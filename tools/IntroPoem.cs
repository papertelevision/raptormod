// IntroPoem.cs -- the story intro (MOV\INTRO.MOV, the poem) rebuilt as VECTOR text (Josh, 2026-10-16: "extract the design and
// text ... ideally a vector based version of this text would be ideal so it is crisp on all screens").
//
// Two halves:
//   * MEASURE (Analyze): from the TensorPix upscale of the original (2400x1120, 685 frames), find every word's ink box on
//     each card's fullest frame, and each word's brightness through the whole movie -- its fade curve. That turns a
//     blurry upscale into data: where each word sits, how big it is, when it comes and goes.
//   * DRAW (Render): one frame of the scene -- each word in its typeface at its size, at its measured place, at its
//     measured brightness -- as anti-aliased vector outlines (GDI+ GraphicsPath), at any size. The DOSBox build encodes
//     these frames into the game's movie; a native build can draw the same scene live at the monitor's resolution.
// The scene (art\intro-poem\scene.json) is the source of truth: text, fonts, boxes, curves. tools\Build-IntroPoem.ps1.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace AztTool
{
    public class PoemBox { public int Card, Line, X0, Y0, X1, Y1; public float[] Curve; }

    public static class IntroPoem
    {
        // ---- MEASURE ---------------------------------------------------------------------------------------------------
        /// <summary>Ink boxes on one frame (BGRA, w x h): rows with ink grouped into lines, each line split into words at
        /// gaps of at least wordGap px. Ink = green channel above ink. Specks (smaller than minPx in both axes) dropped.</summary>
        public static List<int[]> FindWords(byte[] bgra, int w, int h, int ink, int lineGap, int wordGap, int minPx)
        {
            var rows = new int[h];
            for (int y = 0; y < h; y++) { int c = 0, o = y * w * 4; for (int x = 0; x < w; x++) if (bgra[o + x * 4 + 1] > ink) c++; rows[y] = c; }
            var bands = new List<int[]>(); int s = -1, gapRun = 0;
            for (int y = 0; y < h; y++)
            {
                if (rows[y] > 1) { if (s < 0) s = y; gapRun = 0; }
                else if (s >= 0) { gapRun++; if (gapRun > lineGap) { bands.Add(new[] { s, y - gapRun }); s = -1; gapRun = 0; } }
            }
            if (s >= 0) bands.Add(new[] { s, h - 1 });
            var words = new List<int[]>();
            foreach (var b in bands)
            {
                var cols = new int[w];
                for (int y = b[0]; y <= b[1]; y++) { int o = y * w * 4; for (int x = 0; x < w; x++) if (bgra[o + x * 4 + 1] > ink) cols[x]++; }
                int ws = -1, run = 0;
                for (int x = 0; x < w; x++)
                {
                    if (cols[x] > 0) { if (ws < 0) ws = x; run = 0; }
                    else if (ws >= 0) { run++; if (run >= wordGap) { AddWord(words, bgra, w, ws, x - run, b[0], b[1], ink, minPx); ws = -1; run = 0; } }
                }
                if (ws >= 0) AddWord(words, bgra, w, ws, w - 1, b[0], b[1], ink, minPx);
            }
            return words;
        }
        static void AddWord(List<int[]> words, byte[] bgra, int w, int x0, int x1, int y0, int y1, int ink, int minPx)
        {
            // tighten the vertical extent to this word's own ink
            int t = int.MaxValue, bt = -1;
            for (int y = y0; y <= y1; y++) { int o = y * w * 4; for (int x = x0; x <= x1; x++) if (bgra[o + x * 4 + 1] > ink) { if (y < t) t = y; if (y > bt) bt = y; break; } }
            if (bt < 0) return;
            if (x1 - x0 + 1 < minPx && bt - t + 1 < minPx) return;
            words.Add(new[] { x0, t, x1, bt });
        }
        /// <summary>The ink (sum of green over the threshold) inside each box on one frame: one value per box.</summary>
        public static float[] BoxInk(byte[] bgra, int w, int[][] boxes, int ink)
        {
            var r = new float[boxes.Length];
            for (int i = 0; i < boxes.Length; i++)
            {
                var b = boxes[i]; long sum = 0;
                for (int y = b[1]; y <= b[3]; y += 2) { int o = y * w * 4; for (int x = b[0]; x <= b[2]; x += 2) { int g = bgra[o + x * 4 + 1]; if (g > ink) sum += g; } }
                r[i] = sum;
            }
            return r;
        }

        /// <summary>The scene's measure of one phrase on one frame inside rect (x0,y0,x1,y1): its ink box (left, top,
        /// right, bottom), its BASELINE (the last row holding at least `baseShare` of the busiest row's ink -- so descenders
        /// do not move it) -- as int[5].</summary>
        public static int[] MeasureInk(byte[] bgra, int w, int x0, int y0, int x1, int y1, int ink, double baseShare)
        {
            int l = int.MaxValue, t = int.MaxValue, r = -1, b = -1; var rows = new int[y1 - y0 + 1];
            for (int y = y0; y <= y1; y++) { int o = y * w * 4; for (int x = x0; x <= x1; x++) if (bgra[o + x * 4 + 1] > ink) { rows[y - y0]++; if (x < l) l = x; if (x > r) r = x; if (y < t) t = y; if (y > b) b = y; } }
            if (r < 0) return null;
            int mx = 0; foreach (int c in rows) if (c > mx) mx = c;
            int bl = b; for (int y = y1; y >= y0; y--) if (rows[y - y0] >= mx * baseShare) { bl = y; break; }
            return new[] { l, t, r, b, bl };
        }
        /// <summary>Brightness inside rect on one frame: the sum of green above `floor` (stride 2) -- a fade curve's sample.</summary>
        public static double RectLight(byte[] bgra, int w, int x0, int y0, int x1, int y1, int floor)
        {
            long s = 0; for (int y = y0; y <= y1; y += 2) { int o = y * w * 4; for (int x = x0; x <= x1; x += 2) { int g = bgra[o + x * 4 + 1]; if (g > floor) s += g; } }
            return s;
        }

        // ---- PHRASES: runs of one typeface (bold / italic per run), set on one baseline ------------------------------------
        public class Run { public string Text; public bool Bold, Italic; }
        /// <summary>Top: when >= 0, the phrase is placed by its INK TOP instead of its baseline (a lone quote mark has no baseline to measure).</summary>
        public class Phrase { public string Font; public Run[] Runs; public float Size, X, Baseline, Weight; public float Top = -1; public float[] Curve; }
        /// <summary>The phrase's outline at Size x s, ORIGIN AT ITS BASELINE (y = 0) and its ink starting at x = 0.</summary>
        public static GraphicsPath PhrasePath(Phrase ph, float s)
        {
            var all = new GraphicsPath(); float x = 0; float em = ph.Size * s;
            using (var ff = new FontFamily(ph.Font))
            {
                float space = SpaceWidth(ff, em);
                for (int i = 0; i < ph.Runs.Length; i++)
                {
                    var rn = ph.Runs[i]; var st = (rn.Bold ? FontStyle.Bold : FontStyle.Regular) | (rn.Italic ? FontStyle.Italic : FontStyle.Regular);
                    float asc = em * ff.GetCellAscent(st) / ff.GetEmHeight(st);
                    using (var p = new GraphicsPath())
                    {
                        p.AddString(rn.Text, ff, (int)st, em, new PointF(0, 0), StringFormat.GenericTypographic);
                        var bb = p.GetBounds(); if (bb.Width <= 0) continue;
                        using (var m = new Matrix()) { m.Translate(x - bb.X, -asc); p.Transform(m); }
                        all.AddPath(p, false); x += bb.Width + space;
                    }
                }
            }
            return all;
        }
        static float SpaceWidth(FontFamily ff, float em)
        {
            using (var a = new GraphicsPath()) using (var b = new GraphicsPath())
            {
                a.AddString("n n", ff, 0, em, new PointF(0, 0), StringFormat.GenericTypographic); b.AddString("nn", ff, 0, em, new PointF(0, 0), StringFormat.GenericTypographic);
                return a.GetBounds().Width - b.GetBounds().Width;
            }
        }
        /// <summary>The size whose phrase ink width is inkW (measuring space).</summary>
        public static float FitPhrase(Phrase ph, float inkW)
        {
            float keep = ph.Size; ph.Size = 100; float w; using (var p = PhrasePath(ph, 1f)) w = p.GetBounds().Width; ph.Size = keep;
            return w > 0 ? 100f * inkW / w : 0f;
        }
        /// <summary>One frame of phrases: black, each phrase at its curve's level (white x curve[f]), measuring space scaled
        /// by s and offset (ox, oy). Weight thickens the outline (a pen of Weight x em). BGRA out.</summary>
        public static byte[] RenderPhrases(Phrase[] phs, int f, int w, int h, float s, float ox, float oy, int white)
        {
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.Black); g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.CompositingQuality = CompositingQuality.HighQuality;
                    foreach (var ph in phs)
                    {
                        float a = ph.Curve != null && f >= 0 && f < ph.Curve.Length ? ph.Curve[f] : 0f; if (a <= 0.004f) continue;
                        using (var path = PhrasePath(ph, s))
                        {
                            var bb = path.GetBounds();
                            using (var m = new Matrix()) { m.Translate(ox + ph.X * s - bb.X, ph.Top >= 0 ? oy + ph.Top * s - bb.Y : oy + ph.Baseline * s); path.Transform(m); }
                            int v = (int)Math.Round(white * Math.Min(1f, a)); var col = Color.FromArgb(255, v, v, v);
                            using (var br = new SolidBrush(col)) g.FillPath(br, path);
                            if (ph.Weight > 0) using (var pen = new Pen(col, ph.Weight * ph.Size * s) { LineJoin = LineJoin.Round }) g.DrawPath(pen, path);
                        }
                    }
                }
                var d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                var buf = new byte[w * h * 4]; for (int y = 0; y < h; y++) Marshal.Copy(IntPtr.Add(d.Scan0, y * d.Stride), buf, y * w * 4, w * 4);
                bmp.UnlockBits(d); return buf;
            }
        }
        public static void SavePng(byte[] bgra, int w, int h, string path)
        {
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                var d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                for (int y = 0; y < h; y++) Marshal.Copy(bgra, y * w * 4, IntPtr.Add(d.Scan0, y * d.Stride), w * 4);
                bmp.UnlockBits(d); bmp.Save(path, ImageFormat.Png);
            }
        }

        // ---- DRAW (single words; the first pass) -------------------------------------------------------------------------
        public class Word { public string Text, Font; public bool Bold, Italic; public float Size, X, Y; public float[] Curve; }
        /// <summary>One frame: black, then every word whose curve is above zero at frame f (scaled by s from the scene's
        /// measuring space, offset by ox/oy), white at its curve's level. Returns BGRA.</summary>
        public static byte[] RenderFrame(Word[] words, int f, int w, int h, float s, float ox, float oy, int white)
        {
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.Black); g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    foreach (var wd in words)
                    {
                        float a = wd.Curve != null && f < wd.Curve.Length ? wd.Curve[f] : 0f; if (a <= 0.004f) continue;
                        using (var path = WordPath(wd, s))
                        {
                            var bb = path.GetBounds();
                            using (var m = new Matrix()) { m.Translate(ox + wd.X * s - bb.X, oy + wd.Y * s - bb.Y); path.Transform(m); }
                            int v = (int)Math.Round(white * Math.Min(1f, a));
                            using (var br = new SolidBrush(Color.FromArgb(255, v, v, v))) g.FillPath(br, path);
                        }
                    }
                }
                var d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                var buf = new byte[w * h * 4]; for (int y = 0; y < h; y++) Marshal.Copy(IntPtr.Add(d.Scan0, y * d.Stride), buf, y * w * 4, w * 4);
                bmp.UnlockBits(d); return buf;
            }
        }
        /// <summary>A word's outline at its size x s (unpositioned): wd.X/Y are its INK box's top-left in measuring space.</summary>
        public static GraphicsPath WordPath(Word wd, float s)
        {
            var p = new GraphicsPath();
            var st = (wd.Bold ? FontStyle.Bold : FontStyle.Regular) | (wd.Italic ? FontStyle.Italic : FontStyle.Regular);
            using (var ff = new FontFamily(wd.Font)) p.AddString(wd.Text, ff, (int)st, wd.Size * s, new PointF(0, 0), StringFormat.GenericTypographic);
            return p;
        }
        /// <summary>The font size whose ink width matches `inkW` (measuring space): one AddString at 100, scaled.</summary>
        public static float FitSize(string text, string font, bool bold, bool italic, float inkW)
        {
            var w = new Word { Text = text, Font = font, Bold = bold, Italic = italic, Size = 100 };
            using (var p = WordPath(w, 1f)) { var bb = p.GetBounds(); return bb.Width > 0 ? 100f * inkW / bb.Width : 0f; }
        }
        public static float InkHeight(string text, string font, bool bold, bool italic, float size)
        {
            var w = new Word { Text = text, Font = font, Bold = bold, Italic = italic, Size = size };
            using (var p = WordPath(w, 1f)) return p.GetBounds().Height;
        }
    }
}
