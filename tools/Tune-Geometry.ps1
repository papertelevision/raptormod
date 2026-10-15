# Tune-Geometry.ps1 -- is the host render even AIMED the same way as the engine's?
#
#   .\tools\Tune-Geometry.ps1 -Name opening3
#
# Tonal tuning is meaningless until this passes. Against the opening3 capture the host's
# row profile correlated with the engine's at 0.002 -- no relationship at all -- while the
# column profile managed 0.577. A render that is pointed wrong can still be made to match
# a brightness histogram, and then every later "lighting" result is fitted to noise. This
# is the same failure mode as the transposed view matrix: it looked plausible.
#
# WHAT EACH NUMBER MEANS
#   row correlation    vertical agreement -- pitch, or vertical field of view
#   col correlation    horizontal agreement -- yaw, or horizontal field of view
#   best shift         if correlation is good only at a non-zero shift, the view is
#                      OFFSET; if it is bad at every shift, the view is the wrong SHAPE
#                      and no amount of shifting will fix it (wrong FOV, or flipped)
#
# Lighting is deliberately OFF: this measures where geometry lands, and attenuation only
# moves pixels across the lit/unlit threshold and muddies the profile.
[CmdletBinding()]
param(
    [string]$Name = 'opening3',
    [string]$RefDir = 'C:\Games\RaptorMod\cache\ref',
    [string]$CacheDir = 'C:\Games\RaptorMod\cache',
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    [string]$Palette = 'C:\Games\RaptorMod\cache\azrael-palette.pal',
    [double[]]$Fovs = @(40, 45, 50, 55, 60, 65, 70, 75, 80),
    # Wide enough that the peak is found, not clamped. A first run capped at 250 reported
    # -250 for three FOVs in a row, which is the search hitting its own limit rather than
    # a measurement -- a best shift equal to MaxShift means nothing except "look further".
    [int]$MaxShift = 460,
    [switch]$FlipV,
    [switch]$NoCull
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -Path (Join-Path $toolDir 'Align.cs') -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

. (Join-Path $toolDir 'LoadRoom.ps1')
$room = Import-AztRoom -RefName $Name -RefDir $RefDir -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette
$W = $room.W; $H = $room.H; $pal = $room.Pal
Write-Host ("{0}  {1}x{2}  {3:N0} triangles" -f ($room.Rooms -join '+'), $W, $H, ($room.T.Count/3))

# ---- the engine's profiles, from its own 8bpp frame --------------------------
$eng = [System.Drawing.Bitmap]::FromFile((Join-Path $RefDir ("{0}-engine.png" -f $Name)))
$rcE = New-Object System.Drawing.Rectangle -ArgumentList ([int]0),([int]0),([int]$W),([int]$H)
$bdE = $eng.LockBits($rcE, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
$engIdx = New-Object byte[] ($bdE.Stride * $H); $engStride = $bdE.Stride
[System.Runtime.InteropServices.Marshal]::Copy($bdE.Scan0, $engIdx, 0, $engIdx.Length)
$eng.UnlockBits($bdE); $eng.Dispose()

# Profiles are built from the PALETTE INDEX, not luminance: index 0 is the engine's
# undrawn background, which is exactly the "is there geometry here" question being asked.
function Profiles([byte[]]$idx, [int]$stride) {
    $row = $null; $col = $null; $lit = 0
    [AztTool.Align]::IndexProfiles($idx, $stride, $W, $H, [ref]$row, [ref]$col, [ref]$lit)
    return [pscustomobject]@{ Row = $row; Col = $col; Lit = $lit }
}
$eP = Profiles $engIdx $engStride
Write-Host ("engine coverage {0:P1}" -f ($eP.Lit/[double]($W*$H)))
Write-Host ''

$r = New-Object AztTool.Raster($W, $H)
$r.NearZ = [single]0.5
$m = New-Object single[] 16
for ($i = 0; $i -lt 16; $i++) { $m[$i] = [single]$room.Cam[$i] }

# MASK OVERLAP, which a profile correlation cannot give. A corridor's row profile is
# smooth, so cross-correlation sits near 0.6 at many different shifts and the "best" one
# jumps around -- it cannot tell a misaimed view from one that simply draws more.
# Comparing the drawn masks per pixel settles it:
#   recall = how much of what the ENGINE draws the host also draws
#   prec   = how much of what the HOST draws the engine also draws
# recall near 1 with low precision means the host is a SUPERSET -- aimed correctly, just
# drawing things the engine culls. Low recall means genuinely misaimed geometry.
function MaskOverlap([byte[]]$e, [int]$es, [byte[]]$hb, [int]$hs) {
    $inter = 0; $eOnly = 0; $hOnly = 0
    [AztTool.Align]::Overlap($e, $es, $hb, $hs, $W, $H, [ref]$inter, [ref]$eOnly, [ref]$hOnly)
    return [pscustomobject]@{ Inter=$inter; EngineOnly=$eOnly; HostOnly=$hOnly
        Recall=$(if (($inter+$eOnly) -gt 0) { $inter/[double]($inter+$eOnly) } else { 0 })
        Prec  =$(if (($inter+$hOnly) -gt 0) { $inter/[double]($inter+$hOnly) } else { 0 }) }
}

Write-Host ("{0,6} {1,9} {2,9} {3,9} {4,10} {5,10}" -f 'fov','recall','precision','coverage','rowShift','colShift')
$best = $null
foreach ($fov in $Fovs) {
    $r.SetVerticalFov($fov)
    $r.SetCameraWorld($m); $r.Clear([byte]0)
    $r.DrawTextured($room.V, $room.UV, $room.T, $room.TexIdx, $room.Texes, (-not $NoCull), (-not $FlipV))
    $hP = Profiles $r.Color $W
    $ov = MaskOverlap $engIdx $engStride $r.Color $W
    $dy=0; $sy=0.0; [AztTool.Align]::BestShift($eP.Row, $hP.Row, $MaxShift, [ref]$dy, [ref]$sy)
    $dx=0; $sx=0.0; [AztTool.Align]::BestShift($eP.Col, $hP.Col, $MaxShift, [ref]$dx, [ref]$sx)
    $cov = $hP.Lit/[double]($W*$H)
    Write-Host ("{0,6:N0} {1,9:P1} {2,9:P1} {3,9:P1} {4,10} {5,10}" -f $fov, $ov.Recall, $ov.Prec, $cov, $dy, $dx)
    if (-not $best -or $ov.Recall -gt $best.Recall) {
        $best = [pscustomobject]@{ Fov=$fov; Recall=$ov.Recall; Prec=$ov.Prec; Cov=$cov; EngineOnly=$ov.EngineOnly }
    }
}
Write-Host ''
Write-Host ("BEST fov {0}: recall {1:P1}, precision {2:P1}, coverage {3:P1} vs engine {4:P1}" -f `
    $best.Fov, $best.Recall, $best.Prec, $best.Cov, ($eP.Lit/[double]($W*$H))) -ForegroundColor Cyan
if ($best.Recall -ge 0.90) {
    Write-Host 'GEOMETRY IS ALIGNED -- the host draws nearly everything the engine does, plus more.' -ForegroundColor Green
    Write-Host 'The difference is what the engine CULLS, not where it points. Tune draw distance, not the camera.' -ForegroundColor Green
} else {
    Write-Host ("MISALIGNED: the engine draws {0:N0} pixels the host leaves black." -f $best.EngineOnly) -ForegroundColor Yellow
    Write-Host 'Fix the projection or camera matrix before tuning anything tonal.' -ForegroundColor Yellow
}

