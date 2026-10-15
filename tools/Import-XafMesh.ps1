# Import-XafMesh.ps1 -- write new geometry back into a .XAF, in place.
#
#   .\tools\Import-XafMesh.ps1 -Xaf LURKA -Obj C:\Users\josh\Desktop\lurka\LURKA_game.obj
#   .\tools\Import-XafMesh.ps1 -Xaf LURKA -Revert
#
# The inverse of Export-XafObj. It replaces ONLY the vertices / normals /
# texture_coordinates / faces blocks of each object whose name appears in the OBJ, and
# leaves everything else in the file byte-for-byte alone -- the matrices, the materials, the
# animation_set with its 23 position/rotate/scale key lists, and any object the OBJ does not
# mention. That is deliberate: the animations are what make the character move, and
# rewriting the file wholesale would be a far larger blast radius than this needs.
#
# THREE CONVERSIONS THAT MUST HAPPEN, AND ARE EASY TO GET WRONG:
#
# 1. WORLD -> FRAME LOCAL. The OBJ holds world-space vertices; a .XAF object holds vertices
#    in ITS OWN frame, which the engine then transforms by the composed matrix chain. So
#    every vertex must go through the INVERSE of that chain. Skip this and each limb is
#    transformed twice and flies off into the room.
#
# 2. OBJ INDICES ARE GLOBAL AND PER-CORNER; .XAF ARE PER-OBJECT AND PARALLEL. In an OBJ a
#    face corner is v/vt/vn with three independent indices. In a .XAF, texture_coordinates
#    is PARALLEL to vertices -- the UV index IS the vertex index. So every distinct
#    (v, vt, vn) combination has to become its own vertex. Reusing the OBJ's v index alone
#    would collapse UV seams and smear the texture across them.
#
# 3. V IS FLIPPED BACK. Export-XafObj writes v' = 1 - v because OBJ puts v=0 at the bottom
#    while the game's textures are stored top-down. Coming back in, that has to be undone.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Xaf,
    [string]$Obj,
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    [switch]$Revert,
    [switch]$NoFlipV,
    # Share a vertex between faces that differ ONLY in normal, averaging the normals.
    #
    # Blender writes a normal per face corner, so keying on (v,vt,vn) makes every corner
    # unique and the vertex count comes out at exactly 3x the triangle count. That is pure
    # waste HERE, because this engine does no lighting at all -- every vertex colour is
    # white and the Material objects are empty, so a vertex normal cannot change a single
    # pixel. Splitting on it costs memory and per-vertex transform for no visual difference.
    #
    # UV seams still split, because keying keeps vt: that split is real and visible.
    [switch]$SplitOnNormals,
    [switch]$Report
)

$ErrorActionPreference = 'Stop'
$stem = $Xaf -replace '\.(XAF|RES)$',''
$xafPath = Join-Path $TexDir "$stem.XAF"
$origXaf = "$xafPath.orig"
if (-not (Test-Path $xafPath)) { throw "no such .XAF: $xafPath" }
if (-not (Test-Path $origXaf)) { Copy-Item $xafPath $origXaf; Write-Host "backed up -> $origXaf" }

if ($Revert) {
    Copy-Item $origXaf $xafPath -Force
    Write-Host ("{0}.XAF reverted to original ({1:N0} bytes)" -f $stem, (Get-Item $xafPath).Length) -ForegroundColor Green
    return
}
if (-not $Obj) { throw '-Obj is required unless -Revert' }
if (-not (Test-Path $Obj)) { throw "no such OBJ: $Obj" }

# ALWAYS from the pristine backup: splicing into an already-rewritten file would compound.
$text = [IO.File]::ReadAllText($origXaf)

# ---- helpers ----------------------------------------------------------------
function MatchBrace { param([string]$s, [int]$open)
    $d = 0
    for ($i = $open; $i -lt $s.Length; $i++) {
        if ($s[$i] -eq '{') { $d++ } elseif ($s[$i] -eq '}') { $d--; if ($d -eq 0) { return $i } }
    }
    throw "unbalanced braces from $open" }
function BlockAt { param([string]$s, [string]$kw, [int]$from, [int]$limit)
    $m = [regex]::Match($s.Substring($from, $limit - $from), ('(?m)^\s*' + $kw + '\s*\{'))
    if (-not $m.Success) { return $null }
    $open = $from + $m.Index + $m.Value.LastIndexOf('{')
    $close = MatchBrace $s $open
    if ($close -gt $limit) { return $null }
    @{ Open = $open; Close = $close } }
function Floats { param([string]$s) @([regex]::Matches($s, '-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?') | ForEach-Object { [double]$_.Value }) }
function Num {
    <# Match the file's own number style, and never emit an exponent.
       "{0:G7}" produces .NET's "-4.276302E-05" -- CAPITAL E and a two-digit exponent --
       whereas every number the 1996 tool wrote is lowercase with three, "-8.16568e-008".
       Rather than gamble on how tolerant the engine's parser is, this writes plain fixed
       point: anything small enough to need an exponent is indistinguishable from zero at
       this model's scale anyway. InvariantCulture because a comma decimal separator on a
       non-English locale would silently corrupt every coordinate in the file. #>
    param([double]$v)
    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return '0' }
    $s = $v.ToString('0.#######', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($s -eq '-0') { $s = '0' }
    $s }
function MatMul { param($A, $B)
    $res = New-Object 'double[]' 16
    for ($row = 0; $row -lt 4; $row++) { for ($col = 0; $col -lt 4; $col++) {
        $s = 0.0; for ($k = 0; $k -lt 4; $k++) { $s += $A[$row*4+$k] * $B[$k*4+$col] }
        $res[$row*4+$col] = $s } }
    ,$res }
function MatInv {
    # Gauss-Jordan on [M | I]. General, because nothing guarantees these matrices are
    # pure rotations -- a transpose-and-negate shortcut would silently mangle any that scale.
    param($M)
    $a = New-Object 'double[][]' 4
    for ($i = 0; $i -lt 4; $i++) {
        $a[$i] = New-Object 'double[]' 8
        for ($j = 0; $j -lt 4; $j++) { $a[$i][$j] = $M[$i*4+$j] }
        $a[$i][4+$i] = 1.0
    }
    for ($col = 0; $col -lt 4; $col++) {
        $piv = $col
        for ($r2 = $col+1; $r2 -lt 4; $r2++) { if ([Math]::Abs($a[$r2][$col]) -gt [Math]::Abs($a[$piv][$col])) { $piv = $r2 } }
        if ([Math]::Abs($a[$piv][$col]) -lt 1e-12) { throw "singular matrix" }
        if ($piv -ne $col) { $t = $a[$piv]; $a[$piv] = $a[$col]; $a[$col] = $t }
        $d = $a[$col][$col]
        for ($j = 0; $j -lt 8; $j++) { $a[$col][$j] /= $d }
        for ($r2 = 0; $r2 -lt 4; $r2++) {
            if ($r2 -eq $col) { continue }
            $f = $a[$r2][$col]
            if ($f -eq 0) { continue }
            for ($j = 0; $j -lt 8; $j++) { $a[$r2][$j] -= $f * $a[$col][$j] }
        }
    }
    $out = New-Object 'double[]' 16
    for ($i = 0; $i -lt 4; $i++) { for ($j = 0; $j -lt 4; $j++) { $out[$i*4+$j] = $a[$i][4+$j] } }
    ,$out }
function XformP { param([double]$x,[double]$y,[double]$z,$M)
    @( ($x*$M[0] + $y*$M[4] + $z*$M[8]  + $M[12]),
       ($x*$M[1] + $y*$M[5] + $z*$M[9]  + $M[13]),
       ($x*$M[2] + $y*$M[6] + $z*$M[10] + $M[14]) ) }
function XformD { param([double]$x,[double]$y,[double]$z,$M)
    @( ($x*$M[0] + $y*$M[4] + $z*$M[8] ),
       ($x*$M[1] + $y*$M[5] + $z*$M[9] ),
       ($x*$M[2] + $y*$M[6] + $z*$M[10]) ) }
$IDENT = @(1.0,0,0,0, 0,1.0,0,0, 0,0,1.0,0, 0,0,0,1.0)

# ---- walk the .XAF tree: name -> world matrix + mesh block extent -------------
$nodes = @{}
$order = New-Object System.Collections.ArrayList

function Walk { param([string]$name, [int]$bodyStart, [int]$bodyEnd, $parentWorld)
    $children = @()
    $scan = $bodyStart
    while ($true) {
        $m = [regex]::Match($script:text.Substring($scan, $bodyEnd - $scan), 'object\s+"([^"]+)"\s*\{')
        if (-not $m.Success) { break }
        $oStart = $scan + $m.Index
        $open = $oStart + $m.Value.LastIndexOf('{')
        $close = MatchBrace $script:text $open
        $children += ,@($m.Groups[1].Value, ($open+1), $close)
        $scan = $close + 1
        if ($scan -ge $bodyEnd) { break }
    }
    $ownEnd = if ($children.Count) { $children[0][1] } else { $bodyEnd }
    $mb = BlockAt $script:text 'matrix' $bodyStart $ownEnd
    $local = if ($mb) { @(Floats $script:text.Substring($mb.Open+1, $mb.Close-$mb.Open-1)) } else { $IDENT }
    if ($local.Count -lt 16) { $local = $IDENT }
    $world = MatMul $local $parentWorld
    $mesh = BlockAt $script:text 'mesh' $bodyStart $ownEnd
    $script:nodes[$name] = @{ World = $world; Mesh = $mesh }
    [void]$script:order.Add($name)
    foreach ($c in $children) { Walk $c[0] $c[1] $c[2] $world }
}

$scan = 0
while ($true) {
    $m = [regex]::Match($text.Substring($scan), 'object\s+"([^"]+)"\s*\{')
    if (-not $m.Success) { break }
    $open = $scan + $m.Index + $m.Value.LastIndexOf('{')
    $close = MatchBrace $text $open
    Walk $m.Groups[1].Value ($open+1) $close $IDENT
    $scan = $close + 1
    if ($scan -ge $text.Length) { break }
}
Write-Host ("{0}.XAF: {1} objects" -f $stem, $nodes.Count)

# ---- read the OBJ ------------------------------------------------------------
$V = New-Object System.Collections.ArrayList
$VT = New-Object System.Collections.ArrayList
$VN = New-Object System.Collections.ArrayList
$groups = @{}
$cur = ''
foreach ($line in [IO.File]::ReadAllLines($Obj)) {
    if ($line.StartsWith('v ')) {
        $f = $line.Split(' ',[StringSplitOptions]::RemoveEmptyEntries)
        [void]$V.Add(@([double]$f[1],[double]$f[2],[double]$f[3]))
    } elseif ($line.StartsWith('vt ')) {
        $f = $line.Split(' ',[StringSplitOptions]::RemoveEmptyEntries)
        [void]$VT.Add(@([double]$f[1],[double]$f[2]))
    } elseif ($line.StartsWith('vn ')) {
        $f = $line.Split(' ',[StringSplitOptions]::RemoveEmptyEntries)
        [void]$VN.Add(@([double]$f[1],[double]$f[2],[double]$f[3]))
    } elseif ($line.StartsWith('o ')) {
        $cur = $line.Substring(2).Trim()
        if (-not $groups.ContainsKey($cur)) { $groups[$cur] = New-Object System.Collections.ArrayList }
    } elseif ($line.StartsWith('f ') -and $cur) {
        $f = $line.Split(' ',[StringSplitOptions]::RemoveEmptyEntries)
        $corners = @()
        for ($i = 1; $i -lt $f.Length; $i++) {
            $p = $f[$i] -split '/'
            $vi = [int]$p[0]
            $ti = if ($p.Count -ge 2 -and $p[1]) { [int]$p[1] } else { 0 }
            $ni = if ($p.Count -ge 3 -and $p[2]) { [int]$p[2] } else { 0 }
            $corners += ,@($vi,$ti,$ni)
        }
        if ($corners.Count -ge 3) { [void]$groups[$cur].Add($corners) }
    }
}
Write-Host ("{0}: {1:N0} v, {2:N0} vt, {3:N0} vn, {4} groups" -f (Split-Path $Obj -Leaf), $V.Count, $VT.Count, $VN.Count, $groups.Count)

$missing = @($groups.Keys | Where-Object { -not $nodes.ContainsKey($_) })
if ($missing.Count) { Write-Host ("  OBJ groups with no .XAF object (ignored): {0}" -f ($missing -join ', ')) -ForegroundColor Yellow }

# ---- build replacement blocks, splice from the END backwards ------------------
# Reverse file order so every offset computed above stays valid as the text shrinks/grows.
$edits = @()
$totalTris = 0
Write-Host ""
Write-Host ("{0,-14} {1,6} {2,6}  {3}" -f 'object','verts','tris','note')
Write-Host ("-" * 56)

foreach ($name in $order) {
    if (-not $groups.ContainsKey($name)) { continue }
    $node = $nodes[$name]
    if (-not $node.Mesh) { Write-Host ("{0,-14} {1,6} {2,6}  no mesh block -- skipped" -f $name,'','') -ForegroundColor Yellow; continue }
    $inv = MatInv $node.World

    # (2) every distinct (v,vt,vn) becomes one vertex
    $key2idx = @{}
    $lv = New-Object System.Collections.ArrayList
    $lt = New-Object System.Collections.ArrayList
    $ln = New-Object System.Collections.ArrayList
    $faces = New-Object System.Collections.ArrayList
    foreach ($tri in $groups[$name]) {
        $idx = @()
        foreach ($c in $tri) {
            $k = if ($SplitOnNormals) { "$($c[0])/$($c[1])/$($c[2])" } else { "$($c[0])/$($c[1])" }
            if ($key2idx.ContainsKey($k) -and -not $SplitOnNormals -and $c[2] -gt 0 -and $c[2] -le $VN.Count) {
                # accumulate this corner's normal into the shared vertex
                $j = $key2idx[$k]
                $n = $VN[$c[2]-1]
                $d = XformD $n[0] $n[1] $n[2] $inv
                $ex = $ln[$j]
                $ln[$j] = @(($ex[0]+$d[0]), ($ex[1]+$d[1]), ($ex[2]+$d[2]))
            }
            if (-not $key2idx.ContainsKey($k)) {
                $w = $V[$c[0]-1]
                $p = XformP $w[0] $w[1] $w[2] $inv          # (1) world -> frame local
                [void]$lv.Add($p)
                if ($c[1] -gt 0 -and $c[1] -le $VT.Count) {
                    $t = $VT[$c[1]-1]
                    $vv = if ($NoFlipV) { $t[1] } else { 1.0 - $t[1] }   # (3) flip v back
                    [void]$lt.Add(@($t[0], $vv))
                } else { [void]$lt.Add(@(0.0,0.0)) }
                if ($c[2] -gt 0 -and $c[2] -le $VN.Count) {
                    $n = $VN[$c[2]-1]
                    # accumulated unnormalised; normalised once after the whole part is built
                    [void]$ln.Add(@(XformD $n[0] $n[1] $n[2] $inv))
                } else { [void]$ln.Add(@(0.0,1.0,0.0)) }
                $key2idx[$k] = $lv.Count - 1
            }
            $idx += $key2idx[$k]
        }
        for ($t2 = 1; $t2 -lt $idx.Count - 1; $t2++) {
            [void]$faces.Add(@($idx[0], $idx[$t2], $idx[$t2+1]))
        }
    }
    if (-not $lv.Count -or -not $faces.Count) { continue }
    # normalise the accumulated normals now that every corner has contributed
    for ($j = 0; $j -lt $ln.Count; $j++) {
        $d = $ln[$j]
        $len = [Math]::Sqrt($d[0]*$d[0]+$d[1]*$d[1]+$d[2]*$d[2])
        if ($len -le 1e-9) { $ln[$j] = @(0.0,1.0,0.0) }
        else { $ln[$j] = @(($d[0]/$len),($d[1]/$len),($d[2]/$len)) }
    }
    $totalTris += $faces.Count

    # rebuild the four sub-blocks, matching the original file's layout
    $ms = $node.Mesh.Open; $me = $node.Mesh.Close
    $meshText = $text.Substring($ms+1, $me-$ms-1)
    $indent = ''
    $im = [regex]::Match($meshText, '(?m)^([ \t]*)vertices\s*\{')
    if ($im.Success) { $indent = $im.Groups[1].Value }
    $ind2 = $indent + ' '

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($indent + 'vertices {')
    foreach ($p in $lv) { [void]$sb.AppendLine(('{0}{1}, {2}, {3},' -f $ind2, (Num $p[0]), (Num $p[1]), (Num $p[2]))) }
    [void]$sb.AppendLine($indent + '}')
    [void]$sb.AppendLine($indent + 'normals {')
    foreach ($n in $ln) { [void]$sb.AppendLine(('{0}{1}, {2}, {3},' -f $ind2, (Num $n[0]), (Num $n[1]), (Num $n[2]))) }
    [void]$sb.AppendLine($indent + '}')
    [void]$sb.AppendLine($indent + 'texture_coordinates {')
    foreach ($t in $lt) { [void]$sb.AppendLine(('{0}{1}, {2},' -f $ind2, (Num $t[0]), (Num $t[1]))) }
    [void]$sb.AppendLine($indent + '}')
    [void]$sb.AppendLine($indent + 'faces {')
    foreach ($f in $faces) {
        # EXACTLY the original's punctuation: "3,<TAB>0,0, 2,2, 1,1, " -- a comma after
        # every pair AND a trailing one. The first writer emitted "0,0 1,1 2,2" and while a
        # comma-as-whitespace tokeniser would survive that, there is no reason to bet the
        # whole model on how forgiving a 1996 parser is.
        [void]$sb.AppendLine(('{0}3,	{1},{1}, {2},{2}, {3},{3}, ' -f $ind2, $f[0], $f[1], $f[2]))
    }
    [void]$sb.AppendLine($ind2 + '0')
    [void]$sb.AppendLine($indent + '}')

    # keep anything else inside the mesh block -- crucially the `material "NAME"` line
    $tail = ''
    $mm = [regex]::Match($meshText, '(?m)^[ \t]*material\s+"[^"]+"[ \t]*$')
    if ($mm.Success) { $tail = $mm.Value + "`r`n" }

    $edits += ,@{ Start = ($ms+1); End = $me; Text = ("`r`n" + $sb.ToString() + $tail + $indent.Substring(0,[Math]::Max(0,$indent.Length-1))) }
    Write-Host ("{0,-14} {1,6} {2,6}  {3}" -f $name, $lv.Count, $faces.Count, $(if ($tail) { 'material kept' } else { 'NO material line' }))
}

Write-Host ("-" * 56)
Write-Host ("{0,-14} {1,6} {2,6}" -f 'TOTAL','',$totalTris)

if ($Report) { Write-Host "`n-Report given: nothing written."; return }
if (-not $edits.Count) { throw "nothing matched -- no objects were replaced" }

$sorted = @($edits | Sort-Object { -$_.Start })
$new = $text
foreach ($e in $sorted) {
    $new = $new.Substring(0, $e.Start) + $e.Text + $new.Substring($e.End)
}

# brace balance is the cheapest possible proof the splice did not corrupt the file
$open = ([regex]::Matches($new, '\{')).Count
$close = ([regex]::Matches($new, '\}')).Count
if ($open -ne $close) { throw "REFUSING TO WRITE: braces unbalanced after splice ($open open, $close close)" }
$objCount = ([regex]::Matches($new, 'object\s+"[^"]+"\s*\{')).Count
$animCount = ([regex]::Matches($new, 'object_name')).Count
Write-Host ("`nbraces balanced ({0}), objects {1}, animation object_name refs {2}" -f $open, $objCount, $animCount)

[IO.File]::WriteAllText($xafPath, $new, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("wrote {0}  ({1:N0} -> {2:N0} bytes)" -f $xafPath, $text.Length, (Get-Item $xafPath).Length) -ForegroundColor Green
