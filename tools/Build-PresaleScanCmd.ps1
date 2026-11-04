#Requires -Version 5.1
<#
.SYNOPSIS
    Đóng gói scan-once.ps1 thành MỘT file presale-scan.cmd: double-click là chạy.

.DESCRIPTION
    Vài dòng đầu là batch (cmd.exe coi '<# : batch' là label nên bỏ qua), gọi
    PowerShell đọc lại chính file này và chạy phần còn lại. Với PowerShell, khối
    batch nằm trong một block comment nên bị bỏ qua.

    Không hỏi gì: quét xong tự mở thư mục kết quả trong Explorer, cửa sổ console
    tự đóng sau vài giây.

.EXAMPLE
    .\tools\Build-PresaleScanCmd.ps1
    .\tools\Build-PresaleScanCmd.ps1 -Destination "$env:USERPROFILE\Downloads\presale-scan.cmd"
#>
param(
    [string]$Source = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scan-once.ps1'),
    [string]$Destination = (Join-Path (Split-Path -Parent $PSScriptRoot) 'presale-scan.cmd'),
    [int]$CloseAfterSeconds = 10
)

$ErrorActionPreference = 'Stop'

# cmd.exe cần CRLF và KHÔNG được có BOM (BOM làm hỏng dòng đầu).
# Dot-source (không phải '&') để biến cấp script nằm đúng scope $script:.
$header = @'
<# : batch
@echo off
rem presale-wiper: quet TOAN BO PC, chi liet ke, KHONG XOA GI.
chcp 65001 >nul
set "PSW_SELF=%~f0"
set "PSW_OPEN_RESULT=1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". ([ScriptBlock]::Create([IO.File]::ReadAllText($env:PSW_SELF, [Text.Encoding]::UTF8))) %*"
echo.
echo Cua so se tu dong sau __SECONDS__ giay. Ket qua da mo trong Explorer.
timeout /t __SECONDS__ /nobreak >nul
exit /b
#>
'@
$header = $header.Replace('__SECONDS__', [string]$CloseAfterSeconds)

$body = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
$body = $body -replace '^#Requires[^\r\n]*\r?\n', ''

$text = ($header + "`n" + $body) -replace "`r?`n", "`r`n"
[IO.File]::WriteAllText($Destination, $text, (New-Object System.Text.UTF8Encoding($false)))

Get-Item -LiteralPath $Destination
