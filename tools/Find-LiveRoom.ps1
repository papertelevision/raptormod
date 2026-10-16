# Find-LiveRoom.ps1 -- which .XAF is the game ACTUALLY showing, right now?
#
#   .\tools\Find-LiveRoom.ps1
#   .\tools\Find-LiveRoom.ps1 -Top 5
#
# Naming the room by hand was costing a run every time: I rendered ATUNNEL2 while the
# player was in the minehead, then MINEHEAD while they were back in the first room. A
# camera that is right and geometry that is somewhere else produces a jumbled, unmoving
# picture -- which reads as a broken renderer rather than as the wrong file.
#
# WHY THE OBVIOUS METHODS DO NOT WORK:
#   * by NAME -- "the tunnel" matched ATUNNEL2, TUNNJ, TUNNMAZE and ENTRY_D, and the
#     room the game calls Tunnel was none of the ones I picked.
#   * by BOUNDING BOX -- rooms are modelled around their own origin, so the player's
#     position fell inside 15 of 20 candidates. Worthless as a discriminator.
#
# WHAT DOES WORK: the live scene graph names every object the engine built, and those
# names are the room's identity. MINEHEAD's objects are mh_*, its portals zxmineh*. One
# walk of the graph and one pass over the .XAF corpus settles it with a number attached.
[CmdletBinding()]
param(
    [string]$TexDir = "$(if ($env:RAPTORMOD_ROOT) { $env:RAPTORMOD_ROOT } else { 'C:\Games\RaptorMod' })\game\GAME\AZTEX",
    [string]$Sym    = "$PSScriptRoot\..\AztMod.overlay.sym",
    [string]$IndexFile = "$(if ($env:RAPTORMOD_ROOT) { $env:RAPTORMOD_ROOT } else { 'C:\Games\RaptorMod' })\cache\xaf-objects.json",
    [int]$Top = 3,
    [switch]$Quiet,
    # An ALREADY-ATTACHED guest base, from Get-AztGuestBase. Attaching costs a needle scan
    # over the whole address space, which is fine once per game session and far too slow to
    # repeat every time the player walks through a door -- Watch-HostRender re-detects the
    # room on every transition and passes its own base in.
    [object]$GuestBase = $null
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')

$symMap = @{}
foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Sym).Path)) {
    if ($l -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') { $symMap[$Matches[2]] = [uint32]('0x'+$Matches[1]) }
}
$g = $(if ($GuestBase) { $GuestBase } else { Get-AztGuestBase })
function RdU32([long]$host_) {
    $b = [AztTool.ProcMem]::Read($g.ProcessId, $host_, 4)
    if (-not $b) { return 0 }
    return [BitConverter]::ToUInt32($b, 0)
}
function HostOf([uint32]$guestLin) { [long]($g.MemBase + $guestLin) }

$rec = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $symMap['aztCamRec'] + 0x1F0000), 320)
if (-not $rec) { throw 'could not read aztCamRec -- is the game running?' }
if ([Text.Encoding]::ASCII.GetString($rec,0,4) -ne 'CAM1') { throw "aztCamRec has no 'CAM1' magic -- is `$ENABLE_CAM_PUBLISH on?" }
$camObj = [BitConverter]::ToUInt32($rec, 16)
if ($camObj -lt 0x1000) { throw 'the camera object pointer is null -- no scene loaded yet' }

# ---- climb to the root, then walk ------------------------------------------
# Frame fields: +0x24 char* name, +0x30 parent, +0x34 sibling, +0x3C first child.
$p = $camObj
for ($i = 0; $i -lt 16; $i++) {
    $par = RdU32 (HostOf ($p + 0x30))
    if ($par -lt 0x1000) { break }
    $p = $par
}
$root = $p
$names = New-Object System.Collections.Generic.List[string]
$stack = New-Object System.Collections.Stack
$stack.Push($root)
$seen = @{}
while ($stack.Count -gt 0 -and $seen.Count -lt 2000) {
    $f = [uint32]$stack.Pop()
    if ($f -lt 0x1000 -or $seen.ContainsKey($f)) { continue }
    $seen[$f] = 1
    $nmPtr = RdU32 (HostOf ($f + 0x24))
    if ($nmPtr -gt 0x1000) {
        $raw = [AztTool.ProcMem]::Read($g.ProcessId, (HostOf $nmPtr), 32)
        if ($raw) {
            $z = [Array]::IndexOf($raw, [byte]0)
            if ($z -gt 0) {
                $s = [Text.Encoding]::ASCII.GetString($raw, 0, $z)
                # printable only: a bad pointer yields bytes that happen to be non-zero
                if ($s -match '^[\x20-\x7E]+$') { $names.Add($s) }
            }
        }
    }
    $c = RdU32 (HostOf ($f + 0x3C)); if ($c -ge 0x1000) { $stack.Push($c) }
    $s2 = RdU32 (HostOf ($f + 0x34)); if ($s2 -ge 0x1000) { $stack.Push($s2) }
}
$live = @($names | Sort-Object -Unique)
if (-not $Quiet) { Write-Host ("live scene: {0} frames walked, {1} distinct names" -f $seen.Count, $live.Count) }
if ($live.Count -eq 0) { throw 'the scene walk found no named objects' }

# ---- the corpus index, built once ------------------------------------------
# 179 files is a second to scan, but doing it on every render start would be a second
# of the player standing still, so it is cached and rebuilt only if the folder changes.
$needBuild = $true
if (Test-Path $IndexFile) {
    $idxAge = (Get-Item $IndexFile).LastWriteTimeUtc
    $newest = (Get-ChildItem $TexDir -Filter '*.XAF' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
    if ($idxAge -gt $newest) { $needBuild = $false }
}
if ($needBuild) {
    if (-not $Quiet) { Write-Host 'building the .XAF object index...' }
    $idx = @{}
    foreach ($f in (Get-ChildItem $TexDir -Filter '*.XAF')) {
        $objs = @()
        foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
            if ($l -match '^\s*object\s+"([^"]+)"') { $objs += $Matches[1] }
        }
        $idx[$f.BaseName] = @($objs | Sort-Object -Unique)
    }
    New-Item -ItemType Directory -Force (Split-Path $IndexFile -Parent) | Out-Null
    ($idx | ConvertTo-Json -Depth 3 -Compress) | Set-Content -Path $IndexFile -Encoding UTF8
}
$idxJson = Get-Content $IndexFile -Raw | ConvertFrom-Json

# ---- score ------------------------------------------------------------------
# By how many of the room's objects the file explains, NOT by how many of the file's
# objects are present: a big file would otherwise win just by having more names.
$scores = @()
foreach ($prop in $idxJson.PSObject.Properties) {
    $objs = @($prop.Value)
    if ($objs.Count -eq 0) { continue }
    $set = @{}
    foreach ($o in $objs) { $set[$o] = 1 }
    $hit = 0
    foreach ($n in $live) { if ($set.ContainsKey($n)) { $hit++ } }
    if ($hit -gt 0) { $scores += [pscustomobject]@{ Xaf = $prop.Name; Hit = $hit; Of = $live.Count; Pct = (100.0*$hit/$live.Count) } }
}
$scores = @($scores | Sort-Object Hit -Descending)
if ($scores.Count -eq 0) { throw 'no .XAF shares a single object name with the live scene' }
if (-not $Quiet) {
    Write-Host 'best single matches:'
    $scores | Select-Object -First $Top | ForEach-Object {
        Write-Host ("  {0,-12} explains {1,3} of {2,3} live objects  ({3:N0}%)" -f $_.Xaf, $_.Hit, $_.Of, $_.Pct)
    }
}

# ---- A ROOM IS OFTEN SEVERAL FILES -----------------------------------------
# SPAROOM explained 98% on its own, but the corridor room's best single file reached
# only 50% -- and CORICORI plus R1 together reach 98%. MINEHEAD likewise covered 73 of
# 98, the rest being a creature's rig. Returning one file would silently render half a
# room, which looks exactly like a broken renderer.
#
# Greedy set cover: take the file that explains the most still-unexplained objects,
# repeat while a file adds a worthwhile share. Greedy is not optimal in general but the
# sets here barely overlap, and a provably optimal cover of 179 sets is not worth it to
# choose two filenames.
$remaining = @{}
foreach ($n in $live) { $remaining[$n] = 1 }
$chosen = @()
for ($pass = 0; $pass -lt 6 -and $remaining.Count -gt 0; $pass++) {
    $best = $null; $bestHit = 0
    foreach ($prop in $idxJson.PSObject.Properties) {
        if ($chosen -contains $prop.Name) { continue }
        $hit = 0
        foreach ($o in @($prop.Value)) { if ($remaining.ContainsKey($o)) { $hit++ } }
        if ($hit -gt $bestHit) { $bestHit = $hit; $best = $prop.Name }
    }
    # Stop on a file that adds almost nothing: past that point the leftovers are
    # creature rigs and engine-made frames, which no room file will ever contain.
    if (-not $best -or $bestHit -lt [Math]::Max(3, $live.Count * 0.05)) { break }
    $chosen += $best
    foreach ($o in @($idxJson.$best)) { [void]$remaining.Remove($o) }
}
$covered = $live.Count - $remaining.Count
if (-not $Quiet) {
    Write-Host ("composed room: {0}  -> {1} of {2} objects explained ({3:N0}%)" -f `
        ($chosen -join ' + '), $covered, $live.Count, (100.0*$covered/$live.Count))
    if ($remaining.Count -gt 0) {
        Write-Host ("  {0} unexplained (creature rigs and engine frames): {1}" -f `
            $remaining.Count, ((@($remaining.Keys) | Select-Object -First 6) -join ', '))
    }
}
# The answer, on stdout: one file per line, so a caller can consume them all.
$chosen
