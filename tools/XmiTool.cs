// XmiTool.cs -- Miles XMIDI (.XMI) -> Standard MIDI File (.MID).
//
// Azrael's music is 24 .XMI sequences and nothing else -- no CD audio, no
// streamed score. They cannot be played by anything on a modern box, which
// makes it impossible to audition what the game is actually loading. This
// converts them so they can be.
//
// THE TWO WAYS XMI DIFFERS FROM AN SMF, both of which this has to undo:
//
//  1. DELTA TIMES ARE SUMMED BYTES, not a variable-length quantity. Every byte
//     with the high bit CLEAR adds its own value to the delay; the first byte
//     with the high bit SET is the event's status. (A standard VLQ is still
//     used for meta/sysex lengths and for note durations, so both readers are
//     needed and they are NOT interchangeable.)
//
//  2. THERE ARE NO NOTE-OFFS. A note-on carries a duration after its velocity,
//     and the note-off has to be synthesised and scheduled at note+duration.
//     That is why the converter cannot stream: events come out of order, so
//     everything is collected with absolute ticks and sorted at the end.
//
// Timebase: Miles XMI runs on a fixed clock of 120 ticks/second. Writing the
// SMF at 60 ticks per quarter-note with a 500,000 us/qn tempo reproduces that
// exactly (60 / 0.5s = 120).
//
// EMBEDDED TEMPO CHANGES ARE DROPPED, and passing them through was a real bug.
// The 120 Hz clock is fixed: a delay of N is N/120 of a second whatever any tempo
// meta event claims. Miles stores those events but does not pace playback with
// them, so copying one into the SMF makes a standard player honour a tempo the
// game ignores. INGAME.XMI carries 359,280 us/qn, which against 60 PPQN gives
// 167 ticks/sec rather than 120 -- exports ran 39% fast.
//
// One .XMI can hold several sequences (a CAT/FORM chain), so every EVNT chunk
// in the file is emitted as its own .MID. Scanning for EVNT rather than walking
// the IFF tree keeps this robust against the header variations in the set.
using System;
using System.Collections.Generic;
using System.IO;

namespace AztTool
{
    public class XmiEvent
    {
        public long Tick;
        public int  Order;      // note-offs sort before other events at the same tick
        public byte[] Data;
    }

    public static class Xmi
    {
        static bool Match(byte[] b, int p, string id)
        {
            if (p < 0 || p + 4 > b.Length) return false;
            for (int i = 0; i < 4; i++) if (b[p + i] != (byte)id[i]) return false;
            return true;
        }

        static int BE32(byte[] b, int p)
        {
            return (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
        }

        // Standard MIDI variable-length quantity -- used for meta/sysex lengths
        // and for the note duration. NOT the same as the delay reader below.
        static int ReadVlq(byte[] b, ref int p)
        {
            int v = 0;
            while (p < b.Length)
            {
                byte c = b[p++];
                v = (v << 7) | (c & 0x7F);
                if ((c & 0x80) == 0) break;
            }
            return v;
        }

        // XMI delay: sum every byte whose high bit is clear.
        static long ReadDelay(byte[] b, ref int p)
        {
            long d = 0;
            while (p < b.Length && b[p] < 0x80) d += b[p++];
            return d;
        }

        static void WriteVlq(List<byte> o, long v)
        {
            long buf = v & 0x7F;
            while ((v >>= 7) > 0) { buf <<= 8; buf |= 0x80; buf += (v & 0x7F); }
            while (true)
            {
                o.Add((byte)(buf & 0xFF));
                if ((buf & 0x80) != 0) buf >>= 8; else break;
            }
        }

        /// <summary>Convert one .XMI into one .MID per sequence it contains.
        /// Returns the paths written.</summary>
        public static List<string> Convert(string xmiPath, string outDir)
        {
            byte[] b = File.ReadAllBytes(xmiPath);
            string stem = Path.GetFileNameWithoutExtension(xmiPath);
            var written = new List<string>();
            int seq = 0;

            for (int p = 0; p + 8 <= b.Length; p++)
            {
                if (!Match(b, p, "EVNT")) continue;
                int len = BE32(b, p + 4);
                int start = p + 8;
                if (len <= 0 || start + len > b.Length) continue;

                byte[] mid = ConvertEvnt(b, start, start + len);
                string name = (seq == 0) ? stem + ".mid" : stem + "_" + seq + ".mid";
                string dest = Path.Combine(outDir, name);
                File.WriteAllBytes(dest, mid);
                written.Add(dest);
                seq++;
                p = start + len - 1;   // skip past this chunk
            }
            return written;
        }

        static byte[] ConvertEvnt(byte[] b, int p, int end)
        {
            var evts = new List<XmiEvent>();
            long abs = 0;

            while (p < end)
            {
                abs += ReadDelay(b, ref p);
                if (p >= end) break;
                byte status = b[p++];

                if (status == 0xFF)
                {
                    if (p >= end) break;
                    byte type = b[p++];
                    int n = ReadVlq(b, ref p);
                    if (p + n > end) n = Math.Max(0, end - p);
                    var d = new List<byte> { 0xFF, type };
                    WriteVlq(d, n);
                    for (int i = 0; i < n; i++) d.Add(b[p + i]);
                    p += n;
                    // DROP XMI TEMPO EVENTS -- do not pass them through.
                    //
                    // XMIDI's sequencer clock is FIXED at 120 Hz: a delay of N is
                    // N/120 of a second no matter what any tempo meta event says.
                    // Miles stores those events but does not pace playback with
                    // them, so copying one into the SMF makes a standard player
                    // honour a tempo the game ignores. INGAME.XMI carries 359,280
                    // us/qn, which against 60 PPQN is 167 ticks/sec instead of 120
                    // -- the export ran 39% fast, and that is exactly the symptom
                    // it was reported with.
                    if (type == 0x51) continue;
                    if (type == 0x2F) break;               // end of track: we write our own
                    evts.Add(new XmiEvent { Tick = abs, Order = 1, Data = d.ToArray() });
                }
                else if (status == 0xF0 || status == 0xF7)
                {
                    int n = ReadVlq(b, ref p);
                    if (p + n > end) n = Math.Max(0, end - p);
                    var d = new List<byte> { status };
                    WriteVlq(d, n);
                    for (int i = 0; i < n; i++) d.Add(b[p + i]);
                    p += n;
                    evts.Add(new XmiEvent { Tick = abs, Order = 1, Data = d.ToArray() });
                }
                else if (status >= 0x80)
                {
                    int hi = status & 0xF0;
                    if (hi == 0x90)
                    {
                        // note on + DURATION -- synthesise the note-off
                        if (p + 1 >= end) break;
                        byte note = b[p++], vel = b[p++];
                        int dur = ReadVlq(b, ref p);
                        evts.Add(new XmiEvent { Tick = abs, Order = 1,
                                                Data = new byte[] { status, note, vel } });
                        evts.Add(new XmiEvent { Tick = abs + dur, Order = 0,
                                                Data = new byte[] { (byte)(0x80 | (status & 0x0F)), note, 0x40 } });
                    }
                    else if (hi == 0xC0 || hi == 0xD0)
                    {
                        if (p >= end) break;
                        evts.Add(new XmiEvent { Tick = abs, Order = 1,
                                                Data = new byte[] { status, b[p] } });
                        p += 1;
                    }
                    else
                    {
                        if (p + 1 >= end) break;
                        evts.Add(new XmiEvent { Tick = abs, Order = 1,
                                                Data = new byte[] { status, b[p], b[p + 1] } });
                        p += 2;
                    }
                }
            }

            // XMI's clock is fixed at 120 Hz, and 60 PPQN at 500,000 us/qn is that
            // rate exactly (60 ticks / 0.5 s). ALWAYS write it -- the sequence's own
            // tempo events are dropped above, because the game does not pace itself
            // with them.
            evts.Add(new XmiEvent { Tick = 0, Order = -1,
                                    Data = new byte[] { 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20 } });

            evts.Sort((x, y) => x.Tick != y.Tick ? x.Tick.CompareTo(y.Tick)
                                                 : x.Order.CompareTo(y.Order));

            var track = new List<byte>();
            long last = 0;
            foreach (var e in evts)
            {
                WriteVlq(track, e.Tick - last);
                last = e.Tick;
                track.AddRange(e.Data);
            }
            WriteVlq(track, 0);
            track.AddRange(new byte[] { 0xFF, 0x2F, 0x00 });

            var o = new List<byte>();
            o.AddRange(new byte[] { 0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6 });   // MThd
            o.AddRange(new byte[] { 0, 0, 0, 1, 0, 60 });                    // format 0, 1 track, 60 PPQN
            o.AddRange(new byte[] { 0x4D, 0x54, 0x72, 0x6B });               // MTrk
            int tl = track.Count;
            o.AddRange(new byte[] { (byte)(tl >> 24), (byte)(tl >> 16), (byte)(tl >> 8), (byte)tl });
            o.AddRange(track);
            return o.ToArray();
        }
    }
}
