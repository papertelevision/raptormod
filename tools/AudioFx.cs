// AudioFx.cs -- decode an MP3 to PCM with Media Foundation, apply reverb, write a WAV.
//
// There is no ffmpeg, LAME or NAudio on this machine, so Media Foundation does the decode
// (it ships with Windows) and the reverb and WAV writer are done by hand here. The one
// consequence is that the RESULT CANNOT BE AN MP3: nothing here can encode one. The CUE
// sheet takes WAVE tracks just as happily, and an 11-second track is a couple of MB.
//
// The COM interfaces are deliberately declared again rather than shared with Mp4Reader:
// that file's IMFSourceReader is typed around video, and its vtable placeholders are laid
// out for the methods it calls. Redeclaring keeps the two independent -- VTABLE ORDER is
// what matters with these, and a shared edit for one could silently break the other.
//
// REVERB is a Schroeder design: four parallel comb filters (which give the echo density)
// summed into two series allpass filters (which smear the result so it stops sounding like
// discrete echoes). The comb delays are mutually prime so their repeats do not line up and
// ring on one pitch. Feedback is derived from the wanted RT60:
//
//     g = 10 ^ (-3 * delaySeconds / rt60)
//
// which is the standard relation for a comb decaying 60 dB in rt60 seconds.
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace AztTool
{
    [ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAfxAttributes
    {
        void GetItem(); void GetItemType(); void CompareItem(); void Compare();
        void GetUINT32(); void GetUINT64(); void GetDouble(); void GetGUID();
        void GetStringLength(); void GetString(); void GetAllocatedString();
        void GetBlobSize(); void GetBlob(); void GetAllocatedBlob(); void GetUnknown();
        void SetItem(); void DeleteItem(); void DeleteAllItems();
        [PreserveSig] int SetUINT32([In] ref Guid key, int value);
        void SetUINT64(); void SetDouble();
        [PreserveSig] int SetGUID([In] ref Guid key, [In] ref Guid value);
        void SetString(); void SetBlob(); void SetUnknown(); void LockStore(); void UnlockStore();
        void GetCount(); void GetItemByIndex(); void CopyAllItems();
    }

    [ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAfxMediaType : IAfxAttributes { }

    [ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAfxSample
    {
        void GetItem(); void GetItemType(); void CompareItem(); void Compare();
        void GetUINT32(); void GetUINT64(); void GetDouble(); void GetGUID();
        void GetStringLength(); void GetString(); void GetAllocatedString();
        void GetBlobSize(); void GetBlob(); void GetAllocatedBlob(); void GetUnknown();
        void SetItem(); void DeleteItem(); void DeleteAllItems(); void SetUINT32();
        void SetUINT64(); void SetDouble(); void SetGUID(); void SetString(); void SetBlob();
        void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount();
        void GetItemByIndex(); void CopyAllItems();
        void GetSampleFlags(); void SetSampleFlags(); void GetSampleTime(); void SetSampleTime();
        void GetSampleDuration(); void SetSampleDuration(); void GetBufferCount();
        void GetBufferByIndex();
        [PreserveSig] int ConvertToContiguousBuffer(out IAfxMediaBuffer buffer);
    }

    [ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAfxMediaBuffer
    {
        [PreserveSig] int Lock(out IntPtr ptr, out int maxLen, out int curLen);
        [PreserveSig] int Unlock();
        [PreserveSig] int GetCurrentLength(out int len);
    }

    [ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAfxSourceReader
    {
        void GetStreamSelection();
        [PreserveSig] int SetStreamSelection(int streamIndex, bool selected);
        void GetNativeMediaType();
        [PreserveSig] int GetCurrentMediaType(int streamIndex, out IAfxMediaType type);
        [PreserveSig] int SetCurrentMediaType(int streamIndex, IntPtr reserved, IAfxMediaType type);
        void SetCurrentPosition();
        [PreserveSig] int ReadSample(int streamIndex, int flags, out int actualIndex,
                                     out int streamFlags, out long timestamp, out IAfxSample sample);
    }

    public static class AudioFx
    {
        [DllImport("mfplat.dll")] static extern int MFStartup(int version, int flags);
        [DllImport("mfplat.dll")] static extern int MFShutdown();
        [DllImport("mfplat.dll")] static extern int MFCreateMediaType(out IAfxMediaType type);
        [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)]
        static extern int MFCreateSourceReaderFromURL(string url, IAfxAttributes attrs, out IAfxSourceReader reader);

        static Guid MF_MT_MAJOR_TYPE      = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
        static Guid MF_MT_SUBTYPE         = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
        static Guid MFMediaType_Audio     = new Guid("73647561-0000-0010-8000-00aa00389b71");
        static Guid MFAudioFormat_PCM     = new Guid("00000001-0000-0010-8000-00aa00389b71");
        static Guid MF_MT_AUDIO_NUM_CHANNELS      = new Guid("37e48bf5-645e-4c5b-89de-ada9e29b696a");
        static Guid MF_MT_AUDIO_SAMPLES_PER_SECOND= new Guid("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
        static Guid MF_MT_AUDIO_BITS_PER_SAMPLE   = new Guid("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");

        const int FIRST_AUDIO_STREAM = unchecked((int)0xFFFFFFFD);
        const int STREAMFLAG_ENDOFSTREAM = 0x2;

        /// <summary>Decode any Media Foundation readable file to 16-bit stereo PCM.</summary>
        public static short[] DecodePcm(string path, int rate, out int channels) { return DecodePcm(path, rate, 2, out channels); }

        /// <summary>Decode to 16-bit PCM at a chosen rate and channel count.</summary>
        public static short[] DecodePcm(string path, int rate, int wantCh, out int channels)
        {
            channels = wantCh;
            MFStartup(0x20070, 0);
            IAfxSourceReader rd;
            int hr = MFCreateSourceReaderFromURL(path, null, out rd);
            if (hr < 0) throw new Exception("MFCreateSourceReaderFromURL failed: 0x" + hr.ToString("X8"));

            IAfxMediaType want;
            MFCreateMediaType(out want);
            want.SetGUID(ref MF_MT_MAJOR_TYPE, ref MFMediaType_Audio);
            want.SetGUID(ref MF_MT_SUBTYPE, ref MFAudioFormat_PCM);
            want.SetUINT32(ref MF_MT_AUDIO_NUM_CHANNELS, wantCh);
            want.SetUINT32(ref MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
            want.SetUINT32(ref MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
            hr = rd.SetCurrentMediaType(FIRST_AUDIO_STREAM, IntPtr.Zero, want);
            if (hr < 0) throw new Exception("SetCurrentMediaType(PCM) failed: 0x" + hr.ToString("X8"));
            rd.SetStreamSelection(FIRST_AUDIO_STREAM, true);

            var outBuf = new System.Collections.Generic.List<short>(rate * 2 * 30);
            while (true)
            {
                int actual, flags; long ts; IAfxSample sample;
                hr = rd.ReadSample(FIRST_AUDIO_STREAM, 0, out actual, out flags, out ts, out sample);
                if (hr < 0) throw new Exception("ReadSample failed: 0x" + hr.ToString("X8"));
                if ((flags & STREAMFLAG_ENDOFSTREAM) != 0) { if (sample != null) Marshal.ReleaseComObject(sample); break; }
                if (sample == null) continue;
                IAfxMediaBuffer buf;
                sample.ConvertToContiguousBuffer(out buf);
                IntPtr p; int max, cur;
                buf.Lock(out p, out max, out cur);
                var tmp = new short[cur / 2];
                Marshal.Copy(p, tmp, 0, tmp.Length);
                outBuf.AddRange(tmp);
                buf.Unlock();
                Marshal.ReleaseComObject(buf);
                Marshal.ReleaseComObject(sample);
            }
            Marshal.ReleaseComObject(rd);
            MFShutdown();
            return outBuf.ToArray();
        }

        // One comb filter: a delay line fed back on itself. Mutually prime lengths across the
        // bank stop the repeats from lining up, which is what makes a reverb ring on a note.
        class Comb
        {
            readonly float[] buf; int idx; readonly float fb;
            public Comb(int n, float feedback) { buf = new float[n]; fb = feedback; }
            public float Run(float x)
            {
                float y = buf[idx];
                buf[idx] = x + y * fb;
                if (++idx >= buf.Length) idx = 0;
                return y;
            }
        }

        // Allpass: flat magnitude response, but it smears phase, which turns the combs'
        // discrete echoes into something continuous.
        class Allpass
        {
            readonly float[] buf; int idx; const float g = 0.5f;
            public Allpass(int n) { buf = new float[n]; }
            public float Run(float x)
            {
                float y = buf[idx];
                buf[idx] = x + y * g;
                if (++idx >= buf.Length) idx = 0;
                return y - x;
            }
        }

        /// <summary>Schroeder reverb, in place. rt60 in seconds, wet 0..1.</summary>
        public static void Reverb(short[] pcm, int rate, int channels, double rt60, double wet)
        {
            // Mutually prime delays, scaled from the classic 44.1 kHz values.
            int[] combMs = { 1116, 1188, 1277, 1356 };
            int[] apMs   = { 225, 556 };
            double scale = rate / 44100.0;

            for (int ch = 0; ch < channels; ch++)
            {
                var combs = new Comb[combMs.Length];
                for (int i = 0; i < combMs.Length; i++)
                {
                    // stereo spread: nudge the right channel's delays so the two differ
                    int n = (int)(combMs[i] * scale) + (ch == 1 ? 23 : 0);
                    double delaySec = n / (double)rate;
                    float fb = (float)Math.Pow(10.0, -3.0 * delaySec / rt60);
                    combs[i] = new Comb(n, fb);
                }
                var aps = new Allpass[apMs.Length];
                for (int i = 0; i < apMs.Length; i++) aps[i] = new Allpass((int)(apMs[i] * scale) + (ch == 1 ? 11 : 0));

                for (int s = ch; s < pcm.Length; s += channels)
                {
                    float dry = pcm[s] / 32768f;
                    float acc = 0f;
                    for (int i = 0; i < combs.Length; i++) acc += combs[i].Run(dry);
                    acc /= combs.Length;
                    for (int i = 0; i < aps.Length; i++) acc = aps[i].Run(acc);
                    float mixed = (float)((1.0 - wet) * dry + wet * acc);
                    // Clip rather than wrap: a wrapped sample is a loud click, and reverb
                    // tails are exactly where the sum can nudge past full scale.
                    if (mixed > 0.999f) mixed = 0.999f; else if (mixed < -0.999f) mixed = -0.999f;
                    pcm[s] = (short)(mixed * 32767f);
                }
            }
        }

        /// <summary>Append silence so the reverb tail is not cut off at the end of the file.</summary>
        public static short[] Pad(short[] pcm, int rate, int channels, double seconds)
        {
            var outp = new short[pcm.Length + (int)(rate * seconds) * channels];
            Array.Copy(pcm, outp, pcm.Length);
            return outp;
        }

        public static void WriteWav(string path, short[] pcm, int rate, int channels)
        {
            using (var fs = new FileStream(path, FileMode.Create))
            using (var w = new BinaryWriter(fs))
            {
                int dataBytes = pcm.Length * 2;
                w.Write(new char[] { 'R', 'I', 'F', 'F' });
                w.Write(36 + dataBytes);
                w.Write(new char[] { 'W', 'A', 'V', 'E' });
                w.Write(new char[] { 'f', 'm', 't', ' ' });
                w.Write(16);
                w.Write((short)1);                       // PCM
                w.Write((short)channels);
                w.Write(rate);
                w.Write(rate * channels * 2);            // byte rate
                w.Write((short)(channels * 2));          // block align
                w.Write((short)16);
                w.Write(new char[] { 'd', 'a', 't', 'a' });
                w.Write(dataBytes);
                foreach (short s in pcm) w.Write(s);
            }
        }
    }
}
