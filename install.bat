@echo off
rem ZCode-TPS-Footer installer entry (double-click me, after fully quitting ZCode)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
