@echo off
REM Play-HostRender-TrueColour.cmd -- the same as Play-HostRender.cmd, but the 3D view is shown
REM in the renderer's own window laid over the game's viewport (true colour, phase 0), instead
REM of being pushed through the game's 256-colour screen. See tools\Overlay.cs.
REM -TcMaxPixels 5500000 (Josh, 2026-10-08): the 3D drawn at up to 5.5 M pixels (on 4K a 1.2x stretch, was 1.58x at 3.2 M)
call "%~dp0Play-HostRender.cmd" -TrueColour -TcMaxPixels 5500000 %*