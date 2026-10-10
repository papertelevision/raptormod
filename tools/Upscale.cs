// Upscale.cs -- Scale2x (EPX) for Azrael's paletted texture art.
//
// Chosen over a smooth filter because these are 256-colour hand-drawn textures, not
// photographs: bicubic just blurs them, while Scale2x doubles resolution by looking at
// each pixel's four orthogonal neighbours and only rounding a corner where two of them
// agree and the diagonal does not. Edges get cleaner, flat areas stay exactly flat, and
// NOTHING IS INVENTED -- every output pixel is a copy of some input pixel. That matters
// here: an AI upscaler would hallucinate detail and, worse, break the tiling these
// textures depend on.
//
// Applied twice for 4x (256 -> 1024). The point is not that Scale2x looks better at
// 1:1; it is that a 1024x1024 texture can then be sampled with bilinear filtering
// without turning to mush, which is what actually changes how the room reads.
//
// Works on 32bpp BGRA buffers so the caller can hand it anything System.Drawing loads.
using System;

namespace AztTool
{
    public static class Upscale
    {
        // EPX / Scale2x:
        //     B            E0 E1
        //   D E F   ->     E2 E3
        //     H
        //   E0 = (D==B && B!=F && D!=H) ? D : E    ... and so on for the other corners.
        // The B!=F / D!=H guards are what stop it rounding the corner of a genuine
        // 1-pixel checker, which is common in dithered 8-bit art like this.
        public static int[] Scale2(int[] src, int w, int h, out int nw, out int nh)
        {
            nw = w * 2; nh = h * 2;
            int[] dst = new int[nw * nh];
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    int E = src[y * w + x];
                    // clamp at the edges rather than wrap: a wrap would bleed the
                    // opposite side of the texture into the border
                    int B = src[(y > 0 ? y - 1 : 0) * w + x];
                    int H = src[(y < h - 1 ? y + 1 : h - 1) * w + x];
                    int D = src[y * w + (x > 0 ? x - 1 : 0)];
                    int F = src[y * w + (x < w - 1 ? x + 1 : w - 1)];

                    int E0 = E, E1 = E, E2 = E, E3 = E;
                    if (B != H && D != F)
                    {
                        if (D == B) E0 = D;
                        if (B == F) E1 = F;
                        if (D == H) E2 = D;
                        if (H == F) E3 = F;
                    }
                    int o = (y * 2) * nw + (x * 2);
                    dst[o]          = E0;
                    dst[o + 1]      = E1;
                    dst[o + nw]     = E2;
                    dst[o + nw + 1] = E3;
                }
            }
            return dst;
        }

        public static int[] Scale4(int[] src, int w, int h, out int nw, out int nh)
        {
            int w2, h2;
            int[] once = Scale2(src, w, h, out w2, out h2);
            return Scale2(once, w2, h2, out nw, out nh);
        }
    }
}
