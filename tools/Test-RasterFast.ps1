# Prove DrawTexturedFast draws what DrawTextured draws, and measure what it saves.
#
#   .\tools\Test-RasterFast.ps1
#   .\tools\Test-RasterFast.ps1 -Rooms MINEHEAD,ORRERY -Runs 40
#
# No game needed. Each room is loaded exactly as the watcher loads it and rendered from a
# ring of cameras around several eye points inside its bounds, once by the reference and
# once by the fast path. Two things are reported per room:
#
#   * DIFFERING PIXELS with nearest-first sorting OFF. This must be ZERO: with the same
#     triangle order the fast path runs the reference's arithmetic on every pixel it visits,
#     so any difference means its row spans skipped a pixel the reference would have drawn.
#   * differing pixels with sorting ON. Not expected to be zero -- coplanar faces at exactly
#     equal depth resolve to whichever is drawn first -- but it should be a handful.
#
# Timings include the clear, because the watcher pays for it every frame too.
param(
    [string[]]$Rooms = @('CORICORI', 'SPAROOM', 'MINEHEAD', 'ORRERY'),
    [int]$Runs = 30,
    [int]$W = 1600, [int]$H = 928,
    [double]$Fov = 50,
    [string]$TexDir   = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    [string]$CacheDir = 'C:\Games\RaptorMod\cache',
    [string]$Palette  = 'C:\Games\RaptorMod\cache\azrael-palette.pal'
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
. (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'),
                 (Join-Path $toolDir 'SceneGraph.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

function Median([double[]]$v) { $s = @($v | Sort-Object); $s[[int]($s.Count / 2)] }

$threads = [Math]::Max(2, [int]([Environment]::ProcessorCount / 2))
$ref = New-Object AztTool.Raster($W, $H); $fast = New-Object AztTool.Raster($W, $H)
foreach ($r in $ref, $fast) { $r.NearZ = [single]0.5; $r.SetVerticalFov($Fov); $r.Threads = $threads }
Write-Host ("{0}x{1}, fov {2}, {3} threads, {4} timed runs per camera`n" -f $W, $H, $Fov, $threads, $Runs)

$allRef = @(); $allFast = @(); $worstUnsorted = 0
foreach ($name in $Rooms) {
    $room = Import-AztRoom -Rooms @($name) -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette -Width $W -Height $H
    $v = $room.V; $nv = $v.Length / 3
    $mn = @([single]::MaxValue) * 3; $mx = @([single]::MinValue) * 3
    for ($i = 0; $i -lt $nv; $i++) { for ($k = 0; $k -lt 3; $k++) { $c = $v[$i*3+$k]; if ($c -lt $mn[$k]) { $mn[$k] = $c }; if ($c -gt $mx[$k]) { $mx[$k] = $c } } }
    $cx = ($mn[0]+$mx[0])/2; $cy = ($mn[1]+$mx[1])/2; $cz = ($mn[2]+$mx[2])/2
    $rx = ($mx[0]-$mn[0])/2; $rz = ($mx[2]-$mn[2])/2
    # eye points: the centre, and four a third of the way out -- some will be inside a wall,
    # which is the near-plane-clipping case and exactly the one worth testing
    $eyes = @(@($cx,$cy,$cz), @(($cx+$rx/3),$cy,$cz), @(($cx-$rx/3),$cy,$cz), @($cx,$cy,($cz+$rz/3)), @($cx,$cy,($cz-$rz/3)))
    $tRef = @(); $tFast = @(); $dUns = 0; $dSort = 0; $cams = 0; $drawn = 0
    foreach ($e in $eyes) {
        for ($yaw = 0; $yaw -lt 360; $yaw += 45) {
            $a = $yaw * [Math]::PI / 180
            $tx = $e[0] + [Math]::Sin($a) * 100; $tz = $e[2] + [Math]::Cos($a) * 100; $ty = $e[1] - 10
            foreach ($r in $ref, $fast) { $r.LookAt([single]$e[0], [single]$e[1], [single]$e[2], [single]$tx, [single]$ty, [single]$tz, 1) }
            $cams++

            $ref.Clear([byte]0); $ref.DrawTextured($v, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true)
            $drawn += $ref.PixelsWritten

            $fast.SortFrontToBack = $false
            $fast.FastClear([byte]0); $fast.DrawTexturedFast($v, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true)
            $d = 0; $rc = $ref.Color; $fc = $fast.Color
            # compared in .NET: indexing 1.48 M bytes from script takes seconds per frame
            if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$rc, [byte[]]$fc)) { for ($i = 0; $i -lt $rc.Length; $i++) { if ($rc[$i] -ne $fc[$i]) { $d++ } } }
            $dUns += $d
            # depth too: a matching picture over a different depth buffer would hide a bug
            if (-not [System.Linq.Enumerable]::SequenceEqual([single[]]$ref.Depth, [single[]]$fast.Depth)) { $dUns += 1 }

            $fast.SortFrontToBack = $true
            $fast.FastClear([byte]0); $fast.DrawTexturedFast($v, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true)
            $fc = $fast.Color
            if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$rc, [byte[]]$fc)) { for ($i = 0; $i -lt $rc.Length; $i++) { if ($rc[$i] -ne $fc[$i]) { $dSort++ } } }

            if (($yaw % 90) -eq 0) {
                $sw = [Diagnostics.Stopwatch]::new()
                $a1 = New-Object double[] $Runs; $a2 = New-Object double[] $Runs
                for ($k = 0; $k -lt $Runs; $k++) {
                    $sw.Restart(); $ref.Clear([byte]0); $ref.DrawTextured($v, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true); $a1[$k] = $sw.Elapsed.TotalMilliseconds
                    $sw.Restart(); $fast.FastClear([byte]0); $fast.DrawTexturedFast($v, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true); $a2[$k] = $sw.Elapsed.TotalMilliseconds
                }
                $tRef += (Median $a1); $tFast += (Median $a2)
            }
        }
    }
    $mr = Median $tRef; $mf = Median $tFast
    $allRef += $tRef; $allFast += $tFast; if ($dUns -gt $worstUnsorted) { $worstUnsorted = $dUns }
    $col = $(if ($dUns -eq 0) { 'Green' } else { 'Red' })
    Write-Host ("{0,-9} {1,5} tris, {2} cameras, {3:N0} px/frame avg" -f $name, ($room.T.Count/3), $cams, ($drawn / $cams))
    Write-Host ("          reference {0,5:N2} ms   fast {1,5:N2} ms   x{2:N2}   (worst camera: {3:N2} -> {4:N2} ms)" -f $mr, $mf, ($mr / $mf), ($tRef | Measure-Object -Maximum).Maximum, ($tFast | Measure-Object -Maximum).Maximum)
    Write-Host ("          differing pixels, same order: {0}    nearest-first: {1} of {2:N0} ({3:P4})" -f $dUns, $dSort, ($cams * $W * $H), ($dSort / ($cams * $W * $H))) -ForegroundColor $col
}
Write-Host ("`nALL ROOMS  reference {0:N2} ms   fast {1:N2} ms   x{2:N2}" -f (Median $allRef), (Median $allFast), ((Median $allRef) / (Median $allFast)))
if ($worstUnsorted -ne 0) { Write-Host 'THE FAST PATH DOES NOT MATCH THE REFERENCE. Do not ship it.' -ForegroundColor Red; exit 1 }
Write-Host 'Same triangle order => identical picture and depth buffer on every camera.' -ForegroundColor Green
