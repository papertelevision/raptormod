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
        [string]$RefDir   = 'C:\Games\azrael-render\ref',
        [string]$CacheDir = 'C:\Games\azrael-render',
        [string]$TexDir   = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
        [string]$Palette  = 'C:\Games\azrael-inject\azrael-palette.pal',
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
    $artOf = @{}; $twinErr = ''; $nTwin = 0
    if ($haveOv) {
        $twin = $null; try { $twin = Get-AztTwinArt $CacheDir $OverrideDir } catch { $twinErr = $_.Exception.Message }
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
    return [pscustomobject]@{ FromFile = $fromFile; FromPalette = $fromPal; Bad = $bad; Replaced = $replaced; Companions = $mats; CompanionErrors = $matErr; Twins = $nTwin; TwinError = $twinErr }
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
        [string]$RefDir   = 'C:\Games\azrael-render\ref',
        [string]$CacheDir = 'C:\Games\azrael-render',
        [string]$TexDir   = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
        [string]$Palette  = 'C:\Games\azrael-inject\azrael-palette.pal',
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
$script:AztPortalMap = $null; $script:AztPortalMapStamp = $null; $script:AztPortalNotes = @()
function Get-AztPortals {
    param($Room, [string[]]$Files, [string]$CacheDir = 'C:\Games\azrael-render',
          [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
          [string]$Palette = 'C:\Games\azrael-inject\azrael-palette.pal')
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