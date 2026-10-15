// BootHd.cs -- the visor boot, drawn by the host at display resolution (the GPU version).
//
// The game's boot is an 8-bit animation painted into the staging buffer: a 1bpp readout
// expanded through palette tables, glitches drawn as palette runs, everything at 1600x928.
// The true-colour version shows THIS instead, from the very first boot frame: the same
// script (art\boot-hd.json, written by Build-AztMod from the constants the guest is built
// from -- texts, beats, effect tables, ink indices), drawn with antialiased type, a phosphor
// glow and a soft tube, at whatever size the picture is on this screen.
//
// IT FOLLOWS THE GUEST'S CLOCK, NOT ITS OWN. The guest keeps running its boot underneath --
// that is what plays the CD effect and gates the music, the reticle and the HUD -- so every
// beat here is timed from aztBootEl, read each frame and carried forward between the guest's
// frames. The 8-bit boot is untouched and stays the retro version's.
//
// THE END IS THE HOST'S. The shutter reveals the 3D, and in the GPU version that is the host's
// 3D, which only exists once the watcher has taken the viewport -- after the guest boot ends.
// So at the shutter beat the screen HOLDS (the guest's boot is wound forward to its end so the
// takeover starts at once), and when the watcher's first real frame is up it calls Reveal():
// from then on this draws the shutter panels, their lips and phosphor ghost, and the
// calibration box OVER the composed 3D (Overlay.Decorate), then gets out of the way.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;

namespace AztTool
{
    public class BootHd : IDisposable
    {
        // ---- the script (boot-hd.json) ---------------------------------------------------
        string[] _banner, _lines, _misSmall; string _final, _mission;
        int InjW, InjH;
        long U_hold, U_banner, U_banStep, U_text, U_line, U_final, U_finType, U_mission, U_misType, U_misTearDur,
             U_open, U_openSpan, U_calib, U_warmStage, U_disStage, U_slipStart, U_slipEnd, U_flare, U_sweep, U_decay, U_dump, U_barSpan;
        long[] U_misTear; int CaretShr;
        int C_fill, C_scan, C_text, C_flare, C_caret, C_art, C_lip, C_ghost, C_sweep, C_track, C_dump, C_calib;
        int[] C_decay; int[][] C_warm; int[][] Dis;
        double P_font, P_misSmall, P_misBig, P_lineH, P_banGap, P_finalH, P_txtX, P_txtY, P_inkW, P_barX, P_barY, P_barW, P_barH, P_finalY,
               P_misX, P_misY, P_misTextTop, P_misSmH, P_misObjRow, P_misBigH, P_misW, P_icon, P_misTearPx,
               P_dumpX, P_dumpY, P_hexCell, P_edgeMargin, P_blkMargin, P_ghostRows, P_sweepRows;
        int DumpCols, DumpRows, DumpFast, DumpSlow, GlyphCells, GlyphOdds;
        int[] TearRows, TearShift, Split, Slip; double[] CalibR;

        // ---- the look (HD only: the 8-bit boot has none of these) -------------------------
        /// <summary>THE RASTER (Josh, 2026-10-07: "more noticeable interlacing, not thicker, more contrast"):
        /// one dark line of ONE picture pixel every ScanPeriod rows, over everything on the tube -- type
        /// included, as on a real CRT. ScanDark is how much darker that line is; ScanAfter the faint
        /// fall-off on the row after it (the beam's spot is round, not square).</summary>
        public double ScanDark = 0.34, ScanAfter = 0.08;
        public int ScanPeriod = 3;
        /// <summary>How far the dark line also leans toward the tube's scan colour (its hue).</summary>
        public double ScanTint = 0.35;
        /// <summary>The visor's own shading over the top of the view (HUDTOP, drawn smooth by the host).</summary>
        public VisorShade Shade;
        /// <summary>Darkening at the corners of the screen (0 = none).</summary>
        public double Vignette = 0.22;
        /// <summary>Strength and radius (game px) of the phosphor glow round the ink.</summary>
        public double Glow = 0.16, GlowRadius = 1.3;
        // THE INK (Josh, 2026-10-07: "the teal text is really hard to read -- a dark amber/brown"). The 8-bit
        // boot's teal sits too close to the amber in brightness; dark brown reads as unlit phosphor on a lit
        // screen. The newest line still flares -- to burnt orange -- and the fade before the mission walks
        // the ink back into the screen. The telemetry column keeps its own colour.
        // ...AND THEN BRIGHT (Josh, same day: "the dark brown isn't great -- a brighter orange/amber"). Bright amber
        // is LIT phosphor, which is right for a CRT -- but on this light amber screen it has almost no contrast of
        // its own (WCAG ratio about 1.3). So every line carries a tight DARK HALO, the screen's shadow round the
        // strokes: that is what makes it read (about 9:1 against the halo). The 7s are the 8-bit boot's teal again.
        // COMPARED (Josh: "make sure there is enough contrast"): bright amber on the 8-bit boot's light screen is
        // 1.27:1 -- unreadable without a heavy outline, which looked like comic lettering. A DEEPER SCREEN is how
        // real amber monitors did it: at 55% of the 8-bit boot's brightness the type is 3.9:1 on its own, and a
        // soft dark edge sharpens it further (45% and no edge measured 5.4:1, the alternative).
        public static int InkDefault = 0xFFBF4A, FlareDefault = 0xFFF1C4;
        /// <summary>The dark halo round the readout's strokes (not the hex column's), and how strong it is.</summary>
        public int Halo = 0x241204; public double HaloK = 0.45;
        int C_teal, C_tealFlare; int[] C_tealDecay;
        public void UseInk(int ink, int flare)
        {
            if (C_tealDecay == null)
            {   // the 8-bit boot's own inks, kept for the 7s
                C_teal = C_text; C_tealFlare = C_flare; C_tealDecay = (int[])C_decay.Clone();
            }
            C_text = ink; C_flare = flare; C_caret = ink;
            int fill = Screen(C_warm[C_warm.Length - 1][0]), n = Math.Max(1, C_decay.Length);     // (fades into the screen as it is drawn)
            for (int i = 0; i < C_decay.Length; i++) C_decay[i] = Lerp(ink, fill, (i + 1) / (double)(n + 1));
        }
        /// <summary>The guest draws a frame about every 42 ms during the boot; the random beats re-roll at that rate.</summary>
        public long TickUs = 41667;
        /// <summary>Wind the guest's boot to its end when the shutter beat is reached, so the takeover starts at once.</summary>
        public bool FastForward = true;
        // A LOAD IS NOT A BOOT (Josh, 2026-10-10: "the boot animation is playing in the background during the loading sequence
        // ... The boot-in sequence should never display until after the loading sequence is complete" -- and a fast load hands
        // over directly to the game). The re-boot after a load is only the COVER for the renderer's room load: it shows the
        // last game picture (LoadHeld, from the watcher at the load's OK; black when there is none -- a load from the title,
        // which covers it anyway) with the loading panel drawn over it by the overlay's decorators -- no boot visuals, no boot
        // sounds -- and when the renderer's view is up it is simply the game's: no shutter, no calibration.
        public bool LoadCover = true;
        public volatile int[] LoadHeld; public volatile int LoadHeldW, LoadHeldH;
        bool Covering4Load { get { return _reboot && LoadCover; } }
        /// <summary>How long to hold the shutter beat for a Reveal() before giving up and getting out of the way.</summary>
        public int HoldMaxMs = 10000;
        /// <summary>(Stopwatch ticks) the hold does not give up before this: the watcher keeps it ahead while it is still loading
        /// the room's textures under the cover, a big room's can outlast HoldMaxMs on a slow machine.</summary>
        public long HoldExtendUntil;
        /// <summary>THE RENDERER IS STILL PREPARING THE ROOM (2026-10-15, the second PC: its first room took 61 s on a fresh install
        /// -- the shared-art index and every texture read for the first time -- and the hold gave up after HoldMaxMs, so the 8-bit
        /// game showed): while this is set the hold waits, up to HoldBusyMaxMs, with BusyText under the briefing.</summary>
        public volatile bool HoldWhileBusy; public volatile string BusyText = ""; public int HoldBusyMaxMs = 180000;
        /// <summary>The boot's own frame rate: the game draws its boot at about 24, so 40 is smooth at a fraction of the work.</summary>
        public int Fps = 40;

        // ---- where it draws ----------------------------------------------------------------
        public int PicW, PicH, ViewRows;
        Overlay _ov; int _pid; long _aState, _aReboot;     // aztBootState; T0 is +12, El +16 (contiguous in the overlay's BSS)

        public static BootHd Load(string path, int[] pal32)
        {
            var d = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path));
            var b = new BootHd();
            b._banner = Strs(d["banner"]); b._lines = Strs(d["lines"]); b._final = (string)d["final"];
            b._misSmall = Strs(d["missionSmall"]); b._mission = (string)d["mission"];
            b.InjW = I(d["injW"]); b.InjH = I(d["injH"]);
            // The 8-bit readout is capped below its designed size by the overlay's memory (its
            // bitmaps are stored 1bpp in BSS). The host has no such cap: draw at the design.
            if (d.ContainsKey("scale") && d.ContainsKey("designW"))
                b.Zoom = Math.Max(1.0, (b.InjW / N(d["designW"])) / N(d["scale"]));
            var u = (Dictionary<string, object>)d["us"];
            b.U_hold = L(u["hold"]); b.U_banner = L(u["banner"]); b.U_banStep = L(u["banStep"]); b.U_text = L(u["text"]); b.U_line = L(u["line"]);
            b.U_final = L(u["final"]); b.U_finType = L(u["finType"]); b.U_mission = L(u["mission"]); b.U_misType = L(u["misType"]);
            var mt = (object[])u["misTear"]; b.U_misTear = new long[mt.Length]; for (int i = 0; i < mt.Length; i++) b.U_misTear[i] = L(mt[i]);
            b.U_misTearDur = L(u["misTearDur"]); b.U_open = L(u["open"]); b.U_openSpan = L(u["openSpan"]); b.U_calib = L(u["calib"]);
            b.U_warmStage = L(u["warmStage"]); b.U_disStage = L(u["disStage"]); b.U_slipStart = L(u["slipStart"]); b.U_slipEnd = L(u["slipEnd"]);
            b.U_flare = L(u["flare"]); b.CaretShr = I(u["caretShr"]); b.U_sweep = L(u["sweep"]); b.U_decay = L(u["decay"]); b.U_dump = L(u["dump"]); b.U_barSpan = L(u["barSpan"]);
            var k = (Dictionary<string, object>)d["ink"];
            Func<object, int> C = o => pal32[I(o)] & 0xFFFFFF;
            b.C_fill = C(k["fill"]); b.C_scan = C(k["scan"]); b.C_text = C(k["text"]); b.C_flare = C(k["flare"]); b.C_caret = C(k["caret"]);
            b.C_art = C(k["art"]); b.C_lip = C(k["lip"]); b.C_ghost = C(k["ghost"]); b.C_sweep = C(k["sweep"]); b.C_track = C(k["track"]);
            b.C_dump = C(k["dump"]); b.C_calib = C(k["calib"]);
            var dk = (object[])k["decay"]; b.C_decay = new int[dk.Length]; for (int i = 0; i < dk.Length; i++) b.C_decay[i] = C(dk[i]);
            var wm = (object[])k["warm"]; b.C_warm = new int[wm.Length][];
            for (int i = 0; i < wm.Length; i++) { var p = (object[])wm[i]; b.C_warm[i] = new[] { C(p[0]), C(p[1]) }; }
            var ds = (object[])d["dis"]; b.Dis = new int[ds.Length][]; for (int i = 0; i < ds.Length; i++) b.Dis[i] = Ints(ds[i]);
            var x = (Dictionary<string, object>)d["px"];
            b.P_font = N(x["font"]); b.P_misSmall = N(x["misSmall"]); b.P_misBig = N(x["misBig"]); b.P_lineH = N(x["lineH"]); b.P_banGap = N(x["banGap"]);
            b.P_finalH = N(x["finalH"]); b.P_txtX = N(x["txtX"]); b.P_txtY = N(x["txtY"]); b.P_inkW = N(x["inkW"]);
            b.P_barX = N(x["barX"]); b.P_barY = N(x["barY"]); b.P_barW = N(x["barW"]); b.P_barH = N(x["barH"]); b.P_finalY = N(x["finalY"]);
            b.P_misX = N(x["misX"]); b.P_misY = N(x["misY"]); b.P_misTextTop = N(x["misTextTop"]); b.P_misSmH = N(x["misSmH"]); b.P_misObjRow = N(x["misObjRow"]);
            b.P_misBigH = N(x["misBigH"]); b.P_misW = N(x["misW"]); b.P_icon = N(x["icon"]); b.P_misTearPx = N(x["misTearPx"]);
            b.P_dumpX = N(x["dumpX"]); b.P_dumpY = N(x["dumpY"]); b.DumpCols = I(x["dumpCols"]); b.DumpRows = I(x["dumpRows"]); b.P_hexCell = N(x["hexCell"]);
            b.DumpFast = I(x["dumpFast"]); b.DumpSlow = I(x["dumpSlow"]); b.GlyphCells = I(x["glyphCells"]); b.GlyphOdds = I(x["glyphOdds"]);
            b.P_edgeMargin = N(x["edgeMargin"]); b.P_blkMargin = N(x["blkMargin"]);
            b.TearRows = Ints(x["tearRows"]); b.TearShift = Ints(x["tearShift"]); b.Split = Ints(x["split"]); b.Slip = Ints(x["slip"]);
            b.P_sweepRows = N(x["sweepRows"]); b.P_ghostRows = N(x["ghostRows"]);
            var cr = Ints(x["calibR"]); b.CalibR = new double[] { cr[0], cr[1] };
            b.UseInk(InkDefault, FlareDefault);        // (last: it blends toward the screen's colour, loaded above)
            // the heart-rate line says what the trace beats (Josh, 2026-10-07: 125 -> 90 BPM; the 8-bit boot keeps its own)
            for (int i = 0; i < b._lines.Length; i++)
                b._lines[i] = System.Text.RegularExpressions.Regex.Replace(b._lines[i], @"\d+BPM", ((int)Math.Round(b.HeartBpm)) + "BPM");
            return b;
        }
        static int I(object o) { return Convert.ToInt32(o); }
        static long L(object o) { return Convert.ToInt64(o); }
        static double N(object o) { return Convert.ToDouble(o); }
        static string[] Strs(object o) { var a = (object[])o; var r = new string[a.Length]; for (int i = 0; i < a.Length; i++) r[i] = (string)a[i]; return r; }
        static int[] Ints(object o) { var a = (object[])o; var r = new int[a.Length]; for (int i = 0; i < a.Length; i++) r[i] = I(a[i]); return r; }

        // =====================================================================================
        // LAYOUT: everything is placed where the guest places it, through the same mapping the
        // overlay uses to lay the game's 1600x928 view over the picture (centred, the picture's
        // view rows tall). So a line of the readout sits exactly where the 8-bit one would.
        // =====================================================================================
        class Item { public int X, Y, W, H, Pad, HaloPad; public byte[] Cov, GlowM, HaloM; public double Adv; public int Chars; }
        int _lw, _lh, _lvr; double _s, _cx;
        Item[] _lineItems; Item _finalItem; Item _icon; Item[] _misSmallItems; Item _misItem; Item[] _hex;
        double Xp(double gx) { return _cx + (gx - InjW / 2.0) * _s; }
        double Yp(double gy) { return gy * _s; }
        int Px(double g) { return Math.Max(1, (int)Math.Round(g * _s)); }
        /// <summary>Extra size for the TYPE and its blocks, about the middle of the view (1 = the 8-bit boot's own size).</summary>
        public double Zoom = 1.0;
        /// <summary>THE 7 AND THE READOUT A LITTLE TO THE LEFT (Josh, 2026-10-14: "the entire 7 animation and text to be slightly
        /// moved to the left"), game px: its lines, the 7 and its logotype, the bar and the closing line (the heart trace rides
        /// its line). The briefing stays where it was.</summary>
        public double ReadoutShift = -60;
        double TxtX { get { return P_txtX + ReadoutShift; } }
        double Xt(double gx) { return _cx + (gx - InjW / 2.0) * _s * Zoom; }
        double Yt(double gy) { return _lvr / 2.0 + (gy - InjH / 2.0) * _s * Zoom; }
        int Pt(double g) { return Math.Max(1, (int)Math.Round(g * _s * Zoom)); }

        void EnsureLayout(int pw, int ph, int vr)
        {
            if (pw == _lw && ph == _lh && vr == _lvr) return;
            _lw = pw; _lh = ph; _lvr = vr; _s = (double)vr / InjH; _cx = pw / 2.0; _bgFor = -1;
            int n = _banner.Length + _lines.Length;
            _lineItems = new Item[n];
            for (int i = 0; i < n; i++)
            {
                string t = i < _banner.Length ? _banner[i] : _lines[i - _banner.Length];
                double gy = P_txtY + i * P_lineH + (i >= _banner.Length ? P_banGap : 0);
                _lineItems[i] = TextItem(t, P_font, Xt(TxtX), Yt(gy), P_lineH);
            }
            _finalItem = TextItem(_final, P_font, Xt(TxtX), Yt(P_finalY), P_finalH);
            _misSmallItems = new Item[_misSmall.Length];
            for (int i = 0; i < _misSmall.Length; i++) _misSmallItems[i] = TextItem(_misSmall[i], P_misSmall, Xt(P_misX), Yt(P_misY + P_misTextTop + i * P_misSmH), P_misSmH);
            _misItem = TextItem(_mission, P_misBig, Xt(P_misX), Yt(P_misY + P_misObjRow), P_misBigH);
            _icon = IconItem(Xt(P_misX), Yt(P_misY), P_icon);
            _hex = new Item[16];
            for (int i = 0; i < 16; i++) _hex[i] = TextItem("0123456789ABCDEF".Substring(i, 1), P_font, 0, 0, P_lineH);
        }

        StringFormat Fmt()
        {
            var f = (StringFormat)StringFormat.GenericTypographic.Clone();
            f.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;
            return f;
        }
        // Antialiased type, white on black; the red channel is the coverage. Integer pixel
        // sizes are no longer a constraint (that was for the bilevel threshold), so the scaled
        // size is used as it is.
        Item TextItem(string text, double emGame, double x, double y, double boxGame)
        {
            float em = (float)Math.Max(6, emGame * _s * Zoom);
            using (var font = new Font("Consolas", em, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var fmt = Fmt())
            {
                SizeF sz, ten;
                using (var mb = new Bitmap(8, 8)) using (var mg = Graphics.FromImage(mb))
                { sz = mg.MeasureString(text, font, PointF.Empty, fmt); ten = mg.MeasureString("0000000000", font, PointF.Empty, fmt); }
                int w = Math.Max(2, (int)Math.Ceiling(sz.Width) + 2), h = Math.Max(2, (int)Math.Ceiling(boxGame * _s * Zoom));
                var it = new Item { X = (int)Math.Round(x), Y = (int)Math.Round(y), W = w, H = h, Adv = ten.Width / 10.0, Chars = text.Length };
                using (var bm = new Bitmap(w, h, PixelFormat.Format32bppArgb))
                {
                    using (var g = Graphics.FromImage(bm))
                    {
                        g.Clear(Color.Black); g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                        // the glyphs' cap height sits in the middle of the line box the guest gave it
                        float top = (float)Math.Max(0, (h - font.GetHeight()) / 2.0);
                        g.DrawString(text, font, Brushes.White, 0, top, fmt);
                    }
                    it.Cov = Coverage(bm);
                }
                MakeGlow(it);
                return it;
            }
        }
        // The warning octagon with its "!" punched out, as the guest draws it, but smooth.
        Item IconItem(double x, double y, double nGame)
        {
            int n = Math.Max(8, (int)Math.Round(nGame * _s * Zoom));
            var it = new Item { X = (int)Math.Round(x), Y = (int)Math.Round(y), W = n + 2, H = n + 2 };
            using (var bm = new Bitmap(it.W, it.H, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bm))
                {
                    g.Clear(Color.Black); g.SmoothingMode = SmoothingMode.AntiAlias;
                    float c = n * 0.293f, o = 0.5f;
                    g.FillPolygon(Brushes.White, new[] { new PointF(o + c, o), new PointF(o + n - c, o), new PointF(o + n, o + c), new PointF(o + n, o + n - c),
                                                          new PointF(o + n - c, o + n), new PointF(o + c, o + n), new PointF(o, o + n - c), new PointF(o, o + c) });
                    float bw = Math.Max(2f, n / 7f), bx = o + (n - bw) / 2f;
                    g.FillRectangle(Brushes.Black, bx, o + n * 0.20f, bw, n * 0.42f);
                    g.FillRectangle(Brushes.Black, bx, o + n * 0.72f, bw, n * 0.15f);
                }
                it.Cov = Coverage(bm);
            }
            MakeGlow(it);
            return it;
        }
        static byte[] Coverage(Bitmap bm)
        {
            int w = bm.Width, h = bm.Height;
            var bd = bm.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var px = new int[w * h]; Marshal.Copy(bd.Scan0, px, 0, px.Length); bm.UnlockBits(bd);
            var c = new byte[w * h]; for (int i = 0; i < c.Length; i++) c[i] = (byte)((px[i] >> 16) & 255);
            return c;
        }
        // Two box blurs of the coverage, on a margin wide enough to hold them.
        void MakeGlow(Item it)
        {
            int r = Math.Max(1, (int)Math.Round(GlowRadius * _s)), pad = 2 * r;
            int gw = it.W + 2 * pad, gh = it.H + 2 * pad;
            var a = new float[gw * gh];
            for (int y = 0; y < it.H; y++) for (int x = 0; x < it.W; x++) a[(y + pad) * gw + x + pad] = it.Cov[y * it.W + x];
            var b = new float[gw * gh];
            for (int pass = 0; pass < 2; pass++) { BoxH(a, b, gw, gh, r); BoxV(b, a, gw, gh, r); }
            it.GlowM = new byte[gw * gh]; it.Pad = pad;
            for (int i = 0; i < a.Length; i++) it.GlowM[i] = (byte)Math.Min(255, a[i] * 1.6f);
            // THE HALO's own mask: the strokes grown by about a game pixel (a max filter, so the edge is crisp), then
            // softened by one pixel -- an outline, not a shadow; a blur alone read as a smudge round the type
            int hr = Math.Max(1, (int)Math.Round(HaloPx * _s)), hp = hr + 1, hw = it.W + 2 * hp, hh = it.H + 2 * hp;
            var dil = new float[hw * hh];
            for (int y = 0; y < hh; y++) for (int x = 0; x < hw; x++)
            {
                float m = 0; int sy0 = y - hp, sx0 = x - hp;
                for (int dy = -hr; dy <= hr && m < 255; dy++)
                {
                    int yy = sy0 + dy; if (yy < 0 || yy >= it.H) continue;
                    for (int dx = -hr; dx <= hr; dx++)
                    {
                        int xx = sx0 + dx; if (xx < 0 || xx >= it.W) continue;
                        if (dx * dx + dy * dy > hr * hr + hr) continue;
                        float c = it.Cov[yy * it.W + xx]; if (c > m) m = c;
                    }
                }
                dil[y * hw + x] = m;
            }
            var tmp = new float[hw * hh]; BoxH(dil, tmp, hw, hh, 1); BoxV(tmp, dil, hw, hh, 1);
            it.HaloM = new byte[hw * hh]; it.HaloPad = hp;
            for (int i = 0; i < dil.Length; i++) it.HaloM[i] = (byte)Math.Min(255, dil[i]);
        }
        /// <summary>How far the halo reaches round the strokes, in game px.</summary>
        public double HaloPx = 0.5;
        /// <summary>The tube's brightness (1 = the 8-bit boot's amber): lower makes a deeper screen for bright type.</summary>
        public double ScreenDim = 0.55;
        /// <summary>...and warmed as it deepens (red, green, blue): the 8-bit boot's khaki darkened alone goes olive,
        /// and an amber tube's dark is a warm brown.</summary>
        public double[] ScreenWarm = { 1.12, 0.92, 0.65 };
        int Screen(int c)
        {
            if (ScreenDim == 1 && ScreenWarm == null) return c;
            double[] w = ScreenWarm ?? new[] { 1.0, 1.0, 1.0 };
            int r = (int)Math.Min(255, ((c >> 16) & 255) * ScreenDim * w[0]), g = (int)Math.Min(255, ((c >> 8) & 255) * ScreenDim * w[1]), b = (int)Math.Min(255, (c & 255) * ScreenDim * w[2]);
            return (r << 16) | (g << 8) | b;
        }
        static void BoxH(float[] s, float[] d, int w, int h, int r)
        {
            float k = 1f / (2 * r + 1);
            for (int y = 0; y < h; y++) { int o = y * w; float acc = 0; for (int x = -r; x <= r; x++) acc += x >= 0 && x < w ? s[o + x] : 0;
                for (int x = 0; x < w; x++) { d[o + x] = acc * k; int xo = x - r, xi = x + r + 1; if (xo >= 0) acc -= s[o + xo]; if (xi < w) acc += s[o + xi]; } }
        }
        static void BoxV(float[] s, float[] d, int w, int h, int r)
        {
            float k = 1f / (2 * r + 1);
            for (int x = 0; x < w; x++) { float acc = 0; for (int y = -r; y <= r; y++) acc += y >= 0 && y < h ? s[y * w + x] : 0;
                for (int y = 0; y < h; y++) { d[y * w + x] = acc * k; int yo = y - r, yi = y + r + 1; if (yo >= 0) acc -= s[yo * w + x]; if (yi < h) acc += s[yi * w + x]; } }
        }

        // =====================================================================================
        // THE SCREEN: the tube's colour for this warm-up stage under a vignette. Built once per
        // stage (eight times a boot), then copied in whole every frame. The raster goes on last.
        // =====================================================================================
        int[] _bg; int _bgFor = -1;
        void EnsureBg(int stage)
        {
            if (stage == _bgFor && _bg != null) return;
            int pw = _lw, vr = _lvr; if (_bg == null || _bg.Length != pw * vr) _bg = new int[pw * vr];
            int fill = C_warm[stage][0];
            fill = Screen(fill);
            var vx = new double[pw]; for (int x = 0; x < pw; x++) { double d = (x + 0.5) / pw * 2 - 1; vx[x] = d * d; }
            var bg = _bg; double vig = Vignette;
            int rr = (fill >> 16) & 255, rg = (fill >> 8) & 255, rb = fill & 255;
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                double dy = (y + 0.5) / vr * 2 - 1; dy *= dy;
                int o = y * pw;
                for (int x = 0; x < pw; x++)
                {
                    double v = 1 - vig * Math.Pow((vx[x] + dy) * 0.5, 1.3);
                    bg[o + x] = ((int)(rr * v) << 16) | ((int)(rg * v) << 8) | (int)(rb * v);
                }
            });
            _bgFor = stage;
        }
        // The raster over the whole tube: crisp 1-pixel dark lines (drawn at the window's own size, so
        // they are never resampled into a blur or a beat pattern).
        void Raster(int[] pic, int pw, int vr, int scanCol, double strength)
        {
            int per = Math.Max(2, ScanPeriod), kd = (int)(256 * (1 - ScanDark * strength)), ka = (int)(256 * (1 - ScanAfter * strength)), tint = (int)(256 * ScanTint * strength);
            int sr = (scanCol >> 16) & 255, sg = (scanCol >> 8) & 255, sb = scanCol & 255;
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                int ph = y % per; if (ph > 1) return;
                int k = ph == 0 ? kd : ka, t = ph == 0 ? tint : 0, o = y * pw;
                for (int x = 0; x < pw; x++)
                {
                    int c = pic[o + x], r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
                    if (t > 0) { r += (sr - r) * t >> 8; g += (sg - g) * t >> 8; b += (sb - b) * t >> 8; }
                    pic[o + x] = ((r * k >> 8) << 16) | ((g * k >> 8) << 8) | (b * k >> 8);
                }
            });
        }

        static int Lerp(int a, int b, double t)
        {
            if (t <= 0) return a; if (t >= 1) return b;
            int ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255, br = (b >> 16) & 255, bgc = (b >> 8) & 255, bb = b & 255;
            return ((int)(ar + (br - ar) * t) << 16) | ((int)(ag + (bgc - ag) * t) << 8) | (int)(ab + (bb - ab) * t);
        }
        static int Lerp256(int a, int b, int t)    // t 0..256
        {
            int ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255;
            return ((ar + ((((b >> 16) & 255) - ar) * t >> 8)) << 16) | ((ag + ((((b >> 8) & 255) - ag) * t >> 8)) << 8) | (ab + (((b & 255) - ab) * t >> 8));
        }

        // =====================================================================================
        // THE RANDOM BEATS. The guest re-rolls them once a frame from an LCG; here they are a
        // hash of the tick, so a host frame drawn twice inside one guest frame shows the same
        // damage, and the rate the eye sees is the guest's rather than the display's.
        // =====================================================================================
        struct Rng
        {
            uint _s;
            public Rng(long tick, uint salt) { _s = (uint)(tick * 2654435761L) ^ (salt * 0x9E3779B9u) ^ 0x5bd1e995u; Next(); Next(); }
            public uint Next() { uint x = _s; x ^= x << 13; x ^= x >> 17; x ^= x << 5; _s = x; return x * 0x2545F491u; }
            public int Below(int n) { return n <= 0 ? 0 : (int)(Next() % (uint)n); }
        }
        long _lastTick = long.MinValue; int _slipLeft, _slipRows; byte[] _cells;
        // The state the guest carries from frame to frame -- the held slip and the telemetry
        // digits -- is stepped tick by tick, so it changes at the guest's rate.
        void Advance(long tick, long el)
        {
            int nc = DumpCols * DumpRows;
            if (_cells == null || _cells.Length != nc || tick < _lastTick || _lastTick == long.MinValue)
            {
                _cells = new byte[nc]; var r0 = new Rng(tick, 7); for (int i = 0; i < nc; i++) _cells[i] = (byte)r0.Below(16);
                _slipLeft = 0; _lastTick = tick; return;
            }
            long from = Math.Max(_lastTick + 1, tick - 8);
            for (long t = from; t <= tick; t++)
            {
                long et = Math.Min(el, t * TickUs);
                var r = new Rng(t, 11);
                // the hold slip: fires, then holds the same roll for a few frames
                if (et >= U_slipStart && et < U_slipEnd)
                {
                    if (_slipLeft > 0) _slipLeft--;
                    else
                    {
                        int odds = et < DisruptUs ? Slip[3] : Slip[4];
                        if ((r.Next() & (uint)odds) == 0) { _slipRows = (Slip[0] + r.Below(Slip[1])) * ((r.Next() & 1) == 0 ? 1 : -1); _slipLeft = Slip[2]; }
                        else _slipRows = 0;
                    }
                }
                else { _slipLeft = 0; _slipRows = 0; }
                // the telemetry column: fast while the visor is damaged, slow after, frozen at the shutter
                if (et >= U_dump && et < U_open)
                {
                    int roll = et < DisruptUs ? DumpFast : DumpSlow;
                    for (int i = 0; i < roll; i++) _cells[r.Below(nc)] = (byte)r.Below(16);
                }
            }
            _lastTick = tick;
        }
        long DisruptUs { get { return Dis.Length * U_disStage; } }
        long DecayFrom { get { return U_mission - U_decay; } }

        // =====================================================================================
        // ONE FRAME of the boot at guest time `el` (microseconds). `sweepEl` drives the refresh
        // line separately, so the held screen at the end keeps its beat.
        // =====================================================================================
        public void RenderAt(int[] pic, int pw, int ph, int vr, long el, long sweepEl, bool reboot, bool sweep, double dtMs = 0)
        {
            EnsureLayout(pw, ph, vr);
            _reboot = reboot;                         // (what the status column reads: the same answer as the rest of this frame)
            int stages = C_warm.Length;
            int stage = (int)Math.Min(stages - 1, Math.Max(0, el / U_warmStage));
            EnsureBg(stage);
            Buffer.BlockCopy(_bg, 0, pic, 0, pw * vr * 4);
            if (ph > vr) Array.Clear(pic, pw * vr, pw * (ph - vr));
            long tick = el / TickUs;
            Advance(tick, el);
            int scanCol = C_warm[stage][1];

            if (el < U_mission)
            {
                if (el < DisruptUs) DrawDisruption(pic, el, tick, scanCol);
                bool decaying = el >= DecayFrom;
                int ink = C_text, teal = C_teal;
                if (decaying) { int st = (int)Math.Min(C_decay.Length - 1, (el - DecayFrom) * C_decay.Length / Math.Max(1, U_decay)); ink = C_decay[st]; teal = C_tealDecay[Math.Min(st, C_tealDecay.Length - 1)]; }
                DrawHeartBig(pic, pw, ph, vr, el, ink);        // (behind everything on the screen)
                int shown = DrawReadout(pic, el, ink, teal);
                DrawHeart(pic, pw, ph, vr, el, ink);
                DrawBar(pic, el, ink);
                DrawDump(pic, el);
                if (el >= U_final) DrawTyped(pic, new[] { _finalItem }, _finalItem.X, _finalItem.W, el - U_final, U_finType, ink, _finalItem, el);
                if (!decaying)
                {
                    DrawGlyphs(pic, tick, shown);
                    if (el < DisruptUs) { DrawTear(pic, el, tick); DrawSplit(pic, tick); }
                }
            }
            else
            {
                DrawDump(pic, el);
                DrawWatermark(pic, pw, vr, el);      // (the grail behind the briefing: 2026-10-14)
                if (!reboot)
                {
                    // line by line: the icon with the first MISSION line, then the second, then the OBJECTIVE
                    for (int i = 0; i < MisLine.Length; i++)
                    {
                        long t0 = U_mission + MisStartUs(i); if (el < t0) break;
                        Item line = i < _misSmallItems.Length ? _misSmallItems[i] : _misItem;
                        Item[] items = i == 0 ? new[] { _icon, line } : new[] { line };
                        int x0 = i == 0 ? Math.Min(_icon.X, line.X) : line.X, w = line.X + line.W - x0;
                        DrawTyped(pic, items, x0, w, el - t0, (long)(MisLine[i] * 1e6), C_text, line, el);
                    }
                    foreach (long t0 in U_misTear)
                        if (el >= t0 && el < t0 + U_misTearDur)
                        {
                            int x0 = (int)Math.Round(Xt(P_misX)) - Pt(8), w = Pt(P_misW + 16);
                            RotateRows(pic, pw, _misItem.Y, _misItem.Y + _misItem.H, x0, w, Pt(P_misTearPx));
                        }
                }
            }
            // the status column on the right (the lock-on brackets round the text were tried and taken out, Josh 2026-10-07)
            if (StatusColumn && el >= U_dump)
                Paint(pic, pw, ph, g => { g.SetClip(new RectangleF(0, 0, pw, vr)); DrawStatus(g, pw, el); });
            if (_slipRows != 0 && el >= U_slipStart && el < U_slipEnd) Roll(pic, pw, vr, (int)Math.Round(_slipRows * _s));
            // the faults on the tube: the hum bar drifting up and the snow thinning out (a new speckle every frame)
            HumAndSnow(pic, pw, vr, el, el / 20000);
            // THE POWER-ON: dot, line, the line opening into the screen (black round it)
            if (el < PowerUs) PowerMask(pic, pw, vr, el);
            // THE TUBE (first look batch, Josh 2026-10-07): phosphor afterglow, then bloom, the glass's curve
            // and the beams' convergence error in one pass -- and the raster last, which is the tube's own
            // and stays put while the picture slips
            Persist(pic, pw, vr, dtMs);
            // the refresh line AFTER the afterglow: it moves ~20 px a frame, so a trail of it is a stack of separate lines
            if (sweep && el >= PowerUs) DrawSweep(pic, sweepEl);
            Tube(pic, pw, vr, el, tick);
            Purity(pic, pw, vr, el);                // the degauss's colour blotches, on the glass
            if (ScanDark > 0) Raster(pic, pw, vr, scanCol, 1.0);
        }

        // ---- 1. PHOSPHOR AFTERGLOW: light lingers, dark does not ---------------------------------
        /// <summary>How long a lit pixel takes to fade to a third (ms); 0 = off.</summary>
        public double AfterglowMs = 55;
        int[] _ag;
        void Persist(int[] pic, int pw, int vr, double dtMs)
        {
            int n = pw * vr;
            if (_ag == null || _ag.Length != n || dtMs <= 0 || dtMs > 250 || AfterglowMs <= 0)
            { if (_ag == null || _ag.Length != n) _ag = new int[n]; Buffer.BlockCopy(pic, 0, _ag, 0, n * 4); return; }
            int k = (int)(256 * Math.Exp(-dtMs / AfterglowMs)); var ag = _ag;
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                for (int i = y * pw, e = i + pw; i < e; i++)
                {
                    int c = pic[i], p = ag[i];
                    if (Lum(p) > Lum(c) + 3) c = Lerp256(c, p, k);
                    pic[i] = c; ag[i] = c;
                }
            });
        }
        static int Lum(int c) { return (((c >> 16) & 255) * 77 + ((c >> 8) & 255) * 150 + (c & 255) * 29) >> 8; }

        // ---- 2 + 3. BLOOM, CURVATURE, CONVERGENCE ------------------------------------------------
        /// <summary>The glass's bulge: how far the edges bow at the middle of the opposite edge (share of the half-size).</summary>
        public double CurveX = 0.0, CurveY = 0.045;          // (CurveX 0.030 -> 0: Josh, 2026-10-07 -- "the curve at the top is perfect, but the sides can be full width")
        /// <summary>Bright light bleeding into the glass: strength, and how far above the screen's own brightness it starts.</summary>
        public double Bloom = 0.55; public int BloomAbove = 18;
        /// <summary>The red and blue beams' misalignment at the screen's edges (game px), pulling in to nothing
        /// as the system check completes; and the extra kick a glitch gives it.</summary>
        public double ConvMax = 9.0, ConvKick = 4.0;
        /// <summary>How the error is spread: this share everywhere (so the type in the middle fringes too), the rest growing toward the edges; and its vertical share.</summary>
        public double ConvFlat = 0.45, ConvVert = 0.3;
        int[] _tsrc, _wob; float[] _br, _bt; int _bw, _bh; bool[] _bRow;
        static readonly System.Threading.Tasks.ParallelOptions _par = new System.Threading.Tasks.ParallelOptions { MaxDegreeOfParallelism = Math.Max(2, Environment.ProcessorCount - 2) };
        double ConvAt(long el, long tick)
        {
            double done = U_final + U_finType, f = Math.Max(0, 1 - el / done);
            double c = ConvMax * Math.Pow(f, 1.5);
            if (el < DisruptUs) { var r = new Rng(tick, 17); if (r.Below(100) < 14) c += ConvKick * (0.5 + 0.5 * f); }
            // the degauss: the beams swing well apart and back, red and blue changing sides, dying away (signed)
            double env; c += DegaussConv * DegaussSwing(el, out env);
            return c * _s;
        }
        // The glass's curve, worked out once per size: each pixel's source position (1/256 px) and its
        // edge fade. The frame then only has to look things up.
        int[] _mx, _my; byte[] _me; int _mw, _mvr; double _mkx, _mky;
        void EnsureMap(int pw, int vr)
        {
            if (_mx != null && _mw == pw && _mvr == vr && _mkx == CurveX && _mky == CurveY) return;
            int n = pw * vr; var mx = new int[n]; var my = new int[n]; var me = new byte[n];
            double cx = pw / 2.0, cy = vr / 2.0, kx = CurveX, ky = CurveY;
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                double v = (y + 0.5 - cy) / cy; int o = y * pw;
                for (int x = 0; x < pw; x++)
                {
                    double u = (x + 0.5 - cx) / cx, su = u * (1 + kx * v * v), sv = v * (1 + ky * u * u);
                    double ex = 1 - Math.Abs(su), ey = 1 - Math.Abs(sv);
                    if (ex <= 0 || ey <= 0) { me[o + x] = 0; continue; }
                    me[o + x] = (byte)Math.Max(1, Math.Min(255, 255 * Math.Min(1, Math.Min(ex * cx, ey * cy) / 1.5)));
                    mx[o + x] = (int)Math.Round((cx + su * cx - 0.5) * 256); my[o + x] = (int)Math.Round((cy + sv * cy - 0.5) * 256);
                }
            });
            _mx = mx; _my = my; _me = me; _mw = pw; _mvr = vr; _mkx = kx; _mky = ky;
        }
        void Tube(int[] pic, int pw, int vr, long el, long tick)
        {
            int n = pw * vr;
            if (_tsrc == null || _tsrc.Length != n) _tsrc = new int[n];
            Buffer.BlockCopy(pic, 0, _tsrc, 0, n * 4);
            var src = _tsrc; EnsureMap(pw, vr);
            // bloom: the light above the screen's own brightness, at an eighth of the size, blurred
            const int Q = 8;
            int bw = Math.Max(1, (pw + Q - 1) / Q), bh = Math.Max(1, (vr + Q - 1) / Q); bool bloom = Bloom > 0;
            if (bloom)
            {
                if (_br == null || _br.Length != bw * bh * 3) { _br = new float[bw * bh * 3]; _bt = new float[bw * bh * 3]; }
                _bw = bw; _bh = bh; var br = _br; int thr = Lum(C_warm[C_warm.Length - 1][0]) + BloomAbove;
                System.Threading.Tasks.Parallel.For(0, bh, _par, by =>
                {
                    for (int bx = 0; bx < bw; bx++)
                    {
                        float r = 0, g = 0, b = 0;
                        for (int yy = 1; yy < Q; yy += 2) { int y = by * Q + yy; if (y >= vr) break; for (int xx = 1; xx < Q; xx += 2) { int x = bx * Q + xx; if (x >= pw) break;
                            int c = src[y * pw + x], l = Lum(c); if (l <= thr) continue; float k = (l - thr) / (float)(255 - thr);
                            r += ((c >> 16) & 255) * k; g += ((c >> 8) & 255) * k; b += (c & 255) * k; } }
                        int o = (by * bw + bx) * 3; br[o] = r / 16; br[o + 1] = g / 16; br[o + 2] = b / 16;
                    }
                });
                int rad = Math.Max(1, (int)Math.Round(1.5 * _s));
                for (int pass = 0; pass < 2; pass++) { Box3H(_br, _bt, bw, bh, rad); Box3V(_bt, _br, bw, bh, rad); }
                // which cells have any bloom (with a neighbour's, since the lookup blends four)
                if (_bRow == null || _bRow.Length != bw * bh) _bRow = new bool[bw * bh];
                for (int c = 0; c < bw * bh; c++) _bRow[c] = _br[c * 3] + _br[c * 3 + 1] + _br[c * 3 + 2] > 1.5f;
            }
            double conv = ConvAt(el, tick), cxw = pw / 2.0, cyw = vr / 2.0, cflat = ConvFlat, cvert = ConvVert; float bs = (float)Bloom;
            float[] bl = _br; bool[] brow = _bRow; int[] mx = _mx, my = _my; byte[] me = _me;
            int convK = (int)Math.Round(conv * 256);               // the beams' offset at the edge, 1/256 px
            // the degauss also sways the picture: rows pushed sideways in a slow wave, dying with the swing
            double wenv; DegaussSwing(el, out wenv); int[] wob = null;
            if (wenv > 0.01)
            {
                if (_wob == null || _wob.Length != vr) _wob = new int[vr];
                double amp = DegaussWobble * _s * wenv * 256, tt = el / 1e6;
                for (int y = 0; y < vr; y++) _wob[y] = (int)(amp * Math.Sin(2 * Math.PI * (y / (double)vr * 1.7) + tt * 2 * Math.PI * DegaussHz * 0.9));
                wob = _wob;
            }
            System.Threading.Tasks.Parallel.For(0, vr, _par, y =>
            {
                int o = y * pw, wy = wob != null ? wob[y] : 0;
                for (int x = 0; x < pw; x++)
                {
                    int i = o + x, e = me[i];
                    if (e == 0) { pic[i] = 0; continue; }
                    int sx = mx[i] + wy, sy = my[i];
                    int c0 = SampleQ(src, pw, vr, sx, sy), r = (c0 >> 16) & 255, g = (c0 >> 8) & 255, b = c0 & 255;
                    if (convK != 0)
                    {   // the red and blue beams parted: some everywhere, more toward the edges, a little vertically
                        double su = (sx - cxw * 256) / (cxw * 256), sv = (sy - cyw * 256) / (cyw * 256);
                        int d = (int)(convK * (cflat + (1 - cflat) * su)), dy = (int)(convK * cvert * sv);
                        if (d > 77 || d < -77 || dy > 77 || dy < -77) { r = (SampleQ(src, pw, vr, sx + d, sy + dy) >> 16) & 255; b = SampleQ(src, pw, vr, sx - d, sy - dy) & 255; }
                    }
                    if (bloom)
                    {
                        float qx = sx / (256f * Q) - 0.5f, qy = sy / (256f * Q) - 0.5f;
                        if (qx < 0) qx = 0; if (qy < 0) qy = 0; if (qx > bw - 1.001f) qx = bw - 1.001f; if (qy > bh - 1.001f) qy = bh - 1.001f;
                        int ix = (int)qx, iy = (int)qy;
                        int ci = iy * bw + ix, cr = ix + 1 < bw ? 1 : 0, cd = iy + 1 < bh ? bw : 0;
                        if (brow[ci] || brow[ci + cr] || brow[ci + cd] || brow[ci + cd + cr])
                        {
                            float tx = qx - ix, ty = qy - iy;
                            int i00 = (iy * bw + ix) * 3, i01 = ix + 1 < bw ? i00 + 3 : i00, i10 = iy + 1 < bh ? i00 + bw * 3 : i00, i11 = ix + 1 < bw ? i10 + 3 : i10;
                            float w00 = (1 - tx) * (1 - ty) * bs, w01 = tx * (1 - ty) * bs, w10 = (1 - tx) * ty * bs, w11 = tx * ty * bs;
                            r += (int)(bl[i00] * w00 + bl[i01] * w01 + bl[i10] * w10 + bl[i11] * w11);
                            g += (int)(bl[i00 + 1] * w00 + bl[i01 + 1] * w01 + bl[i10 + 1] * w10 + bl[i11 + 1] * w11);
                            b += (int)(bl[i00 + 2] * w00 + bl[i01 + 2] * w01 + bl[i10 + 2] * w10 + bl[i11 + 2] * w11);
                        }
                    }
                    if (e < 255) { r = r * e >> 8; g = g * e >> 8; b = b * e >> 8; }
                    pic[i] = (Math.Min(255, r) << 16) | (Math.Min(255, g) << 8) | Math.Min(255, b);
                }
            });
        }
        // bilinear at a 1/256-pixel position
        static int SampleQ(int[] s, int w, int h, int x, int y)
        {
            int ix = x >> 8, iy = y >> 8;
            if (ix < 0) { ix = 0; x = 0; } if (iy < 0) { iy = 0; y = 0; }
            if (ix >= w - 1) { ix = w - 2; x = (w - 1) << 8; } if (iy >= h - 1) { iy = h - 2; y = (h - 1) << 8; }
            uint fx = (uint)(x - (ix << 8)), fy = (uint)(y - (iy << 8)); if (fx > 256) fx = 256; if (fy > 256) fy = 256;
            int i = iy * w + ix;
            uint a = (uint)s[i], b = (uint)s[i + 1], c = (uint)s[i + w], d = (uint)s[i + w + 1], nx = 256 - fx, ny = 256 - fy;
            uint tRB = ((a & 0xFF00FF) * nx + (b & 0xFF00FF) * fx) >> 8 & 0xFF00FF, tG = ((a & 0x00FF00) * nx + (b & 0x00FF00) * fx) >> 8 & 0x00FF00;
            uint bRB = ((c & 0xFF00FF) * nx + (d & 0xFF00FF) * fx) >> 8 & 0xFF00FF, bG = ((c & 0x00FF00) * nx + (d & 0x00FF00) * fx) >> 8 & 0x00FF00;
            return (int)(((tRB * ny + bRB * fy) >> 8 & 0xFF00FF) | ((tG * ny + bG * fy) >> 8 & 0x00FF00));
        }        static int Sample(int[] s, int w, int h, double x, double y)
        {
            if (x < 0) x = 0; if (y < 0) y = 0; if (x > w - 1.001) x = w - 1.001; if (y > h - 1.001) y = h - 1.001;
            int ix = (int)x, iy = (int)y; uint fx = (uint)((x - ix) * 256), fy = (uint)((y - iy) * 256);
            int i = iy * w + ix; int ix1 = ix + 1 < w ? 1 : 0, iy1 = iy + 1 < h ? w : 0;
            uint a = (uint)s[i], b = (uint)s[i + ix1], c = (uint)s[i + iy1], d = (uint)s[i + iy1 + ix1], nx = 256 - fx, ny = 256 - fy;
            uint tRB = ((a & 0xFF00FF) * nx + (b & 0xFF00FF) * fx) >> 8 & 0xFF00FF, tG = ((a & 0x00FF00) * nx + (b & 0x00FF00) * fx) >> 8 & 0x00FF00;
            uint bRB = ((c & 0xFF00FF) * nx + (d & 0xFF00FF) * fx) >> 8 & 0xFF00FF, bG = ((c & 0x00FF00) * nx + (d & 0x00FF00) * fx) >> 8 & 0x00FF00;
            return (int)(((tRB * ny + bRB * fy) >> 8 & 0xFF00FF) | ((tG * ny + bG * fy) >> 8 & 0x00FF00));
        }
        static void Box3H(float[] s, float[] d, int w, int h, int r)
        {
            float k = 1f / (2 * r + 1);
            System.Threading.Tasks.Parallel.For(0, h, y =>
            {
                for (int ch = 0; ch < 3; ch++)
                {
                    int o = y * w * 3 + ch; float acc = 0;
                    for (int x = -r; x <= r; x++) acc += s[o + Math.Max(0, Math.Min(w - 1, x)) * 3];
                    for (int x = 0; x < w; x++) { d[o + x * 3] = acc * k; acc += s[o + Math.Min(w - 1, x + r + 1) * 3] - s[o + Math.Max(0, x - r) * 3]; }
                }
            });
        }
        static void Box3V(float[] s, float[] d, int w, int h, int r)
        {
            float k = 1f / (2 * r + 1);
            System.Threading.Tasks.Parallel.For(0, w, x =>
            {
                for (int ch = 0; ch < 3; ch++)
                {
                    float acc = 0;
                    for (int y = -r; y <= r; y++) acc += s[(Math.Max(0, Math.Min(h - 1, y)) * w + x) * 3 + ch];
                    for (int y = 0; y < h; y++) { d[(y * w + x) * 3 + ch] = acc * k; acc += s[(Math.Min(h - 1, y + r + 1) * w + x) * 3 + ch] - s[(Math.Max(0, y - r) * w + x) * 3 + ch]; }
                }
            });
        }

        // ---- the elements ------------------------------------------------------------------
        void DrawItem(int[] pic, Item it, int col, int clipX1) { DrawItem(pic, it, col, clipX1, false); }
        void DrawItem(int[] pic, Item it, int col, int clipX1, bool halo)
        {
            int pw = _lw, vr = _lvr;
            // glow first, as a tint of the screen toward the ink (or, for the readout, the dark halo); then the ink itself
            double gs = halo ? HaloK : Glow; int gc = halo ? Halo : col;
            byte[] gm = halo ? it.HaloM : it.GlowM; int gp = halo ? it.HaloPad : it.Pad;
            if (gs > 0 && gm != null)
            {
                int gw = it.W + 2 * gp, gh = it.H + 2 * gp, gx0 = it.X - gp, gy0 = it.Y - gp, gk = (int)(gs * 256);
                for (int y = 0; y < gh; y++)
                {
                    int py = gy0 + y; if (py < 0 || py >= vr) continue;
                    int o = py * pw, so = y * gw;
                    for (int x = 0; x < gw; x++)
                    {
                        int px = gx0 + x; if (px < 0 || px >= pw || px >= clipX1) continue;
                        int g = gm[so + x]; if (g == 0) continue;
                        pic[o + px] = Lerp256(pic[o + px], gc, Math.Min(256, g * gk >> 8));
                    }
                }
            }
            for (int y = 0; y < it.H; y++)
            {
                int py = it.Y + y; if (py < 0 || py >= vr) continue;
                int o = py * pw, so = y * it.W;
                for (int x = 0; x < it.W; x++)
                {
                    int px = it.X + x; if (px < 0 || px >= pw || px >= clipX1) continue;
                    int c = it.Cov[so + x]; if (c == 0) continue;
                    pic[o + px] = c >= 255 ? col : Lerp256(pic[o + px], col, c + (c >> 7));
                }
            }
        }
        void FillRect(int[] pic, int x0, int y0, int x1, int y1, int col)
        {
            int pw = _lw, vr = _lvr;
            if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (x1 > pw) x1 = pw; if (y1 > vr) y1 = vr;
            for (int y = y0; y < y1; y++) { int o = y * pw; for (int x = x0; x < x1; x++) pic[o + x] = col; }
        }
        void BlendRect(int[] pic, int x0, int y0, int x1, int y1, int col, int a256)
        {
            int pw = _lw, vr = _lvr;
            if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (x1 > pw) x1 = pw; if (y1 > vr) y1 = vr;
            for (int y = y0; y < y1; y++) { int o = y * pw; for (int x = x0; x < x1; x++) pic[o + x] = Lerp256(pic[o + x], col, a256); }
        }

        // ---- THE 7 (Josh, 2026-10-14: "build a full vector version of that image ... it will replace the 7s that appear in the
        // boot up sequence. It will be smaller than that series of 7s ... display this as an actual logo ... animate in, with the
        // pulsing effect as some portions become larger then settle ... the tight line vector weight similar to the image along
        // with its different line strikes, but make sure its truly 3d like our maps"; docs\reference\wireframe-7-style.png).
        // The numeral's outline from the reference, extruded into a solid and drawn in perspective: every edge tested against
        // the solid's own faces each frame -- solid where seen, DASHED where the solid hides it (the reference's two strikes).
        // It pulses in as the maps do (a wave across it: each edge grows from nothing past its size and settles, flaring as the
        // wave passes) over Logo7Intro seconds from the banner's start, then turns slowly side to side so it reads as solid.
        public bool Logo7On = true;
        public double Logo7Lift = 0.10;      // (the 7 sits this share of the banner's box above its middle, the logotype under it)
        public double Logo7Height = 0.70, Logo7Intro = 1.5, Logo7Wave = 0.35, Logo7Pulse = 0.35, Logo7Depth = 0.17, Logo7Yaw = -26, Logo7Pitch = -14,
            Logo7Sway = 14, Logo7SwayPeriod = 9, Logo7Line = 1.6, Logo7Dash = 0.85, Logo7Cam = 3.4;
        // the reference's front outline (its pixels; y down), and that face cut into convex pieces
        double _logoCx, _logoBottom, _logoBoxH; Item _logoType; double _logoTypeFor;
        // ---- THE LOGOTYPE under it (Josh, 2026-10-14: "MODEL 7 H.U.D." as a logotype with a small "r" circle to the right, like a
        // TM symbol; it appears between the 7 and the first readout line, the one the HUD slides in on): a technical face, widely
        // tracked, with a circled R at its cap height; wiped on from the left, the wiping edge flaring, at LogoTypeAt seconds.
        public string LogoTypeText = "MODEL 7 H.U.D.";
        public double LogoTypeAt = 2.1, LogoTypeWipe = 0.55, LogoTypeEm = 0.105, LogoTypeTrack = 0.24, LogoTypeGap = 0.06;
        Item LogoTypeItem(double emPx)
        {
            string fam = "Bahnschrift SemiBold";
            try { using (var ff = new FontFamily(fam)) { } } catch { fam = "Segoe UI Semibold"; }
            float em = (float)Math.Max(8, emPx), track = (float)(em * LogoTypeTrack);
            using (var family = new FontFamily(fam))
            using (var fmt = (StringFormat)StringFormat.GenericTypographic.Clone())
            using (var path = new GraphicsPath())
            {
                float x = 0; var cap = RectangleF.Empty;
                foreach (char ch in LogoTypeText)
                {
                    if (ch == ' ') { x += em * 0.30f + track; continue; }
                    using (var one = new GraphicsPath())
                    {
                        one.AddString(ch.ToString(), family, (int)FontStyle.Regular, em, new PointF(x, 0), fmt);
                        var b = one.GetBounds(); if (b.Width <= 0) { x += em * 0.3f + track; continue; }
                        if (char.IsLetterOrDigit(ch)) cap = cap.IsEmpty ? b : RectangleF.Union(cap, b);
                        path.AddPath(one, false);
                        x = b.Right + track;
                    }
                }
                float textR = x - track;
                // the circled R: its ring as tall as about half the capitals, its top level with theirs
                float d = cap.Height * 0.50f, rx = textR + em * (float)LogoTypeGap, ry = cap.Top;
                int pad = (int)Math.Ceiling(em * 0.15f) + 2;
                int w = (int)Math.Ceiling(rx + d) + 2 * pad, h = (int)Math.Ceiling(cap.Bottom - Math.Min(cap.Top, ry)) + 2 * pad;
                var it = new Item { W = w, H = h };
                using (var bm = new Bitmap(w, h, PixelFormat.Format32bppArgb))
                {
                    using (var g = Graphics.FromImage(bm))
                    {
                        g.Clear(Color.Black); g.SmoothingMode = SmoothingMode.AntiAlias;
                        g.TranslateTransform(pad - cap.Left, pad - cap.Top);
                        g.FillPath(Brushes.White, path);
                        using (var ring = new Pen(Color.White, Math.Max(1f, d * 0.09f))) g.DrawEllipse(ring, rx, ry, d, d);
                        using (var rp = new GraphicsPath())
                        {
                            rp.AddString("R", family, (int)FontStyle.Regular, d * 0.70f, PointF.Empty, fmt);
                            var rb = rp.GetBounds(); var m = new Matrix(); m.Translate(rx + d / 2 - (rb.Left + rb.Width / 2), ry + d / 2 - (rb.Top + rb.Height / 2)); rp.Transform(m);
                            g.FillPath(Brushes.White, rp);
                        }
                    }
                    it.Cov = Coverage(bm);
                }
                MakeGlow(it);
                return it;
            }
        }
        void DrawLogoType(int[] pic, long el, int ink)
        {
            if (!Logo7On || string.IsNullOrEmpty(LogoTypeText)) return;
            double t = (el - U_banner) / 1e6 - LogoTypeAt; if (t < 0 || _logoBoxH <= 0) return;
            double em = _logoBoxH * LogoTypeEm;
            if (_logoType == null || Math.Abs(_logoTypeFor - em) > 0.5) { _logoType = LogoTypeItem(em); _logoTypeFor = em; }
            var it = _logoType;
            it.X = (int)Math.Round(_logoCx - it.W / 2.0); it.Y = (int)Math.Round(_logoBottom + _logoBoxH * 0.05);
            double u = Math.Min(1, t / Math.Max(0.05, LogoTypeWipe)), e = Smooth(u);
            int clip = it.X + (int)Math.Round(it.W * e);
            DrawItem(pic, it, u < 1 ? Mix(ink, C_flare, 0.55 * (1 - e)) : ink, clip, true);
            // (the wiping edge: a thin bright line down the letters for as long as it runs)
            if (u < 1) FillRect(pic, clip - Math.Max(1, (int)(_s * Zoom)), it.Y, clip + 1, it.Y + it.H, C_flare);
        }
        static readonly double[] L7Out = { 98, 143, 541, 143, 541, 258, 327, 700, 327, 773, 180, 773, 180, 703, 418, 250, 98, 250 };
        static readonly int[][] L7Cap = { new[] { 0, 1, 2, 7 }, new[] { 0, 7, 8 }, new[] { 7, 2, 3, 6 }, new[] { 6, 3, 4, 5 } };
        public int Logo7Edges;
        void DrawLogo7(int[] pic, long el, int ink)
        {
            if (!Logo7On || el < U_banner) return;
            int nb = _banner.Length; if (nb == 0) return;
            double t = (el - U_banner) / 1e6;
            // where: the banner's box (its rows, from its first character to its widest line), the 7 a share of its height, centred
            double bTop = Yt(P_txtY), bH = nb * P_lineH * _s * Zoom;
            double bW = 0; for (int i = 0; i < nb && i < _lineItems.Length; i++) bW = Math.Max(bW, _lineItems[i].W);
            double cxS = Xt(TxtX) + bW / 2, cyS = bTop + bH * (0.5 - Logo7Lift), size = bH * Logo7Height;
            _logoCx = cxS; _logoBottom = cyS + size * 0.5; _logoBoxH = bH;
            int n = L7Out.Length / 2; double ox = (98 + 541) / 2.0, oy = (143 + 773) / 2.0, H = 773 - 143;
            // the solid in view space: x right, y up, z toward the eye; turned by yaw (with its slow sway) and pitch
            double yaw = (Logo7Yaw + Logo7Sway * Math.Sin(2 * Math.PI * t / Math.Max(1, Logo7SwayPeriod))) * Math.PI / 180, pit = Logo7Pitch * Math.PI / 180;
            double cyw = Math.Cos(yaw), syw = Math.Sin(yaw), cp = Math.Cos(pit), sp = Math.Sin(pit), half = Logo7Depth / 2;
            var V = new double[2 * n * 3];
            for (int k = 0; k < 2 * n; k++)
            {
                int i = k % n; double x = (L7Out[i * 2] - ox) / H, y = -(L7Out[i * 2 + 1] - oy) / H, z = k < n ? half : -half;
                double x1 = x * cyw + z * syw, z1 = -x * syw + z * cyw;          // yaw about y
                double y2 = y * cp - z1 * sp, z2 = y * sp + z1 * cp;             // pitch about x
                V[k * 3] = x1; V[k * 3 + 1] = y2; V[k * 3 + 2] = z2;
            }
            double cam = Logo7Cam;
            Func<double, double, double, PointF> Sc = (x, y, z) => { double k = cam / Math.Max(0.05, cam - z); return new PointF((float)(cxS + x * k * size), (float)(cyS - y * k * size)); };
            var S = new PointF[2 * n]; for (int k = 0; k < 2 * n; k++) S[k] = Sc(V[k * 3], V[k * 3 + 1], V[k * 3 + 2]);
            // the faces (vertex lists): the front and back pieces, and a side per outline edge
            var faces = new List<int[]>();
            foreach (var c in L7Cap) { faces.Add(c); var b = new int[c.Length]; for (int q = 0; q < c.Length; q++) b[q] = c[c.Length - 1 - q] + n; faces.Add(b); }
            for (int i = 0; i < n; i++) faces.Add(new[] { i, (i + 1) % n, (i + 1) % n + n, i + n });
            // planes (view space) for the depth along a line of sight
            var fN = new double[faces.Count * 4];
            for (int f = 0; f < faces.Count; f++)
            {
                int a = faces[f][0] * 3, b = faces[f][1] * 3, c = faces[f][2] * 3;
                double ux = V[b] - V[a], uy = V[b + 1] - V[a + 1], uz = V[b + 2] - V[a + 2], wx = V[c] - V[a], wy = V[c + 1] - V[a + 1], wz = V[c + 2] - V[a + 2];
                double nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
                fN[f * 4] = nx; fN[f * 4 + 1] = ny; fN[f * 4 + 2] = nz; fN[f * 4 + 3] = nx * V[a] + ny * V[a + 1] + nz * V[a + 2];
            }
            Func<int, float, float, bool> Inside = (f, px, py) =>
            {
                var fv = faces[f]; int m = fv.Length; float sgn = 0;
                for (int q = 0; q < m; q++)
                {
                    PointF p0 = S[fv[q]], p1 = S[fv[(q + 1) % m]];
                    float cr = (p1.X - p0.X) * (py - p0.Y) - (p1.Y - p0.Y) * (px - p0.X);
                    if (Math.Abs(cr) < 1e-4f) continue;
                    if (sgn == 0) sgn = Math.Sign(cr); else if (Math.Sign(cr) != sgn) return false;
                }
                return true;
            };
            // the edges: front outline, back outline, the joins
            var edges = new List<int[]>();
            for (int i = 0; i < n; i++) { edges.Add(new[] { i, (i + 1) % n }); edges.Add(new[] { i + n, (i + 1) % n + n }); edges.Add(new[] { i, i + n }); }
            Logo7Edges = edges.Count;
            // the pulse: a wave across the logo, left to right on the screen
            float minX = float.MaxValue, maxX = float.MinValue; foreach (var p in S) { minX = Math.Min(minX, p.X); maxX = Math.Max(maxX, p.X); }
            double wp = t / Math.Max(0.1, Logo7Intro); bool waveOn = wp < 1;
            const int NS = 48;
            var hm = GCHandle.Alloc(pic, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(_lw, _lvr, _lw * 4, PixelFormat.Format32bppPArgb, hm.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                using (var solid = new Pen(Color.Black, (float)Math.Max(1.0, Logo7Line * _s * Zoom)))
                using (var dash = new Pen(Color.Black, (float)Math.Max(0.8, Logo7Line * Logo7Dash * _s * Zoom)))
                using (var halo = new Pen(Color.Black, (float)Math.Max(2.0, Logo7Line * 4 * _s * Zoom)))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    solid.StartCap = LineCap.Round; solid.EndCap = LineCap.Round;
                    dash.DashPattern = new float[] { 3.2f, 2.6f };
                    halo.StartCap = LineCap.Round; halo.EndCap = LineCap.Round;
                    var vis = new bool[NS + 1];
                    foreach (var e in edges)
                    {
                        int a = e[0], b = e[1];
                        PointF A = S[a], B = S[b];
                        // the wave at this edge's middle
                        float mx = (A.X + B.X) / 2, my = (A.Y + B.Y) / 2;
                        double sc = 1, glow = 0;
                        if (waveOn)
                        {
                            double u = (mx - minX) / Math.Max(1, maxX - minX), ph = Math.Max(0, Math.Min(1, (wp * (1 + Logo7Wave) - u) / Logo7Wave));
                            double grow = Smooth(ph / 0.55) * (1 + Logo7Pulse); sc = grow + (1 - grow) * Smooth((ph - 0.55) / 0.45);
                            glow = Smooth(ph / 0.25) * (1 - Smooth((ph - 0.45) / 0.55));
                            if (sc < 0.002) continue;
                        }
                        // seen or hidden, sample by sample along it: hidden where a face of the solid lies between it and the eye
                        for (int q = 0; q <= NS; q++)
                        {
                            double f = (q + 0.5) / (NS + 1);
                            double Px = V[a * 3] + (V[b * 3] - V[a * 3]) * f, Py = V[a * 3 + 1] + (V[b * 3 + 1] - V[a * 3 + 1]) * f, Pz = V[a * 3 + 2] + (V[b * 3 + 2] - V[a * 3 + 2]) * f;
                            PointF sp2 = Sc(Px, Py, Pz); bool hid = false;
                            for (int fi = 0; fi < faces.Count && !hid; fi++)
                            {
                                double nx = fN[fi * 4], ny = fN[fi * 4 + 1], nz = fN[fi * 4 + 2], c0 = fN[fi * 4 + 3];
                                double dx = Px, dy = Py, dz = Pz - cam, den = nx * dx + ny * dy + nz * dz; if (Math.Abs(den) < 1e-9) continue;
                                double tt = (c0 - nz * cam) / den;                  // the ray from the eye (0, 0, cam) through the point: t = 1 at it
                                if (tt <= 0.0005 || tt >= 0.995) continue;
                                if (Inside(fi, sp2.X, sp2.Y)) hid = true;
                            }
                            vis[q] = !hid;
                        }
                        // its runs, drawn scaled about the edge's middle by the wave
                        Func<double, PointF> At = f2 => { float x = A.X + (B.X - A.X) * (float)f2, y = A.Y + (B.Y - A.Y) * (float)f2; return new PointF(mx + (x - mx) * (float)sc, my + (y - my) * (float)sc); };
                        int col = Mix(ink, C_flare, Math.Min(1, glow * 1.4));
                        int r0 = 0;
                        for (int q = 1; q <= NS + 1; q++)
                        {
                            if (q <= NS && vis[q] == vis[r0]) continue;
                            double f0 = r0 / (double)(NS + 1), f1 = q / (double)(NS + 1);
                            PointF p0 = At(f0), p1 = At(f1);
                            if (vis[r0])
                            {
                                if (glow > 0.02) { halo.Color = Argb((int)(70 * glow), C_flare); g.DrawLine(halo, p0, p1); }
                                solid.Color = Argb(255, col); g.DrawLine(solid, p0, p1);
                            }
                            else { dash.Color = Argb(205, col); g.DrawLine(dash, p0, p1); }
                            r0 = q;
                        }
                    }
                }
            }
            finally { hm.Free(); }
        }

        // The banner draws in a line at a time, then the readout under it; the newest line
        // flares for a moment. Returns how many lines are up.
        int DrawReadout(int[] pic, long el, int ink, int teal)
        {
            if (el < U_banner) return 0;
            int nb = _banner.Length, nAll = _lineItems.Length; long age;
            int n;
            if (el < U_text) { long k = (el - U_banner) / U_banStep; n = (int)k + 1; age = (el - U_banner) % U_banStep; if (n >= nb) { n = nb; age = long.MaxValue; } }
            else { long k = (el - U_text) / U_line; n = nb + (int)k + 1; age = (el - U_text) % U_line; if (n >= nAll) { n = nAll; age = long.MaxValue; } }
            if (Logo7On) { DrawLogo7(pic, el, ink); DrawLogoType(pic, el, ink); }      // (THE 7 and its logotype: in place of the banner's rows of 7s)
            for (int i = 0; i < n; i++)
            {
                if (Logo7On && i < nb) continue;
                bool hot = i == n - 1 && age < U_flare, seven = i < nb;      // the 7s keep the 8-bit boot's teal
                DrawItem(pic, _lineItems[i], seven ? (hot ? C_tealFlare : teal) : (hot ? C_flare : ink), int.MaxValue, true);
            }
            return n;
        }
        // Fills as the check runs, full exactly as the closing line finishes typing. No frame (Josh,
        // 2026-10-07): just the bright fill running along its track.
        void DrawBar(int[] pic, long el, int ink)
        {
            if (el < U_text) return;
            double f = Math.Min(1.0, (el - U_text) / (double)U_barSpan);
            int x0 = (int)Math.Round(Xt(P_barX + ReadoutShift)), y0 = (int)Math.Round(Yt(P_barY)), w = Pt(P_barW), h = Pt(P_barH);
            int fx = x0 + (int)Math.Round(w * f);
            FillRect(pic, x0, y0, fx, y0 + h, ink);
            FillRect(pic, fx, y0, x0 + w, y0 + h, C_track);
        }
        // Hex words down the left of the screen: the machine visibly working.
        void DrawDump(int[] pic, long el)
        {
            if (el < U_dump || _cells == null) return;
            int x0 = (int)Math.Round(P_dumpX * _s), y0 = (int)Math.Round(Yt(P_dumpY)), cw = Pt(P_hexCell), lh = Pt(P_lineH);
            for (int r = 0; r < DumpRows; r++)
                for (int c = 0; c < DumpCols; c++)
                {
                    var h = _hex[_cells[r * DumpCols + c] & 15];
                    h.X = x0 + c * cw; h.Y = y0 + r * lh;
                    DrawItem(pic, h, C_dump, int.MaxValue);
                }
        }
        // Text that types itself in left to right, with a blinking block caret at the edge
        // until it is whole. All of `items` are revealed by the same edge.
        void DrawTyped(int[] pic, Item[] items, int x0, int w, long t, long span, int ink, Item caretOn, long el)
        {
            double f = Math.Max(0, Math.Min(1, t / (double)span));
            int edge = x0 + (int)Math.Round(w * f);
            foreach (var it in items) DrawItem(pic, it, ink, edge, true);
            if (f < 1 && ((el >> CaretShr) & 1) == 0)
            {
                int cw = Math.Max(2, (int)Math.Round(caretOn.Adv * 0.9));
                FillRect(pic, edge, caretOn.Y + Px(1), edge + cw, caretOn.Y + caretOn.H - Px(1), C_caret);
            }
        }
        // The refresh line: a bright beat travelling down the screen behind everything. ONE picture
        // pixel (Josh, 2026-10-07) -- the 8-bit boot's two rows were only ever its resolution.
        void DrawSweep(int[] pic, long el)
        {
            int vr = _lvr, pw = _lw;
            double ph = (el % U_sweep) / (double)U_sweep;
            int y = (int)(ph * vr); if (y < 0 || y >= vr) return;
            int o = y * pw;
            for (int x = 0; x < pw; x++) pic[o + x] = C_sweep;
        }
        // Static, edge dropout, flickering blocks and the pulsing bands top and bottom,
        // thinning stage by stage as the visor settles.
        void DrawDisruption(int[] pic, long el, long tick, int scanCol)
        {
            int[] st = Dis[(int)Math.Min(Dis.Length - 1, el / U_disStage)];
            int pw = _lw, vr = _lvr;
            var r = new Rng(tick, 3);
            int band = (int)Math.Round(st[3] * (5 + ((el >> 17) & 3)) / 8.0 * _s);
            if (band > 0) { FillRect(pic, 0, 0, pw, band, C_art); FillRect(pic, 0, vr - band, pw, vr, C_art); }
            int row = Px(1);
            for (int i = 0; i < st[0]; i++)
            {
                int y = (int)Yp(r.Below(InjH)), len = Px(8 + r.Below(128)), x = r.Below(pw);
                if (x + len > pw) continue;
                FillRect(pic, x, y, x + len, y + row, C_art);
            }
            int em = Px(P_edgeMargin), bm = Px(P_blkMargin);
            for (int i = 0; i < st[1]; i++)
            {
                int y = (int)Yp(r.Below(InjH)), len = Px(4 + r.Below(32)), x = r.Below(Math.Max(1, em - len));
                if ((r.Next() & 1) != 0) x = pw - em + x;
                FillRect(pic, x, y, x + len, y + row, (r.Next() & 1) != 0 ? C_art : scanCol);
            }
            for (int i = 0; i < st[2]; i++)
            {
                int bw = Px(4 + r.Below(16)), bh = Px(2 + r.Below(8)), y = (int)Yp(r.Below(InjH - 9)), x = r.Below(Math.Max(1, bm - bw));
                if ((r.Next() & 1) != 0) x = pw - bm + x;
                FillRect(pic, x, y, x + bw, y + bh, (r.Next() & 1) != 0 ? C_art : scanCol);
            }
        }
        // Whole character cells replaced by another cell of the same line, for one frame.
        void DrawGlyphs(int[] pic, long tick, int shown)
        {
            if (shown <= 0) return;
            var r = new Rng(tick, 5);
            if ((r.Next() & (uint)GlyphOdds) != 0) return;
            int pw = _lw;
            for (int k = 0; k < GlyphCells; k++)
            {
                var it = _lineItems[r.Below(shown)];
                int chars = Math.Max(1, it.Chars), cw = (int)Math.Round(it.Adv);
                int a = r.Below(chars), b = r.Below(chars); if (a == b || cw < 1) continue;
                int sx = it.X + (int)Math.Round(a * it.Adv), dx = it.X + (int)Math.Round(b * it.Adv);
                if (sx < 0 || dx < 0 || sx + cw > pw || dx + cw > pw) continue;
                for (int y = Math.Max(0, it.Y); y < Math.Min(_lvr, it.Y + it.H); y++) Array.Copy(pic, y * pw + sx, pic, y * pw + dx, cw);
            }
        }
        // A band of rows displaced sideways, wrapping, for one frame.
        void DrawTear(int[] pic, long el, long tick)
        {
            int[] st = Dis[(int)Math.Min(Dis.Length - 1, el / U_disStage)];
            if (st[4] <= 0) return;
            var r = new Rng(tick, 9);
            if (r.Below(256) >= st[4]) return;
            int rows = Px(TearRows[0] + r.Below(TearRows[1])), y0 = (int)Yp(r.Below(InjH - (TearRows[0] + TearRows[1])));
            int sh = Px(TearShift[0] + r.Below(TearShift[1])); if ((r.Next() & 1) != 0) sh = -sh;
            RotateRows(pic, _lw, y0, y0 + rows, 0, _lw, sh);
        }
        // The split tear: everything below a row steps right, then below a second row again.
        void DrawSplit(int[] pic, long tick)
        {
            var r = new Rng(tick, 13);
            if ((r.Next() & (uint)Split[0]) != 0) return;
            double foot = P_finalY + P_finalH, a = P_txtY + r.Below(64);
            for (int k = 0; k < 3; k++)
            {
                if (k > 0) a += Split[3] + r.Below(Split[4]);
                if (a >= foot) break;
                RotateRows(pic, _lw, (int)Yt(a), (int)Yt(foot), 0, _lw, Px(Split[1] + r.Below(Split[2])));
            }
        }
        int[] _rowTmp;
        void RotateRows(int[] pic, int pw, int y0, int y1, int x0, int w, int shift)
        {
            if (x0 < 0) { w += x0; x0 = 0; } if (x0 + w > pw) w = pw - x0; if (w <= 1) return;
            shift %= w; if (shift < 0) shift += w; if (shift == 0) return;
            if (_rowTmp == null || _rowTmp.Length < w) _rowTmp = new int[w];
            for (int y = Math.Max(0, y0); y < Math.Min(_lvr, y1); y++)
            {
                int o = y * pw + x0;
                Array.Copy(pic, o, _rowTmp, 0, w);
                Array.Copy(_rowTmp, 0, pic, o + shift, w - shift);
                Array.Copy(_rowTmp, w - shift, pic, o, shift);
            }
        }
        int[] _rollTmp;
        // The vertical hold slipping: the whole screen rolls, wrapping.
        void Roll(int[] pic, int pw, int vr, int rows)
        {
            rows %= vr; if (rows < 0) rows += vr; if (rows == 0) return;
            if (_rollTmp == null || _rollTmp.Length < pw * vr) _rollTmp = new int[pw * vr];
            Buffer.BlockCopy(pic, 0, _rollTmp, 0, pw * vr * 4);
            Buffer.BlockCopy(_rollTmp, rows * pw * 4, pic, 0, (vr - rows) * pw * 4);
            Buffer.BlockCopy(_rollTmp, 0, pic, (vr - rows) * pw * 4, rows * pw * 4);
        }

        // =====================================================================================
        // THE REVEAL, over the host's own 3D (Overlay.Decorate): the two panels of the held
        // screen retract from the middle with a bright lip and a phosphor ghost trailing each,
        // then the calibration box closes on the aim point with its crosshair growing to meet it.
        // =====================================================================================
        int[] _held; int _heldW, _heldH, _heldVr;
        void EnsureHeld(int pw, int ph, int vr)
        {
            if (_held != null && _heldW == pw && _heldH == ph && _heldVr == vr) return;
            var h = new int[pw * ph];
            // (without the chalice: the live one is laid over the shutter and the game, turning, fading with the amber)
            _noCup = true; try { RenderAt(h, pw, ph, vr, U_open - 1, 0, _reboot, false); } finally { _noCup = false; }
            _held = h; _heldW = pw; _heldH = ph; _heldVr = vr;
        }
        /// <summary>Overlay.Decorate: lay the shutter / calibration over a finished picture.</summary>
        public bool DecorateFrame(int[] pic, int pw, int ph)
        {
            int vr = _ov != null ? _ov.ViewRowsOf(ph) : ph;
            bool drew = false; double tOver = -1;
            if (_mode == M_REVEAL)
            {
                double t = _revealClock.Elapsed.TotalMilliseconds * 1000.0; tOver = t;
                if (t >= RevealUs) { _mode = M_DONE; Note("visor boot: shutter, calibration and colour done -- the view is the game's"); }
                else
                {
                    drew = DecorateAt(pic, pw, ph, vr, t);
                    if (!_reboot) RevealDegauss(pic, pw, vr, t);
                    // WEAPON SYSTEMS ONLINE types out to its own pattern, a little higher
                    if (!_sndWeapons && t >= WeaponFromUs && t < WeaponFromUs + 300000 && Sound != null) { _sndWeapons = true; Sound.Typing(500, WeaponType, 1.12); }
                }
            }
            // the visor's shading, over EVERY picture -- the boot's and the 3D's -- last, as it is on the glass
            var sh = Shade; if (sh != null) { try { sh.Draw(pic, pw, vr, _mode != M_DONE); drew = true; } catch { } }
            // the glass's highlight and the viewfinder are on top of even that
            if (tOver >= 0 && tOver < RevealUs) { try { DecorateOver(pic, pw, ph, vr, tOver); drew = true; } catch { } }
            else if ((_mode == M_LIVE || _mode == M_HOLD) && !Covering4Load) { try { Glare(pic, pw, vr, 1); drew = true; } catch { } }
            return drew;
        }
        /// <summary>The reveal at `t` microseconds after it started (also the offline test's way in).</summary>
        public bool DecorateAt(int[] pic, int pw, int ph, int vr, double t)
        {
            lock (_drawLock)
            {
                try { EnsureHeld(pw, ph, vr); } catch { return false; }
                EnsureLayout(pw, ph, vr);              // (a no-op: the held frame was just drawn at these sizes)
                double cy = vr / 2.0;
                ColourUp(pic, pw, ph, vr, t);
                if (t < U_openSpan)
                {
                    double h = Math.Max(1, t / U_openSpan * cy);
                    int top = (int)Math.Round(cy - h), bot = (int)Math.Round(cy + h);
                    if (top > 0) Buffer.BlockCopy(_held, 0, pic, 0, top * pw * 4);
                    if (bot < vr) Buffer.BlockCopy(_held, bot * pw * 4, pic, bot * pw * 4, (vr - bot) * pw * 4);
                    // the ghost: dim fill trailing each panel, fading into the world, gone as the shutter completes
                    int g = (int)Math.Round(Math.Min(P_ghostRows * _s, Math.Min(h, cy - h)));
                    for (int k = 0; k < g; k++)
                    {
                        int a = (int)(200.0 * (1 - (k + 0.5) / g));
                        BlendRect(pic, 0, top + k, pw, top + k + 1, C_ghost, a);
                        BlendRect(pic, 0, bot - 1 - k, pw, bot - k, C_ghost, a);
                    }
                    // the lips, on the panels' inner edges
                    int lip = Px(2);
                    if (top >= lip) FillRect(pic, 0, top - lip, pw, top, C_lip);
                    if (bot + lip <= vr) FillRect(pic, 0, bot, pw, bot + lip, C_lip);
                }
                if (t >= LockFromUs && t < LockUs + LockFlashUs) DrawLock(pic, pw, ph, vr, t);
                if (t >= WeaponFromUs && t < WeaponFromUs + (WeaponType + WeaponHold + WeaponFade) * 1e6) DrawWeapons(pic, pw, ph, vr, t - WeaponFromUs);
            }
            return true;
        }

        // ---- THE RETICLE INITIATION (Josh, 2026-10-07: "a vector looking shape would animate before the reticule
        // system appeared"). The 8-bit calibration box, as vector graphics: a diamond spinning down into a square
        // that closes on the aim point, crosshair arms growing to meet it, a flash as it locks -- and only then
        // the game's own reticle (hidden until the lock: see HideReticle), with WEAPON SYSTEMS ONLINE under it.
        public double CalibSeconds = 0.8;
        public int VectorCore = 0xFFE7A6, VectorHalo = 0xFF8E1E;
        public string WeaponText = "WEAPON SYSTEMS ONLINE.";
        // after a LOAD (the re-boot) the line says the whole visor is back (Josh, 2026-10-09); a new game keeps WeaponText
        public string ReloadText = "ALL SYSTEMS OPERATIONAL.";
        public double WeaponType = 0.6, WeaponHold = 1.7, WeaponFade = 0.6, WeaponPx = 17, WeaponBelow = 70;
        const double LockFlashUs = 350000;
        double LockUs { get { return LockFromUs + CalibSeconds * 1e6; } }
        /// <summary>Where the reticle's initiation starts: as the shutter opens -- or, on a new game, once the raptor has got
        /// up (StandUs), so the lock, the colour, WEAPON SYSTEMS ONLINE and the viewfinder all follow the stand-up.</summary>
        double LockFromUs { get { return U_openSpan + StandUs; } }

        // ---- THE RAPTOR GETS UP (Josh, 2026-10-13: "animate the player character standing up when the game first loads a new
        // game (after the bootup visor animation). I dont want the camera to move from low to current position, I want an
        // effect where it tilts a bit as he stands, like getting up from the ground. Dirt and dust would fall from the top of
        // his visor as he finally stands, and the 'weapon systems online' animation would then display, as he's finally
        // ready"). A new game's reveal only (not a load's re-boot): the shutter opens on the room seen from the ground --
        // the view rolled StandRollDeg and pitched StandPitchDeg down -- held while it opens; then over StandSeconds he
        // pushes up (the head lolls the other way), rises, and finds his feet with a small overshoot. The HEIGHT never
        // changes: only the view's turn (TiltCamera, which the watcher applies to the camera it renders from -- the
        // view, the helmet lamp and its shadows turn together; the game's own camera is untouched). As he finally stands,
        // dirt and dust slide off the top of the visor (DrawDust); then the reticle locks and WEAPON SYSTEMS ONLINE types.
        public bool StandUp = true;
        public double StandSeconds = 2.8, StandRollDeg = 15, StandPitchDeg = 24, DustFrom = 0.74, DustSeconds = 2.3;
        public int DustCount = 300;
        double StandUs { get { return StandUp && !_reboot && !Covering4Load ? StandSeconds * 1e6 : 0; } }
        static double Clamp01(double x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
        static double Smoother(double x) { x = Clamp01(x); return x * x * x * (x * (x * 6 - 15) + 10); }
        /// <summary>The view's roll and pitch (degrees; pitch below 0 = looking down) `t` microseconds into the reveal.</summary>
        public void TiltAt(double t, out double roll, out double pitch)
        {
            roll = 0; pitch = 0;
            if (StandUs <= 0) return;
            double u = (t - U_openSpan) / StandUs;                 // (below 0 while the shutter opens: still on the ground)
            if (u >= 1) return;
            u = Math.Max(0, u);
            double down = 1 - Smoother((u - 0.06) / 0.80);          // 1 on the ground .. 0 standing
            double lurch = Math.Sin(Math.PI * Clamp01(u / 0.45)) * (1 - u);          // the push up onto one arm
            double sway = Math.Sin(u * Math.PI * 5.0) * (1 - u) * (1 - u);           // unsteady as he rises
            double settle = Math.Sin(Math.PI * Clamp01((u - 0.72) / 0.28));          // finding his feet: a nod past level and back
            roll = -StandRollDeg * down + StandRollDeg * 0.55 * lurch + StandRollDeg * 0.10 * sway;
            pitch = -StandPitchDeg * down + StandPitchDeg * 0.10 * settle + StandPitchDeg * 0.05 * sway;
        }
        /// <summary>The stand-up's tilt applied to a camera world matrix (rows right, up, forward, position) in place:
        /// pitched about its right axis, then rolled about its forward one; the position is left alone. False = no tilt
        /// now (not a new game's reveal, or he is up).</summary>
        public bool TiltCamera(float[] m)
        {
            if (m == null || m.Length < 16 || _mode != M_REVEAL || StandUs <= 0) return false;
            double roll, pitch; TiltAt(_revealClock.Elapsed.TotalMilliseconds * 1000.0, out roll, out pitch);
            if (roll == 0 && pitch == 0) return false;
            TiltMatrix(m, roll, pitch);
            return true;
        }
        /// <summary>A camera world matrix (rows right, up, forward, position) turned in place: pitched about its right axis
        /// (degrees; below 0 = down), then rolled about its forward one. (Also the offline test's way in.)</summary>
        public static void TiltMatrix(float[] m, double roll, double pitch)
        {
            double p = pitch * Math.PI / 180, q = roll * Math.PI / 180, cp = Math.Cos(p), sp = Math.Sin(p), cq = Math.Cos(q), sq = Math.Sin(q);
            var rgt = new double[3]; var upv = new double[3]; var fwd = new double[3];
            for (int k = 0; k < 3; k++)
            {
                double r0 = m[k], u0 = m[4 + k], f0 = m[8 + k];
                double f1 = f0 * cp + u0 * sp, u1 = u0 * cp - f0 * sp;                // pitch: forward toward up (below 0: down)
                rgt[k] = r0 * cq + u1 * sq; upv[k] = u1 * cq - r0 * sq; fwd[k] = f1;  // roll about the new forward
            }
            for (int k = 0; k < 3; k++) { m[k] = (float)rgt[k]; m[4 + k] = (float)upv[k]; m[8 + k] = (float)fwd[k]; }
        }
        /// <summary>DIRT AND DUST off the top of the visor as he finally stands: a haze sliding down from the top edge, and
        /// grit -- fine specks and a few clumps, dark earth to pale dust -- falling down the glass under gravity, smeared a
        /// little by their speed, thinning as they go. Fixed by a seed: the same fall every time.</summary>
        void DrawDust(int[] pic, int pw, int ph, int vr, double t)
        {
            if (StandUs <= 0) return;
            double s = (t - (U_openSpan + StandUs * DustFrom)) / 1e6;
            if (s < 0 || s > DustSeconds) return;
            float sc = (float)Math.Max(1, _s);
            Paint(pic, pw, ph, g =>
            {
                g.SetClip(new Rectangle(0, 0, pw, vr));
                // the haze: a dusty band at the top, sliding down and thinning
                double hz = Clamp01(s / 0.18) * Clamp01(1 - s / (DustSeconds * 0.75));
                if (hz > 0.01)
                {
                    float hh = (float)(vr * (0.10 + 0.16 * Clamp01(s / 1.2)));
                    using (var lg = new LinearGradientBrush(new RectangleF(0, -1, pw, hh + 2), Argb((int)(150 * hz), 0x7A6850), Argb(0, 0x7A6850), 90f))
                        g.FillRectangle(lg, 0, 0, pw, hh);
                }
                var rnd = new Random(20261013);
                for (int k = 0; k < DustCount; k++)
                {
                    double x = rnd.NextDouble() * pw, delay = 0.55 * Math.Pow(rnd.NextDouble(), 1.6);
                    double big = Math.Pow(rnd.NextDouble(), 3);                                         // most fine, some clumps
                    double size = (0.9 + 4.6 * big) * sc, acc = vr * (0.9 + 1.5 * rnd.NextDouble() + 0.8 * big), v0 = vr * 0.05 * rnd.NextDouble();
                    double drift = (rnd.NextDouble() - 0.5) * 0.03 * pw, tone = rnd.NextDouble(), life = 0.9 + 0.9 * rnd.NextDouble();
                    double ts = s - delay; if (ts <= 0 || ts > life + 0.6) continue;
                    double y = -size + v0 * ts + 0.5 * acc * ts * ts, xx = x + drift * ts;
                    if (y > vr + 8) continue;
                    double a = Clamp01(ts / 0.06) * Clamp01((life + 0.6 - ts) / 0.6) * (0.55 + 0.45 * big);
                    int col = tone < 0.45 ? 0x6A5640 : tone < 0.8 ? 0x8C785C : 0xB9A98C;              // earth, dirt, pale dust (lit by the lamp on the glass)
                    float vy = (float)(v0 + acc * ts), streak = (float)Math.Min(size * 2.5, vy * 0.006);  // smeared a little by its fall
                    using (var b = new SolidBrush(Argb((int)(235 * a), col)))
                        g.FillEllipse(b, (float)(xx - size / 2), (float)(y - size / 2 - streak), (float)size, (float)size + streak);
                }
            });
        }
        double WeaponFromUs { get { return LockUs + 150000; } }
        /// <summary>True while the game's own reticle should be kept out of the picture (before the lock).</summary>
        public bool HideReticle { get { return _mode == M_REVEAL && _revealClock.Elapsed.TotalMilliseconds * 1000 < LockUs; } }

        // GDI+ straight onto the picture: antialiased lines and type, a handful of strokes a frame
        static void Paint(int[] pic, int pw, int ph, Action<Graphics> paint)
        {
            var h = GCHandle.Alloc(pic, GCHandleType.Pinned);
            try { using (var bm = new Bitmap(pw, ph, pw * 4, PixelFormat.Format32bppRgb, h.AddrOfPinnedObject())) using (var g = Graphics.FromImage(bm)) { g.SmoothingMode = SmoothingMode.AntiAlias; paint(g); } }
            finally { h.Free(); }
        }
        static Color Argb(int a, int rgb) { return Color.FromArgb(Math.Max(0, Math.Min(255, a)), (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
        static double EaseOut(double x) { x = Math.Max(0, Math.Min(1, x)); return 1 - Math.Pow(1 - x, 3); }
        void DrawLock(int[] pic, int pw, int ph, int vr, double t)
        {
            double p = EaseOut((t - LockFromUs) / (CalibSeconds * 1e6));
            double flash = t > LockUs ? (t - LockUs) / LockFlashUs : 0;      // 0..1 after the lock: flash, then fade
            float cx = (float)_cx, cy = (float)(vr / 2.0);
            float rad = (float)((CalibR[0] - (CalibR[0] - CalibR[1]) * p) * _s), arm = (float)Math.Min(rad, CalibR[0] * _s * p);
            float ang = (float)(45 * (1 - p) * (1 - p));
            double alpha = flash <= 0 ? 0.35 + 0.65 * p : Math.Max(0, 1 - flash);
            float pulse = flash > 0 ? (float)(1 + 0.18 * Math.Sin(Math.Min(1, flash * 2) * Math.PI)) : 1f;
            float sc = (float)Math.Max(1, _s);
            Paint(pic, pw, ph, g =>
            {
                g.TranslateTransform(cx, cy); g.RotateTransform(ang); g.ScaleTransform(pulse, pulse);
                for (int pass = 0; pass < 2; pass++)
                {
                    int col = pass == 0 ? VectorHalo : VectorCore;
                    float w = pass == 0 ? 6 * sc : 1.6f * sc;
                    int a = (int)(255 * alpha * (pass == 0 ? 0.30 : 1.0) * (flash > 0 && flash < 0.3 ? 1.6 : 1));
                    using (var pen = new Pen(Argb(a, col), w))
                    {
                        // the closing square, its sides shortening into corner brackets as it closes
                        float b = rad * (float)(0.25 + 0.75 * (1 - p));
                        g.DrawLine(pen, -rad, -rad, -rad + b, -rad); g.DrawLine(pen, -rad, -rad, -rad, -rad + b);
                        g.DrawLine(pen, rad, -rad, rad - b, -rad); g.DrawLine(pen, rad, -rad, rad, -rad + b);
                        g.DrawLine(pen, -rad, rad, -rad + b, rad); g.DrawLine(pen, -rad, rad, -rad, rad - b);
                        g.DrawLine(pen, rad, rad, rad - b, rad); g.DrawLine(pen, rad, rad, rad, rad - b);
                        // the crosshair, growing in from the box toward the middle
                        float gap = rad * 0.18f;
                        if (arm > gap)
                        {
                            g.DrawLine(pen, -rad, 0, -rad + (arm - gap), 0); g.DrawLine(pen, rad, 0, rad - (arm - gap), 0);
                            g.DrawLine(pen, 0, -rad, 0, -rad + (arm - gap)); g.DrawLine(pen, 0, rad, 0, rad - (arm - gap));
                        }
                        // tick marks riding the box's middles
                        float tk = 5 * sc;
                        g.DrawLine(pen, -rad - tk, 0, -rad, 0); g.DrawLine(pen, rad, 0, rad + tk, 0); g.DrawLine(pen, 0, -rad - tk, 0, -rad); g.DrawLine(pen, 0, rad, 0, rad + tk);
                    }
                }
                // the lock itself: a ring that blooms out and fades
                if (flash > 0)
                    using (var ring = new Pen(Argb((int)(220 * (1 - flash)), VectorCore), 2 * sc))
                    { float rr = rad * (float)(1 + 0.9 * flash); g.DrawEllipse(ring, -rr, -rr, 2 * rr, 2 * rr); }
            });
        }
        void DrawWeapons(int[] pic, int pw, int ph, int vr, double tu)
        {
            string wt = _reboot ? ReloadText : WeaponText;
            double ts = tu / 1e6, n = wt.Length;
            int shown = (int)Math.Min(n, Math.Floor(n * ts / WeaponType) + 1);
            double alpha = ts < WeaponType + WeaponHold ? 1 : Math.Max(0, 1 - (ts - WeaponType - WeaponHold) / WeaponFade);
            if (ts < 0.12) alpha *= (((int)(ts * 50)) & 1) == 0 ? 1 : 0.35;             // it flickers on
            string s = wt.Substring(0, shown);
            bool caret = shown < n || (((int)(ts * 4) & 1) == 0 && ts < WeaponType + WeaponHold);
            float cx = (float)_cx, y = (float)(vr / 2.0 + WeaponBelow * _s), sf = (float)_s;
            Paint(pic, pw, ph, g =>
            {
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                using (var font = new Font("Consolas", (float)(WeaponPx * _s), FontStyle.Bold, GraphicsUnit.Pixel))
                using (var fmt = Fmt())
                {
                    var full = g.MeasureString(wt, font, PointF.Empty, fmt);
                    float x = cx - full.Width / 2;
                    // a dark backing for the world behind, then a glow, then the type
                    using (var back = new SolidBrush(Argb((int)(120 * alpha), 0x0A0602))) g.FillRectangle(back, x - 10 * sf, y - 4 * sf, full.Width + 20 * sf, full.Height + 8 * sf);
                    using (var halo = new SolidBrush(Argb((int)(90 * alpha), VectorHalo)))
                    {
                        g.DrawString(s, font, halo, x - 1.5f * sf, y, fmt); g.DrawString(s, font, halo, x + 1.5f * sf, y, fmt);
                        g.DrawString(s, font, halo, x, y - 1.5f * sf, fmt); g.DrawString(s, font, halo, x, y + 1.5f * sf, fmt);
                    }
                    using (var core = new SolidBrush(Argb((int)(255 * alpha), VectorCore))) g.DrawString(s, font, core, x, y, fmt);
                    if (caret)
                    {
                        var part = g.MeasureString(s, font, PointF.Empty, fmt);
                        using (var cb = new SolidBrush(Argb((int)(230 * alpha), VectorCore))) g.FillRectangle(cb, x + part.Width + 2, y + 2, font.Size * 0.55f, full.Height - 4);
                    }
                }
            });
        }

        // ---- THE VIEWFINDER (Josh, 2026-10-07: "digital framing like a camera viewfinder" round the outer part of the
        // view as the world fades in from the amber; then "slide in from the top/bottom/left/right to join into their
        // final shape", with the top ones hugging the top; then "animate away as well ... in reverse" and "a slight
        // curve to go along with the curve of the CRT"). Every piece flies in from its own edge of the screen with a
        // speed trail and snaps into place with a slight overshoot: each bracket's horizontal arm from the side, its
        // vertical arm from the top or bottom, and where the two meet the corner flashes. The tick rulers fly in to the
        // middle of each edge and draw outward, a marker on each hunts and settles like a focus. Once the colour is up
        // it all goes the way it came, in reverse: the rulers draw back in and leave first, then the vertical arms (the
        // corners flash as they part), then the horizontal ones -- each pulling in a touch before it flies off. Every
        // line is bent by the tube's own curvature (CurveX/CurveY, the map the boot's glass uses), so the frame bows
        // with the screen. Drawn AFTER the visor's shading (DecorateOver), so the top brackets can sit right at the top.
        public bool Viewfinder = true;
        /// <summary>Seconds: each piece's flight (in, and out again), and how long the frame stays once the colour is up.</summary>
        public double FrameIn = 0.5, FrameHold = 0.3;
        /// <summary>Insets as shares of the view: sides, top and bottom.</summary>
        public double FrameSide = 0.045, FrameTop = 0.035, FrameBottom = 0.06;
        /// <summary>How much of the tube's curvature the frame's lines follow: 1 = the glass's own, 0 = straight.</summary>
        public double FrameCurve = 1.0;
        const double FrameVLag = 0.09, FrameRulerLag = 0.3;                  // in: when the vertical arms and the rulers set off (s)
        const double FrameOutR = 0.15, FrameOutV = 0.3, FrameOutH = 0.39;    // out: the reverse order
        double FrameFromUs { get { return U_openSpan * 0.55; } }
        double FrameOutUs { get { return ColourFromUs + (ColourSeconds + FrameHold) * 1e6; } }
        double FrameEndUs { get { return FrameOutUs + (FrameOutH + FrameIn) * 1e6; } }
        static double EaseBack(double x) { x = Math.Max(0, Math.Min(1, x)); double c1 = 1.8, c3 = c1 + 1, u = x - 1; return 1 + c3 * u * u * u + c1 * u * u; }
        /// <summary>A piece's place at `ts`: 1 = home, 0 = off the screen, -1 = not there (before it comes, after it goes).
        /// In with an overshoot; out the reverse way: a small, quick pull in, then away. (The in-curve simply run backwards
        /// hung the piece just inside home for 64% of its flight before it left -- a wind-up, not a reversal.)</summary>
        double PieceAt(double ts, double inAt, double outAt, out bool moving)
        {
            if (ts < outAt) { double r = (ts - inAt) / FrameIn; moving = r > 0 && r < 1; return r <= 0 ? -1 : EaseBack(r); }
            double o = (ts - outAt) / FrameIn; moving = o < 1;
            return o >= 1 ? -1 : 1 - (1.8 * o * o * o - 0.8 * o * o);      // back-in: ~2% in at o=0.3, home again at 0.44, gone at 1
        }

        // the glass's bend, as the boot's Tube draws it: a picture point (su,sv) shows at the (u,v) where
        // su = u(1 + kx v^2), sv = v(1 + ky u^2) -- solved here by a few fixed-point steps
        float _wcx, _wcy; double _wkx, _wky;
        PointF Wp(float x, float y)
        {
            if (_wkx == 0 && _wky == 0) return new PointF(x, y);
            double su = (x - _wcx) / _wcx, sv = (y - _wcy) / _wcy, u = su, v = sv;
            for (int i = 0; i < 4; i++) { u = su / (1 + _wkx * v * v); v = sv / (1 + _wky * u * u); }
            return new PointF((float)(_wcx + u * _wcx), (float)(_wcy + v * _wcy));
        }
        /// <summary>A straight line of the frame, drawn bent by the glass (in short pieces).</summary>
        void CLine(Graphics g, Pen p, float x0, float y0, float x1, float y1)
        {
            float len = Math.Abs(x1 - x0) + Math.Abs(y1 - y0); int n = Math.Max(1, Math.Min(24, (int)(len / 16)));
            if (n == 1) { g.DrawLine(p, Wp(x0, y0), Wp(x1, y1)); return; }
            var pts = new PointF[n + 1];
            for (int i = 0; i <= n; i++) pts[i] = Wp(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n);
            g.DrawLines(p, pts);
        }
        PointF[] Wps(params PointF[] p) { for (int i = 0; i < p.Length; i++) p[i] = Wp(p[i].X, p[i].Y); return p; }

        /// <summary>What goes over the visor's shading during the reveal: the glass's highlight (fading as the colour
        /// comes up) and the viewfinder, at `t` microseconds into the reveal.</summary>
        public void DecorateOver(int[] pic, int pw, int ph, int vr, double t)
        {
            Glare(pic, pw, vr, GlareLeft(t));
            if (!_reboot) RevealFlare(pic, pw, ph, t);       // (behind the afterimage: drawn first)
            ChaliceOver(pic, pw, ph, t);
            if (Viewfinder && t >= FrameFromUs && t < FrameEndUs) DrawFrame(pic, pw, ph, vr, t);
            DrawDust(pic, pw, ph, vr, t);
        }
        void DrawFrame(int[] pic, int pw, int ph, int vr, double t)
        {
            double ts = (t - FrameFromUs) / 1e6, outAt = (FrameOutUs - FrameFromUs) / 1e6;
            float sc = (float)Math.Max(1, _s), m = Math.Min(pw, vr);
            _wcx = pw / 2f; _wcy = vr / 2f; _wkx = CurveX * FrameCurve; _wky = CurveY * FrameCurve;
            double joinAt = FrameVLag + FrameIn;                                     // both arms home
            float breathe = (float)(1.2 * sc * Math.Sin((ts - joinAt) * 2 * Math.PI * 0.8) * Math.Max(0, Math.Min(1, (ts - joinAt) / 0.4)));
            float x0 = (float)(pw * FrameSide) - breathe, x1 = pw - (float)(pw * FrameSide) + breathe;
            float y0 = (float)(vr * FrameTop) - breathe, y1 = vr - (float)(vr * FrameBottom) + breathe;
            float arm = m * 0.075f, cxm = pw / 2f, cym = (y0 + y1) / 2f, step = m * 0.016f, minor = 4 * sc, major = 9 * sc;
            // the rulers' reach: out from the middle once they are in, back in as the frame starts to leave
            double q = EaseOut((ts - FrameRulerLag - FrameIn * 0.7) / 0.6) * (1 - EaseOut((ts - outAt) / 0.3));
            float rx = (float)(pw * 0.13 * q), ry = (float)((y1 - y0) * 0.17 * q);
            double hunt = Math.Max(0, ts - FrameRulerLag - FrameIn * 0.7);
            float mx = cxm + (float)(pw * 0.06 * Math.Exp(-2.4 * hunt) * Math.Cos(7.5 * hunt));
            float my = cym + (float)((y1 - y0) * 0.09 * Math.Exp(-2.2 * hunt) * Math.Sin(6.5 * hunt + 1.2));
            float far = 10 * sc;                                                     // how far past the screen edge a piece starts
            Paint(pic, pw, ph, g =>
            {
                g.SetClip(new RectangleF(0, 0, pw, vr));
                // trails first (k = 3..1: where each piece was a moment ago, fainter), the piece itself last
                for (int k = 3; k >= 0; k--)
                {
                    double tt = ts - k * 0.035, trail = k == 0 ? 1 : 0.5 / k;
                    bool movH, movV, movR;
                    double pH = PieceAt(tt, 0, outAt + FrameOutH, out movH), pV = PieceAt(tt, FrameVLag, outAt + FrameOutV, out movV), pR = PieceAt(tt, FrameRulerLag, outAt + FrameOutR, out movR);
                    if (k > 0 && !movH && !movV && !movR) continue;
                    // each piece's offset from home: off the screen at 0, home at 1 (past it a little on the way)
                    float oL = -(x0 + arm + far) * (float)(1 - pH), oR = (pw - x1 + arm + far) * (float)(1 - pH);
                    float oT = -(y0 + arm + far) * (float)(1 - pV), oB = (vr - y1 + arm + far) * (float)(1 - pV);
                    float rT = -(y0 + major + far) * (float)(1 - pR), rB = (vr - y1 + major + far) * (float)(1 - pR);
                    float rL = -(x0 + major + far) * (float)(1 - pR), rR = (pw - x1 + major + far) * (float)(1 - pR);
                    for (int pass = 0; pass < 2; pass++)
                    {
                        int col = pass == 0 ? VectorHalo : VectorCore;
                        int a = (int)(255 * trail * (pass == 0 ? 0.26 : 0.9));
                        using (var pen = new Pen(Argb(a, col), pass == 0 ? 5 * sc : 1.5f * sc))
                        using (var thin = new Pen(Argb((int)(a * 0.7), col), pass == 0 ? 4 * sc : 1.1f * sc))
                        using (var fill = new SolidBrush(Argb(a, col)))
                        {
                            if (pH >= 0 && (k == 0 || movH))
                            {   // the horizontal arms, in from the sides (and back out to them)
                                CLine(g, pen, x0 + oL, y0, x0 + arm + oL, y0); CLine(g, pen, x0 + oL, y1, x0 + arm + oL, y1);
                                CLine(g, pen, x1 + oR, y0, x1 - arm + oR, y0); CLine(g, pen, x1 + oR, y1, x1 - arm + oR, y1);
                            }
                            if (pV >= 0 && (k == 0 || movV))
                            {   // the vertical arms, down from the top and up from the bottom
                                CLine(g, pen, x0, y0 + oT, x0, y0 + arm + oT); CLine(g, pen, x1, y0 + oT, x1, y0 + arm + oT);
                                CLine(g, pen, x0, y1 + oB, x0, y1 - arm + oB); CLine(g, pen, x1, y1 + oB, x1, y1 - arm + oB);
                            }
                            if (pR >= 0 && (k == 0 || movR))
                            {   // the rulers, each in from its own edge, then drawing outward from its middle
                                for (int i = 0; i * step <= Math.Max(rx, 0.1f); i++)
                                {
                                    float h = i % 5 == 0 ? major : minor;
                                    foreach (float x in i == 0 ? new[] { cxm } : new[] { cxm - i * step, cxm + i * step })
                                    { CLine(g, thin, x, y0 + rT, x, y0 + rT + h); CLine(g, thin, x, y1 + rB, x, y1 + rB - h); }
                                }
                                for (int i = 0; i * step <= Math.Max(ry, 0.1f); i++)
                                {
                                    float h = i % 5 == 0 ? major : minor;
                                    foreach (float y in i == 0 ? new[] { cym } : new[] { cym - i * step, cym + i * step })
                                    { CLine(g, thin, x0 + rL, y, x0 + rL + h, y); CLine(g, thin, x1 + rR, y, x1 + rR - h, y); }
                                }
                            }
                            if (k > 0) continue;
                            // while the frame is whole: a short second stroke inside each corner, flickering on after the
                            // join and off again as the frame starts to leave
                            double on = ts - joinAt, off = ts - outAt;
                            if (on > 0 && off < 0.12 && (on > 0.12 || (((int)(on * 50)) & 1) == 0) && (off < 0 || (((int)(off * 50)) & 1) == 0))
                            {
                                float d = 5 * sc, s2 = arm * 0.35f;
                                CLine(g, thin, x0 + d, y0 + d, x0 + d + s2, y0 + d); CLine(g, thin, x0 + d, y0 + d, x0 + d, y0 + d + s2);
                                CLine(g, thin, x1 - d, y0 + d, x1 - d - s2, y0 + d); CLine(g, thin, x1 - d, y0 + d, x1 - d, y0 + d + s2);
                                CLine(g, thin, x0 + d, y1 - d, x0 + d + s2, y1 - d); CLine(g, thin, x0 + d, y1 - d, x0 + d, y1 - d - s2);
                                CLine(g, thin, x1 - d, y1 - d, x1 - d - s2, y1 - d); CLine(g, thin, x1 - d, y1 - d, x1 - d, y1 - d - s2);
                            }
                            // the corners flash as the arms join, and again (smaller, no ring) as they part
                            double fj = on / 0.3, fp = (ts - outAt - FrameOutV) / 0.22;
                            foreach (var fl in new[] { fj, fp })
                            {
                                if (fl < 0 || fl >= 1) continue;
                                bool join = fl == fj;
                                using (var ring = new Pen(Argb((int)(a * (1 - fl)), col), (pass == 0 ? 4 : 1.5f) * sc))
                                using (var dot = new SolidBrush(Argb((int)(a * (1 - fl)), pass == 0 ? col : 0xFFFFFF)))
                                {
                                    float rr = arm * (float)(0.12 + 0.45 * fl), dd = (float)((join ? 4 : 3) * sc * (1 - fl) + sc);
                                    foreach (var c0 in new[] { new PointF(x0, y0), new PointF(x1, y0), new PointF(x0, y1), new PointF(x1, y1) })
                                    {
                                        var c = Wp(c0.X, c0.Y);
                                        if (join) g.DrawEllipse(ring, c.X - rr, c.Y - rr, 2 * rr, 2 * rr);
                                        g.FillEllipse(dot, c.X - dd, c.Y - dd, 2 * dd, 2 * dd);
                                    }
                                }
                            }
                            if (q > 0 && off < 0.1 && (off < 0 || (((int)(off * 50)) & 1) == 0))
                            {   // the markers: small arrowheads riding the rulers, pointing at them
                                float ah = 6 * sc, aw = 4 * sc, ay = y0 + major + 3 * sc, ax = x0 + major + 3 * sc, by = y1 - major - 3 * sc, bx = x1 - major - 3 * sc;
                                g.FillPolygon(fill, Wps(new PointF(mx - aw, ay + ah), new PointF(mx + aw, ay + ah), new PointF(mx, ay)));
                                g.FillPolygon(fill, Wps(new PointF(mx - aw, by - ah), new PointF(mx + aw, by - ah), new PointF(mx, by)));
                                g.FillPolygon(fill, Wps(new PointF(ax + ah, my - aw), new PointF(ax + ah, my + aw), new PointF(ax, my)));
                                g.FillPolygon(fill, Wps(new PointF(bx - ah, my - aw), new PointF(bx - ah, my + aw), new PointF(bx, my)));
                            }
                        }
                    }
                }
            });
        }

        // ---- THE GLASS'S HIGHLIGHT (Josh, 2026-10-07: "a subtle highlight to the screen in the top right, which will
        // fade as the amber fades in"). A soft reflection on the tube, over everything (even the visor's shading, as it
        // is on the glass): a tilted oval, soft-edged with a brighter core, blended toward warm white. There all through
        // the boot; during the reveal it fades out with the amber as the colour comes up. Cached per picture size.
        /// <summary>Peak strength (0..1 toward warm white), centre and size (shares of the width / view height), tilt (deg).</summary>
        public double Highlight = 0.12, HighlightX = 0.80, HighlightY = 0.14, HighlightW = 0.24, HighlightH = 0.13, HighlightTilt = -16;
        public int HighlightColour = 0xFFF6E6;
        byte[] _glare; int _gx0, _gy0, _gw, _gh, _gpw, _gvr; double _gk;
        /// <summary>The highlight's strength `t` microseconds into the reveal: full until the colour starts, gone as it is up.</summary>
        double GlareLeft(double t)
        {
            if (ColourSeconds <= 0) return t < ColourFromUs ? 1 : 0;
            double s = Math.Max(0, Math.Min(1, (t - ColourFromUs) / (ColourSeconds * 1e6))); s = s * s * (3 - 2 * s);
            return 1 - s;
        }
        /// <summary>Lay the highlight on a picture at `strength` (0..1). Public for the offline tests.</summary>
        public void Glare(int[] pic, int pw, int vr, double strength)
        {
            if (Highlight <= 0 || strength <= 0.003) return;
            if (_glare == null || _gpw != pw || _gvr != vr || _gk != Highlight)
            {
                double cx = HighlightX * pw, cy = HighlightY * vr, rx = HighlightW * pw / 2, ry = HighlightH * vr / 2, r = Math.Max(rx, ry);
                double ca = Math.Cos(HighlightTilt * Math.PI / 180), sa = Math.Sin(HighlightTilt * Math.PI / 180);
                int gx0 = Math.Max(0, (int)(cx - r)), gx1 = Math.Min(pw, (int)Math.Ceiling(cx + r)), gy0 = Math.Max(0, (int)(cy - r)), gy1 = Math.Min(vr, (int)Math.Ceiling(cy + r));
                int gw = Math.Max(0, gx1 - gx0), gh = Math.Max(0, gy1 - gy0); var gl = new byte[gw * gh];
                for (int y = 0; y < gh; y++)
                    for (int x = 0; x < gw; x++)
                    {
                        double dx = gx0 + x + 0.5 - cx, dy = gy0 + y + 0.5 - cy;
                        double a = (dx * ca + dy * sa) / rx, b = (-dx * sa + dy * ca) / ry, d2 = a * a + b * b;
                        if (d2 >= 1) continue;
                        double soft = (1 - d2) * (1 - d2), core = Math.Max(0, 1 - d2 * 3.2); core *= core;
                        gl[y * gw + x] = (byte)Math.Min(255, 255 * Highlight * (0.7 * soft + 0.3 * core));
                    }
                _glare = gl; _gx0 = gx0; _gy0 = gy0; _gw = gw; _gh = gh; _gpw = pw; _gvr = vr; _gk = Highlight;
            }
            var gm = _glare; int w = _gw, x0g = _gx0, y0g = _gy0, k = (int)(Math.Min(1, strength) * 256);
            int hr = (HighlightColour >> 16) & 255, hg = (HighlightColour >> 8) & 255, hb = HighlightColour & 255;
            System.Threading.Tasks.Parallel.For(0, _gh, y =>
            {
                int o = (y0g + y) * pw + x0g, mo = y * w;
                for (int x = 0; x < w; x++)
                {
                    int a = gm[mo + x] * k >> 8; if (a == 0) continue;
                    int c = pic[o + x], r = (c >> 16) & 255, gg = (c >> 8) & 255, bb = c & 255;
                    r += (hr - r) * a / 255; gg += (hg - gg) * a / 255; bb += (hb - bb) * a / 255;
                    pic[o + x] = (r << 16) | (gg << 8) | bb;
                }
            });
        }

        // ---- 15. THE COLOUR COMES UP (Josh, 2026-10-07) ----------------------------------------
        // The shutter opens on the world as the TUBE shows it -- amber monochrome, under the raster --
        // and once it is fully open the visor's tint disengages: colour comes up and the raster fades.
        /// <summary>How long the colour takes to come up after the shutter is fully open (s); 0 = straight to colour.</summary>
        public double ColourSeconds = 1.2;
        /// <summary>The visor's view before the colour comes up is ENHANCED, as night-vision is: dark lifted (gamma) and
        /// brightened, so a dim cave reads as a glowing amber image and the change to real colour is unmistakable.</summary>
        public double VisorGamma = 0.55, VisorGain = 1.25;
        /// <summary>When the colour starts coming up: after the shutter AND the calibration lock (the tint disengages once locked).</summary>
        double ColourFromUs { get { return LockUs; } }
        double RevealUs { get { return Math.Max(Math.Max(Math.Max(LockUs + LockFlashUs, ColourFromUs + ColourSeconds * 1e6), WeaponFromUs + (WeaponType + WeaponHold + WeaponFade) * 1e6), Viewfinder ? FrameEndUs : 0); } }
        int[] _tintLut;
        void ColourUp(int[] pic, int pw, int ph, int vr, double t)
        {
            if (ColourSeconds <= 0) return;
            double s = Math.Max(0, Math.Min(1, (t - ColourFromUs) / (ColourSeconds * 1e6))); s = s * s * (3 - 2 * s);
            if (s >= 1) return;
            int fill = C_warm[C_warm.Length - 1][0];
            if (_tintLut == null)
            {   // a phosphor's ramp: black up to the tube's amber, then on toward a warm white
                var lut = new int[256]; int lf = Math.Max(1, Lum(fill));
                for (int l0 = 0; l0 < 256; l0++)
                {
                    int l = (int)Math.Min(255, 255 * Math.Pow(l0 / 255.0, VisorGamma) * VisorGain);
                    lut[l0] = l <= lf ? Lerp(0, fill, l / (double)lf) : Lerp(fill, 0xFFF2D2, (l - lf) / (double)Math.Max(1, 255 - lf));
                }
                _tintLut = lut;
            }
            var tl = _tintLut; int keep = (int)(s * 256);
            System.Threading.Tasks.Parallel.For(0, ph, y =>
            {
                for (int i = y * pw, e = i + pw; i < e; i++) { int c = pic[i]; pic[i] = Lerp256(tl[Lum(c)], c, keep); }
            });
            if (ScanDark > 0) Raster(pic, pw, vr, C_warm[C_warm.Length - 1][1], 1 - s);
        }

        // ---- 11. THE HUD POWERS UP WITH THE READOUT ---------------------------------------------
        /// <summary>The lower HUD (Panel.cs): held off until the first readout line ("DEPLOYING MS-2 HELMET INTERFACE..."), then it
        /// slides in and its keys flicker on; its health bar fills on "HEALTH SYSTEM INITIATED".</summary>
        public Panel Hud;
        bool _hudOut, _hudHealth;
        // THE HUD'S SOUND (Josh, 2026-10-07: his ratchet.mp3, "played when the UI comes in from the left right"): played the
        // moment the held HUD is let go to slide in -- and only then (a reload whose HUD is already out has no slide).
        /// <summary>The clip (a 16-bit WAV, stereo kept) and its level against the boot's own sounds; null = none.</summary>
        public string HudSoundPath; public double HudSoundLevel = 0.5;
        short[] _hudPcm;
        void HudSlideSound()
        {
            var s = Sound; if (s == null || !s.On) return;
            if (_hudPcm == null && HudSoundPath != null && File.Exists(HudSoundPath)) _hudPcm = s.LoadStereoWav(HudSoundPath, HudSoundLevel);
            if (_hudPcm != null) { try { s.PlayStereo(_hudPcm); } catch { } }
        }
        void HudBeats(long el)
        {
            var hud = Hud; if (hud == null) return;
            if (!_hudOut && !HudWait && (el >= U_text || _reboot))
            {
                _hudOut = true; if (hud.HoldOff) HudSlideSound(); hud.HoldOff = false;
                if (!_reboot) { hud.PowerUp(hud.SlideSeconds + 0.15); Note(string.Format("visor boot: the HUD comes in at {0:N2} s", el / 1e6)); }
            }
            if (!_hudHealth && !_reboot && el >= U_text + (_lines.Length - 1) * U_line) { _hudHealth = true; hud.BootHealth(); }
        }
        /// <summary>A LOAD HOLDS THE HUD (Josh, 2026-10-13: the HUD's slide-in played behind the loading panel): while set, the
        /// boot never lets the HUD go by itself (its beats, a re-boot, the game reaching play) -- the watcher does, with HudIn().</summary>
        public volatile bool HudWait;
        /// <summary>Let the HUD in now (with its slide-in sound if it was held back): the watcher, once a load's panel is gone.</summary>
        public void HudIn() { HudWait = false; ReleaseHud(); }
        void ReleaseHud() { var hud = Hud; if (hud != null) { if (hud.HoldOff) HudSlideSound(); hud.HoldOff = false; } _hudOut = true; }

        // =====================================================================================
        // THE TUBE COMING ON (Josh, 2026-10-07): "a degauss thunk and red/blue distortion at the very beginning ... to
        // indicate it's kicking in"; "a proper power-on: a bright dot snaps into a horizontal line, which then opens
        // vertically into the amber screen, before the warm-up we already have"; "hum bar and snow: a faint dark band
        // drifting slowly up the screen, plus fine animated noise that thins as the damage clears"; and a live ECG for
        // the heart-rate line. All timed from the guest's clock like everything else, so they sit in the first moments
        // of the boot the CD effect already plays under: the screen is open by 0.44 s, as the first 7s come in.
        // =====================================================================================
        /// <summary>The power-on: the dot (s), the snap to a line (s), the line opening into the screen (s).</summary>
        public bool PowerOn = true; public double PowerDot = 0.07, PowerLine = 0.19, PowerOpen = 0.44;
        public int PowerColour = 0xFFF4DC;
        long PowerUs { get { return PowerOn ? (long)(PowerOpen * 1e6) : 0; } }
        // the power-on as a mask over the frame: black outside the dot / line / opening band, light inside it
        void PowerMask(int[] pic, int pw, int vr, long el)
        {
            double t = el / 1e6, cx = pw / 2.0, cy = vr / 2.0, s = Math.Max(1, _s);
            double dotR = 4.5 * s, lineH = 1.3 * s;
            double wHalf, hHalf, glow; bool lit;       // lit: the dot or line itself is drawn (else the screen shows through)
            if (t < PowerDot) { wHalf = dotR * (0.4 + 0.6 * EaseOut(t / PowerDot)); hHalf = wHalf; lit = true; glow = 1; }
            else if (t < PowerLine) { double p = Math.Pow((t - PowerDot) / (PowerLine - PowerDot), 0.6); wHalf = dotR + (cx - dotR) * p; hHalf = lineH * (1 + 0.6 * (1 - p)); lit = true; glow = 1; }
            else
            {
                // (the lips fade fast as the band opens: slowing into the edges, they stacked up in the afterglow as bars)
                double p = EaseOut((t - PowerLine) / (PowerOpen - PowerLine)); wHalf = cx; hHalf = lineH + (cy - lineH) * p; lit = false; glow = Math.Pow(1 - p, 2.5);
            }
            int pc = PowerColour, gr = (int)(10 * s);
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                double dy = Math.Abs(y + 0.5 - cy); int o = y * pw;
                for (int x = 0; x < pw; x++)
                {
                    double dx = Math.Abs(x + 0.5 - cx);
                    int i = o + x;
                    if (lit)
                    {
                        // the dot or the line: a hard bright core and a soft glow round it, on black
                        double ex = Math.Max(0, dx - (wHalf - (t < PowerDot ? 0 : hHalf))), ey = Math.Max(0, dy - hHalf * 0.5);
                        double d = t < PowerDot ? Math.Max(0, Math.Sqrt(dx * dx + dy * dy) - dotR * 0.5) : Math.Sqrt(ex * ex + ey * ey);
                        double k = d <= 0 ? 1 : Math.Exp(-d / (t < PowerDot ? dotR * 0.8 : lineH * 1.6)) * (dx < wHalf ? 1 : 0.85);
                        pic[i] = k <= 0.004 ? 0 : Lerp256(0, pc, (int)(256 * Math.Min(1, k)));
                        continue;
                    }
                    // the opening: the screen inside the band, black outside, a bright lip at its edges fading as it opens
                    double edge = hHalf - dy;
                    if (edge < 0) { double k = Math.Exp(edge / (1.5 * s)) * glow; pic[i] = k < 0.01 ? 0 : Lerp256(0, pc, (int)(200 * k)); continue; }
                    if (edge < gr && glow > 0) pic[i] = Lerp256(pic[i], pc, (int)(220 * glow * (1 - edge / gr)));
                    else if (glow > 0) pic[i] = Lerp256(pic[i], pc, (int)(110 * glow * glow));       // the screen flashes as it opens
                }
            });
        }

        /// <summary>The degauss: when (s after the boot starts), how far the red and blue beams swing (game px) and how
        /// quickly the swing dies (s), its rate (Hz), the picture's wobble (game px) and the purity blotches' strength.</summary>
        public bool Degauss = true; public double DegaussAt = 0.04, DegaussConv = 26, DegaussDecay = 0.42, DegaussHz = 6.2, DegaussWobble = 7, DegaussPurity = 0.45;
        /// <summary>A second degauss as the mission comes up (Josh, 2026-10-07), this strong against the first (0 = none).</summary>
        public double MissionDegauss = 0.8;
        /// <summary>The degauss's swing at `el`: signed, 1 = full (0 when over) -- the power-on's, and the mission's.</summary>
        double DegaussSwing(long el, out double env)
        {
            env = 0; if (!Degauss) return 0;
            double s = OneDegauss(el / 1e6 - DegaussAt, 1.0, ref env);
            if (!_reboot && MissionDegauss > 0) s += OneDegauss((el - U_mission) / 1e6, MissionDegauss, ref env);
            return s;
        }
        /// <summary>The third degauss, as the shutter opens on the game: this strong against the power-on's (0 = none).</summary>
        public double OpenDegauss = 0.9;
        /// <summary>The reveal's red/blue split and ripple against the sound's strength (Josh, 2026-10-14: "the red/blue degauss
        /// enhanced a bit on that phase"): 1.5x the swing, 1.25x the ripple.</summary>
        public double OpenDegaussLook = 1.5, OpenDegaussWobble = 1.25;
        // the red and blue beams pulled apart and swinging back, and the rows rippling, on the whole picture (boot and game)
        void RevealDegauss(int[] pic, int pw, int vr, double tUs)
        {
            if (OpenDegauss <= 0 || !Degauss) return;
            double env = 0, s = OneDegauss(tUs / 1e6, OpenDegauss, ref env);
            double conv = DegaussConv * _s * s * OpenDegaussLook, wob = DegaussWobble * _s * env * OpenDegaussWobble, ph = tUs / 1e6 * 9.0;
            if (Math.Abs(conv) < 0.5 && wob < 0.5) return;
            int ci = (int)Math.Round(conv);
            System.Threading.Tasks.Parallel.For(0, vr, () => new int[pw], (y, st, row) =>
            {
                int o = y * pw, w = (int)Math.Round(wob * Math.Sin(y * 0.035 + ph));
                Array.Copy(pic, o, row, 0, pw);
                for (int x = 0; x < pw; x++)
                {
                    int xr = x - ci - w, xg = x - w, xb = x + ci - w;
                    xr = xr < 0 ? 0 : xr >= pw ? pw - 1 : xr; xg = xg < 0 ? 0 : xg >= pw ? pw - 1 : xg; xb = xb < 0 ? 0 : xb >= pw ? pw - 1 : xb;
                    pic[o + x] = (row[xr] & 0xFF0000) | (row[xg] & 0x00FF00) | (row[xb] & 0x0000FF);
                }
                return row;
            }, row => { });
        }
        double OneDegauss(double t, double k, ref double env)
        {
            if (t < 0 || t > DegaussDecay * 6) return 0;
            double e = k * Math.Exp(-t / DegaussDecay) * Math.Min(1, t / 0.03); if (e > env) env = e;
            return e * Math.Sin(2 * Math.PI * DegaussHz * t);
        }
        // the colour purity blotches a degauss throws across the tube: soft regions pushed toward red, green or blue,
        // swirling as the field collapses (separable sine fields: cheap)
        float[] _pfx, _pfy, _pgx, _pgy;
        void Purity(int[] pic, int pw, int vr, long el)
        {
            double env; DegaussSwing(el, out env); double a = DegaussPurity * env;
            if (a < 0.01) return;
            double t = el / 1e6;
            if (_pfx == null || _pfx.Length != pw) { _pfx = new float[pw]; _pgx = new float[pw]; }
            if (_pfy == null || _pfy.Length != vr) { _pfy = new float[vr]; _pgy = new float[vr]; }
            for (int x = 0; x < pw; x++) { double u = x / (double)pw; _pfx[x] = (float)Math.Sin(2 * Math.PI * u * 1.3 + t * 5.0); _pgx[x] = (float)Math.Sin(2 * Math.PI * u * 0.9 - t * 4.1 + 1.7); }
            for (int y = 0; y < vr; y++) { double v = y / (double)vr; _pfy[y] = (float)Math.Cos(2 * Math.PI * v * 1.1 - t * 3.3); _pgy[y] = (float)Math.Cos(2 * Math.PI * v * 1.6 + t * 4.4 + 0.6); }
            float[] fx = _pfx, fy = _pfy, gx = _pgx, gy = _pgy; float ak = (float)a;
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                int o = y * pw; float ry = fy[y], by = gy[y];
                for (int x = 0; x < pw; x++)
                {
                    float fr = fx[x] * ry * ak, fb = gx[x] * by * ak, fg = -(fr + fb) * 0.5f;
                    int c = pic[o + x], r = (int)(((c >> 16) & 255) * (1 + fr)), g = (int)(((c >> 8) & 255) * (1 + fg)), b = (int)((c & 255) * (1 + fb));
                    pic[o + x] = (Math.Max(0, Math.Min(255, r)) << 16) | (Math.Max(0, Math.Min(255, g)) << 8) | Math.Max(0, Math.Min(255, b));
                }
            });
        }

        /// <summary>THE HUM BAR: a faint dark band drifting up the screen -- how dark, how tall (share of the view), how long a
        /// pass takes (s), and how strong it stays once the damage has cleared (share).</summary>
        public double HumDark = 0.12, HumHeight = 0.16, HumPeriod = 6.5, HumAfter = 0.45;
        /// <summary>SNOW: fine noise over the tube while it is damaged -- the share of pixels it touches at first, how far it
        /// moves them (levels), and when it has thinned to nothing (s after the damage ends).</summary>
        public double SnowDensity = 0.55, SnowAmp = 48, SnowTail = 1.0;
        void HumAndSnow(int[] pic, int pw, int vr, long el, long frameSeed)
        {
            double t = el / 1e6, dis = DisruptUs / 1e6;
            // the bar: full while damaged, settling to HumAfter over two seconds after
            double hk = t < dis ? 1 : HumAfter + (1 - HumAfter) * Math.Max(0, 1 - (t - dis) / 2.0);
            double hh = Math.Max(4, HumHeight * vr), yc = vr * (1.15 - ((t / HumPeriod) % 1.0) * 1.3);
            double sEnd = dis + SnowTail, u = Math.Min(1, t / sEnd);
            double dens = t < sEnd ? SnowDensity * Math.Pow(1 - u, 1.5) : 0, amp = SnowAmp * (0.4 + 0.6 * (1 - u));
            if (HumDark <= 0 && dens <= 0) return;
            uint thr = (uint)(Math.Min(1, dens) * uint.MaxValue); int ai = (int)amp;
            System.Threading.Tasks.Parallel.For(0, vr, y =>
            {
                int o = y * pw;
                double d = Math.Abs(y + 0.5 - yc) / hh; int mul = 256;
                if (HumDark > 0 && d < 1) mul = (int)(256 * (1 - HumDark * hk * (0.5 + 0.5 * Math.Cos(Math.PI * d))));
                if (thr == 0 && mul >= 256) return;                  // (nothing to do on this row)
                uint st = (uint)(y * 2654435761u) ^ (uint)(frameSeed * 0x9E3779B9L) ^ 0xA5A5A5A5u; if (st == 0) st = 1;
                for (int x = 0; x < pw; x++)
                {
                    int c = pic[o + x], r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
                    if (thr > 0)
                    {
                        st ^= st << 13; st ^= st >> 17; st ^= st << 5;
                        if (st < thr)
                        {   // a speck: lighter or darker, warm like the tube (amber-weighted)
                            int n = (int)((st >> 8) % (uint)(2 * ai + 1)) - ai;
                            r += n; g += n * 7 >> 3; b += n * 5 >> 3;
                            r = r < 0 ? 0 : r > 255 ? 255 : r; g = g < 0 ? 0 : g > 255 ? 255 : g; b = b < 0 ? 0 : b > 255 ? 255 : b;
                        }
                    }
                    if (mul < 256) { r = r * mul >> 8; g = g * mul >> 8; b = b * mul >> 8; }
                    pic[o + x] = (r << 16) | (g << 8) | b;
                }
            });
        }

        // ---- THE HEART-RATE TRACE (Josh: "RAPTOR HEART RATE 125BPM draws a live ECG line at 125 beats per minute,
        // oscilloscope style, with phosphor trail"). A small scope beside that line of the readout: a faint graticule,
        // the trace swept left to right by a bright head, the last beats fading behind it, a gap just ahead of the head
        // where the old trace is wiped. Live from that line's arrival until the readout gives way to the briefing.
        public bool HeartTrace = true; public double HeartBpm = 90, HeartSweep = 2.0, HeartW = 230, HeartGap = 26;     // (Josh: 125 -> 90 BPM; a sweep is 3 beats)
        static double Ecg(double ph)
        {
            // one beat, phase 0..1: P wave, Q dip, the tall R spike, S dip, T wave
            Func<double, double, double, double> G = (c, w, a) => a * Math.Exp(-(ph - c) * (ph - c) / (2 * w * w));
            return G(0.14, 0.028, 0.12) + G(0.30, 0.008, -0.14) + G(0.325, 0.011, 1.0) + G(0.35, 0.010, -0.28) + G(0.56, 0.05, 0.26);
        }
        // ---- THE HEART AS A WATERMARK (Josh, 2026-10-07: "fade in, and be very large in the background as sort of a
        // watermark ... as the heart rate plays out", the small bright one kept). The same trace, the same beats, swept
        // across most of the screen behind everything, faint and soft: it fades in as the heart-rate line arrives and
        // out as the readout gives way to the briefing.
        public double HeartBigAlpha = 0.16, HeartBigFadeIn = 1.4;
        void DrawHeartBig(int[] pic, int pw, int ph, int vr, long el, int ink)
        {
            if (!HeartTrace || HeartBigAlpha <= 0) return;
            long from = HeartFrom; if (el < from || el >= U_mission) return;
            double ts = Math.Max(0, HeartSeconds(el)), beat = 60.0 / HeartBpm, sweep = HeartSweep * 1.5;
            double fade = Math.Min(1, (el - from) / (HeartBigFadeIn * 1e6));
            fade = fade * fade * (3 - 2 * fade);
            if (el > DecayFrom) fade *= Math.Max(0, 1 - (el - DecayFrom) / (double)Math.Max(1, U_mission - DecayFrom));
            if (fade <= 0.01) return;
            float x0 = pw * 0.06f, w = pw * 0.88f, yc = vr * 0.55f, hh = vr * 0.26f, sc = (float)Math.Max(1, _s);
            Paint(pic, pw, ph, g =>
            {
                g.SetClip(new RectangleF(0, 0, pw, vr));
                int n = Math.Max(80, (int)(w / 6)); var pts = new PointF[n + 1];
                for (int k = 0; k <= n; k++)
                {
                    double back = k / (double)n * 0.92, tx = ts - back * sweep, xs = ((tx / sweep) % 1.0 + 1.0) % 1.0;
                    double v = Ecg(((tx / beat) % 1.0 + 1.0) % 1.0);
                    pts[k] = new PointF(x0 + (float)(xs * w), yc + hh * 0.25f - (float)(v * hh));
                }
                const int Run = 8;
                for (int pass = 0; pass < 2; pass++)
                    using (var pen = new Pen(Color.Black, pass == 0 ? 22f * sc : 5f * sc))
                    {
                        pen.LineJoin = LineJoin.Round; pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                        for (int k0 = 0; k0 < n; k0 += Run)
                        {
                            int k1 = Math.Min(n, k0 + Run); double age = (k0 + k1) * 0.5 / n;
                            int a = (int)(255 * HeartBigAlpha * fade * Math.Pow(1 - age, 1.2) * (pass == 0 ? 0.35 : 1.0));
                            if (a < 2) continue;
                            pen.Color = Argb(a, pass == 0 ? VectorHalo : ink);
                            int s0 = k0;
                            for (int k = k0; k < k1; k++) if (pts[k + 1].X > pts[k].X + 1) { if (k > s0) DrawRun(g, pen, pts, s0, k); s0 = k + 1; }
                            if (k1 > s0) DrawRun(g, pen, pts, s0, k1);
                        }
                    }
            });
        }

        // ---- THE STATUS COLUMN (Josh, 2026-10-07: "a second status column on the right to balance the hex column ...
        // a revolving vector line frame of a chalice (the holy grail) would be amazing"). The briefing's objective is
        // LOCATE HOLY GRAIL, so the right side is the visor's ARTIFACT TRACE: the chalice as a teal wireframe in
        // perspective, revolving, its far side dimmer, a scan line passing over it; under it a signal that strengthens
        // as the boot goes on, a bearing and a range ticking -- and POTENTIAL LOCATION when the objective comes up.
        // THEN (same day): "a fragmented, broken image until the mission/objective, and then ... in full view and rotating
        // ... still appearing and fading away as the amber fade away effect leads into the game". Until the briefing the
        // trace is a corrupt signal (ChaliceBroken); as the objective comes up it pulls together; and it stays on, over
        // the game, through the shutter, fading out with the amber (DecorateOver). It turns on the WALL clock, so it keeps
        // revolving through the hold, when the boot's own clock stands still.
        public bool StatusColumn = true; public double StatusW = 230, StatusSpin = 0.75;
        /// <summary>The broken trace before the briefing: share of segments lost, how far slices of it are thrown
        /// (share of its size), how often the damage re-rolls (Hz), and how long it takes to pull together (s).</summary>
        public double ChaliceDrop = 0.45, ChaliceShear = 0.16, ChaliceGlitchHz = 12, ChaliceResolve = 0.35;
        /// <summary>How strong the chalice stays once the game is in view, before it fades with the amber.</summary>
        public double ChaliceOverGame = 0.6;          // (unused since the afterimage replaced the small chalice over the game)
        // the chalice's profile, radius against height (0 = foot, 1 = rim): foot, stem with its knop, the bowl
        static readonly double[] CupR = { 0.40, 0.38, 0.15, 0.075, 0.06, 0.12, 0.06, 0.07, 0.22, 0.35, 0.43, 0.46, 0.45 };
        static readonly double[] CupY = { 0.00, 0.03, 0.07, 0.14, 0.30, 0.38, 0.45, 0.52, 0.58, 0.68, 0.82, 0.94, 1.00 };
        static readonly int[] CupRings = { 0, 2, 5, 7, 9, 11, 12 };
        bool _noCup;                                  // (the shutter's held frame is drawn without it: the live one goes over)
        const float BracketReach = 0.68f;            // the chalice's corner marks, either side of its centre (share of its size)
        // WHEN THE OBJECTIVE COMES UP (Josh, 2026-10-07: "the image of the grail should ease to a 15% larger size and move
        // to the left, closer to the mission/objective text (centered between the right edge of that text and the right
        // edge of the screen)"). It starts as the trace pulls together, and stays there over the game in the reveal.
        /// <summary>How much larger it ends, when it starts (s after the objective appears) and how long the ease takes (s).</summary>
        public double ChaliceGrow = 0.15, ChaliceMoveAt = 0.35, ChaliceMoveTime = 0.9;
        /// <summary>Extra room on the column's right before it moves (game px; 15 ~ 20 px on a 1238-row view -- Josh: "about 20px").</summary>
        public double ChaliceInset = 15;
        /// <summary>The reveal's afterimage: its height against the view (over 1 runs it off the bottom), its middle (shares of
        /// the width and the view's height: low and left, so it runs off those edges), its strength, how wide its glow is
        /// (share of the view's height), how long it takes to come up, how far over its strength it flares, and how fast
        /// the flare dies (s).</summary>
        public double GhostSize = 1.15, GhostX = 0.114, GhostY = 0.78, GhostAlpha = 0.5, GhostGlow = 0.07, GhostRise = 0.12, GhostFlare = 0.8, GhostFlareTime = 0.35;
        /// <summary>The burn-in's amber (screened onto the picture; GhostX 0.27 -> 0.114: ~400 px further left on a 2562-wide picture, Josh).</summary>
        public int GhostAmber = 0xF0A040;
        int[] _ghostMask;
        /// <summary>The afterimage is CRISP lines this wide (share of the view's height); GhostGlowOn brings back the soft glow version.</summary>
        public double GhostLine = 0.0028; public bool GhostGlowOn = false;
        /// <summary>How much the glow is softened (it is drawn at 1/this of the size), and how strong the thin trace of its lines is.</summary>
        public int GhostBlur = 7; public double GhostTrace = 0.16;
        double ChaliceMove(long el)
        {
            if (_reboot) return 0;
            double u = (el - U_mission - ChaliceMoveAt * 1e6) / (ChaliceMoveTime * 1e6);
            u = Math.Max(0, Math.Min(1, u)); return u * u * u * (u * (u * 6 - 15) + 10);       // (smoother-step: no jolt at either end)
        }
        // the right edge of the mission text (its three lines and the icon), in picture px
        float MisRight()
        {
            float r = _icon != null ? _icon.X + _icon.W : 0;
            if (_misSmallItems != null) foreach (var it in _misSmallItems) r = Math.Max(r, it.X + it.W);
            if (_misItem != null) r = Math.Max(r, _misItem.X + _misItem.W);
            return r;
        }

        // where the column and its chalice sit in a picture of this width (the layout must be current)
        // `move` 0..1: how far the objective has moved it (ChaliceMove). THE WHOLE COLUMN MOVES (Josh, 2026-10-07: "all of
        // it to move to the left, including the text associated with it"): its chalice ends centred between the mission
        // text's right edge and the screen's, 15% larger, and the heading, marks and readings come with it, still lined
        // up on its left bracket.
        void ChaliceGeom(int pw, double move, out float colL, out float colW, out float top, out float cupTop, out float cupH, out float cx, out float cy, out float S)
        {
            // the column's RIGHT BRACKET sits as far in from the right edge as the hex column's code sits from the left
            // (Josh, 2026-10-07); the chalice centred between the brackets, the text starting at the left one
            float sc = (float)(_s * Zoom), k = (float)Math.Max(0, Math.Min(1, move)), grow = 1 + (float)ChaliceGrow * k;
            top = (float)Yt(P_dumpY); cupH = (float)(250 * _s) * grow; cupTop = top + 34 * sc; cy = cupTop + cupH * 0.56f;
            S = cupH * 0.80f;                         // (0.92 put the tilted rim into the header)
            float colR = pw - (float)((P_dumpX + ChaliceInset) * _s), half0 = (float)(250 * _s) * 0.80f * BracketReach, half = S * BracketReach;
            float cx0 = colR - half0; cx = cx0 + ((MisRight() + pw) / 2f - cx0) * k;
            colL = cx - half; colW = Math.Max((float)(StatusW * _s), 2 * half);
        }
        /// <summary>The chalice: alpha 0..1; broken 0 = whole, 1 = a corrupt signal.</summary>
        void DrawChalice(Graphics g, float cx, float cy, float S, float cupTop, float cupH, double alpha, double broken) { DrawChalice(g, cx, cy, S, cupTop, cupH, alpha, broken, 0); }
        double _ghostCore = 1;                        // (the ghost's bright core: none in its blurred glow, only in its thin trace)
        double _ghostFlash;                           // (the crisp afterimage's flare: 0..1 toward the flare white)
        double _explode;                              // (the afterimage breaking up: its pieces flying apart and crackling, 0..1)
        static int Mix(int a, int b, double k)
        {
            k = Math.Max(0, Math.Min(1, k));
            int r = (int)(((a >> 16) & 255) * (1 - k) + ((b >> 16) & 255) * k), g = (int)(((a >> 8) & 255) * (1 - k) + ((b >> 8) & 255) * k), bl = (int)((a & 255) * (1 - k) + (b & 255) * k);
            return (r << 16) | (g << 8) | bl;
        }
        /// <summary>ghostPx &gt; 0: the reveal's afterimage -- no scan line, four soft passes widening to about this many px.</summary>
        void DrawChalice(Graphics g, float cx, float cy, float S, float cupTop, float cupH, double alpha, double broken, float ghostPx)
        {
            if (alpha <= 0.01) return;
            double wt = Wall; long gt = (long)(wt * ChaliceGlitchHz);
            float s1 = (float)Math.Max(1, _s);
            // broken, the turn stutters (it jumps between held angles) and the whole trace flickers
            double spinT = broken > 0 ? Math.Floor(wt / 0.14) * 0.14 + (new Rng(gt, 41).Below(100) < 12 * broken ? 0.4 : 0) : wt;
            double phi = spinT * StatusSpin, tilt = 0.32, ct = Math.Cos(tilt), st = Math.Sin(tilt);
            if (broken > 0) alpha *= 1 - 0.45 * broken * (new Rng(gt, 43).Below(100) / 100.0);
            Func<double, double, double, PointF> P = (r, th, h) =>
            {
                double x = r * Math.Cos(th + phi), z = r * Math.Sin(th + phi), y = h - 0.5;
                double y2 = y * ct - z * st, z2 = y * st + z * ct, k = 1 / (1 + z2 * 0.35);
                return new PointF(cx + (float)(x * S * k), cy - (float)(y2 * S * k));
            };
            // the damage: seven horizontal slices, each thrown sideways or lost for a moment
            const int Bands = 7; var shift = new float[Bands]; var gone = new bool[Bands];
            if (broken > 0)
                for (int b = 0; b < Bands; b++)
                {
                    var r = new Rng(gt, (uint)(100 + b));
                    if (r.Below(100) < 45 * broken) shift[b] = (float)((r.Below(2001) / 1000.0 - 1) * ChaliceShear * S * broken);
                    gone[b] = r.Below(100) < 12 * broken;
                }
            Func<float, int> Band = y => Math.Max(0, Math.Min(Bands - 1, (int)((y - cupTop) / cupH * Bands)));
            int dropPct = (int)(ChaliceDrop * 100 * broken), M = 14;
            // (the ghost: four passes, wide and faint to narrow and bright, the glow of something seen too bright)
            float[] gw = { ghostPx, ghostPx * 0.45f, ghostPx * 0.18f, Math.Max(1.5f, ghostPx * 0.06f) }; int[] ga = { 14, 26, 55, (int)(170 * _ghostCore) };
            // (ghostPx < 0: CRISP -- one clean line that wide, no halo: the afterimage as Josh wants it, 2026-10-07)
            bool crisp = ghostPx < 0;
            int passes = crisp ? 1 : ghostPx > 0 ? 4 : 2;
            for (int pass = 0; pass < passes; pass++)
                using (var pen = new Pen(Color.Black, crisp ? -ghostPx : ghostPx > 0 ? gw[pass] : (pass == 0 ? 4f * s1 : 1.3f * s1)))
                {
                    if (ghostPx != 0) { pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round; }
                    int passI = pass;
                    // a line of the wireframe: whole, or (broken) segment by segment, some lost, slices thrown
                    Action<PointF[], double, uint> Line = (pts, near, id) =>
                    {
                        int a = crisp ? (int)(255 * (0.45 + 0.55 * near) * alpha)
                              : ghostPx > 0 ? (int)(ga[passI] * (0.35 + 0.65 * near) * alpha)
                                            : (int)((passI == 0 ? 60 : 230) * (0.25 + 0.75 * near) * alpha);
                        if (a < 3) return;
                        pen.Color = crisp ? Argb(a, Mix(C_teal, C_tealFlare, _ghostFlash))
                                  : Argb(a, ghostPx > 0 ? (passI == 3 ? C_tealFlare : C_teal) : (passI == 0 ? VectorHalo : (near > 0.8 ? C_tealFlare : C_teal)));
                        if (broken <= 0) { g.DrawLines(pen, pts); return; }
                        for (int i = 0; i + 1 < pts.Length; i++)
                        {
                            uint sid = id * 64 + (uint)i;
                            if (new Rng(gt, sid).Below(100) < (_explode > 0 ? (int)(92 * broken * broken) : dropPct)) continue;
                            int b = Band((pts[i].Y + pts[i + 1].Y) * 0.5f); if (gone[b]) continue;
                            if (_explode <= 0) { g.DrawLine(pen, pts[i].X + shift[b], pts[i].Y, pts[i + 1].X + shift[b], pts[i + 1].Y); continue; }
                            // THE PIECES FLY (Josh: "pieces exploding (in a subtle way) and dissolving in electrical style corrupted
                            // effects"): each segment drifts out from the middle -- its own distance, a little turn, shrinking --
                            // and some crackle into a jagged spark of a line, flickering, with a fleck or two thrown off
                            var rs = new Rng(sid, 77);
                            float ax = pts[i].X + shift[b], ay = pts[i].Y, bx = pts[i + 1].X + shift[b], by = pts[i + 1].Y;
                            float mx = (ax + bx) / 2, my = (ay + by) / 2, ddx = mx - cx, ddy = my - cy, dl = (float)Math.Sqrt(ddx * ddx + ddy * ddy) + 1;
                            float ex = (float)_explode, push = ex * S * 0.26f * (0.45f + rs.Below(100) / 100f);
                            float nx = mx + ddx / dl * push, ny = my + ddy / dl * push + ex * S * 0.04f * (rs.Below(100) / 100f);
                            double ang = (rs.Below(201) - 100) / 100.0 * 1.1 * ex, ca = Math.Cos(ang), sa = Math.Sin(ang);
                            float hx = (bx - ax) / 2 * (1 - 0.55f * ex), hy = (by - ay) / 2 * (1 - 0.55f * ex);
                            float rx = (float)(hx * ca - hy * sa), ry = (float)(hx * sa + hy * ca);
                            PointF p0 = new PointF(nx - rx, ny - ry), p1 = new PointF(nx + rx, ny + ry);
                            if (new Rng(gt, sid + 9000).Below(100) < 40 * ex)
                            {
                                // electrical: a zigzag between the ends, jumping each glitch tick
                                var zr = new Rng(gt, sid + 19000); float px = -(p1.Y - p0.Y), py = p1.X - p0.X, pl = (float)Math.Sqrt(px * px + py * py) + 1e-3f; px /= pl; py /= pl;
                                var z = new PointF[5]; z[0] = p0; z[4] = p1;
                                for (int q = 1; q < 4; q++) { float u = q / 4f, j = (zr.Below(201) - 100) / 100f * s1 * (2 + 5 * ex) * 3; z[q] = new PointF(p0.X + (p1.X - p0.X) * u + px * j, p0.Y + (p1.Y - p0.Y) * u + py * j); }
                                g.DrawLines(pen, z);
                                if (zr.Below(100) < 45)
                                    using (var fleck = new SolidBrush(pen.Color))
                                    { float fr = s1 * (1.5f + zr.Below(3)), fx2 = z[zr.Below(5)].X + (zr.Below(201) - 100) / 100f * s1 * 12, fy2 = z[zr.Below(5)].Y + (zr.Below(201) - 100) / 100f * s1 * 12; g.FillEllipse(fleck, fx2 - fr, fy2 - fr, 2 * fr, 2 * fr); }
                            }
                            else g.DrawLine(pen, p0, p1);
                        }
                    };
                    for (int j = 0; j < M; j++)
                    {
                        double th = 2 * Math.PI * j / M; var pts = new PointF[CupR.Length];
                        for (int i = 0; i < CupR.Length; i++) pts[i] = P(CupR[i], th, CupY[i]);
                        Line(pts, 0.5 - 0.5 * Math.Sin(th + phi), (uint)j);
                    }
                    int ringNo = 0;
                    foreach (int ri in CupRings)
                    {
                        // each ring in two halves, near and far
                        for (int half = 0; half < 2; half++)
                        {
                            var pts = new PointF[17];
                            for (int q = 0; q <= 16; q++) { double th = -phi + Math.PI * (half + q / 16.0); pts[q] = P(CupR[ri], th, CupY[ri]); }
                            Line(pts, half == 1 ? 1.0 : 0.15, (uint)(100 + ringNo * 2 + half));
                        }
                        ringNo++;
                    }
                }
            // the scan line passing down over it (not on the ghost)
            if (ghostPx > 0) return;
            double sp = (wt % 2.4) / 2.4; float sy = cupTop + (float)(sp * cupH);
            using (var scan = new Pen(Argb((int)(110 * alpha), C_tealFlare), 1.2f * s1)) g.DrawLine(scan, cx - S * 0.62f, sy, cx + S * 0.62f, sy);
        }
        /// <summary>How broken the trace is at `el`: whole once the objective is up (pulling together over ChaliceResolve).</summary>
        double ChaliceBroken(long el)
        {
            if (_reboot) return 0;
            if (el < U_mission) return 1;
            return Math.Max(0, 1 - (el - U_mission) / (ChaliceResolve * 1e6));
        }
        void DrawStatus(Graphics g, int pw, long el)
        {
            if (!StatusColumn || el < U_dump) return;
            if (RaptorScan) { DrawRaptor(g, pw, _lvr, el); return; }      // (2026-10-14: the raptor's self scan in its place)
            double age = (el - U_dump) / 1e6, t = el / 1e6;
            if (age < 0.2 && (((int)(age * 40)) & 1) == 1) return;                       // flickering on with the hex column
            float sc = (float)(_s * Zoom), s1 = (float)Math.Max(1, _s);
            float colL, colW, top, cupTop, cupH, cx, cy, S; ChaliceGeom(pw, ChaliceMove(el), out colL, out colW, out top, out cupTop, out cupH, out cx, out cy, out S);
            int ink = C_text;
            using (var font = new Font("Consolas", 15f * sc, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var fmt = Fmt())
            using (var inkB = new SolidBrush(Argb(235, ink)))
            {
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                g.DrawString("ARTIFACT TRACE", font, inkB, colL, top, fmt);
                // LOADING A GAME, no chalice (Josh, 2026-10-07): the readings close up under the heading instead
                if (_reboot) { cupTop = top + 4 * sc; cupH = 0; }
                if (!_noCup && !_reboot) DrawChalice(g, cx, cy, S, cupTop, cupH, 1, ChaliceBroken(el));
                // small corner marks round it
                if (!_reboot)
                using (var pen = new Pen(Argb(150, ink), 1.3f * s1))
                {
                    float bx0 = cx - S * BracketReach, bx1 = cx + S * BracketReach, by0 = cupTop - 2 * sc, by1 = cupTop + cupH + 6 * sc, a = 14 * sc;
                    g.DrawLines(pen, new[] { new PointF(bx0, by0 + a), new PointF(bx0, by0), new PointF(bx0 + a, by0) });
                    g.DrawLines(pen, new[] { new PointF(bx1 - a, by0), new PointF(bx1, by0), new PointF(bx1, by0 + a) });
                    g.DrawLines(pen, new[] { new PointF(bx0, by1 - a), new PointF(bx0, by1), new PointF(bx0 + a, by1) });
                    g.DrawLines(pen, new[] { new PointF(bx1 - a, by1), new PointF(bx1, by1), new PointF(bx1, by1 - a) });
                }
                // the readings: a signal that strengthens toward the briefing, a bearing and a range, ticking
                long tick = (long)(t * 5); var rng = new Rng(tick, 23);
                double prog = Math.Min(1, el / (double)U_mission), sig = 0.18 + 0.79 * prog * prog + (rng.Below(40) - 20) / 1000.0;
                int bearing = 41 + rng.Below(5) - 2, range = (int)(1240 * (1 - 0.86 * prog)) + rng.Below(9);
                float ry = cupTop + cupH + 22 * sc, lh = 21 * sc;
                g.DrawString(string.Format("SIGNAL  {0:0.00}", Math.Min(0.99, sig)), font, inkB, colL, ry, fmt);
                g.DrawString(string.Format("BEARING {0:000}", bearing), font, inkB, colL, ry + lh, fmt);
                g.DrawString(string.Format("RANGE   {0:0000}M", range), font, inkB, colL, ry + 2 * lh, fmt);
                // the signal as a bar
                float bw = colW * 0.9f, bh = 5 * sc, by = ry + 3 * lh + 4 * sc;
                // (Josh, 2026-10-07: "slightly darker than the overall background colour so it doesn't stand out so much": both
                // the track and the fill are now just the background a little darker, whatever colour it is at the time)
                using (var track = new SolidBrush(Argb(24, 0))) g.FillRectangle(track, colL, by, bw, bh);
                using (var fill = new SolidBrush(Argb(58, 0))) g.FillRectangle(fill, colL, by, bw * (float)Math.Min(1, sig), bh);
                if (!_reboot && el >= U_mission && ((((el - U_mission) / 250000) & 1) == 0 || el - U_mission > 2000000))
                    // (not a confirmed location -- Josh: "we can't have a location confirmed message")
                    using (var lockB = new SolidBrush(Argb(255, C_flare))) g.DrawString("POTENTIAL LOCATION", font, lockB, colL, by + 14 * sc, fmt);
            }
        }
        // ---- THE SELF SCAN (Josh, 2026-10-14: "Instead of the grail animation on the right, I want a wireframe of the raptor,
        // slowly revolving as a scan line slowly moves up and down the body, detecting damage and such ... more vertically
        // centered ... the size of the zoomed in grail animation when it enlarges, but this animation will only be while the 7
        // and readout text loads"). The player's own suit (RAPTOR.XAF, standing, breathing) as a teal wireframe in the right
        // column, centred on the view's height, turning slowly; a scan line sweeps up and down it and lights the edges it
        // passes. From the readout's SELF SCAN line on, the marked spots ping as the line crosses them and keep a callout
        // (the readout says the damage is minimal, and so do they). It flickers on with the hex column, is broken while the
        // visor's damage runs, and goes with the readout's decay before the briefing. [[azrael-gpu-boot]]
        public bool RaptorScan = true;
        /// <summary>How far it sits left of the grail's old place (game px; -75 ~ 100 px on a 1238-row view: Josh, 2026-10-14), its height (game px: the enlarged grail's), how fast it turns (rad/s), how far it leans toward the eye (rad),
        /// the scan line's round trip up and down (s), and one breath of its idle (s).</summary>
        public double RaptorShift = -75, RaptorH = 265, RaptorSpin = 0.32, RaptorTilt = 0.16, RaptorScanCycle = 6.4, RaptorBreath = 3.5;
        ScanWire _rig; double[] _rigRange; string[] _rigBones; float[] _rigBuf; int[] _markBone; volatile bool _rigLoading;
        /// <summary>What loading the rig found (for the log): empty until it is done.</summary>
        public volatile string RigNote = "";
        /// <summary>Load the raptor's rig for the self scan, off the caller's thread (its walk and idle ranges from KURT.ANI).</summary>
        public void LoadRaptor(string xaf, int walkFrom, int walkTo, int restFrom, int restTo)
        {
            if (_rigLoading || _rig != null || string.IsNullOrEmpty(xaf) || !File.Exists(xaf)) { if (string.IsNullOrEmpty(xaf) || !File.Exists(xaf)) RigNote = "no self scan: no " + xaf; return; }
            _rigLoading = true;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    var sw = new ScanWire();
                    if (sw.AddBody("RAPTOR", xaf, walkFrom, walkTo, restFrom, restTo))
                    {
                        _rigRange = sw.BodyRanges("RAPTOR"); _rigBones = sw.RigBones("RAPTOR");
                        var mb = new int[MarkBone.Length];
                        for (int i = 0; i < mb.Length; i++) mb[i] = Array.FindIndex(_rigBones, b => string.Equals(b, MarkBone[i], StringComparison.OrdinalIgnoreCase));
                        _markBone = mb; _rig = sw;
                        RigNote = string.Format("the raptor's self scan: {0} bones, idle {1}-{2}", _rigBones.Length, _rigRange[2], _rigRange[3]);
                    }
                    else RigNote = "no self scan: " + sw.LastError;
                }
                catch (Exception e) { RigNote = "no self scan: " + e.Message; }
                finally { _rigLoading = false; Note("visor boot: " + RigNote); }
            });
        }
        /// <summary>Offline: load the rig on this thread.</summary>
        public void LoadRaptorNow(string xaf, int walkFrom, int walkTo, int restFrom, int restTo)
        {
            LoadRaptor(xaf, walkFrom, walkTo, restFrom, restTo);
            var w = Stopwatch.StartNew(); while (_rigLoading && w.ElapsedMilliseconds < 20000) Thread.Sleep(5);
        }
        // the spots the scan reports on: the bone, its callout, and whether it is a (minor) fault
        static readonly string[] MarkBone = { "SVISOR", "SSHOULDER", "STOPBODY", "SLOWLEGL" };
        static readonly string[] MarkText = { "VISOR SEAL  OK", "PLATE ABRASION  2%", "TORSO  NOMINAL", "KNEE SERVO  STRESS 4%" };
        static readonly bool[] MarkHurt = { false, true, false, true };
        double[] _markHit; double _scanPrev = double.NaN;
        long SelfScanUs { get { return U_text + 2 * U_line; } }      // (the readout's "FALL DETECTED, INITIATING SELF SCAN..." line)
        long DamageUs { get { return U_text + 4 * U_line; } }        // ("SUIT DAMAGE MINIMAL...")
        void DrawRaptor(Graphics g, int pw, int vr, long el)
        {
            var rig = _rig; if (rig == null || el < U_dump || el >= U_mission) return;
            double age = (el - U_dump) / 1e6;
            if (age < 0.2 && (((int)(age * 40)) & 1) == 1) return;                       // flickering on with the hex column
            double alpha = 1;
            if (el >= DecayFrom)
            {   // going with the readout: fading, flickering out
                double d = (el - DecayFrom) / (double)Math.Max(1, U_mission - DecayFrom);
                alpha = 1 - d; if (((int)(d * 14)) % 3 == 1) alpha *= 0.35;
            }
            if (alpha <= 0.01) return;
            float sc = (float)(_s * Zoom), s1 = (float)Math.Max(1, _s);
            float H = (float)(RaptorH * _s), cy = vr * 0.5f;
            float colR = pw - (float)((P_dumpX + ChaliceInset - RaptorShift) * _s), half = H * 0.42f, cx = colR - half;
            double wt = Wall;
            // broken while the visor's damage runs: slices thrown, segments lost, re-rolled at the glitch rate
            double broken = el < DisruptUs ? 0.8 * (1 - el / (double)DisruptUs) : 0; long gt = (long)(wt * ChaliceGlitchHz);
            double f = _rigRange[3] > _rigRange[2] ? _rigRange[2] + (_rigRange[3] - _rigRange[2]) * ((wt / RaptorBreath) % 1.0) : _rigRange[2];
            int n = rig.RigEdges("RAPTOR", f, Math.PI + wt * RaptorSpin, ref _rigBuf); var e = _rigBuf;
            double ct = Math.Cos(RaptorTilt), st = Math.Sin(RaptorTilt);
            // the scan line: top to bottom and back, easing at the turns (body units, +0.5 the crown, -0.5 the soles)
            double sp = 0.5 - 0.5 * Math.Cos(2 * Math.PI * wt / RaptorScanCycle), yS = 0.5 - sp;
            float scanY = cy - (float)(yS * ct * H);
            const int Bands = 9; var shift = new float[Bands]; var gone = new bool[Bands];
            if (broken > 0)
                for (int b = 0; b < Bands; b++)
                {
                    var r = new Rng(gt, (uint)(300 + b));
                    if (r.Below(100) < 45 * broken) shift[b] = (float)((r.Below(2001) / 1000.0 - 1) * ChaliceShear * H * broken);
                    gone[b] = r.Below(100) < 12 * broken;
                }
            // the edges, sorted into a few strengths (a pen a strength, not a pen an edge): far .. near, and lit by the scan
            var lists = new List<PointF>[5]; for (int i = 0; i < 5; i++) lists[i] = new List<PointF>(n);
            int nm = _markBone != null ? _markBone.Length : 0; var mSum = new double[nm * 4];
            for (int i = 0; i < n; i++)
            {
                int o = i * 7; int bone = (int)e[o + 6];
                for (int k = 0; k < nm; k++) if (_markBone[k] == bone) { mSum[k * 4] += e[o] + e[o + 3]; mSum[k * 4 + 1] += e[o + 1] + e[o + 4]; mSum[k * 4 + 2] += e[o + 2] + e[o + 5]; mSum[k * 4 + 3] += 2; }
                double y0 = e[o + 1] * ct - e[o + 2] * st, z0 = e[o + 1] * st + e[o + 2] * ct, y1 = e[o + 4] * ct - e[o + 5] * st, z1 = e[o + 4] * st + e[o + 5] * ct;
                double k0 = 1 / (1 + z0 * 0.35), k1 = 1 / (1 + z1 * 0.35);
                var a = new PointF(cx + (float)(e[o] * H * k0), cy - (float)(y0 * H * k0)); var b2 = new PointF(cx + (float)(e[o + 3] * H * k1), cy - (float)(y1 * H * k1));
                if (broken > 0)
                {
                    if (new Rng(gt, (uint)i).Below(100) < (int)(ChaliceDrop * 100 * broken)) continue;
                    int bd = Math.Max(0, Math.Min(Bands - 1, (int)(((a.Y + b2.Y) * 0.5f - (cy - H * 0.55f)) / (H * 1.1f) * Bands)));
                    if (gone[bd]) continue; a.X += shift[bd]; b2.X += shift[bd];
                }
                double ym = (e[o + 1] + e[o + 4]) * 0.5, zm = (z0 + z1) * 0.5;
                int li = Math.Abs(ym - yS) < 0.03 ? 4 : Math.Max(0, Math.Min(3, (int)((0.5 - zm * 1.6) * 4)));
                lists[li].Add(a); lists[li].Add(b2);
            }
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (broken > 0) alpha *= 1 - 0.4 * broken * (new Rng(gt, 47).Below(100) / 100.0);
            int[] coreA = { 70, 120, 175, 225, 255 }, haloA = { 10, 18, 28, 40, 40 };
            for (int pass = 0; pass < 2; pass++)
                for (int li = 0; li < 5; li++)
                {
                    var L = lists[li]; if (L.Count == 0) continue;
                    int al = (int)((pass == 0 ? haloA[li] : coreA[li]) * alpha); if (al < 3) continue;
                    int col = pass == 0 ? VectorHalo : (li >= 3 ? C_tealFlare : C_teal);
                    using (var pen = new Pen(Argb(al, col), pass == 0 ? 3.2f * s1 : (li == 4 ? 1.6f : 1.1f) * s1))
                        for (int q = 0; q + 1 < L.Count; q += 2) g.DrawLine(pen, L[q], L[q + 1]);
                }
            // the scan line itself, with a faint wake behind it
            float sw = H * 0.40f; double dir = Math.Sin(2 * Math.PI * wt / RaptorScanCycle);      // >0: going down
            for (int k = 3; k >= 0; k--)
            {
                float yy = scanY - (float)(Math.Sign(dir) * k * 3.5f * s1);
                using (var pen = new Pen(Argb((int)((k == 0 ? 150 : 40 / k) * alpha), C_tealFlare), (k == 0 ? 1.3f : 1f) * s1)) g.DrawLine(pen, cx - sw, yy, cx + sw, yy);
            }
            // corner marks round it
            using (var pen = new Pen(Argb((int)(150 * alpha), C_text), 1.3f * s1))
            {
                float bx0 = cx - half, bx1 = cx + half, by0 = cy - H * 0.57f, by1 = cy + H * 0.57f, a = 14 * sc;
                g.DrawLines(pen, new[] { new PointF(bx0, by0 + a), new PointF(bx0, by0), new PointF(bx0 + a, by0) });
                g.DrawLines(pen, new[] { new PointF(bx1 - a, by0), new PointF(bx1, by0), new PointF(bx1, by0 + a) });
                g.DrawLines(pen, new[] { new PointF(bx0, by1 - a), new PointF(bx0, by1), new PointF(bx0 + a, by1) });
                g.DrawLines(pen, new[] { new PointF(bx1 - a, by1), new PointF(bx1, by1), new PointF(bx1, by1 - a) });
            }
            // THE CALLOUTS: once the self scan has begun, a spot pings as the line crosses it and keeps its callout, typed out
            if (_markHit == null || _markHit.Length != nm) { _markHit = new double[nm]; for (int k = 0; k < nm; k++) _markHit[k] = -1; }
            bool armed = el >= SelfScanUs && !double.IsNaN(_scanPrev);
            using (var font = new Font("Consolas", 13f * sc, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var fmt = Fmt())
                for (int k = 0; k < nm; k++)
                {
                    if (mSum[k * 4 + 3] <= 0) continue;
                    double mx = mSum[k * 4] / mSum[k * 4 + 3], my = mSum[k * 4 + 1] / mSum[k * 4 + 3], mz = mSum[k * 4 + 2] / mSum[k * 4 + 3];
                    if (armed && (my - _scanPrev) * (my - yS) <= 0 && _scanPrev != yS)
                    {
                        _markHit[k] = wt;
                        if (_ov != null && Sound != null && Sound.On && el < DecayFrom) { try { Sound.Line(600 + k, 0.05, MarkHurt[k] ? 1.5 : 1.8); } catch { } }
                    }
                    if (_markHit[k] < 0) continue;
                    double y2 = my * ct - mz * st, z2 = my * st + mz * ct, kk = 1 / (1 + z2 * 0.35), since = wt - _markHit[k];
                    float px = cx + (float)(mx * H * kk), py = cy - (float)(y2 * H * kk);
                    double near = Math.Max(0.35, Math.Min(1, 0.6 - z2 * 2));
                    int mc = MarkHurt[k] ? C_flare : C_tealFlare;
                    // the ping: a ring opening and fading
                    if (since < 0.7)
                        using (var ring = new Pen(Argb((int)(220 * (1 - since / 0.7) * alpha), mc), 1.4f * s1))
                        { float rr = (float)(4 + 22 * EaseOut(since / 0.7)) * s1; g.DrawEllipse(ring, px - rr, py - rr, 2 * rr, 2 * rr); }
                    // the spot: a small square bracket, brighter on the near side
                    float d = 5 * s1;
                    using (var pen = new Pen(Argb((int)(230 * near * alpha), mc), 1.3f * s1)) g.DrawRectangle(pen, px - d, py - d, 2 * d, 2 * d);
                    // the callout, out to the left of the figure: a leader, then the text typed on
                    var txt = MarkText[k]; double typed = Math.Min(1, (wt - FirstHit(k)) / 0.45); int chars = (int)Math.Ceiling(txt.Length * typed);
                    float lx = cx - H * 0.56f, ly = py;
                    using (var pen = new Pen(Argb((int)(140 * alpha), C_text), 1f * s1)) { g.DrawLine(pen, px - d, py, lx + 4 * s1, ly); }
                    if (chars > 0)
                    {
                        string shownTxt = txt.Substring(0, chars); var sz = g.MeasureString(shownTxt, font, PointF.Empty, fmt);
                        using (var br = new SolidBrush(Argb((int)(235 * alpha), MarkHurt[k] ? C_flare : C_text))) g.DrawString(shownTxt, font, br, lx - sz.Width, ly - sz.Height / 2, fmt);
                    }
                }
            _scanPrev = yS;
            // the heading above and the readings under it
            using (var font = new Font("Consolas", 15f * sc, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var fmt = Fmt())
            using (var inkB = new SolidBrush(Argb((int)(235 * alpha), C_text)))
            {
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                float tx = cx - half, top = cy - H * 0.57f - 26 * sc, ry = cy + H * 0.57f + 12 * sc, lh = 21 * sc;
                g.DrawString("MS-2 SELF SCAN", font, inkB, tx, top, fmt);
                double prog = el < SelfScanUs ? 0 : Math.Min(1, (el - SelfScanUs) / (double)Math.Max(1, DamageUs - SelfScanUs));
                var rng = new Rng((long)(wt * 6), 29);
                string integ = el < SelfScanUs ? "--" : string.Format("{0}", prog < 1 ? (int)(97 * prog) + rng.Below(3) : 97);
                g.DrawString("SUIT INTEGRITY " + integ + "%", font, inkB, tx, ry, fmt);
                g.DrawString(string.Format("SCAN PASS {0:00}", el < SelfScanUs ? 0 : 1 + (int)((wt - FirstScanWall()) / (RaptorScanCycle / 2))), font, inkB, tx, ry + lh, fmt);
            }
        }
        /// <summary>Offline renders: the wall clock the turning and the scan run on (seconds); below 0 = the real one.</summary>
        public double WallOverride = -1;
        double Wall { get { return WallOverride >= 0 ? WallOverride : _wall.Elapsed.TotalSeconds; } }
        double _firstScan = -1;
        double FirstScanWall() { if (_firstScan < 0) _firstScan = Wall; return _firstScan; }
        double[] _markFirst;
        double FirstHit(int k)
        {
            if (_markFirst == null || _markFirst.Length != _markHit.Length) { _markFirst = new double[_markHit.Length]; for (int i = 0; i < _markFirst.Length; i++) _markFirst[i] = -1; }
            if (_markFirst[k] < 0) _markFirst[k] = _markHit[k];
            return _markFirst[k];
        }

        // ---- THE GRAIL BEHIND THE BRIEFING (Josh, 2026-10-14: "When we move to the next Objective text, I want the grail to
        // rotate behind this mission text as a sort of watermark, larger than the objective text overall. Then as we fade to the
        // game, everything stays the same, but the grail is now centered and large on screen, having grown in a smooth
        // transition from the new grail watermark ... the grail will play out the shatter and fade effect with the exact same
        // timing"). From the briefing on, the chalice turns behind the mission text, centred on it and larger than it, BURNED in
        // (the afterimage's amber screened on, faint), pulling together as it comes up. In the reveal the same burn-in grows
        // from there to the middle of the view, large, as it strengthens to the afterimage's level; then it breaks up and goes
        // with the amber exactly as before (GhostBreak, GlareLeft).
        // THEN (same day, after seeing it): "Move the new grail down by about 50px, and make it much larger in the lower right in
        // the mirror position of where it was during the previous version. It will remain there at the same size during the fade
        // to gameplay, and break apart exactly as it did originally." So ONE place for both: the old afterimage's pose mirrored
        // (lower RIGHT, its size, running off the right and the bottom), 50 px lower (on a 1238-row view); faint on the briefing,
        // the afterimage's own rise, flare, break-up and fade in the reveal, without moving.
        public bool GrailWatermark = true;
        /// <summary>The watermark's strength and how long it takes to come up (s); its middle (shares of the width and the view's
        /// height) and its size (the old afterimage's: GhostSize of the view's height -- the chalice drawn 0.8 of it).</summary>
        public double WmAlpha = 0.22, WmFadeIn = 0.6, GrailX = 1 - 0.114, GrailY = 0.78 + 50.0 / 1238, GrailSize = 1.15;
        int[] _wmMask;
        void WatermarkPose(int pw, int vr, out float cx, out float cy, out float S)
        {
            cx = (float)(pw * GrailX); cy = (float)(vr * GrailY); S = (float)(vr * GrailSize * 0.80);
        }
        // ROUND 4 (Josh, 2026-10-14: "Move the grail to a smaller size, having it slowly slowly get larger during the Objective/
        // mission portion. It wont get as big as it is on the fade to game sequence, but right before the object screen ends, I
        // want the grail to become broken with a bunch of static as if a signal is being lost. Then ... the same fade to game
        // sequence we have now, but with the grail moved upward by 100px"). On the briefing it starts at WmFrom of the afterimage's
        // size and grows steadily to WmTo by the time the screen ends; over the last SignalLoss seconds it breaks up (the trace's
        // own damage), flickers, fades and drowns in static (GrailStatic). The reveal's afterimage comes back from nothing with
        // its flare, GhostLift higher, at full size, and breaks up and goes as it always did.
        /// <summary>The briefing's grail against the afterimage's size: at the start and at the end; how long the signal takes to
        /// go (s, ending as the screen does); and how much higher the reveal's afterimage is (share of the view's height).</summary>
        public double WmFrom = 0.5, WmTo = 0.75, SignalLoss = 0.9, GhostLift = 100.0 / 1238;
        void DrawWatermark(int[] pic, int pw, int vr, long el)
        {
            if (!GrailWatermark || !StatusColumn || _noCup || _reboot || el < U_mission) return;
            double u = Smooth((el - U_mission) / (WmFadeIn * 1e6));
            float cx, cy, S; WatermarkPose(pw, vr, out cx, out cy, out S);
            double grow = Math.Max(0, Math.Min(1, (el - U_mission) / (double)Math.Max(1, U_open - U_mission)));
            S *= (float)(WmFrom + (WmTo - WmFrom) * grow);
            long lossFrom = U_open - (long)(SignalLoss * 1e6);
            double lost = Smooth((el - lossFrom) / (SignalLoss * 1e6));
            double a = WmAlpha * u * (1 - 0.9 * Smooth((lost - 0.55) / 0.45));      // (broken and crackling first, gone only at the very end)
            if (lost > 0) { var r = new Rng((long)(Wall * ChaliceGlitchHz), 53); if (r.Below(100) < 35 * lost) a *= 0.25 + r.Below(60) / 100.0; }   // (dropping out)
            BurnChalice(pic, pw, vr, cx, cy, S, a, Math.Max(ChaliceBroken(el), Math.Min(1, lost * 1.4)), 0, 0, ref _wmMask);
            if (lost > 0) GrailStatic(pic, pw, vr, cx, cy, S, lost);
        }
        /// <summary>How thick the static gets as the signal goes (share of the pixels over the grail at its worst).</summary>
        public double StaticDensity = 0.6, StaticBright = 1.6;
        // THE SIGNAL GOING: snow over the grail's patch (an oval, soft at its edge), new every 30th of a second, with now and then
        // a bright torn line across it -- thicker and brighter as `amt` goes to 1
        void GrailStatic(int[] pic, int pw, int vr, float cx, float cy, float S, double amt)
        {
            long tick = (long)(Wall * 30);
            float rx = S * 0.62f, ry = S * 0.70f;
            int x0 = Math.Max(0, (int)(cx - rx)), x1 = Math.Min(pw, (int)(cx + rx) + 1), y0 = Math.Max(0, (int)(cy - ry)), y1 = Math.Min(vr, (int)(cy + ry) + 1);
            if (x1 <= x0 || y1 <= y0) return;
            int dens = (int)(1000 * StaticDensity * amt);
            System.Threading.Tasks.Parallel.For(y0, y1, y =>
            {
                var r = new Rng(tick * 8191 + y, 61);
                double dy = (y - cy) / ry; dy *= dy;
                bool tear = r.Below(1000) < (int)(9 * amt); int tearV = 60 + r.Below(120);
                int o = y * pw;
                for (int x = x0; x < x1; x++)
                {
                    double dx = (x - cx) / rx, q = dx * dx + dy; if (q >= 1) continue;
                    double w = 1 - q; w *= w;
                    if (tear) { int v = (int)(tearV * w * Math.Min(1, amt * StaticBright)); Screen(pic, o + x, v, (int)(v * 0.9), (int)(v * 0.75)); continue; }
                    if (r.Below(1000) >= dens * w) continue;
                    int s = (int)(r.Below(230) * w * Math.Min(1, amt * StaticBright));
                    Screen(pic, o + x, s, (int)(s * 0.92), (int)(s * 0.8));
                }
            });
        }
        /// <summary>The chalice BURNED into a picture: its crisp lines into a coverage mask, the amber screened on through it.
        /// S: its size (the drawn height); a: strength 0..1; brk: broken; explode: flying apart (the afterimage's end);
        /// flash: the lines whitening.</summary>
        void BurnChalice(int[] pic, int pw, int vr, float cx, float cy, float S, double a, double brk, double explode, double flash, ref int[] mask)
        {
            if (a <= 0.01 || S < 4) return;
            float cupH = S / 0.80f, cupTop = cy - cupH * 0.56f, lw = Math.Max(1.5f, (float)(vr * GhostLine));
            float reach = S * (0.8f + 0.6f * (float)explode) + 20;
            int y0 = Math.Max(0, (int)(cy - reach)), y1 = Math.Min(vr, (int)(cy + reach) + 1), rows = y1 - y0; if (rows <= 0) return;
            if (mask == null || mask.Length < pw * rows) mask = new int[pw * rows]; else Array.Clear(mask, 0, pw * rows);
            var hm = GCHandle.Alloc(mask, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(pw, rows, pw * 4, PixelFormat.Format32bppPArgb, hm.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias; g.TranslateTransform(0, -y0);
                    double fl = _ghostFlash; _ghostFlash = flash; _explode = explode;
                    try { DrawChalice(g, cx, cy, S, cupTop, cupH, 1.0, brk, -lw); } finally { _explode = 0; _ghostFlash = fl; }
                }
            }
            finally { hm.Free(); }
            int col = Mix(GhostAmber, VectorCore, flash * 0.7);
            int cr = (col >> 16) & 255, cg = (col >> 8) & 255, cb = col & 255, op = (int)(256 * Math.Min(1.0, a)); var mk = mask;
            System.Threading.Tasks.Parallel.For(y0, y1, y =>
            {
                int o = y * pw, mo = (y - y0) * pw;
                for (int x = 0; x < pw; x++)
                {
                    int m = (int)((uint)mk[mo + x] >> 24); if (m == 0) continue;
                    int ka = m * op >> 8;
                    int sr = cr * ka >> 8, sg = cg * ka >> 8, sb = cb * ka >> 8, p = pic[o + x];
                    int r = (p >> 16) & 255, gg = (p >> 8) & 255, b = p & 255;
                    r = 255 - ((255 - r) * (255 - sr) >> 8); gg = 255 - ((255 - gg) * (255 - sg) >> 8); b = 255 - ((255 - b) * (255 - sb) >> 8);
                    pic[o + x] = (p & unchecked((int)0xFF000000)) | (r << 16) | (gg << 8) | b;
                }
            });
        }
        // THE FLARE (Josh, 2026-10-07): "just after the degauss ... a flare of bright amber behind the large chalice, like a
        // pulse of light as if the monitor is popping into existence, but a bright round flare that fades as it reaches the
        // center, and is off-center to the bottom left behind the grail image". A round pool of amber light SCREENED onto the
        // picture, centred low and left, falling off to nothing by the middle of the view; it swells in a moment after the
        // thunk and dies away.
        /// <summary>Its centre (shares of the width and the view's height), its peak strength, when it starts and how long it
        /// takes to swell and to die (s), and its colour (the core goes paler).</summary>
        public double FlareX = 1 - 0.09, FlareY = 0.87, FlarePeak = 0.85, FlareAt = 0.05, FlareRise = 0.16, FlareFade = 0.75;      // (FlareX mirrored to the lower right with the grail: Josh, 2026-10-14)
        public int FlareColour = 0xFFA43A, FlareCore = 0xFFE2A8;
        /// <summary>The red and blue spread apart along the diagonal (share of the radius, Josh: "mix in some red/blue like the
        /// pulses earlier"), and the lens flare: its ghosts' strength and the streak's (0 = none).</summary>
        public double FlareFringe = 0.07, LensGhosts = 0.32, LensStreak = 0.5;
        float[] _flareLut;
        void RevealFlare(int[] pic, int pw, int ph, double tUs)
        {
            double t = tUs / 1e6 - FlareAt; if (t <= 0 || FlarePeak <= 0) return;
            double env = FlarePeak * (t < FlareRise ? Smooth(t / FlareRise) : Math.Exp(-(t - FlareRise) / FlareFade));
            if (env < 0.01) return;
            int vr = _lvr > 0 ? _lvr : ph;
            double fx = pw * FlareX, fy = vr * FlareY, dxc = pw * 0.5 - fx, dyc = vr * 0.5 - fy, R = Math.Sqrt(dxc * dxc + dyc * dyc);   // reaching the middle, gone
            if (_flareLut == null) { _flareLut = new float[1025]; for (int i = 0; i <= 1024; i++) { double d = Math.Sqrt(i / 1024.0); _flareLut[i] = (float)(Math.Pow(1 - d, 1.5) * (0.7 + 0.3 * Math.Exp(-d * d * 18))); } }
            var lut = _flareLut; int cr = (FlareColour >> 16) & 255, cg = (FlareColour >> 8) & 255, cb = FlareColour & 255, kr = (FlareCore >> 16) & 255, kg = (FlareCore >> 8) & 255, kb = FlareCore & 255;
            // the fringe: red's pool a little bigger and pushed out along the diagonal, blue's a little smaller and pulled in
            double ux = dxc / R, uy = dyc / R, fr = FlareFringe;
            double rxR = fx - ux * R * fr, ryR = fy - uy * R * fr, RR = R * (1 + fr), rxB = fx + ux * R * fr, ryB = fy + uy * R * fr, RB = R * (1 - fr);
            int y0 = Math.Max(0, (int)(fy - RR) - 1), y1 = Math.Min(vr, (int)(fy + RR) + 2), xr = (int)(RR + R * fr) + 2;
            float e = (float)env;
            System.Threading.Tasks.Parallel.For(y0, y1, y =>
            {
                int o = y * pw, xa = Math.Max(0, (int)(fx - xr)), xb = Math.Min(pw, (int)(fx + xr) + 1);
                for (int x = xa; x < xb; x++)
                {
                    double dx = x - fx, dy = y - fy, q = (dx * dx + dy * dy) / (R * R);
                    double dxr = x - rxR, dyr = y - ryR, qr = (dxr * dxr + dyr * dyr) / (RR * RR), dxb = x - rxB, dyb = y - ryB, qb = (dxb * dxb + dyb * dyb) / (RB * RB);
                    float kG = q < 1 ? lut[(int)(q * 1024)] * e : 0, kR = qr < 1 ? lut[(int)(qr * 1024)] * e : 0, kB = qb < 1 ? lut[(int)(qb * 1024)] * e : 0;
                    if (kR < 0.004f && kG < 0.004f && kB < 0.004f) continue;
                    float core = (float)Math.Exp(-q * 30);                               // the hot middle, paler
                    int sr = (int)((cr + (kr - cr) * core) * kR), sg = (int)((cg + (kg - cg) * core) * kG), sb = (int)((cb + (kb - cb) * core) * kB + 40 * kB * (1 - kG));
                    Screen(pic, o + x, sr, sg, sb);
                }
            });
            // THE LENS FLARE: ghosts strung from the source through the middle and out past it, and a streak through the source
            if (LensGhosts > 0)
            {
                double[] at = { 0.42, 0.78, 1.18, 1.45, 1.85, 2.25 }, rad = { 0.022, 0.06, 0.035, 0.11, 0.03, 0.075 };
                int[] col = { 0xFFC060, 0xFF8040, 0x60A0FF, 0xFFB060, 0xFF5050, 0x60E0D0 }; bool[] ring = { false, false, true, false, false, true };
                for (int k = 0; k < at.Length; k++)
                {
                    double gx = fx + dxc * at[k], gy = fy + dyc * at[k];
                    Disc(pic, pw, vr, gx, gy, vr * rad[k], col[k], env * LensGhosts * (k == 3 ? 0.6 : 1), ring[k]);
                }
            }
            if (LensStreak > 0)
            {
                // a thin horizontal streak through the source, fading along its length
                double hh = vr * 0.0045, len = pw * 0.55; int ya = Math.Max(0, (int)(fy - hh * 4)), yb = Math.Min(vr, (int)(fy + hh * 4) + 1);
                for (int y = ya; y < yb; y++)
                {
                    double vy = Math.Exp(-(y - fy) * (y - fy) / (2 * hh * hh)), o = y * pw;
                    for (int x = Math.Max(0, (int)(fx - len)); x < Math.Min(pw, (int)(fx + len)); x++)
                    {
                        double k = vy * Math.Pow(1 - Math.Abs(x - fx) / len, 2) * env * LensStreak; if (k < 0.004) continue;
                        Screen(pic, (int)o + x, (int)(255 * k), (int)(200 * k), (int)(150 * k));
                    }
                }
            }
        }
        // (Josh, 2026-10-07: "have that final grail image break apart at the end as it fades away") -- as the amber goes, the
        // afterimage goes the way the trace came in, as a corrupt signal: segments lost, slices thrown, the turn stuttering
        double GhostBreak(double tUs) { double gone = 1 - GlareLeft(tUs); return Smooth((gone - GhostBreakFrom) / GhostBreakSpan); }
        /// <summary>When the afterimage starts breaking up (share of the amber's fade gone) and over how much of it.</summary>
        public double GhostBreakFrom = 0.02, GhostBreakSpan = 0.55;
        static void Screen(int[] pic, int i, int sr, int sg, int sb)
        {
            if (sr > 255) sr = 255; if (sg > 255) sg = 255; if (sb > 255) sb = 255; if (sr < 0) sr = 0; if (sg < 0) sg = 0; if (sb < 0) sb = 0;
            int p = pic[i], r = (p >> 16) & 255, g = (p >> 8) & 255, b = p & 255;
            r = 255 - ((255 - r) * (255 - sr) >> 8); g = 255 - ((255 - g) * (255 - sg) >> 8); b = 255 - ((255 - b) * (255 - sb) >> 8);
            pic[i] = (p & unchecked((int)0xFF000000)) | (r << 16) | (g << 8) | b;
        }
        // a soft lens ghost: a disc fading to its edge, or a thin ring
        static void Disc(int[] pic, int pw, int vr, double cx, double cy, double r, int col, double a, bool ring)
        {
            if (a < 0.01 || r < 1) return;
            int x0 = Math.Max(0, (int)(cx - r) - 1), x1 = Math.Min(pw, (int)(cx + r) + 2), y0 = Math.Max(0, (int)(cy - r) - 1), y1 = Math.Min(vr, (int)(cy + r) + 2);
            int cr = (col >> 16) & 255, cg = (col >> 8) & 255, cb = col & 255;
            for (int y = y0; y < y1; y++)
                for (int x = x0; x < x1; x++)
                {
                    double d = Math.Sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / r; if (d >= 1) continue;
                    double k = ring ? Math.Exp(-Math.Pow((d - 0.86) / 0.07, 2)) : (1 - d * d) * (0.55 + 0.45 * Math.Exp(-Math.Pow((d - 0.9) / 0.08, 2)));
                    k *= a; if (k < 0.004) continue;
                    Screen(pic, y * pw + x, (int)(cr * k), (int)(cg * k), (int)(cb * k));
                }
        }        static double Smooth(double x) { x = Math.Max(0, Math.Min(1, x)); return x * x * (3 - 2 * x); }
        /// <summary>The chalice's afterimage over the game during the reveal (t: microseconds into it).</summary>
        void ChaliceOver(int[] pic, int pw, int ph, double t)
        {
            if (!StatusColumn || _reboot) return;            // (no chalice when loading a game)
            if (GrailWatermark)
            {
                // (2026-10-14) THE WATERMARK STAYS: where the briefing's grail was, the same size; it strengthens from its faint
                // level to the afterimage's over the afterimage's own rise, flares, breaks up and goes with the amber as it always did
                int vrW = _lvr > 0 ? _lvr : ph;
                float wx, wy, wS; WatermarkPose(pw, vrW, out wx, out wy, out wS);
                double up = Smooth(t / (GhostRise * 1e6));
                double flash = GhostFlare * up * Math.Exp(-Math.Max(0, t - GhostRise * 1e6) / (GhostFlareTime * 1e6));
                double aw = GhostAlpha * up * Math.Pow(GlareLeft(t), 0.7), brk = GhostBreak(t);      // (round 4: back from the lost signal, from nothing)
                BurnChalice(pic, pw, vrW, wx, wy - (float)(vrW * GhostLift), wS, aw, brk, brk, flash, ref _ghostMask);
                return;
            }
            // THE AFTERIMAGE (Josh, 2026-10-07): "a large version of it transposed on the lower left side of the viewport as the
            // amber fades into gameplay, like a sunspot/watermark ... filling nearly the entire viewport but spanning outside of
            // it at the bottom and a portion to the left. It will flare, then fade with the fading amber, like a memory."
            // It comes up with the shutter, flares (GhostFlare over GhostFlareTime), and goes as the amber does (GlareLeft).
            // (2026-10-07, after seeing it: "too strong, and ideally more crisp. No glow needed. Only 50% transparent." So: clean
            // lines at GhostAlpha 0.5 at most; the flare is the lines whitening for a moment, not more opacity.)
            double u0 = t / (GhostRise * 1e6), rise = Math.Max(0, Math.Min(1, u0)); rise = rise * rise * (3 - 2 * rise);
            _ghostFlash = GhostFlare * Math.Exp(-Math.Max(0, t - GhostRise * 1e6) / (GhostFlareTime * 1e6));
            double a = GhostAlpha * rise * Math.Pow(GlareLeft(t), 0.7);      // (a touch slower than the amber: its pieces are seen flying apart)
            if (a <= 0.01) return;
            int vr = _lvr > 0 ? _lvr : ph;
            float cupH = (float)(vr * GhostSize), S = cupH * 0.80f;
            float cx = (float)(pw * GhostX), cy = (float)(vr * GhostY), cupTop = cy - cupH * 0.56f;
            if (!GhostGlowOn)
            {
                // A BURN-IN (Josh, 2026-10-07: "more of the amber tone, but a sort of overlay or screen burn blend so it feels
                // more like a watermark"): the crisp lines go into a coverage mask, and the amber is SCREENED onto the picture
                // through it -- the scene under them brightened toward amber, never covered. Near lines burn in stronger.
                float lw = Math.Max(1.5f, (float)(vr * GhostLine));
                if (_ghostMask == null || _ghostMask.Length != pw * vr) _ghostMask = new int[pw * vr]; else Array.Clear(_ghostMask, 0, _ghostMask.Length);
                var hm = GCHandle.Alloc(_ghostMask, GCHandleType.Pinned);
                try
                {
                    using (var bm = new Bitmap(pw, vr, pw * 4, PixelFormat.Format32bppPArgb, hm.AddrOfPinnedObject()))
                    using (var g = Graphics.FromImage(bm)) { g.SmoothingMode = SmoothingMode.AntiAlias; double brk = GhostBreak(t); _explode = brk; try { DrawChalice(g, cx, cy, S, cupTop, cupH, 1.0, brk, -lw); } finally { _explode = 0; } }
                }
                finally { hm.Free(); }
                int col = Mix(GhostAmber, VectorCore, _ghostFlash * 0.7);         // (the flare: toward a pale amber)
                int cr = (col >> 16) & 255, cg = (col >> 8) & 255, cb = col & 255; int op = (int)(256 * Math.Min(1.0, a)); var mask = _ghostMask;
                System.Threading.Tasks.Parallel.For(0, vr, y =>
                {
                    int o = y * pw;
                    for (int x = 0; x < pw; x++)
                    {
                        int m = (int)((uint)mask[o + x] >> 24); if (m == 0) continue;
                        int ka = m * op >> 8;                                        // 0..255: how much amber here
                        int sr = cr * ka >> 8, sg = cg * ka >> 8, sb = cb * ka >> 8, p = pic[o + x];
                        int r = (p >> 16) & 255, gg = (p >> 8) & 255, b = p & 255;
                        r = 255 - ((255 - r) * (255 - sr) >> 8); gg = 255 - ((255 - gg) * (255 - sg) >> 8); b = 255 - ((255 - b) * (255 - sb) >> 8);
                        pic[o + x] = (p & unchecked((int)0xFF000000)) | (r << 16) | (gg << 8) | b;
                    }
                });
                return;
            }
            // a GLOW, not a drawing: drawn at a fifth of the size and laid back up smoothed (the blur of an afterimage), with
            // only a faint thin trace of its lines over it -- a watermark, not a wireframe
            int sw = Math.Max(64, pw / GhostBlur), sh = Math.Max(40, vr / GhostBlur); float k = sw / (float)pw;
            using (var small = new Bitmap(sw, sh, PixelFormat.Format32bppPArgb))
            {
                using (var gs = Graphics.FromImage(small))
                {
                    gs.Clear(Color.Transparent); gs.SmoothingMode = SmoothingMode.AntiAlias;
                    _ghostCore = 0;
                    try { DrawChalice(gs, cx * k, cy * k, S * k, cupTop * k, cupH * k, Math.Min(1.0, a), 0, (float)(vr * GhostGlow) * k); } finally { _ghostCore = 1; }
                }
                Paint(pic, pw, ph, g =>
                {
                    g.SetClip(new RectangleF(0, 0, pw, vr));
                    g.InterpolationMode = InterpolationMode.HighQualityBilinear; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.DrawImage(small, new Rectangle(0, 0, pw, (int)Math.Round(sh / k)));
                    DrawChalice(g, cx, cy, S, cupTop, cupH, Math.Min(1.0, a * GhostTrace), 0, (float)(vr * GhostGlow * 0.12));
                });
            }
        }

        static void DrawRun(Graphics g, Pen pen, PointF[] pts, int a, int b)
        {
            var seg = new PointF[b - a + 1]; Array.Copy(pts, a, seg, 0, seg.Length);
            if (seg.Length >= 2) g.DrawLines(pen, seg);
        }
        void DrawHeart(int[] pic, int pw, int ph, int vr, long el, int ink)
        {
            int li = _banner.Length + 5; if (!HeartTrace || _lineItems == null || li >= _lineItems.Length) return;
            long from = HeartFrom; if (el < from || el >= U_mission) return;
            var it = _lineItems[li];
            float sc = (float)(_s * Zoom), x0 = it.X + it.W + (float)(HeartGap * sc), w = (float)(HeartW * sc);
            if (x0 + w > pw - 8) w = Math.Max(40, pw - 8 - x0);
            float yc = it.Y + it.H * 0.5f, hh = (float)(P_lineH * sc * 1.25);
            double ts = Math.Max(0, HeartSeconds(el)), beat = 60.0 / HeartBpm;      // (the heart keeps real time: see HeartSeconds)
            double appear = Math.Min(1, (el - from) / 250000.0);
            Paint(pic, pw, ph, g =>
            {
                g.SetClip(new RectangleF(x0 - 2, yc - hh - 2, w + 4, 2 * hh + 4));
                // the graticule: a few faint lines, the scope's own
                using (var grid = new Pen(Argb((int)(38 * appear), ink), 1))
                {
                    for (int k = 0; k <= 4; k++) { float yy = yc - hh + k * hh / 2; g.DrawLine(grid, x0, yy, x0 + w, yy); }
                    for (int k = 0; k <= 8; k++) { float xx = x0 + k * w / 8; g.DrawLine(grid, xx, yc - hh, xx, yc + hh); }
                }
                // the trace: from the head back over the sweep, the newest bright, fading toward the wipe gap ahead
                int n = Math.Max(40, (int)(w / 1.5f)); var pts = new PointF[n + 1];
                for (int k = 0; k <= n; k++)
                {
                    double back = k / (double)n * 0.94;                      // share of a sweep behind the head
                    double tx = ts - back * HeartSweep, xs = ((tx / HeartSweep) % 1.0 + 1.0) % 1.0;
                    double v = Ecg(((tx / beat) % 1.0 + 1.0) % 1.0);
                    pts[k] = new PointF(x0 + (float)(xs * w), yc + hh * 0.25f - (float)(v * hh * 1.05));
                }
                // drawn in short runs, each at one brightness, with one pen per pass re-coloured (a pen a segment cost 3 ms)
                const int Run = 6;
                for (int pass = 0; pass < 2; pass++)
                    using (var pen = new Pen(Color.Black, pass == 0 ? 5f * sc : 2.1f * sc))
                    {
                        pen.LineJoin = LineJoin.Round; pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                        for (int k0 = 0; k0 < n; k0 += Run)
                        {
                            int k1 = Math.Min(n, k0 + Run);
                            double age = (k0 + k1) * 0.5 / n;                                    // 0 = at the head
                            int a = (int)(255 * appear * Math.Pow(1 - age, 1.1) * (pass == 0 ? 0.30 : 1.0));
                            if (a < 4) continue;
                            pen.Color = Argb(a, pass == 0 ? VectorHalo : ink);
                            // (split where the trace wraps from the right edge back to the left)
                            int s0 = k0;
                            for (int k = k0; k < k1; k++)
                                if (pts[k + 1].X > pts[k].X + 1) { if (k > s0) DrawRun(g, pen, pts, s0, k); s0 = k + 1; }
                            if (k1 > s0) DrawRun(g, pen, pts, s0, k1);
                        }
                    }
                // the head: a bright spot with a glow
                var hp = pts[0]; float r1 = 2.4f * sc, r2 = 7f * sc;
                using (var gl = new SolidBrush(Argb((int)(90 * appear), VectorHalo))) g.FillEllipse(gl, hp.X - r2, hp.Y - r2, 2 * r2, 2 * r2);
                using (var core = new SolidBrush(Argb((int)(255 * appear), C_flare))) g.FillEllipse(core, hp.X - r1, hp.Y - r1, 2 * r1, 2 * r1);
            });
        }

        // ---- THE SOUND'S CUES: each beat the boot draws, as it is crossed ------------------------
        public BootSound Sound = new BootSound();
        long _sndEl = -1; bool _sndWeapons;
        /// <summary>The CRT's warm-up hum through the boot (1 = BootSound.HumLevel): it swells as the tube comes on, peaks
        /// while it warms, then settles to HumSettle until the shutter opens.</summary>
        public double HumSettle = 0.5;
        public double HumAt(long el)
        {
            double t = el / 1e6;
            if (t < 0.05) return 0;
            if (t < 0.7) { double u = (t - 0.05) / 0.65; return u * u * (3 - 2 * u); }
            if (t < 1.5) return 1;
            if (t < 3.5) return 1 - (1 - HumSettle) * (t - 1.5) / 2.0;
            return HumSettle;
        }
        void SoundBeats(long el)
        {
            var snd = Sound; long prev = _sndEl; _sndEl = el;
            if (snd == null || !snd.On || prev < 0 || el <= prev || el - prev > 500000) return;     // only beats crossed while running
            for (int k = 0; k < _banner.Length; k++)                                             // the 7s: a low tick each
            { long at = U_banner + k * U_banStep; if (prev < at && el >= at) snd.Line(100 + k, 0.16, 0.84); }
            for (int j = 0; j < _lines.Length; j++)                                              // each readout line: a burst
            { long at = U_text + j * U_line; if (prev < at && el >= at) snd.Line(200 + j, 0.34, 1.0); }
            if (prev < U_final && el >= U_final) snd.Typing(300, U_finType / 1e6, 1.0);          // the closing line typing out
            if (!_reboot)
            {
                // the briefing: a second degauss as it comes up, then each of its lines typing out in turn
                if (MissionDegauss > 0 && prev < U_mission && el >= U_mission) snd.DegaussSound(MissionDegauss);
                for (int i = 0; i < MisLine.Length; i++)
                { long at = U_mission + MisStartUs(i); if (prev < at && el >= at) snd.Typing(400 + i, MisLine[i], 0.92); }
            }
        }
        /// <summary>THE BRIEFING LINE BY LINE (Josh, 2026-10-07: "have that text appear in 2 lines, not all at once"): the
        /// MISSION lines (the icon with the first), then the OBJECTIVE -- each typing out in turn: seconds each, and the
        /// pause between. (It all typed at once, behind one edge, as the 8-bit boot draws it.)</summary>
        public double[] MisLine = { 0.5, 0.35, 0.75 }; public double MisGap = 0.1;
        long MisStartUs(int i) { double s = 0; for (int k = 0; k < i && k < MisLine.Length; k++) s += MisLine[k] + MisGap; return (long)(s * 1e6); }
        // THE HEART'S OWN CLOCK (Josh, 2026-10-07: the beeps "should be 125bpm"). Everything else in the boot follows the
        // game's clock; the heart follows the WALL clock from the moment its line arrives, so the trace and its beeps are
        // 125 beats a real minute whatever pace the game's boot clock keeps. HeartSeconds: how long the trace has run.
        double _heartT0 = -1, _sndHeart = -1; Stopwatch _wall = Stopwatch.StartNew();
        long HeartFrom { get { return U_text + 5 * U_line + 120000; } }
        double HeartSeconds(long el)
        {
            if (_heartT0 >= 0 && _mode == M_LIVE) return (_wall.Elapsed.TotalMilliseconds - _heartT0) / 1000.0;
            return (el - HeartFrom) / 1e6;            // (offline renders, and anything not live: the boot's own clock)
        }
        void HeartBeats(long el)
        {
            if (!HeartTrace || el < HeartFrom || el >= U_mission) { if (el < HeartFrom) { _heartT0 = -1; _sndHeart = -1; } return; }
            if (_heartT0 < 0) _heartT0 = _wall.Elapsed.TotalMilliseconds - (el - HeartFrom) / 1000.0;
            double hs = HeartSeconds(el), prev = _sndHeart; _sndHeart = hs;
            var snd = Sound; if (!HeartBeeps || snd == null || !snd.On || prev < 0 || hs <= prev) return;
            // a beep on each R spike of the trace, sent a little early for the sound device's queue
            double beat = 60.0 / HeartBpm, lead = 0.04;
            long k0 = Math.Max(0, (long)Math.Floor((prev + lead) / beat) - 1);
            for (long k = k0; k < k0 + 4; k++)
            {
                double at = (k + 0.325) * beat - lead;                       // (0.325: where the R spike sits in a beat, see Ecg)
                if (prev < at && hs >= at) snd.HeartBeep();
            }
        }
        /// <summary>The heart monitor's beep on each beat of the trace.</summary>
        public bool HeartBeeps = true;

        // =====================================================================================
        // THE LOOP: follows the guest's boot and shows it.
        // =====================================================================================
        const int M_DONE = 0, M_LIVE = 1, M_HOLD = 2, M_REVEAL = 3;
        volatile int _mode = M_DONE; bool _sawEnd = true; bool _reboot;
        readonly object _gate = new object(), _drawLock = new object();
        Stopwatch _revealClock = new Stopwatch(), _holdClock = new Stopwatch();
        Thread _th; volatile bool _run; IntPtr _proc;
        public long Frames, Boots; public double RenderMs; public long LastEl;
        readonly Queue<string> _notes = new Queue<string>();
        void Note(string s) { lock (_notes) { if (_notes.Count < 64) _notes.Enqueue(s); } }
        /// <summary>Next line for the log, or null.</summary>
        public string TakeNote() { lock (_notes) { return _notes.Count > 0 ? _notes.Dequeue() : null; } }
        /// <summary>True while the boot owns the screen (drawing, holding, or revealing).</summary>
        public bool Covering { get { return _mode != M_DONE; } }
        public bool Holding { get { return _mode == M_HOLD; } }
        /// <summary>This boot is a re-boot after a load (not a new game).</summary>
        public bool IsReboot { get { return _reboot; } }
        public string Mode { get { return _mode == M_LIVE ? "live" : _mode == M_HOLD ? "hold" : _mode == M_REVEAL ? "reveal" : "done"; } }

        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        /// <summary>Start following the guest. stateAddr = host address of aztBootState (T0 and El
        /// follow it at +12/+16), rebootAddr = aztReboot. The picture is pw x ph, the overlay's size.</summary>
        public void Start(int pid, Overlay ov, long stateAddr, long rebootAddr, int pw, int ph)
        {
            _pid = pid; _ov = ov; _aState = stateAddr; _aReboot = rebootAddr; PicW = pw; PicH = ph;
            ViewRows = ov != null ? ov.ViewRowsOf(ph) : ph;
            _proc = OpenProcess(0x0010 | 0x0020 | 0x0008 | 0x0400, false, pid);    // VM_READ | VM_WRITE | VM_OPERATION | QUERY_INFORMATION
            if (_proc == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
            if (ov != null) ov.Decorate = DecorateFrame;
            if (Sound != null && Sound.On) Sound.Prepare();          // (the degauss is ready before the boot starts)
            if (Sound != null && Sound.On && HudSoundPath != null && File.Exists(HudSoundPath)) _hudPcm = Sound.LoadStereoWav(HudSoundPath, HudSoundLevel);
            _run = true; _th = new Thread(Loop); _th.IsBackground = true; _th.Name = "AztBootHd"; _th.Start();
        }
        /// <summary>The watcher's 3D is on screen: open the shutter over it.</summary>
        public void Reveal() { Reveal(PicW, PicH); }
        /// <summary>...with the size of the pictures it will be laid over (the 3D's, which need not be the boot's).</summary>
        public void Reveal(int pw, int ph)
        {
            lock (_gate)
            {
                if (_mode != M_HOLD && _mode != M_LIVE) return;
                if (Covering4Load) { _mode = M_DONE; Note(string.Format("visor boot: a load -- the host's view is up after {0:N0} ms of cover: straight to the game, no boot-in", _holdClock.Elapsed.TotalMilliseconds)); return; }
                Note(string.Format("visor boot: the host's 3D is up after {0:N0} ms of hold -- opening the shutter over it", _holdClock.Elapsed.TotalMilliseconds));
                // the panels' picture, drawn now rather than on the first decorated frame
                try { lock (_drawLock) EnsureHeld(pw, ph, _ov != null ? _ov.ViewRowsOf(ph) : ph); } catch { }
                _revealClock.Restart(); _mode = M_REVEAL;
                // THE THIRD DEGAUSS (Josh, 2026-10-07): "when the mission/objective screen leaves and the fade begins ...
                // a red/blue degauss thunk and visual" -- the thunk now, the beams' swing on the reveal's frames (RevealDegauss)
                if (!_reboot && OpenDegauss > 0 && Sound != null && Sound.On) { try { Sound.DegaussSound(OpenDegauss); } catch { } }
            }
        }

        void Loop()
        {
            var clock = Stopwatch.StartNew(); var buf = new byte[20]; var rb = new byte[4]; IntPtr got;
            long lastGuestEl = -1; double lastChange = 0; long shown = 0; int[] pic = null; double lastDraw = 0;
            double frameMs = 1000.0 / Math.Max(10, Fps), next = 0;
            uint lastState = 99;
            while (_run)
            {
                double now = clock.Elapsed.TotalMilliseconds;
                if (now < next) { Thread.Sleep(Math.Max(1, (int)(next - now))); continue; }
                next = now + frameMs;
                uint state = 0, el = 0, t0 = 0;
                if (!ReadProcessMemory(_proc, new IntPtr(_aState), buf, new IntPtr(20), out got) || got.ToInt64() != 20)
                { if (_mode == M_LIVE || _mode == M_HOLD) { _mode = M_DONE; Note("visor boot: the game can no longer be read -- stopped"); } Thread.Sleep(50); continue; }
                state = BitConverter.ToUInt32(buf, 0); t0 = BitConverter.ToUInt32(buf, 12); el = BitConverter.ToUInt32(buf, 16);
                if (state != lastState) { lastState = state; }
                int mode = _mode;
                if (mode == M_DONE)
                {
                    // (a game already past its boot -- attached late -- must not keep the HUD held off)
                    // NOT BOOTING (the intro, gameplay, after a boot): watch for the next one and do nothing else. (This used
                    // to fall through to the frame below: it drew a boot frame every frame of the whole game only to throw
                    // it away, fired the HUD's power-up before any boot, and -- once the hum came in -- held the hum at its
                    // settled level through the intro and all of play. Josh, 2026-10-07: "the hum is continuing through
                    // the gameplay and sometimes in the intro videos".)
                    if (state != 1) { _sawEnd = true; if (state == 2 && Hud != null && Hud.HoldOff && !HudWait) ReleaseHud(); if (Sound != null) Sound.Hum(0); continue; }
                    else if (_sawEnd)
                    {
                        // A NEW BOOT (the first, or the short re-boot after a load).
                        _sawEnd = false; Boots++;
                        _reboot = _aReboot != 0 && ReadProcessMemory(_proc, new IntPtr(_aReboot), rb, new IntPtr(4), out got) && BitConverter.ToUInt32(rb, 0) != 0;
                        lastGuestEl = el; lastChange = now; shown = el; _lastTick = long.MinValue; _held = null; _ag = null; _hudOut = false; _hudHealth = false; _sndEl = el; _sndWeapons = false; _heartT0 = -1; _sndHeart = -1;
                        lock (_gate) _mode = M_LIVE;
                        Note(string.Format("visor boot: {0} at {1:N2} s -- drawn by the host at {2}x{3}", Covering4Load ? "a load: the last picture held under the loading panel (no boot visuals)" : _reboot ? "re-boot after a load" : "started", el / 1e6, PicW, PicH));
                        // the tube kicking in: the degauss's thunk, with the power-on (only when caught at its start)
                        if (!_reboot && Sound != null && Sound.On && el < 700000) { try { Sound.PowerOnSound(); } catch { } }
                        if (Sound != null) Sound.KeepOpen = false;       // (it was kept ready for this; the hum keeps it open now)
                    }
                    else { if (Sound != null) Sound.Hum(0); continue; }  // (a boot already handled -- e.g. given up on in the hold)
                }
                mode = _mode;
                if (mode == M_REVEAL) { if (state != 1) _sawEnd = true; if (Sound != null) Sound.Hum(0); continue; }     // (the hum dies away as the shutter opens)

                // the guest's clock, carried forward between its frames (and never backwards by a jitter)
                long elHost;
                if (mode == M_LIVE)
                {
                    if (state == 1 && el != (uint)lastGuestEl) { lastGuestEl = el; lastChange = now; }
                    elHost = lastGuestEl + (long)(Math.Min(150, now - lastChange) * 1000);
                    if (elHost < shown) elHost = shown;
                    shown = elHost;
                    if (state != 1 || elHost >= U_open)
                    {
                        // THE SHUTTER BEAT: hold here until the host's 3D is up.
                        lock (_gate) { if (_mode == M_LIVE) _mode = M_HOLD; }
                        ReleaseHud();
                        _holdClock.Restart();
                        if (FastForward && state == 1 && el < U_hold)
                        {
                            uint wind = (uint)(U_hold - el + 60000);
                            var nb = BitConverter.GetBytes(t0 - wind);
                            IntPtr wr; WriteProcessMemory(_proc, new IntPtr(_aState + 12), nb, new IntPtr(4), out wr);
                            Note(string.Format("visor boot: shutter beat at {0:N2} s -- the game's boot wound on {1:N2} s to its end so the host can take over", elHost / 1e6, wind / 1e6));
                        }
                        else Note(string.Format("visor boot: shutter beat at {0:N2} s (the game's boot state {1}) -- holding for the host's 3D", elHost / 1e6, state));
                    }
                }
                else elHost = U_open - 1;
                HudBeats(elHost);
                if (mode == M_LIVE && !Covering4Load) { SoundBeats(elHost); HeartBeats(elHost); }
                if (Sound != null) Sound.Hum(Covering4Load ? 0 : mode == M_LIVE ? HumAt(elHost) : HumSettle);
                bool busyWait = HoldWhileBusy && _holdClock.ElapsedMilliseconds < HoldBusyMaxMs;
                if (_mode == M_HOLD && _holdClock.ElapsedMilliseconds > HoldMaxMs && Stopwatch.GetTimestamp() > Interlocked.Read(ref HoldExtendUntil) && !busyWait)
                {
                    lock (_gate) { if (_mode == M_HOLD) _mode = M_DONE; }
                    ReleaseHud();
                    Note(string.Format("visor boot: no host 3D after {0:N0} ms of hold -- getting out of the way", _holdClock.ElapsedMilliseconds));
                    continue;
                }
                if (_mode == M_HOLD && busyWait && !_busyNoted && _holdClock.ElapsedMilliseconds > HoldMaxMs) { _busyNoted = true; Note("visor boot: holding past " + HoldMaxMs + " ms -- the renderer is still preparing the room (" + BusyText + ")"); }
                LastEl = elHost;

                // draw and show
                int pw = PicW, ph = PicH, vr = ViewRows;
                if (pw < 16 || ph < 16) continue;
                if (pic == null || pic.Length != pw * ph) pic = new int[pw * ph];
                var sw = Stopwatch.StartNew();
                bool hold = _mode == M_HOLD;
                long sweepEl = hold ? (U_open - 1) + (long)(_holdClock.Elapsed.TotalMilliseconds * 1000) : elHost;
                double dtMs = lastDraw > 0 ? now - lastDraw : 0; lastDraw = now;
                if (Covering4Load)
                {
                    // the load's cover: the last game picture as it was (or black), the loading panel laid over it on the way out
                    var lh = LoadHeld;
                    if (lh != null && LoadHeldW == pw && LoadHeldH == ph && lh.Length == pic.Length) Buffer.BlockCopy(lh, 0, pic, 0, pic.Length * 4);
                    else Array.Clear(pic, 0, pic.Length);
                }
                else
                {
                    try { lock (_drawLock) { RenderAt(pic, pw, ph, vr, hold ? U_open - 1 : elHost, sweepEl, _reboot, true, dtMs); if (hold && HoldWhileBusy && _holdClock.ElapsedMilliseconds > 1500) DrawBusy(pic, pw, ph, vr); } }
                    catch (Exception e) { lock (_gate) _mode = M_DONE; ReleaseHud(); Note("visor boot: drawing failed: " + e.Message); continue; }
                }
                RenderMs = RenderMs * 0.9 + sw.Elapsed.TotalMilliseconds * 0.1;
                lock (_gate)
                {
                    if (_mode != M_LIVE && _mode != M_HOLD) continue;
                    try { if (_ov != null) pic = _ov.ShowComposed(pic, pw, ph); Frames++; }
                    catch (Exception e) { _mode = M_DONE; Note("visor boot: the overlay refused the picture: " + e.Message); }
                }
            }
        }

        bool _busyNoted;
        // the held briefing's status line while the renderer prepares the room: typed in the boot's ink, a caret blinking after it
        void DrawBusy(int[] pic, int pw, int ph, int vr)
        {
            string s = BusyText; if (string.IsNullOrEmpty(s)) return;
            double t = _holdClock.Elapsed.TotalSeconds; int n = Math.Min(s.Length, (int)((t - 1.5) * 30)); if (n <= 0) return;
            string shown = s.Substring(0, n) + ((((int)(t * 2.5)) & 1) == 0 ? "_" : " ");
            Paint(pic, pw, ph, g =>
            {
                float sc = (float)(_s * Zoom);
                using (var font = new Font("Consolas", 16f * sc, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var fmt = Fmt())
                using (var br = new SolidBrush(Argb(230, C_text)))
                {
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    var sz = g.MeasureString(s + "_", font, PointF.Empty, fmt);
                    g.DrawString(shown, font, br, (pw - sz.Width) / 2f, vr * 0.80f, fmt);
                }
            });
        }

        public void Dispose()
        {
            _run = false; _mode = M_DONE; ReleaseHud();
            if (_th != null) { try { _th.Join(500); } catch { } _th = null; }
            if (_ov != null) { try { if (_ov.Decorate == (Func<int[], int, int, bool>)DecorateFrame) _ov.Decorate = null; } catch { } }
            if (_proc != IntPtr.Zero) { CloseHandle(_proc); _proc = IntPtr.Zero; }
            if (Sound != null) { try { Sound.Hum(0); Sound.Dispose(); } catch { } }
        }
    }
    // =========================================================================================
    // THE BOOT'S SOUND (Josh, 2026-10-07: "digital sounds, not typing -- almost like a dull morse code sound as
    // the lines type out"). Short soft blips, dits and dahs on two close pitches, generated here: a rounded
    // square wave run through a low-pass so it is dull rather than bright, each blip with a soft attack and
    // release so nothing clicks. A line landing gets a short burst; text typing out gets a running pattern
    // for exactly as long as it types. Played through Windows on the host, under the game's own boot sound.
    // =========================================================================================
    public class BootSound
    {
        public bool On = true;
        /// <summary>Peak level, 0..1 of full scale. Kept well under the CD boot effect.</summary>
        public double Volume = 0.36;
        /// <summary>The two pitches the blips alternate between (Hz), and how dull they are (low-pass, Hz).
        /// Low and moody (Josh, 2026-10-07: 560/640 was "a bit too high pitch"). A pitch this low is mostly
        /// below what laptop and TV speakers can play, so what is HEARD is its harmonics: the first low version
        /// (dull 900, soft square) MEASURED 6 dB quieter A-weighted than the old cues and 14.5 dB quieter with
        /// the bass under 250 Hz removed -- it vanished ("the typing sounds have been removed"). So the wave is
        /// squarer (Shape 6) and the low-pass opened to 2.6 kHz: the ear still hears 150 Hz (the harmonics imply
        /// it), at the old cues' loudness on any speaker (scratchpad snd-loud.ps1).</summary>
        public double PitchLo = 150, PitchHi = 172, Dull = 2600;
        public double Dit = 0.045, Dah = 0.11, Gap = 0.036;
        /// <summary>How square the wave is (tanh drive): more = more harmonics above the pitch.</summary>
        public double Shape = 6;
        const int Rate = 44100;            // (was 22050; the mixer's rate since the hum came in -- everything is timed in seconds, so the cues sound the same)
        long _played;
        public long Played { get { return Interlocked.Read(ref _played); } }

        /// <summary>A short burst as a line lands (about `seconds` long).</summary>
        public void Line(int seed, double seconds, double pitchScale) { Play(Pattern(seed, seconds, 0.45, pitchScale)); }
        /// <summary>A running pattern for text typing out over `seconds`.</summary>
        public void Typing(int seed, double seconds, double pitchScale) { Play(Pattern(seed, seconds, 0.8, pitchScale)); }

        // ---- DATA STYLE (Josh, 2026-10-07: "more like a processor sound chipping out data. Less bleepy/bloopy and
        // more digital noise, and a little static"). Not tones: PACKETS of bits. Each chirp clocks out values held for
        // a few samples (sample-and-hold, so it is grainy and digital, not smooth hiss) -- half of them a short word
        // repeated (a buzzy, almost-pitched data whine), the rest random bits at random levels (crunch). Packets come
        // in short uneven bursts with short gaps, over a faint hiss with the odd crackle, through a gentle low-pass.
        /// <summary>True: the data chatter. False: the earlier low tone blips.</summary>
        public bool Data = true;
        /// <summary>How fast a chirp's bits change (Hz): the grain of the chatter. Lower = coarser, moodier.</summary>
        public double BitLo = 700, BitHi = 2800;
        /// <summary>The hiss under it (share of the chatter's level), and crackle pops per second.</summary>
        public double Static = 0.09, Crackle = 24;
        /// <summary>Seconds: short chirps, longer bursts, and the gap between packets.</summary>
        public double ChirpLo = 0.006, ChirpHi = 0.028, BurstLo = 0.04, BurstHi = 0.09, ChirpGap = 0.012;
        /// <summary>The data style's low-pass (Hz), and its level against the tone style's at the same Volume
        /// (0.76 MEASURED to land the typing cue at the tone cues' A-weighted loudness: snd-loud.ps1).</summary>
        public double DataDull = 3600, DataGain = 0.42;      // (0.76 -> 0.42, about -5 dB: Josh, 2026-10-07, "the digital typing ... feels a bit loud compared to the rest of the game")

        short[] Pattern(int seed, double seconds, double ditShare, double pitchScale)
        {
            return Data ? DataPattern(seed, seconds, ditShare, pitchScale) : TonePattern(seed, seconds, ditShare, pitchScale);
        }
        short[] DataPattern(int seed, double seconds, double chirpShare, double pitchScale)
        {
            var rnd = new Random(seed);
            int total = (int)(seconds * Rate) + Rate / 20; var buf = new double[total];
            double t = 0.008;
            while (t < seconds)
            {
                double dur = rnd.NextDouble() < chirpShare ? ChirpLo + (ChirpHi - ChirpLo) * rnd.NextDouble() : BurstLo + (BurstHi - BurstLo) * rnd.NextDouble();
                if (t + dur > seconds) dur = Math.Max(ChirpLo, seconds - t);
                int hold = Math.Max(1, (int)(Rate / ((BitLo + (BitHi - BitLo) * rnd.NextDouble()) * pitchScale)));
                bool word = rnd.NextDouble() < 0.5; int wl = 5 + rnd.Next(10); var bits = new double[wl];
                for (int b = 0; b < wl; b++) bits[b] = rnd.NextDouble() < 0.5 ? -1 : 1;
                double lvl = 0.55 + 0.45 * rnd.NextDouble(), v = 0;
                int s0 = (int)(t * Rate), n = (int)(dur * Rate), att = Rate / 1000, rel = Rate * 3 / 1000, k = 0;
                for (int i = 0; i < n && s0 + i < total; i++)
                {
                    if (i % hold == 0) v = word ? bits[k++ % wl] : (rnd.NextDouble() < 0.5 ? -1 : 1) * (0.4 + 0.6 * rnd.NextDouble());
                    double env = Math.Min(1, Math.Min(i / (double)att, (n - i) / (double)rel));
                    buf[s0 + i] += v * lvl * env;
                }
                // packets: short, uneven gaps, now and then a longer pause
                t += dur + ChirpGap * (0.3 + 1.7 * rnd.NextDouble()) * (rnd.NextDouble() < 0.15 ? 3 : 1);
            }
            // the static: faint hiss the whole length of the cue (faded at its ends) and sparse crackle
            int edge = Rate / 100; double crackP = Crackle / Rate, pop = 0;
            for (int i = 0; i < total; i++)
            {
                double e = Math.Min(1, Math.Min(i / (double)edge, (total - i) / (double)edge));
                if (rnd.NextDouble() < crackP) pop = (rnd.NextDouble() < 0.5 ? -1 : 1) * (0.3 + 0.5 * rnd.NextDouble());
                buf[i] += (Static * (rnd.NextDouble() * 2 - 1) + pop) * e;
                pop *= 0.8;                                         // each pop gone in a millisecond or so
            }
            double a = 1 - Math.Exp(-2 * Math.PI * DataDull / Rate), lp = 0, peak = 1e-9;
            for (int i = 0; i < total; i++) { lp += a * (buf[i] - lp); buf[i] = lp; peak = Math.Max(peak, Math.Abs(lp)); }
            var pcm = new short[total]; double g = Math.Min(0.98, Volume * DataGain) / peak * 32767;
            for (int i = 0; i < total; i++) pcm[i] = (short)Math.Max(-32767, Math.Min(32767, buf[i] * g));
            return pcm;
        }
        short[] TonePattern(int seed, double seconds, double ditShare, double pitchScale)
        {
            var rnd = new Random(seed);
            int total = (int)(seconds * Rate) + Rate / 20; var pcm = new short[total];
            double t = 0.01, lp = 0, a = 1 - Math.Exp(-2 * Math.PI * Dull / Rate);
            var buf = new double[total];
            while (t < seconds)
            {
                double dur = rnd.NextDouble() < ditShare ? Dit : Dah;
                if (t + dur > seconds) dur = Math.Max(Dit * 0.7, seconds - t);
                double f = (rnd.NextDouble() < 0.5 ? PitchLo : PitchHi) * pitchScale;
                int s0 = (int)(t * Rate), n = (int)(dur * Rate), att = Rate * 3 / 1000, rel = Rate * 12 / 1000;
                for (int i = 0; i < n && s0 + i < total; i++)
                {
                    double env = Math.Min(1, Math.Min(i / (double)att, (n - i) / (double)rel));
                    double w = Math.Tanh(Shape * Math.Sin(2 * Math.PI * f * i / Rate)) / Math.Tanh(Shape);     // a rounded square
                    buf[s0 + i] = w * env;
                }
                t += dur + Gap * (0.8 + 0.5 * rnd.NextDouble());
            }
            for (int i = 0; i < total; i++)
            {   // two one-pole low-passes: dull, not shrill
                lp += a * (buf[i] - lp); buf[i] = lp;
            }
            lp = 0; double peak = 1e-9;
            for (int i = 0; i < total; i++) { lp += a * (buf[i] - lp); buf[i] = lp; peak = Math.Max(peak, Math.Abs(lp)); }
            double k = Volume / peak * 32767;
            for (int i = 0; i < total; i++) pcm[i] = (short)Math.Max(-32767, Math.Min(32767, buf[i] * k));
            return pcm;
        }
        /// <summary>Write a cue to a .wav file instead of playing it (for listening offline).</summary>
        public void SaveWav(string path, int seed, double seconds, bool typing, double pitchScale)
        {
            using (var ms = Wav(Pattern(seed, seconds, typing ? 0.8 : 0.45, pitchScale))) File.WriteAllBytes(path, ms.ToArray());
        }
        void Play(short[] pcm)
        {
            if (!On || Volume <= 0) return;
            Interlocked.Increment(ref _played);
            // through the mixer, so cues overlap and sit over the hum (opened off this thread -- it takes ~0.5 s the
            // first time, and this is the boot's drawing thread -- with cues held until it is up); if the sound device
            // cannot be opened that way, through Windows as before (one sound at a time per process)
            lock (_mixLock)
            {
                if (_mixer != null && !_mixer.Closed) { _mixer.Add(pcm, false); return; }
                if (!_mixFailed) { _pending.Add(new Clip { P = pcm }); OpenMixerAsync(); return; }
            }
            PlayFallback(pcm);
        }
        // ---- STEREO CLIPS (Josh's own sounds, 2026-10-07: the HUD's ratchet as it slides in) -------------------------
        // Through the same mixer -- which is stereo now; the boot's own cues and the hum go to both sides as they always did.
        /// <summary>Play an interleaved stereo clip (16-bit, at the engine's rate) -- already at the level it should play.</summary>
        public void PlayStereo(short[] interleaved)
        {
            if (!On || Volume <= 0 || interleaved == null) return;
            Interlocked.Increment(ref _played);
            lock (_mixLock)
            {
                if (_mixer != null && !_mixer.Closed) { _mixer.Add(interleaved, true); return; }
                if (!_mixFailed) { _pending.Add(new Clip { P = interleaved, St = true }); OpenMixerAsync(); return; }
            }
        }
        /// <summary>A WAV (16-bit PCM, mono or stereo, any rate) as an interleaved stereo clip at the engine's rate, scaled by
        /// `gain` and by Volume (against its default, as the boot's own sounds are). Null if it cannot be read.</summary>
        public short[] LoadStereoWav(string path, double gain)
        {
            try
            {
                var b = File.ReadAllBytes(path); int p = 12, ch = 2, rate = Rate, bits = 16, data = -1, len = 0;
                while (p + 8 <= b.Length)
                {
                    string id = System.Text.Encoding.ASCII.GetString(b, p, 4); int sz = BitConverter.ToInt32(b, p + 4);
                    if (id == "fmt ") { ch = BitConverter.ToInt16(b, p + 10); rate = BitConverter.ToInt32(b, p + 12); bits = BitConverter.ToInt16(b, p + 22); }
                    if (id == "data") { data = p + 8; len = Math.Min(sz, b.Length - data); break; }
                    p += 8 + sz + (sz & 1);
                }
                if (data < 0 || bits != 16) return null;
                double k = gain * Volume / 0.36; int n = len / 2 / ch, m = (int)((long)n * Rate / rate); var o = new short[m * 2];
                for (int i = 0; i < m; i++)
                {
                    int s = Math.Min(n - 1, (int)((long)i * rate / Rate));
                    double l = BitConverter.ToInt16(b, data + s * ch * 2), r = ch > 1 ? BitConverter.ToInt16(b, data + (s * ch + 1) * 2) : l;
                    o[i * 2] = (short)Math.Max(-32767, Math.Min(32767, l * k)); o[i * 2 + 1] = (short)Math.Max(-32767, Math.Min(32767, r * k));
                }
                return o;
            }
            catch { return null; }
        }
        sealed class Clip { public short[] P; public bool St; }
        void PlayFallback(short[] pcm)
        {
            var ms = Wav(pcm);
            ThreadPool.QueueUserWorkItem(_ => { try { using (ms) using (var sp = new System.Media.SoundPlayer(ms)) sp.PlaySync(); } catch { } });
        }

        // ---- THE TUBE'S OWN SOUNDS (Josh, 2026-10-07: "a degauss thunk ... to indicate it's kicking in", and "the warm
        // up hum common with CRTs"). The DEGAUSS: the relay's click, a low thump, and the coil's buzz -- mains harmonics,
        // wobbling as its field collapses -- dying over about a second, with static crackling off the glass. The HUM: a
        // transformer's 120 Hz and its overtones with a little rectified buzz, under everything; the boot sets its level
        // (swelling as the tube comes on, settling, gone when the shutter opens) and it eases to it, never jumps.
        /// <summary>The degauss's peak level and the hum's (both scaled with Volume, so -BootSoundVolume moves all of it).</summary>
        public double DegaussLevel = 0.9, HumLevel = 0.6;
        // (MEASURED, A-weighted against the typing cue's -10.1 dB: the degauss ~ -13 dB -- the thump is felt more than
        // heard. THE HUM: 0.085 measured -30.5 at its peak, 0.22 -19.4 / -24.6 settled -- Josh: "I can't hear the warm up
        // hum". Now 0.6 with more overtones: -10.7 at its peak (level with the cues), -15.9 settled. Peak sample 0.77, so
        // the mixer's soft limiter rounds off the degauss over it.)
        short[] _degauss;
        public void PowerOnSound() { if (_degauss == null) _degauss = DegaussPcm(); Play(_degauss); }
        /// <summary>The degauss again, at this share of its level (the mission's).</summary>
        public void DegaussSound(double share)
        {
            if (_degauss == null) _degauss = DegaussPcm();
            if (_degaussSoft == null || _softShare != share)
            {
                var p = new short[_degauss.Length]; for (int i = 0; i < p.Length; i++) p[i] = (short)(_degauss[i] * share);
                _degaussSoft = p; _softShare = share;
            }
            Play(_degaussSoft);
        }
        short[] _degaussSoft; double _softShare;
        // THE HEART MONITOR'S BEEP (Josh, 2026-10-07: "heart rate beeps ... for fun, like an ekg or heart rate monitor"):
        // the bedside monitor's short clean tone on each beat -- a sine with a touch of its octave, soft at both ends.
        /// <summary>The beep's pitch (Hz), length (s) and level (scaled with Volume).</summary>
        public double BeepHz = 920, BeepSeconds = 0.085, BeepLevel = 0.18;    // 0.18: MEASURED -18.7 dBFS while it sounds, 1.4 dB under the chirps (0.30 was 3 dB over)
        short[] _beep;
        public void HeartBeep() { if (_beep == null) _beep = BeepPcm(); Play(_beep); }
        short[] BeepPcm()
        {
            int n = (int)((BeepSeconds + 0.08) * Rate); var buf = new double[n];
            for (int i = 0; i < n; i++)
            {
                double t = i / (double)Rate, env = Math.Min(1, t / 0.004) * (t < BeepSeconds ? 1 : Math.Exp(-(t - BeepSeconds) / 0.016));
                buf[i] = (Math.Sin(2 * Math.PI * BeepHz * t) + 0.18 * Math.Sin(2 * Math.PI * 2 * BeepHz * t + 0.3)) * env;
            }
            return Finish(buf, BeepLevel, 7000, 0.01);
        }
        public short[] BeepClip() { return BeepPcm(); }
        /// <summary>THE ECHO SCAN'S PING (Josh, 2026-10-14): a sonar ping -- a bright tone sliding a little down, ringing away,
        /// with a fainter echo of itself a third of a second later.</summary>
        public void SonarPing()
        {
            if (_ping == null)
            {
                int n = (int)(1.6 * Rate); var buf = new double[n];
                for (int i = 0; i < n; i++)
                {
                    double t = i / (double)Rate, v = 0;
                    foreach (var echo in new[] { new[] { 0.0, 1.0 }, new[] { 0.34, 0.32 }, new[] { 0.68, 0.1 } })
                    {
                        double u = t - echo[0]; if (u < 0) continue;
                        double f = 1180 + 260 * Math.Exp(-u / 0.05), env = Math.Min(1, u / 0.003) * Math.Exp(-u / 0.32);
                        double ph = 2 * Math.PI * (1180 * u - 260 * 0.05 * (Math.Exp(-u / 0.05) - 1));
                        v += echo[1] * env * (Math.Sin(ph) + 0.25 * Math.Sin(2 * ph + 0.4));
                    }
                    buf[i] = v;
                }
                _ping = Finish(buf, BeepLevel * 0.9, 6000, 0.05);
            }
            Play(_ping);
        }
        short[] _ping;
        /// <summary>THE FLAT LINE (Josh, 2026-10-10: the heart "slowly flat line" on death): the monitor's tone held for
        /// `seconds`, fading away over its last 1.2 s.</summary>
        public void Flatline(double seconds)
        {
            int n = (int)((seconds + 0.1) * Rate); var buf = new double[n];
            for (int i = 0; i < n; i++)
            {
                double t = i / (double)Rate, env = Math.Min(1, t / 0.006) * (t < seconds - 1.2 ? 1 : Math.Max(0, (seconds - t) / 1.2));
                buf[i] = (Math.Sin(2 * Math.PI * BeepHz * t) + 0.18 * Math.Sin(2 * Math.PI * 2 * BeepHz * t + 0.3)) * env;
            }
            Play(Finish(buf, BeepLevel * 0.8, 7000, 0.05));
        }
        /// <summary>Get ready for the power-on, off the caller's thread: make the degauss (a few hundred ms of work) and
        /// open the sound device (another ~0.5 s the first time) and keep it open, silent, until KeepOpen is cleared --
        /// or the thunk would land half a second after the dot it belongs to.</summary>
        public void Prepare()
        {
            if (!On || Volume <= 0) return;
            if (_degauss == null) ThreadPool.QueueUserWorkItem(_ => { try { var p = DegaussPcm(); if (_degauss == null) _degauss = p; var q = BeepPcm(); if (_beep == null) _beep = q; } catch { } });
            KeepOpen = true;
            lock (_mixLock) { if ((_mixer == null || _mixer.Closed) && !_mixFailed) OpenMixerAsync(); }
        }
        /// <summary>Open the sound device now and keep it open while silent (the footsteps: a step must not wait half a second).</summary>
        public void Warm()
        {
            if (!On || Volume <= 0) return;
            KeepOpen = true;
            lock (_mixLock) { if ((_mixer == null || _mixer.Closed) && !_mixFailed) OpenMixerAsync(); }
        }
        /// <summary>Keep the sound device open while silent (set by Prepare, cleared when the boot has begun).</summary>
        public volatile bool KeepOpen;
        short[] DegaussPcm()
        {
            int n = (int)(1.7 * Rate); var buf = new double[n]; var rnd = new Random(1977);
            double crackle = 0;
            for (int i = 0; i < n; i++)
            {
                double t = i / (double)Rate, s = 0;
                if (t < 0.004) s += (rnd.NextDouble() * 2 - 1) * 0.9 * (1 - t / 0.004);                         // the relay
                if (t > 0.004) { double u = t - 0.004; s += 0.9 * Math.Sin(2 * Math.PI * 52 * u) * Math.Exp(-u / 0.07); }   // the thump
                if (t > 0.02)
                {   // the coil: 60 Hz and its harmonics, swelling in and dying away, wobbling as the field collapses
                    double u = t - 0.02, env = Math.Min(1, u / 0.03) * Math.Exp(-u / 0.42) * (1 + 0.3 * Math.Sin(2 * Math.PI * 6.2 * u));
                    double c = 0; for (int k = 1; k <= 14; k++) c += Math.Sin(2 * Math.PI * 60 * k * u + k * 0.7) / Math.Pow(k, 0.75);
                    s += 0.75 * c * env;
                }
                // static off the glass: pops, thinning out
                if (rnd.NextDouble() < 45.0 / Rate * Math.Exp(-t / 0.6)) crackle = (rnd.NextDouble() < 0.5 ? -1 : 1) * (0.25 + 0.5 * rnd.NextDouble());
                s += crackle; crackle *= 0.86;
                buf[i] = s;
            }
            return Finish(buf, DegaussLevel, 2600, 0.03);
        }
        // a buffer to 16-bit: low-passed (Hz), faded out over `tail` seconds, peak at `level` x Volume
        short[] Finish(double[] buf, double level, double lowPass, double tail)
        {
            int n = buf.Length; double a = 1 - Math.Exp(-2 * Math.PI * lowPass / Rate), lp = 0, peak = 1e-9; int tn = (int)(tail * Rate);
            for (int i = 0; i < n; i++) { lp += a * (buf[i] - lp); buf[i] = lp * Math.Min(1, (n - i) / (double)Math.Max(1, tn)); peak = Math.Max(peak, Math.Abs(buf[i])); }
            double k = Math.Min(0.98, level * Volume / 0.36) / peak * 32767; var pcm = new short[n];
            for (int i = 0; i < n; i++) pcm[i] = (short)Math.Max(-32767, Math.Min(32767, buf[i] * k));
            return pcm;
        }
        volatile float _humTarget; double _humNow, _humT;
        /// <summary>The hum's level, 0..1 (1 = HumLevel): the mixer eases to it.</summary>
        public void Hum(double level)
        {
            if (!On || Volume <= 0) level = 0;
            _humTarget = (float)Math.Max(0, level);
            if (level > 0) lock (_mixLock) { if ((_mixer == null || _mixer.Closed) && !_mixFailed) OpenMixerAsync(); }
        }
        // the hum, added into the mixer's buffer; true while it is sounding
        bool HumInto(float[] mix)
        {
            float target = _humTarget; if (target <= 0 && _humNow < 2e-3) { _humNow = 0; return KeepOpen; }     // (inaudible: done, unless kept ready)
            double dt = 1.0 / Rate, up = 1 - Math.Exp(-dt / 0.35), down = 1 - Math.Exp(-dt / 0.6), k = HumLevel * Volume / 0.36;
            for (int i = 0; i < mix.Length; i++)
            {
                _humNow += (target - _humNow) * (target > _humNow ? up : down);
                _humT += dt; double w = 2 * Math.PI * 60 * _humT;
                // (more of the overtones than a pure transformer hum has: 120 Hz alone is below what small speakers play,
                // and Josh could not hear the first, purer version at all)
                double h = 0.50 * Math.Sin(2 * w) + 0.34 * Math.Sin(3 * w + 0.7) + 0.30 * Math.Sin(4 * w + 1.3) + 0.22 * Math.Sin(6 * w + 0.2)
                         + 0.16 * Math.Sin(8 * w + 2.1) + 0.10 * Math.Sin(10 * w + 0.9) + 0.07 * Math.Sin(12 * w + 1.7);
                double sw = Math.Sin(w), buzz = sw * sw; buzz *= buzz; buzz *= buzz;                    // |sin|^8: a soft rectified buzz
                h = h * (0.85 + 0.15 * Math.Sin(2 * Math.PI * 0.37 * _humT)) + 0.8 * (buzz - 0.27);
                mix[i] += (float)(h * _humNow * k);
            }
            if (_humT > 3600) _humT -= 3600;          // (keeps the phase precise; 60 Hz x 3600 s is whole cycles)
            return true;
        }
        /// <summary>For listening offline: the degauss, and the hum's warm-up (swell, settle) over `seconds`.</summary>
        public void SaveDegauss(string path) { using (var ms = Wav(DegaussPcm())) File.WriteAllBytes(path, ms.ToArray()); }
        public void SaveHum(string path, double seconds, Func<double, double> levelAt) { SavePcm(path, HumPcm(seconds, levelAt)); }
        /// <summary>Offline: the hum over `seconds` with its level from `levelAt` (s -> 0..1), as the mixer would play it.</summary>
        public float[] HumPcm(double seconds, Func<double, double> levelAt)
        {
            int n = (int)(seconds * Rate), blk = 1024; var all = new float[n]; var mix = new float[blk]; _humNow = 0; _humT = 0;
            for (int o = 0; o < n; o += blk) { Array.Clear(mix, 0, blk); _humTarget = (float)levelAt(o / (double)Rate); HumInto(mix); Array.Copy(mix, 0, all, o, Math.Min(blk, n - o)); }
            _humNow = 0; _humTarget = 0;
            return all;
        }
        /// <summary>Offline: a cue's samples (as Line / Typing play them), and the degauss's.</summary>
        public short[] CuePcm(int seed, double seconds, bool typing, double pitchScale) { return Pattern(seed, seconds, typing ? 0.8 : 0.45, pitchScale); }
        public short[] DegaussClip() { return DegaussPcm(); }
        public static int SampleRate { get { return Rate; } }
        public static void SavePcm(string path, float[] mix)
        {
            var pcm = new short[mix.Length]; for (int i = 0; i < mix.Length; i++) pcm[i] = (short)Math.Max(-32767, Math.Min(32767, mix[i] * 32767));
            using (var ms = Wav(pcm)) File.WriteAllBytes(path, ms.ToArray());
        }

        Mixer _mixer; readonly object _mixLock = new object(); readonly List<Clip> _pending = new List<Clip>();
        bool _mixFailed, _opening, _disposed;
        // (call under _mixLock) open the device on a pool thread; cues that arrive meanwhile wait in _pending
        void OpenMixerAsync()
        {
            if (_opening || _disposed) return;
            _opening = true;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                Mixer m = null;
                try { m = Mixer.Open(Rate, HumInto); } catch { m = null; }
                short[] last = null;
                lock (_mixLock)
                {
                    _opening = false;
                    if (_mixer != null) { _mixer.Dispose(); _mixer = null; }
                    if (m == null) { _mixFailed = true; for (int q = _pending.Count - 1; q >= 0; q--) if (!_pending[q].St) { last = _pending[q].P; break; } _pending.Clear(); }
                    else if (_disposed) { m.Dispose(); _pending.Clear(); }
                    else { _mixer = m; foreach (var p in _pending) m.Add(p.P, p.St); _pending.Clear(); }
                }
                if (last != null) PlayFallback(last);
            });
        }
        public void Dispose() { lock (_mixLock) { _disposed = true; _pending.Clear(); if (_mixer != null) { _mixer.Dispose(); _mixer = null; } } }

        // A SMALL MIXER on the sound device (winmm waveOut): four short buffers kept queued, each filled with the bed
        // (the hum) plus every cue still playing. Closes itself after a few seconds of silence, opened again on demand.
        sealed class Mixer : IDisposable
        {
            [StructLayout(LayoutKind.Sequential)] struct WaveFmt { public ushort Tag, Channels; public uint Rate, Bytes; public ushort Align, Bits, Extra; }
            [StructLayout(LayoutKind.Sequential)] struct WaveHdr { public IntPtr Data; public uint Length, Recorded; public IntPtr User; public uint Flags, Loops; public IntPtr Next, Reserved; }
            [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr h, uint dev, ref WaveFmt fmt, IntPtr cb, IntPtr inst, uint flags);
            [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
            [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
            [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
            [DllImport("winmm.dll")] static extern int waveOutReset(IntPtr h);
            [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr h);
            const int NBuf = 4, Frames = 512; const uint WHDR_DONE = 1;       // ~46 ms queued: the heart beeps keep to the trace
            IntPtr _h; readonly IntPtr[] _hdr = new IntPtr[NBuf], _buf = new IntPtr[NBuf]; readonly bool[] _queued = new bool[NBuf];
            int _hdrSize, _flagsAt; Thread _th; volatile bool _run; Func<float[], bool> _bed;
            class Voice { public short[] P; public int Pos; public bool St; }
            readonly List<Voice> _voices = new List<Voice>();
            public volatile bool Closed;
            public static Mixer Open(int rate, Func<float[], bool> bed)
            {
                var m = new Mixer(); m._bed = bed;
                var f = new WaveFmt { Tag = 1, Channels = 2, Rate = (uint)rate, Bits = 16, Align = 4, Bytes = (uint)rate * 4 };      // (stereo: Josh's own clips are)
                if (waveOutOpen(out m._h, 0xFFFFFFFF, ref f, IntPtr.Zero, IntPtr.Zero, 0) != 0) return null;
                m._hdrSize = Marshal.SizeOf(typeof(WaveHdr)); m._flagsAt = (int)Marshal.OffsetOf(typeof(WaveHdr), "Flags");
                for (int i = 0; i < NBuf; i++) { m._buf[i] = Marshal.AllocHGlobal(Frames * 4); m._hdr[i] = Marshal.AllocHGlobal(m._hdrSize); }
                m._run = true; m._th = new Thread(m.Loop); m._th.IsBackground = true; m._th.Name = "AztBootSound"; m._th.Priority = ThreadPriority.AboveNormal; m._th.Start();
                return m;
            }
            /// <summary>A cue: mono (to both sides) or interleaved stereo.</summary>
            public void Add(short[] pcm, bool stereo) { lock (_voices) _voices.Add(new Voice { P = pcm, St = stereo }); }
            void Loop()
            {
                var mono = new float[Frames]; var mix = new float[Frames * 2]; var pcm = new short[Frames * 2]; var idle = Stopwatch.StartNew();
                try
                {
                    while (_run)
                    {
                        bool wrote = false;
                        for (int i = 0; i < NBuf; i++)
                        {
                            if (_queued[i] && (Marshal.ReadInt32(_hdr[i], _flagsAt) & WHDR_DONE) == 0) continue;
                            if (_queued[i]) { waveOutUnprepareHeader(_h, _hdr[i], _hdrSize); _queued[i] = false; }
                            Array.Clear(mono, 0, Frames);
                            bool sounding = _bed != null && _bed(mono);
                            lock (_voices)
                            {
                                for (int v = _voices.Count - 1; v >= 0; v--)
                                {
                                    var vo = _voices[v];
                                    if (vo.St)
                                    {   // stereo: straight into the two sides
                                        int n2 = Math.Min(Frames * 2, vo.P.Length - vo.Pos);
                                        for (int k = 0; k < n2; k++) mix[k] += vo.P[vo.Pos + k] / 32768f;
                                        vo.Pos += n2;
                                    }
                                    else
                                    {
                                        int n = Math.Min(Frames, vo.P.Length - vo.Pos);
                                        for (int k = 0; k < n; k++) mono[k] += vo.P[vo.Pos + k] / 32768f;
                                        vo.Pos += n;
                                    }
                                    if (vo.Pos >= vo.P.Length) _voices.RemoveAt(v);
                                }
                                if (_voices.Count > 0) sounding = true;
                            }
                            if (sounding) idle.Restart();
                            for (int k = 0; k < Frames; k++) { mix[k * 2] += mono[k]; mix[k * 2 + 1] += mono[k]; }      // the bed and mono cues, both sides
                            for (int k = 0; k < Frames * 2; k++)
                            {   // a soft limiter above 0.7, so a loud moment (the degauss over the hum) rounds off rather than clips
                                float s = mix[k], a = s < 0 ? -s : s;
                                if (a > 0.7f) { a = 0.7f + 0.29f * (float)Math.Tanh((a - 0.7f) / 0.29f); s = s < 0 ? -a : a; }
                                pcm[k] = (short)(s * 32767);
                            }
                            Marshal.Copy(pcm, 0, _buf[i], Frames * 2);
                            Array.Clear(mix, 0, mix.Length);
                            var hd = new WaveHdr { Data = _buf[i], Length = Frames * 4 };
                            Marshal.StructureToPtr(hd, _hdr[i], false);
                            waveOutPrepareHeader(_h, _hdr[i], _hdrSize); waveOutWrite(_h, _hdr[i], _hdrSize); _queued[i] = true; wrote = true;
                        }
                        if (idle.ElapsedMilliseconds > 4000) break;            // silent a while: give the device back
                        if (!wrote) Thread.Sleep(3);
                    }
                }
                catch { }
                finally { Shut(); }
            }
            void Shut()
            {
                if (_h == IntPtr.Zero) return;
                waveOutReset(_h);
                for (int i = 0; i < NBuf; i++) { if (_queued[i]) waveOutUnprepareHeader(_h, _hdr[i], _hdrSize); _queued[i] = false; }
                waveOutClose(_h); _h = IntPtr.Zero;
                for (int i = 0; i < NBuf; i++) { Marshal.FreeHGlobal(_buf[i]); Marshal.FreeHGlobal(_hdr[i]); }
                Closed = true;
            }
            public void Dispose() { _run = false; if (_th != null && Thread.CurrentThread != _th) _th.Join(1000); }
        }
        static MemoryStream Wav(short[] pcm)
        {
            var ms = new MemoryStream();
            var w = new BinaryWriter(ms);
            int bytes = pcm.Length * 2;
            w.Write(new[] { 'R', 'I', 'F', 'F' }); w.Write(36 + bytes); w.Write(new[] { 'W', 'A', 'V', 'E' });
            w.Write(new[] { 'f', 'm', 't', ' ' }); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(Rate); w.Write(Rate * 2); w.Write((short)2); w.Write((short)16);
            w.Write(new[] { 'd', 'a', 't', 'a' }); w.Write(bytes); foreach (var s in pcm) w.Write(s);
            w.Flush(); ms.Position = 0;
            return ms;
        }
    }

    // =========================================================================================
    // THE VISOR'S SHADING (Josh, 2026-10-07). The game shades the top of its view through HUDTOP.RES:
    // one dark colour, DITHERED -- every other pixel, thinning row by row -- which was the only way
    // to fade in 256 colours. In true colour that dither read as a dot screen, and because it is the
    // game's 1600-wide drawing it stopped at the game's view while the picture runs on to the edges
    // of the screen ("floating"). So the host draws it instead: the same file, its dot density turned
    // into a smooth coverage, laid across the WHOLE width the way the overlay lays the visor band
    // (corner wedges at the screen's corners, the straight middle stretched) -- over the boot too.
    // The game's own copy is hidden by turning its dots into the key colour (HideGameCopy): the file's
    // structure is untouched, only the colour of what it draws, and it is put back on the way out.
    // =========================================================================================
    public class VisorShade
    {
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);

        public int InjW = 1600, InjH = 928;
        /// <summary>The overlay's corner wedge (Overlay.VisorWedge): this share of the game's width at each corner.</summary>
        public double Wedge = 0.25;
        /// <summary>How far (game px) the dots are averaged into a coverage, and how dark the result is (1 = the dots' own density).</summary>
        public double Blur = 3, Strength = 1.0;
        public int Color, Index, Inked, Rows;
        /// <summary>Off until the game's own dithered copy is known to be hidden (or during the boot, which hides it anyway).</summary>
        public volatile bool Enabled = true;
        /// <summary>Draw on every picture the overlay shows (when there is no BootHd to do it).</summary>
        public void AttachTo(Overlay ov) { ov.Decorate = (p, w, h) => { Draw(p, w, ov.ViewRowsOf(h)); return true; }; }
        byte[] _file, _patched; float[] _cov;
        byte[] _a; int _aw, _avr, _arows; readonly object _lk = new object();

        public static VisorShade Load(string resPath, int[] pal32, int injW)
        {
            var v = new VisorShade(); v.InjW = injW;
            var b = File.ReadAllBytes(resPath); v._file = b;
            int end = b.Length - 4, p = 0, d = 0; var hist = new int[256];
            var ink = new List<int>(); v._patched = (byte[])b.Clone();
            while (p + 2 <= end)
            {
                int run = BitConverter.ToUInt16(b, p); p += 2;
                for (int k = 0; k < run && p + k < end; k++) { hist[b[p + k]]++; ink.Add(d + k); }
                p += run; d += run;
                if (p + 2 > end) break;
                d += BitConverter.ToUInt16(b, p); p += 2;
            }
            int best = 0; for (int i = 1; i < 256; i++) if (hist[i] > hist[best]) best = i;
            v.Index = best; v.Color = pal32[best] & 0xFFFFFF; v.Inked = ink.Count;
            int rows = d / injW + 1; v.Rows = rows;
            var m = new float[injW * rows]; foreach (int q in ink) if (q < m.Length) m[q] = 1;
            v._cov = BlurClamp(m, injW, rows, Math.Max(1, (int)Math.Round(v.Blur)));
            return v;
        }
        static float[] BlurClamp(float[] s, int w, int h, int r)
        {
            var a = (float[])s.Clone(); var t = new float[s.Length]; float k = 1f / (2 * r + 1);
            for (int pass = 0; pass < 2; pass++)
            {
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { float acc = 0; for (int i = -r; i <= r; i++) acc += a[y * w + Math.Max(0, Math.Min(w - 1, x + i))]; t[y * w + x] = acc * k; }
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { float acc = 0; for (int i = -r; i <= r; i++) { int yy = y + i; acc += yy < 0 ? 1f : yy >= h ? 0f : t[yy * w + x]; } a[y * w + x] = acc * k; }
            }
            return a;
        }
        // the coverage at this picture size: rows mapped like the view, columns like the overlay's visor band
        void Build(int pw, int vr)
        {
            double s = (double)vr / InjH, wedgePx = Wedge * InjW * s, mid0 = Wedge * InjW, mid1 = InjW - Wedge * InjW;
            int rows = Math.Min(vr, (int)Math.Ceiling(Rows * s) + 1);
            var gxs = new double[pw];
            for (int x = 0; x < pw; x++)
            {
                double px = x + 0.5, gx;
                if (px < wedgePx) gx = px / s; else if (px >= pw - wedgePx) gx = InjW - (pw - px) / s;
                else gx = mid0 + (px - wedgePx) / Math.Max(1, pw - 2 * wedgePx) * (mid1 - mid0);
                gxs[x] = Math.Max(0, Math.Min(InjW - 1.001, gx - 0.5));
            }
            var a = new byte[pw * rows]; var cov = _cov; int W = InjW, R = Rows; double str = Strength;
            System.Threading.Tasks.Parallel.For(0, rows, y =>
            {
                double gy = Math.Max(0, Math.Min(R - 1.001, (y + 0.5) / s - 0.5)); int iy = (int)gy; double fy = gy - iy;
                for (int x = 0; x < pw; x++)
                {
                    int ix = (int)gxs[x]; double fx = gxs[x] - ix;
                    double c = (cov[iy * W + ix] * (1 - fx) + cov[iy * W + ix + 1] * fx) * (1 - fy) + (cov[(iy + 1) * W + ix] * (1 - fx) + cov[(iy + 1) * W + ix + 1] * fx) * fy;
                    a[y * pw + x] = (byte)Math.Max(0, Math.Min(255, c * str * 255));
                }
            });
            _a = a; _aw = pw; _avr = vr; _arows = rows;
        }
        /// <summary>The coverage Draw blends by (0..255 a pixel, pw wide, rows deep from the top) -- for the card to lay the
        /// same shading on its way to the window (GpuRaster.SetPresentShade). The same array until the size changes.</summary>
        public byte[] CoverageFor(int pw, int vr, out int rows) { lock (_lk) { if (_a == null || _aw != pw || _avr != vr) Build(pw, vr); rows = _arows; return _a; } }
        public void Draw(int[] pic, int pw, int vr) { Draw(pic, pw, vr, false); }
        /// <summary>force: draw even while not Enabled (the host's boot, which has no game copy under it).</summary>
        public void Draw(int[] pic, int pw, int vr, bool force)
        {
            if (!Enabled && !force) return;
            byte[] a; int rows;
            lock (_lk) { if (_a == null || _aw != pw || _avr != vr) Build(pw, vr); a = _a; rows = _arows; }
            int col = Color, cr = (col >> 16) & 255, cg = (col >> 8) & 255, cb = col & 255;
            System.Threading.Tasks.Parallel.For(0, rows, y =>
            {
                int o = y * pw;
                for (int x = 0; x < pw; x++)
                {
                    int k = a[o + x]; if (k == 0) continue; k += k >> 7;
                    int c = pic[o + x], r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
                    pic[o + x] = ((r + ((cr - r) * k >> 8)) << 16) | ((g + ((cg - g) * k >> 8)) << 8) | (b + ((cb - b) * k >> 8));
                }
            });
        }

        // ---- the game's own copy ---------------------------------------------------------------
        // Where the game keeps the loaded HUDTOP: its data pointer and word count (Build-HudTop.ps1's
        // notes on the loader at 0x109B8), obj2 addresses.
        const int A_PTR = 0x1523CC, A_COUNT = 0x1523C4;
        /// <summary>obj2's runtime delta (the watcher's; it moves with obj1's size -- 0x1F1000 with the old overlay window).</summary>
        public long D2 = 0x1F1000;
        /// <summary>Hide (keyIndex >= 0) or restore (-1) the game's dithered copy. Only ever writes over
        /// data that is byte-for-byte the file it came from (or our own patch of it). Returns what it did.</summary>
        public string SetGameCopy(int pid, long memBase, int keyIndex)
        {
            IntPtr h = OpenProcess(0x0410 | 0x0020 | 0x0008, false, pid);
            if (h == IntPtr.Zero) return "cannot open the game";
            try
            {
                var w4 = new byte[4]; IntPtr got;
                if (!ReadProcessMemory(h, new IntPtr(memBase + A_PTR + D2), w4, new IntPtr(4), out got)) return "cannot read the pointer";
                uint ptr = BitConverter.ToUInt32(w4, 0);
                if (!ReadProcessMemory(h, new IntPtr(memBase + A_COUNT + D2), w4, new IntPtr(4), out got)) return "cannot read the count";
                uint cnt = BitConverter.ToUInt32(w4, 0), fileCnt = BitConverter.ToUInt32(_file, _file.Length - 4);
                if (ptr < 0x1000 || cnt != fileCnt) return string.Format("not loaded yet (ptr 0x{0:X}, count {1} vs {2})", ptr, cnt, fileCnt);
                int n = _file.Length - 4; var cur = new byte[n];
                if (!ReadProcessMemory(h, new IntPtr(memBase + ptr), cur, new IntPtr(n), out got) || got.ToInt64() != n) return "cannot read the data";
                // what the patch would be for this key
                byte[] want;
                if (keyIndex >= 0)
                {
                    want = new byte[n]; Buffer.BlockCopy(_file, 0, want, 0, n);
                    int p = 0;
                    while (p + 2 <= n) { int run = BitConverter.ToUInt16(_file, p); p += 2; for (int k = 0; k < run && p + k < n; k++) want[p + k] = (byte)keyIndex; p += run; if (p + 2 > n) break; p += 2; }
                }
                else { want = new byte[n]; Buffer.BlockCopy(_file, 0, want, 0, n); }
                if (Same(cur, want, n)) return keyIndex >= 0 ? "already hidden" : "already the game's own";
                // only over a copy we recognise: the file itself, or the same structure with every dot one colour
                if (!Same(cur, _file, n) && !SameStructure(cur, n)) return "the game's copy differs from the file -- left alone";
                IntPtr wr;
                if (!WriteProcessMemory(h, new IntPtr(memBase + ptr), want, new IntPtr(n), out wr) || wr.ToInt64() != n) return "write failed";
                return keyIndex >= 0 ? string.Format("hidden ({0} dots now the key colour {1})", Inked, keyIndex) : "restored";
            }
            finally { CloseHandle(h); }
        }
        static bool Same(byte[] a, byte[] b, int n) { for (int i = 0; i < n; i++) if (a[i] != b[i]) return false; return true; }
        // the file's runs and skips, whatever colour the runs' bytes are (a copy hidden with another key)
        bool SameStructure(byte[] cur, int n)
        {
            int p = 0;
            while (p + 2 <= n)
            {
                if (cur[p] != _file[p] || cur[p + 1] != _file[p + 1]) return false;
                int run = BitConverter.ToUInt16(_file, p); p += 2; p += run;
                if (p + 2 > n) break;
                if (cur[p] != _file[p] || cur[p + 1] != _file[p + 1]) return false;
                p += 2;
            }
            return true;
        }
    }
    // =========================================================================================
    // FOOTSTEPS (Josh, 2026-10-14: "footsteps ... subtle sound effects, which would change based on the different flooring
    // being walked on (mainly stone, tile, wood)"). The game has none. The host hears the player walk from the eye's own
    // movement (as the kicked-up dust does): a step every stride's worth of ground, the stride longer the faster the player
    // goes; none for a jump of 30+ units (a load or a teleport), none while falling or in the air. What is underfoot: a ray
    // straight down from the eye to the floor's triangle, and its texture's material (rooms\_materials.json; a room's
    // "footsteps" block names a texture's surface by hand). Each step is made fresh -- a heel and a softer toe a few
    // hundredths of a second after it, each a little different (pitch, weight, grit), the feet a little apart in the stereo
    // -- and played through the host's own mixer (BootSound), at the game's effects level. [[azrael-footsteps]]
    // =========================================================================================
    public class Footsteps
    {
        public enum Surface { Stone, Tile, Wood, Metal, Water }
        public bool On = true;
        /// <summary>Peak level of a walking step (0..1, before Volume and the game's effects level). Subtle by design.</summary>
        public double Level = 0.20;
        /// <summary>The game's own effects setting: 0 = muted (the system menu's SFX off), 1 = full. The watcher sets it.</summary>
        public double SfxShare = 1;
        /// <summary>Stride (world units) = StrideBase + StrideK x speed (units/s): walking ~146 u/s -> ~70 (about 2 steps a
        /// second), running ~290 -> ~93 (about 3).</summary>
        public float StrideBase = 46f, StrideK = 0.16f;
        /// <summary>Slower than this (u/s, smoothed) is standing still; faster than RunSpeed is running (heavier steps).</summary>
        public float MinSpeed = 24f, RunSpeed = 215f;
        /// <summary>Feet are this far below the eye; more than AirGap further than that and the player is in the air.</summary>
        public float EyeHeight = 45f, AirGap = 40f;
        /// <summary>A room's hand-named surfaces: texture leaf (with or without its number), or a material -> surface.</summary>
        public readonly Dictionary<string, Surface> Named = new Dictionary<string, Surface>(StringComparer.OrdinalIgnoreCase);
        /// <summary>A room's default when the floor's texture says nothing (null = stone).</summary>
        public Surface? RoomDefault;
        public readonly BootSound Sound = new BootSound();
        public int Steps;
        public Surface Last;

        const int Rate = 44100;
        readonly Random _rnd = new Random(7);
        float _lx, _ly, _lz, _walked, _speed, _vy, _still; bool _have, _moving, _left;

        /// <summary>Forget where the player was (a room change, a load): no step for the jump.</summary>
        public void Reset() { _have = false; _moving = false; _walked = 0f; _speed = 0f; _vy = 0f; }

        /// <summary>One frame: the eye at (ex,ey,ez), dt seconds since the last; the room as posed. `quiet`: the player is
        /// moved by something else (the map, a conversation, a room cover) -- follow, make no sound. Returns the surface name
        /// of a step it played this frame, or null.</summary>
        public string Update(float dt, float ex, float ey, float ez, float[] vx, int[] idx, int[] triTex, Raster.Tex[] texes, bool quiet)
        {
            if (dt <= 0f) return null; if (dt > 0.1f) dt = 0.1f;
            if (!_have) { _lx = ex; _ly = ey; _lz = ez; _have = true; return null; }
            float mx = ex - _lx, mz = ez - _lz, my = ey - _ly, moved = (float)Math.Sqrt(mx * mx + mz * mz);
            _lx = ex; _ly = ey; _lz = ez;
            if (moved >= 30f || Math.Abs(my) >= 30f) { _moving = false; _walked = 0f; _speed = 0f; _vy = 0f; return null; }      // (a jump, not a step)
            // the game moves the player on its own tick, so frames between see no movement: speed smoothed over ~0.2 s, and
            // still only after a fifth of a second without any
            float k = 1f - (float)Math.Exp(-dt / 0.2f);
            _speed += (moved / dt - _speed) * k; _vy += (my / dt - _vy) * k;
            if (moved > 0.01f) _still = 0f; else _still += dt;
            if (_still > 0.22f || _speed < MinSpeed) { if (_still > 0.22f) { _moving = false; _walked = 0f; _speed = 0f; } return null; }
            float stride = StrideBase + StrideK * _speed;
            if (!_moving) { _moving = true; _walked = stride * 0.5f; }       // (the first step comes half a stride in)
            _walked += moved;
            if (_walked < stride) return null;
            _walked -= stride; if (_walked > stride) _walked = 0f;
            if (quiet || !On || SfxShare <= 0.001 || _vy < -120f) return null;                     // (falling: no steps)
            float down; int tri = RayDown(vx, idx, triTex, ex, ey, ez, EyeHeight + AirGap, out down);
            if (tri < 0) return null;                                                              // (in the air, or nothing under)
            Surface s = Classify(texes, triTex[tri]);
            Last = s; Steps++;
            bool run = _speed > RunSpeed;
            _left = !_left;
            bool lf = _left; int seed = _rnd.Next();
            ThreadPool.QueueUserWorkItem(_ => { try { Sound.PlayStereo(Step(s, run, lf, seed)); } catch { } });      // (made off the drawing thread: a few ms each)
            return s.ToString();
        }

        /// <summary>Keep the sound device open while the game is played (opening it takes half a second: the first step after
        /// a pause would be late).</summary>
        public void Warm() { Sound.Warm(); }

        // the first face straight below the eye within `limit`, either side (as Raster.RayDistance); -1 if none
        static int RayDown(float[] vx, int[] idx, int[] triTex, float px, float py, float pz, float limit, out float dist)
        {
            float best = limit; int hit = -1, nTri = Math.Min(idx.Length / 3, triTex.Length);
            for (int t = 0; t < nTri; t++)
            {
                if (triTex[t] < 0) continue;
                int a = idx[t * 3] * 3, b = idx[t * 3 + 1] * 3, c = idx[t * 3 + 2] * 3;
                float ax = vx[a], az = vx[a + 2], bx = vx[b], bz = vx[b + 2], cx = vx[c], cz = vx[c + 2];
                // (looking straight down: inside the triangle's footprint, then its height there)
                float d = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz);
                if (d > -1e-9f && d < 1e-9f) continue;
                float l0 = ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / d; if (l0 < 0f) continue;
                float l1 = ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / d; if (l1 < 0f) continue;
                float l2 = 1f - l0 - l1; if (l2 < 0f) continue;
                float y = l0 * vx[a + 1] + l1 * vx[b + 1] + l2 * vx[c + 1], dd = py - y;
                if (dd > 0.25f && dd < best) { best = dd; hit = t; }
            }
            dist = best; return hit;
        }

        Surface Classify(Raster.Tex[] texes, int ti)
        {
            Raster.Tex t = texes != null && ti >= 0 && ti < texes.Length ? texes[ti] : null;
            string mat = t != null && t.Material != null ? t.Material : "", leaf = t != null && t.Leaf != null ? t.Leaf : "";
            string bare = System.Text.RegularExpressions.Regex.Replace(leaf, @"^\d+-", "");
            Surface s;
            if (leaf.Length > 0 && (Named.TryGetValue(leaf, out s) || Named.TryGetValue(bare, out s))) return s;
            if (mat.Length > 0 && Named.TryGetValue(mat, out s)) return s;
            switch (mat)
            {
                case "wood": return Surface.Wood;
                case "polished": case "glass": return Surface.Tile;
                case "iron": case "copper": case "brass": case "gold": case "gilded": return Surface.Metal;
                case "water": case "slime": return Surface.Water;
            }
            string b = bare.ToLowerInvariant();
            if (System.Text.RegularExpressions.Regex.IsMatch(b, "tile|marb|mosaic|parq")) return Surface.Tile;
            if (System.Text.RegularExpressions.Regex.IsMatch(b, "wood|plank|plk|board|deck|bri?j|timb")) return Surface.Wood;
            if (System.Text.RegularExpressions.Regex.IsMatch(b, "grat|grid|grill|mesh|metal|iron|steel")) return Surface.Metal;
            return RoomDefault ?? Surface.Stone;
        }

        // ---- THE SOUNDS ------------------------------------------------------------------------------------------------
        // STONE: a dull low thud, a short dry tap and a little grit scraping under the sole. TILE: a hard bright click with
        // a short glassy ring and a faint slap back off a hard room. WOOD: a hollow knock (the board's low modes), now and
        // then a faint creak. METAL (grates, plates): a dull clank that rings a little. WATER: a shallow splash. All through
        // a gentle low-pass (heard from inside a helmet), heel then toe.
        /// <summary>One step's sound: interleaved stereo at the engine's rate, at the level it plays.</summary>
        public short[] Step(Surface s, bool run, bool leftFoot, int seed)
        {
            var r = new Random(seed);
            double len = s == Surface.Metal ? 0.42 : s == Surface.Water ? 0.38 : 0.30;
            int n = (int)(len * Rate); var buf = new double[n];
            double pitch = 0.92 + 0.16 * r.NextDouble(), weight = (run ? 1.25 : 1.0) * (0.82 + 0.18 * r.NextDouble());
            double toeAt = run ? 0.018 + 0.016 * r.NextDouble() : 0.034 + 0.026 * r.NextDouble();
            Hit(buf, s, 0.0, 1.0, pitch, r, run);
            Hit(buf, s, toeAt, run ? 0.62 : 0.48, pitch * 1.06, r, run);
            if (s == Surface.Tile) { int e = (int)(0.026 * Rate); for (int i = n - 1; i >= e; i--) buf[i] += 0.13 * buf[i - e]; }   // (the slap back)
            double lowPass = s == Surface.Tile ? 9000 : s == Surface.Metal ? 7500 : 6000;
            double a = 1 - Math.Exp(-2 * Math.PI * lowPass / Rate), lp = 0, lp2 = 0, peak = 1e-9; int tail = (int)(0.03 * Rate);
            for (int i = 0; i < n; i++) { lp += a * (buf[i] - lp); lp2 += a * (lp - lp2); buf[i] = lp2 * Math.Min(1, (n - i) / (double)tail); peak = Math.Max(peak, Math.Abs(buf[i])); }
            double gain = s == Surface.Tile ? 0.85 : s == Surface.Metal ? 0.72 : s == Surface.Water ? 0.8 : 1.0;
            double lvl = Math.Min(0.95, Level * gain * weight * Math.Max(0, Math.Min(1.5, SfxShare)) * Sound.Volume / 0.36);
            // the feet a little apart: left a little left, right a little right (equal power about the middle)
            double pan = (leftFoot ? -0.14 : 0.14) + 0.05 * (r.NextDouble() - 0.5), ang = (pan + 1) * Math.PI / 4;
            double gl = Math.Cos(ang) * Math.Sqrt(2), gr = Math.Sin(ang) * Math.Sqrt(2), kk = lvl / peak * 32767;
            var o = new short[n * 2];
            for (int i = 0; i < n; i++)
            {
                o[i * 2] = (short)Math.Max(-32767, Math.Min(32767, buf[i] * kk * gl));
                o[i * 2 + 1] = (short)Math.Max(-32767, Math.Min(32767, buf[i] * kk * gr));
            }
            return o;
        }

        // one footfall (heel or toe) at `at` seconds, `amp` of full
        static void Hit(double[] buf, Surface s, double at, double amp, double pitch, Random r, bool run)
        {
            int s0 = (int)(at * Rate), n = buf.Length - s0; if (n <= 0) return;
            var x = new double[n];
            switch (s)
            {
                case Surface.Stone:
                    Thump(x, 95 * pitch, 0.016, 0.55);
                    Noise(x, r, 1700 * pitch, 0.8, 0.0045, 0.55, 0.0005);
                    Grit(x, r, 3200, 0.9, run ? 0.07 : 0.05, run ? 0.32 : 0.24);
                    break;
                case Surface.Tile:
                    Thump(x, 125 * pitch, 0.010, 0.38);
                    Noise(x, r, 3600 * pitch, 1.3, 0.0028, 0.85, 0.0003);
                    Mode(x, 1950 * pitch * (0.95 + 0.1 * r.NextDouble()), 0.012, 0.20, r);
                    Mode(x, 2870 * pitch * (0.95 + 0.1 * r.NextDouble()), 0.009, 0.14, r);
                    Mode(x, 4150 * pitch * (0.95 + 0.1 * r.NextDouble()), 0.006, 0.10, r);
                    Grit(x, r, 5000, 1.0, 0.025, 0.06);
                    break;
                case Surface.Wood:
                    Mode(x, 150 * pitch * (0.94 + 0.12 * r.NextDouble()), 0.050, 0.55, r);
                    Mode(x, 335 * pitch * (0.94 + 0.12 * r.NextDouble()), 0.034, 0.42, r);
                    Mode(x, 610 * pitch * (0.94 + 0.12 * r.NextDouble()), 0.020, 0.28, r);
                    Noise(x, r, 950 * pitch, 1.0, 0.007, 0.45, 0.0006);
                    Grit(x, r, 2400, 0.9, 0.035, 0.08);
                    if (amp >= 1 && r.NextDouble() < 0.12) Creak(x, r);
                    break;
                case Surface.Metal:
                    Thump(x, 85 * pitch, 0.014, 0.35);
                    Noise(x, r, 2400 * pitch, 1.0, 0.004, 0.5, 0.0004);
                    Mode(x, 520 * pitch * (0.95 + 0.1 * r.NextDouble()), 0.11, 0.26, r);
                    Mode(x, 1235 * pitch * (0.95 + 0.1 * r.NextDouble()), 0.075, 0.22, r);
                    Mode(x, 2140 * pitch * (0.95 + 0.1 * r.NextDouble()), 0.055, 0.17, r);
                    Mode(x, 3360 * pitch * (0.95 + 0.1 * r.NextDouble()), 0.038, 0.11, r);
                    break;
                case Surface.Water:
                    Thump(x, 80 * pitch, 0.02, 0.4);
                    Noise(x, r, 1100 * pitch, 0.6, 0.06, 0.45, 0.004);
                    for (int b = 0; b < 5; b++) Bubble(x, r, 0.005 + 0.07 * r.NextDouble(), 500 + 900 * r.NextDouble(), 0.12 + 0.1 * r.NextDouble());
                    break;
            }
            for (int i = 0; i < n; i++) buf[s0 + i] += x[i] * amp;
        }
        // a low sine thud, quick attack
        static void Thump(double[] x, double f, double decay, double amp)
        {
            int n = Math.Min(x.Length, (int)(decay * 8 * Rate));
            for (int i = 0; i < n; i++) { double t = i / (double)Rate; x[i] += amp * Math.Min(1, t / 0.0012) * Math.Exp(-t / decay) * Math.Sin(2 * Math.PI * f * t * (1 + 0.4 * Math.Exp(-t / 0.006))); }
        }
        // a short burst of noise through a band-pass (centre f, Q q), attack `att` s, decay `decay` s
        static void Noise(double[] x, Random r, double f, double q, double decay, double amp, double att)
        {
            int n = Math.Min(x.Length, (int)(decay * 9 * Rate) + (int)(att * Rate)); var w = new double[n];
            for (int i = 0; i < n; i++) { double t = i / (double)Rate; w[i] = (r.NextDouble() * 2 - 1) * Math.Min(1, t / Math.Max(1e-5, att)) * Math.Exp(-t / decay); }
            Band(w, f, q); Norm(w);
            for (int i = 0; i < n; i++) x[i] += amp * w[i];
        }
        // the grit under the sole: sparse little grains, scraping for `dur` s
        static void Grit(double[] x, Random r, double f, double q, double dur, double amp)
        {
            int n = Math.Min(x.Length, (int)(dur * 1.6 * Rate)); var w = new double[n]; double g = 0;
            for (int i = 0; i < n; i++)
            {
                double t = i / (double)Rate, env = Math.Min(1, t / 0.004) * Math.Exp(-t / (dur * 0.45));
                if (r.NextDouble() < 0.035) g = (r.NextDouble() * 2 - 1);
                w[i] = (g + 0.35 * (r.NextDouble() * 2 - 1)) * env; g *= 0.7;
            }
            Band(w, f, q); Norm(w);
            for (int i = 0; i < n; i++) x[i] += amp * w[i];
        }
        // a struck mode: a damped sine
        static void Mode(double[] x, double f, double decay, double amp, Random r)
        {
            int n = Math.Min(x.Length, (int)(decay * 8 * Rate)); double ph = r.NextDouble() * 0.6;
            for (int i = 0; i < n; i++) { double t = i / (double)Rate; x[i] += amp * Math.Min(1, t / 0.0008) * Math.Exp(-t / decay) * Math.Sin(2 * Math.PI * f * t + ph); }
        }
        // a faint board creak: a rough low tone gliding, for a tenth of a second
        static void Creak(double[] x, Random r)
        {
            int s0 = (int)((0.03 + 0.03 * r.NextDouble()) * Rate), n = Math.Min(x.Length - s0, (int)(0.12 * Rate)); if (n <= 0) return;
            double f0 = 260 + 160 * r.NextDouble(), f1 = f0 * (1.15 + 0.2 * r.NextDouble()), ph = 0;
            for (int i = 0; i < n; i++)
            {
                double u = i / (double)n, f = f0 + (f1 - f0) * u, env = Math.Sin(Math.PI * u);
                ph += 2 * Math.PI * f / Rate * (1 + 0.08 * (r.NextDouble() - 0.5));
                double saw = 2 * (ph / (2 * Math.PI) - Math.Floor(ph / (2 * Math.PI) + 0.5));
                x[s0 + i] += 0.06 * env * saw;
            }
        }
        // a bubble: a sine whose pitch rises as it dies
        static void Bubble(double[] x, Random r, double at, double f, double amp)
        {
            int s0 = (int)(at * Rate), n = Math.Min(x.Length - s0, (int)(0.05 * Rate)); if (n <= 0) return; double ph = 0;
            for (int i = 0; i < n; i++) { double t = i / (double)Rate; ph += 2 * Math.PI * f * (1 + 2.5 * t / 0.05) / Rate; x[s0 + i] += amp * Math.Min(1, t / 0.001) * Math.Exp(-t / 0.012) * Math.Sin(ph); }
        }
        // band-pass in place (RBJ, constant 0 dB peak), run twice for a steeper skirt
        static void Band(double[] w, double f, double q)
        {
            f = Math.Min(f, Rate * 0.45);
            double w0 = 2 * Math.PI * f / Rate, al = Math.Sin(w0) / (2 * q), a0 = 1 + al;
            double b0 = al / a0, b2 = -al / a0, a1 = -2 * Math.Cos(w0) / a0, a2 = (1 - al) / a0;
            for (int pass = 0; pass < 2; pass++)
            {
                double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
                for (int i = 0; i < w.Length; i++) { double xi = w[i], y = b0 * xi + b2 * x2 - a1 * y1 - a2 * y2; x2 = x1; x1 = xi; y2 = y1; y1 = y; w[i] = y; }
            }
        }
        static void Norm(double[] w) { double p = 1e-9; foreach (var v in w) p = Math.Max(p, Math.Abs(v)); for (int i = 0; i < w.Length; i++) w[i] /= p; }

        /// <summary>Offline: a walk across each surface (a few steps, walking then running) as a .wav, for listening.</summary>
        public void SaveDemo(string path)
        {
            var clips = new List<short[]>(); var at = new List<int>(); int pos = 0;
            foreach (Surface s in Enum.GetValues(typeof(Surface)))
            {
                for (int i = 0; i < 6; i++)
                {
                    bool run = i >= 4; clips.Add(Step(s, run, (i & 1) == 0, 100 * (int)s + i)); at.Add(pos);
                    pos += (int)((run ? 0.33 : 0.48) * Rate) * 2;
                }
                pos += (int)(0.6 * Rate) * 2;
            }
            int total = pos; for (int i = 0; i < clips.Count; i++) total = Math.Max(total, at[i] + clips[i].Length);
            var mix = new int[total]; for (int i = 0; i < clips.Count; i++) for (int j = 0; j < clips[i].Length; j++) mix[at[i] + j] += clips[i][j];
            var all = new List<short>(total); foreach (var v in mix) all.Add((short)Math.Max(-32767, Math.Min(32767, v)));
            var pcm = all.ToArray();
            using (var fs = File.Create(path))
            using (var bw = new BinaryWriter(fs))
            {
                bw.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); bw.Write(36 + pcm.Length * 2); bw.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
                bw.Write(16); bw.Write((short)1); bw.Write((short)2); bw.Write(Rate); bw.Write(Rate * 4); bw.Write((short)4); bw.Write((short)16);
                bw.Write(System.Text.Encoding.ASCII.GetBytes("data")); bw.Write(pcm.Length * 2); foreach (var v in pcm) bw.Write(v);
            }
        }
    }
}
