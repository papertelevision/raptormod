# What the game's 3D map leaves out of a room, for Room Review's map-look wireframe (Josh, 2026-10-14: "for wireframe view, ideally
# it would look exactly like the map view with the teal colors and planes in place just like the maps"). The SAME rules as the game
# (LoadRoom.ps1 Get-AztMapSkip + Get-AztMapCut: doorway pictures, characters, black occluders, stray parts, the room's "map"
# settings), written as the hidden triangles' middles -- the viewer's OBJ has the same triangles in the same coordinates (checked:
# SPAROOM 671/671, MINEHEAD 1158/1161) -- and the cut under the floor.
#   { room, made, hidden: ["x,y,z" to 0.1, ...], cut: { y, keep: [parts] } | null }
param([Parameter(Mandatory)][string]$Room, [Parameter(Mandatory)][string]$Out, [string]$CacheDir = 'C:\Games\azrael-render')
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'), (Join-Path $toolDir 'SceneGraph.cs'),
                 (Join-Path $toolDir 'Keys.cs'), (Join-Path $toolDir 'Overlay.cs'), (Join-Path $toolDir 'Motes.cs'), (Join-Path $toolDir 'GpuRaster.cs'),
                 (Join-Path $toolDir 'GiBake.cs')) -ReferencedAssemblies System.Drawing, System.Web.Extensions
. (Join-Path $toolDir 'LoadRoom.ps1')
$Room = $Room.ToUpperInvariant()
$r = Import-AztRoom -Rooms @($Room) -CacheDir $CacheDir
$inv = [Globalization.CultureInfo]::InvariantCulture
$key = { param([int]$t) $c = @(0.0, 0.0, 0.0); for ($q = 0; $q -lt 3; $q++) { $vi = [int]$r.T[$t * 3 + $q] * 3; for ($a = 0; $a -lt 3; $a++) { $c[$a] += $r.V[$vi + $a] } }
    '{0},{1},{2}' -f ($c[0] / 3).ToString('F1', $inv), ($c[1] / 3).ToString('F1', $inv), ($c[2] / 3).ToString('F1', $inv) }
$hidden = New-Object 'System.Collections.Generic.List[string]'
foreach ($t in (Get-AztMapSkip -Room $r -Files @($Room) -CacheDir $CacheDir)) { $hidden.Add((& $key ([int]$t))) }
$cut = $null
$mc = Get-AztMapCut -Room $r -Files @($Room) -CacheDir $CacheDir
if ($mc) {
    $keepParts = @{}; for ($t = 0; $t -lt $mc.Tris.Length; $t++) { if (-not $mc.Tris[$t]) { $keepParts[[string]$r.Parts[[int]$r.TriPart[$t]].Name] = 1 } }
    $cut = [ordered]@{ y = [double]$mc.Y; keep = @($keepParts.Keys) }
}
$doc = [ordered]@{ room = $Room; made = [DateTime]::UtcNow.ToString('o'); triangles = [int]$r.TriPart.Length; hidden = $hidden.ToArray(); cut = $cut }
New-Item -ItemType Directory -Force (Split-Path $Out -Parent) | Out-Null
$tmp = $Out + '.tmp'
[IO.File]::WriteAllText($tmp, (ConvertTo-Json $doc -Depth 5 -Compress), (New-Object Text.UTF8Encoding $false))
Move-Item $tmp $Out -Force
