// CursorIcons.cs -- THE GAME'S CURSORS AS ANIMATED VECTORS (Josh, 2026-10-11; true colour only).
//
// "The game uses the icons I've attached for interacting with the environment. I want you to recreate these icons in
// animated vectors, similar in style to the chalice vector and the icons you've created in the game menu ... the arrows to
// open/close doors will subtly animate forward or backward. The 'pick up' icon, which looks like a wrench head, will
// animate up and down. Spinning pinwheel icon will spin a revolution on hover, etc."
//
// The game shows one of 30 cursor bitmaps: 0x2A2EA loads mice\<name>.pcx (its name table at 0x14714A) for slot i into a
// 30 x 30 surface at 0x164B80 + i * 18 (word w, word h, dword pixels); dword 0x147588 points at the one in use and words
// 0x14758E / 0x147590 hold its hot spot. The game draws it into its own screen (0x3544D) -- hover and picking stay its
// own, from the cursor words 0x182D6C / 0x182D6E.
//   * Here the same shapes are traced from the bitmaps into lines in their own 30 x 30 grid (pixel centres at n + 0.5) and
//     drawn in the visor's style -- a dark rim, a soft glow, a crisp core and a hot centre line; amber for the normal set,
//     teal for the "B" set (the chalice's colours), red-amber for ACTIVE -- in a small click-through window of its own at
//     the game's cursor, each with its own subtle animation.
//   * The game's bitmaps are BLANKED in its memory while this draws (index 0 is see-through): a data write, no code -- its
//     cursor logic is untouched, unlike the "pointer hidden" flag, which stopped hover and picking (azrael-host-pointer).
//     They are put back on Dispose, and whenever this cannot draw (not placed for a second).
//   * A cursor that is not one of the 30 (a held item's picture; 0x15210C, the game's own 30 x 30 cursor for combat and
//     close-ups) is left to the game, as it always was.
//   * Overlay.GameCursorBlank tells the panel when the game draws no cursor, so it stops keeping the screen under the
//     pointer apart (with nothing to tell apart, it kept the OLD text there -- a new options list looked unchanged).
//   * The game's "pointer hidden" word is raised by every blit for a moment: only a lasting one hides this (HiddenHoldMs).
// The other host windows go just below this one (Overlay.TopSlot), so the panel and the picture never cover it.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Threading;

namespace AztTool
{
    public class IconCursor : IDisposable
    {
        // ---- Win32 (as Pointer.cs) ----------------------------------------------------------------
        delegate IntPtr WndProcD(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WNDCLASSEX { public int cbSize; public int style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint msg; public IntPtr w, l; public uint time; public POINT pt; }
        [StructLayout(LayoutKind.Sequential)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER { public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
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
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
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
        const uint SWP_NOACTIVATE = 0x10, SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, ULW_ALPHA = 2;

        // ---- THE 30 CURSORS, in the game's order (0x14714A's names: mice\pointer.pcx, mice\active.pcx, ...) ----------------
        public static readonly string[] SlotNames = { "pointer", "active", "look", "blook", "up", "bup", "pull", "bpull", "use", "buse", "rot", "brot",
                                                      "use", "buse", "take", "btake", "push", "bpush", "pull", "bpull", "use", "buse", "down", "bdown",
                                                      "scan", "left", "right", "downarrw", "default", "bdefault" };
        public const int Slots = 30, SlotBytes = 18;

        // ---- the game (host addresses, set before Start) ------------------------------------------------------------
        /// <summary>Host addresses: the cursor words (x, y), the cursor-image dword, the hot-spot words, the "pointer hidden" and
        /// mouselook words, slot 0's surface; TableGuest = slot 0's guest address (what the cursor-image dword holds for it).
        /// MemBase turns a guest pointer into a host address.</summary>
        public long MemBase, CursorAddr, CurSurfAddr, HotAddr, HiddenAddr, MouselookAddr, TableAddr; public uint TableGuest;
        public int GamePid;
        /// <summary>Where the game's screen is on the display (the panel's GetPlacement): { screen px per game px, origin x, y, ... }.</summary>
        public Func<double[], bool> Placement;
        /// <summary>Placement from another object's `bool name(double[])` (the panel's GetPlacement) -- PowerShell 5 cannot make the
        /// delegate itself, and this file does not reference the panel's.</summary>
        public void PlaceBy(object o, string name) { Placement = (Func<double[], bool>)Delegate.CreateDelegate(typeof(Func<double[], bool>), o, name); }
        /// <summary>Size against the game's own bitmap (1 = the same).</summary>
        public double Scale = 1.0;
        /// <summary>Diagnostics: leave the game's bitmaps as they are (both are then seen).</summary>
        public bool KeepBitmaps;
        /// <summary>THE "POINTER HIDDEN" WORD (0x147586) only counts once it has stayed up this long. Every one of the game's
        /// blits raises it while it draws (0x33F80, 0x3439C, 0x34818, 0x34C40 and 0x350CC save it, set 1, put it back), so it
        /// is up for a few ms of most frames; taken at its word the cursor hid and came back ~30 times a second (Josh's first
        /// session: "flickering, and very faint" -- every return restarted the fade-in).</summary>
        public int HiddenHoldMs = 150;
        /// <summary>Hidden for longer than this: the cursor comes back with its appearing animation; shorter, it carries on.</summary>
        public int AppearAfterMs = 400;
        /// <summary>The fade-in when a cursor comes up from nothing (s).</summary>
        public const double FadeIn = CursorShapes.FadeIn;
        // ---- for the report --------------------------------------------------------------------------------------------
        public volatile string Shape = ""; public long Renders, Shown, Blanked, Restored, ReadFails, NotOurs, HideFlagBlips, HideFlagHolds; public string StartError = "";

        readonly IntPtr _proc;
        Thread _thread; volatile bool _run; WndProcD _wndProc; IntPtr _hwnd; string _cls;
        readonly ManualResetEvent _up = new ManualResetEvent(false);

        public IconCursor(int pid)
        {
            _proc = OpenProcess(0x0438, false, pid);      // (read, write, operation, query)
            if (_proc == IntPtr.Zero) throw new InvalidOperationException("OpenProcess failed: " + Marshal.GetLastWin32Error());
        }
        public bool Start()
        {
            _run = true;
            _thread = new Thread(Loop); _thread.IsBackground = true; _thread.Name = "AztIconCursor"; _thread.Start();
            _up.WaitOne(3000);
            return _hwnd != IntPtr.Zero;
        }
        public void Dispose()
        {
            _run = false;
            if (_thread != null) { _thread.Join(1500); _thread = null; }
            Overlay.GameCursorBlank = false;
            try { RestoreAll(); } catch { }       // (again, in case the loop never ran to its end)
            if (_proc != IntPtr.Zero) CloseHandle(_proc);
        }

        // ---- memory --------------------------------------------------------------------------------------------------
        byte[] _b2 = new byte[2], _b4 = new byte[4];
        int RdW(long a) { IntPtr got; if (a == 0 || !ReadProcessMemory(_proc, new IntPtr(a), _b2, new IntPtr(2), out got)) { ReadFails++; return 0; } return BitConverter.ToInt16(_b2, 0); }
        uint RdD(long a) { IntPtr got; if (a == 0 || !ReadProcessMemory(_proc, new IntPtr(a), _b4, new IntPtr(4), out got)) { ReadFails++; return 0; } return BitConverter.ToUInt32(_b4, 0); }
        byte[] Rd(long a, int n) { var b = new byte[n]; IntPtr got; if (a == 0 || !ReadProcessMemory(_proc, new IntPtr(a), b, new IntPtr(n), out got) || got.ToInt64() != n) return null; return b; }
        bool Wr(long a, byte[] b) { IntPtr wr; return a != 0 && WriteProcessMemory(_proc, new IntPtr(a), b, new IntPtr(b.Length), out wr) && wr.ToInt64() == b.Length; }

        /// <summary>The slot of the cursor in use, or -1 (not one of the 30: the game draws it itself).</summary>
        int Slot()
        {
            long d = (long)RdD(CurSurfAddr) - TableGuest;
            if (d < 0 || d % SlotBytes != 0) return -1;
            long i = d / SlotBytes; return i < Slots ? (int)i : -1;
        }
        // THE GAME'S BITMAPS, blanked while this draws (kept, put back after)
        readonly byte[][] _orig = new byte[Slots][]; readonly uint[] _origPx = new uint[Slots]; bool _anyBlanked;
        void BlankAll()
        {
            for (int i = 0; i < Slots; i++)
            {
                var sd = Rd(TableAddr + i * SlotBytes, 8); if (sd == null) continue;
                int w = BitConverter.ToUInt16(sd, 0), h = BitConverter.ToUInt16(sd, 2); uint px = BitConverter.ToUInt32(sd, 4);
                if (w <= 0 || h <= 0 || w > 64 || h > 64 || px < 0x1000) continue;
                int n = w * h; var cur = Rd(MemBase + px, n); if (cur == null) continue;
                bool blank = true; foreach (byte b in cur) if (b != 0) { blank = false; break; }
                if (blank) continue;                                         // (ours already -- or a bitmap with nothing in it)
                _orig[i] = cur; _origPx[i] = px;                             // (the game's own picture -- loaded afresh if it was reloaded)
                if (Wr(MemBase + px, new byte[n])) { Blanked++; _anyBlanked = true; }
            }
        }
        void RestoreAll()
        {
            if (!_anyBlanked) return;
            for (int i = 0; i < Slots; i++)
            {
                if (_orig[i] == null) continue;
                var sd = Rd(TableAddr + i * SlotBytes, 8);
                if (sd != null && BitConverter.ToUInt32(sd, 4) == _origPx[i] && Wr(MemBase + _origPx[i], _orig[i])) Restored++;
                _orig[i] = null;
            }
            _anyBlanked = false;
        }
        // (offline tests: the same reads and writes on a fake guest)
        public int TestSlot() { return Slot(); }
        public void TestBlank() { BlankAll(); }
        public void TestRestore() { RestoreAll(); }
        static readonly uint _ownPid = (uint)Process.GetCurrentProcess().Id;     // (once: GetCurrentProcess made a finalizable object every pass -- 2026-10-13 audit)
        bool Front()
        {
            uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p);
            return GamePid == 0 || p == (uint)GamePid || p == _ownPid;
        }

        /// <summary>Redrawn this often while up (ms): every icon loops now, so all of them keep moving.</summary>
        public int RedrawMs = 16;       // (60 a second; it was 8 -- the 2026-10-13 audit: the position still follows every pass)

        static double C01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
        /// <summary>The icon drawing lives in CursorShapes.cs (shared with the title screen's RAPTOR DOCS).</summary>
        public static void Draw(Graphics g, string name, float x0, float y0, float u, double ta, double t) { CursorShapes.Draw(g, name, x0, y0, u, ta, t); }
        public static void Draw(Graphics g, string name, float x0, float y0, float u, double ta, double t, double fade) { CursorShapes.Draw(g, name, x0, y0, u, ta, t, fade); }
        public static Bitmap Preview(string name, double ta, int size, int bg) { return CursorShapes.Preview(name, ta, size, bg); }

        // ---- the window --------------------------------------------------------------------------------------------------
        IntPtr _memDc, _dib, _oldBmp, _bits; int _n; bool _shown;
        IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l) { if (msg == 0x84) return new IntPtr(-1); return DefWindowProcW(h, msg, w, l); }
        void EnsureDib(int n)
        {
            if (n == _n && _dib != IntPtr.Zero) return;
            FreeDib(); IntPtr sdc = GetDC(IntPtr.Zero); _memDc = CreateCompatibleDC(sdc); ReleaseDC(IntPtr.Zero, sdc);
            var bi = new BITMAPINFOHEADER(); bi.biSize = 40; bi.biWidth = n; bi.biHeight = -n; bi.biPlanes = 1; bi.biBitCount = 32;
            _dib = CreateDIBSection(_memDc, ref bi, 0, out _bits, IntPtr.Zero, 0); _oldBmp = SelectObject(_memDc, _dib); _n = n;
        }
        void FreeDib()
        {
            if (_memDc != IntPtr.Zero) { SelectObject(_memDc, _oldBmp); DeleteDC(_memDc); _memDc = IntPtr.Zero; }
            if (_dib != IntPtr.Zero) { DeleteObject(_dib); _dib = IntPtr.Zero; }
        }
        void Render(string name, float margin, float u, double ta, double t, double fade)
        {
            using (var bm = new Bitmap(_n, _n, _n * 4, PixelFormat.Format32bppPArgb, _bits))
            using (var g = Graphics.FromImage(bm)) { g.Clear(Color.Transparent); Draw(g, name, margin, margin, u, ta, t, fade); }
            Renders++;
        }
        void ShowAt(int x, int y)
        {
            IntPtr sdc = GetDC(IntPtr.Zero);
            var pos = new POINT { x = x, y = y }; var size = new SIZE { cx = _n, cy = _n }; var src = new POINT();
            var bl = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
            UpdateLayeredWindow(_hwnd, sdc, ref pos, ref size, _memDc, ref src, 0, ref bl, ULW_ALPHA);
            ReleaseDC(IntPtr.Zero, sdc);
            if (!_shown) { ShowWindow(_hwnd, 4); SetWindowPos(_hwnd, Overlay.CoverSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); _shown = true; Shown++; }
        }
        void Hide() { if (_shown) { ShowWindow(_hwnd, 0); _shown = false; } }

        // ---- the loop: the cursor followed at about a thousand readings a second, redrawn while it moves ---------------------
        void Loop()
        {
            try
            {
                try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
                _wndProc = WndProc; _cls = "AztIconCursor" + Stopwatch.GetTimestamp();
                var wc = new WNDCLASSEX(); wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX)); wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
                wc.hInstance = GetModuleHandleW(IntPtr.Zero); wc.lpszClassName = _cls;
                if (RegisterClassExW(ref wc) == 0) { StartError = "RegisterClassEx failed: " + Marshal.GetLastWin32Error(); return; }
                _hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, _cls, "AztIconCursor", WS_POPUP, 0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_hwnd == IntPtr.Zero) { StartError = "CreateWindowEx failed: " + Marshal.GetLastWin32Error(); return; }
                Overlay.CursorWindow = _hwnd;              // (the other host windows now go just below this one)
            }
            finally { _up.Set(); }
            timeBeginPeriod(1);
            var place = new double[7]; var clock = Stopwatch.StartNew();
            int slotWas = -1; double since = 0, shownSince = -1; long renderAt = -1000, checkAt = 0, lostAt = -1, raiseAt = 0, goneAt = -1, hiddenAt = -1;
            int lastX = int.MinValue, lastY = int.MinValue; float lastU = 0; bool heldCounted = false;
            try
            {
                while (_run)
                {
                    MSG m; while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
                    long ms = clock.ElapsedMilliseconds; double t = ms / 1000.0;
                    try
                    {
                        bool placed = Placement != null && Placement(place) && place[0] > 0;
                        // the game's bitmaps: blank while this can draw; put back once it has not been able to for a second
                        if (placed) { lostAt = -1; if (!KeepBitmaps && ms >= checkAt) { checkAt = ms + 400; BlankAll(); } }
                        else { if (lostAt < 0) lostAt = ms; if (ms - lostAt > 1000) RestoreAll(); }
                        int slot = placed ? Slot() : -1;
                        if (placed && slot < 0) NotOurs++;
                        // the game draws nothing where its cursor is (its bitmap is blanked): the panel need not tell it from the text
                        Overlay.GameCursorBlank = slot >= 0 && _orig[slot] != null;
                        // "pointer hidden": only once it has stayed up (see HiddenHoldMs -- every blit raises it for a moment)
                        if (RdW(HiddenAddr) == 0) hiddenAt = -1; else if (hiddenAt < 0) { hiddenAt = ms; HideFlagBlips++; heldCounted = false; }
                        bool hiddenLong = hiddenAt >= 0 && ms - hiddenAt >= HiddenHoldMs;
                        if (hiddenLong && !heldCounted) { heldCounted = true; HideFlagHolds++; }
                        bool show = slot >= 0 && RdW(MouselookAddr) == 0 && !hiddenLong && Front();
                        if (!show)
                        {
                            Hide(); if (goneAt < 0) goneAt = ms;
                            if (ms - goneAt > AppearAfterMs) { slotWas = -1; shownSince = -1; Shape = ""; }      // (gone a while: it appears afresh)
                            Thread.Sleep(6); continue;      // (hidden -- mouselook is most of play: not 1,000 passes a second -- 2026-10-13 audit)
                        }
                        goneAt = -1;
                        string name = SlotNames[slot];
                        if (shownSince < 0) shownSince = t;                                     // (up from nothing: it fades in)
                        if (slot != slotWas) { slotWas = slot; since = t; Shape = name; renderAt = -1000; }
                        // where: the bitmap's hot spot is the game's cursor; the grid is laid round it at the display's scale
                        float u = (float)(place[0] * Scale);
                        int cx = RdW(CursorAddr), cy = RdW(CursorAddr + 2), hx = RdW(HotAddr), hy = RdW(HotAddr + 2);
                        double hxs = place[1] + cx * place[0], hys = place[2] + cy * place[0];
                        float margin = (float)Math.Ceiling(12 * u); int n = (int)Math.Ceiling(30 * u + 2 * margin);
                        EnsureDib(n);
                        int wx = (int)Math.Round(hxs - hx * u - margin), wy = (int)Math.Round(hys - hy * u - margin);
                        double ta = t - since, fade = C01((t - shownSince) / FadeIn);
                        bool redraw = u != lastU || ms - renderAt >= RedrawMs || renderAt < 0;
                        if (redraw) { Render(name, margin, u, ta, t, fade); renderAt = ms; lastU = u; }
                        if (redraw || wx != lastX || wy != lastY || !_shown) { ShowAt(wx, wy); lastX = wx; lastY = wy; }
                        if (ms >= raiseAt) { raiseAt = ms + 200; SetWindowPos(_hwnd, Overlay.CoverSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); }
                    }
                    catch (Exception e) { StartError = e.GetType().Name + ": " + e.Message; }
                    Thread.Sleep(1);
                }
            }
            finally
            {
                timeEndPeriod(1);
                if (Overlay.CursorWindow == _hwnd) Overlay.CursorWindow = IntPtr.Zero;
                Overlay.GameCursorBlank = false;
                try { RestoreAll(); } catch { }
                Hide(); FreeDib(); DestroyWindow(_hwnd); _hwnd = IntPtr.Zero; UnregisterClassW(_cls, GetModuleHandleW(IntPtr.Zero));
            }
        }
    }
}
