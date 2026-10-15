// Raster.cs -- TIER A, STAGE A3: the host's software rasteriser.
//
// Emits PALETTE INDICES, not colours. The injection path takes 8-bit indices into the
// game's live palette, so a renderer that worked in RGB would have to quantise 1.48
// million pixels every frame. Instead the palette is resolved ONCE -- a shade ramp is
// chosen up front out of the captured palette -- and the inner loop writes a byte it
// already has. There is no per-frame colour conversion anywhere in this file.
//
// WHY A SOFTWARE RASTERISER AT ALL, when the point was to escape one. Because the one
// being escaped runs on an EMULATED 486 in a single instruction stream. This one runs
// native on 16 cores. The measurement that justifies the whole exercise: the engine's
// scene pass is 44.7 ms of a 46.7 ms frame, and the game without it runs at 522 fps.
// Beating 44.7 ms natively is not ambitious.
//
// CONVENTIONS, and both of these have cost time before:
//
//  * Reality Lab is ROW-VECTOR / ROW-MAJOR. v' = v * M, and translation lives in ROW 3
//    (indices 12,13,14). Composition is child-then-parent. Doing it the other way round
//    produces a model that is subtly, plausibly wrong -- see Export-XafObj's notes.
//  * The game is Y-UP. The Blender importer's Y-up -> Z-up conversion lives in
//    matrix_world only, so mesh data stays in GAME coordinates, which cost a 140-unit
//    misplacement once ([[azrael-blender-obj-axis-trap]]). Nothing here converts axes.
//
// The forward axis and handedness are PARAMETERS rather than assumptions. Which way the
// engine's camera looks has never been established from its code, only matched by eye in
// Blender, so the first offline render is how it gets settled -- and a wrong guess
// baked into the transform would be invisible in the numbers and obvious in the picture.
using System.Runtime.CompilerServices;
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace AztTool
{
    public class Raster
    {
        public readonly int W, H;
        public readonly byte[] Color;      // palette indices -- what gets injected
        public readonly float[] Depth;     // 1/z, so the test is "greater is nearer"

        // view transform, row-major, row-vector
        float[] _view = Identity();
        float _focal = 1.0f;               // 1/tan(vfov/2)
        float _aspect = 1.0f;
        public float NearZ = 1.0f;
        public int Threads = Environment.ProcessorCount;

        public long TrisIn, TrisCulled, TrisClipped, TrisDrawn, PixelsWritten;

        // ---- LIGHTING: a precomputed shade table, not colour arithmetic ----------
        //
        // The engine is Reality Lab in RAMP MODE, where lighting is a shift along a
        // palette ramp rather than a multiply. The 8-bit equivalent on this side is the
        // classic colormap: for every palette index and every light level, the index of
        // the nearest palette entry to that colour darkened by that much. Then lighting
        // costs ONE TABLE LOOKUP per pixel and the renderer never leaves palette space.
        //
        // Computing light per pixel in RGB and quantising would mean a nearest-colour
        // search per pixel -- 1.48 million of them a frame, which is the thing the
        // whole design exists to avoid.
        public byte[] Shade;            // ShadeLevels * 256, level 0 = darkest
        public int ShadeLevels;

        // DISTANCE IS THE DOMINANT EFFECT IN THIS GAME. Its rooms fade to black within a
        // few hundred units -- that falloff, not surface shading, is what the flat host
        // render was missing. The textures already carry baked-in lighting, so a strong
        // normal term would light them twice; it defaults low deliberately.
        public float FogNear = 60f;
        public float FogFar  = 900f;
        // THE SHAPE OF THE FALLOFF, not just its range. A straight line from FogNear to
        // FogFar left the far end of a corridor at ~52% light where the engine reaches
        // true black, and flattened everything into mid-tones. Raising this holds the
        // near field bright and then drops away hard, which is what the engine's rooms
        // actually do. 1.0 is the old linear behaviour.
        public float FogCurve = 1.0f;
        public float Ambient = 0.30f;   // floor, so nothing goes fully black up close
        public float NormalLight = 0.35f;  // weight of the |N.L| term
        public float LightX = 0.3f, LightY = 1.0f, LightZ = 0.4f;
        float _lightLen = 1f;
        // Snapshotted per draw: Math.Pow on a public field inside the pixel loop would
        // re-read it 1.48 million times a frame.
        float _fogCurve = 1f;

        // Nearest palette entry to each (index, level) pair. Index 0 is left at 0 on
        // every level: it is the transparent/black sentinel and must not become
        // something visible when darkened.
        public static byte[] BuildShadeTable(byte[] pal, int levels)
        {
            if (pal == null || pal.Length < 768) throw new ArgumentException("need a 256-entry palette");
            if (levels < 2 || levels > 64) throw new ArgumentException("levels out of range");
            byte[] tbl = new byte[levels * 256];
            for (int l = 0; l < levels; l++)
            {
                double k = (double)l / (levels - 1);
                for (int i = 0; i < 256; i++)
                {
                    if (i == 0) { tbl[l*256] = 0; continue; }
                    double r = pal[i*3] * k, g = pal[i*3+1] * k, b = pal[i*3+2] * k;
                    int best = 0; double bd = double.MaxValue;
                    // skip 0: it is black AND transparent, so matching to it would turn
                    // darkened pixels into holes rather than into shadow
                    for (int c = 1; c < 256; c++)
                    {
                        double dr = pal[c*3] - r, dg = pal[c*3+1] - g, db = pal[c*3+2] - b;
                        double d = dr*dr*0.299 + dg*dg*0.587 + db*db*0.114;
                        if (d < bd) { bd = d; best = c; }
                    }
                    tbl[l*256 + i] = (byte)best;
                }
            }
            return tbl;
        }

        // ---- TEXTURE FILTERING, IN A PALETTE --------------------------------------------------
        //
        // Two things are wrong with one-texel-per-pixel sampling and they are opposite cases.
        //
        // CLOSE UP, a texel covers many pixels and every one of them gets the same index: the
        // wall turns into flat squares. Real filtering blends the four nearest texels, which
        // needs colours that are not in the palette. So the blend is done by CHOICE instead:
        // each pixel takes one of the four, with odds set by how close it is to each, the
        // odds coming from a fixed 4x4 pattern on the screen. Across a few pixels that
        // averages to the blend; at 1600 across the pattern is finer than the eye resolves.
        // (The trick the software renderers of Unreal's era used.) No extra texture reads.
        //
        // FAR AWAY, many texels fall in one pixel and the picked one changes every frame.
        // That is what the Mips are for: the copy with about one texel per pixel is read
        // instead. Which copy is worked out per pixel -- a floor runs from under the feet
        // to the far wall inside one triangle -- from the triangle's texel density, how
        // obliquely it is seen, and the pixel's depth; the step from one copy to the next
        // is dithered too, so there is no line across the floor where the texture changes.
        public bool Filter = false;
        public float MipBias = -0.35f;          // below 0 keeps textures a little sharper than "exact"
        float[] _log2Tab = new float[0];
        static readonly float[] _bayerB = { 5/16f, 13/16f, 7/16f, 15/16f, 1/16f, 9/16f, 3/16f, 11/16f, 4/16f, 12/16f, 6/16f, 14/16f, 0/16f, 8/16f, 2/16f, 10/16f };
        // RGB (5 bits each) -> nearest palette index, never 0. Built once per palette.
        public static byte[] BuildRgbLut(byte[] pal)
        {
            var lut = new byte[32768];
            Parallel.For(0, 32, r5 =>
            {
                for (int g5 = 0; g5 < 32; g5++)
                    for (int b5 = 0; b5 < 32; b5++)
                    {
                        int r = r5 * 8 + 4, g = g5 * 8 + 4, b = b5 * 8 + 4, best = 1; double bd = double.MaxValue;
                        for (int c = 1; c < 256; c++)
                        {
                            double dr = pal[c*3] - r, dg = pal[c*3+1] - g, db = pal[c*3+2] - b;
                            double d = dr*dr*0.299 + dg*dg*0.587 + db*db*0.114;
                            if (d < bd) { bd = d; best = c; }
                        }
                        lut[r5 << 10 | g5 << 5 | b5] = (byte)best;
                    }
            });
            return lut;
        }
        // RGB at 6 bits a channel -> nearest palette index, never 0: for the upscaler.
        public static byte[] BuildRgbLut6(byte[] pal)
        {
            var lut = new byte[262144];
            Parallel.For(0, 64, r6 =>
            {
                for (int g6 = 0; g6 < 64; g6++)
                    for (int b6 = 0; b6 < 64; b6++)
                    {
                        int r = r6 * 4 + 2, g = g6 * 4 + 2, b = b6 * 4 + 2, best = 1; double bd = double.MaxValue;
                        for (int c = 1; c < 256; c++)
                        {
                            double dr = pal[c*3] - r, dg = pal[c*3+1] - g, db = pal[c*3+2] - b;
                            double d = dr*dr*0.299 + dg*dg*0.587 + db*db*0.114;
                            if (d < bd) { bd = d; best = c; }
                        }
                        lut[r6 << 12 | g6 << 6 | b6] = (byte)best;
                    }
            });
            return lut;
        }
        // The whole texture list of a room, enlarged; textures are shared between rooms and
        // each keeps its own enlarged copy, so a texture is only ever done once.
        public static Tex[] UpscaleAll(Tex[] texes, int factor, byte[] pal, byte[] lut6, float sharpen)
        {
            var res = new Tex[texes.Length];
            for (int i = 0; i < texes.Length; i++)
                res[i] = (texes[i] == null || texes[i].W * texes[i].H < 16) ? texes[i] : texes[i].Upscaled(factor, pal, lut6, sharpen);
            return res;
        }
        public static void EnsureMips(Tex[] texes, byte[] pal, byte[] lut)
        {
            if (texes == null) return;
            foreach (Tex t in texes) if (t != null && t.Mips == null) t.BuildMips(pal, lut);
        }

        // ---- MANY PAINTED TEXTURES AT ONCE (2026-10-12) ----------------------------------------
        // A room's 4K art decoded one PNG at a time took 4-5 s on entering it (Josh saw the 256-colour game the whole while).
        // Several at once: 42 of them in 1.1 s instead of 4.5 s with 8 workers (GDI+ serialises some of each decode, so more
        // workers gain little). Runs in the background; the watcher keeps its loading cover counting from Done meanwhile.
        public sealed class RgbJob
        {
            public int Total; internal int DoneN;
            public int Done { get { return System.Threading.Volatile.Read(ref DoneN); } }
            public bool[] Same; public string[] Error;
            public System.Threading.Tasks.Task Task;
            public bool Finished { get { return Task == null || Task.IsCompleted; } }
        }
        /// <summary>texes[i].LoadRgb(paths[i]) for all i on up to `workers` threads (0 = half the processors, at most 8).
        /// Same[i]: the PNG had the texture's own size; Error[i]: why it failed (null = it loaded).</summary>
        public static RgbJob LoadRgbAsync(Tex[] texes, string[] paths, byte[] pal, int workers)
        {
            var j = new RgbJob { Total = texes.Length, Same = new bool[texes.Length], Error = new string[texes.Length] };
            int k = workers > 0 ? workers : Math.Max(1, Math.Min(8, Environment.ProcessorCount / 2));
            j.Task = System.Threading.Tasks.Task.Run(() =>
                Parallel.For(0, texes.Length, new ParallelOptions { MaxDegreeOfParallelism = k }, i =>
                {
                    try { j.Same[i] = texes[i].LoadRgb(paths[i], pal); }
                    catch (Exception e) { j.Error[i] = e.Message; }
                    System.Threading.Interlocked.Increment(ref j.DoneN);
                }));
            return j;
        }

        /// <summary>texes[i].LoadMat(rough[i], height[i], glow[i], maxSize) for all i, as LoadRgbAsync (Same[i]: a map was there).</summary>
        public static RgbJob LoadMatAsync(Tex[] texes, string[] rough, string[] height, string[] glow, int maxSize, int workers)
        {
            var j = new RgbJob { Total = texes.Length, Same = new bool[texes.Length], Error = new string[texes.Length] };
            int k = workers > 0 ? workers : Math.Max(1, Math.Min(8, Environment.ProcessorCount / 2));
            j.Task = System.Threading.Tasks.Task.Run(() =>
                Parallel.For(0, texes.Length, new ParallelOptions { MaxDegreeOfParallelism = k }, i =>
                {
                    try { j.Same[i] = texes[i].LoadMat(rough[i], height[i], glow[i], maxSize); }
                    catch (Exception e) { j.Error[i] = e.Message; }
                    System.Threading.Interlocked.Increment(ref j.DoneN);
                }));
            return j;
        }

        // ---- THE HELMET LAMP ---------------------------------------------------------------
        //
        // A light that the ENGINE never had: the room at a steady general level, plus a
        // spotlight fixed to the player's head. The textures already carry the artists' baked
        // lighting, so this is a gain on top of them, not a relighting -- the room level only
        // takes the edge off (LampRoom < 1) so that the lamp has somewhere to go, and the lamp
        // lifts what it points at back up to, and past, how the texture was painted.
        //
        // Still one table lookup per pixel and still never leaving the palette. The table is
        // the shade table's big brother: it runs from black THROUGH the unlit colour (gain 1)
        // up to LightMaxGain, so "brighter than painted" is a level like any other.
        //
        // The light sits at the eye, which makes it cheap in a way no other light is:
        //   * the CONE depends only on where a pixel is on the screen (its angle off the view
        //     axis), so it is a lookup by squared distance from the screen centre;
        //   * the FALLOFF depends only on depth, another lookup;
        //   * the FACING term -- a wall square-on is brighter than one seen edge-on -- is one
        //     number per triangle;
        //   * and a light at the eye casts no visible shadows, so there are none to compute.
        // A 4x4 ordered dither on the level hides the steps between table rows; it is locked
        // to the screen, so it does not crawl over the walls as they move.
        public bool Lamp = false;
        public byte[] LightTab; public int LightLevels; public float LightMaxGain = 1.5f;
        public float LampRoom  = 0.62f;     // the room's general level, 1 = exactly as painted
        public float LampPower = 1.25f;     // what the lamp adds at the middle of the beam, close up
        // TWO LOBES. The first version had one wide cone (10-24 degrees in a view 25 degrees
        // tall) and read as a vignette: dark corners, nothing that looked like a beam. A torch
        // is a small hot spot inside a much dimmer corona, so that is what this is.
        public float LampInnerDeg = 7.2f, LampOuterDeg = 19.8f;    // the hot spot: full strength inside, gone outside
        // The corona is the FIRST version's whole beam, kept: Josh liked the spot but found v2 too
        // dark, and asked for the lit area of v1 back underneath it. Full strength inside
        // LampHaloInnerDeg, gone by LampHaloDeg, and it carries LampHalo of the lamp's power.
        public float LampHalo = 0.60f, LampHaloInnerDeg = 10f, LampHaloDeg = 24f;
        public float LampSpill = 0.04f;     // fraction of the lamp that reaches everything in view
        public float LampRange = 550f;      // distance at which the lamp is down to half
        // WHERE THE BEAM POINTS, as an offset from the middle of the screen in pixels. The
        // caller moves this so the beam trails the view a little when the player turns; a
        // beam nailed to the screen centre is the other half of why it read as a vignette.
        public float LampCx = 0f, LampCy = 0f;

        // ---- SHADOWS FROM THE LAMP ---------------------------------------------------------
        //
        // A lamp exactly at the eye lights everything the eye can see: no shadows, ever. Move
        // it a hand's breadth off to the side and up -- where a lamp on a helmet really is --
        // and things start to hide the wall behind them from it.
        //
        // The standard way: draw the scene's DEPTH once from the lamp (a second, small Raster,
        // the "shadow map"), then for each pixel of the real picture ask whether the lamp can
        // see that point -- is the point further from the lamp than whatever the lamp saw in
        // that direction? If so it gets the room's level only, without the lamp.
        //
        // What makes it nearly free here is that the lamp is given the CAMERA'S OWN
        // ORIENTATION and merely shifted sideways and up by (ShadowOx, ShadowOy). Lamp space is
        // then view space minus a constant, the depth along the axis is the same number in
        // both, and a pixel's place in the shadow map is two multiply-adds from values the
        // pixel loop already has:  (x/z)_lamp = (x/z)_eye - ShadowOx * (1/z).
        //
        // Four neighbouring map texels are tested and averaged, and the result goes through
        // the same ordered dither as the rest of the lighting, which is what softens the edge.
        // Outside the map (the lamp's view is a little wider than its beam) nothing is shadowed.
        public float[] ShadowMap; public int ShadowW, ShadowH; public float ShadowFocalPx, ShadowOx, ShadowOy;
        public float ShadowBias = 0.02f;
        // SOFT EDGES. A shadow's edge used to be decided by four map texels counted whole, so it
        // came out in five steps and, with no dither in true colour, as a visible staircase. Each
        // lookup now takes four taps spread ShadowSoft texels round the point, each tap a 2x2
        // weighted by where it falls -- sixteen reads, a smooth penumbra about two texels wide.
        public float ShadowSoft = 1.0f;
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static float ShadowTap(float[] m, int mW, float su, float sv, float lim)
        {
            int ui = (int)su, vi = (int)sv; float fu = su - ui, fv = sv - vi; int so = vi * mW + ui;
            float a = m[so] > lim ? 1f : 0f, b = m[so + 1] > lim ? 1f : 0f, c = m[so + mW] > lim ? 1f : 0f, d = m[so + mW + 1] > lim ? 1f : 0f;
            return (a + (b - a) * fu) + ((c + (d - c) * fu) - (a + (b - a) * fu)) * fv;
        }
        /// <summary>Blocked fraction, 0..1, at (su, sv) in a map of mW x mH; -1 if the footprint falls outside it.</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static float ShadowSoftAt(float[] m, int mW, int mH, float su, float sv, float lim, float r)
        {
            if (su - r < 0f || sv - r < 0f || su + r >= mW - 1 || sv + r >= mH - 1) return -1f;
            // most pixels are wholly lit or wholly in shadow: one look at the four texels round the
            // point settles those, and only a pixel near an edge pays for the spread taps
            int ui = (int)su, vi = (int)sv, so = vi * mW + ui;
            bool a = m[so] > lim, b = m[so + 1] > lim, c = m[so + mW] > lim, d = m[so + mW + 1] > lim;
            if (a == b && b == c && c == d) { if (!a) return 0f; if (r <= 0f) return 1f; }
            if (r <= 0f) return ShadowTap(m, mW, su, sv, lim);
            // two taps on a diagonal: a penumbra about 2r texels wide for eight reads, not sixteen
            return 0.5f * (ShadowTap(m, mW, su - r, sv - r, lim) + ShadowTap(m, mW, su + r, sv + r, lim));
        }
        // HOW DARK, AND HOW FAR. A shadow used to mean "the lamp does not reach here", which
        // leaves it at the room's level -- visible only where the beam is strong. ShadowDark
        // takes it below that: in full shadow the room level itself drops by this fraction.
        // And a shadow thins out with distance from the player: full strength up to
        // ShadowNear, gone by ShadowFar, so far walls are not striped by things near the eye.
        public float ShadowDark = 0.30f, ShadowNear = 140f, ShadowFar = 900f;
        float[] _sfadeTab = new float[0];
        // The map is as WIDE as the picture, not square: the first one was a square 64 degrees
        // against a view 78 degrees across, so the outer seventh of the screen on each side
        // had no shadows at all -- a door in the middle cast one and the wall beside it did not.
        public void SetShadow(float[] depthFromLamp, int w, int h, float focalPx, float ox, float oy)
        {
            if (depthFromLamp != null && depthFromLamp.Length != w * h) throw new ArgumentException("shadow map size does not match its data");
            ShadowMap = depthFromLamp; ShadowW = w; ShadowH = h; ShadowFocalPx = focalPx; ShadowOx = ox; ShadowOy = oy;
        }

        // A SECOND LAMP, for a pair set either side of the visor. One lamp off to the right
        // throws every shadow to the left, which looks wrong for a light the player is told is
        // in the middle of their face; a lamp truly in the middle throws none. Two lamps,
        // mirror images, each carrying half the light, give a fringe of half-shadow on BOTH
        // sides of whatever is in the beam -- what a wide lamp does. Same map shape and
        // focal length as the first; null switches it off.
        public float[] ShadowMap2; public float Shadow2Ox, Shadow2Oy;
        public void SetShadow2(float[] depthFromLamp, float ox, float oy)
        {
            if (depthFromLamp != null && depthFromLamp.Length != ShadowW * ShadowH) throw new ArgumentException("second shadow map must be the same size as the first");
            ShadowMap2 = depthFromLamp; Shadow2Ox = ox; Shadow2Oy = oy;
        }

        // HOW FAR CAN A RAY GO? From (px,py,pz) along the unit direction (dx,dy,dz), the
        // distance to the first face of the soup, either side; `limit` if nothing is nearer.
        // Used to keep a lamp on the player's side of walls and ceilings.
        public static float RayDistance(float[] vx, int[] idx, int[] triTex, float px, float py, float pz, float dx, float dy, float dz, float limit)
        {
            float best = limit; int nTri = idx.Length / 3;
            for (int t = 0; t < nTri; t++)
            {
                if (triTex[t] < 0) continue;
                int a = idx[t*3]*3, b = idx[t*3+1]*3, c = idx[t*3+2]*3;
                float e1x = vx[b]-vx[a], e1y = vx[b+1]-vx[a+1], e1z = vx[b+2]-vx[a+2];
                float e2x = vx[c]-vx[a], e2y = vx[c+1]-vx[a+1], e2z = vx[c+2]-vx[a+2];
                float hx = dy*e2z - dz*e2y, hy = dz*e2x - dx*e2z, hz = dx*e2y - dy*e2x;
                float det = e1x*hx + e1y*hy + e1z*hz;
                if (det > -1e-7f && det < 1e-7f) continue;
                float inv = 1f / det;
                float sx = px - vx[a], sy = py - vx[a+1], sz = pz - vx[a+2];
                float u = (sx*hx + sy*hy + sz*hz) * inv; if (u < 0f || u > 1f) continue;
                float qx = sy*e1z - sz*e1y, qy = sz*e1x - sx*e1z, qz = sx*e1y - sy*e1x;
                float v = (dx*qx + dy*qy + dz*qz) * inv; if (v < 0f || u + v > 1f) continue;
                float d = (e2x*qx + e2y*qy + e2z*qz) * inv;
                if (d > 0.25f && d < best) best = d;
            }
            return best;
        }

        // HOW MUCH ROOM IS THERE ABOVE THIS POINT? The distance straight up (world +Y) to the
        // nearest face of the soup, any facing; `limit` if there is none within it. The lamp
        // sits above the eye, and in a 60-unit tunnel a lamp 22 above a 45-unit eye would be
        // on the far side of the ceiling -- with the whole tunnel in its shadow.
        public static float ClearanceUp(float[] vx, int[] idx, int[] triTex, float px, float py, float pz, float limit)
        {
            float best = limit; int nTri = idx.Length / 3;
            for (int t = 0; t < nTri; t++)
            {
                if (triTex[t] < 0) continue;
                int a = idx[t*3]*3, b = idx[t*3+1]*3, c = idx[t*3+2]*3;
                float ax = vx[a], az = vx[a+2], bx = vx[b], bz = vx[b+2], cx = vx[c], cz = vx[c+2];
                float d = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz);
                if (d > -1e-9f && d < 1e-9f) continue;
                float l0 = ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / d; if (l0 < 0f) continue;
                float l1 = ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / d; if (l1 < 0f) continue;
                float l2 = 1f - l0 - l1; if (l2 < 0f) continue;
                float y = l0 * vx[a+1] + l1 * vx[b+1] + l2 * vx[c+1];
                float up = y - py;
                if (up > 0.5f && up < best) best = up;
            }
            return best;
        }
        float[] _coneTab = new float[0], _distTab = new float[0];
        float _coneKey = float.NaN;
        static readonly float[] _bayer = { 0/16f, 8/16f, 2/16f, 10/16f, 12/16f, 4/16f, 14/16f, 6/16f, 3/16f, 11/16f, 1/16f, 9/16f, 15/16f, 7/16f, 13/16f, 5/16f };
        const int CONE_N = 1024, DIST_N = 1024; const float CONE_MAX_TAN2 = 2.0f, DIST_STEP = 2f;
        public float FocalPixels { get { return _focal * VHf * 0.5f; } }
        /// <summary>Rows of the picture that are the VIEW: the projection is centred in them, and any rows
        /// below carry on with the same projection (the 3D under the widescreen panel). 0 = all of it.</summary>
        public int ViewRows;
        float VHf { get { return ViewRows > 0 ? ViewRows : H; } }
        /// <summary>The view's centre row (pixels from the top).</summary>
        public float CentreY { get { return VHf * 0.5f; } }

        public static byte[] BuildLightTable(byte[] pal, int levels, float maxGain)
        {
            if (pal == null || pal.Length < 768) throw new ArgumentException("need a 256-entry palette");
            if (levels < 2 || levels > 128) throw new ArgumentException("levels out of range");
            byte[] tbl = new byte[levels * 256];
            for (int l = 0; l < levels; l++)
            {
                double k = maxGain * l / (levels - 1);
                for (int i = 1; i < 256; i++)
                {
                    double r = Math.Min(255.0, pal[i*3] * k), g = Math.Min(255.0, pal[i*3+1] * k), b = Math.Min(255.0, pal[i*3+2] * k);
                    int best = 1; double bd = double.MaxValue;
                    for (int c = 1; c < 256; c++)      // never 0: black AND transparent in the guest
                    {
                        double dr = pal[c*3] - r, dg = pal[c*3+1] - g, db = pal[c*3+2] - b;
                        double d = dr*dr*0.299 + dg*dg*0.587 + db*db*0.114;
                        if (d < bd) { bd = d; best = c; }
                    }
                    tbl[l*256 + i] = (byte)best;
                }
            }
            return tbl;
        }
        public void SetLightTable(byte[] tbl, int levels, float maxGain)
        {
            if (tbl == null || tbl.Length != levels * 256) throw new ArgumentException("light table size does not match its level count");
            LightTab = tbl; LightLevels = levels; LightMaxGain = maxGain;
        }
        void BuildLampTables()
        {
            float key = LampInnerDeg * 1000f + LampOuterDeg + LampSpill * 7f + LampRange * 0.001f + LampHalo * 31f + LampHaloDeg * 0.37f + LampHaloInnerDeg * 0.011f + ShadowNear * 0.0031f + ShadowFar * 0.00007f;
            if (key == _coneKey && _coneTab.Length == CONE_N) return;
            _coneKey = key;
            _coneTab = new float[CONE_N]; _distTab = new float[DIST_N]; _sfadeTab = new float[DIST_N];
            for (int i = 0; i < DIST_N; i++)
            {
                double d = i * DIST_STEP, t = (ShadowFar - d) / Math.Max(1.0, ShadowFar - ShadowNear);
                if (t < 0) t = 0; else if (t > 1) t = 1;
                _sfadeTab[i] = (float)(t * t * (3 - 2 * t));
            }
            double ci = Math.Cos(LampInnerDeg * Math.PI / 180), co = Math.Cos(LampOuterDeg * Math.PI / 180);
            for (int i = 0; i < CONE_N; i++)
            {
                double tan2 = CONE_MAX_TAN2 * i / (CONE_N - 1);
                double cos = 1.0 / Math.Sqrt(1.0 + tan2);
                double t = (cos - co) / (ci - co); if (t < 0) t = 0; else if (t > 1) t = 1;
                t = t * t * (3 - 2 * t);                               // soft edge
                double ch = Math.Cos(LampHaloDeg * Math.PI / 180), chi = Math.Cos(LampHaloInnerDeg * Math.PI / 180);
                double h = (cos - ch) / (chi - ch); if (h < 0) h = 0; else if (h > 1) h = 1;
                h = h * h * (3 - 2 * h);
                double rest = 1 - LampSpill - LampHalo; if (rest < 0) rest = 0;
                _coneTab[i] = (float)(LampSpill + LampHalo * h + rest * t);
            }
            for (int i = 0; i < DIST_N; i++)
            {
                double d = i * DIST_STEP / LampRange;
                _distTab[i] = (float)(1.0 / (1.0 + d * d));
            }
        }

        public void SetShadeTable(byte[] tbl, int levels)
        {
            if (tbl == null || tbl.Length != levels * 256) throw new ArgumentException("shade table size does not match its level count");
            Shade = tbl; ShadeLevels = levels;
        }

        public Raster(int w, int h)
        {
            if (w <= 0 || h <= 0) throw new ArgumentException("bad size");
            W = w; H = h;
            Color = new byte[w * h];
            Depth = new float[w * h];
            _aspect = (float)w / h;
        }

        static float[] Identity()
        {
            return new float[] { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
        }

        public void SetVerticalFov(double degrees)
        {
            if (degrees <= 1 || degrees >= 179) throw new ArgumentException("fov out of range");
            _focal = (float)(1.0 / Math.Tan(degrees * Math.PI / 360.0));
        }

        // The camera's WORLD matrix, as the engine holds it (frame+0x90). The view
        // transform is its inverse. For a rigid transform that is the transpose of the
        // rotation plus a re-expressed translation -- doing it as a general 4x4 inverse
        // would be slower and would hide a non-rigid matrix instead of being wrong
        // loudly, so this asserts rigidity rather than tolerating it.
        public void SetCameraWorld(float[] m)
        {
            if (m == null || m.Length != 16) throw new ArgumentException("need a 4x4");
            // rows 0..2 are the basis; row 3 is the position
            float[] r = new float[9];
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) r[i*3+j] = m[i*4+j];
            for (int i = 0; i < 3; i++)
            {
                double len = Math.Sqrt(r[i*3]*r[i*3] + r[i*3+1]*r[i*3+1] + r[i*3+2]*r[i*3+2]);
                if (len < 0.9 || len > 1.1)
                    throw new ArgumentException("camera basis row " + i + " has length " + len.ToString("F3") + " -- not a rigid transform");
            }
            float px = m[12], py = m[13], pz = m[14];
            // Row-vector convention: world = c*R + t, so c = world*R^T - t*R^T.
            float[] v = Identity();
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) v[i*4+j] = r[j*3+i];
            // (t * R^T).x is t DOTTED WITH ROW 0 of R, not with its column 0. Getting
            // that backwards is invisible for an axis-aligned camera and catastrophic
            // otherwise: with the columns, a camera placed on +X looking at the origin
            // put the model ten units BEHIND itself, so every triangle failed the near
            // plane and the render came back empty with nothing culled. Views along
            // +/-Z still worked, because the rotation there is symmetric enough to hide
            // it -- which is exactly why the orbit test exists.
            v[12] = -(px*r[0] + py*r[1] + pz*r[2]);   // -(t . right)
            v[13] = -(px*r[3] + py*r[4] + pz*r[5]);   // -(t . up)
            v[14] = -(px*r[6] + py*r[7] + pz*r[8]);   // -(t . forward)
            _view = v;
        }

        // Straight view matrix, for the offline tests where there is no live camera.
        public void SetViewMatrix(float[] m)
        {
            if (m == null || m.Length != 16) throw new ArgumentException("need a 4x4");
            _view = (float[])m.Clone();
        }

        public void LookAt(float ex, float ey, float ez, float tx, float ty, float tz, int upAxis)
        {
            float fx = tx-ex, fy = ty-ey, fz = tz-ez;
            float fl = (float)Math.Sqrt(fx*fx+fy*fy+fz*fz);
            if (fl < 1e-6f) throw new ArgumentException("eye and target coincide");
            fx/=fl; fy/=fl; fz/=fl;
            float ux = upAxis==0?1:0, uy = upAxis==1?1:0, uz = upAxis==2?1:0;
            // right = up x forward
            float rx = uy*fz - uz*fy, ry = uz*fx - ux*fz, rz = ux*fy - uy*fx;
            float rl = (float)Math.Sqrt(rx*rx+ry*ry+rz*rz);
            if (rl < 1e-4f) throw new ArgumentException("looking straight along the up axis");
            rx/=rl; ry/=rl; rz/=rl;
            // trueUp = forward x right
            float tux = fy*rz - fz*ry, tuy = fz*rx - fx*rz, tuz = fx*ry - fy*rx;
            float[] world = new float[] { rx,ry,rz,0, tux,tuy,tuz,0, fx,fy,fz,0, ex,ey,ez,1 };
            LastBasis = new float[] { rx, ry, rz, tux, tuy, tuz, fx, fy, fz };
            SetCameraWorld(world);
        }

        // Counted HERE, not by indexing Color[] from PowerShell. A sampled scan driven
        // from script was reporting 0% coverage for frames that demonstrably contained a
        // million drawn pixels, and a coverage figure that can be wrong is worse than no
        // figure -- it sent the diagnosis at the renderer when the renderer was fine.
        public long CountNonBackground(byte bg)
        {
            long n = 0;
            for (int i = 0; i < Color.Length; i++) if (Color[i] != bg) n++;
            return n;
        }

        public void Clear(byte bg)
        {
            for (int i = 0; i < Color.Length; i++) { Color[i] = bg; Depth[i] = 0f; }
            TrisIn = TrisCulled = TrisClipped = TrisDrawn = PixelsWritten = 0;
        }

        // A texture already reduced to GAME PALETTE INDICES. The reduction happens once,
        // at load, never per frame -- that is the whole reason this renderer can afford
        // 1.48 million pixels in a few milliseconds. Index 0 is transparent (the
        // quantiser emits it for alpha < 128) and is also black, so it doubles as "no
        // pixel here" without needing a separate mask.
        public class Tex
        {
            public byte[] Idx; public int W, H;
            public Tex(byte[] idx, int w, int h)
            {
                if (idx == null || idx.Length != w * h) throw new ArgumentException("texture size does not match its data");
                Idx = idx; W = w; H = h;
            }

            // ---- TRUE COLOUR ---------------------------------------------------------------
            // The same texture as it was painted, 0x00RRGGBB, and its half-size copies down to
            // one texel. Idx stays what decides WHERE the texture has holes (index 0); these
            // only decide what colour the rest is. Null until asked for.
            public class RgbLevel { public int[] Px; public int W, H; }
            public RgbLevel[] Rgb;
            public bool RgbFromFile;
            /// <summary>Worn by something that moves (a character or creature): the graphics card's micro relief, which is
            /// laid in the world, would slide across it, so it is left off these (Import-AztRoom sets it).</summary>
            public bool Moves;
            /// <summary>Casts no shadow (the graphics card's shadow views leave it out): a torch sconce's iron and coals --
            /// Josh, Room Review MINEMAZE/4: its round parts made a 'blobby' shadow; only the wooden stake casts.</summary>
            public bool NoCast;
            /// <summary>GLASS IN ITS HOLES (2026-10-14, Josh, Room Review BAPTIST/1: the windows' pale panes "transparent with 30%
            /// opacity"): above 0, the graphics card draws the texels CutHoles opened as a pane at this share of their own colour
            /// (times GlassTint, the light behind it), unlit -- while the shadow views and the bounce still take them as holes, so
            /// light passes. 0 = holes are holes.</summary>
            public float Glass; public int GlassTint = 0xFFFFFF;
            /// <summary>Worn by a GHOST (a room's "ghost" block names the character): the graphics card leaves it out of the
            /// picture, the shadow views and the reflections and draws it as glowing smoke instead (GpuRaster.GhostOn).
            /// The processor's picture draws it as it always did.</summary>
            public bool Ghost;
            /// <summary>The texture's exported file name without extension (e.g. "37-mineplab"), set when its true colours load.</summary>
            public string Leaf;
            /// <summary>Its palette indices before any holes were cut (CutHoles), so they can be put back.</summary>
            public byte[] IdxOrig;
            /// <summary>The light and shade its ORIGINAL art paints, per texel (255 = the room's well-lit level): the graphics card
            /// shades the room's level and the bounce with it (GpuRaster.BuildArtLight). Null = none.</summary>
            public byte[] ArtLight;
            // ---- MATERIAL (2026-10-12, Josh: "Material tags for every texture ... Shine where it belongs"): what the surface
            // is -- set by the watcher from rooms\_materials.json (name rules, exact names, a room's own "materials") -- and how
            // it shines under the lamp and the placed lights on the graphics card. Shine 0 = matte. Gloss: how tight the
            // highlight is (a Blinn exponent); Metal 0..1: how much it takes the surface's own colour; ShineVary: how much the
            // art's own brightness sets it texel by texel (bright grains and polish shine, painted shadow and cracks do not).
            public string Material;
            public float Shine, Gloss = 16f, Metal, ShineVary;
            /// <summary>How much a wet room's damp shows on it (its material's "wet": 1 stone and rock .. 0 glass, the painted
            /// doorway views, characters): darker and glossier where the room is wet (GpuRaster's WET SURFACES).</summary>
            public float Wet;
            /// <summary>Its share of the graphics card's relief and micro relief (its material's "relief"): 1 stone and wood, 0 on a
            /// shiny surface (Josh, 2026-10-12: relief "makes them all look more grainy and textured where they should be shiny").</summary>
            public float Relief = 1f;
            /// <summary>Its share of the graphics card's PARALLAX DEPTH (its material's "parallax": stone, floor and rock walls and
            /// floors 1, everything else 0 -- Josh, 2026-10-12: "limit this to walls and floors, but not the wooden plank style
            /// floors"). ParallaxSet: named on or off by hand (rooms\_materials.json "parallax" lists, a room's "materials"), so
            /// the art's plank check (GpuRaster.ParallaxGrainMax) does not overrule it.</summary>
            public float Parallax; public bool ParallaxSet;
            /// <summary>How much of its parallax height comes from the art's broad SHADING (0..1: 0 = only the grooves -- mortar,
            /// gaps, cracks -- sink; 1 = bright areas bulge, dark ones sink, with the cracks carved in). A room's "parallax":
            /// {"shade"} (Josh, 2026-10-12, MINEMAZE/7: "The rocks could bulge a bit more throughout, using the texture shading
            /// as a guide for deep cracks and other depth indicators").</summary>
            public float ParallaxShade;
            // COMPANION MAPS (Josh's art pipeline: "<leaf>_rough.png", "_height.png", "_glow.png" beside the colour): one
            // picture, 0xAARRGGBB -- R smoothness (255 - roughness), G height, B glow. MatHas: 1 rough, 2 height, 4 glow.
            public int[] MatPx; public int MatW, MatH, MatHas;
            /// <summary>Reads whichever companion maps are given (null / missing = not there) as greys, at the first one's size
            /// (long side at most maxSize), into MatPx. False if none was there.</summary>
            public bool LoadMat(string rough, string height, string glow, int maxSize)
            {
                string[] files = { rough, height, glow };
                int w = 0, h = 0, has = 0; int[][] grey = new int[3][];
                for (int c = 0; c < 3; c++)
                {
                    string f = files[c]; if (string.IsNullOrEmpty(f) || !System.IO.File.Exists(f)) continue;
                    using (var src = (System.Drawing.Bitmap)System.Drawing.Image.FromFile(f))
                    {
                        if (w == 0)
                        {
                            w = src.Width; h = src.Height;
                            if (maxSize > 0 && Math.Max(w, h) > maxSize) { double k = maxSize / (double)Math.Max(w, h); w = Math.Max(1, (int)Math.Round(w * k)); h = Math.Max(1, (int)Math.Round(h * k)); }
                        }
                        using (var bm = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
                        {
                            using (var g = System.Drawing.Graphics.FromImage(bm))
                            using (var ia = new System.Drawing.Imaging.ImageAttributes())
                            {
                                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy; ia.SetWrapMode(System.Drawing.Drawing2D.WrapMode.TileFlipXY);
                                g.DrawImage(src, new System.Drawing.Rectangle(0, 0, w, h), 0, 0, src.Width, src.Height, System.Drawing.GraphicsUnit.Pixel, ia);
                            }
                            var bd = bm.LockBits(new System.Drawing.Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                            var px = new int[w * h];
                            try { for (int y = 0; y < h; y++) System.Runtime.InteropServices.Marshal.Copy(new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), px, y * w, w); }
                            finally { bm.UnlockBits(bd); }
                            for (int i = 0; i < px.Length; i++) { int p = px[i]; px[i] = (30 * ((p >> 16) & 255) + 59 * ((p >> 8) & 255) + 11 * (p & 255) + 50) / 100; }
                            grey[c] = px; has |= 1 << c;
                        }
                    }
                }
                if (has == 0) { MatPx = null; MatHas = 0; return false; }
                var o = new int[w * h];
                for (int i = 0; i < o.Length; i++)
                {
                    int r = grey[0] != null ? 255 - grey[0][i] : 128, gg = grey[1] != null ? grey[1][i] : 128, b = grey[2] != null ? grey[2][i] : 0;
                    o[i] = unchecked((int)0xFF000000) | (r << 16) | (gg << 8) | b;
                }
                MatPx = o; MatW = w; MatH = h; MatHas = has;
                return true;
            }
            /// <summary>HOLES CUT WHERE THE ART IS BRIGHT (Josh, 2026-10-09, Room Review MINEHEAD/1: "cut this texture up so
            /// light can actually shine through it"): every texel whose ORIGINAL colour is at least minLum bright (0..255),
            /// within box (texels x0 y0 x1 y1; null = all), becomes index 0 -- a hole to the picture, the shadow views and
            /// the bounce bake alike. Always from the original indices, so it can be redone or put back. Returns how many.</summary>
            public int CutHoles(byte[] pal, int minLum, int[] box)
            {
                if (IdxOrig == null) IdxOrig = (byte[])Idx.Clone();
                var idx = (byte[])IdxOrig.Clone(); int n = 0;
                // (box: one x0 y0 x1 y1, or several one after another -- BAPTIST's three windows, 2026-10-14)
                int nb = box != null && box.Length >= 4 ? box.Length / 4 : 1;
                for (int bi = 0; bi < nb; bi++)
                {
                    int o = bi * 4;
                    int x0 = box != null ? Math.Max(0, box[o]) : 0, y0 = box != null ? Math.Max(0, box[o + 1]) : 0, x1 = box != null ? Math.Min(W - 1, box[o + 2]) : W - 1, y1 = box != null ? Math.Min(H - 1, box[o + 3]) : H - 1;
                    for (int y = y0; y <= y1; y++)
                        for (int x = x0; x <= x1; x++)
                        {
                            int i = y * W + x, k = idx[i] * 3; if (idx[i] == 0) continue;
                            if (0.30 * pal[k] + 0.59 * pal[k + 1] + 0.11 * pal[k + 2] >= minLum) { idx[i] = 0; n++; }
                        }
                }
                Idx = idx; return n;
            }
            /// <summary>The holes CutHoles made, undone (the room no longer asks for them).</summary>
            public bool RestoreHoles() { if (IdxOrig == null) return false; Idx = IdxOrig; IdxOrig = null; return true; }

            public void SetRgb(int[] px, int w, int h)
            {
                if (px == null || px.Length != w * h) throw new ArgumentException("rgb size does not match its data");
                var list = new List<RgbLevel>();
                var cur = new RgbLevel { Px = px, W = w, H = h }; list.Add(cur);
                while (cur.W > 1 || cur.H > 1)
                {
                    int nw = Math.Max(1, cur.W / 2), nh = Math.Max(1, cur.H / 2);
                    var np = new int[nw * nh];
                    for (int y = 0; y < nh; y++)
                    {
                        int y0 = Math.Min(cur.H - 1, y * 2), y1 = Math.Min(cur.H - 1, y * 2 + 1);
                        for (int x = 0; x < nw; x++)
                        {
                            int x0 = Math.Min(cur.W - 1, x * 2), x1 = Math.Min(cur.W - 1, x * 2 + 1);
                            int a = cur.Px[y0 * cur.W + x0], b = cur.Px[y0 * cur.W + x1], c = cur.Px[y1 * cur.W + x0], d = cur.Px[y1 * cur.W + x1];
                            int r = (((a >> 16) & 255) + ((b >> 16) & 255) + ((c >> 16) & 255) + ((d >> 16) & 255) + 2) >> 2;
                            int g = (((a >> 8) & 255) + ((b >> 8) & 255) + ((c >> 8) & 255) + ((d >> 8) & 255) + 2) >> 2;
                            int bl = ((a & 255) + (b & 255) + (c & 255) + (d & 255) + 2) >> 2;
                            np[y * nw + x] = (r << 16) | (g << 8) | bl;
                        }
                    }
                    cur = new RgbLevel { Px = np, W = nw, H = nh }; list.Add(cur);
                }
                Rgb = list.ToArray();
            }

            /// <summary>No painted original to hand: the palette's own colours for Idx.</summary>
            public void EnsureRgb(byte[] pal)
            {
                if (Rgb != null) return;
                var px = new int[W * H];
                for (int i = 0; i < px.Length; i++) { int k = Idx[i] * 3; px[i] = (pal[k] << 16) | (pal[k + 1] << 8) | pal[k + 2]; }
                SetRgb(px, W, H);
            }

            /// <summary>The painted original, from its PNG. Where the PNG is transparent the
            /// palette colour is kept (those texels are holes and are never drawn anyway).</summary>
            public bool LoadRgb(string png, byte[] pal)
            {
                using (var src = (System.Drawing.Bitmap)System.Drawing.Image.FromFile(png))
                using (var bm = new System.Drawing.Bitmap(src.Width, src.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
                {
                    using (var g = System.Drawing.Graphics.FromImage(bm)) { g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy; g.DrawImage(src, 0, 0, src.Width, src.Height); }
                    int w = bm.Width, h = bm.Height;
                    var bd = bm.LockBits(new System.Drawing.Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                    var px = new int[w * h];
                    try { for (int y = 0; y < h; y++) System.Runtime.InteropServices.Marshal.Copy(new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), px, y * w, w); }
                    finally { bm.UnlockBits(bd); }
                    bool same = (w == W && h == H);
                    for (int i = 0; i < px.Length; i++)
                    {
                        int a = (px[i] >> 24) & 255;
                        if (a < 128 && same) { int k = Idx[i] * 3; px[i] = (pal[k] << 16) | (pal[k + 1] << 8) | pal[k + 2]; }
                        else px[i] &= 0xFFFFFF;
                    }
                    SetRgb(px, w, h); RgbFromFile = true;
                    return same;
                }
            }

            // SMALLER COPIES OF ITSELF, each half the size of the one before, down to 1x1:
            // Mips[0] is this texture. Drawn far away, a 256-wide texture is sampled at one
            // texel in every eight or sixteen, and WHICH one changes as the camera moves --
            // that is the shimmer on distant floors. Reading from a copy that has already
            // been averaged down to about one texel per screen pixel removes it.
            //
            // Averaging is done in colour and brought back to the palette through `lut`
            // (Raster.BuildRgbLut). Index 0 is "nothing here": a block that is mostly holes
            // stays a hole, otherwise the holes are left out of the average.
            // A LARGER COPY OF ITSELF, for the texture-resolution experiment. There is no more
            // detail to find in a 256-pixel texture than its 256 pixels, so this cannot add
            // any: what it changes is HOW the picture is stretched. The filter blends
            // neighbouring texels in straight lines; this resamples with a bicubic curve
            // (Catmull-Rom, which keeps edges tighter than a plain blur), then sharpens, and
            // only then goes back to the palette -- through `lut6`, 6 bits a channel, because
            // the mip table's 5 bits band visibly on a smooth enlargement. Holes (index 0)
            // are carried across by nearest texel so cut-out edges stay cut out. The texture
            // repeats, so sampling wraps. One copy per factor is kept.
            public Tex Hi; public int HiFactor;
            public Tex Upscaled(int factor, byte[] pal, byte[] lut6, float sharpen)
            {
                if (factor <= 1) return this;
                if (Hi != null && HiFactor == factor) return Hi;
                int nw = W * factor, nh = H * factor, sw = W, sh = H;
                if ((long)nw * nh > 4096L * 4096L) return this;
                var rgb = new float[nw * nh * 3];
                byte[] src = Idx;
                Parallel.For(0, nh, y =>
                {
                    float fy = (y + 0.5f) / factor - 0.5f; int y0 = (int)Math.Floor(fy); float ty = fy - y0;
                    float[] wy = Cubic(ty);
                    for (int x = 0; x < nw; x++)
                    {
                        float fx = (x + 0.5f) / factor - 0.5f; int x0 = (int)Math.Floor(fx); float tx = fx - x0;
                        float[] wx = Cubic(tx);
                        float r = 0, g = 0, b = 0, wsum = 0;
                        for (int j = 0; j < 4; j++)
                        {
                            int sy = ((y0 - 1 + j) % sh + sh) % sh;
                            for (int i = 0; i < 4; i++)
                            {
                                int sx = ((x0 - 1 + i) % sw + sw) % sw;
                                byte p = src[sy * sw + sx];
                                if (p == 0) continue;                 // a hole lends no colour
                                float wgt = wx[i] * wy[j];
                                r += pal[p * 3] * wgt; g += pal[p * 3 + 1] * wgt; b += pal[p * 3 + 2] * wgt; wsum += wgt;
                            }
                        }
                        int o = (y * nw + x) * 3;
                        if (wsum > 0.05f) { rgb[o] = r / wsum; rgb[o + 1] = g / wsum; rgb[o + 2] = b / wsum; }
                    }
                });
                var d = new byte[nw * nh];
                Parallel.For(0, nh, y =>
                {
                    int ym = (y - 1 + nh) % nh, yp = (y + 1) % nh;
                    for (int x = 0; x < nw; x++)
                    {
                        // nearest source texel decides whether this is a hole
                        if (src[(y / factor) * sw + (x / factor)] == 0) { d[y * nw + x] = 0; continue; }
                        int xm = (x - 1 + nw) % nw, xp = (x + 1) % nw, o = (y * nw + x) * 3;
                        int q = 0;
                        for (int c = 0; c < 3; c++)
                        {
                            // unsharp: push each value away from the average of its four neighbours
                            float blur = (rgb[(ym * nw + x) * 3 + c] + rgb[(yp * nw + x) * 3 + c] + rgb[(y * nw + xm) * 3 + c] + rgb[(y * nw + xp) * 3 + c]) * 0.25f;
                            float v = rgb[o + c] + (rgb[o + c] - blur) * sharpen;
                            int iv = v < 0 ? 0 : (v > 255 ? 255 : (int)(v + 0.5f));
                            q = (q << 6) | (iv >> 2);
                        }
                        d[y * nw + x] = lut6[q];
                    }
                });
                Hi = new Tex(d, nw, nh); HiFactor = factor;
                return Hi;
            }
            static float[] Cubic(float t)
            {
                // Catmull-Rom weights for the four samples at -1, 0, 1, 2
                float t2 = t * t, t3 = t2 * t;
                return new float[] { -0.5f * t3 + t2 - 0.5f * t, 1.5f * t3 - 2.5f * t2 + 1f, -1.5f * t3 + 2f * t2 + 0.5f * t, 0.5f * t3 - 0.5f * t2 };
            }

            public Tex[] Mips;
            public void BuildMips(byte[] pal, byte[] lut)
            {
                if (Mips != null) return;
                var list = new List<Tex>(); list.Add(this);
                Tex src = this;
                while (src.W > 1 || src.H > 1)
                {
                    int nw = Math.Max(1, src.W / 2), nh = Math.Max(1, src.H / 2);
                    var d = new byte[nw * nh];
                    for (int y = 0; y < nh; y++)
                        for (int x = 0; x < nw; x++)
                        {
                            int r = 0, g = 0, b = 0, n = 0, holes = 0;
                            for (int k = 0; k < 4; k++)
                            {
                                int sx = Math.Min(src.W - 1, x * 2 + (k & 1)), sy = Math.Min(src.H - 1, y * 2 + (k >> 1));
                                byte i = src.Idx[sy * src.W + sx];
                                if (i == 0) { holes++; continue; }
                                r += pal[i * 3]; g += pal[i * 3 + 1]; b += pal[i * 3 + 2]; n++;
                            }
                            d[y * nw + x] = (holes >= 2 || n == 0) ? (byte)0 : lut[((r / n) >> 3) << 10 | ((g / n) >> 3) << 5 | ((b / n) >> 3)];
                        }
                    src = new Tex(d, nw, nh); list.Add(src);
                }
                Mips = list.ToArray();
            }
        }

        struct V { public float x, y, z; }      // view space

        // A view-space vertex carrying its texture coordinate, so clipping can carry UVs
        // across the cut rather than inventing them.
        struct VT { public float x, y, z, u, v, f; }      // f: how squarely this corner faces the lamp (smooth shading)

        // SUTHERLAND-HODGMAN AGAINST THE NEAR PLANE. Clipping a triangle against one
        // plane yields at most four vertices, so `dst` need only hold four.
        //
        // This REPLACES a reject. Dropping any triangle with a vertex behind the near
        // plane is cheap and almost right: it is invisible in open space and very
        // visible the moment the camera is close to a wall, where the wall you are
        // standing against is exactly the triangle that spans the plane -- so the world
        // opens a hole precisely where you are looking hardest.
        static int ClipNear(VT[] src, int n, VT[] dst, float nz)
        {
            int outN = 0;
            for (int i = 0; i < n; i++)
            {
                VT a = src[i], b = src[(i + 1) % n];
                bool ain = a.z >= nz, bin = b.z >= nz;
                if (ain) dst[outN++] = a;
                if (ain != bin)
                {
                    // the crossing point, with u and v carried along it
                    float t = (nz - a.z) / (b.z - a.z);
                    VT c;
                    c.x = a.x + (b.x - a.x) * t;
                    c.y = a.y + (b.y - a.y) * t;
                    c.z = nz;
                    c.u = a.u + (b.u - a.u) * t;
                    c.v = a.v + (b.v - a.v) * t;
                    c.f = a.f + (b.f - a.f) * t;
                    dst[outN++] = c;
                }
            }
            return outN;
        }

        V ToView(float wx, float wy, float wz)
        {
            V o;
            o.x = wx*_view[0] + wy*_view[4] + wz*_view[8]  + _view[12];
            o.y = wx*_view[1] + wy*_view[5] + wz*_view[9]  + _view[13];
            o.z = wx*_view[2] + wy*_view[6] + wz*_view[10] + _view[14];
            return o;
        }

        // Project to pixels. Returns false behind the near plane.
        bool Project(V v, out float sx, out float sy, out float invZ)
        {
            sx = sy = invZ = 0;
            if (v.z < NearZ) return false;
            float iz = 1f / v.z;
            sx = (v.x * _focal * VHf / W * iz + 1f) * 0.5f * W;
            sy = (1f - v.y * _focal * iz) * 0.5f * VHf;   // screen y grows downward
            invZ = iz;
            return true;
        }

        // Draw a world-space triangle soup. `ramp` is palette indices DARK->BRIGHT and
        // the face's Lambert term against `light` picks one. Flat shading on purpose at
        // this stage: it makes the geometry legible without a single texture decoded,
        // so the camera, the projection and the winding can all be judged from the
        // picture before UVs are in the way.
        public void DrawTriangles(float[] vx, int[] idx, byte[] ramp,
                                  float lx, float ly, float lz, bool cullBackfaces)
        {
            if (vx == null || idx == null || ramp == null || ramp.Length == 0) throw new ArgumentException("missing input");
            if (idx.Length % 3 != 0) throw new ArgumentException("index count is not a multiple of 3");
            float ll = (float)Math.Sqrt(lx*lx+ly*ly+lz*lz);
            if (ll < 1e-6f) { lx = 0; ly = 1; lz = 0; ll = 1; }
            lx/=ll; ly/=ll; lz/=ll;

            int nTri = idx.Length / 3;
            TrisIn += nTri;

            int bands = Math.Max(1, Math.Min(Threads, H / 8));
            int rowsPer = (H + bands - 1) / bands;

            // BAND BY SCANLINE, one thread per band. Each thread writes only its own
            // rows, so there is no sharing and no locking anywhere in the inner loop --
            // the reason this can use all 16 cores at all. Triangle setup is repeated
            // per band, which is cheap next to filling pixels and far cheaper than
            // synchronising a shared framebuffer.
            // PER-TRIANGLE, NOT PER-BAND. Summing a per-band "drawn" counter reported
            // 700 triangles drawn out of 440, because a triangle spanning three bands
            // was counted three times. A flag per triangle counts each one once; the
            // write is a benign race since every thread writes the same 1.
            byte[] hit = new byte[nTri];
            long[] px = new long[bands];
            long[] culled = new long[bands];

            Parallel.For(0, bands, new ParallelOptions { MaxDegreeOfParallelism = Threads }, band =>
            {
                int y0 = band * rowsPer, y1 = Math.Min(H, y0 + rowsPer);
                if (y0 >= y1) return;
                for (int t = 0; t < nTri; t++)
                {
                    int ia = idx[t*3] * 3, ib = idx[t*3+1] * 3, ic = idx[t*3+2] * 3;
                    float ax = vx[ia], ay = vx[ia+1], az = vx[ia+2];
                    float bx = vx[ib], by = vx[ib+1], bz = vx[ib+2];
                    float cx = vx[ic], cy = vx[ic+1], cz = vx[ic+2];

                    // face normal in WORLD space, for shading
                    float e1x=bx-ax, e1y=by-ay, e1z=bz-az;
                    float e2x=cx-ax, e2y=cy-ay, e2z=cz-az;
                    float nx = e1y*e2z - e1z*e2y, ny = e1z*e2x - e1x*e2z, nz = e1x*e2y - e1y*e2x;
                    float nl = (float)Math.Sqrt(nx*nx+ny*ny+nz*nz);
                    if (nl < 1e-12f) { if (band == 0) culled[band]++; continue; }   // degenerate
                    nx/=nl; ny/=nl; nz/=nl;
                    float lam = nx*lx + ny*ly + nz*lz;
                    if (lam < 0) lam = -lam;                 // two-sided: unlit backs read as holes
                    int shade = (int)(lam * (ramp.Length - 1) + 0.5f);
                    if (shade < 0) shade = 0; else if (shade >= ramp.Length) shade = ramp.Length - 1;
                    byte ink = ramp[shade];

                    V va = ToView(ax,ay,az), vb = ToView(bx,by,bz), vc = ToView(cx,cy,cz);
                    // NEAR-PLANE REJECT, not clip, at this stage. A partially visible
                    // triangle is dropped rather than split. That is visible as geometry
                    // vanishing at the very edge of the view when you walk into a wall,
                    // and it is called out here rather than hidden because proper
                    // clipping is a known, separate piece of work -- pretending a reject
                    // is a clip is how a renderer ends up with mysterious holes.
                    float s0x,s0y,i0, s1x,s1y,i1, s2x,s2y,i2;
                    if (!Project(va, out s0x, out s0y, out i0)) continue;
                    if (!Project(vb, out s1x, out s1y, out i1)) continue;
                    if (!Project(vc, out s2x, out s2y, out i2)) continue;

                    float area = (s1x-s0x)*(s2y-s0y) - (s2x-s0x)*(s1y-s0y);
                    if (cullBackfaces && area <= 0) { if (band == 0) culled[band]++; continue; }
                    if (area == 0) continue;
                    float invArea = 1f / area;

                    int minX = (int)Math.Floor(Math.Min(s0x, Math.Min(s1x, s2x)));
                    int maxX = (int)Math.Ceiling(Math.Max(s0x, Math.Max(s1x, s2x)));
                    int minY = (int)Math.Floor(Math.Min(s0y, Math.Min(s1y, s2y)));
                    int maxY = (int)Math.Ceiling(Math.Max(s0y, Math.Max(s1y, s2y)));
                    if (minX < 0) minX = 0; if (maxX > W-1) maxX = W-1;
                    if (minY < y0) minY = y0; if (maxY > y1-1) maxY = y1-1;
                    if (minX > maxX || minY > maxY) continue;

                    bool any = false;
                    for (int y = minY; y <= maxY; y++)
                    {
                        int row = y * W;
                        float fy = y + 0.5f;
                        for (int x = minX; x <= maxX; x++)
                        {
                            float fx = x + 0.5f;
                            float w0 = ((s1x-fx)*(s2y-fy) - (s2x-fx)*(s1y-fy)) * invArea;
                            if (w0 < 0) continue;
                            float w1 = ((s2x-fx)*(s0y-fy) - (s0x-fx)*(s2y-fy)) * invArea;
                            if (w1 < 0) continue;
                            float w2 = 1f - w0 - w1;
                            if (w2 < 0) continue;
                            // INTERPOLATE 1/z, not z. Depth is linear in screen space
                            // only in its reciprocal; interpolating z itself makes
                            // surfaces bow and sort wrongly against each other.
                            float iz = w0*i0 + w1*i1 + w2*i2;
                            int o = row + x;
                            if (iz <= Depth[o]) continue;
                            Depth[o] = iz;
                            Color[o] = ink;
                            any = true;
                            px[band]++;
                        }
                    }
                    if (any) hit[t] = 1;
                }
            });

            for (int i = 0; i < bands; i++) { PixelsWritten += px[i]; TrisCulled += culled[i]; }
            long drawnTris = 0;
            for (int i = 0; i < nTri; i++) if (hit[i] != 0) drawnTris++;
            TrisDrawn += drawnTris;
        }

        // Rasterise ONE view-space triangle that is already wholly in front of the near
        // plane, into the scanline band [y0,y1). Returns whether it wrote anything.
        bool RasterTri(VT a, VT b, VT c, Tex tex, bool cull, bool flipV,
                       int y0, int y1, ref long pxCount, ref long culledCount, bool countCull,
                       float faceLight)
        {
            float i0 = 1f / a.z, i1 = 1f / b.z, i2 = 1f / c.z;
            float s0x = (a.x * _focal * VHf / W * i0 + 1f) * 0.5f * W;
            float s0y = (1f - a.y * _focal * i0) * 0.5f * VHf;
            float s1x = (b.x * _focal * VHf / W * i1 + 1f) * 0.5f * W;
            float s1y = (1f - b.y * _focal * i1) * 0.5f * VHf;
            float s2x = (c.x * _focal * VHf / W * i2 + 1f) * 0.5f * W;
            float s2y = (1f - c.y * _focal * i2) * 0.5f * VHf;

            float area = (s1x-s0x)*(s2y-s0y) - (s2x-s0x)*(s1y-s0y);
            if (cull && area <= 0) { if (countCull) culledCount++; return false; }
            if (area == 0) return false;
            float invArea = 1f / area;

            // PERSPECTIVE CORRECTION. Interpolate u/z and v/z alongside 1/z and divide
            // per pixel. Interpolating u,v directly is the classic texture swim --
            // correct at the vertices, visibly wrong across a floor, and worst exactly
            // where it is most looked at.
            float u0 = a.u*i0, w0q = a.v*i0;
            float u1 = b.u*i1, w1q = b.v*i1;
            float u2 = c.u*i2, w2q = c.v*i2;

            int minX = (int)Math.Floor(Math.Min(s0x, Math.Min(s1x, s2x)));
            int maxX = (int)Math.Ceiling(Math.Max(s0x, Math.Max(s1x, s2x)));
            int minY = (int)Math.Floor(Math.Min(s0y, Math.Min(s1y, s2y)));
            int maxY = (int)Math.Ceiling(Math.Max(s0y, Math.Max(s1y, s2y)));
            if (minX < 0) minX = 0; if (maxX > W-1) maxX = W-1;
            if (minY < y0) minY = y0; if (maxY > y1-1) maxY = y1-1;
            if (minX > maxX || minY > maxY) return false;

            bool any = false;
            for (int y = minY; y <= maxY; y++)
            {
                int row = y * W;
                float fy = y + 0.5f;
                for (int x = minX; x <= maxX; x++)
                {
                    float fx = x + 0.5f;
                    float l0 = ((s1x-fx)*(s2y-fy) - (s2x-fx)*(s1y-fy)) * invArea;
                    if (l0 < 0) continue;
                    float l1 = ((s2x-fx)*(s0y-fy) - (s0x-fx)*(s2y-fy)) * invArea;
                    if (l1 < 0) continue;
                    float l2 = 1f - l0 - l1;
                    if (l2 < 0) continue;
                    float iz = l0*i0 + l1*i1 + l2*i2;
                    int o = row + x;
                    if (iz <= Depth[o]) continue;

                    // ONE RECIPROCAL, used twice for UV and once for depth. The divide
                    // was already being paid for the texture coordinates; the distance
                    // this lighting needs is the same number, so the fog is free.
                    float w = 1f / iz;
                    float uu = (l0*u0 + l1*u1 + l2*u2) * w;
                    float vv = (l0*w0q + l1*w1q + l2*w2q) * w;
                    if (flipV) vv = 1f - vv;
                    // WRAP, do not clamp: the .XAF UVs run outside 0..1 wherever a
                    // surface tiles, and clamping smears the edge pixel across the whole
                    // wall instead of repeating the pattern.
                    uu -= (float)Math.Floor(uu);
                    vv -= (float)Math.Floor(vv);
                    int tx = (int)(uu * tex.W); if (tx >= tex.W) tx = tex.W-1; if (tx < 0) tx = 0;
                    int ty = (int)(vv * tex.H); if (ty >= tex.H) ty = tex.H-1; if (ty < 0) ty = 0;
                    byte ink = tex.Idx[ty * tex.W + tx];
                    if (ink == 0) continue;            // transparent texel

                    if (Shade != null)
                    {
                        // w IS the view-space depth. Linear falloff between FogNear and
                        // FogFar, floored at Ambient so near surfaces are not blown out
                        // and distant ones go properly black -- which is what the engine
                        // does and what the unlit render conspicuously did not.
                        float att = (FogFar - w) * (1f / (FogFar - FogNear));
                        if (att > 1f) att = 1f; else if (att < 0f) att = 0f;
                        if (_fogCurve != 1f) att = (float)Math.Pow(att, _fogCurve);
                        float lit = faceLight * att;
                        if (lit < 0f) lit = 0f; else if (lit > 1f) lit = 1f;
                        int lvl = (int)(lit * (ShadeLevels - 1) + 0.5f);
                        if (lvl < 0) lvl = 0; else if (lvl >= ShadeLevels) lvl = ShadeLevels - 1;
                        ink = Shade[lvl * 256 + ink];
                        if (ink == 0) continue;        // darkened into the sentinel
                    }

                    Depth[o] = iz;
                    Color[o] = ink;
                    any = true;
                    pxCount++;
                }
            }
            return any;
        }

        // Textured draw. `uv` is 2 floats per VERTEX (parallel to vx, which is what the
        // .XAF format gives: texture_coordinates runs parallel to vertices, so the UV
        // index IS the vertex index). `triTex` is one texture index per triangle.
        public void DrawTextured(float[] vx, float[] uv, int[] idx, int[] triTex, Tex[] texes,
                                 bool cullBackfaces, bool flipV)
        {
            if (vx == null || uv == null || idx == null || triTex == null || texes == null) throw new ArgumentException("missing input");
            if (idx.Length % 3 != 0) throw new ArgumentException("index count is not a multiple of 3");
            if (triTex.Length != idx.Length / 3) throw new ArgumentException("one texture index per triangle, please");

            int nTri = idx.Length / 3;
            TrisIn += nTri;
            // normalised once, not per triangle
            _lightLen = (float)Math.Sqrt(LightX*LightX + LightY*LightY + LightZ*LightZ);
            _fogCurve = (FogCurve > 0.05f && FogCurve < 8f) ? FogCurve : 1f;
            if (_lightLen < 1e-6f) { LightX = 0; LightY = 1; LightZ = 0; _lightLen = 1f; }
            int bands = Math.Max(1, Math.Min(Threads, H / 8));
            int rowsPer = (H + bands - 1) / bands;
            byte[] hit = new byte[nTri];
            long[] px = new long[bands];
            long[] culled = new long[bands];

            Parallel.For(0, bands, new ParallelOptions { MaxDegreeOfParallelism = Threads }, band =>
            {
                int y0 = band * rowsPer, y1 = Math.Min(H, y0 + rowsPer);
                if (y0 >= y1) return;
                // Scratch allocated ONCE PER BAND, not per triangle: a 4-element array
                // per triangle would be hundreds of thousands of allocations a frame and
                // the GC would dominate the render.
                VT[] inP = new VT[4], outP = new VT[8];
                for (int t = 0; t < nTri; t++)
                {
                    int ti = triTex[t];
                    if (ti < 0 || ti >= texes.Length || texes[ti] == null) continue;
                    Tex tex = texes[ti];

                    int a = idx[t*3], b = idx[t*3+1], c = idx[t*3+2];

                    // THE SURFACE TERM, in WORLD space and computed once per triangle.
                    // Kept small by default (NormalLight ~0.35): these textures already
                    // have their lighting painted in, so a strong normal term lights
                    // them twice and the room starts looking like untextured geometry
                    // with a flashlight on it.
                    float faceLight = 1f;
                    if (Shade != null)
                    {
                        float ax = vx[a*3], ay = vx[a*3+1], az = vx[a*3+2];
                        float e1x = vx[b*3]-ax,   e1y = vx[b*3+1]-ay, e1z = vx[b*3+2]-az;
                        float e2x = vx[c*3]-ax,   e2y = vx[c*3+1]-ay, e2z = vx[c*3+2]-az;
                        float nx = e1y*e2z - e1z*e2y, ny = e1z*e2x - e1x*e2z, nz = e1x*e2y - e1y*e2x;
                        float nl = (float)Math.Sqrt(nx*nx + ny*ny + nz*nz);
                        float lam = 1f;
                        if (nl > 1e-12f)
                        {
                            lam = (nx*LightX + ny*LightY + nz*LightZ) / (nl * _lightLen);
                            if (lam < 0) lam = -lam;    // two-sided: a dark back face reads as a hole
                        }
                        faceLight = Ambient + (1f - Ambient) * (1f - NormalLight + NormalLight * lam);
                        if (faceLight > 1f) faceLight = 1f;
                    }

                    V pa = ToView(vx[a*3], vx[a*3+1], vx[a*3+2]);
                    V pb = ToView(vx[b*3], vx[b*3+1], vx[b*3+2]);
                    V pc = ToView(vx[c*3], vx[c*3+1], vx[c*3+2]);
                    inP[0].x=pa.x; inP[0].y=pa.y; inP[0].z=pa.z; inP[0].u=uv[a*2]; inP[0].v=uv[a*2+1];
                    inP[1].x=pb.x; inP[1].y=pb.y; inP[1].z=pb.z; inP[1].u=uv[b*2]; inP[1].v=uv[b*2+1];
                    inP[2].x=pc.x; inP[2].y=pc.y; inP[2].z=pc.z; inP[2].u=uv[c*2]; inP[2].v=uv[c*2+1];

                    int nOut = ClipNear(inP, 3, outP, NearZ);
                    if (nOut < 3) continue;

                    bool any = false;
                    // Fan the clipped polygon. Clipping cannot reverse winding, so the
                    // backface test on each fan triangle agrees with the original.
                    for (int k = 1; k <= nOut - 2; k++)
                    {
                        if (RasterTri(outP[0], outP[k], outP[k+1], tex, cullBackfaces, flipV,
                                      y0, y1, ref px[band], ref culled[band], band == 0, faceLight))
                            any = true;
                    }
                    if (any) hit[t] = 1;
                }
            });

            for (int i = 0; i < bands; i++) { PixelsWritten += px[i]; TrisCulled += culled[i]; }
            long drawnTris = 0;
            for (int i = 0; i < nTri; i++) if (hit[i] != 0) drawnTris++;
            TrisDrawn += drawnTris;
        }

        // =====================================================================
        //  THE FAST PATH. Same picture as DrawTextured, measured pixel for pixel
        //  against it (tools\Test-RasterFast.ps1) -- DrawTextured stays as the
        //  reference, so any future change here can be checked the same way.
        // =====================================================================
        //
        // WHAT DrawTextured WAS PAYING FOR THAT THE PICTURE DOES NOT NEED:
        //
        //  * SETUP, 16 TIMES OVER. Every band re-transformed, re-clipped and
        //    re-projected every triangle in the room, then threw most of them away on
        //    the bounding-box test. Here each triangle is prepared once, and a band
        //    only looks at the ones whose rows it owns.
        //  * THE WHOLE BOUNDING BOX. A triangle covers at most half of its box, and a
        //    long thin one almost none of it; every pixel of the box still paid three
        //    edge evaluations to be told so. Here each row's x-range is solved first
        //    and only that span is walked. The span is CONSERVATIVE (padded, computed
        //    in double) and the per-pixel test inside it is the reference's own
        //    arithmetic, operation for operation, which is why the output matches.
        //  * A SHARED COUNTER PER PIXEL. `px[band]++` wrote a long that sits on the
        //    same cache line as its neighbours' counters, from 16 threads, once per
        //    pixel drawn. Counted in a local now and stored once.
        //  * Math.Floor (a double call) twice per pixel for the texture wrap.
        //  * OVERDRAW. Nearest-first order lets the depth test reject a hidden pixel
        //    before its divide and texture fetch. Ties between coplanar faces can
        //    resolve differently from the reference, so it can be switched off.
        //  * A SERIAL CLEAR written as a byte-and-float loop over 1.48 M pixels.
        public bool SortFrontToBack = true;

        struct PTri
        {
            public float s0x, s0y, s1x, s1y, s2x, s2y;
            public float i0, i1, i2, u0, v0, u1, v1, u2, v2;
            public float invArea, faceLight, lamp, lod, f0, f1, f2, nvx, nvy, nvz;   // nv: unit face normal in view space
            public int minX, maxX, minY, maxY, tex, src;
        }
        PTri[] _pt = new PTri[0];
        float[] _ptKey = new float[0];
        VT[] _clipIn = new VT[4], _clipOut = new VT[8];

        // ---- TRUE COLOUR ---------------------------------------------------------------------
        // With Rgb set the fast path also fills Color32 (0x00RRGGBB): the texture's painted
        // colours read with bilinear filtering between two mip levels, and the SAME lighting
        // numbers applied as a real multiply instead of a row of the light table -- so no
        // dither, no banding, and no snapping to the nearest of 200 colours. Color (8-bit)
        // is still written, unlit, so everything that reads it keeps working. Everything
        // that decides WHICH pixels a triangle owns is untouched.
        public bool Rgb = false;
        public int[] Color32;
        // SMOOTH SHADING. The lamp's brightness on a face depends on how squarely the face looks
        // back at it -- one number per triangle, so a round creature made of flat triangles is
        // lit facet by facet. With CornerGroup (from MeshSmooth: which smoothing fan each
        // triangle corner belongs to) the number is worked out per CORNER instead, from the
        // fan's shared normal as posed this frame, and blended across the triangle. A fan never
        // crosses a crease, so a box still has flat, separately lit sides.
        public bool SmoothShade = false;
        public int[] CornerGroup; public int GroupCount;

        // ---- PLACED LIGHTS (true colour only) ------------------------------------------------
        // Up to MaxLights point lights in WORLD space, 8 floats each: x y z, r g b (strength,
        // 1 = as bright as the texture was painted, at the light), range (where it is down to
        // half), spare. No shadows: each pixel is lit by how far it is from the light and how
        // squarely its face turns toward it. Set every frame (flicker lives in the strength).
        public const int MaxLights = 8;
        public float[] Lights = new float[MaxLights * 8]; public int LightCount;
        // SHADOWS FROM A PLACED LIGHT, the same way the flashlight does it: the scene's depth is
        // drawn once from the light (a small Raster looking the way the light faces, wide-angled),
        // and a pixel is lit only if the light can see it. A torch on a wall lights the half-room
        // in front of the wall, so one view the way it faces covers what matters; anything outside
        // that view is simply lit. `axes` = the light view's right, up and forward in WORLD space
        // (LookAt leaves them in LastBasis). The map holds 1/z like Depth does.
        readonly float[][] _lsMap = new float[MaxLights][]; readonly int[] _lsSize = new int[MaxLights]; readonly float[] _lsFocal = new float[MaxLights];
        readonly float[] _lsAxes = new float[MaxLights * 9];
        public float LightShadowBias = 0.03f;
        public void SetLightShadow(int i, float[] depthFromLight, int size, float focalPx, float[] axesWorld)
        {
            if (i < 0 || i >= MaxLights) return;
            if (depthFromLight != null && depthFromLight.Length != size * size) throw new ArgumentException("light shadow map size does not match its data");
            _lsMap[i] = depthFromLight; _lsSize[i] = size; _lsFocal[i] = focalPx;
            if (axesWorld != null && axesWorld.Length >= 9) Array.Copy(axesWorld, 0, _lsAxes, i * 9, 9);
        }
        public void ClearLightShadows() { for (int i = 0; i < MaxLights; i++) _lsMap[i] = null; }
        /// <summary>The world-space right, up and forward of the last LookAt, 9 floats.</summary>
        public float[] LastBasis = new float[9];
        // ---- FOG (true colour only) ---------------------------------------------------------
        // Everything fades toward FogColor32 with depth: nothing at FogNear, FogMax of the way
        // at FogFar and beyond. Applied after lighting, so a lamp does not burn through it.
        public bool Fog32; public int FogColor32 = 0x120C08; public float Fog32Near = 150f, Fog32Far = 900f, Fog32Max = 0.9f;
        /// <summary>The lamp's own strength at a screen position and depth (cone x falloff), for
        /// things drawn after the scene that should sit in the beam -- dust, for one.</summary>
        public float LampAt(float fx, float fy, float z)
        {
            if (!Lamp || LightTab == null) return 0f;
            BuildLampTables();
            float fpx = _focal * VHf * 0.5f, dxp = fx - (W * 0.5f + LampCx), dyp = fy - (VHf * 0.5f + LampCy);
            int ci = (int)((dxp * dxp + dyp * dyp) * (CONE_N - 1) / (CONE_MAX_TAN2 * fpx * fpx)); if (ci > CONE_N - 1) ci = CONE_N - 1; if (ci < 0) ci = 0;
            int wi = (int)(z * (1f / DIST_STEP)); if (wi > DIST_N - 1) wi = DIST_N - 1; if (wi < 0) wi = 0;
            return _coneTab[ci] * _distTab[wi] * LampPower;
        }
        public float FocalPx { get { return _focal * VHf * 0.5f; } }
        /// <summary>World point to view space (x right, y up, z forward).</summary>
        public float[] ViewPoint(float wx, float wy, float wz) { V o = ToView(wx, wy, wz); return new float[] { o.x, o.y, o.z }; }
        float[] _gsum = new float[0];
        int[] _under32;                     // what was under a mask (the water's own colour), for blending a reflection
        public void EnableRgb() { if (Color32 == null) Color32 = new int[W * H]; Rgb = true; }
        public static void EnsureRgb(Tex[] texes, byte[] pal) { foreach (Tex t in texes) if (t != null) t.EnsureRgb(pal); }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static int SampleBi(Tex.RgbLevel lv, float uu, float vv)
        {
            int w = lv.W, h = lv.H; int[] px = lv.Px;
            float fx = uu * w - 0.5f, fy = vv * h - 0.5f;
            int x0 = (int)fx; if (fx < 0f) x0 = -1; int y0 = (int)fy; if (fy < 0f) y0 = -1;
            uint wx = (uint)((fx - x0) * 256f), wy = (uint)((fy - y0) * 256f); if (wx > 255) wx = 255; if (wy > 255) wy = 255;
            int x1 = x0 + 1; if (x0 < 0) x0 = w - 1; if (x1 >= w) x1 = 0;
            int y1 = y0 + 1; if (y0 < 0) y0 = h - 1; if (y1 >= h) y1 = 0;
            uint a = (uint)px[y0 * w + x0], b = (uint)px[y0 * w + x1], c = (uint)px[y1 * w + x0], d = (uint)px[y1 * w + x1];
            uint nx = 256 - wx, ny = 256 - wy;
            uint tRB = ((a & 0xFF00FF) * nx + (b & 0xFF00FF) * wx) >> 8 & 0xFF00FF, tG = ((a & 0x00FF00) * nx + (b & 0x00FF00) * wx) >> 8 & 0x00FF00;
            uint bRB = ((c & 0xFF00FF) * nx + (d & 0xFF00FF) * wx) >> 8 & 0xFF00FF, bG = ((c & 0x00FF00) * nx + (d & 0x00FF00) * wx) >> 8 & 0x00FF00;
            return (int)(((tRB * ny + bRB * wy) >> 8 & 0xFF00FF) | ((tG * ny + bG * wy) >> 8 & 0x00FF00));
        }
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static int Mix(int a, int b, uint wb)       // a towards b by wb/256
        {
            uint na = 256 - wb, ua = (uint)a, ub = (uint)b;
            return (int)((((ua & 0xFF00FF) * na + (ub & 0xFF00FF) * wb) >> 8 & 0xFF00FF) | (((ua & 0x00FF00) * na + (ub & 0x00FF00) * wb) >> 8 & 0x00FF00));
        }

        // ---- AFTER THE PICTURE IS DRAWN: smooth the edges, then sharpen ------------------------
        //
        // EDGES. A triangle either owns a pixel or it does not, so every slanted edge is a
        // staircase. Drawing several samples a pixel would cure it at several times the cost;
        // this instead looks at the finished picture (the FXAA idea): where brightness changes
        // sharply between neighbours, work out which way the edge runs from the four diagonal
        // neighbours and blend a few samples ALONG it. Flat areas and gentle texture are left
        // exactly as they were -- the contrast test skips them -- so it costs almost nothing
        // away from edges.
        //
        // SHARPEN. Bilinear filtering of a 256-pixel texture stretched over a wall is smooth
        // and reads as soft. Each pixel is pushed away from the average of its four neighbours
        // by `sharpen`, and then held between the darkest and brightest of them, so detail
        // gains contrast but no bright or dark fringe can appear -- including on the edges that
        // were just smoothed.
        //
        // Both read one buffer and write another; the result ends up back in Color32.
        int[] _post;
        public double PostMs;
        public void PostRgb(bool smoothEdges, float sharpen)
        {
            if (Color32 == null || (!smoothEdges && sharpen <= 0f)) return;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            if (_post == null) _post = new int[W * H];
            int[] res = PostCore(Color32, _post, W, H, smoothEdges, sharpen, Threads);
            // whichever buffer holds the result becomes the picture; the other is the scratch one
            if (res != Color32) { _post = Color32; Color32 = res; }
            PostMs = sw.Elapsed.TotalMilliseconds;
        }

        /// <summary>The work itself, on any pair of buffers, so it can run away from the frame
        /// loop (see PostJob). Returns whichever of the two holds the finished picture.</summary>
        public static int[] PostCore(int[] src, int[] dst, int w, int h, bool smoothEdges, float sharpen, int threads)
        {
            var po = new ParallelOptions { MaxDegreeOfParallelism = threads };
            if (smoothEdges)
            {
                // GREEN STANDS IN FOR BRIGHTNESS. A separate brightness pass over the whole
                // picture cost a third of the smoothing for nothing an edge test can see.
                int[] s0 = src, d0 = dst;
                Parallel.For(0, h, po, y =>
                {
                    int o = y * w;
                    if (y == 0 || y == h - 1) { Buffer.BlockCopy(s0, o * 4, d0, o * 4, w * 4); return; }
                    d0[o] = s0[o]; d0[o + w - 1] = s0[o + w - 1];
                    for (int x = 1; x < w - 1; x++)
                    {
                        int i = o + x;
                        int lM = (s0[i] >> 8) & 255, lNW = (s0[i - w - 1] >> 8) & 255, lNE = (s0[i - w + 1] >> 8) & 255, lSW = (s0[i + w - 1] >> 8) & 255, lSE = (s0[i + w + 1] >> 8) & 255;
                        int lMin = lM, lMax = lM;
                        if (lNW < lMin) lMin = lNW; if (lNW > lMax) lMax = lNW; if (lNE < lMin) lMin = lNE; if (lNE > lMax) lMax = lNE;
                        if (lSW < lMin) lMin = lSW; if (lSW > lMax) lMax = lSW; if (lSE < lMin) lMin = lSE; if (lSE > lMax) lMax = lSE;
                        int range = lMax - lMin;
                        if (range < 10 || range * 6 < lMax) { d0[i] = s0[i]; continue; }      // not an edge worth touching
                        float dx = -((lNW + lNE) - (lSW + lSE)), dy = (lNW + lSW) - (lNE + lSE);
                        float reduce = (lNW + lNE + lSW + lSE) * (0.25f / 8f); if (reduce < 2f) reduce = 2f;
                        float adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;
                        float rcp = 1f / ((adx < ady ? adx : ady) + reduce);
                        dx *= rcp; dy *= rcp;
                        if (dx > 6f) dx = 6f; else if (dx < -6f) dx = -6f; if (dy > 6f) dy = 6f; else if (dy < -6f) dy = -6f;
                        int a1 = SamplePx(s0, w, h, x + dx * (1f / 3f - 0.5f), y + dy * (1f / 3f - 0.5f));
                        int a2 = SamplePx(s0, w, h, x + dx * (2f / 3f - 0.5f), y + dy * (2f / 3f - 0.5f));
                        int rgbA = Mix(a1, a2, 128);
                        int b1 = SamplePx(s0, w, h, x - dx * 0.5f, y - dy * 0.5f), b2 = SamplePx(s0, w, h, x + dx * 0.5f, y + dy * 0.5f);
                        int rgbB = Mix(rgbA, Mix(b1, b2, 128), 128);
                        int lB = (rgbB >> 8) & 255;
                        d0[i] = (lB < lMin || lB > lMax) ? rgbA : rgbB;
                    }
                });
                var t = src; src = dst; dst = t;            // the smoothed picture is now `src`
            }
            if (sharpen > 0f)
            {
                int k = (int)(sharpen * 256f);
                int[] s1 = src, d1 = dst;
                Parallel.For(0, h, po, y =>
                {
                    int o = y * w;
                    if (y == 0 || y == h - 1) { Buffer.BlockCopy(s1, o * 4, d1, o * 4, w * 4); return; }
                    d1[o] = s1[o]; d1[o + w - 1] = s1[o + w - 1];
                    for (int x = 1; x < w - 1; x++)
                    {
                        int i = o + x; int c = s1[i], n = s1[i - w], s = s1[i + w], e = s1[i + 1], ww = s1[i - 1];
                        if (c == n && c == s && c == e && c == ww) { d1[i] = c; continue; }
                        // GREEN decides how far to push (it is most of what the eye reads as
                        // brightness); the same push goes to red and blue, each held to 0..255.
                        // One channel's worth of comparisons instead of three, and no colour
                        // fringes, since all three move together.
                        int cc = (c >> 8) & 255, cn = (n >> 8) & 255, cs = (s >> 8) & 255, ce = (e >> 8) & 255, cw = (ww >> 8) & 255;
                        int lo = cc, hi = cc;
                        if (cn < lo) lo = cn; if (cn > hi) hi = cn; if (cs < lo) lo = cs; if (cs > hi) hi = cs;
                        if (ce < lo) lo = ce; if (ce > hi) hi = ce; if (cw < lo) lo = cw; if (cw > hi) hi = cw;
                        int v = cc + (((cc * 4 - cn - cs - ce - cw) * k) >> 10);
                        if (v < lo) v = lo; else if (v > hi) v = hi;
                        int d = v - cc;
                        if (d == 0) { d1[i] = c; continue; }
                        int rr = ((c >> 16) & 255) + d, bb = (c & 255) + d;
                        if (rr < 0) rr = 0; else if (rr > 255) rr = 255; if (bb < 0) bb = 0; else if (bb > 255) bb = 255;
                        d1[i] = (rr << 16) | (v << 8) | bb;
                    }
                });
                var t = src; src = dst; dst = t;
            }
            return src;
        }

        // TWO LAMP VIEWS AT ONCE. They are independent pictures of the same geometry; drawn one
        // after the other the second simply waits for the first.
        public static void DrawDepthPair(Raster a, Raster b, float[] vx, float[] uv, int[] idx, int[] triTex, Tex[] texes, bool flipV)
        {
            if (b == null) { a.FastClear(0); a.DrawTexturedFast(vx, uv, idx, triTex, texes, false, flipV); return; }
            Parallel.Invoke(
                () => { a.FastClear(0); a.DrawTexturedFast(vx, uv, idx, triTex, texes, false, flipV); },
                () => { b.FastClear(0); b.DrawTexturedFast(vx, uv, idx, triTex, texes, false, flipV); });
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static int SamplePx(int[] px, int w, int h, float fx, float fy)
        {
            if (fx < 0f) fx = 0f; else if (fx > w - 1.001f) fx = w - 1.001f;
            if (fy < 0f) fy = 0f; else if (fy > h - 1.001f) fy = h - 1.001f;
            int x0 = (int)fx, y0 = (int)fy; uint wx = (uint)((fx - x0) * 256f), wy = (uint)((fy - y0) * 256f);
            int i = y0 * w + x0;
            uint a = (uint)px[i], b = (uint)px[i + 1], c = (uint)px[i + w], d = (uint)px[i + w + 1];
            uint nx = 256 - wx, ny = 256 - wy;
            uint tRB = ((a & 0xFF00FF) * nx + (b & 0xFF00FF) * wx) >> 8 & 0xFF00FF, tG = ((a & 0x00FF00) * nx + (b & 0x00FF00) * wx) >> 8 & 0x00FF00;
            uint bRB = ((c & 0xFF00FF) * nx + (d & 0xFF00FF) * wx) >> 8 & 0xFF00FF, bG = ((c & 0x00FF00) * nx + (d & 0x00FF00) * wx) >> 8 & 0x00FF00;
            return (int)(((tRB * ny + bRB * wy) >> 8 & 0xFF00FF) | ((tG * ny + bG * wy) >> 8 & 0x00FF00));
        }

        public void FastClear(byte bg)
        {
            // the three buffers at once: at 2134x1238 clearing them in turn was over a millisecond
            if (Rgb && Color32 != null && bg == 0 && Color32.Length >= 1000000)
            {
                Parallel.Invoke(() => Array.Clear(Color32, 0, Color32.Length), () => Array.Clear(Depth, 0, Depth.Length), () => Array.Clear(Color, 0, Color.Length));
                TrisIn = TrisCulled = TrisClipped = TrisDrawn = PixelsWritten = 0;
                return;
            }
            if (Rgb && Color32 != null) Array.Clear(Color32, 0, Color32.Length);
            Array.Clear(Depth, 0, Depth.Length);
            if (bg == 0) Array.Clear(Color, 0, Color.Length);
            else
            {
                for (int i = 0; i < W; i++) Color[i] = bg;
                for (int y = 1; y < H; y++) Buffer.BlockCopy(Color, 0, Color, y * W, W);
            }
            TrisIn = TrisCulled = TrisClipped = TrisDrawn = PixelsWritten = 0;
        }

        // Project one clipped view-space triangle into a PTri. The arithmetic is
        // RasterTri's, in RasterTri's order: do not "simplify" it, the match depends on it.
        bool Prepare(ref VT a, ref VT b, ref VT c, bool cull, ref PTri p, ref long culledCount)
        {
            float i0 = 1f / a.z, i1 = 1f / b.z, i2 = 1f / c.z;
            float s0x = (a.x * _focal * VHf / W * i0 + 1f) * 0.5f * W;
            float s0y = (1f - a.y * _focal * i0) * 0.5f * VHf;
            float s1x = (b.x * _focal * VHf / W * i1 + 1f) * 0.5f * W;
            float s1y = (1f - b.y * _focal * i1) * 0.5f * VHf;
            float s2x = (c.x * _focal * VHf / W * i2 + 1f) * 0.5f * W;
            float s2y = (1f - c.y * _focal * i2) * 0.5f * VHf;

            float area = (s1x-s0x)*(s2y-s0y) - (s2x-s0x)*(s1y-s0y);
            if (cull && area <= 0) { culledCount++; return false; }
            if (area == 0) return false;

            int minX = (int)Math.Floor(Math.Min(s0x, Math.Min(s1x, s2x)));
            int maxX = (int)Math.Ceiling(Math.Max(s0x, Math.Max(s1x, s2x)));
            int minY = (int)Math.Floor(Math.Min(s0y, Math.Min(s1y, s2y)));
            int maxY = (int)Math.Ceiling(Math.Max(s0y, Math.Max(s1y, s2y)));
            if (minX < 0) minX = 0; if (maxX > W-1) maxX = W-1;
            if (minY < 0) minY = 0; if (maxY > H-1) maxY = H-1;
            if (minX > maxX || minY > maxY) return false;

            p.s0x = s0x; p.s0y = s0y; p.s1x = s1x; p.s1y = s1y; p.s2x = s2x; p.s2y = s2y;
            p.i0 = i0; p.i1 = i1; p.i2 = i2;
            p.u0 = a.u*i0; p.v0 = a.v*i0; p.u1 = b.u*i1; p.v1 = b.v*i1; p.u2 = c.u*i2; p.v2 = c.v*i2;
            p.invArea = 1f / area;
            p.minX = minX; p.maxX = maxX; p.minY = minY; p.maxY = maxY;
            return true;
        }

        // One edge's contribution to a row's conservative x-range. E(fx) = k - fx*d is the
        // edge function before the invArea scale; `s` is the sign of invArea, so inside is
        // s*E >= 0. Edges that are nearly parallel to the row cannot bound x reliably and
        // are left to the exact per-pixel test.
        static void Bound(double k, double d, double s, ref double lo, ref double hi)
        {
            double a = -d * s, b = k * s;              // inside: a*fx + b >= 0
            if (a > 1e-9) { double x = -b / a; if (x > lo) lo = x; }
            else if (a < -1e-9) { double x = -b / a; if (x < hi) hi = x; }
        }

        // DIAGNOSTIC, for the room audit: given this view drawn twice -- once as the game sees
        // it (back faces culled) and once with every face drawn -- how much of it is HOLE?
        //   empty  pixels where nothing was drawn at all: a gap straight out of the room
        //   leak   pixels where the culled picture shows something FURTHER away than a face
        //          that was culled: the eye is looking through the back of a wall or ceiling
        //          at whatever lies beyond it
        // Standing inside a sealed room both should be zero in every direction.
        public static void HoleStats(byte[] colorCulled, float[] depthCulled, float[] depthAll, out int empty, out int leak)
        {
            int e = 0, l = 0;
            for (int i = 0; i < colorCulled.Length; i++)
            {
                if (depthAll[i] > depthCulled[i] * 1.02f + 1e-7f) l++;      // 1/z: bigger is nearer
                else if (depthCulled[i] == 0f) e++;
            }
            empty = e; leak = l;
        }
        // THE AUDIT'S MEASURE: how far is the host's picture from the ENGINE's picture of the
        // same moment? Both are palette indices over the same viewport. Compared in 16x16
        // blocks of mean brightness rather than pixel by pixel, because the two rasterisers
        // round edges and texels differently and that is not what is being looked for.
        //   badPct      blocks whose brightness differs by more than `tol` (0..255)
        //   hostOnlyPct blocks where the host drew something and the engine left black
        //   engOnlyPct  blocks where the engine drew something and the host left black
        // The last one is the missing-geometry signal: the engine has a wall there, we do not.
        public static void CompareFrames(byte[] host, byte[] eng, byte[] pal, int w, int h, int tol,
                                         out double badPct, out double hostOnlyPct, out double engOnlyPct)
        {
            var lum = new float[256];
            for (int i = 0; i < 256; i++) lum[i] = 0.299f * pal[i * 3] + 0.587f * pal[i * 3 + 1] + 0.114f * pal[i * 3 + 2];
            int bw = w / 16, bh = h / 16, bad = 0, ho = 0, eo = 0;
            for (int by = 0; by < bh; by++)
                for (int bx = 0; bx < bw; bx++)
                {
                    float sh = 0, se = 0; int nh = 0, ne = 0;
                    for (int y = 0; y < 16; y++)
                    {
                        int row = (by * 16 + y) * w + bx * 16;
                        for (int x = 0; x < 16; x++)
                        {
                            byte a = host[row + x], b = eng[row + x];
                            sh += lum[a]; se += lum[b];
                            if (a != 0) nh++; if (b != 0) ne++;
                        }
                    }
                    float mh = sh / 256f, me = se / 256f;
                    if (Math.Abs(mh - me) > tol) bad++;
                    if (nh > 128 && ne < 16 && mh > 12) ho++;
                    if (ne > 128 && nh < 16 && me > 12) eo++;
                }
            double n = bw * bh;
            badPct = 100.0 * bad / n; hostOnlyPct = 100.0 * ho / n; engOnlyPct = 100.0 * eo / n;
        }
        // DIAGNOSTIC: which triangle of this soup is in front at one pixel, under the camera
        // now set. -1 if none. For asking "what does the HOST have under the cursor" when the
        // game's own pick disagrees with the picture. One pixel, so no need to be clever;
        // a triangle that crosses the near plane is simply skipped.
        /// <summary>WHERE A SHOT LANDS (2026-10-14, Josh: "sparks, a brief glow and scorch marks that fade where your shots hit
        /// stone"): the ray from the eye through picture pixel (sx, sy), as this camera draws it, against the room as posed --
        /// the nearest hit within limit: its point, its face's normal turned toward the eye, and the triangle (-1 = none).</summary>
        public int PickHit(float[] vx, int[] idx, int[] triTex, float sx, float sy, float limit, out float hx, out float hy, out float hz, out float nx, out float ny, out float nz)
        {
            hx = hy = hz = nx = ny = nz = 0f;
            float fpx = _focal * VHf * 0.5f, xv = (sx - W * 0.5f) / fpx, yv = (VHf * 0.5f - sy) / fpx;
            float rx = _view[0], ry = _view[4], rz = _view[8], ux = _view[1], uy = _view[5], uz = _view[9], fx = _view[2], fy = _view[6], fz = _view[10];
            float ex = -(_view[12] * rx + _view[13] * ux + _view[14] * fx), ey = -(_view[12] * ry + _view[13] * uy + _view[14] * fy), ez = -(_view[12] * rz + _view[13] * uz + _view[14] * fz);
            float dx = rx * xv + ux * yv + fx, dy = ry * xv + uy * yv + fy, dz = rz * xv + uz * yv + fz, dl = (float)Math.Sqrt(dx * dx + dy * dy + dz * dz);
            dx /= dl; dy /= dl; dz /= dl;
            float best = limit; int bt = -1; int nTri = idx.Length / 3;
            for (int t = 0; t < nTri; t++)
            {
                if (triTex[t] < 0) continue;
                int a = idx[t * 3] * 3, b = idx[t * 3 + 1] * 3, c = idx[t * 3 + 2] * 3;
                float e1x = vx[b] - vx[a], e1y = vx[b + 1] - vx[a + 1], e1z = vx[b + 2] - vx[a + 2];
                float e2x = vx[c] - vx[a], e2y = vx[c + 1] - vx[a + 1], e2z = vx[c + 2] - vx[a + 2];
                float qhx = dy * e2z - dz * e2y, qhy = dz * e2x - dx * e2z, qhz = dx * e2y - dy * e2x;
                float det = e1x * qhx + e1y * qhy + e1z * qhz;
                if (det > -1e-7f && det < 1e-7f) continue;
                float inv = 1f / det;
                float px = ex - vx[a], py = ey - vx[a + 1], pz = ez - vx[a + 2];
                float u = (px * qhx + py * qhy + pz * qhz) * inv; if (u < 0f || u > 1f) continue;
                float qx = py * e1z - pz * e1y, qy = pz * e1x - px * e1z, qz = px * e1y - py * e1x;
                float v = (dx * qx + dy * qy + dz * qz) * inv; if (v < 0f || u + v > 1f) continue;
                float d = (e2x * qx + e2y * qy + e2z * qz) * inv;
                if (d > NearZ && d < best)
                {
                    best = d; bt = t;
                    nx = e1y * e2z - e1z * e2y; ny = e1z * e2x - e1x * e2z; nz = e1x * e2y - e1y * e2x;
                }
            }
            if (bt < 0) return -1;
            float nl = (float)Math.Sqrt(nx * nx + ny * ny + nz * nz); if (nl < 1e-9f) { nx = -dx; ny = -dy; nz = -dz; nl = 1f; }
            nx /= nl; ny /= nl; nz /= nl; if (nx * dx + ny * dy + nz * dz > 0f) { nx = -nx; ny = -ny; nz = -nz; }
            hx = ex + dx * best; hy = ey + dy * best; hz = ez + dz * best;
            return bt;
        }
        public int TriAt(float[] vx, int[] idx, int[] triTex, int px, int py)
        {
            int best = -1; float bestIz = 0f;
            float fx = px + 0.5f, fy = py + 0.5f;
            int nTri = idx.Length / 3;
            for (int t = 0; t < nTri; t++)
            {
                if (triTex[t] < 0) continue;
                V a = ToView(vx[idx[t*3]*3], vx[idx[t*3]*3+1], vx[idx[t*3]*3+2]);
                V b = ToView(vx[idx[t*3+1]*3], vx[idx[t*3+1]*3+1], vx[idx[t*3+1]*3+2]);
                V c = ToView(vx[idx[t*3+2]*3], vx[idx[t*3+2]*3+1], vx[idx[t*3+2]*3+2]);
                float ax, ay, ai, bx, by, bi, cx, cy, ci;
                if (!Project(a, out ax, out ay, out ai) || !Project(b, out bx, out by, out bi) || !Project(c, out cx, out cy, out ci)) continue;
                float area = (bx-ax)*(cy-ay) - (cx-ax)*(by-ay);
                if (area == 0) continue;
                float l0 = ((bx-fx)*(cy-fy) - (cx-fx)*(by-fy)) / area; if (l0 < 0) continue;
                float l1 = ((cx-fx)*(ay-fy) - (ax-fx)*(cy-fy)) / area; if (l1 < 0) continue;
                float l2 = 1f - l0 - l1; if (l2 < 0) continue;
                float iz = l0*ai + l1*bi + l2*ci;
                if (iz > bestIz) { bestIz = iz; best = t; }
            }
            return best;
        }
        public void DrawTexturedFast(float[] vx, float[] uv, int[] idx, int[] triTex, Tex[] texes,
                                     bool cullBackfaces, bool flipV)
        {
            DrawFastCore(vx, uv, idx, triTex, texes, cullBackfaces, flipV, 0);
        }

        // ---- PORTALS: another room, seen through a doorway of this one --------------------
        //
        // A doorway is an APERTURE: a polygon standing in the opening (the quad the game hangs
        // its picture of the next room on). Drawing the real room there takes three steps,
        // all after the current room has been drawn normally with that quad left out:
        //
        //   1. AddPortal    marks every pixel where the aperture is the nearest thing --
        //                   nearer than the room's own geometry (a door leaf standing in
        //                   front of it hides it, properly) and nearer than any other
        //                   aperture. It records the aperture's depth there.
        //   2. EndPortals   wipes those pixels: what was drawn behind the aperture belongs
        //                   to this room's void, not to the picture.
        //   3. DrawTexturedMasked  draws the neighbour, already moved into this room's
        //                   coordinates, into its own pixels only. (What of the neighbour
        //                   may be drawn at all is decided once, when it is loaded: see
        //                   Portals.CullBehind.)
        //
        // None of this touches the plain path: DrawTexturedFast is the same code with the
        // portal test compiled to a never-taken branch.
        public byte[] Mask;
        public float[] MaskDepth;
        public readonly int[] MaskCount = new int[256];
        readonly int[] _mX0 = new int[256], _mX1 = new int[256], _mY0 = new int[256], _mY1 = new int[256];
        bool _maskDirty;

        public void BeginPortals()
        {
            if (Mask == null) { Mask = new byte[W * H]; MaskDepth = new float[W * H]; _inner = new byte[W * H]; }
            else if (_maskDirty) { Array.Clear(Mask, 0, Mask.Length); Array.Clear(_inner, 0, _inner.Length); }
            _maskDirty = false;
            Array.Clear(_restricted, 0, 256);
            for (int i = 0; i < 256; i++) { MaskCount[i] = 0; _mX0[i] = W; _mX1[i] = -1; _mY0[i] = H; _mY1[i] = -1; }
        }

        // `triVerts`: three vertex indices per aperture triangle, into `vx`. Returns the number
        // of pixels the aperture claimed (0 = not in view, or wholly hidden).
        public int AddPortal(float[] vx, int[] triVerts, byte id) { return AddPortal(vx, triVerts, id, false); }
        // `drawn`: the aperture is a surface that has ALREADY been drawn into the picture (water),
        // so it is in the depth buffer at its own depth and must count as visible there.
        public int AddPortal(float[] vx, int[] triVerts, byte id, bool drawn)
        {
            float nearer = drawn ? 0.999f : 1.001f;
            if (id == 0 || Mask == null) throw new ArgumentException("BeginPortals first; id 0 means 'no portal'");
            int nTri = triVerts.Length / 3;
            var pts = new PTri[nTri * 2];
            int n = 0; long culled = 0;
            VT[] inP = new VT[4], outP = new VT[8];
            for (int t = 0; t < nTri; t++)
            {
                for (int k = 0; k < 3; k++)
                {
                    int a = triVerts[t * 3 + k];
                    V p = ToView(vx[a * 3], vx[a * 3 + 1], vx[a * 3 + 2]);
                    inP[k].x = p.x; inP[k].y = p.y; inP[k].z = p.z; inP[k].u = 0; inP[k].v = 0;
                }
                int nOut = ClipNear(inP, 3, outP, NearZ);
                if (nOut < 3) continue;
                for (int k = 1; k <= nOut - 2; k++)
                    if (Prepare(ref outP[0], ref outP[k], ref outP[k + 1], false, ref pts[n], ref culled)) n++;
            }
            if (n == 0) return 0;
            int minY = H, maxY = -1;
            for (int q = 0; q < n; q++) { if (pts[q].minY < minY) minY = pts[q].minY; if (pts[q].maxY > maxY) maxY = pts[q].maxY; }
            int rows = maxY - minY + 1;
            int bands = Math.Max(1, Math.Min(Threads * 2, rows / 8));
            int rowsPer = (rows + bands - 1) / bands;
            int[] cnt = new int[bands], bx0 = new int[bands], bx1 = new int[bands], by0 = new int[bands], by1 = new int[bands];
            int Wl = W; byte[] mask = Mask; float[] md = MaskDepth, depth = Depth;
            int count = n;
            Parallel.For(0, bands, new ParallelOptions { MaxDegreeOfParallelism = Threads }, band =>
            {
                int y0 = minY + band * rowsPer, y1 = Math.Min(maxY + 1, y0 + rowsPer);
                int c = 0, x0 = Wl, x1 = -1, yy0 = int.MaxValue, yy1 = -1;
                for (int q = 0; q < count; q++)
                {
                    int tMinY = pts[q].minY, tMaxY = pts[q].maxY;
                    if (tMaxY < y0 || tMinY >= y1) continue;
                    if (tMinY < y0) tMinY = y0; if (tMaxY > y1 - 1) tMaxY = y1 - 1;
                    float s0x = pts[q].s0x, s0y = pts[q].s0y, s1x = pts[q].s1x, s1y = pts[q].s1y, s2x = pts[q].s2x, s2y = pts[q].s2y;
                    float i0 = pts[q].i0, i1 = pts[q].i1, i2 = pts[q].i2, invArea = pts[q].invArea;
                    for (int y = tMinY; y <= tMaxY; y++)
                    {
                        float fy = y + 0.5f;
                        float c0y = s0y - fy, c1y = s1y - fy, c2y = s2y - fy;
                        int row = y * Wl;
                        for (int x = pts[q].minX; x <= pts[q].maxX; x++)
                        {
                            float fx = x + 0.5f;
                            float l0 = ((s1x - fx) * c2y - (s2x - fx) * c1y) * invArea; if (l0 < 0) continue;
                            float l1 = ((s2x - fx) * c0y - (s0x - fx) * c2y) * invArea; if (l1 < 0) continue;
                            float l2 = 1f - l0 - l1; if (l2 < 0) continue;
                            float iz = l0 * i0 + l1 * i1 + l2 * i2;
                            int o = row + x;
                            // NEARER THAN THE ROOM BY A MARGIN: something of this room's lying in
                            // the aperture's own plane (the game stands a "door shut" picture
                            // there) keeps its pixels rather than fighting for them.
                            if (iz <= depth[o] * nearer) continue;
                            if (mask[o] != 0 && iz <= md[o]) continue;
                            mask[o] = id; md[o] = iz; c++;
                            if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < yy0) yy0 = y; if (y > yy1) yy1 = y;
                        }
                    }
                }
                cnt[band] = c; bx0[band] = x0; bx1[band] = x1; by0[band] = yy0; by1[band] = yy1;
            });
            int total = 0;
            for (int b = 0; b < bands; b++)
            {
                if (cnt[b] == 0) continue;
                total += cnt[b];
                if (bx0[b] < _mX0[id]) _mX0[id] = bx0[b]; if (bx1[b] > _mX1[id]) _mX1[id] = bx1[b];
                if (by0[b] < _mY0[id]) _mY0[id] = by0[b]; if (by1[b] > _mY1[id]) _mY1[id] = by1[b];
            }
            MaskCount[id] += total;
            if (total > 0) _maskDirty = true;
            return total;
        }

        // THE OPENING IS THE SMALLER OF THE TWO. This room's picture quad is often much bigger
        // than the tunnel it is a picture of (the spa's is 123 units square over a 65-unit
        // tunnel: the picture paints the tunnel's walls round the opening). Through an aperture
        // that size the far tunnel is seen from OUTSIDE -- past its walls, into the back of
        // the far room -- which is the "broken polygons" of the first live run. The far room
        // has its own picture quad, standing in the same plane and exactly the size of ITS
        // tunnel mouth, so the aperture is cut down to where the two overlap; the rest of this
        // room's quad becomes plain dark wall, as the picture painted it.
        byte[] _inner; readonly bool[] _restricted = new bool[256];
        public void RestrictPortal(float[] quad, byte id)
        {
            if (id == 0 || Mask == null || MaskCount[id] == 0 || quad == null || quad.Length < 12) return;
            _restricted[id] = true;
            var pts = new PTri[4];
            int n = 0; long culled = 0;
            VT[] inP = new VT[4], outP = new VT[8];
            int[] order = { 0, 1, 2, 0, 2, 3 };
            for (int t = 0; t < 2; t++)
            {
                for (int k = 0; k < 3; k++)
                {
                    int a = order[t * 3 + k];
                    V p = ToView(quad[a * 3], quad[a * 3 + 1], quad[a * 3 + 2]);
                    inP[k].x = p.x; inP[k].y = p.y; inP[k].z = p.z; inP[k].u = 0; inP[k].v = 0;
                }
                int nOut = ClipNear(inP, 3, outP, NearZ);
                if (nOut < 3) continue;
                for (int k = 1; k <= nOut - 2; k++)
                    if (Prepare(ref outP[0], ref outP[k], ref outP[k + 1], false, ref pts[n], ref culled)) n++;
            }
            int cx0 = _mX0[id], cx1 = _mX1[id], cy0 = _mY0[id], cy1 = _mY1[id];
            int Wl = W; byte[] mask = Mask, inner = _inner; int count = n;
            if (count == 0 || cy1 < cy0) return;
            Parallel.For(cy0, cy1 + 1, new ParallelOptions { MaxDegreeOfParallelism = Threads }, y =>
            {
                float fy = y + 0.5f; int row = y * Wl;
                for (int q = 0; q < count; q++)
                {
                    if (y < pts[q].minY || y > pts[q].maxY) continue;
                    float s0x = pts[q].s0x, s1x = pts[q].s1x, s2x = pts[q].s2x, invArea = pts[q].invArea;
                    float c0y = pts[q].s0y - fy, c1y = pts[q].s1y - fy, c2y = pts[q].s2y - fy;
                    int xa = Math.Max(pts[q].minX, cx0), xb = Math.Min(pts[q].maxX, cx1);
                    for (int x = xa; x <= xb; x++)
                    {
                        int o = row + x;
                        if (mask[o] != id) continue;
                        float fx = x + 0.5f;
                        float l0 = ((s1x - fx) * c2y - (s2x - fx) * c1y) * invArea; if (l0 < 0) continue;
                        float l1 = ((s2x - fx) * c0y - (s0x - fx) * c2y) * invArea; if (l1 < 0) continue;
                        if (1f - l0 - l1 < 0) continue;
                        inner[o] = id;
                    }
                }
            });
        }

        // ---- REFLECTIONS IN WATER ---------------------------------------------------------
        //
        // Flat water is a mirror lying on its back, and a mirror shows the room turned upside
        // down about its own plane. So: mark the pixels where the water is the nearest thing
        // (the same marking a doorway uses), then draw the WHOLE ROOM AGAIN with every vertex
        // flipped through the water's height, into those pixels only. Three rules make it
        // read as water rather than as a hole in the floor:
        //   * MaskBeyond  only what lies BEYOND the water surface is drawn. The pool's own
        //                 floor, flipped, comes up above the water and must not appear;
        //                 neither must the water quad itself.
        //   * MaskKeep    a fraction of the pixels (by the screen pattern) are left as the
        //                 water's own texture, so the surface is still there to see.
        //   * MaskDim     the reflection is dimmer than what it reflects.
        // EndPortals(true) keeps the water's colour under the mask instead of wiping it.
        // Flipping reverses every triangle's winding; SwapWinding gives the index list that
        // puts it back, so back-face culling still culls the right faces.
        public bool MaskBeyond = false; public float MaskKeep = 0f, MaskDim = 1f;
        public static void Mirror(float[] src, float[] dst, float planeY)
        {
            float two = planeY * 2f;
            for (int i = 0; i + 2 < src.Length; i += 3) { dst[i] = src[i]; dst[i + 1] = two - src[i + 1]; dst[i + 2] = src[i + 2]; }
        }
        public static int[] SwapWinding(int[] idx)
        {
            var r = new int[idx.Length];
            for (int i = 0; i + 2 < idx.Length; i += 3) { r[i] = idx[i]; r[i + 1] = idx[i + 2]; r[i + 2] = idx[i + 1]; }
            return r;
        }

        public void EndPortals() { EndPortals(false); }
        public void EndPortals(bool keepColour)
        {
            if (!_maskDirty) return;
            int y0 = H, y1 = -1;
            for (int i = 1; i < 256; i++) { if (MaskCount[i] == 0) continue; if (_mY0[i] < y0) y0 = _mY0[i]; if (_mY1[i] > y1) y1 = _mY1[i]; }
            if (y1 < y0) return;
            int Wl = W; byte[] mask = Mask, color = Color, inner = _inner; float[] depth = Depth, md = MaskDepth; bool[] restricted = _restricted;
            int[] c32 = (Rgb && Color32 != null) ? Color32 : null;
            if (c32 != null && _under32 == null) _under32 = new int[W * H];
            int[] under = _under32;
            Parallel.For(y0, y1 + 1, new ParallelOptions { MaxDegreeOfParallelism = Threads }, y =>
            {
                int row = y * Wl;
                for (int x = 0; x < Wl; x++)
                {
                    int o = row + x; byte id = mask[o];
                    if (id == 0 || id == 255) continue;
                    if (c32 != null) { if (keepColour) under[o] = c32[o]; else c32[o] = 0; }
                    if (!keepColour) color[o] = 0;
                    // outside the far tunnel's mouth: dark wall in the aperture's plane, not a view
                    if (restricted[id] && inner[o] != id) { depth[o] = md[o]; mask[o] = 255; }   // 255: wall, no portal draws there
                    else depth[o] = 0f;
                }
            });
        }

        public void DrawTexturedMasked(float[] vx, float[] uv, int[] idx, int[] triTex, Tex[] texes,
                                       bool cullBackfaces, bool flipV, byte id)
        {
            if (id == 0 || Mask == null || MaskCount[id] == 0) return;
            DrawFastCore(vx, uv, idx, triTex, texes, cullBackfaces, flipV, id);
        }

        void DrawFastCore(float[] vx, float[] uv, int[] idx, int[] triTex, Tex[] texes,
                          bool cullBackfaces, bool flipV, int maskId)
        {
            if (vx == null || uv == null || idx == null || triTex == null || texes == null) throw new ArgumentException("missing input");
            if (idx.Length % 3 != 0) throw new ArgumentException("index count is not a multiple of 3");
            if (triTex.Length != idx.Length / 3) throw new ArgumentException("one texture index per triangle, please");

            int nTri = idx.Length / 3;
            TrisIn += nTri;
            _lightLen = (float)Math.Sqrt(LightX*LightX + LightY*LightY + LightZ*LightZ);
            _fogCurve = (FogCurve > 0.05f && FogCurve < 8f) ? FogCurve : 1f;
            if (_lightLen < 1e-6f) { LightX = 0; LightY = 1; LightZ = 0; _lightLen = 1f; }

            int clipX0 = 0, clipX1 = W - 1, clipY0 = 0, clipY1 = H - 1;
            if (maskId != 0) { clipX0 = _mX0[maskId]; clipX1 = _mX1[maskId]; clipY0 = _mY0[maskId]; clipY1 = _mY1[maskId]; }
            byte[] mask = Mask; byte mid = (byte)maskId;
            float[] maskDepthArr = MaskDepth; bool maskBeyond = MaskBeyond && maskId != 0;
            float maskKeep = maskId != 0 ? MaskKeep : 0f, dimK = maskId != 0 ? MaskDim : 1f;
            float lvlPlain = (LightTab != null) ? (LightLevels - 1) / LightMaxGain : 0f;

            bool lampOn = Lamp && LightTab != null && Shade == null;
            if (lampOn) BuildLampTables();
            bool filterOn = Filter;
            bool rgbOn = Rgb && Color32 != null;
            if (rgbOn) foreach (Tex t in texes) if (t != null && t.Rgb == null) { rgbOn = false; break; }    // not prepared: the 8-bit picture only
            if ((filterOn || rgbOn) && _log2Tab.Length != DIST_N) { _log2Tab = new float[DIST_N]; for (int i = 0; i < DIST_N; i++) _log2Tab[i] = (float)Math.Log(Math.Max(1.0, i * DIST_STEP), 2.0); }
            if (rgbOn) filterOn = false;        // the 8-bit picture is not what is shown: nearest texel is all it needs
            if (filterOn)
            {
                foreach (Tex t in texes) if (t != null && t.Mips == null) { filterOn = false; break; }      // not prepared: draw unfiltered rather than fail
            }
            int[] color32 = rgbOn ? Color32 : null, under32 = _under32;
            float lampRoomL = LampRoom, lampPowerL = LampPower;
            // smooth shading: each fan's normal this frame, in view space (sum of its faces' normals,
            // which the cross product already weights by area)
            int[] cg = CornerGroup; int gcount = GroupCount;
            bool smoothOn = SmoothShade && lampOn && rgbOn && maskId == 0 && cg != null && cg.Length == idx.Length && gcount > 0;
            float[] gsum = null;
            if (smoothOn)
            {
                if (_gsum.Length < gcount * 3) _gsum = new float[gcount * 3]; else Array.Clear(_gsum, 0, gcount * 3);
                gsum = _gsum;
                for (int t = 0; t < nTri; t++)
                {
                    int ti = triTex[t]; if (ti < 0 || ti >= texes.Length || texes[ti] == null) continue;
                    int g0 = cg[t * 3], g1 = cg[t * 3 + 1], g2 = cg[t * 3 + 2]; if (g0 < 0 && g1 < 0 && g2 < 0) continue;
                    int a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
                    V pa = ToView(vx[a * 3], vx[a * 3 + 1], vx[a * 3 + 2]), pb = ToView(vx[b * 3], vx[b * 3 + 1], vx[b * 3 + 2]), pc = ToView(vx[c * 3], vx[c * 3 + 1], vx[c * 3 + 2]);
                    float ux = pb.x - pa.x, uy = pb.y - pa.y, uz = pb.z - pa.z, wx = pc.x - pa.x, wy = pc.y - pa.y, wz = pc.z - pa.z;
                    float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
                    if (g0 >= 0 && g0 < gcount) { gsum[g0 * 3] += nx; gsum[g0 * 3 + 1] += ny; gsum[g0 * 3 + 2] += nz; }
                    if (g1 >= 0 && g1 < gcount) { gsum[g1 * 3] += nx; gsum[g1 * 3 + 1] += ny; gsum[g1 * 3 + 2] += nz; }
                    if (g2 >= 0 && g2 < gcount) { gsum[g2 * 3] += nx; gsum[g2 * 3 + 1] += ny; gsum[g2 * 3 + 2] += nz; }
                }
            }
            float[] log2Tab = _log2Tab, bayerB = _bayerB;

            // ---- prepare: once per triangle, on this thread ----------------------
            // A near-clipped triangle fans into at most two, hence 2 * nTri.
            if (_pt.Length < nTri * 2) { _pt = new PTri[nTri * 2]; _ptKey = new float[nTri * 2]; }
            int n = 0; long culledTotal = 0;
            VT[] inP = _clipIn, outP = _clipOut;
            for (int t = 0; t < nTri; t++)
            {
                int ti = triTex[t];
                if (ti < 0 || ti >= texes.Length || texes[ti] == null) continue;
                int a = idx[t*3], b = idx[t*3+1], c = idx[t*3+2];

                float faceLight = 1f;
                if (Shade != null)
                {
                    float ax = vx[a*3], ay = vx[a*3+1], az = vx[a*3+2];
                    float e1x = vx[b*3]-ax,   e1y = vx[b*3+1]-ay, e1z = vx[b*3+2]-az;
                    float e2x = vx[c*3]-ax,   e2y = vx[c*3+1]-ay, e2z = vx[c*3+2]-az;
                    float nx = e1y*e2z - e1z*e2y, ny = e1z*e2x - e1x*e2z, nz = e1x*e2y - e1y*e2x;
                    float nl = (float)Math.Sqrt(nx*nx + ny*ny + nz*nz);
                    float lam = 1f;
                    if (nl > 1e-12f)
                    {
                        lam = (nx*LightX + ny*LightY + nz*LightZ) / (nl * _lightLen);
                        if (lam < 0) lam = -lam;
                    }
                    faceLight = Ambient + (1f - Ambient) * (1f - NormalLight + NormalLight * lam);
                    if (faceLight > 1f) faceLight = 1f;
                }

                V pa = ToView(vx[a*3], vx[a*3+1], vx[a*3+2]);
                V pb = ToView(vx[b*3], vx[b*3+1], vx[b*3+2]);
                V pc = ToView(vx[c*3], vx[c*3+1], vx[c*3+2]);
                float lampFacing = 1f, triLod = 0f, tnx = 0f, tny = 0f, tnz = 1f;
                if (lampOn || filterOn || rgbOn)
                {
                    // how squarely this face looks back at the lamp (which is at the eye, the
                    // origin of view space): |n . c| over their lengths, c the face's centre.
                    // Softened, so a grazing wall dims rather than vanishing.
                    float ux = pb.x-pa.x, uy = pb.y-pa.y, uz = pb.z-pa.z, wx = pc.x-pa.x, wy = pc.y-pa.y, wz = pc.z-pa.z;
                    float nx2 = uy*wz - uz*wy, ny2 = uz*wx - ux*wz, nz2 = ux*wy - uy*wx;
                    float cx2 = pa.x+pb.x+pc.x, cy2 = pa.y+pb.y+pc.y, cz2 = pa.z+pb.z+pc.z;
                    float den = (float)Math.Sqrt((nx2*nx2 + ny2*ny2 + nz2*nz2) * (cx2*cx2 + cy2*cy2 + cz2*cz2));
                    float f = den > 1e-12f ? Math.Abs(nx2*cx2 + ny2*cy2 + nz2*cz2) / den : 1f;
                    lampFacing = 0.35f + 0.65f * f;
                    float nl2 = (float)Math.Sqrt(nx2*nx2 + ny2*ny2 + nz2*nz2); if (nl2 > 1e-12f) { tnx = nx2 / nl2; tny = ny2 / nl2; tnz = nz2 / nl2; }
                    if (filterOn || rgbOn)
                    {
                        // texels per world unit on this face, from its area in texels and in the world
                        Tex t0 = texes[ti];
                        float tw0 = rgbOn ? t0.Rgb[0].W : t0.W, th0 = rgbOn ? t0.Rgb[0].H : t0.H;
                        float du1 = (uv[b*2]-uv[a*2]) * tw0, dv1 = (uv[b*2+1]-uv[a*2+1]) * th0, du2 = (uv[c*2]-uv[a*2]) * tw0, dv2 = (uv[c*2+1]-uv[a*2+1]) * th0;
                        float texArea = Math.Abs(du1*dv2 - du2*dv1);
                        float worldArea = (float)Math.Sqrt(nx2*nx2 + ny2*ny2 + nz2*nz2);     // view space is rigid: same area
                        if (texArea > 1e-6f && worldArea > 1e-6f)
                        {
                            // texels per pixel = density * depth / focal, and seen obliquely the
                            // pixel covers more of the face; half the usual correction, because
                            // the full one blurs a floor long before it shimmers
                            float fcl = f < 0.06f ? 0.06f : f;
                            triLod = 0.5f * (float)Math.Log(texArea / worldArea, 2.0) - (float)Math.Log(_focal * VHf * 0.5f, 2.0) - 0.5f * (float)Math.Log(fcl, 2.0) + MipBias;
                        }
                        else triLod = -100f;
                    }
                }
                inP[0].f = lampFacing; inP[1].f = lampFacing; inP[2].f = lampFacing;
                if (smoothOn)
                {
                    for (int k = 0; k < 3; k++)
                    {
                        int g = cg[t * 3 + k]; if (g < 0 || g >= gcount) continue;
                        V pk = k == 0 ? pa : (k == 1 ? pb : pc);
                        float gx = gsum[g * 3], gy = gsum[g * 3 + 1], gz = gsum[g * 3 + 2];
                        float dn = (float)Math.Sqrt((gx * gx + gy * gy + gz * gz) * (pk.x * pk.x + pk.y * pk.y + pk.z * pk.z));
                        if (dn > 1e-12f) inP[k].f = 0.35f + 0.65f * Math.Abs(gx * pk.x + gy * pk.y + gz * pk.z) / dn;
                    }
                }
                inP[0].x=pa.x; inP[0].y=pa.y; inP[0].z=pa.z; inP[0].u=uv[a*2]; inP[0].v=uv[a*2+1];
                inP[1].x=pb.x; inP[1].y=pb.y; inP[1].z=pb.z; inP[1].u=uv[b*2]; inP[1].v=uv[b*2+1];
                inP[2].x=pc.x; inP[2].y=pc.y; inP[2].z=pc.z; inP[2].u=uv[c*2]; inP[2].v=uv[c*2+1];

                int nOut = ClipNear(inP, 3, outP, NearZ);
                if (nOut < 3) continue;
                for (int k = 1; k <= nOut - 2; k++)
                {
                    if (!Prepare(ref outP[0], ref outP[k], ref outP[k+1], cullBackfaces, ref _pt[n], ref culledTotal)) continue;
                    if (maskId != 0)
                    {
                        // only the part of it that can fall inside this portal's pixels
                        if (_pt[n].minX < clipX0) _pt[n].minX = clipX0; if (_pt[n].maxX > clipX1) _pt[n].maxX = clipX1;
                        if (_pt[n].minY < clipY0) _pt[n].minY = clipY0; if (_pt[n].maxY > clipY1) _pt[n].maxY = clipY1;
                        if (_pt[n].minX > _pt[n].maxX || _pt[n].minY > _pt[n].maxY) continue;
                    }
                    _pt[n].tex = ti; _pt[n].src = t; _pt[n].faceLight = faceLight; _pt[n].lamp = lampFacing; _pt[n].lod = triLod;
                    _pt[n].f0 = outP[0].f; _pt[n].f1 = outP[k].f; _pt[n].f2 = outP[k+1].f;
                    _pt[n].nvx = tnx; _pt[n].nvy = tny; _pt[n].nvz = tnz;
                    float near = _pt[n].i0; if (_pt[n].i1 > near) near = _pt[n].i1; if (_pt[n].i2 > near) near = _pt[n].i2;
                    _ptKey[n] = -near;                 // ascending sort => nearest first
                    n++;
                }
            }
            TrisCulled += culledTotal;
            if (SortFrontToBack && n > 1) Array.Sort(_ptKey, _pt, 0, n);

            // ---- fill: many thin bands, so the scheduler can even out the load ------
            // 16 fat bands left the ones over a floor or ceiling working long after the
            // others had finished. Each band still owns its rows outright: no sharing.
            int bands = Math.Max(1, Math.Min(Threads * 4, H / 4));
            int rowsPer = (H + bands - 1) / bands;
            byte[] hit = new byte[nTri];
            long[] px = new long[bands];
            int count = n;
            PTri[] pt = _pt;
            int Wl = W;
            byte[] color = Color; float[] depth = Depth;
            byte[] shade = Shade; int shadeLevels = ShadeLevels;
            float fogFar = FogFar, fogNear = FogNear, fogCurve = _fogCurve;
            byte[] lightTab = LightTab; int lightLevels = LightLevels;
            float[] coneTab = _coneTab, distTab = _distTab, sfadeTab = _sfadeTab; float[] bayer = _bayer; float sDark = ShadowDark;
            float lvlScale = lampOn ? (lightLevels - 1) / LightMaxGain : 0f;
            float lampBase = LampRoom * lvlScale, lampGain = LampPower * lvlScale;
            float fpx = _focal * VHf * 0.5f;                     // pixels per unit of tan(angle off axis)
            float coneScale = (CONE_N - 1) / (CONE_MAX_TAN2 * fpx * fpx);
            float cxp = W * 0.5f + LampCx, cyp = VHf * 0.5f + LampCy;
            float[] smap = lampOn ? ShadowMap : null; int sW = ShadowW, sH = ShadowH;
            float[] smap2 = (smap != null) ? ShadowMap2 : null; float s2Ox = Shadow2Ox, s2Oy = Shadow2Oy;
            float sF = ShadowFocalPx, sHalfX = sW * 0.5f, sHalfY = sH * 0.5f, sOx = ShadowOx, sOy = ShadowOy, sBias = 1f + ShadowBias, sSoft = ShadowSoft;
            float invFpx = 1f / fpx, cx0 = W * 0.5f, cy0 = VHf * 0.5f;
            // placed lights, moved into view space for this frame; fog, as a per-depth table
            int nLights = (rgbOn && maskId == 0) ? Math.Min(LightCount, MaxLights) : 0;
            float[] lv = new float[nLights * 8];
            for (int li = 0; li < nLights; li++)
            {
                V p = ToView(Lights[li * 8], Lights[li * 8 + 1], Lights[li * 8 + 2]);
                lv[li * 8] = p.x; lv[li * 8 + 1] = p.y; lv[li * 8 + 2] = p.z;
                lv[li * 8 + 3] = Lights[li * 8 + 3]; lv[li * 8 + 4] = Lights[li * 8 + 4]; lv[li * 8 + 5] = Lights[li * 8 + 5];
                float rg = Lights[li * 8 + 6]; lv[li * 8 + 6] = rg > 1f ? 1f / (rg * rg) : 1f;
            }
            // the light views' axes, turned into view space (directions: rotation only)
            float[] lsv = new float[nLights * 9]; bool[] lsHas = new bool[nLights]; float[][] lsMap = new float[nLights][]; int[] lsSize = new int[nLights]; float[] lsFocal = new float[nLights];
            for (int li = 0; li < nLights; li++)
            {
                if (_lsMap[li] == null) continue;
                lsHas[li] = true; lsMap[li] = _lsMap[li]; lsSize[li] = _lsSize[li]; lsFocal[li] = _lsFocal[li];
                for (int a = 0; a < 3; a++)
                {
                    float dx = _lsAxes[li * 9 + a * 3], dy = _lsAxes[li * 9 + a * 3 + 1], dz = _lsAxes[li * 9 + a * 3 + 2];
                    lsv[li * 9 + a * 3]     = dx * _view[0] + dy * _view[4] + dz * _view[8];
                    lsv[li * 9 + a * 3 + 1] = dx * _view[1] + dy * _view[5] + dz * _view[9];
                    lsv[li * 9 + a * 3 + 2] = dx * _view[2] + dy * _view[6] + dz * _view[10];
                }
            }
            float lsBias = 1f + LightShadowBias;
            bool fogOn = rgbOn && Fog32 && maskId == 0 && Fog32Far > Fog32Near;
            float fogA = fogOn ? 1f / (Fog32Far - Fog32Near) : 0f, fogNearL = Fog32Near, fogMaxL = Fog32Max;
            int fogR = (FogColor32 >> 16) & 255, fogG = (FogColor32 >> 8) & 255, fogB = FogColor32 & 255;

            Parallel.For(0, bands, new ParallelOptions { MaxDegreeOfParallelism = Threads }, band =>
            {
                int y0 = band * rowsPer, y1 = Math.Min(H, y0 + rowsPer);
                if (y0 >= y1) return;
                long written = 0;
                for (int q = 0; q < count; q++)
                {
                    int tMinY = pt[q].minY, tMaxY = pt[q].maxY;
                    if (tMaxY < y0 || tMinY >= y1) continue;
                    if (tMinY < y0) tMinY = y0; if (tMaxY > y1 - 1) tMaxY = y1 - 1;

                    float s0x = pt[q].s0x, s0y = pt[q].s0y, s1x = pt[q].s1x, s1y = pt[q].s1y, s2x = pt[q].s2x, s2y = pt[q].s2y;
                    float i0 = pt[q].i0, i1 = pt[q].i1, i2 = pt[q].i2;
                    float u0 = pt[q].u0, w0q = pt[q].v0, u1 = pt[q].u1, w1q = pt[q].v1, u2 = pt[q].u2, w2q = pt[q].v2;
                    float invArea = pt[q].invArea, faceLight = pt[q].faceLight, triLamp = pt[q].lamp * lampGain, triLodQ = pt[q].lod;
                    int bMinX = pt[q].minX, bMaxX = pt[q].maxX;
                    Tex tex = texes[pt[q].tex];
                    Tex[] mips = filterOn ? tex.Mips : null; int maxMip = filterOn ? mips.Length - 1 : 0;
                    Tex.RgbLevel[] rl = rgbOn ? tex.Rgb : null; int maxR = rgbOn ? rl.Length - 1 : 0;
                    float triLampRaw = pt[q].lamp * lampPowerL;
                    float f0q = pt[q].f0 * lampPowerL, f1q = pt[q].f1 * lampPowerL, f2q = pt[q].f2 * lampPowerL;
                    float tnvx = pt[q].nvx, tnvy = pt[q].nvy, tnvz = pt[q].nvz;
                    byte[] texIdx = tex.Idx; int texW = tex.W, texH = tex.H;
                    double sgn = invArea >= 0 ? 1.0 : -1.0;
                    bool narrow = (bMaxX - bMinX) < 12;
                    bool any = false;

                    for (int y = tMinY; y <= tMaxY; y++)
                    {
                        float fy = y + 0.5f;
                        float c0y = s0y - fy, c1y = s1y - fy, c2y = s2y - fy;

                        int xa = bMinX, xb = bMaxX;
                        if (!narrow)
                        {
                            // e0 = (s1x-fx)*c2y - (s2x-fx)*c1y = (s1x*c2y - s2x*c1y) - fx*(c2y - c1y)
                            double lo = -1e30, hi = 1e30;
                            Bound((double)s1x*c2y - (double)s2x*c1y, (double)c2y - c1y, sgn, ref lo, ref hi);
                            Bound((double)s2x*c0y - (double)s0x*c2y, (double)c0y - c2y, sgn, ref lo, ref hi);
                            Bound((double)s0x*c1y - (double)s1x*c0y, (double)c1y - c0y, sgn, ref lo, ref hi);
                            if (hi < lo - 4.0) continue;                   // row misses the triangle
                            // fx = x + 0.5; pad two pixels each side, then clamp to the box
                            double dl = lo - 0.5 - 2.0, dh = hi - 0.5 + 2.0;
                            if (dl > xa) xa = dl >= xb + 1 ? xb + 1 : (int)dl;
                            if (dh < xb) xb = dh <= xa - 1 ? xa - 1 : (int)dh + 1;
                            if (xb > bMaxX) xb = bMaxX;
                            if (xa > xb) continue;
                        }

                        int row = y * Wl;
                        float dyp = fy - cyp, rowR2 = dyp * dyp; int by4 = (y & 3) << 2;
                        float rowTy = (cy0 - fy) * invFpx;
                        for (int x = xa; x <= xb; x++)
                        {
                            float fx = x + 0.5f;
                            float l0 = ((s1x-fx)*c2y - (s2x-fx)*c1y) * invArea;
                            if (l0 < 0) continue;
                            float l1 = ((s2x-fx)*c0y - (s0x-fx)*c2y) * invArea;
                            if (l1 < 0) continue;
                            float l2 = 1f - l0 - l1;
                            if (l2 < 0) continue;
                            float iz = l0*i0 + l1*i1 + l2*i2;
                            int o = row + x;
                            if (iz <= depth[o]) continue;
                            if (mid != 0)
                            {
                                if (mask[o] != mid) continue;
                                if (maskBeyond && iz >= maskDepthArr[o] * 0.998f) continue;       // not beyond the surface
                                // the surface itself shows here (in true colour it is blended instead, below)
                                if (maskKeep > 0f && !rgbOn && bayerB[((y & 3) << 2) | ((x + 2) & 3)] < maskKeep) continue;
                            }

                            float w = 1f / iz;
                            float uu = (l0*u0 + l1*u1 + l2*u2) * w;
                            float vv = (l0*w0q + l1*w1q + l2*w2q) * w;
                            if (flipV) vv = 1f - vv;
                            // floor without the double call; the range guard keeps the
                            // int cast exact and sends anything strange (NaN included)
                            // down the reference path
                            if (uu > -1e9f && uu < 1e9f) { int f = (int)uu; if (uu < f) f--; uu -= f; }
                            else uu -= (float)Math.Floor(uu);
                            if (vv > -1e9f && vv < 1e9f) { int f = (int)vv; if (vv < f) f--; vv -= f; }
                            else vv -= (float)Math.Floor(vv);
                            byte ink;
                            if (!filterOn)
                            {
                                int tx = (int)(uu * texW); if (tx >= texW) tx = texW-1; if (tx < 0) tx = 0;
                                int ty = (int)(vv * texH); if (ty >= texH) ty = texH-1; if (ty < 0) ty = 0;
                                ink = texIdx[ty * texW + tx];
                            }
                            else
                            {
                                int bi = by4 | (x & 3);
                                // which copy: this face's density, this pixel's depth, a dithered step
                                int wq = (int)(w * (1f / DIST_STEP)); if (wq > DIST_N - 1) wq = DIST_N - 1; else if (wq < 0) wq = 0;
                                float lodf = triLodQ + log2Tab[wq] + bayerB[bi];
                                int mip = lodf <= 0f ? 0 : (int)lodf; if (mip > maxMip) mip = maxMip;
                                Tex tm = mips[mip]; int mw = tm.W, mh = tm.H;
                                // one of the four nearest texels, chosen by the screen pattern; the
                                // texture repeats, so the neighbour of the last column is the first
                                float px2 = uu * mw - 0.5f + bayer[bi], py2 = vv * mh - 0.5f + bayerB[((x & 3) << 2) | (y & 3)];
                                int tx = (int)px2; if (px2 < 0f) tx = mw - 1; else if (tx >= mw) tx -= mw;
                                int ty = (int)py2; if (py2 < 0f) ty = mh - 1; else if (ty >= mh) ty -= mh;
                                ink = tm.Idx[ty * mw + tx];
                            }
                            if (ink == 0) continue;
                            float gainF = 1f;

                            if (shade != null)
                            {
                                float att = (fogFar - w) * (1f / (fogFar - fogNear));
                                if (att > 1f) att = 1f; else if (att < 0f) att = 0f;
                                if (fogCurve != 1f) att = (float)Math.Pow(att, fogCurve);
                                float lit = faceLight * att;
                                if (lit < 0f) lit = 0f; else if (lit > 1f) lit = 1f;
                                int lvl = (int)(lit * (shadeLevels - 1) + 0.5f);
                                if (lvl < 0) lvl = 0; else if (lvl >= shadeLevels) lvl = shadeLevels - 1;
                                ink = shade[lvl * 256 + ink];
                                if (ink == 0) continue;
                            }

                            if (lampOn)
                            {
                                float dxp = fx - cxp;
                                int ci = (int)((dxp * dxp + rowR2) * coneScale); if (ci > CONE_N - 1) ci = CONE_N - 1;
                                int wi = (int)(w * (1f / DIST_STEP)); if (wi > DIST_N - 1) wi = DIST_N - 1; else if (wi < 0) wi = 0;
                                float lampF = coneTab[ci] * distTab[wi], baseK = 1f;
                                if (smap != null && mid == 0)       // a reflection is not where its pixels say it is: no shadow lookup
                                {
                                    float su = ((fx - cx0) * invFpx - sOx * iz) * sF + sHalfX;
                                    float sv = sHalfY - (rowTy - sOy * iz) * sF;
                                    {
                                        // 1/z: a bigger number in the map means the lamp saw something NEARER
                                        float lim = iz * sBias;
                                        float o1 = ShadowSoftAt(smap, sW, sH, su, sv, lim, sSoft);
                                        float occl;
                                        if (smap2 == null) occl = o1 < 0f ? 0f : o1;
                                        else
                                        {
                                            // the mirror lamp: its own place in its own map; outside its map it sees everything
                                            float su2 = ((fx - cx0) * invFpx - s2Ox * iz) * sF + sHalfX;
                                            float sv2 = sHalfY - (rowTy - s2Oy * iz) * sF;
                                            float o2 = ShadowSoftAt(smap2, sW, sH, su2, sv2, lim, sSoft);
                                            occl = 0.5f * ((o1 < 0f ? 0f : o1) + (o2 < 0f ? 0f : o2));
                                        }
                                        if (occl > 0f)
                                        {
                                            occl *= sfadeTab[wi];              // thinner with distance from the player
                                            lampF *= 1f - occl;                // the lamp does not reach
                                            baseK = 1f - sDark * occl;         // and the shadow is darker than the room
                                        }
                                    }
                                }
                                if (rgbOn) gainF = (lampRoomL * baseK + (smoothOn ? (l0 * f0q + l1 * f1q + l2 * f2q) : triLampRaw) * lampF) * dimK;
                                else
                                {
                                    int lvl = (int)((lampBase * baseK + triLamp * lampF) * dimK + bayer[by4 | (x & 3)]);
                                    if (lvl >= lightLevels) lvl = lightLevels - 1;
                                    ink = lightTab[(lvl << 8) | ink];
                                }
                            }
                            else if (rgbOn) gainF = dimK;
                            else if (dimK < 1f && lightTab != null)
                            {
                                int lvl = (int)(dimK * lvlPlain + bayer[by4 | (x & 3)]);
                                ink = lightTab[(lvl << 8) | ink];
                            }

                            if (rgbOn)
                            {
                                // which copies: this face's texel density and this pixel's depth, blended
                                int wq2 = (int)(w * (1f / DIST_STEP)); if (wq2 > DIST_N - 1) wq2 = DIST_N - 1; else if (wq2 < 0) wq2 = 0;
                                float lodf = triLodQ + log2Tab[wq2];
                                int c32;
                                if (lodf <= 0f || maxR == 0) c32 = SampleBi(rl[0], uu, vv);
                                else
                                {
                                    int m0 = (int)lodf;
                                    if (m0 >= maxR) c32 = SampleBi(rl[maxR], uu, vv);
                                    else c32 = Mix(SampleBi(rl[m0], uu, vv), SampleBi(rl[m0 + 1], uu, vv), (uint)((lodf - m0) * 256f));
                                }
                                float gR = gainF, gG = gainF, gB = gainF;
                                if (nLights > 0)
                                {
                                    // this pixel in view space, from where it is on the screen and its depth
                                    float pxv = (fx - cx0) * invFpx * w, pyv = rowTy * w, pzv = w;
                                    for (int li = 0; li < nLights; li++)
                                    {
                                        int lb = li * 8;
                                        float ddx = lv[lb] - pxv, ddy = lv[lb + 1] - pyv, ddz = lv[lb + 2] - pzv;
                                        float d2 = ddx * ddx + ddy * ddy + ddz * ddz; if (d2 < 1f) d2 = 1f;
                                        float facing = (ddx * tnvx + ddy * tnvy + ddz * tnvz); if (facing < 0f) facing = -facing;
                                        float att = facing / ((float)Math.Sqrt(d2) * (1f + d2 * lv[lb + 6]));
                                        if (lsHas[li])
                                        {
                                            // from the light to this pixel, in the light view's own axes
                                            int ab = li * 9; float qx = -ddx, qy = -ddy, qz = -ddz;
                                            float lz2 = qx * lsv[ab + 6] + qy * lsv[ab + 7] + qz * lsv[ab + 8];
                                            if (lz2 > 0.5f)
                                            {
                                                int sz = lsSize[li]; float lf = lsFocal[li], halfS = sz * 0.5f, ilz = 1f / lz2;
                                                float su = (qx * lsv[ab] + qy * lsv[ab + 1] + qz * lsv[ab + 2]) * ilz * lf + halfS;
                                                float sv = halfS - (qx * lsv[ab + 3] + qy * lsv[ab + 4] + qz * lsv[ab + 5]) * ilz * lf;
                                                float ol = ShadowSoftAt(lsMap[li], sz, sz, su, sv, ilz * lsBias, sSoft);
                                                if (ol > 0f) att *= 1f - ol;
                                            }
                                        }
                                        gR += lv[lb + 3] * att; gG += lv[lb + 4] * att; gB += lv[lb + 5] * att;
                                    }
                                }
                                float fogF = 0f;
                                if (fogOn) { fogF = (w - fogNearL) * fogA; if (fogF < 0f) fogF = 0f; else if (fogF > 1f) fogF = 1f; fogF = fogF * fogF * (3f - 2f * fogF) * fogMaxL; }
                                if (gR != 1f || gG != 1f || gB != 1f || fogF > 0f)
                                {
                                    float rr = ((c32 >> 16) & 255) * gR, gg = ((c32 >> 8) & 255) * gG, bb = (c32 & 255) * gB;
                                    if (rr > 255f) rr = 255f; if (gg > 255f) gg = 255f; if (bb > 255f) bb = 255f;
                                    if (fogF > 0f) { rr += (fogR - rr) * fogF; gg += (fogG - gg) * fogF; bb += (fogB - bb) * fogF; }
                                    c32 = ((int)(rr + 0.5f) << 16) | ((int)(gg + 0.5f) << 8) | (int)(bb + 0.5f);
                                }
                                // a reflection: laid over the water's own colour, not dotted into it
                                if (mid != 0 && maskKeep > 0f && under32 != null) c32 = Mix(c32, under32[o], (uint)(maskKeep * 256f));
                                color32[o] = c32;
                            }

                            depth[o] = iz;
                            color[o] = ink;
                            any = true;
                            written++;
                        }
                    }
                    if (any) hit[pt[q].src] = 1;
                }
                px[band] = written;
            });

            for (int i = 0; i < bands; i++) PixelsWritten += px[i];
            long drawnTris = 0;
            for (int i = 0; i < nTri; i++) if (hit[i] != 0) drawnTris++;
            TrisDrawn += drawnTris;
        }
    }

    // ---- the per-frame doorway logic, in one place -----------------------------------
    // See Raster.BeginPortals for how a neighbour is drawn; this is WHICH doorways, WHEN.
    public class PortalView
    {
        public int Part;            // index into the room's parts table
        public int VFirst, VCount;  // its vertices
        public int[] Tris;          // its triangles (indices into the room's per-triangle arrays)
        public int[] TriVerts;      // the same triangles as vertex indices, three each
        public bool Hidden;         // currently replaced by the live view
        public bool Parked;         // kept below the floor until the far door changes state
        public bool Up;             // standing in the doorway this frame
    }

    public class Portal
    {
        public string Zone, To;
        public float DoorX, DoorY, DoorZ;       // the exit trigger: floor level at the doorway
        public PortalView[] Views;
        // the neighbouring room, already in THIS room's coordinates
        public float[] V, UV; public int[] T, TexIdx; public Raster.Tex[] Texes;
        public int Pixels;                      // how much of the last frame it filled
        public float[] FarQuad;                 // the far tunnel's mouth, 4 corners in order, this room's coordinates
        // The far room's own door at this doorway (triangles of the neighbour), and what they
        // are textured with when shown. See Portals.Prepare for when it is taken away.
        public int[] DoorTris = new int[0], DoorTex = new int[0];
        public bool DoorsHidden;
        public bool Live;                       // drawn as a live view this frame
    }

    public static class Portals
    {
        // p_out = p * m, row-vector, for a whole vertex buffer
        public static float[] Transform(float[] v, float[] m)
        {
            var r = new float[v.Length];
            for (int i = 0; i + 2 < v.Length; i += 3)
            {
                float x = v[i], y = v[i + 1], z = v[i + 2];
                r[i]     = x * m[0] + y * m[4] + z * m[8]  + m[12];
                r[i + 1] = x * m[1] + y * m[5] + z * m[9]  + m[13];
                r[i + 2] = x * m[2] + y * m[6] + z * m[10] + m[14];
            }
            return r;
        }

        // WHAT PART OF THE NEIGHBOUR BELONGS IN THE DOORWAY. The far room is placed with its
        // half of the tunnel butted against this room's, so all of it should lie beyond the
        // plane the two meet at. Anything of it wholly on THIS side of that plane (a picture
        // parked under its floor that the transform happens to carry back here, say) is
        // dropped once, at load. Triangles that straddle the plane are kept whole.
        public static int CullBehind(float[] v, int[] t, int[] texIdx, float px, float pz, float nx, float nz)
        {
            int cut = 0;
            for (int i = 0; i < texIdx.Length; i++)
            {
                if (texIdx[i] < 0) continue;
                bool any = false;
                for (int k = 0; k < 3; k++)
                {
                    int a = t[i * 3 + k];
                    if ((v[a * 3] - px) * nx + (v[a * 3 + 2] - pz) * nz >= 0f) { any = true; break; }
                }
                if (!any) { texIdx[i] = -1; cut++; }
            }
            return cut;
        }

        // BEFORE the room is drawn: decide which picture quads are standing in their doorway
        // right now, and take those out of the room's own draw. The game keeps a second picture
        // parked far below the floor and lifts it into the opening when a door opens (and can
        // move the first one away), so this is asked of the LIVE pose every frame, not once.
        // `vis` may be null (nothing is being posed: everything is where the file put it).
        public static int Prepare(Portal[] ps, float[] poseV, int[] curTex, int[] baseTex, bool[] vis)
        {
            int standing = 0;
            if (ps == null) return 0;
            for (int i = 0; i < ps.Length; i++)
            {
                Portal p = ps[i];
                bool anyUp = false, parkedUp = false;
                for (int k = 0; k < p.Views.Length; k++)
                {
                    PortalView w = p.Views[k];
                    bool here = vis == null || vis[w.Part];
                    bool up = false;
                    if (here && w.VCount > 0)
                    {
                        float y0 = float.MaxValue, y1 = float.MinValue, cx = 0, cz = 0;
                        int end = w.VFirst + w.VCount;
                        for (int v = w.VFirst; v < end; v++)
                        {
                            float y = poseV[v * 3 + 1];
                            if (y < y0) y0 = y; if (y > y1) y1 = y;
                            cx += poseV[v * 3]; cz += poseV[v * 3 + 2];
                        }
                        cx /= w.VCount; cz /= w.VCount;
                        float dx = cx - p.DoorX, dz = cz - p.DoorZ;
                        // foot near the floor, head above it, and still at this doorway
                        up = y0 < p.DoorY + 45f && y1 > p.DoorY + 25f && (dx * dx + dz * dz) < 260f * 260f;
                    }
                    w.Up = up;
                    if (up) { anyUp = true; if (w.Parked) parkedUp = true; }
                }

                // WHICH PICTURE THE GAME IS SHOWING SAYS WHAT STATE THE FAR DOOR IS IN. The one
                // that stands by default goes with the neighbour exactly as its file has it.
                // The parked one, once lifted, means the far door has changed -- almost always
                // "it has been opened". We can show that only by taking the far door away, so
                // if this doorway has no far door we know of, the lifted picture is showing
                // something the neighbour's file cannot, and it is left as the game drew it.
                bool live = anyUp && !(parkedUp && p.DoorTris.Length == 0);
                p.Live = live;
                bool hideDoors = live && parkedUp;
                if (hideDoors != p.DoorsHidden)
                {
                    for (int t = 0; t < p.DoorTris.Length; t++) p.TexIdx[p.DoorTris[t]] = hideDoors ? -1 : p.DoorTex[t];
                    p.DoorsHidden = hideDoors;
                }
                for (int k = 0; k < p.Views.Length; k++)
                {
                    PortalView w = p.Views[k];
                    bool here = vis == null || vis[w.Part];
                    if (live && w.Up)
                    {
                        for (int t = 0; t < w.Tris.Length; t++) curTex[w.Tris[t]] = -1;
                        w.Hidden = true; standing++;
                    }
                    else if (w.Hidden)
                    {
                        for (int t = 0; t < w.Tris.Length; t++) curTex[w.Tris[t]] = here ? baseTex[w.Tris[t]] : -1;
                        w.Hidden = false;
                    }
                }
            }
            return standing;
        }
        // Put every picture back (the portals are being switched off, or the room is going).
        public static void Restore(Portal[] ps, int[] curTex, int[] baseTex, bool[] vis)
        {
            if (ps == null) return;
            foreach (Portal p in ps)
                foreach (PortalView w in p.Views)
                {
                    if (!w.Hidden) continue;
                    bool here = vis == null || vis[w.Part];
                    for (int t = 0; t < w.Tris.Length; t++) curTex[w.Tris[t]] = here ? baseTex[w.Tris[t]] : -1;
                    w.Hidden = false;
                }
        }

        // AFTER the room is drawn. Returns the pixels filled through doorways this frame.
        public static int Draw(Raster r, Portal[] ps, float[] poseV, bool cull, bool flipV)
        {
            if (ps == null || ps.Length == 0) return 0;
            bool any = false;
            for (int i = 0; i < ps.Length && !any; i++) foreach (PortalView w in ps[i].Views) if (w.Hidden) { any = true; break; }
            if (!any) { for (int i = 0; i < ps.Length; i++) ps[i].Pixels = 0; return 0; }
            r.BeginPortals();
            int n = Math.Min(ps.Length, 254);
            for (int i = 0; i < n; i++)
                foreach (PortalView w in ps[i].Views)
                    if (w.Hidden) r.AddPortal(poseV, w.TriVerts, (byte)(i + 1));
            for (int i = 0; i < n; i++) if (ps[i].FarQuad != null) r.RestrictPortal(ps[i].FarQuad, (byte)(i + 1));
            r.EndPortals();
            int total = 0;
            for (int i = 0; i < n; i++)
            {
                // recount: a nearer aperture may have taken pixels this one claimed first, but
                // the claim is an upper bound and zero is still zero
                ps[i].Pixels = r.MaskCount[i + 1];
                if (ps[i].Pixels == 0) continue;
                r.DrawTexturedMasked(ps[i].V, ps[i].UV, ps[i].T, ps[i].TexIdx, ps[i].Texes, cull, flipV, (byte)(i + 1));
                total += ps[i].Pixels;
            }
            return total;
        }
    }
    // THE AFTER-EFFECTS, AS A JOB SOMEONE ELSE CAN RUN. The frame loop hands a finished picture
    // to the overlay and goes straight back to drawing the next one; the overlay's own thread
    // calls Run on it. A picture goes in, the finished picture comes out -- possibly in a
    // different buffer, in which case this keeps the one it was given as its next scratch.
    public class PostJob
    {
        public bool On = true, SmoothEdges = true; public float Sharpen = 0.5f;
        public int Threads = Environment.ProcessorCount;
        public double Ms; public long Runs;
        int[] _scratch;
        /// <summary>Run, as the delegate the overlay takes (PowerShell cannot spell the type).</summary>
        public Func<int[], int, int, int[]> AsHook() { return Run; }
        /// <summary>Run on another thread (for measuring how the effects and the draw share the processor).</summary>
        public Task RunAsync(int[] src, int w, int h) { return Task.Run(() => { Run(src, w, h); }); }
        public int[] Run(int[] src, int w, int h)
        {
            if (!On || (!SmoothEdges && Sharpen <= 0f)) return src;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            if (_scratch == null || _scratch.Length != src.Length) _scratch = new int[src.Length];
            int[] res = Raster.PostCore(src, _scratch, w, h, SmoothEdges, Sharpen, Threads);
            if (res != src) _scratch = src;
            Ms += sw.Elapsed.TotalMilliseconds; Runs++;
            return res;
        }
    }
}