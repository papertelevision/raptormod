using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

namespace LeTool
{
    public class Fixup
    {
        public uint Site;      // linear address patched
    // Where the RECORD's target-offset field lives in the file, and how many
    // source sites that one record feeds. Needed to retarget a fixup: the code
    // bytes are meaningless (the loader overwrites them from the record), and a
    // record with several sources moves all of them together.
    public long RecTrgOffPos;
    public int  RecTrgOffSize;
    public int  RecSrcCount;
        public uint Value;     // value written
        public int  SrcType;
        public int  TrgObj;
        public uint TrgOff;
    }

    public class LeImage
    {
        public byte[] File;
        public int LeBase;
        public int PageSize;
        public int NumPages;
        public int DataPagesOff;      // absolute file offset of page 1 (derived)
        public int HeaderDataPagesOff;// what the LE header claims (wrong in this binary)
        public uint[] ObjBase;        // [1..n]
        public uint[] ObjSize;
        public uint[] ObjFlags;
        public int[]  ObjPageIdx;
        public int[]  ObjPageCnt;
        public byte[][] ObjData;      // [1..n] full virtual size, zero filled
        public int NObj;
        public List<Fixup> Fixups = new List<Fixup>();
        public uint EntryPoint;

        static uint U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
        static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }

        public LeImage(string path)
        {
            File = System.IO.File.ReadAllBytes(path);
            // find LE signature
            LeBase = -1;
            for (int i = 0; i < File.Length - 4; i++)
                if (File[i] == 0x4C && File[i + 1] == 0x45 && File[i + 2] == 0 && File[i + 3] == 0) { LeBase = i; break; }
            if (LeBase < 0) throw new Exception("no LE header");

            NumPages = (int)U32(File, LeBase + 0x14);
            PageSize = (int)U32(File, LeBase + 0x28);
            int lastPageSize = (int)U32(File, LeBase + 0x2C);
            // The header's "data pages offset" field does not match reality in this binary.
            // Derive it from the tail instead: the page image must end exactly at EOF, with
            // (NumPages-1) full pages plus lastPageSize bytes. Verified against the fixup table.
            DataPagesOff = File.Length - ((NumPages - 1) * PageSize + lastPageSize);
            HeaderDataPagesOff = LeBase + (int)U32(File, LeBase + 0x80);

            int objTab = LeBase + (int)U32(File, LeBase + 0x40);
            NObj = (int)U32(File, LeBase + 0x44);
            int pageMap = LeBase + (int)U32(File, LeBase + 0x48);

            ObjBase = new uint[NObj + 1]; ObjSize = new uint[NObj + 1]; ObjFlags = new uint[NObj + 1];
            ObjPageIdx = new int[NObj + 1]; ObjPageCnt = new int[NObj + 1]; ObjData = new byte[NObj + 1][];

            for (int i = 1; i <= NObj; i++)
            {
                int o = objTab + (i - 1) * 24;
                ObjSize[i]   = U32(File, o);
                ObjBase[i]   = U32(File, o + 4);
                ObjFlags[i]  = U32(File, o + 8);
                ObjPageIdx[i]= (int)U32(File, o + 12);
                ObjPageCnt[i]= (int)U32(File, o + 16);
                ObjData[i]   = new byte[ObjSize[i]];
            }

            // load pages
            for (int i = 1; i <= NObj; i++)
            {
                for (int p = 0; p < ObjPageCnt[i]; p++)
                {
                    int mapEntry = ObjPageIdx[i] + p;            // 1-based module page index
                    int me = pageMap + (mapEntry - 1) * 4;
                    if (me + 4 > File.Length) continue;
                    // LE page map entry: big-endian high word, low byte, flags
                    int high = (File[me] << 8) | File[me + 1];
                    int low = File[me + 2];
                    int flags = File[me + 3];
                    int physPage = (high << 8) | low;            // 1-based physical page
                    if (flags == 3) continue;                    // zero filled
                    long src = (long)DataPagesOff + (long)(physPage - 1) * PageSize;
                    long dst = (long)p * PageSize;
                    for (int k = 0; k < PageSize; k++)
                    {
                        long s = src + k; long d = dst + k;
                        if (s >= File.Length) break;
                        if (d >= ObjData[i].Length) break;
                        ObjData[i][d] = File[s];
                    }
                }
            }

            EntryPoint = ObjBase[(int)U32(File, LeBase + 0x18)] + U32(File, LeBase + 0x1C);

            ApplyFixups(LeBase + (int)U32(File, LeBase + 0x68), LeBase + (int)U32(File, LeBase + 0x6C), pageMap);
        }

        // which object owns module page index (1-based)
        int ObjectOfModulePage(int modulePage, out int pageInObj)
        {
            for (int i = 1; i <= NObj; i++)
                if (modulePage >= ObjPageIdx[i] && modulePage < ObjPageIdx[i] + ObjPageCnt[i])
                { pageInObj = modulePage - ObjPageIdx[i]; return i; }
            pageInObj = 0; return 0;
        }

        void WriteObj(int obj, long off, uint val, int nbytes)
        {
            if (obj < 1 || obj > NObj) return;
            byte[] d = ObjData[obj];
            for (int k = 0; k < nbytes; k++)
            {
                long a = off + k;
                if (a < 0 || a >= d.Length) return;
                d[a] = (byte)((val >> (8 * k)) & 0xFF);
            }
        }

        void ApplyFixups(int fixPageTab, int fixRecTab, int pageMap)
        {
            for (int page = 1; page <= NumPages; page++)
            {
                int e0 = fixPageTab + (page - 1) * 4;
                int e1 = fixPageTab + page * 4;
                if (e1 + 4 > File.Length) break;
                int start = (int)U32(File, e0);
                int end = (int)U32(File, e1);
                int p = fixRecTab + start;
                int pend = fixRecTab + end;

                int pageInObj; int obj = ObjectOfModulePage(page, out pageInObj);
                if (obj == 0) continue;
                long pageOff = (long)pageInObj * PageSize;

                while (p < pend && p + 2 <= File.Length)
                {
                    byte src = File[p];
                    byte tflags = File[p + 1];
                    int srcType = src & 0x0F;
                    bool srcList = (src & 0x20) != 0;
                    p += 2;

                    List<int> srcOffs = new List<int>();
                    long trgOffPos = -1; int trgOffSize = 0;
                    int listCount = 0;
                    if (srcList) { listCount = File[p]; p += 1; }
                    else { srcOffs.Add((short)U16(File, p)); p += 2; }

                    int targetType = tflags & 0x03;
                    int objNum = 0; uint trgOff = 0;

                    if (targetType == 0) // internal
                    {
                        if ((tflags & 0x40) != 0) { objNum = U16(File, p); p += 2; }
                        else { objNum = File[p]; p += 1; }
                        if (srcType != 2)
                        {
                            trgOffPos = p;
                            if ((tflags & 0x10) != 0) { trgOffSize = 4; trgOff = U32(File, p); p += 4; }
                            else { trgOffSize = 2; trgOff = U16(File, p); p += 2; }
                        }
                    }
                    else
                    {
                        // imports: skip module ordinal + proc info (not used by this binary)
                        if ((tflags & 0x40) != 0) p += 2; else p += 1;
                        if (targetType == 1) { if ((tflags & 0x80) != 0) p += 1; else if ((tflags & 0x10) != 0) p += 4; else p += 2; }
                        else if (targetType == 2) { if ((tflags & 0x10) != 0) p += 4; else p += 2; }
                    }
                    if ((tflags & 0x04) != 0) { if ((tflags & 0x20) != 0) p += 4; else p += 2; } // additive

                    if (srcList)
                    {
                        for (int k = 0; k < listCount; k++) { srcOffs.Add((short)U16(File, p)); p += 2; }
                    }

                    if (targetType != 0) continue;
                    uint val = ObjBase[objNum] + trgOff;

                    foreach (int so in srcOffs)
                    {
                        long off = pageOff + so;
                        int nb = 4;
                        if (srcType == 7) nb = 4;
                        else if (srcType == 5) nb = 2;
                        else if (srcType == 8) nb = 4;
                        else if (srcType == 2) nb = 2;
                        else if (srcType == 0) nb = 1;
                        else if (srcType == 3) nb = 4;   // 16:16 ptr -> just write offset part
                        else if (srcType == 6) nb = 4;   // 16:32 ptr
                        uint wv = val;
                        if (srcType == 8) wv = val; // self-relative: leave (rare here)
                        WriteObj(obj, off, wv, nb);
                        Fixups.Add(new Fixup { Site = ObjBase[obj] + (uint)off, Value = wv, SrcType = srcType, TrgObj = objNum, TrgOff = trgOff, RecTrgOffPos = trgOffPos, RecTrgOffSize = trgOffSize, RecSrcCount = srcOffs.Count });
                    }
                }
            }
        }

        /// <summary>File offset that backs a linear address, or -1 if it is BSS / unmapped.</summary>
        public long FileOffsetOfLinear(uint lin)
        {
            int o = ObjOfLinear(lin);
            if (o == 0) return -1;
            long offInObj = lin - ObjBase[o];
            int page = (int)(offInObj / PageSize);
            long inPage = offInObj % PageSize;
            if (page >= ObjPageCnt[o]) return -1;
            int modulePage = ObjPageIdx[o] + page;
            long fo = (long)DataPagesOff + (long)(modulePage - 1) * PageSize + inPage;
            if (fo >= File.Length) return -1;
            return fo;
        }

        public int ObjOfLinear(uint lin)
        {
            // LATEST FIRST: AztMod grows obj1's vsize past obj2's linked base (the overlay's BSS window, 2026-10-11), so in
            // a PATCHED image the linked ranges overlap; there the address is obj2's data, not obj1's zero-filled tail.
            // (DOS/4GW places the objects one after another, so the overlap exists only on paper.) The stock image has no
            // overlap and reads exactly as before.
            for (int i = NObj; i >= 1; i--)
                if (lin >= ObjBase[i] && lin < ObjBase[i] + ObjSize[i]) return i;
            return 0;
        }
        public bool Valid(uint lin) { return ObjOfLinear(lin) != 0; }
        public byte U8(uint lin) { int o = ObjOfLinear(lin); if (o == 0) return 0; return ObjData[o][lin - ObjBase[o]]; }
        public uint U32L(uint lin) { return (uint)(U8(lin) | (U8(lin + 1) << 8) | (U8(lin + 2) << 16) | (U8(lin + 3) << 24)); }
        public ushort U16L(uint lin) { return (ushort)(U8(lin) | (U8(lin + 1) << 8)); }

        public byte[] Slice(uint lin, int n)
        {
            byte[] r = new byte[n];
            for (int i = 0; i < n; i++) r[i] = U8(lin + (uint)i);
            return r;
        }

        public string CString(uint lin, int max)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < max; i++)
            {
                byte c = U8(lin + (uint)i);
                if (c == 0) break;
                if (c >= 32 && c < 127) sb.Append((char)c); else sb.Append('.');
            }
            return sb.ToString();
        }

        // Is this linear address plausibly the start of a printable C string?
        public bool IsStringAt(uint lin, int minLen)
        {
            int n = 0;
            for (int i = 0; i < 256; i++)
            {
                byte c = U8(lin + (uint)i);
                if (c == 0) break;
                if (c < 32 || c >= 127) return false;
                n++;
            }
            return n >= minLen;
        }
    }
}

