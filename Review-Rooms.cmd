@echo off
REM Review-Rooms.cmd -- double-click to look round any room in 3D in your browser, WITHOUT the game, and leave notes.
REM
REM Click any point on a room to leave a note there (what to change: a light here, thicker fog, a texture...). Notes are
REM saved in C:\Games\RaptorMod\cache\room-notes, where Claude reads them, makes the changes, and replies on the note.
REM
REM It runs a small server on this PC only (http://localhost:8642). Close this window to stop it.
REM The path is quoted because this lives under "Program Files (x86)".
title AztMod room review
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-RoomReview.ps1" %*
echo.
echo Room review has stopped.
pause
