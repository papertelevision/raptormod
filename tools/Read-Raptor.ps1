# Symbolise a Reality Lab error capture.
#
#   .\tools\Read-Raptor.ps1
#   .\tools\Read-Raptor.ps1 -Dump C:\Games\azrael-render\raptor.txt
#
# AztRaptorTrap (see $ENABLE_RAPTOR_TRAP in src\Build-AztMod.ps1) replaces RL's registered
# error callback at 0x10204 and sifts the stack for anything inside obj1, i.e. anything that
# could be a return address. That list is raw: some entries are genuine return addresses and
# some are data that merely looks like one. This separates them.
#
# A GENUINE RETURN ADDRESS HAS A CALL IMMEDIATELY BEFORE IT. That is the whole test, and it
# is decisive: for each captured value R, look for a known instruction that both ENDS exactly
# at R and is a call. When one exists, its target is the function that was being called, and
# the function containing it is the caller. Anything else is noise and is labelled as such.
#
# Entries at or above the overlay base are our own patched code, resolved from
# AztMod.overlay.sym instead of from the disassembly, because they do not exist in R.EXE.
param(
    [string]$Dump,
    [string]$Exe,
    [string]$Sym
)
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY in param defaults under `powershell -File`, so resolve here.
$here = Split-Path -Parent $PSCommandPath
if (-not $Dump) { $Dump = 'C:\Games\azrael-render\raptor.txt' }
if (-not $Sym)  { $Sym  = Join-Path $here '..\AztMod.overlay.sym' }
if (-not (Test-Path $Dump)) { throw "no capture at $Dump -- run the watcher until the game reports a Reality Lab error" }

$loadArgs = @{}
if ($Exe) { $loadArgs['Exe'] = $Exe }
. (Join-Path $here 'load.ps1') @loadArgs
Initialize-Azt

# Overlay symbols, sorted so an address inside a routine resolves to that routine + offset.
$ovl = @()
if (Test-Path $Sym) {
    foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Sym).Path)) {
        if ($l -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') {
            $ovl += [pscustomobject]@{ A = [uint32]('0x' + $Matches[1]); N = $Matches[2] }
        }
    }
    $ovl = @($ovl | Sort-Object A)
}
function OvlName([uint32]$a) {
    $best = $null
    foreach ($s in $ovl) { if ($s.A -le $a) { $best = $s } else { break } }
    if (-not $best) { return '' }
    if ($best.A -eq $a) { return $best.N }
    return ("{0}+{1}" -f $best.N, ($a - $best.A))
}

# Every instruction that ENDS at a given address, so a return address can be matched to the
# call that produced it. Built once: the alternative is a backwards decode, which is not
# decidable on x86.
$endsAt = @{}
foreach ($a in $AN.InsnStarts) {
    $ins = $DIS.Decode([uint32]$a)
    $e = [uint32]($a + $ins.Len)
    if (-not $endsAt.ContainsKey($e)) { $endsAt[$e] = [uint32]$a }
}

$lines = @([IO.File]::ReadAllLines((Resolve-Path $Dump).Path))
foreach ($l in $lines) { if ($l -like '#*') { Write-Host $l -ForegroundColor Cyan } }

$addrs = @()
foreach ($l in $lines) { if ($l -match '^0x([0-9A-Fa-f]+)') { $addrs += [uint32]('0x' + $Matches[1]) } }
Write-Host ("`n{0} captured candidate(s), innermost first`n" -f $addrs.Count)

$real = @()
$i = 0
foreach ($a in $addrs) {
    $i++
    $tag = OvlName $a
    if ($tag) {
        Write-Host ("{0,2}. 0x{1:X8}  AztMod overlay: {2}" -f $i, $a, $tag) -ForegroundColor Magenta
        continue
    }
    if (-not $AN.InCode($a)) {
        Write-Host ("{0,2}. 0x{1:X8}  not code -- data that looks like an address" -f $i, $a) -ForegroundColor DarkGray
        continue
    }
    if (-not $endsAt.ContainsKey($a)) {
        Write-Host ("{0,2}. 0x{1:X8}  in code, but no known instruction ends here (not a return address)" -f $i, $a) -ForegroundColor DarkGray
        continue
    }
    $from = $endsAt[$a]
    $ins  = $DIS.Decode($from)
    if ($ins.Text -notmatch '^call') {
        Write-Host ("{0,2}. 0x{1:X8}  preceded by '{2}', not a call -- noise" -f $i, $a, $ins.Text) -ForegroundColor DarkGray
        continue
    }
    $fn = FuncOf $from
    Write-Host ("{0,2}. 0x{1:X8}  RETURN into function 0x{2:X}" -f $i, $a, $fn) -ForegroundColor Green
    Write-Host ("      called: 0x{0:X8}  {1}" -f $from, $ins.Text) -ForegroundColor Green
    $real += [pscustomobject]@{ Ret = $a; Site = $from; Func = $fn; Text = $ins.Text }
}

Write-Host ''
if (-not $real.Count) {
    Write-Host 'No entry had a call immediately before it. Either the chain is deeper than the' -ForegroundColor Yellow
    Write-Host 'scan window, or RL raised the error from a frame whose return address was in a' -ForegroundColor Yellow
    Write-Host 'register rather than on the stack.' -ForegroundColor Yellow
    return
}
Write-Host ("CALL CHAIN -- {0} confirmed frame(s), innermost first:" -f $real.Count) -ForegroundColor Green
foreach ($r in $real) {
    Write-Host ("  0x{0:X8}  {1,-28}  (in 0x{2:X})" -f $r.Site, $r.Text, $r.Func)
}
Write-Host ''
Write-Host 'Disassemble the outermost of these -- that is the game code that made the request --' -ForegroundColor Gray
Write-Host 'with:  . .\tools\load.ps1 ; Initialize-Azt ; UF 0x<func>' -ForegroundColor Gray
