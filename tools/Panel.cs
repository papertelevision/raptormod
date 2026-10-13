// Panel.cs -- THE WIDESCREEN PANEL (Josh, 2026-10-06), drawn by the host across the whole width.
//
// The game can only draw inside its own 1600x1200 screen, so on a widescreen display its panel
// is the 4:3 middle of the design (src\Build-HudWide.ps1 makes that copy, and decides from it
// where everything really is). This window lies over it at the display's full width and draws
// the true-colour art: art\wide\panel-off.png, with panel-lit.png for a lit mode button, and
// THE TEXT AREA's opening animation. The text module is the panel's own art; opening it STRETCHES
// the screen: one art row (through the cable slot between the expand key and the up key) is
// repeated, and everything above it -- the top bezel and the expand key -- rises, smoothly, at
// any height in between. The game does the same in one step (its BOXON is BOXOFF with the rows
// inserted), so where the game's open text lies is exactly where the risen screen is.
//
// WHAT THE GAME STILL DRAWS has to show through, and it is read out of DOSBox's display surface
// exactly as Overlay reads the viewport:
//   * live parts: the inventory list and the health bar in place; the log text 1:1, clipped to
//     as much of the screen as has opened;
//   * the mode buttons' state (which of the game's own lit / unlit sprites is showing);
//   * the CURSOR, wherever this window covers the view or the panel. It is found by
//     DIFFERENCE: a reading taken while the cursor is elsewhere is the reference, and pixels
//     near the cursor that differ from it are the cursor.
// The scroll keys (up / down) are this window's own; expand / collapse and replay stay the
// game's (the expand key rides the top bezel, frame-local in both states, which is what the
// game's own test expects). The window is click-through, like Overlay's: every click still
// reaches DOSBox.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace AztTool
{
    public class Panel : IDisposable
    {
        // ---- Win32 ---------------------------------------------------------------------
        delegate IntPtr WndProcD(IntPtr h, uint msg, IntPtr w, IntPtr l);
        delegate bool EnumD(IntPtr h, IntPtr l);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WNDCLASSEX { public int cbSize; public int style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
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
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumD cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dstDc, ref POINT dst, ref SIZE size, IntPtr srcDc, ref POINT src, uint key, ref BLENDFUNCTION blend, uint flags);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, [Out] int[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, [Out] byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);

        const int WS_POPUP = unchecked((int)0x80000000);
        const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
        const uint SWP_NOACTIVATE = 0x10, SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2;
        const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4;
        const uint WM_NCHITTEST = 0x84, ULW_ALPHA = 2;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

        // ---- the design, in GAME pixels (set from art\wide\wide.json before Start) -------
        public double K;                         // game px per art px
        public int ArtX0 = 17, ArtY0 = 76, HiScale = 2;
        public const int PanelTop = 977, ScreenW = 1600, ScreenH = 1200, ViewY = 49;
        /// <summary>The window covers game rows Top..1199: room for the opened text area.</summary>
        public int Top = 700;
        public int[] Inventory, Gauge, ReplaySprite;                                     // x, y, w, h
        public int[][] Modes = new int[3][];                                              // scan, map, menu
        public int[][] ModeOff = new int[3][], ModeOn = new int[3][];                      // what the game shows, 0xRRGGBB
        /// <summary>Host addresses in the game: the sticky box toggle (word), the conversation
        /// list (word), the cursor (two words) and the log's scroll offset (word).</summary>
        public long BoxBigAddr, ConvListAddr, CursorXAddr, CursorYAddr, LogScrollAddr;
        public int LogScrollStep = 8;

        // ---- THE TEXT AREA: the panel's own module, stretched (Build-HudWide's textArea) -------
        /// <summary>The part that rises: per column span, game x0, x1 and the module's top y there
        /// (the top bezel; the key column's plate starts a little higher).</summary>
        public double[][] TaTop;
        /// <summary>The game row that is repeated as the screen opens; everything above it rises.</summary>
        public double TaInsertY;
        /// <summary>How far the top rises when fully open, game rows (the game's own box extend).</summary>
        public int TaExtend;
        /// <summary>Where the game draws its text, closed and open (x, y, w, h).</summary>
        public int[] RecessClosed, RecessOpen;
        /// <summary>The scroll keys (game px: x, y, w, h); they do not move.</summary>
        public double[] LogUp, LogDown;
        /// <summary>The game's opened box over the view: x, top y, width. Its drawings there are left out
        /// while the box is open or moving -- this window draws that part itself.</summary>
        public int[] FrameOpen;
        /// <summary>The 3D carries on beneath the panel (Overlay.ExtendRows): the art's see-through parts
        /// stay see-through instead of being backed with black.</summary>
        public bool SeeThrough;
        /// <summary>Game rows from here down are this window's alone: the compose leaves the game's drawings
        /// out of them (its 8-bit copy of the panel's bleed), so the cursor is drawn here regardless.</summary>
        public int OwnFromRow = PanelTop;
        /// <summary>The black behind the art starts at this game row (just under the screen modules' top
        /// bezels, so its edge is hidden); above it the art is see-through over the view.</summary>
        public int BackingTop = PanelTop;
        /// <summary>...and runs between these game columns (NaN = the whole window).</summary>
        public double BackingX0 = double.NaN, BackingX1 = double.NaN;
        int _bx0, _bx1;
        /// <summary>The rising module's top-left corner, cut round: centre x, y and radius (game px, in the
        /// closed module's place). Null = square.</summary>
        public double[] TaCorner;
        /// <summary>Where the art's first column and row land (game px); NaN = the first panel's fixed
        /// mapping (art column 17 at x -160, row 347 at 1200).</summary>
        public double GameX0 = double.NaN, GameY0 = double.NaN;
        /// <summary>THE SLIDE-IN (Josh, 2026-10-06): the panel comes in as two halves, from the left and the
        /// right, meeting at this game x (the art's seam). NaN = no slide. Slide runs 0..1; it starts again
        /// when the panel shows after being hidden HideToSlide seconds or more (or for the first time).</summary>
        public double SeamX = double.NaN, SlideSeconds = 0.9, HideToSlide = 3.0, Slide = 1;
        /// <summary>Show (art only) while the view's window is up even before the game's screen is located.</summary>
        public bool Blind;
        /// <summary>Not shown at all until released (BootHd lets it in on the readout's HUD line).</summary>
        public volatile bool HoldOff;
        // ---- THE BOOK / ITEM VIEW (Josh, 2026-10-08: 'the items I pickup and view are hidden behind the ui ... make the
        // black background and item appear above any UI elements') ------------------------------------------------------
        /// <summary>While the game shows a book page or an item close-up (word [0x15257C]), the panel's art steps aside:
        /// its own rows (from PanelTop down) become black with the page drawn over them, and above that it is clear, so
        /// the view's window shows the rest of the page on black. The page surface's pixels (SetBook) say which game
        /// pixels are page: the game clears it to 0 before loading a page, whose pixels are all 128..255.</summary>
        public volatile bool BookView;
        long _bookAddr; int _bookW, _bookH; byte[] _bookMask; readonly Stopwatch _bookClock = Stopwatch.StartNew(); bool _bookWas;
        /// <summary>Where the page surface's pixels are (host address; 0 = unknown) and its size.</summary>
        public void SetBook(long hostPixels, int w, int h) { _bookAddr = hostPixels; _bookW = w; _bookH = h; }
        public long BookReads, BookFails;
        // FROM THE BLEED ROW, NOT PanelTop (Josh, 2026-10-11: the page was "cut off by some portions of the bottom UI's
        // shape"). The view's compose leaves the game's drawings out from OwnFromRow (the art's bleed over the view) down,
        // and this drew the page only from PanelTop -- so rows OwnFromRow..976 of the page showed black: a band across it.
        int BookFrom { get { return Math.Max(Top, Math.Min(OwnFromRow, PanelTop)); } }
        void ReadBook()
        {
            _bookClock.Restart();
            int from = BookFrom, rows = Math.Min(_bookH, ScreenH) - from;
            if (_bookAddr == 0 || _bookW <= 0 || _bookW > 4096 || rows <= 0) { _bookMask = null; return; }
            int n = rows * _bookW;
            if (_bookMask == null || _bookMask.Length != n) _bookMask = new byte[n];
            IntPtr got;
            if (!ReadProcessMemory(_proc, new IntPtr(_bookAddr + (long)from * _bookW), _bookMask, new IntPtr(n), out got) || got.ToInt64() != n) { _bookMask = null; BookFails++; return; }
            _bookMaskFrom = from; BookReads++;
        }
        int _bookMaskFrom = PanelTop;
        void ComposeBook()
        {
            Array.Clear(_work, 0, _work.Length);                        // clear: the view's window shows through
            int from = _bookMaskFrom, top = Math.Max(0, (int)Math.Ceiling(WY(from)));
            const int black = unchecked((int)0xFF000000);
            for (int y = top; y < _wh; y++)
            {
                int iy = (int)Math.Floor((y + _wy + 0.5 - _oy) / _s), mr = iy - from, row = y * _ww;
                bool rowOk = _bookMask != null && _cur != null && iy >= Top && iy < ScreenH && mr >= 0 && (mr + 1) * _bookW <= _bookMask.Length;
                for (int x = 0; x < _ww; x++)
                {
                    int px = black;
                    if (rowOk)
                    {
                        int ix = (int)Math.Floor((x + _wx + 0.5 - _ox) / _s);
                        if (ix >= 0 && ix < ScreenW && ix < _bookW && _bookMask[mr * _bookW + ix] != 0) px = _cur[(iy - Top) * _stride + ix] | black;
                    }
                    _work[row + x] = px;
                }
            }
            Cursor();
        }
        // ---- THE POWER-UP (Josh, 2026-10-07): the keys flicker to life one after another, in their glow art ----
        /// <summary>The keys, left to right, in game px (x, y, w, h).</summary>
        public int[][] PowerKeys;
        public double PowerStagger = 0.11, PowerFlicker = 0.34;
        Stopwatch _power; double _powerDelay;
        /// <summary>Start the keys' power-up after `delaySeconds` (the slide-in's length).</summary>
        public void PowerUp(double delaySeconds) { _powerDelay = delaySeconds; _power = Stopwatch.StartNew(); _dirty = true; }
        /// <summary>The health bar fills from empty (the boot's "HEALTH SYSTEM INITIATED"); the game's own reading takes over when there is one.</summary>
        public void BootHealth() { if (GaugeSlot == null) return; Health = 0; HealthTarget = 1; _dirty = true; }
        // on / off through a short stutter, then off for good (back to the keys' normal art)
        static readonly double[] Flick = { 0.05, 0.09, 0.16, 0.19, 0.30 };
        void DrawPower()
        {
            var keys = PowerKeys; var clk = _power; if (keys == null || clk == null || _lit == null) return;
            double t = clk.Elapsed.TotalSeconds - _powerDelay;
            if (t > keys.Length * PowerStagger + PowerFlicker + 0.05) { _power = null; return; }
            for (int k = 0; k < keys.Length; k++)
            {
                if (keys[k] == null) continue;
                double tk = (t - k * PowerStagger) / (PowerFlicker / 0.34) / (0.9 + 0.1 * (k % 3));
                if (tk < 0) continue;
                int seg = 0; while (seg < Flick.Length && tk >= Flick[seg]) seg++;
                if (seg < Flick.Length && (seg % 2) == 0) CopyRect(_lit, keys[k]);
            }
        }
        public long Slides;
        /// <summary>EDGE TO EDGE: game x of the left end cap's plate slice (x0, x1) and the right one's; their
        /// columns are repeated out to the window's edges. Null = the art ends where it ends.</summary>
        public double[] EdgeSlice;
        /// <summary>EDGE TO EDGE, the v3 way: game x of the left and right cut columns, each in the horizontal
        /// pipe run between an end cap and the body. On a display wider than the art, each end cap moves
        /// out to the window's edge and the cut column is repeated behind it; the body (every control) stays.</summary>
        public double[] EdgeCut;
        /// <summary>THE HEALTH BAR, drawn here (Josh, 2026-10-07: the game's bar was far too short for the new
        /// slot). The slot inside its rim (game px: x, y, w, h); the fill is read off the game's own bar
        /// (Gauge), eased, and drawn as a rounded amber tube that warms to orange and red as health falls.
        /// Null = the game's own bar, copied.</summary>
        public double[] GaugeSlot; public double Health = -1, HealthTarget = -1, HealthRate = 1.2;
        /// <summary>THE OPENED LOG BOX from its own art (Build-HudNew's textArea.exp): the image, where it lies
        /// when fully open (x, y, w, h game px), the row its moving top ends at, the closed module's top (from
        /// there down it replaces the closed art), and how far the top travels. Null file = the old stretch.</summary>
        public string TaExpFile; public double[] TaExpRect; public double TaExpCutY, TaExpClosedTop, TaExpShift;
        /// <summary>The scroll keys while the box is open (they sit higher in the opened art).</summary>
        public double[] LogUpOpen, LogDownOpen;
        /// <summary>THE SEAM LAYOUT (Josh, 2026-10-07): the art's two halves sit at the display's edges and
        /// the gap between them is filled with slivers of their inner edges, repeated. Only with the host's
        /// pointer (Pointer.cs): the game's own layout stays put, and MapPointer turns a position on the
        /// display into the one the game should see.</summary>
        public bool SeamLayout;
        /// <summary>The host's pointer, when it has taken over (its game position drives the scroll keys,
        /// and it draws the cursor, so the diff-cursor here stands down).</summary>
        public Pointer Ptr;
        /// <summary>Hand the pointer this panel's placement and its display-to-game mapping.</summary>
        public void AttachPointer(Pointer p) { Ptr = p; p.Placement = GetPlacement; p.Map = MapPointer; }
        int _dL, _dR, _scW;                       // the halves' shifts (window px) and the seam's canonical column
        /// <summary>Seconds for the text area to open or close.</summary>
        public double AnimSeconds = 0.42;
        /// <summary>The rectangle of the game's VIEWPORT whose drawings the 3D compose should leave out
        /// right now (x0, y0, x1, y1), or null.</summary>
        public int[] HideNow { get { return _hideNow; } }
        volatile int[] _hideNow;

        // ---- status, for the watcher's report ---------------------------------------------
        public bool Shown, BoxOpen; public int ModesLit; public long Updates, ReadFails, ScrollClicks, Toggles;
        public double ComposeMs, Anim; public string StartError = "", RectText = "(not placed)";
        public int CursorX, CursorY;

        readonly int _pid; readonly IntPtr _proc; readonly Overlay _ov;
        readonly Bitmap _imgOff, _imgLit; readonly string _wideDir;
        Thread _thread; volatile bool _run; WndProcD _wndProc; IntPtr _hwnd; string _cls;
        readonly ManualResetEvent _up = new ManualResetEvent(false);

        public Panel(int pid, Overlay ov, string wideDir)
        {
            _pid = pid; _ov = ov; _wideDir = wideDir;
            _proc = OpenProcess(0x0438, false, pid);      // QUERY_INFORMATION | VM_READ | VM_WRITE | VM_OPERATION
            if (_proc == IntPtr.Zero) throw new InvalidOperationException("OpenProcess failed: " + Marshal.GetLastWin32Error());
            _imgOff = LoadPArgb(System.IO.Path.Combine(wideDir, "panel-off.png"));
            _imgLit = LoadPArgb(System.IO.Path.Combine(wideDir, "panel-lit.png"));
        }
        static Bitmap LoadPArgb(string p)
        {
            using (var b = new Bitmap(p))
            {
                var c = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppPArgb);
                using (var g = Graphics.FromImage(c)) { g.CompositingMode = CompositingMode.SourceCopy; g.DrawImage(b, 0, 0, b.Width, b.Height); }
                return c;
            }
        }
        public bool Start()
        {
            _run = true;
            _thread = new Thread(WindowThread); _thread.IsBackground = true; _thread.Name = "AztPanel";
            _thread.SetApartmentState(ApartmentState.STA); _thread.Start();
            _up.WaitOne(3000);
            return _hwnd != IntPtr.Zero;
        }
        public void Dispose()
        {
            _run = false;
            if (_thread != null) { _thread.Join(1500); _thread = null; }
            if (_proc != IntPtr.Zero) CloseHandle(_proc);
            _imgOff.Dispose(); _imgLit.Dispose(); if (_imgExp != null) _imgExp.Dispose();
        }

        IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            if (msg == WM_NCHITTEST) return new IntPtr(-1);     // HTTRANSPARENT
            return DefWindowProcW(h, msg, w, l);
        }

        // ---- placement: the same arithmetic as Overlay.Place -------------------------------
        int _wx, _wy, _ww, _wh;                 // the window, in physical pixels
        double _s, _ox, _oy;                    // screen px per game px; the game screen's origin
        bool Place()
        {
            IntPtr best = IntPtr.Zero; long bestArea = 0; RECT bc = new RECT(); POINT bo = new POINT();
            EnumWindows(delegate (IntPtr hh, IntPtr l)
            {
                uint p; GetWindowThreadProcessId(hh, out p);
                if (p != (uint)_pid || !IsWindowVisible(hh) || IsIconic(hh)) return true;
                RECT c; if (!GetClientRect(hh, out c)) return true;
                long area = (long)(c.r - c.l) * (c.b - c.t);
                if (area > bestArea) { POINT o = new POINT(); ClientToScreen(hh, ref o); best = hh; bestArea = area; bc = c; bo = o; }
                return true;
            }, IntPtr.Zero);
            if (best == IntPtr.Zero) return false;
            int cw = bc.r - bc.l, ch = bc.b - bc.t; if (cw < 64 || ch < 64) return false;
            double s = Math.Min((double)cw / ScreenW, (double)ch / ScreenH);
            double ox = bo.x + (cw - ScreenW * s) / 2, oy = bo.y + (ch - ScreenH * s) / 2;
            int x = bo.x, w = cw, y = (int)Math.Round(oy + Top * s), h = (int)Math.Round(oy + ScreenH * s) - y;
            if (x != _wx || y != _wy || w != _ww || h != _wh || Math.Abs(s - _s) > 1e-9)
            {
                _wx = x; _wy = y; _ww = w; _wh = h; _s = s; _ox = ox; _oy = oy;
                SetWindowPos(_hwnd, Overlay.TopSlot(), x, y, w, h, SWP_NOACTIVATE);
                RectText = w + "x" + h + " at " + x + "," + y;
                Rescale();
            }
            return true;
        }
        // game -> window pixels
        double WX(double gx) { return _ox + gx * _s - _wx; }
        double WY(double gy) { return _oy + gy * _s - _wy; }

        // ---- the art, scaled to this window once per placement ---------------------------
        int[] _base, _lit, _expW; Bitmap _imgExp; int _ex0, _ex1;
        // the end caps' plate, stepped out to the window's edges: the slice's columns repeated
        void FillEdges(int[] img)
        {
            int l0 = (int)Math.Ceiling(WX(EdgeSlice[0])), l1 = (int)Math.Floor(WX(EdgeSlice[1]));
            int r0 = (int)Math.Ceiling(WX(EdgeSlice[2])), r1 = (int)Math.Floor(WX(EdgeSlice[3]));
            if (l1 <= l0) l1 = l0 + 1; if (r1 <= r0) r1 = r0 + 1;                       // (a one-column slice: a smooth extruded plate)
            for (int y = 0; y < _wh; y++)
            {
                int row = y * _ww;
                if (l1 > l0 && l0 > 0 && l1 <= _ww) for (int x = 0; x < l0; x++) img[row + x] = img[row + l1 - 1 - ((l0 - 1 - x) % (l1 - l0))];
                if (r1 > r0 && r0 >= 0 && r1 < _ww) for (int x = r1; x < _ww; x++) img[row + x] = img[row + r0 + ((x - r1) % (r1 - r0))];
            }
        }
        // THE SEAM LAYOUT: left of the seam moves by _dL, right of it by _dR; the gap takes slivers of the
        // two inner edges (a few columns in from the seam line itself, which is a dark joint), half each
        int[] Lay(int[] src)
        {
            var o = new int[_ww * _wh];
            // the seam itself is a dark joint: each half stops SeamTrim short of it, and the filler takes its place
            int tr = SeamTrimW, gap0 = _scW - tr + _dL, gap1 = _scW + tr + _dR, mid = (gap0 + gap1) / 2;
            int sl = Math.Max(0, Math.Min(_ww - 1, _scW - tr - 1)), sr = Math.Max(0, Math.Min(_ww - 1, _scW + tr));
            for (int y = 0; y < _wh; y++)
            {
                int row = y * _ww;
                for (int x = 0; x < _ww; x++)
                {
                    int sx = x < gap0 ? x - _dL : x >= gap1 ? x - _dR : x < mid ? sl : sr;
                    if (sx >= 0 && sx < _ww) o[row + x] = src[row + sx];
                }
            }
            return o;
        }
        // a game rect's shift on the display: by the half it lies in
        int SeamTrimW { get { return (int)Math.Ceiling(3 * _s); } }
        int XS(double gx) { return double.IsNaN(SeamX) ? 0 : gx < SeamX ? _dL : _dR; }
        /// <summary>A position on the display (game px; may lie outside 0..1599) -> where the game should see
        /// it. Over the art: the half it is in, moved back to the game's own layout (the seam's gap is the
        /// seam). Over the 3D view: itself, held inside the game's view.</summary>
        public double[] MapPointer(double dgx, double dgy)
        {
            double gx = dgx, gy = dgy; int[] wk = _work;
            if (_s > 0 && wk != null)
            {
                int wx = (int)Math.Floor(WX(dgx)), wy = (int)Math.Floor(WY(dgy));
                bool art = wy >= 0 && wy < _wh && wx >= 0 && wx < _ww && ((wk[wy * _ww + wx] >> 24) & 255) > 16;
                bool hud = art || (!SeeThrough && dgy >= BackingTop);
                if (hud && SeamLayout)
                {
                    int gap0 = _scW - SeamTrimW + _dL, gap1 = _scW + SeamTrimW + _dR;
                    gx = wx < gap0 ? dgx - _dL / _s : wx >= gap1 ? dgx - _dR / _s : SeamX;
                }
                else if (!hud && gy >= PanelTop) gy = PanelTop - 1;      // the 3D seen under the panel's gaps: still the view
            }
            return new[] { Math.Max(0, Math.Min(ScreenW - 1, gx)), Math.Max(0, Math.Min(ScreenH - 1, gy)) };
        }
        /// <summary>Where a game position shows on the display (game px): moved with its half.</summary>
        public double DisplayXOf(double gx) { return _s > 0 ? gx + XS(gx) / _s : gx; }
        /// <summary>For the pointer: { screen px per game px, the game screen's origin x, y, and the game
        /// window's client rect: left, top, width, height } -- false until placed.</summary>
        public bool GetPlacement(double[] p)
        {
            if (_s <= 0 || _ww <= 0) return false;
            p[0] = _s; p[1] = _ox; p[2] = _oy; p[3] = _wx; p[4] = _oy; p[5] = _ww; p[6] = ScreenH * _s;
            return true;
        }
        // the end caps, moved out to the window's edges; the cut column repeated in the gap behind each
        int[] CutEdges(int[] src, double aL, double aR)
        {
            int cL = (int)Math.Round(WX(EdgeCut[0])), cR = (int)Math.Round(WX(EdgeCut[1]));
            int sL = aL > 0 ? (int)Math.Floor(aL) : 0, sR = aR < _ww ? (int)Math.Floor(_ww - aR) : 0;
            if ((sL == 0 && sR == 0) || cL < 0 || cR >= _ww || cL >= cR) return src;
            var o = (int[])src.Clone();
            for (int y = 0; y < _wh; y++)
            {
                int row = y * _ww;
                for (int x = 0; x < cL; x++) { int sx = x < cL - sL ? x + sL : cL; o[row + x] = src[row + sx]; }
                for (int x = cR; x < _ww; x++) { int sx = x >= cR + sR ? x - sR : cR; o[row + x] = src[row + sx]; }
            }
            return o;
        }
        int _taX0, _taIns; int[] _taTop;          // the rising part, in window px: first column, the repeated row, top row per column
        void Rescale()
        {
            // the panel images: column u, row v at HiScale -> game x = -160 + u/HiScale*K, y = 1200 + (ArtY0 + v/HiScale - 347)*K
            double gx0 = double.IsNaN(GameX0) ? -160.0 : GameX0, gy0 = double.IsNaN(GameY0) ? 1200.0 + (ArtY0 - 347.0) * K : GameY0;
            double gw = _imgOff.Width / (double)HiScale * K, gh = _imgOff.Height / (double)HiScale * K;
            _base = Draw(_imgOff, WX(gx0), WY(gy0), gw * _s, gh * _s, _ww, _wh);
            _lit = Draw(_imgLit, WX(gx0), WY(gy0), gw * _s, gh * _s, _ww, _wh);
            _expW = null;
            if (TaExpFile != null && TaExpRect != null)
            {
                if (_imgExp == null) _imgExp = LoadPArgb(System.IO.Path.Combine(_wideDir, TaExpFile));
                _expW = Draw(_imgExp, WX(TaExpRect[0]), WY(TaExpRect[1]), TaExpRect[2] * _s, TaExpRect[3] * _s, _ww, _wh);
            }
            _dL = 0; _dR = 0; _scW = double.IsNaN(SeamX) ? -1 : (int)Math.Round(WX(SeamX));
            if (SeamLayout && _scW > 0)
            {
                double aL = WX(gx0), aR = WX(gx0 + gw);
                _dL = aL > 0 ? -(int)Math.Floor(aL) : 0; _dR = aR < _ww ? (int)Math.Floor(_ww - aR) : 0;
                _base = Lay(_base); _lit = Lay(_lit); if (_expW != null) _expW = Lay(_expW);
            }
            else if (EdgeCut != null) { double aL = WX(gx0), aR = WX(gx0 + gw); _base = CutEdges(_base, aL, aR); _lit = CutEdges(_lit, aL, aR); }
            else if (EdgeSlice != null) { FillEdges(_base); FillEdges(_lit); }
            if (_expW != null) { _ex0 = Math.Max(0, (int)Math.Floor(WX(TaExpRect[0])) + _dR); _ex1 = Math.Min(_ww, (int)Math.Ceiling(WX(TaExpRect[0] + TaExpRect[2])) + _dR); }
            _taTop = null;
            if (TaTop != null && TaTop.Length > 0)
            {
                double lo = double.MaxValue, hi = double.MinValue;
                foreach (var sp in TaTop) { lo = Math.Min(lo, sp[0]); hi = Math.Max(hi, sp[1]); }
                _taX0 = Math.Max(0, (int)Math.Round(WX(lo)) + _dR); int x1 = Math.Min(_ww, (int)Math.Round(WX(hi)) + _dR);
                _taIns = (int)Math.Round(WY(TaInsertY));
                _taTop = new int[Math.Max(0, x1 - _taX0)];
                for (int i = 0; i < _taTop.Length; i++)
                {
                    double gx = (_taX0 - _dR + i + _wx + 0.5 - _ox) / _s; _taTop[i] = -1;
                    foreach (var sp in TaTop) if (gx >= sp[0] && gx < sp[1]) { _taTop[i] = Math.Max(0, (int)Math.Round(WY(sp[2]))); break; }
                }
            }
            _work = new int[_ww * _wh];
            _seamW = double.IsNaN(SeamX) ? -1 : Math.Max(0, Math.Min(_ww, _scW + (_dL + _dR) / 2));
            _bx0 = double.IsNaN(BackingX0) ? 0 : Math.Max(0, Math.Min(_ww, (int)Math.Round(WX(BackingX0))));
            _bx1 = double.IsNaN(BackingX1) ? _ww : Math.Max(_bx0, Math.Min(_ww, (int)Math.Round(WX(BackingX1))));
            _opaqueFrom = Math.Max(0, (int)Math.Floor(WY(BackingTop)));
            MakeDib();
            _dirty = true;
        }
        static int[] Draw(Bitmap img, double x, double y, double w, double h, int dw, int dh)
        {
            using (var d = new Bitmap(dw, dh, PixelFormat.Format32bppPArgb))
            {
                using (var g = Graphics.FromImage(d))
                using (var ia = new ImageAttributes())
                {
                    g.Clear(Color.Transparent); g.CompositingMode = CompositingMode.SourceCopy;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    ia.SetWrapMode(WrapMode.TileFlipXY);
                    g.DrawImage(img, new RectangleF((float)x, (float)y, (float)w, (float)h), new RectangleF(0, 0, img.Width, img.Height), GraphicsUnit.Pixel);
                }
                var r = new int[dw * dh];
                var bd = d.LockBits(new Rectangle(0, 0, dw, dh), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
                Marshal.Copy(bd.Scan0, r, 0, r.Length); d.UnlockBits(bd);
                return r;
            }
        }

        // ---- the layered window's bitmap ----------------------------------------------------
        IntPtr _memDc, _dib, _oldBmp, _bits; int[] _work; int _opaqueFrom; bool _dirty;
        void MakeDib()
        {
            FreeDib();
            IntPtr sdc = GetDC(IntPtr.Zero);
            _memDc = CreateCompatibleDC(sdc); ReleaseDC(IntPtr.Zero, sdc);
            var bi = new BITMAPINFOHEADER(); bi.biSize = 40; bi.biWidth = _ww; bi.biHeight = -_wh; bi.biPlanes = 1; bi.biBitCount = 32;
            _dib = CreateDIBSection(_memDc, ref bi, 0, out _bits, IntPtr.Zero, 0);
            _oldBmp = SelectObject(_memDc, _dib);
        }
        void FreeDib()
        {
            if (_memDc != IntPtr.Zero) { SelectObject(_memDc, _oldBmp); DeleteDC(_memDc); _memDc = IntPtr.Zero; }
            if (_dib != IntPtr.Zero) { DeleteObject(_dib); _dib = IntPtr.Zero; }
        }
        void Present()
        {
            Marshal.Copy(_work, 0, _bits, _work.Length);
            IntPtr sdc = GetDC(IntPtr.Zero);
            var pos = new POINT { x = _wx, y = _wy }; var size = new SIZE { cx = _ww, cy = _wh }; var src = new POINT();
            var bl = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
            UpdateLayeredWindow(_hwnd, sdc, ref pos, ref size, _memDc, ref src, 0, ref bl, ULW_ALPHA);
            ReleaseDC(IntPtr.Zero, sdc);
            Updates++;
        }

        // ---- reading the game ------------------------------------------------------------------
        int[] _cur, _prev, _ref; int _stride; bool _haveRef;
        bool ReadScreen()
        {
            long a = _ov.SurfaceAddress; int st = _ov.SurfaceStride;
            if (a == 0 || st <= 0) return false;
            int rows = ScreenH - Top, n = st * (rows - 1) + ScreenW;
            if (_cur == null || _cur.Length != n || _stride != st) { _cur = new int[n]; _prev = new int[n]; _ref = new int[n]; _stride = st; _haveRef = false; }
            IntPtr got;
            if (!ReadProcessMemory(_proc, new IntPtr(a + (long)(Top - ViewY) * st * 4), _cur, new IntPtr((long)n * 4), out got) || got.ToInt64() != (long)n * 4) { ReadFails++; return false; }
            return true;
        }
        int Word(long addr)
        {
            if (addr == 0) return 0;
            var b = new byte[2]; IntPtr got;
            if (!ReadProcessMemory(_proc, new IntPtr(addr), b, new IntPtr(2), out got)) return 0;
            return b[0] | (b[1] << 8);
        }
        void SetWord(long addr, int v)
        {
            if (addr == 0) return;
            var b = new byte[] { (byte)v, (byte)(v >> 8) }; IntPtr wr;
            WriteProcessMemory(_proc, new IntPtr(addr), b, new IntPtr(2), out wr);
        }
        int Px(int gx, int gy) { return _cur[(gy - Top) * _stride + gx] & 0xFFFFFF; }
        // THE STEADY COPY of the live parts (Josh: the log's text flickered). The game repaints its text box every
        // frame -- fills it with the frame's own pixels, then draws the text -- and a reading that lands between
        // the two catches the box empty. So a pixel of the live parts only changes here once two readings in a
        // row agree on its new value: a half-drawn box is never shown, and real changes arrive one reading late.
        // ASYMMETRIC (the two-reading rule still let some through): text APPEARING is taken after 2 agreeing
        // readings, text VANISHING (a pixel going back to its background) only after 6 -- longer than one of the
        // game's frames, so a box caught between its fill and its text never blanks the text.
        int[] _stab, _last; byte[] _cnt; public long SteadyHolds; public int SteadyShow = 2, SteadyHide = 6;
        bool Steady()
        {
            if (_cur == null) return false;
            if (_stab == null || _stab.Length != _cur.Length) { _stab = (int[])_cur.Clone(); _last = (int[])_cur.Clone(); _cnt = new byte[_cur.Length]; return true; }
            bool changed = false; long held = 0;
            foreach (var g in new[] { Inventory, Gauge, BoxOpen ? RecessOpen : RecessClosed })
            {
                if (g == null) continue;
                int y0 = Math.Max(Top, g[1]), y1 = Math.Min(ScreenH, g[1] + g[3]), x0 = Math.Max(0, g[0]), x1 = Math.Min(ScreenW, g[0] + g[2]);
                for (int y = y0; y < y1; y++)
                {
                    int o = (y - Top) * _stride;
                    for (int x = x0; x < x1; x++)
                    {
                        int i = o + x, c = _cur[i];
                        if (c != _stab[i])
                        {
                            if (c == _last[i]) { if (_cnt[i] < 255) _cnt[i]++; } else _cnt[i] = 1;
                            int need = IsBg(c & 0xFFFFFF, Bg(x, y)) ? SteadyHide : SteadyShow;
                            if (_cnt[i] >= need) { _stab[i] = c; _cnt[i] = 0; changed = true; } else held++;
                        }
                        else _cnt[i] = 0;
                        _last[i] = c;
                    }
                }
            }
            if (held > 0) SteadyHolds++;
            return changed;
        }
        // the same, without the cursor: near it, the reference (taken while it was elsewhere) -- so a
        // live part copied somewhere else does not carry the cursor with it (it is drawn on its own)
        int PxNoCursor(int gx, int gy)
        {
            if (_haveRef && !_blankCur && gx >= CursorX - 12 && gx < CursorX + 72 && gy >= CursorY - 12 && gy < CursorY + 72) return _ref[(gy - Top) * _stride + gx] & 0xFFFFFF;
            return (_stab ?? _cur)[(gy - Top) * _stride + gx] & 0xFFFFFF;
        }
        // THE REFERENCE, every reading: the screen itself everywhere but a box around the cursor. In
        // the box, what differs from it is the cursor -- unless far too much differs (the screen changed
        // under a resting cursor: the box opened, a mode lit). Then the cursor is the shape last seen,
        // and everything else in the box is taken as the new screen, so it heals in one reading.
        const int CurBoxL = 12, CurBoxR = 72, CurMaxPx = 1500, CurMaxSpan = 64;
        int[] _sprDx = new int[(CurBoxL + CurBoxR) * (CurBoxL + CurBoxR)], _sprDy = new int[(CurBoxL + CurBoxR) * (CurBoxL + CurBoxR)];
        int _sprN; bool[] _learned = new bool[(CurBoxL + CurBoxR) * (CurBoxL + CurBoxR)]; bool _haveLearned;
        public long CursorHeals;
        // THE GAME DRAWS NO CURSOR while the host's vector cursor is up (CursorIcons.cs blanks its bitmap; Overlay.GameCursorBlank).
        // Then there is nothing to tell apart: the reference is the screen itself, nothing is learnt and no cursor is drawn here.
        // (Without this the box round a resting pointer was never refreshed -- the text under it stayed OLD -- and changing text
        // there was "learnt" as the cursor's shape and redrawn wherever the pointer went.)
        bool _blankCur; public long BlankCursorReadings;
        void UpdateRef()
        {
            _blankCur = Overlay.GameCursorBlank;
            if (_blankCur) { _sprN = 0; _haveLearned = false; Buffer.BlockCopy(_cur, 0, _ref, 0, _cur.Length * 4); _haveRef = true; BlankCursorReadings++; return; }
            int rows = ScreenH - Top;
            int cx0 = Math.Max(0, CursorX - CurBoxL), cx1 = Math.Min(ScreenW, CursorX + CurBoxR);
            int cy0 = Math.Max(0, CursorY - CurBoxL - Top), cy1 = Math.Min(rows, CursorY + CurBoxR - Top);
            bool inside = CursorX >= 0 && CursorX < ScreenW && CursorY < ScreenH && cy1 > cy0 && cx1 > cx0;
            _sprN = 0;
            if (!inside) { Buffer.BlockCopy(_cur, 0, _ref, 0, _cur.Length * 4); _haveRef = true; return; }
            // THE REFERENCE AT ONCE (it used to wait for the cursor to leave the window, which -- with the window
            // now reaching row 492 for the tall opened log -- it never did, so the cursor was never drawn over
            // the art). Taken whole now; the cursor's own spot heals as soon as it moves.
            if (!_haveRef) { Buffer.BlockCopy(_cur, 0, _ref, 0, _cur.Length * 4); _haveRef = true; return; }
            for (int r = 0; r < rows; r++)
            {
                int o = r * _stride;
                if (r < cy0 || r >= cy1) Buffer.BlockCopy(_cur, o * 4, _ref, o * 4, ScreenW * 4);
                else { Buffer.BlockCopy(_cur, o * 4, _ref, o * 4, cx0 * 4); Buffer.BlockCopy(_cur, (o + cx1) * 4, _ref, (o + cx1) * 4, (ScreenW - cx1) * 4); }
            }
            int n = 0, minX = int.MaxValue, maxX = int.MinValue, minY = int.MaxValue, maxY = int.MinValue;
            for (int r = cy0; r < cy1; r++)
                for (int x = cx0; x < cx1; x++)
                {
                    int i = r * _stride + x; if (((_cur[i] ^ _ref[i]) & 0xFFFFFF) == 0) continue;
                    int dx = x - CursorX, dy = r + Top - CursorY;
                    _sprDx[n] = dx; _sprDy[n] = dy; n++;
                    if (dx < minX) minX = dx; if (dx > maxX) maxX = dx; if (dy < minY) minY = dy; if (dy > maxY) maxY = dy;
                }
            if (n == 0) return;
            if (n <= CurMaxPx && maxX - minX < CurMaxSpan && maxY - minY < CurMaxSpan)
            {
                _sprN = n; Array.Clear(_learned, 0, _learned.Length);
                for (int k = 0; k < n; k++) _learned[(_sprDy[k] + CurBoxL) * (CurBoxL + CurBoxR) + _sprDx[k] + CurBoxL] = true;
                _haveLearned = true; return;
            }
            if (!_haveLearned) return;
            CursorHeals++; n = 0;
            for (int r = cy0; r < cy1; r++)
                for (int x = cx0; x < cx1; x++)
                {
                    int dx = x - CursorX, dy = r + Top - CursorY, i = r * _stride + x;
                    if (_learned[(dy + CurBoxL) * (CurBoxL + CurBoxR) + dx + CurBoxL]) { _sprDx[n] = dx; _sprDy[n] = dy; n++; }
                    else _ref[i] = _cur[i];
                }
            _sprN = n;
        }

        // which of the game's two sprites a mode button shows: the nearer, summed over a grid
        int ModesShown()
        {
            int lit = 0;
            for (int m = 0; m < 3; m++)
            {
                int[] r = Modes[m], off = ModeOff[m], on = ModeOn[m]; if (r == null || off == null || on == null) continue;
                long dOff = 0, dOn = 0;
                for (int y = 1; y < r[3]; y += 3) for (int x = 1; x < r[2]; x += 3)
                {
                    int c = Px(r[0] + x, r[1] + y), a = off[y * r[2] + x], b = on[y * r[2] + x];
                    dOff += Math.Abs(((c >> 16) & 255) - ((a >> 16) & 255)) + Math.Abs(((c >> 8) & 255) - ((a >> 8) & 255)) + Math.Abs((c & 255) - (a & 255));
                    dOn  += Math.Abs(((c >> 16) & 255) - ((b >> 16) & 255)) + Math.Abs(((c >> 8) & 255) - ((b >> 8) & 255)) + Math.Abs((c & 255) - (b & 255));
                }
                if (dOn < dOff) lit |= 1 << m;
            }
            return lit;
        }

        // ---- one picture ---------------------------------------------------------------------
        static int Scale(int src, int a256)
        {   // a premultiplied pixel times a/256
            uint s = (uint)src, k = (uint)a256;
            uint rb = ((s & 0x00FF00FF) * k >> 8) & 0x00FF00FF, ag = (((s >> 8) & 0x00FF00FF) * k >> 8) & 0x00FF00FF;
            return (int)(rb | (ag << 8));
        }
        static int Over(int src, int dst)
        {   // premultiplied "over"
            uint s = (uint)src, d = (uint)dst, ia = 255 - (s >> 24);
            uint rb = ((d & 0x00FF00FF) * ia >> 8) & 0x00FF00FF, ag = (((d >> 8) & 0x00FF00FF) * ia >> 8) & 0x00FF00FF;
            return (int)(s + (rb | (ag << 8)));
        }
        static double Ease(double t) { t = Math.Max(0, Math.Min(1, t)); return t * t * (3 - 2 * t); }
        void Compose()
        {
            var sw = Stopwatch.StartNew();
            if (Slide < 1 && _seamW >= 0) { ComposeSlide(); ComposeMs = sw.Elapsed.TotalMilliseconds; return; }
            Buffer.BlockCopy(_base, 0, _work, 0, _work.Length * 4);
            // a lit mode button: that rectangle from the lit art
            for (int m = 0; m < 3; m++) if ((ModesLit & (1 << m)) != 0) CopyRect(_lit, Modes[m]);
            DrawPower();
            double e = Ease(Anim);
            int shift = (int)Math.Round(e * TaExtend * _s);
            if (_expW != null) { if (e > 0) ExpandDraw(e); }
            else if (shift > 0) Stretch(shift);
            // without the 3D beneath it, the panel is opaque: black behind the art from its top row down
            if (!SeeThrough) for (int y = _opaqueFrom; y < _wh; y++) for (int i = y * _ww + _bx0; i < y * _ww + _bx1; i++) _work[i] |= unchecked((int)0xFF000000);
            // the game's live parts -- none yet while the panel is up BLIND (the boot, before the game's screen is found)
            if (_cur == null) { if (GaugeSlot != null && Health >= 0) DrawHealth(); ComposeMs = sw.Elapsed.TotalMilliseconds; return; }
            if (!InvHost()) LiveKeyed(Inventory);
            if (GaugeSlot != null) DrawHealth(); else LiveKeyed(Gauge);
            if (!LogHost(e)) LogText(e);
            Cursor();
            ComposeMs = sw.Elapsed.TotalMilliseconds;
        }
        // THE SLIDE-IN: the left half (the window's columns left of the seam, black behind it from the
        // backing row down, as at rest) comes in from the left, the right half from the right; nothing of
        // the game's is drawn until they meet.
        int _seamW = -1;
        void ComposeSlide()
        {
            double t = Math.Max(0, Math.Min(1, Slide)), e = 1 - (1 - t) * (1 - t) * (1 - t);    // ease out
            int sx = _seamW, dxL = -(int)Math.Round((1 - e) * sx), dxR = (int)Math.Round((1 - e) * (_ww - sx));
            Array.Clear(_work, 0, _work.Length);
            int opaqueFrom = SeeThrough ? _wh : _opaqueFrom;
            for (int y = 0; y < _wh; y++)
            {
                int row = y * _ww; bool opq = y >= opaqueFrom;
                int s0 = -dxL, n = sx - s0;                                   // left: source columns s0..sx-1 -> 0..
                if (n > 0) { Buffer.BlockCopy(_base, (row + s0) * 4, _work, row * 4, n * 4); if (opq) for (int c = Math.Max(s0, _bx0); c < Math.Min(sx, _bx1); c++) _work[row + c + dxL] |= unchecked((int)0xFF000000); }
                int d0 = sx + dxR, n2 = _ww - d0;                             // right: source sx.. -> d0..
                if (n2 > 0) { Buffer.BlockCopy(_base, (row + sx) * 4, _work, (row + d0) * 4, n2 * 4); if (opq) for (int c = Math.Max(sx, _bx0); c < Math.Min(sx + n2, _bx1); c++) _work[row + c + dxR] |= unchecked((int)0xFF000000); }
            }
        }
        // THE OPENED LOG BOX at e (0 closed .. 1 open), from its own art: the top of the opened module (border,
        // collapse chevron, the piston's cap) rides up from where the closed top is, and below it the opened
        // art is uncovered in place -- the piston's rod grows out from under its cap. From the closed module's
        // top down it REPLACES the closed art; the closed art fades out over the first part of the way.
        void ExpandDraw(double e)
        {
            int ey0 = (int)Math.Floor(WY(TaExpRect[1])), cut = (int)Math.Round(WY(TaExpCutY)), ct = Math.Max(0, (int)Math.Round(WY(TaExpClosedTop)));
            int D = (int)Math.Round((1 - e) * TaExpShift * _s);
            int fade = (int)(256 * Math.Max(0, 1 - e / 0.3));
            for (int y = Math.Max(0, ey0); y < _wh; y++)
            {
                int src = y < ey0 + D ? -1 : y < cut + D ? y - D : y;
                int row = y * _ww, srow = src * _ww;
                for (int x = _ex0; x < _ex1; x++)
                {
                    int p = src >= 0 && src < _wh ? _expW[srow + x] : 0, o = row + x;
                    if (y >= ct) { if (fade > 0) p = Over(Scale(_base[o], fade), p); _work[o] = p; }
                    else if (p != 0) _work[o] = Over(p, _work[o]);
                }
            }
        }
        // the game's bar: how far it is filled, from its stable copy (the rightmost column, across a few rows,
        // that is not the slot's own background)
        double ReadHealth()
        {
            var g = Gauge; if (g == null || _cur == null) return -1;
            int best = -1;
            for (int k = 1; k <= 3; k++)
            {
                int gy = g[1] + g[3] * k / 4; if (gy < Top || gy >= ScreenH) continue;
                for (int gx = g[0] + g[2] - 1; gx >= g[0]; gx--)
                {
                    int c = PxNoCursor(gx, gy);
                    if (!IsBg(c, Bg(gx, gy))) { if (gx - g[0] + 1 > best) best = gx - g[0] + 1; break; }
                }
            }
            return best < 0 ? 0 : Math.Min(1.0, best / (double)g[2]);
        }
        static double Smooth01(double a, double b, double v) { double t = Math.Max(0, Math.Min(1, (v - a) / (b - a))); return t * t * (3 - 2 * t); }
        void DrawHealth()
        {
            double frac = Health < 0 ? 0 : Health;
            double gx0 = GaugeSlot[0] + 4, gx1 = GaugeSlot[0] + GaugeSlot[2] - 4, gy0 = GaugeSlot[1] + 5, gy1 = GaugeSlot[1] + GaugeSlot[3] - 5;
            int sh = XS(GaugeSlot[0]);
            double wx0 = WX(gx0) + sh, wx1 = WX(gx1) + sh, wy0 = WY(gy0), wy1 = WY(gy1);
            double wf = wx0 + frac * (wx1 - wx0); if (wf <= wx0 + 0.5) return;
            // a rounded rectangle, corner radius a quarter of its height (Josh: half the capsule's rounding)
            double rad = (wy1 - wy0) / 4;
            // colour by health: amber-gold, warming to orange, then red when low
            double hr = 0xE8, hg = 0xA0, hb = 0x38;
            if (frac < 0.5) { double k = Smooth01(0.5, 0.2, frac); hr += (0xE0 - hr) * k; hg += (0x60 - hg) * k; hb += (0x22 - hb) * k; }
            if (frac < 0.2) { double k = Smooth01(0.2, 0.05, frac); hr += (0xC8 - hr) * k; hg += (0x26 - hg) * k; hb += (0x18 - hb) * k; }
            int x0 = Math.Max(0, (int)Math.Floor(wx0)), x1 = Math.Min(_ww, (int)Math.Ceiling(wf)), y0 = Math.Max(0, (int)Math.Floor(wy0)), y1 = Math.Min(_wh, (int)Math.Ceiling(wy1));
            for (int y = y0; y < y1; y++)
            {
                double py = y + 0.5, tv = (py - wy0) / (wy1 - wy0);
                // a tube: a bright band a third of the way down, darker toward the bottom
                double shade = 0.62 + 0.62 * Math.Exp(-Math.Pow((tv - 0.3) / 0.15, 2)) - 0.32 * Math.Max(0, tv - 0.55) / 0.45;
                for (int x = x0; x < x1; x++)
                {
                    double px = x + 0.5;
                    // rounded ends (both: the far one moves with the fill)
                    double cov = 1;
                    double dx = Math.Max(0, Math.Max((wx0 + rad) - px, px - (wf - rad))), dy = Math.Max(0, Math.Max((wy0 + rad) - py, py - (wy1 - rad)));
                    double d = Math.Sqrt(dx * dx + dy * dy);
                    cov = Math.Max(0, Math.Min(1, rad - d + 0.5)); if (cov <= 0) continue;
                    double edge = Math.Exp(-Math.Max(0, wf - px) / 6.0) * 0.35;              // a glow at the leading edge
                    double s2 = shade + edge;
                    int r = (int)Math.Min(255, hr * s2), gg = (int)Math.Min(255, hg * s2), b = (int)Math.Min(255, hb * s2), a = (int)(cov * 255);
                    int src = (a << 24) | ((r * a / 255) << 16) | ((gg * a / 255) << 8) | (b * a / 255);
                    int o = y * _ww + x; _work[o] = Over(src, _work[o]);
                }
            }
        }
        // THE TEXT AREA, opened by `shift` window rows: in each of the module's columns, the module
        // from its top down to the repeated row moves up by `shift`, and the gap it leaves is that row,
        // repeated. All of it comes from the closed panel art itself.
        void Stretch(int shift)
        {
            if (_taTop == null) return;
            int ins = Math.Min(_wh - 1, _taIns), band0 = ins - shift;
            double[] cn = TaCorner; double inv = 1.0 / _s;
            for (int i = 0; i < _taTop.Length; i++)
            {
                int t = _taTop[i], x = _taX0 + i; if (t < 0 || t >= ins) continue;
                int bandPx = _base[ins * _ww + x];
                for (int y = Math.Max(0, t - shift); y < ins; y++)
                {
                    int src = y < band0 ? _base[(y + shift) * _ww + x] : bandPx;
                    if (cn != null && y < band0)
                    {   // the rounded corner: coverage of the circle, in the closed module's own place
                        double gx = (x + _wx + 0.5 - _ox) * inv - cn[0], gy = (y + shift + _wy + 0.5 - _oy) * inv - cn[1];
                        if (gx < 0 && gy < 0)
                        {
                            double cov = Math.Max(0, Math.Min(1, (cn[2] - Math.Sqrt(gx * gx + gy * gy)) * _s + 0.5));   // one window pixel of soft edge
                            if (cov <= 0) src = 0; else if (cov < 1) src = Scale(src, (int)(cov * 256));
                        }
                    }
                    // above the closed module's top: over whatever the panel has there (hoses);
                    // inside it: the old module is replaced
                    int o = y * _ww + x; _work[o] = Over(src, y < t ? _work[o] : 0);
                }
            }
        }
        // THE LOG TEXT, 1:1 from the game. Open (the game shows its tall recess at once): as much of it
        // as the rising screen has uncovered. Closed, or closing: the short recess.
        void LogText(double e)
        {
            if (!BoxOpen || RecessOpen == null) { LiveKeyed(RecessClosed); return; }
            int[] c = RecessClosed, o = RecessOpen; if (c == null) return;
            int bottom = o[1] + o[3], top = Math.Max(o[1], (int)Math.Ceiling(c[1] - e * TaExtend));
            if (bottom - top >= 2) LiveKeyed(new[] { o[0], top, o[2], bottom - top });
        }
        // ---- THE HUD TEXT IN VECTOR TYPE (Josh, 2026-10-09; HudDecoder below): the log is read back out of the game's
        // own text surface and drawn in Verdana at the display's resolution; the inventory's names are read straight
        // from its list. Whatever does not decode -- or does not line up with what the game shows -- is the game's pixels.
        /// <summary>Host addresses (MemBase + guest address) of: dword [0x1521AC] the log's text object, dwords [0x152178]
        /// / [0x15217C] the gold / cyan fonts, dword [0x163A38] the inventory's font, the inventory list widget 0x163A40,
        /// word 0x14747A its row pitch, word 0x152B32 the conversation list's scroll. MemBase turns a guest pointer into a
        /// host address.</summary>
        public long MemBase, LogObjAddr, FontGoldAddr, FontCyanAddr, FontInvAddr, InvWidgetAddr, InvPitchAddr, ConvScrollAddr;
        /// <summary>Host address of word 0x162B34, the conversation's option count; the options' ends follow it (0x162B36[i],
        /// words: the text surface's row where option i ends -- the table AztConvHit's click walks).</summary>
        public long ConvOptAddr;
        /// <summary>Host address of word 0x152B28: a conversation line is being spoken (no options list up meanwhile).</summary>
        public long ConvSpeakAddr;
        /// <summary>Conversation frames whose screen check failed but kept the last good placement (a torn reading: the game
        /// repaints its box -- fill, then text -- every frame); the option the pointer is over (-1 none).</summary>
        public long TextHolds; public int HoverOption = -1;
        public bool HostText = true;
        public string TextFace = "Consolas"; public bool TextBold = true; public double TextEm = 17.5;      // (the visor's face, Josh 2026-10-09, at the game sheets' own em)
        /// <summary>The game's palette (0xRRGGBB): gold (56) and cyan (55) for the log. Null = their stock colours.</summary>
        public int[] Palette;
        public long TextFrames, TextFallbacks, TextLinesDecoded, TextRunsMissed; public string TextNote = "", TextSample = "";
        HudFont[] _logFonts; HudFont _invFont; HudDecoder _dec; uint[] _fontPtrs = new uint[3];
        byte[] _surf; int _surfW, _surfH;
        readonly System.Collections.Generic.Dictionary<ulong, HudRun[]> _lineCache = new System.Collections.Generic.Dictionary<ulong, HudRun[]>();
        readonly System.Collections.Generic.Dictionary<uint, string> _nameCache = new System.Collections.Generic.Dictionary<uint, string>();
        byte[] Bytes(long addr, int n)
        {
            if (addr == 0 || n <= 0) return null;
            var b = new byte[n]; IntPtr got;
            return ReadProcessMemory(_proc, new IntPtr(addr), b, new IntPtr(n), out got) && got.ToInt64() == n ? b : null;
        }
        uint Dword(long addr) { var b = Bytes(addr, 4); return b == null ? 0 : BitConverter.ToUInt32(b, 0); }
        HudFont ReadFont(uint ptr)
        {
            if (ptr < 0x1000) return null;
            var fo = Bytes(MemBase + ptr, 10); if (fo == null || fo[0] != 0x21 || fo[1] != 139) return null;
            uint sp = BitConverter.ToUInt32(fo, 2), tp = BitConverter.ToUInt32(fo, 6);
            var sh = Bytes(MemBase + sp, 8); if (sh == null) return null;
            int w = BitConverter.ToUInt16(sh, 0), h = BitConverter.ToUInt16(sh, 2); uint px = BitConverter.ToUInt32(sh, 4);
            if (w <= 0 || h <= 0 || w > 8192 || h > 64) return null;
            var sheet = Bytes(MemBase + px, w * h); var tb = Bytes(MemBase + tp, 139 * 4); if (sheet == null || tb == null) return null;
            var st = new int[139]; var en = new int[139];
            for (int g = 0; g < 139; g++) { st[g] = BitConverter.ToUInt16(tb, g * 4); en[g] = BitConverter.ToUInt16(tb, g * 4 + 2); if (en[g] < st[g] || en[g] > w) return null; }
            return new HudFont(sheet, w, h, st, en);
        }
        bool ReadTextFonts()
        {
            uint g = Dword(FontGoldAddr), c = Dword(FontCyanAddr), i = Dword(FontInvAddr);
            if (_logFonts == null || g != _fontPtrs[0] || c != _fontPtrs[1])
            {
                var fg = ReadFont(g); var fc = ReadFont(c);
                if (fg == null || fc == null || fg.H != fc.H) { _logFonts = null; _dec = null; TextNote = "the log's fonts could not be read"; return false; }
                _logFonts = new[] { fg, fc }; _dec = new HudDecoder(_logFonts); _fontPtrs[0] = g; _fontPtrs[1] = c; _lineCache.Clear();
            }
            if (_invFont == null || i != _fontPtrs[2]) { _invFont = ReadFont(i); _fontPtrs[2] = i; }
            return true;
        }
        static ulong BandHash(byte[] pix, int w, int top, int rows)
        {
            ulong h = 14695981039346656037UL; int o = top * w, n = rows * w;
            for (int i = 0; i < n; i++) { h ^= pix[o + i]; h *= 1099511628211UL; }
            return h;
        }
        HudRun[] DecodeLine(int top)
        {
            ulong k = BandHash(_surf, _surfW, top, _logFonts[0].H - 1) ^ ((ulong)top << 48);
            HudRun[] r; if (_lineCache.TryGetValue(k, out r)) return r;
            r = _dec.Line(_surf, _surfW, top); TextLinesDecoded++;
            foreach (var x in r) if (!x.Ok) TextRunsMissed++;
            if (_lineCache.Count > 600) _lineCache.Clear();
            _lineCache[k] = r; return r;
        }
        // is a game pixel (screen) ink -- not the background it sits on?
        bool ScreenInk(int gx, int gy) { if (gx < 0 || gx >= ScreenW || gy < Top || gy >= ScreenH) return false; int c = PxNoCursor(gx, gy); return !IsBg(c, Bg(gx, gy)); }
        // THE CHECK that the surface rows put at the recess are what the game shows: the surface's main-ink pixels (gold /
        // cyan at full strength) against the screen's BRIGHT pixels there -- a shadow on a dark box is not reliably visible
        bool[] _scrInk; int _scrX, _scrY, _scrW, _scrH;
        const int AlignPad = 64;       // (how far the game's text may sit from the recess's left edge: its box has padding)
        void ScreenInkMap(int x0, int y0, int w, int h)
        {
            _scrX = x0; _scrY = y0; _scrW = w; _scrH = h;
            if (_scrInk == null || _scrInk.Length < w * h) _scrInk = new bool[w * h];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int gx = x0 + x, gy = y0 + y; bool ink = false;
                    if (gx >= 0 && gx < ScreenW && gy >= Top && gy < ScreenH)
                    {
                        int c = PxNoCursor(gx, gy);
                        ink = 0.30 * ((c >> 16) & 255) + 0.59 * ((c >> 8) & 255) + 0.11 * (c & 255) > 110 && !IsBg(c, Bg(gx, gy));
                    }
                    _scrInk[y * w + x] = ink;
                }
        }
        bool MainInk(int v) { return v != 0 && (v == _logFonts[0].Ink || v == _logFonts[1].Ink); }
        // surface rows from `first` laid at the recess's top row ry, shifted dx: how many of its main-ink pixels the screen
        // shows bright (the share), visible rows vy0..vy1
        double Agree(int first, int dx, int ry, int vy0, int vy1, int step, out int inks)
        {
            int both = 0, s = 0, c = 0;
            for (int y = vy0; y < vy1; y += step)
            {
                int row = first + y - ry; bool rowIn = row >= 0 && row < _surfH; int so = (y - _scrY) * _scrW;
                for (int x = 0; x < _surfW; x += 2)
                {
                    int sx = x + AlignPad + dx; if (sx < 0 || sx >= _scrW) continue;
                    bool a = rowIn && MainInk(_surf[row * _surfW + x]), b = _scrInk[so + sx];
                    if (a) s++; if (b) c++; if (a && b) both++;
                }
            }
            inks = Math.Max(s, c);
            if (s < 20) return c < 20 ? 1 : 0;
            double r = (double)both / s; if (c > 3 * s) r *= 0.5;
            return r;
        }
        // NOT WHERE THE MATHS SAYS: rows by the ink-per-row profile, then columns by the ink-per-column profile at those rows
        bool Search(int ry, int vy0, int vy1, out int first, out int dx)
        {
            int n = vy1 - vy0; first = 0; dx = 0;
            var rp = new int[n]; for (int y = 0; y < n; y++) { int so = y * _scrW; for (int x = 0; x < _scrW; x++) if (_scrInk[so + x]) rp[y]++; }
            var sp = new int[_surfH]; for (int r = 0; r < _surfH; r++) { int o = r * _surfW; for (int x = 0; x < _surfW; x++) if (MainInk(_surf[o + x])) sp[r]++; }
            long best = long.MaxValue; int top0 = vy0 - ry;
            for (int f = -n; f < _surfH; f++)
            {
                long sad = 0;
                for (int y = 0; y < n && sad < best; y++) { int r = f + top0 + y; int v = r >= 0 && r < _surfH ? sp[r] : 0; sad += Math.Abs(rp[y] - v); }
                if (sad < best) { best = sad; first = f; }
            }
            var cs = new int[_surfW]; var cc = new int[_scrW];
            for (int y = 0; y < n; y++)
            {
                int r = first + top0 + y; if (r >= 0 && r < _surfH) for (int x = 0; x < _surfW; x++) if (MainInk(_surf[r * _surfW + x])) cs[x]++;
                for (int x = 0; x < _scrW; x++) if (_scrInk[y * _scrW + x]) cc[x]++;
            }
            long bestX = long.MaxValue;
            for (int d = -AlignPad; d <= AlignPad; d++)
            {
                long sad = 0;
                for (int x = 0; x < _surfW; x++) { int sx = x + AlignPad + d; int v = sx >= 0 && sx < _scrW ? cc[sx] : 0; sad += Math.Abs(cs[x] - v); }
                if (sad < bestX) { bestX = sad; dx = d; }
            }
            return true;
        }
        int _lastFirst = int.MinValue, _lastDx, _sampleTop;
        int _goodDelta = int.MinValue; bool _convWas, _listWas; readonly Stopwatch _goodClock = Stopwatch.StartNew();
        /// <summary>How long a conversation's screen check may fail before the placement is looked for again (s).</summary>
        public double ConvHoldSeconds = 1.5;
        /// <summary>How long nothing may agree before the game's own pixels are shown instead (s).</summary>
        public double ConvGiveUpSeconds = 4.0;
        // the last good shift of each mode: an options list sits 2 px further in than the spoken lines (every session's log)
        int _listDx = 2, _logDx = 0; bool _confirmed;
        /// <summary>BLANK LINES SHORTER (Josh, 2026-10-09: "the linespacing is perfect for textwrapping, but the line breaks
        /// are too wide"): an empty line between paragraphs takes this share of a line. The newest line keeps its place at
        /// the box's bottom and the text above closes up (showing a little more of the history). Not in a conversation --
        /// its option lines must stay where the game's clicks find them -- nor while a run is shown as the game's pixels.</summary>
        public double BlankLine = 0.4;
        /// <summary>Game px kept clear at the box's right edge BEYOND the left margin (Josh, 2026-10-09: the right margin as wide
        /// as the left, the game's own inset): a line in the visor's face that would reach it is narrowed.</summary>
        public int TextRight = 0;
        /// <summary>The log in vector type. False = draw the game's pixels instead (the caller does).</summary>
        bool LogHost(double e)
        {
            _ownLog = false; _logAnim = false;
            if (!HostText || MemBase == 0 || LogObjAddr == 0 || RecessClosed == null) return false;
            if (!ReadTextFonts()) return false;
            uint obj = Dword(LogObjAddr); if (obj < 0x1000) { TextNote = "no log object"; return false; }
            var ob = Bytes(MemBase + obj, 0x14); if (ob == null) return false;
            uint sp = BitConverter.ToUInt32(ob, 0); int ycur = BitConverter.ToInt16(ob, 6);
            var sh = Bytes(MemBase + sp, 8); if (sh == null) return false;
            int w = BitConverter.ToUInt16(sh, 0), h = BitConverter.ToUInt16(sh, 2); uint px = BitConverter.ToUInt32(sh, 4);
            if (w <= 0 || h <= 0 || w > 2048 || h > 4096) return false;
            if (_surf == null || _surf.Length != w * h) _surf = new byte[w * h];
            IntPtr got; if (!ReadProcessMemory(_proc, new IntPtr(MemBase + px), _surf, new IntPtr(w * h), out got) || got.ToInt64() != w * h) return false;
            _surfW = w; _surfH = h;
            // what is on screen: the recess (closed), or as much of the opened one as the rising screen shows
            int[] rec = (!BoxOpen || RecessOpen == null) ? RecessClosed : RecessOpen;
            int vy0 = rec[1], vy1 = rec[1] + rec[3];
            if (BoxOpen && RecessOpen != null) vy0 = Math.Max(RecessOpen[1], (int)Math.Ceiling(RecessClosed[1] - e * TaExtend));
            if (vy1 - vy0 < 2) return true;
            // which surface row is at the recess's top, and how far in the text sits: the mod's window maths and the last
            // offset that fitted, checked against the screen; else found from the screen
            bool conv = Word(ConvListAddr) != 0;
            // outside a conversation the log is laid out HERE, in the recess the art shows (LogOwn); a conversation keeps the
            // game's own places, where its option clicks are
            if (!conv && LogBoxClosed != null && LogBoxOpen != null) { _ownLog = true; return LogOwn(e, ycur, w, h); }
            int maxOff = Math.Max(0, h - rec[3]), s = Math.Min(Word(LogScrollAddr), maxOff), first = maxOff - s;
            int cs = ConvScrollAddr != 0 && conv ? Word(ConvScrollAddr) : 0;
            // AN OPTIONS LIST is blitted from surface row cs (its scroll) at y 2 -- the FIRST list too, which sits unscrolled
            // at cs 0 (Josh, 2026-10-10: "when the dialogue options first appear ... still glitchy": cs 0 used to mean "not
            // a list", so the first list was placed by the log's maths, never lined up and showed the game's pixels)
            // (the option count is only zeroed when the NEXT list is built, so it outlives a choice: a list is up when there
            // are options and nobody is speaking -- 0x152B28; the other placement is still tried before a search)
            int optN = conv && ConvOptAddr != 0 ? Word(ConvOptAddr) : 0;
            bool speaking = conv && ConvSpeakAddr != 0 && Word(ConvSpeakAddr) != 0;
            bool listMode = cs != 0 || (optN > 0 && optN <= MaxOptions && !speaking);
            int altFirst = listMode ? first : cs - 2;
            if (listMode) first = cs - 2;
            // A NEW MODE STARTS FROM THE GAME'S MATHS, NOT FROM NOTHING (Josh, 2026-10-11: "sometimes still gets stuck in the old
            // text, no hover effects"): every session's log has the list at row cs - 2, +2 px and the spoken lines at the log's
            // rows, 0 px -- but a new list or a new conversation used to forget everything, so the first readings (the game
            // repaints its box -- fill, then text -- and DOSBox's screen lags its memory) found an empty box ("best 0%") and
            // showed the game's pixels until a later reading agreed, up to a second. Now each mode starts trusted, at its own
            // last good dx, and the usual hold covers the torn readings.
            // (until the screen confirms it, a failed check searches at once -- the maths could be wrong -- and only a search
            // that finds nothing either, an empty box, keeps the maths)
            if (listMode != _listWas) { _listWas = listMode; _goodDelta = 0; _goodClock.Restart(); _lastDx = listMode ? _listDx : _logDx; _confirmed = false; }
            // STEADY (Josh, 2026-10-10: the conversation text "flickers"): the game repaints its box every frame -- fills it,
            // then draws the text -- so a reading between the two finds nothing to agree with. The placement is the game's
            // own maths (+ the offset last confirmed); a failed check keeps it, and only a check failing for a whole
            // ConvHoldSeconds goes looking (Search); the game's pixels only if nothing has ever lined up.
            if (conv != _convWas) { _convWas = conv; _goodDelta = 0; _goodClock.Restart(); _lastDx = listMode ? _listDx : _logDx; _confirmed = false; }
            int mathFirst = first; if (_goodDelta != int.MinValue) first = mathFirst + _goodDelta;
            ScreenInkMap(rec[0] - AlignPad, vy0, Math.Min(w, rec[2]) + 2 * AlignPad, vy1 - vy0);
            int dx = _lastDx, inks; double ok = Agree(first, dx, rec[1], vy0, vy1, 2, out inks);
            if (ok >= 0.8 || inks <= 40) { if (inks > 40) { _goodDelta = first - mathFirst; _goodClock.Restart(); _confirmed = true; } }
            else if (_goodDelta != int.MinValue && _confirmed && _goodClock.Elapsed.TotalSeconds < ConvHoldSeconds) { TextHolds++; }
            else
            {
                // (another placement counts only where there IS text to compare: "nothing" agreeing with an empty box -- a torn
                // reading -- scored 100% and was kept as the offset, sending the next real frames astray: the "row -172" lines)
                Func<int, int, double> tryAt = (f, d) => { int ik; double a = Agree(f, d, rec[1], vy0, vy1, 2, out ik); return ik > 40 ? a : 0; };
                for (int d = -6; d <= 6 && ok < 0.8; d++)
                {
                    if (d == 0) continue; double a = tryAt(first, _lastDx + d);
                    if (a > ok) { ok = a; dx = _lastDx + d; }
                }
                if (ok < 0.8 && _lastFirst != int.MinValue) { double a = tryAt(_lastFirst, dx); if (a > ok) { ok = a; first = _lastFirst; } }
                if (ok < 0.8 && altFirst != first) { double a = tryAt(altFirst, dx); if (a > ok) { ok = a; first = altFirst; } }
                if (ok < 0.8)
                {
                    int f2, d2; Search(rec[1], vy0, vy1, out f2, out d2);
                    double a = tryAt(f2, d2);
                    if (a >= 0.8) { ok = a; first = f2; dx = d2; }
                    else if (_goodDelta == int.MinValue || _goodClock.Elapsed.TotalSeconds > ConvGiveUpSeconds)
                    {
                        // (nothing has agreed for ConvGiveUpSeconds: the screen really shows something else -- the game's pixels,
                        // with what the check saw, for the log)
                        TextFallbacks++;
                        TextNote = string.Format("log does not line up with the screen (best {0:P0} at row {1}, {2:+0;-0;0} px; {3}, scroll {4}, {5} options, speaking {6}, box {7}, {8} ink px)", Math.Max(a, ok), f2, d2, listMode ? "options list" : "spoken lines", cs, optN, speaking ? "yes" : "no", BoxOpen ? "open" : "closed", inks);
                        return false;
                    }
                    else { TextHolds++; first = mathFirst + _goodDelta; dx = _lastDx; }      // (keep the game's maths with the last good offset -- never the flicker back to pixels)
                }
                if (ok >= 0.8) { _goodDelta = first - mathFirst; _goodClock.Restart(); _confirmed = true; }
            }
            _lastFirst = first; _lastDx = dx;
            if (ok >= 0.8) { if (listMode) _listDx = dx; else _logDx = dx; }
            int lh = _logFonts[0].H;
            // the lines' places (game rows on screen): the game's own, or closed up round blank lines
            var tops = new System.Collections.Generic.List<int>(); var ys = new System.Collections.Generic.List<double>();
            int bottomRow = first + (vy1 - rec[1]);                                       // the surface row at the box's bottom
            int tBot = ycur - (int)Math.Floor((ycur - (bottomRow - 1)) / (double)lh) * lh;  // the line holding it (aligned to the cursor's)
            bool close = !conv && BlankLine < 1, missed = false;
            double y = rec[1] + (tBot - first);
            for (int t = tBot; t > -lh; t -= lh)
            {
                if (t >= 0 && t + lh <= h)
                {
                    var r = DecodeLine(t); bool blank = true; foreach (var q in r) { if (q.Ok) blank = false; else missed = true; }
                    if (t != tBot) y -= close && blank ? lh * BlankLine : lh;
                    tops.Add(t); ys.Add(close ? y : rec[1] + (t - first));
                }
                else if (t != tBot) y -= lh;
                if ((close ? y : rec[1] + (t - first)) + lh <= vy0) break;
            }
            if (missed && close) { for (int i = 0; i < tops.Count; i++) ys[i] = rec[1] + (tops[i] - first); }      // (game pixels shown: keep the game's places)
            var hnd = GCHandle.Alloc(_work, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(_ww, _wh, _ww * 4, PixelFormat.Format32bppPArgb, hnd.AddrOfPinnedObject()))
                using (var gfx = Graphics.FromImage(bm))
                {
                    int sx = XS(rec[0]);
                    var clip = RectangleF.FromLTRB((float)WX(rec[0]) + sx, (float)WY(vy0), (float)WX(rec[0] + rec[2]) + sx, (float)WY(vy1));
                    gfx.SetClip(clip);
                    gfx.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit; gfx.SmoothingMode = SmoothingMode.AntiAlias;
                    HoverOption = -1;
                    if (conv) OptionHover(gfx, rec, first, dx, sx, vy0, vy1, lh, h);
                    string sample = null; _sampleTop = int.MinValue;
                    for (int i = tops.Count - 1; i >= 0; i--)
                    {
                        int top = tops[i]; double sy = ys[i];
                        if (sy + lh <= vy0 || sy >= vy1) continue;
                        var runs = DecodeLine(top); bool anyText = false;
                        foreach (var r in runs)
                        {
                            if (!r.Ok) { gfx.Flush(); LiveKeyedClip(new[] { rec[0] + dx + r.X, (int)Math.Round(sy), r.W, lh }, vy0, vy1); continue; }
                            anyText = true;
                            if (top == _sampleTop || sample == null) { if (sample == null) { sample = ""; _sampleTop = top; } sample += (sample.Length > 0 ? " " : "") + r.Text; }
                        }
                        if (anyText) gfx.DrawImageUnscaled(LineImage(runs, _logFonts, Math.Max(40, rec[2] - 2 * Math.Max(0, dx) - TextRight), true, LogColour), (int)Math.Round(WX(rec[0] + dx) + sx) - LinePad, (int)Math.Round(WY(sy)) - LinePad);
                    }
                    if (sample != null) TextSample = sample;
                }
            }
            finally { hnd.Free(); }
            TextFrames++; TextNote = string.Format("log in vector type ({0:P0} matches the screen at row {1}, {2:+0;-0;0} px)", ok, first, dx);
            return true;
        }
        // THE OPTION UNDER THE POINTER (Josh, 2026-10-10: dialogue options "hard to click ... clickable naturally"): the game
        // gives no hover feedback at all. Its click (AztConvHit -> 0x180C0) takes the first option whose end row is below the
        // pointer's row, so that option is the one lit here -- what lights is what a click will pick: an amber glass bar
        // across its lines with the visor's brackets. Option i's lines run from option i-1's end; the first option's top is
        // found from the text (its lines upward in the same font, to a blank line).
        public int HoverInk = 0xFFB040;
        // AS MANY OPTIONS AS THE GAME DRAWS (Josh, 2026-10-11: a 17-option list "reverts to the game text"): the game adds an
        // option's end to 0x162B36[] for every option it fits, until the list nears the surface's bottom (0x17FF6: y < H - 80,
        // 598 rows in the mod) -- about 28 one-line options. The cap was 16: past it the list was not seen as a list (the log's
        // maths placed it) and the hover gave up. Anything past this is a bad reading.
        const int MaxOptions = 64;
        void OptionHover(Graphics gfx, int[] rec, int first, int dx, int sx, int vy0, int vy1, int lh, int surfH)
        {
            if (ConvOptAddr == 0 || lh <= 0) return;
            var ob = Bytes(ConvOptAddr, 2 + 2 * MaxOptions); if (ob == null) return;
            int n = BitConverter.ToUInt16(ob, 0); if (n <= 0 || n > MaxOptions) return;
            int cx = CursorX, cy = CursorY;
            if (cx < rec[0] || cx >= rec[0] + rec[2] || cy < vy0 || cy >= vy1) return;
            int row = cy - rec[1] + first, idx = -1;
            var e = new int[n]; for (int i = 0; i < n; i++) e[i] = BitConverter.ToInt16(ob, 2 + 2 * i);
            for (int i = 0; i < n; i++) if (row < e[i]) { idx = i; break; }
            if (idx < 0) return;
            int bot = e[idx], top;
            if (idx > 0) top = e[idx - 1];
            else
            {
                // the first option: its lines upward from its end, in its font, until a blank line (at most four)
                top = bot - lh; int font = -1;
                for (int k = 1; k <= 4; k++)
                {
                    int t = bot - k * lh; if (t < 0 || t + lh > surfH) break;
                    var runs = DecodeLine(t); int f = -1; foreach (var q in runs) if (q.Ok) { f = q.Font; break; }
                    if (f < 0) break; if (font < 0) font = f; else if (f != font) break;
                    top = t;
                }
                if (row < top) return;          // (above the options: the game would still take the first -- nothing is lit)
            }
            if (bot <= top) return;
            HoverOption = idx;
            double gy0 = Math.Max(vy0, rec[1] + (top - first) - 1), gy1 = Math.Min(vy1, rec[1] + (bot - first) + 1);
            if (gy1 - gy0 < 4) return;
            // (within the recess the ART shows -- wider than the game's box, whose first list sits only 2 px in)
            double artL = LogBoxOpen != null ? LogBoxOpen[0] + 6 : rec[0] + 2, artR = LogBoxOpen != null ? LogBoxOpen[0] + LogBoxOpen[2] - 6 : rec[0] + rec[2] - 6;
            float x0 = (float)WX(Math.Max(artL, rec[0] + dx - 10)) + sx, x1 = (float)WX(Math.Min(artR, rec[0] + rec[2] - 6)) + sx, y0 = (float)WY(gy0), y1 = (float)WY(gy1);
            var r = RectangleF.FromLTRB(x0, y0, x1, y1);
            var clipWas = gfx.Clip; gfx.ResetClip(); gfx.SetClip(RectangleF.FromLTRB(x0 - 4, (float)WY(vy0), x1 + 4, (float)WY(vy1)));
            int ink = HoverInk; Func<int, Color> C = a => Color.FromArgb(Math.Max(0, Math.Min(255, a)), (ink >> 16) & 255, (ink >> 8) & 255, ink & 255);
            using (var lg = new LinearGradientBrush(r, C(0), C(0), 0f))
            {
                var cb = new ColorBlend(); cb.Positions = new[] { 0f, 0.08f, 0.85f, 1f }; cb.Colors = new[] { C(70), C(46), C(26), C(0) }; lg.InterpolationColors = cb;
                gfx.FillRectangle(lg, r);
            }
            float L = (float)Math.Max(5, 7 * _s), th = (float)Math.Max(1.5, 1.6 * _s);
            using (var p = new Pen(C(230), th))
            {
                gfx.DrawLines(p, new[] { new PointF(x0 + L, y0), new PointF(x0, y0), new PointF(x0, y1), new PointF(x0 + L, y1) });
                gfx.DrawLines(p, new[] { new PointF(x1 - L, y0), new PointF(x1, y0), new PointF(x1, y1), new PointF(x1 - L, y1) });
            }
            gfx.Clip = clipWas;
        }
        // ---- THE LOG'S OWN LAYOUT (Josh, 2026-10-10: the top line showed cut off under the frame -- "it displays too high ...
        // display as if that is the top of the text when collapsed, with proper padding on top, and the same padding ... when
        // the text log is expanded"; "tightened up, with better mouse scrolling"). The game lays its text from the top of a
        // box that is not where the art's recess is (its first row sat 8 px under the art's bevel, its bottom 16 px short),
        // so outside conversations the host lays the log out itself, from the history the surface holds:
        //   * inside the recess the ART shows (LogBoxClosed / LogBoxOpen, measured off panel-off / panel-exp), LogPadX in
        //     from each side, and top and bottom padding sized so the closed box holds whole lines (21-px lines in 117:
        //     four, 16.5 px each end) -- the same padding open;
        //   * the top line always whole at the top padding: while the text does not fill the box it starts there (as the
        //     game's did); once it does, the view starts at the first line that lets the newest fit, any slack below it;
        //   * SCROLLED HERE, a line at a time, eased (LogScrollSeconds): the wheel and the arrows move whole text lines (blank
        //     lines are passed over), and a view scrolled back stays on its lines as new text arrives. The game's own scroll
        //     word is left alone (its pixels are not what is shown).
        /// <summary>The recess the panel's art shows round the log, closed and open (game px x, y, w, h).</summary>
        public double[] LogBoxClosed, LogBoxOpen;
        /// <summary>Game px from the recess's sides to the text; the least top / bottom padding (the rest is shared out so
        /// the closed box holds whole lines).</summary>
        public double LogPadX = 22, LogPadMinY = 14;
        /// <summary>How quickly a scroll eases to its line (s, the time constant); the wheel's lines a notch (0 = a fifth
        /// of the lines in view, at least one).</summary>
        public double LogScrollSeconds = 0.07; public int LogWheelLines = 0;
        bool _ownLog, _logAnim; int _logTop = -1, _logWant, _logLines; double _logOff = double.NaN; string[] _logSig; double[] _logCum;
        readonly Stopwatch _logClock = new Stopwatch();
        static double Lerp(double a, double b, double f) { return a + (b - a) * f; }
        // where line `idx` of the old history is in the new one: the same run of up to three lines, nearest where the
        // change in length puts it; -1 = gone
        static int Remap(string[] was, int idx, string[] now)
        {
            if (was == null || idx < 0 || idx >= was.Length) return -1;
            int m = Math.Min(3, was.Length - idx), guess = idx + (now.Length - was.Length), best = -1, bestD = int.MaxValue;
            for (int p = 0; p + m <= now.Length; p++)
            {
                bool same = true; for (int k = 0; k < m && same; k++) same = now[p + k] == was[idx + k];
                if (same && Math.Abs(p - guess) < bestD) { bestD = Math.Abs(p - guess); best = p; }
            }
            return best;
        }
        bool LogOwn(double e, int ycur, int w, int h)
        {
            int lh = _logFonts[0].H;
            // the history: every line the surface holds on the cursor's grid, oldest first, blank ends left off
            var tops = new System.Collections.Generic.List<int>(); var blank = new System.Collections.Generic.List<bool>(); var sig = new System.Collections.Generic.List<string>();
            var sb = new System.Text.StringBuilder();
            for (int t = ((ycur % lh) + lh) % lh; t + lh <= h && t <= ycur; t += lh)
            {
                var r = DecodeLine(t); bool b = true; sb.Length = 0;
                foreach (var q in r) { if (q.Ok) { if (q.Text.Trim().Length > 0) b = false; sb.Append(q.Text).Append(' '); } else { b = false; sb.Append('\u0001').Append(q.X).Append(','); } }
                tops.Add(t); blank.Add(b); sig.Add(b ? "" : sb.ToString());
            }
            int a0 = 0, a1 = tops.Count - 1;
            while (a0 <= a1 && blank[a0]) a0++;
            while (a1 >= a0 && blank[a1]) a1--;
            int n = a1 - a0 + 1; if (n < 0) n = 0;
            if (a0 > 0 || n < tops.Count) { tops = tops.GetRange(a0, n); blank = blank.GetRange(a0, n); sig = sig.GetRange(a0, n); }
            var sigA = sig.ToArray();
            var cum = new double[n + 1];
            for (int i = 0; i < n; i++) cum[i + 1] = cum[i] + (blank[i] ? lh * BlankLine : lh);
            // the box: the art's recess, between closed and open as far as the screen has risen
            double[] C = LogBoxClosed, O = LogBoxOpen; double f = Math.Max(0, Math.Min(1, e));
            double bx0 = Lerp(C[0], O[0], f), by0 = Lerp(C[1], O[1], f), bx1 = Lerp(C[0] + C[2], O[0] + O[2], f), by1 = Lerp(C[1] + C[3], O[1] + O[3], f);
            int fit = Math.Max(1, (int)Math.Floor((C[3] - 2 * LogPadMinY) / lh)); double padY = Math.Max(0, (C[3] - fit * lh) / 2.0);
            double aTop = by0 + padY, aBot = by1 - padY, A = aBot - aTop;
            // the view's first line when following the newest
            int follow = 0;
            if (cum[n] > A + 0.5) { follow = n - 1; for (int i = 0; i < n; i++) if (cum[i] >= cum[n] - A - 0.5) { follow = i; break; } }
            // new text (or the surface scrolled): the lines on screen keep their places, and a view scrolled back its lines
            bool changedSig = _logSig == null || sigA.Length != _logSig.Length;
            if (!changedSig) for (int i = 0; i < n; i++) if (sigA[i] != _logSig[i]) { changedSig = true; break; }
            if (changedSig && _logSig != null && _logCum != null && !double.IsNaN(_logOff))
            {
                int oi = 0; while (oi + 1 < _logSig.Length && _logCum[oi + 1] <= _logOff) oi++;
                int p = Remap(_logSig, oi, sigA);
                if (p >= 0) _logOff += cum[p] - _logCum[oi];
                if (_logTop >= 0) { int q = Remap(_logSig, _logTop, sigA); _logTop = q >= 0 ? q : -1; }
            }
            // the wheel / the arrows: whole text lines, blank ones passed over
            int top = _logTop >= 0 ? Math.Min(_logTop, follow) : follow;
            if (_logWant != 0 && n > 0)
            {
                int dir = Math.Sign(_logWant);
                for (int k = Math.Abs(_logWant); k > 0; k--)
                {
                    int nx = top - dir; while (nx >= 0 && nx < follow && blank[nx]) nx -= dir;
                    if (nx < 0 || nx > follow) break; top = nx;
                }
                _logWant = 0;
            }
            _logTop = top >= follow ? -1 : top;
            double target = cum[n] <= A + 0.5 ? 0 : cum[Math.Min(top, n)];
            double dt = _logClock.IsRunning ? _logClock.Elapsed.TotalSeconds : 1; _logClock.Restart();
            if (double.IsNaN(_logOff) || dt > 0.5) _logOff = target;
            else { _logOff += (target - _logOff) * (1 - Math.Exp(-dt / Math.Max(0.01, LogScrollSeconds))); if (Math.Abs(target - _logOff) < 0.25) _logOff = target; }
            _logAnim = _logOff != target; _logSig = sigA; _logCum = cum; _logLines = (int)Math.Floor(A / lh);
            var hnd = GCHandle.Alloc(_work, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(_ww, _wh, _ww * 4, PixelFormat.Format32bppPArgb, hnd.AddrOfPinnedObject()))
                using (var gfx = Graphics.FromImage(bm))
                {
                    int sx = XS(bx0); double tx = bx0 + LogPadX; int lineW = (int)Math.Max(40, bx1 - LogPadX - tx);
                    gfx.SetClip(RectangleF.FromLTRB((float)WX(bx0) + sx, (float)WY(aTop - 1), (float)WX(bx1) + sx, (float)WY(aBot + 1)));
                    gfx.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit; gfx.SmoothingMode = SmoothingMode.AntiAlias;
                    string sample = null;
                    for (int i = 0; i < n; i++)
                    {
                        double sy = aTop + cum[i] - _logOff;
                        // at rest only whole lines (no slivers of the next ones at the padding); while easing, whatever is in
                        // the box, cut at its padding
                        if (blank[i] || (_logAnim ? (sy + lh <= aTop || sy >= aBot) : (sy < aTop - 0.5 || sy + lh > aBot + 0.5))) continue;
                        var runs = DecodeLine(tops[i]); bool any = false;
                        foreach (var r in runs) { if (r.Ok) any = true; else DrawSurfRun(gfx, tops[i], r, tx + r.X, sy, sx); }
                        if (any) gfx.DrawImageUnscaled(LineImage(runs, _logFonts, lineW, true, LogColour), (int)Math.Round(WX(tx) + sx) - LinePad, (int)Math.Round(WY(sy)) - LinePad);
                        if (any) sample = sigA[i];
                    }
                    if (sample != null) TextSample = sample.Trim();
                }
            }
            finally { hnd.Free(); }
            TextFrames++;
            TextNote = string.Format("log laid out by the host: {0} lines, {1}", n, _logTop < 0 ? "following the newest" : "scrolled back to line " + _logTop);
            return true;
        }
        // a run the decoder could not read: the surface's own pixels (the game's palette), at the host's place for it
        void DrawSurfRun(Graphics gfx, int top, HudRun r, double gx, double gy, int sx)
        {
            int lh = _logFonts[0].H, rw = Math.Min(r.W, _surfW - r.X); if (rw <= 0 || r.X < 0 || top < 0 || top + lh > _surfH) return;
            using (var bm = new Bitmap(rw, lh, PixelFormat.Format32bppArgb))
            {
                for (int y = 0; y < lh; y++)
                    for (int x = 0; x < rw; x++)
                    {
                        int v = _surf[(top + y) * _surfW + r.X + x]; if (v == 0) continue;
                        int c = Palette != null && v < Palette.Length ? Palette[v] & 0xFFFFFF : v * 0x010101;
                        bm.SetPixel(x, y, Color.FromArgb(255, (c >> 16) & 255, (c >> 8) & 255, c & 255));
                    }
                var im = gfx.InterpolationMode; gfx.InterpolationMode = InterpolationMode.HighQualityBilinear;
                gfx.DrawImage(bm, new RectangleF((float)WX(gx) + sx, (float)WY(gy), (float)(rw * _s), (float)(lh * _s)));
                gfx.InterpolationMode = im;
            }
        }
        int LogColour(int font)
        {
            int idx = font == 1 ? 55 : 56, def = font == 1 ? 0xBCF8FC : 0xF8B018;
            return Palette != null && Palette.Length > idx && (Palette[idx] & 0xFFFFFF) != 0 ? Palette[idx] & 0xFFFFFF : def;
        }
        // the text face at the display's scale, and where its baseline sits below a line's top (image px)
        Font _tf; float _tfEm, _tfAsc;
        Font TextFont()
        {
            float em = (float)(TextEm * _s);
            if (_tf == null || _tfEm != em)
            {
                if (_tf != null) _tf.Dispose();
                _tf = new Font(TextFace, em, TextBold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel); _tfEm = em;
                var ff = _tf.FontFamily; _tfAsc = em * ff.GetCellAscent(_tf.Style) / ff.GetEmHeight(_tf.Style);
            }
            return _tf;
        }
        void DrawText(Graphics gfx, string text, int rgb, bool outline, float x, float baseY, StringFormat fmt)
        {
            var font = TextFont(); float y = baseY - _tfAsc;
            if (outline)
            {
                float d = Math.Max(1f, (float)(_s * 0.6));
                using (var sb = new SolidBrush(Color.FromArgb(150, 8, 5, 2)))
                    foreach (var o in new[] { new PointF(d, d), new PointF(-d * 0.6f, 0), new PointF(d, 0), new PointF(0, d), new PointF(0, -d * 0.6f) })
                        gfx.DrawString(text, font, sb, x + o.X, y + o.Y, fmt);
            }
            using (var b = new SolidBrush(Color.FromArgb(255, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255))) gfx.DrawString(text, font, b, x, y, fmt);
        }
        // ONE LINE AS AN IMAGE, made once and kept (by its text, places, fonts and the display's scale): a compose then only
        // lays images -- drawing every run with its outline each picture cost ~40 ms at 4K.
        // THE LINE FLOWS IN THE VISOR'S FACE (Josh, 2026-10-09): from the game's first word, each run at the face's own spacing,
        // the game's gaps as that many spaces (its space is floor(2h/7) px) -- squeezing each word into the width the game's
        // Verdana gave it made narrow words look pinched. Only a line that would overrun the box is narrowed, evenly.
        readonly System.Collections.Generic.Dictionary<string, Bitmap> _lineImg = new System.Collections.Generic.Dictionary<string, Bitmap>();
        const int LinePad = 6;
        Bitmap LineImage(HudRun[] runs, HudFont[] fonts, int lineW, bool outline, Func<int, int> colour)
        {
            var key = new System.Text.StringBuilder(); key.Append(_s.ToString("R")).Append('|').Append(TextFace).Append(TextBold).Append(TextEm).Append('|').Append(lineW).Append(outline ? 'o' : '-');
            foreach (var r in runs) if (r.Ok) key.Append('|').Append(r.X).Append(',').Append(r.W).Append(',').Append(r.Font).Append(',').Append(colour(r.Font)).Append(',').Append(r.Text);
            string k = key.ToString(); Bitmap bm;
            if (_lineImg.TryGetValue(k, out bm)) return bm;
            if (_lineImg.Count > 300) { foreach (var b in _lineImg.Values) b.Dispose(); _lineImg.Clear(); }
            int H = fonts[0].H; float space = 2 * H / 7f;
            bm = new Bitmap((int)Math.Ceiling(lineW * _s) + 2 * LinePad, (int)Math.Ceiling(H * _s) + 2 * LinePad, PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(bm))
            using (var fmt = (StringFormat)StringFormat.GenericTypographic.Clone())
            {
                fmt.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit; g.SmoothingMode = SmoothingMode.AntiAlias;
                var font = TextFont(); float spW = g.MeasureString(" ", font, PointF.Empty, fmt).Width;
                // lay the line out: runs one after another, each gap as round(gap / the game's space) spaces (at least one)
                var parts = new System.Collections.Generic.List<Tuple<string, int, float>>(); float x = 0; int prevEnd = int.MinValue, x0 = -1;
                foreach (var r in runs)
                {
                    if (!r.Ok) continue;
                    if (x0 < 0) x0 = r.X;
                    else { int gap = r.X - prevEnd; if (gap > 0) x += spW * Math.Max(1, (int)Math.Round(gap / space)); }
                    parts.Add(Tuple.Create(r.Text, r.Font, x));
                    x += g.MeasureString(r.Text, font, PointF.Empty, fmt).Width; prevEnd = r.X + r.W;
                }
                if (x0 < 0) { _lineImg[k] = bm; return bm; }
                float left = (float)(x0 * _s), avail = (float)(lineW * _s) - left, kx = x > avail && x > 0 ? avail / x : 1f;
                float baseY = (float)(fonts[0].BaseRow * _s) + LinePad;
                g.TranslateTransform(left + LinePad, 0); if (kx < 1f) g.ScaleTransform(kx, 1f);
                foreach (var p in parts) DrawText(g, p.Item1, colour(p.Item2), outline, p.Item3, baseY, fmt);
            }
            _lineImg[k] = bm; return bm;
        }        // the game's pixels for a rectangle, within the visible rows only
        void LiveKeyedClip(int[] g, int vy0, int vy1)
        {
            int y0 = Math.Max(g[1], vy0), y1 = Math.Min(g[1] + g[3], vy1); if (y1 - y0 < 2 || g[2] < 2) return;
            LiveKeyed(new[] { g[0], y0, g[2], y1 - y0 });
        }
        /// <summary>The inventory names' colour: dark sepia, as the game's own font (its full ink is the darkest, index 54).</summary>
        public int InvInk = 0x2A1C0E;
        /// <summary>The inventory's names in vector type, read from the game's list. False = the game's pixels instead.</summary>
        bool InvHost()
        {
            if (!HostText || MemBase == 0 || InvWidgetAddr == 0 || Inventory == null) return false;
            if (!ReadTextFonts() || _invFont == null) return false;
            var wb = Bytes(InvWidgetAddr, 0x14A); if (wb == null) return false;
            int w = BitConverter.ToUInt16(wb, 0), h = BitConverter.ToUInt16(wb, 2), top = BitConverter.ToInt16(wb, 0x12), count = BitConverter.ToInt16(wb, 0x14);
            int vel = BitConverter.ToInt16(wb, 0x144), marked = BitConverter.ToInt16(wb, 0x148), pitch = Word(InvPitchAddr);
            if (vel != 0 || pitch <= 0 || count < 0 || count > 50 || top < 0) return false;    // (scrolling: the game's own pixels for the moment)
            var hnd = GCHandle.Alloc(_work, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(_ww, _wh, _ww * 4, PixelFormat.Format32bppPArgb, hnd.AddrOfPinnedObject()))
                using (var gfx = Graphics.FromImage(bm))
                {
                    int sx = XS(Inventory[0]);
                    gfx.SetClip(RectangleF.FromLTRB((float)WX(Inventory[0]) + sx, (float)WY(Inventory[1]), (float)WX(Inventory[0] + Math.Min(w, Inventory[2])) + sx, (float)WY(Inventory[1] + Math.Min(h, Inventory[3]))));
                    gfx.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit; gfx.SmoothingMode = SmoothingMode.AntiAlias;
                    for (int i = top, y = 0; i < count && y < h; i++, y += pitch)
                    {
                        uint np = BitConverter.ToUInt32(wb, 0x7A + 4 * i); string name;
                        if (!_nameCache.TryGetValue(np, out name))
                        {
                            var nb = Bytes(MemBase + np, 64); if (nb == null) continue;
                            int n = 0; while (n < 64 && nb[n] != 0) n++;
                            name = System.Text.Encoding.GetEncoding(437).GetString(nb, 0, n);
                            if (_nameCache.Count > 200) _nameCache.Clear(); _nameCache[np] = name;
                        }
                        int iw = 0; foreach (char ch in name) { int g = ch == ' ' ? -1 : HudDecoder.GlyphOf(ch); iw += g < 0 || g >= 139 ? 2 * _invFont.H / 7 : _invFont.End[g] - _invFont.Start[g]; }
                        var one = new[] { new HudRun { X = 0, W = iw, Font = 0, Text = name, Ok = true } };
                        gfx.DrawImageUnscaled(LineImage(one, new[] { _invFont }, Math.Min(w, Inventory[2]), false, q => InvInk), (int)Math.Round(WX(Inventory[0]) + sx) - LinePad, (int)Math.Round(WY(Inventory[1] + y)) - LinePad);
                        // the eye (the item held for use): the game's own picture of it
                        int id = BitConverter.ToInt16(wb, 0x16 + 2 * i);
                        if (id == marked && marked >= 0) { gfx.Flush(); LiveKeyedClip(new[] { Inventory[0] + w - 17, Inventory[1] + y, 17, pitch }, Inventory[1], Inventory[1] + Inventory[3]); }
                    }
                }
            }
            finally { hnd.Free(); }
            return true;
        }
        void CopyRect(int[] src, int[] g)
        {
            int sh = XS(g[0]);
            int x0 = Math.Max(0, (int)Math.Floor(WX(g[0])) + sh), x1 = Math.Min(_ww, (int)Math.Ceiling(WX(g[0] + g[2])) + sh);
            int y0 = Math.Max(0, (int)Math.Floor(WY(g[1]))), y1 = Math.Min(_wh, (int)Math.Ceiling(WY(g[1] + g[3])));
            if (x1 > x0) for (int y = y0; y < y1; y++) Buffer.BlockCopy(src, (y * _ww + x0) * 4, _work, (y * _ww + x0) * 4, (x1 - x0) * 4);
        }
        // ---- WHAT THE TEXT SITS ON (wide\bg8.bin): the game's own backgrounds as DOSBox shows them ------
        // The game draws its text and inventory over 8-bit copies of the panel's screens; the host shows only
        // the pixels that are NOT that background, over its own true-colour screens (Josh: no backgrounds).
        int[] _bgPanel, _bgBox; int _bgPX, _bgPY, _bgPW, _bgPH, _bgBX, _bgBY, _bgBW, _bgBH;
        public int BgTolerance = 24;
        public void LoadBg8(string path)
        {
            using (var br = new System.IO.BinaryReader(System.IO.File.OpenRead(path)))
            {
                _bgPX = br.ReadInt32(); _bgPY = br.ReadInt32(); _bgPW = br.ReadInt32(); _bgPH = br.ReadInt32();
                _bgPanel = new int[_bgPW * _bgPH]; for (int i = 0; i < _bgPanel.Length; i++) _bgPanel[i] = br.ReadInt32();
                _bgBX = br.ReadInt32(); _bgBY = br.ReadInt32(); _bgBW = br.ReadInt32(); _bgBH = br.ReadInt32();
                _bgBox = new int[_bgBW * _bgBH]; for (int i = 0; i < _bgBox.Length; i++) _bgBox[i] = br.ReadInt32();
            }
        }
        int Bg(int gx, int gy)
        {
            if (BoxOpen && _bgBox != null) { int bx = gx - _bgBX, by = gy - _bgBY; if (bx >= 0 && by >= 0 && bx < _bgBW && by < _bgBH) return _bgBox[by * _bgBW + bx]; }
            if (_bgPanel != null) { int px = gx - _bgPX, py = gy - _bgPY; if (px >= 0 && py >= 0 && px < _bgPW && py < _bgPH) return _bgPanel[py * _bgPW + px]; }
            return -1;
        }
        bool IsBg(int c, int b)
        {
            if (b < 0) return false;
            return Math.Abs(((c >> 16) & 255) - ((b >> 16) & 255)) + Math.Abs(((c >> 8) & 255) - ((b >> 8) & 255)) + Math.Abs((c & 255) - (b & 255)) <= BgTolerance;
        }
        // a rectangle of the game's screen, 1:1 in place, its background left out: bilinear over the four
        // nearest game pixels with the background ones weighing nothing, laid OVER the art
        void LiveKeyed(int[] g)
        {
            if (g == null) return;
            if (_bgPanel == null) { Live(g); return; }
            // where it goes on the display: moved with its half -- or, if it spans the seam (the health bar),
            // stretched across the gap
            double dx0 = WX(g[0]) + XS(g[0]), dx1 = WX(g[0] + g[2]) + XS(g[0] + g[2] - 1);
            int x0 = Math.Max(0, (int)Math.Floor(dx0)), x1 = Math.Min(_ww, (int)Math.Ceiling(dx1));
            int y0 = Math.Max(0, (int)Math.Floor(WY(g[1]))), y1 = Math.Min(_wh, (int)Math.Ceiling(WY(g[1] + g[3])));
            double inv = 1.0 / _s, kx = g[2] / Math.Max(1.0, dx1 - dx0);
            Parallel.For(y0, y1, y =>
            {
                double fy = (y + _wy + 0.5 - _oy) * inv - 0.5;
                int iy = (int)Math.Floor(fy); iy = Math.Max(g[1], Math.Min(g[1] + g[3] - 2, iy));
                int wy = Math.Max(0, Math.Min(256, (int)((fy - iy) * 256)));
                for (int x = x0; x < x1; x++)
                {
                    double fx = g[0] + (x + 0.5 - dx0) * kx - 0.5; int ix = (int)Math.Floor(fx);
                    ix = Math.Max(g[0], Math.Min(g[0] + g[2] - 2, ix)); int wx = Math.Max(0, Math.Min(256, (int)((fx - ix) * 256)));
                    long a = 0, r = 0, gg = 0, b = 0;
                    for (int k = 0; k < 4; k++)
                    {
                        int sx = ix + (k & 1), sy = iy + (k >> 1);
                        int c = PxNoCursor(sx, sy); if (IsBg(c, Bg(sx, sy))) continue;
                        long wgt = (long)((k & 1) != 0 ? wx : 256 - wx) * ((k >> 1) != 0 ? wy : 256 - wy);
                        a += wgt; r += wgt * ((c >> 16) & 255); gg += wgt * ((c >> 8) & 255); b += wgt * (c & 255);
                    }
                    if (a == 0) continue;
                    int A = (int)Math.Min(255, a >> 8), R = (int)Math.Min(255, r >> 16), G = (int)Math.Min(255, gg >> 16), B = (int)Math.Min(255, b >> 16);
                    int o = y * _ww + x; _work[o] = Over((A << 24) | (R << 16) | (G << 8) | B, _work[o]);
                }
            });
        }
        // a rectangle of the game's screen, bilinear, opaque, onto the same place in the window
        void Live(int[] g)
        {
            if (g == null) return;
            LiveMap(g, new double[] { g[0], g[1], g[2], g[3] });
        }
        // the game's rectangle `src` shown in `dst` (game px), one uniform scale (src w / dst w),
        // pinned to the bottom: a log's newest line is at the bottom; above `src` stays glass
        void LiveMap(int[] src, double[] dst)
        {
            if (src == null || dst == null) return;
            double k = src[2] / dst[2];
            int x0 = Math.Max(0, (int)Math.Round(WX(dst[0]))), x1 = Math.Min(_ww, (int)Math.Round(WX(dst[0] + dst[2])));
            int y0 = Math.Max(0, (int)Math.Round(WY(dst[1]))), y1 = Math.Min(_wh, (int)Math.Round(WY(dst[1] + dst[3])));
            double inv = 1.0 / _s, dBottom = dst[1] + dst[3];
            Parallel.For(y0, y1, y =>
            {
                double gyw = (y + _wy + 0.5 - _oy) * inv;
                double fy = src[1] + src[3] - (dBottom - gyw) * k - 0.5; if (fy < src[1] - 0.5) return;
                int iy = (int)Math.Floor(fy); iy = Math.Max(src[1], Math.Min(src[1] + src[3] - 2, iy));
                int wyf = (int)((fy - iy) * 256); if (wyf < 0) wyf = 0; if (wyf > 256) wyf = 256;
                for (int x = x0; x < x1; x++)
                {
                    double fx = src[0] + ((x + _wx + 0.5 - _ox) * inv - dst[0]) * k - 0.5; int ix = (int)Math.Floor(fx);
                    ix = Math.Max(src[0], Math.Min(src[0] + src[2] - 2, ix)); int wxf = (int)((fx - ix) * 256); if (wxf < 0) wxf = 0; if (wxf > 256) wxf = 256;
                    int a = PxNoCursor(ix, iy), b = PxNoCursor(ix + 1, iy), c = PxNoCursor(ix, iy + 1), d = PxNoCursor(ix + 1, iy + 1);
                    uint nx = (uint)(256 - wxf), ux = (uint)wxf, ny = (uint)(256 - wyf), uy = (uint)wyf;
                    uint tRB = (((uint)a & 0xFF00FF) * nx + ((uint)b & 0xFF00FF) * ux) >> 8 & 0xFF00FF, tG = (((uint)a & 0xFF00) * nx + ((uint)b & 0xFF00) * ux) >> 8 & 0xFF00;
                    uint bRB = (((uint)c & 0xFF00FF) * nx + ((uint)d & 0xFF00FF) * ux) >> 8 & 0xFF00FF, bG = (((uint)c & 0xFF00) * nx + ((uint)d & 0xFF00) * ux) >> 8 & 0xFF00;
                    _work[y * _ww + x] = unchecked((int)0xFF000000) | (int)(((tRB * ny + bRB * uy) >> 8 & 0xFF00FF) | ((tG * ny + bG * uy) >> 8 & 0xFF00));
                }
            });
        }
        static bool In(int[] r, int x, int y) { return r != null && x >= r[0] && y >= r[1] && x < r[0] + r[2] && y < r[1] + r[3]; }
        static bool In(double[] r, double x, double y) { return r != null && x >= r[0] && y >= r[1] && x < r[0] + r[2] && y < r[1] + r[3]; }
        // THE CURSOR: game pixels near it that differ from the reference, wherever this window covers
        // (or the opened box over the view, where the 3D compose leaves the game's drawings out)
        void Cursor()
        {
            if (!_haveRef || _sprN == 0 || (Ptr != null && Ptr.Active)) return;
            int[] hide = _hideNow;
            for (int k = 0; k < _sprN; k++)
                {
                    int gx = CursorX + _sprDx[k], gy = CursorY + _sprDy[k];
                    if (gx < 0 || gx >= ScreenW || gy < Top || gy >= ScreenH) continue;
                    int c = _cur[(gy - Top) * _stride + gx] & 0xFFFFFF;
                    // where the 3D compose shows none of the game's drawings: the opened box, and (3D beneath) the panel rows
                    bool foot = (hide != null && gx >= hide[0] && gx < hide[2] && gy >= hide[1] + ViewY && gy < hide[3] + ViewY) || gy >= OwnFromRow;
                    int x0 = (int)Math.Floor(WX(gx)), x1 = (int)Math.Ceiling(WX(gx + 1)), y0 = (int)Math.Floor(WY(gy)), y1 = (int)Math.Ceiling(WY(gy + 1));
                    for (int y = Math.Max(0, y0); y < Math.Min(_wh, y1); y++)
                        for (int x = Math.Max(0, x0); x < Math.Min(_ww, x1); x++)
                            if (foot || (_work[y * _ww + x] >> 24) != 0) _work[y * _ww + x] = unchecked((int)0xFF000000) | c;
                }
        }

        // ---- the text area's own keys: expand / collapse, scroll up / down ------------------------
        bool _lmbWas; long _lmbDownAt, _lastStep; int _held;
        void Clicks()
        {
            bool down = (GetAsyncKeyState(0x01) & 0x8000) != 0;
            long now = Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
            if (!down) { _lmbWas = false; _held = 0; return; }
            uint fp; GetWindowThreadProcessId(GetForegroundWindow(), out fp);
            if (fp != (uint)_pid) { _lmbWas = down; return; }
            if (!_lmbWas)
            {
                double gx, gy;
                if (Ptr != null && Ptr.Active) { gx = Ptr.GameX; gy = Ptr.GameY; }
                else { POINT p; GetCursorPos(out p); gx = (p.x - _ox) / _s; gy = (p.y - _oy) / _s; }
                double[] up = BoxOpen && LogUpOpen != null ? LogUpOpen : LogUp, dn = BoxOpen && LogDownOpen != null ? LogDownOpen : LogDown;
                _held = In(up, gx, gy) ? 1 : In(dn, gx, gy) ? -1 : 0;
                _lmbDownAt = now; _lastStep = 0;
                if (_held != 0) Step(_held, now);
            }
            else if (_held != 0 && now - _lmbDownAt > 350 && now - _lastStep > 70) Step(_held, now);   // held: repeat
            _lmbWas = down;
        }
        // ---- THE MOUSE WHEEL over the log (Josh, 2026-10-09): a notch scrolls the history a couple of lines -- the same word
        // the scroll keys write. Only while the game is in front and its cursor is over the text screen.
        public bool WheelScroll = true; public int WheelStep = 42; public long WheelNotches;
        WheelHook _wheel; int _wheelRest;
        void Wheel(int delta)
        {
            uint fp; GetWindowThreadProcessId(GetForegroundWindow(), out fp);
            if (fp != (uint)_pid || (LogScrollAddr == 0 && !_ownLog)) { _wheelRest = 0; return; }
            int[] r = BoxOpen && RecessOpen != null ? RecessOpen : RecessClosed; if (r == null) return;
            const int M = 30;       // (the screen's frame round the text counts too)
            if (CursorX < r[0] - M || CursorX >= r[0] + r[2] + M || CursorY < r[1] - M || CursorY >= r[1] + r[3] + M) { _wheelRest = 0; return; }
            _wheelRest += delta; int notches = _wheelRest / 120; _wheelRest -= notches * 120;
            if (notches == 0) return;
            // the host's own layout: whole lines, eased (LogOwn) -- a fifth of the lines in view a notch, at least one
            if (_ownLog) { _logWant += notches * (LogWheelLines > 0 ? LogWheelLines : Math.Max(1, (int)Math.Round(_logLines / 5.0))); WheelNotches += Math.Abs(notches); _dirty = true; return; }
            int v = Word(LogScrollAddr);
            v = Math.Max(0, Math.Min(0xFFFF, v + notches * WheelStep));     // (up = back through the history; the game clamps the far end)
            SetWord(LogScrollAddr, v); WheelNotches += Math.Abs(notches); _dirty = true;
        }
        void Step(int dir, long now)
        {
            if (_ownLog) { _logWant += dir; _lastStep = now; ScrollClicks++; _dirty = true; return; }     // (a line a click, the host's layout)
            int v = Word(LogScrollAddr);
            v = dir > 0 ? Math.Min(0xFFFF, v + LogScrollStep) : Math.Max(0, v - LogScrollStep);   // the game clamps the far end itself
            SetWord(LogScrollAddr, v); _lastStep = now; ScrollClicks++;
        }
        // the game's opened box over the view is this window's to draw while the box is open or moving
        void SetHide()
        {
            bool want = FrameOpen != null && (BoxOpen || Anim > 0);
            int[] h = _hideNow;
            if (!want) { if (h != null) _hideNow = null; return; }
            if (h == null) _hideNow = new[] { FrameOpen[0], FrameOpen[1] - ViewY, FrameOpen[0] + FrameOpen[2], PanelTop - ViewY };
        }

        /// <summary>TESTING, no game or window: one picture for a display of clientW x clientH, from
        /// `screen` (game rows Top..1199 at `stride` px a row) and a reference without the cursor.
        /// modesLit -1 = decide from the screen, as in play; anim 0 closed .. 1 open. Returns the
        /// window's pixels (premultiplied ARGB, WindowW x WindowH).</summary>
        public int[] TestCompose(int clientW, int clientH, int[] screen, int stride, int[] reference, int cursorX, int cursorY, double anim, bool boxOpen, int modesLit)
        {
            double s = Math.Min((double)clientW / ScreenW, (double)clientH / ScreenH);
            _s = s; _ox = (clientW - ScreenW * s) / 2; _oy = (clientH - ScreenH * s) / 2;
            _wx = 0; _ww = clientW; _wy = (int)Math.Round(_oy + Top * s); _wh = (int)Math.Round(_oy + ScreenH * s) - _wy;
            if (_base == null || _work == null || _work.Length != _ww * _wh) Rescale();
            _cur = screen; _stride = stride; _ref = reference != null ? (int[])reference.Clone() : null; _haveRef = reference != null;
            CursorX = cursorX; CursorY = cursorY; Anim = anim; BoxOpen = boxOpen; SetHide();
            Slide = TestSlide;
            _sprN = 0; if (_haveRef) UpdateRef();
            _stab = (int[])screen.Clone(); _last = (int[])screen.Clone(); _cnt = new byte[screen.Length];
            if (GaugeSlot != null) { Health = ReadHealth(); HealthTarget = Health; }
            ModesLit = modesLit < 0 ? ModesShown() : modesLit;
            if (BookView) ComposeBook(); else Compose();
            return (int[])_work.Clone();
        }
        /// <summary>TESTING: the page surface's rows from PanelTop down (what ReadBook would read), for TestCompose with BookView.</summary>
        public void TestBook(byte[] rowsFromPanelTop, int w, int h) { _bookMask = rowsFromPanelTop; _bookW = w; _bookH = h; _bookMaskFrom = PanelTop; }
        /// <summary>TESTING: the whole page surface (rows from 0); the panel keeps the rows it reads in play (from BookFrom).</summary>
        public void TestBookSurface(byte[] surface, int w, int h)
        {
            int from = BookFrom, rows = Math.Min(h, ScreenH) - from; var m = new byte[rows * w];
            Array.Copy(surface, from * w, m, 0, m.Length); _bookMask = m; _bookW = w; _bookH = h; _bookMaskFrom = from;
        }
        public int TestBookFrom { get { return BookFrom; } }
        /// <summary>TESTING: scroll the host-laid log by `lines` text lines (+ = back through the history), as the wheel does.</summary>
        public void TestLogScroll(int lines) { _logWant += lines; }
        /// <summary>TESTING: the slide position TestCompose draws at.</summary>
        public double TestSlide = 1;
        public int WindowW { get { return _ww; } }
        public int WindowH { get { return _wh; } }
        public int WindowY { get { return _wy; } }

        // ---- the thread ----------------------------------------------------------------------------
        void WindowThread()
        {
            try
            {
                try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
                _wndProc = WndProc;
                _cls = "AztPanel" + Stopwatch.GetTimestamp();
                var wc = new WNDCLASSEX();
                wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX)); wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
                wc.hInstance = GetModuleHandleW(IntPtr.Zero); wc.lpszClassName = _cls;
                if (RegisterClassExW(ref wc) == 0) { StartError = "RegisterClassEx failed: " + Marshal.GetLastWin32Error(); return; }
                _hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                                        _cls, "", WS_POPUP, 0, 0, 16, 16, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_hwnd == IntPtr.Zero) { StartError = "CreateWindowEx failed: " + Marshal.GetLastWin32Error(); return; }
            }
            finally { _up.Set(); }
            if (WheelScroll) { try { _wheel = new WheelHook(); _wheel.Start(); } catch { _wheel = null; } }
            var placeClock = Stopwatch.StartNew(); var animClock = Stopwatch.StartNew(); bool placed = false, ovWas = false, everShown = false;
            var hiddenClock = Stopwatch.StartNew();
            SetHide();
            while (_run)
            {
                MSG m; while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
                try
                {
                    if (!placed || placeClock.ElapsedMilliseconds >= 250) { placed = Place(); placeClock.Restart(); if (Shown) SetWindowPos(_hwnd, Overlay.TopSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); }
                    // BLIND: shown with the view's window before the game's screen has been found (it is found
                    // after the visor boot) -- the art only, sliding in as the boot starts (Josh, 2026-10-07)
                    bool located = _ov.Located;
                    bool want = placed && _ov.Shown && (located || Blind) && !HoldOff;
                    if (want && !ovWas) { SetWindowPos(_hwnd, Overlay.TopSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); _dirty = true; }   // the view's window was just raised: go back above it
                    ovWas = want;
                    double dt = animClock.Elapsed.TotalSeconds; animClock.Restart();
                    if (!want) { if (Shown) { ShowWindow(_hwnd, SW_HIDE); Shown = false; hiddenClock.Restart(); } Thread.Sleep(20); continue; }
                    // about to show after a while away (or for the first time): the halves slide in
                    if (!Shown && _seamW >= 0 && (!everShown || hiddenClock.Elapsed.TotalSeconds >= HideToSlide)) { Slide = 0; Slides++; _dirty = true; }
                    if (Slide < 1) { Slide = Math.Min(1, Slide + dt / Math.Max(0.05, SlideSeconds)); _dirty = true; }
                    if (!BookView) Clicks();                                  // (no panel keys while a page covers them)
                    if (_wheel != null) { int wd = _wheel.Take(); if (wd != 0 && !BookView) Wheel(wd); }
                    if (_power != null) _dirty = true;                     // the keys' power-up is running
                    if (!located)
                    {
                        // the boot's health fill, with no reading of the game's own yet
                        if (Health >= 0 && Math.Abs(Health - HealthTarget) > 1e-4)
                        { double st = dt * HealthRate; Health = HealthTarget > Health ? Math.Min(HealthTarget, Health + st) : Math.Max(HealthTarget, Health - st); _dirty = true; }
                        if (_dirty)
                        {
                            Compose(); Present(); _dirty = false;
                            if (!Shown) { ShowWindow(_hwnd, SW_SHOWNOACTIVATE); SetWindowPos(_hwnd, Overlay.TopSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); Shown = true; everShown = true; }
                        }
                    }
                    else if (BookView)
                    {
                        // the book / item view: no art, the page over black (re-read 4x a second: pages turn)
                        if (ReadScreen())
                        {
                            CursorX = Word(CursorXAddr); CursorY = Word(CursorYAddr);
                            UpdateRef();                                                  // (keeps the cursor's shape learnt: it is drawn over the page too)
                            if (!_bookWas || _bookClock.ElapsedMilliseconds >= 250) { ReadBook(); _dirty = true; }
                            _bookWas = true;
                            bool changedB = _dirty;
                            if (!changedB) for (int i = 0; i < _cur.Length; i++) if (_cur[i] != _prev[i]) { changedB = true; break; }
                            if (changedB)
                            {
                                ComposeBook(); Present(); _dirty = false;
                                Buffer.BlockCopy(_cur, 0, _prev, 0, _cur.Length * 4);
                                if (!Shown) { ShowWindow(_hwnd, SW_SHOWNOACTIVATE); SetWindowPos(_hwnd, Overlay.TopSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); Shown = true; everShown = true; }
                            }
                        }
                    }
                    else if (ReadScreen())
                    {
                        if (_bookWas) { _bookWas = false; _dirty = true; }            // back from the book: the art again
                        CursorX = Word(CursorXAddr); CursorY = Word(CursorYAddr);
                        bool openWas = BoxOpen;
                        BoxOpen = Word(BoxBigAddr) != 0 || Word(ConvListAddr) != 0;
                        if (BoxOpen != openWas) Toggles++;
                        UpdateRef();
                        bool steadyChanged = Steady();
                        if (GaugeSlot != null)
                        {
                            double ht = ReadHealth();
                            if (ht >= 0) { HealthTarget = ht; if (Health < 0) { Health = ht; steadyChanged = true; } }
                            if (Health >= 0 && Math.Abs(Health - HealthTarget) > 1e-4)
                            { double st = dt * HealthRate; Health = HealthTarget > Health ? Math.Min(HealthTarget, Health + st) : Math.Max(HealthTarget, Health - st); steadyChanged = true; }
                        }
                        int lit = ModesShown();
                        double target = BoxOpen ? 1 : 0, was = Anim;
                        if (Anim != target) { double stepA = dt / Math.Max(0.05, AnimSeconds); Anim = target > Anim ? Math.Min(target, Anim + stepA) : Math.Max(target, Anim - stepA); }
                        SetHide();
                        bool changed = _dirty || lit != ModesLit || Anim != was || steadyChanged || _logAnim;      // (_logAnim: the log easing to its line)
                        if (!changed) for (int i = 0; i < _cur.Length; i++) if (_cur[i] != _prev[i]) { changed = true; break; }
                        ModesLit = lit;
                        if (changed)
                        {
                            Compose(); Present(); _dirty = false;
                            Buffer.BlockCopy(_cur, 0, _prev, 0, _cur.Length * 4);     // what this picture was made from
                            if (!Shown) { ShowWindow(_hwnd, SW_SHOWNOACTIVATE); SetWindowPos(_hwnd, Overlay.TopSlot(), 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE); Shown = true; everShown = true; }
                        }
                    }
                }
                catch (Exception e) { StartError = e.GetType().Name + ": " + e.Message; }
                Thread.Sleep((Anim != 0 && Anim != 1) || Slide < 1 || _logAnim ? 4 : 10);
            }
            if (_wheel != null) { _wheel.Dispose(); _wheel = null; }
            ShowWindow(_hwnd, SW_HIDE); Shown = false; FreeDib();
            DestroyWindow(_hwnd); _hwnd = IntPtr.Zero;
            UnregisterClassW(_cls, GetModuleHandleW(IntPtr.Zero));
        }
    }

    /// <summary>The mouse wheel, wherever the pointer is (a low-level hook on its own thread with its own message loop, so a
    /// slow picture never holds up the system's mouse). Take() returns the wheel's movement since the last call (120 a notch,
    /// positive = away from the user).</summary>
    public class WheelHook : IDisposable
    {
        delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint msg; public IntPtr w, l; public uint time; public int x, y; }
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookExW(int id, HookProc proc, IntPtr mod, uint tid);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint lo, uint hi);
        [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint tid, uint msg, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr n);
        int _delta; HookProc _proc; Thread _t; volatile uint _tid; IntPtr _hook;
        public bool Hooked { get { return _hook != IntPtr.Zero; } }
        public void Start() { _t = new Thread(Run) { IsBackground = true, Name = "AztWheel" }; _t.Start(); }
        void Run()
        {
            _tid = GetCurrentThreadId(); _proc = Proc;
            _hook = SetWindowsHookExW(14, _proc, GetModuleHandleW(IntPtr.Zero), 0);       // WH_MOUSE_LL
            MSG m; while (GetMessageW(out m, IntPtr.Zero, 0, 0) > 0) { }
            if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
        }
        IntPtr Proc(int code, IntPtr w, IntPtr l)
        {
            if (code >= 0 && w.ToInt64() == 0x020A) { int md = Marshal.ReadInt32(l, 8); Interlocked.Add(ref _delta, (short)(md >> 16)); }   // WM_MOUSEWHEEL: mouseData's high word
            return CallNextHookEx(_hook, code, w, l);
        }
        public int Take() { return Interlocked.Exchange(ref _delta, 0); }
        public void Dispose() { if (_tid != 0) PostThreadMessageW(_tid, 0x0012, IntPtr.Zero, IntPtr.Zero); }
    }
    // ==== THE HUD'S TEXT IN VECTOR TYPE (Josh, 2026-10-09: the log and inventory text "too hard to read" -- "crisp,
    // legible fonts with consistent linespacing", the visor's approach) ===============================================
    // The game keeps no history of its log as text (docs\text-render-RE.md: each line's bytes are freed once drawn; the
    // scrollback is only pixels in its surface), so the host READS THE SURFACE BACK: every glyph the game draws is an exact
    // copy of its font sheet's columns (index 0 transparent), so a line's ink runs segment into glyphs by exact match --
    // the same text, at the same places, in the same font (gold / cyan), whatever printed it. The panel then draws it in
    // Verdana (the face the game's sheets were made from) at the display's own resolution. Anything that does not decode
    // is shown as the game's pixels, as before.

    /// <summary>One of the game's bitmap fonts: its sheet (palette indices, index 0 = nothing) and the glyph table
    /// (139 glyphs from '!', start/end columns; advance = end - start).</summary>
    public class HudFont
    {
        public int SheetW, H; public byte[] Sheet; public int[] Start = new int[139], End = new int[139];
        /// <summary>The baseline, rows from the top of a line: the bottom of 'x''s main ink (not its shadow).</summary>
        public int BaseRow;
        /// <summary>Its main ink (palette index): the most used index that is not the shadow (54).</summary>
        public int Ink = -1;
        public HudFont(byte[] sheet, int w, int h, int[] start, int[] end)
        {
            Sheet = sheet; SheetW = w; H = h; Array.Copy(start, Start, 139); Array.Copy(end, End, 139);
            var hist = new int[256]; foreach (var b in sheet) hist[b]++;
            int best = 0; for (int i = 1; i < 256; i++) if (i != Shadow && hist[i] > best) { best = hist[i]; Ink = i; }
            int gx = 'x' - 0x21; BaseRow = h * 3 / 4;
            for (int r = h - 1; r >= 0; r--)
            {
                bool any = false; for (int c = Start[gx]; c < End[gx] && !any; c++) { int v = sheet[r * w + c]; if (v != 0 && v != Shadow) any = true; }
                if (any) { BaseRow = r + 1; break; }
            }
        }
        public const int Shadow = 54;
        /// <summary>The glyph table the game's loader (0x38BBB) builds from a sheet: runs between fully blank columns, +1
        /// on a sheet with one ink only.</summary>
        public static HudFont FromSheet(byte[] sheet, int w, int h)
        {
            int ink = -1; bool single = true;
            foreach (var b in sheet) { if (b == 0) continue; if (ink < 0) ink = b; else if (b != ink) { single = false; break; } }
            int one = single ? 1 : 0, col = 0; var st = new int[139]; var en = new int[139];
            Func<int, bool> blank = c => { for (int r = 0; r < h; r++) if (sheet[r * w + c] != 0) return false; return true; };
            for (int g = 0; g < 139; g++)
            {
                while (col < w && blank(col)) col++;
                st[g] = col;
                while (col < w - one && !blank(col)) col++;
                en[g] = col + one; col = en[g];
            }
            return new HudFont(sheet, w, h, st, en);
        }
    }
    /// <summary>A run of decoded text on one line: where it starts (surface x), how wide it is there, which font (index into
    /// the fonts given), the text; Ok false = it did not decode (show the game's pixels there).</summary>
    public struct HudRun { public int X, W, Font; public string Text; public bool Ok; }

    public class HudDecoder
    {
        readonly HudFont[] _f; readonly int _rows;
        readonly System.Collections.Generic.Dictionary<long, System.Collections.Generic.List<int>> _byCol = new System.Collections.Generic.Dictionary<long, System.Collections.Generic.List<int>>();
        static readonly System.Text.Encoding Cp437 = GetCp437();
        static System.Text.Encoding GetCp437() { try { return System.Text.Encoding.GetEncoding(437); } catch { return null; } }
        /// <summary>Fonts of one line height. The last row of a line is not compared: the game's scroll (0x39281) moves one
        /// row too few, so after a scroll each line's last row holds stale pixels.</summary>
        public HudDecoder(HudFont[] fonts)
        {
            _f = fonts; _rows = fonts[0].H - 1;
            for (int f = 0; f < fonts.Length; f++)
                for (int g = 0; g < 139; g++)
                {
                    if (fonts[f].End[g] <= fonts[f].Start[g]) continue;
                    bool ink = false; for (int r = 0; r < _rows && !ink; r++) for (int c = fonts[f].Start[g]; c < fonts[f].End[g]; c++) if (fonts[f].Sheet[r * fonts[f].SheetW + c] != 0) { ink = true; break; }
                    if (!ink) continue;                 // (nothing to see above its last row: an underscore -- passed over as blank)
                    long k = ColKey(fonts[f].Sheet, fonts[f].SheetW, 0, fonts[f].Start[g]);
                    System.Collections.Generic.List<int> l; if (!_byCol.TryGetValue(k, out l)) _byCol[k] = l = new System.Collections.Generic.List<int>();
                    l.Add((f << 8) | g);
                }
        }
        long ColKey(byte[] pix, int w, int top, int x)
        {
            long h = 1469598103934665603L; for (int r = 0; r < _rows; r++) { h ^= pix[(top + r) * w + x]; h *= 1099511628211L; }
            return h;
        }
        bool Blank(byte[] pix, int w, int top, int x) { for (int r = 0; r < _rows; r++) if (pix[(top + r) * w + x] != 0) return false; return true; }
        bool Match(byte[] pix, int w, int top, int x, HudFont f, int g)
        {
            int s = f.Start[g], n = f.End[g] - s;
            for (int r = 0; r < _rows; r++)
            {
                int o = (top + r) * w + x, so = r * f.SheetW + s;
                for (int c = 0; c < n; c++) if (pix[o + c] != f.Sheet[so + c]) return false;
            }
            return true;
        }
        public static char CharOf(int g)
        {
            int code = g + 0x21; if (code < 0x80 || Cp437 == null) return (char)code;
            return Cp437.GetString(new[] { (byte)code })[0];
        }
        /// <summary>One line of the surface (rows top..top+H-1, w wide), read left to right as one path: blank columns are
        /// passed over, every inked column must belong to a glyph that matches exactly (rows 0..H-2) -- a glyph may begin on
        /// a column that is blank in those rows ('j''s hook is only in the last row). Fewest glyphs wins; a column no glyph
        /// explains is passed over at a high cost and reported as a run that did not decode.</summary>
        public HudRun[] Line(byte[] pix, int w, int top)
        {
            const int Inf = int.MaxValue / 2, Miss = 1000;
            var blank = new bool[w]; for (int x = 0; x < w; x++) blank[x] = Blank(pix, w, top, x);
            var cost = new int[w + 1]; var prev = new int[w + 1]; var code = new int[w + 1];
            for (int i = 1; i <= w; i++) cost[i] = Inf; prev[0] = -1;
            for (int p = 0; p < w; p++)
            {
                if (cost[p] >= Inf) continue;
                int cs = cost[p] + (blank[p] ? 0 : Miss);
                if (cs < cost[p + 1]) { cost[p + 1] = cs; prev[p + 1] = p; code[p + 1] = -1; }
                System.Collections.Generic.List<int> cand; if (!_byCol.TryGetValue(ColKey(pix, w, top, p), out cand)) continue;
                foreach (int fc in cand)
                {
                    HudFont f = _f[fc >> 8]; int g = fc & 255, gw = f.End[g] - f.Start[g];
                    if (p + gw > w || cost[p] + 1 >= cost[p + gw]) continue;
                    if (Match(pix, w, top, p, f, g)) { cost[p + gw] = cost[p] + 1; prev[p + gw] = p; code[p + gw] = fc; }
                }
            }
            var steps = new System.Collections.Generic.List<int>(); for (int p = w; p > 0; p = prev[p]) steps.Add(p);
            steps.Reverse();
            var runs = new System.Collections.Generic.List<HudRun>();
            var sb = new System.Text.StringBuilder(); int start = 0, font = -1, missFrom = -1;
            Action flush = () => { if (sb.Length > 0) runs.Add(new HudRun { X = start, W = 0, Font = font, Text = sb.ToString(), Ok = true }); sb.Clear(); };
            int last = 0;
            foreach (int p in steps)
            {
                int q = prev[p], fc = code[p];
                if (fc < 0)
                {
                    flush();
                    if (!blank[q]) { if (missFrom < 0) missFrom = q; }
                    else if (missFrom >= 0) { runs.Add(new HudRun { X = missFrom, W = q - missFrom, Font = -1, Ok = false }); missFrom = -1; }
                }
                else
                {
                    if (missFrom >= 0) { runs.Add(new HudRun { X = missFrom, W = q - missFrom, Font = -1, Ok = false }); missFrom = -1; }
                    int ff = fc >> 8;
                    if (sb.Length > 0 && ff != font) flush();
                    if (sb.Length == 0) start = q;
                    font = ff; sb.Append(CharOf(fc & 255));
                }
                last = p;
            }
            flush(); if (missFrom >= 0) runs.Add(new HudRun { X = missFrom, W = w - missFrom, Font = -1, Ok = false });
            // each run's width: to the end of its last glyph
            for (int i = 0; i < runs.Count; i++)
            {
                var r = runs[i]; if (!r.Ok) continue;
                int x = r.X; foreach (char ch in r.Text) { int g = GlyphOf(ch); x += _f[r.Font].End[g] - _f[r.Font].Start[g]; }
                r.W = x - r.X; runs[i] = r;
            }
            return runs.ToArray();
        }
        public static int GlyphOf(char ch)
        {
            int code = ch; if (code >= 0x80 && Cp437 != null) code = Cp437.GetBytes(new[] { ch })[0];
            return code - 0x21;
        }        /// <summary>TESTING: draws text into a surface as the game does (0x38EC8 / 0x39120: glyph columns copied, index 0
        /// transparent; a space advances floor(2h/7)). Returns the x it ended at.</summary>
        public static int DrawAsGame(byte[] pix, int w, int x, int top, HudFont f, string s)
        {
            foreach (char ch in s)
            {
                if (ch == ' ') { x += 2 * f.H / 7; continue; }
                int code = ch; if (code >= 0x80 && Cp437 != null) code = Cp437.GetBytes(new[] { ch })[0];
                int g = code - 0x21; if (g < 0 || g >= 139) continue;
                int st = f.Start[g], n = f.End[g] - st;
                for (int r = 0; r < f.H; r++) for (int c = 0; c < n && x + c < w; c++) { byte v = f.Sheet[r * f.SheetW + st + c]; if (v != 0) pix[(top + r) * w + x + c] = v; }
                x += n;
            }
            return x;
        }
    }
}
