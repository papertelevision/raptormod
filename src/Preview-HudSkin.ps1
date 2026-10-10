# Preview-HudSkin.ps1 -- show what the new panel art looks like after it is
# reduced to the palette the game actually leaves us.
#
# THE BUDGET, established in game rather than assumed:
#   0        transparency key / black
#   1..57    OURS -- hud3.pcx supplies these and nothing overwrites them
#   58..71   overwritten from h1.pcx at 0x2843D (the status gauge ramp)
#   72..127  Reality Lab shading ramps. Repainting 72..86 turned the whole 3D
#            world red in game, so these belong to the renderer, not to us.
#   128..255 overwritten from pal.pcx at 0x28524 (character / flesh tones)
#
# So the panel gets 57 colours. This script renders the conversion at 1x and 3x,
# with and without dithering, and writes nothing into the game.
[CmdletBinding()]
param(
    [string]$In       = "$PSScriptRoot\..\design\incoming\panel-pair.png",
    [string]$OutDir   = "$PSScriptRoot\..\design",
    [int]   $Colours  = 57,
    [int]   $ScreenW  = 800,
    [int]   $PanelH   = 111,
    # The top panel's extent in the source render, measured from its alpha:
    # rows 59..381, with the body (fully opaque across the centre) starting at 133.
    [int]   $SrcTop   = 59,
    [int]   $SrcSolid = 133,
    [int]   $SrcBot   = 381
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs"
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Drawing

# ---- load the render -------------------------------------------------------
$fs = [System.IO.File]::OpenRead($In)
$fr = [System.Windows.Media.Imaging.BitmapDecoder]::Create($fs,'None','OnLoad').Frames[0]
$SW = $fr.PixelWidth; $SH = $fr.PixelHeight; $sStride = $SW*4
$src = New-Object 'byte[]' ($sStride*$SH)
$cv  = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($fr,[System.Windows.Media.PixelFormats]::Bgra32,$null,0)
$cv.CopyPixels($src,$sStride,0); $fs.Close()

# ---- geometry --------------------------------------------------------------
# One uniform vertical scale for bleed and body: the body must land on exactly
# $PanelH rows, and the bleed follows it. The horizontal scale is set by the
# screen width, so the art ends up slightly stretched vertically -- far less than
# the 0.685-vs-1.25 squash the stock art currently suffers.
$sy = $PanelH / [double]($SrcBot - $SrcSolid + 1)
$bleed = [int][Math]::Round(($SrcSolid - $SrcTop) * $sy)
$DH = $bleed + $PanelH
Write-Host ("source rows {0}..{1} (solid at {2})  ->  {3}x{4}: {5} bleed rows + {6} body" -f `
    $SrcTop,$SrcBot,$SrcSolid,$ScreenW,$DH,$bleed,$PanelH)
Write-Host ("scaleX {0:N4}  scaleY {1:N4}  ({2:P1} vertical stretch)" -f ($ScreenW/[double]$SW), $sy, (($sy/($ScreenW/[double]$SW))-1))

$dst = New-Object 'byte[]' ($ScreenW*$DH*4)
[LeTool.Quant]::Resample($src,$SW,$SH,$sStride,0,$SrcTop,$SW,($SrcBot+1),$dst,$ScreenW,$DH)

# ---- drop the registration blocks BEFORE choosing colours ------------------
# The eight #FF00FF rectangles are placeholders: the engine draws the automap,
# scan readout, gauge and action-button sprites over them. Left in, median cut
# spent ten of fifty-seven precious slots on shades of magenta. They are marked
# here, excluded from the palette vote, and forced to index 0 (black) afterwards
# -- which is what an unlit recess should look like anyway.
# TWO masks, because one is not enough. The blocks are antialiased against the
# bezel in the source render, and a 2.5:1 downscale smears that edge into a ring
# of purple-tinted metal. A tight mask left six half-magenta entries in the
# palette (#3C0141, #6B046F, #8D0494 ...), which is six colours of brass gone.
#   tight  -> forced to index 0 in the output (the recess itself)
#   vote   -> tight, dilated 3px, excluded from the palette vote only, so the
#             contaminated ring still gets an index but never earns one
$mag  = New-Object 'bool[]' ($ScreenW*$DH)
$dil  = New-Object 'bool[]' ($ScreenW*$DH)
$nm = 0
for ($i=0; $i -lt $ScreenW*$DH; $i++) {
    $o = $i*4
    if ($dst[$o+3] -lt 128) { continue }
    $r=[int]$dst[$o+2]; $g=[int]$dst[$o+1]; $b=[int]$dst[$o]
    if ($r -gt 150 -and $g -lt 110 -and $b -gt 150) { $mag[$i]=$true; $nm++ }
    # "magentaness": both R and B clearly above G. Catches the blended ring.
    if (([Math]::Min($r,$b) - $g) -gt 28) { $dil[$i]=$true }
}
$R = 3
$vote = New-Object 'byte[]' ($ScreenW*$DH*4)
[Array]::Copy($dst,$vote,$dst.Length)
$nv = 0
for ($y=0; $y -lt $DH; $y++) { for ($x=0; $x -lt $ScreenW; $x++) {
    $hit = $false
    for ($dy=-$R; $dy -le $R -and -not $hit; $dy++) { for ($dx=-$R; $dx -le $R; $dx++) {
        $ny=$y+$dy; $nx=$x+$dx
        if ($ny -lt 0 -or $ny -ge $DH -or $nx -lt 0 -or $nx -ge $ScreenW) { continue }
        if ($dil[$ny*$ScreenW+$nx]) { $hit=$true; break } } }
    if ($hit) { $vote[($y*$ScreenW+$x)*4+3] = 0; $nv++ }   # alpha 0 = ignored by MedianCut
} }
Write-Host ("`nregistration blocks: {0:N0} px forced to index 0, {1:N0} px ({2:P1}) excluded from the palette vote" -f $nm,$nv,($nv/($ScreenW*$DH)))

# ---- reduce ----------------------------------------------------------------
$pal = [LeTool.Quant]::MedianCut($vote,$ScreenW,$DH,$Colours)
Write-Host ("`nthe {0} colours chosen for indices 1..{0}:" -f $Colours)
$line = @()
for ($i=0; $i -lt $Colours; $i++) { $line += ('#{0:X2}{1:X2}{2:X2}' -f $pal[$i*3],$pal[$i*3+1],$pal[$i*3+2]) }
for ($i=0; $i -lt $line.Count; $i+=10) { "   " + (($line[$i..([Math]::Min($i+9,$line.Count-1))]) -join ' ') }

# ---- render both variants --------------------------------------------------
function Save-Preview {
    param([byte[]]$Idx, [string]$Name, [int]$Zoom)
    $bmp = New-Object System.Drawing.Bitmap ($ScreenW*$Zoom), ($DH*$Zoom)
    $bg  = [System.Drawing.Color]::FromArgb(0,0,0)
    for ($y=0; $y -lt $DH; $y++) { for ($x=0; $x -lt $ScreenW; $x++) {
        $v = $Idx[$y*$ScreenW+$x]
        if ($v -eq 0) { $c = $bg } else { $k=$v-1; $c=[System.Drawing.Color]::FromArgb($pal[$k*3],$pal[$k*3+1],$pal[$k*3+2]) }
        for($dy=0;$dy -lt $Zoom;$dy++){for($dx=0;$dx -lt $Zoom;$dx++){ $bmp.SetPixel($x*$Zoom+$dx,$y*$Zoom+$dy,$c) }} } }
    $p = Join-Path $OutDir $Name
    $bmp.Save($p,[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Write-Host ("   wrote {0}  ({1} x {2})" -f $Name, ($ScreenW*$Zoom), ($DH*$Zoom))
}

function Blank-Regions { param([byte[]]$Idx)
    for ($i=0; $i -lt $ScreenW*$DH; $i++) { if ($mag[$i]) { $Idx[$i] = 0 } }
    return $Idx
}

Write-Host ""
# map from $dst (the real pixels, ring included) -- $vote exists only to pick colours
$flat = Blank-Regions ([LeTool.Quant]::Map($dst,$ScreenW,$DH,$pal,$Colours,1,0))
Save-Preview $flat 'skin-preview-flat-1x.png' 1
Save-Preview $flat 'skin-preview-flat-2x.png' 2
$dith = Blank-Regions ([LeTool.Quant]::Map($dst,$ScreenW,$DH,$pal,$Colours,1,1))
Save-Preview $dith 'skin-preview-dither-1x.png' 1
Save-Preview $dith 'skin-preview-dither-2x.png' 2
