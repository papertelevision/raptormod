# Fit-RoomTextures.ps1 -- Josh's redrawn room textures (ChatGPT etc.) into the true-colour renderer, LINED UP (2026-10-08).
#
# A redrawn texture keeps the look but not the geometry: CORICORI's first batch came back zoomed in 8-14% and shifted up
# to 6%, so doorways, holes and borders landed in the wrong place on the model (the game maps a texture by position).
# For each image in the room's folder named like one of its textures (00-r12r5.png; copy suffixes like "(3)" are fine):
#   1. a different shape (a 2:1 crop of a square texture) is fitted content-box to content-box first;
#   2. the zoom (x, y) and shift that best line its edges up with the ORIGINAL's are measured (tools\TexFit.cs);
#   3. it is warped back into the original's frame at -Size, over the previous aligned replacement (or the original),
#      which shows only in a thin border where un-zooming leaves a gap;
#   4. scored again; anything still under -MinMatch is flagged (redraw it, or leave the old one);
#   5. written to the replacement folder; what it replaces is kept in -Backup first.
# The relief (normal) maps are built from whatever texture loads, so they follow with no extra step.
#
#   .\tools\Fit-RoomTextures.ps1 -Room CORICORI [-Src folder] [-Size 2048] [-Sheet check.png] [-WhatIf]
param(
    [Parameter(Mandatory)][string]$Room,
    [string]$Src = '',
    [string]$Dst = 'C:\Games\azrael-textures\hires',
    [string]$Orig = 'C:\Games\azrael-render',
    [string]$Backup = '',
    [ValidateSet(512, 1024, 2048, 4096)][int]$Size = 2048,     # 4096: only a few per room, or they overflow the card's texture budget (GpuRaster.MaxTextureBytes)
    [double]$MinMatch = 0.75,
    [string]$Sheet = '',
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName System.Drawing
if (-not ('AztTool.TexFit' -as [type])) { Add-Type -Path (Join-Path $toolDir 'TexFit.cs') -ReferencedAssemblies System.Drawing }
$Room = $Room.ToUpperInvariant()
if (-not $Src) { $Src = "C:\Games\azrael-gfx\decals\$Room\updated" }
if (-not $Backup) { $Backup = Join-Path (Split-Path $Dst -Parent) ("hires-backup-{0}" -f $Room.ToLowerInvariant()) }
New-Item -ItemType Directory -Force $Backup | Out-Null
# the room's own textures (its MTL), so a name from another room is never touched
$roomTex = @{}; foreach ($l in [IO.File]::ReadAllLines((Join-Path $Orig "$Room.mtl"))) { if ($l.Trim().StartsWith('map_Kd ')) { $roomTex[$l.Trim().Substring(7).Trim()] = 1 } }
$tmpDir = Join-Path $env:TEMP ("fitrt-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $tmpDir | Out-Null

function New-G($bmp) { $g = [Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingQuality = 'HighQuality'; $g.SmoothingMode = 'HighQuality'; return $g }
function Get-ContentBox($bm, [int]$thr) {
    $w = $bm.Width; $h = $bm.Height; $x0 = $w; $y0 = $h; $x1 = -1; $y1 = -1; $st = [Math]::Max(1, [int]($w / 600))
    for ($y = 0; $y -lt $h; $y += $st) { for ($x = 0; $x -lt $w; $x += $st) { $p = $bm.GetPixel($x, $y); if (($p.R + $p.G + $p.B) -gt $thr) { if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }; if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y } } } }
    return @($x0, $y0, ($x1 + $st), ($y1 + $st))
}
$rows = @()
try {
    foreach ($f in Get-ChildItem $Src -Filter '*.png') {
        if ($f.Name -notmatch '^(\d\d-[A-Za-z0-9_]+)') { $rows += [pscustomobject]@{ Texture = $f.Name; Result = 'SKIPPED: no texture name' }; continue }
        $leaf = $Matches[1] + '.png'
        if (-not $roomTex.ContainsKey($leaf)) { $rows += [pscustomobject]@{ Texture = $f.Name; Result = "SKIPPED: $Room has no $leaf" }; continue }
        $origPath = Join-Path $Orig $leaf; $dstPath = Join-Path $Dst $leaf; $bakPath = Join-Path $Backup $leaf
        if ((Test-Path $dstPath) -and -not (Test-Path $bakPath) -and -not $WhatIf) { Copy-Item $dstPath $bakPath }
        $under = $(if (Test-Path $bakPath) { $bakPath } elseif (Test-Path $dstPath) { $dstPath } else { $origPath })     # the aligned picture beneath (the border)
        $ob = [Drawing.Bitmap]::FromFile($origPath); $ow = $ob.Width; $oh = $ob.Height
        $W = $Size; $H = [int][Math]::Round($Size * $oh / $ow)
        # 1. into the original's shape
        $img = [Drawing.Image]::FromFile($f.FullName); $shape = ''
        $stage = New-Object Drawing.Bitmap $W, $H, ([Drawing.Imaging.PixelFormat]::Format32bppArgb); $g = New-G $stage
        $wrap = New-Object Drawing.Imaging.ImageAttributes; $wrap.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
        if ([Math]::Abs($img.Width / $img.Height - $ow / $oh) -lt 0.02) { $g.DrawImage($img, (New-Object Drawing.Rectangle 0, 0, $W, $H), 0, 0, $img.Width, $img.Height, [Drawing.GraphicsUnit]::Pixel, $wrap) }
        else {
            $sb = New-Object Drawing.Bitmap $img; $bs = Get-ContentBox $sb 40; $sb.Dispose(); $bo = Get-ContentBox $ob 40; $k = $W / $ow
            $g.Clear([Drawing.Color]::Black)
            $g.DrawImage($img, (New-Object Drawing.Rectangle ([int]($bo[0] * $k)), ([int]($bo[1] * $k)), ([int](($bo[2] - $bo[0]) * $k)), ([int](($bo[3] - $bo[1]) * $k))), $bs[0], $bs[1], ($bs[2] - $bs[0]), ($bs[3] - $bs[1]), [Drawing.GraphicsUnit]::Pixel, $wrap)
            $shape = ' (a different shape: content boxes matched)'
        }
        $g.Dispose(); $img.Dispose(); $ob.Dispose()
        $stagePath = Join-Path $tmpDir $leaf; $stage.Save($stagePath, [Drawing.Imaging.ImageFormat]::Png); $stage.Dispose()
        # 2. measured
        $r = [AztTool.TexFit]::FitFine($origPath, $stagePath, 256)
        $sx = $r[2]; $sy = $r[3]; $dx = $r[4] * $W / 256.0; $dy = $r[5] * $H / 256.0
        $moved = ([Math]::Abs($sx - 1) -gt 0.006 -or [Math]::Abs($sy - 1) -gt 0.006 -or [Math]::Abs($r[4]) -gt 0.6 -or [Math]::Abs($r[5]) -gt 0.6) -and ($r[1] -gt $r[0] + 0.01)
        # 3. warped into place, over the aligned picture beneath
        $out = New-Object Drawing.Bitmap $W, $H, ([Drawing.Imaging.PixelFormat]::Format32bppArgb); $g = New-G $out
        if ($moved) { $u = [Drawing.Image]::FromFile($under); $g.DrawImage($u, 0, 0, $W, $H); $u.Dispose() }
        $st = [Drawing.Image]::FromFile($stagePath)
        $cx = $W / 2.0; $cy = $H / 2.0
        $rect = $(if ($moved) { New-Object Drawing.RectangleF ([single]($cx - $cx * $sx + $dx)), ([single]($cy - $cy * $sy + $dy)), ([single]($W * $sx)), ([single]($H * $sy)) } else { New-Object Drawing.RectangleF 0, 0, $W, $H })
        $g.DrawImage($st, $rect, (New-Object Drawing.RectangleF 0, 0, $st.Width, $st.Height), [Drawing.GraphicsUnit]::Pixel); $st.Dispose(); $g.Dispose()
        $finalTmp = Join-Path $tmpDir ("final-" + $leaf); $out.Save($finalTmp, [Drawing.Imaging.ImageFormat]::Png); $out.Dispose()
        # 4. scored
        $after = [AztTool.TexFit]::FitFine($origPath, $finalTmp, 256)
        $ok = $after[0] -ge $MinMatch
        if (-not $WhatIf) { Copy-Item -Force $finalTmp $dstPath }
        $rows += [pscustomobject]@{ Texture = $leaf; Result = $(if ($ok) { 'ok' } else { 'CHECK: still lines up poorly' })
            Before = [Math]::Round($r[0], 2); After = [Math]::Round($after[0], 2)
            Fix = $(if ($moved) { 'zoom {0:N3} x {1:N3}, shift {2:+0.0;-0.0}% {3:+0.0;-0.0}%{4}' -f (1 / $sx), (1 / $sy), (-100 * $r[4] / 256), (-100 * $r[5] / 256), $shape } else { 'none needed' + $shape })
            Final = $finalTmp; Orig = $origPath }
    }
    $rows | Select-Object Texture, Result, Before, After, Fix | Format-Table -AutoSize | Out-String -Width 250
    "previous replacements kept in $Backup$(if ($WhatIf) { '  (-WhatIf: nothing written)' })"
    if ($Sheet) {
        # original | result, with the original's outlines in red over the result
        $done = @($rows | Where-Object { $_.Final }); $cell = 240
        $sh = New-Object Drawing.Bitmap ($cell * 2 + 30), ([Math]::Max(1, $done.Count) * ($cell + 10) + 10); $gg = [Drawing.Graphics]::FromImage($sh); $gg.Clear([Drawing.Color]::DimGray)
        for ($i = 0; $i -lt $done.Count; $i++) {
            $y = 10 + $i * ($cell + 10)
            $a = [Drawing.Image]::FromFile($done[$i].Orig); $gg.InterpolationMode = 'NearestNeighbor'; $gg.DrawImage($a, 10, $y, $cell, $cell); $a.Dispose()
            $b = [Drawing.Image]::FromFile($done[$i].Final); $gg.InterpolationMode = 'HighQualityBicubic'; $gg.DrawImage($b, 20 + $cell, $y, $cell, $cell); $b.Dispose()
            $e = [AztTool.TexFit]::Edges([AztTool.TexFit]::Lum($done[$i].Orig, $cell), $cell); $mx = ($e | Measure-Object -Maximum).Maximum
            $ov = New-Object Drawing.Bitmap $cell, $cell
            for ($q = 0; $q -lt $e.Length; $q++) { $v = $e[$q] / [Math]::Max(1, $mx); if ($v -gt 0.25) { $ov.SetPixel($q % $cell, [int][Math]::Floor($q / $cell), [Drawing.Color]::FromArgb([int](255 * [Math]::Min(1, $v * 1.5)), 255, 40, 40)) } }
            $gg.DrawImage($ov, 20 + $cell, $y); $ov.Dispose()
        }
        $gg.Dispose(); $sh.Save($Sheet); $sh.Dispose(); "check sheet: $Sheet (left the original, right the result with the original's outlines in red)"
    }
}
finally { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
