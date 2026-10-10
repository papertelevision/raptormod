# Build-HudOverlay.ps1 -- generate HUDBOT.RES so the TOP of the notes/inventory
# housing overlaps the bottom of the 3D viewport.
#
# WHY THIS EXISTS. Build-HudArt copies the housing 1:1 into the panel band, but
# that band only starts at y=391 and the housing artwork starts at y~321, so the
# top ~20 rows of the lens were simply cut off. They cannot go in HUD3.PCX
# either: the viewport covers y 49..390 and overwrites that area every frame.
#
# The only way to draw there is the game's own overlay mechanism -- run-length
# data composited straight into the 3D framebuffer. That is what HUDTOP.RES /
# HUDBOT.RES are for, and it is what gave the stock HUD its soft interlock
# between panel and view.
#
# FORMAT (loader 0x109B8, applier 0x1E789):
#   <data> <dword wordCount> <dword destOffset>
#   data = `word run; run bytes; word skip`; the applier copies `run` bytes then
#   does edi += skip, so run+skip per row must equal the framebuffer STRIDE.
#   wordCount counts WORDS, not records -- there is a `dec ebx` after each.
#
# An earlier attempt re-authored the STOCK HUDBOT (the panel's full-width top
# edge) scaled to 0.55. It did not line up, because that silhouette belongs to a
# 640-wide panel while ours is 352 wide and centred. This builds the overlay from
# the housing artwork instead, at 1:1, using the exact same delta Build-HudArt
# uses -- so it cannot help but line up.
#
# NOTE: the 16 HUDTOP call sites stay NOPed. Stock HUDTOP.RES is still authored
# for a 552 stride and would smear; only HUDBOT is re-authored here.
[CmdletBinding()]
param(
    [string]$GameDir = '',      # '' = the stock game this repo sits in: <Steam>\Azrael's Tear\GAME\AZRAEL
    [string]$OutDir  = "$PSScriptRoot\..\art",
    [int]   $ViewY   = 49,
    [int]   $ViewW   = 640,
    [int]   $ViewH   = 342,
    [int]   $PanelTop = 391,
    # these MUST match Build-AztMod.ps1 / Build-HudArt.ps1
    [int]   $InvSrcX = 28,
    [int]   $InvSrcR = 197,
    [int]   $InvDx   = 62,
    [int]   $InvDy   = 51,
    # top of the housing artwork; 318 is the stock panel top, a natural boundary
    [int]   $InvSrcTop = 318,
    # first housing row that lands INSIDE the panel band -- Build-HudArt's $invSrcY
    [int]   $InvSrcY = 340,
    # target resolution, so the overlay scales exactly as Build-HudArt does
    [int]   $ScreenW = 640,
    [int]   $ScreenH = 480,
    # first row of instrument-panel artwork in design space (Build-HudArt's $PANEL_TOP)
    [int]   $PanelSrcTop = 318
)
if (-not $GameDir) { $GameDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'GAME\AZRAEL' }      # (in the body: $PSScriptRoot is empty in param() under -File)

$ErrorActionPreference = 'Stop'
if (-not ("LeTool.Pcx" -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies "System.Drawing"
}
New-Item -ItemType Directory -Force $OutDir | Out-Null

$src = [LeTool.Pcx]::Load((Resolve-Path (Join-Path $GameDir 'HUD3.PCX')).Path)
function Lum([int]$i) { [int](0.3*$src.Palette[$i*3] + 0.59*$src.Palette[$i*3+1] + 0.11*$src.Palette[$i*3+2]) }

$HS = $ScreenW / 640.0
if ([Math]::Abs($ScreenH / 480.0 - $HS) -gt 0.001) {
    throw "$ScreenW x $ScreenH is not 4:3 like 640x480; one uniform scale will not do"
}

# Rows of the housing that land ABOVE the panel band, i.e. inside the viewport.
# $InvSrcY is where Build-HudArt starts the panel-band copy, so everything above
# it is what gets cut off and has to come from here.
$srcBottom = $InvSrcY - 1
if ($srcBottom -lt $InvSrcTop) { throw "no housing rows land inside the viewport" }
# At 640x480 that has to reduce to the old `$PanelTop - $InvDy - 1`, or this is
# no longer the same overlay.
if ($HS -eq 1.0 -and $srcBottom -ne ($PanelTop - $InvDy - 1)) {
    throw "the 1:1 case changed: srcBottom $srcBottom vs $($PanelTop - $InvDy - 1)"
}

# Only the LENS belongs in the overlay, not the dark panel surround -- drawing the
# whole rectangle would put a hard-edged block over the 3D, the opposite of the
# point. Take everything bright enough to be lens, then grow by one pixel so the
# real dark rim comes with it and the edge reads as artwork rather than a cut.
$LENS = 40
$keep = @{}
for ($y = $InvSrcTop; $y -le $srcBottom; $y++) {
    for ($x = $InvSrcX; $x -le $InvSrcR; $x++) {
        if ((Lum $src.Pixels[$y*640 + $x]) -gt $LENS) { $keep["$x,$y"] = $true }
    }
}
$grown = @{}
foreach ($k in $keep.Keys) {
    $p = $k -split ','; $x = [int]$p[0]; $y = [int]$p[1]
    for ($dy = -1; $dy -le 1; $dy++) {
        for ($dx = -1; $dx -le 1; $dx++) {
            $nx = $x + $dx; $ny = $y + $dy
            if ($nx -ge $InvSrcX -and $nx -le $InvSrcR -and $ny -ge $InvSrcTop -and $ny -le $srcBottom) {
                $grown["$nx,$ny"] = $true
            }
        }
    }
}

# Map to view-local framebuffer offsets using the SAME geometry as the artwork.
#
# Build-HudArt places the housing at
#     x: round(($InvSrcX + $InvDx) * HS), width round($invW * HS)
#     y: the panel band, i.e. source row $InvSrcY lands exactly on $PanelTop
# so the rows above $InvSrcY run upward from $PanelTop at the same scale. Both
# axes are therefore derived from the art's own numbers rather than re-guessed.
#
# ITERATE OVER DESTINATION PIXELS, not source. Scaling UP maps several dest
# pixels to one source pixel, and a source-driven loop would leave unwritten
# holes scattered through the lens.
$invW    = $InvSrcR - $InvSrcX + 1
$srcRows = $InvSrcY - $InvSrcTop

$dstX0 = [int][Math]::Round(($InvSrcX + $InvDx) * $HS)
$dstW  = [int][Math]::Round($invW * $HS)

# THE TWO AXES DO NOT SHARE A SCALE, because Build-HudArt's housing blit does not
# either: it maps src ($invW x $panelH) onto dst ($invWDst x $newPanelH), i.e.
#   x by $HS            (the housing keeps screen scale -- it is not shrunk)
#   y by newPanelH/162  (it IS squashed, to fit the rescaled panel band)
# At 800x600 that is x1.25 horizontally but x0.685 vertically.
#
# Using $HS for Y stretched the lens TOP by 1.27 while the lens BODY below it was
# squashed by 0.685 -- a 1.9x mismatch, which read as a hard horizontal seam
# across the middle of the lens with a far-too-tall dome above it. The overlay is
# a CONTINUATION of the panel artwork, so it has to use the panel's own Y scale.
$panelSrcH = 480 - $PanelSrcTop            # 162 rows of panel art in design space
$panelDstH = $ScreenH - $PanelTop          # what Build-HudArt squashed it into
$vScale    = $panelDstH / $panelSrcH

$dstY1 = $PanelTop - 1
$dstH  = [int][Math]::Round($srcRows * $vScale)
$dstY0 = $PanelTop - $dstH
if ($dstH -lt 1) { throw "the overlay would be less than one row tall" }

# COLOUR COMES FROM THE SAME RESAMPLER AS THE ARTWORK. Picking the nearest source
# pixel per destination pixel left the lens top visibly grainy against the smooth
# BlitScaledSmooth-ed panel directly below it -- the join was geometrically right
# but read as dithered noise meeting clean shading. So scale the region with the
# very same call Build-HudArt uses and read the colours back out of it.
# (The MASK is still decided in source space; only the shading is resampled.)
$canvas = New-Object LeTool.Pcx
$canvas.Width = $ViewW; $canvas.Height = $PanelTop
$canvas.Pixels = New-Object byte[] ($ViewW * $PanelTop)
$canvas.Palette = $src.Palette
$bg = $src.Pixels[0]
$canvas.FillRect(0, 0, $ViewW, $PanelTop, $bg)
$canvas.BlitScaledSmooth($src, $InvSrcX, $InvSrcTop, $invW, $srcRows, $dstX0, $dstY0, $dstW, $dstH, $bg)

$px = @{}
for ($dy = $dstY0; $dy -le $dstY1; $dy++) {
    $sy = $InvSrcTop + [int][Math]::Floor(($dy - $dstY0) * $srcRows / $dstH)
    if ($sy -lt $InvSrcTop) { $sy = $InvSrcTop } elseif ($sy -gt $srcBottom) { $sy = $srcBottom }
    $vy = $dy - $ViewY
    if ($vy -lt 0 -or $vy -ge $ViewH) { continue }
    for ($dx = $dstX0; $dx -lt $dstX0 + $dstW; $dx++) {
        if ($dx -lt 0 -or $dx -ge $ViewW) { continue }
        $sx = $InvSrcX + [int][Math]::Floor(($dx - $dstX0) * $invW / $dstW)
        if ($sx -lt $InvSrcX) { $sx = $InvSrcX } elseif ($sx -gt $InvSrcR) { $sx = $InvSrcR }
        if (-not $grown.ContainsKey("$sx,$sy")) { continue }
        $px[$vy * $ViewW + $dx] = $canvas.Pixels[$dy * $ViewW + $dx]
    }
}
if ($px.Count -eq 0) { throw "overlay is empty" }

# --- encode ------------------------------------------------------------------
$offsets = @($px.Keys | Sort-Object)
$destOff = [int]($offsets[0] / $ViewW) * $ViewW
$out = New-Object System.Collections.Generic.List[byte]
$words = 0; $cur = $destOff; $i = 0
while ($i -lt $offsets.Count) {
    $start = $offsets[$i]; $j = $i
    while ($j + 1 -lt $offsets.Count -and $offsets[$j+1] -eq $offsets[$j] + 1) { $j++ }
    $len = $offsets[$j] - $start + 1
    $gap = $start - $cur
    if ($words -gt 0) {
        $out.Add([byte]($gap -band 0xFF)); $out.Add([byte](($gap -shr 8) -band 0xFF)); $words++
    } elseif ($gap -ne 0) {
        $out.Add(0); $out.Add(0); $words++
        $out.Add([byte]($gap -band 0xFF)); $out.Add([byte](($gap -shr 8) -band 0xFF)); $words++
    }
    $out.Add([byte]($len -band 0xFF)); $out.Add([byte](($len -shr 8) -band 0xFF)); $words++
    for ($k = $start; $k -le $offsets[$j]; $k++) { $out.Add([byte]$px[$k]) }
    $cur = $start + $len; $i = $j + 1
}
$lastByte = $cur - 1
if ($lastByte -ge $ViewW * $ViewH) { throw "overlay would write past the framebuffer ($lastByte >= $($ViewW*$ViewH))" }
$out.AddRange([byte[]][BitConverter]::GetBytes([int]$words))
$out.AddRange([byte[]][BitConverter]::GetBytes([int]$destOff))
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'HUDBOT.RES'), $out.ToArray())

$r0 = [int]($offsets[0] / $ViewW); $r1 = [int]($offsets[-1] / $ViewW)
Write-Host ("HUDBOT.RES  housing rows {0}..{1} -> screen y {2}..{3} (view rows {4}..{5}), x {6}..{7}" -f `
    $InvSrcTop, $srcBottom, $dstY0, $dstY1, $r0, $r1, $dstX0, ($dstX0+$dstW-1))
Write-Host ("            {0} px, {1} words, offset {2}, last byte {3} of {4}, {5:N0} bytes (scale {6:N2})" -f `
    $px.Count, $words, $destOff, $lastByte, ($ViewW*$ViewH), $out.Count, $HS)
