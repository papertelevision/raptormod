@echo off
REM Install-Update.cmd -- applies the latest AztMod build to the modded game. Close the game first.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Apply-Delta.ps1"
pause
