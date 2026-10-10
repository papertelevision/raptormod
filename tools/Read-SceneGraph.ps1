# Read-SceneGraph.ps1 -- dump the LIVE scene graph: names, world positions, visuals.
#
#   .\tools\Read-SceneGraph.ps1
#   .\tools\Read-SceneGraph.ps1 -Watch 20        # re-read every second, report what MOVED
#
# The renderer draws each room's .XAF in its rest pose and never looks at the engine's scene
# again, which is why doors do not animate, picked-up items keep being drawn, and characters
# are missing. This is the reader that fixes all three -- and -Watch is the proof: open a
# door and the node that moves is named here.
[CmdletBinding()]
param(
    [string]$Sym = '',
    [int]$MaxNodes = 600,
    [int]$Watch = 0,            # seconds to keep sampling (0 = one shot)
    [double]$MoveEps = 0.5      # world-translation change that counts as movement
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
if (-not $Sym) { $Sym = Join-Path $toolDir '..\AztMod.overlay.sym' }
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -Path (Join-Path $toolDir 'SceneGraph.cs') -ErrorAction Stop

$symMap = @{}
foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Sym).Path)) {
    if ($l -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') { $symMap[$Matches[2]] = [uint32]('0x'+$Matches[1]) }
}
$g = Get-AztGuestBase
$rec = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $symMap['aztCamRec'] + 0x1F0000), 320)
if (-not $rec) { throw 'could not read aztCamRec' }
if ([Text.Encoding]::ASCII.GetString($rec,0,4) -ne 'CAM1') { throw "aztCamRec has no CAM1 magic" }
$camObj = [BitConverter]::ToUInt32($rec, 16)
if ($camObj -lt 0x1000) { throw 'no scene loaded yet' }

$root = [AztTool.SceneGraph]::RootOf($g.ProcessId, [long]$g.MemBase, $camObj)
Write-Host ("camera frame 0x{0:X}, scene root 0x{1:X}" -f $camObj, $root)

function Snap { ,([AztTool.SceneGraph]::Walk($g.ProcessId, [long]$g.MemBase, $root, $MaxNodes)) }

$nodes = Snap
Write-Host ("{0} frames; {1} carry a visual" -f $nodes.Count, @($nodes | Where-Object { $_.VisualCount -gt 0 }).Count)
Write-Host ''
Write-Host ("{0,-20} {1,5} {2,10} {3,10} {4,10}  {5}" -f 'name','depth','x','y','z','visuals')
foreach ($n in ($nodes | Sort-Object Depth, Name)) {
    if (-not $n.Name) { continue }
    Write-Host ("{0,-20} {1,5} {2,10:N1} {3,10:N1} {4,10:N1}  {5}" -f `
        $n.Name, $n.Depth, $n.World[12], $n.World[13], $n.World[14], $n.VisualCount)
}

if ($Watch -gt 0) {
    Write-Host ''
    Write-Host ("watching {0}s -- open a door or pick something up; whatever MOVES is listed" -f $Watch) -ForegroundColor Cyan
    $prev = @{}
    foreach ($n in $nodes) { $prev[$n.Frame] = @($n.World[12], $n.World[13], $n.World[14]) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $seenMove = @{}
    while ($sw.Elapsed.TotalSeconds -lt $Watch) {
        Start-Sleep -Milliseconds 400
        $cur = Snap
        $live = @{}
        foreach ($n in $cur) {
            $live[$n.Frame] = 1
            if ($prev.ContainsKey($n.Frame)) {
                $p = $prev[$n.Frame]
                $d = [Math]::Sqrt([Math]::Pow($n.World[12]-$p[0],2) + [Math]::Pow($n.World[13]-$p[1],2) + [Math]::Pow($n.World[14]-$p[2],2))
                if ($d -gt $MoveEps) {
                    $key = "$($n.Frame)"
                    if (-not $seenMove.ContainsKey($key)) {
                        Write-Host ("  MOVED  {0,-20} by {1,8:N1}  -> {2:N1} {3:N1} {4:N1}" -f `
                            $(if($n.Name){$n.Name}else{"0x$('{0:X}' -f $n.Frame)"}), $d, $n.World[12], $n.World[13], $n.World[14]) -ForegroundColor Yellow
                        $seenMove[$key] = 1
                    }
                }
            } else {
                Write-Host ("  ADDED  {0}" -f $(if($n.Name){$n.Name}else{"0x$('{0:X}' -f $n.Frame)"})) -ForegroundColor Green
            }
            $prev[$n.Frame] = @($n.World[12], $n.World[13], $n.World[14])
        }
        foreach ($k in @($prev.Keys)) { if (-not $live.ContainsKey($k)) { Write-Host ("  REMOVED frame 0x{0:X}" -f $k) -ForegroundColor Magenta; $prev.Remove($k) } }
    }
}
