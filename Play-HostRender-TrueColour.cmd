@echo off
REM Play-HostRender-TrueColour.cmd -- the same as Play-HostRender.cmd, but the 3D view is shown
REM in the renderer's own window laid over the game's viewport (true colour, phase 0), instead
REM of being pushed through the game's 256-colour screen. See tools\Overlay.cs.
REM The 3D is drawn at up to 5.5 M pixels (Josh, 2026-10-08: on 4K a 1.2x stretch). Since 2026-10-15 that is the renderer's default;
REM a slower PC sets "tcMaxPixels" lower in raptormod-settings.json in the game folder.
call "%~dp0Play-HostRender.cmd" -TrueColour %*