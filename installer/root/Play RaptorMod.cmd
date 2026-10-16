@echo off
REM RaptorMod -- the true-colour (GPU) version. This folder is the install; the renderer starts the game.
for %%I in ("%~dp0.") do set "RAPTORMOD_ROOT=%%~fI"
call "%RAPTORMOD_ROOT%\app\Play-HostRender-TrueColour.cmd" %*
