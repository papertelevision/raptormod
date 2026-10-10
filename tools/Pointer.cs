// Pointer.cs -- THE POINTER ACROSS THE WHOLE DISPLAY (Josh, 2026-10-07; true colour / GPU only).
//
// The game's mouse lives inside its own 1600x1200 screen: the driver's range is that screen, the
// game draws the cursor into it, and every hit test reads its two cursor words. On a widescreen
// display the host paints well past those 1600 columns, so the pointer could not follow the art.
//
// This takes the pointer over while the game shows it (mouselook off), with NO game code:
//   * the game's own "pointer hidden" flag (0x147586) is held set. The mouse callback then neither
//     writes the cursor words nor draws the cursor -- and the host owns both;
//   * the pointer moves with the DRIVER's motion (the callback still saves the driver's position,
//     0x182D68 / 0x182D64), so it feels exactly as before -- and where the driver is pinned at the
//     edge of its range, raw mouse input (Windows Raw Input, which sees every count) carries it on,
//     scaled by the driver's own counts-to-pixels ratio, measured as you move;
//   * the game is handed the position it should see (Map: the panel's halves sit apart at the
//     display's edges, so a click on the art becomes a click on the game's own layout), and that is
//     what a click is stamped with -- the callback stamps the cursor words before it would have
//     written them;
//   * the cursor is drawn here, in a small window of its own: the game's CURRENT cursor image
//     (0x147588 -> a game surface; hotspot 0x14758E / 0x147590), so TAKE / USE / a held item all show.
// Mouselook on: hands off (the game hides the pointer itself and looks with mickeys).
// Dispose clears the flag, so the game's own pointer comes back. If the host dies outright, the
// right mouse button (into mouselook and out) clears it too.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace AztTool
{
    public class Pointer : IDisposable
    {
        // ---- Win32 ---------------------------------------------------------------------------
        delegate IntPtr WndProcD(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WNDCLASSEX { public int cbSize; public int style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint msg; public IntPtr w, l; public uint time; public POINT pt; }
        [StructLayout(LayoutKind.Sequential)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER { public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort usUsagePage, usUsage; public uint dwFlags; public IntPtr hwndTarget; }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClassExW(ref WNDCLASSEX c);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool UnregisterClassW(string name, IntPtr inst);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateWindowExW(int ex, string cls, string title, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern bool PeekMessageW(out MSG m, IntPtr h, uint lo, uint hi, uint remove);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dstDc, ref POINT dst, ref SIZE size, IntPtr srcDc, ref POINT src, uint key, ref BLENDFUNCTION blend, uint flags);
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devs, uint n, uint size);
        [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr hRaw, uint cmd, IntPtr data, ref uint size, uint headerSize);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, [Out] byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
        [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
        [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);

        const int WS_POPUP = unchecked((int)0x80000000);
        const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
        const uint SWP_NOACTIVATE = 0x10, SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2;
        const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4;
        const uint WM_NCHITTEST = 0x84, WM_INPUT = 0xFF, ULW_ALPHA = 2, RIDEV_INPUTSINK = 0x100, RID_INPUT = 0x10000003;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

        // ---- the game (host addresses, set before Start) ----------------------------------------
        /// <summary>word: the game's "pointer hidden" flag; word: mouselook on; two words: the cursor;
        /// dwords: the driver's x and y as the callback last saw them; dword: the cursor image (a game
        /// surface pointer); two words: its hotspot. MemBase turns a guest pointer into a host address.</summary>
        public long HiddenAddr, MouselookAddr, CursorAddr, DrvXAddr, DrvYAddr, CurSurfAddr, HotAddr, MemBase;
        /// <summary>The game's palette as DOSBox shows it (0xRRGGBB); index 0 of the cursor is see-through.</summary>
        public int[] Palette;
        /// <summary>Where the game's screen is on the display and how big the display is: given by the panel,
        /// which places itself on the game's window. Returns false when it is not placed.</summary>
        public Func<double[], bool> Placement;      // fills { s, ox, oy, clientLeft, clientTop, clientW, clientH }
        /// <summary>Display position (game px, may lie outside 0..1599) -> the position the game should see.</summary>
        public Func<double, double, double[]> Map;
        /// <summary>The driver's range the game set (its own screen): where the driver pins.</summary>
        public int DrvMinX = 0, DrvMaxX = 1599, DrvMinY = 0, DrvMaxY = 1199;

        // ---- state, for the report ----------------------------------------------------------------
        public volatile bool Active; public double DispX = 800, DispY = 600, GameX, GameY, Ratio = 1.0;
        public long RawCounts, DriverMoves, RawMoves, Writes, ReadFails, Takeovers, Images;
        public string StartError = "";

        readonly int _pid; readonly IntPtr _proc;
        Thread _thread; volatile bool _run; WndProcD _wndProc; IntPtr _hwnd; string _cls;
        readonly ManualResetEvent _up = new ManualResetEvent(false);

        public Pointer(int pid)
        {
            _pid = pid;
            _proc = OpenProcess(0x0438, false, pid);
            if (_proc == IntPtr.Zero) throw new InvalidOperationException("OpenProcess failed: " + Marshal.GetLastWin32Error());
        }
        public bool Start()
        {
            _run = true;
            _thread = new Thread(Loop); _thread.IsBackground = true; _thread.Name = "AztPointer"; _thread.Start();
            _up.WaitOne(3000);
            return _hwnd != IntPtr.Zero;
        }
        public void Dispose()
        {
            _run = false;
            if (_thread != null) { _thread.Join(1500); _thread = null; }
            if (_proc != IntPtr.Zero) CloseHandle(_proc);
        }

        // ---- memory --------------------------------------------------------------------------------
        byte[] _b2 = new byte[2], _b4 = new byte[4];
        int RdW(long a) { IntPtr got; if (a == 0 || !ReadProcessMemory(_proc, new IntPtr(a), _b2, new IntPtr(2), out got)) { ReadFails++; return 0; } return BitConverter.ToInt16(_b2, 0); }
        int RdD(long a) { IntPtr got; if (a == 0 || !ReadProcessMemory(_proc, new IntPtr(a), _b4, new IntPtr(4), out got)) { ReadFails++; return 0; } return BitConverter.ToInt32(_b4, 0); }
        void WrW(long a, int v) { if (a == 0) return; IntPtr wr; WriteProcessMemory(_proc, new IntPtr(a), new[] { (byte)v, (byte)(v >> 8) }, new IntPtr(2), out wr); }
        void WrXY(long a, int x, int y) { if (a == 0) return; IntPtr wr; WriteProcessMemory(_proc, new IntPtr(a), new[] { (byte)x, (byte)(x >> 8), (byte)y, (byte)(y >> 8) }, new IntPtr(4), out wr); Writes++; }
        byte[] Rd(long a, int n) { var b = new byte[n]; IntPtr got; if (!ReadProcessMemory(_proc, new IntPtr(a), b, new IntPtr(n), out got) || got.ToInt64() != n) return null; return b; }

        // ---- raw input -------------------------------------------------------------------------------
        int _rawX, _rawY;
        IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            if (msg == WM_NCHITTEST) return new IntPtr(-1);
            if (msg == WM_INPUT)
            {
                uint size = 0, hdr = (uint)(IntPtr.Size == 8 ? 24 : 16);
                GetRawInputData(l, RID_INPUT, IntPtr.Zero, ref size, hdr);
                if (size > 0 && size < 256)
                {
                    IntPtr buf = Marshal.AllocHGlobal((int)size);
                    try
                    {
                        if (GetRawInputData(l, RID_INPUT, buf, ref size, hdr) == size && Marshal.ReadInt32(buf, 0) == 0)   // RIM_TYPEMOUSE
                        {
                            int o = (int)hdr; ushort flags = (ushort)Marshal.ReadInt16(buf, o);
                            if ((flags & 1) == 0)                                                                  // relative motion
                            { _rawX += Marshal.ReadInt32(buf, o + 12); _rawY += Marshal.ReadInt32(buf, o + 16); }
                        }
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
            }
            return DefWindowProcW(h, msg, w, l);
        }

        // ---- the cursor's own window ---------------------------------------------------------------------
        IntPtr _memDc, _dib, _oldBmp, _bits; int _cw, _ch; bool _shown;
        int[] _img; int _iw, _ih, _hotX, _hotY; uint _imgPtr; long _imgSum; double _imgS;
        Stopwatch _imgClock = Stopwatch.StartNew();
        // the game's current cursor image, as 0xAARRGGBB premultiplied, re-read when it changes
        bool ReadImage()
        {
            uint p = (uint)RdD(CurSurfAddr); if (p < 0x1000) return false;
            // (the game's surface, as its blitter 0x37D98 reads it: word width, word height, dword pixels, rows packed at the width)
            var sd = Rd(MemBase + p, 8); if (sd == null) return false;
            int w = BitConverter.ToUInt16(sd, 0), h = BitConverter.ToUInt16(sd, 2), bpl = w; uint px = BitConverter.ToUInt32(sd, 4);
            if (w <= 0 || h <= 0 || w > 256 || h > 256 || bpl < w || px < 0x1000) return false;
            var raw = Rd(MemBase + px, bpl * (h - 1) + w); if (raw == null) return false;
            long sum = p * 31L + w * 7 + h; for (int i = 0; i < raw.Length; i += 3) sum = sum * 131 + raw[i];
            int hx = RdW(HotAddr), hy = RdW(HotAddr + 2);
            if (p == _imgPtr && sum == _imgSum && hx == _hotX && hy == _hotY && _img != null) return true;
            var img = new int[w * h];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int v = raw[y * bpl + x]; img[y * w + x] = v == 0 ? 0 : unchecked((int)0xFF000000) | (Palette != null ? Palette[v] & 0xFFFFFF : v * 0x010101); }
            _img = img; _iw = w; _ih = h; _hotX = hx; _hotY = hy; _imgPtr = p; _imgSum = sum; _imgS = 0; Images++;
            return true;
        }
        // the image at the display's scale (bilinear, premultiplied), into the window's bitmap
        void Build(double s)
        {
            int dw = Math.Max(1, (int)Math.Ceiling(_iw * s)), dh = Math.Max(1, (int)Math.Ceiling(_ih * s));
            if (dw != _cw || dh != _ch || _dib == IntPtr.Zero)
            {
                FreeDib(); IntPtr sdc = GetDC(IntPtr.Zero); _memDc = CreateCompatibleDC(sdc); ReleaseDC(IntPtr.Zero, sdc);
                var bi = new BITMAPINFOHEADER(); bi.biSize = 40; bi.biWidth = dw; bi.biHeight = -dh; bi.biPlanes = 1; bi.biBitCount = 32;
                _dib = CreateDIBSection(_memDc, ref bi, 0, out _bits, IntPtr.Zero, 0); _oldBmp = SelectObject(_memDc, _dib); _cw = dw; _ch = dh;
            }
            var o = new int[dw * dh];
            for (int y = 0; y < dh; y++)
            {
                double fy = (y + 0.5) / s - 0.5; int iy = (int)Math.Floor(fy); double wy = fy - iy;
                for (int x = 0; x < dw; x++)
                {
                    double fx = (x + 0.5) / s - 0.5; int ix = (int)Math.Floor(fx); double wx = fx - ix;
                    double a = 0, r = 0, g = 0, b = 0;
                    for (int k = 0; k < 4; k++)
                    {
                        int sx = ix + (k & 1), sy = iy + (k >> 1); if (sx < 0 || sy < 0 || sx >= _iw || sy >= _ih) continue;
                        int c = _img[sy * _iw + sx]; if (c == 0) continue;
                        double wgt = ((k & 1) != 0 ? wx : 1 - wx) * ((k >> 1) != 0 ? wy : 1 - wy);
                        a += wgt; r += wgt * ((c >> 16) & 255); g += wgt * ((c >> 8) & 255); b += wgt * (c & 255);
                    }
                    if (a <= 0) continue;
                    int A = (int)Math.Min(255, a * 255 + 0.5);
                    o[y * dw + x] = (A << 24) | ((int)Math.Min(255, r) << 16) | ((int)Math.Min(255, g) << 8) | (int)Math.Min(255, b);   // r..b are already weighted: premultiplied
                }
            }
            Marshal.Copy(o, 0, _bits, o.Length); _imgS = s;
        }
        void FreeDib()
        {
            if (_memDc != IntPtr.Zero) { SelectObject(_memDc, _oldBmp); DeleteDC(_memDc); _memDc = IntPtr.Zero; }
            if (_dib != IntPtr.Zero) { DeleteObject(_dib); _dib = IntPtr.Zero; }
        }
        void ShowAt(int x, int y)
        {
            IntPtr sdc = GetDC(IntPtr.Zero);
            var pos = new POINT { x = x, y = y }; var size = new SIZE { cx = _cw, cy = _ch }; var src = new POINT();
            var bl = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
            UpdateLayeredWindow(_hwnd, sdc, ref pos, ref size, _memDc, ref src, 0, ref bl, ULW_ALPHA);
            ReleaseDC(IntPtr.Zero, sdc);
            if (!_shown) { ShowWindow(_hwnd, SW_SHOWNOACTIVATE); _shown = true; }
        }
        void HideCursor() { if (_shown) { ShowWindow(_hwnd, SW_HIDE); _shown = false; } }

        // ---- the loop, about a thousand times a second -----------------------------------------------
        void Loop()
        {
            try
            {
                try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
                _wndProc = WndProc; _cls = "AztPointer" + Stopwatch.GetTimestamp();
                var wc = new WNDCLASSEX(); wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX)); wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
                wc.hInstance = GetModuleHandleW(IntPtr.Zero); wc.lpszClassName = _cls;
                if (RegisterClassExW(ref wc) == 0) { StartError = "RegisterClassEx failed: " + Marshal.GetLastWin32Error(); return; }
                _hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, _cls, "", WS_POPUP, 0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_hwnd == IntPtr.Zero) { StartError = "CreateWindowEx failed: " + Marshal.GetLastWin32Error(); return; }
                var rid = new[] { new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 2, dwFlags = RIDEV_INPUTSINK, hwndTarget = _hwnd } };
                if (!RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) StartError = "raw input not registered: " + Marshal.GetLastWin32Error();
            }
            finally { _up.Set(); }
            timeBeginPeriod(1);
            var place = new double[7]; bool had = false; int lastDx = 0, lastDy = 0; double sDrv = 0, sRaw = 0; int raiseTick = 0;
            try
            {
                while (_run)
                {
                    MSG m; while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
                    int rx = _rawX, ry = _rawY; _rawX = 0; _rawY = 0; RawCounts += Math.Abs(rx) + Math.Abs(ry);
                    try
                    {
                        bool placed = Placement != null && Placement(place);
                        bool look = RdW(MouselookAddr) != 0;
                        int dx = RdD(DrvXAddr), dy = RdD(DrvYAddr);
                        if (!placed || look)
                        {
                            // hands off: the game looks with mickeys and hides its own pointer
                            if (Active) { Active = false; }
                            HideCursor(); had = false; lastDx = dx; lastDy = dy;
                        }
                        else
                        {
                            if (!Active)
                            {
                                // taking over: start where the game's cursor is
                                DispX = (short)RdW(CursorAddr); DispY = (short)RdW(CursorAddr + 2);
                                Active = true; Takeovers++; lastDx = dx; lastDy = dy; had = true;
                            }
                            if (RdW(HiddenAddr) == 0) WrW(HiddenAddr, 1);      // the game neither moves nor draws its pointer
                            // the driver's motion, as DOSBox gives it; raw input only where the driver is pinned
                            int ddx = dx - lastDx, ddy = dy - lastDy; lastDx = dx; lastDy = dy;
                            if (ddx != 0 && rx != 0 && Math.Sign(ddx) == Math.Sign(rx) && dx > DrvMinX && dx < DrvMaxX)
                            { sDrv = sDrv * 0.98 + Math.Abs(ddx); sRaw = sRaw * 0.98 + Math.Abs(rx); if (sRaw > 20) Ratio = Math.Max(0.05, Math.Min(20, sDrv / sRaw)); }
                            double mx = ddx, my = ddy;
                            if (ddx != 0) DriverMoves++;
                            if (ddx == 0 && rx != 0 && ((rx > 0 && dx >= DrvMaxX) || (rx < 0 && dx <= DrvMinX)) || ddx == 0 && rx != 0 && (DispX < 0 || DispX > ScreenW - 1)) { mx = rx * Ratio; RawMoves++; }
                            if (ddy == 0 && ry != 0 && ((ry > 0 && dy >= DrvMaxY) || (ry < 0 && dy <= DrvMinY))) my = 0;   // the screen's top and bottom ARE the display's
                            double xl = (place[3] - place[1]) / place[0], xr = (place[3] + place[5] - place[1]) / place[0];
                            DispX = Math.Max(xl, Math.Min(xr - 1, DispX + mx)); DispY = Math.Max(0, Math.Min(ScreenH - 1, DispY + my));
                            double[] g = Map != null ? Map(DispX, DispY) : new[] { Math.Max(0, Math.Min(ScreenW - 1, DispX)), DispY };
                            int gx = (int)Math.Round(g[0]), gy = (int)Math.Round(g[1]);
                            if (gx != (int)GameX || gy != (int)GameY || !had) { WrXY(CursorAddr, gx, gy); had = true; }
                            GameX = gx; GameY = gy;
                            // the cursor, drawn at the display position
                            if (_imgClock.ElapsedMilliseconds >= 30 || _img == null) { _imgClock.Restart(); if (ReadImage() && Math.Abs(_imgS - place[0]) > 1e-6) Build(place[0]); }
                            if (_img != null && _dib != IntPtr.Zero)
                            {
                                if (Math.Abs(_imgS - place[0]) > 1e-6) Build(place[0]);
                                ShowAt((int)Math.Round(place[1] + (DispX - _hotX) * place[0]), (int)Math.Round(place[2] + (DispY - _hotY) * place[0]));
                                if (++raiseTick >= 250) { raiseTick = 0; SetWindowPos(_hwnd, Overlay.TopSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); }
                            }
                        }
                    }
                    catch (Exception e) { StartError = e.GetType().Name + ": " + e.Message; }
                    Thread.Sleep(1);
                }
            }
            finally
            {
                timeEndPeriod(1);
                if (Active) { WrW(HiddenAddr, 0); Active = false; }      // the game's own pointer comes back
                HideCursor(); FreeDib(); DestroyWindow(_hwnd); _hwnd = IntPtr.Zero; UnregisterClassW(_cls, GetModuleHandleW(IntPtr.Zero));
            }
        }
        const int ScreenW = 1600, ScreenH = 1200;
    }
}
