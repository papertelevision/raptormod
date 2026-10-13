# Test-TextureCoverage.ps1 -- does each replacement hold the right picture WHERE THE ROOM'S MODELS SAMPLE IT?
#   .\tools\Test-TextureCoverage.ps1 -Room MINEMAZE [-Hires <folder>] [-Only a.png,b.png -Sheet out.png]
# Run it after installing a room's new textures. Flags: structure (correlation < 0.3), DETAIL MISSING (edge energy < 0.7 of the original's),
# SMOOTH IN n% (8x8 cells where the original has detail and the new art is flat -- catches a strip like MINEMAZE's ramp), DARKER.
# A flagged cell in a near-black region (original mean < ~10) is dither noise, not a problem: check with -Only/-Sheet.
param([string]$Room = 'MINEMAZE', [string]$Sheet = '', [string]$Hires = 'C:\Games\azrael-textures\hires', [string]$Only = '')
# WHERE THE MODEL SAMPLES EACH TEXTURE vs WHAT THE REPLACEMENT HOLDS THERE. For every texture of the room: the UV triangles
# that use it are drawn into a mask at the original's size; inside that mask the original and the installed replacement
# (boxed down to the original's size) are compared -- structure (luminance correlation), detail (edge energy, new / orig) and
# darkness (share of near-black pixels). The MINEMAZE ramp (2026-10-11) was planks in the original but a smooth band in the
# new art across half of the sampled strip: edge energy collapses there, which is what this flags.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Collections.Generic;
public static class UvAudit {
    public static double L(int c) { return 0.3 * ((c >> 16) & 255) + 0.59 * ((c >> 8) & 255) + 0.11 * (c & 255); }
    // the triangles (u,v triples, OBJ v up) into a w x h mask, wrapping outside 0..1
    public static bool[] Mask(List<double[]> tris, int w, int h)
    {
        var m = new bool[w * h];
        foreach (var t in tris)
        {
            double x0 = t[0] * w, y0 = (1 - t[1]) * h, x1 = t[2] * w, y1 = (1 - t[3]) * h, x2 = t[4] * w, y2 = (1 - t[5]) * h;
            int minx = (int)Math.Floor(Math.Min(x0, Math.Min(x1, x2))), maxx = (int)Math.Ceiling(Math.Max(x0, Math.Max(x1, x2)));
            int miny = (int)Math.Floor(Math.Min(y0, Math.Min(y1, y2))), maxy = (int)Math.Ceiling(Math.Max(y0, Math.Max(y1, y2)));
            double d = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0); if (Math.Abs(d) < 1e-9) continue;
            for (int y = miny; y < maxy; y++) for (int x = minx; x < maxx; x++)
            {
                double px = x + 0.5, py = y + 0.5;
                double a = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) / d, b = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) / d, c = 1 - a - b;
                if (a < -0.02 || b < -0.02 || c < -0.02) continue;
                int wx = ((x % w) + w) % w, wy = ((y % h) + h) % h; m[wy * w + wx] = true;
            }
        }
        return m;
    }
    // the replacement boxed down to w x h luminance
    public static double[] Down(int[] p, int pw, int ph, int w, int h)
    {
        var o = new double[w * h]; var n = new int[w * h];
        for (int y = 0; y < ph; y++) { int ty = (int)((long)y * h / ph); for (int x = 0; x < pw; x++) { int tx = (int)((long)x * w / pw); o[ty * w + tx] += L(p[y * pw + x]); n[ty * w + tx]++; } }
        for (int i = 0; i < o.Length; i++) o[i] /= Math.Max(1, n[i]);
        return o;
    }
    public static double[] Lum(int[] p) { var o = new double[p.Length]; for (int i = 0; i < p.Length; i++) o[i] = L(p[i]); return o; }
    // per cell of an 8 x 8 grid (cells with enough sampled texels and real detail in the original): the detail ratio new/orig.
    // Returns [lowest cell ratio, share of the sampled texels in cells under 0.45]
    public static double[] CellRatios(double[] a, double[] b, bool[] m, int w, int h)
    {
        int g = 8; var o = new double[g * g];
        for (int cy = 0; cy < g; cy++) for (int cx = 0; cx < g; cx++)
        {
            int x0 = cx * w / g, x1 = (cx + 1) * w / g, y0 = cy * h / g, y1 = (cy + 1) * h / g; double ea = 0, eb = 0; int n = 0;
            for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { int i = y * w + x; if (!m[i]) continue; n++; if (x + 1 < x1 && m[i + 1]) { ea += Math.Abs(a[i] - a[i + 1]); eb += Math.Abs(b[i] - b[i + 1]); } if (y + 1 < y1 && m[i + w]) { ea += Math.Abs(a[i] - a[i + w]); eb += Math.Abs(b[i] - b[i + w]); } }
            o[cy * g + cx] = (n < 16 || ea / n < 3) ? -1 : eb / ea;
        }
        return o;
    }
    public static double[] Cells(double[] a, double[] b, bool[] m, int w, int h)
    {
        int g = 8; double minR = 99; int badN = 0, allN = 0;
        for (int cy = 0; cy < g; cy++) for (int cx = 0; cx < g; cx++)
        {
            int x0 = cx * w / g, x1 = (cx + 1) * w / g, y0 = cy * h / g, y1 = (cy + 1) * h / g; double ea = 0, eb = 0; int n = 0;
            for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++)
            {
                int i = y * w + x; if (!m[i]) continue; n++;
                if (x + 1 < x1 && m[i + 1]) { ea += Math.Abs(a[i] - a[i + 1]); eb += Math.Abs(b[i] - b[i + 1]); }
                if (y + 1 < y1 && m[i + w]) { ea += Math.Abs(a[i] - a[i + w]); eb += Math.Abs(b[i] - b[i + w]); }
            }
            allN += n;
            if (n < 16 || ea / n < 3) continue;          // too few texels, or the original is flat there (black, plain)
            double r = eb / ea; if (r < minR) minR = r; if (r < 0.45) badN += n;
        }
        return new double[] { minR > 90 ? -1 : minR, allN > 0 ? badN / (double)allN : 0 };
    }
    // [ncc, energy new/orig, dark orig, dark new, masked px]
    public static double[] Compare(double[] a, double[] b, bool[] m, int w, int h)
    {
        double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0, ea = 0, eb = 0; int n = 0, da = 0, db = 0;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
        {
            int i = y * w + x; if (!m[i]) continue; n++;
            sa += a[i]; sb += b[i]; saa += a[i] * a[i]; sbb += b[i] * b[i]; sab += a[i] * b[i];
            if (a[i] < 12) da++; if (b[i] < 12) db++;
            if (x + 1 < w && m[i + 1]) { ea += Math.Abs(a[i] - a[i + 1]); eb += Math.Abs(b[i] - b[i + 1]); }
            if (y + 1 < h && m[i + w]) { ea += Math.Abs(a[i] - a[i + w]); eb += Math.Abs(b[i] - b[i + w]); }
        }
        if (n == 0) return new double[] { 0, 0, 0, 0, 0 };
        double va = saa / n - (sa / n) * (sa / n), vb = sbb / n - (sb / n) * (sb / n), cov = sab / n - (sa / n) * (sb / n);
        return new double[] { cov / Math.Sqrt(Math.Max(1e-9, va * vb)), eb / Math.Max(1e-9, ea), da / (double)n, db / (double)n, n };
    }
}
'@
function Read-Px($path) { $bm = [Drawing.Bitmap]::FromFile($path); $w = $bm.Width; $h = $bm.Height; $c = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb); $g = [Drawing.Graphics]::FromImage($c); $g.DrawImage($bm, 0, 0, $w, $h); $g.Dispose(); $bm.Dispose(); $bd = $c.LockBits((New-Object Drawing.Rectangle 0, 0, $w, $h), 'ReadOnly', 'Format32bppArgb'); $p = New-Object int[] ($w * $h); [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $p, 0, $p.Length); $c.UnlockBits($bd); $c.Dispose(); @{ W = $w; H = $h; P = $p } }
$cache = 'C:\Games\azrael-render'; $hires = $Hires
$map = @{}; $cur = $null; foreach ($l in [IO.File]::ReadAllLines("$cache\$Room.mtl")) { $s = $l.Trim(); if ($s.StartsWith('newmtl ')) { $cur = $s.Substring(7) } elseif ($s.StartsWith('map_Kd ')) { $map[$cur] = $s.Substring(7) } }
$vt = New-Object System.Collections.Generic.List[double[]]; $tris = @{}; $m = ''; $parts = @{}; $o = ''
foreach ($l in [IO.File]::ReadAllLines("$cache\$Room.obj")) {
    if ($l.StartsWith('vt ')) { $q = $l.Substring(3).Trim() -split '\s+'; $vt.Add([double[]]@([double]$q[0], [double]$q[1])) }
    elseif ($l.StartsWith('o ')) { $o = $l.Substring(2) }
    elseif ($l.StartsWith('usemtl ')) { $m = $l.Substring(7) }
    elseif ($l.StartsWith('f ') -and $map.ContainsKey($m)) {
        $leaf = $map[$m]; if (-not $tris[$leaf]) { $tris[$leaf] = New-Object 'System.Collections.Generic.List[double[]]'; $parts[$leaf] = @{} }; $parts[$leaf][$o] = 1
        $c = New-Object System.Collections.Generic.List[double[]]; foreach ($cc in ($l.Substring(2).Trim() -split '\s+')) { $c.Add($vt[[int]($cc.Split('/')[1]) - 1]) }     # (a List: the pipeline would flatten the pairs)
        for ($k = 1; $k -lt $c.Count - 1; $k++) { $tris[$leaf].Add([double[]]@($c[0][0], $c[0][1], $c[$k][0], $c[$k][1], $c[$k + 1][0], $c[$k + 1][1])) }
    }
}
$rows = foreach ($leaf in ($tris.Keys | Sort-Object)) {
    $op = Read-Px "$cache\$leaf"; $hp = "$hires\$leaf"
    $mask = [UvAudit]::Mask($tris[$leaf], $op.W, $op.H)
    # keyed: only the original's solid texels are ever drawn
    for ($i = 0; $i -lt $mask.Length; $i++) { if ((($op.P[$i] -shr 24) -band 255) -lt 128) { $mask[$i] = $false } }
    $uvs = $tris[$leaf]; [double]$umin = 9; [double]$umax = -9; [double]$vmin = 9; [double]$vmax = -9; foreach ($t in $uvs) { foreach ($k in 0, 2, 4) { $umin = [Math]::Min([double]$umin, [double]$t[$k]); $umax = [Math]::Max([double]$umax, [double]$t[$k]); $vmin = [Math]::Min([double]$vmin, [double]$t[$k + 1]); $vmax = [Math]::Max([double]$vmax, [double]$t[$k + 1]) } }
    if (-not (Test-Path -LiteralPath $hp)) { [pscustomobject]@{ Texture = $leaf; Installed = 'NONE'; Parts = ($parts[$leaf].Keys -join ','); Flag = 'no replacement' }; continue }
    $np = Read-Px $hp; $nd = [UvAudit]::Down($np.P, $np.W, $np.H, $op.W, $op.H)
    $lo = [UvAudit]::Lum($op.P); $r = [UvAudit]::Compare($lo, $nd, $mask, $op.W, $op.H); $cl = [UvAudit]::Cells($lo, $nd, $mask, $op.W, $op.H)
    $flag = @(); if ($r[0] -lt 0.3) { $flag += 'structure' }; if ($r[1] -lt 0.7) { $flag += 'DETAIL MISSING' }; if ($cl[1] -gt 0.05) { $flag += ('SMOOTH IN {0:P0} OF IT' -f $cl[1]) }; if ($r[3] - $r[2] -gt 0.2) { $flag += 'DARKER' }
    [pscustomobject]@{ Texture = $leaf; Installed = ('{0}x{1} {2:MM-dd HH:mm}' -f $np.W, $np.H, (Get-Item -LiteralPath $hp).LastWriteTime); Sampled = ('{0:P0}' -f ($r[4] / ($op.W * $op.H))); UV = ('u {0:N2}..{1:N2} v {2:N2}..{3:N2}' -f $umin, $umax, $vmin, $vmax)
        Corr = [Math]::Round($r[0], 2); Detail = [Math]::Round($r[1], 2); DarkOrig = ('{0:P0}' -f $r[2]); DarkNew = ('{0:P0}' -f $r[3]); WorstCell = [Math]::Round($cl[0], 2); Parts = (($parts[$leaf].Keys | Sort-Object) -join ','); Flag = ($flag -join ' ') }
}
$rows | Format-Table Texture, Installed, Sampled, UV, Corr, Detail, WorstCell, DarkOrig, DarkNew, Flag -AutoSize | Out-String -Width 260
if ($Sheet -and $Only) {
    $want = $Only.Split(','); $cell = 300; $sh = New-Object Drawing.Bitmap ($cell * 3 + 40), ($want.Count * ($cell + 24) + 10); $gg = [Drawing.Graphics]::FromImage($sh); $gg.Clear([Drawing.Color]::DimGray)
    $fnt = New-Object Drawing.Font 'Consolas', 10; $red = New-Object Drawing.Pen ([Drawing.Color]::Red), 2
    for ($k = 0; $k -lt $want.Count; $k++) {
        $leaf = $want[$k]; $y = 20 + $k * ($cell + 24); $gg.DrawString($leaf, $fnt, [Drawing.Brushes]::White, 10, $y - 17)
        $op = Read-Px "$cache\$leaf"; $np = Read-Px "$hires\$leaf"; $mask = [UvAudit]::Mask($tris[$leaf], $op.W, $op.H)
        for ($i = 0; $i -lt $mask.Length; $i++) { if ((($op.P[$i] -shr 24) -band 255) -lt 128) { $mask[$i] = $false } }
        $nd = [UvAudit]::Down($np.P, $np.W, $np.H, $op.W, $op.H); $cr = [UvAudit]::CellRatios([UvAudit]::Lum($op.P), $nd, $mask, $op.W, $op.H)
        $a = [Drawing.Image]::FromFile("$cache\$leaf"); $gg.InterpolationMode = 'NearestNeighbor'; $gg.DrawImage($a, 10, $y, $cell, $cell); $a.Dispose()
        $b = [Drawing.Image]::FromFile("$hires\$leaf"); $gg.InterpolationMode = 'HighQualityBicubic'; $gg.DrawImage($b, 20 + $cell, $y, $cell, $cell); $gg.DrawImage($b, 30 + 2 * $cell, $y, $cell, $cell); $b.Dispose()
        $mb = New-Object Drawing.Bitmap $op.W, $op.H; for ($i = 0; $i -lt $mask.Length; $i++) { if (-not $mask[$i]) { $mb.SetPixel($i % $op.W, [int][Math]::Floor($i / $op.W), [Drawing.Color]::FromArgb(170, 0, 0, 0)) } }
        $gg.InterpolationMode = 'NearestNeighbor'; $gg.DrawImage($mb, 30 + 2 * $cell, $y, $cell, $cell); $mb.Dispose()
        for ($c = 0; $c -lt 64; $c++) { if ($cr[$c] -ge 0 -and $cr[$c] -lt 0.45) { $gg.DrawRectangle($red, [int](30 + 2 * $cell + ($c % 8) * $cell / 8), [int]($y + [Math]::Floor($c / 8) * $cell / 8), [int]($cell / 8), [int]($cell / 8)) } }
    }
    $gg.Dispose(); $sh.Save($Sheet); $sh.Dispose(); "sheet: $Sheet (original | replacement | replacement with the unsampled area darkened and the smooth cells in red)"
}