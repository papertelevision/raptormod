# Build-TexturePrompt.ps1 -- write the image-model brief for a room, from measurements.
#
#   .\tools\Build-TexturePrompt.ps1 -Res CORICORI -Out C:\Games\RaptorMod\textures\room01\PROMPT.txt
#
# The first version of this brief was written from adjectives ("dark and desaturated, mossy
# stone") and the model returned warm sandstone for surfaces that are cool grey-green in the
# original. Adjectives are the weakest link in the chain, because at -Blend 1.0 every hue in
# the finished texture came from the model and none of it came from the game.
#
# So everything quotable here is measured instead:
#
#   HEX per texture     from Measure-TexturePalette, lit pixels only
#   VISIBLE WINDOW      from the .XAF's texture_coordinates -- most of these textures are
#                       sampled over a SUB-RECTANGLE, so most of the model's image is never
#                       seen and its composition has to survive being cropped to that window
#   TEXEL BUDGET        the art box at the output scale; the real legibility limit
#   CANVAS              aspect-matched to the record, because the tool stretches the source
#                       over the whole record and a square source on a 2:1 record squashes
#                       every feature by half
#
# Textures are grouped into MATERIAL FAMILIES by hue, because the measurement showed the
# room is four materials rather than twenty independent images, and a family has to be
# generated as a set or the floor looks patchworked.

[CmdletBinding()]
param(
    [string]$Res = 'CORICORI',
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    [int]$Scale = 2,
    [double]$Soften = 0.35,
    [Parameter(Mandatory)][string]$Out
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
$stem = $Res -replace '\.(RES|XAF)$',''

# ---- measurements ------------------------------------------------------------
& (Join-Path $toolDir 'Measure-TexturePalette.ps1') -Res $stem -TexDir $TexDir -Scale $Scale | Out-Null
$csv = Join-Path $env:TEMP "$stem-palette.csv"
if (-not (Test-Path $csv)) { throw "Measure-TexturePalette produced no csv" }
$rows = @(Import-Csv $csv)

# ---- UV windows from the .XAF ------------------------------------------------
$xafPath = Join-Path $TexDir "$stem.XAF"
$xaf = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($xafPath))
$matTex = @{}
foreach ($m in [regex]::Matches($xaf, 'material\s+"([^"]+)"\s*\{([^}]*)\}', 'IgnoreCase')) {
    $t = [regex]::Match($m.Groups[2].Value, 'texture\s+"([^"]+)"')
    if ($t.Success) { $matTex[$m.Groups[1].Value] = ((($t.Groups[1].Value -split '[\\/]')[-1]) -replace '\.(azf|gif)$','') }
}
$uv = @{}
$objs = @([regex]::Matches($xaf, 'object\s+"([^"]+)"\s*\{', 'IgnoreCase'))
for ($k = 0; $k -lt $objs.Count; $k++) {
    $a = $objs[$k].Index
    $b = if ($k+1 -lt $objs.Count) { $objs[$k+1].Index } else { $xaf.Length }
    $body = $xaf.Substring($a, $b - $a)
    $mm = [regex]::Match($body, 'material\s+"([^"]+)"')
    if (-not $mm.Success -or -not $matTex.ContainsKey($mm.Groups[1].Value)) { continue }
    $tex = $matTex[$mm.Groups[1].Value]
    $tc = [regex]::Match($body, 'texture_coordinates\s*\{([^}]*)\}')
    if (-not $tc.Success) { continue }
    $nums = @([regex]::Matches($tc.Groups[1].Value, '-?\d+(?:\.\d+)?(?:e-?\d+)?') | ForEach-Object { [double]$_.Value })
    $us = @(); $vs = @()
    for ($i = 0; $i -lt $nums.Count - 1; $i += 2) { $us += $nums[$i]; $vs += $nums[$i+1] }
    if (-not $us.Count) { continue }
    $u0 = ($us | Measure-Object -Minimum).Minimum; $u1 = ($us | Measure-Object -Maximum).Maximum
    $v0 = ($vs | Measure-Object -Minimum).Minimum; $v1 = ($vs | Measure-Object -Maximum).Maximum
    if (-not $uv.ContainsKey($tex)) { $uv[$tex] = [pscustomobject]@{ U0=$u0; U1=$u1; V0=$v0; V1=$v1 } }
    else { $r = $uv[$tex]
        if ($u0 -lt $r.U0) { $r.U0 = $u0 }; if ($u1 -gt $r.U1) { $r.U1 = $u1 }
        if ($v0 -lt $r.V0) { $r.V0 = $v0 }; if ($v1 -gt $r.V1) { $r.V1 = $v1 } }
}

# ---- material families, by hue of the dominant colour ------------------------
function HueFamily {
    param([string]$hexList, [int]$satMax)
    $h = ($hexList -split ' ')[0]
    $r = [Convert]::ToInt32($h.Substring(1,2),16); $g = [Convert]::ToInt32($h.Substring(3,2),16); $b = [Convert]::ToInt32($h.Substring(5,2),16)
    # warm = red clearly dominant; cool-green = green at or above red; neutral otherwise
    if ($satMax -ge 60 -and $r -gt $b + 8) { return 'WARM' }
    if ($g -ge $r -and $g -ge $b) { return 'COOLGREEN' }
    if ($r -gt $b + 4) { return 'NEUTRALWARM' }
    return 'NEUTRAL'
}

$subjects = @{
    'r12r5'   = 'weathered stone wall panel';        'corirock'  = 'rough natural rock face, damp'
    'vstpap01'= 'aged parchment pinned to stone';    'all2cori'  = 'corridor transition wall, mossy stone'
    'cor2wash'= 'corridor transition wall, wet stone';'ecrflr05' = 'stone floor slab, entrance'
    'ecrflra4'= 'stone floor slab, variant';         'ecrflra3'  = 'stone floor slab, variant'
    'ecrflra2'= 'stone floor slab, variant';         'ecrflra1'  = 'stone floor slab, variant'
    'ecrhole' = 'dark opening / hole in stone';      'or_tunnl'  = 'rough tunnel mouth'
    'ecrdor02'= 'large ornate door';                 'ecrflr04'  = 'stone floor slab, variant'
    'ecrflr03'= 'stone floor slab, variant';         'ecrflr02'  = 'stone floor slab, variant'
    'ecrflr01'= 'stone floor slab, main';            'ecrlwl01'  = 'corridor wall, left of the door'
    'ecrrwl01'= 'corridor wall, right of the door';  'ecrdor01'  = 'smaller door'
}

# Materials that are their own thing and must not be averaged into a family's shared
# palette. vstpap01 is bright cream parchment at 99% saturation: the hue test puts it with
# the brown stone, which would drag that family's shared palette toward tan and hand the
# model a washed-out wall colour. corirock falls out on its own already.
$loners = @('vstpap01')

# Borderline cases the hue test gets wrong by a hair. ecrhole's dominant #272623 misses the
# warm test by exactly one unit (r=39, b=35, needs r>b+4) yet its palette is the door
# family's almost entry for entry -- it is the opening in that same wall. Pinning it is
# honest; loosening the threshold to catch it would drag real neutrals in with it.
$famOverride = @{ 'ecrhole' = 'NEUTRALWARM' }

foreach ($r in $rows) {
    $fam = if ($famOverride.ContainsKey($r.Name)) { $famOverride[$r.Name] }
           elseif ($loners -contains $r.Name)     { 'NEUTRAL' }
           else                                   { HueFamily $r.Hex ([int]$r.SatMaxPct) }
    $r | Add-Member -NotePropertyName Family -NotePropertyValue $fam -Force
    $r | Add-Member -NotePropertyName Subject -NotePropertyValue $(if ($subjects.ContainsKey($r.Name)) { $subjects[$r.Name] } else { 'stone surface' }) -Force
    # canvas aspect-matched to the record, long side 1024
    $rw = [int]$r.RecW; $rh = [int]$r.RecH
    if ($rw -ge $rh) { $cw = 1024; $ch = [int](1024.0 * $rh / $rw) } else { $ch = 1024; $cw = [int](1024.0 * $rw / $rh) }
    $r | Add-Member -NotePropertyName CanvasW -NotePropertyValue $cw -Force
    $r | Add-Member -NotePropertyName CanvasH -NotePropertyValue $ch -Force
    if ($uv.ContainsKey($r.Name)) {
        $u = $uv[$r.Name]
        $r | Add-Member -NotePropertyName Win -NotePropertyValue ("{0:N0}-{1:N0}% x {2:N0}-{3:N0}%" -f ($u.U0*100),($u.U1*100),($u.V0*100),($u.V1*100)) -Force
        $r | Add-Member -NotePropertyName WinFull -NotePropertyValue ($u.U0 -le 0.02 -and $u.U1 -ge 0.98 -and $u.V0 -le 0.02 -and $u.V1 -ge 0.98) -Force
        $visFrac = [Math]::Max(0.05, $u.U1 - $u.U0)
    } else {
        $r | Add-Member -NotePropertyName Win -NotePropertyValue 'unknown' -Force
        $r | Add-Member -NotePropertyName WinFull -NotePropertyValue $false -Force
        $visFrac = 1.0
    }
    # TWO numbers, because one of them alone misleads.
    #
    # The hard floor is what 4 output texels works out to on the model's canvas -- but for
    # these windows that is under 1%, and quoting it alone reads as PERMISSION for fine
    # detail, which is the opposite of what is wanted. So it is given in pixels, as a
    # vanishing threshold, and the headline number is a TARGET:
    #
    #   aim for about MAJOR_FORMS shapes across the visible window
    #
    # which is what actually produces legible artwork at this size.
    $MAJOR_FORMS = 6
    $r | Add-Member -NotePropertyName MinFeatPx -NotePropertyValue ([int][Math]::Ceiling(4.0 * $visFrac * $r.CanvasW / [Math]::Max(1,[int]$r.ArtW))) -Force
    $r | Add-Member -NotePropertyName TargetPct -NotePropertyValue ([Math]::Round(100.0 * $visFrac / $MAJOR_FORMS, 1)) -Force
    $r | Add-Member -NotePropertyName TargetPx  -NotePropertyValue ([int]($r.CanvasW * $visFrac / $MAJOR_FORMS)) -Force
    $r | Add-Member -NotePropertyName FormTexels -NotePropertyValue ([int]([int]$r.ArtW / $MAJOR_FORMS)) -Force
}

$famOrder = @('COOLGREEN','WARM','NEUTRALWARM','NEUTRAL')
$famTitle = @{
    'COOLGREEN'   = 'FAMILY A -- COOL GREY-GREEN STONE  (the floor)'
    'WARM'        = 'FAMILY B -- WARM BROWN STONE  (the big wall and tunnel surfaces)'
    'NEUTRALWARM' = 'FAMILY C -- NEUTRAL WARM-GREY STONE  (the doors and their surround)'
    'NEUTRAL'     = 'FAMILY D -- ODD ONES OUT  (generate these individually)'
}

# ---- write the brief ---------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
function W { param([string]$s = '') [void]$sb.AppendLine($s) }

$allHex = @()
foreach ($r in $rows) { $allHex += ($r.Hex -split ' ') }
$satCeil = ($rows | Measure-Object -Property SatMaxPct -Maximum).Maximum

W "AZRAEL'S TEAR -- ROOM 1 TEXTURE REMASTER  (brief v3, generated from measurements)"
W ("=" * 79)
W ""
W ("Generated {0} from {1}.RES.orig and {1}.XAF. Output settings these numbers assume:" -f (Get-Date -Format 'yyyy-MM-dd'), $stem)
W ("    -Scale {0}  -Blend 1.0  -Smooth 0  -Soften {1}" -f $Scale, $Soften)
W ""
W "WHAT CHANGED FROM THE LAST BRIEF, AND WHY"
W "-----------------------------------------"
W ""
W "1. COLOUR IS NOW SPECIFIED IN HEX, PER TEXTURE. The pipeline takes LIGHTING from the"
W "   1996 original and COLOUR entirely from the new art, so every hue in the finished"
W "   texture is the model's choice. 'Dark and desaturated' was too loose: it returned warm"
W "   sandstone for surfaces that are measurably cool grey-green."
W ""
W "2. THE ROOM IS FOUR MATERIALS, NOT TWENTY IMAGES. Measuring the dominant hues grouped"
W "   the textures into families that share a palette. Generate a family as a SET, in one"
W "   conversation, so its members match each other."
W ""
W "3. THE ARTWORK MUST BE SIMPLER. Each texture below quotes the number of output texels"
W "   its visible area actually gets. These are small -- the corridor walls get about 95"
W "   texels across -- and the result is reduced to 256 colours. Fine speckle, gravel,"
W "   lichen dots and photographic grain do not become detail at this size; they become"
W "   noise. In the originals, SIX colours describe 76-100% of the entire lit surface."
W ""
W ""
W "THE HARD RULES"
W "--------------"
W ""
W "A. FLAT, FULL-BLEED MATERIAL. Fill the whole canvas with the material, edge to edge."
W "   Do NOT paint shadows, vignettes, dark borders, ambient occlusion or any lighting."
W "   The original's own hand-painted shadow is re-applied afterwards by the toolchain and"
W "   it is the thing that gives this game its mood -- if you also paint shadow, it gets"
W "   applied twice and the surface goes black."
W ""
W "B. EVEN BRIGHTNESS. Absolute brightness is normalised away by the relighting step, so"
W "   do not try to match how dark the original looks. Aim for an even MID-TONE across the"
W "   whole canvas. What must match is HUE and SATURATION, not lightness."
W ""
W "C. USE ONLY THE LISTED COLOURS. Treat each texture's hex list as the complete palette."
W "   Blends between those colours are fine. A hue that is not in the list -- any blue,"
W "   any warm orange in a grey-green surface, any green in a brown one -- is wrong."
W ("   Saturation stays low: no dominant colour in this room exceeds {0}%, and the floor" -f $satCeil)
W "   family stays under 31%."
W ""
W "D. NO MORE THAN 8 DISTINCT TONES, and keep them close together. The originals average"
W "   six. This is the single biggest lever on whether the result reads as stone or as mud."
W ""
W "E. LARGE, SIMPLE FORMS. Each entry gives a TARGET SCALE: roughly six major forms across"
W "   the part of the image that is actually visible. For a stone wall that means about six"
W "   courses of block, not thirty. Favour a few big shapes with clean boundaries over many"
W "   small ones. No fine noise, no dense speckle, no photographic grain, no hairline"
W "   cracks, no scattered pebbles. Each entry also gives a vanishing point in pixels --"
W "   detail below it is not merely lost, it turns into dither noise and makes the surface"
W "   look worse than leaving it alone."
W ""
W "F. SEAMLESS TILING on all four edges. These surfaces repeat. Check by offsetting the"
W "   image 50% in both directions and looking at the middle."
W ""
W "G. EXACT CANVAS SIZE as given. The canvas is aspect-matched to the game's record: a"
W "   square image on a 2:1 record gets squashed to half height and every feature with it."
W ""
W "H. FILENAMES EXACTLY AS LISTED, number prefix included. The game's .RES has no names"
W "   or index of its own -- the number is the only thing tying an image back to its slot."
W ""
W ""
W "ABOUT THE 'VISIBLE WINDOW' COLUMN"
W "---------------------------------"
W ""
W "Most of these textures are not tiled over a whole surface. Their UVs sample a"
W "SUB-RECTANGLE of the image and the rest is never drawn. The window is given as a"
W "percentage of the canvas. Two consequences:"
W ""
W "  * Composition outside the window is invisible, so do not put the interesting part in"
W "    a corner. Keep the material uniform enough that ANY crop of it reads correctly."
W "  * The texel budget applies to the window, not the whole image, which is why the"
W "    minimum feature sizes are as large as they are."
W ""
W "Four textures use the full image and are marked FULL."
W ""

foreach ($fam in $famOrder) {
    $set = @($rows | Where-Object { $_.Family -eq $fam } | Sort-Object { [int]$_.Index })
    if (-not $set.Count) { continue }
    W ""
    W ("=" * 79)
    W $famTitle[$fam]
    W ("=" * 79)
    W ""
    # the family's shared palette: most frequent hexes across its members
    $fh = @{}
    foreach ($r in $set) { foreach ($h in ($r.Hex -split ' ')) { if ($fh.ContainsKey($h)) { $fh[$h]++ } else { $fh[$h] = 1 } } }
    $shared = @($fh.GetEnumerator() | Sort-Object { -$_.Value } | Select-Object -First 8 | ForEach-Object { $_.Key })
    W ("SHARED PALETTE for this family -- use these across every member:")
    W ("    " + ($shared -join '  '))
    $sMax = ($set | Measure-Object -Property SatMaxPct -Maximum).Maximum
    W ("    saturation ceiling {0}%" -f $sMax)
    W ""
    if ($fam -eq 'COOLGREEN') {
        W "These nine are variants of ONE floor. Same stone, same grout colour, same block"
        W "scale, same saturation. If they differ from each other the floor looks patchworked."
        W "Generate all nine in a single conversation and vary only the arrangement."
        W ""
    }
    if ($fam -eq 'NEUTRALWARM') {
        W "The two doors and the two wall strips beside them are one material. The wall strips"
        W "are the narrowest surfaces in the room -- about 95 texels across -- so they need the"
        W "largest, plainest forms of anything here."
        W ""
    }
    if ($fam -eq 'NEUTRAL') {
        W "These do not share a palette with anything. Do them one at a time, each with its own"
        W "hex list."
        W ""
    }

    foreach ($r in $set) {
        $full = if ($r.WinFull -eq 'True' -or $r.WinFull -eq $true) { '  [FULL IMAGE]' } else { '' }
        W ("-" * 79)
        W ("{0:d2}-{1}.png{2}" -f [int]$r.Index, $r.Name, $full)
        W ("    subject          {0}" -f $r.Subject)
        W ("    canvas           {0} x {1} pixels  (exact)" -f $r.CanvasW, $r.CanvasH)
        W ("    palette          {0}" -f $r.Hex)
        W ("    saturation       under {0}%" -f $r.SatMaxPct)
        W ("    visible window   {0}{1}" -f $r.Win, $(if ($full) { '' } else { ' of the canvas' }))
        W ("    texel budget     {0} x {1} texels for that window" -f $r.ArtW, $r.ArtH)
        W ("    TARGET SCALE     about 6 major forms across the visible window -- each one")
        W ("                     roughly {0}% of canvas width ({1} px), landing at ~{2} texels" -f `
             $r.TargetPct, $r.TargetPx, $r.FormTexels)
        W ("    vanishing point  detail finer than {0} px on your canvas will not survive" -f $r.MinFeatPx)
    }
}

W ""
W ""
W ("=" * 79)
W "A PROMPT YOU CAN PASTE, ONE FAMILY AT A TIME"
W ("=" * 79)
W ""
W "  I'm remastering textures for a 1996 DOS game -- a dark, wet, gothic underground"
W "  cathedral. I need flat, tileable MATERIAL images. The game's own shadow and lighting"
W "  are re-applied afterwards by my toolchain, so yours must contain NO lighting at all:"
W "  no shadows, no vignette, no dark borders, no ambient occlusion. Even mid-tone"
W "  brightness across the whole canvas."
W ""
W "  The results are reduced to 256 colours and displayed at very low resolution, so the"
W "  artwork must be SIMPLE and LEGIBLE. No more than 8 distinct tones. Large clean shapes:"
W "  about SIX major forms across the visible part of each image, so roughly six courses of"
W "  stone block, not thirty. No fine speckle, no gravel, no scattered pebbles, no hairline"
W "  cracks, no photographic grain -- at this size those do not become detail, they become"
W "  dither noise and look worse than plain stone. In the originals six colours describe the"
W "  entire surface, and that is the look I am matching."
W ""
W "  Use ONLY the hex colours I give you, and blends between them. Any hue outside that"
W "  list is wrong."
W ""
W "  Each image must tile seamlessly on all four edges, and must be EXACTLY the canvas size"
W "  I specify."
W ""
W "  Here is the set. Generate them as a matching family:"
W ""
W "  <paste the family block here>"
W ""
W ""
W "WHEN THEY COME BACK"
W "-------------------"
W ""
W "Put them in one folder with the <number>-<name>.png filenames, then:"
W ""
W ("    .\tools\Prepare-Textures.ps1 -InDir <folder> -Scale {0} -Blend 1.0 -Smooth 0 -Soften {1}" -f $Scale, $Soften)
W ("    .\src\Texture-Tool.ps1 -Import -Res {0} -InDir <folder>\prepared" -f $stem)
W ""
W "Prepare-Textures reports an 'art box ... off by Npx' line per texture. That is the"
W "self-check that the new art landed where the original's art sat. A few pixels is fine;"
W "'MOVED' means the geometry will sample the wrong part of the image."
W ""
W ("Record 20 (spadoor) is absent on purpose: its 1996 pixel stream does not decode, so it")
W "is passed through untouched and cannot be replaced."
W ""
W ("{0}.RES.orig is the pristine backup and every import is rebuilt from it, so settings" -f $stem)
W "never compound and a bad batch is never destructive."

# UTF-8 without the mangling that Get-Content/Set-Content round-trips cause
[IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# the ENRICHED table, with family / canvas / target-scale columns that Measure-TexturePalette
# does not know about. Build-PaletteSheet reads this one, not the raw measurement csv.
$enriched = Join-Path $env:TEMP "$stem-brief.csv"
$rows | Select-Object Index,Name,Family,Subject,RecW,RecH,CanvasW,CanvasH,ArtW,ArtH,Win,WinFull,
                      SatMaxPct,TopShare,FormTexels,TargetPct,TargetPx,MinFeatPx,Hex |
    Export-Csv -NoTypeInformation $enriched
Write-Host ("brief csv -> {0}" -f $enriched)
Write-Host ("wrote {0}  ({1:N0} bytes, {2} textures in {3} families)" -f $Out, (Get-Item $Out).Length, $rows.Count,
            (@($rows | Group-Object Family)).Count) -ForegroundColor Green
$rows | Group-Object Family | ForEach-Object { Write-Host ("  {0,-12} {1,2}  {2}" -f $_.Name, $_.Count, (($_.Group | ForEach-Object { $_.Name }) -join ', ')) }
