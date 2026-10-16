# Build-Release.ps1 -- builds RaptorMod's PUBLIC package: a setup wizard (Inno Setup) that any player with the Steam game
# runs (RaptorMod 1.0, 2026-10-16; Josh: "a distributable file for this patch to be played by any player ... steam-friendly
# and compliant"; everything in one download; prepared for ModDB).
#
#   powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1                 # stage + guard + compile + zip
#   powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1 -NoCompile      # stage + guard only (fast check)
#
# WHAT GOES IN, decided from a WORKING install (-Ref, Josh's C:\Games\RaptorMod\game) rather than from a hand list: every
# file there is hashed against the player's Steam folder and against the files on AZT.BIN.
#   * identical to a Steam file          -> NOT shipped: Install-Game copies the player's own
#   * identical to a file on AZT.BIN     -> NOT shipped: extracted from the player's own disc image (runtime\disc-map.tsv)
#   * a backup (.aztbak .orig .src ...)  -> NOT shipped
#   * the mod's own                      -> shipped if a rule below names it (payload\pre, payload\post), else listed in
#                                           not-shipped.txt for a look (saves, logs, old exports)
# plus app\ (the repo's tracked files minus the developer-only ones), textures\hires (the 4K set) and the root launchers.
# THE GUARD: no staged or shipped file may match a Steam or disc file by hash, or be named R.EXE / AZT.BIN / *.aztbak.
param(
    [string]$Ref = 'C:\Games\RaptorMod\game',
    [string]$Textures = 'C:\Games\RaptorMod\textures\hires',
    [string]$OutDir = 'C:\Games\RaptorMod-Release',
    [string]$Iscc = '',
    [switch]$NoCompile,
    [switch]$NoZip
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$steam = Split-Path -Parent $repo
$man = Get-Content (Join-Path $repo 'AztMod.manifest.json') -Raw | ConvertFrom-Json
$ver = [string]$man.modVersion
$work = Join-Path $OutDir 'work'; $stage = Join-Path $OutDir "stage-$ver"; $out = Join-Path $OutDir "RaptorMod-$ver"
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
$md5 = [Security.Cryptography.MD5]::Create()
function Get-Md5([string]$p) { $f = [IO.File]::OpenRead($p); try { [BitConverter]::ToString($md5.ComputeHash($f)) } finally { $f.Close() } }
Say "RaptorMod $ver release -- ref $Ref, out $OutDir" Cyan
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# ---- 1. what the player already has: the Steam files and the disc's ---------------------------------------------------
Say '1. hashing the Steam game and its disc image'
$known = @{}
foreach ($f in Get-ChildItem -LiteralPath $steam -Recurse -File | Where-Object { $_.FullName -notmatch '\\(AztMod|\.claude)(\\|$)' }) { $known[(Get-Md5 $f.FullName)] = 'steam' }
$disc = Join-Path $work 'disc'
if (-not (Test-Path $disc) -or @(Get-ChildItem $disc -File).Count -lt 2000) {
    if (Test-Path $disc) { Remove-Item $disc -Recurse -Force }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\Read-CdImage.ps1') -Image (Join-Path $steam 'AZT.BIN') -OutDir $disc | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'extracting AZT.BIN failed' }
}
$discByHash = @{}
foreach ($f in Get-ChildItem $disc -File) { $h = Get-Md5 $f.FullName; if (-not $discByHash[$h]) { $discByHash[$h] = $f.Name }; if (-not $known[$h]) { $known[$h] = 'disc' } }
Say ("   {0} Steam + disc files known" -f $known.Count) DarkGray

# ---- 2. the working install, classified --------------------------------------------------------------------------------
Say '2. classifying the working install'
$isBackup = '\.(aztbak|orig|aztoff|aztnew|aztdiag|roombak|requant|local|bak)$|\.bak-|\\orig\\|\\_new\\|\.src$'
# THE PAYLOAD RULES (relative to the game folder). pre: before the patcher; post: after it (it rebuilds the book pages)
$preRx  = '^(DOSBOX-STAGING\\|soundfonts\\|AZT\.CUE$|AZTRACK\d+\.(mp3|wav)$|raptordocs\\)'
$postRx = '^(GAME\\MOV\\[^\\]+\.MOV$|GAME\\AZRAEL\\(INTRO|MINDLOGO|OPENING)\.MOV$|GAME\\AZRAEL\\TITLE\.PCX$|GAME\\AZTEX\\BOOKS\\[^\\]+\.PCX$)'
$stockMapped = @{}; $mapRows = New-Object System.Collections.Generic.List[string]; $pre = 0; $post = 0; $skipped = New-Object System.Collections.Generic.List[string]
foreach ($f in Get-ChildItem -LiteralPath $Ref -Recurse -File) {
    $rel = $f.FullName.Substring($Ref.Length + 1)
    if ($rel -match $isBackup) {
        # a STOCK original the patcher (or the book step) replaces: when it is on the disc, it is placed there at install so
        # the patcher sees what it saw here (it backs it up, then replaces it -- e.g. MAPS\HELP.PCX; the books' stock .src are NOT placed: the installer skips the rescale, the finished pages ship)
        if ($rel -match '^(.+)\.aztbak$') { $sr = $matches[1]; $hb = Get-Md5 $f.FullName
            if ($known[$hb] -eq 'disc' -and -not $stockMapped[$sr]) { $stockMapped[$sr] = 1; $mapRows.Add("$($discByHash[$hb])`t$sr") } }
        continue
    }
    # an EMPTY file (several in GAME\AZTEX): created at install -- its hash matches any empty file, so it cannot be mapped
    if ($f.Length -eq 0) { $mapRows.Add("-`t$rel"); continue }
    $h = Get-Md5 $f.FullName
    if ($known[$h] -eq 'steam') { continue }
    if ($known[$h] -eq 'disc') { $mapRows.Add("$($discByHash[$h])`t$rel"); continue }
    $dest = $(if ($rel -match $preRx) { 'pre' } elseif ($rel -match $postRx) { 'post' } else { '' })
    if (-not $dest) { $skipped.Add(("{0}  ({1:N0} KB)" -f $rel, ($f.Length / 1KB))); continue }
    $to = Join-Path $stage "payload\$dest\$rel"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $to
    if ($dest -eq 'pre') { $pre++ } else { $post++ }
}
Say ("   payload: {0} files before the patcher, {1} after; {2} disc files mapped; {3} of the install's own files not shipped (not-shipped.txt)" -f $pre, $post, $mapRows.Count, $skipped.Count) DarkGray
[IO.File]::WriteAllLines((Join-Path $OutDir 'not-shipped.txt'), $skipped)

# ---- 3. app\: the repo's tracked files, minus the developer-only ones --------------------------------------------------
Say '3. the mod itself (app\)'
$devOnly = '^(design|docs|room-notes|art-backup-preskin|\.claude|\.github|installer|tools/room-review|tools/retired)/|^(CLAUDE\.md|SETUP\.md|README\.md|\.gitignore|\.gitattributes|Review-Rooms\.cmd|Install-Update\.cmd|Play-HostRender-(Audit|Capture)\.cmd|AztTester\.ps1|Set-[A-Za-z]+\.ps1|AztMod\.manifest\.installed\.json|runtime/MDI\.INI\.stock-fm)$|^tools/(Install-RaptorMod\.(ps1|cmd)|Setup-Machine\.ps1|Export-AssetPack\.ps1|Build-Release\.ps1|Start-RoomRound\.ps1|Reply-RoomNote\.ps1|Restore-RoomRound\.ps1|Wait-RoomSubmit\.ps1|RoomNotes\.ps1|RoomLookWorker\.ps1)$'
# (tracked AND new-but-not-ignored files: a release built before its new scripts are committed must still carry them)
$files = @(& git -C $repo ls-files --cached --others --exclude-standard) | Select-Object -Unique | Where-Object { $_ -notmatch $devOnly }
foreach ($r in $files) {
    $src = Join-Path $repo ($r -replace '/', '\'); $to = Join-Path $stage ("app\" + ($r -replace '/', '\'))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath $src -Destination $to
}
$seen = @{}; $mapRows = @($mapRows | Where-Object { $d = ($_ -split "`t")[1]; if ($seen[$d]) { $false } else { $seen[$d] = 1; $true } })
[IO.File]::WriteAllLines((Join-Path $stage 'app\runtime\disc-map.tsv'), (@("# disc file (as tools\Read-CdImage.ps1 names it)`tits place in the game folder -- RaptorMod $ver") + $mapRows))
Say ("   {0} files" -f $files.Count) DarkGray

# ---- 4. the root: launchers and the player's documents -----------------------------------------------------------------
Say '4. launchers and documents'
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'root') | Out-Null
foreach ($f in Get-ChildItem (Join-Path $repo 'installer\root') -File) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stage "root\$($f.Name)") }
foreach ($d in Get-ChildItem (Join-Path $repo 'installer\docs') -File) {
    $t = [IO.File]::ReadAllText($d.FullName).Replace('{VERSION}', $ver)
    [IO.File]::WriteAllText((Join-Path $stage "root\$($d.Name)"), $t.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
}

# ---- 5. THE GUARD ---------------------------------------------------------------------------------------------------------
Say '5. guard: nothing of the publisher''s in the package'
$bad = New-Object System.Collections.Generic.List[string]; $n = 0; $bytes = 0L
foreach ($set in @(@($stage, 'stage'), @($Textures, 'textures'))) {
    foreach ($f in Get-ChildItem -LiteralPath $set[0] -Recurse -File) {
        $n++; $bytes += $f.Length
        if ($f.Name -match '^(R\.EXE|AZT\.BIN)$|\.aztbak$') { $bad.Add("$($set[1]): $($f.FullName) (name)"); continue }
        if ($f.Length -eq 0) { continue }
        $k = $known[(Get-Md5 $f.FullName)]
        if ($k) { $bad.Add("$($set[1]): $($f.FullName) (identical to a $k file)") }
    }
}
if ($bad.Count) { $bad | Select-Object -First 20 | ForEach-Object { Say "   $_" Red }; throw "GUARD: $($bad.Count) file(s) would ship the publisher's own content -- fix the rules" }
Say ("   passed: {0:N0} files, {1:N1} GB checked" -f $n, ($bytes / 1GB)) Green

# ---- 6. the setup wizard --------------------------------------------------------------------------------------------------
if ($NoCompile) { Say "staged in $stage (-NoCompile: no setup built)" Yellow; return }
if (-not $Iscc) { $Iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
if (-not $Iscc) { throw 'Inno Setup 6 (ISCC.exe) not found: winget install JRSoftware.InnoSetup' }
Say '6. compiling the setup (Inno Setup; the textures make this take a while)'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
$sw = [Diagnostics.Stopwatch]::StartNew()
& $Iscc /Q "/DAppVer=$ver" "/DStage=$stage" "/DTextures=$Textures" "/DOutDir=$out" (Join-Path $repo 'installer\RaptorMod.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit $LASTEXITCODE)" }
$parts = @(Get-ChildItem $out -File)
Say ("   {0} file(s), {1:N2} GB in {2:N0} min: {3}" -f $parts.Count, (($parts | Measure-Object Length -Sum).Sum / 1GB), $sw.Elapsed.TotalMinutes, (($parts | ForEach-Object Name) -join ', ')) Green
# the checksums, and ONE archive for an upload (stored: the setup is compressed already)
$sums = foreach ($p in $parts) { "{0}  {1}" -f (Get-FileHash $p.FullName -Algorithm SHA256).Hash.ToLower(), $p.Name }
[IO.File]::WriteAllLines((Join-Path $out 'SHA256SUMS.txt'), $sums)
Copy-Item (Join-Path $stage 'root\README.txt') (Join-Path $out 'README.txt') -Force
if (-not $NoZip) {
    $zip = Join-Path $OutDir "RaptorMod-$ver.zip"; if (Test-Path $zip) { Remove-Item $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($out, $zip, [IO.Compression.CompressionLevel]::NoCompression, $true)
    Say ("   upload: {0} ({1:N2} GB)" -f $zip, ((Get-Item $zip).Length / 1GB)) Green
}
Say "done: $out" Cyan
