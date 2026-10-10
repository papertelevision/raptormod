# Measure-TexturePalette.ps1 -- what colours a room's original textures actually are, and
# how many texels of each are actually visible.
#
#   .\tools\Measure-TexturePalette.ps1 -Res CORICORI
#   .\tools\Measure-TexturePalette.ps1 -Res CORICORI -Swatches design\room1-swatches
#
# WHY THIS EXISTS: the remaster pipeline takes LIGHTING from the original and COLOUR from
# the new art. At -Blend 1.0 every hue in the result came from the image model, so telling
# it "dark and desaturated gothic stone" in words is the weakest possible link in the chain
# -- it will cheerfully return warm sandstone or blue-grey granite and both are wrong.
#
# So measure the original instead and hand the model hex values.
#
# Two numbers per texture matter:
#
#   DOMINANT COLOURS -- computed from the LIT pixels only. The dark pixels are painted
#   shadow, so including them just drags every texture toward black and says nothing about
#   the material. Hues are clustered on a coarse grid and reported by pixel count.
#
#   VISIBLE TEXELS -- the art bounding box, times the output scale. This is the real
#   legibility budget: ecrflra2's art occupies 183x361 of its 512x512 record, so detail
#   finer than a few texels dissolves into 256-colour dither no matter how good the source
#   was. Quoting this to the model is what stops it returning photographic gravel.
[CmdletBinding()]
param(
    [string]$Res = 'CORICORI',
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [int]$Scale = 2,             # the output scale the art is being made for
    [int]$Top = 6,               # dominant colours to report per texture
    [int]$DarkThresh = 18,       # at or below this luminance a pixel is shadow, not material
    [string]$Swatches            # optional: write a palette swatch PNG per texture
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -AssemblyName System.Drawing
if (-not ("AztTool.Azf" -as [type])) { Add-Type -Path (Join-Path $toolDir 'AzfTool.cs') -ReferencedAssemblies System.Drawing }

$stem = $Res -replace '\.(RES|XAF)$',''
$resPath = Join-Path $TexDir "$stem.RES"
$xafPath = Join-Path $TexDir "$stem.XAF"
# ALWAYS the pristine backup: measuring a .RES that already has remastered records in it
# would feed the model its own previous output.
$origRes = "$resPath.orig"
if (-not (Test-Path $origRes)) { $origRes = $resPath; Write-Host "no .orig backup -- measuring the live .RES" -ForegroundColor Yellow }
$texs = [AztTool.Azf]::Read($origRes)

# ---- names, first-appearance order ------------------------------------------
$names = New-Object System.Collections.ArrayList
if (Test-Path $xafPath) {
    $xaf = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($xafPath))
    foreach ($m in [regex]::Matches($xaf, 'texture\s+"([^"]+)"', 'IgnoreCase')) {
        $leaf = (($m.Groups[1].Value -split '[\\/]')[-1]) -replace '\.(azf|gif)$',''
        if (-not $names.Contains($leaf)) { [void]$names.Add($leaf) }
    }
}

if ($Swatches) { New-Item -ItemType Directory -Force $Swatches | Out-Null }

$rows = @()
$globalBins = @{}

for ($i = 0; $i -lt $texs.Count; $i++) {
    $t = $texs[$i]
    if (-not $t.Decoded) {
        Write-Host ("  {0,2}  {1,-12} does not decode -- skipped" -f $i, $(if ($i -lt $names.Count) { $names[$i] } else { '?' })) -ForegroundColor Yellow
        continue
    }
    $nm = if ($i -lt $names.Count) { $names[$i] } else { "rec$i" }

    # bounding box of the lit area, and a colour histogram of it
    $bins = @{}
    $x0 = $t.Width; $y0 = $t.Height; $x1 = -1; $y1 = -1
    $litCount = 0
    $lumMin = 255.0; $lumMax = 0.0; $lumSum = 0.0
    for ($y = 0; $y -lt $t.Height; $y++) {
        $row = $y * $t.BytesPerLine
        for ($x = 0; $x -lt $t.Width; $x++) {
            $c = $t.Pixels[$row + $x]
            # [int] IS LOad-BEARING. PowerShell's -shl and -shr keep the LEFT operand's
            # type, so ([byte]41 -shl 16) is 0, not 2686976. Leaving these as bytes made
            # the histogram key below discard the red channel entirely.
            $r = [int]$t.Palette[$c*4]; $g = [int]$t.Palette[$c*4+1]; $b = [int]$t.Palette[$c*4+2]
            $lum = 0.299*$r + 0.587*$g + 0.114*$b
            if ($lum -le $DarkThresh) { continue }
            if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }
            if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y }
            $litCount++
            if ($lum -lt $lumMin) { $lumMin = $lum }
            if ($lum -gt $lumMax) { $lumMax = $lum }
            $lumSum += $lum
            # coarse 16x16x16 grid: fine enough to separate materials, coarse enough that
            # dithered neighbours land in one bucket instead of 40
            $key = ((($r -shr 4) -shl 8) -bor (($g -shr 4) -shl 4) -bor ($b -shr 4))
            if ($bins.ContainsKey($key)) { $bins[$key][0]++ ; $bins[$key][1] += $r; $bins[$key][2] += $g; $bins[$key][3] += $b }
            else { $bins[$key] = @(1, [int]$r, [int]$g, [int]$b) }
            if ($globalBins.ContainsKey($key)) { $globalBins[$key][0]++ ; $globalBins[$key][1] += $r; $globalBins[$key][2] += $g; $globalBins[$key][3] += $b }
            else { $globalBins[$key] = @(1, [int]$r, [int]$g, [int]$b) }
        }
    }
    if ($litCount -eq 0) {
        Write-Host ("  {0,2}  {1,-12} entirely below the dark threshold -- skipped" -f $i, $nm) -ForegroundColor Yellow
        continue
    }

    # top bins, as the AVERAGE colour of each bin rather than the bin centre.
    # NOT $top -- PowerShell variable names are case-insensitive, so $top IS the $Top
    # parameter, and assigning an array to it made -First fail on the second texture.
    $topBins = @($bins.GetEnumerator() | Sort-Object { -$_.Value[0] } | Select-Object -First $Top)
    $hexes = @()
    foreach ($e in $topBins) {
        $n = $e.Value[0]
        $hexes += ('#{0:X2}{1:X2}{2:X2}' -f [int]($e.Value[1]/$n), [int]($e.Value[2]/$n), [int]($e.Value[3]/$n))
    }
    $topShare = 0.0
    foreach ($e in $topBins) { $topShare += $e.Value[0] }
    $topShare = 100.0 * $topShare / $litCount

    # saturation of the lit material, as a ceiling to quote at the model
    $satMax = 0.0
    foreach ($e in $topBins) {
        $n = $e.Value[0]
        $r = $e.Value[1]/$n; $g = $e.Value[2]/$n; $b = $e.Value[3]/$n
        $mx = [Math]::Max($r, [Math]::Max($g, $b)); $mn = [Math]::Min($r, [Math]::Min($g, $b))
        $s = if ($mx -le 0) { 0 } else { ($mx - $mn) / $mx }
        if ($s -gt $satMax) { $satMax = $s }
    }

    $bw = if ($x1 -ge $x0) { $x1 - $x0 + 1 } else { 0 }
    $bh = if ($y1 -ge $y0) { $y1 - $y0 + 1 } else { 0 }
    $rows += [pscustomobject]@{
        Index     = $i
        Name      = $nm
        RecW      = $t.Width
        RecH      = $t.Height
        OutW      = $t.Width  * $Scale
        OutH      = $t.Height * $Scale
        ArtW      = $bw * $Scale
        ArtH      = $bh * $Scale
        ArtPct    = [Math]::Round(100.0 * $bw * $bh / ($t.Width * $t.Height), 1)
        LitPct    = [Math]::Round(100.0 * $litCount / ($t.Width * $t.Height), 1)
        LumMin    = [int]$lumMin
        LumMean   = [int]($lumSum / $litCount)
        LumMax    = [int]$lumMax
        SatMaxPct = [int]($satMax * 100)
        TopShare  = [int]$topShare
        Hex       = ($hexes -join ' ')
    }

    Write-Host ("  {0,2}  {1,-12} {2,4}x{3,-4} art {4,4}x{5,-4} ({6,4}% lit)  lum {7,3}-{8,-3} sat<{9,2}%  {10}" -f `
                $i, $nm, $t.Width, $t.Height, $bw, $bh, $rows[-1].LitPct, [int]$lumMin, [int]$lumMax, $rows[-1].SatMaxPct, ($hexes -join ' '))

    if ($Swatches) {
        $sw = 48; $bmp = New-Object System.Drawing.Bitmap(($sw * $hexes.Count), $sw)
        $g2 = [System.Drawing.Graphics]::FromImage($bmp)
        for ($k = 0; $k -lt $hexes.Count; $k++) {
            $col = [System.Drawing.ColorTranslator]::FromHtml($hexes[$k])
            $br = New-Object System.Drawing.SolidBrush($col)
            $g2.FillRectangle($br, ($k*$sw), 0, $sw, $sw); $br.Dispose()
        }
        $g2.Dispose()
        $bmp.Save((Join-Path $Swatches ("{0:d2}-{1}.png" -f $i, $nm)), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
}

# ---- the room's shared palette ----------------------------------------------
Write-Host ""
$gTop = @($globalBins.GetEnumerator() | Sort-Object { -$_.Value[0] } | Select-Object -First 12)
$gHex = @()
foreach ($e in $gTop) {
    $n = $e.Value[0]
    $gHex += ('#{0:X2}{1:X2}{2:X2}' -f [int]($e.Value[1]/$n), [int]($e.Value[2]/$n), [int]($e.Value[3]/$n))
}
Write-Host ("ROOM PALETTE ({0} textures, lit pixels only):" -f $rows.Count) -ForegroundColor Green
Write-Host ("  " + ($gHex -join '  '))

$satAll = ($rows | Measure-Object -Property SatMaxPct -Maximum).Maximum
Write-Host ("  saturation never exceeds {0}% on any dominant colour" -f $satAll)
Write-Host ("  smallest art region: {0}" -f (($rows | Sort-Object { $_.ArtW * $_.ArtH } | Select-Object -First 1 |
              ForEach-Object { "{0} at {1}x{2} texels" -f $_.Name, $_.ArtW, $_.ArtH })))

$rows | Export-Csv -NoTypeInformation (Join-Path $env:TEMP "$stem-palette.csv")
Write-Host ("`ncsv -> {0}" -f (Join-Path $env:TEMP "$stem-palette.csv"))
$script:PaletteRows = $rows
$script:RoomPalette = $gHex
$rows
