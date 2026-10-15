@echo off
REM Play-HostRender-Audit.cmd -- play as usual; whenever you stand still the renderer checks its
REM picture against the game's own and logs the result (C:\Games\RaptorMod\cache\audit).
call "%~dp0Play-HostRender.cmd" -Audit %*
