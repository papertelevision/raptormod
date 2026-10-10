// AviWriter.cs -- minimal AVI muxer: Motion-JPEG video + 8-bit PCM audio.
//
// There is no ffmpeg on this machine, so producing an actual playable file means writing
// the container. AVI is the right choice here: the structure is small enough to emit
// correctly by hand, and VLC / MPC / Windows all open MJPEG AVI without extra codecs.
//
// MJPEG rather than uncompressed: a 640x480 frame is 307,200 bytes raw, so OUTRO2's 2,000
// frames would be 614 MB. As JPEG the same movie lands in the low tens of MB.
//
// The fiddly part of AVI is that three things are only known after all the data is written
// -- the RIFF size, the 'movi' list size and the frame count -- so those are emitted as
// zero placeholders and patched in Close(). The index (idx1) stores each chunk's offset
// RELATIVE TO THE 'movi' FOURCC, which is the form every player accepts; absolute file
// offsets are a common way to produce a file that looks fine to a parser and seeks wrongly.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

namespace AztTool
{
    public class AviWriter : IDisposable
    {
        FileStream _fs;
        BinaryWriter _w;
        int _width, _height;
        int _fps;
        bool _audio;
        int _channels, _sampleRate, _bits;

        long _riffSizePos, _moviListSizePos, _moviFourccPos, _totalFramesPos, _videoLenPos, _audioLenPos;
        int _videoFrames, _audioBytes, _maxVideoChunk;

        struct IdxEntry { public uint Id, Flags, Offset, Length; }
        List<IdxEntry> _idx = new List<IdxEntry>();

        static uint FourCC(string s)
        {
            return (uint)(s[0] | (s[1] << 8) | (s[2] << 16) | (s[3] << 24));
        }

        public AviWriter(string path, int width, int height, int fps,
                         bool audio, int channels, int sampleRate) :
            this(path, width, height, fps, audio, channels, sampleRate, 8) { }

        public AviWriter(string path, int width, int height, int fps,
                         bool audio, int channels, int sampleRate, int bitsPerSample)
        {
            _width = width; _height = height; _fps = fps;
            _audio = audio; _channels = channels; _sampleRate = sampleRate;
            _bits = bitsPerSample <= 0 ? 8 : bitsPerSample;
            _fs = new FileStream(path, FileMode.Create, FileAccess.Write);
            _w = new BinaryWriter(_fs);
            WriteHeaders();
        }

        void WriteHeaders()
        {
            _w.Write(FourCC("RIFF"));
            _riffSizePos = _fs.Position; _w.Write((uint)0);
            _w.Write(FourCC("AVI "));

            int nStreams = _audio ? 2 : 1;
            int hdrlSize = 4 + (8 + 56) + (8 + 4 + (8 + 56) + (8 + 40));
            if (_audio) hdrlSize += 8 + 4 + (8 + 56) + (8 + 18);

            _w.Write(FourCC("LIST"));
            _w.Write((uint)hdrlSize);
            _w.Write(FourCC("hdrl"));

            // ---- avih
            _w.Write(FourCC("avih"));
            _w.Write((uint)56);
            _w.Write((uint)(1000000 / _fps));        // microseconds per frame
            _w.Write((uint)(_width * _height * 3 * _fps));
            _w.Write((uint)0);
            _w.Write((uint)0x10);                    // AVIF_HASINDEX
            _totalFramesPos = _fs.Position; _w.Write((uint)0);
            _w.Write((uint)0);
            _w.Write((uint)nStreams);
            _w.Write((uint)(_width * _height * 3));
            _w.Write((uint)_width);
            _w.Write((uint)_height);
            for (int i = 0; i < 4; i++) _w.Write((uint)0);

            // ---- video stream
            _w.Write(FourCC("LIST"));
            _w.Write((uint)(4 + (8 + 56) + (8 + 40)));
            _w.Write(FourCC("strl"));
            _w.Write(FourCC("strh"));
            _w.Write((uint)56);
            _w.Write(FourCC("vids"));
            _w.Write(FourCC("MJPG"));
            _w.Write((uint)0); _w.Write((ushort)0); _w.Write((ushort)0);
            _w.Write((uint)0);
            _w.Write((uint)1);                       // scale
            _w.Write((uint)_fps);                    // rate  -> fps = rate/scale
            _w.Write((uint)0);
            _videoLenPos = _fs.Position; _w.Write((uint)0);
            _w.Write((uint)(_width * _height * 3));
            _w.Write((uint)0xFFFFFFFF);
            _w.Write((uint)0);
            _w.Write((short)0); _w.Write((short)0);
            _w.Write((short)_width); _w.Write((short)_height);

            _w.Write(FourCC("strf"));
            _w.Write((uint)40);
            _w.Write((uint)40);                      // biSize
            _w.Write((int)_width);
            _w.Write((int)_height);
            _w.Write((ushort)1);                     // biPlanes
            _w.Write((ushort)24);                    // biBitCount
            _w.Write(FourCC("MJPG"));                // biCompression
            _w.Write((uint)(_width * _height * 3));
            for (int i = 0; i < 4; i++) _w.Write((uint)0);

            // ---- audio stream
            if (_audio)
            {
                int blockAlign = _channels * (_bits / 8);
                _w.Write(FourCC("LIST"));
                _w.Write((uint)(4 + (8 + 56) + (8 + 18)));
                _w.Write(FourCC("strl"));
                _w.Write(FourCC("strh"));
                _w.Write((uint)56);
                _w.Write(FourCC("auds"));
                _w.Write((uint)1);                   // PCM
                _w.Write((uint)0); _w.Write((ushort)0); _w.Write((ushort)0);
                _w.Write((uint)0);
                _w.Write((uint)blockAlign);          // scale
                _w.Write((uint)(_sampleRate * blockAlign));
                _w.Write((uint)0);
                _audioLenPos = _fs.Position; _w.Write((uint)0);
                _w.Write((uint)(_sampleRate * blockAlign));
                _w.Write((uint)0xFFFFFFFF);
                _w.Write((uint)blockAlign);          // dwSampleSize
                _w.Write((short)0); _w.Write((short)0); _w.Write((short)0); _w.Write((short)0);

                _w.Write(FourCC("strf"));
                _w.Write((uint)18);
                _w.Write((ushort)1);                 // WAVE_FORMAT_PCM
                _w.Write((ushort)_channels);
                _w.Write((uint)_sampleRate);
                _w.Write((uint)(_sampleRate * blockAlign));
                _w.Write((ushort)blockAlign);
                _w.Write((ushort)_bits);
                _w.Write((ushort)0);
            }

            _w.Write(FourCC("LIST"));
            _moviListSizePos = _fs.Position; _w.Write((uint)0);
            _moviFourccPos = _fs.Position;
            _w.Write(FourCC("movi"));
        }

        void WriteChunk(string id, byte[] data, int len, bool keyframe)
        {
            long pos = _fs.Position;
            _w.Write(FourCC(id));
            _w.Write((uint)len);
            _w.Write(data, 0, len);
            if ((len & 1) != 0) _w.Write((byte)0);   // chunks are word aligned
            _idx.Add(new IdxEntry {
                Id = FourCC(id),
                Flags = keyframe ? 0x10u : 0u,
                Offset = (uint)(pos - _moviFourccPos),
                Length = (uint)len
            });
        }

        /// <summary>Encode and append one video frame.</summary>
        public void AddFrame(Bitmap bmp, long quality)
        {
            var enc = GetJpegEncoder();
            var ps = new EncoderParameters(1);
            ps.Param[0] = new EncoderParameter(Encoder.Quality, quality);
            using (var ms = new MemoryStream())
            {
                bmp.Save(ms, enc, ps);
                var b = ms.ToArray();
                if (b.Length > _maxVideoChunk) _maxVideoChunk = b.Length;
                WriteChunk("00dc", b, b.Length, true);
            }
            _videoFrames++;
        }

        /// <summary>Append PCM for this frame. Interleaved if stereo.</summary>
        public void AddAudio(byte[] pcm, int len)
        {
            if (!_audio || len <= 0) return;
            WriteChunk("01wb", pcm, len, false);
            _audioBytes += len;
        }

        static ImageCodecInfo _jpeg;
        static ImageCodecInfo GetJpegEncoder()
        {
            if (_jpeg == null)
                foreach (var c in ImageCodecInfo.GetImageEncoders())
                    if (c.FormatID == ImageFormat.Jpeg.Guid) { _jpeg = c; break; }
            return _jpeg;
        }

        public void Close()
        {
            if (_fs == null) return;
            long moviEnd = _fs.Position;

            _w.Write(FourCC("idx1"));
            _w.Write((uint)(_idx.Count * 16));
            foreach (var e in _idx)
            {
                _w.Write(e.Id); _w.Write(e.Flags); _w.Write(e.Offset); _w.Write(e.Length);
            }
            long fileEnd = _fs.Position;

            // patch the three sizes that were only knowable at the end
            _fs.Seek(_riffSizePos, SeekOrigin.Begin);      _w.Write((uint)(fileEnd - 8));
            _fs.Seek(_moviListSizePos, SeekOrigin.Begin);  _w.Write((uint)(moviEnd - _moviFourccPos));
            _fs.Seek(_totalFramesPos, SeekOrigin.Begin);   _w.Write((uint)_videoFrames);
            _fs.Seek(_videoLenPos, SeekOrigin.Begin);      _w.Write((uint)_videoFrames);
            if (_audio)
            {
                _fs.Seek(_audioLenPos, SeekOrigin.Begin);
                int ba = Math.Max(1, _channels * (_bits / 8));
                _w.Write((uint)(_audioBytes / ba));                       // in sample frames
            }
            _fs.Seek(0, SeekOrigin.End);
            _w.Flush(); _fs.Close();
            _fs = null;
        }

        public void Dispose() { Close(); }
    }
}
