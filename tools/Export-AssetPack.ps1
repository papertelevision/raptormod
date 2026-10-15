# Export-AssetPack.ps1 -- pack the data that is NOT in git, for setting up another PC (see SETUP.md).
#
#   powershell -ExecutionPolicy Bypass -File tools\Export-AssetPack.ps1 -OutDir E:\raptormod-assets
#   powershell -ExecutionPolicy Bypass -File tools\Export-AssetPack.ps1 -OutDir E:\raptormod-assets -Include all
#
# Writes one .tar per component plus pack.json into -OutDir. Plain tar (Windows' own tar.exe): the big files are PNG, MOV
# and MP3 already, so compressing them again buys almost nothing and costs a lot of time. Restore on the other PC with
# tools\Setup-Machine.ps1 -AssetPack <that folder>.
#
# THE PACK HOLDS A COPY OF THE GAME (the built install). It is for Josh's own machines: keep it on a private drive or a
# private cloud folder -- never a public place.
#
# Components (default: install, hires, books, gfx; -Include all adds the optional ones):
#   install    C:\Games\AzraelsTear-Modded       the built game: DOSBox Staging + its conf and soundfont, the extracted and
#                                                upscaled GAME\AZTEX, the re-encoded movies, the CD soundtrack, saves
#   hires      C:\Games\azrael-textures\hires    the renderer's hi-res textures (~6 GB: Real-ESRGAN runs + Josh's 4K art)
#   books      C:\Games\azrael-books             the upscaled book pages (an install input)
#   gfx        C:\Games\azrael-gfx               Josh's sources only: decals\<ROOM>\updated, screens, credits, orrery-puzzle,
#                                                (the title's manual text + print-out list are in git: raptordocs\; their scans are credits\)
#   audio      Desktop\AzraelTearSoundtrack      optional: soundtrack / boot-sound sources (Build-Soundtrack, loading audio)
#   video      C:\Games\azrael-video\update      optional: the MP4 sources the movies are re-encoded from
#   realesrgan C:\Games\realesrgan               optional: the upscaler (only for re-running upscales / HUD builds)
#   rmfiles    Desktop\RaptorModFiles            optional: Josh's working files (3D, audio, updated art, the opening MP4s)
#   gfxextra   C:\Games\azrael-gfx               optional: Josh's 4K/2K decal sources (decals\<ROOM>\4k-2k, ~3 GB) and wire\

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string[]]$Include = @('install', 'hires', 'books', 'gfx'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $tar)) { throw "tar.exe not found at $tar" }
$desk = [Environment]::GetFolderPath('Desktop')

# name -> root (the folder the tar is made FROM and restored INTO), the paths inside it, excludes, restore root token
$all = [ordered]@{
    install    = @{ Root = 'C:\Games'; Paths = @('AzraelsTear-Modded'); Restore = 'C:\Games'
                    Exclude = @('AzraelsTear-Modded/AztMod', 'AzraelsTear-Modded/.claude', 'AzraelsTear-Modded/capture', '*.log', '*.LOG', 'AzraelsTear-Modded/stdout.txt') }
    hires      = @{ Root = 'C:\Games\azrael-textures'; Paths = @('hires'); Restore = 'C:\Games\azrael-textures'; Exclude = @() }
    books      = @{ Root = 'C:\Games'; Paths = @('azrael-books'); Restore = 'C:\Games'; Exclude = @('azrael-books/before') }
    gfx        = @{ Root = 'C:\Games'; Paths = $null; Restore = 'C:\Games'; Exclude = @() }
    audio      = @{ Root = $desk; Paths = @('AzraelTearSoundtrack'); Restore = '%DESKTOP%'; Exclude = @() }
    video      = @{ Root = 'C:\Games\azrael-video'; Paths = @('update'); Restore = 'C:\Games\azrael-video'; Exclude = @() }
    realesrgan = @{ Root = 'C:\Games'; Paths = @('realesrgan'); Restore = 'C:\Games'; Exclude = @() }
    rmfiles    = @{ Root = $desk; Paths = @('RaptorModFiles'); Restore = '%DESKTOP%'; Exclude = @() }
    gfxextra   = @{ Root = 'C:\Games'; Paths = $null; Restore = 'C:\Games'; Exclude = @() }
}
# gfx: Josh's own sources only (the rest of azrael-gfx is a regenerable export)
$gfx = @()
foreach ($d in @('screens', 'credits', 'orrery-puzzle')) { if (Test-Path (Join-Path 'C:\Games\azrael-gfx' $d)) { $gfx += "azrael-gfx/$d" } }
if (Test-Path 'C:\Games\azrael-gfx\decals') {
    Get-ChildItem 'C:\Games\azrael-gfx\decals' -Directory | ForEach-Object { if (Test-Path (Join-Path $_.FullName 'updated')) { $gfx += "azrael-gfx/decals/$($_.Name)/updated" } }
}
$all.gfx.Paths = $gfx
# gfxextra: the decal SOURCES Fit-RoomTextures makes the hi-res textures from (4k-2k), and the wire art
$gx = @(); if (Test-Path 'C:\Games\azrael-gfx\wire') { $gx += 'azrael-gfx/wire' }
if (Test-Path 'C:\Games\azrael-gfx\decals') {
    Get-ChildItem 'C:\Games\azrael-gfx\decals' -Directory | ForEach-Object { if (Test-Path (Join-Path $_.FullName '4k-2k')) { $gx += "azrael-gfx/decals/$($_.Name)/4k-2k" } }
}
$all.gfxextra.Paths = $gx

if ($Include -contains 'all') { $Include = @($all.Keys) }
foreach ($n in $Include) { if (-not $all.Contains($n)) { throw "unknown component '$n' (known: $($all.Keys -join ', '), all)" } }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# A NETWORK FOLDER (the NAS): tar.exe writes in 10 KB records, and over SMB each one waits on the network -- MEASURED 2.2 MB/s
# to the NAS over Wi-Fi, against 58 MB/s for robocopy /J's large unbuffered writes (2026-10-15). So each tar is made on this
# PC first, copied over with robocopy /J, and the local copy removed.
$stage = $null
if ($OutDir.StartsWith('\\') -or ([IO.DriveInfo]::new([IO.Path]::GetPathRoot((Resolve-Path $OutDir).Path)).DriveType -eq 'Network')) {
    $stage = Join-Path $env:TEMP 'raptormod-pack-stage'; New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Write-Host "network folder: each tar is built in $stage, then copied over with robocopy /J" -ForegroundColor DarkCyan
}
$commit = ''; try { $git = Get-Command git -ErrorAction Stop; $commit = (& $git.Source -C (Split-Path -Parent $PSScriptRoot) rev-parse --short HEAD 2>$null) } catch { }
$pack = [ordered]@{ created = (Get-Date).ToString('s'); fromComputer = $env:COMPUTERNAME; repoCommit = $commit; components = @() }

foreach ($n in $Include) {
    $c = $all[$n]
    $paths = @($c.Paths | Where-Object { $_ -and (Test-Path (Join-Path $c.Root ($_ -replace '/', '\'))) })
    if (-not $paths.Count) { Write-Host ("{0,-10} skipped: nothing at {1}" -f $n, $c.Root) -ForegroundColor Yellow; continue }
    $out = Join-Path $OutDir "$n.tar"
    if ((Test-Path $out) -and -not $Force) { Write-Host ("{0,-10} skipped: {1} exists (-Force to rebuild)" -f $n, $out) -ForegroundColor Yellow; continue }
    $make = if ($stage) { Join-Path $stage "$n.tar" } else { $out }
    $targs = @('-cf', $make, '-C', $c.Root)
    foreach ($x in $c.Exclude) { $targs += @('--exclude', $x) }
    $targs += $paths
    Write-Host ("{0,-10} packing {1} ..." -f $n, ($paths -join ', ')) -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $tar @targs
    if ($LASTEXITCODE -ne 0) { throw "tar failed for $n (exit $LASTEXITCODE)" }
    if ($stage) {
        $tc = $sw.Elapsed.TotalSeconds
        & robocopy $stage $OutDir "$n.tar" /J /IS /IT /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "copying $n.tar to $OutDir failed (robocopy exit $LASTEXITCODE)" }
        if ((Get-Item $out).Length -ne (Get-Item $make).Length) { throw "$n.tar on $OutDir is not the size of the one made here" }
        [IO.File]::Delete($make)
        Write-Host ("{0,-10} built in {1:N0} s, copied in {2:N0} s" -f $n, $tc, ($sw.Elapsed.TotalSeconds - $tc)) -ForegroundColor DarkCyan
    }
    $len = (Get-Item $out).Length
    Write-Host ("{0,-10} {1:N0} MB in {2:N0} s -> {3}" -f $n, ($len / 1MB), $sw.Elapsed.TotalSeconds, $out) -ForegroundColor Green
    $pack.components += [ordered]@{ name = $n; tar = "$n.tar"; restore = $c.Restore; paths = $paths; bytes = $len }
}
# pack.json: merged with what is already there (components packed in an earlier run stay listed)
$pj = Join-Path $OutDir 'pack.json'
if (Test-Path $pj) {
    $old = Get-Content $pj -Raw | ConvertFrom-Json
    foreach ($oc in @($old.components)) { if (-not ($pack.components | Where-Object { $_.name -eq $oc.name })) { $pack.components += $oc } }
}
[IO.File]::WriteAllText($pj, ($pack | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
$tot = 0; foreach ($pc in $pack.components) { $tot += [long]$pc.bytes }
Write-Host ""
Write-Host ("pack: {0} component(s), {1:N1} GB in {2}" -f $pack.components.Count, ($tot / 1GB), $OutDir) -ForegroundColor Green
# the one-click installer goes next to the pack: on a fresh PC (Steam game only) double-click Install-RaptorMod.cmd there
foreach ($f in 'Install-RaptorMod.ps1', 'Install-RaptorMod.cmd') { Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $OutDir $f) -Force }
Write-Host "On the other PC: double-click $(Join-Path $OutDir 'Install-RaptorMod.cmd') (Steam + the game installed first)"
Write-Host "  or, with the repo already cloned: powershell -ExecutionPolicy Bypass -File AztMod\tools\Setup-Machine.ps1 -AssetPack <this folder>"
