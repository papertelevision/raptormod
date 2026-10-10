# Set-SaveRoom.ps1 -- read and edit the room / player position in a save slot, to warp.
#
#   .\tools\Set-SaveRoom.ps1 -Show                     # what room is each slot in?
#   .\tools\Set-SaveRoom.ps1 -Slot 3 -Room 12          # put slot 3 in room 12
#   .\tools\Set-SaveRoom.ps1 -Slot 3 -FromSlot 1       # copy room AND position out of slot 1
#   .\tools\Set-SaveRoom.ps1 -Slot 3 -Room 12 -X -63.7 -Y -28.1 -Z 32.5
#   .\tools\Set-SaveRoom.ps1 -Slot 3 -Restore          # undo
#
# HOW THE FIELDS WERE FOUND. Three saves taken A -> B -> A, one room apart with nothing else
# touched, differ in only 19 bytes. The fields sit a fixed distance from END OF FILE, which
# matters because saves vary in length (16,756 / 16,834 / 16,884 / 17,524 seen) and the
# variable-length section is early -- SAVE1 and SAVE2 first diverge at 0x10CF, so any offset
# measured from the START of the file would be wrong for a different-sized save.
#
#     room        uint16   at  len - 926
#     X, Y, Z     float64  at  len - 918, +8, +16
#
# Cross-checked on all seven shipped/played saves: every start-of-game save reads room 0, the
# one-room walk reads 1, and SAVE65535 (the save known to be elsewhere) reads 100.
#
# THERE IS NO CHECKSUM. The trailer's last 16 bytes are four 32-bit slots -- three a repeated
# constant, one a 16-bit counter -- and neither sum-8 nor xor-8 over the file reproduces it. So
# an edited save is not rejected for integrity.
#
# POSITION MATTERS. Setting a room without setting coordinates leaves you at the previous room's
# coordinates, which can drop you inside geometry or outside the level. Prefer -FromSlot, or
# supply coordinates you have actually seen in a save for that room. -Show prints them.
#
# CAVEAT: this moves you, it does not advance the story. Flags, inventory and conversation state
# are whatever the slot already had, so a dialogue option gated on story progress may not appear.

[CmdletBinding()]
param(
    [int]$Slot = -1,
    [int]$Room = -1,
    [int]$FromSlot = -1,
    [string]$Scene,            # compute a standable position from that room's scene geometry
    [double]$X = [double]::NaN,
    [double]$Y = [double]::NaN,
    [double]$Z = [double]::NaN,
    [switch]$Show,
    [switch]$Restore,
    [string]$SaveDir = 'C:\Games\AzraelsTear-Modded\GAME\AZRAEL'
)

$ErrorActionPreference = 'Stop'
$ROOM_FROM_END = 926
$POS_FROM_END  = 918

function Slot-Path([int]$n) {
    # DOS 8.3 truncates SAVE65535.DAT to SAVE6553.DAT
    $name = if ($n -eq 65535) { 'SAVE6553.DAT' } else { "SAVE$n.DAT" }
    Join-Path $SaveDir $name
}
function Read-Loc([string]$p) {
    $b = [IO.File]::ReadAllBytes($p)
    [pscustomobject]@{
        Path = $p; Len = $b.Length
        Room = [BitConverter]::ToUInt16($b, $b.Length - $ROOM_FROM_END)
        X = [BitConverter]::ToDouble($b, $b.Length - $POS_FROM_END)
        Y = [BitConverter]::ToDouble($b, $b.Length - $POS_FROM_END + 8)
        Z = [BitConverter]::ToDouble($b, $b.Length - $POS_FROM_END + 16)
    }
}

if ($Show -or ($Slot -lt 0)) {
    Write-Host ''
    Write-Host ('{0,-14} {1,7} {2,6}   {3,11} {4,11} {5,11}' -f 'slot','bytes','room','X','Y','Z')
    foreach ($n in 0,1,2,3,4,6,65535) {
        $p = Slot-Path $n
        if (-not (Test-Path $p)) { continue }
        $l = Read-Loc $p
        Write-Host ('{0,-14} {1,7:N0} {2,6}   {3,11:N1} {4,11:N1} {5,11:N1}' -f `
                    ("slot $n"), $l.Len, $l.Room, $l.X, $l.Y, $l.Z)
    }
    Write-Host ''
    Write-Host 'edit with:  -Slot <n> -Room <id>   (add -FromSlot <n> to copy position too)'
    return
}

$path = Slot-Path $Slot
if (-not (Test-Path $path)) { throw "no such slot: $path" }
$bak = "$path.roombak"

if ($Restore) {
    if (-not (Test-Path $bak)) { Write-Host "slot $Slot was never edited"; return }
    Copy-Item $bak $path -Force
    [IO.File]::Delete($bak)
    $l = Read-Loc $path
    Write-Host ("slot {0} restored -- room {1} at ({2:N1}, {3:N1}, {4:N1})" -f $Slot,$l.Room,$l.X,$l.Y,$l.Z) -ForegroundColor Green
    return
}

$before = Read-Loc $path
Write-Host ("slot {0} is currently room {1} at ({2:N1}, {3:N1}, {4:N1})" -f `
            $Slot, $before.Room, $before.X, $before.Y, $before.Z)

if ($FromSlot -ge 0) {
    $srcPath = Slot-Path $FromSlot
    if (-not (Test-Path $srcPath)) { throw "no such source slot: $srcPath" }
    $s = Read-Loc $srcPath
    if ($Room -lt 0) { $Room = $s.Room }
    if ([double]::IsNaN($X)) { $X = $s.X }
    if ([double]::IsNaN($Y)) { $Y = $s.Y }
    if ([double]::IsNaN($Z)) { $Z = $s.Z }
    Write-Host ("copying from slot {0}: room {1} at ({2:N1}, {3:N1}, {4:N1})" -f $FromSlot,$s.Room,$s.X,$s.Y,$s.Z)
}

# A computed spawn beats carrying the old room's coordinates over, which is what strands you
# outside the geometry. See Get-RoomSpawn.ps1 for how the floor height is derived.
if ($Scene) {
    $sp = & (Join-Path $PSScriptRoot 'Get-RoomSpawn.ps1') -Scene $Scene
    if ($sp) {
        $X = $sp.X; $Y = $sp.Y; $Z = $sp.Z
        Write-Host ("spawn computed from {0}.xaf (floor '{1}'): ({2:N1}, {3:N1}, {4:N1})" -f `
                    $sp.Scene, $sp.Floor, $X, $Y, $Z)
        if (-not $sp.Named) {
            Write-Host '  ! that scene has no object actually named floor*, so this position is a guess' -ForegroundColor Yellow
        }
    }
}

if ($Room -lt 0) { throw 'nothing to do -- give -Room, -FromSlot or -Scene' }
if ($Room -gt 65535) { throw "room id $Room does not fit a uint16" }

if ([double]::IsNaN($X) -or [double]::IsNaN($Y) -or [double]::IsNaN($Z)) {
    Write-Host '  ! no coordinates given, so you keep this slot''s existing position.' -ForegroundColor Yellow
    Write-Host '    If that position is not inside the new room you may spawn in geometry.' -ForegroundColor Yellow
}

if (-not (Test-Path $bak)) { Copy-Item $path $bak }     # created once, never overwritten
$b = [IO.File]::ReadAllBytes($path)
[Array]::Copy([BitConverter]::GetBytes([uint16]$Room), 0, $b, $b.Length - $ROOM_FROM_END, 2)
if (-not [double]::IsNaN($X)) { [Array]::Copy([BitConverter]::GetBytes($X), 0, $b, $b.Length - $POS_FROM_END,      8) }
if (-not [double]::IsNaN($Y)) { [Array]::Copy([BitConverter]::GetBytes($Y), 0, $b, $b.Length - $POS_FROM_END +  8, 8) }
if (-not [double]::IsNaN($Z)) { [Array]::Copy([BitConverter]::GetBytes($Z), 0, $b, $b.Length - $POS_FROM_END + 16, 8) }
[IO.File]::WriteAllBytes($path, $b)

$after = Read-Loc $path
Write-Host ("slot {0} is now  room {1} at ({2:N1}, {3:N1}, {4:N1})" -f `
            $Slot, $after.Room, $after.X, $after.Y, $after.Z) -ForegroundColor Green
Write-Host ("  backup: {0}   undo with  -Slot {1} -Restore" -f (Split-Path $bak -Leaf), $Slot) -ForegroundColor DarkGray
