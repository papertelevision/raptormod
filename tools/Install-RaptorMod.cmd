@echo off
REM Install-RaptorMod.cmd -- double-click on a PC with the Steam game: clones RaptorMod and sets it up from the asset pack
REM in THIS folder (it is copied next to the pack, e.g. on the NAS). See tools\Install-RaptorMod.ps1 and SETUP.md.
REM Add -DryRun to see what it would do:   Install-RaptorMod.cmd -DryRun
REM ("%~dp0." -- the folder with no trailing backslash, which would otherwise escape the closing quote)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RaptorMod.ps1" -AssetPack "%~dp0." %*
echo.
pause
