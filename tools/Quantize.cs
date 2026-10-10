using System;
using System.Collections.Generic;

namespace LeTool
{
    // Resampling + palette reduction for the HUD reskin.
    //
    // The panel art arrives as a 24-bit render with an alpha channel and has to end
    // up as 8-bit indexed pixels sharing the game's single 256-entry palette. Only
    // indices 1..57 are ours: 0 is the transparency key / black, 58..71 are
    // overwritten from h1.pcx, 72..127 are the Reality Lab shading ramps the 3D
    // renderer uses (verified in game -- repainting 72..86 turned the world red),
    // and 128..255 are overwritten from pal.pcx.
    public static class Quant
    {
        // Box-filter resample of a BGRA buffer into dst, premultiplying by alpha so
        // transparent pixels do not bleed their colour into the edges.
        public static void Resample(byte[] src, int sw, int sh, int sStride,
                                    int sx0, int sy0, int sx1, int sy1,
                                    byte[] dst, int dw, int dh)
        {
            double rw = (double)(sx1 - sx0) / dw;
            double rh = (double)(sy1 - sy0) / dh;
            for (int dy = 0; dy < dh; dy++)
            {
                int y0 = sy0 + (int)Math.Floor(dy * rh);
                int y1 = sy0 + (int)Math.Ceiling((dy + 1) * rh);
                if (y1 <= y0) y1 = y0 + 1;
                if (y1 > sy1) y1 = sy1;
                for (int dx = 0; dx < dw; dx++)
                {
                    int x0 = sx0 + (int)Math.Floor(dx * rw);
                    int x1 = sx0 + (int)Math.Ceiling((dx + 1) * rw);
                    if (x1 <= x0) x1 = x0 + 1;
                    if (x1 > sx1) x1 = sx1;

                    double b = 0, g = 0, r = 0, a = 0; int n = 0;
                    for (int y = y0; y < y1; y++)
                        for (int x = x0; x < x1; x++)
                        {
                            int o = y * sStride + x * 4;
                            double al = src[o + 3] / 255.0;
                            b += src[o] * al; g += src[o + 1] * al; r += src[o + 2] * al;
                            a += src[o + 3]; n++;
                        }
                    if (n == 0) n = 1;
                    double aa = a / n;
                    // un-premultiply so the averaged colour is the real surface colour
                    double w = aa / 255.0;
                    if (w < 1e-6) { b = g = r = 0; } else { b /= n * w; g /= n * w; r /= n * w; }
                    int od = dy * dw * 4 + dx * 4;
                    dst[od] = Clamp(b); dst[od + 1] = Clamp(g); dst[od + 2] = Clamp(r);
                    dst[od + 3] = Clamp(aa);
                }
            }
        }
        static byte Clamp(double v) { return (byte)(v < 0 ? 0 : v > 255 ? 255 : (int)Math.Round(v)); }

        // Knock out a flat background by flooding INWARD from the border, rather
        // than keying on the colour globally. The TAKE/USE/PUSH lettering is bone
        // white and a global key punches holes straight through it; the letters
        // never touch the border, so a fill can never reach them.
        // maxSat caps how far apart the channels may be. The render's background is
        // not flat white -- it carries a vignette from 203 to 255 -- so a plain
        // brightness threshold stalls on the darker patches. Dropping the threshold
        // far enough to cover them risks eating the bone-coloured lettering, hence
        // the second test: background is NEUTRAL, the artwork is olive and brass.
        public static int MatteBorder(byte[] px, int w, int h, int thresh, int maxSat)
        {
            s_thresh = thresh; s_maxSat = maxSat;
            var seen = new bool[w * h];
            var stk = new Stack<int>();
            for (int x = 0; x < w; x++)
                foreach (int y in new[] { 0, h - 1 })
                { int p = y * w + x; if (!seen[p] && Bg(px, p)) { seen[p] = true; stk.Push(p); } }
            for (int y = 0; y < h; y++)
                foreach (int x in new[] { 0, w - 1 })
                { int p = y * w + x; if (!seen[p] && Bg(px, p)) { seen[p] = true; stk.Push(p); } }

            while (stk.Count > 0)
            {
                int p = stk.Pop(); int cx = p % w;
                foreach (int d in new[] { -1, 1, -w, w })
                {
                    if (d == -1 && cx == 0) continue;
                    if (d == 1 && cx == w - 1) continue;
                    int q = p + d;
                    if (q < 0 || q >= w * h) continue;
                    if (!seen[q] && Bg(px, q)) { seen[q] = true; stk.Push(q); }
                }
            }
            int n = 0;
            for (int i = 0; i < w * h; i++) if (seen[i]) { px[i * 4 + 3] = 0; n++; }
            return n;
        }
        static int s_thresh = 232, s_maxSat = 255;
        static bool Bg(byte[] px, int p)
        {
            int b = px[p * 4], g = px[p * 4 + 1], r = px[p * 4 + 2];
            int lo = Math.Min(b, Math.Min(g, r)), hi = Math.Max(b, Math.Max(g, r));
            return lo >= s_thresh && (hi - lo) <= s_maxSat;
        }

        // Connected components of the opaque area. Returns x,y,w,h,pixels per blob.
        public static int[] Blobs(byte[] px, int w, int h, int minPx)
        {
            var lab = new int[w * h];
            var res = new List<int>();
            int n = 0;
            var stk = new Stack<int>();
            for (int s = 0; s < w * h; s++)
            {
                if (px[s * 4 + 3] < 128 || lab[s] != 0) continue;
                n++; stk.Clear(); stk.Push(s); lab[s] = n;
                int x0 = w, x1 = 0, y0 = h, y1 = 0, c = 0;
                while (stk.Count > 0)
                {
                    int p = stk.Pop(); c++;
                    int cx = p % w, cy = p / w;
                    if (cx < x0) x0 = cx; if (cx > x1) x1 = cx;
                    if (cy < y0) y0 = cy; if (cy > y1) y1 = cy;
                    foreach (int d in new[] { -1, 1, -w, w })
                    {
                        if (d == -1 && cx == 0) continue;
                        if (d == 1 && cx == w - 1) continue;
                        int q = p + d;
                        if (q < 0 || q >= w * h) continue;
                        if (px[q * 4 + 3] >= 128 && lab[q] == 0) { lab[q] = n; stk.Push(q); }
                    }
                }
                if (c >= minPx) { res.Add(x0); res.Add(y0); res.Add(x1 - x0 + 1); res.Add(y1 - y0 + 1); res.Add(c); }
            }
            return res.ToArray();
        }

        class Box
        {
            public List<int> Idx = new List<int>();
            public int rmin, rmax, gmin, gmax, bmin, bmax;
            public int Volume { get { return (rmax - rmin) * (gmax - gmin) * (bmax - bmin); } }
            public int Longest
            {
                get
                {
                    int dr = rmax - rmin, dg = gmax - gmin, db = bmax - bmin;
                    return dr >= dg && dr >= db ? 0 : (dg >= db ? 1 : 2);
                }
            }
        }

        // Median cut over the OPAQUE pixels only. Returns count*3 RGB bytes.
        public static byte[] MedianCut(byte[] px, int w, int h, int count)
        {
            var pts = new List<int>();
            for (int i = 0; i < w * h; i++) if (px[i * 4 + 3] >= 128) pts.Add(i);
            if (pts.Count == 0) return new byte[count * 3];

            var boxes = new List<Box>();
            var first = new Box(); first.Idx = pts; Fit(first, px);
            boxes.Add(first);

            while (boxes.Count < count)
            {
                // split the box with the largest volume that still has room to split
                int best = -1; long bestV = -1;
                for (int i = 0; i < boxes.Count; i++)
                    if (boxes[i].Idx.Count > 1 && boxes[i].Volume > bestV) { bestV = boxes[i].Volume; best = i; }
                if (best < 0) break;

                var bx = boxes[best];
                int axis = bx.Longest;
                bx.Idx.Sort(delegate(int a, int b) { return Chan(px, a, axis).CompareTo(Chan(px, b, axis)); });
                int mid = bx.Idx.Count / 2;
                var lo = new Box(); var hi = new Box();
                lo.Idx = bx.Idx.GetRange(0, mid);
                hi.Idx = bx.Idx.GetRange(mid, bx.Idx.Count - mid);
                if (lo.Idx.Count == 0 || hi.Idx.Count == 0) break;
                Fit(lo, px); Fit(hi, px);
                boxes[best] = lo; boxes.Add(hi);
            }

            var pal = new byte[count * 3];
            for (int i = 0; i < boxes.Count && i < count; i++)
            {
                long r = 0, g = 0, b = 0;
                foreach (int p in boxes[i].Idx) { r += px[p * 4 + 2]; g += px[p * 4 + 1]; b += px[p * 4]; }
                int n = boxes[i].Idx.Count;
                pal[i * 3] = (byte)(r / n); pal[i * 3 + 1] = (byte)(g / n); pal[i * 3 + 2] = (byte)(b / n);
            }
            return pal;
        }
        static int Chan(byte[] px, int i, int axis) { return axis == 0 ? px[i * 4 + 2] : axis == 1 ? px[i * 4 + 1] : px[i * 4]; }
        static void Fit(Box bx, byte[] px)
        {
            bx.rmin = bx.gmin = bx.bmin = 255; bx.rmax = bx.gmax = bx.bmax = 0;
            foreach (int p in bx.Idx)
            {
                int r = px[p * 4 + 2], g = px[p * 4 + 1], b = px[p * 4];
                if (r < bx.rmin) bx.rmin = r; if (r > bx.rmax) bx.rmax = r;
                if (g < bx.gmin) bx.gmin = g; if (g > bx.gmax) bx.gmax = g;
                if (b < bx.bmin) bx.bmin = b; if (b > bx.bmax) bx.bmax = b;
            }
        }

        // Lossless path. When an image holds no more distinct colours than the palette
        // can carry, quantising it is not just unnecessary, it is HARMFUL: median cut
        // picks box *averages* as representatives, so colours that were already exactly
        // representable get shifted.
        //
        // Scale2x output is precisely this case -- it only ever copies existing pixels,
        // so an upscaled 256-colour texture still has at most 256 colours. Measured on
        // CORICORI record 0, median cut left only 54% of pixels exact; this leaves 100%.
        //
        // reserveIndex >= 0 keeps that slot for the chroma key (magenta), and any
        // magenta pixel is mapped to it directly so the key survives byte-exact.
        // Returns the index buffer, or null when there are too many colours -- the
        // caller then falls back to MedianCut.
        public static byte[] MapExact(byte[] px, int w, int h, int count, int reserveIndex, out byte[] pal3)
        {
            pal3 = null;
            const int MAGENTA = (255 << 16) | (0 << 8) | 255;

            var slot = new Dictionary<int, int>();
            int limit = count - (reserveIndex >= 0 && reserveIndex < count ? 1 : 0);
            for (int i = 0; i < w * h; i++)
            {
                if (px[i * 4 + 3] < 128) continue;                       // transparent -> index 0
                int key = (px[i * 4 + 2] << 16) | (px[i * 4 + 1] << 8) | px[i * 4];
                if (reserveIndex >= 0 && key == MAGENTA) continue;       // handled below
                if (slot.ContainsKey(key)) continue;
                if (slot.Count >= limit) return null;                    // too many colours
                slot[key] = slot.Count;
            }

            // Skip the reserved slot when handing out indices, so nothing else lands on it.
            var order = new int[slot.Count];
            foreach (var kv in slot) order[kv.Value] = kv.Key;
            var index = new Dictionary<int, int>();
            pal3 = new byte[count * 3];
            int next = 0;
            for (int i = 0; i < order.Length; i++)
            {
                if (next == reserveIndex) next++;
                index[order[i]] = next;
                pal3[next * 3] = (byte)((order[i] >> 16) & 255);
                pal3[next * 3 + 1] = (byte)((order[i] >> 8) & 255);
                pal3[next * 3 + 2] = (byte)(order[i] & 255);
                next++;
            }
            if (reserveIndex >= 0 && reserveIndex < count)
            {
                pal3[reserveIndex * 3] = 255; pal3[reserveIndex * 3 + 1] = 0; pal3[reserveIndex * 3 + 2] = 255;
                index[MAGENTA] = reserveIndex;
            }

            var outIdx = new byte[w * h];
            for (int i = 0; i < w * h; i++)
            {
                if (px[i * 4 + 3] < 128) { outIdx[i] = 0; continue; }
                int key = (px[i * 4 + 2] << 16) | (px[i * 4 + 1] << 8) | px[i * 4];
                outIdx[i] = (byte)index[key];
            }
            return outIdx;
        }

        // Map to the palette. baseIndex is the palette slot the first colour occupies.
        // dither 0 = none, 1 = Floyd-Steinberg. Transparent pixels become index 0.
        public static byte[] Map(byte[] px, int w, int h, byte[] pal, int count, int baseIndex, int dither)
        {
            return Map(px, w, h, pal, count, baseIndex, dither, -1);
        }

        // skipIndex: a palette slot the search may never choose for an OPAQUE pixel.
        //
        // WHY THIS EXISTS. The software rasteriser treats index 0 as a transparent texel
        // ("if (ink == 0) continue"), which is right for chroma-keyed art. But the nearest-
        // colour search below ran over the whole palette including 0, and in the game's
        // captured palette index 0 is pure black -- so every opaque NEAR-BLACK texel landed
        // on it and was then skipped as a hole. Measured on real rooms: 80.2% of CORICORI's
        // opaque texels, 67.8% of WASHCORI's, 59.0% of MINEMAZE's.
        //
        // On screen that is not subtle: most of every wall is punched out to black, and the
        // only texels that survive are the brightest ones, which read as scattered bright
        // dots. "Transparent walls", "corrupted textures" and "bright speckles" were all
        // this one bug.
        //
        // The palette has a SECOND pure black at index 54 (luminance 0.0, identical to 0),
        // so excluding 0 costs nothing visually -- black texels simply land on 54 and stay
        // opaque. Callers that legitimately want index 0 (the HUD art, which uses baseIndex
        // 1 or 128) keep the old behaviour by not passing a skipIndex.
        public static byte[] Map(byte[] px, int w, int h, byte[] pal, int count, int baseIndex, int dither, int skipIndex)
        {
            var outIdx = new byte[w * h];
            var err = new double[w * h * 3];
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    int i = y * w + x;
                    if (px[i * 4 + 3] < 128) { outIdx[i] = 0; continue; }
                    double r = px[i * 4 + 2] + err[i * 3];
                    double g = px[i * 4 + 1] + err[i * 3 + 1];
                    double b = px[i * 4] + err[i * 3 + 2];
                    int bi = -1; double bd = double.MaxValue;
                    for (int c = 0; c < count; c++)
                    {
                        if (c == skipIndex) continue;
                        double dr = pal[c * 3] - r, dg = pal[c * 3 + 1] - g, db = pal[c * 3 + 2] - b;
                        double d = dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114;
                        if (d < bd) { bd = d; bi = c; }
                    }
                    if (bi < 0) bi = (skipIndex == 0 && count > 1) ? 1 : 0;   // palette of one
                    outIdx[i] = (byte)(baseIndex + bi);
                    if (dither != 0)
                    {
                        double er = r - pal[bi * 3], eg = g - pal[bi * 3 + 1], eb = b - pal[bi * 3 + 2];
                        Spread(err, px, w, h, x + 1, y, er, eg, eb, 7.0 / 16);
                        Spread(err, px, w, h, x - 1, y + 1, er, eg, eb, 3.0 / 16);
                        Spread(err, px, w, h, x, y + 1, er, eg, eb, 5.0 / 16);
                        Spread(err, px, w, h, x + 1, y + 1, er, eg, eb, 1.0 / 16);
                    }
                }
            }
            return outIdx;
        }
        static void Spread(double[] err, byte[] px, int w, int h, int x, int y, double er, double eg, double eb, double f)
        {
            if (x < 0 || x >= w || y < 0 || y >= h) return;
            int i = y * w + x;
            if (px[i * 4 + 3] < 128) return;      // never push error into transparency
            err[i * 3] += er * f; err[i * 3 + 1] += eg * f; err[i * 3 + 2] += eb * f;
        }
    }
}
