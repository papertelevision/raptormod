# Restore-RoomRound.ps1 -- undo Room Review rounds (2026-10-08): put room settings back to how they were BEFORE round N
# (its snapshot in C:\Games\azrael-render\rooms-history\round-NNN), for one room or all. The current files are
# snapshotted first (rooms-history\restore-<time>), so a restore can itself be undone.
#
#   .\tools\Restore-RoomRound.ps1 -Round 3 -Room WASHCORI     (WASHCORI as it was before round 3)
#   .\tools\Restore-RoomRound.ps1 -Round 3                    (every room file)
param(
    [Parameter(Mandatory)][int]$Round,
    [string]$Room = '',
    [string]$RenderDir = 'C:\Games\azrael-render'
)
$ErrorActionPreference = 'Stop'
$snap = Join-Path $RenderDir ('rooms-history\round-{0:D3}' -f $Round)
if (-not (Test-Path $snap)) { throw "no snapshot for round $Round ($snap)" }
$roomsDir = Join-Path $RenderDir 'rooms'
$safety = Join-Path $RenderDir ('rooms-history\restore-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
New-Item -ItemType Directory -Force $safety | Out-Null
foreach ($f in @(Get-ChildItem $roomsDir -Filter '*.json' -File)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $safety $f.Name) -Force }
$names = $(if ($Room) { @($Room.ToUpperInvariant() + '.json') } else {
    # every file in the snapshot, and any room file made since (which goes, the room back to the defaults)
    @(@(Get-ChildItem $snap -Filter '*.json' -File | ForEach-Object Name) + @(Get-ChildItem $roomsDir -Filter '*.json' -File | ForEach-Object Name) | Sort-Object -Unique) })
foreach ($nm in $names) {
    $src = Join-Path $snap $nm; $dst = Join-Path $roomsDir $nm
    if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination $dst -Force; Write-Host "restored $nm (as before round $Round)" -ForegroundColor Green }
    elseif (Test-Path $dst) {
        # the room had no file of its own before that round: it goes back to the shared defaults (the file is kept aside)
        Move-Item -LiteralPath $dst -Destination (Join-Path $safety ($nm + '.removed')) -Force; Write-Host "$nm had no file before round $Round -- back to the defaults" -ForegroundColor Yellow
    }
}
Write-Host "the files as they were just now: $safety" -ForegroundColor DarkGray
