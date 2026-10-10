# Build-Art.ps1 -- regenerate the WHOLE art chain for one target resolution.
#
# WHY THIS EXISTS. Changing the screen size means re-running nine generators in a
# fixed order with a dozen derived sizes threaded between them, and until now that
# order lived only in a memory note. Every resolution change rediscovered the same
# three traps:
#
#   * Build-HudArt MUST run before Build-HudSkin. HudArt rescales Mindscape's art
#     and writes HUD3/HUDOFF/MAPBKGRD/NBUT*; HudSkin then paints the reskin over
#     it. Running only HudSkin leaves the widget sprites at the old scale, and
#     running HudArt second wipes the reskin.
#   * Build-SysMenu defaults -OutDir to design\incoming\sysmenu\out, NOT art\, so
#     without an explicit -OutDir the frames are generated and never shipped.
#   * Build-Font defaults -GameDir to the MODIFIED copy. It must read the PRISTINE
#     Steam install or it re-renders a font from an already-replaced font.
#
# The sizes are all derived from (ScreenW, ScreenH, PanelScale) by exactly the
# arithmetic Build-AztMod uses, so there is one definition of the layout rather
# than two that have to be kept in step by hand. Pass -WhatIf to see the numbers
# without generating anything.
#
#   .\src\Build-Art.ps1 -ScreenW 1600 -ScreenH 1200
#   .\src\Build-Art.ps1 -ScreenW 1024 -ScreenH 768 -WhatIf
#
# It does NOT run Build-AztMod, Build-Books, Build-Title, Build-Screens or
# Build-Credits: the first is the patch build, and the rest are content rather
# than layout. Run Build-AztMod afterwards -- it re-asserts every size this wrote
# and names the exact flag to fix if one disagrees.
[CmdletBinding()]
param(
    [int]   $ScreenW    = 1600,
    [int]   $ScreenH    = 1200,
    [double]$PanelScale = 0.55,
    # Rows reserved for the compass strip above the viewport. A CONSTANT at every
    # resolution, deliberately: rows 0..48 of HUD3 are empty and the only thing up
    # there is COMPMAP.PCX, a fixed 348x24 sprite the game blits at (x,15). Scaling
    # it just reserves dead rows and pushes the viewport down.
    [int]   $ViewY      = 49,
    [string]$ArtDir     = "$PSScriptRoot\..\art",
    # The PRISTINE install, for generators that read Mindscape's originals.
    [string]$StockGame  = "$PSScriptRoot\..\..\GAME\AZRAEL",
    # Composed from design\boxoff-4x.png + boxon-4x.png on first use; see below.
    [string]$BoxSheet   = "$PSScriptRoot\..\design\box-pair-sheet.png",
    [string]$SysMaster  = "$PSScriptRoot\..\design\incoming\sysmenu\master.png",
    [string[]]$Only     = @(),      # run just these steps, by name
    # THE LOG BOX NEEDS A SECOND PASS, and that is structural rather than an
    # oversight. Build-AztMod sizes the frame from the SCAN READOUT region it
    # measures out of the finished panel artwork (frame = scan + pads + lip +
    # extend), so the number cannot be known until HudSkin has run -- and HudSkin
    # runs inside this script. Duplicating that arithmetic here is exactly the
    # drift this wrapper exists to prevent, so instead:
    #
    #   1. .\src\Build-Art.ps1 -ScreenW w -ScreenH h
    #   2. .\src\Build-AztMod.ps1          -> throws, naming -BoxW/-BoxHOff/-BoxHOn
    #   3. .\src\Build-Art.ps1 -Only HudBox -BoxW .. -BoxHOff .. -BoxHOn ..
    #   4. .\src\Build-AztMod.ps1          -> clean
    #
    # 0 means "use the rough scale-up", which gets pass 1 far enough to measure.
    [int]   $BoxW       = 0,
    [int]   $BoxHOff    = 0,
    [int]   $BoxHOn     = 0,
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

# ---- the layout, derived exactly as Build-AztMod derives it ---------------------
$SCREEN_W_OLD  = 640
$PANEL_TOP_OLD = 318
$HS            = $ScreenW / [double]$SCREEN_W_OLD
function Hi([double]$v) { [int][Math]::Round($v * $HS) }
$panelScaleEff = $PanelScale * $HS
$panelH        = [int][Math]::Round((480 - $PANEL_TOP_OLD) * $panelScaleEff)
$panelTop      = $ScreenH - $panelH
$viewW         = $ScreenW
$viewH         = $panelTop - $ViewY
$radius        = [int][Math]::Round(26 * $HS / 1.6)
$sysW          = Hi 206
$sysH          = Hi 170
$fontEm        = 10 * $HS
$fontHeight    = Hi 12
$fontLevels    = 6
# The STORY LOG sheets (RUSGLD2 gold narration / GENBLU2 cyan conversation). Kept
# deliberately BELOW the full Hi(12) = 30, because the renderer takes wrap width from
# the surface and line height from the sheet, so a taller face costs characters per
# line in a fixed recess. Measured over the 139 glyphs: 12 rows -> ~29 chars in the
# 287 px recess, 24 -> ~23, 30 -> ~19. 24 is double the stock height and still reads
# as prose. Must match $LOG_FONT_ROWS / $LOG_FONT_EM in Build-AztMod.ps1.
$logRows       = 21          # 24 until 2026-10-07: Josh asked for slightly smaller, to fit more in the log
$logEm         = 17.5
$logLevels     = 6
# The rough scale-up, used only until Build-AztMod measures the real frame; see
# the -BoxW note in the parameter block for why this takes two passes.
# Must match Build-AztMod's $GAUGE_W_EXTRA exactly, which is why both are the same
# expression against the 1024 measurement rather than two literals that can drift.
$gaugeExtra    = [int][Math]::Floor(2 * $HS / 1.6)
$boxWEff       = $(if ($BoxW    -gt 0) { $BoxW }    else { Hi 160 })
$boxHOffEff    = $(if ($BoxHOff -gt 0) { $BoxHOff } else { $panelH })
$boxHOnEff     = $(if ($BoxHOn  -gt 0) { $BoxHOn }  else { $panelH + (Hi 75) })

if ([Math]::Abs(($ScreenW / [double]$ScreenH) - (4.0/3.0)) -gt 0.001) {
    Write-Host ("  WARNING: {0}x{1} is not 4:3 -- one uniform scale will not fit it" -f $ScreenW, $ScreenH) -ForegroundColor Yellow
}
if (-not (Test-Path $StockGame)) { throw "the pristine game is not at $StockGame" }

Write-Host ("art chain for {0}x{1}  (scale {2:N4}, panel {3}%)" -f $ScreenW,$ScreenH,$HS,($PanelScale*100))
Write-Host ("  viewport      {0} x {1} at (0,{2})" -f $viewW,$viewH,$ViewY)
Write-Host ("  panel         {0} rows, top at {1}" -f $panelH,$panelTop)
Write-Host ("  corner radius {0}" -f $radius)
Write-Host ("  fold-out      {0} x {1}" -f $sysW,$sysH)
Write-Host ("  font          em {0}, height {1}, {2} levels" -f $fontEm,$fontHeight,$fontLevels)
Write-Host ''

# ---- every generator runs in its OWN PowerShell process ------------------------
# Not for isolation's sake -- because they cannot share one. Each generator does
# its own `Add-Type` of PcxTool/Quantize, and Add-Type is process-wide: the first
# one wins and the next throws "the type name 'LeTool.Pcx' already exists". Run
# in-process and the chain dies at whichever generator happens to be second.
#
# It also means a generator that throws cannot leave half-initialised state behind
# for the next one, and the exit code is the only thing that crosses the boundary.
function Q([string]$s) { "'" + $s.Replace("'","''") + "'" }   # the project path has an apostrophe in it
$tmp = Join-Path $env:TEMP ("aztart-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
function Invoke-Generator([string]$cmd) {
    [IO.File]::WriteAllText($tmp, "`$ErrorActionPreference='Stop'`r`n$cmd`r`n", (New-Object Text.UTF8Encoding $false))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
    if ($LASTEXITCODE -ne 0) { throw "generator exited with code $LASTEXITCODE" }
}

# ---- the box sheet, composed from the two separate renders ----------------------
# Build-HudBox wants ONE page with both panels on it, found by connected component
# and told apart by aspect. The renders exist only as two files (boxoff-4x 696x376
# and boxon-4x 696x856, each a panel on a near-white page), and the one file that
# looks like a sheet -- box-surround-4x -- holds a single panel on black, so it
# fails the two-panel check. Composing the pair side by side on white, with a gap
# wide enough that the components cannot touch and merge into one, gives the
# slicer exactly the input it documents.
$BoxOff4x = "$PSScriptRoot\..\design\boxoff-4x.png"
$BoxOn4x  = "$PSScriptRoot\..\design\boxon-4x.png"
if (-not $WhatIf -and ($Only.Count -eq 0 -or $Only -contains 'HudBox')) {
    if (-not (Test-Path $BoxSheet)) {
        Add-Type -AssemblyName System.Drawing
        $a = [System.Drawing.Bitmap]::FromFile((Resolve-Path $BoxOff4x).Path)
        $b = [System.Drawing.Bitmap]::FromFile((Resolve-Path $BoxOn4x).Path)
        $gap = 80
        $sheet = New-Object System.Drawing.Bitmap (($gap*3 + $a.Width + $b.Width), ($gap*2 + [Math]::Max($a.Height,$b.Height)))
        $g = [System.Drawing.Graphics]::FromImage($sheet)
        $g.Clear([System.Drawing.Color]::White)
        $g.DrawImage($a, $gap, $gap, $a.Width, $a.Height)
        $g.DrawImage($b, ($gap*2 + $a.Width), $gap, $b.Width, $b.Height)
        $g.Dispose(); $a.Dispose(); $b.Dispose()
        $sheet.Save($BoxSheet, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host ("composed the box sheet: {0}x{1} -> {2}" -f $sheet.Width,$sheet.Height,(Split-Path $BoxSheet -Leaf))
        $sheet.Dispose()
    }
}

# ---- the chain, in the only order that works -----------------------------------
# Each step is a name and a command line. The ORDER IS THE POINT; see the header.
$steps = @(
    @{ Name = 'HudArt'; Why = 'rescales Mindscape art: HUD3, HUDOFF, MAPBKGRD, NBUT*'
       Cmd = "& $(Q "$PSScriptRoot\Build-HudArt.ps1") -Scale $PanelScale -ScreenW $ScreenW -ScreenH $ScreenH -OutDir $(Q $ArtDir) -GameDir $(Q $StockGame)" }

    # THE LOG SHEETS ARE GENERATED AGAIN. They were kept stock (1380x12) because at
    # 1024x768 every generated replacement looked worse -- but that was a 12-row
    # render, and anti-aliased glyphs improve as they grow. At 1600x1200 the stock
    # sheet is simply too small: the panel and the log recess scaled by 2.5 and the
    # text did not. $logRows/$logEm MUST match $LOG_FONT_ROWS/$LOG_FONT_EM in
    # Build-AztMod, which asserts the generated sheet's height for exactly that
    # reason -- the engine reads LINE HEIGHT off the sheet, so a mismatch re-wraps
    # the log at the wrong leading instead of failing.
    @{ Name = 'Font'; Why = "the HUD and log typeface ($logRows-row log sheets)"
       Cmd = "& $(Q "$PSScriptRoot\Build-Font.ps1") -GameDir $(Q $StockGame) -OutDir $(Q $ArtDir) -EmSize $fontEm -Height $fontHeight -Levels $fontLevels -LogStock `$false -LogEm $logEm -LogHeight $logRows -LogLevels $logLevels -InvEm $logEm -InvHeight $logRows" }

    @{ Name = 'HudSkin'; Why = 'paints the reskin over HudArt and writes hud-layout.json'
       Cmd = "& $(Q "$PSScriptRoot\Build-HudSkin.ps1") -OutDir $(Q $ArtDir) -ScreenW $ScreenW -ScreenH $ScreenH -PanelTop $panelTop -ViewY $ViewY" }

    @{ Name = 'HudRepalette'; Why = 'folds the reskin inks into the live palette slice'
       Cmd = "& $(Q "$PSScriptRoot\Build-HudRepalette.ps1") -ArtDir $(Q $ArtDir)" }

    @{ Name = 'HudButtons'; Why = 'mode and arrow sprites, sized from hud-layout.json'
       Cmd = "& $(Q "$PSScriptRoot\Build-HudButtons.ps1") -ArtDir $(Q $ArtDir)" }

    @{ Name = 'HudInv'; Why = 'INVBACK2, sized from hud-layout.json'
       Cmd = "& $(Q "$PSScriptRoot\Build-HudInv.ps1") -ArtDir $(Q $ArtDir)" }

    # H1 must come out at exactly the width Build-AztMod will compute, which is the
    # detected recess PLUS $GAUGE_W_EXTRA -- the bar deliberately overhangs the
    # registration rectangle, because the painted well is wider than it. Left to its
    # own default Build-HudBar sizes H1 to the bare recess and the patch build then
    # rejects it for being 3 px narrow. The width is read from hud-layout.json INSIDE
    # the child process, because HudSkin only just wrote it in this same run.
    @{ Name = 'HudBar'; Why = "H1, the health fill, recess + $gaugeExtra px of overhang"
       Cmd = "`$g = ((Get-Content $(Q (Join-Path $ArtDir 'hud-layout.json')) -Raw | ConvertFrom-Json).regions | " +
             "Where-Object { (`$_.w / `$_.h) -ge 4.0 } | Select-Object -First 1)`r`n" +
             "if (-not `$g) { throw 'no gauge recess (aspect >= 4) in hud-layout.json' }`r`n" +
             # NO -H ANY MORE. It was pinned to Mindscape's 15 while $GAUGE_RESIZE_H was
             # off; both are on now, so the HEIGHT comes from the measured recess exactly
             # as the width does, and Build-AztMod asserts H1 matches the gauge surface.
             "& $(Q "$PSScriptRoot\Build-HudBar.ps1") -ArtDir $(Q $ArtDir) -StockH1 $(Q (Join-Path $StockGame 'H1.PCX')) -W ([int]`$g.w + $gaugeExtra)" }

    @{ Name = 'HudBox'; Why = 'the expanding log box, both states'
       Cmd = "& $(Q "$PSScriptRoot\Build-HudBox.ps1") -Sheet $(Q $BoxSheet) -OutDir $(Q $ArtDir) -GameDir $(Q $StockGame) -BoxW $boxWEff -BoxHOff $boxHOffEff -BoxHOn $boxHOnEff" }

    @{ Name = 'HudTop'; Why = 'HUDTOP.RES -- the visor curve over the viewport'
       Cmd = "& $(Q "$PSScriptRoot\Build-HudTop.ps1") -OutDir $(Q $ArtDir) -ViewW $viewW -ViewH $viewH -ScreenW $ScreenW -Radius $radius -StockRes $(Q (Join-Path $StockGame 'HUDTOP.RES')) -NoBottom" }

    @{ Name = 'SysMenu'; Why = 'the 14 fold-out frames -- NOTE the explicit -OutDir'
       Cmd = "& $(Q "$PSScriptRoot\Build-SysMenu.ps1") -W $sysW -H $sysH -Master $(Q $SysMaster) -OutDir $(Q $ArtDir) -GameDir $(Q $StockGame) -NoPreview" }
)

$ran = 0; $failed = @()
foreach ($s in $steps) {
    if ($Only.Count -gt 0 -and $Only -notcontains $s.Name) { continue }
    Write-Host ("==== {0,-13} {1}" -f $s.Name, $s.Why) -ForegroundColor Cyan
    if ($WhatIf) { Write-Host ('     ' + $s.Cmd); continue }
    try { Invoke-Generator $s.Cmd; $ran++ }
    catch {
        # Keep going. A generator that fails on a size it does not like should not
        # hide the four after it that would have failed on something else -- one
        # pass of this script should surface every disagreement, not the first.
        Write-Host ("     FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $failed += [pscustomobject]@{ Step = $s.Name; Error = $_.Exception.Message }
    }
    Write-Host ''
}

if (Test-Path $tmp) { Remove-Item $tmp -Force }
if ($WhatIf) { Write-Host 'nothing generated (-WhatIf)'; return }
Write-Host ("{0} step(s) ran, {1} failed" -f $ran, $failed.Count)
if ($failed.Count) {
    $failed | ForEach-Object { Write-Host ("  {0,-13} {1}" -f $_.Step, $_.Error) -ForegroundColor Red }
    throw "$($failed.Count) art step(s) failed -- the art set is INCONSISTENT, do not install it"
}
Write-Host 'now run src\Build-AztMod.ps1 -- it re-asserts every size written here' -ForegroundColor Green
