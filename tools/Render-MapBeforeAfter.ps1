param([string]$Room, [double]$Yaw = 30, [double]$Pitch = 40, [double]$Zoom = 1.2, [string]$Out, [string]$Round = 'round-026')
# A map note's before | after: the 3D map of the room with the round's snapshot of rooms\<ROOM>.json (before) and the current one.
$ErrorActionPreference = 'Stop'
$mod = "C:\Program Files (x86)\Steam\steamapps\common\Azrael's Tear\AztMod"
$cur = Join-Path $mod "rooms\$Room.json"; $old = "C:\Games\azrael-render\rooms-history\$Round\$Room.json"
$sp = Split-Path $Out -Parent; $bak = Join-Path $sp "$Room.json.cur"
Copy-Item $cur $bak -Force
try {
    Copy-Item $old $cur -Force
    & powershell -NoProfile -File (Join-Path $mod 'tools\Test-GpuLook.ps1') -Room $Room -Map -MapYaw $Yaw -MapPitch $Pitch -MapZoom $Zoom -Width 960 -Height 540 -Out (Join-Path $sp "$Room-before.png") | Out-Null
} finally { Copy-Item $bak $cur -Force }
& powershell -NoProfile -File (Join-Path $mod 'tools\Test-GpuLook.ps1') -Room $Room -Map -MapYaw $Yaw -MapPitch $Pitch -MapZoom $Zoom -Width 960 -Height 540 -Out (Join-Path $sp "$Room-after.png") | Select-String 'map:' | ForEach-Object { $_.Line }
Add-Type -AssemblyName System.Drawing
$a = [Drawing.Bitmap]::FromFile((Join-Path $sp "$Room-before.png")); $b = [Drawing.Bitmap]::FromFile((Join-Path $sp "$Room-after.png"))
$s = New-Object Drawing.Bitmap 1924, 540; $g = [Drawing.Graphics]::FromImage($s); $g.Clear([Drawing.Color]::Black)
$g.DrawImage($a, 0, 0, 960, 540); $g.DrawImage($b, 964, 0, 960, 540)
$f = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$g.DrawString('MAP BEFORE', $f, [Drawing.Brushes]::White, 12, 8); $g.DrawString('MAP AFTER', $f, [Drawing.Brushes]::White, 976, 8)
$a.Dispose(); $b.Dispose(); $s.Save($Out); $g.Dispose(); $s.Dispose()
"saved $Out"
