# Read-SceneLog.ps1 -- decode AZTSCN.LOG, the stage-2 scene graph enumeration.
#
# 400-byte record per frame node (see the aztScnRec label run in Build-AztMod.ps1):
#
#   +0x000 'SNOD'  +0x004 object  +0x008 depth
#   +0x00C frame header, 76 raw bytes from [obj+0x00]
#   +0x058 world 4x4, 64 bytes from [obj+0x90]
#   +0x098 tail, 112 bytes from [obj+0xD0]
#   +0x108 64 bytes from *[obj+0x20]   (zeroed if the pointer was null)
#   +0x148 64 bytes from *[obj+0x24]   (zeroed if the pointer was null)
#
# ALL ARITHMETIC IS DONE IN [double]. A uint32 cast looks harmless until a field
# holds 0xFFFFFFFF or a bad walk leaves a tiny address in the object column: the
# subtraction underflows, the cast throws, and the census dies halfway through
# printing. That happened twice. Widths here are chosen so nothing has to be cast
# back down.
#
# Field meanings established so far, from the recursive propagator at 0x55378 plus
# the census below:
#   +0x00 hash-bucket chain (the link 0x39E50 follows)   +0x14 handle
#   +0x18 class tag        +0x1C/+0x20 count + array     +0x24 per-frame pointer
#   +0x30 parent           +0x34 next sibling            +0x38 prev sibling
#   +0x3C first child      +0x40 last child              +0x44 dirty byte
#   +0x4C local 4x4        +0x90 world 4x4
#
# Usage:
#   .\tools\Read-SceneLog.ps1
#   .\tools\Read-SceneLog.ps1 -Tree 60
#   .\tools\Read-SceneLog.ps1 -Dump 12         # full hex of one node
#   .\tools\Read-SceneLog.ps1 -Offset 0x24     # every value at one header offset

[CmdletBinding()]
param(
    [string]$Path,
    [int]$Tree = 0,
    [int]$Offset = -1,
    [int]$Dump = -1,
    [string]$Csv
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    foreach ($c in @('C:\Games\RaptorMod\game\GAME\AZRAEL\AZTSCN.LOG',
                     (Join-Path $PSScriptRoot '..\..\AZTSCN.LOG'))) {
        if (Test-Path $c) { $Path = (Resolve-Path $c).Path; break }
    }
}
if (-not $Path -or -not (Test-Path $Path)) { throw "AZTSCN.LOG not found. Pass -Path." }

$RECLEN = 400
$HDR = 0x00C
$WLD = 0x058
$TAIL = 0x098
$P20 = 0x108
$P24 = 0x148

$bytes = [IO.File]::ReadAllBytes($Path)
$count = [Math]::Floor($bytes.Length / $RECLEN)
Write-Host ("AZTSCN.LOG: {0:N0} bytes, {1:N0} node records" -f $bytes.Length, $count)
if ($bytes.Length % $RECLEN -ne 0) {
    Write-Host ("  NOTE: {0} trailing bytes" -f ($bytes.Length % $RECLEN)) -ForegroundColor DarkGray
}
if ($count -lt 1) { throw "no records" }

# Deliberately NOT named U32/GU: `gu` is the built-in alias for Get-Unique and a
# two-letter helper silently resolved to it, producing pages of binding errors.
function ReadDw  { param($o) [double][BitConverter]::ToUInt32($bytes, $o) }
function ReadFl  { param($o) [BitConverter]::ToSingle($bytes, $o) }
function HexDw   { param($v) '0x{0:X8}' -f [uint32]$v }

$nodes = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $count; $i++) {
    $o = $i * $RECLEN
    if ((ReadDw $o) -ne 0x444F4E53) { continue }        # 'SNOD'
    [void]$nodes.Add([pscustomobject]@{
        Index  = $i
        Rec    = $o
        Obj    = ReadDw ($o + 0x004)
        Depth  = [int](ReadDw ($o + 0x008))
        Handle = ReadDw ($o + $HDR + 0x14)
        Tag    = ReadDw ($o + $HDR + 0x18)
        Cnt1C  = ReadDw ($o + $HDR + 0x1C)
        P20v   = ReadDw ($o + $HDR + 0x20)
        P24v   = ReadDw ($o + $HDR + 0x24)
        Parent = ReadDw ($o + $HDR + 0x30)
        Sib    = ReadDw ($o + $HDR + 0x34)
        PrevSib= ReadDw ($o + $HDR + 0x38)
        Child  = ReadDw ($o + $HDR + 0x3C)
        LastCh = ReadDw ($o + $HDR + 0x40)
        X      = ReadFl ($o + $WLD + 0x30)
        Y      = ReadFl ($o + $WLD + 0x34)
        Z      = ReadFl ($o + $WLD + 0x38)
    })
}
$nodes = @($nodes)
$maxDepth = ($nodes | Measure-Object Depth -Maximum).Maximum
Write-Host ("  {0:N0} valid nodes, max depth {1}" -f $nodes.Count, $maxDepth)

$byObj = @{}
foreach ($nd in $nodes) { $byObj[[string]$nd.Obj] = $nd }
function IsNode { param($v) ($v -ne 0) -and $byObj.ContainsKey([string]$v) }

$objMin = ($nodes | Measure-Object Obj -Minimum).Minimum
$objMax = ($nodes | Measure-Object Obj -Maximum).Maximum
$heapLo = $objMin - 0x800000; if ($heapLo -lt 0x10000) { $heapLo = 0x10000 }
$heapHi = $objMax + 0x800000
function IsHeap { param($v) ($v -ge $heapLo) -and ($v -le $heapHi) }

# ---- 1. integrity -----------------------------------------------------------
Write-Host "`n--- walk integrity --------------------------------------------------"
$tagGroups = $nodes | Group-Object Tag | Sort-Object Count -Descending
$mainTag = [double]$tagGroups[0].Name
Write-Host ("  class tag {0} on {1} of {2} nodes{3}" -f (HexDw $mainTag), $tagGroups[0].Count, $nodes.Count,
            $(if ($tagGroups.Count -gt 1) { " ($($tagGroups.Count) distinct tags)" } else { ' (all one class)' }))
$dupes   = @($nodes | Group-Object Obj | Where-Object { $_.Count -gt 1 })
$orphans = @($nodes | Where-Object { $_.Depth -gt 0 -and -not (IsNode $_.Parent) })
$badDep  = @($nodes | Where-Object { $_.Depth -gt 0 -and (IsNode $_.Parent) -and $byObj[[string]$_.Parent].Depth -ne ($_.Depth - 1) })
$roots   = @($nodes | Where-Object { $_.Depth -eq 0 })
if ($dupes.Count)   { Write-Host ("  {0} object(s) visited twice -- cycle or shared node" -f $dupes.Count) -ForegroundColor Yellow }
               else { Write-Host  "  every node visited exactly once" -ForegroundColor Green }
if ($orphans.Count) { Write-Host ("  {0} node(s) with an unvisited parent" -f $orphans.Count) -ForegroundColor Yellow }
               else { Write-Host  "  every non-root node's parent was visited" -ForegroundColor Green }
if ($badDep.Count)  { Write-Host ("  {0} node(s) with depth != parent depth + 1" -f $badDep.Count) -ForegroundColor Yellow }
               else { Write-Host  "  every depth equals parent depth + 1" -ForegroundColor Green }
Write-Host ("  {0} root node(s) at depth 0" -f $roots.Count)

# The doubly-linked lists should be mutually consistent. If +0x38 really is the
# previous sibling then following +0x34 and coming back must return the same node.
$sibOk = 0; $sibBad = 0
foreach ($nd in $nodes) {
    if (-not (IsNode $nd.Sib)) { continue }
    if ($byObj[[string]$nd.Sib].PrevSib -eq $nd.Obj) { $sibOk++ } else { $sibBad++ }
}
Write-Host ("  +0x34/+0x38 reciprocal (next.prev == self): {0} ok, {1} bad  -- {2}" -f $sibOk, $sibBad,
            $(if ($sibBad -eq 0 -and $sibOk -gt 0) { '+0x38 CONFIRMED previous sibling' } else { '+0x38 unconfirmed' })) `
           -ForegroundColor $(if ($sibBad -eq 0 -and $sibOk -gt 0) { 'Green' } else { 'Yellow' })

# +0x40 should be the LAST child: walk the sibling chain from +0x3C and see where it ends.
$lcOk = 0; $lcBad = 0
foreach ($nd in $nodes) {
    if (-not (IsNode $nd.Child)) { continue }
    $cur = $byObj[[string]$nd.Child]; $guard = 0
    while ((IsNode $cur.Sib) -and $guard -lt 4096) { $cur = $byObj[[string]$cur.Sib]; $guard++ }
    if ($cur.Obj -eq $nd.LastCh) { $lcOk++ } else { $lcBad++ }
}
Write-Host ("  +0x3C/+0x40 (last of the child chain == +0x40): {0} ok, {1} bad  -- {2}" -f $lcOk, $lcBad,
            $(if ($lcBad -eq 0 -and $lcOk -gt 0) { '+0x40 CONFIRMED last child' } else { '+0x40 unconfirmed' })) `
           -ForegroundColor $(if ($lcBad -eq 0 -and $lcOk -gt 0) { 'Green' } else { 'Yellow' })

# ---- 2. the candidate pointers ----------------------------------------------
# Both were followed in-game and 64 bytes captured. What matters is whether the
# target looks like another engine OBJECT (same header shape: a class tag at +0x18
# that is a static obj2 address) or like raw data.
Write-Host "`n--- what the candidate pointers point AT ----------------------------"
foreach ($cand in @(@{ n = '+0x20'; f = 'P20v'; b = $P20; pair = '+0x1C count' },
                    @{ n = '+0x24'; f = 'P24v'; b = $P24; pair = '' })) {
    $have = @($nodes | Where-Object { $_.($cand.f) -ne 0 })
    Write-Host ("`n  {0}: non-null on {1} of {2} nodes {3}" -f $cand.n, $have.Count, $nodes.Count,
                $(if ($cand.pair) { "(paired with $($cand.pair))" } else { '' }))
    if (-not $have.Count) { Write-Host '    always null'; continue }
    # Census the target's own first 16 dwords.
    Write-Host  "    target dword census (over the non-null nodes):"
    for ($k = 0; $k -lt 64; $k += 4) {
        $vals = foreach ($nd in $have) { ReadDw ($nd.Rec + $cand.b + $k) }
        $vals = @($vals)
        $nz   = @($vals | Where-Object { $_ -ne 0 }).Count
        $dist = @($vals | Sort-Object -Unique).Count
        $fr   = @($vals | Where-Object { IsNode $_ }).Count
        $hp   = @($vals | Where-Object { ($_ -ne 0) -and -not (IsNode $_) -and (IsHeap $_) }).Count
        $sm   = @($vals | Where-Object { ($_ -ne 0) -and ($_ -lt 0x10000) }).Count
        $flo  = @($vals | ForEach-Object { $ff = [BitConverter]::ToSingle([BitConverter]::GetBytes([uint32]$_), 0)
                                            if ([Math]::Abs($ff) -gt 1e-4 -and [Math]::Abs($ff) -lt 1e6) { 1 } }).Count
        $note = ''
        if ($dist -eq 1 -and $nz -gt 0) { $note = 'CONSTANT ' + (HexDw $vals[0]) }
        if ($dist -eq 1 -and $nz -gt 0 -and $vals[0] -gt 0x100000 -and -not (IsHeap $vals[0])) {
            $note = 'CONSTANT ' + (HexDw $vals[0]) + '  <== looks like a CLASS TAG (static address)'
        }
        Write-Host ("      +0x{0:X2}  nonzero {1,4}  distinct {2,4}  ->node {3,4}  heapptr {4,4}  small {5,4}  float-ish {6,4}   {7}" -f `
                    $k, $nz, $dist, $fr, $hp, $sm, $flo, $note)
    }
}

# ---- 3. the region past the world matrix ------------------------------------
Write-Host "`n--- tail census, [obj+0xD0..0x13F] (never sampled before) ----------"
Write-Host  "  offset  nonzero ->node heapptr  small float-ish distinct  note"
for ($k = 0; $k -lt 112; $k += 4) {
    $vals = foreach ($nd in $nodes) { ReadDw ($nd.Rec + $TAIL + $k) }
    $vals = @($vals)
    $nz   = @($vals | Where-Object { $_ -ne 0 }).Count
    if ($nz -eq 0) { continue }
    $fr   = @($vals | Where-Object { IsNode $_ }).Count
    $hp   = @($vals | Where-Object { ($_ -ne 0) -and -not (IsNode $_) -and (IsHeap $_) }).Count
    $sm   = @($vals | Where-Object { ($_ -ne 0) -and ($_ -lt 0x10000) }).Count
    $flo  = @($vals | ForEach-Object { $ff = [BitConverter]::ToSingle([BitConverter]::GetBytes([uint32]$_), 0)
                                        if ([Math]::Abs($ff) -gt 1e-4 -and [Math]::Abs($ff) -lt 1e6) { 1 } }).Count
    $dist = @($vals | Sort-Object -Unique).Count
    $note = ''
    if ($hp -gt 0 -and $fr -eq 0) { $note = '<== heap pointer, never a node' }
    if ($fr -gt 0)                { $note = '<== points at scene NODES' }
    Write-Host ("  +0x{0:X3}  {1,7} {2,6} {3,7} {4,6} {5,9} {6,8}  {7}" -f `
                ($k + 0xD0), $nz, $fr, $hp, $sm, $flo, $dist, $note) `
               -ForegroundColor $(if ($note) { 'Cyan' } else { 'Gray' })
}

# ---- 4. tree ----------------------------------------------------------------
if ($Tree -gt 0) {
    Write-Host "`n--- scene graph (walk order) ---------------------------------------"
    $shown = [Math]::Min($Tree, $nodes.Count)
    for ($i = 0; $i -lt $shown; $i++) {
        $nd = $nodes[$i]
        $kids = @($nodes | Where-Object { $_.Parent -eq $nd.Obj }).Count
        Write-Host ("  {0,4} {1}{2} h{3,-6}{4}{5}{6} ({7,9:N2},{8,8:N2},{9,9:N2})" -f `
                    $nd.Index, ('  ' * $nd.Depth), (HexDw $nd.Obj), [uint32]$nd.Handle,
                    $(if ($kids) { "[$kids] " } else { '' }),
                    $(if ($nd.P20v) { 'A' } else { '-' }),
                    $(if ($nd.P24v) { 'B' } else { '-' }),
                    $nd.X, $nd.Y, $nd.Z)
    }
    if ($nodes.Count -gt $shown) { Write-Host ("  ... {0} more (-Tree {1})" -f ($nodes.Count - $shown), $nodes.Count) }
}

# ---- 5. detail --------------------------------------------------------------
if ($Offset -ge 0) {
    Write-Host ("`n--- every value at header +0x{0:X2} ----------------------------------" -f $Offset)
    foreach ($nd in $nodes) {
        $v = ReadDw ($nd.Rec + $HDR + $Offset)
        if ($v -eq 0) { continue }
        Write-Host ("  node {0,4} obj {1} depth {2,2} -> {3} {4}" -f `
                    $nd.Index, (HexDw $nd.Obj), $nd.Depth, (HexDw $v),
                    $(if (IsNode $v) { '(a visited node)' } else { '' }))
    }
}

if ($Dump -ge 0) {
    $nd = $nodes | Where-Object { $_.Index -eq $Dump } | Select-Object -First 1
    if (-not $nd) { throw "no node with index $Dump" }
    Write-Host ("`n--- node {0}, obj {1}, depth {2} -- full record ---" -f $nd.Index, (HexDw $nd.Obj), $nd.Depth)
    foreach ($seg in @(@{n='header  [obj+0x000]'; o=$HDR; l=76},
                       @{n='world   [obj+0x090]'; o=$WLD; l=64},
                       @{n='tail    [obj+0x0D0]'; o=$TAIL; l=112},
                       @{n='*[+0x20]           '; o=$P20; l=64},
                       @{n='*[+0x24]           '; o=$P24; l=64})) {
        Write-Host ("  {0}" -f $seg.n) -ForegroundColor DarkGray
        for ($r = 0; $r -lt $seg.l; $r += 16) {
            $n2 = [Math]::Min(16, $seg.l - $r)
            $hex = (($bytes[($nd.Rec+$seg.o+$r)..($nd.Rec+$seg.o+$r+$n2-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
            Write-Host ("    +0x{0:X3}  {1}" -f $r, $hex)
        }
    }
}

if ($Csv) {
    $nodes | Select-Object Index, Depth,
        @{n='Obj';    e={ HexDw $_.Obj }},    @{n='Parent'; e={ HexDw $_.Parent }},
        @{n='Child';  e={ HexDw $_.Child }},  @{n='Sib';    e={ HexDw $_.Sib }},
        @{n='P20';    e={ HexDw $_.P20v }},   @{n='P24';    e={ HexDw $_.P24v }},
        @{n='Handle'; e={ [uint32]$_.Handle }}, Cnt1C, X, Y, Z |
        Export-Csv -NoTypeInformation -Encoding utf8 $Csv
    Write-Host ("`nwrote {0}" -f $Csv)
}
