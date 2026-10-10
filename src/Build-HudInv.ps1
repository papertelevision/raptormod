# Build-HudInv.ps1 -- rescale the inventory/notes window background to fill its
# recess in the reskinned panel.
#
# INVBACK2.PCX ships 103x69, which is exactly what the stock layout wanted. The
# new panel's recess is larger, so the stock art sat centred with a band of bare
# recess around it. This stretches it to the recess and Build-AztMod then draws
# it at the recess's top-left corner instead of centring it.
#
# NEAREST-NEIGHBOUR ON THE INDICES, not a filtered resample of the colours. The
# file is 8-bit paletted and every index has to stay inside the HUD's 1..53
# budget; averaging neighbours would invent colours that are not in it and the
# nearest-match afterwards would smear the crisp one-pixel edges of the border.
param(
    [string]$ArtDir = "$PSScriptRoot\..\art",
    [string]$Name   = 'INVBACK2.PCX',
    [int]   $W      = 0,      # 0 = take it from art\hud-layout.json
    [int]   $H      = 0
)

Add-Type -Path "$PSScriptRoot\..\tools\PcxTool.cs" -ReferencedAssemblies "System.Drawing"

if ($W -le 0 -or $H -le 0) {
    $lf = Join-Path $ArtDir 'hud-layout.json'
    if (-not (Test-Path $lf)) { throw "need art\hud-layout.json to size $Name (or pass -W/-H)" }
    $L = Get-Content $lf -Raw | ConvertFrom-Json
    # The inventory recess is the automap's region: widest of the two tall ones.
    # Identified by SHAPE, like everywhere else -- never by index.
    $rg = @($L.regions)
    $map = @($rg | Where-Object { $_.w -gt 100 -and $_.h -gt 60 } | Sort-Object x | Select-Object -First 1)[0]
    if (-not $map) { throw 'could not find the inventory recess in hud-layout.json' }
    $W = [int]$map.w; $H = [int]$map.h
}

$path = Join-Path $ArtDir $Name
$src  = [LeTool.Pcx]::Load($path)
if ($src.Width -eq $W -and $src.Height -eq $H) {
    Write-Host ("{0} is already {1}x{2}" -f $Name, $W, $H); return
}
$sw = $src.Width; $sh = $src.Height
$dst = New-Object byte[] ($W * $H)
for ($y = 0; $y -lt $H; $y++) {
    $sy = [int](($y * $sh) / $H); if ($sy -ge $sh) { $sy = $sh - 1 }
    for ($x = 0; $x -lt $W; $x++) {
        $sx = [int](($x * $sw) / $W); if ($sx -ge $sw) { $sx = $sw - 1 }
        $dst[$y*$W + $x] = $src.Pixels[$sy*$sw + $sx]
    }
}
$out = New-Object LeTool.Pcx
$out.Width = $W; $out.Height = $H
$out.BitsPerPixel = 8; $out.Planes = 1; $out.BytesPerLine = $W
$out.Pixels = $dst
$out.Palette = $src.Palette.Clone()
$out.SavePcx($path)
Write-Host ("{0}: {1}x{2} -> {3}x{4}" -f $Name, $sw, $sh, $W, $H)
