# Set-AnimRate.ps1 -- change how fast animations play, without rebuilding.
#
#   .\Set-AnimRate.ps1           # report the current rate
#   .\Set-AnimRate.ps1 14        # 14 animation frames per second
#
# THIS IS THE ANIMATION DIAL. Set-ActorRate.ps1 is not: aztPeriod gates 0x261C0,
# which is the actor SCRIPT interpreter (walk to a point, wait, play a sound),
# and its one caller is skipped entirely in the opening room. Turning it down
# four-fold changes nothing you can see, which is exactly how this dial came to
# exist.
#
# What actually animates a creature is a Reality Lab move callback that adds ONE
# animation frame per RENDERED frame, with no clock anywhere on the path -- so
# the animation rate was simply the frame rate. AztMod gates all three of those
# sites on the real clock instead. 18.2 Hz is the BIOS tick and the rate the 1996
# build was paced at; the 40 fps cap was running everything 2.2x too fast.
#
# LOWER = slower. It cannot go faster than the frame rate, because the gate still
# allows at most one step per rendered frame -- asking for 60 on a 40 fps cap
# just gives you 40.
[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [double]$Fps,
    [string]$Dest = 'C:\Games\AzraelsTear-Modded'
)

$ErrorActionPreference = 'Stop'
$US = 1000000.0

$man = Join-Path $PSScriptRoot 'AztMod.manifest.json'
if (-not (Test-Path $man)) { throw "manifest not found: $man" }
$m = Get-Content $man -Raw | ConvertFrom-Json
$s = $m.settings | Where-Object { $_.name -eq 'aztAnimPeriod' }
if (-not $s) { throw "this build has no animation gate (needs `$ENABLE_ACTOR_TIME)" }

$exe = Join-Path $Dest 'GAME\AZRAEL\R.EXE'
if (-not (Test-Path $exe)) { throw "patched R.EXE not found: $exe" }

$bytes = [System.IO.File]::ReadAllBytes($exe)
$off   = [int]$s.file
$cur   = [BitConverter]::ToUInt32($bytes, $off)

# Sanity-check the slot before writing, in case the layout ever shifts.
if ($cur -lt ($US / 60) -or $cur -gt $US) {
    throw ("offset {0} holds {1}, not a plausible animation period -- is R.EXE patched with this build?" -f $off, $cur)
}

if (-not $PSBoundParameters.ContainsKey('Fps')) {
    Write-Host ("animation rate is {0:N1} Hz  ({1} us per frame)" -f ($US / $cur), $cur)
    Write-Host ("  build default {0} us ({1:N1} Hz, the BIOS tick)" -f $s.default, ($US / [double]$s.default))
    Write-Host "  pass a number to change it, e.g.  .\Set-AnimRate.ps1 14"
    return
}

$new = [uint32][Math]::Round($US / $Fps)
[BitConverter]::GetBytes($new).CopyTo($bytes, $off)
[System.IO.File]::WriteAllBytes($exe, $bytes)
Write-Host ("animation rate {0:N1} Hz -> {1:N1} Hz  ({2} us)" -f ($US / $cur), $Fps, $new)
Write-Host "  relaunch to try it."
