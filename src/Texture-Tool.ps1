# Texture-Tool.ps1 -- get Azrael's textures out to PNG and back again.
#
#   .\src\Texture-Tool.ps1 -Export -Res LURKA -OutDir design\incoming\lurka
#   .\src\Texture-Tool.ps1 -Import -Res LURKA -InDir  design\incoming\lurka
#
# Export writes one PNG per record, named "<idx>-<name>.png". THE INDEX IS WHAT
# MATTERS -- a .RES has no names or index of its own, and records are matched to
# the room's .XAF textures purely by first-appearance order, so the number in the
# filename is the only thing tying a PNG back to its slot. Keep it.
#
# Import replaces each record whose index has a PNG, and leaves the rest alone.
#
# THE PALETTE IS REBUILT FROM THE NEW IMAGE, not reused. Each texture carries its
# own private 256 entries and nothing else indexes them, so an upscale gets a
# fresh optimal palette instead of being crushed into the old one. That is the
# whole reason this is worth doing on AI output.
#
# RULES FOR REPLACEMENT ART:
#   * dimensions must be POWERS OF TWO, and <= 512 in each axis -- every one of
#     the game's 2,909 textures is, and 512 is the largest it ships. 1024 is
#     untested and may simply not render.
#   * a texture whose .XAF name contains '#' is CHROMA KEYED on magenta
#     (GetTexture2 0x28685, colour built at 0x1E9DC from 1.0,0,1.0). Pass -Keyed
#     for those: magenta is then reserved in the palette and never dithered into,
#     because a near-magenta pixel misses the key test and renders as a fringe.
[CmdletBinding()]
param(
    [switch]$Export,
    [switch]$Import,
    [Parameter(Mandatory)][string]$Res,
    [string]$OutDir,
    [string]$InDir,
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [int[]] $Keyed = @(),         # record indices that are chroma-keyed
    # 512 is the largest size the game itself ships. Larger is UNTESTED: the format has
    # no limit (width/height are int32) but the software rasteriser may cap UV precision.
    [switch]$AllowOversize
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\AzfTool.cs","$PSScriptRoot\..\tools\Uprez.cs" -ReferencedAssemblies System.Drawing
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Drawing

$resPath = if (Test-Path $Res) { $Res } else { Join-Path $TexDir ("{0}.RES" -f ($Res -replace '\.RES$','')) }
if (-not (Test-Path $resPath)) { throw "not found: $resPath" }
$orig = "$resPath.orig"
if (-not (Test-Path $orig)) { Copy-Item $resPath $orig }

function Save-Png($t, $path) {
    $bmp = New-Object System.Drawing.Bitmap($t.Width, $t.Height, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    $cp = $bmp.Palette
    for ($i = 0; $i -lt 256 -and ($i*4+2) -lt $t.Palette.Length; $i++) {
        $cp.Entries[$i] = [System.Drawing.Color]::FromArgb(255, $t.Palette[$i*4], $t.Palette[$i*4+1], $t.Palette[$i*4+2])
    }
    $bmp.Palette = $cp
    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$t.Width,$t.Height)),
                       [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                       [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    for ($y = 0; $y -lt $t.Height; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy($t.Pixels, $y*$t.BytesPerLine,
            [IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride), $t.Width)
    }
    $bmp.UnlockBits($d); $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

# PNG -> BGRA byte array, which is what Quantize expects
function Read-Bgra($path, [ref]$w, [ref]$h) {
    $img = [System.Drawing.Image]::FromFile($path)
    $bmp = New-Object System.Drawing.Bitmap($img.Width, $img.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($img, 0, 0, $img.Width, $img.Height); $g.Dispose(); $img.Dispose()
    $w.Value = $bmp.Width; $h.Value = $bmp.Height
    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$bmp.Width,$bmp.Height)),
                       [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                       [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $buf = New-Object byte[] ($bmp.Width * $bmp.Height * 4)
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride),
            $buf, $y*$bmp.Width*4, $bmp.Width*4)
    }
    $bmp.UnlockBits($d); $bmp.Dispose()
    return $buf
}

$texs = [AztTool.Azf]::Read($orig)

if ($Export) {
    if (-not $OutDir) { throw '-Export needs -OutDir' }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    for ($i = 0; $i -lt $texs.Count; $i++) {
        if (-not $texs[$i].Decoded) {
            "SKIPPED record {0}  {1}x{2}  -- pixel stream will not decode; it is passed through untouched on import" -f `
                $i, $texs[$i].Width, $texs[$i].Height
            continue
        }
        $p = Join-Path $OutDir ("{0}-tex.png" -f $i)
        Save-Png $texs[$i] $p
        "exported {0}  {1}x{2}" -f (Split-Path $p -Leaf), $texs[$i].Width, $texs[$i].Height
    }
    return
}

if ($Import) {
    if (-not $InDir) { throw '-Import needs -InDir' }
    $any = $false
    for ($i = 0; $i -lt $texs.Count; $i++) {
        # Match on the PARSED leading number, not on a -Filter string. Export-RoomTextures
        # writes zero-padded names ("08-ecrflra2.png") while -Filter "8-*.png" only matches
        # the unpadded form, so every index below 10 was silently skipped.
        $png = @(Get-ChildItem $InDir -Filter '*.png' -ErrorAction SilentlyContinue |
                 Where-Object { $_.BaseName -match '^(\d+)-' -and [int]$Matches[1] -eq $i })
        if ($png.Count -eq 0) { continue }
        $file = $png[0].FullName
        $w = 0; $h = 0
        $bgra = Read-Bgra $file ([ref]$w) ([ref]$h)

        foreach ($d in @($w, $h)) {
            if ($d -gt 512 -and -not $AllowOversize) {
                throw "$file is ${w}x${h}; each axis must be <= 512 (the largest the game ships). Pass -AllowOversize to try larger -- it is UNTESTED and may not render."
            }
            if (($d -band ($d - 1)) -ne 0) { throw "$file is ${w}x${h}; both axes must be powers of two" }
        }
        if ($w -gt 512 -or $h -gt 512) {
            Write-Host ("  WARNING: {0} is {1}x{2}. No shipped texture exceeds 512, so this is beyond anything the engine is known to handle." -f (Split-Path $file -Leaf), $w, $h) -ForegroundColor Yellow
        }

        $isKeyed = $Keyed -contains $i
        # Reserve magenta when keyed: the key is matched by COLOUR, so it must
        # survive quantisation exactly and nothing may dither near it.

        # Try the lossless path first. Art that already fits in 256 colours -- which
        # includes anything Scale2x produced, since it only copies existing pixels --
        # should be stored exactly, not approximated by median cut's box averages.
        $reserve = if ($isKeyed) { 255 } else { -1 }
        $pal3 = $null
        $idx = [LeTool.Quant]::MapExact($bgra, $w, $h, 256, $reserve, [ref]$pal3)
        if ($null -ne $idx) {
            $nCols = 256
            $mode = 'exact palette'
        } else {
            $nCols = if ($isKeyed) { 255 } else { 256 }
            $pal3 = [LeTool.Quant]::MedianCut($bgra, $w, $h, $nCols)
            $idx  = [LeTool.Quant]::Map($bgra, $w, $h, $pal3, $nCols, 0, 1)
            $mode = 'median cut + dither'
        }

        # 3-byte palette -> the .azf's 4-byte (r,g,b,flags)
        $pal4 = New-Object byte[] 1024
        for ($c = 0; $c -lt $nCols; $c++) {
            $pal4[$c*4]   = $pal3[$c*3]
            $pal4[$c*4+1] = $pal3[$c*3+1]
            $pal4[$c*4+2] = $pal3[$c*3+2]
        }
        if ($isKeyed) { $pal4[255*4] = 255; $pal4[255*4+1] = 0; $pal4[255*4+2] = 255 }

        $t = $texs[$i]
        $t.Width = $w; $t.Height = $h; $t.BytesPerLine = $w
        $t.Palette = $pal4; $t.Pixels = $idx
        $t.Dirty = $true        # only Dirty records are re-encoded; the rest are copied verbatim
        "imported {0} -> record {1}  {2}x{3}  {4}  [{5}]" -f (Split-Path $file -Leaf), $i, $w, $h, `
            $(if ($isKeyed) { 'keyed (magenta reserved at 255)' } else { 'opaque' }), $mode
        $any = $true
    }
    if (-not $any) { throw "no PNGs matching '<index>-*.png' found in $InDir" }
    [AztTool.Azf]::Write($resPath, $texs)
    "wrote {0}  ({1:N0} bytes)" -f $resPath, (Get-Item $resPath).Length
    return
}

throw 'specify -Export or -Import'

