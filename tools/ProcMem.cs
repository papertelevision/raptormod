// ProcMem.cs -- read another process's memory from the host.
//
// This exists to test one specific claim in the feasibility report: that reaching the
// game's state from host code requires forking DOSBox. DOSBox emulates guest RAM as an
// ordinary allocation inside an ordinary Windows process, so if a known byte pattern can
// be found there and read back live, a host-side reader needs NO emulator changes at all.
//
// WHY A SIGNATURE SEARCH RATHER THAN AN ADDRESS CALCULATION: the game is DOS/4GW, which
// runs in protected mode with its OWN page tables, so a guest LINEAR address is not a
// fixed offset into DOSBox's memory array -- it has to be translated through emulated
// paging. A signature sidesteps that entirely: find the bytes, and you have the host
// address of that guest page. Keep any single signature UNDER 4096 BYTES and it cannot
// straddle a page boundary, so it is guaranteed contiguous in host memory even when the
// guest pages around it are not.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AztTool
{
    public static class ProcMem
    {
        const int PROCESS_QUERY_INFORMATION = 0x0400;
        const int PROCESS_VM_READ = 0x0010;
        const int PROCESS_VM_WRITE = 0x0020;
        const int PROCESS_VM_OPERATION = 0x0008;

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr addr, out MEMORY_BASIC_INFORMATION mbi, IntPtr len);

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORY_BASIC_INFORMATION
        {
            public IntPtr BaseAddress;
            public IntPtr AllocationBase;
            public int AllocationProtect;
            public int __alignment1;
            public IntPtr RegionSize;
            public int State;
            public int Protect;
            public int Type;
            public int __alignment2;
        }

        const int MEM_COMMIT = 0x1000;
        const int PAGE_GUARD = 0x100;
        const int PAGE_NOACCESS = 0x01;

        public class Region
        {
            public long Base;
            public long Size;
            public int Protect;
            public int Type;
        }

        public static List<Region> Regions(int pid, long maxAddr)
        {
            var list = new List<Region>();
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (h == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
            try
            {
                long addr = 0;
                int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));
                while (addr < maxAddr)
                {
                    MEMORY_BASIC_INFORMATION mbi;
                    if (VirtualQueryEx(h, new IntPtr(addr), out mbi, new IntPtr(mbiSize)) == IntPtr.Zero) break;
                    long size = mbi.RegionSize.ToInt64();
                    if (size <= 0) break;
                    bool readable = mbi.State == MEM_COMMIT
                                    && (mbi.Protect & PAGE_GUARD) == 0
                                    && (mbi.Protect & PAGE_NOACCESS) == 0;
                    if (readable)
                        list.Add(new Region { Base = mbi.BaseAddress.ToInt64(), Size = size,
                                              Protect = mbi.Protect, Type = mbi.Type });
                    addr = mbi.BaseAddress.ToInt64() + size;
                }
            }
            finally { CloseHandle(h); }
            return list;
        }

        // ONE HANDLE, KEPT (2026-10-13 performance audit): Read and Write used to OpenProcess + CloseHandle on every call,
        // and the watcher makes 15-20 of them a frame (GuestWord, Step-MemCore, the menu and shot watches) -- ~35-50 us each,
        // most of it the open/close. The handle for the last pid is now kept (read + write rights); a failed call drops it
        // and the next call opens a fresh one, so a restarted DOSBox (a new process, maybe the same pid) is picked up.
        static readonly object _hLock = new object();
        static IntPtr _h = IntPtr.Zero; static int _hPid = -1;
        static IntPtr Handle(int pid)
        {
            lock (_hLock)
            {
                if (_h != IntPtr.Zero && _hPid == pid) return _h;
                if (_h != IntPtr.Zero) { CloseHandle(_h); _h = IntPtr.Zero; _hPid = -1; }
                IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION, false, pid);
                if (h == IntPtr.Zero) h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);     // (read-only if writing is refused)
                if (h == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
                _h = h; _hPid = pid; return h;
            }
        }
        static void Drop(IntPtr h) { lock (_hLock) { if (_h == h && h != IntPtr.Zero) { CloseHandle(_h); _h = IntPtr.Zero; _hPid = -1; } } }

        public static byte[] Read(int pid, long addr, int len)
        {
            IntPtr h = Handle(pid);
            var buf = new byte[len];
            IntPtr got;
            if (!ReadProcessMemory(h, new IntPtr(addr), buf, new IntPtr(len), out got))
            {
                // (a bad address fails too -- only a dead process means the handle is stale: then try once more on a fresh one)
                bool gone = Marshal.GetLastWin32Error() == 6 /* ERROR_INVALID_HANDLE */ || ProcessGone(h);
                if (!gone) return null;
                Drop(h); h = Handle(pid);
                if (!ReadProcessMemory(h, new IntPtr(addr), buf, new IntPtr(len), out got)) return null;
            }
            if (got.ToInt64() != len)
            {
                var trimmed = new byte[got.ToInt64()];
                Array.Copy(buf, trimmed, trimmed.Length);
                return trimmed;
            }
            return buf;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out int code);
        static bool ProcessGone(IntPtr h) { int code; return !GetExitCodeProcess(h, out code) || code != 259 /* STILL_ACTIVE */; }

        // Write into the guest. This is the half of the bridge that can BREAK the running
        // game rather than merely observe it, so callers are expected to target memory
        // they own (AztMod's own BSS) rather than engine structures.
        public static bool Write(int pid, long addr, byte[] data)
        {
            IntPtr h = Handle(pid);
            IntPtr written;
            if (!WriteProcessMemory(h, new IntPtr(addr), data, new IntPtr(data.Length), out written))
            {
                bool gone = ProcessGone(h); if (!gone) return false;
                Drop(h); h = Handle(pid);
                if (!WriteProcessMemory(h, new IntPtr(addr), data, new IntPtr(data.Length), out written)) return false;
            }
            return written.ToInt64() == data.Length;
        }

        // Poll a 4-byte value as fast as the OS will allow, recording every CHANGE with a
        // high-resolution timestamp. Doing the loop in C# rather than PowerShell matters:
        // the whole question is whether the host can observe every frame, and a PowerShell
        // loop's own overhead would dominate the measurement it is supposed to make.
        public class Tick { public uint Value; public long Ticks; }

        public static List<Tick> WatchDword(int pid, long addr, int milliseconds, int maxTicks)
        {
            var outp = new List<Tick>();
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (h == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
            try
            {
                var buf = new byte[4];
                IntPtr got;
                var sw = System.Diagnostics.Stopwatch.StartNew();
                uint last = 0; bool first = true;
                while (sw.ElapsedMilliseconds < milliseconds && outp.Count < maxTicks)
                {
                    if (!ReadProcessMemory(h, new IntPtr(addr), buf, new IntPtr(4), out got)) break;
                    uint v = BitConverter.ToUInt32(buf, 0);
                    if (first || v != last)
                    {
                        outp.Add(new Tick { Value = v, Ticks = sw.ElapsedTicks });
                        last = v; first = false;
                    }
                }
                sw.Stop();
            }
            finally { CloseHandle(h); }
            return outp;
        }

        // Snapshot a span of guest RAM twice, `delayMs` apart, and report which 4 KB pages
        // differ. The framebuffer is whatever large CONTIGUOUS run of pages changes every
        // frame -- found by observation rather than by reverse engineering the video code.
        // Returns one entry per page: 0 unchanged, 1 changed.
        public static byte[] ChangedPages(int pid, long baseAddr, int size, int delayMs)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (h == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
            try
            {
                var a = new byte[size];
                var b = new byte[size];
                IntPtr got;
                if (!ReadProcessMemory(h, new IntPtr(baseAddr), a, new IntPtr(size), out got)) return null;
                System.Threading.Thread.Sleep(delayMs);
                if (!ReadProcessMemory(h, new IntPtr(baseAddr), b, new IntPtr(size), out got)) return null;

                int pages = size / 4096;
                var outp = new byte[pages];
                for (int p = 0; p < pages; p++)
                {
                    int o = p * 4096;
                    for (int i = 0; i < 4096; i++)
                    {
                        if (a[o + i] != b[o + i]) { outp[p] = 1; break; }
                    }
                }
                return outp;
            }
            finally { CloseHandle(h); }
        }

        // Every host address at which `sig` appears. minRegion/maxRegion skip regions that
        // are too small or absurdly large to be the emulated RAM array.
        public static List<long> Scan(int pid, byte[] sig, long minRegion, long maxRegion, long maxAddr, int maxHits)
        {
            var hits = new List<long>();
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (h == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
            try
            {
                foreach (var r in Regions(pid, maxAddr))
                {
                    if (r.Size < minRegion || r.Size > maxRegion) continue;

                    // Read in chunks with an overlap of sig.Length-1 so a match that
                    // straddles a chunk boundary is not missed.
                    const int CHUNK = 4 * 1024 * 1024;
                    long pos = 0;
                    var buf = new byte[CHUNK];
                    while (pos < r.Size)
                    {
                        int want = (int)Math.Min(CHUNK, r.Size - pos);
                        IntPtr got;
                        if (!ReadProcessMemory(h, new IntPtr(r.Base + pos), buf, new IntPtr(want), out got))
                        { pos += want; continue; }
                        int n = (int)got.ToInt64();
                        for (int i = 0; i + sig.Length <= n; i++)
                        {
                            if (buf[i] != sig[0]) continue;
                            int k = 1;
                            while (k < sig.Length && buf[i + k] == sig[k]) k++;
                            if (k == sig.Length)
                            {
                                hits.Add(r.Base + pos + i);
                                if (hits.Count >= maxHits) return hits;
                            }
                        }
                        if (n < want) { pos += want; continue; }
                        pos += n - (sig.Length - 1);
                        if (n < sig.Length) pos += sig.Length;
                    }
                }
            }
            finally { CloseHandle(h); }
            return hits;
        }
    }
}
