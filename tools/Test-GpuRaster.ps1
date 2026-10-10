# Test-GpuRaster.ps1 -- the graphics-card renderer (tools\GpuRaster.cs) against the processor's
# (tools\Raster.cs), without a game: the same room, the same cameras.
#   -Lit: both lit as the watcher lights them -- helmet lamp (aimed off centre), the room's fog
#   and placed lights from C:\Games\azrael-render\rooms -- with no shadows on either side.
#   -Full: everything the watcher draws, on both sides, every frame -- -Lit plus the lamp's shadow
#   view (one lamp, 512 tall), the placed lights' shadow views, water reflections (the room
#   loaded by the watcher's own Get-Room, which finds the pools) and dust.
#
#   .\tools\Test-GpuRaster.ps1                       (first room, 2562x1238)
#   .\tools\Test-GpuRaster.ps1 -Room SPAROOM -Width 1920 -Height 928
#
# Reports which card and driver, how long a frame takes each way (the card's time includes
# reading the picture back), how far the two pictures differ, and saves them side by side.
param(
    [string]$Room = 'CORICORI',
    [int]$Width = 2562, [int]$Height = 1238,
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$Palette = 'C:\Games\azrael-inject\azrael-palette.pal',
    [string]$HiresDir = 'C:\Games\azrael-textures\hires',
    [string]$OutDir = 'C:\Games\azrael-render\tc-test',
    [int]$Frames = 40,
    [switch]$Lit,
    [switch]$Full,
    [string]$RoomsDir = 'C:\Games\azrael-render\rooms',
    # the view in the top rows only, the picture carrying on beneath (the 3D under the widescreen panel)
    [int]$ViewRows = 0
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolDir 'GuestBase.ps1'); . (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'GpuRaster.cs'), (Join-Path $toolDir 'GiBake.cs'), (Join-Path $toolDir 'Motes.cs')) -ReferencedAssemblies 'System.Drawing'
if ($Full) { $Lit = $true }
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class GpuCmp {
    // mean absolute difference per channel over pixels both drew; and pixels only one drew
    // coverage from the processor's own 8-bit buffer (index 0 = nothing drawn) and the card's depth
    public static double[] Compare(int[] a, int[] b, byte[] aDrawn, float[] bDepth) {
        long s = 0, both = 0, onlyA = 0, onlyB = 0, big = 0;
        for (int i = 0; i < a.Length; i++) {
            int x = a[i] & 0xFFFFFF, y = b[i] & 0xFFFFFF;
            bool da = aDrawn[i] != 0, db = bDepth[i] > 0f;
            if (!da && !db) continue;
            if (!da) { onlyB++; continue; } if (!db) { onlyA++; continue; }
            int d = Math.Abs(((x >> 16) & 255) - ((y >> 16) & 255)) + Math.Abs(((x >> 8) & 255) - ((y >> 8) & 255)) + Math.Abs((x & 255) - (y & 255));
            s += d; both++; if (d > 3 * 40) big++;
        }
        return new double[] { both == 0 ? 0 : s / (3.0 * both), both, onlyA, onlyB, big };
    }
    public static void Save(string path, int[][] pics, int w, int h) {
        using (var bm = new Bitmap(w * pics.Length, h, PixelFormat.Format32bppRgb)) {
            var bd = bm.LockBits(new Rectangle(0, 0, w * pics.Length, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
            for (int p = 0; p < pics.Length; p++) for (int y = 0; y < h; y++) Marshal.Copy(pics[p], y * w, new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride + p * w * 4), w);
            bm.UnlockBits(bd); bm.Save(path, ImageFormat.Png);
        }
    }
}
'@
function Median($xs) { $s = @($xs | Sort-Object); return $s[[int]($s.Count / 2)] }

$pal = [IO.File]::ReadAllBytes($Palette)
$wp = Join-Path $toolDir 'Watch-HostRender.ps1'; $tk = $null; $pe = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($wp, [ref]$tk, [ref]$pe)
# (returns the functions' code; the CALLER dot-sources it, or they would vanish with this function's scope)
function Get-WatcherFunction([string[]]$names) { foreach ($fn in $names) { $fd = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true); [scriptblock]::Create($fd.Extent.Text) } }
function Say([string]$m, [string]$c = 'Gray') { }
if ($Full) {
    # the watcher's own room loader: it is what finds the water and its levels
    foreach ($sb in (Get-WatcherFunction 'Get-CharacterSig', 'Get-Room')) { . $sb }
    $W = 1600; $H = 928; $CacheRooms = 8; $TrueColour = $true; $NoRgb = $false; $TexOverrideDir = $HiresDir; $TexScale = 1; $NoReflections = $false
    $roomCache = New-Object System.Collections.Specialized.OrderedDictionary; $script:rgbLut = [AztTool.Raster]::BuildRgbLut($pal)
    $rm = Get-Room @($Room)
} else {
    $rm = Import-AztRoom -Rooms @($Room) -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette -Width $Width -Height $Height
    [void](Add-AztRgb -Names @($Room) -CacheDir $CacheDir -Pal $pal -OverrideDir $HiresDir); [AztTool.Raster]::EnsureRgb($rm.Texes, $pal)
}
"{0}: {1:N0} triangles, {2} textures" -f $Room, ($rm.T.Length / 3), $rm.Texes.Length

$cpu = New-Object AztTool.Raster($Width, $Height); $cpu.NearZ = [single]0.5; $cpu.SetVerticalFov(50); $cpu.EnableRgb(); $cpu.MipBias = [single]-0.35; $cpu.ViewRows = $ViewRows
$cpu.Threads = [Environment]::ProcessorCount - [int]([Environment]::ProcessorCount / 10)
if ($Lit) {
    # the watcher's own lamp settings and its own atmosphere functions (cut from its source)
    $cpu.SetLightTable([AztTool.Raster]::BuildLightTable($pal, 76, [single]2.4), 76, [single]2.4)
    $cpu.LampHalo = [single]0.495; $cpu.LampHaloInnerDeg = [single]10; $cpu.LampHaloDeg = [single]24; $cpu.LampRoom = [single]0.54; $cpu.LampPower = [single]1.68; $cpu.LampRange = [single]550
    $cpu.LampInnerDeg = [single]8.64; $cpu.LampOuterDeg = [single]21; $cpu.Lamp = $true
    $cpu.LampCx = [single]90; $cpu.LampCy = [single]-40          # the beam trailing a turn
    foreach ($sb in (Get-WatcherFunction 'ConvertTo-Rgb24', 'Get-RoomAtmosphere', 'Set-RoomAtmosphere', 'Update-RoomLights')) { . $sb }
    $NoFog = $false; $NoDust = (-not $Full); $NoLights = $false; $script:atmClock = [Diagnostics.Stopwatch]::StartNew()
    Set-RoomAtmosphere $cpu (Get-RoomAtmosphere @($Room)) $rm
    $cpu.ClearLightShadows()                                    # (-Lit: no shadows on either side)
    $cpu.ShadowDark = [single]0.30; $cpu.ShadowNear = [single]140; $cpu.ShadowFar = [single]900; $cpu.ShadowSoft = [single]1.0
    "lit: lamp aimed (+90, -40) px; fog {0}; {1} placed light(s){2}" -f $(if ($cpu.Fog32) { 'on' } else { 'off' }), $script:roomLights.Count, $(if ($Full) { ("; FULL: lamp shadow, light shadows, {0} water group(s), dust {1}" -f @($rm.WaterGroups).Count, $(if ($script:motes) { $script:motes.Count } else { 0 })) } else { '' })
    if ($Full) {
        # the lamp's shadow view as the watcher makes it: one lamp, 512 tall, the picture's shape, 58 degrees
        $shadowW = [int]([Math]::Round(512 * $Width / [double]$Height / 4) * 4)
        $rs = New-Object AztTool.Raster($shadowW, 512); $rs.NearZ = [single]0.5; $rs.SetVerticalFov(58); $rs.Threads = $cpu.Threads
        $lampM = New-Object single[] 16; $mirV = $null; $moteBuf = New-Object single[] 6000
    }
}
$err = $null; $gpu = [AztTool.GpuRaster]::Create($Width, $Height, [ref]$err)
if (-not $gpu) { "NO GPU: $err"; exit 1 }
try {
    "card: {0} / {1}; OpenGL {2}; depth as 1/z (reverse Z): {3}" -f $gpu.Vendor, $gpu.Renderer, $gpu.Version, $gpu.ReverseZ
    $gpu.NearZ = [single]0.5; $gpu.SetVerticalFov(50); $gpu.MipBias = [single]-0.35; $gpu.ViewRows = $ViewRows
    $up = [Diagnostics.Stopwatch]::StartNew(); [void]$gpu.Upload($rm.Texes); $upMs = $up.Elapsed.TotalMilliseconds
    "textures onto the card: {0} in {1:N0} ms, {2:N0} MB" -f $gpu.TexturesUploaded, $upMs, ($gpu.TextureBytes / 1MB)

    # cameras: the middle of the room, eye 40 above its floor, eight headings, looking a little down
    $v = $rm.V; $n = $v.Length / 3; $sx = 0.0; $sz = 0.0; $minY = [double]::MaxValue
    for ($i = 0; $i -lt $n; $i++) { $sx += $v[$i * 3]; $sz += $v[$i * 3 + 2]; if ($v[$i * 3 + 1] -lt $minY) { $minY = $v[$i * 3 + 1] } }
    $ex = $sx / $n; $ez = $sz / $n; $ey = $minY + 40
    if ($Room -eq 'CORICORI') { $ex = -101.8; $ey = 49.5; $ez = 113.3 }
    $pitch = -15
    if ($Full -and @($rm.Water).Count) {
        # over the water, looking down at it: where a reflection shows
        $wt0 = $rm.Water[0]; $wx = 0.0; $wz = 0.0; $wn = 0
        foreach ($vi in $wt0.TriVerts) { $wx += $rm.V[$vi * 3]; $wz += $rm.V[$vi * 3 + 2]; $wn++ }
        $ex = $wx / $wn; $ez = $wz / $wn; $ey = $rm.V[$wt0.VFirst * 3 + 1] + 45; $pitch = -40
    }
    $cams = @()
    foreach ($yaw in 0, 45, 90, 135, 180, 225, 270, 315) {
        $a = $yaw * [Math]::PI / 180
        $cpu.LookAt([single]$ex, [single]$ey, [single]$ez, [single]($ex + [Math]::Sin($a) * 100), [single]($ey + $pitch), [single]($ez + [Math]::Cos($a) * 100), 1)
        $b = $cpu.LastBasis; $vals = @($b[0], $b[1], $b[2], 0, $b[3], $b[4], $b[5], 0, $b[6], $b[7], $b[8], 0, $ex, $ey, $ez, 1)
        $c16 = New-Object single[] 16; for ($i = 0; $i -lt 16; $i++) { $c16[$i] = [single]$vals[$i] }; $cams += ,$c16
    }
    $gpic = New-Object int[] ($Width * $Height); $gdep = New-Object single[] ($Width * $Height)
    $cT = @(); $gT = @(); $gD = @(); $gR = @(); $diffs = @(); $saved = $false
    for ($f = 0; $f -lt $Frames; $f++) {
        $cam = $cams[$f % $cams.Count]
        $cpu.SetCameraWorld($cam); $gpu.SetCameraWorld($cam)
        if ($Lit) { Update-RoomLights $cpu }           # the torch's flicker, this frame
        $gpu.CopyLighting($cpu)                         # the card takes the processor's lighting as it stands
        if ($Full) { $script:motes.Update([single]0.02, $cam[12], $cam[13], $cam[14]); $script:motes.LampLevel = [single]1 }
        $t = [Diagnostics.Stopwatch]::StartNew()
        if ($Full) {
            # the lamp: the camera's own orientation moved 24 right and 8 up (as the watcher, before its wall check)
            [Array]::Copy($cam, $lampM, 16); for ($k = 0; $k -lt 3; $k++) { $lampM[12 + $k] = [single]($cam[12 + $k] + $cam[$k] * 24 + $cam[4 + $k] * 8) }
            $rs.SetCameraWorld($lampM); $cpu.SetShadow($rs.Depth, $rs.W, $rs.H, $rs.FocalPixels, [single]24, [single]8); $cpu.SetShadow2($null, 0, 0)
            [AztTool.Raster]::DrawDepthPair($rs, $null, $rm.V, $rm.UV, $rm.T, $rm.TexIdx, $rm.Texes, $true)
            # the placed lights that cast, as the watcher draws them
            for ($li = 0; $li -lt $script:roomLights.Count; $li++) {
                $lz = $script:lightRs[$li]; if (-not $lz) { continue }
                $l = $script:roomLights[$li]; $d = $l.Dir; $upAx = $(if ([Math]::Abs($d[1]) -gt 0.9) { 0 } else { 1 })
                $lz.LookAt($l.X, $l.Y, $l.Z, [single]($l.X + $d[0] * 100), [single]($l.Y + $d[1] * 100), [single]($l.Z + $d[2] * 100), $upAx)
                $lz.FastClear([byte]0); $lz.DrawTexturedFast($rm.V, $rm.UV, $rm.T, $rm.TexIdx, $rm.Texes, $false, $true)
                $cpu.SetLightShadow($li, $lz.Depth, $lz.W, $lz.FocalPixels, $lz.LastBasis)
                $gpu.SetLightShadow($li, $l.X, $l.Y, $l.Z, $lz.LastBasis, $lz.W, $lz.FocalPixels)
            }
            $gpu.SetLampShadow(0, $lampM, $rs.W, $rs.H, $rs.FocalPixels, [single]24, [single]8)
        }
        $cpu.FastClear([byte]0); $cpu.DrawTexturedFast($rm.V, $rm.UV, $rm.T, $rm.TexIdx, $rm.Texes, $true, $true)
        if ($Full) {
            # water, as the watcher: mark the pool, the room mirrored through it
            foreach ($wGroup in @($rm.WaterGroups)) {      # (not $gr: that IS $gR, the timing list)
                $cpu.BeginPortals(); $wpx = 0; $wySum = 0.0; $wyN = 0; $tl = New-Object 'System.Collections.Generic.List[int]'
                foreach ($wt in $wGroup.Parts) { $wyP = $rm.V[$wt.VFirst * 3 + 1]; if ($cam[13] -le $wyP + 1) { continue }; $wpx += $cpu.AddPortal($rm.V, $wt.TriVerts, [byte]250, $true); $wySum += $wyP; $wyN++; $tl.AddRange([int[]]$wt.TriVerts) }
                if ($wyN -eq 0) { continue }
                $gpu.AddWater($tl.ToArray(), [single]($wySum / $wyN))
                if ($wpx -le 0) { continue }
                $cpu.EndPortals($true)
                if (-not $mirV -or $mirV.Length -ne $rm.V.Length) { $mirV = New-Object single[] $rm.V.Length }
                [AztTool.Raster]::Mirror($rm.V, $mirV, [single]($wySum / $wyN))
                $cpu.MaskBeyond = $true; $cpu.MaskKeep = [single]0.65; $cpu.MaskDim = [single]0.72
                $cpu.DrawTexturedMasked($mirV, $rm.UV, $rm.TSwap, $rm.TexIdx, $rm.Texes, $true, $true, [byte]250)
                $cpu.MaskBeyond = $false; $cpu.MaskKeep = [single]0; $cpu.MaskDim = [single]1
            }
            if ($script:motes) { [void]$script:motes.Draw($cpu); $nm = $script:motes.Gather($cpu, $moteBuf); $gpu.SetMotes($moteBuf, $nm, $script:motes.Color, $script:motes.ColorDark) }
        }
        $cMs = $t.Elapsed.TotalMilliseconds
        $t.Restart()
        $gpu.Draw($rm.V, $rm.UV, $rm.T, $rm.TexIdx, $rm.Texes, $true, $true); $gpu.ReadBack($gpic)
        $gMs = $t.Elapsed.TotalMilliseconds
        if ($f -ge 4) { $cT += $cMs; $gT += $gMs; $gD += $gpu.LastDrawMs; $gR += $gpu.LastReadMs }
        if ($f -lt $cams.Count) {
            $gpu.ReadDepth($gdep); $d = [GpuCmp]::Compare([int[]]$cpu.Color32, $gpic, [byte[]]$cpu.Color, $gdep); $diffs += ,$d
            if (-not $saved -and $d[1] -gt $Width * $Height * 0.5) {
                New-Item -ItemType Directory -Force $OutDir | Out-Null
                $png = Join-Path $OutDir ("gpu-vs-cpu-{0}{1}.png" -f $Room, $(if ($Full) { "-full" } elseif ($Lit) { "-lit" } else { "" }))
                [GpuCmp]::Save($png, [int[][]]@([int[]]$cpu.Color32.Clone(), [int[]]$gpic.Clone()), $Width, $Height); $saved = $true
                "saved processor | card side by side: $png"
            }
        }
    }
    "per frame, median of {0}:" -f $cT.Count
    "  processor (Raster, {0} threads)           {1,6:N1} ms" -f $cpu.Threads, (Median $cT)
    "  graphics card, draw + read back           {0,6:N1} ms   (issuing the draw {1:N1}, waiting + reading the picture {2:N1}); {3} texture batches, {4} shadow views, {5} water groups, {6} motes" -f (Median $gT), (Median $gD), (Median $gR), $gpu.LastBatches, $gpu.LastShadowViews, $gpu.LastWaterGroups, $gpu.LastMotes
    "pictures compared over {0} headings:" -f $diffs.Count
    foreach ($d in $diffs) { "  mean difference {0,5:N2} / 255 over {1,9:N0} pixels both drew; only processor {2,6:N0}, only card {3,6:N0}; pixels off by more than 40: {4:N0}" -f $d[0], $d[1], $d[2], $d[3], $d[4] }
} finally { $gpu.Dispose() }
