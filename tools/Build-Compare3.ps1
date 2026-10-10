# Build-Compare3.ps1 -- the remaster case as a single image.
#
#   .\tools\Build-Compare3.ps1
#
# Stacks three views of the SAME camera pose:
#   1. the game itself, cropped out of a DOSBox screenshot
#   2. the extracted scene rendered from the engine's own matrix, original textures
#   3. the same render with 4x Scale2x textures and bilinear sampling
#
# The DOSBox crop takes the top 75% of the frame because the 3D viewport is 1024x576 of
# a 1024x768 screen; the capture is saved at 2x, so it is downscaled back to 1024x576 with
# HighQualityBicubic. That resampling is the one place this image is not pixel-honest, and
# it works AGAINST row 1 (it softens the original slightly), so any advantage rows 2-3
# appear to have is understated, not overstated.
#
# Also emits a detail strip: one region at 2x, original art beside upscaled art, which is
# where the difference is actually legible.

[CmdletBinding()]
param(
    [string]$Capture = 'C:\Games\AzraelsTear-Modded\capture\image0007.png',
    [string]$Dir     = 'C:\Games\azrael-compare',
    [string]$Pose    = 'f2169',
    # detail crop, in 1024x576 render coordinates: the boulder and the right-hand wall
    [int[]]$Detail   = @(470, 300, 300, 170)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$VW, $VH = 1024, 576
$BAND = 30

function New-Canvas { param([int]$w, [int]$h)
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::FromArgb(12, 12, 14))
    , @($bmp, $g)
}

function Draw-Label { param($g, [string]$text, [int]$x, [int]$y, [int]$w)
    $font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 228, 205))
    $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(24, 24, 28))
    $g.FillRectangle($bg, $x, $y, $w, $BAND)
    $g.DrawString($text, $font, $brush, [single]($x + 10), [single]($y + 6))
    $font.Dispose(); $brush.Dispose(); $bg.Dispose()
}

# ---- source images ----------------------------------------------------------
$r1x = Join-Path $Dir ("render-{0}-1x.png" -f $Pose)
$r4x = Join-Path $Dir ("render-{0}-4x.png" -f $Pose)
foreach ($p in @($Capture, $r1x, $r4x)) {
    if (-not (Test-Path $p)) { throw "missing $p" }
}

$capIm = [System.Drawing.Image]::FromFile($Capture)
# the 3D viewport is the top 75% of the screen, whatever scale the capture was saved at
$srcH = [int]($capIm.Height * 0.75)
$capView = New-Object System.Drawing.Bitmap($VW, $VH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$cg = [System.Drawing.Graphics]::FromImage($capView)
$cg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$cg.DrawImage($capIm, (New-Object System.Drawing.Rectangle(0, 0, $VW, $VH)),
                      0, 0, $capIm.Width, $srcH, [System.Drawing.GraphicsUnit]::Pixel)
$cg.Dispose(); $capIm.Dispose()

$im1 = [System.Drawing.Image]::FromFile($r1x)
$im4 = [System.Drawing.Image]::FromFile($r4x)

# ---- stacked comparison -----------------------------------------------------
$rows = @(
    @{ Img = $capView; Text = '1.  THE GAME  -  DOSBox capture, 1024x576 viewport, original renderer' },
    @{ Img = $im1;     Text = '2.  EXTRACTED  -  same scene, engine''s own camera matrix, original 256px art' },
    @{ Img = $im4;     Text = '3.  EXTRACTED + 4x  -  identical geometry and camera, Scale2x art, bilinear' }
)
$H = ($VH + $BAND) * $rows.Count
$pair = New-Canvas $VW $H
$out = $pair[0]; $g = $pair[1]
$y = 0
foreach ($row in $rows) {
    Draw-Label $g $row.Text 0 $y $VW
    $y += $BAND
    $g.DrawImage($row.Img, (New-Object System.Drawing.Rectangle(0, $y, $VW, $VH)))
    $y += $VH
}
$g.Dispose()
$stackPath = Join-Path $Dir ("compare3-{0}.png" -f $Pose)
$out.Save($stackPath, [System.Drawing.Imaging.ImageFormat]::Png)
$out.Dispose()
Write-Host ("stacked  -> {0}" -f $stackPath) -ForegroundColor Green

# ---- detail strip, 2x --------------------------------------------------------
$dx, $dy, $dw, $dh = $Detail
$Z = 2
$dpair = New-Canvas (($dw * $Z) * 2 + 8) (($dh * $Z) + $BAND)
$dout = $dpair[0]; $dg = $dpair[1]
# nearest-neighbour for the ZOOM itself: this strip is about what the renders contain,
# so magnifying them must not add smoothing of its own
$dg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
Draw-Label $dg 'original 256px art' 0 0 ($dw * $Z)
Draw-Label $dg '4x Scale2x art' (($dw * $Z) + 8) 0 ($dw * $Z)
$srcRect = New-Object System.Drawing.Rectangle($dx, $dy, $dw, $dh)
$dg.DrawImage($im1, (New-Object System.Drawing.Rectangle(0, $BAND, ($dw * $Z), ($dh * $Z))),
              $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
$dg.DrawImage($im4, (New-Object System.Drawing.Rectangle((($dw * $Z) + 8), $BAND, ($dw * $Z), ($dh * $Z))),
              $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
$dg.Dispose()
$detailPath = Join-Path $Dir ("compare3-{0}-detail.png" -f $Pose)
$dout.Save($detailPath, [System.Drawing.Imaging.ImageFormat]::Png)
$dout.Dispose()
Write-Host ("detail   -> {0}" -f $detailPath) -ForegroundColor Green

$im1.Dispose(); $im4.Dispose(); $capView.Dispose()
