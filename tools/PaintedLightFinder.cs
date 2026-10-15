// PaintedLightFinder.cs -- the PAINTED-LIGHT FINDER for Room Review (Josh, 2026-10-14: "search every room's art for painted
// light like CHAMBNEW's spotlights and drop suggested pins. You'd approve each one, so you still place every light").
// Used by tools\Suggest-PaintedLights.ps1 ([[azrael-room-review]]).
//
//  1. Analyse(png): the ORIGINAL 1996 art (never the hi-res copies: the light is painted into the palette art). The texture's
//     brightness, smoothed, against its OWN median: the patches clearly brighter than the rest are blobs. Each is classified:
//       cone    -- a spotlight fan: one side of the blob (and the strip past it) clearly brighter than the other; the SOURCE
//                  is the blob's bright end, the FADE runs the other way (CHAMBNEW 08-chwall: three uplight cones a wall);
//       window  -- a bright patch crossed by a grid of dark bars (BAPTIST 25-bapleft1, MINEHEAD 37-mineplab);
//       pool    -- a round bright patch with no direction (a glow, a lit patch).
//     Small highlights (under ~0.3% of the art), huge washes (more than a third of it) and weak contrast are dropped.
//  2. PlMesh: a room's OBJ (Export-XafObj: room coordinates, the same space as the lights). Locate() finds EVERY face that
//     shows a texture point -- the faces' UVs may tile past 0..1, so the point is tried at every whole-number shift inside
//     the UV triangle's range -- with the world point, the face's +u/+v directions in the world (so a texture's fade can be
//     turned into up/down/sideways), and the normal turned to the side the room is on: rays along both sides (a short fan
//     each); the side whose rays escape into the void is outside (walls are one-sided shells), ties go to the OBJ normal.
//  3. Ray() / Floor(): distances to the room's surfaces, for the floor under an uplight and the ceiling over a downlight.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

namespace AztTool
{
    public class PlBlob
    {
        public string Kind;                 // cone | window | pool
        public double U, V;                 // the source point in OBJ uv (v up: row 0 of the PNG is v = 1)
        public double FU, FV;               // a cone's fade direction in uv (unit; 0,0 otherwise)
        public double U0, V0, U1, V1;       // the blob's box in uv
        public double Area;                 // share of the texture's art
        public double Contrast;             // the blob's mean brightness over the texture's median
        public double Throw;                // a cone's one-sidedness (0..1+)
        public double Fill;                 // pixels / box
        public double Elong;                // a cone: its length along the throw over its width
        public double Peak, Halo;           // a glow: centre over rim, and the ring outside it over the art (both in shares of its lift)
        public double ThrowStrip, ThrowLit;  // a cone: the lit strip past its end over the dark one past its source; that strip over the art (shares of its lift)
        public double Broad;                // the broad (heavily smoothed) brightness at its centre over the art, in shares of its lift
        public double Score;                // 0..1, the texture-level confidence
        public int R, G, B;                 // the painted light's colour (brightest third of the blob, raw)
        public int Bars;                    // a window's dark bars counted across it (both ways)
        public int X0, Y0, X1, Y1, Px, Py;  // pixels
        public double Median;
        public int BR, BG, BB;              // the art's own middle colour (pixels round its median brightness): the light is lit / base
        public override string ToString() { return string.Format(CultureInfo.InvariantCulture, "{0} uv({1:0.000},{2:0.000}) fade({3:0.00},{4:0.00}) area {5:0.0000} con {6:0.00} throw {7:0.00} fill {8:0.00} bars {9} score {10:0.00} px({11},{12}) box {13},{14}-{15},{16}", Kind, U, V, FU, FV, Area, Contrast, Throw, Fill, Bars, Score, Px, Py, X0, Y0, X1, Y1) + string.Format(CultureInfo.InvariantCulture, " elong {0:0.00} peak {1:0.00} halo {2:0.00} strip {3:0.00} lit {4:0.00} broad {5:0.00}", Elong, Peak, Halo, ThrowStrip, ThrowLit, Broad); }
    }

    public class PlHit
    {
        public int Tri; public double X, Y, Z;        // the world point
        public double NX, NY, NZ;                     // the normal, toward the room
        public double DuX, DuY, DuZ, DvX, DvY, DvZ;   // world change per unit u and per unit v on this face
        public double SU, SV;                         // the uv point actually used (shifted into the triangle's range)
        public int OrientVotes;                       // how sure the side test was (rays escaping on the outside)
    }

    public static class PaintedLightFinder
    {
        // ---- 1. the texture -------------------------------------------------------------------------------------------
        public static int LastW, LastH; public static double LastMedian, LastP90, LastP99;

        public static PlBlob[] Analyse(string path, bool keyed, string debugPng)
        {
            Bitmap bmp;
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) { bmp = new Bitmap(fs); }
            int W = bmp.Width, H = bmp.Height; LastW = W; LastH = H;
            var px = new int[W * H];
            var bd = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try { for (int y = 0; y < H; y++) Marshal.Copy(bd.Scan0 + y * bd.Stride, px, y * W, W); } finally { bmp.UnlockBits(bd); bmp.Dispose(); }
            var res = new List<PlBlob>();
            if (W < 16 || H < 16) return res.ToArray();
            var L = new float[W * H]; var ok = new bool[W * H]; var lv = new List<float>(W * H);
            for (int i = 0; i < px.Length; i++)
            {
                int c = px[i], a = (c >> 24) & 255, r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
                L[i] = 0.299f * r + 0.587f * g + 0.114f * b;
                ok[i] = !keyed || a >= 128;
                // (padding: many textures sit in a pure black frame -- not art, so not in the median)
                if (ok[i] && L[i] >= 4) lv.Add(L[i]);
            }
            if (lv.Count < W * H / 6) return res.ToArray();
            lv.Sort();
            double med = lv[lv.Count / 2], p90 = lv[(int)(lv.Count * 0.90)], p99 = lv[(int)(lv.Count * 0.99)];
            LastMedian = med; LastP90 = p90; LastP99 = p99;
            double artArea = lv.Count;
            var lab = new int[W * H]; var res2 = new List<PlBlob>();

            // ---- WINDOWS first, on a coarse smoothing (the panes run together into one patch), tested on the raw pixels
            // for a grid of dark bars both ways; their boxes are then left out of the finer search
            int rw = Math.Max(2, (int)Math.Round(Math.Min(W, H) / 40.0));
            var SW = Blur(Blur(L, ok, W, H, rw), ok, W, H, rw);
            double TW = Math.Max(Math.Max(med + 20, med * 1.5), med + 0.30 * (p99 - med)); if (TW > 240) TW = 240;
            var inWin = new bool[W * H];
            foreach (var pix in Components(SW, ok, W, H, TW, null))
            {
                var wb = WindowBlob(pix, L, SW, ok, px, W, H, med, artArea);
                if (wb == null) continue;
                res2.Add(wb);
                for (int y = Math.Max(0, wb.Y0 - 2); y <= Math.Min(H - 1, wb.Y1 + 2); y++) for (int x = Math.Max(0, wb.X0 - 2); x <= Math.Min(W - 1, wb.X1 + 2); x++) inWin[y * W + x] = true;
                foreach (int p in pix) lab[p] = 1;
            }

            // ---- cones and pools: a finer smoothing (a painted light is a broad shape: noise and fine detail go), brighter
            // than the texture's own level by a clear margin; touching lights are pulled apart at their dimmer necks
            int rad = Math.Max(1, (int)Math.Round(Math.Min(W, H) / 85.0));
            var S = Blur(Blur(L, ok, W, H, rad), ok, W, H, rad);
            // ...and the BROAD light of the art (a sixteenth of it across): painted light is a large, smooth swell of brightness;
            // a pale stone or a lit tile among dark ones averages away at this scale
            int rc = Math.Max(3, (int)Math.Round(Math.Min(W, H) / 16.0));
            var SC = Blur(Blur(L, ok, W, H, rc), ok, W, H, rc);
            double T = Math.Max(Math.Max(med + 24, med * 1.6), med + 0.42 * (p99 - med));
            if (T > 245) T = 245;
            foreach (var pix0 in Components(S, ok, W, H, T, inWin))
            {
                foreach (var pix in Split(pix0, S, W, H, T, artArea, 0))
                {
                    var bl = Describe(pix, L, S, ok, px, W, H, med, artArea, T, SC);
                    if (bl == null) continue;
                    res2.Add(bl); foreach (int p in pix) lab[p] = 2;
                }
            }
            // the art's own middle colour (the pixels between its 35th and 65th brightness percentiles)
            double l35 = lv[(int)(lv.Count * 0.35)], l65 = lv[(int)(lv.Count * 0.65)], br = 0, bg = 0, bb = 0; int bn = 0;
            for (int i = 0; i < px.Length; i++) { if (!ok[i] || L[i] < l35 || L[i] > l65) continue; int c = px[i]; br += (c >> 16) & 255; bg += (c >> 8) & 255; bb += c & 255; bn++; }
            foreach (var b in res2) if (bn > 0) { b.BR = (int)(br / bn); b.BG = (int)(bg / bn); b.BB = (int)(bb / bn); }
            res.AddRange(res2);
            if (!string.IsNullOrEmpty(debugPng)) SaveDebug(debugPng, px, W, H, lab, res);
            return res.ToArray();
        }

        // 8-connected patches of S above T (pixels in 'skip' left out)
        static List<List<int>> Components(float[] S, bool[] ok, int W, int H, double T, bool[] skip)
        {
            var outp = new List<List<int>>(); var seen = new bool[W * H]; var stack = new Stack<int>();
            for (int s0 = 0; s0 < S.Length; s0++)
            {
                if (seen[s0] || !ok[s0] || S[s0] <= T || (skip != null && skip[s0])) continue;
                seen[s0] = true; stack.Push(s0); var pix = new List<int>();
                while (stack.Count > 0)
                {
                    int p = stack.Pop(); pix.Add(p); int x = p % W, y = p / W;
                    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++)
                    {
                        int xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
                        int q = yy * W + xx; if (!seen[q] && ok[q] && S[q] > T && (skip == null || !skip[q])) { seen[q] = true; stack.Push(q); }
                    }
                }
                outp.Add(pix);
            }
            return outp;
        }

        // two painted lights side by side merge into one patch at the base threshold: raise it in steps toward the patch's
        // peak; once the patch falls into two or more cores of real size, every pixel goes to the core it reaches first
        // (grown back out through the patch), so each light keeps its own whole shape
        static List<List<int>> Split(List<int> pix, float[] S, int W, int H, double T, double artArea, int depth)
        {
            var one = new List<List<int>> { pix };
            if (depth > 2 || pix.Count < 2 * 0.003 * artArea) return one;
            double peak = 0; foreach (int p in pix) if (S[p] > peak) peak = S[p];
            var member = new Dictionary<int, int>(pix.Count); foreach (int p in pix) member[p] = -1;
            for (int k = 1; k <= 5; k++)
            {
                double t = T + k * (peak - T) / 7.0;
                // the cores at this level
                var core = new Dictionary<int, int>(); var cores = new List<List<int>>(); var stack = new Stack<int>();
                foreach (int s0 in pix)
                {
                    if (S[s0] <= t || core.ContainsKey(s0)) continue;
                    var c = new List<int>(); core[s0] = cores.Count; stack.Push(s0);
                    while (stack.Count > 0)
                    {
                        int p = stack.Pop(); c.Add(p); int x = p % W, y = p / W;
                        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++)
                        {
                            int xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
                            int q = yy * W + xx; if (member.ContainsKey(q) && S[q] > t && !core.ContainsKey(q)) { core[q] = cores.Count; stack.Push(q); }
                        }
                    }
                    cores.Add(c);
                }
                var big = new List<int>(); for (int i = 0; i < cores.Count; i++) if (cores[i].Count >= Math.Max(0.0012 * artArea, 0.08 * pix.Count)) big.Add(i);
                if (big.Count < 2) continue;
                // grow the big cores back through the patch, breadth first
                var owner = new Dictionary<int, int>(); var q2 = new Queue<int>();
                for (int bi = 0; bi < big.Count; bi++) foreach (int p in cores[big[bi]]) { owner[p] = bi; q2.Enqueue(p); }
                while (q2.Count > 0)
                {
                    int p = q2.Dequeue(); int x = p % W, y = p / W, o = owner[p];
                    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++)
                    {
                        int xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
                        int q = yy * W + xx; if (member.ContainsKey(q) && !owner.ContainsKey(q)) { owner[q] = o; q2.Enqueue(q); }
                    }
                }
                var parts = new List<List<int>>(); for (int bi = 0; bi < big.Count; bi++) parts.Add(new List<int>());
                foreach (int p in pix) { int o; if (owner.TryGetValue(p, out o)) parts[o].Add(p); }
                var res = new List<List<int>>(); foreach (var pp in parts) res.AddRange(Split(pp, S, W, H, t, artArea, depth + 1));
                return res;
            }
            return one;
        }

        static float[] Blur(float[] src, bool[] ok, int W, int H, int r)
        {
            var tmp = new float[W * H]; var dst = new float[W * H];
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                {
                    double s = 0; int n = 0;
                    for (int k = -r; k <= r; k++) { int xx = x + k; if (xx < 0 || xx >= W) continue; int q = y * W + xx; if (!ok[q]) continue; s += src[q]; n++; }
                    tmp[y * W + x] = n > 0 ? (float)(s / n) : 0f;
                }
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                {
                    double s = 0; int n = 0;
                    for (int k = -r; k <= r; k++) { int yy = y + k; if (yy < 0 || yy >= H) continue; int q = yy * W + x; if (!ok[q]) continue; s += tmp[q]; n++; }
                    dst[y * W + x] = ok[y * W + x] && n > 0 ? (float)(s / n) : 0f;
                }
            return dst;
        }

        static double Clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

        // the patch's box, centre, mean, colour -- shared by both searches
        static PlBlob Basics(List<int> pix, float[] L, float[] S, int[] px, int W, double med, double artArea, out double cx, out double cy, out double M)
        {
            cx = cy = M = 0;
            double area = pix.Count / artArea;
            if (area < 0.003 || area > 0.34) return null;
            int x0 = W, y0 = int.MaxValue, x1 = 0, y1 = 0; double sx = 0, sy = 0, sl = 0;
            var ls = new List<float>(pix.Count);
            foreach (int p in pix)
            {
                int x = p % W, y = p / W; if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
                sx += x; sy += y; sl += S[p]; ls.Add(L[p]);
            }
            int bw = x1 - x0 + 1, bh = y1 - y0 + 1;
            if (bw < 4 || bh < 4) return null;
            M = sl / pix.Count; cx = sx / pix.Count; cy = sy / pix.Count;
            if (M - med < 12) return null;
            var b = new PlBlob { X0 = x0, Y0 = y0, X1 = x1, Y1 = y1, Area = area, Contrast = M / Math.Max(8, med), Fill = pix.Count / (double)(bw * bh), Median = med };
            // the painted light's colour: the brightest third of the patch's own pixels
            ls.Sort(); float lc = ls[(int)(ls.Count * 0.67)]; double cr = 0, cg = 0, cb = 0; int cn = 0;
            foreach (int p in pix) { if (L[p] < lc) continue; int c = px[p]; cr += (c >> 16) & 255; cg += (c >> 8) & 255; cb += c & 255; cn++; }
            if (cn > 0) { b.R = (int)(cr / cn); b.G = (int)(cg / cn); b.B = (int)(cb / cn); }
            return b;
        }
        static void Finish(PlBlob b, int W, int H)
        {
            b.U = (b.Px + 0.5) / W; b.V = 1 - (b.Py + 0.5) / H;
            b.U0 = b.X0 / (double)W; b.U1 = (b.X1 + 1) / (double)W; b.V0 = 1 - (b.Y1 + 1) / (double)H; b.V1 = 1 - b.Y0 / (double)H;
        }

        // a WINDOW: a bright patch crossed by a regular grid of dark bars, both ways (the raw pixels, split into pane and bar
        // at the midpoint of the box's own bright and dark quarters)
        static PlBlob WindowBlob(List<int> pix, float[] L, float[] SW, bool[] ok, int[] px, int W, int H, double med, double artArea)
        {
            double cx, cy, M; var b = Basics(pix, L, SW, px, W, med, artArea, out cx, out cy, out M);
            if (b == null || b.X1 - b.X0 < 7 || b.Y1 - b.Y0 < 7 || b.Fill < 0.4) return null;
            var v = new List<float>();
            for (int y = b.Y0; y <= b.Y1; y++) for (int x = b.X0; x <= b.X1; x++) { int q = y * W + x; if (ok[q]) v.Add(L[q]); }
            if (v.Count < 40) return null; v.Sort();
            double lo = 0, hi = 0; int n4 = v.Count / 4; for (int i = 0; i < n4; i++) { lo += v[i]; hi += v[v.Count - 1 - i]; } lo /= n4; hi /= n4;
            if (hi - lo < Math.Max(40, 0.45 * hi)) return null;        // panes and bars clearly apart
            double mid = (lo + hi) / 2;
            double barsR, barsC;
            double gr = GridLines(L, ok, W, b.X0, b.Y0, b.X1, b.Y1, mid, true, out barsR), gc = GridLines(L, ok, W, b.X0, b.Y0, b.X1, b.Y1, mid, false, out barsC);
            if (gr < 0.45 || gc < 0.45) return null;
            b.Kind = "window"; b.Px = (int)Math.Round((b.X0 + b.X1) / 2.0); b.Py = (int)Math.Round((b.Y0 + b.Y1) / 2.0);
            b.Bars = (int)Math.Round(barsR + barsC);
            b.Score = 0.35 * Clamp01((b.Contrast - 1.3) / 1.2) + 0.20 * AreaTerm(b.Area) + 0.45 * Clamp01((Math.Min(gr, gc) - 0.3) / 0.5);
            Finish(b, W, H);
            return b;
        }
        // the share of the box's middle lines (70%) that cross a grid: at least 2 dark bars, each at most a fifth of the
        // line, between at least 3 panes of even size (spread under half their mean); 'bars' = the mean bar count
        static double GridLines(float[] L, bool[] ok, int W, int x0, int y0, int x1, int y1, double mid, bool alongRows, out double bars)
        {
            int a0 = alongRows ? y0 : x0, a1 = alongRows ? y1 : x1, len = alongRows ? x1 - x0 + 1 : y1 - y0 + 1;
            int from = a0 + (a1 - a0) * 15 / 100, to = a1 - (a1 - a0) * 15 / 100, lines = 0, grid = 0; double nb = 0;
            for (int a = from; a <= to; a++)
            {
                var lit = new List<int>(); var dark = new List<int>(); int run = 0; bool cur = false, started = false;
                for (int k = 0; k <= len; k++)
                {
                    bool l = false;
                    if (k < len) { int x = alongRows ? x0 + k : a, y = alongRows ? a : y0 + k, q = y * W + x; l = ok[q] && L[q] >= mid; }
                    if (k == len || l != cur)
                    {
                        if (started && run > 0) { if (cur) lit.Add(run); else if (k < len) dark.Add(run); }
                        if (l) started = true; cur = l; run = 0;
                    }
                    run++;
                }
                lines++;
                int maxBar = Math.Max(2, len / 5); bool okBars = dark.Count >= 2; foreach (int d in dark) if (d > maxBar) okBars = false;
                if (!okBars || lit.Count < 3) continue;
                // (the end panes may be cut by the box: the inner ones carry the rhythm)
                var inner = lit.Count > 3 ? lit.GetRange(1, lit.Count - 2) : lit; double m = 0, s = 0;
                foreach (int r in inner) m += r; m /= inner.Count; foreach (int r in inner) s += (r - m) * (r - m); s = Math.Sqrt(s / inner.Count);
                if (s > 0.5 * m) continue;
                grid++; nb += dark.Count;
            }
            bars = grid > 0 ? nb / grid : 0;
            return lines > 0 ? grid / (double)lines : 0;
        }

        // a CONE (spotlight fan) or a POOL (round glow), from the finer search
        static PlBlob Describe(List<int> pix, float[] L, float[] S, bool[] ok, int[] px, int W, int H, double med, double artArea, double T, float[] SC)
        {
            double cx, cy, M; var b = Basics(pix, L, S, px, W, med, artArea, out cx, out cy, out M);
            if (b != null) { int ci = (int)Math.Round(cy) * W + (int)Math.Round(cx); b.Broad = (SC[ci] - med) / Math.Max(1, M - med); }
            if (b == null) return null;
            int x0 = b.X0, y0 = b.Y0, x1 = b.X1, y1 = b.Y1, bw = x1 - x0 + 1, bh = y1 - y0 + 1; double lift = M - med, area = b.Area;
            // which way the light throws -- each side's strip past the patch (other bright patches and black padding left
            // out: a neighbouring light is not this one's throw), and the patch's own two halves
            var own = new HashSet<int>(pix);
            double best = 0, bestHalf = 0; int bd = -1;
            for (int d = 0; d < 4; d++)
            {
                // 0 up (toward row 0), 1 down, 2 left, 3 right
                int o = d ^ 1;
                double sd = Strip(S, L, ok, W, H, x0, y0, x1, y1, d, T, own), so = Strip(S, L, ok, W, H, x0, y0, x1, y1, o, T, own);
                double hd = Half(pix, S, W, x0, y0, x1, y1, d), ho = Half(pix, S, W, x0, y0, x1, y1, o);
                if (double.IsNaN(sd) || double.IsNaN(so)) continue;
                // (the source side must be ART right next to the patch: a patch hard against the black padding round the
                // art -- R22G's docarch corner -- would read as a fan falling out of the padding)
                if (EdgeArt(L, ok, W, H, x0, y0, x1, y1, o) < 0.5) continue;
                // the light FADES toward d: the strip past d is lit (more than the strip past o), and the half at o is the brighter (the source end)
                double t = (sd - so) / lift + 0.6 * (ho - hd) / lift;
                if (t > best) { best = t; bd = d; bestHalf = (ho - hd) / lift; b.ThrowStrip = (sd - so) / lift; b.ThrowLit = (sd - med) / lift; }
            }
            b.Throw = best;
            // a fan is longer along its throw than across it
            b.Elong = bd < 0 ? 0 : bd <= 1 ? bh / (double)bw : bw / (double)bh;
            // A painted FAN (tuned on CHAMBNEW's 08-chwall, checked against every room's art, 2026-10-14): a solid shape
            // (filled 60%+ of its box) of real size (1.2%+ of the art: CHAMBNEW's are 2.2-4%), somewhat longer along its
            // throw than across (1.1-1.9: a squat patch with a lighter side, or a long streak, is uneven art), and the
            // strip past its end clearly lit over the strip past its source (CHAMBNEW 0.48-0.66), and strong (2.3x the art's
            // level; CHAMBNEW 2.8-2.9). Wet streaks, pale
            // stones and lit floor tiles fail one of these; what fails is tried as a glow below.
            if (bd >= 0 && best >= 0.30 && bestHalf > -0.05 && b.Elong >= 1.1 && b.Elong <= 1.9 && b.Fill >= 0.6 && area >= 0.012 && b.ThrowStrip >= 0.4 && b.Contrast >= 2.3)
            {
                b.Kind = "cone";
                // the SOURCE: on the axis through the patch's centre, 40% of the way in from the bright end
                // (CHAMBNEW: Josh marked the bright base of each painted fan, a little up from its foot)
                double fx = 0, fy = 0;
                switch (bd) { case 0: fy = -1; break; case 1: fy = 1; break; case 2: fx = -1; break; default: fx = 1; break; }
                if (bd <= 1) { b.Px = (int)Math.Round(cx); b.Py = (int)Math.Round(fy < 0 ? y1 - 0.4 * bh : y0 + 0.4 * bh); }
                else { b.Py = (int)Math.Round(cy); b.Px = (int)Math.Round(fx < 0 ? x1 - 0.4 * bw : x0 + 0.4 * bw); }
                b.FU = fx; b.FV = -fy;      // (uv's v runs up the picture)
                b.Score = 0.30 * Clamp01((b.Contrast - 1.3) / 1.2) + 0.15 * AreaTerm(area) + 0.35 * Clamp01((best - 0.2) / 0.6) + 0.20 * Clamp01((b.Elong - 0.9) / 0.6);
            }
            else
            {
                // a POOL / glow: compact and round-ish, or it is just a lighter stretch of the art
                double asp = Math.Max(bw, bh) / (double)Math.Min(bw, bh);
                if (b.Fill < 0.45 || asp > 2.6) return null;
                // a GLOW is brightest in the middle and falls off smoothly into its surroundings: the nearest 30% of its
                // pixels to its centre against the farthest 30% (Peak), and the ring just outside it against the art (Halo).
                // A lighter patch of art (a wet floor, a pale stone) is flat-topped and ends at an edge.
                var byD = new List<KeyValuePair<double, float>>(pix.Count);
                foreach (int p in pix) { double dx = p % W - cx, dy = p / W - cy; byD.Add(new KeyValuePair<double, float>(dx * dx + dy * dy, S[p])); }
                byD.Sort((a1, a2) => a1.Key.CompareTo(a2.Key));
                int n3 = Math.Max(1, byD.Count * 3 / 10); double inner = 0, outer = 0;
                for (int i = 0; i < n3; i++) { inner += byD[i].Value; outer += byD[byD.Count - 1 - i].Value; }
                b.Peak = (inner - outer) / n3 / lift;
                int gx = Math.Max(2, Math.Max(bw, bh) / 2); double hs = 0; int hn = 0;
                for (int y = Math.Max(0, y0 - gx); y <= Math.Min(H - 1, y1 + gx); y++) for (int x = Math.Max(0, x0 - gx); x <= Math.Min(W - 1, x1 + gx); x++)
                { int q = y * W + x; if (!ok[q] || own.Contains(q) || S[q] > T) continue; hs += S[q]; hn++; }
                b.Halo = hn > 0 ? (hs / hn - med) / lift : 0;
                // (and a glow worth a light is big -- 1.5%+ of the art --, strong -- 2.5x its level --, and a swell of the broad light:
                // LIGHT's lr_rocks pool passes; EXIT_E5's pale stones, tunnel floor tiles and props do not)
                if (b.Peak < 0.3 || b.Halo < 0.15 || area < 0.015 || b.Broad < 0.6 || b.Contrast < 2.5) return null;
                b.Kind = "pool"; b.Px = (int)Math.Round(cx); b.Py = (int)Math.Round(cy);
                b.Score = 0.30 * Clamp01((b.Contrast - 1.5) / 1.5) + 0.10 * AreaTerm(area) + 0.10 * Clamp01((2.6 - asp) / 1.2) + 0.30 * Clamp01((b.Peak - 0.2) / 0.5) + 0.20 * Clamp01(b.Halo / 0.4);
            }
            Finish(b, W, H);
            return b;
        }
        static double AreaTerm(double a) { if (a < 0.008) return Clamp01((a - 0.003) / 0.005); if (a <= 0.12) return 1; return Clamp01(1 - (a - 0.12) / 0.22); }

        // the share of the 3 lines just past one side of the box that are art (not the pure black padding, not a key hole)
        static double EdgeArt(float[] L, bool[] ok, int W, int H, int x0, int y0, int x1, int y1, int d)
        {
            int n = 0, art = 0;
            for (int k = 1; k <= 3; k++)
            {
                if (d <= 1) { int y = d == 0 ? y0 - k : y1 + k; if (y < 0 || y >= H) { n += x1 - x0 + 1; continue; } for (int x = x0; x <= x1; x++) { n++; int q = y * W + x; if (ok[q] && L[q] >= 4) art++; } }
                else { int x = d == 2 ? x0 - k : x1 + k; if (x < 0 || x >= W) { n += y1 - y0 + 1; continue; } for (int y = y0; y <= y1; y++) { n++; int q = y * W + x; if (ok[q] && L[q] >= 4) art++; } }
            }
            return n > 0 ? art / (double)n : 0;
        }
        // mean smoothed brightness of the strip just past one side of the box (as deep as the box), other bright patches left
        // out (a neighbouring light is not this one's throw); NaN when mostly off the texture
        static double Strip(float[] S, float[] L, bool[] ok, int W, int H, int x0, int y0, int x1, int y1, int d, double T, HashSet<int> own)
        {
            int bw = x1 - x0 + 1, bh = y1 - y0 + 1; int ax, ay, bx, by;
            switch (d)
            {
                case 0: ax = x0; bx = x1; by = y0 - 2; ay = y0 - 1 - bh; break;
                case 1: ax = x0; bx = x1; ay = y1 + 2; by = y1 + 1 + bh; break;
                case 2: ay = y0; by = y1; bx = x0 - 2; ax = x0 - 1 - bw; break;
                default: ay = y0; by = y1; ax = x1 + 2; bx = x1 + 1 + bw; break;
            }
            if (ax < 0) ax = 0; if (ay < 0) ay = 0; if (bx >= W) bx = W - 1; if (by >= H) by = H - 1;
            if (bx - ax < 1 || by - ay < 1) return double.NaN;
            // (needs at least a quarter of the strip's planned depth to be on the texture)
            double depth = (d <= 1) ? (by - ay + 1) / (double)bh : (bx - ax + 1) / (double)bw; if (depth < 0.25) return double.NaN;
            double s = 0; int n = 0, all = 0;
            for (int y = ay; y <= by; y++) for (int x = ax; x <= bx; x++)
            {
                int q = y * W + x; all++;
                if (!ok[q] || (S[q] > T && !own.Contains(q))) continue;
                s += S[q]; n++;
            }
            return n > 0 && n >= 0.35 * all ? s / n : double.NaN;
        }
        // mean smoothed brightness of the blob's own pixels in its half toward one side
        static double Half(List<int> pix, float[] S, int W, int x0, int y0, int x1, int y1, int d)
        {
            double mx = (x0 + x1) / 2.0, my = (y0 + y1) / 2.0, s = 0; int n = 0;
            foreach (int p in pix)
            {
                int x = p % W, y = p / W; bool inside = d == 0 ? y < my : d == 1 ? y > my : d == 2 ? x < mx : x > mx;
                if (inside) { s += S[p]; n++; }
            }
            return n > 0 ? s / n : 0;
        }
        static void SaveDebug(string path, int[] px, int W, int H, int[] lab, List<PlBlob> res)
        {
            int k = Math.Max(1, 512 / Math.Max(W, H));
            using (var bm = new Bitmap(W * k, H * k, PixelFormat.Format32bppArgb))
            using (var g = Graphics.FromImage(bm))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                var bmS = new Bitmap(W, H, PixelFormat.Format32bppArgb);
                for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { int c = px[y * W + x] | unchecked((int)0xFF000000); if (lab[y * W + x] != 0) c = Color.FromArgb(255, Math.Min(255, ((c >> 16) & 255) + 40), (c >> 8) & 255, Math.Min(255, (c & 255) + 60)).ToArgb(); bmS.SetPixel(x, y, Color.FromArgb(c)); }
                g.DrawImage(bmS, 0, 0, W * k, H * k); bmS.Dispose();
                foreach (var b in res)
                {
                    var col = b.Kind == "cone" ? Color.Lime : b.Kind == "window" ? Color.Cyan : Color.Orange;
                    using (var pen = new Pen(col, 1)) g.DrawRectangle(pen, b.X0 * k, b.Y0 * k, (b.X1 - b.X0 + 1) * k, (b.Y1 - b.Y0 + 1) * k);
                    g.FillEllipse(Brushes.Red, b.Px * k - 3, b.Py * k - 3, 7, 7);
                    if (b.Kind == "cone") using (var pen = new Pen(Color.Yellow, 2)) g.DrawLine(pen, b.Px * k, b.Py * k, (float)(b.Px * k + b.FU * 30), (float)(b.Py * k - b.FV * 30));
                    using (var f = new Font("Consolas", 8)) g.DrawString(b.Kind[0] + " " + b.Score.ToString("0.00", CultureInfo.InvariantCulture), f, Brushes.White, b.X0 * k, b.Y0 * k - 12 < 0 ? b.Y1 * k + 1 : b.Y0 * k - 12);
                }
                bm.Save(path, ImageFormat.Png);
            }
        }
    }

    // ---- 2. the room ----------------------------------------------------------------------------------------------------
    public class PlMesh
    {
        public float[] P;       // 9 a triangle (room coordinates)
        public float[] T;       // 6 a triangle (uv)
        public float[] N;       // 3 a triangle: the OBJ's own normal (mean of its corners), or 0
        public int[] Mat, Part;
        public List<string> Mats = new List<string>(), Parts = new List<string>();
        public bool[] Solid;    // counts for ray tests (set by the caller: triggers, views and occluders do not)
        public int Count;
        public double MinX, MinY, MinZ, MaxX, MaxY, MaxZ;

        public static PlMesh Load(string objPath)
        {
            var m = new PlMesh(); var inv = CultureInfo.InvariantCulture;
            var v = new List<float>(); var vt = new List<float>(); var vn = new List<float>();
            var P = new List<float>(); var T = new List<float>(); var N = new List<float>(); var mat = new List<int>(); var part = new List<int>();
            int curMat = -1, curPart = -1; var matIdx = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var raw in File.ReadLines(objPath))
            {
                var ln = raw.Trim(); if (ln.Length < 2 || ln[0] == '#') continue;
                if (ln.StartsWith("v ")) { var s = ln.Split((char[])null, StringSplitOptions.RemoveEmptyEntries); v.Add(float.Parse(s[1], inv)); v.Add(float.Parse(s[2], inv)); v.Add(float.Parse(s[3], inv)); }
                else if (ln.StartsWith("vt ")) { var s = ln.Split((char[])null, StringSplitOptions.RemoveEmptyEntries); vt.Add(float.Parse(s[1], inv)); vt.Add(s.Length > 2 ? float.Parse(s[2], inv) : 0f); }
                else if (ln.StartsWith("vn ")) { var s = ln.Split((char[])null, StringSplitOptions.RemoveEmptyEntries); vn.Add(float.Parse(s[1], inv)); vn.Add(float.Parse(s[2], inv)); vn.Add(float.Parse(s[3], inv)); }
                else if (ln.StartsWith("o ") || ln.StartsWith("g ")) { m.Parts.Add(ln.Substring(2).Trim()); curPart = m.Parts.Count - 1; }
                else if (ln.StartsWith("usemtl ")) { var nm = ln.Substring(7).Trim(); int k; if (!matIdx.TryGetValue(nm, out k)) { k = m.Mats.Count; m.Mats.Add(nm); matIdx[nm] = k; } curMat = k; }
                else if (ln.StartsWith("f "))
                {
                    var s = ln.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
                    var vi = new int[s.Length - 1]; var ti = new int[s.Length - 1]; var ni = new int[s.Length - 1];
                    for (int k = 1; k < s.Length; k++)
                    {
                        var c = s[k].Split('/');
                        vi[k - 1] = Idx(c[0], v.Count / 3); ti[k - 1] = c.Length > 1 && c[1].Length > 0 ? Idx(c[1], vt.Count / 2) : -1; ni[k - 1] = c.Length > 2 && c[2].Length > 0 ? Idx(c[2], vn.Count / 3) : -1;
                    }
                    for (int k = 1; k + 1 < vi.Length; k++)
                    {
                        int[] cs = { 0, k, k + 1 }; float nx = 0, ny = 0, nz = 0;
                        foreach (int c in cs)
                        {
                            P.Add(v[vi[c] * 3]); P.Add(v[vi[c] * 3 + 1]); P.Add(v[vi[c] * 3 + 2]);
                            if (ti[c] >= 0) { T.Add(vt[ti[c] * 2]); T.Add(vt[ti[c] * 2 + 1]); } else { T.Add(0); T.Add(0); }
                            if (ni[c] >= 0) { nx += vn[ni[c] * 3]; ny += vn[ni[c] * 3 + 1]; nz += vn[ni[c] * 3 + 2]; }
                        }
                        N.Add(nx); N.Add(ny); N.Add(nz); mat.Add(curMat); part.Add(curPart);
                    }
                }
            }
            m.P = P.ToArray(); m.T = T.ToArray(); m.N = N.ToArray(); m.Mat = mat.ToArray(); m.Part = part.ToArray(); m.Count = m.Mat.Length;
            m.Solid = new bool[m.Count]; for (int i = 0; i < m.Count; i++) m.Solid[i] = true;
            m.MinX = m.MinY = m.MinZ = double.MaxValue; m.MaxX = m.MaxY = m.MaxZ = double.MinValue;
            for (int i = 0; i < m.P.Length; i += 3) { m.MinX = Math.Min(m.MinX, m.P[i]); m.MaxX = Math.Max(m.MaxX, m.P[i]); m.MinY = Math.Min(m.MinY, m.P[i + 1]); m.MaxY = Math.Max(m.MaxY, m.P[i + 1]); m.MinZ = Math.Min(m.MinZ, m.P[i + 2]); m.MaxZ = Math.Max(m.MaxZ, m.P[i + 2]); }
            return m;
        }
        // a triangle's unit normal y (its winding's side; callers use the absolute value)
        public double NormalY(int t) { int o = t * 9; double e1x = P[o + 3] - P[o], e1y = P[o + 4] - P[o + 1], e1z = P[o + 5] - P[o + 2], e2x = P[o + 6] - P[o], e2y = P[o + 7] - P[o + 1], e2z = P[o + 8] - P[o + 2]; double nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x, l = Math.Sqrt(nx * nx + ny * ny + nz * nz); return l > 0 ? ny / l : 0; }
        static int Idx(string s, int count) { int i = int.Parse(s, CultureInfo.InvariantCulture); return i > 0 ? i - 1 : count + i; }

        // the nearest solid surface along a ray (either side of a face), or +inf
        public double Ray(double ox, double oy, double oz, double dx, double dy, double dz, double far) { int t; return Ray(ox, oy, oz, dx, dy, dz, far, out t); }
        // ...and which triangle it hit (-1: none)
        public double Ray(double ox, double oy, double oz, double dx, double dy, double dz, double far, out int tri)
        {
            double best = far; bool hit = false; tri = -1;
            for (int t = 0; t < Count; t++)
            {
                if (!Solid[t]) continue; int o = t * 9;
                double ax = P[o], ay = P[o + 1], az = P[o + 2];
                double e1x = P[o + 3] - ax, e1y = P[o + 4] - ay, e1z = P[o + 5] - az, e2x = P[o + 6] - ax, e2y = P[o + 7] - ay, e2z = P[o + 8] - az;
                double px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
                double det = e1x * px + e1y * py + e1z * pz; if (Math.Abs(det) < 1e-9) continue;
                double inv = 1 / det, tx = ox - ax, ty = oy - ay, tz = oz - az;
                double u = (tx * px + ty * py + tz * pz) * inv; if (u < 0 || u > 1) continue;
                double qx = ty * e1z - tz * e1y, qy = tz * e1x - tx * e1z, qz = tx * e1y - ty * e1x;
                double w = (dx * qx + dy * qy + dz * qz) * inv; if (w < 0 || u + w > 1) continue;
                double d = (e2x * qx + e2y * qy + e2z * qz) * inv;
                if (d > 0.05 && d < best) { best = d; hit = true; tri = t; }
            }
            return hit ? best : double.PositiveInfinity;
        }

        // every face (of the triangles flagged in 'use') that shows texture point (u, v), at any whole-number tiling shift
        Dictionary<int, int> orientCache = new Dictionary<int, int>();
        public PlHit[] Locate(bool[] use, double u, double v)
        {
            var res = new List<PlHit>();
            for (int t = 0; t < Count; t++)
            {
                if (!use[t]) continue; int q = t * 6;
                double u0 = T[q], v0 = T[q + 1], u1 = T[q + 2], v1 = T[q + 3], u2 = T[q + 4], v2 = T[q + 5];
                double mnU = Math.Min(u0, Math.Min(u1, u2)), mxU = Math.Max(u0, Math.Max(u1, u2)), mnV = Math.Min(v0, Math.Min(v1, v2)), mxV = Math.Max(v0, Math.Max(v1, v2));
                double den = (u1 - u0) * (v2 - v0) - (u2 - u0) * (v1 - v0); if (Math.Abs(den) < 1e-12) continue;
                int i0 = (int)Math.Floor(mnU - u), i1 = (int)Math.Ceiling(mxU - u), j0 = (int)Math.Floor(mnV - v), j1 = (int)Math.Ceiling(mxV - v);
                if ((i1 - i0) * (j1 - j0) > 400) continue;      // (a face tiled hundreds of times: a floor pattern, not painted light)
                for (int i = i0; i <= i1; i++) for (int j = j0; j <= j1; j++)
                {
                    double su = u + i, sv = v + j;
                    double b1 = ((su - u0) * (v2 - v0) - (u2 - u0) * (sv - v0)) / den, b2 = ((u1 - u0) * (sv - v0) - (su - u0) * (v1 - v0)) / den, b0 = 1 - b1 - b2;
                    const double eps = -1e-4; if (b0 < eps || b1 < eps || b2 < eps) continue;
                    int o = t * 9;
                    var h = new PlHit { Tri = t, SU = su, SV = sv };
                    h.X = b0 * P[o] + b1 * P[o + 3] + b2 * P[o + 6]; h.Y = b0 * P[o + 1] + b1 * P[o + 4] + b2 * P[o + 7]; h.Z = b0 * P[o + 2] + b1 * P[o + 5] + b2 * P[o + 8];
                    // world change per unit u and v: [e1 e2] * inverse([du1 du2; dv1 dv2])
                    double du1 = u1 - u0, du2 = u2 - u0, dv1 = v1 - v0, dv2 = v2 - v0, id = 1 / (du1 * dv2 - du2 * dv1);
                    double e1x = P[o + 3] - P[o], e1y = P[o + 4] - P[o + 1], e1z = P[o + 5] - P[o + 2], e2x = P[o + 6] - P[o], e2y = P[o + 7] - P[o + 1], e2z = P[o + 8] - P[o + 2];
                    h.DuX = (e1x * dv2 - e2x * dv1) * id; h.DuY = (e1y * dv2 - e2y * dv1) * id; h.DuZ = (e1z * dv2 - e2z * dv1) * id;
                    h.DvX = (e2x * du1 - e1x * du2) * id; h.DvY = (e2y * du1 - e1y * du2) * id; h.DvZ = (e2z * du1 - e1z * du2) * id;
                    double nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x, nl = Math.Sqrt(nx * nx + ny * ny + nz * nz);
                    if (nl < 1e-9) continue; nx /= nl; ny /= nl; nz /= nl;
                    // (once per triangle, at its centre: a face is flat, and a floor tiled hundreds of times would cast thousands of rays)
                    int clear; bool flip;
                    if (orientCache.TryGetValue(t, out clear)) { flip = clear < 0; clear = Math.Abs(clear) - 1; }
                    else
                    {
                        double gx = (P[o] + P[o + 3] + P[o + 6]) / 3, gy = (P[o + 1] + P[o + 4] + P[o + 7]) / 3, gz = (P[o + 2] + P[o + 5] + P[o + 8]) / 3;
                        clear = Orient(gx, gy, gz, nx, ny, nz, t, out flip); orientCache[t] = flip ? -(clear + 1) : clear + 1;
                    }
                    if (flip) { nx = -nx; ny = -ny; nz = -nz; }
                    h.NX = nx; h.NY = ny; h.NZ = nz; h.OrientVotes = clear;
                    res.Add(h);
                }
            }
            return res.ToArray();
        }

        // which side of a face the room is on: rays leave both sides (a fan of 5 each); the side whose rays hit nothing
        // (the void outside the room's shell) is OUTSIDE. Ties: the OBJ's own normal, then the room's centre.
        // Returns how clear it was (escapes on one side minus the other: 0 = a tie, decided by the fallbacks).
        int Orient(double x, double y, double z, double nx, double ny, double nz, int tri, out bool flip)
        {
            double ax, ay, az; if (Math.Abs(ny) < 0.9) { ax = 0; ay = 1; az = 0; } else { ax = 1; ay = 0; az = 0; }
            double tx = ay * nz - az * ny, ty = az * nx - ax * nz, tz = ax * ny - ay * nx, tl = Math.Sqrt(tx * tx + ty * ty + tz * tz); tx /= tl; ty /= tl; tz /= tl;
            double bx = ny * tz - nz * ty, by = nz * tx - nx * tz, bz = nx * ty - ny * tx;
            int escFront = 0, escBack = 0; double far = 8000;
            double[,] fan = { { 0, 0 }, { 0.5, 0 }, { -0.5, 0 }, { 0, 0.5 }, { 0, -0.5 } };
            for (int k = 0; k < 5; k++)
            {
                double fx = nx + fan[k, 0] * tx + fan[k, 1] * bx, fy = ny + fan[k, 0] * ty + fan[k, 1] * by, fz = nz + fan[k, 0] * tz + fan[k, 1] * bz, fl = Math.Sqrt(fx * fx + fy * fy + fz * fz);
                fx /= fl; fy /= fl; fz /= fl;
                if (double.IsInfinity(Ray(x + nx * 0.5, y + ny * 0.5, z + nz * 0.5, fx, fy, fz, far))) escFront++;
                double gx = -nx + fan[k, 0] * tx + fan[k, 1] * bx, gy = -ny + fan[k, 0] * ty + fan[k, 1] * by, gz = -nz + fan[k, 0] * tz + fan[k, 1] * bz, gl = Math.Sqrt(gx * gx + gy * gy + gz * gz);
                gx /= gl; gy /= gl; gz /= gl;
                if (double.IsInfinity(Ray(x - nx * 0.5, y - ny * 0.5, z - nz * 0.5, gx, gy, gz, far))) escBack++;
            }
            if (escBack != escFront) { flip = escFront > escBack; return Math.Abs(escBack - escFront); }
            double on = N[tri * 3] * nx + N[tri * 3 + 1] * ny + N[tri * 3 + 2] * nz;
            if (Math.Abs(on) > 1e-3) { flip = on < 0; return 0; }
            double cx = (MinX + MaxX) / 2 - x, cy = (MinY + MaxY) / 2 - y, cz = (MinZ + MaxZ) / 2 - z;
            flip = (cx * nx + cy * ny + cz * nz) < 0; return 0;
        }
    }
}
