# Export-AnimFrames.ps1 -- decode a .MOV to a PNG sequence.
#
#   .\tools\Export-AnimFrames.ps1 -Path MOV_INTRO.MOV -OutDir out
#   .\tools\Export-AnimFrames.ps1 -Path MOV_INTRO.MOV -OutDir out -Every 12
#   .\tools\Export-AnimFrames.ps1 -Path MOV_TOB.MOV -Verify          # decode, write nothing
#
# The format and the codec are documented in tools\AnimTool.cs; this is just the driver.
#
# READ THE VERIFY NUMBERS. A block codec fails quietly -- a wrong opcode length desynchronises
# the stream and the picture degrades over the following frames rather than throwing. Two
# figures catch that:
#
#   blocks accounted   every 4x4 block should be written or explicitly skipped exactly once.
#                      100% means the control stream was consumed exactly as the engine
#                      consumes it. Slightly under means the delta stream ran out early and
#                      the remaining blocks were left unchanged, which is benign; well under
#                      means desynchronisation.
#   out of range       motion vectors pointing outside the padded buffer. Should be 0.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$OutDir,
    [int]$MaxFrames = 0,
    [int]$Every = 1,
    [switch]$Verify,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path (Split-Path -Parent $PSCommandPath) 'LoadAnim.ps1')
if (-not $Verify -and -not $OutDir) { throw 'give -OutDir, or -Verify to decode without writing' }

$anim = New-Object AztTool.Anim ($Path)
$stem = [IO.Path]::GetFileNameWithoutExtension($Path)
if ($OutDir -and -not $Verify) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

$sw = [Diagnostics.Stopwatch]::StartNew()
$n = 0; $written = 0
while ($anim.NextFrame()) {
    if (-not $Verify -and ($n % $Every) -eq 0) {
        $anim.SavePng((Join-Path $OutDir ("{0}-{1:d5}.png" -f $stem, $n)))
        $written++
    }
    $n++
    if ($MaxFrames -gt 0 -and $n -ge $MaxFrames) { break }
}
$sw.Stop()

$bw = [Math]::Ceiling($anim.Width / 4)
$bh = [Math]::Ceiling($anim.Height / 4)
$perFrame = $bw * $bh
$deltaFrames = [Math]::Max(1, $n - 1)
$accounted = ($anim.OpCount0 + $anim.OpCount2 + $anim.OpCount3 + $anim.BlocksSkipped) / [double]$deltaFrames
$pct = $accounted / $perFrame

$colour = if ($pct -ge 0.995 -and $anim.OutOfRange -eq 0) { 'Green' } else { 'Yellow' }
Write-Host ("{0,-14} {1,4}/{2,-4} frames  {3}x{4}  {5,6:N0} ms" -f `
            (Split-Path $Path -Leaf), $n, $anim.Frames, $anim.Width, $anim.Height, $sw.ElapsedMilliseconds)
if (-not $Quiet) {
    Write-Host ("   ops: mv-long {0,7:N0}  mv-packed {1,7:N0}  literal {2,9:N0}  skip-run {3,7:N0}  blocks skipped {4,10:N0}" -f `
                $anim.OpCount0, $anim.OpCount2, $anim.OpCount3, $anim.OpCount1, $anim.BlocksSkipped)
}
Write-Host ("   blocks accounted {0,8:N1} of {1,6:N0} per frame ({2:P2})   out of range {3}" -f `
            $accounted, $perFrame, $pct, $anim.OutOfRange) -ForegroundColor $colour
if ($written) { Write-Host ("   {0} PNG(s) -> {1}" -f $written, $OutDir) }
