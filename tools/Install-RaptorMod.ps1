# Install-RaptorMod.ps1 -- set up RaptorMod on a PC that has the Steam game and nothing else (Josh, 2026-10-14: "plan
# what's needed so I can easily patch the steam version of the game on another machine with this entire mod").
#
# Lives next to the asset pack (a copy on the NAS: \\DXP2800GT-7649\personal_folder\Projects\AzraelsTear\assets) and is
# started by Install-RaptorMod.cmd beside it. In order:
#   1. finds the Steam copy of Azrael's Tear (the registry and libraryfolders.vdf, as Apply-AztMod does)
#   2. finds Git, or installs it with winget (you answer winget's own prompts)
#   3. clones the repo (-Branch, default dev-next) into <game>\AztMod -- or, if it is already there, fetches and fast-forwards
#      (GitHub asks you to sign in the first time: the repo is private)
#   4. runs AztMod\tools\Setup-Machine.ps1 -AssetPack <the pack folder>: everything goes into ONE folder, C:\Games\RaptorMod (an
#      older install's folders are moved in); it restores the pack, links, installs the patches,
#      builds the room cache, prepares the textures, checks the graphics card, makes ONE desktop shortcut (RaptorMod) --
# -DryRun prints what it would do and changes nothing. The game is never launched.

[CmdletBinding()]
param(
    [string]$AssetPack = '',
    [string]$GameDir = '',
    [string]$Branch = 'dev-next',
    [string]$RepoUrl = 'https://github.com/papertelevision/raptormod.git',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
function Step($s) { Write-Host ""; Write-Host "== $s" -ForegroundColor Cyan }
function Ok($s) { Write-Host "   $s" -ForegroundColor Green }
function Warn($s) { Write-Host "   $s" -ForegroundColor Yellow }
function Plan($s) { Write-Host "   DRY RUN: would $s" -ForegroundColor DarkCyan }
# the pack: the folder this script sits in, unless given ($PSScriptRoot is empty in a param default under -File)
if (-not $AssetPack) { $AssetPack = Split-Path -Parent $PSCommandPath }
$AssetPack = $AssetPack.TrimEnd('\', '.')

# ---- 1. the Steam game ---------------------------------------------------------------------------------------------
Step "the Steam copy of Azrael's Tear"
$relExe = 'GAME\AZRAEL\R.EXE'
function Find-SteamGame {
    $roots = @()
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try { $p = (Get-ItemProperty -Path $k -ErrorAction Stop).InstallPath; if ($p) { $roots += $p } } catch { }
        try { $p = (Get-ItemProperty -Path $k -ErrorAction Stop).SteamPath; if ($p) { $roots += ($p -replace '/', '\') } } catch { }
    }
    foreach ($r in @($roots)) {
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) { foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) { $roots += $m.Groups[1].Value -replace '\\\\', '\' } }
    }
    foreach ($r in ($roots | Select-Object -Unique)) {
        $c = Join-Path $r "steamapps\common\Azrael's Tear"
        if (Test-Path (Join-Path $c $relExe)) { return $c }
    }
    return $null
}
if (-not $GameDir) { $GameDir = Find-SteamGame }
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir $relExe))) {
    throw "Azrael's Tear was not found in any Steam library. Install it with Steam first (or pass -GameDir <its folder>)."
}
Ok $GameDir
$target = Join-Path $GameDir 'AztMod'

# ---- 2. Git --------------------------------------------------------------------------------------------------------
Step 'Git'
function Find-Git {
    $g = Get-Command git -ErrorAction SilentlyContinue; if ($g) { return $g.Source }
    foreach ($c in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}
$git = Find-Git
if ($git) { Ok $git }
elseif ($DryRun) { Plan 'install Git: winget install --id Git.Git -e' }
else {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Git is not installed and winget is not available. Install Git for Windows (https://git-scm.com), then run this again.' }
    Warn 'Git is not installed: installing it with winget (answer its prompts)...'
    & winget install --id Git.Git -e
    $git = Find-Git
    if (-not $git) { throw 'Git still not found after winget. Install Git for Windows, then run this again.' }
    Ok $git
}

# ---- 3. the repo ---------------------------------------------------------------------------------------------------
Step "the repo ($Branch) at $target"
if (Test-Path (Join-Path $target '.git')) {
    if ($DryRun) { Plan "fetch and fast-forward $target to origin/$Branch" }
    else {
        & $git -C $target fetch origin
        & $git -C $target checkout $Branch
        & $git -C $target pull --ff-only origin $Branch
        if ($LASTEXITCODE -ne 0) { Warn "could not fast-forward (local changes?) -- left as it is" } else { Ok 'up to date' }
    }
} elseif ((Test-Path $target) -and @(Get-ChildItem -LiteralPath $target -Force).Count) {
    throw "$target exists but is not a clone. Move it aside, then run this again."
} else {
    if ($DryRun) { Plan "git clone -b $Branch $RepoUrl `"$target`"" }
    else {
        Warn 'cloning (GitHub asks you to sign in the first time: the repo is private)...'
        & $git -c core.longpaths=true -c core.autocrlf=false clone -b $Branch $RepoUrl $target
        if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)" }
        Ok 'cloned'
    }
}

# ---- 4. the pack and the setup ----------------------------------------------------------------------------------------
Step "asset pack: $AssetPack"
$pj = Join-Path $AssetPack 'pack.json'
if (-not (Test-Path $pj)) { throw "no pack.json in $AssetPack -- run this from the asset pack folder (or pass -AssetPack)." }
$pack = [IO.File]::ReadAllText($pj) | ConvertFrom-Json; $tot = 0L; foreach ($c in @($pack.components)) { $tot += [long]$c.bytes }
Ok ("{0} component(s), {1:N1} GB, made {2} on {3} (repo {4})" -f @($pack.components).Count, ($tot / 1GB), $pack.created, $pack.fromComputer, $pack.repoCommit)
$setup = Join-Path $target 'tools\Setup-Machine.ps1'
if ($DryRun) { Plan "run powershell -File `"$setup`" -AssetPack `"$AssetPack`" (restore ~$([int]($tot / 1GB)) GB, install the patches into C:\Games\RaptorMod, room cache, textures, GPU check, the RaptorMod shortcut)"; return }
if (Get-Process dosbox* -ErrorAction SilentlyContinue) { throw 'DOSBox is running -- close the game, then run this again.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -AssetPack $AssetPack
if ($LASTEXITCODE -ne 0) { throw "Setup-Machine stopped with an error (exit $LASTEXITCODE) -- see above" }
Write-Host ""
Write-Host 'RaptorMod is installed in C:\Games\RaptorMod: play with the RaptorMod shortcut on the desktop.' -ForegroundColor Green
