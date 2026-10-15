# Setup-Machine.ps1 -- make this PC ready to work on RaptorMod (see SETUP.md). Safe to run again at any time.
#
#   powershell -ExecutionPolicy Bypass -File tools\Setup-Machine.ps1 -AssetPack E:\raptormod-assets
#   powershell -ExecutionPolicy Bypass -File tools\Setup-Machine.ps1                 (no pack: just the links and derived files)
#
# EVERYTHING ON THIS PC LIVES IN ONE FOLDER, C:\Games\RaptorMod (2026-10-15, Josh: "a single install folder"):
#   game\       the patched game (DOSBox Staging, its confs, saves, raptormod-settings.json)
#   cache\      the renderer's caches and watch.log; rooms\ and room-notes\ are junctions to this repo's
#   textures\   hires\ (the hi-res textures), hires-2048\ (made for Normal quality), hires-backup-*
#   sources\    books, gfx, video, realesrgan, soundtrack, files (Josh's working files)
#   scratch\    old research / test output
#   Play RaptorMod.cmd, Room Review.cmd -- and ONE desktop shortcut, RaptorMod
# The git repo stays in the Steam game folder (the build reads the stock game from there).
#
# What it does, in order (each step says what it did, or why it skipped):
#   1. checks the repo sits in the Steam game folder (<Steam library>\steamapps\common\Azrael's Tear\AztMod); the repo's git settings
#   2. MOVES the old layout in (C:\Games\AzraelsTear-Modded, azrael-render, azrael-textures, azrael-books, azrael-gfx, azrael-video,
#      realesrgan, Desktop\AzraelTearSoundtrack, Desktop\RaptorModFiles, the old test folders): a move, never a copy, and only
#      where the new place is still empty
#   3. -AssetPack: restores the pack's tar files (tools\Export-AssetPack.ps1) -- a part already there is left alone unless -Force
#   4. cache\rooms and \room-notes -> junctions to this repo's rooms\ and room-notes\; the palette into cache\
#   5. art\title\title-music.wav <- decoded from art\title\title-music.mp3 (the title's music player wants PCM)
#   6. Apply-AztMod -Install (this repo's patches) into game\, the manifest recorded as installed; the DOSBox conf's capture folder
#   7. every room's cached export (tools\Build-RoomCache.ps1) -- a few minutes the first time, seconds after
#   8. textures prepared: the shared-art index built and every hi-res texture read once (a fresh PC's first room took 61 s
#      otherwise -- 2026-10-15), and the graphics card checked (tools\Test-GpuCaps.ps1)
#   9. the launchers in C:\Games\RaptorMod and ONE desktop shortcut, RaptorMod (older RaptorMod shortcuts are removed)
#  10. a dry run of the launcher (AZT_DRYRUN: every step checked, nothing started)
# The game is never launched. tools\Install-RaptorMod.ps1 runs all of this on a fresh PC (clone + pack from the NAS).
[CmdletBinding()]
param(
    [string]$AssetPack = '',
    [string]$GameDest = 'C:\Games\RaptorMod\game',
    [switch]$Force,
    [switch]$SkipInstall,
    [switch]$SkipRoomCache,
    [switch]$NoShortcut
)
$Root = 'C:\Games\RaptorMod'
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

# ---- 1b. the repo's own git settings (byte-exact files, long paths, the author) -- only where unset ------------------
Step 'git settings'
$gitExe = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitExe -and (Test-Path 'C:\Program Files\Git\cmd\git.exe')) { $gitExe = Get-Item 'C:\Program Files\Git\cmd\git.exe' }
if (-not $gitExe -or -not (Test-Path (Join-Path $repo '.git'))) { Warn 'no git (or not a clone) -- skipped' }
else {
    $gx = if ($gitExe.Source) { $gitExe.Source } else { $gitExe.FullName }
    foreach ($kv in @(@('core.autocrlf', 'false'), @('core.longpaths', 'true'), @('user.name', 'Josh Sears'), @('user.email', 'josh@papertelevision.com'))) {
        $cur = (& $gx -C $repo config --local --get $kv[0]) 2>$null
        if ($cur) { Ok "$($kv[0]) = $cur" } else { & $gx -C $repo config --local $kv[0] $kv[1]; Ok "$($kv[0]) set to $($kv[1])" }
    }
}

# ---- 2. the old layout moves in -------------------------------------------------------------------------------------
Step "one folder: $Root"
New-Item -ItemType Directory -Force -Path $Root | Out-Null
$desk = [Environment]::GetFolderPath('Desktop')
$moves = @(
    @('C:\Games\AzraelsTear-Modded', 'game'), @('C:\Games\azrael-render', 'cache'), @('C:\Games\azrael-textures', 'textures'),
    @('C:\Games\azrael-books', 'sources\books'), @('C:\Games\azrael-gfx', 'sources\gfx'), @('C:\Games\azrael-video', 'sources\video'),
    @('C:\Games\realesrgan', 'sources\realesrgan'), @((Join-Path $desk 'AzraelTearSoundtrack'), 'sources\soundtrack'), @((Join-Path $desk 'RaptorModFiles'), 'sources\files'),
    @('C:\Games\azrael-inject', 'scratch\azrael-inject'), @('C:\Games\azrael-models', 'scratch\azrael-models'), @('C:\Games\azrael-rooms', 'scratch\azrael-rooms'),
    @('C:\Games\azrael-rooms2', 'scratch\azrael-rooms2'), @('C:\Games\azrael-compare', 'scratch\azrael-compare'), @('C:\Games\azrael-suppress3d', 'scratch\azrael-suppress3d'),
    @('C:\Games\azrael-stage7', 'scratch\azrael-stage7'), @('C:\Games\azrael-scene.json', 'scratch\azrael-scene.json'), @('C:\Games\azrael-zones.csv', 'scratch\azrael-zones.csv'),
    @('C:\Games\azrael-rooms.csv', 'scratch\azrael-rooms.csv'))
$moved = 0
foreach ($mv in $moves) {
    $old = $mv[0]; $new = Join-Path $Root $mv[1]
    if (-not (Test-Path -LiteralPath $old)) { continue }
    if (Test-Path -LiteralPath $new) { Warn "$old is still here, but $new exists too -- left as it is (move what you need by hand)"; $problems += "both $old and $new"; continue }
    if (($old -like 'C:\Games\AzraelsTear-Modded*') -and (Get-Process dosbox* -ErrorAction SilentlyContinue)) { Warn 'DOSBox is running -- close the game and run this again to move the game folder'; $problems += 'DOSBox running'; continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $new) | Out-Null
    try { Move-Item -LiteralPath $old -Destination $new -ErrorAction Stop; Ok "$old -> $new"; $moved++ }
    catch { Warn "could not move $old ($($_.Exception.Message)) -- close anything using it and run this again"; $problems += "move $old" }
}
if (-not $moved) { Ok 'nothing of the old layout left to move' }
# (the DOSBox conf's capture folder, and anything else in the game's confs, follow the game folder)
foreach ($cf in @(Get-ChildItem (Join-Path $Root 'game') -Filter '*.conf' -File -ErrorAction SilentlyContinue)) {
    $ct = [IO.File]::ReadAllText($cf.FullName)
    if ($ct -match '(?i)C:\\Games\\AzraelsTear-Modded') { [IO.File]::WriteAllText($cf.FullName, ($ct -replace '(?i)C:\\Games\\AzraelsTear-Modded', 'C:\Games\RaptorMod\game')); Ok "$($cf.Name): paths moved to the new game folder" }
}

# ---- 3. the asset pack ----------------------------------------------------------------------------------------------
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
        $dest = [string]$c.restore
        if ($dest -notlike "$Root*") { Warn "$($c.name): an older pack (restores into $dest) -- skipped; export the pack again from the PC that has everything"; $problems += "old pack $($c.name)"; continue }
        $file = Join-Path $AssetPack $c.tar
        if (-not (Test-Path $file)) { Warn "$($c.name): $($c.tar) missing from the pack -- skipped"; continue }
        $present = @($c.paths | Where-Object { Test-Path (Join-Path $dest ($_ -replace '/', '\')) })

        if ($present.Count -and -not $Force) { Ok ("{0}: already here ({1}) -- left alone (-Force to restore over it)" -f $c.name, ($present -join ', ')); continue }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Write-Host ("   {0}: restoring {1:N0} MB into {2} ..." -f $c.name, ([long]$c.bytes / 1MB), $dest)
        # (a pack on the NAS: tar reading in small pieces over SMB is slow -- the tar is first copied here in large blocks with
        # robocopy /J, unpacked, and the local copy removed; see Export-AssetPack)
        $local = $null
        if ($AssetPack.StartsWith('\\')) {
            $stage = Join-Path $env:TEMP 'raptormod-pack-stage'; New-Item -ItemType Directory -Force -Path $stage | Out-Null
            Write-Host ("   {0}: copying {1} from the network ..." -f $c.name, $c.tar)
            & robocopy $AssetPack $stage $c.tar /J /IS /IT /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -lt 8) { $local = Join-Path $stage $c.tar; $file = $local } else { Warn "$($c.name): robocopy exit $LASTEXITCODE -- unpacking straight from the network instead" }
        }
        & $tar -xf $file -C $dest
        if ($LASTEXITCODE -ne 0) { Warn "$($c.name): tar exit $LASTEXITCODE"; $problems += "pack $($c.name)" } else { Ok "$($c.name): restored" }
        if ($local -and (Test-Path $local)) { [IO.File]::Delete($local) }
    }
}

# ---- 4. junctions: room settings and Room Review's notes; the palette ------------------------------------------------
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
Step 'junctions (rooms\, room-notes\ -> C:\Games\RaptorMod\cache)'
Set-RepoJunction 'C:\Games\RaptorMod\cache\rooms' (Join-Path $repo 'rooms')
Set-RepoJunction 'C:\Games\RaptorMod\cache\room-notes' (Join-Path $repo 'room-notes')

# (the palette)
Step 'palette'
$palDst = 'C:\Games\RaptorMod\cache\azrael-palette.pal'; $palSrc = Join-Path $repo 'runtime\azrael-palette.pal'
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
    # (Media Foundation does the decoding: missing on Windows N editions without the Media Feature Pack. The title then has
    # no music -- the rest of the setup must still run)
    try {
        if ($env:AZT_SETUP_FAIL_DECODE) { throw 'forced decode failure (AZT_SETUP_FAIL_DECODE test)' }
        if (-not ('AztTool.AudioFx' -as [type])) { Add-Type -Path (Join-Path $repo 'tools\AudioFx.cs') }
        $ch = 0; $pcm = [AztTool.AudioFx]::DecodePcm($mp3, 44100, 2, [ref]$ch)
        [AztTool.AudioFx]::WriteWav($wav, $pcm, 44100, $ch)
        Ok ("decoded: {0:N1} s, {1:N0} MB" -f ($pcm.Length / $ch / 44100.0), ((Get-Item $wav).Length / 1MB))
    } catch { Warn "could not decode the title music ($($_.Exception.Message)) -- the title will be silent; install the Media Feature Pack and run this again"; $problems += 'title music' }
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
foreach ($dep in @(@('DOSBox Staging', (Join-Path $GameDest 'DOSBOX-STAGING\dosbox.exe')), @('extracted textures (GAME\AZTEX)', (Join-Path $GameDest 'GAME\AZTEX')), @('hi-res textures', 'C:\Games\RaptorMod\textures\hires'))) {
    if (Test-Path $dep[1]) { Ok "$($dep[0]): present" } else { Warn "$($dep[0]): MISSING ($($dep[1]))"; $problems += $dep[0] }
}

# ---- 7. the room cache ----------------------------------------------------------------------------------------------
Step 'room cache (Room Review''s 3D rooms, the renderer''s units)'
if ($SkipRoomCache) { Warn 'skipped (-SkipRoomCache): built on first use instead' }
elseif (-not (Test-Path (Join-Path $GameDest 'GAME\AZTEX'))) { Warn 'no GAME\AZTEX in the install yet -- run this again once the install is in place' }
else {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # (in its own PowerShell: the install above has already compiled C# types of the same names into this one -- "the type
    # name 'LeTool.Quant' already exists" -- and a session cannot load two)
    try {
        $rc = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\Build-RoomCache.ps1') 2>&1
        $rcExit = $LASTEXITCODE; @($rc) | Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }
        if ($rcExit -ne 0) { throw "exit $rcExit" }
        Ok ("done in {0:N0} s ({1} rooms exported for the viewer)" -f $sw.Elapsed.TotalSeconds, @(Get-ChildItem 'C:\Games\RaptorMod\cache' -Filter '*.obj' -File -ErrorAction SilentlyContinue).Count)
    }
    catch { Warn "Build-RoomCache failed: $($_.Exception.Message)"; $problems += 'room cache' }
}

# ---- 8. textures prepared, and the graphics card checked --------------------------------------------------------------
# (2026-10-15, the second PC: its first room took 61 s -- the shared-art index opens every hi-res texture and hashes every
# original, and on files just restored that is slow the first time; done here instead of under the visor boot)
Step 'textures prepared (the shared-art index; every hi-res texture read once)'
$hires = Join-Path $Root 'textures\hires'
if (-not (Test-Path $hires) -or -not (Test-Path (Join-Path $Root 'cache'))) { Warn 'no textures\hires or cache yet -- skipped' }
else {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $prep = @"
`$ErrorActionPreference = 'Stop'; . '$($repo.Replace("'", "''"))\tools\LoadRoom.ps1'
`$m = Get-AztTwinArt '$Root\cache' '$hires'; `$script:AztTwin.Note
"@
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $prep 2>&1
    if ($LASTEXITCODE -eq 0) { Ok ("shared-art index: {0} ({1:N0} s)" -f (@($out) -join ' '), $sw.Elapsed.TotalSeconds) } else { Warn "shared-art index failed: $(@($out) -join ' ')"; $problems += 'texture index' }
}
Step 'graphics card'
$gc = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\Test-GpuCaps.ps1') -CacheDir (Join-Path $Root 'cache') 2>&1
if ($LASTEXITCODE -eq 0) { Ok (@($gc) -join ' ') } else { Warn ((@($gc) -join ' ') + ' -- the game would run without the GPU picture'); $problems += 'graphics card' }

# ---- 9. the launchers and ONE desktop shortcut ------------------------------------------------------------------------
Step "launchers ($Root) and the desktop shortcut"
$playCmd = Join-Path $Root 'Play RaptorMod.cmd'; $reviewCmd = Join-Path $Root 'Room Review.cmd'
[IO.File]::WriteAllText($playCmd, "@echo off`r`nREM RaptorMod -- the GPU version (the host renderer starts the game). Made by tools\Setup-Machine.ps1.`r`ncall `"$(Join-Path $repo 'Play-HostRender-TrueColour.cmd')`" %*`r`n", (New-Object Text.ASCIIEncoding))
[IO.File]::WriteAllText($reviewCmd, "@echo off`r`nREM Room Review (the room-settings viewer). Made by tools\Setup-Machine.ps1.`r`ncall `"$(Join-Path $repo 'Review-Rooms.cmd')`" %*`r`n", (New-Object Text.ASCIIEncoding))
Ok "wrote $playCmd and $reviewCmd"
if (-not $NoShortcut) {
    $sh = New-Object -ComObject WScript.Shell
    # older RaptorMod shortcuts (anything on the desktop that starts something in the repo or the game folder) go: ONE remains
    foreach ($l in @(Get-ChildItem $desk -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
        if ($l.Name -eq 'RaptorMod.lnk') { continue }
        $tp = [string]$sh.CreateShortcut($l.FullName).TargetPath
        if ($tp -and ($tp -like "$repo\*" -or $tp -like 'C:\Games\AzraelsTear-Modded\*' -or $tp -like "$Root\*")) { [IO.File]::Delete($l.FullName); Ok "removed the old shortcut $($l.Name)" }
    }
    $lnk = Join-Path $desk 'RaptorMod.lnk'; $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = $playCmd; $s.WorkingDirectory = $Root; $s.Description = "Azrael's Tear with RaptorMod (the GPU version)"
    $ico = Join-Path $Root 'game\DOSBOX-STAGING\dosbox.exe'; if (Test-Path $ico) { $s.IconLocation = "$ico,0" }
    $s.Save(); Ok "desktop: RaptorMod -> $playCmd"
}
# ---- 10. the launcher, dry run ----------------------------------------------------------------------------------------
Step 'launcher check (dry run: nothing is started)'
$env:AZT_DRYRUN = '1'
try { $out = & cmd /c "call `"$(Join-Path $repo 'Play-HostRender.cmd')`"" 2>&1; $out | ForEach-Object { Write-Host "   $_" } }
finally { [Environment]::SetEnvironmentVariable('AZT_DRYRUN', $null, 'Process'); [Environment]::SetEnvironmentVariable('AZT_HOSTRENDER_MIN', $null, 'Process') }
if (($out -join "`n") -match 'renderer script found') { Ok 'the launcher finds the game and the renderer' } else { Warn 'the launcher dry run did not pass (see above)'; $problems += 'launcher' }

Write-Host ""
if ($problems.Count) { Write-Host ("setup finished with {0} thing(s) to sort out: {1}" -f $problems.Count, ($problems -join '; ')) -ForegroundColor Yellow }
else { Write-Host "setup finished: this PC is ready -- play with the RaptorMod shortcut on the desktop (or $Root\Play RaptorMod.cmd)" -ForegroundColor Green }
