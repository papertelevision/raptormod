# Find-DisplaySurface.ps1 -- locate DOSBox's display surface by its SIGNATURE, not by a
# remembered offset.
#
#   .\tools\Find-DisplaySurface.ps1
#
# Every previous attempt assumed "the 64 MB region, plus 0x140000". That offset came from
# one session and has already been wrong twice -- once it was reading a stale region whose
# contents never changed at all, which produced four identical "measurements".
#
# So: fill the entire viewport with ONE index through the injection path. On a 32-bit
# display surface that is ~590,000 identical pixels -- about 2.4 MB of one repeating dword,
# a signature nothing else in the process will match. Search every committed region for the
# longest such run and report where it is. Changing the index and repeating confirms it
# really is the viewport rather than some other uniform buffer.

[CmdletBinding()]
param(
    [string]$Overlay = 'C:\Games\RaptorMod\game\GAME\AZRAEL\AZTCODE.BIN',
    [int]$W = 1024,
    [int]$H = 576
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')

$b = [IO.File]::ReadAllBytes($Overlay)
$bufPtrVar = 0; $enableVar = 0
for ($i = 0; $i -lt $b.Length - 16; $i++) {
    if ($b[$i] -eq 0xB8 -and [BitConverter]::ToUInt32($b, $i+1) -eq ($W * $H) -and
        $b[$i+5] -eq 0xE8 -and $b[$i+10] -eq 0x89 -and $b[$i+11] -eq 0x86) {
        $bufPtrVar = [BitConverter]::ToUInt32($b, $i+12); break }
}
for ($i = 0; $i -lt $b.Length - 8; $i++) {
    if ($b[$i] -eq 0x8B -and $b[$i+1] -eq 0x9E -and $b[$i+6] -eq 0x85 -and $b[$i+7] -eq 0xDB) {
        $enableVar = [BitConverter]::ToUInt32($b, $i+2); break }
}
$g = Get-AztGuestBase
function RdU32([long]$lin) { [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $lin -Length 4), 0) }
function WrU32([long]$lin, [uint32]$v) {
    [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $lin + 0x1F0000), [BitConverter]::GetBytes($v))
}
$buf = RdU32 $bufPtrVar
if ($buf -lt 0x1000) { throw 'staging buffer not allocated' }
$frame = New-Object byte[] ($W * $H)
function Fill([byte]$v) {
    for ($i = 0; $i -lt $frame.Length; $i++) { $frame[$i] = $v }
    [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $buf), $frame)
}

WrU32 $enableVar 1

$regs = @([AztTool.ProcMem]::Regions($g.ProcessId, 0x7FFFFFFFFFFF) |
          Where-Object { $_.Size -ge 2MB } | Sort-Object Size -Descending)
Write-Host ("{0} committed regions of 2 MB or more" -f $regs.Count)

function LongestUniformRun {
    param([byte[]]$data)
    # longest run of a repeating 4-byte group
    $best = 0; $bestAt = -1; $run = 0; $start = 0
    for ($i = 4; $i + 4 -le $data.Length; $i += 4) {
        $same = ($data[$i] -eq $data[$i-4]) -and ($data[$i+1] -eq $data[$i-3]) -and
                ($data[$i+2] -eq $data[$i-2]) -and ($data[$i+3] -eq $data[$i-1])
        if ($same) { if ($run -eq 0) { $start = $i - 4 }; $run += 4 }
        else { if ($run -gt $best) { $best = $run; $bestAt = $start }; $run = 0 }
    }
    if ($run -gt $best) { $best = $run; $bestAt = $start }
    return @($best, $bestAt)
}

foreach ($idx in @(200, 40)) {
    Fill ([byte]$idx)
    Start-Sleep -Milliseconds 700
    Write-Host ""
    Write-Host ("--- viewport filled with index {0} ---" -f $idx)
    foreach ($r in ($regs | Select-Object -First 8)) {
        $len = [int][Math]::Min($r.Size, 48MB)
        $data = [AztTool.ProcMem]::Read($g.ProcessId, $r.Base, $len)
        if ($null -eq $data) { continue }
        $res = LongestUniformRun $data
        if ($res[0] -ge 1MB) {
            $at = $r.Base + $res[1]
            $px = [AztTool.ProcMem]::Read($g.ProcessId, ($at + 65536), 4)
            Write-Host ("  region 0x{0:X11} ({1,5:N0} MB)  run {2,10:N0} bytes at +0x{3:X}  pixel BGRA {4}" -f `
                $r.Base, ($r.Size/1MB), $res[0], $res[1],
                (($px | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
        }
    }
}

WrU32 $enableVar 0
Write-Host ""
Write-Host "injection disabled. The region whose run is ~2.4 MB and whose pixel CHANGES" -ForegroundColor Green
Write-Host "between the two indices is the display surface." -ForegroundColor Green
