# Render-RoomView.ps1 -- one room view through the true-colour renderer, offline (2026-10-08): the room's real look --
# its lights, volumetric fog, mist and shadows, from its current settings (rooms\<ROOM>.json) -- flashlight off and on,
# side by side, labelled. Used by Room Review's "Render this view" button and by Claude's note replies.
#
#   .\tools\Render-RoomView.ps1 -Room CORICORI -X -101.8 -Y 50 -Z 113.3 -Yaw 135 -Pitch -12 -Out C:\temp\view.png
param(
    [Parameter(Mandatory)][string]$Room,
    [Parameter(Mandatory)][double]$X, [Parameter(Mandatory)][double]$Y, [Parameter(Mandatory)][double]$Z,
    [Parameter(Mandatory)][double]$Yaw, [Parameter(Mandatory)][double]$Pitch,
    [Parameter(Mandatory)][string]$Out,
    [int]$Width = 960, [int]$Height = 540,
    # how long the particles (steam, embers, drips) build up first; at 0.3 s (until round 7) a steam room showed almost none
    [double]$Seconds = 4
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tmp = Join-Path $env:TEMP ('rrv-{0}-{1}' -f $Room.ToUpperInvariant(), [Guid]::NewGuid().ToString('N').Substring(0, 8))
$shots = @()
foreach ($lamp in @($false, $true)) {
    # Test-GpuLook: the renderer's GPU path; steady torches (no flicker), standing still
    $o = '{0}-{1}.png' -f $tmp, $(if ($lamp) { 'on' } else { 'off' })
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $toolDir 'Test-GpuLook.ps1'), '-Room', $Room.ToUpperInvariant(),
        '-X', $X, '-Y', $Y, '-Z', $Z, '-Yaw', $Yaw, '-Pitch', $Pitch, '-Walk', 0, '-Seconds', $Seconds, '-Width', $Width, '-Height', $Height, '-Steady', '-Out', $o)
    if (-not $lamp) { $a += '-LampOff' }
    & powershell @a | Out-Null
    if (-not (Test-Path $o)) { throw "the render did not come out ($o)" }
    $shots += $o
}
Add-Type -AssemblyName System.Drawing
$l = [Drawing.Image]::FromFile($shots[0]); $r = [Drawing.Image]::FromFile($shots[1])
try {
    $pic = New-Object Drawing.Bitmap ($l.Width + $r.Width + 6), $l.Height; $g = [Drawing.Graphics]::FromImage($pic)
    $g.Clear([Drawing.Color]::Black); $g.DrawImage($l, 0, 0, $l.Width, $l.Height); $g.DrawImage($r, $l.Width + 6, 0, $r.Width, $r.Height)
    $font = New-Object Drawing.Font 'Segoe UI', 13, ([Drawing.FontStyle]::Bold)
    foreach ($lab in @(@('flashlight off', 8), @('flashlight on', $l.Width + 14))) {
        $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(150, 0, 0, 0))), $lab[1] - 4, 6, 130, 24)
        $g.DrawString($lab[0], $font, [Drawing.Brushes]::Gold, $lab[1], 7)
    }
    $g.Dispose()
    $dir = Split-Path -Parent $Out; if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $pic.Save($Out, [Drawing.Imaging.ImageFormat]::Png); $pic.Dispose()
} finally { $l.Dispose(); $r.Dispose(); foreach ($s in $shots) { Remove-Item -LiteralPath $s -ErrorAction SilentlyContinue } }
