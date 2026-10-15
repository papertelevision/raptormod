# Get-RoomSpawn.ps1 -- candidate standable positions inside a room, from its scene geometry.
#
#   .\tools\Get-RoomSpawn.ps1 -Scene washcori            # best candidate
#   .\tools\Get-RoomSpawn.ps1 -Scene washcori -List      # all candidates, best first
#   .\tools\Get-RoomSpawn.ps1 -All                       # coverage check over every scene
#
# WHY. Editing a save's room without its coordinates leaves you at the PREVIOUS room's position:
# outside the level, standing on nothing. Rooms sit at very different heights, so the old Y is
# never close.
#
# HEIGHT -- this part is verified. Player Y = floor mesh world Ymin + EYE_HEIGHT, checked
# against six saved positions in two rooms:
#     washcori  floor Ymin  -73.1 + 45 = -28.1   (saved -28.1)
#     coricori  floor Ymin -114.3 + 45 = -69.3   (saved -69.3)
#     coricori  floor Ymin -108.9 + 45 = -63.9   (saved -64.1)
# It is Ymin, the BOTTOM of the slab, not Ymax: the floor pieces are ~30 units thick and the top
# surface is out by that much, which is enough to strand you.
#
# HORIZONTAL -- this part is a best guess, which is why -List exists. A floor slab's CENTROID is
# not reliably walkable; it can sit under a wall or in a corner. The better candidates are the
# zx*/zy* ZONE TRIGGER VOLUMES, because the player physically walks through those during normal
# play, so their footprint is walkable by definition. Candidates are therefore ranked:
#     1. zone triggers resting on the main floor (their Ymin within ~15 units of the floor's)
#     2. the floor slab's own centroid
# and every candidate is returned so a bad one can simply be skipped rather than re-guessed.
#
# Floor naming: objects called black* are excluded. In washcori 'blackfloor' is a void backdrop
# plane sitting 0.2 units under the real 'floor' -- low enough to win a "lowest floor" test while
# being scenery, not ground.
#
# EYE_HEIGHT is the mod's current value; if Set-EyeHeight.ps1 changes it, change this to match.
# XAF matrices are ROW-vector (translation in the last row), as Export-XafObj also assumes.

[CmdletBinding()]
param(
    [string]$Scene,
    [switch]$List,
    [switch]$All,
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    [double]$EyeHeight = 45
)

$ErrorActionPreference = 'Stop'

function Get-XafObjects([string]$p) {
    $lines = [IO.File]::ReadAllLines($p)
    $objs = @(); $cur = $null; $mode = ''
    foreach ($ln in $lines) {
        $t = $ln.Trim()
        if ($t -match '^object\s+"([^"]+)"') {
            if ($cur) { $objs += $cur }
            $cur = [pscustomobject]@{ Name = $matches[1]; M = @(); V = @() }; $mode = ''; continue
        }
        if (-not $cur) { continue }
        if ($t -match '^matrix\s*\{')   { $mode = 'M'; continue }
        if ($t -match '^vertices\s*\{') { $mode = 'V'; continue }
        if ($t -match '^(normals|texture_coordinates|faces|face_materials|mesh)\s*\{') { $mode = ''; continue }
        if ($t -match '^\}') { $mode = ''; continue }
        if ($mode) {
            $vals = $t -split '[,\s]+' | Where-Object { $_ -match '^-?\d*\.?\d+(e[-+]?\d+)?$' } | ForEach-Object { [double]$_ }
            if ($mode -eq 'M') { $cur.M += $vals } else { $cur.V += $vals }
        }
    }
    if ($cur) { $objs += $cur }
    $objs
}

function Get-Extents([string]$path) {
    $out = @()
    foreach ($o in (Get-XafObjects $path)) {
        if ($o.M.Count -lt 16 -or $o.V.Count -lt 9) { continue }
        $M = $o.M; $xs = @(); $ys = @(); $zs = @()
        for ($i = 0; $i + 2 -lt $o.V.Count; $i += 3) {
            $x = $o.V[$i]; $y = $o.V[$i+1]; $z = $o.V[$i+2]
            $xs += $x*$M[0] + $y*$M[4] + $z*$M[8]  + $M[12]
            $ys += $x*$M[1] + $y*$M[5] + $z*$M[9]  + $M[13]
            $zs += $x*$M[2] + $y*$M[6] + $z*$M[10] + $M[14]
        }
        $xmin=($xs|Measure-Object -Min).Minimum; $xmax=($xs|Measure-Object -Max).Maximum
        $zmin=($zs|Measure-Object -Min).Minimum; $zmax=($zs|Measure-Object -Max).Maximum
        $out += [pscustomobject]@{
            Name=$o.Name
            Ymin=($ys|Measure-Object -Min).Minimum
            Xc=($xs|Measure-Object -Average).Average
            Zc=($zs|Measure-Object -Average).Average
            Area=[Math]::Abs($xmax-$xmin)*[Math]::Abs($zmax-$zmin)
        }
    }
    $out
}

function Get-Candidates([string]$path) {
    $objs = Get-Extents $path
    if (-not $objs) { return @() }

    # the ground plane: a named floor that is not a black backdrop, lowest first
    $floors = $objs | Where-Object { $_.Name -match '^(floor|ground|flr)' -and $_.Name -notmatch '^black' }
    if (-not $floors) {
        $sortedY = ($objs | ForEach-Object { $_.Ymin } | Sort-Object)
        $median  = $sortedY[[int]($sortedY.Count/2)]
        $floors  = $objs | Where-Object { $_.Ymin -le $median } | Sort-Object Area -Descending | Select-Object -First 1
        $named = $false
    } else { $named = $true }
    if (-not $floors) { return @() }
    $floor = $floors | Sort-Object Ymin | Select-Object -First 1
    $groundY = $floor.Ymin + $EyeHeight

    $cands = @()
    # zone triggers sitting on this floor: walkable by definition, the player walks through them
    foreach ($z in ($objs | Where-Object { $_.Name -match '^(zx|zy)' })) {
        # Triggers rest on the floor's TOP face, and the slabs are up to ~30 units thick
        # (coricori), so the window has to span the slab or the whole room finds nothing.
        # Anything outside it is in a pit or on another storey.
        $drop = $z.Ymin - $floor.Ymin
        if ($drop -lt -10 -or $drop -gt 60) { continue }
        # A trigger named *entry* IS the room's arrival point -- coricori's 'zxentry' sits at
        # (-5, 14.7) and the real saved position in that room was (5.5, 2.5). Rank those first;
        # otherwise fall back to whichever trigger is nearest the middle of the floor.
        $dist = [Math]::Sqrt([Math]::Pow($z.Xc-$floor.Xc,2) + [Math]::Pow($z.Zc-$floor.Zc,2))
        if ($z.Name -match 'entry') { $dist = -1000000 + $dist }
        $cands += [pscustomobject]@{
            Scene=[IO.Path]::GetFileNameWithoutExtension($path); Source="trigger $($z.Name)"
            X=[Math]::Round($z.Xc,2); Y=[Math]::Round($groundY,2); Z=[Math]::Round($z.Zc,2)
            Floor=$floor.Name; Named=$named; Rank=$dist
        }
    }
    $cands = @($cands | Sort-Object Rank)
    $cands += [pscustomobject]@{
        Scene=[IO.Path]::GetFileNameWithoutExtension($path); Source="floor centre $($floor.Name)"
        X=[Math]::Round($floor.Xc,2); Y=[Math]::Round($groundY,2); Z=[Math]::Round($floor.Zc,2)
        Floor=$floor.Name; Named=$named; Rank=[double]::MaxValue
    }
    $cands
}

if ($All) {
    foreach ($f in (Get-ChildItem $TexDir -Recurse -Filter '*.xaf' -File | Sort-Object BaseName)) {
        $c = Get-Candidates $f.FullName
        if ($c) { $c[0] | Select-Object Scene,Source,X,Y,Z,Floor,Named }
        else { [pscustomobject]@{Scene=$f.BaseName;Source='(no geometry)';X=$null;Y=$null;Z=$null;Floor=$null;Named=$false} }
    }
    return
}

if (-not $Scene) { throw 'give -Scene <name> or -All' }
$f = Get-ChildItem $TexDir -Recurse -Filter ($Scene + '.xaf') -File | Select-Object -First 1
if (-not $f) { throw "no scene file for '$Scene'" }
$c = Get-Candidates $f.FullName
if (-not $c) { throw "no usable geometry in $($f.Name)" }
if ($List) { $c | Select-Object Scene,Source,X,Y,Z,Floor,Named } else { $c[0] | Select-Object Scene,Source,X,Y,Z,Floor,Named }
