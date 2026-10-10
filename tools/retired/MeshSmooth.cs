// MeshSmooth.cs -- rounder models for the HOST renderer, made when a room is loaded.
//
// The host renderer draws its own copy of the game's geometry, so a creature or an arch can be
// given more triangles here without the game ever knowing: the game's files, its collision and
// its animation are untouched, and nothing extra runs inside DOSBox.
//
// WHAT MUST NOT HAPPEN. A room is mostly flat walls and square frames. Ordinary subdivision
// rounds every box into a pillow and multiplies the triangle count everywhere -- and this
// rasteriser pays per triangle. So:
//
//   * an edge is SMOOTH only if the two faces that meet at it are within CreaseDeg of each
//     other. Anything sharper, and every open border, is a CREASE and stays exactly straight;
//   * at each vertex, faces connected to one another through smooth edges share one normal
//     (a "fan"). The two faces either side of a smooth edge are in the same fan at both of its
//     ends, so both compute the SAME curved midpoint for it -- which is what keeps the surface
//     from cracking open along the edge;
//   * the midpoint of a smooth edge is pushed out onto the curved surface its end normals
//     imply (Phong tessellation). If that moves it less than MinMove, the edge is straight for
//     all practical purposes and is left alone;
//   * a triangle is split only along its curved edges: none, and it is untouched; one, two or
//     three, and it becomes two, three or four. No midpoint is ever left dangling against an
//     unsplit neighbour, so there are no pin-holes, and a flat wall gains nothing at all.
//
// Vertices are matched by POSITION within a part to decide what is connected (the files
// duplicate a vertex wherever the texture has a seam), but texture coordinates are interpolated
// along each triangle's own edge, so a seam stays a seam.
//
// PARTS KEEP THEIR OWN CONTIGUOUS VERTEX RANGES. Live posing moves each named part by its
// vertex range, so a part's new vertices are inserted directly after its old ones and every
// index is renumbered.
//
// It also hands back, for every triangle corner, WHICH FAN it belongs to (CornerGroup). The
// rasteriser uses that to shade a rounded surface smoothly instead of facet by facet.
using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace AztRoom
{
    public static class MeshSmooth
    {
        public class Stats
        {
            public int TrisBefore, TrisAfter, VertsBefore, VertsAfter, PartsChanged, SmoothEdges, CurvedEdges, Levels;
            public double Ms; public string Note = "";
        }

        struct Key : IEquatable<Key>
        {
            public int P, X, Y, Z;
            public bool Equals(Key o) { return P == o.P && X == o.X && Y == o.Y && Z == o.Z; }
            public override bool Equals(object o) { return o is Key && Equals((Key)o); }
            public override int GetHashCode() { unchecked { return (P * 73856093) ^ (X * 19349663) ^ (Y * 83492791) ^ (Z * 1540483477); } }
        }

        class Topo
        {
            public int NV, NT;
            public int[] PartOfV;           // -1: in no part
            public bool RangesOk;
            public bool[] Elig;             // triangle takes part in smoothing
            public int[] Weld;              // per vertex
            public float[] FN;              // face normal, 3 per triangle
            public int[] CornerGroup;       // per corner: fan id, -1 = none
            public int GroupCount;
            public float[] GroupN;          // 3 per group
            public float[] CornerN;         // 3 per corner
            public Dictionary<long, int> EdgeId; public List<int> EA, EB, EKA, EKB;   // tri A/B and the edge's index within each
            public bool[] ESmooth;
        }

        static int Find(int[] p, int i) { while (p[i] != i) { p[i] = p[p[i]]; i = p[i]; } return i; }

        // `inN`: null for the model as the game stores it -- smoothness is then decided by the angle
        // between faces. For a model that has already been split once it is the normal each
        // triangle corner was GIVEN (3 floats a corner), and an edge is smooth where the two
        // faces agree on that normal at both ends. The second round of splitting therefore
        // refines the SAME curved surface the first round described, instead of re-deriving a
        // slightly fatter one from the first round's triangles (which is what over-inflated it).
        static Topo Analyse(RoomUnit u, float cosCrease, float[] inN)
        {
            var t = new Topo(); int nv = u.V.Length / 3, nt = u.T.Length / 3; t.NV = nv; t.NT = nt;
            t.PartOfV = new int[nv]; for (int i = 0; i < nv; i++) t.PartOfV[i] = -1;
            t.RangesOk = true;
            for (int p = 0; p < u.PartName.Length; p++)
            {
                int a = u.PartVFirst[p], b = a + u.PartVCount[p];
                if (a < 0 || b > nv) { t.RangesOk = false; continue; }
                for (int k = a; k < b; k++) { if (t.PartOfV[k] != -1) t.RangesOk = false; t.PartOfV[k] = p; }
            }
            // weld by position, within a part
            t.Weld = new int[nv]; var wd = new Dictionary<Key, int>(nv);
            for (int i = 0; i < nv; i++)
            {
                var k = new Key { P = t.PartOfV[i], X = (int)Math.Round(u.V[i * 3] * 200.0), Y = (int)Math.Round(u.V[i * 3 + 1] * 200.0), Z = (int)Math.Round(u.V[i * 3 + 2] * 200.0) };
                int id; if (!wd.TryGetValue(k, out id)) { id = wd.Count; wd[k] = id; }
                t.Weld[i] = id;
            }
            t.Elig = new bool[nt]; t.FN = new float[nt * 3];
            for (int f = 0; f < nt; f++)
            {
                int a = u.T[f * 3], b = u.T[f * 3 + 1], c = u.T[f * 3 + 2];
                float e1x = u.V[b * 3] - u.V[a * 3], e1y = u.V[b * 3 + 1] - u.V[a * 3 + 1], e1z = u.V[b * 3 + 2] - u.V[a * 3 + 2];
                float e2x = u.V[c * 3] - u.V[a * 3], e2y = u.V[c * 3 + 1] - u.V[a * 3 + 1], e2z = u.V[c * 3 + 2] - u.V[a * 3 + 2];
                float nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
                double len = Math.Sqrt(nx * nx + ny * ny + nz * nz);
                int p = u.TriPart[f];
                bool ok = len > 1e-7 && u.TexIdx[f] >= 0 && p >= 0 && t.PartOfV[a] == p && t.PartOfV[b] == p && t.PartOfV[c] == p
                          && t.Weld[a] != t.Weld[b] && t.Weld[b] != t.Weld[c] && t.Weld[a] != t.Weld[c];
                t.Elig[f] = ok;
                if (len > 1e-12) { t.FN[f * 3] = (float)(nx / len); t.FN[f * 3 + 1] = (float)(ny / len); t.FN[f * 3 + 2] = (float)(nz / len); }
            }
            // edges
            t.EdgeId = new Dictionary<long, int>(nt * 2); t.EA = new List<int>(); t.EB = new List<int>(); t.EKA = new List<int>(); t.EKB = new List<int>();
            var count = new List<int>();
            for (int f = 0; f < nt; f++)
            {
                if (!t.Elig[f]) continue;
                for (int k = 0; k < 3; k++)
                {
                    int w0 = t.Weld[u.T[f * 3 + k]], w1 = t.Weld[u.T[f * 3 + (k + 1) % 3]];
                    long key = w0 < w1 ? ((long)w0 << 32) | (uint)w1 : ((long)w1 << 32) | (uint)w0;
                    int e;
                    if (!t.EdgeId.TryGetValue(key, out e)) { e = t.EA.Count; t.EdgeId[key] = e; t.EA.Add(f); t.EKA.Add(k); t.EB.Add(-1); t.EKB.Add(-1); count.Add(1); }
                    else { count[e]++; if (t.EB[e] < 0) { t.EB[e] = f; t.EKB[e] = k; } }
                }
            }
            int ne = t.EA.Count; t.ESmooth = new bool[ne];
            var parent = new int[nt * 3]; for (int i = 0; i < parent.Length; i++) parent[i] = i;
            for (int e = 0; e < ne; e++)
            {
                if (count[e] != 2) continue;
                int fa = t.EA[e], fb = t.EB[e], ka = t.EKA[e], kb = t.EKB[e];
                // the two faces must run along the edge in opposite directions, or one of them is inside out
                int a0 = t.Weld[u.T[fa * 3 + ka]], a1 = t.Weld[u.T[fa * 3 + (ka + 1) % 3]];
                int b0 = t.Weld[u.T[fb * 3 + kb]], b1 = t.Weld[u.T[fb * 3 + (kb + 1) % 3]];
                if (a0 != b1 || a1 != b0) continue;
                if (inN == null)
                {
                    float d = t.FN[fa * 3] * t.FN[fb * 3] + t.FN[fa * 3 + 1] * t.FN[fb * 3 + 1] + t.FN[fa * 3 + 2] * t.FN[fb * 3 + 2];
                    if (d < cosCrease) continue;
                }
                else
                {
                    int ca0 = (fa * 3 + ka) * 3, cb0 = (fb * 3 + (kb + 1) % 3) * 3, ca1 = (fa * 3 + (ka + 1) % 3) * 3, cb1 = (fb * 3 + kb) * 3;
                    float d0 = inN[ca0] * inN[cb0] + inN[ca0 + 1] * inN[cb0 + 1] + inN[ca0 + 2] * inN[cb0 + 2];
                    float d1 = inN[ca1] * inN[cb1] + inN[ca1 + 1] * inN[cb1 + 1] + inN[ca1 + 2] * inN[cb1 + 2];
                    if (d0 < 0.9995f || d1 < 0.9995f) continue;
                }
                t.ESmooth[e] = true;
                // join the two faces' corners at each end of the edge: a0 is A's corner ka and B's corner kb+1
                int ra = Find(parent, fa * 3 + ka), rb = Find(parent, fb * 3 + (kb + 1) % 3); if (ra != rb) parent[ra] = rb;
                ra = Find(parent, fa * 3 + (ka + 1) % 3); rb = Find(parent, fb * 3 + kb); if (ra != rb) parent[ra] = rb;
            }
            // fans -> groups, and each group's normal: face normals weighted by the corner's angle
            t.CornerGroup = new int[nt * 3]; var gid = new Dictionary<int, int>(); var sums = new List<double>();
            for (int f = 0; f < nt; f++)
            {
                if (!t.Elig[f]) { t.CornerGroup[f * 3] = t.CornerGroup[f * 3 + 1] = t.CornerGroup[f * 3 + 2] = -1; continue; }
                for (int k = 0; k < 3; k++)
                {
                    int root = Find(parent, f * 3 + k), g;
                    if (!gid.TryGetValue(root, out g)) { g = gid.Count; gid[root] = g; sums.Add(0); sums.Add(0); sums.Add(0); }
                    t.CornerGroup[f * 3 + k] = g;
                    int v = u.T[f * 3 + k], vn = u.T[f * 3 + (k + 1) % 3], vp = u.T[f * 3 + (k + 2) % 3];
                    double ax = u.V[vn * 3] - u.V[v * 3], ay = u.V[vn * 3 + 1] - u.V[v * 3 + 1], az = u.V[vn * 3 + 2] - u.V[v * 3 + 2];
                    double bx = u.V[vp * 3] - u.V[v * 3], by = u.V[vp * 3 + 1] - u.V[v * 3 + 1], bz = u.V[vp * 3 + 2] - u.V[v * 3 + 2];
                    double la = Math.Sqrt(ax * ax + ay * ay + az * az), lb = Math.Sqrt(bx * bx + by * by + bz * bz);
                    double cs = (la > 1e-12 && lb > 1e-12) ? (ax * bx + ay * by + az * bz) / (la * lb) : 1; if (cs > 1) cs = 1; else if (cs < -1) cs = -1;
                    double w = Math.Acos(cs);
                    sums[g * 3] += t.FN[f * 3] * w; sums[g * 3 + 1] += t.FN[f * 3 + 1] * w; sums[g * 3 + 2] += t.FN[f * 3 + 2] * w;
                }
            }
            t.GroupCount = gid.Count; t.GroupN = new float[t.GroupCount * 3];
            for (int g = 0; g < t.GroupCount; g++)
            {
                double l = Math.Sqrt(sums[g * 3] * sums[g * 3] + sums[g * 3 + 1] * sums[g * 3 + 1] + sums[g * 3 + 2] * sums[g * 3 + 2]);
                if (l > 1e-12) { t.GroupN[g * 3] = (float)(sums[g * 3] / l); t.GroupN[g * 3 + 1] = (float)(sums[g * 3 + 1] / l); t.GroupN[g * 3 + 2] = (float)(sums[g * 3 + 2] / l); }
            }
            // the normal each corner works with: handed in, or its fan's (its own face's if it has no fan)
            if (inN != null) t.CornerN = inN;
            else
            {
                t.CornerN = new float[nt * 9];
                for (int f = 0; f < nt; f++) for (int k = 0; k < 3; k++)
                {
                    int g = t.CornerGroup[f * 3 + k], o = (f * 3 + k) * 3;
                    if (g >= 0) { t.CornerN[o] = t.GroupN[g * 3]; t.CornerN[o + 1] = t.GroupN[g * 3 + 1]; t.CornerN[o + 2] = t.GroupN[g * 3 + 2]; }
                    else { t.CornerN[o] = t.FN[f * 3]; t.CornerN[o + 1] = t.FN[f * 3 + 1]; t.CornerN[o + 2] = t.FN[f * 3 + 2]; }
                }
            }
            return t;
        }

        static RoomUnit Shell(RoomUnit u)
        {
            var o = new RoomUnit();
            o.PartName = u.PartName; o.PartRest = u.PartRest; o.TexW = u.TexW; o.TexH = u.TexH; o.TexData = u.TexData;
            o.Textured = u.Textured; o.Flat = u.Flat; o.Skipped = u.Skipped; o.Solid = u.Solid; o.FlatInk = u.FlatInk;
            return o;
        }

        // One round of splitting. Returns null if nothing was split.
        static RoomUnit SplitOnce(RoomUnit u, Topo t, float minMove, Stats st, out float[] outN)
        {
            outN = null;
            if (!t.RangesOk) { st.Note = "part vertex ranges overlap or run off the end: left as it was"; return null; }
            int ne = t.EA.Count; var curved = new bool[ne]; var mid = new float[ne * 3]; int nCurved = 0, nSmooth = 0;
            for (int e = 0; e < ne; e++)
            {
                if (!t.ESmooth[e]) continue; nSmooth++;
                int fa = t.EA[e], ka = t.EKA[e];
                int v0 = u.T[fa * 3 + ka], v1 = u.T[fa * 3 + (ka + 1) % 3];
                int c0 = (fa * 3 + ka) * 3, c1 = (fa * 3 + (ka + 1) % 3) * 3;
                double p0x = u.V[v0 * 3], p0y = u.V[v0 * 3 + 1], p0z = u.V[v0 * 3 + 2], p1x = u.V[v1 * 3], p1y = u.V[v1 * 3 + 1], p1z = u.V[v1 * 3 + 2];
                double mx = (p0x + p1x) * 0.5, my = (p0y + p1y) * 0.5, mz = (p0z + p1z) * 0.5;
                double n0x = t.CornerN[c0], n0y = t.CornerN[c0 + 1], n0z = t.CornerN[c0 + 2], n1x = t.CornerN[c1], n1y = t.CornerN[c1 + 1], n1z = t.CornerN[c1 + 2];
                // the midpoint dropped onto each end's tangent plane, and the mean of the two
                double d0 = (mx - p0x) * n0x + (my - p0y) * n0y + (mz - p0z) * n0z, d1 = (mx - p1x) * n1x + (my - p1y) * n1y + (mz - p1z) * n1z;
                double ox = -(d0 * n0x + d1 * n1x) * 0.5, oy = -(d0 * n0y + d1 * n1y) * 0.5, oz = -(d0 * n0z + d1 * n1z) * 0.5;
                // HOW FAR ALONG THAT. For two points on a circle the mean of the two projections
                // overshoots the arc, by a factor that depends only on the angle between the two
                // normals: with c = cos(half that angle), the arc's own midpoint is exactly
                // 1 / ((1 + c) c) of the way. So a ring of flat faces becomes the circle it was
                // drawn to suggest -- not a fatter one -- and splitting again stays on it.
                double nd = n0x * n1x + n0y * n1y + n0z * n1z; if (nd > 1) nd = 1; if (nd < -0.5) continue;
                double ch = Math.Sqrt((1 + nd) * 0.5);
                double ALPHA = 1.0 / ((1 + ch) * ch); if (ALPHA > 1.3) ALPHA = 1.3;
                ox *= ALPHA; oy *= ALPHA; oz *= ALPHA;
                double move = Math.Sqrt(ox * ox + oy * oy + oz * oz);
                double len = Math.Sqrt((p1x - p0x) * (p1x - p0x) + (p1y - p0y) * (p1y - p0y) + (p1z - p0z) * (p1z - p0z));
                if (move < minMove || move < len * 0.012) continue;                 // straight enough
                double cap = len * 0.25; if (move > cap) { double k = cap / move; ox *= k; oy *= k; oz *= k; }
                curved[e] = true; nCurved++;
                mid[e * 3] = (float)(mx + ox); mid[e * 3 + 1] = (float)(my + oy); mid[e * 3 + 2] = (float)(mz + oz);
            }
            st.SmoothEdges = nSmooth; st.CurvedEdges = nCurved;
            if (nCurved == 0) return null;

            // new vertices: one per (edge, pair of the triangle's OWN vertices), so a texture seam keeps two
            int nv = t.NV, nt = t.NT, np = u.PartName.Length;
            var newOf = new Dictionary<long, int>(); var nvPos = new List<float>(); var nvUv = new List<float>(); var nvPart = new List<int>();
            var triMid = new int[nt * 3];           // per triangle edge: index into the new-vertex list, or -1
            for (int f = 0; f < nt; f++)
            {
                triMid[f * 3] = triMid[f * 3 + 1] = triMid[f * 3 + 2] = -1;
                if (!t.Elig[f]) continue;
                for (int k = 0; k < 3; k++)
                {
                    int va = u.T[f * 3 + k], vb = u.T[f * 3 + (k + 1) % 3];
                    int w0 = t.Weld[va], w1 = t.Weld[vb];
                    long ek = w0 < w1 ? ((long)w0 << 32) | (uint)w1 : ((long)w1 << 32) | (uint)w0;
                    int e = t.EdgeId[ek]; if (!curved[e]) continue;
                    long vk = va < vb ? ((long)va << 32) | (uint)vb : ((long)vb << 32) | (uint)va;
                    int ni;
                    if (!newOf.TryGetValue(vk, out ni))
                    {
                        ni = nvPart.Count; newOf[vk] = ni;
                        nvPos.Add(mid[e * 3]); nvPos.Add(mid[e * 3 + 1]); nvPos.Add(mid[e * 3 + 2]);
                        nvUv.Add((u.UV[va * 2] + u.UV[vb * 2]) * 0.5f); nvUv.Add((u.UV[va * 2 + 1] + u.UV[vb * 2 + 1]) * 0.5f);
                        nvPart.Add(u.TriPart[f]);
                    }
                    triMid[f * 3 + k] = ni;
                }
            }
            // lay the vertices out again: each part's new ones go straight after its old ones
            var added = new int[np]; foreach (int p in nvPart) added[p]++;
            var order = new int[np]; for (int i = 0; i < np; i++) order[i] = i;
            var ends = new int[np]; for (int i = 0; i < np; i++) ends[i] = u.PartVFirst[i] + u.PartVCount[i];
            Array.Sort((int[])ends.Clone(), order);             // parts by where their range ends
            var shiftAt = new int[nv + 2];                       // shiftAt[i]: vertices inserted before old index i
            var partNewBase = new int[np]; int run = 0, oi = 0;
            for (int i = 0; i <= nv; i++)
            {
                while (oi < np && ends[order[oi]] <= i) { int p = order[oi]; partNewBase[p] = ends[p] + run; run += added[p]; oi++; }
                shiftAt[i] = run;
            }
            int total = nv + nvPart.Count;
            var o = Shell(u);
            o.V = new float[total * 3]; o.UV = new float[total * 2];
            var newIdx = new int[nv];
            for (int i = 0; i < nv; i++)
            {
                int j = i + shiftAt[i]; newIdx[i] = j;
                o.V[j * 3] = u.V[i * 3]; o.V[j * 3 + 1] = u.V[i * 3 + 1]; o.V[j * 3 + 2] = u.V[i * 3 + 2];
                o.UV[j * 2] = u.UV[i * 2]; o.UV[j * 2 + 1] = u.UV[i * 2 + 1];
            }
            var fill = new int[np]; var midIdx = new int[nvPart.Count];
            for (int n = 0; n < nvPart.Count; n++)
            {
                int p = nvPart[n], j = partNewBase[p] + fill[p]++; midIdx[n] = j;
                o.V[j * 3] = nvPos[n * 3]; o.V[j * 3 + 1] = nvPos[n * 3 + 1]; o.V[j * 3 + 2] = nvPos[n * 3 + 2];
                o.UV[j * 2] = nvUv[n * 2]; o.UV[j * 2 + 1] = nvUv[n * 2 + 1];
            }
            o.PartVFirst = new int[np]; o.PartVCount = new int[np];
            for (int p = 0; p < np; p++)
            {
                int a = u.PartVFirst[p];
                o.PartVFirst[p] = (a >= 0 && a <= nv) ? a + shiftAt[a] : a;
                // a part's own insertions come AFTER its range, so they are not in shiftAt[its first vertex]
                o.PartVCount[p] = u.PartVCount[p] + added[p];
            }
            // triangles
            // Each new triangle corner also carries a NORMAL forward for the next round: an old
            // corner keeps the one it had; a midpoint takes the mean of its edge's two ends
            // (which both faces on that edge agree about, so they still agree afterwards).
            var T = new List<int>(nt * 4); var tex = new List<int>(nt * 2); var part = new List<int>(nt * 2); var changed = new HashSet<int>();
            var N = new List<float>(nt * 36);
            int[] pat3 = { 0, 3, 5, 3, 1, 4, 5, 4, 2, 3, 4, 5 }, pat2 = { 3, 1, 4, 0, 3, 4, 0, 4, 2 }, pat1 = { 0, 3, 2, 3, 1, 2 }, pat0 = { 0, 1, 2 };
            var vi6 = new int[6]; var n6 = new float[18];
            for (int f = 0; f < nt; f++)
            {
                int m0 = triMid[f * 3], m1 = triMid[f * 3 + 1], m2 = triMid[f * 3 + 2];
                int cnt = (m0 >= 0 ? 1 : 0) + (m1 >= 0 ? 1 : 0) + (m2 >= 0 ? 1 : 0);
                // turn the triangle so the pattern is always the same way round
                int rot = 0;
                if (cnt == 1) rot = m0 >= 0 ? 0 : (m1 >= 0 ? 1 : 2);                  // the split edge first
                else if (cnt == 2) rot = m2 < 0 ? 0 : (m0 < 0 ? 1 : 2);               // the UNSPLIT edge last
                for (int k = 0; k < 3; k++)
                {
                    int ck = (rot + k) % 3, src = (f * 3 + ck) * 3;
                    vi6[k] = newIdx[u.T[f * 3 + ck]];
                    n6[k * 3] = t.CornerN[src]; n6[k * 3 + 1] = t.CornerN[src + 1]; n6[k * 3 + 2] = t.CornerN[src + 2];
                    int mk = triMid[f * 3 + ck]; vi6[3 + k] = mk >= 0 ? midIdx[mk] : -1;
                }
                for (int k = 0; k < 3; k++)
                {
                    int a = k * 3, b = ((k + 1) % 3) * 3, d = (3 + k) * 3;
                    double sx = n6[a] + n6[b], sy = n6[a + 1] + n6[b + 1], sz = n6[a + 2] + n6[b + 2], sl = Math.Sqrt(sx * sx + sy * sy + sz * sz);
                    if (sl > 1e-9) { n6[d] = (float)(sx / sl); n6[d + 1] = (float)(sy / sl); n6[d + 2] = (float)(sz / sl); } else { n6[d] = n6[a]; n6[d + 1] = n6[a + 1]; n6[d + 2] = n6[a + 2]; }
                }
                int[] pat = cnt == 3 ? pat3 : (cnt == 2 ? pat2 : (cnt == 1 ? pat1 : pat0));
                if (cnt > 0) changed.Add(u.TriPart[f]);
                for (int k = 0; k < pat.Length; k++) { int q = pat[k]; T.Add(vi6[q]); N.Add(n6[q * 3]); N.Add(n6[q * 3 + 1]); N.Add(n6[q * 3 + 2]); }
                for (int k = 0; k < pat.Length / 3; k++) { tex.Add(u.TexIdx[f]); part.Add(u.TriPart[f]); }
            }
            o.T = T.ToArray(); o.TexIdx = tex.ToArray(); o.TriPart = part.ToArray(); outN = N.ToArray();
            st.PartsChanged = Math.Max(st.PartsChanged, changed.Count);
            return o;
        }

        /// <summary>A smoothed copy of a unit. `levels` rounds of splitting (0 = none: only the
        /// corner groups for smooth shading are worked out). The textures are shared, not copied.</summary>
        public static RoomUnit Smooth(RoomUnit u, int levels, float creaseDeg, float minMove, int maxTris, out Stats st)
        {
            var sw = Stopwatch.StartNew(); st = new Stats();
            st.TrisBefore = u.T.Length / 3; st.VertsBefore = u.V.Length / 3;
            float cosCrease = (float)Math.Cos(creaseDeg * Math.PI / 180.0);
            RoomUnit cur = u; float[] carried = null;
            for (int l = 0; l < levels; l++)
            {
                var t = Analyse(cur, cosCrease, carried);
                float[] nextN;
                var nxt = SplitOnce(cur, t, minMove, st, out nextN);
                if (nxt == null) break;
                if (maxTris > 0 && nxt.T.Length / 3 > maxTris) { st.Note = "stopped at the triangle ceiling"; break; }
                cur = nxt; carried = nextN; st.Levels = l + 1;
            }
            var ft = Analyse(cur, cosCrease, carried);
            RoomUnit res = cur;
            if (ReferenceEquals(cur, u)) { res = Shell(u); res.V = u.V; res.UV = u.UV; res.T = u.T; res.TexIdx = u.TexIdx; res.TriPart = u.TriPart; res.PartVFirst = u.PartVFirst; res.PartVCount = u.PartVCount; }
            res.CornerGroup = ft.CornerGroup; res.GroupCount = ft.GroupCount;
            st.TrisAfter = res.T.Length / 3; st.VertsAfter = res.V.Length / 3; st.Ms = sw.Elapsed.TotalMilliseconds;
            return res;
        }

        // ---- checks, for the test script ------------------------------------------------------
        /// <summary>Open borders of the DRAWN surface, as a count of edges used by exactly one
        /// triangle (matched by position). Splitting must never change this number.</summary>
        public static int BorderEdges(RoomUnit u)
        {
            var wd = new Dictionary<Key, int>(); int nv = u.V.Length / 3; var w = new int[nv];
            for (int i = 0; i < nv; i++)
            {
                var k = new Key { P = 0, X = (int)Math.Round(u.V[i * 3] * 200.0), Y = (int)Math.Round(u.V[i * 3 + 1] * 200.0), Z = (int)Math.Round(u.V[i * 3 + 2] * 200.0) };
                int id; if (!wd.TryGetValue(k, out id)) { id = wd.Count; wd[k] = id; } w[i] = id;
            }
            var cnt = new Dictionary<long, int>();
            for (int f = 0; f < u.T.Length / 3; f++)
            {
                if (u.TexIdx[f] < 0) continue;
                for (int k = 0; k < 3; k++)
                {
                    int a = w[u.T[f * 3 + k]], b = w[u.T[f * 3 + (k + 1) % 3]]; if (a == b) continue;
                    long key = a < b ? ((long)a << 32) | (uint)b : ((long)b << 32) | (uint)a; int c; cnt.TryGetValue(key, out c); cnt[key] = c + 1;
                }
            }
            int n = 0; foreach (var kv in cnt) if (kv.Value == 1) n++;
            return n;
        }

        /// <summary>Is every vertex of every triangle inside its part's range, and are the ranges disjoint?</summary>
        public static string CheckParts(RoomUnit u)
        {
            int nv = u.V.Length / 3; var own = new int[nv]; for (int i = 0; i < nv; i++) own[i] = -1;
            for (int p = 0; p < u.PartName.Length; p++)
            {
                int a = u.PartVFirst[p], b = a + u.PartVCount[p]; if (a < 0 || b > nv) return "part " + u.PartName[p] + " runs off the vertex list";
                for (int k = a; k < b; k++) { if (own[k] != -1) return "parts " + u.PartName[own[k]] + " and " + u.PartName[p] + " overlap"; own[k] = p; }
            }
            for (int f = 0; f < u.T.Length / 3; f++)
            {
                int p = u.TriPart[f]; if (p < 0) continue;
                for (int k = 0; k < 3; k++) { int v = u.T[f * 3 + k]; if (v < 0 || v >= nv) return "triangle " + f + " points off the vertex list"; }
            }
            return "";
        }
    }
}
