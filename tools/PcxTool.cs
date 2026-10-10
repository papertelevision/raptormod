using System;
using System.IO;
using System.Drawing;
using System.Drawing.Imaging;

namespace LeTool
{
    /// <summary>
    /// Decoder for the game's 8-bit RLE PCX files (all HUD art, fonts and cursors).
    /// Palette is the trailing 769 bytes: a 0x0C marker followed by 256 RGB triples.
    /// </summary>
    public class Pcx
    {
        public int Width, Height, BitsPerPixel, Planes, BytesPerLine;
        public byte[] Pixels;          // Width * Height, one palette index per pixel
        public byte[] Palette;         // 768 bytes, RGB

        public static Pcx Load(string path)
        {
            try { return FromBytes(File.ReadAllBytes(path)); }
            catch (Exception e) { throw new Exception(e.Message + " (" + path + ")"); }
        }

        // Decode from memory, so images can come straight out of the CD image
        // without being written to disk first.
        public static Pcx FromBytes(byte[] f)
        {
            if (f == null || f.Length < 128 || f[0] != 0x0A) throw new Exception("not a PCX");

            Pcx p = new Pcx();
            p.BitsPerPixel = f[3];
            int xmin = BitConverter.ToUInt16(f, 4),  ymin = BitConverter.ToUInt16(f, 6);
            int xmax = BitConverter.ToUInt16(f, 8),  ymax = BitConverter.ToUInt16(f, 10);
            p.Width  = xmax - xmin + 1;
            p.Height = ymax - ymin + 1;
            p.Planes = f[65];
            p.BytesPerLine = BitConverter.ToUInt16(f, 66);

            p.Palette = new byte[768];
            if (f.Length >= 769 && f[f.Length - 769] == 0x0C)
                Array.Copy(f, f.Length - 768, p.Palette, 0, 768);

            p.Pixels = new byte[p.Width * p.Height];
            int src = 128;
            int total = p.BytesPerLine * p.Planes * p.Height;
            byte[] raw = new byte[total];
            int w = 0;
            while (w < total && src < f.Length)
            {
                byte b = f[src++];
                if ((b & 0xC0) == 0xC0)
                {
                    int run = b & 0x3F;
                    if (src >= f.Length) break;
                    byte v = f[src++];
                    for (int i = 0; i < run && w < total; i++) raw[w++] = v;
                }
                else raw[w++] = b;
            }
            for (int y = 0; y < p.Height; y++)
                for (int x = 0; x < p.Width; x++)
                {
                    int o = y * p.BytesPerLine * p.Planes + x;
                    p.Pixels[y * p.Width + x] = (o < raw.Length) ? raw[o] : (byte)0;
                }
            return p;
        }

        public void SavePng(string outPath, int scale)
        {
            using (Bitmap bmp = new Bitmap(Width * scale, Height * scale, PixelFormat.Format24bppRgb))
            {
                for (int y = 0; y < Height; y++)
                    for (int x = 0; x < Width; x++)
                    {
                        int idx = Pixels[y * Width + x] * 3;
                        Color c = Color.FromArgb(Palette[idx], Palette[idx + 1], Palette[idx + 2]);
                        for (int sy = 0; sy < scale; sy++)
                            for (int sx = 0; sx < scale; sx++)
                                bmp.SetPixel(x * scale + sx, y * scale + sy, c);
                    }
                bmp.Save(outPath, ImageFormat.Png);
            }
        }

        /// <summary>Write an 8-bit RLE PCX the game can load.</summary>
        public void SavePcx(string path)
        {
            int bpl = Width + (Width & 1);          // bytes per line must be even
            using (var fs = File.Create(path))
            using (var w = new BinaryWriter(fs))
            {
                byte[] h = new byte[128];
                h[0] = 0x0A; h[1] = 5; h[2] = 1; h[3] = 8;
                BitConverter.GetBytes((ushort)0).CopyTo(h, 4);
                BitConverter.GetBytes((ushort)0).CopyTo(h, 6);
                BitConverter.GetBytes((ushort)(Width - 1)).CopyTo(h, 8);
                BitConverter.GetBytes((ushort)(Height - 1)).CopyTo(h, 10);
                BitConverter.GetBytes((ushort)72).CopyTo(h, 12);
                BitConverter.GetBytes((ushort)72).CopyTo(h, 14);
                h[65] = 1;                                   // planes
                BitConverter.GetBytes((ushort)bpl).CopyTo(h, 66);
                BitConverter.GetBytes((ushort)1).CopyTo(h, 68);   // colour palette
                w.Write(h);

                byte[] line = new byte[bpl];
                for (int y = 0; y < Height; y++)
                {
                    for (int x = 0; x < Width; x++) line[x] = Pixels[y * Width + x];
                    if (bpl > Width) line[Width] = 0;
                    int i = 0;
                    while (i < bpl)
                    {
                        byte v = line[i]; int run = 1;
                        while (i + run < bpl && line[i + run] == v && run < 63) run++;
                        if (run > 1 || (v & 0xC0) == 0xC0) { w.Write((byte)(0xC0 | run)); w.Write(v); }
                        else w.Write(v);
                        i += run;
                    }
                }
                w.Write((byte)0x0C);
                w.Write(Palette);
            }
        }

        /// <summary>Nearest-neighbour scale of a sub-rectangle, drawn into this image.
        /// Nearest-neighbour keeps every pixel a valid palette index -- interpolating
        /// indices would produce meaningless colours in an 8-bit paletted image.</summary>
        public void BlitScaled(Pcx src, int sx, int sy, int sw, int sh, int dx, int dy, int dw, int dh)
        {
            for (int y = 0; y < dh; y++)
                for (int x = 0; x < dw; x++)
                {
                    int px = sx + (int)((long)x * sw / dw);
                    int py = sy + (int)((long)y * sh / dh);
                    int tx = dx + x, ty = dy + y;
                    if (tx < 0 || ty < 0 || tx >= Width || ty >= Height) continue;
                    if (px < 0 || py < 0 || px >= src.Width || py >= src.Height) continue;
                    Pixels[ty * Width + tx] = src.Pixels[py * src.Width + px];
                }
        }

        /// <summary>Area-averaged (box filter) scale with palette re-matching.
        /// BlitScaled is nearest-neighbour: it keeps one source pixel per destination
        /// pixel and throws the rest away, which at 55% discards ~70% of the artwork
        /// and is why a downscaled HUD reads rougher than the original. This averages
        /// every source pixel covering a destination pixel, then snaps the result to
        /// the nearest palette entry ALREADY USED in the source region, so nothing
        /// off-palette can appear.
        /// keyIndex is the transparent/background colour: it never contributes to an
        /// average, and a destination pixel that is mostly key stays key, which keeps
        /// sprite edges clean instead of haloing.</summary>
        public void BlitScaledSmooth(Pcx src, int sx, int sy, int sw, int sh, int dx, int dy, int dw, int dh, int keyIndex)
        {
            bool[] used = new bool[256];
            for (int y = 0; y < sh; y++)
                for (int x = 0; x < sw; x++)
                {
                    int px = sx + x, py = sy + y;
                    if (px < 0 || py < 0 || px >= src.Width || py >= src.Height) continue;
                    used[src.Pixels[py * src.Width + px]] = true;
                }
            if (keyIndex >= 0 && keyIndex < 256) used[keyIndex] = false;
            var cand = new System.Collections.Generic.List<int>();
            for (int i = 0; i < 256; i++) if (used[i]) cand.Add(i);

            for (int y = 0; y < dh; y++)
            {
                int y0 = sy + (int)((long)y * sh / dh);
                int y1 = sy + (int)((long)(y + 1) * sh / dh);
                if (y1 <= y0) y1 = y0 + 1;
                for (int x = 0; x < dw; x++)
                {
                    int x0 = sx + (int)((long)x * sw / dw);
                    int x1 = sx + (int)((long)(x + 1) * sw / dw);
                    if (x1 <= x0) x1 = x0 + 1;

                    long r = 0, g = 0, b = 0;
                    int n = 0, nkey = 0, total = 0;
                    for (int py = y0; py < y1; py++)
                        for (int px = x0; px < x1; px++)
                        {
                            if (px < 0 || py < 0 || px >= src.Width || py >= src.Height) continue;
                            total++;
                            int i = src.Pixels[py * src.Width + px];
                            if (i == keyIndex) { nkey++; continue; }
                            r += src.Palette[i * 3]; g += src.Palette[i * 3 + 1]; b += src.Palette[i * 3 + 2];
                            n++;
                        }
                    int tx = dx + x, ty = dy + y;
                    if (tx < 0 || ty < 0 || tx >= Width || ty >= Height) continue;
                    if (n == 0 || (total > 0 && nkey * 2 > total)) { Pixels[ty * Width + tx] = (byte)keyIndex; continue; }
                    int ar = (int)(r / n), ag = (int)(g / n), ab = (int)(b / n);
                    int best = -1; long bestD = long.MaxValue;
                    foreach (int i in cand)
                    {
                        long dr = Palette[i * 3] - ar, dg = Palette[i * 3 + 1] - ag, db = Palette[i * 3 + 2] - ab;
                        long d = dr * dr + dg * dg + db * db;
                        if (d < bestD) { bestD = d; best = i; }
                    }
                    Pixels[ty * Width + tx] = (byte)(best < 0 ? keyIndex : best);
                }
            }
        }

        public void FillRect(int x0, int y0, int w, int h, byte index)
        {
            for (int y = y0; y < y0 + h; y++)
                for (int x = x0; x < x0 + w; x++)
                    if (x >= 0 && y >= 0 && x < Width && y < Height) Pixels[y * Width + x] = index;
        }

        /// <summary>Count of pixels using each palette index -- handy for spotting the
        /// transparent/keyed colour that marks the 3D viewport hole.</summary>
        public int[] Histogram()
        {
            int[] h = new int[256];
            foreach (byte b in Pixels) h[b]++;
            return h;
        }

        /// <summary>Bounding box of every pixel equal to <paramref name="index"/>.</summary>
        public string BoundsOf(byte index)
        {
            int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
            for (int y = 0; y < Height; y++)
                for (int x = 0; x < Width; x++)
                    if (Pixels[y * Width + x] == index)
                    {
                        if (x < x0) x0 = x; if (x > x1) x1 = x;
                        if (y < y0) y0 = y; if (y > y1) y1 = y;
                    }
            if (x1 < 0) return "(none)";
            return string.Format("x {0}..{1}  y {2}..{3}   ({4}x{5})", x0, x1, y0, y1, x1 - x0 + 1, y1 - y0 + 1);
        }
    }
}
