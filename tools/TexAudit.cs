// TexAudit.cs -- PHASE 3's AUDIT (Josh, 2026-10-12: "A seamless-texture audit for every room ... flag textures whose edges are
// dark or don't match where a model repeats them, so we catch the next 'rope pipe' before you see it in game" and "Fix badly
// stretched textures"): how each room's models lay each texture -- how many times a face repeats it, where it is stretched
// far more one way than the other (or laid as a single line: a smear) -- and, for the art itself, whether its edges are dark
// or do not meet, which a repeat shows as a stripe. Used by tools\Test-TextureTiling.ps1.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

namespace AztTool
{
    public static class TexAudit
    {
        public sealed class MatStats
        {
            public string Material, Leaf; public int Faces, StretchFaces, SmearFaces, RepeatFaces, BadFaces;
            public double Area, StretchArea, SmearArea, RepeatArea, BadArea, MaxSpanU, MaxSpanV, MaxShear;
        }
        public static bool Bad(double[] t) { return !(Math.Abs(t[0]) < 1e4) || !(Math.Abs(t[1]) < 1e4); }
        static double D(string s) { return double.Parse(s, NumberStyles.Float, CultureInfo.InvariantCulture); }
        /// <summary>One room's OBJ (+ its MTL): per material, its faces' repeats and stretch. texW/texH: the art's size in texels
        /// for a material's leaf (null = 256), so stretch is judged in texels. Stretched = one way over `stretchK` times as many
        /// world units per texel as the other; a smear = its texture coordinates in a line (no area).</summary>
        public static int[] PngSize(string path)
        {
            try
            {
                using (var f = File.OpenRead(path))
                {
                    var b = new byte[24]; if (f.Read(b, 0, 24) < 24) return null;
                    return new[] { (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19], (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23] };
                }
            }
            catch { return null; }
        }
        /// <summary>The same, the art's sizes read from the original PNGs in texDir (leaf + ".png").</summary>
        public static List<MatStats> Room(string objPath, string mtlPath, string texDir, double stretchK)
        {
            var cache = new Dictionary<string, int[]>();
            return Room(objPath, mtlPath, leaf => { int[] s; if (!cache.TryGetValue(leaf, out s)) { s = PngSize(Path.Combine(texDir, leaf + ".png")); cache[leaf] = s; } return s; }, stretchK);
        }
        public static List<MatStats> Room(string objPath, string mtlPath, Func<string, int[]> texSize, double stretchK)
        {
            var leafOf = new Dictionary<string, string>(); string cur = null;
            foreach (var l0 in File.ReadAllLines(mtlPath))
            {
                var l = l0.Trim();
                if (l.StartsWith("newmtl ")) cur = l.Substring(7).Trim();
                else if (l.StartsWith("map_Kd ") && cur != null) leafOf[cur] = Path.GetFileNameWithoutExtension(l.Substring(7).Trim());
            }
            var v = new List<double[]>(); var vt = new List<double[]>(); var stats = new Dictionary<string, MatStats>(); string mat = null;
            foreach (var l0 in File.ReadLines(objPath))
            {
                if (l0.StartsWith("v ")) { var p = l0.Substring(2).Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries); v.Add(new[] { D(p[0]), D(p[1]), D(p[2]) }); }
                else if (l0.StartsWith("vt ")) { var p = l0.Substring(3).Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries); vt.Add(new[] { D(p[0]), D(p[1]) }); }
                else if (l0.StartsWith("usemtl ")) mat = l0.Substring(7).Trim();
                else if (l0.StartsWith("f ") && mat != null && leafOf.ContainsKey(mat))
                {
                    var p = l0.Substring(2).Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                    if (p.Length < 3) continue;
                    MatStats s; if (!stats.TryGetValue(mat, out s)) { s = new MatStats { Material = mat, Leaf = leafOf[mat] }; stats[mat] = s; }
                    var sz = texSize(leafOf[mat]) ?? new[] { 256, 256 };
                    int[] vi = new int[p.Length], ti = new int[p.Length];
                    for (int k = 0; k < p.Length; k++) { var q = p[k].Split('/'); vi[k] = int.Parse(q[0]) - 1; ti[k] = q.Length > 1 && q[1].Length > 0 ? int.Parse(q[1]) - 1 : -1; }
                    for (int k = 1; k + 1 < p.Length; k++) Face(s, v[vi[0]], v[vi[k]], v[vi[k + 1]], ti[0] >= 0 ? vt[ti[0]] : null, ti[k] >= 0 ? vt[ti[k]] : null, ti[k + 1] >= 0 ? vt[ti[k + 1]] : null, sz[0], sz[1], stretchK);
                }
            }
            return new List<MatStats>(stats.Values);
        }
        static void Face(MatStats s, double[] a, double[] b, double[] c, double[] ta, double[] tb, double[] tc, int tw, int th, double stretchK)
        {
            if (ta == null || tb == null || tc == null) return;
            double e1x = b[0] - a[0], e1y = b[1] - a[1], e1z = b[2] - a[2], e2x = c[0] - a[0], e2y = c[1] - a[1], e2z = c[2] - a[2];
            double cx = e1y * e2z - e1z * e2y, cy = e1z * e2x - e1x * e2z, cz = e1x * e2y - e1y * e2x;
            double area = 0.5 * Math.Sqrt(cx * cx + cy * cy + cz * cz); if (area < 1e-6) return;
            s.Faces++; s.Area += area;
            // texture coordinates that are not numbers anyone meant (the 1996 files hold uninitialised ones, -1.7e38): the face
            // shows one texel of the art, flat
            if (Bad(ta) || Bad(tb) || Bad(tc)) { s.BadFaces++; s.BadArea += area; return; }
            double su = Math.Max(ta[0], Math.Max(tb[0], tc[0])) - Math.Min(ta[0], Math.Min(tb[0], tc[0]));
            double sv = Math.Max(ta[1], Math.Max(tb[1], tc[1])) - Math.Min(ta[1], Math.Min(tb[1], tc[1]));
            s.MaxSpanU = Math.Max(s.MaxSpanU, su); s.MaxSpanV = Math.Max(s.MaxSpanV, sv);
            if (su > 1.05 || sv > 1.05) { s.RepeatFaces++; s.RepeatArea += area; }
            // texels per world unit along each texture direction: solve the face's world edges for dP/du and dP/dv
            double du1 = (tb[0] - ta[0]) * tw, dv1 = (tb[1] - ta[1]) * th, du2 = (tc[0] - ta[0]) * tw, dv2 = (tc[1] - ta[1]) * th;
            double det = du1 * dv2 - du2 * dv1;
            double texArea = Math.Abs(det) * 0.5;
            if (texArea < 1e-3 * Math.Max(1.0, area))
            {   // its texture coordinates (nearly) in a line: the art smeared across the face
                if (area > 20) { s.SmearFaces++; s.SmearArea += area; }
                return;
            }
            double pux = (e1x * dv2 - e2x * dv1) / det, puy = (e1y * dv2 - e2y * dv1) / det, puz = (e1z * dv2 - e2z * dv1) / det;
            double pvx = (e2x * du1 - e1x * du2) / det, pvy = (e2y * du1 - e1y * du2) / det, pvz = (e2z * du1 - e1z * du2) / det;
            double lu = Math.Sqrt(pux * pux + puy * puy + puz * puz), lv = Math.Sqrt(pvx * pvx + pvy * pvy + pvz * pvz);
            double an = Math.Max(lu, lv) / Math.Max(1e-12, Math.Min(lu, lv));
            double shear = Math.Abs(pux * pvx + puy * pvy + puz * pvz) / Math.Max(1e-12, lu * lv);
            s.MaxShear = Math.Max(s.MaxShear, shear);
            if (an > stretchK && area > 20) { s.StretchFaces++; s.StretchArea += area; }
        }

        /// <summary>The art's edges (at most 256 across): each side's band (6% deep) against the middle's brightness (0..1 = how
        /// dark the band is relative to it), and how far the opposite edges are from meeting (mean |difference| of the outermost
        /// rows / columns, over the middle's mean brightness). [top, bottom, left, right, mismatch top-bottom, mismatch left-right,
        /// middle's mean brightness 0..255, share of the picture near black (cut-out art: a rope or chain on its holes)]</summary>
        public static double[] Edges(string png)
        {
            int w, h; int[] px;
            using (var src = (Bitmap)Image.FromFile(png))
            {
                double k = Math.Min(1.0, 256.0 / Math.Max(src.Width, src.Height)); w = Math.Max(4, (int)Math.Round(src.Width * k)); h = Math.Max(4, (int)Math.Round(src.Height * k));
                using (var bm = new Bitmap(w, h, PixelFormat.Format32bppArgb))
                {
                    using (var g = Graphics.FromImage(bm)) { g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear; g.DrawImage(src, 0, 0, w, h); }
                    var bd = bm.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                    px = new int[w * h];
                    try { for (int y = 0; y < h; y++) Marshal.Copy(new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), px, y * w, w); } finally { bm.UnlockBits(bd); }
                }
            }
            Func<int, double> L = c => 0.30 * ((c >> 16) & 255) + 0.59 * ((c >> 8) & 255) + 0.11 * (c & 255);
            Func<int, int, int, int, double> Mean = (x0, y0, x1, y1) => { double s = 0; int n = 0; for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { s += L(px[y * w + x]); n++; } return n > 0 ? s / n : 0; };
            int bx = Math.Max(1, (int)(w * 0.06)), by = Math.Max(1, (int)(h * 0.06));
            double mid = Mean(w / 4, h / 4, w * 3 / 4, h * 3 / 4), m = Math.Max(mid, 1);
            double top = Mean(0, 0, w, by) / m, bot = Mean(0, h - by, w, h) / m, left = Mean(0, 0, bx, h) / m, right = Mean(w - bx, 0, w, h) / m;
            double tbm = 0; for (int x = 0; x < w; x++) tbm += Math.Abs(L(px[x]) - L(px[(h - 1) * w + x])); tbm /= w * m;
            double lrm = 0; for (int y = 0; y < h; y++) lrm += Math.Abs(L(px[y * w]) - L(px[y * w + w - 1])); lrm /= h * m;
            int dark = 0; for (int i = 0; i < px.Length; i++) if (L(px[i]) < 8) dark++;
            return new[] { top, bot, left, right, tbm, lrm, mid, dark / (double)px.Length };
        }
    }
}
