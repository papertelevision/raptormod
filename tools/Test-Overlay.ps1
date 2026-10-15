# Test-Overlay.ps1 -- the true-colour overlay, checked without a game.
#
#   .\tools\Test-Overlay.ps1
#
# Builds a fake 1600x1200 32-bit display surface in THIS process (noise for the HUD, a "widget"
# over the viewport's corner, a "reticle" in the middle), then asks Overlay.cs to do everything
# it does against DOSBox: find the viewport from the calibration patch, tell a live surface from
# a stale one, lay the game's drawings over a host picture, notice a movie, and scale. The
# window is created but never shown.
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -Path (Join-Path $toolDir 'Overlay.cs') -ErrorAction Stop
if (-not ('AztTool.ProcMem' -as [type])) { Add-Type -Path (Join-Path $toolDir 'ProcMem.cs') }

$W = 1600; $H = 928; $SW = 1600; $SH = 1200; $fail = 0
function Check([string]$what, [bool]$ok) { Write-Host ("  {0,-58} {1}" -f $what, $(if ($ok) { 'ok' } else { 'FAILED' })) -ForegroundColor $(if ($ok) { 'Gray' } else { 'Red' }); if (-not $ok) { $script:fail++ } }

$palB = [IO.File]::ReadAllBytes('C:\Games\RaptorMod\cache\azrael-palette.pal'); $pal32 = New-Object int[] 256
for ($i = 0; $i -lt 256; $i++) { $pal32[$i] = ([int]$palB[$i*3] -shl 16) -bor ([int]$palB[$i*3+1] -shl 8) -bor [int]$palB[$i*3+2] }

$hdr = 4096*3 + 64; $first = [int]($hdr / 4)
$surf = New-Object int[] ($first + $SW*$SH + 5000)
$rnd = New-Object Random 7
for ($i = 0; $i -lt $surf.Length; $i++) { $surf[$i] = $rnd.Next() -band 0xFFFFFF }
$A = 120; $B = 200
function Paint([byte[]]$frame) {
    for ($y = 0; $y -lt $H; $y++) { $o = $first + ($y + 49)*$SW; $fo = $y*$W; for ($x = 0; $x -lt $W; $x++) { $surf[$o + $x] = $pal32[$frame[$fo + $x]] } }
    for ($y = 0; $y -lt 40; $y++)     { $o = $first + ($y + 49)*$SW; for ($x = 0;   $x -lt 300; $x++) { $surf[$o + $x] = 0xAA5500 } }
    for ($y = 450; $y -lt 478; $y++)  { $o = $first + ($y + 49)*$SW; for ($x = 786; $x -lt 814; $x++) { $surf[$o + $x] = 0x00FF00 } }
}
$gh = [Runtime.InteropServices.GCHandle]::Alloc($surf, 'Pinned'); $addr = $gh.AddrOfPinnedObject().ToInt64()
$ov = $null
try {
    $ov = New-Object AztTool.Overlay($PID, $W, $H, $SW, $SH, 0, 49)
    $ov.SyncRead = $true
    Paint ([AztTool.Overlay]::PatchFrame($W, $H, $A, $B, 400, 200, 256, 128))
    $regs = @([AztTool.ProcMem]::Regions($PID, 0x7FFFFFFFFFFF) | Where-Object { $_.Size -ge 5MB -and $_.Size -le 600MB })
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $f = $ov.FindPatch([long[]]@($regs | ForEach-Object { $_.Base }), [long[]]@($regs | ForEach-Object { $_.Size }), 400, 200, 256, 128)
    Write-Host ("scanned {0} regions, {1:N0} MB, in {2} ms: {3} place(s)" -f $regs.Count, (($regs | Measure-Object Size -Sum).Sum / 1MB), $clock.ElapsedMilliseconds, $f.Count)
    $want = $addr + $hdr + 49*$SW*4
    Check 'the viewport is found, once' ($f.Count -eq 1)
    Check 'at the right address, with the right stride' ($f.Count -ge 1 -and $f[0][0] -eq $want -and $f[0][1] -eq $SW)
    Check 'the patch is confirmed where it was drawn' ($ov.CheckPatch($f[0][0], $f[0][1], 400, 200, 256, 128))
    Paint ([AztTool.Overlay]::PatchFrame($W, $H, $A, $B, 1000, 620, 256, 128))
    Check 'a moved patch is no longer confirmed at the old place' (-not $ov.CheckPatch($f[0][0], $f[0][1], 400, 200, 256, 128))
    Check 'and is confirmed at the new one' ($ov.CheckPatch($f[0][0], $f[0][1], 1000, 620, 256, 128))

    $ov.SetSurface($f[0][0], [int]$f[0][1])
    Paint ([AztTool.Overlay]::FlatFrame($W, $H, $A))
    $col = New-Object byte[] ($W*$H); for ($i = 0; $i -lt $col.Length; $i++) { $col[$i] = [byte](54 + [int][Math]::Floor(($i % $W) * 200 / $W)) }
    $ov.FixX = 0; $ov.FixY = 0; $ov.FixW = 2134; $ov.FixH = 1238
    Check ("the window is created  {0}" -f $ov.StartError) ($ov.Start())
    $ov.KeepCopy = $true
    $share = $ov.Present($col, $pal32, 400)
    Write-Host ("present: key share {0}/1000, key #{1:X6}, read {2:N2} ms, compose {3:N2} ms" -f $share, $ov.LastKey, $ov.ReadMs, $ov.ComposeMs)
    $fr = $ov.LastFrame()
    Check 'the key is the flat colour the game was given' ($ov.LastKey -eq $pal32[$A])
    Check 'clear view shows the host picture' ($fr[500*$W + 100] -eq $pal32[$col[500*$W + 100]])
    Check 'the widget over the corner is kept' ($fr[10*$W + 10] -eq 0xAA5500)
    Check 'the reticle is kept' ($fr[460*$W + 800] -eq 0x00FF00)
    Start-Sleep -Milliseconds 200
    Check 'never shown: this process is not the game in front' (-not $ov.Shown)
    for ($y = 0; $y -lt $H; $y++) { $o = $first + ($y + 49)*$SW; for ($x = 0; $x -lt $W; $x++) { $surf[$o + $x] = $rnd.Next() -band 0xFFFFFF } }
    Check 'a movie over the view (no one colour) hides the overlay' ($ov.Present($col, $pal32, 400) -lt 400)

    $dst = New-Object int[] (2134*1238); $xi = $null; $xf = $null
    [AztTool.Overlay]::Scale($fr, $W, $H, $dst, 2134, 1238, [ref]$xi, [ref]$xf)
    $clock.Restart(); for ($k = 0; $k -lt 20; $k++) { [AztTool.Overlay]::Scale($fr, $W, $H, $dst, 2134, 1238, [ref]$xi, [ref]$xf) }
    Write-Host ("scale 1600x928 -> 2134x1238: {0:N2} ms" -f ($clock.Elapsed.TotalMilliseconds / 20))
    # a horizontal ramp must stay a ramp: same colour at the same relative place, within a step
    $bad = 0
    foreach ($dx in 50, 700, 1300, 2000) {
        $s = $fr[600*$W + [int](($dx + 0.5) * $W / 2134)]; $d = $dst[800*2134 + $dx]
        foreach ($sh in 16, 8, 0) { if ([Math]::Abs((($s -shr $sh) -band 255) - (($d -shr $sh) -band 255)) -gt 24) { $bad++ } }
    }
    Check 'the scaled picture matches its source' ($bad -eq 0)
    Write-Host ("window rectangle {0}; blits {1}" -f $ov.RectText, $ov.Blits)
} finally { if ($ov) { $ov.Dispose() }; $gh.Free() }
if ($fail) { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all checks passed' -ForegroundColor Green }
