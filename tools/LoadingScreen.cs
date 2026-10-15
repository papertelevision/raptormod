// LoadingScreen.cs -- "Loading RaptorMod..." while the host renderer gets ready (Josh, 2026-10-07).
//
// The GPU version has to have hold of the game before the game's own boot starts, and a player
// who skips the intro movies gets there in a few seconds -- faster than the renderer could
// compile, find the game and open its window. So the renderer puts this up FIRST, starts the
// game behind it, and the game is held (suspended) from the moment it is found until the picture
// window and the host's boot are ready. Then this fades and the game carries on from where it
// was held: nothing of the intro is lost and nothing can be skipped past the renderer.
//
// Small white type and a thin bar on black, full screen, topmost, never takes the focus (keys go
// to DOSBox). Compiled ON ITS OWN, before the renderer's big compile, so it is up within a second.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Threading;

namespace AztTool
{
    // ---- THE LOADING SCREEN'S SOUND: a small stereo mixer (winmm waveOut) for the voice over the track ----------------
    // Its own, not BootHd's: this file is compiled on its own, within a second of launch. WAV only -- winmm's MCI MP3
    // device does not open on every Windows (it did not on the dev machine), so the track is shipped decoded.
    public sealed class LoadingAudio : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)] struct WaveFmt { public ushort Tag, Channels; public uint Rate, Bytes; public ushort Align, Bits, Extra; }
        [StructLayout(LayoutKind.Sequential)] struct WaveHdr { public IntPtr Data; public uint Length, Recorded; public IntPtr User; public uint Flags, Loops; public IntPtr Next, Reserved; }
        [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr h, uint dev, ref WaveFmt fmt, IntPtr cb, IntPtr inst, uint flags);
        [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveOutReset(IntPtr h);
        [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr h);
        const int Rate = 44100, NBuf = 4, Frames = 2048; const uint WHDR_DONE = 1;
        IntPtr _h; readonly IntPtr[] _hdr = new IntPtr[NBuf], _buf = new IntPtr[NBuf]; readonly bool[] _queued = new bool[NBuf];
        int _hdrSize, _flagsAt; Thread _th; volatile bool _run; readonly ManualResetEvent _done = new ManualResetEvent(false);
        float[] _voice, _track; int _vPos, _tPos; float _vGain, _tGain; volatile int _fadeLeft = -1; int _fadeLen = 1;
        public double VoiceSeconds { get { return _voice == null ? 0 : _voice.Length / 2.0 / Rate; } }
        public double TrackSeconds { get { return _track == null ? 0 : _track.Length / 2.0 / Rate; } }
        /// <summary>The voice has played to its end (or there is none).</summary>
        public bool VoiceDone
        {
            get
            {
                if (_voice == null) return true;
                if (Volatile.Read(ref _vPos) < _voice.Length) return false;
                // (the last of it is QUEUED then, not yet heard: wait out the buffers, NBuf x Frames ~ 0.19 s, and a little)
                if (_vEnd == null) _vEnd = Stopwatch.StartNew();
                return _vEnd.ElapsedMilliseconds > NBuf * Frames * 1000 / Rate + 60;
            }
        }
        Stopwatch _vEnd;
        public static LoadingAudio Play(string voicePath, string trackPath, double voiceGain, double trackGain, out string err) { return Play(voicePath, trackPath, voiceGain, trackGain, 0, out err); }
        /// <summary>voiceLowHz &gt; 0: the voice dulled above it (two gentle one-pole stages) -- further away.</summary>
        public static LoadingAudio Play(string voicePath, string trackPath, double voiceGain, double trackGain, double voiceLowHz, out string err)
        {
            err = null;
            try
            {
                var a = new LoadingAudio { _vGain = (float)voiceGain, _tGain = (float)trackGain };
                a._voice = voicePath != null && System.IO.File.Exists(voicePath) ? ReadWav(voicePath) : null;
                a._track = trackPath != null && System.IO.File.Exists(trackPath) ? ReadWav(trackPath) : null;
                if (a._voice == null && a._track == null) { err = "neither sound file was found"; return null; }
                if (a._voice != null && voiceLowHz > 0)
                {
                    double k = 1 - Math.Exp(-2 * Math.PI * voiceLowHz / Rate); double l1 = 0, l2 = 0, r1 = 0, r2 = 0; var v = a._voice;
                    for (int i = 0; i + 1 < v.Length; i += 2)
                    { l1 += k * (v[i] - l1); l2 += k * (l1 - l2); r1 += k * (v[i + 1] - r1); r2 += k * (r1 - r2); v[i] = (float)l2; v[i + 1] = (float)r2; }
                }
                var f = new WaveFmt { Tag = 1, Channels = 2, Rate = Rate, Bits = 16, Align = 4, Bytes = Rate * 4 };
                int r = waveOutOpen(out a._h, 0xFFFFFFFF, ref f, IntPtr.Zero, IntPtr.Zero, 0);
                if (r != 0) { err = "waveOutOpen failed: " + r; return null; }
                a._hdrSize = Marshal.SizeOf(typeof(WaveHdr)); a._flagsAt = (int)Marshal.OffsetOf(typeof(WaveHdr), "Flags");
                for (int i = 0; i < NBuf; i++) { a._buf[i] = Marshal.AllocHGlobal(Frames * 4); a._hdr[i] = Marshal.AllocHGlobal(a._hdrSize); }
                a._run = true; a._th = new Thread(a.Loop) { IsBackground = true, Name = "AztLoadingSound", Priority = ThreadPriority.AboveNormal }; a._th.Start();
                return a;
            }
            catch (Exception e) { err = e.Message; return null; }
        }
        /// <summary>Fade the track out over this long (the voice, if any is left, plays on).</summary>
        public void FadeTrack(double seconds) { _fadeLen = Math.Max(1, (int)(seconds * Rate)); _fadeLeft = _fadeLen; }
        /// <summary>The track starts over at its end (the title's music) -- until it is faded out.</summary>
        public volatile bool LoopTrack;
        /// <summary>The track comes up from silence over this long, from its start.</summary>
        public void FadeInTrack(double seconds) { _inLen = Math.Max(1, (int)(seconds * Rate)); _inPos = 0; }
        int _inLen, _inPos = int.MaxValue;
        public bool Wait(int ms) { return _done.WaitOne(ms); }
        // 16-bit PCM WAV to interleaved stereo floats at 44.1 kHz (mono doubled; another rate resampled linearly)
        static float[] ReadWav(string path)
        {
            var b = System.IO.File.ReadAllBytes(path); int p = 12, ch = 2, rate = Rate, bits = 16, data = -1, len = 0;
            while (p + 8 <= b.Length)
            {
                string id = System.Text.Encoding.ASCII.GetString(b, p, 4); int sz = BitConverter.ToInt32(b, p + 4);
                if (id == "fmt ") { ch = BitConverter.ToInt16(b, p + 10); rate = BitConverter.ToInt32(b, p + 12); bits = BitConverter.ToInt16(b, p + 22); }
                if (id == "data") { data = p + 8; len = Math.Min(sz, b.Length - data); break; }
                p += 8 + sz + (sz & 1);
            }
            if (data < 0 || bits != 16 || ch < 1) throw new Exception(path + ": not a 16-bit PCM WAV");
            int n = len / 2 / ch, m = (int)((long)n * Rate / rate); var o = new float[m * 2];
            for (int i = 0; i < m; i++)
            {
                int k = Math.Min(n - 1, (int)((long)i * rate / Rate));
                float l = BitConverter.ToInt16(b, data + (k * ch) * 2) / 32768f, r = ch > 1 ? BitConverter.ToInt16(b, data + (k * ch + 1) * 2) / 32768f : l;
                o[i * 2] = l; o[i * 2 + 1] = r;
            }
            return o;
        }
        void Loop()
        {
            var mix = new float[Frames * 2]; var pcm = new short[Frames * 2];
            try
            {
                while (_run)
                {
                    bool wrote = false;
                    for (int i = 0; i < NBuf; i++)
                    {
                        if (_queued[i] && (Marshal.ReadInt32(_hdr[i], _flagsAt) & WHDR_DONE) == 0) continue;
                        if (_queued[i]) { waveOutUnprepareHeader(_h, _hdr[i], _hdrSize); _queued[i] = false; }
                        bool vLeft = _voice != null && _vPos < _voice.Length, tLeft = _track != null && _tPos < _track.Length && _fadeLeft != 0;
                        if (!vLeft && !tLeft) { if (!AnyQueued()) { _run = false; break; } continue; }
                        Array.Clear(mix, 0, mix.Length);
                        if (vLeft) { int n = Math.Min(mix.Length, _voice.Length - _vPos); for (int k = 0; k < n; k++) mix[k] += _voice[_vPos + k] * _vGain; Volatile.Write(ref _vPos, _vPos + n); }
                        if (tLeft)
                        {
                            int n = Math.Min(mix.Length, _track.Length - _tPos);
                            for (int k = 0; k < n; k += 2)
                            {
                                float g = _tGain;
                                if (_inPos < _inLen) { g *= _inPos / (float)_inLen; _inPos++; }
                                if (_fadeLeft > 0) { g *= _fadeLeft / (float)_fadeLen; _fadeLeft--; }
                                else if (_fadeLeft == 0) g = 0;
                                mix[k] += _track[_tPos + k] * g; mix[k + 1] += _track[_tPos + k + 1] * g;
                            }
                            _tPos += n;
                            if (LoopTrack && _tPos >= _track.Length && _fadeLeft != 0) _tPos = 0;
                        }
                        for (int k = 0; k < mix.Length; k++)
                        {   // a soft limiter above 0.75: the voice over the track rounds off rather than clips
                            float s = mix[k], a = s < 0 ? -s : s;
                            if (a > 0.75f) { a = 0.75f + 0.24f * (float)Math.Tanh((a - 0.75f) / 0.24f); s = s < 0 ? -a : a; }
                            pcm[k] = (short)(s * 32767);
                        }
                        Marshal.Copy(pcm, 0, _buf[i], pcm.Length);
                        Marshal.StructureToPtr(new WaveHdr { Data = _buf[i], Length = (uint)(pcm.Length * 2) }, _hdr[i], false);
                        waveOutPrepareHeader(_h, _hdr[i], _hdrSize); waveOutWrite(_h, _hdr[i], _hdrSize); _queued[i] = true; wrote = true;
                    }
                    if (!wrote) Thread.Sleep(5);
                }
            }
            catch { }
            finally { Shut(); _done.Set(); }
        }
        bool AnyQueued() { for (int i = 0; i < NBuf; i++) if (_queued[i] && (Marshal.ReadInt32(_hdr[i], _flagsAt) & WHDR_DONE) == 0) return true; return false; }
        void Shut()
        {
            if (_h == IntPtr.Zero) return;
            waveOutReset(_h);
            for (int i = 0; i < NBuf; i++) { if (_queued[i]) waveOutUnprepareHeader(_h, _hdr[i], _hdrSize); _queued[i] = false; }
            waveOutClose(_h); _h = IntPtr.Zero;
            for (int i = 0; i < NBuf; i++) { Marshal.FreeHGlobal(_buf[i]); Marshal.FreeHGlobal(_hdr[i]); }
        }
        public void Dispose() { _run = false; if (_th != null && Thread.CurrentThread != _th) _th.Join(1000); }
    }

    public class LoadingScreen : IDisposable
    {
        delegate IntPtr WndProcD(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WNDCLASSEX
        {
            public int cbSize; public int style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra;
            public IntPtr hInstance, hIcon, hCursor, hbrBackground;
            public string lpszMenuName, lpszClassName; public IntPtr hIconSm;
        }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint msg; public IntPtr w, l; public uint time; public POINT pt; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClassExW(ref WNDCLASSEX c);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool UnregisterClassW(string name, IntPtr inst);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateWindowExW(int ex, string cls, string title, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern bool PeekMessageW(out MSG m, IntPtr h, uint lo, uint hi, uint remove);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
        [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFO mi);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("gdi32.dll")] static extern IntPtr GetStockObject(int i);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
        [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);

        const int WS_POPUP = unchecked((int)0x80000000);
        const int WS_EX_LAYERED = 0x80000, WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
        const uint SWP_NOACTIVATE = 0x10, SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2;
        const int SW_SHOWNOACTIVATE = 4, SW_HIDE = 0;
        const uint WM_MOUSEACTIVATE = 0x21, WM_NCHITTEST = 0x84, WM_SETCURSOR = 0x20;
        [DllImport("user32.dll")] static extern IntPtr SetCursor(IntPtr c);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

        public string Text = "Loading RaptorMod...";
        public string StartError = "";
        /// <summary>WHAT IT REALLY IS ON SCREEN (Josh, 2026-10-14: 'still too small this time ... sometimes not being full screen'): each
        /// size it takes is reported here (the gate puts it in the watcher's log), and ~1.5 s after it shows a small picture of the
        /// whole screen is saved to ShotPath (null = none) -- so the next time it is wrong, the log and the picture say how.</summary>
        public Action<string> Log; public string ShotPath; bool _shot; string _dpiCtx = "?";
        Thread _th; volatile bool _run; WndProcD _wp; IntPtr _hwnd; string _cls;
        readonly ManualResetEvent _up = new ManualResetEvent(false), _gone = new ManualResetEvent(false);
        readonly object _lk = new object();
        // the bar: a target that climbs toward each stage's end along an easing curve (so it never
        // sits still while something slow is waited for), and the shown value easing after it
        double _from, _to, _tau = 1; Stopwatch _stage = Stopwatch.StartNew(); bool _finish;
        double _shown;

        public bool Start() { return Prepare() && Show(); }
        /// <summary>Make the window, HIDDEN, so that Show() is instant (the gate does this as soon as it starts).</summary>
        public bool Prepare()
        {
            if (_th != null) return _hwnd != IntPtr.Zero;
            _run = true;
            _th = new Thread(Loop); _th.IsBackground = true; _th.Name = "AztLoading"; _th.SetApartmentState(ApartmentState.STA); _th.Start();
            _up.WaitOne(3000);
            return _hwnd != IntPtr.Zero;
        }
        /// <summary>Put it up: black over the whole screen at once, the type and bar a moment later.</summary>
        public bool Show()
        {
            if (_th == null && !Prepare()) return false;
            _visible = true;
            IntPtr h = _hwnd; if (h == IntPtr.Zero) return false;
            // shown from THIS thread too, so it does not wait for the window's own loop to wake
            ShowWindow(h, SW_SHOWNOACTIVATE); SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
            _showEv.Set();
            return true;
        }
        volatile bool _visible; readonly ManualResetEvent _showEv = new ManualResetEvent(false);
        public bool Visible { get { return _visible; } }
        /// <summary>The next stage: the bar heads for `to` (0..1), getting about 90% of the way in `expectSeconds`.</summary>
        public void Stage(double to, double expectSeconds)
        {
            lock (_lk) { _from = Target(); _to = Math.Max(_from, Math.Min(1, to)); _tau = Math.Max(0.05, expectSeconds); _stage.Restart(); }
        }
        double Target()
        {
            double t = _stage.Elapsed.TotalSeconds;
            return _from + (_to - _from) * (1 - Math.Exp(-2.3 * t / _tau));
        }
        /// <summary>Fill the bar, fade out, close. Returns at once; Wait() blocks until it is gone.</summary>
        public void Finish() { lock (_lk) { _finish = true; } }
        public bool Wait(int ms) { return _th == null || !_visible || _gone.WaitOne(ms); }     // (never shown: nothing to wait for)
        public double Shown { get { return _shown; } }

        // ---- THE PANEL: the logo, the line of type, the bar -------------------------------------------------------
        /// <summary>Room above the type for the logo (px at 96 dpi).</summary>
        /// <summary>How long the bar takes to count up from empty when the screen goes up (s).</summary>
        public double BarIntro = 1.4;
        public double LogoBand = 96;
        /// <summary>The credit line under the bar, and the room it takes (px at 96 dpi).</summary>
        public string Credit = "Developed by Josh Sears\nPapertelevision.com"; public double CreditBand = 48;                  // (168 at the first logo's size; 40% smaller now, and closer to the type)
        public bool Logo = true;
        // AT ITS OWN PIXEL SIZE, always (never DrawImageUnscaled: GDI+ scales that by the bitmap's stored DPI over the target's,
        // and a new bitmap takes its DPI from the display context of the moment -- 96 one launch, 144 the next on a 150% screen.
        // Josh, 2026-10-14: the launch screen 'too small and a little off center to the left' = drawn at 2/3 from its corner.)
        static void Blit(Graphics g, Image im, int x, int y) { g.DrawImage(im, new Rectangle(x, y, im.Width, im.Height), 0, 0, im.Width, im.Height, GraphicsUnit.Pixel); }
        void DrawPanel(Graphics g, int pw, int ph, double sc, double t, double shown)
        {
            g.Clear(Color.Black); g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            float top = (float)(LogoBand * sc);
            if (Logo) DrawFangs(g, pw / 2f, (float)(top * 0.52), (float)(sc), t);
            int barW = (int)(220 * sc), barH = Math.Max(2, (int)(3 * sc)), barX = (pw - barW) / 2, barY = (int)(top + 40 * sc);
            using (var font = new Font("Segoe UI", (float)(14 * sc), FontStyle.Regular, GraphicsUnit.Pixel))
            using (var white = new SolidBrush(Color.FromArgb(235, 235, 235)))
            using (var track = new SolidBrush(Color.FromArgb(48, 48, 48)))
            {
                var sz = g.MeasureString(Text, font);
                g.DrawString(Text, font, white, (pw - sz.Width) / 2f, barY - sz.Height - (float)(8 * sc));
                g.FillRectangle(track, barX, barY, barW, barH);
                g.FillRectangle(white, barX, barY, (int)Math.Round(barW * Math.Max(0, Math.Min(1, shown))), barH);
            }
            // the credit under the bar, two centred lines, as bright as the type above (Josh, 2026-10-07)
            if (!string.IsNullOrEmpty(Credit))
                using (var small = new Font("Segoe UI", (float)(11.5 * sc), FontStyle.Regular, GraphicsUnit.Pixel))
                using (var ink = new SolidBrush(Color.FromArgb(235, 235, 235)))
                {
                    g.TextRenderingHint = TextRenderingHint.AntiAlias;      // (grid-fitting spaces small type unevenly)
                    float y = barY + barH + (float)(22 * sc);
                    foreach (var line in Credit.Split('\n'))
                    {
                        var cs = g.MeasureString(line, small);
                        g.DrawString(line, small, ink, (pw - cs.Width) / 2f, y); y += (float)(15.5 * sc);
                    }
                }
        }        /// <summary>Offline: the panel at `t` seconds after it went up, the bar at `shown`.</summary>
        public Bitmap Preview(double sc, double t, double shown)
        {
            int pw = (int)(320 * sc), ph = (int)((64 + LogoBand + CreditBand) * sc); var b = new Bitmap(pw, ph);
            using (var g = Graphics.FromImage(b)) DrawPanel(g, pw, ph, sc, t, shown);
            return b;
        }

        // ---- THE LOGO: a pair of fangs in white vector line (Josh, 2026-10-07: "a wireframe feel (similar to the grail),
        // pure white, 1-2px vector linework of an animated pair of fangs, logo like, animated in the smooth style of the
        // reticle animation"). Corner brackets close in turning, as the boot's lock does; the jaw line draws out from the
        // middle; the fangs draw down from the gum to the tip, one a beat after the other, their cross-section rings
        // popping in; a lock flash rings off the tips; then it idles -- breathing, a scan line, a glint down each fang.
        static double Clamp01(double x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
        static double EaseOut(double x) { x = Clamp01(x); return 1 - Math.Pow(1 - x, 3); }
        static double EaseInOut(double x) { x = Clamp01(x); return x * x * x * (x * (x * 6 - 15) + 10); }
        static double EaseBack(double x) { x = Clamp01(x); double c = 1.6; return 1 + (c + 1) * Math.Pow(x - 1, 3) + c * Math.Pow(x - 1, 2); }
        static PointF[] Bez(PointF a, PointF b, PointF c, PointF d, int n)
        {
            var p = new PointF[n + 1];
            for (int i = 0; i <= n; i++)
            {
                float u = i / (float)n, v = 1 - u;
                p[i] = new PointF(v * v * v * a.X + 3 * v * v * u * b.X + 3 * v * u * u * c.X + u * u * u * d.X, v * v * v * a.Y + 3 * v * v * u * b.Y + 3 * v * u * u * c.Y + u * u * u * d.Y);
            }
            return p;
        }
        // a polyline drawn up to share f of its length (the stroke drawing itself on)
        static void Partial(Graphics g, Pen pen, PointF[] p, double f)
        {
            f = Clamp01(f); if (f <= 0 || p.Length < 2) return;
            double total = 0; var seg = new double[p.Length - 1];
            for (int i = 0; i + 1 < p.Length; i++) { seg[i] = Math.Sqrt((p[i + 1].X - p[i].X) * (p[i + 1].X - p[i].X) + (p[i + 1].Y - p[i].Y) * (p[i + 1].Y - p[i].Y)); total += seg[i]; }
            double want = total * f, acc = 0; var outp = new System.Collections.Generic.List<PointF> { p[0] };
            for (int i = 0; i + 1 < p.Length; i++)
            {
                if (acc + seg[i] >= want) { float k = (float)((want - acc) / Math.Max(1e-6, seg[i])); outp.Add(new PointF(p[i].X + (p[i + 1].X - p[i].X) * k, p[i].Y + (p[i + 1].Y - p[i].Y) * k)); break; }
                acc += seg[i]; outp.Add(p[i + 1]);
            }
            if (outp.Count >= 2) g.DrawLines(pen, outp.ToArray());
        }
        static PointF At(PointF[] p, double f) { int i = (int)Math.Round(Clamp01(f) * (p.Length - 1)); return p[i]; }
        // v2 (Josh: "lose the brackets, make it more 3d, and 40% smaller"): the fangs are true 3D wireframes now -- each a
        // tapering tusk of round sections swept along a spine that curves in and forward, eight lines down its length and
        // rings round it; the jaw a horseshoe band curving back in depth. Drawn in perspective, the far side dimmer, and
        // swaying gently so the depth reads. Same build-up: the jaw out from the middle, the fangs drawn gum to tip a beat
        // apart with their rings popping in, a flash off the tips, then breathing, a scan line and a glint.
        /// <summary>The logo's size (1 = the first version's).</summary>
        public double LogoScale = 0.6;
        void DrawFangs(Graphics g, float cx, float cy, float sc, double t)
        {
            float U = (float)(58 * sc * LogoScale);
            // the view: a slow sway about the upright (it swings in from one side as it draws), looked at a little from below
            double sway = t < 1.6 ? 0.55 * (1 - EaseInOut(t / 1.6)) : 0.38 * Math.Sin((t - 1.6) * 2 * Math.PI / 7.0);
            double cyw = Math.Cos(sway), syw = Math.Sin(sway), tilt = -0.22, ct = Math.Cos(tilt), st = Math.Sin(tilt);
            Func<double, double, double, double[]> V = (x, y, z) =>
            {
                double x1 = x * cyw + z * syw, z1 = -x * syw + z * cyw;          // turn about the upright
                double y2 = y * ct - z1 * st, z2 = y * st + z1 * ct;              // tip toward / away from the eye
                double k = 1 / (1 + z2 * 0.35);
                return new[] { cx + x1 * U * k, cy + (y2 - 0.45) * U * k, z2 };
            };
            double breathe = t > 1.6 ? 0.88 + 0.12 * Math.Cos((t - 1.6) * 2 * Math.PI / 2.4) : 1;
            Func<double, int> A = k => (int)Math.Max(0, Math.Min(255, 255 * k * breathe));
            Func<double, double> Near = z => Clamp01(0.55 - z * 1.4);              // 1 = nearest
            float lw = Math.Max(1f, 1.4f * sc);
            using (var pen = new Pen(Color.White, lw) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round, LineJoin = System.Drawing.Drawing2D.LineJoin.Round })
            using (var thin = new Pen(Color.White, Math.Max(1f, 1.0f * sc)))
            {
                // 1. the jaw: a horseshoe band (upper and lower edge, ticks between), out from the middle (0 .. 0.6 s)
                double jw = EaseOut((t - 0.05) / 0.55);
                const int JN = 32;
                var up = new double[JN + 1][]; var lo = new double[JN + 1][];
                for (int i = 0; i <= JN; i++)
                {
                    double x = -1.0 + 2.0 * i / JN, arch = -0.10 * Math.Cos(x * Math.PI / 2), z = -0.42 * (1 - x * x);
                    up[i] = V(x, arch, z); lo[i] = V(x, arch + 0.07, z);
                }
                for (int half = 0; half < 2; half++)
                {
                    // from the middle out, each half
                    var pu = new System.Collections.Generic.List<PointF>(); var pl = new System.Collections.Generic.List<PointF>(); double zsum = 0;
                    for (int i = JN / 2; half == 0 ? i <= JN : i >= 0; i += half == 0 ? 1 : -1) { pu.Add(new PointF((float)up[i][0], (float)up[i][1])); pl.Add(new PointF((float)lo[i][0], (float)lo[i][1])); zsum += up[i][2]; }
                    pen.Color = Color.FromArgb(A(0.95), Color.White); Partial(g, pen, pu.ToArray(), jw);
                    thin.Color = Color.FromArgb(A(0.5), Color.White); Partial(g, thin, pl.ToArray(), jw);
                }
                for (int i = 2; i <= JN - 2; i += 3)
                {
                    double at = Math.Abs(i - JN / 2) / (double)(JN / 2); if (at > jw) continue;
                    thin.Color = Color.FromArgb(A(0.35 + 0.35 * Near(up[i][2])), Color.White);
                    g.DrawLine(thin, (float)up[i][0], (float)up[i][1], (float)lo[i][0], (float)lo[i][1]);
                }
                // 2. the fangs: tapering round sections along a spine that curves in and forward (0.35 .. 1.1 s)
                const int NU = 22, NM = 8;
                for (int side = -1; side <= 1; side += 2)
                {
                    double d0 = 0.35 + (side > 0 ? 0.1 : 0), fk = EaseInOut((t - d0) / 0.6);
                    if (fk <= 0) continue;
                    Func<double, double[]> Spine = u => new[] { side * (0.36 - 0.11 * Math.Pow(u, 1.4)), -0.10 * Math.Cos(0.36 * Math.PI / 2) + 0.04 + 1.05 * u, -0.30 + 0.22 * u * u };
                    Func<double, double> Rad = u => 0.155 * Math.Pow(1 - u, 0.8);
                    // the lines down its length, each drawn gum to tip; dimmer round the back
                    for (int j = 0; j < NM; j++)
                    {
                        double th = 2 * Math.PI * j / NM; var pts = new PointF[NU + 1]; double zs = 0;
                        for (int k = 0; k <= NU; k++)
                        {
                            double u = k / (double)NU; var s = Spine(u); double r = Rad(u);
                            var p = V(s[0] + r * Math.Cos(th), s[1], s[2] + r * Math.Sin(th)); pts[k] = new PointF((float)p[0], (float)p[1]); zs += p[2];
                        }
                        double nr = Near(zs / (NU + 1));
                        var pp = nr > 0.5 ? pen : thin; pp.Color = Color.FromArgb(A(0.25 + 0.75 * nr), Color.White);
                        Partial(g, pp, pts, fk);
                    }
                    // the rings, base to tip, popping in as the lines pass them -- each in two halves, near and far
                    double[] us = { 0.0, 0.2, 0.4, 0.6, 0.78 };
                    for (int r = 0; r < us.Length; r++)
                    {
                        if (us[r] > fk) continue;
                        double rk = EaseBack((t - d0 - us[r] * 0.6) / 0.25); if (rk <= 0) continue;
                        var s = Spine(us[r]); double rad = Rad(us[r]) * rk;
                        for (int halfR = 0; halfR < 2; halfR++)
                        {
                            var ring = new PointF[13]; double zs = 0;
                            for (int q = 0; q <= 12; q++)
                            {
                                double th = Math.PI * (halfR + q / 12.0); var p = V(s[0] + rad * Math.Cos(th), s[1], s[2] + rad * Math.Sin(th));
                                ring[q] = new PointF((float)p[0], (float)p[1]); zs += p[2];
                            }
                            thin.Color = Color.FromArgb(A((0.2 + 0.6 * Near(zs / 13)) * Clamp01(rk)), Color.White); g.DrawLines(thin, ring);
                        }
                    }
                    // the tip, for the flash and the glint
                    var tipP = V(Spine(1)[0], Spine(1)[1], Spine(1)[2]);
                    double lk = (t - 1.1) / 0.45;
                    if (lk > 0 && lk < 1) { float rr = (float)(U * (0.06 + 0.45 * EaseOut(lk))); thin.Color = Color.FromArgb((int)(200 * (1 - lk)), Color.White); g.DrawEllipse(thin, (float)tipP[0] - rr, (float)tipP[1] - rr, 2 * rr, 2 * rr); }
                    if (t > 1.6)
                    {
                        double gl = ((t - 1.6 + (side > 0 ? 1.1 : 0)) % 3.2) / 0.7;
                        if (gl < 1)
                        {
                            double u = EaseInOut(gl); var s = Spine(u); var gp = V(s[0] - side * Rad(u), s[1], s[2]); float rr = 1.8f * sc;
                            using (var gb = new SolidBrush(Color.FromArgb((int)(220 * Math.Sin(gl * Math.PI)), Color.White))) g.FillEllipse(gb, (float)gp[0] - rr, (float)gp[1] - rr, 2 * rr, 2 * rr);
                        }
                    }
                }
                // a scan line passing down over it now and then
                if (t > 1.6)
                {
                    double sp = ((t - 1.6) % 2.8) / 1.1;
                    if (sp < 1)
                    {
                        float y0 = cy + (float)((-0.3 - 0.45) * U), y1 = cy + (float)((1.2 - 0.45) * U), sy = y0 + (float)(EaseInOut(sp) * (y1 - y0));
                        thin.Color = Color.FromArgb((int)(80 * Math.Sin(sp * Math.PI)), Color.White); g.DrawLine(thin, cx - 1.1f * U, sy, cx + 1.1f * U, sy);
                    }
                }
            }
        }
        IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            if (msg == WM_MOUSEACTIVATE) return new IntPtr(3);     // MA_NOACTIVATE
            // No pointer over the loading screen (Josh, 2026-10-07: "a blue system loading spinner"). The window had
            // no cursor of its own, so Windows' launch-feedback cursor -- the busy ring, from DOSBox having just
            // been started -- was what showed in the middle of the screen. An empty cursor here hides it.
            if (msg == WM_SETCURSOR) { SetCursor(IntPtr.Zero); return new IntPtr(1); }
            return DefWindowProcW(h, msg, w, l);
        }

        void Loop()
        {
            try
            {
                try { IntPtr prev = SetThreadDpiAwarenessContext(new IntPtr(-4)); _dpiCtx = prev == IntPtr.Zero ? "refused" : "per-monitor"; } catch { _dpiCtx = "failed"; }
                _wp = WndProc; _cls = "AztLoading" + Stopwatch.GetTimestamp();
                var wc = new WNDCLASSEX();
                wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX)); wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wp);
                wc.hInstance = GetModuleHandleW(IntPtr.Zero); wc.lpszClassName = _cls; wc.hbrBackground = GetStockObject(4);   // BLACK_BRUSH
                if (RegisterClassExW(ref wc) == 0) { StartError = "RegisterClassEx failed: " + Marshal.GetLastWin32Error(); return; }
                // the primary monitor, where DOSBox goes full screen
                var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                GetMonitorInfoW(MonitorFromPoint(new POINT(), 1), ref mi);
                int x = mi.rcMonitor.l, y = mi.rcMonitor.t, w = mi.rcMonitor.r - mi.rcMonitor.l, h = mi.rcMonitor.b - mi.rcMonitor.t;
                _hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, _cls, "RaptorMod", WS_POPUP, x, y, w, h,
                                        IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_hwnd == IntPtr.Zero) { StartError = "CreateWindowEx failed: " + Marshal.GetLastWin32Error(); return; }
                SetLayeredWindowAttributes(_hwnd, 0, 255, 2);
                _up.Set();
                // made but hidden until Show(); messages pumped meanwhile so the window stays healthy
                while (_run && !_showEv.WaitOne(5))
                {
                    MSG pm; while (PeekMessageW(out pm, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref pm); DispatchMessageW(ref pm); }
                }
                if (!_run) return;
                ShowWindow(_hwnd, SW_SHOWNOACTIVATE);
                // put the pointer back where it is: a move, so the window is asked for its (empty) cursor at once
                POINT cp; if (GetCursorPos(out cp)) SetCursorPos(cp.x, cp.y);

                // ONE SIZE, EVERY LAUNCH (Josh, 2026-10-14: "The raptor mod loading screen is sometimes full screen and sometimes
                // smaller. It needs to be consistently the correct size"). The panel is scaled by the WINDOW'S OWN HEIGHT in its
                // own coordinates (1.5 at 1600 rows -- the size it was designed at on Josh's 150% screen), not by the DPI the window
                // reports, so it is the same share of the screen whether or not this thread's DPI awareness took; and the window is
                // fitted to the primary monitor again several times a second, so DOSBox going full screen underneath (a mode or
                // scale change) cannot leave it the wrong size. The panel re-centres when the size changes.
                Bitmap panel = null; int pw = 0, ph = 0, px = 0, py = 0, cw = 0, chh = 0; double sc = 1;
                try
                {
                    var clock = Stopwatch.StartNew(); double last = clock.Elapsed.TotalSeconds; Stopwatch fade = null; long topAt = -1000, fitAt = -1000;
                    while (_run)
                    {
                        MSG m; while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
                        double now = clock.Elapsed.TotalSeconds, dt = now - last; last = now;
                        double target; bool fin; lock (_lk) { fin = _finish; target = fin ? 1.0 : Target(); }
                        _shown += (target - _shown) * Math.Min(1, dt * (fin ? 14 : 6));
                        if (fin && _shown > 0.995) _shown = 1;
                        // the whole primary monitor, again and again (cheap), and the panel sized from what the window really is
                        if (clock.ElapsedMilliseconds - fitAt > 250)
                        {
                            fitAt = clock.ElapsedMilliseconds;
                            var fm = new MONITORINFO(); fm.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                            if (GetMonitorInfoW(MonitorFromPoint(new POINT(), 1), ref fm))
                            {
                                RECT wr; GetWindowRect(_hwnd, out wr);
                                if (wr.l != fm.rcMonitor.l || wr.t != fm.rcMonitor.t || wr.r != fm.rcMonitor.r || wr.b != fm.rcMonitor.b)
                                    SetWindowPos(_hwnd, HWND_TOPMOST, fm.rcMonitor.l, fm.rcMonitor.t, fm.rcMonitor.r - fm.rcMonitor.l, fm.rcMonitor.b - fm.rcMonitor.t, SWP_NOACTIVATE);
                            }
                            RECT cr; GetClientRect(_hwnd, out cr);
                            int nw = Math.Max(1, cr.r - cr.l), nh = Math.Max(1, cr.b - cr.t);
                            if (nw != cw || nh != chh || panel == null)
                            {
                                cw = nw; chh = nh;
                                sc = Math.Max(1.0, chh / 1067.0);
                                pw = (int)(320 * sc); ph = (int)((64 + LogoBand + CreditBand) * sc); px = (cw - pw) / 2; py = (chh - ph) / 2;
                                if (panel != null) panel.Dispose();
                                panel = new Bitmap(pw, ph);
                                try
                                {
                                    RECT lw; GetWindowRect(_hwnd, out lw); var lm = new MONITORINFO(); lm.cbSize = Marshal.SizeOf(typeof(MONITORINFO)); GetMonitorInfoW(MonitorFromPoint(new POINT(), 1), ref lm);
                                    if (Log != null) Log(string.Format("{0:N1} s: window {1},{2} {3}x{4}, client {5}x{6}, monitor {7}x{8}, dpi {9} ({10}), panel {11}x{12} at {13},{14} (scale {15:N2})",
                                        now, lw.l, lw.t, lw.r - lw.l, lw.b - lw.t, cw, chh, lm.rcMonitor.r - lm.rcMonitor.l, lm.rcMonitor.b - lm.rcMonitor.t, GetDpiForWindow(_hwnd), _dpiCtx, pw, ph, px, py, sc));
                                }
                                catch { }
                                using (var wg = Graphics.FromHwnd(_hwnd)) wg.Clear(Color.Black);      // (the old panel's place, black again)
                            }
                        }
                        // above DOSBox, which comes up full screen underneath after this does
                        if (clock.ElapsedMilliseconds - topAt > 100) { SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); topAt = clock.ElapsedMilliseconds; }
                        // (Josh, 2026-10-07: the bar counts UP from empty as the screen comes up, to wherever loading has got to)
                        double disp = _shown * EaseOut(now / BarIntro);
                        using (var g = Graphics.FromImage(panel)) DrawPanel(g, pw, ph, sc, now, disp);
                        using (var wg = Graphics.FromHwnd(_hwnd)) Blit(wg, panel, px, py);
                        // (once, ~1.5 s in: the whole screen as it really looks, a third of its size)
                        if (!_shot && ShotPath != null && now > 1.5)
                        {
                            _shot = true;
                            try
                            {
                                var sm = new MONITORINFO(); sm.cbSize = Marshal.SizeOf(typeof(MONITORINFO)); GetMonitorInfoW(MonitorFromPoint(new POINT(), 1), ref sm);
                                int sw = sm.rcMonitor.r - sm.rcMonitor.l, sh = sm.rcMonitor.b - sm.rcMonitor.t;
                                using (var full = new Bitmap(sw, sh)) using (var fg = Graphics.FromImage(full))
                                {
                                    fg.CopyFromScreen(sm.rcMonitor.l, sm.rcMonitor.t, 0, 0, new Size(sw, sh));
                                    using (var small = new Bitmap(Math.Max(1, sw / 3), Math.Max(1, sh / 3))) using (var sg = Graphics.FromImage(small)) { sg.DrawImage(full, 0, 0, small.Width, small.Height); small.Save(ShotPath, System.Drawing.Imaging.ImageFormat.Png); }
                                }
                                if (Log != null) Log("the screen as it looked at 1.5 s: " + ShotPath);
                            }
                            catch (Exception se) { if (Log != null) Log("no picture of the screen: " + se.Message); }
                        }
                        if (fin && _shown >= 1)
                        {
                            if (fade == null) fade = Stopwatch.StartNew();
                            double a = 1 - fade.Elapsed.TotalMilliseconds / 350.0;
                            if (a <= 0) break;
                            SetLayeredWindowAttributes(_hwnd, 0, (byte)(255 * a), 2);
                        }
                        Thread.Sleep(15);
                    }
                }
                finally { if (panel != null) panel.Dispose(); }
            }
            catch (Exception e) { StartError = e.Message; }
            finally
            {
                if (_hwnd != IntPtr.Zero) { ShowWindow(_hwnd, SW_HIDE); DestroyWindow(_hwnd); _hwnd = IntPtr.Zero; }
                try { UnregisterClassW(_cls, GetModuleHandleW(IntPtr.Zero)); } catch { }
                _up.Set(); _gone.Set();
            }
        }

        public void Dispose()
        {
            _run = false;
            if (_th != null) { _th.Join(1000); _th = null; }
        }

        // ---- holding the game while the renderer gets ready --------------------------------------
        /// <summary>Freeze every thread of a process. NOT USED to hold the game any more: freezing DOSBox for seconds killed
        /// its Sound Blaster for the rest of the session (2026-10-07). The gate holds the game through its frame limiter.</summary>
        public static bool Suspend(int pid) { return Nt(pid, true); }
        /// <summary>Let it run again. Safe to call when it was never suspended.</summary>
        public static bool Resume(int pid) { return Nt(pid, false); }
        static bool Nt(int pid, bool suspend)
        {
            IntPtr h = OpenProcess(0x0800, false, pid);    // PROCESS_SUSPEND_RESUME
            if (h == IntPtr.Zero) return false;
            try { return (suspend ? NtSuspendProcess(h) : NtResumeProcess(h)) == 0; } finally { CloseHandle(h); }
        }
    }

    // ---- THE GATE: hold the game at the start of play only if the renderer is not ready yet ------
    // (Josh, 2026-10-07: the intro movies must play.) The game starts at once and its intro plays
    // untouched while the renderer compiles and loads in the background. This thread -- compiled
    // and running within a second of launch -- finds the game, then watches for the first gameplay
    // frame (the staging buffer appearing / the visor boot starting). If the renderer has said
    // Ready() by then, nothing happens and no loading screen is ever seen. If not (the player
    // skipped the movies), the game is suspended right there, before its boot has really begun,
    // "Loading RaptorMod..." goes up, and both are released the moment the renderer is ready.
    // ---- THE TITLE MENU (Josh, 2026-10-10: "replace the title image ... implemented in the GPU as a true title screen, with
    // a Continue, Load, Options, Quit buttons under the title text in a similar style to what we've done with the visor
    // load/save screen. The Continue will load the most recently dated save file. Load ... can come up without visor
    // background as an overlay to this title screen ... beneath this menu somewhat separate but in the same column ... a
    // less prominent button titled Story"). The game holds its title stage for it (Build-AztMod $ENABLE_TITLE_MENU) and the
    // gate drives the game from the choice; this is the picture and the menu: the 4K art (cover-fit to the monitor), the
    // visor's amber type and lock-on brackets, and a slot list for LOAD. DOSBox keeps the focus and the mouse (it captures
    // it), so the input is the GAME's: its cursor and left button (fed in by the gate, CursorX/Y/Button) and the keys,
    // read globally while DOSBox is in front (the game ignores them while the title is held).
    public partial class TitleScreen : IDisposable      // (RAPTOR DOCS: RaptorDocs.cs)
    {
        delegate IntPtr WndProcD(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WNDCLASSEX { public int cbSize; public int style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint msg; public IntPtr w, l; public uint time; public POINT pt; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClassExW(ref WNDCLASSEX c);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool UnregisterClassW(string name, IntPtr inst);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateWindowExW(int ex, string cls, string title, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern bool PeekMessageW(out MSG m, IntPtr h, uint lo, uint hi, uint remove);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
        [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFO mi);
        [DllImport("gdi32.dll")] static extern IntPtr GetStockObject(int i);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern IntPtr SetCursor(IntPtr c);
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort usUsagePage, usUsage; public uint dwFlags; public IntPtr hwndTarget; }
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devs, uint n, uint size);
        [DllImport("user32.dll", SetLastError = true)] static extern int GetRegisteredRawInputDevices([Out] RAWINPUTDEVICE[] devs, ref uint n, uint size);
        [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr hRaw, uint cmd, IntPtr data, ref uint size, uint headerSize);
        const uint WM_INPUT = 0xFF, RIDEV_INPUTSINK = 0x100, RIDEV_REMOVE = 0x1, RID_INPUT = 0x10000003;
        const int WS_POPUP = unchecked((int)0x80000000);
        const int WS_EX_LAYERED = 0x80000, WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80, WS_EX_TRANSPARENT = 0x20;
        const uint SWP_NOACTIVATE = 0x10, SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

        // ---- what it is told, and what it says ----
        /// <summary>The title art; the game's save folder (SAVEn.DAT, SGDNAME.DAT); DOSBox's process (its keys count only
        /// while it is in front).</summary>
        public string ImagePath, SaveDir; public int GamePid;
        /// <summary>The game's cursor (its own screen px) and left button, kept current by the gate.</summary>
        public volatile int CursorX = -1, CursorY = -1, Button;
        public const int PickNone = 0, PickLoad = 1, PickNew = 2, PickQuit = 3;
        volatile int _pick, _pickSlot = -1;
        /// <summary>The player's choice (PickLoad with PickSlot, PickNew, PickQuit) -- 0 until there is one.</summary>
        public int Pick { get { return _pick; } }
        public int PickSlot { get { return _pickSlot; } }
        public string StartError = "", Note = "";
        public bool Visible { get { return _shown; } }
        // ---- READING A LOG (Josh, 2026-10-10: "i want to see the loading animation I mentioned when I click continue or if I
        // load a game" -- the memory core's "Initiating log file" panel): a LOAD does not close the title. The art dims, the
        // panel opens where the menu was and reads the archive in -- typed title, the bar, the stream -- holding short of full
        // until the renderer's view is up behind it (LoadShown, from the gate), then "LOG FILE INITIATED." and the window fades
        // into the visor's shutter. ReadMax: never longer than that, whatever happens.
        /// <summary>The visor's view is back behind the title: finish the reading and go.</summary>
        public volatile bool LoadShown;
        public double ReadSeconds = 2.2, ReadHold = 0.85, ReadMax = 45, ReadDim = 0.55;
        double _readAt = -1, _readDoneAt = -1, _readP, _readBlip = -9, _shownAt = -1; string _readName = ""; int _readSlot = -1;
        public double ReadMin = 1.0;
        // THE ROOM IS PART OF THE LOAD (Josh, 2026-10-12: "we need those textures to be loaded when loading a game as well, but
        // that needs to be lumped into the core loading UI/animation as part of the loading process"): as the visor's own panel
        // (ScanWire.cs VisorMenu.ReadBar) -- the renderer reports the new room's textures, decoded and sent to the card, through
        // the gate (GameGate.TitleLoadProgress) as LoadProgress 0..1; the archive is the first 30% of the bar, the room the rest.
        // -1 (RoomLoadAhead off): the bar as before.
        public volatile float LoadProgress = -1f;
        public bool RoomLoadAhead;
        public string RoomStage = "ANALYZING ENVIRONMENT";
        double _progBase = -1, _readPT = -1;
        double ReadBar(double rt, double t)
        {
            double e = 1 - Math.Pow(1 - Math.Min(1, rt / ReadSeconds), 2);
            float lp = LoadProgress;
            if (lp < 0) return Math.Max(_readP, Math.Min(0.99, e));
            double tgt = 0.30 * e + 0.12 * (1 - Math.Exp(-Math.Max(0, rt - ReadSeconds) / 3.0));
            if (lp > 0) { if (_progBase < 0) _progBase = Math.Max(_readP, 0.30); tgt = Math.Max(tgt, _progBase + (0.99 - _progBase) * Math.Min(1, lp)); }
            double dt = _readPT >= 0 ? Math.Max(0, Math.Min(0.25, t - _readPT)) : 0; _readPT = t;
            return tgt <= _readP ? _readP : _readP + (tgt - _readP) * Math.Min(1, dt * 7);
        }
        /// <summary>TESTING: a window of this place and size in place of the whole monitor (TestW 0 = the monitor).</summary>
        public int TestX, TestY, TestW, TestH;
        // ---- the look (the visor's inks) ----
        public int Amber = 0xFFB040, AmberHi = 0xFFE3A6, AmberDim = 0x9A6418, Glass = 0x140A02;
        /// <summary>Where the column sits: its centre x, its first row's y (shares of the art, which is cover-fit).</summary>
        public double ColX = 0.352, ColY = 0.475;

        Thread _th; volatile bool _run; WndProcD _wp; IntPtr _hwnd; string _cls; volatile bool _shown, _closing;
        readonly ManualResetEvent _up = new ManualResetEvent(false), _gone = new ManualResetEvent(false);

        // ---- the saves ----
        public class Slot { public int Index; public string Name; public DateTime When; public bool Usable; }
        public Slot[] Slots = new Slot[0]; public int NewestSlot = -1;
        public void ReadSaves()
        {
            var list = new System.Collections.Generic.List<Slot>(); NewestSlot = -1; DateTime best = DateTime.MinValue;
            byte[] names = null; try { names = System.IO.File.ReadAllBytes(System.IO.Path.Combine(SaveDir, "SGDNAME.DAT")); } catch { }
            for (int i = 0; i < 5; i++)
            {
                var s = new Slot { Index = i, Name = "", When = DateTime.MinValue };
                if (names != null && names.Length >= (i + 1) * 32)
                {
                    int n = 0; while (n < 30 && names[i * 32 + n] != 0) n++;
                    s.Name = System.Text.Encoding.ASCII.GetString(names, i * 32, n).Trim();
                    s.Usable = BitConverter.ToUInt16(names, i * 32 + 30) == 0;
                }
                string f = System.IO.Path.Combine(SaveDir, "SAVE" + i + ".DAT");
                if (System.IO.File.Exists(f)) s.When = System.IO.File.GetLastWriteTime(f); else s.Usable = false;
                if (s.Name.Length == 0 || string.Equals(s.Name, "EMPTY", StringComparison.OrdinalIgnoreCase)) s.Usable = false;    // (the shipped placeholders)
                if (s.Usable && s.When > best) { best = s.When; NewestSlot = i; }
                list.Add(s);
            }
            Slots = list.ToArray();
        }

        public bool Start()
        {
            ReadSaves(); _sel = NewestSlot >= 0 ? R_CONT : R_NEW;
            _run = true; _th = new Thread(Loop); _th.IsBackground = true; _th.Name = "AztTitle"; _th.SetApartmentState(ApartmentState.STA); _th.Start();
            _up.WaitOne(8000);
            return _hwnd != IntPtr.Zero;
        }
        /// <summary>Fade out and go (the choice has been acted on).</summary>
        public void Close() { _closing = true; }
        public bool WaitGone(int ms) { return _gone.WaitOne(ms); }
        public void Dispose() { _run = false; if (_th != null && Thread.CurrentThread != _th) _th.Join(2000); }

        [StructLayout(LayoutKind.Sequential)] struct PAINTSTRUCT { public IntPtr hdc; public int fErase; public RECT rc; public int fRestore, fIncUpdate; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] rgb; }
        [DllImport("user32.dll")] static extern IntPtr BeginPaint(IntPtr h, out PAINTSTRUCT ps);
        [DllImport("user32.dll")] static extern bool EndPaint(IntPtr h, ref PAINTSTRUCT ps);
        volatile bool _needFull;
        // THE MOUSE ON THE TITLE (Josh, 2026-10-10: "Can we enable mouse support on the main title screen?"). The game's cursor
        // (0x182D6C) does not move before play -- its handler only moves it once the pointer is live -- so the title reads the
        // mouse ITSELF, through raw input (RIDEV_INPUTSINK: delivered with DOSBox in front and holding the mouse captured):
        // movement moves the title's own pointer, the left button picks, the wheel steps through the rows. Counted only while
        // DOSBox (or this) is in front. The process's earlier mouse registration (the host pointer, -HostPointer) is put back
        // when the title goes.
        int _rawDX, _rawDY, _rawClicks, _rawWheel; bool _rawAbs; int _rawAbsX, _rawAbsY;
        /// <summary>Pointer pixels per mouse count (scaled up with the screen past 1920 wide; a fast move is helped along).</summary>
        public double RawSpeed = 1.0;
        RAWINPUTDEVICE[] _rawBefore;
        void RawInput(IntPtr l)
        {
            uint size = 0, hdr = (uint)(IntPtr.Size == 8 ? 24 : 16);
            GetRawInputData(l, RID_INPUT, IntPtr.Zero, ref size, hdr);
            if (size == 0 || size > 256) return;
            IntPtr buf = Marshal.AllocHGlobal((int)size);
            try
            {
                if (GetRawInputData(l, RID_INPUT, buf, ref size, hdr) != size || Marshal.ReadInt32(buf, 0) != 0) return;     // RIM_TYPEMOUSE
                int o = (int)hdr; ushort flags = (ushort)Marshal.ReadInt16(buf, o), bf = (ushort)Marshal.ReadInt16(buf, o + 4);
                int x = Marshal.ReadInt32(buf, o + 12), y = Marshal.ReadInt32(buf, o + 16);
                if ((flags & 1) == 0) { _rawDX += x; _rawDY += y; }                                   // relative motion (a mouse)
                else { _rawAbs = true; _rawAbsX = x; _rawAbsY = y; }                                  // absolute (a tablet, remote desktop): 0..65535
                if ((bf & 0x0001) != 0) _rawClicks++;                                                 // left button down
                if ((bf & 0x0400) != 0) _rawWheel += (short)Marshal.ReadInt16(buf, o + 6);            // the wheel
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            if (msg == WM_INPUT) { try { RawInput(l); } catch { } return DefWindowProcW(h, msg, w, l); }
            if (msg == 0x20) { SetCursor(IntPtr.Zero); return new IntPtr(1); }       // WM_SETCURSOR: none of ours
            if (msg == 0x84) return new IntPtr(-1);                                 // WM_NCHITTEST: transparent to the mouse
            // (Josh, 2026-10-10: "showing only partially the background, a black portion of nothing"): Windows' own repaint
            // must neither erase the window to its black brush nor be left to it -- the loop redraws ALL of it next pass
            if (msg == 0x14) return new IntPtr(1);                                  // WM_ERASEBKGND: never
            if (msg == 0x0F) { PAINTSTRUCT ps; BeginPaint(h, out ps); EndPaint(h, ref ps); _needFull = true; return IntPtr.Zero; }   // WM_PAINT
            return DefWindowProcW(h, msg, w, l);
        }

        // ---- the menu's rows ----
        // (Josh, 2026-10-10: "add a New Game button below Continue ... The continue button will be unselectable when no saves
        // exist (the first time booting the game)" -- NEW GAME is always there; CONTINUE greys out and is passed over)
        // (Josh, 2026-10-11: the last row, STORY, became RAPTOR DOCS -- the manual and the classified print-outs, RaptorDocs.cs)
        const int R_CONT = 0, R_NEW = 1, R_LOAD = 2, R_OPT = 3, R_QUIT = 4, R_DOCS = 5, ROWS = 6;
        static readonly string[] Labels = { "CONTINUE", "NEW GAME", "LOAD", "OPTIONS", "QUIT", "RAPTOR DOCS" };
        bool Enabled(int row) { return row != R_CONT || NewestSlot >= 0; }
        int Step(int from, int dir) { int r = from; for (int k = 0; k < ROWS; k++) { r = (r + dir + ROWS) % ROWS; if (Enabled(r)) return r; } return from; }
        int _sel = 0, _hover = -1, _lsel = 0; bool _loadOpen; double _loadAt = -9;
        double _selAt, _pickAt = -1;
        // ONE CLICK, ONE ACTION -- AND ONLY ON WHAT IS SHOWING (Josh, 2026-10-11: "I will click the options button and if I click
        // somewhere in the options menu, it will accidentally click the load button or some other menu button that is in the main
        // menu behind ... you can only click the buttons that you see on screen"). A click reaches the title TWICE: raw input
        // here at once, and the game's own button word (0x182DA6) a frame or more later, once DOSBox has passed it on. A click on
        // a panel's BACK closed the panel on the first, and the second landed on the main menu row underneath -- acting on the
        // remembered selection, which the hover only updates when its index changes, so it could even reopen the panel just shut.
        // Now: a press within ClickMerge s of the last is the same click; none counts for LayerSettle s after a panel opens or
        // closes; and a click acts on the button under the pointer in the layer on top, nothing else.
        double _pressAt = -9, _layerAt = -9; const double ClickMerge = 0.3, LayerSettle = 0.3;
        void LayerChanged(double t) { _layerAt = t; _hover = -1; }
        /// <summary>A mouse press (from either source) at the pointer (x, y); `placed` = the pointer has a position. True = it acted.</summary>
        public bool Press(double t, float x, float y, bool placed)
        {
            // (the merge counts from the last press that ACTED: clicking a reader's arrow quickly turns a page per click,
            // where counting from any press -- each merged one renewing it -- swallowed every click after the first)
            bool again = t - _pressAt < ClickMerge, settling = t - _layerAt < LayerSettle;
            if (again || settling || !placed) return false;
            int hit = HitTest(x, y);                                   // (the layer on top NOW)
            if (hit < 0) return false;
            _pressAt = t;
            if (_view != V_NONE) _vsel = hit; else if (_docsOpen) _dsel = hit; else if (_optOpen) _osel = hit; else if (_loadOpen) _lsel = hit; else _sel = hit;
            Activate(t); return true;
        }
        /// <summary>OFFLINE: the layer showing ("menu", "options", "load", "docs", "manual", "classified") and the centre of a
        /// button in it (a reader's: VB_BACK 0, VB_PREV 1, VB_NEXT 2, VB_DOC 3, a chapter 10 + i).</summary>
        public string TestLayer { get { return _view == V_MANUAL ? "manual" : _view == V_CLASSIFIED ? "classified" : _docsOpen ? "docs" : _optOpen ? "options" : _loadOpen ? "load" : "menu"; } }
        public PointF TestCentre(string layer, int i)
        {
            var r = layer == "options" ? _optRect[i] : layer == "load" ? _slotRect[i] : layer == "docs" ? _docsRect[i] : layer == "manual" || layer == "classified" ? ViewRect(i) : _rowRect[i];
            return new PointF(r.Left + r.Width / 2, r.Top + r.Height / 2);
        }
        /// <summary>OFFLINE: the manual's page / the classified file showing, and the magnifier.</summary>
        public int TestPage { get { return _view == V_CLASSIFIED ? _cdoc : _page; } }
        /// <summary>TESTING: a key for the running loop to take as pressed (its own thread acts on it); the loop's passes and the
        /// time they spent drawing (ms), and the passes that repainted the whole window.</summary>
        public void TestQueueKey(int vk) { _testKeys.Enqueue(vk); }
        readonly System.Collections.Concurrent.ConcurrentQueue<int> _testKeys = new System.Collections.Concurrent.ConcurrentQueue<int>();
        public long Passes, FullPasses; public double DrawMs, DrawMsMax;
        public bool TestZoom { get { return _zoom; } }
        public void TestKey(int vk, double t) { Key(vk, t); }
        public int TestHit(float x, float y) { return HitTest(x, y); }
        RectangleF[] _rowRect = new RectangleF[ROWS]; RectangleF[] _slotRect = new RectangleF[6];
        // THE OPTIONS PANEL (Josh, 2026-10-11: "in the settings of the main menu we would have a texture quality setting:
        // Normal/Ultra ... implement the menu item on the home menu, with that 'coming soon' in place on the actual new sub
        // menu"): OPTIONS opens it over the column as LOAD opens the slot list. TEXTURE QUALITY (Normal = 2K textures, Ultra =
        // 4K) is shown but not yet offered -- picking it says COMING SOON -- and BACK (or ESC) closes it. The renderer already
        // loads either size (the watcher's -TextureQuality / <game>\raptormod-settings.json "textureQuality").
        const int O_TEX = 0, O_BACK = 1, OROWS = 2;
        bool _optOpen; double _optAt = -9, _optSoonAt = -9; int _osel = O_TEX;
        RectangleF _optPanel; RectangleF[] _optRect = new RectangleF[OROWS]; Rectangle _optArea;
        /// <summary>The texture quality in use, "NORMAL" or "ULTRA" (the watcher's choice), shown on the options panel.</summary>
        public string TextureQuality = "ULTRA";
        Bitmap _bg, _buf; Rectangle _menuArea, _loadArea; int _W, _H; float _s;
        System.Media.SoundPlayer _tick, _confirm;

        static Color C(int rgb, double a) { return Color.FromArgb(Math.Max(0, Math.Min(255, (int)(255 * a))), (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
        static double Ease(double t) { t = Math.Max(0, Math.Min(1, t)); return 1 - Math.Pow(1 - t, 3); }
        static double EaseBack(double t) { t = Math.Max(0, Math.Min(1, t)); double c = 1.70158; return 1 + (c + 1) * Math.Pow(t - 1, 3) + c * Math.Pow(t - 1, 2); }
        static float Hash(int a, int b) { uint h = (uint)(a * 374761393 + b * 668265263); h = (h ^ (h >> 13)) * 1274126177u; return ((h ^ (h >> 16)) & 0xFFFF) / 65535f; }

        // a short sound, made here: the visor's tick (hover) and a two-tone blip (confirm)
        static System.Media.SoundPlayer Tone(double[] hz, double len, double vol)
        {
            int rate = 22050, n = (int)(len * rate); var ms = new System.IO.MemoryStream(); var bw = new System.IO.BinaryWriter(ms);
            bw.Write(0x46464952); bw.Write(36 + n * 2); bw.Write(0x45564157); bw.Write(0x20746D66); bw.Write(16); bw.Write((short)1); bw.Write((short)1);
            bw.Write(rate); bw.Write(rate * 2); bw.Write((short)2); bw.Write((short)16); bw.Write(0x61746164); bw.Write(n * 2);
            for (int i = 0; i < n; i++)
            {
                double t = i / (double)rate, seg = len / hz.Length; int k = Math.Min(hz.Length - 1, (int)(t / seg)); double ts = t - k * seg;
                double env = Math.Min(1, ts / 0.003) * Math.Exp(-ts / (seg * 0.35));
                bw.Write((short)(Math.Sin(2 * Math.PI * hz[k] * t) * env * vol * 32000));
            }
            ms.Position = 0; var p = new System.Media.SoundPlayer(ms); try { p.Load(); } catch { }
            return p;
        }
        static void Play(System.Media.SoundPlayer p) { if (p == null) return; try { p.Play(); } catch { } }

        void Loop()
        {
            try
            {
                try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
                _wp = WndProc; _cls = "AztTitle" + Stopwatch.GetTimestamp();
                var wc = new WNDCLASSEX(); wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX)); wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wp);
                wc.hInstance = GetModuleHandleW(IntPtr.Zero); wc.lpszClassName = _cls; wc.hbrBackground = GetStockObject(4);
                if (RegisterClassExW(ref wc) == 0) { StartError = "RegisterClassEx failed"; return; }
                var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                GetMonitorInfoW(MonitorFromPoint(new POINT(), 1), ref mi);
                int x = mi.rcMonitor.l, y = mi.rcMonitor.t; _W = mi.rcMonitor.r - x; _H = mi.rcMonitor.b - y;
                if (TestW > 0) { x = TestX; y = TestY; _W = TestW; _H = TestH; }
                _s = _H / 1080f;
                Prepare();
                _hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT, _cls, "AztTitleCover", WS_POPUP, x, y, _W, _H, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_hwnd == IntPtr.Zero) { StartError = "CreateWindowEx failed"; return; }
                SetLayeredWindowAttributes(_hwnd, 0, 0, 2);
                ShowWindow(_hwnd, 4); SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
                try
                {
                    uint rsz = (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)), rn = 8; var had = new RAWINPUTDEVICE[8];
                    int got = GetRegisteredRawInputDevices(had, ref rn, rsz);
                    for (int i = 0; i < got; i++) if (had[i].usUsagePage == 1 && had[i].usUsage == 2) _rawBefore = new[] { had[i] };
                    if (!RegisterRawInputDevices(new[] { new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 2, dwFlags = RIDEV_INPUTSINK, hwndTarget = _hwnd } }, 1, rsz))
                        Note = "mouse: raw input not registered (" + Marshal.GetLastWin32Error() + ") -- keys only";
                }
                catch (Exception e) { Note = "mouse: " + e.Message + " -- keys only"; }
                _shown = true; _up.Set();
                _tick = Tone(new[] { 2600.0 }, 0.018, 0.18); _confirm = Tone(new[] { 520.0, 780.0 }, 0.16, 0.22);
                var clock = Stopwatch.StartNew(); bool first = true; long topAt = 0; double closeAt = -1; int curX0 = -1, curY0 = -1; int btnWas = 0;
                var keys = new bool[256]; double mouseAt = -9; float ptrX = -1, ptrY = -1; RectangleF ptrWas = RectangleF.Empty;
                while (_run)
                {
                    MSG m; while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
                    double t = clock.Elapsed.TotalSeconds;
                    if (clock.ElapsedMilliseconds - topAt > 150) { SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); topAt = clock.ElapsedMilliseconds; }
                    // the fade: in over 0.7 s; out when told
                    double alpha = Ease(t / 0.7);
                    if (_closing) { if (closeAt < 0) closeAt = t; alpha *= 1 - Ease((t - closeAt) / 0.55); if (t - closeAt > 0.6) break; }
                    SetLayeredWindowAttributes(_hwnd, 0, (byte)(255 * alpha), 2);
                    // ---- input: the game's cursor and button; the keys while DOSBox is in front ----
                    if (_pick == PickNone)
                    {
                        bool front = Front();
                        int cx = CursorX, cy = CursorY, bt = Button;
                        // the game's cursor across the whole title, if it moves (its screen is 4:3; the cursor's range tells which size)
                        if (cx >= 0 && cy >= 0 && (cx != curX0 || cy != curY0))
                        {
                            if (curX0 >= 0) { float gw = cx > 640 || cy > 480 ? 1600f : 640f, gh = gw * 0.75f; ptrX = cx / gw * _W; ptrY = cy / gh * _H; mouseAt = t; }
                            curX0 = cx; curY0 = cy;
                        }
                        // the mouse itself (raw input); the pointer starts on the selected row
                        int rdx = _rawDX, rdy = _rawDY, clicks = _rawClicks, wheel = _rawWheel; _rawDX = _rawDY = _rawClicks = _rawWheel = 0;
                        if (!front) { rdx = rdy = clicks = wheel = 0; _rawAbs = false; }
                        if (_rawAbs) { _rawAbs = false; ptrX = (float)(_rawAbsX / 65535.0 * _W); ptrY = (float)(_rawAbsY / 65535.0 * _H); mouseAt = t; }
                        if (rdx != 0 || rdy != 0)
                        {
                            if (mouseAt < 0 || ptrX < 0) { var r0 = SelRect(); ptrX = r0.Left + r0.Width * 0.5f; ptrY = r0.Top + r0.Height * 0.5f; }
                            double k = RawSpeed * Math.Max(1.0, _W / 1920.0) * (1 + 0.035 * Math.Min(30, Math.Sqrt((double)rdx * rdx + (double)rdy * rdy)));
                            ptrX = (float)Math.Max(0, Math.Min(_W - 2, ptrX + rdx * k)); ptrY = (float)Math.Max(0, Math.Min(_H - 2, ptrY + rdy * k));
                            mouseAt = t;
                        }
                        int hit = -1;
                        if (mouseAt > 0)
                        {
                            hit = HitTest(ptrX, ptrY);
                            if (hit != _hover)
                            {
                                _hover = hit;
                                if (_view != V_NONE) { if (_vsel != hit) { _vsel = hit; _selAt = t; _vNeed = true; if (hit >= 0 && hit != VB_DOC) Play(_tick); } }   // (a reader: leaving a button lets it go)
                                else if (hit >= 0) { if (_docsOpen) { if (_dsel != hit) { _dsel = hit; _selAt = t; Play(_tick); } } else if (_optOpen) { if (_osel != hit) { _osel = hit; _selAt = t; Play(_tick); } } else if (_loadOpen) { if (_lsel != hit) { _lsel = hit; _selAt = t; Play(_tick); } } else if (_sel != hit) { _sel = hit; _selAt = t; Play(_tick); } }
                            }
                            if (_view == V_CLASSIFIED && (ptrX != _lastPtrX || ptrY != _lastPtrY)) ZoomFollow(ptrX, ptrY);     // (magnified: the pointer pans)
                            _lastPtrX = ptrX; _lastPtrY = ptrY;
                        }
                        if ((bt != 0 && btnWas == 0) || clicks > 0) Press(t, ptrX, ptrY, mouseAt > 0);
                        btnWas = bt;
                        if (wheel != 0) Key(wheel > 0 ? 0x26 : 0x28, t);
                        int qk; while (_testKeys.TryDequeue(out qk)) Key(qk, t);                    // (TESTING: keys queued from outside)
                        // (up, down, enter, esc, space; and for the readers: left, right, page up / down, home, end, backspace)
                        foreach (int vk in new[] { 0x26, 0x28, 0x0D, 0x1B, 0x20, 0x25, 0x27, 0x21, 0x22, 0x24, 0x23, 0x08 })
                        {
                            bool d = front && (GetAsyncKeyState(vk) & 0x8000) != 0;
                            if (d && !keys[vk]) Key(vk, t);
                            keys[vk] = d;
                        }
                    }
                    // ---- the reading: done once the view is up behind it (and it has had its time); then the fade ----
                    if (_readAt >= 0)
                    {
                        double rt = t - _readAt;
                        if (LoadShown && _shownAt < 0) _shownAt = t;
                        if (_readDoneAt < 0 && ((_shownAt >= 0 && rt >= ReadMin && t - _shownAt >= 0.3) || rt > ReadMax)) { _readDoneAt = t; Play(_confirm); }
                        else if (_readDoneAt < 0 && rt > 0.6 && rt < ReadSeconds && t - _readBlip > 0.42) { _readBlip = t; Play(_tick); }
                        if (_readDoneAt >= 0 && t - _readDoneAt > ReadHold) _closing = true;
                    }
                    // ---- draw: the menu's area (and the pointer's old and new places) over the art ----
                    bool reading = _readAt >= 0;
                    bool optUp = _optOpen || (t - _optAt) < 0.4, docsUp = _docsOpen || (t - _docsAt) < 0.4;
                    var dirty = reading ? Rectangle.Union(_menuArea, _readArea) : _loadOpen || (t - _loadAt) < 0.4 ? Rectangle.Union(_menuArea, _loadArea) : _menuArea;
                    if (optUp && !reading) dirty = Rectangle.Union(dirty, _optArea);
                    if (docsUp && !reading) dirty = Rectangle.Union(dirty, _docsArea);
                    RectangleF ptrNow = ptrX >= 0 && mouseAt > 0 && _pick == PickNone ? PointerBox(ptrX, ptrY) : RectangleF.Empty;
                    // THE WHOLE WINDOW for its first second and whenever Windows asked for a repaint; else only what moves.
                    // (Never DrawImageUnscaled: GDI+ scales it by the screen's DPI over the bitmap's 96 -- at 150% the art
                    // came out 1.5x, its top left only, with the menu's patches drawn 1:1 out of line with it.)
                    // (Reading: the whole window too while the art dims behind the panel.)
                    double dim = reading ? Ease((t - _pickAt) / 0.8) : 0;
                    bool full = first || _needFull || t < 1.0 || (reading && t - _pickAt < 0.9); if (full) _needFull = false;
                    var all = new Rectangle(0, 0, _W, _H);
                    // A RAPTOR DOCS READER covers the whole window: all of it when it changes, else just its moving parts
                    bool viewUp = ViewUp(t), viewFull = true; var vd = all;
                    try { vd = ViewDirty(t, out viewFull); } catch (Exception e) { DocsFault(e, t); }
                    if (viewUp) dirty = viewFull || full ? all : vd;
                    // the grail's gold: its own rectangle, every pass (not behind a reader)
                    bool fxOn = (GrailFx || GrailGlow) && !viewUp && _fxArea.Width > 0 && _fxArea.Height > 0;
                    if (fxOn && GrailFx) StepFx(t);
                    bool fgOn = !viewUp && _fgArea.Width > 0 && _fgArea.Height > 0;
                    bool fgDue = fgOn && t - _fgDrawnAt >= 1.0 / Math.Max(5, ForeFps);
                    if (fgDue) { StepFore(t); RenderFore(); _fgDrawnAt = t; }
                    long drawAt = Stopwatch.GetTimestamp();
                    using (var g = Graphics.FromImage(_buf))
                    {
                        if (full) { g.DrawImage(_bg, all, all, GraphicsUnit.Pixel); if (fgOn) DrawForeLayer(g); if (dim > 0) using (var db = new SolidBrush(C(0x000000, ReadDim * dim))) g.FillRectangle(db, all); }
                        g.SetClip(dirty); if (!ptrWas.IsEmpty) g.SetClip(ptrWas, System.Drawing.Drawing2D.CombineMode.Union); if (!ptrNow.IsEmpty) g.SetClip(ptrNow, System.Drawing.Drawing2D.CombineMode.Union);
                        if (fxOn) g.SetClip(_fxArea, System.Drawing.Drawing2D.CombineMode.Union);
                        if (fgDue) g.SetClip(_fgArea, System.Drawing.Drawing2D.CombineMode.Union);
                        g.DrawImage(_bg, all, all, GraphicsUnit.Pixel);
                        if (fgOn) DrawForeLayer(g);                       // (the dust: its finished layer, wherever this pass repaints)
                        if (fxOn) DrawGlow(g, t, 1);
                        if (dim > 0) using (var db = new SolidBrush(C(0x000000, ReadDim * dim))) g.FillRectangle(db, all);
                        if (fxOn && GrailFx) DrawFx(g, 1 - ReadDim * dim);
                        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                        DrawMenu(g, t);
                        if (_loadOpen || (t - _loadAt) < 0.4) DrawLoad(g, t);
                        if (optUp) DrawOptions(g, t);
                        try
                        {
                            if (docsUp) DrawDocsPanel(g, t);
                            if (viewUp) { RectangleF vc = dirty; vc = Union2(Union2(vc, ptrWas), ptrNow); DrawView(g, t, vc, dirty == all); }   // (what this pass repaints)
                        }
                        catch (Exception e) { DocsFault(e, t); }
                        if (reading) DrawRead(g, t);
                        if (!ptrNow.IsEmpty) DrawPointer(g, ptrX, ptrY);
                    }
                    using (var wg = Graphics.FromHwnd(_hwnd))
                    {
                        wg.PageUnit = GraphicsUnit.Pixel;
                        if (full) wg.DrawImage(_buf, all, all, GraphicsUnit.Pixel);
                        else
                        {
                            if (dirty.Width > 0 && dirty.Height > 0) wg.DrawImage(_buf, dirty, dirty, GraphicsUnit.Pixel);
                            if (fxOn && !dirty.Contains(_fxArea)) wg.DrawImage(_buf, _fxArea, _fxArea, GraphicsUnit.Pixel);
                            if (fgDue && !dirty.Contains(_fgArea)) wg.DrawImage(_buf, _fgArea, _fgArea, GraphicsUnit.Pixel);
                            foreach (var pr in new[] { ptrWas, ptrNow }) if (!pr.IsEmpty) { var r = Rectangle.Round(pr); wg.DrawImage(_buf, r, r, GraphicsUnit.Pixel); }
                        }
                    }
                    double dms = (Stopwatch.GetTimestamp() - drawAt) * 1000.0 / Stopwatch.Frequency;
                    Passes++; DrawMs += dms; if (dms > DrawMsMax) DrawMsMax = dms; if (dirty == all || full) FullPasses++;
                    ptrWas = ptrNow; first = false;
                    Thread.Sleep(14);
                }
            }
            catch (Exception e) { StartError = e.GetType().Name + ": " + e.Message; }
            finally
            {
                _shown = false;
                try
                {
                    uint rsz = (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE));
                    if (_rawBefore != null) RegisterRawInputDevices(_rawBefore, 1, rsz);
                    else RegisterRawInputDevices(new[] { new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 2, dwFlags = RIDEV_REMOVE, hwndTarget = IntPtr.Zero } }, 1, rsz);
                }
                catch { }
                if (_hwnd != IntPtr.Zero) { ShowWindow(_hwnd, 0); DestroyWindow(_hwnd); _hwnd = IntPtr.Zero; }
                try { UnregisterClassW(_cls, GetModuleHandleW(IntPtr.Zero)); } catch { }
                if (_bg != null) _bg.Dispose(); if (_buf != null) _buf.Dispose();
                if (_fgLayer != null) { _fgLayer.Dispose(); _fgLayer = null; } if (_glowImg != null) { _glowImg.Dispose(); _glowImg = null; }
                if (_curImg != null) { _curImg.Dispose(); _curImg = null; } if (_curAct != null) { _curAct.Dispose(); _curAct = null; }
                try { FreeDocs(); } catch { }
                _up.Set(); _gone.Set();
            }
        }
        bool Front()
        {
            uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p);
            return GamePid == 0 || p == (uint)GamePid || p == (uint)Process.GetCurrentProcess().Id;
        }
        static RectangleF Union2(RectangleF a, RectangleF b) { return a.IsEmpty ? b : b.IsEmpty ? a : RectangleF.Union(a, b); }
        /// <summary>The selected button of the layer on top (where the pointer starts).</summary>
        RectangleF SelRect()
        {
            if (_view != V_NONE) return _vsel >= 0 ? ViewRect(_vsel) : ViewRect(VB_NEXT);
            return _docsOpen ? _docsRect[_dsel] : _optOpen ? _optRect[_osel] : _loadOpen ? _slotRect[_lsel] : _rowRect[_sel];
        }

        // the art, cover-fit to the monitor, made once; and the menu's layout
        void Prepare()
        {
            _bg = new Bitmap(_W, _H, System.Drawing.Imaging.PixelFormat.Format32bppPArgb); _buf = new Bitmap(_W, _H, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            float ox = 0, oy = 0, sc = 1;
            using (var g = Graphics.FromImage(_bg))
            {
                g.Clear(Color.Black);
                try
                {
                    using (var art = Image.FromFile(ImagePath))
                    {
                        sc = Math.Max(_W / (float)art.Width, _H / (float)art.Height); float dw = art.Width * sc, dh = art.Height * sc; ox = (_W - dw) / 2; oy = (_H - dh) / 2;
                        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                        g.DrawImage(art, ox, oy, dw, dh);
                        _artX = ox; _artY = oy; _artW = dw; _artH = dh;
                    }
                }
                catch (Exception e) { Note = "title art: " + e.Message; _artX = 0; _artY = 0; _artW = _W; _artH = _H; }
            }
            // the column: rows below the art's credit line, centred on the title
            float cx = _artX + (float)ColX * _artW, y0 = _artY + (float)ColY * _artH, pitch = 66 * _s, rw = 420 * _s, rh = 52 * _s;
            for (int i = 0; i < R_DOCS; i++) { float yy = y0 + i * pitch + (i > 0 ? 22 * _s : 0); _rowRect[i] = new RectangleF(cx - rw / 2, yy, rw, rh); }
            _rowRect[R_DOCS] = new RectangleF(cx - rw * 0.36f, _rowRect[R_QUIT].Bottom + 58 * _s, rw * 0.72f, 40 * _s);
            var a = RectangleF.Union(_rowRect[0], _rowRect[R_DOCS]); a.Inflate(150 * _s, 40 * _s);
            _menuArea = Rectangle.Intersect(Rectangle.Round(a), new Rectangle(0, 0, _W, _H));
            // the slot list, over the column (the menu steps back while it shows)
            float pw = 760 * _s, ph = 470 * _s, px = cx - pw / 2, py = y0 - 40 * _s;
            _loadPanel = new RectangleF(px, py, pw, ph);
            for (int i = 0; i < 6; i++) _slotRect[i] = new RectangleF(px + 36 * _s, py + 96 * _s + i * 58 * _s + (i == 5 ? 16 * _s : 0), pw - 72 * _s, 50 * _s);
            var la = _loadPanel; la.Inflate(40 * _s, 40 * _s);
            _loadArea = Rectangle.Intersect(Rectangle.Round(la), new Rectangle(0, 0, _W, _H));
            // the options panel: the slot list's width and place, as tall as its two rows need
            float oph = 300 * _s;
            _optPanel = new RectangleF(px, py, pw, oph);
            _optRect[O_TEX] = new RectangleF(px + 36 * _s, py + 96 * _s, pw - 72 * _s, 92 * _s);
            _optRect[O_BACK] = new RectangleF(px + 36 * _s, py + 96 * _s + 92 * _s + 22 * _s, pw - 72 * _s, 50 * _s);
            var oa = _optPanel; oa.Inflate(40 * _s, 40 * _s);
            _optArea = Rectangle.Intersect(Rectangle.Round(oa), new Rectangle(0, 0, _W, _H));
            PrepareDocs(px, py, pw);            // (RAPTOR DOCS: its panel where OPTIONS' is, and the readers)
            LoadCursors();
            // the reading panel: the same column, a little wider (the archive's name goes in its title)
            float rw2 = 900 * _s, rh2 = 462 * _s, rx = Math.Max(24 * _s, Math.Min(_W - rw2 - 24 * _s, cx - rw2 / 2)), ry = Math.Max(24 * _s, Math.Min(_H - rh2 - 24 * _s, y0 - 30 * _s));
            _readPanel = new RectangleF(rx, ry, rw2, rh2);
            var ra = _readPanel; ra.Inflate(40 * _s, 40 * _s);
            _readArea = Rectangle.Intersect(Rectangle.Round(ra), new Rectangle(0, 0, _W, _H));
            PrepareFx();                        // (the grail's gold flakes: their place and repaint rectangle)
        }
        float _artX, _artY, _artW, _artH; RectangleF _loadPanel, _readPanel; Rectangle _readArea;

        int HitTest(float x, float y)
        {
            if (_view != V_NONE) return ViewHit(x, y);
            if (_docsOpen) return DocsHit(x, y);
            if (_optOpen) { for (int i = 0; i < OROWS; i++) if (_optRect[i].Contains(x, y)) return i; return -1; }
            if (_loadOpen) { for (int i = 0; i < 6; i++) if (_slotRect[i].Contains(x, y)) return i; return -1; }
            for (int i = 0; i < ROWS; i++) { if (!Enabled(i)) continue; var r = _rowRect[i]; r.Inflate(0, 6 * _s); if (r.Contains(x, y)) return i; }
            return -1;
        }
        void Key(int vk, double t)
        {
            if (ViewKey(vk, t) || DocsKey(vk, t)) return;
            if (vk != 0x26 && vk != 0x28 && vk != 0x0D && vk != 0x1B && vk != 0x20) return;        // (the readers' keys mean nothing here)
            if (_optOpen)
            {
                if (vk == 0x26) { _osel = (_osel + OROWS - 1) % OROWS; _selAt = t; Play(_tick); }
                else if (vk == 0x28) { _osel = (_osel + 1) % OROWS; _selAt = t; Play(_tick); }
                else if (vk == 0x0D || vk == 0x20) Activate(t);
                else if (vk == 0x1B) { _optOpen = false; _optAt = t; LayerChanged(t); Play(_tick); }
                return;
            }
            if (_loadOpen)
            {
                if (vk == 0x26) { _lsel = (_lsel + 5) % 6; _selAt = t; Play(_tick); }
                else if (vk == 0x28) { _lsel = (_lsel + 1) % 6; _selAt = t; Play(_tick); }
                else if (vk == 0x0D || vk == 0x20) Activate(t);
                else if (vk == 0x1B) { _loadOpen = false; _loadAt = t; LayerChanged(t); Play(_tick); }
                return;
            }
            if (vk == 0x26) { _sel = Step(_sel, -1); _selAt = t; Play(_tick); }
            else if (vk == 0x28) { _sel = Step(_sel, 1); _selAt = t; Play(_tick); }
            else if (vk == 0x0D || vk == 0x20) Activate(t);
        }
        void Activate(double t)
        {
            if (_view != V_NONE) { if (_vsel >= 0) ViewActivate(_vsel, t); return; }
            if (_docsOpen) { DocsActivate(t); return; }
            if (_optOpen)
            {
                if (_osel == O_BACK) { _optOpen = false; _optAt = t; LayerChanged(t); Play(_tick); return; }
                Play(_tick); _optSoonAt = t; return;                                                     // (not offered yet)
            }
            if (_loadOpen)
            {
                if (_lsel == 5) { _loadOpen = false; _loadAt = t; LayerChanged(t); Play(_tick); return; }    // BACK
                var s = _lsel < Slots.Length ? Slots[_lsel] : null;
                if (s == null || !s.Usable) { Play(_tick); return; }
                Play(_confirm); _pickSlot = s.Index; _pickAt = t; BeginRead(t, s.Index); _pick = PickLoad; return;
            }
            switch (_sel)
            {
                case R_CONT: if (NewestSlot < 0) { Play(_tick); break; } Play(_confirm); _pickAt = t; _pickSlot = NewestSlot; BeginRead(t, NewestSlot); _pick = PickLoad; break;
                case R_NEW: Play(_confirm); _pickAt = t; _pick = PickNew; break;
                case R_LOAD: Play(_confirm); _loadOpen = true; _loadAt = t; LayerChanged(t); _lsel = NewestSlot >= 0 ? NewestSlot : 5; break;
                case R_OPT: Play(_confirm); _optOpen = true; _optAt = t; LayerChanged(t); _osel = O_TEX; break;
                case R_DOCS: OpenDocsPanel(t); break;
                case R_QUIT: Play(_confirm); _pickAt = t; _pick = PickQuit; break;
            }
        }

        // type with the visor's letter-spacing, one character at a time
        static float Spaced(Graphics g, string s, Font f, Brush b, float x, float y, float track, bool measureOnly)
        {
            float w = 0; var fmt = StringFormat.GenericTypographic;
            foreach (char ch in s)
            {
                string c = ch.ToString(); float cw = ch == ' ' ? g.MeasureString("n", f, 1000, fmt).Width : g.MeasureString(c, f, 1000, fmt).Width;
                if (!measureOnly) g.DrawString(c, f, b, x + w, y, fmt);
                w += cw + track;
            }
            return w - track;
        }
        void Brackets(Graphics g, RectangleF r, Color c, float len, float th)
        {
            using (var p = new Pen(c, th))
            {
                g.DrawLines(p, new[] { new PointF(r.Left, r.Top + len), new PointF(r.Left, r.Top), new PointF(r.Left + len, r.Top) });
                g.DrawLines(p, new[] { new PointF(r.Right - len, r.Top), new PointF(r.Right, r.Top), new PointF(r.Right, r.Top + len) });
                g.DrawLines(p, new[] { new PointF(r.Left, r.Bottom - len), new PointF(r.Left, r.Bottom), new PointF(r.Left + len, r.Bottom) });
                g.DrawLines(p, new[] { new PointF(r.Right - len, r.Bottom), new PointF(r.Right, r.Bottom), new PointF(r.Right, r.Bottom - len) });
            }
        }

        void DrawMenu(Graphics g, double t)
        {
            double back = _loadOpen ? Ease((t - _loadAt) / 0.3) : 1 - Ease((t - _loadAt) / 0.3);     // the list in front: the menu steps back
            back = Math.Max(back, _optOpen ? Ease((t - _optAt) / 0.3) : 1 - Ease((t - _optAt) / 0.3));   // (and behind the options)
            back = Math.Max(back, DocsBack(t));                                                          // (and behind RAPTOR DOCS)
            double leave = _pickAt >= 0 ? Ease((t - _pickAt) / 0.35) : 0;
            using (var big = new Font("Consolas", 30 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var small = new Font("Consolas", 21 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var sub = new Font("Consolas", 14 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                for (int i = 0; i < ROWS; i++)
                {
                    // each row flickers on in turn as the title comes up (the HUD keys' power-up)
                    double on = t - (0.55 + i * 0.1); if (on < 0) continue;
                    double vis = on < 0.16 ? (Hash(i, (int)(t * 40)) > 0.45 ? 1 : 0.15) : 1;
                    vis *= (1 - back) * (1 - leave);
                    if (vis <= 0.01) continue;
                    var r = _rowRect[i]; bool sel = i == _sel && !_loadOpen && !_optOpen && !_docsOpen && _view == V_NONE, picked = _pickAt >= 0 && sel;
                    var f = i == R_DOCS ? small : big;
                    float tw = Spaced(g, Labels[i], f, null, 0, 0, 7 * _s, true), tx = r.Left + (r.Width - tw) / 2, ty = r.Top + (r.Height - f.Height) / 2 - (i == R_CONT ? 7 * _s : 0);
                    if (sel)
                    {
                        // the lock-on: a glass bar, brackets snapping in from wide, chevrons, a scan running across
                        double k = EaseBack((t - _selAt) / 0.28); var br = r; br.Inflate((float)(1 - k) * 40 * _s, (float)(1 - k) * 10 * _s);
                        using (var gl = new System.Drawing.Drawing2D.LinearGradientBrush(r, C(Glass, 0.0), C(Glass, 0.0), 0f))
                        {
                            var cb = new System.Drawing.Drawing2D.ColorBlend(); cb.Positions = new[] { 0f, 0.25f, 0.75f, 1f };
                            cb.Colors = new[] { C(Glass, 0), C(Amber, 0.16 * vis), C(Amber, 0.16 * vis), C(Glass, 0) }; gl.InterpolationColors = cb;
                            g.FillRectangle(gl, r);
                        }
                        double sweep = ((t - _selAt) * 0.7) % 1.0; float sx = r.Left + (float)sweep * r.Width;
                        using (var sb = new SolidBrush(C(AmberHi, 0.10 * vis))) g.FillRectangle(sb, sx - 30 * _s, r.Top, 60 * _s, r.Height);
                        Brackets(g, br, C(picked && ((int)(t * 18) & 1) == 0 ? AmberHi : Amber, 0.95 * vis), 12 * _s, Math.Max(2f, 2.2f * _s));
                        float ch = (float)(Math.Sin(t * 5) * 4 * _s);
                        using (var cbr = new SolidBrush(C(Amber, 0.9 * vis))) { g.DrawString("›", f, cbr, tx - 44 * _s + ch, ty); g.DrawString("‹", f, cbr, tx + tw + 20 * _s - ch, ty); }
                    }
                    // the label: a dark halo for the art behind it, then the type
                    using (var sh = new SolidBrush(C(0x000000, 0.65 * vis))) { Spaced(g, Labels[i], f, sh, tx + 2 * _s, ty + 2 * _s, 7 * _s, false); }
                    bool off = !Enabled(i);
                    int ink = sel ? AmberHi : (off ? AmberDim : Amber); double ia = sel ? 1 : off ? 0.42 : 0.82;
                    using (var tb = new SolidBrush(C(ink, ia * vis))) Spaced(g, Labels[i], f, tb, tx, ty, 7 * _s, false);
                    if (i == R_CONT)
                    {
                        // under CONTINUE: the save it will load (or a new game)
                        string line = NewestSlot >= 0 ? string.Format("{0}  //  {1}", Slots[NewestSlot].Name.ToUpperInvariant(), Slots[NewestSlot].When.ToString("MMM dd  HH:mm").ToUpperInvariant()) : "NO SAVED LOG";
                        float lw = Spaced(g, line, sub, null, 0, 0, 2 * _s, true);
                        using (var lb = new SolidBrush(C(sel ? Amber : AmberDim, (off ? 0.45 : 0.9) * vis))) Spaced(g, line, sub, lb, r.Left + (r.Width - lw) / 2, ty + f.Height + 2 * _s, 2 * _s, false);
                    }
                    if (i == R_QUIT)
                    {
                        // the divider before RAPTOR DOCS: a thin rule fading at both ends, a diamond at its middle
                        float dy = (r.Bottom + _rowRect[R_DOCS].Top) / 2, dw = 200 * _s, dcx = r.Left + r.Width / 2;
                        using (var lg = new System.Drawing.Drawing2D.LinearGradientBrush(new RectangleF(dcx - dw, dy - 1, 2 * dw, 2), C(Amber, 0), C(Amber, 0), 0f))
                        {
                            var cb = new System.Drawing.Drawing2D.ColorBlend(); cb.Positions = new[] { 0f, 0.5f, 1f }; cb.Colors = new[] { C(Amber, 0), C(Amber, 0.55 * vis), C(Amber, 0) }; lg.InterpolationColors = cb;
                            g.FillRectangle(lg, dcx - dw, dy - 0.75f * _s, 2 * dw, 1.5f * _s);
                        }
                        float d = 4 * _s; using (var db = new SolidBrush(C(Amber, 0.8 * vis))) g.FillPolygon(db, new[] { new PointF(dcx, dy - d), new PointF(dcx + d, dy), new PointF(dcx, dy + d), new PointF(dcx - d, dy) });
                    }
                }
            }
        }

        void DrawLoad(Graphics g, double t)
        {
            double a = _loadOpen ? Ease((t - _loadAt) / 0.3) : 1 - Ease((t - _loadAt) / 0.3);
            double leave = _pickAt >= 0 ? Ease((t - _pickAt) / 0.35) : 0; a *= 1 - leave;
            if (a <= 0.01) return;
            var p = _loadPanel; float grow = (float)(1 - Ease((t - _loadAt) / 0.3)) * (_loadOpen ? 1 : 0); var pr = p; pr.Inflate(-grow * 30 * _s, -grow * 30 * _s);
            using (var gb = new SolidBrush(C(0x050302, 0.84 * a))) g.FillRectangle(gb, pr);
            using (var ln = new SolidBrush(C(0x000000, 0.22 * a))) for (float yy = pr.Top; yy < pr.Bottom; yy += 3 * _s) g.FillRectangle(ln, pr.Left, yy, pr.Width, Math.Max(1f, _s));
            Brackets(g, pr, C(Amber, 0.9 * a), 22 * _s, Math.Max(2f, 2.4f * _s));
            using (var hf = new Font("Consolas", 22 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var rf = new Font("Consolas", 20 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var sf = new Font("Consolas", 14 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                using (var hb = new SolidBrush(C(AmberHi, a))) Spaced(g, "RAPTOR H.U.D. // MEMORY CORE // RESTORE", hf, hb, pr.Left + 36 * _s, pr.Top + 30 * _s, 3 * _s, false);
                using (var rl = new SolidBrush(C(Amber, 0.5 * a))) g.FillRectangle(rl, pr.Left + 36 * _s, pr.Top + 70 * _s, pr.Width - 72 * _s, Math.Max(1f, 1.2f * _s));
                for (int i = 0; i < 6; i++)
                {
                    var r = _slotRect[i]; bool sel = i == _lsel; var s = i < 5 && i < Slots.Length ? Slots[i] : null; bool ok = i == 5 || (s != null && s.Usable);
                    if (sel)
                    {
                        using (var sb = new SolidBrush(C(Amber, (ok ? 0.16 : 0.07) * a))) g.FillRectangle(sb, r);
                        double k = EaseBack((t - _selAt) / 0.25); var br = r; br.Inflate((float)(1 - k) * 24 * _s, (float)(1 - k) * 8 * _s);
                        Brackets(g, br, C(ok ? Amber : AmberDim, 0.95 * a), 10 * _s, Math.Max(2f, 2f * _s));
                    }
                    int ink = !ok ? AmberDim : sel ? AmberHi : Amber; float ty = r.Top + (r.Height - rf.Height) / 2;
                    using (var tb = new SolidBrush(C(ink, (ok ? 1 : 0.6) * a)))
                    {
                        if (i == 5) { float bw = Spaced(g, "BACK", rf, null, 0, 0, 5 * _s, true); Spaced(g, "BACK", rf, tb, r.Left + (r.Width - bw) / 2, ty, 5 * _s, false); continue; }
                        Spaced(g, string.Format("{0:00}", i + 1), rf, tb, r.Left + 18 * _s, ty, 3 * _s, false);
                        Spaced(g, s != null && s.Usable ? s.Name.ToUpperInvariant() : "-- EMPTY --", rf, tb, r.Left + 86 * _s, ty, 3 * _s, false);
                        if (s != null && s.Usable)
                        {
                            string when = s.When.ToString("MMM dd  HH:mm").ToUpperInvariant(); float ww = Spaced(g, when, sf, null, 0, 0, 2 * _s, true);
                            using (var wb = new SolidBrush(C(sel ? Amber : AmberDim, a))) Spaced(g, when, sf, wb, r.Right - 18 * _s - ww, r.Top + (r.Height - sf.Height) / 2, 2 * _s, false);
                            if (i == NewestSlot) using (var nb = new SolidBrush(C(Amber, 0.75 * a))) g.FillEllipse(nb, r.Left + 64 * _s, r.Top + r.Height / 2 - 4 * _s, 8 * _s, 8 * _s);
                        }
                    }
                }
            }
        }
        // THE OPTIONS PANEL (see O_TEX): the slot list's look -- dark glass, scan lines, the visor's brackets. TEXTURE QUALITY is
        // drawn dim (as an empty slot is): its two settings with the one in use underlined, what each means, a COMING SOON tag
        // (picking it flashes OFFLINE // COMING SOON); BACK below.
        void DrawOptions(Graphics g, double t)
        {
            double a = _optOpen ? Ease((t - _optAt) / 0.3) : 1 - Ease((t - _optAt) / 0.3);
            double leave = _pickAt >= 0 ? Ease((t - _pickAt) / 0.35) : 0; a *= 1 - leave;
            if (a <= 0.01) return;
            var p = _optPanel; float grow = (float)(1 - Ease((t - _optAt) / 0.3)) * (_optOpen ? 1 : 0); var pr = p; pr.Inflate(-grow * 30 * _s, -grow * 30 * _s);
            using (var gb = new SolidBrush(C(0x050302, 0.84 * a))) g.FillRectangle(gb, pr);
            using (var ln = new SolidBrush(C(0x000000, 0.22 * a))) for (float yy = pr.Top; yy < pr.Bottom; yy += 3 * _s) g.FillRectangle(ln, pr.Left, yy, pr.Width, Math.Max(1f, _s));
            Brackets(g, pr, C(Amber, 0.9 * a), 22 * _s, Math.Max(2f, 2.4f * _s));
            using (var hf = new Font("Consolas", 22 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var rf = new Font("Consolas", 20 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var sf = new Font("Consolas", 14 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                using (var hb = new SolidBrush(C(AmberHi, a))) Spaced(g, "RAPTOR H.U.D. // SYSTEM // OPTIONS", hf, hb, pr.Left + 36 * _s, pr.Top + 30 * _s, 3 * _s, false);
                using (var rl = new SolidBrush(C(Amber, 0.5 * a))) g.FillRectangle(rl, pr.Left + 36 * _s, pr.Top + 70 * _s, pr.Width - 72 * _s, Math.Max(1f, 1.2f * _s));
                // TEXTURE QUALITY -- not offered yet
                var r = _optRect[O_TEX]; bool sel = _osel == O_TEX;
                if (sel)
                {
                    using (var sb = new SolidBrush(C(Amber, 0.07 * a))) g.FillRectangle(sb, r);
                    double k = EaseBack((t - _selAt) / 0.25); var br = r; br.Inflate((float)(1 - k) * 24 * _s, (float)(1 - k) * 8 * _s);
                    Brackets(g, br, C(AmberDim, 0.95 * a), 10 * _s, Math.Max(2f, 2f * _s));
                }
                float ty = r.Top + 14 * _s;
                using (var tb = new SolidBrush(C(AmberDim, 0.8 * a))) Spaced(g, "TEXTURE QUALITY", rf, tb, r.Left + 18 * _s, ty, 3 * _s, false);
                string[] q = { "NORMAL", "ULTRA" }; bool ultra = string.Equals(TextureQuality, "ULTRA", StringComparison.OrdinalIgnoreCase);
                float w0 = Spaced(g, q[0], rf, null, 0, 0, 3 * _s, true), w1 = Spaced(g, q[1], rf, null, 0, 0, 3 * _s, true);
                float x1 = r.Right - 18 * _s - w1, x0 = x1 - 34 * _s - w0;
                for (int j = 0; j < 2; j++)
                {
                    bool cur = (j == 1) == ultra; float xx = j == 0 ? x0 : x1, ww = j == 0 ? w0 : w1;
                    using (var vb = new SolidBrush(C(cur ? Amber : AmberDim, (cur ? 0.75 : 0.4) * a))) Spaced(g, q[j], rf, vb, xx, ty, 3 * _s, false);
                    if (cur) using (var ub = new SolidBrush(C(Amber, 0.55 * a))) g.FillRectangle(ub, xx, ty + rf.Height + 3 * _s, ww, Math.Max(1f, 1.5f * _s));
                }
                float sy = r.Top + 60 * _s;
                using (var db = new SolidBrush(C(AmberDim, 0.65 * a))) Spaced(g, "NORMAL: 2K  //  ULTRA: 4K", sf, db, r.Left + 18 * _s, sy, 2 * _s, false);
                bool flash = t - _optSoonAt < 1.6; string tag = flash ? "OFFLINE  //  COMING SOON" : "COMING SOON";
                double fa = flash && (t - _optSoonAt) < 0.14 ? (Hash(7, (int)(t * 50)) > 0.4 ? 1 : 0.2) : 1;
                float tw = Spaced(g, tag, sf, null, 0, 0, 2 * _s, true), tx = r.Right - 18 * _s - tw;
                using (var tp = new Pen(C(flash ? Amber : AmberDim, 0.8 * fa * a), Math.Max(1f, 1.2f * _s))) g.DrawRectangle(tp, tx - 8 * _s, sy - 4 * _s, tw + 16 * _s, sf.Height + 8 * _s);
                using (var gb2 = new SolidBrush(C(flash ? AmberHi : Amber, 0.85 * fa * a))) Spaced(g, tag, sf, gb2, tx, sy, 2 * _s, false);
                // BACK, as the slot list's
                var rb = _optRect[O_BACK]; bool bsel = _osel == O_BACK;
                if (bsel)
                {
                    using (var sb = new SolidBrush(C(Amber, 0.16 * a))) g.FillRectangle(sb, rb);
                    double k = EaseBack((t - _selAt) / 0.25); var br = rb; br.Inflate((float)(1 - k) * 24 * _s, (float)(1 - k) * 8 * _s);
                    Brackets(g, br, C(Amber, 0.95 * a), 10 * _s, Math.Max(2f, 2f * _s));
                }
                using (var bb = new SolidBrush(C(bsel ? AmberHi : Amber, a))) { float bw = Spaced(g, "BACK", rf, null, 0, 0, 5 * _s, true); Spaced(g, "BACK", rf, bb, rb.Left + (rb.Width - bw) / 2, rb.Top + (rb.Height - rf.Height) / 2, 5 * _s, false); }
            }
        }
        void BeginRead(double t, int slot)
        {
            _readSlot = slot; _readName = slot >= 0 && slot < Slots.Length ? (Slots[slot].Name ?? "").Trim().ToUpperInvariant() : "";
            _readAt = t + 0.3; _readDoneAt = -1; _readP = 0; _shownAt = -1;           // (after the menu has stepped away)
            LoadProgress = RoomLoadAhead ? 0f : -1f; _progBase = -1; _readPT = -1;
        }
        static string Typed(string s, double t, double from, double cps) { int n = (int)Math.Max(0, Math.Min(s.Length, (t - from) * cps)); return s.Substring(0, n); }
        // THE MEMORY CORE READING IN -- the visor's panel (ScanWire's VisorMenu.DrawArchive, read access), drawn on the title
        void DrawRead(Graphics g, double t)
        {
            if (t < _readAt) return;
            double rt = t - _readAt; bool done = _readDoneAt >= 0;
            double open = Ease(rt / 0.35);
            var p = _readPanel; float ph = (float)(p.Height * Math.Max(0.006, open)); var pr = new RectangleF(p.Left, p.Top + (p.Height - ph) / 2, p.Width, ph);
            using (var gb = new SolidBrush(C(0x050302, 0.9))) g.FillRectangle(gb, pr);
            using (var ln = new SolidBrush(C(0x000000, 0.22))) for (float yy = pr.Top; yy < pr.Bottom; yy += 3 * _s) g.FillRectangle(ln, pr.Left, yy, pr.Width, Math.Max(1f, _s));
            if (open < 0.98)
            {
                // opening from a bright line, as the visor's panels do
                using (var lb = new SolidBrush(C(AmberHi, 0.9 * (1 - open)))) g.FillRectangle(lb, pr.Left, pr.Top + pr.Height / 2 - 1.5f * _s, pr.Width, 3 * _s);
                Brackets(g, pr, C(Amber, 0.9 * open), 22 * _s, Math.Max(2f, 2.4f * _s));
                return;
            }
            Brackets(g, pr, C(Amber, 0.9), 22 * _s, Math.Max(2f, 2.4f * _s));
            double p01 = done ? 1 : ReadBar(rt, t);
            if (!done && _shownAt >= 0) p01 = Math.Max(p01, _readP + (1 - _readP) * Math.Min(1, (t - _shownAt) / 0.3));
            _readP = p01;
            float x0 = pr.Left + 40 * _s, x1 = pr.Right - 40 * _s, y = pr.Top + 28 * _s;
            using (var fSmall = new Font("Consolas", 15 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var fTitle = new Font("Consolas", 34 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var fRow = new Font("Consolas", 26 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var fHex = new Font("Consolas", 14 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var bHi = new SolidBrush(C(AmberHi, 0.97)))
            using (var bAm = new SolidBrush(C(Amber, 0.92)))
            using (var bDim = new SolidBrush(C(AmberDim, 0.9)))
            using (var thin = new Pen(C(AmberDim, 0.8), Math.Max(1f, _s)))
            {
                Spaced(g, "RAPTOR H.U.D.  //  MEMORY CORE  //  READ ACCESS", fSmall, bDim, x0, y, 2 * _s, false);
                // the title: typed, its dots counting while it works; done = steady (after a short blink)
                string nm = _readName.Length > 0 ? _readName : "UNNAMED";
                string busy = string.Format("INITIATING LOG FILE \"{0}\"", nm);
                string title = done ? "LOG FILE INITIATED." : Typed(busy, t, _readAt + 0.15, 34) + (rt > 0.7 ? new string('.', 1 + (int)(rt * 3) % 3) : "");
                float tw = Spaced(g, busy + "...", fTitle, null, 0, 0, 2 * _s, true), room = x1 - x0;
                using (var fFit = tw > room ? new Font("Consolas", 34 * _s * room / tw, FontStyle.Bold, GraphicsUnit.Pixel) : null)
                    if (!done || ((int)((t - _readDoneAt) * 8) & 1) == 0 || t - _readDoneAt > 0.3)
                        Spaced(g, title, done || fFit == null ? fTitle : fFit, bHi, x0, y + 30 * _s, 2 * _s, false);
                float ry = pr.Top + 118 * _s; g.DrawLine(thin, x0, ry, x1, ry);
                // which archive
                Spaced(g, Typed(string.Format("ARCHIVE {0:00}  //  {1}", _readSlot + 1, nm), t, _readAt + 0.35, 60), fRow, bAm, x0, ry + 20 * _s, 3 * _s, false);
                // the fill bar, segmented, its leading edge bright
                float by0 = ry + 84 * _s, by1 = by0 + 38 * _s;
                g.DrawRectangle(thin, x0, by0, x1 - x0, by1 - by0);
                int segs = 40; float sw = (x1 - x0 - 8 * _s) / segs; int lit = (int)Math.Floor(p01 * segs);
                for (int i = 0; i < lit; i++) g.FillRectangle(i == lit - 1 && !done ? bHi : bAm, x0 + 4 * _s + i * sw, by0 + 4 * _s, sw - 3 * _s, by1 - by0 - 8 * _s);
                string pct = string.Format("{0,3}%", (int)Math.Round(p01 * 100)); float pw = Spaced(g, pct, fSmall, null, 0, 0, 1 * _s, true);
                Spaced(g, pct, fSmall, bDim, x1 - pw, by1 + 8 * _s, 1 * _s, false);
                Spaced(g, done ? "INTEGRITY VERIFIED" : LoadProgress > 0 && RoomStage != null ? RoomStage : "RESTORING ARCHIVE FROM MEMORY CORE", fSmall, bDim, x0, by1 + 8 * _s, 2 * _s, false);
                // the stream: lines of hex scrolling up under the bar, newest brightest (still once it is done)
                int k = (int)((done ? _readDoneAt - _readAt : rt) * 14); float hy = by1 + 44 * _s;
                for (int j = 0; j < 6; j++)
                {
                    int line = k - 5 + j; if (line < 0) continue;
                    var sb = new System.Text.StringBuilder(); sb.AppendFormat("{0:X6}  ", 0x1000 + line * 0x30);
                    for (int b = 0; b < 16; b++) { sb.AppendFormat("{0:X2} ", (int)(Hash(line * 31 + _readSlot, b) * 255)); if (b == 7) sb.Append(' '); }
                    double a = done ? 0.35 : (j == 5 ? 0.95 : 0.25 + 0.1 * j);
                    using (var hb = new SolidBrush(C(j == 5 && !done ? Amber : AmberDim, a))) g.DrawString(sb.ToString(), fHex, hb, x0, hy + j * 19 * _s);
                }
                Spaced(g, done ? "> LOG FILE INITIATED  //  RESUMING" : "> DO NOT POWER DOWN THE VISOR", fSmall, done ? bAm : bDim, x0, pr.Bottom - 40 * _s, 2 * _s, false);
            }
        }
        // THE GAME'S OWN POINTER (Josh, 2026-10-10: "a similar cursor to the one in-game ... more like a small reticule"): the
        // game's MICE\POINTER.PCX -- the diamond crosshair it uses over its interface -- and MICE\ACTIVE.PCX, its hot variant,
        // over a row that can be picked. Index 0 is see-through; the hot spot is the middle. Drawn smooth at the size it has in
        // game (CursorScale x the screen's width over the game's 1600, as the visor maps it). The drawn arrow only if the files cannot be read.
        Bitmap _curImg, _curAct; float _curHotX, _curHotY;
        public double CursorScale = 1.0;
        float CurK { get { return (float)(CursorScale * _W / 1600.0); } }      // (as in game: the 1600 game px across the visor's width)
        static Bitmap ReadPcx(string path)
        {
            byte[] f = System.IO.File.ReadAllBytes(path);
            if (f.Length < 128 + 769 || f[0] != 0x0A || f[3] != 8 || f[65] != 1 || f[f.Length - 769] != 0x0C) return null;
            int w = BitConverter.ToUInt16(f, 8) - BitConverter.ToUInt16(f, 4) + 1, h = BitConverter.ToUInt16(f, 10) - BitConverter.ToUInt16(f, 6) + 1, bpl = BitConverter.ToUInt16(f, 66);
            if (w <= 0 || h <= 0 || w > 256 || h > 256 || bpl < w) return null;
            var idx = new byte[bpl * h]; int src = 128, end = f.Length - 769, dst = 0;
            while (dst < idx.Length && src < end)
            {
                byte b = f[src++]; int run = 1;
                if ((b & 0xC0) == 0xC0) { run = b & 0x3F; if (src >= end) break; b = f[src++]; }
                while (run-- > 0 && dst < idx.Length) idx[dst++] = b;
            }
            int pal = f.Length - 768;
            var bm = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
            {
                int v = idx[y * bpl + x];
                bm.SetPixel(x, y, v == 0 ? Color.FromArgb(0, 0, 0, 0) : Color.FromArgb(255, f[pal + v * 3], f[pal + v * 3 + 1], f[pal + v * 3 + 2]));
            }
            return bm;
        }
        void LoadCursors()
        {
            if (_curImg != null || string.IsNullOrEmpty(SaveDir)) return;
            try
            {
                _curImg = ReadPcx(System.IO.Path.Combine(SaveDir, "MICE", "POINTER.PCX"));
                try { _curAct = ReadPcx(System.IO.Path.Combine(SaveDir, "MICE", "ACTIVE.PCX")); } catch { _curAct = null; }
                if (_curImg != null) { _curHotX = _curImg.Width / 2f; _curHotY = _curImg.Height / 2f; }
            }
            catch (Exception e) { _curImg = null; Note = (Note.Length > 0 ? Note + "; " : "") + "pointer art: " + e.Message; }
        }
        /// <summary>The pointer's box at (x, y) (its hot spot) -- what the redraw must cover, its shadow included.</summary>
        RectangleF PointerBox(float x, float y)
        {
            if (_curImg == null) return new RectangleF(x - 4, y - 4, 34 * _s + 8, 40 * _s + 8);
            float k = CurK; return new RectangleF(x - _curHotX * k - 4, y - _curHotY * k - 4, _curImg.Width * k + 8 + 3 * k, _curImg.Height * k + 8 + 3 * k);
        }
        void DrawPointer(Graphics g, float x, float y)
        {
            if (_curImg != null)
            {
                var img = _hover >= 0 && _curAct != null ? _curAct : _curImg; float ck = CurK;
                var im = g.InterpolationMode; var po = g.PixelOffsetMode;
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear; g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
                var r = new RectangleF(x - _curHotX * ck, y - _curHotY * ck, img.Width * ck, img.Height * ck);
                // a soft shadow under it, for the art behind (the same image, black, a little down and right)
                using (var ia = new System.Drawing.Imaging.ImageAttributes())
                {
                    var cm = new System.Drawing.Imaging.ColorMatrix(new float[][] { new float[] { 0, 0, 0, 0, 0 }, new float[] { 0, 0, 0, 0, 0 }, new float[] { 0, 0, 0, 0, 0 }, new float[] { 0, 0, 0, 0.55f, 0 }, new float[] { 0, 0, 0, 0, 1 } });
                    ia.SetColorMatrix(cm);
                    var sr = r; sr.Offset(2 * ck, 2 * ck);
                    g.DrawImage(img, Rectangle.Round(sr), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
                }
                g.DrawImage(img, r, new RectangleF(0, 0, img.Width, img.Height), GraphicsUnit.Pixel);
                g.InterpolationMode = im; g.PixelOffsetMode = po;
                return;
            }
            float k = _s * 1.3f; var pts = new[] { new PointF(x, y), new PointF(x, y + 26 * k), new PointF(x + 7 * k, y + 19 * k), new PointF(x + 12 * k, y + 29 * k), new PointF(x + 16 * k, y + 27 * k), new PointF(x + 11 * k, y + 17 * k), new PointF(x + 20 * k, y + 17 * k) };
            using (var sh = new SolidBrush(C(0x000000, 0.6))) { var s2 = new PointF[pts.Length]; for (int i = 0; i < pts.Length; i++) s2[i] = new PointF(pts[i].X + 2 * _s, pts[i].Y + 2 * _s); g.FillPolygon(sh, s2); }
            using (var fb = new SolidBrush(C(Amber, 0.95))) g.FillPolygon(fb, pts);
            using (var ob = new Pen(C(0x2A1500, 0.9), Math.Max(1f, _s))) g.DrawPolygon(ob, pts);
        }

        // ---- THE GRAIL'S GOLD (Josh, 2026-10-13: "particle effects there of very high rez gold flakes pulsing subtly upwards
        // from around that chalice ... gold, varying sizes but as small as 1px to around 4-6px on the larger size. The smaller
        // ones crisp, but larger ones closer and a bokeh effect. They will course upward and fade, like magic emanating from
        // the grail itself"). Flakes leave the bowl's rim (GrailX/GrailY, its half-width GrailRimW: shares of the art, which is
        // cover-fit) and rise, spreading a little, swaying, slowing, fading; the stream swells and eases every GrailPulse s.
        // Most are fine and crisp: 1 px squares, a few 2-3 px; each turns as it rises and catches the light (a glint). About
        // one in nine is CLOSER: 4-6 px, out of focus -- a see-through disc with a brighter rim and a soft halo (bokeh), rising
        // faster and drifting wider. Sizes follow the monitor (x H/1440, at least 1). Drawn into their own repaint rectangle
        // (_fxArea) each pass, apart from the menu's; off behind a RAPTOR DOCS reader; dimmed with the art while a log reads.
        public bool GrailFx = true;
        public double GrailX = 0.693, GrailY = 0.503, GrailRimW = 0.056, GrailRise = 0.30, GrailRate = 90, GrailPulse = 3.4, GrailBokeh = 0.11;
        /// <summary>The flakes' pace (Josh, 2026-10-13: "just as smoothly, but a bit slower"): their speed, sway, glints and the
        /// pulse are scaled by it, their lives stretched by 1/it so they still rise as far; as many stay on screen.</summary>
        public double GrailSpeed = 0.63;      // (0.7, then "another 10%" slower -- Josh, 2026-10-13)
        static readonly int[] GrailInks = { 0xFFDC8A, 0xFFC45A, 0xFFF3CC, 0xF0B04A };
        class Flake { public float X, Y, VX, VY, Size, Life, Age, Phase, Tw, SwayF, SwayA; public int Ink, Tone; public bool Bokeh; }
        readonly System.Collections.Generic.List<Flake> _flakes = new System.Collections.Generic.List<Flake>(); readonly Random _fxRnd = new Random(1996);
        Rectangle _fxArea; float _fxCx, _fxCy, _fxRimW, _fxA, _fxK; double _fxT = -1, _fxDebt;
        // ---- THE GRAIL LIGHTS HIS FACE (Josh, 2026-10-13: "a glow effect to illuminate the man's face, as if the grail is an
        // actual light source, with a very subtle glow effect that brightens and becomes transparent, as if gazing into a slowly
        // flickering flame"). Made once with the art: the face's region as the grail would light it -- each pixel screened
        // brighter by the flame's warm colour (x 1 + GlowLift x GlowWarm), under a soft oval mask (FaceX/FaceY its centre, FaceRX/FaceRY
        // its radii: shares of the art) strongest low on the face, where the light comes from. Each pass lays it over the art
        // at a strength that drifts like a flame -- three slow waves (about 0.35, 0.8 and 1.9 Hz) and the flakes' swell --
        // between GlowMin and GlowMax. Inside the flakes' repaint rectangle (grown to hold the face).
        public bool GrailGlow = true;
        public double FaceX = 0.737, FaceY = 0.27, FaceRX = 0.125, FaceRY = 0.215, GlowLift = 1.8, GlowMin = 0.45, GlowMax = 1.0;
        // (Josh, 2026-10-13: first too faint to see -> lift 1.8, 0.45..1.0 ("the strength is good"); then "span his entire face
        // and a portion of the helmet ... make it pulse slower": the oval 0.085 x 0.15 -> 0.125 x 0.215, centred a little
        // higher, a wider flat middle, less fall-off toward the top; the flame at GlowPace x its old speed)
        public double GlowPace = 0.5;
        public int GlowWarm = 0xFFB86B;
        Bitmap _glowImg; Rectangle _glowArea; readonly System.Drawing.Imaging.ImageAttributes _glowAttr = new System.Drawing.Imaging.ImageAttributes();
        readonly System.Drawing.Imaging.ColorMatrix _glowCm = new System.Drawing.Imaging.ColorMatrix();
        void PrepareGlow()
        {
            if (_glowImg != null) { _glowImg.Dispose(); _glowImg = null; }
            _glowArea = Rectangle.Empty;
            if (!GrailGlow || _bg == null) return;
            float cx = _artX + (float)FaceX * _artW, cy = _artY + (float)FaceY * _artH, rx = (float)FaceRX * _artW, ry = (float)FaceRY * _artH;
            var r = Rectangle.Intersect(Rectangle.Round(RectangleF.FromLTRB(cx - rx, cy - ry, cx + rx, cy + ry)), new Rectangle(0, 0, _W, _H));
            if (r.Width < 8 || r.Height < 8) return;
            var img = new Bitmap(r.Width, r.Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            var src = _bg.LockBits(r, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            var dst = img.LockBits(new Rectangle(0, 0, r.Width, r.Height), System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            try
            {
                var row = new int[r.Width]; var orow = new int[r.Width];
                double wr = ((GlowWarm >> 16) & 255) / 255.0, wg = ((GlowWarm >> 8) & 255) / 255.0, wb = (GlowWarm & 255) / 255.0;
                for (int y = 0; y < r.Height; y++)
                {
                    Marshal.Copy(src.Scan0 + y * src.Stride, row, 0, r.Width);
                    double dy = (r.Top + y + 0.5 - cy) / ry, low = Math.Max(0, Math.Min(1, 0.5 + 0.5 * dy));     // (0 at the top .. 1 at the bottom)
                    for (int x = 0; x < r.Width; x++)
                    {
                        double dx = (r.Left + x + 0.5 - cx) / rx, d = Math.Sqrt(dx * dx + dy * dy);
                        double fall = d >= 1 ? 0 : d <= 0.45 ? 1 : 1 - (d - 0.45) / 0.55; fall = fall * fall * (3 - 2 * fall);
                        double m = fall * (0.7 + 0.3 * low);
                        if (m <= 0.002) { orow[x] = 0; continue; }
                        int c = row[x]; double cr = ((c >> 16) & 255) / 255.0, cg = ((c >> 8) & 255) / 255.0, cb = (c & 255) / 255.0;
                        double lr = cr * (1 + GlowLift * wr) + 0.02 * wr, lg = cg * (1 + GlowLift * wg) + 0.02 * wg, lb = cb * (1 + GlowLift * wb) + 0.02 * wb;   // (lit: what the light falls on brightens, the shadows stay -- a screen made it haze)
                        int a = (int)Math.Round(255 * m);
                        orow[x] = (a << 24) | ((int)Math.Round(255 * Math.Min(1, lr) * m) << 16) | ((int)Math.Round(255 * Math.Min(1, lg) * m) << 8) | (int)Math.Round(255 * Math.Min(1, lb) * m);
                    }
                    Marshal.Copy(orow, 0, dst.Scan0 + y * dst.Stride, r.Width);
                }
            }
            finally { _bg.UnlockBits(src); img.UnlockBits(dst); }
            _glowImg = img; _glowArea = r;
        }
        /// <summary>The flame's strength at t s (GlowMin..GlowMax): three slow waves and the flakes' swell.</summary>
        double GlowAt(double t)
        {
            double q = t * GlowPace;
            double n = 0.5 + 0.5 * (0.5 * Math.Sin(2.2 * q) + 0.3 * Math.Sin(5.0 * q + 1.3) + 0.12 * Math.Sin(11.9 * q + 0.4) + 0.08 * (2 * FxPulse(t) - 1));
            return GlowMin + (GlowMax - GlowMin) * Math.Max(0, Math.Min(1, n));
        }
        void DrawGlow(Graphics g, double t, double k)
        {
            if (_glowImg == null || k <= 0.01) return;
            _glowCm.Matrix33 = (float)(GlowAt(t) * k); _glowAttr.SetColorMatrix(_glowCm);
            g.DrawImage(_glowImg, _glowArea, 0, 0, _glowArea.Width, _glowArea.Height, GraphicsUnit.Pixel, _glowAttr);
        }
        // ---- DUST IN THE FOREGROUND (Josh, 2026-10-13: "On the lower left, I want some very large dust, very much in the
        // foreground and huge bokeh effects, moving upward in the same pattern as the grail effects, but much slower and much
        // more transparent (though still varied in size and opacity)"). A few dozen out-of-focus motes close to the lens in the
        // lower left (ForeArea: x0, y0, x1, y1 shares of the WINDOW): soft discs with a faint brighter rim and a halo, ForeMin..
        // ForeMax px across (x H/1440), each its own faintness (ForeAlpha at most), rising and swaying like the grail's flakes at
        // a fraction of their pace, fading in and out over lives of 9-18 s and near the area's open edges. Drawn under the menu,
        // in their own repaint rectangle; with the flakes (GrailFx).
        // ROUND 2 (Josh, 2026-10-13: "a bit more visible and warmer, but keep some of the current level of transparent examples
        // also, increase the density ... remove the outline effect so they are blurred circle shapes only ... increase the span
        // ... across the lower left (fading out around the half way point), and vertically upward, fading around the title
        // area"): warmer inks; a third stay as faint as before, the rest up to ForeAlpha; ForeCount 60; each a BLURRED disc --
        // a soft sprite (flat middle, smooth fall-off, no rim) per ink, drawn bilinear at its size and faintness; the area
        // runs to half the window's width and up to the title, fading over its last ForeFadeX / ForeFadeY. The area is ~1.6 Mpx,
        // so it is repainted at ForeFps (the motes move a pixel or less between); the motes are drawn every pass, so the menu's
        // own repaints, which overlap them, never lose them.
        public bool ForeDust = true;
        // ROUND 3 (Josh, 2026-10-13: "reduce the foreground dust spanning area by 20% in both directions, the frame rate is
        // taking a big hit so perhaps a bit less of them as well"): the area 0.52 x 0.80 -> 0.416 x 0.64 of the window (and its
        // fades with it), 60 -> 34 motes. THE HIT WAS THE DRAW, not the area: each sprite went through an ImageAttributes
        // colour matrix (GDI+'s slow path) -- 22 ms a pass offline for 60, and still 8 ms for 34 drawn plain (any scaled
        // GDI+ draw is slow). The motes are now composited by hand into a layer when a dust frame is due (RenderFore).
        public double ForeX0 = 0.0, ForeY0 = 0.36, ForeX1 = 0.416, ForeY1 = 1.0, ForeFadeX = 0.144, ForeFadeY = 0.16, ForeMin = 14, ForeMax = 130, ForeAlpha = 0.46, ForeCount = 34, ForeFps = 40;
        static readonly int[] ForeInks = { 0xFFB24A, 0xF89A30, 0xFFC872, 0xEE8A2C };
        // THE LAYER: the art under the area (copied once) with the motes laid on it HERE, a smooth fall-off per pixel (full to
        // 45% of the radius, smoothstep to nothing at the edge, from a table), whenever a dust frame is due; every pass then
        // copies the finished layer, unscaled, wherever it repaints the area (GDI+'s scaled sprite draws cost 8-22 ms a pass).
        int[] _fgBg, _fgPix; Bitmap _fgLayer; readonly float[] _fgLut = new float[1025]; double _fgDrawnAt = -9;
        readonly System.Collections.Generic.List<Flake> _fore = new System.Collections.Generic.List<Flake>();
        Rectangle _fgArea; double _fgT = -1, _fgDebt;
        void PrepareFore()
        {
            _fore.Clear(); _fgT = -1; _fgDebt = 0; _fgDrawnAt = -9;
            if (_fgLayer != null) { _fgLayer.Dispose(); _fgLayer = null; }
            _fgArea = GrailFx && ForeDust ? Rectangle.Intersect(Rectangle.Round(RectangleF.FromLTRB((float)ForeX0 * _W, (float)ForeY0 * _H, (float)ForeX1 * _W, (float)ForeY1 * _H)), new Rectangle(0, 0, _W, _H)) : Rectangle.Empty;
            if (_fgArea.Width < 8 || _fgArea.Height < 8 || _bg == null) { _fgArea = Rectangle.Empty; return; }
            for (int i = 0; i <= 1024; i++) { double d = Math.Sqrt(i / 1024.0), v = d >= 1 ? 0 : d <= 0.45 ? 1 : 1 - (d - 0.45) / 0.55; _fgLut[i] = (float)(v * v * (3 - 2 * v)); }
            int w = _fgArea.Width, h = _fgArea.Height; _fgBg = new int[w * h]; _fgPix = new int[w * h];
            var bd = _bg.LockBits(_fgArea, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            try { for (int y = 0; y < h; y++) Marshal.Copy(bd.Scan0 + y * bd.Stride, _fgBg, y * w, w); } finally { _bg.UnlockBits(bd); }
            _fgLayer = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            // already drifting when the title appears: a life's worth of them, part-way through
            for (int i = 0; i < (int)ForeCount; i++) _fore.Add(NewFore(true));
            RenderFore();
        }        Flake NewFore(bool anyAge)
        {
            var p = new Flake(); p.Bokeh = true; float k = Math.Max(1f, _H / 1440f), A = _H;
            float u = R01(); p.Size = (float)(ForeMin + (ForeMax - ForeMin) * Math.Pow(u, 1.8)) * k;     // (most mid-sized, a few huge)
            p.X = _fgArea.Left + (float)Math.Pow(R01(), 1.3) * _fgArea.Width * 1.05f - 0.05f * _fgArea.Width;   // (thicker toward the corner)
            p.Y = _fgArea.Top + _fgArea.Height * (1.08f - 0.85f * (float)Math.Pow(R01(), 1.4));         // (anywhere in the area, more low: at their pace they rise only ~a third of it in a life)
            float near = (float)((p.Size / k - ForeMin) / Math.Max(1, ForeMax - ForeMin));          // (bigger = nearer = a little quicker)
            p.VY = -(0.010f + 0.012f * R01() + 0.010f * near) * A * (float)Math.Max(0.1, GrailSpeed);
            p.VX = (0.002f + 0.006f * R01()) * A;                                                         // (a slow drift right, out of the corner)
            p.Life = 9f + 9f * R01(); p.Phase = R01() * 6.283f; p.Tw = 0.25f + 0.5f * R01();
            p.SwayF = (0.25f + 0.35f * R01()); p.SwayA = (0.006f + 0.012f * R01()) * A;
            p.Ink = (int)(ForeAlpha * 1000 * (R01() < 0.35 ? 0.25 + 0.25 * R01() : 0.55 + 0.45 * R01()));   // (its own faintness, per mille: a third as faint as round 1)
            p.Tone = _fxRnd.Next(ForeInks.Length);
            if (anyAge) { p.Age = R01() * p.Life * 0.8f; p.Y += p.VY * p.Age; p.X += p.VX * p.Age; }
            return p;
        }
        void StepFore(double t)
        {
            double dt = _fgT < 0 ? 0 : Math.Min(0.1, t - _fgT); _fgT = t;
            double avgLife = 13.5;
            _fgDebt += dt * ForeCount / avgLife;
            while (_fgDebt >= 1 && _fore.Count < ForeCount * 2) { _fgDebt -= 1; _fore.Add(NewFore(false)); }
            for (int i = _fore.Count - 1; i >= 0; i--)
            {
                var p = _fore[i]; p.Age += (float)dt;
                if (p.Age >= p.Life || p.Y + p.Size < _fgArea.Top) { _fore.RemoveAt(i); continue; }
                p.X += (p.VX + (float)Math.Cos(p.Age * p.SwayF + p.Phase) * p.SwayA * p.SwayF) * (float)dt;
                p.Y += p.VY * (float)dt;
            }
        }
        void RenderFore()
        {
            if (_fgLayer == null) return;
            int w = _fgArea.Width, h = _fgArea.Height; Array.Copy(_fgBg, _fgPix, _fgPix.Length);
            foreach (var p in _fore)
            {
                double life = Math.Min(1, p.Age / 2.5) * Math.Min(1, (p.Life - p.Age) / (0.4 * p.Life));
                // fading out toward the area's open edges: the last ForeFadeY of it upward (the title), ForeFadeX rightward
                double fy = (p.Y - _fgArea.Top) / Math.Max(1.0, ForeFadeY * _H), fx = (_fgArea.Right - p.X) / Math.Max(1.0, ForeFadeX * _W);
                double edge = Math.Max(0, Math.Min(1, fy)) * Math.Max(0, Math.Min(1, fx)); edge = edge * edge * (3 - 2 * edge);
                double a = life * edge * (p.Ink / 1000.0) * (0.85 + 0.15 * Math.Sin(p.Age * p.Tw + p.Phase));
                if (a <= 0.003) continue;
                // a blurred disc, no outline: 1.25 x its size across (as large as round 1's halo)
                double R = p.Size * 1.25 / 2, cx = p.X - _fgArea.Left, cy = p.Y - _fgArea.Top, inv = 1024.0 / (R * R);
                int x0 = Math.Max(0, (int)Math.Floor(cx - R)), x1 = Math.Min(w - 1, (int)Math.Ceiling(cx + R)), y0 = Math.Max(0, (int)Math.Floor(cy - R)), y1 = Math.Min(h - 1, (int)Math.Ceiling(cy + R));
                int ink = ForeInks[p.Tone], ir = (ink >> 16) & 255, ig = (ink >> 8) & 255, ib = ink & 255; float af = (float)a;
                for (int y = y0; y <= y1; y++)
                {
                    double dy = y + 0.5 - cy, dy2 = dy * dy; int row = y * w;
                    for (int x = x0; x <= x1; x++)
                    {
                        double dx = x + 0.5 - cx; int q = (int)((dx * dx + dy2) * inv); if (q >= 1024) continue;
                        int si = (int)(_fgLut[q] * af * 256 + 0.5); if (si <= 0) continue;
                        int c = _fgPix[row + x], r = (c >> 16) & 255, gg = (c >> 8) & 255, bb = c & 255;
                        r += ((ir - r) * si) >> 8; gg += ((ig - gg) * si) >> 8; bb += ((ib - bb) * si) >> 8;
                        _fgPix[row + x] = unchecked((int)0xFF000000) | (r << 16) | (gg << 8) | bb;
                    }
                }
            }
            var bd = _fgLayer.LockBits(new Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            try { for (int y = 0; y < h; y++) Marshal.Copy(_fgPix, y * w, bd.Scan0 + y * bd.Stride, w); } finally { _fgLayer.UnlockBits(bd); }
        }
        void DrawForeLayer(Graphics g)
        {
            if (_fgLayer != null) g.DrawImage(_fgLayer, _fgArea, 0, 0, _fgArea.Width, _fgArea.Height, GraphicsUnit.Pixel);
        }        void PrepareFx()
        {
            _fxCx = _artX + (float)GrailX * _artW; _fxCy = _artY + (float)GrailY * _artH; _fxRimW = (float)GrailRimW * _artW; _fxA = _artH;
            _fxK = Math.Max(1f, _H / 1440f);
            var r = RectangleF.FromLTRB(_fxCx - 0.135f * _artW, _fxCy - ((float)GrailRise + 0.05f) * _artH, _fxCx + 0.135f * _artW, _fxCy + 0.05f * _artH);
            _fxArea = GrailFx ? Rectangle.Intersect(Rectangle.Round(r), new Rectangle(0, 0, _W, _H)) : Rectangle.Empty;
            PrepareGlow();
            if (!_glowArea.IsEmpty) _fxArea = _fxArea.IsEmpty ? _glowArea : Rectangle.Union(_fxArea, _glowArea);     // (one rectangle: they overlap)
            PrepareFore();
            _flakes.Clear(); _fxT = -1; _fxDebt = 0;
        }
        double FxPulse(double t) { return 0.5 + 0.5 * Math.Sin(2 * Math.PI * t * GrailSpeed / Math.Max(0.5, GrailPulse)); }
        float R01() { return (float)_fxRnd.NextDouble(); }
        void StepFx(double t)
        {
            double dt = _fxT < 0 ? 0 : Math.Min(0.1, t - _fxT); _fxT = t;
            double pulse = FxPulse(t);
            // new flakes: the stream swells with the pulse
            _fxDebt += dt * GrailRate * GrailSpeed * (0.7 + 0.6 * pulse);          // (slower = longer lives: fewer a second keep the count)
            while (_fxDebt >= 1 && _flakes.Count < 600)
            {
                _fxDebt -= 1;
                var p = new Flake(); bool bk = R01() < GrailBokeh; p.Bokeh = bk;
                float u = R01() * 2 - 1; u = Math.Sign(u) * (float)Math.Pow(Math.Abs(u), bk ? 0.8 : 1.3);      // (most from the middle of the rim)
                p.X = _fxCx + u * _fxRimW * (bk ? 1.5f : 1f);
                p.Y = _fxCy + (R01() - 0.65f) * 0.022f * _fxA - (bk ? R01() * 0.05f * _fxA : 0);
                float up = (bk ? 0.075f + 0.07f * R01() : 0.04f + 0.075f * R01()) * _fxA * (float)(1 + 0.3 * pulse);
                p.VY = -up; p.VX = u * 0.022f * _fxA * (bk ? 1.6f : 1f) + (R01() - 0.5f) * 0.012f * _fxA;
                p.Life = bk ? 2.0f + 1.5f * R01() : 2.4f + 2.2f * R01();
                float sp = (float)Math.Max(0.1, GrailSpeed); p.VY *= sp; p.VX *= sp; p.Life /= sp;
                p.Size = bk ? (4f + 2.5f * R01()) * _fxK : (float)(1 + 2.2 * Math.Pow(R01(), 2.6)) * _fxK;
                p.Phase = R01() * 6.283f; p.Tw = (2.5f + 6f * R01()) * sp; p.SwayF = (0.8f + 1.6f * R01()) * sp; p.SwayA = (0.004f + 0.01f * R01()) * _fxA;
                p.Ink = _fxRnd.Next(GrailInks.Length);
                _flakes.Add(p);
            }
            if (_fxDebt > 4) _fxDebt = 0;
            for (int i = _flakes.Count - 1; i >= 0; i--)
            {
                var p = _flakes[i]; p.Age += (float)dt;
                if (p.Age >= p.Life) { _flakes.RemoveAt(i); continue; }
                float slow = (float)Math.Exp(-0.18 * GrailSpeed * dt);
                p.VY *= slow; p.VX *= slow;
                p.X += (p.VX + (float)Math.Cos(p.Age * p.SwayF + p.Phase) * p.SwayA * p.SwayF) * (float)dt;
                p.Y += p.VY * (float)dt;
            }
        }
        void DrawFx(Graphics g, double k)
        {
            if (k <= 0.01 || _flakes.Count == 0) return;
            var sm = g.SmoothingMode;
            foreach (var p in _flakes)
            {
                if (!_fxArea.Contains((int)p.X, (int)p.Y)) continue;
                double life = Math.Min(1, p.Age / 0.35) * Math.Min(1, (p.Life - p.Age) / (0.45 * p.Life));
                double edge = Math.Min(Math.Min(p.Y - _fxArea.Top, Math.Min(p.X - _fxArea.Left, _fxArea.Right - p.X)) / (0.06 * _fxA), 1.0);   // (gone before their rectangle's edge)
                life *= Math.Max(0, edge);
                double glint = Math.Pow(Math.Abs(Math.Sin(p.Age * p.Tw + p.Phase)), 3);           // (turning, catching the light)
                int ink = GrailInks[p.Ink];
                if (p.Bokeh)
                {
                    // close and out of focus: a soft halo, a see-through disc, a brighter rim
                    double a = k * life * (0.75 + 0.25 * glint);
                    float d = p.Size, h = d * 1.9f;
                    g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    using (var hb = new SolidBrush(C(ink, 0.10 * a))) g.FillEllipse(hb, p.X - h / 2, p.Y - h / 2, h, h);
                    using (var fb = new SolidBrush(C(ink, 0.30 * a))) g.FillEllipse(fb, p.X - d / 2, p.Y - d / 2, d, d);
                    using (var rp = new Pen(C(0xFFE3A6, 0.45 * a), Math.Max(0.8f, d * 0.16f))) g.DrawEllipse(rp, p.X - d / 2, p.Y - d / 2, d, d);
                }
                else if (p.Size < 1.7f * _fxK)
                {
                    // fine and crisp: a whole pixel (or two), no smoothing
                    double a = k * life * (0.6 + 0.4 * glint);
                    int px = (int)Math.Round(p.Size), x = (int)Math.Round(p.X), y = (int)Math.Round(p.Y);
                    g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
                    using (var b = new SolidBrush(C(glint > 0.8 ? 0xFFF0C2 : ink, a))) g.FillRectangle(b, x, y, Math.Max(1, px), Math.Max(1, px));
                }
                else
                {
                    // a little larger: a smoothed flake with a bright core when it glints
                    double a = k * life * (0.65 + 0.35 * glint);
                    float d = p.Size;
                    g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    using (var b = new SolidBrush(C(ink, a))) g.FillEllipse(b, p.X - d / 2, p.Y - d / 2, d, d);
                    if (glint > 0.6) using (var c = new SolidBrush(C(0xFFF6DA, a * (glint - 0.6) / 0.4))) g.FillRectangle(c, (int)Math.Round(p.X), (int)Math.Round(p.Y), 1, 1);
                }
            }
            g.SmoothingMode = sm;
        }

        /// <summary>OFFLINE: the title as it would be drawn at w x h, t seconds in, with row `sel` selected (loadOpen: the slot
        /// list up, `lsel` selected).</summary>
        /// <summary>OFFLINE: a load's reading, `rt` seconds into it (doneFor >= 0: finished that long ago).</summary>
        public Bitmap PreviewRead(int w, int h, int slot, double rt, double doneFor)
        {
            ReadSaves(); _W = w; _H = h; _s = h / 1080f; Prepare();
            double t = 10; _pickAt = t - rt - 0.3; _readAt = t - rt; _readSlot = slot; _readName = slot >= 0 && slot < Slots.Length ? Slots[slot].Name.Trim().ToUpperInvariant() : ""; _readDoneAt = doneFor >= 0 ? t - doneFor : -1; _readP = 0;
            using (var g = Graphics.FromImage(_buf))
            {
                g.DrawImage(_bg, new Rectangle(0, 0, _W, _H), new Rectangle(0, 0, _W, _H), GraphicsUnit.Pixel);
                using (var db = new SolidBrush(C(0x000000, ReadDim * Ease((t - _pickAt) / 0.8)))) g.FillRectangle(db, 0, 0, _W, _H);
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                DrawRead(g, t);
            }
            var o = (Bitmap)_buf.Clone(); _bg.Dispose(); _buf.Dispose(); _bg = null; _buf = null; return o;
        }
        /// <summary>OFFLINE: Preview also draws the pointer over the selected row (hovering it: the hot variant).</summary>
        public bool PreviewPointer, PreviewHover;
        /// <summary>OFFLINE: Preview with the options panel up instead (PreviewOsel selected; PreviewSoon: just picked TEXTURE QUALITY).</summary>
        public bool PreviewOptions, PreviewSoon; public int PreviewOsel;
        public Bitmap Preview(int w, int h, double t, int sel, bool loadOpen, int lsel)
        {
            ReadSaves(); _W = w; _H = h; _s = h / 1080f; Prepare();
            _sel = Enabled(sel) ? sel : R_NEW; _selAt = t - 1; _loadOpen = loadOpen; _loadAt = loadOpen ? t - 1 : -9; _lsel = lsel;
            _optOpen = PreviewOptions; _optAt = PreviewOptions ? t - 1 : -9; _osel = PreviewOsel; _optSoonAt = PreviewSoon ? t - 0.3 : -9;
            PreviewDocsState(t);
            using (var g = Graphics.FromImage(_buf))
            {
                g.DrawImage(_bg, new Rectangle(0, 0, _bg.Width, _bg.Height), 0, 0, _bg.Width, _bg.Height, GraphicsUnit.Pixel); g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                if (GrailGlow) DrawGlow(g, t, 1);
                if (GrailFx && _fxArea.Width > 0) { for (double ft = 0; ft <= t; ft += 1 / 60.0) StepFx(ft); DrawFx(g, 1); }
                if (_fgArea.Width > 0) { for (double ft = 0; ft <= t; ft += 1 / 60.0) StepFore(ft); RenderFore(); DrawForeLayer(g); }
                DrawMenu(g, t); if (loadOpen) DrawLoad(g, t); if (_optOpen) DrawOptions(g, t);
                PreviewDocsDraw(g, t);
                if (PreviewPointer) { var rr = _optOpen ? _optRect[_osel] : loadOpen ? _slotRect[_lsel] : _rowRect[_sel]; _hover = PreviewHover ? 0 : -1; DrawPointer(g, rr.Left + rr.Width * 0.62f, rr.Top + rr.Height * 0.55f); _hover = -1; }
            }
            var o = (Bitmap)_buf.Clone(); _bg.Dispose(); _buf.Dispose(); _bg = null; _buf = null; return o;
        }
    }

    public class GameGate : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        struct MBI { public IntPtr BaseAddress, AllocationBase; public uint AllocationProtect; public IntPtr RegionSize; public uint State, Protect, Type; }
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr addr, out MBI mbi, IntPtr len);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
        [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);

        // HOW THE GAME IS HELD (2026-10-07). It used to be NtSuspendProcess on DOSBox -- every thread, ~8 s -- and that
        // KILLED THE SOUND BLASTER for the rest of the session: the game kept asking for its sounds (shot.wav at volume
        // 100/127, nothing paused or muted, measured) and voices, gunfire and effects stayed silent. Every session with a
        // hold had it; none without did. Now the GAME holds itself and DOSBox runs on: its frame limiter AztFrameLimit
        // spins until aztFramePeriod microseconds have passed and re-reads the period every pass, so a huge period parks
        // its frame loop right there -- timers, IRQs and the Sound Blaster all running -- and putting the period back
        // lets it go on the next pass. The boot's clock is wall time (el = now - T0), so if the boot had begun, T0 is
        // moved on by the time held, or the boot would jump ahead by it.
        /// <summary>obj1 linear of aztFramePeriod (the manifest's setting) -- 0: the game cannot be held, and is not.</summary>
        public int FramePeriodLin;
        uint _periodWas; long _aPeriod, _aState;
        bool W32(long hostAddr, uint v) { IntPtr n; return WriteProcessMemory(_proc, new IntPtr(hostAddr), BitConverter.GetBytes(v), new IntPtr(4), out n) && n.ToInt64() == 4; }
        bool HoldGame()
        {
            if (FramePeriodLin == 0 || _aPeriod == 0) return false;
            _periodWas = U32(_aPeriod); if (_periodWas == 0 || _periodWas > 10000000) _periodWas = 41667;    // (a sane cap to come back to)
            return W32(_aPeriod, 0x7FFFFFFF);
        }
        // THE BOOT'S CLOCK IS HELD TOO, NOT CORRECTED AFTERWARDS (2026-10-07). The park above does not always hold: there
        // are game states that skip the frame limiter (AztActorTime exists for them), and then the boot ran on behind the
        // loading screen -- and the release, adding the whole hold to T0 as if it had been parked, pushed `el` below zero:
        // unsigned, huge, past the boot's hard cap, so it ended on its first frame ("will not play the full bootup
        // sequence if I skip the movies too fast"). Now, all through the hold, T0 is kept at guest-now minus the elapsed
        // time the boot had when it was caught: whether its frames run or not, it cannot get further, and when it is let go
        // it carries on from exactly there.
        long _aTick, _aPer15, _aAcc15; uint _elHeld; bool _elSet;
        /// <summary>The guest's own clock (AztNow: BIOS tick x slot-15 period + slot-15 accumulator, microseconds, 32-bit).</summary>
        uint GuestNow()
        {
            for (int tries = 0; tries < 4; tries++)
            {
                uint tk = U32(_aTick), per = U32(_aPer15), acc = U32(_aAcc15), tk2 = U32(_aTick);
                if (tk == tk2 || tries == 3) return unchecked((uint)((ulong)tk * per) + acc);     // (a tick between the reads: again)
            }
            return 0;
        }
        void FreezeBoot()
        {
            if (_aState == 0 || _aTick == 0) return;
            uint st = U32(_aState);
            if (st != 1) return;                                  // not begun (0) -- or already over (2), too late to help
            if (!_elSet) { _elHeld = U32(_aState + 16); if (_elHeld > 60000000) _elHeld = 0; _elSet = true; }
            W32(_aState + 12, unchecked(GuestNow() - _elHeld));
        }
        void ReleaseGame(double heldMs)
        {
            if (_aPeriod == 0) return;
            FreezeBoot();                                         // (one last time, then let it run from there)
            W32(_aPeriod, _periodWas);
        }

        public readonly LoadingScreen Screen = new LoadingScreen();
        public int Pid; public long MemBase;
        /// <summary>Longest the game may be held, whatever happens: it is never left frozen.</summary>
        public int MaxHoldMs = 20000;
        public bool WasHeld; public double HeldMs;
        int _symBuf, _symState; byte[] _exe; IntPtr _proc;
        Thread _th; volatile bool _run; readonly object _lk = new object();
        bool _ready, _held; Stopwatch _holdClock = new Stopwatch(), _life = Stopwatch.StartNew();
        readonly System.Collections.Generic.Queue<string> _notes = new System.Collections.Generic.Queue<string>();
        void Note(string s) { lock (_notes) { if (_notes.Count < 32) _notes.Enqueue(string.Format("[gate {0:N1}s] {1}", _life.Elapsed.TotalSeconds, s)); } }
        public string TakeNote() { lock (_notes) { return _notes.Count > 0 ? _notes.Dequeue() : null; } }
        public bool Holding { get { lock (_lk) return _held; } }

        /// <summary>symBufPtr / symBootState: the overlay symbols aztInjBufPtr and aztBootState (obj1).</summary>
        public void Start(int pid, string exePath, int symBufPtr, int symBootState)
        {
            Screen.Log = s => Note("loading screen: " + s);      // (its real size on screen, each time it changes -- the watcher's log)
            Pid = pid; _symBuf = symBufPtr; _symState = symBootState;
            using (var fs = new System.IO.FileStream(exePath, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete))
            { _exe = new byte[fs.Length]; int o = 0; while (o < _exe.Length) { int n = fs.Read(_exe, o, _exe.Length - o); if (n <= 0) break; o += n; } }
            _proc = OpenProcess(0x0438, false, pid);         // query + read + write (the hold writes the frame period)
            if (_proc == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
            // If the renderer dies or is closed while the game is held, this thread dies with it -- so the
            // release is also hooked to the process going away, or the game would stay frozen for good.
            AppDomain.CurrentDomain.ProcessExit += (s, e) => { try { Ready(true); } catch { } };
            // the window is made now, hidden, so that holding the game puts black over its frozen frame at once
            if (!Screen.Prepare()) Note("loading screen could not be prepared: " + Screen.StartError);
            _run = true; _th = new Thread(Loop); _th.IsBackground = true; _th.Name = "AztGameGate"; _th.Start();
        }
        public void Stage(double to, double expectSeconds) { Screen.Stage(to, expectSeconds); }

        /// <summary>The renderer has hold of the game: release it if it is being held, and stop watching.</summary>
        // THE LOADING SCREEN'S SOUND (Josh, 2026-10-07): "Loading ... Raptor Mod." layered over his raptormod_loading track.
        // "If the loading is complete before the soundtrack is complete, load into game. But we must always finish the
        // loading raptor mod voice track." So once the renderer is ready the game is let go -- but not before the voice
        // has finished; the track then fades out under the game coming in.
        /// <summary>The two sounds (WAV, 16-bit PCM) and their levels; Sound false = a silent loading screen.</summary>
        // (2026-10-07, Josh: "the voice feels a little loud ... a bit softer, almost as if in the distance": half the level,
        // the top end rolled off above VoiceLowHz -- distance takes the highs first)
        public string VoicePath, TrackPath; public double VoiceGain = 0.5, VoiceLowHz = 2800, TrackGain = 0.3, TrackFadeSeconds = 1.2; public bool Sound = true;
        LoadingAudio _audio; volatile bool _releaseReq;
        /// <summary>Show the loading screen at the start of play on EVERY launch, even when the renderer is already ready --
        /// held until the voice has said "Loading ... Raptor Mod" (Josh, 2026-10-07: "I do want to see it every time so at the
        /// minimum we hear it"). False = only when the renderer is not ready yet (the old way).</summary>
        public bool AlwaysShow = true;
        bool _shownOnce;
        /// <summary>The renderer has hold of the game: release it (once the loading voice has finished), and stop watching.</summary>
        public void Ready() { Ready(false); }
        /// <summary>force: let the game go NOW, voice or not (the renderer is going away).</summary>
        public void Ready(bool force)
        {
            bool held;
            lock (_lk) { _ready = true; held = _held; if (held && !force) { _releaseReq = true; return; } _held = false; if (!held && !force && AlwaysShow && !_shownOnce) _releaseReq = true; }
            if (held) ReleaseNow("renderer gone: game released at once", true);
            else if (!Screen.Visible && (force || !AlwaysShow || _shownOnce)) Screen.Dispose();     // never needed: drop the hidden window
        }
        // (on the gate's own thread, normally -- or the caller's when forced)
        void ReleaseNow(string why, bool hard)
        {
            HeldMs = _holdClock.Elapsed.TotalMilliseconds;
            bool ok = true; try { ReleaseGame(HeldMs); } catch { ok = false; }
            Note(string.Format("{0} after {1:N0} ms held{2}", why, HeldMs, ok ? "" : " -- RELEASE FAILED"));
            var a = _audio; if (a != null) { if (hard) a.Dispose(); else a.FadeTrack(TrackFadeSeconds); }
            Screen.Finish();
        }

        // The same rule as GuestBase.ps1's Get-AztGuestBase: strings from R.EXE found ONCE in the big
        // RAM block, from BOTH of its objects, all agreeing on one base.
        static readonly string[] Needles = { "To prevent danger of overload it is recommended", "VESA VBE SuperVGA BIOS implemenation",
                                             "Audio Interface Library application usage script", "Run-Time system. (c) Copyright by WATCOM" };
        // OBJ2'S DELTA IS NOT FIXED (2026-10-11). DOS/4GW places obj2 one page past obj1's END, and AztMod grew obj1 for a
        // bigger overlay window -- so obj2 runs at vsize + 0xC1000 past its linked address (0x1F1000 with the old 52 KB
        // window, 0x224000 with the 256 KB one). The needles are kept as addresses BEFORE their object's delta, obj1's are
        // tried first (their delta never moves), and obj2's are checked under each candidate: the one this R.EXE's header
        // implies, then the old one. D2 is the one that matched; every obj2 address below uses it.
        /// <summary>obj2's runtime delta, as the needles found it (0x1F1000 until then).</summary>
        public long D2 = 0x1F1000;
        const long D1 = 0x1F0000;
        System.Collections.Generic.List<byte[]> _sigs; System.Collections.Generic.List<long> _lins; System.Collections.Generic.List<int> _objs; long[] _d2s;
        long Rt(int k, long d2) { return _lins[k] + (_objs[k] == 1 ? D1 : d2); }
        void Needled()
        {
            if (_sigs != null) return;
            var enc = System.Text.Encoding.GetEncoding(28591); string text = enc.GetString(_exe);
            var sigs = new System.Collections.Generic.List<byte[]>(); var lins = new System.Collections.Generic.List<long>(); var objs = new System.Collections.Generic.List<int>();
            foreach (int want in new[] { 1, 2 })                 // (obj1's first: the anchor's address must not depend on obj2's delta)
                foreach (var n in Needles)
                {
                    int fo = text.IndexOf(n, StringComparison.Ordinal); if (fo < 0) continue;
                    long lin; int ob;
                    if (fo >= 0x184A54) { lin = 0x140000 + (fo - 0x184A54); ob = 2; }
                    else if (fo >= 0x61A54) { lin = 0x10000 + (fo - 0x61A54); ob = 1; }
                    else continue;
                    if (ob != want) continue;
                    sigs.Add(System.Text.Encoding.ASCII.GetBytes(n)); lins.Add(lin); objs.Add(ob);
                }
            // the candidates: one page past obj1's end as this R.EXE declares it (obj1 at 0x200000, linked 0x10000; obj2 linked
            // 0x140000), then the old layout's
            var d2s = new System.Collections.Generic.List<long>();
            const int VSIZE_OFF = 0x290FC + 0xC4;
            if (_exe.Length > VSIZE_OFF + 4) { long vs = BitConverter.ToUInt32(_exe, VSIZE_OFF); long pages = (vs + 0xFFF) & ~0xFFFL; d2s.Add(D1 + 0x10000 + pages + 0x1000 - 0x140000); }
            if (!d2s.Contains(0x1F1000)) d2s.Add(0x1F1000);
            _d2s = d2s.ToArray(); _sigs = sigs; _lins = lins; _objs = objs;
        }
        bool Matches(long addr, byte[] sig)
        {
            var b = new byte[sig.Length]; IntPtr got;
            if (!ReadProcessMemory(_proc, new IntPtr(addr), b, new IntPtr(b.Length), out got) || got.ToInt64() != b.Length) return false;
            for (int i = 0; i < b.Length; i++) if (b[i] != sig[i]) return false;
            return true;
        }
        /// <summary>Is `cand` the guest's RAM base: EVERY needle at its exact loaded address, from both objects (obj2's under
        /// one of the candidate deltas -- which, if so, becomes D2)?</summary>
        bool Verify(long cand)
        {
            foreach (long d2 in _d2s)
            {
                bool o1 = false, o2 = false, all = true;
                for (int k = 0; k < _sigs.Count && all; k++)
                {
                    if (!Matches(cand + Rt(k, d2), _sigs[k])) all = false;
                    else if (_objs[k] == 1) o1 = true; else o2 = true;
                }
                if (all && o1 && o2) { D2 = d2; return true; }
            }
            return false;
        }
        // THE FAST WAY (Josh, 2026-10-07: "I still see the CPU version sometimes"). The full scan below compared four
        // needles byte by byte across every big region -- over a gigabyte with DOSBox Staging's graphics mappings --
        // and took SECONDS a pass: the log showed the game found 12 s after launch, after a player who skipped the
        // movies was already into the boot. Here ONE needle is looked for with the runtime's native byte search,
        // and each hit is checked by reading the other needles at their exact loaded offsets: the relative layout
        // of the loaded image across BOTH objects is what makes a hit the game and not a stale copy of the file
        // (in the file the two objects sit at different distances). Regions are tried near their starts first.
        long FastBase(long minRegion, bool whole)
        {
            Needled(); if (_sigs.Count < 2 || _objs[0] != 1) return 0;
            byte[] anchor = _sigs[0]; long rtA = Rt(0, 0); byte a0 = anchor[0];     // (an obj1 needle: its address has no obj2 delta in it)
            long addr = 0; int mbiLen = Marshal.SizeOf(typeof(MBI)); var buf = new byte[whole ? (4 << 20) : (512 << 10)];
            while (addr < 0x7FFFFFFFFFFF)
            {
                MBI m; if (VirtualQueryEx(_proc, new IntPtr(addr), out m, new IntPtr(mbiLen)) == IntPtr.Zero) break;
                long size = m.RegionSize.ToInt64(), b = m.BaseAddress.ToInt64(); if (size <= 0) break;
                bool readable = m.State == 0x1000 && (m.Protect & 0x100) == 0 && (m.Protect & 0x01) == 0;
                if (readable && size >= minRegion && size <= (4L << 30) && size > rtA + anchor.Length)
                {
                    // the anchor lies rtA past the base, so it can only be in [b + rtA, b + size)
                    long from = b + rtA, end = whole ? b + size : Math.Min(b + size, from + buf.Length);
                    for (long pos = from; pos < end; )
                    {
                        int want = (int)Math.Min(buf.Length, end - pos); IntPtr got;
                        if (!ReadProcessMemory(_proc, new IntPtr(pos), buf, new IntPtr(want), out got) || got.ToInt64() < anchor.Length) { pos += want; continue; }
                        int n = (int)got.ToInt64(), lim = n - anchor.Length;
                        for (int i = Array.IndexOf(buf, a0, 0, lim + 1); i >= 0; i = i < lim ? Array.IndexOf(buf, a0, i + 1, lim - i) : -1)
                        {
                            int j = 1; while (j < anchor.Length && buf[i + j] == anchor[j]) j++;
                            if (j == anchor.Length && Verify(pos + i - rtA)) return pos + i - rtA;
                        }
                        pos += Math.Max(1, n - anchor.Length + 1);
                    }
                }
                addr = b + size;
            }
            return 0;
        }

        long FindBase(long minRegion)
        {
            Needled();
            var sigs = _sigs; var objs = _objs;
            var hits = new int[sigs.Count]; var at = new long[sigs.Count];
            long addr = 0; int mbiLen = Marshal.SizeOf(typeof(MBI)); var buf = new byte[4 << 20];
            while (addr < 0x7FFFFFFFFFFF)
            {
                MBI m; if (VirtualQueryEx(_proc, new IntPtr(addr), out m, new IntPtr(mbiLen)) == IntPtr.Zero) break;
                long size = m.RegionSize.ToInt64(), b = m.BaseAddress.ToInt64(); if (size <= 0) break;
                bool readable = m.State == 0x1000 && (m.Protect & 0x100) == 0 && (m.Protect & 0x01) == 0;
                if (readable && size >= minRegion && size <= (4L << 30))
                {
                    for (long pos = 0; pos < size; )
                    {
                        int want = (int)Math.Min(buf.Length, size - pos); IntPtr got;
                        if (!ReadProcessMemory(_proc, new IntPtr(b + pos), buf, new IntPtr(want), out got) || got.ToInt64() <= 64) { pos += want; continue; }
                        int n = (int)got.ToInt64();
                        // matches STARTING in the last 64 bytes are left to the next (overlapping) chunk,
                        // or one string would be counted twice and fail the found-once test
                        bool last = n < want || pos + n >= size;
                        int lim = last ? n : n - 64;
                        for (int k = 0; k < sigs.Count; k++)
                        {
                            var sg = sigs[k];
                            for (int i = 0; i < lim && i + sg.Length <= n; i++)
                            {
                                if (buf[i] != sg[0]) continue;
                                int j = 1; while (j < sg.Length && buf[i + j] == sg[j]) j++;
                                if (j == sg.Length) { hits[k]++; at[k] = b + pos + i; }
                            }
                        }
                        if (n < want) { pos += want; continue; }
                        pos += n - 64;      // overlap: no needle is longer than 64 bytes
                    }
                }
                addr = b + size;
            }
            foreach (long d2 in _d2s)
            {
                long baseFound = 0; bool o1 = false, o2 = false, agree = true;
                for (int k = 0; k < sigs.Count && agree; k++)
                {
                    if (hits[k] != 1) continue;
                    long bk = at[k] - Rt(k, d2);
                    if (baseFound == 0) baseFound = bk; else if (bk != baseFound) agree = false;
                    if (objs[k] == 1) o1 = true; else o2 = true;
                }
                if (agree && o1 && o2) { D2 = d2; return baseFound; }
            }
            return 0;
        }
        uint U32(long hostAddr)
        {
            var b = new byte[4]; IntPtr got;
            return ReadProcessMemory(_proc, new IntPtr(hostAddr), b, new IntPtr(4), out got) && got.ToInt64() == 4 ? BitConverter.ToUInt32(b, 0) : 0;
        }
        int U16(long hostAddr)
        {
            var b = new byte[2]; IntPtr got;
            return ReadProcessMemory(_proc, new IntPtr(hostAddr), b, new IntPtr(2), out got) && got.ToInt64() == 2 ? BitConverter.ToUInt16(b, 0) : -1;
        }
        bool W16(long hostAddr, int v) { IntPtr n; return WriteProcessMemory(_proc, new IntPtr(hostAddr), BitConverter.GetBytes((ushort)v), new IntPtr(2), out n) && n.ToInt64() == 2; }

        // ---- THE TITLE MENU (Build-AztMod $ENABLE_TITLE_MENU; TitleScreen above) --------------------------------------
        // The game holds its title stage, ORing 0x0100 into the skip flag (0x182DB0) every pass. Seen, the menu goes up and
        // 0x8000 goes into the flag ("the host is here": the game now ignores keys). The choice is acted on here, in the
        // game: a LOAD writes the selected row and OK's mode where the fold-out keeps them (the overlay runs OK on the first
        // frame), then releases the title (0x0200) with the load bit (0x0002: no opening movie) and leaves the bit -- the rest of the intro
        // skipped; a NEW game releases it to 0 -- the story intro plays; QUIT closes DOSBox.
        /// <summary>Hold the title for the menu (false: the game's own title, waiting for a key); the art; the save folder.</summary>
        public bool TitleOn; public string TitleImage, SaveDir;
        /// <summary>RAPTOR DOCS' folder (<game>\raptordocs: the manual and the classified print-outs; RaptorDocs.cs).</summary>
        public string TitleDocs;
        /// <summary>The texture quality in use ("NORMAL" / "ULTRA"), shown on the title's options panel.</summary>
        public string TitleTextureQuality = "ULTRA";
        /// <summary>The grail's gold flakes on the title (TitleScreen.GrailFx; the watcher's -NoGrailDust).</summary>
        public bool TitleGrailFx = true;
        /// <summary>The grail's light on the man's face (TitleScreen.GrailGlow; the watcher's -NoGrailGlow).</summary>
        public bool TitleGrailGlow = true;
        /// <summary>The title's music (Josh, 2026-10-10: "the track kreepy2 to play while this main title is on screen"): a 16-bit
        /// WAV looped from the menu's arrival until a choice fades it; its level.</summary>
        public string TitleMusic; public double TitleMusicGain = 0.55, TitleMusicFadeIn = 2.0, TitleMusicFadeOut = 1.6;
        LoadingAudio _music;
        /// <summary>The slot the title menu loads (-1: none) -- the renderer's visor shows its name as it loads.</summary>
        public volatile int PickedSlot = -1; public volatile string PickedName = "";
        /// <summary>The renderer's view is up after a load from the title: the title's reading finishes and it fades into it.</summary>
        /// <summary>The title's window is still up (a load: it finishes reading the log and fades after TitleLoadShown).</summary>
        public bool TitleShowing { get { var ts = _title; return ts != null && ts.Visible; } }
        public void TitleLoadShown() { var ts = _title; if (ts != null && !ts.LoadShown) { ts.LoadShown = true; Note("the view is back: the title finishes reading the log and fades into the visor"); } }
        /// <summary>The renderer's own part of a title load (the new room's textures decoded and sent to the card), 0..1: the
        /// title's reading bar carries it (TitleScreen.LoadProgress). TitleRoomLoad: the renderer will report one (true colour).</summary>
        public void TitleLoadProgress(double p) { var ts = _title; if (ts != null) ts.LoadProgress = (float)Math.Max(0, Math.Min(1, p)); }
        public bool TitleRoomLoad;
        TitleScreen _title; bool _titleDone; long _aFlag, _aCurX, _aCurY, _aBtn, _aSel, _aOk; long _titleTick; Stopwatch _titleLoad;
        // THE RELEASE IS CONFIRMED, NOT FIRED AND FORGOTTEN (2026-10-10: loads "going to a black screen (no audio)" -- the game
        // never left its title). The title loop spins on `or word [flag],0x100`, a read-modify-write that DOSBox does not make
        // atomic against this process: a write landing between its read and its write is put straight back to the old value.
        // Two blind writes 80 ms apart could both be lost, and the game sat in the loop on a black title for good. So the
        // release goes in WITHOUT 0x0100 and is rewritten until the game ORs 0x0100 back onto it -- proof that the loop read it
        // after it landed (and so leaves) -- then, the loop gone, the final value.
        // THE TITLE'S CLICKS STAY AT THE TITLE (2026-10-10: "the gun still shot, but only the first right click"; the shot
        // record: no left button at all, the shot on the first right press). DOSBox hands the game every click made on the
        // title menu, and the game queues them while it waits at its title -- nothing reads them there. A new game's opening
        // movie used to drain them (0x20C26); a LOAD skips the movie now, so the left click that picked Continue was still
        // queued in play, and the next mouse event (the first right press) pumped it through: a left-down in combat = a shot.
        // So, as the title is let go (the game still in its title loop: nobody reading), every one of the input object's
        // rings ([0x182DB8] + 0x16 / 0x22 / 0x2E / 0x3A / 0x46: count, write index, read index, capacity, data) is emptied --
        // the read index moved up to the write index, then the count zeroed.
        int ClearGameInput()
        {
            long objAt = MemBase + 0x182DB8 + D2; uint obj = U32(objAt); if (obj < 0x1000 || obj > 0x10000000) return -1;
            long b = MemBase + obj; int dropped = 0;
            foreach (int off in new[] { 0x16, 0x22, 0x2E, 0x3A, 0x46 })
            {
                int cnt = U16(b + off), w = U16(b + off + 2), cap = U16(b + off + 6);
                if (cnt < 0 || w < 0 || cap <= 0 || cap > 4096 || cnt > cap || w >= cap) continue;
                if (cnt == 0) continue;
                W16(b + off + 4, w); W16(b + off, 0); dropped += cnt;
            }
            return dropped;
        }
        void ReleaseTitle(int bits, int final)
        {
            int cleared = -1; try { cleared = ClearGameInput(); } catch { }
            if (cleared > 0) Note(string.Format("title: {0} queued input event(s) from the menu dropped before play", cleared));
            int rel = 0x8200 | bits, tries = 0, f = -1; var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < 2000)
            {
                W16(_aFlag, rel); tries++;
                Thread.Sleep(4);
                f = U16(_aFlag);
                if (f >= 0 && (f & 0x0300) == 0x0300) break;                      // the loop OR'd onto OUR value: it has seen it
                if (f == rel) { Thread.Sleep(6); int f2 = U16(_aFlag); if (f2 == rel) { f = f2 | 0x0100; break; } f = f2; }   // ours, left alone: the loop is gone
            }
            if (f < 0 || (f & 0x0300) != 0x0300) Note(string.Format("title release NOT acknowledged after {0} writes (flag 0x{1:X4})", tries, f & 0xFFFF));
            else if (tries > 1) Note(string.Format("title release took {0} writes -- the loop's own write had put the flag back (0x{1:X4})", tries, f));
            Thread.Sleep(80);
            W16(_aFlag, final);
        }
        // THE HOST'S BIT FROM THE START (2026-10-10: "Sometimes it will randomly just start a new game when I'm on the menu").
        // Without 0x8000 the title loop leaves on ANY key bit -- and the keyboard interrupt sets bit 0 on every key DOWN, UP and
        // REPEAT: a skip key released (or held) after the intro's last check ended the title on its first pass. The opening
        // movie then ran unseen behind Loading RaptorMod and the menu until the mouse used it up, and a new game began. So the
        // bit goes in as soon as the game is found, before the title: the intro's checks test bit 0 alone (btr), the movie player
        // never reads the flag, and nothing in the game clears the bit -- written once, re-written only if it is ever missing.
        void ClaimTitle()
        {
            if (_title != null || _titleLoad != null) return;          // (the title's own ticks keep it from there)
            int f = U16(_aFlag); if (f >= 0 && (f & 0x8000) == 0) W16(_aFlag, f | 0x8000);
        }
        void TitleTick()
        {
            if (!TitleOn || _titleDone || _aFlag == 0) return;
            int f = U16(_aFlag); if (f < 0) return;
            if (_title == null)
            {
                if ((f & 0x0100) == 0) return;                                  // not at the title (yet)
                // FIRST "Loading RaptorMod" (Josh, 2026-10-10: "The main title/menu can appear after the loading raptor mod so
                // users always see it"): the game is held at its title (0x8000) behind the loading screen and its voice
                // until the renderer is ready and the voice has finished -- then the menu
                if (_titleLoad == null)
                {
                    W16(_aFlag, f | 0x8000); _titleLoad = Stopwatch.StartNew();
                    lock (_lk) _shownOnce = true;
                    if (!Screen.Show()) Note("loading screen failed: " + Screen.StartError);
                    if (Sound && VoicePath != null && _audio == null) { string err; _audio = LoadingAudio.Play(VoicePath, TrackPath, VoiceGain, TrackGain, VoiceLowHz, out err); if (_audio == null) Note("loading sound failed: " + err); }
                    Note("the game is at its title: Loading RaptorMod, then the title menu");
                    return;
                }
                if ((f & 0x8000) == 0) W16(_aFlag, f | 0x8000);
                bool ready; lock (_lk) ready = _ready;
                var au0 = _audio; bool voiceDone = au0 == null || au0.VoiceDone;
                if (ready) Screen.Stage(1.0, 0.3);
                if (!((ready && voiceDone && _titleLoad.ElapsedMilliseconds > 1500) || _titleLoad.ElapsedMilliseconds > 60000)) return;
                if (!ready) Note("the renderer still is not ready after 60 s -- the title menu anyway");
                Screen.Finish(); if (au0 != null) au0.FadeTrack(TrackFadeSeconds);
                var ts = new TitleScreen { ImagePath = TitleImage, SaveDir = SaveDir, GamePid = Pid, TextureQuality = TitleTextureQuality ?? "ULTRA", DocsDir = TitleDocs, RoomLoadAhead = TitleRoomLoad, GrailFx = TitleGrailFx, GrailGlow = TitleGrailGlow };
                if (!ts.Start()) { Note("title menu could not start: " + ts.StartError + " -- the game's own title waits for a key"); _titleDone = true; return; }
                W16(_aFlag, f | 0x8000);
                _title = ts;
                if (Sound && TitleMusic != null)
                {
                    string merr; _music = LoadingAudio.Play(null, TitleMusic, 0, TitleMusicGain, out merr);
                    if (_music != null) { _music.LoopTrack = true; _music.FadeInTrack(TitleMusicFadeIn); } else Note("title music failed: " + merr);
                }
                Note(string.Format("title menu up ({0} saved logs; Continue = slot {1}){2}", Array.FindAll(ts.Slots, s => s.Usable).Length, ts.NewestSlot + 1, ts.Note.Length > 0 ? " -- " + ts.Note : ""));
                return;
            }
            if (_title.Pick == TitleScreen.PickNone && !_title.Visible && _title.StartError.Length > 0)
            {
                // the menu died with no choice: never leave the game held at its title -- on as a new game
                ReleaseTitle(0, 0);
                _titleDone = true; Note("title menu failed (" + _title.StartError + ") -- the game let go into the story intro");
                return;
            }
            if (_title.Pick == TitleScreen.PickNone)
            {
                if ((f & 0x8000) == 0) W16(_aFlag, f | 0x8000);                 // (kept: the host is here)
                _title.CursorX = (short)U16(_aCurX); _title.CursorY = (short)U16(_aCurY); _title.Button = U16(_aBtn) > 0 ? 1 : 0;
                return;
            }
            int pick = _title.Pick, slot = _title.PickSlot; bool skip = pick != TitleScreen.PickNew;
            if (_music != null) _music.FadeTrack(pick == TitleScreen.PickQuit ? 0.8 : TitleMusicFadeOut);
            PickedName = pick == TitleScreen.PickLoad && slot >= 0 && slot < _title.Slots.Length ? (_title.Slots[slot].Name ?? "") : ""; PickedSlot = pick == TitleScreen.PickLoad ? slot : -1;
            if (pick == TitleScreen.PickLoad) { W16(_aSel, slot); W16(_aOk, 0); }
            // let the title go (the host's release, 0x0200) -- for a LOAD with the LOAD BIT (0x0002) in it: the title's exit
            // tests it and jumps over the opening movie (Build-AztMod 'title-loadskip-2003E'; the movie player never reads this
            // flag, it plays until a key)
            bool load = pick == TitleScreen.PickLoad;
            ReleaseTitle(load ? 0x0002 : 0, load ? 2 : skip ? 1 : 0);
            _titleDone = true; if (!load) _title.Close();                         // (a load: the title reads the log in, until TitleLoadShown)
            Note(pick == TitleScreen.PickLoad ? string.Format("title menu: LOAD slot {0} -- the intro skipped, the save loads on the first frame; the title reads it in", slot + 1)
                 : pick == TitleScreen.PickNew ? "title menu: NEW GAME -- the story intro plays" : "title menu: QUIT");
            if (pick == TitleScreen.PickQuit)
            {
                _title.WaitGone(1000);
                try { var p = Process.GetProcessById(Pid); if (!p.CloseMainWindow() || !p.WaitForExit(4000)) { p.Kill(); } } catch (Exception e) { Note("quit: " + e.Message); }
            }
        }

        void Loop()
        {
            try
            {
                // 1. find the game (its code is loaded a second or two after DOSBox starts)
                try { timeBeginPeriod(1); } catch { }      // (1 ms sleeps: the poll below must not doze 15.6 ms)
                var find = Stopwatch.StartNew(); int passes = 0; string how = "";
                while (_run && MemBase == 0)
                {
                    lock (_lk) if (_ready && !AlwaysShow) { Note("renderer ready before the game was found -- nothing to hold"); return; }
                    long minR = find.Elapsed.TotalSeconds < 20 ? (8L << 20) : 4096; passes++;
                    try
                    {
                        MemBase = FastBase(minR, false); how = "near a region start";
                        if (MemBase == 0) { MemBase = FastBase(minR, true); how = "full anchor scan"; }
                        if (MemBase == 0 && find.Elapsed.TotalSeconds > 30) { MemBase = FindBase(minR); how = "four-needle scan"; }
                    }
                    catch { MemBase = 0; }
                    if (MemBase == 0) Thread.Sleep(40);
                }
                if (MemBase == 0) return;
                Note(string.Format("game found after {0:N1} s, {1} passes ({2}; guest RAM at host 0x{3:X}; obj2 delta 0x{4:X}) -- watching for the start of play", find.Elapsed.TotalSeconds, passes, how, MemBase, D2));
                long aBuf = MemBase + _symBuf + D1, aState = MemBase + _symState + D1;
                _aState = aState; _aPeriod = FramePeriodLin != 0 ? MemBase + FramePeriodLin + D1 : 0;
                _aTick = MemBase + 0x46C; _aPer15 = MemBase + 0x1485E0 + D2; _aAcc15 = MemBase + 0x1485A0 + D2;
                // the title menu's: the skip flag, the cursor and left button, the selected row and what OK does (obj2)
                _aFlag = MemBase + 0x182DB0 + D2; _aCurX = MemBase + 0x182D6C + D2; _aCurY = MemBase + 0x182D6E + D2; _aBtn = MemBase + 0x182DA6 + D2;
                _aSel = MemBase + 0x146948 + D2; _aOk = MemBase + 0x1524CC + D2;
                // 2. watch for the first gameplay frame (and, before it, the title)
                long polls = 0;
                while (_run)
                {
                    if (TitleOn && !_titleDone && polls - _titleTick >= 6) { _titleTick = polls; try { ClaimTitle(); TitleTick(); } catch (Exception e) { Note("title menu failed: " + e.Message); _titleDone = true; if (_title != null) _title.Close(); } }
                    lock (_lk) if (_ready && !AlwaysShow && (!TitleOn || _titleDone)) { Note("renderer ready before the game reached play -- no loading screen needed"); return; }
                    uint bp = U32(aBuf), st = U32(aState);
                    if ((bp >= 0x1000 || st != 0) && _title != null && !_titleDone) { _titleDone = true; _title.Close(); }
                    if ((bp >= 0x1000 || st != 0) && _titleLoad != null)
                    {
                        // the loading screen was the title's: with the renderer ready, play needs no second one
                        bool rdy; lock (_lk) rdy = _ready;
                        if (rdy) { Note("the game reached play after the title menu -- the renderer is ready, no second loading screen"); return; }
                    }
                    if (bp >= 0x1000 || st != 0)
                    {
                        lock (_lk)
                        {
                            if (_ready && !AlwaysShow) { Note("renderer ready just in time -- no loading screen needed"); return; }
                            if (HoldGame()) { _held = true; WasHeld = true; _shownOnce = true; _holdClock.Restart(); _elSet = false; FreezeBoot(); if (_ready) _releaseReq = true; }
                        }
                        if (!_held) { Note("the game reached play before the renderer was ready and could NOT be held"); return; }
                        if (!Screen.Show()) Note("loading screen failed: " + Screen.StartError);
                        if (Sound && VoicePath != null)
                        {
                            string err; _audio = LoadingAudio.Play(VoicePath, TrackPath, VoiceGain, TrackGain, VoiceLowHz, out err);
                            Note(_audio != null ? string.Format("loading sound: voice {0:N1} s over the track {1:N1} s", _audio.VoiceSeconds, _audio.TrackSeconds) : "loading sound failed: " + err);
                        }
                        Note(string.Format("{0} (boot state {1}{2}) -- held, loading screen up",
                                           _ready ? "the game reached play with the renderer ready: the loading screen anyway, until its voice is done" : "the game reached play before the renderer was ready",
                                           st, st != 0 && polls == 0 ? ", ALREADY under way when the game was found" : ""));
                        break;
                    }
                    polls++;
                    Thread.Sleep(1);
                }
                // 3. the backstop: never leave it frozen
                while (_run)
                {
                    lock (_lk) { if (!_held) return; FreezeBoot(); }
                    if (_releaseReq)
                    {
                        var au = _audio;
                        if (au == null || au.VoiceDone)
                        {
                            lock (_lk) { if (!_held) return; _held = false; }
                            ReleaseNow(au == null ? "renderer ready: game released" : "renderer ready and the loading voice finished: game released", false);
                            return;
                        }
                        Screen.Stage(1.0, 0.3);                        // (ready: the bar full while the voice finishes)
                    }
                    if (_holdClock.ElapsedMilliseconds > MaxHoldMs)
                    {
                        Note(string.Format("renderer still not ready after {0} ms -- releasing the game anyway", MaxHoldMs));
                        lock (_lk) { _held = false; }
                        ReleaseGame(_holdClock.Elapsed.TotalMilliseconds); if (_audio != null) _audio.FadeTrack(TrackFadeSeconds); Screen.Finish(); return;
                    }
                    Thread.Sleep(1);
                }
            }
            catch (Exception e) { Note("failed: " + e.Message); lock (_lk) { if (_held) { _held = false; try { ReleaseGame(_holdClock.Elapsed.TotalMilliseconds); } catch { } Screen.Finish(); } } }
        }

        public void Dispose()
        {
            if (_title != null) { try { _title.Close(); _title.WaitGone(800); _title.Dispose(); } catch { } }
            var mu = _music; _music = null; if (mu != null) { try { mu.FadeTrack(0.5); mu.Wait(900); mu.Dispose(); } catch { } }
            Ready(true);                            // (releases a held game)
            var a = _audio; _audio = null; if (a != null) { a.Wait(2500); a.Dispose(); }
            _run = false;
            if (_th != null) { _th.Join(1000); _th = null; }
            Screen.Wait(1500); Screen.Dispose();
            if (_proc != IntPtr.Zero) { CloseHandle(_proc); _proc = IntPtr.Zero; }
        }
    }
}
