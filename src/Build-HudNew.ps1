# Build-HudNew.ps1 -- the NEW lower HUD (Josh, 2026-10-06): design\incoming\hud\HUD_NEW.png, with
# HUD_GLOW.png as its lit / glowing variant. Replaces Build-HudWide.ps1's panel (that script and its
# art stay, for going back).
#
# Like Build-HudWide, the panel is drawn twice from ONE mapping fixed in GAME pixels:
#   * by the GAME, in 8-bit, inside its 1600x1200 screen (HUD3 rows 977+, HUDBOT bleed, the mode
#     sprites, the log box, the inventory backing, the health bar) -- this copy decides where the
#     engine draws and where clicks land;
#   * by the HOST (tools\Panel.cs), in true colour, over it -- sliding in from both sides at the seam.
#
# THE MAPPING: game x = X0 + col * K, game y = Y0 + row * K. Unlike the previous art, this one has
# controls almost to its edges (the inventory screen at 6% of the width, the log keys at 94%), and the
# game's mouse only reaches its own 1600 columns. So K is chosen to put the inventory's text area at
# game x 20 and the log module's right edge at 1599; the art then spans about -104..1700, a little
# short of a 16:10 display's edges -- its cut-off end caps are faded out there.
#
# THE TEXT HAS NO BACKGROUND OF ITS OWN (Josh): the game's inventory backing and log box are cut from
# the panel's own 8-bit copy, and the host draws only the pixels the game draws ON them (wide\bg8.bin
# holds what those backgrounds look like on DOSBox's screen), over its own true-colour screens.
#
# OUTPUTS (art\): HUD3.PCX, HUDOFF.PCX (rows 977+), HUDBOT.RES, hud-layout.json, NBUT{0,1,2}{OFF,ON}.PCX,
# BOXOFF.PCX, BOXON.PCX, hud-box.json, INVBACK2.PCX, H1.PCX (Build-HudBar), and wide\: panel-off.png,
# panel-lit.png, modes.bin, bg8.bin, wide.json.
[CmdletBinding()]
param(
    [string]$Art       = '',
    [string]$Glow      = '',
    [string]$Expanded  = '',
    [string]$ArtDir    = '',
    [string]$StockGame = '',      # '' = the stock game this repo sits in: <Steam>\Azrael's Tear\GAME\AZRAEL
    [string]$Upscaler  = 'C:\Games\RaptorMod\sources\realesrgan\realesrgan-ncnn-vulkan.exe',
    # how much taller the opened log box is, in game rows (0 = from HUD_Expanded.png's screen)
    [int]$Extend = 0,
    [switch]$NoUpscale
)
if (-not $StockGame) { $StockGame = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'GAME\AZRAEL' }      # (in the body: $PSScriptRoot is empty in param() under -File)
$ErrorActionPreference = 'Stop'
# ($PSScriptRoot is empty in param defaults under powershell -File)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Art)    { $Art    = Join-Path $here '..\design\incoming\hud\HUD_NEW.png' }
if (-not $Glow)   { $Glow   = Join-Path $here '..\design\incoming\hud\HUD_GLOW.png' }
if (-not $Expanded) { $Expanded = Join-Path $here '..\design\incoming\hud\HUD_Expanded.png' }
if (-not $ArtDir) { $ArtDir = Join-Path $here '..\art' }
$ArtDir = (Resolve-Path $ArtDir).Path
Add-Type -Path (Join-Path $here '..\tools\Quantize.cs')
Add-Type -Path (Join-Path $here '..\tools\PcxTool.cs') -ReferencedAssemblies 'System.Drawing'
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Drawing.Drawing2D; using System.Collections.Generic;
public static class HudWide {
    public static byte[] Load(string p, out int w, out int h) {
        using (var b = new Bitmap(p)) { w = b.Width; h = b.Height; var r = new byte[w * h * 4];
            var bd = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            System.Runtime.InteropServices.Marshal.Copy(bd.Scan0, r, 0, r.Length); b.UnlockBits(bd); return r; } }
    public static Bitmap ToBitmap(byte[] px, int w, int h) {
        var b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        var bd = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        System.Runtime.InteropServices.Marshal.Copy(px, 0, bd.Scan0, px.Length); b.UnlockBits(bd); return b; }
    public static byte[] FromBitmap(Bitmap b) {
        var r = new byte[b.Width * b.Height * 4];
        var bd = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        System.Runtime.InteropServices.Marshal.Copy(bd.Scan0, r, 0, r.Length); b.UnlockBits(bd); return r; }
    public static void Save(byte[] px, int w, int h, string path) { using (var b = ToBitmap(px, w, h)) b.Save(path, ImageFormat.Png); }
    // the background (black, connected to the border) becomes transparent
    public static int Matte(byte[] px, int w, int h) {
        var bg = new bool[w * h]; var st = new Stack<int>(); int n = 0;
        for (int x = 0; x < w; x++) { st.Push(x); st.Push((h - 1) * w + x); }
        for (int y = 0; y < h; y++) { st.Push(y * w); st.Push(y * w + w - 1); }
        while (st.Count > 0) { int k = st.Pop(); if (bg[k]) continue; int o = k * 4;
            if (px[o] + px[o + 1] + px[o + 2] >= 6) continue; bg[k] = true; n++; int kx = k % w, ky = k / w;
            if (kx > 0) st.Push(k - 1); if (kx < w - 1) st.Push(k + 1); if (ky > 0) st.Push(k - w); if (ky < h - 1) st.Push(k + w); }
        // ONLY TRUE BLACK, then close the slits. The hoses' shadow sides are nearly black too, and
        // a looser cut-out (r+g+b < 54) ate them, leaving their highlights floating as dashes; the
        // gaps between their ribs ARE pure black and reach the background, so a background pixel
        // mostly surrounded by machine is put back (as black).
        var keep = new bool[w * h];
        for (int y = 2; y < h - 2; y++) for (int x = 2; x < w - 2; x++) { int i = y * w + x; if (!bg[i]) continue; int m = 0;
            for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) if (!bg[i + dy * w + dx]) m++;
            if (m >= 13) keep[i] = true; }
        for (int i = 0; i < w * h; i++) if (keep[i]) { bg[i] = false; n--; }
        for (int i = 0; i < w * h; i++) if (bg[i]) { px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0; }
        return n; }
    // where the second (lit) panel sits relative to the first: least green-channel difference
    public static int[] Align(byte[] px, int w, int h, int y0, int y1, int dyMin, int dyMax, int dxR) {
        double best = double.MaxValue; int bx = 0, by = 0;
        for (int dy = dyMin; dy <= dyMax; dy++) for (int dx = -dxR; dx <= dxR; dx++) {
            double s = 0; long n = 0;
            for (int y = y0; y <= y1; y += 3) { int yb = y + dy; if (yb < 0 || yb >= h) continue;
                for (int x = 20; x < w - 20; x += 3) { int xb = x + dx; int a = (y * w + x) * 4, b = (yb * w + xb) * 4;
                    if (px[a + 3] < 128 || px[b + 3] < 128) continue; s += Math.Abs(px[a + 1] - px[b + 1]); n++; } }
            if (n > 0 && s / n < best) { best = s / n; bx = dx; by = dy; } }
        return new int[] { bx, by, (int)(best * 100) }; }
    // a region of the source (art coordinates, fractional) drawn at another size, high quality
    public static byte[] Render(byte[] src, int sw, int sh, float sx, float sy, float sWid, float sHei, int dw, int dh) {
        using (var s = ToBitmap(src, sw, sh)) using (var d = new Bitmap(dw, dh, PixelFormat.Format32bppArgb)) using (var g = Graphics.FromImage(d))
        using (var ia = new ImageAttributes()) {
            g.Clear(Color.Transparent); g.CompositingMode = CompositingMode.SourceCopy; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality; ia.SetWrapMode(WrapMode.TileFlipXY);
            g.DrawImage(s, new Rectangle(0, 0, dw, dh), sx, sy, sWid, sHei, GraphicsUnit.Pixel, ia);
            return FromBitmap(d); } }
    // 3x3 box blur of the colours (not alpha), so film grain does not speckle into 53 colours
    public static byte[] Smooth(byte[] px, int w, int h) {
        var o = (byte[])px.Clone();
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int i = (y * w + x) * 4; if (px[i + 3] < 128) continue;
            for (int c = 0; c < 3; c++) { int s = 0, n = 0;
                for (int dy = -1; dy <= 1; dy++) { int yy = y + dy; if (yy < 0 || yy >= h) continue;
                    for (int dx = -1; dx <= 1; dx++) { int xx = x + dx; if (xx < 0 || xx >= w) continue; int j = (yy * w + xx) * 4; if (px[j + 3] < 128) continue; s += px[j + c]; n++; } }
                o[i + c] = (byte)(s / n); } }
        return o; }
    public static byte[] Crop(byte[] px, int w, int x0, int y0, int cw, int ch, int bpp) {
        var o = new byte[cw * ch * bpp];
        for (int y = 0; y < ch; y++) Buffer.BlockCopy(px, ((y0 + y) * w + x0) * bpp, o, y * cw * bpp, cw * bpp);
        return o; }
    // `count` copies of row `at` inserted below it
    public static byte[] InsertRows(byte[] px, int w, int h, int at, int count, int bpp) {
        int stride = w * bpp; var o = new byte[(h + count) * stride];
        Buffer.BlockCopy(px, 0, o, 0, (at + 1) * stride);
        for (int k = 0; k < count; k++) Buffer.BlockCopy(px, at * stride, o, (at + 1 + k) * stride, stride);
        Buffer.BlockCopy(px, (at + 1) * stride, o, (at + 1 + count) * stride, (h - at - 1) * stride);
        return o; }
    // black background behind every transparent pixel, alpha opaque: what the upscaler gets
    public static byte[] OnBlack(byte[] px) { var o = (byte[])px.Clone(); for (int i = 0; i < o.Length; i += 4) { int a = o[i + 3];
        o[i] = (byte)(o[i] * a / 255); o[i + 1] = (byte)(o[i + 1] * a / 255); o[i + 2] = (byte)(o[i + 2] * a / 255); o[i + 3] = 255; } return o; }
    // magenta screens -> dark glass, graded by how magenta a pixel is (soft and shadowed edges too)
    public static void Glass(byte[] px) { for (int i = 0; i < px.Length; i += 4) { if (px[i + 3] == 0) continue; int r = px[i + 2], g = px[i + 1], b = px[i];
        int mg = Math.Min(r, b) - g; if (mg <= 12) continue; int k = Math.Min(256, (mg - 12) * 256 / 40);
        px[i + 2] = (byte)((r * (256 - k) + 0x12 * k) >> 8); px[i + 1] = (byte)((g * (256 - k) + 0x11 * k) >> 8); px[i] = (byte)((b * (256 - k) + 0x0B * k) >> 8); px[i + 3] = 255; } }
    // THE SEE-THROUGH EDGE (the 3D runs on beneath the host's panel): within `band` px of the cut-out,
    // alpha follows brightness, so the near-black rim the true-black matte leaves fades into the
    // world instead of standing as a jagged black outline. Inside the band nothing changes.
    public static void SoftEdge(byte[] px, int w, int h, int band, int lo, int hi) {
        var dist = new int[w * h]; var q = new Queue<int>();
        for (int i = 0; i < w * h; i++) { if (px[i * 4 + 3] == 0) { dist[i] = 0; q.Enqueue(i); } else dist[i] = int.MaxValue; }
        while (q.Count > 0) { int k = q.Dequeue(), d = dist[k] + 1; if (d > band) continue; int kx = k % w, ky = k / w;
            int[] nb = { kx > 0 ? k - 1 : -1, kx < w - 1 ? k + 1 : -1, ky > 0 ? k - w : -1, ky < h - 1 ? k + w : -1 };
            foreach (int n in nb) if (n >= 0 && dist[n] > d) { dist[n] = d; q.Enqueue(n); } }
        for (int i = 0; i < w * h; i++) { if (dist[i] == 0 || dist[i] > band) continue; int o = i * 4;
            int lum = px[o] + px[o + 1] + px[o + 2]; double t = Math.Max(0, Math.Min(1, (lum - lo) / (double)(hi - lo))); t = t * t * (3 - 2 * t);
            // deeper into the band, less of the fade: the outermost pixel takes all of it
            double k2 = (double)(dist[i] - 1) / band; t = t + (1 - t) * k2;
            px[o + 3] = (byte)Math.Min(px[o + 3], (int)Math.Round(255 * t)); } }
    // colour from one image, alpha from another of the same size
    public static void TakeAlpha(byte[] dst, byte[] alphaSrc) { for (int i = 3; i < dst.Length; i += 4) dst[i] = alphaSrc[i]; }
}
'@

# ---- the art, measured (art pixels in HUD_NEW.png) -------------------------------------------------
$PANEL_TOP = 977; $SCREEN_W = 1600; $SCREEN_H = 1200; $VIEW_Y = 49
$PAD = 8                                     # text kept off the screens' edges (art px), all four sides
$A = @{
    # the two screens' INNER areas (inside the bezels), before padding
    invScreen = @(128, 474, 358, 107); logScreen = @(1201, 466, 609, 117)
    module    = @(1178, 452, 694, 0)         # the log module: its frame's left edge to the key column's right edge
    gaugeSlot = @(818, 498, 268, 54)         # the health bar's slot, inside its rim
    scan = @(553, 473, 104, 124); map = @(668, 474, 105, 123); menu = @(1107, 487, 69, 86)   # (y order = scan, map, menu)
    invUp = @(508, 482, 24, 41); invDown = @(508, 528, 24, 42)      # narrow: the engine tells arrows by h/w >= 1.5
    logExpand = @(1832, 459, 36, 37); logUp = @(1832, 505, 36, 36); logDown = @(1832, 548, 36, 37)
}
$ART_TOP = 330; $ART_BOTTOM = 646            # the art's first and last rows
$SEAM = 953                                  # where the two halves meet (the line through the health slot)
$INSERT_ART_ROW = 500                        # (the old stretch, kept for the wide.json fields; the opened art replaces it)
$MODULE_TOP = @(@(1178, 1832, 452), @(1832, 1872, 455))
$BACKING_ART_ROW = 482                       # the black behind the panel starts here: below the body's top edge everywhere
# EDGE TO EDGE (Josh): the end caps' outer plate is stepped out to the display's edges by the host,
# repeating these art columns (a plain stretch of brass, cut by the image border).
$EDGE_SLICE_L = @(3, 4); $EDGE_SLICE_R = @(1979, 1980)        # ONE column each: wider slices repeat as visible ribs
# THE OPENED LOG BOX (HUD_Expanded.png): the screen's inner top, against the closed one's; its module's
# columns and first row; the row where its moving top (border, collapse chevron, the piston's cap) ends;
# and its up / down keys, which sit higher than the closed ones.
$EXP_SCREEN_TOP = 83; $CLOSED_SCREEN_TOP = 466
$EXP_COLS = @(1146, 1888); $EXP_ROW0 = 55; $EXP_CUT = 160; $CLOSED_MODULE_TOP = 440
$A_OPEN = @{ logCollapse = @(1830, 78, 42, 42); logUp = @(1830, 470, 40, 52); logDown = @(1830, 524, 40, 54) }

# ---- THE MAPPING -----------------------------------------------------------------------------------
$LEFT_COL = $A.invScreen[0] + $PAD; $RIGHT_COL = $A.module[0] + $A.module[2]
$K = (1599.0 - 20.0) / ($RIGHT_COL - $LEFT_COL)
# (MAP_X0 / MAP_Y0, never $X0: PowerShell names are case-insensitive and resolved dynamically, so a
# helper's local $x0 silently became the mapping's origin inside GX)
$MAP_X0 = 20.0 - $LEFT_COL * $K
$MAP_Y0 = $SCREEN_H - $ART_BOTTOM * $K
function GX([double]$c) { $MAP_X0 + $c * $K }
function GY([double]$r) { $MAP_Y0 + $r * $K }
function Rect([double]$col, [double]$row, [double]$rWid, [double]$rHei) {
    $x0 = [int][Math]::Round((GX $col)); $y0 = [int][Math]::Round((GY $row))
    [pscustomobject]@{ x = $x0; y = $y0; w = ([int][Math]::Round((GX ($col + $rWid))) - $x0); h = ([int][Math]::Round((GY ($row + $rHei))) - $y0) }
}
$G_TOP = [int][Math]::Floor((GY $ART_TOP)); $BLEED = $PANEL_TOP - $G_TOP; $G_H = $SCREEN_H - $G_TOP
Write-Host ("mapping: {0:N4} game px per art px; art spans game x {1:N0}..{2:N0}, rows {3}..1199 (bleed {4} rows over the view); seam at x {5:N1}" -f $K, (GX 0), (GX 1983), $G_TOP, $BLEED, (GX $SEAM))

# ---- load, matte; the glow takes the plain art's outline ---------------------------------------------
$w = 0; $h = 0
$ref = [HudWide]::Load($Art, [ref]$w, [ref]$h)
$bgN = [HudWide]::Matte($ref, $w, $h)
$gw = 0; $gh = 0; $glo = [HudWide]::Load($Glow, [ref]$gw, [ref]$gh)
$ew = 0; $eh = 0; $expA = [HudWide]::Load($Expanded, [ref]$ew, [ref]$eh)
if ($ew -ne $w -or $eh -ne $h) { throw "HUD_Expanded is ${ew}x$eh, HUD_NEW ${w}x$h" }
[void][HudWide]::Matte($expA, $ew, $eh)
if ($gw -ne $w -or $gh -ne $h) { throw "HUD_GLOW is ${gw}x$gh, HUD_NEW ${w}x$h" }
[HudWide]::TakeAlpha($glo, $ref)
Write-Host ("art {0}x{1}: {2:N0} background px matted" -f $w, $h, $bgN)

# ---- the game's copy: 1600 x G_H, game rows G_TOP..1199 -------------------------------------------------
$srcX = (0 - $MAP_X0) / $K; $srcW = $SCREEN_W / $K; $srcY = ($G_TOP - $MAP_Y0) / $K; $srcH = $G_H / $K
$gOff = [HudWide]::Render($ref, $w, $h, [single]$srcX, [single]$srcY, [single]$srcW, [single]$srcH, $SCREEN_W, $G_H)
$gLit = [HudWide]::Render($glo, $w, $h, [single]$srcX, [single]$srcY, [single]$srcW, [single]$srcH, $SCREEN_W, $G_H)
$hud3 = [LeTool.Pcx]::Load((Join-Path $ArtDir 'HUD3.PCX'))
$pal = $hud3.Palette; $PAL_LO = 1; $NCOL = 53; $BLACK = 54
$sub = New-Object byte[] ($NCOL * 3); for ($i = 0; $i -lt $NCOL * 3; $i++) { $sub[$i] = $pal[$PAL_LO * 3 + $i] }
function Quant([byte[]]$px, [int]$qw, [int]$qh) { ,([LeTool.Quant]::Map([HudWide]::Smooth($px, $qw, $qh), $qw, $qh, $sub, $NCOL, $PAL_LO, 0)) }
$qOff = Quant $gOff $SCREEN_W $G_H
$qLit = Quant $gLit $SCREEN_W $G_H
for ($i = 0; $i -lt $qOff.Length; $i++) { if ($qOff[$i] -eq 0) { $qOff[$i] = [byte]$BLACK } }     # (the game's copy: black behind)

# ---- HUD3 / HUDOFF: rows 977..1199 ------------------------------------------------------------------------
foreach ($name in 'HUD3.PCX', 'HUDOFF.PCX') {
    $p = [LeTool.Pcx]::Load((Join-Path $ArtDir $name))
    if ($p.Width -ne $SCREEN_W -or $p.Height -ne $SCREEN_H) { throw "$name is $($p.Width)x$($p.Height), not ${SCREEN_W}x$SCREEN_H" }
    for ($y = 0; $y -lt ($SCREEN_H - $PANEL_TOP); $y++) { [Array]::Copy($qOff, ($BLEED + $y) * $SCREEN_W, $p.Pixels, ($PANEL_TOP + $y) * $p.BytesPerLine, $SCREEN_W) }
    $p.SavePcx((Join-Path $ArtDir $name))
}
Write-Host 'HUD3.PCX, HUDOFF.PCX: panel rows replaced (existing palette, 53 colours)'

# ---- HUDBOT.RES: the bleed rows over the view (the end caps rising into it) -------------------------------
$qBleed = Quant $gOff $SCREEN_W $G_H                 # (the unblackened copy: 0 = nothing there)
$rowStart = $PANEL_TOP - $BLEED - $VIEW_Y; $destOff = $rowStart * $SCREEN_W
$px = New-Object 'System.Collections.Generic.SortedDictionary[int,byte]'
for ($y = 0; $y -lt $BLEED; $y++) { for ($x = 0; $x -lt $SCREEN_W; $x++) { $v = $qBleed[$y * $SCREEN_W + $x]; if ($v -ne 0) { $px[($rowStart + $y) * $SCREEN_W + $x] = $v } } }
# NEVER EMPTY: the applier (0x1E789) is a do-while on the word count, so a file with no records loops
# forever. Within the game's 1600 columns this art may not rise over the view at all (only its end caps
# do, outside them): then one black pixel in the view's last row, left edge, which the host hides anyway.
$OWN_TOP = $PANEL_TOP
if ($px.Count -gt 0) { $OWN_TOP = $PANEL_TOP - $BLEED + [int][Math]::Floor(@($px.Keys)[0] / $SCREEN_W) - $rowStart }
else { $px[($PANEL_TOP - $VIEW_Y - 1) * $SCREEN_W] = [byte]$BLACK }
$offs = @($px.Keys)
$script:out = New-Object System.Collections.Generic.List[byte]; $script:words = 0
function Add-Word([int]$v) { $script:out.Add([byte]($v -band 0xFF)); $script:out.Add([byte](($v -shr 8) -band 0xFF)); $script:words++ }
function Add-Gap([int]$g) { while ($g -gt 65535) { Add-Word 65535; Add-Word 0; $g -= 65535 }; Add-Word $g }
$cur = $destOff; $i = 0
while ($i -lt $offs.Count) {
    $start = $offs[$i]; $j = $i
    while ($j + 1 -lt $offs.Count -and $offs[$j + 1] -eq $offs[$j] + 1) { $j++ }
    $len = $offs[$j] - $start + 1; $gap = $start - $cur
    if ($script:words -eq 0 -and $gap -ne 0) { Add-Word 0 }
    if ($script:words -gt 0 -or $gap -ne 0) { Add-Gap $gap }
    Add-Word $len
    for ($kk = $start; $kk -le $offs[$j]; $kk++) { $script:out.Add($px[$kk]) }
    $cur = $start + $len; $i = $j + 1
}
if (($cur - 1) -ge ($SCREEN_W * ($PANEL_TOP - $VIEW_Y))) { throw 'HUDBOT.RES would write past the view' }
$script:out.AddRange([byte[]][BitConverter]::GetBytes([int]$script:words)); $script:out.AddRange([byte[]][BitConverter]::GetBytes([int]$destOff))
[IO.File]::WriteAllBytes((Join-Path $ArtDir 'HUDBOT.RES'), $script:out.ToArray())
Write-Host ("HUDBOT.RES: {0:N0} px over {1} rows" -f $px.Count, $BLEED)

# ---- the regions, in game coordinates ---------------------------------------------------------------------
$R = @{}; foreach ($k2 in $A.Keys) { $arr = $A[$k2]; $R[$k2] = Rect $arr[0] $arr[1] $arr[2] $arr[3] }
$P = $PAD
$inv = Rect ($A.invScreen[0] + $P) ($A.invScreen[1] + $P) ($A.invScreen[2] - 2 * $P) ($A.invScreen[3] - 2 * $P)
$rec = Rect ($A.logScreen[0] + $P) ($A.logScreen[1] + $P) ($A.logScreen[2] - 2 * $P) ($A.logScreen[3] - 2 * $P)
# the health bar: the slot's width, H1's 34 rows, centred in the slot
$slot = $R.gaugeSlot; $GAUGE_H = 34
$gaugeWell = [pscustomobject]@{ x = $slot.x; y = [int]($slot.y + [Math]::Floor(($slot.h - $GAUGE_H) / 2)); w = $slot.w; h = $GAUGE_H }

# ---- THE LOG BOX: the module, stretched open at one row ----------------------------------------------------
$FRAME_X = $R.module.x; $FRAME_W = $R.module.w
$EXT_EXACT = ($CLOSED_SCREEN_TOP - $EXP_SCREEN_TOP) * $K
$FY_SMALL = $PANEL_TOP; $FH_SMALL = $SCREEN_H - $PANEL_TOP; $EXT = $(if ($Extend -gt 0) { $Extend } else { [int][Math]::Round($EXT_EXACT) }); $FH_BIG = $FH_SMALL + $EXT
if (($FY_SMALL - $EXT) -lt $VIEW_Y) { throw "the opened log box would rise above the view ($($FY_SMALL - $EXT))" }
$RX = $rec.x; $RW = $rec.w; $RY_SMALL = $rec.y; $RH_SMALL = $rec.h
$RY_BIG = $RY_SMALL - $EXT; $RH_BIG = $RH_SMALL + $EXT
$INS_Y = [int][Math]::Round((GY $INSERT_ART_ROW))
if ($FRAME_X + $FRAME_W -gt $SCREEN_W) { throw "the log module ends at x $($FRAME_X + $FRAME_W), past the game's screen" }
if ($INS_Y -le $RY_SMALL -or $INS_Y -ge ($RY_SMALL + $RH_SMALL)) { throw "the repeated row ($INS_Y) must cross the text area ($RY_SMALL..$($RY_SMALL + $RH_SMALL))" }
if ($R.logExpand.y + $R.logExpand.h -gt $INS_Y -or $R.logUp.y -lt $INS_Y) { throw 'the repeated row must lie between the expand key (rises) and the up key (stays)' }
Write-Host ("text: inventory {0}x{1} at ({2},{3}); log {4}x{5} at ({6},{7}), {4}x{8} open" -f $inv.w, $inv.h, $inv.x, $inv.y, $RW, $RH_SMALL, $RX, $RY_SMALL, $RH_BIG)

$regions = @(
    [pscustomobject]@{ x = $inv.x; y = $inv.y - $PANEL_TOP; w = $inv.w; h = $inv.h }
    [pscustomobject]@{ x = $gaugeWell.x; y = $gaugeWell.y - $PANEL_TOP; w = ($gaugeWell.w - 3); h = $gaugeWell.h }   # + Build-AztMod's 3 px overhang = the well
    [pscustomobject]@{ x = ($FRAME_X + 17); y = 23; w = ($FRAME_W - 33); h = 150 }        # scan: frame = x-17 .. +33 (Build-AztMod's pads)
    [pscustomobject]@{ x = $R.scan.x; y = $R.scan.y - $PANEL_TOP; w = $R.scan.w; h = $R.scan.h }
    [pscustomobject]@{ x = $R.map.x; y = $R.map.y - $PANEL_TOP; w = $R.map.w; h = $R.map.h }
    [pscustomobject]@{ x = $R.menu.x; y = $R.menu.y - $PANEL_TOP; w = $R.menu.w; h = $R.menu.h }
    [pscustomobject]@{ x = $R.invUp.x; y = $R.invUp.y - $PANEL_TOP; w = $R.invUp.w; h = $R.invUp.h }
    [pscustomobject]@{ x = $R.invDown.x; y = $R.invDown.y - $PANEL_TOP; w = $R.invDown.w; h = $R.invDown.h }
)
foreach ($rg in $regions) { $rg | Add-Member -NotePropertyName px -NotePropertyValue ($rg.w * $rg.h) }
# classify exactly as Build-AztMod does, so a mismatch fails HERE
$scanR = $regions | Where-Object { $_.x -gt ($SCREEN_W / 2) } | Sort-Object { -($_.w * $_.h) } | Select-Object -First 1
$mapR = $regions | Where-Object { $_.x -lt ($SCREEN_W / 2) } | Sort-Object { -($_.w * $_.h) } | Select-Object -First 1
$gaugeR = $regions | Where-Object { ($_.w / $_.h) -ge 4.0 } | Select-Object -First 1
$ctrl = @($regions | Where-Object { ($_.h / $_.w) -ge 1.5 } | Sort-Object y)
$acts = @($regions | Where-Object { $_ -ne $scanR -and $_ -ne $mapR -and $_ -ne $gaugeR -and $ctrl -notcontains $_ } | Sort-Object y)
if ($ctrl.Count -ne 2 -or $acts.Count -ne 3 -or $mapR.x -ne $inv.x -or $scanR.x -ne ($FRAME_X + 17) -or $gaugeR.x -ne $gaugeWell.x) { throw "the regions do not classify as intended: $($ctrl.Count) arrows, $($acts.Count) buttons" }
if ($acts[0].x -ne $R.scan.x -or $acts[1].x -ne $R.map.x -or $acts[2].x -ne $R.menu.x) { throw 'the mode buttons do not sort scan, map, menu by height' }
if ($mapR.x - 20 -gt 127 -or $mapR.x -lt 20) { throw "inventory window x $($mapR.x): the click test at 0x2C462 holds x-20 in one signed byte" }
foreach ($c in @($ctrl) + @($acts)) { if ($c.x -lt 0 -or ($c.x + $c.w) -gt $SCREEN_W) { throw "a control at x $($c.x) is outside the game's screen" } }
# no replay key in this art: the game's lower-bound click test goes to the bottom-right corner, under the frame
$repX = $SCREEN_W - 86; $repY = $SCREEN_H - 43
$layout = [ordered]@{ screenW = $SCREEN_W; screenH = $SCREEN_H; panelTop = $PANEL_TOP; viewY = $VIEW_Y; bleed = $BLEED; regions = $regions
    gaugeWellW = $gaugeWell.w; replay = [ordered]@{ x = $repX; y = $repY } }
$layout | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ArtDir 'hud-layout.json') -Encoding utf8
Write-Host ("hud-layout.json: inventory ({0},{1}) {2}x{3}; gauge well ({4},{5}) {6}x{7}; log frame x {8} w {9}" -f $inv.x, $inv.y, $inv.w, $inv.h, $gaugeWell.x, $gaugeWell.y, $gaugeWell.w, $gaugeWell.h, $FRAME_X, $FRAME_W)

# ---- the mode buttons: unlit (HUD_NEW) and lit (HUD_GLOW) sprites ------------------------------------------
for ($bi = 0; $bi -lt 3; $bi++) {
    $t = $acts[$bi]; $ty = $t.y + $PANEL_TOP - $G_TOP
    foreach ($st in @(@{ q = $qOff; f = 'OFF' }, @{ q = $qLit; f = 'ON' })) {
        $s = New-Object LeTool.Pcx; $s.Width = $t.w; $s.Height = $t.h; $s.BitsPerPixel = 8; $s.Planes = 1; $s.BytesPerLine = $t.w
        $s.Pixels = [HudWide]::Crop($st.q, $SCREEN_W, $t.x, $ty, $t.w, $t.h, 1)
        for ($i = 0; $i -lt $s.Pixels.Length; $i++) { if ($s.Pixels[$i] -eq 0) { $s.Pixels[$i] = [byte]$BLACK } }
        $s.Palette = $pal.Clone(); $s.SavePcx((Join-Path $ArtDir ("NBUT{0}{1}.PCX" -f $bi, $st.f)))
    }
}
Write-Host ("NBUT0..2: {0}" -f (($acts | ForEach-Object { "{0}x{1}" -f $_.w, $_.h }) -join ', '))
# as DOSBox SHOWS them: the palette through the VGA's 6-bit DAC, as 0xRRGGBB
$dac = New-Object int[] 256
for ($i = 0; $i -lt 256; $i++) { $c3 = foreach ($chn in 0..2) { $v6 = $pal[$i * 3 + $chn] -shr 2; ($v6 -shl 2) -bor ($v6 -shr 4) }; $dac[$i] = ($c3[0] -shl 16) -bor ($c3[1] -shl 8) -bor $c3[2] }
$mb = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($mb)
for ($bi = 0; $bi -lt 3; $bi++) {
    $t2 = $acts[$bi]; $bw.Write([int]$t2.w); $bw.Write([int]$t2.h)
    foreach ($nm in 'OFF', 'ON') { $pp = [LeTool.Pcx]::Load((Join-Path $ArtDir ("NBUT{0}{1}.PCX" -f $bi, $nm))); foreach ($v in $pp.Pixels) { $bw.Write([int]$dac[$v]) } }
}
$bw.Flush(); New-Item -ItemType Directory -Force (Join-Path $ArtDir 'wide') | Out-Null
[IO.File]::WriteAllBytes((Join-Path $ArtDir 'wide\modes.bin'), $mb.ToArray()); $bw.Dispose()

# ---- the log box in the game's copy: the module, and the module with the rows inserted ---------------------
$insLocal = $INS_Y - $FY_SMALL
$qBoxOff = [HudWide]::Crop($qOff, $SCREEN_W, $FRAME_X, ($FY_SMALL - $G_TOP), $FRAME_W, $FH_SMALL, 1)
# OPENED: HUD_Expanded.png in the game's rows (977 - EXT)..1199, the frame's columns
$eTop = $FY_SMALL - $EXT; $eH = $SCREEN_H - $eTop
$gExp = [HudWide]::Render($expA, $w, $h, [single]$srcX, [single](($eTop - $MAP_Y0) / $K), [single]$srcW, [single]($eH / $K), $SCREEN_W, $eH)
$qExp = Quant $gExp $SCREEN_W $eH; for ($i = 0; $i -lt $qExp.Length; $i++) { if ($qExp[$i] -eq 0) { $qExp[$i] = [byte]$BLACK } }
$qBoxOn = [HudWide]::Crop($qExp, $SCREEN_W, $FRAME_X, 0, $FRAME_W, $FH_BIG, 1)
foreach ($b in @(@{ q = $qBoxOff; hh = $FH_SMALL; n = 'BOXOFF' }, @{ q = $qBoxOn; hh = $FH_BIG; n = 'BOXON' })) {
    $s = New-Object LeTool.Pcx; $s.Width = $FRAME_W; $s.Height = $b.hh; $s.BitsPerPixel = 8; $s.Planes = 1; $s.BytesPerLine = $FRAME_W
    $s.Pixels = [byte[]]$b.q.Clone(); $s.Palette = $pal.Clone(); $s.SavePcx((Join-Path $ArtDir ($b.n + '.PCX')))
}
$ek = $R.logExpand; $ck = Rect $A_OPEN.logCollapse[0] $A_OPEN.logCollapse[1] $A_OPEN.logCollapse[2] $A_OPEN.logCollapse[3]
$ckLocalY = $ck.y - ($FY_SMALL - $EXT)        # frame-local in the opened frame
$box = [ordered]@{ frameW = $FRAME_W; frameHOff = $FH_SMALL; frameHOn = $FH_BIG; extend = $EXT; lift = 0
    recessX = ($RX - $FRAME_X); recessY = ($RY_SMALL - $FY_SMALL); recessW = $RW; recessHOff = $RH_SMALL; recessHOn = $RH_BIG
    iconX0 = ([Math]::Min($ek.x, $ck.x) - $FRAME_X - 2); iconY0 = ([Math]::Min($ek.y - $FY_SMALL, $ckLocalY) - 2)
    iconX1 = [Math]::Min($FRAME_W - 1, [Math]::Max($ek.x + $ek.w, $ck.x + $ck.w) - $FRAME_X + 2); iconY1 = ([Math]::Max($ek.y + $ek.h - $FY_SMALL, $ckLocalY + $ck.h) + 2) }
if (($FRAME_W - $box.recessW) -gt 127 -or $box.recessY -gt 127) { throw 'the frame-to-recess offsets must fit one signed byte' }
$box | ConvertTo-Json | Set-Content (Join-Path $ArtDir 'hud-box.json') -Encoding utf8
Write-Host ("log box: frame {0}x{1} at ({2},{3}) (open {4} rows), text {5} px wide (the original was 287)" -f $FRAME_W, $FH_SMALL, $FRAME_X, $FY_SMALL, $FH_BIG, $RW)

# ---- the inventory backing: the panel's own green screen, so the list has no background of its own ---------
$ib = New-Object LeTool.Pcx; $ib.Width = $inv.w; $ib.Height = $inv.h; $ib.BitsPerPixel = 8; $ib.Planes = 1; $ib.BytesPerLine = $inv.w
$ib.Pixels = [HudWide]::Crop($qOff, $SCREEN_W, $inv.x, ($inv.y - $G_TOP), $inv.w, $inv.h, 1); $ib.Palette = $pal.Clone()
$ib.SavePcx((Join-Path $ArtDir 'INVBACK2.PCX'))
Write-Host ("INVBACK2.PCX: {0}x{1}, cut from the panel's own screen" -f $inv.w, $inv.h)
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Build-HudBar.ps1') -ArtDir $ArtDir -StockH1 (Join-Path $StockGame 'H1.PCX') -W $gaugeWell.w
if ($LASTEXITCODE) { throw 'Build-HudBar failed' }

# ---- what the text sits on, as DOSBox shows it (wide\bg8.bin) ---------------------------------------------
# block: int x, y, w, h, then w*h ints 0xRRGGBB. 1: the panel rows (the game's copy); 2: the opened log box.
$wd = Join-Path $ArtDir 'wide'
$ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([int]0); $bw.Write([int]$G_TOP); $bw.Write([int]$SCREEN_W); $bw.Write([int]$G_H); foreach ($v in $qOff) { $bw.Write([int]$dac[$v]) }
$bw.Write([int]$FRAME_X); $bw.Write([int]($FY_SMALL - $EXT)); $bw.Write([int]$FRAME_W); $bw.Write([int]$FH_BIG); foreach ($v in $qBoxOn) { $bw.Write([int]$dac[$v]) }
$bw.Flush(); [IO.File]::WriteAllBytes((Join-Path $wd 'bg8.bin'), $ms.ToArray()); $bw.Dispose()

# ---- the host's true-colour copy ----------------------------------------------------------------------------
# Art rows 320..649, all columns, upscaled 4x by Real-ESRGAN and brought down to 2x; and the opened log
# module from HUD_Expanded.png (panel-exp.png).
$CX = 0; $CY = 320; $CW = $w; $CH = 330; $HI = 2
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('azthud-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
try {
    $EXW = $EXP_COLS[1] - $EXP_COLS[0]; $EXH = $CY + $CH - $EXP_ROW0
    foreach ($v in @(@{ n = 'off'; src = $ref; x = $CX; y = $CY; cw = $CW; ch = $CH }, @{ n = 'lit'; src = $glo; x = $CX; y = $CY; cw = $CW; ch = $CH },
                     @{ n = 'exp'; src = $expA; x = $EXP_COLS[0]; y = $EXP_ROW0; cw = $EXW; ch = $EXH })) {
        $CW = $v.cw; $CH = $v.ch
        $crop = [HudWide]::Crop($v.src, $w, $v.x, $v.y, $CW, $CH, 4)
        [HudWide]::SoftEdge($crop, $CW, $CH, 3, 12, 110)
        $alpha = [HudWide]::Render($crop, $CW, $CH, 0, 0, $CW, $CH, $CW * $HI, $CH * $HI)
        if ($NoUpscale) { $hiImg = [byte[]]$alpha.Clone() }
        else {
            [HudWide]::Save(([HudWide]::OnBlack($crop)), $CW, $CH, (Join-Path $tmp "$($v.n).png"))
            $upp = Start-Process -FilePath $Upscaler -ArgumentList @('-i', "`"$(Join-Path $tmp "$($v.n).png")`"", '-o', "`"$(Join-Path $tmp "$($v.n)-x4.png")`"", '-n', 'realesrgan-x4plus', '-s', '4', '-f', 'png') -WorkingDirectory (Split-Path $Upscaler) -NoNewWindow -Wait -PassThru -RedirectStandardError (Join-Path $tmp 'esrgan.log')
            if ($upp.ExitCode -ne 0) { throw "the upscaler failed ($($upp.ExitCode))" }
            $uw = 0; $uh = 0; $up = [HudWide]::Load((Join-Path $tmp "$($v.n)-x4.png"), [ref]$uw, [ref]$uh)
            if ($uw -ne $CW * 4) { throw "the upscaler gave $uw px, not $($CW * 4)" }
            $hiImg = [HudWide]::Render($up, $uw, $uh, 0, 0, $uw, $uh, $CW * $HI, $CH * $HI)
            [HudWide]::TakeAlpha($hiImg, $alpha)
        }
        [HudWide]::Save($hiImg, $CW * $HI, $CH * $HI, (Join-Path $wd "panel-$($v.n).png"))
    }
    $CW = $w; $CH = 330
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

function GR($rr) { [ordered]@{ x = $rr.x; y = $rr.y; w = $rr.w; h = $rr.h } }
$wide = [ordered]@{
    about = 'Build-HudNew.ps1: the new HUD. Images are art columns 0.. and rows 320.. at 2x; game = gameX0 + col*k, gameY0 + row*k (from the images'' own origin).'
    k = $K; artX0 = $CX; artY0 = $CY; hiScale = $HI; gameX0 = (GX $CX); gameY0 = (GY $CY)
    panelTop = $PANEL_TOP; bleedTop = $OWN_TOP; extend = $EXT
    backingTop = [int][Math]::Round((GY $BACKING_ART_ROW)); seamX = (GX $SEAM)
    # edge to edge: these columns of the end caps' outer plate are repeated out to the display's edges
    edgeSlice = @((GX $EDGE_SLICE_L[0]), (GX $EDGE_SLICE_L[1]), (GX $EDGE_SLICE_R[0]), (GX $EDGE_SLICE_R[1]))
    windowTop = [int][Math]::Floor([Math]::Min((GY $EXP_ROW0), ($FY_SMALL - $EXT))) - 4
    panelOff = 'panel-off.png'; panelLit = 'panel-lit.png'; bg8 = 'bg8.bin'
    inventory = (GR $inv); gauge = (GR $gaugeWell)
    modes = @((GR $R.scan), (GR $R.map), (GR $R.menu))
    invUp = (GR $R.invUp); invDown = (GR $R.invDown)
    textArea = [ordered]@{
        extend = $EXT; insertY = (GY $INSERT_ART_ROW)
        top = @($MODULE_TOP | ForEach-Object { ,@((GX $_[0]), (GX $_[1]), (GY $_[2])) })
        recessClosed = [ordered]@{ x = $RX; y = $RY_SMALL; w = $RW; h = $RH_SMALL }
        recessOpen = [ordered]@{ x = $RX; y = $RY_BIG; w = $RW; h = $RH_BIG }
        expand = (GR $R.logExpand); up = (GR $R.logUp); down = (GR $R.logDown)
        frame = [ordered]@{ x = $FRAME_X; w = $FRAME_W; yOpen = ($FY_SMALL - $EXT) }
        # the opened module (panel-exp.png, at 2x from art column EXP_COLS[0], row EXP_ROW0), in its OPEN place:
        # its top down to cutY rides up by shift; below cutY it is uncovered in place; it replaces the
        # closed module from closedTop down
        exp = [ordered]@{ file = 'panel-exp.png'; x = (GX $EXP_COLS[0]); y = (GY $EXP_ROW0); w = ($EXW * $K); h = ($EXH * $K)
            cutY = (GY $EXP_CUT); closedTop = (GY $CLOSED_MODULE_TOP); shift = $EXT_EXACT }
        upOpen = (GR (Rect $A_OPEN.logUp[0] $A_OPEN.logUp[1] $A_OPEN.logUp[2] $A_OPEN.logUp[3]))
        downOpen = (GR (Rect $A_OPEN.logDown[0] $A_OPEN.logDown[1] $A_OPEN.logDown[2] $A_OPEN.logDown[3]))
    }
}
$wide | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $wd 'wide.json') -Encoding utf8
Write-Host ("host art: wide\panel-off.png, panel-lit.png {0}x{1}; bg8.bin; wide.json (backing from row {2}, seam at x {3:N1})" -f ($CW * $HI), ($CH * $HI), $wide.backingTop, $wide.seamX)
