# Set-FrameCap.ps1 -- change the frame-rate cap without rebuilding.
#
#   .\Set-FrameCap.ps1           # report the current cap
#   .\Set-FrameCap.ps1 24        # cap at 24 fps
#
# WHY THERE IS A CAP AT ALL. Azrael is frame-tied end to end: player movement is
# `pos += dir * constant` PER FRAME, and nothing in the animation path reads a
# clock. So the frame rate is also the game speed, and a frame rate that changes
# with room content makes the game speed change with it -- which is why the first
# room ran at hyperspeed and settled only once enough was going on to slow it.
#
# Capping the loop makes every frame-tied system advance at a fixed rate. The
# trade is that frame rate above the cap is thrown away, so this is a genuine
# taste dial: LOWER = slower, steadier, closer to how the game was built (~18 fps);
# HIGHER = smoother, but everything moves faster than the 1996 design intended.
[CmdletBinding()]
param(
    [ValidateRange(5, 120)]
    [int]$Fps,
    [string]$Dest = 'C:\Games\AzraelsTear-Modded'
)

$ErrorActionPreference = 'Stop'
# AztNow now returns MICROSECONDS, not PIT ticks -- it no longer reads the PIT
# counter directly, because the game reprograms channel 0 (see AztNow).
$PIT_HZ = 1000000.0

$man = Join-Path $PSScriptRoot 'AztMod.manifest.json'
if (-not (Test-Path $man)) { throw "manifest not found: $man" }
$m = Get-Content $man -Raw | ConvertFrom-Json
$s = $m.settings | Where-Object { $_.name -eq 'aztFramePeriod' }
if (-not $s) { throw "this build has no frame limiter (needs `$ENABLE_ACTOR_TIME)" }

$exe = Join-Path $Dest 'GAME\AZRAEL\R.EXE'
if (-not (Test-Path $exe)) { throw "patched R.EXE not found: $exe" }

$bytes = [System.IO.File]::ReadAllBytes($exe)
$off   = [int]$s.file
$cur   = [BitConverter]::ToUInt32($bytes, $off)

# Sanity-check the slot before writing, in case the layout ever shifts.
# FLOOR the fast end: the period is written ROUNDED, so 120 fps stores 8333 while
# $PIT_HZ/120 is 8333.33 -- the un-floored bound rejected the exact value this
# script had just written at the top of its own ValidateRange.
if ($cur -lt [Math]::Floor($PIT_HZ / 120) -or $cur -gt ($PIT_HZ / 5)) {
    throw ("offset {0} holds {1}, not a plausible frame period -- is R.EXE patched with this build?" -f $off, $cur)
}

if (-not $PSBoundParameters.ContainsKey('Fps')) {
    Write-Host ("frame cap is {0:N1} fps  ({1} us per frame)" -f ($PIT_HZ / $cur), $cur)
    Write-Host "  pass a number to change it, e.g.  .\Set-FrameCap.ps1 24"
    return
}

$new = [uint32][Math]::Round($PIT_HZ / $Fps)
[BitConverter]::GetBytes($new).CopyTo($bytes, $off)
[System.IO.File]::WriteAllBytes($exe, $bytes)
Write-Host ("frame cap {0:N1} fps -> {1} fps  ({2} us)" -f ($PIT_HZ / $cur), $Fps, $new)
Write-Host "  relaunch to try it."

