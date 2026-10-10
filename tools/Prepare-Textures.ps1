# Prepare-Textures.ps1 -- turn AI-generated art into something the engine can use.
#
#   .\tools\Prepare-Textures.ps1 -InDir C:\Users\josh\Desktop\Room1_textures
#
# THE THING THAT MAKES THIS NECESSARY: most of this game's textures are NOT tiling
# materials. Their UVs sample a SUB-RECTANGLE of the image and the rest is unused black
# padding -- in room 1, only 4 of 21 textures use the full 0..1 range. Those UVs are baked
# into the geometry, so replacement art has to land in the same rectangle or the engine
# samples the wrong part of it and stretches whatever it finds.
#
#   r12r5, all2cori, cor2wash, or_tunnl   full 0..1  -> the art fills the image
#   everything else                       ~30% of it -> the art goes in a rectangle
#
# So the artist (or the image model) should ALWAYS produce a flat, full-bleed material,
# and this tool places it. That keeps the prompt simple and puts the per-texture geometry
# knowledge here, where it can be read from the .XAF instead of remembered.
#
# It also handles the two things image models get wrong regardless of instructions:
# they emit a fixed canvas size (so everything is resized to the record's real size, read
# from the .RES), and they frame their output (so -AutoCrop strips letterboxing).

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InDir,
    [string]$OutDir,
    [string]$Res = 'CORICORI',
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [switch]$NoAutoCrop,        # AutoCrop is ON by default: AI output is usually framed
    [switch]$NoFitUV,           # FitUV is ON by default: most textures are sub-region
    [double]$SeamWarn = 2.0,
    # How much of the NEW art to use. 1.0 = all new detail, 0.0 = the original untouched.
    # AI material is often too high-frequency for a surface this small: a 91px-wide visible
    # region reduced to 256 dithered colours turns fine lichen speckle into noise. Blending
    # back toward the original keeps its character and adds resolution instead of replacing
    # the look wholesale.
    [double]$Blend = 1.0,
    # Box-blur radius applied to the new art before relighting, to kill high-frequency
    # detail that will not survive quantisation anyway. 0 = off.
    [int]$Smooth = 0,
    # Fractional softening, 0..1, applied to the new art AFTER -Smooth. -Smooth is an integer
    # radius, so its smallest possible step is a full 3x3 average -- which at 512 is already
    # more blur than is wanted, and there is nothing between it and nothing at all. This
    # mixes a 3x3 blur back into the sharp art by the given fraction, so 0.25 is a quarter
    # of one radius-1 blur: enough to knit adjacent texels together without losing the
    # detail that doubling the resolution just bought.
    #
    # It deliberately does NOT touch the original's luminance, only the new surface art, for
    # the same reason -Smooth does not: the original's luminance IS the shadow edge, and
    # softening that would smear the hand-painted silhouette this room's mood depends on.
    [double]$Soften = 0.0,
    # Remove LOW-FREQUENCY brightness variation from the new art -- vignettes, corner
    # darkening, a gradient across the image, a bright hotspot in the middle.
    #
    # The brief tells the image model to paint no lighting at all, because the original's
    # hand-painted shadow is re-applied afterwards. Models ignore this constantly: a
    # contact sheet came back with a dark gradient burned into the bottom of every tile.
    # That gradient is not removed by relighting, it is MULTIPLIED by it, and lands in the
    # game as a dark band across the floor.
    #
    # The lighting is modelled by averaging luminance into a coarse grid and sampling it
    # back bilinearly -- deliberately too coarse to represent anything but illumination --
    # then each pixel is divided by its local value. Texture detail is untouched because
    # detail does not survive the downsample in the first place.
    [switch]$Flatten,
    [int]$FlattenGrid = 10,      # coarser = only the very broadest gradients are removed
    [double]$FlattenMax = 2.5,   # gain clamp, so near-black corners cannot explode

    # Multiply the output record size. The engine point-samples with no filtering, so a
    # texture magnified on screen shows hard texel blocks -- and this room's art regions
    # are small (ecrflra2's visible area is only 91x180 texels). Doubling gives twice the
    # texel density for the same surface, which is the lever that actually affects
    # blockiness. Costs 4x the decoded bytes, which comes out of the texture cache.
    # Hard engine limit: 512 per axis, power of two.
    [int]$Scale = 1,
    # 512 is the largest the game ships; beyond that is untested territory.
    [switch]$AllowOversize
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -AssemblyName System.Drawing
if (-not ("AztTool.Azf" -as [type])) { Add-Type -Path (Join-Path $toolDir 'AzfTool.cs') -ReferencedAssemblies System.Drawing }
if (-not $OutDir) { $OutDir = Join-Path $InDir 'prepared' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$stem = $Res -replace '\.(RES|XAF)$',''
$resPath = Join-Path $TexDir "$stem.RES"
$xafPath = Join-Path $TexDir "$stem.XAF"
$origRes = "$resPath.orig"
$texs = [AztTool.Azf]::Read($(if (Test-Path $origRes) { $origRes } else { $resPath }))

# ---- names in first-appearance order, and each texture's UV bounds -----------
$xaf = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($xafPath))
$names = New-Object System.Collections.ArrayList
foreach ($m in [regex]::Matches($xaf, 'texture\s+"([^"]+)"', 'IgnoreCase')) {
    $leaf = (($m.Groups[1].Value -split '[\\/]')[-1]) -replace '\.(azf|gif)$',''
    if (-not $names.Contains($leaf)) { [void]$names.Add($leaf) }
}
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
Write-Host ("{0}: {1} records, UV bounds for {2} textures" -f $stem, $texs.Count, $uv.Count)

function BBox {
    <# bounding box of everything above near-black -- used both to crop AI framing and to
       check the placed result against the ORIGINAL record's own art position #>
    param([System.Drawing.Bitmap]$bm, [int]$Thresh = 18)
    $w = $bm.Width; $h = $bm.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $d = $bm.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object 'int[]' ($w * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $px, 0, $px.Length)
    $bm.UnlockBits($d)
    $x0 = $w; $y0 = $h; $x1 = -1; $y1 = -1
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $v = $px[$y*$w + $x]
            if ((0.299*(($v -shr 16) -band 255) + 0.587*(($v -shr 8) -band 255) + 0.114*($v -band 255)) -gt $Thresh) {
                if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }
                if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y }
            }
        }
    }
    if ($x1 -lt 0) { return $null }
    return (New-Object System.Drawing.Rectangle($x0, $y0, ($x1-$x0+1), ($y1-$y0+1)))
}

function OrigBitmap {
    <# The original record as RGB. When the output is scaled up, the lighting map is
       resized to match -- SMOOTHLY, because it is lighting: upscaling it with
       nearest-neighbour would bake the original's texel blocks into the shadow and
       defeat the entire point of adding resolution. #>
    param($t, [int]$W = 0, [int]$H = 0)
    $bm = New-Object System.Drawing.Bitmap($t.Width, $t.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $t.Height; $y++) {
        for ($x = 0; $x -lt $t.Width; $x++) {
            $c = $t.Pixels[$y * $t.BytesPerLine + $x]
            $bm.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $t.Palette[$c*4], $t.Palette[$c*4+1], $t.Palette[$c*4+2]))
        }
    }
    if ($W -gt 0 -and ($W -ne $t.Width -or $H -ne $t.Height)) {
        $up = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g3 = [System.Drawing.Graphics]::FromImage($up)
        $g3.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g3.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g3.DrawImage($bm, (New-Object System.Drawing.Rectangle(0, 0, $W, $H)))
        $g3.Dispose(); $bm.Dispose()
        return $up
    }
    return $bm
}

$done = 0
foreach ($f in (Get-ChildItem $InDir -Filter '*.png' -File | Sort-Object Name)) {
    if ($f.BaseName -notmatch '^(\d+)-(.+)$') { Write-Host ("  {0}: no <index>-<name> prefix, skipped" -f $f.Name) -ForegroundColor Yellow; continue }
    $idx = [int]$Matches[1]
    if ($idx -ge $texs.Count) { Write-Host ("  {0}: index past the .RES" -f $f.Name) -ForegroundColor Yellow; continue }
    $tname = if ($idx -lt $names.Count) { $names[$idx] } else { '' }
    $tw = $texs[$idx].Width; $th = $texs[$idx].Height
    $ow = $tw; $oh = $th                       # the original's size, for the lighting map
    if ($Scale -gt 1) {
        $tw = $tw * $Scale; $th = $th * $Scale
        if (($tw -gt 512 -or $th -gt 512) -and -not $AllowOversize) {
            Write-Host ("  {0}: {1}x{2} at scale {3} would exceed the engine's 512 limit -- left at {4}x{5}" -f `
                        $f.Name, $ow, $oh, $Scale, $ow, $oh) -ForegroundColor Yellow
            $tw = $ow; $th = $oh
        }
    }

    $im = [System.Drawing.Image]::FromFile($f.FullName)
    $sw0 = $im.Width; $sh0 = $im.Height
    $work = New-Object System.Drawing.Bitmap($im); $im.Dispose()

    if (-not $NoAutoCrop) {
        $cr = BBox $work
        if ($cr -and ($cr.Width -lt $work.Width -or $cr.Height -lt $work.Height)) {
            $c = New-Object System.Drawing.Bitmap($cr.Width, $cr.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g2 = [System.Drawing.Graphics]::FromImage($c)
            $g2.DrawImage($work, (New-Object System.Drawing.Rectangle(0,0,$cr.Width,$cr.Height)), $cr, [System.Drawing.GraphicsUnit]::Pixel)
            $g2.Dispose(); $work.Dispose(); $work = $c
        }
    }

    # THE BLACK IS NOT PADDING -- IT IS THE LIGHTING.
    #
    # This engine does no lighting whatsoever: every vertex colour is white and the
    # Material objects are empty, so shading is emission-only. All the mood in this game
    # is PAINTED INTO THE TEXTURES. The dark regions and the irregular silhouettes are
    # hand-painted shadow, and replacing them with flat full-bleed stone throws away the
    # entire lighting design of the room.
    #
    # So the original is used as a LIGHTING MAP and the new art as SURFACE DETAIL:
    #
    #     out = newRGB * (origLuminance / meanNewLuminance)
    #
    # Where the original is black the result is black, so shadows and silhouette survive
    # exactly. Where it is mid-grey the new art is scaled to that brightness, and the new
    # art's own variation rides on top as detail. Normalising by the new art's mean keeps
    # the overall brightness matched to the original rather than darkening everything.
    $ob = OrigBitmap $texs[$idx] $tw $th
    $obb = BBox $ob
    $r = if ($uv.ContainsKey($tname)) { $uv[$tname] } else { $null }
    $uvFull = $r -and ($r.U0 -le 0.02 -and $r.U1 -ge 0.98 -and $r.V0 -le 0.02 -and $r.V1 -ge 0.98)

    # new art stretched over the WHOLE record, so the geometry is untouched
    $stretched = New-Object System.Drawing.Bitmap($tw, $th, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = [System.Drawing.Graphics]::FromImage($stretched)
    $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gr.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gr.DrawImage($work, (New-Object System.Drawing.Rectangle(0, 0, $tw, $th)))
    $gr.Dispose(); $work.Dispose()

    $rect = New-Object System.Drawing.Rectangle(0, 0, $tw, $th)
    $dN = $stretched.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $pxN = New-Object 'int[]' ($tw * $th); [System.Runtime.InteropServices.Marshal]::Copy($dN.Scan0, $pxN, 0, $pxN.Length)
    $stretched.UnlockBits($dN); $stretched.Dispose()
    $dO = $ob.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $pxO = New-Object 'int[]' ($tw * $th); [System.Runtime.InteropServices.Marshal]::Copy($dO.Scan0, $pxO, 0, $pxO.Length)
    $ob.UnlockBits($dO); $ob.Dispose()

    # flatten the model's own baked lighting BEFORE anything else measures brightness
    if ($Flatten) {
        $G = [Math]::Max(2, $FlattenGrid)
        $gs = New-Object 'double[]' ($G*$G)
        $gn = New-Object 'int[]'    ($G*$G)
        for ($y = 0; $y -lt $th; $y++) {
            $gy = [int]($y * $G / $th); if ($gy -ge $G) { $gy = $G-1 }
            $rowOff = $y*$tw
            for ($x = 0; $x -lt $tw; $x++) {
                $gx = [int]($x * $G / $tw); if ($gx -ge $G) { $gx = $G-1 }
                $v = $pxN[$rowOff + $x]
                $gs[$gy*$G+$gx] += 0.299*(($v -shr 16) -band 255) + 0.587*(($v -shr 8) -band 255) + 0.114*($v -band 255)
                $gn[$gy*$G+$gx]++
            }
        }
        $gAll = 0.0
        for ($i = 0; $i -lt $gs.Length; $i++) {
            if ($gn[$i] -gt 0) { $gs[$i] = $gs[$i] / $gn[$i] } else { $gs[$i] = 1.0 }
            if ($gs[$i] -lt 1.0) { $gs[$i] = 1.0 }
            $gAll += $gs[$i]
        }
        $gAll = $gAll / $gs.Length

        $flat = New-Object 'int[]' ($tw*$th)
        for ($y = 0; $y -lt $th; $y++) {
            $fy = ($y + 0.5) * $G / $th - 0.5
            $y0i = [Math]::Floor($fy); $ty = $fy - $y0i
            $ya = [int][Math]::Max(0, [Math]::Min($G-1, $y0i)); $yb = [int][Math]::Max(0, [Math]::Min($G-1, $y0i+1))
            $rowOff = $y*$tw
            for ($x = 0; $x -lt $tw; $x++) {
                $fx = ($x + 0.5) * $G / $tw - 0.5
                $x0i = [Math]::Floor($fx); $tx = $fx - $x0i
                $xa = [int][Math]::Max(0, [Math]::Min($G-1, $x0i)); $xb = [int][Math]::Max(0, [Math]::Min($G-1, $x0i+1))
                $t0 = $gs[$ya*$G+$xa] + ($gs[$ya*$G+$xb] - $gs[$ya*$G+$xa]) * $tx
                $t1 = $gs[$yb*$G+$xa] + ($gs[$yb*$G+$xb] - $gs[$yb*$G+$xa]) * $tx
                $loc = $t0 + ($t1 - $t0) * $ty
                if ($loc -lt 1.0) { $loc = 1.0 }
                $gain = $gAll / $loc
                if ($gain -gt $FlattenMax) { $gain = $FlattenMax }
                if ($gain -lt (1.0/$FlattenMax)) { $gain = 1.0/$FlattenMax }
                $v = $pxN[$rowOff + $x]
                $rr2 = (( ($v -shr 16) -band 255) * $gain); if ($rr2 -gt 255) { $rr2 = 255 }
                $gg2 = (( ($v -shr 8)  -band 255) * $gain); if ($gg2 -gt 255) { $gg2 = 255 }
                $bb2 = (( $v           -band 255) * $gain); if ($bb2 -gt 255) { $bb2 = 255 }
                $flat[$rowOff + $x] = (-16777216 -bor ([int]$rr2 -shl 16) -bor ([int]$gg2 -shl 8) -bor [int]$bb2)
            }
        }
        $pxN = $flat
    }

    $sumN = 0.0
    for ($i = 0; $i -lt $pxN.Length; $i++) {
        $v = $pxN[$i]
        $sumN += 0.299*(($v -shr 16) -band 255) + 0.587*(($v -shr 8) -band 255) + 0.114*($v -band 255)
    }
    $meanN = $sumN / $pxN.Length
    if ($meanN -lt 1) { $meanN = 1 }

    # optional smoothing of the NEW art only -- the original's luminance must stay sharp,
    # because that is the shadow edge
    if ($Smooth -gt 0) {
        $tmp = New-Object 'int[]' ($tw * $th)
        for ($y = 0; $y -lt $th; $y++) {
            for ($x = 0; $x -lt $tw; $x++) {
                $sr = 0; $sg = 0; $sb = 0; $n2 = 0
                for ($ky = -$Smooth; $ky -le $Smooth; $ky++) {
                    $yy = $y + $ky; if ($yy -lt 0 -or $yy -ge $th) { continue }
                    for ($kx = -$Smooth; $kx -le $Smooth; $kx++) {
                        $xx = $x + $kx; if ($xx -lt 0 -or $xx -ge $tw) { continue }
                        $v = $pxN[$yy*$tw + $xx]
                        $sr += ($v -shr 16) -band 255; $sg += ($v -shr 8) -band 255; $sb += $v -band 255; $n2++
                    }
                }
                $tmp[$y*$tw + $x] = (-16777216 -bor ([int]($sr/$n2) -shl 16) -bor ([int]($sg/$n2) -shl 8) -bor [int]($sb/$n2))
            }
        }
        $pxN = $tmp
    }

    # fractional softening: lerp the new art toward its own 3x3 box blur
    $sf = [Math]::Max(0.0, [Math]::Min(1.0, $Soften))
    if ($sf -gt 0) {
        $tmp = New-Object 'int[]' ($tw * $th)
        for ($y = 0; $y -lt $th; $y++) {
            for ($x = 0; $x -lt $tw; $x++) {
                $sr = 0; $sg = 0; $sb = 0; $n2 = 0
                for ($ky = -1; $ky -le 1; $ky++) {
                    $yy = $y + $ky; if ($yy -lt 0 -or $yy -ge $th) { continue }
                    for ($kx = -1; $kx -le 1; $kx++) {
                        $xx = $x + $kx; if ($xx -lt 0 -or $xx -ge $tw) { continue }
                        $v = $pxN[$yy*$tw + $xx]
                        $sr += ($v -shr 16) -band 255; $sg += ($v -shr 8) -band 255; $sb += $v -band 255; $n2++
                    }
                }
                $c = $pxN[$y*$tw + $x]
                $cr = ($c -shr 16) -band 255; $cg2 = ($c -shr 8) -band 255; $cb = $c -band 255
                $mr = [int]($cr  + ($sr/$n2 - $cr)  * $sf)
                $mg = [int]($cg2 + ($sg/$n2 - $cg2) * $sf)
                $mb = [int]($cb  + ($sb/$n2 - $cb)  * $sf)
                $tmp[$y*$tw + $x] = (-16777216 -bor ($mr -shl 16) -bor ($mg -shl 8) -bor $mb)
            }
        }
        $pxN = $tmp
    }

    $pxOut = New-Object 'int[]' ($tw * $th)
    $t = [Math]::Max(0.0, [Math]::Min(1.0, $Blend))
    # At Scale > 1 the original has been bicubically upscaled, so blending toward it mixes
    # in a SOFT copy of 1996 art -- the opposite of what adding texels was for. The blend
    # is a good dial at native size and a blur at double size.
    if ($Scale -gt 1 -and $t -lt 0.85) {
        Write-Host ("      note: Blend {0:N2} at Scale {1} mixes in an upscaled (soft) original; 0.85-1.0 is sharper" -f $t, $Scale) -ForegroundColor Yellow
    }
    for ($i = 0; $i -lt $pxN.Length; $i++) {
        $o = $pxO[$i]
        $lo = 0.299*(($o -shr 16) -band 255) + 0.587*(($o -shr 8) -band 255) + 0.114*($o -band 255)
        $g = $lo / $meanN
        $n = $pxN[$i]
        $rr = (( ($n -shr 16) -band 255) * $g); if ($rr -gt 255) { $rr = 255 }
        $gg = (( ($n -shr 8)  -band 255) * $g); if ($gg -gt 255) { $gg = 255 }
        $bb = (( $n           -band 255) * $g); if ($bb -gt 255) { $bb = 255 }
        # blend back toward the ORIGINAL pixel; at t=0 the record is unchanged, which makes
        # this a safe dial rather than an all-or-nothing replacement
        $orr = ($o -shr 16) -band 255; $ogg = ($o -shr 8) -band 255; $obb2 = $o -band 255
        $fr = [int]($orr + ($rr - $orr) * $t); $fg = [int]($ogg + ($gg - $ogg) * $t); $fb = [int]($obb2 + ($bb - $obb2) * $t)
        if ($fr -lt 0) { $fr = 0 }; if ($fg -lt 0) { $fg = 0 }; if ($fb -lt 0) { $fb = 0 }
        $pxOut[$i] = (-16777216 -bor ($fr -shl 16) -bor ($fg -shl 8) -bor $fb)
    }
    $out = New-Object System.Drawing.Bitmap($tw, $th, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $dOut = $out.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($pxOut, 0, $dOut.Scan0, $pxOut.Length)
    $out.UnlockBits($dOut)
    $full = $uvFull

    # SELF-CHECK. The question is "did the hand-painted shadow stay where it was", and a
    # thresholded bounding box answers it badly: the box is lit-vs-not at a fixed cutoff, so
    # new art that is brighter than the original's mean lifts faint fringe over the line and
    # the box GROWS while the silhouette has not moved at all. Measured on one such warning:
    # the whole grown ring was below luminance 18 in the original.
    #
    # So two numbers, and only the second can fail the texture:
    #   CENTRE SHIFT -- where the art sits. Growth on all sides leaves this at zero.
    #   SHADOW MATCH -- Pearson correlation of output luminance against the original's.
    #                   This is the silhouette itself, and it is threshold-free.
    #
    # CALIBRATED, not guessed. A perfect score is impossible: output luminance is the
    # original's multiplied by the new art's, so the new detail -- the entire point of the
    # exercise -- necessarily decorrelates it. The texture accepted on screen measures
    # 0.873, and a first cut at this check used 0.90 and failed all nine tiles of a batch
    # that was fine. 0.75 sits well below the observed good range (0.81-0.87) and still
    # well above a genuinely misplaced result.
    $SHADOW_MIN = 0.75
    $nbb = BBox $out
    $note = ''
    $sOO = 0.0; $sNN = 0.0; $sON = 0.0; $mO = 0.0; $mN = 0.0
    for ($i = 0; $i -lt $pxOut.Length; $i++) {
        $o = $pxO[$i]; $n2 = $pxOut[$i]
        $mO += 0.299*(($o -shr 16) -band 255) + 0.587*(($o -shr 8) -band 255) + 0.114*($o -band 255)
        $mN += 0.299*(($n2 -shr 16) -band 255) + 0.587*(($n2 -shr 8) -band 255) + 0.114*($n2 -band 255)
    }
    $mO /= $pxOut.Length; $mN /= $pxOut.Length
    for ($i = 0; $i -lt $pxOut.Length; $i++) {
        $o = $pxO[$i]; $n2 = $pxOut[$i]
        $a = (0.299*(($o -shr 16) -band 255) + 0.587*(($o -shr 8) -band 255) + 0.114*($o -band 255)) - $mO
        $b2 = (0.299*(($n2 -shr 16) -band 255) + 0.587*(($n2 -shr 8) -band 255) + 0.114*($n2 -band 255)) - $mN
        $sOO += $a*$a; $sNN += $b2*$b2; $sON += $a*$b2
    }
    $corr = if ($sOO -gt 0 -and $sNN -gt 0) { $sON / [Math]::Sqrt($sOO * $sNN) } else { 0.0 }
    if ($obb -and $nbb) {
        $ocx = $obb.X + $obb.Width/2.0; $ocy = $obb.Y + $obb.Height/2.0
        $ncx = $nbb.X + $nbb.Width/2.0; $ncy = $nbb.Y + $nbb.Height/2.0
        $shift = [int][Math]::Round([Math]::Max([Math]::Abs($ncx-$ocx), [Math]::Abs($ncy-$ocy)))
        $note = ("  centre {0}px  shadow match {1:N3}" -f $shift, $corr)
        if ($shift -gt 6)            { $note += '  <-- MOVED' }
        if ($corr -lt $SHADOW_MIN)   { $note += '  <-- SHADOW LOST' }
    }
    $where = if ($full) { 'full image' } else { 'placed' }
    $uvNote = if ($r) { ("UV {0:N2}-{1:N2}/{2:N2}-{3:N2}{4}" -f $r.U0,$r.U1,$r.V0,$r.V1, $(if ($uvFull) { ' FULL' } else { '' })) } else { 'no UV' }
    Write-Host ("  {0,-22} {1}x{2} -> {3}x{4}  {5,-9} {6}{7}" -f $f.Name, $sw0, $sh0, $tw, $th, $where, $uvNote, $note)

    $out.Save((Join-Path $OutDir $f.Name), [System.Drawing.Imaging.ImageFormat]::Png)
    $out.Dispose()
    $done++
}

Write-Host ""
Write-Host ("{0} prepared -> {1}" -f $done, $OutDir)
Write-Host ("to import:  .\src\Texture-Tool.ps1 -Import -Res {0} -InDir {1}" -f $stem, $OutDir)
