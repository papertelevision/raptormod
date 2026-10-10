# Test-RoomHoles.ps1 -- find every room the host renderer draws with a hole in it, without
# anyone having to walk there and look.
#
#   .\tools\Test-RoomHoles.ps1                  # every room the game loads; summary + CSV
#   .\tools\Test-RoomHoles.ps1 -Rooms MINEMAZE -Detail
#
# THE IDEA. A room is a sealed box seen from inside. So stand the camera where a player can
# stand, look in ALL directions (six 90-degree views: a full sphere), and ask of every pixel:
#   * was anything drawn there?           no  -> an EMPTY hole, straight out of the room
#   * is the nearest surface facing away? yes -> a LEAK: the renderer culled that face and
#                                                 shows whatever is behind the wall instead
# Both are counted by drawing each view twice, culled and unculled, and comparing depth
# (Raster.HoleStats). Viewpoints are the arrival markers (`zy*`, where the game stands the
# player) plus points spread over the walkable floor, at eye height (floor + 45, the game's
# own figure). The parts responsible are named by sampling the leaking pixels.
#
# It cannot tell a hole from an opening the designers meant (a pit, a window on black), so
# it ranks rather than judges: the worst rooms come first, with the worst viewpoint and the
# parts involved, and those are the ones worth a look.
param(
    [string[]]$Rooms,
    [switch]$Detail,
    [int]$PerRoom = 14,                 # floor viewpoints per room, besides the markers
    [int]$Size = 192,
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$GameDir  = 'C:\Games\AzraelsTear-Modded\GAME\AZRAEL',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
if (-not $Csv) { $Csv = Join-Path $CacheDir 'room-holes.csv' }
. (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'),
                 (Join-Path $toolDir 'SceneGraph.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

if ($Rooms) { $Rooms = @($Rooms | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }   # -File hands 'A,B' over as one string
if (-not $Rooms) {
    # the files the game itself loads: ROOMS.DAT, a 60-byte room name then a 60-byte file name
    $have = @{}; Get-ChildItem (Join-Path $CacheDir '*.obj') | ForEach-Object { $have[$_.BaseName.ToUpper()] = 1 }
    $rb = [IO.File]::ReadAllBytes((Join-Path $GameDir 'ROOMS.DAT')); $found = New-Object System.Collections.Generic.List[string]
    for ($o = 62; $o -lt $rb.Length - 62; $o++) {
        $z = [Array]::IndexOf($rb, [byte]0, $o, 13); if ($z -lt $o + 2) { continue }
        $s = [Text.Encoding]::ASCII.GetString($rb, $o, $z - $o).ToUpper()
        if (-not $have.ContainsKey($s) -or $found.Contains($s)) { continue }
        $z2 = [Array]::IndexOf($rb, [byte]0, $o - 60, 60); if ($z2 -lt $o - 58) { continue }
        $nm = [Text.Encoding]::ASCII.GetString($rb, $o - 60, $z2 - ($o - 60))
        if ($nm -notmatch '^[A-Za-z][A-Za-z0-9]{1,15}$' -or [BitConverter]::ToUInt16($rb, $o + 60) -gt 40) { continue }
        $found.Add($s)
    }
    $Rooms = @($found | Where-Object { $_ -notin 'ROOM', 'DEATH' })
}

$ras = New-Object AztTool.Raster($Size, $Size); $ras.NearZ = [single]0.5; $ras.SetVerticalFov(90)
$faces = @(@(1,0,0,1), @(-1,0,0,1), @(0,0,1,1), @(0,0,-1,1), @(0,1,0,2), @(0,-1,0,2))   # direction, up axis
$faceName = 'east','west','north','south','UP','DOWN'
$rows = @()
foreach ($rn in $Rooms) {
    try { $geo = Import-AztRoom -Rooms @($rn) -CacheDir $CacheDir } catch { Write-Host "$rn : $($_.Exception.Message)" -ForegroundColor Yellow; continue }
    $vv = $geo.V; $tt = $geo.T; $tx = $geo.TexIdx; $nT = [int]($tt.Length / 3)
    # ---- where can a player stand? ----
    $pts = New-Object System.Collections.ArrayList
    foreach ($p in $geo.Parts) {
        if ($p.Name -notmatch '^zy' -or $p.VCount -lt 3) { continue }
        $x = 0.0; $y = 0.0; $z = 0.0; for ($k = 0; $k -lt $p.VCount; $k++) { $o = ($p.VFirst + $k) * 3; $x += $vv[$o]; $y += $vv[$o+1]; $z += $vv[$o+2] }
        [void]$pts.Add(@(($x / $p.VCount), ($y / $p.VCount + 45), ($z / $p.VCount), $p.Name))
    }
    # floor: drawn triangles lying nearly flat, big enough to stand on; spread through the list
    $flat = New-Object System.Collections.Generic.List[int]
    for ($t = 0; $t -lt $nT; $t++) {
        if ($tx[$t] -lt 0) { continue }
        $a = $tt[$t*3]*3; $b = $tt[$t*3+1]*3; $c = $tt[$t*3+2]*3
        $e1x = $vv[$b]-$vv[$a]; $e1y = $vv[$b+1]-$vv[$a+1]; $e1z = $vv[$b+2]-$vv[$a+2]
        $e2x = $vv[$c]-$vv[$a]; $e2y = $vv[$c+1]-$vv[$a+1]; $e2z = $vv[$c+2]-$vv[$a+2]
        $nx = $e1y*$e2z - $e1z*$e2y; $ny = $e1z*$e2x - $e1x*$e2z; $nz = $e1x*$e2y - $e1y*$e2x
        $nl = [Math]::Sqrt($nx*$nx + $ny*$ny + $nz*$nz)
        if ($nl -lt 800 -or [Math]::Abs($ny) / $nl -lt 0.9) { continue }          # area >= 400, within ~25 degrees of level
        $flat.Add($t)
    }
    # keep the LOWER half by height: floors, not ceilings
    $byY = @($flat | Sort-Object { $vv[$tt[$_*3]*3 + 1] })
    $floor = @($byY | Select-Object -First ([Math]::Max(1, [int]($byY.Count / 2))))
    if ($floor.Count) {
        $step = [Math]::Max(1, [int]($floor.Count / $PerRoom))
        for ($k = 0; $k -lt $floor.Count -and ($pts.Count -lt $PerRoom + 12); $k += $step) {
            $t = $floor[$k]; $a = $tt[$t*3]*3; $b = $tt[$t*3+1]*3; $c = $tt[$t*3+2]*3
            [void]$pts.Add(@((($vv[$a]+$vv[$b]+$vv[$c])/3), (($vv[$a+1]+$vv[$b+1]+$vv[$c+1])/3 + 45), (($vv[$a+2]+$vv[$b+2]+$vv[$c+2])/3), 'floor'))
        }
    }
    if (-not $pts.Count) { continue }
    $worst = $null; $sumE = 0.0; $sumL = 0.0; $nView = 0; $blame = @{}
    foreach ($pt in $pts) {
        for ($f = 0; $f -lt 6; $f++) {
            $d = $faces[$f]
            $ras.LookAt([single]$pt[0], [single]$pt[1], [single]$pt[2], [single]($pt[0] + $d[0]), [single]($pt[1] + $d[1]), [single]($pt[2] + $d[2]), [int]$d[3])
            $ras.FastClear([byte]0); $ras.DrawTexturedFast($vv, $geo.UV, $tt, $tx, $geo.Texes, $false, $true)
            $all = [single[]]$ras.Depth.Clone()
            $ras.FastClear([byte]0); $ras.DrawTexturedFast($vv, $geo.UV, $tt, $tx, $geo.Texes, $true, $true)
            $e = 0; $l = 0; [AztTool.Raster]::HoleStats($ras.Color, $ras.Depth, $all, [ref]$e, [ref]$l)
            $pe = 100.0 * $e / ($Size * $Size); $pl = 100.0 * $l / ($Size * $Size)
            $sumE += $pe; $sumL += $pl; $nView++
            if ($pl -gt 2) {
                # who is it? the nearest face of all, at a scatter of the leaking pixels
                $dc = $ras.Depth; $seen = 0
                for ($i = 97; $i -lt $all.Length -and $seen -lt 24; $i += 389) {
                    if ($all[$i] -le $dc[$i] * 1.02 + 1e-7) { continue }
                    $t = $ras.TriAt($vv, $tt, $tx, ($i % $Size), [int][Math]::Floor($i / $Size)); $seen++
                    if ($t -ge 0) { $pi2 = $geo.TriPart[$t]; $nm = $(if ($pi2 -ge 0) { [string]$geo.Parts[$pi2].Name } else { '?' }); $blame[$nm] = 1 + [int]$blame[$nm] }
                }
            }
            if (-not $worst -or ($pe + $pl) -gt ($worst.E + $worst.L)) { $worst = @{ E = $pe; L = $pl; At = $pt; Face = $faceName[$f] } }
            if ($Detail -and ($pe + $pl) -gt 3) { '{0,-9} at ({1,6:N0},{2,6:N0},{3,6:N0}) {4,-7} looking {5,-5}: empty {6,5:N1}%  leak {7,5:N1}%' -f $rn, $pt[0], $pt[1], $pt[2], $pt[3], $faceName[$f], $pe, $pl }
        }
    }
    $rows += [pscustomobject]@{ Room = $rn; Views = $nView; Empty = [Math]::Round($sumE / $nView, 2); Leak = [Math]::Round($sumL / $nView, 2)
        WorstEmpty = [Math]::Round($worst.E, 1); WorstLeak = [Math]::Round($worst.L, 1)
        WorstAt = ('{0:N0},{1:N0},{2:N0} {3}' -f $worst.At[0], $worst.At[1], $worst.At[2], $worst.Face)
        LeakingParts = ((@($blame.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object { $_.Key })) -join ' ') }
}
$rows = @($rows | Sort-Object { $_.Empty + $_.Leak } -Descending)
$rows | Export-Csv $Csv -NoTypeInformation
$rows | Format-Table Room, Views, Empty, Leak, WorstEmpty, WorstLeak, WorstAt, LeakingParts -AutoSize | Out-String -Width 220
"{0} rooms, {1} views; written -> {2}" -f $rows.Count, ($rows | Measure-Object Views -Sum).Sum, $Csv