# Build-Credits.ps1 -- the quit-screen credits backdrop.
#
#   .\src\Build-Credits.ps1 -Export -OutDir C:\Games\RaptorMod\sources\gfx\credits
#   .\src\Build-Credits.ps1 -Import -InDir  C:\Games\RaptorMod\sources\gfx\credits
#   .\src\Build-Credits.ps1 -Revert
#
# WHAT THIS FIXES. The credits routine at 0x1FC6C creates two surfaces and the mod patches
# all four dimensions to the mod's screen size (scr-h/w-1FCB7/1FCBC/1FCC9/1FCCE), both
# 0x4B000 byte-copy counts to 0xC0000, and the text centring at 0x1FDB9 from 640 to 1024.
# Those are all correct. What was NOT correct is that BACKDROP.PCX stayed 640x480 and is
# loaded at (0,0), so it painted the top-left corner and nothing else -- and the surface
# allocator does not clear:
#
#     0x37AE0   call 0x32C40          <- bare malloc: try 0x401A7, else 0x2876C
#     0x37AEC   mov [ecx+4], eax      <- straight into the surface, never zeroed
#
# So the other 383,232 bytes were uninitialised heap, the whole surface was copied to the
# compose surface, and the credits were drawn over the top of it. It read as corruption
# rather than as a small image because the text IS correctly centred on the full width, so
# it straddled the boundary between the art and the garbage.
#
# The fix needs no code at all: an image the size of the surface paints all of it.
#
# THE PALETTE IS NOT THIS IMAGE'S OWN. Unlike TITLE.PCX (see Build-Title.ps1, which gives
# its image a fresh optimal palette because nothing else is on screen), the credits screen
# displays through MISTRAL.PCX's palette. From the code, in order:
#
#     0x1FCDF   call 0x38A20   "backdrop.pcx" -> surface B
#     0x1FCF2   call 0x3E7B4   "mistral.pcx", edx=[ebp-0x34A]   <- reads the PALETTE
#     0x1FCFC   call 0x38AB8   "mistral.pcx"                    <- loads the font
#     0x1FE1B   lea eax,[ebp-0x34A] / call 0x1FBC2              <- fades THAT palette in
#
# So the backdrop contributes pixel INDICES only. They are resolved against the font's
# palette, and a fresh optimal palette here would render as garbage colours. The two files
# happen to carry byte-identical palettes today, which is exactly why this would survive
# testing and then break the first time the font is replaced -- so this script reads the
# palette from MISTRAL.PCX by name and asserts the result rather than relying on that.
#
# WHICH INDICES ARE USABLE. That palette's entries 0..80 are a continuous neutral grey ramp,
# #000000 to #5A5A5A, one luma step per index -- which is about perfect for a dark
# watermark. Three carve-outs:
#   53        #4B433C, the only warm entry in the run, and one of the font's own tones
#   81,82,83  #8E857D / #CEC5BD / #FFFFFF -- the glyph ink. A backdrop reaching these
#             would compete with the text it sits behind.
#   84..255   all #FFFFFF padding, so nothing to choose from anyway.
# Hence the allowed set below. Error diffusion is ON, not for the ramp itself (a 1-luma step
# needs none) but for the 1..12 band: the ramp jumps 0 -> 13 at its bottom end, and the
# antialiased edges of the watermark live exactly there.
[CmdletBinding()]
param(
    [switch]$Export,
    [switch]$Import,
    [switch]$Revert,
    [string]$OutDir,
    [string]$InDir,
    [string]$GameDir = 'C:\Games\RaptorMod\game\GAME\AZRAEL',
    [string]$ArtDir  = (Join-Path $PSScriptRoot '..\art'),
    [int]$Width  = 0,          # 0 = take the mod's own screen size from the manifest
    [int]$Height = 0,
    [switch]$NoDither
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs"  -ReferencedAssemblies System.Drawing
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing

$ArtDir = (Resolve-Path $ArtDir).Path
$artPcx = Join-Path $ArtDir 'BACKDROP.PCX'

if ($Revert) {
    if (Test-Path $artPcx) {
        Remove-Item $artPcx
        Write-Host "removed art\BACKDROP.PCX -- the next install restores the stock 640x480 one" -ForegroundColor Green
    } else { Write-Host 'art\BACKDROP.PCX is not present; nothing to revert' -ForegroundColor Yellow }
    return
}

# THE STOCK FILE, never the installed one. Apply-AztMod keeps the original as .aztbak the
# first time it replaces anything, so once this script has shipped a 1024x768 backdrop the
# live BACKDROP.PCX is our own output -- exporting that and re-importing it would resample
# a resample. Same trap Build-Books records for the book pages.
function Stock($name) {
    $live = Join-Path $GameDir $name
    foreach ($c in @("$live.src", "$live.aztbak", $live)) { if (Test-Path $c) { return $c } }
    throw "cannot find $name in $GameDir"
}

if ($Export) {
    if (-not $OutDir) { throw '-Export needs -OutDir' }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $bd = [LeTool.Pcx]::Load((Stock 'BACKDROP.PCX'))
    $bd.SavePng((Join-Path $OutDir 'BACKDROP.png'), 1)
    $mi = [LeTool.Pcx]::Load((Stock 'MISTRAL.PCX'))
    $mi.SavePng((Join-Path $OutDir 'MISTRAL-full.png'), 1)
    Copy-Item (Join-Path $GameDir 'CREDITS.TXT') (Join-Path $OutDir 'CREDITS.TXT') -Force
    $h = $bd.Histogram(); $used = 0
    for ($i = 0; $i -lt 256; $i++) { if ($h[$i] -gt 0) { $used++ } }
    Write-Host ("exported BACKDROP {0}x{1} ({2} indices used), MISTRAL {3}x{4}, CREDITS.TXT -> {5}" -f `
                $bd.Width, $bd.Height, $used, $mi.Width, $mi.Height, $OutDir)
    Write-Host 'Upscale BACKDROP.png and put it back with the same name. Any size: it is resampled on import.'
    return
}
if (-not $Import) { throw 'specify -Export, -Import or -Revert' }
if (-not $InDir)  { throw '-Import needs -InDir' }

# THE SIZE IS THE ENTIRE FIX, so it is read from the mod's own manifest rather than typed
# here. A backdrop that is merely LARGER still leaves the surface partly unpainted if the
# mod's resolution moves, and this is a bug whose symptom is "the credits look corrupt" --
# not something anyone would connect back to a constant in a build script.
if (-not $Width -or -not $Height) {
    $mf = Join-Path $PSScriptRoot '..\AztMod.manifest.json'
    if (-not (Test-Path $mf)) { throw 'no manifest to read the screen size from; pass -Width/-Height' }
    $man = Get-Content $mf -Raw | ConvertFrom-Json
    if (-not $Width)  { $Width  = [int]$man.art.screenW }
    if (-not $Height) { $Height = [int]$man.art.screenH }
    Write-Host ("screen size from the manifest: {0}x{1}" -f $Width, $Height)
}
if ($Width -le 0 -or $Height -le 0) { throw "bad target size ${Width}x${Height}" }

$png = Join-Path $InDir 'BACKDROP.png'
if (-not (Test-Path $png)) { throw "no $png to import" }

# The palette comes from the FONT, for the reasons at the top of this file.
$mi = [LeTool.Pcx]::Load((Stock 'MISTRAL.PCX'))
$pal = $mi.Palette

$ALLOW = @(0..52) + @(54..80)       # the neutral ramp, minus the font's own tones
$sub = New-Object byte[] ($ALLOW.Count * 3)
for ($i = 0; $i -lt $ALLOW.Count; $i++) {
    $src = $ALLOW[$i] * 3
    $sub[$i*3] = $pal[$src]; $sub[$i*3+1] = $pal[$src+1]; $sub[$i*3+2] = $pal[$src+2]
}

# PNG -> BGRA at the target size
$img = [System.Drawing.Image]::FromFile($png)
$sw = $img.Width; $sh = $img.Height
$bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)))
$g.Dispose(); $img.Dispose()

$d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$Width,$Height)),
                   [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                   [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$bgra = New-Object byte[] ($Width * $Height * 4)
for ($y = 0; $y -lt $Height; $y++) {
    [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride),
        $bgra, $y*$Width*4, $Width*4)
}
$bmp.UnlockBits($d); $bmp.Dispose()

# Map returns indices into the SUB-palette, which is not contiguous in the real one.
$sm = [LeTool.Quant]::Map($bgra, $Width, $Height, $sub, $ALLOW.Count, 0, $(if ($NoDither) { 0 } else { 1 }))
$px = New-Object byte[] ($Width * $Height)
for ($i = 0; $i -lt $px.Length; $i++) { $px[$i] = [byte]$ALLOW[$sm[$i]] }

$out = New-Object LeTool.Pcx
$out.Width = $Width; $out.Height = $Height
$out.BitsPerPixel = 8; $out.Planes = 1; $out.BytesPerLine = $Width
$out.Pixels = $px
$out.Palette = $pal                 # the font's palette, so the file is self-describing too
New-Item -ItemType Directory -Force $ArtDir | Out-Null
$out.SavePcx($artPcx)

# ASSERT, do not assume. Every one of these is a way this silently goes back to looking
# corrupt, and none of them is visible without launching the game and quitting it.
$chk = [LeTool.Pcx]::Load($artPcx)
if ($chk.Width -ne $Width -or $chk.Height -ne $Height) {
    throw ("wrote {0}x{1} but read back {2}x{3}" -f $Width, $Height, $chk.Width, $chk.Height)
}
$h = $chk.Histogram()
$bad = @(); for ($i = 0; $i -lt 256; $i++) { if ($h[$i] -gt 0 -and $ALLOW -notcontains $i) { $bad += $i } }
if ($bad.Count) { throw ("the backdrop uses indices outside the neutral ramp: {0}" -f ($bad -join ', ')) }
$palDiff = 0; for ($i = 0; $i -lt 768; $i++) { if ($chk.Palette[$i] -ne $pal[$i]) { $palDiff++ } }
if ($palDiff) { throw "the written palette does not match MISTRAL.PCX's ($palDiff bytes differ)" }

$used = 0; $max = 0
for ($i = 0; $i -lt 256; $i++) { if ($h[$i] -gt 0) { $used++; $max = $i } }
Write-Host ("imported {0}x{1} -> {2}x{3}, {4} grey levels, brightest index {5} (#{6:X2}{6:X2}{6:X2}-ish), {7:N0} bytes" -f `
            $sw, $sh, $Width, $Height, $used, $max, $pal[$max*3], (Get-Item $artPcx).Length) -ForegroundColor Green
Write-Host "wrote art\BACKDROP.PCX -- run Apply-AztMod to install it."
Write-Host "Revert with:  .\src\Build-Credits.ps1 -Revert"
