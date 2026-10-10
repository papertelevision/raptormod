using System;
using System.Text;
using System.Collections.Generic;

namespace LeTool
{
    public class Analyzer
    {
        public LeImage Img;
        public Disasm Dis;

        public HashSet<uint> InsnStarts = new HashSet<uint>();
        public HashSet<uint> CallTargets = new HashSet<uint>();
        public Dictionary<uint, List<uint>> CallSites = new Dictionary<uint, List<uint>>(); // target -> callers
        public Dictionary<uint, uint> InsnToFunc = new Dictionary<uint, uint>();             // insn -> owning func (first seed reached)
        public Dictionary<uint, List<uint>> ImmRefs = new Dictionary<uint, List<uint>>();    // referenced value -> insn addrs
        public List<uint> Strings = new List<uint>();
        public Dictionary<uint, string> StringAt = new Dictionary<uint, string>();

        uint codeLo, codeHi;

        public Analyzer(LeImage img, Disasm dis)
        {
            Img = img; Dis = dis;
            codeLo = img.ObjBase[1];
            codeHi = img.ObjBase[1] + img.ObjSize[1];
        }

        public bool InCode(uint a) { return a >= codeLo && a < codeHi; }

        public void BuildStrings()
        {
            for (int o = 1; o <= Img.NObj; o++)
            {
                uint b = Img.ObjBase[o];
                byte[] d = Img.ObjData[o];
                int i = 0;
                while (i < d.Length)
                {
                    if (d[i] >= 32 && d[i] < 127)
                    {
                        int j = i;
                        while (j < d.Length && d[j] >= 32 && d[j] < 127) j++;
                        if (j < d.Length && d[j] == 0 && (j - i) >= 4)
                        {
                            uint addr = b + (uint)i;
                            Strings.Add(addr);
                            StringAt[addr] = Encoding.ASCII.GetString(d, i, j - i);
                        }
                        i = j + 1;
                    }
                    else i++;
                }
            }
        }

        /// <summary>Recursive-descent walk. Seeds: entry point + anything a fixup points at inside code.</summary>
        public void Explore(IEnumerable<uint> seeds)
        {
            Queue<uint> work = new Queue<uint>();
            HashSet<uint> queued = new HashSet<uint>();
            foreach (uint s in seeds) if (InCode(s) && queued.Add(s)) work.Enqueue(s);

            while (work.Count > 0)
            {
                uint fn = work.Dequeue();
                WalkBlock(fn, fn, work, queued);
            }
        }

        void WalkBlock(uint start, uint func, Queue<uint> work, HashSet<uint> queued)
        {
            Stack<uint> local = new Stack<uint>();
            local.Push(start);
            int guard = 0;
            while (local.Count > 0 && guard++ < 400000)
            {
                uint a = local.Pop();
                while (true)
                {
                    if (!InCode(a)) break;
                    if (InsnStarts.Contains(a)) break;
                    Insn ins = Dis.Decode(a);
                    if (ins.Len <= 0) break;
                    InsnStarts.Add(a);
                    if (!InsnToFunc.ContainsKey(a)) InsnToFunc[a] = func;

                    if (ins.HasImm32 && ins.Imm32 != 0) AddImmRef(ins.Imm32, a);
                    if (ins.HasDisp32 && ins.Disp32 != 0) AddImmRef(ins.Disp32, a);

                    if (ins.IsCall && ins.HasTarget)
                    {
                        CallTargets.Add(ins.Target);
                        List<uint> l;
                        if (!CallSites.TryGetValue(ins.Target, out l)) { l = new List<uint>(); CallSites[ins.Target] = l; }
                        l.Add(a);
                        if (InCode(ins.Target) && queued.Add(ins.Target)) work.Enqueue(ins.Target);
                    }
                    if (ins.IsCondJmp && ins.HasTarget) local.Push(ins.Target);
                    if (ins.IsJmp)
                    {
                        if (ins.HasTarget) { a = ins.Target; continue; }
                        break; // indirect jmp: stop
                    }
                    if (ins.IsRet) break;
                    a = (uint)(a + ins.Len);
                }
            }
        }

        void AddImmRef(uint v, uint site)
        {
            List<uint> l;
            if (!ImmRefs.TryGetValue(v, out l)) { l = new List<uint>(); ImmRefs[v] = l; }
            l.Add(site);
        }

        /// <summary>Sorted list of discovered function starts.</summary>
        public List<uint> Functions()
        {
            List<uint> f = new List<uint>(CallTargets);
            f.Sort();
            return f;
        }

        /// <summary>Owning function start for an arbitrary instruction address (largest func start &lt;= a that is in same walk).</summary>
        public uint FuncOf(uint a)
        {
            uint r;
            if (InsnToFunc.TryGetValue(a, out r)) return r;
            // fall back: nearest preceding known function start
            uint best = 0;
            foreach (uint f in CallTargets) if (f <= a && f > best) best = f;
            return best;
        }

        /// <summary>All string literals referenced from within a function body (walk linearly until ret-ish).</summary>
        public List<string> StringsInFunc(uint fn, int maxInsn)
        {
            List<string> outp = new List<string>();
            uint a = fn;
            for (int i = 0; i < maxInsn; i++)
            {
                if (!InsnStarts.Contains(a)) break;
                Insn ins = Dis.Decode(a);
                uint v = 0; bool has = false;
                if (ins.HasImm32) { v = ins.Imm32; has = true; }
                if (has && StringAt.ContainsKey(v)) outp.Add(StringAt[v]);
                if (ins.IsRet) break;
                a = (uint)(a + ins.Len);
            }
            return outp;
        }
    }
}
