# Export-XafObj.ps1 -- turn a .XAF straight into a textured Wavefront OBJ.
#
#   .\tools\Export-XafObj.ps1 -Xaf LURKA -OutDir C:\Games\azrael-models\lurka
#   .\tools\Export-XafObj.ps1 -Xaf LURKA -OutDir ... -Report      # inspect, write nothing
#
# This is the OFF-LINE route, and for a CHARACTER it is the right one. tools\Export-Obj.ps1
# reads AZTGEO.BIN, a dump of the live scene, which means the thing being exported has to be
# on screen at the time -- fine for a room, awkward for a creature. A .XAF holds the same
# geometry as plain text, in its REST POSE, with nothing needing to be running.
#
# THE ONE THING THAT MAKES THIS NON-TRIVIAL: .XAF OBJECTS NEST, AND THEIR MATRICES ARE LOCAL.
#
#     object "SBUM" {            <- pelvis, the rig root
#       matrix { ... }
#       mesh { ... }
#       object "STOPBODY" {      <- a CHILD frame; its matrix is relative to SBUM
#         matrix { ... }
#         object "SNECK" { object "head" { ... } }
#
# LURKA is five levels deep (SBUM > STOPBODY > STOPAR01 > SLOWARM01 > SHANDR01). Treat the
# 23 objects as a flat list and every limb lands on top of the pelvis. The world transform
# of a frame is the product of its own matrix and all its ancestors'.
#
# Reality Lab is ROW-VECTOR / row-major -- its own GetPosition reads translation from row 3 --
# so composition is child-then-parent:  W_child = M_child * W_parent,  and  v' = v * W.
# Doing it the other way round produces a model that is subtly, plausibly wrong.
#
# FACES are `count, v,n  v,n  v,n` with a trailing 0 terminating the list. The second number
# of each pair is a NORMAL index, not a UV index: texture_coordinates is parallel to
# vertices, so the UV index is the vertex index.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Xaf,
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$OutDir,
    [switch]$Report,
    [switch]$NoTextures,
    [switch]$NoFlipV,
    [switch]$Flat,           # ignore the hierarchy (diagnostic only -- produces a heap)
    [switch]$IfStale         # skip if the cached OBJ is already at $OBJ_VERSION
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -AssemblyName System.Drawing

# CACHE VERSION -- bump whenever a change here alters the OBJ.
#
# Four scripts cache these OBJs and every one of them tested only `Test-Path`, so a fixed
# exporter kept being ignored in favour of a stale file. (tools\LoadRoom.ps1 was written to
# be the single copy of these rules, but nothing was ever switched over to it, so the test
# lived in four places.) The alternative -- deleting the cache by hand -- is what destroyed
# the engine reference frames in ref\, which can only be recaptured with the game running.
# Callers now pass -IfStale unconditionally and the decision is made here, once.
$OBJ_VERSION = '# xafobj-version 4'    # 4: textureless materials are written to the .mtl with their colour and alpha

$stem = $Xaf -replace '\.(XAF|RES)$',''
$xafPath = if (Test-Path $Xaf) { $Xaf } else { Join-Path $TexDir "$stem.XAF" }
if (-not (Test-Path $xafPath)) { throw "no such .XAF: $xafPath" }
if (-not $OutDir) { $OutDir = Join-Path 'C:\Games\azrael-models' $stem.ToLower() }

if ($IfStale) {
    $cached = Join-Path $OutDir "$stem.obj"
    if (Test-Path $cached) {
        $head = @(Get-Content $cached -TotalCount 1)
        if ($head.Count -and $head[0] -eq $OBJ_VERSION) { return }
    }
}

$text = [IO.File]::ReadAllText($xafPath)
Write-Host ("{0}: {1:N0} bytes" -f (Split-Path $xafPath -Leaf), $text.Length)

# ---- helpers ----------------------------------------------------------------
function MatchBrace {
    <# index of the '}' matching the '{' at $open #>
    param([string]$s, [int]$open)
    $d = 0
    for ($i = $open; $i -lt $s.Length; $i++) {
        if ($s[$i] -eq '{') { $d++ }
        elseif ($s[$i] -eq '}') { $d--; if ($d -eq 0) { return $i } }
    }
    throw "unbalanced braces from $open"
}
function BlockBody {
    <# body text of the first `<kw> {` at or after $from, or $null #>
    param([string]$s, [string]$kw, [int]$from, [int]$limit)
    $m = [regex]::Match($s.Substring($from, $limit - $from), ('(?m)^\s*' + $kw + '\s*\{'))
    if (-not $m.Success) { return $null }
    $open = $from + $m.Index + $m.Value.LastIndexOf('{')
    $close = MatchBrace $s $open
    if ($close -gt $limit) { return $null }
    return @{ Body = $s.Substring($open+1, $close-$open-1); Start = $open; End = $close }
}
function Floats { param([string]$s)
    @([regex]::Matches($s, '-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?') | ForEach-Object { [double]$_.Value }) }
function Ints { param([string]$s)
    @([regex]::Matches($s, '-?\d+') | ForEach-Object { [int]$_.Value }) }

# row-vector: v' = v * M
function XformPoint { param([double]$x, [double]$y, [double]$z, $M)
    # every element parenthesised: PowerShell's comma binds tighter than '+', so bare sums
    # inside @() parse as an array and the addition then fails on Object[]
    @( ($x*$M[0] + $y*$M[4] + $z*$M[8]  + $M[12]),
       ($x*$M[1] + $y*$M[5] + $z*$M[9]  + $M[13]),
       ($x*$M[2] + $y*$M[6] + $z*$M[10] + $M[14]) ) }
function XformDir { param([double]$x, [double]$y, [double]$z, $M)
    @( ($x*$M[0] + $y*$M[4] + $z*$M[8] ),
       ($x*$M[1] + $y*$M[5] + $z*$M[9] ),
       ($x*$M[2] + $y*$M[6] + $z*$M[10]) ) }
# W_child = M_child * W_parent   (row-vector composition)
#
# The accumulator is $res, NOT $R: PowerShell variable names are case-insensitive, so $R
# and the row counter $r are the same variable and the loop's first assignment turned the
# matrix into an Int32. It fails as "Unable to index into an object of type System.Int32"
# pointing at the assignment, which is nowhere near the real cause.
function MatMul { param($A, $B)
    $res = New-Object 'double[]' 16
    for ($row = 0; $row -lt 4; $row++) {
        for ($col = 0; $col -lt 4; $col++) {
            $s = 0.0
            for ($k = 0; $k -lt 4; $k++) { $s += $A[$row*4+$k] * $B[$k*4+$col] }
            $res[$row*4+$col] = $s
        }
    }
    ,$res }
$IDENT = @(1.0,0,0,0, 0,1.0,0,0, 0,0,1.0,0, 0,0,0,1.0)

# ---- material -> texture file ------------------------------------------------
$matTex = @{}
foreach ($m in [regex]::Matches($text, 'material\s+"([^"]+)"\s*\{([^}]*)\}', 'IgnoreCase')) {
    $t = [regex]::Match($m.Groups[2].Value, 'texture\s+"([^"]+)"')
    if ($t.Success) { $matTex[$m.Groups[1].Value] = ((($t.Groups[1].Value -split '[\\/]')[-1]) -replace '\.(azf|gif)$','') }
}
# textures in FIRST-APPEARANCE order -- this, not any name in the file, is what maps a
# .RES record to a texture, because a .RES carries no names or index of its own
$texOrder = New-Object System.Collections.ArrayList
foreach ($m in [regex]::Matches($text, 'texture\s+"([^"]+)"', 'IgnoreCase')) {
    $leaf = (($m.Groups[1].Value -split '[\\/]')[-1]) -replace '\.(azf|gif)$',''
    if (-not $texOrder.Contains($leaf)) { [void]$texOrder.Add($leaf) }
}
Write-Host ("  {0} materials, {1} distinct textures: {2}" -f $matTex.Count, $texOrder.Count, ($texOrder -join ', '))

# ---- walk the object tree ----------------------------------------------------
$nodes = New-Object System.Collections.ArrayList

function ParseObject {
    param([string]$name, [int]$bodyStart, [int]$bodyEnd, $parentWorld, [int]$depth, [string]$parentName)

    # direct children start at the first nested `object "` inside this body; everything
    # before that belongs to THIS object
    $childMatches = @()
    $scan = $bodyStart
    while ($true) {
        $m = [regex]::Match($script:text.Substring($scan, $bodyEnd - $scan), 'object\s+"([^"]+)"\s*\{')
        if (-not $m.Success) { break }
        $oStart = $scan + $m.Index
        $open = $oStart + $m.Value.LastIndexOf('{')
        $close = MatchBrace $script:text $open
        $childMatches += ,@($m.Groups[1].Value, ($open+1), $close)
        $scan = $close + 1
        if ($scan -ge $bodyEnd) { break }
    }
    $ownEnd = if ($childMatches.Count) { $childMatches[0][1] } else { $bodyEnd }

    $mb = BlockBody $script:text 'matrix' $bodyStart $ownEnd
    $local = if ($mb) { @(Floats $mb.Body) } else { $IDENT }
    if ($local.Count -lt 16) { $local = $IDENT }
    $world = if ($Flat) { ,@($local) } else { MatMul $local $parentWorld }

    $meshB = BlockBody $script:text 'mesh' $bodyStart $ownEnd
    $verts = @(); $norms = @(); $uvs = @(); $faces = @(); $mat = ''; $faceMats = @()
    if ($meshB) {
        $ms = $meshB.Start; $me = $meshB.End
        $vb = BlockBody $script:text 'vertices'            $ms $me
        $nb = BlockBody $script:text 'normals'             $ms $me
        $tb = BlockBody $script:text 'texture_coordinates' $ms $me
        $fb = BlockBody $script:text 'faces'               $ms $me
        if ($vb) { $f = Floats $vb.Body; for ($i = 0; $i+2 -lt $f.Count; $i += 3) { $verts += ,@($f[$i],$f[$i+1],$f[$i+2]) } }
        if ($nb) { $f = Floats $nb.Body; for ($i = 0; $i+2 -lt $f.Count; $i += 3) { $norms += ,@($f[$i],$f[$i+1],$f[$i+2]) } }
        if ($tb) { $f = Floats $tb.Body; for ($i = 0; $i+1 -lt $f.Count; $i += 2) { $uvs   += ,@($f[$i],$f[$i+1]) } }
        if ($fb) {
            $ii = Ints $fb.Body; $p = 0
            while ($p -lt $ii.Count) {
                $n = $ii[$p]; $p++
                if ($n -le 0) { break }              # 0 terminates the face list
                if ($p + 2*$n -gt $ii.Count) { break }
                $corner = @()
                for ($k = 0; $k -lt $n; $k++) { $corner += ,@($ii[$p+$k*2], $ii[$p+$k*2+1]) }
                $p += 2*$n
                $faces += ,$corner
            }
        }
        $mm = [regex]::Match($script:text.Substring($ms, $me-$ms), 'material\s+"([^"]+)"')
        if ($mm.Success) { $mat = $mm.Groups[1].Value }
        # A MESH CAN BE MULTI-MATERIAL. Alongside `material "NAME"` there is an optional
        # `face_materials { "NAME", "NAME", ... }` -- one quoted name per face, in face
        # order, and such a mesh carries NO mesh-level material at all. Reading only the
        # single `material` dropped every one of them to the flat fallback ink: 31,980
        # faces corpus-wide, 24.1% of all visible geometry, including CHIMNEY's exit door
        # (`chi_xitdor`, 6 faces 1CHIM_END + 2 1GRAILDOOR) and the `stuff` meshes that
        # hold each room's props -- 1,369 faces of them in PULPIT2 alone.
        $fmb = BlockBody $script:text 'face_materials' $ms $me
        if ($fmb) { $faceMats = @([regex]::Matches($fmb.Body, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) }
    }

    [void]$script:nodes.Add([pscustomobject]@{
        Name = $name; Parent = $parentName; Depth = $depth
        Verts = $verts; Norms = $norms; UVs = $uvs; Faces = $faces
        Material = $mat; FaceMats = $faceMats; World = $world })

    foreach ($c in $childMatches) { ParseObject $c[0] $c[1] $c[2] $world ($depth+1) $name }
}

# roots: top-level `object` blocks
$scan = 0
$roots = 0
while ($true) {
    $m = [regex]::Match($text.Substring($scan), 'object\s+"([^"]+)"\s*\{')
    if (-not $m.Success) { break }
    $open = $scan + $m.Index + $m.Value.LastIndexOf('{')
    $close = MatchBrace $text $open
    ParseObject $m.Groups[1].Value ($open+1) $close $IDENT 0 ''
    $roots++
    $scan = $close + 1
    if ($scan -ge $text.Length) { break }
}
$nodes = @($nodes)
Write-Host ("  {0} objects in {1} root(s), max depth {2}" -f $nodes.Count, $roots,
            (($nodes | Measure-Object Depth -Maximum).Maximum))

$totV = ($nodes | ForEach-Object { $_.Verts.Count } | Measure-Object -Sum).Sum
$totF = ($nodes | ForEach-Object { $_.Faces.Count } | Measure-Object -Sum).Sum
Write-Host ("  {0:N0} vertices, {1:N0} faces" -f $totV, $totF)

Write-Host "`nhierarchy (world translation after composing the chain):"
foreach ($n in $nodes) {
    $w = $n.World
    $mdesc = $(if ($n.FaceMats.Count) {
        "per-face: {0} across {1} faces" -f @($n.FaceMats | Sort-Object -Unique).Count, $n.FaceMats.Count
    } else { $n.Material })
    Write-Host ("  {0}{1,-12} {2,4} v {3,4} f  at {4,8:N2} {5,8:N2} {6,8:N2}  {7}" -f `
        ('  ' * $n.Depth), $n.Name, $n.Verts.Count, $n.Faces.Count, $w[12], $w[13], $w[14], $mdesc)
}

# a rig assembled with the composition the wrong way round collapses onto the root, so
# the spread of the part origins is a real check, not decoration
$xs = @($nodes | ForEach-Object { $_.World[12] }); $ys = @($nodes | ForEach-Object { $_.World[13] }); $zs = @($nodes | ForEach-Object { $_.World[14] })
Write-Host ("`npart origins span  X {0:N2}..{1:N2}   Y {2:N2}..{3:N2}   Z {4:N2}..{5:N2}" -f `
    ($xs|Measure-Object -Minimum).Minimum, ($xs|Measure-Object -Maximum).Maximum,
    ($ys|Measure-Object -Minimum).Minimum, ($ys|Measure-Object -Maximum).Maximum,
    ($zs|Measure-Object -Minimum).Minimum, ($zs|Measure-Object -Maximum).Maximum)

if ($Report) { Write-Host "`n-Report given: nothing written."; return }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# ---- textures ----------------------------------------------------------------
# '#' MARKS A CHROMA-KEYED TEXTURE and is also the COMMENT character in OBJ/MTL, so a
# map_Kd line naming the file verbatim would be truncated at the '#'. Keyed textures are
# therefore written as RGBA with magenta punched to alpha 0 and a '#'-free name.
$matPng = @{}
if (-not $NoTextures) {
    $resPath = Join-Path $TexDir "$stem.RES"
    $origRes = "$resPath.orig"
    $srcRes = if (Test-Path $origRes) { $origRes } else { $resPath }
    if (Test-Path $srcRes) {
        if (-not ("AztTool.Azf" -as [type])) { Add-Type -Path (Join-Path $toolDir 'AzfTool.cs') -ReferencedAssemblies System.Drawing }
        $texs = [AztTool.Azf]::Read($srcRes)
        for ($i = 0; $i -lt $texs.Count -and $i -lt $texOrder.Count; $i++) {
            $t = $texs[$i]
            if (-not $t.Decoded) { Write-Host ("  texture {0} ({1}) does not decode -- skipped" -f $i, $texOrder[$i]) -ForegroundColor Yellow; continue }
            $raw = $texOrder[$i]
            $keyed = $raw -match '#'
            $safe = ($raw -replace '#','_key') -replace '[^A-Za-z0-9_.-]','_'
            $png = "{0:d2}-{1}.png" -f $i, $safe
            $bmp = New-Object System.Drawing.Bitmap($t.Width, $t.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$t.Width,$t.Height)),
                    [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $px = New-Object 'int[]' ($t.Width*$t.Height)
            for ($y = 0; $y -lt $t.Height; $y++) {
                for ($x = 0; $x -lt $t.Width; $x++) {
                    $c = $t.Pixels[$y*$t.BytesPerLine + $x]
                    # [int] is load-bearing: PowerShell's -shl keeps the LEFT operand's
                    # type, so shifting a byte by 16 yields 0 and red/green vanish
                    $r = [int]$t.Palette[$c*4]; $g = [int]$t.Palette[$c*4+1]; $b = [int]$t.Palette[$c*4+2]
                    $a = 255
                    if ($keyed -and $r -gt 200 -and $g -lt 60 -and $b -gt 200) { $a = 0 }
                    $px[$y*$t.Width+$x] = (($a -shl 24) -bor ($r -shl 16) -bor ($g -shl 8) -bor $b)
                }
            }
            [System.Runtime.InteropServices.Marshal]::Copy($px, 0, $d.Scan0, $px.Length)
            $bmp.UnlockBits($d)
            $bmp.Save((Join-Path $OutDir $png), [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            foreach ($k in $matTex.Keys) { if ($matTex[$k] -eq $raw) { $matPng[$k] = @{ Png = $png; Keyed = $keyed } } }
            Write-Host ("  texture {0,2} {1,-10} {2}x{3} -> {4}{5}" -f $i, $raw, $t.Width, $t.Height, $png, $(if ($keyed) { '  [keyed -> alpha]' } else { '' }))
        }
    } else {
        Write-Host ("no {0}.RES -- the OBJ will have no materials" -f $stem) -ForegroundColor Yellow
    }
}

# ---- write the OBJ -----------------------------------------------------------
$obj = New-Object System.Collections.ArrayList
[void]$obj.Add($OBJ_VERSION)     # must be line 1 -- see -IfStale above
[void]$obj.Add(("# Azrael's Tear -- {0} exported from {1}.XAF by AztMod" -f $stem, $stem))
[void]$obj.Add("# " + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
[void]$obj.Add(("# {0} objects, rest pose, local matrices composed down the hierarchy" -f $nodes.Count))
if ($matPng.Count) { [void]$obj.Add("mtllib $stem.mtl") }

# PARTS SIDECAR: every object's name, its vertex range, and its REST world matrix.
#
# The vertices written below are posed -- the hierarchy is composed into them -- which freezes
# the room in its rest state. That is why doors never open, picked-up items keep being drawn
# and anything the engine moves stays put: nothing downstream can tell one object from
# another, let alone re-pose it.
#
# This records the ranges and the rest matrix alongside, so a renderer that reads the LIVE
# scene graph can substitute the engine's current world matrix per object. Written always
# (it is a few KB) so no second export pass is needed, and the posed OBJ is unchanged for
# every existing consumer.
$objParts = New-Object System.Collections.ArrayList
$vCur = 0

$vBase = 1; $tBase = 1; $nBase = 1; $tris = 0; $dropped = 0
foreach ($n in $nodes) {
    if (-not $n.Verts.Count) { continue }
    $safe = $n.Name -replace '[^A-Za-z0-9_.-]','_'
    [void]$obj.Add("")
    [void]$obj.Add("o $safe")
    # The LIVE graph names objects exactly as the .XAF does, so $n.Name is the join key --
    # not $safe, which has had characters replaced for OBJ's benefit.
    [void]$objParts.Add([pscustomobject]@{
        name = $n.Name; vFirst = $vCur; vCount = $n.Verts.Count
        rest = @($n.World | ForEach-Object { [double]$_ })
    })
    $vCur += $n.Verts.Count
    foreach ($v in $n.Verts) {
        $p = if ($Flat) { $v } else { XformPoint $v[0] $v[1] $v[2] $n.World }
        [void]$obj.Add(("v {0:F6} {1:F6} {2:F6}" -f $p[0], $p[1], $p[2]))
    }
    foreach ($t in $n.UVs) {
        # OBJ puts v=0 at the BOTTOM; the game's textures are stored top-down
        $vv = if ($NoFlipV) { $t[1] } else { 1.0 - $t[1] }
        [void]$obj.Add(("vt {0:F6} {1:F6}" -f $t[0], $vv))
    }
    foreach ($nr in $n.Norms) {
        $d = if ($Flat) { $nr } else { XformDir $nr[0] $nr[1] $nr[2] $n.World }
        $len = [Math]::Sqrt($d[0]*$d[0] + $d[1]*$d[1] + $d[2]*$d[2]); if ($len -le 0) { $len = 1 }
        [void]$obj.Add(("vn {0:F6} {1:F6} {2:F6}" -f ($d[0]/$len), ($d[1]/$len), ($d[2]/$len)))
    }
    # OBJ carries per-face materials by re-emitting `usemtl` between face groups, so the
    # multi-material meshes need no new format -- only that the name be re-checked per
    # face. A mesh-level material is emitted once up front, as before.
    $curMtl = $null
    if (-not $n.FaceMats.Count -and $n.Material) { [void]$obj.Add("usemtl $($n.Material)"); $curMtl = $n.Material }

    $hasUV = $n.UVs.Count -eq $n.Verts.Count
    $fi = -1
    foreach ($f in $n.Faces) {
        # advanced for EVERY face, including dropped ones: face_materials is parallel to
        # the face list, so skipping the increment would shift every later face's material
        $fi++
        $want = $(if ($fi -lt $n.FaceMats.Count) { $n.FaceMats[$fi] } else { $n.Material })
        $parts = @(); $ok = $true
        foreach ($c in $f) {
            $vi = $c[0]; $ni = $c[1]
            if ($vi -lt 0 -or $vi -ge $n.Verts.Count) { $ok = $false; break }
            $s = [string]($vBase + $vi)
            if ($hasUV) { $s += '/' + ($tBase + $vi) } else { $s += '/' }
            if ($ni -ge 0 -and $ni -lt $n.Norms.Count) { $s += '/' + ($nBase + $ni) }
            $parts += $s
        }
        if (-not $ok -or $parts.Count -lt 3) { $dropped++; continue }
        if ($want -and $want -ne $curMtl) { [void]$obj.Add("usemtl $want"); $curMtl = $want }
        # fan-triangulate anything with more than 3 corners
        for ($k = 1; $k -lt $parts.Count - 1; $k++) {
            [void]$obj.Add(("f {0} {1} {2}" -f $parts[0], $parts[$k], $parts[$k+1]))
            $tris++
        }
    }
    $vBase += $n.Verts.Count; $tBase += $n.UVs.Count; $nBase += $n.Norms.Count
}

$partsPath = Join-Path $OutDir "$stem.parts.json"
[IO.File]::WriteAllText($partsPath, (ConvertTo-Json @($objParts) -Depth 4 -Compress))
Write-Host ("wrote {0}  ({1} objects with rest matrices)" -f $partsPath, $objParts.Count)

$objPath = Join-Path $OutDir "$stem.obj"
[IO.File]::WriteAllLines($objPath, $obj)
Write-Host ("`nwrote {0}  ({1:N0} triangles, {2} dropped)" -f $objPath, $tris, $dropped) `
           -ForegroundColor $(if ($dropped -eq 0) { 'Green' } else { 'Yellow' })

if ($matPng.Count) {
    $mtl = New-Object System.Collections.ArrayList
    [void]$mtl.Add("# materials for $stem")
    foreach ($k in ($matPng.Keys | Sort-Object)) {
        [void]$mtl.Add("")
        [void]$mtl.Add("newmtl $k")
        [void]$mtl.Add("Ka 1.000 1.000 1.000")
        [void]$mtl.Add("Kd 1.000 1.000 1.000")
        [void]$mtl.Add("Ks 0.000 0.000 0.000")
        [void]$mtl.Add("d 1.0")
        # the engine does NO lighting -- every vertex colour is white and the Material
        # objects are empty, so the art is emission-only. illum 1 is the closest OBJ gets.
        [void]$mtl.Add("illum 1")
        [void]$mtl.Add("map_Kd $($matPng[$k].Png)")
        if ($matPng[$k].Keyed) { [void]$mtl.Add("map_d $($matPng[$k].Png)") }
    }
    # ---- MATERIALS WITH NO TEXTURE, written with what the .XAF says about them ----------
    # They used to be left out of the .mtl altogether, so every consumer had to guess, and
    # the host renderer guessed "paint it a neutral grey". The file is explicit instead:
    #
    #     material "BLACKMATTE"   { texture ""  colour { 0, 0, 0, 1 } }   <- solid black
    #     material "CLEAR_OBJECT" { texture ""  colour { 0, 0, 0, 0 } }   <- not drawn
    #
    # The fourth colour component is alpha. Across the corpus 106 textureless materials have
    # alpha 0 (trigger volumes and placeholders: TRANSPARANT, CLEAR_OBJECT, ATRANNIE...) and
    # the rest have alpha 1 and a real colour -- the Raptor's black suit is 181 of its 504
    # triangles. So: Kd is the colour, d is the alpha, and no map_Kd means "flat".
    $nFlatMat = 0
    foreach ($m in [regex]::Matches($text, '(?s)material\s+"([^"]+)"\s*\{(.*?)\n\}')) {
        $nm = $m.Groups[1].Value
        if ($matPng.ContainsKey($nm)) { continue }
        if ([regex]::Match($m.Groups[2].Value, 'texture\s+"([^"]+)"').Success) { continue }   # has art that failed to load: leave to the fallback
        $c = @([regex]::Match($m.Groups[2].Value, 'colour\s*\{([^}]*)\}').Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($c.Count -lt 4) { continue }
        [void]$mtl.Add("")
        [void]$mtl.Add("newmtl $nm")
        [void]$mtl.Add(("Kd {0:F4} {1:F4} {2:F4}" -f [double]$c[0], [double]$c[1], [double]$c[2]))
        [void]$mtl.Add(("d {0:F1}" -f [double]$c[3]))
        $nFlatMat++
    }
    $mtlPath = Join-Path $OutDir "$stem.mtl"
    [IO.File]::WriteAllLines($mtlPath, $mtl)
    Write-Host ("wrote {0}  ({1} materials)" -f $mtlPath, $matPng.Count)
}

Write-Host ""
Write-Host "IN BLENDER: the OBJ importer's default 'Y up' puts the game's Y-up into a Z-up" -ForegroundColor Cyan
Write-Host "scene by rotating the OBJECT, not the mesh data -- so the vertices you read in" -ForegroundColor Cyan
Write-Host "Python are still in GAME coordinates. Apply the rotation, or read world_matrix." -ForegroundColor Cyan
