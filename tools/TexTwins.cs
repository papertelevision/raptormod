// TexTwins.cs -- SHARED ART (2026-10-12, [[azrael-texture-repair]] "Shared art out of step"): one original picture under
// several texture leaves, and which of those leaves should show a twin's NEW art.
//
// The exporter writes one PNG per unit that holds a picture, so the SAME original turns up under several leaves (MINEMAZE's
// 03-baptapce is BAPTIST's 00-baptapce, byte for byte), and replacement art goes in by leaf. Josh's new art for one room
// therefore left the same picture in other rooms on the old upscale: 382 copies in 93 rooms on 2026-10-12. This finds, for
// every leaf whose replacement is the OLD UPSCALE (or missing), a twin with NEW art, and LoadRoom.ps1's Add-AztRgb loads the
// twin's file instead -- colour, companion maps and the Normal tier's 2K copy alike. Nothing is copied.
//   * Twins = originals with the same MD5.
//   * OLD UPSCALE = exactly 4x the original both ways. Every Real-ESRGAN file (Upscale-All, 2026-10-05) is; none of Josh's is
//     (measured 2026-10-12: 2,153 at 4x, 273 at 8-64x -- his go in at 4096 on the long side). So a redraw installed at
//     exactly 4x (a 512 original at 2048) would read as an upscale: install redraws at 4096.
//   * A leaf with new art of its own keeps it, whatever its twins have: Josh's per-room redraws are never overridden.
//   * Several twins with new art (per-room redraws of one picture): the one in the room most like this leaf's -- the most
//     original pictures in common, so SPAROOM3 takes SPAROOM's, HINEAZF MINEHEAD's, ORERYL5 ORRERY's -- then the newer file.
//   * Not for a picture of one flat colour (the n_black family): the new art cannot show anything there, and a 4096 square
//     of black is ~85 MB of memory a texture.
// Cached in an index file beside the originals (one per art folder), keyed by a stamp of the originals, the .mtl files and
// the art folder as they are LISTED (names, sizes, times: a few ms, nothing read); when the stamp moves, only what changed
// is read again (the MD5 of a new original, the size of new art).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace AztTool
{
    public static class TexTwins
    {
        public const string Version = "twins-1";
        public sealed class Pair { public string Leaf, Twin; public bool Flat; public int Score; }
        /// <summary>The last Load's decisions: every leaf on old art that has a twin with new art (Flat = left as it is).</summary>
        public static List<Pair> LastPairs = new List<Pair>();
        public static string LastNote = "", LastStamp = "";

        static readonly StringComparer K = StringComparer.OrdinalIgnoreCase;
        static readonly CultureInfo C = CultureInfo.InvariantCulture;

        // an exported original: "NN-name.png" (the leaf is the name without ".png")
        static bool IsOriginal(string n)
        {
            return n.Length > 7 && n[0] >= '0' && n[0] <= '9' && n[1] >= '0' && n[1] <= '9' && n[2] == '-' && n.EndsWith(".png", StringComparison.OrdinalIgnoreCase);
        }

        public static string IndexPath(string origDir, string artDir)
        {
            return Path.Combine(origDir, "texture-twins-" + new DirectoryInfo(artDir).Name.ToLowerInvariant() + ".tsv");
        }

        /// <summary>What the index depends on, as the folders list it: count, total size and summed times of the originals, of
        /// the .mtl files and of the art folder's PNGs. A file added, removed, rewritten or put back from a backup moves it.</summary>
        public static string Stamp(string origDir, string artDir)
        {
            long nO = 0, sO = 0, tO = 0, nM = 0, sM = 0, tM = 0, nA = 0, sA = 0, tA = 0;
            unchecked
            {
                foreach (var f in new DirectoryInfo(origDir).EnumerateFiles())
                {
                    string n = f.Name;
                    if (IsOriginal(n)) { nO++; sO += f.Length; tO += f.LastWriteTimeUtc.Ticks; }
                    else if (n.EndsWith(".mtl", StringComparison.OrdinalIgnoreCase)) { nM++; sM += f.Length; tM += f.LastWriteTimeUtc.Ticks; }
                }
                foreach (var f in new DirectoryInfo(artDir).EnumerateFiles("*.png")) { nA++; sA += f.Length; tA += f.LastWriteTimeUtc.Ticks; }
            }
            return string.Format(C, "{0}|{1}|o {2} {3} {4}|m {5} {6} {7}|a {8} {9} {10}", Version, Path.GetFullPath(artDir).TrimEnd('\\').ToLowerInvariant(),
                nO, sO, tO, nM, sM, tM, nA, sA, tA);
        }

        static int[] PngSize(byte[] b)
        {
            if (b == null || b.Length < 24) return new[] { 0, 0 };
            return new[] { (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19], (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23] };
        }
        static int[] PngSize(string path)
        {
            try { using (var f = File.OpenRead(path)) { var b = new byte[24]; return f.Read(b, 0, 24) < 24 ? new[] { 0, 0 } : PngSize(b); } }
            catch { return new[] { 0, 0 }; }
        }
        // every pixel the same colour
        static bool IsFlat(string path)
        {
            try
            {
                using (var bm = new Bitmap(path))
                {
                    int w = bm.Width, h = bm.Height;
                    var bd = bm.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                    var px = new int[w * h];
                    try { Marshal.Copy(bd.Scan0, px, 0, px.Length); } finally { bm.UnlockBits(bd); }
                    for (int i = 1; i < px.Length; i++) if (px[i] != px[0]) return false;
                    return true;
                }
            }
            catch { return false; }
        }

        /// <summary>leaf -> the twin leaf whose art (in artDir) it should show; empty when nothing applies. From the index file
        /// when its stamp still holds, else worked out again (and the index rewritten).</summary>
        public static Dictionary<string, string> Load(string origDir, string artDir)
        {
            var sw = Stopwatch.StartNew();
            string stamp = Stamp(origDir, artDir), idx = IndexPath(origDir, artDir);
            var map = new Dictionary<string, string>(K);
            var pairs = new List<Pair>();
            var oldO = new Dictionary<string, string[]>(K); var oldA = new Dictionary<string, string[]>(K);
            string[] lines = null;
            try { if (File.Exists(idx)) lines = File.ReadAllLines(idx); } catch { lines = null; }
            if (lines != null && lines.Length > 0)
            {
                bool same = lines[0] == "#" + stamp;
                foreach (var l in lines)
                {
                    var c = l.Split('\t');
                    if (c[0] == "O" && c.Length >= 8) oldO[c[1]] = c;
                    else if (c[0] == "A" && c.Length >= 6) oldA[c[1]] = c;
                    else if (same && (c[0] == "T" || c[0] == "F") && c.Length >= 4)
                    {
                        var p = new Pair(); p.Leaf = c[1]; p.Twin = c[2]; p.Flat = c[0] == "F"; p.Score = int.Parse(c[3], C);
                        pairs.Add(p); if (!p.Flat) map[p.Leaf] = p.Twin;
                    }
                }
                if (same)
                {
                    LastPairs = pairs; LastStamp = stamp;
                    LastNote = string.Format(C, "{0} leaves show a twin's new art ({1} flat-colour ones left); from {2}, {3} ms", map.Count, pairs.Count - map.Count, idx, sw.ElapsedMilliseconds);
                    return map;
                }
            }

            // 1. the originals: what picture each leaf is (MD5) and its size -- read again only for a file whose size or time moved
            int hashed = 0, sized = 0, decoded = 0;
            var md5 = new Dictionary<string, string>(K); var osz = new Dictionary<string, int[]>(K); var flat = new Dictionary<string, int>(K);
            var olt = new Dictionary<string, string[]>(K);      // (its size and time, as listed)
            using (var h = MD5.Create())
            {
                foreach (var f in new DirectoryInfo(origDir).EnumerateFiles())
                {
                    if (!IsOriginal(f.Name)) continue;
                    string leaf = f.Name.Substring(0, f.Name.Length - 4), len = f.Length.ToString(C), tk = f.LastWriteTimeUtc.Ticks.ToString(C);
                    olt[leaf] = new[] { len, tk };
                    string[] c;
                    if (oldO.TryGetValue(leaf, out c) && c[2] == len && c[3] == tk)
                    {
                        md5[leaf] = c[4]; osz[leaf] = new[] { int.Parse(c[5], C), int.Parse(c[6], C) }; flat[leaf] = int.Parse(c[7], C);
                    }
                    else
                    {
                        byte[] b = File.ReadAllBytes(f.FullName); hashed++;
                        md5[leaf] = BitConverter.ToString(h.ComputeHash(b)).Replace("-", ""); osz[leaf] = PngSize(b); flat[leaf] = -1;
                    }
                }
            }
            // 2. the art folder: each leaf's replacement and its size (header only)
            var art = new Dictionary<string, FileInfo>(K); var asz = new Dictionary<string, int[]>(K);
            foreach (var f in new DirectoryInfo(artDir).EnumerateFiles("*.png"))
            {
                string leaf = f.Name.Substring(0, f.Name.Length - 4);
                if (!md5.ContainsKey(leaf)) continue;      // (companion maps, strays)
                art[leaf] = f;
                string[] c;
                if (oldA.TryGetValue(leaf, out c) && c[2] == f.Length.ToString(C) && c[3] == f.LastWriteTimeUtc.Ticks.ToString(C)) asz[leaf] = new[] { int.Parse(c[4], C), int.Parse(c[5], C) };
                else { asz[leaf] = PngSize(f.FullName); sized++; }
            }
            // 3. the rooms each leaf is in, and the pictures each room holds (its .mtl)
            var use = new Dictionary<string, List<string>>(K); var pics = new Dictionary<string, HashSet<string>>(K);
            foreach (var f in new DirectoryInfo(origDir).EnumerateFiles("*.mtl"))
            {
                string room = Path.GetFileNameWithoutExtension(f.Name); var set = new HashSet<string>();
                foreach (var l in File.ReadLines(f.FullName))
                {
                    string s = l.Trim(); if (!s.StartsWith("map_Kd ", StringComparison.Ordinal)) continue;
                    string leaf = Path.GetFileNameWithoutExtension(s.Substring(7).Trim()); string m;
                    if (md5.TryGetValue(leaf, out m)) set.Add(m);
                    List<string> u; if (!use.TryGetValue(leaf, out u)) { u = new List<string>(); use[leaf] = u; }
                    if (!u.Contains(room)) u.Add(room);
                }
                pics[room] = set;
            }
            // 4. the twins: per picture, which leaves have NEW art (not exactly 4x the original: not the old upscale)
            var groups = new Dictionary<string, List<string>>();
            foreach (var kv in md5) { List<string> g; if (!groups.TryGetValue(kv.Value, out g)) { g = new List<string>(); groups[kv.Value] = g; } g.Add(kv.Key); }
            var overlap = new Dictionary<string, int>();
            foreach (var g in groups.Values)
            {
                if (g.Count < 2) continue;
                g.Sort(StringComparer.Ordinal);
                var fresh = new List<string>();
                foreach (var l in g) if (IsNewArt(l, art, asz, osz)) fresh.Add(l);
                if (fresh.Count == 0) continue;
                foreach (var l in g)
                {
                    if (IsNewArt(l, art, asz, osz)) continue;
                    string best = null; int bs = -1; long bt = long.MinValue;
                    foreach (var t in fresh)
                    {
                        int sc = Overlap(l, t, use, pics, overlap); long tt = art[t].LastWriteTimeUtc.Ticks;
                        if (sc > bs || (sc == bs && tt > bt)) { best = t; bs = sc; bt = tt; }
                    }
                    if (flat[l] < 0) { flat[l] = IsFlat(Path.Combine(origDir, l + ".png")) ? 1 : 0; decoded++; }
                    var p = new Pair(); p.Leaf = l; p.Twin = best; p.Flat = flat[l] == 1; p.Score = bs;
                    pairs.Add(p); if (!p.Flat) map[l] = best;
                }
            }
            // 5. the index: the stamp, what was read (so the next rebuild reads only what changed), the decisions
            var outL = new List<string>(); outL.Add("#" + stamp);
            outL.Add("# TexTwins.cs: O leaf len ticks md5 w h flat(-1 unknown) | A leaf len ticks w h (the art's size) | T leaf twin score (shows the twin's art) | F leaf twin score (flat colour: left)");
            var keys = new List<string>(md5.Keys); keys.Sort(StringComparer.Ordinal);
            foreach (var leaf in keys)
            {
                var o = osz[leaf];
                outL.Add(string.Join("\t", new[] { "O", leaf, olt[leaf][0], olt[leaf][1], md5[leaf], o[0].ToString(C), o[1].ToString(C), flat[leaf].ToString(C) }));
            }
            foreach (var leaf in keys)
            {
                FileInfo f; if (!art.TryGetValue(leaf, out f)) continue; var a = asz[leaf];
                outL.Add(string.Join("\t", new[] { "A", leaf, f.Length.ToString(C), f.LastWriteTimeUtc.Ticks.ToString(C), a[0].ToString(C), a[1].ToString(C) }));
            }
            foreach (var p in pairs) outL.Add(string.Join("\t", new[] { p.Flat ? "F" : "T", p.Leaf, p.Twin, p.Score.ToString(C) }));
            string tmp = idx + "." + Process.GetCurrentProcess().Id.ToString(C) + ".part";
            try
            {
                File.WriteAllLines(tmp, outL);
                if (File.Exists(idx)) File.Replace(tmp, idx, null); else File.Move(tmp, idx);
            }
            catch { try { File.Delete(tmp); } catch { } }      // (an index that cannot be written costs only the next rebuild)
            LastPairs = pairs; LastStamp = stamp;
            LastNote = string.Format(C, "{0} leaves show a twin's new art ({1} flat-colour ones left); index rebuilt in {2} ms ({3} originals hashed, {4} art sizes read, {5} decoded)",
                map.Count, pairs.Count - map.Count, sw.ElapsedMilliseconds, hashed, sized, decoded);
            return map;
        }

        static bool IsNewArt(string leaf, Dictionary<string, FileInfo> art, Dictionary<string, int[]> asz, Dictionary<string, int[]> osz)
        {
            if (!art.ContainsKey(leaf)) return false;
            int[] a = asz[leaf], o = osz[leaf];
            if (a[0] <= 0 || o[0] <= 0) return false;
            return !(a[0] == 4 * o[0] && a[1] == 4 * o[1]);
        }

        // the most pictures any room holding `leaf` has in common with any room holding `twin`
        static int Overlap(string leaf, string twin, Dictionary<string, List<string>> use, Dictionary<string, HashSet<string>> pics, Dictionary<string, int> memo)
        {
            List<string> ra, rb; if (!use.TryGetValue(leaf, out ra) || !use.TryGetValue(twin, out rb)) return 0;
            int best = 0;
            foreach (var a in ra) foreach (var b in rb)
            {
                string key = string.CompareOrdinal(a, b) < 0 ? a + "|" + b : b + "|" + a; int n;
                if (!memo.TryGetValue(key, out n))
                {
                    HashSet<string> pa, pb; n = 0;
                    if (pics.TryGetValue(a, out pa) && pics.TryGetValue(b, out pb)) { if (pa.Count > pb.Count) { var x = pa; pa = pb; pb = x; } foreach (var m in pa) if (pb.Contains(m)) n++; }
                    memo[key] = n;
                }
                if (n > best) best = n;
            }
            return best;
        }
    }
}
