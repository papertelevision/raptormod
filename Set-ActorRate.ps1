# Set-ActorRate.ps1 -- retune the animation/actor rate without rebuilding.
#
#   .\Set-ActorRate.ps1                 # report whatever this build uses
#   .\Set-ActorRate.ps1 200             # set it
#
# WHAT THE NUMBER MEANS depends on which gate the build has:
#
#   aztPeriod  (clock gate, rides with $ENABLE_LFB)
#       Hundredths of a BIOS tick between actor steps. 100 = 18.2 Hz, 200 = 9.1,
#       50 = 36.4. BIGGER IS SLOWER. Frame-rate independent, so this is a
#       one-time setting rather than something to re-dial.
#
#   aztActorPct  (older percentage gate)
#       Percent of frames on which actors advance. SMALLER IS SLOWER. Only ever
#       right at one frame rate.
#
# Diagnostic use: set aztPeriod absurdly high (say 2000, about 0.9 Hz). If
# something on screen STILL animates at full speed, it is not going through the
# actor stepper at 0x261C0 at all, and the cause is elsewhere.
[CmdletBinding()]
param(
    [ValidateRange(1, 20000)]
    [int]$Value,
    [string]$Dest = 'C:\Games\AzraelsTear-Modded'
)

$ErrorActionPreference = 'Stop'
$man = Join-Path $PSScriptRoot 'AztMod.manifest.json'
if (-not (Test-Path $man)) { throw "manifest not found: $man" }
$m = Get-Content $man -Raw | ConvertFrom-Json

# Prefer the clock gate when this build has one.
$s = $m.settings | Where-Object { $_.name -eq 'aztPeriod' }
if (-not $s) { $s = $m.settings | Where-Object { $_.name -eq 'aztActorPct' } }
if (-not $s) { throw "this build has no actor-rate setting" }

$exe = Join-Path $Dest 'GAME\AZRAEL\R.EXE'
if (-not (Test-Path $exe)) { throw "patched R.EXE not found: $exe" }

$bytes = [System.IO.File]::ReadAllBytes($exe)
$off   = [int]$s.file
$cur   = [BitConverter]::ToUInt16($bytes, $off)

# Guard against writing to the wrong place if the layout ever shifts.
$max = if ($s.name -eq 'aztPeriod') { 20000 } else { 100 }
if ($cur -lt 1 -or $cur -gt $max) {
    throw ("offset {0} holds {1}, out of range for {2} -- is R.EXE patched with this build?" -f $off, $cur, $s.name)
}

function Describe($n) {
    if ($s.name -eq 'aztPeriod') { "{0}  ({1:N1} Hz)" -f $n, (18.2065 * 100 / $n) } else { "{0}%" -f $n }
}

if (-not $PSBoundParameters.ContainsKey('Value')) {
    Write-Host ("{0} is currently {1}   (build default {2})" -f $s.name, (Describe $cur), $s.default)
    Write-Host ("  {0}" -f $s.desc)
    Write-Host "  pass a number to change it, e.g.  .\Set-ActorRate.ps1 200"
    return
}
if ($s.name -ne 'aztPeriod' -and $Value -gt 100) { throw "aztActorPct is a percentage; use 1..100" }

[BitConverter]::GetBytes([uint16]$Value).CopyTo($bytes, $off)
[System.IO.File]::WriteAllBytes($exe, $bytes)
Write-Host ("{0}: {1} -> {2}" -f $s.name, (Describe $cur), (Describe $Value))
Write-Host "  relaunch to try it."
