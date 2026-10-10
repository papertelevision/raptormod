@echo off
rem  Play-Azrael-Staging.bat
rem
rem  No arguments            -> use azrael-staging.conf as-is.
rem  First argument is --    -> every argument is forwarded to dosbox verbatim:
rem                               Play-Azrael-Staging.bat --set vsync=on --set presentation_mode=host-rate
rem                               Play-Azrael-Staging.bat --set cpu_cycles_protected=500000
rem  Otherwise               -> [shader] [dedither-strength], e.g.
rem                               Play-Azrael-Staging.bat nearest
rem                               Play-Azrael-Staging.bat scaler/xbr-lv3 0
cd /d "%~dp0"
set OVR=
set FIRST=%~1
if "%FIRST:~0,2%"=="--" goto passthru
if not "%~1"=="" set OVR=--set shader=%~1
if not "%~2"=="" set OVR=%OVR% --set dedithering=%~2
start "" /W /B DOSBOX-STAGING\dosbox.exe --noprimaryconf --nolocalconf --conf azrael-staging.conf --conf azrael-game.conf %OVR%
goto :eof
:passthru
start "" /W /B DOSBOX-STAGING\dosbox.exe --noprimaryconf --nolocalconf --conf azrael-staging.conf --conf azrael-game.conf %*
