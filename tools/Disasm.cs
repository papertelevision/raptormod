using System;
using System.Text;
using System.Collections.Generic;

namespace LeTool
{
    public class Insn
    {
        public uint Addr;
        public int  Len;
        public string Mnem = "?";
        public string Ops = "";
        public bool IsCall, IsJmp, IsCondJmp, IsRet, IsInt;
        public bool HasTarget;      // direct branch target
        public uint Target;
        public bool HasImm32;
        public uint Imm32;
        public bool HasDisp32;      // absolute [disp32] memory operand
        public uint Disp32;
        public string Text { get { return (Ops.Length > 0) ? Mnem + " " + Ops : Mnem; } }
    }

    public class Disasm
    {
        static string[] R32 = { "eax","ecx","edx","ebx","esp","ebp","esi","edi" };
        static string[] R16 = { "ax","cx","dx","bx","sp","bp","si","di" };
        static string[] R8  = { "al","cl","dl","bl","ah","ch","dh","bh" };
        static string[] SREG= { "es","cs","ss","ds","fs","gs","?","?" };
        static string[] CC  = { "o","no","b","ae","z","nz","be","a","s","ns","p","np","l","ge","le","g" };
        static string[] GRP1= { "add","or","adc","sbb","and","sub","xor","cmp" };
        static string[] GRP2= { "rol","ror","rcl","rcr","shl","shr","sal","sar" };
        static string[] GRP3= { "test","test","not","neg","mul","imul","div","idiv" };

        LeImage img;
        public Disasm(LeImage i) { img = i; }

        byte B(uint a) { return img.U8(a); }
        uint D(uint a) { return img.U32L(a); }
        ushort W(uint a) { return img.U16L(a); }

        // ---- ModRM decoding ----
        class MRM { public int mod, reg, rm, len; public string text; public bool isAbs; public uint abs; public bool isReg; }

        MRM DecodeModRM(uint a, bool opsize16, bool addr16, int operandBytes)
        {
            MRM m = new MRM();
            byte b = B(a);
            m.mod = b >> 6; m.reg = (b >> 3) & 7; m.rm = b & 7;
            int len = 1;
            string sizePfx = operandBytes == 1 ? "byte " : (operandBytes == 2 ? "word " : "dword ");
            if (m.mod == 3)
            {
                m.isReg = true;
                m.text = operandBytes == 1 ? R8[m.rm] : (operandBytes == 2 ? R16[m.rm] : R32[m.rm]);
                m.len = len; return m;
            }
            string baseStr = null; string idxStr = ""; long disp = 0; bool haveDisp = false; bool dispIsAbs = false;
            if (m.rm == 4)
            {
                byte sib = B(a + 1); len++;
                int sc = sib >> 6, ix = (sib >> 3) & 7, bs = sib & 7;
                if (ix != 4) idxStr = "+" + R32[ix] + (sc > 0 ? "*" + (1 << sc) : "");
                if (bs == 5 && m.mod == 0) { disp = (int)D(a + (uint)len); len += 4; haveDisp = true; dispIsAbs = (idxStr == ""); baseStr = null; }
                else baseStr = R32[bs];
            }
            else if (m.rm == 5 && m.mod == 0)
            {
                disp = (int)D(a + (uint)len); len += 4; haveDisp = true; dispIsAbs = true; baseStr = null;
            }
            else baseStr = R32[m.rm];

            if (m.mod == 1) { disp = (sbyte)B(a + (uint)len); len += 1; haveDisp = true; }
            else if (m.mod == 2) { disp = (int)D(a + (uint)len); len += 4; haveDisp = true; }

            StringBuilder sb = new StringBuilder();
            sb.Append(sizePfx).Append('[');
            bool first = true;
            if (baseStr != null) { sb.Append(baseStr); first = false; }
            if (idxStr != "") { sb.Append(first ? idxStr.Substring(1) : idxStr); first = false; }
            if (haveDisp)
            {
                if (first) sb.Append("0x" + ((uint)disp).ToString("X"));
                else if (disp >= 0) sb.Append("+0x" + disp.ToString("X"));
                else sb.Append("-0x" + (-disp).ToString("X"));
            }
            sb.Append(']');
            m.text = sb.ToString();
            m.len = len;
            if (dispIsAbs) { m.isAbs = true; m.abs = (uint)disp; }
            return m;
        }

        string Reg(int r, int bytes) { return bytes == 1 ? R8[r] : (bytes == 2 ? R16[r] : R32[r]); }
        static string Hex(uint v) { return "0x" + v.ToString("X"); }
        static string HexS(long v) { return v < 0 ? "-0x" + (-v).ToString("X") : "0x" + v.ToString("X"); }

        public Insn Decode(uint addr)
        {
            Insn ins = new Insn(); ins.Addr = addr;
            uint a = addr;
            bool opsz = false, adsz = false, rep = false, repne = false, lockp = false;
            string seg = null;

            // prefixes
            for (int guard = 0; guard < 8; guard++)
            {
                byte p = B(a);
                if (p == 0x66) { opsz = true; a++; }
                else if (p == 0x67) { adsz = true; a++; }
                else if (p == 0xF3) { rep = true; a++; }
                else if (p == 0xF2) { repne = true; a++; }
                else if (p == 0xF0) { lockp = true; a++; }
                else if (p == 0x2E) { seg = "cs"; a++; }
                else if (p == 0x36) { seg = "ss"; a++; }
                else if (p == 0x3E) { seg = "ds"; a++; }
                else if (p == 0x26) { seg = "es"; a++; }
                else if (p == 0x64) { seg = "fs"; a++; }
                else if (p == 0x65) { seg = "gs"; a++; }
                else break;
            }

            int osz = opsz ? 2 : 4;
            byte op = B(a); a++;

            Action<MRM> noteAbs = (m) => { if (m != null && m.isAbs) { ins.HasDisp32 = true; ins.Disp32 = m.abs; } };

            // ---- 0F two byte ----
            if (op == 0x0F)
            {
                byte o2 = B(a); a++;
                if (o2 >= 0x80 && o2 <= 0x8F)
                {
                    int rel = (int)D(a); a += 4;
                    ins.Mnem = "j" + CC[o2 - 0x80]; ins.IsCondJmp = true;
                    ins.HasTarget = true; ins.Target = (uint)(a + rel);
                    ins.Ops = Hex(ins.Target); ins.Len = (int)(a - addr); return ins;
                }
                if (o2 >= 0x90 && o2 <= 0x9F)
                {
                    MRM m = DecodeModRM(a, opsz, adsz, 1); a += (uint)m.len; noteAbs(m);
                    ins.Mnem = "set" + CC[o2 - 0x90]; ins.Ops = m.text; ins.Len = (int)(a - addr); return ins;
                }
                if (o2 >= 0x40 && o2 <= 0x4F)
                {
                    MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; noteAbs(m);
                    ins.Mnem = "cmov" + CC[o2 - 0x40]; ins.Ops = Reg(m.reg, osz) + ", " + m.text; ins.Len = (int)(a - addr); return ins;
                }
                switch (o2)
                {
                    case 0xB6: case 0xB7: case 0xBE: case 0xBF:
                        {
                            int sb2 = (o2 == 0xB6 || o2 == 0xBE) ? 1 : 2;
                            MRM m = DecodeModRM(a, opsz, adsz, sb2); a += (uint)m.len; noteAbs(m);
                            ins.Mnem = (o2 < 0xBE) ? "movzx" : "movsx";
                            ins.Ops = Reg(m.reg, osz) + ", " + m.text; ins.Len = (int)(a - addr); return ins;
                        }
                    case 0xAF:
                        { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; noteAbs(m);
                          ins.Mnem = "imul"; ins.Ops = Reg(m.reg, osz) + ", " + m.text; ins.Len = (int)(a - addr); return ins; }
                    case 0xA2: ins.Mnem = "cpuid"; ins.Len = (int)(a - addr); return ins;
                    case 0x31: ins.Mnem = "rdtsc"; ins.Len = (int)(a - addr); return ins;
                    case 0xA0: ins.Mnem = "push"; ins.Ops = "fs"; ins.Len = (int)(a - addr); return ins;
                    case 0xA1: ins.Mnem = "pop"; ins.Ops = "fs"; ins.Len = (int)(a - addr); return ins;
                    case 0xA8: ins.Mnem = "push"; ins.Ops = "gs"; ins.Len = (int)(a - addr); return ins;
                    case 0xA9: ins.Mnem = "pop"; ins.Ops = "gs"; ins.Len = (int)(a - addr); return ins;
                    case 0xA3: case 0xAB: case 0xB3: case 0xBB:
                        { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; noteAbs(m);
                          ins.Mnem = o2 == 0xA3 ? "bt" : (o2 == 0xAB ? "bts" : (o2 == 0xB3 ? "btr" : "btc"));
                          ins.Ops = m.text + ", " + Reg(m.reg, osz); ins.Len = (int)(a - addr); return ins; }
                    case 0xBA:
                        { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; byte i8 = B(a); a++; noteAbs(m);
                          string[] g8 = { "?","?","?","?","bt","bts","btr","btc" };
                          ins.Mnem = g8[m.reg]; ins.Ops = m.text + ", " + Hex(i8); ins.Len = (int)(a - addr); return ins; }
                    case 0xBC: case 0xBD:
                        { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; noteAbs(m);
                          ins.Mnem = o2 == 0xBC ? "bsf" : "bsr"; ins.Ops = Reg(m.reg, osz) + ", " + m.text; ins.Len = (int)(a - addr); return ins; }
                    case 0xA4: case 0xAC:
                        { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; byte i8 = B(a); a++; noteAbs(m);
                          ins.Mnem = o2 == 0xA4 ? "shld" : "shrd"; ins.Ops = m.text + ", " + Reg(m.reg, osz) + ", " + Hex(i8); ins.Len = (int)(a - addr); return ins; }
                    case 0xA5: case 0xAD:
                        { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; noteAbs(m);
                          ins.Mnem = o2 == 0xA5 ? "shld" : "shrd"; ins.Ops = m.text + ", " + Reg(m.reg, osz) + ", cl"; ins.Len = (int)(a - addr); return ins; }
                    case 0xB0: case 0xB1:
                        { int nb = o2 == 0xB0 ? 1 : osz; MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                          ins.Mnem = "cmpxchg"; ins.Ops = m.text + ", " + Reg(m.reg, nb); ins.Len = (int)(a - addr); return ins; }
                    case 0xC8: case 0xC9: case 0xCA: case 0xCB: case 0xCC: case 0xCD: case 0xCE: case 0xCF:
                        ins.Mnem = "bswap"; ins.Ops = R32[o2 - 0xC8]; ins.Len = (int)(a - addr); return ins;
                    case 0x0B: ins.Mnem = "ud2"; ins.Len = (int)(a - addr); return ins;
                    default:
                        { // best effort: assume modrm
                          MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len;
                          ins.Mnem = "(0f" + o2.ToString("x2") + ")"; ins.Ops = m.text; ins.Len = (int)(a - addr); return ins; }
                }
            }

            // ---- one byte ----
            if (op < 0x40 && (op & 7) <= 5 && (op & 0x38) >> 3 <= 7 && (op & 0xC7) != 0x06 && (op & 0xC7) != 0x07)
            {
                int grp = (op >> 3) & 7;
                int lo = op & 7;
                if (lo <= 3)
                {
                    int nb = (lo == 0 || lo == 2) ? 1 : osz;
                    MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                    ins.Mnem = GRP1[grp];
                    ins.Ops = (lo < 2) ? (m.text + ", " + Reg(m.reg, nb)) : (Reg(m.reg, nb) + ", " + m.text);
                    ins.Len = (int)(a - addr); return ins;
                }
                else if (lo == 4) { byte i8 = B(a); a++; ins.Mnem = GRP1[grp]; ins.Ops = "al, " + Hex(i8); ins.Len = (int)(a - addr); return ins; }
                else { uint iv = osz == 2 ? W(a) : D(a); a += (uint)osz; ins.Mnem = GRP1[grp]; ins.Ops = (osz == 2 ? "ax, " : "eax, ") + Hex(iv); ins.HasImm32 = true; ins.Imm32 = iv; ins.Len = (int)(a - addr); return ins; }
            }

            if (op >= 0x40 && op <= 0x47) { ins.Mnem = "inc"; ins.Ops = Reg(op - 0x40, osz); ins.Len = (int)(a - addr); return ins; }
            if (op >= 0x48 && op <= 0x4F) { ins.Mnem = "dec"; ins.Ops = Reg(op - 0x48, osz); ins.Len = (int)(a - addr); return ins; }
            if (op >= 0x50 && op <= 0x57) { ins.Mnem = "push"; ins.Ops = Reg(op - 0x50, osz); ins.Len = (int)(a - addr); return ins; }
            if (op >= 0x58 && op <= 0x5F) { ins.Mnem = "pop"; ins.Ops = Reg(op - 0x58, osz); ins.Len = (int)(a - addr); return ins; }
            if (op >= 0x70 && op <= 0x7F)
            {
                int rel = (sbyte)B(a); a++;
                ins.Mnem = "j" + CC[op - 0x70]; ins.IsCondJmp = true; ins.HasTarget = true; ins.Target = (uint)(a + rel);
                ins.Ops = Hex(ins.Target); ins.Len = (int)(a - addr); return ins;
            }
            if (op >= 0x91 && op <= 0x97) { ins.Mnem = "xchg"; ins.Ops = (osz == 2 ? "ax, " : "eax, ") + Reg(op - 0x90, osz); ins.Len = (int)(a - addr); return ins; }
            if (op >= 0xB0 && op <= 0xB7) { byte i8 = B(a); a++; ins.Mnem = "mov"; ins.Ops = R8[op - 0xB0] + ", " + Hex(i8); ins.Len = (int)(a - addr); return ins; }
            if (op >= 0xB8 && op <= 0xBF)
            {
                uint iv = osz == 2 ? W(a) : D(a); a += (uint)osz;
                ins.Mnem = "mov"; ins.Ops = Reg(op - 0xB8, osz) + ", " + Hex(iv);
                ins.HasImm32 = true; ins.Imm32 = iv; ins.Len = (int)(a - addr); return ins;
            }

            switch (op)
            {
                case 0x60: ins.Mnem = "pushad"; break;
                case 0x61: ins.Mnem = "popad"; break;
                case 0x68: { uint iv = osz == 2 ? W(a) : D(a); a += (uint)osz; ins.Mnem = "push"; ins.Ops = Hex(iv); ins.HasImm32 = true; ins.Imm32 = iv; break; }
                case 0x6A: { int v = (sbyte)B(a); a++; ins.Mnem = "push"; ins.Ops = HexS(v); break; }
                case 0x69: { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; uint iv = osz == 2 ? W(a) : D(a); a += (uint)osz; noteAbs(m);
                             ins.Mnem = "imul"; ins.Ops = Reg(m.reg, osz) + ", " + m.text + ", " + Hex(iv); ins.HasImm32 = true; ins.Imm32 = iv; break; }
                case 0x6B: { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; int iv = (sbyte)B(a); a++; noteAbs(m);
                             ins.Mnem = "imul"; ins.Ops = Reg(m.reg, osz) + ", " + m.text + ", " + HexS(iv); break; }
                case 0x80: case 0x81: case 0x83:
                    {
                        int nb = (op == 0x80) ? 1 : osz;
                        MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                        long iv;
                        if (op == 0x81) { iv = (osz == 2) ? W(a) : (int)D(a); a += (uint)osz; ins.HasImm32 = true; ins.Imm32 = (uint)iv; }
                        else if (op == 0x83) { iv = (sbyte)B(a); a++; }
                        else { iv = B(a); a++; }
                        ins.Mnem = GRP1[m.reg]; ins.Ops = m.text + ", " + HexS(iv); break;
                    }
                case 0x84: case 0x85:
                    { int nb = op == 0x84 ? 1 : osz; MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                      ins.Mnem = "test"; ins.Ops = m.text + ", " + Reg(m.reg, nb); break; }
                case 0x86: case 0x87:
                    { int nb = op == 0x86 ? 1 : osz; MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                      ins.Mnem = "xchg"; ins.Ops = m.text + ", " + Reg(m.reg, nb); break; }
                case 0x88: case 0x89: case 0x8A: case 0x8B:
                    {
                        int nb = (op == 0x88 || op == 0x8A) ? 1 : osz;
                        MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                        ins.Mnem = "mov";
                        ins.Ops = (op < 0x8A) ? (m.text + ", " + Reg(m.reg, nb)) : (Reg(m.reg, nb) + ", " + m.text);
                        break;
                    }
                case 0x8C: { MRM m = DecodeModRM(a, opsz, adsz, 2); a += (uint)m.len; noteAbs(m); ins.Mnem = "mov"; ins.Ops = m.text + ", " + SREG[m.reg]; break; }
                case 0x8E: { MRM m = DecodeModRM(a, opsz, adsz, 2); a += (uint)m.len; noteAbs(m); ins.Mnem = "mov"; ins.Ops = SREG[m.reg] + ", " + m.text; break; }
                case 0x8D:
                    {
                        MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; noteAbs(m);
                        string t = m.text; int ix = t.IndexOf('[');
                        ins.Mnem = "lea"; ins.Ops = Reg(m.reg, osz) + ", " + (ix >= 0 ? t.Substring(ix) : t); break;
                    }
                case 0x8F: { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; noteAbs(m); ins.Mnem = "pop"; ins.Ops = m.text; break; }
                case 0x90: ins.Mnem = "nop"; break;
                case 0x98: ins.Mnem = osz == 2 ? "cbw" : "cwde"; break;
                case 0x99: ins.Mnem = osz == 2 ? "cwd" : "cdq"; break;
                case 0x9B: ins.Mnem = "wait"; break;
                case 0x9C: ins.Mnem = "pushfd"; break;
                case 0x9D: ins.Mnem = "popfd"; break;
                case 0x9E: ins.Mnem = "sahf"; break;
                case 0x9F: ins.Mnem = "lahf"; break;
                case 0xA0: case 0xA1: case 0xA2: case 0xA3:
                    {
                        uint mo = D(a); a += 4;
                        int nb = (op == 0xA0 || op == 0xA2) ? 1 : osz;
                        string r = nb == 1 ? "al" : (nb == 2 ? "ax" : "eax");
                        ins.Mnem = "mov";
                        ins.Ops = (op < 0xA2) ? (r + ", [" + Hex(mo) + "]") : ("[" + Hex(mo) + "], " + r);
                        ins.HasDisp32 = true; ins.Disp32 = mo; break;
                    }
                case 0xA4: ins.Mnem = (rep ? "rep " : "") + "movsb"; break;
                case 0xA5: ins.Mnem = (rep ? "rep " : "") + (osz == 2 ? "movsw" : "movsd"); break;
                case 0xA6: ins.Mnem = (repne ? "repne " : (rep ? "repe " : "")) + "cmpsb"; break;
                case 0xA7: ins.Mnem = (repne ? "repne " : (rep ? "repe " : "")) + (osz == 2 ? "cmpsw" : "cmpsd"); break;
                case 0xA8: { byte i8 = B(a); a++; ins.Mnem = "test"; ins.Ops = "al, " + Hex(i8); break; }
                case 0xA9: { uint iv = osz == 2 ? W(a) : D(a); a += (uint)osz; ins.Mnem = "test"; ins.Ops = (osz == 2 ? "ax, " : "eax, ") + Hex(iv); ins.HasImm32 = true; ins.Imm32 = iv; break; }
                case 0xAA: ins.Mnem = (rep ? "rep " : "") + "stosb"; break;
                case 0xAB: ins.Mnem = (rep ? "rep " : "") + (osz == 2 ? "stosw" : "stosd"); break;
                case 0xAC: ins.Mnem = "lodsb"; break;
                case 0xAD: ins.Mnem = osz == 2 ? "lodsw" : "lodsd"; break;
                case 0xAE: ins.Mnem = (repne ? "repne " : (rep ? "repe " : "")) + "scasb"; break;
                case 0xAF: ins.Mnem = (repne ? "repne " : (rep ? "repe " : "")) + (osz == 2 ? "scasw" : "scasd"); break;
                case 0xC0: case 0xC1:
                    { int nb = op == 0xC0 ? 1 : osz; MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; byte i8 = B(a); a++; noteAbs(m);
                      ins.Mnem = GRP2[m.reg]; ins.Ops = m.text + ", " + Hex(i8); break; }
                case 0xC2: { ushort iv = W(a); a += 2; ins.Mnem = "ret"; ins.Ops = Hex(iv); ins.IsRet = true; break; }
                case 0xC3: ins.Mnem = "ret"; ins.IsRet = true; break;
                case 0xC6: case 0xC7:
                    {
                        int nb = op == 0xC6 ? 1 : osz;
                        MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                        uint iv; if (nb == 1) { iv = B(a); a++; } else if (nb == 2) { iv = W(a); a += 2; } else { iv = D(a); a += 4; ins.HasImm32 = true; ins.Imm32 = iv; }
                        ins.Mnem = "mov"; ins.Ops = m.text + ", " + Hex(iv); break;
                    }
                case 0xC8: { ushort iv = W(a); a += 2; byte lvl = B(a); a++; ins.Mnem = "enter"; ins.Ops = Hex(iv) + ", " + Hex(lvl); break; }
                case 0xC9: ins.Mnem = "leave"; break;
                case 0xCA: { ushort iv = W(a); a += 2; ins.Mnem = "retf"; ins.Ops = Hex(iv); ins.IsRet = true; break; }
                case 0xCB: ins.Mnem = "retf"; ins.IsRet = true; break;
                case 0xCC: ins.Mnem = "int3"; break;
                case 0xCD: { byte i8 = B(a); a++; ins.Mnem = "int"; ins.Ops = Hex(i8); ins.IsInt = true; break; }
                case 0xCF: ins.Mnem = "iretd"; ins.IsRet = true; break;
                case 0xD0: case 0xD1: case 0xD2: case 0xD3:
                    { int nb = (op == 0xD0 || op == 0xD2) ? 1 : osz; MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                      ins.Mnem = GRP2[m.reg]; ins.Ops = m.text + ", " + ((op < 0xD2) ? "1" : "cl"); break; }
                case 0xD8: case 0xD9: case 0xDA: case 0xDB: case 0xDC: case 0xDD: case 0xDE: case 0xDF:
                    {
                        byte mb = B(a);
                        if ((mb >> 6) == 3) { a += 1; ins.Mnem = "fpu(" + op.ToString("x2") + mb.ToString("x2") + ")"; }
                        else { MRM m = DecodeModRM(a, opsz, adsz, 4); a += (uint)m.len; noteAbs(m);
                               ins.Mnem = FpuMemName(op, m.reg); ins.Ops = m.text; }
                        break;
                    }
                case 0xE0: case 0xE1: case 0xE2: case 0xE3:
                    { int rel = (sbyte)B(a); a++; string[] n = { "loopne","loope","loop","jecxz" };
                      ins.Mnem = n[op - 0xE0]; ins.IsCondJmp = true; ins.HasTarget = true; ins.Target = (uint)(a + rel); ins.Ops = Hex(ins.Target); break; }
                case 0xE8:
                    { int rel = (int)D(a); a += 4; ins.Mnem = "call"; ins.IsCall = true; ins.HasTarget = true; ins.Target = (uint)(a + rel); ins.Ops = Hex(ins.Target); break; }
                case 0xE9:
                    { int rel = (int)D(a); a += 4; ins.Mnem = "jmp"; ins.IsJmp = true; ins.HasTarget = true; ins.Target = (uint)(a + rel); ins.Ops = Hex(ins.Target); break; }
                case 0xEB:
                    { int rel = (sbyte)B(a); a++; ins.Mnem = "jmp"; ins.IsJmp = true; ins.HasTarget = true; ins.Target = (uint)(a + rel); ins.Ops = Hex(ins.Target); break; }
                case 0xE4: case 0xE5: { byte i8 = B(a); a++; ins.Mnem = "in"; ins.Ops = (op == 0xE4 ? "al, " : "eax, ") + Hex(i8); break; }
                case 0xE6: case 0xE7: { byte i8 = B(a); a++; ins.Mnem = "out"; ins.Ops = Hex(i8) + (op == 0xE6 ? ", al" : ", eax"); break; }
                case 0xEC: ins.Mnem = "in"; ins.Ops = "al, dx"; break;
                case 0xED: ins.Mnem = "in"; ins.Ops = "eax, dx"; break;
                case 0xEE: ins.Mnem = "out"; ins.Ops = "dx, al"; break;
                case 0xEF: ins.Mnem = "out"; ins.Ops = "dx, eax"; break;
                case 0xF4: ins.Mnem = "hlt"; break;
                case 0xF5: ins.Mnem = "cmc"; break;
                case 0xF6: case 0xF7:
                    {
                        int nb = op == 0xF6 ? 1 : osz;
                        MRM m = DecodeModRM(a, opsz, adsz, nb); a += (uint)m.len; noteAbs(m);
                        ins.Mnem = GRP3[m.reg];
                        if (m.reg <= 1) { uint iv; if (nb == 1) { iv = B(a); a++; } else if (nb == 2) { iv = W(a); a += 2; } else { iv = D(a); a += 4; ins.HasImm32 = true; ins.Imm32 = iv; }
                                          ins.Ops = m.text + ", " + Hex(iv); }
                        else ins.Ops = m.text;
                        break;
                    }
                case 0xF8: ins.Mnem = "clc"; break;
                case 0xF9: ins.Mnem = "stc"; break;
                case 0xFA: ins.Mnem = "cli"; break;
                case 0xFB: ins.Mnem = "sti"; break;
                case 0xFC: ins.Mnem = "cld"; break;
                case 0xFD: ins.Mnem = "std"; break;
                case 0xFE:
                    { MRM m = DecodeModRM(a, opsz, adsz, 1); a += (uint)m.len; noteAbs(m);
                      ins.Mnem = m.reg == 0 ? "inc" : "dec"; ins.Ops = m.text; break; }
                case 0xFF:
                    {
                        MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; noteAbs(m);
                        switch (m.reg)
                        {
                            case 0: ins.Mnem = "inc"; ins.Ops = m.text; break;
                            case 1: ins.Mnem = "dec"; ins.Ops = m.text; break;
                            case 2: ins.Mnem = "call"; ins.Ops = m.text; ins.IsCall = true; break;
                            case 3: ins.Mnem = "callf"; ins.Ops = m.text; ins.IsCall = true; break;
                            case 4: ins.Mnem = "jmp"; ins.Ops = m.text; ins.IsJmp = true; break;
                            case 5: ins.Mnem = "jmpf"; ins.Ops = m.text; ins.IsJmp = true; break;
                            case 6: ins.Mnem = "push"; ins.Ops = m.text; break;
                            default: ins.Mnem = "?ff"; ins.Ops = m.text; break;
                        }
                        break;
                    }
                case 0x62: { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; ins.Mnem = "bound"; ins.Ops = Reg(m.reg, osz) + ", " + m.text; break; }
                case 0xC4: { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; ins.Mnem = "les"; ins.Ops = Reg(m.reg, osz) + ", " + m.text; break; }
                case 0xC5: { MRM m = DecodeModRM(a, opsz, adsz, osz); a += (uint)m.len; ins.Mnem = "lds"; ins.Ops = Reg(m.reg, osz) + ", " + m.text; break; }
                case 0x06: ins.Mnem = "push"; ins.Ops = "es"; break;
                case 0x07: ins.Mnem = "pop"; ins.Ops = "es"; break;
                case 0x0E: ins.Mnem = "push"; ins.Ops = "cs"; break;
                case 0x16: ins.Mnem = "push"; ins.Ops = "ss"; break;
                case 0x17: ins.Mnem = "pop"; ins.Ops = "ss"; break;
                case 0x1E: ins.Mnem = "push"; ins.Ops = "ds"; break;
                case 0x1F: ins.Mnem = "pop"; ins.Ops = "ds"; break;
                default:
                    ins.Mnem = "db"; ins.Ops = Hex(op); break;
            }
            if (seg != null && ins.Ops.Contains("[")) ins.Ops = ins.Ops.Replace("[", seg + ":[");
            if (lockp) ins.Mnem = "lock " + ins.Mnem;
            ins.Len = (int)(a - addr);
            if (ins.Len <= 0) ins.Len = 1;
            return ins;
        }

        static string FpuMemName(byte op, int reg)
        {
            switch (op)
            {
                case 0xD8: { string[] n = { "fadd","fmul","fcom","fcomp","fsub","fsubr","fdiv","fdivr" }; return n[reg]; }
                case 0xD9: { string[] n = { "fld","?","fst","fstp","fldenv","fldcw","fnstenv","fnstcw" }; return n[reg]; }
                case 0xDA: { string[] n = { "fiadd","fimul","ficom","ficomp","fisub","fisubr","fidiv","fidivr" }; return n[reg]; }
                case 0xDB: { string[] n = { "fild","fisttp","fist","fistp","?","fld80","?","fstp80" }; return n[reg]; }
                case 0xDC: { string[] n = { "faddq","fmulq","fcomq","fcompq","fsubq","fsubrq","fdivq","fdivrq" }; return n[reg]; }
                case 0xDD: { string[] n = { "fldq","fisttpq","fstq","fstpq","frstor","?","fnsave","fnstsw" }; return n[reg]; }
                case 0xDE: { string[] n = { "fiaddw","fimulw","ficomw","ficompw","fisubw","fisubrw","fidivw","fidivrw" }; return n[reg]; }
                case 0xDF: { string[] n = { "fildw","fisttpw","fistw","fistpw","fbld","fildq","fbstp","fistpq" }; return n[reg]; }
            }
            return "fpu";
        }
    }
}
