// Mp4Reader.cs -- decode MP4/H.264 to raw frames using Windows Media Foundation.
//
// There is no ffmpeg on this machine, and the upscaler (TensorPix) emits MP4. Media
// Foundation ships with Windows, so the whole pipeline stays local and needs no download.
//
// The Source Reader does the work: point it at a file, ask for RGB32 output, and it inserts
// the H.264 decoder and a colour converter itself. Two details decide whether the frames
// come out right:
//
//   MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING must be set on the attribute store BEFORE the
//   reader is created. Without it, asking for RGB32 on an H.264 file fails outright -- the
//   decoder only offers NV12 and nothing will convert it.
//
//   MF_MT_DEFAULT_STRIDE can be NEGATIVE, which means the buffer is bottom-up. Reading it
//   as top-down produces a vertically mirrored frame, which is easy to miss on a dark
//   cutscene and ruins every frame of the encode.
//
// COM interfaces are declared with placeholder slots for the methods this never calls. The
// VTABLE ORDER is what matters -- IMFSample and IMFMediaType both inherit IMFAttributes, so
// their own methods sit after that interface's thirty. Omitting the placeholders silently
// calls the wrong function pointer.
using System;
using System.Runtime.InteropServices;

namespace AztTool
{
    [ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFAttributes
    {
        void GetItem(); void GetItemType(); void CompareItem(); void Compare();
        void GetUINT32(); [PreserveSig] int GetUINT64([In] ref Guid key, out ulong value);
        void GetDouble(); void GetGUID(); void GetStringLength(); void GetString();
        void GetAllocatedString(); void GetBlobSize(); void GetBlob(); void GetAllocatedBlob();
        void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
        [PreserveSig] int SetUINT32([In] ref Guid key, int value);
        void SetUINT64(); void SetDouble();
        [PreserveSig] int SetGUID([In] ref Guid key, [In] ref Guid value);
        void SetString(); void SetBlob(); void SetUnknown(); void LockStore(); void UnlockStore();
        void GetCount(); void GetItemByIndex(); void CopyAllItems();
    }

    [ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaType
    {
        // --- IMFAttributes (30 slots)
        void GetItem(); void GetItemType(); void CompareItem(); void Compare();
        [PreserveSig] int GetUINT32([In] ref Guid key, out int value);
        [PreserveSig] int GetUINT64([In] ref Guid key, out ulong value);
        void GetDouble(); void GetGUID(); void GetStringLength(); void GetString();
        void GetAllocatedString(); void GetBlobSize(); void GetBlob(); void GetAllocatedBlob();
        void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
        [PreserveSig] int SetUINT32([In] ref Guid key, int value);
        void SetUINT64(); void SetDouble();
        [PreserveSig] int SetGUID([In] ref Guid key, [In] ref Guid value);
        void SetString(); void SetBlob(); void SetUnknown(); void LockStore(); void UnlockStore();
        void GetCount(); void GetItemByIndex(); void CopyAllItems();
        // --- IMFMediaType
        void GetMajorType(); void IsCompressedFormat(); void IsEqual();
        void GetRepresentation(); void FreeRepresentation();
    }

    [ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSample
    {
        // --- IMFAttributes (30 slots)
        void GetItem(); void GetItemType(); void CompareItem(); void Compare();
        void GetUINT32(); void GetUINT64(); void GetDouble(); void GetGUID();
        void GetStringLength(); void GetString(); void GetAllocatedString(); void GetBlobSize();
        void GetBlob(); void GetAllocatedBlob(); void GetUnknown(); void SetItem();
        void DeleteItem(); void DeleteAllItems(); void SetUINT32(); void SetUINT64();
        void SetDouble(); void SetGUID(); void SetString(); void SetBlob(); void SetUnknown();
        void LockStore(); void UnlockStore(); void GetCount(); void GetItemByIndex(); void CopyAllItems();
        // --- IMFSample
        void GetSampleFlags(); void SetSampleFlags(); void GetSampleTime(); void SetSampleTime();
        void GetSampleDuration(); void SetSampleDuration(); void GetBufferCount(); void GetBufferByIndex();
        [PreserveSig] int ConvertToContiguousBuffer(out IMFMediaBuffer buffer);
        void AddBuffer(); void RemoveBufferByIndex(); void RemoveAllBuffers();
        void GetTotalLength(); void CopyToBuffer();
    }

    [ComImport, Guid("045fa593-8799-42b8-bc8d-8968c6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaBuffer
    {
        [PreserveSig] int Lock(out IntPtr ptr, out int maxLen, out int curLen);
        [PreserveSig] int Unlock();
        [PreserveSig] int GetCurrentLength(out int len);
        void SetCurrentLength(); void GetMaxLength();
    }

    [ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSourceReader
    {
        void GetStreamSelection();
        [PreserveSig] int SetStreamSelection(int streamIndex, [MarshalAs(UnmanagedType.Bool)] bool selected);
        void GetNativeMediaType();
        [PreserveSig] int GetCurrentMediaType(int streamIndex, out IMFMediaType type);
        [PreserveSig] int SetCurrentMediaType(int streamIndex, IntPtr reserved, IMFMediaType type);
        void SetCurrentPosition();
        [PreserveSig] int ReadSample(int streamIndex, int flags, out int actualIndex,
                                     out int streamFlags, out long timestamp, out IMFSample sample);
        void Flush(); void GetServiceForStream(); void GetPresentationAttribute();
    }

    public class Mp4Reader : IDisposable
    {
        [DllImport("mfplat.dll")] static extern int MFStartup(int version, int flags);
        [DllImport("mfplat.dll")] static extern int MFShutdown();
        [DllImport("mfplat.dll")] static extern int MFCreateAttributes(out IMFAttributes attrs, int initialSize);
        [DllImport("mfplat.dll")] static extern int MFCreateMediaType(out IMFMediaType type);
        [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)]
        static extern int MFCreateSourceReaderFromURL(string url, IMFAttributes attrs, out IMFSourceReader reader);

        static Guid MF_MT_MAJOR_TYPE = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
        static Guid MF_MT_SUBTYPE    = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
        static Guid MFMediaType_Video= new Guid("73646976-0000-0010-8000-00aa00389b71");
        static Guid MFVideoFormat_RGB32 = new Guid("00000016-0000-0010-8000-00aa00389b71");
        static Guid MF_MT_FRAME_SIZE = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
        static Guid MF_MT_DEFAULT_STRIDE = new Guid("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
        static Guid MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING = new Guid("fb394f3d-ccf1-42ee-bbb3-f9b845d5681d");

        const int FIRST_VIDEO_STREAM = unchecked((int)0xFFFFFFFC);
        const int ALL_STREAMS        = unchecked((int)0xFFFFFFFE);
        const int MF_VERSION = 0x00020070;
        const int STREAMFLAG_ENDOFSTREAM = 0x2;

        IMFSourceReader _reader;
        bool _started;
        public int Width, Height;
        int _stride;
        bool _bottomUp;
        /// <summary>Row pitch MF DECLARED via MF_MT_DEFAULT_STRIDE (0 = absent).</summary>
        public int DeclaredStride;
        /// <summary>Row pitch actually used, after checking it against the first buffer.</summary>
        public int ActualStride { get { return _stride; } }
        /// <summary>Length of the first locked sample buffer, for diagnostics.</summary>
        public int FirstBufferLength;
        /// <summary>Set when the declared stride disagreed with the buffer and was corrected.</summary>
        public bool StrideCorrected;

        public Mp4Reader(string path)
        {
            int hr = MFStartup(MF_VERSION, 0);
            if (hr < 0) throw new Exception("MFStartup failed 0x" + hr.ToString("X8"));
            _started = true;

            IMFAttributes attrs;
            Check(MFCreateAttributes(out attrs, 1), "MFCreateAttributes");
            // must be set before the reader is created, or RGB32 cannot be negotiated
            Check(attrs.SetUINT32(ref MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1), "enable video processing");
            Check(MFCreateSourceReaderFromURL(path, attrs, out _reader), "MFCreateSourceReaderFromURL");

            Check(_reader.SetStreamSelection(ALL_STREAMS, false), "deselect all");
            Check(_reader.SetStreamSelection(FIRST_VIDEO_STREAM, true), "select video");

            IMFMediaType want;
            Check(MFCreateMediaType(out want), "MFCreateMediaType");
            Check(want.SetGUID(ref MF_MT_MAJOR_TYPE, ref MFMediaType_Video), "set major type");
            Check(want.SetGUID(ref MF_MT_SUBTYPE, ref MFVideoFormat_RGB32), "set RGB32");
            Check(_reader.SetCurrentMediaType(FIRST_VIDEO_STREAM, IntPtr.Zero, want), "SetCurrentMediaType(RGB32)");

            IMFMediaType cur;
            Check(_reader.GetCurrentMediaType(FIRST_VIDEO_STREAM, out cur), "GetCurrentMediaType");
            ulong fs;
            Check(cur.GetUINT64(ref MF_MT_FRAME_SIZE, out fs), "frame size");
            Width  = (int)(fs >> 32);
            Height = (int)(fs & 0xFFFFFFFF);

            int stride;
            if (cur.GetUINT32(ref MF_MT_DEFAULT_STRIDE, out stride) >= 0 && stride != 0)
            {
                _bottomUp = stride < 0;
                _stride = Math.Abs(stride);
                DeclaredStride = _stride;
            }
            else { _stride = Width * 4; _bottomUp = false; }
        }

        /// <summary>
        /// MF_MT_DEFAULT_STRIDE is the media type's NOMINAL pitch and the decoder is free to
        /// hand back rows padded wider than that. For a width that is already a multiple of 16
        /// the two agree and nothing is wrong; for one that is NOT -- 1470 pads to 1472, eight
        /// bytes a row -- every row lands two pixels off the last and the picture comes out
        /// sheared, each row shifted a little further than the one above. Nothing throws and
        /// the block codec downstream still reports 100% of blocks accounted, because the
        /// frames it is handed are self-consistent; they are just skewed.
        ///
        /// The buffer length settles it: a contiguous RGB32 buffer is exactly pitch*Height, so
        /// divide it back out and believe that over the declared value.
        /// </summary>
        void CheckStride(int bufLen)
        {
            if (FirstBufferLength != 0) return;          // first frame only
            FirstBufferLength = bufLen;
            if (Height <= 0 || Width <= 0) return;

            // DO NOT divide by Height: the decoder pads the HEIGHT too. A 1470x630 clip comes
            // back as 1472x640 -- both axes rounded up to 16 -- so bufLen/Height is 5981.46 and
            // a divisibility test simply fails. Walk candidate pitches instead and take the
            // narrowest one that divides the buffer into a whole number of rows, allowing the
            // row count itself to be padded. A width that is already aligned matches Width*4
            // first and nothing changes.
            for (int pitch = Width * 4; pitch <= Width * 4 + 256; pitch += 4)
            {
                if (bufLen % pitch != 0) continue;
                int rows = bufLen / pitch;
                if (rows < Height || rows > Height + 64) continue;
                if (pitch != _stride) { _stride = pitch; StrideCorrected = true; }
                return;
            }
        }

        /// <summary>The next frame's locked buffer, copied verbatim with no de-striding.
        /// For working out the true pitch from the picture itself.</summary>
        public byte[] ReadRawFrame()
        {
            int actual, flags; long ts; IMFSample sample;
            Check(_reader.ReadSample(FIRST_VIDEO_STREAM, 0, out actual, out flags, out ts, out sample), "ReadSample");
            if ((flags & STREAMFLAG_ENDOFSTREAM) != 0) { if (sample != null) Marshal.ReleaseComObject(sample); return null; }
            if (sample == null) return new byte[0];
            IMFMediaBuffer buf;
            Check(sample.ConvertToContiguousBuffer(out buf), "ConvertToContiguousBuffer");
            IntPtr p; int maxLen, curLen;
            Check(buf.Lock(out p, out maxLen, out curLen), "Lock");
            var o = new byte[curLen];
            Marshal.Copy(p, o, 0, curLen);
            buf.Unlock();
            Marshal.ReleaseComObject(buf);
            Marshal.ReleaseComObject(sample);
            return o;
        }

        static void Check(int hr, string what)
        {
            if (hr < 0) throw new Exception(what + " failed 0x" + hr.ToString("X8"));
        }

        /// <summary>Next frame as BGRA, top-down, width*height*4. Null at end of stream.</summary>
        public byte[] ReadFrame()
        {
            while (true)
            {
                int actual, flags; long ts; IMFSample sample;
                Check(_reader.ReadSample(FIRST_VIDEO_STREAM, 0, out actual, out flags, out ts, out sample), "ReadSample");
                if ((flags & STREAMFLAG_ENDOFSTREAM) != 0) { if (sample != null) Marshal.ReleaseComObject(sample); return null; }
                if (sample == null) continue;          // a gap or a format change; keep going

                IMFMediaBuffer buf;
                Check(sample.ConvertToContiguousBuffer(out buf), "ConvertToContiguousBuffer");
                IntPtr p; int maxLen, curLen;
                Check(buf.Lock(out p, out maxLen, out curLen), "Lock");
                CheckStride(curLen);
                var o = new byte[Width * Height * 4];
                for (int y = 0; y < Height; y++)
                {
                    int src = _bottomUp ? (Height - 1 - y) * _stride : y * _stride;
                    Marshal.Copy((IntPtr)(p.ToInt64() + src), o, y * Width * 4, Width * 4);
                }
                // FORCE ALPHA OPAQUE. RGB32 is X8R8G8B8 and Media Foundation leaves the X
                // byte at ZERO, so the buffer reads as fully transparent. Anything that
                // composites it -- Graphics.DrawImage, which is how frames get resized --
                // then draws nothing at all, and every frame comes out identical to the
                // last. A raw byte copy shows the picture perfectly, so this only bites
                // once the frames go through GDI+.
                for (int i = 3; i < o.Length; i += 4) o[i] = 255;
                buf.Unlock();
                Marshal.ReleaseComObject(buf);
                Marshal.ReleaseComObject(sample);
                return o;
            }
        }

        public void Dispose()
        {
            if (_reader != null) { Marshal.ReleaseComObject(_reader); _reader = null; }
            if (_started) { MFShutdown(); _started = false; }
        }
    }
}
