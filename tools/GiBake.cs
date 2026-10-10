// GiBake.cs -- BOUNCED LIGHT, worked out once per room (Josh, 2026-10-09: "Bounced light (global illumination),
// pre-calculated per room ... I really want to start with this one").
//
// A 3D grid of light probes fills the room's box (one every Spacing units). Each probe sends rays out into the room
// (a BVH over the room's triangles); where a ray lands, the surface's colour (its texture there) times the light reaching
// it -- the placed lights, each tested for shadow, plus (from the second bounce on) the bounced light the grid already
// holds at that spot -- is what that ray brings back. Each probe keeps it as an L1 spherical harmonic per colour (the light
// arriving from every direction, in 12 numbers), so the card can give any surface, of any facing, the light bounced onto
// it: GpuRaster.SetGi, FS_MAIN's giAt. Probes that see the BACKS of walls are inside a wall or outside the room, and are
// marked invalid (that is what keeps light from leaking through walls). The room's moving things (characters) are left
// out of the bake; they are lit by it all the same.
//
// The processor does it (any thread, no OpenGL): the watcher bakes in the background and caches the result in a file
// named by a signature of everything that went in (geometry, textures' colours, lights, settings).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace AztTool
{
    public class GiBake
    {
        // ---- inputs ------------------------------------------------------------------------------------------
        public class Light { public float X, Y, Z, R, G, B, Range = 250f, DX, DY = -1f, DZ, CosIn = 2f, CosOut = -2f; public bool Shadow = true; }
        public readonly List<Light> Lights = new List<Light>();
        public float Spacing = 20f;          // world units between probes
        public int Rays = 64;                // rays per probe per bounce
        public int Bounces = 3;
        public float SkyR, SkyG, SkyB;       // what a ray that leaves the room brings back (underground: nothing)
        public int MaxProbes = 600000;       // the spacing grows if the room would need more
        public float Albedo = 1f;            // a multiplier on every surface's colour (how much light the room gives back)
        public float MaxAlbedo = 0.9f;

        // ---- outputs -----------------------------------------------------------------------------------------
        public int NX, NY, NZ; public float X0, Y0, Z0;
        public float[] SH;                   // per probe: R(c00, c1x, c1y, c1z), G(...), B(...) = 12 floats
        public byte[] Valid;                 // per probe: 1 = in the room
        public int ValidCount; public double Ms; public string Note = ""; public volatile bool Done; public string Error;
        public string Signature;

        // ---- the room ----------------------------------------------------------------------------------------
        float[] _v; int[] _t; int _nt;               // triangles kept (indices into _v)
        int[] _tTex; float[] _uv; Raster.Tex[] _texes; bool _flipV;
        int[] _tri;                                   // kept triangle -> source triangle index (3 vertex ids in _t)

        /// <summary>Take the room as it will be drawn: vertices, uvs, indices, per-triangle texture, textures (their
        /// colours loaded); textures that move (characters) are left out.</summary>
        public void SetRoom(float[] vx, float[] uv, int[] idx, int[] triTex, Raster.Tex[] texes, bool flipV)
        {
            _v = vx; _uv = uv; _texes = texes; _flipV = flipV;
            var keep = new List<int>();
            for (int t = 0; t + 2 < idx.Length; t += 3)
            {
                int ti = triTex != null && t / 3 < triTex.Length ? triTex[t / 3] : -1;
                if (ti >= 0 && texes != null && ti < texes.Length && texes[ti] != null && (texes[ti].Moves || texes[ti].NoCast)) continue;      // (what moves, and what casts no shadow, stops no light here either)
                keep.Add(t / 3);
            }
            _nt = keep.Count; _t = new int[_nt * 3]; _tTex = new int[_nt]; _tri = keep.ToArray();
            for (int k = 0; k < _nt; k++) { int s = keep[k] * 3; _t[k * 3] = idx[s]; _t[k * 3 + 1] = idx[s + 1]; _t[k * 3 + 2] = idx[s + 2]; _tTex[k] = triTex != null && keep[k] < triTex.Length ? triTex[keep[k]] : -1; }
            _uvIdx = idx;
            // textures with holes (palette index 0): a ray passes through those texels, as the picture shows through them
            _holeTri = new bool[_nt]; var hasHole = new Dictionary<int, bool>();
            for (int k = 0; k < _nt; k++)
            {
                int ti = _tTex[k]; if (texes == null || ti < 0 || ti >= texes.Length || texes[ti] == null || texes[ti].Idx == null) continue;
                bool hh; if (!hasHole.TryGetValue(ti, out hh)) { hh = Array.IndexOf(texes[ti].Idx, (byte)0) >= 0; hasHole[ti] = hh; }
                _holeTri[k] = hh;
            }
        }
        bool[] _holeTri;
        bool IsHole(int k, float bu, float bv)
        {
            var tx = _texes[_tTex[k]];
            int s = _tri[k] * 3, a = _uvIdx[s], b = _uvIdx[s + 1], c = _uvIdx[s + 2];
            float su = _uv[a * 2] + (_uv[b * 2] - _uv[a * 2]) * bu + (_uv[c * 2] - _uv[a * 2]) * bv;
            float sv = _uv[a * 2 + 1] + (_uv[b * 2 + 1] - _uv[a * 2 + 1]) * bu + (_uv[c * 2 + 1] - _uv[a * 2 + 1]) * bv;
            if (_flipV) sv = 1 - sv; su -= (float)Math.Floor(su); sv -= (float)Math.Floor(sv);
            return tx.Idx[Math.Min(tx.H - 1, (int)(sv * tx.H)) * tx.W + Math.Min(tx.W - 1, (int)(su * tx.W))] == 0;
        }
        int[] _uvIdx;

        // ---- the signature: everything that changes the result --------------------------------------------------
        public string MakeSignature()
        {
            ulong h = 1469598103934665603UL;
            Action<ulong> Mix = x => { h ^= x; h *= 1099511628211UL; };
            Mix((ulong)_v.Length); Mix((ulong)_nt);
            for (int i = 0; i < _v.Length; i += 7) Mix((ulong)BitConverter.ToUInt32(BitConverter.GetBytes(_v[i]), 0));
            for (int i = 0; i < _t.Length; i += 5) Mix((ulong)_t[i]);
            if (_texes != null) foreach (var tx in _texes)
                {
                    if (tx != null) { Mix(tx.NoCast ? 3UL : 5UL); if (tx.IdxOrig != null) { ulong hz = 0; foreach (var b in tx.Idx) if (b == 0) hz++; Mix(hz); } }      // (holes cut, and what casts no shadow, change the light)
                    if (tx == null || tx.Rgb == null || tx.Rgb.Length == 0) { Mix(7); continue; }
                    var lv = tx.Rgb[tx.Rgb.Length - 1]; Mix((ulong)tx.Rgb[0].W); Mix((ulong)(uint)lv.Px[0]);
                    if (tx.Rgb.Length > 3) { var l3 = tx.Rgb[tx.Rgb.Length - 4]; for (int i = 0; i < l3.Px.Length; i += 3) Mix((ulong)(uint)l3.Px[i]); }
                }
            foreach (var l in Lights) foreach (float f in new[] { l.X, l.Y, l.Z, l.R, l.G, l.B, l.Range, l.DX, l.DY, l.DZ, l.CosIn, l.CosOut, l.Shadow ? 1f : 0f }) Mix((ulong)BitConverter.ToUInt32(BitConverter.GetBytes(f), 0));
            foreach (float f in new[] { Spacing, (float)Rays, (float)Bounces, SkyR, SkyG, SkyB, Albedo, (float)MaxEscape, MaxAlbedo, 6f /* format */ }) Mix((ulong)BitConverter.ToUInt32(BitConverter.GetBytes(f), 0));
            Signature = h.ToString("x16"); return Signature;
        }

        // ---- the BVH -----------------------------------------------------------------------------------------
        float[] _bmin, _bmax; int[] _left, _right, _first, _count; int[] _order; int _nodes;
        float[] _tv;      // per kept triangle: v0 (3), e1 (3), e2 (3), normal (3)
        void BuildBvh()
        {
            _tv = new float[_nt * 12]; var cent = new float[_nt * 3]; var tmin = new float[_nt * 3]; var tmax = new float[_nt * 3];
            for (int k = 0; k < _nt; k++)
            {
                int a = _t[k * 3], b = _t[k * 3 + 1], c = _t[k * 3 + 2];
                for (int d = 0; d < 3; d++)
                {
                    float pa = _v[a * 3 + d], pb = _v[b * 3 + d], pc = _v[c * 3 + d];
                    _tv[k * 12 + d] = pa; _tv[k * 12 + 3 + d] = pb - pa; _tv[k * 12 + 6 + d] = pc - pa;
                    tmin[k * 3 + d] = Math.Min(pa, Math.Min(pb, pc)); tmax[k * 3 + d] = Math.Max(pa, Math.Max(pb, pc)); cent[k * 3 + d] = (pa + pb + pc) / 3f;
                }
                float e1x = _tv[k * 12 + 3], e1y = _tv[k * 12 + 4], e1z = _tv[k * 12 + 5], e2x = _tv[k * 12 + 6], e2y = _tv[k * 12 + 7], e2z = _tv[k * 12 + 8];
                float nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x, nl = (float)Math.Sqrt(nx * nx + ny * ny + nz * nz);
                if (nl > 1e-12f) { nx /= nl; ny /= nl; nz /= nl; }
                _tv[k * 12 + 9] = nx; _tv[k * 12 + 10] = ny; _tv[k * 12 + 11] = nz;
            }
            int cap = Math.Max(1, 2 * _nt); _bmin = new float[cap * 3]; _bmax = new float[cap * 3]; _left = new int[cap]; _right = new int[cap]; _first = new int[cap]; _count = new int[cap];
            _order = new int[_nt]; for (int i = 0; i < _nt; i++) _order[i] = i; _nodes = 0;
            Build(0, _nt, cent, tmin, tmax);
        }
        int Build(int lo, int hi, float[] cent, float[] tmin, float[] tmax)
        {
            int n = _nodes++;
            float[] mn = { float.MaxValue, float.MaxValue, float.MaxValue }, mx = { float.MinValue, float.MinValue, float.MinValue };
            float[] cmn = { float.MaxValue, float.MaxValue, float.MaxValue }, cmx = { float.MinValue, float.MinValue, float.MinValue };
            for (int i = lo; i < hi; i++)
            {
                int k = _order[i];
                for (int d = 0; d < 3; d++) { mn[d] = Math.Min(mn[d], tmin[k * 3 + d]); mx[d] = Math.Max(mx[d], tmax[k * 3 + d]); cmn[d] = Math.Min(cmn[d], cent[k * 3 + d]); cmx[d] = Math.Max(cmx[d], cent[k * 3 + d]); }
            }
            for (int d = 0; d < 3; d++) { _bmin[n * 3 + d] = mn[d]; _bmax[n * 3 + d] = mx[d]; }
            if (hi - lo <= 4) { _first[n] = lo; _count[n] = hi - lo; _left[n] = _right[n] = -1; return n; }
            int ax = 0; float ext = cmx[0] - cmn[0]; for (int d = 1; d < 3; d++) if (cmx[d] - cmn[d] > ext) { ext = cmx[d] - cmn[d]; ax = d; }
            if (ext <= 0) { _first[n] = lo; _count[n] = hi - lo; _left[n] = _right[n] = -1; return n; }
            // split at the middle of the centroids' extent (the order partitioned round it)
            float mid = (cmn[ax] + cmx[ax]) * 0.5f; int i0 = lo, i1 = hi - 1;
            while (i0 <= i1) { if (cent[_order[i0] * 3 + ax] < mid) i0++; else { int tt = _order[i0]; _order[i0] = _order[i1]; _order[i1] = tt; i1--; } }
            int m = i0; if (m == lo || m == hi) m = (lo + hi) / 2;
            _count[n] = 0;
            _left[n] = Build(lo, m, cent, tmin, tmax); _right[n] = Build(m, hi, cent, tmin, tmax);
            return n;
        }
        static bool Box(float[] mn, float[] mx, int n, float ox, float oy, float oz, float ix, float iy, float iz, float tmax)
        {
            float t0 = 0, t1 = tmax, a, b;
            a = (mn[n * 3] - ox) * ix; b = (mx[n * 3] - ox) * ix; if (a > b) { float s = a; a = b; b = s; } t0 = Math.Max(t0, a); t1 = Math.Min(t1, b);
            a = (mn[n * 3 + 1] - oy) * iy; b = (mx[n * 3 + 1] - oy) * iy; if (a > b) { float s = a; a = b; b = s; } t0 = Math.Max(t0, a); t1 = Math.Min(t1, b);
            a = (mn[n * 3 + 2] - oz) * iz; b = (mx[n * 3 + 2] - oz) * iz; if (a > b) { float s = a; a = b; b = s; } t0 = Math.Max(t0, a); t1 = Math.Min(t1, b);
            return t0 <= t1;
        }
        /// <summary>The nearest hit: triangle (kept index), t, barycentrics; -1 = none.</summary>
        int Trace(float ox, float oy, float oz, float dx, float dy, float dz, float tmax, out float tHit, out float bu, out float bv, int[] stack)
        {
            float ix = 1f / (Math.Abs(dx) > 1e-12f ? dx : 1e-12f), iy = 1f / (Math.Abs(dy) > 1e-12f ? dy : 1e-12f), iz = 1f / (Math.Abs(dz) > 1e-12f ? dz : 1e-12f);
            int sp = 0, best = -1; tHit = tmax; bu = bv = 0; stack[sp++] = 0;
            while (sp > 0)
            {
                int n = stack[--sp];
                if (!Box(_bmin, _bmax, n, ox, oy, oz, ix, iy, iz, tHit)) continue;
                if (_left[n] < 0)
                {
                    for (int i = _first[n]; i < _first[n] + _count[n]; i++)
                    {
                        int k = _order[i], o = k * 12;
                        float e1x = _tv[o + 3], e1y = _tv[o + 4], e1z = _tv[o + 5], e2x = _tv[o + 6], e2y = _tv[o + 7], e2z = _tv[o + 8];
                        float px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
                        float det = e1x * px + e1y * py + e1z * pz; if (Math.Abs(det) < 1e-12f) continue;
                        float inv = 1f / det, sx = ox - _tv[o], sy = oy - _tv[o + 1], sz = oz - _tv[o + 2];
                        float u = (sx * px + sy * py + sz * pz) * inv; if (u < 0 || u > 1) continue;
                        float qx = sy * e1z - sz * e1y, qy = sz * e1x - sx * e1z, qz = sx * e1y - sy * e1x;
                        float v = (dx * qx + dy * qy + dz * qz) * inv; if (v < 0 || u + v > 1) continue;
                        float t = (e2x * qx + e2y * qy + e2z * qz) * inv;
                        if (t > 1e-3f && t < tHit && !(_holeTri[k] && IsHole(k, u, v))) { tHit = t; best = k; bu = u; bv = v; }
                    }
                }
                else { stack[sp++] = _left[n]; stack[sp++] = _right[n]; }
            }
            return best;
        }
        bool Occluded(float ox, float oy, float oz, float dx, float dy, float dz, float tmax, int[] stack)
        {
            float t, u, v; return Trace(ox, oy, oz, dx, dy, dz, tmax, out t, out u, out v, stack) >= 0;
        }

        // ---- a surface's colour where a ray lands ----------------------------------------------------------------
        void SurfaceColour(int k, float bu, float bv, out float r, out float g, out float b)
        {
            r = g = b = 0.5f;
            int ti = _tTex[k]; if (_texes == null || ti < 0 || ti >= _texes.Length || _texes[ti] == null) { r *= Albedo; g *= Albedo; b *= Albedo; return; }
            var tx = _texes[ti]; if (tx.Rgb == null || tx.Rgb.Length == 0) { r *= Albedo; g *= Albedo; b *= Albedo; return; }
            int lv = 0; while (lv + 1 < tx.Rgb.Length && tx.Rgb[lv].W > 64) lv++;
            var L = tx.Rgb[lv];
            int s = _tri[k] * 3, a = _uvIdx[s], bb = _uvIdx[s + 1], c = _uvIdx[s + 2];
            float su = _uv[a * 2] + (_uv[bb * 2] - _uv[a * 2]) * bu + (_uv[c * 2] - _uv[a * 2]) * bv;
            float sv = _uv[a * 2 + 1] + (_uv[bb * 2 + 1] - _uv[a * 2 + 1]) * bu + (_uv[c * 2 + 1] - _uv[a * 2 + 1]) * bv;
            if (_flipV) sv = 1 - sv; su -= (float)Math.Floor(su); sv -= (float)Math.Floor(sv);
            int px = L.Px[Math.Min(L.H - 1, (int)(sv * L.H)) * L.W + Math.Min(L.W - 1, (int)(su * L.W))];
            r = Math.Min(MaxAlbedo, ((px >> 16) & 255) / 255f * Albedo); g = Math.Min(MaxAlbedo, ((px >> 8) & 255) / 255f * Albedo); b = Math.Min(MaxAlbedo, (px & 255) / 255f * Albedo);      // (no surface gives back more than MaxAlbedo)
        }

        // ---- the light reaching a point directly (the placed lights, each tested for shadow) ---------------------
        void Direct(float px, float py, float pz, float nx, float ny, float nz, int[] stack, out float r, out float g, out float b)
        {
            r = g = b = 0;
            foreach (var l in Lights)
            {
                float dx = l.X - px, dy = l.Y - py, dz = l.Z - pz, d2 = Math.Max(dx * dx + dy * dy + dz * dz, 1f), d = (float)Math.Sqrt(d2);
                dx /= d; dy /= d; dz /= d;
                float cs = dx * nx + dy * ny + dz * nz; if (cs <= 0) continue;
                // as FS_MAIN: facing / (1 + d^2 / range^2), and a spotlight's cone
                float att = cs / (1f + d2 / Math.Max(1f, l.Range * l.Range));
                if (l.CosOut > -1.5f)
                {
                    float c = -(dx * l.DX + dy * l.DY + dz * l.DZ), w = Math.Max(1e-3f, l.CosIn - l.CosOut), tt = Math.Max(0f, Math.Min(1f, (c - l.CosOut) / w));
                    att *= tt * tt * (3 - 2 * tt);
                }
                if (att <= 1e-5f) continue;
                if (l.Shadow && Occluded(px + nx * 0.5f, py + ny * 0.5f, pz + nz * 0.5f, dx, dy, dz, d - 1f, stack)) continue;
                r += l.R * att; g += l.G * att; b += l.B * att;
            }
        }

        // ---- the grid: the bounced light at a point with a normal (as FS_MAIN's giAt) ----------------------------
        public void Irradiance(float[] sh, float px, float py, float pz, float nx, float ny, float nz, out float r, out float g, out float b)
        {
            r = g = b = 0;
            float qx = (px + nx * Spacing * 0.3f - X0) / Spacing, qy = (py + ny * Spacing * 0.3f - Y0) / Spacing, qz = (pz + nz * Spacing * 0.3f - Z0) / Spacing;
            int bx = (int)Math.Floor(qx), by = (int)Math.Floor(qy), bz = (int)Math.Floor(qz); float fx = qx - bx, fy = qy - by, fz = qz - bz;
            float ws = 0;
            for (int i = 0; i < 8; i++)
            {
                int ox = i & 1, oy = (i >> 1) & 1, oz = i >> 2, cx = bx + ox, cy = by + oy, cz = bz + oz;
                if (cx < 0 || cy < 0 || cz < 0 || cx >= NX || cy >= NY || cz >= NZ) continue;
                int p = (cz * NY + cy) * NX + cx; if (Valid[p] == 0) continue;
                float w = (ox == 1 ? fx : 1 - fx) * (oy == 1 ? fy : 1 - fy) * (oz == 1 ? fz : 1 - fz);
                float dx = X0 + cx * Spacing - px, dy = Y0 + cy * Spacing - py, dz = Z0 + cz * Spacing - pz, dl = (float)Math.Sqrt(dx * dx + dy * dy + dz * dz) + 1e-4f;
                float bw = ((dx * nx + dy * ny + dz * nz) / dl + 1f) * 0.5f; w *= bw * bw + 0.05f;
                int o = p * 12;
                r += w * Math.Max(0f, sh[o] * 0.282095f + 0.325735f * (sh[o + 1] * nx + sh[o + 2] * ny + sh[o + 3] * nz));
                g += w * Math.Max(0f, sh[o + 4] * 0.282095f + 0.325735f * (sh[o + 5] * nx + sh[o + 6] * ny + sh[o + 7] * nz));
                b += w * Math.Max(0f, sh[o + 8] * 0.282095f + 0.325735f * (sh[o + 9] * nx + sh[o + 10] * ny + sh[o + 11] * nz));
                ws += w;
            }
            if (ws > 1e-4f) { r /= ws; g /= ws; b /= ws; } else { r = g = b = 0; }
        }

        /// <summary>For measuring (after Run): at each kept triangle's middle, both faces -- the bounced light (the grid), the
        /// direct light and the surface's colour, as luminances: 3 floats per face, the brighter-lit face of the two.</summary>
        public float[] SurfaceStats()
        {
            var st = new int[256]; var res = new float[_nt * 3];
            for (int k = 0; k < _nt; k++)
            {
                int o = k * 12; float cx = _tv[o] + (_tv[o + 3] + _tv[o + 6]) / 3f, cy = _tv[o + 1] + (_tv[o + 4] + _tv[o + 7]) / 3f, cz = _tv[o + 2] + (_tv[o + 5] + _tv[o + 8]) / 3f;
                float best = -1;
                for (int sd = -1; sd <= 1; sd += 2)
                {
                    float nx = _tv[o + 9] * sd, ny = _tv[o + 10] * sd, nz = _tv[o + 11] * sd, er, eg, eb, dr, dg, db, ar, ag, ab;
                    Irradiance(SH, cx + nx * 0.5f, cy + ny * 0.5f, cz + nz * 0.5f, nx, ny, nz, out er, out eg, out eb);
                    Direct(cx + nx * 0.5f, cy + ny * 0.5f, cz + nz * 0.5f, nx, ny, nz, st, out dr, out dg, out db);
                    SurfaceColour(k, 1f / 3, 1f / 3, out ar, out ag, out ab);
                    float e = 0.3f * er + 0.59f * eg + 0.11f * eb, d = 0.3f * dr + 0.59f * dg + 0.11f * db;
                    if (e + d > best) { best = e + d; res[k * 3] = e; res[k * 3 + 1] = d; res[k * 3 + 2] = 0.3f * ar + 0.59f * ag + 0.11f * ab; }
                }
            }
            return res;
        }
        // ---- the bake ----------------------------------------------------------------------------------------
        // ---- running it: its own threads, below the game's priority in the watcher (DOSBox must never wait for it) ----
        /// <summary>How many threads, and at what priority (the watcher: a share of the machine, below normal).</summary>
        public int Threads = Environment.ProcessorCount; public ThreadPriority Priority = ThreadPriority.Normal;
        /// <summary>Saved here when it finishes (the cache file), if set.</summary>
        public string SavePath;
        volatile bool _stop;
        public void Cancel() { _stop = true; }
        /// <summary>Bake on a thread of its own; Done goes true when it has finished (or failed: Error).</summary>
        public Thread Start()
        {
            var t = new Thread(Run, 64 << 20) { IsBackground = true, Priority = Priority, Name = "AztGiBake" };
            t.Start(); return t;
        }
        void ParFor(int n, Action<int, int[]> body)
        {
            int next = -1, nt = Math.Max(1, Math.Min(Threads, n)); Exception err = null;
            var ths = new Thread[nt];
            for (int i = 0; i < nt; i++)
            {
                ths[i] = new Thread(() =>
                {
                    var stack = new int[256];
                    try { int j; while (!_stop && (j = Interlocked.Increment(ref next)) < n) body(j, stack); }
                    catch (Exception e) { err = e; _stop = true; }
                }, 16 << 20) { IsBackground = true, Priority = Priority };
                ths[i].Start();
            }
            foreach (var t in ths) t.Join();
            if (err != null) throw err;
            if (_stop) throw new OperationCanceledException();
        }
        /// <summary>Rays kept between bounces at most (10 floats each): the rays per probe come down to fit.</summary>
        public int MaxRays = 6000000;
        /// <summary>A probe with more of its 32 test rays than this escaping into nothing is outside the room.</summary>
        public int MaxEscape = 6;
        /// <summary>Geometry further than this from every light is left out of the grid's bounds (parked parts).</summary>
        public float FarFromLights = 4000;

        public void Run()
        {
            var sw = Stopwatch.StartNew();
            try
            {
                if (_v == null || _nt == 0) throw new InvalidOperationException("no room to bake");
                if (Lights.Count == 0) throw new InvalidOperationException("no placed lights to bounce");
                if (Signature == null) MakeSignature();
                BuildBvh();
                float mnx = float.MaxValue, mny = float.MaxValue, mnz = float.MaxValue, mxx = float.MinValue, mxy = float.MinValue, mxz = float.MinValue;
                // (the grid spans the room near its lights: geometry parked far away -- ORRERY's orrery parts wait at y -37,000
                // until the game moves them in -- stretched it to 1,179 probes tall and 209 in the room)
                for (int k = 0; k < _nt * 3; k++)
                {
                    int vi = _t[k]; float x = _v[vi * 3], y = _v[vi * 3 + 1], z = _v[vi * 3 + 2];
                    bool near = false; foreach (var L in Lights) { float dx = x - L.X, dy = y - L.Y, dz = z - L.Z; if (dx * dx + dy * dy + dz * dz < FarFromLights * FarFromLights) { near = true; break; } }
                    if (!near) continue;
                    if (x < mnx) mnx = x; if (x > mxx) mxx = x; if (y < mny) mny = y; if (y > mxy) mxy = y; if (z < mnz) mnz = z; if (z > mxz) mxz = z;
                }
                if (mnx > mxx) throw new InvalidOperationException("no geometry near the lights");
                float sp = Math.Max(4f, Spacing);
                while ((long)((mxx - mnx) / sp + 2) * (long)((mxy - mny) / sp + 2) * (long)((mxz - mnz) / sp + 2) > MaxProbes) sp *= 1.15f;
                Spacing = sp; X0 = mnx; Y0 = mny; Z0 = mnz;
                NX = (int)((mxx - mnx) / sp) + 2; NY = (int)((mxy - mny) / sp) + 2; NZ = (int)((mxz - mnz) / sp) + 2;
                int np = NX * NY * NZ; Valid = new byte[np]; SH = new float[np * 12];
                // 1. WHICH PROBES ARE IN THE ROOM: the open space the lights are in, flooded probe to probe wherever the step
                // between them crosses no surface. (Not by which side of the faces a probe sees: this engine's faces are not
                // wound consistently -- the shader turns every normal toward the eye.) A probe inside a wall or outside the
                // room is never reached, so it lends no light (the shader leaves it out).
                // ...and only through probes that are enclosed: a probe out past a doorway, in the empty box round the
                // room's shell, sees most of its rays escape into nothing. More than MaxEscape of 32 escaping = outside.
                var open = new bool[np]; var dirs32 = Fibonacci(32);
                ParFor(np, (p, stack) =>
                {
                    int cx = p % NX, cy = (p / NX) % NY, cz = p / (NX * NY), miss = 0;
                    float px = X0 + cx * sp, py = Y0 + cy * sp, pz = Z0 + cz * sp, t, u, v;
                    for (int k = 0; k < 32 && miss <= MaxEscape; k++)
                        if (Trace(px, py, pz, dirs32[k * 3], dirs32[k * 3 + 1], dirs32[k * 3 + 2], 1e6f, out t, out u, out v, stack) < 0) miss++;
                    open[p] = miss <= MaxEscape;
                });
                int enclosed = 0; for (int p = 0; p < np; p++) if (open[p]) enclosed++;
                var stk = new int[256]; var queue = new Queue<int>();
                foreach (var l in Lights)
                {
                    int cx0 = (int)Math.Round((l.X - X0) / sp), cy0 = (int)Math.Round((l.Y - Y0) / sp), cz0 = (int)Math.Round((l.Z - Z0) / sp);
                    for (int dz = -1; dz <= 1; dz++) for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++)
                            {
                                int cx = cx0 + dx, cy = cy0 + dy, cz = cz0 + dz; if (cx < 0 || cy < 0 || cz < 0 || cx >= NX || cy >= NY || cz >= NZ) continue;
                                int p = (cz * NY + cy) * NX + cx; if (Valid[p] != 0 || !open[p]) continue;
                                float ex = X0 + cx * sp - l.X, ey = Y0 + cy * sp - l.Y, ez = Z0 + cz * sp - l.Z, el = (float)Math.Sqrt(ex * ex + ey * ey + ez * ez);
                                if (el > 1e-3f && Occluded(l.X, l.Y, l.Z, ex / el, ey / el, ez / el, el, stk)) continue;
                                Valid[p] = 1; queue.Enqueue(p);
                            }
                }
                // a light from outside the room (a shaft down through a hole, no shadow test): seeded where its beam first
                // reaches an enclosed probe
                foreach (var l in Lights)
                {
                    float dl = (float)Math.Sqrt(l.DX * l.DX + l.DY * l.DY + l.DZ * l.DZ); if (dl < 1e-4f) continue;
                    for (float d = 0; d < Math.Max(l.Range, 1000f); d += sp * 0.5f)
                    {
                        float x = l.X + l.DX / dl * d, y = l.Y + l.DY / dl * d, z = l.Z + l.DZ / dl * d;
                        int cx = (int)Math.Round((x - X0) / sp), cy = (int)Math.Round((y - Y0) / sp), cz = (int)Math.Round((z - Z0) / sp);
                        if (cx < 0 || cy < 0 || cz < 0 || cx >= NX || cy >= NY || cz >= NZ) continue;
                        int p = (cz * NY + cy) * NX + cx; if (!open[p]) continue;
                        if (Valid[p] == 0) { Valid[p] = 1; queue.Enqueue(p); }
                        break;
                    }
                }                int[] ox = { 1, -1, 0, 0, 0, 0 }, oy = { 0, 0, 1, -1, 0, 0 }, oz = { 0, 0, 0, 0, 1, -1 };
                int valid = queue.Count;
                while (queue.Count > 0)
                {
                    if (_stop) throw new OperationCanceledException();
                    int p = queue.Dequeue(), cx = p % NX, cy = (p / NX) % NY, cz = p / (NX * NY);
                    float px = X0 + cx * sp, py = Y0 + cy * sp, pz = Z0 + cz * sp;
                    for (int k = 0; k < 6; k++)
                    {
                        int nx = cx + ox[k], ny = cy + oy[k], nz = cz + oz[k]; if (nx < 0 || ny < 0 || nz < 0 || nx >= NX || ny >= NY || nz >= NZ) continue;
                        int q = (nz * NY + ny) * NX + nx; if (Valid[q] != 0 || !open[q]) continue;
                        if (Occluded(px, py, pz, ox[k], oy[k], oz[k], sp, stk)) continue;
                        Valid[q] = 1; valid++; queue.Enqueue(q);
                    }
                }
                ValidCount = valid; Enclosed = enclosed;
                if (valid == 0) throw new InvalidOperationException("no probe reaches a light");
                // 2. each valid probe's rays, once: how far each goes, the surface's facing, its colour, the direct light on it
                var vIdx = new int[valid]; int vi2 = 0; for (int p = 0; p < np; p++) if (Valid[p] != 0) vIdx[vi2++] = p;
                int R = Math.Max(16, Rays);
                if ((long)valid * R > MaxRays) R = Math.Max(16, (int)(MaxRays / valid));
                if ((long)valid * R > MaxRays) throw new InvalidOperationException("too many probes for the ray budget: raise the spacing");
                RaysUsed = R;
                var dirs = Fibonacci(R);
                // per valid probe and ray: distance, normal (3, the ray's side), colour (3), colour x direct (3); a miss = NaN
                var hit = new float[valid * R * 10];
                ParFor(valid, (q, stack) =>
                {
                    int p = vIdx[q], cx = p % NX, cy = (p / NX) % NY, cz = p / (NX * NY);
                    float px = X0 + cx * sp, py = Y0 + cy * sp, pz = Z0 + cz * sp;
                    // each probe's rays turned its own way (no grid of identical patterns)
                    float a = (float)((p * 0.618034) % 1.0 * 2 * Math.PI), ca = (float)Math.Cos(a), sa = (float)Math.Sin(a);
                    for (int k = 0; k < R; k++)
                    {
                        float dx = dirs[k * 3] * ca - dirs[k * 3 + 2] * sa, dy = dirs[k * 3 + 1], dz = dirs[k * 3] * sa + dirs[k * 3 + 2] * ca;
                        int o = (q * R + k) * 10;
                        float t, u, v; int h = Trace(px, py, pz, dx, dy, dz, 1e6f, out t, out u, out v, stack);
                        if (h < 0) { hit[o] = float.NaN; continue; }
                        float nx = _tv[h * 12 + 9], ny = _tv[h * 12 + 10], nz = _tv[h * 12 + 11];
                        if (nx * dx + ny * dy + nz * dz > 0) { nx = -nx; ny = -ny; nz = -nz; }      // the side the ray came from
                        float hx = px + dx * t, hy = py + dy * t, hz = pz + dz * t, cr, cg, cb, dr, dg, db;
                        SurfaceColour(h, u, v, out cr, out cg, out cb);
                        Direct(hx, hy, hz, nx, ny, nz, stack, out dr, out dg, out db);
                        hit[o] = t; hit[o + 1] = nx; hit[o + 2] = ny; hit[o + 3] = nz;
                        hit[o + 4] = cr; hit[o + 5] = cg; hit[o + 6] = cb; hit[o + 7] = cr * dr; hit[o + 8] = cg * dg; hit[o + 9] = cb * db;
                    }
                });
                // 3. the bounces: each ray brings back colour x (direct + the bounced light the grid holds there), into SH
                float wk = (float)(4 * Math.PI / R);
                for (int bnc = 0; bnc < Math.Max(1, Bounces); bnc++)
                {
                    var prev = SH; var next = new float[np * 12]; bool first = bnc == 0;
                    ParFor(valid, (q, stack) =>
                    {
                        int p = vIdx[q], cx = p % NX, cy = (p / NX) % NY, cz = p / (NX * NY);
                        float px = X0 + cx * sp, py = Y0 + cy * sp, pz = Z0 + cz * sp;
                        float a = (float)((p * 0.618034) % 1.0 * 2 * Math.PI), ca = (float)Math.Cos(a), sa = (float)Math.Sin(a);
                        var acc = new float[12];
                        for (int k = 0; k < R; k++)
                        {
                            float dx = dirs[k * 3] * ca - dirs[k * 3 + 2] * sa, dy = dirs[k * 3 + 1], dz = dirs[k * 3] * sa + dirs[k * 3 + 2] * ca;
                            int o = (q * R + k) * 10; float lr, lg, lb;
                            if (float.IsNaN(hit[o])) { lr = SkyR; lg = SkyG; lb = SkyB; }
                            else
                            {
                                lr = hit[o + 7]; lg = hit[o + 8]; lb = hit[o + 9];
                                if (!first)
                                {
                                    float er, eg, eb, t = hit[o];
                                    Irradiance(prev, px + dx * t, py + dy * t, pz + dz * t, hit[o + 1], hit[o + 2], hit[o + 3], out er, out eg, out eb);
                                    lr += hit[o + 4] * er; lg += hit[o + 5] * eg; lb += hit[o + 6] * eb;
                                }
                            }
                            float y0 = 0.282095f * wk, y1 = 0.488603f * wk;
                            acc[0] += lr * y0; acc[1] += lr * y1 * dx; acc[2] += lr * y1 * dy; acc[3] += lr * y1 * dz;
                            acc[4] += lg * y0; acc[5] += lg * y1 * dx; acc[6] += lg * y1 * dy; acc[7] += lg * y1 * dz;
                            acc[8] += lb * y0; acc[9] += lb * y1 * dx; acc[10] += lb * y1 * dy; acc[11] += lb * y1 * dz;
                        }
                        Array.Copy(acc, 0, next, p * 12, 12);
                    });
                    SH = next;
                }
                Ms = sw.Elapsed.TotalMilliseconds;
                Note = string.Format("{0}x{1}x{2} probes {3:N0} units apart, {4:N0} in the room ({10:N0} enclosed); {5} rays, {6} bounces, {7} lights; {8:N0} triangles; {9:N1} s",
                    NX, NY, NZ, Spacing, ValidCount, R, Bounces, Lights.Count, _nt, Ms / 1000, Enclosed);
                if (SavePath != null) { try { Save(SavePath); } catch (Exception e) { Note += " (not cached: " + e.Message + ")"; } }
            }
            catch (OperationCanceledException) { Error = "cancelled"; }
            catch (Exception e) { Error = e.Message; }
            finally { Done = true; }
        }
        public int RaysUsed, Enclosed;        static float[] Fibonacci(int n)
        {
            var d = new float[n * 3]; double ga = Math.PI * (3 - Math.Sqrt(5));
            for (int i = 0; i < n; i++)
            {
                double y = 1 - (i + 0.5) * 2.0 / n, r = Math.Sqrt(Math.Max(0, 1 - y * y)), th = ga * i;
                d[i * 3] = (float)(Math.Cos(th) * r); d[i * 3 + 1] = (float)y; d[i * 3 + 2] = (float)(Math.Sin(th) * r);
            }
            return d;
        }

        // ---- the cache file --------------------------------------------------------------------------------
        public void Save(string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string tmp = path + ".tmp";
            using (var bw = new BinaryWriter(File.Create(tmp)))
            {
                bw.Write(0x31494741); bw.Write(Signature ?? ""); bw.Write(NX); bw.Write(NY); bw.Write(NZ); bw.Write(X0); bw.Write(Y0); bw.Write(Z0); bw.Write(Spacing);
                bw.Write(ValidCount); bw.Write(Note ?? ""); bw.Write(Valid);
                var bytes = new byte[SH.Length * 4]; Buffer.BlockCopy(SH, 0, bytes, 0, bytes.Length); bw.Write(bytes);
            }
            if (File.Exists(path)) File.Delete(path); File.Move(tmp, path);
        }
        public static GiBake Load(string path)
        {
            using (var br = new BinaryReader(File.OpenRead(path)))
            {
                if (br.ReadInt32() != 0x31494741) throw new InvalidDataException("not a bounced-light file");
                var g = new GiBake(); g.Signature = br.ReadString(); g.NX = br.ReadInt32(); g.NY = br.ReadInt32(); g.NZ = br.ReadInt32();
                g.X0 = br.ReadSingle(); g.Y0 = br.ReadSingle(); g.Z0 = br.ReadSingle(); g.Spacing = br.ReadSingle(); g.ValidCount = br.ReadInt32(); g.Note = br.ReadString();
                int np = g.NX * g.NY * g.NZ; g.Valid = br.ReadBytes(np);
                var bytes = br.ReadBytes(np * 48); g.SH = new float[np * 12]; Buffer.BlockCopy(bytes, 0, g.SH, 0, bytes.Length);
                g.Done = true; return g;
            }
        }
    }
}
