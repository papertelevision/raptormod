# Test-GpuLook.ps1 -- a frame through the graphics card's whole picture, without a game, to a PNG:
# lamp + its shadow, the room's torches + theirs, fog, dust, relief, water, particles (after a few
# simulated seconds, walking forward), corner darkening, ground mist and the visible beam.
# For setting strengths sensibly before they are judged in game; also times each frame.
#
#   .\tools\Test-GpuLook.ps1 -Room WASHCORI
#   .\tools\Test-GpuLook.ps1 -Room CORICORI -Yaw 140 -Pitch -10 -Off        (-Off: the new effects off, to compare)
param(
    [string]$Room = 'CORICORI', [double]$X = [double]::NaN, [double]$Y = [double]::NaN, [double]$Z = [double]::NaN,
    [double]$Yaw = 135, [double]$Pitch = -12, [int]$Width = 2562, [int]$Height = 1238,
    [double]$Relief = 1.0, [double]$AO = 0.6, [double]$Beam = 1.0, [switch]$Off, [switch]$LampOff, [switch]$MistOff, [switch]$NoParts, [double]$Seconds = 3, [double]$Walk = 70,
    [string]$Out = '', [string]$MistColor = '', [double]$MistDensity = -1, [double]$MistHeight = -1, [double]$MistMax = -1, [double]$BeamHaze = -1, [double]$BeamOuter = -1, [double]$BeamInner = -1, [double[]]$BeamOrg = $null, [switch]$NoLampShadow, [double]$BeamMax = -1, [double]$BeamFall = -1,
    [switch]$ReliefSharp, [double]$ReliefSharpK = -1, [double]$ReliefMid = -1, [double]$ReliefTile = -1,     # the SHARP (full-size) relief maps: steepness, broad share, scale
    [switch]$NoPixelMip, [double]$GpuMipBias = 0, [double]$Anisotropy = 8, [switch]$NoDustMotes, [switch]$NoTorches, [double]$NormMipBias = -9, [double]$ReliefGain = -1, [double]$Detail = 0, [double]$DetailScale = -1, [double]$DetailAO = -1, [double]$DetailRough = -1, [double]$ReliefTint = -1, [double]$ReliefOpacity = -1, [double]$Flash = 0, [double]$FlashRange = 420, [double[]]$PlayerShadow = $null, [double]$PlayerYaw = 0, [switch]$Steady, [double]$LightShadowDeep = 0.35, [switch]$OldLightView, [switch]$BlackView, [double]$LightSoft = 4, [double]$LampSoft = 3, [switch]$NoVolume, [switch]$PresentTest, [switch]$VolFull, [string]$PaintMap = '', [switch]$NoPaint, [switch]$NoGi, [double]$GiStrength = -1, [double]$GiAmbient = -1, [double]$VolLit = -1, [double]$VolLitAir = -1, [switch]$NoArtLight                                    # mipmaps per pixel (or per triangle), bias, anisotropy
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolDir 'GuestBase.ps1'); . (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'GpuRaster.cs'), (Join-Path $toolDir 'GiBake.cs'), (Join-Path $toolDir 'Overlay.cs'), (Join-Path $toolDir 'Motes.cs'), (Join-Path $toolDir 'Particles.cs'), (Join-Path $toolDir 'ScanWire.cs'), (Join-Path $toolDir 'BootHd.cs'), (Join-Path $toolDir 'Panel.cs'), (Join-Path $toolDir 'Pointer.cs'), (Join-Path $toolDir 'Keys.cs')) -ReferencedAssemblies 'System.Drawing', 'System.Web.Extensions'
Add-Type -AssemblyName System.Drawing
$wp = Join-Path $toolDir 'Watch-HostRender.ps1'; $tk = $null; $pe = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($wp, [ref]$tk, [ref]$pe)
foreach ($fn in 'ConvertTo-Rgb24', 'Get-RoomAtmosphere', 'Set-RoomAtmosphere', 'Update-RoomLights', 'Get-CharacterSig', 'Get-Room', 'Set-GpuAtmosphere', 'Set-GpuGi', 'Complete-GpuGi', 'Set-RoomTextureRules') { $fd = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true); if ($fd) { . ([scriptblock]::Create($fd.Extent.Text)) } }
function Say([string]$m, [string]$c = 'Gray') { }
$RoomsDir = 'C:\Games\azrael-render\rooms'; $LampRoomOff = 0.82; $NoFog = $false; $NoDust = [bool]$NoDustMotes; $NoLights = [bool]$NoTorches; $NoMist = $false; $NoParticles = $false; $script:giBake = $null; $script:giSync = $true      # (bounced light: worked out here and now, or read from its cache)
$CacheDir = 'C:\Games\azrael-render'; $TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX'; $Palette = 'C:\Games\azrael-inject\azrael-palette.pal'
$W = 1600; $H = 928; $CacheRooms = 8; $TrueColour = $true; $NoRgb = $false; $TexOverrideDir = 'C:\Games\azrael-textures\hires'; $TexScale = 1; $NoReflections = $false
$roomCache = New-Object System.Collections.Specialized.OrderedDictionary
$pal = [IO.File]::ReadAllBytes($Palette); $script:rgbLut = [AztTool.Raster]::BuildRgbLut($pal)
$theRoom = Get-Room @($Room)      # (not $room: that IS $Room, the [string] parameter)

$r = New-Object AztTool.Raster($Width, $Height); $r.NearZ = [single]0.5; $r.SetVerticalFov(50); $r.EnableRgb()
$r.SetLightTable([AztTool.Raster]::BuildLightTable($pal, 76, [single]2.4), 76, [single]2.4)
$r.LampHalo = [single]0.495; $r.LampHaloInnerDeg = [single]10; $r.LampHaloDeg = [single]24; $r.LampRange = [single]550; $r.LampInnerDeg = [single]8.64; $r.LampOuterDeg = [single]21
$r.ShadowDark = [single]0.38; $r.ShadowNear = [single]140; $r.ShadowFar = [single]900; $r.ShadowSoft = [single]1.0; $r.Lamp = $true
if ($LampOff) { $r.LampRoom = [single]0.82; $r.LampPower = [single]0 } else { $r.LampRoom = [single]0.54; $r.LampPower = [single]1.68 }
$script:motes = $null; $script:roomLights = @(); $script:atmClock = [Diagnostics.Stopwatch]::StartNew()
$e = $null; $gpu = [AztTool.GpuRaster]::Create($Width, $Height, [ref]$e); if (-not $gpu) { throw $e }; if ($VolFull) { $gpu.VolHalf = $false }
$gpu.NearZ = [single]0.5; $gpu.SetVerticalFov(50); $gpu.BlackView = [bool]$BlackView; $gpu.LightSoft = [single]$LightSoft; $gpu.LampSoft = [single]$LampSoft; $gpu.LightShadowDeep = [single]$LightShadowDeep
$gpu.ReliefSharpBuild = [bool]$ReliefSharp; $gpu.ReliefSharp = [bool]$ReliefSharp; if ($ReliefSharpK -ge 0) { $gpu.ReliefSharpK = [single]$ReliefSharpK }; if ($ReliefMid -ge 0) { $gpu.ReliefMid = [single]$ReliefMid }; if ($ReliefTile -gt 0) { $gpu.ReliefTile = [single]$ReliefTile }
$gpu.PixelMip = -not $NoPixelMip; $gpu.PixelMipBias = [single]$GpuMipBias; $gpu.Anisotropy = [single]$Anisotropy; if ($NormMipBias -gt -9) { $gpu.NormMipBias = [single]$NormMipBias }; if ($ReliefGain -gt 0) { $gpu.ReliefGain = [single]$ReliefGain }; $gpu.Detail = [single]$Detail; if ($DetailScale -gt 0) { $gpu.DetailScale = [single]$DetailScale }; if ($DetailAO -ge 0) { $gpu.DetailAO = [single]$DetailAO }; if ($DetailRough -ge 0) { $gpu.DetailRough = [single]$DetailRough }; if ($ReliefTint -ge 0) { $gpu.ReliefTint = [single]$ReliefTint }; if ($ReliefOpacity -ge 0) { $gpu.ReliefOpacity = [single]$ReliefOpacity }
$atm = Get-RoomAtmosphere @($Room); Set-RoomAtmosphere $r $atm $theRoom; if ($Steady) { foreach ($l in $script:roomLights) { $l.Flicker = 0 } }      # (-Steady: no torch flicker, so two renders compare)
if (Get-Command Set-GpuAtmosphere -ErrorAction SilentlyContinue) { Set-GpuAtmosphere $gpu $atm $theRoom }; if ($PaintMap) { $gpu.SavePaintField($PaintMap); "  painted darkness: " + $gpu.PaintNote }; if ($NoPaint) { $gpu.PaintOn = $false }; if ($gpu.ArtOn) { "  light from the artwork: {0}; room tint #{1:X6}" -f $gpu.ArtNote, $gpu.RoomTint }
if ($VolLit -ge 0) { $gpu.VolLit = [single]$VolLit }; if ($VolLitAir -ge 0) { $gpu.VolLitAir = [single]$VolLitAir }
if ($GiStrength -ge 0) { $gpu.GiStrength = [single]$GiStrength }; if ($GiAmbient -ge 0) { $gpu.GiAmbient = [single]$GiAmbient }; if ($gpu.GiOn) { "  bounced light: {0}; strength {1}, room level x{2}" -f $gpu.GiNote, $gpu.GiStrength, $gpu.GiAmbient }
if ($null -ne $script:volLevel) { $r.LampRoom = [single]$script:volLevel }      # (a volumetric-fog room: the level is held, flashlight or not)
# (trying mist settings before they go in the room files)
if ($MistColor) { $gpu.MistColor = ConvertTo-Rgb24 $MistColor 0x2A241E }
if ($MistDensity -ge 0) { $gpu.MistDensity = [single]$MistDensity }; if ($MistHeight -gt 0) { $gpu.MistHeight = [single]$MistHeight }; if ($MistMax -ge 0) { $gpu.MistMax = [single]$MistMax }
if ($BeamHaze -ge 0) { $gpu.BeamHaze = [single]$BeamHaze }; if ($BeamOuter -gt 0) { $gpu.BeamOuterDeg = [single]$BeamOuter }; if ($BeamInner -gt 0) { $gpu.BeamInnerDeg = [single]$BeamInner }
if ($BeamMax -ge 0) { $gpu.BeamMax = [single]$BeamMax }; if ($BeamFall -gt 0) { $gpu.BeamFalloff = [single]$BeamFall }
if ($BeamOrg) { $gpu.BeamOrgX = [single]$BeamOrg[0]; $gpu.BeamOrgY = [single]$BeamOrg[1]; $gpu.BeamOrgZ = [single]$BeamOrg[2] }
$gpu.Relief = [single]$(if ($Off) { 0 } else { $Relief }); $gpu.AO = [single]$(if ($Off) { 0 } else { $AO }); $gpu.Beam = [single]$(if ($Off) { 0 } else { $Beam })
if ($Off -or $MistOff) { $gpu.MistOn = $false }; $roomMist = $gpu.MistOn

# where to stand: given, or over the room's middle at eye height above its floor
if ([double]::IsNaN($X)) {
    $v = $theRoom.V; $n = $v.Length / 3; $sx = 0.0; $sz = 0.0; for ($i = 0; $i -lt $n; $i++) { $sx += $v[$i * 3]; $sz += $v[$i * 3 + 2] }
    $X = $sx / $n; $Z = $sz / $n
    if ($Room -eq 'CORICORI') { $X = -101.8; $Z = 113.3 }
}
if ([double]::IsNaN($Y)) {
    $dn = [AztTool.Raster]::RayDistance($theRoom.V, $theRoom.T, $theRoom.TexIdx, [single]$X, [single]200, [single]$Z, 0, -1, 0, 2000)
    $Y = $(if ($dn -lt 2000) { 200 - $dn + 48 } else { 49.5 })
}
function Cam([double]$x, [double]$y, [double]$z) {
    $a = $Yaw * [Math]::PI / 180; $pt = [Math]::Tan($Pitch * [Math]::PI / 180) * 100
    $r.LookAt([single]$x, [single]$y, [single]$z, [single]($x + [Math]::Sin($a) * 100), [single]($y + $pt), [single]($z + [Math]::Cos($a) * 100), 1)
    $b = $r.LastBasis; return ,([single[]]@($b[0], $b[1], $b[2], 0, $b[3], $b[4], $b[5], 0, $b[6], $b[7], $b[8], 0, $x, $y, $z, 1))
}
# a fake screen of only the key colour (no HUD drawings), for the compose
$screen = New-Object int[] (1600 * 928); for ($i = 0; $i -lt $screen.Length; $i++) { $screen[$i] = 0x101010 }
$o = New-Object AztTool.Overlay($PID, 1600, 928, 1600, 1200, 0, 49); $o.Wide = $true
$cxi = $null; $cxf = $null; $cxiR = $null; $cxfR = $null; $riy = $null; $rwy = $null; $bt = 0; $bb = 0; $vis = $false
$o.ComposeMap($Width, $Height, [ref]$cxi, [ref]$cxf, [ref]$cxiR, [ref]$cxfR, [ref]$riy, [ref]$rwy, [ref]$bt, [ref]$bb, [ref]$vis)
$shadowW = [int]([Math]::Round(512 * $Width / [double]$Height / 4) * 4)
$rs = New-Object AztTool.Raster($shadowW, 512); $rs.NearZ = [single]0.5; $rs.SetVerticalFov(58)
$lampM = New-Object single[] 16; $moteBuf = New-Object single[] 6000; $partBuf = New-Object single[] 20000
$fin = New-Object int[] ($Width * $Height); $times = @(); $gpuOnly = @()
try {
    # -Seconds of simulated time, walking forward 70 units a second toward the view
    $a = $Yaw * [Math]::PI / 180; $frames = [int]($Seconds * 30)
    for ($f = 0; $f -lt $frames; $f++) {
        $back = ($frames - 1 - $f) * $Walk / 30.0
        $cam = Cam ($X - [Math]::Sin($a) * $back) $Y ($Z - [Math]::Cos($a) * $back)
        $r.SetCameraWorld($cam); Update-RoomLights $r
        $gpu.Time = [single]($f / 30.0)
        if ($script:fx) { $script:fx.Update([single](1 / 30.0), $cam[12], $cam[13], $cam[14], $theRoom.V, $theRoom.T, $theRoom.TexIdx); $gpu.MistFloorY = [single]$script:fx.FloorY; if (-not $dropBuf) { $dropBuf = New-Object single[] 64 }; $gpu.SetDrops($dropBuf, $script:fx.GatherDrops($dropBuf)) }
        if ($script:motes) { $script:motes.Update([single](1 / 30.0), $cam[12], $cam[13], $cam[14]); $script:motes.LampLevel = [single]$(if ($LampOff) { 0 } else { 1 }) }
        if ($f -lt $frames - 12) { continue }
        $t = [Diagnostics.Stopwatch]::StartNew()
        [Array]::Copy($cam, $lampM, 16); for ($k = 0; $k -lt 3; $k++) { $lampM[12 + $k] = [single]($cam[12 + $k] + $cam[$k] * 24 + $cam[4 + $k] * 8) }
        $gpu.Flash = [single]$Flash; $gpu.FlashRange = [single]$FlashRange     # (a muzzle flash: the lamp's shadow view is drawn for it too)
        if ((-not $LampOff -or $Flash -gt 0) -and -not $NoLampShadow) { $gpu.SetLampShadow(0, $lampM, $rs.W, $rs.H, $rs.FocalPixels, [single]24, [single]8) }
        for ($li = 0; $li -lt $script:roomLights.Count; $li++) {
            $lz = $script:lightRs[$li]; if (-not $lz) { continue }
            $l = $script:roomLights[$li]; $d = $l.Dir
            $dlx = [single]($l.X + $l.Jx); $dly = [single]($l.Y + $l.Jy); $dlz = [single]($l.Z + $l.Jz)      # (where it is this frame: it dances, as in the watcher)
            $upAx = $(if ([Math]::Abs($d[1]) -gt 0.9) { 0 } else { 1 })     # (a light facing straight up or down: lean on x instead, as the watcher does)
            $lz.LookAt($dlx, $dly, $dlz, [single]($dlx + $d[0] * 100), [single]($dly + $d[1] * 100), [single]($dlz + $d[2] * 100), $upAx)
            if ($OldLightView) { $gpu.SetLightShadow($li, $dlx, $dly, $dlz, $lz.LastBasis, $lz.W, $lz.FocalPixels) } else { $gpu.SetLightCube($li, $dlx, $dly, $dlz, 768) }
        }
        # -PlayerShadow x,z: the player's raptor body stood there (eye at the room's eye height above the floor), facing
        # -PlayerYaw degrees, cast only into the placed lights' views -- as the watcher does from the camera
        if ($PlayerShadow) {
            if (-not $script:bodyW) {
                $script:bodyW = New-Object AztTool.ScanWire
                if (-not $script:bodyW.AddBody('PLAYER', (Join-Path $TexDir 'RAPTOR.XAF'), 124, 136, 143, 147)) { throw $script:bodyW.LastError }
                $script:bodyB = New-Object single[] ($script:bodyW.BodyTriCount('PLAYER') * 9)
            }
            $px = $PlayerShadow[0]; $pz = $PlayerShadow[1]
            $py0 = $(if ($script:roomLights.Count) { $script:roomLights[0].Y + 10 } else { 200 })      # (from 200 the ray can meet a ceiling)
            $pd = [AztTool.Raster]::RayDistance($theRoom.V, $theRoom.T, $theRoom.TexIdx, [single]$px, [single]$py0, [single]$pz, 0, -1, 0, 2000)
            $py = $py0 - $pd + 48; $ya = $PlayerYaw * [Math]::PI / 180; $script:playerFloor = $py0 - $pd; if (-not $script:saidFloor) { $script:saidFloor = 1; "  player: floor {0:N1} under {1:N0},{2:N0}; body eye at {3:N1}" -f $script:playerFloor, $px, $pz, $py | Write-Host }
            $pm = [single[]]@(0, 0, 0, 0, 0, 1, 0, 0, [Math]::Sin($ya), 0, [Math]::Cos($ya), 0, $px, $py, $pz, 1)
            $bn = $script:bodyW.StepBody('PLAYER', $pm, 48, (1 / 30.0), $script:bodyB)
            $gpu.SetCasters($script:bodyB, $bn)
        }
        foreach ($grp in @($theRoom.WaterGroups)) { if (-not $grp) { continue }; $tl = New-Object 'System.Collections.Generic.List[int]'; $ys = 0.0; $yn = 0; foreach ($wt in $grp.Parts) { $wy = $theRoom.V[$wt.VFirst * 3 + 1]; if ($cam[13] -le $wy + 1) { continue }; $tl.AddRange([int[]]$wt.TriVerts); $ys += $wy; $yn++ }; if ($yn) { $gpu.AddWater($tl.ToArray(), [single]($ys / $yn)) } }
        if ($script:motes) { $nm = $script:motes.Gather($r, $moteBuf); $gpu.SetMotes($moteBuf, $nm, $script:motes.Color, $script:motes.ColorDark) }
        if ($script:fx -and -not $Off -and -not $NoParts) { $np = $script:fx.Gather($r, $partBuf); $gpu.SetParticles($partBuf, $np) }
        $gpu.SetCameraWorld($cam); $gpu.CopyLighting($r)
        $gpu.Draw($theRoom.V, $theRoom.UV, $theRoom.T, $theRoom.TexIdx, $theRoom.Texes, $true, $true)
        $gpu.SetComposeMap($cxi, $cxf, $cxiR, $cxfR, $riy, $rwy)
        $gpu.PostCompose([single]0, $screen, 1600, 1600, 928, 0x101010, $bt, $bb, $vis)
        $gpu.ReadComposed($fin)
        $times += $t.Elapsed.TotalMilliseconds; $gpuOnly += $gpu.LastDrawMs; $casters = $gpu.LastCasters
    }
    if ($script:fx -and $np) {
        # what the steam is, as handed to the card (stride 10: x y z size r g b a additive seed; steam's seed is 1+)
        $sn = 0; $sy = 0.0; $sc = 0.0; $sa = 0.0; $ss = 0.0
        for ($q = 0; $q -lt $np; $q++) { $o10 = $q * 10; if ($partBuf[$o10 + 9] -ge 1) { $sn++; $sy += $partBuf[$o10 + 1]; $sc += $partBuf[$o10 + 4]; $sa += $partBuf[$o10 + 7]; $ss += $partBuf[$o10 + 3] } }
        if ($sn) { "  steam: {0} puffs (of {1} particles alive); mean height {2:N0}, red {3:N0}, alpha {4:N3}, size {5:N0}" -f $sn, $script:fx.Count, ($sy / $sn), ($sc / $sn), ($sa / $sn), ($ss / $sn) } else { "  steam: none gathered ({0} particles alive)" -f $script:fx.Count }
    }
    # how steep the relief maps came out, per texture (mean and 90th percentile of the slope), old and sharp
    $st = @(); foreach ($tx in $theRoom.Texes) { $a = $gpu.ReliefStats($tx, $false); $b = $gpu.ReliefStats($tx, $true); if ($a) { $st += ,@($a[0], $a[1], $(if ($b) { $b[0] } else { 0 }), $(if ($b) { $b[1] } else { 0 }), $a[2], $(if ($b) { $b[2] } else { 0 })) } }
    if ($st.Count) { "  relief slope over {0} textures -- old (half size, ~{1:N0} px): mean {2:N3} p90 {3:N3}; sharp (~{4:N0} px): mean {5:N3} p90 {6:N3}; {7} sharp maps, {8:N0} MB" -f $st.Count, (($st | ForEach-Object { $_[4] } | Measure-Object -Average).Average), (($st | ForEach-Object { $_[0] } | Measure-Object -Average).Average), (($st | ForEach-Object { $_[1] } | Measure-Object -Average).Average), (($st | ForEach-Object { $_[5] } | Measure-Object -Average).Average), (($st | ForEach-Object { $_[2] } | Measure-Object -Average).Average), (($st | ForEach-Object { $_[3] } | Measure-Object -Average).Average), $gpu.SharpMaps, ($gpu.SharpBytes / 1MB) }
    $partsShown = $gpu.LastParticles; $realFrame = [int[]]$fin.Clone()     # (the timing re-draws below have no particles or dust left: save THIS frame)
    $tc = [Diagnostics.Stopwatch]::StartNew(); $gpu.Draw($theRoom.V, $theRoom.UV, $theRoom.T, $theRoom.TexIdx, $theRoom.Texes, $true, $true); $gpu.SetComposeMap($cxi, $cxf, $cxiR, $cxfR, $riy, $rwy); $gpu.PostCompose([single]0, $screen, 1600, 1600, 928, 0x101010, $bt, $bb, $vis); $gpu.ReadComposed($fin); $script:cardMs = $tc.Elapsed.TotalMilliseconds
    $tc.Restart(); $gpu.Relief = 0; $gpu.AO = 0; $gpu.Beam = 0; $gpu.MistOn = $false; $gpu.Draw($theRoom.V, $theRoom.UV, $theRoom.T, $theRoom.TexIdx, $theRoom.Texes, $true, $true); $gpu.PostCompose([single]0, $screen, 1600, 1600, 928, 0x101010, $bt, $bb, $vis); $gpu.ReadComposed($fin); "  the same frame with relief, corners, mist and beam off: {0:N1} ms" -f $tc.Elapsed.TotalMilliseconds
    $gpu.Relief = [single]$(if ($Off) { 0 } else { $Relief }); $gpu.AO = [single]$(if ($Off) { 0 } else { $AO }); $gpu.Beam = [single]$(if ($Off) { 0 } else { $Beam }); $gpu.MistOn = $roomMist
    $gpu.Draw($theRoom.V, $theRoom.UV, $theRoom.T, $theRoom.TexIdx, $theRoom.Texes, $true, $true); $gpu.PostCompose([single]0, $screen, 1600, 1600, 928, 0x101010, $bt, $bb, $vis); $gpu.ReadComposed($fin)
    if ($PresentTest) {
        # THE CARD'S OWN WINDOW (2026-10-08): this frame shown by GpuRaster.PresentGpu in the overlay's card window at
        # 1.2x (as a 5.5 M picture on a 4K screen), captured off the screen and compared with the same frame read back
        # and stretched by a reference bicubic; then the old path's processor cost for the same window
        Add-Type -AssemblyName System.Windows.Forms
        $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $k = [Math]::Min(1.2, [Math]::Min(($sb.Width - 120) / $Width, ($sb.Height - 120) / $Height))
        $ww = [int]($Width * $k); $wh = [int]($Height * $k)
        $po = New-Object AztTool.Overlay($PID, 1600, 928, 1600, 1200, 0, 49)
        $po.FixX = 60; $po.FixY = 60; $po.FixW = $ww; $po.FixH = $wh; $po.IgnoreForeground = $true; $po.StaleMs = 5000
        try {
            if (-not $po.Start()) { throw "overlay: $($po.StartError)" }
            if (-not $gpu.AttachPresent($po.GlWindow)) { throw "attach: $($gpu.PresentError)" }
            $po.GlPresent = $true
            $pt = @(); for ($q = 0; $q -lt 40; $q++) { if ($gpu.PresentGpu()) { $po.NoteGlFrame(); $pt += $gpu.LastPresentMs }; Start-Sleep -Milliseconds 20 }
            Start-Sleep -Milliseconds 400
            $cap = New-Object System.Drawing.Bitmap $ww, $wh; $cg = [System.Drawing.Graphics]::FromImage($cap); $cg.CopyFromScreen(60, 60, 0, 0, (New-Object System.Drawing.Size $ww, $wh)); $cg.Dispose()
            $src = New-Object System.Drawing.Bitmap -ArgumentList $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
            $bd = $src.LockBits((New-Object System.Drawing.Rectangle 0, 0, $Width, $Height), [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppRgb); [Runtime.InteropServices.Marshal]::Copy($fin, 0, $bd.Scan0, $fin.Length); $src.UnlockBits($bd)
            $ref = New-Object System.Drawing.Bitmap $ww, $wh; $rg = [System.Drawing.Graphics]::FromImage($ref); $rg.InterpolationMode = 'HighQualityBicubic'; $rg.PixelOffsetMode = 'HighQuality'; $rg.DrawImage($src, 0, 0, $ww, $wh); $rg.Dispose()
            $d = 0.0; $big = 0; $n = 0
            for ($sy = 8; $sy -lt $wh - 8; $sy += 7) { for ($sx = 8; $sx -lt $ww - 8; $sx += 7) { $a = $cap.GetPixel($sx, $sy); $b = $ref.GetPixel($sx, $sy); $e = ([Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B)) / 3.0; $d += $e; if ($e -gt 24) { $big++ }; $n++ } }
            $cap.Save(($Out -replace '\.png$', '-present.png')); $ref.Save(($Out -replace '\.png$', '-presentref.png'))
            "  PRESENT TEST: {0}x{1} picture into a {2}x{3} window: {4} pictures shown, {5:N2} ms each on this thread (median); on screen vs a bicubic stretch: mean difference {6:N2}/255, {7:P1} of samples off by more than 24" -f $Width, $Height, $ww, $wh, $pt.Count, (@($pt | Sort-Object)[[int]($pt.Count / 2)]), ($d / $n), ($big / $n)
            # the visor's shading: a band of full coverage toward pure red across the top 40 picture rows
            $cov = New-Object byte[] ($Width * 40); for ($q = 0; $q -lt $cov.Length; $q++) { $cov[$q] = 255 }
            $gpu.SetPresentShade($cov, $Width, 40, 0xFF0000); [void]$gpu.PresentGpu(); $po.NoteGlFrame(); Start-Sleep -Milliseconds 300
            $c2 = New-Object System.Drawing.Bitmap 1, 1; $g2 = [System.Drawing.Graphics]::FromImage($c2); $g2.CopyFromScreen((60 + [int]($ww / 2)), (60 + [int](20 * $k)), 0, 0, (New-Object System.Drawing.Size 1, 1)); $g2.Dispose()
            "  PRESENT TEST: visor shading band (should be red): {0}" -f $c2.GetPixel(0, 0); $c2.Dispose(); $gpu.SetPresentShade($null, 0, 0, 0)
            # the old way, for the same window: read back, stretch on the processor (the GDI copy not counted)
            $dst = New-Object int[] ($ww * $wh); $xi = $null; $xf = $null; $rb = @(); $sc = @()
            for ($q = 0; $q -lt 8; $q++) { $tq = [Diagnostics.Stopwatch]::StartNew(); $gpu.ReadComposed($fin); $rb += $tq.Elapsed.TotalMilliseconds; $tq.Restart(); [AztTool.Overlay]::Scale($fin, $Width, $Height, $dst, $ww, $wh, [ref]$xi, [ref]$xf); $sc += $tq.Elapsed.TotalMilliseconds }
            "  OLD PATH for comparison: read-back {0:N2} ms + processor stretch {1:N2} ms (+ the GDI copy, not measured)" -f (@($rb | Sort-Object)[4]), (@($sc | Sort-Object)[4])
        } finally { $gpu.DetachPresent(); $po.Dispose() }
    }
    if (-not $Out) { $Out = Join-Path 'C:\Games\azrael-render\tc-test' ("look-{0}{1}.png" -f $Room, $(if ($Off) { '-off' } elseif ($LampOff) { '-lampoff' } else { '' })) }
    New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
    $bm = New-Object System.Drawing.Bitmap -ArgumentList $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
    $bd = $bm.LockBits((New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $Width, $Height), [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
    [Runtime.InteropServices.Marshal]::Copy($realFrame, 0, $bd.Scan0, $realFrame.Length); $bm.UnlockBits($bd); $bm.Save($Out); $bm.Dispose()
    "{0}: eye {1:N0} {2:N0} {3:N0}, looking {4} deg; {5} particles, {6} motes; mist {7} (floor at {8:N0}); whole frame here, steady state {9:N1} ms (the card's part, waited for: {10:N1} ms); saved {11}" -f $Room, $X, $Y, $Z, $Yaw, $partsShown, $gpu.LastMotes, $gpu.MistOn, $gpu.MistFloorY, (@($times | Sort-Object)[[int]($times.Count / 2)]), $script:cardMs, $Out
} finally { $gpu.Dispose(); $o.Dispose() }
