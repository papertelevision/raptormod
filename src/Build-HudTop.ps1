# Build-HudTop.ps1 -- generate HUDTOP.RES so the 3D viewport gets its VISOR back.
#
# WHY. The stock game's viewport was not a rectangle: it read as a curved
# faceplate. That shape is not in the HUD artwork -- it comes from HUDTOP.RES, a
# run-length overlay the game composites straight into the 3D framebuffer after
# rendering. AztMod NOPs all 16 HUDTOP call sites because the stock file is
# authored for a 552-wide view and smears at any other width, so the curve went
# with it and the view became a hard rectangle.
#
# THE CURVE IS MINDSCAPE'S OWN, RESAMPLED. An earlier version approximated it
# with a 26 px corner radius, which is far too tight and reads as a clipped
# corner rather than glass. Decoding the stock file settles what the shape
# actually is -- 22 rows deep on a 282-tall view, a quarter of the width per side
# at row 1, and row 0 inked edge to edge:
#
#   row  0: full width      row  4: 94/90       row  12: 29/25
#   row  1: 137/134         row  8: 56/51       row  21: 1/0
#
# So this reads that profile out of the stock file and scales it to whatever view
# it is asked for. No curve is invented: the faceplate is the one the artists
# drew, at the new resolution.
#
# THE TRAILERS ARE NOT THE SAME LENGTH. This cost a crash. The loader at 0x109B8
# handles the two files with different code:
#
#   HUDTOP                                HUDBOT
#   lea ebx, [eax-0x4]   <-- minus 4      lea ebx, [eax-0x8]   <-- minus 8
#   read ebx -> [0x1523CC]                read ebx -> [0x1523D0]
#   read 4   -> [0x1523C4]  word count    read 4   -> [0x1523C8]  word count
#                                         read 4   -> [0x1523BC]  dest offset
#
# So HUDTOP.RES is:
#
#   <data> <dword wordCount>              -- FOUR bytes of trailer, no dest offset
#   data = `word run; run bytes; word skip`
#   wordCount counts WORDS, not records.
#
# HUDTOP has NO destination offset field: its destination is whatever pointer the
# call site passes, i.e. the top-left of the view. Writing HUDBOT's 8-byte trailer
# here makes the game read the word-count dword as stream data and take the
# destOffset dword (0) as the count -- and 0x1E789 is a do-while (`dec ebx; jz`),
# so a count of zero decrements to 0xFFFFFFFF and sprays memory for four billion
# iterations. That is the "Gate Selector points to illegal descriptor" crash.
[CmdletBinding()]
param(
    [string]$OutDir = "$PSScriptRoot\..\art",
    [int]   $ViewW  = 800,
    [int]   $ViewH  = 440,
    # Bottom-corner radius in 640x480 DESIGN space. It now sits UNDER the mirrored
    # bottom sweep rather than being the whole of the bottom edge, so it only has to
    # round off whatever the sweep leaves in the extreme corners. Was the only shape
    # down there before -- see $NoMirrorBottom.
    [int]   $Radius = 26,
    [int]   $ScreenW = 800,
    # Mindscape's file, read for its curve only.
    [string]$StockRes = "$PSScriptRoot\..\..\GAME\AZRAEL\HUDTOP.RES",
    # Bevel highlight depth in 640-space pixels; 0 disables it.
    # THREE SEPARATE ELEMENTS. Each is measured from a different thing, which is
    # the whole trick -- driving them from one value is what flattened the sweep
    # into a bar on the previous attempt.
    #
    #   FadeRim  -- how far INTO the shell the glass dissolve reaches, from the
    #               curve. Short: this is the edge of the glass, not the haze.
    #   Vignette -- how far OUT INTO THE VIEW the black haze reaches, from the
    #               curve. This is the depth cue; it follows the sweep, so it is
    #               naturally deepest at the corners and thinnest in the middle.
    #   GlintFrac / GlintAlpha -- the bronze catch-light hugging the curve, as a
    #               FRACTION of each column's depth (so it is thin in the middle
    #               and wide at the corners, like the stock shape) and how dense
    #               it is allowed to get (low = faint).
    [int]    $FadeRim  = 8,
    [int]    $Vignette = 40,
    [double] $VigStart = 0.55,
    #               GlintAlpha 0 turns the bronze off entirely, which is the
    #               shipped setting: the black haze alone gives the depth, and the
    #               metal on the rim fought the instrument panel for attention.
    #               Raise it to bring the catch-light back.
    #
    #               TRIED AT 0.5 AND REJECTED, with the sweep mirrored top and
    #               bottom, on the theory that pure black only reads as a border
    #               where it sits over something bright -- the amber CRT during the
    #               boot, nothing during gameplay. It lit both rims as intended and
    #               was still the wrong look. The dark dithered haze alone is the
    #               one that was signed off; it is not a visibility problem to fix.
    [double] $GlintFrac  = 0.55,
    [double] $GlintAlpha = 0.0,
    # Minimum sweep depth across the WHOLE width, in 640-space pixels. Mindscape's
    # curve tapers to a single row at the centre, which at this resolution reads
    # as a hairline rather than the edge of a faceplate -- there is no room in one
    # pixel to show a bevel at all. This gives the middle some thickness to bevel
    # into; the sides still get the full sweep on top of it.
    # Thin again now that the vignette carries the depth below it.
    [int]   $MinTop = 6,
    # The faceplate sweep and its haze are mirrored along the BOTTOM of the view as
    # well as the top, so the glass has two edges instead of one. Pass this to go
    # back to the old behaviour: small rounded bottom corners in flat black.
    [switch] $NoMirrorBottom,
    # NOTHING along the bottom: the widescreen panel (Build-HudWide.ps1, 2026-10-06) is its own
    # edge, and the bottom haze read as a dotted black band over the 3D beside it (Josh: make it
    # transparent). The top sweep is unchanged.
    [switch] $NoBottom
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null

$INK = 54                                   # #000000, as the stock overlays use
$HS  = $ScreenW / 640.0
$R   = [int][Math]::Round($Radius * $HS)
if ($R -lt 2) { throw "corner radius $R is too small to be visible" }

# --- read the stock curve ----------------------------------------------------
$STOCK_W = 552; $STOCK_H = 282
if (-not (Test-Path $StockRes)) { throw "stock HUDTOP.RES not found: $StockRes (needed for the visor curve)" }
$sd = [System.IO.File]::ReadAllBytes($StockRes)
$swc = [BitConverter]::ToInt32($sd, $sd.Length - 4)
$sink = @{}
$sp = 0; $sw = 0; $sc = 0
while ($sw -lt $swc -and $sp -lt ($sd.Length - 4)) {
    $run = [BitConverter]::ToUInt16($sd, $sp); $sp += 2; $sw++
    for ($k = 0; $k -lt $run; $k++) { $sink[$sc + $k] = 1 }
    $sp += $run; $sc += $run
    if ($sw -lt $swc) { $skip = [BitConverter]::ToUInt16($sd, $sp); $sp += 2; $sw++; $sc += $skip }
}
if ($sink.Count -lt 1000) { throw "stock HUDTOP.RES decoded to only $($sink.Count) px -- wrong file?" }

# Per-row spans, measured inward from each edge. Row 0 is inked edge to edge, so
# both halves are simply the half width.
$maxSrcRow = 0
foreach ($o in $sink.Keys) { $y = [int][Math]::Floor($o / $STOCK_W); if ($y -gt $maxSrcRow) { $maxSrcRow = $y } }
$SL = New-Object 'double[]' ($maxSrcRow + 1)
$SR = New-Object 'double[]' ($maxSrcRow + 1)
for ($y = 0; $y -le $maxSrcRow; $y++) {
    # NOT $l / $r. PowerShell identifiers are CASE-INSENSITIVE, so a loop counter
    # called $r silently IS $R, the corner radius -- which zeroed it and made the
    # bottom corners disappear. Same trap as $w vs $ViewW.
    [int]$lspan = 0; while ($lspan -lt $STOCK_W -and $sink.ContainsKey($y*$STOCK_W + $lspan)) { $lspan++ }
    [int]$rspan = 0; while ($rspan -lt $STOCK_W -and $sink.ContainsKey($y*$STOCK_W + ($STOCK_W-1-$rspan))) { $rspan++ }
    # a row that meets in the middle is full width; clamp both halves to that
    if ($lspan + $rspan -ge $STOCK_W) { $lspan = [int]($STOCK_W/2); $rspan = $STOCK_W - $lspan }
    $SL[$y] = $lspan; $SR[$y] = $rspan
}

# --- build the mask ----------------------------------------------------------
$XS = $ViewW / [double]$STOCK_W
$YS = $ViewH / [double]$STOCK_H
[int]$topRows = [int][Math]::Ceiling(($maxSrcRow + 1) * $YS)
if ($topRows -ge $ViewH) { throw "the visor curve ($topRows rows) does not fit a ${ViewW}x${ViewH} view" }

$inked = New-Object 'bool[]' ($ViewW * $ViewH)
[int]$minRows = [int][Math]::Round($MinTop * $HS)
if ($minRows -ge $topRows) { throw "MinTop ($minRows rows) is as deep as the whole sweep ($topRows)" }
for ($y = 0; $y -lt $minRows; $y++) {
    for ($x = 0; $x -lt $ViewW; $x++) { $inked[$y*$ViewW + $x] = $true }
}
for ($y = 0; $y -lt $topRows; $y++) {
    # linear between the two nearest stock rows, so the curve stays smooth
    $sy = $y / $YS
    [int]$y0 = [Math]::Min($maxSrcRow, [int][Math]::Floor($sy))
    [int]$y1 = [Math]::Min($maxSrcRow, $y0 + 1)
    $f  = $sy - $y0
    [int]$lw = [int][Math]::Round((($SL[$y0] * (1-$f)) + ($SL[$y1] * $f)) * $XS)
    [int]$rw = [int][Math]::Round((($SR[$y0] * (1-$f)) + ($SR[$y1] * $f)) * $XS)
    for ($x = 0; $x -lt $lw -and $x -lt $ViewW; $x++) { $inked[$y*$ViewW + $x] = $true }
    for ($x = 0; $x -lt $rw -and $x -lt $ViewW; $x++) { $inked[$y*$ViewW + ($ViewW-1-$x)] = $true }
}
# ---- THE SAME SWEEP, MIRRORED ALONG THE BOTTOM ------------------------------
# The bottom used to get nothing but small rounded corners and flat black, on the
# reasoning that it meets the instrument panel so there is no outside light to catch
# and no view beyond it to haze into. In the enlarged viewport that reads as a
# faceplate with only one edge: the top dissolves into the view and the bottom stops
# at a hard line.
#
# Mirrored row for row from the SAME stock profile, so this is still Mindscape's
# curve rather than an invented one -- see the header. Only the mask is built here;
# the haze that makes it read as glass is added in the sweep below.
if (-not $NoMirrorBottom) {
    for ($y = 0; $y -lt $minRows; $y++) {
        [int]$by = $ViewH - 1 - $y
        if ($by -lt 0) { break }
        for ($x = 0; $x -lt $ViewW; $x++) { $inked[$by*$ViewW + $x] = $true }
    }
    for ($y = 0; $y -lt $topRows; $y++) {
        [int]$by = $ViewH - 1 - $y
        if ($by -lt $topRows) { break }        # the two sweeps would meet: stop
        $sy = $y / $YS
        [int]$y0 = [Math]::Min($maxSrcRow, [int][Math]::Floor($sy))
        [int]$y1 = [Math]::Min($maxSrcRow, $y0 + 1)
        $f  = $sy - $y0
        [int]$lw = [int][Math]::Round((($SL[$y0] * (1-$f)) + ($SL[$y1] * $f)) * $XS)
        [int]$rw = [int][Math]::Round((($SR[$y0] * (1-$f)) + ($SR[$y1] * $f)) * $XS)
        for ($x = 0; $x -lt $lw -and $x -lt $ViewW; $x++) { $inked[$by*$ViewW + $x] = $true }
        for ($x = 0; $x -lt $rw -and $x -lt $ViewW; $x++) { $inked[$by*$ViewW + ($ViewW-1-$x)] = $true }
    }
}

# ordinary rounded corners along the bottom
$r2 = [double]($R * $R)
foreach ($cx in @(0, ($ViewW - 1))) {
    [int]$sx = $(if ($cx -eq 0) { 1 } else { -1 })
    for ($i = 0; $i -lt $R; $i++) {
        for ($j = 0; $j -lt $R; $j++) {
            $dx = ($R - $i) - 0.5; $dy = ($R - $j) - 0.5
            if (($dx*$dx + $dy*$dy) -le $r2) { continue }
            [int]$x = $cx + $sx * $i; [int]$y = ($ViewH - 1) - $j
            if ($x -lt 0 -or $x -ge $ViewW -or $y -lt $topRows) { continue }
            $inked[$y*$ViewW + $x] = $true
        }
    }
}

# --- the bevel ---------------------------------------------------------------
# A faceplate is glass with a thickness, so its inner rim catches light. Depth is
# measured PER COLUMN from the curve's inner edge, which keeps the highlight an
# even thickness all along the sweep -- eroding from every boundary instead makes
# the band collapse wherever the curve is only a pixel or two deep.
#
# The ramp is DITHERED between steps: the palette has a pearl and a brass but
# nothing between them, so an ordered dither is the only way to get a gradient
# out of four colours. 45/40/10 are inside the HUD's own 1..53 budget, so this
# follows the reskin instead of fighting it.
# BRONZE, not gold. The first pass topped out at 53 #EDD773, whose green sits
# almost as high as its red -- that is a yellow, and it read as brass polish
# rather than the aged bronze the instrument panel is made of. This starts lower
# and browner, and runs NINE steps so most of the band is dark: the eye reads the
# average, so a long tail to black is what makes it sit back.
#   22 #CCAE68  bronze catching light -- the rim
#   47 #AD9762  lit bronze            42 #8F7536  bronze
#   44 #7D5C29  shadowed bronze       14 #715319  dark bronze
#   11 #54491D  deep bronze           10 #443919  near-black bronze
#    2 #2B2918  the last warmth before black
#   54 #000000  the plate
# All inside the HUD's own 1..53 budget, so this tracks the panel reskin.
$RAMP = @(22, 47, 42, 44, 14, 11, 10, 2, $INK)
# 4x4 ordered rather than 2x2: six ramp steps over ~11 px needs finer thresholds
# than four cells can express, and coarse dither on a curve reads as staircasing.
$BAYER = @(
     0, 8, 2,10,
    12, 4,14, 6,
     3,11, 1, 9,
    15, 7,13, 5) | ForEach-Object { $_ / 16.0 }
[int]$FR = [Math]::Max(1, [int][Math]::Round($FadeRim * $HS))   # glass dissolve
[int]$VD = [Math]::Max(1, [int][Math]::Round($Vignette * $HS))  # haze into the view

# SCREEN-DOOR TRANSPARENCY. The overlay writes palette indices straight into the
# framebuffer -- there is no alpha and no blend, so the only way to see glass
# rather than paint is to leave some pixels UNWRITTEN and let the 3D show
# through. Coverage rises with depth: almost nothing survives at the inner rim,
# everything does by the time the bevel reaches the frame.
#
# 8x8 ordered rather than the 4x4 used for colour: coverage needs 64 distinct
# levels to look like a gradient instead of a screen mesh, where four steps of
# hue only need 16.
$COVER = @(
     0,32, 8,40, 2,34,10,42,
    48,16,56,24,50,18,58,26,
    12,44, 4,36,14,46, 6,38,
    60,28,52,20,62,30,54,22,
     3,35,11,43, 1,33, 9,41,
    51,19,59,27,49,17,57,25,
    15,47, 7,39,13,45, 5,37,
    63,31,55,23,61,29,53,21) | ForEach-Object { ($_ + 0.5) / 64.0 }

# Both take U in 0..1, but they measure from OPPOSITE ends and that is the point.
# Test-Cover's u is distance from the CURVE (0 = the glass edge, dissolve) and
# Get-Ink's u is distance from the SCREEN EDGE (1 = lit bronze, 0 = black).
# Light arrives from outside the helmet; the glass ends at the sweep. Driving
# both from one value lit the wrong side, and driving both from the column depth
# made every column look alike and erased the curve.
function Test-Cover {
    param([double]$u, [int]$x, [int]$y)
    if ($u -ge 1.0) { return $true }
    return ($u -gt $COVER[(($y % 8) * 8) + ($x % 8)])
}

# The catch-light. g is 1 right on the curve and 0 where the glint runs out.
# It is deliberately weak: GlintAlpha caps how many pixels are allowed to be
# bronze at all, so even at full strength it is a scatter of dark metal over
# black rather than a painted line. Anything denser stops reading as a glint and
# starts reading as trim.
function Get-Ink {
    param([double]$g, [int]$x, [int]$y)
    if ($GlintAlpha -le 0.0 -or $g -le 0.0) { return [byte]$INK }
    if (($g * $GlintAlpha) -le $COVER[(($y % 8) * 8) + ($x % 8)]) { return [byte]$INK }
    $t = (1.0 - $g) * ($RAMP.Count - 1)
    [int]$lo = [int][Math]::Floor($t)
    [int]$hi = [Math]::Min($RAMP.Count - 1, $lo + 1)
    $frac = $t - $lo
    $th = $BAYER[(($y % 4) * 4) + ($x % 4)]
    return [byte]$(if ($frac -gt $th) { $RAMP[$hi] } else { $RAMP[$lo] })
}

$px = @{}
for ($x = 0; $x -lt $ViewW; $x++) {
    # top sweep: the rim is the LAST inked row in this column
    [int]$edge = -1
    for ($y = $topRows - 1; $y -ge 0; $y--) { if ($inked[$y*$ViewW + $x]) { $edge = $y; break } }
    if ($edge -ge 0) {
        # the shell, plus the catch-light hugging the curve
        [int]$gd = [Math]::Max(1, [int][Math]::Round($edge * $GlintFrac))
        for ($y = 0; $y -le $edge; $y++) {
            if (-not $inked[$y*$ViewW + $x]) { continue }
            [int]$dRim = $edge - $y
            [double]$cov = [Math]::Min(1.0, ($dRim + 1) / [double]$FR)
            if (-not (Test-Cover $cov $x $y)) { continue }
            # Anchored to the TOP OF THE VIEWPORT, not to the curve. The light is
            # coming off the outside of the helmet, so the catch has to sit on the
            # screen edge; riding the curve put it partway down the shell, which
            # read as trim rather than a glint. Its DEPTH still scales with the
            # column, so it stays thin across the middle and wide at the corners.
            [double]$g = $(if ($y -lt $gd) { 1.0 - ($y / [double]$gd) } else { 0.0 })
            $px[$y*$ViewW + $x] = Get-Ink $g $x $y
        }
        # the haze, carrying on BELOW the curve and out into the view. Squared so
        # it leaves quickly near the curve and trails off slowly -- a linear fade
        # reads as a band with an edge, which is the thing being avoided.
        for ($k = 1; $k -le $VD; $k++) {
            [int]$y = $edge + $k
            if ($y -ge $ViewH) { break }
            [double]$v = 1.0 - ($k / [double]$VD)
            $v = $v * $v * $VigStart
            if ($v -le $COVER[(($y % 8) * 8) + ($x % 8)]) { continue }
            $px[$y*$ViewW + $x] = [byte]$INK
        }
    }
    # bottom corners: the rim is the FIRST inked row
    [int]$bedge = -1
    for ($y = $topRows; $y -lt $ViewH; $y++) { if ($inked[$y*$ViewW + $x]) { $bedge = $y; break } }
    # The shell itself, dissolving at its rim exactly as the top one does. Flat
    # black, like the top: GlintAlpha is 0 in the shipped settings, so the bronze is
    # off at both edges and the haze below is what carries the depth.
    #
    # A mirrored catch-light was built here and backed out -- see $GlintAlpha. It
    # worked; it just was not the look. If it is ever wanted again it needs its own
    # anchor to the BOTTOM edge, because the top's rides distance from row 0 and
    # reusing that directly lights the top rim only.
    if ($bedge -ge 0) {
        for ($y = $bedge; $y -lt $ViewH; $y++) {
            if (-not $inked[$y*$ViewW + $x]) { continue }
            [double]$cov = [Math]::Min(1.0, (($y - $bedge) + 1) / [double]$FR)
            if (-not (Test-Cover $cov $x $y)) { continue }
            $px[$y*$ViewW + $x] = [byte]$INK
        }
        # ...and the haze, carrying on ABOVE the curve and out into the view -- the
        # mirror of the top's. An earlier note here said the bottom had "no view
        # beyond it to haze into", which confused WHERE the panel is with WHICH WAY
        # the haze goes: it does not spill onto the panel, it reaches up into the
        # 3D, and without it the faceplate had a soft top edge and a hard bottom one.
        #
        # Squared like the top's, so it leaves the curve quickly and trails off
        # slowly; a linear fade reads as a band with an edge.
        if (-not $NoMirrorBottom) {
            for ($k = 1; $k -le $VD; $k++) {
                [int]$y = $bedge - $k
                if ($y -lt $topRows) { break }        # do not reach into the top sweep
                [double]$v = 1.0 - ($k / [double]$VD)
                $v = $v * $v * $VigStart
                if ($v -le $COVER[(($y % 8) * 8) + ($x % 8)]) { continue }
                $px[$y*$ViewW + $x] = [byte]$INK
            }
        }
    }
}
if ($NoBottom) { foreach ($o in @($px.Keys)) { if ($o -ge [int]($ViewH / 2) * $ViewW) { $px.Remove($o) } } }
if ($px.Count -eq 0) { throw "visor mask is empty" }

# --- encode ------------------------------------------------------------------
# Runs of consecutive offsets with a skip word between them. Runs MERGE across
# row boundaries, which is correct and is what the stock file does too -- its
# first record is a 689-byte run covering all of row 0 and part of row 1.
$offsets = @($px.Keys | Sort-Object)
$destOff = 0
if ($offsets[0] -ne 0) { throw "HUDTOP has no dest-offset field, so the mask must start at offset 0 (it starts at $($offsets[0]))" }
$out = New-Object System.Collections.Generic.List[byte]
$words = 0
function Add-Word { param([int]$v)
    if ($v -lt 0 -or $v -gt 65535) { throw "value $v does not fit the 16-bit run/skip field" }
    $script:out.Add([byte]($v -band 0xFF)); $script:out.Add([byte](($v -shr 8) -band 0xFF)); $script:words++ }

# THE SKIP FIELD IS 16 BITS and the gap from the sweep to the bottom corners is
# the whole height of the view, so a long gap is a CHAIN: skip 65535, run 0,
# skip 65535, run 0, ... skip remainder. Getting this wrong walks the applier off
# the end of the framebuffer.
function Add-Gap {
    param([int]$g)
    while ($g -gt 65535) { Add-Word 65535; Add-Word 0; $g -= 65535 }
    Add-Word $g
}

$cur = $destOff; $i = 0
while ($i -lt $offsets.Count) {
    $start = $offsets[$i]; $j = $i
    while ($j + 1 -lt $offsets.Count -and $offsets[$j+1] -eq $offsets[$j] + 1) { $j++ }
    $len = $offsets[$j] - $start + 1
    $gap = $start - $cur
    if ($words -eq 0 -and $gap -ne 0) { Add-Word 0 }    # a leading zero-length run
    if ($words -gt 0 -or $gap -ne 0)  { Add-Gap $gap }
    Add-Word $len
    for ($k = $start; $k -le $offsets[$j]; $k++) { $out.Add([byte]$px[$k]) }
    $cur = $start + $len; $i = $j + 1
}

$lastByte = $cur - 1
if ($lastByte -ge $ViewW * $ViewH) { throw "overlay would write past the framebuffer ($lastByte >= $($ViewW*$ViewH))" }
$out.AddRange([byte[]][BitConverter]::GetBytes([int]$words))   # 4-byte trailer ONLY
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'HUDTOP.RES'), $out.ToArray())

# --- verify ------------------------------------------------------------------
# POSITIONS, not just a pixel count. The old check counted how many bytes decoded
# and whether they were in bounds, which both hold for a stream that puts every
# pixel in the wrong place -- so it could not have caught a drift, and an hour
# went into chasing a bug it would have ruled out in a second.
$chk = $out.ToArray()
$cwc = [BitConverter]::ToInt32($chk, $chk.Length - 4)
$got = @{}
$p = 0; $w = 0; $c = 0
while ($w -lt $cwc -and $p -lt ($chk.Length - 4)) {
    $run = [BitConverter]::ToUInt16($chk, $p); $p += 2; $w++
    for ($k = 0; $k -lt $run; $k++) { $got[$c + $k] = $chk[$p + $k] }
    $p += $run; $c += $run
    if ($w -lt $cwc) { $skip = [BitConverter]::ToUInt16($chk, $p); $p += 2; $w++; $c += $skip }
}
if ($cwc -ne $words)          { throw "trailer word count $cwc does not match $words" }
if ($p -ne ($chk.Length - 4)) { throw "round trip consumed $p bytes of $($chk.Length - 4)" }
if ($got.Count -ne $px.Count) { throw "round trip decoded $($got.Count) px, expected $($px.Count)" }
foreach ($o in $offsets) {
    if (-not $got.ContainsKey($o))  { throw ("offset {0} (row {1}, col {2}) is missing from the stream" -f $o, [int]($o/$ViewW), ($o % $ViewW)) }
    if ($got[$o] -ne $px[$o])       { throw ("offset {0} decoded as ink {1}, expected {2}" -f $o, $got[$o], $px[$o]) }
}
foreach ($o in $got.Keys) {
    if ($o -lt 0 -or $o -ge $ViewW*$ViewH) { throw "offset $o lands outside the ${ViewW}x${ViewH} view" }
    if (-not $px.ContainsKey($o))          { throw ("offset {0} (row {1}) is in the stream but not the mask" -f $o, [int]($o/$ViewW)) }
}

Write-Host ("HUDTOP.RES  visor: sweep {0} rows (Mindscape x{1:N2}), glass {2} px, haze {3} px @{4:P0}, {5}, min {6} px, bottom r={7}: {8:N0} px, {9:N0} words, {10:N0} bytes (positions verified)" -f `
    $topRows, $YS, $FR, $VD, $VigStart,
    $(if ($GlintAlpha -gt 0) { "glint {0:P0} deep @{1:P0}" -f $GlintFrac, $GlintAlpha } else { 'no glint (black only)' }),
    $minRows, $R, $px.Count, $words, $out.Count)
