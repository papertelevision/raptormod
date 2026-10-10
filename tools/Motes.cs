// Motes.cs -- dust floating in the air, drawn by the host renderer after the scene.
//
// A cloud of tiny specks drifting slowly in the space around the player. They are the one
// thing in the picture that is not a surface: each is a soft dot a pixel or two across, drawn
// where the depth buffer says nothing is in front of it, and lit the way a surface at that
// place would be -- so they mostly show up where the flashlight's beam is, which is what dust
// in a torch beam does. Dust lives in a sphere around the player (respawned when it drifts out
// or the player walks away), kept inside the room's own bounds so none hangs outside the walls.
using System;

namespace AztTool
{
    public class Motes
    {
        public int Count;
        public float[] P, Vel, Phase;      // world position, drift, and a per-mote wander phase
        public float Radius = 350f;        // how far around the player dust exists
        public float Drift = 6f;           // units per second of slow drift
        public float Size = 1.4f;          // world size of the LARGEST mote (a disc of this radius at depth)
        public float SizeMin = 0.3f;       // the smallest, as a share of Size; motes are spread between the two
        float[] _sz;                        // each mote's own size share
        public float Brightness = 1.0f;    // overall strength
        public int Color = 0xD8C8B0;       // warm grey, before lighting
        // FLASHLIGHT OFF: the dust does not vanish, it turns to dull grey-brown specks hanging in
        // the dark -- laid OVER the picture (a mix toward ColorDark) rather than adding light,
        // since there is no beam to catch them. LampLevel (0 off .. 1 on, the lamp's own fade)
        // blends between the two looks, so switching the lamp eases from one to the other.
        public int ColorDark = 0x6E5E4C;   // grey-brown
        public float DarkAlpha = 0.45f;    // how solid the largest dark speck is
        public float LampLevel = 1f;
        public float Floor = -1e9f, Ceiling = 1e9f, MinX = -1e9f, MaxX = 1e9f, MinZ = -1e9f, MaxZ = 1e9f;
        Random _rnd = new Random(7); float _t;

        public Motes(int count) { Count = count; P = new float[count * 3]; Vel = new float[count * 3]; Phase = new float[count]; _sz = new float[count]; for (int i = 0; i < count; i++) Phase[i] = (float)(_rnd.NextDouble() * 6.2832); }

        public void SetBounds(float minX, float maxX, float minY, float maxY, float minZ, float maxZ)
        { MinX = minX; MaxX = maxX; Floor = minY; Ceiling = maxY; MinZ = minZ; MaxZ = maxZ; }

        void Spawn(int i, float cx, float cy, float cz)
        {
            // somewhere in the sphere round the player, inside the room's box
            for (int tries = 0; tries < 8; tries++)
            {
                double u = _rnd.NextDouble() * 2 - 1, th = _rnd.NextDouble() * 6.2832, r = Radius * Math.Pow(_rnd.NextDouble(), 1.0 / 3);
                double s = Math.Sqrt(1 - u * u);
                float x = (float)(cx + r * s * Math.Cos(th)), y = (float)(cy + r * u * 0.5), z = (float)(cz + r * s * Math.Sin(th));
                if (x < MinX || x > MaxX || y < Floor || y > Ceiling || z < MinZ || z > MaxZ) continue;
                P[i * 3] = x; P[i * 3 + 1] = y; P[i * 3 + 2] = z;
                // more small ones than large: the square of a uniform draw
                double sr = _rnd.NextDouble(); _sz[i] = (float)(SizeMin + (1 - SizeMin) * sr * sr);
                Vel[i * 3] = (float)((_rnd.NextDouble() - 0.5) * Drift); Vel[i * 3 + 1] = (float)((_rnd.NextDouble() - 0.5) * Drift * 0.5); Vel[i * 3 + 2] = (float)((_rnd.NextDouble() - 0.5) * Drift);
                return;
            }
            P[i * 3] = cx; P[i * 3 + 1] = cy; P[i * 3 + 2] = cz;
        }

        public void Reset() { for (int i = 0; i < Count; i++) P[i * 3 + 1] = float.NaN; }

        public void Update(float dt, float cx, float cy, float cz)
        {
            _t += dt; float r2 = Radius * Radius * 1.3f;
            for (int i = 0; i < Count; i++)
            {
                int o = i * 3;
                if (float.IsNaN(P[o + 1])) { Spawn(i, cx, cy, cz); continue; }
                // a slow wander on top of the drift
                float ph = Phase[i] + _t * 0.7f;
                P[o] += (Vel[o] + (float)Math.Sin(ph) * Drift * 0.4f) * dt;
                P[o + 1] += (Vel[o + 1] + (float)Math.Cos(ph * 1.3f) * Drift * 0.2f) * dt;
                P[o + 2] += (Vel[o + 2] + (float)Math.Sin(ph * 0.8f + 1.7f) * Drift * 0.4f) * dt;
                float dx = P[o] - cx, dy = P[o + 1] - cy, dz = P[o + 2] - cz;
                if (dx * dx + dy * dy + dz * dz > r2 || P[o + 1] < Floor || P[o + 1] > Ceiling) Spawn(i, cx, cy, cz);
            }
        }

        /// <summary>For the graphics card (GpuRaster.SetMotes): everything Draw works out per mote,
        /// without drawing -- 6 floats each into `dst`: screen x, y, depth, radius in pixels, beam
        /// strength (adds Color), dark strength (mixes toward ColorDark). `r` supplies the camera
        /// and the lamp, as for Draw. Whether something is in front is left to the card's own
        /// depth test, pixel by pixel. Returns how many motes were written.</summary>
        public int Gather(Raster r, float[] dst)
        {
            if (dst == null) return 0;
            int W = r.W, H = r.H, n = 0, cap = dst.Length / 6; float fpx = r.FocalPx, cx0 = W * 0.5f, cy0 = r.CentreY;
            float roomL = r.LampRoom * 0.12f;
            float on = LampLevel < 0f ? 0f : (LampLevel > 1f ? 1f : LampLevel), off = 1f - on;
            bool fog = r.Fog32; float fN = r.Fog32Near, fSpan = Math.Max(1f, r.Fog32Far - r.Fog32Near), fMax = r.Fog32Max;
            for (int i = 0; i < Count && n < cap; i++)
            {
                int o = i * 3; if (float.IsNaN(P[o + 1])) continue;
                float[] v = r.ViewPoint(P[o], P[o + 1], P[o + 2]);
                float z = v[2]; if (z < 2f) continue;
                float iz = 1f / z;
                float sx = cx0 + v[0] * fpx * iz, sy = cy0 - v[1] * fpx * iz;
                if (sx < 1 || sy < 1 || sx >= W - 1 || sy >= H - 1) continue;
                float lit = on > 0f ? roomL + r.LampAt(sx, sy, z) * 0.9f : 0f;
                float szk = _sz[i] > 0f ? _sz[i] : 1f;
                float sizeK = 0.45f + 0.55f * szk;
                float keep = 1f;
                if (fog && z > fN) { float f = (z - fN) / fSpan; if (f > 1f) f = 1f; keep = 1f - f * fMax; }
                float a = lit * Brightness * sizeK * on * keep; if (a > 1f) a = 1f;
                float m = DarkAlpha * Brightness * sizeK * off * keep; if (m > 1f) m = 1f;
                if (a < 0.02f && m < 0.02f) continue;
                float rad = Size * szk * fpx * iz; if (rad < 0.8f) rad = 0.8f; if (rad > 4f) rad = 4f;
                int q = n * 6;
                dst[q] = sx; dst[q + 1] = sy; dst[q + 2] = z; dst[q + 3] = rad; dst[q + 4] = a; dst[q + 5] = m;
                n++;
            }
            return n;
        }

        /// <summary>Draw into the raster's true-colour picture, in front of the scene's depth.</summary>
        public int Draw(Raster r)
        {
            if (r.Color32 == null || !r.Rgb) return 0;
            int W = r.W, H = r.H; float fpx = r.FocalPx, cx0 = W * 0.5f, cy0 = r.CentreY;
            int[] c32 = r.Color32; float[] depth = r.Depth; int drawn = 0;
            float roomL = r.LampRoom * 0.12f;
            int cr = (Color >> 16) & 255, cg = (Color >> 8) & 255, cb = Color & 255;
            int dr = (ColorDark >> 16) & 255, dg = (ColorDark >> 8) & 255, db = ColorDark & 255;
            float on = LampLevel < 0f ? 0f : (LampLevel > 1f ? 1f : LampLevel), off = 1f - on;
            bool fog = r.Fog32; float fN = r.Fog32Near, fSpan = Math.Max(1f, r.Fog32Far - r.Fog32Near), fMax = r.Fog32Max;
            for (int i = 0; i < Count; i++)
            {
                int o = i * 3; if (float.IsNaN(P[o + 1])) continue;
                float[] v = r.ViewPoint(P[o], P[o + 1], P[o + 2]);
                float z = v[2]; if (z < 2f) continue;
                float iz = 1f / z;
                float sx = cx0 + v[0] * fpx * iz, sy = cy0 - v[1] * fpx * iz;
                if (sx < 1 || sy < 1 || sx >= W - 1 || sy >= H - 1) continue;
                int px = (int)sx, py = (int)sy, oo = py * W + px;
                if (depth[oo] > iz) continue;                               // something is in front
                // lit like a surface here would be: the room's level plus the lamp's beam
                float lit = on > 0f ? roomL + r.LampAt(sx, sy, z) * 0.9f : 0f;
                float szk = _sz[i] > 0f ? _sz[i] : 1f;
                float sizeK = 0.45f + 0.55f * szk;
                // the far ones sink into the fog like everything else
                float keep = 1f;
                if (fog && z > fN) { float f = (z - fN) / fSpan; if (f > 1f) f = 1f; keep = 1f - f * fMax; }
                float a = lit * Brightness * sizeK * on * keep; if (a > 1f) a = 1f;      // the beam's look: adds light
                float m = DarkAlpha * Brightness * sizeK * off * keep; if (m > 1f) m = 1f;   // the dark look: grey-brown over the picture
                if (a < 0.02f && m < 0.02f) continue;
                float rad = Size * szk * fpx * iz; if (rad < 0.8f) rad = 0.8f; if (rad > 4f) rad = 4f;
                int ir = (int)Math.Ceiling(rad);
                for (int yy = -ir; yy <= ir; yy++)
                {
                    int ty = py + yy; if (ty < 0 || ty >= H) continue;
                    for (int xx = -ir; xx <= ir; xx++)
                    {
                        int tx = px + xx; if (tx < 0 || tx >= W) continue;
                        float d = (float)Math.Sqrt(xx * xx + yy * yy) / rad; if (d > 1f) continue;
                        float fall = 1f - d * d, k = a * fall, km = m * fall;
                        int to = ty * W + tx; if (depth[to] > iz) continue;
                        int c = c32[to];
                        float r0 = (c >> 16) & 255, g0 = (c >> 8) & 255, b0 = c & 255;
                        r0 += (dr - r0) * km; g0 += (dg - g0) * km; b0 += (db - b0) * km;
                        int rr = (int)(r0 + cr * k), gg = (int)(g0 + cg * k), bb = (int)(b0 + cb * k);
                        if (rr > 255) rr = 255; if (gg > 255) gg = 255; if (bb > 255) bb = 255;
                        c32[to] = (rr << 16) | (gg << 8) | bb;
                    }
                }
                drawn++;
            }
            return drawn;
        }
    }
}
