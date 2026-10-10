@echo off
REM Play-HostRender-Capture.cmd -- the same as Play-HostRender.cmd, but the renderer also saves
REM the picture it drew every 2 seconds to C:\Games\azrael-render\frames, and logs the camera
REM and every moved object with each one, so a wrong-looking frame can be examined afterwards.
call "%~dp0Play-HostRender.cmd" -SaveFrames 2 %*
