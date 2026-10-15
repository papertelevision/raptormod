// ScanWire.cs -- the scanner's wireframe, drawn by the host (Josh, 2026-10-07).
//
// When the player scans a creature or character, the game plays a ten-frame bitmap of a "wireframe" turning
// round (WIRE\<name>00..09.PCX) in the top-left corner of the view, the creature walking as it turns. In the
// true-colour game this draws the REAL model instead: the character's own rig (<name>.XAF), posed from its own
// keyframes and walking its own WALK cycle (the .ANI's frame range), as a revolving vector wireframe in the style
// of the boot's chalice -- every edge, teal with a glow, the far side dimmer.
//
// HOW THE GAME DOES IT (R.EXE, found 2026-10-07):
//   0x17690(eax = name)  loads name00..09 from "%swire\%s%02d.pcx" into ten 140x120 surfaces at 0x152918
//                        (18 bytes each: word w, word h, dword pixels), draws a 1-px frame round each, then
//                        counter [0x1529CE] = 0, flag [0x1529CC] = 1 (0x17790); on failure flag = 0.
//   0x14FE8 (each frame) if flag: blit surface (counter mod 10) into the VIEW buffer 0x152150 at (20, 40);
//                        inc counter; when it passes 100, flag = 0. PER FRAME, no clock: at the stock 24 fps a scan
//                        is ~4.2 s, but the host renderer lifts the frame cap and the guest runs at 100-300 fps,
//                        so a scan was over in 0.3-1 s (what broke the first version). The HOST therefore holds
//                        the counter to the wall clock at ScanHz (HoldScan), for every scan, ours or not.
//   Other code clears the flag to cancel a scan (room changes, menus: 0x111E8, 0x129C9, 0x15CBE, 0x2FBBE ...);
//   the host never writes the flag, so all of those still work.
//   Callers: 0x2BE30 (characters: the object's own name, e.g. RAPTOR), 0x2BC3C (items, via WIRESCAN.RES).
// The name is a stack temporary, so WHICH set is playing is told by comparing the first loaded frame with the
// game's own WIRE\<name>00.PCX. Only sets with a rig are replaced; anything else is left to the game's bitmaps.
//
// THE RIG (.XAF, plain text): nested `object "NAME" { matrix {16} mesh { vertices {} faces { n, v,t, ... 0 } } }`
// with row-vector matrices composed child-then-parent (W = M * W_parent, v' = v * W -- as Export-XafObj), and an
// `animation_set` of per-object rotate_keys (t, w,x,y,z), scale_keys (t, x,y,z), position_keys (t, x,y,z) by frame.
// Frame 0 reproduces every rest matrix, which is how the quaternion convention is CHECKED at load (RigCheck).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace AztTool
{
    /// <summary>CRISP VISOR TEXT (Josh, 2026-10-15: "Any reason why fonts are blurry in these visor scans and other visor text?").
    /// GDI+ only hints a font at a WHOLE pixel size, and only lands a glyph's stems on pixels when it starts on one: the visor's
    /// sizes were fractions of the view (vr / 58 = 26.48 px) and its text sat at fractional places (centred, scaled), so every
    /// letter came out half a pixel soft. Every visor font and every DrawString goes through here: sizes and positions rounded.
    /// (The boot learned the same lesson: [[azrael-boot-text-rasteriser]].)</summary>
    static class Crisp
    {
        public static Font Font(float em, FontStyle style) { return new Font("Consolas", Math.Max(1f, (float)Math.Round(em)), style, GraphicsUnit.Pixel); }
        public static Font Font(double em, FontStyle style) { return Font((float)em, style); }
        static float R(float v) { return (float)Math.Round(v); }
        public static void Text(Graphics g, string s, Font f, Brush b, float x, float y) { g.DrawString(s, f, b, R(x), R(y)); }
        public static void Text(Graphics g, string s, Font f, Brush b, float x, float y, StringFormat sf) { g.DrawString(s, f, b, R(x), R(y), sf); }
    }
    public class ScanWire
    {
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
        [DllImport("winmm.dll")] static extern int timeBeginPeriod(int ms);
        [DllImport("winmm.dll")] static extern int timeEndPeriod(int ms);

        const int A_FLAG = 0x1529CC, A_COUNT = 0x1529CE, A_SURF = 0x152918, FW = 140, FH = 120;
        // WHO is scanned (0x2BE30 does the same): [0x1521B4] -> the target's name string, "ZZ" + its id in digits (atoi
        // from +2); the actor table at 0x1521C4 has 0x6F buckets at +2, each a list of { next, name ptr, id ptr }.
        const int A_TARGET = 0x1521B4, A_ACTORS = 0x1521C4;
        /// <summary>Where the game draws its wire frame in the VIEW (game px): x0, y0, x1, y1.</summary>
        public static readonly int[] GameRect = { 20, 40, 20 + FW, 40 + FH };

        // ==== THE RIG =================================================================================
        class Bone
        {
            public string Name; public int Parent = -1; public double[] Rest; public float[] V; public int[] Edge; public int[] Tri;      // (Tri: the faces, for the player's shadow body)
            public double[] RotT, Rot, SclT, Scl, PosT, Pos;      // keys: times, and 4 (w,x,y,z) or 3 values each
        }
        class Rig
        {
            public int ExtraFrom = -1, ExtraTo = -1;     // a second clip played after the walk (SetExtra), -1 = none
            public string Name, Key; public Bone[] Bones; public bool[] Mask; public bool Transpose;      // (Key: the .XAF file's size and date, for the start-angle cache)
            public List<bool[]> Frames = new List<bool[]>();     // the game's ten frames (ink masks), for AutoPhase
            public double From, To;                               // the WALK cycle (frame To == frame From)
            public double RestFrom, RestTo;                       // the REST (idle) range, for the player's body
            public double Cx, Cy, Cz, H, R;                       // the cycle's middle, height and reach round the upright (for scaling)
            public int Edges, Verts;
            public double Phase;                                  // the turn it starts at, to begin where the game's frames do (AutoPhase)
            public int Dir = 1;                                   // and which way it turns (the game's frames are not all the same way round)
            public bool IsItem;                                   // an item set: drawn from the game's frames, no mesh
            public Bitmap[] Ink, Glow;                            // (its frames as line art in the scan's inks, made at first draw)
        }
        readonly Dictionary<string, Rig> _rigs = new Dictionary<string, Rig>(StringComparer.OrdinalIgnoreCase);
        public string LastError = "";
        /// <summary>What the last Add found (bones, edges, the quaternion check), for the log.</summary>
        public string RigInfo = "";
        public int Count { get { return _rigs.Count; } }
        // ---- THE CHARACTERS: a character definition's name (KURTB) -> the rig it uses (its .ANI's FILE) and the scan's
        // text (its entry in DESCRIPT.ZAP, NAME.DES -- what the game prints in the log when it is scanned)
        class CharInfo { public string Rig, Text; }
        readonly Dictionary<string, CharInfo> _chars = new Dictionary<string, CharInfo>(StringComparer.OrdinalIgnoreCase);
        /// <summary>Register a character: its definition's name, the rig set it uses (as added), and its scan text (or null).</summary>
        public void AddCharacter(string name, string rig, string text) { _chars[name] = new CharInfo { Rig = rig, Text = text }; }
        public int Characters { get { return _chars.Count; } }

        // ==== ITEMS (Josh, 2026-10-08: batch 2) ========================================================================
        // An item's frames say WHICH set is showing (GAME\AZRAEL\WIRESCAN.RES, the game's item -> set table; one set, e.g.
        // BISC, serves 24 different objects), and the game's pick says WHICH OBJECT: [0x1521B4] is the picked frame's name,
        // 'ZZnnnn' for a character, the room part's own name for an object (e.g. 'flask03'); its text is the OBJECTS.DAT
        // record naming that part (+0x78) or object (+0x3C) -- 603-byte records after a 2-byte count, display name +0, scan
        // text +0xCB -- settled by the hovered object's shown name where a part name repeats between rooms.
        // DRAWN FROM THE GAME'S OWN FRAMES, not a mesh: the rooms' models of the items are stand-ins (the inkwell, key, gun,
        // ammo bag and Claude's shield are flat textured cards, the flasks bare pyramids without their labels), while the
        // scan frames were rendered from detailed models that never shipped. Each frame is drawn large and smooth in the
        // scan's inks, held, and cross-faded to the next as it turns (a turn in 2*pi/Spin s, like the characters).
        readonly Dictionary<string, Rig> _itemSets = new Dictionary<string, Rig>(StringComparer.OrdinalIgnoreCase);
        /// <summary>Register an item set by its frames alone (the mesh is found per scan).</summary>
        public bool AddItem(string name, string[] frames)
        {
            try
            {
                var r = new Rig { Name = name, IsItem = true, Bones = new Bone[0] };
                int pw, ph;
                foreach (var fk in frames)
                {
                    var pk = ReadPcx8(fk, out pw, out ph); if (pw != FW || ph != FH) break;
                    var mk = new bool[FW * FH]; for (int i = 0; i < FW * FH; i++) mk[i] = pk[i] != 0; r.Frames.Add(mk);
                }
                if (r.Frames.Count == 0) throw new Exception("no 140x120 frames");
                r.Mask = r.Frames[0]; _itemSets[name] = r; return true;
            }
            catch (Exception e) { LastError = name + ": " + e.Message; return false; }
        }
        public int Items { get { return _itemSets.Count; } }
        class ObjInfo { public string Obj, Part, Display, Text; public int Action; }
        readonly Dictionary<string, List<ObjInfo>> _objs = new Dictionary<string, List<ObjInfo>>(StringComparer.OrdinalIgnoreCase);
        /// <summary>Read GAME\AZRAEL\OBJECTS.DAT: every object's name, room part and scan text. Returns the count.</summary>
        public int LoadObjects(string path)
        {
            var b = File.ReadAllBytes(path); int n = BitConverter.ToUInt16(b, 0), got = 0;
            Func<int, int, string> z = (o, max) => { int e = o; while (e < o + max && e < b.Length && b[e] != 0) e++; return System.Text.Encoding.ASCII.GetString(b, o, e - o); };
            for (int i = 0; i < n; i++)
            {
                int r = 2 + i * 603; if (r + 603 > b.Length) break;
                var oi = new ObjInfo { Display = z(r, 0x3C).Trim(), Obj = z(r + 0x3C, 0x3B).Trim(), Part = z(r + 0x78, 0x10).Trim(), Text = z(r + 0xCB, 0x100).Trim(), Action = b[r + 0xBA] };
                foreach (var key in new[] { oi.Part, oi.Obj })
                {
                    if (string.IsNullOrEmpty(key)) continue;
                    List<ObjInfo> l; if (!_objs.TryGetValue(key, out l)) _objs[key] = l = new List<ObjInfo>();
                    l.Add(oi);
                }
                got++;
            }
            return got;
        }
        /// <summary>Is this a part the game knows as an object (OBJECTS.DAT's room part or object name) -- something to take
        /// or use (the echo scan's items)?</summary>
        public bool IsObjectPart(string part) { return !string.IsNullOrEmpty(part) && _objs.ContainsKey(part); }
        /// <summary>Can this part be PICKED UP? OBJECTS.DAT's action byte (+0xBA) is 6 = take (2026-10-15: the 111 such records are
        /// exactly the pickups -- keys, flasks, parchments, scrolls, the gun and its ammo, shields, tapestry pieces, wafers, wax...;
        /// 7 = open (doors, chests), 3 = pull (levers, buttons), 4 = turn (wheels, winches), 8 = use, 1 = climb, 0 = scenery).</summary>
        public bool IsTakePart(string part)
        {
            List<ObjInfo> l; if (string.IsNullOrEmpty(part) || !_objs.TryGetValue(part, out l)) return false;
            foreach (var o in l) if (o.Action == 6) return true;
            return false;
        }
        /// <summary>The "open" objects (action 7) that are MECHANISMS -- the rest of 7 is doors, tables, books, barrels...</summary>
        public string MechanismNames = @"(?i)handle|hatch|bolt|millstone|cullis|pipe|ribbing|shield slot|stone head";
        /// <summary>Is this part an INTERACTIVE object (Josh, 2026-10-15: "a mechanical handle or lever for example")? Action 3
        /// (pull: levers, buttons), 4 (turn: wheels, winches, a stop cock, a mirror), 8 (use: bolts, chains, hooks, pins, rope,
        /// an altar, the oven tray), or 7 (open) when its name is a mechanism (MechanismNames). Pickups are not (IsTakePart).</summary>
        public bool IsInteractivePart(string part)
        {
            List<ObjInfo> l; if (string.IsNullOrEmpty(part) || !_objs.TryGetValue(part, out l)) return false;
            foreach (var o in l)
            {
                if (o.Action == 3 || o.Action == 4 || o.Action == 8) return true;
                if (o.Action == 7 && System.Text.RegularExpressions.Regex.IsMatch(o.Display ?? "", MechanismNames)) return true;
            }
            return false;
        }
        ObjInfo ObjectFor(string picked, string display = null)
        {
            List<ObjInfo> l; if (picked == null || !_objs.TryGetValue(picked, out l) || l.Count == 0) return null;
            // a part name can be shared between rooms ('flask01' is Essence in one, Aqua Fortis in another): the name the
            // game shows for the hovered object settles it
            if (!string.IsNullOrEmpty(display)) foreach (var o in l) if (string.Equals(o.Display, display, StringComparison.OrdinalIgnoreCase) && o.Text.Length > 0) return o;
            foreach (var o in l) if (string.Equals(o.Obj, picked, StringComparison.OrdinalIgnoreCase) && o.Text.Length > 0) return o;     // (an object's own name is unique)
            foreach (var o in l) if (o.Text.Length > 0) return o;
            return l[0];
        }
        // the hovered object's name as the game shows it: word [0x146872] is its index (-1: none), [0x1841D0] the object
        // table, +0x3F the name (0x2D478 prints it)
        const long A_HOVER = 0x146872, A_OBJTAB = 0x1841D0;
        string HoveredName()
        {
            try
            {
                if (!Read(_memBase + A_HOVER + D2, _w4, 2)) return null;
                int idx = BitConverter.ToInt16(_w4, 0); if (idx < 0 || idx > 4000) return null;
                if (!Read(_memBase + A_OBJTAB + D2, _w4, 4)) return null;
                long tab = BitConverter.ToUInt32(_w4, 0); if (tab < 0x1000 || !Read(_memBase + tab + idx * 4L, _w4, 4)) return null;
                long obj = BitConverter.ToUInt32(_w4, 0); return obj < 0x1000 ? null : GuestString(obj + 0x3F);
            }
            catch { return null; }
        }
        /// <summary>The last item scan: what was picked, and what became of it (for the log).</summary>
        public string LastItem;
        /// <summary>Offline check: the text a scan of `set` picking `picked` (shown as `shown`) would print, and its readout.</summary>
        public string[] TestItem(string set, string picked, string shown)
        {
            Rig s; if (!_itemSets.TryGetValue(set, out s)) return null;
            var oi = ObjectFor(picked, shown);
            return new[] { s.Name, oi != null ? oi.Text : "", string.Join(" | ", ReadLines(s)) };
        }
        /// <summary>The character definition the last scan was of (read from the game), and how it was told.</summary>
        public string LastName, LastHow;

        /// <summary>Register a set: the rig (.XAF), the game's first frame that identifies it (WIRE\NAME00.PCX, or
        /// an extracted .png), and the frame range it walks (the .ANI's WALK).</summary>
        public bool Add(string name, string xafPath, string firstFrame, int walkFrom, int walkTo)
        {
            if (!firstFrame.EndsWith(".pcx", StringComparison.OrdinalIgnoreCase)) return AddCore(name, xafPath, null, firstFrame, walkFrom, walkTo);
            // the other nine, beside it (NAME01..09.PCX)
            var fr = new List<string> { firstFrame };
            for (int k = 1; k < 10; k++)
            {
                string fk = System.Text.RegularExpressions.Regex.Replace(firstFrame, @"00(\.pcx)$", k.ToString("00") + "$1", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (fk == firstFrame || !File.Exists(fk)) break;
                fr.Add(fk);
            }
            return AddCore(name, xafPath, fr.ToArray(), null, walkFrom, walkTo);
        }
        /// <summary>Register a set from its frames named one by one (the game's own file names are not always NAME00..09:
        /// Geoffrye's are GEFFRYE0 then GEOFF01..09). walkTo == walkFrom: a single pose, turned but not animated.</summary>
        public bool Add(string name, string xafPath, string[] frames, int walkFrom, int walkTo) { return AddCore(name, xafPath, frames, null, walkFrom, walkTo); }
        bool AddCore(string name, string xafPath, string[] frames, string png, int walkFrom, int walkTo)
        {
            try
            {
                var r = LoadXaf(xafPath); r.Name = name; r.From = walkFrom; r.To = walkTo >= walkFrom ? walkTo : walkFrom;
                if (r.Verts < 24) throw new Exception("its rig is a placeholder (" + r.Verts + " vertices: SAILOR_A.XAF is one box) -- left to the game");
                var xi = new FileInfo(xafPath); r.Key = Path.GetFileName(xafPath).ToUpperInvariant() + ":" + xi.Length + ":" + xi.LastWriteTimeUtc.Ticks;
                r.Mask = new bool[FW * FH];
                if (frames != null && frames.Length > 0)
                {
                    int pw, ph;
                    foreach (var fk in frames)
                    {
                        var pk = ReadPcx8(fk, out pw, out ph);
                        if (pw != FW || ph != FH) { if (r.Frames.Count == 0) throw new Exception("frame is " + pw + "x" + ph + ", not 140x120"); break; }
                        var mk = new bool[FW * FH]; for (int i = 0; i < FW * FH; i++) mk[i] = pk[i] != 0; r.Frames.Add(mk);
                    }
                    r.Mask = r.Frames[0];
                }
                else
                    using (var b = new Bitmap(png))
                    {
                        if (b.Width != FW || b.Height != FH) throw new Exception("frame is not 140x120");
                        for (int y = 0; y < FH; y++) for (int x = 0; x < FW; x++) { var c = b.GetPixel(x, y); r.Mask[y * FW + x] = c.R + c.G + c.B > 30; }
                    }
                double errA = RigCheck(r, false), errB = RigCheck(r, true);
                r.Transpose = errB < errA;
                Measure(r);
                _rigs[name] = r;
                RigInfo = string.Format(CultureInfo.InvariantCulture, "{0}: {1} bones, {2} vertices, {3} edges, walk {4}-{5}; frame 0 vs rest matrices {6:G3} (other convention {7:G3})",
                    name, r.Bones.Length, r.Verts, r.Edges, walkFrom, walkTo, Math.Min(errA, errB), Math.Max(errA, errB));
                // where its turn starts is worked out in the background (~2 s a rig; the watcher's attach must not wait)
                lock (_phaseQ) { _phaseQ.Enqueue(r); if (_phaseThread == null) { _phaseThread = new Thread(PhaseWork) { IsBackground = true, Name = "ScanWire phases", Priority = ThreadPriority.BelowNormal }; _phaseThread.Start(); } }
                return true;
            }
            catch (Exception e) { LastError = name + ": " + e.Message; return false; }
        }

        // WHERE TO START THE TURN: each creature's ten frames begin at their own angle (the raptor faces the eye, the
        // small dinosaur starts side-on), so the wireframe is drawn at 36 angles and the one whose silhouette best
        // matches the game's first frame is where it starts.
        // (All ten frames, as a SEQUENCE: frame i is a tenth of a turn on from frame i-1, and a tenth of the walk. One frame
        // alone cannot tell a front from a back -- it put the raptor at 210 degrees; the turn's direction and which side
        // the head and the tail come round on can.)
        double AutoPhase(Rig r, out double best)
        {
            best = -1; double at = 0; int atDir = 1; var px = new int[FW * FH]; int n = Math.Max(1, r.Frames.Count);
            for (int k = 0; k < 72; k++)
            {
                int dir = k < 36 ? 1 : -1; double ph = (k % 36) * Math.PI / 18; double sum = 0;
                for (int i = 0; i < n; i++)
                {
                    // our view i: the turn at ph + i tenths (either way round), the walk at i tenths of its cycle
                    r.Phase = ph + dir * i * 2 * Math.PI / 10;
                    var h = GCHandle.Alloc(px, GCHandleType.Pinned);
                    try
                    {
                        Array.Clear(px, 0, px.Length);
                        using (var bm = new Bitmap(FW, FH, FW * 4, PixelFormat.Format32bppRgb, h.AddrOfPinnedObject()))
                        using (var g = Graphics.FromImage(bm)) DrawPose(g, r, 2, 2, FW - 4, FH - 4, 1, r.From + (r.To - r.From) * i / 10.0, 0, 2.5f);
                    }
                    finally { h.Free(); }
                    var game = r.Frames.Count > 0 ? r.Frames[i] : r.Mask;
                    int inter = 0, uni = 0;
                    for (int y = 2; y < FH - 2; y++) for (int x = 2; x < FW - 2; x++)
                    { bool a = (px[y * FW + x] & 0xFFFFFF) != 0, b = game[y * FW + x]; if (a || b) uni++; if (a && b) inter++; }
                    sum += uni > 0 ? inter / (double)uni : 0;
                }
                double s = sum / n;
                if (s > best) { best = s; at = ph; atDir = dir; }
            }
            r.Phase = at; r.Dir = atDir;
            return at;
        }
        readonly Queue<Rig> _phaseQ = new Queue<Rig>(); Thread _phaseThread;
        /// <summary>A file where the start angles found are kept (a few lines; ~2.5 s of work a set, so they are worked out
        /// once, not on every launch). Null: not kept.</summary>
        public string PhaseCache;
        readonly object _cacheLock = new object();
        bool CacheGet(string key, out double ph, out int dir, out double iou)
        {
            ph = 0; dir = 1; iou = 0;
            try
            {
                lock (_cacheLock)
                {
                    if (string.IsNullOrEmpty(PhaseCache) || !File.Exists(PhaseCache)) return false;
                    foreach (var ln in File.ReadAllLines(PhaseCache))
                    {
                        var p = ln.Split('\t'); if (p.Length < 4 || p[0] != key) continue;
                        ph = double.Parse(p[1], CultureInfo.InvariantCulture); dir = int.Parse(p[2], CultureInfo.InvariantCulture); iou = double.Parse(p[3], CultureInfo.InvariantCulture);
                        return true;
                    }
                }
            }
            catch { }
            return false;
        }
        void CachePut(string key, double ph, int dir, double iou)
        {
            try { lock (_cacheLock) { if (!string.IsNullOrEmpty(PhaseCache)) File.AppendAllText(PhaseCache, string.Format(CultureInfo.InvariantCulture, "{0}\t{1:R}\t{2}\t{3:0.0000}\r\n", key, ph, dir, iou)); } }
            catch { }
        }
        /// <summary>What the background alignment found, a line per rig (for the log).</summary>
        public readonly System.Collections.Concurrent.ConcurrentQueue<string> PhaseNotes = new System.Collections.Concurrent.ConcurrentQueue<string>();
        void PhaseWork()
        {
            while (true)
            {
                Rig r; lock (_phaseQ) { if (_phaseQ.Count == 0) { _phaseThread = null; return; } r = _phaseQ.Dequeue(); }
                try
                {
                    // worked on a COPY of the turn settings, then set at once: a scan meanwhile draws at 0 degrees, never half-way
                    string key = r.Name + "|" + r.Key + "|" + r.From.ToString(CultureInfo.InvariantCulture) + "-" + r.To.ToString(CultureInfo.InvariantCulture) + "|" + r.Frames.Count + "|v2";
                    double ph, iou; int dir;
                    if (CacheGet(key, out ph, out dir, out iou)) { r.Dir = dir; r.Phase = ph; PhaseNotes.Enqueue(string.Format(CultureInfo.InvariantCulture, "{0} starts at {1:0} deg turning {2} (silhouette match {3:0.00}, remembered)", r.Name, ph * 180 / Math.PI, dir > 0 ? "+" : "-", iou)); continue; }
                    var probe = new Rig { Name = r.Name, Bones = r.Bones, Mask = r.Mask, Transpose = r.Transpose, Frames = r.Frames, From = r.From, To = r.To, Cx = r.Cx, Cy = r.Cy, Cz = r.Cz, H = r.H, R = r.R };
                    ph = AutoPhase(probe, out iou);
                    r.Dir = probe.Dir; r.Phase = ph; CachePut(key, ph, r.Dir, iou);
                    PhaseNotes.Enqueue(string.Format(CultureInfo.InvariantCulture, "{0} starts at {1:0} deg turning {2} (silhouette match {3:0.00} over {4} frames)", r.Name, ph * 180 / Math.PI, r.Dir > 0 ? "+" : "-", iou, r.Frames.Count));
                }
                catch (Exception e) { PhaseNotes.Enqueue(r.Name + ": alignment failed, " + e.Message); }
            }
        }
        // ==== THE PLAYER'S SHADOW BODY (Josh, 2026-10-07: "player shadows ... use the raptor mesh to cast these shadows ... cast
        // from room lights"). The player is the camera -- there is no body. This poses the raptor's rig, walking or idling, and
        // hands its triangles in world space to the GPU's placed-light shadow views only: never drawn, a silhouette for the lights.
        /// <summary>A rig for the body: no scan frames, its walk cycle and its idle range.</summary>
        public bool AddBody(string name, string xafPath, int walkFrom, int walkTo, int restFrom, int restTo)
        {
            try
            {
                var r = LoadXaf(xafPath); r.Name = name; r.From = walkFrom; r.To = walkTo > walkFrom ? walkTo : walkFrom + 1;
                r.RestFrom = restFrom; r.RestTo = restTo > restFrom ? restTo : restFrom; r.Mask = new bool[FW * FH];
                r.Transpose = RigCheck(r, true) < RigCheck(r, false);
                Measure(r); _rigs[name] = r; return true;
            }
            catch (Exception e) { LastError = name + ": " + e.Message; return false; }
        }
        /// <summary>The body's triangles (all bones).</summary>
        public int BodyTriCount(string name) { Rig r; if (!_rigs.TryGetValue(name, out r)) return 0; int n = 0; foreach (var b in r.Bones) if (b.Tri != null) n += b.Tri.Length / 3; return n; }
        /// <summary>The body's feet and eye height (rig units), and the middle it is centred on: {feetY, eyeY, cx, cz, height}.</summary>
        public double[] BodyMetrics(string name)
        {
            Rig r; if (!_rigs.TryGetValue(name, out r)) return null;
            double feet = r.Cy - r.H / 2, top = r.Cy + r.H / 2;
            return new[] { feet, top - 0.06 * r.H, r.Cx, r.Cz, r.H };
        }
        /// <summary>The body posed at `frame` and placed by `model` (a row-vector 4x4: rig -> world), into buf (9 floats a
        /// triangle). Returns how many triangles.</summary>
        public int BodyTris(string name, double frame, double[] model, float[] buf)
        {
            Rig r; if (!_rigs.TryGetValue(name, out r) || model == null || model.Length < 16) return 0;
            var W = Pose(r, frame); int n = 0; var m2 = new double[16];
            for (int i = 0; i < r.Bones.Length; i++)
            {
                var b = r.Bones[i]; if (b.Tri == null || b.Tri.Length == 0) continue;
                Mul(W[i], model, m2); var v = b.V; var m = m2;
                for (int q = 0; q + 2 < b.Tri.Length; q += 3)
                {
                    if ((n + 1) * 9 > buf.Length) return n;
                    for (int k = 0; k < 3; k++)
                    {
                        int vi = b.Tri[q + k] * 3; double x = v[vi], y = v[vi + 1], z = v[vi + 2]; int o = n * 9 + k * 3;
                        buf[o] = (float)(x * m[0] + y * m[4] + z * m[8] + m[12]); buf[o + 1] = (float)(x * m[1] + y * m[5] + z * m[9] + m[13]); buf[o + 2] = (float)(x * m[2] + y * m[6] + z * m[10] + m[14]);
                    }
                    n++;
                }
            }
            return n;
        }
        /// <summary>Where the body stands and how it moves: how far behind the eye it stands (share of its height), its
        /// facing's offset (radians: the rig faces +Z -- visor, toes, arms; checked in profile), its keyframe rate
        /// (frames/s: the game's animation tick, which the watcher reads from aztAnimPeriod), and its fixed eye height.</summary>
        public double BodyBack = 0, BodyYaw = 0, BodyAnimHz = 18.2065, BodyEyeHeight = 48;
        /// <summary>How quickly the body turns after the view (1/s) and settles onto a new floor height (1/s).</summary>
        public double BodyTurnRate = 10, BodyFloorRate = 14;
        /// <summary>Seconds for one breath standing still (Josh, 2026-10-08: the idle was 'in fast forward'). The REST range
        /// is only 4 keyframes (KURT.ANI 143-147), a fifth of a second at the animation tick. It is a closed loop (147 is
        /// 143's pose again, measured), so it is played forward once per breath, blended between keys.</summary>
        public double BodyIdleCycle = 3.5;
        /// <summary>Whole keyframes only, as the game steps its characters. Off: blended between keyframes at the same rate,
        /// which a long shadow needs -- every 1/18 s pose jump is magnified by the light's angle.</summary>
        public bool BodyStepped = false;
        double _bx = double.NaN, _bz, _walkF, _idleF, _fx = double.NaN, _fz, _floorY = double.NaN; bool _walking;
        public double BodySpeed;
        /// <summary>Once a frame: the body under the camera (`cam16`, row-vector: right, up, forward, position), stood on
        /// the floor `floorDist` below the eye, walking if the camera moved, idling if not; its triangles into buf. dt in s.
        /// STEADY ON PURPOSE (Josh, 2026-10-08: 'very jiggly'): a wall torch only a little above the body's head turns any
        /// movement into a big swing of the shadow, so the body is a FIXED size (BodyEyeHeight, the game's 48 -- never the
        /// live eye height, which the walk bob moves), its feet follow the floor not the eye, it turns after the view
        /// smoothly, and walking/standing has a dead band so it cannot flick between the two.</summary>
        public int StepBody(string name, float[] cam16, double floorDist, double dt, float[] buf)
        {
            Rig r; if (!_rigs.TryGetValue(name, out r) || cam16 == null || floorDist <= 1) return 0;
            double ex = cam16[12], ey = cam16[13], ez = cam16[14];
            dt = Math.Max(1e-3, Math.Min(0.25, dt));
            // the floor under the eye: followed quickly, but a step of a few units does not pop; a big change is a new place
            double fy = ey - floorDist;
            if (double.IsNaN(_floorY) || Math.Abs(fy - _floorY) > 40) _floorY = fy; else _floorY += (fy - _floorY) * Math.Min(1, dt * BodyFloorRate);
            // the facing: the camera's forward, flat, turned toward smoothly (kept as it was when looking straight down/up)
            double fx = cam16[8], fz = cam16[10], fl = Math.Sqrt(fx * fx + fz * fz);
            if (fl > 0.15)
            {
                fx /= fl; fz /= fl;
                if (double.IsNaN(_fx)) { _fx = fx; _fz = fz; }
                else
                {
                    double k = Math.Min(1, dt * BodyTurnRate), nx = _fx + (fx - _fx) * k, nz = _fz + (fz - _fz) * k, nl = Math.Sqrt(nx * nx + nz * nz);
                    if (nl < 1e-3) { _fx = fx; _fz = fz; } else { _fx = nx / nl; _fz = nz / nl; }
                }
            }
            if (double.IsNaN(_fx)) { _fx = 0; _fz = 1; }
            double cy = Math.Cos(BodyYaw), sy = Math.Sin(BodyYaw), ffx = _fx * cy - _fz * sy, ffz = _fx * sy + _fz * cy;
            // walking or standing: how fast the eye moved across the floor, with a dead band between the two
            double spd = double.IsNaN(_bx) ? 0 : Math.Sqrt((ex - _bx) * (ex - _bx) + (ez - _bz) * (ez - _bz)) / dt;
            _bx = ex; _bz = ez; if (spd > 400) spd = 0;      // (a jump, not a walk: a room change or a warp)
            BodySpeed += (spd - BodySpeed) * Math.Min(1, dt * 6);
            if (_walking ? BodySpeed < 15 : BodySpeed > 40) _walking = !_walking;
            double frame;
            if (_walking)
            {
                _walkF += dt * BodyAnimHz; double span = r.To - r.From;
                double wf = (_walkF % span + span) % span; frame = r.From + (BodyStepped ? Math.Floor(wf) : wf); _idleF = 0;
            }
            else
            {
                _idleF += dt / Math.Max(0.2, BodyIdleCycle);
                double br = _idleF % 1.0;                                             // once through the loop per breath
                frame = r.RestTo > r.RestFrom ? r.RestFrom + (r.RestTo - r.RestFrom) * br : r.RestFrom;
            }
            // a fixed size, its feet on the (followed) floor, under the eye
            var mt = BodyMetrics(name); double feet = mt[0], eye = mt[1], cxr = mt[2], czr = mt[3], h = mt[4];
            double s = BodyEyeHeight / Math.Max(1e-3, eye - feet);
            double bk = BodyBack * h * s, px = ex - ffx * bk, pz = ez - ffz * bk;
            var model = new double[16];
            model[0] = ffz * s; model[1] = 0; model[2] = -ffx * s;                // rig X -> across (a turn about Y, not a mirror)
            model[4] = 0; model[5] = s; model[6] = 0;                             // rig Y -> up
            model[8] = ffx * s; model[9] = 0; model[10] = ffz * s;                // rig Z (its front: visor, toes) -> the facing
            model[12] = px - (cxr * model[0] + czr * model[8]); model[13] = _floorY - feet * s; model[14] = pz - (cxr * model[2] + czr * model[10]);
            model[15] = 1;
            return BodyTris(name, frame, model, buf);
        }
        /// <summary>The rig's walk cycle and idle range (frames), for the caller's own clock.</summary>
        public double[] BodyRanges(string name) { Rig r; if (!_rigs.TryGetValue(name, out r)) return null; return new[] { r.From, r.To, r.RestFrom, r.RestTo }; }
        // ==== FOR THE VISOR BOOT (Josh, 2026-10-14: "a wireframe of the raptor, slowly revolving as a scan line slowly moves up and
        // down the body"): the rig's edges posed and turned, for BootHd to draw in the boot's own style ====
        /// <summary>The rig's edges at `frame`, turned `turn` radians about its upright, in units of its height about its middle:
        /// x across, y UP, z away from the eye. 7 floats an edge: x0 y0 z0 x1 y1 z1 and the bone's index. Returns how many.</summary>
        public int RigEdges(string name, double frame, double turn, ref float[] buf)
        {
            Rig r; if (!_rigs.TryGetValue(name, out r)) return 0;
            var W = Pose(r, frame); double cp = Math.Cos(turn), sp = Math.Sin(turn), u = 1.0 / r.H;
            if (buf == null || buf.Length < r.Edges * 7) buf = new float[r.Edges * 7];
            int n = 0; var P = new float[64 * 3];
            for (int i = 0; i < r.Bones.Length; i++)
            {
                var b = r.Bones[i]; var v = b.V; var m = W[i]; int nv = v.Length / 3;
                if (b.Edge.Length == 0) continue;
                if (P.Length < nv * 3) P = new float[nv * 3];
                for (int q = 0; q < nv; q++)
                {
                    double vx = v[q * 3], vy = v[q * 3 + 1], vz = v[q * 3 + 2];
                    double x = (vx * m[0] + vy * m[4] + vz * m[8] + m[12] - r.Cx) * u, y = (vx * m[1] + vy * m[5] + vz * m[9] + m[13] - r.Cy) * u, z = (vx * m[2] + vy * m[6] + vz * m[10] + m[14] - r.Cz) * u;
                    P[q * 3] = (float)(x * cp + z * sp); P[q * 3 + 1] = (float)y; P[q * 3 + 2] = (float)(-x * sp + z * cp);
                }
                var e = b.Edge;
                for (int q = 0; q + 1 < e.Length; q += 2)
                {
                    int a = e[q] * 3, c = e[q + 1] * 3, o = n * 7;
                    buf[o] = P[a]; buf[o + 1] = P[a + 1]; buf[o + 2] = P[a + 2]; buf[o + 3] = P[c]; buf[o + 4] = P[c + 1]; buf[o + 5] = P[c + 2]; buf[o + 6] = i;
                    n++;
                }
            }
            return n;
        }
        /// <summary>The rig's bone names, in the order RigEdges numbers them.</summary>
        public string[] RigBones(string name) { Rig r; if (!_rigs.TryGetValue(name, out r)) return null; var s = new string[r.Bones.Length]; for (int i = 0; i < s.Length; i++) s[i] = r.Bones[i].Name; return s; }
        /// <summary>How far it reaches round its upright, against its height (a long tail turning is wider than it is tall).</summary>
        public double RigReach(string name) { Rig r; if (!_rigs.TryGetValue(name, out r)) return 0; return r.R / r.H; }

        // ---- .XAF: a tiny tokenizer and block tree ----
        class XNode { public string Key, Name; public List<XNode> Kids = new List<XNode>(); public List<double> Nums = new List<double>(); }
        static List<object> Tokens(string s)
        {
            var t = new List<object>(); int i = 0, n = s.Length;
            while (i < n)
            {
                char c = s[i];
                if (char.IsWhiteSpace(c) || c == ',') { i++; continue; }
                if (c == '{' || c == '}') { t.Add(c); i++; continue; }
                if (c == '"') { int j = s.IndexOf('"', i + 1); if (j < 0) j = n; t.Add(new string[] { s.Substring(i + 1, j - i - 1) }); i = j + 1; continue; }
                if (char.IsDigit(c) || c == '-' || c == '+' || c == '.')
                {
                    int j = i + 1; while (j < n && (char.IsDigit(s[j]) || s[j] == '.' || s[j] == 'e' || s[j] == 'E' || ((s[j] == '-' || s[j] == '+') && (s[j - 1] == 'e' || s[j - 1] == 'E')))) j++;
                    double v; if (double.TryParse(s.Substring(i, j - i), NumberStyles.Float, CultureInfo.InvariantCulture, out v)) t.Add(v); i = j; continue;
                }
                if (char.IsLetter(c) || c == '_') { int j = i + 1; while (j < n && (char.IsLetterOrDigit(s[j]) || s[j] == '_')) j++; t.Add(s.Substring(i, j - i)); i = j; continue; }
                i++;
            }
            return t;
        }
        static void ParseInto(List<object> t, ref int i, XNode into)
        {
            while (i < t.Count)
            {
                object k = t[i];
                if (k is char) { i++; if ((char)k == '}') return; continue; }
                if (k is double) { into.Nums.Add((double)k); i++; continue; }
                if (k is string[]) { i++; continue; }                         // a bare string (face_materials list)
                var node = new XNode { Key = (string)k }; i++;
                if (i < t.Count && t[i] is string[]) { node.Name = ((string[])t[i])[0]; i++; }
                if (i < t.Count && t[i] is char && (char)t[i] == '{') { i++; ParseInto(t, ref i, node); }
                into.Kids.Add(node);
            }
        }
        static XNode Kid(XNode n, string key) { foreach (var k in n.Kids) if (k.Key == key) return k; return null; }

        Rig LoadXaf(string path)
        {
            var toks = Tokens(File.ReadAllText(path)); int i = 0; var root = new XNode(); ParseInto(toks, ref i, root);
            var bones = new List<Bone>();
            Action<XNode, int> walk = null;
            walk = (o, parent) =>
            {
                // parts that are not the body: blood splats (shown when hit; RAPTOR's BLOOD02 is parked 300 units away)
                // and helper boxes: TOBIAS's 'tdummy' (a 416-unit box at the root -- it shrank him to a few dots), EXTGEFF's
                // 'dummygoeff'. Their bones stay (the body hangs off them); only their meshes go.
                bool skip = o.Name != null && (o.Name.StartsWith("BLOOD", StringComparison.OrdinalIgnoreCase) || o.Name.IndexOf("dummy", StringComparison.OrdinalIgnoreCase) >= 0);
                var b = new Bone { Name = o.Name ?? "", Parent = parent };
                var m = Kid(o, "matrix"); b.Rest = new double[16];
                if (m != null && m.Nums.Count >= 16) for (int q = 0; q < 16; q++) b.Rest[q] = m.Nums[q]; else { b.Rest[0] = b.Rest[5] = b.Rest[10] = b.Rest[15] = 1; }
                var mesh = skip ? null : Kid(o, "mesh");
                var vs = mesh != null ? Kid(mesh, "vertices") : null; var fs = mesh != null ? Kid(mesh, "faces") : null;
                b.V = new float[vs != null ? vs.Nums.Count / 3 * 3 : 0];
                for (int q = 0; q < b.V.Length; q++) b.V[q] = (float)vs.Nums[q];
                // every edge of every face, once (welded by position inside the part: the files split vertices at seams)
                var edges = new HashSet<long>(); var weld = new Dictionary<string, int>(); int nv = b.V.Length / 3; var map = new int[nv];
                for (int q = 0; q < nv; q++)
                {
                    string key = string.Format(CultureInfo.InvariantCulture, "{0:F3},{1:F3},{2:F3}", b.V[q * 3], b.V[q * 3 + 1], b.V[q * 3 + 2]);
                    int j; if (!weld.TryGetValue(key, out j)) { j = q; weld[key] = q; } map[q] = j;
                }
                var tris = new List<int>();
                if (fs != null)
                {
                    var f = fs.Nums; int p = 0;
                    while (p < f.Count)
                    {
                        int cnt = (int)f[p++]; if (cnt <= 0 || p + 2 * cnt > f.Count) break;
                        for (int c = 1; c + 1 < cnt; c++)
                        {
                            int a0 = (int)f[p], a1 = (int)f[p + c * 2], a2 = (int)f[p + (c + 1) * 2];
                            if (a0 >= 0 && a1 >= 0 && a2 >= 0 && a0 < nv && a1 < nv && a2 < nv) { tris.Add(a0); tris.Add(a1); tris.Add(a2); }
                        }
                        for (int c = 0; c < cnt; c++)
                        {
                            int a = (int)f[p + c * 2], z = (int)f[p + ((c + 1) % cnt) * 2];
                            if (a < 0 || z < 0 || a >= nv || z >= nv) continue;
                            a = map[a]; z = map[z]; if (a == z) continue;
                            edges.Add(Math.Min(a, z) * 65536L + Math.Max(a, z));
                        }
                        p += 2 * cnt;
                    }
                }
                b.Tri = tris.ToArray();
                b.Edge = new int[edges.Count * 2]; int e = 0;
                foreach (long k in edges) { b.Edge[e++] = (int)(k / 65536); b.Edge[e++] = (int)(k % 65536); }
                int me = bones.Count; bones.Add(b);
                foreach (var k in o.Kids) if (k.Key == "object") walk(k, me);
            };
            foreach (var k in root.Kids) if (k.Key == "object") walk(k, -1);
            // the keys
            var set = Kid(root, "animation_set");
            if (set != null)
                foreach (var a in set.Kids)
                {
                    if (a.Key != "animation") continue;
                    var on = Kid(a, "object_name"); string nm = on != null && on.Name != null ? on.Name : a.Name;
                    var b = bones.Find(x => x.Name == nm); if (b == null) continue;
                    Keys(Kid(a, "rotate_keys"), 4, out b.RotT, out b.Rot);
                    Keys(Kid(a, "scale_keys"), 3, out b.SclT, out b.Scl);
                    Keys(Kid(a, "position_keys"), 3, out b.PosT, out b.Pos);
                }
            var r = new Rig { Bones = bones.ToArray() };
            foreach (var b in r.Bones) { r.Edges += b.Edge.Length / 2; r.Verts += b.V.Length / 3; }
            if (r.Verts == 0) throw new Exception("no geometry in " + path);
            return r;
        }
        static void Keys(XNode n, int per, out double[] t, out double[] v)
        {
            t = null; v = null; if (n == null || n.Nums.Count < per + 1) return;
            int k = n.Nums.Count / (per + 1); t = new double[k]; v = new double[k * per];
            for (int i = 0; i < k; i++) { t[i] = n.Nums[i * (per + 1)]; for (int j = 0; j < per; j++) v[i * per + j] = n.Nums[i * (per + 1) + 1 + j]; }
        }

        // ---- posing ----
        // a bone's local matrix at a (fractional) frame: scale, then rotation, then position (row vectors)
        static void Local(Bone b, double f, bool transpose, double[] m)
        {
            if (b.RotT == null && b.SclT == null && b.PosT == null) { Array.Copy(b.Rest, m, 16); return; }
            double w, x, y, z, sx, sy, sz, px, py, pz;
            if (b.RotT != null) Slerp(b.RotT, b.Rot, f, out w, out x, out y, out z);
            else { RestQuat(b.Rest, out w, out x, out y, out z); transpose = false; }
            if (b.SclT != null) { var s = Lerp3(b.SclT, b.Scl, f); sx = s[0]; sy = s[1]; sz = s[2]; }
            else { sx = Len(b.Rest, 0); sy = Len(b.Rest, 4); sz = Len(b.Rest, 8); }
            if (b.PosT != null) { var p = Lerp3(b.PosT, b.Pos, f); px = p[0]; py = p[1]; pz = p[2]; }
            else { px = b.Rest[12]; py = b.Rest[13]; pz = b.Rest[14]; }
            // the standard rotation matrix of q (column-vector form), read as rows -- or its transpose
            double[] R = {
                1 - 2 * (y * y + z * z), 2 * (x * y - w * z),     2 * (x * z + w * y),
                2 * (x * y + w * z),     1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
                2 * (x * z - w * y),     2 * (y * z + w * x),     1 - 2 * (x * x + y * y) };
            if (transpose) { double t; t = R[1]; R[1] = R[3]; R[3] = t; t = R[2]; R[2] = R[6]; R[6] = t; t = R[5]; R[5] = R[7]; R[7] = t; }
            double[] s3 = { sx, sy, sz };
            for (int r = 0; r < 3; r++) { for (int c = 0; c < 3; c++) m[r * 4 + c] = s3[r] * R[r * 3 + c]; m[r * 4 + 3] = 0; }
            m[12] = px; m[13] = py; m[14] = pz; m[15] = 1;
        }
        static double Len(double[] m, int o) { return Math.Sqrt(m[o] * m[o] + m[o + 1] * m[o + 1] + m[o + 2] * m[o + 2]); }
        static void RestQuat(double[] m, out double w, out double x, out double y, out double z)
        {
            // (only for a bone with position/scale keys and no rotation keys: keep the rest rotation)
            double sx = Len(m, 0), sy = Len(m, 4), sz = Len(m, 8);
            double a = m[0] / sx, b = m[1] / sx, c = m[2] / sx, d = m[4] / sy, e = m[5] / sy, f = m[6] / sy, g = m[8] / sz, h = m[9] / sz, k = m[10] / sz;
            double tr = a + e + k;
            if (tr > 0) { double s = Math.Sqrt(tr + 1) * 2; w = s / 4; x = (h - f) / s; y = (c - g) / s; z = (d - b) / s; }
            else if (a > e && a > k) { double s = Math.Sqrt(1 + a - e - k) * 2; w = (h - f) / s; x = s / 4; y = (b + d) / s; z = (c + g) / s; }
            else if (e > k) { double s = Math.Sqrt(1 + e - a - k) * 2; w = (c - g) / s; x = (b + d) / s; y = s / 4; z = (f + h) / s; }
            else { double s = Math.Sqrt(1 + k - a - e) * 2; w = (d - b) / s; x = (c + g) / s; y = (f + h) / s; z = s / 4; }
        }
        static int Seg(double[] t, double f, out double u)
        {
            u = 0; if (t.Length == 1 || f <= t[0]) return 0;
            if (f >= t[t.Length - 1]) return t.Length - 1;
            int i = 0; while (i + 1 < t.Length && t[i + 1] <= f) i++;
            u = (f - t[i]) / Math.Max(1e-9, t[i + 1] - t[i]); return i;
        }
        static double[] Lerp3(double[] t, double[] v, double f)
        {
            double u; int i = Seg(t, f, out u); int j = Math.Min(i + 1, t.Length - 1);
            return new[] { v[i * 3] + (v[j * 3] - v[i * 3]) * u, v[i * 3 + 1] + (v[j * 3 + 1] - v[i * 3 + 1]) * u, v[i * 3 + 2] + (v[j * 3 + 2] - v[i * 3 + 2]) * u };
        }
        static void Slerp(double[] t, double[] v, double f, out double w, out double x, out double y, out double z)
        {
            double u; int i = Seg(t, f, out u); int j = Math.Min(i + 1, t.Length - 1);
            double aw = v[i * 4], ax = v[i * 4 + 1], ay = v[i * 4 + 2], az = v[i * 4 + 3], bw = v[j * 4], bx = v[j * 4 + 1], by = v[j * 4 + 2], bz = v[j * 4 + 3];
            double d = aw * bw + ax * bx + ay * by + az * bz; if (d < 0) { d = -d; bw = -bw; bx = -bx; by = -by; bz = -bz; }   // the short way round
            double ka = 1 - u, kb = u;
            if (d < 0.9995) { double th = Math.Acos(Math.Min(1, d)), sn = Math.Sin(th); ka = Math.Sin((1 - u) * th) / sn; kb = Math.Sin(u * th) / sn; }
            w = aw * ka + bw * kb; x = ax * ka + bx * kb; y = ay * ka + by * kb; z = az * ka + bz * kb;
            double l = Math.Sqrt(w * w + x * x + y * y + z * z); if (l > 0) { w /= l; x /= l; y /= l; z /= l; }
        }
        static void Mul(double[] a, double[] b, double[] o)      // o = a * b (4x4, row vectors)
        {
            for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) o[r * 4 + c] = a[r * 4] * b[c] + a[r * 4 + 1] * b[4 + c] + a[r * 4 + 2] * b[8 + c] + a[r * 4 + 3] * b[12 + c];
        }
        /// <summary>Every bone's world matrix at frame f (W = local * W_parent; parents come before children).</summary>
        static double[][] Pose(Rig r, double f)
        {
            var W = new double[r.Bones.Length][]; var L = new double[16];
            for (int i = 0; i < r.Bones.Length; i++)
            {
                var b = r.Bones[i]; Local(b, f, r.Transpose, L); W[i] = new double[16];
                if (b.Parent < 0) Array.Copy(L, W[i], 16); else Mul(L, W[b.Parent], W[i]);
            }
            return W;
        }
        /// <summary>Per bone: the largest difference between its frame-0 local matrix and its rest matrix (offline check).</summary>
        public string CheckReport(string name, bool transpose)
        {
            Rig r = _rigs[name]; var sb = new System.Text.StringBuilder(); var L = new double[16];
            foreach (var b in r.Bones)
            {
                if (b.RotT == null) { sb.AppendLine(b.Name + " (no keys)"); continue; }
                Local(b, b.RotT[0], transpose, L); double worst = 0; int at = 0;
                for (int q = 0; q < 16; q++) { double d = Math.Abs(L[q] - b.Rest[q]); if (d > worst) { worst = d; at = q; } }
                sb.AppendLine(string.Format(CultureInfo.InvariantCulture, "{0,-10} t0={1,4} worst {2:G4} at [{3}] key {4:G4} rest {5:G4}", b.Name, b.RotT[0], worst, at, L[at], b.Rest[at]));
            }
            return sb.ToString();
        }
        /// <summary>Largest difference between the ROOT bones' frame-0 local matrices and their rest matrices. (Only the
        /// roots: frame 0 is a pose of its own for the limbs -- RAPTOR's legs differ from rest by up to 6.6 units -- and
        /// the root's children have rest matrices that cancel the root's rotation and scale, 1.06383 = 1/0.94, while
        /// their keys do not. The keys are each bone's true local transform: posed by them, the figure is whole.)</summary>
        static double RigCheck(Rig r, bool transpose)
        {
            double worst = 0; var L = new double[16];
            foreach (var b in r.Bones)
            {
                if (b.Parent >= 0 || b.RotT == null || b.RotT[0] != 0) continue;
                Local(b, 0, transpose, L);
                for (int q = 0; q < 16; q++) worst = Math.Max(worst, Math.Abs(L[q] - b.Rest[q]));
            }
            return worst;
        }
        // the walk cycle's middle and height (sampled), so the figure keeps one size and turns about one axis
        static void Measure(Rig r)
        {
            double x0 = 1e30, x1 = -1e30, y0 = 1e30, y1 = -1e30, z0 = 1e30, z1 = -1e30;
            for (int s = 0; s < 24; s++)
            {
                var W = Pose(r, r.From + (r.To - r.From) * s / 24.0);
                for (int i = 0; i < r.Bones.Length; i++)
                {
                    var v = r.Bones[i].V; var m = W[i];
                    for (int q = 0; q + 2 < v.Length; q += 3)
                    {
                        double x = v[q] * m[0] + v[q + 1] * m[4] + v[q + 2] * m[8] + m[12], y = v[q] * m[1] + v[q + 1] * m[5] + v[q + 2] * m[9] + m[13], z = v[q] * m[2] + v[q + 1] * m[6] + v[q + 2] * m[10] + m[14];
                        x0 = Math.Min(x0, x); x1 = Math.Max(x1, x); y0 = Math.Min(y0, y); y1 = Math.Max(y1, y); z0 = Math.Min(z0, z); z1 = Math.Max(z1, z);
                    }
                }
            }
            r.Cx = (x0 + x1) / 2; r.Cy = (y0 + y1) / 2; r.Cz = (z0 + z1) / 2; r.H = Math.Max(1e-3, y1 - y0);
            // how far it reaches from the upright it turns about: a long-bodied creature side-on is wider than it is tall
            double rr = 0;
            for (int s = 0; s < 24; s++)
            {
                var W = Pose(r, r.From + (r.To - r.From) * s / 24.0);
                for (int i = 0; i < r.Bones.Length; i++)
                {
                    var v = r.Bones[i].V; var m = W[i];
                    for (int q = 0; q + 2 < v.Length; q += 3)
                    {
                        double x = v[q] * m[0] + v[q + 1] * m[4] + v[q + 2] * m[8] + m[12] - r.Cx, z = v[q] * m[2] + v[q + 1] * m[6] + v[q + 2] * m[10] + m[14] - r.Cz;
                        rr = Math.Max(rr, x * x + z * z);
                    }
                }
            }
            r.R = Math.Max(1e-3, Math.Sqrt(rr));
        }

        /// <summary>An 8-bit, one-plane PCX's pixels (RLE: a byte >= 0xC0 repeats the next one (b &amp; 0x3F) times).</summary>
        public static byte[] ReadPcx8(string path, out int w, out int h)
        {
            var d = File.ReadAllBytes(path);
            if (d.Length < 129 || d[0] != 0x0A || d[3] != 8 || d[65] != 1) throw new Exception("not an 8-bit one-plane PCX");
            w = BitConverter.ToUInt16(d, 8) - BitConverter.ToUInt16(d, 4) + 1; h = BitConverter.ToUInt16(d, 10) - BitConverter.ToUInt16(d, 6) + 1;
            int bpl = BitConverter.ToUInt16(d, 66); var px = new byte[w * h]; var line = new byte[bpl]; int p = 128;
            for (int y = 0; y < h; y++)
            {
                int x = 0;
                while (x < bpl && p < d.Length)
                {
                    int b = d[p++], n = 1;
                    if (b >= 0xC0) { n = b & 0x3F; b = p < d.Length ? d[p++] : 0; }
                    while (n-- > 0 && x < bpl) line[x++] = (byte)b;
                }
                Buffer.BlockCopy(line, 0, px, y * w, Math.Min(w, bpl));
            }
            return px;
        }

        // ==== THE GAME: a thread that follows the scan, identifies it, and holds it to the clock ===========
        IntPtr _proc; long _memBase, D2 = 0x1F1000; Thread _thread; volatile bool _stop;
        /// <summary>Keep every scan running for as long as it did at the game's own rate (the counter at ScanHz).</summary>
        public bool HoldScan = true;
        /// <summary>The rate the game's scan counter is held to (frames/s): the modded game's cap, 24 -> 100 frames = 4.2 s.</summary>
        public double ScanHz = 24;
        /// <summary>memBase: the guest's RAM in DOSBox; delta2: where obj2's addresses sit past it (usually 0x1F1000).</summary>
        public void Attach(int pid, long memBase, long delta2)
        {
            Detach(); _memBase = memBase; if (delta2 != 0) D2 = delta2; LastError = "";
            _proc = OpenProcess(0x0010 | 0x0020 | 0x0008 | 0x0400, false, pid);    // VM_READ | VM_WRITE | VM_OPERATION | QUERY_INFORMATION
            if (_proc == IntPtr.Zero) { LastError = "OpenProcess failed: " + Marshal.GetLastWin32Error(); return; }
            _stop = false; _thread = new Thread(Run) { IsBackground = true, Name = "ScanWire", Priority = ThreadPriority.AboveNormal }; _thread.Start();
        }
        public void Detach()
        {
            _stop = true; if (_thread != null) { _thread.Join(500); _thread = null; }
            if (_proc != IntPtr.Zero) { CloseHandle(_proc); _proc = IntPtr.Zero; }
            _playing = null; _on = false;
        }
        /// <summary>Detach, and let the sound device go (for good: a disposed BootSound stays silent). Not part of Detach,
        /// which Attach calls first.</summary>
        public void Close() { Detach(); var s = Sound; if (s != null) { try { s.KeepOpen = false; s.Dispose(); } catch { } } }
        volatile string _playing; volatile bool _on; long _t0, _tEnd; int _lastWritten;
        /// <summary>The set the host is drawing now (null = none, or a scan it does not replace).</summary>
        public string Playing { get { return _playing; } }
        public bool ScanOn { get { return _on; } }
        public int Counter; public long Scans, Replaced, Held; public double LastScore;
        /// <summary>Hide the game's box: while ours plays, and briefly after (a screen reading can lag a frame).</summary>
        public bool HideNow { get { return _playing != null || (Stopwatch.GetTimestamp() - Interlocked.Read(ref _tEnd)) < Stopwatch.Frequency / 8; } }
        /// <summary>Seconds into the current scan.</summary>
        public double ScanSeconds { get { return (Stopwatch.GetTimestamp() - Interlocked.Read(ref _t0)) / (double)Stopwatch.Frequency; } }
        readonly byte[] _w4 = new byte[4], _hdr = new byte[8], _px = new byte[FW * FH], _wr = new byte[2];
        bool Read(long addr, byte[] buf, int n) { IntPtr got; return _proc != IntPtr.Zero && ReadProcessMemory(_proc, new IntPtr(addr), buf, new IntPtr(n), out got) && got.ToInt64() == n; }
        void Run()
        {
            timeBeginPeriod(1);
            try
            {
                long lastLook = 0; uint lookSum = 0, pendingSum = 0;
                while (!_stop)
                {
                    Thread.Sleep(1);
                    if (!Read(_memBase + A_FLAG + D2, _w4, 4)) continue;
                    bool on = BitConverter.ToUInt16(_w4, 0) != 0; int cnt = BitConverter.ToUInt16(_w4, 2); Counter = cnt;
                    long now = Stopwatch.GetTimestamp();
                    if (!on) { if (_on) { _on = false; if (_playing != null) Interlocked.Exchange(ref _tEnd, now); _playing = null; } continue; }
                    // a scan started -- or a new one replaced it (the loader puts the counter back to 0, under what the host
                    // last wrote; or, if the host's write landed after that, the frames themselves changed)
                    bool restart = !_on || cnt < _lastWritten;
                    if (!restart && now - lastLook > Stopwatch.Frequency / 10)
                    {
                        // (only once the new frames have stopped changing: never identify a half-loaded set)
                        lastLook = now; uint s = LookSum();
                        if (s != 0 && s != lookSum) { if (s == pendingSum) restart = true; else pendingSum = s; } else pendingSum = 0;
                    }
                    if (restart)
                    {
                        _on = true; _lastWritten = 0; Interlocked.Exchange(ref _t0, now);
                        var r = Identify(); lookSum = LookSum(); lastLook = now; pendingSum = 0;
                        // by NAME when the game says who it is (KURT and KURTB share one rig and one set of frames, but
                        // not one text); the frames' match stays the fallback
                        string who = TargetName(); CharInfo ci = null; LastName = who; LastHow = r != null ? "frames" : "none";
                        if (who != null && _chars.TryGetValue(who, out ci)) { Rig byName; if (ci.Rig != null && _rigs.TryGetValue(ci.Rig, out byName)) { r = byName; LastHow = "name"; } }
                        string itemText = null; LastItem = null;
                        if (r != null && r.IsItem)
                        {
                            // an item: drawn from its set's own frames; its text by the pick's name and the shown name
                            string picked = GuestString(Read(_memBase + A_TARGET + D2, _w4, 4) ? BitConverter.ToUInt32(_w4, 0) : 0), shown = HoveredName();
                            var oi = ObjectFor(picked, shown);
                            LastItem = string.Format("{0}: picked '{1}', shown '{2}' -> {3}", r.Name, picked ?? "?", shown ?? "?", oi != null ? oi.Display + " (" + oi.Obj + ")" : "no OBJECTS.DAT record (no result text)");
                            itemText = oi != null ? oi.Text : null; LastHow = "item";
                        }
                        else if (r != null && who == null)
                        {
                            // a character's frames on an OBJECT (Claude's engraved shield shows his figure): its own text
                            string picked = GuestString(Read(_memBase + A_TARGET + D2, _w4, 4) ? BitConverter.ToUInt32(_w4, 0) : 0);
                            var oi = ObjectFor(picked, HoveredName()); if (oi != null) { itemText = oi.Text; LastItem = string.Format("{0} frames on object '{1}' ({2})", r.Name, picked, oi.Display); }
                        }
                        string txt = itemText ?? (ci != null ? ci.Text : null);
                        _resultLines = r != null && Result && !string.IsNullOrEmpty(txt) ? Wrap(txt) : null;
                        _scanLen = ScanLength(r, _resultLines); _resNext = 0;
                        if (r != null) Replaced++;
                        _playing = r != null ? r.Name : null;
                        Interlocked.Increment(ref Scans);           // (last: the log reads Playing and LastScore when this moves)
                        // the sound: the degauss now, the readout's lines and SCAN COMPLETE as they come up
                        _sndLines = r != null ? ReadLines(r) : null; _sndNext = 0; _sndDone = false;
                        if (_sndLines != null) PlaySafe(s => s.DegaussSound(ScanDegauss), "degauss");
                    }
                    if (_sndLines != null && _playing != null)
                    {
                        double el = (now - Interlocked.Read(ref _t0)) / (double)Stopwatch.Frequency;
                        while (_sndNext < _sndLines.Length && el >= ReadStart + _sndNext * ReadGap)
                        {
                            int i = _sndNext++; double secs = _sndLines[i].Length / ReadCps;
                            if (el < ReadStart + i * ReadGap + 0.15) PlaySafe(s => s.Typing(600 + i, secs, ReadPitch), "line " + i + " typing " + secs.ToString("0.00", CultureInfo.InvariantCulture) + " s");      // (never a late one)
                        }
                        if (!_sndDone && el >= DoneAt(_sndLines)) { _sndDone = true; if (el < DoneAt(_sndLines) + 0.15) PlaySafe(s => s.Line(700, 0.16, 1.1 * ReadPitch), "scan complete"); }
                        var rl = _resultLines;
                        if (rl != null)
                            while (_resNext < rl.Length && el >= ResultLineAt(rl, _resNext))
                            {
                                int i = _resNext++; double secs = rl[i].Length / ResultCps;
                                if (el < ResultLineAt(rl, i) + 0.15) PlaySafe(s => s.Typing(800 + i, secs, ResultPitch), "result " + i + " typing " + secs.ToString("0.00", CultureInfo.InvariantCulture) + " s");
                            }
                    }
                    if (HoldScan)
                    {
                        // the counter, from the clock (written every pass: the guest adds one per frame in between)
                        int want = (int)Math.Min(100, (now - Interlocked.Read(ref _t0)) / (double)Stopwatch.Frequency * 100 / _scanLen);
                        if (want < cnt || want > cnt) { _wr[0] = (byte)want; _wr[1] = (byte)(want >> 8); IntPtr wn; if (WriteProcessMemory(_proc, new IntPtr(_memBase + A_COUNT + D2), _wr, new IntPtr(2), out wn)) Held++; }
                        _lastWritten = want;
                    }
                }
            }
            catch (Exception e) { LastError = "scan thread: " + e.Message; }
            finally { timeEndPeriod(1); }
        }
        string[] _sndLines; int _sndNext, _resNext; bool _sndDone;
        volatile string[] _resultLines; double _scanLen = 100 / 24.0;
        // the scanned character's definition name, read the way 0x2BE30 reads it; null if the target is not a character
        readonly byte[] _rd = new byte[32];
        string GuestString(long guestPtr)
        {
            if (guestPtr < 0x1000 || !Read(_memBase + guestPtr, _rd, 32)) return null;
            int n = Array.IndexOf(_rd, (byte)0); if (n <= 0) return null;
            return System.Text.Encoding.ASCII.GetString(_rd, 0, n);
        }
        string TargetName()
        {
            try
            {
                if (!Read(_memBase + A_TARGET + D2, _w4, 4)) return null;
                string tag = GuestString(BitConverter.ToUInt32(_w4, 0));
                if (tag == null || tag.Length < 3 || tag[0] != 'Z' || tag[1] != 'Z') return null;
                int k = 2, id = 0; while (k < tag.Length && char.IsDigit(tag[k])) id = id * 10 + (tag[k++] - '0');
                if (k == 2) return null;
                var b4 = new byte[12];
                for (int i = 0; i < 0x6F; i++)
                {
                    if (!Read(_memBase + A_ACTORS + D2 + 2 + i * 4, _w4, 4)) return null;
                    long p = BitConverter.ToUInt32(_w4, 0);
                    for (int hops = 0; p >= 0x1000 && hops < 64; hops++)
                    {
                        if (!Read(_memBase + p, b4, 12)) break;
                        long np = BitConverter.ToUInt32(b4, 0), namep = BitConverter.ToUInt32(b4, 4), idp = BitConverter.ToUInt32(b4, 8);
                        if (idp >= 0x1000 && Read(_memBase + idp, _w4, 4) && BitConverter.ToInt32(_w4, 0) == id) return GuestString(namep);
                        p = np;
                    }
                }
            }
            catch { }
            return null;
        }
        /// <summary>What was played and when (s into the scan), for checking the timing.</summary>
        public readonly System.Collections.Concurrent.ConcurrentQueue<string> SoundEvents = new System.Collections.Concurrent.ConcurrentQueue<string>();
        void PlaySafe(Action<BootSound> play, string what)
        {
            var s = Sound; if (s == null || !s.On) return;
            try { play(s); } catch { }
            if (SoundEvents.Count < 64) SoundEvents.Enqueue(string.Format(CultureInfo.InvariantCulture, "{0:0.000} {1}", ScanSeconds, what));
        }
        // a cheap fingerprint of the loaded first frame (16 bytes from each of 8 rows)
        readonly byte[] _row = new byte[16];
        uint LookSum()
        {
            if (!Read(_memBase + A_SURF + D2, _hdr, 8)) return 0;
            uint ptr = BitConverter.ToUInt32(_hdr, 4), h = 2166136261; if (ptr < 0x1000) return 0;
            for (int y = 10; y < FH; y += 14)
            {
                if (!Read(_memBase + ptr + y * FW + 40, _row, 16)) return 0;
                for (int i = 0; i < 16; i++) h = (h ^ _row[i]) * 16777619;
            }
            return h | 1;
        }
        Rig Identify()
        {
            if (!Read(_memBase + A_SURF + D2, _hdr, 8)) return null;
            int w = BitConverter.ToUInt16(_hdr, 0), h = BitConverter.ToUInt16(_hdr, 2); uint ptr = BitConverter.ToUInt32(_hdr, 4);
            if (w != FW || h != FH || ptr < 0x1000 || !Read(_memBase + ptr, _px, FW * FH)) return null;
            Rig best = null; double bestScore = 0;
            foreach (var rr in System.Linq.Enumerable.Concat(_rigs.Values, _itemSets.Values))
            {
                // agreement on what is ink and what is not, inside the 1-px frame the game draws round it
                int inter = 0, uni = 0;
                for (int y = 2; y < FH - 2; y++) for (int x = 2; x < FW - 2; x++)
                { bool a = _px[y * FW + x] != 0, b = rr.Mask[y * FW + x]; if (a || b) uni++; if (a && b) inter++; }
                double s = uni > 0 ? inter / (double)uni : 0;
                if (s > bestScore) { bestScore = s; best = rr; }
            }
            LastScore = bestScore;
            return bestScore >= MatchAt ? best : null;
        }
        /// <summary>How alike the game's frame and the art must be (share of ink in common) to count as that set.</summary>
        public double MatchAt = 0.6;
        /// <summary>Main loop, once a frame: nothing to do any more (the thread follows the game); kept for the watcher.</summary>
        public void Poll() { }

        // ==== THE DRAWING ==============================================================================
        public int Teal = 0x5FD8C0, TealFlare = 0xCFFFF4, Halo = 0x0E5A50;
        /// <summary>How fast it turns (rad/s), how far it leans toward the eye (rad), its height against the box, the
        /// angle it starts at, and how fast it walks (animation frames/s). Josh 2026-10-07: "speed up the animation
        /// by a little bit, maybe 10%" -- both the turn and the walk (the engine's own rate is 18.2065): 1.76 / 20.03.
        /// Josh 2026-10-13: it "spins and animates very quickly. Can we slow that down a bit?" -- ~30% slower: a turn
        /// in 5 s, the walk a little under the engine's rate.</summary>
        public double Spin = 1.25, Tilt = 0.14, Fill = 0.88, Phase = 0, AnimHz = 14.0;
        /// <summary>THE SECOND CLIP (Josh, 2026-10-13: "can the scan for these two creatures include their new sniffing
        /// animation as well?"): a set with one (SetExtra -- the watcher gives it any SNIFF range its .ANI has) walks for about
        /// ExtraAfter seconds (whole cycles), plays the clip once, and walks again.</summary>
        public double ExtraAfter = 2.0;
        public bool SetExtra(string name, int from, int to)
        {
            Rig r; if (!_rigs.TryGetValue(name, out r) || to <= from) return false;
            r.ExtraFrom = from; r.ExtraTo = to; return true;
        }
        /// <summary>How much bigger than the game's box it is drawn (anchored at the box's top-left): 1.4, then 15% more.</summary>
        public double BoxScale = 1.61;
        /// <summary>Place the box by the VISOR BAND's column map (true): the band lays the game's top rows across the full
        /// width with their corners at the screen's corners, so the box keeps the place the game gave it beside the
        /// visor's corner -- toward the screen's left edge rather than the 4:3 view's ("move it to the left more").</summary>
        public bool AnchorToBand = true;
        /// <summary>Fade in and out (s); the end is ScanSeconds reaching 100 / ScanHz.</summary>
        public double FadeIn = 0.15, FadeOut = 0.3;

        // ---- THE SCAN EFFECT over the whole view (Josh 2026-10-07: "a pulse, a scanning effect that gives a digital
        // readout similar to robocop or terminator using similar graphics as the intro bootup animation: a smooth/brief
        // pulse of the amber/orange with interlacing, a scan line both on the x/y axis moving across the screen")
        /// <summary>The boot's own inks (BootHd's palette indices: scan 34, sweep 49, text 88, flare 55); the watcher
        /// sets them from the live palette.</summary>
        public int Amber = 0xCA9228, AmberHi = 0xE7D27D, Ink = 0x71DFD7, InkFlare = 0xBEFBFF;
        /// <summary>The pulse: on, rise and fall (s), how far the view goes amber at its peak, how dark the interlaced rows get.</summary>
        public bool Pulse = true; public double PulseIn = 0.08, PulseOut = 0.75, PulseTint = 0.6, Interlace = 0.4;
        /// <summary>The amber light the pulse adds at its peak (share of the amber ink).</summary>
        public double PulseLift = 0.3;
        /// <summary>The sweeping lines: ONE pass, top-left to bottom-right (Josh: "scan once from top left to lower right,
        /// that's all that's needed") -- when it starts and how long it takes (s).</summary>
        public bool Sweeps = true; public double SweepAt = 0.05, SweepTime = 1.5;
        /// <summary>The typed readout beside the wireframe: when its first line starts (s into the scan), the time between
        /// lines, and characters a second. (The sound follows the same numbers.)</summary>
        public bool Readout = true; public double ReadStart = 0.3, ReadGap = 0.3, ReadCps = 38;

        // ---- THE SOUND (Josh: "sound effects, similar to the bootup animation for the text that is being read out, and a
        // single degauss sound when the scan initiates"): the boot's own BootSound -- its data chatter per readout line,
        // its degauss thunk as the scan starts. Played from the scan thread, on the scan's own clock.
        /// <summary>The boot's sound engine (null = silent). Prepared once and kept open, so the thunk lands on time.</summary>
        public BootSound Sound;
        // ---- THE RESULT (Josh, 2026-10-07: 'add specifics to each scannable creature ... based on the meta data added to the
        // text log ... display as a result after the scan in larger fonts to the right of the viewport (still while the amber
        // monitor effect is displaying, so it can extend its length)'): the character's own scan text, its ' - ' parts one
        // to a line, typing out after SCAN COMPLETE; the scan is held long enough to read it, and a softer amber pulse
        // brings it in.
        /// <summary>On; the pause after SCAN COMPLETE; between lines; characters a second; how long it stays once typed
        /// (at least, and per character); its size against the view's height; the second pulse's share of the first.</summary>
        public bool Result = true; public double ResultAfter = 0.3, ResultGap = 0.12, ResultCps = 34, ResultHold = 2.0, ResultPerChar = 0.015,
            ResultEm = 0.026, ResultPulse = 0.45, ResultPitch = 0.95;
        /// <summary>Longest line of the result, in characters (longer parts wrap at a word).</summary>
        public int ResultWidth = 26;
        string[] Wrap(string text)
        {
            var outL = new List<string>();
            foreach (var raw in text.Split(new[] { " - " }, StringSplitOptions.RemoveEmptyEntries))
            {
                string part = System.Text.RegularExpressions.Regex.Replace(raw, @"\s+", " ").Trim().ToUpperInvariant();
                if (part.Length == 0) continue;
                while (part.Length > ResultWidth)
                {
                    int cut = part.LastIndexOf(' ', ResultWidth); if (cut <= 0) cut = ResultWidth;
                    outL.Add(part.Substring(0, cut).TrimEnd()); part = part.Substring(cut).TrimStart();      // (flush left: no hanging indent, Josh)
                }
                outL.Add(part);
            }
            return outL.Count > 0 ? outL.ToArray() : null;
        }
        double ResultAt(Rig r) { return DoneAt(ReadLines(r)) + ResultAfter; }
        double _resultAt;
        double ResultLineAt(string[] rl, int i)
        {
            double at = _resultAt; for (int k = 0; k < i; k++) at += rl[k].Length / ResultCps + ResultGap; return at;
        }
        /// <summary>The scan's whole length (s): the game's own ~4.2 s, or long enough to type and read the result.</summary>
        double ScanLength(Rig r, string[] rl)
        {
            double stock = 100 / ScanHz; if (r == null || rl == null) return stock;
            _resultAt = ResultAt(r); int chars = 0; foreach (var l in rl) chars += l.Length;
            double typed = ResultLineAt(rl, rl.Length - 1) + rl[rl.Length - 1].Length / ResultCps;
            return Math.Max(stock, typed + ResultHold + chars * ResultPerChar);
        }
        void DrawResult(Graphics g, string[] rl, int pw, int vr, double a, double t)
        {
            if (t < _resultAt) return;
            float em = (float)(vr * ResultEm), lh = em * 1.32f, cw = em * 0.55f, margin = vr * 0.05f;
            float colW = cw * (ResultWidth + 1), x = pw - margin - colW, y0 = vr * 0.17f;
            double come = Smooth((t - _resultAt) / 0.2);
            var rng = new Random((int)(t * 30));
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // a bar down its left that grows with it, and a heading
            float shown = 0; for (int i = 0; i < rl.Length; i++) if (t >= ResultLineAt(rl, i)) shown = i + 1;
            using (var bar = new Pen(Color.FromArgb((int)(200 * a * come), Color.FromArgb(Amber)), Math.Max(1.5f, em * 0.09f)))
                g.DrawLine(bar, x - em * 0.6f, y0 - em * 1.2f, x - em * 0.6f, y0 + Math.Max(0.5f, shown) * lh);
            using (var hf = Crisp.Font(em * 0.62f, FontStyle.Bold))
            using (var hb = new SolidBrush(Color.FromArgb((int)(230 * a * come), Color.FromArgb(AmberHi))))
            {
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                Crisp.Text(g, "ANALYSIS RESULT", hf, hb, x, y0 - em * 1.15f);
            }
            using (var font = Crisp.Font(em, FontStyle.Bold))
            using (var ink = new SolidBrush(Color.FromArgb((int)(240 * a), Color.FromArgb(Ink))))
            using (var head = new SolidBrush(Color.FromArgb((int)(245 * a), Color.FromArgb(AmberHi))))
            using (var flare = new SolidBrush(Color.FromArgb((int)(255 * a), Color.FromArgb(InkFlare))))
            {
                for (int i = 0; i < rl.Length; i++)
                {
                    double t0 = ResultLineAt(rl, i); if (t < t0) break;
                    string L = rl[i]; int n = Math.Min(L.Length, (int)((t - t0) * ResultCps)); bool typing = n < L.Length;
                    var cs = L.Substring(0, n).ToCharArray();
                    if (t < t0 + L.Length / ResultCps + 0.25) for (int k = 0; k < cs.Length; k++) if (char.IsDigit(cs[k])) cs[k] = (char)('0' + rng.Next(10));
                    string txt = new string(cs) + (typing && ((int)(t * 8) & 1) == 0 ? "_" : "");
                    // the first part (DNASCAN / WARNING / PENSCAN) is the heading of the result, in the boot's amber
                    var br = i == 0 ? head : (typing ? flare : ink);
                    Crisp.Text(g, txt, font, br, x, y0 + i * lh);
                }
            }
        }
        /// <summary>The degauss at the scan's start, at this share of the boot's power-on level (the boot's mission uses 0.8).</summary>
        public double ScanDegauss = 0.8;
        /// <summary>Pitch of the readout's chatter against the boot's (the boot's mission lines are 0.92).</summary>
        public double ReadPitch = 1.0;

        Overlay _ov;
        /// <summary>For drawing over the true-colour picture: where the game's view lies in it comes from the overlay.</summary>
        public void Use(Overlay ov)
        {
            _ov = ov; Warm();
            // the sound device opened now and kept open (silent), so the scan's thunk is not half a second late
            var s = Sound; if (s != null && s.On) { try { s.Prepare(); } catch { } }
        }
        // everything the first scan frame would compile and load (it cost 33-45 ms once, a hitch on the scan's first frame)
        void Warm()
        {
            try
            {
                foreach (var name in _rigs.Keys)
                {
                    var px = new int[320 * 240]; PulseView(px, 320, 240, PulseIn);
                    var h = GCHandle.Alloc(px, GCHandleType.Pinned);
                    try
                    {
                        using (var bm = new Bitmap(320, 240, 320 * 4, PixelFormat.Format32bppRgb, h.AddrOfPinnedObject()))
                        using (var g = Graphics.FromImage(bm)) { DrawSweeps(g, 320, 240, 1, 1, 1); DrawBox(g, name, 0, 0, 100, 100, 1, 1); DrawReadout(g, name, 100, 0, 100, 1, 3.5); }
                    }
                    finally { h.Free(); }
                    break;
                }
            }
            catch { }
        }
        public long Drawn; public double LastDrawMs;
        /// <summary>DrawOver as a delegate, for Overlay.Decorate2 (PowerShell 5.1 cannot write [Func[int[],...]]).</summary>
        public Func<int[], int, int, bool> Hook { get { return DrawOver; } }
        /// <summary>Overlay.Decorate2: the scan effect and the wireframe, while one of ours is playing.</summary>
        public bool DrawOver(int[] pic, int pw, int ph)
        {
            var name = _playing; var ov = _ov; if (name == null || ov == null) return false;
            var clock = Stopwatch.StartNew();
            int[] cxi, cxf, cxiR, cxfR, riy, rwy; int bt, bb; bool vis;
            ov.ComposeMap(pw, ph, out cxi, out cxf, out cxiR, out cxfR, out riy, out rwy, out bt, out bb, out vis);
            int vr = Math.Min(ph, ov.ViewRowsOf(ph));
            // the picture's columns and rows that show the game's box: its size from the view's own map, its left edge
            // from the visor band's (AnchorToBand)
            int x0 = -1, x1 = -1, y0 = -1, y1 = -1, xa = -1;
            int[] ax = AnchorToBand && vis ? cxiR : cxi;
            for (int x = 0; x < pw; x++) { int ix = cxi[x]; if (ix < 0) continue; if (x0 < 0 && ix >= GameRect[0]) x0 = x; if (ix < GameRect[2]) x1 = x; }
            for (int x = 0; x < pw; x++) { int ix = ax[x]; if (ix >= GameRect[0]) { xa = x; break; } }
            for (int y = 0; y < ph; y++) { int iy = riy[y]; if (iy < 0) continue; if (y0 < 0 && iy >= GameRect[1]) y0 = y; if (iy < GameRect[3]) y1 = y; }
            if (x0 < 0 || y0 < 0 || x1 <= x0 || y1 <= y0) return false;
            if (xa < 0) xa = x0;
            double t = ScanSeconds, end = HoldScan ? _scanLen : 1e9;
            double a = Math.Min(1, t / FadeIn) * Math.Max(0, Math.Min(1, (end - t) / FadeOut));
            if (a <= 0.01) return false;
            float bw = (float)((x1 - x0 + 1) * BoxScale), bh = (float)((y1 - y0 + 1) * BoxScale), bx = xa, by = y0;
            if (Pulse) PulseView(pic, pw, vr, t);
            var hnd = GCHandle.Alloc(pic, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(pw, ph, pw * 4, PixelFormat.Format32bppRgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                {
                    g.SetClip(new Rectangle(0, 0, pw, vr));
                    if (Sweeps) DrawSweeps(g, pw, vr, a, t, bh / 120f);
                    DrawBox(g, name, bx, by, bw, bh, a, t);
                    if (Readout) DrawReadout(g, name, bx + bw + 14 * bh / 190f, by, bh, a, t);
                    var rl = _resultLines; if (rl != null) DrawResult(g, rl, pw, vr, a, t);
                }
            }
            finally { hnd.Free(); }
            Drawn++; LastDrawMs = clock.Elapsed.TotalMilliseconds; return true;
        }
        static double Smooth(double x) { x = Math.Max(0, Math.Min(1, x)); return x * x * (3 - 2 * x); }
        /// <summary>The pulse's strength at t: a quick smooth rise, a slower smooth fall.</summary>
        double PulseAt(double t)
        {
            double p = t < PulseIn ? Smooth(t / PulseIn) : 1 - Smooth((t - PulseIn) / PulseOut);
            if (_resultLines != null && t >= _resultAt) { double u = t - _resultAt; p = Math.Max(p, ResultPulse * (u < PulseIn ? Smooth(u / PulseIn) : 1 - Smooth((u - PulseIn) / PulseOut))); }
            return p;
        }
        // the view goes amber -- the scene's own light, as the boot's amber screen -- and every other band of rows dims
        void PulseView(int[] pic, int pw, int vr, double t)
        {
            double p = PulseAt(t); if (p <= 0.005) return;
            int k = (int)(256 * PulseTint * p), kl = (int)(256 * (1 - Interlace * p)), lift = (int)(256 * PulseLift);
            int ar = (Amber >> 16) & 255, ag = (Amber >> 8) & 255, ab = Amber & 255, hr = (AmberHi >> 16) & 255, hg = (AmberHi >> 8) & 255, hb = AmberHi & 255;
            int band = Math.Max(1, vr / 540);                 // interlace rows: ~2 px on a 1080-row view, as the boot's
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                int o = y * pw; bool dim = ((y / band) & 1) == 1;
                for (int x = 0; x < pw; x++)
                {
                    int c = pic[o + x], r = (c >> 16) & 255, gg = (c >> 8) & 255, b = c & 255;
                    int l = (r * 77 + gg * 150 + b * 29) >> 8;                    // the pixel's light
                    // amber toward the highlight with the light (dark -> the boot's amber, bright -> its sweep ink), kept
                    // bright (0.45..1 of it), then a wash of amber LIGHT on top: a pulse, not a dimming
                    int sh = 115 + l * 140 / 255;
                    int tr = ((ar * (255 - l) + hr * l) / 255 * sh >> 8) + (ar * lift >> 8), tg = ((ag * (255 - l) + hg * l) / 255 * sh >> 8) + (ag * lift >> 8), tb = ((ab * (255 - l) + hb * l) / 255 * sh >> 8) + (ab * lift >> 8);
                    r += (tr - r) * k >> 8; gg += (tg - gg) * k >> 8; b += (tb - b) * k >> 8;
                    if (dim) { r = r * kl >> 8; gg = gg * kl >> 8; b = b * kl >> 8; }
                    pic[o + x] = (Math.Max(0, Math.Min(255, r)) << 16) | (Math.Max(0, Math.Min(255, gg)) << 8) | Math.Max(0, Math.Min(255, b));
                }
            });
        }
        void DrawSweeps(Graphics g, int pw, int vr, double a, double t, float s)
        {
            s = Math.Max(1f, s);
            double u = (t - SweepAt) / SweepTime; if (u <= 0 || u >= 1) return;
            double e = Smooth(u), al = a * Smooth(u / 0.08) * Smooth((1 - u) / 0.15);     // (in quickly, out over the last stretch)
            float y = (float)(vr * e), x = (float)(pw * e);
            float trail = 70 * s;
            g.SmoothingMode = SmoothingMode.None;
            Action<RectangleF, LinearGradientMode> Trail = (rc, mode) =>
            {
                if (rc.Width < 1 || rc.Height < 1) return;
                var c0 = Color.FromArgb(0, Color.FromArgb(Amber)); var c1 = Color.FromArgb((int)(70 * al), Color.FromArgb(Amber));
                using (var br = new LinearGradientBrush(new RectangleF(rc.X - 1, rc.Y - 1, rc.Width + 2, rc.Height + 2), c0, c1, mode)) g.FillRectangle(br, rc);
            };
            // the phosphor trails behind them: above the line going down, left of the line going right
            Trail(new RectangleF(0, y - trail, pw, trail), LinearGradientMode.Vertical);
            Trail(new RectangleF(x - trail, 0, trail, vr), LinearGradientMode.Horizontal);
            using (var glow = new Pen(Color.FromArgb((int)(60 * al), Color.FromArgb(Amber)), 5 * s))
            using (var core = new Pen(Color.FromArgb((int)(210 * al), Color.FromArgb(AmberHi)), 1.4f * s))
            {
                g.DrawLine(glow, 0, y, pw, y); g.DrawLine(glow, x, 0, x, vr);
                g.DrawLine(core, 0, y, pw, y); g.DrawLine(core, x, 0, x, vr);
            }            // where they cross: a tick and its coordinates, in view px
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var pen = new Pen(Color.FromArgb((int)(220 * al), Color.FromArgb(AmberHi)), 1.2f * s))
                g.DrawEllipse(pen, x - 7 * s, y - 7 * s, 14 * s, 14 * s);
            using (var font = Crisp.Font(11f * s, FontStyle.Bold))
            using (var br = new SolidBrush(Color.FromArgb((int)(220 * al), Color.FromArgb(AmberHi))))
            {
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                string txt = string.Format("X{0:0000} Y{1:0000}", (int)(x * 1600 / Math.Max(1, pw)), (int)(y * 928 / Math.Max(1, vr)));
                float tx = x + 10 * s, ty = y + 6 * s;
                if (tx > pw - 120 * s) tx = x - 120 * s; if (ty > vr - 20 * s) ty = y - 20 * s;
                Crisp.Text(g, txt, font, br, tx, ty);
            }
        }
        // the readout's lines: the numbers are the rig's own and the identification's real score
        string[] ReadLines(Rig r)
        {
            if (r.IsItem)
            {
                // the numbers are the frames' own: their ink (edge pixels) and how many views
                int inkPx = 0; foreach (var m in r.Frames) foreach (var b in m) if (b) inkPx++;
                return new[] {
                    "SCAN MODE " + (4000 + inkPx % 6000).ToString("0000"),
                    "MATERIAL ANALYSIS",
                    "OBJECT ......... ACQUIRED",
                    "PROFILE VIEWS .. " + r.Frames.Count.ToString("00"),
                    "EDGE TRACE ..... " + (inkPx / Math.Max(1, r.Frames.Count)).ToString("0000"),
                    "SURFACE MAP .... " + (inkPx % 977).ToString("0000"),
                    "PROFILE MATCH .. " + (LastScore * 100).ToString("00.0", CultureInfo.InvariantCulture) + "%" };
            }
            return new[] {
                "SCAN MODE " + (4000 + (int)(r.Edges % 6000)).ToString("0000"),
                "BIOMETRIC ANALYSIS",
                "SUBJECT ........ ACQUIRED",
                "SKELETAL NODES . " + r.Bones.Length.ToString("00"),
                "VERTEX MAP ..... " + r.Verts.ToString("0000"),
                "GAIT CYCLE ..... " + ((int)(r.To - r.From)).ToString("00") + "F",
                "PROFILE MATCH .. " + (LastScore * 100).ToString("00.0", CultureInfo.InvariantCulture) + "%" };
        }
        /// <summary>When SCAN COMPLETE comes up (s into the scan): after the last line has typed and locked.</summary>
        double DoneAt(string[] lines) { return ReadStart + (lines.Length - 1) * ReadGap + lines[lines.Length - 1].Length / ReadCps + 0.6; }
        // the readout: lines that type in one after another, their numbers scrambling until they lock
        void DrawReadout(Graphics g, string name, float x, float y, float bh, double a, double t)
        {
            Rig r; if (!_rigs.TryGetValue(name, out r) && !_itemSets.TryGetValue(name, out r)) return;
            float s = Math.Max(1f, bh / 190f), em = 13f * s, lh = em * 1.45f;
            string[] lines = ReadLines(r);
            double start = ReadStart, gap = ReadGap, cps = ReadCps;
            var rng = new Random((int)(t * 30));               // (the scramble re-rolls 30 times a second)
            using (var font = Crisp.Font(em, FontStyle.Bold))
            using (var ink = new SolidBrush(Color.FromArgb((int)(235 * a), Color.FromArgb(Ink))))
            using (var head = new SolidBrush(Color.FromArgb((int)(240 * a), Color.FromArgb(AmberHi))))
            using (var flare = new SolidBrush(Color.FromArgb((int)(255 * a), Color.FromArgb(InkFlare))))
            {
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                for (int i = 0; i < lines.Length; i++)
                {
                    double t0 = start + i * gap; if (t < t0) break;
                    string L = lines[i]; int shown = Math.Min(L.Length, (int)((t - t0) * cps)); bool typing = shown < L.Length;
                    bool locked = t > t0 + L.Length / cps + 0.35;
                    var cs = L.Substring(0, shown).ToCharArray();
                    if (!locked) for (int k = 0; k < cs.Length; k++) if (char.IsDigit(cs[k])) cs[k] = (char)('0' + rng.Next(10));
                    string txt = new string(cs) + (typing && ((int)(t * 8) & 1) == 0 ? "_" : "");
                    Crisp.Text(g, txt, font, i == 0 ? head : (typing ? flare : ink), x, y + i * lh);
                }
                // SCAN COMPLETE, blinking, once the last line has locked
                double done = DoneAt(lines);
                if (t > done && ((int)((t - done) * 4) & 1) == 0) Crisp.Text(g, "SCAN COMPLETE", font, head, x, y + (lines.Length + 0.6f) * lh);
            }
            // a hex stream down the right of it, as the boot's dump column
            using (var small = Crisp.Font(em * 0.72f, FontStyle.Regular))
            using (var dim = new SolidBrush(Color.FromArgb((int)(120 * a * Smooth((t - start) / 0.4)), Color.FromArgb(Ink))))
            {
                int rows = (int)((lines.Length + 2) * 1.45f / 1.0f), tick = (int)(t * 14);
                float hx = x + em * 15.5f;
                for (int i = 0; i < rows; i++)
                {
                    var rr = new Random(tick * 131 + i * 7);
                    Crisp.Text(g, rr.Next(0x10000).ToString("X4") + " " + rr.Next(0x10000).ToString("X4"), small, dim, hx, y + i * em * 1.05f);
                }
            }
        }        void DrawBox(Graphics g, string name, float bx, float by, float bw, float bh, double a, double t)
        {
            g.SetClip(new RectangleF(bx, by, bw, bh));
            DrawInto(g, name, bx, by, bw, bh, a, t);
            g.ResetClip();
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float s1 = Math.Max(1f, bh / 120f), m = 9 * s1;
            // the chalice's corner marks round the box, and its scan line passing down
            using (var pen = new Pen(Color.FromArgb((int)(150 * a), Color.FromArgb(Teal)), 1.1f * s1))
            {
                float l = bx + 1, r = bx + bw - 2, tp = by + 1, b2 = by + bh - 2;
                g.DrawLines(pen, new[] { new PointF(l, tp + m), new PointF(l, tp), new PointF(l + m, tp) });
                g.DrawLines(pen, new[] { new PointF(r - m, tp), new PointF(r, tp), new PointF(r, tp + m) });
                g.DrawLines(pen, new[] { new PointF(l, b2 - m), new PointF(l, b2), new PointF(l + m, b2) });
                g.DrawLines(pen, new[] { new PointF(r - m, b2), new PointF(r, b2), new PointF(r, b2 - m) });
            }
            double sp = (t % 1.8) / 1.8; float sy = by + 3 + (float)(sp * (bh - 6));
            using (var scan = new Pen(Color.FromArgb((int)(80 * a), Color.FromArgb(TealFlare)), 1.0f * s1)) g.DrawLine(scan, bx + 4, sy, bx + bw - 5, sy);
        }
        /// <summary>Draw a set, walking and turning, into the box (x, y, w, h). alpha 0..1; t seconds into the scan.</summary>
        public void DrawInto(Graphics g, string name, float bx, float by, float bw, float bh, double alpha, double t)
        {
            Rig r; if (name == null) return;
            if (_itemSets.TryGetValue(name, out r) && !_rigs.ContainsKey(name)) { DrawFrames(g, r, bx, by, bw, bh, alpha, t); return; }
            if (!_rigs.TryGetValue(name, out r)) return;
            double span = r.To - r.From, f = span > 0 ? r.From + ((t * AnimHz) % span + span) % span : r.From;      // (span 0: a single pose)
            if (span > 0 && r.ExtraTo > r.ExtraFrom)
            {
                // the walk for whole cycles, then the second clip once through (SetExtra)
                double cyc = Math.Max(1, Math.Round(ExtraAfter * AnimHz / span)), walk = cyc * span, ex = r.ExtraTo - r.ExtraFrom, x = ((t * AnimHz) % (walk + ex) + walk + ex) % (walk + ex);
                f = x < walk ? r.From + x % span : r.ExtraFrom + (x - walk);
            }
            DrawPose(g, r, bx, by, bw, bh, alpha, f, r.Dir * t * Spin, 0);
        }
        // AN ITEM: the game's own frames as line art -- a soft halo under crisp ink, scaled to the box, each held and then
        // cross-faded into the next over the last FrameBlend of its share of the turn (a constant blend would ghost)
        public double FrameBlend = 0.3;
        void DrawFrames(Graphics g, Rig r, float bx, float by, float bw, float bh, double alpha, double t)
        {
            int n = r.Frames.Count; if (n == 0) return;
            if (r.Ink == null) MakeInks(r);
            double pos = t * Spin / (2 * Math.PI) * n; pos = (pos % n + n) % n;
            int i0 = (int)pos, i1 = (i0 + 1) % n; double u = pos - i0;
            double w1 = FrameBlend > 0 ? Smooth((u - (1 - FrameBlend)) / FrameBlend) : 0;
            // the frame's 1-px border left out; scaled to the box, aspect kept, centred
            float sw = FW - 4, sh = FH - 4, k = Math.Min(bw / sw, bh / sh) * (float)Math.Min(1.0, Fill / 0.88);
            float dw = sw * k, dh = sh * k, dx = bx + (bw - dw) / 2, dy = by + (bh - dh) / 2;
            var dst = new RectangleF(dx, dy, dw, dh); var src = new RectangleF(2, 2, sw, sh);
            g.InterpolationMode = InterpolationMode.HighQualityBilinear; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            for (int pass = 0; pass < 2; pass++)
            {
                var set = pass == 0 ? r.Glow : r.Ink;
                DrawFaded(g, set[i0], dst, src, alpha * (1 - w1));
                if (w1 > 0.002) DrawFaded(g, set[i1], dst, src, alpha * w1);
            }
        }
        static void DrawFaded(Graphics g, Bitmap b, RectangleF dst, RectangleF src, double a)
        {
            if (a <= 0.004) return;
            using (var ia = new ImageAttributes())
            {
                var cm = new ColorMatrix { Matrix33 = (float)Math.Min(1, a) }; ia.SetColorMatrix(cm);
                g.DrawImage(b, new[] { dst.Location, new PointF(dst.Right, dst.Top), new PointF(dst.Left, dst.Bottom) }, src, GraphicsUnit.Pixel, ia);
            }
        }
        // the inks: teal line art (the nearest-to-eye flare is the frame's own ink here), and its halo -- the mask spread
        // by a 2-px blur in the halo colour, as the wireframes' wide dim pass
        void MakeInks(Rig r)
        {
            int n = r.Frames.Count; var ink = new Bitmap[n]; var glow = new Bitmap[n];
            for (int i = 0; i < n; i++)
            {
                var m = r.Frames[i];
                var bi = new Bitmap(FW, FH, PixelFormat.Format32bppArgb); var bg = new Bitmap(FW, FH, PixelFormat.Format32bppArgb);
                int teal = Teal & 0xFFFFFF, halo = Halo & 0xFFFFFF;
                for (int y = 0; y < FH; y++)
                    for (int x = 0; x < FW; x++)
                    {
                        if (m[y * FW + x]) bi.SetPixel(x, y, Color.FromArgb(230 << 24 | teal));
                        int c = 0; for (int yy = -2; yy <= 2; yy++) for (int xx = -2; xx <= 2; xx++) { int px = x + xx, py = y + yy; if (px >= 0 && py >= 0 && px < FW && py < FH && m[py * FW + px]) c++; }
                        if (c > 0) bg.SetPixel(x, y, Color.FromArgb(Math.Min(255, 26 + c * 9) << 24 | halo));
                    }
                ink[i] = bi; glow[i] = bg;
            }
            r.Glow = glow; r.Ink = ink;
        }
        // the rig at animation frame f, turned `turn` past its start; core line width (0 = by the box's size)
        void DrawPose(Graphics g, Rig r, float bx, float by, float bw, float bh, double alpha, double f, double turn, float coreW)
        {
            var W = Pose(r, f);
            float s1 = Math.Max(1f, bh / 120f);
            double phi = Phase + r.Phase + turn, cp = Math.Cos(phi), sp = Math.Sin(phi), ct = Math.Cos(Tilt), st = Math.Sin(Tilt);
            // the size: tall things by their height, long things by their reach (turning, the reach is the width)
            double unit = Math.Max(r.H, 2 * r.R * bh / Math.Max(1f, bw)); float cx = bx + bw / 2, cy = by + bh / 2;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // project every bone's vertices: posed, centred on the cycle, turned about the upright, leant toward the eye
            var P = new PointF[r.Bones.Length][]; var Z = new float[r.Bones.Length][];
            for (int i = 0; i < r.Bones.Length; i++)
            {
                var v = r.Bones[i].V; var m = W[i]; int n = v.Length / 3; P[i] = new PointF[n]; Z[i] = new float[n];
                for (int q = 0; q < n; q++)
                {
                    double vx = v[q * 3], vy = v[q * 3 + 1], vz = v[q * 3 + 2];
                    double x = (vx * m[0] + vy * m[4] + vz * m[8] + m[12] - r.Cx) / unit, y = (vx * m[1] + vy * m[5] + vz * m[9] + m[13] - r.Cy) / unit, z = (vx * m[2] + vy * m[6] + vz * m[10] + m[14] - r.Cz) / unit;
                    double x1 = x * cp + z * sp, z1 = -x * sp + z * cp;
                    double y2 = y * ct - z1 * st, z2 = y * st + z1 * ct, k = 1 / (1 + z2 * 0.35);
                    P[i][q] = new PointF(cx + (float)(x1 * bh * Fill * k), cy - (float)(y2 * bh * Fill * k)); Z[i][q] = (float)z2;
                }
            }
            for (int pass = 0; pass < 2; pass++)
                using (var pen = new Pen(Color.Black, pass == 0 ? 3.0f * s1 : (coreW > 0 ? coreW : 0.9f * s1)))
                    for (int i = 0; i < r.Bones.Length; i++)
                    {
                        var e = r.Bones[i].Edge; var p = P[i]; var z = Z[i];
                        for (int q = 0; q + 1 < e.Length; q += 2)
                        {
                            int a = e[q], b = e[q + 1];
                            double near = Math.Max(0, Math.Min(1, 0.5 - (z[a] + z[b]) * 1.1));     // 1 = nearest
                            int al = (int)((pass == 0 ? 40 : 225) * (0.2 + 0.8 * near) * alpha); if (al < 3) continue;
                            pen.Color = Color.FromArgb(Math.Min(255, al), Color.FromArgb(pass == 0 ? Halo : (near > 0.85 ? TealFlare : Teal)));
                            g.DrawLine(pen, p[a], p[b]);
                        }
                    }
        }
        /// <summary>Offline: a w x h picture of a set at time t (s), on black, with the box's marks.</summary>
        public int[] RenderTest(string name, int w, int h, double t, bool marks)
        {
            var px = new int[w * h]; var hnd = GCHandle.Alloc(px, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(w, h, w * 4, PixelFormat.Format32bppRgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm)) { g.Clear(Color.Black); if (marks) DrawBox(g, name, 0, 0, w, h, 1, t); else DrawInto(g, name, 0, 0, w, h, 1, t); }
            }
            finally { hnd.Free(); }
            return px;
        }
    }

    /// <summary>A VISOR READOUT (Josh, 2026-10-09, Room Review MINEMAZE/5: entering the mines with the flashlight off, "a
    /// readout on their visor that reads 'Dark environment detected. Press F for Headlamp'"). Lines type onto the visor
    /// one after another in the scanner's inks, over a faint dark backing, hold, and fade; Dismiss() fades them at once
    /// (the flashlight came on). Overlay.Decorate3; while Playing the watcher has every frame decorated.</summary>
    /// <summary>THE ECHO SCAN'S LABELS (Josh, 2026-10-15: "have it highlight items that can be picked up and place a small
    /// icon/tooltip over them after ... '[i icon] Item of interest detected. Suggestion: Investigate.' We will see this in the scan
    /// and in the world. The tooltip will remain for 20 seconds before fading, and will renew each time the player scans.
    /// Similarly, for characters 'Humanoid figure detected. Approach with caution.' For creatures: 'Live fauna detected.
    /// Avoid.'"). Each scan (Begin + Add) names its targets by their vertex ranges; every frame Step finds each one's top in
    /// the posed geometry, lets it appear when the echo's shell reaches it (a ragged flicker on), holds it Hold s, fades it,
    /// and hands the nearest MaxLabels to the card (GpuRaster.SetLabels), which pins the pre-drawn tooltips over them in its
    /// present pass. A taken item (its triangle no longer drawn) loses its label.</summary>
    public class EchoLabels
    {
        public const int ITEM = 0, HUMANOID = 1, CREATURE = 2, INTERACTIVE = 3, LOCKED = 4, KINDS = 5;
        // (Josh, 2026-10-15, round 3: pickups and interactive items lose the "Suggestion" line; a locked door reads "Locked door.")
        public string[] Head = { "Item of interest detected.", "Humanoid figure detected.", "Live fauna detected.", "Interactive item detected.", "Locked door." };
        public string[] Sub = { "", "Approach with caution.", "Avoid.", "", "" };
        /// <summary>Per kind: the brackets, icon and leader; the first line; the second line; the glass.</summary>
        public int[] Ink = { 0xFFD27A, 0xFFB040, 0xFF6A38, 0xE8C878, 0xFF9A48 }, HeadInk = { 0xFFF1CC, 0xFFE3A6, 0xFFD9C9, 0xFFF0D2, 0xFFE6CC }, SubInk = { 0xFFB040, 0xFFB040, 0xFF8A5C, 0xD9B060, 0xFF9A48 };
        /// <summary>The thin leader from the tooltip's corner down to the thing (Josh: "lighter weight/thinner"): its width as a
        /// share of the text's size, and its strength.</summary>
        public float LeaderWidth = 1f / 18f; public int LeaderAlpha = 190;
        /// <summary>The corner brackets' width, as a share of the text's size (em/9 first; Josh: "make the brackets thinner").</summary>
        public float BracketWidth = 1f / 16f;
        /// <summary>The room's REST geometry (its own vertex list): a LOCKED door that has moved from it is open, and loses its label.</summary>
        public float[] Rest;
        public int Glass = 0x140C02;
        /// <summary>How long each kind holds (s) and fades (Josh, 2026-10-15: characters and creatures "around 3 seconds, then
        /// fade. Seeing that next to the wireframe outline is sufficient"; pickups and interactive objects 20 s).</summary>
        public double[] HoldOf = { 20, 3, 3, 20, 20 }, FadeOf = { 1.5, 0.8, 0.8, 1.5, 1.5 };
        public double FlickerOn = 0.25;
        /// <summary>(Josh, 2026-10-15: "for interactive items and items of interest, after 3 seconds, let's have those tooltips
        /// smoothly transition only to the i icon and not display the text unless they renew the scan"): when a pickup's or an
        /// interactive item's text gives way to its icon alone (s after it shows) and how long the cross-fade takes (s).</summary>
        public double CompactAfter = 3.0, CompactFade = 0.6;
        // the atlas's rows: the five tooltips, then the icon-only pickup and interactive item
        const int ROW_ITEM_ICON = KINDS, ROW_INTER_ICON = KINDS + 1, ROWS = KINDS + 2;
        public double Hold { get { return HoldOf[ITEM]; } }
        public int MaxLabels = 16;
        public bool Enabled = true;
        public long Scans, Shown;
        class Target { public int Kind, Tri; public int[] VFirst, VCount; public double At = -1; }
        readonly List<Target> _t = new List<Target>(); readonly Stopwatch _clock = new Stopwatch();
        public int Count { get { return _t.Count; } }
        public bool Active { get { return _t.Count > 0; } }
        public void Clear() { _t.Clear(); }
        /// <summary>A new scan: the old labels go, the new ones come as the shell reaches them.</summary>
        public void Begin() { _t.Clear(); _clock.Restart(); Scans++; }
        /// <summary>One target: kind, its vertex ranges (first, count) in the room's vertex list, and a triangle of it that is not
        /// drawn once it has been taken (-1: none).</summary>
        public void Add(int kind, int[] vFirst, int[] vCount, int tri)
        {
            if (vFirst == null || vCount == null || vFirst.Length == 0) return;
            _t.Add(new Target { Kind = kind, VFirst = vFirst, VCount = vCount, Tri = tri });
        }
        static double Noise(int i) { uint h = (uint)i * 2654435761u; h ^= h >> 13; h *= 0x5bd1e995; h ^= h >> 15; return (h & 0xFFFF) / 65535.0; }
        // has this target moved more than a few units from the room's rest geometry (a door swung or slid open)?
        bool Moved(Target tg, float[] vx)
        {
            var rest = Rest; float worst = 0f;
            for (int r = 0; r < tg.VFirst.Length; r++)
            {
                int a = tg.VFirst[r], e = Math.Min(Math.Min(vx.Length, rest.Length) / 3, a + tg.VCount[r]);
                for (int v = Math.Max(0, a); v < e; v++)
                    for (int k = 0; k < 3; k++) { float d = Math.Abs(vx[v * 3 + k] - rest[v * 3 + k]); if (d > worst) worst = d; }
            }
            return worst > OpenMoved;
        }
        /// <summary>How far (units) a locked door's vertices may be from rest and still count as shut.</summary>
        public float OpenMoved = 3f;
        float[] _buf = new float[0]; readonly List<float[]> _cand = new List<float[]>();
        /// <summary>Every frame: vx the posed vertices, dt the drawn triangles' textures (below 0 = not drawn), the shell's
        /// speed (units/s), hide = keep them off for now (the map, a cover, a menu); their clocks run on.</summary>
        public void Step(GpuRaster gpu, float[] vx, int[] dt, float shellSpeed, bool hide)
        {
            if (gpu == null) return;
            if (!Enabled || _t.Count == 0 || vx == null) { gpu.SetLabels(null, 0); return; }
            double now = _clock.Elapsed.TotalSeconds; float ex = gpu.CamX, ey = gpu.CamY, ez = gpu.CamZ;
            _cand.Clear(); bool any = false;
            for (int i = 0; i < _t.Count; i++)
            {
                var tg = _t[i];
                if (tg.Tri >= 0 && dt != null && tg.Tri < dt.Length && dt[tg.Tri] < 0) continue;      // (taken)
                float x0 = float.MaxValue, x1 = float.MinValue, y0 = float.MaxValue, y1 = float.MinValue, z0 = float.MaxValue, z1 = float.MinValue; int got = 0;
                for (int r = 0; r < tg.VFirst.Length; r++)
                {
                    int a = tg.VFirst[r], e = Math.Min(vx.Length / 3, a + tg.VCount[r]);
                    for (int v = Math.Max(0, a); v < e; v++)
                    {
                        float x = vx[v * 3], y = vx[v * 3 + 1], z = vx[v * 3 + 2];
                        if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; if (z < z0) z0 = z; if (z > z1) z1 = z; got++;
                    }
                }
                if (got == 0) continue;
                if (tg.Kind == LOCKED && Rest != null && Moved(tg, vx)) continue;      // (open: no longer locked)
                float h = y1 - y0, ax = (x0 + x1) * 0.5f, ay = y1 + Math.Max(3f, h * 0.12f), az = (z0 + z1) * 0.5f;
                float dx = ax - ex, dy = ay - ey, dz = az - ez, dist = (float)Math.Sqrt(dx * dx + dy * dy + dz * dz);
                if (tg.At < 0) tg.At = dist / Math.Max(1f, shellSpeed);          // (it shows when the shell gets there)
                double age = now - tg.At; if (age < 0) { any = true; continue; }
                double hold = HoldOf[tg.Kind], fade = FadeOf[tg.Kind];
                double alpha = age < hold ? 1 : Math.Max(0, 1 - (age - hold) / fade);
                if (alpha <= 0) continue;
                any = true;
                if (age < FlickerOn && Noise((int)(age * 60) + i * 31) < 0.3 + 0.5 * (1 - age / FlickerOn)) alpha *= 0.2;
                if (hide) continue;
                if ((tg.Kind == ITEM || tg.Kind == INTERACTIVE) && CompactAfter > 0)
                {
                    double kc = Math.Max(0, Math.Min(1, (age - CompactAfter) / Math.Max(0.05, CompactFade))); kc = kc * kc * (3 - 2 * kc);
                    if (kc < 1) _cand.Add(new[] { ax, ay, az, (float)tg.Kind, (float)(alpha * (1 - kc)), dist });
                    if (kc > 0) _cand.Add(new[] { ax, ay, az, (float)(tg.Kind == ITEM ? ROW_ITEM_ICON : ROW_INTER_ICON), (float)(alpha * kc), dist + 0.01f });
                }
                else _cand.Add(new[] { ax, ay, az, (float)tg.Kind, (float)alpha, dist });
            }
            if (!any) { _t.Clear(); gpu.SetLabels(null, 0); return; }
            _cand.Sort((p, q) => p[5].CompareTo(q[5]));
            int n = Math.Min(MaxLabels, _cand.Count);
            if (_buf.Length < n * 5) _buf = new float[n * 5];
            for (int i = 0; i < n; i++) Array.Copy(_cand[i], 0, _buf, i * 5, 5);
            if (n > 0) Shown++;
            EnsureAtlas(gpu);
            gpu.SetLabels(_buf, n);
        }

        // ---- the three tooltips, drawn once for the window's size -------------------------------------------------------
        int _atlasFor = -1;
        void EnsureAtlas(GpuRaster gpu)
        {
            int W = gpu.PresentW, H = gpu.PresentH; if (W < 64 || H < 64) return;
            if (_atlasFor == H) return;
            _atlasFor = H;
            float em = Math.Max(11f, H / 74f), pad = em * 0.7f, icon = em * 1.5f, gap = em * 0.55f, lh = em * 1.3f;
            float textW = 0; var textOf = new float[KINDS];
            using (var b1 = new Bitmap(1, 1)) using (var g1 = Graphics.FromImage(b1)) using (var f = Crisp.Font(em, FontStyle.Bold))
                for (int k = 0; k < KINDS; k++) { textOf[k] = Math.Max(g1.MeasureString(Head[k], f, PointF.Empty, StringFormat.GenericTypographic).Width, g1.MeasureString(Sub[k], f, PointF.Empty, StringFormat.GenericTypographic).Width); textW = Math.Max(textW, textOf[k]); }
            float plateW = pad + icon + gap + textW + pad, plateH = pad + lh * 2 + pad * 0.6f, plate1H = pad * 0.85f + lh + pad * 0.55f;
            float leadX = em * 2.0f, leadY = em * 1.7f, m = em * 0.5f;          // (the leader: from the point up and right to the plate)
            int cw = (int)Math.Ceiling(m + leadX + plateW + m), ch = (int)Math.Ceiling(m + plateH + leadY + m);
            float axp = m, ayp = ch - m;                                       // (the point the tooltip is pinned to)
            var px = new int[cw * ch * ROWS];
            var hnd = GCHandle.Alloc(px, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(cw, ch * ROWS, cw * 4, PixelFormat.Format32bppPArgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                using (var font = Crisp.Font(em, FontStyle.Bold))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                    for (int row = 0; row < ROWS; row++)
                    {
                        // (the last two rows: the pickup and the interactive item as their icon alone)
                        bool iconOnly = row >= KINDS; int k = row == ROW_ITEM_ICON ? ITEM : row == ROW_INTER_ICON ? INTERACTIVE : row;
                        float plateK = iconOnly ? pad + icon + pad * 0.9f : pad + icon + gap + textOf[k] + pad;      // (each plate fits its own words)
                        bool one = iconOnly || string.IsNullOrEmpty(Sub[k]);
                        float oy = row * ch, px0 = axp + leadX, py1 = oy + ch - m - leadY, py0 = py1 - (one ? plate1H : plateH), px1 = px0 + plateK;
                        var ink = Color.FromArgb(235, Color.FromArgb(Ink[k]));
                        // the glass, interlaced
                        using (var gb = new SolidBrush(Color.FromArgb(165, Color.FromArgb(Glass)))) g.FillRectangle(gb, px0, py0, plateK, py1 - py0);
                        using (var il = new SolidBrush(Color.FromArgb(50, Color.Black))) for (float yy = py0; yy < py1; yy += 3) g.FillRectangle(il, px0, yy, plateK, 1);
                        using (var pen = new Pen(ink, Math.Max(1.5f, em / 9f)))
                        {
                            // the visor's corner brackets
                            float L = em * 0.55f;
                            using (var bp = new Pen(ink, Math.Max(1f, em * BracketWidth)))      // (thin: Josh, 2026-10-15)
                            {
                                g.DrawLines(bp, new[] { new PointF(px0, py0 + L), new PointF(px0, py0), new PointF(px0 + L, py0) });
                                g.DrawLines(bp, new[] { new PointF(px1 - L, py0), new PointF(px1, py0), new PointF(px1, py0 + L) });
                                g.DrawLines(bp, new[] { new PointF(px0, py1 - L), new PointF(px0, py1), new PointF(px0 + L, py1) });
                                g.DrawLines(bp, new[] { new PointF(px1 - L, py1), new PointF(px1, py1), new PointF(px1, py1 - L) });
                            }
                            // the leader and the point: a small diamond on the thing itself
                            float ay = oy + ayp;
                            using (var thin = new Pen(Color.FromArgb(LeaderAlpha, Color.FromArgb(Ink[k])), Math.Max(1f, em * LeaderWidth)))
                            {
                                g.DrawLine(thin, axp, ay, px0, py1);
                                float d = em * 0.26f; var dia = new[] { new PointF(axp, ay - d), new PointF(axp + d, ay), new PointF(axp, ay + d), new PointF(axp - d, ay) };
                                using (var fill = new SolidBrush(Color.FromArgb(120, Color.FromArgb(Ink[k])))) g.FillPolygon(fill, dia);
                                g.DrawPolygon(thin, dia);
                            }
                            // the icon
                            float cx = px0 + pad + icon / 2, cy = (py0 + py1) / 2, r = icon * 0.42f;
                            if (k == ITEM)
                            {
                                g.DrawEllipse(pen, cx - r, cy - r, 2 * r, 2 * r);                              // (i)
                                using (var dot = new SolidBrush(ink)) g.FillEllipse(dot, cx - r * 0.13f, cy - r * 0.58f, r * 0.26f, r * 0.26f);
                                g.DrawLine(pen, cx, cy - r * 0.12f, cx, cy + r * 0.55f);
                            }
                            else if (k == HUMANOID)
                            {
                                g.DrawEllipse(pen, cx - r * 0.32f, cy - r * 0.95f, r * 0.64f, r * 0.64f);       // (a head and shoulders)
                                g.DrawArc(pen, cx - r * 0.85f, cy - r * 0.15f, r * 1.7f, r * 1.9f, 180, 180);
                                g.DrawLine(pen, cx - r * 0.85f, cy + r * 0.8f, cx + r * 0.85f, cy + r * 0.8f);
                            }
                            else if (k == LOCKED)
                            {
                                // a padlock: the shackle, the body, the keyhole
                                g.DrawArc(pen, cx - r * 0.5f, cy - r * 1.0f, r * 1.0f, r * 1.05f, 180, 180);
                                g.DrawLine(pen, cx - r * 0.5f, cy - r * 0.48f, cx - r * 0.5f, cy - r * 0.1f); g.DrawLine(pen, cx + r * 0.5f, cy - r * 0.48f, cx + r * 0.5f, cy - r * 0.1f);
                                using (var fill = new SolidBrush(Color.FromArgb(70, Color.FromArgb(Ink[k])))) g.FillRectangle(fill, cx - r * 0.82f, cy - r * 0.1f, r * 1.64f, r * 1.1f);
                                g.DrawRectangle(pen, cx - r * 0.82f, cy - r * 0.1f, r * 1.64f, r * 1.1f);
                                using (var dot = new SolidBrush(ink)) g.FillEllipse(dot, cx - r * 0.14f, cy + r * 0.22f, r * 0.28f, r * 0.28f);
                                g.DrawLine(pen, cx, cy + r * 0.4f, cx, cy + r * 0.72f);
                            }
                            else if (k == INTERACTIVE)
                            {
                                // a cog: eight teeth round a ring, a hub
                                var cog = new PointF[32];
                                for (int q = 0; q < 32; q++) { double an = q * Math.PI * 2 / 32 + Math.PI / 32; float rr = (q % 4 < 2) ? r * 1.0f : r * 0.74f; cog[q] = new PointF(cx + rr * (float)Math.Cos(an), cy + rr * (float)Math.Sin(an)); }
                                using (var fill = new SolidBrush(Color.FromArgb(60, Color.FromArgb(Ink[k])))) g.FillPolygon(fill, cog);
                                g.DrawPolygon(pen, cog);
                                g.DrawEllipse(pen, cx - r * 0.3f, cy - r * 0.3f, r * 0.6f, r * 0.6f);
                            }
                            else
                            {
                                var tri = new[] { new PointF(cx, cy - r * 1.0f), new PointF(cx + r * 1.08f, cy + r * 0.85f), new PointF(cx - r * 1.08f, cy + r * 0.85f) };   // (a warning sign)
                                using (var fill = new SolidBrush(Color.FromArgb(70, Color.FromArgb(Ink[k])))) g.FillPolygon(fill, tri);
                                g.DrawPolygon(pen, tri);
                                g.DrawLine(pen, cx, cy - r * 0.38f, cx, cy + r * 0.25f);
                                using (var dot = new SolidBrush(ink)) g.FillEllipse(dot, cx - r * 0.1f, cy + r * 0.42f, r * 0.2f, r * 0.2f);
                            }
                        }
                        float tx = px0 + pad + icon + gap, ty = one ? (py0 + py1) / 2 - em * 0.62f : py0 + pad * 0.8f;
                        if (iconOnly) continue;
                        using (var hb = new SolidBrush(Color.FromArgb(245, Color.FromArgb(HeadInk[k])))) Crisp.Text(g, Head[k], font, hb, tx, ty, StringFormat.GenericTypographic);
                        if (!one) using (var sb = new SolidBrush(Color.FromArgb(230, Color.FromArgb(SubInk[k])))) Crisp.Text(g, Sub[k], font, sb, tx, ty + lh, StringFormat.GenericTypographic);
                    }
                }
            }
            finally { hnd.Free(); }
            gpu.SetLabelAtlas(px, cw, ch, ROWS, axp, ayp);
        }
    }

    public class VisorNote
    {
        public int Ink = 0x71DFD7, AmberHi = 0xE7D27D, InkFlare = 0xBEFBFF;
        public double Cps = 38, Gap = 0.3, FadeIn = 0.25, FadeOut = 0.7, Hold = 6;
        readonly Overlay _ov; string[] _lines; readonly Stopwatch _clock = new Stopwatch(); double _dismissAt = -1;
        public VisorNote(Overlay ov) { _ov = ov; }
        public void Show(string[] lines, double hold)
        {
            if (lines == null || lines.Length == 0) return;
            _lines = lines; Hold = Math.Max(0.5, hold); _dismissAt = -1; _clock.Restart();
        }
        public void Dismiss() { if (_lines != null && _dismissAt < 0) _dismissAt = _clock.Elapsed.TotalSeconds; }
        double LineStart(int i) { double t = 0.15; for (int k = 0; k < i; k++) t += _lines[k].Length / Cps + Gap; return t; }
        double End { get { int n = _lines.Length; return LineStart(n - 1) + _lines[n - 1].Length / Cps + Hold; } }
        double Alpha(double t)
        {
            double a = Math.Min(1, t / FadeIn) * Math.Max(0, Math.Min(1, (End - t) / FadeOut));
            if (_dismissAt >= 0) a *= Math.Max(0, 1 - (t - _dismissAt) / 0.25);
            return a;
        }
        bool LinesPlaying
        {
            get
            {
                var l = _lines; if (l == null) return false;
                double t = _clock.Elapsed.TotalSeconds;
                if (t > End || (_dismissAt >= 0 && t > _dismissAt + 0.25)) { _lines = null; return false; }
                return true;
            }
        }
        public bool Playing { get { bool l = LinesPlaying; return l | BadgePlaying; } }
        public Func<int[], int, int, bool> Hook { get { return DrawOver; } }

        // ---- THE DAMAGE BADGE (Josh, 2026-10-10: "When taking damage throughout the game, I want a small badge to appear in
        // the visor per our typical style that reads 'Damage taken!' ... a small notification style tooltip that appears in
        // the lower left of the visor"). Damage() on every hit (the watcher sees the player's health fall): it flickers on
        // with a red split, a warning sign and the words in a dark glass plate with the visor's corner brackets, holds
        // BadgeHold s, and fades. A hit while it shows flashes it again and starts its hold over.
        public int Alert = 0xFF4A2E, AlertText = 0xFFD9C9;
        public double BadgeHold = 2.4, BadgeFade = 0.55, BadgeOn = 0.2;
        public string BadgeText = "Damage taken!";
        public long Damages;
        readonly Stopwatch _badge = new Stopwatch(); double _badgeHit = -1;     // (the badge's clock: its start, the latest hit)
        public void Damage()
        {
            Damages++;
            if (!BadgePlaying) { _badge.Restart(); _badgeHit = 0; } else _badgeHit = _badge.Elapsed.TotalSeconds;
        }
        bool BadgePlaying { get { return _badgeHit >= 0 && _badge.IsRunning && _badge.Elapsed.TotalSeconds < _badgeHit + BadgeHold + BadgeFade; } }
        static float Noise1(int i) { uint h = (uint)i * 2654435761u; h ^= h >> 13; h *= 0x5bd1e995; h ^= h >> 15; return (h & 0xFFFF) / 65535f; }
        void DrawBadge(int[] pic, int pw, int ph, int vr)
        {
            if (!BadgePlaying) return;
            double t = _badge.Elapsed.TotalSeconds, sinceHit = t - _badgeHit;
            // on: a ragged flicker for BadgeOn s; out: a fade after the hold
            double a = Math.Max(0, Math.Min(1, (_badgeHit + BadgeHold + BadgeFade - t) / BadgeFade));
            if (t < BadgeOn) a *= Noise1((int)(t * 60)) > 0.35 + 0.5 * (1 - t / BadgeOn) ? 1 : 0.15;
            if (a <= 0.01) return;
            double hitK = Math.Exp(-sinceHit / 0.18);                                     // each hit's flash
            float em = Math.Max(13f, vr / 50f), pad = em * 0.7f;
            float slide = (float)(em * 0.8 * Math.Pow(Math.Max(0, 1 - t / 0.25), 2));    // (in from the left as it appears)
            var hnd = GCHandle.Alloc(pic, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(pw, ph, pw * 4, PixelFormat.Format32bppRgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                using (var font = Crisp.Font(em, FontStyle.Bold))
                {
                    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit; g.SmoothingMode = SmoothingMode.AntiAlias;
                    float tw = g.MeasureString(BadgeText, font, PointF.Empty, StringFormat.GenericTypographic).Width, icon = em * 1.15f;
                    float w = pad + icon + em * 0.55f + tw + pad, h = em * 2.0f;
                    float x0 = pw * 0.055f - em * 0.8f - slide, y1 = vr * 0.86f, y0 = y1 - h;
                    g.SetClip(new Rectangle(0, 0, pw, vr));
                    // the glass: the view behind darkened and reddened, interlaced, brighter on a fresh hit
                    int ix0 = Math.Max(0, (int)x0), ix1 = Math.Min(pw, (int)(x0 + w)), iy0 = Math.Max(0, (int)y0), iy1 = Math.Min(vr, (int)y1);
                    for (int py = iy0; py < iy1; py++)
                    {
                        float k = (float)(1 - a * (((py - iy0) % 3 == 0) ? 0.70 : 0.58)), red = (float)(a * (0.10 + 0.22 * hitK));
                        for (int px = ix0; px < ix1; px++)
                        {
                            int c = pic[py * pw + px]; float r = ((c >> 16) & 255) * k, gg = ((c >> 8) & 255) * k, b = (c & 255) * k;
                            r += (((Alert >> 16) & 255) - r) * red; gg += (((Alert >> 8) & 255) - gg) * red * 0.35f; b += ((Alert & 255) - b) * red * 0.35f;
                            pic[py * pw + px] = ((int)Math.Min(255, r) << 16) | ((int)Math.Min(255, gg) << 8) | (int)Math.Min(255, b);
                        }
                    }
                    var col = Color.FromArgb((int)(255 * a), Color.FromArgb(Alert));
                    // the visor's corner brackets, kicked out a little by each hit
                    float kick = (float)(em * 0.35 * hitK), L = em * 0.65f;
                    using (var pen = new Pen(col, Math.Max(2f, em / 9f)))
                    {
                        float bx0 = x0 - kick, by0 = y0 - kick, bx1 = x0 + w + kick, by1 = y1 + kick;
                        g.DrawLines(pen, new[] { new PointF(bx0, by0 + L), new PointF(bx0, by0), new PointF(bx0 + L, by0) });
                        g.DrawLines(pen, new[] { new PointF(bx1 - L, by0), new PointF(bx1, by0), new PointF(bx1, by0 + L) });
                        g.DrawLines(pen, new[] { new PointF(bx0, by1 - L), new PointF(bx0, by1), new PointF(bx0 + L, by1) });
                        g.DrawLines(pen, new[] { new PointF(bx1 - L, by1), new PointF(bx1, by1), new PointF(bx1, by1 - L) });
                        // the warning sign, pulsing
                        float cx = x0 + pad + icon / 2, cy = (y0 + y1) / 2, s = icon * (float)(1 + 0.12 * hitK);
                        var tri = new[] { new PointF(cx, cy - s * 0.52f), new PointF(cx + s * 0.58f, cy + s * 0.46f), new PointF(cx - s * 0.58f, cy + s * 0.46f) };
                        double pulse = 0.65 + 0.35 * Math.Cos(t * 7.5);
                        using (var fill = new SolidBrush(Color.FromArgb((int)(70 * a * pulse), Color.FromArgb(Alert)))) g.FillPolygon(fill, tri);
                        g.DrawPolygon(pen, tri);
                        g.DrawLine(pen, cx, cy - s * 0.18f, cx, cy + s * 0.14f);
                        using (var dot = new SolidBrush(col)) g.FillEllipse(dot, cx - s * 0.06f, cy + s * 0.24f, s * 0.12f, s * 0.12f);
                    }
                    // the words: a red split on a fresh hit, then steady
                    float tx = x0 + pad + icon + em * 0.55f, ty = (y0 + y1) / 2 - em * 0.62f;
                    float split = (float)(em * 0.22 * hitK);
                    if (split > 0.3f) using (var ghost = new SolidBrush(Color.FromArgb((int)(150 * a), Color.FromArgb(Alert)))) Crisp.Text(g, BadgeText, font, ghost, tx + split, ty, StringFormat.GenericTypographic);
                    using (var ink = new SolidBrush(Color.FromArgb((int)(250 * a), Color.FromArgb(AlertText)))) Crisp.Text(g, BadgeText, font, ink, tx - split * 0.4f, ty, StringFormat.GenericTypographic);
                }
            }
            finally { hnd.Free(); }
        }
        public bool DrawOver(int[] pic, int pw, int ph)
        {
            int vr = Math.Min(ph, _ov != null ? _ov.ViewRowsOf(ph) : ph);
            bool badge = BadgePlaying; if (badge) DrawBadge(pic, pw, ph, vr);
            var lines = _lines; if (lines == null) return badge;
            double t = _clock.Elapsed.TotalSeconds, a = Alpha(t);
            if (a <= 0.01) return badge;
            float em = Math.Max(14f, vr / 42f), lh = em * 1.45f, x = pw * 0.055f, y = vr * 0.10f;
            int maxLen = 0; foreach (var L in lines) maxLen = Math.Max(maxLen, L.Length);
            // a faint dark backing, soft at its edges, so the text reads over a bright wall
            int bx0 = (int)(x - em * 0.8f), by0 = (int)(y - em * 0.6f), bx1 = (int)(x + em * 0.6f * maxLen + em * 0.8f), by1 = (int)(y + lh * lines.Length + em * 0.3f);
            float feather = em * 0.9f;
            for (int py = Math.Max(0, by0); py < Math.Min(vr, by1); py++)
            {
                float ey = Math.Min(py - by0, by1 - 1 - py) / feather; if (ey > 1) ey = 1;
                for (int px = Math.Max(0, bx0); px < Math.Min(pw, bx1); px++)
                {
                    float ex = Math.Min(px - bx0, bx1 - 1 - px) / feather; if (ex > 1) ex = 1;
                    float k = 1f - 0.45f * (float)a * ex * ey; int c = pic[py * pw + px];
                    pic[py * pw + px] = ((int)(((c >> 16) & 255) * k) << 16) | ((int)(((c >> 8) & 255) * k) << 8) | (int)((c & 255) * k);
                }
            }
            var hnd = GCHandle.Alloc(pic, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(pw, ph, pw * 4, PixelFormat.Format32bppRgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                using (var font = Crisp.Font(em, FontStyle.Bold))
                using (var head = new SolidBrush(Color.FromArgb((int)(245 * a), Color.FromArgb(AmberHi))))
                using (var flare = new SolidBrush(Color.FromArgb((int)(255 * a), Color.FromArgb(InkFlare))))
                {
                    g.SetClip(new Rectangle(0, 0, pw, vr));
                    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                    for (int i = 0; i < lines.Length; i++)
                    {
                        double t0 = LineStart(i); if (t < t0) break;
                        string L = lines[i]; int shown = Math.Min(L.Length, (int)((t - t0) * Cps)); bool typing = shown < L.Length;
                        string txt = L.Substring(0, shown) + (typing && ((int)(t * 8) & 1) == 0 ? "_" : "");
                        // the first line in the header's amber; the rest in the scanner's ink, breathing gently once typed
                        double breath = typing ? 1 : 0.78 + 0.22 * Math.Cos((t - t0) * 3.2);
                        using (var ink = new SolidBrush(Color.FromArgb((int)(235 * a * breath), Color.FromArgb(Ink))))
                            Crisp.Text(g, txt, font, i == 0 ? head : (typing ? flare : ink), x, y + i * lh);
                    }
                }
            }
            finally { hnd.Free(); }
            return true;
        }
    }

    /// <summary>THE VISOR'S "Scanning..." LABEL (Josh, 2026-10-13: "for this new animation, each time it shows, I want a small
    /// 'Scanning...' label to appear in the lower right of the visor area in typical in-universe style. It will be on screen
    /// the same amount of time as the wireframes so very brief"). While the room materializes (GpuRaster.MatTagK): the damage
    /// badge's dark glass plate and corner brackets, at the lower left (moved from the right, 2026-10-13), in the scan's teal -- a turning radar sweep,
    /// the word with its dots ticking on, and a thin bar that fills as the wave crosses the room (MatProgress). It flickers
    /// on and fades with the outlines' trail. Drawn here (GDI+, premultiplied) Fps times a second; the card lays it over the
    /// picture in its present pass (GpuRaster.SetTag), so the frames never come back through the processor for it.</summary>
    public class ScanTag
    {
        public int Ink = 0x5FD8C0, Flare = 0xCFFFF4, Glass = 0x021214;
        public string Text = "Mapping environment";      // (Josh, 2026-10-13: was "Scanning"; the dots tick on after it)
        /// <summary>The same badge on the 3D map while its lights draw it (GpuRaster.MapTagK; Josh, 2026-10-14).</summary>
        public string MapText = "Accessing Map Data";
        /// <summary>...and on the visor's echo scan (V), in its amber (GpuRaster.EchoTagK; Josh, 2026-10-14).</summary>
        public string EchoText = "Gathering Environmental Data";
        public int EchoInk = 0xFFB040, EchoFlare = 0xFFE3A6, EchoGlass = 0x140C02;
        int _ink = 0x5FD8C0, _flare = 0xCFFFF4, _glass = 0x021214;
        /// <summary>The gap between the badge and the panel under it (window px at a 1238-row view; it scales with the view).</summary>
        public float AbovePanel = 20f;
        public double FadeIn = 0.18, Fps = 40;
        public bool Enabled = true;
        public long Shows;
        readonly Overlay _ov; readonly Stopwatch _clock = Stopwatch.StartNew();
        double _onAt = -1, _drawnAt = -1; int[] _px; int _w, _h; float _em = -1, _textW; string _shown, _textFor;
        public ScanTag(Overlay ov) { _ov = ov; }
        static double Noise(int i) { uint h = (uint)i * 2654435761u; h ^= h >> 13; h *= 0x5bd1e995; h ^= h >> 15; return (h & 0xFFFF) / 65535.0; }
        static Font FontOf(float em) { return Crisp.Font(em, FontStyle.Bold); }
        /// <summary>Every frame, on the card's thread, before the picture is presented.</summary>
        public void Step(GpuRaster gpu)
        {
            // which message: the room materializing (teal), the map drawing (teal), the echo scan (amber) -- the strongest shows
            float kMat = Enabled ? gpu.MatTagK : 0f, kMap = Enabled ? gpu.MapTagK : 0f, kEcho = Enabled ? gpu.EchoTagK : 0f;
            int which = kMap > kMat && kMap >= kEcho ? 1 : kEcho > kMat ? 2 : 0;
            float k = which == 1 ? kMap : which == 2 ? kEcho : kMat;
            float prog = which == 1 ? gpu.MapTagProgress : which == 2 ? gpu.EchoTagProgress : gpu.MatProgress;
            string want = which == 1 ? MapText : which == 2 ? EchoText : Text;
            if (want != _shown) { _shown = want; _onAt = -1; }          // (a new message: it flickers on afresh)
            if (which == 2) { _ink = EchoInk; _flare = EchoFlare; _glass = EchoGlass; } else { _ink = Ink; _flare = Flare; _glass = Glass; }
            double now = _clock.Elapsed.TotalSeconds;
            if (k <= 0.001f) { _onAt = -1; gpu.TagOn = false; return; }
            if (_onAt < 0) { _onAt = now; _drawnAt = -1; Shows++; }
            int W = gpu.PresentW, H = gpu.PresentH; if (W < 64 || H < 64) { gpu.TagOn = false; return; }
            if (_drawnAt >= 0 && now - _drawnAt < 1.0 / Fps) return;           // (the last one stays on the card)
            _drawnAt = now;
            double t = now - _onAt, a = Math.Min(1.0, t / FadeIn) * k;
            if (t < 0.22 && Noise((int)(t * 60)) < 0.3 + 0.5 * (1 - t / 0.22)) a *= 0.2;      // (a ragged flicker on)
            int vr = Math.Max(64, Math.Min(H, _ov != null ? _ov.ViewRowsOf(H) : H));
            float x, y; var px = Render(t, a, prog, W, vr, out x, out y);
            gpu.SetTag(px, _w, _h, x, y);
        }
        /// <summary>The label at time t (s) and strength a, for a window W wide whose view is vr rows: its pixels (premultiplied
        /// ARGB, _w x _h) and where its top left goes (window px).</summary>
        public int[] Render(double t, double a, float prog, int W, int vr, out float x, out float y)
        {
            float em = Math.Max(12f, vr / 58f), pad = em * 0.7f, icon = em * 1.2f;
            string text = _shown ?? Text;
            if (em != _em || text != _textFor)
            {
                _em = em; _textFor = text;
                using (var b = new Bitmap(1, 1)) using (var g = Graphics.FromImage(b)) using (var f = FontOf(em))
                    _textW = g.MeasureString(text + "...", f, PointF.Empty, StringFormat.GenericTypographic).Width;   // (the plate keeps its size as the dots come)
            }
            float bw = pad + icon + em * 0.55f + _textW + pad, bh = em * 2.3f, margin = em * 0.3f;
            int w = (int)Math.Ceiling(bw + 2 * margin), h = (int)Math.Ceiling(bh + 2 * margin);
            // (the lower LEFT of the visor -- Josh, 2026-10-13: "on the left side of the visor, not the right" -- where the
            // damage badge and the conversation badge sit; none of them shows at the same moment as a room materializing)
            // (MOVED to the MIDDLE, just above the panel -- Josh, 2026-10-14: "move the 'accessing map data' badge to the middle, just
            // above the UI by about 20px padding, same goes for the 'Mapping Environment' badge which should use the exact same style":
            // the view's last row is the panel's top, PanelTop)
            x = W * 0.5f - w * 0.5f; y = vr - AbovePanel * vr / 1238f - bh - margin;
            if (_px == null || _px.Length != w * h) _px = new int[w * h]; else Array.Clear(_px, 0, _px.Length);
            _w = w; _h = h;
            var hnd = GCHandle.Alloc(_px, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(w, h, w * 4, PixelFormat.Format32bppPArgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                using (var font = FontOf(em))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                    float x0 = margin, y0 = margin, x1 = margin + bw, y1 = margin + bh;
                    // the glass: the view behind darkened toward a teal black, interlaced
                    using (var gb = new SolidBrush(Color.FromArgb((int)(150 * a), Color.FromArgb(_glass)))) g.FillRectangle(gb, x0, y0, bw, bh);
                    using (var il = new SolidBrush(Color.FromArgb((int)(55 * a), Color.Black))) for (float yy = y0; yy < y1; yy += 3) g.FillRectangle(il, x0, yy, bw, 1);
                    var ink = Color.FromArgb((int)(235 * a), Color.FromArgb(_ink));
                    // the visor's corner brackets
                    float L = em * 0.6f;
                    using (var pen = new Pen(ink, Math.Max(1.5f, em / 9f)))
                    {
                        g.DrawLines(pen, new[] { new PointF(x0, y0 + L), new PointF(x0, y0), new PointF(x0 + L, y0) });
                        g.DrawLines(pen, new[] { new PointF(x1 - L, y0), new PointF(x1, y0), new PointF(x1, y0 + L) });
                        g.DrawLines(pen, new[] { new PointF(x0, y1 - L), new PointF(x0, y1), new PointF(x0 + L, y1) });
                        g.DrawLines(pen, new[] { new PointF(x1 - L, y1), new PointF(x1, y1), new PointF(x1, y1 - L) });
                    }
                    // the radar: two rings, a fading wedge behind a turning arm
                    float cx = x0 + pad + icon / 2, cy = y0 + bh * 0.45f, r = icon * 0.46f;
                    using (var thin = new Pen(Color.FromArgb((int)(140 * a), Color.FromArgb(_ink)), Math.Max(1f, em / 14f)))
                    {
                        g.DrawEllipse(thin, cx - r, cy - r, 2 * r, 2 * r); g.DrawEllipse(thin, cx - r * 0.5f, cy - r * 0.5f, r, r);
                    }
                    double ang = t * 300.0 % 360.0;       // (degrees: a turn every 1.2 s)
                    for (int i = 0; i < 6; i++)
                        using (var wb = new SolidBrush(Color.FromArgb((int)(75 * a * (1 - i / 6.0)), Color.FromArgb(_ink))))
                            g.FillPie(wb, cx - r, cy - r, 2 * r, 2 * r, (float)(ang - 10 * (i + 1)), 10f);
                    double ar = ang * Math.PI / 180;
                    using (var arm = new Pen(Color.FromArgb((int)(250 * a), Color.FromArgb(_flare)), Math.Max(1.5f, em / 10f)))
                        g.DrawLine(arm, cx, cy, cx + r * (float)Math.Cos(ar), cy + r * (float)Math.Sin(ar));
                    // the word, its dots ticking on
                    string s = text + new string('.', (int)(t * 3.2) % 4);
                    float tx = cx + icon / 2 + em * 0.55f, ty = cy - em * 0.62f;
                    using (var tb = new SolidBrush(ink)) Crisp.Text(g, s, font, tb, tx, ty, StringFormat.GenericTypographic);
                    // the bar: how far the wave has crossed the room
                    float by = y1 - em * 0.42f, bx0 = tx, bx1 = x1 - pad, fx = bx0 + (bx1 - bx0) * Math.Max(0f, Math.Min(1f, prog));
                    using (var track = new Pen(Color.FromArgb((int)(70 * a), Color.FromArgb(_ink)), Math.Max(1f, em / 12f))) g.DrawLine(track, bx0, by, bx1, by);
                    if (fx > bx0 + 0.5f) using (var fill = new Pen(Color.FromArgb((int)(240 * a), Color.FromArgb(_flare)), Math.Max(1.5f, em / 9f))) g.DrawLine(fill, bx0, by, fx, by);
                }
            }
            finally { hnd.Free(); }
            return _px;
        }
    }
    /// <summary>VISOR CONDENSATION (Josh, 2026-10-14: "steam in the spa rooms fogs the edges of your visor, then clears"). In a
    /// room with steam (the watcher passes it), the visor mists over from its edges: in over FogIn seconds on entering, held a
    /// little, then evaporating back toward the edges (ClearSeconds) to a faint rim (Rest) -- with now and then a fresh waft of
    /// steam (every WaftEvery seconds, give or take) that mists it again partway. Leaving the room it clears (LeaveSeconds).
    /// The card draws it in the present pass (GpuRaster.VisorFog: the edge haze, the picture softened behind it, beads of
    /// water at its inner edge); this only sets how far in it reaches.</summary>
    public class VisorFog
    {
        // (clearing much slower -- Josh, 2026-10-14: 'make the condensation disappear much slower': ClearSeconds 7 -> 18, LeaveSeconds 4 -> 10,
        // evaporating at 1/4 s instead of 1/1.5 s)
        public double FogIn = 1.6, Hold = 2.5, ClearSeconds = 18.0, Rest = 0.22, LeaveSeconds = 10.0, WaftEvery = 22, WaftPeak = 0.75, WaftIn = 1.2;
        public float Strength = 1f;
        /// <summary>How far the mist runs on below the view's bottom row, as a share of the window's height (Josh, 2026-10-14:
        /// its bottom edge showed as a hard line above the panel art -- "move the bottom portion ... down by around 100px": 0.065
        /// of his 1536-row window), so its cut-off lies behind the panel.</summary>
        public float BelowPanel = 0.065f;
        public bool Enabled = true;
        readonly Overlay _ov; readonly Stopwatch _clock = Stopwatch.StartNew(); readonly Random _rnd = new Random();
        double _k, _stepAt = -1, _inSince = -1, _waftAt = -1, _waftT = -1;
        public VisorFog(Overlay ov) { _ov = ov; }
        public double Level { get { return _k; } }
        /// <summary>Every frame, before the picture is presented: whether the room steams (and the visor is in use -- no map,
        /// no boot cover).</summary>
        public void Step(GpuRaster gpu, bool steamy)
        {
            double now = _clock.Elapsed.TotalSeconds, dt = _stepAt < 0 ? 0 : Math.Min(0.25, now - _stepAt); _stepAt = now;
            steamy = steamy && Enabled;
            double target;
            if (!steamy) { _inSince = -1; _waftT = -1; target = 0; _k = Math.Max(0, _k - dt / LeaveSeconds); }
            else
            {
                if (_inSince < 0) { _inSince = now; _waftAt = now + WaftEvery * (0.8 + 0.6 * _rnd.NextDouble()); }
                double t = now - _inSince;
                // entering: up to full, held, then clearing to the rest level
                if (t < FogIn) target = t / FogIn;
                else if (t < FogIn + Hold) target = 1;
                else target = Math.Max(Rest, 1 - (t - FogIn - Hold) / ClearSeconds);
                // a waft of steam: up to WaftPeak and away again
                if (now >= _waftAt && _waftT < 0) { _waftT = now; _waftAt = now + WaftEvery * (0.7 + 0.6 * _rnd.NextDouble()); }
                if (_waftT >= 0)
                {
                    double w = now - _waftT, wk = w < WaftIn ? w / WaftIn : Math.Max(0, 1 - (w - WaftIn - 1.0) / ClearSeconds);
                    if (w > WaftIn + 1.0 + ClearSeconds) _waftT = -1;
                    target = Math.Max(target, WaftPeak * Math.Min(1, wk));
                }
                // fogging is quick, evaporating slow
                double rate = target > _k ? 1.0 / 0.35 : 1.0 / 4.0;
                _k += (target - _k) * Math.Min(1, dt * rate);
            }
            int H = gpu.PresentH; int vr = Math.Max(64, Math.Min(H, _ov != null ? _ov.ViewRowsOf(H) : H));
            gpu.VisorFogAmount = Math.Min(1f, Strength);      // (a lighter room: thinner as well as narrower)
            gpu.VisorFog = (float)(_k * Strength); gpu.VisorFogTime = (float)(now % 1000.0); gpu.VisorFogRows = H > 0 ? Math.Min(1f, (float)vr / H + BelowPanel) : 1f;
        }
    }
    /// <summary>THE VISOR RECORDS A CONVERSATION (Josh, 2026-10-13: in place of the original's red glow, "a subtle amber glow
    /// that is on the outside edge of the visor anytime the character is engaged with a npc dialogue. Then a small soundwave
    /// icon at the bottom left of the visor, with small text beneath: Conversation recording engaged..."). While a
    /// conversation is up ([0x152B1C]; the watcher passes it and whether a line is being spoken, [0x152B28]): the visor's
    /// edges glow amber, breathing slowly (GpuRaster.ConvGlow, in the present pass), and at the lower left -- the scanning
    /// label's plate mirrored, in the visor's amber -- a soundwave that moves with the voice (calm while nobody speaks), a
    /// recording dot, and the words beneath, their dots ticking on. It flickers on like the scanning label and fades out
    /// when the conversation ends. Drawn here Fps times a second; the card lays it over the picture (GpuRaster.SetTag2).</summary>
    public class ConvTag
    {
        public int Ink = 0xFFB040, Flare = 0xFFE2B0, Glass = 0x140C02;
        public string Text = "Conversation recording engaged";
        public double FadeIn = 0.18, FadeOut = 0.5, GlowIn = 0.7, GlowOut = 0.9, Fps = 30;
        public float GlowStrength = 1f;
        public bool Enabled = true;
        public long Shows;
        readonly Overlay _ov; readonly Stopwatch _clock = Stopwatch.StartNew();
        double _onAt = -1, _drawnAt = -1, _k, _glow, _stepAt = -1, _voice; int[] _px; int _w, _h; float _em = -1, _textW;
        public ConvTag(Overlay ov) { _ov = ov; }
        static double Noise(int i) { uint h = (uint)i * 2654435761u; h ^= h >> 13; h *= 0x5bd1e995; h ^= h >> 15; return (h & 0xFFFF) / 65535.0; }
        static Font FontOf(float em) { return Crisp.Font(em, FontStyle.Bold); }
        /// <summary>Every frame, on the card's thread, before the picture is presented: a conversation is up; a line is
        /// being spoken.</summary>
        public void Step(GpuRaster gpu, bool conv, bool speaking)
        {
            double now = _clock.Elapsed.TotalSeconds, dt = _stepAt < 0 ? 0 : Math.Min(0.25, now - _stepAt); _stepAt = now;
            bool on = Enabled && conv;
            _k = on ? Math.Min(1, _k + dt / FadeIn) : Math.Max(0, _k - dt / FadeOut);
            _glow = on ? Math.Min(1, _glow + dt / GlowIn) : Math.Max(0, _glow - dt / GlowOut);
            _voice += ((speaking ? 1.0 : 0.0) - _voice) * Math.Min(1, dt * 6);           // (the wave eases between talk and quiet)
            int W = gpu.PresentW, H = gpu.PresentH;
            int vr = Math.Max(64, Math.Min(H, _ov != null ? _ov.ViewRowsOf(H) : H));
            double g = _glow * _glow * (3 - 2 * _glow);
            gpu.ConvGlow = (float)(g * GlowStrength); gpu.ConvTime = (float)(now % 1000.0); gpu.ConvRows = H > 0 ? (float)vr / H : 1f;
            if (_k <= 0.001) { _onAt = -1; gpu.Tag2On = false; return; }
            if (_onAt < 0) { _onAt = now; _drawnAt = -1; Shows++; }
            if (W < 64 || H < 64) { gpu.Tag2On = false; return; }
            if (_drawnAt >= 0 && now - _drawnAt < 1.0 / Fps) return;           // (the last one stays on the card)
            _drawnAt = now;
            double t = now - _onAt, a = _k;
            if (on && t < 0.22 && Noise((int)(t * 60) + 17) < 0.3 + 0.5 * (1 - t / 0.22)) a *= 0.2;      // (a ragged flicker on)
            float x, y; var px = Render(t, a, _voice, W, vr, out x, out y);
            gpu.SetTag2(px, _w, _h, x, y);
        }
        /// <summary>The badge at time t (s), strength a and voice 0..1 (a line being spoken), for a window W wide whose view
        /// is vr rows: its pixels (premultiplied ARGB, _w x _h) and where its top left goes (window px).</summary>
        public int[] Render(double t, double a, double voice, int W, int vr, out float x, out float y)
        {
            float em = Math.Max(12f, vr / 58f), sem = em * 0.78f, pad = em * 0.7f;
            if (em != _em)
            {
                _em = em;
                using (var b = new Bitmap(1, 1)) using (var g = Graphics.FromImage(b)) using (var f = FontOf(sem))
                    _textW = g.MeasureString(Text + "...", f, PointF.Empty, StringFormat.GenericTypographic).Width;   // (the plate keeps its size as the dots come)
            }
            float waveH = em * 1.25f, bw = pad + _textW + pad, bh = pad * 0.8f + waveH + em * 0.35f + sem * 1.15f + pad * 0.7f, margin = em * 0.3f;
            int w = (int)Math.Ceiling(bw + 2 * margin), h = (int)Math.Ceiling(bh + 2 * margin);
            x = W * 0.055f - em * 0.8f - margin; y = vr * 0.86f - bh - margin;
            if (_px == null || _px.Length != w * h) _px = new int[w * h]; else Array.Clear(_px, 0, _px.Length);
            _w = w; _h = h;
            var hnd = GCHandle.Alloc(_px, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(w, h, w * 4, PixelFormat.Format32bppPArgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                using (var font = FontOf(sem))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                    float x0 = margin, y0 = margin, x1 = margin + bw, y1 = margin + bh;
                    // the glass: the view behind darkened toward an amber black, interlaced
                    using (var gb = new SolidBrush(Color.FromArgb((int)(140 * a), Color.FromArgb(Glass)))) g.FillRectangle(gb, x0, y0, bw, bh);
                    using (var il = new SolidBrush(Color.FromArgb((int)(55 * a), Color.Black))) for (float yy = y0; yy < y1; yy += 3) g.FillRectangle(il, x0, yy, bw, 1);
                    var ink = Color.FromArgb((int)(235 * a), Color.FromArgb(Ink));
                    // the visor's corner brackets
                    float L = em * 0.6f;
                    using (var pen = new Pen(ink, Math.Max(1.5f, em / 9f)))
                    {
                        g.DrawLines(pen, new[] { new PointF(x0, y0 + L), new PointF(x0, y0), new PointF(x0 + L, y0) });
                        g.DrawLines(pen, new[] { new PointF(x1 - L, y0), new PointF(x1, y0), new PointF(x1, y0 + L) });
                        g.DrawLines(pen, new[] { new PointF(x0, y1 - L), new PointF(x0, y1), new PointF(x0 + L, y1) });
                        g.DrawLines(pen, new[] { new PointF(x1 - L, y1), new PointF(x1, y1), new PointF(x1, y1 - L) });
                    }
                    // the recording dot, breathing
                    float wy0 = y0 + pad * 0.8f, cy = wy0 + waveH / 2, dr = em * 0.2f, dx = x0 + pad + dr;
                    double pulse = 0.55 + 0.45 * Math.Sin(t * 4.2);
                    using (var db = new SolidBrush(Color.FromArgb((int)(250 * a * pulse), Color.FromArgb(Flare)))) g.FillEllipse(db, dx - dr, cy - dr, 2 * dr, 2 * dr);
                    using (var dg = new Pen(Color.FromArgb((int)(90 * a * pulse), Color.FromArgb(Ink)), Math.Max(1f, em / 14f))) g.DrawEllipse(dg, dx - dr * 1.9f, cy - dr * 1.9f, dr * 3.8f, dr * 3.8f);
                    // the soundwave: bars across the plate, moving with the voice (a low ripple while nobody speaks), the
                    // middle ones tallest; a thin centre line under them
                    float bx0 = dx + dr * 2.8f, bx1 = x1 - pad;
                    int n = Math.Max(12, (int)((bx1 - bx0) / (em * 0.32f)));
                    float step = (bx1 - bx0) / n, bwid = Math.Max(1.2f, step * 0.5f);
                    using (var cl = new Pen(Color.FromArgb((int)(70 * a), Color.FromArgb(Ink)), Math.Max(1f, em / 16f))) g.DrawLine(cl, bx0, cy, bx1, cy);
                    for (int i = 0; i < n; i++)
                    {
                        double u = (i + 0.5) / n, env = Math.Sin(Math.PI * u);
                        double talk = 0.25 + 0.75 * Math.Abs(Math.Sin(t * 9.0 + i * 0.9) * Math.Sin(t * 5.3 + i * 0.37 + 1.7)) * (0.6 + 0.4 * Noise((int)(t * 14) * 97 + i));
                        double calm = 0.10 + 0.08 * Math.Sin(t * 2.4 - u * 9.0);
                        double hgt = (calm + (talk - calm) * voice) * (0.35 + 0.65 * env);
                        float hh = (float)Math.Max(1.0, hgt * waveH * 0.5), bx = bx0 + step * i + (step - bwid) / 2;
                        var col = Color.FromArgb((int)(a * (150 + 90 * env)), Color.FromArgb(hgt > 0.55 ? Flare : Ink));
                        using (var bb = new SolidBrush(col)) g.FillRectangle(bb, bx, cy - hh, bwid, 2 * hh);
                    }
                    // the words beneath, their dots ticking on
                    string s = Text + new string('.', (int)(t * 2.4) % 4);
                    float tx = x0 + pad, ty = wy0 + waveH + em * 0.35f;
                    using (var tb = new SolidBrush(ink)) Crisp.Text(g, s, font, tb, tx, ty, StringFormat.GenericTypographic);
                }
            }
            finally { hnd.Free(); }
            return _px;
        }
    }
    /// <summary>THE DAMAGED VISOR (Josh, 2026-10-10: "on that same signal when the damage taken badge displays, I want to see
    /// distortion/static on the visor ... As the health gets lower, i want to see more and more damage on the visor, like
    /// scratches at first, dirt etc., then more and more cracks, a broken piece from one corner when near death, and a small
    /// heart rate signal (just like in the intro animation) when near death ... really sell the idea that you're wearing an
    /// operating system visor").
    /// The glass is one layer drawn here, off the game's thread, for the damage it has taken (GpuRaster.SetVisorLayer):
    /// dust and grime first, hairline scratches, a raptor's claw rake, then impact cracks that spread as the damage grows
    /// (each crack system has its own threshold and grows along its own lines -- the same glass, never re-dealt), and near
    /// death a top corner broken away (BreakLeft: the LEFT one), the display dead behind it, its liquid crystal bleeding in. The present pass
    /// lays it over the picture with the cracks bending the view behind them (FS_PRESENT). A hit tears and splits the
    /// display for a moment (Hit); mending (health back) is a teal sweep down the glass. Near death a vitals monitor --
    /// the boot's oscilloscope ECG, racing and irregular -- sits above the damage badge, and the visor's edges pulse red with
    /// each beat. Everything is fixed by Seed; the units follow the view's height, so it is the same glass at any size.</summary>
    public class VisorDamage
    {
        public int Seed = 7331;
        public double HitSeconds = 0.42, SweepSeconds = 1.3, WidgetFrom = 0.75;
        public int Amber = 0xFFB040, Alert = 0xFF4A2E, AlertText = 0xFFD9C9;
        public bool Enabled = true;
        readonly Overlay _ov; readonly Stopwatch _clock = Stopwatch.StartNew();
        public VisorDamage(Overlay ov) { _ov = ov; }
        /// <summary>The visor's menus (the watcher sets it): behind an open panel the damage fades away -- in over FadeIn s as
        /// it opens, back over FadeOut s after it closes (Josh, 2026-10-10: "fade the damage behind open menus").</summary>
        public VisorMenu Menus; public double ClearFadeIn = 0.2, ClearFadeOut = 0.3;
        double _clrK, _clrAt = -1; float[] _clrLast;
        /// <summary>The damage the glass shows (1 - health), and builds of its layer so far / the last one's time.</summary>
        public double Level; public long Builds; public double LastBuildMs; public string LastError;
        /// <summary>The vitals monitor's beep on each beat while it shows (Josh: "pretty quiet" -- its own BootSound, at a
        /// low Volume); null = silent.</summary>
        public BootSound Sound;
        /// <summary>Dying: how long the heart takes to stop; how long the flat line's tone sounds; deaths seen.</summary>
        public double DeathSeconds = 6, FlatlineSeconds = 4; public long Deaths;
        double _deathAt = -1, _deadBpm, _flatAt = -1;
        public bool Flatlined { get { return _flatAt >= 0; } }
        double _hitAt = -99, _hitK = 1; float _hitSeed;
        double _shown = -1; int _shownW, _shownH;
        System.Threading.Tasks.Task<Layer> _job;
        double _sweepAt = -1, _widA, _widAt = -1;
        readonly Random _rnd = new Random(11);
        // the heart: R spikes (s, amplitude)
        readonly List<double> _beatT = new List<double>(), _beatA = new List<double>(); double _nextBeat = -1;
        public double Bpm;

        /// <summary>A hit (strength 0..1: how much of the health went).</summary>
        public void Hit(double strength)
        {
            _hitAt = _clock.Elapsed.TotalSeconds; _hitK = Math.Max(0.45, Math.Min(1, strength)); _hitSeed = (float)(_rnd.NextDouble() * 100);
        }
        double ViewFrac(int h) { return _ov != null && h > 0 ? Math.Max(0.3, Math.Min(1.0, _ov.ViewRowsOf(h) / (double)h)) : 1.0; }

        /// <summary>Every frame, on the card's thread, before the picture is presented: health 0..1 (negative = not known:
        /// the glass shows none of it).</summary>
        public void Step(GpuRaster gpu, double health)
        {
            double now = _clock.Elapsed.TotalSeconds;
            Level = !Enabled || health < 0 ? 0 : Math.Max(0, Math.Min(1, 1 - health));
            // DEATH (Josh, 2026-10-10: "If you die from damage and the system menu comes up, lets have the heart rate slowly
            // flat line"): health at nothing -- the heart slows and weakens over DeathSeconds, stops, and the monitor holds a
            // flat line with its long tone; the display fails with it (VisorDeath). A load (health back, or not known while
            // the boot covers the view) ends it.
            bool dead = Enabled && health >= 0 && health <= 0.0005;
            if (dead && _deathAt < 0) { _deathAt = now; _deadBpm = Math.Max(60, Bpm); _flatAt = -1; Deaths++; }
            if (!dead) { _deathAt = -1; _flatAt = -1; }
            int w = gpu.PresentW, h = gpu.PresentH;
            if (w >= 64 && h >= 64)
            {
                // a finished layer goes to the card; a lighter one (the glass mending) sweeps in
                if (_job != null && _job.IsCompleted)
                {
                    Layer L = null; try { L = _job.Result; } catch (Exception e) { LastError = e.GetBaseException().Message; }
                    _job = null;
                    if (L != null)
                    {
                        bool mend = _shown > 0 && L.Level < _shown - 1e-6;
                        gpu.SetVisorLayer(L.Paint, L.W, L.H, L.Fx, L.FW, L.FH);
                        if (mend) _sweepAt = now;
                        _shown = L.Level; _shownW = L.W; _shownH = L.H; Builds++; LastBuildMs = L.Ms;
                    }
                }
                double q = Math.Round(Level * 40) / 40.0;
                if (_job == null && (Math.Abs(q - _shown) > 1e-6 || w != _shownW || h != _shownH))
                {
                    int sd = Seed; double vf = ViewFrac(h);
                    _job = System.Threading.Tasks.Task.Run(() => Build(q, w, h, sd, vf));
                }
            }
            // the hit: strong at once, flickering, gone in HitSeconds
            double age = now - _hitAt, hit = 0;
            if (age < HitSeconds) { hit = _hitK * Math.Pow(1 - age / HitSeconds, 1.4); if (age < 0.12 && ((int)(age * 90) & 1) == 1) hit *= 0.55; }
            // the mending sweep
            float sweep = -1; if (_sweepAt >= 0) { double sa = (now - _sweepAt) / SweepSeconds; if (sa >= 1) _sweepAt = -1; else sweep = (float)sa; }
            double beat = Heart(now);
            gpu.VisorOn = Level > 0.004 || hit > 0 || sweep >= 0;
            gpu.VisorLevel = (float)Level; gpu.VisorHit = (float)hit; gpu.VisorHitAge = (float)Math.Max(0, age); gpu.VisorSeed = _hitSeed;
            gpu.VisorTime = (float)(now % 1000.0); gpu.VisorBeat = (float)beat; gpu.VisorSweep = sweep; gpu.VisorViewRows = (float)ViewFrac(h);
            gpu.VisorDeath = (float)(_flatAt >= 0 ? Math.Min(1, (now - _flatAt) / 4.0) : 0);
            // clear behind the open menus (the last rectangles kept while it fades back)
            {
                var cr = Menus != null ? Menus.ClearRects : null; bool up = cr != null && cr.Length >= 4;
                if (up) _clrLast = cr;
                double cdt = _clrAt < 0 ? 0 : now - _clrAt; _clrAt = now;
                _clrK = up ? Math.Min(1, _clrK + cdt / Math.Max(0.01, ClearFadeIn)) : Math.Max(0, _clrK - cdt / Math.Max(0.01, ClearFadeOut));
                gpu.VisorClear = _clrK > 0 ? _clrLast : null; gpu.VisorClearK = (float)_clrK;
            }
            // the vitals monitor near death, fading in and out
            double wa = Level >= WidgetFrom ? 1 : 0; double dt = _widAt < 0 ? 0 : now - _widAt; _widAt = now;
            _widA = wa > _widA ? Math.Min(wa, _widA + dt / 0.6) : Math.Max(wa, _widA - dt / 0.8);
            if (_widA > 0.01 && w >= 64 && h >= 64)
            {
                // 30 times a second, like the other visor labels (it was every presented frame, with two fonts made each time --
                // the 2026-10-13 audit); between, the last one stays on the card
                if (now - _widDrawnAt >= 1.0 / 30 || !gpu.VisorWidget)
                {
                    _widDrawnAt = now;
                    float rx, ry; int ww, wh; var px = Widget(now, w, h, out ww, out wh, out rx, out ry);
                    gpu.SetVisorWidget(px, ww, wh, rx, ry);
                }
            }
            else gpu.VisorWidget = false;
        }

        // ---- THE HEART near death: racing (108 -> 178 BPM), irregular, the odd beat dropped, weaker as it goes ----
        static double Gs(double x, double c, double wd, double a) { return a * Math.Exp(-(x - c) * (x - c) / (2 * wd * wd)); }
        // one beat around its R spike (s): P, Q, R, S, T -- the boot's Ecg shape in seconds
        static double Wave(double dt) { return Gs(dt, -0.16, 0.026, 0.12) + Gs(dt, -0.022, 0.008, -0.14) + Gs(dt, 0, 0.011, 1.0) + Gs(dt, 0.022, 0.010, -0.28) + Gs(dt, 0.2, 0.045, 0.26); }
        double Heart(double now)
        {
            // (from half health the heart quickens and the visor's edges pulse with it; the monitor and its beeps near death)
            double sev = Math.Max(0, Math.Min(1, (Level - WidgetFrom) / (1 - WidgetFrom))), from = Math.Max(0, Math.Min(1, (Level - 0.5) / 0.5));
            // dying: the rate falls from where it was to nothing over DeathSeconds, the beats weaken and come unevenly
            double life = _deathAt < 0 ? 1 : Math.Max(0, 1 - (now - _deathAt) / DeathSeconds);
            Bpm = _deathAt < 0 ? 88 + 90 * from : _deadBpm * Math.Pow(life, 0.8);
            if (_nextBeat < 0 || _nextBeat < now - 2) _nextBeat = now;
            while (now >= _nextBeat && (_deathAt < 0 || Bpm >= 14))
            {
                bool drop = (sev > 0.5 && _rnd.NextDouble() < 0.14 * sev) || (_deathAt >= 0 && _rnd.NextDouble() < 0.25 * (1 - life));
                if (!drop)
                {
                    _beatT.Add(_nextBeat); _beatA.Add((1 - 0.45 * sev) * (0.85 + 0.3 * _rnd.NextDouble()) * (0.25 + 0.75 * life));
                    if (Sound != null && _widA > 0.5 && now - _nextBeat < 0.1) Sound.HeartBeep();
                }
                _nextBeat += 60.0 / Math.Max(14, Bpm) * (1 + (_rnd.NextDouble() - 0.5) * 0.2 * (0.4 + sev));
            }
            // the heart has stopped: once the last beat has passed, the flat line and its tone
            if (_deathAt >= 0 && Bpm < 14 && _flatAt < 0)
            {
                double lastB = _beatT.Count > 0 ? _beatT[_beatT.Count - 1] : -99;
                if (now - lastB > 0.7) { _flatAt = now; Bpm = 0; if (Sound != null) Sound.Flatline(FlatlineSeconds); }
            }
            if (_flatAt >= 0) Bpm = 0;
            while (_beatT.Count > 0 && _beatT[0] < now - 8) { _beatT.RemoveAt(0); _beatA.RemoveAt(0); }
            double last = _beatT.Count > 0 ? _beatT[_beatT.Count - 1] : -99;
            return Level > 0.5 ? Math.Exp(-(now - last) / 0.16) : 0;
        }
        double Ecg(double t)
        {
            double v = 0;
            for (int i = _beatT.Count - 1; i >= 0; i--) { double d = t - _beatT[i]; if (d < -0.3) continue; if (d > 0.4) break; v += _beatA[i] * Wave(d); }
            return v;
        }

        // ---- THE VITALS MONITOR: the visor's little scope above the damage badge ----
        int[] _wpx; Bitmap _wbm;
        static Color Argb(int a, int rgb) { return Color.FromArgb(Math.Max(0, Math.Min(255, a)), (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
        double _widDrawnAt = -1;
        int[] Widget(double now, int w, int h, out int ww, out int wh, out float x, out float y)
        {
            double vr = h * ViewFrac(h); float em = (float)Math.Max(12, vr / 46.0);
            ww = (int)(em * 15); wh = (int)(em * 5.6);
            float badgeEm = (float)Math.Max(13, vr / 50.0);
            x = (float)(w * 0.055 - badgeEm * 0.8); y = (float)(vr * 0.86 - badgeEm * 2.0 - em * 0.9 - wh);
            if (_wbm == null || _wbm.Width != ww || _wbm.Height != wh) { if (_wbm != null) _wbm.Dispose(); _wbm = new Bitmap(ww, wh, PixelFormat.Format32bppPArgb); _wpx = new int[ww * wh]; }
            double a = _widA, sev = Math.Max(0, Math.Min(1, (Level - WidgetFrom) / (1 - WidgetFrom)));
            using (var g = Graphics.FromImage(_wbm))
            using (var f = Crisp.Font(em * 0.62f, FontStyle.Bold))
            using (var fb = Crisp.Font(em * 0.95f, FontStyle.Bold))
            {
                g.Clear(Color.Transparent); g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                // the glass: dark, red-tinged, interlaced
                using (var bk = new SolidBrush(Argb((int)(150 * a), 0x140405))) g.FillRectangle(bk, 0, 0, ww, wh);
                using (var il = new SolidBrush(Argb((int)(60 * a), 0x000000))) for (int yy = 0; yy < wh; yy += 3) g.FillRectangle(il, 0, yy, ww, 1);
                var col = Argb((int)(235 * a), Alert); float L = em * 0.7f;
                using (var pen = new Pen(col, Math.Max(2f, em / 10f)))
                {
                    float x0 = 1, y0 = 1, x1 = ww - 2, y1 = wh - 2;
                    g.DrawLines(pen, new[] { new PointF(x0, y0 + L), new PointF(x0, y0), new PointF(x0 + L, y0) });
                    g.DrawLines(pen, new[] { new PointF(x1 - L, y0), new PointF(x1, y0), new PointF(x1, y0 + L) });
                    g.DrawLines(pen, new[] { new PointF(x0, y1 - L), new PointF(x0, y1), new PointF(x0 + L, y1) });
                    g.DrawLines(pen, new[] { new PointF(x1 - L, y1), new PointF(x1, y1), new PointF(x1, y1 - L) });
                }
                float pad = em * 0.55f;
                // the header: VITALS, and a blinking CRITICAL
                using (var am = new SolidBrush(Argb((int)(240 * a), Amber))) Crisp.Text(g, "VITALS // CARDIAC", f, am, pad, pad * 0.6f, StringFormat.GenericTypographic);
                bool blink = ((int)(now * 2.4) & 1) == 0;
                using (var rb = new SolidBrush(Argb((int)((blink ? 250 : 90) * a), Alert)))
                using (var sf = new StringFormat(StringFormat.GenericTypographic) { Alignment = StringAlignment.Far })
                    Crisp.Text(g, _flatAt >= 0 ? "NO PULSE" : _deathAt >= 0 ? "CARDIAC FAILURE" : sev > 0.6 ? "ARRHYTHMIA" : "CRITICAL", f, rb, ww - pad, pad * 0.6f, sf);
                // the scope
                float sx0 = pad, sx1 = ww - pad - em * 3.9f, sy0 = em * 1.35f, sy1 = wh - em * 1.55f, sw = sx1 - sx0, mid = sy0 + (sy1 - sy0) * 0.62f, hh = (sy1 - sy0) * 0.72f;
                using (var grid = new Pen(Argb((int)(40 * a), Alert), 1))
                {
                    for (int k = 0; k <= 4; k++) { float yy = sy0 + k * (sy1 - sy0) / 4; g.DrawLine(grid, sx0, yy, sx1, yy); }
                    for (int k = 0; k <= 10; k++) { float xx = sx0 + k * sw / 10; g.DrawLine(grid, xx, sy0, xx, sy1); }
                }
                const double Sweep = 2.4; int n = Math.Max(60, (int)(sw / 1.4f)); var pts = new PointF[n + 1];
                for (int k = 0; k <= n; k++)
                {
                    double back = k / (double)n * 0.94, tx = now - back * Sweep, xs = ((tx / Sweep) % 1.0 + 1.0) % 1.0;
                    pts[k] = new PointF(sx0 + (float)(xs * sw), mid - (float)(Ecg(tx) * hh));
                }
                g.SetClip(new RectangleF(sx0 - 2, sy0 - 2, sw + 4, sy1 - sy0 + 4));
                for (int pass = 0; pass < 2; pass++)
                    using (var pen = new Pen(Color.Black, pass == 0 ? em * 0.28f : em * 0.11f))
                    {
                        pen.LineJoin = LineJoin.Round; pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                        for (int k0 = 0; k0 < n; k0 += 6)
                        {
                            int k1 = Math.Min(n, k0 + 6); double ageK = (k0 + k1) * 0.5 / n;
                            int al = (int)(255 * a * Math.Pow(1 - ageK, 1.1) * (pass == 0 ? 0.32 : 1.0)); if (al < 4) continue;
                            pen.Color = Argb(al, pass == 0 ? Alert : 0xFF8A70);
                            int s0 = k0;
                            for (int k = k0; k < k1; k++) if (pts[k + 1].X > pts[k].X + 1) { if (k > s0) g.DrawLines(pen, Seg(pts, s0, k)); s0 = k + 1; }
                            if (k1 > s0) g.DrawLines(pen, Seg(pts, s0, k1));
                        }
                    }
                var hp = pts[0]; float r1 = em * 0.13f, r2 = em * 0.38f;
                using (var gl = new SolidBrush(Argb((int)(100 * a), Alert))) g.FillEllipse(gl, hp.X - r2, hp.Y - r2, 2 * r2, 2 * r2);
                using (var core = new SolidBrush(Argb((int)(255 * a), 0xFFE6DC))) g.FillEllipse(core, hp.X - r1, hp.Y - r1, 2 * r1, 2 * r1);
                g.ResetClip();
                // the rate, a heart that jumps with each beat, and the suit's integrity (the health)
                double last = _beatT.Count > 0 ? _beatT[_beatT.Count - 1] : -99, pulse = Math.Exp(-(now - last) / 0.12);
                float hx = sx1 + em * 0.55f, hy = sy0 + em * 0.15f, hs = em * (0.62f + 0.22f * (float)pulse);
                using (var hb = new SolidBrush(Argb((int)(255 * a), Alert))) FillHeart(g, hb, hx + em * 0.45f, hy + em * 0.45f, hs);
                using (var tb = new SolidBrush(Argb((int)(245 * a), AlertText)))
                {
                    Crisp.Text(g, _flatAt >= 0 ? "--" : ((int)Math.Round(Bpm)).ToString(), fb, tb, hx + em * 1.05f, hy - em * 0.1f, StringFormat.GenericTypographic);
                    Crisp.Text(g, "BPM", f, tb, hx + em * 1.1f, hy + em * 0.95f, StringFormat.GenericTypographic);
                }
                // the footer: the suit's integrity (the health), a bar of segments that blink out from the right
                double integ = Math.Max(0, 1 - Level); float fy = wh - em * 1.15f;
                using (var am2 = new SolidBrush(Argb((int)(220 * a), Amber)))
                    Crisp.Text(g, string.Format("SUIT INTEGRITY {0,3:0}%", integ * 100), f, am2, pad, fy, StringFormat.GenericTypographic);
                float bx0 = pad + em * 8.6f, bx1 = ww - pad, segW = (bx1 - bx0) / 10f;
                for (int sgi = 0; sgi < 10; sgi++)
                {
                    bool lit = (sgi + 0.5) / 10.0 < integ || (sgi == (int)(integ * 10) && blink);
                    using (var sb = new SolidBrush(Argb((int)((lit ? 220 : 45) * a), lit ? Alert : 0xFFFFFF)))
                        g.FillRectangle(sb, bx0 + sgi * segW + 1, fy + em * 0.08f, segW - 3, em * 0.5f);
                }
            }
            var bd = _wbm.LockBits(new Rectangle(0, 0, ww, wh), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
            Marshal.Copy(bd.Scan0, _wpx, 0, ww * wh); _wbm.UnlockBits(bd);
            return _wpx;
        }
        static PointF[] Seg(PointF[] p, int a, int b) { var s = new PointF[b - a + 1]; Array.Copy(p, a, s, 0, s.Length); return s; }
        static void FillHeart(Graphics g, Brush b, float cx, float cy, float s)
        {
            using (var gp = new GraphicsPath())
            {
                gp.AddBezier(cx, cy + s * 0.45f, cx - s * 0.75f, cy - s * 0.05f, cx - s * 0.45f, cy - s * 0.65f, cx, cy - s * 0.25f);
                gp.AddBezier(cx, cy - s * 0.25f, cx + s * 0.45f, cy - s * 0.65f, cx + s * 0.75f, cy - s * 0.05f, cx, cy + s * 0.45f);
                g.FillPath(b, gp);
            }
        }

        // ---- THE GLASS'S LAYER ----
        public class Layer { public int[] Paint, Fx; public int W, H, FW, FH; public double Level, Ms; }
        class Crack { public List<PointF> P = new List<PointF>(); public float Start; public float Width = 1; public double T; public float Reach; }
        static double Clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
        // a crack: a jittered walk from (x, y), branching now and then; its points' distance from the impact starts at `start`
        static void Walk(Random r, List<Crack> into, float x, float y, double ang, float len, float step, float start, int depth, float width, double t, float reach)
        {
            var c = new Crack { Start = start, Width = width, T = t, Reach = reach }; c.P.Add(new PointF(x, y)); into.Add(c);
            float d = 0;
            while (d < len)
            {
                // (glass cracks run straight and turn at kinks: a little drift, now and then a sharp change)
                ang += (r.NextDouble() - 0.5) * 0.16; if (r.NextDouble() < 0.14) ang += (r.NextDouble() - 0.5) * 1.1;
                float st = step * (float)(1.0 + 1.2 * r.NextDouble());
                x += (float)Math.Cos(ang) * st; y += (float)Math.Sin(ang) * st; d += st; c.P.Add(new PointF(x, y));
                if (depth < 2 && r.NextDouble() < 0.07)
                    Walk(r, into, x, y, ang + (r.NextDouble() < 0.5 ? -1 : 1) * (0.4 + 0.6 * r.NextDouble()), (len - d) * (float)(0.35 + 0.4 * r.NextDouble()), step * 0.8f, start + d, depth + 1, width * 0.65f, t, reach);
            }
        }
        // the part of a crack within `grown` of its impact
        static PointF[] Grown(Crack c, float grown)
        {
            var o = new List<PointF>(); float d = c.Start; if (d > grown) return null;
            o.Add(c.P[0]);
            for (int i = 1; i < c.P.Count; i++)
            {
                float sl = (float)Math.Sqrt((c.P[i].X - c.P[i - 1].X) * (c.P[i].X - c.P[i - 1].X) + (c.P[i].Y - c.P[i - 1].Y) * (c.P[i].Y - c.P[i - 1].Y));
                if (d + sl > grown) { float f = (grown - d) / Math.Max(1e-3f, sl); o.Add(new PointF(c.P[i - 1].X + (c.P[i].X - c.P[i - 1].X) * f, c.P[i - 1].Y + (c.P[i].Y - c.P[i - 1].Y) * f)); break; }
                d += sl; o.Add(c.P[i]);
            }
            return o.Count >= 2 ? o.ToArray() : null;
        }
        static void BoxBlur(float[] a, int w, int h, int r)
        {
            if (r <= 0) return; var t = new float[a.Length];
            for (int y = 0; y < h; y++)
            {
                float s = 0; int o = y * w;
                for (int x = -r; x <= r; x++) s += a[o + Math.Max(0, Math.Min(w - 1, x))];
                for (int x = 0; x < w; x++) { t[o + x] = s / (2 * r + 1); s += a[o + Math.Min(w - 1, x + r + 1)] - a[o + Math.Max(0, x - r)]; }
            }
            for (int x = 0; x < w; x++)
            {
                float s = 0;
                for (int y = -r; y <= r; y++) s += t[Math.Max(0, Math.Min(h - 1, y)) * w + x];
                for (int y = 0; y < h; y++) { a[y * w + x] = s / (2 * r + 1); s += t[Math.Min(h - 1, y + r + 1) * w + x] - t[Math.Max(0, y - r) * w + x]; }
            }
        }
        static float[] Channel(Bitmap b)
        {
            int w = b.Width, h = b.Height; var px = new int[w * h];
            var bd = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb); Marshal.Copy(bd.Scan0, px, 0, px.Length); b.UnlockBits(bd);
            var f = new float[w * h]; for (int i = 0; i < f.Length; i++) f[i] = ((px[i] >> 16) & 255) / 255f;
            return f;
        }
        static float VNoise(float x, float y, int seed)
        {
            int xi = (int)Math.Floor(x), yi = (int)Math.Floor(y); float fx = x - xi, fy = y - yi;
            Func<int, int, float> H = (a, b) => { uint hh = (uint)(a * 374761393 + b * 668265263 + seed * 144665); hh = (hh ^ (hh >> 13)) * 1274126177u; return ((hh ^ (hh >> 16)) & 0xFFFF) / 65535f; };
            fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
            return (H(xi, yi) * (1 - fx) + H(xi + 1, yi) * fx) * (1 - fy) + (H(xi, yi + 1) * (1 - fx) + H(xi + 1, yi + 1) * fx) * fy;
        }

        /// <summary>The glass at damage `level` for a window w x h (whose top viewFrac of rows is the view).</summary>
        /// <summary>The damage (1 - health) at which the top corner breaks away.</summary>
        public const double CornerFrom = 0.5;
        /// <summary>WHICH top corner breaks (Josh, 2026-10-10: "when the player dies of damage, we cant see the system menu due
        /// to the broken glass effect, so I want to put the broken glass effect from the top right damage to the left, but make
        /// sure we dont lose any of the other effects"). The system menu folds out on the right. true = the break is top LEFT
        /// and the claw rake, which was placed on the side away from the break, goes to the right: the whole glass mirrored,
        /// the same seed, every effect kept -- false = the original (break top right, rake left).</summary>
        public static bool BreakLeft = true;
        public static Layer Build(double level, int w, int h, int seed, double viewFrac)
        {
            var sw = Stopwatch.StartNew();
            var L = new Layer { W = w, H = h, Level = level, FW = Math.Max(1, w / 2), FH = Math.Max(1, h / 2) };
            float vr = (float)(h * viewFrac), u = vr / 1000f;
            var r = new Random(seed);
            using (var paint = new Bitmap(w, h, PixelFormat.Format32bppPArgb))
            using (var bCrack = new Bitmap(L.FW, L.FH, PixelFormat.Format32bppArgb))
            using (var bGrime = new Bitmap(L.FW, L.FH, PixelFormat.Format32bppArgb))
            using (var bDead = new Bitmap(L.FW, L.FH, PixelFormat.Format32bppArgb))
            using (var bGlitch = new Bitmap(L.FW, L.FH, PixelFormat.Format32bppArgb))
            using (var gp = Graphics.FromImage(paint))
            using (var gc = Graphics.FromImage(bCrack)) using (var gg = Graphics.FromImage(bGrime)) using (var gd = Graphics.FromImage(bDead)) using (var ga = Graphics.FromImage(bGlitch))
            {
                gp.Clear(Color.Transparent);
                foreach (var g in new[] { gc, gg, gd, ga }) { g.Clear(Color.Black); g.ScaleTransform(L.FW / (float)w, L.FH / (float)h); }
                foreach (var g in new[] { gp, gc, gg, gd, ga }) { g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality; }
                Func<double, double, double> In = (t, ramp) => Clamp01((level - t) / ramp);       // how far in an element is (0 = not yet)

                // 1. DUST: specks, some catching the light, some dark; a little grime round each
                for (int i = 0; i < 320; i++)
                {
                    float x = (float)(r.NextDouble() * w), y = (float)(r.NextDouble() * vr), rad = (float)((0.5 + 2.6 * Math.Pow(r.NextDouble(), 2)) * u);
                    double t = 0.03 + 0.62 * Math.Pow(r.NextDouble(), 1.3); bool light = r.NextDouble() < 0.35; double al = 0.25 + 0.45 * r.NextDouble();
                    double k = In(t, 0.05); if (k <= 0) continue;
                    using (var b = new SolidBrush(Argb((int)(255 * al * k), light ? 0xC8BEA8 : 0x1E1812))) gp.FillEllipse(b, x - rad, y - rad, 2 * rad, 2 * rad);
                    using (var b = new SolidBrush(Argb((int)(70 * k), 0xFFFFFF))) gg.FillEllipse(b, x - rad * 3, y - rad * 3, rad * 6, rad * 6);
                }
                // 2. SMUDGES: wide soft wipes of grime
                for (int i = 0; i < 12; i++)
                {
                    float x = (float)(r.NextDouble() * w), y = (float)(r.NextDouble() * vr), rx = (float)((60 + 180 * r.NextDouble()) * u), ry = rx * (float)(0.25 + 0.35 * r.NextDouble());
                    double ang = r.NextDouble() * 180, t = 0.1 + 0.6 * r.NextDouble(), al = 0.18 + 0.16 * r.NextDouble(), k = In(t, 0.08); if (k <= 0) continue;
                    var st = gg.Save(); gg.TranslateTransform(x, y); gg.RotateTransform((float)ang);
                    using (var b = new SolidBrush(Argb((int)(255 * al * k), 0xFFFFFF))) gg.FillEllipse(b, -rx, -ry, 2 * rx, 2 * ry);
                    gg.Restore(st);
                }
                // 3. SCRATCHES: hairlines that catch the light, now and then a few side by side
                for (int i = 0; i < 80; i++)
                {
                    float x = (float)(r.NextDouble() * w), y = (float)(r.NextDouble() * vr), len = (float)((20 + 280 * Math.Pow(r.NextDouble(), 1.6)) * u);
                    double ang = r.NextDouble() * Math.PI * 2, bend = (r.NextDouble() - 0.5) * 0.6, t = 0.05 + 0.8 * Math.Pow(r.NextDouble(), 1.2), al = 40 + 50 * r.NextDouble();
                    int lines = r.NextDouble() < 0.2 ? 2 + r.Next(3) : 1; float gap = (float)((2 + 2 * r.NextDouble()) * u);
                    double k = In(t, 0.06); if (k <= 0) continue;
                    for (int j = 0; j < lines; j++)
                    {
                        float ox = (float)(-Math.Sin(ang) * gap * j), oy = (float)(Math.Cos(ang) * gap * j);
                        PointF p0 = new PointF(x + ox, y + oy), p3 = new PointF(x + ox + (float)Math.Cos(ang) * len, y + oy + (float)Math.Sin(ang) * len);
                        PointF p1 = new PointF(p0.X + (float)Math.Cos(ang + bend) * len / 3, p0.Y + (float)Math.Sin(ang + bend) * len / 3), p2 = new PointF(p3.X - (float)Math.Cos(ang - bend) * len / 3, p3.Y - (float)Math.Sin(ang - bend) * len / 3);
                        using (var dk = new Pen(Argb((int)(40 * k), 0x000000), Math.Max(1f, 0.9f * u))) gp.DrawBezier(dk, p0.X + 1, p0.Y + 1, p1.X + 1, p1.Y + 1, p2.X + 1, p2.Y + 1, p3.X + 1, p3.Y + 1);
                        using (var lt = new Pen(Argb((int)(al * k), 0xD7E1EB), Math.Max(1f, 0.55f * u))) gp.DrawBezier(lt, p0, p1, p2, p3);
                    }
                }
                // 4. THE CLAW RAKE: four long gouges across the glass, on the side away from the broken corner
                {
                    float cx = (float)(w * (0.22 + 0.1 * r.NextDouble())), cy = (float)(vr * (0.35 + 0.15 * r.NextDouble())); double ang = -0.9 + 0.3 * r.NextDouble();
                    if (BreakLeft) { cx = w - cx; ang = Math.PI - ang; }      // (mirrored: away from the break, as it always was)
                    double k = In(0.42, 0.06);
                    if (k > 0)
                        for (int j = 0; j < 4; j++)
                        {
                            float off = (j - 1.5f) * 11 * u, len = (float)((230 + 60 * Math.Sin(j * 1.7)) * u) * (float)k;
                            float x0 = cx - (float)Math.Sin(ang) * off - (float)Math.Cos(ang) * len / 2, y0 = cy + (float)Math.Cos(ang) * off - (float)Math.Sin(ang) * len / 2;
                            float x3 = x0 + (float)Math.Cos(ang) * len, y3 = y0 + (float)Math.Sin(ang) * len;
                            float bx = (float)(Math.Sin(ang) * 18 * u), by = (float)(-Math.Cos(ang) * 18 * u);
                            using (var dk = new Pen(Argb((int)(120 * k), 0x000000), 2.6f * u)) gp.DrawBezier(dk, x0 + u, y0 + u, x0 + (x3 - x0) / 3 + bx + u, y0 + (y3 - y0) / 3 + by + u, x0 + 2 * (x3 - x0) / 3 + bx + u, y0 + 2 * (y3 - y0) / 3 + by + u, x3 + u, y3 + u);
                            using (var lt = new Pen(Argb((int)(170 * k), 0xE6EEF4), 1.3f * u)) gp.DrawBezier(lt, x0, y0, x0 + (x3 - x0) / 3 + bx, y0 + (y3 - y0) / 3 + by, x0 + 2 * (x3 - x0) / 3 + bx, y0 + 2 * (y3 - y0) / 3 + by, x3, y3);
                            using (var gr = new Pen(Argb((int)(140 * k), 0xFFFFFF), 6 * u)) gg.DrawBezier(gr, x0, y0, x0 + (x3 - x0) / 3 + bx, y0 + (y3 - y0) / 3 + by, x0 + 2 * (x3 - x0) / 3 + bx, y0 + 2 * (y3 - y0) / 3 + by, x3, y3);
                            using (var cr = new Pen(Argb((int)(200 * k), 0xFFFFFF), 4 * u)) gc.DrawBezier(cr, x0, y0, x0 + (x3 - x0) / 3 + bx, y0 + (y3 - y0) / 3 + by, x0 + 2 * (x3 - x0) / 3 + bx, y0 + 2 * (y3 - y0) / 3 + by, x3, y3);
                        }
                }
                // 5. IMPACTS: crack systems, each from its own threshold, spreading as the damage grows
                var cracks = new List<Crack>(); var centres = new List<PointF>(); var cT = new List<double>(); var cReach = new List<float>(); var cRad = new List<List<Crack>>();
                double[] thr = { 0.30, 0.45, 0.58, 0.68, 0.80 };
                for (int i = 0; i < thr.Length; i++)
                {
                    float x, y; int tries = 0;
                    do { x = (float)((0.06 + 0.88 * r.NextDouble()) * w); y = (float)((0.06 + 0.84 * r.NextDouble()) * vr); }
                    while (++tries < 40 && Math.Abs(x / w - 0.5) < 0.2 && Math.Abs(y / vr - 0.5) < 0.22);       // (the middle of the view stays clear longest)
                    float reach = (float)((180 + 260 * r.NextDouble()) * u * (0.8 + 0.12 * i));
                    centres.Add(new PointF(x, y)); cT.Add(thr[i]); cReach.Add(reach);
                    int nr = 6 + r.Next(5); var rads = new List<Crack>(); double a0 = r.NextDouble() * Math.PI * 2;
                    for (int j = 0; j < nr; j++)
                    {
                        int before = cracks.Count;
                        Walk(r, cracks, x, y, a0 + j * Math.PI * 2 / nr + (r.NextDouble() - 0.5) * 0.5, reach * (float)(0.45 + 0.55 * r.NextDouble()), (float)((6 + 6 * r.NextDouble()) * u), 0, 0, 1f, thr[i], reach);
                        rads.Add(cracks[before]);
                    }
                    cRad.Add(rads);
                }
                Action<PointF[], float, double> DrawCrack = (pts, wd, k) =>
                {
                    if (pts == null || pts.Length < 2) return;
                    foreach (var q0 in pts) if (float.IsNaN(q0.X) || float.IsNaN(q0.Y) || Math.Abs(q0.X) > 1e6f || Math.Abs(q0.Y) > 1e6f) return;
                    // (Josh, 2026-10-10: the fine cracks "a bit too visible" -- about 60% of the first strength)
                    using (var glow = new Pen(Argb((int)(12 * k), 0xFFFFFF), 3.0f * u * wd)) gp.DrawLines(glow, pts);
                    var sh = new PointF[pts.Length]; for (int q = 0; q < pts.Length; q++) sh[q] = new PointF(pts[q].X + 0.6f * u, pts[q].Y + 0.6f * u);
                    using (var dk = new Pen(Argb((int)(70 * k), 0x000000), Math.Max(1.1f, 1.8f * u * wd))) gp.DrawLines(dk, sh);
                    using (var lt = new Pen(Argb((int)(125 * k * Math.Min(1, 0.55 + 0.45 * wd)), 0xE6F0F5), Math.Max(1f, 0.6f * u * wd))) gp.DrawLines(lt, pts);
                    using (var cf = new Pen(Argb((int)(255 * k), 0xFFFFFF), 7 * u * Math.Max(0.6f, wd))) gc.DrawLines(cf, pts);
                    using (var gl = new Pen(Argb((int)(200 * k), 0xFFFFFF), 16 * u * Math.Max(0.6f, wd))) ga.DrawLines(gl, pts);
                };
                foreach (var c in cracks)
                {
                    double k = In(c.T, 0.04); if (k <= 0) continue;
                    float grown = c.Reach * (float)Math.Min(1, 0.3 + (level - c.T) / 0.2);
                    var pts = Grown(c, grown); if (pts != null) DrawCrack(pts, c.Width, k);
                }
                for (int i = 0; i < centres.Count; i++)
                {
                    double k = In(cT[i], 0.04); if (k <= 0) continue;
                    var c0 = centres[i]; float grown = cReach[i] * (float)Math.Min(1, 0.3 + (level - cT[i]) / 0.2);
                    // the crush at the centre: stress-whitened glass and small chips
                    float hz = 26 * u * (0.6f + 0.4f * grown / cReach[i]);
                    using (var path = new GraphicsPath())
                    {
                        path.AddEllipse(c0.X - hz, c0.Y - hz, 2 * hz, 2 * hz);
                        using (var pg = new PathGradientBrush(path) { CenterColor = Argb((int)(70 * k), 0xFFFFFF), SurroundColors = new[] { Color.Transparent } }) gp.FillEllipse(pg, c0.X - hz, c0.Y - hz, 2 * hz, 2 * hz);
                    }
                    var cr2 = new Random(seed * 31 + i);
                    for (int j = 0; j < 9; j++)
                    {
                        double a = cr2.NextDouble() * Math.PI * 2; float d = (float)(cr2.NextDouble() * 10 * u), s = (float)((2 + 5 * cr2.NextDouble()) * u);
                        float px = c0.X + (float)Math.Cos(a) * d, py = c0.Y + (float)Math.Sin(a) * d;
                        var tri = new[] { new PointF(px, py - s), new PointF(px + s * 0.9f, py + s * 0.6f), new PointF(px - s * 0.7f, py + s * 0.5f) };
                        using (var fb = new SolidBrush(Argb((int)(60 * k), 0xFFFFFF))) gp.FillPolygon(fb, tri);
                        using (var eb = new Pen(Argb((int)(120 * k), 0xEEF6FA), Math.Max(1f, 0.5f * u))) gp.DrawPolygon(eb, tri);
                    }
                    // the web: rings joining neighbouring radial cracks, once the system has spread a while
                    double kw = In(cT[i] + 0.1, 0.06);
                    if (kw > 0)
                    {
                        var rads = cRad[i];
                        foreach (double fr in new[] { 0.2, 0.45 })
                        {
                            float rr = cReach[i] * (float)(fr * (0.8 + 0.4 * cr2.NextDouble())); if (rr > grown) continue;
                            for (int j = 0; j < rads.Count; j++)
                            {
                                if (cr2.NextDouble() < 0.55) continue;      // (partial rings: real ones never close)
                                var pa = Grown(rads[j], rr); var pb = Grown(rads[(j + 1) % rads.Count], rr); if (pa == null || pb == null) continue;
                                PointF A = pa[pa.Length - 1], B = pb[pb.Length - 1];
                                var mid = new PointF((A.X + B.X) / 2 + (float)((cr2.NextDouble() - 0.5) * 8 * u), (A.Y + B.Y) / 2 + (float)((cr2.NextDouble() - 0.5) * 8 * u));
                                // bowed a little outward
                                float ox = mid.X - c0.X, oy = mid.Y - c0.Y, ol = (float)Math.Sqrt(ox * ox + oy * oy) + 1e-3f; mid = new PointF(mid.X + ox / ol * rr * 0.08f, mid.Y + oy / ol * rr * 0.08f);
                                DrawCrack(new[] { A, mid, B }, 0.7f, kw);
                            }
                        }
                    }
                }
                // 6. DEAD PIXELS along the cracks, later on
                for (int i = 0; i < 14 && cracks.Count > 0; i++)
                {
                    var c = cracks[r.Next(cracks.Count)]; var p = c.P[r.Next(c.P.Count)]; double t = Math.Max(c.T + 0.12, 0.55 + 0.4 * r.NextDouble());
                    float s = (float)((1.5 + 3 * r.NextDouble()) * u); int kind = r.Next(4);
                    double k = In(t, 0.03); if (k <= 0) continue;
                    int rgb = kind == 0 ? 0x000000 : kind == 1 ? 0xFF2020 : kind == 2 ? 0x20FF40 : 0x3040FF;
                    using (var b = new SolidBrush(Argb((int)(230 * k), rgb))) gp.FillRectangle(b, p.X, p.Y, s, s);
                }
                // 7. THE BROKEN CORNER, BREAKING AWAY LIKE GLASS (Josh, 2026-10-10: "actually break apart and change shape like
                // actual glass"). The top corner (left with BreakLeft, else right) is a web of pieces -- rings out from the corner crossed by jagged
                // radial lines, every edge shared by the two pieces either side of it -- and each piece has its own damage at
                // which it falls out: those at the corner first (from CornerFrom, half health), a piece only after the one
                // inside it. So the hole grows a piece at a time and its edge changes shape as it goes; a piece about to go is
                // cracked round first; the display behind is dead (the dead field), its liquid crystal bleeding at the edge.
                {
                    var cr = new Random(seed * 7 + 3);
                    const int K = 6, J = 7;
                    float Sx = 0.36f * w, Sy = 0.5f * vr; var C0 = new PointF(BreakLeft ? -2 : w + 2, -2);
                    var th = new double[J + 1];
                    for (int j = 0; j <= J; j++) th[j] = j == 0 ? -0.15 : j == J ? Math.PI / 2 + 0.15 : (j + (cr.NextDouble() - 0.5) * 0.6) / J * Math.PI / 2;
                    var V = new PointF[K + 1, J + 1];
                    for (int k = 0; k <= K; k++)
                        for (int j = 0; j <= J; j++)
                        {
                            if (k == 0) { V[k, j] = C0; continue; }
                            double rho = (k + (cr.NextDouble() - 0.5) * 0.55) / K, a = th[j] + (j > 0 && j < J ? (cr.NextDouble() - 0.5) * 0.08 : 0);
                            float ox = (float)(rho * Math.Cos(a) * Sx);      // (out from the corner, across the glass)
                            V[k, j] = new PointF(BreakLeft ? ox : w - ox, (float)(rho * Math.Sin(a) * Sy));
                        }
                    // when each piece falls out (never before the piece inside it)
                    var T = new double[K, J];
                    for (int j = 0; j < J; j++)
                        for (int k = 0; k < K; k++)
                        {
                            double b = k == 0 ? CornerFrom + 0.07 * cr.NextDouble() : CornerFrom + (k / (double)(K - 1)) * (0.97 - CornerFrom) * (0.7 + 0.6 * cr.NextDouble());
                            T[k, j] = k == 0 ? b : Math.Max(T[k - 1, j] + 0.015, b);
                        }
                    T[0, J / 2] = CornerFrom;
                    Func<int, int, bool> Gone = (k, j) => k >= 0 && k < K && j >= 0 && j < J && level >= T[k, j];
                    // an edge, jagged: the same points whichever piece asks for it
                    Func<PointF, PointF, int, PointF[]> Jag = (a, b, key) =>
                    {
                        var jr = new Random(seed * 131 + key); const int m = 5; var pts = new PointF[m + 1]; pts[0] = a; pts[m] = b;
                        float dx = b.X - a.X, dy = b.Y - a.Y, len = (float)Math.Sqrt(dx * dx + dy * dy) + 1e-3f, px = -dy / len, py = dx / len;
                        for (int i = 1; i < m; i++) { float f = i / (float)m, jt = (float)((jr.NextDouble() - 0.5) * len * 0.16); if (jr.NextDouble() < 0.2) jt *= 2.2f; pts[i] = new PointF(a.X + dx * f + px * jt, a.Y + dy * f + py * jt); }
                        return pts;
                    };
                    Func<int, int, PointF[]> RingE = (k, j) => Jag(V[k, j], V[k, j + 1], 5000 + k * 50 + j);      // ring k, from line j to j+1
                    Func<int, int, PointF[]> RadE = (k, j) => Jag(V[k, j], V[k + 1, j], 1000 + k * 50 + j);       // line j, from ring k to k+1
                    Func<PointF[], PointF[]> Rev = a => { var b = (PointF[])a.Clone(); Array.Reverse(b); return b; };
                    Func<int, int, PointF[]> Piece = (k, j) =>
                    {
                        var poly = new List<PointF>();
                        if (k > 0) poly.AddRange(RingE(k, j)); else poly.Add(C0);
                        poly.AddRange(RadE(k, j + 1)); poly.AddRange(Rev(RingE(k + 1, j))); poly.AddRange(Rev(RadE(k, j)));
                        return poly.ToArray();
                    };
                    var outline = new List<KeyValuePair<PointF[], int>>();      // the hole's edge: polyline, its edge's key
                    for (int k = 0; k < K; k++)
                        for (int j = 0; j < J; j++)
                        {
                            if (!Gone(k, j))
                            {
                                // about to go: cracked round its edges first
                                double kc = In(T[k, j] - 0.07, 0.04);
                                if (kc > 0) foreach (var e in new[] { RingE(k + 1, j), RadE(k, j), RadE(k, j + 1) }) DrawCrack(e, 0.8f, kc * 0.85);
                                continue;
                            }
                            double kk = In(T[k, j], 0.02);
                            using (var b = new SolidBrush(Argb((int)(255 * kk), 0xFFFFFF))) gd.FillPolygon(b, Piece(k, j));
                            if (!Gone(k + 1, j)) outline.Add(new KeyValuePair<PointF[], int>(RingE(k + 1, j), 5000 + (k + 1) * 50 + j));
                            if (j > 0 && !Gone(k, j - 1)) outline.Add(new KeyValuePair<PointF[], int>(RadE(k, j), 1000 + k * 50 + j));
                            if (j + 1 < J && !Gone(k, j + 1)) outline.Add(new KeyValuePair<PointF[], int>(RadE(k, j + 1), 1000 + k * 50 + j + 1));
                        }
                    foreach (var kv in outline)
                    {
                        var ep = kv.Value; var e = kv.Key; var er = new Random(seed * 977 + ep);
                        // into the glass: away from the corner
                        var inner = new PointF[e.Length];
                        for (int q = 0; q < e.Length; q++) { float dx = e[q].X - C0.X, dy = e[q].Y - C0.Y, dl = (float)Math.Sqrt(dx * dx + dy * dy) + 1e-3f; inner[q] = new PointF(e[q].X + dx / dl * 4 * u, e[q].Y + dy / dl * 4 * u); }
                        using (var dk = new Pen(Argb(170, 0x000000), 3.5f * u)) gp.DrawLines(dk, inner);
                        using (var lt2 = new Pen(Argb(110, 0xBFD6E0), 1.2f * u)) gp.DrawLines(lt2, inner);
                        using (var lt = new Pen(Argb(235, 0xF2FAFF), Math.Max(1.5f, 1.5f * u))) gp.DrawLines(lt, e);
                        using (var cf = new Pen(Argb(255, 0xFFFFFF), 10 * u)) gc.DrawLines(cf, e);
                        using (var gl = new Pen(Argb(255, 0xFFFFFF), 30 * u)) ga.DrawLines(gl, e);
                        // the liquid crystal bleeding past it, chips of glass left on it, cracks running on into the glass
                        var mid = e[e.Length / 2]; float mx = mid.X - C0.X, my = mid.Y - C0.Y, ml = (float)Math.Sqrt(mx * mx + my * my) + 1e-3f; mx /= ml; my /= ml;
                        for (int q = 0; q < 2; q++)
                        {
                            var bp = e[er.Next(e.Length)]; float rad = (float)((12 + 34 * er.NextDouble()) * u), off = (float)((er.NextDouble() - 0.85) * 30 * u);   // (mostly on the hole's side: only its fringe reaches the glass)
                            using (var b = new SolidBrush(Argb((int)(255 * (0.3 + 0.5 * er.NextDouble())), 0xFFFFFF))) gd.FillEllipse(b, bp.X + mx * off - rad, bp.Y + my * off - rad, 2 * rad, 2 * rad);
                        }
                        if (er.NextDouble() < 0.7)
                        {
                            float d = (float)((6 + 20 * er.NextDouble()) * u), s = (float)((5 + 14 * er.NextDouble()) * u); double a = er.NextDouble() * Math.PI * 2;
                            float sx = mid.X + mx * d, sy = mid.Y + my * d;
                            var sh = new[] { new PointF(sx + (float)Math.Cos(a) * s, sy + (float)Math.Sin(a) * s), new PointF(sx + (float)Math.Cos(a + 2.2) * s * 0.7f, sy + (float)Math.Sin(a + 2.2) * s * 0.7f), new PointF(sx + (float)Math.Cos(a + 4.1) * s * 0.9f, sy + (float)Math.Sin(a + 4.1) * s * 0.9f) };
                            using (var fb = new SolidBrush(Argb(35, 0xFFFFFF))) gp.FillPolygon(fb, sh);
                            using (var eb = new Pen(Argb(170, 0xEEF6FA), Math.Max(1f, 0.7f * u))) gp.DrawPolygon(eb, sh);
                            using (var cf = new Pen(Argb(220, 0xFFFFFF), 6 * u)) gc.DrawPolygon(cf, sh);
                        }
                        if (er.NextDouble() < 0.5)
                        {
                            var ec = new List<Crack>(); var sp = e[1 + er.Next(e.Length - 2)];
                            Walk(er, ec, sp.X, sp.Y, Math.Atan2(my, mx) + (er.NextDouble() - 0.5) * 1.0, (float)((60 + 160 * er.NextDouble()) * u), 7 * u, 0, 1, 0.85f, 0, 1e9f);
                            foreach (var c in ec) DrawCrack(c.P.ToArray(), c.Width, 1);
                        }
                    }
                }
                // the fields, softened, and grime gathering at the visor's rim as the damage grows
                float[] fc = Channel(bCrack), fg = Channel(bGrime), fd = Channel(bDead), fa = Channel(bGlitch);
                int fw = L.FW, fh = L.FH; float uf = u * fw / w;
                BoxBlur(fc, fw, fh, Math.Max(1, (int)(1.5f * uf))); BoxBlur(fc, fw, fh, Math.Max(1, (int)(1.5f * uf)));
                BoxBlur(fg, fw, fh, Math.Max(2, (int)(8 * uf))); BoxBlur(fg, fw, fh, Math.Max(2, (int)(8 * uf)));
                BoxBlur(fd, fw, fh, Math.Max(2, (int)(5 * uf))); BoxBlur(fd, fw, fh, Math.Max(2, (int)(5 * uf)));
                BoxBlur(fa, fw, fh, Math.Max(1, (int)(3 * uf)));
                double rim = Math.Pow(Clamp01((level - 0.1) / 0.9), 1.5) * 0.45; float fvr = vr * fh / h;
                var fx = new int[fw * fh];
                for (int y = 0; y < fh; y++)
                    for (int x = 0; x < fw; x++)
                    {
                        int i = y * fw + x; float g = fg[i];
                        if (rim > 0)
                        {
                            float ex = Math.Min(x, fw - 1 - x) / (fw * 0.18f), ey = Math.Min(y, Math.Max(0, fvr - 1 - y)) / (fvr * 0.2f), e = 1 - Math.Min(1, Math.Min(ex, ey));
                            if (e > 0) g += (float)(rim * e * e * (0.45 + 0.75 * VNoise(x / (fw * 0.03f), y / (fw * 0.03f), seed)));
                        }
                        int R = (int)(Math.Min(1, fc[i]) * 255), G = (int)(Math.Min(1, g) * 255), Bd = (int)(Math.Min(1, fd[i]) * 255), A = (int)(Math.Min(1, fa[i]) * 255);
                        fx[i] = (A << 24) | (R << 16) | (G << 8) | Bd;
                    }
                L.Fx = fx;
                L.Paint = new int[w * h];
                var bd = paint.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb); Marshal.Copy(bd.Scan0, L.Paint, 0, L.Paint.Length); paint.UnlockBits(bd);
            }
            L.Ms = sw.Elapsed.TotalMilliseconds;
            return L;
        }
    }

    /// <summary>THE VISOR'S MEMORY CORE (Josh, 2026-10-09: the save/load list's text was "far too small"; "an all new
    /// loading screen ... the amber interlaced monitor kick in (with transparency so the environment shows a bit) ... the
    /// degauss sound ... a similar style as the bootup sequence"). The game's own slot list (tiny, at the view's top left)
    /// is hidden (Overlay.HideRect2) and this draws in its place, from the game's state polled each frame (SetState).
    /// Clicks still go to the GAME: Build-AztMod moves the list's hot spots (rows, close box, RESTART) and the row maths
    /// (0x2CC37) onto THIS layout, so the numbers below are the build's and must change together (docs\save-load-screen-RE.md).
    /// Layout in GAME SCREEN px (1600x1200; the view starts at screen row ViewY).</summary>
    public class VisorMenu
    {
        // ---- the layout (the build's $SLOTLIST_* -- keep in step) ----
        // (all x 56 left of the first layout: the two menus balanced on screen -- Build-AztMod's $MENU_SHIFT, Josh 2026-10-09)
        public int PanelX0 = 34, PanelY0 = 140, PanelX1 = 954, PanelY1 = 800;
        public int CloseX0 = 894, CloseY0 = 160, CloseX1 = 934, CloseY1 = 200;
        public int RowX0 = 74, RowX1 = 914, RowTop = 280, RowPitch = 76, RowH = 68, Rows = 5;
        public int RestartX0 = 74, RestartY0 = 676, RestartX1 = 504, RestartY1 = 736;
        public int ViewY = 49;
        // ---- the look ----
        public int Amber = 0xFFB040, AmberHi = 0xFFE3A6, AmberDim = 0x9A6418, Glass = 0x2A1700;
        /// <summary>One turn of the confirm key's sheen round its outline (s).</summary>
        public double SheenSeconds = 3.0;
        public double Darken = 0.62, Tint = 0.10, Interlace = 0.32, Degauss = 0.85, OpenSeconds = 0.22;
        public BootSound Sound;
        readonly Overlay _ov;
        public VisorMenu(Overlay ov) { _ov = ov; }
        // ---- THE GAME'S CURSOR, drawn over the panel (Josh, 2026-10-09: "the mouse cursor ... gets lost behind it"). The
        // game draws it into its own picture, which is under this panel (and the panel hides the game's drawings in its
        // area), so the host draws it again on top: the game's CURRENT cursor image (its surface pointer and hot spot, as
        // Pointer.cs reads them), at the game's cursor. Host addresses; MemBase turns a guest pointer into a host address.
        public int Pid; public long MemBase, CurSurfAddr, HotAddr, HiddenAddr; public int[] Palette;
        // (its own guest reads, as Pointer.cs: ProcMem is compiled apart from this file)
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, [Out] byte[] buf, IntPtr size, out IntPtr read);
        IntPtr _proc; int _procPid;
        byte[] Rd(long addr, int len)
        {
            if (addr == 0 || len <= 0) return null;
            if (_proc == IntPtr.Zero || _procPid != Pid) { _proc = OpenProcess(0x0410, false, Pid); _procPid = Pid; if (_proc == IntPtr.Zero) return null; }
            var b = new byte[len]; IntPtr got;
            return ReadProcessMemory(_proc, new IntPtr(addr), b, new IntPtr(len), out got) && got.ToInt64() == len ? b : null;
        }
        int[] _cur; int _cw, _ch, _chx, _chy; uint _curPtr; long _curSum;
        /// <summary>Why the game's cursor image could not be read, the last time it failed ("" = it was read); the watcher
        /// logs it (Josh, 2026-10-09: the cursor still did not show in game -- the cause could not be seen from here).</summary>
        public string CursorNote = ""; public long CursorDrawn, CursorFallback;
        bool Fail(string why) { CursorNote = why; return false; }
        bool ReadCursor()
        {
            if (Pid == 0 || CurSurfAddr == 0) return Fail("no process or address given");
            try
            {
                // (the pointer-hidden flag is NOT a reason to draw nothing here: the panel is up, so the player needs a pointer)
                var pb = Rd(CurSurfAddr, 4); if (pb == null) return Fail(string.Format("could not read the cursor-surface pointer at host 0x{0:X} (OpenProcess {1})", CurSurfAddr, _proc == IntPtr.Zero ? "failed" : "ok"));
                uint p = BitConverter.ToUInt32(pb, 0); if (p < 0x1000) return Fail(string.Format("cursor-surface pointer is 0x{0:X}", p));
                // THE GAME'S SURFACE (read off its blitter 0x37D98, 2026-10-09 -- the log showed the old guess reading 30x30 as
                // one dword): word width, word height, dword pixels; rows packed at the width
                var sd = Rd(MemBase + p, 8); if (sd == null) return Fail(string.Format("could not read the cursor surface at guest 0x{0:X}", p));
                int w = BitConverter.ToUInt16(sd, 0), h = BitConverter.ToUInt16(sd, 2), bpl = w; uint px = BitConverter.ToUInt32(sd, 4);
                if (w <= 0 || h <= 0 || w > 256 || h > 256 || bpl < w || px < 0x1000) return Fail(string.Format("cursor surface looks wrong: {0}x{1}, {2} per line, pixels at 0x{3:X}", w, h, bpl, px));
                var raw = Rd(MemBase + px, bpl * (h - 1) + w); if (raw == null) return Fail(string.Format("could not read the cursor pixels at guest 0x{0:X}", px));
                CursorNote = "";
                var hb2 = Rd(HotAddr, 4); int hx = hb2 != null ? BitConverter.ToInt16(hb2, 0) : 0, hy = hb2 != null ? BitConverter.ToInt16(hb2, 2) : 0;
                long sum = p * 31L + w * 7 + h + hx * 13 + hy; for (int i = 0; i < raw.Length; i += 3) sum = sum * 131 + raw[i];
                if (p == _curPtr && sum == _curSum && _cur != null) return true;
                var img = new int[w * h];
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int v = raw[y * bpl + x]; img[y * w + x] = v == 0 ? -1 : (Palette != null && v < Palette.Length ? Palette[v] & 0xFFFFFF : v * 0x010101); }
                _cur = img; _cw = w; _ch = h; _chx = hx; _chy = hy; _curPtr = p; _curSum = sum;
                return true;
            }
            catch (Exception e) { return Fail("reading the cursor threw: " + e.Message); }
        }
        // the cursor at the picture's scale (bilinear over its opaque texels), its hot spot on the game's cursor; when the
        // game's image cannot be read, the visor's own pointer instead -- never nothing
        void DrawCursor(int[] pic, int pw, int vr, float s)
        {
            if (_cx < 0 || _cy < 0) { CursorNote = string.Format("no cursor position ({0},{1})", _cx, _cy); return; }
            if (!ReadCursor() || _cur == null) { DrawOwnPointer(pic, pw, vr, s); return; }
            CursorDrawn++;
            float ox = PX(_cx) - _chx * s, oy = PY(_cy) - _chy * s;
            int dw = (int)Math.Ceiling(_cw * s), dh = (int)Math.Ceiling(_ch * s);
            for (int y = 0; y < dh; y++)
            {
                int py = (int)oy + y; if (py < 0 || py >= vr) continue;
                double fy = (y + 0.5) / s - 0.5; int iy = (int)Math.Floor(fy); double wy = fy - iy;
                for (int x = 0; x < dw; x++)
                {
                    int px = (int)ox + x; if (px < 0 || px >= pw) continue;
                    double fx = (x + 0.5) / s - 0.5; int ix = (int)Math.Floor(fx); double wx = fx - ix;
                    double a = 0, r = 0, g = 0, b = 0;
                    for (int k = 0; k < 4; k++)
                    {
                        int sx = ix + (k & 1), sy = iy + (k >> 1); if (sx < 0 || sy < 0 || sx >= _cw || sy >= _ch) continue;
                        int c = _cur[sy * _cw + sx]; if (c == -1) continue;
                        double wgt = ((k & 1) != 0 ? wx : 1 - wx) * ((k >> 1) != 0 ? wy : 1 - wy);
                        a += wgt; r += wgt * ((c >> 16) & 255); g += wgt * ((c >> 8) & 255); b += wgt * (c & 255);
                    }
                    if (a <= 0.02) continue;
                    int o = py * pw + px, d = pic[o]; double ia = 1 - Math.Min(1, a);
                    pic[o] = ((int)Math.Min(255, r + ((d >> 16) & 255) * ia) << 16) | ((int)Math.Min(255, g + ((d >> 8) & 255) * ia) << 8) | (int)Math.Min(255, b + (d & 255) * ia);
                }
            }
        }

        // ---- the game's state, each frame ----
        bool _open, _save; int _sel = -1, _cx = -1, _cy = -1; string[] _names = new string[5];
        readonly Stopwatch _clock = Stopwatch.StartNew(); double _openedAt = -10, _closedAt = -10, _modeAt = -10;
        int _hover = -99; string _typedWas = null; int _selWas = -2;
        /// <summary>The game is saving (its flag 0x152B02): set before SetState.</summary>
        public bool Writing;
        public double WriteSeconds = 3.0, WrittenHold = 0.7;     // (the game holds its save message 3 s; "LOG WRITTEN." stays this long)
        bool _writing; int _writeSlot = -1; double _writeAt = -10, _wroteAt = -10, _writeBlip = -10, _lastShown = -10;
        bool WriteScreen(double t) { return _writing || t - _wroteAt < WrittenHold; }
        /// <summary>From the game: list showing, save mode, the selected row (-1, 0..4, 6 = RESTART), the five names, the
        /// cursor (screen px).</summary>
        public void SetState(bool open, bool save, int sel, string[] names, int cx, int cy)
        {
            double t = _clock.Elapsed.TotalSeconds;
            // WRITING THE LOG (Josh, 2026-10-09: on confirm "I see the old load/save interface briefly"): OK takes the game's
            // list down at once and then saves for ~3 s, so the panel stays up through the save as "WRITING LOG..." (Writing:
            // the game's saving flag 0x152B02), says it is written, then closes. A short grace bridges the poll that can land
            // between the list going down and the flag going up.
            if (Writing && !_writing) { _writeAt = t; _writeSlot = _sel; if (Sound != null && Sound.On) { try { Sound.Typing(71, 0.55, 1.05); } catch { } } }
            if (!Writing && _writing) { _wroteAt = t; if (Sound != null && Sound.On) { try { Sound.Line(29, 0.1, 1.3); } catch { } } }
            if (Writing && Sound != null && Sound.On && t - _writeBlip > 0.42 && t - _writeAt > 0.6) { _writeBlip = t; try { Sound.Line(40 + (int)(t * 7) % 9, 0.06, 1.1); } catch { } }
            _writing = Writing;
            if (open || _writing || t - _wroteAt < WrittenHold) _lastShown = t;
            open = open || _writing || t - _wroteAt < WrittenHold || (_open && t - _lastShown < 0.15);
            if (open && !_open) { _openedAt = t; _modeAt = t; if (Sound != null && Sound.On) { try { Sound.DegaussSound(Degauss); } catch { } } }
            else if (open && save != _save && !WriteScreen(t)) { _modeAt = t; if (Sound != null && Sound.On) { try { Sound.Line(7, 0.12, 1.2); } catch { } } }
            if (!open && _open) { _closedAt = t; if (t - _wroteAt < 3) { _returnAt = t + 0.18; _returnSnd = false; } }      // (after a save: back to the world, once the panel has folded)
            _open = open; _cx = cx; _cy = cy;
            if (!WriteScreen(t)) _save = save;              // (the game drops save mode as it starts writing: the screen stays WRITE)
            if (names != null) for (int i = 0; i < 5 && i < names.Length; i++) _names[i] = names[i] ?? "";
            if (open && !WriteScreen(t))
            {
                int hv = HitAt(cx, cy);
                if (hv != _hover && hv != -99 && Sound != null && Sound.On) { try { Sound.Typing(hv + 3, 0.035, 1.35); } catch { } }
                _hover = hv;
                if (sel != _selWas && _selWas != -2 && sel != -1 && Sound != null && Sound.On) { try { Sound.Line(sel + 11, 0.07, 1.0); } catch { } }
                string typed = (save && sel >= 0 && sel < 5) ? _names[sel] : null;
                if (typed != null && _typedWas != null && sel == _selWas && typed != _typedWas && Sound != null && Sound.On) { try { Sound.Typing(typed.Length, 0.045, 1.15); } catch { } }
                _typedWas = typed;
            }
            _sel = sel; _selWas = sel;
        }
        /// <summary>Drawing: while the list is up and for a moment as it closes.</summary>
        public bool Playing { get { return _open || _clock.Elapsed.TotalSeconds - _closedAt < 0.2; } }
        /// <summary>What of the GAME's drawings to leave out of the picture while this shows (view px x0 y0 x1 y1): the game's
        /// own tiny list (its stipple, RESTART and rows, still drawn at the stock place, view 146,36..354,196) and anything
        /// of the game's under this panel's glass (the reticle) -- one box over both.</summary>
        public int[] HideRect { get { return new[] { Math.Min(PanelX0, 146), Math.Min(PanelY0 - ViewY, 36), Math.Max(PanelX1, 354), Math.Max(PanelY1 - ViewY, 196) }; } }
        // what the cursor is over: 0..4 a row, 6 RESTART, 7 the close box, -99 nothing
        int HitAt(int x, int y)
        {
            if (x >= CloseX0 && x <= CloseX1 && y >= CloseY0 && y <= CloseY1) return 7;
            if (!_save && x >= RestartX0 && x <= RestartX1 && y >= RestartY0 && y <= RestartY1) return 6;
            if (x >= RowX0 && x <= RowX1 && y >= RowTop) { int r = (y - RowTop) / RowPitch; if (r < Rows && y - RowTop - r * RowPitch <= RowH) return r; }
            return -99;
        }

        public Func<int[], int, int, bool> Hook { get { return DrawOver; } }
        int[] _gx, _gy; int _mapW, _mapH;          // game px (screen x, VIEW y) -> picture px
        float PX(double gx) { int g = (int)Math.Max(0, Math.Min(_gx.Length - 1, Math.Round(gx))); return _gx[g]; }
        float PY(double gyScreen) { int g = (int)Math.Max(0, Math.Min(_gy.Length - 1, Math.Round(gyScreen - ViewY))); return _gy[g]; }
        static Color C(int rgb, double a) { return Color.FromArgb((int)Math.Max(0, Math.Min(255, 255 * a)), (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }

        /// <summary>The open panels (memory core / reading / writing, system menu) as rectangles of the PICTURE, 0..1 each
        /// way, four floats a panel (x0, y0, x1, y1); null when none is up. VisorDamage fades the glass's damage out behind
        /// them (Josh, 2026-10-10: "fade the damage behind open menus").</summary>
        public volatile float[] ClearRects;
        public bool DrawOver(int[] pic, int pw, int ph)
        {
            if (_ov == null) { ClearRects = null; return false; }
            double t = _clock.Elapsed.TotalSeconds;
            // opening: the tube's picture grows from a line; closing: it collapses back
            double grow = _open ? Math.Min(1, (t - _openedAt) / OpenSeconds) : Math.Max(0, 1 - (t - _closedAt) / 0.18);
            double sysGrow = _sysOpen ? Math.Min(1, (t - _sysOpenedAt) / OpenSeconds) : Math.Max(0, 1 - (t - _sysClosedAt) / 0.18);
            double rt = t - _returnAt; bool ret = rt >= 0 && rt < ReturnSeconds;
            // a log being read (a load): the panel opens from its line, stays through the reading, folds at its end
            StretchReading(t);
            bool reading = Reading(t);
            if (reading)
            {
                double rd = t - _readAt, rg = t < ReadEnd ? Math.Min(1, rd / OpenSeconds) : Math.Max(0, 1 - (t - ReadEnd) / 0.18);
                grow = Math.Max(grow, rg);
                if (Sound != null && Sound.On)
                {
                    if (rd < _readLen && t - _readBlip > 0.42 && rd > 0.6) { _readBlip = t; try { Sound.Line(40 + (int)(t * 7) % 9, 0.06, 1.1); } catch { } }
                    if (rd >= _readLen && !_readDoneSnd) { _readDoneSnd = true; try { Sound.Line(29, 0.1, 1.3); } catch { } }
                }
            }
            if (grow <= 0.001 && sysGrow <= 0.001 && !ret) { ClearRects = null; return false; }
            int[] cxi, cxf, cxiR, cxfR, riy, rwy; int bt, bb; bool vis;
            _ov.ComposeMap(pw, ph, out cxi, out cxf, out cxiR, out cxfR, out riy, out rwy, out bt, out bb, out vis);
            int vr = Math.Min(ph, _ov.ViewRowsOf(ph));
            if (_gx == null || _mapW != pw || _mapH != ph)
            {
                _gx = new int[1601]; _gy = new int[1201]; _mapW = pw; _mapH = ph;
                for (int g = 0; g <= 1600; g++) { int px = pw - 1; for (int x = 0; x < pw; x++) if (cxi[x] >= g) { px = x; break; } _gx[g] = px; }
                for (int g = 0; g <= 1200; g++) { int py = vr - 1; for (int y = 0; y < vr; y++) if (riy[y] >= g) { py = y; break; } _gy[g] = py; }
            }
            float s = Math.Max(0.5f, (PX(1000) - PX(0)) / 1000f);              // picture px per game px
            bool any = false;
            if (sysGrow > 0.001)
            {
                // THE RIGHT EDGE FROM ITS CONTENT (Josh, 2026-10-09: "the same interior padding as the left"): the view's last game
                // columns stretch toward the display's edge (the wide mapping), so x 1599 sat far past the buttons -- the edge is the
                // content's right plus the left's padding, in picture px; and the top right BENDS DOWN with the visor's curve
                float right = Math.Min(pw - 1, PX(SysContentRight) + (PX(SysContentLeft) - PX(SysX0)));
                _sysBend = (float)(SysBend * s); _sysRight = right; _sysTop = PY(SysY0); _sysBot = PY(SysY1);
                any |= DrawPanel(pic, pw, ph, vr, s, t, SysX0, SysY0, SysX1, SysY1, sysGrow, _sysOpen, _sysOpenedAt, DrawSysContent, right, _sysBend);
            }
            if (grow > 0.001) any |= DrawPanel(pic, pw, ph, vr, s, t, PanelX0, PanelY0, PanelX1, PanelY1, grow, _open || reading, reading ? _readAt : _openedAt, DrawContent);
            // the panels' rectangles (a little past their frames), for the damaged visor
            {
                var cl = new List<float>(8); float m = 10 * s;
                if (sysGrow > 0.001) cl.AddRange(new[] { (PX(SysX0) - m) / pw, (PY(SysY0) - m) / ph, (_sysRight + m) / pw, (PY(SysY1) + m) / ph });
                if (grow > 0.001) cl.AddRange(new[] { (PX(PanelX0) - m) / pw, (PY(PanelY0) - m) / ph, (PX(PanelX1) + m) / pw, (PY(PanelY1) + m) / ph });
                ClearRects = cl.Count > 0 ? cl.ToArray() : null;
            }
            if (ret) { DrawReturn(pic, pw, vr, s, rt); any = true; }
            if (any && !ret && !reading) DrawCursor(pic, pw, vr, s);         // (last: over the panels; not while the view returns -- the game's own pointer is back)
            return any;
        }
        // one panel of visor glass at game rect (gx0,gy0)-(gx1,gy1), opened `grow` (0..1) from a bright line, its content once open
        bool DrawPanel(int[] pic, int pw, int ph, int vr, float s, double t, int gx0, int gy0, int gx1, int gy1, double grow, bool open, double openedAt, Action<Graphics, float, double> content, float rightPx = -1, float bendPx = 0)
        {
            // the panel on the picture, as it opens (from a bright line through its middle)
            float x0 = PX(gx0), x1 = rightPx > 0 ? rightPx : PX(gx1), yc = (PY(gy0) + PY(gy1)) / 2f, hh = (PY(gy1) - PY(gy0)) / 2f * (float)Math.Max(0.012, grow * grow * (3 - 2 * grow));
            int ix0 = Math.Max(0, (int)x0), ix1 = Math.Min(pw - 1, (int)x1), iy0 = Math.Max(0, (int)(yc - hh)), iy1 = Math.Min(vr - 1, (int)(yc + hh));
            if (ix1 <= ix0 || iy1 <= iy0) return false;
            // THE DEGAUSS (as the boot's): the red and blue beams swing apart and back, the picture sways, dying away
            double dt = t - openedAt, swing = open && dt < 1.6 ? Math.Exp(-dt / 0.32) * Math.Sin(dt * 2 * Math.PI * 6.2) : 0;
            int conv = (int)Math.Round(swing * 14 * s);
            double wobAmp = Math.Abs(swing) * 5 * s;
            int line = Math.Max(1, (int)Math.Round(s));                         // the interlace's line height
            double roll = (t * 0.22) % 1.0;                                     // a faint bright band rolling down the glass
            int gr = (Glass >> 16) & 255, gg = (Glass >> 8) & 255, gb = Glass & 255;
            var src = conv != 0 || wobAmp > 0.5 ? (int[])pic.Clone() : null;
            System.Threading.Tasks.Parallel.For(iy0, iy1 + 1, y =>
            {
                double fy = (y - (yc - hh)) / Math.Max(1.0, 2 * hh);
                bool dark = ((y - iy0) / line) % 2 == 1;
                double band = Math.Exp(-Math.Pow((fy - roll) * 9, 2)) * 0.06;
                double edgeY = Math.Min(1, Math.Min(fy, 1 - fy) * 14);
                int wob = wobAmp > 0.5 ? (int)Math.Round(wobAmp * Math.Sin(fy * 11 + t * 37)) : 0;
                float xEdge = bendPx > 0 ? x1 - BendAt(bendPx, (y - PY(gy0)) / Math.Max(1f, PY(gy1) - PY(gy0))) : x1;
                for (int x = ix0; x <= ix1 && x <= xEdge; x++)
                {
                    int o = y * pw + x, c;
                    if (src != null)
                    {
                        int xr = Math.Max(0, Math.Min(pw - 1, x + wob - conv)), xg = Math.Max(0, Math.Min(pw - 1, x + wob)), xb = Math.Max(0, Math.Min(pw - 1, x + wob + conv));
                        c = (src[y * pw + xr] & 0xFF0000) | (src[y * pw + xg] & 0x00FF00) | (src[y * pw + xb] & 0x0000FF);
                    }
                    else c = pic[o];
                    double fx = (x - x0) / Math.Max(1.0, xEdge - x0), edge = Math.Min(edgeY, Math.Min(1, Math.Min(fx, 1 - fx) * 22));
                    // the glass: the room darkened and amber-tinted through it (it shows a little), interlaced, a rolling band
                    double k = (1 - Darken * edge) * (dark ? 1 - Interlace : 1);
                    double r = ((c >> 16) & 255), g = ((c >> 8) & 255), b = (c & 255);
                    double lum = 0.3 * r + 0.59 * g + 0.11 * b;
                    r = (r * 0.35 + lum * 0.65) * k + gr * Tint * edge + 255 * band; g = (g * 0.35 + lum * 0.65 * 0.78) * k + gg * Tint * edge + 176 * band; b = (b * 0.35 + lum * 0.65 * 0.35) * k + gb * Tint * edge + 64 * band;
                    pic[o] = ((int)Math.Min(255, r) << 16) | ((int)Math.Min(255, g) << 8) | (int)Math.Min(255, b);
                }
            });
            if (grow < 0.999) { DrawOpenLine(pic, pw, ix0, Math.Min(ix1, (int)(bendPx > 0 ? x1 - BendAt(bendPx, (yc - PY(gy0)) / Math.Max(1f, PY(gy1) - PY(gy0))) : x1)), (int)yc, grow); return true; }
            var hnd = GCHandle.Alloc(pic, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(pw, ph, pw * 4, PixelFormat.Format32bppRgb, hnd.AddrOfPinnedObject()))
                using (var gfx = Graphics.FromImage(bm))
                {
                    if (bendPx > 0)
                    {
                        // the content clipped to the bent edge
                        var pts = new System.Collections.Generic.List<PointF> { new PointF(ix0, iy0) };
                        for (int k = 0; k <= 24; k++) { float yy = iy0 + (iy1 - iy0) * k / 24f; pts.Add(new PointF(x1 - BendAt(bendPx, (yy - PY(gy0)) / Math.Max(1f, PY(gy1) - PY(gy0))), yy)); }
                        pts.Add(new PointF(ix0, iy1));
                        using (var gp = new GraphicsPath()) { gp.AddPolygon(pts.ToArray()); gfx.SetClip(gp); }
                    }
                    else gfx.SetClip(new Rectangle(ix0, iy0, ix1 - ix0 + 1, iy1 - iy0 + 1));
                    gfx.SmoothingMode = SmoothingMode.AntiAlias; gfx.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                    content(gfx, s, t);
                }
            }
            finally { hnd.Free(); }
            return true;
        }

        // ==== THE SYSTEM MENU (Josh, 2026-10-09: "do away with the rendered system menu for this GPU mode ... rebuild it in the
        // same style as the new save/load menu"; docs\system-menu-RE.md). The game's fold-out (1085..1599 x 89..513) is hidden
        // and this draws in its place; the clicks stay the GAME's: the watcher moves the fold-out's hot spots to the rects
        // below in guest memory while true colour runs (Set-SysMenuHot) and puts them back after -- so retro keeps the old one.
        // The sliders' drag maths is the game's code (track x 1100..1352, level 127 at the LEFT end): the tracks keep those x.
        public int SysX0 = 1007, SysY0 = 140, SysX1 = 1543, SysY1 = 606;      // (SysX1 = the game's fold-out's right edge, moved with it)      // (top level with the memory core's panel, PanelY0 -- Josh 2026-10-09; wider than the game's fold-out round the same controls: room inside the brackets)      // (wider than the game's fold-out round the same controls: room inside the brackets, Josh 2026-10-09)
        public static readonly int[] SysSave = { 1049, 268, 1279, 318 }, SysLoad = { 1294, 268, 1523, 318 }, SysQuit = { 1360, 178, 1469, 223 };
        /// <summary>The content's left and right (game px) -- the panel's edges sit the same distance outside both; the top right
        /// bends down by SysBend game px at the top, easing to none SysBendReach of the way down (the visor's downturn).</summary>
        public int SysContentLeft = 1049, SysContentRight = 1523; public double SysBend = 0, SysBendReach = 0.55;      // (the bend: tried and taken out, Josh 2026-10-09)
        float _sysBend, _sysRight, _sysTop, _sysBot;
        float BendAt(float bendPx, float fy) { double k = Math.Max(0, 1 - fy / SysBendReach); return (float)(bendPx * k * k); }
        float SysRightAt(float y) { return _sysRight - BendAt(_sysBend, (y - _sysTop) / Math.Max(1f, _sysBot - _sysTop)); }
        public static readonly int[] SysMusTrack = { 1044, 353, 1296, 403 }, SysMusToggle = { 1314, 358, 1523, 398 };      // (the tracks = the game's drag maths: x 1044..1296 since the fold-out moved)
        public static readonly int[] SysSfxTrack = { 1044, 436, 1296, 486 }, SysSfxToggle = { 1314, 441, 1523, 481 };
        public static readonly int[] SysOk = { 1294, 518, 1523, 568 };
        bool _sysOpen, _sysQuit, _sfxOn, _musOn, _dragS, _dragM, _sysSave, _sysLoad; int _sfxLv = 100, _musLv = 100;
        double _sysOpenedAt = -10, _sysClosedAt = -10, _sysModeAt = -10; int _sysHover = -1;
        /// <summary>The system menu's opening sound (the degauss on ESC / Q). Off until its new sound is in (Josh, 2026-10-15).</summary>
        public bool SysOpenSound = false;
        /// <summary>From the game, each frame: the fold-out up (0x1523D6), quit confirm (0x1524CA), the save / load lists, the sound
        /// toggles and levels (0x14693A..0x146940; a level above 127 is the drag's pixel step -- kept from before), the drags.</summary>
        public void SetSys(bool up, bool quit, bool saveList, bool loadList, bool sfxOn, bool musOn, int sfxLevel, int musLevel, bool dragS, bool dragM)
        {
            double t = _clock.Elapsed.TotalSeconds;
            // (the opening sound -- the degauss thunk on ESC / Q -- is OFF: Josh, 2026-10-15, it played during a title load's loading sequence,
            // and a new system-menu sound is coming; SysOpenSound brings the old one back)
            if (up && !_sysOpen) { _sysOpenedAt = t; _sysModeAt = t; if (SysOpenSound && Sound != null && Sound.On) { try { Sound.DegaussSound(Degauss * 0.8); } catch { } } }
            if (!up && _sysOpen) _sysClosedAt = t;
            if (up && quit != _sysQuit) { _sysModeAt = t; if (Sound != null && Sound.On) { try { Sound.Line(quit ? 23 : 7, 0.12, quit ? 0.9 : 1.2); } catch { } } }
            if (up && Sound != null && Sound.On && ((sfxOn != _sfxOn) || (musOn != _musOn)) && _sysOpen) { try { Sound.Line(17, 0.07, (sfxOn && musOn) ? 1.25 : 0.95); } catch { } }
            _sysOpen = up; _sysQuit = quit; _sysSave = saveList; _sysLoad = loadList; _sfxOn = sfxOn; _musOn = musOn; _dragS = dragS; _dragM = dragM;
            if (sfxLevel >= 0 && sfxLevel <= 127) _sfxLv = sfxLevel; if (musLevel >= 0 && musLevel <= 127) _musLv = musLevel;
            if (up)
            {
                int hv = SysHit(_cx, _cy);
                if (hv != _sysHover && hv >= 0 && Sound != null && Sound.On) { try { Sound.Typing(hv + 30, 0.035, 1.35); } catch { } }
                _sysHover = hv;
            }
        }
        /// <summary>The game's OK (its one confirm, screen 3) is live: quit asking, or a slot / RESTART picked in a list.</summary>
        bool SysConfirm { get { return _sysQuit || ((_sysSave || _sysLoad) && (_sel >= 0 && _sel <= 4 || _sel == 6)); } }
        public bool SysPlaying { get { return _sysOpen || _clock.Elapsed.TotalSeconds - _sysClosedAt < 0.2; } }
        static bool In(int[] r, int x, int y) { return x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]; }
        // 0 save, 1 load, 2 quit, 3 music track, 4 music toggle, 5 sfx track, 6 sfx toggle, 7 confirm; -1 nothing
        int SysHit(int x, int y)
        {
            if (In(SysSave, x, y)) return 0; if (In(SysLoad, x, y)) return 1; if (In(SysQuit, x, y)) return 2;
            if (In(SysMusTrack, x, y)) return 3; if (In(SysMusToggle, x, y)) return 4; if (In(SysSfxTrack, x, y)) return 5; if (In(SysSfxToggle, x, y)) return 6;
            if (SysConfirm && In(SysOk, x, y)) return 7;
            return -1;
        }
        /// <summary>The game's drawings to leave out while the panels show (view px x0 y0 x1 y1): one box over the memory core's
        /// and the fold-out's, whichever are up.</summary>
        public int[] HideAll
        {
            get
            {
                bool m = Playing, sy = SysPlaying; if (!m && !sy) return null;
                int[] a = m ? HideRect : null, b = sy ? new[] { Math.Min(SysX0, 1029), Math.Min(SysY0, 89) - ViewY, SysX1 + 1, Math.Max(SysY1, 513) + 1 - ViewY } : null;      // (always the game's whole fold-out, 1029..1543 x 89..513, too)
                if (a == null) return b; if (b == null) return a;
                return new[] { Math.Min(a[0], b[0]), Math.Min(a[1], b[1]), Math.Max(a[2], b[2]), Math.Max(a[3], b[3]) };
            }
        }
        RectangleF R(int[] r) { return RectangleF.FromLTRB(PX(r[0]), PY(r[1]), PX(r[2]), PY(r[3])); }
        // active: a key waiting for its click (the confirm) -- lit faintly, its outline the sheen's track (Sheen).
        void Button(Graphics g, int[] r, string label, string sub, bool hov, bool lit, Font f, Font fs, Pen frame, Pen thin, Brush bHi, Brush bAm, Brush bDim, Brush bDark, bool active = false)
        {
            var rr = R(r);
            if (lit) g.FillRectangle(new SolidBrush(C(Amber, 0.88)), rr); else if (hov) g.FillRectangle(new SolidBrush(C(Amber, active ? 0.32 : 0.2)), rr); else if (active) g.FillRectangle(new SolidBrush(C(Amber, 0.14)), rr);
            if (!active) g.DrawRectangle(lit || hov ? frame : thin, rr.X, rr.Y, rr.Width, rr.Height);      // (a waiting key's outline is the sheen's track: Sheen)
            var sz = g.MeasureString(label, f);
            float ty = rr.Y + (rr.Height - sz.Height) / 2f - (sub != null ? fs.Height * 0.3f : 0);
            Crisp.Text(g, label, f, lit ? bDark : bHi, rr.X + (rr.Width - sz.Width) / 2f, ty);
            if (sub != null) { var s2 = g.MeasureString(sub, fs); Crisp.Text(g, sub, fs, lit ? bDark : bDim, rr.X + (rr.Width - s2.Width) / 2f, ty + sz.Height * 0.86f); }
        }
        // THE CONFIRM KEY ASKS FOR ITS CLICK (Josh, 2026-10-13: "the 'confirm' button should become active but also have a
        // revolving effect on its outline clarifying that the user needs to click it ... an in-universe style revolving 'sheen'
        // that slowly revolves on the button's outline ... ... anytime the player needs to confirm something
        // after an initial action in the menu systems"; then "switched back to the amber/orange color rather than the teal"): a faint amber outline, and a bright head with a fading tail running round
        // it once every SheenSeconds -- a soft wide glow under a crisp line, the head itself in the flare.
        void Sheen(Graphics g, RectangleF rr, double t, float s)
        {
            float w = rr.Width, h = rr.Height, per = 2 * (w + h);
            if (per < 4) return;
            Func<float, PointF> At = d =>
            {
                d = ((d % per) + per) % per;
                if (d < w) return new PointF(rr.X + d, rr.Y); d -= w;
                if (d < h) return new PointF(rr.Right, rr.Y + d); d -= h;
                if (d < w) return new PointF(rr.Right - d, rr.Bottom); d -= w;
                return new PointF(rr.X, rr.Bottom - d);
            };
            using (var rim = new Pen(C(Amber, 0.5), Math.Max(1f, 1.2f * s))) g.DrawRectangle(rim, rr.X, rr.Y, w, h);
            float head = (float)((t / Math.Max(0.3, SheenSeconds)) % 1.0) * per, tail = per * 0.38f; const int n = 56;
            var sm = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
            for (int pass = 0; pass < 2; pass++)
                using (var pen = new Pen(Color.Transparent, pass == 0 ? Math.Max(3.5f, 5.5f * s) : Math.Max(1.2f, 1.7f * s)) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    for (int i = n - 1; i >= 0; i--)
                    {
                        double k = Math.Pow(1 - i / (double)n, 1.8);
                        pen.Color = C(i < 4 && pass == 1 ? AmberHi : Amber, (pass == 0 ? 0.2 : 1.0) * k);
                        // (each piece through any corner it turns, so the head stays on the outline)
                        float d0 = head - tail * (i + 1) / n, d1 = head - tail * i / n;
                        var p0 = At(d0); var p1 = At(d1);
                        float[] corners = { w, w + h, 2 * w + h, per };
                        PointF? mid = null;
                        foreach (var cn in corners) { float a0 = ((d0 % per) + per) % per, a1 = a0 + (d1 - d0); if (a0 < cn && a1 > cn) { mid = At(cn); break; } }
                        if (mid.HasValue) { g.DrawLine(pen, p0, mid.Value); g.DrawLine(pen, mid.Value, p1); } else g.DrawLine(pen, p0, p1);
                    }
            g.SmoothingMode = sm;
        }
        void Slider(Graphics g, float s, int[] track, string name, int level, bool on, bool drag, bool hov, Font f, Font fs, Pen frame, Pen thin, Brush bHi, Brush bAm, Brush bDim)
        {
            var rr = R(track);
            Crisp.Text(g, name, fs, bDim, rr.X + 2 * s, rr.Y - fs.Height - 2 * s);
            // the bar: 24 segments; the GAME's track -- louder to the LEFT (its drag maths: level 127 at x 1100, 0 at 1352)
            var mx = g.MeasureString("MAX", fs); float bx0 = rr.X + mx.Width + 10 * s, bx1 = rr.Right - mx.Width - 10 * s, by0 = rr.Y + rr.Height * 0.3f, by1 = rr.Bottom - rr.Height * 0.3f;
            int segs = 24, lit = on ? (int)Math.Round(level * segs / 127.0) : 0; float sw = (bx1 - bx0) / segs;
            for (int i = 0; i < segs; i++)
            {
                bool l = i >= segs - lit;     // (lit from the right end leftward, as the game's own bar)
                g.FillRectangle(new SolidBrush(C(l ? (drag ? AmberHi : Amber) : AmberDim, l ? 0.92 : 0.28)), bx0 + i * sw + 1, by0, sw - 2.2f * s, by1 - by0);
            }
            g.DrawRectangle(hov || drag ? frame : thin, rr.X, rr.Y, rr.Width, rr.Height);
            float ly = rr.Y + (rr.Height - mx.Height) / 2f; Crisp.Text(g, "MAX", fs, bDim, rr.X + 5 * s, ly); var mz = g.MeasureString("MIN", fs); Crisp.Text(g, "MIN", fs, bDim, rr.Right - mz.Width - 5 * s, ly);      // (inside the track's ends: below it they ran into the next slider's name)
            string pct = on ? string.Format("{0}%", (int)Math.Round(level * 100 / 127.0)) : "MUTED"; var pz = g.MeasureString(pct, fs);
            Crisp.Text(g, pct, fs, on ? bAm : bDim, rr.Right - pz.Width - 2 * s, rr.Y - fs.Height - 2 * s);
        }
        void DrawSysContent(Graphics g, float s, double t)
        {
            float x0 = PX(SysX0), y0 = PY(SysY0), x1 = _sysRight, y1 = PY(SysY1);
            using (var frame = new Pen(C(Amber, 0.85), Math.Max(1.5f, 2.2f * s)))
            using (var thin = new Pen(C(AmberDim, 0.8), Math.Max(1f, 1f * s)))
            using (var fSmall = Crisp.Font(14f * s, FontStyle.Bold))
            using (var fTitle = Crisp.Font(34f * s, FontStyle.Bold))
            using (var fBtn = Crisp.Font(22f * s, FontStyle.Bold))
            using (var bHi = new SolidBrush(C(AmberHi, 0.97)))
            using (var bAm = new SolidBrush(C(Amber, 0.92)))
            using (var bDim = new SolidBrush(C(AmberDim, 0.9)))
            using (var bDark = new SolidBrush(Color.FromArgb(240, 18, 10, 2)))
            {
                float m = 12 * s, br = 40 * s;
                foreach (var cnr in new[] { new[] { x0 + m, y0 + m, 1f, 1f }, new[] { x1 - m, y0 + m, -1f, 1f }, new[] { x0 + m, y1 - m, 1f, -1f }, new[] { x1 - m, y1 - m, -1f, -1f } })
                { g.DrawLine(frame, cnr[0], cnr[1], cnr[0] + br * cnr[2], cnr[1]); g.DrawLine(frame, cnr[0], cnr[1], cnr[0], cnr[1] + br * cnr[3]); }
                float hx = PX(SysSave[0]), hy = PY(SysY0 + 40);
                Crisp.Text(g, Typed("RAPTOR H.U.D.  //  SYSTEM CORE", t, _sysModeAt + 0.05, 70), fSmall, bDim, hx, hy);
                Crisp.Text(g, Typed(_sysQuit ? "SHUTDOWN?" : "SYSTEMS", t, _sysModeAt + 0.12, 32), fTitle, bHi, hx, hy + 20 * s);
                // the power key (QUIT): top right
                Button(g, SysQuit, "QUIT", "SYSTEM", _sysHover == 2, _sysQuit, fBtn, fSmall, frame, thin, bHi, bAm, bDim, bDark);
                float ry = PY(SysSave[1] - 10); g.DrawLine(thin, hx, ry, PX(SysLoad[2]), ry);
                if (t < _sysModeAt + 0.25) return;
                Button(g, SysSave, "WRITE LOG", "SAVE", _sysHover == 0, _sysSave, fBtn, fSmall, frame, thin, bHi, bAm, bDim, bDark);
                Button(g, SysLoad, "READ LOG", "LOAD", _sysHover == 1, _sysLoad, fBtn, fSmall, frame, thin, bHi, bAm, bDim, bDark);
                if (t < _sysModeAt + 0.4) return;
                Slider(g, s, SysMusTrack, "MUSIC", _musLv, _musOn, _dragM, _sysHover == 3, fBtn, fSmall, frame, thin, bHi, bAm, bDim);
                Button(g, SysMusToggle, _musOn ? "ON" : "OFF", "MUSIC", _sysHover == 4, _musOn, fBtn, fSmall, frame, thin, bHi, bAm, bDim, bDark);
                Slider(g, s, SysSfxTrack, "EFFECTS", _sfxLv, _sfxOn, _dragS, _sysHover == 5, fBtn, fSmall, frame, thin, bHi, bAm, bDim);
                Button(g, SysSfxToggle, _sfxOn ? "ON" : "OFF", "EFFECTS", _sysHover == 6, _sfxOn, fBtn, fSmall, frame, thin, bHi, bAm, bDim, bDark);
                // the confirm row: only while QUIT is asking
                float py = PY(SysOk[1]);
                if (SysConfirm)
                {
                    // the game's one OK: quitting, or committing the memory core's pick (save / load / restart)
                    string what = _sysQuit ? "> CONFIRM VISOR SHUTDOWN" : _sel == 6 ? "> RESTART THE MISSION" : _sysSave ? "> COMMIT TO ARCHIVE" : "> RESTORE ARCHIVE";
                    string key = _sysQuit ? "CONFIRM" : _sel == 6 ? "RESTART" : _sysSave ? "COMMIT" : "RESTORE", sub = _sysQuit ? "QUIT GAME" : _sysSave ? "SAVE" : "LOAD";
                    if (((int)(t * 2.2) & 1) == 0) Crisp.Text(g, what, fSmall, bAm, hx, py + 6 * s);
                    Crisp.Text(g, _sysQuit ? "QUIT AGAIN OR ESC TO CANCEL" : "OR PRESS ENTER", fSmall, bDim, hx, py + 26 * s);
                    Button(g, SysOk, key, sub, _sysHover == 7, false, fBtn, fSmall, frame, thin, bHi, bAm, bDim, bDark, true);
                    Sheen(g, R(SysOk), t, s);
                }
                else if (((int)(t * 1.6) & 1) == 0 || t < _sysModeAt + 1.2) Crisp.Text(g, Typed("> ESC TO CLOSE", t, _sysModeAt + 0.6, 50), fSmall, bAm, hx, py + 16 * s);
            }
        }        // ---- THE MEMORY CELL (Josh, 2026-10-09: on hovering a slot "a vector based static shape ... animated but icon like ... for
        // this helmet's operating system"): the archive as a small wireframe cube turning in the row, its data bars pulsing inside;
        // writing (save) a chevron streams down into it, reading (load) out of it; an empty slot is a dashed, hollow cell. It
        // flickers on as the cursor arrives and bobs a little -- one amber a touch under the brackets'.
        double _cellAt = -10; int _cellRow = -99;
        void MemCell(Graphics g, float s, double t, float cx, float cy, float r, bool empty, bool sel)
        {
            int row = _hover >= 0 ? _hover : _sel;
            if (row != _cellRow) { _cellRow = row; _cellAt = t; }
            double age = t - _cellAt, inK = Math.Min(1, age / 0.18);
            if (age < 0.18 && (((int)(age * 60)) & 1) == 1) return;                   // (it flickers on)
            float sc = r * (float)(0.6 + 0.4 * inK), by = cy + (float)Math.Sin(t * 2.2) * 1.6f * s;
            int ink = sel ? 0x2A1806 : Amber; double a = sel ? 0.85 : 0.78;
            double yaw = t * 1.1, pitch = 0.52, cyw = Math.Cos(yaw), syw = Math.Sin(yaw), cp = Math.Cos(pitch), sp = Math.Sin(pitch);
            Func<double, double, double, PointF> P = (x, y, z) =>
            {
                double x1 = x * cyw + z * syw, z1 = -x * syw + z * cyw, y1 = y * cp - z1 * sp;
                return new PointF(cx + (float)(x1 * sc * 0.62), by + (float)(y1 * sc * 0.62));
            };
            var v = new PointF[8]; int k = 0;
            foreach (int xs in new[] { -1, 1 }) foreach (int ys in new[] { -1, 1 }) foreach (int zs in new[] { -1, 1 }) v[k++] = P(xs, ys, zs);
            int[,] e = { { 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 }, { 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 }, { 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 } };
            using (var pen = new Pen(C(ink, a), Math.Max(1f, 1.4f * s)))
            using (var dim = new Pen(C(ink, a * 0.45), Math.Max(1f, 1f * s)))
            {
                if (empty) { pen.DashStyle = DashStyle.Dash; }
                for (int i = 0; i < 12; i++) g.DrawLine(pen, v[e[i, 0]], v[e[i, 1]]);
                if (!empty)
                {
                    // the data: three bars inside, each lit to its own pulsing length
                    for (int b = 0; b < 3; b++)
                    {
                        double ly = -0.5 + 0.5 * b, len = 0.25 + 0.55 * (0.5 + 0.5 * Math.Sin(t * (3.1 + b * 1.7) + b * 2.0));
                        g.DrawLine(pen, P(-0.6, ly, 0), P(-0.6 + 1.2 * len, ly, 0));
                    }
                }
                else g.DrawLine(dim, P(-0.7, 0.7, 0), P(0.7, -0.7, 0));                    // (vacant: struck through)
                // writing in / reading out: a chevron sliding along the cell's axis, fading as it goes
                double ph = (t * 0.9) % 1.0, dir = _save ? 1 : -1;
                float off = (float)((_save ? -1.9 + 1.4 * ph : -0.5 - 1.4 * ph) * sc * 0.62), ca = (float)(1 - ph);
                using (var cpen = new Pen(C(ink, a * ca), Math.Max(1f, 1.4f * s)))
                {
                    float w = sc * 0.5f, h = sc * 0.28f * (float)dir, yy = by + off;
                    g.DrawLines(cpen, new[] { new PointF(cx - w, yy - h), new PointF(cx, yy + h * 0.2f), new PointF(cx + w, yy - h) });
                }
                // corner ticks round it: the cell held in the visor's sight
                float q = sc * 1.25f, tl = sc * 0.35f;
                foreach (var cn in new[] { new[] { -1f, -1f }, new[] { 1f, -1f }, new[] { -1f, 1f }, new[] { 1f, 1f } })
                { float x0 = cx + cn[0] * q, y0 = cy + cn[1] * q; g.DrawLine(dim, x0, y0, x0 - cn[0] * tl, y0); g.DrawLine(dim, x0, y0, x0, y0 - cn[1] * tl); }
            }
        }

        // ---- BACK TO THE WORLD (Josh, 2026-10-09: after a save is committed and the menus close, "a bit of vector static like a
        // shutter ... as the user returns to the game world and the visor color once again fades"): over the whole view -- static
        // (bright horizontal dashes, re-thrown 30 times a second) gathering, the shutter's lids snapping shut from top and bottom to
        // a bright line, then opening, and the world seen in the visor's amber monochrome fading back to its own colour (as the
        // boot's colour-up). ~1.4 s, then nothing.
        public double ReturnSeconds = 1.45;
        double _returnAt = -10; bool _returnSnd;
        public bool ReturnPlaying { get { double r = _clock.Elapsed.TotalSeconds - _returnAt; return r > -0.3 && r < ReturnSeconds; } }
        /// <summary>Any of this class's pictures showing (the watcher keeps the decorated path while true).</summary>
        public bool AnyPlaying { get { return Playing || SysPlaying || ReturnPlaying || ReadPlaying; } }
        static double Sm(double x) { x = Math.Max(0, Math.Min(1, x)); return x * x * (3 - 2 * x); }
        void DrawReturn(int[] pic, int pw, int vr, float s, double rt)
        {
            if (!_returnSnd && Sound != null && Sound.On) { _returnSnd = true; try { Sound.Line(51, 0.28, 0.8); Sound.DegaussSound(Degauss * 0.45); } catch { } }
            // the lids: closing 0.12..0.34 to the middle, held to 0.42, opening by 0.70
            double close = Sm((rt - 0.12) / 0.22) * (1 - Sm((rt - 0.42) / 0.28));
            int mid = vr / 2, lid = (int)Math.Round(close * mid);
            // the amber: full once the lids are shut, fading from 0.42 to the end
            double amber = rt < 0.42 ? Sm(rt / 0.3) : 1 - Sm((rt - 0.42) / (ReturnSeconds - 0.5));
            // static: most while the lids move
            double stat = Math.Max(0, Math.Sin(Math.Min(1, rt / 0.75) * Math.PI)) * 0.9;
            int ar = (Amber >> 16) & 255, ag = (Amber >> 8) & 255, ab = Amber & 255;
            int line = Math.Max(1, (int)Math.Round(s));
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                int o = y * pw;
                bool shut = y < lid || y >= vr - lid;
                for (int x = 0; x < pw; x++)
                {
                    int c = pic[o + x];
                    if (shut) { pic[o + x] = 0x080502; continue; }
                    if (amber <= 0.002) continue;
                    double r = (c >> 16) & 255, gg = (c >> 8) & 255, b = c & 255, l = (0.3 * r + 0.59 * gg + 0.11 * b) / 255.0;
                    double tr = l * ar * 1.15, tg = l * ag * 1.1, tb = l * ab * 0.9;
                    if (((y / line) & 1) == 1) { tr *= 0.82; tg *= 0.82; tb *= 0.82; }           // (interlaced, as the glass)
                    r += (tr - r) * amber; gg += (tg - gg) * amber; b += (tb - b) * amber;
                    pic[o + x] = ((int)Math.Min(255, r) << 16) | ((int)Math.Min(255, gg) << 8) | (int)Math.Min(255, b);
                }
            });
            // the lids' lips: bright lines on their edges, a hot line across the middle while shut
            Action<int, double> Lip = (y, k) =>
            {
                if (y < 0 || y >= vr) return;
                for (int x = 0; x < pw; x++) { int c = pic[y * pw + x]; int r = (int)Math.Min(255, ((c >> 16) & 255) + 255 * k), gg = (int)Math.Min(255, ((c >> 8) & 255) + 190 * k), b = (int)Math.Min(255, (c & 255) + 90 * k); pic[y * pw + x] = (r << 16) | (gg << 8) | b; }
            };
            if (lid > 0) for (int d = 0; d < 2 * line; d++) { Lip(lid + d, 0.55 - 0.2 * d / line); Lip(vr - lid - 1 - d, 0.55 - 0.2 * d / line); }
            if (close > 0.97) for (int d = -line; d <= line; d++) Lip(mid + d, 0.9 - 0.3 * Math.Abs(d) / Math.Max(1, line));
            // the static: short bright dashes scattered over the open part, thrown anew each 1/30 s
            if (stat > 0.02)
            {
                var rnd = new Random((int)(rt * 30) * 7919 + 17);
                int n = (int)(stat * 260 * pw / 1600.0);
                for (int i = 0; i < n; i++)
                {
                    int y = rnd.Next(vr); if (y < lid || y >= vr - lid) continue;
                    int len = (int)((8 + rnd.Next(120)) * s), x0 = rnd.Next(pw), th = 1 + rnd.Next(2) * line;
                    double k = (0.25 + 0.6 * rnd.NextDouble()) * stat; bool white = rnd.Next(5) == 0;
                    for (int dy = 0; dy < th && y + dy < vr; dy++)
                        for (int x = x0; x < Math.Min(pw, x0 + len); x++)
                        {
                            int c = pic[(y + dy) * pw + x];
                            int r = (int)Math.Min(255, ((c >> 16) & 255) + (white ? 255 : ar) * k), gg = (int)Math.Min(255, ((c >> 8) & 255) + (white ? 240 : ag) * k), b = (int)Math.Min(255, (c & 255) + (white ? 210 : ab) * k);
                            pic[(y + dy) * pw + x] = (r << 16) | (gg << 8) | b;
                        }
                }
            }
        }
        // the tube coming on: a bright horizontal line across the middle, fading as the picture opens
        void DrawOpenLine(int[] pic, int pw, int x0, int x1, int y, double grow)
        {
            double a = 1 - grow; int amb = AmberHi;
            for (int dy = -1; dy <= 1; dy++)
            {
                int yy = y + dy; if (yy < 0 || yy * pw >= pic.Length) continue;
                double k = a * (dy == 0 ? 1 : 0.45);
                for (int x = x0; x <= x1; x++) { int o = yy * pw + x, c = pic[o]; int r = (int)Math.Min(255, ((c >> 16) & 255) + ((amb >> 16) & 255) * k), g = (int)Math.Min(255, ((c >> 8) & 255) + ((amb >> 8) & 255) * k), b = (int)Math.Min(255, (c & 255) + (amb & 255) * k); pic[o] = (r << 16) | (g << 8) | b; }
            }
        }
        // the visor's own pointer: an amber arrow with a dark edge, its tip on the game's cursor
        void DrawOwnPointer(int[] pic, int pw, int vr, float s)
        {
            CursorFallback++;
            float tx = PX(_cx), ty = PY(_cy), k = 1.15f * s;
            var pts = new[] { new PointF(tx, ty), new PointF(tx, ty + 19 * k), new PointF(tx + 4.6f * k, ty + 14.6f * k), new PointF(tx + 8.2f * k, ty + 22 * k),
                              new PointF(tx + 11 * k, ty + 20.6f * k), new PointF(tx + 7.4f * k, ty + 13.4f * k), new PointF(tx + 13.4f * k, ty + 13.4f * k) };
            var hnd = GCHandle.Alloc(pic, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(pw, pic.Length / pw, pw * 4, PixelFormat.Format32bppRgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                using (var fill = new SolidBrush(C(AmberHi, 1)))
                using (var edge = new Pen(Color.FromArgb(255, 20, 12, 4), Math.Max(1.2f, 1.6f * s)))
                {
                    g.SetClip(new Rectangle(0, 0, pw, vr)); g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.FillPolygon(fill, pts); g.DrawPolygon(edge, pts);
                }
            }
            finally { hnd.Free(); }
        }
        // typed text: how much of `txt` shows `at` seconds after `from`
        static string Typed(string txt, double now, double from, double cps)
        {
            if (now < from) return ""; int n = Math.Min(txt.Length, (int)((now - from) * cps)); return txt.Substring(0, n);
        }
        // WRITING THE LOG: the heading stays, the rows give way to the archive being written, a fill bar timed to the game's
        // own save (WriteSeconds, then full the moment it reports done), a hex stream racing past, "LOG WRITTEN." at the end
        // READING A LOG (Josh, 2026-10-10: "when loading a game lets have a screen on the visor very similar to the saving game
        // screen, but instead it will read 'Initiating log file "[name of save being loaded]"'"): the same panel over the start
        // of the visor's re-boot -- the title typed with the archive's name, the bar filling over ReadSeconds, the stream, then
        // "LOG FILE INITIATED." for ReadHold, and the panel folds away into the re-boot. BeginReading starts it (the renderer
        // calls it when a load's re-boot begins: from the fold-out, or the title menu's Continue / Load).
        public double ReadSeconds = 2.2, ReadHold = 0.7;
        /// <summary>The load is still under way (a load from the TITLE: the renderer is loading the room and the visor's
        /// re-boot holds for it): the reading does not finish while this is set -- its bar creeps on short of full, and
        /// "LOG FILE INITIATED." comes when it clears. The renderer sets it.</summary>
        public volatile bool ReadWait;
        /// <summary>The load is done (the renderer's view is up): the reading ends now -- not before ReadMin -- its bar running
        /// on to full in 0.3 s (Josh: the loading sequence follows the actual loading time).</summary>
        public void FinishReading()
        {
            ReadWait = false; double t = _clock.Elapsed.TotalSeconds;
            if (t >= _readAt && t < _readAt + _readLen) { _readFinAt = t; _readLen = Math.Max(ReadMin, t - _readAt + 0.3); }
        }
        public double ReadMin = 1.0; double _readFinAt = -10;
        double _readAt = -10, _readBlip = -10, _readLen = 2.2, _readP; int _readSlot = -1; string _readName = ""; bool _readDoneSnd;
        // THE ROOM IS PART OF THE LOAD (Josh, 2026-10-12: "we need those textures to be loaded when loading a game as well, but
        // that needs to be lumped into the core loading UI/animation as part of the loading process"): the renderer reports the
        // new room's textures -- decoded, then sent to the card -- as LoadProgress (0..1). The archive itself is then the first
        // 30% of the bar on the planned time (creeping on while the room has not begun), the rest follows the room, never
        // backwards, and the line under the bar says what it is doing. -1 (RoomLoadAhead off: no renderer room to wait for):
        // the bar as before.
        public volatile float LoadProgress = -1f;
        public bool RoomLoadAhead = true;
        public string RoomStage = "ANALYZING ENVIRONMENT";
        double _progBase = -1, _readPT = -1;
        double ReadBar(double rt, double t)
        {
            double e = 1 - Math.Pow(1 - Math.Min(1, rt / ReadSeconds), 2);
            float lp = LoadProgress;
            if (lp < 0) return Math.Max(_readP, Math.Min(0.99, e));
            double tgt = 0.30 * e + 0.12 * (1 - Math.Exp(-Math.Max(0, rt - ReadSeconds) / 3.0));
            if (lp > 0) { if (_progBase < 0) _progBase = Math.Max(_readP, 0.30); tgt = Math.Max(tgt, _progBase + (0.99 - _progBase) * Math.Min(1, lp)); }
            double dt = _readPT >= 0 ? Math.Max(0, Math.Min(0.25, t - _readPT)) : 0; _readPT = t;
            return tgt <= _readP ? _readP : _readP + (tgt - _readP) * Math.Min(1, dt * 7);
        }
        public void BeginReading(int slot, string name)
        {
            double t = _clock.Elapsed.TotalSeconds; _readAt = t; _readLen = ReadSeconds; _readP = 0; _readSlot = slot; _readName = (name ?? "").Trim().ToUpperInvariant(); _readDoneSnd = false;
            LoadProgress = RoomLoadAhead ? 0f : -1f; _progBase = -1; _readPT = -1;
            if (Sound != null && Sound.On) { try { Sound.DegaussSound(Degauss); Sound.Typing(73, 0.55, 1.05); } catch { } }
        }
        double ReadEnd { get { return _readAt + _readLen + ReadHold; } }
        // while the load is held up the reading stretches: always another 0.3 s to go (from where the clock is)
        // (whenever it is looked at -- a frame can come late while the renderer loads; 60 s at most, whatever the renderer does)
        void StretchReading(double t) { if (ReadWait && t >= _readAt && t - _readAt < 60 && t - _readAt > _readLen - 0.3) _readLen = t - _readAt + 0.3; }
        bool Reading(double t) { return t >= _readAt && t < ReadEnd + 0.2; }
        public bool ReadPlaying { get { return Reading(_clock.Elapsed.TotalSeconds); } }
        void DrawWriting(Graphics g, float s, double t) { DrawArchive(g, s, t, false); }
        void DrawArchive(Graphics g, float s, double t, bool read)
        {
            float x0 = PX(PanelX0), y0 = PY(PanelY0), x1 = PX(PanelX1), y1 = PY(PanelY1);
            double rt = t - _readAt;
            bool done = read ? rt >= _readLen : !_writing; double wt = read ? rt : t - _writeAt;
            // reading: eased over ReadSeconds as planned; a load held up past that (ReadWait) sits at 99% until it is done
            double p = !read ? (done ? 1 : Math.Min(0.96, 1 - Math.Exp(-wt / (WriteSeconds * 0.45))))
                     : done ? 1 : ReadBar(rt, t);
            if (read && !done && _readFinAt >= _readAt) p = Math.Max(p, _readP + (1 - _readP) * Math.Min(1, (t - _readFinAt) / 0.3));
            if (read) _readP = p;
            double startAt = read ? _readAt : _writeAt, doneAt = read ? _readAt + _readLen : _wroteAt;
            using (var frame = new Pen(C(Amber, 0.85), Math.Max(1.5f, 2.2f * s)))
            using (var thin = new Pen(C(AmberDim, 0.8), Math.Max(1f, 1f * s)))
            using (var fSmall = Crisp.Font(15f * s, FontStyle.Bold))
            using (var fTitle = Crisp.Font(40f * s, FontStyle.Bold))
            using (var fRow = Crisp.Font(34f * s, FontStyle.Bold))
            using (var bHi = new SolidBrush(C(AmberHi, 0.97)))
            using (var bAm = new SolidBrush(C(Amber, 0.92)))
            using (var bDim = new SolidBrush(C(AmberDim, 0.9)))
            {
                float m = 14 * s, br = 46 * s;
                foreach (var cnr in new[] { new[] { x0 + m, y0 + m, 1f, 1f }, new[] { x1 - m, y0 + m, -1f, 1f }, new[] { x0 + m, y1 - m, 1f, -1f }, new[] { x1 - m, y1 - m, -1f, -1f } })
                { g.DrawLine(frame, cnr[0], cnr[1], cnr[0] + br * cnr[2], cnr[1]); g.DrawLine(frame, cnr[0], cnr[1], cnr[0], cnr[1] + br * cnr[3]); }
                float hx = PX(RowX0), hy = PY(PanelY0 + 30), hx1 = PX(RowX1);
                Crisp.Text(g, read ? "RAPTOR H.U.D.  //  MEMORY CORE  //  READ ACCESS" : "RAPTOR H.U.D.  //  MEMORY CORE  //  WRITE ACCESS", fSmall, bDim, hx, hy);
                // the title: typed, then its dots counting while it works; done = steady (after a short blink)
                int slotN = read ? _readSlot : _writeSlot;
                string nm = read ? _readName : (slotN >= 0 && slotN < 5 ? (_names[slotN] ?? "") : "");
                string busy = read ? string.Format("INITIATING LOG FILE \"{0}\"", nm.Length > 0 ? nm : "UNNAMED") : "COMMITTING LOG TO MEMORY";
                string title = done ? (read ? "LOG FILE INITIATED." : "LOG COMMITTED.") : Typed(busy, t, startAt, 34) + (wt > 0.7 ? new string('.', 1 + (int)(wt * 3) % 3) : "");
                using (var fFit = busy.Length + 3 > 36 ? Crisp.Font((float)(40f * s * 36 / (busy.Length + 3)), FontStyle.Bold) : null)
                    if (!done || ((int)((t - doneAt) * 8) & 1) == 0 || t - doneAt > 0.3) Crisp.Text(g, title, done || fFit == null ? fTitle : fFit, bHi, hx, hy + 24 * s);
                float ry = PY(RowTop - 22); g.DrawLine(thin, hx, ry, hx1, ry);
                // which archive
                string who = slotN >= 0 && slotN < 5 ? string.Format("ARCHIVE {0:00}  //  {1}", slotN + 1, nm.Length > 0 ? nm : "UNNAMED") : "ARCHIVE";
                Crisp.Text(g, Typed(who, t, startAt + 0.2, 60), fRow, bAm, hx, PY(RowTop + 10));
                // the fill bar, segmented, its leading edge bright
                float bx0 = hx, bx1 = hx1, by0 = PY(RowTop + 96), by1 = PY(RowTop + 136);
                g.DrawRectangle(thin, bx0, by0, bx1 - bx0, by1 - by0);
                int segs = 40; float sw = (bx1 - bx0 - 8 * s) / segs; int lit = (int)Math.Floor(p * segs);
                for (int i = 0; i < lit; i++) g.FillRectangle(i == lit - 1 && !done ? bHi : bAm, bx0 + 4 * s + i * sw, by0 + 4 * s, sw - 3 * s, by1 - by0 - 8 * s);
                var pct = string.Format("{0,3}%", (int)Math.Round(p * 100));
                Crisp.Text(g, pct, fSmall, bDim, bx1 - g.MeasureString(pct, fSmall).Width, by1 + 6 * s);
                Crisp.Text(g, done ? "INTEGRITY VERIFIED" : read ? (LoadProgress > 0 && RoomStage != null ? RoomStage : "RESTORING ARCHIVE FROM MEMORY CORE") : "COMMITTING ARCHIVE TO MEMORY CORE", fSmall, bDim, bx0, by1 + 6 * s);
                // the stream: lines of hex scrolling up under the bar, newest brightest
                int tick = (int)(t * 18), lines = 8; float ly = PY(RowTop + 200), lh = 19 * s;
                for (int i = 0; i < lines; i++)
                {
                    var rnd = new Random((tick - i) * 7919 + 13);
                    var sb = new System.Text.StringBuilder(); sb.Append(string.Format("{0:X6}  ", ((tick - i) * 48) & 0xFFFFFF));
                    for (int k = 0; k < 16; k++) sb.Append(rnd.Next(0x100).ToString("X2")).Append(k == 7 ? "  " : " ");
                    double a = done ? 0.35 : 0.9 - i * 0.09;
                    using (var b = new SolidBrush(C(i == 0 && !done ? Amber : AmberDim, a))) Crisp.Text(g, sb.ToString(), fSmall, b, hx, ly + (lines - 1 - i) * lh);
                }
                // the prompt along the bottom
                float py = PY(PanelY1 - 44);
                string prompt = done ? (read ? "> LOG FILE INITIATED  //  RESUMING" : "> LOG COMMITTED  //  VISOR RESUMING") : "> DO NOT POWER DOWN THE VISOR";
                if (done || ((int)(t * 1.6) & 1) == 0) Crisp.Text(g, prompt, fSmall, bAm, hx, py);
            }
        }
        void DrawContent(Graphics g, float s, double t)
        {
            if (Reading(t)) { DrawArchive(g, s, t, true); return; }
            if (WriteScreen(t)) { DrawWriting(g, s, t); return; }
            double since = t - _modeAt;
            float x0 = PX(PanelX0), y0 = PY(PanelY0), x1 = PX(PanelX1), y1 = PY(PanelY1);
            using (var frame = new Pen(C(Amber, 0.85), Math.Max(1.5f, 2.2f * s)))
            using (var thin = new Pen(C(AmberDim, 0.8), Math.Max(1f, 1f * s)))
            using (var fSmall = Crisp.Font(15f * s, FontStyle.Bold))
            using (var fTitle = Crisp.Font(40f * s, FontStyle.Bold))
            using (var fRow = Crisp.Font(34f * s, FontStyle.Bold))
            using (var fNum = Crisp.Font(22f * s, FontStyle.Bold))
            using (var bHi = new SolidBrush(C(AmberHi, 0.97)))
            using (var bAm = new SolidBrush(C(Amber, 0.92)))
            using (var bDim = new SolidBrush(C(AmberDim, 0.9)))
            using (var bDark = new SolidBrush(Color.FromArgb(240, 18, 10, 2)))
            {
                // the frame: corner brackets, a rule under the heading
                float m = 14 * s, br = 46 * s;
                foreach (var cnr in new[] { new[] { x0 + m, y0 + m, 1f, 1f }, new[] { x1 - m, y0 + m, -1f, 1f }, new[] { x0 + m, y1 - m, 1f, -1f }, new[] { x1 - m, y1 - m, -1f, -1f } })
                { g.DrawLine(frame, cnr[0], cnr[1], cnr[0] + br * cnr[2], cnr[1]); g.DrawLine(frame, cnr[0], cnr[1], cnr[0], cnr[1] + br * cnr[3]); }
                float hx = PX(RowX0), hy = PY(PanelY0 + 30);
                Crisp.Text(g, Typed("RAPTOR H.U.D.  //  MEMORY CORE  //  " + (_save ? "WRITE" : "READ") + " ACCESS", t, _modeAt + 0.05, 70), fSmall, bDim, hx, hy);
                Crisp.Text(g, Typed(_save ? "COMMIT ARCHIVE" : "RECALL ARCHIVE", t, _modeAt + 0.15, 32), fTitle, bHi, hx, hy + 24 * s);
                float ry = PY(RowTop - 22); g.DrawLine(thin, hx, ry, PX(RowX1), ry);
                // the close box
                bool hc = _hover == 7;
                var cr = new RectangleF(PX(CloseX0), PY(CloseY0), PX(CloseX1) - PX(CloseX0), PY(CloseY1) - PY(CloseY0));
                if (hc) g.FillRectangle(new SolidBrush(C(Amber, 0.35)), cr);
                g.DrawRectangle(hc ? frame : thin, cr.X, cr.Y, cr.Width, cr.Height);
                float ci = cr.Width * 0.28f; g.DrawLine(frame, cr.X + ci, cr.Y + ci, cr.Right - ci, cr.Bottom - ci); g.DrawLine(frame, cr.Right - ci, cr.Y + ci, cr.X + ci, cr.Bottom - ci);
                // the rows
                for (int i = 0; i < Rows; i++)
                {
                    double rt = _modeAt + 0.3 + i * 0.07; if (t < rt) break;
                    float rx0 = PX(RowX0), rx1 = PX(RowX1), ra = PY(RowTop + i * RowPitch), rb = PY(RowTop + i * RowPitch + RowH);
                    string nm = _names[i] ?? ""; bool empty = nm.Length == 0 || nm == "EMPTY";
                    bool sel = _sel == i, hov = _hover == i, typing = sel && _save;
                    if (sel) g.FillRectangle(new SolidBrush(C(Amber, 0.88)), rx0, ra, rx1 - rx0, rb - ra);
                    else if (hov) g.FillRectangle(new SolidBrush(C(Amber, 0.18)), rx0, ra, rx1 - rx0, rb - ra);
                    g.DrawLine(sel ? frame : thin, rx0, rb, rx1, rb);
                    float ty = ra + (rb - ra - fRow.Height) / 2f;
                    Crisp.Text(g, string.Format("{0:00}", i + 1), fNum, sel ? bDark : bDim, rx0 + 10 * s, ra + (rb - ra - fNum.Height) / 2f);
                    string shown = Typed(empty && !typing ? "-- EMPTY --" : nm, t, rt, 60);
                    if (typing && ((int)(t * 2.5) & 1) == 0) shown += "_";
                    Crisp.Text(g, shown, fRow, sel ? bDark : (empty ? bDim : bHi), rx0 + 70 * s, ty);
                    string tag = typing ? string.Format("{0,2}/20", nm.Length) : (empty ? "VACANT" : "STORED");
                    var tsz = g.MeasureString(tag, fSmall);
                    Crisp.Text(g, tag, fSmall, sel ? bDark : bDim, rx1 - tsz.Width - 12 * s, ra + (rb - ra - tsz.Height) / 2f);
                    if (hov || (sel && _hover < 0)) MemCell(g, s, t, rx1 - tsz.Width - 12 * s - 52 * s, (ra + rb) / 2f, 26 * s, empty && !typing, sel);
                }
                // RESTART (load only): a button under the rows
                if (!_save && t > _modeAt + 0.7)
                {
                    bool hr = _hover == 6, sr = _sel == 6;
                    var rr = new RectangleF(PX(RestartX0), PY(RestartY0), PX(RestartX1) - PX(RestartX0), PY(RestartY1) - PY(RestartY0));
                    if (sr) g.FillRectangle(new SolidBrush(C(Amber, 0.88)), rr); else if (hr) g.FillRectangle(new SolidBrush(C(Amber, 0.2)), rr);
                    g.DrawRectangle(sr || hr ? frame : thin, rr.X, rr.Y, rr.Width, rr.Height);
                    var sz = g.MeasureString("RESTART MISSION", fNum);
                    Crisp.Text(g, "RESTART MISSION", fNum, sr ? bDark : bAm, rr.X + (rr.Width - sz.Width) / 2f, rr.Y + (rr.Height - sz.Height) / 2f);
                }
                // the prompt along the bottom, blinking once it has typed
                string prompt = _save ? (_sel >= 0 && _sel < 5 ? "KEY IN A NAME  //  ENTER TO COMMIT" : "SELECT A SLOT TO WRITE")
                                      : (_sel >= 0 ? "ENTER OR OK TO RESTORE" : "SELECT AN ARCHIVE");
                float py = PY(PanelY1 - 44);
                if (((int)(t * 1.6) & 1) == 0 || t < _modeAt + 1.2) Crisp.Text(g, Typed("> " + prompt, t, _modeAt + 0.9, 50), fSmall, bAm, hx, py);
                // a data stream down the right edge, as the boot's dump column
                // (in the heading, clear of the rows and the close box: two short columns left of the box)
                int tick = (int)(t * 12);
                for (int i = 0; i < 6; i++) for (int col = 0; col < 2; col++) { var rnd = new Random(tick * 131 + i * 7 + col * 977); Crisp.Text(g, rnd.Next(0x10000).ToString("X4") + " " + rnd.Next(0x100).ToString("X2"), fSmall, bDim, PX(CloseX0 - 250 + col * 110), PY(PanelY0 + 24) + i * 17 * s); }
            }
        }
    }
}
