// SceneGraph.cs -- read the LIVE scene graph: every frame's name, world matrix and visual.
//
// The renderer currently draws each room's .XAF in its REST POSE, so doors never open, items
// that have been picked up are still drawn, and characters (which live in their own .XAF
// files) are absent entirely. All three are the same gap: nothing after load consults the
// engine's own scene.
//
// Frame layout, from [[azrael-rl-object-model]] / [[azrael-scene-graph]]:
//     +0x24  char*  name          (a plain C string)
//     +0x30  Frame* parent
//     +0x34  Frame* sibling
//     +0x3C  Frame* first child
//     +0x4C  float[16] local matrix
//     +0x90  float[16] world matrix     (NOT +0x48/+0x8C -- those were a static-analysis
//                                        error corrected by measurement)
//     +0x268 {count, cap, ptr}  visual list  -- the engine-wide list shape
//
// Walking this in PowerShell is not viable at frame rate: ~130 nodes x several reads each,
// plus a 64-byte matrix per node, is thousands of ReadProcessMemory round trips per frame.
// One C# call per frame instead.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AztTool
{
    public class SceneNode
    {
        public uint Frame;          // guest address, the identity of this node
        public uint Parent;
        public string Name;
        public int Depth;
        public float[] World;       // 16 floats, row-vector / row-major
        public int VisualCount;     // 0 = a pure transform node, nothing to draw
    }

    public static class SceneGraph
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int n, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        // ONE HANDLE, KEPT. This runs every frame, and opening then closing a process handle
        // 22 times a second is pure overhead on a host whose spare CPU the emulator needs --
        // DOSBox runs the game on a single thread and its animation is clock-gated, so host
        // load turns directly into bigger animation steps inside the guest.
        static IntPtr _h = IntPtr.Zero;
        static int _hPid = 0;
        static IntPtr Handle(int pid)
        {
            if (_h != IntPtr.Zero && _hPid == pid) return _h;
            if (_h != IntPtr.Zero) { CloseHandle(_h); _h = IntPtr.Zero; }
            _h = OpenProcess(0x0010 /*VM_READ*/, false, pid);
            _hPid = pid;
            return _h;
        }
        // Call when the game exits: the next Walk would otherwise reuse a dead handle.
        public static void Release()
        {
            if (_h != IntPtr.Zero) { CloseHandle(_h); _h = IntPtr.Zero; _hPid = 0; }
        }

        public static List<SceneNode> Walk(int pid, long memBase, uint rootFrame, int maxNodes)
        {
            var res = new List<SceneNode>();
            IntPtr h = Handle(pid);
            if (h == IntPtr.Zero) return res;
            try
            {
                var buf4 = new byte[4];
                var buf64 = new byte[64];
                var nameBuf = new byte[64];
                var seen = new HashSet<uint>();
                // Explicit stack with depth, so sibling chains do not inherit a child's depth.
                var stack = new Stack<KeyValuePair<uint, int>>();
                stack.Push(new KeyValuePair<uint, int>(rootFrame, 0));

                while (stack.Count > 0 && res.Count < maxNodes)
                {
                    var cur = stack.Pop();
                    uint f = cur.Key; int depth = cur.Value;
                    if (f < 0x1000 || seen.Contains(f)) continue;
                    seen.Add(f);

                    var n = new SceneNode { Frame = f, Depth = depth, Name = "", World = new float[16] };

                    IntPtr got;
                    if (ReadProcessMemory(h, (IntPtr)(memBase + f + 0x30), buf4, 4, out got))
                        n.Parent = BitConverter.ToUInt32(buf4, 0);

                    // name: a pointer to a C string. A bad pointer reads as non-zero garbage,
                    // so the result is only accepted if it is printable.
                    if (ReadProcessMemory(h, (IntPtr)(memBase + f + 0x24), buf4, 4, out got))
                    {
                        uint np = BitConverter.ToUInt32(buf4, 0);
                        if (np > 0x1000 && ReadProcessMemory(h, (IntPtr)(memBase + np), nameBuf, 64, out got))
                        {
                            int z = Array.IndexOf(nameBuf, (byte)0);
                            if (z > 0)
                            {
                                bool ok = true;
                                for (int i = 0; i < z; i++) if (nameBuf[i] < 0x20 || nameBuf[i] > 0x7E) { ok = false; break; }
                                if (ok) n.Name = System.Text.Encoding.ASCII.GetString(nameBuf, 0, z);
                            }
                        }
                    }

                    if (ReadProcessMemory(h, (IntPtr)(memBase + f + 0x90), buf64, 64, out got))
                        for (int i = 0; i < 16; i++) n.World[i] = BitConverter.ToSingle(buf64, i * 4);

                    if (ReadProcessMemory(h, (IntPtr)(memBase + f + 0x268), buf4, 4, out got))
                        n.VisualCount = (int)BitConverter.ToUInt32(buf4, 0);

                    res.Add(n);

                    if (ReadProcessMemory(h, (IntPtr)(memBase + f + 0x3C), buf4, 4, out got))
                    {
                        uint c = BitConverter.ToUInt32(buf4, 0);
                        if (c >= 0x1000) stack.Push(new KeyValuePair<uint, int>(c, depth + 1));
                    }
                    if (ReadProcessMemory(h, (IntPtr)(memBase + f + 0x34), buf4, 4, out got))
                    {
                        uint s = BitConverter.ToUInt32(buf4, 0);
                        if (s >= 0x1000) stack.Push(new KeyValuePair<uint, int>(s, depth));
                    }
                }
            }
            finally { /* handle is cached in Handle(); Release() closes it */ }
            return res;
        }

        // ---- the per-frame path: ONE read per node, and the posing done here ------
        //
        // Walk() above makes seven process reads per node and hands back objects that the
        // script then loops over to build a name table and pose each part -- about 2.8 ms
        // for a room with two characters, which was affordable at ten walks a second and is
        // not at one walk per frame. And ten a second is what a character animated at:
        // the world streamed past at 130 fps while the creatures in it stepped at 10, which
        // is why they read as less crisp than the room around them.
        //
        // Everything a walk needs sits inside the first 0x26C bytes of the frame, so it is
        // read in one call. Names never change for the life of a frame, so the string behind
        // a name pointer is read once and remembered.
        static readonly Dictionary<uint, string> _nameCache = new Dictionary<uint, string>();
        // name -> guest address of the frame, from the most recent walk. For diagnostics that
        // want to look at one object's own fields (its velocity and rotation flags, say).
        public static readonly Dictionary<string, uint> FramePtr = new Dictionary<string, uint>();
        // Every observed step of every moving part, while StepLogOn: { ms, yaw in degrees,
        // x, y, z }. A count and a duration could not tell a door that swings over three
        // seconds from one that snaps open in a tenth of a second and snaps shut three
        // seconds later; the individual steps can.
        public static bool StepLogOn = false;
        public static readonly Dictionary<string, List<double[]>> StepLog = new Dictionary<string, List<double[]>>();
        static int _nameCachePid = 0;
        // THE NAME CACHE MUST NOT OUTLIVE THE STRINGS IT REMEMBERS. It maps the ADDRESS of a
        // name to the name, on the reasoning that "a frame's name never changes". True -- but
        // frames do not live for ever. Every room change frees the old room's frames and their
        // name strings, and the next room's names are allocated out of the same heap, often at
        // the very same addresses. The cache then answered with the PREVIOUS room's name for a
        // new frame: parts could not be found (not drawn) or were found under another object's
        // name (drawn with its matrix), and a creature that had gone still "had" four bones.
        // It got worse with every room change and showed most on returning somewhere, which is
        // exactly how it was reported: 53 of CHAMBNEW's parts hidden on the second visit, with
        // the game's own scene complete. Room DETECTION never used the cache (WalkBlocks reads
        // every name), which is why the right room was always loaded and then drawn wrongly.
        //
        // So the cache is thrown away four times a second. Re-reading ~150 short strings that
        // often is nothing; a wrong name can now survive a quarter of a second at most.
        static readonly System.Diagnostics.Stopwatch _nameAge = System.Diagnostics.Stopwatch.StartNew();
        public static void ForgetNames() { _nameCache.Clear(); _nameAge.Restart(); }
        static void AgeNames(int pid)
        {
            if (_nameCachePid != pid || _nameAge.ElapsedMilliseconds > 250) { _nameCache.Clear(); _nameCachePid = pid; _nameAge.Restart(); }
        }

        // name -> world matrix for every named frame. An instanced object is registered under
        // its full name (ZZ0001EUBUM) AND, if nothing has claimed it yet, under the bare name,
        // because the room's own .XAF knows its instanced objects without the prefix.
        //
        // THE WORLD MATRIX IS COMPOSED HERE, NOT READ. frame+0x90 is a CACHE that the engine
        // refreshes lazily -- when it is about to draw a frame, or when something asks for
        // it -- and under the host renderer the engine no longer draws. Animation keeps
        // writing each bone's LOCAL matrix (+0x4C) and setting its dirty flag, and the cached
        // world simply stops following. Measured live on a dead Raptor: its root bone's
        // local translation was (7.1, -18.7, -5.6) while its cached world still sat exactly
        // on its container, 18.7 units off, with the dirty flag set -- so the whole body
        // was drawn 18.7 units from where the engine put it the moment it drew for itself.
        // The cache is exact whenever it IS fresh (local x parent.world reproduced it to
        // four decimals on every consistent frame), so composing top-down from the locals
        // gives the same answer the engine would, without waiting for it to ask.
        // Row-vector convention: world = local * parentWorld.
        public static Dictionary<string, float[]> WalkLive(int pid, long memBase, uint rootFrame, int maxNodes)
        {
            var live = new Dictionary<string, float[]>(256);
            IntPtr h = Handle(pid);
            if (h == IntPtr.Zero) return live;
            AgeNames(pid);
            var buf = new byte[0x26C];
            var nameBuf = new byte[64];
            var seen = new HashSet<uint>();
            var stack = new Stack<KeyValuePair<uint, float[]>>();
            stack.Push(new KeyValuePair<uint, float[]>(rootFrame, null));
            int count = 0;
            IntPtr got;
            while (stack.Count > 0 && count < maxNodes)
            {
                var cur = stack.Pop();
                uint f = cur.Key; float[] parentWorld = cur.Value;
                if (f < 0x1000 || !seen.Add(f)) continue;
                if (!ReadProcessMemory(h, (IntPtr)(memBase + f), buf, buf.Length, out got)) continue;
                count++;

                var w = new float[16];
                // THE ROOT IS IDENTITY, not whatever sits at its +0x90. The top of the parent
                // chain is not a real frame (measured: its matrix rows are zero and its "world"
                // holds NaN), and the scene frame below it has an identity local, so the walk
                // starts from identity and everything real hangs correctly beneath.
                if (parentWorld == null) { w[0] = 1f; w[5] = 1f; w[10] = 1f; w[15] = 1f; }
                else
                {
                    var local = new float[16];
                    Buffer.BlockCopy(buf, 0x4C, local, 0, 64);
                    w = Mul(local, parentWorld);
                }

                uint np = BitConverter.ToUInt32(buf, 0x24);
                string name = null;
                if (np > 0x1000 && !_nameCache.TryGetValue(np, out name))
                {
                    name = "";
                    if (ReadProcessMemory(h, (IntPtr)(memBase + np), nameBuf, 64, out got))
                    {
                        int z = Array.IndexOf(nameBuf, (byte)0);
                        if (z > 0)
                        {
                            bool ok = true;
                            for (int i = 0; i < z; i++) if (nameBuf[i] < 0x20 || nameBuf[i] > 0x7E) { ok = false; break; }
                            if (ok) name = System.Text.Encoding.ASCII.GetString(nameBuf, 0, z);
                        }
                    }
                    // Remembered only once it reads as a name: a frame caught mid-construction
                    // must be allowed to get its real name on the next walk.
                    if (name.Length > 0) _nameCache[np] = name;
                }
                if (!string.IsNullOrEmpty(name))
                {
                    live[name] = w; FramePtr[name] = f;
                    if (name.Length > 6 && name[0] == 'Z' && name[1] == 'Z'
                        && char.IsDigit(name[2]) && char.IsDigit(name[3]) && char.IsDigit(name[4]) && char.IsDigit(name[5]))
                    {
                        string bare = name.Substring(6);
                        if (!live.ContainsKey(bare)) { live[bare] = w; FramePtr[bare] = f; }
                    }
                }
                // children hang off THIS frame's world; siblings share this frame's parent
                uint c = BitConverter.ToUInt32(buf, 0x3C); if (c >= 0x1000) stack.Push(new KeyValuePair<uint, float[]>(c, w));
                uint s = BitConverter.ToUInt32(buf, 0x34); if (s >= 0x1000) stack.Push(new KeyValuePair<uint, float[]>(s, parentWorld));
            }
            return live;
        }

        // ---- THE TREE ITSELF, for motion smoothing ---------------------------------
        //
        // WalkLive hands back finished world matrices, which is all that posing needs and
        // exactly what smoothing cannot use: a limb's world matrix is its own turn multiplied
        // through every joint above it, and blending two of THOSE swings the hand along a
        // straight line while the arm it hangs from turns through an arc -- joints open up
        // mid-step. Blending each joint's LOCAL matrix and composing afterwards keeps every
        // bone on the end of its parent, so the walk has to hand back the locals and who
        // each one's parent is. Same single read per node, same name cache.
        public class LiveTree
        {
            public int Count;
            public uint[] Frame;        // guest address: the identity of a node across walks
            public int[] Parent;        // index into these arrays, -1 for the top
            public string[] Name;       // "" when the frame has none
            public float[][] Local;     // 16 floats, row-vector
            public bool[] InChar;       // this frame is part of an instanced rig
        }

        public static LiveTree WalkTree(int pid, long memBase, uint rootFrame, int maxNodes)
        {
            IntPtr h = Handle(pid);
            if (h == IntPtr.Zero) return null;
            AgeNames(pid);
            var t = new LiveTree();
            t.Frame = new uint[maxNodes]; t.Parent = new int[maxNodes]; t.Name = new string[maxNodes];
            t.Local = new float[maxNodes][]; t.InChar = new bool[maxNodes];
            var buf = new byte[0x26C];
            var nameBuf = new byte[64];
            var seen = new HashSet<uint>();
            var stack = new Stack<KeyValuePair<uint, int>>();
            stack.Push(new KeyValuePair<uint, int>(rootFrame, -1));
            int n = 0;
            IntPtr got;
            while (stack.Count > 0 && n < maxNodes)
            {
                var cur = stack.Pop();
                uint f = cur.Key; int parent = cur.Value;
                if (f < 0x1000 || !seen.Add(f)) continue;
                if (!ReadProcessMemory(h, (IntPtr)(memBase + f), buf, buf.Length, out got)) continue;
                var local = new float[16];
                Buffer.BlockCopy(buf, 0x4C, local, 0, 64);

                uint np = BitConverter.ToUInt32(buf, 0x24);
                string name = null;
                if (np > 0x1000 && !_nameCache.TryGetValue(np, out name))
                {
                    name = "";
                    if (ReadProcessMemory(h, (IntPtr)(memBase + np), nameBuf, 64, out got))
                    {
                        int z = Array.IndexOf(nameBuf, (byte)0);
                        if (z > 0)
                        {
                            bool ok = true;
                            for (int i = 0; i < z; i++) if (nameBuf[i] < 0x20 || nameBuf[i] > 0x7E) { ok = false; break; }
                            if (ok) name = System.Text.Encoding.ASCII.GetString(nameBuf, 0, z);
                        }
                    }
                    if (name.Length > 0) _nameCache[np] = name;
                }
                if (name == null) name = "";

                // A RIG IS EVERYTHING UNDER ITS CONTAINER. The engine instances a character
                // beneath a frame it names "XAFQ%d" and prefixes every bone "ZZ%04d".
                bool inChar = parent >= 0 && t.InChar[parent];
                if (!inChar && name.Length > 4)
                {
                    if (name[0] == 'X' && name[1] == 'A' && name[2] == 'F' && name[3] == 'Q' && char.IsDigit(name[4])) inChar = true;
                    else if (name.Length > 6 && name[0] == 'Z' && name[1] == 'Z' && char.IsDigit(name[2]) && char.IsDigit(name[3])
                             && char.IsDigit(name[4]) && char.IsDigit(name[5])) inChar = true;
                }

                t.Frame[n] = f; t.Parent[n] = parent; t.Name[n] = name; t.Local[n] = local; t.InChar[n] = inChar;
                int me = n; n++;
                // children hang off THIS frame; siblings share this frame's parent
                uint c = BitConverter.ToUInt32(buf, 0x3C); if (c >= 0x1000) stack.Push(new KeyValuePair<uint, int>(c, me));
                uint s = BitConverter.ToUInt32(buf, 0x34); if (s >= 0x1000) stack.Push(new KeyValuePair<uint, int>(s, parent));
            }
            t.Count = n;
            return t;
        }

        // One moment of the scene, by the same rule as WalkLiveStable: walk twice, accept
        // only when both walks saw the same frames with bit-identical locals.
        public static LiveTree WalkTreeStable(int pid, long memBase, uint rootFrame, int maxNodes, int maxTries, out int tries)
        {
            tries = 0;
            var a = WalkTree(pid, memBase, rootFrame, maxNodes);
            if (a == null) return null;
            for (int t = 1; t <= maxTries; t++)
            {
                var b = WalkTree(pid, memBase, rootFrame, maxNodes);
                if (b == null) return null;
                if (SameTree(a, b)) { tries = t + 1; return b; }
                a = b;
            }
            return null;
        }

        static bool SameTree(LiveTree a, LiveTree b)
        {
            if (a.Count != b.Count || a.Count == 0) return false;
            for (int i = 0; i < a.Count; i++)
            {
                if (a.Frame[i] != b.Frame[i] || a.Parent[i] != b.Parent[i]) return false;
                float[] m = a.Local[i], o = b.Local[i];
                for (int k = 0; k < 16; k++) if (m[k] != o[k]) return false;
            }
            return true;
        }

        // DIAGNOSTIC WALK: all three matrix blocks of every named frame, not just the world
        // one. 51 floats per name: local (+0x4C), world (+0x90), the third block (+0xD4),
        // then the three bytes at +0x44..+0x46 (dirty flag and two motion flags). Used to
        // compare what the engine holds while WE draw against what it holds while IT draws.
        public static Dictionary<string, float[]> WalkBlocks(int pid, long memBase, uint rootFrame, int maxNodes)
        {
            var res = new Dictionary<string, float[]>(256);
            IntPtr h = Handle(pid);
            if (h == IntPtr.Zero) return res;
            var buf = new byte[0x26C];
            var nameBuf = new byte[64];
            var seen = new HashSet<uint>();
            var stack = new Stack<uint>();
            stack.Push(rootFrame);
            IntPtr got; int count = 0;
            while (stack.Count > 0 && count < maxNodes)
            {
                uint f = stack.Pop();
                if (f < 0x1000 || !seen.Add(f)) continue;
                if (!ReadProcessMemory(h, (IntPtr)(memBase + f), buf, buf.Length, out got)) continue;
                count++;
                uint np = BitConverter.ToUInt32(buf, 0x24);
                if (np > 0x1000 && ReadProcessMemory(h, (IntPtr)(memBase + np), nameBuf, 64, out got))
                {
                    int z = Array.IndexOf(nameBuf, (byte)0);
                    if (z > 0)
                    {
                        string name = System.Text.Encoding.ASCII.GetString(nameBuf, 0, z);
                        var v = new float[51];
                        Buffer.BlockCopy(buf, 0x4C, v, 0, 64);
                        Buffer.BlockCopy(buf, 0x90, v, 64, 64);
                        Buffer.BlockCopy(buf, 0xD4, v, 128, 64);
                        v[48] = buf[0x44]; v[49] = buf[0x45]; v[50] = buf[0x46];
                        if (!res.ContainsKey(name)) res[name] = v;
                    }
                }
                uint c = BitConverter.ToUInt32(buf, 0x3C); if (c >= 0x1000) stack.Push(c);
                uint s = BitConverter.ToUInt32(buf, 0x34); if (s >= 0x1000) stack.Push(s);
            }
            return res;
        }

        // DIAGNOSTIC: the ENGINE'S OWN mesh vertices for every named frame that has a mesh.
        // frame+0x268 is the visual count and +0x270 the Visual*[]; a Mesh keeps
        // {count, cap, ptr} for its vertices at +0x48 with a 48-byte stride, x,y,z first,
        // in the frame's local space (all from [[azrael-rl-object-model]]). Returned as
        // x,y,z triples so they can be laid beside the vertices the host loaded from the
        // .XAF: if the engine's loader moves or rescales a mesh, this is where it shows.
        public static Dictionary<string, float[]> WalkMeshVerts(int pid, long memBase, uint rootFrame, int maxNodes, int maxVerts)
        {
            var res = new Dictionary<string, float[]>(256);
            IntPtr h = Handle(pid);
            if (h == IntPtr.Zero) return res;
            var buf = new byte[0x2E0];
            var nameBuf = new byte[64];
            var b4 = new byte[4];
            var mesh = new byte[0x70];
            var seen = new HashSet<uint>();
            var stack = new Stack<uint>();
            stack.Push(rootFrame);
            IntPtr got; int count = 0;
            while (stack.Count > 0 && count < maxNodes)
            {
                uint f = stack.Pop();
                if (f < 0x1000 || !seen.Add(f)) continue;
                if (!ReadProcessMemory(h, (IntPtr)(memBase + f), buf, buf.Length, out got)) continue;
                count++;
                uint c = BitConverter.ToUInt32(buf, 0x3C); if (c >= 0x1000) stack.Push(c);
                uint s = BitConverter.ToUInt32(buf, 0x34); if (s >= 0x1000) stack.Push(s);

                uint np = BitConverter.ToUInt32(buf, 0x24);
                int nVis = BitConverter.ToInt32(buf, 0x268);
                uint visArr = BitConverter.ToUInt32(buf, 0x270);
                if (np <= 0x1000 || nVis < 1 || visArr < 0x1000) continue;
                if (!ReadProcessMemory(h, (IntPtr)(memBase + np), nameBuf, 64, out got)) continue;
                int z = Array.IndexOf(nameBuf, (byte)0);
                if (z <= 0) continue;
                string name = System.Text.Encoding.ASCII.GetString(nameBuf, 0, z);
                if (res.ContainsKey(name)) continue;
                if (!ReadProcessMemory(h, (IntPtr)(memBase + visArr), b4, 4, out got)) continue;
                uint m = BitConverter.ToUInt32(b4, 0);
                if (m < 0x1000 || !ReadProcessMemory(h, (IntPtr)(memBase + m), mesh, mesh.Length, out got)) continue;
                int nv = BitConverter.ToInt32(mesh, 0x48);
                uint vp = BitConverter.ToUInt32(mesh, 0x50);
                if (nv < 1 || nv > 20000 || vp < 0x1000) continue;
                int take = Math.Min(nv, maxVerts);
                var raw = new byte[take * 48];
                if (!ReadProcessMemory(h, (IntPtr)(memBase + vp), raw, raw.Length, out got)) continue;
                var v = new float[take * 3 + 1];
                v[0] = nv;                                   // the engine's full vertex count
                for (int i = 0; i < take; i++) Buffer.BlockCopy(raw, i * 48, v, (1 + i * 3) * 4, 12);
                res[name] = v;
            }
            return res;
        }

        // ONE WHOLE ENGINE FRAME OUT OF SEVERAL PARTIAL ONES. The engine clears its viewport
        // surface and then fills it triangle by triangle, taking most of a frame to do it,
        // so a copy taken at an arbitrary moment is nearly always part-drawn -- which is why
        // "wait until two copies are identical" failed on every single capture. For a still
        // view each pixel's FINISHED value is the same every frame, and what a part-drawn
        // copy shows instead is the clear colour (0) or something drawn behind. So take the
        // value each pixel shows most often across the copies, ignoring 0 unless it is all
        // there is. `unsettled` counts pixels where no non-zero value appeared twice: a few
        // is noise at an edge, many means something in view really was moving.
        public static byte[] SettledFrame(byte[][] reads, out int unsettled)
        {
            int n = reads.Length, len = reads[0].Length;
            var res = new byte[len];
            int bad = 0;
            var cnt = new int[256];
            for (int p = 0; p < len; p++)
            {
                byte best = 0; int bestN = 0;
                for (int i = 0; i < n; i++) cnt[reads[i][p]] = 0;
                for (int i = 0; i < n; i++)
                {
                    byte v = reads[i][p];
                    if (v == 0) continue;
                    int c = ++cnt[v];
                    if (c > bestN) { bestN = c; best = v; }
                }
                res[p] = best;
                if (bestN == 1) bad++;          // seen once only: not confirmed by any other copy
            }
            unsettled = bad;
            return res;
        }

        // A WALK THAT IS KNOWN TO BE ONE MOMENT. The guest keeps running while we read, and
        // each frame it re-derives every world matrix from the top of the tree down. A walk
        // that overlaps that pass gets a parent from the new frame and a child from the old
        // one -- on a character that is a limb drawn where its parent used to be: a polygon
        // stretching across the body, a texture that jumps, a creature left floating for a
        // frame. The old script walk took 5-8 ms against a guest frame of under 4, so it
        // straddled a frame boundary every single time.
        //
        // There is no lock to take, so do what a reader without one does: walk twice and
        // accept the result only if the two agree exactly. If the guest wrote anything in
        // between, they differ and we go again; after a few tries the caller keeps the pose
        // it already has, which is one frame stale and never torn. `tries` reports how many
        // walks it took (0 = gave up), so the log can say how often this bites.
        public static Dictionary<string, float[]> WalkLiveStable(int pid, long memBase, uint rootFrame, int maxNodes, int maxTries, out int tries)
        {
            tries = 0;
            var a = WalkLive(pid, memBase, rootFrame, maxNodes);
            for (int t = 1; t <= maxTries; t++)
            {
                var b = WalkLive(pid, memBase, rootFrame, maxNodes);
                if (SameWalk(a, b)) { tries = t + 1; return b; }
                a = b;
            }
            return null;
        }

        static bool SameWalk(Dictionary<string, float[]> a, Dictionary<string, float[]> b)
        {
            if (a.Count != b.Count || a.Count == 0) return false;
            foreach (var kv in a)
            {
                float[] o;
                if (!b.TryGetValue(kv.Key, out o)) return false;
                float[] m = kv.Value;
                for (int i = 0; i < 16; i++) if (m[i] != o[i]) return false;
            }
            return true;
        }

        // Pose every part from the live table. Same rules as the script's Update-Pose, which
        // this replaces: a part at rest is restored once, a moved part is re-posed from the
        // REST vertices (never from its own last pose, so error cannot accumulate), and a
        // part whose frame has gone is reported so the caller can stop drawing it.
        // Returns { moved, missing }; indices whose visibility flipped are appended to `changed`.
        // `last` / `steps` (optional): how many times each part's live matrix has CHANGED from
        // one call to the next. Set against the number of calls, that says whether a moving
        // thing steps every frame or only on the game's 18 Hz tick.
        public static int[] PoseAll(Dictionary<string, float[]> live, string[] names, int[] vFirst, int[] vCount,
                                    float[][] rest, float[][] invRest, float[] src, float[] dst,
                                    bool[] posed, bool[] vis, List<int> changed)
        {
            return PoseAll(live, names, vFirst, vCount, rest, invRest, src, dst, posed, vis, changed, null, null, null, null);
        }

        public static int[] PoseAll(Dictionary<string, float[]> live, string[] names, int[] vFirst, int[] vCount,
                                    float[][] rest, float[][] invRest, float[] src, float[] dst,
                                    bool[] posed, bool[] vis, List<int> changed, float[][] last, int[] steps)
        {
            return PoseAll(live, names, vFirst, vCount, rest, invRest, src, dst, posed, vis, changed, last, steps, null, null);
        }

        // `firstMs` / `lastMs`: when (host milliseconds, high resolution) each part's matrix
        // first and last changed since the caller reset them -- so a motion can be timed, not
        // just counted. A door that takes 20 steps in one second is on the tick; one that takes
        // them in 50 ms is being stepped every frame.
        public static int[] PoseAll(Dictionary<string, float[]> live, string[] names, int[] vFirst, int[] vCount,
                                    float[][] rest, float[][] invRest, float[] src, float[] dst,
                                    bool[] posed, bool[] vis, List<int> changed, float[][] last, int[] steps,
                                    double[] firstMs, double[] lastMs)
        {
            int moved = 0, missing = 0;
            for (int i = 0; i < names.Length; i++)
            {
                float[] m;
                bool here = live.TryGetValue(names[i], out m);
                if (here && last != null)
                {
                    float[] p = last[i];
                    if (p == null) last[i] = m;
                    else
                    {
                        bool diff = false;
                        for (int k = 0; k < 16; k++) if (Math.Abs(m[k] - p[k]) > 1e-5f) { diff = true; break; }
                        if (diff)
                        {
                            steps[i]++; last[i] = m;
                            if (firstMs != null)
                            {
                                double now = System.Diagnostics.Stopwatch.GetTimestamp() * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
                                if (firstMs[i] == 0) firstMs[i] = now;
                                lastMs[i] = now;
                                if (StepLogOn)
                                {
                                    List<double[]> sl;
                                    if (!StepLog.TryGetValue(names[i], out sl)) { sl = new List<double[]>(); StepLog[names[i]] = sl; }
                                    if (sl.Count < 400) sl.Add(new double[] { now, Math.Atan2(m[2], m[0]) * 180.0 / Math.PI, m[12], m[13], m[14] });
                                }
                            }
                        }
                    }
                }
                if (here)
                {
                    if (NearlyEqual(m, rest[i], 0.01f))
                    {
                        if (posed[i]) { Array.Copy(src, vFirst[i] * 3, dst, vFirst[i] * 3, vCount[i] * 3); posed[i] = false; }
                    }
                    else
                    {
                        PoseRange(src, dst, vFirst[i], vCount[i], Mul(invRest[i], m));
                        posed[i] = true;
                        moved++;
                    }
                }
                else missing++;
                if (here != vis[i]) { vis[i] = here; changed.Add(i); }
            }
            return new int[] { moved, missing };
        }

        // ---- re-posing ----------------------------------------------------------
        // The OBJ's vertices are POSED into the rest world. To move an object to where the
        // engine currently has it, apply  D = inverse(rest) * live  to those vertices:
        //
        //     v_live = v_restPosed * D = (v_local * rest) * (rest^-1 * live) = v_local * live
        //
        // Doing it this way means the exporter does not have to emit a second, unposed copy
        // of every room, and every existing consumer of the OBJ keeps working unchanged.
        //
        // Row-vector / row-major throughout, matching Reality Lab and the exporter: the
        // translation is row 3 (indices 12,13,14).

        // General affine inverse. NOT a transpose: these matrices can carry scale, and
        // assuming orthonormality would silently distort anything that does.
        public static float[] InvertAffine(float[] m)
        {
            double a = m[0], b = m[1], c = m[2];
            double d = m[4], e = m[5], f = m[6];
            double g = m[8], h = m[9], i = m[10];
            double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
            var r = new float[16];
            if (Math.Abs(det) < 1e-12)
            {
                // Singular (a collapsed or not-yet-populated frame). Identity leaves the
                // object at its rest pose, which is visibly wrong but never NaN.
                r[0] = r[5] = r[10] = r[15] = 1f;
                return r;
            }
            double id = 1.0 / det;
            double i00 = (e * i - f * h) * id, i01 = (c * h - b * i) * id, i02 = (b * f - c * e) * id;
            double i10 = (f * g - d * i) * id, i11 = (a * i - c * g) * id, i12 = (c * d - a * f) * id;
            double i20 = (d * h - e * g) * id, i21 = (b * g - a * h) * id, i22 = (a * e - b * d) * id;
            double tx = m[12], ty = m[13], tz = m[14];
            r[0] = (float)i00; r[1] = (float)i01; r[2] = (float)i02;
            r[4] = (float)i10; r[5] = (float)i11; r[6] = (float)i12;
            r[8] = (float)i20; r[9] = (float)i21; r[10] = (float)i22;
            r[12] = (float)(-(tx * i00 + ty * i10 + tz * i20));
            r[13] = (float)(-(tx * i01 + ty * i11 + tz * i21));
            r[14] = (float)(-(tx * i02 + ty * i12 + tz * i22));
            r[15] = 1f;
            return r;
        }

        public static float[] Mul(float[] A, float[] B)
        {
            var r = new float[16];
            for (int row = 0; row < 4; row++)
                for (int col = 0; col < 4; col++)
                {
                    double s = 0;
                    for (int k = 0; k < 4; k++) s += A[row * 4 + k] * B[k * 4 + col];
                    r[row * 4 + col] = (float)s;
                }
            return r;
        }

        // Transform one object's vertex range from src into dst by d.
        public static void PoseRange(float[] src, float[] dst, int vFirst, int vCount, float[] d)
        {
            int end = vFirst + vCount;
            for (int v = vFirst; v < end; v++)
            {
                int o = v * 3;
                float x = src[o], y = src[o + 1], z = src[o + 2];
                dst[o]     = x * d[0] + y * d[4] + z * d[8]  + d[12];
                dst[o + 1] = x * d[1] + y * d[5] + z * d[9]  + d[13];
                dst[o + 2] = x * d[2] + y * d[6] + z * d[10] + d[14];
            }
        }

        // Is this matrix close enough to the rest pose that re-posing would be a no-op?
        // Comparing first avoids transforming every static wall in the room every frame.
        public static bool NearlyEqual(float[] a, float[] b, float eps)
        {
            for (int i = 0; i < 16; i++) if (Math.Abs(a[i] - b[i]) > eps) return false;
            return true;
        }

        // ---- quaternion helpers for Smoother ------------------------------------
        // Whatever convention these use, they use it both ways, which is all a blend needs.
        internal static void MatToQuat(double[] r, double[] q)
        {
            double m00 = r[0], m01 = r[1], m02 = r[2], m10 = r[3], m11 = r[4], m12 = r[5], m20 = r[6], m21 = r[7], m22 = r[8];
            double tr = m00 + m11 + m22, x, y, z, w;
            if (tr > 0) { double s = Math.Sqrt(tr + 1.0) * 2; w = 0.25 * s; x = (m21 - m12) / s; y = (m02 - m20) / s; z = (m10 - m01) / s; }
            else if (m00 > m11 && m00 > m22) { double s = Math.Sqrt(1.0 + m00 - m11 - m22) * 2; w = (m21 - m12) / s; x = 0.25 * s; y = (m01 + m10) / s; z = (m02 + m20) / s; }
            else if (m11 > m22) { double s = Math.Sqrt(1.0 + m11 - m00 - m22) * 2; w = (m02 - m20) / s; x = (m01 + m10) / s; y = 0.25 * s; z = (m12 + m21) / s; }
            else { double s = Math.Sqrt(1.0 + m22 - m00 - m11) * 2; w = (m10 - m01) / s; x = (m02 + m20) / s; y = (m12 + m21) / s; z = 0.25 * s; }
            double l = Math.Sqrt(x * x + y * y + z * z + w * w);
            if (l < 1e-12) { q[0] = 0; q[1] = 0; q[2] = 0; q[3] = 1; return; }
            q[0] = x / l; q[1] = y / l; q[2] = z / l; q[3] = w / l;
        }
        internal static void QuatToMat(double x, double y, double z, double w, double[] r)
        {
            r[0] = 1 - 2 * (y * y + z * z); r[1] = 2 * (x * y - z * w);     r[2] = 2 * (x * z + y * w);
            r[3] = 2 * (x * y + z * w);     r[4] = 1 - 2 * (x * x + z * z); r[5] = 2 * (y * z - x * w);
            r[6] = 2 * (x * z - y * w);     r[7] = 2 * (y * z + x * w);     r[8] = 1 - 2 * (x * x + y * y);
        }

        // Climb to the root from any frame (the camera's is the one we always have).
        public static uint RootOf(int pid, long memBase, uint frame)
        {
            IntPtr h = Handle(pid);
            if (h == IntPtr.Zero) return frame;
            try
            {
                var buf4 = new byte[4];
                uint p = frame;
                for (int i = 0; i < 32; i++)
                {
                    IntPtr got;
                    if (!ReadProcessMemory(h, (IntPtr)(memBase + p + 0x30), buf4, 4, out got)) break;
                    uint par = BitConverter.ToUInt32(buf4, 0);
                    if (par < 0x1000) break;
                    p = par;
                }
                return p;
            }
            finally { /* handle is cached in Handle(); Release() closes it */ }
        }
    }

    // ---- MOTION SMOOTHING ---------------------------------------------------------
    //
    // The game animates on its 18.2 Hz clock tick: a creature's bones, and its walk across
    // the floor, change eighteen times a second and hold still in between. Drawn at 130
    // frames a second that is seven identical pictures of the creature, then a jump -- while
    // the room around it glides, because the camera is read fresh for every frame.
    //
    // So each joint is not drawn where the game last put it, but on its way there: when a
    // new pose arrives, the joint starts moving from wherever it is being DRAWN now toward
    // the new pose, and takes one tick to arrive -- by which time the next pose is due. The
    // price is that a creature is shown one tick (55 ms) behind the game's own idea of it;
    // nothing is predicted, so nothing can overshoot or be drawn somewhere it never was.
    //
    // What is blended is each joint's LOCAL matrix, as rotation / scale / position, and the
    // world matrices are composed from the blended locals afterwards. That is what keeps a
    // limb attached to its parent in between poses (see SceneGraph.LiveTree).
    //
    // NOT EVERYTHING IS SMOOTHED, on purpose:
    //   * A frame that changes on every sample is not on the tick (the player, anything
    //     riding on the player) and is passed straight through; delaying it buys nothing.
    //   * A jump too big to be one step of an animation is a teleport and is not slid.
    //   * Room objects are smoothed only when they TURN in place (a door on its hinge).
    //     One that travels may be carrying the player -- a lift -- and the camera is not
    //     delayed, so a smoothed lift would shudder against the unsmoothed view from it.
    //     Rigs are always smoothed: nothing rides a creature. `All` overrides this.
    public class Smoother
    {
        class Pose
        {
            public float[] M;                 // the matrix as read
            public double[] S = new double[3], Q = new double[4];
            public bool Rigid;                // decomposed cleanly (no mirror, no collapsed axis)
        }
        class St
        {
            public Pose From, To;
            public double T0, Dur, LastChange;
        }

        readonly Dictionary<uint, St> _st = new Dictionary<uint, St>();
        SceneGraph.LiveTree _tree;
        float[][] _world = new float[0][];
        public double TickMs = 1000.0 / 18.2065;
        public bool All = false;
        public long Blended, Snapped;         // steps eased / steps passed straight through

        public void Reset() { _st.Clear(); _tree = null; }
        public bool HasTree { get { return _tree != null && _tree.Count > 0; } }
        public string[] Names()
        {
            if (_tree == null) return new string[0];
            var r = new string[_tree.Count]; Array.Copy(_tree.Name, r, _tree.Count); return r;
        }

        static Pose Decompose(float[] m)
        {
            var p = new Pose(); p.M = m;
            double[] r = new double[9];
            bool ok = true;
            for (int i = 0; i < 3; i++)
            {
                double x = m[i * 4], y = m[i * 4 + 1], z = m[i * 4 + 2];
                double l = Math.Sqrt(x * x + y * y + z * z);
                p.S[i] = l;
                if (l < 1e-6) { ok = false; break; }
                r[i * 3] = x / l; r[i * 3 + 1] = y / l; r[i * 3 + 2] = z / l;
            }
            if (ok)
            {
                double det = r[0] * (r[4] * r[8] - r[5] * r[7]) - r[1] * (r[3] * r[8] - r[5] * r[6]) + r[2] * (r[3] * r[7] - r[4] * r[6]);
                // a pure rotation has determinant 1; a mirror or a sheared basis does not
                if (det < 0.98 || det > 1.02) ok = false;
            }
            if (ok) SceneGraph.MatToQuat(r, p.Q);
            p.Rigid = ok;
            return p;
        }

        static bool Same(float[] a, float[] b)
        {
            for (int i = 0; i < 16; i++) if (Math.Abs(a[i] - b[i]) > 1e-6f) return false;
            return true;
        }

        static float[] Blend(Pose a, Pose b, double t)
        {
            var m = new float[16];
            if (!a.Rigid || !b.Rigid)
            {
                for (int i = 0; i < 16; i++) m[i] = (float)(a.M[i] + (b.M[i] - a.M[i]) * t);
                return m;
            }
            double ax = a.Q[0], ay = a.Q[1], az = a.Q[2], aw = a.Q[3];
            double bx = b.Q[0], by = b.Q[1], bz = b.Q[2], bw = b.Q[3];
            double dot = ax * bx + ay * by + az * bz + aw * bw;
            if (dot < 0) { bx = -bx; by = -by; bz = -bz; bw = -bw; dot = -dot; }   // the short way round
            double wa, wb;
            if (dot > 0.9995) { wa = 1 - t; wb = t; }
            else
            {
                double th = Math.Acos(dot), sn = Math.Sin(th);
                wa = Math.Sin((1 - t) * th) / sn; wb = Math.Sin(t * th) / sn;
            }
            double x = ax * wa + bx * wb, y = ay * wa + by * wb, z = az * wa + bz * wb, w = aw * wa + bw * wb;
            double l = Math.Sqrt(x * x + y * y + z * z + w * w);
            x /= l; y /= l; z /= l; w /= l;
            double[] r = new double[9];
            SceneGraph.QuatToMat(x, y, z, w, r);
            for (int i = 0; i < 3; i++)
            {
                double s = a.S[i] + (b.S[i] - a.S[i]) * t;
                m[i * 4] = (float)(r[i * 3] * s); m[i * 4 + 1] = (float)(r[i * 3 + 1] * s); m[i * 4 + 2] = (float)(r[i * 3 + 2] * s);
                m[i * 4 + 3] = (float)(a.M[i * 4 + 3] + (b.M[i * 4 + 3] - a.M[i * 4 + 3]) * t);
            }
            for (int i = 12; i < 16; i++) m[i] = (float)(a.M[i] + (b.M[i] - a.M[i]) * t);
            return m;
        }

        static float[] Current(St s, double nowMs)
        {
            if (s.Dur <= 0) return s.To.M;
            double t = (nowMs - s.T0) / s.Dur;
            if (t >= 1) return s.To.M;
            if (t <= 0) return s.From.M;
            return Blend(s.From, s.To, t);
        }

        // A new, confirmed walk of the scene. Call whenever one is available.
        public void Sample(SceneGraph.LiveTree t, double nowMs)
        {
            if (t == null || t.Count == 0) return;
            for (int i = 0; i < t.Count; i++)
            {
                St s;
                float[] m = t.Local[i];
                if (!_st.TryGetValue(t.Frame[i], out s))
                {
                    s = new St(); s.From = s.To = Decompose(m); s.LastChange = nowMs - 1e6;
                    _st[t.Frame[i]] = s;
                    continue;
                }
                if (Same(m, s.To.M)) continue;

                double since = nowMs - s.LastChange;
                s.LastChange = nowMs;
                Pose np = Decompose(m);
                bool ease = since >= 30.0;                    // faster than that is not the tick
                if (ease && !All && !t.InChar[i])
                {
                    // a room object: only when it turns in place
                    double dx = m[12] - s.To.M[12], dy = m[13] - s.To.M[13], dz = m[14] - s.To.M[14];
                    if (dx * dx + dy * dy + dz * dz > 1e-4) ease = false;
                }
                if (ease)
                {
                    // one step of an animation, or a teleport?
                    double dx = m[12] - s.To.M[12], dy = m[13] - s.To.M[13], dz = m[14] - s.To.M[14];
                    if (dx * dx + dy * dy + dz * dz > 150.0 * 150.0) ease = false;
                    else if (np.Rigid && s.To.Rigid)
                    {
                        double dot = Math.Abs(np.Q[0] * s.To.Q[0] + np.Q[1] * s.To.Q[1] + np.Q[2] * s.To.Q[2] + np.Q[3] * s.To.Q[3]);
                        if (dot < 0.5) ease = false;          // more than 120 degrees in one step
                    }
                }
                if (!ease) { s.From = s.To = np; s.Dur = 0; Snapped++; continue; }

                // FROM WHERE IT IS DRAWN NOW, not from the previous pose: if the last step had
                // not finished arriving, starting from its end would be a jump of its own.
                float[] cur = Current(s, nowMs);
                s.From = ReferenceEquals(cur, s.To.M) ? s.To : Decompose(cur);
                s.To = np;
                s.T0 = nowMs;
                // One tick, or the measured gap when the game is stepping steadily at some
                // other rate. A first step after a rest has no gap to measure: one tick.
                s.Dur = (since > 40.0 && since < 80.0) ? since : TickMs;
                Blended++;
            }
            _tree = t;
            if (_st.Count > t.Count * 4 + 64)
            {
                // frames come and go with rooms and creatures; do not keep them for ever
                var live = new HashSet<uint>();
                for (int i = 0; i < t.Count; i++) live.Add(t.Frame[i]);
                var dead = new List<uint>();
                foreach (var k in _st.Keys) if (!live.Contains(k)) dead.Add(k);
                foreach (var k in dead) _st.Remove(k);
            }
        }

        // name -> world matrix as of `nowMs`, in the shape SceneGraph.WalkLive returns (and
        // by its rules: the top of the tree is identity, an instanced bone is also registered
        // under its bare name if nothing else has claimed it). Call once per rendered frame.
        public Dictionary<string, float[]> Evaluate(double nowMs)
        {
            var live = new Dictionary<string, float[]>(256);
            var t = _tree;
            if (t == null) return live;
            if (_world.Length < t.Count) _world = new float[t.Count][];
            for (int i = 0; i < t.Count; i++)
            {
                float[] w;
                int p = t.Parent[i];
                if (p < 0) { w = new float[16]; w[0] = 1f; w[5] = 1f; w[10] = 1f; w[15] = 1f; }
                else
                {
                    St s; float[] local = _st.TryGetValue(t.Frame[i], out s) ? Current(s, nowMs) : t.Local[i];
                    w = SceneGraph.Mul(local, _world[p]);
                }
                _world[i] = w;
                string name = t.Name[i];
                if (name.Length == 0) continue;
                live[name] = w; SceneGraph.FramePtr[name] = t.Frame[i];
                if (name.Length > 6 && name[0] == 'Z' && name[1] == 'Z'
                    && char.IsDigit(name[2]) && char.IsDigit(name[3]) && char.IsDigit(name[4]) && char.IsDigit(name[5]))
                {
                    string bare = name.Substring(6);
                    if (!live.ContainsKey(bare)) { live[bare] = w; SceneGraph.FramePtr[bare] = t.Frame[i]; }
                }
            }
            return live;
        }
    }
}
