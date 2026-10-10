# Build-HudSkin.ps1 -- convert the new panel render into the game's HUD art.
#
# WHAT THIS PRODUCES
#   HUD3.PCX      800x600, the lit panel in rows 489..599, and THE PALETTE
#   HUDOFF.PCX    the same geometry, powered-down state
#   HUDBOT.RES    the 33 bleed rows, composited into the 3D view so the panel's
#                 silhouette bites up into the image instead of butting against it
#   MAPBKGRD.PCX  re-pointed to a surviving index (it uses exactly one colour)
#   hud-layout.json  the eight engine-drawn regions, measured from the artwork,
#                 for Build-AztMod to move the game's coordinates onto
#
# THE PALETTE BUDGET -- every one of these was established by reading the loader
# or by probing the running game, not assumed:
#
#   0          transparency key; also the panel's own transparent corners -> black
#   1..53      OURS. 53 colours, chosen from the artwork by median cut.
#   54         MUST STAY #000000. It is the backdrop fill for every row above the
#              panel (100% of HUD3 rows 0..488 are this one index) AND the glyph
#              shadow Build-Font hardcodes.
#   55, 56     the cyan and gold font inks. Reserved so the story log keeps its
#              two distinguishable colours.
#   57         spare, unused by anything we ship.
#   58..71     overwritten from h1.pcx by the loader at 0x2843D.
#   72..127    Reality Lab shading ramps. Repainting 72..86 turned the entire 3D
#              world red in game -- these belong to the renderer.
#   128..255   overwritten from pal.pcx at 0x28524 (character / flesh tones).
#
# So HUD3.PCX carries the palette for the whole game, and we may only rewrite
# 1..53 of it. That is one colour fewer than the stock panel used, for artwork
# with far more tonal range -- which is why the registration blocks are masked
# out of the palette vote below.
[CmdletBinding()]
param(
    [string]$PanelPng = "$PSScriptRoot\..\design\incoming\panel-pair.png",
    [string]$OutDir   = "$PSScriptRoot\..\art",
    [int]   $ScreenW  = 800,
    [int]   $ScreenH  = 600,
    [int]   $PanelTop = 489,
    [int]   $ViewY    = 49,
    [int]   $Dither   = 0,
    # The two panels' extents in the source render, measured from its alpha.
    [int]   $LitTop = 59,  [int]$LitSolid = 133, [int]$LitBot = 381,
    [int]   $OffTop = 451, [int]$OffSolid = 525, [int]$OffBot = 772
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs"
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies "System.Drawing"
Add-Type -AssemblyName PresentationCore

$PAL_LO = 1; $PAL_HI = 53
$NCOL   = $PAL_HI - $PAL_LO + 1
$BLACK  = 54
$PanelH = $ScreenH - $PanelTop

# ---- load the render -------------------------------------------------------
$fs = [System.IO.File]::OpenRead($PanelPng)
$fr = [System.Windows.Media.Imaging.BitmapDecoder]::Create($fs,'None','OnLoad').Frames[0]
$SW = $fr.PixelWidth; $SH = $fr.PixelHeight; $sStride = $SW*4
$src = New-Object 'byte[]' ($sStride*$SH)
(New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($fr,[System.Windows.Media.PixelFormats]::Bgra32,$null,0)).CopyPixels($src,$sStride,0)
$fs.Close()

$sy    = $PanelH / [double]($LitBot - $LitSolid + 1)
$BLEED = [int][Math]::Round(($LitSolid - $LitTop) * $sy)
$DH    = $BLEED + $PanelH
if (($OffSolid - $OffTop) -ne ($LitSolid - $LitTop)) { throw "the two panels do not register: bleed $($LitSolid-$LitTop) vs $($OffSolid-$OffTop)" }
Write-Host ("panel {0}x{1}: {2} bleed rows + {3} body   (scaleX {4:N4} scaleY {5:N4})" -f $ScreenW,$DH,$BLEED,$PanelH,($ScreenW/[double]$SW),$sy)

function Get-Panel { param([int]$Top,[int]$Bot)
    $d = New-Object 'byte[]' ($ScreenW*$DH*4)
    [LeTool.Quant]::Resample($src,$SW,$SH,$sStride,0,$Top,$SW,($Bot+1),$d,$ScreenW,$DH)
    return $d
}
$lit = Get-Panel $LitTop $LitBot
$off = Get-Panel $OffTop $OffBot

# ---- mask the registration blocks -----------------------------------------
# Tight mask -> forced to index 0 (an unlit recess). Dilated mask -> excluded
# from the palette vote only, because the 2.5:1 downscale smears the blocks'
# antialiased edges into a purple ring that otherwise wins ten palette slots.
function Get-Masks { param([byte[]]$D)
    $tight = New-Object 'bool[]' ($ScreenW*$DH)
    $ring  = New-Object 'bool[]' ($ScreenW*$DH)
    for ($i=0; $i -lt $ScreenW*$DH; $i++) {
        $o=$i*4; if ($D[$o+3] -lt 128) { continue }
        $r=[int]$D[$o+2]; $g=[int]$D[$o+1]; $b=[int]$D[$o]
        if ($r -gt 150 -and $g -lt 110 -and $b -gt 150) { $tight[$i]=$true }
        if (([Math]::Min($r,$b) - $g) -gt 28) { $ring[$i]=$true }
    }
    $dil = New-Object 'bool[]' ($ScreenW*$DH); $R=3
    for ($y=0; $y -lt $DH; $y++) { for ($x=0; $x -lt $ScreenW; $x++) {
        $hit=$false
        for ($dy=-$R; $dy -le $R -and -not $hit; $dy++) { for ($dx=-$R; $dx -le $R; $dx++) {
            $ny=$y+$dy; $nx=$x+$dx
            if ($ny -lt 0 -or $ny -ge $DH -or $nx -lt 0 -or $nx -ge $ScreenW) { continue }
            if ($ring[$ny*$ScreenW+$nx]) { $hit=$true; break } } }
        if ($hit) { $dil[$y*$ScreenW+$x]=$true } } }

    # A THIRD MASK, for the FILL. Excluding the contaminated ring from the palette
    # vote stopped it winning slots, but those pixels were still mapped normally --
    # and the nearest colour to a purple-tinted pixel in an all-brass palette is a
    # SATURATED ORANGE. Measured on the inventory window: 70 border pixels of
    # index 46 = #844309, which reads in game as a bright vertical line down each
    # side of the recess. Growing the tight mask by 2px lets the recess swallow
    # them. Measurement still uses Tight, so the published region rects are
    # unaffected and the engine keeps drawing exactly where it did.
    $fill = New-Object 'bool[]' ($ScreenW*$DH); $FR=2
    for ($y=0; $y -lt $DH; $y++) { for ($x=0; $x -lt $ScreenW; $x++) {
        $hit=$false
        for ($dy=-$FR; $dy -le $FR -and -not $hit; $dy++) { for ($dx=-$FR; $dx -le $FR; $dx++) {
            $ny=$y+$dy; $nx=$x+$dx
            if ($ny -lt 0 -or $ny -ge $DH -or $nx -lt 0 -or $nx -ge $ScreenW) { continue }
            if ($tight[$ny*$ScreenW+$nx]) { $hit=$true; break } } }
        if ($hit) { $fill[$y*$ScreenW+$x]=$true } } }
    return @{ Tight=$tight; Dil=$dil; Fill=$fill }
}
$mLit = Get-Masks $lit
$mOff = Get-Masks $off

# ---- choose the palette from BOTH states ----------------------------------
# HUD3 and HUDOFF share one palette (the loader only ever uploads HUD3's), so the
# colours must be voted on by both or the powered-down state quantises badly.
$vote = New-Object 'byte[]' ($ScreenW*$DH*2*4)
[Array]::Copy($lit,0,$vote,0,$lit.Length)
[Array]::Copy($off,0,$vote,$lit.Length,$off.Length)
for ($i=0; $i -lt $ScreenW*$DH; $i++) {
    if ($mLit.Dil[$i]) { $vote[$i*4+3] = 0 }
    if ($mOff.Dil[$i]) { $vote[($ScreenW*$DH+$i)*4+3] = 0 }
}
$newPal = [LeTool.Quant]::MedianCut($vote,$ScreenW,($DH*2),$NCOL)

# ---- start from the current art so rows 0..488 and indices 54.. survive ----
$base = [LeTool.Pcx]::Load((Join-Path $OutDir 'HUD3.PCX'))
$pal  = $base.Palette.Clone()
for ($i=0; $i -lt $NCOL; $i++) {
    $pal[($PAL_LO+$i)*3]   = $newPal[$i*3]
    $pal[($PAL_LO+$i)*3+1] = $newPal[$i*3+1]
    $pal[($PAL_LO+$i)*3+2] = $newPal[$i*3+2]
}
$pal[$BLACK*3] = 0; $pal[$BLACK*3+1] = 0; $pal[$BLACK*3+2] = 0   # non-negotiable

# THE RECESSES MUST NOT BE PURE BLACK. The engine only draws into the automap,
# scan, gauge and action sockets when it has something to show, and the action
# lamps are blank most of the time. Filled with #000000 they read as holes
# punched through the panel. Two dark tones from the artwork's own palette --
# darkest for the well, one step up for the bottom lip where light would catch --
# make an empty socket read as an unlit instrument instead.
$lum = @()
for ($i=0; $i -lt $NCOL; $i++) { $lum += [pscustomobject]@{ i=($PAL_LO+$i); v=(0.299*$newPal[$i*3] + 0.587*$newPal[$i*3+1] + 0.114*$newPal[$i*3+2]) } }
$dark = @($lum | Sort-Object v)
$RECESS = $dark[0].i; $LIP = $dark[1].i
Write-Host ("recess fill: index {0} (#{1:X2}{2:X2}{3:X2}), lip {4} (#{5:X2}{6:X2}{7:X2})" -f `
    $RECESS,$pal[$RECESS*3],$pal[$RECESS*3+1],$pal[$RECESS*3+2],$LIP,$pal[$LIP*3],$pal[$LIP*3+1],$pal[$LIP*3+2])

function New-Sheet {
    param([byte[]]$D, [hashtable]$M)
    $idx = [LeTool.Quant]::Map($D,$ScreenW,$DH,$newPal,$NCOL,$PAL_LO,$Dither)
    # Fill (tight grown 2px), NOT Tight -- see Get-Masks. The extra ring is what
    # kills the orange edge; it reads as a slightly deeper bezel shadow.
    for ($i=0; $i -lt $ScreenW*$DH; $i++) {
        if (-not $M.Fill[$i]) { continue }
        $below = $i + 2*$ScreenW
        $idx[$i] = $(if ($below -lt $ScreenW*$DH -and -not $M.Fill[$below]) { [byte]$LIP } else { [byte]$RECESS })
    }
    $s = New-Object LeTool.Pcx
    $s.Width=$ScreenW; $s.Height=$ScreenH; $s.BitsPerPixel=8; $s.Planes=1; $s.BytesPerLine=$ScreenW
    $s.Pixels = New-Object byte[] ($ScreenW*$ScreenH)
    for ($i=0; $i -lt $s.Pixels.Length; $i++) { $s.Pixels[$i] = [byte]$BLACK }   # backdrop
    for ($y=0; $y -lt $PanelH; $y++) { for ($x=0; $x -lt $ScreenW; $x++) {
        $v = $idx[($BLEED+$y)*$ScreenW+$x]
        $s.Pixels[($PanelTop+$y)*$ScreenW+$x] = $(if ($v -eq 0) { [byte]$BLACK } else { $v })   # 0 = outside the silhouette
    } }
    $s.Palette = $pal.Clone()
    return @{ Sheet=$s; Idx=$idx }
}
$rLit = New-Sheet $lit $mLit
$rOff = New-Sheet $off $mOff
$rLit.Sheet.SavePcx((Join-Path $OutDir 'HUD3.PCX'))
$rOff.Sheet.SavePcx((Join-Path $OutDir 'HUDOFF.PCX'))
Write-Host ("wrote HUD3.PCX and HUDOFF.PCX  ({0} colours in indices {1}..{2})" -f $NCOL,$PAL_LO,$PAL_HI)

# ---- MAPBKGRD uses exactly one index; re-point it --------------------------
$mb = [LeTool.Pcx]::Load((Join-Path $OutDir 'MAPBKGRD.PCX'))
$oldIdx = 10
$want = @($base.Palette[$oldIdx*3], $base.Palette[$oldIdx*3+1], $base.Palette[$oldIdx*3+2])
$best = $PAL_LO; $bd = [double]::MaxValue
for ($i=0; $i -lt $NCOL; $i++) {
    $dr=$newPal[$i*3]-$want[0]; $dg=$newPal[$i*3+1]-$want[1]; $db=$newPal[$i*3+2]-$want[2]
    $d = $dr*$dr*0.299 + $dg*$dg*0.587 + $db*$db*0.114
    if ($d -lt $bd) { $bd=$d; $best=$PAL_LO+$i }
}
for ($i=0; $i -lt $mb.Pixels.Length; $i++) { if ($mb.Pixels[$i] -eq $oldIdx) { $mb.Pixels[$i] = [byte]$best } }
$mb.Palette = $pal.Clone()
$mb.SavePcx((Join-Path $OutDir 'MAPBKGRD.PCX'))
Write-Host ("MAPBKGRD.PCX: index {0} (#{1:X2}{2:X2}{3:X2}) -> {4} (#{5:X2}{6:X2}{7:X2})" -f `
    $oldIdx,$want[0],$want[1],$want[2],$best,$pal[$best*3],$pal[$best*3+1],$pal[$best*3+2])

# ---- HUDBOT.RES : the bleed rows, into the 3D view -------------------------
# EIGHT-byte trailer here (word count + destination offset), unlike HUDTOP's
# four -- the loader really does read the two files differently. See
# Build-HudTop.ps1 for what getting that backwards does.
$rowStart = $PanelTop - $BLEED - $ViewY          # first bleed row, in VIEW rows
$destOff  = $rowStart * $ScreenW
$px = @{}
for ($y=0; $y -lt $BLEED; $y++) { for ($x=0; $x -lt $ScreenW; $x++) {
    $v = $rLit.Idx[$y*$ScreenW+$x]
    if ($v -ne 0) { $px[($rowStart+$y)*$ScreenW + $x] = [byte]$v }
} }
$offs = @($px.Keys | Sort-Object)
$out = New-Object System.Collections.Generic.List[byte]
$words = 0
function Add-Word { param([int]$v) $script:out.Add([byte]($v -band 0xFF)); $script:out.Add([byte](($v -shr 8) -band 0xFF)); $script:words++ }
function Add-Gap { param([int]$g) while ($g -gt 65535) { Add-Word 65535; Add-Word 0; $g -= 65535 }; Add-Word $g }
$cur = $destOff; $i = 0
while ($i -lt $offs.Count) {
    $start = $offs[$i]; $j = $i
    while ($j+1 -lt $offs.Count -and $offs[$j+1] -eq $offs[$j]+1) { $j++ }
    $len = $offs[$j] - $start + 1
    $gap = $start - $cur
    if ($words -eq 0 -and $gap -ne 0) { Add-Word 0 }
    if ($words -gt 0 -or $gap -ne 0)  { Add-Gap $gap }
    Add-Word $len
    for ($k=$start; $k -le $offs[$j]; $k++) { $out.Add($px[$k]) }
    $cur = $start + $len; $i = $j + 1
}
$VIEW_H = $PanelTop - $ViewY
if (($cur-1) -ge ($ScreenW*$VIEW_H)) { throw "overlay would write past the view ($($cur-1) >= $($ScreenW*$VIEW_H))" }
$out.AddRange([byte[]][BitConverter]::GetBytes([int]$words))
$out.AddRange([byte[]][BitConverter]::GetBytes([int]$destOff))
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'HUDBOT.RES'), $out.ToArray())
Write-Host ("HUDBOT.RES  {0} px over {1} rows from view row {2}, {3} words, last byte {4} of {5}, {6:N0} bytes" -f `
    $px.Count,$BLEED,$rowStart,$words,($cur-1),($ScreenW*$VIEW_H),$out.Count)

# ---- measure the regions and publish them ---------------------------------
# Connected components of the tight mask, in PANEL-LOCAL coordinates, so
# Build-AztMod can move the engine's draw sites onto the artwork.
$lab = New-Object 'int[]' ($ScreenW*$DH); $n=0; $boxes=@()
for ($s=0; $s -lt $ScreenW*$DH; $s++) {
    if (-not $mLit.Tight[$s] -or $lab[$s] -ne 0) { continue }
    $n++; $stk = New-Object System.Collections.Generic.Stack[int]; $stk.Push($s); $lab[$s]=$n
    $x0=$ScreenW;$x1=0;$y0=$DH;$y1=0;$c=0
    while ($stk.Count) { $p=$stk.Pop(); $c++; $cx=$p%$ScreenW; $cy=[int][Math]::Floor($p/$ScreenW)
        if($cx -lt $x0){$x0=$cx}; if($cx -gt $x1){$x1=$cx}; if($cy -lt $y0){$y0=$cy}; if($cy -gt $y1){$y1=$cy}
        foreach ($d in @(-1,1,-$ScreenW,$ScreenW)) { $q=$p+$d
            if ($q -lt 0 -or $q -ge $ScreenW*$DH) { continue }
            if ($d -eq -1 -and $cx -eq 0) { continue }; if ($d -eq 1 -and $cx -eq $ScreenW-1) { continue }
            if ($mLit.Tight[$q] -and $lab[$q] -eq 0) { $lab[$q]=$n; $stk.Push($q) } } }
    if ($c -gt 60) { $boxes += [pscustomobject]@{ x=$x0; y=($y0-$BLEED); w=($x1-$x0+1); h=($y1-$y0+1); px=$c } }
}
$boxes = @($boxes | Sort-Object { $_.y * 10000 + $_.x })
Write-Host ("`nregions found in the artwork ({0}), panel-local:" -f $boxes.Count)
foreach ($b in $boxes) { "   ({0,3},{1,3})  {2,3} x {3,3}" -f $b.x,$b.y,$b.w,$b.h }
@{ screenW=$ScreenW; screenH=$ScreenH; panelTop=$PanelTop; viewY=$ViewY; bleed=$BLEED; regions=$boxes } |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'hud-layout.json') -Encoding utf8
Write-Host "wrote hud-layout.json"

