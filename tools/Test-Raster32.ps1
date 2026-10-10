# Test-Raster32.ps1 -- the true-colour pixel path against the 8-bit one, without a game.
#
#   .\tools\Test-Raster32.ps1
#   .\tools\Test-Raster32.ps1 -Rooms SPAROOM -Save
#
# Each room is loaded as the watcher loads it, given its painted textures (Add-AztRgb), and
# drawn from a ring of cameras twice with the helmet lamp on: once the 8-bit way (filtered,
# through the light table) and once in true colour. Reported per room:
#   * COVERAGE must be identical -- the same pixels drawn, the same depth buffer. True colour
#     changes what colour a pixel is, never whether a triangle owns it.
#   * how far apart the two pictures are on average (they should be close: same art, same
#     light), and how many distinct colours each uses.
#   * the time for each.
# -Save writes side-by-side PNGs (8-bit left, true colour right) to -OutDir.
param(
    [string[]]$Rooms = @('CORICORI', 'SPAROOM', 'MINEHEAD'),
    [int]$W = 1600, [int]$H = 928, [double]$Fov = 50,
    [switch]$Save, [string]$OutDir = 'C:\Games\azrael-render\tc-test',
    [string]$TexDir   = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$Palette  = 'C:\Games\azrael-inject\azrael-palette.pal'
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
. (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'),
                 (Join-Path $toolDir 'SceneGraph.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System; using System.Collections.Generic;
public static class Tc32Test {
    public static int[] Expand(byte[] c, byte[] pal) { var o = new int[c.Length]; for (int i = 0; i < c.Length; i++) { int k = c[i] * 3; o[i] = (pal[k] << 16) | (pal[k+1] << 8) | pal[k+2]; } return o; }
    public static double MeanDiff(int[] a, int[] b, byte[] drawn) { long s = 0, n = 0; for (int i = 0; i < a.Length; i++) { if (drawn[i] == 0) continue; n++;
        s += Math.Abs(((a[i] >> 16) & 255) - ((b[i] >> 16) & 255)) + Math.Abs(((a[i] >> 8) & 255) - ((b[i] >> 8) & 255)) + Math.Abs((a[i] & 255) - (b[i] & 255)); } return n == 0 ? 0 : s / (3.0 * n); }
    public static int Distinct(int[] a) { var h = new HashSet<int>(a); return h.Count; }
    public static int CoverageDiff(byte[] a, byte[] b) { int n = 0; for (int i = 0; i < a.Length; i++) if ((a[i] == 0) != (b[i] == 0)) n++; return n; }
    public static void SavePair(string path, int[] l, int[] r, int w, int h) {
        using (var bm = new System.Drawing.Bitmap(w * 2, h, System.Drawing.Imaging.PixelFormat.Format32bppRgb)) {
            var bd = bm.LockBits(new System.Drawing.Rectangle(0, 0, w * 2, h), System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppRgb);
            for (int y = 0; y < h; y++) { System.Runtime.InteropServices.Marshal.Copy(l, y * w, new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), w);
                                          System.Runtime.InteropServices.Marshal.Copy(r, y * w, new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride + w * 4), w); }
            bm.UnlockBits(bd); bm.Save(path, System.Drawing.Imaging.ImageFormat.Png); } }
}
'@
$pal = [IO.File]::ReadAllBytes($Palette); $lut = [AztTool.Raster]::BuildRgbLut($pal)
$light = [AztTool.Raster]::BuildLightTable($pal, 76, [single]2.4)
function New-Ras {
    $q = New-Object AztTool.Raster($W, $H); $q.NearZ = [single]0.5; $q.SetVerticalFov($Fov)
    $q.SetLightTable($light, 76, [single]2.4)
    $q.LampHalo = [single]0.495; $q.LampHaloInnerDeg = [single]10; $q.LampHaloDeg = [single]24
    $q.LampRoom = [single]0.54; $q.LampPower = [single]1.68; $q.LampRange = [single]550
    $q.LampInnerDeg = [single]8.64; $q.LampOuterDeg = [single]21; $q.Lamp = $true
    return $q
}
# unfiltered: the 8-bit texture filter picks one of four texels by a screen pattern, and at the
# edge of a hole in a texture that changes which pixels are drawn -- a difference of its own, not of true colour
$r8 = New-Ras; $r8.Filter = $false
$r32 = New-Ras; $r32.EnableRgb()
if ($Save) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
$fail = 0
foreach ($name in $Rooms) {
    $room = Import-AztRoom -Rooms @($name) -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette -Width $W -Height $H
    [AztTool.Raster]::EnsureMips($room.Texes, $pal, $lut)
    $st = Add-AztRgb -Names @($name) -CacheDir $CacheDir -Pal $pal
    [AztTool.Raster]::EnsureRgb($room.Texes, $pal)
    $v = $room.V; $nv = $v.Length / 3
    $mn = @([single]::MaxValue) * 3; $mx = @([single]::MinValue) * 3
    for ($i = 0; $i -lt $nv; $i++) { for ($k = 0; $k -lt 3; $k++) { $c = $v[$i*3+$k]; if ($c -lt $mn[$k]) { $mn[$k] = $c }; if ($c -gt $mx[$k]) { $mx[$k] = $c } } }
    $cx = ($mn[0]+$mx[0])/2; $cy = ($mn[1]+$mx[1])/2; $cz = ($mn[2]+$mx[2])/2; $rx = ($mx[0]-$mn[0])/2; $rz = ($mx[2]-$mn[2])/2
    $eyes = @(@($cx,$cy,$cz), @(($cx+$rx/3),$cy,$cz), @($cx,$cy,($cz-$rz/3)))
    $t8 = @(); $t32 = @(); $cov = 0; $diff = @(); $d8 = 0; $d32 = 0; $cams = 0; $depthBad = 0
    foreach ($e in $eyes) {
        for ($yaw = 0; $yaw -lt 360; $yaw += 90) {
            $a = $yaw * [Math]::PI / 180
            foreach ($q in $r8, $r32) { $q.LookAt([single]$e[0], [single]$e[1], [single]$e[2], [single]($e[0] + [Math]::Sin($a) * 100), [single]($e[1] - 10), [single]($e[2] + [Math]::Cos($a) * 100), 1) }
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $r8.FastClear([byte]0); $r8.DrawTexturedFast($v, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true); $t8 += $clock.Elapsed.TotalMilliseconds
            $clock.Restart()
            $r32.FastClear([byte]0); $r32.DrawTexturedFast($v, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true); $t32 += $clock.Elapsed.TotalMilliseconds
            $cams++
            $cov += [Tc32Test]::CoverageDiff($r8.Color, $r32.Color)
            if (-not [System.Linq.Enumerable]::SequenceEqual([single[]]$r8.Depth, [single[]]$r32.Depth)) { $depthBad++ }
            $left = [Tc32Test]::Expand($r8.Color, $pal)
            $diff += [Tc32Test]::MeanDiff($left, $r32.Color32, $r32.Color)
            $d8 = [Math]::Max($d8, [Tc32Test]::Distinct($left)); $d32 = [Math]::Max($d32, [Tc32Test]::Distinct($r32.Color32))
            if ($Save) { [Tc32Test]::SavePair((Join-Path $OutDir ("{0}-{1}-{2}.png" -f $name, $eyes.IndexOf($e), $yaw)), $left, $r32.Color32, $W, $H) }
        }
    }
    $ok = ($cov -eq 0 -and $depthBad -eq 0); if (-not $ok) { $fail++ }
    Write-Host ("{0,-9} {1} cameras; textures: {2} painted, {3} from the palette{4}" -f $name, $cams, $st.FromFile, $st.FromPalette, $(if ($st.Bad.Count) { '  ** ORDER FAILED: ' + ($st.Bad -join ',') } else { '' }))
    Write-Host ("          coverage differs on {0} pixels, depth on {1} cameras  -> {2}" -f $cov, $depthBad, $(if ($ok) { 'identical' } else { 'DIFFERENT' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    Write-Host ("          mean difference per channel {0:N1} of 255; colours in a frame: up to {1} (8-bit) vs {2:N0} (true colour)" -f (($diff | Measure-Object -Average).Average), $d8, $d32)
    Write-Host ("          8-bit {0:N1} ms, true colour {1:N1} ms (median)" -f (($t8 | Sort-Object)[[int]($t8.Count/2)]), (($t32 | Sort-Object)[[int]($t32.Count/2)]))
}
if ($fail) { exit 1 }
