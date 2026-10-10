# Read-Anim.ps1 -- parse Azrael's .MOV (IAnimation) container.
#
#   .\tools\Read-Anim.ps1 -Path ...\MOV_LIBEMPTY.MOV
#   .\tools\Read-Anim.ps1 -Path ...\MOV_INTRO.MOV -MaxFrames 4 -Chunks
#
# THE LAYOUT IS READ OUT OF THE ENGINE, NOT GUESSED. R.EXE's IAnimation constructor sits at
# 0x2026C and DecodeAnimationFrame at 0x20A2C; between them they give the whole container:
#
#   FILE HEADER, 30 bytes (the constructor reads exactly 0x1E)
#     +0x00  u32  magic 0xAB12EF90      ; mismatch -> "Invalid animation header if file %s"
#     +0x04  u16  frame count           ; -> IAnimation+0x00
#     +0x06  u16  frames per second     ; -> IAnimation+0x04
#     +0x08  u16  width                 ; -> IAnimation+0x12
#     +0x0A  u16  height                ; -> IAnimation+0x14
#     +0x0C..+0x1D  not touched by the constructor
#
#   FRAME HEADER, 16 bytes
#     +0x00  u32  magic 0xEE9901CF
#     +0x04  u16  chunk count
#     +0x06  u32  decompressed size
#     +0x0A  u32  compressed size       ; ZERO means the payload is stored raw
#
#   then the payload, which is a run of CHUNKS:
#     +0x00  u32  magic 0x0123FEDC
#     +0x04  u16  type                  ; 1..7, dispatched through a table at 0x20A10
#     +0x06  u32  data size
#     +0x10  data
#
# THE PAYLOAD COMPRESSION IS THE ONE ALREADY SOLVED. DecodeAnimationFrame hands the staging
# buffer to 0x2D558 -- the same static-Huffman inflate the .RES textures use -- so
# AztTool.Azf.Inflate decodes it unchanged. That is most of the work already done.
#
# Chunk handlers, from the jump table:
#     1 -> 0x20470     4 -> 0x204B4     5 -> 0x20770
#     6 -> 0x207F0     7 -> 0x207F0 with a flag at 0x162FEA
#     2, 3 -> an error path; the shipped files should never contain them

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [int]$MaxFrames = 0,          # 0 = all
    [switch]$Chunks,              # list every chunk, not just a summary
    [string]$DumpDir              # write each frame's decompressed payload
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -AssemblyName System.Drawing
if (-not ("AztTool.Azf" -as [type])) { Add-Type -Path (Join-Path $toolDir 'AzfTool.cs') -ReferencedAssemblies System.Drawing }

# Convert::ToUInt32, NOT a hex literal. PowerShell parses 0xAB12EF90 as an Int32, and
# since the top bit is set that is NEGATIVE (-1424416368) -- so it never equals the UInt32
# that BitConverter returns, and the failure message prints the two as identical because
# {0:X8} formats both the same way.
$FILE_MAGIC  = [Convert]::ToUInt32('AB12EF90', 16)
$FRAME_MAGIC = [Convert]::ToUInt32('EE9901CF', 16)
$CHUNK_MAGIC = [Convert]::ToUInt32('0123FEDC', 16)

$data = [IO.File]::ReadAllBytes($Path)
if ($data.Length -lt 30) { throw "too short to be an animation" }
$m = [BitConverter]::ToUInt32($data, 0)
if ($m -ne $FILE_MAGIC) { throw ("bad file magic 0x{0:X8}, expected 0x{1:X8}" -f $m, $FILE_MAGIC) }

$frames = [BitConverter]::ToUInt16($data, 4)
$fps    = [BitConverter]::ToUInt16($data, 6)
$width  = [BitConverter]::ToUInt16($data, 8)
$height = [BitConverter]::ToUInt16($data, 10)
Write-Host ("{0}: {1} frames @ {2} fps, {3}x{4}  ({5:N0} bytes, {6:N1}s)" -f `
            (Split-Path $Path -Leaf), $frames, $fps, $width, $height, $data.Length, $(if ($fps) { $frames/$fps } else { 0 }))
Write-Host ("  header bytes 0x0C..0x1D: " + (($data[12..29] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))

if ($DumpDir) { New-Item -ItemType Directory -Force $DumpDir | Out-Null }

$pos = 30
$n = 0
$typeCount = @{}
$typeBytes = @{}
$rawFrames = 0
$firstPayload = $null

while ($pos + 16 -le $data.Length) {
    if ($MaxFrames -gt 0 -and $n -ge $MaxFrames) { break }
    $fm = [BitConverter]::ToUInt32($data, $pos)
    if ($fm -ne $FRAME_MAGIC) {
        Write-Host ("  frame {0}: bad magic 0x{1:X8} at 0x{2:X} -- stopping" -f $n, $fm, $pos) -ForegroundColor Yellow
        break
    }
    $nChunks = [BitConverter]::ToUInt16($data, $pos + 4)
    $rawSize = [int][BitConverter]::ToUInt32($data, $pos + 6)
    $cmpSize = [int][BitConverter]::ToUInt32($data, $pos + 10)
    $pos += 16

    if ($cmpSize -eq 0) {
        if ($pos + $rawSize -gt $data.Length) { Write-Host "  truncated raw payload" -ForegroundColor Yellow; break }
        $payload = New-Object byte[] $rawSize
        [Array]::Copy($data, $pos, $payload, 0, $rawSize)
        $pos += $rawSize
        $rawFrames++
    } else {
        try { $payload = [AztTool.Azf]::Inflate($data, $pos) }
        catch { Write-Host ("  frame {0}: inflate failed -- {1}" -f $n, $_.Exception.Message) -ForegroundColor Red; break }
        $pos += $cmpSize
    }
    if ($n -eq 0) { $firstPayload = $payload }
    if ($DumpDir) { [IO.File]::WriteAllBytes((Join-Path $DumpDir ("frame{0:d4}.bin" -f $n)), $payload) }

    # walk the chunks
    $cp = 0; $seen = @()
    for ($c = 0; $c -lt $nChunks -and $cp + 16 -le $payload.Length; $c++) {
        $cm = [BitConverter]::ToUInt32($payload, $cp)
        $ct = [BitConverter]::ToUInt16($payload, $cp + 4)
        $cs = [int][BitConverter]::ToUInt32($payload, $cp + 6)
        $bad = if ($cm -ne $CHUNK_MAGIC) { ' BADMAGIC' } else { '' }
        $seen += ("t{0}/{1:N0}{2}" -f $ct, $cs, $bad)
        if ($typeCount.ContainsKey([int]$ct)) { $typeCount[[int]$ct]++ ; $typeBytes[[int]$ct] += $cs }
        else { $typeCount[[int]$ct] = 1; $typeBytes[[int]$ct] = $cs }
        if ($Chunks) {
            Write-Host ("    frame {0,4} chunk {1}: type {2}  size {3,9:N0}  at +0x{4:X}{5}" -f $n, $c, $ct, $cs, $cp, $bad)
        }
        $cp += 16 + $cs
    }
    if (-not $Chunks -and $n -lt 6) {
        Write-Host ("  frame {0,4}: {1} chunk(s), raw {2,8:N0}, comp {3,8:N0}  [{4}]{5}" -f `
                    $n, $nChunks, $rawSize, $cmpSize, ($seen -join ' '), $(if ($payload.Length -ne $rawSize) { "  DECOMP={0:N0} != header" -f $payload.Length } else { '' }))
    }
    $n++
}

Write-Host ""
Write-Host ("parsed {0} of {1} frames, {2:N0} of {3:N0} bytes consumed" -f $n, $frames, $pos, $data.Length)
if ($rawFrames) { Write-Host ("  {0} frame(s) stored uncompressed" -f $rawFrames) }
Write-Host "chunk types seen:"
foreach ($k in ($typeCount.Keys | Sort-Object)) {
    $what = switch ($k) { 1 {'handler 0x20470'} 4 {'handler 0x204B4'} 5 {'handler 0x20770'}
                          6 {'handler 0x207F0'} 7 {'handler 0x207F0 + flag'} default {'UNSUPPORTED in the engine'} }
    Write-Host ("  type {0}: {1,6} chunks, {2,12:N0} bytes   {3}" -f $k, $typeCount[$k], $typeBytes[$k], $what)
}
if ($firstPayload) {
    Write-Host ("`nfirst frame payload {0:N0} bytes; first chunk's data begins:" -f $firstPayload.Length)
    $off = 16
    Write-Host ("  " + (($firstPayload[$off..([Math]::Min($off+47,$firstPayload.Length-1))] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
}
