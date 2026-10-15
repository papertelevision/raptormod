# Suggest-PaintedLights.ps1 -- the PAINTED-LIGHT FINDER for Room Review (Josh, 2026-10-14: "search every room's art for
# painted light like CHAMBNEW's spotlights and drop suggested pins. You'd approve each one, so you still place every light").
#
# The 1996 texture artists painted light into the wall art (CHAMBNEW's 08-chwall: three spotlight fans a wall rising from
# the floor; Josh marked 12 and got 12 wall-wash uplights -- room-notes\CHAMBNEW.json 1-12, rooms\CHAMBNEW.json). This finds
# that painted light in every texture a room's SURFACES use (tools\PaintedLightFinder.cs: cones, windows, glows, against the
# art's own median), maps each find onto EVERY face that shows it (tiled UVs included), turns the face's normal to the room
# side, and proposes a light the way Josh approved CHAMBNEW's:
#   uplight    a fan rising up a wall: 8 out from the wall, 5 above the floor under it, aimed up and 20 degrees into the
#              wall, cone [24, 44], wash, the painted colour, power 1.6, range 120 (exactly CHAMBNEW's)
#   downlight  the same fan falling: 8 out, 5 under the ceiling over it, aimed down and 20 degrees into the wall
#   sidelight  a fan along a wall: 8 out, aimed along it and 20 degrees in
#   glow       a round bright patch: a small all-round light 15 out from the surface
#   window     a bright cell with a bar grid: just its place and its world rectangle (a light outside shining in)
# Close finds are merged (-Merge units), each gets a confidence; finds next to a light the room already has are kept as
# 'covered' (not shown as pins). Earlier answers are kept: a find at the place of an approved or dismissed one keeps its id
# and status, so running again never brings a dismissed pin back.
#
# Writes room-notes\<ROOM>.suggest.json {schema 1, room, made, suggestions[]} -- NEVER rooms\*.json (Josh places lights:
# Room Review's Approve turns a suggestion into a note, and the light is added in the next round of notes).
#
#   .\tools\Suggest-PaintedLights.ps1 -Room CHAMBNEW            (one or more rooms)
#   .\tools\Suggest-PaintedLights.ps1 -All [-IncludeHidden]     (every room in C:\Games\azrael-render; not the characters,
#                                                                camera dummies or test models the viewer groups apart)
#   -MinConfidence 0.55  -Merge 20  -WhatIf (list, write nothing)  -DebugDir <dir> (each texture's finds drawn over it)
param(
    [string[]]$Room = @(),
    [switch]$All,
    [switch]$IncludeHidden,
    [double]$MinConfidence = 0.55,
    [double]$Merge = 20,
    [switch]$WhatIf,
    [string]$DebugDir = '',
    [string]$RenderDir = 'C:\Games\azrael-render',
    [string]$NotesDir = ''
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path      # ($PSScriptRoot is empty in param defaults under -File)
if (-not $NotesDir) { $NotesDir = Join-Path $RenderDir 'room-notes' }
if (-not ('AztTool.PaintedLightFinder' -as [type])) { Add-Type -Path (Join-Path $toolDir 'PaintedLightFinder.cs') -ReferencedAssemblies System.Drawing }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$inv = [Globalization.CultureInfo]::InvariantCulture
if ($DebugDir) { New-Item -ItemType Directory -Force $DebugDir | Out-Null }

# ---- which rooms ----------------------------------------------------------------------------------------------------
$web = Join-Path $toolDir 'room-review'
$cfg = [IO.File]::ReadAllText((Join-Path $web 'rooms.json')) | ConvertFrom-Json
$hidden = @($cfg.hidden | ForEach-Object { ([string]$_).ToUpperInvariant() })
# the models that are not rooms: the viewer's own lists (viewer.js ANI_RIGS, CHAR_COPIES, OTHER_MODELS), read from it so
# the two never disagree
$notRooms = @{}
$vjs = [IO.File]::ReadAllText((Join-Path $web 'viewer.js'))
foreach ($m in [regex]::Matches($vjs, '(?s)const (?:ANI_RIGS|CHAR_COPIES|OTHER_MODELS) = \{(.*?)\};')) {
    foreach ($k in [regex]::Matches($m.Groups[1].Value, "(?:'([^']+)'|([A-Z0-9_#-]+))\s*:")) { $notRooms[($k.Groups[1].Value + $k.Groups[2].Value).ToUpperInvariant()] = 1 }
}
if ($All) {
    $Room = @(Get-ChildItem $RenderDir -Filter '*.obj' | ForEach-Object { $_.BaseName.ToUpperInvariant() } | Where-Object { -not $notRooms.ContainsKey($_) -and ($IncludeHidden -or $hidden -notcontains $_) } | Sort-Object -Unique)
}
if (-not $Room.Count) { throw 'name a -Room (or -All)' }

$portals = $null; $pp = Join-Path $RenderDir 'portals.json'
if (Test-Path $pp) { $portals = [IO.File]::ReadAllText($pp) | ConvertFrom-Json }

# never surfaces of the room: triggers and masks (the renderer's own list, LoadRoom.ps1), and doorway PICTURES of the next
# room (they carry that room's painted light, not this one's) -- the portal map's views, and the art named for two rooms
# (bap2mine, mhed2mmz, all2cori, r62r5 ...)
$SKIP_MATS = @('TRANSPARANT', 'ACTIVATION', 'BLACKCOVER')
function Test-ViewArt([string]$leaf) { $b = [IO.Path]::GetFileNameWithoutExtension($leaf).ToLowerInvariant(); return ($b -match '^\d+-r\d+r\d+') -or ($b -match '^\d+-[a-z_]*[a-z]2[a-z]{3,}') }

$texCache = @{}
function Get-TexFinds([string]$leaf, [bool]$keyed) {
    if ($texCache.ContainsKey($leaf)) { return $texCache[$leaf] }
    $p = Join-Path $RenderDir $leaf; $r = @()
    if (Test-Path -LiteralPath $p) {
        # ([NullString]: PowerShell passes $null to a string parameter as "")
        $dbg = $(if ($DebugDir) { Join-Path $DebugDir ('finds-' + $leaf) } else { [NullString]::Value })
        try { $r = @([AztTool.PaintedLightFinder]::Analyse($p, $keyed, $dbg)) } catch { Write-Host ("  ({0}: {1})" -f $leaf, $_.Exception.Message) -ForegroundColor DarkYellow }
        $r = @($r | Add-Member -NotePropertyName TexW -NotePropertyValue ([AztTool.PaintedLightFinder]::LastW) -PassThru | Add-Member -NotePropertyName TexH -NotePropertyValue ([AztTool.PaintedLightFinder]::LastH) -PassThru)
    }
    $texCache[$leaf] = $r
    return $r
}

function R2([double]$v) { [Math]::Round($v, 2) }
function R3([double]$v) { [Math]::Round($v, 3) }
function Norm($v) { $l = [Math]::Sqrt($v[0] * $v[0] + $v[1] * $v[1] + $v[2] * $v[2]); if ($l -lt 1e-9) { return $null }; return @(($v[0] / $l), ($v[1] / $l), ($v[2] / $l)) }
# the painted light's colour: the brightest third of the find's own pixels, at full brightness (CHAMBNEW's fans give
# #FFF8C1, a cream close to the #FFE6C0 Josh approved). (Dividing by the art's middle colour to get the light alone was
# tried: on CHAMBNEW's green-brown stone it turned the cream pink.)
function Get-LightHex($b) {
    $m = [Math]::Max($b.R, [Math]::Max($b.G, $b.B)); if ($m -le 0) { return '#FFE6C0' }
    $c = @($b.R, $b.G, $b.B) | ForEach-Object { [int][Math]::Round(255.0 * $_ / $m) }
    return ('#{0:X2}{1:X2}{2:X2}' -f $c[0], $c[1], $c[2])
}

$summary = @()
foreach ($R in $Room) {
    $R = $R.ToUpperInvariant(); $obj = Join-Path $RenderDir ($R + '.obj'); $mtl = Join-Path $RenderDir ($R + '.mtl')
    if (-not (Test-Path $obj) -or -not (Test-Path $mtl)) { Write-Host "$R`: no export in $RenderDir" -ForegroundColor Yellow; continue }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # materials -> texture (and keyed: the art has holes)
    $mats = @{}; $cur = $null
    foreach ($ln in [IO.File]::ReadAllLines($mtl)) {
        $t = $ln.Trim()
        if ($t -match '^newmtl\s+(.+)$') { $cur = [ordered]@{ name = $Matches[1].Trim(); map = $null; keyed = $false; d = 1.0 }; $mats[$cur.name.ToUpperInvariant()] = $cur }
        elseif ($cur -and $t -match '^map_Kd\s+(.+)$') { $cur.map = $Matches[1].Trim() }
        elseif ($cur -and $t -match '^map_d\s') { $cur.keyed = $true }
        elseif ($cur -and $t -match '^d\s+([-\d.]+)') { $cur.d = [double]::Parse($Matches[1], $inv) }
    }
    $mesh = [AztTool.PlMesh]::Load($obj)
    $views = @{}
    if ($portals -and $portals.PSObject.Properties[$R]) { foreach ($e in @($portals.$R)) { foreach ($vn in @($e.views) + @($e.parked)) { if ($vn) { $views[[string]$vn] = 1 } } } }
    # per triangle: is it a room surface we may search, and does it stop rays
    $partSkip = New-Object bool[] $mesh.Parts.Count
    for ($i = 0; $i -lt $mesh.Parts.Count; $i++) { $n = $mesh.Parts[$i]; $partSkip[$i] = ($n -match '^(?i)(zx|zy|zz|black)') -or $views.ContainsKey($n) }
    $matTex = New-Object string[] $mesh.Mats.Count; $matTrig = New-Object bool[] $mesh.Mats.Count; $matKeyed = New-Object bool[] $mesh.Mats.Count
    for ($i = 0; $i -lt $mesh.Mats.Count; $i++) {
        $m = $mats[$mesh.Mats[$i].ToUpperInvariant()]
        $matTrig[$i] = ($SKIP_MATS -contains $mesh.Mats[$i].ToUpperInvariant()) -or ($m -and -not $m.map -and $m.d -le 0)
        if ($m -and $m.map -and -not $matTrig[$i] -and -not (Test-ViewArt $m.map) -and $mesh.Mats[$i] -notmatch '(?i)view') { $matTex[$i] = $m.map; $matKeyed[$i] = $m.keyed }
    }
    $byTex = @{}
    for ($t = 0; $t -lt $mesh.Count; $t++) {
        $mi = $mesh.Mat[$t]; $pi = $mesh.Part[$t]
        $trig = ($mi -ge 0 -and $matTrig[$mi]) -or ($pi -ge 0 -and $mesh.Parts[$pi] -match '^(?i)(zx|zy)')
        $mesh.Solid[$t] = -not $trig
        if ($mi -lt 0 -or -not $matTex[$mi] -or ($pi -ge 0 -and $partSkip[$pi])) { continue }
        $leaf = $matTex[$mi]; if (-not $byTex.ContainsKey($leaf)) { $byTex[$leaf] = New-Object 'System.Collections.Generic.List[int]' }
        $byTex[$leaf].Add($t)
    }
    # (a texture a doorway picture also uses is that picture's art)
    foreach ($leaf in @($byTex.Keys)) {
        for ($t = 0; $t -lt $mesh.Count; $t++) { $pi = $mesh.Part[$t]; $mi = $mesh.Mat[$t]; if ($pi -ge 0 -and $views.ContainsKey($mesh.Parts[$pi]) -and $mi -ge 0 -and $matTex[$mi] -eq $leaf) { $byTex.Remove($leaf); break } }
    }

    # ---- every find, on every face that shows it ----
    $cands = New-Object 'System.Collections.Generic.List[object]'; $high = 0; $hiddenN = 0; $wallpaper = 0
    foreach ($leaf in @($byTex.Keys | Sort-Object)) {
        $tris = $byTex[$leaf]; $keyed = $false
        $use = New-Object bool[] $mesh.Count; foreach ($t in $tris) { $use[$t] = $true; if ($matKeyed[$mesh.Mat[$t]]) { $keyed = $true } }
        foreach ($b in @(Get-TexFinds $leaf $keyed)) {
            if ($b.Score -lt 0.3) { continue }
            $hits = $mesh.Locate($use, $b.U, $b.V)
            # (shown on more than 48 faces: a floor or wall pattern tiled over and over, never painted lamps -- and PULPIT3's
            # tiled floors made this loop take 20 minutes before this)
            if ($hits.Length -gt 48) { $wallpaper++; continue }
            foreach ($h in $hits) {
                $P = @($h.X, $h.Y, $h.Z); $N = @($h.NX, $h.NY, $h.NZ)
                $wall = [Math]::Abs($h.NY) -lt 0.7
                $nf = Norm @($h.NX, 0, $h.NZ)
                $conf = $b.Score * $(if ($h.OrientVotes -gt 0) { 1.0 } else { 0.85 })
                $kind = switch ($b.Kind) { 'window' { 'window' } 'pool' { 'glow' } default { 'cone' } }
                $fade = $null
                if ($kind -eq 'cone') {
                    $f = @(($b.FU * $h.DuX + $b.FV * $h.DvX), ($b.FU * $h.DuY + $b.FV * $h.DvY), ($b.FU * $h.DuZ + $b.FV * $h.DvZ))
                    $dn = $f[0] * $N[0] + $f[1] * $N[1] + $f[2] * $N[2]; $fade = Norm @(($f[0] - $dn * $N[0]), ($f[1] - $dn * $N[1]), ($f[2] - $dn * $N[2]))
                    if (-not $wall -or -not $fade -or -not $nf) { $kind = 'glow' }
                    elseif ($fade[1] -gt 0.6) { $kind = 'uplight' } elseif ($fade[1] -lt -0.6) { $kind = 'downlight' } else { $kind = 'sidelight'; $conf *= 0.75 }      # (a fan along a wall is rare in the art)
                }
                if ($kind -eq 'glow' -and -not $wall) { $conf *= 0.8 }        # (a bright patch on a floor or ceiling is more often the art than a pool of light)
                $light = $null; $rect = $null; $why = ''; $drop = $false      # (inside 'switch', 'continue' would only leave the switch)
                $hex = Get-LightHex $b
                $contrast = $b.Contrast.ToString('0.0', $inv)
                switch ($kind) {
                    'uplight' {
                        $L = @(($P[0] + 8 * $nf[0]), $P[1], ($P[2] + 8 * $nf[2]))
                        # the floor under it; a fan whose foot is far above any floor is the texture tiling up the wall again
                        $tf = -1; $down = $mesh.Ray($L[0], $P[1] + 1, $L[2], 0, -1, 0, 400, [ref]$tf)
                        $up = $mesh.Ray($L[0], $P[1], $L[2], 0, 1, 0, 40)
                        if ([double]::IsInfinity($down) -or ($tf -ge 0 -and [Math]::Abs($mesh.NormalY($tf)) -lt 0.6)) {
                            if (-not [double]::IsInfinity($up)) { $hiddenN++; $drop = $true; break }       # (under the floor: the wall runs on below it)
                            $conf *= 0.6; $floorY = $P[1] - 10
                        } else { $floorY = $P[1] + 1 - $down }
                        $hgt = $P[1] - $floorY
                        if ($hgt -gt 60) { $high++; $drop = $true; break }
                        if ($hgt -gt 40) { $conf *= 0.7 }
                        $L[1] = $floorY + 5
                        $dir = @((-0.342 * $nf[0]), 0.94, (-0.342 * $nf[2]))
                        $light = [ordered]@{ wash = $true; x = (R2 $L[0]); y = (R2 $L[1]); z = (R2 $L[2]); dir = @((R3 $dir[0]), (R3 $dir[1]), (R3 $dir[2])); cone = @(24, 44); color = $hex; power = 1.6; range = 120 }
                        $why = "a painted light fan rising up the wall from {0:0} above the floor ({1}x the art's level)" -f $hgt, $contrast
                    }
                    'downlight' {
                        $L = @(($P[0] + 8 * $nf[0]), $P[1], ($P[2] + 8 * $nf[2]))
                        $upD = $mesh.Ray($L[0], $P[1] - 1, $L[2], 0, 1, 0, 400)
                        if (-not [double]::IsInfinity($upD) -and $upD -lt 61) { $L[1] = $P[1] - 1 + $upD - 5 } else { $L[1] = $P[1] + 5 }
                        $dir = @((-0.342 * $nf[0]), -0.94, (-0.342 * $nf[2]))
                        $light = [ordered]@{ wash = $true; x = (R2 $L[0]); y = (R2 $L[1]); z = (R2 $L[2]); dir = @((R3 $dir[0]), (R3 $dir[1]), (R3 $dir[2])); cone = @(24, 44); color = $hex; power = 1.6; range = 120 }
                        $why = "a painted light fan falling down the wall ({0}x the art's level)" -f $contrast
                    }
                    'sidelight' {
                        $L = @(($P[0] + 8 * $nf[0]), $P[1], ($P[2] + 8 * $nf[2]))
                        $dir = Norm @((0.94 * $fade[0] - 0.342 * $nf[0]), (0.94 * $fade[1]), (0.94 * $fade[2] - 0.342 * $nf[2]))
                        $light = [ordered]@{ wash = $true; x = (R2 $L[0]); y = (R2 $L[1]); z = (R2 $L[2]); dir = @((R3 $dir[0]), (R3 $dir[1]), (R3 $dir[2])); cone = @(24, 44); color = $hex; power = 1.6; range = 120 }
                        $why = "a painted light fan running along the wall ({0}x the art's level)" -f $contrast
                    }
                    'glow' {
                        $L = @(($P[0] + 15 * $N[0]), ($P[1] + 15 * $N[1]), ($P[2] + 15 * $N[2]))
                        $light = [ordered]@{ x = (R2 $L[0]); y = (R2 $L[1]); z = (R2 $L[2]); color = $hex; power = 0.5; range = 90; flicker = 0 }
                        $why = "a round painted glow ({0}x the art's level)" -f $contrast
                    }
                    'window' {
                        $L = $P
                        $corner = { param($u, $v) $du = $u - $b.U; $dv = $v - $b.V; @((R2 ($P[0] + $du * $h.DuX + $dv * $h.DvX)), (R2 ($P[1] + $du * $h.DuY + $dv * $h.DvY)), (R2 ($P[2] + $du * $h.DuZ + $dv * $h.DvZ))) }
                        $rect = @((& $corner $b.U0 $b.V0), (& $corner $b.U1 $b.V0), (& $corner $b.U1 $b.V1), (& $corner $b.U0 $b.V1))
                        $why = "a painted window: bright panes behind a bar grid (about {0} bars across; {1}x the art's level)" -f $b.Bars, $contrast
                    }
                }
                if ($drop) { continue }
                # the light must sit in the open room: nothing between the wall and it
                if ($kind -ne 'window') {
                    $off = $(if ($kind -eq 'glow') { 15 } else { 8 })
                    if (-not [double]::IsInfinity($mesh.Ray($P[0] + $N[0] * 0.5, $P[1] + $N[1] * 0.5, $P[2] + $N[2] * 0.5, $N[0], $N[1], $N[2], $off))) { $conf *= 0.6 }
                }
                $cands.Add([pscustomobject]@{
                    kind = $kind; confidence = [Math]::Min(1.0, [double]$conf); point = @((R2 $P[0]), (R2 $P[1]), (R2 $P[2])); normal = @((R3 $N[0]), (R3 $N[1]), (R3 $N[2]))
                    part = $mesh.Parts[$mesh.Part[$h.Tri]]; material = $mesh.Mats[$mesh.Mat[$h.Tri]]; texture = $leaf
                    uv = @((R3 $b.U), (R3 $b.V)); crop = @($b.X0, $b.Y0, ($b.X1 + 1), ($b.Y1 + 1), $b.TexW, $b.TexH)
                    light = $light; rect = $rect; why = $why; L = $L
                })
            }
        }
    }

    # ---- merged: the most confident first, anything within -Merge units of it folds in ----
    $kept = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in ($cands | Sort-Object confidence -Descending)) {
        $twin = $null
        foreach ($k in $kept) { $dx = $k.point[0] - $c.point[0]; $dy = $k.point[1] - $c.point[1]; $dz = $k.point[2] - $c.point[2]; if ([Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz) -lt $Merge) { $twin = $k; break } }
        if ($twin) { $twin.faces++; continue }
        $c | Add-Member faces 1; $kept.Add($c)
    }
    # wallpaper: a texture whose finds land in more places than CHAMBNEW's twelve fans is a pattern repeated down a corridor
    # or across a floor, not lamps someone painted where they stand -- the more places, the less sure
    foreach ($g in ($kept | Group-Object texture)) { if ($g.Count -gt 12) { foreach ($c in $g.Group) { $c.confidence *= [Math]::Sqrt(12.0 / $g.Count) } } }
    $kept = @($kept | Where-Object { $_.confidence -ge $MinConfidence })

    # ---- the room's own lights: a find right next to one is already lit ('covered', kept but not a pin) ----
    $have = @()
    $rf = Join-Path $RenderDir ('rooms\' + $R + '.json')
    if (Test-Path $rf) { try { $have = @(([IO.File]::ReadAllText($rf) | ConvertFrom-Json).lights | Where-Object { $_ -and $null -ne $_.x }) } catch { } }
    # ---- earlier answers: the same place keeps its id and its status ----
    $out = Join-Path $NotesDir ($R + '.suggest.json'); $old = @(); $nextId = 1
    if (Test-Path $out) { try { $od = [IO.File]::ReadAllText($out, $utf8) | ConvertFrom-Json; $old = @($od.suggestions | Where-Object { $_ }); foreach ($o in $old) { if ([int]$o.id -ge $nextId) { $nextId = [int]$o.id + 1 } } } catch { } }
    $used = @{}; $final = @()
    foreach ($c in ($kept | Sort-Object { $_.point[1] }, { $_.point[0] })) {
        $prev = $null
        foreach ($o in $old) {
            if ($used.ContainsKey([int]$o.id) -or $o.kind -ne $c.kind) { continue }
            $dx = $o.point[0] - $c.point[0]; $dy = $o.point[1] - $c.point[1]; $dz = $o.point[2] - $c.point[2]
            if ([Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz) -lt $Merge) { $prev = $o; break }
        }
        $status = 'pending'; $id = 0; $extra = [ordered]@{}
        if ($prev) { $id = [int]$prev.id; $used[$id] = 1; if ($prev.status -in 'approved', 'dismissed') { $status = [string]$prev.status; foreach ($k in 'note', 'decided') { if ($prev.PSObject.Properties[$k]) { $extra[$k] = $prev.$k } } } }
        else { $id = $nextId; $nextId++ }
        $cover = $null
        if ($c.kind -ne 'window') { foreach ($l in $have) { $dx = [double]$l.x - $c.L[0]; $dy = [double]$l.y - $c.L[1]; $dz = [double]$l.z - $c.L[2]; if ([Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz) -lt 30) { $cover = $(if ($l.name) { [string]$l.name } else { 'a light' }); break } } }
        if ($cover -and $status -eq 'pending') { $status = 'covered' }
        $s = [ordered]@{ id = $id; kind = $c.kind; confidence = [Math]::Round($c.confidence, 2); point = $c.point; normal = $c.normal; part = $c.part; material = $c.material
                         texture = $c.texture; uv = $c.uv; crop = $c.crop; faces = $c.faces; why = $c.why; light = $c.light }
        if ($c.rect) { $s.rect = $c.rect }
        if ($cover) { $s.covered = $cover }
        $s.status = $status; foreach ($k in $extra.Keys) { $s[$k] = $extra[$k] }
        $final += [pscustomobject]$s
    }
    # (an old answer nothing matches any more stays in the file, so the decision is not lost)
    foreach ($o in $old) { if (-not $used.ContainsKey([int]$o.id) -and $o.status -in 'approved', 'dismissed') { $o | Add-Member stale $true -Force; $final += $o } }
    $final = @($final | Sort-Object { [int]$_.id })

    $counts = [ordered]@{}; foreach ($k in 'uplight', 'downlight', 'sidelight', 'glow', 'window') { $n = @($final | Where-Object { $_.kind -eq $k -and $_.status -eq 'pending' }).Count; if ($n) { $counts[$k] = $n } }
    $pending = @($final | Where-Object { $_.status -eq 'pending' }).Count; $covered = @($final | Where-Object { $_.status -eq 'covered' }).Count
    $line = '{0,-10} {1,3} pending ({2}){3}{4} -- {5} textures, {6} faces looked at, {7:N1} s' -f $R, $pending, (($counts.Keys | ForEach-Object { '{0} {1}' -f $counts[$_], $_ }) -join ', '),
        $(if ($covered) { ", $covered by existing lights" } else { '' }), ($(if ($high) { ", $high high tile repeats skipped" } else { '' }) + $(if ($wallpaper) { ", $wallpaper tiled patterns skipped" } else { '' })), $byTex.Count, $cands.Count, $sw.Elapsed.TotalSeconds
    Write-Host $line -ForegroundColor $(if ($pending) { 'Cyan' } else { 'DarkGray' })
    $summary += [pscustomobject]@{ Room = $R; Pending = $pending; Covered = $covered; Counts = $counts; Suggestions = $final }
    if (-not $WhatIf -and ($final.Count -or (Test-Path $out))) {
        $doc = [ordered]@{ schema = 1; room = $R; made = [DateTime]::UtcNow.ToString('o'); tool = 'tools\Suggest-PaintedLights.ps1'; minConfidence = $MinConfidence; suggestions = [object[]]$final }
        $tmp = $out + '.tmp'
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Depth 8), $utf8)
        if (Test-Path $out) { [IO.File]::Replace($tmp, $out, [NullString]::Value) } else { [IO.File]::Move($tmp, $out) }
    }
}
if ($Room.Count -gt 1) { Write-Host ('{0} rooms, {1} pending suggestions' -f $summary.Count, (($summary | Measure-Object Pending -Sum).Sum)) -ForegroundColor Cyan }
$summary
