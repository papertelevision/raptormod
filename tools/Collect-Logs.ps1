# Collect-Logs.ps1 -- zips a RaptorMod install's logs and settings to the Desktop, for a bug report (Collect Logs.cmd).
$r = $env:RAPTORMOD_ROOT; if (-not $r) { $r = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) }
$want = @('cache\watch.log', 'cache\watch.1.log', 'cache\install.log', 'cache\gpu-check.json', 'raptormod-root.txt', 'game\raptormod-settings.json')
$f = @($want | ForEach-Object { Join-Path $r $_ } | Where-Object { Test-Path $_ })
if (-not $f.Count) { Write-Host "No logs found in $r"; exit 1 }
$z = Join-Path ([Environment]::GetFolderPath('Desktop')) ('RaptorMod-logs-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.zip')
Compress-Archive -Path $f -DestinationPath $z -Force
Write-Host "Saved $z -- attach it to your bug report."