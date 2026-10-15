// HostView.cs -- TIER A, STAGE 1: drive the view-injection path CONTINUOUSLY.
//
// The injection mechanism itself is already proven: a host-filled staging buffer in
// the guest's heap, copied into the 3D surface by AztInjBody once per guest frame,
// at a measured 1.5% cost. What has NEVER been tested is the LOOP -- a host process
// producing a frame every frame, indefinitely, while the game runs. The recorded
// gaps were exactly that: "continuous per-frame rendering and its latency" and "a
// host renderer that must not tear still needs a sync mechanism".
//
// So this stage deliberately does NOT render the game's geometry. It generates a
// synthetic frame that makes latency and tearing VISIBLE and MEASURABLE, and
// answers three questions before a single triangle is rasterised:
//
//   1. how many frames a second can the host actually push through the bridge?
//   2. what does the guest observe, and does raising its cap change that?
//   3. does an un-synchronised writer tear, and how badly?
//
// Building a rasteriser first would mean discovering the answer to (3) after weeks
// of work instead of minutes.
//
// WHY C#. One frame is 1600*928 = 1,484,800 bytes. PowerShell cannot fill that per
// frame -- a per-pixel loop there runs at a few hundred thousand elements a second,
// so a single frame would take seconds. The fill and the WriteProcessMemory both
// have to live on this side; PowerShell drives and reports.
//
// THE PATTERN IS A MEASURING INSTRUMENT, not decoration:
//   * a vertical bar sweeping left to right once a second -- judder and latency are
//     obvious on a moving edge, and invisible on a static image
//   * a per-row SEQUENCE byte in column 0..3, so a frame assembled from two
//     different host writes can be DETECTED rather than squinted at: any row whose
//     sequence differs from row 0's is a torn row
//   * a 64 px grid, which shears visibly if the stride is ever wrong (the same
//     failure mode that sheared the opening movie)
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace AztTool
{
    public class HostView
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int len, out IntPtr written);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int len, out IntPtr read);

        const int PROCESS_VM_READ = 0x0010, PROCESS_VM_WRITE = 0x0020, PROCESS_VM_OPERATION = 0x0008;
        const int PROCESS_QUERY_INFORMATION = 0x0400;

        readonly IntPtr _h;
        readonly int _w, _h2;
        readonly long _buf;          // host address of the guest staging buffer
        readonly byte[] _frame;

        // Palette indices to draw with. Supplied by the caller from the CAPTURED game
        // palette -- never guessed. 0 and 255 are BOTH BLACK in this game and three
        // separate probes have been wasted on that, so the caller is expected to have
        // excluded them; this only refuses the obvious case.
        byte _ink, _dim, _grid;
        int _markCol;

        public long HostFrames;
        public long WriteFailures;

        public HostView(int pid, long bufHostAddr, int w, int h, byte ink, byte dim, byte grid)
        {
            if (w <= 0 || h <= 0) throw new ArgumentException("bad frame size");
            if (ink == 0 || dim == 0 || grid == 0) throw new ArgumentException("index 0 is black -- pass real captured indices");
            _h = OpenProcess(PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION | PROCESS_QUERY_INFORMATION, false, pid);
            if (_h == IntPtr.Zero) throw new InvalidOperationException("OpenProcess failed: " + Marshal.GetLastWin32Error());
            _w = w; _h2 = h; _buf = bufHostAddr;
            _frame = new byte[w * h];
            _ink = ink; _dim = dim; _grid = grid;
            _markCol = (w / 2) & ~3;   // mid-row, dword-aligned
        }

        public int MarkCol { get { return _markCol; } }

        public void Close() { if (_h != IntPtr.Zero) CloseHandle(_h); if (_timer != IntPtr.Zero) { CloseHandle(_timer); _timer = IntPtr.Zero; } }

        public uint ReadU32(long hostAddr)
        {
            byte[] b = new byte[4]; IntPtr got;
            if (!ReadProcessMemory(_h, (IntPtr)hostAddr, b, 4, out got)) return 0;
            return BitConverter.ToUInt32(b, 0);
        }

        /// <summary>A block of the game's memory through this session's open handle; null if it
        /// cannot be read (the game has gone).</summary>
        public byte[] ReadBytes(long hostAddr, int len)
        {
            byte[] b = new byte[len]; IntPtr got;
            if (!ReadProcessMemory(_h, (IntPtr)hostAddr, b, len, out got) || (long)got != len) return null;
            return b;
        }

        public bool WriteU32(long hostAddr, uint v)
        {
            IntPtr put;
            return WriteProcessMemory(_h, (IntPtr)hostAddr, BitConverter.GetBytes(v), 4, out put);
        }

        // ---- THE HANDSHAKE WAIT, IN ONE CALL (2026-10-13 performance audit) ----------------------
        // The watcher polled aztInjReady from script: a function call, a handle read and a
        // Thread.Sleep(1) that overshoots to ~2 ms at a 1 ms timer period. Here the poll is a
        // high-resolution waitable timer at PollUs (Windows 10 1803+; Sleep(1) where it is not
        // offered). STILL A SLEEP, NEVER A SPIN: DOSBox emulates on one thread, and a tight
        // ReadProcessMemory loop starves it -- the game stops answering input.
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateWaitableTimerExW(IntPtr attrs, string name, uint flags, uint access);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetWaitableTimer(IntPtr h, ref long due, int period, IntPtr fn, IntPtr arg, bool resume);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr h, uint ms);
        const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x2, TIMER_ALL_ACCESS = 0x1F0003;
        IntPtr _timer; bool _timerTried;
        /// <summary>How long one poll of the wait sleeps, in microseconds (250-500 is the audit's range).</summary>
        public int PollUs = 400;
        /// <summary>True when the waits use the high-resolution timer (false: Thread.Sleep(1)).</summary>
        public bool FineTimer { get { return _timer != IntPtr.Zero; } }
        void Nap()
        {
            if (!_timerTried) { _timerTried = true; try { _timer = CreateWaitableTimerExW(IntPtr.Zero, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS); } catch { _timer = IntPtr.Zero; } }
            if (_timer != IntPtr.Zero)
            {
                long due = -10L * Math.Max(100, PollUs);          // relative, in 100 ns units
                if (SetWaitableTimer(_timer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false)) { WaitForSingleObject(_timer, 50); return; }
            }
            Thread.Sleep(1);
        }
        /// <summary>Wait for the dword at readyHostAddr to read 0, polling with a sleep; false when
        /// timeoutMs passed first (the caller skips the frame -- it never writes over a copy).</summary>
        public bool WaitClear(long readyHostAddr, int timeoutMs)
        {
            if (ReadU32(readyHostAddr) == 0) return true;
            long t0 = Stopwatch.GetTimestamp(), lim = (long)(timeoutMs * (double)Stopwatch.Frequency / 1000.0);
            while (true)
            {
                if (Stopwatch.GetTimestamp() - t0 > lim) return false;
                Nap();
                if (ReadU32(readyHostAddr) == 0) return true;
            }
        }

        // ---- ONE SNAPSHOT OF THE GUEST'S HOT WORDS PER FRAME (2026-10-13 performance audit) ----
        // The frame loop read ~15-25 single words (menus, the fold-out block, conversation, ammo,
        // weapon, cursor), each a script call and a process read. The blocks they sit in are read
        // here once (Take), and served from the copy. Addresses are BUILT obj2 linear; host =
        // base + lin, with base = MemBase + the obj2 delta for this attach. Anything outside the
        // blocks, or in a block whose read failed, is read live. Writes go to the game at once
        // (WriteSnap) and into the copy, so a later read in the same frame sees them.
        long _snapBase; uint[] _snapLin; byte[][] _snapBuf; bool[] _snapOk;
        public void SnapInit(long baseHost, uint[] lins, int[] lens)
        {
            _snapBase = baseHost; _snapLin = (uint[])lins.Clone();
            _snapBuf = new byte[lins.Length][]; _snapOk = new bool[lins.Length];
            for (int i = 0; i < lins.Length; i++) _snapBuf[i] = new byte[lens[i]];
        }
        /// <summary>Read every block once. Call at the top of the frame, and again where the
        /// freshest values matter (after the handshake wait, beside the camera read).</summary>
        public void SnapTake()
        {
            if (_snapLin == null) return;
            for (int i = 0; i < _snapLin.Length; i++)
            {
                IntPtr got; byte[] b = _snapBuf[i];
                _snapOk[i] = ReadProcessMemory(_h, (IntPtr)(_snapBase + _snapLin[i]), b, b.Length, out got) && (long)got == b.Length;
            }
        }
        int SnapAt(uint lin, int len, out int off)
        {
            off = 0; if (_snapLin == null) return -1;
            for (int i = 0; i < _snapLin.Length; i++)
            {
                long o = (long)lin - _snapLin[i];
                if (o >= 0 && o + len <= _snapBuf[i].Length) { if (!_snapOk[i]) return -1; off = (int)o; return i; }
            }
            return -1;
        }
        /// <summary>A signed word at a built obj2 address: from the snapshot, else live; null when unreadable.</summary>
        public short? SnapWord(uint lin)
        {
            int off; int i = SnapAt(lin, 2, out off);
            if (i >= 0) return BitConverter.ToInt16(_snapBuf[i], off);
            byte[] b = ReadBytes(_snapBase + lin, 2); if (b == null) return null;
            return BitConverter.ToInt16(b, 0);
        }
        /// <summary>A dword at a built obj2 address: from the snapshot, else live (0 when unreadable, as ReadU32).</summary>
        public uint SnapU32(uint lin)
        {
            int off; int i = SnapAt(lin, 4, out off);
            if (i >= 0) return BitConverter.ToUInt32(_snapBuf[i], off);
            return ReadU32(_snapBase + lin);
        }
        /// <summary>A copy of len bytes at a built obj2 address: from the snapshot, else live; null when unreadable.</summary>
        public byte[] SnapBytes(uint lin, int len)
        {
            int off; int i = SnapAt(lin, len, out off);
            if (i >= 0) { var r = new byte[len]; Buffer.BlockCopy(_snapBuf[i], off, r, 0, len); return r; }
            return ReadBytes(_snapBase + lin, len);
        }
        /// <summary>Write to the game now (a data write) and into the snapshot's copy.</summary>
        public bool WriteSnap(uint lin, byte[] data)
        {
            IntPtr put;
            bool ok = WriteProcessMemory(_h, (IntPtr)(_snapBase + lin), data, data.Length, out put) && (long)put == data.Length;
            int off; int i = SnapAt(lin, data.Length, out off);
            if (ok && i >= 0) Buffer.BlockCopy(data, 0, _snapBuf[i], off, data.Length);
            return ok;
        }

        // Fill the frame for a given phase (0..1 of the sweep) and sequence number.
        // Written as a row loop over a flat byte[]: the whole point is that this is
        // native-speed work, so there is no cleverness to be had and clarity wins.
        public void Compose(double phase, byte seq)
        {
            int barX = (int)(phase * (_w - 1));
            int barHalf = Math.Max(2, _w / 160);
            for (int y = 0; y < _h2; y++)
            {
                int row = y * _w;
                // A dim vertical gradient, so the frame is unmistakably host-drawn
                // even when the bar is off-screen.
                byte bg = (byte)(((y * 4) / _h2) == 0 ? _dim : _dim);
                for (int x = 0; x < _w; x++) _frame[row + x] = bg;
                // the 64 px grid -- a stride error turns these into diagonals
                if ((y & 63) < 2) { for (int x = 0; x < _w; x++) _frame[row + x] = _grid; }
                else { for (int x = 0; x < _w; x += 64) { _frame[row + x] = _grid; if (x + 1 < _w) _frame[row + x + 1] = _grid; } }
                // the sweeping bar
                int x0 = Math.Max(0, barX - barHalf), x1 = Math.Min(_w - 1, barX + barHalf);
                for (int x = x0; x <= x1; x++) _frame[row + x] = _ink;
                // THE TEAR DETECTOR: this frame's sequence number, four columns wide,
                // in the MIDDLE of the row.
                //
                // It used to be at columns 0..3 and that made the measurement wrong.
                // The game draws its own widgets over the viewport AFTER our injection
                // -- automap, status gauge, scan readout, reticle, all at hard-coded
                // screen coords -- which is the property the whole hybrid depends on.
                // At the left edge and in the top and bottom rows that overdraw lands
                // exactly on the marker, so a correct, untorn frame still read as
                // "torn" on most rows. Measured: rows 300/500/700 carried the right
                // sequence while rows 0/1/900/927 carried the game's own indices.
                //
                // Four adjacent columns, all required to agree, mid-frame where no
                // widget draws: the game would have to lay down a 4-wide run of
                // exactly our current sequence value to fool it.
                int m = _markCol;
                _frame[row + m] = seq; _frame[row + m + 1] = seq;
                _frame[row + m + 2] = seq; _frame[row + m + 3] = seq;
            }
        }

        public long PushFailStreak;
        public bool GameExited;

        // Push an EXTERNALLY produced frame -- the rasteriser's colour buffer -- straight
        // into the guest, with no intermediate copy. The renderer and this class each
        // own a 1.48 MB buffer already; copying between them every frame would be 1.48 MB
        // of pure waste per frame for nothing.
        public bool PushFrame(byte[] frame)
        {
            if (frame == null || frame.Length != _frame.Length)
                throw new ArgumentException("frame is " + (frame == null ? 0 : frame.Length) + " bytes, expected " + _frame.Length);
            IntPtr put;
            bool ok = WriteProcessMemory(_h, (IntPtr)_buf, frame, frame.Length, out put);
            if (!ok || (long)put != frame.Length)
            {
                WriteFailures++; PushFailStreak++;
                if (PushFailStreak >= 32) GameExited = true;
                return false;
            }
            PushFailStreak = 0; HostFrames++;
            return true;
        }

        public bool Push()
        {
            IntPtr put;
            bool ok = WriteProcessMemory(_h, (IntPtr)_buf, _frame, _frame.Length, out put);
            if (!ok || (long)put != _frame.Length)
            {
                WriteFailures++; PushFailStreak++;
                // A RUN OF FAILURES MEANS THE GAME IS GONE, and the loop must say so
                // rather than spinning. A 90 s run once ended with 2,319 "write
                // failures" and NEGATIVE frame counters, because once the process dies
                // every read returns 0 and every delta goes backwards -- output that
                // looked like a catastrophic fault when the game had simply been
                // closed. Numbers that cannot be true are worse than no numbers.
                if (PushFailStreak >= 32) GameExited = true;
                return false;
            }
            PushFailStreak = 0;
            HostFrames++;
            return true;
        }

        // Run the loop for `ms` milliseconds at a target rate. targetFps <= 0 means
        // "as fast as possible", which is what measures the bridge's own ceiling.
        public void Run(int ms, double targetFps)
        {
            Stopwatch sw = Stopwatch.StartNew();
            double periodMs = targetFps > 0 ? 1000.0 / targetFps : 0;
            long next = 0;
            byte seq = 1;
            while (sw.ElapsedMilliseconds < ms)
            {
                double t = sw.Elapsed.TotalSeconds;
                Compose(t - Math.Floor(t), seq);
                if (!Push() && GameExited) break;
                // seq cycles 1..254: 0 and 255 are avoided so a sequence byte can
                // never be confused with the game's own black.
                seq = (byte)(seq >= 254 ? 1 : seq + 1);
                if (periodMs > 0)
                {
                    next += (long)periodMs;
                    long wait = next - sw.ElapsedMilliseconds;
                    if (wait > 0) Thread.Sleep((int)wait);
                }
            }
        }

        public long SyncWaits, SyncTimeouts;

        // THE SYNCHRONISED LOOP (stage A2). One frame, one copy:
        //
        //   fill the buffer -> set ready -> wait for the guest to clear it -> repeat
        //
        // The guest copies only while ready is set and clears it on the way out, so
        // the host is never writing the buffer the guest is reading. That is the whole
        // fix for the 4%-to-91% tearing the unsynchronised loop measured.
        //
        // The host is PACED BY THE GUEST here, deliberately. Pushing faster than the
        // game can consume produced nothing but torn rows, so the achieved rate in
        // this mode IS the guest's frame rate, and that is the number worth having.
        //
        // The wait spins with a yield rather than Thread.Sleep(1): a guest frame at
        // 400 fps is 2.5 ms and the scheduler's 1 ms granularity would quantise it
        // badly. `timeoutMs` stops a paused or dead game from hanging the loop
        // forever -- on timeout the frame is abandoned, not forced, because forcing it
        // would mean writing the buffer mid-copy, which is the thing being avoided.
        public void RunSynced(int ms, long readyHostAddr, int timeoutMs)
        {
            Stopwatch sw = Stopwatch.StartNew();
            byte seq = 1;
            while (sw.ElapsedMilliseconds < ms)
            {
                // Wait for the previous frame to be consumed BEFORE touching the
                // buffer. On the first pass ready is already 0, so this falls straight
                // through.
                long waitStart = sw.ElapsedMilliseconds;
                bool timedOut = false, ranOut = false;
                while (ReadU32(readyHostAddr) != 0)
                {
                    // RUNNING OUT OF TIME IS NOT A TIMEOUT. Counting it as one made
                    // every single run report "the guest stopped consuming", because
                    // the loop always ends mid-wait -- a warning that fires every time
                    // is worse than no warning.
                    if (sw.ElapsedMilliseconds >= ms) { ranOut = true; break; }
                    if (sw.ElapsedMilliseconds - waitStart > timeoutMs) { timedOut = true; break; }
                    SyncWaits++;
                    Thread.Yield();
                }
                if (ranOut) break;
                if (timedOut) { SyncTimeouts++; continue; }

                double t = sw.Elapsed.TotalSeconds;
                Compose(t - Math.Floor(t), seq);
                if (!Push()) { if (GameExited) break; continue; }
                seq = (byte)(seq >= 254 ? 1 : seq + 1);
                // The baton goes over LAST, after every byte of the frame is in place.
                WriteU32(readyHostAddr, 1);
            }
            if (GameExited) return;
            // Leave it consumed so the guest is not left waiting on a frame that will
            // never be refreshed.
            WriteU32(readyHostAddr, 0);
        }

        // Read what the game is actually SHOWING and decide whether it is torn.
        //
        // ONE SNAPSHOT, not a read per row. The previous version issued a separate
        // ReadProcessMemory for every row, so the game kept drawing BETWEEN the reads
        // and rows sampled milliseconds apart were compared as though they were
        // simultaneous. That manufactures disagreement. The whole surface comes across
        // in one call now, so every row in the sample is from the same instant.
        //
        // A row counts only if all four marker columns agree -- otherwise the game has
        // drawn over the marker and the row says nothing about tearing.
        //
        // CONTIGUITY IS THE REAL DISCRIMINATOR. A genuine tear is the guest copying
        // while the host writes, which splits the frame at ONE row: everything above
        // from one host frame, everything below from another, so exactly one
        // transition. Scattered disagreement across many transitions is not tearing,
        // it is overdraw or a bad sample. Reporting the transition COUNT distinguishes
        // the two; a single "% of rows differ" figure cannot.
        //
        // Returns: counted, skipped, distinct, transitions, mode, modeCount
        public int[] VerifySnapshot(long surfHost, int stride, int rows)
        {
            int len = stride * rows;
            byte[] surf = new byte[len];
            IntPtr got;
            if (!ReadProcessMemory(_h, (IntPtr)surfHost, surf, len, out got) || (long)got != len)
                return new int[] { 0, 0, 0, 0, 0, 0 };

            int m = _markCol;
            byte[] seqOf = new byte[rows];
            bool[] valid = new bool[rows];
            int counted = 0, skipped = 0;
            for (int y = 0; y < rows; y++)
            {
                int row = y * stride;
                byte a = surf[row + m], b = surf[row + m + 1], c = surf[row + m + 2], d = surf[row + m + 3];
                if (a == b && b == c && c == d && a != 0) { seqOf[y] = a; valid[y] = true; counted++; }
                else skipped++;
            }

            int[] hist = new int[256];
            for (int y = 0; y < rows; y++) if (valid[y]) hist[seqOf[y]]++;
            int mode = 0, modeCount = 0, distinct = 0;
            for (int i = 0; i < 256; i++)
            {
                if (hist[i] == 0) continue;
                distinct++;
                if (hist[i] > modeCount) { modeCount = hist[i]; mode = i; }
            }

            int transitions = 0; int prev = -1;
            for (int y = 0; y < rows; y++)
            {
                if (!valid[y]) continue;
                if (prev >= 0 && seqOf[y] != prev) transitions++;
                prev = seqOf[y];
            }
            return new int[] { counted, skipped, distinct, transitions, mode, modeCount };
        }
    }
}
