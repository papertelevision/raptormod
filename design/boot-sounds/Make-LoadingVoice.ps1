# Make-LoadingVoice.ps1 -- "Loading RaptorMod." as a digitized synth voice with heavy reverb and echo (Josh, 2026-10-07).
#
# Windows' own speech (SAPI, Microsoft David) says the words; a 24-band channel VOCODER puts them on a low, slightly
# detuned saw buzz (noise carries the s and t sounds), a little of the plain voice stays in for clarity, a light
# bit-crush digitizes it, then a stereo ping-pong ECHO and a large Freeverb-style hall REVERB. Writes a 44.1 kHz stereo WAV.
#
#   .\Make-LoadingVoice.ps1                          (-> 11-loading-raptormod.wav beside this script)
#   .\Make-LoadingVoice.ps1 -Pitch 70 -Wet 0.6 -Out x.wav
param(
    [string]$Text = 'Loading ... Raptor Mod.',   # '...' becomes a pause (-PauseMs)
    [double]$PauseMs = 450,
    [string]$Voice = 'Microsoft David Desktop',
    [double]$Pitch = 62,            # the buzz the words ride on (Hz): lower = darker (v2 82; Josh: 'deeper in tone')
    [double]$Semitones = -3,        # the voice itself shifted down before the vocoder (formants too: bigger, not just lower)
    [string]$SpeakPitch = '-25%',   # SAPI's own pitch for the spoken words
    [double]$Dry = 0.55,            # the plain voice's share against the vocoder's (loudness-matched): the WORDS (v1 0.18 was unintelligible)
    [double]$Crush = 0.22,          # the digitized share (sample-and-hold to 16 kHz, 10 bits)
    [double]$EchoMs = 520, [double]$EchoFb = 0.35,
    [double]$Room = 0.88, [double]$Wet = 0.38, [double]$PreDelayMs = 70, [double]$Tail = 5.0,
    [string]$Rate = '-20%',
    [double]$Duck = 0.85,           # how far the echo and reverb are pulled down under the words (0 = not at all)
    [ValidateSet('mix','crush','echo','full')][string]$Stage = 'full',      # stop after this stage (for testing what each costs in clarity)
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = Join-Path $here '11-loading-raptormod.wav' }
Add-Type -AssemblyName System.Speech
Add-Type -TypeDefinition @'
using System; using System.IO;
public static class VoiceFx {
    const int SR = 44100;
    // RBJ band-pass (constant 0 dB peak)
    class BP { double b0, b2, a1, a2, x1, x2, y1, y2;
        public BP(double fc, double q) { double w = 2 * Math.PI * fc / SR, al = Math.Sin(w) / (2 * q), a0 = 1 + al; b0 = al / a0; b2 = -al / a0; a1 = -2 * Math.Cos(w) / a0; a2 = (1 - al) / a0; }
        public double Run(double x) { double y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2; x2 = x1; x1 = x; y2 = y1; y1 = y; return y; } }
    public static float[] Read16Mono(string path, out int rate) {
        var b = File.ReadAllBytes(path); int p = 12; rate = 22050; int ch = 1, data = -1, len = 0;
        while (p + 8 <= b.Length) { string id = System.Text.Encoding.ASCII.GetString(b, p, 4); int sz = BitConverter.ToInt32(b, p + 4);
            if (id == "fmt ") { ch = BitConverter.ToInt16(b, p + 10); rate = BitConverter.ToInt32(b, p + 12); }
            if (id == "data") { data = p + 8; len = Math.Min(sz, b.Length - data); break; } p += 8 + sz + (sz & 1); }
        int n = len / 2 / ch; var o = new float[n]; for (int i = 0; i < n; i++) o[i] = BitConverter.ToInt16(b, data + i * 2 * ch) / 32768f; return o; }
    public static float[] Resample(float[] x, int from) {
        int n = (int)((long)x.Length * SR / from); var o = new float[n];
        for (int i = 0; i < n; i++) { double s = (double)i * from / SR; int k = (int)s; double f = s - k; o[i] = (float)(x[Math.Min(k, x.Length - 1)] * (1 - f) + x[Math.Min(k + 1, x.Length - 1)] * f); } return o; }
    // the vocoder: the voice's band envelopes laid on a buzz (low bands) and noise (the top ones)
    public static float[] Vocode(float[] v, double pitch, double dry, int pad, int tail) {
        int n = v.Length + pad + tail; var outp = new double[n]; const int B = 32; double lo = 90, hi = 9000;
        var rnd = new Random(7); double ph1 = 0, ph2 = 0, ph3 = 0;
        var ana = new BP[B]; var syn = new BP[B]; var env = new double[B]; var fc = new double[B];
        for (int b = 0; b < B; b++) { fc[b] = lo * Math.Pow(hi / lo, (b + 0.5) / B); ana[b] = new BP(fc[b], 7.5); syn[b] = new BP(fc[b], 7.5); }
        double att = 1 - Math.Exp(-1.0 / (0.004 * SR)), rel = 1 - Math.Exp(-1.0 / (0.025 * SR));
        for (int i = 0; i < n; i++) {
            int j = i - pad; double x = j >= 0 && j < v.Length ? v[j] : 0;
            // the carrier: two saws a hair apart and a sub sine an octave down -- a thick, low synth buzz
            ph1 += pitch / SR; ph1 -= Math.Floor(ph1); ph2 += pitch * 1.006 / SR; ph2 -= Math.Floor(ph2); ph3 += pitch * 0.5 / SR; ph3 -= Math.Floor(ph3);
            double buzz = (2 * ph1 - 1) * 0.5 + (2 * ph2 - 1) * 0.5 + 0.35 * Math.Sin(2 * Math.PI * ph3);
            double noise = rnd.NextDouble() * 2 - 1, y = 0;
            for (int b = 0; b < B; b++) {
                double a = Math.Abs(ana[b].Run(x)); env[b] += (a > env[b] ? att : rel) * (a - env[b]);
                double car = fc[b] > 4200 ? noise : (fc[b] > 2600 ? 0.6 * buzz + 0.5 * noise : buzz);
                y += syn[b].Run(car) * env[b] * (1.0 + b * 0.06);
            }
            outp[i] = y;
        }
        // the plain voice beside it, loudness-matched (RMS), mixed dry : vocoder
        var plain = new double[n]; for (int i = 0; i < n; i++) { int j = i - pad; plain[i] = j >= 0 && j < v.Length ? v[j] : 0; }
        double rv = Rms(outp), rp = Rms(plain); var mix = new double[n];
        for (int i = 0; i < n; i++) mix[i] = (1 - dry) * outp[i] / rv + dry * plain[i] / rp;
        return Norm(mix, 0.7); }
    static double Rms(double[] x) { double s = 0; int c = 0; foreach (var v in x) if (v != 0) { s += v * v; c++; } return Math.Sqrt(s / Math.Max(1, c)) + 1e-12; }
    // digitized: sample-and-hold to 16 kHz at 10 bits, mixed in
    public static float[] Crush(float[] x, double mix) {
        var o = new float[x.Length]; double held = 0, acc = 0, step = 16000.0 / SR, q = 512;
        for (int i = 0; i < x.Length; i++) { acc += step; if (acc >= 1) { acc -= 1; held = Math.Round(x[i] * q) / q; } o[i] = (float)(x[i] * (1 - mix) + held * mix); } return o; }
    // DUCKING: how far the effects are pulled down at each moment -- deep while the voice speaks, back up within
    // ~0.35 s of it stopping. The words stay clear; the echo and the hall bloom in the gaps and after the phrase.
    public static float[] Duck(float[] voice, double depth) {
        int n = voice.Length; var g = new float[n]; double env = 0, peak = 1e-9, att = 1 - Math.Exp(-1.0 / (0.005 * SR)), rel = 1 - Math.Exp(-1.0 / (0.35 * SR));
        var e = new double[n]; for (int i = 0; i < n; i++) { double a = Math.Abs(voice[i]); env += (a > env ? att : rel) * (a - env); e[i] = env; peak = Math.Max(peak, env); }
        for (int i = 0; i < n; i++) g[i] = (float)(1 - depth * Math.Min(1, e[i] / (peak * 0.5)));
        return g; }
    public static float[] Gains = null;
    // stereo ping-pong echo, darker each time round
    public static void Echo(float[] m, out float[] L, out float[] R, double ms, double fb) {
        int n = m.Length, d = (int)(ms * SR / 1000); L = new float[n]; R = new float[n]; var bl = new double[d]; var br = new double[d]; int p = 0; double lpL = 0, lpR = 0, k = 1 - Math.Exp(-2 * Math.PI * 3200.0 / SR);
        for (int i = 0; i < n; i++) { double el = bl[p], er = br[p]; lpL += k * (el - lpL); lpR += k * (er - lpR);
            bl[p] = m[i] * 0.8 + lpR * fb; br[p] = lpL * fb;           // left feeds right feeds left
            double gk = Gains != null && i < Gains.Length ? Gains[i] : 1;
            L[i] = (float)(m[i] + el * 0.6 * gk); R[i] = (float)(m[i] + er * 0.6 * gk); p = (p + 1) % d; } }
    // Freeverb: eight damped combs and four all-passes per side (the right side spread by 23 samples)
    static readonly int[] CT = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 }, AT = { 556, 441, 341, 225 };
    public static float[] Verb(float[] x, double room, double damp, double wet, int spread, int pre) {
        int n = x.Length; var o = new float[n]; double fbk = 0.7 + 0.28 * room;
        var cb = new double[8][]; var cs = new double[8]; var ci = new int[8]; for (int c = 0; c < 8; c++) cb[c] = new double[CT[c] + spread];
        var ab = new double[4][]; var ai = new int[4]; for (int a = 0; a < 4; a++) ab[a] = new double[AT[a] + spread];
        for (int i = 0; i < n; i++) {
            double inp = (i >= pre ? x[i - pre] : 0) * 0.015, s = 0;
            for (int c = 0; c < 8; c++) { double y = cb[c][ci[c]]; cs[c] = y * (1 - damp) + cs[c] * damp; cb[c][ci[c]] = inp + cs[c] * fbk; ci[c] = (ci[c] + 1) % cb[c].Length; s += y; }
            for (int a = 0; a < 4; a++) { double bo = ab[a][ai[a]], y = -s + bo; ab[a][ai[a]] = s + bo * 0.5; ai[a] = (ai[a] + 1) % ab[a].Length; s = y; }
            double gk = Gains != null && i < Gains.Length ? Gains[i] : 1;
            o[i] = (float)(x[i] * (1 - wet * 0.5) + s * wet * 3.0 * gk); }
        return o; }
    static float[] Norm(double[] x, double peak) { double m = 1e-9; foreach (var v in x) m = Math.Max(m, Math.Abs(v)); var o = new float[x.Length]; for (int i = 0; i < x.Length; i++) o[i] = (float)(x[i] / m * peak); return o; }
    public static void WriteStereo(string path, float[] L, float[] R) {
        int n = Math.Min(L.Length, R.Length); double m = 1e-9; for (int i = 0; i < n; i++) m = Math.Max(m, Math.Max(Math.Abs(L[i]), Math.Abs(R[i])));
        double k = 0.89 / m; int fade = SR / 2;
        using (var w = new BinaryWriter(File.Create(path))) {
            w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 4); w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)2); w.Write(SR); w.Write(SR * 4); w.Write((short)4); w.Write((short)16);
            w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(n * 4);
            for (int i = 0; i < n; i++) { double f = Math.Min(1.0, (n - i) / (double)fade); w.Write((short)Math.Round(L[i] * k * f * 32767)); w.Write((short)Math.Round(R[i] * k * f * 32767)); } } }
}
'@
$tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'azt-voice-src.wav')
$sp = New-Object System.Speech.Synthesis.SpeechSynthesizer
try { $sp.SelectVoice($Voice) } catch { Write-Host "voice '$Voice' not found -- using the default" -ForegroundColor Yellow }
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(22050, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$sp.SetOutputToWaveFile($tmp, $fmt)
$sp.SpeakSsml(('<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US"><prosody rate="{1}" pitch="{2}">{0}</prosody></speak>' -f ([Security.SecurityElement]::Escape($Text) -replace '\s*\.\.\.\s*', ('<break time="{0}ms"/>' -f [int]$PauseMs)), $Rate, $SpeakPitch))
$sp.SetOutputToNull(); $sp.Dispose()
$rate = 0; $src = [VoiceFx]::Read16Mono($tmp, [ref]$rate); Remove-Item $tmp -ErrorAction SilentlyContinue
$v = [VoiceFx]::Resample($src, [int][Math]::Round($rate * [Math]::Pow(2, $Semitones / 12.0)))      # (a lower rate read back at 44.1 kHz: down $Semitones)
$voc = [VoiceFx]::Vocode($v, $Pitch, $Dry, [int](0.15 * 44100), [int]($Tail * 44100))
if ($Stage -eq 'mix') { [VoiceFx]::WriteStereo($Out, $voc, $voc); "stage mix -> $Out"; return }
$cr = [VoiceFx]::Crush($voc, $Crush)
if ($Stage -eq 'crush') { [VoiceFx]::WriteStereo($Out, $cr, $cr); "stage crush -> $Out"; return }
[VoiceFx]::Gains = [VoiceFx]::Duck($cr, $Duck)
$L = $null; $R = $null; [VoiceFx]::Echo($cr, [ref]$L, [ref]$R, $EchoMs, $EchoFb)
if ($Stage -eq 'echo') { [VoiceFx]::WriteStereo($Out, $L, $R); "stage echo -> $Out"; return }
$pre = [int]($PreDelayMs * 44.1)
$L2 = [VoiceFx]::Verb($L, $Room, 0.35, $Wet, 0, $pre); $R2 = [VoiceFx]::Verb($R, $Room, 0.35, $Wet, 23, $pre)
[VoiceFx]::WriteStereo($Out, $L2, $R2)
"{0}: {1:N2} s (speech {2:N2} s), pitch {3} Hz, echo {4} ms x {5}, reverb room {6} wet {7}" -f $Out, ($L2.Length / 44100.0), ($v.Length / 44100.0), $Pitch, $EchoMs, $EchoFb, $Room, $Wet
