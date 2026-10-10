// AzfTool.cs -- read and write Azrael's .RES texture bundles.
//
// A .RES is a flat run of .azf records, no names and no index; entries match the
// room's .XAF textures by FIRST-APPEARANCE order (not alphabetical -- getting
// that wrong silently mislabels every texture in the room).
//
//   dword payloadLength            bytes after this dword
//   D3DRMIMAGE, 60 bytes           width, height, aspectx, aspecty, depth, rgb,
//                                  bytes_per_line, buffer1, buffer2,
//                                  r/g/b/a masks, palette_size, palette*
//   palette   palette_size * 4     (r, g, b, flags)
//   pixels                         Huffman stream, below
//
// THE CODEC (0x2D558, reached through the cdecl thunk 0x2D54D):
//
//   dword  uncompressedSize
//   dword  rootNode                256..511
//   uint16 tree[1024]              2048 bytes
//   bits                           little-endian dwords, LSB first
//
//   node = rootNode
//   while node >= 0x100:           # 256+ is internal
//       node = tree[node*2 + bit]
//   emit (byte)node                # <256 is the literal, and IS its own index
//
// Leaves are the byte values themselves, so internal nodes must live in
// 256..511 -- only table entries 512..1023 are ever read. A 256-symbol Huffman
// tree needs 255 internal nodes, which fits exactly.
//
// REFILL ORDER MATTERS. The decoder does `dec cx` BEFORE the table read and
// refills the moment cx hits zero -- even when the next step would exit to a
// leaf. So the stream must always have another dword readable past the last
// bit actually used; the writer pads for that rather than sizing exactly.
using System;
using System.Collections.Generic;
using System.IO;

namespace AztTool
{
    public class AzfTexture
    {
        public int Width, Height, BytesPerLine;
        public int AspectX = 1, AspectY = 1, Depth = 8, Rgb = 0;
        public uint RedMask = 255, GreenMask = 255, BlueMask = 255, AlphaMask = 0;
        public byte[] Palette;     // palette_size * 4, (r,g,b,flags)
        public byte[] Pixels;      // BytesPerLine * Height -- null if Decoded is false
        public int PaletteSize { get { return Palette.Length / 4; } }

        // The record exactly as it sat in the file, length dword included. Kept so a
        // record can be written back untouched -- see Write.
        public byte[] Raw;

        // False when the Huffman stream would not decode. At least one record in
        // CORICORI.RES and R1.RES is like this: the LAST record in the file, whose
        // stream runs short of the padding the decoder's refill-before-leaf order
        // demands. The game never trips over it, so it is a packing artefact rather
        // than corruption -- but it must not take the whole bundle down with it.
        public bool Decoded;

        // Set by a caller that has actually changed Width/Height/Palette/Pixels.
        // Write re-encodes ONLY these; everything else is copied through verbatim, so
        // importing two textures changes two records and leaves the other nineteen
        // bit-for-bit identical to the original file.
        public bool Dirty;
    }

    public static class Azf
    {
        // ---- decode ---------------------------------------------------------
        // The refill-before-leaf order described above means the stream must always have
        // one more dword readable past the last bit actually used. Every record gets that
        // for free from the record that follows it -- except the LAST record in the file,
        // where the file simply ends. Reading it with BitConverter threw, and the catch in
        // Read turned that into Decoded=false, so the final texture of 7 rooms was lost:
        // CORICORI's spadoor (both doors in the opening room), CHAPEL, R1, SPACORI, THEO,
        // THEONEW, IKTEST -- and in every one of the 7 it was the last record, which is
        // what gives the boundary away. The game is unbothered because under DOS the four
        // bytes past the buffer are just slack heap.
        //
        // Those bits are never consumed: the loop is driven by outLen and the final leaf
        // is already reachable from the bits in hand. So zero-filling past the end is
        // bit-exact for the real output, not an approximation.
        static uint Dword(byte[] b, int p)
        {
            uint v = 0;
            for (int i = 3; i >= 0; i--) v = (v << 8) | (p + i < b.Length ? b[p + i] : 0u);
            return v;
        }

        public static byte[] Inflate(byte[] b, int off)
        {
            int outLen = BitConverter.ToInt32(b, off);
            int root   = BitConverter.ToInt32(b, off + 4);
            int tree   = off + 8;
            int p      = tree + 0x800;

            var o = new byte[outLen];
            uint buf = Dword(b, p); p += 4;
            int cx = 32;
            for (int i = 0; i < outLen; i++)
            {
                int node = root;
                while (node >= 0x100)
                {
                    uint bit = buf & 1; buf >>= 1; cx--;
                    node = BitConverter.ToUInt16(b, tree + ((node * 2 + (int)bit) * 2));
                    if (cx == 0) { buf = Dword(b, p); p += 4; cx = 32; }
                }
                o[i] = (byte)node;
            }
            return o;
        }

        // ---- encode ---------------------------------------------------------
        class Node { public long Freq; public int Index; public Node L, R; }

        public static byte[] Deflate(byte[] data)
        {
            var freq = new long[256];
            foreach (byte v in data) freq[v]++;

            var live = new List<Node>();
            for (int i = 0; i < 256; i++) if (freq[i] > 0) live.Add(new Node { Freq = freq[i], Index = i });

            var tree = new ushort[1024];
            int root;

            if (live.Count == 0) { root = 0; }
            else if (live.Count == 1)
            {
                // One symbol: the decoder's `while node >= 0x100` never runs and
                // it emits the root as a literal every time, which is correct --
                // and consumes no bits at all.
                root = live[0].Index;
            }
            else
            {
                int next = 256;
                var pool = new List<Node>(live);
                while (pool.Count > 1)
                {
                    pool.Sort(delegate (Node a, Node b) {
                        int c = a.Freq.CompareTo(b.Freq);
                        return c != 0 ? c : a.Index.CompareTo(b.Index);   // stable, so output is reproducible
                    });
                    Node x = pool[0], y = pool[1];
                    pool.RemoveRange(0, 2);
                    if (next > 511) throw new Exception("more than 256 internal nodes; cannot index in 256..511");
                    var par = new Node { Freq = x.Freq + y.Freq, Index = next++, L = x, R = y };
                    tree[par.Index * 2 + 0] = (ushort)x.Index;
                    tree[par.Index * 2 + 1] = (ushort)y.Index;
                    pool.Add(par);
                }
                root = pool[0].Index;
                if (root < 256) throw new Exception("root must be an internal node");
            }

            // Walk the tree once to get each symbol's bit path.
            var codes = new List<bool>[256];
            if (live.Count > 1) BuildCodes(tree, root, new List<bool>(), codes);
            else if (live.Count == 1) codes[live[0].Index] = new List<bool>();

            var bits = new List<bool>();
            foreach (byte v in data)
            {
                var c = codes[v];
                if (c == null) throw new Exception("symbol " + v + " has no code");
                bits.AddRange(c);
            }

            var ms = new MemoryStream();
            var bw = new BinaryWriter(ms);
            bw.Write(data.Length);
            bw.Write(root);
            for (int i = 0; i < 1024; i++) bw.Write(tree[i]);

            uint acc = 0; int n = 0;
            foreach (bool bit in bits)
            {
                if (bit) acc |= (1u << n);
                if (++n == 32) { bw.Write(acc); acc = 0; n = 0; }
            }
            bw.Write(acc);                 // flush the partial word
            bw.Write((uint)0);             // ...and pad, because the decoder may
            bw.Write((uint)0);             // refill past the last bit it uses
            return ms.ToArray();
        }

        static void BuildCodes(ushort[] tree, int node, List<bool> path, List<bool>[] codes)
        {
            if (node < 256) { codes[node] = new List<bool>(path); return; }
            path.Add(false); BuildCodes(tree, tree[node * 2 + 0], path, codes); path.RemoveAt(path.Count - 1);
            path.Add(true);  BuildCodes(tree, tree[node * 2 + 1], path, codes); path.RemoveAt(path.Count - 1);
        }

        // ---- container ------------------------------------------------------
        public static List<AzfTexture> Read(string path)
        {
            byte[] b = File.ReadAllBytes(path);
            var list = new List<AzfTexture>();
            int p = 0;
            while (p + 64 <= b.Length)
            {
                int len = BitConverter.ToInt32(b, p);
                if (len <= 0 || (long)len + 4 > b.Length - p) break;
                var t = new AzfTexture();
                t.Width        = BitConverter.ToInt32(b, p + 4);
                t.Height       = BitConverter.ToInt32(b, p + 8);
                t.AspectX      = BitConverter.ToInt32(b, p + 12);
                t.AspectY      = BitConverter.ToInt32(b, p + 16);
                t.Depth        = BitConverter.ToInt32(b, p + 20);
                t.Rgb          = BitConverter.ToInt32(b, p + 24);
                t.BytesPerLine = BitConverter.ToInt32(b, p + 28);
                t.RedMask      = BitConverter.ToUInt32(b, p + 40);
                t.GreenMask    = BitConverter.ToUInt32(b, p + 44);
                t.BlueMask     = BitConverter.ToUInt32(b, p + 48);
                t.AlphaMask    = BitConverter.ToUInt32(b, p + 52);
                int ps         = BitConverter.ToInt32(b, p + 56);
                if (t.Width <= 0 || t.Height <= 0 || ps < 0 || ps > 256) break;
                t.Palette = new byte[ps * 4];
                Array.Copy(b, p + 64, t.Palette, 0, ps * 4);

                t.Raw = new byte[len + 4];
                Array.Copy(b, p, t.Raw, 0, len + 4);

                // A record that will not decode is KEPT, not dropped: its header and
                // palette are fine, and Raw lets Write put it back untouched. Dropping
                // it would renumber every record after it, which silently remaps every
                // texture in the room.
                try { t.Pixels = Inflate(b, p + 64 + ps * 4); t.Decoded = true; }
                catch { t.Pixels = null; t.Decoded = false; }

                list.Add(t);
                p += len + 4;
            }
            return list;
        }

        public static void Write(string path, List<AzfTexture> texs)
        {
            var ms = new MemoryStream();
            var bw = new BinaryWriter(ms);
            foreach (var t in texs)
            {
                // Untouched record -> copy the original bytes. This makes an import a
                // surgical edit rather than a full re-pack, so a re-encode bug can only
                // ever affect the records actually being replaced.
                if (!t.Dirty)
                {
                    if (t.Raw == null)
                        throw new Exception("record is neither Dirty nor has Raw bytes to copy through");
                    bw.Write(t.Raw);
                    continue;
                }
                if (t.Pixels == null)
                    throw new Exception("record marked Dirty but has no pixels");

                byte[] pix = Deflate(t.Pixels);
                int payload = 60 + t.Palette.Length + pix.Length;
                bw.Write(payload);
                bw.Write(t.Width); bw.Write(t.Height);
                bw.Write(t.AspectX); bw.Write(t.AspectY);
                bw.Write(t.Depth); bw.Write(t.Rgb);
                bw.Write(t.BytesPerLine);
                bw.Write((uint)0); bw.Write((uint)0);            // buffer1/2: runtime only
                bw.Write(t.RedMask); bw.Write(t.GreenMask);
                bw.Write(t.BlueMask); bw.Write(t.AlphaMask);
                bw.Write(t.PaletteSize);
                bw.Write((uint)0);                                // palette*: runtime only
                bw.Write(t.Palette);
                bw.Write(pix);
            }
            File.WriteAllBytes(path, ms.ToArray());
        }
    }
}
