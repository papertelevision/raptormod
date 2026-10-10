# Build-Screens.ps1 -- full-screen UI art that is neither HUD nor book page.
#
#   .\src\Build-Screens.ps1 -Import -InDir C:\Games\azrael-gfx\screens
#   .\src\Build-Screens.ps1 -Import -InDir ... -Only HELP
#   .\src\Build-Screens.ps1 -Revert
#
# WHY THESE NEED REPLACING AT ALL, beyond looking better: both are loaded at (0,0) by
# 0x38A20 into a surface the mod has already enlarged to the full screen, and the surface
# allocator at 0x37AE0 is a bare malloc that never clears (see Build-Credits.ps1 for the
# full trace). A 640x480 image in a 1024x768 surface therefore paints the top-left corner
# and leaves the rest showing uninitialised heap. Matching the screen size IS the fix.
#
#   HELP.PCX     AZTEX\MAPS, loaded by 0x1EF8A -- the F1 help screen. Shares function
#                0x1EC7A with the automap: edx = -1 picks help.pcx, anything else loads
#                mapbkgrd.pcx. MAPBKGRD is already generated at screen size by Build-HudArt,
#                which is what establishes that this surface is full-screen.
#   NEWLOGO.PCX  AZRAEL, the end/publisher screen. R.EXE draws it, not TM.EXE.
#
# TWO DIFFERENT PALETTE RULES, and getting them the wrong way round is silent:
#
#   NEWLOGO is SELF-PALETTED -- it calls SetWholePalette and nothing else is on screen, so
#   all 256 entries are its own and it gets a fresh optimal palette. Same rule as TITLE.PCX
#   (Build-Title.ps1), which is where that was established from the code.
#
#   HELP obeys the BOOK RULE: indices 128..255 only. Measured on the stock file, which uses
#   exactly 128 contiguous indices starting at 128 and nothing at or below 127 -- identical
#   to every stock book page. The low half belongs to whatever else is on screen, so the
#   quantiser gets 128 colours at base index 128 and entries 0..127 are copied from the
#   stock image untouched. Giving this one a fresh 256-colour palette would recolour the
#   HUD the moment F1 is pressed.
#
# DESTINATION. Everything goes through art\ rather than straight into the game folder, so
# the files get .aztbak backups, come back on -Revert, and are swept when a later build
# stops shipping them. art\_AZTEX\ is Apply-AztMod's redirect for the texture tree -- writing
# HELP.PCX directly into GAME\AZTEX\MAPS would work until the next install and then quietly
# persist forever with no way back. (Build-Title.ps1 still writes into the game folder, which
# is exactly why NEWLOGO.PCX shows up as "restored stock" in every install log.)
[CmdletBinding()]
param(
    [switch]$Import,
    [switch]$Revert,
    [string]$InDir  = 'C:\Games\azrael-gfx\screens',
    [string]$GameDir = 'C:\Games\AzraelsTear-Modded\GAME',
    [string]$ArtDir  = (Join-Path $PSScriptRoot '..\art'),
    [string[]]$Only,
    [int]$Width  = 0,          # 0 = take the mod's own screen size from the manifest
    [int]$Height = 0,
    # How much of the screen HEIGHT an INSET image occupies; the canvas stays screen-sized
    # and the rest is black. Only images whose rule says inset=$true are affected -- a logo
    # or title screen is meant to bleed, and shrinking one would just float it in a box.
    [int]$FillPct = 80,
    [switch]$NoDither
)
if ($FillPct -lt 10 -or $FillPct -gt 100) { throw "-FillPct must be 10..100; got $FillPct" }

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs"  -ReferencedAssemblies System.Drawing
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing

$ArtDir = (Resolve-Path $ArtDir).Path

# png      is the name Export-Images.ps1 gives it, so a re-export round-trips
# stock    where the pristine game file lives, relative to GameDir
# art      where our output goes under art\, which decides where it installs
# palette  'self' = fresh 256;  'high128' = 128 colours at base index 128
# inset    $true  = scaled to $FillPct of the height and centred on black
#
# HELP is inset and NEWLOGO is not, and that is the in-game / title distinction rather than
# a judgement about either picture: HELP is something you call up mid-play and read, so it
# wants a margin the way the book pages do. NEWLOGO is a full-bleed logo card, and it is
# already black around the type -- an inset would shrink the wordmark and change nothing
# else. The credits backdrop is deliberately not here at all: it is a watermark meant to
# reach the screen edges, and Build-Credits.ps1 owns it.
$SCREENS = @(
    @{ key='HELP';    png='MAPS__HELP.png';      stock='AZTEX\MAPS\HELP.PCX';
       art='_AZTEX\MAPS\HELP.PCX';               palette='high128'; inset=$true }
    @{ key='NEWLOGO'; png='AZRAEL__NEWLOGO.png'; stock='AZRAEL\NEWLOGO.PCX';
       art='NEWLOGO.PCX';                        palette='self';    inset=$false }
)

if ($Revert) {
    $n = 0
    foreach ($s in $SCREENS) {
        if ($Only -and ($Only -notcontains $s.key)) { continue }
        $p = Join-Path $ArtDir $s.art
        if (Test-Path $p) { Remove-Item $p; Write-Host ("removed art\{0}" -f $s.art) -ForegroundColor Green; $n++ }
    }
    if ($n) { Write-Host 'the next install puts the stock images back' } else { Write-Host 'nothing to revert' -ForegroundColor Yellow }
    return
}
if (-not $Import) { throw 'specify -Import or -Revert' }

# The target size is the mod's screen size, read from the manifest rather than typed here --
# an image that does not match it exactly is the bug this script exists to fix.
if (-not $Width -or -not $Height) {
    $mf = Join-Path $PSScriptRoot '..\AztMod.manifest.json'
    if (-not (Test-Path $mf)) { throw 'no manifest to read the screen size from; pass -Width/-Height' }
    $man = Get-Content $mf -Raw | ConvertFrom-Json
    if (-not $Width)  { $Width  = [int]$man.art.screenW }
    if (-not $Height) { $Height = [int]$man.art.screenH }
}
Write-Host ("target {0}x{1}" -f $Width, $Height)

# ALWAYS MEASURE AGAINST THE STOCK FILE. Once this script has shipped a replacement, the
# live file in the game folder is our own output; reading the low palette half out of that
# would be reading back what we wrote. .aztbak is Apply-AztMod's copy of the original.
function StockPath($rel) {
    $live = Join-Path $GameDir $rel
    foreach ($c in @("$live.aztbak", "$live.src", $live)) { if (Test-Path $c) { return $c } }
    throw "cannot find the stock $rel"
}

foreach ($s in $SCREENS) {
    if ($Only -and ($Only -notcontains $s.key)) { continue }
    $png = Join-Path $InDir $s.png
    if (-not (Test-Path $png)) { Write-Host ("{0}: no {1}, skipped" -f $s.key, $s.png) -ForegroundColor DarkGray; continue }
    $stock = [LeTool.Pcx]::Load((StockPath $s.stock))

    # Content size. For an inset image the picture is quantised at THIS size and composited
    # onto the full canvas afterwards -- not drawn into a black canvas and quantised whole,
    # which would spend one of the 128 palette boxes on the border and still only get a
    # near-black for it.
    $useInset = $s.inset -and ($FillPct -lt 100)
    $cw = $(if ($useInset) { [int]($Width  * $FillPct / 100) } else { $Width })
    $ch = $(if ($useInset) { [int]($Height * $FillPct / 100) } else { $Height })
    $cx = [int](($Width - $cw) / 2); $cy = [int](($Height - $ch) / 2)

    # PNG -> BGRA at the content size
    $img = [System.Drawing.Image]::FromFile($png)
    $sw = $img.Width; $sh = $img.Height
    $bmp = New-Object System.Drawing.Bitmap($cw, $ch, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $cw, $ch)))
    $g.Dispose(); $img.Dispose()
    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$cw,$ch)),
                       [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                       [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bgra = New-Object byte[] ($cw * $ch * 4)
    for ($y = 0; $y -lt $ch; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride), $bgra, $y*$cw*4, $cw*4)
    }
    $bmp.UnlockBits($d); $bmp.Dispose()

    $pal = New-Object byte[] 768
    $dith = $(if ($NoDither) { 0 } else { 1 })
    # One colour is reserved for the border when there is one, and it must be EXACTLY
    # #000000: a near-black frame reads as a grey box against the real black around it.
    $border = $(if ($useInset) { 255 } else { -1 })
    if ($s.palette -eq 'high128') {
        $nCol = $(if ($useInset) { 127 } else { 128 })
        $pal3 = [LeTool.Quant]::MedianCut($bgra, $cw, $ch, $nCol)
        $px   = [LeTool.Quant]::Map($bgra, $cw, $ch, $pal3, $nCol, 128, $dith)
        [Array]::Copy($stock.Palette, 0, $pal, 0, 384)          # 0..127 stay exactly as shipped
        for ($c = 0; $c -lt $nCol; $c++) {
            $pal[(128+$c)*3] = $pal3[$c*3]; $pal[(128+$c)*3+1] = $pal3[$c*3+1]; $pal[(128+$c)*3+2] = $pal3[$c*3+2]
        }
        $mode = "book rule, $nCol colours at index 128"
        $lo = 128; $hi = 255
    } else {
        $pal3 = $null
        $px = [LeTool.Quant]::MapExact($bgra, $cw, $ch, 256, -1, [ref]$pal3)
        $mode = 'exact palette'
        if ($null -eq $px) {
            $pal3 = [LeTool.Quant]::MedianCut($bgra, $cw, $ch, 256)
            $px   = [LeTool.Quant]::Map($bgra, $cw, $ch, $pal3, 256, 0, $dith)
            $mode = $(if ($NoDither) { 'median cut' } else { 'median cut + dither' })
        }
        [Array]::Copy($pal3, 0, $pal, 0, [Math]::Min(768, $pal3.Length))
        $lo = 0; $hi = 255
    }

    # Compose onto the full canvas. The game still blits a screen-sized image at (0,0), so
    # nothing in the patch set knows or cares that the picture inside it got smaller.
    if ($useInset) {
        $pal[$border*3] = 0; $pal[$border*3+1] = 0; $pal[$border*3+2] = 0
        $canvas = New-Object byte[] ($Width * $Height)
        for ($i = 0; $i -lt $canvas.Length; $i++) { $canvas[$i] = [byte]$border }
        for ($y = 0; $y -lt $ch; $y++) { [Array]::Copy($px, $y*$cw, $canvas, ($cy+$y)*$Width + $cx, $cw) }
        $px = $canvas
        $mode += ", inset {0}x{1} at ({2},{3})" -f $cw, $ch, $cx, $cy
    }

    $out = New-Object LeTool.Pcx
    $out.Width = $Width; $out.Height = $Height
    $out.BitsPerPixel = 8; $out.Planes = 1; $out.BytesPerLine = $Width
    $out.Pixels = $px; $out.Palette = $pal
    $dest = Join-Path $ArtDir $s.art
    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
    $out.SavePcx($dest)

    # ASSERT ON READBACK. Both failure modes here are invisible without launching the game
    # and reaching the screen in question: a size that does not match the surface shows
    # uninitialised heap, and an index outside the allowed band recolours the HUD.
    $chk = [LeTool.Pcx]::Load($dest)
    if ($chk.Width -ne $Width -or $chk.Height -ne $Height) {
        throw ("{0}: wrote {1}x{2} but read back {3}x{4}" -f $s.key, $Width, $Height, $chk.Width, $chk.Height)
    }
    $h = $chk.Histogram(); $bad = 0; $used = 0
    for ($i = 0; $i -lt 256; $i++) {
        if ($h[$i] -gt 0) { $used++; if ($i -lt $lo -or $i -gt $hi) { $bad++ } }
    }
    if ($bad) { throw ("{0}: {1} index/indices outside the allowed band {2}..{3}" -f $s.key, $bad, $lo, $hi) }
    if ($s.palette -eq 'high128') {
        $df = 0; for ($i = 0; $i -lt 384; $i++) { if ($chk.Palette[$i] -ne $stock.Palette[$i]) { $df++ } }
        if ($df) { throw ("{0}: the low palette half was modified ({1} bytes)" -f $s.key, $df) }
    }
    Write-Host ("{0,-8} {1}x{2} -> {3}x{4}  [{5}]  {6} colours, band {7}..{8}  -> art\{9}  {10:N0} bytes" -f `
                $s.key, $sw, $sh, $Width, $Height, $mode, $used, $lo, $hi, $s.art, (Get-Item $dest).Length) `
               -ForegroundColor Green
}
Write-Host ''
Write-Host 'Run Apply-AztMod to install.   Revert with:  .\src\Build-Screens.ps1 -Revert'
