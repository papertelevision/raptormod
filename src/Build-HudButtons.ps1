# Build-HudButtons.ps1 -- slice the contextual lamps and the two arrow keys.
#
# Run AFTER Build-HudSkin.ps1: it reads the palette and the region layout that
# script produced, and it edits HUD3.PCX / HUDOFF.PCX in place.
#
# WHAT THE STOCK SPRITES ACTUALLY ARE. NBUT0/1/2 are not labelled buttons -- the
# stock art is three blank oval housing lamps that swap between an unlit and a
# lit copy. (They also carry no embedded palette at all: they index straight into
# the game palette, so rendering one needs HUD3.PCX's.) The TAKE / USE / PUSH art
# is therefore a change in kind, not just in style: the panel will now always show
# three labelled lamps that light contextually rather than three blank ones.
#
# The two CTRL regions are NOT sprites. The game paints them as part of the panel
# artwork and only draws a highlight over the region on hover, so the arrows are
# composited straight into HUD3/HUDOFF and there is no lit state for them.
#
# NO HELPER FUNCTIONS THAT RETURN COLLECTIONS. PowerShell's return semantics cost
# three debugging rounds here: `return $hashtable` came back as Object[], and
# `return ,$array` survived only until the caller's @() re-wrapped it, so six
# sprites reported as one. Everything below is linear, and every loop that would
# be slow or type-fragile lives in tools\Quantize.cs instead.
[CmdletBinding()]
param(
    # SCAN / MAP / INV. These are the three NBUT slots, and they are MODE
    # TOGGLES, not contextual verbs -- TAKE/USE/PUSH was my own wrong guess at
    # what those slots do. NBUT0 sits level with the top arrow, NBUT1 with the
    # bottom one, NBUT2 further right by the gauge.
    [string]$ModesPng  = "$PSScriptRoot\..\design\incoming\modes.png",
    [string]$ArrowsPng = "$PSScriptRoot\..\design\incoming\arrows-on-white.png",
    [string]$ArtDir    = "$PSScriptRoot\..\art"
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs"
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies "System.Drawing"
Add-Type -AssemblyName PresentationCore

$layout = Get-Content (Join-Path $ArtDir 'hud-layout.json') -Raw | ConvertFrom-Json
$hud3   = [LeTool.Pcx]::Load((Join-Path $ArtDir 'HUD3.PCX'))
$hudoff = [LeTool.Pcx]::Load((Join-Path $ArtDir 'HUDOFF.PCX'))
$pal    = $hud3.Palette
$PAL_LO = 1; $PAL_HI = 53
$NCOL   = $PAL_HI - $PAL_LO + 1
$subPal = New-Object 'byte[]' ($NCOL*3)
for ($i=0; $i -lt $NCOL; $i++) { for ($k=0; $k -lt 3; $k++) { $subPal[$i*3+$k] = $pal[($PAL_LO+$i)*3+$k] } }

# ---- classify the regions exactly as Build-AztMod does ---------------------
$rg = @($layout.regions)
$SW = [int]$layout.screenW
$scanR  = $rg | Where-Object { $_.x -gt ($SW/2) } | Sort-Object { -($_.w*$_.h) } | Select-Object -First 1
$mapR   = $rg | Where-Object { $_.x -lt ($SW/2) } | Sort-Object { -($_.w*$_.h) } | Select-Object -First 1
# BY ASPECT, NOT BY ABSOLUTE SIZE -- these must stay identical to Build-AztMod's
# copy of this classifier, and `h -le 14` / `w -lt 20` were the regions' pixel
# sizes at one resolution, not their shapes. See the note there.
$gaugeR = $rg | Where-Object { ($_.w / $_.h) -ge 4.0 } | Select-Object -First 1
$ctrl   = @($rg | Where-Object { ($_.h / $_.w) -ge 1.5 } | Sort-Object y)
$acts   = @($rg | Where-Object { $_ -ne $scanR -and $_ -ne $mapR -and $_ -ne $gaugeR -and $ctrl -notcontains $_ } | Sort-Object y)
if ($ctrl.Count -ne 2 -or $acts.Count -ne 3) { throw "region classification failed: $($ctrl.Count) controls, $($acts.Count) actions" }

# `axis` says how the sheet is laid out, because the two renders disagree:
#   'cols'  buttons run ACROSS, the two states run DOWN  (modes.png: SCAN MAP INV
#           on the top row unlit, the same three lit underneath)
#   'rows'  buttons run DOWN, the two states run ACROSS  (arrows.png)
# Guessing wrong silently pairs a button's unlit face with a different button's
# lit one, so it is declared rather than inferred.
foreach ($job in @(
    @{ n='modes';  path=$ModesPng;  count=3; axis='cols' },
    @{ n='arrows'; path=$ArrowsPng; count=2; axis='rows' })) {

    Write-Host ("{0}:" -f $job.n)
    $fsx  = [System.IO.File]::OpenRead($job.path)
    $frx  = [System.Windows.Media.Imaging.BitmapDecoder]::Create($fsx,'None','OnLoad').Frames[0]
    $iw   = [int]$frx.PixelWidth
    $ih   = [int]$frx.PixelHeight
    $istr = $iw * 4
    $buf  = New-Object 'byte[]' ($istr*$ih)
    (New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($frx,[System.Windows.Media.PixelFormats]::Bgra32,$null,0)).CopyPixels($buf,$istr,0)
    $fsx.Close()

    # Usable alpha? If not, knock the background out by flooding inward from the
    # border. The render's background is NOT flat white -- it carries a vignette
    # from 203 to 255 -- so the flood tests NEUTRALITY (channels within 14 of one
    # another) as well as brightness, which is what keeps it out of the brass.
    $op = 0
    for ($k=0; $k -lt $iw*$ih; $k+=7) { if ($buf[$k*4+3] -ge 250) { $op++ } }
    if ($op -ge ([int]($iw*$ih/7) - 2)) {
        $cut = [LeTool.Quant]::MatteBorder($buf,$iw,$ih,186,14)
        Write-Host ("   no alpha: matted {0:N0} background px by border flood fill" -f $cut)
    }

    $flat = [LeTool.Quant]::Blobs($buf,$iw,$ih,20000)
    $n = $flat.Length / 5
    Write-Host ("   {0} sprites" -f $n)
    if ($n -ne $job.count*2) { throw "$($job.n): expected $($job.count*2) sprites, found $n" }

    $sp = @()
    for ($k=0; $k -lt $flat.Length; $k+=5) {
        $sp += [pscustomobject]@{ x=$flat[$k]; y=$flat[$k+1]; w=$flat[$k+2]; h=$flat[$k+3] }
    }
    # Order the buttons along their own axis, then the two states along the other.
    $sorted = $(if ($job.axis -eq 'cols') { @($sp | Sort-Object x) } else { @($sp | Sort-Object y) })

    for ($r=0; $r -lt $job.count; $r++) {
        $two = @($sorted[$r*2], $sorted[$r*2+1])
        # unlit first: it is the TOP copy on a 'cols' sheet, the LEFT one on 'rows'
        $pair   = $(if ($job.axis -eq 'cols') { @($two | Sort-Object y) } else { @($two | Sort-Object x) })
        $target = $(if ($job.n -eq 'modes') { $acts[$r] } else { $ctrl[$r] })

        $made = @()
        foreach ($st in @($pair[0], $pair[1])) {
            $d = New-Object 'byte[]' ($target.w*$target.h*4)
            [LeTool.Quant]::Resample($buf,$iw,$ih,$istr,$st.x,$st.y,($st.x+$st.w),($st.y+$st.h),$d,$target.w,$target.h)
            $made += ,([LeTool.Quant]::Map($d,$target.w,$target.h,$subPal,$NCOL,$PAL_LO,0))
        }

        if ($job.n -eq 'modes') {
            # BAKE THE UNLIT FACE INTO THE PANEL TOO. The engine only blits an
            # NBUT sprite when that action is available, so an empty socket was
            # showing the bare recess -- three black ovals most of the time.
            # With the OFF face painted into HUD3/HUDOFF the socket always reads
            # as a button, and the engine's ON sprite simply lights it.
            $by = [int]$target.y + [int]$layout.panelTop
            foreach ($dest in @($hud3, $hudoff)) {
                for ($y=0; $y -lt $target.h; $y++) { for ($x=0; $x -lt $target.w; $x++) {
                    $v = $made[0][$y*$target.w+$x]
                    if ($v -ne 0) { $dest.Pixels[($by+$y)*$dest.BytesPerLine + $target.x + $x] = $v }
                } }
            }
            foreach ($v in @(@{s=0; f='OFF'}, @{s=1; f='ON'})) {
                $sheet = New-Object LeTool.Pcx
                $sheet.Width=$target.w; $sheet.Height=$target.h; $sheet.BitsPerPixel=8
                $sheet.Planes=1; $sheet.BytesPerLine=$target.w
                $sheet.Pixels = $made[$v.s]; $sheet.Palette = $pal.Clone()
                $sheet.SavePcx((Join-Path $ArtDir ("NBUT{0}{1}.PCX" -f $r, $v.f)))
            }
            Write-Host ("   NBUT{0}: {1}x{2} -> {3}x{4} at panel ({5},{6})" -f `
                $r,$pair[0].w,$pair[0].h,$target.w,$target.h,$target.x,$target.y)
        } else {
            # hud-layout.json stores y PANEL-LOCAL (0 = the panel's top row) but
            # x absolute, so only y needs the offset. Getting this wrong painted
            # both arrows at screen row 13 -- up in the black backdrop above the
            # viewport, nowhere near the panel.
            $ay = [int]$target.y + [int]$layout.panelTop
            # THE LIT STATE, deliberately. These two are always-visible toggles
            # (scan mode and the map), not contextual lamps, and the unlit render
            # is almost entirely #1C1D11 -- at 15x29 on screen it reads as a black
            # square, which is exactly what it looked like in game. The game still
            # draws its own hover highlight over the region on mouseover.
            foreach ($dest in @($hud3, $hudoff)) {
                for ($y=0; $y -lt $target.h; $y++) { for ($x=0; $x -lt $target.w; $x++) {
                    $v = $made[1][$y*$target.w+$x]
                    if ($v -ne 0) { $dest.Pixels[($ay+$y)*$dest.BytesPerLine + $target.x + $x] = $v }
                } }
            }
            Write-Host ("   arrow{0}: {1}x{2} -> {3}x{4} at screen ({5},{6})" -f `
                $r,$pair[0].w,$pair[0].h,$target.w,$target.h,$target.x,$ay)
        }
    }
}

# ---- give the two big displays a screen colour ----------------------------
# The automap window is where the INVENTORY SCREEN draws, and INVBACK2.PCX is a
# sage panel (#949C84 / #9CA58D, 51% of it between them). Left as a near-black
# recess the window reads as a hole punched in the housing whenever the map or
# inventory is not up, so it gets the screen's own colour instead. The scan
# readout gets a darker tint -- it is a text display, and sage behind text the
# game draws in an unknown ink is a gamble.
function Nearest-New { param([int]$r,[int]$g,[int]$b)
    $best = 1; $bd = [double]::MaxValue
    for ($k=1; $k -le 53; $k++) {
        $dr=$pal[$k*3]-$r; $dg=$pal[$k*3+1]-$g; $db=$pal[$k*3+2]-$b
        $d = $dr*$dr*0.299 + $dg*$dg*0.587 + $db*$db*0.114
        if ($d -lt $bd) { $bd=$d; $best=$k }
    }
    return $best
}
$screenIdx = Nearest-New 0x94 0x9C 0x84          # INVBACK2's dominant sage
$scanIdx   = Nearest-New 0x28 0x2A 0x22          # an unlit readout, not a void
foreach ($fill in @(@{ r=$mapR;  i=$screenIdx; n='inventory / map window' },
                    @{ r=$scanR; i=$scanIdx;   n='scan readout' })) {
    $fy = [int]$fill.r.y + [int]$layout.panelTop
    foreach ($dest in @($hud3, $hudoff)) {
        for ($y=0; $y -lt $fill.r.h; $y++) { for ($x=0; $x -lt $fill.r.w; $x++) {
            $dest.Pixels[($fy+$y)*$dest.BytesPerLine + $fill.r.x + $x] = [byte]$fill.i
        } }
    }
    Write-Host ("   {0}: filled {1}x{2} at ({3},{4}) with index {5} (#{6:X2}{7:X2}{8:X2})" -f `
        $fill.n,$fill.r.w,$fill.r.h,$fill.r.x,$fy,$fill.i,$pal[$fill.i*3],$pal[$fill.i*3+1],$pal[$fill.i*3+2])
}

# ---- BLACK OUT THE GAUGE WELL ----------------------------------------------
#
# The health bar is drawn into this recess, and the recess artwork has a LIP one
# shade lighter than its floor (index 2 #2B2918 against index 1 #12130B) running
# round the inside. Below the bar that lip showed as a thin bright line across the
# bottom of the well -- the bar is 14 rows and the well is about 20, so it cannot
# cover it.
#
# Filling the gauge RECTANGLE is not enough: the well is wider than the measured
# registration block (at 1024x768, x 490..652 against a region of 500..629), so a
# rectangle leaves the lip showing at both ends. So flood the actual recess from
# the region's centre.
#
# Only inks 1 and 2 are traversed, so the bronze rim is a wall the fill cannot
# cross, and the whole thing is bounded to the region plus a margin -- index 1 is
# the shared recess floor and an unbounded fill would run into the other wells.
$gy = [int]$gaugeR.y + [int]$layout.panelTop
$PAD = 24
$bx0 = [Math]::Max(0, [int]$gaugeR.x - $PAD)
$bx1 = [Math]::Min($hud3.Width - 1, [int]$gaugeR.x + [int]$gaugeR.w - 1 + $PAD)
$by0 = [Math]::Max(0, $gy - $PAD)
$by1 = [Math]::Min($hud3.Height - 1, $gy + [int]$gaugeR.h - 1 + $PAD)
$FLOOR = 1
# DEEPEN THE WELL. The bar does not reach the bottom of the recess, and the bezel's
# top edge reads as a bright line across the gap underneath it. Flooding the recess
# could not fix that, because those rows are the bezel and not the floor -- the
# hollow itself has to grow downward into them.
#
# Done PER COLUMN, from each column's own lowest floor pixel, so the recess keeps
# its rounded bottom corners. Squaring it off with one rectangle would put hard
# corners on an otherwise radiused well.
$GAUGE_DEEPEN = 0
# The black plate behind the health bar: the gauge rect grown by this much on every
# side, corners rounded by this radius, forced to the recess floor ink regardless of
# what was there. Belt and braces over the flood above, which can only repaint the
# two recess inks and stops at anything else.
# OFF. The mask never covered the line, because the line is drawn at runtime over
# the panel rather than being part of it -- the plate just sat behind it while
# flattening the recess bevel. Kept only so the geometry is not re-derived if a
# genuine artwork blemish ever needs covering here.
$GAUGE_MASK     = $false
$GAUGE_MASK_PAD = 3
$GAUGE_MASK_R   = 3
# The BOTTOM pad separately, because the bright band is not symmetric. Measured in
# HUD3 at 1024x768: inside the mask, rows 658..678 are pure floor (lum 18) and the
# bezel runs 679..685, peaking at lum 171-184 on 680-681, with 686 back to floor.
# So a 3px pad stops exactly one row short of it; 10 covers the band completely.
# Note a PARTIAL cover looks worse than none -- blacking only 680-681 once left
# 682-685 standing alone against fresh black and read as a thicker line, not a
# thinner one.
$GAUGE_MASK_PAD_B = 10
# ...and the TOP pad, which is where the reported line actually was. Measured in
# HUD3 at 1024x768 inside the gauge span: rows 653..657 run lum 118/190/148/119/90
# against a floor of 18, and 658 onward is already floor. A 3px pad topped out at
# 659 -- one row BELOW the band -- which is why three separate attempts at the
# bottom of the well never touched it. 9 reaches row 653 and covers the lot.
$GAUGE_MASK_PAD_T = 9
foreach ($dest in @($hud3, $hudoff)) {
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $stack = New-Object 'System.Collections.Generic.Stack[int]'
    $colBot = @{}
    $sx0 = [int]$gaugeR.x + [int]([int]$gaugeR.w / 2)
    $sy0 = $gy + [int]([int]$gaugeR.h / 2)
    $stack.Push($sy0 * $dest.BytesPerLine + $sx0) | Out-Null
    $n = 0
    while ($stack.Count -gt 0) {
        $o = $stack.Pop()
        if (-not $seen.Add($o)) { continue }
        # [int] ROUNDS in PowerShell, it does not truncate -- [int](685621/1024) is
        # 670, not 669, which drove $px negative and made the fill visit nothing.
        $py = [int][Math]::Floor($o / $dest.BytesPerLine); $px = $o - $py * $dest.BytesPerLine
        if ($px -lt $bx0 -or $px -gt $bx1 -or $py -lt $by0 -or $py -gt $by1) { continue }
        [int]$cur = $dest.Pixels[$o]
        if ($cur -ne 1 -and $cur -ne 2) { continue }
        $dest.Pixels[$o] = [byte]$FLOOR
        $n++
        if (-not $colBot.ContainsKey($px) -or $py -gt $colBot[$px]) { $colBot[$px] = $py }
        $stack.Push($o - 1) | Out-Null
        $stack.Push($o + 1) | Out-Null
        $stack.Push($o - $dest.BytesPerLine) | Out-Null
        $stack.Push($o + $dest.BytesPerLine) | Out-Null
    }
    $deep = 0
    foreach ($cx in @($colBot.Keys)) {
        for ($k = 1; $k -le $GAUGE_DEEPEN; $k++) {
            $ey = $colBot[$cx] + $k
            if ($ey -ge $dest.Height) { break }
            $dest.Pixels[$ey * $dest.BytesPerLine + $cx] = [byte]$FLOOR
            $deep++
        }
    }

    # ---- the mask (OFF) ----------------------------------------------------
    #
    # DISABLED 2026-09-24. This was an attempt to hide a bright line above the bar
    # by painting the panel art black behind it. It does not work and it should not
    # have been expected to: the line is drawn AT RUNTIME, over the panel, so the
    # mask sits behind it -- and all it achieved was flattening the recess bezel.
    #
    # The line appears only with the rebuilt health bar, so it belongs to the gauge
    # patches (surface 105x15 -> 130x14, the three 1575 -> 1820 buffers, the 1000 ->
    # 808 divisor, and an H1.PCX that is fully opaque where the stock one had three
    # transparent rows top and bottom). It is not a panel-artwork problem at all.
    if ($GAUGE_MASK) {
    # A plain black plate painted behind the bar: the gauge rect grown by
    # $GAUGE_MASK_PAD on every side, with slightly rounded corners, forced to the
    # recess floor ink. Unconditional -- it does not care what ink was underneath,
    # which is the difference between this and the flood above (the flood only
    # traverses the two recess inks and stops at anything else, so it can never
    # cover a stray pixel drawn in a third colour).
    $mx0 = [Math]::Max(0, [int]$gaugeR.x - $GAUGE_MASK_PAD)
    $my0 = [Math]::Max(0, $gy - $GAUGE_MASK_PAD_T)
    $mx1 = [Math]::Min($dest.Width - 1,  [int]$gaugeR.x + [int]$gaugeR.w - 1 + $GAUGE_MASK_PAD)
    $my1 = [Math]::Min($dest.Height - 1, $gy + [int]$gaugeR.h - 1 + $GAUGE_MASK_PAD_B)
    $mr  = $GAUGE_MASK_R
    $masked = 0
    for ($my = $my0; $my -le $my1; $my++) {
        for ($mxx = $mx0; $mxx -le $mx1; $mxx++) {
            # Corner rounding: only inside the $mr square at each corner is a
            # radius test applied, so the straight edges stay straight.
            $dx = 0; $dy = 0
            if     ($mxx -lt $mx0 + $mr) { $dx = ($mx0 + $mr) - $mxx }
            elseif ($mxx -gt $mx1 - $mr) { $dx = $mxx - ($mx1 - $mr) }
            if     ($my  -lt $my0 + $mr) { $dy = ($my0 + $mr) - $my }
            elseif ($my  -gt $my1 - $mr) { $dy = $my - ($my1 - $mr) }
            if ($dx -gt 0 -and $dy -gt 0 -and (($dx*$dx + $dy*$dy) -gt ($mr*$mr))) { continue }
            $dest.Pixels[$my * $dest.BytesPerLine + $mxx] = [byte]$FLOOR
            $masked++
        }
    }
    }

    if ($dest -eq $hud3) {
        $maskTxt = if ($GAUGE_MASK) { "masked {0} px as ({1},{2})..({3},{4}) r{5}" -f $masked, $mx0, $my0, $mx1, $my1, $mr }
                   else             { 'mask OFF (the line it chased is drawn at runtime, not in the art)' }
        Write-Host ("   gauge well: flooded {0} px to index {1} (#{2:X2}{3:X2}{4:X2}), deepened {5} rows, {6}" -f `
            $n, $FLOOR, $pal[$FLOOR*3], $pal[$FLOOR*3+1], $pal[$FLOOR*3+2], $GAUGE_DEEPEN, $maskTxt)
    }
}

$hud3.SavePcx((Join-Path $ArtDir 'HUD3.PCX'))
$hudoff.SavePcx((Join-Path $ArtDir 'HUDOFF.PCX'))
Write-Host "arrows, button faces and screen fills composited into HUD3.PCX / HUDOFF.PCX"

