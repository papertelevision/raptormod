# Setup-Machine.ps1 -- make this PC ready to work on RaptorMod (see SETUP.md). Safe to run again at any time.
#
#   powershell -ExecutionPolicy Bypass -File tools\Setup-Machine.ps1 -AssetPack E:\raptormod-assets
#   powershell -ExecutionPolicy Bypass -File tools\Setup-Machine.ps1                 (no pack: just the links and derived files)
#
# What it does, in order (each step says what it did, or why it skipped):
#   1. checks the repo sits in the Steam game folder (<Steam library>\steamapps\common\Azrael's Tear\AztMod)
#   2. -AssetPack: restores the pack's tar files (tools\Export-AssetPack.ps1) to their places -- a folder that already
#      exists is left alone unless -Force
#   3. C:\Games\azrael-render\rooms and \room-notes -> junctions to this repo's rooms\ and room-notes\ (the tools all read
#      the old paths): the room settings and Room Review's notes are versioned; the notes' screenshots stay on each PC
#   4. C:\Games\azrael-inject\azrael-palette.pal <- runtime\azrael-palette.pal (the renderer needs it)
#   5. art\title\title-music.wav <- decoded from art\title\title-music.mp3 (the title's music player wants PCM)
#   6. with the game installed at C:\Games\AzraelsTear-Modded: Apply-AztMod -Install (this repo's patches), then the
#      manifest is recorded as installed (Install-Update.cmd diffs against it)
#   7. every room's cached export (tools\Build-RoomCache.ps1: the OBJ/textures Room Review's 3D viewer shows, and the
#      renderer's units) -- a few minutes the first time, seconds after; -SkipRoomCache to leave it to first use
#   8. a desktop shortcut to Play-HostRender-TrueColour.cmd
# The game is never launched.

[CmdletBinding()]
param(
    [string]$AssetPack = '',
    [string]$GameDest = 'C:\Games\AzraelsTear-Modded',
    [switch]$Force,
    [switch]$SkipInstall,
    [switch]$SkipRoomCache,
    [switch]$NoShortcut
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
function Step($s) { Write-Host ""; Write-Host "== $s" -ForegroundColor Cyan }
function Ok($s) { Write-Host "   $s" -ForegroundColor Green }
function Warn($s) { Write-Host "   $s" -ForegroundColor Yellow }
$problems = @()

# ---- 1. where the repo is -------------------------------------------------------------------------------------------
Step 'repo location'
$steamGame = Split-Path -Parent $repo
if (Test-Path (Join-Path $steamGame 'GAME\AZRAEL\R.EXE')) { Ok "in the Steam game folder: $steamGame" }
else {
    Warn "NOT inside the Steam game folder (no ..\GAME\AZRAEL\R.EXE next to $repo)."
    Warn "Clone it to <Steam library>\steamapps\common\Azrael's Tear\AztMod -- the build scripts read the stock game from there."
    $problems += 'repo location'
}
if ((Split-Path -Leaf $repo) -ne 'AztMod') { Warn "the folder is '$(Split-Path -Leaf $repo)', not 'AztMod' (the launchers and docs assume AztMod)"; $problems += 'folder name' }

# ---- 2. the asset pack ----------------------------------------------------------------------------------------------
if ($AssetPack) {
    Step "asset pack: $AssetPack"
    $pj = Join-Path $AssetPack 'pack.json'
    if (-not (Test-Path $pj)) { throw "no pack.json in $AssetPack (make one with tools\Export-AssetPack.ps1)" }
    $pack = Get-Content $pj -Raw | ConvertFrom-Json
    Ok ("made {0} on {1}, repo {2}" -f $pack.created, $pack.fromComputer, $pack.repoCommit)
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $need = 0; foreach ($c in @($pack.components)) { $need += [long]$c.bytes }
    $free = (Get-PSDrive C).Free
    if ($free -lt $need * 1.1) { Warn ("C: has {0:N1} GB free; the pack needs about {1:N1} GB" -f ($free / 1GB), ($need / 1GB)) }
    foreach ($c in @($pack.components)) {
        $dest = ([string]$c.restore).Replace('%DESKTOP%', [Environment]::GetFolderPath('Desktop')).Replace('%REPO%', $repo)
        $file = Join-Path $AssetPack $c.tar
        if (-not (Test-Path $file)) { Warn "$($c.name): $($c.tar) missing from the pack -- skipped"; continue }
        $present = @($c.paths | Where-Object { Test-Path (Join-Path $dest ($_ -replace '/', '\')) })
        if ($present.Count -and -not $Force) { Ok ("{0}: already here ({1}) -- left alone (-Force to restore over it)" -f $c.name, ($present -join ', ')); continue }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Write-Host ("   {0}: restoring {1:N0} MB into {2} ..." -f $c.name, ([long]$c.bytes / 1MB), $dest)
        & $tar -xf $file -C $dest
        if ($LASTEXITCODE -ne 0) { Warn "$($c.name): tar exit $LASTEXITCODE"; $problems += "pack $($c.name)" } else { Ok "$($c.name): restored" }
    }
}

# ---- 3. junctions: room settings and Room Review's notes ------------------------------------------------------------
function Set-RepoJunction([string]$link, [string]$target) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $link) | Out-Null
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $it = Get-Item $link -ErrorAction SilentlyContinue
    if ($it -and ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if ((@($it.Target) -join '') -eq $target) { Ok "$link : junction already in place"; return }
        Warn "$link : a junction is there but points to $($it.Target) -- relinking"; [IO.Directory]::Delete($link)
    } elseif ($it) {
        # a real folder (this PC's own, from before the repo): kept beside it; anything missing from the repo's copy is
        # copied in first (never overwriting), so nothing made on this PC is lost
        $keep = "$link.local-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Get-ChildItem -LiteralPath $link -File | Where-Object { -not (Test-Path (Join-Path $target $_.Name)) } | Copy-Item -Destination $target
        Rename-Item $link (Split-Path -Leaf $keep); Warn "$link : a real folder was there -- kept as $keep (files the repo lacked were copied in)"
    }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null; Ok "$link -> $target"
}
Step 'junctions (rooms\, room-notes\ -> C:\Games\azrael-render)'
Set-RepoJunction 'C:\Games\azrael-render\rooms' (Join-Path $repo 'rooms')
Set-RepoJunction 'C:\Games\azrael-render\room-notes' (Join-Path $repo 'room-notes')

# ---- 4. palette -----------------------------------------------------------------------------------------------------
Step 'palette'
$palDst = 'C:\Games\azrael-inject\azrael-palette.pal'; $palSrc = Join-Path $repo 'runtime\azrael-palette.pal'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $palDst) | Out-Null
if ((Test-Path $palDst) -and ((Get-FileHash $palDst).Hash -eq (Get-FileHash $palSrc).Hash)) { Ok 'up to date' }
else {
    if (Test-Path $palDst) { Copy-Item $palDst "$palDst.local" -Force; Warn "differed from the repo's: the old one kept as azrael-palette.pal.local" }
    Copy-Item $palSrc $palDst -Force; Ok "copied to $palDst"
}

# ---- 5. title music -------------------------------------------------------------------------------------------------
Step 'title music'
$mp3 = Join-Path $repo 'art\title\title-music.mp3'; $wav = Join-Path $repo 'art\title\title-music.wav'
if (-not (Test-Path $mp3)) { Warn 'art\title\title-music.mp3 missing'; $problems += 'title music' }
elseif ((Test-Path $wav) -and (Get-Item $wav).LastWriteTime -ge (Get-Item $mp3).LastWriteTime -and -not $Force) { Ok 'title-music.wav up to date' }
else {
    if (-not ('AztTool.AudioFx' -as [type])) { Add-Type -Path (Join-Path $repo 'tools\AudioFx.cs') }
    $ch = 0; $pcm = [AztTool.AudioFx]::DecodePcm($mp3, 44100, 2, [ref]$ch)
    [AztTool.AudioFx]::WriteWav($wav, $pcm, 44100, $ch)
    Ok ("decoded: {0:N1} s, {1:N0} MB" -f ($pcm.Length / $ch / 44100.0), ((Get-Item $wav).Length / 1MB))
}

# ---- 6. install the patches -----------------------------------------------------------------------------------------
Step "game install ($GameDest)"
if ($SkipInstall) { Warn 'skipped (-SkipInstall)' }
elseif (-not (Test-Path (Join-Path $GameDest 'GAME\AZRAEL\R.EXE'))) {
    Warn 'no built game there. Restore the pack''s "install" component (-AssetPack), or build one (see SETUP.md, "Building the install from scratch").'
    $problems += 'game install'
} elseif (Get-Process dosbox* -ErrorAction SilentlyContinue) { Warn 'DOSBox is running -- close the game and run this again to install the patches'; $problems += 'DOSBox running' }
else {
    & (Join-Path $repo 'Apply-AztMod.ps1') -Install -Dest $GameDest
    Copy-Item (Join-Path $repo 'AztMod.manifest.json') (Join-Path $repo 'AztMod.manifest.installed.json') -Force
    Ok 'patches installed; manifest recorded as installed'
}
foreach ($dep in @(@('DOSBox Staging', (Join-Path $GameDest 'DOSBOX-STAGING\dosbox.exe')), @('extracted textures (GAME\AZTEX)', (Join-Path $GameDest 'GAME\AZTEX')), @('hi-res textures', 'C:\Games\azrael-textures\hires'))) {
    if (Test-Path $dep[1]) { Ok "$($dep[0]): present" } else { Warn "$($dep[0]): MISSING ($($dep[1]))"; $problems += $dep[0] }
}

# ---- 7. the room cache ----------------------------------------------------------------------------------------------
Step 'room cache (Room Review''s 3D rooms, the renderer''s units)'
if ($SkipRoomCache) { Warn 'skipped (-SkipRoomCache): built on first use instead' }
elseif (-not (Test-Path (Join-Path $GameDest 'GAME\AZTEX'))) { Warn 'no GAME\AZTEX in the install yet -- run this again once the install is in place' }
else {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { & (Join-Path $repo 'tools\Build-RoomCache.ps1') *>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }; Ok ("done in {0:N0} s ({1} rooms exported for the viewer)" -f $sw.Elapsed.TotalSeconds, @(Get-ChildItem 'C:\Games\azrael-render' -Filter '*.obj' -File -ErrorAction SilentlyContinue).Count) }
    catch { Warn "Build-RoomCache failed: $($_.Exception.Message)"; $problems += 'room cache' }
}

# ---- 8. shortcut ----------------------------------------------------------------------------------------------------
if (-not $NoShortcut) {
    Step 'desktop shortcut'
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Azrael's Tear (Host Renderer - true colour).lnk"
    if (Test-Path $lnk) { Ok 'already there' }
    else {
        $sh = New-Object -ComObject WScript.Shell; $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = Join-Path $repo 'Play-HostRender-TrueColour.cmd'; $s.WorkingDirectory = $repo; $s.Save(); Ok "made: $lnk"
    }
}

Write-Host ""
if ($problems.Count) { Write-Host ("setup finished with {0} thing(s) to sort out: {1}" -f $problems.Count, ($problems -join '; ')) -ForegroundColor Yellow }
else { Write-Host 'setup finished: this PC is ready (play with the desktop shortcut)' -ForegroundColor Green }
