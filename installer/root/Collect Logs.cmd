@echo off
REM Collect Logs -- zips RaptorMod's logs to your Desktop, to attach to a bug report.
for %%I in ("%~dp0.") do set "RAPTORMOD_ROOT=%%~fI"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\tools\Collect-Logs.ps1"
pause