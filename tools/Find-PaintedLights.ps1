# Find-PaintedLights.ps1 -- where a room's ORIGINAL art paints its light, as torch positions (2026-10-09, Josh, Room Review
# MINEMAZE/1: "random lighting throughout with no light source ... add real light sources throughout in the bright areas,
# lit by the torches we've designed").
#
# The room's surfaces are sampled from the game's own pixels into a smoothed floor plan of how bright the art is
# (GpuRaster.BuildPaintField, the same map the painted darkness uses). Its brightest places, at least -Spacing apart, are
# the painted light pools. For each: the floor under it (a ray up from below the room), then rays round it at torch height
# for the nearest wall; the torch goes on that wall facing the pool, -OffWall units out, -Height above the floor.
# Prints the lights as room-file JSON (lights[] entries with "torch"), nearest wall first; -Map saves a picture.
#
#   .\tools\Find-PaintedLights.ps1 -Room MINEMAZE [-Count 6] [-Spacing 220] [-Height 72] [-OffWall 15] [-Map file.png]
param(
    [Parameter(Mandatory)][string]$Room,
    [int]$Count = 6, [double]$Spacing = 220, [double]$Height = 72, [double]$OffWall = 15, [double]$WallMax = 160,
    [double]$MinBright = 0.6,          # a pool must be at least this share of the room's bright level
    [switch]$Peaks,                    # only local maxima (small pools); without it, bright areas are covered evenly (brightest first, -Spacing apart)
    [string]$Map = ''
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolDir 'GuestBase.ps1'); . (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'GpuRaster.cs'), (Join-Path $toolDir 'GiBake.cs'), (Join-Path $toolDir 'Overlay.cs'), (Join-Path $toolDir 'Motes.cs'), (Join-Path $toolDir 'Particles.cs'), (Join-Path $toolDir 'ScanWire.cs'), (Join-Path $toolDir 'BootHd.cs'), (Join-Path $toolDir 'Panel.cs'), (Join-Path $toolDir 'Pointer.cs'), (Join-Path $toolDir 'Keys.cs')) -ReferencedAssemblies 'System.Drawing', 'System.Web.Extensions'
Add-Type -AssemblyName System.Drawing
$wp = Join-Path $toolDir 'Watch-HostRender.ps1'; $tk = $null; $pe = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($wp, [ref]$tk, [ref]$pe)
foreach ($fn in 'ConvertTo-Rgb24', 'Get-CharacterSig', 'Get-Room') { $fd = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true); if ($fd) { . ([scriptblock]::Create($fd.Extent.Text)) } }
function Say([string]$m, [string]$c = 'Gray') { }
$CacheDir = 'C:\Games\RaptorMod\cache'; $TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX'; $Palette = 'C:\Games\RaptorMod\cache\azrael-palette.pal'
$W = 1600; $H = 928; $CacheRooms = 8; $TrueColour = $true; $NoRgb = $false; $TexOverrideDir = 'C:\Games\RaptorMod\textures\hires'; $TexScale = 1; $NoReflections = $false
$roomCache = New-Object System.Collections.Specialized.OrderedDictionary
$pal = [IO.File]::ReadAllBytes($Palette)
$rm = Get-Room @($Room.ToUpperInvariant())
$e = $null; $gpu = [AztTool.GpuRaster]::Create(64, 64, [ref]$e); if (-not $gpu) { throw $e }
try {
    $gpu.BuildPaintField($rm.V, $rm.UV, $rm.T, $rm.TexIdx, $rm.Texes, $true, 8, 30, 1.5, $pal)
    $nx = 0; $nz = 0; $x0 = 0.0; $z0 = 0.0; $cx = 0.0; $cz = 0.0; $bright = 0.0
    $lum = $gpu.PaintLum([ref]$nx, [ref]$nz, [ref]$x0, [ref]$z0, [ref]$cx, [ref]$cz, [ref]$bright)
    if ($Map) { $gpu.SavePaintField($Map) }
} finally { $gpu.Dispose() }
# the room's vertical extent, for the floor rays
$v = $rm.V; $ymin = [double]::MaxValue; $ymax = [double]::MinValue; for ($i = 1; $i -lt $v.Length; $i += 3) { if ($v[$i] -lt $ymin) { $ymin = $v[$i] }; if ($v[$i] -gt $ymax) { $ymax = $v[$i] } }
# local maxima of brightness (within half the spacing), brightest first
$rad = [int][Math]::Ceiling(($Spacing / 2) / $cx); $cands = New-Object System.Collections.Generic.List[object]
for ($z = 0; $z -lt $nz; $z++) { for ($x = 0; $x -lt $nx; $x++) {
    $l = $lum[$z * $nx + $x]; if ($l -lt $bright * $MinBright) { continue }
    $isMax = $true
    if ($Peaks) { for ($dz = -$rad; $dz -le $rad -and $isMax; $dz += 2) { for ($dx = -$rad; $dx -le $rad; $dx += 2) { $xx = $x + $dx; $zz = $z + $dz; if ($xx -lt 0 -or $zz -lt 0 -or $xx -ge $nx -or $zz -ge $nz) { continue }; if ($lum[$zz * $nx + $xx] -gt $l) { $isMax = $false; break } } } }
    if ($isMax) { $cands.Add([pscustomobject]@{ X = $x0 + ($x + 0.5) * $cx; Z = $z0 + ($z + 0.5) * $cz; L = $l }) }
} }
$picked = New-Object System.Collections.Generic.List[object]
foreach ($c in ($cands | Sort-Object L -Descending)) {
    if ($picked.Count -ge $Count) { break }
    $near = $false; foreach ($p in $picked) { if ([Math]::Sqrt(($p.X - $c.X) * ($p.X - $c.X) + ($p.Z - $c.Z) * ($p.Z - $c.Z)) -lt $Spacing) { $near = $true; break } }
    if ($near) { continue }
    # the floor under it: up from below the room, the first surface
    $up = [AztTool.Raster]::RayDistance($rm.V, $rm.T, $rm.TexIdx, [single]$c.X, [single]($ymin - 5), [single]$c.Z, 0, 1, 0, [single]($ymax - $ymin + 10))
    if ($up -ge ($ymax - $ymin + 10)) { continue }
    $floor = $ymin - 5 + $up; $ty = $floor + $Height
    # the nearest wall round it at torch height
    $best = $null
    for ($k = 0; $k -lt 24; $k++) {
        $a = 2 * [Math]::PI * $k / 24; $dx = [Math]::Cos($a); $dz = [Math]::Sin($a)
        $d = [AztTool.Raster]::RayDistance($rm.V, $rm.T, $rm.TexIdx, [single]$c.X, [single]$ty, [single]$c.Z, [single]$dx, 0, [single]$dz, [single]$WallMax)
        if ($d -lt $WallMax -and (-not $best -or $d -lt $best.D)) { $best = [pscustomobject]@{ D = $d; DX = $dx; DZ = $dz } }
    }
    if (-not $best -or $best.D -lt $OffWall + 2) { continue }
    $wx = $c.X + $best.DX * $best.D; $wz = $c.Z + $best.DZ * $best.D
    $lx = $wx - $best.DX * $OffWall; $lz = $wz - $best.DZ * $OffWall
    $picked.Add([pscustomobject]@{ X = $c.X; Z = $c.Z; L = $c.L; Floor = $floor; LX = $lx; LY = $ty; LZ = $lz; NX = -$best.DX; NZ = -$best.DZ; Wall = $best.D })
}
"{0}: art's bright level {1:N0}; {2} candidate pools, {3} torches placed (spacing {4}, wall within {5})" -f $Room, $bright, $cands.Count, $picked.Count, $Spacing, $WallMax
$i = 0
foreach ($p in $picked) {
    $i++
    '    {{ "name": "torch {0} (painted light pool at {1:N0}, {2:N0})", "x": {3:0.##}, "y": {4:0.##}, "z": {5:0.##}, "dir": [ {6:0.###}, 0, {7:0.###} ], "shadow": true, "color": "#FFB266", "power": 1.4, "range": 260, "flicker": 0.35, "torch": {{ "scale": 1, "wall": {8} }} }}' -f $i, $p.X, $p.Z, $p.LX, $p.LY, $p.LZ, $p.NX, $p.NZ, $OffWall
}
