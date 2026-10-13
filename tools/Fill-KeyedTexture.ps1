# Fill-KeyedTexture.ps1 -- Josh's replacement art for a KEYED texture (a `_key` leaf: magenta cut-outs) made safe for the renderer.
#   .\tools\Fill-KeyedTexture.ps1 -In <new art.png> -Out C:\Games\azrael-textures\hires\<leaf>_key.png -Orig C:\Games\azrael-render\<leaf>_key.png
# Back up the installed file first (Fit-RoomTextures' -Backup folder). First used on MINEMAZE 11-mmzgun_key / 14-mmzamul_key (2026-10-11).
param([string]$In, [string]$Out, [string]$Orig)
# KEYED REPLACEMENT ART (magenta cut-outs). The ORIGINAL's mask decides the holes in the renderer (GpuRaster uMask: palette
# index 0, nearest texel, at the original's size), so:
#   * inside the original's SOLID area the art is kept as it is -- except BRIGHT magenta, background showing through where
#     the new art's shape is finer than the original's coarse texels (it would draw as pink);
#   * in the original's HOLES every pixel is replaced too;
# and everything replaced takes the NEAREST kept art colour (a multi-source flood). The filtered 4K colour and its mips then
# never see magenta at the cut edge. (A first try keyed magenta of ANY brightness everywhere and ate the gun's dark,
# purple-cast stock; the original's mask is what tells background from art.) The kept art is DESPILLED: AI art rendered on
# magenta carries a magenta cast (the gun's purple patches, the gold amulet gone pink).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('Bleed.K3' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
namespace Bleed {
public static class K3 {
    // DESPILL (as green-screen work does for green): the magenta cast a magenta background throws on AI-rendered art is the
    // part of red and blue above green -- taken off both. Colours with no magenta excess (gold, brown, grey) are untouched.
    public static int Despill(int c) { int r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255; int e = System.Math.Min(r, b) - g; if (e > 0) { r -= e; b -= e; } return (int)(0xFF000000u | (uint)((r << 16) | (g << 8) | b)); }
    public static bool Bright(int c) { int r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255; return r > 110 && b > 110 && g < 0.55 * System.Math.Min(r, b); }
    // px: the art (ARGB); solid: the original's mask at the art's size. Returns how many pixels were replaced.
    public static int Fill(int[] px, bool[] solid, int w, int h)
    {
        int n = w * h; var q = new int[n]; int head = 0, tail = 0, repl = 0; var done = new bool[n];
        for (int i = 0; i < n; i++) { if (solid[i] && !Bright(px[i])) { px[i] = Despill(px[i]); done[i] = true; q[tail++] = i; } else repl++; }
        if (tail == 0) return repl;
        while (head < tail)
        {
            int i = q[head++], x = i % w, y = i / w, c = px[i];
            if (x > 0 && !done[i - 1]) { done[i - 1] = true; px[i - 1] = c; q[tail++] = i - 1; }
            if (x < w - 1 && !done[i + 1]) { done[i + 1] = true; px[i + 1] = c; q[tail++] = i + 1; }
            if (y > 0 && !done[i - w]) { done[i - w] = true; px[i - w] = c; q[tail++] = i - w; }
            if (y < h - 1 && !done[i + w]) { done[i + w] = true; px[i + w] = c; q[tail++] = i + w; }
        }
        for (int i = 0; i < n; i++) px[i] |= unchecked((int)0xFF000000);
        return repl;
    }
    public static int Count(bool[] m) { int n = 0; foreach (var b in m) if (b) n++; return n; }
    // the original's alpha (< 128 = a hole, as Raster.Tex.LoadRgb), nearest-sampled up to w x h
    public static bool[] Mask(int[] o, int ow, int oh, int w, int h)
    {
        var m = new bool[w * h];
        for (int y = 0; y < h; y++) { int oy = System.Math.Min(oh - 1, (int)((long)y * oh / h)); for (int x = 0; x < w; x++) { int ox = System.Math.Min(ow - 1, (int)((long)x * ow / w)); m[y * w + x] = ((o[oy * ow + ox] >> 24) & 255) >= 128; } }
        return m;
    }
}
}
'@
}
function Read-Argb($path) {
    $bm = [Drawing.Bitmap]::FromFile($path); $w = $bm.Width; $h = $bm.Height
    $c32 = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb); $g = [Drawing.Graphics]::FromImage($c32); $g.CompositingMode = 'SourceCopy'; $g.DrawImage($bm, 0, 0, $w, $h); $g.Dispose(); $bm.Dispose()
    $bd = $c32.LockBits((New-Object Drawing.Rectangle 0, 0, $w, $h), 'ReadOnly', 'Format32bppArgb'); $px = New-Object int[] ($w * $h)
    [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $px, 0, $px.Length); $c32.UnlockBits($bd); $c32.Dispose()
    return @{ W = $w; H = $h; Px = $px }
}
$a = Read-Argb $In; $o = Read-Argb $Orig
$solid = [Bleed.K3]::Mask($o.Px, $o.W, $o.H, $a.W, $a.H)
$repl = [Bleed.K3]::Fill($a.Px, $solid, $a.W, $a.H)
$outBm = New-Object Drawing.Bitmap $a.W, $a.H, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
$bd = $outBm.LockBits((New-Object Drawing.Rectangle 0, 0, $a.W, $a.H), 'WriteOnly', 'Format32bppArgb'); [Runtime.InteropServices.Marshal]::Copy($a.Px, 0, $bd.Scan0, $a.Px.Length); $outBm.UnlockBits($bd)
$outBm.Save($Out, [Drawing.Imaging.ImageFormat]::Png); $outBm.Dispose()
$solidN = [Bleed.K3]::Count($solid)
"{0}: {1}x{2}; the original's solid area {3:P1}; {4:P1} replaced by the nearest art colour (its holes + bright magenta inside) -> {5}" -f (Split-Path $In -Leaf), $a.W, $a.H, ($solidN / $solid.Length), ($repl / ($a.W * $a.H)), $Out
