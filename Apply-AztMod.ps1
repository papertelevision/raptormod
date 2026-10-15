<#
.SYNOPSIS
    AztMod -- quality-of-life patches for Azrael's Tear (1996, Mindscape).

.DESCRIPTION
    Patches the game's R.EXE. By default it does NOT touch your Steam install:
    it copies the whole game to a separate folder and patches the copy, so Steam
    can never overwrite it and "Verify integrity of game files" is harmless.

.EXAMPLE
    # Recommended: install a patched copy next to your Steam library
    .\Apply-AztMod.ps1 -Install -Dest "D:\Games\AzraelsTear-Modded"

.EXAMPLE
    .\Apply-AztMod.ps1 -Status -Dest "D:\Games\AzraelsTear-Modded"
    .\Apply-AztMod.ps1 -Revert -Dest "D:\Games\AzraelsTear-Modded"

.EXAMPLE
    # Patch the Steam install directly (not recommended -- see README)
    .\Apply-AztMod.ps1 -InPlace
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName='Install')][switch]$Install,
    [Parameter(ParameterSetName='Revert')] [switch]$Revert,
    [Parameter(ParameterSetName='Status')] [switch]$Status,

    # Source game folder (the one containing GAME\, DOSBOX\, AZT.BIN).
    [string]$GameDir = (Split-Path -Parent $PSScriptRoot),

    # Where the patched copy lives. Ignored with -InPlace.
    [string]$Dest,

    # Patch $GameDir directly instead of making a copy.
    [switch]$InPlace,

    # Skip the intro movie (AZRAEL.BAT runs TM before R). Testing convenience.
    [Parameter(ParameterSetName='Install')][switch]$SkipIntro,

    [string]$Manifest = "$PSScriptRoot\AztMod.manifest.json"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Say  { param($m) Write-Host $m }
function Ok   { param($m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "  [fail] $m" -ForegroundColor Red; exit 1 }

function FromHex([string]$h) {
    $n = $h.Length / 2
    $b = New-Object byte[] $n
    for ($i = 0; $i -lt $n; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i*2,2), 16) }
    return ,$b
}

# ---------------------------------------------------------------------------
if (-not (Test-Path $Manifest)) { Die "manifest not found: $Manifest" }
$man = Get-Content $Manifest -Raw | ConvertFrom-Json

function Show-Keys {
    if (-not ($man.PSObject.Properties.Name -contains 'keys')) { return }
    Say ""
    Say "  in-game keys:"
    foreach ($k in $man.keys) { Say "    $k" }
}

$target = if ($InPlace) { $GameDir } else { $Dest }
if (-not $target) {
    Die "specify -Dest <folder> for the patched copy, or -InPlace to patch the Steam install directly"
}

$relExe  = $man.targetFile -replace '/', '\'
$exePath = Join-Path $target $relExe
$bakPath = "$exePath.aztbak"

Say ""
Say "AztMod $($man.modVersion)  --  feature: $($man.feature)"
Say "target: $exePath"
Say ""

# ---------------------------------------------------------------------------
# STATUS
# ---------------------------------------------------------------------------
if ($Status) {
    if (-not (Test-Path $exePath)) { Die "no game executable at that path" }
    $sha = (Get-FileHash $exePath -Algorithm SHA256).Hash
    if ($sha -eq $man.targetSha256) { Ok "R.EXE is UNPATCHED (stock)"; exit 0 }

    $b = [System.IO.File]::ReadAllBytes($exePath)
    $applied = 0; $missing = @()
    foreach ($p in $man.patches) {
        $rep = FromHex $p.replace
        $match = $true
        for ($i = 0; $i -lt $rep.Length; $i++) {
            if ($b[[int]$p.offset + $i] -ne $rep[$i]) { $match = $false; break }
        }
        if ($match) { $applied++ } else { $missing += $p.name }
    }
    if ($applied -eq $man.patches.Count) {
        Ok "AztMod is fully applied ($applied/$($man.patches.Count) patches)"
        Show-Keys
    } else {
        Warn "partially patched: $applied/$($man.patches.Count). Missing: $($missing -join ', ')"
    }
    if (Test-Path $bakPath) { Ok "backup present: $bakPath" } else { Warn "no backup found" }
    exit 0
}

# ---------------------------------------------------------------------------
# REVERT
# ---------------------------------------------------------------------------
if ($Revert) {
    if (-not (Test-Path $bakPath)) { Die "no backup at $bakPath -- nothing to revert to" }
    $sha = (Get-FileHash $bakPath -Algorithm SHA256).Hash
    if ($sha -ne $man.targetSha256) { Die "backup does not match the expected stock R.EXE" }
    Copy-Item $bakPath $exePath -Force
    Ok "restored stock R.EXE from backup"
    # every backed-up asset, not just PCX -- the HUD overlays are .RES. R.EXE is
    # restored above, so it is excluded here.
    $artBaks = Get-ChildItem (Join-Path $target 'GAME\AZRAEL') -Filter '*.aztbak' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notlike 'R.EXE*' }
    foreach ($b in $artBaks) {
        Copy-Item $b.FullName ($b.FullName -replace '\.aztbak$','') -Force
        Ok ("restored " + ($b.Name -replace '\.aztbak$',''))
    }
    # Assets the mod ADDED have no stock version to restore, so they go instead.
    foreach ($m in (Get-ChildItem (Join-Path $target 'GAME\AZRAEL') -Filter '*.aztnew' -ErrorAction SilentlyContinue)) {
        $added = $m.FullName -replace '\.aztnew$',''
        if (Test-Path $added) { Remove-Item $added -Force }
        Remove-Item $m.FullName -Force
        Ok ("removed " + (Split-Path $added -Leaf) + " (added by the mod)")
    }
    foreach ($rel in @('GAME\AZRAEL\AZRAEL.BAT', 'azrael-base.conf')) {
        $p = Join-Path $target $rel
        if (Test-Path "$p.aztbak") { Copy-Item "$p.aztbak" $p -Force; Ok "restored $rel" }
    }
    foreach ($mov in @('INTRO.MOV', 'MINDLOGO.MOV', 'UVCONFIG.DAT')) {
        $p = Join-Path $target "GAME\AZRAEL\$mov"
        if (Test-Path "$p.aztoff") { Move-Item "$p.aztoff" $p -Force; Ok "restored $mov" }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# INSTALL
# ---------------------------------------------------------------------------
# Find the source game. The -GameDir default (the folder above this script) only
# holds for a dev checkout living inside the game folder; a downloaded release
# sits anywhere, so fall back to locating the Steam library.
function Find-SteamGame {
    $roots = @()
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = (Get-ItemProperty -Path $k -ErrorAction Stop).InstallPath
            if ($p) { $roots += $p }
        } catch { }
    }
    # Steam can spread games over several libraries; libraryfolders.vdf lists them.
    foreach ($r in @($roots)) {
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $roots += $m.Groups[1].Value -replace '\\\\', '\'
            }
        }
    }
    foreach ($r in ($roots | Select-Object -Unique)) {
        $c = Join-Path $r "steamapps\common\Azrael's Tear"
        if (Test-Path (Join-Path $c $relExe)) { return $c }
    }
    return $null
}

# Reinstalling over an existing patched copy does not need the source at all --
# the copy is already there and its own .aztbak is the restore point.
$needSource = $InPlace -or -not (Test-Path $exePath)
if ($needSource -and -not (Test-Path (Join-Path $GameDir $relExe))) {
    $found = Find-SteamGame
    if ($found) {
        Say "found your Steam copy: $found"
        $GameDir = $found
    } else {
        Die "could not find $relExe under $GameDir, and no Steam copy was found -- pass -GameDir <your Azrael's Tear folder>"
    }
}

if (-not $InPlace) {
    if (Test-Path $exePath) {
        Say "existing copy found at $target -- reusing it"
    } else {
        Say "copying game to $target (this takes a minute; ~530 MB)..."
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        # (not AztMod itself -- this repo and its .git -- nor the Steam folder's .claude: the game is all the copy needs)
        Get-ChildItem -LiteralPath $GameDir -Force | Where-Object { $_.Name -notin @('AztMod', '.claude') } | Copy-Item -Destination $target -Recurse -Force
        Ok "copied"
    }
} else {
    Warn "patching the Steam install directly."
    Warn "Steam's 'Verify integrity of game files' will undo this. Keep the backup."
}

# back up before touching anything
if (-not (Test-Path $bakPath)) {
    Copy-Item $exePath $bakPath -Force
    Ok "backup written: $(Split-Path -Leaf $bakPath)"
}

$sha = (Get-FileHash $exePath -Algorithm SHA256).Hash
if ($sha -ne $man.targetSha256) {
    if ((Get-FileHash $bakPath -Algorithm SHA256).Hash -eq $man.targetSha256) {
        Say "R.EXE is already modified; restoring from backup first"
        Copy-Item $bakPath $exePath -Force
    } else {
        Die @"
R.EXE does not match the version this patch was built for.
  expected SHA256 $($man.targetSha256)
  found           $sha
This build of AztMod targets the Steam release of Azrael's Tear.
"@
    }
}

$b = [System.IO.File]::ReadAllBytes($exePath)
if ($b.Length -ne $man.targetLength) { Die "unexpected file length" }

# verify every patch before writing any of them
foreach ($p in $man.patches) {
    $exp = FromHex $p.expect
    for ($i = 0; $i -lt $exp.Length; $i++) {
        if ($b[[int]$p.offset + $i] -ne $exp[$i]) {
            Die ("patch '{0}': unexpected bytes at file offset 0x{1:X}" -f $p.name, ([int]$p.offset + $i))
        }
    }
}
Ok "all $($man.patches.Count) patch sites verified"

foreach ($p in $man.patches) {
    $rep = FromHex $p.replace
    for ($i = 0; $i -lt $rep.Length; $i++) { $b[[int]$p.offset + $i] = $rep[$i] }
    Say ("         {0,-15} {1}" -f $p.name, $p.note)
}
[System.IO.File]::WriteAllBytes($exePath, $b)
Ok "patched R.EXE"

# The extra intro movie is NOT a manifest payload -- it is 41 MB, and like the re-encoded
# GAME\MOV set it is produced by tools\Convert-ToAnim.ps1 straight into the destination.
# But the PATCH that calls it ships in the manifest, so the two can come apart: install to
# a fresh destination (or delete the copy so the Steam files are copied again) and R.EXE
# calls the player for a file that is not there. Checked here rather than left to chance,
# with the encoder's own output folder as a fallback source.
if ($man.patches | Where-Object name -eq 'opening-movie') {
    $omDst = Join-Path $target 'GAME\AZRAEL\OPENING.MOV'
    if (-not (Test-Path $omDst)) {
        $omSrc = Join-Path $target 'GAME\MOV\_new\OPENING.MOV'
        if (Test-Path $omSrc) {
            Copy-Item $omSrc $omDst
            Ok ("copied OPENING.MOV from GAME\MOV\_new ({0:N0} MB)" -f ((Get-Item $omDst).Length / 1MB))
        } else {
            Warn "this build patches in an extra intro movie but GAME\AZRAEL\OPENING.MOV is missing --"
            Warn "  the intro will fail at that call. Re-encode it with:"
            Warn "  .\tools\Convert-ToAnim.ps1 -Mp4 C:\Games\RaptorMod\sources\video\update\opening.mp4 -Out '$omDst'"
        }
    } else {
        Ok ("OPENING.MOV present ({0:N0} MB) -- the extra intro movie will play" -f ((Get-Item $omDst).Length / 1MB))
    }
}

# Replacement HUD art, if this build ships any. Each original is backed up
# alongside itself the first time, so -Revert can put them all back.
$artDir = Join-Path $PSScriptRoot 'art'

# A redistributable build does NOT ship art/. HUD3, HUDOFF and the NBUT sprites
# are rescaled from Mindscape's own artwork, so the package carries none of it --
# the manifest records how they were made and they are rebuilt here from the
# player's own files. Doing the fonts the same way also keeps rendered Microsoft
# font bitmaps out of the package. Developer builds keep a prebuilt art/ and this
# whole block is skipped.
if (-not (Test-Path $artDir) -and ($man.PSObject.Properties.Name -contains 'art')) {
    $gen = @(Join-Path $PSScriptRoot 'src\Build-HudArt.ps1'), (Join-Path $PSScriptRoot 'src\Build-Font.ps1'),
           (Join-Path $PSScriptRoot 'src\Build-HudOverlay.ps1')
    if ($gen | Where-Object { -not (Test-Path $_) }) {
        Die "this build generates its art but src\Build-HudArt.ps1 / src\Build-Font.ps1 are missing"
    }
    # THE GENERATORS MUST NEVER SEE THEIR OWN OUTPUT.
    #
    # They rescale and repaint Mindscape's artwork, and every one of those
    # operations is destructive: rescaling an already-rescaled panel halves it
    # again, and wiping MAPBKGRD's baked HUD a second time finds no HUD to wipe
    # and produces nothing at all (which then trips the $missing check below).
    # Reading straight out of GAME\AZRAEL is only correct on a first install.
    #
    # So assemble a pristine input directory: every PCX/RES, taken from its
    # .aztbak backup when one exists and from the live file otherwise. Under a
    # megabyte all told, and it makes re-installing and upgrading idempotent.
    $liveArt = Join-Path $target 'GAME\AZRAEL'
    $srcArt  = Join-Path ([System.IO.Path]::GetTempPath()) ("aztmod-src-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $srcArt -Force | Out-Null
    $script:AztTempSrc = $srcArt
    foreach ($f in Get-ChildItem $liveArt -File) {
        if ($f.Extension -notmatch '^\.(PCX|RES)$') { continue }
        $bak = Join-Path $liveArt ($f.Name + '.aztbak')
        Copy-Item $(if (Test-Path $bak) { $bak } else { $f.FullName }) (Join-Path $srcArt $f.Name) -Force
    }

    $artDir = Join-Path ([System.IO.Path]::GetTempPath()) ("aztmod-art-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $artDir -Force | Out-Null
    Say "         building replacement art from your own game files..."
    try {
        # -CdImage: the map screen's backdrop is on the disc, not in GAME\AZRAEL.
        & $gen[0] -Scale $man.art.hudScale -GameDir $srcArt -OutDir $artDir `
                  -CdImage (Join-Path $target 'AZT.BIN') `
                  -ScreenW $(if ($man.art.PSObject.Properties.Name -contains 'screenW') { $man.art.screenW } else { 640 }) `
                  -ScreenH $(if ($man.art.PSObject.Properties.Name -contains 'screenH') { $man.art.screenH } else { 480 }) | Out-Null
        $fontArgs = @{ GameDir = $srcArt; OutDir = $artDir; Face = $man.art.fontFace
                       EmSize = [double]$man.art.fontEm; Height = [int]$man.art.fontHeight }
        if ($man.art.PSObject.Properties.Name -contains 'fontLevels') { $fontArgs['Levels'] = [int]$man.art.fontLevels }
        # The story log's own size, when it differs from the rest of the HUD.
        if ($man.art.PSObject.Properties.Name -contains 'logFontEm')     { $fontArgs['LogEm']     = [double]$man.art.logFontEm }
        if ($man.art.PSObject.Properties.Name -contains 'logFontHeight') { $fontArgs['LogHeight'] = [int]$man.art.logFontHeight }
        if ($man.art.PSObject.Properties.Name -contains 'logFontLevels') { $fontArgs['LogLevels'] = [int]$man.art.logFontLevels }
        if ($man.art.PSObject.Properties.Name -contains 'logFontCrisp')  { $fontArgs['LogCrisp']  = [bool]$man.art.logFontCrisp }
        if ($man.art.PSObject.Properties.Name -contains 'logFontStock')  { $fontArgs['LogStock']  = [bool]$man.art.logFontStock }
        & $gen[1] @fontArgs | Out-Null
        # HUDBOT.RES is addressed by framebuffer OFFSET, so it is only valid for
        # the exact viewport it was built for. Pass the manifest's geometry --
        # letting this default to 640x480 produces a file that composites at the
        # wrong stride, which is the documented cause of the widescreen smear.
        $ovArgs = @{ GameDir = $srcArt; OutDir = $artDir }
        foreach ($m in @(@('viewY','ViewY'), @('viewW','ViewW'), @('viewH','ViewH'),
                         @('panelTop','PanelTop'), @('screenW','ScreenW'), @('screenH','ScreenH'))) {
            if ($man.art.PSObject.Properties.Name -contains $m[0]) { $ovArgs[$m[1]] = [int]$man.art.($m[0]) }
        }
        & $gen[2] @ovArgs | Out-Null
        # The expanding log box's two frames, only if this build ships them. The
        # generator slices them out of the render in design\incoming and measures
        # the text area back out of the result -- see src\Build-HudBox.ps1.
        $boxGen = Join-Path $PSScriptRoot 'src\Build-HudBox.ps1'
        if (($man.art.files -contains 'BOXOFF.PCX') -and (Test-Path $boxGen)) {
            & $boxGen -GameDir $srcArt -OutDir $artDir -BoxW 207 -BoxHOff 111 -BoxHOn 231 -Pad 4 | Out-Null
        }
        # Stretch the inventory background to its recess (see src\Build-HudInv.ps1).
        $invGen = Join-Path $PSScriptRoot 'src\Build-HudInv.ps1'
        if (Test-Path $invGen) {
            & $invGen -ArtDir $artDir | Out-Null
        }
        # The health fill, as a solid rectangle the size of the gauge recess. Only
        # when this build actually ships one -- the engine's gauge surface is
        # resized to match, so a stock 105x15 H1 here would be copied short.
        $barGen = Join-Path $PSScriptRoot 'src\Build-HudBar.ps1'
        if (($man.art.files -contains 'H1.PCX') -and (Test-Path $barGen)) {
            & $barGen -ArtDir $artDir -StockH1 (Join-Path $srcArt 'H1.PCX') | Out-Null
        }

        # The system fold-out's 14 frames, rebuilt from one master render. The
        # size has to match what the build patched the draw site and the hot
        # spots to, so it comes from the manifest rather than the generator's
        # own default -- a mismatch would put the controls where they cannot be
        # clicked.
        $sysGen = Join-Path $PSScriptRoot 'src\Build-SysMenu.ps1'
        if (($man.art.files -contains 'SAVE00.PCX') -and (Test-Path $sysGen)) {
            & $sysGen -OutDir $artDir -GameDir $srcArt `
                      -W ([int]$man.art.sysMenuW) -H ([int]$man.art.sysMenuH) | Out-Null
        }

        # Rounded viewport corners (HUDTOP.RES), only if this build ships one.
        $topGen = Join-Path $PSScriptRoot 'src\Build-HudTop.ps1'
        if (($man.art.files -contains 'HUDTOP.RES') -and (Test-Path $topGen)) {
            # Build-HudTop reads Mindscape's own HUDTOP.RES for the visor curve
            # and resamples it, so it needs the UNMODIFIED file.
            $topArgs = @{ OutDir = $artDir; StockRes = (Join-Path $srcArt 'HUDTOP.RES') }
            foreach ($m in @(@('viewW','ViewW'), @('viewH','ViewH'), @('screenW','ScreenW'), @('cornerRadius','Radius'))) {
                if ($man.art.PSObject.Properties.Name -contains $m[0]) { $topArgs[$m[1]] = [int]$man.art.($m[0]) }
            }
            & $topGen @topArgs | Out-Null
        }
    } catch {
        Die "could not build the replacement art: $_"
    }
    $missing = @($man.art.files | Where-Object { -not (Test-Path (Join-Path $artDir $_)) })
    if ($missing.Count) { Die "art generation did not produce: $($missing -join ', ')" }
    Ok ("generated {0} art file(s)" -f $man.art.files.Count)
    $script:AztTempArt = $artDir
}
# Any art this build no longer ships must go back to stock, or a previous
# install's rescaled panel would be left behind under a build that expects the
# original geometry.
#
# ...and art this build deliberately does NOT ship has to be excluded even when a
# prebuilt art\ still holds a copy of it. A developer box keeps art\ populated
# and generation is skipped entirely (see above), so dropping a file from the
# manifest is not enough on its own -- the copy loop below walks the FOLDER, not
# the manifest, and would happily install a stale leftover.
$artExclude = @()
if (($man.PSObject.Properties.Name -contains 'art') -and
    ($man.art.PSObject.Properties.Name -contains 'logFontStock') -and [bool]$man.art.logFontStock) {
    $artExclude += @('RUSGLD2.PCX','GENBLU2.PCX')   # the log keeps Mindscape's own face
}
$shipped = @()
if (Test-Path $artDir) {
    $shipped = @(Get-ChildItem $artDir -File -Recurse |
                 ForEach-Object { $_.Name } |
                 Where-Object { $artExclude -notcontains $_ })
}
# R.EXE is handled above. MDI.INI is NOT part of the art pipeline -- it carries
# the General MIDI driver switch -- so it must not be swept back to stock here,
# only by -Revert.
# RESOURCE.CFG is NOT art either -- it carries the texture/sound/movie search
# paths, and pointing its first line at a folder on C: is how replacement artwork
# is loaded at all. Sweeping it back to stock silently sends the game to the CD
# again, which looks exactly like "my new art did not get installed".
# BOTH TREES ARE SWEPT RECURSIVELY. art\ installs into subfolders -- art\MICE\ into
# GAME\AZRAEL\MICE\, art\ORRPUZ\ into GAME\AZRAEL\ORRPUZ\, art\_AZTEX\ into GAME\AZTEX\ --
# so a build that STOPS shipping one of those leaves its replacement behind for good unless
# the sweep reaches the subfolder too. That is not hypothetical: the orrery art had to be put
# back by hand because this loop only looked at the AZRAEL root.
#
# Sweeping a shipped file is prevented by $shipped, which is built from art\ recursively, so
# MICE and anything else still being shipped is skipped here by name.
#
# Only .aztbak: Build-Books keeps the pre-rescale pages as .PCX.src, a deliberately separate
# scheme so that this sweep and the books' own revert cannot fight each other.
foreach ($b in (@(Get-ChildItem (Join-Path $target 'GAME\AZRAEL') -Filter '*.aztbak' -Recurse -ErrorAction SilentlyContinue) +
                @(Get-ChildItem (Join-Path $target 'GAME\AZTEX')  -Filter '*.aztbak' -Recurse -ErrorAction SilentlyContinue) |
                 Where-Object { $_.Name -notlike 'R.EXE*' -and $_.Name -notlike 'MDI.INI*' -and $_.Name -notlike 'RESOURCE.CFG*' })) {
    $name = $b.Name -replace '\.aztbak$',''
    if ($shipped -notcontains $name) {
        Copy-Item $b.FullName ($b.FullName -replace '\.aztbak$','') -Force
        Ok "restored stock $name (this build does not replace it)"
    }
}
if (Test-Path $artDir) {
    $n = 0
    # -Recurse so art\MICE\ lands in GAME\AZRAEL\MICE\. The cursor bitmaps index
    # the shared palette like everything else, so a reskin has to re-point them
    # too, and the game loads them by relative path -- they cannot be flattened.
    foreach ($f in Get-ChildItem $artDir -File -Recurse) {
        if ($artExclude -contains $f.Name) { continue }
        $rel  = $f.FullName.Substring($artDir.Length).TrimStart('\')
        # art\_AZTEX\... installs into GAME\AZTEX\... instead of GAME\AZRAEL\...
        #
        # Not everything replaceable lives beside the executables: the F1 help screen is
        # AZTEX\MAPS\HELP.PCX, loaded through RESOURCE.CFG's first search path. It could have
        # been written straight into the game folder the way Build-Books writes the pages,
        # but then it would not get an .aztbak, would not come back on -Revert, and would not
        # be swept when a later build stops shipping it. One reserved prefix keeps all of
        # that, and the leading underscore cannot collide with a real subfolder of AZRAEL.
        if ($rel -like '_AZTEX\*') {
            $dest = Join-Path $target ("GAME\AZTEX\" + $rel.Substring(7))
        } else {
            $dest = Join-Path $target ("GAME\AZRAEL\" + $rel)
        }
        # NEW assets -- ones the stock game has no counterpart for, like the
        # expanding log box's two frames -- are allowed through only when the
        # manifest asks for them by name. Everything else still has to be
        # REPLACING something, so a stray file left in art\ cannot be dumped into
        # the game directory by accident. A new file gets an .aztnew marker
        # instead of an .aztbak, because there is no stock version to put back:
        # -Revert deletes it.
        if (-not (Test-Path $dest)) {
            if ($man.art.files -notcontains $f.Name) { continue }
            Set-Content -Path "$dest.aztnew" -Value '' -Encoding ascii
        }
        $bak = "$dest.aztbak"
        if ((Test-Path $dest) -and -not (Test-Path $bak)) { Copy-Item $dest $bak -Force }
        Copy-Item $f.FullName $dest -Force
        Say ("         art             {0}" -f $f.Name)
        $n++
    }
    if ($n) { Ok "replaced $n HUD art file(s)" }
}

# CHARACTER ANIMATION LINES the game's own models already have keys for (Josh, 2026-10-13: the CORICORI creatures should
# pause "every once in a while ... explore that sniffing animation too as that would be perfect to include in the pause").
# EUGBLD.XAF carries frames 11-52 that no .ANI uses: a stand, a sniff at the ground, a look round with the jaw open, back
# to the stand -- the game's SNIFF state (keyword 10 at 0x147300) just never had a range. The line is ADDED HERE, in the
# installed copy, rather than shipping edited .ANI files (game data stays out of the repo). Each file keeps an .aztbak,
# so the stock-restore sweep above and -Revert both put the original back -- and this re-adds the line every install.
# The watcher pauses them into it (a room's "npcs": "pauseAnim": "SNIFF"). See docs\notes\azrael-npc-pace.md.
foreach ($ad in @(
    @{ File = 'EUGENE.ANI'; Line = 'SNIFF 11-52' },
    @{ File = 'EUGENB.ANI'; Line = 'SNIFF 11-52' }
)) {
    $ap = Join-Path $target ('GAME\AZRAEL\' + $ad.File)
    if (-not (Test-Path $ap)) { Say ("         ani             {0}: not in this game -- skipped" -f $ad.File); continue }
    $txt = [IO.File]::ReadAllText($ap)
    $kw = ($ad.Line -split '\s+')[0]
    if ($txt -match ('(?m)^\s*' + [regex]::Escape($kw) + '\s')) { continue }      # (there already)
    if (-not (Test-Path "$ap.aztbak")) { Copy-Item $ap "$ap.aztbak" -Force }
    $nl = $(if ($txt.Contains("`r`n")) { "`r`n" } else { "`n" })
    $mRest = [regex]::Match($txt, '(?m)^\s*REST\s[^\r\n]*')
    $txt = $(if ($mRest.Success) { $txt.Insert($mRest.Index + $mRest.Length, $nl + $ad.Line) } else { $txt.TrimEnd() + $nl + $ad.Line + $nl })
    [IO.File]::WriteAllText($ap, $txt, (New-Object Text.ASCIIEncoding))
    Ok ("{0}: added '{1}'" -f $ad.File, $ad.Line)
}

# The BSS overlay. Not art and not a patch: it is code that has no file offset to
# be patched into, so it ships as bytes in the manifest and is written out here
# for AztOverlayLoad to read on the first frame.
#
# IT IS NOT OPTIONAL -- patched call sites point into it by absolute address, so
# a missing file is a crash rather than a lost feature. It gets an .aztnew marker
# because the stock game has no counterpart, which is what makes -Revert delete
# it rather than try to restore one.
if ($man.PSObject.Properties.Name -contains 'overlay' -and $man.overlay) {
    $ovDir  = Join-Path $target ($man.overlay.dir -replace '/','\')
    $ovPath = Join-Path $ovDir $man.overlay.name
    if (-not (Test-Path $ovDir)) { Die "overlay target directory is missing: $ovDir" }
    $ovBytes = FromHex $man.overlay.bytes
    if (-not (Test-Path $ovPath)) { Set-Content -Path "$ovPath.aztnew" -Value '' -Encoding ascii }
    [System.IO.File]::WriteAllBytes($ovPath, $ovBytes)
    Ok ("wrote {0} ({1:N0} bytes of code -> linear {2})" -f $man.overlay.name, $ovBytes.Length, $man.overlay.base)
}

# Readable book/scroll pages, rescaled to the screen. These live in the TEXTURE
# tree (GAME\AZTEX\BOOKS, where RESOURCE.CFG points), not in GAME\AZRAEL, so they
# are not part of the art copy above -- they are rewritten where they sit, with
# the pre-rescale page kept beside each one as .PCX.src.
#
# THIS MUST MATCH $BOOK_FULLSCREEN IN THE BUILD. When the pages are screen-sized
# the build drops its `book-centre` patch and the stock (0,0) placement is
# correct; if the pages were left at 640x480 with that patch gone, every page
# would sit in the top-left corner. The manifest carries the flag so the two
# cannot drift apart.
if ($man.PSObject.Properties.Name -contains 'art' -and
    $man.art.PSObject.Properties.Name -contains 'bookFullscreen' -and [bool]$man.art.bookFullscreen) {
    $bookGen = Join-Path $PSScriptRoot 'src\Build-Books.ps1'
    $bookDir = Join-Path $target 'GAME\AZTEX\BOOKS'
    if ((Test-Path $bookGen) -and (Test-Path $bookDir)) {
        try {
            $bookArgs = @{ BookDir = $bookDir
                           Width   = [int]$man.art.screenW
                           Height  = [int]$man.art.screenH }
            # -InDir, when the build named a folder of up-rezzed pages and it is there.
            # WITHOUT THIS the regeneration below rescales from the pristine 640x480 .src
            # every single install, silently discarding imported high-resolution art --
            # the page would simply get blurrier again with no message to say why.
            if ($man.art.PSObject.Properties.Name -contains 'bookSource' -and
                $man.art.bookSource -and (Test-Path $man.art.bookSource)) {
                $bookArgs.InDir = [string]$man.art.bookSource
                Say ("         book pages from {0}" -f $man.art.bookSource)
            }
            if ($man.art.PSObject.Properties.Name -contains 'bookFillPct' -and $man.art.bookFillPct) {
                $bookArgs.FillPct = [int]$man.art.bookFillPct
            }
            $r = & $bookGen @bookArgs
            Ok ([string]$r)
        } catch {
            Say "         WARNING: could not rescale the book pages: $_"
        }
    }
}
if (Get-Variable -Name AztTempSrc -Scope Script -ErrorAction SilentlyContinue) {
    Remove-Item $script:AztTempSrc -Recurse -Force -ErrorAction SilentlyContinue
}
if (Get-Variable -Name AztTempArt -Scope Script -ErrorAction SilentlyContinue) {
    Remove-Item $script:AztTempArt -Recurse -Force -ErrorAction SilentlyContinue
}

# DOSBox memory is left at the stock 16 MB.
#
# v0.9.3 raised it to 32 on the theory that the enlarged buffers had run the pool
# dry. They had not: with memsize=32 the identical fault simply moved from
# 0x1000000 to 0x2000000 -- i.e. it always lands on the last byte of whatever pool
# it is given, which is the signature of a buffer being walked off the end, not of
# a pool that is slightly too small. (The real culprit was the HUDTOP/HUDBOT
# overlay writing 552-wide rows into a 640-wide framebuffer; see hook-hudres.)
# Anything above 31 MB also makes DOSBox print a "NOT recommended" warning.
$conf = Join-Path $target 'azrael-base.conf'
if (Test-Path "$conf.aztbak") {
    Copy-Item "$conf.aztbak" $conf -Force
    Ok "DOSBox memsize restored to the stock value"
}

# Optional: skip the intro movies.
#
# Two separate players are involved. TM.EXE is invoked by AZRAEL.BAT before the
# game; R.EXE plays mindlogo.mov and intro.mov itself. The R.EXE side CANNOT be
# patched out -- NOPing either the sequence function (0x1FF39) or its three calls
# to the player (0x20BD4) boots straight into "INT:Gate Selector points to
# illegal descriptor", so that code is doing more than playing video. Renaming
# the files leaves every code path intact and just gives the player nothing to
# open.
# Renaming the .MOV files does not work either -- the game exits silently before
# reaching the menu. So only the TM.EXE half can be skipped for now; R.EXE still
# plays mindlogo.mov and intro.mov, both of which are click-through.
foreach ($mov in @('INTRO.MOV', 'MINDLOGO.MOV')) {
    $p = Join-Path $target "GAME\AZRAEL\$mov"
    if (Test-Path "$p.aztoff") { Move-Item "$p.aztoff" $p -Force; Ok "restored $mov" }
}

# Hi-res needs UVCONFIG.DAT out of the way.
#
# That file is a SAVED SciTech UniVBE configuration -- its strings read
# "S3 SuperVGA (Trio64) with 1 Mb". While it is present the driver only offers
# the mode list it was detected with, and the game's mode-list scan fails for
# anything above 640x480: it gives up and exits SILENTLY, with nothing in either
# DOSBox's log or the game's own stdout.
#
# Proof: with every size constant left alone and ONLY the mode number changed,
# 0x100 (640x400) starts and 0x103/0x105 do not. Move this file aside and 0x103
# starts immediately. UniVBE then re-detects the emulated S3 and offers the
# larger modes.
$uvc = Join-Path $target 'GAME\AZRAEL\UVCONFIG.DAT'
$wantHires = ($man.PSObject.Properties.Name -contains 'hires') -and $man.hires
if ($wantHires) {
    if (Test-Path $uvc) { Move-Item $uvc "$uvc.aztoff" -Force; Ok 'UVCONFIG.DAT moved aside (it pins UniVBE to a 640x480 mode list)' }
} elseif (Test-Path "$uvc.aztoff") {
    Move-Item "$uvc.aztoff" $uvc -Force; Ok 'UVCONFIG.DAT restored'
}

$abat = Join-Path $target 'GAME\AZRAEL\AZRAEL.BAT'
if ($SkipIntro -and (Test-Path $abat)) {
    $bak = "$abat.aztbak"
    if (-not (Test-Path $bak)) { Copy-Item $abat $bak -Force }
    @'
@echo off
rem AztMod: intro movie skipped. The original is in AZRAEL.BAT.aztbak
r %1 %2 %3
'@ | Set-Content -Path $abat -Encoding ascii
    Ok "intro movie skipped (AZRAEL.BAT now runs R directly)"
} elseif (Test-Path $abat) {
    # Intro kept -- but TM.EXE prints a boot screen first ("Azrael's Tear : v1.0 /
    # (c) 1993-1996 Intelligent Games Limited", then "Found %dKB of Extended RAM" and
    # friends). Redirecting its stdout to NUL hides that while still letting it play the
    # movie and set the errorlevel R depends on.
    #
    # THE REDIRECT IS ON TM ONLY. R's own output must not be touched: the same batch line
    # decides whether R runs at all, and a failed TM has to keep reporting it.
    if (Test-Path "$abat.aztbak") { Copy-Item "$abat.aztbak" $abat -Force }
    else { Copy-Item $abat "$abat.aztbak" -Force }
    @'
@echo off
rem AztMod: TM's startup banner and memory report sent to NUL. It still plays the intro
rem and still sets ERRORLEVEL, so R runs exactly as before. Original in AZRAEL.BAT.aztbak
tm %1 %2 %3 > NUL
if NOT ERRORLEVEL 1 r %1 %2 %3
'@ | Set-Content -Path $abat -Encoding ascii
    Ok "intro kept; TM's boot banner suppressed (pass -SkipIntro to skip the intro entirely)"
}

# a launcher that works regardless of where it is invoked from
#
# PREFER DOSBOX STAGING. This used to hard-code the bundled 0.74 and was never
# updated when the project moved to Staging, so every "modded" launch silently ran
# the OLD emulator on azrael-base.conf -- `cycles = max limit 280000` and
# `memsize = 16`, rather than Staging's 400000 / 32. That is a large amount of CPU
# to lose, and at 800x600 (1.56x the pixels of 640x480) the rasteriser needs all
# of it: heavy rooms could not get near the 40 fps cap, which made everything
# frame-tied crawl. The two launchers have to agree on the emulator or the tuning
# in azrael-staging.conf is tuning something nobody runs.
# (2026-10-15: this plain launcher is now Play-Azrael-8bit.bat -- the 8-bit game, no renderer. Play-Azrael-Modded.bat, written
# below, starts the GPU version through the repo's launcher: on the second PC that name was the obvious one to click, and it
# never started the renderer)
$bat = Join-Path $target 'Play-Azrael-8bit.bat'
$staging = Join-Path $target 'DOSBOX-STAGING\dosbox.exe'
if ((Test-Path $staging) -and (Test-Path (Join-Path $target 'azrael-staging.conf'))) {
    @'
@echo off
cd /d "%~dp0"
start "" /W /B DOSBOX-STAGING\dosbox.exe --noprimaryconf --nolocalconf --conf azrael-staging.conf --conf azrael-game.conf %*
'@ | Set-Content -Path $bat -Encoding ascii
    Ok "wrote $(Split-Path -Leaf $bat)  (DOSBox Staging)"
} else {
    @'
@echo off
cd /d "%~dp0"
start "" /W /B DOSBOX\DOSBox.exe -noconsole -conf azrael-base.conf -conf azrael-graphics.conf -conf azrael-game.conf
'@ | Set-Content -Path $bat -Encoding ascii
    Ok "wrote $(Split-Path -Leaf $bat)  (DOSBox 0.74 -- Staging not found)"
}

# THE MAIN LAUNCHER: the GPU version (the repo's Play-HostRender-TrueColour.cmd: the renderer starts the game), the 8-bit one
# when there is no repo beside this install
$gpuCmd = Join-Path $PSScriptRoot 'Play-HostRender-TrueColour.cmd'
$main = Join-Path $target 'Play-Azrael-Modded.bat'
if (Test-Path $gpuCmd) {
    @"
@echo off
REM RaptorMod -- the GPU version: the host renderer starts the game ($([IO.Path]::GetFileName($gpuCmd)) in the repo).
REM Play-Azrael-8bit.bat beside this runs the game without the renderer.
call "$gpuCmd" %*
"@ | Set-Content -Path $main -Encoding ascii
    Ok "wrote Play-Azrael-Modded.bat  (the GPU version, through $gpuCmd)"
} else {
    Copy-Item $bat $main -Force
    Ok "wrote Play-Azrael-Modded.bat  (the 8-bit game: no renderer beside this install)"
}
$bat = $main

Say ""
Say "Done. Launch with:  $bat"
Say "  (this is the ONLY executable that has the mod -- launching from Steam,"
Say "   or the original run-game.bat, runs the unpatched game)"
Show-Keys
Say ""
Say "To undo:"
Say "  .\Apply-AztMod.ps1 -Revert -Dest `"$target`""
Say ""

