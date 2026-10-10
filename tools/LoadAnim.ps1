# LoadAnim.ps1 -- compile the whole animation toolchain in one go.
#
#   . "$PSScriptRoot\LoadAnim.ps1"
#
# Add-Type compiles a SET of files into one assembly, and a type can only be defined once
# per session. So if one script loads {AzfTool, AnimTool} and another then asks for
# {AzfTool, AnimTool, AnimEncoder}, the second fails with "the type name 'AztTool.AzfTexture'
# already exists" -- the shared files collide even though the new one is genuinely missing.
#
# Every animation script therefore loads the SAME union through here, guarded on the type
# from the last file in the list. Whichever script runs first compiles everything; the rest
# short-circuit.
$script:__animToolDir = $PSScriptRoot
Add-Type -AssemblyName System.Drawing
if (-not ("AztTool.AviWriter" -as [type])) {
    Add-Type -Path @(
        (Join-Path $PSScriptRoot 'AzfTool.cs')
        (Join-Path $PSScriptRoot 'AnimTool.cs')
        (Join-Path $PSScriptRoot 'AnimEncoder.cs')
        (Join-Path $PSScriptRoot 'AviWriter.cs')
        (Join-Path $PSScriptRoot 'Mp4Reader.cs')
    ) -ReferencedAssemblies System.Drawing
}
if (-not ("LeTool.Quant" -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Quantize.cs') -ReferencedAssemblies System.Drawing
}
