# Build every room's and every character's cached unit ahead of time.
#
#   .\tools\Build-RoomCache.ps1
#   .\tools\Build-RoomCache.ps1 -Only MINEHEAD,RAPTOR
#
# Import-AztRoom caches each .XAF as a ready-to-draw unit (tools\RoomUnit.cs) the first time
# it is needed, so only the FIRST visit to a room pays the second or so it takes to build.
# This pays all of those up front, so no room is ever a first visit while playing.
#
# Safe to re-run: units whose inputs have not changed are found in the cache and skipped.
# Re-run it after the palette is re-captured or the exporter changes -- both are part of
# every unit's stamp, so every unit is rebuilt then.
param(
    [string[]]$Only,
    [string]$TexDir   = "$(if ($env:RAPTORMOD_ROOT) { $env:RAPTORMOD_ROOT } else { 'C:\Games\RaptorMod' })\game\GAME\AZTEX",
    [string]$CacheDir = "$(if ($env:RAPTORMOD_ROOT) { $env:RAPTORMOD_ROOT } else { 'C:\Games\RaptorMod' })\cache",
    [string]$Palette  = "$(if ($env:RAPTORMOD_ROOT) { $env:RAPTORMOD_ROOT } else { 'C:\Games\RaptorMod' })\cache\azrael-palette.pal"
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
. (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'),
                 (Join-Path $toolDir 'SceneGraph.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

$pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)
$sha = [Security.Cryptography.SHA1]::Create()
try { $palHash = ([BitConverter]::ToString($sha.ComputeHash($pal)) -replace '-', '').Substring(0, 16) } finally { $sha.Dispose() }

$names = @(Get-ChildItem $TexDir -Filter '*.XAF' | Where-Object { $_.Length -gt 0 } | ForEach-Object { $_.BaseName } | Sort-Object)
if ($Only) { $names = @($names | Where-Object { $Only -contains $_ }) }
Write-Host ("{0} .XAF files, palette {1}" -f $names.Count, $palHash)

$built = 0; $cached = 0; $failed = @(); $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
foreach ($n in $names) {
    $i++
    $t = [Diagnostics.Stopwatch]::StartNew()
    try {
        $m = Get-AztUnit -Name $n -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette -PalHash $palHash 6>$null
        # under 150 ms means it came from the cache; a build is always far slower
        if ($t.ElapsedMilliseconds -lt 150) { $cached++ } else { $built++ }
        # do not hold 178 rooms of textures in memory just to have built them
        $script:AztUnitMem.Remove($n)
    } catch {
        $failed += ('{0}: {1}' -f $n, $_.Exception.Message)
    }
    if (($i % 20) -eq 0) { Write-Host ("  {0} / {1}  ({2:N0} s)" -f $i, $names.Count, $sw.Elapsed.TotalSeconds) }
}
Write-Host ("built {0}, already cached {1}, failed {2}, in {3:N0} s" -f $built, $cached, $failed.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor $(if ($failed.Count) { 'Yellow' } else { 'Green' })
foreach ($f in $failed) { Write-Host ("  FAILED {0}" -f $f) -ForegroundColor Yellow }
