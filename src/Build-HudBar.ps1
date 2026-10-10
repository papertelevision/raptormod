# Build-HudBar.ps1 -- rebuild H1.PCX, the player-health fill, as a SOLID RECTANGLE
# sized to the reskinned panel's gauge recess.
#
# WHAT H1.PCX ACTUALLY IS. The gauge is two 105x15 surfaces created back to back at
# 0x284A4..0x28518: a frame (0x163A10) and a fill (0x163A22 = frame + 0x12). The fill
# surface's pixels are memcpy'd from a 1575-byte (105*15) buffer, and that buffer is
# H1.PCX. The draw at 0x11E2B blits the fill with `ecx` = how many columns to show,
# where ecx = (health >> 16) * 8 / 1000 -- so the bar's LENGTH is the health, but its
# SHAPE and COLOUR are entirely this file's.
#
# Mindscape's original is a tapered wedge in a banded gradient:
#
#   row  0-2   empty            <- only rows 3..11 of 15 are used at all
#   row  3     cols  8..61
#   row  5     cols  8..80      <- the right edge tapers row by row
#   row  9-10  cols  8..93
#   row 12-14  empty
#
# ...in eleven inks (#FAB01B #F7D05B #F7C139 #F6B512 #F59200 #F57200 #F55300 plus
# three browns). Against a reskin whose gauge recess is a clean rectangle that reads
# as the wrong shape in the wrong palette, which is exactly what it looked like.
#
# TWO THINGS THIS DELIBERATELY DOES NOT DO
#
# 1. It does not touch the palette. The reskin's own amber already lives at index 50
#    (HUD3 occupies 1..53 of the merged palette), so the pixels just point at it and
#    no entry has to be added or moved. See [[azrael-palette-budget]].
# 2. It keeps the STOCK palette bytes verbatim. H1.PCX's palette is merged into live
#    indices 58..71, so replacing it would recolour whatever else reads that slice.
#    Copying it through unchanged makes the merge byte-identical to stock.
#
# The engine side is NOT optional: Build-AztMod has to resize both gauge surfaces,
# both 1575-byte allocations, the memcpy length AND rescale the health divisor, or a
# wider bar simply gets clipped at 105 and full health never looks full.
param(
    [string]$ArtDir   = "$PSScriptRoot\..\art",
    [string]$StockH1  = "$PSScriptRoot\..\..\GAME\AZRAEL\H1.PCX",
    [int]   $W        = 0,        # 0 = take the gauge recess from art\hud-layout.json
    [int]   $H        = 0,
    # The vertical ramp, DARKEST EDGE FIRST and brightest last. All are HUD3 inks
    # (palette 1..53) picked for saturation, so the bar is lit like a tube: rust at
    # the top and bottom edges rising to amber through the middle, which is what
    # gives it depth. A flat fill was tried and read as a coloured block stuck onto
    # the panel.
    #   51 #733A07 rust     46 #A55D0E     21 #C9790F     27 #D58E12
    #   34 #E29E18          50 #F3B617 amber
    [int[]] $Ramp     = @(51, 46, 21, 27, 34, 50),
    # Rows left bare top and bottom. 0 = fill the recess, which is how the bar looked when it
    # was signed off. Mindscape''s own H1 insets by 3, but matching that only made our bar
    # shorter and did NOT remove the widening artefact -- do not "fix" it here again.
    [int]   $InsetY   = 0,
    # Ordered-dither the fractional position between adjacent ramp inks. ON: this is the
    # shading that was signed off. Turning it off was tried against the widening artefact,
    # did not remove it, and flattened the bar into hard bands.
    [bool]  $Dither   = $true
)
$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies "System.Drawing"

if ($W -le 0 -or $H -le 0) {
    $lf = Join-Path $ArtDir 'hud-layout.json'
    if (-not (Test-Path $lf)) { throw "need art\hud-layout.json to size the gauge (or pass -W/-H)" }
    $L = Get-Content $lf -Raw | ConvertFrom-Json
    # BY ASPECT, like every other region lookup -- the gauge is the only one wider
    # than 4:1, at any resolution. See [[azrael-resolution-asserts]].
    $g = @($L.regions | Where-Object { ($_.w / $_.h) -ge 4.0 } | Select-Object -First 1)[0]
    if (-not $g) { throw 'could not find the gauge recess in hud-layout.json' }
    # FILL IN ONLY WHAT WAS NOT GIVEN. This used to assign both whenever either was
    # missing, so `-H 15` alone was silently discarded and the layout's 14 came back --
    # which matters because the WIDTH comes from the recess but the HEIGHT must match
    # the gauge SURFACE, and $GAUGE_RESIZE_H is deliberately off (see the status-gauge
    # notes: the height half of the resize is the suspect half).
    if ($W -le 0) { $W = [int]$g.w }
    if ($H -le 0) { $H = [int]$g.h }
}
if ($W -le 0 -or $H -le 0) { throw "bad gauge size ${W}x${H}" }
if ($Ramp.Count -lt 2) { throw "the ramp needs at least two inks" }
foreach ($ink in $Ramp) {
    if ($ink -lt 1 -or $ink -gt 53) {
        throw "ink index $ink is outside the HUD's palette slice (1..53) -- it would not survive the merge"
    }
}

if (-not (Test-Path $StockH1)) { throw "need Mindscape's H1.PCX for its palette: $StockH1" }
$src = [LeTool.Pcx]::Load((Resolve-Path $StockH1).Path)

# THE ARTWORK IS NOT THE PROBLEM AND MUST NOT BE "FIXED" AGAIN.
#
# Three changes were made here chasing the artefact that appears when the gauge is widened --
# a 3-row transparent inset to match stock, dropping the dither, and pre-filling with the
# well's floor. NONE of them removed it, all three made the bar look worse, and all three are
# reverted. The bar at 105 wide with this exact code looked right; only the WIDTH changed when
# the artefact appeared, so the artefact is engine-side. See the status-gauge notes.
$pix = New-Object byte[] ($W * $H)
$y0  = [Math]::Max(0, $InsetY)
$y1  = $H - 1 - $y0
if ($y1 -lt $y0) { throw "inset $InsetY leaves no rows in a ${H}-row bar" }

# 4x4 ordered dither. With only ~14 rows a straight ramp gives one hard band per
# row, which reads as stripes; dithering the FRACTIONAL position between two
# adjacent inks breaks those boundaries up so it reads as a continuous fall-off.
$BAYER = @(@(0,8,2,10), @(12,4,14,6), @(3,11,1,9), @(15,7,13,5))
$rows  = $y1 - $y0 + 1
$mid   = ($y0 + $y1) / 2.0
$last  = $Ramp.Count - 1
# A FLAT CORE, or the bar never actually reaches its brightest ink. With an even
# row count there is no exact centre row, so the two middle rows sit at a fraction
# of the way up the ramp and dither to roughly 60% amber -- the highlight reads as
# muddy. Holding $Core rows at full brightness gives it a real hot line to fall
# away from, which is the whole point of shading it like a tube.
# PROPORTIONAL TO THE BAR'S HEIGHT, not a fixed number of rows. It was a flat 1.0,
# which is right at Mindscape's 15 rows and wrong at 23: the lit core stayed three
# rows while the fall-off stretched, so the bar read as a thin bright strip with
# thick dark edges -- "compacted vertically" -- instead of a taller tube. Scaling it
# keeps the same proportion of core to fall-off at any height, and reproduces 1.0 at
# 15 rows exactly, so this is a no-op at the size it was signed off.
$Core  = 1.0 * $rows / 15.0
$half  = [Math]::Max(0.5, (($rows - 1) / 2.0) - $Core)

for ($y = $y0; $y -le $y1; $y++) {
    # t = 0 across the core, rising to 1 at the top and bottom edges.
    $d = [Math]::Max(0.0, [Math]::Abs($y - $mid) - $Core)
    $t = $d / $half
    if ($t -gt 1.0) { $t = 1.0 }
    # Brightest (end of the ramp) at the centre, darkest (start) at the edges.
    $p   = (1.0 - $t) * $last
    $lo  = [int][Math]::Floor($p)
    if ($lo -gt $last) { $lo = $last }
    $frac = $p - $lo
    # ONE INK PER ROW unless -Dither is asked for. The dither was meant to hide the
    # band boundaries, and on a 14-row bar sunk in a dark well it does the opposite:
    # mixing two inks per row puts a scatter of single pixels along every boundary,
    # and the darkest one -- rust against the black well, at the bar's bottom edge --
    # reads as a line of particles sitting on top of the bar rather than as shading.
    # Nine rows over six inks gives a clean enough fall-off without it.
    $kRow = [int][Math]::Round($p)
    if ($kRow -lt 0) { $kRow = 0 } elseif ($kRow -gt $last) { $kRow = $last }
    for ($x = 0; $x -lt $W; $x++) {
        $k = $kRow
        if ($Dither) {
            $thr = $BAYER[$y % 4][$x % 4] / 16.0
            $k   = $lo
            if ($frac -gt $thr -and $k -lt $last) { $k = $lo + 1 }
        }
        $pix[$y*$W + $x] = [byte]$Ramp[$k]
    }
}

$out = New-Object LeTool.Pcx
$out.Width = $W; $out.Height = $H
$out.BitsPerPixel = 8; $out.Planes = 1; $out.BytesPerLine = $W
$out.Pixels = $pix
$out.Palette = $src.Palette.Clone()      # stock palette, so the 58..71 merge is unchanged
$dest = Join-Path $ArtDir 'H1.PCX'
$out.SavePcx($dest)

# REPORT THE COLOURS THE PLAYER WILL SEE, which are HUD3's entries -- not H1's own.
# H1's palette only populates live 58..71; indices 1..53 come from HUD3. Printing
# $src's entries here would name colours that never reach the screen.
$shown = ($Ramp | ForEach-Object { "$_" }) -join '>'
$hud3 = Join-Path $ArtDir 'HUD3.PCX'
if (Test-Path $hud3) {
    $hp = ([LeTool.Pcx]::Load((Resolve-Path $hud3).Path)).Palette
    $shown = ($Ramp | ForEach-Object { '#{0:X2}{1:X2}{2:X2}' -f $hp[$_*3], $hp[$_*3+1], $hp[$_*3+2] }) -join ' > '
}
Write-Host ("H1.PCX  health fill {0}x{1} -> {2}x{3} on {4} rows, {5} bytes" -f `
    $src.Width, $src.Height, $W, $H, $rows, ($W*$H))
Write-Host ("        dithered ramp, edge -> centre: {0}" -f $shown)
