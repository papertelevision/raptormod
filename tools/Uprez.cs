// Uprez.cs -- scale an .azf texture up while keeping it loadable by the engine.
//
// Three constraints, and all three bite:
//
// 1. THE PALETTE IS FIXED PER TEXTURE. Each .azf carries its own 256 entries and
//    the engine uses them as-is, so a scaled image has to be re-quantised back
//    into the SAME palette. (Unlike the HUD there is no shared-index budget --
//    see azrael-palette-budget -- because nothing else uses this palette.)
//
// 2. '#' IN THE TEXTURE'S NAME MEANS CHROMA KEY, AND THE KEY IS A COLOUR, NOT AN
//    INDEX. GetTexture2 (0x28685) calls SetTransparency with the colour built at
//    0x1E9DC from floats (1.0, 0, 1.0) -- magenta. So a plain smooth upscale is
//    WRONG for these: interpolating between magenta and the sprite invents
//    near-magenta pixels that miss the key test and render as a bright fringe
//    around every edge. The mask is therefore scaled nearest-neighbour and the
//    colour is smoothed only among non-key pixels, which are first flooded
//    outward so the blur has something real to pull from.
//
// 3. DIMENSIONS SHOULD STAY POWERS OF TWO. Every one of the game's 2,909
//    textures is, and the largest in use is 512 in either axis.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace AztTool
{
    public static class Uprez
    {
        /// <summary>Index of the palette entry nearest pure magenta, or -1.</summary>
        public static int FindKeyIndex(byte[] pal)
        {
            int best = -1; int bestD = int.MaxValue;
            for (int i = 0; i < pal.Length / 4; i++)
            {
                int dr = pal[i * 4] - 255, dg = pal[i * 4 + 1] - 0, db = pal[i * 4 + 2] - 255;
                int d = dr * dr + dg * dg + db * db;
                if (d < bestD) { bestD = d; best = i; }
            }
            return bestD <= 3 * 32 * 32 ? best : -1;   // must actually be magenta-ish
        }

        /// <summary>
        /// Scale2x, run directly on PALETTE INDICES rather than on colour.
        ///
        /// Worth doing at the index level for three reasons:
        ///   * the palette is never touched, so there is no re-quantisation and no dither --
        ///     the output is colour-exact, unlike the bicubic path below;
        ///   * chroma-keyed textures need no special handling at all. The algorithm only
        ///     ever COPIES an existing index, so it can never invent a near-magenta pixel,
        ///     which is the entire hazard constraint 2 describes;
        ///   * it is edge-preserving: diagonals get stepped rather than blurred.
        ///
        /// The catch, and it is a real one: Scale2x only acts where neighbouring pixels are
        /// EQUAL. On clean pixel art that is most of the image; on digitised photographic
        /// texture it is almost nowhere, and the result degenerates to nearest-neighbour --
        /// four times the memory for an identical picture. Measure before assuming it helps.
        /// </summary>
        public static int Scale2x(AzfTexture t)
        {
            int sw = t.Width, sh = t.Height, dw = sw * 2, dh = sh * 2;
            var src = new byte[sw * sh];
            for (int y = 0; y < sh; y++)
                for (int x = 0; x < sw; x++)
                    src[y * sw + x] = t.Pixels[y * t.BytesPerLine + x];

            var outPix = new byte[dw * dh];
            int changed = 0;
            for (int y = 0; y < sh; y++)
                for (int x = 0; x < sw; x++)
                {
                    byte P = src[y * sw + x];
                    byte A = src[(y > 0 ? y - 1 : y) * sw + x];
                    byte D = src[(y < sh - 1 ? y + 1 : y) * sw + x];
                    byte C = src[y * sw + (x > 0 ? x - 1 : x)];
                    byte B = src[y * sw + (x < sw - 1 ? x + 1 : x)];

                    byte E0 = (C == A && C != D && A != B) ? A : P;
                    byte E1 = (A == B && A != C && B != D) ? B : P;
                    byte E2 = (D == C && D != B && C != A) ? C : P;
                    byte E3 = (B == D && B != A && D != C) ? D : P;
                    if (E0 != P || E1 != P || E2 != P || E3 != P) changed++;

                    int o = (y * 2) * dw + (x * 2);
                    outPix[o] = E0; outPix[o + 1] = E1;
                    outPix[o + dw] = E2; outPix[o + dw + 1] = E3;
                }

            t.Width = dw; t.Height = dh; t.BytesPerLine = dw; t.Pixels = outPix;
            return changed;   // source pixels where Scale2x did something other than replicate
        }

        /// <summary>
        /// Smooth upscale with an unsharp mask, re-quantised into the texture's OWN
        /// palette so no colour is invented and keyed textures stay safe.
        ///
        /// An upscale cannot add detail. What it buys on this engine is smaller texels:
        /// the rasteriser point-samples with no filtering, so a 256px texture magnified on
        /// screen shows hard texel blocks, and at 512 those blocks are half the size. Plain
        /// bicubic trades that blockiness for softness, which is a bad trade on its own --
        /// hence the sharpen, which puts edge definition back after the interpolation.
        ///
        /// sharpen is the unsharp amount: 0 is plain bicubic, 0.5-1.0 is a normal range,
        /// above about 1.5 it starts ringing on the high-contrast grout lines.
        /// </summary>
        public static void ScaleSmooth(AzfTexture t, int factor, bool keyed, double sharpen)
        {
            int sw = t.Width, sh = t.Height;
            int dw = sw * factor, dh = sh * factor;
            int key = keyed ? FindKeyIndex(t.Palette) : -1;

            var rgb  = new byte[sw * sh * 3];
            var mask = new bool[sw * sh];
            for (int y = 0; y < sh; y++)
                for (int x = 0; x < sw; x++)
                {
                    int i = y * sw + x, p = t.Pixels[y * t.BytesPerLine + x];
                    mask[i] = (key >= 0 && p == key);
                    rgb[i * 3] = t.Palette[p * 4]; rgb[i * 3 + 1] = t.Palette[p * 4 + 1]; rgb[i * 3 + 2] = t.Palette[p * 4 + 2];
                }
            if (key >= 0)
            {
                var m = (bool[])mask.Clone();
                for (int pass = 0; pass < 4; pass++)
                {
                    var next = (bool[])m.Clone();
                    for (int y = 0; y < sh; y++)
                        for (int x = 0; x < sw; x++)
                        {
                            int i = y * sw + x;
                            if (!m[i]) continue;
                            int r = 0, g = 0, b = 0, n = 0;
                            for (int dy = -1; dy <= 1; dy++)
                                for (int dx = -1; dx <= 1; dx++)
                                {
                                    int xx = x + dx, yy = y + dy;
                                    if (xx < 0 || yy < 0 || xx >= sw || yy >= sh) continue;
                                    int j = yy * sw + xx;
                                    if (m[j]) continue;
                                    r += rgb[j * 3]; g += rgb[j * 3 + 1]; b += rgb[j * 3 + 2]; n++;
                                }
                            if (n > 0) { rgb[i*3]=(byte)(r/n); rgb[i*3+1]=(byte)(g/n); rgb[i*3+2]=(byte)(b/n); next[i]=false; }
                        }
                    m = next;
                }
            }

            var src = new Bitmap(sw, sh, PixelFormat.Format24bppRgb);
            var sd = src.LockBits(new Rectangle(0, 0, sw, sh), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
            for (int y = 0; y < sh; y++)
                for (int x = 0; x < sw; x++)
                {
                    int i = (y * sw + x) * 3;
                    System.Runtime.InteropServices.Marshal.WriteByte(sd.Scan0, y*sd.Stride + x*3 + 0, rgb[i+2]);
                    System.Runtime.InteropServices.Marshal.WriteByte(sd.Scan0, y*sd.Stride + x*3 + 1, rgb[i+1]);
                    System.Runtime.InteropServices.Marshal.WriteByte(sd.Scan0, y*sd.Stride + x*3 + 2, rgb[i+0]);
                }
            src.UnlockBits(sd);

            var dst = new Bitmap(dw, dh, PixelFormat.Format24bppRgb);
            using (var g2 = Graphics.FromImage(dst))
            {
                g2.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g2.PixelOffsetMode   = PixelOffsetMode.Half;
                g2.SmoothingMode     = SmoothingMode.HighQuality;
                g2.DrawImage(src, new Rectangle(0, 0, dw, dh));
            }

            // upscaled RGB into a flat array so the unsharp pass can read neighbours
            var up = new byte[dw * dh * 3];
            var dd0 = dst.LockBits(new Rectangle(0, 0, dw, dh), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            for (int y = 0; y < dh; y++)
                for (int x = 0; x < dw; x++)
                {
                    int o = y * dd0.Stride + x * 3, i = (y * dw + x) * 3;
                    up[i + 2] = System.Runtime.InteropServices.Marshal.ReadByte(dd0.Scan0, o);
                    up[i + 1] = System.Runtime.InteropServices.Marshal.ReadByte(dd0.Scan0, o + 1);
                    up[i + 0] = System.Runtime.InteropServices.Marshal.ReadByte(dd0.Scan0, o + 2);
                }
            dst.UnlockBits(dd0);

            if (sharpen > 0.0)
            {
                var sharp = new byte[dw * dh * 3];
                for (int y = 0; y < dh; y++)
                    for (int x = 0; x < dw; x++)
                    {
                        int i = (y * dw + x) * 3;
                        for (int c = 0; c < 3; c++)
                        {
                            int sum = 0, n = 0;
                            for (int dy = -1; dy <= 1; dy++)
                                for (int dx = -1; dx <= 1; dx++)
                                {
                                    int xx = x + dx, yy = y + dy;
                                    if (xx < 0 || yy < 0 || xx >= dw || yy >= dh) continue;
                                    sum += up[((yy * dw + xx) * 3) + c]; n++;
                                }
                            double blur = (double)sum / n;
                            double v = up[i + c] + sharpen * (up[i + c] - blur);
                            sharp[i + c] = (byte)(v < 0 ? 0 : (v > 255 ? 255 : v));
                        }
                    }
                up = sharp;
            }

            var outPix = new byte[dw * dh];
            int np = t.Palette.Length / 4;
            var cache = new System.Collections.Generic.Dictionary<int, byte>();
            for (int y = 0; y < dh; y++)
                for (int x = 0; x < dw; x++)
                {
                    if (key >= 0 && mask[(y / factor) * sw + (x / factor)]) { outPix[y * dw + x] = (byte)key; continue; }
                    int i = (y * dw + x) * 3;
                    int r = up[i], g = up[i + 1], b = up[i + 2];
                    int rgbKey = (r << 16) | (g << 8) | b;
                    byte idx;
                    if (!cache.TryGetValue(rgbKey, out idx))
                    {
                        int best = 0, bestD = int.MaxValue;
                        for (int k = 0; k < np; k++)
                        {
                            if (k == key) continue;
                            int dr = t.Palette[k*4] - r, dg = t.Palette[k*4+1] - g, db = t.Palette[k*4+2] - b;
                            int d = dr*dr + dg*dg + db*db;
                            if (d < bestD) { bestD = d; best = k; }
                        }
                        idx = (byte)best; cache[rgbKey] = idx;
                    }
                    outPix[y * dw + x] = idx;
                }
            src.Dispose(); dst.Dispose();
            t.Width = dw; t.Height = dh; t.BytesPerLine = dw; t.Pixels = outPix;
        }

        public static void Scale(AzfTexture t, int factor, bool keyed)
        {
            int sw = t.Width, sh = t.Height;
            int dw = sw * factor, dh = sh * factor;
            int key = keyed ? FindKeyIndex(t.Palette) : -1;

            // source -> RGB, with key pixels marked
            var rgb  = new byte[sw * sh * 3];
            var mask = new bool[sw * sh];
            for (int y = 0; y < sh; y++)
                for (int x = 0; x < sw; x++)
                {
                    int i = y * sw + x, p = t.Pixels[y * t.BytesPerLine + x];
                    mask[i] = (key >= 0 && p == key);
                    rgb[i * 3]     = t.Palette[p * 4];
                    rgb[i * 3 + 1] = t.Palette[p * 4 + 1];
                    rgb[i * 3 + 2] = t.Palette[p * 4 + 2];
                }

            // flood the key region outward from real pixels so the resampler
            // never averages the key colour into a sprite edge
            if (key >= 0)
            {
                var m = (bool[])mask.Clone();
                for (int pass = 0; pass < 4; pass++)
                {
                    var next = (bool[])m.Clone();
                    for (int y = 0; y < sh; y++)
                        for (int x = 0; x < sw; x++)
                        {
                            int i = y * sw + x;
                            if (!m[i]) continue;
                            int r = 0, g = 0, b = 0, n = 0;
                            for (int dy = -1; dy <= 1; dy++)
                                for (int dx = -1; dx <= 1; dx++)
                                {
                                    int xx = x + dx, yy = y + dy;
                                    if (xx < 0 || yy < 0 || xx >= sw || yy >= sh) continue;
                                    int j = yy * sw + xx;
                                    if (m[j]) continue;
                                    r += rgb[j * 3]; g += rgb[j * 3 + 1]; b += rgb[j * 3 + 2]; n++;
                                }
                            if (n > 0)
                            {
                                rgb[i * 3] = (byte)(r / n); rgb[i * 3 + 1] = (byte)(g / n); rgb[i * 3 + 2] = (byte)(b / n);
                                next[i] = false;
                            }
                        }
                    m = next;
                }
            }

            // smooth upscale of the colour
            var src = new Bitmap(sw, sh, PixelFormat.Format24bppRgb);
            var sd = src.LockBits(new Rectangle(0, 0, sw, sh), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
            for (int y = 0; y < sh; y++)
                for (int x = 0; x < sw; x++)
                {
                    int i = (y * sw + x) * 3;
                    System.Runtime.InteropServices.Marshal.WriteByte(sd.Scan0, y * sd.Stride + x * 3 + 0, rgb[i + 2]); // B
                    System.Runtime.InteropServices.Marshal.WriteByte(sd.Scan0, y * sd.Stride + x * 3 + 1, rgb[i + 1]); // G
                    System.Runtime.InteropServices.Marshal.WriteByte(sd.Scan0, y * sd.Stride + x * 3 + 2, rgb[i + 0]); // R
                }
            src.UnlockBits(sd);

            var dst = new Bitmap(dw, dh, PixelFormat.Format24bppRgb);
            using (var g2 = Graphics.FromImage(dst))
            {
                g2.InterpolationMode  = InterpolationMode.HighQualityBicubic;
                g2.PixelOffsetMode    = PixelOffsetMode.Half;
                g2.SmoothingMode      = SmoothingMode.HighQuality;
                g2.DrawImage(src, new Rectangle(0, 0, dw, dh));
            }

            // re-quantise into the ORIGINAL palette, with the mask nearest-scaled
            var outPix = new byte[dw * dh];
            var dd = dst.LockBits(new Rectangle(0, 0, dw, dh), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            int np = t.Palette.Length / 4;
            var cache = new System.Collections.Generic.Dictionary<int, byte>();
            for (int y = 0; y < dh; y++)
                for (int x = 0; x < dw; x++)
                {
                    if (key >= 0 && mask[(y / factor) * sw + (x / factor)]) { outPix[y * dw + x] = (byte)key; continue; }
                    int o = y * dd.Stride + x * 3;
                    int b = System.Runtime.InteropServices.Marshal.ReadByte(dd.Scan0, o);
                    int g = System.Runtime.InteropServices.Marshal.ReadByte(dd.Scan0, o + 1);
                    int r = System.Runtime.InteropServices.Marshal.ReadByte(dd.Scan0, o + 2);
                    int rgbKey = (r << 16) | (g << 8) | b;
                    byte idx;
                    if (!cache.TryGetValue(rgbKey, out idx))
                    {
                        int best = 0, bestD = int.MaxValue;
                        for (int i = 0; i < np; i++)
                        {
                            if (i == key) continue;              // never invent a keyed pixel
                            int dr = t.Palette[i * 4] - r, dg = t.Palette[i * 4 + 1] - g, db = t.Palette[i * 4 + 2] - b;
                            int d = dr * dr + dg * dg + db * db;
                            if (d < bestD) { bestD = d; best = i; }
                        }
                        idx = (byte)best; cache[rgbKey] = idx;
                    }
                    outPix[y * dw + x] = idx;
                }
            dst.UnlockBits(dd);
            src.Dispose(); dst.Dispose();

            t.Width = dw; t.Height = dh; t.BytesPerLine = dw; t.Pixels = outPix;
        }
    }
}
