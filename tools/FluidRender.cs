// FluidRender.cs -- render a .mid to .wav through a soundfont, offline.
//
// Judging a soundfont swap inside the game is nearly impossible: you have to be
// standing in the right room for the right cue, the music is quiet under the
// ambience, and you cannot hear the two banks back to back. This drives the SAME
// FluidSynth that DOSBox Staging uses -- libfluidsynth-3.dll out of the Staging
// folder -- so what comes out is what the game would play, and two renders of
// the same track through different soundfonts are directly comparable.
//
// It renders by hand with fluid_synth_write_s16 rather than using FluidSynth's
// own file renderer, because that path wants libsndfile and its availability
// varies by build; writing the RIFF header here has no dependencies at all.
//
// The DLL lives beside its own dependencies (glib, iconv, intl, pcre2), so the
// caller must SetDllDirectory to the Staging folder before the first call or
// the load fails with a bare "module not found".
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace AztTool
{
    public static class FluidRender
    {
        const string LIB = "libfluidsynth-3.dll";

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool SetDllDirectory(string path);

        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr new_fluid_settings();
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern void delete_fluid_settings(IntPtr s);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern int fluid_settings_setnum(IntPtr s, string name, double val);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern int fluid_settings_setint(IntPtr s, string name, int val);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr new_fluid_synth(IntPtr s);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern void delete_fluid_synth(IntPtr syn);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern int fluid_synth_sfload(IntPtr syn, string path, int reset);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr new_fluid_player(IntPtr syn);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern void delete_fluid_player(IntPtr p);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern int fluid_player_add(IntPtr p, string mid);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern int fluid_player_play(IntPtr p);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)] static extern int fluid_player_get_status(IntPtr p);
        [DllImport(LIB, CallingConvention = CallingConvention.Cdecl)]
        static extern int fluid_synth_write_s16(IntPtr syn, int len, short[] lo, int loff, int linc,
                                                                    short[] ro, int roff, int rinc);

        const int FLUID_PLAYER_DONE = 3;

        /// <summary>Render midPath through sfPath into wavPath. Stops at
        /// maxSeconds so a looping cue cannot render forever.</summary>
        public static string Render(string stagingDir, string sfPath, string midPath, string wavPath,
                                    int maxSeconds, double revRoom, double revDamp,
                                    double revWidth, double revLevel)
        {
            SetDllDirectory(stagingDir);
            const int RATE = 44100;

            IntPtr set = new_fluid_settings();
            if (set == IntPtr.Zero) return "new_fluid_settings failed";
            fluid_settings_setnum(set, "synth.sample-rate", RATE);
            fluid_settings_setint(set, "synth.reverb.active", 1);
            fluid_settings_setint(set, "synth.chorus.active", 1);
            // Match azrael-staging.conf so the render is what the game would play.
            fluid_settings_setnum(set, "synth.reverb.room-size", revRoom);
            fluid_settings_setnum(set, "synth.reverb.damp",      revDamp);
            fluid_settings_setnum(set, "synth.reverb.width",     revWidth);
            fluid_settings_setnum(set, "synth.reverb.level",     revLevel);

            IntPtr syn = new_fluid_synth(set);
            if (syn == IntPtr.Zero) { delete_fluid_settings(set); return "new_fluid_synth failed"; }
            if (fluid_synth_sfload(syn, sfPath, 1) == -1)
            {
                delete_fluid_synth(syn); delete_fluid_settings(set);
                return "could not load soundfont: " + sfPath;
            }

            IntPtr pl = new_fluid_player(syn);
            if (pl == IntPtr.Zero) { delete_fluid_synth(syn); delete_fluid_settings(set); return "new_fluid_player failed"; }
            if (fluid_player_add(pl, midPath) != 0)
            {
                delete_fluid_player(pl); delete_fluid_synth(syn); delete_fluid_settings(set);
                return "could not read midi: " + midPath;
            }
            fluid_player_play(pl);

            const int BLOCK = 4096;                 // frames per pull
            var buf = new short[BLOCK * 2];         // interleaved stereo
            long maxFrames = (long)maxSeconds * RATE;
            long done = 0;

            using (var fs = new FileStream(wavPath, FileMode.Create, FileAccess.Write))
            using (var bw = new BinaryWriter(fs))
            {
                for (int i = 0; i < 44; i++) bw.Write((byte)0);   // header patched at the end

                while (done < maxFrames)
                {
                    if (fluid_synth_write_s16(syn, BLOCK, buf, 0, 2, buf, 1, 2) != 0) break;
                    var bytes = new byte[BLOCK * 4];
                    Buffer.BlockCopy(buf, 0, bytes, 0, bytes.Length);
                    bw.Write(bytes);
                    done += BLOCK;
                    if (fluid_player_get_status(pl) == FLUID_PLAYER_DONE) break;
                }

                long dataLen = done * 4;
                bw.Flush();
                fs.Seek(0, SeekOrigin.Begin);
                bw.Write(new char[] { 'R', 'I', 'F', 'F' });
                bw.Write((int)(36 + dataLen));
                bw.Write(new char[] { 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' });
                bw.Write(16);                    // fmt chunk size
                bw.Write((short)1);              // PCM
                bw.Write((short)2);              // stereo
                bw.Write(RATE);
                bw.Write(RATE * 4);              // byte rate
                bw.Write((short)4);              // block align
                bw.Write((short)16);             // bits
                bw.Write(new char[] { 'd', 'a', 't', 'a' });
                bw.Write((int)dataLen);
            }

            delete_fluid_player(pl);
            delete_fluid_synth(syn);
            delete_fluid_settings(set);
            return null;                         // success
        }
    }
}
