// Align.cs -- measure how the host render differs from the engine's own frame.
//
// Eyeballing a dark corridor is how a transposed view matrix survived once already. This
// reduces both images to row and column PROFILES (how many lit pixels per row/column) and
// cross-correlates them, so a pitch error shows up as a row shift, a yaw error as a column
// shift, and a field-of-view error as a profile that cannot be aligned by shifting at all.
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace AztTool
{
    public class Align
    {
        public int W, H;
        public double[] Row, Col;      // lit-pixel counts
        public double Coverage, MeanLum, MeanLumDrawn;
        public int Lit;

        // A dark texture is not the background. The background is a hard 0; anything the
        // rasteriser actually wrote has some value, so the threshold only has to clear
        // rounding, not separate "dark" from "unlit".
        public const int LIT = 10;

        public static Align Measure(Bitmap bm, int y0, int h)
        {
            var a = new Align { W = bm.Width, H = h };
            a.Row = new double[h]; a.Col = new double[bm.Width];
            var rc = new Rectangle(0, y0, bm.Width, h);
            var bd = bm.LockBits(rc, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            int stride = bd.Stride;
            var buf = new byte[stride * h];
            Marshal.Copy(bd.Scan0, buf, 0, buf.Length);
            bm.UnlockBits(bd);

            double sum = 0, sumDrawn = 0;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < bm.Width; x++)
                {
                    int o = y * stride + x * 3;
                    double l = 0.114 * buf[o] + 0.587 * buf[o + 1] + 0.299 * buf[o + 2];
                    sum += l;
                    if (l >= LIT) { a.Row[y]++; a.Col[x]++; a.Lit++; sumDrawn += l; }
                }
            a.Coverage = a.Lit / (double)(bm.Width * h);
            a.MeanLum = sum / (bm.Width * (double)h);
            a.MeanLumDrawn = a.Lit > 0 ? sumDrawn / a.Lit : 0;
            return a;
        }

        // ---- 8bpp index-buffer helpers ------------------------------------------
        // These loops are in C# because a 1.48M-element scan in PowerShell is both slow
        // and, as this project has already been bitten by, capable of returning a wrong
        // answer with no error -- a per-pixel `-ne 0` there compared an array to a scalar
        // and threw "Could not compare 0 to 0 0 0 ...".
        //
        // Index 0 is the undrawn background in both the engine's own frame and the host's
        // output, so "is this pixel drawn" is exactly `idx != 0` -- no threshold needed.

        public static void IndexProfiles(byte[] idx, int stride, int w, int h,
                                         out double[] row, out double[] col, out int lit)
        {
            row = new double[h]; col = new double[w]; lit = 0;
            for (int y = 0; y < h; y++)
            {
                int b = y * stride;
                for (int x = 0; x < w; x++)
                    if (idx[b + x] != 0) { row[y]++; col[x]++; lit++; }
            }
        }

        // recall = share of the ENGINE's drawn pixels that the host also draws
        // prec   = share of the HOST's drawn pixels that the engine also draws
        // recall near 1 with low precision means the host is a SUPERSET: aimed correctly,
        // drawing things the engine culls. Low recall means genuinely misaimed geometry.
        public static void Overlap(byte[] e, int es, byte[] hh, int hs, int w, int h,
                                   out int inter, out int engineOnly, out int hostOnly)
        {
            inter = 0; engineOnly = 0; hostOnly = 0;
            for (int y = 0; y < h; y++)
            {
                int eb = y * es, hb = y * hs;
                for (int x = 0; x < w; x++)
                {
                    bool a = e[eb + x] != 0, b = hh[hb + x] != 0;
                    if (a && b) inter++; else if (a) engineOnly++; else if (b) hostOnly++;
                }
            }
        }

        // normalised cross-correlation at integer shifts; returns the best shift and score
        public static void BestShift(double[] a, double[] b, int maxShift, out int shift, out double score)
        {
            shift = 0; score = -1;
            for (int s = -maxShift; s <= maxShift; s++)
            {
                double sa = 0, sb = 0, sab = 0, saa = 0, sbb = 0; int n = 0;
                for (int i = 0; i < a.Length; i++)
                {
                    int j = i + s;
                    if (j < 0 || j >= b.Length) continue;
                    sa += a[i]; sb += b[j]; sab += a[i] * b[j]; saa += a[i] * a[i]; sbb += b[j] * b[j]; n++;
                }
                if (n < 8) continue;
                double num = sab - sa * sb / n;
                double den = Math.Sqrt((saa - sa * sa / n) * (sbb - sb * sb / n));
                double r = den > 0 ? num / den : 0;
                if (r > score) { score = r; shift = s; }
            }
        }
    }
}
