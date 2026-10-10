# Build-HudKeys.ps1 -- the widescreen panel's text-area keys (Josh, 2026-10-06).
#
# The panel render (two_panels_reference.png) has four plain square keys beside the text screen.
# Josh's later text-area render has integrated round brass keys in a riveted column, but that
# render is at a different scale from the panel. So the COLUMN alone is lifted out of it and
# scaled into the panel's own column, in both the unlit and the lit panel; everything else stays
# the panel's own art. The result is the reference Build-HudWide.ps1 reads.
[CmdletBinding()]
param(
    [string]$Panel = "$PSScriptRoot\..\design\incoming\hud\two_panels_reference.png",
    [string]$Keys  = "$PSScriptRoot\..\design\incoming\hud\textarea\textarea-collapsed.png",
    [string]$Out   = "$PSScriptRoot\..\design\incoming\hud\two_panels_reference-keys.png",
    [int]$LitDy = 321                                   # the lit panel is this many rows below the unlit one
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
# the column in the key render (x, y, w, h): four plates from the expand key's top to the replay key's bottom
$SRC = New-Object Drawing.Rectangle 730, 122, 95, 385
# where it goes in the panel (the old column's keys span x 1820..1860, y 150..330); uniform scale
$SCALE = 0.51
$dw = [int][Math]::Round($SRC.Width * $SCALE); $dh = [int][Math]::Round($SRC.Height * $SCALE)
$DX = 1842 - [int]($dw / 2); $DY = 140
# soft left and right edges, so the plate meets the panel's column frame without a seam
$keyImg = [Drawing.Bitmap]::new((Resolve-Path $Keys).Path)
$col = New-Object Drawing.Bitmap $dw, $dh, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [Drawing.Graphics]::FromImage($col); $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
$g.DrawImage($keyImg, (New-Object Drawing.Rectangle 0, 0, $dw, $dh), $SRC, 'Pixel'); $g.Dispose(); $keyImg.Dispose()
$FEATHER = 3
for ($x = 0; $x -lt $FEATHER; $x++) { $k = ($x + 1) / ($FEATHER + 1)
    foreach ($xx in $x, ($dw - 1 - $x)) { for ($y = 0; $y -lt $dh; $y++) { $c = $col.GetPixel($xx, $y); $col.SetPixel($xx, $y, [Drawing.Color]::FromArgb([int]($c.A * $k), $c.R, $c.G, $c.B)) } } }
$pan = [Drawing.Bitmap]::new((Resolve-Path $Panel).Path)
$outImg = New-Object Drawing.Bitmap $pan.Width, $pan.Height, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [Drawing.Graphics]::FromImage($outImg); $g.DrawImage($pan, 0, 0, $pan.Width, $pan.Height)
$g.CompositingMode = 'SourceOver'
foreach ($panelDy in 0, $LitDy) { $g.DrawImage($col, $DX, $DY + $panelDy, $dw, $dh) }
$g.Dispose(); $outImg.Save($Out, [Drawing.Imaging.ImageFormat]::Png); $outImg.Dispose(); $pan.Dispose(); $col.Dispose()
Write-Host ("keys: the column {0}x{1} from the text-area render -> {2}x{3} at ({4},{5}) in both panels -> {6}" -f $SRC.Width, $SRC.Height, $dw, $dh, $DX, $DY, (Split-Path $Out -Leaf))
# where each key landed (art px), for Build-HudWide
$map = { param($y0, $y1) [int][Math]::Round($DY + ($y0 - $SRC.Y) * $SCALE), [int][Math]::Round($DY + ($y1 - $SRC.Y) * $SCALE) }
foreach ($k in @(@('expand', 122, 222), @('up', 280, 360), @('down', 360, 425), @('replay', 425, 505), @('gap', 222, 280))) { $r = & $map $k[1] $k[2]; "  {0,-7} rows {1}..{2}, x {3}..{4}" -f $k[0], $r[0], $r[1], $DX, ($DX + $dw) }
