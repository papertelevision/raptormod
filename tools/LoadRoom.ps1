# LoadRoom.ps1 -- dot-source this for Import-AztRoom.
#
# ONE COPY OF THE RULES. Loading a room for the rasteriser involves half a dozen
# decisions that must agree everywhere: merging several .XAF files with rebased indices,
# resolving UVs through the faces, keying materials by FILE+name, skipping the invisible
# trigger volumes, and quantising textures into the game palette. That logic had been
# copied into three scripts, and a fix applied to one of them (the TRANSPARANT skip) did
# not reach the others -- so the live renderer and the comparison tool were drawing
# different pictures from the same room.
#
# The rules themselves are documented at the points where they bite.

# THE SLOW PATH. Builds everything from the OBJ text; kept exactly as it was, and now called
# for ONE file at a time by Get-AztUnit below, whose result is cached. Import-AztRoom itself
# is the fast composer at the end of this file.
function Import-AztRoomSlow {
    [CmdletBinding()]
    param(
        [string]$RefName,                       # a Capture-Reference json, or
        [string[]]$Rooms,                       # an explicit list of .XAF names
        # CHARACTERS: rigs that live in their own .XAF and are instanced into the room by
        # the engine. Each entry is @{ Xaf = 'EUGBLD'; Prefix = 'ZZ0001' }. The geometry is
        # loaded once PER INSTANCE and every part is named Prefix + object name, which is
        # exactly what the live scene graph calls that instance's frames (the engine's own
        # format strings are "XAFQ%d" for the container and "ZZ%04d" for the prefix). So the
        # same per-name posing that opens doors places and animates a character, and two
        # copies of one rig stay separate because their prefixes differ.
        [object[]]$Characters = @(),
        [string]$RefDir   = 'C:\Games\RaptorMod\cache\ref',
        [string]$CacheDir = 'C:\Games\RaptorMod\cache',
        [string]$TexDir   = 'C:\Games\RaptorMod\game\GAME\AZTEX',
        [string]$Palette  = 'C:\Games\RaptorMod\cache\azrael-palette.pal',
        [int]$Width = 0, [int]$Height = 0
    )
    $toolDir = $PSScriptRoot
    $cam = $null
    if ($RefName) {
        $ref = Get-Content (Join-Path $RefDir ("{0}.json" -f $RefName)) -Raw | ConvertFrom-Json
        $Rooms = @($ref.rooms)
        if ($Width -le 0)  { $Width  = [int]$ref.width }
        if ($Height -le 0) { $Height = [int]$ref.height }
        $cam = @(0..15 | ForEach-Object { [double]$ref.camera[$_] })
    }
    if (-not $Rooms -or $Rooms.Count -eq 0) { throw 'Import-AztRoom needs -RefName or -Rooms' }

    $verts = New-Object System.Collections.Generic.List[single]
    $uvs   = New-Object System.Collections.Generic.List[single]
    $tris  = New-Object System.Collections.Generic.List[int]
    $triMat = New-Object System.Collections.Generic.List[int]
    $matNames = New-Object System.Collections.Generic.List[string]
    $partList = New-Object System.Collections.ArrayList
    $uvOf = @{}
    $entries = @(); foreach ($rm in $Rooms) { $entries += @{ F = $rm; P = '' } }
    foreach ($ch in @($Characters)) { if ($ch) { $entries += @{ F = [string]$ch.Xaf; P = [string]$ch.Prefix } } }
    foreach ($e in $entries) {
        $room = $e.F; $namePrefix = $e.P
        $obj = Join-Path $CacheDir ("{0}.obj" -f $room)
        # -IfStale, not Test-Path: the exporter stamps a version into the OBJ header and
        # re-exports anything older. A cached OBJ from an older exporter is worse than no
        # cache, because it silently keeps whatever that exporter got wrong at the time --
        # which is how per-face materials stayed missing after the exporter was fixed.
        New-Item -ItemType Directory -Force $CacheDir | Out-Null
        & (Join-Path $toolDir 'Export-XafObj.ps1') -Xaf $room -TexDir $TexDir -OutDir $CacheDir -IfStale | Out-Null
        if (-not (Test-Path $obj)) { throw "no geometry for $room" }
        # PER-FILE INDEX BASES. OBJ indices are per-file and 1-based; concatenating
        # without rebasing points every face after the first file at the wrong vertices,
        # which produces geometry that is plausible and wrong.
        $vBase = [int]($verts.Count/3); $tBase = [int]($uvs.Count/2); $curMat = -1
        # PARTS: each object's name, vertex range and REST world matrix, so a caller that can
        # read the LIVE scene graph can re-pose or hide objects per frame. Without this the
        # room is one anonymous soup of triangles and nothing can move -- which is why doors
        # never opened and picked-up items kept being drawn. vFirst is rebased like every
        # other index here.
        $pj = Join-Path $CacheDir ("{0}.parts.json" -f $room)
        if (Test-Path $pj) {
            # ASSIGN FIRST. ConvertFrom-Json emits a JSON array as ONE pipeline object, so
            # `foreach ($p in @(... | ConvertFrom-Json))` wraps the whole array in a
            # single-element array and $p becomes all 64 parts at once -- which fails as
            # "cannot convert System.Object[] to System.Int32" on the first cast, pointing at
            # the cast rather than at the enumeration.
            $pjson = Get-Content $pj -Raw | ConvertFrom-Json
            foreach ($p in @($pjson)) {
                [void]$partList.Add([pscustomobject]@{
                    Name = ($namePrefix + $p.name); Room = $room; IsCharacter = ($namePrefix -ne '')
                    VFirst = ([int]$p.vFirst + $vBase); VCount = [int]$p.vCount
                    Rest = @(0..15 | ForEach-Object { [single]$p.rest[$_] })
                })
            }
        }
        foreach ($line in [IO.File]::ReadAllLines($obj)) {
            if ($line.Length -lt 2) { continue }
            if ($line[0] -eq 'v' -and $line[1] -eq ' ') {
                $p = $line.Substring(2).Trim() -split '\s+'
                $verts.Add([single]$p[0]); $verts.Add([single]$p[1]); $verts.Add([single]$p[2])
            } elseif ($line[0] -eq 'v' -and $line[1] -eq 't') {
                $p = $line.Substring(3).Trim() -split '\s+'
                $uvs.Add([single]$p[0]); $uvs.Add([single]$p[1])
            } elseif ($line.StartsWith('usemtl ')) {
                # KEYED BY FILE+NAME: two rooms can both define `n_black` over different
                # art, and merging by name alone paints one room with the other's textures.
                $key = "$room/" + $line.Substring(7).Trim()
                $curMat = $matNames.IndexOf($key)
                if ($curMat -lt 0) { $matNames.Add($key); $curMat = $matNames.Count - 1 }
            } elseif ($line[0] -eq 'f' -and $line[1] -eq ' ') {
                # UVs RESOLVE THROUGH THE FACE. "vt index == vertex index" holds within a
                # .XAF mesh but not across a room that mixes textured and untextured
                # meshes -- MINEHEAD has 1,710 vertices and 1,662 UVs -- and taken
                # globally the lists drift and every later UV lands on the wrong vertex.
                $vi = @(); $ti = @()
                foreach ($tok in ($line.Substring(2).Trim() -split '\s+')) {
                    $parts = $tok -split '/'
                    $vi += [int]$parts[0] - 1 + $vBase
                    $ti += $(if ($parts.Count -ge 2 -and $parts[1]) { [int]$parts[1] - 1 + $tBase } else { -1 })
                }
                for ($c = 0; $c -lt $vi.Count; $c++) { if ($ti[$c] -ge 0) { $uvOf[$vi[$c]] = $ti[$c] } }
                for ($k = 1; $k -lt $vi.Count-1; $k++) { $tris.Add($vi[0]); $tris.Add($vi[$k]); $tris.Add($vi[$k+1]); $triMat.Add($curMat) }
            }
        }
    }
    $vArr = $verts.ToArray(); $tArr = $tris.ToArray()
    $nv = [int]($vArr.Count/3); $uvArr = New-Object single[] ($nv*2)
    for ($i = 0; $i -lt $nv; $i++) {
        $t = $(if ($uvOf.ContainsKey($i)) { $uvOf[$i] } else { -1 })
        if ($t -ge 0 -and ($t*2+1) -lt $uvs.Count) { $uvArr[$i*2] = $uvs[$t*2]; $uvArr[$i*2+1] = $uvs[$t*2+1] }
    }

    $pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)
    $mtlMap = @{}; $mtlFlat = @{}      # $mtlFlat: "file/material" -> @(r, g, b, alpha) for materials with no texture
    foreach ($room in @($entries | ForEach-Object { $_.F } | Select-Object -Unique)) {
        $mtl = Join-Path $CacheDir ("{0}.mtl" -f $room)
        if (-not (Test-Path $mtl)) { continue }
        $cur = $null
        foreach ($l in [IO.File]::ReadAllLines($mtl)) {
            $s = $l.Trim()
            if ($s.StartsWith('newmtl ')) { $cur = $s.Substring(7).Trim(); $kd = $null }
            elseif ($s.StartsWith('map_Kd ') -and $cur) { $mtlMap["$room/$cur"] = $s.Substring(7).Trim() }
            elseif ($s.StartsWith('Kd ') -and $cur) { $kd = @($s.Substring(3).Trim() -split '\s+' | ForEach-Object { [double]$_ }) }
            elseif ($s.StartsWith('d ') -and $cur -and $kd) { $mtlFlat["$room/$cur"] = @($kd[0], $kd[1], $kd[2], [double]$s.Substring(2).Trim()) }
        }
    }
    $texes = @(); $matToTex = @{}
    for ($mi = 0; $mi -lt $matNames.Count; $mi++) {
        $png = $(if ($mtlMap.ContainsKey($matNames[$mi])) { Join-Path $CacheDir $mtlMap[$matNames[$mi]] } else { $null })
        if (-not $png -or -not (Test-Path $png)) { $matToTex[$mi] = -1; continue }
        $bm = [System.Drawing.Bitmap]::FromFile($png); $tw = $bm.Width; $th = $bm.Height
        $cv = New-Object System.Drawing.Bitmap -ArgumentList $tw, $th, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gr = [System.Drawing.Graphics]::FromImage($cv); $gr.DrawImage($bm,0,0,$tw,$th); $gr.Dispose(); $bm.Dispose()
        $rc = New-Object System.Drawing.Rectangle -ArgumentList ([int]0),([int]0),$tw,$th
        $bd = $cv.LockBits($rc,[System.Drawing.Imaging.ImageLockMode]::ReadOnly,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $raw = New-Object byte[] ($tw*$th*4)
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0,$raw,0,$raw.Length)
        $cv.UnlockBits($bd); $cv.Dispose()
        # Quantised ONCE, at load. Dither 0 on purpose: a dithered wall crawls as the
        # camera moves, which is worse in motion than the banding it removes.
        $texes += (New-Object AztTool.Raster+Tex([LeTool.Quant]::Map($raw,$tw,$th,$pal,256,0,0,0), $tw, $th))
        $matToTex[$mi] = $texes.Count - 1
    }

    # MATERIALS THE ENGINE NEVER DRAWS. TRANSPARANT and ACTIVATION are trigger surfaces
    # -- the materials on the zx*/zy* objects AZONES.DAT lists as room portals -- and
    # BLACKCOVER is a masking quad. CORICORI's 17 TRANSPARANT faces are large quads lying
    # across the floor; drawing them flat covered a third of the screen in one colour.
    $SKIP_MATS = @('TRANSPARANT','ACTIVATION','BLACKCOVER')
    # The flat ink is for real geometry that simply carries no material (MINEHEAD's
    # `stuff` and `minechasm`). Dark and strictly neutral: a mid-luminance pick landed on
    # a pink that made every such face leap out of the scene.
    $fbCand = @(1..254 | ForEach-Object {
        $r3=$pal[$_*3]; $g3=$pal[$_*3+1]; $b3=$pal[$_*3+2]
        $mx=[Math]::Max($r3,[Math]::Max($g3,$b3)); $mn=[Math]::Min($r3,[Math]::Min($g3,$b3))
        [pscustomobject]@{ I=$_; L=(0.299*$r3+0.587*$g3+0.114*$b3); S=($mx-$mn) } } |
        Where-Object { $_.S -le 16 } | Sort-Object L)
    if ($fbCand.Count -lt 4) {
        $fbCand = @(1..254 | ForEach-Object { [pscustomobject]@{ I=$_; L=(0.299*$pal[$_*3]+0.587*$pal[$_*3+1]+0.114*$pal[$_*3+2]) } } | Sort-Object L)
    }
    $fbInk = [byte]$fbCand[[int]($fbCand.Count*0.20)].I
    $texes += (New-Object AztTool.Raster+Tex((New-Object byte[] 1), 1, 1))
    $texes[$texes.Count-1].Idx[0] = $fbInk
    $fbIdx = $texes.Count - 1

    # FLAT MATERIALS, AS THE .XAF DEFINES THEM. A material with no texture is either invisible
    # (alpha 0: trigger volumes and placeholders) or a solid colour (alpha 1: the Raptor's
    # black suit, BLACKMATTE). Both used to fall to the grey fallback above, which drew grey
    # patches over a third of that character and grey quads where a room has an invisible
    # marker. The nearest palette entry is found once per material; never index 0, which is
    # transparent in the guest.
    $flatTex = @{}
    for ($mi = 0; $mi -lt $matNames.Count; $mi++) {
        if ($matToTex[$mi] -ge 0 -or -not $mtlFlat.ContainsKey($matNames[$mi])) { continue }
        $c = $mtlFlat[$matNames[$mi]]
        if ($c[3] -le 0) { $flatTex[$mi] = -1; continue }
        $best = 1; $bd = [double]::MaxValue
        for ($pi2 = 1; $pi2 -lt 256; $pi2++) {
            $dr = $pal[$pi2*3] - $c[0]*255; $dg = $pal[$pi2*3+1] - $c[1]*255; $db = $pal[$pi2*3+2] - $c[2]*255
            $dd = $dr*$dr*0.299 + $dg*$dg*0.587 + $db*$db*0.114
            if ($dd -lt $bd) { $bd = $dd; $best = $pi2 }
        }
        $ft = New-Object AztTool.Raster+Tex((New-Object byte[] 1), 1, 1); $ft.Idx[0] = [byte]$best
        $texes += $ft; $flatTex[$mi] = $texes.Count - 1
    }

    $triTexArr = New-Object int[] ($triMat.Count)
    $nTex = 0; $nFlat = 0; $nSkip = 0; $nSolid = 0
    for ($i = 0; $i -lt $triMat.Count; $i++) {
        $mm = $triMat[$i]
        $nm = $(if ($mm -ge 0) { ($matNames[$mm] -split '/')[-1] } else { '' })
        if ($SKIP_MATS -contains $nm) { $triTexArr[$i] = -1; $nSkip++ }
        elseif ($mm -ge 0 -and $matToTex.ContainsKey($mm) -and $matToTex[$mm] -ge 0) { $triTexArr[$i] = $matToTex[$mm]; $nTex++ }
        elseif ($mm -ge 0 -and $flatTex.ContainsKey($mm)) { if ($flatTex[$mm] -lt 0) { $triTexArr[$i] = -1; $nSkip++ } else { $triTexArr[$i] = $flatTex[$mm]; $nSolid++ } }
        # A FACE WITH NO MATERIAL AT ALL IS A HELPER, NOT GEOMETRY. Swept across all 178 files
        # (135,043 triangles) exactly 63 have none, and every one is an authoring dummy: the
        # 12-triangle boxes `dummy`, `tdummy`, `sailorbox`, `fight`, and `rat`'s 2-triangle root
        # -- the handles an animator moves a rig or a camera by. Drawing them grey put a box
        # round Tobias and the sailor. The grey fallback stays for a material that EXISTS but
        # whose texture could not be loaded, where grey is at least a visible symptom.
        elseif ($mm -lt 0) { $triTexArr[$i] = -1; $nSkip++ }
        else { $triTexArr[$i] = $fbIdx; $nFlat++ }
    }

    $lo = @([single]::MaxValue,[single]::MaxValue,[single]::MaxValue)
    $hi = @([single]::MinValue,[single]::MinValue,[single]::MinValue)
    for ($i = 0; $i -lt $vArr.Count; $i += 3) {
        for ($a = 0; $a -lt 3; $a++) { $v=$vArr[$i+$a]; if($v -lt $lo[$a]){$lo[$a]=$v}; if($v -gt $hi[$a]){$hi[$a]=$v} }
    }
    $span = 0.0
    for ($a = 0; $a -lt 3; $a++) { $d = $hi[$a]-$lo[$a]; if ($d -gt $span) { $span = $d } }
    if ($span -le 0) { $span = 1000.0 }

    # Per-vertex and per-triangle part index, so a caller can re-pose or hide a named object
    # without searching. A triangle belongs wholly to one part: faces only ever reference
    # their own object's vertices, which is what makes the first-vertex lookup sound.
    $nV = [int]($vArr.Count/3)
    $partOf = New-Object int[] $nV
    for ($i = 0; $i -lt $nV; $i++) { $partOf[$i] = -1 }
    for ($pi = 0; $pi -lt $partList.Count; $pi++) {
        $p = $partList[$pi]
        for ($k = 0; $k -lt $p.VCount; $k++) {
            $vi = $p.VFirst + $k
            if ($vi -ge 0 -and $vi -lt $nV) { $partOf[$vi] = $pi }
        }
    }
    $nT = [int]($tArr.Count/3)
    $triPart = New-Object int[] $nT
    for ($i = 0; $i -lt $nT; $i++) { $triPart[$i] = $partOf[$tArr[$i*3]] }

    return [pscustomobject]@{
        Rooms = $Rooms; Characters = @($Characters); V = $vArr; UV = $uvArr; T = $tArr
        Parts = @($partList); PartOf = $partOf; TriPart = $triPart
        TexIdx = $triTexArr; Texes = [AztTool.Raster+Tex[]]$texes
        Pal = $pal; Span = $span; Cam = $cam; W = $Width; H = $Height
        Textured = $nTex; Flat = $nFlat; Skipped = $nSkip; Solid = $nSolid; FlatInk = $fbInk
    }
}

# =====================================================================================
#  THE FAST PATH: units, cached, composed in compiled code. See tools\RoomUnit.cs.
# =====================================================================================
#
# Bump when a rule in Import-AztRoomSlow changes what a unit contains (which materials are
# skipped, how flat ones are coloured, how UVs resolve...). It is part of every unit's stamp,
# so old caches are rebuilt instead of trusted.
$script:AZT_UNIT_RULES = 'rules-2'      # 2: faces with no material are helpers and are not drawn
$script:AztUnitMem = @{}          # name -> @{ Stamp; Unit; Tex }  -- lives as long as the process
$script:AztObjVersion = $null

function Get-AztUnit {
    param([string]$Name, [string]$CacheDir, [string]$TexDir, [string]$Palette, [string]$PalHash)
    if (-not ('AztRoom.RoomUnit' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'RoomUnit.cs') -ErrorAction Stop }
    if (-not $script:AztObjVersion) {
        # The exporter's CURRENT version line, read from its source rather than by running it:
        # running it is the cost this path exists to avoid, and a cached OBJ whose first line
        # is anything else is stale by the exporter's own rule.
        $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Export-XafObj.ps1')), "\`$OBJ_VERSION\s*=\s*'([^']+)'")
        $script:AztObjVersion = $(if ($m.Success) { $m.Groups[1].Value } else { '?' })
    }
    $obj = Join-Path $CacheDir ("{0}.obj" -f $Name)
    $unitPath = Join-Path $CacheDir ("{0}.unit" -f $Name)
    $stamp = $null
    if (Test-Path $obj) {
        $first = ''
        $sr = New-Object IO.StreamReader($obj); try { $first = $sr.ReadLine() } finally { $sr.Dispose() }
        if ($first -eq $script:AztObjVersion) {
            $stamp = '{0}|{1}|{2}|{3}' -f $script:AZT_UNIT_RULES, $first, (Get-Item $obj).LastWriteTimeUtc.Ticks, $PalHash
        }
    }
    if ($stamp) {
        $mem = $script:AztUnitMem[$Name]
        if ($mem -and $mem.Stamp -eq $stamp) { return $mem }
        $u = [AztRoom.RoomUnit]::Load($unitPath, $stamp)
        if ($u) { return (Add-AztUnitMem $Name $stamp $u) }
    }

    # MISS: build it the slow way, once. The slow path runs the exporter (-IfStale), so the
    # stamp is taken AFTER it, from the OBJ it left behind.
    $slow = Import-AztRoomSlow -Rooms @($Name) -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette
    $sr = New-Object IO.StreamReader($obj); try { $first = $sr.ReadLine() } finally { $sr.Dispose() }
    $stamp = '{0}|{1}|{2}|{3}' -f $script:AZT_UNIT_RULES, $first, (Get-Item $obj).LastWriteTimeUtc.Ticks, $PalHash
    $u = New-Object AztRoom.RoomUnit
    $u.V = [single[]]$slow.V; $u.UV = [single[]]$slow.UV; $u.T = [int[]]$slow.T
    $u.TexIdx = [int[]]$slow.TexIdx; $u.TriPart = [int[]]$slow.TriPart
    $np = $slow.Parts.Count
    $u.PartName = New-Object string[] $np; $u.PartVFirst = New-Object int[] $np; $u.PartVCount = New-Object int[] $np
    $u.PartRest = New-Object single[] ($np * 16)
    for ($i = 0; $i -lt $np; $i++) {
        $p = $slow.Parts[$i]
        $u.PartName[$i] = [string]$p.Name; $u.PartVFirst[$i] = [int]$p.VFirst; $u.PartVCount[$i] = [int]$p.VCount
        for ($k = 0; $k -lt 16; $k++) { $u.PartRest[$i*16 + $k] = [single]$p.Rest[$k] }
    }
    $nt = $slow.Texes.Count
    $u.TexW = New-Object int[] $nt; $u.TexH = New-Object int[] $nt; $u.TexData = New-Object 'byte[][]' $nt
    for ($i = 0; $i -lt $nt; $i++) { $u.TexW[$i] = $slow.Texes[$i].W; $u.TexH[$i] = $slow.Texes[$i].H; $u.TexData[$i] = [byte[]]$slow.Texes[$i].Idx }
    $u.Textured = [int]$slow.Textured; $u.Flat = [int]$slow.Flat; $u.Skipped = [int]$slow.Skipped; $u.Solid = [int]$slow.Solid
    $u.FlatInk = [byte]$slow.FlatInk
    try { $u.Save($unitPath, $stamp) } catch { Write-Warning ("could not write {0}: {1}" -f $unitPath, $_.Exception.Message) }
    return (Add-AztUnitMem $Name $stamp $u)
}

function Add-AztUnitMem([string]$Name, [string]$Stamp, $u) {
    $tex = New-Object 'AztTool.Raster+Tex[]' $u.TexData.Length
    for ($i = 0; $i -lt $tex.Length; $i++) { $tex[$i] = New-Object AztTool.Raster+Tex($u.TexData[$i], $u.TexW[$i], $u.TexH[$i]) }
    $mem = @{ Stamp = $Stamp; Unit = $u; Tex = $tex }
    $script:AztUnitMem[$Name] = $mem
    return $mem
}

# TRUE COLOUR: give a unit's textures their painted originals.
#
# A unit keeps its textures already squeezed into the game's palette, and not their names. But
# the order they were made in is fixed by Import-AztRoomSlow: one per material that has a
# picture, in the order the OBJ first uses each material; then the grey fallback; then the flat
# colours. So the same walk over the OBJ and the .mtl gives the PNG for each of the first few,
# and the rest (which never had a picture) take their colour from the palette. A PNG whose size
# does not match the texture it is being given to means the order assumption has failed for
# that unit, and the whole unit falls back to palette colours rather than risk a wrong picture.
# a PNG's width and height from its header (IHDR), without decoding it
function Get-AztPngSize([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try { $b = New-Object byte[] 24; if ($fs.Read($b, 0, 24) -lt 24) { return $null }
          return @(((([int]$b[16]) -shl 24) -bor (([int]$b[17]) -shl 16) -bor (([int]$b[18]) -shl 8) -bor [int]$b[19]), ((([int]$b[20]) -shl 24) -bor (([int]$b[21]) -shl 16) -bor (([int]$b[22]) -shl 8) -bor [int]$b[23])) }
    finally { $fs.Dispose() }
}
# TEXTURE QUALITY (Josh, 2026-10-11: the title's Options -> Texture quality, Normal = 2K textures, Ultra = 4K): a replacement
# larger than -MaxSize on its long side is read from a copy scaled to fit, made once in "<OverrideDir>-<MaxSize>" beside the
# folder (made again when the master is newer) -- so Normal also decodes a quarter of the pixels at every room entry
function Get-AztSizedOverride([string]$Path, [int]$MaxSize) {
    if ($MaxSize -le 0) { return $Path }
    $sz = Get-AztPngSize $Path; if (-not $sz -or [Math]::Max($sz[0], $sz[1]) -le $MaxSize) { return $Path }
    $dir = Split-Path $Path -Parent; $cd = Join-Path (Split-Path $dir -Parent) ("{0}-{1}" -f (Split-Path $dir -Leaf), $MaxSize)
    $out = Join-Path $cd (Split-Path $Path -Leaf)
    if ((Test-Path $out) -and (Get-Item $out).LastWriteTimeUtc -ge (Get-Item $Path).LastWriteTimeUtc) { return $out }
    New-Item -ItemType Directory -Force $cd | Out-Null
    Add-Type -AssemblyName System.Drawing
    $k = $MaxSize / [double][Math]::Max($sz[0], $sz[1]); $w = [Math]::Max(1, [int][Math]::Round($sz[0] * $k)); $h = [Math]::Max(1, [int][Math]::Round($sz[1] * $k))
    $tmp = "$out.part"; $src = [Drawing.Image]::FromFile($Path)
    try {
        $bm = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb); $g = [Drawing.Graphics]::FromImage($bm)
        $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingMode = 'SourceCopy'
        $ia = New-Object Drawing.Imaging.ImageAttributes; $ia.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)      # (no dark rim from beyond the edge)
        $g.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $w, $h), 0, 0, $src.Width, $src.Height, [Drawing.GraphicsUnit]::Pixel, $ia)
        $g.Dispose(); $bm.Save($tmp, [Drawing.Imaging.ImageFormat]::Png); $bm.Dispose()
    } finally { $src.Dispose() }
    Move-Item -Force $tmp $out
    return $out
}
# SHARED ART (2026-10-12, [[azrael-texture-repair]]): one original picture is exported under several leaves (MINEMAZE's 03-baptapce is
# BAPTIST's 00-baptapce), and replacement art goes in by leaf -- so a leaf still on the old upscale whose picture has Josh's new art
# under another leaf loads THAT leaf's art: leaf -> twin leaf, tools\TexTwins.cs (the rules, the index file). Checked on every load
# that has textures to decode: ~5 ms (the folders listed, nothing read); worked out again only when they changed (~0.6 s for all).
$script:AztTwin = $null
function Get-AztTwinArt([string]$CacheDir, [string]$OverrideDir) {
    if (-not $OverrideDir -or -not [IO.Directory]::Exists($OverrideDir) -or -not [IO.Directory]::Exists($CacheDir)) { return (New-Object 'System.Collections.Generic.Dictionary[string,string]') }
    if (-not ('AztTool.TexTwins' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'TexTwins.cs') -ReferencedAssemblies System.Drawing -ErrorAction Stop }
    $stamp = [AztTool.TexTwins]::Stamp($CacheDir, $OverrideDir)
    if ($script:AztTwin -and $script:AztTwin.Stamp -eq $stamp) { return $script:AztTwin.Map }
    $map = [AztTool.TexTwins]::Load($CacheDir, $OverrideDir)
    $script:AztTwin = @{ Stamp = [AztTool.TexTwins]::LastStamp; Map = $map; Note = [AztTool.TexTwins]::LastNote }
    return $map
}
function Add-AztRgb {
    # -OverrideDir: REPLACEMENT ART. A PNG there with the same file name as a texture's own
    # (e.g. 08-ecrflra2.png) is used for its colours instead, at whatever size it is. The
    # original is still loaded first, to prove the texture order, and still decides where the
    # texture has holes -- so a replacement must keep the original's layout. A texture whose own file
    # there is only the old upscale shows a twin's new art instead (SHARED ART, Get-AztTwinArt).
    # -MaxSize: TEXTURE QUALITY -- replacements no larger than this on their long side (0 = as they are; Normal = 2048)
    # -Progress: { param($done, $total) } called every ~15 ms while the pictures decode (the watcher's loading cover)
    param([string[]]$Names, [string]$CacheDir, [byte[]]$Pal, [string]$OverrideDir = '', [int]$MaxSize = 0, [scriptblock]$Progress = $null)
    $fromFile = 0; $fromPal = 0; $bad = @(); $replaced = @()
    $dirKey = [string]$OverrideDir + $(if ($MaxSize -gt 0 -and $OverrideDir) { "|$MaxSize" } else { '' })      # (another quality = every texture afresh)
    $useNow = ++$script:AztRgbUse
    # 1. the units that need their colours, and each one's pictures in the order its textures were made
    $work = New-Object System.Collections.Generic.List[object]
    foreach ($n in @($Names | Where-Object { $_ } | Select-Object -Unique)) {
        $mem = $script:AztUnitMem[$n]
        if (-not $mem) { continue }
        $mem.RgbUsed = $useNow
        # done already, FOR THIS REPLACEMENT FOLDER. Another folder means every texture is loaded
        # afresh (its original first, then the replacement if that folder has one).
        if ($mem.RgbDone -and [string]$mem.RgbDir -eq $dirKey) { continue }
        $tex = $mem.Tex; $pngs = @()
        if ($mem.RgbDone) { foreach ($t in $tex) { $t.Rgb = $null; $t.RgbFromFile = $false } }
        $obj = Join-Path $CacheDir ("{0}.obj" -f $n); $mtl = Join-Path $CacheDir ("{0}.mtl" -f $n)
        if ((Test-Path $obj) -and (Test-Path $mtl)) {
            $map = @{}; $cur = $null
            foreach ($l in [IO.File]::ReadAllLines($mtl)) {
                $s = $l.Trim()
                if ($s.StartsWith('newmtl ')) { $cur = $s.Substring(7).Trim() }
                elseif ($s.StartsWith('map_Kd ') -and $cur) { $map[$cur] = $s.Substring(7).Trim() }
            }
            $seen = @{}
            foreach ($l in [IO.File]::ReadAllLines($obj)) {
                if (-not $l.StartsWith('usemtl ')) { continue }
                $m = $l.Substring(7).Trim(); if ($seen.ContainsKey($m)) { continue }; $seen[$m] = 1
                if ($map.ContainsKey($m)) { $p = Join-Path $CacheDir $map[$m]; if (Test-Path $p) { $pngs += $p } }
            }
        }
        $work.Add([pscustomobject]@{ N = $n; Mem = $mem; Pngs = $pngs; Ok = ($pngs.Count -lt $tex.Length) })
    }
    if ($work.Count -eq 0) { return [pscustomobject]@{ FromFile = 0; FromPalette = 0; Bad = @(); Replaced = @(); Twins = 0 } }
    $haveOv = [bool]($OverrideDir -and (Test-Path $OverrideDir))
    # the leaf whose replacement art each texture shows: its own, or a twin's new art (SHARED ART, Get-AztTwinArt)
    $artOf = @{}; $twinErr = ''; $nTwin = 0; $twinMs = 0
    if ($haveOv) {
        $twSw = [Diagnostics.Stopwatch]::StartNew()
        $twin = $null; try { $twin = Get-AztTwinArt $CacheDir $OverrideDir } catch { $twinErr = $_.Exception.Message }
        $twinMs = [int]$twSw.ElapsedMilliseconds
        foreach ($w in $work) { foreach ($p in $w.Pngs) { $lf = [IO.Path]::GetFileNameWithoutExtension($p); $artOf[$p] = $(if ($twin -and $twin.ContainsKey($lf)) { $twin[$lf] } else { $lf }) } }
    }
    $ovGuess = 0; if ($haveOv) { foreach ($w in $work) { foreach ($p in $w.Pngs) { if (Test-Path (Join-Path $OverrideDir ($artOf[$p] + '.png'))) { $ovGuess++ } } } }
    # MANY AT ONCE (2026-10-12): Raster.LoadRgbAsync decodes on several threads -- a room's 4K art in ~0.7 s, not 4-5 s --
    # while this waits, telling -Progress how far it has got (weighting the 4K replacements: the originals are 128-256 px)
    $wait = { param($job, [int]$base, [int]$tot)
        while (-not $job.Finished) { if ($Progress) { try { & $Progress ($base + $job.Done) $tot } catch { } }; [Threading.Thread]::Sleep(15) }
        if ($job.Task) { $job.Task.Wait() }
        if ($Progress) { try { & $Progress ($base + $job.Total) $tot } catch { } } }
    # 2. the originals: they prove the texture order (a size that does not match = palette colours for that whole unit)
    $jt = New-Object System.Collections.Generic.List[object]; $jp = New-Object System.Collections.Generic.List[string]; $jw = New-Object System.Collections.Generic.List[int]
    for ($wi = 0; $wi -lt $work.Count; $wi++) {
        $w = $work[$wi]; if (-not $w.Ok) { continue }
        for ($i = 0; $i -lt $w.Pngs.Count; $i++) { if ($w.Mem.Tex[$i].Rgb) { continue }; $jt.Add($w.Mem.Tex[$i]); $jp.Add($w.Pngs[$i]); $jw.Add($wi) }
    }
    $totAll = [Math]::Max(1, [int](($jt.Count + 9) / 10) + $ovGuess)
    if ($jt.Count) {
        $job = [AztTool.Raster]::LoadRgbAsync([AztTool.Raster+Tex[]]$jt.ToArray(), $jp.ToArray(), $Pal, 0)
        & $wait $job 0 $totAll
        for ($k = 0; $k -lt $jt.Count; $k++) {
            $jt[$k].Leaf = [IO.Path]::GetFileNameWithoutExtension($jp[$k])      # (its name, for room settings that name a texture: "holes")
            if ($job.Error[$k] -or -not $job.Same[$k]) { $work[$jw[$k]].Ok = $false }
        }
    }
    foreach ($w in $work) { if (-not $w.Ok) { $bad += $w.N; foreach ($t in $w.Mem.Tex) { if ($t.RgbFromFile) { $t.Rgb = $null; $t.RgbFromFile = $false } } } }
    # 3. the replacement art (the slow part)
    if ($haveOv) {
        $ot = New-Object System.Collections.Generic.List[object]; $op = New-Object System.Collections.Generic.List[string]; $oo = New-Object System.Collections.Generic.List[string]
        foreach ($w in $work) {
            if (-not $w.Ok) { continue }
            for ($i = 0; $i -lt $w.Pngs.Count; $i++) {
                $ov = Join-Path $OverrideDir ($artOf[$w.Pngs[$i]] + '.png')
                if (-not (Test-Path $ov)) { continue }
                if ($Progress -and $MaxSize -gt 0) { try { & $Progress ([int](($jt.Count + 9) / 10)) $totAll } catch { } }      # (a smaller copy made the first time can take a moment: the cover keeps moving)
                try { $ov = Get-AztSizedOverride $ov $MaxSize } catch { }
                $ot.Add($w.Mem.Tex[$i]); $op.Add($ov); $oo.Add($w.Pngs[$i])
            }
        }
        if ($ot.Count) {
            $job = [AztTool.Raster]::LoadRgbAsync([AztTool.Raster+Tex[]]$ot.ToArray(), $op.ToArray(), $Pal, 0)
            & $wait $job ([int](($jt.Count + 9) / 10)) $totAll
            for ($k = 0; $k -lt $ot.Count; $k++) {
                if ($job.Error[$k]) { try { [void]$ot[$k].LoadRgb($oo[$k], $Pal) } catch { } }      # (a replacement that will not load: the original)
                else {
                    $own = [IO.Path]::GetFileNameWithoutExtension($oo[$k]); $src = $artOf[$oo[$k]]
                    $replaced += ('{0}.png ({1}x{2}{3})' -f $own, $ot[$k].Rgb[0].W, $ot[$k].Rgb[0].H, $(if ($src -ne $own) { $nTwin++; ', the new art of ' + $src } else { '' }))
                }
            }
        }
    }
    # 3b. COMPANION MAPS (Josh's art pipeline, 2026-10-12): "<name>_rough.png" (white = rough, black = polished), "_height.png"
    # (white = raised) and "_glow.png" (white = glows) beside a replacement in the same folder -- read at most 2048 on their long
    # side (the Normal tier's sized copies as for the colours) into Tex.MatPx: the graphics card's shine, relief and glow.
    # A texture showing a twin's art takes that twin's maps (they belong to the picture).
    $mats = 0; $matErr = @()
    if ($haveOv) {
        $ct = New-Object System.Collections.Generic.List[object]; $cr = New-Object System.Collections.Generic.List[string]; $ch = New-Object System.Collections.Generic.List[string]; $cg = New-Object System.Collections.Generic.List[string]
        foreach ($w in $work) {
            if (-not $w.Ok) { continue }
            for ($i = 0; $i -lt $w.Pngs.Count; $i++) {
                $tx = $w.Mem.Tex[$i]; $tx.MatPx = $null; $tx.MatHas = 0
                $base = Join-Path $OverrideDir $artOf[$w.Pngs[$i]]
                $cp = New-Object string[] 3; $any = $false; $sf = @('_rough', '_height', '_glow')
                for ($c = 0; $c -lt 3; $c++) { $p = $base + $sf[$c] + '.png'; if (Test-Path -LiteralPath $p) { try { $p = Get-AztSizedOverride $p $MaxSize } catch { }; $cp[$c] = $p; $any = $true } }
                if ($any) { $ct.Add($tx); $cr.Add($cp[0]); $ch.Add($cp[1]); $cg.Add($cp[2]) }
            }
        }
        if ($ct.Count) {
            $job = [AztTool.Raster]::LoadMatAsync([AztTool.Raster+Tex[]]$ct.ToArray(), $cr.ToArray(), $ch.ToArray(), $cg.ToArray(), $(if ($MaxSize -gt 0) { [Math]::Min($MaxSize, 2048) } else { 2048 }), 0)
            $job.Task.Wait()
            for ($k = 0; $k -lt $ct.Count; $k++) { if ($job.Same[$k]) { $mats++ } elseif ($job.Error[$k]) { $matErr += ('{0}: {1}' -f $ct[$k].Leaf, $job.Error[$k]) } }
        }
    }
    # 4. palette colours for the rest
    foreach ($w in $work) {
        $b = 0L
        foreach ($t in $w.Mem.Tex) {
            if ($t.Rgb) { if ($t.RgbFromFile) { $fromFile++ } } else { $t.EnsureRgb($Pal); $fromPal++ }
            foreach ($lv in $t.Rgb) { $b += 4L * $lv.Px.Length }
            if ($t.MatPx) { $b += 4L * $t.MatPx.Length }
        }
        $w.Mem.RgbDone = $true; $w.Mem.RgbDir = $dirKey; $w.Mem.RgbBytes = $b
    }
    return [pscustomobject]@{ FromFile = $fromFile; FromPalette = $fromPal; Bad = $bad; Replaced = $replaced; Companions = $mats; CompanionErrors = $matErr; Twins = $nTwin; TwinError = $twinErr; TwinMs = $twinMs; TwinNote = $(if ($script:AztTwin) { $script:AztTwin.Note } else { '' }) }
}
$script:AztRgbUse = 0
# THE SESSION'S TEXTURE CACHE, BOUNDED (2026-10-12). Every unit's painted colours stay decoded for the session, so a room
# entered again needs no decoding at all -- but a 4K texture is ~85 MB here (with its half-size copies) and a room 1-2.5 GB,
# so past -CapBytes the least recently used units OTHER than -Keep give theirs up (decoded again if met again).
function Limit-AztRgbCache([string[]]$Keep, [long]$CapBytes) {
    $all = @(); $total = 0L
    foreach ($kv in $script:AztUnitMem.GetEnumerator()) { $m = $kv.Value; if (-not $m.RgbDone -or -not $m.RgbBytes) { continue }; $total += [long]$m.RgbBytes; $all += [pscustomobject]@{ N = [string]$kv.Key; M = $m } }
    $dropped = @()
    if ($CapBytes -gt 0 -and $total -gt $CapBytes) {
        foreach ($u in @($all | Where-Object { $Keep -notcontains $_.N } | Sort-Object { [long]$_.M.RgbUsed })) {
            if ($total -le [long]($CapBytes * 0.85)) { break }
            foreach ($t in $u.M.Tex) { $t.Rgb = $null; $t.RgbFromFile = $false; $t.MatPx = $null; $t.MatHas = 0 }
            $total -= [long]$u.M.RgbBytes; $u.M.RgbDone = $false; $u.M.RgbBytes = 0; $dropped += $u.N
        }
    }
    return [pscustomobject]@{ Bytes = $total; Dropped = $dropped }
}

# Same parameters and the same result shape as it always had; every caller is unchanged.
function Import-AztRoom {
    [CmdletBinding()]
    param(
        [string]$RefName,
        [string[]]$Rooms,
        [object[]]$Characters = @(),
        [string]$RefDir   = 'C:\Games\RaptorMod\cache\ref',
        [string]$CacheDir = 'C:\Games\RaptorMod\cache',
        [string]$TexDir   = 'C:\Games\RaptorMod\game\GAME\AZTEX',
        [string]$Palette  = 'C:\Games\RaptorMod\cache\azrael-palette.pal',
        [int]$Width = 0, [int]$Height = 0
    )
    # (Smoother models -- curved subdivision of each unit at load, tools\retired\MeshSmooth.cs --
    # were tried and removed on 2026-10-05: Josh found they made the characters look worse.)
    $cam = $null
    if ($RefName) {
        $ref = Get-Content (Join-Path $RefDir ("{0}.json" -f $RefName)) -Raw | ConvertFrom-Json
        $Rooms = @($ref.rooms)
        if ($Width -le 0)  { $Width  = [int]$ref.width }
        if ($Height -le 0) { $Height = [int]$ref.height }
        $cam = @(0..15 | ForEach-Object { [double]$ref.camera[$_] })
    }
    if (-not $Rooms -or $Rooms.Count -eq 0) { throw 'Import-AztRoom needs -RefName or -Rooms' }
    New-Item -ItemType Directory -Force $CacheDir | Out-Null

    $pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $palHash = ([BitConverter]::ToString($sha.ComputeHash($pal)) -replace '-', '').Substring(0, 16) } finally { $sha.Dispose() }

    $names = @(); $prefixes = @(); $isChar = @()
    foreach ($rm in $Rooms) { $names += [string]$rm; $prefixes += ''; $isChar += $false }
    foreach ($ch in @($Characters)) { if ($ch) { $names += [string]$ch.Xaf; $prefixes += [string]$ch.Prefix; $isChar += $true } }

    $mems = @(); foreach ($n in $names) { $mems += (Get-AztUnit -Name $n -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette -PalHash $palHash) }
    # a character's textures move with it: the card's world-laid micro relief stays off them (Raster.Tex.Moves)
    for ($i = 0; $i -lt $mems.Count; $i++) { if ($isChar[$i]) { foreach ($ct in @($mems[$i].Tex)) { if ($ct) { $ct.Moves = $true } } } }
    $units = New-Object 'AztRoom.RoomUnit[]' $mems.Count
    for ($i = 0; $i -lt $mems.Count; $i++) { $units[$i] = $mems[$i].Unit }
    $c = [AztRoom.Composed]::Build($units, [string[]]$prefixes)

    # textures: one list per DISTINCT unit, in first-appearance order -- the order Build used
    $slotTex = @(); $seenUnit = @()
    for ($i = 0; $i -lt $mems.Count; $i++) {
        $dup = $false; foreach ($s in $seenUnit) { if ([object]::ReferenceEquals($s, $units[$i])) { $dup = $true; break } }
        if (-not $dup) { $seenUnit += $units[$i]; $slotTex += ,$mems[$i].Tex }
    }
    $texes = New-Object 'AztTool.Raster+Tex[]' $c.TexSlot.Length
    for ($i = 0; $i -lt $texes.Length; $i++) { $texes[$i] = $slotTex[$c.TexSlot[$i]][$c.TexLocal[$i]] }

    $parts = New-Object object[] $c.PartName.Length
    for ($i = 0; $i -lt $parts.Length; $i++) {
        $e = $c.PartEntry[$i]
        $parts[$i] = [pscustomobject]@{ Name = $c.PartName[$i]; Room = $names[$e]; VFirst = $c.PartVFirst[$i]; VCount = $c.PartVCount[$i]; Rest = $c.PartRest[$i]; IsCharacter = $isChar[$e] }
    }

    return [pscustomobject]@{
        Rooms = $Rooms; Characters = @($Characters); V = $c.V; UV = $c.UV; T = $c.T
        Parts = $parts; PartOf = $c.PartOf; TriPart = $c.TriPart
        TexIdx = $c.TexIdx; Texes = $texes
        Pal = $pal; Span = [double]$c.Span; Cam = $cam; W = $Width; H = $Height
        Textured = $c.Textured; Flat = $c.Flat; Skipped = $c.Skipped; Solid = $c.Solid; FlatInk = $mems[0].Unit.FlatInk
    }
}

# =====================================================================================
#  DOORWAYS: the neighbouring rooms, ready to draw through this room's doors.
# =====================================================================================
#
# tools\Build-PortalMap.ps1 works out, from the game's own zone table and the trigger and
# arrival markers in every room file, which room is behind each doorway and the transform
# that carries it into this room's coordinates. This turns that into things the rasteriser
# can draw: for each doorway of the rooms in $Files that has a picture standing in it, the
# picture's triangles (to leave out and to use as the opening) and the neighbour's geometry,
# moved. Returns AztTool.Portal[]; a doorway whose neighbour will not load is skipped and
# keeps its picture, and the reason is put in $script:AztPortalNotes for the caller to log.
# THE MAP'S DOORS (Josh, 2026-10-14: the map's arrows "are still in place as they are in the original game"): every doorway
# of the room's files from the portal map (tools\Build-PortalMap.ps1: portals.json, per .XAF -- the doorway's pad 'door',
# the way out of the room 'axis' (x, z), the room it leads to 'to'). Returns @{ Marks = float[] (8 per door, GpuRaster
# SetMapMarks: x, y, z, out x, out z, 0 = a door, size 0, 0); Doors = @( @{ To; X; Y; Z } ) }.
function Get-AztMapDoors([string[]]$Files, [string]$CacheDir = 'C:\Games\RaptorMod\cache') {
    $mapPath = Join-Path $CacheDir 'portals.json'
    $marks = New-Object 'System.Collections.Generic.List[single]'; $doors = @()
    if (-not (Test-Path $mapPath)) { return @{ Marks = $marks.ToArray(); Doors = $doors } }
    $stamp = (Get-Item $mapPath).LastWriteTimeUtc.Ticks
    if ($script:AztPortalMapStamp -ne $stamp) { $script:AztPortalMap = [IO.File]::ReadAllText($mapPath) | ConvertFrom-Json; $script:AztPortalMapStamp = $stamp }
    foreach ($f in $Files) {
        $prop = $script:AztPortalMap.PSObject.Properties[$f.ToUpper()]; if (-not $prop) { continue }
        foreach ($e in @($prop.Value)) {
            if (-not $e.door -or @($e.door).Count -lt 3) { continue }
            $ax = 0.0; $az = 1.0; if ($e.axis -and @($e.axis).Count -ge 2) { $ax = [double]$e.axis[0]; $az = [double]$e.axis[1] }
            foreach ($v in @([single]$e.door[0], [single]$e.door[1], [single]$e.door[2], [single]$ax, [single]$az, [single]0, [single]0, [single]0)) { $marks.Add($v) }
            $doors += @{ To = [string]$e.to; X = [double]$e.door[0]; Y = [double]$e.door[1]; Z = [double]$e.door[2] }
        }
    }
    return @{ Marks = $marks.ToArray(); Doors = $doors }
}
# ...and the triangles the map leaves out (GpuRaster.SetMapSkip): every doorway's painted views of the next room
# (portals.json 'views' -- the parked alternates float outside the room), matched by exact part name in that file, and the
# characters (a pose frozen into the map).
# A room's textures by name, in the room's texture order (Room.Texes): each file's materials in the order its OBJ first uses them,
# the ones with no texture (TRANSPARANT, ATRANNIE...) left out -- checked on MINEHEAD: Tex[8] = 27-mineflr2 after TRANSPARANT --
# the files one after another. Each: Mat (the material, upper case) and Leaf (the png's name, upper case, its 'NN-' prefix off).
$script:AztTexNames = @{}
function Get-AztTexNames([string[]]$Files, [string]$CacheDir = 'C:\Games\RaptorMod\cache') {
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $Files) {
        $n = $f.ToUpperInvariant(); $obj = Join-Path $CacheDir ($n + '.obj'); $mtl = Join-Path $CacheDir ($n + '.mtl')
        if (-not (Test-Path $obj) -or -not (Test-Path $mtl)) { continue }
        $key = $n + '@' + (Get-Item $obj).LastWriteTimeUtc.Ticks
        if (-not $script:AztTexNames.ContainsKey($key)) {
            $map = @{}; $cur = $null; $one = New-Object 'System.Collections.Generic.List[object]'
            foreach ($l in [IO.File]::ReadAllLines($mtl)) { $s = $l.Trim(); if ($s.StartsWith('newmtl ')) { $cur = $s.Substring(7).Trim() } elseif ($s.StartsWith('map_Kd ') -and $cur) { $map[$cur] = $s.Substring(7).Trim() } }
            $seen = @{}
            foreach ($l in [IO.File]::ReadAllLines($obj)) {
                if (-not $l.StartsWith('usemtl ')) { continue }
                $m = $l.Substring(7).Trim(); if ($seen.ContainsKey($m)) { continue }; $seen[$m] = 1
                if (-not $map.ContainsKey($m)) { continue }
                $lf = ([IO.Path]::GetFileNameWithoutExtension($map[$m]) -replace '^\d+-', '').ToUpperInvariant()
                $one.Add([pscustomobject]@{ Mat = $m.ToUpperInvariant(); Leaf = $lf })
            }
            $script:AztTexNames[$key] = $one
        }
        $out.AddRange($script:AztTexNames[$key])
    }
    return ,$out
}
function Get-AztMapSkip($Room, [string[]]$Files, [string]$CacheDir = 'C:\Games\RaptorMod\cache') {
    $names = @{}; $doorXYZ = New-Object 'System.Collections.Generic.List[single]'
    $mapPath = Join-Path $CacheDir 'portals.json'
    if (Test-Path $mapPath) {
        $stamp = (Get-Item $mapPath).LastWriteTimeUtc.Ticks
        if ($script:AztPortalMapStamp -ne $stamp) { $script:AztPortalMap = [IO.File]::ReadAllText($mapPath) | ConvertFrom-Json; $script:AztPortalMapStamp = $stamp }
        foreach ($f in $Files) {
            $prop = $script:AztPortalMap.PSObject.Properties[$f.ToUpper()]; if (-not $prop) { continue }
            foreach ($e in @($prop.Value)) {
                foreach ($vn in @($e.views) + @($e.parked)) { if ($vn) { $names[$f.ToUpper() + '|' + [string]$vn] = 1 } }
                if ($e.door -and @($e.door).Count -ge 3) { $doorXYZ.Add([single]$e.door[0]); $doorXYZ.Add([single]$e.door[1]); $doorXYZ.Add([single]$e.door[2]) }
            }
        }
    }
    # ...and the parts a room's settings leave off its map (Josh, 2026-10-14: Room Review "map update" notes): rooms\<ROOM>.json
    # "map": { "hide": [part names, exactly as the room file spells them] }
    # MORE THAN PARTS (Josh, 2026-10-14, round 26: a giant black ceiling inside MINEHEAD's main mesh; "all other geometry that extends
    # under the main floor"): "hideMaterials": [material or texture names -- 'BLACK', '10-n_black.png' and 'n_black' alike],
    # "hideBelow": a height (triangles wholly under it), "keep": [parts those two leave alone]
    $hide = @{}; $hideMat = @{}; $below = @{}; $keep = @{}; $boxes = @()
    foreach ($f in $Files) {
        $rp = Join-Path (Join-Path $CacheDir 'rooms') ($f.ToUpper() + '.json')
        if (-not (Test-Path $rp)) { continue }
        try {
            $rj = [IO.File]::ReadAllText($rp) | ConvertFrom-Json; $F = $f.ToUpper()
            foreach ($hn in @($rj.map.hide)) { if ($hn) { $hide[$F + '|' + [string]$hn] = 1 } }
            foreach ($hm in @($rj.map.hideMaterials)) {
                if (-not $hm) { continue }
                # ("part/material": only that part's -- MINEHEAD's ceiling is stuff/BLACK, the cart's black faces stay)
                $hs = [string]$hm; $hp = ''; $sl = $hs.IndexOf('/'); if ($sl -gt 0) { $hp = $hs.Substring(0, $sl); $hs = $hs.Substring($sl + 1) }
                $hideMat[$F + '|' + $hp + '|' + (([IO.Path]::GetFileNameWithoutExtension($hs)) -replace '^\d+-', '').ToUpperInvariant()] = 1
            }
            if ($null -ne $rj.map.hideBelow) { $below[$F] = [double]$rj.map.hideBelow }
            foreach ($kn in @($rj.map.keep)) { if ($kn) { $keep[$F + '|' + [string]$kn] = 1 } }
            # "hideBoxes": [{ "box": [x0, y0, z0, x1, y1, z1], "part": optional }] -- triangles whose middle lies inside leave the map, "keep"
            # or not (Josh, 2026-10-14, MINEHEAD/13: the two shafts under the floor, inside the kept chasm mesh)
            foreach ($hb in @($rj.map.hideBoxes)) { if ($hb -and $hb.box -and @($hb.box).Count -eq 6) { $boxes += ,@($F, [string]$hb.part, [double[]]@($hb.box)) } }
        } catch { }
    }
    # (the items the player can pick up, in every room: <CacheDir>\pickups.json, learned from the game's scripts by the watcher's
    # Update-Pickups -- Josh, 2026-10-14, MINEMAZE/12: "Omit all items that are able to be picked up from the player from all maps")
    $pick = @{}
    $pkf = Join-Path $CacheDir 'pickups.json'
    if (Test-Path $pkf) {
        $pst = (Get-Item $pkf).LastWriteTimeUtc.Ticks
        if ($script:AztPickupsStamp -ne $pst) { try { $script:AztPickups = @(([IO.File]::ReadAllText($pkf) | ConvertFrom-Json).parts) } catch { $script:AztPickups = @() }; $script:AztPickupsStamp = $pst }
        foreach ($pn in @($script:AztPickups)) { if ($pn) { $pick[[string]$pn] = 1 } }
    }
    $skipPart = New-Object 'System.Collections.Generic.HashSet[int]'
    for ($i = 0; $i -lt $Room.Parts.Count; $i++) {
        $p = $Room.Parts[$i]
        if ($pick.Count -and $pick.ContainsKey([string]$p.Name)) { [void]$skipPart.Add($i); continue }
        if ($hide.Count -and $hide.ContainsKey(([string]$p.Room).ToUpper() + '|' + [string]$p.Name)) { [void]$skipPart.Add($i); continue }
        # (and the room's occluder sheets: across the game they are named black... -- blackcover, blackout01, BLACKTOP01, MINEMAZE's black planes)
        if ($p.IsCharacter -or $names.ContainsKey(([string]$p.Room).ToUpper() + '|' + [string]$p.Name) -or ([string]$p.Name) -match '^(?i)black') { [void]$skipPart.Add($i) }
    }
    # ...and whatever is not joined to the room's body (parked doors, backdrop planes, props left outside: GpuRaster.MapStrayParts)
    try {
        $np = $Room.Parts.Count; $vf = New-Object int[] $np; $vc = New-Object int[] $np; $sk = New-Object bool[] $np
        for ($i = 0; $i -lt $np; $i++) { $vf[$i] = [int]$Room.Parts[$i].VFirst; $vc[$i] = [int]$Room.Parts[$i].VCount; $sk[$i] = $skipPart.Contains($i) }
        $stray = [AztTool.GpuRaster]::MapStrayParts([single[]]$Room.V, $vf, $vc, $sk, [single]6, $doorXYZ.ToArray())
        for ($i = 0; $i -lt $np; $i++) { if ($stray[$i]) { [void]$skipPart.Add($i) } }
    } catch { }
    # ...and the dark FLAT sheets (a material with no texture, near black: occluders hiding what lies beyond -- MINEMAZE's
    # 'black' planes), which are no shape of the room
    $darkTex = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        $palB = [IO.File]::ReadAllBytes('C:\Games\RaptorMod\cache\azrael-palette.pal'); $palK = $(if (($palB | Measure-Object -Maximum).Maximum -le 63) { 4 } else { 1 })
        for ($k = 0; $k -lt $Room.Texes.Count; $k++) {
            $tx = $Room.Texes[$k]; if (-not $tx -or $tx.W -ne 1 -or $tx.H -ne 1) { continue }
            $ci = [int]$tx.Idx[0] * 3; if ($ci + 2 -ge $palB.Length) { continue }
            if ((0.3 * $palB[$ci] + 0.59 * $palB[$ci + 1] + 0.11 * $palB[$ci + 2]) * $palK -lt 40) { [void]$darkTex.Add($k) }
        }
    } catch { }
    $tris = New-Object 'System.Collections.Generic.List[int]'
    $tp = $Room.TriPart; $ti = $Room.TexIdx
    # (the per-triangle rules: which textures a room's "hideMaterials" names, and its "hideBelow")
    $matHit = New-Object 'System.Collections.Generic.HashSet[int]'; $texFile = @{}; $texNames = @{}
    $partScoped = @($hideMat.Keys | Where-Object { $_ -notlike '*||*' }).Count -gt 0
    if ($hideMat.Count) {      # (the textures' names, and which a room-wide entry hides)
        $tn = Get-AztTexNames -Files $Files -CacheDir $CacheDir
        # (a unit can end with a spare 1x1 texture no triangle uses -- MINEHEAD's 49th -- so a single room may have more)
        $lineUp = $tn.Count -eq $Room.Texes.Count -or ($Files.Count -eq 1 -and $tn.Count -lt $Room.Texes.Count -and @($Room.Texes | Select-Object -Skip $tn.Count | Where-Object { $_.W -ne 1 -or $_.H -ne 1 }).Count -eq 0)
        if ($lineUp) {
            # (which file each texture came from: the files' textures one after another)
            $fi = 0; $cnt = 0; $per = @(); foreach ($f in $Files) { $per += ,@($f.ToUpper(), (Get-AztTexNames -Files @($f) -CacheDir $CacheDir).Count) }
            for ($k = 0; $k -lt $tn.Count; $k++) {
                while ($fi -lt $per.Count -and $k -ge $cnt + $per[$fi][1]) { $cnt += $per[$fi][1]; $fi++ }
                $F = $(if ($fi -lt $per.Count) { $per[$fi][0] } else { '' })
                $texFile[$k] = $F; $texNames[$k] = @($tn[$k].Mat, $tn[$k].Leaf)
                if ($hideMat.ContainsKey($F + '||' + $tn[$k].Mat) -or $hideMat.ContainsKey($F + '||' + $tn[$k].Leaf)) { [void]$matHit.Add($k) }
            }
        } else { $script:AztMapSkipNote = ('map: the texture names of {0} do not line up ({1} named, {2} textures) -- its hideMaterials are not applied' -f ($Files -join '+'), $tn.Count, $Room.Texes.Count) }
    }
    $V = $Room.V; $T = $Room.T
    for ($tq = 0; $tq -lt $tp.Length; $tq++) {
        if ($skipPart.Contains([int]$tp[$tq]) -or ($tq -lt $ti.Length -and $darkTex.Contains([int]$ti[$tq]))) { $tris.Add($tq); continue }
        if ($matHit.Count -eq 0 -and $below.Count -eq 0 -and -not $partScoped -and $boxes.Count -eq 0) { continue }
        $pt = $Room.Parts[[int]$tp[$tq]]; $F = ([string]$pt.Room).ToUpper()
        if ($boxes.Count) {
            $mx = 0.0; $my = 0.0; $mz = 0.0; for ($c = 0; $c -lt 3; $c++) { $vi = [int]$T[$tq * 3 + $c] * 3; $mx += $V[$vi]; $my += $V[$vi + 1]; $mz += $V[$vi + 2] }; $mx /= 3; $my /= 3; $mz /= 3
            $inBox = $false
            foreach ($bx in $boxes) {
                if ($bx[0] -ne $F -or ($bx[1] -and $bx[1] -ne [string]$pt.Name)) { continue }
                $q = $bx[2]; if ($mx -ge $q[0] -and $mx -le $q[3] -and $my -ge $q[1] -and $my -le $q[4] -and $mz -ge $q[2] -and $mz -le $q[5]) { $inBox = $true; break }
            }
            if ($inBox) { $tris.Add($tq); continue }
        }
        if ($keep.ContainsKey($F + '|' + [string]$pt.Name)) { continue }
        if ($tq -lt $ti.Length -and $matHit.Contains([int]$ti[$tq])) { $tris.Add($tq); continue }
        if ($partScoped -and $tq -lt $ti.Length -and $texNames.ContainsKey([int]$ti[$tq])) {
            $nm = $texNames[[int]$ti[$tq]]; $pk = $texFile[[int]$ti[$tq]] + '|' + [string]$pt.Name + '|'
            if ($hideMat.ContainsKey($pk + $nm[0]) -or $hideMat.ContainsKey($pk + $nm[1])) { $tris.Add($tq); continue }
        }
        if ($below.ContainsKey($F)) {
            $yb = $below[$F]; $all = $true
            for ($c = 0; $c -lt 3; $c++) { if ($V[[int]$T[$tq * 3 + $c] * 3 + 1] -ge $yb) { $all = $false; break } }
            if ($all) { $tris.Add($tq) }
        }
    }
    return ,$tris.ToArray()
}
# THE MAP CUT UNDER THE FLOOR (Josh, 2026-10-14, Room Review MINEHEAD/8+9): a room's "map": { "hideBelow": y, "keep": [parts] } --
# the map clips every triangle not in "keep" at y (GpuRaster.SetMapCut / ClipMapBelow): walls that run on down under the floor end at
# it. $null when the room has no cut; else @{ Y = the height; Tris = per triangle of $Room, true = cut it }. (Get-AztMapSkip also
# drops what is WHOLLY under it, so the complex's rooms lose that much even where they are not clipped.)
function Get-AztMapCut($Room, [string[]]$Files, [string]$CacheDir = 'C:\Games\RaptorMod\cache') {
    $y = $null; $keep = @{}; $cutFiles = @{}
    foreach ($f in $Files) {
        $rp = Join-Path (Join-Path $CacheDir 'rooms') ($f.ToUpper() + '.json')
        if (-not (Test-Path $rp)) { continue }
        try {
            $rj = [IO.File]::ReadAllText($rp) | ConvertFrom-Json
            if ($null -eq $rj.map -or $null -eq $rj.map.hideBelow) { continue }
            if ($null -eq $y) { $y = [double]$rj.map.hideBelow }
            $cutFiles[$f.ToUpper()] = 1
            foreach ($kn in @($rj.map.keep)) { if ($kn) { $keep[$f.ToUpper() + '|' + [string]$kn] = 1 } }
        } catch { }
    }
    if ($null -eq $y) { return $null }
    $tp = $Room.TriPart; $flags = New-Object bool[] $tp.Length
    for ($tq = 0; $tq -lt $tp.Length; $tq++) {
        $pt = $Room.Parts[[int]$tp[$tq]]; $rf = ([string]$pt.Room).ToUpper()
        $flags[$tq] = $cutFiles.ContainsKey($rf) -and -not $keep.ContainsKey($rf + '|' + [string]$pt.Name)
    }
    return @{ Y = [single]$y; Tris = $flags }
}
$script:AztPortalMap = $null; $script:AztPortalMapStamp = $null; $script:AztPortalNotes = @()
# THE WHOLE COMPLEX (Josh, 2026-10-14: "from a room's 3D map, zoom out to every room you've visited, laid out in place and
# linked by their doorways ... unvisited rooms stay as faint outlines"). Every room file is modelled round its own origin;
# portals.json's 'm' carries the far room's geometry into this room's coordinates through each doorway (row vectors,
# translation in [12..14]). From the current room outward through the VISITED rooms (a breadth-first spanning tree -- the
# graph has loops, the first way found wins), each room placed by m x (its parent's placement); a visited room's neighbours
# that were never visited are placed too, faint (group 2), and not walked through. The rooms' map geometry (as the room's
# own map: doorway pictures, characters, occluders and strays left out -- Get-AztMapSkip) is kept per room once read.
$script:AztComplexGeo = @{}
function Get-AztComplexGeo([string]$Name, [string]$CacheDir = 'C:\Games\RaptorMod\cache') {
    $k = $Name.ToUpperInvariant()
    $rjp = Join-Path (Join-Path $CacheDir 'rooms') ($k + '.json'); if (Test-Path $rjp) { $k += '@' + (Get-Item $rjp).LastWriteTimeUtc.Ticks }
    $pkf = Join-Path $CacheDir 'pickups.json'; if (Test-Path $pkf) { $k += '#' + (Get-Item $pkf).LastWriteTimeUtc.Ticks }      # (the pick-ups learned: read again)      # (its map settings changed: read again)
    if ($null -eq $script:AztComplexGeo) { $script:AztComplexGeo = @{} }      # (a caller that took only the functions)
    if ($script:AztComplexGeo.ContainsKey($k)) { return $script:AztComplexGeo[$k] }
    $geo = $null
    try {
        $r = Import-AztRoom -Rooms @($Name) -CacheDir $CacheDir
        $skip = New-Object 'System.Collections.Generic.HashSet[int]'
        $sk = Get-AztMapSkip -Room $r -Files @($Name) -CacheDir $CacheDir      # (one int[]: it returns ,$list)
        foreach ($t in $sk) { foreach ($u in @($t)) { [void]$skip.Add([int]$u) } }
        $keep = New-Object 'System.Collections.Generic.List[int]'
        $nt = [int]($r.T.Length / 3)
        $rv = $r.V
        for ($t = 0; $t -lt $nt; $t++) {
            if ($r.TexIdx[$t] -lt 0 -or $skip.Contains($t)) { continue }
            $i0 = $r.T[$t * 3] * 3; $i1 = $r.T[$t * 3 + 1] * 3; $i2 = $r.T[$t * 3 + 2] * 3
            # (backdrop planes far bigger than a room -- MINEHEAD's, TRACK01's -- would swamp the complex: edges over 1200 left out)
            $e1 = [Math]::Abs($rv[$i0] - $rv[$i1]) + [Math]::Abs($rv[$i0 + 1] - $rv[$i1 + 1]) + [Math]::Abs($rv[$i0 + 2] - $rv[$i1 + 2]); $e2 = [Math]::Abs($rv[$i1] - $rv[$i2]) + [Math]::Abs($rv[$i1 + 1] - $rv[$i2 + 1]) + [Math]::Abs($rv[$i1 + 2] - $rv[$i2 + 2]); $e3 = [Math]::Abs($rv[$i2] - $rv[$i0]) + [Math]::Abs($rv[$i2 + 1] - $rv[$i0 + 1]) + [Math]::Abs($rv[$i2 + 2] - $rv[$i0 + 2])
            if ([Math]::Max($e1, [Math]::Max($e2, $e3)) -gt 1500) { continue }
            $keep.Add($r.T[$t * 3]); $keep.Add($r.T[$t * 3 + 1]); $keep.Add($r.T[$t * 3 + 2])
        }
        $geo = @{ V = [single[]]$r.V; T = $keep.ToArray() }
        # (its cut under the floor, as its own map: the kept triangles clipped -- Get-AztMapCut)
        $mcut = Get-AztMapCut -Room $r -Files @($Name) -CacheDir $CacheDir
        if ($mcut) {
            $kt = $keep.ToArray(); $nk = [int]($kt.Length / 3); $fl = New-Object bool[] $nk; $tt0 = New-Object int[] $nk; $w = 0
            for ($t = 0; $t -lt $nt; $t++) {
                if ($w -ge $nk) { break }
                if ($r.T[$t * 3] -eq $kt[$w * 3] -and $r.T[$t * 3 + 1] -eq $kt[$w * 3 + 1] -and $r.T[$t * 3 + 2] -eq $kt[$w * 3 + 2]) { $fl[$w] = $mcut.Tris[$t]; $w++ }
            }
            $cv = $null; $ci = $null; $ct = $null
            [AztTool.GpuRaster]::ClipMapBelow([single[]]$r.V, [int[]]$kt, [int[]]$tt0, [bool[]]$fl, [single]$mcut.Y, [ref]$cv, [ref]$ci, [ref]$ct)
            $geo = @{ V = [single[]]$cv; T = [int[]]$ci }
        }
    } catch { $geo = $null; $script:AztComplexError = "{0}: {1}" -f $Name, $_.Exception.Message }
    $script:AztComplexGeo[$k] = $geo
    return $geo
}
function Get-AztComplex([string]$Root, [string[]]$Visited, [string]$CacheDir = 'C:\Games\RaptorMod\cache', [int]$MaxRooms = 80, [switch]$ShowUnvisited) {
    $mapPath = Join-Path $CacheDir 'portals.json'
    if (-not (Test-Path $mapPath)) { return $null }
    $stamp = (Get-Item $mapPath).LastWriteTimeUtc.Ticks
    if ($script:AztPortalMapStamp -ne $stamp) { $script:AztPortalMap = [IO.File]::ReadAllText($mapPath) | ConvertFrom-Json; $script:AztPortalMapStamp = $stamp }
    $vis = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($v in @($Visited)) { if ($v) { [void]$vis.Add($v.ToUpperInvariant()) } }
    $root = $Root.ToUpperInvariant()
    $placed = [ordered]@{}; $placed[$root] = [single[]]@(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
    $group = @{ $root = 0 }
    $queue = New-Object 'System.Collections.Generic.Queue[string]'; $queue.Enqueue($root)
    while ($queue.Count -gt 0 -and $placed.Count -lt $MaxRooms) {
        $a = $queue.Dequeue(); $ma = $placed[$a]
        $prop = $script:AztPortalMap.PSObject.Properties[$a]; if (-not $prop) { continue }
        foreach ($e in @($prop.Value)) {
            $b = ([string]$e.to).ToUpperInvariant(); if (-not $b -or $placed.Contains($b) -or -not $e.m -or @($e.m).Count -ne 16) { continue }
            $m = [single[]]@($e.m)
            $c = New-Object single[] 16
            for ($i = 0; $i -lt 4; $i++) { for ($j = 0; $j -lt 4; $j++) { $sum = 0.0; for ($q = 0; $q -lt 4; $q++) { $sum += $m[$i * 4 + $q] * $ma[$q * 4 + $j] }; $c[$i * 4 + $j] = [single]$sum } }
            $placed[$b] = $c
            # (only the rooms the player has reached -- Josh, 2026-10-14: the helmet scans a room as he enters it, so one not yet
            # entered is not on the map at all; the grey outlines of unvisited neighbours were too bright where they overlapped)
            if ($vis.Contains($b)) { $group[$b] = 1; $queue.Enqueue($b) } elseif ($ShowUnvisited) { $group[$b] = 2 } else { $placed.Remove($b) }
        }
    }
    $cxV = New-Object 'System.Collections.Generic.List[single]'; $cxT = New-Object 'System.Collections.Generic.List[int]'; $cxG = New-Object 'System.Collections.Generic.List[int]'      # (not $V/$T: $v and $t are the loops' -- one name in PowerShell)
    $names = @()
    foreach ($name in @($placed.Keys)) {
        if ($name -eq $root) { continue }
        $geo = Get-AztComplexGeo $name $CacheDir; if (-not $geo -or $geo.T.Length -eq 0) { continue }
        $mm = $placed[$name]; $base = [int]($cxV.Count / 3); $gv = $geo.V
        for ($i = 0; $i -lt $gv.Length; $i += 3) {
            $x = $gv[$i]; $y = $gv[$i + 1]; $z = $gv[$i + 2]
            $cxV.Add([single]($x * $mm[0] + $y * $mm[4] + $z * $mm[8] + $mm[12])); $cxV.Add([single]($x * $mm[1] + $y * $mm[5] + $z * $mm[9] + $mm[13])); $cxV.Add([single]($x * $mm[2] + $y * $mm[6] + $z * $mm[10] + $mm[14]))
        }
        foreach ($ix in $geo.T) { $cxT.Add($base + $ix) }
        for ($t = 0; $t -lt $geo.T.Length / 3; $t++) { $cxG.Add([int]$group[$name]) }
        $names += ('{0}{1}' -f $name, $(if ($group[$name] -eq 2) { '(faint)' } else { '' }))
    }
    return @{ V = $cxV.ToArray(); T = $cxT.ToArray(); G = $cxG.ToArray(); Rooms = $names }
}
function Get-AztPortals {
    param($Room, [string[]]$Files, [string]$CacheDir = 'C:\Games\RaptorMod\cache',
          [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX',
          [string]$Palette = 'C:\Games\RaptorMod\cache\azrael-palette.pal')
    $script:AztPortalNotes = @()
    $res = New-Object 'System.Collections.Generic.List[AztTool.Portal]'
    $mapPath = Join-Path $CacheDir 'portals.json'
    if (-not (Test-Path $mapPath)) { $script:AztPortalNotes += 'no portals.json -- run tools\Build-PortalMap.ps1'; return ,$res.ToArray() }
    $stamp = (Get-Item $mapPath).LastWriteTimeUtc.Ticks
    if ($script:AztPortalMapStamp -ne $stamp) {
        $script:AztPortalMap = [IO.File]::ReadAllText($mapPath) | ConvertFrom-Json
        $script:AztPortalMapStamp = $stamp
    }
    foreach ($f in $Files) {
        $prop = $script:AztPortalMap.PSObject.Properties[$f.ToUpper()]
        if (-not $prop) { continue }
        foreach ($e in @($prop.Value)) {
            if (-not $e.views -or @($e.views).Count -eq 0) { continue }
            if ($Files -contains [string]$e.to) { continue }
            try {
                $views = New-Object 'System.Collections.Generic.List[AztTool.PortalView]'
                foreach ($vn in @($e.views)) {
                    for ($i = 0; $i -lt $Room.Parts.Count; $i++) {
                        $p = $Room.Parts[$i]
                        # -ceq: object names are matched exactly as the files spell them
                        if ($p.IsCharacter -or $p.Name -cne [string]$vn -or ([string]$p.Room).ToUpper() -ne $f.ToUpper()) { continue }
                        $tl = New-Object 'System.Collections.Generic.List[int]'
                        $t = [Array]::IndexOf($Room.TriPart, $i)
                        while ($t -ge 0) { $tl.Add($t); $t = [Array]::IndexOf($Room.TriPart, $i, $t + 1) }
                        if ($tl.Count -eq 0) { break }
                        $w = New-Object AztTool.PortalView
                        $w.Part = $i; $w.VFirst = [int]$p.VFirst; $w.VCount = [int]$p.VCount
                        $w.Parked = (@($e.parked) -ccontains [string]$vn)
                        $w.Tris = $tl.ToArray(); $w.TriVerts = New-Object int[] ($tl.Count * 3)
                        for ($k = 0; $k -lt $tl.Count; $k++) { [Array]::Copy($Room.T, $tl[$k] * 3, $w.TriVerts, $k * 3, 3) }
                        $views.Add($w)
                        break
                    }
                }
                if ($views.Count -eq 0) { continue }
                $nb = Import-AztRoom -Rooms @([string]$e.to) -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette
                $po = New-Object AztTool.Portal
                $po.Zone = [string]$e.zone; $po.To = [string]$e.to
                $po.DoorX = [single]$e.door[0]; $po.DoorY = [single]$e.door[1]; $po.DoorZ = [single]$e.door[2]
                $po.Views = $views.ToArray()
                if ($e.farQuad -and @($e.farQuad).Count -eq 12) { $po.FarQuad = [single[]]@($e.farQuad | ForEach-Object { [single]$_ }) }
                $po.V = [AztTool.Portals]::Transform([single[]]$nb.V, [single[]]@($e.m | ForEach-Object { [single]$_ }))
                $po.UV = [single[]]$nb.UV; $po.T = [int[]]$nb.T; $po.TexIdx = [int[]]$nb.TexIdx.Clone(); $po.Texes = $nb.Texes
                # the far room's own pictures of THIS room stand in the plane the two tunnels
                # meet at, facing the other way: never drawn
                foreach ($fv in @($e.farViews)) {
                    for ($i = 0; $i -lt $nb.Parts.Count; $i++) {
                        if ($nb.Parts[$i].Name -cne [string]$fv) { continue }
                        $t = [Array]::IndexOf($nb.TriPart, $i)
                        while ($t -ge 0) { $po.TexIdx[$t] = -1; $t = [Array]::IndexOf($nb.TriPart, $i, $t + 1) }
                        break
                    }
                }
                [void][AztTool.Portals]::CullBehind($po.V, $po.T, $po.TexIdx, [single]$e.plane[0], [single]$e.plane[1], [single]$e.axis[0], [single]$e.axis[1])
                # the far room's own door at this doorway, so it can be taken away when the game
                # says it has been opened
                $dl = New-Object 'System.Collections.Generic.List[int]'
                foreach ($dn in @($e.farDoors)) {
                    for ($i = 0; $i -lt $nb.Parts.Count; $i++) {
                        if ($nb.Parts[$i].Name -cne [string]$dn) { continue }
                        $t = [Array]::IndexOf($nb.TriPart, $i)
                        while ($t -ge 0) { $dl.Add($t); $t = [Array]::IndexOf($nb.TriPart, $i, $t + 1) }
                        break
                    }
                }
                $po.DoorTris = $dl.ToArray(); $po.DoorTex = New-Object int[] $dl.Count
                for ($k = 0; $k -lt $dl.Count; $k++) { $po.DoorTex[$k] = $po.TexIdx[$dl[$k]] }
                $res.Add($po)
            } catch {
                $script:AztPortalNotes += ("doorway {0} -> {1} keeps its picture: {2}" -f $e.zone, $e.to, $_.Exception.Message)
            }
        }
    }
    return ,$res.ToArray()
}