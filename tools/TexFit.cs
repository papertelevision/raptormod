using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// TexFit.cs -- tools\Fit-RoomTextures.ps1's measuring half (2026-10-08). How far a redrawn texture has drifted from the original: both reduced to N x N luminance, then the scale (sx, sy) and
// shift (dx, dy) that best map the new one onto the original, by normalised cross-correlation of their edges.
namespace AztTool {
public static class TexFit
{
    public static float[] Lum(string path, int n)
    {
        using (var src = new Bitmap(path))
        using (var b = new Bitmap(n, n, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(b)) { g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic; g.DrawImage(src, 0, 0, n, n); }
            var d = b.LockBits(new Rectangle(0, 0, n, n), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var px = new int[n * n]; Marshal.Copy(d.Scan0, px, 0, px.Length); b.UnlockBits(d);
            var l = new float[n * n];
            for (int i = 0; i < l.Length; i++) { int c = px[i]; l[i] = 0.3f * ((c >> 16) & 255) + 0.59f * ((c >> 8) & 255) + 0.11f * (c & 255); }
            return l;
        }
    }
    // edge strength: what has to line up (outlines, holes, borders), not the colours
    public static float[] Edges(float[] l, int n)
    {
        var e = new float[n * n];
        for (int y = 1; y < n - 1; y++) for (int x = 1; x < n - 1; x++)
        {
            float gx = l[y * n + x + 1] - l[y * n + x - 1], gy = l[(y + 1) * n + x] - l[(y - 1) * n + x];
            e[y * n + x] = (float)Math.Sqrt(gx * gx + gy * gy);
        }
        return e;
    }
    static float Sample(float[] a, int n, float x, float y)
    {
        int ix = (int)Math.Floor(x), iy = (int)Math.Floor(y); if (ix < 0 || iy < 0 || ix >= n - 1 || iy >= n - 1) return 0f;
        float fx = x - ix, fy = y - iy;
        return (a[iy * n + ix] * (1 - fx) + a[iy * n + ix + 1] * fx) * (1 - fy) + (a[(iy + 1) * n + ix] * (1 - fx) + a[(iy + 1) * n + ix + 1] * fx) * fy;
    }
    static double Ncc(float[] a, float[] b, int n, double sx, double sy, double dx, double dy)
    {
        // original pixel (x, y) <- new pixel ((x - c - dx) / sx + c, ...): scale about the centre, then shift
        double c = n * 0.5, sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0; int k = 0;
        for (int y = 4; y < n - 4; y++) for (int x = 4; x < n - 4; x++)
        {
            double va = a[y * n + x], vb = Sample(b, n, (float)((x - c - dx) / sx + c), (float)((y - c - dy) / sy + c));
            sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb; k++;
        }
        double ma = sa / k, mb = sb / k, cov = sab / k - ma * mb, va2 = saa / k - ma * ma, vb2 = sbb / k - mb * mb;
        return cov / Math.Sqrt(Math.Max(va2 * vb2, 1e-9));
    }
    /// <summary>Fit at 128 then refine at n (shift in pixels of n): {ncc identity, best, sx, sy, dx, dy}.</summary>
    public static double[] FitFine(string orig, string neu, int n)
    {
        var r = Fit(orig, neu, 128); double k = n / 128.0;
        var a = Edges(Lum(orig, n), n); var b = Edges(Lum(neu, n), n);
        double best = Ncc(a, b, n, r[2], r[3], r[4] * k, r[5] * k), bsx = r[2], bsy = r[3], bdx = r[4] * k, bdy = r[5] * k;
        double csx = bsx, csy = bsy, cdx = bdx, cdy = bdy;
        for (double sx = csx - 0.012; sx <= csx + 0.0121; sx += 0.004) for (double sy = csy - 0.012; sy <= csy + 0.0121; sy += 0.004)
            for (double dx = cdx - k; dx <= cdx + k + 0.01; dx += 0.5) for (double dy = cdy - k; dy <= cdy + k + 0.01; dy += 0.5)
            { double v = Ncc(a, b, n, sx, sy, dx, dy); if (v > best) { best = v; bsx = sx; bsy = sy; bdx = dx; bdy = dy; } }
        return new[] { Ncc(a, b, n, 1, 1, 0, 0), best, bsx, bsy, bdx, bdy };
    }
    /// <summary>{ncc at identity, best ncc, sx, sy, dx, dy} with dx, dy in pixels of an n-pixel image.</summary>
    public static double[] Fit(string orig, string neu, int n)
    {
        var a = Edges(Lum(orig, n), n); var b = Edges(Lum(neu, n), n);
        double id = Ncc(a, b, n, 1, 1, 0, 0);
        double best = -2, bsx = 1, bsy = 1, bdx = 0, bdy = 0;
        // coarse, then fine
        for (double sx = 0.80; sx <= 1.201; sx += 0.04) for (double sy = 0.80; sy <= 1.201; sy += 0.04)
            for (int dx = -n / 8; dx <= n / 8; dx += 2) for (int dy = -n / 8; dy <= n / 8; dy += 2)
            { double v = Ncc(a, b, n, sx, sy, dx, dy); if (v > best) { best = v; bsx = sx; bsy = sy; bdx = dx; bdy = dy; } }
        double csx = bsx, csy = bsy, cdx = bdx, cdy = bdy;
        for (double sx = csx - 0.04; sx <= csx + 0.041; sx += 0.01) for (double sy = csy - 0.04; sy <= csy + 0.041; sy += 0.01)
            for (double dx = cdx - 2; dx <= cdx + 2.01; dx += 0.5) for (double dy = cdy - 2; dy <= cdy + 2.01; dy += 0.5)
            { double v = Ncc(a, b, n, sx, sy, dx, dy); if (v > best) { best = v; bsx = sx; bsy = sy; bdx = dx; bdy = dy; } }
        return new[] { id, best, bsx, bsy, bdx, bdy };
    }
}

}
