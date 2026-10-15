// RaptorDocs.cs -- RAPTOR DOCS on the title screen (Josh, 2026-10-11: "On the main menu lets change the label 'story' to
// 'Raptor Docs'. On opening it (which will be just like opening the options menu as far as UI) we will see 'Manual' and
// 'Classified Docs'. The Manual will open an in game variation of the manual we have on file ... presented in a way that
// is in-universe for the game, but simple and sleek. For the Classified docs, we will be adding the original print-outs
// that came with the game ... click in-universe left/right arrows to view those docs, with a 'back' button that will lead
// back to the main menu.")
//
// Part of TitleScreen (LoadingScreen.cs); the loading gate compiles it with LoadingScreen.cs and CursorShapes.cs.
//   * RAPTOR DOCS opens a panel like OPTIONS: MANUAL, CLASSIFIED DOCS, BACK.
//   * MANUAL = the MS-2 OPERATOR'S MANUAL in the visor's library: the 1996 manual's text (<DocsDir>\manual.txt; its header
//     has the markup) typeset in the visor's inks, a page at a time, the chapters down the left. Its cursor legend draws the
//     in-game vector icons (CursorShapes), animated as in play.
//   * CLASSIFIED DOCS = the print-outs that came in the box (<DocsDir>\classified.txt + classified\*.jpg), one at a time
//     between the visor's arrow pads. A click on the page magnifies it; the pointer's height then pans it.
//   * BACK (or ESC) in either goes straight back to the main menu (Josh's words). Arrow keys / PgUp / PgDn / the wheel turn
//     the pages; Home / End go to the first / last.
//   * A reader repaints whole only when something changes (ViewDirty). Otherwise only its moving parts are redrawn: the
//     arrow pads, the manual's icons, a page loading, revealing or panning.
// tools\Build-RaptorDocs.ps1 writes DocsDir from Josh's sources (C:\Games\RaptorMod\sources\gfx\raptordocs, credits\*.png).
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Text;
using System.Threading;

namespace AztTool
{
    public partial class TitleScreen
    {
        /// <summary>RAPTOR DOCS' folder: manual.txt, classified.txt, classified\*.jpg (tools\Build-RaptorDocs.ps1).</summary>
        public string DocsDir;
        /// <summary>A click on a classified page magnifies it this much (against the page fitted whole; never past the scan).</summary>
        public double DocZoom = 2.0;
        /// <summary>The manual's body text (pale amber).</summary>
        public int DocInk = 0xF2DDB8, DocRed = 0xFF6A3C;

        // ---- the RAPTOR DOCS panel (a layer like OPTIONS) ----------------------------------------------------------------
        const int D_MAN = 0, D_CLS = 1, D_BACK = 2, DROWS = 3;
        bool _docsOpen; double _docsAt = -9, _docsSoonAt = -9; int _dsel = D_MAN;
        RectangleF _docsPanel; readonly RectangleF[] _docsRect = new RectangleF[DROWS]; Rectangle _docsArea;

        // ---- the readers -----------------------------------------------------------------------------------------------
        const int V_NONE = 0, V_MANUAL = 1, V_CLASSIFIED = 2;
        const int VB_BACK = 0, VB_PREV = 1, VB_NEXT = 2, VB_DOC = 3, VB_TOC = 10;
        int _view, _viewLast = V_MANUAL, _vsel = -1; double _viewAt = -9, _viewShutAt = -9; volatile bool _vNeed = true;
        float _vs = 1;                      // the readers' scale: 1 at 1920 x 1080, by the smaller side
        RectangleF _mPanel, _mText, _mBack, _mPrev, _mNext, _cPanel, _cArea, _cBack, _cPrev, _cNext; RectangleF[] _tocRect = new RectangleF[0];
        volatile bool _docsGone;

        bool ViewUp(double t) { return _view != V_NONE || t - _viewShutAt < 0.45; }
        double ViewAlpha(double t) { return _view != V_NONE ? Ease((t - _viewAt) / 0.3) : 1 - Ease((t - _viewShutAt) / 0.3); }
        /// <summary>How far the main menu has stepped back for RAPTOR DOCS (its panel or a reader in front).</summary>
        double DocsBack(double t)
        {
            double b = _docsOpen ? Ease((t - _docsAt) / 0.3) : 1 - Ease((t - _docsAt) / 0.3);
            return Math.Max(b, _view != V_NONE ? Ease((t - _viewAt) / 0.3) : 1 - Ease((t - _viewShutAt) / 0.3));
        }

        // ---- layout (from Prepare) -------------------------------------------------------------------------------------
        void PrepareDocs(float px, float py, float pw)
        {
            _docsPanel = new RectangleF(px, py, pw, 410 * _s);
            _docsRect[D_MAN] = new RectangleF(px + 36 * _s, py + 96 * _s, pw - 72 * _s, 92 * _s);
            _docsRect[D_CLS] = new RectangleF(px + 36 * _s, py + 200 * _s, pw - 72 * _s, 92 * _s);
            _docsRect[D_BACK] = new RectangleF(px + 36 * _s, py + 322 * _s, pw - 72 * _s, 50 * _s);
            var da = _docsPanel; da.Inflate(40 * _s, 40 * _s); _docsArea = Rectangle.Intersect(Rectangle.Round(da), new Rectangle(0, 0, _W, _H));
            _vs = Math.Min(_W / 1920f, _H / 1080f);
            LoadDocsIndex();
            LayoutViewer();
            _pages = null;                  // (laid out for this size when the manual first opens)
        }
        void LayoutViewer()
        {
            float v = _vs;
            // the manual: a reading column, the chapters down its left
            float mw = Math.Min(1380 * v, _W - 60 * v), mh = Math.Min(980 * v, _H - 60 * v);
            _mPanel = new RectangleF((_W - mw) / 2, (_H - mh) / 2, mw, mh);
            float tocW = 280 * v, x0 = _mPanel.Left + 36 * v, colX = x0 + tocW + 64 * v;
            _mText = new RectangleF(colX, _mPanel.Top + 104 * v, _mPanel.Right - 60 * v - colX, mh - 208 * v);
            _mBack = new RectangleF(x0, _mPanel.Bottom - 84 * v, tocW, 50 * v);
            float fy = _mPanel.Bottom - 88 * v, cx = _mText.Left + _mText.Width / 2;
            _mPrev = new RectangleF(cx - 200 * v, fy, 76 * v, 58 * v); _mNext = new RectangleF(cx + 124 * v, fy, 76 * v, 58 * v);
            int n = _chapters == null ? 0 : _chapters.Count; _tocRect = new RectangleF[n];
            float ty = _mPanel.Top + 146 * v, pitch = Math.Min(50 * v, (_mBack.Top - 30 * v - ty) / Math.Max(1, n));
            for (int i = 0; i < n; i++) _tocRect[i] = new RectangleF(x0, ty + i * pitch, tocW, pitch - 6 * v);
            // the classified files: as large as the screen allows, an arrow pad either side
            _cPanel = new RectangleF(24 * v, 24 * v, _W - 48 * v, _H - 48 * v);
            float padW = 92 * v, padH = 220 * v, midY = _cPanel.Top + _cPanel.Height / 2;
            _cPrev = new RectangleF(_cPanel.Left + 30 * v, midY - padH / 2, padW, padH);
            _cNext = new RectangleF(_cPanel.Right - 30 * v - padW, midY - padH / 2, padW, padH);
            float ax = _cPrev.Right + 30 * v;
            _cArea = new RectangleF(ax, _cPanel.Top + 86 * v, _cNext.Left - 30 * v - ax, _cPanel.Height - 86 * v - 100 * v);
            _cBack = new RectangleF(_cPanel.Left + 36 * v, _cPanel.Bottom - 82 * v, 220 * v, 50 * v);
        }

        // ---- the files ------------------------------------------------------------------------------------------------
        class MBlock { public string Kind, A, B, C; }
        class MChapter { public string Name, Heading; public readonly List<MBlock> Blocks = new List<MBlock>(); public int FirstPage; }
        class CDoc { public string File, Title, Sub, Err; public volatile bool Ready, Loading; public Bitmap Fit, Zoom; public SizeF For; }
        List<MChapter> _chapters; string _manualTitle = "OPERATOR'S MANUAL";
        readonly List<CDoc> _cdocs = new List<CDoc>(); int _cdoc, _revealDoc = -1; double _revealAt = -9;
        bool ManualReady { get { return _chapters != null && _chapters.Count > 0; } }
        bool ClassifiedReady { get { return _cdocs.Count > 0; } }
        CDoc CurDoc { get { return _cdoc >= 0 && _cdoc < _cdocs.Count ? _cdocs[_cdoc] : null; } }

        void LoadDocsIndex()
        {
            if (string.IsNullOrEmpty(DocsDir)) return;
            if (_chapters == null)
                try { string mp = Path.Combine(DocsDir, "manual.txt"); if (File.Exists(mp)) ParseManual(mp); }
                catch (Exception e) { _chapters = null; Note = (Note.Length > 0 ? Note + "; " : "") + "manual: " + e.Message; }
            if (_cdocs.Count == 0)
                try
                {
                    string ip = Path.Combine(DocsDir, "classified.txt");
                    if (File.Exists(ip))
                        foreach (var raw in File.ReadAllLines(ip, Encoding.UTF8))
                        {
                            string l = raw.Trim(); if (l.Length == 0 || l.StartsWith("//")) continue;
                            var f = l.Split('|'); string file = Path.Combine(DocsDir, "classified", f[0].Trim());
                            if (!File.Exists(file)) continue;
                            _cdocs.Add(new CDoc { File = file, Title = f.Length > 1 ? f[1].Trim() : Path.GetFileNameWithoutExtension(file).ToUpperInvariant(), Sub = f.Length > 2 ? f[2].Trim() : "" });
                        }
                }
                catch (Exception e) { Note = (Note.Length > 0 ? Note + "; " : "") + "classified: " + e.Message; }
        }
        // manual.txt: see its header. Plain lines join into paragraphs; a blank line ends one; '//' at the start is a comment.
        void ParseManual(string path)
        {
            var chapters = new List<MChapter>(); MChapter ch = null; var para = new StringBuilder();
            Action flush = () => { if (para.Length > 0 && ch != null) ch.Blocks.Add(new MBlock { Kind = "p", A = para.ToString() }); para.Clear(); };
            foreach (var raw in File.ReadAllLines(path, Encoding.UTF8))
            {
                string l = raw.TrimEnd();
                if (l.StartsWith("//")) continue;
                if (l.Trim().Length == 0) { flush(); continue; }
                if (l[0] == '@')
                {
                    flush();
                    int sp = l.IndexOf(' '); string kind = (sp < 0 ? l.Substring(1) : l.Substring(1, sp - 1)).ToLowerInvariant(), rest = sp < 0 ? "" : l.Substring(sp + 1).Trim();
                    bool split = kind == "chapter" || kind == "term" || kind == "icon" || kind == "figicon";
                    var f = split ? rest.Split('|') : new[] { rest }; for (int i = 0; i < f.Length; i++) f[i] = f[i].Trim();
                    if (kind == "title") { _manualTitle = rest.ToUpperInvariant(); continue; }
                    if (kind == "chapter") { ch = new MChapter { Name = f[0].ToUpperInvariant(), Heading = (f.Length > 1 ? f[1] : f[0]).ToUpperInvariant() }; chapters.Add(ch); continue; }
                    if (ch != null) ch.Blocks.Add(new MBlock { Kind = kind, A = f[0], B = f.Length > 1 ? f[1] : "", C = f.Length > 2 ? f[2] : "" });
                    continue;
                }
                if (para.Length > 0) para.Append(' ');
                para.Append(l.Trim());
            }
            flush();
            _chapters = chapters;
        }

        // ---- the manual's pages ------------------------------------------------------------------------------------------
        // A page is a list of placed items (in the text column's own coordinates); drawn straight from them, the icons live.
        const int MI_TEXT = 0, MI_SPACED = 1, MI_RULE = 2, MI_ICON = 3, MI_FRAME = 4, MI_DIAMOND = 5, MI_BAR = 6;
        class MItem { public int K; public string S; public RectangleF R; public Font F; public int Ink; public double A = 1; public float Track; public bool Center; }
        class MPage { public int Chapter; public readonly List<MItem> Items = new List<MItem>(); }
        List<MPage> _pages; SizeF _pagesFor; int _page; double _pageAt = -9;
        Font _fBody, _fItal, _fHead, _fChap, _fMono, _fCap, _fIconT, _fUi, _fUiS, _fUiH; float _fontsFor = -1;

        static string Family(params string[] names)
        {
            foreach (var n in names) { try { using (new FontFamily(n)) return n; } catch { } }
            return "Segoe UI";
        }
        void EnsureFonts()
        {
            if (_fBody != null && _fontsFor == _vs) return;
            FreeFonts(); _fontsFor = _vs; float v = _vs;
            string body = Family("Bahnschrift SemiLight", "Bahnschrift", "Segoe UI"), semi = Family("Bahnschrift SemiBold", "Bahnschrift", "Segoe UI Semibold");
            _fBody = new Font(body, 19.5f * v, FontStyle.Regular, GraphicsUnit.Pixel);
            _fItal = new Font(Family("Segoe UI Light", "Segoe UI"), 20f * v, FontStyle.Italic, GraphicsUnit.Pixel);
            _fHead = new Font(semi, 22f * v, FontStyle.Regular, GraphicsUnit.Pixel);
            _fIconT = new Font(semi, 19.5f * v, FontStyle.Regular, GraphicsUnit.Pixel);
            _fChap = new Font("Consolas", 27f * v, FontStyle.Bold, GraphicsUnit.Pixel);
            _fMono = new Font("Consolas", 15.5f * v, FontStyle.Regular, GraphicsUnit.Pixel);
            _fCap = new Font("Consolas", 14.5f * v, FontStyle.Bold, GraphicsUnit.Pixel);
            _fUi = new Font("Consolas", 18f * v, FontStyle.Bold, GraphicsUnit.Pixel);
            _fUiS = new Font("Consolas", 14f * v, FontStyle.Bold, GraphicsUnit.Pixel);
            _fUiH = new Font("Consolas", 22f * v, FontStyle.Bold, GraphicsUnit.Pixel);
        }
        void FreeFonts()
        {
            foreach (var f in new[] { _fBody, _fItal, _fHead, _fChap, _fMono, _fCap, _fIconT, _fUi, _fUiS, _fUiH }) if (f != null) f.Dispose();
            _fBody = _fItal = _fHead = _fChap = _fMono = _fCap = _fIconT = _fUi = _fUiS = _fUiH = null;
        }
        static List<string> Wrap(string s, float width, Func<string, float> measure)
        {
            var lines = new List<string>(); string cur = "";
            foreach (var w in s.Split(' '))
            {
                if (w.Length == 0) continue;
                string t = cur.Length == 0 ? w : cur + " " + w;
                if (cur.Length > 0 && measure(t) > width) { lines.Add(cur); cur = w; } else cur = t;
            }
            if (cur.Length > 0) lines.Add(cur);
            return lines;
        }
        void EnsurePages()
        {
            if (!ManualReady) return;
            EnsureFonts();
            if (_pages != null && _pagesFor == _mText.Size) return;
            _pages = new List<MPage>(); _pagesFor = _mText.Size;
            float W = _mText.Width, H = _mText.Height, v = _vs;
            using (var bm = new Bitmap(8, 8))
            using (var g = Graphics.FromImage(bm))
            {
                g.TextRenderingHint = TextRenderingHint.AntiAlias;
                var fmt = StringFormat.GenericTypographic;
                Func<Font, Func<string, float>> m = f => s => g.MeasureString(s, f, new PointF(0, 0), fmt).Width;
                Func<Font, float, Func<string, float>> ms = (f, tr) => s => Spaced(g, s, f, null, 0, 0, tr, true);
                float lh = _fBody.GetHeight(g) * 1.34f, gapP = lh * 0.55f, lhc = _fCap.GetHeight(g) * 1.35f, lhm = _fMono.GetHeight(g) * 1.3f;
                MPage pg = null; float y = 0; int ci = 0;
                Action np = () => { pg = new MPage { Chapter = ci }; _pages.Add(pg); y = 0; };
                Func<float, bool> fits = need => y + need <= H;
                Action<float> keep = need => { if (y > 0 && !fits(need)) np(); };
                Action<string, float, float, Font, int, double, bool> text = (s, x, w, f, ink, a, center) =>
                    pg.Items.Add(new MItem { K = MI_TEXT, S = s, R = new RectangleF(x, y, w, f.GetHeight(g)), F = f, Ink = ink, A = a, Center = center });
                for (ci = 0; ci < _chapters.Count; ci++)
                {
                    var ch = _chapters[ci]; np(); ch.FirstPage = _pages.Count - 1;
                    // the chapter's heading: spaced capitals over a short bright rule
                    foreach (var hl in Wrap(ch.Heading, W, ms(_fChap, 4 * v)))
                    {
                        pg.Items.Add(new MItem { K = MI_SPACED, S = hl, R = new RectangleF(0, y, W, _fChap.GetHeight(g)), F = _fChap, Ink = AmberHi, Track = 4 * v });
                        y += _fChap.GetHeight(g) * 1.12f;
                    }
                    y += 6 * v; pg.Items.Add(new MItem { K = MI_RULE, R = new RectangleF(0, y, 150 * v, 2.2f * v), Ink = Amber, A = 0.9 }); y += 30 * v;
                    for (int bi = 0; bi < ch.Blocks.Count; bi++)
                    {
                        var b = ch.Blocks[bi];
                        switch (b.Kind)
                        {
                            case "p":
                            {
                                var lines = Wrap(b.A, W, m(_fBody));
                                for (int i = 0; i < lines.Count; i++)
                                {
                                    if (i == 0) keep(lh * Math.Min(2, lines.Count)); else if (!fits(lh)) np();
                                    text(lines[i], 0, W, _fBody, DocInk, 0.93, false); y += lh;
                                }
                                y += gapP; break;
                            }
                            case "h":
                            {
                                float hh = _fHead.GetHeight(g) * 1.25f;
                                if (y > 0) y += 8 * v;
                                keep(hh + lh * 3);
                                text(b.A, 0, W, _fHead, Amber, 1.0, false); y += hh + 2 * v; break;
                            }
                            case "epigraph":
                            {
                                var lines = Wrap(b.A, W * 0.84f, m(_fItal)); float le = _fItal.GetHeight(g) * 1.3f;
                                keep(le * lines.Count);
                                foreach (var l in lines) { if (!fits(le)) np(); text(l, 0, W, _fItal, AmberHi, 0.9, true); y += le; }
                                y += gapP * 0.6f; break;
                            }
                            case "bullet":
                            {
                                float ind = 30 * v; var lines = Wrap(b.A, W - ind, m(_fBody));
                                keep(lh * Math.Min(2, lines.Count));
                                pg.Items.Add(new MItem { K = MI_DIAMOND, R = new RectangleF(9 * v, y + lh * 0.42f - 5 * v, 10 * v, 10 * v), Ink = Amber });
                                for (int i = 0; i < lines.Count; i++) { if (i > 0 && !fits(lh)) np(); text(lines[i], ind, W - ind, _fBody, DocInk, 0.93, false); y += lh; }
                                y += gapP * 0.5f; break;
                            }
                            case "quote":
                            {
                                float ind = 24 * v; var lines = Wrap(b.A, W - ind, m(_fBody));
                                keep(lh * Math.Min(2, lines.Count));
                                for (int i = 0; i < lines.Count; i++)
                                {
                                    if (i > 0 && !fits(lh)) np();
                                    pg.Items.Add(new MItem { K = MI_BAR, R = new RectangleF(2 * v, y + 2 * v, 2.2f * v, lh), Ink = Amber, A = 0.55 });
                                    text(lines[i], ind, W - ind, _fBody, DocInk, 0.86, false); y += lh;
                                }
                                y += gapP; break;
                            }
                            case "mono":
                            {
                                foreach (var l in Wrap(b.A, W, m(_fMono))) { if (!fits(lhm)) np(); text(l, 0, W, _fMono, AmberDim, 1.0, false); y += lhm; }
                                break;
                            }
                            case "caption":
                            {
                                var lines = Wrap(b.A, W, ms(_fCap, 2.5f * v)); keep(lhc * lines.Count);
                                foreach (var l in lines) { pg.Items.Add(new MItem { K = MI_SPACED, S = l, R = new RectangleF(0, y, W, lhc), F = _fCap, Ink = AmberDim, A = 0.95, Track = 2.5f * v }); y += lhc; }
                                y += 8 * v; break;
                            }
                            case "warn":
                            {
                                // the warning box: consecutive @warn lines together, the first its title
                                var parts = new List<string> { b.A }; while (bi + 1 < ch.Blocks.Count && ch.Blocks[bi + 1].Kind == "warn") parts.Add(ch.Blocks[++bi].A);
                                float pad = 18 * v, iw = W - 2 * pad; var wrapped = new List<List<string>>(); float bh = pad * 2 + lhc * 1.3f;
                                for (int i = 1; i < parts.Count; i++) { var ls = Wrap(parts[i], iw, ms(_fCap, 1.5f * v)); wrapped.Add(ls); bh += ls.Count * lhc + (i < parts.Count - 1 ? 10 * v : 0); }
                                keep(bh);
                                pg.Items.Add(new MItem { K = MI_FRAME, R = new RectangleF(0, y, W, bh), Ink = DocRed, A = 0.85 });
                                float yy = y + pad;
                                pg.Items.Add(new MItem { K = MI_SPACED, S = parts[0].ToUpperInvariant(), R = new RectangleF(pad, yy, iw, lhc), F = _fCap, Ink = DocRed, A = 1, Track = 5 * v }); yy += lhc * 1.3f;
                                foreach (var ls in wrapped) { foreach (var l in ls) { pg.Items.Add(new MItem { K = MI_SPACED, S = l, R = new RectangleF(pad, yy, iw, lhc), F = _fCap, Ink = AmberHi, A = 0.85, Track = 1.5f * v }); yy += lhc; } yy += 10 * v; }
                                y += bh + gapP; break;
                            }
                            case "term":
                            {
                                float lw = W * 0.34f; var left = Wrap(b.A, lw - 18 * v, ms(_fCap, 1.5f * v));
                                var right = new List<string>(); foreach (var part in b.B.Split(';')) right.AddRange(Wrap(part.Trim(), W - lw, m(_fBody)));
                                float rh = Math.Max(left.Count * lhc, right.Count * lh) + 10 * v;
                                keep(rh);
                                float y0 = y;
                                foreach (var l in left) { pg.Items.Add(new MItem { K = MI_SPACED, S = l, R = new RectangleF(0, y + (lh - lhc) * 0.5f, lw, lhc), F = _fCap, Ink = Amber, A = 0.9, Track = 1.5f * v }); y += lhc; }
                                y = y0; foreach (var l in right) { text(l, lw, W - lw, _fBody, DocInk, 0.93, false); y += lh; }
                                y = y0 + rh;
                                pg.Items.Add(new MItem { K = MI_RULE, R = new RectangleF(0, y - 5 * v, W, 1 * v), Ink = Amber, A = 0.18 });
                                break;
                            }
                            case "icon":
                            {
                                // a cursor of the legend: the in-game vector icon in its glass cell, its name, what it means
                                float cell = 64 * v, tx = cell + 22 * v, th = _fIconT.GetHeight(g) * 1.2f; var lines = Wrap(b.C, W - tx, m(_fBody));
                                float rh = Math.Max(cell, th + lines.Count * lh) + 16 * v;
                                keep(rh);
                                pg.Items.Add(new MItem { K = MI_FRAME, R = new RectangleF(0, y + 2 * v, cell, cell), Ink = Amber, A = 0.5 });
                                pg.Items.Add(new MItem { K = MI_ICON, S = b.A, R = new RectangleF(0, y + 2 * v, cell, cell) });
                                float y0 = y; text(b.B, tx, W - tx, _fIconT, AmberHi, 1.0, false); y += th;
                                foreach (var l in lines) { text(l, tx, W - tx, _fBody, DocInk, 0.93, false); y += lh; }
                                y = y0 + rh; break;
                            }
                            case "figicon":
                            {
                                // the manual's figure of a cursor: the icon and its caption, framed
                                float cell = 58 * v, pad = 12 * v, tx = cell + pad * 2 + 8 * v; var lines = Wrap(b.B, W - tx - pad, ms(_fCap, 1.5f * v));
                                float bh = Math.Max(cell + pad * 2, lines.Count * lhc + pad * 2);
                                keep(bh + lh * 2);
                                pg.Items.Add(new MItem { K = MI_FRAME, R = new RectangleF(0, y, W, bh), Ink = Amber, A = 0.4 });
                                pg.Items.Add(new MItem { K = MI_ICON, S = b.A, R = new RectangleF(pad, y + (bh - cell) / 2, cell, cell) });
                                float yy = y + (bh - lines.Count * lhc) / 2;
                                foreach (var l in lines) { pg.Items.Add(new MItem { K = MI_SPACED, S = l, R = new RectangleF(tx, yy, W - tx, lhc), F = _fCap, Ink = Amber, A = 0.95, Track = 1.5f * v }); yy += lhc; }
                                y += bh + 14 * v; break;
                            }
                            case "gap": y += lh * 0.7f; break;
                            case "break": if (y > 0) np(); break;
                        }
                    }
                    // a title page (only centred lines, as AZRAEL): the whole page centred, a little above the middle
                    if (ch.Blocks.Count > 0 && ch.Blocks.TrueForAll(q => q.Kind == "epigraph" || q.Kind == "caption" || q.Kind == "gap") && _pages.Count - 1 == ch.FirstPage)
                    {
                        float bottom = 0; foreach (var it in pg.Items) bottom = Math.Max(bottom, it.R.Bottom);
                        float dy = Math.Max(0, (H - bottom) * 0.4f);
                        foreach (var it in pg.Items)
                        {
                            float x = it.K == MI_RULE ? (W - it.R.Width) / 2 : it.R.X;
                            it.R = new RectangleF(x, it.R.Y + dy, it.R.Width, it.R.Height);
                            if (it.K == MI_SPACED || it.K == MI_TEXT) it.Center = true;
                        }
                    }
                }
            }
            _page = Math.Max(0, Math.Min(_page, _pages.Count - 1));
        }

        // ---- the classified files: decoded and scaled away from the window's thread ---------------------------------------
        void StartLoad(CDoc d, bool sync)
        {
            var area = _cArea.Size;
            if (d == null || d.Loading || (d.Ready && d.For == area)) return;
            d.Loading = true; d.Err = null; double zk = DocZoom;
            if (sync) LoadDoc(d, area, zk); else ThreadPool.QueueUserWorkItem(_ => LoadDoc(d, area, zk));
        }
        void LoadDoc(CDoc d, SizeF area, double zk)
        {
            Bitmap fit = null, zoom = null;
            try
            {
                using (var src = Image.FromFile(d.File))
                {
                    float k = Math.Min(area.Width / src.Width, area.Height / src.Height);
                    int fw = Math.Max(1, (int)(src.Width * k)), fh = Math.Max(1, (int)(src.Height * k));
                    fit = ScaleTo(src, fw, fh);
                    double kz = Math.Min(1.0, k * zk);
                    int zw = (int)(src.Width * kz), zh = (int)(src.Height * kz);
                    if (zw > fw * 1.15) zoom = ScaleTo(src, zw, zh);
                }
                lock (d)
                {
                    if (_docsGone) { fit.Dispose(); if (zoom != null) zoom.Dispose(); return; }
                    if (d.Fit != null) d.Fit.Dispose(); if (d.Zoom != null) d.Zoom.Dispose();
                    d.Fit = fit; d.Zoom = zoom; d.For = area; d.Ready = true;
                }
            }
            catch (Exception e) { d.Err = e.Message; if (fit != null) fit.Dispose(); if (zoom != null) zoom.Dispose(); }
            finally { d.Loading = false; _vNeed = true; }
        }
        static Bitmap ScaleTo(Image src, int w, int h)
        {
            var b = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(b))
            using (var ia = new ImageAttributes())
            {
                ia.SetWrapMode(WrapMode.TileFlipXY);          // (no dark seam at the edges)
                g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.CompositingMode = CompositingMode.SourceCopy;
                g.DrawImage(src, new Rectangle(0, 0, w, h), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel, ia);
            }
            return b;
        }
        void FreeDocs()
        {
            _docsGone = true;
            foreach (var d in _cdocs) lock (d) { if (d.Fit != null) d.Fit.Dispose(); if (d.Zoom != null) d.Zoom.Dispose(); d.Fit = d.Zoom = null; d.Ready = false; }
            FreeFonts();
        }

        // ---- opening, closing, turning --------------------------------------------------------------------------------
        void OpenView(int kind, double t)
        {
            _docsOpen = false; _docsAt = t;
            _view = kind; _viewLast = kind; _viewAt = t; _vsel = -1; _vNeed = true; LayerChanged(t);
            if (kind == V_MANUAL) { try { EnsurePages(); } catch (Exception e) { DocsFault(e, t); return; } _pageAt = t + 0.2; }
            else { _cdoc = 0; _zoom = false; _revealDoc = -1; StartLoad(CurDoc, false); for (int i = 1; i < _cdocs.Count; i++) StartLoad(_cdocs[i], false); }
        }
        void CloseView(double t)
        {
            if (_view == V_NONE) return;
            _viewLast = _view; _view = V_NONE; _viewShutAt = t; _zoom = false; _sel = R_DOCS; LayerChanged(t); Play(_tick);
        }
        void GoPage(int p, double t)
        {
            if (_pages == null) return;
            p = Math.Max(0, Math.Min(_pages.Count - 1, p)); if (p == _page) return;
            _page = p; _pageAt = t; _vNeed = true; Play(_tick);
        }
        void GoDoc(int i, double t)
        {
            i = Math.Max(0, Math.Min(_cdocs.Count - 1, i)); if (i == _cdoc) return;
            _cdoc = i; _zoom = false; _zoomAt = -9; _revealDoc = -1; _vNeed = true; Play(_confirm);
            StartLoad(CurDoc, false);
        }
        void ViewStep(int dir, double t) { if (_view == V_MANUAL) GoPage(_page + dir, t); else if (_view == V_CLASSIFIED) GoDoc(_cdoc + dir, t); }

        // ---- magnifying a classified page -----------------------------------------------------------------------------
        bool _zoom; double _zoomAt = -9, _panClock = -1; float _panX = 0.5f, _panY, _panTX = 0.5f, _panTY;
        static float Clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
        void ToggleZoom(double t, float px, float py)
        {
            var d = CurDoc; if (d == null || !d.Ready || d.Zoom == null) { Play(_tick); return; }
            _zoom = !_zoom; _zoomAt = t; _vNeed = true; Play(_tick);
            if (_zoom && px >= 0) { ZoomFollow(px, py); _panX = _panTX; _panY = _panTY; }
        }
        /// <summary>The pointer's place over the page picks what part of the magnified page shows (top = its top).</summary>
        void ZoomFollow(float x, float y)
        {
            if (!_zoom) return; var A = _cArea;
            _panTX = Clamp01((x - A.Left - A.Width * 0.15f) / (A.Width * 0.7f));
            _panTY = Clamp01((y - A.Top - A.Height * 0.12f) / (A.Height * 0.76f));
        }
        void PanStep(float d) { if (_zoom) { _panTY = Clamp01(_panTY + d); _vNeed = true; } }
        static RectangleF Lerp(RectangleF a, RectangleF b, double k)
        {
            float f = (float)k;
            return new RectangleF(a.X + (b.X - a.X) * f, a.Y + (b.Y - a.Y) * f, a.Width + (b.Width - a.Width) * f, a.Height + (b.Height - a.Height) * f);
        }
        RectangleF DocFit(CDoc d) { var A = _cArea; return new RectangleF((float)Math.Round(A.X + (A.Width - d.Fit.Width) / 2), (float)Math.Round(A.Y + (A.Height - d.Fit.Height) / 2), d.Fit.Width, d.Fit.Height); }
        double ZoomK(double t) { return _zoom ? Ease((t - _zoomAt) / 0.25) : 1 - Ease((t - _zoomAt) / 0.25); }
        RectangleF DocRect(CDoc d, double t)
        {
            var fit = DocFit(d); if (d.Zoom == null) return fit;
            var A = _cArea; float zw = d.Zoom.Width, zh = d.Zoom.Height;
            var zr = new RectangleF((float)Math.Round(zw <= A.Width ? A.X + (A.Width - zw) / 2 : A.X + (A.Width - zw) * _panX),
                                    (float)Math.Round(zh <= A.Height ? A.Y + (A.Height - zh) / 2 : A.Y + (A.Height - zh) * _panY), zw, zh);
            double k = ZoomK(t);
            return k <= 0 ? fit : k >= 1 ? zr : Lerp(fit, zr, k);
        }

        // ---- what to repaint this pass --------------------------------------------------------------------------------
        /// <summary>The reader's part of this pass: `full` = repaint it all; otherwise the rectangle of its moving parts (may be empty).</summary>
        Rectangle ViewDirty(double t, out bool full)
        {
            full = false;
            if (!ViewUp(t)) return Rectangle.Empty;
            int kind = _view != V_NONE ? _view : _viewLast;
            // the pan eases toward the pointer
            double dt = _panClock < 0 ? 0 : Math.Min(0.1, t - _panClock); _panClock = t;
            bool panning = false;
            if (_zoom && kind == V_CLASSIFIED)
            {
                float kk = (float)Math.Min(1, dt * 11);
                if (Math.Abs(_panTY - _panY) > 0.0004f || Math.Abs(_panTX - _panX) > 0.0004f) { _panY += (_panTY - _panY) * kk; _panX += (_panTX - _panX) * kk; panning = true; }
            }
            if (t - _viewAt < 0.45 || t - _viewShutAt < 0.45 || _vNeed) { full = true; return new Rectangle(0, 0, _W, _H); }
            var r = RectangleF.Empty; Action<RectangleF> add = q => { r = r.IsEmpty ? q : RectangleF.Union(r, q); };
            if (kind == V_MANUAL)
            {
                if (t - _pageAt < 0.4) add(_mText);
                if (_page > 0) add(_mPrev);
                if (_pages != null && _page < _pages.Count - 1) add(_mNext);
                if (_pages != null && _page < _pages.Count) foreach (var it in _pages[_page].Items) if (it.K == MI_ICON) { var q = it.R; q.Offset(_mText.Left, _mText.Top); add(q); }
            }
            else
            {
                var d = CurDoc;
                if (d != null && d.Ready && _revealDoc != _cdoc) { _revealDoc = _cdoc; _revealAt = t; }
                if (d == null || !d.Ready || t - _revealAt < 0.75 || t - _zoomAt < 0.3 || panning) add(_cArea);
                if (_cdoc > 0) add(_cPrev);
                if (_cdoc < _cdocs.Count - 1) add(_cNext);
            }
            if (r.IsEmpty) return Rectangle.Empty;
            var rr = Rectangle.Round(r); rr.Inflate(6, 6);
            return Rectangle.Intersect(rr, new Rectangle(0, 0, _W, _H));
        }

        // ---- input ------------------------------------------------------------------------------------------------------
        int DocsHit(float x, float y) { for (int i = 0; i < DROWS; i++) if (_docsRect[i].Contains(x, y)) return i; return -1; }
        int ViewHit(float x, float y)
        {
            if (_view == V_MANUAL)
            {
                if (_mBack.Contains(x, y)) return VB_BACK;
                if (_page > 0 && _mPrev.Contains(x, y)) return VB_PREV;
                if (_pages != null && _page < _pages.Count - 1 && _mNext.Contains(x, y)) return VB_NEXT;
                for (int i = 0; i < _tocRect.Length; i++) if (_tocRect[i].Contains(x, y)) return VB_TOC + i;
                return -1;
            }
            if (_view == V_CLASSIFIED)
            {
                if (_cBack.Contains(x, y)) return VB_BACK;
                if (_cdoc > 0 && _cPrev.Contains(x, y)) return VB_PREV;
                if (_cdoc < _cdocs.Count - 1 && _cNext.Contains(x, y)) return VB_NEXT;
                var d = CurDoc;
                if (d != null && d.Ready && d.Zoom != null && _cArea.Contains(x, y) && DocRect(d, 1e9).Contains(x, y)) return VB_DOC;
                return -1;
            }
            return -1;
        }
        RectangleF ViewRect(int code)
        {
            bool man = _view == V_MANUAL;
            if (code == VB_BACK) return man ? _mBack : _cBack;
            if (code == VB_PREV) return man ? _mPrev : _cPrev;
            if (code == VB_NEXT) return man ? _mNext : _cNext;
            if (code >= VB_TOC && code - VB_TOC < _tocRect.Length) return _tocRect[code - VB_TOC];
            return man ? _mText : _cArea;
        }
        float _lastPtrX = -1, _lastPtrY = -1;
        void ViewActivate(int code, double t)
        {
            if (code == VB_BACK) CloseView(t);
            else if (code == VB_PREV) ViewStep(-1, t);
            else if (code == VB_NEXT) ViewStep(1, t);
            else if (code == VB_DOC) ToggleZoom(t, _lastPtrX, _lastPtrY);
            else if (code >= VB_TOC && _chapters != null && code - VB_TOC < _chapters.Count) GoPage(_chapters[code - VB_TOC].FirstPage, t);
        }
        /// <summary>A key while a reader is up (true = it was the reader's).</summary>
        bool ViewKey(int vk, double t)
        {
            if (_view == V_NONE) return false;
            bool man = _view == V_MANUAL;
            switch (vk)
            {
                case 0x1B: case 0x08: CloseView(t); break;                                       // Esc, Backspace: the main menu
                case 0x25: case 0x21: ViewStep(-1, t); break;                                    // Left, Page Up
                case 0x27: case 0x22: ViewStep(1, t); break;                                     // Right, Page Down
                case 0x26: if (man) ViewStep(-1, t); else PanStep(-0.14f); break;                // Up / wheel up
                case 0x28: if (man) ViewStep(1, t); else PanStep(0.14f); break;                  // Down / wheel down
                case 0x24: if (man) GoPage(0, t); else GoDoc(0, t); break;                       // Home
                case 0x23: if (man) GoPage(_pages == null ? 0 : _pages.Count - 1, t); else GoDoc(_cdocs.Count - 1, t); break;   // End
                case 0x0D: case 0x20: if (_vsel >= 0) ViewActivate(_vsel, t); else if (!man) ToggleZoom(t, -1, -1); break;
            }
            return true;
        }
        bool DocsKey(int vk, double t)
        {
            if (!_docsOpen) return false;
            if (vk == 0x26) { _dsel = (_dsel + DROWS - 1) % DROWS; _selAt = t; Play(_tick); }
            else if (vk == 0x28) { _dsel = (_dsel + 1) % DROWS; _selAt = t; Play(_tick); }
            else if (vk == 0x0D || vk == 0x20) DocsActivate(t);
            else if (vk == 0x1B || vk == 0x08) { _docsOpen = false; _docsAt = t; LayerChanged(t); Play(_tick); }
            return true;
        }
        void DocsActivate(double t)
        {
            if (_dsel == D_BACK) { _docsOpen = false; _docsAt = t; LayerChanged(t); Play(_tick); return; }
            bool ok = _dsel == D_MAN ? ManualReady : ClassifiedReady;
            if (!ok) { Play(_tick); _docsSoonAt = t; return; }
            Play(_confirm); OpenView(_dsel == D_MAN ? V_MANUAL : V_CLASSIFIED, t);
        }
        void OpenDocsPanel(double t)
        {
            Play(_confirm); _docsOpen = true; _docsAt = t; LayerChanged(t);
            _dsel = ManualReady ? D_MAN : ClassifiedReady ? D_CLS : D_BACK;
        }

        // ---- drawing ----------------------------------------------------------------------------------------------------
        void GlassPanel(Graphics g, RectangleF pr, double a, RectangleF clip, float k)
        {
            using (var gb = new SolidBrush(C(0x050302, 0.9 * a))) g.FillRectangle(gb, pr);
            var cr = RectangleF.Intersect(pr, clip); float st = 3 * k;
            if (cr.Height > 0)
                using (var ln = new SolidBrush(C(0x000000, 0.22 * a)))
                    for (float yy = pr.Top + (float)Math.Ceiling((cr.Top - pr.Top) / st) * st; yy < cr.Bottom; yy += st) g.FillRectangle(ln, cr.Left, yy, cr.Width, Math.Max(1f, k));
            Brackets(g, pr, C(Amber, 0.9 * a), 22 * k, Math.Max(2f, 2.4f * k));
        }
        /// <summary>A button of the readers (BACK): the slot list's look.</summary>
        void ViewButton(Graphics g, RectangleF r, string label, bool sel, double a, double t)
        {
            if (sel)
            {
                using (var sb = new SolidBrush(C(Amber, 0.16 * a))) g.FillRectangle(sb, r);
                double k = EaseBack((t - _selAt) / 0.25); var br = r; br.Inflate((float)(1 - k) * 24 * _vs, (float)(1 - k) * 8 * _vs);
                Brackets(g, br, C(Amber, 0.95 * a), 10 * _vs, Math.Max(2f, 2f * _vs));
            }
            else using (var p = new Pen(C(AmberDim, 0.55 * a), Math.Max(1f, 1.2f * _vs))) g.DrawRectangle(p, r.X, r.Y, r.Width, r.Height);
            using (var bb = new SolidBrush(C(sel ? AmberHi : Amber, a))) { float bw = Spaced(g, label, _fUi, null, 0, 0, 5 * _vs, true); Spaced(g, label, _fUi, bb, r.Left + (r.Width - bw) / 2, r.Top + (r.Height - _fUi.Height) / 2, 5 * _vs, false); }
        }
        /// <summary>An arrow pad: the game's own door arrow (the vector icon), looping, in a glass pad; dim when there is nowhere to go.</summary>
        void ArrowPad(Graphics g, RectangleF r, bool right, bool on, bool sel, double a, double t, float u)
        {
            using (var gb = new SolidBrush(C(sel ? Amber : 0x050302, (sel ? 0.16 : 0.55) * a))) g.FillRectangle(gb, r);
            Brackets(g, r, C(on ? (sel ? AmberHi : Amber) : AmberDim, (on ? 0.9 : 0.3) * a), 12 * _vs, Math.Max(2f, 2f * _vs));
            float x0 = r.Left + r.Width / 2 - (right ? 22f : 8f) * u, y0 = r.Top + r.Height / 2 - 15.5f * u;     // (each arrow's own middle in its grid)
            double ta = on ? t - _viewAt + (sel ? 0.6 : 0) : 3.0;
            TitleShapes.Draw(g, right ? "right" : "left", x0, y0, u, ta, t, (on ? 1.0 : 0.25) * a);
        }

        // THE PANEL: OPTIONS' look; each row a title, a line under it and a tag; BACK below
        void DrawDocsPanel(Graphics g, double t)
        {
            double a = _docsOpen ? Ease((t - _docsAt) / 0.3) : 1 - Ease((t - _docsAt) / 0.3);
            double leave = _pickAt >= 0 ? Ease((t - _pickAt) / 0.35) : 0; a *= 1 - leave;
            if (_view != V_NONE) a *= 1 - Ease((t - _viewAt) / 0.2);
            if (a <= 0.01) return;
            var p = _docsPanel; float grow = (float)(1 - Ease((t - _docsAt) / 0.3)) * (_docsOpen ? 1 : 0); var pr = p; pr.Inflate(-grow * 30 * _s, -grow * 30 * _s);
            using (var gb = new SolidBrush(C(0x050302, 0.84 * a))) g.FillRectangle(gb, pr);
            using (var ln = new SolidBrush(C(0x000000, 0.22 * a))) for (float yy = pr.Top; yy < pr.Bottom; yy += 3 * _s) g.FillRectangle(ln, pr.Left, yy, pr.Width, Math.Max(1f, _s));
            Brackets(g, pr, C(Amber, 0.9 * a), 22 * _s, Math.Max(2f, 2.4f * _s));
            using (var hf = new Font("Consolas", 22 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var rf = new Font("Consolas", 20 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var sf = new Font("Consolas", 14 * _s, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                using (var hb = new SolidBrush(C(AmberHi, a))) Spaced(g, "RAPTOR H.U.D. // ARCHIVE // RAPTOR DOCS", hf, hb, pr.Left + 36 * _s, pr.Top + 30 * _s, 3 * _s, false);
                using (var rl = new SolidBrush(C(Amber, 0.5 * a))) g.FillRectangle(rl, pr.Left + 36 * _s, pr.Top + 70 * _s, pr.Width - 72 * _s, Math.Max(1f, 1.2f * _s));
                for (int i = 0; i < 2; i++)
                {
                    var r = _docsRect[i]; bool sel = _dsel == i, ok = i == D_MAN ? ManualReady : ClassifiedReady;
                    if (sel)
                    {
                        using (var sb = new SolidBrush(C(Amber, (ok ? 0.16 : 0.07) * a))) g.FillRectangle(sb, r);
                        double k = EaseBack((t - _selAt) / 0.25); var br = r; br.Inflate((float)(1 - k) * 24 * _s, (float)(1 - k) * 8 * _s);
                        Brackets(g, br, C(ok ? Amber : AmberDim, 0.95 * a), 10 * _s, Math.Max(2f, 2f * _s));
                    }
                    string title = i == D_MAN ? "MANUAL" : "CLASSIFIED DOCS";
                    string line = !ok ? "NOT INSTALLED" : i == D_MAN ? string.Format("MS-2 HELMET  //  {0}  //  {1} CHAPTERS", _manualTitle.Replace("MS-2 ", ""), _chapters.Count)
                                                                     : string.Format("{0} FILE{1}  //  RECOVERED PRINT-OUTS", _cdocs.Count, _cdocs.Count == 1 ? "" : "S");
                    string tag = i == D_MAN ? "LIBRARY" : "RAPTOR EYES ONLY"; int tagInk = i == D_MAN ? Amber : DocRed;     // (Josh, 2026-10-11: was EYES ONLY)
                    using (var tb = new SolidBrush(C(!ok ? AmberDim : sel ? AmberHi : Amber, (ok ? 1 : 0.6) * a))) Spaced(g, title, rf, tb, r.Left + 18 * _s, r.Top + 16 * _s, 3 * _s, false);
                    using (var lb = new SolidBrush(C(sel ? Amber : AmberDim, (ok ? 0.9 : 0.6) * a))) Spaced(g, line, sf, lb, r.Left + 18 * _s, r.Top + 58 * _s, 2 * _s, false);
                    bool flash = !ok && sel && t - _docsSoonAt < 1.6; string tg = flash ? "OFFLINE" : tag;
                    double fa = flash && (t - _docsSoonAt) < 0.14 ? (Hash(11 + i, (int)(t * 50)) > 0.4 ? 1 : 0.2) : 1;
                    float tw = Spaced(g, tg, sf, null, 0, 0, 2 * _s, true), tx = r.Right - 18 * _s - tw, ty = r.Top + 19 * _s;
                    using (var tp = new Pen(C(ok ? tagInk : AmberDim, 0.8 * fa * a), Math.Max(1f, 1.2f * _s))) g.DrawRectangle(tp, tx - 8 * _s, ty - 4 * _s, tw + 16 * _s, sf.Height + 8 * _s);
                    using (var tgb = new SolidBrush(C(ok ? tagInk : AmberDim, 0.9 * fa * a))) Spaced(g, tg, sf, tgb, tx, ty, 2 * _s, false);
                }
                var rb = _docsRect[D_BACK]; bool bsel = _dsel == D_BACK;
                if (bsel)
                {
                    using (var sb = new SolidBrush(C(Amber, 0.16 * a))) g.FillRectangle(sb, rb);
                    double k = EaseBack((t - _selAt) / 0.25); var br = rb; br.Inflate((float)(1 - k) * 24 * _s, (float)(1 - k) * 8 * _s);
                    Brackets(g, br, C(Amber, 0.95 * a), 10 * _s, Math.Max(2f, 2f * _s));
                }
                using (var bb = new SolidBrush(C(bsel ? AmberHi : Amber, a))) { float bw = Spaced(g, "BACK", rf, null, 0, 0, 5 * _s, true); Spaced(g, "BACK", rf, bb, rb.Left + (rb.Width - bw) / 2, rb.Top + (rb.Height - rf.Height) / 2, 5 * _s, false); }
            }
        }

        /// <summary>The reader in front (or fading out), drawn within `clip`.</summary>
        void DrawView(Graphics g, double t, RectangleF clip, bool full)
        {
            if (!ViewUp(t)) return;
            double a = ViewAlpha(t); if (a <= 0.004) { if (full) _vNeed = false; return; }
            EnsureFonts();
            var tr = g.TextRenderingHint; var sm = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var db = new SolidBrush(C(0x000000, 0.82 * a))) g.FillRectangle(db, clip);
            int kind = _view != V_NONE ? _view : _viewLast;
            if (kind == V_MANUAL) DrawManual(g, t, a, clip); else DrawClassified(g, t, a, clip);
            g.TextRenderingHint = tr; g.SmoothingMode = sm;
            if (full) _vNeed = false;
        }
        RectangleF Opening(RectangleF p, double t) { float grow = _view != V_NONE ? (float)(1 - Ease((t - _viewAt) / 0.3)) : 0; p.Inflate(-grow * 30 * _vs, -grow * 30 * _vs); return p; }

        void DrawManual(Graphics g, double t, double a, RectangleF clip)
        {
            float v = _vs; var P = Opening(_mPanel, t);
            GlassPanel(g, P, a, clip, v);
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            float x0 = _mPanel.Left + 36 * v;
            using (var hb = new SolidBrush(C(AmberHi, a))) Spaced(g, "RAPTOR H.U.D.  //  LIBRARY  //  " + _manualTitle, _fUiH, hb, x0, _mPanel.Top + 30 * v, 3 * v, false);
            string st = "STOLLAND LIBRARY  //  ONLINE"; float sw = Spaced(g, st, _fUiS, null, 0, 0, 2 * v, true);
            using (var sb = new SolidBrush(C(AmberDim, 0.9 * a))) Spaced(g, st, _fUiS, sb, _mPanel.Right - 40 * v - sw, _mPanel.Top + 36 * v, 2 * v, false);
            using (var rl = new SolidBrush(C(Amber, 0.5 * a))) g.FillRectangle(rl, x0, _mPanel.Top + 72 * v, _mPanel.Width - 72 * v, Math.Max(1f, 1.2f * v));
            if (!ManualReady || _pages == null || _pages.Count == 0)
            {
                using (var eb = new SolidBrush(C(AmberDim, a))) Spaced(g, "LIBRARY FILE NOT INSTALLED", _fUi, eb, _mText.Left, _mText.Top, 3 * v, false);
                ViewButton(g, _mBack, "BACK", _vsel == VB_BACK, a, t); return;
            }
            var page = _pages[Math.Min(_page, _pages.Count - 1)];
            // the contents, down the left
            using (var cb = new SolidBrush(C(AmberDim, 0.9 * a))) Spaced(g, "CONTENTS", _fUiS, cb, x0, _mPanel.Top + 104 * v, 3 * v, false);
            using (var dl = new SolidBrush(C(Amber, 0.25 * a))) g.FillRectangle(dl, _mText.Left - 34 * v, _mText.Top - 4 * v, Math.Max(1f, 1.2f * v), _mPanel.Bottom - 26 * v - _mText.Top);
            for (int i = 0; i < _tocRect.Length; i++)
            {
                var r = _tocRect[i]; if (!r.IntersectsWith(clip)) continue;
                bool cur = page.Chapter == i, hov = _vsel == VB_TOC + i;
                if (cur || hov)
                {
                    using (var sb = new SolidBrush(C(Amber, (cur ? 0.15 : 0.07) * a))) g.FillRectangle(sb, r);
                    if (cur) Brackets(g, r, C(Amber, 0.9 * a), 8 * v, Math.Max(1.5f, 1.8f * v));
                }
                float ty = r.Top + (r.Height - _fUiS.Height) / 2;
                using (var nb = new SolidBrush(C(cur ? Amber : AmberDim, 0.85 * a))) Spaced(g, string.Format("{0:00}", i + 1), _fUiS, nb, r.Left + 12 * v, ty, 1 * v, false);
                using (var tb = new SolidBrush(C(cur || hov ? AmberHi : Amber, (cur || hov ? 1 : 0.78) * a))) Spaced(g, _chapters[i].Name, _fUiS, tb, r.Left + 50 * v, ty, 2 * v, false);
            }
            // the page: it comes up behind a bright line running down the column
            double pk = Ease((t - _pageAt) / 0.32), pa = a * (0.25 + 0.75 * pk);
            float reveal = _mText.Top + (_mText.Height + 20 * v) * (float)pk;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
            var fmt = StringFormat.GenericTypographic;
            foreach (var it in page.Items)
            {
                var r = it.R; r.Offset(_mText.Left, _mText.Top);
                if (!r.IntersectsWith(clip)) continue;
                double ia = pa * it.A * (r.Top > reveal ? 0.25 : 1);
                switch (it.K)
                {
                    case MI_TEXT:
                        using (var b = new SolidBrush(C(it.Ink, ia)))
                        {
                            float x = r.Left; if (it.Center) x += (r.Width - g.MeasureString(it.S, it.F, new PointF(0, 0), fmt).Width) / 2;
                            g.DrawString(it.S, it.F, b, x, r.Top, fmt);
                        }
                        break;
                    case MI_SPACED:
                        using (var b = new SolidBrush(C(it.Ink, ia)))
                        {
                            float x = r.Left; if (it.Center) x += (r.Width - Spaced(g, it.S, it.F, null, 0, 0, it.Track, true)) / 2;
                            Spaced(g, it.S, it.F, b, x, r.Top, it.Track, false);
                        }
                        break;
                    case MI_RULE: using (var b = new SolidBrush(C(it.Ink, ia))) g.FillRectangle(b, r); break;
                    case MI_BAR: using (var b = new SolidBrush(C(it.Ink, ia))) g.FillRectangle(b, r); break;
                    case MI_DIAMOND:
                        using (var b = new SolidBrush(C(it.Ink, ia))) { float cx = r.Left + r.Width / 2, cy = r.Top + r.Height / 2, d = r.Width / 2; g.FillPolygon(b, new[] { new PointF(cx, cy - d), new PointF(cx + d, cy), new PointF(cx, cy + d), new PointF(cx - d, cy) }); }
                        break;
                    case MI_FRAME:
                        using (var gb = new SolidBrush(C(0x140A02, 0.6 * pa))) g.FillRectangle(gb, r);
                        using (var p = new Pen(C(it.Ink, ia), Math.Max(1f, 1.2f * v))) g.DrawRectangle(p, r.X, r.Y, r.Width, r.Height);
                        Brackets(g, r, C(it.Ink, Math.Min(1, ia * 1.8)), 8 * v, Math.Max(1.5f, 1.8f * v));
                        break;
                    case MI_ICON:
                    {
                        float u = r.Width / 30f * 0.82f, ix = r.Left + (r.Width - 30 * u) / 2, iy = r.Top + (r.Height - 30 * u) / 2;
                        TitleShapes.Draw(g, it.S, ix, iy, u, Math.Max(0, t - _pageAt), t, pa);
                        break;
                    }
                }
            }
            if (pk < 1 && reveal < _mText.Bottom + 10 * v)
                using (var lb = new SolidBrush(C(AmberHi, 0.6 * (1 - pk) * a))) g.FillRectangle(lb, _mText.Left - 8 * v, reveal, _mText.Width + 16 * v, Math.Max(1f, 2f * v));
            // the footer: the page arrows, the count between; BACK under the contents
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            ArrowPad(g, _mPrev, false, _page > 0, _vsel == VB_PREV, a, t, 1.55f * v);
            ArrowPad(g, _mNext, true, _page < _pages.Count - 1, _vsel == VB_NEXT, a, t, 1.55f * v);
            string cnt = string.Format("{0:00}  /  {1:00}", _page + 1, _pages.Count); float cw = Spaced(g, cnt, _fUi, null, 0, 0, 3 * v, true);
            float ccx = (_mPrev.Right + _mNext.Left) / 2;
            using (var nb = new SolidBrush(C(Amber, a))) Spaced(g, cnt, _fUi, nb, ccx - cw / 2, _mPrev.Top + 8 * v, 3 * v, false);
            string pl = "PAGE"; float pw = Spaced(g, pl, _fUiS, null, 0, 0, 4 * v, true);
            using (var pb = new SolidBrush(C(AmberDim, 0.85 * a))) Spaced(g, pl, _fUiS, pb, ccx - pw / 2, _mPrev.Top + 36 * v, 4 * v, false);
            ViewButton(g, _mBack, "BACK", _vsel == VB_BACK, a, t);
        }

        void DrawClassified(Graphics g, double t, double a, RectangleF clip)
        {
            float v = _vs; var P = Opening(_cPanel, t);
            GlassPanel(g, P, a, clip, v);
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            float x0 = _cPanel.Left + 36 * v;
            using (var hb = new SolidBrush(C(AmberHi, a))) Spaced(g, "RAPTOR H.U.D.  //  ARCHIVE  //  CLASSIFIED", _fUiH, hb, x0, _cPanel.Top + 28 * v, 3 * v, false);
            string tag = "RAPTOR EYES ONLY"; float tw = Spaced(g, tag, _fUiS, null, 0, 0, 4 * v, true), tx = _cPanel.Right - 46 * v - tw, ty = _cPanel.Top + 32 * v;
            using (var tp = new Pen(C(DocRed, 0.85 * a), Math.Max(1f, 1.4f * v))) g.DrawRectangle(tp, tx - 10 * v, ty - 6 * v, tw + 20 * v, _fUiS.Height + 12 * v);
            using (var tb = new SolidBrush(C(DocRed, a))) Spaced(g, tag, _fUiS, tb, tx, ty, 4 * v, false);
            using (var rl = new SolidBrush(C(Amber, 0.5 * a))) g.FillRectangle(rl, x0, _cPanel.Top + 70 * v, _cPanel.Width - 72 * v, Math.Max(1f, 1.2f * v));
            var d = CurDoc;
            if (d != null && _cArea.IntersectsWith(clip))
            {
                if (d.Ready && d.Fit != null)
                    lock (d)
                    {
                        if (d.Fit != null)
                        {
                            var r = DocRect(d, t); double zk = ZoomK(t);
                            var bmp = zk > 0 && d.Zoom != null ? d.Zoom : d.Fit;
                            var gs = g.Save();
                            g.SetClip(_cArea, CombineMode.Intersect);
                            double rv = _revealDoc == _cdoc ? Ease((t - _revealAt) / 0.6) : 0;
                            float shown = r.Height * (float)rv;
                            g.SetClip(new RectangleF(r.Left - 2, r.Top - 2, r.Width + 4, shown + 2), CombineMode.Intersect);
                            bool exact = Math.Abs(r.Width - bmp.Width) < 0.5f && Math.Abs(r.Height - bmp.Height) < 0.5f;
                            g.InterpolationMode = exact ? InterpolationMode.NearestNeighbor : InterpolationMode.Bilinear; g.PixelOffsetMode = PixelOffsetMode.Half;
                            using (var ia = new ImageAttributes())
                            {
                                var cm = new ColorMatrix(); cm.Matrix33 = (float)a; ia.SetColorMatrix(cm);
                                var dst = exact ? new Rectangle((int)Math.Round(r.X), (int)Math.Round(r.Y), bmp.Width, bmp.Height) : Rectangle.Round(r);
                                g.DrawImage(bmp, dst, 0, 0, bmp.Width, bmp.Height, GraphicsUnit.Pixel, ia);
                            }
                            // shown on the visor: faint scan lines over it
                            var vis = RectangleF.Intersect(RectangleF.Intersect(r, _cArea), clip); float st = 3 * v;
                            if (vis.Height > 0) using (var ln = new SolidBrush(C(0x000000, 0.05 * a))) for (float yy = r.Top + (float)Math.Ceiling((vis.Top - r.Top) / st) * st; yy < vis.Bottom; yy += st) g.FillRectangle(ln, vis.Left, yy, vis.Width, Math.Max(1f, v));
                            g.Restore(gs);
                            if (rv < 1)
                                using (var lb = new SolidBrush(C(AmberHi, 0.85 * (1 - rv) * a))) g.FillRectangle(lb, r.Left - 10 * v, r.Top + shown - 1.5f * v, r.Width + 20 * v, 3 * v);
                            if (zk < 0.5) Brackets(g, RectangleF.Inflate(r, 10 * v, 10 * v), C(Amber, 0.85 * a * (1 - 2 * zk)), 18 * v, Math.Max(2f, 2f * v));
                        }
                    }
                else DrawDecrypting(g, t, a, d);
            }
            // the arrow pads, the file's name, BACK
            ArrowPad(g, _cPrev, false, _cdoc > 0, _vsel == VB_PREV, a, t, 3.0f * v);
            ArrowPad(g, _cNext, true, _cdoc < _cdocs.Count - 1, _vsel == VB_NEXT, a, t, 3.0f * v);
            if (d != null)
            {
                float fy = _cPanel.Bottom - 86 * v, cx = _cArea.Left + _cArea.Width / 2;
                string tt = d.Title; float ttw = Spaced(g, tt, _fUi, null, 0, 0, 3 * v, true);
                using (var b = new SolidBrush(C(AmberHi, a))) Spaced(g, tt, _fUi, b, cx - ttw / 2, fy, 3 * v, false);
                if (d.Sub.Length > 0) { float ssw = Spaced(g, d.Sub, _fUiS, null, 0, 0, 2 * v, true); using (var b = new SolidBrush(C(AmberDim, 0.95 * a))) Spaced(g, d.Sub, _fUiS, b, cx - ssw / 2, fy + 32 * v, 2 * v, false); }
                string cnt = string.Format("FILE {0:00} / {1:00}", _cdoc + 1, _cdocs.Count), hint = d.Zoom == null ? "" : _zoom ? "MOVE TO READ  //  CLICK TO RETURN" : "CLICK THE PAGE TO MAGNIFY";
                float cw = Spaced(g, cnt, _fUi, null, 0, 0, 3 * v, true);
                using (var b = new SolidBrush(C(Amber, a))) Spaced(g, cnt, _fUi, b, _cPanel.Right - 40 * v - cw, fy, 3 * v, false);
                if (hint.Length > 0) { float hw = Spaced(g, hint, _fUiS, null, 0, 0, 2 * v, true); using (var b = new SolidBrush(C(AmberDim, 0.9 * a))) Spaced(g, hint, _fUiS, b, _cPanel.Right - 40 * v - hw, fy + 32 * v, 2 * v, false); }
            }
            ViewButton(g, _cBack, "BACK", _vsel == VB_BACK, a, t);
        }
        // a file not yet decoded: the visor decrypting it (the memory core's bar and stream)
        void DrawDecrypting(Graphics g, double t, double a, CDoc d)
        {
            float v = _vs, w = Math.Min(620 * v, _cArea.Width * 0.8f), x0 = _cArea.Left + (_cArea.Width - w) / 2, y0 = _cArea.Top + _cArea.Height / 2 - 70 * v;
            string head = d.Err != null ? "FILE DAMAGED" : string.Format("DECRYPTING FILE {0:00}{1}", _cdoc + 1, new string('.', 1 + (int)(t * 3) % 3));
            using (var b = new SolidBrush(C(d.Err != null ? DocRed : AmberHi, a))) Spaced(g, head, _fUiH, b, x0, y0, 3 * v, false);
            float by0 = y0 + 48 * v, bh = 30 * v;
            using (var p = new Pen(C(AmberDim, 0.8 * a), Math.Max(1f, v))) g.DrawRectangle(p, x0, by0, w, bh);
            int segs = 28; float sw = (w - 8 * v) / segs; int lit = d.Err != null ? 0 : (int)((t * 18) % (segs + 8));
            using (var sb = new SolidBrush(C(Amber, 0.9 * a))) for (int i = Math.Max(0, lit - 8); i < Math.Min(segs, lit); i++) g.FillRectangle(sb, x0 + 4 * v + i * sw, by0 + 4 * v, sw - 3 * v, bh - 8 * v);
            int k = (int)(t * 14);
            using (var hb = new SolidBrush(C(AmberDim, 0.6 * a)))
                for (int j = 0; j < 4; j++)
                {
                    var sb2 = new StringBuilder(); sb2.AppendFormat("{0:X6}  ", 0x2000 + (k + j) * 0x30);
                    for (int bb = 0; bb < 12; bb++) sb2.AppendFormat("{0:X2} ", (int)(Hash((k + j) * 17 + _cdoc, bb) * 255));
                    g.DrawString(sb2.ToString(), _fMono, hb, x0, by0 + bh + 18 * v + j * 20 * v);
                }
            if (d.Err != null) using (var b = new SolidBrush(C(AmberDim, a))) g.DrawString(d.Err, _fMono, b, x0, by0 + bh + 110 * v);
        }

        /// <summary>A fault in RAPTOR DOCS must not take the title with it (the loop's own catch closes the window, which
        /// releases the game into its intro): note it, close the docs and carry on.</summary>
        void DocsFault(Exception e, double t)
        {
            Note = (Note.Length > 0 ? Note + "; " : "") + "raptor docs: " + e.GetType().Name + ": " + e.Message;
            if (_view != V_NONE) { _viewLast = _view; _view = V_NONE; _viewShutAt = t - 1; }
            _docsOpen = false; _docsAt = t - 1; _vNeed = true; _needFull = true; LayerChanged(t);
        }

        // ---- offline ----------------------------------------------------------------------------------------------------
        /// <summary>OFFLINE: Preview with the RAPTOR DOCS panel up (PreviewDsel selected), or a reader (PreviewView 1 manual,
        /// 2 classified) at page / file PreviewPage, magnified (PreviewZoom, panned to PreviewPan), PreviewVsel hovered.</summary>
        public bool PreviewDocs, PreviewZoom; public int PreviewDsel, PreviewView, PreviewPage, PreviewVsel = -1; public float PreviewPan = 0.3f;
        /// <summary>OFFLINE: the manual's page count at w x h (laid out as the reader would).</summary>
        public int TestPageCount(int w, int h) { _W = w; _H = h; _s = h / 1080f; _vs = Math.Min(w / 1920f, h / 1080f); LoadDocsIndex(); LayoutViewer(); _pages = null; EnsurePages(); return _pages == null ? 0 : _pages.Count; }
        void PreviewDocsState(double t)
        {
            if (PreviewDocs) { _docsOpen = true; _docsAt = t - 1; _dsel = PreviewDsel; }
            if (PreviewView == V_NONE) return;
            _view = _viewLast = PreviewView; _viewAt = t - 1; _vsel = PreviewVsel;
            if (_view == V_MANUAL) { EnsurePages(); _page = Math.Max(0, Math.Min(PreviewPage, _pages == null ? 0 : _pages.Count - 1)); _pageAt = t - 3; }
            else
            {
                _cdoc = Math.Max(0, Math.Min(PreviewPage, _cdocs.Count - 1)); StartLoad(CurDoc, true); _revealDoc = _cdoc; _revealAt = t - 2;
                if (PreviewZoom) { _zoom = true; _zoomAt = t - 1; _panY = _panTY = PreviewPan; _panX = _panTX = 0.5f; }
            }
        }
        void PreviewDocsDraw(Graphics g, double t)
        {
            if (PreviewDocs) DrawDocsPanel(g, t);
            if (PreviewView != V_NONE) DrawView(g, t, new RectangleF(0, 0, _W, _H), true);
        }
    }
}
