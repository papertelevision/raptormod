# Upscale-Room.ps1 -- AI-upscale a room's textures for the TRUE-COLOUR renderer, in one batch.
#
#   .\tools\Upscale-Room.ps1 -Room CORICORI
#   .\tools\Upscale-Room.ps1 -Room CORICORI -Sheet        (also writes before/after sheets)
#   .\tools\Upscale-Room.ps1 -Room CORICORI -Revert       (take this room's replacements out)
#
# The game's own files are not touched. Results go to C:\Games\RaptorMod\textures\hires under the
# textures' own file names, which is where Watch-HostRender -TrueColour looks for replacement
# art (see -TexOverrideDir). Deleting a file there puts that texture back to the original.
#
# THE TEXTURES CARRY THE LIGHTING. This game has no lights: every shadow, every pool of
# torchlight and every black void round a piece of art is PAINTED INTO the texture. An
# upscaler knows none of that -- it will happily brighten a shadow it takes for noise, or grow
# detail into the black. So the upscaler is only trusted for FINE detail, and the original
# decides everything else:
#
#   1. each texture is padded with a wrapped copy of itself, so one that tiles still tiles;
#   2. Real-ESRGAN (the portable ncnn-vulkan build) enlarges the whole folder 4x in one run;
#   3. LIGHT LOCK: the enlarged picture is divided by its own blur and multiplied by the
#      ORIGINAL's blur, per colour channel. Over any patch a couple of original texels across,
#      the result therefore has exactly the original's brightness and colour -- shadows,
#      gradients and black space come out where and as dark as the artists put them -- and
#      what survives from the upscaler is only the detail finer than that.
#
# The original still decides where a texture has holes (the renderer reads that from the
# game's own copy), so cut-out shapes are unchanged.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Room,
    [int]$Scale = 4,
    [string]$Model = 'realesrgan-x4plus',
    [string]$ExeDir   = 'C:\Games\RaptorMod\sources\realesrgan',
    [string]$CacheDir = 'C:\Games\RaptorMod\cache',
    [string]$OutDir   = 'C:\Games\RaptorMod\textures\hires',
    [string]$WorkDir  = 'C:\Games\RaptorMod\textures\upscale-work',
    [double]$LockTexels = 2.0,        # the light lock's reach, in ORIGINAL texels
    # THE LOOK (see Fx.Finish). The defaults are the first batch: all upscaler, nothing added.
    [ValidateRange(0.0, 1.0)][double]$Blend = 1.0,
    [ValidateRange(0.0, 3.0)][double]$Sharpen = 0.0,
    [ValidateRange(0.0, 3.0)][double]$Grain = 0.0,
    [ValidateRange(0.0, 1.0)][double]$GrainTint = 0.0,     # 0 = grey grain; above 0, that share of it differs per colour channel
    [switch]$ColourFromOriginal,                             # hue and saturation from the original; only brightness from the upscaler
    [ValidateRange(0.0, 2.0)][double]$Detail = 0.0,          # the original's own fine grime laid back over the upscale (see Fx.Finish)
    [ValidateRange(0.0, 1.5)][double]$Clarity = 0.0,         # local contrast over a few texels
    # -Ladder NAME.png: do not replace anything; write ONE picture of that texture finished
    # several ways side by side, for choosing the settings by eye. Needs a previous run of this
    # room (it reuses the upscaler's output).
    [string]$Ladder = '',
    [int]$LadderX = -1, [int]$LadderY = -1, [int]$LadderSize = 96,     # the patch to show, in ORIGINAL texels
    [int]$Pad = 16,                   # wrapped border given to the upscaler, in original texels
    [switch]$Sheet,
    [switch]$Revert,
    [switch]$Force                    # redo textures that already have a replacement
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('AztTex.Fx' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
namespace AztTex {
public static class Fx {
    public static int[] Load(string path, out int w, out int h) {
        using (var src = (Bitmap)Image.FromFile(path)) using (var bm = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb)) {
            using (var g = Graphics.FromImage(bm)) { g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy; g.DrawImage(src, 0, 0, src.Width, src.Height); }
            w = bm.Width; h = bm.Height; var px = new int[w * h];
            var bd = bm.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try { for (int y = 0; y < h; y++) Marshal.Copy(new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), px, y * w, w); } finally { bm.UnlockBits(bd); }
            return px; } }
    public static void Save(string path, int[] px, int w, int h) {
        using (var bm = new Bitmap(w, h, PixelFormat.Format32bppRgb)) {
            var bd = bm.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
            try { for (int y = 0; y < h; y++) Marshal.Copy(px, y * w, new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), w); } finally { bm.UnlockBits(bd); }
            bm.Save(path, ImageFormat.Png); } }
    // transparent texels become black: that is what the game shows there, and what the upscaler should see
    public static void Flatten(int[] px) { for (int i = 0; i < px.Length; i++) { if (((px[i] >> 24) & 255) < 128) px[i] = 0; else px[i] &= 0xFFFFFF; } }
    // bring a noise field to a given strength (root mean square): the coarser grain of a bigger
    // texture must be exactly as strong as the fine grain of a smaller one (0.32 is what the 4x recipe measures)
    public static void Level(float[] n, float rms) { double q = 0; for (int i = 0; i < n.Length; i++) q += (double)n[i] * n[i]; float k = (float)(rms / Math.Sqrt(q / n.Length + 1e-12)); for (int i = 0; i < n.Length; i++) n[i] *= k; }
    public static int[] Half(int[] px, int w, int h) {
        int W = w / 2, H = h / 2; var o = new int[W * H];
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            int a = px[(2 * y) * w + 2 * x], b = px[(2 * y) * w + 2 * x + 1], c = px[(2 * y + 1) * w + 2 * x], d = px[(2 * y + 1) * w + 2 * x + 1];
            int r = (((a >> 16) & 255) + ((b >> 16) & 255) + ((c >> 16) & 255) + ((d >> 16) & 255) + 2) >> 2;
            int g = (((a >> 8) & 255) + ((b >> 8) & 255) + ((c >> 8) & 255) + ((d >> 8) & 255) + 2) >> 2;
            int bl = ((a & 255) + (b & 255) + (c & 255) + (d & 255) + 2) >> 2;
            o[y * W + x] = (r << 16) | (g << 8) | bl; }
        return o; }
    public static int[] PadWrap(int[] px, int w, int h, int pad) {
        int W = w + 2 * pad, H = h + 2 * pad; var o = new int[W * H];
        for (int y = 0; y < H; y++) { int sy = ((y - pad) % h + h) % h; for (int x = 0; x < W; x++) { int sx = ((x - pad) % w + w) % w; o[y * W + x] = px[sy * w + sx]; } }
        return o; }
    public static int[] Crop(int[] px, int w, int x0, int y0, int cw, int ch) {
        var o = new int[cw * ch]; for (int y = 0; y < ch; y++) Array.Copy(px, (y0 + y) * w + x0, o, y * cw, cw); return o; }
    // bilinear enlargement that WRAPS, texel centres aligned the way the renderer samples them
    public static float[] UpChannel(int[] px, int w, int h, int scale, int shift) {
        int W = w * scale, H = h * scale; var o = new float[W * H];
        for (int y = 0; y < H; y++) { float fy = (y + 0.5f) / scale - 0.5f; int y0 = (int)Math.Floor(fy); float wy = fy - y0; int ya = ((y0 % h) + h) % h, yb = (ya + 1) % h;
            for (int x = 0; x < W; x++) { float fx = (x + 0.5f) / scale - 0.5f; int x0 = (int)Math.Floor(fx); float wx = fx - x0; int xa = ((x0 % w) + w) % w, xb = (xa + 1) % w;
                float a = (px[ya * w + xa] >> shift) & 255, b = (px[ya * w + xb] >> shift) & 255, c = (px[yb * w + xa] >> shift) & 255, d = (px[yb * w + xb] >> shift) & 255;
                o[y * W + x] = (a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy; } }
        return o; }
    public static float[] Channel(int[] px, int shift) { var o = new float[px.Length]; for (int i = 0; i < px.Length; i++) o[i] = (px[i] >> shift) & 255; return o; }
    // three box blurs, wrapping: close to a Gaussian, and a texture that tiles stays tiling
    public static float[] Blur(float[] src, int w, int h, int r) {
        var a = (float[])src.Clone(); var b = new float[a.Length]; float inv = 1f / (2 * r + 1);
        for (int pass = 0; pass < 3; pass++) {
            for (int y = 0; y < h; y++) { int row = y * w; float s = 0; for (int k = -r; k <= r; k++) s += a[row + ((k % w) + w) % w];
                for (int x = 0; x < w; x++) { b[row + x] = s * inv; s += a[row + (x + r + 1) % w] - a[row + ((x - r) % w + w) % w]; } }
            for (int x = 0; x < w; x++) { float s = 0; for (int k = -r; k <= r; k++) s += b[(((k % h) + h) % h) * w + x];
                for (int y = 0; y < h; y++) { a[y * w + x] = s * inv; s += b[((y + r + 1) % h) * w + x] - b[(((y - r) % h + h) % h) * w + x]; } }
        }
        return a; }
    // THE LIGHT LOCK. up = the upscaler's picture; orig = the original, enlarged plainly.
    public static int[] LightLock(int[] up, int[] orig, int ow, int oh, int scale, int radius, out double meanBefore, out double meanAfter) {
        int W = ow * scale, H = oh * scale; var res = new int[W * H]; double mb = 0, ma = 0;
        for (int shift = 16; shift >= 0; shift -= 8) {
            float[] u = Channel(up, shift), o = UpChannel(orig, ow, oh, scale, shift);
            float[] bu = Blur(u, W, H, radius), bo = Blur(o, W, H, radius);
            for (int i = 0; i < res.Length; i++) {
                mb += Math.Abs(bu[i] - bo[i]);
                float k = (bo[i] + 0.75f) / (bu[i] + 0.75f); if (k > 3f) k = 3f;
                float v = u[i] * k; if (v > 255f) v = 255f; if (v < 0f) v = 0f;
                res[i] |= ((int)(v + 0.5f)) << shift; }
            float[] br = Blur(Channel(res, shift), W, H, radius);
            for (int i = 0; i < res.Length; i++) ma += Math.Abs(br[i] - bo[i]);
        }
        meanBefore = mb / (3.0 * res.Length); meanAfter = ma / (3.0 * res.Length); return res; }
    // THE BALANCE BETWEEN THE ORIGINAL AND THE UPSCALE, after the light lock:
    //   blend    how much of the upscaler's picture is used; the rest is the original, plainly
    //            enlarged. 1 = all upscaler, 0 = the original.
    //   sharpen  pushes each pixel away from the average of its 3x3 neighbourhood.
    //   grain    fine noise, the same on all three channels and stronger where the picture is
    //            brighter. The originals are digitised photographs and have it; the upscaler
    //            removes it, which is most of what reads as "smooth" and "painted". Nothing
    //            is added where the picture is black, so black space stays black.
    // None of the three changes the average brightness of an area, so the lock still holds.
    public static int[] Finish(int[] locked, int[] orig, int ow, int oh, int scale, float blend, float sharpen, float grain, int seed) {
        return Finish(locked, orig, ow, oh, scale, blend, sharpen, grain, seed, false, 0f); }
    public static int[] Finish(int[] locked, int[] orig, int ow, int oh, int scale, float blend, float sharpen, float grain, int seed, bool chromaFromOrig, float grainTint) {
        return Finish(locked, orig, ow, oh, scale, blend, sharpen, grain, seed, chromaFromOrig, grainTint, 0f, 0f); }
    // GRIT, two ways, both from the picture itself rather than from noise:
    //   detail   the ORIGINAL's own fine texture -- its dirt, speckle and scratches, everything
    //            smaller than a couple of texels -- lifted off the original and laid back over
    //            the upscaler's cleaned-up surface, at this strength. 1 = as strong as it was.
    //   clarity  local contrast: each pixel pushed away from the average of a patch a few
    //            texels across, so light and dark patches of grime separate more.
    public static int[] Finish(int[] locked, int[] orig, int ow, int oh, int scale, float blend, float sharpen, float grain, int seed, bool chromaFromOrig, float grainTint, float detail, float clarity) {
        int W = ow * scale, H = oh * scale; var res = new int[W * H];
        // THE SAME GRAIN AND THE SAME SHARPEN AT ANY SCALE: both are sized against the ORIGINAL
        // texel (a quarter of one), not against the output pixel -- or an 8x texture would get
        // grain half as coarse as the 4x one and read as smoother, not as the same look sharper.
        int fr = Math.Max(1, scale / 4);
        var rnd = new Random(seed); var noise = new float[W * H];
        if (grain > 0f) {
            for (int i = 0; i < noise.Length; i++) noise[i] = (float)(rnd.NextDouble() + rnd.NextDouble() - 1.0);
            // half of it a little coarser than one pixel, so it survives being seen from a step away
            var coarse = Blur(noise, W, H, fr); for (int i = 0; i < noise.Length; i++) noise[i] = (fr > 1 ? 0.35f : 0.6f) * noise[i] + (fr > 1 ? 2.6f : 1.6f) * coarse[i]; if (fr > 1) Level(noise, 0.32f);
        }
        float[] lum = null;
        if (grain > 0f) { lum = new float[W * H]; for (int i = 0; i < lum.Length; i++) { int c = locked[i]; lum[i] = (((c >> 16) & 255) * 77 + ((c >> 8) & 255) * 150 + (c & 255) * 29) / 256f; } lum = Blur(lum, W, H, 1); }
        var ch = new float[3][]; var oc = new float[3][];
        for (int c = 0; c < 3; c++) {
            int shift = 16 - 8 * c;
            float[] v = Channel(locked, shift);
            if (blend < 1f || chromaFromOrig) oc[c] = UpChannel(orig, ow, oh, scale, shift);
            if (blend < 1f) { float[] o = oc[c]; for (int i = 0; i < v.Length; i++) v[i] = o[i] + blend * (v[i] - o[i]); }
            if (detail > 0f) {
                float[] o = oc[c] != null ? oc[c] : UpChannel(orig, ow, oh, scale, shift);
                float[] ob = Blur(o, W, H, Math.Max(1, scale));            // the original without its fine texture
                for (int i = 0; i < v.Length; i++) v[i] += detail * (o[i] - ob[i]);
            }
            if (clarity > 0f) { float[] b = Blur(v, W, H, Math.Max(2, 3 * scale)); for (int i = 0; i < v.Length; i++) v[i] += clarity * (v[i] - b[i]); }
            if (sharpen > 0f) { float[] b = Blur(v, W, H, fr); for (int i = 0; i < v.Length; i++) v[i] += sharpen * (v[i] - b[i]); }
            ch[c] = v;
        }
        // COLOUR ENTIRELY FROM THE ORIGINAL. The upscaler is asked only "how bright is this
        // pixel"; what colour it is comes from the original at the same place, scaled to that
        // brightness. No hue or saturation the artists did not paint can appear. Where the
        // original is black it has no colour to give, and the pixel is left as it was.
        if (chromaFromOrig) {
            float[] r = ch[0], g = ch[1], b = ch[2], or = oc[0], og = oc[1], ob = oc[2];
            for (int i = 0; i < r.Length; i++) {
                float y = 0.299f * r[i] + 0.587f * g[i] + 0.114f * b[i], yo = 0.299f * or[i] + 0.587f * og[i] + 0.114f * ob[i];
                float w = yo / 6f; if (w > 1f) w = 1f; if (w <= 0f) continue;
                float k = y / (yo + 0.5f); if (k > 4f) k = 4f; if (k < 0f) k = 0f;
                r[i] += w * (or[i] * k - r[i]); g[i] += w * (og[i] * k - g[i]); b[i] += w * (ob[i] * k - b[i]);
            }
        }
        for (int c = 0; c < 3; c++) {
            int shift = 16 - 8 * c; float[] v = ch[c];
            // THE GRAIN'S COLOUR: grainTint of it is this channel's own noise, the rest shared by
            // all three. 0 is pure grey grain; a little tint is how scanned film actually looks.
            float[] own = null;
            if (grain > 0f && grainTint > 0f) {
                own = new float[W * H]; for (int i = 0; i < own.Length; i++) own[i] = (float)(rnd.NextDouble() + rnd.NextDouble() - 1.0);
                var coarse2 = Blur(own, W, H, fr); for (int i = 0; i < own.Length; i++) own[i] = (fr > 1 ? 0.35f : 0.6f) * own[i] + (fr > 1 ? 2.6f : 1.6f) * coarse2[i]; if (fr > 1) Level(own, 0.32f);
            }
            for (int i = 0; i < v.Length; i++) {
                float x = v[i];
                if (grain > 0f && lum[i] > 2.5f) {
                    float nz = own == null ? noise[i] : (1f - grainTint) * noise[i] + grainTint * own[i];
                    x += nz * grain * (2.0f + 0.10f * lum[i]);
                }
                if (x < 0f) x = 0f; else if (x > 255f) x = 255f;
                res[i] |= ((int)(x + 0.5f)) << shift; }
        }
        return res; }
    public static int[] UpPlain(int[] orig, int ow, int oh, int scale) {
        int W = ow * scale, H = oh * scale; var res = new int[W * H];
        for (int shift = 16; shift >= 0; shift -= 8) { float[] o = UpChannel(orig, ow, oh, scale, shift); for (int i = 0; i < res.Length; i++) res[i] |= ((int)(o[i] + 0.5f)) << shift; }
        return res; }
} }
'@
}

$mtl = Join-Path $CacheDir ("{0}.mtl" -f $Room)
if (-not (Test-Path $mtl)) { throw "no material file for $Room in $CacheDir -- has the renderer loaded this room at least once?" }
$names = @([IO.File]::ReadAllLines($mtl) | Where-Object { $_.Trim().StartsWith('map_Kd ') } | ForEach-Object { $_.Trim().Substring(7).Trim() } | Select-Object -Unique |
           Where-Object { Test-Path (Join-Path $CacheDir $_) })
if (-not $names.Count) { throw "$Room has no textures" }
New-Item -ItemType Directory -Force $OutDir | Out-Null

if ($Revert) {
    $n = 0; foreach ($nm in $names) { $f = Join-Path $OutDir $nm; if (Test-Path $f) { Remove-Item $f -Confirm:$false; $n++ } }
    Write-Host ("{0}: {1} replacement texture(s) removed from {2}; the originals show again" -f $Room, $n, $OutDir) -ForegroundColor Green
    return
}

if ($Ladder) {
    $upPath = Join-Path (Join-Path $WorkDir ("{0}-up" -f $Room)) $Ladder
    if (-not (Test-Path $upPath)) { throw "no upscaler output for $Ladder -- run this room once first" }
    $tw = 0; $th = 0; $opx = [AztTex.Fx]::Load((Join-Path $CacheDir $Ladder), [ref]$tw, [ref]$th); [AztTex.Fx]::Flatten($opx)
    $uw = 0; $uh = 0; $up = [AztTex.Fx]::Load($upPath, [ref]$uw, [ref]$uh)
    $padN = [int](($uw / $Scale - $tw) / 2)
    $crop = [AztTex.Fx]::Crop($up, $uw, $padN * $Scale, $padN * $Scale, $tw * $Scale, $th * $Scale)
    $b0 = 0.0; $a0 = 0.0
    $locked = [AztTex.Fx]::LightLock($crop, $opx, $tw, $th, $Scale, [int][Math]::Max(1, [Math]::Round($LockTexels * $Scale)), [ref]$b0, [ref]$a0)
    # the approved recipe (A) and seven ways of adding grit to it
    $variants = @(
        @{ T = 'A  approved recipe (as installed)';      B = 1.0; S = 0.8; G = 2.0; C = $true; N = 0.35; D = 0.0; K = 0.0 },
        @{ T = 'B  + original grime 0.7';                B = 1.0; S = 0.8; G = 2.0; C = $true; N = 0.35; D = 0.7; K = 0.0 },
        @{ T = 'C  + original grime 1.2';                B = 1.0; S = 0.8; G = 2.0; C = $true; N = 0.35; D = 1.2; K = 0.0 },
        @{ T = 'D  + clarity 0.5';                       B = 1.0; S = 0.8; G = 2.0; C = $true; N = 0.35; D = 0.0; K = 0.5 },
        @{ T = 'E  + grime 0.7 + clarity 0.5';           B = 1.0; S = 0.8; G = 2.0; C = $true; N = 0.35; D = 0.7; K = 0.5 },
        @{ T = 'F  + grain 3.0';                         B = 1.0; S = 0.8; G = 3.0; C = $true; N = 0.35; D = 0.0; K = 0.0 },
        @{ T = 'G  + grime 0.7 + grain 3.0';             B = 1.0; S = 0.8; G = 3.0; C = $true; N = 0.35; D = 0.7; K = 0.0 },
        @{ T = 'H  80% upscaler + grime 1.0 + clarity 0.4'; B = 0.8; S = 0.8; G = 2.0; C = $true; N = 0.35; D = 1.0; K = 0.4 })
    $ps = $LadderSize * $Scale
    $lx = $(if ($LadderX -ge 0) { $LadderX } else { [int](($tw - $LadderSize) / 2) }); $ly = $(if ($LadderY -ge 0) { $LadderY } else { [int](($th - $LadderSize) / 2) })
    $cols = 4; $rowsN = [int][Math]::Ceiling($variants.Count / $cols); $lab = 26
    $bm = New-Object System.Drawing.Bitmap -ArgumentList ([int]($cols * ($ps + 6))), ([int]($rowsN * ($ps + $lab + 6)))
    $gr = [System.Drawing.Graphics]::FromImage($bm); $gr.Clear([System.Drawing.Color]::FromArgb(255, 24, 24, 24))
    $font = New-Object System.Drawing.Font('Segoe UI', 11); $ink = [System.Drawing.Brushes]::White
    for ($vi = 0; $vi -lt $variants.Count; $vi++) {
        $vv = $variants[$vi]
        $px = [AztTex.Fx]::Finish($locked, $opx, $tw, $th, $Scale, [single]$vv.B, [single]$vv.S, [single]$vv.G, $Ladder.GetHashCode(), [bool]$vv.C, [single]$vv.N, [single]$vv.D, [single]$vv.K)
        $patch = [AztTex.Fx]::Crop($px, $tw * $Scale, $lx * $Scale, $ly * $Scale, $ps, $ps)
        $tmp = Join-Path $WorkDir '_ladder-patch.png'; [AztTex.Fx]::Save($tmp, $patch, $ps, $ps)
        $pi2 = [System.Drawing.Image]::FromFile($tmp)
        $ox = ($vi % $cols) * ($ps + 6) + 3; $oy = [int][Math]::Floor($vi / $cols) * ($ps + $lab + 6) + 3
        $gr.DrawImage($pi2, $ox, $oy + $lab, $ps, $ps); $pi2.Dispose()
        $gr.DrawString($vv.T, $font, $ink, [single]$ox, [single]($oy + 2))
    }
    $gr.Dispose(); $outP = Join-Path $WorkDir ("ladder-{0}-{1}" -f $Room, $Ladder); $bm.Save($outP, [System.Drawing.Imaging.ImageFormat]::Png); $bm.Dispose()
    Write-Host ("ladder written: {0}" -f $outP) -ForegroundColor Green
    return
}

$exe = Join-Path $ExeDir 'realesrgan-ncnn-vulkan.exe'
if (-not (Test-Path $exe)) { throw "Real-ESRGAN was not found at $exe" }
$todo = @($names | Where-Object { $Force -or -not (Test-Path (Join-Path $OutDir $_)) })
Write-Host ("{0}: {1} textures, {2} to do (x{3}, model {4})" -f $Room, $names.Count, $todo.Count, $Scale, $Model)
if (-not $todo.Count) { Write-Host 'nothing to do (use -Force to redo)'; return }

$inDir = Join-Path $WorkDir ("{0}-in" -f $Room); $upDir = Join-Path $WorkDir ("{0}-up" -f $Room)
foreach ($d in $inDir, $upDir) { if (Test-Path $d) { Get-ChildItem $d -File | Remove-Item -Confirm:$false }; New-Item -ItemType Directory -Force $d | Out-Null }

# 1. the padded, flattened originals
$orig = @{}
foreach ($nm in $todo) {
    $tw = 0; $th = 0; $px = [AztTex.Fx]::Load((Join-Path $CacheDir $nm), [ref]$tw, [ref]$th)
    [AztTex.Fx]::Flatten($px)
    $orig[$nm] = @{ Px = $px; W = $tw; H = $th }
    $padN = [Math]::Min($Pad, [Math]::Min($tw, $th))
    [AztTex.Fx]::Save((Join-Path $inDir $nm), [AztTex.Fx]::PadWrap($px, $tw, $th, $padN), $tw + 2 * $padN, $th + 2 * $padN)
    $orig[$nm].Pad = $padN
}

# 2. the upscaler, once, over the folder
$clock = [Diagnostics.Stopwatch]::StartNew()
$log = Join-Path $WorkDir ("{0}-realesrgan.log" -f $Room)
$p = Start-Process -FilePath $exe -ArgumentList @('-i', "`"$inDir`"", '-o', "`"$upDir`"", '-n', $Model, '-s', '4', '-f', 'png') -WorkingDirectory $ExeDir -NoNewWindow -Wait -PassThru -RedirectStandardError $log -RedirectStandardOutput ($log + '.out')
# -Scale 8: THE UPSCALER AGAIN, ON ITS OWN OUTPUT (16x), then halved. The model only knows how
# to make 4x; a second pass re-draws every edge it made in the first with four times the
# pixels, and averaging that down by two gives an 8x picture with clean, unstepped edges.
$srcDir = $upDir
if ($Scale -eq 8) {
    $up2Dir = Join-Path $WorkDir ("{0}-up2" -f $Room)
    if (Test-Path $up2Dir) { Get-ChildItem $up2Dir -File | Remove-Item -Confirm:$false }; New-Item -ItemType Directory -Force $up2Dir | Out-Null
    Write-Host ("  first pass done in {0:N0} s; second pass (16x) ..." -f $clock.Elapsed.TotalSeconds)
    $p = Start-Process -FilePath $exe -ArgumentList @('-i', "`"$upDir`"", '-o', "`"$up2Dir`"", '-n', $Model, '-s', '4', '-f', 'png') -WorkingDirectory $ExeDir -NoNewWindow -Wait -PassThru -RedirectStandardError ($log + '.2') -RedirectStandardOutput ($log + '.2.out')
    $srcDir = $up2Dir
}
$made = @(Get-ChildItem $srcDir -Filter *.png)
Write-Host ("Real-ESRGAN: exit code {0}, {1} of {2} pictures in {3:N0} s" -f $p.ExitCode, $made.Count, $todo.Count, $clock.Elapsed.TotalSeconds)
if ($made.Count -lt $todo.Count) { Write-Host ("  see {0}" -f $log) -ForegroundColor Yellow; Get-Content $log -Tail 8 | ForEach-Object { Write-Host "    $_" } }

# 3. the light lock, and into place
$done = 0; $rows = @()
foreach ($nm in $todo) {
    $upPath = Join-Path $srcDir $nm
    if (-not (Test-Path $upPath)) { Write-Host ("  {0}: the upscaler produced nothing -- left as the original" -f $nm) -ForegroundColor Yellow; continue }
    $o = $orig[$nm]; $uw = 0; $uh = 0
    $up = [AztTex.Fx]::Load($upPath, [ref]$uw, [ref]$uh)
    if ($Scale -eq 8) { $up = [AztTex.Fx]::Half($up, $uw, $uh); $uw = [int]($uw / 2); $uh = [int]($uh / 2) }
    if ($uw -ne ($o.W + 2 * $o.Pad) * $Scale -or $uh -ne ($o.H + 2 * $o.Pad) * $Scale) { Write-Host ("  {0}: came back {1}x{2}, not the expected size -- skipped" -f $nm, $uw, $uh) -ForegroundColor Yellow; continue }
    $crop = [AztTex.Fx]::Crop($up, $uw, $o.Pad * $Scale, $o.Pad * $Scale, $o.W * $Scale, $o.H * $Scale)
    $before = 0.0; $after = 0.0
    $res = [AztTex.Fx]::LightLock($crop, $o.Px, $o.W, $o.H, $Scale, [int][Math]::Max(1, [Math]::Round($LockTexels * $Scale)), [ref]$before, [ref]$after)
    if ($Blend -lt 1 -or $Sharpen -gt 0 -or $Grain -gt 0 -or $ColourFromOriginal -or $Detail -gt 0 -or $Clarity -gt 0) { $res = [AztTex.Fx]::Finish($res, $o.Px, $o.W, $o.H, $Scale, [single]$Blend, [single]$Sharpen, [single]$Grain, $nm.GetHashCode(), [bool]$ColourFromOriginal, [single]$GrainTint, [single]$Detail, [single]$Clarity) }
    [AztTex.Fx]::Save((Join-Path $OutDir $nm), $res, $o.W * $Scale, $o.H * $Scale)
    $rows += [pscustomobject]@{ Name = $nm; From = ('{0}x{1}' -f $o.W, $o.H); To = ('{0}x{1}' -f ($o.W * $Scale), ($o.H * $Scale)); LightOffBefore = $before; LightOffAfter = $after }
    $done++
    if ($Sheet) {
        $sheetDir = Join-Path $WorkDir ("{0}-sheets" -f $Room); New-Item -ItemType Directory -Force $sheetDir | Out-Null
        $W2 = $o.W * $Scale; $H2 = $o.H * $Scale; $plain = [AztTex.Fx]::UpPlain($o.Px, $o.W, $o.H, $Scale)
        $all = New-Object int[] ($W2 * 3 * $H2)
        for ($y = 0; $y -lt $H2; $y++) { [Array]::Copy($plain, $y * $W2, $all, $y * $W2 * 3, $W2); [Array]::Copy($crop, $y * $W2, $all, $y * $W2 * 3 + $W2, $W2); [Array]::Copy($res, $y * $W2, $all, $y * $W2 * 3 + 2 * $W2, $W2) }
        for ($i = 0; $i -lt $all.Length; $i++) { $all[$i] = $all[$i] -band 0xFFFFFF }
        [AztTex.Fx]::Save((Join-Path $sheetDir $nm), $all, $W2 * 3, $H2)
    }
}
$rows | Format-Table Name, From, To, @{ n = 'light off by (upscaler)'; e = { '{0:N2}' -f $_.LightOffBefore } }, @{ n = 'after the lock'; e = { '{0:N2}' -f $_.LightOffAfter } } -AutoSize | Out-String | Write-Host
Write-Host ("{0}: {1} replacement textures written to {2}" -f $Room, $done, $OutDir) -ForegroundColor Green
if ($Sheet) { Write-Host ("before / upscaler / final sheets: {0}" -f (Join-Path $WorkDir ("{0}-sheets" -f $Room))) }
