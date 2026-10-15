# Generates rescaled HUD backgrounds so the instrument panel takes up less of
# the screen and the 3D viewport can grow downward into the space it frees.
#
#   .\Build-HudArt.ps1 -Scale 0.30 -OutDir ..\art
#
# The stock panel occupies y 318..479 of a 640x480 background (measured, not
# guessed -- see Measure below). It is scaled by -Scale, centred horizontally and
# pushed to the bottom of the screen. Everything the panel used to occupy becomes
# background colour, which the enlarged viewport then covers.
#
# The strip above the viewport (y 0..48) is left ALONE: it carries the compass
# and other live HUD elements, and covering it makes them flicker as the view
# blit overwrites them every frame.

[CmdletBinding()]
param(
    [double]$Scale  = 0.30,
    [string]$GameDir = "$PSScriptRoot\..\..\GAME\AZRAEL",
    [string]$OutDir  = "$PSScriptRoot\..\art",
    # The game's CD image. The map screen's backdrop lives on the disc, not in
    # GAME\AZRAEL -- see the MAPBKGRD section at the bottom.
    [string]$CdImage = "$PSScriptRoot\..\..\AZT.BIN",
    # Output resolution. The stock art is 640x480; 800x600 is the same 4:3 design
    # at a uniform 1.25, which is exactly how Build-AztMod.ps1 scales the
    # coordinates. The two MUST agree or the art and the hit tests part company.
    [int]$ScreenW = 640,
    [int]$ScreenH = 480
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ("LeTool.Pcx" -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies "System.Drawing"
}

$PANEL_TOP = 318          # first row of instrument-panel artwork
$SCREEN_H  = 480
$TOP_KEEP  = 49           # rows reserved for the compass strip

# --- ISO9660 reader ----------------------------------------------------------
# Just enough to pull one file out of the game's CD image. AZT.CUE declares
# MODE1/2352, i.e. raw sectors: 16 bytes of sync+header, 2048 bytes of user
# data, then EDC/ECC. Only the user data is ISO9660.
function Read-IsoFile([string]$bin, [string]$dirPath, [string]$fileName) {
    $RAW = 2352; $HDR = 16; $USER = 2048
    $fs = [System.IO.File]::OpenRead((Resolve-Path $bin).Path)
    try {
        $sector = {
            param([int]$lba)
            $b = New-Object byte[] $USER
            $fs.Seek([long]$lba * $RAW + $HDR, 'Begin') | Out-Null
            $fs.Read($b, 0, $USER) | Out-Null
            $b
        }
        $extent = {
            param([int]$lba, [int]$len)
            $o = New-Object byte[] $len; $n = 0
            while ($n -lt $len) {
                $s = & $sector ($lba + [int]($n / $USER))
                $take = [Math]::Min($USER, $len - $n)
                [Array]::Copy($s, 0, $o, $n, $take); $n += $take
            }
            $o
        }
        # Directory records are packed back to back but never straddle a logical
        # block; a zero length byte means "skip to the next block".
        $entries = {
            param([byte[]]$d)
            $r = @(); $p = 0
            while ($p -lt $d.Length) {
                $len = $d[$p]
                if ($len -eq 0) {
                    $p = ([int]($p / $USER) + 1) * $USER
                    if ($p -ge $d.Length) { break }
                    continue
                }
                $nlen = $d[$p + 32]
                $r += [pscustomobject]@{
                    Name  = [System.Text.Encoding]::ASCII.GetString($d, $p + 33, $nlen)
                    Lba   = [BitConverter]::ToInt32($d, $p + 2)
                    Size  = [BitConverter]::ToInt32($d, $p + 10)
                    IsDir = [bool]($d[$p + 25] -band 2)
                }
                $p += $len
            }
            $r
        }
        $pvd = & $sector 16
        $cur = & $entries (& $extent ([BitConverter]::ToInt32($pvd, 156+2)) ([BitConverter]::ToInt32($pvd, 156+10)))
        foreach ($part in ($dirPath -split '\\' | Where-Object { $_ })) {
            $d = $cur | Where-Object { $_.IsDir -and $_.Name -eq $part }
            if (-not $d) { throw "no directory '$part' in '$dirPath' on the disc image" }
            $cur = & $entries (& $extent $d.Lba $d.Size)
        }
        # ISO9660 names carry a ";1" version suffix.
        $f = $cur | Where-Object { -not $_.IsDir -and ($_.Name -replace ';\d+$','') -eq $fileName } | Select-Object -First 1
        if (-not $f) { throw "no file '$fileName' in '$dirPath' on the disc image" }
        return (& $extent $f.Lba $f.Size)
    } finally { $fs.Close() }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $OutDir | Out-Null

# THE LAYOUT IS DESIGNED IN 640x480 AND SCALED BY ONE FACTOR. 800x600 is the same
# 4:3 design at 1.25, which is exactly what Build-AztMod.ps1 does to every
# coordinate, so the art and the hit tests stay registered.
$HS = $ScreenW / 640.0
# A NON-4:3 SCREEN IS TOLERABLE HERE, and it used to throw. Everything below scales
# art by $HS (width-derived) and places the panel at `$ScreenH - $newPanelH`, which
# is panel-relative and agrees with Build-AztMod.ps1's own $PANEL_TOP_NEW at any
# aspect -- at 1280x1024 both land on 846. The only consequence of 5:4 is that the
# sprites carry the horizontal scale while the screen is taller than that by the
# aspect difference, so the panel band is proportionally shorter. Nothing comes
# unregistered, because the hit tests are scaled by the same $HS.
if ([Math]::Abs($ScreenH / 480.0 - $HS) -gt 0.001) {
    Write-Host ("  WARNING: {0}x{1} is not 4:3; art scales x{2:N3} while the screen is x{3:N3} tall -- panel band is {4:P1} shorter in proportion" -f `
        $ScreenW, $ScreenH, $HS, ($ScreenH / 480.0), (1.0 - $HS / ($ScreenH / 480.0)))
}
$scaleEff  = $Scale * $HS          # panel: shrunk by -Scale, then grown by the screen
$topKeep   = [int][Math]::Round($TOP_KEEP * $HS)

$panelH    = $SCREEN_H - $PANEL_TOP                   # 162, in design space
$newPanelH = [int][Math]::Round($panelH * $scaleEff)
$newPanelW = [int][Math]::Round(640 * $scaleEff)
$newTop    = $ScreenH - $newPanelH
$newLeft   = [int](($ScreenW - $newPanelW) / 2)

Write-Host ("screen {0}x{1} (scale {2:N2})" -f $ScreenW, $ScreenH, $HS)
Write-Host ("panel {0}x{1} at y={2}  ->  {3}x{4} at ({5},{6})" -f `
    640, $panelH, $PANEL_TOP, $newPanelW, $newPanelH, $newLeft, $newTop)
Write-Host ("viewport can now run y {0}..{1}  (height {2})" -f $topKeep, ($newTop-1), ($newTop - $topKeep))

foreach ($name in @('HUD3','HUDOFF')) {
    $srcPath = Join-Path $GameDir "$name.PCX"
    $src = [LeTool.Pcx]::Load((Resolve-Path $srcPath).Path)

    # A fresh canvas at the target size, carrying the source palette. (At 640x480
    # this is the same size as the source, so nothing is resampled that was not
    # being resampled before.)
    $bg = $src.Pixels[0]                              # the outer border colour
    $dst = New-Object LeTool.Pcx
    $dst.Width = $ScreenW; $dst.Height = $ScreenH
    $dst.Pixels = New-Object byte[] ($ScreenW * $ScreenH)
    $dst.Palette = $src.Palette
    $dst.FillRect(0, 0, $ScreenW, $ScreenH, $bg)

    # The compass strip (y 0..48) carries live HUD elements and must survive; it
    # scales with everything else rather than being left at its stock size.
    $dst.BlitScaledSmooth($src, 0, 0, 640, $TOP_KEEP, 0, 0, $ScreenW, $topKeep, $bg)

    # The instrument panel.
    $dst.BlitScaledSmooth($src, 0, $PANEL_TOP, 640, $panelH, $newLeft, $newTop, $newPanelW, $newPanelH, $bg)

    # The notes/inventory housing is NOT shrunk with the panel. Shrinking it cost
    # legibility (the note list inside does not scale), relocating the bare window
    # left it floating with no bezel, and its up/down buttons scaled away from the
    # thing they scroll. So the whole cluster moves together at screen scale:
    # bezel, window recess and both buttons.
    #
    # Build-AztMod.ps1 derives the SAME region and destination and moves the hot
    # spots to match. The two must agree or the window draws where you cannot
    # click. THE DELTA IS THE INVARIANT: +62 in design space puts the housing over
    # the panel's own shrunken copy of this same lens, which is why the inventory
    # used to appear twice.
    $invDx = 62
    # The lens artwork starts around x=38-48 depending on the row, so cutting at 50
    # sliced through it. 28 takes the whole lens plus a little dark border.
    $invSrcX = 28; $invSrcR = 197; $invSrcY = 340
    $cx0 = 70; $cx1 = 193; $cy1 = 413                      # window + buttons
    $invW = $invSrcR - $invSrcX + 1
    if ($cx0 -lt $invSrcX -or $cx1 -gt $invSrcR -or $cy1 -ge $invSrcY + $panelH) {
        throw "inventory housing source region does not contain the window and buttons"
    }
    $invDstX = [int][Math]::Round(($invSrcX + $invDx) * $HS)
    $invWDst = [int][Math]::Round($invW * $HS)
    if ($invDstX + $invWDst -gt [int][Math]::Round(261 * $HS)) {
        throw "housing at x=$invDstX would cover the panel controls at 261"
    }
    if ($invDstX -lt 0) { throw "housing would start off the left edge" }
    $dst.BlitScaledSmooth($src, $invSrcX, $invSrcY, $invW, $panelH, $invDstX, $newTop, $invWDst, $newPanelH, $bg)
    if ($name -eq 'HUD3') {
        Write-Host ("  inventory housing {0}x{1} from ({2},{3}) -> {4}x{5} at ({6},{7})" -f `
            $invW, $panelH, $invSrcX, $invSrcY, $invWDst, $newPanelH, $invDstX, $newTop)
    }

    $out = Join-Path $OutDir "$name.PCX"
    $dst.SavePcx($out)
    Write-Host ("  wrote {0}  ({1:N0} bytes)" -f $out, (Get-Item $out).Length)
}

# The three contextual panel buttons. nbut0/1/2 each have an "off" and an "on"
# image; the game blits the "on" one over the panel when the button lights up, at
# a FIXED anchor held in static data (0x147488 / 0x14748E = 235,343). They sit on
# the panel, so they have to shrink with it -- otherwise the highlight is roughly
# twice the size of the button it is highlighting.
#
# Build-AztMod.ps1 patches the matching surface dimensions and pixel-buffer sizes
# at 0x2D1E4, and moves the anchor. Those must agree with the sizes written here.
foreach ($name in @('NBUT0OFF','NBUT0ON','NBUT1OFF','NBUT1ON','NBUT2OFF','NBUT2ON')) {
    $srcPath = Join-Path $GameDir "$name.PCX"
    if (-not (Test-Path $srcPath)) { Write-Host "  (missing $name.PCX)"; continue }
    $src = [LeTool.Pcx]::Load((Resolve-Path $srcPath).Path)
    $nw = [int][Math]::Round($src.Width  * $scaleEff)
    $nh = [int][Math]::Round($src.Height * $scaleEff)
    $dst = New-Object LeTool.Pcx
    $dst.Width = $nw; $dst.Height = $nh
    $dst.Pixels = New-Object byte[] ($nw * $nh)
    $dst.Palette = $src.Palette
    # pixel 0 is the keyed/transparent colour in these sprites
    $dst.FillRect(0, 0, $nw, $nh, $src.Pixels[0])
    $dst.BlitScaledSmooth($src, 0, 0, $src.Width, $src.Height, 0, 0, $nw, $nh, $src.Pixels[0])
    $out = Join-Path $OutDir "$name.PCX"
    $dst.SavePcx($out)
    Write-Host ("  {0,-9} {1}x{2} -> {3}x{4}  (buffer {5})" -f $name, $src.Width, $src.Height, $nw, $nh, ($nw*$nh))
}

# MAPBKGRD.PCX -- the map screen's backdrop.
#
# The map screen is not a HUD overlay: it loads this full-screen 640x480 image
# into the shared offscreen page (surface 0x1525E0 takes its pixels from
# [0x147244] at 0x12A4D) and then draws the map on top. The "darkened UI"
# players see under the map is not a runtime blit of HUDOFF at all -- Mindscape
# BAKED a dimmed copy of the full-size instrument panel into the bottom of this
# image. It is art, which is why no code patch could have moved it.
#
# AND IT LIVES ON THE CD, NOT IN GAME\AZRAEL.
#
# The load at 0x1ECA6 formats "%smaps\mapbkgrd.pcx" with the first line of
# RESOURCE.CFG, which is "D:\TEXTURES\", so the real path is
# D:\TEXTURES\MAPS\MAPBKGRD.PCX inside AZT.BIN. There IS a MAPBKGRD.PCX sitting
# in GAME\AZRAEL, but the game never reads it and it is not even the same
# picture -- its palette differs from the disc's in 744 of 768 bytes.
#
# That palette is the whole reason this has to come off the disc: the disc copy
# shares its palette EXACTLY (0 of 768 bytes differ) with the individual map
# images like AQUADUCT.PCX, so substituting the local variant would recolour
# every map in the game.
#
# Build-AztMod.ps1 shortens the format string to plain "mapbkgrd.pcx" so the
# game loads it from the working directory (C:\AZRAEL) instead, which is where
# the file written here is installed. The two changes only work together.
$map = $null
if (Test-Path $CdImage) {
    try {
        $map = [LeTool.Pcx]::FromBytes((Read-IsoFile $CdImage 'TEXTURES\MAPS' 'MAPBKGRD.PCX'))
    } catch {
        Write-Host "  (could not read MAPBKGRD.PCX from $CdImage -- $_)"
    }
} else {
    Write-Host "  (no CD image at $CdImage)"
}
if (-not $map) {
    throw "cannot build the map backdrop without the game's CD image (AZT.BIN); pass -CdImage"
}

# Find the band to wipe rather than hard-coding 318. Scan up from the bottom for
# the first row that is essentially pure black; everything below it is panel.
# On the disc image this lands at 321, one row above where the panel's luminance
# jumps from 0 to 23.
$lum = New-Object int[] 256
for ($i = 0; $i -lt 256; $i++) {
    $lum[$i] = [int](0.3*$map.Palette[$i*3] + 0.59*$map.Palette[$i*3+1] + 0.11*$map.Palette[$i*3+2])
}
$panelTop = $map.Height
for ($y = $map.Height - 1; $y -ge 0; $y--) {
    $m = 0
    for ($x = 0; $x -lt $map.Width; $x++) {
        $v = $lum[$map.Pixels[$y*$map.Width + $x]]
        if ($v -gt $m) { $m = $v }
    }
    if ($m -le 2) { break }     # pure-black row: the panel's glow has ended
    $panelTop = $y
}
if ($panelTop -ge $map.Height) {
    throw "MAPBKGRD.PCX has no panel band to wipe -- the disc image is not what this expects"
}
if ($panelTop -lt $PANEL_TOP - 40) {
    # Sanity: the baked panel should start near y=318. Much higher than that and
    # the scan has run into real map artwork, so refuse rather than destroy it.
    throw "MAPBKGRD panel band starts at y=$panelTop, far above the expected $PANEL_TOP -- refusing to wipe map artwork"
}
$black = $map.Pixels[0]      # top-left corner: the image's own black
$map.FillRect(0, $panelTop, $map.Width, $map.Height - $panelTop, $black)

# The map backdrop STAYS 640x480 at every resolution (Josh, 2026-10-14: the old maps showed "corrupted" since the
# move to 1600x1200). The map screen composes into a 640x480 surface (0x12954 creates 0x1525E0 at 0x280 x 0x1E0) and
# MAPS.DAT places every piece in 640x480 coordinates, so a backdrop resized to the screen no longer fit its surface:
# its rows ran at the wrong pitch. The composed map is now drawn at its own size, centred in the view (Build-AztMod
# AztMapBlit), or not at all when the host draws the 3D map.
$out = Join-Path $OutDir 'MAPBKGRD.PCX'
$map.SavePcx($out)
Write-Host ("  MAPBKGRD  from disc, wiped baked HUD rows {0}..{1} -> index {2}  ({3:N0} bytes)" -f `
    $panelTop, ($map.Height-1), $black, (Get-Item $out).Length)

Write-Host ""
Write-Host ("Set `$VIEW_Y = {0} and `$VIEW_H = {1} in Build-AztMod.ps1" -f $TOP_KEEP, ($newTop - $TOP_KEEP))

