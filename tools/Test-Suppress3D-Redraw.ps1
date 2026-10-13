# Test-Suppress3D-Redraw.ps1 -- the decisive form of the unknown-8 test.
#
#   .\tools\Test-Suppress3D-Redraw.ps1
#
# The simple version of this test is ambiguous. With the 3D suppressed the viewport stops
# changing (17.59% -> 0.00% between frames), but the HUD panel ALSO reads 0.00% -- and it
# read only 0.32% in the baseline, because the panel is nearly static anyway. So "the HUD
# stopped changing" cannot distinguish "the HUD pass is still running and drawing the same
# pixels" from "everything stopped".
#
# THE FIX: don't watch, intervene. Blank a rectangle in BOTH regions and see which one the
# game paints back.
#
#   * viewport rectangle stays blank  -> nothing is drawing it   -> 3D really is suppressed
#   * HUD rectangle is repainted      -> the HUD pass is alive   -> UI survives suppression
#
# That is a positive result on both sides rather than an absence of change, and the two
# regions act as each other's control in the same frame.
#
# The frame counter is sampled throughout to prove the game loop is still running at all,
# which rules out "the whole engine stalled".
#
# Everything is restored: the flag from a finally block, and the blanked pixels are the
# game's own to repaint.

#
# TWO MODES, because the obvious one is too blunt:
#
#   -Mode Flag  writes the engine's own 3D-skip flag. MEASURED RESULT: this stops the
#               ENTIRE screen redraw, HUD included -- the flag has 13 references across
#               the codebase, so setting it globally disables far more than one block.
#
#   -Mode Jump  patches the single conditional branch that guards the 3D block,
#               0x14160 `75 2A` (jnz) -> `EB 2A` (jmp), so ONLY 0x14162..0x14187 is
#               skipped and every other path that consults those flags is untouched.
#               One byte, restored afterwards.

[CmdletBinding()]
param(
    [ValidateSet('Flag','Jump')][string]$Mode = 'Jump',
    [long]$JumpSite = 0x14160,        # obj1: the `jnz 0x1418C` guarding the 3D block
    [long]$Flag = 0x1525F2,
    [string]$OutDir = 'C:\Games\azrael-suppress3d',
    [long]$FbOffset = 0x140000,
    [int]$Stride = 2048,
    [int]$SettleMs = 700
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
$OBJ2_DELTA = 0x1F1000
New-Item -ItemType Directory -Force $OutDir | Out-Null

$g = Get-AztGuestBase

# ---- locate the display surface ---------------------------------------------
$regs = [AztTool.ProcMem]::Regions($g.ProcessId, 0x7FFFFFFFFFFF)
$best = $null; $bestRun = 0
foreach ($r in ($regs | Where-Object { $_.Size -ge 8MB -and $_.Size -le 128MB })) {
    $pg = [AztTool.ProcMem]::ChangedPages($g.ProcessId, $r.Base, [int][Math]::Min($r.Size, 16MB), 90)
    if ($null -eq $pg) { continue }
    $run = 0; $cur = 0
    foreach ($x in $pg) { if ($x) { $cur++; if ($cur -gt $run) { $run = $cur } } else { $cur = 0 } }
    if ($run -gt $bestRun) { $bestRun = $run; $best = $r }
}
if (-not $best) { throw "no changing video region found -- is the game in a room?" }
$fb = $best.Base + $FbOffset
Write-Host ("display surface host 0x{0:X11} ({1:N0} MB), longest changed run {2} pages" -f $best.Base, ($best.Size/1MB), $bestRun)

# two test rectangles: one in the 3D viewport, one inside the HUD panel
$VIEW = @{ Name = 'viewport'; Y0 = 150; Y1 = 300; X0 = 400; W = 900 }
$HUD  = @{ Name = 'HUD panel'; Y0 = 690; Y1 = 780; X0 = 900; W = 700 }

function Rect-Read { param($r)
    $rows = @()
    for ($y = $r.Y0; $y -lt $r.Y1; $y++) {
        $b = [AztTool.ProcMem]::Read($g.ProcessId, ($fb + $y*$Stride + $r.X0), $r.W)
        if ($null -eq $b) { throw "read failed" }
        $rows += ,$b
    }
    $rows
}
function Rect-Blank { param($r)
    $zero = New-Object byte[] $r.W
    for ($y = $r.Y0; $y -lt $r.Y1; $y++) {
        [void][AztTool.ProcMem]::Write($g.ProcessId, ($fb + $y*$Stride + $r.X0), $zero)
    }
}
function Rect-NonZero { param($rows)
    $n = 0; $t = 0
    foreach ($row in $rows) { foreach ($b in $row) { $t++; if ($b -ne 0) { $n++ } } }
    return (100.0 * $n / $t)
}

# the overlay's frame counter, to show the game loop is alive
$ovl = [IO.File]::ReadAllBytes('C:\Games\AzraelsTear-Modded\GAME\AZRAEL\AZTCODE.BIN')
$off = -1
for ($i = 0; $i + 4 -le $ovl.Length; $i++) {
    if ($ovl[$i] -eq 0x43 -and $ovl[$i+1] -eq 0x41 -and $ovl[$i+2] -eq 0x4D -and $ovl[$i+3] -eq 0x31) { $off = $i; break }
}
$fnLin = 0x133000 + $off + 4
function FrameNo { [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $fnLin -Length 4), 0) }

if ($Mode -eq 'Flag') {
    $target = $g.MemBase + $Flag + $g.Delta2      # (GuestBase finds obj2's delta: it moved with obj1's size)
    $len = 2
    $suppressBytes = [BitConverter]::GetBytes([uint16]1)
    $desc = ("flag 0x{0:X6} = 1" -f $Flag)
} else {
    # obj1, so the runtime delta is +0x1F0000
    $target = $g.MemBase + $JumpSite + 0x1F0000
    $len = 1
    $suppressBytes = [byte[]](0xEB)          # jnz -> jmp short
    $desc = ("byte at 0x{0:X5}: 75 (jnz) -> EB (jmp)" -f $JumpSite)
}
$orig = [AztTool.ProcMem]::Read($g.ProcessId, $target, $len)
Write-Host ("target: {0}   current bytes: {1}" -f $desc, (($orig | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
if ($Mode -eq 'Jump' -and $orig[0] -ne 0x75) {
    throw ("expected 0x75 (jnz) at 0x{0:X5} but found 0x{1:X2} -- refusing to patch the wrong instruction" -f $JumpSite, $orig[0])
}
$flagHost = $target

function Run-Probe { param([string]$label)
    Write-Host ""
    Write-Host ("=== $label ===") -ForegroundColor Cyan
    $f0 = FrameNo
    foreach ($r in @($VIEW, $HUD)) {
        $before = Rect-NonZero (Rect-Read $r)
        Rect-Blank $r
        $justAfter = Rect-NonZero (Rect-Read $r)
        Start-Sleep -Milliseconds $SettleMs
        $after = Rect-NonZero (Rect-Read $r)
        $verdict = if ($after -gt 1.0) { 'REPAINTED by the game' } else { 'still blank -- nothing drew it' }
        Write-Host ("  {0,-10}  non-zero before {1,6:N2}%  after blanking {2,5:N2}%  {3}ms later {4,6:N2}%   -> {5}" -f `
                    $r.Name, $before, $justAfter, $SettleMs, $after, $verdict)
    }
    $f1 = FrameNo
    Write-Host ("  frame counter {0} -> {1}  ({2} frames elapsed, so the game loop {3})" -f `
                $f0, $f1, ($f1 - $f0), $(if ($f1 -gt $f0) { 'IS running' } else { 'is NOT running' }))
}

try {
    Run-Probe "BASELINE - 3D running"
    Write-Host ""
    Write-Host ("applying: {0}" -f $desc) -ForegroundColor Yellow
    [void][AztTool.ProcMem]::Write($g.ProcessId, $target, $suppressBytes)
    Start-Sleep -Milliseconds 600
    Run-Probe ("SUPPRESSED - mode {0}" -f $Mode)
}
finally {
    [void][AztTool.ProcMem]::Write($g.ProcessId, $target, $orig)
    Start-Sleep -Milliseconds 500
    $now = [AztTool.ProcMem]::Read($g.ProcessId, $target, $len)
    $ok = $true
    for ($i = 0; $i -lt $len; $i++) { if ($now[$i] -ne $orig[$i]) { $ok = $false } }
    Write-Host ""
    Write-Host ("restored: {0}  (verified: {1})" -f (($now | ForEach-Object { '{0:X2}' -f $_ }) -join ' '), $ok) -ForegroundColor Green
}
