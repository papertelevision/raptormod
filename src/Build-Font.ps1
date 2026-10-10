# Build-Font.ps1 -- generate replacement font sheets for Azrael's Tear.
#
# THE FORMAT, as read out of StLoadFont (0x38AB8) rather than guessed:
#
#   * a font is ONE PCX: a single horizontal strip of glyphs
#   * 0x38C05 / 0x38C12 hard-code the character range: first = 0x21 ('!'),
#     count = 0x8B = 139, so the strip covers 0x21..0xAB. SPACE is not in the
#     sheet; the renderer gives it a fixed advance.
#   * glyphs are VARIABLE width, delimited by fully-blank columns. The loader
#     walks the strip (0x38C42..0x38D16) testing each column against every row
#     and records 139 runs into a 4-byte-per-glyph table at font+6.
#   * line height = the PCX height; the renderer reads it off the font surface
#     at 0x39255, so a taller sheet re-spaces the text with no code change.
#   * palette index 0 is the transparency key. All other indices are looked up
#     in the CURRENT palette (PALETTE.PCX), NOT in the font PCX's own palette --
#     which is why the 18x14 RUS* sheets are unusable: RUSBLU2's only ink is
#     index 53 = #080000.
#
#   Verified: RUSGLD2, GENBLU2 and INVFONT all scan to exactly 139 runs.
#
# The consequence that makes this worth doing: a better font is a pure art swap.
# Keep 139 glyphs and the game re-measures every advance itself, so nothing that
# uses these fonts can go out of layout.
#
# The one hard rule: NO GLYPH MAY CONTAIN AN INTERIOR FULLY-BLANK COLUMN, or it
# splits into two runs and every later character shifts by one. Anything with a
# gap (notably '"') gets a single shadow-coloured pixel dropped into the bottom
# row to bridge it -- black, below the baseline, invisible in play.
param(
    [string]$GameDir = "C:\Games\AzraelsTear-Modded\GAME\AZRAEL",
    [string]$OutDir  = "$PSScriptRoot\..\art",
    [string]$Face    = 'Verdana',   # a screen face: open apertures, large x-height
    [double]$EmSize  = 10,
    [int]   $Height  = 12,          # stock is 12; the renderer uses this as line height
    [int]   $Pad     = 1,           # blank columns between glyphs
    # Antialiasing depth. The glyphs are rasterised with AntiAlias already, but the
    # coverage is quantised to this many ink levels before being snapped to the
    # game palette -- so this is literally how smooth the edges can be. 4 was
    # enough at 640x480; a bigger sheet shows the steps.
    [int]   $Levels  = 4,
    # The story log's own size, if it should differ from the rest of the HUD.
    # 0 = use $EmSize / $Height / $Levels. See the job list at the bottom.
    [double]$LogEm   = 0,
    [int]   $LogHeight = 0,
    [int]   $LogLevels = 0,
    # Render the log sheet hinted and aliased instead of anti-aliased. At small
    # sizes the anti-aliased fringe is most of the glyph and this palette snaps it
    # to grey; see New-FontSheet.
    [bool]  $LogCrisp  = $false,
    # KEEP MINDSCAPE'S OWN LOG SHEETS. The stock RUSGLD2/GENBLU2 are 1380x12
    # two-colour bitmap faces with solid 3px strokes, and nothing rasterised from
    # a TrueType outline at this size matches them for crispness -- see the job
    # list below. When set, neither sheet is written at all, so the installer's
    # "no longer shipped" sweep puts the originals back.
    [bool]  $LogStock  = $false,
    # THE INVENTORY'S SHEET (INVFONT), 0 = keep the stock 12-row one. Josh, 2026-10-07: it was "microscopic"
    # next to the log, so it is made the log's size, in dark sepia ink on the panel's green screen.
    [double]$InvEm     = 0,
    [int]   $InvHeight = 0,
    [int]   $InvLevels = 4
)

Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies "System.Drawing"
Add-Type -AssemblyName System.Drawing

$FIRST = 0x21
$COUNT = 139

$gamePal = [LeTool.Pcx]::Load((Join-Path $GameDir 'PALETTE.PCX')).Palette
$SHADOW  = 54      # #000000, what the stock sheets use behind the ink

# High bytes are DOS code page 437 -- the stock strips carry the accented set.
$cp437 = [System.Text.Encoding]::GetEncoding(437)
$chars = @()
for ($i = 0; $i -lt $COUNT; $i++) {
    $chars += $cp437.GetString([byte[]]@([byte]($FIRST + $i)))
}

# --- ink ramps, snapped to the game palette -------------------------------
# Only the low region is safe: 200+ reads as black in PALETTE.PCX (the scene
# palettes drive it), which is why FONT.PCX's own inks cannot be reused either.
function Nearest-Index {
    param([int]$r, [int]$g, [int]$b, [int]$Hi = 199)
    $best = -1; $bestD = [int]::MaxValue
    foreach ($i in 1..$Hi) {
        $dr = $gamePal[$i*3] - $r; $dg = $gamePal[$i*3+1] - $g; $db = $gamePal[$i*3+2] - $b
        $d = $dr*$dr + $dg*$dg + $db*$db
        if ($d -lt $bestD) { $bestD = $d; $best = $i }
    }
    $best
}
function Build-Ramp {
    param([int]$r, [int]$g, [int]$b, [int]$levels, [int]$Hi = 199)
    $ramp = @()
    for ($i = 1; $i -le $levels; $i++) {
        $f = $i / $levels
        $ramp += (Nearest-Index ([int]($r*$f)) ([int]($g*$f)) ([int]($b*$f)) -Hi $Hi)
    }
    # The faintest level is pinned to the shadow colour rather than whatever the
    # palette happens to hold near 25% of the ink. There is no dark cyan in this
    # palette, so the nearest match for the blue font was index 23 = #384838 -- a
    # muddy teal-green, sprayed around every glyph edge. Folding the faintest
    # coverage into the shadow instead reads as an outline, and it can only ever
    # use an index the stock sheets already prove is safe in the live palette.
    $ramp[0] = $SHADOW
    $ramp
}

function New-FontSheet {
    param([int[]]$Ramp, [double]$Em = 0, [int]$Rows = 0, [bool]$Crisp = $false)
    if ($Em   -le 0) { $Em   = $EmSize }
    if ($Rows -le 0) { $Rows = $Height }
    $EmSize = $Em; $Height = $Rows

    # 1. rasterise every glyph into its own tight coverage mask
    $CANVAS = 32
    $bmp  = New-Object System.Drawing.Bitmap $CANVAS, $Height
    $gr   = [System.Drawing.Graphics]::FromImage($bmp)
    # ANTI-ALIASING IS WHAT MAKES A SMALL SHEET LOOK DIRTY. Every partial-coverage
    # pixel is snapped to the nearest palette entry, and this palette has no dark
    # cyan -- the mid levels come out #747474/#989898 grey. At 15 rows the solid
    # core of a stroke outvoted them; at 11 the fringe IS most of the glyph, so the
    # text reads as grey mush rather than smaller text. Hinted 1bpp gives back a
    # clean two-colour glyph, which is what a 1996 bitmap font looked like anyway.
    $gr.TextRenderingHint = if ($Crisp) {
        [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
    } else {
        [System.Drawing.Text.TextRenderingHint]::AntiAlias
    }
    $font = New-Object System.Drawing.Font($Face, $EmSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt  = [System.Drawing.StringFormat]::GenericTypographic
    $glyphs = @()

    foreach ($ch in $chars) {
        $gr.Clear([System.Drawing.Color]::Black)
        $gr.DrawString($ch, $font, [System.Drawing.Brushes]::White, 1, 0, $fmt)
        $cov = New-Object 'int[,]' $CANVAS, $Height
        $minX = $CANVAS; $maxX = -1
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $CANVAS; $x++) {
                $v = $bmp.GetPixel($x, $y).G
                $cov[$x, $y] = $v
                if ($v -ge 24) { if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x } }
            }
        }
        if ($maxX -lt 0) { $minX = 0; $maxX = 2 }          # blank glyph -> reserve a stub
        $glyphs += @{ cov = $cov; x0 = $minX; w = ($maxX - $minX + 1) }
    }
    $gr.Dispose(); $bmp.Dispose(); $font.Dispose()

    # 2. lay them out, +1 for the shadow, with $Pad blank columns between
    $W = 0
    foreach ($g in $glyphs) { $W += $g.w + 1 + $Pad }
    $sheet = New-Object LeTool.Pcx
    $sheet.Width = $W; $sheet.Height = $Height
    $sheet.BitsPerPixel = 8; $sheet.Planes = 1; $sheet.BytesPerLine = $W
    $sheet.Pixels = New-Object byte[] ($W * $Height)
    $sheet.Palette = $gamePal.Clone()

    $pen = 0
    foreach ($g in $glyphs) {
        $gw = $g.w + 1                                     # room for the +1,+1 shadow
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $g.w; $x++) {
                if ($g.cov[($g.x0 + $x), $y] -lt 40) { continue }
                $sx = $pen + $x + 1; $sy = $y + 1
                if ($sx -lt $W -and $sy -lt $Height) { $sheet.Pixels[$sy * $W + $sx] = [byte]$SHADOW }
            }
        }
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $g.w; $x++) {
                $v = $g.cov[($g.x0 + $x), $y]
                if ($v -lt 24) { continue }
                $lvl = [int][Math]::Round(($v / 255.0) * $Ramp.Count)
                if ($lvl -lt 1) { $lvl = 1 } elseif ($lvl -gt $Ramp.Count) { $lvl = $Ramp.Count }
                $sheet.Pixels[$y * $W + $pen + $x] = [byte]$Ramp[$lvl - 1]
            }
        }
        # Bridge INTERIOR blank columns only, or the loader splits this glyph in two.
        #
        # "Interior" matters: a leading or trailing blank column splits nothing, and
        # marking it just leaves a dot floating beside the letter. An earlier version
        # walked every column and dropped the mark on the bottom row -- 22 detached
        # specks sitting on the baseline (the stock sheets have none), which is
        # exactly what showed up in game as dots behind the text.
        #
        # The mark also goes on the same row as the lowest ink in the column to its
        # left, so it attaches to a stroke instead of floating.
        $colLow = New-Object 'int[]' $gw
        for ($x = 0; $x -lt $gw; $x++) {
            $colLow[$x] = -1
            for ($y = $Height - 1; $y -ge 0; $y--) {
                if ($sheet.Pixels[$y * $W + $pen + $x] -ne 0) { $colLow[$x] = $y; break }
            }
        }
        $first = -1; $last = -1
        for ($x = 0; $x -lt $gw; $x++) { if ($colLow[$x] -ge 0) { if ($first -lt 0) { $first = $x }; $last = $x } }
        if ($first -ge 0) {
            for ($x = $first + 1; $x -lt $last; $x++) {
                if ($colLow[$x] -ge 0) { continue }
                $row = $colLow[$x - 1]
                if ($row -lt 0) { $row = $Height - 1 }
                $sheet.Pixels[$row * $W + $pen + $x] = [byte]$SHADOW
                $colLow[$x] = $row
            }
        } else {
            # a glyph this face has nothing for: it still needs to occupy one run
            $sheet.Pixels[($Height - 1) * $W + $pen] = [byte]$SHADOW
        }
        $pen += $gw + $Pad
    }
    $sheet
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# The two fonts the story box uses, by their stock ink colours:
#   rusgld2.pcx -> gold #F8B018 (index 56)   genblu2.pcx -> cyan #BCF8FC (index 55)
#
# BOTH OF THESE ARE STORY LOG FONTS, and rusgld2 is the one you mostly read.
# Of HudPrint's 43 call sites 24 pass [0x152178] (rusgld2) and 15 pass [0x15217C]
# (genblu2) -- the log switches between them, gold for narration and cyan for the
# conversation line under the cursor. Shrinking only genblu2 changed a minority of
# the text and looked like nothing had happened at all.
#
# $EmSize/$Height were scaled up with the screen so HUD captions kept their
# relative size, which is right for a caption and too big for a 170px-wide box of
# prose. The Log* overrides bring both sheets down together; 0 means "default".
#
# THE RAMP MAY ONLY USE INDICES 1..56, AND THAT IS NOT THE SAME AS 1..199.
# The live palette is merged from hud3 + pal + h1, and only 1..53 belong to the
# HUD; 54/55/56 are safe too because the STOCK sheets use exactly those (54 ink
# shadow, 56 gold, 55 cyan) and survive every scene. Everything above is scene
# colour and changes from room to room.
#
# Searching all 199 gave the prettiest gold on paper -- 35, 119, 114, 65, 104, 56,
# a clean #302000 -> #F8B018 ramp -- but four of those six live in scene
# territory, so a third of every glyph's ink was drawn in whatever colour the
# current room happened to hold there. In the log box, whose recess is a flat
# index 2, that reads as dots peppered through the text and lining up into
# columns beside the stems.
#
# Restricted, gold becomes 35, 26, 22, 14, 56, 56 (a browner ramp, which suits
# the panel) and cyan 29, 19, 9, 3, 55, 55. Duller mid-tones, but stable.
#
# Do NOT "fix" this by dropping to two levels instead. That pins every
# partial-coverage pixel to the shadow, and at this size Verdana's stems are
# mostly partial coverage -- the glyphs go black and the text stops being
# readable. Stock gets away with two colours because its strokes are solid 3px
# bitmap, not an anti-aliased outline.
$LOG_SAFE_MAX = 56
# INVFONT: dark ink on a LIGHT screen, so the ramp runs the other way -- faint coverage is a blend of the
# screen's green and the ink, full coverage the ink itself; every step snapped inside the safe 1..56.
if ($InvEm -gt 0 -and $InvHeight -gt 0) {
    $bgC = @(150, 160, 128); $inkC = @(34, 24, 12)
    $iramp = @(); for ($i = 1; $i -le $InvLevels; $i++) { $f = 0.35 + 0.65 * $i / $InvLevels
        $iramp += (Nearest-Index ([int]($bgC[0] + ($inkC[0] - $bgC[0]) * $f)) ([int]($bgC[1] + ($inkC[1] - $bgC[1]) * $f)) ([int]($bgC[2] + ($inkC[2] - $bgC[2]) * $f)) -Hi $LOG_SAFE_MAX) }
    $isheet = New-FontSheet -Ramp $iramp -Em $InvEm -Rows $InvHeight
    $isheet.SavePcx((Join-Path $OutDir 'INVFONT.PCX'))
    Write-Host ("INVFONT   {0,4}x{1,-3} ramp {2} -> {3}" -f $isheet.Width, $isheet.Height, ($iramp -join ','),
        (($iramp | ForEach-Object { '#{0:X2}{1:X2}{2:X2}' -f $gamePal[$_*3], $gamePal[$_*3+1], $gamePal[$_*3+2] }) -join ' '))
}
if ($LogStock) {
    Write-Host "RUSGLD2 / GENBLU2: keeping the stock sheets (1380x12, two-colour) -- not generated"
    return
}
foreach ($job in @(
    @{ name = 'RUSGLD2'; r = 0xF8; g = 0xB0; b = 0x18; em = $LogEm; rows = $LogHeight
       levels = $LogLevels; crisp = $LogCrisp },
    @{ name = 'GENBLU2'; r = 0xBC; g = 0xF8; b = 0xFC; em = $LogEm; rows = $LogHeight
       levels = $LogLevels; crisp = $LogCrisp })) {
    $lv = $(if ($job.levels -gt 0) { $job.levels } else { $Levels })
    $ramp = Build-Ramp $job.r $job.g $job.b $lv -Hi $LOG_SAFE_MAX
    $sheet = New-FontSheet -Ramp $ramp -Em $job.em -Rows $job.rows -Crisp $job.crisp
    $out = Join-Path $OutDir "$($job.name).PCX"
    $sheet.SavePcx($out)
    Write-Host ("{0,-9} {1,4}x{2,-3} ramp {3} -> {4}" -f $job.name, $sheet.Width, $sheet.Height,
        ($ramp -join ','), (($ramp | ForEach-Object { '#{0:X2}{1:X2}{2:X2}' -f $gamePal[$_*3], $gamePal[$_*3+1], $gamePal[$_*3+2] }) -join ' '))
}
