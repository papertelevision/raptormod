# Verify a patch manifest WITHOUT running the game.
#
# Applies the manifest to a scratch copy, reloads it through the LE loader --
# which applies fixups exactly as DOS/4GW does -- and disassembles the hook sites
# and the cave. This is what caught the fixup-overlap bug in v0.1.0: the patch
# looked correct on disk but the loader overwrote four bytes of the injected
# `call` with a relocation, which would have crashed on launch.
#
#   .\tools\Test-Patch.ps1
#   .\tools\Test-Patch.ps1 -Manifest .\AztMod.diag.manifest.json

[CmdletBinding()]
param(
    [string]$Manifest = "$PSScriptRoot\..\AztMod.manifest.json",
    [string]$Exe,
    [string]$WorkDir = $env:TEMP
)

$ErrorActionPreference = 'Stop'

if (-not $Exe) {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $Exe  = Join-Path $root 'GAME\AZRAEL\R.EXE'
}
$man = Get-Content $Manifest -Raw | ConvertFrom-Json
$out = Join-Path $WorkDir ('azt-verify-{0}.exe' -f ([IO.Path]::GetFileNameWithoutExtension($Manifest)))

function FromHex([string]$h) {
    $n = $h.Length / 2; $b = New-Object byte[] $n
    for ($i = 0; $i -lt $n; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i*2,2),16) }
    return ,$b
}

if (-not ("LeTool.LeImage" -as [type])) {
    Add-Type -Path @("$PSScriptRoot\LeTool.cs","$PSScriptRoot\Disasm.cs","$PSScriptRoot\Analyzer.cs")
}

# --- instruction-boundary check -------------------------------------------
# Every patch must replace a WHOLE number of instructions. Leave half an
# instruction behind and the orphaned bytes execute as garbage: a 6-byte
# `jnz rel32` once got a 5-byte `call`, and the stray byte became an
# `add byte [esi-0x7D], ah` that corrupted memory on the fall-through path.
$orig    = New-Object LeTool.LeImage ($Exe)
$origDis = New-Object LeTool.Disasm ($orig)
$OBJ1_BASE = 0x10000
$bad = 0
foreach ($p in $man.patches) {
    if ($p.name -notlike 'hook-*') { continue }     # data patches need no alignment
    $lin = [uint32]($OBJ1_BASE + ([int]$p.offset - $orig.DataPagesOff))
    if (-not $orig.Valid($lin)) { continue }
    $len = ($p.expect.Length / 2)
    $covered = 0
    while ($covered -lt $len) {
        $ins = $origDis.Decode([uint32]($lin + $covered))
        $covered += $ins.Len
    }
    if ($covered -ne $len) {
        Write-Host ("  BAD {0}: patch is {1} bytes but covers {2} bytes of instructions" -f $p.name, $len, $covered) -ForegroundColor Red
        $bad++
    } else {
        Write-Host ("  ok  {0}: {1} bytes = whole instruction(s)" -f $p.name, $len) -ForegroundColor DarkGray
    }
}
if ($bad) { throw "$bad hook(s) do not align to instruction boundaries" }
Write-Host ""

$b = [System.IO.File]::ReadAllBytes($Exe)
foreach ($p in $man.patches) {
    $exp = FromHex $p.expect; $rep = FromHex $p.replace; $off = [int]$p.offset
    for ($i = 0; $i -lt $exp.Length; $i++) {
        if ($b[$off+$i] -ne $exp[$i]) { throw ("{0}: mismatch at +{1}" -f $p.name, $i) }
    }
    for ($i = 0; $i -lt $rep.Length; $i++) { $b[$off+$i] = $rep[$i] }
    Write-Host ("applied {0,-16} file 0x{1:X}  {2} bytes" -f $p.name, $off, $rep.Length)
}
[System.IO.File]::WriteAllBytes($out, $b)

if (-not ("LeTool.LeImage" -as [type])) {
    Add-Type -Path @("$PSScriptRoot\LeTool.cs","$PSScriptRoot\Disasm.cs","$PSScriptRoot\Analyzer.cs")
}
$img = New-Object LeTool.LeImage ($out)
$dis = New-Object LeTool.Disasm ($img)

Write-Host ""
Write-Host ("obj1 vsize 0x{0:X}   flags 0x{1:X}" -f $img.ObjSize[1], $img.ObjFlags[1])

$names = @{}
foreach ($s in $man.symbols) { $names[[uint32]$s.linear] = $s.name }

function Dump([uint32]$addr, [int]$n, [string]$title) {
    Write-Host ""; Write-Host "=== $title ===" -ForegroundColor Cyan
    $a = [uint32]$addr
    for ($i = 0; $i -lt $n; $i++) {
        if (-not $img.Valid($a)) { break }
        $ins = $dis.Decode($a)
        $by  = ($img.Slice($a,[Math]::Min($ins.Len,8)) | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        $lbl = ""; if ($names.ContainsKey([uint32]$a)) { $lbl = $names[[uint32]$a] + ":" }
        $tgt = ""; if ($ins.HasTarget -and $names.ContainsKey([uint32]$ins.Target)) { $tgt = "   ; -> " + $names[[uint32]$ins.Target] }
        Write-Host ("{0,-16}{1:X8}  {2,-22}  {3}{4}" -f $lbl, $a, $by, $ins.Text, $tgt)
        $a = [uint32]($a + $ins.Len)
    }
}

# hook sites come from the manifest note text; cave comes from caveBase
Dump 0x13DC8 3  "frame hook (must be a 2-byte jmp clearing the fixups at +3/+13)"
Dump 0x13DD9 1  "  landing site: the injected call"
Dump 0x15E41 1  "RMB down"
Dump 0x15E59 1  "RMB up"
Dump 0x15E7E 1  "key down"
Dump ([uint32]$man.caveBase) 60 "injected stub"

Write-Host ""
Write-Host "If every branch above resolves to a named symbol and no game bytes were" -ForegroundColor DarkGray
Write-Host "clobbered by a relocation, the patch is structurally sound." -ForegroundColor DarkGray
Remove-Item $out -Force
