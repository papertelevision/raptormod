# Map-GuestMemory.ps1 -- read the running game's memory from the host, with no DOSBox fork.
#
#   .\tools\Map-GuestMemory.ps1 -WaitFor 240 -Lin 0x133000 -Len 256
#   .\tools\Map-GuestMemory.ps1                       # attach to a running dosbox now
#
# Tests the cheap end of unknown 7. NOTHING IS EVER WRITTEN to the game's memory.
#
# METHOD. Strings are the one thing in an LE image the loader never relocates, so long
# strings from R.EXE make ideal needles: find each exactly once, convert its file offset
# to the address the game actually runs at, and the difference is DOSBox's emulated-RAM
# base. Several needles are used on purpose -- a single one would produce a "consistent"
# answer with nothing to check it against.
#
# THE FILE -> RUNTIME CONVERSION IS PER OBJECT, and getting it wrong silently shifts
# everything by 0x1000:
#   obj1  image linear 0x10000, file 0x61A54 onward,             runs at +0x1F0000
#   obj2  image linear 0x140000, file 0x61A54 + 291*4096 onward, runs at +0x1F1000
# The 291 is obj1's page count from the LE header; the data-pages offset 0x61A54 is
# derived from the file tail because the header's own value is wrong.
#
# TIMING. Attach whenever the game is up; but the AztMod overlay at image-linear 0x133000
# is only present once the game has actually initialised it, so a dump of that address
# taken during the intro will read as empty. -WaitFor polls for the process so you can
# launch and play without racing a fixed sleep.

[CmdletBinding()]
param(
    [string]$Exe = 'C:\Games\RaptorMod\game\GAME\AZRAEL\R.EXE',
    [int]$WaitFor = 0,             # seconds to poll for a dosbox process
    [int]$Settle = 20,             # seconds to let the game initialise before reading
    [long]$Lin = 0,                # a guest IMAGE-linear address to dump (e.g. 0x133000)
    [int]$Len = 256,
    [switch]$Obj2,                 # $Lin is an obj2 address (delta 0x1F1000, not 0x1F0000)
    [string]$OutFile               # optional: write the dumped bytes to this file
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
if (-not ("AztTool.ProcMem" -as [type])) { Add-Type -Path (Join-Path $toolDir 'ProcMem.cs') }

$DATA_PAGES = 0x61A54
$OBJ1_LIN   = 0x10000
$OBJ1_PAGES = 291
$OBJ2_LIN   = 0x140000
$OBJ2_FILE  = $DATA_PAGES + $OBJ1_PAGES * 4096      # 0x184A54
$D1 = 0x1F0000
# obj2 runs one page past obj1's END, so its delta follows obj1's vsize in this R.EXE's object table (0x1F1000 with the
# old 52 KB overlay window, 0x224000 with the 256 KB one -- 2026-10-11; see GuestBase.ps1 Get-AztObj2Deltas)
$D2 = 0x1F1000
try {
    $fsx = [IO.File]::Open($Exe, 'Open', 'Read', 'ReadWrite, Delete'); $vb = New-Object byte[] 4
    try { [void]$fsx.Seek(0x290FC + 0xC4, 'Begin'); [void]$fsx.Read($vb, 0, 4) } finally { $fsx.Dispose() }
    $D2 = $D1 + $OBJ1_LIN + ([long]([Math]::Ceiling([BitConverter]::ToUInt32($vb, 0) / 4096.0)) * 4096) + 0x1000 - $OBJ2_LIN
} catch { }

function Get-Dosbox {
    Get-Process -Name 'dosbox*' -ErrorAction SilentlyContinue | Select-Object -First 1
}

$proc = Get-Dosbox
if (-not $proc -and $WaitFor -gt 0) {
    Write-Host ("waiting up to {0}s for a dosbox process -- launch the game and play into the first room" -f $WaitFor)
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitFor)
    while (-not $proc -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $proc = Get-Dosbox
    }
    if ($proc) {
        # Let the game get past its own startup before reading. The overlay is only
        # present once AztMod's init has run, so an immediate read can be premature.
        Write-Host ("  found pid {0}; giving the game {1}s to initialise" -f $proc.Id, $Settle)
        for ($i = 0; $i -lt $Settle; $i++) {
            Start-Sleep -Seconds 1
            if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
                Write-Host "  game closed during settle; back to waiting" -ForegroundColor Yellow
                $proc = $null
                break
            }
        }
        # closed during settle and there is still time: resume polling
        while (-not $proc -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 700
            $proc = Get-Dosbox
            if ($proc) {
                Write-Host ("  found pid {0} again; settling" -f $proc.Id)
                Start-Sleep -Seconds $Settle
                if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { $proc = $null }
            }
        }
    }
}
if (-not $proc) {
    Write-Host ""
    Write-Host "No dosbox process appeared before the deadline. Nothing was read and nothing" -ForegroundColor Yellow
    Write-Host "was changed -- just re-run this with the game already running." -ForegroundColor Yellow
    return
}
Write-Host ("target: pid {0}, working set {1:N0} MB" -f $proc.Id, ($proc.WorkingSet64 / 1MB))

if (-not (Test-Path $Exe)) { throw "not found: $Exe" }
# DOSBox holds R.EXE open EXCLUSIVELY while the game runs, so ReadAllBytes fails with
# a sharing violation exactly when this tool is most useful. Open it with a permissive
# share mode instead; we only ever read.
$fs = [IO.File]::Open($Exe, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                      ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try {
    $br = New-Object IO.BinaryReader($fs)
    $exeBytes = $br.ReadBytes([int]$fs.Length)
} finally { $fs.Dispose() }
$exeText = [Text.Encoding]::GetEncoding(28591).GetString($exeBytes)

# needles spread across the image; each is plain text and therefore never relocated
$needles = @(
    'To prevent danger of overload it is recommended',
    'VESA VBE SuperVGA BIOS implemenation',
    'Audio Interface Library application usage script',
    'Run-Time system. (c) Copyright by WATCOM'
)

function FileToRuntime([long]$fileOff) {
    if ($fileOff -ge $OBJ2_FILE) { return ($OBJ2_LIN + ($fileOff - $OBJ2_FILE) + $D2), 'obj2' }
    if ($fileOff -ge $DATA_PAGES) { return ($OBJ1_LIN + ($fileOff - $DATA_PAGES) + $D1), 'obj1' }
    return $null, 'not loaded'
}

$rows = @()
foreach ($n in $needles) {
    $fo = $exeText.IndexOf($n)
    if ($fo -lt 0) { continue }
    $rt, $obj = FileToRuntime $fo
    if ($null -eq $rt) { Write-Host ("  {0,-34} file 0x{1:X6} is below the data pages -- skipped" -f $n.Substring(0,34), $fo) -ForegroundColor Yellow; continue }
    try { $hits = [AztTool.ProcMem]::Scan($proc.Id, [Text.Encoding]::ASCII.GetBytes($n), 4KB, 4GB, 0x7FFFFFFFFFFF, 4) }
    catch { throw ("scan failed -- the game probably exited. {0}" -f $_.Exception.Message) }
    if ($hits.Count -ne 1) {
        Write-Host ("  {0,-34} {1} hit(s) -- excluded" -f $n.Substring(0,34), $hits.Count) -ForegroundColor Yellow
        continue
    }
    $rows += [pscustomobject]@{ N = $n.Substring(0,[Math]::Min(30,$n.Length)); File = [long]$fo
                                Obj = $obj; Run = [long]$rt; Host_ = [long]$hits[0]
                                Base = ([long]$hits[0] - [long]$rt) }
}
if (-not $rows.Count) { throw "no unambiguous needle found -- is the game actually loaded?" }

Write-Host ""
Write-Host ("{0,-32} {1,4} {2,10} {3,10} {4,16}" -f 'needle','obj','file','runtime','host - runtime')
foreach ($r in $rows) {
    Write-Host ("{0,-32} {1,4} 0x{2:X6}  0x{3:X6}   0x{4:X11}" -f $r.N, $r.Obj, $r.File, $r.Run, $r.Base)
}

$bases = @($rows | ForEach-Object { $_.Base } | Sort-Object -Unique)
Write-Host ""
if ($bases.Count -ne 1) {
    Write-Host ("INCONSISTENT -- {0} different bases. Guest linear is NOT identity-mapped onto" -f $bases.Count) -ForegroundColor Yellow
    Write-Host  "the emulated RAM array; a page-table walk would be needed." -ForegroundColor Yellow
    foreach ($b in $bases) { Write-Host ("   0x{0:X11}" -f $b) -ForegroundColor Yellow }
    return
}
$memBase = $bases[0]
Write-Host ("CONSISTENT across {0} needles -- host = runtimeLinear + 0x{1:X11}" -f $rows.Count, $memBase) -ForegroundColor Green

$regs = [AztTool.ProcMem]::Regions($proc.Id, 0x7FFFFFFFFFFF)
$ram = $regs | Where-Object { $memBase -ge $_.Base -and $memBase -lt ($_.Base + $_.Size) } | Select-Object -First 1
if ($ram) {
    Write-Host ("guest RAM: host 0x{0:X11}, {1:N0} MB; MemBase sits 0x{2:X} into it" -f `
        $ram.Base, ($ram.Size / 1MB), ($memBase - $ram.Base))
}

if ($Lin) {
    $rt = $Lin + $(if ($Obj2) { $D2 } else { $D1 })
    $addr = $rt + $memBase
    Write-Host ""
    Write-Host ("--- guest image-linear 0x{0:X} (runtime 0x{1:X}) at host 0x{2:X11} ---" -f $Lin, $rt, $addr)
    $bytes = [AztTool.ProcMem]::Read($proc.Id, $addr, $Len)
    if ($null -eq $bytes) { Write-Host "  read failed" -ForegroundColor Yellow; return }
    $nonZero = 0; foreach ($b in $bytes) { if ($b -ne 0) { $nonZero++ } }
    for ($i = 0; $i -lt $bytes.Length; $i += 16) {
        $n = [Math]::Min(16, $bytes.Length - $i)
        $hex = ''; $asc = ''
        for ($j = 0; $j -lt $n; $j++) {
            $hex += ('{0:X2} ' -f $bytes[$i+$j])
            $c = $bytes[$i+$j]
            $asc += $(if ($c -ge 32 -and $c -lt 127) { [char]$c } else { '.' })
        }
        Write-Host ("  {0:X8}  {1,-48} {2}" -f ($Lin + $i), $hex, $asc)
    }
    Write-Host ("  {0} of {1} bytes non-zero" -f $nonZero, $bytes.Length)
    if ($OutFile) { [IO.File]::WriteAllBytes($OutFile, $bytes); Write-Host ("  written to {0}" -f $OutFile) }
}

if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { Write-Host "`ndosbox still running." }
else { Write-Host "`ndosbox exited during the scan -- rerun and leave it up." -ForegroundColor Yellow }
