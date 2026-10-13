// Particles.cs -- embers, drips, steam and footstep dust, for the graphics card's picture.
//
// Simulated here (a few hundred at most, microseconds), drawn by GpuRaster.SetParticles as soft
// sprites in the room's depth. Four kinds:
//   * EMBERS  rise from every flickering light (a torch), glowing orange to red, and die out.
//   * DRIPS   fall from the real ceiling above the player -- found by a ray up into the room's
//             own geometry -- to the real floor below, and splash.
//   * STEAM   billows up from the floor around the player (rooms that have it), growing and
//             thinning as it rises.
//   * KICKUP  little puffs of dust where the player's feet are, while walking.
//   * GHOST   glowing wisps shed from a ghost's hem, ribbons and hands (a room's "ghost" block), rising as they fade.
// Everything but the embers is lit the way the dust motes are: the room's level plus the helmet
// lamp's beam where it falls (Raster.LampAt); embers make their own light.
using System;
using System.Collections.Generic;

namespace AztTool
{
    public class Particles
    {
        public const int Stride = 10;          // per particle out: x y z, size (world), r g b (0..255), alpha, additive (0/1), seed
        struct P { public float x, y, z, vx, vy, vz, age, life, size, size1, seed; public byte kind; }
        const byte EMBER = 1, DRIP = 2, SPLASH = 3, STEAM = 4, KICK = 5, SHAFT = 6, WMIST = 7, GHOST = 8;
        readonly List<P> _p = new List<P>(512);
        readonly Random _rnd = new Random(11);
        float R() { return (float)_rnd.NextDouble(); }

        // ---- settings (set from the room's atmosphere file) ----------------------------------------
        public float EmberRate = 7f, EmberRise = 34f, EmberLife = 1.8f, EmberSize = 0.9f;
        public int EmberColor = 0xFF8A2A;
        public float DripRate = 0f, DripRadius = 260f, DripSize = 0.8f, Gravity = 520f;
        public int DripColor = 0xA8B4B8;
        /// <summary>DRIPS WITH NO CEILING (Josh, 2026-10-09, SPAROOM/2: "droplets from the ceiling ... hitting the surface"):
        /// SPAROOM's water has nothing above it, so a drip starts this far above the eye, out of the dark (0 = only under a
        /// real ceiling, as before).</summary>
        public float DripFromDark = 0f;
        // where drips land, for the water's rings (GpuRaster.SetDrops): x, z, height, age (s); the newest 16
        readonly float[] _drops = new float[16 * 4]; int _dropN, _dropNext;
        /// <summary>The drips that landed in the last few seconds: x, z, the height they landed at, age (s). Returns how many.</summary>
        public int GatherDrops(float[] dst)
        {
            int n = 0;
            for (int i = 0; i < _dropN && (n + 1) * 4 <= dst.Length; i++) { if (_drops[i * 4 + 3] > 3f) continue; Array.Copy(_drops, i * 4, dst, n * 4, 4); n++; }
            return n;
        }
        public float SteamRate = 0f, SteamRadius = 320f, SteamRise = 10f, SteamLife = 7f, SteamSize = 38f, SteamAlpha = 0.11f;
        public int SteamColor = 0xC4C2BA;
        /// <summary>Fine steam (SPAROOM, 2026-10-08): small, sharply shaped wisps instead of soft puffs (seed 3+ to the shader).</summary>
        public bool SteamFine;
        public float KickRate = 0f, KickSize = 7f, KickLife = 1.6f, KickAlpha = 0.22f, KickStep = 26f, KickAhead = 60f;
        public int KickColor = 0x8A7A64;
        public float EyeHeight = 45f;          // where the feet are, below the eye, when the floor is not found
        public int MaxParticles = 1500;

        // the lights embers come from: x y z per light (only those that flicker)
        float[] _emit = new float[0]; float[] _emitAcc = new float[0];
        public void SetEmitters(float[] xyz) { _emit = xyz ?? new float[0]; _emitAcc = new float[_emit.Length / 3]; }
        public void Clear() { _p.Clear(); _dripAcc = 0; _steamAcc = 0; _wmAcc = 0; _walked = 0; _haveLast = false; }

        // ---- WATER-EDGE MIST (Josh, 2026-10-09, Room Review SPAROOM/8: "some teal, subtle mist ... in the edges of the top of
        // the water ... the same basic color as the water is but slightly lighter"): soft puffs born along the outline of the
        // water's surface where it meets the walls, pillars and steps (SetWaterEdges), a little in over the water, lying
        // low and drifting slowly, growing and thinning. Self-lit, as the steam is.
        public float WaterMistRate = 0f, WaterMistSize = 34f, WaterMistLife = 11f, WaterMistRise = 1.5f, WaterMistAlpha = 0.07f, WaterMistInset = 10f, WaterMistDrift = 3f, WaterMistBand = 40f;
        public int WaterMistColor = 0x7FE6DA;
        float[] _wPts = new float[0]; float _wmAcc;     // per birthplace: x y z, away-from-the-wall x z (unit)
        /// <summary>Where the water meets the room: points on the water's surface (its triangles, as vertex-index triples into
        /// the room's vertices) that are inside the room (every way level with the water meets something) and within `band`
        /// units of a wall, pillar or step. The water is often one big quad running under the walls, so its own outline
        /// is no use. Returns how many birthplaces.</summary>
        public int SetWaterEdges(float[] vx, int[] tris, int[] idx, int[] triTex, float band)
        {
            _p.RemoveAll(q => q.kind == WMIST); _wmPrimed = false;
            var pts = new List<float>(); var rnd = new Random(5);
            double area = 0; var cum = new List<double>();
            for (int t = 0; t + 2 < tris.Length; t += 3)
            {
                int i0 = tris[t] * 3, i1 = tris[t + 1] * 3, i2 = tris[t + 2] * 3;
                double ax = vx[i1] - vx[i0], az = vx[i1 + 2] - vx[i0 + 2], bx = vx[i2] - vx[i0], bz = vx[i2 + 2] - vx[i0 + 2];
                area += Math.Abs(ax * bz - az * bx) * 0.5; cum.Add(area);
            }
            if (area <= 0) { _wPts = new float[0]; return 0; }
            int want = 6000; const int DIRS = 12;
            for (int k = 0; k < want; k++)
            {
                double pick = rnd.NextDouble() * area; int ti = cum.BinarySearch(pick); if (ti < 0) ti = ~ti; if (ti >= cum.Count) ti = cum.Count - 1;
                int i0 = tris[ti * 3] * 3, i1 = tris[ti * 3 + 1] * 3, i2 = tris[ti * 3 + 2] * 3;
                double u = rnd.NextDouble(), v = rnd.NextDouble(); if (u + v > 1) { u = 1 - u; v = 1 - v; }
                float x = (float)(vx[i0] + (vx[i1] - vx[i0]) * u + (vx[i2] - vx[i0]) * v), y = (float)(vx[i0 + 1] + (vx[i1 + 1] - vx[i0 + 1]) * u + (vx[i2 + 1] - vx[i0 + 1]) * v), z = (float)(vx[i0 + 2] + (vx[i1 + 2] - vx[i0 + 2]) * u + (vx[i2 + 2] - vx[i0 + 2]) * v);
                float ry = y + 4f, best = 1e9f, bdx = 0, bdz = 0; bool open = false;
                for (int d = 0; d < DIRS && !open; d++)
                {
                    double ang = d * 2 * Math.PI / DIRS; float dx = (float)Math.Cos(ang), dz = (float)Math.Sin(ang);
                    float dist = Raster.RayDistance(vx, idx, triTex, x, ry, z, dx, 0f, dz, 1500f);
                    if (dist >= 1500f) open = true;                       // escapes level with the water: outside the room
                    else if (dist < best) { best = dist; bdx = dx; bdz = dz; }
                }
                if (open || best > band || best < 1.5f) continue;
                pts.AddRange(new[] { x, y, z, -bdx, -bdz });              // (drifting away from the nearest wall, out over the water)
            }
            _wPts = pts.ToArray();
            return _wPts.Length / 5;
        }
        void WaterMistParticle(bool anyAge)
        {
            int n = _wPts.Length / 5; if (n == 0) return;
            int b = _rnd.Next(n) * 5; float inset = WaterMistInset * R();
            float x = _wPts[b] + _wPts[b + 3] * inset + (R() - 0.5f) * 6f, z = _wPts[b + 2] + _wPts[b + 4] * inset + (R() - 0.5f) * 6f;
            float y = _wPts[b + 1] + 1.5f + R() * 4f;
            float life = WaterMistLife * (0.7f + R() * 0.6f), drift = WaterMistDrift;
            Add(new P { kind = WMIST, x = x, y = y, z = z, vx = (R() - 0.5f) * drift + _wPts[b + 3] * drift * 0.5f, vy = WaterMistRise * (0.4f + R() * 0.8f), vz = (R() - 0.5f) * drift + _wPts[b + 4] * drift * 0.5f,
                        age = anyAge ? R() * life : 0f, life = life, size = WaterMistSize * (0.6f + R() * 0.5f), size1 = WaterMistSize * (1.5f + R() * 0.8f), seed = R() });
        }

        // ---- SHAFT DUST (2026-10-08, Josh: "more particles floating in this light shaft, illuminated"): specks drifting
        // inside a spotlight's cone, from where the beam enters the room (its first surface along the cone) down to where it
        // lands, glowing in its light (additive) -- white near the top, the light's far colour lower down.
        // Per shaft, 18 floats: apex x y z, dir x y z, tan(outer cone), count, size, top rgb (0..255), far rgb (0..255), size spread
        // (0 = 0.5-1.4 x size; above it, mostly fine specks with a few far bigger motes: 0.3 x size up to 0.3 + 2.7 x spread -- ORRERY, Josh 2026-10-09),
        // swirl (radians a second round the beam's axis, 0 = none: they drift down as before; with it they also rise and sink),
        // from the light (1 = the specks fill the beam from the light itself down to the last surface it meets)
        float[] _shafts = new float[0]; float[] _shaftSpan;           // per shaft: from, to (distance along the axis), found once
        public void SetShafts(float[] s) { _shafts = s ?? new float[0]; _shaftSpan = null; _p.RemoveAll(q => q.kind == SHAFT); }
        public int ShaftCount { get { int n = 0; foreach (var q in _p) if (q.kind == SHAFT) n++; return n; } }
        void ShaftParticle(int si, bool anyAge)
        {
            int b = si * 18; float from = _shaftSpan[si * 2], to = _shaftSpan[si * 2 + 1]; if (to <= from) return;
            float dx = _shafts[b + 3], dy = _shafts[b + 4], dz = _shafts[b + 5], tn = _shafts[b + 6];
            // a cross axis pair for the cone
            float ux = Math.Abs(dy) < 0.9f ? 0f : 1f, uy = Math.Abs(dy) < 0.9f ? 1f : 0f;
            float t1x = uy * dz, t1y = -ux * dz, t1z = ux * dy - uy * dx; float tl = (float)Math.Sqrt(t1x * t1x + t1y * t1y + t1z * t1z); if (tl < 1e-6f) tl = 1f; t1x /= tl; t1y /= tl; t1z /= tl;
            float t2x = dy * t1z - dz * t1y, t2y = dz * t1x - dx * t1z, t2z = dx * t1y - dy * t1x;
            float along = from + R() * (to - from), rad = tn * along * 0.85f * (float)Math.Sqrt(R()), a = R() * 6.2832f;
            float ca = (float)Math.Cos(a) * rad, sa = (float)Math.Sin(a) * rad;
            float life = 7f + R() * 7f;
            Add(new P { kind = SHAFT, x = _shafts[b] + dx * along + t1x * ca + t2x * sa, y = _shafts[b + 1] + dy * along + t1y * ca + t2y * sa, z = _shafts[b + 2] + dz * along + t1z * ca + t2z * sa,
                        vx = (R() - 0.5f) * 3f, vy = _shafts[b + 16] > 0f ? (R() - 0.5f) * 0.6f : -(0.6f + R() * 1.6f), vz = (R() - 0.5f) * 3f, age = anyAge ? R() * life : 0f, life = life,
                        size = _shafts[b + 15] > 0f ? _shafts[b + 8] * (0.3f + 2.7f * _shafts[b + 15] * (float)Math.Pow(R(), 3)) : _shafts[b + 8] * (0.5f + R() * 0.9f), size1 = si + (along - from) / Math.Max(1f, to - from) * 0.999f, seed = R() });
        }

        // ---- A GHOST'S WISPS (Josh, 2026-10-11, WELLROOM: Niamh "more ethereal"): pale curls of mist shed from her hem, her
        // trailing ribbons and her hands (SetGhostSources: those parts' vertices in the posed room), drifting up and away and
        // fading -- she moves on and they stay where they were shed, so they trail. Glowing (additive), shaped as the steam's soft puff.
        // Size, rise (a second) and spread are shares of the height those parts span as she is posed (her size is the engine's).
        public float GhostRate = 0f, GhostSize = 0.06f, GhostLife = 3.2f, GhostRise = 0.05f, GhostAlpha = 0.85f, GhostSpread = 0.03f;
        public int GhostColor = 0x9FEDE4;
        int[] _gVerts = new int[0]; float _gAcc, _gSpan = 1f;
        /// <summary>Where a ghost's wisps are shed from: vertex indices into the posed room Update is given (none = no wisps).</summary>
        public void SetGhostSources(int[] verts) { _gVerts = verts ?? new int[0]; _p.RemoveAll(q => q.kind == GHOST); _gAcc = 0; }
        public int GhostSources { get { return _gVerts.Length; } }
        void GhostParticle(float[] vx)
        {
            // somewhere between two of those points: through her lower body, not only at its corners
            int a = _gVerts[_rnd.Next(_gVerts.Length)] * 3, b = _gVerts[_rnd.Next(_gVerts.Length)] * 3;
            if (a + 2 >= vx.Length || b + 2 >= vx.Length) return;
            float u = R(), px = vx[a] + (vx[b] - vx[a]) * u, py = vx[a + 1] + (vx[b + 1] - vx[a + 1]) * u, pz = vx[a + 2] + (vx[b + 2] - vx[a + 2]) * u;
            float life = GhostLife * (0.6f + R() * 0.8f), sp = GhostSpread * _gSpan, sz = GhostSize * _gSpan;
            Add(new P { kind = GHOST, x = px + (R() - 0.5f) * sp, y = py + (R() - 0.5f) * sp, z = pz + (R() - 0.5f) * sp,
                        vx = (R() - 0.5f) * sp, vy = GhostRise * _gSpan * (0.4f + R() * 0.9f), vz = (R() - 0.5f) * sp,
                        life = life, size = sz * (0.5f + R() * 0.5f), size1 = sz * (1.6f + R()), seed = R() });
        }

        bool _wmPrimed;
        float _dripAcc, _steamAcc, _walked; float _lx, _ly, _lz; bool _haveLast;
        public int Count { get { return _p.Count; } }
        public float FloorY = float.NaN;      // under the player, last found

        /// <summary>Advance by dt seconds. The eye is at (ex, ey, ez); `vx/idx/triTex` is the room as
        /// posed this frame (for the ceilings and floors drips and steam need).</summary>
        public void Update(float dt, float ex, float ey, float ez, float[] vx, int[] idx, int[] triTex)
        {
            if (dt <= 0f) return; if (dt > 0.1f) dt = 0.1f;
            // the floor under the player: a ray straight down from the eye
            float down = Raster.RayDistance(vx, idx, triTex, ex, ey, ez, 0f, -1f, 0f, 400f);
            float feet = down < 400f ? ey - down : ey - EyeHeight;
            FloorY = float.IsNaN(FloorY) ? feet : FloorY + (feet - FloorY) * Math.Min(1f, dt * 8f);

            for (int i = 0; i < _dropN; i++) _drops[i * 4 + 3] += dt;
            // move and age what there is
            for (int i = _p.Count - 1; i >= 0; i--)
            {
                P p = _p[i];
                p.age += dt;
                if (p.age >= p.life) { _p.RemoveAt(i); continue; }
                switch (p.kind)
                {
                    case EMBER:
                        p.vx += (R() - 0.5f) * 60f * dt; p.vz += (R() - 0.5f) * 60f * dt; p.vy += 6f * dt;
                        break;
                    case DRIP:
                        p.vy -= Gravity * dt;
                        if (p.y + p.vy * dt <= p.size1)             // size1 holds the floor height it lands on
                        {
                            { int k = _dropNext; _drops[k * 4] = p.x; _drops[k * 4 + 1] = p.z; _drops[k * 4 + 2] = p.size1; _drops[k * 4 + 3] = 0f; _dropNext = (_dropNext + 1) % 16; if (_dropN < 16) _dropN++; }
                            for (int k = 0; k < 5; k++) Add(new P { kind = SPLASH, x = p.x, y = p.size1 + 0.5f, z = p.z, vx = (R() - 0.5f) * 50f, vy = 25f + R() * 30f, vz = (R() - 0.5f) * 50f, life = 0.35f + R() * 0.2f, size = DripSize * 0.6f, seed = R() });
                            _p.RemoveAt(i); continue;
                        }
                        break;
                    case SPLASH: p.vy -= Gravity * dt; break;
                    case STEAM:
                        p.vx += (R() - 0.5f) * 8f * dt; p.vz += (R() - 0.5f) * 8f * dt;
                        break;
                    case WMIST:
                        p.vx += (R() - 0.5f) * 2f * dt; p.vz += (R() - 0.5f) * 2f * dt;
                        break;
                    case GHOST:
                        // a slow curl: wandering sideways, easing off, still rising
                        p.vx += (R() - 0.5f) * 10f * dt; p.vz += (R() - 0.5f) * 10f * dt; p.vx *= 1f - 0.6f * dt; p.vz *= 1f - 0.6f * dt;
                        break;
                    case KICK:
                        p.vx *= 1f - Math.Min(1f, 2.5f * dt); p.vz *= 1f - Math.Min(1f, 2.5f * dt); p.vy -= 4f * dt;
                        break;
                    case SHAFT:
                        // a slow wander, settling a little
                        p.vx += (R() - 0.5f) * 4f * dt; p.vz += (R() - 0.5f) * 4f * dt; p.vx *= 1f - 0.3f * dt; p.vz *= 1f - 0.3f * dt;
                        {
                            // SWIRLING round the beam (Josh, ORRERY 2026-10-09: "bokeh effect dust particles swirling within the light
                            // beam"): turned about the axis, each at its own pace, rising and sinking a little, kept inside the cone
                            int si = (int)p.size1, b = si * 18;
                            if (b + 17 < _shafts.Length && _shafts[b + 16] > 0f)
                            {
                                float ax = _shafts[b], ay = _shafts[b + 1], az = _shafts[b + 2], dx = _shafts[b + 3], dy = _shafts[b + 4], dz = _shafts[b + 5];
                                float rx = p.x - ax, ry = p.y - ay, rz = p.z - az, al = rx * dx + ry * dy + rz * dz;
                                rx -= dx * al; ry -= dy * al; rz -= dz * al;
                                float a = _shafts[b + 16] * (0.6f + p.seed * 0.8f) * dt, c = (float)Math.Cos(a), s = (float)Math.Sin(a);
                                float tx = dy * rz - dz * ry, ty = dz * rx - dx * rz, tz = dx * ry - dy * rx;          // (the radius turned a quarter)
                                float nx = rx * c + tx * s, ny = ry * c + ty * s, nz = rz * c + tz * s;
                                float rl = (float)Math.Sqrt(nx * nx + ny * ny + nz * nz), lim = _shafts[b + 6] * Math.Max(al, 1f) * 0.85f;
                                if (rl > lim && rl > 1e-4f) { float k = lim / rl; nx *= k; ny *= k; nz *= k; }
                                p.x = ax + dx * al + nx; p.y = ay + dy * al + ny; p.z = az + dz * al + nz;
                                // (Josh, round 27: "more natural, just a bunch of particles floating around slowly and ethereal ...
                                // much slower"): each eases toward a slow, smooth drift of its own -- a gently changing field, no
                                // jitter -- so they float and meander rather than circle
                                float ph = p.seed * 6.2832f, ag = p.age;
                                float fx = 0.9f * (float)Math.Sin(0.021f * p.y + 0.11f * ag + ph), fy = 0.45f * (float)Math.Sin(0.017f * p.x + 0.07f * ag + ph * 1.7f), fz = 0.9f * (float)Math.Cos(0.019f * p.y + 0.09f * ag + ph * 2.3f);
                                float ease = Math.Min(1f, 0.6f * dt);
                                p.vx += (fx - p.vx) * ease; p.vy += (fy - p.vy) * ease; p.vz += (fz - p.vz) * ease;
                            }
                        }
                        break;
                }
                p.x += p.vx * dt; p.y += p.vy * dt; p.z += p.vz * dt;
                _p[i] = p;
            }

            // SHAFT DUST: where each shaft's beam is in the room (once, from the room as posed), then kept at its count
            int nShafts = _shafts.Length / 18;
            if (nShafts > 0 && vx != null)
            {
                if (_shaftSpan == null)
                {
                    _shaftSpan = new float[nShafts * 2];
                    for (int si = 0; si < nShafts; si++)
                    {
                        int b = si * 18; float ax = _shafts[b], ay = _shafts[b + 1], az = _shafts[b + 2], dx = _shafts[b + 3], dy = _shafts[b + 4], dz = _shafts[b + 5];
                        // the first surface along the axis; if a second lies beyond it, the beam enters through the first
                        // (a ceiling it shines through) and lands on the second -- otherwise it starts at the light itself
                        float d1 = Raster.RayDistance(vx, idx, triTex, ax, ay, az, dx, dy, dz, 5000f);
                        float d2 = d1 < 5000f ? Raster.RayDistance(vx, idx, triTex, ax + dx * (d1 + 1f), ay + dy * (d1 + 1f), az + dz * (d1 + 1f), dx, dy, dz, 5000f) : 5000f;
                        // ("from the light": ORRERY's light is in the room's own shaft and its first surface is the orrery's top,
                        // not a ceiling -- every speck went between that and the pit floor)
                        if (_shafts[b + 17] > 0.5f) { _shaftSpan[si * 2] = 2f; _shaftSpan[si * 2 + 1] = (d2 < 5000f ? d1 + d2 : Math.Min(d1, 1500f)) - 2f; }
                        else if (d1 < 5000f && d2 < 5000f) { _shaftSpan[si * 2] = d1 + 2f; _shaftSpan[si * 2 + 1] = d1 + d2 - 2f; }
                        else { _shaftSpan[si * 2] = 2f; _shaftSpan[si * 2 + 1] = Math.Min(d1, 1500f) - 2f; }
                        int want = (int)_shafts[b + 7];
                        for (int k = 0; k < want; k++) ShaftParticle(si, true);           // there already when the room is entered
                    }
                }
                else
                    for (int si = 0; si < nShafts; si++)
                    {
                        int have = 0; foreach (var q in _p) if (q.kind == SHAFT && (int)q.size1 == si) have++;
                        for (int k = have; k < (int)_shafts[si * 18 + 7]; k++) ShaftParticle(si, false);
                    }
            }
            // EMBERS, from each flickering light
            for (int li = 0; li < _emitAcc.Length; li++)
            {
                _emitAcc[li] += EmberRate * dt;
                while (_emitAcc[li] >= 1f)
                {
                    _emitAcc[li] -= 1f;
                    float a = R() * 6.2832f, rr = R() * 3f;
                    Add(new P { kind = EMBER, x = _emit[li * 3] + (float)Math.Cos(a) * rr, y = _emit[li * 3 + 1] + R() * 2f, z = _emit[li * 3 + 2] + (float)Math.Sin(a) * rr,
                                vx = (R() - 0.5f) * 10f, vy = EmberRise * (0.6f + R() * 0.8f), vz = (R() - 0.5f) * 10f, life = EmberLife * (0.5f + R()), size = EmberSize * (0.6f + R() * 0.8f), seed = R() });
                }
            }
            // DRIPS, from the ceiling above a point near the player, to the floor below it
            if (DripRate > 0f && vx != null)
            {
                _dripAcc += DripRate * dt;
                int tries = 0;
                while (_dripAcc >= 1f && tries++ < 4)
                {
                    float a = R() * 6.2832f, d = (float)Math.Sqrt(R()) * DripRadius;
                    float px = ex + (float)Math.Cos(a) * d, pz = ez + (float)Math.Sin(a) * d;
                    float up = Raster.ClearanceUp(vx, idx, triTex, px, ey, pz, 600f);
                    if (up >= 600f && DripFromDark <= 0f) continue;            // open sky, or outside the room
                    float top = up >= 600f ? ey + DripFromDark : ey + up - 0.6f;      // (no ceiling: out of the dark above)
                    float fall = Raster.RayDistance(vx, idx, triTex, px, top, pz, 0f, -1f, 0f, 1200f);
                    if (fall >= 1200f || fall < 8f) continue;
                    _dripAcc -= 1f;
                    Add(new P { kind = DRIP, x = px, y = top, z = pz, vy = 0f, life = 6f, size = DripSize, size1 = top - fall, seed = R() });
                }
                if (_dripAcc > 3f) _dripAcc = 3f;
            }
            // STEAM, rising from the floor round the player
            if (SteamRate > 0f && vx != null)
            {
                _steamAcc += SteamRate * dt;
                int tries = 0;
                while (_steamAcc >= 1f && tries++ < 8)
                {
                    float a = R() * 6.2832f, d = (float)Math.Sqrt(R()) * SteamRadius;
                    float px = ex + (float)Math.Cos(a) * d, pz = ez + (float)Math.Sin(a) * d;
                    float fall = Raster.RayDistance(vx, idx, triTex, px, ey, pz, 0f, -1f, 0f, 600f);
                    if (fall >= 600f) continue;
                    _steamAcc -= 1f;
                    Add(new P { kind = STEAM, x = px, y = ey - fall + 4f, z = pz, vx = (R() - 0.5f) * 6f, vy = SteamRise * (0.6f + R() * 0.8f), vz = (R() - 0.5f) * 6f, life = SteamLife * (0.6f + R() * 0.8f), size = SteamSize * (0.5f + R() * 0.5f), size1 = SteamSize * (1.4f + R()), seed = R() });
                }
                if (_steamAcc > 3f) _steamAcc = 3f;
            }
            // WATER-EDGE MIST: born along the water's outline (there already when the room is entered)
            if (WaterMistRate > 0f && _wPts.Length > 0)
            {
                if (!_wmPrimed) { _wmPrimed = true; int n0 = (int)(WaterMistRate * WaterMistLife); for (int k = 0; k < n0; k++) WaterMistParticle(true); }
                _wmAcc += WaterMistRate * dt;
                while (_wmAcc >= 1f) { _wmAcc -= 1f; WaterMistParticle(false); }
            }
            // A GHOST'S WISPS, from her as she is posed this frame
            if (GhostRate > 0f && _gVerts.Length > 0 && vx != null)
            {
                float lo = float.MaxValue, hi = float.MinValue;
                foreach (int gv in _gVerts) { int k3 = gv * 3 + 1; if (k3 >= vx.Length) continue; float y = vx[k3]; if (y < lo) lo = y; if (y > hi) hi = y; }
                _gSpan = hi > lo ? Math.Max(1f, hi - lo) : 1f;
                _gAcc += GhostRate * dt;
                while (_gAcc >= 1f) { _gAcc -= 1f; GhostParticle(vx); }
            }
            // KICKED-UP DUST: a few puffs at the feet for every step's worth of ground covered
            if (_haveLast && KickRate > 0f)
            {
                float mx = ex - _lx, mz = ez - _lz, moved = (float)Math.Sqrt(mx * mx + mz * mz);
                if (moved < 30f)                                               // (a jump is a teleport, not a step)
                {
                    _walked += moved;
                    while (_walked >= KickStep)
                    {
                        _walked -= KickStep;
                        float hx = moved > 1e-3f ? mx / moved : 0f, hz = moved > 1e-3f ? mz / moved : 0f;
                        int n = (int)Math.Max(1f, KickRate);
                        for (int k = 0; k < n; k++)
                        {
                            // out in front where it can be seen (at the feet themselves it is below the view)
                            float side = (R() - 0.5f) * 40f, fwd = KickAhead * (0.7f + R() * 0.8f);
                            Add(new P { kind = KICK, x = ex + hx * fwd - hz * side, y = FloorY + 1f + R() * 2f, z = ez + hz * fwd + hx * side,
                                        vx = (R() - 0.5f) * 30f + hx * 12f, vy = 6f + R() * 10f, vz = (R() - 0.5f) * 30f + hz * 12f, life = KickLife * (0.6f + R() * 0.7f), size = KickSize * (0.6f + R() * 0.8f), size1 = KickSize * 2.2f, seed = R() });
                        }
                    }
                }
                else _walked = 0f;
            }
            _lx = ex; _ly = ey; _lz = ez; _haveLast = true;
        }

        void Add(P p) { if (_p.Count < MaxParticles) _p.Add(p); }

        /// <summary>For the card: Stride floats a particle into dst, lit as the dust motes are (the
        /// camera and the lamp from `r`). Alpha-blended ones come first, back to front; then the
        /// additive ones. Returns how many.</summary>
        public int Gather(Raster r, float[] dst)
        {
            if (dst == null) return 0;
            int cap = dst.Length / Stride, n = 0;
            int W = r.W, H = r.H; float fpx = r.FocalPx, cx0 = W * 0.5f, cy0 = r.CentreY;
            float roomL = r.LampRoom;
            var order = new List<KeyValuePair<float, int>>(_p.Count);
            for (int i = 0; i < _p.Count; i++)
            {
                P p = _p[i];
                float[] v = r.ViewPoint(p.x, p.y, p.z);
                if (v[2] < 1f) continue;
                float sx = cx0 + v[0] * fpx / v[2], sy = cy0 - v[1] * fpx / v[2];
                if (sx < -200 || sy < -200 || sx > W + 200 || sy > H + 200) continue;
                bool add = p.kind == EMBER || p.kind == SHAFT || p.kind == GHOST;
                order.Add(new KeyValuePair<float, int>(add ? 1e9f - v[2] : -v[2], i));       // alpha ones far to near, then the additive ones
            }
            order.Sort((a, b) => a.Key.CompareTo(b.Key));
            foreach (var kv in order)
            {
                if (n >= cap) break;
                P p = _p[kv.Value];
                float t = p.age / p.life, size = p.size, alpha, cr, cg, cb; bool additive = false;
                int col;
                float[] v = r.ViewPoint(p.x, p.y, p.z);
                float sx = cx0 + v[0] * fpx / v[2], sy = cy0 - v[1] * fpx / v[2];
                float beam = r.LampAt(sx, sy, v[2]) * 0.9f, lit = roomL * 0.55f + beam;
                switch (p.kind)
                {
                    case EMBER:
                        additive = true; col = EmberColor;
                        // hot orange cooling to a dull red, flickering as it goes
                        float heat = Math.Min(1f, 1.9f * (1f - t * t)) * (0.75f + 0.25f * (float)Math.Sin((p.age * 23f) + p.seed * 40f));      // bright most of their life, dying at the end
                        cr = ((col >> 16) & 255) * heat; cg = ((col >> 8) & 255) * heat * heat; cb = (col & 255) * heat * heat * heat;
                        alpha = 1f; break;
                    case DRIP: case SPLASH:
                        col = DripColor; cr = ((col >> 16) & 255) * lit; cg = ((col >> 8) & 255) * lit; cb = (col & 255) * lit;
                        alpha = p.kind == DRIP ? 1f : 0.8f * (1f - t); cr = Math.Max(cr, 60f); cg = Math.Max(cg, 66f); cb = Math.Max(cb, 70f); break;    // (a drip glints a little even outside the beam)
                    case STEAM:
                        col = SteamColor; size = p.size + (p.size1 - p.size) * t;
                        // steam is pale on its own, flashlight or not (Josh, 2026-10-06: it vanished with
                        // the lamp off -- lit by the room alone it was the same shade as the room); the
                        // beam brightens it a little more, never to a white blob
                        float sl = Math.Min(0.95f, 0.72f + 0.35f * beam);
                        cr = ((col >> 16) & 255) * sl; cg = ((col >> 8) & 255) * sl; cb = (col & 255) * sl;
                        alpha = SteamAlpha * (float)Math.Sin(Math.PI * t); break;   // fades in, then out
                    case WMIST:
                        col = WaterMistColor; size = p.size + (p.size1 - p.size) * t;
                        // self-lit, as the steam (the water's own glow is under it); the beam brightens it a little
                        float wl = Math.Min(1f, 0.85f + 0.3f * beam);
                        cr = ((col >> 16) & 255) * wl; cg = ((col >> 8) & 255) * wl; cb = (col & 255) * wl;
                        alpha = WaterMistAlpha * (float)Math.Sin(Math.PI * t); break;
                    case GHOST:
                        // her own glow, growing and thinning as it rises, fading in and out
                        additive = true; col = GhostColor; size = p.size + (p.size1 - p.size) * t;
                        cr = (col >> 16) & 255; cg = (col >> 8) & 255; cb = col & 255;
                        alpha = GhostAlpha * (float)Math.Sin(Math.PI * t); break;
                    case SHAFT:
                    {
                        // lit by the shaft itself: its colour along the beam (size1's fraction), glinting, fading in and out
                        additive = true; int si = (int)p.size1, b = si * 18; float f = p.size1 - si;
                        float glint = 0.55f + 0.45f * (float)Math.Sin(p.age * (2.2f + p.seed * 3f) + p.seed * 30f), fade = (float)Math.Sin(Math.PI * t);
                        float k = glint * fade;
                        cr = (_shafts[b + 9] + (_shafts[b + 12] - _shafts[b + 9]) * f) * k; cg = (_shafts[b + 10] + (_shafts[b + 13] - _shafts[b + 10]) * f) * k; cb = (_shafts[b + 11] + (_shafts[b + 11 + 3] - _shafts[b + 11]) * f) * k;
                        alpha = 1f; break;
                    }
                    default:  // KICK
                        col = KickColor; size = p.size + (p.size1 - p.size) * t;
                        float kl = Math.Max(lit, 0.62f);      // (seen without the lamp too)
                        cr = ((col >> 16) & 255) * kl; cg = ((col >> 8) & 255) * kl; cb = (col & 255) * kl;
                        alpha = KickAlpha * (1f - t) * Math.Min(1f, t * 8f); break;
                }
                int q = n * Stride;
                dst[q] = p.x; dst[q + 1] = p.y; dst[q + 2] = p.z; dst[q + 3] = size;
                dst[q + 4] = Math.Min(255f, cr); dst[q + 5] = Math.Min(255f, cg); dst[q + 6] = Math.Min(255f, cb);
                dst[q + 7] = alpha; dst[q + 8] = additive ? 1f : 0f; dst[q + 9] = p.kind == STEAM ? (SteamFine ? 3f : 1f) + p.seed : p.kind == WMIST ? 1f + p.seed : p.kind == GHOST ? 1f + p.seed : (p.kind == DRIP ? -1f : p.seed);      // (water mist and a ghost's wisps: the steam's soft puff)
                n++;
            }
            return n;
        }
    }
}
