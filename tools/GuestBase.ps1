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
$script:AZT_D2 = 0x1F1000                              # obj2 is a page further along

function ConvertTo-AztRuntime {
    <#
      A file offset in R.EXE -> the linear address the game actually runs it at.
      Returns $null for offsets below the data pages (header/stub, never loaded).
    #>
    param([Parameter(Mandatory)][long]$FileOffset)
    if ($FileOffset -ge $script:AZT_OBJ2_FILE) {
        return [pscustomobject]@{ Runtime = $script:AZT_OBJ2_LIN + ($FileOffset - $script:AZT_OBJ2_FILE) + $script:AZT_D2; Obj = 'obj2' }
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
        $rt = ConvertTo-AztRuntime -FileOffset $fo
        if ($null -eq $rt) { continue }
        $hits = [AztTool.ProcMem]::Scan($ProcessId, [Text.Encoding]::ASCII.GetBytes($n), $MinRegion, 4GB, 0x7FFFFFFFFFFF, 4)
        if ($hits.Count -ne 1) { continue }
        $found += [pscustomobject]@{ Needle = $n; Obj = $rt.Obj; File = [long]$fo
                                     Runtime = [long]$rt.Runtime; Host_ = [long]$hits[0]
                                     Base = ([long]$hits[0] - [long]$rt.Runtime) }
    }
    if (-not $found.Count) { throw "no unambiguous needle found -- is the game loaded?" }
    # BOTH OBJECTS, or it is not the loaded image. Needles from one object always agree with each
    # other -- including in a plain copy of the file sitting in a buffer -- so only a pair that
    # spans obj1 and obj2 proves the per-object deltas, and with them the base. (Attaching while
    # the game is still starting made this matter: that is when such copies exist.)
    if (-not $AllowOneObject -and @($found | ForEach-Object { $_.Obj } | Sort-Object -Unique).Count -lt 2) {
        throw ("only {0} needle(s), all in {1} -- not yet the loaded game" -f $found.Count, $found[0].Obj)
    }

    $bases = @($found | ForEach-Object { $_.Base } | Sort-Object -Unique)
    if ($bases.Count -ne 1) {
        throw ("inconsistent base across {0} needles ({1} distinct) -- guest linear is not " -f $found.Count, $bases.Count) +
              "identity-mapped onto the emulated RAM array, so a page-table walk is needed"
    }
    $memBase = $bases[0]

    $regs = [AztTool.ProcMem]::Regions($ProcessId, 0x7FFFFFFFFFFF)
    $ram = $regs | Where-Object { $memBase -ge $_.Base -and $memBase -lt ($_.Base + $_.Size) } | Select-Object -First 1

    [pscustomobject]@{
        ProcessId = $ProcessId
        MemBase   = $memBase
        RamBase   = $(if ($ram) { $ram.Base } else { 0 })
        RamSize   = $(if ($ram) { $ram.Size } else { 0 })
        Needles   = $found
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
    $rt = $Lin + $(if ($Obj2) { $script:AZT_D2 } else { $script:AZT_D1 })
    [AztTool.ProcMem]::Read($Base.ProcessId, ($Base.MemBase + $rt), $Length)
}
