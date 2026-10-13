# GuestBase.ps1 -- find DOSBox's emulated-RAM base, so host code can address the guest.
#
#   . .\tools\GuestBase.ps1
#   $g = Get-AztGuestBase
#   $host_ = $g.MemBase + $runtimeLinear
#
# Dot-source this rather than copying the derivation: the base MOVES between runs (the
# allocation is subject to ASLR), so it must be derived every time, and the per-object
# runtime deltas differ by 0x1000, which is exactly the kind of constant that gets
# mis-copied.

$script:AZT_DATA_PAGES = 0x61A54                       # derived, not from the LE header
$script:AZT_OBJ1_LIN   = 0x10000
$script:AZT_OBJ1_PAGES = 291
$script:AZT_OBJ2_LIN   = 0x140000
$script:AZT_OBJ2_FILE  = 0x61A54 + 291 * 4096          # 0x184A54
$script:AZT_D1 = 0x1F0000                              # obj1 runs at 0x200000
# obj2 runs ONE PAGE PAST obj1's END -- DOS/4GW places the objects one after another -- so its delta follows obj1's vsize:
# 0x1F1000 with the 52 KB overlay window (vsize 0x130000), 0x224000 with the 256 KB one (vsize 0x163000, 2026-10-11).
# Get-AztGuestBase works it out from the installed R.EXE's header and the needles (Get-AztObj2Deltas) and returns it as
# .Delta2; this is only the default for callers that have no base object.
$script:AZT_D2 = 0x1F1000
$script:AZT_OBJ1_VSIZE_OFF = 0x290FC + 0xC4             # obj1's vsize in the LE object table (file offset)

function Get-AztObj2Deltas {
    <#
      The obj2 deltas to try, most likely first: the one obj1's vsize in this R.EXE implies (one page past obj1's end,
      obj1 at 0x200000), then the old 0x1F1000. A plain COPY of the file sitting in a buffer gives neither (its objects
      are 0xD000 closer), so the two-object needle rule still rejects one.
    #>
    param([byte[]]$ExeBytes)
    $c = New-Object System.Collections.Generic.List[long]
    if ($ExeBytes -and $ExeBytes.Length -gt $script:AZT_OBJ1_VSIZE_OFF + 4) {
        $vs = [long][BitConverter]::ToUInt32($ExeBytes, $script:AZT_OBJ1_VSIZE_OFF)
        $pages = [long]([Math]::Ceiling($vs / 4096.0)) * 4096
        $c.Add($script:AZT_D1 + $script:AZT_OBJ1_LIN + $pages + 0x1000 - $script:AZT_OBJ2_LIN)
    }
    if (-not $c.Contains([long]0x1F1000)) { $c.Add([long]0x1F1000) }
    return ,$c.ToArray()
}

function ConvertTo-AztRuntime {
    <#
      A file offset in R.EXE -> the linear address the game actually runs it at.
      Returns $null for offsets below the data pages (header/stub, never loaded).
      -D2: obj2's delta (Get-AztGuestBase's .Delta2); the old default otherwise.
    #>
    param([Parameter(Mandatory)][long]$FileOffset, [long]$D2 = $script:AZT_D2)
    if ($FileOffset -ge $script:AZT_OBJ2_FILE) {
        return [pscustomobject]@{ Runtime = $script:AZT_OBJ2_LIN + ($FileOffset - $script:AZT_OBJ2_FILE) + $D2; Obj = 'obj2' }
    }
    if ($FileOffset -ge $script:AZT_DATA_PAGES) {
        return [pscustomobject]@{ Runtime = $script:AZT_OBJ1_LIN + ($FileOffset - $script:AZT_DATA_PAGES) + $script:AZT_D1; Obj = 'obj1' }
    }
    return $null
}

function Get-AztGuestBase {
    <#
      Locate the running game inside the DOSBox process and return
        { Pid, MemBase, RamBase, RamSize, Needles }
      MemBase is the host address that guest runtime-linear 0 would map to, so
        hostAddress = MemBase + runtimeLinear.

      Long strings from R.EXE are the needles because the LE loader never relocates
      text. Several are used, spanning BOTH objects -- a single needle would always
      look self-consistent, and one that only covered obj2 would not catch a mistake
      in obj1's delta.
    #>
    [CmdletBinding()]
    param(
        [string]$Exe = 'C:\Games\AzraelsTear-Modded\GAME\AZRAEL\R.EXE',
        [int]$ProcessId = 0,
        # Only regions at least this big are searched. The emulated RAM is ONE allocation of
        # memsize MB (32), so 8 MB skips everything else DOSBox has mapped -- most of the scan's
        # time -- and also its file buffers, which can hold R.EXE before DOS4GW has loaded it.
        [long]$MinRegion = 4KB,
        # Accept needles from one object only (the old rule). The watcher falls back to this if the
        # two-object rule has not been met for a while, in case a needle is not unique in a build.
        [switch]$AllowOneObject
    )

    $toolDir = Split-Path -Parent $PSCommandPath
    if (-not ("AztTool.ProcMem" -as [type])) { Add-Type -Path (Join-Path $toolDir 'ProcMem.cs') }

    if (-not $ProcessId) {
        $p = Get-Process -Name 'dosbox*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $p) { throw "no dosbox process running" }
        $ProcessId = $p.Id
    }

    if (-not (Test-Path $Exe)) { throw "not found: $Exe" }
    # DOSBox holds R.EXE open exclusively while the game runs, so a plain ReadAllBytes
    # fails with a sharing violation exactly when this is most useful.
    $fs = [IO.File]::Open($Exe, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                          ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $exeBytes = (New-Object IO.BinaryReader($fs)).ReadBytes([int]$fs.Length) }
    finally { $fs.Dispose() }
    $exeText = [Text.Encoding]::GetEncoding(28591).GetString($exeBytes)

    $needles = @(
        'To prevent danger of overload it is recommended',   # obj2
        'VESA VBE SuperVGA BIOS implemenation',              # obj2
        'Audio Interface Library application usage script',  # obj2
        'Run-Time system. (c) Copyright by WATCOM'           # obj1 -- spans the image
    )

    $found = @()
    foreach ($n in $needles) {
        $fo = $exeText.IndexOf($n)
        if ($fo -lt 0) { continue }
        $rt = ConvertTo-AztRuntime -FileOffset $fo -D2 0
        if ($null -eq $rt) { continue }
        $hits = [AztTool.ProcMem]::Scan($ProcessId, [Text.Encoding]::ASCII.GetBytes($n), $MinRegion, 4GB, 0x7FFFFFFFFFFF, 4)
        if ($hits.Count -ne 1) { continue }
        # Lin: the address before its object's delta (obj1's is fixed; obj2's is found below)
        $lin = $(if ($rt.Obj -eq 'obj1') { [long]$rt.Runtime - $script:AZT_D1 } else { [long]$rt.Runtime })
        $found += [pscustomobject]@{ Needle = $n; Obj = $rt.Obj; File = [long]$fo; Lin = $lin; Host_ = [long]$hits[0] }
    }
    if (-not $found.Count) { throw "no unambiguous needle found -- is the game loaded?" }
    # BOTH OBJECTS, or it is not the loaded image. Needles from one object always agree with each
    # other -- including in a plain copy of the file sitting in a buffer -- so only a pair that
    # spans obj1 and obj2 proves the per-object deltas, and with them the base. (Attaching while
    # the game is still starting made this matter: that is when such copies exist.)
    if (-not $AllowOneObject -and @($found | ForEach-Object { $_.Obj } | Sort-Object -Unique).Count -lt 2) {
        throw ("only {0} needle(s), all in {1} -- not yet the loaded game" -f $found.Count, $found[0].Obj)
    }

    # obj2's delta: the candidate under which every needle agrees on one base
    $d2s = Get-AztObj2Deltas $exeBytes; $memBase = $null; $d2 = $null; $seen = @()
    foreach ($cd in $d2s) {
        $bases = @($found | ForEach-Object { $_.Host_ - ($_.Lin + $(if ($_.Obj -eq 'obj1') { $script:AZT_D1 } else { $cd })) } | Sort-Object -Unique)
        $seen += ('0x{0:X}: {1} base(s)' -f $cd, $bases.Count)
        if ($bases.Count -eq 1) { $memBase = $bases[0]; $d2 = $cd; break }
    }
    if ($null -eq $memBase) {
        # (say what obj2's delta WOULD be from an obj1 + obj2 pair, so a layout nobody expected can be read off the log)
        $o1 = $found | Where-Object { $_.Obj -eq 'obj1' } | Select-Object -First 1; $o2 = $found | Where-Object { $_.Obj -eq 'obj2' } | Select-Object -First 1
        $implied = $(if ($o1 -and $o2) { '; an obj1/obj2 pair implies obj2 delta 0x{0:X}' -f ($o2.Host_ - $o2.Lin - ($o1.Host_ - $o1.Lin - $script:AZT_D1)) } else { '' })
        throw ("inconsistent base across {0} needles (obj2 deltas tried: {1}){2} -- guest linear is not " -f $found.Count, ($seen -join ', '), $implied) +
              "identity-mapped onto the emulated RAM array, or the objects sit somewhere new"
    }
    foreach ($f in $found) { $f | Add-Member -NotePropertyName Runtime -NotePropertyValue ($f.Lin + $(if ($f.Obj -eq 'obj1') { $script:AZT_D1 } else { $d2 })); $f | Add-Member -NotePropertyName Base -NotePropertyValue $memBase }

    $regs = [AztTool.ProcMem]::Regions($ProcessId, 0x7FFFFFFFFFFF)
    $ram = $regs | Where-Object { $memBase -ge $_.Base -and $memBase -lt ($_.Base + $_.Size) } | Select-Object -First 1

    [pscustomobject]@{
        ProcessId = $ProcessId
        MemBase   = $memBase
        RamBase   = $(if ($ram) { $ram.Base } else { 0 })
        RamSize   = $(if ($ram) { $ram.Size } else { 0 })
        Needles   = $found
        Delta1    = [long]$script:AZT_D1
        Delta2    = [long]$d2
    }
}

function Read-AztRuntime {
    <#
      Read `Length` bytes from a RAW runtime address -- the values the engine itself
      stores in its pointers, as opposed to the image-linear addresses AztMod's patches
      are written against. Returns $null if the read fails.
    #>
    param(
        [Parameter(Mandatory)]$Base,
        [Parameter(Mandatory)][long]$Addr,
        [Parameter(Mandatory)][int]$Length
    )
    [AztTool.ProcMem]::Read($Base.ProcessId, ($Base.MemBase + $Addr), $Length)
}

function Test-AztPointer {
    <#
      Does this look like a guest pointer at all? Emulated RAM is 32 MB, and anything
      below the first page is certainly not an object. Cheap, but it is what stops a
      float or a count being followed as a pointer and walking off into nonsense.
    #>
    param([Parameter(Mandatory)][long]$Addr, $Base)
    $limit = if ($Base -and $Base.RamSize -gt 0) { [long]$Base.RamSize } else { 0x2000000 }
    return ($Addr -ge 0x1000 -and $Addr -lt $limit)
}

function Read-AztGuest {
    <#
      Read `Length` bytes from a guest IMAGE-linear address (the addresses AztMod's
      patches use). Pass -Obj2 for an obj2 address; the deltas differ by a page.
    #>
    param(
        [Parameter(Mandatory)]$Base,       # from Get-AztGuestBase
        [Parameter(Mandatory)][long]$Lin,
        [Parameter(Mandatory)][int]$Length,
        [switch]$Obj2
    )
    $d2 = $(if ($Base.PSObject.Properties['Delta2'] -and $Base.Delta2) { [long]$Base.Delta2 } else { $script:AZT_D2 })
    $rt = $Lin + $(if ($Obj2) { $d2 } else { $script:AZT_D1 })
    [AztTool.ProcMem]::Read($Base.ProcessId, ($Base.MemBase + $rt), $Length)
}
