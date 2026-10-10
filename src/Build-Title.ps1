# Build-Title.ps1 -- export and replace the title screen and publisher logo.
#
#   .\src\Build-Title.ps1 -Export -OutDir design\incoming\title
#   .\src\Build-Title.ps1 -Import -InDir  design\incoming\title
#   .\src\Build-Title.ps1 -Revert
#
# THE TITLE SCREEN IS NOT A VIDEO. It is TITLE.PCX, 8-bit, sitting in GAME\AZRAEL next to
# the executables -- so it is a straight asset swap with no reverse-engineering.
#
# R.EXE DRAWS IT, NOT TM.EXE. An earlier version of this note said the opposite, on the
# strength of AZRAEL.BAT running `tm` before `r`. That is just the start-up order; the
# filenames live in R.EXE's own string table (see SIZE below), and TM.EXE never touches
# them. The mistake outlived itself in a warning on every import -- see further down.
#
# IT OWNS THE WHOLE PALETTE, unlike the book pages. Build-HudRepalette knows this from the
# code rather than by inspection: 0x1FBC2 loads backdrop/mistral/newlogo and calls
# SetWholePalette, and title.pcx does the same. Measured on the stock file: 251 distinct
# indices spanning 0..255, 124 of them below 128. So all 256 entries are free here and the
# books' 128..255 restriction does NOT apply -- which is why this is a separate script
# rather than another mode of Build-Books.
#
# SIZE. The filenames "title.pcx" and "newlogo.pcx" are in R.EXE's string table at 0x134B21,
# reached by index rather than by pointer, which is why neither an xref nor a fixup search
# finds them. So they follow the SCREEN RESOLUTION like the book pages do.
#
# -Width/-Height therefore default to the mod's own screen, read from the manifest's
# art.screenW/screenH rather than hard-coded. The default used to be the stock 640x480, on
# the reasoning that a plain -Import should not silently change geometry -- but with the mod
# running at 1024x768 that had it exactly backwards: the silent change was a plain -Import
# DOWNGRADING the title to a quarter-area image that no longer fills the screen. Both the
# stock art and the replacements are 4:3, so 1024x768 needs no letterboxing.

[CmdletBinding()]
param(
    [switch]$Export,
    [switch]$Import,
    [switch]$Revert,
    [string]$OutDir,
    [string]$InDir,
    [string]$GameDir = 'C:\Games\AzraelsTear-Modded\GAME\AZRAEL',
    # 0 = the mod's screen, from the manifest. Pass both to override.
    [int]$Width  = 0,
    [int]$Height = 0,
    [string[]]$Files = @('TITLE.PCX','NEWLOGO.PCX'),
    [int]$Colours = 256,
    [switch]$NoDither
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs"  -ReferencedAssemblies System.Drawing
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing

# Backup as <name>.PCX.src, matching Build-Books. NOT .aztbak: that suffix belongs to
# Apply-AztMod's own install/uninstall bookkeeping, and borrowing it would make an
# AztMod uninstall restore art this script is responsible for -- or worse, make this
# script's revert fight the installer's.
function BackupOf($p) { "$p.src" }

# ---- the screen these images have to fill ------------------------------------
# From the manifest, which is what the build actually patched R.EXE to use, so this cannot
# drift the way a second copy of the number would. Resolved HERE, in the body, where the
# parameters are known -- a derived value placed above its inputs becomes $null, and $null
# arithmetic is 0, silently (see the DERIVED block in Build-AztMod).
$screenW = 640; $screenH = 480          # stock, and the fallback if no manifest is present
$manPath = Join-Path $PSScriptRoot '..\AztMod.manifest.json'
if (Test-Path $manPath) {
    $man = Get-Content $manPath -Raw | ConvertFrom-Json
    if ($man.art.screenW -and $man.art.screenH) { $screenW = [int]$man.art.screenW; $screenH = [int]$man.art.screenH }
}
if ($Width  -le 0) { $Width  = $screenW }
if ($Height -le 0) { $Height = $screenH }

if ($Revert) {
    $n = 0
    foreach ($f in $Files) {
        $p = Join-Path $GameDir $f
        $b = BackupOf $p
        if (Test-Path $b) {
            Copy-Item $b $p -Force
            Write-Host ("{0} reverted ({1:N0} bytes)" -f $f, (Get-Item $p).Length) -ForegroundColor Green
            $n++
        } else { Write-Host ("{0}: no .src backup, left alone" -f $f) -ForegroundColor Yellow }
    }
    if (-not $n) { Write-Host "nothing to revert" -ForegroundColor Yellow }
    return
}

if ($Export) {
    if (-not $OutDir) { throw '-Export needs -OutDir' }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    foreach ($f in $Files) {
        $p = Join-Path $GameDir $f
        # export the PRISTINE image when one exists, so a re-export after an import
        # gives the original art rather than a re-encode of the replacement
        $b = BackupOf $p
        $src = if (Test-Path $b) { $b } else { $p }
        if (-not (Test-Path $src)) { Write-Host ("{0}: not found" -f $f) -ForegroundColor Yellow; continue }
        $x = [LeTool.Pcx]::Load($src)
        $png = Join-Path $OutDir (($f -replace '\.PCX$','') + '.png')
        $x.SavePng($png, 1)
        $hist = $x.Histogram()
        $used = 0; $lo = 0
        for ($i = 0; $i -lt 256; $i++) { if ($hist[$i] -gt 0) { $used++; if ($i -lt 128) { $lo++ } } }
        Write-Host ("exported {0,-12} {1}x{2}  {3} colours ({4} below index 128)  -> {5}" -f `
                    $f, $x.Width, $x.Height, $used, $lo, (Split-Path $png -Leaf))
    }
    Write-Host ""
    Write-Host "Upscale these, then put the results back in the same folder with the SAME names."
    Write-Host "Any size is fine -- they are resampled to the target on import."
    return
}

if (-not $Import) { throw 'specify -Export, -Import or -Revert' }
if (-not $InDir) { throw '-Import needs -InDir' }

foreach ($f in $Files) {
    $dest = Join-Path $GameDir $f
    if (-not (Test-Path $dest)) { Write-Host ("{0}: not in $GameDir" -f $f) -ForegroundColor Yellow; continue }
    $png = Join-Path $InDir (($f -replace '\.PCX$','') + '.png')
    if (-not (Test-Path $png)) { Write-Host ("{0}: no replacement {1}" -f $f, (Split-Path $png -Leaf)) -ForegroundColor DarkGray; continue }

    $bak = BackupOf $dest
    if (-not (Test-Path $bak)) { Copy-Item $dest $bak; Write-Host ("  backed up -> {0}" -f (Split-Path $bak -Leaf)) }
    $stock = [LeTool.Pcx]::Load($bak)          # always measure against the ORIGINAL

    # PNG -> BGRA at the target size
    $img = [System.Drawing.Image]::FromFile($png)
    $sw = $img.Width; $sh = $img.Height
    $bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)))
    $g.Dispose(); $img.Dispose()

    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$Width,$Height)),
                       [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                       [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bgra = New-Object byte[] ($Width * $Height * 4)
    for ($y = 0; $y -lt $Height; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride),
            $bgra, $y*$Width*4, $Width*4)
    }
    $bmp.UnlockBits($d); $bmp.Dispose()

    # A FRESH OPTIMAL PALETTE, not the stock one. Nothing else is on screen while the
    # title is up -- it calls SetWholePalette itself -- so all 256 entries belong to this
    # image and crushing new art into 1996's palette would throw away most of the gain.
    $pal3 = $null
    $idx = [LeTool.Quant]::MapExact($bgra, $Width, $Height, $Colours, -1, [ref]$pal3)
    $mode = 'exact palette'
    if ($null -eq $idx) {
        $pal3 = [LeTool.Quant]::MedianCut($bgra, $Width, $Height, $Colours)
        $idx  = [LeTool.Quant]::Map($bgra, $Width, $Height, $pal3, $Colours, 0, $(if ($NoDither) { 0 } else { 1 }))
        $mode = if ($NoDither) { 'median cut' } else { 'median cut + dither' }
    }

    $pal = New-Object byte[] 768
    [Array]::Copy($pal3, 0, $pal, 0, [Math]::Min(768, $pal3.Length))

    $out = New-Object LeTool.Pcx
    $out.Width = $Width; $out.Height = $Height
    $out.BitsPerPixel = 8; $out.Planes = 1; $out.BytesPerLine = $Width
    $out.Pixels = $idx; $out.Palette = $pal
    $out.SavePcx($dest)

    # WARN ON THE MISTAKE, NOT ON THE NORMAL CASE. This used to fire whenever the size
    # differed from the stock 640x480 and blame TM.EXE for not coping -- so it warned on
    # every correct import, stayed silent on the wrong one, and named a program that does
    # not draw these images. R.EXE does, and it draws them at the screen resolution.
    #
    # The real failure is an image that does not match the screen: too small and it sits in
    # a corner instead of filling it, too large and it is cropped.
    $warn = ''
    if ($Width -ne $screenW -or $Height -ne $screenH) {
        $warn = "  <-- {0}x{1} is NOT the screen ({2}x{3}); this will not fill it" -f `
                $Width, $Height, $screenW, $screenH
    } elseif ([Math]::Abs(($sw / [double]$sh) - ($Width / [double]$Height)) -gt 0.01) {
        # Both stock images are 4:3 and so is the screen, so a source that is not will be
        # stretched. Worth saying out loud rather than letting it look subtly wrong.
        $warn = "  <-- source is {0:N2}:1 but the screen is {1:N2}:1; it will be stretched" -f `
                ($sw / [double]$sh), ($Width / [double]$Height)
    }
    Write-Host ("imported {0,-12} {1}x{2} source -> {3}x{4}  [{5}]  {6:N0} bytes{7}" -f `
                (Split-Path $png -Leaf), $sw, $sh, $Width, $Height, $mode, (Get-Item $dest).Length, $warn) `
               -ForegroundColor $(if ($warn) { 'Yellow' } else { 'Green' })
}
Write-Host ""
Write-Host "Revert with:  .\src\Build-Title.ps1 -Revert"
