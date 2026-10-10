@echo off
REM Watch-HostRender.cmd -- double-click this, then start the game whenever you like.
REM
REM It does NOT launch the game. It waits for one, takes over the 3D viewport, follows the
REM player from room to room, and goes back to waiting when the game exits. Leave it running
REM across as many sessions as you want; Ctrl-C in this window stops it and hands the
REM viewport back to the engine.
REM
REM Arguments pass straight through:   Watch-HostRender.cmd -Light
REM                                    Watch-HostRender.cmd -Uncap
REM
REM The path is quoted because this lives under "Program Files (x86)" -- unquoted,
REM powershell -File takes "C:\Program" as the script name and exits immediately.
title AztMod host renderer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Watch-HostRender.ps1" %*
echo.
echo The host renderer has stopped.
pause
