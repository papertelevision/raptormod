// RoomUnit.cs -- one .XAF's worth of ready-to-draw geometry, and the fast way to combine them.
//
// WHY THIS EXISTS. Entering a room paused the picture for one to three seconds, and twice
// when a character was present. All of it was Import-AztRoom re-doing, in script, work whose
// answer never changes: parsing the OBJ text line by line, resolving UVs through the faces,
// quantising every texture into the palette, then walking every triangle to assign textures
// and parts. A room plus two creatures did that three times over -- and did the whole room
// again when a creature arrived.
//
// A UNIT is the finished product for ONE file: vertices, UVs, triangles, a texture index per
// triangle, the parts table, and the textures already reduced to palette indices. It is
// built once by the old script path, written to disk, and after that read back in a few
// milliseconds. A ROOM is then just units laid end to end with their indices rebased, which
// is array copying and is done here rather than in script.
//
// Deliberately self-contained: textures are plain byte arrays, not Raster.Tex, so this file
// compiles on its own and LoadRoom.ps1 can add it without knowing which other AztTool
// sources the caller happened to compile.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace AztRoom
{
    public class RoomUnit
    {
        public const int FormatVersion = 1;

        public float[] V, UV;                 // 3 and 2 floats per vertex
        public int[] T;                       // 3 vertex indices per triangle
        public int[] TexIdx;                  // per triangle: index into the texture list, -1 = not drawn
        public int[] TriPart;                 // per triangle: index into the parts table, -1 = none
        public string[] PartName;
        public int[] PartVFirst, PartVCount;
        public float[] PartRest;              // 16 floats per part, row-major
        public int[] TexW, TexH;
        public byte[][] TexData;              // palette indices, TexW*TexH each
        public int Textured, Flat, Skipped, Solid;
        public byte FlatInk;
        // NOT SAVED: worked out by MeshSmooth when a unit is smoothed in memory. For every
        // triangle corner, which smoothing fan it belongs to (-1 = none: shade it flat).
        public int[] CornerGroup; public int GroupCount;

        // `stamp` identifies everything the unit was built FROM (exporter version, the OBJ's
        // own timestamp, the palette's hash, the loader's rules). A cache written under a
        // different stamp is ignored rather than trusted: a stale unit would silently keep
        // whatever an older loader got wrong, which is the failure the OBJ cache already had
        // once before it grew a version line.
        public void Save(string path, string stamp)
        {
            string tmp = path + ".tmp";
            using (var w = new BinaryWriter(File.Create(tmp), Encoding.UTF8))
            {
                w.Write(0x554E5441);          // 'ATNU'
                w.Write(FormatVersion);
                w.Write(stamp);
                WriteF(w, V); WriteF(w, UV); WriteI(w, T); WriteI(w, TexIdx); WriteI(w, TriPart);
                w.Write(PartName.Length);
                foreach (var s in PartName) w.Write(s ?? "");
                WriteI(w, PartVFirst); WriteI(w, PartVCount); WriteF(w, PartRest);
                WriteI(w, TexW); WriteI(w, TexH);
                w.Write(TexData.Length);
                foreach (var d in TexData) { w.Write(d.Length); w.Write(d); }
                w.Write(Textured); w.Write(Flat); w.Write(Skipped); w.Write(Solid); w.Write(FlatInk);
            }
            if (File.Exists(path)) File.Delete(path);
            File.Move(tmp, path);
        }

        public static RoomUnit Load(string path, string stamp)
        {
            if (!File.Exists(path)) return null;
            try
            {
                using (var r = new BinaryReader(File.OpenRead(path), Encoding.UTF8))
                {
                    if (r.ReadInt32() != 0x554E5441) return null;
                    if (r.ReadInt32() != FormatVersion) return null;
                    if (r.ReadString() != stamp) return null;
                    var u = new RoomUnit();
                    u.V = ReadF(r); u.UV = ReadF(r); u.T = ReadI(r); u.TexIdx = ReadI(r); u.TriPart = ReadI(r);
                    int np = r.ReadInt32();
                    u.PartName = new string[np];
                    for (int i = 0; i < np; i++) u.PartName[i] = r.ReadString();
                    u.PartVFirst = ReadI(r); u.PartVCount = ReadI(r); u.PartRest = ReadF(r);
                    u.TexW = ReadI(r); u.TexH = ReadI(r);
                    int nt = r.ReadInt32();
                    u.TexData = new byte[nt][];
                    for (int i = 0; i < nt; i++) { int n = r.ReadInt32(); u.TexData[i] = r.ReadBytes(n); }
                    u.Textured = r.ReadInt32(); u.Flat = r.ReadInt32(); u.Skipped = r.ReadInt32(); u.Solid = r.ReadInt32();
                    u.FlatInk = r.ReadByte();
                    return u;
                }
            }
            catch (Exception) { return null; }     // truncated or foreign file: rebuild it
        }

        static void WriteF(BinaryWriter w, float[] a)
        {
            w.Write(a.Length);
            var b = new byte[a.Length * 4]; Buffer.BlockCopy(a, 0, b, 0, b.Length); w.Write(b);
        }
        static void WriteI(BinaryWriter w, int[] a)
        {
            w.Write(a.Length);
            var b = new byte[a.Length * 4]; Buffer.BlockCopy(a, 0, b, 0, b.Length); w.Write(b);
        }
        static float[] ReadF(BinaryReader r)
        {
            int n = r.ReadInt32(); var a = new float[n];
            var b = r.ReadBytes(n * 4); Buffer.BlockCopy(b, 0, a, 0, b.Length); return a;
        }
        static int[] ReadI(BinaryReader r)
        {
            int n = r.ReadInt32(); var a = new int[n];
            var b = r.ReadBytes(n * 4); Buffer.BlockCopy(b, 0, a, 0, b.Length); return a;
        }
    }

    // Units laid end to end. Everything that was an index into a unit's own arrays is rebased
    // onto the combined ones; nothing else changes.
    public class Composed
    {
        public float[] V, UV;
        public int[] T, TexIdx, TriPart, PartOf;
        public string[] PartName;
        public int[] PartVFirst, PartVCount, PartEntry;   // PartEntry: which input entry a part came from
        public float[][] PartRest;
        public int[] TexSlot, TexLocal;                   // combined texture i = texture TexLocal[i] of distinct unit TexSlot[i]
        public int Textured, Flat, Skipped, Solid;
        public float Span;
        // per triangle corner: its smoothing fan, numbered across the whole composition (each
        // copy of a unit has its own, because each copy is posed on its own); null if no unit had any
        public int[] CornerGroup; public int GroupCount;

        // `units[i]` drawn with part names prefixed by `prefixes[i]`. The SAME unit object may
        // appear more than once (two creatures of one kind): its geometry is copied per
        // appearance, because each copy is posed separately, but its textures are listed once.
        public static Composed Build(RoomUnit[] units, string[] prefixes)
        {
            int nv = 0, nt = 0, np = 0;
            foreach (var u in units) { nv += u.V.Length / 3; nt += u.T.Length / 3; np += u.PartName.Length; }
            var c = new Composed();
            c.V = new float[nv * 3]; c.UV = new float[nv * 2];
            c.T = new int[nt * 3]; c.TexIdx = new int[nt]; c.TriPart = new int[nt];
            c.PartOf = new int[nv];
            c.PartName = new string[np]; c.PartVFirst = new int[np]; c.PartVCount = new int[np];
            c.PartEntry = new int[np]; c.PartRest = new float[np][];

            var texBase = new Dictionary<RoomUnit, int>();
            var slot = new List<int>(); var local = new List<int>();
            var distinct = new List<RoomUnit>();
            foreach (var u in units)
            {
                if (texBase.ContainsKey(u)) continue;
                texBase[u] = slot.Count;
                int s = distinct.Count; distinct.Add(u);
                for (int i = 0; i < u.TexData.Length; i++) { slot.Add(s); local.Add(i); }
            }
            c.TexSlot = slot.ToArray(); c.TexLocal = local.ToArray();

            bool anyGroups = false; foreach (var u in units) if (u.CornerGroup != null) anyGroups = true;
            if (anyGroups) { c.CornerGroup = new int[nt * 3]; for (int i = 0; i < c.CornerGroup.Length; i++) c.CornerGroup[i] = -1; }
            int vB = 0, tB = 0, pB = 0, gB = 0;
            for (int e = 0; e < units.Length; e++)
            {
                var u = units[e];
                int uv = u.V.Length / 3, ut = u.T.Length / 3, up = u.PartName.Length, tb = texBase[u];
                if (u.CornerGroup != null)
                {
                    for (int i = 0; i < u.CornerGroup.Length; i++) c.CornerGroup[tB * 3 + i] = u.CornerGroup[i] < 0 ? -1 : u.CornerGroup[i] + gB;
                    gB += u.GroupCount; c.GroupCount = gB;
                }
                Buffer.BlockCopy(u.V, 0, c.V, vB * 12, u.V.Length * 4);
                Buffer.BlockCopy(u.UV, 0, c.UV, vB * 8, u.UV.Length * 4);
                for (int i = 0; i < u.T.Length; i++) c.T[tB * 3 + i] = u.T[i] + vB;
                for (int i = 0; i < ut; i++)
                {
                    c.TexIdx[tB + i] = u.TexIdx[i] < 0 ? -1 : u.TexIdx[i] + tb;
                    c.TriPart[tB + i] = u.TriPart[i] < 0 ? -1 : u.TriPart[i] + pB;
                }
                for (int i = 0; i < uv; i++) c.PartOf[vB + i] = -1;
                string pre = prefixes[e] ?? "";
                for (int i = 0; i < up; i++)
                {
                    c.PartName[pB + i] = pre + u.PartName[i];
                    c.PartVFirst[pB + i] = u.PartVFirst[i] + vB;
                    c.PartVCount[pB + i] = u.PartVCount[i];
                    c.PartEntry[pB + i] = e;
                    var r = new float[16]; Array.Copy(u.PartRest, i * 16, r, 0, 16); c.PartRest[pB + i] = r;
                    int end = Math.Min(u.PartVFirst[i] + u.PartVCount[i], uv);
                    for (int k = Math.Max(0, u.PartVFirst[i]); k < end; k++) c.PartOf[vB + k] = pB + i;
                }
                c.Textured += u.Textured; c.Flat += u.Flat; c.Skipped += u.Skipped; c.Solid += u.Solid;
                vB += uv; tB += ut; pB += up;
            }

            float lx = float.MaxValue, ly = float.MaxValue, lz = float.MaxValue;
            float hx = float.MinValue, hy = float.MinValue, hz = float.MinValue;
            for (int i = 0; i < c.V.Length; i += 3)
            {
                float x = c.V[i], y = c.V[i + 1], z = c.V[i + 2];
                if (x < lx) lx = x; if (x > hx) hx = x;
                if (y < ly) ly = y; if (y > hy) hy = y;
                if (z < lz) lz = z; if (z > hz) hz = z;
            }
            float span = Math.Max(hx - lx, Math.Max(hy - ly, hz - lz));
            c.Span = (c.V.Length == 0 || span <= 0) ? 1000f : span;
            return c;
        }
    }
}
