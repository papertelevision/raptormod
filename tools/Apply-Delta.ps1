# Apply-Delta.ps1 -- bring the modded game from the manifest it was last installed from
# (AztMod.manifest.installed.json) to the current one (AztMod.manifest.json): put back the
# stock bytes of every patch that changed or went away, write the new ones, write the overlay,
# then verify EVERY patch in the current manifest against the file. Refuses while the game runs.
param([string]$Game = 'C:\Games\RaptorMod\game\GAME\AZRAEL')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (@(Get-Process dosbox -ErrorAction SilentlyContinue).Count) { Write-Host 'The game is running. Close it first, then run this again.' -ForegroundColor Red; exit 1 }
$oldP = Join-Path $root 'AztMod.manifest.installed.json'; $newP = Join-Path $root 'AztMod.manifest.json'
$old = [IO.File]::ReadAllText($oldP) | ConvertFrom-Json; $new = [IO.File]::ReadAllText($newP) | ConvertFrom-Json
function HexB([string]$h) { $o = New-Object byte[] ($h.Length / 2); for ($i = 0; $i -lt $o.Length; $i++) { $o[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }; ,$o }
function HexS([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join '' }
$exe = Join-Path $Game 'R.EXE'
$raw = [IO.File]::ReadAllBytes($exe)
$om = @{}; foreach ($p in $old.patches) { $om[$p.name] = $p }; $nm = @{}; foreach ($p in $new.patches) { $nm[$p.name] = $p }
$undo = @($old.patches | Where-Object { -not $nm.ContainsKey($_.name) -or $nm[$_.name].offset -ne $_.offset -or $nm[$_.name].replace -ne $_.replace })
$todo = @($new.patches | Where-Object { -not $om.ContainsKey($_.name) -or $om[$_.name].offset -ne $_.offset -or $om[$_.name].replace -ne $_.replace })
foreach ($p in $undo) {
    $rep = HexB $p.replace; $cur = HexS ([byte[]]$raw[$p.offset..($p.offset + $rep.Length - 1)])
    if ($cur -eq $p.expect) { continue }                       # already stock
    if ($cur -ne $p.replace) { throw "cannot undo $($p.name): the file holds $cur, neither the old patch nor stock" }
    (HexB $p.expect).CopyTo($raw, [int]$p.offset)
}
foreach ($p in $todo) {
    $exp = HexB $p.expect; $cur = HexS ([byte[]]$raw[$p.offset..($p.offset + $exp.Length - 1)])
    if ($cur -ne $p.expect -and $cur -ne $p.replace) { throw "cannot apply $($p.name): the file holds $cur, expected $($p.expect)" }
    (HexB $p.replace).CopyTo($raw, [int]$p.offset)
}
$bad = 0
foreach ($p in $new.patches) { $rep = HexB $p.replace; for ($i = 0; $i -lt $rep.Length; $i++) { if ($raw[$p.offset + $i] -ne $rep[$i]) { $bad++; Write-Host "MISMATCH $($p.name)" -ForegroundColor Red; break } } }
if ($bad) { throw "$bad patches would not verify -- nothing written" }
Copy-Item $exe "$exe.pre-delta" -Force
[IO.File]::WriteAllBytes($exe, $raw)
[IO.File]::WriteAllBytes((Join-Path $Game $new.overlay.name), (HexB $new.overlay.bytes))
Copy-Item $newP $oldP -Force
Write-Host ("installed: {0} patch(es) changed ({1}); all {2} verified; overlay {3} bytes" -f $todo.Count, (($todo | ForEach-Object name) -join ', '), $new.patches.Count, ($new.overlay.bytes.Length / 2)) -ForegroundColor Green