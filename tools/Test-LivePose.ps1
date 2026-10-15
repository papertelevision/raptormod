# What is in the live scene that the host renderer is not drawing, or is drawing somewhere else?
#
#   .\tools\Test-LivePose.ps1 -Rooms MINEHEAD
#   .\tools\Test-LivePose.ps1 -Rooms CORICORI -Characters EUGBLD:ZZ0001,EUGBLD:ZZ0002
#
# Read-only, against the running game. Stand where the difference is visible and leave the
# game open. It answers three questions the pictures cannot:
#
#   1. UNDRAWN: live frames that carry a mesh but match no part the host loaded. Each one is an
#      object the engine draws and the host does not -- a prop from another file, an instance
#      under a name the loader does not expect.
#   2. MISPLACED: parts whose live world matrix is far from the rest pose the .XAF gave them.
#      Most of these are right (an open door, a creature); the list is here so a part that
#      SHOULD have moved and did not can be told from one that moved correctly.
#   3. AMBIGUOUS: names that occur on more than one live frame with different matrices. The
#      walk keeps one matrix per name, so for these the host has to be picking one of several.
#
# It also re-derives every world matrix from the locals (what the host uses) and compares it
# with the engine's own cache, which is exact whenever the engine has just drawn.
param(
    [Parameter(Mandatory)][string[]]$Rooms,
    [string[]]$Characters = @(),
    [string]$CacheDir = 'C:\Games\RaptorMod\cache'
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
. (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'),
                 (Join-Path $toolDir 'SceneGraph.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing
if (-not ('AztTool.ProcMem' -as [type])) { Add-Type -Path (Join-Path $toolDir 'ProcMem.cs') }

$g = Get-AztGuestBase
$sym = @{}
foreach ($l in [IO.File]::ReadAllLines((Join-Path $toolDir '..\AztMod.overlay.sym'))) { if ($l -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') { $sym[$Matches[2]] = [uint32]('0x' + $Matches[1]) } }
function RB([long]$rt, [int]$n) { ,([byte[]][AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $rt), $n)) }
$rec = RB ($sym['aztCamRec'] + 0x1F0000) 320
$cam = [BitConverter]::ToUInt32($rec, 16)
if ($cam -lt 0x1000) { throw 'no scene loaded' }
"host is drawing: {0}" -f $(if ([BitConverter]::ToUInt32((RB ($sym['aztHostInject'] + 0x1F0000) 4), 0)) { 'yes (the engine cache is refreshed by the game-side stub)' } else { 'no (the engine is drawing, its cache is exact)' })

# ---- one full walk, keeping EVERY frame (duplicates included) ----------------
$top = $cam; for ($i = 0; $i -lt 32; $i++) { $par = [BitConverter]::ToUInt32((RB ($top + 0x30) 4), 0); if ($par -lt 0x1000) { break }; $top = $par }
$nodes = New-Object System.Collections.ArrayList; $byPtr = @{}
$stack = New-Object System.Collections.Stack; $stack.Push(@($top, $null))
while ($stack.Count -and $nodes.Count -lt 2000) {
    $e = $stack.Pop(); $f = [uint32]$e[0]; $pw = $e[1]
    if ($f -lt 0x1000 -or $byPtr.ContainsKey($f)) { continue }
    $b = [byte[]](RB $f 0x2E0); if (-not $b -or $b.Length -lt 0x2E0) { continue }
    $L = New-Object single[] 16; $C = New-Object single[] 16
    [Buffer]::BlockCopy($b, 0x4C, $L, 0, 64); [Buffer]::BlockCopy($b, 0x90, $C, 0, 64)
    if ($null -eq $pw) { $Wd = [single[]]@(1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1) } else { $Wd = [AztTool.SceneGraph]::Mul($L, [single[]]$pw) }
    $np = [BitConverter]::ToUInt32($b, 0x24); $name = ''
    if ($np -gt 0x1000) { $nb = [byte[]](RB $np 48); if ($nb) { $z = [Array]::IndexOf($nb, [byte]0); if ($z -gt 0) { $name = [Text.Encoding]::ASCII.GetString($nb, 0, $z) } } }
    $nv = 0; $vis = [BitConverter]::ToInt32($b, 0x268); $va = [BitConverter]::ToUInt32($b, 0x270)
    if ($vis -ge 1 -and $va -ge 0x1000) { $m = [BitConverter]::ToUInt32((RB $va 4), 0); if ($m -ge 0x1000) { $mb = [byte[]](RB $m 0x70); if ($mb) { $nv = [BitConverter]::ToInt32($mb, 0x48) } } }
    $n = [pscustomobject]@{ Frame = $f; Name = $name; Parent = [BitConverter]::ToUInt32($b, 0x30); Local = $L; World = $Wd; Cached = $C; Vis = $vis; Verts = $nv; Dirty = $b[0x44]; Vel = $b[0x46]; Rot = $b[0x45] }
    [void]$nodes.Add($n); $byPtr[$f] = $n
    $c = [BitConverter]::ToUInt32($b, 0x3C); if ($c -ge 0x1000) { $stack.Push(@($c, $Wd)) }
    $s = [BitConverter]::ToUInt32($b, 0x34); if ($s -ge 0x1000) { $stack.Push(@($s, $pw)) }
}
"walked {0} frames, {1} with a mesh" -f $nodes.Count, @($nodes | Where-Object { $_.Verts -gt 0 }).Count

# ---- composed vs the engine's cache ------------------------------------------
$off = @($nodes | Where-Object { $_.Name -and $_.Parent -ge 0x1000 } | ForEach-Object { $e = 0.0; for ($i = 0; $i -lt 16; $i++) { $e = [Math]::Max($e, [Math]::Abs($_.World[$i] - $_.Cached[$i])) }; if ($e -gt 0.05) { [pscustomobject]@{ N = $_; E = $e } } })
"composed-from-locals disagrees with the engine's cache on {0} named frames" -f $off.Count
$off | Sort-Object E -Descending | Select-Object -First 12 | ForEach-Object { '   {0,-18} by {1,8:N2}  cached t ({2:N1} {3:N1} {4:N1})  composed t ({5:N1} {6:N1} {7:N1})  dirty {8}' -f $_.N.Name, $_.E, $_.N.Cached[12], $_.N.Cached[13], $_.N.Cached[14], $_.N.World[12], $_.N.World[13], $_.N.World[14], $_.N.Dirty }

# ---- what the host has loaded -------------------------------------------------
$chars = @(); foreach ($c in $Characters) { $p = $c -split ':'; $chars += @{ Xaf = $p[0]; Prefix = $p[1] } }
$room = Import-AztRoom -Rooms $Rooms -Characters $chars -CacheDir $CacheDir 6>$null
$partByName = @{}; foreach ($p in $room.Parts) { $partByName[$p.Name] = $p }
"host loaded {0} parts from {1}" -f $room.Parts.Count, (($Rooms + ($chars | ForEach-Object { $_.Xaf })) -join ' + ')

''
'1. UNDRAWN -- live frames with a mesh and no matching part:'
$und = @($nodes | Where-Object { $_.Verts -gt 0 -and $_.Name -and -not $partByName.ContainsKey($_.Name) -and -not ($_.Name -match '^ZZ\d{4}(.+)$' -and $partByName.ContainsKey($Matches[1])) })
if (-not $und.Count) { '   none' }
$und | Sort-Object Name | ForEach-Object { $par = $byPtr[$_.Parent]; '   {0,-20} {1,4} verts  at ({2,8:N1} {3,8:N1} {4,8:N1})  parent {5}' -f $_.Name, $_.Verts, $_.World[12], $_.World[13], $_.World[14], $(if ($par) { $par.Name } else { '?' }) }

''
'2. PARTS AWAY FROM THEIR REST POSE (live world vs the .XAF):'
$moved = @()
foreach ($n in $nodes) { if (-not $n.Name) { continue }; $key = $n.Name; if (-not $partByName.ContainsKey($key) -and $n.Name -match '^ZZ\d{4}(.+)$') { $key = $Matches[1] }; $p = $partByName[$key]; if (-not $p -or $p.IsCharacter) { continue }
    $d = [Math]::Sqrt([Math]::Pow($n.World[12]-$p.Rest[12],2) + [Math]::Pow($n.World[13]-$p.Rest[13],2) + [Math]::Pow($n.World[14]-$p.Rest[14],2))
    $rd = 0.0; for ($i = 0; $i -lt 11; $i++) { $rd = [Math]::Max($rd, [Math]::Abs($n.World[$i] - $p.Rest[$i])) }
    if ($d -gt 0.5 -or $rd -gt 0.02) { $moved += [pscustomobject]@{ N = $n; P = $p; D = $d; R = $rd } } }
if (-not $moved.Count) { '   none' }
$moved | Sort-Object D -Descending | Select-Object -First 30 | ForEach-Object { $par = $byPtr[$_.N.Parent]; '   {0,-18} moved {1,7:N1} units, rotation/scale change {2:N2}:  rest ({3:N1} {4:N1} {5:N1}) -> live ({6:N1} {7:N1} {8:N1})  parent {9}  vel {10} rot {11}' -f $_.N.Name, $_.D, $_.R, $_.P.Rest[12], $_.P.Rest[13], $_.P.Rest[14], $_.N.World[12], $_.N.World[13], $_.N.World[14], $(if ($par) { $par.Name } else { '?' }), $_.N.Vel, $_.N.Rot }

''
'3. AMBIGUOUS -- a name on more than one live frame, at different places:'
$amb = 0
foreach ($grp in ($nodes | Where-Object { $_.Name } | Group-Object Name | Where-Object { $_.Count -gt 1 })) {
    $first = $grp.Group[0]; $differ = $false
    foreach ($o in $grp.Group) { for ($i = 0; $i -lt 16; $i++) { if ([Math]::Abs($o.World[$i] - $first.World[$i]) -gt 0.05) { $differ = $true } } }
    if (-not $differ) { continue }
    $amb++
    '   {0} x{1}: {2}' -f $grp.Name, $grp.Count, (($grp.Group | ForEach-Object { '({0:N1} {1:N1} {2:N1}){3}' -f $_.World[12], $_.World[13], $_.World[14], $(if ($_.Verts) { " mesh $($_.Verts)v" } else { ' no mesh' }) }) -join '  ')
}
if (-not $amb) { '   none' }

''
'4. PARTS THE HOST HAS THAT ARE NOT IN THE LIVE SCENE (drawn hidden):'
$liveNames = @{}; foreach ($n in $nodes) { if ($n.Name) { $liveNames[$n.Name] = 1; if ($n.Name -match '^ZZ\d{4}(.+)$') { $liveNames[$Matches[1]] = 1 } } }
$gone = @($room.Parts | Where-Object { -not $liveNames.ContainsKey($_.Name) })
if (-not $gone.Count) { '   none' } else { '   ' + (($gone | ForEach-Object { $_.Name }) -join ' ') }
