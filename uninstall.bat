@echo off
rem ZCode-TPS-Footer uninstaller entry (double-click me, after fully quitting ZCode)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
