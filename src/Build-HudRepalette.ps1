# Build-HudRepalette.ps1 -- re-point every OTHER 2D asset onto the reskin palette.
#
# WHY THIS EXISTS. The whole game runs on one 256-entry palette that HUD3.PCX
# carries, so rewriting indices 1..53 for the new panel silently recolours every
# other asset that indexes them -- and 72 of the game's 125 PCX files do. The
# system menu was the visible casualty: SAVE*.PCX are the fold-out panels, and
# they draw 40% of their pixels from 1..53. Also affected: INVBACK2.PCX (the
# inventory backing) and the GENGRN / GENYEL font strips.
#
# The fix is the standard one for a shared-palette game: leave the palette alone
# and re-point the ART. For each affected file, every pixel in 1..53 is remapped
# to the perceptually nearest colour in the new 53. Measured error over the whole
# old range is min 2.1, median 9.4, max 22.8 -- a slight shift toward brass, not
# a corruption.
#
# WHAT IS DELIBERATELY SKIPPED:
#   * anything we already generate (HUD3, HUDOFF, MAPBKGRD, NBUT*, the fonts)
#   * anything that uses indices >= 128 in quantity. Those either carry their own
#     palette and upload it (TITLE.PCX, the whole ORRPUZ set) or are character
#     art living in pal.pcx's range, and neither should be touched.
[CmdletBinding()]
param(
    [string]$GameDir = '',      # '' = the stock game this repo sits in: <Steam>\Azrael's Tear\GAME\AZRAEL
    [string]$ArtDir  = "$PSScriptRoot\..\art",
    [string]$OldHud  = "$PSScriptRoot\..\art-backup-preskin\HUD3.PCX",
    [double]$HighMax = 0.10
)
if (-not $GameDir) { $GameDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'GAME\AZRAEL' }      # (in the body: $PSScriptRoot is empty in param() under -File)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies "System.Drawing"

$newPal = ([LeTool.Pcx]::Load((Join-Path $ArtDir 'HUD3.PCX'))).Palette
$oldPal = ([LeTool.Pcx]::Load($OldHud)).Palette
$PAL_LO = 1; $PAL_HI = 53

# old index -> nearest new index, computed once
$map = New-Object 'int[]' 256
for ($i=0; $i -lt 256; $i++) { $map[$i] = $i }
for ($i=$PAL_LO; $i -le $PAL_HI; $i++) {
    $r=$oldPal[$i*3]; $g=$oldPal[$i*3+1]; $b=$oldPal[$i*3+2]
    $best=$i; $bd=[double]::MaxValue
    for ($k=$PAL_LO; $k -le $PAL_HI; $k++) {
        $dr=$newPal[$k*3]-$r; $dg=$newPal[$k*3+1]-$g; $db=$newPal[$k*3+2]-$b
        $d = $dr*$dr*0.299 + $dg*$dg*0.587 + $db*$db*0.114
        if ($d -lt $bd) { $bd=$d; $best=$k }
    }
    $map[$i] = $best
}

$skip = @('HUD3.PCX','HUDOFF.PCX','MAPBKGRD.PCX','GENBLU2.PCX','RUSGLD2.PCX',
          'NBUT0OFF.PCX','NBUT0ON.PCX','NBUT1OFF.PCX','NBUT1ON.PCX','NBUT2OFF.PCX','NBUT2ON.PCX',
          # NOT ARTWORK. These are the palette SOURCES: pal.pcx supplies live
          # indices 128..255 and h1.pcx supplies 58..71 (see the loader at
          # 0x28524 / 0x2843D). Re-pointing their pixels is meaningless and
          # rewriting their palettes destroys the character colours and the
          # status-gauge ramp. palette.pcx is the artists' reference copy.
          'PAL.PCX','H1.PCX','PALETTE.PCX')

# Loaded by code that calls SetWholePalette, so their indices mean something
# else entirely. TITLE.PCX is also caught by the 128..255 test.
$SELF_PAL = @('TITLE.PCX','BACKDROP.PCX','MISTRAL.PCX','NEWLOGO.PCX')

$done = 0; $skipped = @(); $subdir = @()
foreach ($f in (Get-ChildItem $GameDir -Recurse -Filter '*.PCX')) {
    if ($skip -contains $f.Name) { continue }
    try { $p = [LeTool.Pcx]::Load($f.FullName) } catch { continue }

    $hist = New-Object 'int[]' 256
    foreach ($b in $p.Pixels) { $hist[$b]++ }
    $low = 0; for ($i=$PAL_LO; $i -le $PAL_HI; $i++) { $low += $hist[$i] }
    if ($low -eq 0) { continue }
    $high = 0; for ($i=128; $i -lt 256; $i++) { $high += $hist[$i] }
    if (($high / [double]$p.Pixels.Length) -gt $HighMax) {
        $skipped += ("{0} ({1:P0} in 128..255)" -f $f.Name, ($high/$p.Pixels.Length)); continue
    }
    # A PCX's EMBEDDED PALETTE IS NOT EVIDENCE. An earlier version of this script
    # skipped any file whose own palette differed from the game's, and that threw
    # away the font strips and two cursors -- those carry junk palettes (RUSBLU2's
    # only ink is index 53 = #080000) but are drawn through the CURRENT palette,
    # so they need re-pointing more than anything else does.
    #
    # The files that genuinely upload a palette are known from the code, not
    # guessed: 0x1FBC2 loads backdrop.pcx / mistral.pcx / newlogo.pcx and calls
    # SetWholePalette, title.pcx does the same, and the orrpuz set is caught by
    # the 128..255 test above.
    if ($SELF_PAL -contains $f.Name) { $skipped += ("{0} (uploads its own palette)" -f $f.Name); continue }
    # Subfolder assets (mice\ cursors) are loaded by relative path, so they are
    # mirrored into art\MICE\ and the installer copies art\ recursively.
    $rel = $f.FullName.Substring($GameDir.Length).TrimStart('\')
    $out = Join-Path $ArtDir $rel
    if ($rel -ne $f.Name) {
        $subdir += $rel
        New-Item -ItemType Directory -Force (Split-Path $out -Parent) | Out-Null
    }

    for ($i=0; $i -lt $p.Pixels.Length; $i++) {
        $v = $p.Pixels[$i]
        if ($v -ge $PAL_LO -and $v -le $PAL_HI) { $p.Pixels[$i] = [byte]$map[$v] }
    }
    # DO NOT touch the embedded palette. The game ignores it for shared-palette
    # art, and for anything that uploads its own (the intro and credits stills)
    # rewriting it would be destructive. Only the pixel indices move.
    $p.SavePcx($out)
    $done++
}

Write-Host ("re-pointed {0} assets onto the new palette" -f $done)
if ($skipped.Count) { Write-Host ("skipped (own palette / character art): {0}" -f ($skipped -join ', ')) }
if ($subdir.Count)  { Write-Host ("mirrored into subfolders: {0}" -f ($subdir -join ', ')) }


