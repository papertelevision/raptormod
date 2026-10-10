# Build-SysMenu.ps1 -- generate the 14 system fold-out frames from one master.
#
#   .\src\Build-SysMenu.ps1                    # write SAVE00..SAVE13 PCX + previews
#   .\src\Build-SysMenu.ps1 -PreviewOnly
#
# WHY ONE MASTER. The stock set is not fourteen drawings. Diffing each state
# against SAVE06 shows music changes 703 px inside a 59x44 box and sfx 389 px
# inside 42x43 -- purely local. So the eight state frames are the same artwork
# with one control lit, and the six opening frames are the panel arriving. An AI
# asked for fourteen variants redraws the panel fourteen times and the animation
# strobes; generating them from one master is the only way they stay identical.
#
# THE PALETTE IS NOT OURS. These frames carry no palette of their own -- the
# loader (0x14A9F -> 0x38A20) reads pixels only, so every index is looked up in
# the live DAC that Reality Lab is also using. So the art is quantised against
# the LIVE palette assembled exactly as 0x28363 does it (hud3 base, h1 for
# 58..71, pal.pcx for 128..255) rather than getting a palette of its own.
# Index 0 is the transparency key.
[CmdletBinding()]
param(
    [int]$W = 412,
    [int]$H = 340,
    [string]$Master,
    [string]$OutDir,
    [string]$GameDir = 'C:\Games\AzraelsTear-Modded\GAME\AZRAEL',
    [switch]$PreviewOnly,
    # Writing into AztMod\art (the prebuilt set the installer ships) must leave
    # nothing but the PCX behind -- stray PNGs there are files the copy loop then
    # has to decide about.
    [switch]$NoPreview
)
$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs","$PSScriptRoot\..\tools\Quantize.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing

$design = Join-Path $PSScriptRoot '..\design\incoming\sysmenu'
if (-not $Master) { $Master = Join-Path $design 'master.png' }
if (-not $OutDir) { $OutDir = Join-Path $design 'out' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (-not (Test-Path $Master)) { throw "master not found: $Master" }

# The plates below were measured at 412x340; everything here is expressed in that
# reference space and scaled to whatever size is actually being built, so the
# panel can be resized without re-measuring anything. Build-AztMod scales the hot
# spots by the same ratio from the same reference.
$REF_W = 412.0
$SK = $W / $REF_W
function S([double]$v) { return [int][Math]::Round($v * $SK) }
# FROM THE ARTWORK'S WELL, via the same $SK Build-AztMod uses for $SYSMENU_SLIDER_*.
# These were Mindscape's 87x27 scaled by the ratio to the OLD fold-out, which left
# the bars undersized in the new render's ellipse. Keep these two REF numbers equal
# to $SYSMENU_SLIDER_REF_W / _REF_H in Build-AztMod.ps1 or the art and the click
# maths describe different tracks.
$BAR_REF_W = 202
$BAR_REF_H = 58
$BAR_W = [int][Math]::Round($BAR_REF_W * $SK)
$BAR_H = [int][Math]::Round($BAR_REF_H * $SK)

# ---- the live palette -------------------------------------------------------
# HUD3 carries the base palette, and AztMod REPLACES HUD3 -- so when the
# installer has already generated the reskinned one into the output directory,
# that is the palette this art will actually be looked up in. Reading the stock
# HUD3 instead would quantise against colours the DAC will not contain.
# H1 and PAL.PCX are never replaced, so they always come from the game.
$hud3Skin = Join-Path $OutDir 'HUD3.PCX'
$hud3Path = if (Test-Path $hud3Skin) { $hud3Skin } else { Join-Path $GameDir 'HUD3.PCX' }
$hud3 = [LeTool.Pcx]::Load($hud3Path)
$h1   = [LeTool.Pcx]::Load((Join-Path $GameDir 'H1.PCX'))
$palp = [LeTool.Pcx]::Load((Join-Path $GameDir 'PAL.PCX'))
$live = New-Object byte[] 768
[Array]::Copy($hud3.Palette, $live, 768)
for ($i = 58; $i -le 71; $i++)  { for ($k=0;$k -lt 3;$k++){ $live[$i*3+$k] = $h1.Palette[$i*3+$k] } }
for ($i = 128; $i -le 255; $i++){ for ($k=0;$k -lt 3;$k++){ $live[$i*3+$k] = $palp.Palette[($i-128)*3+$k] } }
$pal3 = New-Object byte[] (255*3)
for ($c = 0; $c -lt 255; $c++) { for ($k=0;$k -lt 3;$k++){ $pal3[$c*3+$k] = $live[($c+1)*3+$k] } }

# ---- the control plates, measured off the master ---------------------------
# Found by isolating bright warm-gold blobs and checking the boxes by eye
# (design\incoming\sysmenu\plates-detected.png). These drive BOTH the lit-state
# artwork and the hot-spot rectangles the build writes, so they are stated once,
# here, and exported for Build-AztMod rather than duplicated.
$NAMES = @('load','music','quit','sfx','save')
[int[]]$PX = @(134, 241, 177, 240, 137)
[int[]]$PY = @( 71, 106, 144, 187, 213)
[int[]]$PW = @( 59,  59,  38,  32,  59)
[int[]]$PH = @( 19,  20,  23,  20,  19)

# ---- master -> RGBA at final size ------------------------------------------
$img = [System.Drawing.Image]::FromFile($Master)
$base = New-Object System.Drawing.Bitmap ($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($base)
$g.InterpolationMode = 'HighQualityBicubic'
$g.PixelOffsetMode = 'Half'
$g.DrawImage($img, 0, 0, $W, $H)
$g.Dispose(); $img.Dispose()

function Get-Bgra($bmp) {
    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$bmp.Width,$bmp.Height)), 'ReadOnly', 'Format32bppArgb')
    $buf = New-Object byte[] ($bmp.Width*$bmp.Height*4)
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64()+$y*$d.Stride), $buf, $y*$bmp.Width*4, $bmp.Width*4)
    }
    $bmp.UnlockBits($d)
    return $buf
}

# Lit control: a warm rim plus a lift inside the plate. Drawn with Graphics on a
# clone so the highlight is anti-aliased into the artwork BEFORE quantisation --
# doing it on indices instead would posterise the rim into a hard stair.
# The opening frames are the panel SWINGING open on a hinge at its right edge,
# not a wipe. A flat panel rotating about a vertical axis projects to a width of
# `full * sin(angle)`, so compressing the master horizontally and pinning it to
# the right edge is the actual perspective of that motion -- which is what the
# stock frames depict, and why a straight wipe looked like a shutter instead.
#
# Derived from the ONE master, so every frame is the same artwork and the
# animation cannot strobe; hand-drawn or regenerated frames would each differ
# slightly and flicker at 14 fps.
function New-Frame([int]$lit, [string]$caption, [double]$open) {
    $bmp = New-Object System.Drawing.Bitmap ($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gg = [System.Drawing.Graphics]::FromImage($bmp)
    $gg.SmoothingMode = 'AntiAlias'
    if ($open -gt 0.0) {
        $gg.InterpolationMode = 'HighQualityBicubic'
        $gg.PixelOffsetMode = 'Half'
        [int]$fw = [Math]::Max(1, [int][Math]::Round($W * $open))
        $gg.DrawImage($base, ($W - $fw), 0, $fw, $H)      # pinned to the RIGHT edge
    }
    # Lit controls and captions only exist once the panel is fully open -- the
    # plate rectangles are measured in the open panel's own space.
    if ($open -lt 1.0) { $gg.Dispose(); return $bmp }
    if ($lit -ge 0) {
        [int]$x = S $PX[$lit]; [int]$y = S $PY[$lit]; [int]$w = S $PW[$lit]; [int]$h = S $PH[$lit]
        $glow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 255, 226, 150))
        $gg.FillRectangle($glow, ($x-2), ($y-2), ($w+4), ($h+4))
        $rim = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(235, 255, 238, 190), 2)
        $gg.DrawRectangle($rim, ($x-3), ($y-3), ($w+6), ($h+6))
    }
    if ($caption) {
        # THESE THREE NUMBERS ARE ALSO IN Build-AztMod.ps1, as $SYSMENU_CONFIRM -- the
        # caption is a BUTTON, so the hot spot has to land on the words. It used to be
        # hand-placed over there and sat 53 px below them, which made the quit
        # confirmation unclickable while every other control (all derived from
        # $SYSMENU_PLATES) worked. Anchor 150/266 and the 15pt Georgia Bold face are
        # what that rectangle is computed from; change one and change the other.
        $f = New-Object System.Drawing.Font ('Georgia', (15 * $SK), [System.Drawing.FontStyle]::Bold)
        $sz = $gg.MeasureString($caption, $f)
        [single]$cx = (S 150) - $sz.Width / 2
        [single]$cy = S 266
        $gg.DrawString($caption, $f, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,20,14,6))), ($cx+1), ($cy+1))
        $gg.DrawString($caption, $f, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,226,186,92))), $cx, $cy)
        $f.Dispose()
    }
    $gg.Dispose()
    return $bmp
}

function Save-Frame([int]$n, $bmp) {
    $bgra = Get-Bgra $bmp
    $idx = [LeTool.Quant]::Map($bgra, $W, $H, $pal3, 255, 1, 0)
    for ($i = 0; $i -lt $W*$H; $i++) { if ($bgra[$i*4+3] -lt 128) { $idx[$i] = 0 } }

    $pcx = New-Object LeTool.Pcx
    $pcx.Width = $W; $pcx.Height = $H
    $pcx.BitsPerPixel = 8; $pcx.Planes = 1; $pcx.BytesPerLine = $W
    $pcx.Pixels = $idx; $pcx.Palette = $live
    if (-not $PreviewOnly) { $pcx.SavePcx((Join-Path $OutDir ("SAVE{0:00}.PCX" -f $n))) }
    if (-not $NoPreview)   { $pcx.SavePng((Join-Path $OutDir ("preview-SAVE{0:00}.png" -f $n)), 1) }
}

# frame -> (lit control, caption, how far open)
[int[]]$LIT  = @(-1,-1,-1,-1,-1,-1, -1,  4,  0,  1,  3, -1,  4,  0)
$CAPS        = @('','','','','','',  '', '', '', '', '', 'Quit Game', 'confirm', 'confirm')
# sin(n/6 * 90 deg): the projected width of a panel opening at a constant rate.
# It eases out naturally -- fast while edge-on, slowing as it comes face-on --
# which is what makes it read as a hinge rather than a scale.
[double[]]$OPEN = @(0..5 | ForEach-Object { [Math]::Sin($_ / 6.0 * [Math]::PI / 2.0) }) + @(1.0)*8

for ($n = 0; $n -le 13; $n++) {
    $bmp = New-Frame $LIT[$n] $CAPS[$n] $OPEN[$n]
    Save-Frame $n $bmp
    $bmp.Dispose()
}
$base.Dispose()

# Hand the plate geometry to the build, so the hot spots and the lit artwork can
# never disagree about where a control is.
# ---- the two volume level bars ---------------------------------------------
# temp.pcx and bemp.pcx, stock 87x27, blitted as a partial source rect to show a
# fill level. They index the live palette like everything else here, so they are
# doubled by PIXEL REPLICATION rather than resampled: a filter would invent
# colours that are not in the DAC, and at 2x exactly there is nothing to gain
# from one. The build scales every constant in the slider chain to match.
foreach ($bar in @('TEMP.PCX','BEMP.PCX')) {
    # ALWAYS from the stock 87x27, never from a previously scaled copy -- rescaling
    # a rescale loses a row of the fill every time the panel size is nudged.
    $srcBar = Join-Path $GameDir $bar
    # In an INSTALLED game dir the file is already a scaled copy, so prefer the
    # installer's stock backup when there is one.
    if (Test-Path "$srcBar.aztbak") { $srcBar = "$srcBar.aztbak" }
    if (-not (Test-Path $srcBar)) { continue }
    $b = [LeTool.Pcx]::Load($srcBar)
    if ($b.Width -ne 87 -or $b.Height -ne 27) {
        throw ("{0} is {1}x{2}, not the stock 87x27 -- point -GameDir at unmodified art" -f $bar, $b.Width, $b.Height)
    }
    [int]$bw = $BAR_W
    [int]$bh = $BAR_H
    $bp = New-Object byte[] ($bw * $bh)
    # REDRAWN FROM THE SHAPE, not resampled pixel by pixel.
    #
    # A solid amber version was tried and rejected -- the bevelled ramp is what makes
    # these read as part of the fold-out. But nearest-neighbour scaling 87 -> 154 is
    # a 1.77x non-integer blow-up, and it shows: the diagonals turn into ragged
    # staircases and the segment stripes come out unevenly wide. That is the
    # "very pixelated" look.
    #
    # So reconstruct it instead. The bar is a SWOOSH of twelve vertical segments:
    #
    #   top edge    starts at y23 bottom-left, climbs to a peak of y1 around x22,
    #               falls back to y8 by x36 and runs flat to the right
    #   bottom edge flat at y26 out to x65, then climbs away to y12 at the right tip
    #   inks        59 66 60 67 61 68 62 70 63 71 64 21 -- alternating light/dark
    #
    # Taking top/bottom as continuous functions of x and evaluating them at the
    # DESTINATION resolution gives clean edges at any size, because the diagonal is
    # computed per output column rather than copied from a source pixel. Segment
    # inks are taken nearest-neighbour on purpose, so the stripe boundaries stay
    # hard vertical lines instead of being blurred across.
    [int]$sw = $b.Width; [int]$sh = $b.Height
    $srcTop = New-Object double[] $sw
    $srcBot = New-Object double[] $sw
    $srcInk = New-Object int[] $sw
    for ($x = 0; $x -lt $sw; $x++) {
        $t = -1; $bt = -1; $counts = @{}
        for ($y = 0; $y -lt $sh; $y++) {
            [int]$i = $b.Pixels[$y*$sw + $x]
            if ($i -ne 0) {
                if ($t -lt 0) { $t = $y }
                $bt = $y
                $counts[$i] = [int]$counts[$i] + 1
            }
        }
        $srcTop[$x] = $t; $srcBot[$x] = $bt
        $srcInk[$x] = if ($counts.Count) { ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key } else { 0 }
    }
    $vs = $bh / [double]$sh
    for ($x = 0; $x -lt $bw; $x++) {
        # Continuous source position of this output column's centre.
        $u  = (($x + 0.5) * $sw / [double]$bw) - 0.5
        $i0 = [int][Math]::Floor($u); $frac = $u - $i0
        if ($i0 -lt 0) { $i0 = 0; $frac = 0.0 }
        $i1 = [Math]::Min($sw - 1, $i0 + 1)
        $i0 = [Math]::Min($sw - 1, $i0)
        if ($srcTop[$i0] -lt 0 -or $srcTop[$i1] -lt 0) { continue }
        $tp = $srcTop[$i0] + ($srcTop[$i1] - $srcTop[$i0]) * $frac
        $bt = $srcBot[$i0] + ($srcBot[$i1] - $srcBot[$i0]) * $frac
        $ink = [int]$srcInk[[Math]::Min($sw - 1, [Math]::Max(0, [int][Math]::Round($u)))]
        if ($ink -eq 0) { continue }
        $y0d = [int][Math]::Round($tp * $vs)
        $y1d = [int][Math]::Round(($bt + 1) * $vs) - 1
        if ($y0d -lt 0) { $y0d = 0 }
        if ($y1d -gt $bh - 1) { $y1d = $bh - 1 }
        for ($y = $y0d; $y -le $y1d; $y++) { $bp[$y*$bw + $x] = [byte]$ink }
    }
    $ob = New-Object LeTool.Pcx
    $ob.Width = $bw; $ob.Height = $bh
    $ob.BitsPerPixel = 8; $ob.Planes = 1; $ob.BytesPerLine = $bw
    $ob.Pixels = $bp; $ob.Palette = $b.Palette
    $ob.SavePcx((Join-Path $OutDir $bar))
    "sysmenu: {0} {1}x{2} -> {3}x{4}" -f $bar, $b.Width, $b.Height, $bw, $bh
}

$meta = [ordered]@{
    width = $W; height = $H
    plates = @(for ($i=0; $i -lt 5; $i++) { [ordered]@{ name=$NAMES[$i]; x=$PX[$i]; y=$PY[$i]; w=$PW[$i]; h=$PH[$i] } })
}
if (-not $NoPreview) { $meta | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutDir 'plates.json') -Encoding utf8 }
"sysmenu: wrote 14 frames at {0}x{1} -> {2}" -f $W, $H, $OutDir
