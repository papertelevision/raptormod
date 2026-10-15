# Read-Zones.ps1 -- decode AZONES.DAT: the game's zone/trigger table and room graph.
#
#   .\tools\Read-Zones.ps1
#   .\tools\Read-Zones.ps1 -Graph          # room adjacency only
#   .\tools\Read-Zones.ps1 -Csv C:\Games\RaptorMod\scratch\azrael-zones.csv
#
# This is unknown 6 in the feasibility report ("room/portal/visibility structures"),
# which was rated High cost on the assumption it needed reverse engineering. It did not:
# the table is a flat array on disk.
#
# FORMAT.  uint16 count, then `count` records of 75 bytes:
#     +0   zone name, NUL-terminated (60 bytes)
#     +60  object name, NUL-terminated (12 bytes)
#     +72  3 trailing bytes
# 23,927 bytes = 2 + 319*75 exactly, and the header word is 0x013F = 319, so the
# layout is confirmed by two independent counts rather than by eyeballing a hex dump.
#
# THE FILE IS FULL OF GARBAGE AND THAT IS NORMAL. It was written from an uncleared
# buffer, so the bytes after each NUL are 0xCC debug fill or stale heap -- at one point
# it even contains fragments of unrelated strings and code. Read up to the NUL and
# ignore the rest; do not try to interpret what follows it.
#
# WHAT THE RECORDS MEAN. The object name is a `zx*`/`zy*` object that also appears in
# the room's .XAF and in the live scene graph -- these are TRIGGER VOLUMES, placed in
# the world like any other object. The zone name says what entering it does:
#   * "<A>To<B>"                a portal from room A to room B  -> the room graph
#   * "EntryCoord<Room>" etc.   spawn/entry coordinates
#   * "<Room><Thing>AZ"         a scripted event (characters, deaths, vehicles, flies)
#   * "R22aLift1", "D1Lift2"    lift/ladder endpoints
# so one table carries the level graph AND the trigger system.

[CmdletBinding()]
param(
    [string]$Path = 'C:\Games\RaptorMod\game\GAME\AZRAEL\AZONES.DAT',
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    [switch]$Graph,
    [switch]$MapFiles,
    [string]$Csv
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { throw "not found: $Path" }
$b = [IO.File]::ReadAllBytes($Path)

$REC = 75; $OBJ_OFF = 60
$count = [BitConverter]::ToUInt16($b, 0)
$expect = 2 + $count * $REC
Write-Host ("{0}: {1:N0} bytes, header count {2} -> expects {3:N0} bytes  {4}" -f `
            (Split-Path $Path -Leaf), $b.Length, $count, $expect,
            $(if ($expect -eq $b.Length) { 'EXACT' } else { 'MISMATCH -- layout may be wrong' }))

function StrAt { param([int]$o, [int]$max)
    $s = ''
    for ($i = 0; $i -lt $max -and ($o + $i) -lt $b.Length; $i++) {
        $c = $b[$o + $i]
        if ($c -eq 0) { break }
        if ($c -lt 32 -or $c -gt 126) { break }   # 0xCC fill and stale heap
        $s += [char]$c
    }
    $s
}

$zones = @()
for ($i = 0; $i -lt $count; $i++) {
    $base = 2 + $i * $REC
    $zones += [pscustomobject]@{
        Index  = $i
        Zone   = StrAt $base $OBJ_OFF
        Object = StrAt ($base + $OBJ_OFF) 12
    }
}
$good = @($zones | Where-Object { $_.Zone -and $_.Object })
Write-Host ("{0} records, {1} with both a zone name and an object" -f $zones.Count, $good.Count)

# ---- classify ----------------------------------------------------------------
$portal = @(); $entry = @(); $lift = @(); $event = @()
foreach ($z in $good) {
    if     ($z.Zone -match '^(.+?)To(.+)$' -and $z.Zone -notmatch 'AZ$') { $portal += $z }
    elseif ($z.Zone -match 'Entry|Coord')                                { $entry  += $z }
    elseif ($z.Zone -match 'Lift|Ladder|Top$|Bot$')                      { $lift   += $z }
    else                                                                 { $event  += $z }
}
Write-Host ""
Write-Host ("  portals (X->Y)      {0,4}" -f $portal.Count)
Write-Host ("  entry coordinates   {0,4}" -f $entry.Count)
Write-Host ("  lifts / ladders     {0,4}" -f $lift.Count)
Write-Host ("  scripted events     {0,4}" -f $event.Count)

if ($Csv) {
    $good | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    Write-Host ("`nwritten -> {0}" -f $Csv)
}

# ---- the room graph ----------------------------------------------------------
Write-Host ""
Write-Host "=== ROOM GRAPH (from '<A>To<B>' zone names) ===" -ForegroundColor Cyan
$edges = @{}
$rooms = @{}
foreach ($p in $portal) {
    if ($p.Zone -notmatch '^(.+?)To(.+)$') { continue }
    $from = $Matches[1]; $to = $Matches[2]
    $rooms[$from] = $true; $rooms[$to] = $true
    $k = "$from|$to"
    if (-not $edges.ContainsKey($k)) { $edges[$k] = @() }
    $edges[$k] += $p.Object
}
Write-Host ("{0} distinct rooms, {1} directed connections" -f $rooms.Count, $edges.Count)

# a portal is two-way when the reverse edge also exists; that is worth knowing because
# one-way drops (falls, chutes) are exactly the interesting cases
$oneWay = @()
foreach ($k in $edges.Keys) {
    $parts = $k -split '\|'
    if (-not $edges.ContainsKey(($parts[1] + '|' + $parts[0]))) { $oneWay += $k }
}
Write-Host ("{0} of them have no return edge (one-way drops, chutes, or unnamed returns)" -f $oneWay.Count)

if (-not $Graph) {
    Write-Host ""
    Write-Host ("{0,-24} {1,-24} {2}" -f 'from', 'to', 'trigger object(s)')
    foreach ($k in ($edges.Keys | Sort-Object)) {
        $parts = $k -split '\|'
        Write-Host ("{0,-24} {1,-24} {2}" -f $parts[0], $parts[1], (($edges[$k] | Sort-Object -Unique) -join ', '))
    }
}

Write-Host ""
Write-Host "--- one-way (no reverse edge) ---"
foreach ($k in ($oneWay | Sort-Object)) { $parts = $k -split '\|'; Write-Host ("  {0} -> {1}" -f $parts[0], $parts[1]) }

# ---- which .XAF holds each trigger object? -----------------------------------
if ($MapFiles) {
    Write-Host ""
    Write-Host "=== trigger object -> .XAF file (this is the room -> file mapping) ===" -ForegroundColor Cyan
    $objs = @($good | ForEach-Object { $_.Object } | Sort-Object -Unique)
    $where = @{}
    foreach ($f in (Get-ChildItem $TexDir -Filter '*.XAF' -File)) {
        if ($f.Length -eq 0) { continue }
        $t = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($f.FullName))
        foreach ($o in $objs) {
            if ($t.IndexOf('"' + $o + '"') -ge 0) {
                if (-not $where.ContainsKey($o)) { $where[$o] = @() }
                $where[$o] += $f.BaseName
            }
        }
    }
    Write-Host ("{0} distinct trigger objects, {1} located in a .XAF" -f $objs.Count, $where.Count)
    foreach ($o in ($where.Keys | Sort-Object)) {
        Write-Host ("  {0,-14} {1}" -f $o, (($where[$o] | Sort-Object -Unique) -join ', '))
    }
    $orphan = @($objs | Where-Object { -not $where.ContainsKey($_) })
    Write-Host ""
    Write-Host ("{0} trigger object(s) found in NO .XAF: {1}" -f $orphan.Count, (($orphan | Select-Object -First 20) -join ', '))
}
