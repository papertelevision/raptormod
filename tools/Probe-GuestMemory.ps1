# Probe-GuestMemory.ps1 -- can host code read the game's state WITHOUT forking DOSBox?
#
#   .\tools\Probe-GuestMemory.ps1
#
# Unknown 7 in the feasibility report assumes a host-side reader needs an emulator fork.
# This tests the cheaper hypothesis first: DOSBox keeps emulated RAM in an ordinary
# allocation in an ordinary Windows process, so a host process may be able to find and
# read the guest's memory with ReadProcessMemory and no emulator changes whatsoever.
#
# The probe looks for AZTCODE.BIN -- AztMod's own overlay, loaded to guest linear
# 0x133000. It is the ideal needle because WE produced it: it is 12,815 bytes of content
# that exists nowhere else on the system, so a hit cannot be a coincidence.
#
# It then reads the whole blob back from the address it found and reports how many bytes
# match the file. That is the self-validating part: a high match proves both that we
# found the right thing AND how much of the guest's address space is contiguous in host
# memory, which is what decides whether a mailbox can be read in one call.

[CmdletBinding()]
param(
    [string]$Blob = 'C:\Games\AzraelsTear-Modded\GAME\AZRAEL\AZTCODE.BIN',
    [int]$Pid_ = 0,
    [int]$SigLen = 256,
    [long]$GuestLinear = 0x133000
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
if (-not ("AztTool.ProcMem" -as [type])) { Add-Type -Path (Join-Path $toolDir 'ProcMem.cs') }

if (-not (Test-Path $Blob)) { throw "overlay blob not found: $Blob" }
$blobBytes = [IO.File]::ReadAllBytes($Blob)
Write-Host ("overlay blob: {0:N0} bytes, loaded by the game to guest linear 0x{1:X}" -f $blobBytes.Length, $GuestLinear)

if (-not $Pid_) {
    $procs = @(Get-Process -Name 'dosbox*' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { throw "no dosbox process running -- launch the game first" }
    if ($procs.Count -gt 1) { Write-Host ("{0} dosbox processes; using the first" -f $procs.Count) -ForegroundColor Yellow }
    $Pid_ = $procs[0].Id
}
$proc = Get-Process -Id $Pid_
Write-Host ("target: {0} pid {1}, working set {2:N0} MB" -f $proc.ProcessName, $Pid_, ($proc.WorkingSet64 / 1MB))

# ---- pick signatures that cannot straddle a guest page ----------------------
# 0x133000 is page aligned, so file offset O sits at guest 0x133000+O and a signature
# starting 0x200 into any page stays inside that page for any SigLen <= 0xE00.
$cands = @()
foreach ($page in 0, 1, 2) {
    $off = $page * 4096 + 0x200
    if ($off + $SigLen -gt $blobBytes.Length) { continue }
    $sig = New-Object byte[] $SigLen
    [Array]::Copy($blobBytes, $off, $sig, 0, $SigLen)
    $distinct = ($sig | Sort-Object -Unique).Count
    $cands += [pscustomobject]@{ Offset = $off; Sig = $sig; Distinct = $distinct }
}
Write-Host ""
Write-Host "--- signatures ---"
foreach ($c in $cands) {
    Write-Host ("  file +0x{0:X5}  guest 0x{1:X}  {2} distinct byte values{3}" -f `
        $c.Offset, ($GuestLinear + $c.Offset), $c.Distinct,
        $(if ($c.Distinct -lt 8) { '   (LOW VARIETY -- a hit here would be weak evidence)' } else { '' }))
}

# ---- scan ---------------------------------------------------------------------
Write-Host ""
Write-Host "--- scanning committed regions (this reads, never writes) ---"
$found = @()
foreach ($c in $cands) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # emulated RAM is a large single allocation; ignore tiny regions and absurd ones
    $hits = [AztTool.ProcMem]::Scan($Pid_, $c.Sig, 64KB, 2GB, 0x7FFFFFFFFFFF, 8)
    $sw.Stop()
    Write-Host ("  file +0x{0:X5}: {1} hit(s) in {2:N1}s{3}" -f $c.Offset, $hits.Count, $sw.Elapsed.TotalSeconds,
        $(if ($hits.Count) { '  ->  ' + (($hits | ForEach-Object { '0x{0:X}' -f $_ }) -join ', ') } else { '' }))
    foreach ($hp in $hits) { $found += [pscustomobject]@{ Offset = $c.Offset; Host_ = $hp } }
}

if (-not $found.Count) {
    Write-Host ""
    Write-Host "NOT FOUND. That does not disprove the idea -- it may mean the overlay is not" -ForegroundColor Yellow
    Write-Host "resident yet (load a saved game or reach the first room), or that DOSBox stores" -ForegroundColor Yellow
    Write-Host "guest RAM somewhere this scan skipped." -ForegroundColor Yellow
    return
}

# ---- derive the base and read the whole blob back ---------------------------
Write-Host ""
Write-Host "--- verification: read the whole overlay back from the derived base ---"
$first = $found[0]
$base = $first.Host_ - $first.Offset        # host address corresponding to guest 0x133000
Write-Host ("guest 0x{0:X} appears to be host 0x{1:X}" -f $GuestLinear, $base)

$back = [AztTool.ProcMem]::Read($Pid_, $base, $blobBytes.Length)
if ($null -eq $back) { Write-Host "  read failed" -ForegroundColor Yellow; return }

$match = 0
$firstDiff = -1
for ($i = 0; $i -lt $back.Length; $i++) {
    if ($back[$i] -eq $blobBytes[$i]) { $match++ }
    elseif ($firstDiff -lt 0) { $firstDiff = $i }
}
$pct = 100.0 * $match / $blobBytes.Length
Write-Host ("  {0:N0} of {1:N0} bytes match ({2:N1}%)" -f $match, $blobBytes.Length, $pct)
if ($firstDiff -ge 0) {
    Write-Host ("  first difference at file +0x{0:X} (guest 0x{1:X})" -f $firstDiff, ($GuestLinear + $firstDiff))
    Write-Host  "  NOTE: differences are EXPECTED past the code -- the overlay's BSS holds live"
    Write-Host  "        counters and buffers that the game has been writing to."
}

# per-page match, which is what actually tells us about contiguity
Write-Host ""
Write-Host "--- per-page match (4096-byte guest pages) ---"
$pages = [int][Math]::Ceiling($blobBytes.Length / 4096.0)
for ($p = 0; $p -lt $pages; $p++) {
    $s = $p * 4096
    $e = [Math]::Min($s + 4096, $blobBytes.Length)
    $m = 0
    for ($i = $s; $i -lt $e; $i++) { if ($back[$i] -eq $blobBytes[$i]) { $m++ } }
    $n = $e - $s
    Write-Host ("  page {0}  guest 0x{1:X}  {2,5}/{3,-5} bytes match  {4,6:N1}%" -f `
        $p, ($GuestLinear + $s), $m, $n, (100.0 * $m / $n))
}

Write-Host ""
Write-Host "If page 0 matches at or near 100%, a host process can read guest memory live" -ForegroundColor Green
Write-Host "with no emulator fork, and unknown 7's transport is solved at the cheap end." -ForegroundColor Green
