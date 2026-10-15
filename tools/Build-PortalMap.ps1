# Build-PortalMap.ps1 -- which room is behind each doorway, and where it sits.
#
#   .\tools\Build-PortalMap.ps1              # writes C:\Games\RaptorMod\cache\portals.json
#   .\tools\Build-PortalMap.ps1 -Report      # and prints every portal it found
#
# WHY. A doorway in this game does not show the next room. It shows a PICTURE of it: a quad
# standing in the opening, textured with a still that was rendered once in 1996 (`r12r5` is
# "room 1 looking into room 5"). The host renderer can draw the real room there instead, but
# only if it knows which room that is and how the two rooms fit together -- and every room
# file is modelled in its own coordinates around its own origin, so nothing lines up as stored.
#
# WHAT THE GAME'S OWN DATA SAYS. Three things, all on disk, none needing the game running:
#
#   * AZONES.DAT names every zone and the trigger object that fires it. A zone called
#     "SpaRoomToMineHead" (or, in the first few rooms, just "WashRoomMineMaze") on object
#     `zxspa2R6` is the floor patch in the spa room that sends you to the mine head.
#   * Each room file ALSO holds arrival markers: `zyR06` in SPAROOM.XAF is where you stand
#     after arriving FROM room 6. Checked across the corpus: the zy marker named for the
#     destination is the nearest marker to that destination's trigger in all but a handful
#     of rooms, a median of about 30 units further into the room.
#   * ROOMS.DAT lists, per room, its name and the one .XAF the game actually loads -- which
#     is what picks MINEHEAD over the dev copies MINEHED2 and HINEAZF.
#
# Trigger and marker together give each side of a doorway its position and its direction, and
# the picture quad gives the plane where that room's stub of tunnel ends. Butting the two
# planes together, with the two ways out pointing at each other, is one rigid transform (a
# turn about the vertical axis plus a shift), and that is what is written out per portal: the
# matrix that carries the far room's geometry into this room's coordinates.
#
# The door's axis is the picture quad's own normal where there is one (it stands square in
# the opening), and the trigger-to-marker direction otherwise.
#
# WHICH QUADS ARE PICTURES. Found by position, not by name -- the names are all over the
# place (`spaview`, `entcori`, `Object14`, `gibbetdoor`). A picture is a single upright
# textured quad standing just beyond its trigger and square across the way out. A room often
# has a second one parked far below the floor; the game lifts it into the doorway when a door
# opens, so those are listed too and the renderer decides per frame which are standing in a
# doorway. A picture of a CLOSED door ("...CLOSE") is left alone: that one should stay a picture.
[CmdletBinding()]
param(
    [string]$CacheDir = 'C:\Games\RaptorMod\cache',
    [string]$GameDir  = 'C:\Games\RaptorMod\game\GAME\AZRAEL',
    [string]$Out      = '',
    [switch]$Report
)
$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $CacheDir 'portals.json' }

# ---- every small object in every room file ---------------------------------------------
# Triggers, markers and pictures are all quads (a few triggers are boxes), so anything with
# more than eight vertices is scenery and is not kept.
$files = @{}; $matTex = @{}; $boxes = @{}
foreach ($f in Get-ChildItem (Join-Path $CacheDir '*.obj')) {
    $room = $f.BaseName.ToUpper()
    $mt = @{}; $mtl = Join-Path $CacheDir ($f.BaseName + '.mtl')
    if (Test-Path $mtl) {
        $cur = $null
        foreach ($l in [IO.File]::ReadAllLines($mtl)) {
            if ($l.StartsWith('newmtl ')) { $cur = $l.Substring(7).Trim() }
            elseif ($l.StartsWith('map_Kd ') -and $cur) { $mt[$cur] = ($l.Substring(7).Trim() -replace '^\d\d-', '' -replace '\.png$', '') }
        }
    }
    $matTex[$room] = $mt
    $V = New-Object 'System.Collections.Generic.List[double[]]'; $objs = New-Object System.Collections.ArrayList; $cur = $null; $m = ''
    foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
        if ($l.Length -lt 2) { continue }
        $c0 = $l[0]; $c1 = $l[1]
        if ($c0 -eq 'v' -and $c1 -eq ' ') { $p = $l.Substring(2).Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries); $V.Add([double[]]@([double]$p[0], [double]$p[1], [double]$p[2])) }
        elseif ($c0 -eq 'o' -and $c1 -eq ' ') { $cur = [pscustomobject]@{ Name = $l.Substring(2).Trim(); Mats = (New-Object 'System.Collections.Generic.HashSet[string]'); Vi = (New-Object 'System.Collections.Generic.HashSet[int]'); Tris = 0 }; [void]$objs.Add($cur) }
        elseif ($l.StartsWith('usemtl ')) { $m = $l.Substring(7).Trim() }
        elseif ($c0 -eq 'f' -and $c1 -eq ' ' -and $cur) {
            $tk = $l.Substring(2).Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            [void]$cur.Mats.Add($m); $cur.Tris += $tk.Length - 2
            foreach ($t in $tk) { [void]$cur.Vi.Add([int]($t.Split('/')[0]) - 1) }
        }
    }
    $h = @{}; $boxOf = @{}
    foreach ($o in $objs) {
        if ($o.Vi.Count -eq 0) { continue }
        # every object's bounding box, for finding the door that stands in a doorway
        if (-not $boxOf.ContainsKey($o.Name) -and $o.Vi.Count -le 96) {
            $lo = @([double]::MaxValue, [double]::MaxValue, [double]::MaxValue); $hi = @([double]::MinValue, [double]::MinValue, [double]::MinValue)
            foreach ($vi in $o.Vi) { $q = $V[$vi]; for ($a = 0; $a -lt 3; $a++) { if ($q[$a] -lt $lo[$a]) { $lo[$a] = $q[$a] }; if ($q[$a] -gt $hi[$a]) { $hi[$a] = $q[$a] } } }
            $pp = @($o.Vi | ForEach-Object { ,$V[$_] })
            $boxOf[$o.Name] = [pscustomobject]@{ Name = $o.Name; Lo = $lo; Hi = $hi; N = $o.Vi.Count; Mats = @($o.Mats); P = $pp }
        }
        if ($o.Vi.Count -gt 8 -or $h.ContainsKey($o.Name)) { continue }
        $pts = @($o.Vi | ForEach-Object { ,$V[$_] })
        $cx = 0.0; $cy = 0.0; $cz = 0.0; $y0 = [double]::MaxValue; $y1 = [double]::MinValue
        foreach ($q in $pts) { $cx += $q[0]; $cy += $q[1]; $cz += $q[2]; if ($q[1] -lt $y0) { $y0 = $q[1] }; if ($q[1] -gt $y1) { $y1 = $q[1] } }
        $n = $pts.Count
        # the normal, from the first three corners that are not in a line
        $nx = 0.0; $ny = 0.0; $nz = 0.0
        if ($n -ge 3) {
            for ($k = 2; $k -lt $n; $k++) {
                $ax = $pts[1][0] - $pts[0][0]; $ay = $pts[1][1] - $pts[0][1]; $az = $pts[1][2] - $pts[0][2]
                $bx = $pts[$k][0] - $pts[0][0]; $by = $pts[$k][1] - $pts[0][1]; $bz = $pts[$k][2] - $pts[0][2]
                $nx = $ay*$bz - $az*$by; $ny = $az*$bx - $ax*$bz; $nz = $ax*$by - $ay*$bx
                $nl = [Math]::Sqrt($nx*$nx + $ny*$ny + $nz*$nz)
                if ($nl -gt 1e-6) { $nx /= $nl; $ny /= $nl; $nz /= $nl; break }
            }
        }
        $h[$o.Name] = [pscustomobject]@{ Name = $o.Name; Mats = @($o.Mats); Tris = $o.Tris; N = $n
                                         C = @(($cx/$n), ($cy/$n), ($cz/$n)); Y0 = $y0; Y1 = $y1; Nrm = @($nx, $ny, $nz) }
    }
    $files[$room] = $h; $boxes[$room] = $boxOf
}

# ---- ROOMS.DAT: room name -> the file the game loads -----------------------------------
# A room record starts with a 60-byte name and a 60-byte file name. Found by looking for a
# known .XAF name with a clean identifier 60 bytes before it and a small zone count after.
$rb = [IO.File]::ReadAllBytes((Join-Path $GameDir 'ROOMS.DAT'))
function Read-Str([byte[]]$b, [int]$o, [int]$max) {
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $max -and ($o + $i) -lt $b.Length; $i++) {
        $c = $b[$o + $i]
        if ($c -eq 0) { return $sb.ToString() }
        if ($c -lt 32 -or $c -gt 126) { return $null }
        [void]$sb.Append([char]$c)
    }
    return $null
}
# The first rooms were named before the numbering existed; their numbers are the ones their
# neighbours' arrival markers use (ORRERY.XAF holds zyR04, zyR08 and zyR10: the Theo chamber,
# the baptistery and the tunnel). "Orrey" is a typo in the shipped zone table.
$ALIAS = @{ EntryCoord = 'R1'; WashRoom = 'R2'; MineMaze = 'R3'; TheoChamber = 'R4'; SpaRoom = 'R5'; MineHead = 'R6'; MineHeadRight = 'R6'
            WellRoom = 'R7'; Baptistery = 'R8'; Orrery = 'R9'; OrreryRoom = 'R9'; Orrey = 'R9'; Tunnel = 'R10'
            ChapterHouse = 'R18'; Vestry = 'R17'; Cloister = 'R16' }
function Get-Code([string]$n) {
    if ($ALIAS.ContainsKey($n)) { $n = $ALIAS[$n] }
    if ($n -match '^([A-Za-z]+)0*(\d+)([A-Za-z]?)$') { return ($Matches[1] + $Matches[2] + $Matches[3]).ToUpper() }
    return $n.ToUpper()
}
$codeFile = @{}
for ($o = 62; $o -lt $rb.Length - 62; $o++) {
    $s = Read-Str $rb $o 13
    if (-not $s -or $s.Length -lt 2 -or -not $files.ContainsKey($s.ToUpper())) { continue }
    $n = Read-Str $rb ($o - 60) 60
    if (-not $n -or $n -notmatch '^[A-Za-z][A-Za-z0-9]{1,15}$') { continue }
    $cnt = [BitConverter]::ToUInt16($rb, $o + 60)
    if ($cnt -gt 40) { continue }
    $ok = $true
    for ($k = 0; $k -lt $cnt; $k++) { $z = Read-Str $rb ($o + 62 + $k*60) 60; if (-not $z -or $z.Length -lt 2) { $ok = $false; break } }
    if (-not $ok) { continue }
    $c = Get-Code $n
    if (-not $codeFile.ContainsKey($c)) { $codeFile[$c] = $s.ToUpper() }
}

# ---- AZONES.DAT: the portal zones -------------------------------------------------------
$zb = [IO.File]::ReadAllBytes((Join-Path $GameDir 'AZONES.DAT'))
$zn = [BitConverter]::ToUInt16($zb, 0)
function Read-Zone([int]$o, [int]$max) { $s = ''; for ($i = 0; $i -lt $max; $i++) { $c = $zb[$o + $i]; if ($c -eq 0 -or $c -lt 32 -or $c -gt 126) { break }; $s += [char]$c }; $s }
$aliasNames = @($ALIAS.Keys | Sort-Object Length -Descending)
$zones = @()
for ($i = 0; $i -lt $zn; $i++) {
    $o = 2 + $i*75; $z = Read-Zone $o 60; $ob = Read-Zone ($o + 60) 12
    if (-not $z -or -not $ob -or $z -match 'AZ$') { continue }
    $A = $null; $B = $null
    if ($z -match '^(.+?)To(.+)$') { $A = $Matches[1]; $B = $Matches[2] }
    else { foreach ($na in $aliasNames) { if ($z.StartsWith($na) -and $ALIAS.ContainsKey($z.Substring($na.Length))) { $A = $na; $B = $z.Substring($na.Length); break } } }
    if (-not $A) { continue }
    $zones += [pscustomobject]@{ Zone = $z; Zx = $ob; A = (Get-Code $A); B = (Get-Code $B) }
}
$byPair = @{}; foreach ($z in $zones) { $byPair["$($z.A)>$($z.B)"] = $z }

# ---- one side of a doorway: the trigger, the marker, the axis, the pictures --------------
function Get-Side([string]$file, [string]$zxName, [string]$otherCode) {
    $h = $files[$file]; if (-not $h -or -not $h.ContainsKey($zxName)) { return $null }
    $X = $h[$zxName].C
    $zy = $null
    foreach ($o in $h.Values) { if ($o.Name -match '^zy(.+)$' -and (Get-Code $Matches[1]) -eq $otherCode) { $zy = $o; break } }
    if (-not $zy) { return $null }
    $Y = $zy.C
    $ex = $X[0] - $Y[0]; $ez = $X[2] - $Y[2]; $el = [Math]::Sqrt($ex*$ex + $ez*$ez)
    if ($el -lt 1e-3) { return $null }          # marker on top of its trigger (a lift): no direction to take
    $ex /= $el; $ez /= $el
    $views = @()
    foreach ($o in $h.Values) {
        if ($o.N -ne 4 -or $o.Name -match '^[zZ][xXyY]') { continue }
        if ([Math]::Abs($o.Nrm[1]) -gt 0.2 -or ($o.Y1 - $o.Y0) -lt 30) { continue }      # upright, door-sized
        $tex = $null; $mname = ''
        foreach ($mm in $o.Mats) { if ($matTex[$file].ContainsKey($mm)) { $tex = $matTex[$file][$mm]; $mname = $mm } }
        if (-not $tex) { continue }
        # A picture of a SHUT door stays a picture (`sa_door` is the sanctuary's door painted
        # on a quad, "...CLOSE" the same for a portcullis), and a plain black blanking quad is
        # there to hide the way, not to show it.
        if ($mname -match 'CLOSE|CLOS$|DOOR|^BLACK' -or $tex -match '_$|door|^n_black') { continue }
        $dx = $o.C[0] - $X[0]; $dz = $o.C[2] - $X[2]
        $along = $dx*$ex + $dz*$ez; $side = -$dx*$ez + $dz*$ex
        if ($along -lt 5 -or $along -gt 220 -or [Math]::Abs($side) -gt 45) { continue }
        # square across the way out: its normal within about 35 degrees of the door axis
        $nh = [Math]::Sqrt($o.Nrm[0]*$o.Nrm[0] + $o.Nrm[2]*$o.Nrm[2]); if ($nh -lt 1e-3) { continue }
        $cosA = [Math]::Abs(($o.Nrm[0]*$ex + $o.Nrm[2]*$ez) / $nh)
        if ($cosA -lt 0.8 -and $el -lt 90) { continue }
        $views += [pscustomobject]@{ Name = $o.Name; Mat = $mname; Tex = $tex; Along = $along; Standing = ($o.Y0 -lt ($X[1] + 45) -and $o.Y1 -gt ($X[1] + 25)); O = $o }
    }
    $views = @($views | Sort-Object Along)
    # THE AXIS: the nearest picture's normal, pointed away from the room; the marker-to-trigger
    # direction when the doorway has no picture.
    $ax = $ex; $az = $ez
    if ($views.Count) {
        $o = $views[0].O; $nh = [Math]::Sqrt($o.Nrm[0]*$o.Nrm[0] + $o.Nrm[2]*$o.Nrm[2])
        $ax = $o.Nrm[0] / $nh; $az = $o.Nrm[2] / $nh
        if (($ax*($o.C[0] - $X[0]) + $az*($o.C[2] - $X[2])) -lt 0) { $ax = -$ax; $az = -$az }
    }
    $s = ($X[0] - $Y[0])*$ax + ($X[2] - $Y[2])*$az
    if ($s -lt 5 -or $s -gt 150) { $s = 30.0 }
    # WHERE THIS ROOM'S HALF OF THE TUNNEL ENDS: the plane its picture stands in, as a distance
    # out from the trigger along the axis. The picture standing by default if there is one,
    # else the parked one; a doorway with no picture gets the usual figure.
    $pv = @($views | Where-Object { $_.Standing }) | Select-Object -First 1
    if (-not $pv -and $views.Count) { $pv = $views[0] }
    $reach = $(if ($pv) { ($pv.O.C[0] - $X[0])*$ax + ($pv.O.C[2] - $X[2])*$az } else { 58.0 })
    return [pscustomobject]@{ File = $file; Zx = $zxName; Zy = $zy.Name; X = $X; Y = $Y; Ax = $ax; Az = $az; S = $s; Views = $views
                              Reach = $reach; PvName = $(if ($pv) { $pv.Name } else { $null }); PvParked = [bool]($pv -and -not $pv.Standing)
                              # the middle of the tunnel mouth: the picture's own centre where there
                              # is one (the two mouths are then concentric), floor level at the trigger
                              Q = $(if ($pv) { @($pv.O.C[0], $X[1], $pv.O.C[2]) } else { @(($X[0] + $ax*$reach), $X[1], ($X[2] + $az*$reach)) }) }
}

# ---- THE DOOR AT THE FAR END -------------------------------------------------------------
# A doorway is two doors with a short tunnel between them: this room's, which is real geometry
# and is posed live, and the far room's, which you see at the end of the tunnel. That is why
# most doorways have TWO pictures: the one standing by default shows the far door shut
# (`all2cori` is a plain shut door, used by four rooms), and the parked one, which the game
# lifts into place when the far door has been opened, shows the room beyond it.
#
# The neighbour is drawn from its file, where every door is shut. So when the game is showing
# the "open" picture, the far room's own door has to be taken out of the way -- and this
# finds it: an upright slab standing ACROSS the far room's way out, between its trigger and
# its interior, thin along the tunnel, no bigger than a door, reaching from the floor to
# above eye height. Tunnel walls run along the axis and floors lie flat, so neither qualifies.
function Get-FarDoors($side) {
    $res = @()
    foreach ($o in $boxes[$side.File].Values) {
        if ($o.Name -match '^[zZ][xXyY]' -or ($side.Views | Where-Object { $_.Name -ceq $o.Name })) { continue }
        $tex = $false; foreach ($mm in $o.Mats) { if ($matTex[$side.File].ContainsKey($mm)) { $tex = $true } }
        if (-not $tex) { continue }
        $u0 = [double]::MaxValue; $u1 = [double]::MinValue; $v0 = [double]::MaxValue; $v1 = [double]::MinValue
        foreach ($q in $o.P) {
            $dx = $q[0] - $side.X[0]; $dz = $q[2] - $side.X[2]
            $u = -($dx*$side.Ax + $dz*$side.Az); $v = -$dx*$side.Az + $dz*$side.Ax       # u: into the room
            if ($u -lt $u0) { $u0 = $u }; if ($u -gt $u1) { $u1 = $u }; if ($v -lt $v0) { $v0 = $v }; if ($v -gt $v1) { $v1 = $v }
        }
        $floor = $side.X[1]
        if ($u0 -lt -30 -or $u1 -gt 260) { continue }                          # in the tunnel, not out in the room
        if (($u1 - $u0) -gt 25 -or ($v1 - $v0) -lt 20 -or ($v1 - $v0) -gt 170) { continue }   # a slab across it, door-sized
        if ($v0 -gt 30 -or $v1 -lt -30) { continue }                           # that blocks the middle of it
        if ($o.Lo[1] -gt ($floor + 25) -or $o.Hi[1] -lt ($floor + 45) -or ($o.Hi[1] - $o.Lo[1]) -gt 220) { continue }
        $res += [pscustomobject]@{ Name = $o.Name; U = [int](($u0 + $u1) / 2); W = [int]($v1 - $v0); Mat = (@($o.Mats) -join ',') }
    }
    # ONLY WHAT IS NAMED AS A DOOR, and only the first of them. The slab test alone also finds
    # the wall a door is set in (`wall10` beside `doorcor01`), a desk and a bookshelf; taking a
    # wall out would open a hole in the room, which is worse than leaving a door shut.
    $doors = @($res | Where-Object { $_.Name -match 'door|gate' -and $_.Name -notmatch 'wall' -and $_.U -le 230 } | Sort-Object U)
    if (-not $doors.Count) { return @() }
    return @($doors | Where-Object { $_.U -le ($doors[0].U + 40) })
}

$map = [ordered]@{}; $rows = @(); $nNoRev = 0; $nNoSide = 0; $nMismatch = 0
foreach ($z in $zones) {
    $rev = $byPair["$($z.B)>$($z.A)"]
    $filesA = @($files.Keys | Where-Object { $files[$_].ContainsKey($z.Zx) } | Sort-Object)
    if (-not $rev) { $nNoRev++; continue }
    # the far room's file: the one ROOMS.DAT loads if it holds the return trigger, else any that does
    $cand = @($files.Keys | Where-Object { $files[$_].ContainsKey($rev.Zx) } | Sort-Object)
    $fb = $(if ($codeFile[$z.B] -and ($cand -contains $codeFile[$z.B])) { $codeFile[$z.B] } elseif ($cand.Count) { $cand[0] } else { $null })
    if (-not $fb) { $nNoSide++; continue }
    $sb = Get-Side $fb $rev.Zx $z.A
    if (-not $sb) { $nNoSide++; continue }
    $farDoors = @(Get-FarDoors $sb)
    foreach ($fa in $filesA) {
        $sa = Get-Side $fa $z.Zx $z.B
        if (-not $sa) { $nNoSide++; continue }
        # B's way out points INTO A:  R(axis_B) = -axis_A,  a turn about the vertical.
        $phiB = [Math]::Atan2($sb.Ax, $sb.Az); $phiA = [Math]::Atan2(-$sa.Ax, -$sa.Az)
        $d = $phiA - $phiB
        while ($d -gt [Math]::PI) { $d -= 2*[Math]::PI }; while ($d -le -[Math]::PI) { $d += 2*[Math]::PI }
        # MEASURED IN THE GAME (2026-10-05, eight transitions between rooms 1, 2 and 5): the
        # player's heading does not change AT ALL through a doorway, where the picture quads
        # said 6 and 11 degrees. The rooms share one orientation and the tunnels simply are
        # not perfectly square to each other; turning the far room to make them so bent
        # every tunnel at its join. A small turn is therefore no turn. A large one (a
        # stairwell at 99 degrees) is kept: nothing has measured those yet, and two exits
        # facing the same way cannot be right either -- watch their PORTAL CHECK lines.
        if ([Math]::Abs($d) -le (30 * [Math]::PI / 180)) { $d = 0.0 }
        $cs = [Math]::Cos($d); $sn = [Math]::Sin($d)
        $s = ($sa.S + $sb.S) / 2
        # THE TWO HALVES OF THE TUNNEL, END TO END. Each room models its own door and a
        # stub of tunnel beyond it, ending at the plane its picture stands in; the pictures
        # themselves show a tunnel with the far door at the end of it. So the far room is
        # placed with ITS picture plane on THIS room's picture plane:
        #       p_A = R(p_B - Q_B) + Q_A        floors level at the two triggers
        # (Tried first, and rejected: placing the far room so that this room's trigger sits on
        # the far room's arrival marker. That is seamless at the instant of the teleport --
        # which is a load screen anyway -- but folds the two tunnels on top of each other, so a
        # stairwell's facing wall stood right in the doorway where the picture shows a passage.)
        $tx = $sa.Q[0]; $ty = $sa.Q[1]; $tz = $sa.Q[2]
        $bx = $sb.Q[0]; $by = $sb.Q[1]; $bz = $sb.Q[2]
        # row-vector 4x4:  x' = x*cs + z*sn,  z' = -x*sn + z*cs
        $m = @($cs, 0, (-$sn), 0,   0, 1, 0, 0,   $sn, 0, $cs, 0,
               ($tx - ($bx*$cs + $bz*$sn)), ($ty - $by), ($tz - (-$bx*$sn + $bz*$cs)), 1)
        # THE FAR TUNNEL'S MOUTH, in this room's coordinates: the far room's own picture quad,
        # corners in order round its centre. The doorway is drawn only where this overlaps
        # this room's picture quad -- see Raster.RestrictPortal.
        $farQuad = @()
        if ($sb.PvName -and $boxes[$sb.File].ContainsKey($sb.PvName)) {
            $fo = $boxes[$sb.File][$sb.PvName]; $fn = $files[$sb.File][$sb.PvName].Nrm; $fc = $files[$sb.File][$sb.PvName].C
            # a far room with only a PARKED picture: that quad is hundreds of units under the
            # floor until the game lifts it, so stand it on the floor at its trigger here
            $lift = 0.0
            $fy0 = ($fo.P | ForEach-Object { $_[1] } | Measure-Object -Minimum).Minimum
            if ($sb.PvParked) { $lift = $sb.X[1] - $fy0 }
            if ($fo.P.Count -eq 4) {
                $ord = @($fo.P | Sort-Object { [Math]::Atan2(($_[1] - $fc[1]), (($_[0] - $fc[0])*$fn[2] - ($_[2] - $fc[2])*$fn[0])) })
                foreach ($q in $ord) {
                    $farQuad += [Math]::Round($q[0]*$m[0] + $q[2]*$m[8] + $m[12], 2)
                    $farQuad += [Math]::Round($q[1] + $lift + $m[13], 2)
                    $farQuad += [Math]::Round($q[0]*$m[2] + $q[2]*$m[10] + $m[14], 2)
                }
            }
        }
        # DO THE TWO MOUTHS ACTUALLY MEET? Both quads, measured across and up in this room's
        # picture plane. If they barely overlap, something about this doorway is not what the
        # rest are (KITCHEN's "picture" towards the tree maze is a piece of mill machinery),
        # and a doorway that opens on nothing is worse than the still: it keeps its picture.
        $viewNames = @($sa.Views | ForEach-Object { $_.Name })
        if ($farQuad.Count -eq 12 -and $sa.PvName -and $boxes[$fa].ContainsKey($sa.PvName)) {
            $tgx = $sa.Az; $tgz = -$sa.Ax
            $a0 = 1e9; $a1 = -1e9; $ay0 = 1e9; $ay1 = -1e9; $b0 = 1e9; $b1 = -1e9; $by0 = 1e9; $by1 = -1e9
            foreach ($q in $boxes[$fa][$sa.PvName].P) { $hh = ($q[0] - $sa.Q[0])*$tgx + ($q[2] - $sa.Q[2])*$tgz; if ($hh -lt $a0) { $a0 = $hh }; if ($hh -gt $a1) { $a1 = $hh }; if ($q[1] -lt $ay0) { $ay0 = $q[1] }; if ($q[1] -gt $ay1) { $ay1 = $q[1] } }
            # a parked near picture is judged where it will stand
            if ($sa.PvParked) { $sh = $sa.X[1] - $ay0; $ay0 += $sh; $ay1 += $sh }
            for ($k = 0; $k -lt 4; $k++) { $hh = ($farQuad[$k*3] - $sa.Q[0])*$tgx + ($farQuad[$k*3+2] - $sa.Q[2])*$tgz; $yy = $farQuad[$k*3+1]; if ($hh -lt $b0) { $b0 = $hh }; if ($hh -gt $b1) { $b1 = $hh }; if ($yy -lt $by0) { $by0 = $yy }; if ($yy -gt $by1) { $by1 = $yy } }
            $ow = [Math]::Min($a1, $b1) - [Math]::Max($a0, $b0); $oh = [Math]::Min($ay1, $by1) - [Math]::Max($ay0, $by0)
            $small = [Math]::Min(($a1 - $a0)*($ay1 - $ay0), ($b1 - $b0)*($by1 - $by0))
            if ($ow -le 0 -or $oh -le 0 -or $small -le 0 -or ($ow*$oh / $small) -lt 0.4) { $viewNames = @(); $nMismatch++ }
        }
        if (-not $map.Contains($fa)) { $map[$fa] = New-Object System.Collections.ArrayList }
        [void]$map[$fa].Add([ordered]@{
            zone = $z.Zone; zx = $z.Zx; to = $fb; toCode = $z.B
            m = @($m | ForEach-Object { [Math]::Round([double]$_, 5) })
            door = @($sa.X | ForEach-Object { [Math]::Round([double]$_, 2) }); axis = @([Math]::Round($sa.Ax, 5), [Math]::Round($sa.Az, 5))
            # the plane the far room starts at, and the far room's own pictures of THIS room,
            # which stand in that plane facing the other way and must not be drawn
            plane = @([Math]::Round($sa.Q[0], 2), [Math]::Round($sa.Q[2], 2))
            farViews = @($sb.Views | ForEach-Object { $_.Name })
            farQuad = $farQuad
            views = $viewNames
            # which of those is parked below the floor until the far door opens
            parked = @($sa.Views | Where-Object { -not $_.Standing } | ForEach-Object { $_.Name })
            farDoors = @($farDoors | ForEach-Object { $_.Name })
            # where the game stands you in the far room, in the far room's own coordinates
            land = @($sb.Y | ForEach-Object { [Math]::Round([double]$_, 2) })
        })
        $rows += [pscustomobject]@{ From = $fa; Zone = $z.Zone; To = $fb; Turn = [int]($d * 180 / [Math]::PI); S = [int]($sa.Reach + $sb.Reach)
                                    FarDoors = (@($farDoors | ForEach-Object { '{0}@{1}' -f $_.Name, $_.U }) -join ' ')
                                    Views = (@($sa.Views | ForEach-Object { '{0}[{1}/{2}{3}]' -f $_.Name, $_.Mat, $_.Tex, $(if ($_.Standing) { '' } else { ' parked' }) }) -join ' ') }
    }
}
[IO.File]::WriteAllText($Out, ($map | ConvertTo-Json -Depth 6 -Compress))
$withView = @($rows | Where-Object { $_.Views }).Count - $nMismatch
Write-Host ("{0} portal zones; {1} doorways mapped across {2} room files, {3} with a picture to replace; {4} zones have no way back, {5} sides had no marker" -f `
    $zones.Count, $rows.Count, $map.Count, $withView, $nNoRev, $nNoSide)
Write-Host ("written -> {0}" -f $Out)
if ($Report) { $rows | Sort-Object From, Zone | Format-Table From, Zone, To, Turn, @{ n = 'Tunnel'; e = { $_.S } }, FarDoors, Views -AutoSize | Out-String -Width 240 | Write-Host }
