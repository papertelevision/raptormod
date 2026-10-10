# Read-CdImage.ps1 -- list or extract files from Azrael's AZT.BIN CD image.
#
#   .\tools\Read-CdImage.ps1                                   # list everything
#   .\tools\Read-CdImage.ps1 -Filter '\.ANM$'                  # just the movies
#   .\tools\Read-CdImage.ps1 -Filter '\.ANM$' -OutDir C:\tmp   # and extract them
#
# AZT.BIN IS RAW 2352-BYTE SECTORS, NOT A COOKED 2048-BYTE ISO. A .bin paired with a .cue
# usually is, and the difference bites immediately: the ISO9660 "CD001" signature sits at
# sector 16 offset 1 in a cooked image and at sector 16 offset 17 in a raw MODE1 one,
# because each raw sector begins with a 12-byte sync pattern and a 4-byte header. Treat it
# as cooked and nothing parses. The file length checks out exactly: 511,023,744 / 2352 =
# 217,272 sectors with no remainder, while /2048 leaves a fraction.
#
# So every read is: sector * 2352 + 16, for 2048 bytes of user data.

[CmdletBinding()]
param(
    [string]$Image = 'C:\Games\AzraelsTear-Modded\AZT.BIN',
    [string]$Filter,          # regex against the full path inside the image
    [string]$OutDir,          # extract when given
    # Emit the matched entries as objects instead of only printing them. The listing is
    # capped at 60 rows for readability, which is fine for a look but useless for comparing
    # the disc against the installed tree -- that needs all of them.
    [switch]$PassThru,
    [int]$SectorSize = 2352,
    [int]$DataOffset = 16,
    [int]$DataSize = 2048
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Image)) { throw "no such image: $Image" }
$fs = [IO.File]::OpenRead($Image)

function ReadSector { param([int]$lba)
    $fs.Seek([int64]$lba * $SectorSize + $DataOffset, 'Begin') | Out-Null
    $b = New-Object byte[] $DataSize
    [void]$fs.Read($b, 0, $DataSize)
    ,$b }
function ReadRange { param([int]$lba, [int]$length)
    # a file spans consecutive sectors; the raw layout means they are NOT contiguous in the
    # file, so each 2048-byte chunk has to be lifted out of its own 2352-byte sector
    $out = New-Object byte[] $length
    $done = 0; $s = $lba
    while ($done -lt $length) {
        $chunk = ReadSector $s
        $n = [Math]::Min($DataSize, $length - $done)
        [Array]::Copy($chunk, 0, $out, $done, $n)
        $done += $n; $s++
    }
    ,$out }

$pvd = ReadSector 16
if ([Text.Encoding]::ASCII.GetString($pvd, 1, 5) -ne 'CD001') {
    $fs.Close(); throw "no CD001 at sector 16 -- wrong sector size or not ISO9660"
}
$volume = ([Text.Encoding]::ASCII.GetString($pvd, 40, 32)).Trim()
$rootLba = [BitConverter]::ToUInt32($pvd, 156 + 2)
$rootLen = [BitConverter]::ToUInt32($pvd, 156 + 10)
Write-Host ("{0}: volume '{1}', root at LBA {2}, {3:N0} bytes" -f (Split-Path $Image -Leaf), $volume, $rootLba, $rootLen)

$files = New-Object System.Collections.ArrayList

function WalkDir { param([int]$lba, [int]$len, [string]$path, [int]$depth)
    if ($depth -gt 8) { return }
    $data = ReadRange $lba $len
    $p = 0
    while ($p -lt $data.Length) {
        $rl = $data[$p]
        if ($rl -eq 0) {
            # records never straddle a sector; a zero length means skip to the next one
            $next = [Math]::Floor($p / $DataSize) * $DataSize + $DataSize
            if ($next -le $p) { break }
            $p = $next
            if ($p -ge $data.Length) { break }
            continue
        }
        $ext = [BitConverter]::ToUInt32($data, $p + 2)
        $dl  = [BitConverter]::ToUInt32($data, $p + 10)
        $flags = $data[$p + 25]
        $nl = $data[$p + 32]
        $name = [Text.Encoding]::ASCII.GetString($data, $p + 33, $nl)
        $p += $rl
        if ($nl -eq 1 -and ($data[$p - $rl + 33] -eq 0 -or $data[$p - $rl + 33] -eq 1)) { continue }  # . and ..
        $clean = ($name -split ';')[0]
        if ($flags -band 2) {
            WalkDir ([int]$ext) ([int]$dl) ("$path$clean\") ($depth + 1)
        } else {
            [void]$files.Add([pscustomobject]@{ Path = "$path$clean"; Lba = [int]$ext; Size = [int]$dl })
        }
    }
}

WalkDir ([int]$rootLba) ([int]$rootLen) '' 0
Write-Host ("{0:N0} files in the image" -f $files.Count)

$sel = if ($Filter) { @($files | Where-Object { $_.Path -match $Filter }) } else { @($files) }
Write-Host ("{0:N0} matched{1}" -f $sel.Count, $(if ($Filter) { " /$Filter/" } else { '' }))
if (-not $PassThru) {
    $sel | Sort-Object { -$_.Size } | Select-Object -First 60 |
        ForEach-Object { Write-Host ("  {0,-34} {1,12:N0} bytes   LBA {2}" -f $_.Path, $_.Size, $_.Lba) }
    if ($sel.Count -gt 60) { Write-Host ("  ... and {0} more" -f ($sel.Count - 60)) }
}
Write-Host ("total matched: {0:N0} bytes ({1:N1} MB)" -f (($sel | Measure-Object Size -Sum).Sum), ((($sel | Measure-Object Size -Sum).Sum)/1MB))

if ($OutDir) {
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    foreach ($f in $sel) {
        $dest = Join-Path $OutDir ($f.Path -replace '[\\/]','_')
        [IO.File]::WriteAllBytes($dest, (ReadRange $f.Lba $f.Size))
        Write-Host ("  extracted {0} ({1:N0} bytes)" -f (Split-Path $dest -Leaf), $f.Size)
    }
}
$fs.Close()
if ($PassThru) { $sel }
