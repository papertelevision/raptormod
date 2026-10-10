# Probe-Mp4.ps1 -- read an MP4's video geometry and frame count WITHOUT decoding it.
#
#   .\tools\Probe-Mp4.ps1 -Path <file.mp4>
#   .\tools\Probe-Mp4.ps1 -Dir  <folder>
#
# Decoding a 2560x1920 clip just to count its frames means holding ~19.7 MB per frame, so a
# 2,000-frame movie would want 39 GB. The container already carries everything needed:
# walk moov -> trak, take the track whose hdlr is 'vide', and read
#   stsd  the VisualSampleEntry's width/height
#   stsz  the sample count = frame count
#
# Offsets that are easy to get wrong, hence spelled out:
#   stsd  +8 version/flags, +12 entry_count, so the sample entry starts at +16.
#         Inside it: 8 size/type, 6 reserved, 2 data_ref, 2 pre_defined, 2 reserved,
#         12 pre_defined[3] -> width at +32, height at +34 of the entry.
#         Absolute: stsd+48 and stsd+50.
#   stsz  +12 sample_size (0 = per-sample table), +16 sample_count.

[CmdletBinding()]
param([string]$Path, [string]$Dir)

$ErrorActionPreference = 'Stop'

function Probe-One {
    param([string]$file)
    $b = [IO.File]::ReadAllBytes($file)
    function U32([int]$o) { ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o+1] -shl 16) -bor ([uint32]$b[$o+2] -shl 8) -bor $b[$o+3] }
    function U16([int]$o) { ([int]$b[$o] -shl 8) -bor $b[$o+1] }
    function Typ([int]$o)  { [Text.Encoding]::ASCII.GetString($b, $o, 4) }

    $result = [pscustomobject]@{ File = (Split-Path $file -Leaf); W = 0; H = 0; Frames = 0; Audio = $false }
    $CONTAINERS = @('moov','trak','mdia','minf','stbl','edts','udta')

    # walk, remembering which handler the current trak declared
    $stack = New-Object System.Collections.Stack
    function Walk([int]$off, [int]$end, [string]$handler) {
        while ($off + 8 -le $end) {
            $size = [int](U32 $off)
            $type = Typ ($off + 4)
            if ($size -lt 8) { break }
            $inner = $off + 8
            switch ($type) {
                'hdlr' { $handler = Typ ($off + 16) }
                'stsd' {
                    if ($handler -eq 'vide' -and $script:res.W -eq 0) {
                        $script:res.W = U16 ($off + 48)
                        $script:res.H = U16 ($off + 50)
                    }
                }
                'stsz' {
                    if ($handler -eq 'vide' -and $script:res.Frames -eq 0) { $script:res.Frames = [int](U32 ($off + 16)) }
                    if ($handler -eq 'soun') { $script:res.Audio = $true }
                }
            }
            if ($CONTAINERS -contains $type) { $handler = Walk $inner ($off + $size) $handler }
            $off += $size
        }
        return $handler
    }
    $script:res = $result
    [void](Walk 0 $b.Length '')
    $result
}

if ($Dir) {
    $rows = @()
    foreach ($f in (Get-ChildItem $Dir -Filter '*.mp4' | Sort-Object Name)) { $rows += Probe-One $f.FullName }
    $rows
} elseif ($Path) {
    Probe-One $Path
} else { throw 'give -Path or -Dir' }
