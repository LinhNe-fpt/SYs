@echo off
rem Double-click de chay scan-once.ps1 (chi quet, KHONG xoa gi). Khong hoi gi.
chcp 65001 >nul
set "PSW_OPEN_RESULT=1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan-once.ps1" %*
echo.
echo Cua so se tu dong sau 10 giay. Ket qua da mo trong Explorer.
timeout /t 10 /nobreak >nul
