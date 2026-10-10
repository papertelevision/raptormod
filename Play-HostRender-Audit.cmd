@echo off
REM Play-HostRender-Audit.cmd -- play as usual; whenever you stand still the renderer checks its
REM picture against the game's own and logs the result (C:\Games\azrael-render\audit).
call "%~dp0Play-HostRender.cmd" -Audit %*
