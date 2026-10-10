// Keys.cs -- is a key down, in the game's own window?
//
// The helmet lamp belongs to the host renderer, so its switch does too: the key is read
// here, straight from Windows, and counts only while the window in front belongs to the
// game's process -- an F typed into anything else must not flick a light in a game running
// behind it. Nothing is patched into the game for this, and the game still receives the key.
using System;
using System.Runtime.InteropServices;

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
}
