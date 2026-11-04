@echo off
rem Double-click de chay scan-once.ps1 (chi quet, KHONG xoa gi).
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan-once.ps1" %*
echo.
pause
