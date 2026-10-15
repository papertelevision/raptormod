# Test-GpuCaps.ps1 -- can this PC run RaptorMod's GPU version? (2026-10-15: the second PC's install; Setup-Machine runs this)
#
#   powershell -ExecutionPolicy Bypass -File tools\Test-GpuCaps.ps1
#
# Compiles the renderer exactly as Watch-HostRender does (every .cs it loads, the same references) and opens the graphics card
# the way the renderer does (GpuRaster.Create: OpenGL 4.5, glClipControl, its startup shaders and buffers). Prints one line,
# writes <CacheDir>\gpu-check.json, and exits 0 if the card can draw the picture, 1 if not (the reason in both). Never starts
# the game. It does not test the overlay window itself (that needs the game running).

[CmdletBinding()]
param([string]$CacheDir = 'C:\Games\RaptorMod\cache')
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
$res = [ordered]@{ checked = (Get-Date).ToString('s'); computer = $env:COMPUTERNAME; ok = $false; compiled = $false; vendor = ''; renderer = ''; version = ''; cardMemoryGB = 0; screen = ''; error = '' }
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # (the renderer's own set and order: Watch-HostRender.ps1, the Add-Type after GuestBase/LoadRoom)
    Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'),
                     (Join-Path $toolDir 'SceneGraph.cs'), (Join-Path $toolDir 'Keys.cs'), (Join-Path $toolDir 'Overlay.cs'), (Join-Path $toolDir 'Motes.cs'),
                     (Join-Path $toolDir 'GpuRaster.cs'), (Join-Path $toolDir 'GiBake.cs'), (Join-Path $toolDir 'Particles.cs'), (Join-Path $toolDir 'Panel.cs'), (Join-Path $toolDir 'Pointer.cs'), (Join-Path $toolDir 'CursorShapes.cs'), (Join-Path $toolDir 'CursorIcons.cs'),
                     (Join-Path $toolDir 'BootHd.cs'), (Join-Path $toolDir 'ScanWire.cs'), (Join-Path $toolDir 'RoomCover.cs'), (Join-Path $toolDir 'TexTwins.cs'), (Join-Path $toolDir 'FrameStep.cs')) `
             -ReferencedAssemblies 'System.Drawing', 'System.Web.Extensions' -ErrorAction Stop
    $res.compiled = $true; $compileMs = $sw.ElapsedMilliseconds
    Add-Type -AssemblyName System.Windows.Forms
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $res.screen = '{0}x{1}' -f $b.Width, $b.Height
    $e = $null; $g = [AztTool.GpuRaster]::Create(1280, 720, [ref]$e)
    if ($g) {
        $res.ok = $true; $res.vendor = [string]$g.Vendor; $res.renderer = [string]$g.Renderer; $res.version = [string]$g.Version; $res.cardMemoryGB = [Math]::Round($g.CardMemoryBytes / 1GB, 1)
        $g.Dispose()
    } else { $res.error = [string]$e }
} catch { $res.error = $_.Exception.Message }
try { New-Item -ItemType Directory -Force $CacheDir | Out-Null; [IO.File]::WriteAllText((Join-Path $CacheDir 'gpu-check.json'), ($res | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch { }
if ($res.ok) {
    Write-Host ("GPU OK: {0} (OpenGL {1}, {2} GB), screen {3}; the renderer compiled in {4:N0} ms" -f $res.renderer, $res.version, $res.cardMemoryGB, $res.screen, $compileMs) -ForegroundColor Green
    exit 0
}
Write-Host ("GPU NOT USABLE: {0}{1}" -f $res.error, $(if (-not $res.compiled) { ' (the renderer did not compile)' } else { '' })) -ForegroundColor Yellow
exit 1
