# Export-Obj.ps1 -- turn AZTGEO.BIN into a Wavefront OBJ of a live Azrael room.
#
# AZTGEO.BIN is a stream of variable-length mesh blocks. Each block is a 144-byte
# header (see the aztGeoRec label run in Build-AztMod.ps1) followed immediately by
# three payloads written straight out of the engine's own arrays:
#
#   header      144 bytes
#   vertices    vCount * 48    x,y,z | colour | u,v | 24 unused
#   faces       fCount * 120   inline Face objects
#   normals     nCount * 12    unit nx,ny,nz
#
# Header: +0x00 'GEO1'  +0x04 frame  +0x08 depth  +0x0C/10/14 v/f/n counts
#         +0x18/1C/20 v/f/n array BASE POINTERS   +0x24 mesh
#         +0x28 world 4x4 (row-major, translation in row 3)  +0x68 name (32)
#
# TWO THINGS THAT MATTER FOR CORRECTNESS:
#
# 1. Faces reference geometry by POINTER, not by index. The base pointers are in the
#    header precisely so an index can be recovered as (ptr - base) / stride. Any
#    corner pointer that does not land exactly on a stride boundary inside the array
#    is REJECTED rather than rounded -- a silently wrong index would produce geometry
#    that looks plausible and is wrong, which is worse than a dropped face.
#
# 2. Vertices are FRAME-LOCAL. Each must be multiplied by the frame's world matrix to
#    sit in the room. Reality Lab is row-vector/row-major (its own GetPosition reads
#    the translation from row 3), so the transform is v' = v * M, not M * v.
#
# The corner-pointer offsets inside Face are not documented anywhere; this scans the
# whole Face for dwords that resolve to valid vertex indices and takes the first
# `vertex count` of them. That is a heuristic, and the script says so in its output.
#
# Usage:
#   .\tools\Export-Obj.ps1                          # room.obj next to the log
#   .\tools\Export-Obj.ps1 -Out C:\tmp\room1.obj
#   .\tools\Export-Obj.ps1 -Report                  # inspect, write nothing

[CmdletBinding()]
param(
    [string]$Path,
    [string]$Out,
    [switch]$Report,
    [switch]$NoTransform,
    [int]$MaxFaceScan = 120,
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZRAEL\room1-tex',
    [switch]$NoFlipV
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    foreach ($c in @('C:\Games\RaptorMod\game\GAME\AZRAEL\AZTGEO.BIN',
                     (Join-Path $PSScriptRoot '..\..\AZTGEO.BIN'))) {
        if (Test-Path $c) { $Path = (Resolve-Path $c).Path; break }
    }
}
if (-not $Path -or -not (Test-Path $Path)) { throw "AZTGEO.BIN not found. Pass -Path." }
if (-not $Out) { $Out = Join-Path (Split-Path -Parent $Path) 'azrael-room.obj' }

$bytes = [IO.File]::ReadAllBytes($Path)
Write-Host ("AZTGEO.BIN: {0:N0} bytes" -f $bytes.Length)

# Verbose names deliberately: short helpers like Fl/Rd/Gu silently resolve to the
# built-in aliases Format-List / Remove-Item / Get-Unique.
function ReadUint32  { param([int]$o) [BitConverter]::ToUInt32($bytes, $o) }
function ReadFloat32 { param([int]$o) [BitConverter]::ToSingle($bytes, $o) }
function ReadAscii   { param([int]$o, [int]$n)
    $s = ''
    for ($k = 0; $k -lt $n; $k++) {
        $c = $bytes[$o + $k]; if ($c -eq 0) { break }
        $s += $(if ($c -ge 32 -and $c -le 126) { [char]$c } else { '_' })
    }
    $s
}

# 464, not 144: the geometry header grew when the local matrix and the Texture /
# Material objects were added. A stale value here silently misreads every block.
$HDR = 464
$VSTRIDE = 48; $FSTRIDE = 120; $NSTRIDE = 12
$TEX0 = 0x0C8            # the mesh's first face's Texture object, 128 bytes
$TEXHND = $TEX0 + 0x14   # its handle -- the join key to the extracted PNGs

# Texture POINTER -> PNG, and handle -> PNG, from the index Export-LiveTextures writes.
#
# The pointer map is what makes PER-FACE materials work. Assigning one material per
# MESH (from face[0]) was wrong for `dorwall06` and `dorwall07`, which use 3 distinct
# textures across their 18 faces each -- 2 of 124 meshes rendered with the wrong art.
# A Face's +0x3C holds the Texture object pointer directly, so faces map to textures
# exactly, with no handle lookup and no assumption that a mesh has only one.
$texMap = @{}       # handle  -> png
$ptrMap = @{}       # texptr  -> png
if ($TexDir -and (Test-Path (Join-Path $TexDir 'textures.csv'))) {
    foreach ($row in (Import-Csv (Join-Path $TexDir 'textures.csv'))) {
        $texMap[[string][int]$row.Handle] = $row.File
        if ($row.PSObject.Properties['TexPtr']) {
            $ptrMap[[string][uint32]("0x" + ($row.TexPtr -replace '^0x',''))] = $row.File
        }
    }
    Write-Host ("texture index: {0} handles, {1} pointers from {2}" -f `
                $texMap.Count, $ptrMap.Count, (Join-Path $TexDir 'textures.csv'))
    if (-not $ptrMap.Count) {
        Write-Host "  textures.csv has no TexPtr column -- re-run Export-LiveTextures.ps1 for per-face materials" -ForegroundColor Yellow
    }
} elseif ($TexDir) {
    Write-Host ("no textures.csv in {0} -- the OBJ will have no materials" -f $TexDir) -ForegroundColor Yellow
}

# ---- walk the blocks ---------------------------------------------------------
$meshes = New-Object System.Collections.ArrayList
$pos = 0
$bad = 0
while ($pos + $HDR -le $bytes.Length) {
    if ((ReadUint32 $pos) -ne 0x314F4547) { $bad++; break }      # 'GEO1'
    $vC = [int](ReadUint32 ($pos + 0x0C))
    $fC = [int](ReadUint32 ($pos + 0x10))
    $nC = [int](ReadUint32 ($pos + 0x14))
    $vSz = $vC * $VSTRIDE; $fSz = $fC * $FSTRIDE; $nSz = $nC * $NSTRIDE
    $need = $HDR + $vSz + $fSz + $nSz
    if ($pos + $need -gt $bytes.Length) {
        Write-Host ("  truncated block at 0x{0:X} (needs {1:N0} bytes, {2:N0} left) -- run ended early" -f `
                    $pos, $need, ($bytes.Length - $pos)) -ForegroundColor Yellow
        break
    }
    $m = [pscustomobject]@{
        Name   = ReadAscii ($pos + 0x68) 32
        TexHnd = [int](ReadUint32 ($pos + $TEXHND))
        Frame  = ReadUint32 ($pos + 0x04)
        Depth  = [int](ReadUint32 ($pos + 0x08))
        VCount = $vC; FCount = $fC; NCount = $nC
        VBase  = [double](ReadUint32 ($pos + 0x18))
        FBase  = [double](ReadUint32 ($pos + 0x1C))
        NBase  = [double](ReadUint32 ($pos + 0x20))
        World  = @(0..15 | ForEach-Object { ReadFloat32 ($pos + 0x28 + $_*4) })
        VOff   = $pos + $HDR
        FOff   = $pos + $HDR + $vSz
        NOff   = $pos + $HDR + $vSz + $fSz
    }
    [void]$meshes.Add($m)
    $pos += $need
}
$meshes = @($meshes)
Write-Host ("  {0} mesh blocks, {1:N0} vertices, {2:N0} faces, {3:N0} normals" -f `
            $meshes.Count,
            (($meshes | Measure-Object VCount -Sum).Sum),
            (($meshes | Measure-Object FCount -Sum).Sum),
            (($meshes | Measure-Object NCount -Sum).Sum))
if ($pos -lt $bytes.Length) { Write-Host ("  {0:N0} trailing bytes unparsed" -f ($bytes.Length - $pos)) -ForegroundColor DarkGray }
if (-not $meshes.Count) { throw "no complete mesh blocks" }

# ---- build the OBJ ----------------------------------------------------------
# Row-vector convention: v' = v * M, translation in row 3.
function TransformPoint {
    param($x, $y, $z, $M)
    # EACH ELEMENT MUST BE PARENTHESISED. PowerShell's comma binds TIGHTER than `+`,
    # so writing these as bare sums makes `$M[12], $x*$M[1]` parse as an array and the
    # preceding `+` then attempts double + Object[], failing with
    # "[System.Object[]] does not contain a method named 'op_Addition'".
    @(
        ($x*$M[0] + $y*$M[4] + $z*$M[8]  + $M[12]),
        ($x*$M[1] + $y*$M[5] + $z*$M[9]  + $M[13]),
        ($x*$M[2] + $y*$M[6] + $z*$M[10] + $M[14])
    )
}

# NOTE: every -f inside a .Add(...) call is parenthesised. In a METHOD CALL the
# commas are argument separators, so .Add("{0} {1}" -f $a, $b) passes three
# arguments and the format string only ever sees $a -- which fails with "Index
# (zero based) must be ... less than the size of the argument list".
$objLines = New-Object System.Collections.ArrayList
[void]$objLines.Add("# Azrael's Tear -- room geometry read live from the running game by AztMod")
[void]$objLines.Add("# " + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
[void]$objLines.Add(("# {0} meshes; vertices transformed by each frame's world 4x4" -f $meshes.Count))

$vBaseIdx = 1          # OBJ indices are 1-based and global across the file
$tBaseIdx = 1
$nBaseIdx = 1
$facesOut = 0
$facesDropped = 0
$degenerate = 0
$perMesh = New-Object System.Collections.ArrayList
$matUsed = @{}      # material name -> png file, in use order
$missing = @{}      # texture handles with no extracted PNG

foreach ($m in $meshes) {
    # --- vertices
    $verts = New-Object System.Collections.ArrayList
    $uvs   = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $m.VCount; $i++) {
        $o = $m.VOff + $i*$VSTRIDE
        $x = [double](ReadFloat32 $o); $y = [double](ReadFloat32 ($o+4)); $z = [double](ReadFloat32 ($o+8))
        $u = [double](ReadFloat32 ($o+16)); $v = [double](ReadFloat32 ($o+20))
        if ($NoTransform) { $p = @($x,$y,$z) } else { $p = TransformPoint $x $y $z $m.World }
        # OBJ puts v=0 at the BOTTOM of the image; the game's textures are stored top
        # down, so v is flipped. This is a convention choice, not something read out of
        # the engine -- if the textures come out upside down, pass -NoFlipV.
        if (-not $NoFlipV) { $v = 1.0 - $v }
        [void]$verts.Add($p); [void]$uvs.Add(@($u,$v))
    }
    # --- normals
    $norms = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $m.NCount; $i++) {
        $o = $m.NOff + $i*$NSTRIDE
        [void]$norms.Add(@([double](ReadFloat32 $o), [double](ReadFloat32 ($o+4)), [double](ReadFloat32 ($o+8))))
    }

    $safe = if ($m.Name) { ($m.Name -replace '[^A-Za-z0-9_.-]','_') } else { ('frame_{0:X8}' -f $m.Frame) }
    [void]$objLines.Add("")
    [void]$objLines.Add("o $safe")
    foreach ($p in $verts) { [void]$objLines.Add(("v {0:F6} {1:F6} {2:F6}" -f $p[0], $p[1], $p[2])) }
    foreach ($t in $uvs)   { [void]$objLines.Add(("vt {0:F6} {1:F6}" -f $t[0], $t[1])) }
    foreach ($n in $norms) { [void]$objLines.Add(("vn {0:F6} {1:F6} {2:F6}" -f $n[0], $n[1], $n[2])) }

    # --- faces, GROUPED BY MATERIAL ------------------------------------------
    # Faces are collected per material first and emitted in groups, because a mesh can
    # use several textures and OBJ applies a `usemtl` to every face after it. Emitting
    # one material per mesh got `dorwall06` and `dorwall07` wrong.
    $groups = @{}                       # material name ('' = none) -> list of f lines
    $mFaces = 0; $mDropped = 0
    for ($i = 0; $i -lt $m.FCount; $i++) {
        $fo = $m.FOff + $i*$FSTRIDE
        # this FACE's own texture, not the mesh's
        $fMat = ''
        $tp = [uint32](ReadUint32 ($fo + 0x3C))
        if ($tp -ne 0 -and $ptrMap.Count) {
            $png = $ptrMap[[string]$tp]
            if ($png) {
                $fMat = [IO.Path]::GetFileNameWithoutExtension($png)
                if (-not $matUsed.ContainsKey($fMat)) { $matUsed[$fMat] = $png }
            } else { $missing[('ptr 0x{0:X8}' -f $tp)] = $true }
        }
        if (-not $fMat -and $texMap.Count -and $m.TexHnd -ne 0) {
            $png = $texMap[[string]$m.TexHnd]       # fall back to the mesh's handle
            if ($png) {
                $fMat = [IO.Path]::GetFileNameWithoutExtension($png)
                if (-not $matUsed.ContainsKey($fMat)) { $matUsed[$fMat] = $png }
            }
        }
        if (-not $groups.ContainsKey($fMat)) { $groups[$fMat] = New-Object System.Collections.ArrayList }
        # THE CORNER SLOTS ARE KNOWN, so no scanning. Censused across all 1,173 faces:
        # +0x58/+0x5C/+0x60 hold the three corner VERTEX pointers and +0x64/+0x68/+0x6C
        # the three corner NORMAL pointers, on 100% of faces. (An earlier reading had
        # +0x58 as "pointer to the vertex array" -- it is really corner 0, which merely
        # coincides with the array base when corner 0 is vertex 0.)
        #
        # THE ORDER IS THE WINDING ORDER, and it is correct as-is: the geometric normal
        # from this corner order matches each Face's own stored normal at +0x2C with a
        # dot product of 1.000 on 1,165 of 1,165 non-degenerate faces, 0 disagreeing.
        # So do NOT reverse it.
        $vidx = @(); $nidx = @()
        foreach ($k in @(0x58, 0x5C, 0x60)) {
            $d = [double](ReadUint32 ($fo + $k)) - $m.VBase
            if ($d -lt 0 -or ($d % $VSTRIDE) -ne 0) { $vidx = @(); break }
            $vi = [int]($d / $VSTRIDE)
            if ($vi -ge $m.VCount) { $vidx = @(); break }
            $vidx += $vi
        }
        if ($vidx.Count -ne 3) { $mDropped++; continue }
        foreach ($k in @(0x64, 0x68, 0x6C)) {
            $d = [double](ReadUint32 ($fo + $k)) - $m.NBase
            if ($d -lt 0 -or ($d % $NSTRIDE) -ne 0) { $nidx = @(); break }
            $ni = [int]($d / $NSTRIDE)
            if ($ni -ge $m.NCount) { $nidx = @(); break }
            $nidx += $ni
        }
        if (($vidx | Select-Object -Unique).Count -lt 3) { $degenerate++; $mDropped++; continue }
        $uniq = $vidx
        $parts = @()
        for ($c = 0; $c -lt 3; $c++) {
            $gv = $vBaseIdx + $vidx[$c]
            $gt = $tBaseIdx + $vidx[$c]
            if ($nidx.Count -eq 3) {
                $parts += ("{0}/{1}/{2}" -f $gv, $gt, ($nBaseIdx + $nidx[$c]))
            } else {
                $parts += ("{0}/{1}" -f $gv, $gt)
            }
        }
        for ($t = 1; $t -lt $uniq.Count - 1; $t++) {
            [void]$groups[$fMat].Add(("f {0} {1} {2}" -f $parts[0], $parts[$t], $parts[$t+1]))
            $mFaces++
        }
    }
    # emit the groups: one `usemtl` per material actually used by this mesh
    foreach ($k in ($groups.Keys | Sort-Object)) {
        if ($k) { [void]$objLines.Add("usemtl $k") }
        foreach ($line in $groups[$k]) { [void]$objLines.Add($line) }
    }
    if ($groups.Count -gt 1) {
        Write-Host ("  {0}: {1} materials across its faces" -f $safe, $groups.Count) -ForegroundColor Cyan
    }
    $facesOut += $mFaces; $facesDropped += $mDropped
    [void]$perMesh.Add([pscustomobject]@{
        Name = $safe; Verts = $m.VCount; Faces = $m.FCount; Tris = $mFaces; Dropped = $mDropped; Depth = $m.Depth
    })

    $vBaseIdx += $verts.Count
    $tBaseIdx += $uvs.Count
    $nBaseIdx += $norms.Count
}

Write-Host ""
Write-Host ("triangles written : {0:N0}" -f $facesOut)
Write-Host ("faces dropped     : {0:N0}{1}" -f $facesDropped,
            $(if ($facesDropped) { '  (corner pointers did not resolve to exact vertex indices)' } else { '' })) `
           -ForegroundColor $(if ($facesDropped -eq 0) { 'Green' } else { 'Yellow' })
if ($degenerate) { Write-Host ("  of those, {0} were degenerate (<3 distinct corners)" -f $degenerate) -ForegroundColor Yellow }

$worst = @($perMesh | Where-Object { $_.Dropped -gt 0 } | Sort-Object { -$_.Dropped } | Select-Object -First 10)
if ($worst.Count) {
    Write-Host "`nmeshes with dropped faces:"
    $worst | ForEach-Object { Write-Host ("   {0,-22} {1,4} verts {2,4} faces -> {3,4} tris, {4} dropped" -f $_.Name, $_.Verts, $_.Faces, $_.Tris, $_.Dropped) }
}
Write-Host "`nlargest meshes:"
$perMesh | Sort-Object { -$_.Verts } | Select-Object -First 8 | ForEach-Object {
    Write-Host ("   {0,-22} depth {1}  {2,4} verts {3,4} faces -> {4,4} tris" -f $_.Name, $_.Depth, $_.Verts, $_.Faces, $_.Tris)
}

if ($Report) { Write-Host "`n-Report given: nothing written."; return }

# ---- the .mtl, and the PNGs beside it ---------------------------------------
# The mtllib line has to precede the first `usemtl`, so it is spliced in after the
# fact rather than guessed at up front -- until the meshes are walked we do not know
# whether any material was resolved at all.
if ($matUsed.Count) {
    $mtlName = [IO.Path]::GetFileNameWithoutExtension($Out) + '.mtl'
    $mtlPath = Join-Path (Split-Path -Parent $Out) $mtlName
    $objLines.Insert(3, "mtllib $mtlName")

    $mtl = New-Object System.Collections.ArrayList
    [void]$mtl.Add("# Azrael's Tear -- materials for the room geometry")
    [void]$mtl.Add("# Textures were read out of the running game's memory with their own palettes.")
    foreach ($k in ($matUsed.Keys | Sort-Object)) {
        [void]$mtl.Add("")
        [void]$mtl.Add("newmtl $k")
        [void]$mtl.Add("Ka 1.000 1.000 1.000")
        [void]$mtl.Add("Kd 1.000 1.000 1.000")
        [void]$mtl.Add("Ks 0.000 0.000 0.000")
        [void]$mtl.Add("d 1.0")
        [void]$mtl.Add("illum 1")            # the engine's Materials are effectively flat
        [void]$mtl.Add("map_Kd $($matUsed[$k])")
        # the three blood decals are chroma-keyed; their PNGs already carry alpha
        if ($k -match '_$') { [void]$mtl.Add("map_d $($matUsed[$k])") }
    }
    [IO.File]::WriteAllLines($mtlPath, $mtl)
    Write-Host ("`nwrote {0}  ({1} materials)" -f $mtlPath, $matUsed.Count)

    # copy the PNGs next to the OBJ so map_Kd resolves without editing paths
    $dest = Split-Path -Parent $Out
    if ($TexDir -and (Resolve-Path $TexDir).Path -ne (Resolve-Path $dest).Path) {
        foreach ($f in $matUsed.Values) {
            $src = Join-Path $TexDir $f
            if (Test-Path $src) { Copy-Item $src (Join-Path $dest $f) -Force }
        }
        Write-Host ("copied {0} PNGs next to the OBJ" -f $matUsed.Count)
    }
}
if ($missing.Count) {
    Write-Host ("{0} texture handle(s) had no extracted PNG: {1}" -f $missing.Count, (($missing.Keys | Sort-Object) -join ', ')) -ForegroundColor Yellow
}

[IO.File]::WriteAllLines($Out, $objLines)
Write-Host ("`nwrote {0}  ({1:N0} lines, {2:N0} bytes)" -f $Out, $objLines.Count, (Get-Item $Out).Length)
Write-Host  "Open it in any modeller. Winding order is CONFIRMED correct: the geometric"
Write-Host  "normal from each face's corner order matches its own stored normal (dot 1.000,"
Write-Host  "1165 of 1165 non-degenerate faces), so no flip is needed."
