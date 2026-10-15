// Keys.cs -- is a key down, in the game's own window?
//
// The helmet lamp belongs to the host renderer, so its switch does too: the key is read
// here, straight from Windows, and counts only while the window in front belongs to the
// game's process -- an F typed into anything else must not flick a light in a game running
// behind it. Nothing is patched into the game for this, and the game still receives the key.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace AztTool
{
    public static class Keys
    {
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

        public static bool DownInProcess(int vKey, int pid)
        {
            if ((GetAsyncKeyState(vKey) & 0x8000) == 0) return false;
            uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p);
            return p == (uint)pid;
        }
    }

    /// <summary>
    /// SPACE AFTER A SPOKEN LINE (Josh, 2026-10-11). The game's SPACE draws and holsters the weapon ("Toggle MS7 Sniper sight",
    /// 0x136D8 -> 0x131E1), and RaptorMod's Space also SKIPS a spoken line (AztSkipKey). So a Space pressed as a line ends --
    /// or a second tap after a skip -- drew the weapon, and with it out there are no pick-up / use cursors and the left button
    /// fires: "I could not pick up the key in the well" (both clicks there were shots).
    ///   * While a line is being spoken (word 0x152B28) Space goes to the game as always: it skips.
    ///   * For QuietMs after a line ends (naturally or skipped) Space is NOT passed to the game -- a low-level keyboard hook
    ///     drops it, and its key-up. Each dropped press starts the quiet again, so a held or hammered Space stays quiet.
    ///   * A Space still HELD when the line ends gets its key-up sent at once: DOSBox repeats a held key by itself, and the
    ///     repeats would reach the game after the line.
    /// Only while the game's window is in front. No game code: the overlay is full (2 bytes free, 2026-10-11).
    /// </summary>
    public class SpaceGuard : IDisposable
    {
        delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint msg; public IntPtr w, l; public uint time; public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookExW(int id, HookProc proc, IntPtr mod, uint tid);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint lo, uint hi);
        [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint tid, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr n);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, [Out] byte[] buf, IntPtr size, out IntPtr read);
        const int VK_SPACE = 0x20; const ushort SC_SPACE = 0x39; const uint KEYEVENTF_KEYUP = 2;
        static readonly IntPtr Marker = new IntPtr(0x41A75A0E);      // (our own key-up: let through)

        /// <summary>The game's "a line is being spoken" word (host address: MemBase + 0x152B28 + obj2 delta).</summary>
        public long SpeakAddr;
        /// <summary>DOSBox's process: Space is only held back while its window is in front.</summary>
        public int GamePid;
        /// <summary>How long after a line ends Space is held back (ms).</summary>
        public int QuietMs = 1000;
        // ---- for the report --------------------------------------------------------------------------------------------
        public long Swallowed, Passed, LineEnds, EarlyUps, ReadFails; public string StartError = "";
        public bool Hooked { get { return _hook != IntPtr.Zero; } }

        readonly IntPtr _proc; readonly Stopwatch _clock = Stopwatch.StartNew();
        HookProc _hookProc; Thread _hookT, _pollT; volatile uint _tid; IntPtr _hook; volatile bool _run;
        long _endedAt = long.MinValue;          // (clock ms when the last line ended; MinValue = none yet)
        volatile bool _gameDown;                // the game was given Space's key-down and not yet its key-up
        bool _wasSpeaking;
        readonly byte[] _b2 = new byte[2];      // (the poll thread's)
        readonly byte[] _h2 = new byte[2];      // (the hook's)

        public SpaceGuard(int pid)
        {
            _proc = OpenProcess(0x0410, false, pid);      // (read, query)
            if (_proc == IntPtr.Zero) throw new InvalidOperationException("OpenProcess failed: " + Marshal.GetLastWin32Error());
            GamePid = pid;
        }
        public bool Start()
        {
            _run = true;
            _pollT = new Thread(Poll) { IsBackground = true, Name = "AztSpaceGuardPoll" }; _pollT.Start();
            var up = new ManualResetEvent(false);
            _hookT = new Thread(() => Run(up)) { IsBackground = true, Name = "AztSpaceGuard" }; _hookT.Start();
            up.WaitOne(2000);
            return Hooked;
        }
        public void Dispose()
        {
            _run = false;
            if (_tid != 0) PostThreadMessageW(_tid, 0x0012, IntPtr.Zero, IntPtr.Zero);       // WM_QUIT: the hook thread unhooks
            if (_hookT != null) { _hookT.Join(1000); _hookT = null; }
            if (_pollT != null) { _pollT.Join(1000); _pollT = null; }
            if (_proc != IntPtr.Zero) CloseHandle(_proc);
        }

        int Speaking(byte[] b)
        {
            IntPtr got;
            if (SpeakAddr == 0 || !ReadProcessMemory(_proc, new IntPtr(SpeakAddr), b, new IntPtr(2), out got)) { ReadFails++; return -1; }
            return b[0] | (b[1] << 8);
        }
        bool GameInFront() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p == (uint)GamePid; }

        // the line's end, seen within a few ms (and a Space still held then let go of, for the game)
        void Poll()
        {
            while (_run)
            {
                int sp = Speaking(_b2);
                if (sp >= 0)
                {
                    bool now = sp != 0;
                    if (_wasSpeaking && !now)
                    {
                        Interlocked.Exchange(ref _endedAt, _clock.ElapsedMilliseconds); LineEnds++;
                        if (_gameDown && GameInFront()) { SendSpaceUp(); _gameDown = false; EarlyUps++; }
                    }
                    _wasSpeaking = now;
                }
                Thread.Sleep(4);
            }
        }
        void SendSpaceUp()
        {
            var inp = new INPUT[1]; inp[0].type = 1;
            inp[0].u.ki = new KEYBDINPUT { wVk = VK_SPACE, wScan = SC_SPACE, dwFlags = KEYEVENTF_KEYUP, time = 0, dwExtraInfo = Marker };
            SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
        }

        void Run(ManualResetEvent up)
        {
            try
            {
                _tid = GetCurrentThreadId(); _hookProc = Proc;
                _hook = SetWindowsHookExW(13, _hookProc, GetModuleHandleW(IntPtr.Zero), 0);       // WH_KEYBOARD_LL
                if (_hook == IntPtr.Zero) StartError = "SetWindowsHookEx failed: " + Marshal.GetLastWin32Error();
            }
            finally { up.Set(); }
            if (_hook == IntPtr.Zero) return;
            MSG m; while (GetMessageW(out m, IntPtr.Zero, 0, 0) > 0) { }
            UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero;
        }
        IntPtr Proc(int code, IntPtr w, IntPtr l)
        {
            try
            {
                // (KBDLLHOOKSTRUCT: vkCode +0, scanCode, flags, time, then dwExtraInfo at +16 in both 32- and 64-bit)
                if (code >= 0 && Marshal.ReadInt32(l, 0) == VK_SPACE && Marshal.ReadIntPtr(l, 16) != Marker)
                {
                    int msg = w.ToInt32();
                    if (msg == 0x100 || msg == 0x104)                                   // key down (or a repeat of it)
                    {
                        if (GameInFront())
                        {
                            long now = _clock.ElapsedMilliseconds, ended = Interlocked.Read(ref _endedAt);
                            bool quiet = ended != long.MinValue && now - ended < QuietMs && Speaking(_h2) == 0;
                            if (quiet) { Interlocked.Exchange(ref _endedAt, now); Swallowed++; return new IntPtr(1); }
                            if (!_gameDown) Passed++;
                            _gameDown = true;
                        }
                    }
                    else if (msg == 0x101 || msg == 0x105)                              // key up
                    {
                        if (_gameDown) _gameDown = false;                               // (the game had the down: it gets the up)
                        else if (GameInFront()) return new IntPtr(1);                   // (it never had it, or had its up already)
                    }
                }
            }
            catch { }
            return CallNextHookEx(_hook, code, w, l);
        }

        /// <summary>OFFLINE: what the hook would do with a Space down / up now (true = let through), and a line's end.</summary>
        public bool TestKey(bool down)
        {
            // (the hook's own decision, without Windows: the game counts as in front)
            long now = _clock.ElapsedMilliseconds, ended = Interlocked.Read(ref _endedAt);
            if (down)
            {
                bool quiet = ended != long.MinValue && now - ended < QuietMs && Speaking(_h2) == 0;
                if (quiet) { Interlocked.Exchange(ref _endedAt, now); Swallowed++; return false; }
                if (!_gameDown) Passed++;
                _gameDown = true; return true;
            }
            if (_gameDown) { _gameDown = false; return true; }
            return false;
        }
        public bool TestGameDown { get { return _gameDown; } }
    }

    /// <summary>THE MOUSE ITSELF, while the 3D map is up (Josh, 2026-10-14: "The user can click to rotate the map"). DOSBox holds
    /// the mouse captured, so the pointer the game shows says nothing about a drag; Windows' raw input still reports every
    /// movement and button to a window that asks for it (RIDEV_INPUTSINK, even in the background). A message-only window on its
    /// own thread: movement while the left button is held (DragX / DragY), the wheel, and whether the left button is down --
    /// counted only while the window in front belongs to the game (or to this process). One process can have only one raw
    /// mouse target, so whatever was registered before (the host pointer's) is put back when this stops.</summary>
    public sealed class RawMouse : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort usUsagePage, usUsage; public uint dwFlags; public IntPtr hwndTarget; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct WNDCLASSEX { public int cbSize; public uint style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
        delegate IntPtr WndProcD(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClassExW(ref WNDCLASSEX c);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool UnregisterClassW(string name, IntPtr inst);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateWindowExW(int ex, string cls, string title, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern bool PeekMessageW(out MSG m, IntPtr h, uint lo, uint hi, uint remove);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devs, uint n, uint size);
        [DllImport("user32.dll", SetLastError = true)] static extern int GetRegisteredRawInputDevices([Out] RAWINPUTDEVICE[] devs, ref uint n, uint size);
        [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr hRaw, uint cmd, IntPtr data, ref uint size, uint headerSize);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
        const uint WM_INPUT = 0xFF, RIDEV_INPUTSINK = 0x100, RIDEV_REMOVE = 0x1, RID_INPUT = 0x10000003;

        public int GamePid;
        public string StartError;
        public long Inputs;
        int _dx, _dy, _wheel; volatile bool _left;
        Thread _th; volatile bool _run; IntPtr _hwnd; string _cls; WndProcD _wp; RAWINPUTDEVICE[] _before;
        readonly ManualResetEvent _up = new ManualResetEvent(false);
        static readonly uint _ownPid = (uint)Process.GetCurrentProcess().Id;

        public bool Start()
        {
            if (_th != null) return StartError == null;
            _run = true; _th = new Thread(Loop) { IsBackground = true, Name = "AztRawMouse" }; _th.Start();
            _up.WaitOne(2000);
            return StartError == null;
        }
        /// <summary>Movement with the left button held, and the wheel, since the last call (and whether the button is down now).</summary>
        public void Take(out int dragX, out int dragY, out int wheel, out bool left)
        {
            dragX = Interlocked.Exchange(ref _dx, 0); dragY = Interlocked.Exchange(ref _dy, 0); wheel = Interlocked.Exchange(ref _wheel, 0); left = _left;
        }
        bool Front()
        {
            uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p);
            return GamePid == 0 || p == (uint)GamePid || p == _ownPid;
        }
        IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            if (msg == WM_INPUT)
            {
                uint size = 0, hdr = (uint)(IntPtr.Size == 8 ? 24 : 16);
                GetRawInputData(l, RID_INPUT, IntPtr.Zero, ref size, hdr);
                if (size > 0 && size < 256)
                {
                    IntPtr buf = Marshal.AllocHGlobal((int)size);
                    try
                    {
                        if (GetRawInputData(l, RID_INPUT, buf, ref size, hdr) == size && Marshal.ReadInt32(buf, 0) == 0)      // RIM_TYPEMOUSE
                        {
                            int o = (int)hdr; ushort flags = (ushort)Marshal.ReadInt16(buf, o), bf = (ushort)Marshal.ReadInt16(buf, o + 4); short bd = Marshal.ReadInt16(buf, o + 6);
                            if ((bf & 0x1) != 0) _left = true;                  // RI_MOUSE_LEFT_BUTTON_DOWN
                            if ((bf & 0x2) != 0) _left = false;                 // ..._UP
                            bool front = Front();
                            if (front)
                            {
                                Inputs++;
                                if ((bf & 0x400) != 0) Interlocked.Add(ref _wheel, bd);      // RI_MOUSE_WHEEL
                                if ((flags & 1) == 0 && _left) { Interlocked.Add(ref _dx, Marshal.ReadInt32(buf, o + 12)); Interlocked.Add(ref _dy, Marshal.ReadInt32(buf, o + 16)); }
                            }
                        }
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
            }
            return DefWindowProcW(h, msg, w, l);
        }
        void Loop()
        {
            uint rsz = (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE));
            try
            {
                _wp = WndProc; _cls = "AztRawMouse" + Stopwatch.GetTimestamp();
                var wc = new WNDCLASSEX(); wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX)); wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wp);
                wc.hInstance = GetModuleHandleW(IntPtr.Zero); wc.lpszClassName = _cls;
                if (RegisterClassExW(ref wc) == 0) { StartError = "RegisterClassEx failed: " + Marshal.GetLastWin32Error(); return; }
                _hwnd = CreateWindowExW(0, _cls, "", 0, 0, 0, 0, 0, new IntPtr(-3) /* HWND_MESSAGE */, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_hwnd == IntPtr.Zero) { StartError = "CreateWindowEx failed: " + Marshal.GetLastWin32Error(); return; }
                try
                {
                    uint rn = 8; var had = new RAWINPUTDEVICE[8]; int got = GetRegisteredRawInputDevices(had, ref rn, rsz);
                    for (int i = 0; i < got; i++) if (had[i].usUsagePage == 1 && had[i].usUsage == 2) _before = new[] { had[i] };
                }
                catch { }
                if (!RegisterRawInputDevices(new[] { new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 2, dwFlags = RIDEV_INPUTSINK, hwndTarget = _hwnd } }, 1, rsz))
                { StartError = "raw input not registered: " + Marshal.GetLastWin32Error(); return; }
            }
            finally { _up.Set(); }
            try
            {
                while (_run)
                {
                    MSG m; while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
                    Thread.Sleep(2);
                }
            }
            finally
            {
                try
                {
                    if (_before != null) RegisterRawInputDevices(_before, 1, rsz);
                    else RegisterRawInputDevices(new[] { new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 2, dwFlags = RIDEV_REMOVE, hwndTarget = IntPtr.Zero } }, 1, rsz);
                }
                catch { }
                if (_hwnd != IntPtr.Zero) { DestroyWindow(_hwnd); _hwnd = IntPtr.Zero; }
                try { UnregisterClassW(_cls, GetModuleHandleW(IntPtr.Zero)); } catch { }
            }
        }
        public void Dispose() { _run = false; if (_th != null && Thread.CurrentThread != _th) _th.Join(1000); _th = null; }
    }
}
