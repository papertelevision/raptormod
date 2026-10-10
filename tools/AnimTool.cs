// AnimTool.cs -- decoder for Azrael's Tear .MOV (IAnimation) animations.
//
// Everything here is transcribed from R.EXE, not inferred from the files:
//   0x2026C  IAnimation constructor   - 30-byte file header
//   0x20A2C  DecodeAnimationFrame     - 16-byte frame header, chunk dispatch (table 0x20A10)
//   0x20470  chunk type 1  keyframe   - movsd/movsb memcpy of w*h
//   0x20770  chunk type 5  palette    - 256 RGB triples, VGA 6-bit
//   0x204B4  chunk type 4  delta      - the block codec below (opcode table 0x204A4)
//   0x207F0  chunk types 6/7 audio    - not video
//   0x37B38  end of frame             - memcpy CURRENT -> PREVIOUS
//
// THE DELTA CODEC. The image is walked in BANDS OF 4 SCANLINES, and within a band in
// blocks of 4 pixels, left to right. Each block takes a 2-bit opcode from a control byte;
// a fresh control byte is fetched after 4 blocks (0x20701). So a block is 4x4 pixels and
// a control byte covers four of them.
//
//   op 0  0x205A4  MOTION VECTOR, long form. Two bytes A,B.
//                    dx = A - 0x7F
//                    B >= 0x80 -> dy = B - 0xBF, source is the CURRENT frame
//                    B <  0x80 -> dy = B - 0x3F, source is the PREVIOUS frame
//   op 1  0x20639  SKIP RUN. One byte; 0 means 256. That many blocks are left untouched,
//                    INCLUDING this one. Skipped blocks consume no opcode bits (0x20735
//                    bypasses 0x20701), and a run may cross band boundaries.
//   op 2  0x20653  MOTION VECTOR, packed. One byte, always from the PREVIOUS frame:
//                    dy = (c & 0x0F) - 7,  dx = (c >> 4) - 7
//                    Note the nibble order: the LOW nibble is scaled by width.
//   op 3  0x206E3  LITERAL. 16 bytes, the 4x4 block verbatim.
//
// "Skip" means leave the CURRENT buffer alone, which works because 0x37B38 copies current
// into previous at the end of every frame rather than swapping them -- the current buffer
// therefore still holds frame N-1 while frame N is being built.
//
// FRAME BUFFERS CARRY A MARGIN. Motion vectors reach up to 63 rows and 127 columns outside
// the block, and near an edge that lands outside the picture. The engine simply reads
// whatever heap follows its allocation; here the buffers are padded so the same read is
// in-bounds and yields black instead of crashing or picking up unrelated memory.
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace AztTool
{
    public class Anim
    {
        public const uint FILE_MAGIC  = 0xAB12EF90;
        public const uint FRAME_MAGIC = 0xEE9901CF;
        public const uint CHUNK_MAGIC = 0x0123FEDC;

        public int Frames, Fps, Width, Height;
        public byte[] Palette = new byte[768];     // VGA 6-bit
        public int FrameIndex = -1;
        public bool HasPalette;

        // statistics, so a caller can tell a clean decode from a plausible-looking mess
        public long OpCount0, OpCount1, OpCount2, OpCount3, BlocksSkipped, OutOfRange;

        // Audio from the frame just decoded. Chunk type 6 is 8-bit unsigned MONO and type 7
        // is 8-bit unsigned STEREO, interleaved -- established from the data: type 7's bytes
        // resolve into two independently smooth waveforms on the even and odd indices, while
        // type 6's form a single one. Both carry 2205 sample-frames per video frame, so at
        // 22050 Hz a frame is exactly 0.1s and the true rate is 10 fps, not the 12 the file
        // header reports.
        public const int SampleRate = 22050;
        public const int SamplesPerFrame = 2205;
        public byte[] LastAudio;
        public int LastAudioLen;
        public int AudioType;                      // 0 none, 6 mono, 7 stereo
        public int AudioChannels { get { return AudioType == 7 ? 2 : 1; } }
        public bool HasAudio { get { return AudioType != 0; } }

        byte[] _file;
        int _pos;
        byte[] _cur, _prev;
        int _origin;                               // index of pixel (0,0) inside _cur/_prev

        public Anim(string path)
        {
            _file = System.IO.File.ReadAllBytes(path);
            if (_file.Length < 30 || BitConverter.ToUInt32(_file, 0) != FILE_MAGIC)
                throw new Exception("not an Azrael animation (bad file magic)");
            Frames = BitConverter.ToUInt16(_file, 4);
            Fps    = BitConverter.ToUInt16(_file, 6);
            Width  = BitConverter.ToUInt16(_file, 8);
            Height = BitConverter.ToUInt16(_file, 10);
            _pos = 30;
            _origin = 70 * Width + 256;            // covers dy -63 and dx -127
            int size = _origin * 2 + Width * Height;
            _cur  = new byte[size];
            _prev = new byte[size];
        }

        /// <summary>Pixels of the frame just decoded, width*height, one palette index each.</summary>
        public byte[] GetPixels()
        {
            var o = new byte[Width * Height];
            Array.Copy(_cur, _origin, o, 0, o.Length);
            return o;
        }

        /// <summary>Decode the next frame. False at end of stream.</summary>
        public bool NextFrame()
        {
            if (_pos + 16 > _file.Length) return false;
            if (BitConverter.ToUInt32(_file, _pos) != FRAME_MAGIC) return false;
            int nChunks = BitConverter.ToUInt16(_file, _pos + 4);
            int rawSize = (int)BitConverter.ToUInt32(_file, _pos + 6);
            int cmpSize = (int)BitConverter.ToUInt32(_file, _pos + 10);
            _pos += 16;

            byte[] payload;
            if (cmpSize == 0)
            {
                if (_pos + rawSize > _file.Length) return false;
                payload = new byte[rawSize];
                Array.Copy(_file, _pos, payload, 0, rawSize);
                _pos += rawSize;
            }
            else
            {
                payload = Azf.Inflate(_file, _pos);   // the same inflate the .RES textures use
                _pos += cmpSize;
            }

            LastAudioLen = 0;
            int cp = 0;
            for (int c = 0; c < nChunks && cp + 16 <= payload.Length; c++)
            {
                int type = BitConverter.ToUInt16(payload, cp + 4);
                int size = (int)BitConverter.ToUInt32(payload, cp + 6);
                int d = cp + 16;
                switch (type)
                {
                    case 5:
                        for (int i = 0; i < 768 && d + i < payload.Length; i++) Palette[i] = payload[d + i];
                        HasPalette = true;
                        break;
                    case 1:
                        Array.Copy(payload, d, _cur, _origin, Math.Min(Width * Height, Math.Min(size, payload.Length - d)));
                        break;
                    case 4:
                        // bound by the chunk, not the payload: a delta stream that ends
                        // early must not spill into whatever chunk follows it
                        Delta(payload, d, Math.Min(payload.Length, d + size));
                        break;
                    case 6: case 7:
                        AudioType = type;
                        int alen = Math.Min(size, payload.Length - d);
                        if (alen > 0)
                        {
                            if (LastAudio == null || LastAudio.Length < alen) LastAudio = new byte[alen];
                            Array.Copy(payload, d, LastAudio, 0, alen);
                            LastAudioLen = alen;
                        }
                        break;
                }
                cp += 16 + size;
            }

            Array.Copy(_cur, _prev, _cur.Length);     // 0x37B38: current -> previous
            FrameIndex++;
            return true;
        }

        void Copy4x4(byte[] src, int s, int dOff)
        {
            for (int r = 0; r < 4; r++)
            {
                int ss = s + r * Width, dd = dOff + r * Width;
                if (ss < 0 || ss + 4 > src.Length) { OutOfRange++; continue; }
                _cur[dd]     = src[ss];
                _cur[dd + 1] = src[ss + 1];
                _cur[dd + 2] = src[ss + 2];
                _cur[dd + 3] = src[ss + 3];
            }
        }

        void Delta(byte[] s, int off, int end)
        {
            int W = Width, H = Height;
            if (off >= end) return;
            int ctrl = s[off++];
            int bits = 0;
            int skip = 0;

            for (int row = 0; row < H; row += 4)
            {
                for (int x = 0; x < W; x += 4)
                {
                    int dst = _origin + row * W + x;
                    if (skip != 0) { skip--; BlocksSkipped++; continue; }
                    int op = ctrl & 3;
                    switch (op)
                    {
                        case 0:
                        {
                            if (off + 1 >= end) return;
                            int A = s[off], B = s[off + 1]; off += 2;
                            int dx = A - 0x7F;
                            int dy; byte[] srcBuf;
                            if ((B & 0x80) != 0) { dy = B - 0xBF; srcBuf = _cur; }
                            else                 { dy = B - 0x3F; srcBuf = _prev; }
                            Copy4x4(srcBuf, _origin + (row + dy) * W + x + dx, dst);
                            OpCount0++;
                            break;
                        }
                        case 1:
                        {
                            if (off >= end) return;
                            int cnt = s[off++];
                            if (cnt == 0) cnt = 256;
                            skip = cnt - 1;           // this block is skipped too
                            BlocksSkipped++;
                            OpCount1++;
                            break;
                        }
                        case 2:
                        {
                            if (off >= end) return;
                            int c = s[off++];
                            int dy = (c & 0x0F) - 7;  // LOW nibble scales by width
                            int dx = (c >> 4) - 7;
                            Copy4x4(_prev, _origin + (row + dy) * W + x + dx, dst);
                            OpCount2++;
                            break;
                        }
                        default:
                        {
                            if (off + 16 > end) return;
                            for (int r = 0; r < 4; r++)
                                Array.Copy(s, off + r * 4, _cur, dst + r * W, 4);
                            off += 16;
                            OpCount3++;
                            break;
                        }
                    }
                    ctrl >>= 2;
                    if (++bits == 4)
                    {
                        if (off >= end) return;
                        ctrl = s[off++];
                        bits = 0;
                    }
                }
            }
        }

        /// <summary>The current frame as a 24bpp bitmap. Caller disposes.</summary>
        public Bitmap ToBitmap()
        {
            var bmp = new Bitmap(Width, Height, PixelFormat.Format24bppRgb);
            var bd = bmp.LockBits(new Rectangle(0, 0, Width, Height), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
            var row = new byte[bd.Stride];
            for (int y = 0; y < Height; y++)
            {
                for (int x = 0; x < Width; x++)
                {
                    int c = _cur[_origin + y * Width + x];
                    int r = Palette[c * 3] * 255 / 63;
                    int g = Palette[c * 3 + 1] * 255 / 63;
                    int b = Palette[c * 3 + 2] * 255 / 63;
                    if (r > 255) r = 255; if (g > 255) g = 255; if (b > 255) b = 255;
                    row[x * 3] = (byte)b; row[x * 3 + 1] = (byte)g; row[x * 3 + 2] = (byte)r;
                }
                Marshal.Copy(row, 0, (IntPtr)(bd.Scan0.ToInt64() + y * bd.Stride), bd.Stride);
            }
            bmp.UnlockBits(bd);
            return bmp;
        }

        public void SavePng(string path)
        {
            var bmp = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
            var bd = bmp.LockBits(new Rectangle(0, 0, Width, Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            var px = new int[Width * Height];
            for (int i = 0; i < px.Length; i++)
            {
                int c = _cur[_origin + i];
                int r = Palette[c * 3] * 255 / 63;
                int g = Palette[c * 3 + 1] * 255 / 63;
                int b = Palette[c * 3 + 2] * 255 / 63;
                if (r > 255) r = 255; if (g > 255) g = 255; if (b > 255) b = 255;
                px[i] = unchecked((int)0xFF000000) | (r << 16) | (g << 8) | b;
            }
            Marshal.Copy(px, 0, bd.Scan0, px.Length);
            bmp.UnlockBits(bd);
            bmp.Save(path, ImageFormat.Png);
            bmp.Dispose();
        }
    }
}
