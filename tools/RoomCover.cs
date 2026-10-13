// RoomCover.cs -- THE VISOR'S LOADING COVER on entering a room (Josh, 2026-10-12: "When entering a room, I will see the 256
// color version of the game (non gpu engine) for a good while as the textures load ... we need a loading interface, similar to
// the base game, while these textures load on entering a room. I want it to be a simple in world loading display on the
// viewport, top center. Something like 'Raptor H.U.D - Analyzing Environment...' with a loading number counting up to 100% as
// the room loads. The key is we shouldnt see the 256 version.")
//
// The picture the watcher presents through the card's window (GpuRaster.PresentPicture, held fresh: Overlay.HoldFreshUntil)
// from the moment a room change is seen until the new room's first frame is ready: the visor gone dark, and at the top of the
// view, centred, the readout -- RAPTOR H.U.D. // ANALYZING ENVIRONMENT, a percentage counting up, a segmented bar -- with a
// faint scan sweeping down the glass. The game keeps drawing underneath (the watcher's engine-draw pulse on every room change
// needs that), hidden. Where the load is (0..1) is the watcher's: the game's own frames of the new room, the room recognised,
// its painted textures decoded (Raster.LoadRgbAsync), then uploaded to the card (GpuRaster.UploadSome).
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace AztTool
{
    public sealed class RoomCover : IDisposable
    {
        public int Amber = 0xFFB040, AmberHi = 0xFFE3A6, AmberDim = 0x9A6418;
        public string Title = "RAPTOR H.U.D.  //  ANALYZING ENVIRONMENT";
        int[] _buf; int _w, _h; double _shown; Font _fTitle, _fPct; float _fontsFor;

        /// <summary>What the readout shows now (0..1): it counts up towards the load, never down.</summary>
        public double Shown { get { return _shown; } }
        /// <summary>Back to 0 for the next room.</summary>
        public void Reset() { _shown = 0; }

        static Color C(int rgb, double a) { return Color.FromArgb(Math.Max(0, Math.Min(255, (int)(255 * a))), (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
        static float Spaced(Graphics g, string s, Font f, Brush b, float x, float y, float track)
        {
            float w = 0; var fmt = StringFormat.GenericTypographic;
            foreach (char ch in s)
            {
                string c = ch.ToString(); float cw = ch == ' ' ? g.MeasureString("n", f, 1000, fmt).Width : g.MeasureString(c, f, 1000, fmt).Width;
                if (b != null) g.DrawString(c, f, b, x + w, y, fmt);
                w += cw + track;
            }
            return w - track;
        }

        /// <summary>The cover for a picture w x h whose top viewRows rows are the game's view, t s after it went up, the load
        /// `target` (0..1) done. The buffer is reused: present it before the next call.</summary>
        public int[] Render(int w, int h, int viewRows, double t, double target)
        {
            if (_buf == null || _w != w || _h != h) { _buf = new int[w * h]; _w = w; _h = h; }
            double tgt = Math.Max(0, Math.Min(1, target));
            // (counting up: quick, but the numbers show -- and once the room is in, straight on to 100)
            if (tgt > _shown) _shown = Math.Min(tgt, _shown + (tgt >= 1 ? Math.Max(0.03, (tgt - _shown) * 0.35) : Math.Max(0.006, (tgt - _shown) * 0.22)));
            unchecked { int black = (int)0xFF000000; for (int i = 0; i < _buf.Length; i++) _buf[i] = black; }
            int vr = viewRows > 0 ? Math.Min(h, viewRows) : h;
            float s = Math.Min(w / 1920f, vr / 1080f);
            if (_fTitle == null || _fontsFor != s)
            {
                if (_fTitle != null) { _fTitle.Dispose(); _fPct.Dispose(); }
                _fTitle = new Font("Consolas", 22f * s, FontStyle.Bold, GraphicsUnit.Pixel); _fPct = new Font("Consolas", 34f * s, FontStyle.Bold, GraphicsUnit.Pixel); _fontsFor = s;
            }
            var hnd = GCHandle.Alloc(_buf, GCHandleType.Pinned);
            try
            {
                using (var bm = new Bitmap(w, h, w * 4, PixelFormat.Format32bppPArgb, hnd.AddrOfPinnedObject()))
                using (var g = Graphics.FromImage(bm))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    double a = Math.Min(1, t / 0.15);                                  // (the readout comes up quickly)
                    // a faint scan sweeping down the dark glass, every 1.6 s
                    double sweep = (t % 1.6) / 1.6; float sy = (float)(sweep * vr);
                    using (var lg = new LinearGradientBrush(new RectangleF(0, sy - 60 * s, w, 60 * s + 1), C(Amber, 0), C(Amber, 0.07 * a), 90f))
                        g.FillRectangle(lg, 0, sy - 60 * s, w, 60 * s);
                    using (var ln = new SolidBrush(C(Amber, 0.16 * a))) g.FillRectangle(ln, 0, sy, w, Math.Max(1f, 1.2f * s));
                    // the readout, top centre of the view
                    float cx = w / 2f, y0 = vr * 0.065f;
                    string dots = new string('.', 1 + (int)(t * 3) % 3);
                    float tw = Spaced(g, Title, _fTitle, null, 0, 0, 4 * s), dw = Spaced(g, "...", _fTitle, null, 0, 0, 4 * s);
                    float tx = cx - (tw + dw) / 2;
                    using (var sh = new SolidBrush(C(0x000000, 0.8 * a))) Spaced(g, Title, _fTitle, sh, tx + 2 * s, y0 + 2 * s, 4 * s);
                    using (var tb = new SolidBrush(C(AmberHi, a))) { Spaced(g, Title, _fTitle, tb, tx, y0, 4 * s); Spaced(g, dots, _fTitle, tb, tx + tw + 4 * s, y0, 4 * s); }
                    int pct = (int)Math.Round(_shown * 100);
                    string ps = pct + "%"; float pw = Spaced(g, ps, _fPct, null, 0, 0, 3 * s);
                    float py = y0 + 40 * s;
                    using (var pb = new SolidBrush(C(Amber, a))) Spaced(g, ps, _fPct, pb, cx - pw / 2, py, 3 * s);
                    // the segmented bar, its leading segment bright
                    float bw = 420 * s, bh = 10 * s, bx = cx - bw / 2, by = py + 52 * s;
                    using (var fr = new Pen(C(AmberDim, 0.9 * a), Math.Max(1f, 1.2f * s))) g.DrawRectangle(fr, bx - 3 * s, by - 3 * s, bw + 6 * s, bh + 6 * s);
                    int segs = 30, lit = (int)Math.Floor(_shown * segs); float sw = bw / segs;
                    using (var on = new SolidBrush(C(Amber, 0.92 * a))) using (var hi = new SolidBrush(C(AmberHi, a)))
                        for (int i = 0; i < lit; i++) g.FillRectangle(i == lit - 1 && _shown < 1 ? hi : on, bx + i * sw, by, sw - 2 * s, bh);
                    // the visor's corner brackets round the readout
                    float bl = tx - 26 * s, br = tx + tw + dw + 26 * s, bt = y0 - 14 * s, bb = by + bh + 16 * s, k = 16 * s;
                    using (var p = new Pen(C(Amber, 0.75 * a), Math.Max(1.5f, 2f * s)))
                    {
                        g.DrawLines(p, new[] { new PointF(bl, bt + k), new PointF(bl, bt), new PointF(bl + k, bt) });
                        g.DrawLines(p, new[] { new PointF(br - k, bt), new PointF(br, bt), new PointF(br, bt + k) });
                        g.DrawLines(p, new[] { new PointF(bl, bb - k), new PointF(bl, bb), new PointF(bl + k, bb) });
                        g.DrawLines(p, new[] { new PointF(br - k, bb), new PointF(br, bb), new PointF(br, bb - k) });
                    }
                }
            }
            finally { hnd.Free(); }
            return _buf;
        }

        public void Dispose() { if (_fTitle != null) { _fTitle.Dispose(); _fPct.Dispose(); _fTitle = null; } }
    }
}
