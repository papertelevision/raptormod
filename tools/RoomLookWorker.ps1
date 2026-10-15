# RoomLookWorker.ps1 -- ROOM REVIEW'S "GAME LOOK" (Josh, 2026-10-12: "Its much easier for me to see these effects in the room
# preview app we built so can we implement them there so there is more parity with the actual game?"): the true-colour
# renderer kept running for the viewer, frame by frame. The review server (Start-RoomReview.ps1) starts it the first time
# Game look is switched on, sends it the viewer's camera and switches, and passes the JPEG back. It renders exactly as
# Test-GpuLook does (the same room loading, settings, lights, shadows, fog, compose) -- one frame per request instead of a
# whole process (~10 s) per picture. Switches as the game's keys: wet (F5), shine (F6), relief + depth (F7), texture repair
# (F11), the flashlight. It listens on 127.0.0.1 only and quits when the server is gone or after -IdleMinutes unused.
#
#   (started by Start-RoomReview.ps1)  RoomLookWorker.ps1 -Port 8650 -ParentPid 1234
param(
    [int]$Port = 8650, [int]$ParentPid = 0, [double]$IdleMinutes = 20,
    [ValidateSet('Normal', 'Ultra')][string]$TextureQuality = 'Ultra',
    [string]$RoomsDir = 'C:\Games\azrael-render\rooms',
    [string]$TexOverrideDir = 'C:\Games\azrael-textures\hires'
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1'); . (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'GpuRaster.cs'), (Join-Path $toolDir 'GiBake.cs'), (Join-Path $toolDir 'Overlay.cs'), (Join-Path $toolDir 'Motes.cs'), (Join-Path $toolDir 'Particles.cs'), (Join-Path $toolDir 'ScanWire.cs'), (Join-Path $toolDir 'BootHd.cs'), (Join-Path $toolDir 'Panel.cs'), (Join-Path $toolDir 'Pointer.cs'), (Join-Path $toolDir 'Keys.cs')) -ReferencedAssemblies 'System.Drawing', 'System.Web.Extensions'
Add-Type -Path (Join-Path $toolDir 'RoomReviewHttp.cs')
Add-Type -AssemblyName System.Drawing
# the watcher's own room loading and settings (as Test-GpuLook)
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $toolDir 'Watch-HostRender.ps1'), [ref]$null, [ref]$null)
foreach ($fn in 'ConvertTo-Rgb24', 'Get-RoomAtmosphere', 'Set-RoomAtmosphere', 'Update-RoomLights', 'Get-CharacterSig', 'Get-Room', 'Set-GpuAtmosphere', 'Set-GpuGi', 'Complete-GpuGi', 'Set-RoomTextureRules', 'Set-GpuGhost', 'Set-RoomGhosts', 'Get-MaterialTable', 'Resolve-TexMaterial', 'Set-RoomMaterials', 'Set-GpuWet', 'Set-GpuRepair') {
    $fd = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true); if ($fd) { . ([scriptblock]::Create($fd.Extent.Text)) }
}
function Say([string]$m, [string]$c = 'Gray') { }
$LampRoomOff = 0.82; $NoFog = $false; $NoDust = $true; $NoLights = $false; $NoMist = $false; $NoParticles = $false; $script:giBake = $null; $script:giSync = $true
$NoShine = $false; $Shine = 1.0; $NoWet = $false; $NoRepair = $false; $NoParallax = $false; $ParallaxDepth = 1.0; $NoGhost = $false; $NoArtLight = $false; $NoVolume = $false; $NoFlipV = $false
$CacheDir = 'C:\Games\azrael-render'; $TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX'; $Palette = 'C:\Games\azrael-inject\azrael-palette.pal'
$W = 1600; $H = 928; $CacheRooms = 4; $TrueColour = $true; $NoRgb = $false; $TexScale = 1; $NoReflections = $false
$roomCache = New-Object System.Collections.Specialized.OrderedDictionary
$script:texMax = $(if ($TextureQuality -eq 'Normal') { 2048 } else { 0 })
$pal = [IO.File]::ReadAllBytes($Palette); $script:rgbLut = [AztTool.Raster]::BuildRgbLut($pal)
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---- the renderer at a size (made again when the viewer's size changes) ------------------------------------------------
$S = @{ W = 0; H = 0; R = $null; Gpu = $null; Rs = $null; Room = $null; Stamp = ''; TheRoom = $null; Atm = $null; Clock = [Diagnostics.Stopwatch]::StartNew(); Last = 0.0; Comp = $null }
function New-Renderer([int]$w, [int]$h) {
    if ($S.Gpu) { try { $S.Gpu.Dispose() } catch { } }; $S.Gpu = $null; $S.Room = $null
    $r = New-Object AztTool.Raster($w, $h); $r.NearZ = [single]0.5; $r.SetVerticalFov(50); $r.EnableRgb()
    $r.SetLightTable([AztTool.Raster]::BuildLightTable($pal, 76, [single]2.4), 76, [single]2.4)
    $r.LampHalo = [single]0.495; $r.LampHaloInnerDeg = [single]10; $r.LampHaloDeg = [single]24; $r.LampRange = [single]550; $r.LampInnerDeg = [single]8.64; $r.LampOuterDeg = [single]21
    $r.ShadowDark = [single]0.38; $r.ShadowNear = [single]140; $r.ShadowFar = [single]900; $r.ShadowSoft = [single]1.0; $r.Lamp = $true
    $e = $null; $g = [AztTool.GpuRaster]::Create($w, $h, [ref]$e); if (-not $g) { throw "graphics card: $e" }
    $g.NearZ = [single]0.5; $g.SetVerticalFov(50); $g.LightSoft = [single]4; $g.LampSoft = [single]3; $g.LightShadowDeep = [single]0.35
    $g.PixelMip = $true; $g.Anisotropy = [single]8; $g.Detail = [single]0
    $sw = [int]([Math]::Round(512 * $w / [double]$h / 4) * 4); $rs = New-Object AztTool.Raster($sw, 512); $rs.NearZ = [single]0.5; $rs.SetVerticalFov(58)
    # the compose (fog, beam, mist over the picture), as Test-GpuLook sets it up
    $o = New-Object AztTool.Overlay($PID, 1600, 928, 1600, 1200, 0, 49); $o.Wide = $true
    $cxi = $null; $cxf = $null; $cxiR = $null; $cxfR = $null; $riy = $null; $rwy = $null; $bt = 0; $bb = 0; $vis = $false
    $o.ComposeMap($w, $h, [ref]$cxi, [ref]$cxf, [ref]$cxiR, [ref]$cxfR, [ref]$riy, [ref]$rwy, [ref]$bt, [ref]$bb, [ref]$vis); $o.Dispose()
    $screen = New-Object int[] (1600 * 928); for ($i = 0; $i -lt $screen.Length; $i++) { $screen[$i] = 0x101010 }
    $S.W = $w; $S.H = $h; $S.R = $r; $S.Gpu = $g; $S.Rs = $rs
    $S.Comp = @{ Cxi = $cxi; Cxf = $cxf; CxiR = $cxiR; CxfR = $cxfR; Riy = $riy; Rwy = $rwy; Bt = $bt; Bb = $bb; Vis = $vis; Screen = $screen; Fin = (New-Object int[] ($w * $h)) }
}
# what the room's look depends on: its own file, the shared ones (a round of notes changes them while this runs)
function Get-RoomStamp([string]$room) {
    $p = @((Join-Path $RoomsDir "$room.json"), (Join-Path $RoomsDir '_defaults.json'), (Join-Path $RoomsDir '_materials.json'))
    return (($p | ForEach-Object { if (Test-Path -LiteralPath $_) { (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks } else { 0 } }) -join '/')
}
function Use-Room([string]$room) {
    $stamp = Get-RoomStamp $room
    if ($S.Room -eq $room -and $S.Stamp -eq $stamp) { return }
    $script:motes = $null; $script:roomLights = @(); $script:atmClock = [Diagnostics.Stopwatch]::StartNew(); $script:fx = $null; $script:volLevel = $null
    $S.TheRoom = Get-Room @($room)
    $S.Atm = Get-RoomAtmosphere @($room); Set-RoomAtmosphere $S.R $S.Atm $S.TheRoom
    foreach ($l in $script:roomLights) { $l.Flicker = 0 }      # (steady, as Render view: two frames compare)
    Set-GpuAtmosphere $S.Gpu $S.Atm $S.TheRoom
    $S.Room = $room; $S.Stamp = $stamp; $S.Last = $S.Clock.Elapsed.TotalSeconds
}
function Get-Cam([double]$x, [double]$y, [double]$z, [double]$yaw, [double]$pitch) {
    $a = $yaw * [Math]::PI / 180; $pt = [Math]::Tan($pitch * [Math]::PI / 180) * 100
    $S.R.LookAt([single]$x, [single]$y, [single]$z, [single]($x + [Math]::Sin($a) * 100), [single]($y + $pt), [single]($z + [Math]::Cos($a) * 100), 1)
    $b = $S.R.LastBasis; return , ([single[]]@($b[0], $b[1], $b[2], 0, $b[3], $b[4], $b[5], 0, $b[6], $b[7], $b[8], 0, $x, $y, $z, 1))
}
# one frame, as Test-GpuLook's (lamp shadow, the placed lights' cube shadows, water, particles, compose)
function Invoke-Frame($q) {
    $r = $S.R; $gpu = $S.Gpu; $theRoom = $S.TheRoom
    $gpu.WetOn = [bool]$q.wet; $gpu.ShineOn = [bool]$q.shine; $gpu.ReliefOn = [bool]$q.relief; $gpu.RelayOn = [bool]$q.repair
    $lamp = [bool]$q.lamp
    if ($lamp) { $r.LampRoom = [single]0.54; $r.LampPower = [single]1.68 } else { $r.LampRoom = [single]0.82; $r.LampPower = [single]0 }
    if ($null -ne $script:volLevel) { $r.LampRoom = [single]$script:volLevel }      # (a volumetric-fog room holds its level)
    # the viewer's own angle (viewer.js GAME_FOV, the game's field of view), so its pins sit on this picture
    $fv = $(if ($q.fov) { [Math]::Max(30.0, [Math]::Min(100.0, [double]$q.fov)) } else { 60.0 })
    $r.SetVerticalFov($fv); $gpu.SetVerticalFov($fv); if ($S.Rs) { $S.Rs.SetVerticalFov($fv + 8) }
    $cam = Get-Cam ([double]$q.X) ([double]$q.Y) ([double]$q.Z) ([double]$q.Yaw) ([double]$q.Pitch)
    $r.SetCameraWorld($cam); Update-RoomLights $r
    $now = $S.Clock.Elapsed.TotalSeconds; $dt = [single][Math]::Min(0.1, [Math]::Max(0.0, $now - $S.Last)); $S.Last = $now
    $gpu.Time = [single]$now
    if ($script:fx) { $script:fx.Update($dt, $cam[12], $cam[13], $cam[14], $theRoom.V, $theRoom.T, $theRoom.TexIdx); $gpu.MistFloorY = [single]$script:fx.FloorY; if (-not $script:dropBuf) { $script:dropBuf = New-Object single[] 64 }; $gpu.SetDrops($script:dropBuf, $script:fx.GatherDrops($script:dropBuf)) }
    $lampM = New-Object single[] 16; [Array]::Copy($cam, $lampM, 16); for ($k = 0; $k -lt 3; $k++) { $lampM[12 + $k] = [single]($cam[12 + $k] + $cam[$k] * 24 + $cam[4 + $k] * 8) }
    $gpu.Flash = [single]0
    if ($lamp) { $gpu.SetLampShadow(0, $lampM, $S.Rs.W, $S.Rs.H, $S.Rs.FocalPixels, [single]24, [single]8) }
    for ($li = 0; $li -lt $script:roomLights.Count; $li++) {
        $lz = $script:lightRs[$li]; if (-not $lz) { continue }
        $l = $script:roomLights[$li]; $d = $l.Dir
        $dlx = [single]($l.X + $l.Jx); $dly = [single]($l.Y + $l.Jy); $dlz = [single]($l.Z + $l.Jz)
        $upAx = $(if ([Math]::Abs($d[1]) -gt 0.9) { 0 } else { 1 })
        $lz.LookAt($dlx, $dly, $dlz, [single]($dlx + $d[0] * 100), [single]($dly + $d[1] * 100), [single]($dlz + $d[2] * 100), $upAx)
        $gpu.SetLightCube($li, $dlx, $dly, $dlz, 768)
    }
    foreach ($grp in @($theRoom.WaterGroups)) { if (-not $grp) { continue }; $tl = New-Object 'System.Collections.Generic.List[int]'; $ys = 0.0; $yn = 0; foreach ($wt in $grp.Parts) { $wy = $theRoom.V[$wt.VFirst * 3 + 1]; if ($cam[13] -le $wy + 1) { continue }; $tl.AddRange([int[]]$wt.TriVerts); $ys += $wy; $yn++ }; if ($yn) { $gpu.AddWater($tl.ToArray(), [single]($ys / $yn)) } }
    if ($script:fx -and -not $script:partBuf) { $script:partBuf = New-Object single[] 20000 }
    if ($script:fx) { $np = $script:fx.Gather($r, $script:partBuf); if ($script:eyeShine) { $np = $script:eyeShine.Append($(if ($pose) { $pose.PoseV } else { $theRoom.V }), $r, [single]$(if ($r.Lamp -and $r.LampPower -gt 0) { 1 } else { 0 }), $script:partBuf, $np) }; $gpu.SetParticles($script:partBuf, $np) }
    $gpu.SetCameraWorld($cam); $gpu.CopyLighting($r)
    $gpu.Draw($theRoom.V, $theRoom.UV, $theRoom.T, $theRoom.TexIdx, $theRoom.Texes, $true, $true)
    $c = $S.Comp
    $gpu.SetComposeMap($c.Cxi, $c.Cxf, $c.CxiR, $c.CxfR, $c.Riy, $c.Rwy)
    $gpu.PostCompose([single]0, $c.Screen, 1600, 1600, 928, 0x101010, $c.Bt, $c.Bb, $c.Vis)
    $gpu.ReadComposed($c.Fin)
}
$jpegCodec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
function Get-Jpeg([int]$quality) {
    $bm = New-Object Drawing.Bitmap -ArgumentList $S.W, $S.H, ([Drawing.Imaging.PixelFormat]::Format32bppRgb)
    try {
        $bd = $bm.LockBits((New-Object Drawing.Rectangle 0, 0, $S.W, $S.H), [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format32bppRgb)
        [Runtime.InteropServices.Marshal]::Copy($S.Comp.Fin, 0, $bd.Scan0, $S.Comp.Fin.Length); $bm.UnlockBits($bd)
        $ep = New-Object Drawing.Imaging.EncoderParameters 1; $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), ([long]$quality)
        $ms = New-Object IO.MemoryStream; $bm.Save($ms, $jpegCodec, $ep); return $ms.ToArray()
    } finally { $bm.Dispose() }
}

# ---- serving -------------------------------------------------------------------------------------------------------------
$http = New-Object AztTool.MiniHttp; $http.Start($Port)
Write-Host ("ROOM LOOK worker on 127.0.0.1:{0} (texture quality {1})" -f $Port, $TextureQuality) -ForegroundColor Cyan
$idle = [Diagnostics.Stopwatch]::StartNew(); $utf8 = New-Object System.Text.UTF8Encoding($false)
function Reply($rq, [int]$st, [string]$type, [byte[]]$body, $hdr = $null) { $hd = New-Object 'System.Collections.Generic.Dictionary[string,string]'; $hd['Cache-Control'] = 'no-store'; if ($hdr) { foreach ($k in $hdr.Keys) { $hd[$k] = [string]$hdr[$k] } }; $rq.Respond($st, $type, $body, $hd) }
try {
    while ($true) {
        if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
        if ($idle.Elapsed.TotalMinutes -gt $IdleMinutes) { break }
        $rq = $http.Accept(500); if (-not $rq) { continue }
        $idle.Restart()
        try {
            if ($rq.Path -eq '/ping') { Reply $rq 200 'application/json' ($utf8.GetBytes((ConvertTo-Json @{ ok = $true; room = $S.Room; w = $S.W; h = $S.H } -Compress))); continue }
            if ($rq.Path -eq '/quit') { Reply $rq 200 'application/json' ($utf8.GetBytes('{"bye":true}')); break }
            if ($rq.Path -ne '/frame' -or $rq.Method -ne 'POST') { Reply $rq 404 'application/json' ($utf8.GetBytes('{"error":"no such thing"}')); continue }
            $q = $utf8.GetString($rq.Body) | ConvertFrom-Json
            $room = ([string]$q.room).ToUpperInvariant(); if ($room -notmatch '^[A-Z0-9_-]{1,32}$') { throw 'bad room' }
            $w = [Math]::Max(160, [Math]::Min(2560, [int]$q.w)); $h = [Math]::Max(90, [Math]::Min(1600, [int]$q.h)); $w -= $w % 4; $h -= $h % 2
            $sw = [Diagnostics.Stopwatch]::StartNew(); $made = $false; $loaded = $false
            if ($w -ne $S.W -or $h -ne $S.H -or -not $S.Gpu) { New-Renderer $w $h; $made = $true }
            if ($S.Room -ne $room -or $S.Stamp -ne (Get-RoomStamp $room)) { Use-Room $room; $loaded = $true }
            $tl = $sw.Elapsed.TotalMilliseconds
            Invoke-Frame $q
            $tf = $sw.Elapsed.TotalMilliseconds
            $jpg = Get-Jpeg $(if ($q.quality) { [int]$q.quality } else { 85 })
            Reply $rq 200 'image/jpeg' $jpg @{ 'X-Look-Ms' = ('{0:0}/{1:0}/{2:0}' -f $tl, ($tf - $tl), ($sw.Elapsed.TotalMilliseconds - $tf)); 'X-Look-Loaded' = $(if ($loaded -or $made) { '1' } else { '0' }) }
        } catch {
            Write-Host ("  frame failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            try { Reply $rq 500 'application/json' ($utf8.GetBytes((ConvertTo-Json @{ error = $_.Exception.Message } -Compress))) } catch { }
        }
    }
} finally {
    $http.Stop(); if ($S.Gpu) { try { $S.Gpu.Dispose() } catch { } }
    Write-Host 'room look worker stopped.' -ForegroundColor Gray
}
