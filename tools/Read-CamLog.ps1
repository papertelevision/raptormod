# Read-CamLog.ps1 -- decode AZTCAM.LOG, the §14 camera-transform experiment.
#
# The stub writes fixed 320-byte binary records (see the aztCamRec label run in
# Build-AztMod.ps1 for the authoritative map). This decodes them and, more to the
# point, ANSWERS THE EXPERIMENT'S QUESTIONS rather than just dumping numbers:
#
#   1. Do the two candidate frames resolve at all, and are they really frames?
#   2. Are [0x152144] (the viewport camera) and [0x162DE4] (the frame movement
#      drives) the same object, parent and child, or unrelated?
#   3. Does the transform TRACK MOVEMENT -- does translation change when walking
#      and the rotation basis change when turning?
#   4. Is the rotation block a well-formed orthonormal basis? If it is, the matrix
#      really is a camera transform and not three floats that happen to move.
#
# Usage:
#   .\tools\Read-CamLog.ps1                       # summary + verdicts
#   .\tools\Read-CamLog.ps1 -Rows 40              # also print 40 sampled rows
#   .\tools\Read-CamLog.ps1 -Csv out.csv          # full per-frame export

[CmdletBinding()]
param(
    [string]$Path,
    [int]$Rows = 0,
    [string]$Csv
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    foreach ($c in @(
        'C:\Games\AzraelsTear-Modded\AZTCAM.LOG',
        (Join-Path $PSScriptRoot '..\..\AZTCAM.LOG')
    )) { if (Test-Path $c) { $Path = (Resolve-Path $c).Path; break } }
}
if (-not $Path -or -not (Test-Path $Path)) { throw "AZTCAM.LOG not found. Pass -Path." }

$RECLEN = 320
$b = [IO.File]::ReadAllBytes($Path)
$n = [Math]::Floor($b.Length / $RECLEN)
Write-Host ("AZTCAM.LOG: {0:N0} bytes, {1:N0} records" -f $b.Length, $n)
if ($b.Length % $RECLEN -ne 0) {
    Write-Host ("  NOTE: {0} trailing bytes -- the last record was not flushed (expected on a hard quit)" -f ($b.Length % $RECLEN)) -ForegroundColor DarkGray
}
if ($n -lt 2) { throw "need at least 2 records to say anything about movement" }

function F32 { param($o) [BitConverter]::ToSingle($b, $o) }
function U32 { param($o) [BitConverter]::ToUInt32($b, $o) }
function Mat { param($o) 0..15 | ForEach-Object { [BitConverter]::ToSingle($b, $o + $_*4) } }

$recs = New-Object System.Collections.ArrayList
$bad  = 0
for ($i = 0; $i -lt $n; $i++) {
    $o = $i * $RECLEN
    if ((U32 $o) -ne 0x314D4143) { $bad++; continue }   # 'CAM1'
    $cw = Mat ($o + 0x01C)
    $cl = Mat ($o + 0x05C)
    $mw = Mat ($o + 0x0AC)
    $ml = Mat ($o + 0x0EC)
    [void]$recs.Add([pscustomobject]@{
        Frame     = U32 ($o + 0x004)
        TimeUs    = U32 ($o + 0x008)
        CamIface  = U32 ($o + 0x00C)
        CamObj    = U32 ($o + 0x010)
        CamType   = U32 ($o + 0x014)
        CamParent = U32 ($o + 0x018)
        CamWorld  = $cw
        CamLocal  = $cl
        MovIface  = U32 ($o + 0x09C)
        MovObj    = U32 ($o + 0x0A0)
        MovType   = U32 ($o + 0x0A4)
        MovParent = U32 ($o + 0x0A8)
        MovWorld  = $mw
        MovLocal  = $ml
        EyeY      = F32 ($o + 0x12C)
        Cue       = U32 ($o + 0x130)
        Root      = U32 ($o + 0x134)
        Delta1    = U32 ($o + 0x138)
        Delta2    = U32 ($o + 0x13C)
        CamX = $cw[12]; CamY = $cw[13]; CamZ = $cw[14]
        MovX = $mw[12]; MovY = $mw[13]; MovZ = $mw[14]
    })
}
if ($bad) { Write-Host ("  {0} records had a bad magic and were skipped" -f $bad) -ForegroundColor Yellow }
$recs = @($recs)
if ($recs.Count -lt 2) { throw "no valid records" }

# AztNow returns 32-bit MICROSECONDS, which wraps every 2^32 us = 4,294.97 s, and
# its epoch is the game's own timer bookkeeping rather than process start -- so a
# run can begin near the top of the range and wrap partway through. The first route
# log did exactly that: timestamps ran 4,285s then restarted at 3.5s, which made one
# segment report a duration of MINUS 4,290 seconds. Unwrap into a monotonic
# timeline before anything uses a duration.
$WRAP = [double]4294967296
$epoch = [double]$recs[0].TimeUs
$carry = [double]0
$wraps = 0
for ($i = 0; $i -lt $recs.Count; $i++) {
    if ($i -gt 0 -and [double]$recs[$i].TimeUs -lt [double]$recs[$i-1].TimeUs) {
        # A backwards step of nearly the full range is the counter wrapping; a small
        # one would be something else entirely and is left alone rather than hidden.
        if (([double]$recs[$i-1].TimeUs - [double]$recs[$i].TimeUs) -gt ($WRAP / 2)) {
            $carry += $WRAP; $wraps++
        }
    }
    $recs[$i] | Add-Member -NotePropertyName T -NotePropertyValue `
        ((([double]$recs[$i].TimeUs + $carry) - $epoch) / 1e6) -Force
}
if ($wraps) { Write-Host ("  clock wrapped {0}x (32-bit us counter); timeline unwrapped" -f $wraps) -ForegroundColor DarkGray }
Write-Host ("  span {0:N2}s  ({1:N1} records/s average)" -f $recs[-1].T, ($recs.Count / [Math]::Max(0.001, $recs[-1].T)))

# The log opens before the scene exists, so the first records hold identity
# matrices. Analysing those would drag every span and average toward zero.
$firstLive = 0
for ($i = 0; $i -lt $recs.Count; $i++) {
    $m = $recs[$i].CamWorld
    if ($recs[$i].CamObj -ne 0 -and -not ($m[0] -eq 1 -and $m[12] -eq 0 -and $m[14] -eq 0)) { $firstLive = $i; break }
}
if ($firstLive -gt 0) {
    Write-Host ("  skipping the first {0} record(s): camera still identity (pre-scene)" -f $firstLive) -ForegroundColor DarkGray
    $recs = $recs[$firstLive..($recs.Count-1)]
}

# ---- 1. identity -------------------------------------------------------------
Write-Host "`n--- frame objects ---------------------------------------------------"
$r0 = $recs[0]

# The type tag is a RELOCATED pointer, so it cannot be compared against the linear
# 0x147EDC from the notes directly -- the first run read 0x338EDC and looked wrong.
# The stub logs the obj2 delta precisely so the arithmetic can be closed here: a
# tag that is exactly 0x147EDC + delta IS the frame class, proven rather than
# assumed. 0x147EDC is an obj2 address (obj2 is based at 0x140000).
$FRAME_TYPE_LIN = 0x147EDC
$d2 = $r0.Delta2
$expectTag = [uint32](($FRAME_TYPE_LIN + $d2) -band 0xFFFFFFFF)
Write-Host ("  load deltas: obj1 (esi) 0x{0:X8}   obj2 (edi) 0x{1:X8}" -f $r0.Delta1, $d2)
Write-Host ("  frame class tag expected at 0x147EDC+delta = 0x{0:X8}" -f $expectTag)
foreach ($k in @('Cam','Mov')) {
    $lbl = if ($k -eq 'Cam') { "[0x152144] viewport camera" } else { "[0x162DE4] movement frame " }
    $ifc = $r0."${k}Iface"; $obj = $r0."${k}Obj"
    $typ = $r0."${k}Type";  $par = $r0."${k}Parent"
    if ($obj -eq 0) {
        Write-Host ("  {0}  handle 0x{1:X8} -> DID NOT RESOLVE" -f $lbl, $ifc) -ForegroundColor Red
        continue
    }
    if ($typ -eq $expectTag) {
        $tag = "type 0x{0:X8} == 0x147EDC+delta -- CONFIRMED a Reality Lab frame" -f $typ
        $col = 'Green'
    } else {
        $tag = "type 0x{0:X8} != 0x147EDC+delta (0x{1:X8}) -- NOT a frame" -f $typ, $expectTag
        $col = 'Yellow'
    }
    Write-Host ("  {0}  handle 0x{1:X8} -> obj 0x{2:X8}  parent 0x{3:X8}" -f $lbl, $ifc, $obj, $par)
    Write-Host ("      {0}" -f $tag) -ForegroundColor $col
}
Write-Host ("  RL root sentinel [0x147ED8] holds 0x{0:X8}" -f $r0.Root)

# How the two relate. This is question 2, and it is decided by pointers, not by
# eyeballing whether the numbers look similar.
Write-Host "`n--- relationship ---------------------------------------------------"
if ($r0.CamObj -ne 0 -and $r0.CamObj -eq $r0.MovObj) {
    Write-Host "  SAME OBJECT: the viewport camera IS the frame the movement code drives." -ForegroundColor Green
} elseif ($r0.CamParent -ne 0 -and $r0.CamParent -eq $r0.MovObj) {
    Write-Host "  CHILD: the camera is a child of the movement frame." -ForegroundColor Green
    Write-Host "         The camera's LOCAL matrix is then its offset//pitch within the player frame."
} elseif ($r0.MovParent -ne 0 -and $r0.MovParent -eq $r0.CamObj) {
    Write-Host "  CHILD: the movement frame is a child of the viewport camera." -ForegroundColor Green
} else {
    Write-Host "  DISTINCT and not directly related -- compare the parent chains before concluding." -ForegroundColor Yellow
}
$unstable = @($recs | Where-Object { $_.CamObj -ne $r0.CamObj -or $_.MovObj -ne $r0.MovObj })
if ($unstable.Count) {
    Write-Host ("  NOTE: the object pointers CHANGE during the run ({0} records differ) -- frames are" -f $unstable.Count) -ForegroundColor Yellow
    Write-Host  "        recreated, most likely on a room change. Group by object before analysing."
}

# ---- 2. does it track movement? ---------------------------------------------
# A camera transform must move when the player walks. Report the span and the
# largest per-frame step: a span of zero means this is not the live transform,
# and an implausibly large step means records are being torn.
Write-Host "`n--- motion ---------------------------------------------------------"
function Span { param($vals) ($vals | Measure-Object -Maximum -Minimum) }
foreach ($k in @('Cam','Mov')) {
    $xs = $recs | ForEach-Object { $_."${k}X" }
    $ys = $recs | ForEach-Object { $_."${k}Y" }
    $zs = $recs | ForEach-Object { $_."${k}Z" }
    $sx = Span $xs; $sy = Span $ys; $sz = Span $zs
    $rx = $sx.Maximum - $sx.Minimum; $ry = $sy.Maximum - $sy.Minimum; $rz = $sz.Maximum - $sz.Minimum
    $step = 0.0
    for ($i = 1; $i -lt $recs.Count; $i++) {
        $dx = $recs[$i]."${k}X" - $recs[$i-1]."${k}X"
        $dz = $recs[$i]."${k}Z" - $recs[$i-1]."${k}Z"
        $d = [Math]::Sqrt($dx*$dx + $dz*$dz)
        if ($d -gt $step) { $step = $d }
    }
    $verdict = if (($rx + $rz) -gt 1e-3) { 'TRACKS MOVEMENT' } else { 'STATIC -- did not move' }
    Write-Host ("  {0} world translation: X span {1,10:N3}  Y span {2,10:N3}  Z span {3,10:N3}   {4}" -f `
                $k, $rx, $ry, $rz, $verdict)
    Write-Host ("       range X [{0,10:N2} .. {1,10:N2}]  Y [{2,8:N2} .. {3,8:N2}]  Z [{4,10:N2} .. {5,10:N2}]  max XZ step/frame {6:N3}" -f `
                $sx.Minimum, $sx.Maximum, $sy.Minimum, $sy.Maximum, $sz.Minimum, $sz.Maximum, $step)
}
$eye = Span ($recs | ForEach-Object { $_.EyeY })
Write-Host ("  cached eye Y [0x162DC0]: {0:N3} .. {1:N3}" -f $eye.Minimum, $eye.Maximum)
Write-Host ("  music cue [0x152AD0]: {0}" -f (($recs | ForEach-Object { $_.Cue } | Select-Object -Unique) -join ', '))

# ---- 3. is the rotation block a real basis? ---------------------------------
# The strongest available self-check. If rows 0..2 of the 4x4 are unit length and
# mutually perpendicular across the whole run, the block genuinely is a rotation
# and the offsets were read correctly -- an accident would not stay orthonormal.
Write-Host "`n--- rotation basis (orthonormality check) --------------------------"
foreach ($k in @('Cam','Mov')) {
    foreach ($space in @('World','Local')) {
        $worstU = 0.0; $worstO = 0.0; $seen = 0
        foreach ($r in $recs) {
            $m = $r."${k}${space}"
            if ($r."${k}Obj" -eq 0) { continue }
            $seen++
            $rows3 = @(
                @($m[0], $m[1], $m[2]),
                @($m[4], $m[5], $m[6]),
                @($m[8], $m[9], $m[10])
            )
            foreach ($v in $rows3) {
                $len = [Math]::Sqrt($v[0]*$v[0] + $v[1]*$v[1] + $v[2]*$v[2])
                $e = [Math]::Abs($len - 1.0); if ($e -gt $worstU) { $worstU = $e }
            }
            foreach ($p in @(@(0,1), @(0,2), @(1,2))) {
                $a = $rows3[$p[0]]; $c = $rows3[$p[1]]
                $d = [Math]::Abs($a[0]*$c[0] + $a[1]*$c[1] + $a[2]*$c[2])
                if ($d -gt $worstO) { $worstO = $d }
            }
        }
        if ($seen -eq 0) { continue }
        $ok = ($worstU -lt 0.01 -and $worstO -lt 0.01)
        $msg = if ($ok) { 'ORTHONORMAL -- this is a rotation matrix' } else { 'NOT orthonormal (scaled, or the offset is wrong)' }
        $col = if ($ok) { 'Green' } else { 'Yellow' }
        Write-Host ("  {0} {1,-5}: worst |len-1| {2:E2}   worst dot {3:E2}   {4}" -f $k, $space, $worstU, $worstO, $msg) `
                   -ForegroundColor $col
    }
}

# Yaw and pitch recovered from the basis. Row 2 of the matrix is the forward
# vector, so the heading is atan2 of its X and Z and the elevation is asin of its
# Y -- there is nowhere else a look direction could come from.
$yaws   = New-Object 'double[]' $recs.Count
$pitchs = New-Object 'double[]' $recs.Count
for ($i = 0; $i -lt $recs.Count; $i++) {
    $m = $recs[$i].CamWorld
    $yaws[$i] = [Math]::Atan2([double]$m[8], [double]$m[10]) * 180.0 / [Math]::PI
    $fy = [double]$m[9]
    if ($fy -gt 1.0) { $fy = 1.0 }; if ($fy -lt -1.0) { $fy = -1.0 }
    $pitchs[$i] = [Math]::Asin($fy) * 180.0 / [Math]::PI
}
$ys2 = Span $yaws; $ps2 = Span $pitchs
Write-Host ("`n--- look direction (from the camera world basis) --------------------")
Write-Host ("  yaw  : {0,8:N2}deg .. {1,8:N2}deg   span {2,7:N2}deg" -f $ys2.Minimum, $ys2.Maximum, ($ys2.Maximum-$ys2.Minimum))
Write-Host ("  pitch: {0,8:N2}deg .. {1,8:N2}deg   span {2,7:N2}deg   {3}" -f `
            $ps2.Minimum, $ps2.Maximum, ($ps2.Maximum-$ps2.Minimum),
            $(if (($ps2.Maximum - $ps2.Minimum) -gt 1.0) { 'PITCH IS PRESENT in the camera world matrix' }
              else { 'pitch flat -- either it was not used, or it lives elsewhere' }))

# ---- 5. route segmentation ---------------------------------------------------
# The route is walked as distinct actions (stand / walk / turn / strafe / look),
# so classify each frame by what actually changed and collapse the runs. This is
# what turns the log from "the numbers move" into "the numbers move WHEN AND HOW
# the player moved", which is the actual claim §14 has to support.
Write-Host "`n--- what the camera did, segment by segment ------------------------"
$acts = New-Object 'string[]' $recs.Count
$acts[0] = 'start'
for ($i = 1; $i -lt $recs.Count; $i++) {
    $dx = $recs[$i].CamX - $recs[$i-1].CamX
    $dz = $recs[$i].CamZ - $recs[$i-1].CamZ
    $dy = $recs[$i].CamY - $recs[$i-1].CamY
    $sp = [Math]::Sqrt($dx*$dx + $dz*$dz)
    $dyaw = $yaws[$i] - $yaws[$i-1]
    while ($dyaw -gt 180) { $dyaw -= 360 }; while ($dyaw -lt -180) { $dyaw += 360 }
    $dyaw = [Math]::Abs($dyaw)
    $dpit = [Math]::Abs($pitchs[$i] - $pitchs[$i-1])
    # A room change teleports the camera; at 24 fps a real step is a few units.
    if ($sp -gt 60 -or [Math]::Abs($dy) -gt 40 -or $recs[$i].CamObj -ne $recs[$i-1].CamObj) {
        $acts[$i] = 'TELEPORT/room change'
    } elseif ($sp -gt 0.05 -and $dyaw -gt 0.2) { $acts[$i] = 'move + turn' }
    elseif ($sp -gt 0.05)                      { $acts[$i] = 'move' }
    elseif ($dyaw -gt 0.2)                     { $acts[$i] = 'turn' }
    elseif ($dpit -gt 0.2)                     { $acts[$i] = 'look up/down' }
    else                                       { $acts[$i] = 'still' }
}
$i = 0
while ($i -lt $recs.Count) {
    $j = $i
    while ($j + 1 -lt $recs.Count -and $acts[$j+1] -eq $acts[$i]) { $j++ }
    $t0 = $recs[$i].T; $t1 = $recs[$j].T
    $dur = $t1 - $t0
    # Runs shorter than a third of a second are input jitter between real actions.
    if ($dur -ge 0.30 -or ($j - $i) -ge 8) {
        $dist = [Math]::Sqrt(
            [Math]::Pow($recs[$j].CamX - $recs[$i].CamX, 2) +
            [Math]::Pow($recs[$j].CamZ - $recs[$i].CamZ, 2))
        $dyawTot = $yaws[$j] - $yaws[$i]
        while ($dyawTot -gt 180) { $dyawTot -= 360 }; while ($dyawTot -lt -180) { $dyawTot += 360 }
        Write-Host ("  t {0,7:N2}s +{1,5:N2}s  {2,-20}  moved {3,8:N2}  turned {4,7:N1}deg  pitch {5,6:N1}deg" -f `
                    $t0, $dur, $acts[$i], $dist, $dyawTot, ($pitchs[$j] - $pitchs[$i]))
    }
    $i = $j + 1
}

# ---- 4. sampled rows / export ----------------------------------------------
if ($Rows -gt 0) {
    Write-Host "`n--- sampled rows ---------------------------------------------------"
    $stride = [Math]::Max(1, [Math]::Floor($recs.Count / $Rows))
    Write-Host ("{0,7} {1,9} {2,11} {3,9} {4,11} {5,8} {6,7} {7,11} {8,9}" -f `
                'frame','t(s)','camX','camY','camZ','yaw','pitch','movX','movZ')
    for ($i = 0; $i -lt $recs.Count; $i += $stride) {
        $r = $recs[$i]
        Write-Host ("{0,7} {1,9:N2} {2,11:N2} {3,9:N2} {4,11:N2} {5,8:N1} {6,7:N1} {7,11:N2} {8,9:N2}" -f `
                    $r.Frame, $r.T, $r.CamX, $r.CamY, $r.CamZ, $yaws[$i], $pitchs[$i], $r.MovX, $r.MovZ)
    }
}

if ($Csv) {
    $recs | Select-Object Frame, TimeUs, EyeY, Cue,
        @{n='CamObj';   e={ '0x{0:X8}' -f $_.CamObj }},
        CamX, CamY, CamZ,
        @{n='MovObj';   e={ '0x{0:X8}' -f $_.MovObj }},
        MovX, MovY, MovZ,
        @{n='CamWorld'; e={ ($_.CamWorld -join ' ') }},
        @{n='CamLocal'; e={ ($_.CamLocal -join ' ') }},
        @{n='MovWorld'; e={ ($_.MovWorld -join ' ') }} |
        Export-Csv -NoTypeInformation -Encoding utf8 $Csv
    Write-Host ("`nwrote {0}" -f $Csv)
}
