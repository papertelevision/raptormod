# Read-LiveCamera.ps1 -- read the game's live camera pose from the host, no file I/O.
#
#   .\tools\Read-LiveCamera.ps1 -Samples 20 -IntervalMs 400
#
# This is the end of the mailbox chain the feasibility report proposed in §9: the guest
# publishes state into AztMod's overlay every frame, and host code reads it straight out
# of DOSBox's memory. No emulator fork, and -- unlike AZTCAM.LOG -- no disk write per
# frame and no waiting for the game to exit before the data can be used.
#
# FINDING THE RECORD WITHOUT REBUILDING. The overlay's label map is not in the manifest,
# and rebuilding to obtain it would produce an AZTCODE.BIN that might differ from the one
# the RUNNING game loaded, which would put every offset silently out of place. Instead
# the record is located by its own magic: `aztCamRec` is declared as the dword 'CAM1',
# so searching the shipped AZTCODE.BIN for that value gives its offset directly, and the
# guest address is overlayBase + offset.
#
# RECORD LAYOUT, from the build's own contiguity assertion (Build-AztMod.ps1 ~4691).
# The build throws if these ever stop being contiguous, so this table cannot drift
# silently -- but it is still the thing to re-check first if the numbers look wrong.
#     +0   'CAM1'          +4   frameNo       +8   time
#     +12  camIface        +16  camObj        +20  camType     +24  camParent
#     +28  camWorld  4x4   +92  camLocal 4x4
#     +156 movIface        +160 movObj        +164 movType     +168 movParent
#     +172 movWorld  4x4   +236 movLocal 4x4
#     +300 eyeY            +304 cue           +308 root
#     +312 delta1(obj1)    +316 delta2(obj2)      = 320 bytes
#
# NOTE ON WHICH MATRIX TO TRUST: camWorld was observed stuck at identity for a whole
# session while the MOVEMENT frame tracked correctly, so movWorld is the one reported
# as the pose. That is an unexplained engine behaviour, not a bug in this reader.

[CmdletBinding()]
param(
    [string]$Overlay = 'C:\Games\RaptorMod\game\GAME\AZRAEL\AZTCODE.BIN',
    [long]$OverlayBase = 0x133000,
    [int]$Samples = 12,
    [int]$IntervalMs = 400,
    [int]$RecLen = 320
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')

# ---- locate aztCamRec by its magic ------------------------------------------
if (-not (Test-Path $Overlay)) { throw "not found: $Overlay" }
$ovl = [IO.File]::ReadAllBytes($Overlay)
$MAGIC = [Text.Encoding]::ASCII.GetBytes('CAM1')
$off = -1
for ($i = 0; $i + 4 -le $ovl.Length; $i++) {
    if ($ovl[$i] -eq $MAGIC[0] -and $ovl[$i+1] -eq $MAGIC[1] -and $ovl[$i+2] -eq $MAGIC[2] -and $ovl[$i+3] -eq $MAGIC[3]) {
        $off = $i; break
    }
}
if ($off -lt 0) { throw "'CAM1' not found in $Overlay -- was the overlay built with ENABLE_CAM_LOG?" }
$recLin = $OverlayBase + $off
Write-Host ("aztCamRec: AZTCODE.BIN +0x{0:X} -> guest image-linear 0x{1:X}" -f $off, $recLin)

$g = Get-AztGuestBase
Write-Host ("guest RAM base 0x{0:X11} ({1:N0} MB), MemBase 0x{2:X11}, from {3} needles" -f `
            $g.RamBase, ($g.RamSize / 1MB), $g.MemBase, $g.Needles.Count)
Write-Host ""

function F32 { param($b, [int]$o) [BitConverter]::ToSingle($b, $o) }
function U32 { param($b, [int]$o) [BitConverter]::ToUInt32($b, $o) }

Write-Host ("{0,6} {1,12} {2,4} {3,10} {4,10} {5,10} {6,8} {7,8}" -f `
            'frame', 'time', 'cue', 'X', 'Y', 'Z', 'yaw', 'pitch')

$prev = $null
$changed = 0
for ($s = 0; $s -lt $Samples; $s++) {
    $rec = Read-AztGuest -Base $g -Lin $recLin -Length $RecLen
    if ($null -eq $rec -or $rec.Length -lt $RecLen) {
        Write-Host "  read failed (game closed?)" -ForegroundColor Yellow
        break
    }
    $frame = U32 $rec 4
    $time  = U32 $rec 8
    $cue   = U32 $rec 304

    # movement frame world matrix at +172, row-major, translation in the last row
    $m = 172
    $x = F32 $rec ($m + 48); $y = F32 $rec ($m + 52); $z = F32 $rec ($m + 56)
    # row 0 is the right vector, row 2 the forward vector
    $fx = F32 $rec ($m + 32); $fy = F32 $rec ($m + 36); $fz = F32 $rec ($m + 40)
    $yaw   = [Math]::Atan2($fx, $fz) * 180.0 / [Math]::PI
    $pitch = [Math]::Asin([Math]::Max(-1.0, [Math]::Min(1.0, $fy))) * 180.0 / [Math]::PI

    $key = "$frame|$x|$y|$z"
    if ($null -ne $prev -and $key -ne $prev) { $changed++ }
    $prev = $key

    Write-Host ("{0,6} {1,12} {2,4} {3,10:N2} {4,10:N2} {5,10:N2} {6,8:N1} {7,8:N1}" -f `
                $frame, $time, $cue, $x, $y, $z, $yaw, $pitch)
    if ($s -lt $Samples - 1) { Start-Sleep -Milliseconds $IntervalMs }
}

Write-Host ""
if ($changed -gt 0) {
    Write-Host ("LIVE: the record changed on {0} of {1} samples -- host code is reading the" -f $changed, ($Samples - 1)) -ForegroundColor Green
    Write-Host  "game's running state directly out of emulated RAM, with no emulator fork." -ForegroundColor Green
} else {
    Write-Host "Record never changed across the samples. Either the game is paused / sitting" -ForegroundColor Yellow
    Write-Host "in a menu, or the per-frame hook is not running. Move around and re-run." -ForegroundColor Yellow
}
