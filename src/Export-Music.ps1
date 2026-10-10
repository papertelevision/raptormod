# Export-Music.ps1 -- turn the game's .XMI score into playable .MID files.
#
# Azrael ships TWO arrangements of the same music and picks between them at
# start-up from the DRIVER line in MDI.INI (see 0x1EF9B, which matches it
# against ULTRA / SBAWE32 / SNDSCAPE / MPU401 and returns 1 for a wavetable
# card, 0 otherwise; 0x138DD then chooses the track table):
#
#   wavetable / General MIDI     awemyst  cathedrl egyptian fight2  ghosts
#                                grail    ingame   ingame2  kreepy2 kreepy3
#                                peaceful
#   OPL FM synthesis             awe_fm   cath_fm  egypt_fm fite2_fm ghost_fm
#                                grail_fm game1_fm game2_fm krep2_fm krep3_fm
#                                peace_fm
#
# AztMod sets MPU401.MDI, so it plays the FIRST set. This exports both so the
# difference can be heard directly instead of inferred.
#
# NOTE ON WHAT THIS IS AND IS NOT: the game has no recorded music at all. Every
# track is a MIDI sequence, so every track will sound like MIDI. How good it
# sounds is entirely down to the synthesiser -- for AztMod that is FluidSynth
# with soundfonts\GeneralUser-GS.sf2, set in azrael-staging.conf.
param(
    [string]$GameDir = "C:\Games\AzraelsTear-Modded\GAME\AZRAEL",
    [string]$OutDir  = "$PSScriptRoot\..\..\music-export"
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\..\tools\XmiTool.cs"

if (-not (Test-Path $GameDir)) { throw "game folder not found: $GameDir" }
$gm = @('awemyst','cathedrl','egyptian','fight2','ghosts','grail','ingame','ingame2','kreepy2','kreepy3','peaceful')

foreach ($sub in @('general-midi','opl-fm','other')) {
    New-Item -ItemType Directory -Force (Join-Path $OutDir $sub) | Out-Null
}

$n = 0
foreach ($f in (Get-ChildItem $GameDir -Filter '*.XMI' | Sort-Object Name)) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name).ToLower()
    $sub  = if ($gm -contains $stem)    { 'general-midi' }
            elseif ($stem -like '*_fm') { 'opl-fm' }
            else                        { 'other' }
    $dest = Join-Path $OutDir $sub
    $made = [AztTool.Xmi]::Convert($f.FullName, $dest)
    foreach ($m in $made) {
        Write-Host ("{0,-14} -> {1}\{2}  ({3:N0} bytes)" -f $f.Name, $sub, (Split-Path $m -Leaf), (Get-Item $m).Length)
        $n++
    }
}
Write-Host ""
Write-Host ("{0} .mid written to {1}" -f $n, (Resolve-Path $OutDir))
Write-Host "general-midi\ is what AztMod plays; opl-fm\ is what the stock game plays."
