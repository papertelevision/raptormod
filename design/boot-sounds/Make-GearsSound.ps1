# Make-GearsSound.ps1 -- the HUD's arrival: heavy machinery as the panel halves slide in from the left and the right during
# the boot (Josh, 2026-10-07: "a machine like sound of gears turning ... refine it here first"). Not wired in yet.
#
# v2 (Josh: "make it heavier and like a gear/ratchet, more like servos, deep rumble underneath. The one you created sounds
# like a cartoon sound"). v1's bright pure resonances (2-5 kHz 'tinks'), its even tick spacing and its buzzy saw motor were
# what made it a toy. Now:
#   - SERVOS: geared-motor whirr -- band-limited noise through a gearbox band that climbs as it spins up and drops as it
#     slows, over a low fundamental pulsing with the gear mesh; one per half (left, right), a little apart in pitch
#   - RATCHET: heavy pawl clicks -- broadband snaps through LOW damped body modes (200-900 Hz), irregular, slower
#   - a deep sub RUMBLE (35-60 Hz) through the slide and into the latch
#   - the LATCH: a big dark clunk (40 Hz impact + a low metal body, no bright ring), then a short hydraulic hiss seating it
#   - light saturation for weight, a darker room
# Follows the slide (Panel.cs: 0.9 s, ease-out cubic -- fastest at the start, slowing to a stop).
#
# v3 (Josh: "I like the tink sound but I want it deep, like a roller coaster being pulled up a hill, or gears grinded ... a
# deep bass ratchet sound, with a metallic click at the end as it clicks into place, metal on metal, but again deep"):
#   - the RATCHET is a chain-lift clack: each one a steel impact ringing with a struck BAR's inharmonic modes (1 : 2.756 :
#     5.404 : 8.933 -- the 'tink', but pitched near 190 Hz), over a low thump; fast, then slowing, never quite even
#   - GRINDING: rough friction noise in 150-600 Hz with a jittering grain, and a gritty gear whine near 90 Hz
#   - the servos turned down to a drive motor's drone under it all; the deep rumble kept
#   - the CLICK INTO PLACE: a heavy metal-on-metal clang -- the same bar modes far deeper (~95 Hz) and longer -- with a
#     sharp contact and a body thud; the hiss is off by default
#
#   .\Make-GearsSound.ps1 [-Slide 0.9] [-Clicks 11] [-BarHz 190] [-ClangHz 95] [-Grind 1] [-Latch 1] [-Out x.wav]
param(
    [double]$Slide = 0.9,           # the slide's length (s)
    [double]$Clicks = 11,           # ratchet clacks a second at full speed
    [double]$BarHz = 190,           # the clacks' ring (a struck bar's lowest mode)
    [double]$ClangHz = 95,          # the final clang's
    [double]$Grind = 1.0,           # the grinding's level
    [double]$Servo = 0.35,          # the drive motors' drone (v2's servos, turned down)
    [double]$Ratchet = 1.0,         # the ratchet's level
    [double]$Rumble = 1.0,          # the sub rumble's level
    [double]$Latch = 1.0,           # the latch's level
    [double]$Hiss = 0.0,            # the hydraulic hiss after the latch (off)
    [double]$Room = 0.22,
    [int]$Seed = 5,
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = Join-Path $here '12-hud-gears.wav' }
Add-Type -TypeDefinition @'
using System; using System.IO;
public static class Gears3 {
    const int SR = 44100;
    // a resonant mode (damped two-pole)
    class Mode { double b0, a1, a2, y1, y2; public Mode(double f, double decay) { double r = Math.Exp(-1.0 / (decay * SR)), w = 2 * Math.PI * f / SR; a1 = -2 * r * Math.Cos(w); a2 = r * r; b0 = 1 - r; }
        public double Run(double x) { double y = b0 * x - a1 * y1 - a2 * y2; y2 = y1; y1 = y; return y; } }
    // a state-variable band-pass whose centre can move
    class SVF { double lo, bp; public double Run(double x, double f, double q) { double k = 2 * Math.Sin(Math.PI * Math.Min(f, SR / 6.0) / SR); lo += k * bp; double hi = x - lo - bp / q; bp += k * hi; return bp; } }
    static double Speed(double t, double T) { if (t >= T || t < 0) return 0; double u = t / T, s = (1 - u) * (1 - u); return s * Math.Min(1, t / 0.05); }
    public static void Make(string path, double T, double clicks, double barHz, double clangHz, double grind, double servo, double ratchet, double rumble, double latch, double hiss, double room, int seed) {
        double total = T + 1.1; int n = (int)(total * SR); var L = new double[n]; var R = new double[n]; var rnd = new Random(seed);
        // SERVOS: one per half -- a gearbox whirr (noise through a moving band) and a low fundamental pulsing with the mesh
        double[] base0 = { 62, 71 }, gbLo = { 380, 430 }, gbHi = { 900, 1010 }, pl = { 0.9, 0.35 }, pr = { 0.35, 0.9 };
        for (int s = 0; s < 2; s++) {
            var f1 = new SVF(); var f2 = new SVF(); double ph = rnd.NextDouble(), mesh = 0, sm = 0;
            for (int i = 0; i < n; i++) {
                double t = i / (double)SR, sp = Speed(t, T);
                sm += (sp - sm) * 0.002;                                            // (the motor lags the slide a touch)
                if (sm < 0.003 && t > T) continue;
                double nz = rnd.NextDouble() * 2 - 1;
                double band = gbLo[s] + (gbHi[s] - gbLo[s]) * sm;
                double whirr = f1.Run(nz, band, 6) * 0.9 + f2.Run(nz, band * 2.02, 9) * 0.35;
                double f0 = base0[s] * (0.75 + 0.5 * sm); ph += f0 / SR; ph -= Math.Floor(ph);
                mesh += f0 * 9 / SR; mesh -= Math.Floor(mesh);                      // 9 teeth a turn: the whirr throbs with them
                double am = 0.7 + 0.3 * Math.Sin(2 * Math.PI * mesh);
                double low = Math.Sin(2 * Math.PI * ph) * 0.55 + Math.Sin(4 * Math.PI * ph + 0.6) * 0.2;
                double v = (whirr * am * 1.4 + low * 0.5) * sm * servo;
                L[i] += v * pl[s]; R[i] += v * pr[s];
            }
        }
        // RATCHET: a chain lift's clack -- a steel impact ringing with a struck bar's modes (deep), over a low thump; one
        // dog per half, a little apart, fast then slowing with the slide
        double[] bar = { 1.0, 2.756, 5.404, 8.933 }, bd = { 0.16, 0.10, 0.06, 0.035 }, ba = { 1.0, 0.6, 0.35, 0.18 };
        for (int s = 0; s < 2; s++) {
            var md = new Mode[4]; for (int k = 0; k < 4; k++) md[k] = new Mode(barHz * (s == 0 ? 1.0 : 1.09) * bar[k], bd[k]);
            var thump = new Mode(58 + 6 * s, 0.07);
            double ph = rnd.NextDouble() * 0.3, next = 1; double burstLeft = 0, burstAmp = 0;
            for (int i = 0; i < n; i++) {
                double t = i / (double)SR, sp = Speed(t, T);
                ph += clicks * (s == 0 ? 1.0 : 0.93) * (0.3 + 0.7 * sp) / SR * (t < T ? 1 : 0);
                if (ph >= next) { next += 1 + (rnd.NextDouble() - 0.5) * 0.22; burstLeft = 0.0025 * SR; burstAmp = (0.55 + 0.45 * sp) * (0.8 + 0.4 * rnd.NextDouble()); }
                double x = 0; if (burstLeft > 0) { x = (rnd.NextDouble() * 2 - 1) * burstAmp * (burstLeft / (0.0025 * SR)); burstLeft--; }
                double y = 0; for (int k = 0; k < 4; k++) y += md[k].Run(x) * ba[k];
                y = y * 14 + thump.Run(x) * 22 + x * 0.1;
                y *= ratchet; L[i] += y * pl[s]; R[i] += y * pr[s];
            }
        }
        // GRINDING: rough friction in 150-600 Hz with a jittering grain, and a gritty gear whine near 90 Hz
        {
            var g1 = new SVF(); var g2 = new SVF(); double grain = 0, wp = 0;
            for (int i = 0; i < n; i++) {
                double t = i / (double)SR, sp = Speed(t, T); if (sp <= 0) continue;
                if ((i & 63) == 0) grain = 0.4 + 0.6 * rnd.NextDouble();               // the grit: the level jumping ~700 times a second
                double nz = rnd.NextDouble() * 2 - 1;
                double fr = g1.Run(nz, 230 + 160 * sp, 2.2) * 0.8 + g2.Run(nz, 480, 3) * 0.4;
                double f0 = 70 + 40 * sp; wp += f0 / SR; wp -= Math.Floor(wp);
                double whine = Math.Sin(2 * Math.PI * wp) + 0.5 * Math.Sin(4 * Math.PI * wp + 1) + 0.3 * Math.Sign(Math.Sin(6 * Math.PI * wp)) * 0.4;
                double v = (fr * grain * 1.6 + whine * 0.12) * sp * grind;
                L[i] += v * 0.8; R[i] += v * 0.8;
            }
        }        // the SUB RUMBLE: deep filtered noise and a slow-wavering 42 Hz, through the slide and on into the latch
        double r1 = 0, r2 = 0, r3 = 0, kr = 1 - Math.Exp(-2 * Math.PI * 70.0 / SR);
        for (int i = 0; i < n; i++) {
            double t = i / (double)SR, sp = Speed(t, T);
            double env = (t < T ? 0.35 + 0.65 * sp : 0.35 * Math.Exp(-(t - T) / 0.35)) * Math.Min(1, t / 0.08);
            r1 += kr * ((rnd.NextDouble() * 2 - 1) - r1); r2 += kr * (r1 - r2); r3 += kr * (r2 - r3);
            double v = (r3 * 4.0 + 0.3 * Math.Sin(2 * Math.PI * 42 * t) * (0.8 + 0.2 * Math.Sin(2 * Math.PI * 3.1 * t))) * env * rumble;
            L[i] += v; R[i] += v;
        }
        // the CLICK INTO PLACE: metal on metal, deep -- the bar's modes at clangHz, long; a sharp contact; a body thud
        double[] cd = { 0.65, 0.42, 0.26, 0.15, 0.09 }, ca = { 1.0, 0.7, 0.45, 0.25, 0.12 }; double[] cr = { 1.0, 2.756, 5.404, 8.933, 13.34 };
        int i0 = (int)(T * SR); var hsv = new SVF();
        for (int i = i0; i < n; i++) {
            double t = (i - i0) / (double)SR, v = 0;
            for (int k = 0; k < cr.Length; k++) v += ca[k] * Math.Sin(2 * Math.PI * clangHz * cr[k] * t + k * 0.7) * Math.Exp(-t / cd[k]) * Math.Min(1, t / 0.001);
            v += 0.9 * Math.Sin(2 * Math.PI * 41 * t) * Math.Exp(-t / 0.14) * Math.Min(1, t / 0.002);          // the body thud
            if (t < 0.004) v += (rnd.NextDouble() * 2 - 1) * 0.8 * (1 - t / 0.004);                            // the contact
            double t2 = t - 0.06;
            if (t2 > 0 && hiss > 0) { double he = Math.Min(1, t2 / 0.03) * Math.Exp(-t2 / 0.22); v += hsv.Run(rnd.NextDouble() * 2 - 1, 3200, 1.2) * 0.35 * he * hiss; }
            v *= latch * 0.75; L[i] += v; R[i] += v;
        }        // weight: a soft saturation; then a darker room
        for (int i = 0; i < n; i++) { L[i] = Math.Tanh(L[i] * 1.4) / 1.4; R[i] = Math.Tanh(R[i] * 1.4) / 1.4; }
        Room(L, room, 0); Room(R, room, 23);
        double m = 1e-9; for (int i = 0; i < n; i++) m = Math.Max(m, Math.Max(Math.Abs(L[i]), Math.Abs(R[i])));
        double kk = 0.708 / m;
        using (var w = new BinaryWriter(File.Create(path))) {
            w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 4); w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)2); w.Write(SR); w.Write(SR * 4); w.Write((short)4); w.Write((short)16);
            w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(n * 4);
            for (int i = 0; i < n; i++) { double f = Math.Min(1.0, (n - i) / (0.1 * SR)); w.Write((short)Math.Round(L[i] * kk * f * 32767)); w.Write((short)Math.Round(R[i] * kk * f * 32767)); } }
    }
    static readonly int[] CT = { 1116, 1188, 1277, 1356, 1422, 1491 }, AT = { 556, 441 };
    static void Room(double[] x, double wet, int spread) {
        int n = x.Length; var cb = new double[6][]; var cs = new double[6]; var ci = new int[6]; for (int c = 0; c < 6; c++) cb[c] = new double[CT[c] + spread];
        var ab = new double[2][]; var ai = new int[2]; for (int a = 0; a < 2; a++) ab[a] = new double[AT[a] + spread];
        for (int i = 0; i < n; i++) {
            double inp = x[i] * 0.02, s = 0;
            for (int c = 0; c < 6; c++) { double y = cb[c][ci[c]]; cs[c] = y * 0.35 + cs[c] * 0.65; cb[c][ci[c]] = inp + cs[c] * 0.8; ci[c] = (ci[c] + 1) % cb[c].Length; s += y; }
            for (int a = 0; a < 2; a++) { double bo = ab[a][ai[a]], y = -s + bo; ab[a][ai[a]] = s + bo * 0.5; ai[a] = (ai[a] + 1) % ab[a].Length; s = y; }
            x[i] += s * wet * 5; }
    }
}
'@
[Gears3]::Make($Out, $Slide, $Clicks, $BarHz, $ClangHz, $Grind, $Servo, $Ratchet, $Rumble, $Latch, $Hiss, $Room, $Seed)
"{0}: {1:N2} s (slide {2} s, then the clang)" -f $Out, ($Slide + 1.1), $Slide
