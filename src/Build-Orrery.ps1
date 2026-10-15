# Build-Orrery.ps1 -- slice a generated contact sheet into the orrery puzzle's 18 PCX files.
#
#   .\src\Build-Orrery.ps1 -Sheet C:\Games\RaptorMod\sources\gfx\orrery-puzzle\incoming\sheet.png
#   .\src\Build-Orrery.ps1 -Revert
#
# THE FOUR VARIANTS ARE ROTATIONS, NOT SEPARATE ART. Measured on the stock files: for every
# ring family, 02/03/04 are 01 rotated, with angular-profile correlations of 0.87-0.999. So
# the sheet supplies ONE image per ring and this script generates the other three. Producing
# them by hand would give four rings that do not line up, and the puzzle is about matching
# rotations, so that would break it rather than just look wrong.
#
# RINGS ARE FITTED, NOT CROPPED TO THEIR BOUNDING BOX. Each ring is a broken annulus, so its
# bounding box is pulled in wherever an arc gap reaches the extreme -- the stock LARGE ring
# measures 1.079 wide for 1.000 tall that way. Cropping on that would make the ring an
# ellipse and the rotations would wobble. Instead the centre and outer radius are fitted by
# searching for the centre that makes the per-angle outer radius most consistent, and the
# crop is a square derived from that fit.
#
# SCALED BY OUTER RADIUS. Each ring is scaled so its outer radius lands exactly on the stock
# value, which keeps the four rings nesting at the same screen sizes they always had. The
# inner radius is left as drawn: a generated ring that is thinner than the original just has
# a bigger hole, which is a look, not a fault.
#
# PALETTE INDEX 0 IS THE TRANSPARENCY KEY. Every stock file has palette[0] = #000000 and uses
# it for 27-82% of its pixels. So background is classified FIRST and forced to index 0, and
# the art is quantised into indices 1..255 -- never the other way round, or dark stone would
# quantise onto the key colour and punch holes through the ring.
[CmdletBinding()]
param(
    [string]$Sheet  = 'C:\Games\RaptorMod\sources\gfx\orrery-puzzle\incoming\sheet.png',
    [string]$ArtDir = (Join-Path $PSScriptRoot '..\art\ORRPUZ'),
    [string]$OrrGame = 'C:\Games\RaptorMod\game\GAME\AZRAEL\ORRPUZ',   # stock, read-only
    [int]$BgSum     = 30,      # R+G+B at or below this is background -> index 0
    [switch]$Revert
)
$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs"  -ReferencedAssemblies System.Drawing
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing

# OUTPUT GOES TO art\ORRPUZ, NOT STRAIGHT INTO THE GAME FOLDER. Apply-AztMod copies
# art\<sub>\ into GAME\AZRAEL\<sub>\, takes the .aztbak backup itself, and sweeps the file
# back to stock if a later build stops shipping it. Writing into the game folder works until
# the next install and then persists with no way back -- which is why NEWLOGO.PCX showed up
# as "restored stock" in every install log until it was moved here.
if ($Revert) {
    if (Test-Path $ArtDir) {
        Get-ChildItem $ArtDir -Filter '*.PCX' -File | ForEach-Object { [IO.File]::Delete($_.FullName) }
        Write-Host 'cleared art\ORRPUZ -- the next install restores the stock orrery' -ForegroundColor Green
    } else { Write-Host 'nothing to revert' -ForegroundColor Yellow }
    return
}
if (-not (Test-Path $Sheet)) { throw "no sheet at $Sheet" }
New-Item -ItemType Directory -Force $ArtDir | Out-Null

# ---- read the sheet ---------------------------------------------------------
$bmp = New-Object System.Drawing.Bitmap $Sheet
$W = $bmp.Width; $H = $bmp.Height
$d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$W,$H)),'ReadOnly','Format32bppArgb')
$stride = $d.Stride; $src = New-Object byte[] ($stride*$H)
[System.Runtime.InteropServices.Marshal]::Copy($d.Scan0,$src,0,$src.Length)
$bmp.UnlockBits($d); $bmp.Dispose()
Write-Host ("sheet {0}x{1}" -f $W,$H)

function Lit([int]$x,[int]$y) {
    if ($x -lt 0 -or $y -lt 0 -or $x -ge $W -or $y -ge $H) { return $false }
    $o = $y*$stride + $x*4
    return (($src[$o] + $src[$o+1] + $src[$o+2]) -gt $BgSum)
}

# ---- find the six panels by projection --------------------------------------
# Row then column gaps. Deliberately NOT connected components: the arc gaps in a ring split
# it into separate blobs, and dilating enough to rejoin them also welds the MID ring to the
# frame, which sits 14 rows below it.
$rowHas = New-Object bool[] $H
for ($y=0; $y -lt $H; $y++) { for ($x=0; $x -lt $W; $x++) { if (Lit $x $y) { $rowHas[$y]=$true; break } } }
$bands = @(); $s = -1
for ($y=0; $y -le $H; $y++) {
    $on = ($y -lt $H -and $rowHas[$y])
    if ($on -and $s -lt 0) { $s = $y } elseif (-not $on -and $s -ge 0) { $bands += ,@($s, ($y-1)); $s = -1 }
}
if ($bands.Count -ne 2) { throw ("expected 2 rows of panels, found {0}" -f $bands.Count) }

function ColsIn($y0,$y1) {
    $has = New-Object bool[] $W
    for ($x=0; $x -lt $W; $x++) { for ($y=$y0; $y -le $y1; $y++) { if (Lit $x $y) { $has[$x]=$true; break } } }
    # a gap only splits panels if it is wide; a ring can have an empty column through its
    # middle where the top and bottom arc gaps line up, and that must not split it
    $out=@(); $s=-1; $run=0
    for ($x=0; $x -le $W; $x++) {
        $on = ($x -lt $W -and $has[$x])
        if ($on) { if ($s -lt 0) { $s=$x }; $run=0 }
        else { $run++
            if ($s -ge 0 -and $run -ge 60) { $out += ,@($s, ($x-$run)); $s=-1 } } }
    if ($s -ge 0) { $out += ,@($s, ($W-1)) }
    return $out
}
$top = ColsIn $bands[0][0] $bands[0][1]
$bot = ColsIn $bands[1][0] $bands[1][1]
if ($top.Count -ne 3 -or $bot.Count -ne 3) { throw ("expected 3+3 panels, found {0}+{1}" -f $top.Count,$bot.Count) }

# stock geometry: canvas, outer radius, and the 90-degree rotation mapping
$SPEC = @(
    @{ n='LARGE'; size=200; outer=96; band=0; col=0 }
    @{ n='MID';   size=160; outer=80; band=0; col=1 }
    @{ n='TOP';   size=61;  outer=29; band=0; col=2 }
    @{ n='BOT';   size=61;  outer=31; band=1; col=0 }
)

function PanelBox($band,$col) {
    $cols = if ($band -eq 0) { $top } else { $bot }
    $y0=$bands[$band][0]; $y1=$bands[$band][1]
    $x0=$cols[$col][0];   $x1=$cols[$col][1]
    # tighten vertically inside this column
    $mny=99999; $mxy=-1
    for ($y=$y0; $y -le $y1; $y++) { for ($x=$x0; $x -le $x1; $x++) { if (Lit $x $y) { if($y -lt $mny){$mny=$y}; if($y -gt $mxy){$mxy=$y}; break } } }
    return ,@($x0,$mny,$x1,$mxy)
}

# ---- fit a ring's centre and outer radius -----------------------------------
function FitRing($box) {
    $pts = New-Object System.Collections.ArrayList
    for ($y=$box[1]; $y -le $box[3]; $y++) { for ($x=$box[0]; $x -le $box[2]; $x++) { if (Lit $x $y) { [void]$pts.Add(@($x,$y)) } } }
    $cx0 = ($box[0]+$box[2])/2.0; $cy0 = ($box[1]+$box[3])/2.0
    $best=$null; $bestSd=[double]::MaxValue
    foreach ($dx in -16..16) { foreach ($dy in -16..16) {
        $cx=$cx0+$dx; $cy=$cy0+$dy
        $mx = New-Object double[] 72
        foreach ($p in $pts) { $ax=$p[0]-$cx; $ay=$p[1]-$cy
            $a=[int](([Math]::Atan2($ay,$ax)+[Math]::PI)*72/(2*[Math]::PI))%72
            $r=[Math]::Sqrt($ax*$ax+$ay*$ay); if ($r -gt $mx[$a]) { $mx[$a]=$r } }
        $v = $mx | Where-Object { $_ -gt 0 }
        $mean = ($v|Measure-Object -Average).Average
        $sd = [Math]::Sqrt((($v|ForEach-Object{($_-$mean)*($_-$mean)})|Measure-Object -Sum).Sum/$v.Count)
        if ($sd -lt $bestSd) { $bestSd=$sd; $best=@($cx,$cy,$mean) } } }
    return ,@($best[0],$best[1],$best[2],$bestSd)
}

# ---- crop a source rectangle and scale it to a target size ------------------
function Render($sx,$sy,$sw,$sh,$tw,$th) {
    $o = New-Object System.Drawing.Bitmap($tw,$th,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($o)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Black)
    $sb = New-Object System.Drawing.Bitmap $Sheet
    $g.DrawImage($sb,(New-Object System.Drawing.Rectangle(0,0,$tw,$th)),
                     (New-Object System.Drawing.Rectangle($sx,$sy,$sw,$sh)),'Pixel')
    $g.Dispose(); $sb.Dispose()
    return $o
}

# ---- bitmap -> indexed PCX, index 0 reserved for the key colour -------------
function SaveIndexed($bitmap,$path,$colours) {
    $w=$bitmap.Width; $h=$bitmap.Height
    $dd=$bitmap.LockBits((New-Object System.Drawing.Rectangle(0,0,$w,$h)),'ReadOnly','Format32bppArgb')
    $bgra=New-Object byte[] ($w*$h*4)
    for ($y=0;$y -lt $h;$y++) { [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($dd.Scan0.ToInt64()+$y*$dd.Stride),$bgra,$y*$w*4,$w*4) }
    $bitmap.UnlockBits($dd)
    # classify background BEFORE quantising -- see the header
    $isBg=New-Object bool[] ($w*$h)
    for ($i=0;$i -lt ($w*$h);$i++) { $o=$i*4
        if (([int]$bgra[$o]+[int]$bgra[$o+1]+[int]$bgra[$o+2]) -le $BgSum) { $isBg[$i]=$true } }
    # SHARED palette, indices 128..255 -- see the header. $script:ORR_PAL3 is built once from
    # all six images together; mapping each image against its own optimal palette is what
    # turned the puzzle into coloured noise.
    $idx =[LeTool.Quant]::Map($bgra,$w,$h,$script:ORR_PAL3,128,128,1)
    for ($i=0;$i -lt ($w*$h);$i++) { if ($isBg[$i]) { $idx[$i]=0 } }
    $out=New-Object LeTool.Pcx
    $out.Width=$w; $out.Height=$h; $out.BitsPerPixel=8; $out.Planes=1; $out.BytesPerLine=$w
    $out.Pixels=$idx; $out.Palette=$script:ORR_PAL
    $out.SavePcx($path)
    return $idx
}

# Rotating the INDEX array, not the bitmap: a 90-degree turn of an indexed image is exact,
# while rotating the RGB and requantising gives four siblings with slightly different
# dithering, which shows as the ring shimmering as the player turns it.
function RotIdx($idx,$w,$h,$quarter) {
    if ($quarter -eq 0) { return $idx }
    $o=New-Object byte[] ($w*$h)
    for ($y=0;$y -lt $h;$y++) { for ($x=0;$x -lt $w;$x++) {
        switch ($quarter) {
            1 { $nx=$h-1-$y; $ny=$x }            # 90 clockwise
            2 { $nx=$w-1-$x; $ny=$h-1-$y }
            3 { $nx=$y;      $ny=$w-1-$x }       # 270
        }
        $o[$ny*$w+$nx]=$idx[$y*$w+$x] } }
    return $o
}
function SaveIdx($idx,$w,$h,$path) {
    $out=New-Object LeTool.Pcx
    $out.Width=$w; $out.Height=$h; $out.BitsPerPixel=8; $out.Planes=1; $out.BytesPerLine=$w
    $out.Pixels=$idx; $out.Palette=$script:ORR_PAL
    $out.SavePcx($path)
}

New-Item -ItemType Directory -Force (Join-Path (Split-Path $Sheet -Parent) 'preview') | Out-Null
$prev = Join-Path (Split-Path $Sheet -Parent) 'preview'

# ---- render every panel first, at final size --------------------------------
# All six are produced BEFORE anything is quantised, because they have to share one palette.
$PANELS = @{}
foreach ($s in $SPEC) {
    $box = PanelBox $s.band $s.col
    $fit = FitRing $box
    $cx=$fit[0]; $cy=$fit[1]; $R=$fit[2]
    $half = ($s.size/2.0) * $R / $s.outer      # crop square: R maps onto the stock outer radius
    $sx=[int][Math]::Round($cx-$half); $sy=[int][Math]::Round($cy-$half); $sz=[int][Math]::Round($half*2)
    $PANELS[$s.n] = Render $sx $sy $sz $sz $s.size $s.size
    Write-Host ("{0,-7} fit centre ({1:N1},{2:N1}) R {3:N1} sd {4:N1} -> crop {5}x{5} -> {6}x{6}" -f `
                $s.n,$cx,$cy,$R,$fit[3],$sz,$s.size)
}
$sbox = PanelBox 1 1
$scx = ($sbox[0]+$sbox[2])/2.0; $scy = ($sbox[1]+$sbox[3])/2.0
$shalf = [Math]::Max(($sbox[2]-$sbox[0]),($sbox[3]-$sbox[1]))/2.0
$PANELS['SUN'] = Render ([int]($scx-$shalf)) ([int]($scy-$shalf)) ([int]($shalf*2)) ([int]($shalf*2)) 17 17
Write-Host 'SUN     -> 17x17'
# The frame is fitted to 552x282 rather than cropped. The generated panel is wider in
# proportion (2.57 vs 1.96) but its OPENING sits at nearly the same fractions (68%x79%
# against the stock 65%x84%), and the opening is what the rings show through.
$fbox = PanelBox 1 2
$fw = $fbox[2]-$fbox[0]+1; $fh = $fbox[3]-$fbox[1]+1
$PANELS['ORRBACK'] = Render $fbox[0] $fbox[1] $fw $fh 552 282
Write-Host ("ORRBACK {0}x{1} -> 552x282" -f $fw,$fh)

# ---- ONE palette for all six, in indices 128..255 ---------------------------
# THE ORRERY ONLY LOADS THE UPPER HALF OF THE PALETTE. Its loader at 0x2FB88 reads
# ORRBACK.PCX, then pushes entries 0x80..0xFF to the hardware and nothing else:
#
#     0x2FD83  mov word [ebp-4], 0x80     <- starts at 128
#     0x2FD99  call 0x353FC               <- set entry
#     0x2FDA6  cmp eax, 0x100             <- up to 255
#
# Measured on the stock art, that is exactly what it uses: the ONLY index below 128 in any of
# the six files is 0, the transparency key. Art placed in 1..127 indexes entries the orrery
# never loads, which is whatever the previous screen left there -- it renders as coloured
# noise, which is what a first attempt at this produced.
#
# And all six stock files carry a BYTE-IDENTICAL palette, because ORRBACK's is the one that
# gets loaded and every other file indexes into it. Giving each image its own optimal palette
# is the same bug by a different route.
$all = New-Object System.Collections.ArrayList
foreach ($k in $PANELS.Keys) {
    $b=$PANELS[$k]
    $dd=$b.LockBits((New-Object System.Drawing.Rectangle(0,0,$b.Width,$b.Height)),'ReadOnly','Format32bppArgb')
    $tmp=New-Object byte[] ($b.Width*$b.Height*4)
    for ($y=0;$y -lt $b.Height;$y++) { [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($dd.Scan0.ToInt64()+$y*$dd.Stride),$tmp,$y*$b.Width*4,$b.Width*4) }
    $b.UnlockBits($dd)
    for ($i=0;$i -lt ($b.Width*$b.Height);$i++) { $o=$i*4
        if (([int]$tmp[$o]+[int]$tmp[$o+1]+[int]$tmp[$o+2]) -gt $BgSum) {
            [void]$all.Add($tmp[$o]); [void]$all.Add($tmp[$o+1]); [void]$all.Add($tmp[$o+2]); [void]$all.Add(255) } } }
$combined = [byte[]]$all.ToArray()
$nPix = $combined.Length/4
Write-Host ("shared palette: median cut over {0:N0} art pixels from all six panels -> 128 colours at index 128" -f $nPix)
$script:ORR_PAL3 = [LeTool.Quant]::MedianCut($combined,$nPix,1,128)
$script:ORR_PAL  = New-Object byte[] 768
for ($c=0;$c -lt 128;$c++) { $script:ORR_PAL[(128+$c)*3]=$script:ORR_PAL3[$c*3]; $script:ORR_PAL[(128+$c)*3+1]=$script:ORR_PAL3[$c*3+1]; $script:ORR_PAL[(128+$c)*3+2]=$script:ORR_PAL3[$c*3+2] }
# Entries 1..127 are never pushed to the hardware by the orrery, but they are copied from the
# STOCK file rather than left black so the PCX still previews correctly in an image viewer
# and so a diff against the original shows only the half that actually changed.
$stockRef = Join-Path $OrrGame 'ORRBACK.PCX.aztbak'
if (-not (Test-Path $stockRef)) { $stockRef = Join-Path $OrrGame 'ORRBACK.PCX' }
if (Test-Path $stockRef) {
    $sp = [LeTool.Pcx]::Load($stockRef)
    for ($i=3;$i -lt 384;$i++) { $script:ORR_PAL[$i] = $sp.Palette[$i] }
}

# ---- write the 18 files ------------------------------------------------------
# 02 IS 270 AND 04 IS 90, not the other way round. Measured with an angular-profile
# cross-correlation on the stock files: 01->02 is a 270 degree shift and 01->04 is 90. The
# obvious assignment turns every ring the opposite way through the puzzle's four states.
foreach ($s in $SPEC) {
    $idx = SaveIndexed $PANELS[$s.n] (Join-Path $ArtDir ("{0}01.PCX" -f $s.n)) 128
    foreach ($kv in @(@('02',3),@('03',2),@('04',1))) {
        SaveIdx (RotIdx $idx $s.size $s.size $kv[1]) $s.size $s.size (Join-Path $ArtDir ("{0}{1}.PCX" -f $s.n,$kv[0]))
    }
    $PANELS[$s.n].Dispose()
}
[void](SaveIndexed $PANELS['SUN']     (Join-Path $ArtDir 'SUN.PCX') 128)
[void](SaveIndexed $PANELS['ORRBACK'] (Join-Path $ArtDir 'ORRBACK.PCX') 128)
$PANELS['SUN'].Dispose(); $PANELS['ORRBACK'].Dispose()

Write-Host ''
Write-Host "18 files written to $ArtDir   (run Apply-AztMod to install)"
Write-Host 'Revert with:  .\src\Build-Orrery.ps1 -Revert'
