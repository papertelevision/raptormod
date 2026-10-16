@echo off
REM Play-HostRender.cmd -- one click: the game AND the host renderer.
REM
REM Runs the host renderer in this (minimised) window; once it is ready it starts Azrael's Tear
REM from the modded copy and renders that one session. When the game closes, the renderer hands the viewport
REM back, restores the frame cap and movement step, and this window closes itself.
REM
REM Nothing here is needed to play: with no renderer running the game simply draws for
REM itself, as it always did. Play-Azrael-Modded.bat in the game folder is still that.
REM
REM Arguments pass through to the renderer:   Play-HostRender.cmd -KeepCap
REM                                           Play-HostRender.cmd -NoFpsCounter -SaveFrames 5
REM
REM If something goes wrong, the renderer's log is <root>\cache\watch.log (C:\Games\RaptorMod in the dev layout), and
REM AztMod\Watch-HostRender.cmd still runs the renderer on its own, visibly, for any game.

REM Re-launch minimised, so the renderer's window is not sitting over the game.
REM GOTO, NOT A PARENTHESISED BLOCK: this file's own path contains "(x86)", and inside an
REM IF ( ... ) block that closing parenthesis ends the block wherever the path is expanded.
if defined AZT_HOSTRENDER_MIN goto run
set AZT_HOSTRENDER_MIN=1
if defined AZT_DRYRUN goto run
start "AztMod host renderer" /min cmd /c call "%~f0" %*
exit /b

:run
title AztMod host renderer
REM The install's root: RAPTORMOD_ROOT when a release launcher set it, else the dev layout. (No IF block: a root
REM may hold "(x86)" too.)
REM (a release: this file is <root>\app\Play-HostRender.cmd and <root>\raptormod-root.txt marks the install -- found from here
REM when a shortcut did not set RAPTORMOD_ROOT, e.g. the game folder's Play-Azrael-Modded.bat)
if not defined RAPTORMOD_ROOT if exist "%~dp0..\raptormod-root.txt" for %%I in ("%~dp0..") do set "RAPTORMOD_ROOT=%%~fI"
set "RMROOT=C:\Games\RaptorMod"
if defined RAPTORMOD_ROOT set "RMROOT=%RAPTORMOD_ROOT%"
set "GAME=%RMROOT%\game"
if not exist "%GAME%\DOSBOX-STAGING\dosbox.exe" goto nogame

REM AZT_DRYRUN=1 checks every step of this file without starting the game or the renderer.
if defined AZT_DRYRUN goto dry

REM Starting a second game beside one that is already up gives two DOSBoxes and a renderer
REM attached to whichever it finds first. Say so instead.
tasklist /FI "IMAGENAME eq dosbox.exe" 2>nul | find /I "dosbox.exe" >nul
if not errorlevel 1 (
    echo A DOSBox is already running. Close the game first, then start this again.
    pause
    exit /b 1
)

REM THE RENDERER FIRST, AND IT STARTS THE GAME (-Launch) once everything it can prepare without
REM the game is ready -- so the picture window and the host's own boot animation are up before the
REM game's boot begins (Josh, 2026-10-07). Same DOSBox command line as Play-Azrael-Modded.bat.
REM The path is quoted because this lives under "Program Files (x86)" -- unquoted,
REM powershell -File takes "C:\Program" as the script.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Watch-HostRender.ps1" -Once -Launch -GameDir "%GAME%" %*
if errorlevel 1 goto failed
goto :eof

:nogame
echo The modded game was not found at %GAME%.
echo Run the RaptorMod installer (or Apply-AztMod.ps1) first.
pause
exit /b 1

:failed
echo.
echo The host renderer stopped with an error. See %RMROOT%\cache\watch.log
pause
goto :eof

:dry
echo DRY RUN: would run powershell -File "%~dp0tools\Watch-HostRender.ps1" -Once -Launch -GameDir "%GAME%" %*
echo DRY RUN: ...which starts "%GAME%\DOSBOX-STAGING\dosbox.exe" --noprimaryconf --nolocalconf --conf azrael-staging.conf --conf azrael-game.conf
if exist "%~dp0tools\Watch-HostRender.ps1" (echo DRY RUN: renderer script found) else (echo DRY RUN: RENDERER SCRIPT MISSING)
