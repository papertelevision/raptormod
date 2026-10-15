# Test-MeshSmooth.ps1 -- the model smoother, checked without a game.
#
#   .\tools\Test-MeshSmooth.ps1                 (the checks, then every exported unit)
#   .\tools\Test-MeshSmooth.ps1 -Levels 2 -CreaseDeg 35
#
# 1. Made-up shapes with known answers:
#      a cube and a flat sheet must come back UNCHANGED (a box must not turn into a pillow);
#      a coarse sphere must end up measurably closer to a true sphere, with no new open edges;
#      a sphere with a texture seam down it must still be closed.
# 2. Every unit the renderer has exported (rooms and characters): triangles before and after,
#    parts still own contiguous vertex ranges, no new open edges. Reported as a table of the
#    units that grow the most, and totals.
param(
    [int]$Levels = 1, [double]$CreaseDeg = 40, [double]$MinMove = 0.03, [int]$MaxTris = 60000,
    [string]$CacheDir = 'C:\Games\RaptorMod\cache', [int]$Top = 14
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -Path @((Join-Path $toolDir 'RoomUnit.cs'), (Join-Path $toolDir 'MeshSmooth.cs')) -ErrorAction Stop
$fail = 0
function Check([string]$what, [bool]$ok) { Write-Host ("  {0,-66} {1}" -f $what, $(if ($ok) { 'ok' } else { 'FAILED' })) -ForegroundColor $(if ($ok) { 'Gray' } else { 'Red' }); if (-not $ok) { $script:fail++ } }
function New-Unit([single[]]$v, [single[]]$uv, [int[]]$t) {
    $u = New-Object AztRoom.RoomUnit
    $u.V = $v; $u.UV = $uv; $u.T = $t; $nt = $t.Length / 3
    $u.TexIdx = New-Object int[] $nt; $u.TriPart = New-Object int[] $nt
    $u.PartName = @('shape'); $u.PartVFirst = @(0); $u.PartVCount = @([int]($v.Length / 3)); $u.PartRest = New-Object single[] 16
    $u.TexW = @(1); $u.TexH = @(1); $u.TexData = New-Object 'byte[][]' 1; $u.TexData[0] = New-Object byte[] 1
    return $u
}
function Smooth($u, [int]$lv = $Levels) { $st = $null; $r = [AztRoom.MeshSmooth]::Smooth($u, $lv, [single]$CreaseDeg, [single]$MinMove, $MaxTris, [ref]$st); return @{ U = $r; S = $st } }

Write-Host 'made-up shapes'
# --- a cube, 8 shared corners
$cv = @(); foreach ($z in -10, 10) { foreach ($y in -10, 10) { foreach ($x in -10, 10) { $cv += $x, $y, $z } } }
$ct = @(0,2,1, 1,2,3,  4,5,6, 5,7,6,  0,1,4, 1,5,4,  2,6,3, 3,6,7,  0,4,2, 2,4,6,  1,3,5, 3,7,5)
$cube = New-Unit ([single[]]$cv) (New-Object single[] 16) ([int[]]$ct)
$r = Smooth $cube
Check 'a cube keeps its 12 triangles' ($r.S.TrisAfter -eq 12)
Check 'and its 8 corners exactly where they were' ([System.Linq.Enumerable]::SequenceEqual([single[]]$r.U.V, [single[]]$cube.V))
# --- a flat sheet, 4x4 squares
$sv = @(); $suv = @(); for ($y = 0; $y -le 4; $y++) { for ($x = 0; $x -le 4; $x++) { $sv += ($x * 10), 0, ($y * 10); $suv += ($x / 4), ($y / 4) } }
$stt = @(); for ($y = 0; $y -lt 4; $y++) { for ($x = 0; $x -lt 4; $x++) { $a = $y * 5 + $x; $stt += $a, ($a + 5), ($a + 1), ($a + 1), ($a + 5), ($a + 6) } }
$r = Smooth (New-Unit ([single[]]$sv) ([single[]]$suv) ([int[]]$stt))
Check 'a flat sheet gains nothing' ($r.S.TrisAfter -eq 32)
# --- a coarse sphere (8 round, 5 up), radius 50, with a duplicated seam column like a textured one has
$RAD = 50.0; $seg = 8; $rings = 5; $pv = @(); $puv = @()
for ($j = 0; $j -le $rings; $j++) { $phi = [Math]::PI * $j / $rings
    for ($i = 0; $i -le $seg; $i++) { $th = 2 * [Math]::PI * $i / $seg      # i = seg repeats i = 0: the seam
        $pv += ($RAD * [Math]::Sin($phi) * [Math]::Cos($th)), ($RAD * [Math]::Cos($phi)), ($RAD * [Math]::Sin($phi) * [Math]::Sin($th)); $puv += ($i / $seg), ($j / $rings) } }
$pt = @(); for ($j = 0; $j -lt $rings; $j++) { for ($i = 0; $i -lt $seg; $i++) { $a = $j * ($seg + 1) + $i; $b = $a + $seg + 1
    if ($j -gt 0) { $pt += $a, ($a + 1), $b }; if ($j -lt $rings - 1) { $pt += ($a + 1), ($b + 1), $b } } }
$sph = New-Unit ([single[]]$pv) ([single[]]$puv) ([int[]]$pt)
function SphereError($u) { $worst = 0.0; $sum = 0.0; $n = $u.T.Length / 3
    for ($f = 0; $f -lt $n; $f++) { $cx = 0.0; $cy = 0.0; $cz = 0.0; for ($k = 0; $k -lt 3; $k++) { $vi = $u.T[$f * 3 + $k]; $cx += $u.V[$vi * 3]; $cy += $u.V[$vi * 3 + 1]; $cz += $u.V[$vi * 3 + 2] }
        $d = [Math]::Abs($RAD - [Math]::Sqrt($cx * $cx + $cy * $cy + $cz * $cz) / 3); $sum += $d; if ($d -gt $worst) { $worst = $d } }
    return @{ Mean = $sum / $n; Worst = $worst } }
$e0 = SphereError $sph; $b0 = [AztRoom.MeshSmooth]::BorderEdges($sph)
$r = Smooth $sph; $e1 = SphereError $r.U
Write-Host ("    sphere: {0} -> {1} triangles; face centres off the true sphere by {2:N2} -> {3:N2} on average, {4:N2} -> {5:N2} at worst" -f $r.S.TrisBefore, $r.S.TrisAfter, $e0.Mean, $e1.Mean, $e0.Worst, $e1.Worst)
Check 'a coarse sphere gets more triangles' ($r.S.TrisAfter -gt $r.S.TrisBefore)
Check 'and they lie closer to the true sphere (under half the error)' ($e1.Mean -lt $e0.Mean * 0.5)
Check 'no new open edges, texture seam included (no cracks)' ([AztRoom.MeshSmooth]::BorderEdges($r.U) -eq $b0)
Check 'the part still owns one contiguous vertex range' ([AztRoom.MeshSmooth]::CheckParts($r.U) -eq '' -and $r.U.PartVCount[0] -eq $r.U.V.Length / 3)
Check 'every corner has a smoothing group' (@($r.U.CornerGroup | Where-Object { $_ -lt 0 }).Count -eq 0)
$r2 = Smooth $sph 2; $e2 = SphereError $r2.U
Write-Host ("    two levels: {0} triangles, mean error {1:N2}" -f $r2.S.TrisAfter, $e2.Mean)
Check 'two levels: closer again, still closed' ($e2.Mean -lt $e1.Mean -and [AztRoom.MeshSmooth]::BorderEdges($r2.U) -eq $b0)
$r0 = Smooth $sph 0
Check 'zero levels: geometry untouched, groups still worked out' ($r0.S.TrisAfter -eq $r0.S.TrisBefore -and $r0.U.CornerGroup.Length -eq $sph.T.Length)

# --- every exported unit
Write-Host ("`nexported units (levels {0}, crease {1} degrees, least move {2})" -f $Levels, $CreaseDeg, $MinMove)
$rows = @(); $tb = 0; $ta = 0; $bad = 0; $ms = 0.0
foreach ($f in Get-ChildItem $CacheDir -Filter *.unit) {
    $u = $null
    try { $fs = [IO.File]::OpenRead($f.FullName); $br = New-Object IO.BinaryReader($fs, [Text.Encoding]::UTF8); [void]$br.ReadInt32(); [void]$br.ReadInt32(); $stamp = $br.ReadString(); $br.Dispose(); $u = [AztRoom.RoomUnit]::Load($f.FullName, $stamp) } catch { }
    if (-not $u) { continue }
    $before = [AztRoom.MeshSmooth]::BorderEdges($u)
    $r = Smooth $u
    $prob = [AztRoom.MeshSmooth]::CheckParts($r.U)
    $after = [AztRoom.MeshSmooth]::BorderEdges($r.U)
    if ($prob -or $after -ne $before) { $bad++; Write-Host ("  {0}: {1} {2}" -f $f.BaseName, $prob, $(if ($after -ne $before) { "open edges $before -> $after" })) -ForegroundColor Red }
    $tb += $r.S.TrisBefore; $ta += $r.S.TrisAfter; $ms += $r.S.Ms
    $rows += [pscustomobject]@{ Unit = $f.BaseName; Before = $r.S.TrisBefore; After = $r.S.TrisAfter; Growth = $(if ($r.S.TrisBefore) { $r.S.TrisAfter / $r.S.TrisBefore } else { 1 }); Parts = $r.S.PartsChanged; Ms = $r.S.Ms; Note = $r.S.Note }
}
$rows | Sort-Object Growth -Descending | Select-Object -First $Top | Format-Table Unit, Before, After, @{ n = 'x'; e = { '{0:N2}' -f $_.Growth } }, Parts, @{ n = 'ms'; e = { '{0:N1}' -f $_.Ms } }, Note -AutoSize | Out-String | Write-Host
Write-Host ("{0} units: {1:N0} -> {2:N0} triangles (x{3:N2}); {4} unchanged; {5:N0} ms in all" -f $rows.Count, $tb, $ta, $(if ($tb) { $ta / $tb } else { 1 }), @($rows | Where-Object { $_.After -eq $_.Before }).Count, $ms)
Check 'every unit: parts intact and no new open edges' ($bad -eq 0)
if ($fail) { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all checks passed' -ForegroundColor Green }
