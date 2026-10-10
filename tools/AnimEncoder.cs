// AnimEncoder.cs -- write Azrael's .MOV (IAnimation) format.
//
// The inverse of AnimTool.cs. Container layout and chunk semantics are documented there
// and in tools\Read-Anim.ps1; this only notes what the ENCODER has to get right.
//
// 1. THE CONTROL STREAM AND THE DATA STREAM ARE THE SAME STREAM, INTERLEAVED. The decoder
//    (0x204B4) reads one control byte, then the data for the next FOUR opcodes, then the
//    next control byte. Opcodes occupy bits 0-1, 2-3, 4-5, 6-7 in that order, because the
//    decoder does `op = ctrl & 3` then `ctrl >>= 2`. Emitting all control bytes up front,
//    or packing the opcodes the other way round, produces a file that decodes to noise.
//
// 2. ONLY TWO OPCODES ARE NEEDED. op3 (16 literal bytes) and op1 (skip run) are sufficient
//    to express any frame. The two motion-vector opcodes are a compression optimisation, and
//    getting a motion search subtly wrong is the easiest way to ship a file that looks right
//    for fifty frames and then drifts. Correctness first.
//
// 3. NEVER DITHER. The palette mapping has to be nearest-colour, not error-diffused: dither
//    noise makes every block differ from the previous frame even where the picture is
//    static, which destroys the skip runs and inflates the file several times over.
//
// 4. THE PALETTE IS VGA 6-BIT. The decoder scales by 255/63, so entries are stored 0..63.
//    Colours are matched against the 6-bit-rounded palette, not the 8-bit one, so the match
//    reflects what will actually be displayed.
//
// 5. FRAMES ARE STORED UNCOMPRESSED (compressed size 0). Every shipped file already does
//    this for all but frame 0, and the engine handles it on the documented path.
//
// Dimensions must be multiples of 4: the block copy writes a full 4x4 regardless, so a
// partial block at an edge would run past the end of the row.
using System;
using System.Collections.Generic;
using System.IO;

namespace AztTool
{
    public class AnimEncoder : IDisposable
    {
        FileStream _fs;
        BinaryWriter _w;
        int _w2, _h, _fps;
        byte[] _pal6 = new byte[768];      // as stored: 0..63
        byte[] _prev;                      // previous frame's indices
        int _frames;
        bool _first = true;

        public long LiteralBlocks, SkippedBlocks, SkipRuns;

        public AnimEncoder(string path, int width, int height, int fps)
        {
            if ((width & 3) != 0 || (height & 3) != 0)
                throw new Exception("width and height must be multiples of 4 (the codec writes whole 4x4 blocks)");
            _w2 = width; _h = height; _fps = fps;
            _fs = new FileStream(path, FileMode.Create, FileAccess.Write);
            _w = new BinaryWriter(_fs);

            _w.Write((uint)0xAB12EF90);
            _w.Write((ushort)0);           // frame count, patched in Close
            _w.Write((ushort)fps);
            _w.Write((ushort)width);
            _w.Write((ushort)height);
            for (int i = 0; i < 18; i++) _w.Write((byte)0);   // header is 30 bytes total
        }

        /// <summary>Palette as 256 RGB triples, 0..255. Stored as 6-bit.</summary>
        public void SetPalette(byte[] rgb768)
        {
            for (int i = 0; i < 768 && i < rgb768.Length; i++) _pal6[i] = (byte)(rgb768[i] >> 2);
        }

        /// <summary>The palette as it will be displayed: 6-bit values scaled back to 0..255.</summary>
        public byte[] DisplayPalette()
        {
            var o = new byte[768];
            for (int i = 0; i < 768; i++) o[i] = (byte)(_pal6[i] * 255 / 63);
            return o;
        }

        static void WriteChunkHeader(BinaryWriter w, int type, int size)
        {
            w.Write((uint)0x0123FEDC);
            w.Write((ushort)type);
            w.Write((uint)size);
            w.Write((ushort)0);
            w.Write((uint)0);            // 16 bytes total
        }

        /// <summary>
        /// Append a frame. <paramref name="idx"/> is width*height palette indices.
        /// Audio, when supplied, is copied through verbatim with its original chunk type.
        /// </summary>
        public void AddFrame(byte[] idx, byte[] audio, int audioLen, int audioType)
        {
            var ms = new MemoryStream();
            var bw = new BinaryWriter(ms);
            int nChunks = 0;

            if (_first)
            {
                WriteChunkHeader(bw, 5, 768);
                bw.Write(_pal6, 0, 768);
                nChunks++;

                WriteChunkHeader(bw, 1, _w2 * _h);
                bw.Write(idx, 0, _w2 * _h);
                nChunks++;
            }
            else
            {
                var delta = BuildDelta(idx);
                WriteChunkHeader(bw, 4, delta.Length);
                bw.Write(delta, 0, delta.Length);
                nChunks++;
            }

            if (audio != null && audioLen > 0 && audioType != 0)
            {
                WriteChunkHeader(bw, audioType, audioLen);
                bw.Write(audio, 0, audioLen);
                nChunks++;
            }

            bw.Flush();
            var payload = ms.ToArray();
            ms.Dispose();

            _w.Write((uint)0xEE9901CF);
            _w.Write((ushort)nChunks);
            _w.Write((uint)payload.Length);
            _w.Write((uint)0);             // compressed size 0 = stored raw
            _w.Write((ushort)0);           // 16 bytes total
            _w.Write(payload, 0, payload.Length);

            if (_prev == null) _prev = new byte[_w2 * _h];
            Array.Copy(idx, _prev, _w2 * _h);
            _first = false;
            _frames++;
        }

        bool BlockEquals(byte[] a, byte[] b, int off)
        {
            for (int r = 0; r < 4; r++)
            {
                int o = off + r * _w2;
                if (a[o] != b[o] || a[o+1] != b[o+1] || a[o+2] != b[o+2] || a[o+3] != b[o+3]) return false;
            }
            return true;
        }

        byte[] BuildDelta(byte[] idx)
        {
            var data = new List<byte>(_w2 * _h / 4);
            var ops  = new List<int>();          // opcode per emitted slot
            var args = new List<byte[]>();       // its data bytes

            int bw2 = _w2 / 4, bh = _h / 4;
            int run = 0;

            Action flushRun = delegate {
                while (run > 0)
                {
                    int n = Math.Min(run, 256);
                    ops.Add(1);
                    args.Add(new byte[] { (byte)(n == 256 ? 0 : n) });   // 0 means 256
                    SkipRuns++;
                    run -= n;
                }
            };

            for (int by = 0; by < bh; by++)
            {
                for (int bx = 0; bx < bw2; bx++)
                {
                    int off = (by * 4) * _w2 + bx * 4;
                    if (BlockEquals(idx, _prev, off)) { run++; SkippedBlocks++; continue; }
                    flushRun();
                    var lit = new byte[16];
                    for (int r = 0; r < 4; r++)
                        Array.Copy(idx, off + r * _w2, lit, r * 4, 4);
                    ops.Add(3);
                    args.Add(lit);
                    LiteralBlocks++;
                }
            }
            // THE TRAILING RUN MUST BE EMITTED. It is tempting to drop it -- the blocks it
            // covers would keep the previous frame's pixels anyway -- but the decoder does
            // not know the frame is finished. It keeps walking blocks, keeps taking 2-bit
            // opcodes from whatever byte it has, and keeps reading operands past the end of
            // this chunk. In a frame laid out [delta][audio] that means it decodes the
            // SOUNDTRACK as picture data. Costs a couple of bytes; prevents garbage.
            flushRun();

            // interleave: control byte, then the data for its four opcodes
            for (int i = 0; i < ops.Count; i += 4)
            {
                int ctrl = 0;
                for (int k = 0; k < 4 && i + k < ops.Count; k++) ctrl |= (ops[i + k] & 3) << (k * 2);
                data.Add((byte)ctrl);
                for (int k = 0; k < 4 && i + k < ops.Count; k++) data.AddRange(args[i + k]);
            }
            // one spare control byte: the decoder fetches the next one after every fourth
            // opcode, including the last, and would otherwise read past the chunk
            data.Add(0);
            return data.ToArray();
        }

        public void Close()
        {
            if (_fs == null) return;
            _fs.Seek(4, SeekOrigin.Begin);
            _w.Write((ushort)_frames);
            _fs.Seek(0, SeekOrigin.End);
            _w.Flush(); _fs.Close(); _fs = null;
        }

        public void Dispose() { Close(); }

        /// <summary>
        /// Palette indices to BGRA, using a 6-bit VGA palette. Lets an ORIGINAL movie be
        /// re-encoded at a larger size: decode, expand to colour, resample, re-map.
        /// No detail is invented, but the picture covers the screen instead of sitting in
        /// a small rectangle in the middle of it, which is most of the complaint.
        /// </summary>
        public static byte[] IndicesToBgra(byte[] idx, byte[] pal6, int w, int h)
        {
            var o = new byte[w * h * 4];
            for (int i = 0; i < w * h && i < idx.Length; i++)
            {
                int c = idx[i];
                o[i*4]     = (byte)(pal6[c*3+2] * 255 / 63);   // B
                o[i*4 + 1] = (byte)(pal6[c*3+1] * 255 / 63);   // G
                o[i*4 + 2] = (byte)(pal6[c*3]   * 255 / 63);   // R
                o[i*4 + 3] = 255;
            }
            return o;
        }

        // 15-bit (5:5:5) nearest-colour lookup. The exact-RGB cache used by the plain
        // mapper is useless once dithering is on -- error diffusion makes almost every
        // pixel a different colour, so the cache would grow to millions of entries and
        // still miss. 32,768 entries built once costs nothing and makes the inner loop O(1).
        byte[] _lut;
        void BuildLut()
        {
            if (_lut != null) return;
            _lut = new byte[32768];
            var pr = new int[256]; var pg = new int[256]; var pb = new int[256];
            for (int i = 0; i < 256; i++)
            {
                pr[i] = _pal6[i*3] * 255 / 63;
                pg[i] = _pal6[i*3+1] * 255 / 63;
                pb[i] = _pal6[i*3+2] * 255 / 63;
            }
            for (int r = 0; r < 32; r++)
                for (int g = 0; g < 32; g++)
                    for (int b = 0; b < 32; b++)
                    {
                        int rr = (r << 3) | 4, gg = (g << 3) | 4, bb = (b << 3) | 4;  // bin centre
                        int bd = int.MaxValue, bi = 0;
                        for (int c = 0; c < 256; c++)
                        {
                            int dr = pr[c] - rr, dg = pg[c] - gg, db = pb[c] - bb;
                            int d = dr*dr + dg*dg + db*db;
                            if (d < bd) { bd = d; bi = c; }
                        }
                        _lut[(r << 10) | (g << 5) | b] = (byte)bi;
                    }
        }

        /// <summary>
        /// Floyd-Steinberg error diffusion.
        ///
        /// THIS COSTS COMPRESSION, BY DESIGN OF THE FORMAT. Dither noise makes a block
        /// differ from the previous frame even where the picture has not moved, so skip
        /// runs collapse and the file grows -- often several times over. It is worth it
        /// only where banding is the visible problem, which is smooth gradients: a logo
        /// or a fade, not a busy 3D scene. Compare both before choosing.
        /// </summary>
        public byte[] MapFrameDithered(byte[] bgra, int w, int h)
        {
            BuildLut();
            var o = new byte[w * h];
            var pr = new int[256]; var pg = new int[256]; var pb = new int[256];
            for (int i = 0; i < 256; i++)
            {
                pr[i] = _pal6[i*3] * 255 / 63;
                pg[i] = _pal6[i*3+1] * 255 / 63;
                pb[i] = _pal6[i*3+2] * 255 / 63;
            }
            // two rows of accumulated error, one per channel
            var curR = new int[w + 2]; var curG = new int[w + 2]; var curB = new int[w + 2];
            var nxtR = new int[w + 2]; var nxtG = new int[w + 2]; var nxtB = new int[w + 2];

            for (int y = 0; y < h; y++)
            {
                Array.Clear(nxtR, 0, nxtR.Length);
                Array.Clear(nxtG, 0, nxtG.Length);
                Array.Clear(nxtB, 0, nxtB.Length);
                for (int x = 0; x < w; x++)
                {
                    int i = (y * w + x) * 4;
                    int b = bgra[i] + curB[x+1];
                    int g = bgra[i+1] + curG[x+1];
                    int r = bgra[i+2] + curR[x+1];
                    if (r < 0) r = 0; else if (r > 255) r = 255;
                    if (g < 0) g = 0; else if (g > 255) g = 255;
                    if (b < 0) b = 0; else if (b > 255) b = 255;

                    byte idx = _lut[((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)];
                    o[y * w + x] = idx;

                    int er = r - pr[idx], eg = g - pg[idx], eb = b - pb[idx];
                    curR[x+2] += er * 7 / 16; curG[x+2] += eg * 7 / 16; curB[x+2] += eb * 7 / 16;
                    nxtR[x]   += er * 3 / 16; nxtG[x]   += eg * 3 / 16; nxtB[x]   += eb * 3 / 16;
                    nxtR[x+1] += er * 5 / 16; nxtG[x+1] += eg * 5 / 16; nxtB[x+1] += eb * 5 / 16;
                    nxtR[x+2] += er     / 16; nxtG[x+2] += eg     / 16; nxtB[x+2] += eb     / 16;
                }
                var t = curR; curR = nxtR; nxtR = t;
                t = curG; curG = nxtG; nxtG = t;
                t = curB; curB = nxtB; nxtB = t;
            }
            return o;
        }

        /// <summary>
        /// Nearest-colour mapping against the 6-bit palette. Deliberately NOT dithered --
        /// see note 3 at the top of this file.
        /// </summary>
        public byte[] MapFrame(byte[] bgra, int w, int h)
        {
            var o = new byte[w * h];
            var pr = new int[256]; var pg = new int[256]; var pb = new int[256];
            for (int i = 0; i < 256; i++)
            {
                pr[i] = _pal6[i*3] * 255 / 63;
                pg[i] = _pal6[i*3+1] * 255 / 63;
                pb[i] = _pal6[i*3+2] * 255 / 63;
            }
            var cache = new Dictionary<int, byte>();
            for (int i = 0; i < w * h; i++)
            {
                int b = bgra[i*4], g = bgra[i*4+1], r = bgra[i*4+2];
                int key = (r << 16) | (g << 8) | b;
                byte best;
                if (!cache.TryGetValue(key, out best))
                {
                    int bd = int.MaxValue, bi = 0;
                    for (int c = 0; c < 256; c++)
                    {
                        int dr = pr[c] - r, dg = pg[c] - g, db = pb[c] - b;
                        int d = dr*dr + dg*dg + db*db;
                        if (d < bd) { bd = d; bi = c; }
                    }
                    best = (byte)bi; cache[key] = best;
                }
                o[i] = best;
            }
            return o;
        }
    }
}
