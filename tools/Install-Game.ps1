# Install-Game.ps1 -- RaptorMod's PLAYER-SIDE builder (RaptorMod 1.0, 2026-10-16). The setup wizard copies the mod into
# <root> and runs this; it is also safe to run again (a repair keeps the player's saves).
#
#   <root>\app\        this mod (tools\, art\, rooms\, runtime\, the manifest)          -- from the package
#   <root>\payload\    pre\ + post\: files laid over the game before / after the patcher -- from the package, removed after
#   <root>\textures\   hires\ (4K)                                                       -- from the package
#   <root>\game\       BUILT HERE from the player's own Steam copy: copied, the disc's files extracted, patched
#   <root>\cache\      install.log, the palette, the room cache, gpu-check.json
#
# NOTHING OF THE PUBLISHER'S IS IN THE PACKAGE: the game is copied from the player's Steam folder, R.EXE is patched from
# the manifest's byte edits, and GAME\AZTEX is extracted from their own AZT.BIN (app\runtime\disc-map.tsv says which
# disc file goes where -- written by tools\Build-Release.ps1 from a working install). Steam's folder is only READ.
#
#   powershell -ExecutionPolicy Bypass -File <root>\app\tools\Install-Game.ps1 [-SteamDir <folder>] [-Root <folder>]
param([string]$Root = '', [string]$SteamDir = '', [switch]$SkipRoomCache, [switch]$NoPause)
$ErrorActionPreference = 'Stop'
$App = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $Root) { $Root = Split-Path -Parent $App }
$Root = (Resolve-Path $Root).Path.TrimEnd('\')
$env:RAPTORMOD_ROOT = $Root                          # (every script below finds its folders from this)
$Game = Join-Path $Root 'game'; $Cache = Join-Path $Root 'cache'; $Payload = Join-Path $Root 'payload'
New-Item -ItemType Directory -Force -Path $Cache, $Game | Out-Null
$log = Join-Path $Cache 'install.log'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$problems = New-Object System.Collections.Generic.List[string]
$script:n = 0; $steps = 10
function Log([string]$m) { try { [IO.File]::AppendAllText($log, ("[{0:yyyy-MM-dd HH:mm:ss}] {1}`r`n" -f (Get-Date), $m)) } catch { } }
function Step([string]$m) { $script:n++; $l = "[$script:n/$steps] $m"; Write-Host ""; Write-Host $l -ForegroundColor Cyan; Log $l }
function Ok([string]$m)   { Write-Host "      $m" -ForegroundColor Green; Log "  ok: $m" }
function Warn([string]$m) { Write-Host "      $m" -ForegroundColor Yellow; Log "  WARN: $m" }
function Fail([string]$m) {
    Write-Host ""; Write-Host "RaptorMod could not be installed:" -ForegroundColor Red; Write-Host "  $m" -ForegroundColor Red
    Write-Host "  (details: $log)"; Log "FAILED: $m"
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
# a child PowerShell for each heavy step: several compile C# types of the same names, and one session cannot hold two
function Run-Child([string]$what, [string]$file, [string[]]$argList) {
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $file @argList 2>&1; $code = $LASTEXITCODE
    foreach ($o in @($out)) { Log "    $o" }
    if ($code -ne 0) { throw "$what failed (exit $code) -- see $log" }
    return @($out)
}
Log "==== RaptorMod install: root $Root, app $App"
$man = Get-Content (Join-Path $App 'AztMod.manifest.json') -Raw | ConvertFrom-Json
Write-Host ("RaptorMod {0} -- building the game in {1}" -f $man.modVersion, $Game) -ForegroundColor White

# ---- 1. the player's Steam copy ------------------------------------------------------------------------------------
Step "finding Azrael's Tear (Steam)"
function Test-SteamGame([string]$d) { $d -and (Test-Path (Join-Path $d 'GAME\AZRAEL\R.EXE')) -and (Test-Path (Join-Path $d 'AZT.BIN')) }
if (-not (Test-SteamGame $SteamDir)) {
    $SteamDir = ''
    $libs = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try { $p = Get-ItemProperty $k -ErrorAction Stop; foreach ($v in 'SteamPath', 'InstallPath') { if ($p.$v) { $libs.Add(($p.$v -replace '/', '\')) } } } catch { }
    }
    foreach ($l in @($libs)) {
        $vdf = Join-Path $l 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) { foreach ($mm in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) { $libs.Add(($mm.Groups[1].Value -replace '\\\\', '\')) } }
    }
    foreach ($l in ($libs | Select-Object -Unique)) { $c = Join-Path $l "steamapps\common\Azrael's Tear"; if (Test-SteamGame $c) { $SteamDir = $c; break } }
}
if (-not $SteamDir) { Fail "Azrael's Tear was not found in your Steam libraries. Install it with Steam first (or pass -SteamDir <its folder>)." }
$exe = Join-Path $SteamDir 'GAME\AZRAEL\R.EXE'
$sha = (Get-FileHash $exe -Algorithm SHA256).Hash
if ($sha -ne $man.targetSha256 -or (Get-Item $exe).Length -ne [long]$man.targetLength) {
    Fail ("$exe is not the Steam release this mod patches (SHA-256 $sha). In Steam: right-click Azrael's Tear > Properties > Installed Files > Verify integrity, then run setup again.")
}
Ok "$SteamDir (the Steam release: R.EXE checks out)"

# ---- 2. copy it (the Steam folder is only read) ---------------------------------------------------------------------
Step 'copying the game (about 530 MB; your Steam folder is not changed)'
if (Test-Path (Join-Path $Game 'GAME\AZRAEL\R.EXE')) { Ok 'already copied (a repair: your saves are kept)' }
else {
    & robocopy $SteamDir $Game /E /XD AztMod .claude /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "copying the game failed (robocopy exit $LASTEXITCODE)" }
    Ok 'copied'
}

# ---- 3. the disc's files: extracted from YOUR AZT.BIN ---------------------------------------------------------------
Step 'extracting the game''s textures, maps and books from your AZT.BIN'
$map = Join-Path $App 'runtime\disc-map.tsv'
if (-not (Test-Path $map)) { Fail "app\runtime\disc-map.tsv is missing -- the package is incomplete" }
$rows = @(Get-Content $map | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $f = $_ -split "`t"; [pscustomobject]@{ Disc = $f[0]; Rel = $f[1] } })
# ("-" = an EMPTY file the game has -- several in GAME\AZTEX -- made here, not read from the disc)
foreach ($r in @($rows | Where-Object { $_.Disc -eq '-' })) { $dst = Join-Path $Game $r.Rel; if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null; [IO.File]::WriteAllBytes($dst, [byte[]]@()) } }
$need = @($rows | Where-Object { $_.Disc -ne '-' -and -not (Test-Path (Join-Path $Game $_.Rel)) })
if (-not $need.Count) { Ok ("all {0} files in place" -f $rows.Count) }
else {
    $tmp = Join-Path $Cache 'disc-extract'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    try { Run-Child 'extracting AZT.BIN' (Join-Path $App 'tools\Read-CdImage.ps1') @('-Image', (Join-Path $Game 'AZT.BIN'), '-OutDir', $tmp) | Out-Null }
    catch { Fail $_.Exception.Message }
    $miss = 0
    foreach ($r in $need) {
        $src = Join-Path $tmp $r.Disc; $dst = Join-Path $Game $r.Rel
        if (-not (Test-Path $src)) { $miss++; Log "    not on the disc: $($r.Disc) -> $($r.Rel)"; continue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($miss) { Fail "$miss of the game's files were not found on your AZT.BIN (see $log)" }
    Ok ("{0} files placed" -f $need.Count)
}

# ---- 4. the mod's own files, before the patcher (DOSBox Staging, the soundfont, the soundtrack, the configs) ----------
Step 'adding DOSBox Staging, the soundtrack and the configs'
$pre = Join-Path $Payload 'pre'
if (Test-Path $pre) {
    & robocopy $pre $Game /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "placing the mod's files failed (robocopy exit $LASTEXITCODE)" }
    Ok 'placed'
} elseif (Test-Path (Join-Path $Game 'DOSBOX-STAGING\dosbox.exe')) { Ok 'already in place (a repair)' }
else { Fail "the package's payload\pre folder is missing and DOSBox Staging is not installed -- run setup again" }
$rt = Join-Path $App 'runtime'
foreach ($c in 'azrael-staging.conf', 'azrael-game.conf', 'azrael-graphics.conf') { Copy-Item (Join-Path $rt $c) (Join-Path $Game $c) -Force }
foreach ($c in 'MDI.INI', 'RESOURCE.CFG') { Copy-Item (Join-Path $rt $c) (Join-Path $Game "GAME\AZRAEL\$c") -Force }
# (DOSBox's screenshots / recordings: this install's own capture folder)
$conf = Join-Path $Game 'azrael-staging.conf'; $capDir = Join-Path $Game 'capture'
New-Item -ItemType Directory -Force -Path $capDir | Out-Null
[IO.File]::WriteAllText($conf, ([regex]::Replace([IO.File]::ReadAllText($conf), '(?m)^capture_dir\s*=.*$', "capture_dir = $capDir")))
Ok 'DOSBox configs and the music driver set'

# ---- 5. the patch ---------------------------------------------------------------------------------------------------
Step ("patching the game (RaptorMod {0}: {1} edits to R.EXE, the overlay, the HUD art)" -f $man.modVersion, @($man.patches).Count)
try { $out = Run-Child 'the patcher' (Join-Path $App 'Apply-AztMod.ps1') @('-Install', '-Dest', $Game, '-GameDir', $SteamDir, '-Manifest', (Join-Path $App 'AztMod.manifest.json'), '-SkipBooks'); Ok ('patched ({0})' -f ((@($out | Where-Object { "$_" -match 'patch sites verified' }) | Select-Object -Last 1) -replace '^\s*\[ok\]\s*', '')) }
catch { Fail $_.Exception.Message }

# ---- 6. the mod's own files, after the patcher (it rebuilds the book pages from the stock ones: ours go over them) ----
Step 'adding the remastered movies, book pages and title'
$post = Join-Path $Payload 'post'
if (Test-Path $post) {
    & robocopy $post $Game /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "placing the movies and books failed (robocopy exit $LASTEXITCODE)" }
    Ok 'placed'
} else { Warn 'the book pages and title were not found in payload\post -- run the setup again to restore them'; $problems.Add('book pages') }

# ---- 7. the title music -----------------------------------------------------------------------------------------------
Step 'title music'
$mp3 = Join-Path $App 'art\title\title-music.mp3'; $wav = Join-Path $App 'art\title\title-music.wav'
if (Test-Path $wav) { Ok 'in place' }
elseif (-not (Test-Path $mp3)) { Warn 'art\title\title-music.mp3 missing'; $problems.Add('title music') }
else {
    # (Media Foundation decodes it: missing on Windows "N" editions without the Media Feature Pack -- the title is then silent)
    $dec = @"
`$ErrorActionPreference = 'Stop'; Add-Type -Path '$((Join-Path $App 'tools\AudioFx.cs').Replace("'", "''"))'
`$ch = 0; `$pcm = [AztTool.AudioFx]::DecodePcm('$($mp3.Replace("'", "''"))', 44100, 2, [ref]`$ch); [AztTool.AudioFx]::WriteWav('$($wav.Replace("'", "''"))', `$pcm, 44100, `$ch)
"@
    $o = & $ps -NoProfile -ExecutionPolicy Bypass -Command $dec 2>&1
    if ($LASTEXITCODE -eq 0 -and (Test-Path $wav)) { Ok 'decoded' } else { Log "    $(@($o) -join ' ')"; Warn 'could not decode the title music (Windows N? install the Media Feature Pack and run setup again) -- the title will be silent'; $problems.Add('title music') }
}

# ---- 8. the renderer's cache ------------------------------------------------------------------------------------------
Step 'preparing the renderer (palette, rooms, room cache -- a few minutes)'
Copy-Item (Join-Path $rt 'azrael-palette.pal') (Join-Path $Cache 'azrael-palette.pal') -Force
$rooms = Join-Path $Cache 'rooms'
if (-not (Test-Path $rooms)) { New-Item -ItemType Junction -Path $rooms -Target (Join-Path $App 'rooms') | Out-Null }
Ok 'palette and rooms in place'
if ($SkipRoomCache) { Warn 'room cache skipped (-SkipRoomCache): each room is prepared the first time you enter it' }
else {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { Run-Child 'the room cache' (Join-Path $App 'tools\Build-RoomCache.ps1') @() | Out-Null; Ok ("room cache built ({0:N0} s)" -f $sw.Elapsed.TotalSeconds) }
    catch { Warn "$($_.Exception.Message) -- rooms are then prepared the first time you enter them"; $problems.Add('room cache') }
}
# THE CHARACTER INDEX (which .XAF holds which object: without it every character is invisible -- RaptorMod 1.0's first test)
# and THE DOORWAY MAP (the 3D map's and the echo scan's doors). On a dev PC both were made long ago by Find-LiveRoom (only
# with a game running) and Build-PortalMap; here they are built from the files just placed. Both checked identical to the dev
# PC's (2026-10-16).
try {
    $idx = @{}
    foreach ($f in (Get-ChildItem (Join-Path $Game 'GAME\AZTEX') -Filter '*.XAF')) {
        $objs = @(); foreach ($l in [IO.File]::ReadAllLines($f.FullName)) { if ($l -match '^\s*object\s+"([^"]+)"') { $objs += $Matches[1] } }
        $idx[$f.BaseName] = @($objs | Sort-Object -Unique)
    }
    [IO.File]::WriteAllText((Join-Path $Cache 'xaf-objects.json'), ($idx | ConvertTo-Json -Depth 3 -Compress), (New-Object Text.UTF8Encoding($false)))
    Ok ("character index: {0} model files" -f $idx.Count)
} catch { Warn "the character index failed ($($_.Exception.Message)) -- characters would not be drawn"; $problems.Add('character index') }
if ($SkipRoomCache) { Warn 'doorway map skipped with the room cache' }
else {
    try { Run-Child 'the doorway map' (Join-Path $App 'tools\Build-PortalMap.ps1') @('-CacheDir', $Cache, '-GameDir', (Join-Path $Game 'GAME\AZRAEL')) | Out-Null; Ok 'doorway map built' }
    catch { Warn "$($_.Exception.Message) -- the map and the echo scan show no doorways"; $problems.Add('doorway map') }
}
$hires = Join-Path $Root 'textures\hires'
if (Test-Path $hires) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $prep = @"
`$ErrorActionPreference = 'Stop'; . '$((Join-Path $App 'tools\LoadRoom.ps1').Replace("'", "''"))'
`$m = Get-AztTwinArt '$($Cache.Replace("'", "''"))' '$($hires.Replace("'", "''"))'; `$script:AztTwin.Note
"@
    $o = & $ps -NoProfile -ExecutionPolicy Bypass -Command $prep 2>&1
    if ($LASTEXITCODE -eq 0) { Ok ("hi-res textures indexed ({0:N0} s)" -f $sw.Elapsed.TotalSeconds) } else { Log "    $(@($o) -join ' ')"; Warn 'the hi-res texture index failed -- it is rebuilt on first play'; $problems.Add('texture index') }
} else { Warn "no textures\hires -- the game runs with its own textures"; $problems.Add('hi-res textures') }

# ---- 9. the graphics card ----------------------------------------------------------------------------------------------
Step 'checking the graphics card (OpenGL 4.5 for the true-colour picture)'
$gpuOk = $true
try { $o = Run-Child 'the graphics check' (Join-Path $App 'tools\Test-GpuCaps.ps1') @('-CacheDir', $Cache); Ok (@($o) | Select-Object -Last 1) }
catch { $gpuOk = $false; Warn "this PC's graphics card cannot draw RaptorMod's true-colour picture. Use the 'Play RaptorMod (Classic 8-bit)' shortcut."; $problems.Add('graphics card') }

# ---- 10. done ----------------------------------------------------------------------------------------------------------
Step 'finishing'
[IO.File]::WriteAllText((Join-Path $Root 'raptormod-root.txt'), ("RaptorMod {0}`r`nThis folder is a RaptorMod install. The launchers find it from this file.`r`nSteam game: {1}`r`nInstalled: {2:yyyy-MM-dd HH:mm}`r`n" -f $man.modVersion, $SteamDir, (Get-Date)))
# the payload has been laid in: drop the big parts. KEPT: post\'s book pages and title (~90 MB) -- the patcher rebuilds the
# book pages from the stock ones on every run, so a REPAIR lays these back over them (else a repair would blur the books)
if (Test-Path $Payload) {
    Remove-Item (Join-Path $Payload 'pre') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Payload 'post\GAME\MOV') -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem (Join-Path $Payload 'post\GAME\AZRAEL') -Filter '*.MOV' -File -ErrorAction SilentlyContinue | Remove-Item -Force
}
$env:AZT_DRYRUN = '1'; $d = & cmd /c "`"$(Join-Path $App 'Play-HostRender.cmd')`"" 2>&1; Remove-Item Env:AZT_DRYRUN
foreach ($o in @($d)) { Log "    $o" }
if (@($d) -match 'renderer script found') { Ok 'launcher checked' } else { Warn 'the launcher check did not pass (see install.log)'; $problems.Add('launcher') }
Write-Host ""
if ($problems.Count) { Write-Host ("RaptorMod is installed, with notes: {0}. Details: {1}" -f ($problems -join ', '), $log) -ForegroundColor Yellow }
else { Write-Host "RaptorMod is installed. Start it from the 'Play RaptorMod' shortcut." -ForegroundColor Green }
Log ("==== done; notes: {0}" -f ($problems -join ', '))
exit 0
