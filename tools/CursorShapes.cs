// CursorShapes.cs -- THE GAME'S CURSORS AS ANIMATED VECTORS: the shapes and their drawing (see CursorIcons.cs for the window
// that shows them at the game's cursor). Split out 2026-10-11 so the title screen's RAPTOR DOCS (RaptorDocs.cs, compiled
// with LoadingScreen.cs in the loading gate) draws the very same icons in its manual: this file has no other dependency.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace AztTool
{
    // ONE SOURCE, TWO NAMES: the loading gate compiles this with the title (LoadingScreen.cs + RaptorDocs.cs) defining
    // TITLE_GATE, so its copy is TitleShapes; the renderer's (with CursorIcons.cs) is CursorShapes. PowerShell's Add-Type
    // refuses a type name it has already added in the session ("already exists"), public or not.
#if TITLE_GATE
    static class TitleShapes
#else
    static class CursorShapes
#endif
    {
        /// <summary>The fade-in when a cursor comes up from nothing (s).</summary>
        public const double FadeIn = 0.08;

        // ---- THE SHAPES -------------------------------------------------------------------------------------------------------
        // Each icon is lines in its bitmap's 30 x 30 grid. A stroke: points, closed or not, a fill (alpha, 0 = none), its line's
        // weight against the others, its own alpha and glow (the animations brighten parts).
        class Stroke { public PointF[] P; public bool Closed; public float Fill, Weight = 1f, A = 1f, Glow = 1f; public bool Dark; }
        static PointF Pt(double x, double y) { return new PointF((float)x, (float)y); }
        static double C01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
        static double EaseOut(double t) { t = C01(t); return 1 - Math.Pow(1 - t, 3); }
        static double EaseInOut(double t) { t = C01(t); return t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2; }
        static double EaseBack(double t) { t = C01(t); double c = 1.70158; return 1 + (c + 1) * Math.Pow(t - 1, 3) + c * Math.Pow(t - 1, 2); }
        /// <summary>A smooth bump: 0 -> 1 -> 0 as x runs 0..1 (0 outside).</summary>
        static double Bump(double x) { return x <= 0 || x >= 1 ? 0 : 0.5 - 0.5 * Math.Cos(2 * Math.PI * x); }
        /// <summary>A pulse once every `period` s, lasting `len` s, starting `delay` s in.</summary>
        static double Pulse(double t, double period, double len, double delay) { double p = ((t - delay) % period + period) % period; return Bump(p / len); }
        /// <summary>THE LOOP (Josh, 2026-10-11: "make them all animate more than once. So animate, 1.5 second pause, animate, in
        /// a loop"): the rest between two plays of an icon's action.</summary>
        public static double LoopPause = 1.5;
        /// <summary>Time into the current play of an action `act` s long whose first play starts `start` s after the cursor
        /// appeared, the plays LoopPause apart (so >= act = resting); -1 before the first. `round` counts the plays.</summary>
        static double Play(double ta, double start, double act, out int round)
        {
            round = 0; if (ta < start) return -1;
            double per = act + LoopPause; round = (int)Math.Floor((ta - start) / per); return (ta - start) - round * per;
        }
        static double Play(double ta, double start, double act) { int r; return Play(ta, start, act, out r); }
        static PointF[] Move(PointF[] p, double dx, double dy) { var o = new PointF[p.Length]; for (int i = 0; i < p.Length; i++) o[i] = new PointF(p[i].X + (float)dx, p[i].Y + (float)dy); return o; }
        static PointF[] Zoom(PointF[] p, double cx, double cy, double sx, double sy) { var o = new PointF[p.Length]; for (int i = 0; i < p.Length; i++) o[i] = new PointF((float)(cx + (p[i].X - cx) * sx), (float)(cy + (p[i].Y - cy) * sy)); return o; }
        static PointF[] Rotate(PointF[] p, double cx, double cy, double deg)
        {
            double a = deg * Math.PI / 180, c = Math.Cos(a), s = Math.Sin(a); var o = new PointF[p.Length];
            for (int i = 0; i < p.Length; i++) { double x = p[i].X - cx, y = p[i].Y - cy; o[i] = new PointF((float)(cx + x * c - y * s), (float)(cy + x * s + y * c)); }
            return o;
        }
        static Stroke S(PointF[] p, bool closed) { return new Stroke { P = p, Closed = closed }; }
        static Stroke S(PointF[] p, bool closed, float fill, float weight) { return new Stroke { P = p, Closed = closed, Fill = fill, Weight = weight }; }
        static PointF[] Ring(double cx, double cy, double rx, double ry, int n) { var o = new PointF[n]; for (int i = 0; i < n; i++) { double a = 2 * Math.PI * i / n; o[i] = Pt(cx + rx * Math.Cos(a), cy + ry * Math.Sin(a)); } return o; }

        /// <summary>The icon `name` (a slot's name) `ta` s after it appeared, at clock `t`, as strokes in its grid.</summary>
        static List<Stroke> Build(string name, double ta, double t)
        {
            var L = new List<Stroke>();
            bool b = name.Length > 1 && name[0] == 'b';         // (the teal set: blook, bup, ... bdefault)
            string k = b ? name.Substring(1) : name;
            switch (k)
            {
                case "pointer":
                case "active":
                {
                    // the diamond crosshair: the diamond, its four arms outside it and the cross within (the bitmap's gaps kept).
                    // Appearing: the arms close in from outside and the diamond settles from a little larger (a lock-on).
                    // Then, a rest apart, it locks on again: the arms spring out and snap back in.
                    double kk = EaseBack(ta / 0.3), arm = 3.5 * (1 - kk), sd = 1 + 0.22 * (1 - EaseOut(ta / 0.3));
                    double lp = Play(ta, 0.3 + LoopPause, 0.45);
                    if (lp >= 0 && lp < 0.45) { double o = lp < 0.12 ? EaseOut(lp / 0.12) : 1 - EaseBack((lp - 0.12) / 0.33); arm += 2.4 * o; sd += 0.12 * Math.Max(0, o); }
                    L.Add(S(Zoom(new[] { Pt(15.5, 8.5), Pt(22.5, 15.5), Pt(15.5, 22.5), Pt(8.5, 15.5) }, 15.5, 15.5, sd, sd), true));
                    L.Add(S(new[] { Pt(4.5 - arm, 15.5), Pt(6.5 - arm, 15.5) }, false)); L.Add(S(new[] { Pt(24.5 + arm, 15.5), Pt(26.5 + arm, 15.5) }, false));
                    L.Add(S(new[] { Pt(15.5, 4.5 - arm), Pt(15.5, 6.5 - arm) }, false)); L.Add(S(new[] { Pt(15.5, 24.5 + arm), Pt(15.5, 26.5 + arm) }, false));
                    L.Add(S(new[] { Pt(10.5, 15.5), Pt(13.5, 15.5) }, false)); L.Add(S(new[] { Pt(17.5, 15.5), Pt(20.5, 15.5) }, false));
                    L.Add(S(new[] { Pt(15.5, 10.5), Pt(15.5, 13.5) }, false)); L.Add(S(new[] { Pt(15.5, 17.5), Pt(15.5, 20.5) }, false));
                    if (k == "active") { float g = (float)(1 + 0.6 * Pulse(t, 1.2, 0.6, 0)); foreach (var s in L) s.Glow = g; }      // (over something it can press: it throbs)
                    break;
                }
                case "look":
                {
                    // the eye: a dome over a base that rises a little to the right; its iris (look) or, filled and glossy, the
                    // teal one (blook). Appearing: it OPENS from its base. Then, a rest apart each time, the amber eye looks
                    // one way and back, blinks, looks the other way, blinks...; the teal one's gloss slides across it.
                    double open = 0.12 + 0.88 * EaseBack(ta / 0.32);
                    int round; double lp = Play(ta, 0.32 + LoopPause, b ? 1.2 : 0.8, out round);
                    bool acting = lp >= 0 && lp < (b ? 1.2 : 0.8);
                    if (!b && acting && (round & 1) == 1) open *= 1 - 0.85 * Bump(lp / 0.28);
                    Func<double, double> yb = x => 21.5 + (18.5 - 21.5) * (x - 1.5) / 28.0;      // (the base line)
                    var dome = new List<PointF>(); for (int i = 0; i <= 28; i++) { double th = Math.PI * i / 28; double x = 15.5 - 14 * Math.Cos(th); dome.Add(Pt(x, yb(x) - 12.5 * Math.Sin(th))); }
                    var arc = Zoom(dome.ToArray(), 15.5, 20, 1, open);
                    if (b)
                    {
                        L.Add(S(arc, true, 0.30f, 1f));
                        // its gloss (the bitmap's highlight, upper left), sliding across the dome each play
                        double sweep = acting ? EaseInOut(lp / 1.2) : 0, th0 = Math.PI * (0.12 + 0.62 * sweep);
                        var gl = new List<PointF>(); for (int i = 0; i <= 8; i++) { double th = th0 + Math.PI * 0.2 * i / 8; double x = 15.5 - 11 * Math.Cos(th); gl.Add(Pt(x, yb(x) - 9.8 * Math.Sin(th))); }
                        var gs = S(Zoom(gl.ToArray(), 15.5, 20, 1, open), false, 0, 0.7f); gs.A = (float)(0.55 + 0.45 * (acting ? Bump(lp / 1.2) : 0)); gs.Glow = 1.6f; L.Add(gs);
                    }
                    else
                    {
                        L.Add(S(arc, true));
                        double dx = acting && (round & 1) == 0 ? 2.2 * Math.Sin(Math.PI * lp / 0.8) * ((round & 2) == 0 ? 1 : -1) : 0;
                        L.Add(S(Zoom(Ring(15.5 + dx, 14, 2.6, 2.6, 18), 15.5, 20, 1, open), true, 0f, 1.55f));
                        var pupil = S(Zoom(Ring(15.5 + dx, 14, 0.9, 0.9, 10), 15.5, 20, 1, open), true, 0.95f, 0.01f); pupil.Dark = true; L.Add(pupil);
                    }
                    L.Add(S(new[] { Pt(1.5, 21.5), Pt(29.5, 18.5) }, false));
                    break;
                }
                case "up":
                case "down":
                {
                    // three chevrons, the way to go: they light up in turn as the cursor appears and AT ONCE step forward in a
                    // wave, one after another; then the wave again, a rest apart (Josh: "animate a bit earlier, and a bit more
                    // obvious so a touch more movement" -- it waited for a 1.3 s clock and moved 1.6 units)
                    bool up = k == "up"; double[] ap = up ? new[] { 2.5, 10.75, 18.75 } : new[] { 9.25, 17.25, 26.5 }, bs = up ? new[] { 10.5, 18.5, 26.5 } : new[] { 2.5, 10.5, 18.5 };
                    double lp = Play(ta, 0.1, 0.62);
                    for (int i = 0; i < 3; i++)
                    {
                        int order = up ? 2 - i : i;                      // (the wave starts at the back)
                        double d = (lp < 0 ? 0 : 2.6 * Bump((lp - 0.09 * order) / 0.44)) * (up ? -1 : 1);
                        var s = S(Move(new[] { Pt(15.5, ap[i]), Pt(23.5, bs[i]), Pt(7.5, bs[i]) }, 0, d), true);
                        s.A = (float)C01((ta - 0.07 * order) / 0.12); s.Glow = (float)(1 + 0.8 * Math.Abs(d) / 2.6); L.Add(s);
                    }
                    break;
                }
                case "pull":
                case "push":
                {
                    // the cut stone: PULL its wide face up and its point down (toward you), PUSH its point up (away). It comes
                    // in toward you / goes back as it appears, and leans that way again, a rest apart.
                    bool pull = k == "pull";
                    double sc = pull ? 0.86 + 0.14 * EaseBack(ta / 0.32) : 1.14 - 0.14 * EaseBack(ta / 0.32);
                    double lp = Play(ta, 0.32 + LoopPause, 0.6), pz = lp < 0 ? 0 : Bump(lp / 0.6);
                    sc *= pull ? 1 + 0.1 * pz : 1 - 0.09 * pz; double dy = (pull ? 1.2 : -1.2) * pz;
                    var parts = new List<Stroke>();
                    if (pull)
                    {
                        parts.Add(S(new[] { Pt(8.5, 8.5), Pt(21.5, 8.5), Pt(28.5, 12.5), Pt(28.5, 13.5), Pt(23.5, 18.5), Pt(6.5, 18.5), Pt(1.5, 13.5), Pt(1.5, 12.5) }, true));
                        parts.Add(S(new[] { Pt(10.5, 9.0), Pt(8.5, 17.0) }, false)); parts.Add(S(new[] { Pt(19.5, 9.0), Pt(21.5, 17.0) }, false));
                        parts.Add(S(new[] { Pt(6.5, 18.5), Pt(14.5, 26.5), Pt(23.5, 18.5) }, false));
                        parts.Add(S(new[] { Pt(10.8, 20.5), Pt(18.3, 20.5), Pt(14.5, 25.2) }, true, 0.55f, 0.8f));
                    }
                    else
                    {
                        parts.Add(S(new[] { Pt(8.5, 11.5), Pt(14.5, 7.5), Pt(21.5, 11.5) }, false));
                        parts.Add(S(new[] { Pt(12.5, 9.2), Pt(14.5, 10.5), Pt(16.5, 9.2) }, false, 0, 0.8f));
                        parts.Add(S(new[] { Pt(8.5, 11.5), Pt(21.5, 11.5), Pt(28.5, 15.5), Pt(23.5, 21.5), Pt(6.5, 21.5), Pt(1.5, 15.5) }, true));
                        parts.Add(S(new[] { Pt(10.5, 12.5), Pt(8.5, 20.0) }, false)); parts.Add(S(new[] { Pt(19.5, 12.5), Pt(21.5, 20.0) }, false));
                    }
                    double cy = pull ? 17 : 14.5;
                    foreach (var s in parts) { s.P = Move(Zoom(s.P, 15, cy, sc, sc), 0, dy); s.Glow = (float)(1 + 0.6 * pz); L.Add(s); }
                    break;
                }
                case "use":
                {
                    // the lever between two arrows: it is THROWN as the cursor appears (from a tilt, about its base), the arrows
                    // spreading out from it; then, a rest apart, it is pulled back and thrown again, the arrows nudging out
                    double kk = EaseBack(ta / 0.38), tilt = -18 * (1 - kk), spread = 3 * (1 - EaseOut(ta / 0.3)), nudge = 0;
                    double lp = Play(ta, 0.38 + LoopPause, 0.55);
                    if (lp >= 0 && lp < 0.55)
                    {
                        tilt += lp < 0.12 ? -14 * EaseOut(lp / 0.12) : -14 * (1 - EaseBack((lp - 0.12) / 0.43));
                        nudge = 1.4 * Bump((lp - 0.12) / 0.43);
                    }
                    var bar = S(Rotate(new[] { Pt(15.5, 3.8), Pt(15.5, 20.2) }, 15.5, 22, tilt), false, 0, 2.2f); L.Add(bar);
                    L.Add(S(new[] { Pt(12.5, 22.5), Pt(18.5, 22.5), Pt(18.5, 25.5), Pt(12.5, 25.5) }, true, 0.6f, 0.9f));
                    var notch = S(Ring(15.5, 24.2, 0.7, 0.7, 8), true, 0.95f, 0.01f); notch.Dark = true; L.Add(notch);
                    L.Add(S(Move(new[] { Pt(10.5, 3.5), Pt(10.5, 19.5), Pt(2, 11.5) }, spread - nudge, 0), true));
                    L.Add(S(Move(new[] { Pt(20.5, 3.5), Pt(20.5, 19.5), Pt(29, 11.5) }, -spread + nudge, 0), true));
                    break;
                }
                case "rot":
                {
                    // the pinwheel: four blades, each a leg out from the middle (1.5 to its side), the tip back and across, the
                    // back edge to the next blade's leg. It turns ONE whole revolution as it appears, and again, a rest apart.
                    double turn = 360 * EaseInOut(Play(ta, 0, 0.95) / 0.95);
                    var blade = new[] { Pt(-0.5, -1.5), Pt(-13, -1.5), Pt(-5, -10), Pt(-0.5, -5.5) };
                    for (int q = 0; q < 4; q++)
                    {
                        var p = new PointF[blade.Length];
                        for (int i = 0; i < blade.Length; i++) { double x = blade[i].X, y = blade[i].Y; for (int r = 0; r < q; r++) { double tx = -y; y = x; x = tx; } p[i] = Pt(15 + x, 15 + y); }
                        L.Add(S(Rotate(p, 15, 15, turn), false));
                    }
                    break;
                }
                case "take":
                {
                    // the claw that picks things up: it drops in as it appears (lighting up as it lands), then, a rest apart, bobs
                    // up and down -- a lift and a smaller second one -- its jaws closing as it lifts (a grab) and its glow swelling
                    // with the lift, as the door arrows' does with their step (Josh, 2026-10-11: "a bit more animation ... perhaps a
                    // glow like the arrow icons for opening doors")
                    double land = 1 - EaseOut(ta / 0.32), lp = Play(ta, 0.32 + LoopPause, 0.8);
                    double k1 = lp < 0 ? 0 : Bump(lp / 0.45), k2 = lp < 0 ? 0 : Bump((lp - 0.45) / 0.35);
                    double dy = -4 * (1 - EaseBack(ta / 0.32)) - 2.0 * k1 - 1.0 * k2, pinch = 1.3 * k1 + 0.6 * k2;
                    float glow = (float)(1 + 0.9 * Math.Max(k1, 0.6 * k2) + 0.6 * land);
                    // the jaws (below the head, y > 14) close toward the middle, the more the lower
                    Func<PointF[], PointF[]> grab = p =>
                    {
                        var o = new PointF[p.Length];
                        for (int i = 0; i < p.Length; i++) { double f = C01((p[i].Y - 14) / 12.5) * pinch; o[i] = Pt(p[i].X + (p[i].X < 15 ? f : -f), p[i].Y + dy); }
                        return o;
                    };
                    var outer = S(grab(new[] { Pt(10.5, 26.5), Pt(9.5, 24.0), Pt(8.5, 22.0), Pt(7.5, 20.0), Pt(6.5, 18.0), Pt(5.0, 15.0), Pt(5.0, 13.8), Pt(11.5, 7.2), Pt(11.5, 2.5),
                                               Pt(19.5, 2.5), Pt(19.5, 7.5), Pt(24.5, 13.8), Pt(24.5, 15.0), Pt(23.0, 18.0), Pt(22.0, 20.0), Pt(21.0, 22.0), Pt(20.0, 24.0), Pt(19.5, 26.5) }), false);
                    var inner = S(grab(new[] { Pt(10.5, 26.3), Pt(10.5, 14.5), Pt(19.5, 14.5), Pt(19.5, 26.3) }), false);
                    outer.Glow = glow; inner.Glow = glow; L.Add(outer); L.Add(inner);
                    break;
                }
                case "scan":
                {
                    // three squares of bars round a middle: appearing, they open out from the middle one after another; then, a
                    // rest apart, a scan runs out through them, ring by ring, each brightening and stepping out as it passes
                    double[] r = { 2.0, 7.0, 11.0 }, half = { 1.0, 4.0, 7.0 };       // (a ring: its bars' distance out, their half-length)
                    double lp = Play(ta, 0.4 + LoopPause, 0.84);
                    for (int i = 0; i < 3; i++)
                    {
                        double h = lp < 0 ? 0 : Bump((lp - 0.17 * i) / 0.5), grow = EaseBack((ta - 0.06 * i) / 0.28), d = r[i] * grow + 0.8 * h, l = half[i] * grow;
                        var bars = new[] { new[] { Pt(15.5 - l, 15.5 - d), Pt(15.5 + l, 15.5 - d) }, new[] { Pt(15.5 - l, 15.5 + d), Pt(15.5 + l, 15.5 + d) },
                                           new[] { Pt(15.5 - d, 15.5 - l), Pt(15.5 - d, 15.5 + l) }, new[] { Pt(15.5 + d, 15.5 - l), Pt(15.5 + d, 15.5 + l) } };
                        foreach (var bb in bars) { var s = S(bb, false); s.Glow = (float)(1 + 0.9 * h); s.A = (float)(0.7 + 0.3 * h); L.Add(s); }
                    }
                    break;
                }
                case "left":
                case "right":
                case "downarrw":
                {
                    // one arrow: it slides in from behind as it appears and AT ONCE points the way -- a push and a smaller second
                    // one -- then again, a rest apart (Josh: earlier and more obvious; it waited for a 1.25 s clock, 1.8 units)
                    double back = 4 * (1 - EaseBack(ta / 0.3)), lp = Play(ta, 0.22, 0.62);
                    double go = lp < 0 ? 0 : 3.0 * Bump(lp / 0.36) + 1.2 * Bump((lp - 0.36) / 0.26);
                    if (k == "left") L.Add(S(Move(new[] { Pt(12.5, 6.5), Pt(12.5, 24.5), Pt(3.5, 15.5) }, back - go, 0), true));
                    else if (k == "right") L.Add(S(Move(new[] { Pt(17.5, 6.5), Pt(17.5, 24.5), Pt(26.5, 15.5) }, -back + go, 0), true));
                    else L.Add(S(Move(new[] { Pt(7.5, 10.5), Pt(23.5, 10.5), Pt(15.5, 19.5) }, 0, -back + go), true));
                    break;
                }
                case "shoot":
                {
                    // the combat sight -- not one of the game's 30 bitmaps (in combat the game draws its own), only the RAPTOR
                    // DOCS manual's SHOOT entry draws it: the ring tightens in as it appears, the cross through it; then, a rest
                    // apart, three quick flashes (a three-round burst)
                    double rr = 8 + 3.5 * (1 - EaseBack(ta / 0.32)), lp = Play(ta, 0.32 + LoopPause, 0.5);
                    float burst = lp < 0 ? 1f : (float)(1 + 0.9 * (Bump(lp / 0.14) + Bump((lp - 0.17) / 0.14) + Bump((lp - 0.34) / 0.14)));
                    L.Add(S(Ring(15.5, 15.5, rr, rr, 36), true));
                    L.Add(S(new[] { Pt(15.5, 15.5 - rr - 3), Pt(15.5, 12.5) }, false)); L.Add(S(new[] { Pt(15.5, 18.5), Pt(15.5, 15.5 + rr + 3) }, false));
                    L.Add(S(new[] { Pt(15.5 - rr - 3, 15.5), Pt(12.5, 15.5) }, false)); L.Add(S(new[] { Pt(18.5, 15.5), Pt(15.5 + rr + 3, 15.5) }, false));
                    L.Add(S(Ring(15.5, 15.5, 0.8, 0.8, 8), true, 0.9f, 0.6f));
                    foreach (var s in L) s.Glow = burst;
                    break;
                }
                case "default":
                {
                    // the view's own cursor (two arrows facing in): no more than a slow breath -- it is up most of the time
                    double inw = 0.7 * Math.Pow(Math.Sin(Math.PI * t / 2.8), 2);
                    L.Add(S(new[] { Pt(6.5 + inw, 4.5), Pt(13.5 + inw, 12.0), Pt(13.5 + inw, 16.0), Pt(6.5 + inw, 23.5) }, true));
                    L.Add(S(new[] { Pt(24.5 - inw, 4.5), Pt(17.5 - inw, 12.0), Pt(17.5 - inw, 16.0), Pt(24.5 - inw, 23.5) }, true));
                    break;
                }
            }
            // the "B" set sits where its own bitmap does (a pixel or two off the amber one)
            double ox = name == "bdown" ? -1 : 0, oy = name == "btake" ? 1 : name == "bpull" ? -1 : name == "bpush" ? -2 : 0;
            if (ox != 0 || oy != 0) foreach (var s in L) s.P = Move(s.P, ox, oy);
            return L;
        }

        // the inks: core, hot centre line
        public static int Amber = 0xFFB040, AmberHi = 0xFFE3A6, Teal = 0x71DFD7, TealHi = 0xBEFBFF, Red = 0xFF6A3C, RedHi = 0xFFD2B4, Rim = 0x0A0603;
        static Color Col(int rgb, double a) { return Color.FromArgb(Math.Max(0, Math.Min(255, (int)(255 * a))), (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }

        /// <summary>Draws the icon of slot name `name`: its grid's origin at (x0, y0), `u` px a grid unit, `ta` s after it appeared,
        /// clock `t`, fading in over its first 0.08 s.</summary>
        public static void Draw(Graphics g, string name, float x0, float y0, float u, double ta, double t) { Draw(g, name, x0, y0, u, ta, t, C01(ta / FadeIn)); }
        /// <summary>The same at opacity `fade` (0..1). The window fades a cursor in only when it comes up from nothing; one
        /// shape changing to another shows at once (the new shape's own animation still plays).</summary>
        public static void Draw(Graphics g, string name, float x0, float y0, float u, double ta, double t, double fade)
        {
            bool teal = name.Length > 1 && name[0] == 'b', red = name == "active";
            int core = red ? Red : teal ? Teal : Amber, hi = red ? RedHi : teal ? TealHi : AmberHi;
            double a = C01(fade);           // (no flicker-on: Josh 2026-10-11, the icons read as "flickering, and very faint")
            var L = Build(name, ta, t);
            g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            Func<PointF[], PointF[]> toPx = p => { var o = new PointF[p.Length]; for (int i = 0; i < p.Length; i++) o[i] = new PointF(x0 + p[i].X * u, y0 + p[i].Y * u); return o; };
            Action<Pen, Stroke, PointF[]> line = (pen, s, p) => { if (p.Length < 2) return; if (s.Closed) g.DrawPolygon(pen, p); else g.DrawLines(pen, p); };
            var px = new List<PointF[]>(); foreach (var s in L) px.Add(toPx(s.P));
            // 1. fills (a filled facet, a knob, the teal eye's dome); a dark one punches its colour out (a pupil, a notch)
            for (int i = 0; i < L.Count; i++)
            {
                var s = L[i]; if (s.Fill <= 0 || px[i].Length < 3) continue;
                using (var br = new SolidBrush(s.Dark ? Col(Rim, 0.92 * a * s.A) : Col(core, s.Fill * a * s.A))) g.FillPolygon(br, px[i]);
            }
            // 2. the dark rim (the bitmap's outline), 3. the glow, 4. the core, 5. its hot centre line
            // (bolder than the first cut, whose 1.25-unit core was under two screen pixels at 2560 wide: "very faint", Josh)
            for (int pass = 0; pass < 4; pass++)
                for (int i = 0; i < L.Count; i++)
                {
                    var s = L[i]; if (s.Dark || s.Weight < 0.05f) continue; float w = s.Weight;
                    Color c; float width;
                    if (pass == 0) { c = Col(Rim, 0.85 * a * s.A); width = (2.6f + 1.7f * w) * u; }
                    else if (pass == 1) { c = Col(core, Math.Min(0.6, 0.27 * s.Glow) * a * s.A); width = (2.4f + 1.8f * w) * u * Math.Min(1.4f, s.Glow); }
                    else if (pass == 2) { c = Col(core, a * s.A); width = 1.7f * w * u; }
                    else { c = Col(hi, Math.Min(1.0, 0.8 + 0.25 * (s.Glow - 1)) * a * s.A); width = 0.65f * w * u; }
                    using (var pen = new Pen(c, Math.Max(0.6f, width)) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round }) line(pen, s, px[i]);
                }
        }
        /// <summary>OFFLINE: slot name `name` drawn `ta` s after it appeared (clock t = ta) on a `size`-px square, over `bg`.</summary>
        public static Bitmap Preview(string name, double ta, int size, int bg)
        {
            var bm = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bm)) { g.Clear(Color.FromArgb(255, (bg >> 16) & 255, (bg >> 8) & 255, bg & 255)); float u = size / 46f; Draw(g, name, 8 * u, 8 * u, u, ta, ta); }
            return bm;
        }
    }
}
