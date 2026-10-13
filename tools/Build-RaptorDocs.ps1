# Build-RaptorDocs.ps1 -- RAPTOR DOCS' files for the title screen (tools\RaptorDocs.cs): the manual's text and the classified
# print-outs, from Josh's sources into the game install.
#
#   powershell -ExecutionPolicy Bypass -File tools\Build-RaptorDocs.ps1
#   powershell -ExecutionPolicy Bypass -File tools\Build-RaptorDocs.ps1 -GameDir C:\Games\AzraelsTear-Modded -Source C:\Games\azrael-gfx
#
# Sources:
#   <TextDir>\manual.txt       the 1996 manual, OCR'd and proofread against its scan (the markup is in its header)
#   <TextDir>\classified.txt   the print-outs in order: <path under Source> | title | the line under it
#     TextDir = this repo's raptordocs\ (Josh, 2026-10-13: the text is versioned in this private repo -- it never goes
#     public; a separate distribution repo comes later)
#   <Source>\<path>            the print-outs' scans (the asset pack's gfx component: they stay OUT of git)
# Writes <GameDir>\raptordocs (the watcher hands it to the title as GameGate.TitleDocs):
#   manual.txt, classified.txt (file | title | line), classified\NN.jpg (each scan as a JPEG at its full size).
# Run it again after changing either source; the watcher reads the files when the title opens.
[CmdletBinding()]
param(
    [string]$GameDir = 'C:\Games\AzraelsTear-Modded',
    [string]$Source = 'C:\Games\azrael-gfx',
    [string]$TextDir = '',          # ('' = the repo's raptordocs\, from this script's own path: $PSScriptRoot is empty in a param default)
    [ValidateRange(50, 100)][int]$Quality = 92
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not $TextDir) { $TextDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'raptordocs' }
$src = $TextDir
foreach ($p in @($GameDir, (Join-Path $src 'manual.txt'), (Join-Path $src 'classified.txt'))) { if (-not (Test-Path $p)) { throw "not found: $p" } }
$out = Join-Path $GameDir 'raptordocs'; $cls = Join-Path $out 'classified'
New-Item -ItemType Directory -Force -Path $cls | Out-Null

# the manual: as it is (the title parses it)
Copy-Item (Join-Path $src 'manual.txt') (Join-Path $out 'manual.txt') -Force
$chapters = @([IO.File]::ReadAllLines((Join-Path $src 'manual.txt')) | Where-Object { $_ -like '@chapter *' }).Count
Write-Host ("manual      {0} chapters -> {1}" -f $chapters, (Join-Path $out 'manual.txt')) -ForegroundColor Green

# the print-outs: each scan as a JPEG, in order
$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$ep = New-Object Drawing.Imaging.EncoderParameters 1
$ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), ([long]$Quality)
Get-ChildItem $cls -Filter '*.jpg' | Remove-Item -Force          # (a file dropped from the list goes too)
$index = New-Object System.Collections.Generic.List[string]
$index.Add('// RAPTOR DOCS -- the classified print-outs (written by tools\Build-RaptorDocs.ps1 from ' + (Join-Path $src 'classified.txt') + '): file | title | line')
$n = 0
foreach ($line in [IO.File]::ReadAllLines((Join-Path $src 'classified.txt'))) {
    $l = $line.Trim(); if (-not $l -or $l.StartsWith('//')) { continue }
    $f = @($l -split '\|' | ForEach-Object { $_.Trim() })
    $from = Join-Path $Source $f[0]; if (-not (Test-Path $from)) { throw "print-out not found: $from" }
    $n++; $name = '{0:00}.jpg' -f $n
    $img = [Drawing.Image]::FromFile($from)
    try { $img.Save((Join-Path $cls $name), $jpeg, $ep); $size = '{0} x {1}' -f $img.Width, $img.Height } finally { $img.Dispose() }
    $title = $(if ($f.Count -gt 1) { $f[1] } else { [IO.Path]::GetFileNameWithoutExtension($from).ToUpperInvariant() })
    $sub = $(if ($f.Count -gt 2) { $f[2] } else { '' })
    $index.Add(('{0} | {1} | {2}' -f $name, $title, $sub))
    Write-Host ("classified  {0}  {1,-12} {2:N1} MB  {3}" -f $name, $size, ((Get-Item (Join-Path $cls $name)).Length / 1MB), $title) -ForegroundColor Green
}
[IO.File]::WriteAllLines((Join-Path $out 'classified.txt'), $index, (New-Object Text.UTF8Encoding($false)))
Write-Host ("{0} print-out(s) -> {1}" -f $n, $cls) -ForegroundColor Green
