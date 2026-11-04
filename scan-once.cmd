@echo off
rem Double-click de chay scan-once.ps1 an (chi quet, KHONG xoa gi). Khong hoi gi.
set "PSW_OPEN_RESULT=1"
set "PSW_HIDDEN=1"
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scan-once.ps1" %*
