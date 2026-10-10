# Set-EyeHeight.ps1 -- how tall you are, without rebuilding.
#
#   .\Set-EyeHeight.ps1            # report the current height
#   .\Set-EyeHeight.ps1 95         # eye 95 units above the floor
#
# PASS A POSITIVE NUMBER. Internally the engine stores this as a NEGATIVE Y,
# because negative Y is up in Azrael's world space, but a dial that goes "down to
# make you taller" is a trap. This script flips the sign for you.
#
# What it moves: the camera is a child frame of the player, and 0x1388A is the
# only place its offset inside that parent is set -- `push 0xC28C0000` = -70.0f.
# So this is a genuine eye height, not a spawn position, and it survives walking,
# room changes and reloads.
#
# Scale: running is ~291 units/second, so if that is about 4 m/s the world is
# roughly 73 units to the metre -- which puts the stock 70 at well under a metre
# and explains why the stock game feels like playing a child. 120-125 is around
# adult eye level if that estimate holds; 85-95 is a moderate, safe lift.
#
# Collision is horizontal (X/Z), so raising this cannot walk you through walls.
# The real limit is cosmetic: too tall and the view clips into low ceilings and
# door frames, which shows up as geometry vanishing in front of you.
[CmdletBinding()]
param(
    [ValidateRange(40, 200)]
    [double]$Height,
    [string]$Dest = 'C:\Games\AzraelsTear-Modded'
)

$ErrorActionPreference = 'Stop'
$man = Join-Path $PSScriptRoot 'AztMod.manifest.json'
if (-not (Test-Path $man)) { throw "manifest not found: $man" }
$m = Get-Content $man -Raw | ConvertFrom-Json
$s = $m.settings | Where-Object { $_.name -eq 'aztEyeHeight' }
if (-not $s) { throw "this build has no eye-height setting" }

$exe = Join-Path $Dest 'GAME\AZRAEL\R.EXE'
if (-not (Test-Path $exe)) { throw "patched R.EXE not found: $exe" }

$bytes = [System.IO.File]::ReadAllBytes($exe)
$off   = [int]$s.file
$cur   = [BitConverter]::ToSingle($bytes, $off)

# Guard the slot before writing, in case the layout ever shifts. Stock is -70 and
# anything sane stays negative and in the same order of magnitude.
if ($cur -gt -40.0 -or $cur -lt -200.0) {
    throw ("offset {0} holds {1}, not a plausible eye height -- is R.EXE patched with this build?" -f $off, $cur)
}

if (-not $PSBoundParameters.ContainsKey('Height')) {
    Write-Host ("eye height is {0:N1} units  (stored as {1:N1})" -f (-$cur), $cur)
    Write-Host ("  build default {0:N1};  stock game 70.0" -f (-[double]$s.default))
    Write-Host "  pass a number to change it, e.g.  .\Set-EyeHeight.ps1 95   (bigger = taller)"
    return
}

$new = [single](-[Math]::Abs($Height))
[BitConverter]::GetBytes($new).CopyTo($bytes, $off)
[System.IO.File]::WriteAllBytes($exe, $bytes)
Write-Host ("eye height {0:N1} -> {1:N1} units" -f (-$cur), $Height)
Write-Host "  relaunch to try it."
