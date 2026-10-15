# Export-Rooms.ps1 -- split a multi-room capture and export one textured OBJ per room.
#
#   .\tools\Export-Rooms.ps1 -OutRoot C:\Games\RaptorMod\scratch\azrael-rooms
#   .\tools\Export-Rooms.ps1 -Index            # just list the rooms, export nothing
#
# A multi-room session writes four interleaved streams, each carrying a 32-byte 'ROOM'
# marker at the start of every capture. The Nth marker in one stream corresponds to the
# Nth marker in all the others, so the streams can be sliced in lockstep.
#
# REVISITS ARE CAPTURED, DELIBERATELY. Walking back into a room re-fires the trigger,
# because the engine genuinely rebuilds the scene -- the room's frames are new objects
# with new handles. That is not waste: comparing two visits shows what CHANGED (a
# creature killed, an item taken). But for an archive we want one model per room, so
# captures are grouped by a fingerprint of their STATIC geometry names, excluding:
#   * ZZnnnn*  creature bones (the instance number climbs globally, and a creature may
#              be present on one visit and dead on the next)
#   * XAFQn    creature roots
#   * dummy    the player's own body
# Fingerprinting on everything INCLUDING those gave 11 groups for 7 real rooms; the
# static-only fingerprint gives exactly 7.

[CmdletBinding()]
param(
    [string]$Dir = 'C:\Games\RaptorMod\game\GAME\AZRAEL',
    [string]$OutRoot,
    [switch]$Index,
    [switch]$AllVisits          # export every capture, not one per distinct room
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath

$ROOM_MAGIC = 0x4D4F4F52        # 'ROOM'
$SNOD = 0x444F4E53
$SCN_LEN = 1456

function SliceAt {
    param([byte[]]$bytes)
    # byte offsets of every 'ROOM' marker, scanned on 4-byte alignment
    $offs = New-Object System.Collections.ArrayList
    for ($i = 0; $i -le $bytes.Length - 4; $i += 4) {
        if ($bytes[$i] -eq 0x52 -and $bytes[$i+1] -eq 0x4F -and $bytes[$i+2] -eq 0x4F -and $bytes[$i+3] -eq 0x4D) {
            [void]$offs.Add($i)
        }
    }
    $offs
}

$streams = @{}
foreach ($s in @(@{k='scn';f='AZTSCN.LOG'}, @{k='geo';f='AZTGEO.BIN'},
                 @{k='tex';f='AZTTEX.BIN'}, @{k='ani';f='AZTANI.BIN'})) {
    $p = Join-Path $Dir $s.f
    if (-not (Test-Path $p)) { Write-Host ("missing {0} -- skipped" -f $s.f) -ForegroundColor Yellow; continue }
    $bytes = [IO.File]::ReadAllBytes($p)
    $streams[$s.k] = @{ Name = $s.f; Bytes = $bytes; Marks = (SliceAt $bytes) }
    Write-Host ("{0,-12} {1,12:N0} bytes, {2} ROOM markers" -f $s.f, $bytes.Length, $streams[$s.k].Marks.Count)
}
if (-not $streams.ContainsKey('scn')) { throw "AZTSCN.LOG is required (it carries the frame names)" }

$n = $streams['scn'].Marks.Count
foreach ($k in $streams.Keys) {
    if ($streams[$k].Marks.Count -ne $n) {
        Write-Host ("WARNING: {0} has {1} markers but AZTSCN.LOG has {2} -- the streams are not in lockstep, so slices may be mismatched." -f `
                    $streams[$k].Name, $streams[$k].Marks.Count, $n) -ForegroundColor Yellow
    }
}

# ---- fingerprint each capture from the scene stream -------------------------
$scn = $streams['scn']
function ReadNameAt { param($bytes, [int]$o)
    $s = ''
    for ($k = 0; $k -lt 32; $k++) { $c = $bytes[$o+$k]; if ($c -eq 0) { break }; $s += [char]$c }
    $s
}
$caps = @()
for ($i = 0; $i -lt $n; $i++) {
    $start = $scn.Marks[$i]
    $end = if ($i+1 -lt $n) { $scn.Marks[$i+1] } else { $scn.Bytes.Length }
    $seq = [BitConverter]::ToUInt32($scn.Bytes, $start+4)
    $cue = [BitConverter]::ToUInt32($scn.Bytes, $start+8)
    $static = New-Object System.Collections.ArrayList
    $nodes = 0
    $p = $start + 32
    while ($p + $SCN_LEN -le $end) {
        if ([BitConverter]::ToUInt32($scn.Bytes, $p) -ne $SNOD) { break }
        $nodes++
        $nm = ReadNameAt $scn.Bytes ($p + 0x568)
        if ($nm -and $nm -notmatch '^ZZ\d{4}' -and $nm -notmatch '^XAFQ' -and $nm -ne 'dummy') { [void]$static.Add($nm) }
        $p += $SCN_LEN
    }
    $caps += [pscustomobject]@{
        Idx = $i; Seq = $seq; Cue = $cue; Nodes = $nodes
        FP = (($static | Sort-Object -Unique) -join '|')
        Sample = (($static | Sort-Object -Unique | Select-Object -First 5) -join ', ')
    }
}

$groups = @($caps | Group-Object FP | Sort-Object { $_.Group[0].Seq })
Write-Host ""
Write-Host ("{0} captures -> {1} distinct rooms" -f $n, $groups.Count)
Write-Host "  room  visits         nodes  cue  identifying frames"
$rooms = @()
$r = 0
foreach ($g in $groups) {
    $r++
    $first = $g.Group[0]
    $rooms += [pscustomobject]@{ Room = $r; Pick = $first.Idx
        Visits = (($g.Group | ForEach-Object { $_.Seq }) -join ','); Nodes = $first.Nodes
        Cue = $first.Cue; Sample = $first.Sample; All = @($g.Group | ForEach-Object { $_.Idx }) }
    Write-Host ("  {0,4}  {1,-14} {2,5}  {3,3}  {4}" -f $r, $rooms[-1].Visits, $first.Nodes, $first.Cue, $first.Sample)
}

if ($Index -or -not $OutRoot) {
    if (-not $OutRoot) { Write-Host "`n(pass -OutRoot <dir> to export)" }
    return
}

# ---- slice and export -------------------------------------------------------
New-Item -ItemType Directory -Force $OutRoot | Out-Null
$todo = if ($AllVisits) { $caps | ForEach-Object { [pscustomobject]@{ Room = ("v{0:d2}" -f $_.Seq); Pick = $_.Idx } } }
        else { $rooms | ForEach-Object { [pscustomobject]@{ Room = ("room{0:d2}" -f $_.Room); Pick = $_.Pick } } }

foreach ($t in $todo) {
    $dest = Join-Path $OutRoot $t.Room
    New-Item -ItemType Directory -Force $dest | Out-Null
    Write-Host ""
    Write-Host ("=== {0} (capture {1}) ===" -f $t.Room, $t.Pick) -ForegroundColor Cyan

    # write the per-capture slices, skipping the 32-byte marker so the existing
    # decoders see their own record types first
    $ok = $true
    foreach ($k in @('geo','tex','ani')) {
        if (-not $streams.ContainsKey($k)) { continue }
        $st = $streams[$k]
        if ($t.Pick -ge $st.Marks.Count) { Write-Host ("  no {0} slice for this capture" -f $k) -ForegroundColor Yellow; if ($k -ne 'ani') { $ok = $false }; continue }
        $a = $st.Marks[$t.Pick] + 32
        $b = if ($t.Pick+1 -lt $st.Marks.Count) { $st.Marks[$t.Pick+1] } else { $st.Bytes.Length }
        $slice = New-Object byte[] ($b - $a)
        [Array]::Copy($st.Bytes, $a, $slice, 0, $slice.Length)
        [IO.File]::WriteAllBytes((Join-Path $dest ("_" + $k + ".bin")), $slice)
        Write-Host ("  {0}: {1:N0} bytes" -f $k, $slice.Length)
    }
    if (-not $ok) { Write-Host "  skipping export: no geometry slice" -ForegroundColor Yellow; continue }

    $texDir = Join-Path $dest 'tex'
    if (Test-Path (Join-Path $dest '_tex.bin')) {
        & (Join-Path $toolDir 'Export-LiveTextures.ps1') -Path (Join-Path $dest '_tex.bin') -OutDir $texDir *> $null
        Write-Host ("  textures: {0} PNGs" -f (Get-ChildItem $texDir -Filter '*.png' -ErrorAction SilentlyContinue).Count)
    }
    & (Join-Path $toolDir 'Export-Obj.ps1') -Path (Join-Path $dest '_geo.bin') `
        -Out (Join-Path $dest ($t.Room + '.obj')) -TexDir $texDir *> $null
    $obj = Join-Path $dest ($t.Room + '.obj')
    if (Test-Path $obj) {
        $tris = (Select-String -Path $obj -Pattern '^f ').Count
        $mats = (Select-String -Path $obj -Pattern '^usemtl ').Count
        $objs = (Select-String -Path $obj -Pattern '^o ').Count
        Write-Host ("  OBJ: {0} objects, {1} triangles, {2} usemtl" -f $objs, $tris, $mats) -ForegroundColor Green
    } else {
        Write-Host "  OBJ export produced nothing" -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host ("done -> {0}" -f $OutRoot)
