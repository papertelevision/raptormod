# Build-Books.ps1 -- rescale the readable book/scroll pages to the screen size.
#
#   .\src\Build-Books.ps1                      # rescale in place to 1024x768
#   .\src\Build-Books.ps1 -Width 800 -Height 600
#   .\src\Build-Books.ps1 -InDir design\incoming\flat-art\books   # use replacements
#   .\src\Build-Books.ps1 -Revert              # put the originals back
#
# WHY. Book pages ship at 640x480 and the game blits them 1:1 into the
# full-screen surface, so raising the screen resolution makes them physically
# SMALLER on screen -- 86% of the width at the original 640x480, 69% at 800x600,
# 54% at 1024x768. AztMod's `book-centre` patch only ever centred them, which
# fixes the position and does nothing about the size. Rescaling the artwork is
# the fix, and it is better than a runtime scaler would be: it happens once, at
# install time, with a proper resampler, and it costs no code cave.
#
# Once the pages ARE screen-sized, the page lands at (0,0) -- which is what the
# stock code already does -- so `book-centre` drops out of the build entirely.
# Build-AztMod's $BOOK_FULLSCREEN keeps the two in step; do not change one
# without the other, or pages sit in the top-left corner instead of centred.
#
# PAGES MAY ONLY USE PALETTE INDICES 128..255. Measured, not assumed: every stock
# page has zero pixels below 128. The low half belongs to whatever else is
# resident while the page is up, and writing into it is what turned an earlier
# replacement into a screenful of dithering dots. So the quantiser gets 128
# colours at base index 128, and entries 0..127 are copied from the stock page
# untouched.
[CmdletBinding()]
param(
    [int]$Width  = 1024,
    [int]$Height = 768,
    # How much of the screen HEIGHT the page itself occupies. The canvas stays exactly
    # $Width x $Height -- the page is scaled down inside it and the rest is black, so the
    # game still blits a screen-sized image at (0,0) and no code changes. 100 = the old
    # full-bleed behaviour, byte for byte.
    #
    # Full bleed made the pages read as wallpaper rather than as a page being held up: a
    # scan with no margin has nothing to tell the eye where the paper ends and the screen
    # begins. Both axes are scaled by the SAME factor, so the page keeps the shape it had.
    [int]$FillPct = 80,
    [string]$BookDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX\BOOKS',
    [string]$InDir,            # optional PNG replacements, named <stem>.png
    [string[]]$Only,           # process only these stems; everything else is left alone
    [switch]$Revert
)
if ($FillPct -lt 10 -or $FillPct -gt 100) { throw "-FillPct must be 10..100; got $FillPct" }

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs"  -ReferencedAssemblies System.Drawing
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $BookDir)) { throw "book folder not found: $BookDir" }

# The pristine page is kept beside the rescaled one as <name>.PCX.src, so a
# re-run rescales from the ORIGINAL rather than from its own output -- rescaling
# a rescale loses detail every time. It is also deliberately NOT '.orig': that
# suffix is already used for the pre-replacement stock art, and a page the user
# has replaced must keep its replacement as the source.
function Source-Of($pcx) {
    $src = "$pcx.src"
    if (Test-Path $src) { return $src }
    return $pcx
}

if ($Revert) {
    $n = 0
    foreach ($f in Get-ChildItem $BookDir -Filter '*.PCX.src' -File) {
        $dest = $f.FullName -replace '\.src$',''
        Copy-Item $f.FullName $dest -Force
        Remove-Item $f.FullName -Force
        $n++
    }
    "reverted {0} page(s) to their pre-rescale size" -f $n
    return
}

# PCX (or PNG) -> 32bpp BGRA at the target size, resampled properly.
# The PAGE ITSELF, at content size -- not the full canvas. Quantising the content alone
# matters: with the black border included, median cut would spend one of its 128 boxes on
# pure black (about a third of the pixels at 80%), and the border has to come out EXACTLY
# black anyway rather than near-black, so it is composited afterwards with a reserved index.
$CONTENT_W = [int]($Width  * $FillPct / 100)
$CONTENT_H = [int]($Height * $FillPct / 100)
$CONTENT_X = [int](($Width  - $CONTENT_W) / 2)
$CONTENT_Y = [int](($Height - $CONTENT_H) / 2)

function Scale-ToBgra($loader, [ref]$outW, [ref]$outH) {
    $bmp = New-Object System.Drawing.Bitmap($CONTENT_W, $CONTENT_H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.DrawImage($loader, 0, 0, $CONTENT_W, $CONTENT_H)
    $g.Dispose()
    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$CONTENT_W,$CONTENT_H)),
                       [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                       [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $buf = New-Object byte[] ($CONTENT_W * $CONTENT_H * 4)
    for ($y = 0; $y -lt $CONTENT_H; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride),
            $buf, $y*$CONTENT_W*4, $CONTENT_W*4)
    }
    $bmp.UnlockBits($d); $bmp.Dispose()
    $outW.Value = $CONTENT_W; $outH.Value = $CONTENT_H
    return $buf
}

# an indexed Pcx -> a drawable 32bpp Bitmap
function Pcx-ToBitmap($p) {
    $bmp = New-Object System.Drawing.Bitmap($p.Width, $p.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$p.Width,$p.Height)),
                       [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                       [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $row = New-Object byte[] ($p.Width * 4)
    for ($y = 0; $y -lt $p.Height; $y++) {
        for ($x = 0; $x -lt $p.Width; $x++) {
            $i = $p.Pixels[$y*$p.Width + $x]
            $row[$x*4]   = $p.Palette[$i*3+2]     # B
            $row[$x*4+1] = $p.Palette[$i*3+1]     # G
            $row[$x*4+2] = $p.Palette[$i*3]       # R
            $row[$x*4+3] = 255
        }
        [System.Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride), $row.Length)
    }
    $bmp.UnlockBits($d)
    return $bmp
}

$done = 0; $skipped = 0
# Pages with no replacement PNG, so they were upscaled from the shipped 640x480 art.
# REPORTED, not silent. The fallback is correct behaviour -- a page nobody has re-drawn
# must still come out screen-sized -- but it is indistinguishable in the output from a
# page built off a 2048x1536 source, so a name that quietly stops matching (a typo, a
# "(1)" suffix, a file left in a subfolder) costs that page its resolution with nothing
# to show for it. Nine pages turned out to be in exactly that state.
$fellBack = @()
foreach ($f in Get-ChildItem $BookDir -Filter '*.PCX' -File | Sort-Object Name) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    if ($f.Length -eq 0) { $skipped++; continue }
    # -Only exists because the skip test below compares against the .src, which is the
    # PRISTINE 640x480 page -- so a plain re-run does not consider an already-rescaled page
    # done, and would rebuild all 91 of them to replace one.
    if ($Only -and ($Only -notcontains $stem)) { $skipped++; continue }

    $srcPath = Source-Of $f.FullName
    try { $src = [LeTool.Pcx]::Load($srcPath) } catch { $skipped++; continue }
    if ($src.BitsPerPixel -ne 8 -or $src.Planes -ne 1) { $skipped++; continue }

    # a replacement PNG wins over the shipped page, at whatever size it comes in
    $png = $null
    if ($InDir) {
        $cand = Join-Path $InDir ("{0}.png" -f $stem)
        if (Test-Path $cand) { $png = $cand } else { $fellBack += $stem }
    }

    if (-not $png -and $src.Width -eq $Width -and $src.Height -eq $Height) { $skipped++; continue }

    if ($png) {
        $img = [System.Drawing.Image]::FromFile($png)
    } else {
        $img = Pcx-ToBitmap $src
    }
    $w = 0; $h = 0
    $bgra = Scale-ToBgra $img ([ref]$w) ([ref]$h)
    $img.Dispose()

    # Colours at base index 128 -- see the header. Dithering is on: these are
    # photographic parchment scans and banding shows badly on flat vellum.
    #
    # ONE FEWER COLOUR WHEN THERE IS A BORDER, because index 255 is reserved for it. The
    # border must be EXACTLY #000000: a near-black from the quantiser would show as a faint
    # grey frame against the real black of the screen around it, which is more obvious than
    # losing one colour out of 128 on a parchment scan.
    $nCol = $(if ($FillPct -lt 100) { 127 } else { 128 })
    $pal3 = [LeTool.Quant]::MedianCut($bgra, $w, $h, $nCol)
    $idx  = [LeTool.Quant]::Map($bgra, $w, $h, $pal3, $nCol, 128, 1)

    # keep the stock low half exactly as it was; only 128..255 are ours
    $pal = New-Object byte[] 768
    [Array]::Copy($src.Palette, 0, $pal, 0, 384)
    for ($c = 0; $c -lt $nCol; $c++) {
        $pal[(128+$c)*3]     = $pal3[$c*3]
        $pal[(128+$c)*3 + 1] = $pal3[$c*3+1]
        $pal[(128+$c)*3 + 2] = $pal3[$c*3+2]
    }

    # Compose onto the full-size canvas. The game still gets a screen-sized page at (0,0);
    # only the picture inside it got smaller, so `book-centre` stays dropped and nothing
    # in the build has to know about this.
    if ($FillPct -lt 100) {
        $pal[255*3] = 0; $pal[255*3+1] = 0; $pal[255*3+2] = 0      # the reserved border black
        $canvas = New-Object byte[] ($Width * $Height)
        for ($i = 0; $i -lt $canvas.Length; $i++) { $canvas[$i] = 255 }
        for ($y = 0; $y -lt $h; $y++) {
            [Array]::Copy($idx, $y*$w, $canvas, ($CONTENT_Y + $y)*$Width + $CONTENT_X, $w)
        }
        $idx = $canvas
        $w = $Width; $h = $Height
    }

    if (-not (Test-Path "$($f.FullName).src")) { Copy-Item $f.FullName "$($f.FullName).src" }

    $out = New-Object LeTool.Pcx
    $out.Width = $w; $out.Height = $h
    $out.BitsPerPixel = 8; $out.Planes = 1; $out.BytesPerLine = $w
    $out.Pixels = $idx; $out.Palette = $pal
    $out.SavePcx($f.FullName)
    $done++
}

if ($FillPct -lt 100) {
    "books: rescaled {0} page(s) to {1}x{2} canvas, page {3}x{4} at ({5},{6}) on black, skipped {7}" -f `
        $done, $Width, $Height, $CONTENT_W, $CONTENT_H, $CONTENT_X, $CONTENT_Y, $skipped
} else {
    "books: rescaled {0} page(s) to {1}x{2}, skipped {3}" -f $done, $Width, $Height, $skipped
}
if ($InDir) {
    $fromPng = $done - $fellBack.Count
    "books: {0} page(s) from {1}, {2} upscaled from the shipped 640x480 art" -f $fromPng, $InDir, $fellBack.Count
    if ($fellBack.Count) { "books: no replacement for -- {0}" -f (($fellBack | Sort-Object) -join ', ') }
}
