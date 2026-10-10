# Test-GpuCompose.ps1 -- phase 3 of the graphics-card renderer, without a game: the card's
# sharpen and compose (GpuRaster.PostCompose) against the processor's (Raster.PostCore +
# Overlay.Present), on the same drawn picture and the same "screen" -- a fake DOSBox viewport in
# this process's own memory: the key colour, with game-like drawings over it (a visor band
# across the top, a reticle, text, marks at the edges and corners).
#
#   .\tools\Test-GpuCompose.ps1                     (2562x1238, widescreen with the visor remap)
#   .\tools\Test-GpuCompose.ps1 -Width 1600 -Height 928 -NoWide
param([int]$Width = 2562, [int]$Height = 1238, [switch]$NoWide, [double]$Sharpen = 0.5, [int]$Frames = 20, [switch]$TimePasses, [switch]$Pipelined)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolDir 'GuestBase.ps1'); . (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'GpuRaster.cs'), (Join-Path $toolDir 'GiBake.cs'), (Join-Path $toolDir 'Overlay.cs')) -ReferencedAssemblies 'System.Drawing'
Add-Type -TypeDefinition @'
public static class CmpC {
    public static long[] Go(int[] a, int[] b, int n) { long diff = 0, maxd = 0, big = 0; for (int i = 0; i < n; i++) { int x = a[i] & 0xFFFFFF, y = b[i] & 0xFFFFFF; if (x == y) continue; diff++; int d = System.Math.Max(System.Math.Abs(((x >> 16) & 255) - ((y >> 16) & 255)), System.Math.Max(System.Math.Abs(((x >> 8) & 255) - ((y >> 8) & 255)), System.Math.Abs((x & 255) - (y & 255)))); if (d > maxd) maxd = d; if (d > 2) big++; } return new long[] { diff, maxd, big }; }
    // the fake screen: key everywhere, game-like drawings over it
    public static void Paint(int[] s, int stride, int w, int h, int key, int seed) {
        var rnd = new System.Random(seed);
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) s[y * stride + x] = key | unchecked((int)0xFF000000);
        for (int y = 0; y < (int)(h * 0.09); y++) for (int x = 0; x < w; x++) { if (y > (int)(h * 0.06) && x > w / 4 && x < w - w / 4) continue; s[y * stride + x] = (0x302820 + (x * 7 + y * 3) % 40) | unchecked((int)0xFF000000); }   // the visor band, wedges at the corners
        for (int k = -14; k <= 14; k++) { s[(h / 2) * stride + w / 2 + k] = 0xFFFFFF; s[(h / 2 + k) * stride + w / 2] = 0xFFFFFF; }       // a reticle
        for (int k = 0; k < 400; k++) { int x = 100 + rnd.Next(500), y = h - 120 + rnd.Next(60); s[y * stride + x] = 0xC0C060; }    // "text"
        for (int y = 0; y < h; y++) { s[y * stride] = 0x804020; s[y * stride + w - 1] = 0x204080; }                                     // the edges
        for (int k = 0; k < 2000; k++) { int x = rnd.Next(w), y = rnd.Next(h); s[y * stride + x] = rnd.Next(0x1000000); }                // scattered single pixels
    }
}
'@
$W = 1600; $H = 928; $stride = 1600; $key = 0x101010
$pal = [IO.File]::ReadAllBytes('C:\Games\azrael-inject\azrael-palette.pal')
$room = Import-AztRoom -Rooms @('CORICORI') -CacheDir C:\Games\azrael-render -TexDir C:\Games\AzraelsTear-Modded\GAME\AZTEX -Palette C:\Games\azrael-inject\azrael-palette.pal -Width $Width -Height $Height
[void](Add-AztRgb -Names @('CORICORI') -CacheDir C:\Games\azrael-render -Pal $pal -OverrideDir 'C:\Games\azrael-textures\hires'); [AztTool.Raster]::EnsureRgb($room.Texes, $pal)
$r = New-Object AztTool.Raster($Width, $Height); $r.NearZ = [single]0.5; $r.SetVerticalFov(50); $r.EnableRgb()
$e = $null; $gpu = [AztTool.GpuRaster]::Create($Width, $Height, [ref]$e); if (-not $gpu) { "NO GPU: $e"; exit 1 }
$screen = New-Object int[] ($stride * $H + 64); $gh = [Runtime.InteropServices.GCHandle]::Alloc($screen, 'Pinned')
$o = New-Object AztTool.Overlay($PID, $W, $H, 1600, 1200, 0, 49)
try {
    $o.SyncRead = $true; $o.KeepCopy = $true; $o.Wide = (-not $NoWide)
    $o.SetSurface($gh.AddrOfPinnedObject().ToInt64(), $stride)
    $gpu.NearZ = [single]0.5; $gpu.SetVerticalFov(50); $gpu.TimePasses = [bool]$TimePasses
    $pic = New-Object int[] ($Width * $Height); $scratch = New-Object int[] ($Width * $Height); $fin = New-Object int[] ($Width * $Height)
    $cpuMs = @(); $gpuMs = @(); $results = @(); $upl = 0.0; $pst = 0.0; $rdb = 0.0; $shp = 0.0; $cmp = 0.0; $fin2 = 0.0; $prevCpu = $null
    for ($f = 0; $f -lt $Frames; $f++) {
        [CmpC]::Paint($screen, $stride, $W, $H, $key, $f)
        $a = ($f * 37) * [Math]::PI / 180; $ex = -101.8; $ey = 49.5; $ez = 113.3
        $r.LookAt([single]$ex, [single]$ey, [single]$ez, [single]($ex + [Math]::Sin($a) * 100), [single]($ey - 15), [single]($ez + [Math]::Cos($a) * 100), 1)
        $b = $r.LastBasis; $cam = [single[]]@($b[0], $b[1], $b[2], 0, $b[3], $b[4], $b[5], 0, $b[6], $b[7], $b[8], 0, $ex, $ey, $ez, 1)
        $gpu.SetCameraWorld($cam); $gpu.CopyLighting($r)
        $gpu.Draw($room.V, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true); $gpu.ReadBack($pic)
        # THE PROCESSOR: sharpen, then compose (the overlay's own Present, with its tables)
        $t = [Diagnostics.Stopwatch]::StartNew()
        $sharp = [AztTool.Raster]::PostCore([int[]]$pic.Clone(), $scratch, $Width, $Height, $false, [single]$Sharpen, 3)
        $share = $o.PresentRgb($sharp, $Width, $Height, 400)
        $cpuMs += $t.Elapsed.TotalMilliseconds
        $cpuPic = [int[]]$o.LastFrame().Clone()
        # THE CARD: the same picture (still on it), the overlay's latest reading and maps
        $k = 0; $sh = 0; $st = 0
        $scr = $o.TakeSurface(400, [ref]$k, [ref]$sh, [ref]$st)     # (outside the timing: in game the overlay's own thread reads the screen)
        $t.Restart()
        $cxi = $null; $cxf = $null; $cxiR = $null; $cxfR = $null; $riy = $null; $rwy = $null; $bt = 0; $bb = 0; $vis = $false
        $o.ComposeMap($Width, $Height, [ref]$cxi, [ref]$cxf, [ref]$cxiR, [ref]$cxfR, [ref]$riy, [ref]$rwy, [ref]$bt, [ref]$bb, [ref]$vis)
        $gpu.SetComposeMap($cxi, $cxf, $cxiR, $cxfR, $riy, $rwy)
        if ($Pipelined) {
            # what the watcher does: last frame's picture collected, this one's started
            $had = $gpu.FinishRead($fin)
            $gpu.PostCompose([single]$Sharpen, $scr, $st, $W, $H, $k, $bt, $bb, $vis); $gpu.StartRead()
            $gpuMs += $t.Elapsed.TotalMilliseconds; $fin2 += $gpu.LastFinishMs
            if ($had) { $results += ,([CmpC]::Go($prevCpu, $fin, $Width * $Height)) }
            $prevCpu = $cpuPic; continue
        }
        $gpu.PostCompose([single]$Sharpen, $scr, $st, $W, $H, $k, $bt, $bb, $vis)
        $gpu.ReadComposed($fin)
        $gpuMs += $t.Elapsed.TotalMilliseconds; if ($f -ge 2) { $shp += $gpu.LastSharpenMs; $cmp += $gpu.LastComposeMs; $upl += $gpu.LastUploadScreenMs; $pst += $gpu.LastPostMs; $rdb += $gpu.LastReadMs }
        $results += ,([CmpC]::Go($cpuPic, $fin, $Width * $Height))
        if ($f -eq 0) { "screen share of key: processor {0}, card {1}; key #{2:X6}; visor remap {3} (band rows < {4})" -f $share, $sh, $k, $vis, $bt }
    }
    $mc = ($cpuMs | Select-Object -Skip 2 | Measure-Object -Average).Average; $mg = ($gpuMs | Select-Object -Skip 2 | Measure-Object -Average).Average
    "sharpen + compose, {0}x{1}: processor (3 threads, as the overlay ran it) {2:N1} ms; card (screen upload + both passes + read-back) {3:N1} ms" -f $Width, $Height, $mc, $mg
    if ($Pipelined) { "  pipelined: on this thread per frame {0:N2} ms, of which collecting the previous picture {1:N2} ms (the card's work overlaps the rest of the loop)" -f $mg, ($fin2 / $Frames) }
    if (-not $Pipelined) { "  card, split: screen upload {0:N2} + passes issued {1:N2} + waiting for them and reading the finished picture back {2:N2} ms" -f ($upl / ($Frames - 2)), (($pst - $upl) / ($Frames - 2)), ($rdb / ($Frames - 2)) }
    if ($TimePasses) { "  each step waited for: screen upload {0:N2}, sharpen {1:N2}, compose {2:N2}, read-back {3:N2} ms" -f ($upl / ($Frames - 2)), ($shp / ($Frames - 2)), ($cmp / ($Frames - 2)), ($rdb / ($Frames - 2)) }
    $tot = ($results | ForEach-Object { $_[0] } | Measure-Object -Sum).Sum; $mx = ($results | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum; $bg = ($results | ForEach-Object { $_[2] } | Measure-Object -Sum).Sum
    "over {0} frames: pixels that differ at all {1:N0} of {2:N0}; largest difference {3} / 255; pixels off by more than 2: {4:N0}" -f $results.Count, $tot, ([long]$Width * $Height * $results.Count), $mx, $bg
} finally { $gpu.Dispose(); $o.Dispose(); $gh.Free() }
