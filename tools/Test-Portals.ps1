# Test-Portals.ps1 -- the doorway views and the motion blend, checked without the game.
#
#   .\tools\Test-Portals.ps1                         # CORICORI, every doorway
#   .\tools\Test-Portals.ps1 -Room SPAROOM -Back 220
#   .\tools\Test-Portals.ps1 -All                    # every room file with a doorway: numbers only
#
# For each doorway of the room that has a picture standing in it, stands the camera inside
# the room looking out through that doorway and renders the frame twice: as the game has it
# (the still picture) and with the neighbouring room drawn through the opening. Both are
# saved as PNGs side by side, so the two can be looked at; and it reports how much of the
# frame the doorway filled and how much of that the neighbour actually covered.
#
# It also checks two things that can be checked exactly:
#   * with the doorways switched on, every pixel OUTSIDE a doorway is identical to the room
#     drawn with the picture simply left out (the portal pass must not disturb the room it
#     is drawn into);
#   * the motion blend returns a rigid, correctly scaled matrix half way through a turn.
param(
    [string]$Room = 'CORICORI',
    [double]$Back = 160,          # how far inside the room from the exit trigger to stand
    [double]$Eye = 33,            # eye height above the floor at the doorway
    [double]$Side = 0,            # step sideways, to see the parallax
    [switch]$All,
    [int]$Width = 800, [int]$Height = 464,
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
if (-not $OutDir) { $OutDir = Join-Path $CacheDir 'portal-test' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
. (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'),
                 (Join-Path $toolDir 'SceneGraph.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

function Save-Indexed([byte[]]$color, [byte[]]$pal, [int]$w, [int]$h, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    $cp = $bmp.Palette
    for ($i = 0; $i -lt 256; $i++) { $cp.Entries[$i] = [System.Drawing.Color]::FromArgb($pal[$i*3], $pal[$i*3+1], $pal[$i*3+2]) }
    $bmp.Palette = $cp
    $rc = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $w, $h
    $bd = $bmp.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    for ($y = 0; $y -lt $h; $y++) { [System.Runtime.InteropServices.Marshal]::Copy($color, $y * $w, [IntPtr]($bd.Scan0.ToInt64() + $y * $bd.Stride), $w) }
    $bmp.UnlockBits($bd); $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

# ---- the blend ---------------------------------------------------------------
# A bone scaled 0.1 that turns 90 degrees about Y and moves 10 units, sampled half way.
$sm = New-Object AztTool.Smoother; $sm.All = $true
function New-Tree([single[]]$local) {
    $t = New-Object AztTool.SceneGraph+LiveTree
    $t.Count = 2; $t.Frame = [uint32[]]@(0x2000, 0x3000); $t.Parent = [int[]]@(-1, 0); $t.Name = [string[]]@('', 'bone')
    $t.Local = New-Object 'single[][]' 2; $t.Local[0] = New-Object single[] 16; $t.Local[1] = $local; $t.InChar = [bool[]]@($false, $true)
    return $t
}
$a = [single[]]@(0.1,0,0,0, 0,0.1,0,0, 0,0,0.1,0, 5,0,0,1)
$b = [single[]]@(0,0,-0.1,0, 0,0.1,0,0, 0.1,0,0,0, 15,0,0,1)
$sm.Sample((New-Tree $a), 0); $sm.Sample((New-Tree $b), 1000)
$mid = $sm.Evaluate(1000 + $sm.TickMs / 2)['bone']; $end = $sm.Evaluate(1000 + $sm.TickMs + 1)['bone']
$len = [Math]::Sqrt($mid[0]*$mid[0] + $mid[1]*$mid[1] + $mid[2]*$mid[2])
$ang = [Math]::Atan2(-$mid[2], $mid[0]) * 180 / [Math]::PI
$okBlend = ([Math]::Abs($len - 0.1) -lt 1e-4) -and ([Math]::Abs($ang - 45) -lt 0.01) -and ([Math]::Abs($mid[12] - 10) -lt 1e-3)
$okEnd = $true; for ($i = 0; $i -lt 16; $i++) { if ([Math]::Abs($end[$i] - $b[$i]) -gt 1e-6) { $okEnd = $false } }
'{0}  motion blend: half way through a 90-degree turn the bone is at {1:N2} degrees, scale {2:N4}, x {3:N2}; arrives exactly: {4}' -f `
    $(if ($okBlend -and $okEnd) { 'PASS' } else { 'FAIL' }), $ang, $len, $mid[12], $okEnd

# ---- the doorways -------------------------------------------------------------
$map = [IO.File]::ReadAllText((Join-Path $CacheDir 'portals.json')) | ConvertFrom-Json
$roomList = $(if ($All) { @($map.PSObject.Properties | ForEach-Object { $_.Name }) } else { @($Room.ToUpper()) })
$r = New-Object AztTool.Raster($Width, $Height); $r.NearZ = [single]0.5; $r.SetVerticalFov(50)
$fails = 0; $nDoor = 0; $nEmpty = 0
foreach ($rn in $roomList) {
    $geo = Import-AztRoom -Rooms @($rn) -CacheDir $CacheDir
    $ps = Get-AztPortals -Room $geo -Files @($rn) -CacheDir $CacheDir
    foreach ($note in $script:AztPortalNotes) { "  $note" }
    if (-not $ps.Count) { if (-not $All) { "$rn has no doorway with a picture" }; continue }
    $entries = @($map.PSObject.Properties[$rn].Value)
    foreach ($po in $ps) {
        $e = $entries | Where-Object { $_.zone -eq $po.Zone } | Select-Object -First 1
        $ax = [double]$e.axis[0]; $az = [double]$e.axis[1]
        $ex = $po.DoorX - $ax*$Back - $az*$Side; $ez = $po.DoorZ - $az*$Back + $ax*$Side; $ey = $po.DoorY + $Eye
        $r.LookAt([single]$ex, [single]$ey, [single]$ez, [single]($po.DoorX + $ax*100), [single]$ey, [single]($po.DoorZ + $az*100), 1)
        $base = [int[]]$geo.TexIdx.Clone(); $cur = [int[]]$geo.TexIdx.Clone()
        # as the game has it
        $r.FastClear([byte]0); $r.DrawTexturedFast($geo.V, $geo.UV, $geo.T, $cur, $geo.Texes, $true, $true)
        $plain = [byte[]]$r.Color.Clone()
        # with the neighbour
        $one = [AztTool.Portal[]]@($po)
        $standing = [AztTool.Portals]::Prepare($one, $geo.V, $cur, $base, $null)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r.FastClear([byte]0); $r.DrawTexturedFast($geo.V, $geo.UV, $geo.T, $cur, $geo.Texes, $true, $true)
        $t1 = $sw.Elapsed.TotalMilliseconds
        $bare = [byte[]]$r.Color.Clone()      # the room with the picture taken out and nothing put in its place
        $sw.Restart(); $px = [AztTool.Portals]::Draw($r, $one, $geo.V, $true, $true); $t2 = $sw.Elapsed.TotalMilliseconds
        $with = [byte[]]$r.Color.Clone(); $maskNow = [byte[]]$r.Mask.Clone()
        # outside the doorway nothing may change; inside it, count what the neighbour covered
        $diffOutside = 0; $covered = 0; $wall = 0; $nOpen = 0; $mask = $maskNow
        if ($px -gt 0) {
            for ($i = 0; $i -lt $with.Length; $i++) { if ($mask[$i] -eq 255) { $wall++ } elseif ($mask[$i] -ne 0) { $nOpen++; if ($with[$i] -ne 0) { $covered++ } } elseif ($with[$i] -ne $bare[$i]) { $diffOutside++ } }
        }
        $nDoor++
        if ($diffOutside -gt 0) { $fails++ }
        if ($px -gt 0 -and ($nOpen -eq 0 -or $covered -eq 0)) { $nEmpty++ }
        # and as it is once the game says the far door has been opened: the far room's own
        # door at this doorway taken out of the way
        $open = $null
        if ($po.DoorTris.Length -and -not $All) {
            for ($k = 0; $k -lt $po.DoorTris.Length; $k++) { $po.TexIdx[$po.DoorTris[$k]] = -1 }
            $r.FastClear([byte]0); $r.DrawTexturedFast($geo.V, $geo.UV, $geo.T, $cur, $geo.Texes, $true, $true)
            [void][AztTool.Portals]::Draw($r, $one, $geo.V, $true, $true)
            $open = [byte[]]$r.Color.Clone()
            for ($k = 0; $k -lt $po.DoorTris.Length; $k++) { $po.TexIdx[$po.DoorTris[$k]] = $po.DoorTex[$k] }
        }
        [AztTool.Portals]::Restore($one, $cur, $base, $null)
        $line = '{0}  {1,-9} {2,-22} -> {3,-9} pictures standing {4}, doorway {5,6:N0} px ({6,4:N1}% of frame), {12,3:N0}% of it is the far tunnel mouth, neighbour covers {7,5:N1}% of that, {8} px changed outside; room {9:N1} ms + doorway {10:N1} ms, far door: {11} triangles' -f `
            $(if ($diffOutside -eq 0) { 'PASS' } else { 'FAIL' }), $rn, $po.Zone, $po.To, $standing, $px, (100.0*$px/$with.Length), $(if ($nOpen) { 100.0*$covered/$nOpen } else { 0 }), $diffOutside, $t1, $t2, $po.DoorTris.Length, $(if ($px) { 100.0*$nOpen/$px } else { 0 })
        if (-not $All -or $diffOutside -gt 0 -or ($px -gt 0 -and ($nOpen -eq 0 -or $covered -eq 0))) { $line }
        if (-not $All) {
            $stem = Join-Path $OutDir ('{0}-{1}' -f $rn, ($po.Zone -replace '[^A-Za-z0-9]', ''))
            Save-Indexed $plain $geo.Pal $Width $Height "$stem-picture.png"
            Save-Indexed $with $geo.Pal $Width $Height "$stem-live.png"
            if ($open) { Save-Indexed $open $geo.Pal $Width $Height "$stem-live-fardooropen.png" }
        }
    }
}
'{0} doorways rendered in {1} room files: {2} disturbed the room outside the doorway, {3} showed nothing at all through it' -f $nDoor, $roomList.Count, $fails, $nEmpty
if (-not $All) { "pictures -> $OutDir" }
