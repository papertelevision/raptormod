# Build-HudWide.ps1 -- the widescreen panel (Josh, 2026-10-06).
#
# Josh's new panel spans the whole width of a widescreen display, wider than the game's own
# 1600-pixel screen. So it is drawn twice:
#
#   * by the GAME, in 8-bit, inside its 1600x1200 screen. That is the 4:3 middle of the new art.
#     This copy decides where everything really is: where the engine draws the inventory list,
#     the health bar, the log text and the mode sprites, and where clicks land.
#   * by the HOST RENDERER, in true colour, across the full width, over the game's copy
#     (tools\Panel.cs). The live parts are copied in from the game's screen.
#
# Both come from one mapping, fixed in GAME pixels so it is the same on every display:
#     game x = -160 + (art column - 17) * K
#     game y = 1200 + (art row   - 347) * K
#     K = 1920 / 2038 game pixels per art pixel
# The art spans 1920 game pixels: exactly the width of a 16:10 display. Every control lies
# inside 0..1599, the part of the screen the game's mouse can reach. Only the end caps lie
# outside it. Josh chose the art's TRUE SHAPE (no vertical stretch): its body is 194 game
# rows, against a panel of 223. The 29 rows above the body show the hoses and humps behind the
# panel's top edge, over black.
#
# THE PALETTE IS NOT TOUCHED. Build-HudSkin would choose 53 new colours, and indices 1..53 are
# shared by 72 of the game's PCX files: the system menu, the fonts, the inventory. The new art
# is mapped onto the EXISTING 53 instead. They came from the previous brass panel, and the host
# draws the true-colour art over them anyway.
#
# OUTPUTS (art\):
#   HUD3.PCX, HUDOFF.PCX       rows 977..1199 replaced; everything above is kept
#   HUDBOT.RES                 the bleed rows over the view (the humps)
#   hud-layout.json            the 8 regions, plus gaugeWellW and replay (read by Build-AztMod)
#   NBUT{0,1,2}{OFF,ON}.PCX    the three mode buttons, unlit and lit, cut from the art
#   BOXOFF.PCX, BOXON.PCX      the log module, closed and opened (rows inserted), and hud-box.json
#   INVBACK2.PCX, H1.PCX       via Build-HudInv / Build-HudBar
#   wide\panel-off.png, wide\panel-lit.png, wide\modes.bin, wide\wide.json   (the host's)
[CmdletBinding()]
param(
    # the panel render with the round text-area keys transplanted in (Build-HudKeys.ps1)
    [string]$Reference = "$PSScriptRoot\..\design\incoming\hud\two_panels_reference-keys.png",
    [string]$ArtDir    = "$PSScriptRoot\..\art",
    [string]$StockGame = '',      # '' = the stock game this repo sits in: <Steam>\Azrael's Tear\GAME\AZRAEL
    [string]$Upscaler  = 'C:\Games\RaptorMod\sources\realesrgan\realesrgan-ncnn-vulkan.exe',
    # how much taller the opened log box is, in game rows
    [int]$Extend = 160,
    [switch]$NoUpscale
)
if (-not $StockGame) { $StockGame = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'GAME\AZRAEL' }      # (in the body: $PSScriptRoot is empty in param() under -File)
$ErrorActionPreference = 'Stop'
$ArtDir = (Resolve-Path $ArtDir).Path
Add-Type -Path "$PSScriptRoot\..\tools\Quantize.cs"
Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies 'System.Drawing'
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

# ---- the art, measured (art pixels in two_panels_reference.png: top panel unlit) ----------
$K = 1920.0 / 2038.0
function GX([double]$c) { -160.0 + ($c - 17.0) * $K }
function GY([double]$ar) { 1200.0 + ($ar - 347.0) * $K }
function Rect([double]$col, [double]$row, [double]$rWid, [double]$rHei) {
    $x0 = [int][Math]::Round((GX $col)); $y0 = [int][Math]::Round((GY $row))
    [pscustomobject]@{ x = $x0; y = $y0; w = ([int][Math]::Round((GX ($col + $rWid))) - $x0); h = ([int][Math]::Round((GY ($row + $rHei))) - $y0) }
}
$PANEL_TOP = 977; $SCREEN_W = 1600; $SCREEN_H = 1200; $VIEW_Y = 49
$BLEED = 28; $G_TOP = $PANEL_TOP - $BLEED; $G_H = $SCREEN_H - $G_TOP          # the game's copy: rows 949..1199
$A = @{
    inventory = @(246, 160, 345, 161); gauge = @(936, 186, 250, 36); log = @(1304, 159, 477, 161)
    module    = @(1286, 148, 588, 0)       # the log module: bezel's left edge to the control column's right edge
    scan = @(742, 139, 161, 88); map = @(732, 243, 156, 81); menu = @(1061, 245, 117, 75)   # oval faces + 3 px
    invUp = @(634, 162, 42, 72); invDown = @(634, 245, 42, 65)
    # the round keys Build-HudKeys.ps1 put in the column (their plates)
    logExpand = @(1818, 133, 48, 58); logUp = @(1818, 221, 48, 40); logDown = @(1818, 261, 48, 34); logReplay = @(1818, 295, 48, 40)
}
# The art row repeated when the text area opens: between the expand key and the up key, through the
# small cable slot there (it stretches like a cable), the plain bezel sides and plain glass.
$INSERT_ART_ROW = 205
# What rises with the top bezel: art columns, and the module's top row in them (the bezel's top edge
# is row 140; the key column's plate starts higher). Above that is the panel's hoses, which stay.
# From the bezel's own left edge (col 1284): left of it is the crest and shadow, which stay.
$MODULE_TOP = @(@(1284, 1817, 140), @(1817, 1870, 133))
# The bezel's top-left corner is a short 45-degree bevel with dark panel behind it; rising, that read
# as a square corner over the view. It is cut ROUND, tangent to the left and top edges, a radius big
# enough that the arc lies inside the bevel (Josh: "shave a few pixels off ... a rounded corner").
$MODULE_CORNER_R = 22
# The black backing behind the panel starts here: just under the two screen modules' top bezels
# (row 141), so its edge is hidden behind them (Josh: not up into the view).
$BACKING_ART_ROW = 144
$PAD = 4                         # text kept off the recess's edges

# ---- load, matte, find the lit panel --------------------------------------------------------
$w = 0; $h = 0
$ref = [HudWide]::Load($Reference, [ref]$w, [ref]$h)
$bgN = [HudWide]::Matte($ref, $w, $h)
$al = [HudWide]::Align($ref, $w, $h, 141, 337, 300, 345, 10)
$LIT_DX = $al[0]; $LIT_DY = $al[1]
Write-Host ("reference {0}x{1}: {2:N0} background px matted; lit panel at ({3},{4}) from the unlit one, mean difference {5:N2}" -f $w, $h, $bgN, $LIT_DX, $LIT_DY, ($al[2] / 100.0))

# ---- the game's copy: 1600 x 251, game rows 949..1199 -----------------------------------------
$srcX = 17.0 + 160.0 / $K; $srcW = $SCREEN_W / $K
$srcY = 347.0 + ($G_TOP - 1200.0) / $K; $srcH = $G_H / $K
$gOff = [HudWide]::Render($ref, $w, $h, [single]$srcX, [single]$srcY, [single]$srcW, [single]$srcH, $SCREEN_W, $G_H)
$gLit = [HudWide]::Render($ref, $w, $h, [single]($srcX + $LIT_DX), [single]($srcY + $LIT_DY), [single]$srcW, [single]$srcH, $SCREEN_W, $G_H)

$hud3 = [LeTool.Pcx]::Load((Join-Path $ArtDir 'HUD3.PCX'))
$pal = $hud3.Palette; $PAL_LO = 1; $NCOL = 53; $BLACK = 54
$sub = New-Object byte[] ($NCOL * 3); for ($i = 0; $i -lt $NCOL * 3; $i++) { $sub[$i] = $pal[$PAL_LO * 3 + $i] }
function Quant([byte[]]$px, [int]$qw, [int]$qh) { ,([LeTool.Quant]::Map([HudWide]::Smooth($px, $qw, $qh), $qw, $qh, $sub, $NCOL, $PAL_LO, 0)) }
$qOff = Quant $gOff $SCREEN_W $G_H
$qLit = Quant $gLit $SCREEN_W $G_H

# ---- HUD3 / HUDOFF: rows 977..1199 --------------------------------------------------------------
foreach ($name in 'HUD3.PCX', 'HUDOFF.PCX') {
    $p = [LeTool.Pcx]::Load((Join-Path $ArtDir $name))
    if ($p.Width -ne $SCREEN_W -or $p.Height -ne $SCREEN_H) { throw "$name is $($p.Width)x$($p.Height), not ${SCREEN_W}x$SCREEN_H" }
    for ($y = 0; $y -lt ($SCREEN_H - $PANEL_TOP); $y++) {
        $so = ($BLEED + $y) * $SCREEN_W; $do = ($PANEL_TOP + $y) * $p.BytesPerLine
        for ($x = 0; $x -lt $SCREEN_W; $x++) { $v = $qOff[$so + $x]; $p.Pixels[$do + $x] = $(if ($v -eq 0) { [byte]$BLACK } else { $v }) }
    }
    $p.SavePcx((Join-Path $ArtDir $name))
}
Write-Host 'HUD3.PCX, HUDOFF.PCX: panel rows replaced (existing palette, 53 colours)'

# ---- HUDBOT.RES: the bleed rows, composited into the view (Build-HudSkin's format) ---------------
$rowStart = $PANEL_TOP - $BLEED - $VIEW_Y; $destOff = $rowStart * $SCREEN_W
$px = New-Object 'System.Collections.Generic.SortedDictionary[int,byte]'
for ($y = 0; $y -lt $BLEED; $y++) { for ($x = 0; $x -lt $SCREEN_W; $x++) { $v = $qOff[$y * $SCREEN_W + $x]; if ($v -ne 0) { $px[($rowStart + $y) * $SCREEN_W + $x] = $v } } }
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

# ---- the regions, in game coordinates ------------------------------------------------------------
$R = @{}; foreach ($k2 in $A.Keys) { $arr = $A[$k2]; $R[$k2] = Rect $arr[0] $arr[1] $arr[2] $arr[3] }

# ---- THE TEXT AREA: the panel's own log module, stretched (2026-10-06) ---------------------------
# Josh's separate text-area renders never matched the panel's scale, so the module is the panel's
# own art (with the round keys from his render transplanted by Build-HudKeys.ps1). Opening it
# STRETCHES the screen: copies of one art row are inserted, and everything above it -- the top bezel
# and the expand key -- rises $Extend rows. The game does it in one step (BOXON = BOXOFF with the rows
# inserted); the host animates every height in between from the same row. The frame stays on the
# panel (no lift), so the expand key is frame-local in both states and the game's own toggle works.
$FRAME_X = $R.module.x; $FRAME_W = $R.module.w
$FY_SMALL = $PANEL_TOP; $FH_SMALL = $SCREEN_H - $PANEL_TOP; $EXT = $Extend; $FH_BIG = $FH_SMALL + $EXT
$RX = $R.log.x + $PAD; $RW = $R.log.w - 2 * $PAD; $RY_SMALL = $R.log.y + $PAD; $RH_SMALL = $R.log.h - 2 * $PAD
$RY_BIG = $RY_SMALL - $EXT; $RH_BIG = $RH_SMALL + $EXT
$INS_Y = [int][Math]::Round((GY $INSERT_ART_ROW))
if ($INS_Y -le $RY_SMALL -or $INS_Y -ge ($RY_SMALL + $RH_SMALL)) { throw "the repeated row ($INS_Y) must cross the text screen ($RY_SMALL..$($RY_SMALL + $RH_SMALL))" }
if ($R.logExpand.y + $R.logExpand.h -gt $INS_Y -or $R.logUp.y -lt $INS_Y) { throw 'the repeated row must lie between the expand key (rises) and the up key (stays)' }
if (($FY_SMALL - $EXT) -lt $VIEW_Y) { throw 'the opened text area would rise above the view' }
Write-Host ("text area: text {0}x{1} at ({2},{3}), {0}x{4} open; the module's top rises {5} rows, stretching game row {6}" -f $RW, $RH_SMALL, $RX, $RY_SMALL, $RH_BIG, $EXT, $INS_Y)
$gaugeWell = $R['gauge']
$regions = @(
    [pscustomobject]@{ x = $R.inventory.x; y = $R.inventory.y - $PANEL_TOP; w = $R.inventory.w; h = $R.inventory.h }
    [pscustomobject]@{ x = $gaugeWell.x; y = $gaugeWell.y - $PANEL_TOP; w = ($gaugeWell.w - 3); h = $gaugeWell.h }   # + Build-AztMod's 3 px overhang = the well
    [pscustomobject]@{ x = ($FRAME_X + 17); y = 23; w = ($FRAME_W - 33); h = 150 }       # scan: frame = x-17 .. +33 (Build-AztMod's pads); y and h only need to lie in the panel
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
if ($ctrl.Count -ne 2 -or $acts.Count -ne 3 -or $mapR.x -ne $R.inventory.x -or $scanR.x -ne ($FRAME_X + 17) -or $gaugeR.x -ne $gaugeWell.x) { throw "the regions do not classify as intended: $($ctrl.Count) arrows, $($acts.Count) buttons" }
if ($acts[0].x -ne $R.scan.x -or $acts[1].x -ne $R.map.x -or $acts[2].x -ne $R.menu.x) { throw 'the mode buttons do not sort scan, map, menu by height' }
if ($mapR.x - 20 -gt 127) { throw "inventory window x $($mapR.x): the click test at 0x2C462 holds x-20 in one signed byte" }
foreach ($c in @($ctrl) + @($acts)) { if ($c.x -lt 0 -or ($c.x + $c.w) -gt $SCREEN_W) { throw "a control at x $($c.x) is outside the game's screen" } }
# the replay sprite is 86 wide and must stay on the game's screen; its click test is x >= X, y >= Y
# The replay key is below the repeated row, so it is in the same place in both states.
$repX = [int][Math]::Min($R.logReplay.x, $SCREEN_W - 86)
$repY = [int][Math]::Min($R.logReplay.y + 3, $SCREEN_H - 43)
$layout = [ordered]@{ screenW = $SCREEN_W; screenH = $SCREEN_H; panelTop = $PANEL_TOP; viewY = $VIEW_Y; bleed = $BLEED; regions = $regions
    gaugeWellW = $gaugeWell.w; replay = [ordered]@{ x = $repX; y = $repY } }
$layout | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ArtDir 'hud-layout.json') -Encoding utf8
Write-Host ("hud-layout.json: inventory ({0},{1}) {2}x{3}; gauge well ({4},{5}) {6}x{7}; log frame x {8} w {9}; replay click from ({10},{11})" -f `
    $R.inventory.x, $R.inventory.y, $R.inventory.w, $R.inventory.h, $gaugeWell.x, $gaugeWell.y, $gaugeWell.w, $gaugeWell.h, $FRAME_X, $FRAME_W, $repX, $repY)

# ---- the mode buttons: unlit and lit sprites ---------------------------------------------------
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
# ...and as DOSBox will SHOW them: the palette through the VGA's 6-bit DAC, as 0xRRGGBB, so the
# host can tell which of the two the game is drawing (wide\modes.bin: per button w, h, unlit, lit)
$dac = New-Object int[] 256
for ($i = 0; $i -lt 256; $i++) { $c3 = foreach ($chn in 0..2) { $v6 = $pal[$i * 3 + $chn] -shr 2; ($v6 -shl 2) -bor ($v6 -shr 4) }; $dac[$i] = ($c3[0] -shl 16) -bor ($c3[1] -shl 8) -bor $c3[2] }
$mb = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($mb)
for ($bi = 0; $bi -lt 3; $bi++) {
    $t2 = $acts[$bi]; $bw.Write([int]$t2.w); $bw.Write([int]$t2.h)
    foreach ($nm in 'OFF', 'ON') { $pp = [LeTool.Pcx]::Load((Join-Path $ArtDir ("NBUT{0}{1}.PCX" -f $bi, $nm))); foreach ($v in $pp.Pixels) { $bw.Write([int]$dac[$v]) } }
}
$bw.Flush(); New-Item -ItemType Directory -Force (Join-Path $ArtDir 'wide') | Out-Null
[IO.File]::WriteAllBytes((Join-Path $ArtDir 'wide\modes.bin'), $mb.ToArray()); $bw.Dispose()

# ---- the log box in the game's copy: the module, and the module with the rows inserted -------------
# Cut from the panel's own QUANTISED copy, so the closed box is pixel-identical to HUD3 under it.
$insLocal = $INS_Y - $FY_SMALL
$qBoxOff = [HudWide]::Crop($qOff, $SCREEN_W, $FRAME_X, ($FY_SMALL - $G_TOP), $FRAME_W, $FH_SMALL, 1)
$qBoxOn = [HudWide]::InsertRows($qBoxOff, $FRAME_W, $FH_SMALL, $insLocal, $EXT, 1)
foreach ($b in @(@{ q = $qBoxOff; hh = $FH_SMALL; n = 'BOXOFF' }, @{ q = $qBoxOn; hh = $FH_BIG; n = 'BOXON' })) {
    $q = [byte[]]$b.q.Clone(); for ($i = 0; $i -lt $q.Length; $i++) { if ($q[$i] -eq 0) { $q[$i] = [byte]$BLACK } }
    $s = New-Object LeTool.Pcx; $s.Width = $FRAME_W; $s.Height = $b.hh; $s.BitsPerPixel = 8; $s.Planes = 1; $s.BytesPerLine = $FRAME_W
    $s.Pixels = $q; $s.Palette = $pal.Clone(); $s.SavePcx((Join-Path $ArtDir ($b.n + '.PCX')))
}
# The expand key rides the top bezel, so it is frame-local in both states: the game's own toggle.
$ek = $R.logExpand
$box = [ordered]@{ frameW = $FRAME_W; frameHOff = $FH_SMALL; frameHOn = $FH_BIG; extend = $EXT; lift = 0
    recessX = ($RX - $FRAME_X); recessY = ($RY_SMALL - $FY_SMALL); recessW = $RW; recessHOff = $RH_SMALL; recessHOn = $RH_BIG
    iconX0 = ($ek.x - $FRAME_X - 2); iconY0 = ($ek.y - $FY_SMALL - 2); iconX1 = [Math]::Min($FRAME_W - 1, $ek.x + $ek.w - $FRAME_X + 2); iconY1 = ($ek.y + $ek.h - $FY_SMALL + 2) }
if (($FRAME_W - $box.recessW) -gt 127 -or $box.recessY -gt 127) { throw 'the frame-to-recess offsets must fit one signed byte' }
if ($box.iconY1 -ge $insLocal) { throw 'the expand key must lie above the repeated row' }
$box | ConvertTo-Json | Set-Content (Join-Path $ArtDir 'hud-box.json') -Encoding utf8
Write-Host ("log box: frame {0}x{1} at ({2},{3}) (open {4} rows), text surface {5} px wide (the original was 287); toggle ({6},{7})..({8},{9}) frame-local" -f $FRAME_W, $FH_SMALL, $FRAME_X, $FY_SMALL, $FH_BIG, $RW, $box.iconX0, $box.iconY0, $box.iconX1, $box.iconY1)# ---- the inventory backing and the health bar, by their own generators --------------------------
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Build-HudInv.ps1" -ArtDir $ArtDir
if ($LASTEXITCODE) { throw 'Build-HudInv failed' }
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Build-HudBar.ps1" -ArtDir $ArtDir -StockH1 (Join-Path $StockGame 'H1.PCX') -W $gaugeWell.w
if ($LASTEXITCODE) { throw 'Build-HudBar failed' }

# ---- the host's true-colour copy -------------------------------------------------------------------
# Art columns 17..2054, rows 62..351 (the end caps' tops at 68, down past the game's 1200), upscaled 4x by
# Real-ESRGAN and brought down to 2x: the host scales it to the display from there.
$wd = Join-Path $ArtDir 'wide'; New-Item -ItemType Directory -Force $wd | Out-Null
$CX = 17; $CY = 62; $CW = 2038; $CH = 290; $HI = 2      # rows from 62: the end caps and crests reach row 68 (76 cut their tops off)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aztwide-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
try {
    foreach ($v in @(@{ n = 'off'; dx = 0; dy = 0 }, @{ n = 'lit'; dx = $LIT_DX; dy = $LIT_DY })) {
        $crop = [HudWide]::Crop($ref, $w, ($CX + $v.dx), ($CY + $v.dy), $CW, $CH, 4)
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
        if ($v.n -eq 'off') { $hiOff = $hiImg }
    }
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
# every rectangle the host needs, in GAME coordinates
function GR($rr) { [ordered]@{ x = $rr.x; y = $rr.y; w = $rr.w; h = $rr.h } }
$wide = [ordered]@{
    about = 'Build-HudWide.ps1: the widescreen panel. Images are art columns 17.. and rows 76.. at 2x; game = -160 + (col-17)*k, 1200 + (row-347)*k.'
    k = $K; artX0 = $CX; artY0 = $CY; hiScale = $HI; panelTop = $PANEL_TOP; bleedTop = $G_TOP; extend = $EXT
    backingTop = [int][Math]::Round((GY $BACKING_ART_ROW))
    panelOff = 'panel-off.png'; panelLit = 'panel-lit.png'
    inventory = (GR $R.inventory); gauge = (GR $gaugeWell)
    modes = @((GR $R.scan), (GR $R.map), (GR $R.menu))
    invUp = (GR $R.invUp); invDown = (GR $R.invDown)
    # the text area: the module above insertY (per column span: game x0, x1, top y) rises by extend
    textArea = [ordered]@{
        extend = $EXT; insertY = (GY $INSERT_ART_ROW)
        top = @($MODULE_TOP | ForEach-Object { ,@((GX $_[0]), (GX $_[1]), (GY $_[2])) })
        recessClosed = [ordered]@{ x = $RX; y = $RY_SMALL; w = $RW; h = $RH_SMALL }
        recessOpen = [ordered]@{ x = $RX; y = $RY_BIG; w = $RW; h = $RH_BIG }
        expand = (GR $R.logExpand); up = (GR $R.logUp); down = (GR $R.logDown); replay = (GR $R.logReplay)
        frame = [ordered]@{ x = $FRAME_X; w = $FRAME_W; yOpen = ($FY_SMALL - $EXT) }
        corner = [ordered]@{ x = (GX ($MODULE_TOP[0][0] + $MODULE_CORNER_R)); y = (GY ($MODULE_TOP[0][2] + $MODULE_CORNER_R)); r = ($MODULE_CORNER_R * $K) }
    }
}
$wide | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $wd 'wide.json') -Encoding utf8
Write-Host ("host art: wide\panel-off.png, panel-lit.png {0}x{1}; wide.json" -f ($CW * $HI), ($CH * $HI))
