# Build-HudBox.ps1 -- slice the expanding log box's two frames out of a contact
# sheet and turn them into game-palette PCXs.
#
# The box has two states and each needs its own image, because the frame's top
# edge has to appear at two different screen rows and no single bitmap can put a
# border in both places (see the box blob in Build-AztMod.ps1).
#
#   BOXOFF.PCX   174 x 94    collapsed, sits at screen (554, 489)
#   BOXON.PCX    174 x 214   expanded,  sits at screen (554, 369)
#
# THE ARTWORK DRIVES THE CODE, as with the panel: this measures the interior
# recess out of the finished image and writes it to art\hud-box.json, and
# Build-AztMod sizes the text window from that rather than from guesses. Move the
# rail in a re-render and the text follows it.
#
# The sheet is expected to be a white page with the two panels on it, at whatever
# size the renderer felt like. They are found by connected components (>= 40000
# px) so labels, captions and 1:1 duplicates are ignored, and told apart by
# ASPECT -- wider than tall is the collapsed one -- never by position, so a
# re-arranged sheet cannot silently swap them.
param(
    [string]$Sheet,
    [string]$GameDir = "C:\Games\RaptorMod\game\GAME\AZRAEL",
    [string]$OutDir  = "$PSScriptRoot\..\art",
    [int]   $BoxW    = 174,
    [int]   $BoxHOff = 94,
    [int]   $BoxHOn  = 214,
    # Floyd-Steinberg on a frame this small stipples the flat recess, which reads
    # as noise behind the text. The render is already close to the panel's own
    # colours, so nearest-match is both cleaner and more faithful.
    [int]   $Dither  = 0,
    # Interior margin between the recess's edge and the text, in pixels.
    [int]   $Pad     = 4,
    # 3x3 box-blur passes before quantisation; see Build-Box.
    [int]   $Smooth  = 1
)

Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs"  -ReferencedAssemblies "System.Drawing"
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs" -ReferencedAssemblies "System.Drawing"
Add-Type -AssemblyName System.Drawing

$PAL_LO = 1; $PAL_HI = 53          # the HUD's own slice of the shared palette
$NCOL   = $PAL_HI - $PAL_LO + 1

if (-not $Sheet) {
    # Default to the newest ChatGPT drop in design\incoming.
    $Sheet = (Get-ChildItem "$PSScriptRoot\..\design\incoming" -Filter 'ChatGPT*.png' |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not (Test-Path $Sheet)) { throw "no sheet: $Sheet" }
Write-Host ("sheet: {0}" -f (Split-Path $Sheet -Leaf))

# ---- read the sheet, alpha = "is artwork" ----------------------------------
$bmp = New-Object System.Drawing.Bitmap $Sheet
$SW = $bmp.Width; $SH = $bmp.Height
$bd = $bmp.LockBits((New-Object System.Drawing.Rectangle 0,0,$SW,$SH),
                    [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$src = New-Object byte[] ($SW*$SH*4)
[System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $src, 0, $src.Length)
$bmp.UnlockBits($bd); $bmp.Dispose()
for ($i = 0; $i -lt $SW*$SH; $i++) {
    $b = $src[$i*4]; $g = $src[$i*4+1]; $r = $src[$i*4+2]
    $src[$i*4+3] = if ($r -lt 235 -or $g -lt 235 -or $b -lt 235) { 255 } else { 0 }
}

$bl = [LeTool.Quant]::Blobs($src, $SW, $SH, 40000)
if ($bl.Length -lt 10) { throw ("expected two panels on the sheet, found {0}" -f ($bl.Length/5)) }
$panels = @()
for ($i = 0; $i -lt $bl.Length; $i += 5) {
    $panels += @{ x=$bl[$i]; y=$bl[$i+1]; w=$bl[$i+2]; h=$bl[$i+3]; a=($bl[$i+2]/$bl[$i+3]) }
}
$panels = @($panels | Sort-Object { -($_.w * $_.h) } | Select-Object -First 2)
$off = @($panels | Sort-Object { -$_.a })[0]     # widest = collapsed
$on  = @($panels | Sort-Object {  $_.a })[0]     # tallest = expanded
if ($off.x -eq $on.x -and $off.y -eq $on.y) { throw 'both panels resolved to the same blob' }

# ---- the palette we have to live inside ------------------------------------
#
# PREFER art\HUD3.PCX -- THE ONE THIS BUILD JUST MADE. Reading it from $GameDir was
# wrong in two different ways and cost a real corruption bug on 2026-09-24:
#
#   * $GameDir defaults to the INSTALLED copy, so the palette is whatever was
#     installed LAST. Regenerating at 1024x768 while 1280x1024 was still installed
#     quantised the box art against the 1280 palette. Build-HudSkin re-quantises the
#     render to 53 colours at each resolution, and the chosen colours DIFFER because
#     the image being quantised differs -- so the box came out mapped into a palette
#     the game never loads. On screen: "shiny, all yellow/white".
#   * On a FIRST install there is no modded art there at all, so it would read
#     Mindscape's stock palette instead of the reskin's.
#
# art\HUD3.PCX is the authoritative reskin palette and the one the game will
# actually upload, so bind to that and fall back to $GameDir only if it is absent
# (a build that ships no replacement HUD3).
$palSrc = Join-Path $OutDir 'HUD3.PCX'
if (-not (Test-Path $palSrc)) { $palSrc = Join-Path $GameDir 'HUD3.PCX' }
Write-Host ("palette from {0}" -f $palSrc)
$base = [LeTool.Pcx]::Load((Resolve-Path $palSrc).Path)
$gamePal = $base.Palette
$sub = New-Object byte[] ($NCOL*3)
for ($i = 0; $i -lt $NCOL; $i++) {
    $sub[$i*3]   = $gamePal[($PAL_LO+$i)*3]
    $sub[$i*3+1] = $gamePal[($PAL_LO+$i)*3+1]
    $sub[$i*3+2] = $gamePal[($PAL_LO+$i)*3+2]
}

# ---- one state -------------------------------------------------------------
# Returns the recess rect, measured from the FINISHED indices rather than from
# the source: what matters is where the dark area lands after scaling, not where
# the artist drew it.
function Build-Box {
    param($P, [int]$DW, [int]$DH, [string]$Name)

    $d = New-Object byte[] ($DW*$DH*4)
    [LeTool.Quant]::Resample($src, $SW, $SH, $SW*4,
                             $P.x, $P.y, ($P.x+$P.w), ($P.y+$P.h), $d, $DW, $DH)

    # DENOISE BEFORE QUANTISING. The render carries film grain, and 53 colours is
    # not enough to hold a smooth metal gradient: neighbouring pixels that differ
    # by one or two levels get mapped to DIFFERENT near-identical golds, and the
    # rail comes out speckled. A 40x8 patch of it held 28 distinct indices.
    #
    # Resample is already an area average, so this is not about the scaling --
    # it is about grain surviving into the palette lookup. The bigger the box
    # (256x143 at 1024x768 vs 207x111 at 800x600) the less the downscale averages
    # away and the worse it gets, which is why this only became visible at 1024.
    #
    # A 3x3 box blur costs a little crispness on the bevel and removes almost all
    # of the speckle, because it pulls adjacent pixels onto the same palette entry.
    #
    # MEASURE ON THE SHARP VERSION, SHIP THE SMOOTH ONE. The recess rect is found
    # by walking out from the centre while the brightness matches, and blurring
    # softens the bevel enough to move that edge a pixel -- which was enough to
    # trip the "both frames must agree" guard below (22 vs 19). Geometry comes
    # from the unblurred indices; only the pixels we write are denoised.
    $sharp = [LeTool.Quant]::Map($d, $DW, $DH, $sub, $NCOL, $PAL_LO, $Dither)
    if ($Smooth -gt 0) {
        for ($pass = 0; $pass -lt $Smooth; $pass++) {
            $s = $d.Clone()
            for ($y = 0; $y -lt $DH; $y++) {
                for ($x = 0; $x -lt $DW; $x++) {
                    $b=0;$g=0;$r=0;$a=0;$n=0
                    for ($dy = -1; $dy -le 1; $dy++) {
                        $yy = $y + $dy; if ($yy -lt 0 -or $yy -ge $DH) { continue }
                        for ($dx = -1; $dx -le 1; $dx++) {
                            $xx = $x + $dx; if ($xx -lt 0 -or $xx -ge $DW) { continue }
                            $o = ($yy*$DW + $xx)*4
                            $b += $s[$o]; $g += $s[$o+1]; $r += $s[$o+2]; $a += $s[$o+3]; $n++
                        }
                    }
                    $o = ($y*$DW + $x)*4
                    $d[$o]=[byte]($b/$n); $d[$o+1]=[byte]($g/$n); $d[$o+2]=[byte]($r/$n); $d[$o+3]=[byte]($a/$n)
                }
            }
        }
    }
    $idx = [LeTool.Quant]::Map($d, $DW, $DH, $sub, $NCOL, $PAL_LO, $Dither)

    $pcx = New-Object LeTool.Pcx
    $pcx.Width = $DW; $pcx.Height = $DH
    $pcx.BitsPerPixel = 8; $pcx.Planes = 1; $pcx.BytesPerLine = $DW
    $pcx.Pixels = $idx
    $pcx.Palette = $gamePal.Clone()
    $out = Join-Path $OutDir "$Name.PCX"
    $pcx.SavePcx($out)

    # The recess, by luminance: walk out from the centre while it stays dark.
    $lum = New-Object int[] 256
    for ($i = 0; $i -lt 256; $i++) {
        $lum[$i] = [int](0.299*$gamePal[$i*3] + 0.587*$gamePal[$i*3+1] + 0.114*$gamePal[$i*3+2])
    }
    # MATCH THE CENTRE, DO NOT JUST TEST FOR "DARK". A plain luma < 70 test walks
    # straight through the recess's inner shadow, which is darker than the fill,
    # and stops somewhere in the bevel -- so the rect came out several pixels too
    # big on the top and left and the text drew onto the frame. Holding to the
    # centre's own brightness stops at the first pixel that is not the fill.
    $cx = [int]($DW/2); $cy = [int]($DH/2)
    $c   = $lum[$sharp[$cy*$DW + $cx]]
    $TOL = 10
    $x0 = $cx; while ($x0 -gt 0     -and [Math]::Abs($lum[$sharp[$cy*$DW + $x0 - 1]] - $c) -le $TOL) { $x0-- }
    $x1 = $cx; while ($x1 -lt $DW-1 -and [Math]::Abs($lum[$sharp[$cy*$DW + $x1 + 1]] - $c) -le $TOL) { $x1++ }
    $y0 = $cy; while ($y0 -gt 0     -and [Math]::Abs($lum[$sharp[($y0-1)*$DW + $cx]] - $c) -le $TOL) { $y0-- }
    $y1 = $cy; while ($y1 -lt $DH-1 -and [Math]::Abs($lum[$sharp[($y1+1)*$DW + $cx]] - $c) -le $TOL) { $y1++ }
    # Interior padding. One pixel only kept the text off the bevel; it still read
    # as butting every edge, because a text block fills its surface exactly and
    # the engine gives it no margin of its own.
    $x0 += $Pad; $y0 += $Pad; $x1 -= $Pad; $y1 -= $Pad

    $used = @{}
    foreach ($b in $idx) { $used[$b] = 1 }
    Write-Host ("{0,-7} {1,3}x{2,-3} from {3}x{4} (x{5:N3},{6:N3})  recess x {7}..{8}  y {9}..{10}  {11} colours" -f `
        $Name, $DW, $DH, $P.w, $P.h, ($DW/$P.w), ($DH/$P.h), $x0, $x1, $y0, $y1, $used.Count)
    return @{ x0=$x0; x1=$x1; y0=$y0; y1=$y1 }
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$rOff = Build-Box $off $BoxW $BoxHOff 'BOXOFF'
$rOn  = Build-Box $on  $BoxW $BoxHOn  'BOXON'

# THE TEXT IS PINNED TO THE BOX'S TOP-LEFT (0x37D98 clamps a positive x or y to
# zero), so the left inset is not ours to choose -- it is always 0 and the art
# has to keep its left rail thin. The other three sides we can honour, and the
# RIGHT one is taken from the collapsed frame because both states share it.
# THE RECESS IS ITS OWN SURFACE, not an inset of the frame. The text block is
# pinned to its destination's (0,0) by 0x37D98 and cannot be offset, so the only
# way to get it inside the bezel is for the bezel not to be part of that surface:
# the frame blits first, the recess blits on top, and the text lands at the
# recess's own origin. That is also why the frame may now be wider than the
# recess on EVERY side, which is what lets it cover the panel's old well.
#
# The two states must agree on where the recess starts, because the frame's Y is
# derived from the recess's by subtracting this.
if ($rOff.x0 -ne $rOn.x0) {
    Write-Host ("  note: recess left differs between states ({0} vs {1}); using the closed one" -f $rOff.x0, $rOn.x0)
}
#
# The two renders do not agree on the rail to the pixel, and the disagreement GROWS
# WITH THE FRAME: they are scaled to a common width but different heights, so their
# top borders land on different destination rows (1-2px at 1024x768, 4px at
# 1280x1024). A flat "2px" tolerance is therefore a resolution test masquerading as
# a registration test.
#
# What actually goes wrong is narrower than "the box jumps". The recess ORIGIN is
# shared -- only the heights are per-state -- so if the open frame's rail sits above
# that origin and its height is measured from its own rail, the recess surface
# overhangs the bottom bevel by the difference. So take the LOWER of the two rails
# as the origin (no frame ink is then left exposed above the recess) and measure
# both heights FROM THAT ORIGIN to each state's own bottom. The recess is then
# contained in both frames by construction and the residual is invisible: a few
# rows of the frame's own interior above the surface, in the same dark ink.
$recessY = [Math]::Max($rOff.y0, $rOn.y0)
if ($rOff.y0 -ne $rOn.y0) {
    Write-Host ("  note: top rails differ between states ({0} vs {1}); recess pinned to {2} and both heights measured from it" -f `
        $rOff.y0, $rOn.y0, $recessY)
}
# Beyond a twentieth of the frame it is no longer resampling slack, it is the wrong
# artwork or a misdetected recess.
$railTol = [Math]::Max(2, [int][Math]::Round($BoxHOff / 20.0))
if ([Math]::Abs($rOff.y0 - $rOn.y0) -gt $railTol) {
    throw "the two frames' top rails differ by $([Math]::Abs($rOff.y0 - $rOn.y0))px ($($rOff.y0) vs $($rOn.y0)), over the ${railTol}px allowed for a ${BoxHOff}px frame -- check the source renders"
}

# The chevron, for the click rect: the brightest ink to the right of the recess,
# in the top third. Padded out to the whole button so a click near it still lands.
$b = [LeTool.Pcx]::Load((Join-Path $OutDir 'BOXOFF.PCX'))
$ix0=999;$ix1=-1;$iy0=999;$iy1=-1
for ($y=0; $y -lt [int]($BoxHOff/3); $y++) {
    for ($x=$rOff.x1+1; $x -lt $BoxW; $x++) {
        $i=[int]$b.Pixels[$y*$BoxW+$x]
        if ($gamePal[$i*3] -gt 200 -and $gamePal[$i*3+1] -gt 120 -and $gamePal[$i*3+2] -lt 60) {
            if($x -lt $ix0){$ix0=$x}; if($x -gt $ix1){$ix1=$x}
            if($y -lt $iy0){$iy0=$y}; if($y -gt $iy1){$iy1=$y}
        }
    }
}
if ($ix1 -lt 0) { throw 'no chevron found in the closed frame -- the toggle would be unclickable' }
$PAD = 4
$box = [ordered]@{
    frameW     = $BoxW
    frameHOff  = $BoxHOff
    frameHOn   = $BoxHOn
    recessX    = $rOff.x0
    recessY    = $recessY
    recessW    = $rOff.x1 - $rOff.x0 + 1
    recessHOff = $rOff.y1 - $recessY + 1
    recessHOn  = $rOn.y1  - $recessY + 1
    iconX0     = [Math]::Max(0, $ix0 - $PAD)
    iconY0     = [Math]::Max(0, $iy0 - $PAD)
    iconX1     = [Math]::Min($BoxW - 1, $ix1 + $PAD)
    iconY1     = $iy1 + $PAD
}
$box | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutDir 'hud-box.json') -Encoding utf8
Write-Host ("recess {0}x{1} (open {2}) at +{3},+{4} in the frame;  toggle x {5}..{6} y {7}..{8}" -f `
    $box.recessW, $box.recessHOff, $box.recessHOn, $box.recessX, $box.recessY,
    $box.iconX0, $box.iconX1, $box.iconY0, $box.iconY1)


