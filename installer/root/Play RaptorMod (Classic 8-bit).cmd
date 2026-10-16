@echo off
REM RaptorMod in the game's own 8-bit picture: for PCs whose graphics card cannot run the true-colour version.
for %%I in ("%~dp0.") do set "RAPTORMOD_ROOT=%%~fI"
call "%RAPTORMOD_ROOT%\app\Play-HostRender.cmd" -Retro %*
