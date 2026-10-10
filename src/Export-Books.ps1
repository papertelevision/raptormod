# Export-Books.ps1 -- dump the readable book/scroll pages to PNG for re-authoring.
#
#   .\src\Export-Books.ps1 -OutDir C:\Games\azrael-books
#
# The counterpart to Build-Books.ps1's -InDir. Put the improved PNGs back with:
#   .\src\Build-Books.ps1 -InDir <that folder>
#
# EXPORTS THE PRISTINE ART, NOT WHAT IS INSTALLED. Build-Books keeps each page's original
# 640x480 beside the rescaled one as <name>.PCX.src, and this prefers the .src. Handing an
# upscaler the 1024x768 rescale would be upscaling an upscale -- it would sharpen the
# resampler's own softness rather than the 1996 artwork.
#
# WHAT THE REPLACEMENT ART MUST RESPECT (Build-Books enforces the palette, but the artist
# should know why the pages look the way they do):
#
#   PAGES MAY ONLY USE PALETTE INDICES 128..255. Measured, not assumed: every stock page has
#   zero pixels below 128. The low half of the palette belongs to whatever else is resident
#   while a page is up, and writing into it turned an earlier replacement into a screenful of
#   dithering dots. Build-Books quantises new art into 128 colours at base index 128 and
#   copies entries 0..127 from the stock page untouched -- so the replacement effectively has
#   HALF a palette. Flat, high-contrast, text-forward art survives that; photographic
#   gradients do not.
#
#   Size is free. The pages are rescaled to the screen on import (1024x768), so supply
#   whatever resolution the tool produces.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$BookDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX\BOOKS',
    [switch]$Installed          # export what is installed rather than the pristine .src
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing
if (-not (Test-Path $BookDir)) { throw "book folder not found: $BookDir" }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$n = 0; $skipped = @(); $fromSrc = 0
foreach ($f in (Get-ChildItem $BookDir -Filter '*.PCX' | Sort-Object Name)) {
    if ($f.Length -lt 100) { $skipped += ("{0} (empty in the original)" -f $f.Name); continue }
    $src = "$($f.FullName).src"
    $use = if (-not $Installed -and (Test-Path $src)) { $fromSrc++; $src } else { $f.FullName }
    try { $p = [LeTool.Pcx]::Load($use) } catch { $skipped += ("{0} ({1})" -f $f.Name, $_.Exception.Message); continue }
    $out = Join-Path $OutDir ($f.BaseName + '.png')
    $p.SavePng($out, 1)
    $hist = $p.Histogram()
    $lo = 0; for ($i = 0; $i -lt 128; $i++) { $lo += $hist[$i] }
    Write-Host ("  {0,-14} {1,4}x{2,-4} -> {3}{4}" -f $f.Name, $p.Width, $p.Height, (Split-Path $out -Leaf),
                $(if ($lo) { "   (WARNING: {0:N0} px below index 128)" -f $lo } else { '' }))
    $n++
}

Write-Host ""
Write-Host ("{0} page(s) -> {1}   ({2} from the pristine .src)" -f $n, $OutDir, $fromSrc) -ForegroundColor Green
if ($skipped.Count) { Write-Host ("skipped {0}: {1}" -f $skipped.Count, ($skipped -join ', ')) -ForegroundColor Yellow }
Write-Host ""
Write-Host "Put the improved PNGs back with the SAME base names:"
Write-Host ("  .\src\Build-Books.ps1 -InDir {0}" -f $OutDir)
