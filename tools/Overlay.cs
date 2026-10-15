// Overlay.cs -- TRUE COLOUR, PHASE 0: the host's picture in the host's own window.
//
// The game is an 8-bit program and stays one: its video mode, its blits, its palette fades and
// its movies all assume a byte a pixel, and there is no room left in the overlay to change that.
// So the 3D view stops going THROUGH the game. It is drawn here, in a borderless window that
// sits exactly over the game's viewport and lets every click and key fall through to DOSBox.
//
// What the game itself draws over the view -- reticle, cursor, hover text, conversation text,
// the visor frame's edges -- must still be seen. So the game is handed a FLAT frame of one
// colour (the key) instead of a picture, and the finished screen is read back out of DOSBox's
// own 32-bit display surface: wherever the viewport is not the key colour, the game has drawn
// something, and that pixel is laid over ours.
//
// THE KEY IS MEASURED EVERY FRAME, NOT ASSUMED: it is whatever colour most of the viewport is.
// That follows a palette fade for free, and it doubles as the test for "the game is showing
// something else here" (a movie, a full-screen menu) -- if no one colour holds the viewport,
// the overlay gets out of the way.
//
// THE WINDOW HAS ITS OWN THREAD, which also does the scaling and the blit. PowerShell is not
// DPI-aware (it sees this 2560x1600 desktop as 1707x1067), and a window is only free of DWM's
// bitmap stretching if the thread that creates it is; and a window nobody pumps messages for
// is declared hung and replaced by a ghost.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace AztTool
{
    public class Overlay : IDisposable
    {
        // ---- Win32 ---------------------------------------------------------------------
        delegate IntPtr WndProcD(IntPtr h, uint msg, IntPtr w, IntPtr l);
        delegate bool EnumD(IntPtr h, IntPtr l);

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
        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER
        {
            public int biSize, biWidth, biHeight; public short biPlanes, biBitCount;
            public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
        }

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
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumD cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
        [DllImport("gdi32.dll")]
        static extern int SetDIBitsToDevice(IntPtr dc, int x, int y, uint w, uint h, int sx, int sy, uint start, uint lines, int[] bits, ref BITMAPINFOHEADER bmi, uint usage);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, [Out] int[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, [Out] byte[] buf, IntPtr size, out IntPtr read);

        const int WS_POPUP = unchecked((int)0x80000000);
        const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
        const uint SWP_NOACTIVATE = 0x10, SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2;
        const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4;
        const uint WM_NCHITTEST = 0x84;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string cls, string name);
        // THE COVER (Josh, 2026-10-10: loading from the title, "the bottom interface appears over it and flickers ... no visor
        // interface until after the game is loaded"): the title (LoadingScreen.cs TitleScreen, window name CoverName) stays on
        // top while it reads a log in, and every host window that puts itself topmost goes JUST BELOW it instead of fighting it
        // for the top (both re-asserted on timers: the swap was the flicker). It fades out over them when the view is back.
        public const string CoverName = "AztTitleCover";
        static IntPtr _cover; static long _coverAt;
        /// <summary>Where a host window goes in the z-order: just below the game's cursor (CursorIcons.cs) while it is drawn
        /// by the host, else just below the title while it is up, else the top.</summary>
        public static IntPtr TopSlot()
        {
            IntPtr cw = CursorWindow; if (cw != IntPtr.Zero) return cw;
            return CoverSlot();
        }
        /// <summary>Just below the title while it is up, else the top (the cursor's own place).</summary>
        public static IntPtr CoverSlot()
        {
            long now = Stopwatch.GetTimestamp();
            if (now - _coverAt > Stopwatch.Frequency / 10) { _coverAt = now; IntPtr c = FindWindowW(null, CoverName); _cover = c != IntPtr.Zero && IsWindowVisible(c) ? c : IntPtr.Zero; }
            return _cover != IntPtr.Zero ? _cover : HWND_TOPMOST;
        }
        /// <summary>THE GAME'S CURSOR, DRAWN BY THE HOST (CursorIcons.cs IconCursor): every other host window goes below it.</summary>
        public static IntPtr CursorWindow;
        /// <summary>The game draws NO cursor of its own just now (IconCursor has blanked its bitmap and draws it instead): the
        /// panel then takes the screen as it is round the pointer -- there is no cursor to tell apart from the text under it.</summary>
        public static volatile bool GameCursorBlank;

        // ---- state ---------------------------------------------------------------------
        readonly int _pid, _w, _h, _screenW, _screenH, _vpX, _vpY;
        readonly IntPtr _proc;
        Thread _thread; volatile bool _run; WndProcD _wndProc; IntPtr _hwnd; string _cls;
        readonly AutoResetEvent _evt = new AutoResetEvent(false);
        readonly ManualResetEvent _up = new ManualResetEvent(false);
        readonly object _lock = new object();
        int[] _back, _ready, _show, _surf, _dst;
        bool _pending; long _lastFrameTicks; volatile bool _want;
        long _vpAddr; int _stridePx;
        int _rx, _ry, _rw, _rh;                 // where the window is, in physical pixels
        int[] _xi, _xf;                         // per-column source index and fraction

        public string StartError = "";
        public string RectText = "(not placed)";
        public string GameWindowText = "(not found)";
        public long Presented, Blits; public int SlowRegionsSkipped;
        public double ScaleMs, ComposeMs, ReadMs;
        public bool Shown;
        // ---- THE CARD'S OWN WINDOW (optimisation pass, Josh 2026-10-08: 65-70 fps) --------------------------------
        // The card can draw straight into a window, so the finished picture need not come back to the processor, be
        // stretched there and be copied to this window by GDI (5-15 ms a frame at 4K). A window OpenGL draws into
        // must never also be drawn by GDI, so the card gets a second window of its own, placed with this one; only
        // one of the two is ever shown. GlPresent picks it (the processor's path, F9, keeps this window).
        IntPtr _glHwnd; volatile bool _glDrawn; bool _glWas;
        /// <summary>The card's window (for GpuRaster.AttachPresent); zero until Start.</summary>
        public IntPtr GlWindow { get { return _glHwnd; } }
        /// <summary>Show the card's window instead of this one; pictures arrive by NoteGlFrame.</summary>
        public volatile bool GlPresent;
        /// <summary>The card has just put a picture in its window (its SwapBuffers).</summary>
        public void NoteGlFrame()
        {
            Interlocked.Exchange(ref _lastFrameTicks, Stopwatch.GetTimestamp());
            _want = true; _glDrawn = true; Presented++; _evt.Set();
        }
        /// <summary>The decorations (boot, visor shading, scanner) on a picture, without handing it to this window --
        /// for a picture the card shows (GpuRaster.PresentPicture).</summary>
        public void DecorateOnly(int[] pic, int pw, int ph)
        {
            lock (_presentLock)
            {
                EnsureSize(pw, ph);
                Decorated(pic, pw, ph);
                if (KeepCopy) { if (_copy == null || _copy.Length != pic.Length) _copy = new int[pic.Length]; Buffer.BlockCopy(pic, 0, _copy, 0, pic.Length * 4); }
            }
        }
        /// <summary>A rectangle of the game's viewport (x0, y0, x1, y1) whose drawings are not laid
        /// over the picture: the widescreen panel (Panel.cs) draws the opened log box there. Null = none.</summary>
        public int[] HideRect;
        /// <summary>A second such rectangle: the scanner's wireframe box, which the host draws itself (ScanWire.cs).</summary>
        public int[] HideRect2;
        /// <summary>View rows from this one down: the game's drawings there are left out (as GpuRaster.HideFromRow).</summary>
        public int HideFromRow = int.MaxValue;
        /// <summary>Nudges and a full override, for when the computed placement is not right.</summary>
        public int NudgeX, NudgeY, NudgeW, NudgeH;
        /// <summary>Fill the game window's whole width (see Place).</summary>
        public bool Wide;
        /// <summary>Game rows BELOW the view that the picture carries on into (set before Start): the 3D under
        /// the widescreen panel, so the panel's gaps show the world instead of black. The picture keeps
        /// the view's scale; those rows show the picture alone (the game's drawings there are its panel).</summary>
        public int ExtendRows;
        /// <summary>Picture rows that are the game's view, for a picture ph rows tall.</summary>
        public int ViewRowsOf(int ph) { return ExtendRows > 0 ? (int)Math.Round((double)ph * _h / (_h + ExtendRows)) : ph; }
        public int FixX = -1, FixY = -1, FixW = -1, FixH = -1;
        /// <summary>Show whatever the foreground window is. Only for testing without a game.</summary>
        public bool IgnoreForeground;
        /// <summary>Hide if the main loop has not handed over a frame for this long.</summary>
        public int StaleMs = 400;
        /// <summary>Until this Stopwatch tick the window counts as fresh whatever the frames (the game's own long stalls the host
        /// covers with its own picture: the save's ~3 s of file writing, Josh 2026-10-09 -- hidden, the game's 8-bit screen showed).</summary>
        public long HoldFreshUntil;
        public int LastKey;                     // the key colour measured on the last frame (0xRRGGBB)
        /// <summary>The key the host hands the game (0xRRGGBB; -1 = none): see-through too, whatever the commonest colour is (as GpuRaster.KeyAlso).</summary>
        public int KeyAlso = -1;
        /// <summary>FLICKER WATCH. Screen readings rejected because part of the view had turned
        /// pure black where the reading before held the key (a reading caught while DOSBox was
        /// redrawing: laid over the picture it would flash that part black); and how often the
        /// window was hidden, by reason. Read and reset by the watcher's report.</summary>
        public long TornReads, HideStale, HideFront, HidePlace, HideWant;
        /// <summary>A torn reading is kept back at most this many times in a row; past that the
        /// black is real (a fade, a menu) and goes through.</summary>
        public int TornHoldMax = 3;
        bool[] _prevKeySamp; int _tornRun;

        int _scaleSrcW;
        /// <summary>The window's size on the screen in real pixels; 0 until it has been placed.</summary>
        public int RectW { get { return _rw; } }
        public int RectH { get { return _rh; } }
        public bool Located { get { return _vpAddr != 0; } }
        public long SurfaceAddress { get { return _vpAddr; } }
        public int SurfaceStride { get { return _stridePx; } }

        public Overlay(int pid, int w, int h, int screenW, int screenH, int vpX, int vpY)
        {
            _pid = pid; _w = w; _h = h; _screenW = screenW; _screenH = screenH; _vpX = vpX; _vpY = vpY;
            _back = new int[w * h]; _ready = new int[w * h]; _show = new int[w * h];
            _proc = OpenProcess(0x0410, false, pid);        // QUERY_INFORMATION | VM_READ
            if (_proc == IntPtr.Zero) throw new InvalidOperationException("OpenProcess failed: " + Marshal.GetLastWin32Error());
        }

        public bool Start()
        {
            _run = true;
            _thread = new Thread(WindowThread); _thread.IsBackground = true; _thread.Name = "AztOverlay";
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();
            _up.WaitOne(3000);
            return _hwnd != IntPtr.Zero;
        }

        public void Hide() { _want = false; }

        public void Dispose()
        {
            _run = false; _runReader = false; _evt.Set();
            if (_reader != null) { _reader.Join(1500); _reader = null; }
            _subEvt.Set(); if (_worker != null) { _worker.Join(1500); _worker = null; }
            if (_thread != null) { _thread.Join(1500); _thread = null; }
            if (_proc != IntPtr.Zero) CloseHandle(_proc);
        }

        // ---- the window thread ------------------------------------------------------------
        IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            if (msg == WM_NCHITTEST) return new IntPtr(-1);     // HTTRANSPARENT
            return DefWindowProcW(h, msg, w, l);
        }

        void WindowThread()
        {
            try
            {
                // Per-monitor aware (v2), for THIS thread and so for the window it creates.
                try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
                _wndProc = WndProc;
                _cls = "AztOverlay" + Stopwatch.GetTimestamp();
                var wc = new WNDCLASSEX();
                wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
                wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
                wc.hInstance = GetModuleHandleW(IntPtr.Zero);
                wc.lpszClassName = _cls;
                if (RegisterClassExW(ref wc) == 0) { StartError = "RegisterClassEx failed: " + Marshal.GetLastWin32Error(); return; }
                _hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                                        _cls, "", WS_POPUP, 0, 0, 16, 16, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_hwnd == IntPtr.Zero) { StartError = "CreateWindowEx failed: " + Marshal.GetLastWin32Error(); return; }
                SetLayeredWindowAttributes(_hwnd, 0, 255, 2);   // LWA_ALPHA, opaque: ordinary GDI drawing then works
                // the card's window: the same kind (click-through, topmost, never focused); OpenGL draws into a layered
                // window like this one (tested 2026-10-08: exact colours on screen, the context current on another thread)
                _glHwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                                          _cls, "", WS_POPUP, 0, 0, 16, 16, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_glHwnd != IntPtr.Zero) SetLayeredWindowAttributes(_glHwnd, 0, 255, 2);
            }
            catch (Exception e) { StartError = e.Message; }
            finally { _up.Set(); }
            if (_hwnd == IntPtr.Zero) return;

            var placeClock = Stopwatch.StartNew(); bool placed = false, drawn = false;
            while (_run)
            {
                MSG m;
                while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }

                if (!placed || placeClock.ElapsedMilliseconds >= 250) { placed = Place(); placeClock.Restart(); }

                bool fresh = (Stopwatch.GetTimestamp() - Interlocked.Read(ref _lastFrameTicks)) * 1000 / Stopwatch.Frequency < StaleMs || Stopwatch.GetTimestamp() < Interlocked.Read(ref HoldFreshUntil);
                bool front = IgnoreForeground || GameInFront();
                bool show = _want && placed && fresh && front;

                bool gl = GlPresent && _glHwnd != IntPtr.Zero;
                if (gl != _glWas)
                {
                    // the other window goes; the one taking over shows once it has a picture of its own
                    if (Shown) { ShowWindow(_glWas ? _glHwnd : _hwnd, SW_HIDE); Shown = false; }
                    drawn = false; _glDrawn = false; _glWas = gl;
                }
                if (!gl)
                {
                    bool take = false;
                    int[] showBuf = null; int srcW = 0, srcH = 0;
                    lock (_lock) { if (_pending) { var t = _ready; _ready = _show; _show = t; _pending = false; take = true; showBuf = _show; srcW = _pw; srcH = _ph; } }
                    if (take && show && _rw > 0 && _rh > 0 && showBuf != null && showBuf.Length == srcW * srcH)
                    {
                        var sw = Stopwatch.StartNew();
                        if (_dst == null || _dst.Length != _rw * _rh) _dst = new int[_rw * _rh];
                        if (srcW != _scaleSrcW) { _xi = null; _scaleSrcW = srcW; }
                        Scale(showBuf, srcW, srcH, _dst, _rw, _rh, ref _xi, ref _xf);
                        ScaleMs = sw.Elapsed.TotalMilliseconds;
                        Blit(); drawn = true;
                    }
                }
                else { ScaleMs = 0; if (_glDrawn) drawn = true; }      // (the card scales, on its way into its window)
                IntPtr act = gl ? _glHwnd : _hwnd;
                // Shown only once there is a picture in it, and never with a stale one.
                if (show && drawn && !Shown) { ShowWindow(act, SW_SHOWNOACTIVATE); SetWindowPos(act, TopSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); Shown = true; }
                else if (!show && Shown)
                {
                    if (!_want) HideWant++; else if (!placed) HidePlace++; else if (!fresh) HideStale++; else HideFront++;
                    ShowWindow(act, SW_HIDE); Shown = false; drawn = false;
                }
                if (!show) { drawn = false; _glDrawn = false; }

                _evt.WaitOne(6);
            }
            ShowWindow(_hwnd, SW_HIDE); Shown = false;
            if (_glHwnd != IntPtr.Zero) { ShowWindow(_glHwnd, SW_HIDE); DestroyWindow(_glHwnd); _glHwnd = IntPtr.Zero; }
            DestroyWindow(_hwnd); _hwnd = IntPtr.Zero;
            UnregisterClassW(_cls, GetModuleHandleW(IntPtr.Zero));
        }

        bool GameInFront()
        {
            uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p);
            return p == (uint)_pid;
        }

        IntPtr FindGameWindow(out RECT client, out POINT origin)
        {
            IntPtr best = IntPtr.Zero; long bestArea = 0; RECT bc = new RECT(); POINT bo = new POINT();
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint p; GetWindowThreadProcessId(h, out p);
                if (p != (uint)_pid || !IsWindowVisible(h) || IsIconic(h)) return true;
                RECT c; if (!GetClientRect(h, out c)) return true;
                long area = (long)(c.r - c.l) * (c.b - c.t);
                if (area > bestArea) { POINT o = new POINT(); ClientToScreen(h, ref o); best = h; bestArea = area; bc = c; bo = o; }
                return true;
            }, IntPtr.Zero);
            client = bc; origin = bo;
            return best;
        }

        // Where the viewport is on the screen: the game's picture is fitted into DOSBox's client
        // area at its own shape (viewport = fit, square pixels), centred, and the viewport is a
        // known rectangle of that picture.
        bool Place()
        {
            int x, y, w, h;
            if (FixW > 0 && FixH > 0) { x = FixX; y = FixY; w = FixW; h = FixH; GameWindowText = "(fixed rectangle)"; }
            else
            {
                RECT c; POINT o;
                if (FindGameWindow(out c, out o) == IntPtr.Zero) { GameWindowText = "(not found)"; return false; }
                int cw = c.r - c.l, ch = c.b - c.t;
                if (cw < 64 || ch < 64) return false;
                GameWindowText = cw + "x" + ch + " at " + o.x + "," + o.y;
                double s = Math.Min((double)cw / _screenW, (double)ch / _screenH);
                double ox = o.x + (cw - _screenW * s) / 2, oy = o.y + (ch - _screenH * s) / 2;
                int l = (int)Math.Round(ox + _vpX * s), r = (int)Math.Round(ox + (_vpX + _w) * s);
                int t = (int)Math.Round(oy + _vpY * s), b = (int)Math.Round(oy + (_vpY + _h + ExtendRows) * s);
                // WIDE: the whole width of the game's window, not just the 4:3 picture's. On a
                // widescreen display the 3D view then runs out past the pillars either side; the
                // picture handed in is drawn that wide, and the game's own drawings land in the
                // middle where its 4:3 picture is (see Present).
                if (Wide) { l = o.x; r = o.x + cw; }
                x = l + NudgeX; y = t + NudgeY; w = r - l + NudgeW; h = b - t + NudgeH;
            }
            if (w < 16 || h < 16) return false;
            if (x != _rx || y != _ry || w != _rw || h != _rh)
            {
                _rx = x; _ry = y; _rw = w; _rh = h; _xi = null;
                SetWindowPos(_hwnd, TopSlot(), x, y, w, h, SWP_NOACTIVATE);
                if (_glHwnd != IntPtr.Zero) SetWindowPos(_glHwnd, TopSlot(), x, y, w, h, SWP_NOACTIVATE);     // (the card's window, in step)
                RectText = w + "x" + h + " at " + x + "," + y;
            }
            return true;
        }

        void Blit()
        {
            IntPtr dc = GetDC(_hwnd);
            if (dc == IntPtr.Zero) return;
            var bi = new BITMAPINFOHEADER();
            bi.biSize = 40; bi.biWidth = _rw; bi.biHeight = -_rh; bi.biPlanes = 1; bi.biBitCount = 32;
            if (SetDIBitsToDevice(dc, 0, 0, (uint)_rw, (uint)_rh, 0, 0, 0, (uint)_rh, _dst, ref bi, 0) > 0) Blits++;
            ReleaseDC(_hwnd, dc);
        }

        // ---- scaling ----------------------------------------------------------------------
        // Bilinear, 8-bit fractions, rows in parallel. The red/blue pair and the green channel are
        // interpolated as two packed multiplies each.
        public static void Scale(int[] src, int sw, int sh, int[] dst, int dw, int dh, ref int[] xi, ref int[] xf)
        {
            if (dw == sw && dh == sh) { Buffer.BlockCopy(src, 0, dst, 0, sw * sh * 4); return; }
            if (xi == null || xi.Length != dw)
            {
                xi = new int[dw]; xf = new int[dw];
                for (int x = 0; x < dw; x++)
                {
                    double fx = (x + 0.5) * sw / dw - 0.5; if (fx < 0) fx = 0;
                    int ix = (int)fx; if (ix > sw - 2) { ix = sw - 2; fx = sw - 1; }
                    xi[x] = ix; xf[x] = (int)((fx - ix) * 256);
                }
            }
            int[] cxi = xi, cxf = xf;
            Parallel.For(0, dh, y =>
            {
                double fy = (y + 0.5) * sh / dh - 0.5; if (fy < 0) fy = 0;
                int iy = (int)fy; if (iy > sh - 2) { iy = sh - 2; fy = sh - 1; }
                int wy = (int)((fy - iy) * 256), r0 = iy * sw, r1 = r0 + sw, o = y * dw;
                for (int x = 0; x < dw; x++)
                {
                    int ix = cxi[x], wx = cxf[x];
                    int a = src[r0 + ix], b = src[r0 + ix + 1], c = src[r1 + ix], d = src[r1 + ix + 1];
                    uint ux = (uint)wx, nx = 256 - ux, uy = (uint)wy, ny = 256 - uy;
                    uint topRB = (((uint)a & 0xFF00FF) * nx + ((uint)b & 0xFF00FF) * ux) >> 8 & 0xFF00FF;
                    uint topG  = (((uint)a & 0x00FF00) * nx + ((uint)b & 0x00FF00) * ux) >> 8 & 0x00FF00;
                    uint botRB = (((uint)c & 0xFF00FF) * nx + ((uint)d & 0xFF00FF) * ux) >> 8 & 0xFF00FF;
                    uint botG  = (((uint)c & 0x00FF00) * nx + ((uint)d & 0x00FF00) * ux) >> 8 & 0x00FF00;
                    int rb = (int)((topRB * ny + botRB * uy) >> 8 & 0xFF00FF);
                    int g  = (int)((topG  * ny + botG  * uy) >> 8 & 0x00FF00);
                    dst[o + x] = rb | g;
                }
            });
        }

        // ---- finding the viewport in DOSBox's display surface -----------------------------
        // The viewport is as wide as the screen, so a flat fill says nothing about where a row
        // starts, and the game draws over the top and bottom rows and the left edge. So the
        // calibration frame is a flat colour with ONE RECTANGLE of a second colour, placed clear
        // of the edges and the reticle: rows that read [>=32 of X][exactly rw of Y][>=32 of X],
        // rh of them one stride apart, cannot be anything else.
        public static byte[] PatchFrame(int w, int h, byte a, byte b, int rx, int ry, int rw, int rh)
        {
            var f = new byte[w * h];
            for (int i = 0; i < f.Length; i++) f[i] = a;
            for (int y = ry; y < ry + rh; y++) for (int x = rx; x < rx + rw; x++) f[y * w + x] = b;
            return f;
        }

        public static byte[] FlatFrame(int w, int h, byte a)
        {
            var f = new byte[w * h];
            for (int i = 0; i < f.Length; i++) f[i] = a;
            return f;
        }

        /// <summary>Every place in the given regions where the patch is found. Each result is
        /// { host address of viewport pixel (0,0), stride in pixels }.</summary>
        public List<long[]> FindPatch(long[] bases, long[] sizes, int rx, int ry, int rw, int rh)
        {
            var found = new List<long[]>();
            var chunk = new byte[16 << 20];
            // SLOW MEMORY LAST, AND ONLY IF NOTHING ELSE HAS THE SCREEN. Some of DOSBox's regions
            // read at ~20 MB/s (driver-mapped); searching them cost most of a 4.4 s search, and
            // a copy of the screen living in one is no use for reading every frame anyway.
            SlowRegionsSkipped = 0;
            var order = new List<int>(); var slow = new List<int>(); var probe = new byte[1 << 20];
            for (int k = 0; k < bases.Length; k++)
            {
                if (sizes[k] < (long)_w * _h * 4 || sizes[k] > (600L << 20)) continue;
                var psw = Stopwatch.StartNew(); IntPtr pg;
                if (!ReadProcessMemory(_proc, new IntPtr(bases[k]), probe, new IntPtr(probe.Length), out pg)) continue;
                if (psw.Elapsed.TotalMilliseconds > 6) slow.Add(k); else order.Add(k);
            }
            int fastCount = order.Count; order.AddRange(slow);
            for (int oi = 0; oi < order.Count; oi++)
            {
                if (oi >= fastCount && found.Count > 0) { SlowRegionsSkipped = order.Count - oi; break; }
                int ri = order[oi];
                long size = sizes[ri];
                int n = (int)(size / 4);
                int[] a;
                try { a = new int[n]; } catch (OutOfMemoryException) { continue; }
                bool ok = true;
                for (long off = 0; off < size; off += chunk.Length)
                {
                    int len = (int)Math.Min(chunk.Length, size - off); IntPtr got;
                    if (!ReadProcessMemory(_proc, new IntPtr(bases[ri] + off), chunk, new IntPtr(len), out got) || got.ToInt64() != len) { ok = false; break; }
                    Buffer.BlockCopy(chunk, 0, a, (int)off, len & ~3);
                }
                if (!ok) continue;

                var hits = new List<int>();
                int i = 0, prevCol = -1, prevLen = 0, pendStart = -1, pendFlank = 0;
                while (i < n)
                {
                    int c = a[i] & 0xFFFFFF, j = i + 1;
                    while (j < n && (a[j] & 0xFFFFFF) == c) j++;
                    int len = j - i;
                    if (pendStart >= 0) { if (c == pendFlank && len >= 32) hits.Add(pendStart); pendStart = -1; }
                    if (len == rw && prevLen >= 32 && prevCol != c) { pendStart = i; pendFlank = prevCol; }
                    prevCol = c; prevLen = len; i = j;
                }
                if (hits.Count < rh) continue;
                var set = new HashSet<int>(hits);
                // the stride: the screen's width, or failing that the commonest gap between hits
                var strides = new List<int>(); strides.Add(_screenW);
                var gaps = new Dictionary<int, int>();
                for (int k = 1; k < hits.Count; k++) { int gp = hits[k] - hits[k - 1]; int cnt; gaps.TryGetValue(gp, out cnt); gaps[gp] = cnt + 1; }
                int bestGap = 0, bestCnt = 0; foreach (var kv in gaps) if (kv.Value > bestCnt) { bestCnt = kv.Value; bestGap = kv.Key; }
                if (bestGap > rw && bestGap != _screenW) strides.Add(bestGap);
                foreach (int st in strides)
                {
                    foreach (int hgt in hits)
                    {
                        if (set.Contains(hgt - st)) continue;           // not the top row of its column
                        int k = 0; while (set.Contains(hgt + k * st)) k++;
                        if (k != rh) continue;
                        long vp = (long)hgt - (long)ry * st - rx;
                        if (vp < 0 || vp + (long)(_h - 1) * st + _w > n) continue;
                        found.Add(new long[] { bases[ri] + vp * 4, st });
                    }
                    if (found.Count > 0) break;
                }
            }
            return found;
        }

        /// <summary>Is the patch at this place NOW? Used to tell a live surface from a stale copy:
        /// move the patch, and only a surface that is really being displayed follows it.</summary>
        public bool CheckPatch(long vpAddr, int stridePx, int rx, int ry, int rw, int rh)
        {
            int x0 = rx - 32, n = rw + 64; var row = new int[n]; IntPtr got;
            long at = vpAddr + ((long)(ry + rh / 2) * stridePx + x0) * 4;
            if (!ReadProcessMemory(_proc, new IntPtr(at), row, new IntPtr(n * 4), out got) || got.ToInt64() != n * 4) return false;
            int outside = row[0] & 0xFFFFFF, inside = row[32] & 0xFFFFFF;
            if (outside == inside) return false;
            for (int i = 0; i < n; i++)
            {
                int want = (i >= 32 && i < 32 + rw) ? inside : outside;
                if ((row[i] & 0xFFFFFF) != want) return false;
            }
            return true;
        }

        // THE SURFACE IS READ ON ITS OWN THREAD, never in the frame.
        //
        // The first live run read it inline and the picture ran at 3-5 frames a second: the copy
        // of the display that had been chosen took 277 ms to read 5.9 MB (the first of six
        // places the screen was found in -- evidently memory mapped from the graphics driver
        // rather than ordinary RAM). Two changes: the watcher now times every live copy and
        // takes the fastest, and whatever a read costs, it only ever delays the game's own
        // drawings over the view, not the view.
        readonly object _surfLock = new object();
        int[] _surfRead, _surfLatest;
        bool _surfFresh, _haveSurf; int _latestKey, _latestShare, _key, _share;
        Thread _reader; volatile bool _runReader = true; long _lastPresentTicks; volatile int _consecFails;
        public long Reads;
        /// <summary>Read inside Present, as the tests need (paint, then present, then look).</summary>
        public bool SyncRead;
        /// <summary>Pause between reads of the display surface.</summary>
        public int ReadPauseMs = 6;

        public void SetSurface(long vpAddr, int stridePx)
        {
            int n = stridePx * (_h - 1) + _w;
            lock (_surfLock) { _surfRead = new int[n]; _surfLatest = new int[n]; _surf = new int[n]; _haveSurf = false; _surfFresh = false; }
            _stridePx = stridePx; _vpAddr = vpAddr; _consecFails = 0;
            if (!SyncRead && _reader == null) { _reader = new Thread(ReaderLoop); _reader.IsBackground = true; _reader.Name = "AztOverlayRead"; _reader.Start(); }
        }

        /// <summary>Milliseconds to read the whole viewport from this place (best of two), or -1.</summary>
        public double TimeRead(long vpAddr, int stridePx)
        {
            var b = new int[stridePx * (_h - 1) + _w]; double best = -1; IntPtr got;
            for (int k = 0; k < 2; k++)
            {
                var sw = Stopwatch.StartNew();
                if (!ReadProcessMemory(_proc, new IntPtr(vpAddr), b, new IntPtr(b.Length * 4), out got) || got.ToInt64() != b.Length * 4) return -1;
                double ms = sw.Elapsed.TotalMilliseconds; if (best < 0 || ms < best) best = ms;
            }
            return best;
        }

        readonly Dictionary<int, int> _hist = new Dictionary<int, int>(64); bool[] _spareKeySamp;
        bool ReadOnce()
        {
            int[] buf = _surfRead; long addr = _vpAddr; int st = _stridePx;
            if (buf == null || addr == 0) return false;
            var sw = Stopwatch.StartNew(); IntPtr got; int bytes = buf.Length * 4;
            if (!ReadProcessMemory(_proc, new IntPtr(addr), buf, new IntPtr(bytes), out got) || got.ToInt64() != bytes) { _consecFails++; return false; }
            ReadMs = sw.Elapsed.TotalMilliseconds;
            // the key: the commonest colour among a grid of samples
            var hist = _hist; hist.Clear(); int samples = 0, key = 0, keyN = 0;          // (one dictionary, kept: ~128 readings a second -- 2026-10-13 audit)
            for (int y = 4; y < _h; y += 8)
            {
                int r = y * st;
                for (int x = 8; x < _w; x += 16)
                {
                    int c = buf[r + x] & 0xFFFFFF, cnt; hist.TryGetValue(c, out cnt); cnt++; hist[c] = cnt; samples++;
                    if (cnt > keyN) { keyN = cnt; key = c; }
                }
            }
            // TORN? Samples that held the key last time and are now pure black (and black is not
            // the new key): DOSBox was caught part-way through drawing its screen. Keep the last
            // good reading instead -- the black would be laid over the picture as the game's own.
            int nS = samples, si = 0, wentBlack = 0;
            bool[] prevK = _prevKeySamp, curK = _spareKeySamp != null && _spareKeySamp.Length == nS ? _spareKeySamp : new bool[nS];     // (two arrays in turn, not a new one each reading)
            for (int y = 4; y < _h; y += 8)
            {
                int r = y * st;
                for (int x = 8; x < _w; x += 16, si++)
                {
                    int c = buf[r + x] & 0xFFFFFF; curK[si] = c == key;
                    if (prevK != null && si < prevK.Length && prevK[si] && c == 0 && key != 0) wentBlack++;
                }
            }
            if (wentBlack >= Math.Max(8, nS / 100) && _tornRun < TornHoldMax) { _tornRun++; TornReads++; return true; }
            _tornRun = 0; _spareKeySamp = _prevKeySamp; _prevKeySamp = curK;
            lock (_surfLock)
            {
                if (buf != _surfRead) return false;             // the surface was changed under us
                _surfRead = _surfLatest; _surfLatest = buf;
                _latestKey = key; _latestShare = (int)(1000L * keyN / Math.Max(1, samples));
                _surfFresh = true; _haveSurf = true;
            }
            _consecFails = 0; Reads++;
            return true;
        }

        void ReaderLoop()
        {
            while (_runReader)
            {
                bool active = _vpAddr != 0 && (Stopwatch.GetTimestamp() - Interlocked.Read(ref _lastPresentTicks)) * 1000 / Stopwatch.Frequency < 500;
                if (active) { if (!ReadOnce()) Thread.Sleep(20); Thread.Sleep(Math.Max(1, ReadPauseMs)); }
                else Thread.Sleep(20);
            }
        }

        // ---- one frame --------------------------------------------------------------------
        /// <summary>Lay the game's own drawings over the host's picture and hand it to the window.
        /// Returns the share of the viewport (per thousand) holding the key colour in the latest
        /// reading of the screen, or -1 if the screen cannot be read. Below minShare the game is
        /// showing something of its own there and the overlay hides.</summary>
        public int Present(byte[] color8, int[] pal32, int minShare) { return Present(color8, pal32, null, _w, _h, minShare); }
        /// <summary>The same, for a picture that is already true colour (0x00RRGGBB).</summary>
        public int PresentRgb(int[] rgb, int minShare) { return Present(null, null, rgb, _w, _h, minShare); }
        // THE PICTURE NEED NOT BE THE GAME'S SIZE. The game's viewport is 1600x928 whatever the
        // display is; the host's picture is drawn at the size the viewport actually occupies on
        // THIS screen (2134x1238 on a 2560x1600 display, 1440x835 on 1920x1080...), so nothing
        // is stretched. The game's own drawings are still 1600x928 and are laid over it with
        // bilinear weights, so a cursor or a line of text has smooth edges against the picture
        // instead of doubled pixels.
        public int Present(byte[] color8, int[] pal32, int pw, int ph, int minShare) { return Present(color8, pal32, null, pw, ph, minShare); }
        public int PresentRgb(int[] rgb, int pw, int ph, int minShare) { return Present(null, null, rgb, pw, ph, minShare); }
        int _pw, _ph; int[] _cxi, _cxf;

        // ---- the visor frame for the wide picture ---------------------------------------------
        public bool Visor = true;
        public float VisorTopRows = 0.09f;        // the rows the frame's top art occupies, as a share of the height
        public float VisorBottomRows = 0.0f;      // ...and the bottom art: 0 = left as it is (moving it corrupted the panel's edge)
        public float VisorWedge = 0.25f;          // the frame's corner wedge: this share of the game's width on each side
        int[] _cxiR, _cxfR;
        // The band rows' own column map: game columns 0..wedge land on the far left at the game's
        // scale, the last wedge on the far right, and the straight middle is stretched between.
        void BuildVisor(int pw, int ph)
        {
            _cxiR = new int[pw]; _cxfR = new int[pw];
            double s = (double)ViewRowsOf(ph) / _h, wedgePx = VisorWedge * _w * s;       // a wedge, in picture pixels
            double midGame0 = VisorWedge * _w, midGame1 = _w - VisorWedge * _w;
            double midPic0 = wedgePx, midPic1 = pw - wedgePx;
            for (int x = 0; x < pw; x++)
            {
                double px = x + 0.5, gx;
                if (px < midPic0) gx = px / s;
                else if (px >= midPic1) gx = _w - (pw - px) / s;
                else gx = midGame0 + (px - midPic0) / (midPic1 - midPic0) * (midGame1 - midGame0);
                double fx = gx - 0.5; if (fx < 0) fx = 0;
                int ix = (int)fx; if (ix > _w - 2) { ix = _w - 2; fx = _w - 1; }
                _cxiR[x] = ix; _cxfR[x] = (int)((fx - ix) * 256);
            }
        }

        // ---- THE PICTURE LEAVES THE FRAME LOOP HERE ------------------------------------------
        // Smoothing, sharpening and laying the game's drawings over the picture took 7-9 ms of
        // every frame on the one thread that also has to wait for the game, read the camera and
        // draw. None of it needs that thread. SubmitRgb takes the finished picture and returns
        // at once with another buffer to draw the next one into; a thread of the overlay's own
        // runs PostHook on it (the after-effects), composes, and hands it to the window.
        // If a picture is still waiting when the next arrives, the older one is dropped.
        public Func<int[], int, int, int[]> PostHook;
        public int LastShare = 1000; public long Submitted, Dropped; public double PipeMs;
        /// <summary>How many threads laying the game's drawings over the picture may use. It runs
        /// while the next picture is being drawn, so it is kept small on purpose.</summary>
        public int ComposeThreads = Environment.ProcessorCount;
        readonly object _subLock = new object(); readonly AutoResetEvent _subEvt = new AutoResetEvent(false);
        int[] _subBuf; int _subW, _subH, _subMin; bool _subPending; Thread _worker;
        readonly Stack<int[]> _pool = new Stack<int[]>();
        readonly object _presentLock = new object();

        /// <summary>Hand a picture to the pipeline (post-processing, then composing and showing it,
        /// all off the renderer's thread). The picture belongs to the overlay afterwards; the buffer
        /// returned is a spare of the same size to draw the next one into.</summary>
        public int[] SubmitRgb(int[] rgb, int pw, int ph, int minShare)
        {
            if (rgb == null || rgb.Length < pw * ph) throw new ArgumentException("picture size does not match its data");
            int[] spare = null;
            lock (_subLock)
            {
                if (_subPending) { spare = _subBuf; Dropped++; }
                _subBuf = rgb; _subW = pw; _subH = ph; _subMin = minShare; _subPending = true;
                while (spare == null && _pool.Count > 0) { var b = _pool.Pop(); if (b.Length == rgb.Length) spare = b; }
            }
            if (spare == null || spare.Length != rgb.Length) spare = new int[rgb.Length];
            if (_worker == null) { _worker = new Thread(WorkerLoop); _worker.IsBackground = true; _worker.Name = "AztOverlayPipe"; _worker.Start(); }
            Interlocked.Exchange(ref _lastPresentTicks, Stopwatch.GetTimestamp());
            Submitted++; _subEvt.Set();
            return spare;
        }

        void WorkerLoop()
        {
            while (_runReader)
            {
                _subEvt.WaitOne(4);
                int[] buf = null; int w = 0, h = 0, min = 0;
                lock (_subLock) { if (_subPending) { buf = _subBuf; _subBuf = null; _subPending = false; w = _subW; h = _subH; min = _subMin; } }
                if (buf == null) continue;
                var sw = Stopwatch.StartNew();
                int[] pic = buf; var hook = PostHook;
                if (hook != null) { try { pic = hook(buf, w, h) ?? buf; } catch { pic = buf; } }
                try { LastShare = Present(null, null, pic, w, h, min); } catch { LastShare = -1; }
                PipeMs = sw.Elapsed.TotalMilliseconds;
                // shown: the renderer can draw into this buffer again. It is the hook's OUTPUT
                // that is free -- PostJob keeps the buffer it was given as its next scratch, so
                // handing `buf` back would have two threads drawing into one picture.
                lock (_subLock) { if (_pool.Count < 4) _pool.Push(pic); }
            }
        }
        static int Mix4(int a, int b, int c, int d, uint wx, uint wy)
        {
            uint nx = 256 - wx, ny = 256 - wy, ua = (uint)a, ub = (uint)b, uc = (uint)c, ud = (uint)d;
            uint tRB = ((ua & 0xFF00FF) * nx + (ub & 0xFF00FF) * wx) >> 8 & 0xFF00FF, tG = ((ua & 0x00FF00) * nx + (ub & 0x00FF00) * wx) >> 8 & 0x00FF00;
            uint bRB = ((uc & 0xFF00FF) * nx + (ud & 0xFF00FF) * wx) >> 8 & 0xFF00FF, bG = ((uc & 0x00FF00) * nx + (ud & 0x00FF00) * wx) >> 8 & 0x00FF00;
            return (int)(((tRB * ny + bRB * wy) >> 8 & 0xFF00FF) | ((tG * ny + bG * wy) >> 8 & 0x00FF00));
        }
        /// <summary>Stamp a small palette-indexed strip into a true-colour picture.</summary>
        public static void StampPal(int[] dst, int dstW, byte[] strip, int sw, int sh, int x0, int y0, int[] pal32)
        {
            for (int y = 0; y < sh; y++) { int o = (y0 + y) * dstW + x0, s = y * sw; for (int x = 0; x < sw; x++) dst[o + x] = pal32[strip[s + x]]; }
        }
        // The buffers and the column map for a picture of this size (built again when it changes).
        void EnsureSize(int pw, int ph)
        {
            if (pw == _pw && ph == _ph) return;
            lock (_lock) { _back = new int[pw * ph]; _ready = new int[pw * ph]; _show = new int[pw * ph]; _pw = pw; _ph = ph; _pending = false; _copy = null; }
            // Which column of the game's 1600-wide view each picture column comes from. The
            // game's view keeps the picture's HEIGHT and sits in the middle: a picture wider
            // than 4:3 has columns either side that no game pixel covers (ix = -1), and those
            // show the picture alone.
            _cxi = new int[pw]; _cxf = new int[pw];
            double gw = (double)ViewRowsOf(ph) * _w / _h, gx0 = (pw - gw) / 2;
            for (int x = 0; x < pw; x++)
            {
                double fx = (x - gx0 + 0.5) * _w / gw - 0.5;
                if (x + 0.5 < gx0 || x + 0.5 > gx0 + gw) { _cxi[x] = -1; _cxf[x] = 0; continue; }
                if (fx < 0) fx = 0;
                int ix = (int)fx; if (ix > _w - 2) { ix = _w - 2; fx = _w - 1; }
                _cxi[x] = ix; _cxf[x] = (int)((fx - ix) * 256);
            }
            _riy = null;
        }

        // ---- COMPOSED ELSEWHERE: the graphics card lays the game's drawings over the picture ----
        // (GpuRaster.PostCompose). The overlay then only supplies the latest reading of the screen
        // and the maps Present would have used, and shows what comes back.
        int[] _riy, _rwy;
        /// <summary>The latest reading of the screen for composing elsewhere: the viewport's pixels
        /// (row r at r * stride), the key colour and its share (per thousand). Null with share -1
        /// if the screen cannot be read, 0 if there is no reading yet. Hides the window when the
        /// share is under minShare, exactly as Present does.</summary>
        public int[] TakeSurface(int minShare, out int key, out int share, out int stridePx)
        {
            key = 0; share = 0; stridePx = _stridePx;
            if (_vpAddr == 0) { share = -1; return null; }
            Interlocked.Exchange(ref _lastPresentTicks, Stopwatch.GetTimestamp());
            if (SyncRead && !ReadOnce()) { _want = false; share = -1; return null; }
            if (_consecFails >= 3) { _want = false; share = -1; return null; }
            lock (_presentLock)
            {
                lock (_surfLock)
                {
                    if (!_haveSurf) { _want = false; return null; }
                    if (_surfFresh) { var t = _surf; _surf = _surfLatest; _surfLatest = t; _key = _latestKey; _share = _latestShare; _surfFresh = false; }
                }
                key = _key; share = _share; LastKey = key; LastShare = share;
                if (share < minShare) { _want = false; return null; }
                return _surf;
            }
        }
        /// <summary>Everything Present uses to place the game's 1600x928 drawings on a picture of
        /// this size: per picture column its game column and 1/256 fraction (and the visor band's
        /// own pair), per picture row the same, and which rows are the visor band.</summary>
        public void ComposeMap(int pw, int ph, out int[] cxi, out int[] cxf, out int[] cxiR, out int[] cxfR, out int[] riy, out int[] rwy, out int bandTop, out int bandBot, out bool visor)
        {
            lock (_presentLock)
            {
                EnsureSize(pw, ph);
                visor = Wide && Visor && (pw != _w || ph != _h);
                if (visor && (_cxiR == null || _cxiR.Length != pw)) BuildVisor(pw, ph);
                if (_riy == null || _riy.Length != ph)
                {
                    _riy = new int[ph]; _rwy = new int[ph]; int gh = _h, vr = ViewRowsOf(ph);
                    for (int y = 0; y < ph; y++)
                    {
                        if (y >= vr) { _riy[y] = -1; _rwy[y] = 0; continue; }     // under the panel: the picture alone
                        double fy = (y + 0.5) * gh / vr - 0.5; if (fy < 0) fy = 0;
                        int iy = (int)fy; if (iy > gh - 2) { iy = gh - 2; fy = gh - 1; }
                        _riy[y] = iy; _rwy[y] = (int)((fy - iy) * 256);
                    }
                }
                cxi = _cxi; cxf = _cxf; cxiR = visor ? _cxiR : _cxi; cxfR = visor ? _cxfR : _cxf; riy = _riy; rwy = _rwy;
                int vrB = ViewRowsOf(ph); bandTop = (int)(vrB * VisorTopRows); bandBot = vrB - (int)(vrB * VisorBottomRows);
            }
        }
        // ---- THE BOOT, THROUGH THIS WINDOW (Josh, 2026-10-07: "load into the GPU rendered game right off the bat")
        // The visor boot is the game's own animation, written into the staging buffer it shares with the host.
        // Shown from there, it comes up in this window from its first frame -- no 8-bit picture, no switch, and
        // the calibration that follows it happens behind the held last frame. Laid where the game's view lies in
        // the picture (the compose's own maps), black at the sides and under the panel.
        byte[] _bootBuf; int[] _bootPic; int _bootW, _bootH;
        public long BootFrames;
        public bool ShowGuestFrame(long hostAddr, int fw, int fh, int[] pal32, int pw, int ph)
        {
            if (fw != _w || fh != _h || pal32 == null) return false;
            if (_bootBuf == null || _bootBuf.Length != fw * fh) _bootBuf = new byte[fw * fh];
            IntPtr got;
            if (!ReadProcessMemory(_proc, new IntPtr(hostAddr), _bootBuf, new IntPtr(fw * fh), out got) || got.ToInt64() != fw * fh) return false;
            int[] cxi, cxf, cxiR, cxfR, riy, rwy; int bt, bb; bool vis;
            ComposeMap(pw, ph, out cxi, out cxf, out cxiR, out cxfR, out riy, out rwy, out bt, out bb, out vis);
            if (_bootPic == null || _bootPic.Length != pw * ph) _bootPic = new int[pw * ph];
            var src = _bootBuf; var pic = _bootPic;
            Parallel.For(0, ph, y =>
            {
                int o = y * pw, iy = riy[y];
                if (iy < 0) { Array.Clear(pic, o, pw); return; }
                uint wy = (uint)rwy[y]; int r0 = iy * fw, r1 = Math.Min(fh - 1, iy + 1) * fw;
                for (int x = 0; x < pw; x++)
                {
                    int ix = cxi[x]; if (ix < 0) { pic[o + x] = 0; continue; }
                    int ix1 = Math.Min(fw - 1, ix + 1);
                    pic[o + x] = Mix4(pal32[src[r0 + ix]], pal32[src[r0 + ix1]], pal32[src[r1 + ix]], pal32[src[r1 + ix1]], (uint)cxf[x], wy);
                }
            });
            _bootW = pw; _bootH = ph; BootFrames++;
            ShowComposed((int[])pic.Clone(), pw, ph);
            return true;
        }
        /// <summary>Keep showing the last boot frame (while the display surface is being located).</summary>
        public bool HoldGuestFrame()
        {
            if (_bootPic == null) return false;
            ShowComposed((int[])_bootPic.Clone(), _bootW, _bootH);
            return true;
        }
        /// <summary>Show a picture finished elsewhere (pw x ph, 0x00RRGGBB). It belongs to the
        /// overlay afterwards; the buffer returned is a spare of the same size for the next one.</summary>
        public int[] ShowComposed(int[] pic, int pw, int ph)
        {
            if (pic == null || pic.Length < pw * ph) throw new ArgumentException("picture size does not match its data");
            int[] spare;
            lock (_presentLock)
            {
                EnsureSize(pw, ph);
                Decorated(pic, pw, ph);
                if (KeepCopy) { if (_copy == null || _copy.Length != pic.Length) _copy = new int[pic.Length]; Buffer.BlockCopy(pic, 0, _copy, 0, pic.Length * 4); }
                // _ready is never in use outside _lock (the window thread swaps it with _show there)
                lock (_lock) { spare = _ready; _ready = pic; _pending = true; }
                Interlocked.Exchange(ref _lastFrameTicks, Stopwatch.GetTimestamp());
                _want = true; Presented++;
            }
            _evt.Set();
            return (spare != null && spare.Length == pic.Length) ? spare : new int[pic.Length];
        }
        int Present(byte[] color8, int[] pal32, int[] rgb, int pw, int ph, int minShare)
        {
            lock (_presentLock) { return PresentLocked(color8, pal32, rgb, pw, ph, minShare); }
        }
        int PresentLocked(byte[] color8, int[] pal32, int[] rgb, int pw, int ph, int minShare)
        {
            if (_vpAddr == 0) return -1;
            if (pw < 16 || ph < 16 || (rgb != null ? rgb.Length : color8.Length) < pw * ph) throw new ArgumentException("picture size does not match its data");
            EnsureSize(pw, ph);
            Interlocked.Exchange(ref _lastPresentTicks, Stopwatch.GetTimestamp());
            if (SyncRead && !ReadOnce()) { _want = false; return -1; }
            if (_consecFails >= 3) { _want = false; return -1; }
            var sw = Stopwatch.StartNew();
            lock (_surfLock)
            {
                if (!_haveSurf) { _want = false; return 0; }     // no reading of the screen yet
                if (_surfFresh) { var t = _surf; _surf = _surfLatest; _surfLatest = t; _key = _latestKey; _share = _latestShare; _surfFresh = false; }
            }
            int key = _key, share = _share, key2 = KeyAlso >= 0 ? KeyAlso & 0xFFFFFF : key;
            LastKey = key;
            if (share < minShare) { _want = false; return share; }

            int[] surf = _surf, back = _back; int w = _w, st = _stridePx;
            if (pw != _w || ph != _h)
            {
                int gh = _h; int[] cxi = _cxi, cxf = _cxf;
                // THE VISOR FRAME, STRETCHED TO THE WIDE PICTURE. The game's own frame art is kept
                // exactly as it is -- only moved: in the rows it occupies (the top and bottom
                // bands) the game's view is laid across the FULL width with its two corner wedges
                // at the far corners of the screen and its straight middle stretched to span the
                // gap between them. Every other row is composed as usual, so the cursor, reticle
                // and text stay where the game put them.
                bool visor = Wide && Visor;
                if (visor && (_cxiR == null || _cxiR.Length != pw)) BuildVisor(pw, ph);
                int[] cxiR = _cxiR, cxfR = _cxfR;
                int vr = ViewRowsOf(ph);
                int bandTop = (int)(vr * VisorTopRows), bandBot = vr - (int)(vr * VisorBottomRows);
                Parallel.For(0, ph, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, ComposeThreads) }, y =>
                {
                    if (y >= vr) { int ob = y * pw; if (rgb != null) Buffer.BlockCopy(rgb, ob * 4, back, ob * 4, pw * 4); else for (int x = 0; x < pw; x++) back[ob + x] = pal32[color8[ob + x]]; return; }
                    double fy = (y + 0.5) * gh / vr - 0.5; if (fy < 0) fy = 0;
                    int iy = (int)fy; if (iy > gh - 2) { iy = gh - 2; fy = gh - 1; }
                    uint wy = (uint)((fy - iy) * 256); int r0 = iy * st, r1 = r0 + st, o = y * pw;
                    bool bandRow = visor && (y < bandTop || y >= bandBot);
                    int[] xi = bandRow ? cxiR : cxi, xf = bandRow ? cxfR : cxf;
                    int[] hr = HideRect; bool hideRow = hr != null && iy + 1 >= hr[1] && iy < hr[3];
                    int[] hr2 = HideRect2; bool hideRow2 = hr2 != null && iy + 1 >= hr2[1] && iy < hr2[3];
                    if (iy + 1 >= HideFromRow) { if (rgb != null) Buffer.BlockCopy(rgb, o * 4, back, o * 4, pw * 4); else for (int x = 0; x < pw; x++) back[o + x] = pal32[color8[o + x]]; return; }      // (+1: the row below is blended in too)
                    for (int x = 0; x < pw; x++)
                    {
                        int ix = xi[x];
                        int pic = rgb != null ? rgb[o + x] : pal32[color8[o + x]];
                        if (ix < 0) { back[o + x] = pic; continue; }           // beyond the game's own picture
                        if (hideRow && ix + 1 >= hr[0] && ix < hr[2]) { back[o + x] = pic; continue; }   // the host's panel draws here
                        if (hideRow2 && ix + 1 >= hr2[0] && ix < hr2[2]) { back[o + x] = pic; continue; }
                        int a = surf[r0 + ix] & 0xFFFFFF, b = surf[r0 + ix + 1] & 0xFFFFFF, c = surf[r1 + ix] & 0xFFFFFF, d = surf[r1 + ix + 1] & 0xFFFFFF;
                        bool ka = a == key || a == key2, kb = b == key || b == key2, kc = c == key || c == key2, kd = d == key || d == key2;
                        if (ka && kb && kc && kd) { back[o + x] = pic; continue; }
                        back[o + x] = Mix4(ka ? pic : a, kb ? pic : b, kc ? pic : c, kd ? pic : d, (uint)xf[x], wy);
                    }
                });
            }
            else
            Parallel.For(0, _h, y =>
            {
                int r = y * st, o = y * w;
                if (rgb != null)
                    for (int x = 0; x < w; x++)
                    {
                        int s = surf[r + x] & 0xFFFFFF;
                        back[o + x] = (s == key || s == key2) ? rgb[o + x] : s;
                    }
                else
                    for (int x = 0; x < w; x++)
                    {
                        int s = surf[r + x] & 0xFFFFFF;
                        back[o + x] = (s == key || s == key2) ? pal32[color8[o + x]] : s;
                    }
            });
            Decorated(back, pw, ph);
            if (KeepCopy) { if (_copy == null) _copy = new int[back.Length]; Buffer.BlockCopy(back, 0, _copy, 0, back.Length * 4); }
            lock (_lock) { var t = _back; _back = _ready; _ready = t; _pending = true; }
            Interlocked.Exchange(ref _lastFrameTicks, Stopwatch.GetTimestamp());
            _want = true; Presented++;
            ComposeMs = sw.Elapsed.TotalMilliseconds;
            _evt.Set();
            return share;
        }

        // ---- DRAWN OVER EVERY FINISHED PICTURE, last thing before it is shown -------------------
        // (BootHd's shutter and calibration, laid over the host's first frames of 3D.) Returns
        // whether it drew; a failure in it never costs the frame.
        public Func<int[], int, int, bool> Decorate;
        /// <summary>A second one, drawn after the first: the scanner's wireframe (ScanWire.cs).</summary>
        public Func<int[], int, int, bool> Decorate2;
        /// <summary>A third, after the scanner: a visor readout (ScanWire.cs, VisorNote).</summary>
        public Func<int[], int, int, bool> Decorate3;
        /// <summary>A fourth: the visor's memory core, the save/load screen (ScanWire.cs, VisorMenu).</summary>
        public Func<int[], int, int, bool> Decorate4;
        void Decorated(int[] pic, int pw, int ph)
        {
            var d = Decorate; if (d != null) try { d(pic, pw, ph); } catch { }
            var d2 = Decorate2; if (d2 != null) try { d2(pic, pw, ph); } catch { }
            var d3 = Decorate3; if (d3 != null) try { d3(pic, pw, ph); } catch { }
            var d4 = Decorate4; if (d4 != null) try { d4(pic, pw, ph); } catch { }
        }
        /// <summary>The composed frame most recently handed over, for saving to a file.</summary>
        public int[] LastFrame() { return _copy; }
        /// <summary>Keep a copy of each composed frame (the buffers themselves rotate through the window thread).</summary>
        public bool KeepCopy;
        int[] _copy;
    }
}
