# Query helpers. Requires load.ps1 to have been dot-sourced and AN explored.

function Find-Str ([string]$pattern) {
  foreach ($a in $AN.Strings) {
    $s = $AN.StringAt[$a]
    if ($s -match $pattern) { Write-Output ("0x{0}  `"{1}`"" -f $a.ToString("X"), $s) }
  }
}

function Addr-Of-Str ([string]$exact) {
  foreach ($a in $AN.Strings) { if ($AN.StringAt[$a] -ceq $exact) { return [uint32]$a } }
  return $null
}

# instruction sites that load this constant/address
function Refs ([uint32]$v) {
  if ($AN.ImmRefs.ContainsKey([uint32]$v)) { return $AN.ImmRefs[[uint32]$v] }
  return @()
}

# who calls this function
function Callers ([uint32]$fn) {
  if ($AN.CallSites.ContainsKey([uint32]$fn)) { return $AN.CallSites[[uint32]$fn] }
  return @()
}

# nearest discovered function start at or before addr
function FuncOf ([uint32]$a) { return $AN.FuncOf([uint32]$a) }

# disassemble a whole function (until ret at depth 0 / next func start)
function UF ([uint32]$fn, [int]$max = 400) {
  $a = [uint32]$fn
  for ($i = 0; $i -lt $max; $i++) {
    if (-not $IMG.Valid($a)) { break }
    $ins = $DIS.Decode($a)
    $bytes = ($IMG.Slice($a, [Math]::Min($ins.Len, 8)) | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    $note = ""
    foreach ($v in @($(if($ins.HasImm32){$ins.Imm32}), $(if($ins.HasDisp32){$ins.Disp32}))) {
      if ($null -ne $v -and $AN.StringAt.ContainsKey([uint32]$v)) { $note = '  ; "' + $AN.StringAt[[uint32]$v] + '"'; break }
    }
    if ($note -eq "" -and $ins.HasTarget -and $AN.CallTargets.Contains([uint32]$ins.Target)) { }
    $mark = if ($AN.CallTargets.Contains([uint32]$a) -and $a -ne $fn) { "*" } else { " " }
    Write-Output ("{0}{1:X8}  {2,-22}  {3}{4}" -f $mark, $a, $bytes, $ins.Text, $note)
    if ($ins.IsRet) { break }
    $a = [uint32]($a + $ins.Len)
  }
}

# Build a name table: function -> first string literal used inside it (Watcom error-macro idiom)
function Build-FuncNames {
  $names = @{}
  foreach ($fn in $AN.Functions()) {
    $ss = $AN.StringsInFunc([uint32]$fn, 3000)
    if ($ss.Count -gt 0) { $names[[uint32]$fn] = $ss }
  }
  return $names
}
