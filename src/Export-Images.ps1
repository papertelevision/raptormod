# Export-Images.ps1 -- every PCX the game loads, as PNG, sorted into what is worth
# up-rezzing and what is not.
#
#   .\src\Export-Images.ps1                      # everything except the books
#   .\src\Export-Images.ps1 -IncludeBooks        # ...and the books too
#   .\src\Export-Images.ps1 -Only screens        # just one category
#
# WHAT THE GAME ACTUALLY LOADS, read out of R.EXE's strings rather than guessed from the
# folder listing -- several names are built with printf and never appear whole on disk:
#   %smaps\help.pcx     the F1 help screen
#   %smaps\%s.pcx       the automap art, one per room
#   %s\books\%s%d.pcx   the readable pages          (already handled by Build-Books)
#   mice\*.pcx          cursors
#   wire\%s%02d.pcx     inventory item rotation frames, 683 of them
#   orrpuz\*.pcx        the orrery puzzle
#   plus the fixed UI names: title, hud3, hudoff, backdrop, mapbkgrd, save%02d, screen%d...
#
# CATEGORIES exist because "all the images" is 1,105 files and most of them should never be
# touched. A 16x10 cursor or a 1932x15 font strip does not want an AI upscale: the cursors
# are mask-registered to single pixels, and the fonts are a variable-width strip whose glyph
# boundaries the engine finds by scanning for a marker colour. Those are listed so nothing
# is a surprise, not because they are candidates.
[CmdletBinding()]
param(
    [string]$GameDir = 'C:\Games\AzraelsTear-Modded\GAME',
    [string]$OutDir  = 'C:\Games\azrael-gfx',
    [switch]$IncludeBooks,
    [string[]]$Only,
    [switch]$NoSheets
)
$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $GameDir)) { throw "no such game folder: $GameDir" }

# Fonts are one tall strip of glyphs, so they are extremely wide and a dozen pixels high.
# Caught by shape rather than by name: the Russian and colour variants are numerous and a
# name list would go stale.
function Get-Category {
    param([string]$name, [string]$folder, [int]$w, [int]$h)
    if ($folder -eq 'WIRE')   { return 'wire' }
    if ($folder -eq 'MICE')   { return 'cursors' }
    if ($folder -eq 'BOOKS')  { return 'books' }
    if ($h -le 20 -and $w -ge 300) { return 'fonts' }
    if ($w -le 8 -or $h -le 8)     { return 'fonts' }   # the 5px map rules and separators
    # BY NAME, not by folder: the F1 help screen lives in MAPS with the automap art but is
    # a full-screen UI image and belongs with the other screens.
    if ($name -eq 'HELP') { return 'screens' }
    if ($folder -eq 'MAPS') {
        # The automap has two tiers -- large area views and small per-room thumbnails (the
        # _C set). Only the large ones are worth putting through an upscaler.
        if ($w -ge 200 -and $h -ge 150) { return 'maps-large' }
        return 'maps-small'
    }
    if ($folder -eq 'ORRPUZ') { return 'puzzle' }
    if ($w -ge 200 -and $h -ge 150) { return 'screens' }
    return 'ui'
}

function Pcx-ToBitmap($p) {
    $bmp = New-Object System.Drawing.Bitmap($p.Width, $p.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$p.Width,$p.Height)),
                       [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                       [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $row = New-Object byte[] ($p.Width * 4)
    for ($y = 0; $y -lt $p.Height; $y++) {
        for ($x = 0; $x -lt $p.Width; $x++) {
            $i = $p.Pixels[$y*$p.Width + $x]
            $row[$x*4]   = $p.Palette[$i*3+2]
            $row[$x*4+1] = $p.Palette[$i*3+1]
            $row[$x*4+2] = $p.Palette[$i*3]
            $row[$x*4+3] = 255
        }
        [System.Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride), $row.Length)
    }
    $bmp.UnlockBits($d)
    return $bmp
}

# THE PRISTINE PAGE, not the rescaled one. Build-Books leaves the original beside its
# output as <name>.PCX.src, so exporting the .PCX would hand back art that has already been
# through a quantiser -- upscaling that would bake in its banding.
function Source-Of($f) {
    $src = "$($f.FullName).src"
    if (Test-Path $src) { return $src }
    return $f.FullName
}

$files = Get-ChildItem $GameDir -Filter '*.PCX' -File -Recurse
$rows  = New-Object System.Collections.ArrayList
$byCat = @{}
$skipped = 0

foreach ($f in $files) {
    $folder = Split-Path $f.DirectoryName -Leaf
    if ($folder -eq 'BOOKS' -and -not $IncludeBooks) { continue }
    $path = Source-Of $f
    try { $p = [LeTool.Pcx]::Load($path) } catch { $skipped++; continue }
    if ($p.BitsPerPixel -ne 8 -or $p.Planes -ne 1) { $skipped++; continue }

    $stem0 = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $cat = Get-Category $stem0 $folder $p.Width $p.Height
    if ($Only -and ($Only -notcontains $cat)) { continue }

    $dir = Join-Path $OutDir $cat
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    # WIRE has 683 files across many items and names repeat nowhere, but MAPS and AZRAEL
    # can both hold a name, so the folder goes in the filename rather than nesting deeper.
    $out = Join-Path $dir ("{0}__{1}.png" -f $folder, $stem)

    $bmp = Pcx-ToBitmap $p
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    # MOD-REPLACED OR STOCK. Apply-AztMod keeps the shipped file as <name>.aztbak whenever
    # it installs its own, so the presence of that backup is the flag. It matters a lot for
    # up-rezzing: 76 of the 78 files in AZRAEL are already the mod's own HUD reskin, fonts
    # and buttons, and putting those through an upscaler would fight the pipeline that
    # generates them rather than improve anything.
    [void]$rows.Add([pscustomobject]@{
        Category = $cat; Folder = $folder; Name = $f.Name
        W = $p.Width; H = $p.Height; Pixels = $p.Width * $p.Height
        Source = $(if (Test-Path "$($f.FullName).aztbak") { 'mod-generated' } else { 'stock' })
        FromSrc = ($path -ne $f.FullName); Png = (Split-Path $out -Leaf)
    })
    if (-not $byCat.ContainsKey($cat)) { $byCat[$cat] = New-Object System.Collections.ArrayList }
    [void]$byCat[$cat].Add($out)
}

$rows | Sort-Object Category, @{E='Pixels';D=$true}, Name |
    Export-Csv (Join-Path $OutDir 'manifest.csv') -NoTypeInformation -Encoding UTF8

# A contact sheet per category, so the whole set can be judged at a glance instead of by
# opening 400 files. Thumbnails keep their aspect inside a fixed cell.
if (-not $NoSheets) {
    foreach ($cat in $byCat.Keys) {
        $list = @($byCat[$cat] | Sort-Object)
        $cell = 128; $cols = 8
        $rowsN = [Math]::Ceiling($list.Count / [double]$cols)
        $sheet = New-Object System.Drawing.Bitmap ($cols*$cell), ([int]($rowsN*$cell))
        $g = [System.Drawing.Graphics]::FromImage($sheet)
        $g.Clear([System.Drawing.Color]::FromArgb(24,24,24))
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        for ($i = 0; $i -lt $list.Count; $i++) {
            $im = [System.Drawing.Image]::FromFile($list[$i])
            $s = [Math]::Min(($cell-8)/[double]$im.Width, ($cell-8)/[double]$im.Height)
            $w = [Math]::Max(1,[int]($im.Width*$s)); $h = [Math]::Max(1,[int]($im.Height*$s))
            $cx = ($i % $cols)*$cell + [int](($cell-$w)/2)
            $cy = [int]($i/$cols)*$cell + [int](($cell-$h)/2)
            $g.DrawImage($im, $cx, $cy, $w, $h)
            $im.Dispose()
        }
        $g.Dispose()
        $sheet.Save((Join-Path $OutDir ("_sheet-{0}.png" -f $cat)), [System.Drawing.Imaging.ImageFormat]::Png)
        $sheet.Dispose()
    }
}

"exported {0} image(s) to {1}   (skipped {2} unreadable/non-8bpp)" -f $rows.Count, $OutDir, $skipped
$rows | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
    $px = ($_.Group | Measure-Object Pixels -Maximum).Maximum
    $stock = @($_.Group | Where-Object Source -eq 'stock').Count
    "  {0,-11} {1,4} files  {2,4} stock / {3,3} mod-generated   largest {4:N0} px" -f `
        $_.Name, $_.Count, $stock, ($_.Count - $stock), $px
}
