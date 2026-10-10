# Split-ContactSheet.ps1 -- cut one labelled grid image into individually named textures.
#
#   .\tools\Split-ContactSheet.ps1 -In 'sheet.png' -OutDir out `
#       -Names '05-ecrflr05,06-ecrflra4,07-ecrflra3,08-ecrflra2,09-ecrflra1,13-ecrflr04,14-ecrflr03,15-ecrflr02,16-ecrflr01'
#
# Image models like returning a contact sheet when asked for a set. That is workable, but it
# brings two problems that silently ruin the textures if they are not handled:
#
#   1. THE LABEL IS BURNED INTO THE ARTWORK, not drawn in a margin. Slice on the grid alone
#      and every texture carries its own filename across the bottom, which then gets
#      relit and quantised into the game like any other detail. The label band is found by
#      colour -- bright warm text over dark stone, in the lower part of the cell -- and
#      trimmed off with a margin.
#
#   2. GUTTER WIDTHS ARE NOT UNIFORM. Assuming width/cols puts a sliver of the neighbouring
#      cell, or of the black gutter, down one edge of each tile. Gutters are detected as
#      runs of near-black rows and columns and the cells are whatever lies between them.
#
# NAMES ARE POSITIONAL, in reading order (left to right, top to bottom), and the count must
# match the detected cell count exactly -- the script refuses to guess. Read the labels off
# the sheet yourself first: a wrong name here is silent and lands the art on the wrong
# surface, which is the single most expensive mistake in this pipeline.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$In,
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$Names,      # comma-separated, reading order
    [int]$GutterLum = 12,                      # mean luminance below which a line is gutter
    [int]$MinCell = 40,                        # ignore runs narrower than this
    [double]$LabelZone = 0.25,                 # search the bottom this fraction for a label
    [int]$LabelMargin = 8,                     # extra px trimmed above the label
    [switch]$NoLabelTrim
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

$nameList = @($Names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$src = New-Object System.Drawing.Bitmap($In)
$w = $src.Width; $h = $src.Height
$d = $src.LockBits((New-Object System.Drawing.Rectangle(0,0,$w,$h)),
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$px = New-Object 'int[]' ($w*$h)
[System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $px, 0, $px.Length)
$src.UnlockBits($d)
Write-Host ("{0}: {1}x{2}" -f (Split-Path $In -Leaf), $w, $h)

# ---- gutters ----------------------------------------------------------------
function Spans {
    <# runs of NON-gutter lines, given a per-line mean #>
    param([double[]]$mean, [int]$limit, [int]$minLen)
    $spans = @(); $start = -1
    for ($i = 0; $i -lt $mean.Length; $i++) {
        $isGut = $mean[$i] -lt $limit
        if (-not $isGut -and $start -lt 0) { $start = $i }
        elseif ($isGut -and $start -ge 0) {
            if (($i - $start) -ge $minLen) { $spans += ,@($start, ($i-1)) }
            $start = -1
        }
    }
    if ($start -ge 0 -and ($mean.Length - $start) -ge $minLen) { $spans += ,@($start, ($mean.Length-1)) }
    ,$spans
}

$colMean = New-Object 'double[]' $w
for ($x = 0; $x -lt $w; $x++) {
    $s = 0.0
    for ($y = 0; $y -lt $h; $y++) { $v = $px[$y*$w+$x]
        $s += 0.299*(($v -shr 16) -band 255) + 0.587*(($v -shr 8) -band 255) + 0.114*($v -band 255) }
    $colMean[$x] = $s / $h
}
$rowMean = New-Object 'double[]' $h
for ($y = 0; $y -lt $h; $y++) {
    $s = 0.0; $r = $y*$w
    for ($x = 0; $x -lt $w; $x++) { $v = $px[$r+$x]
        $s += 0.299*(($v -shr 16) -band 255) + 0.587*(($v -shr 8) -band 255) + 0.114*($v -band 255) }
    $rowMean[$y] = $s / $w
}
$colSpans = Spans $colMean $GutterLum $MinCell
$rowSpans = Spans $rowMean $GutterLum $MinCell
Write-Host ("  grid: {0} columns x {1} rows = {2} cells" -f $colSpans.Count, $rowSpans.Count, ($colSpans.Count * $rowSpans.Count))

$cellCount = $colSpans.Count * $rowSpans.Count
if ($cellCount -ne $nameList.Count) {
    throw ("detected {0} cells but {1} names were given. Check the sheet, or pass -GutterLum / -MinCell to change detection. Names are positional and this script will not guess." -f $cellCount, $nameList.Count)
}

# ---- cut --------------------------------------------------------------------
$k = 0
foreach ($rs in $rowSpans) {
    foreach ($cs in $colSpans) {
        $x0 = $cs[0]; $x1 = $cs[1]; $y0 = $rs[0]; $y1 = $rs[1]
        $cw = $x1 - $x0 + 1; $ch = $y1 - $y0 + 1

        # label band: bright warm text, low in the cell. Searching only the lower part and
        # only the left half keeps warm highlights in the stone itself from matching.
        $cut = $y1
        if (-not $NoLabelTrim) {
            $ytop = $y1 - [int]($ch * $LabelZone)
            $xlim = $x0 + [int]($cw * 0.5)
            $firstText = $null
            for ($y = $ytop; $y -le $y1; $y++) {
                $n = 0
                for ($x = $x0; $x -le $xlim; $x++) {
                    $v = $px[$y*$w+$x]
                    $r = ($v -shr 16) -band 255; $g = ($v -shr 8) -band 255; $b = $v -band 255
                    if ($r -gt 175 -and $g -gt 145 -and $b -lt ($r - 55)) { $n++ }
                }
                if ($n -ge 4) { $firstText = $y; break }
            }
            if ($null -ne $firstText) { $cut = [Math]::Max($y0 + 8, $firstText - $LabelMargin) }
        }
        $keepH = $cut - $y0 + 1

        $dst = New-Object System.Drawing.Bitmap($cw, $keepH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g2 = [System.Drawing.Graphics]::FromImage($dst)
        $g2.DrawImage($src, (New-Object System.Drawing.Rectangle(0,0,$cw,$keepH)),
                      (New-Object System.Drawing.Rectangle($x0,$y0,$cw,$keepH)), [System.Drawing.GraphicsUnit]::Pixel)
        $g2.Dispose()
        $nm = $nameList[$k]
        if ($nm -notmatch '\.png$') { $nm = "$nm.png" }
        $dst.Save((Join-Path $OutDir $nm), [System.Drawing.Imaging.ImageFormat]::Png)
        $dst.Dispose()
        $trim = $y1 - $cut
        Write-Host ("  {0,-20} cell {1},{2} {3}x{4}  ->  {5}x{6}  (label trim {7}px)" -f `
                    $nm, $x0, $y0, $cw, $ch, $cw, $keepH, $trim)
        $k++
    }
}
$src.Dispose()
Write-Host ""
Write-Host ("{0} tiles -> {1}" -f $k, $OutDir) -ForegroundColor Green
