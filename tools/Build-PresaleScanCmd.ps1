#Requires -Version 5.1
<#
.SYNOPSIS
    Đóng gói scan-once.ps1 thành MỘT file presale-scan.cmd: double-click là chạy.

.DESCRIPTION
    Vài dòng đầu là batch (cmd.exe coi '<# : batch' là label nên bỏ qua), gọi
    PowerShell đọc lại chính file này và chạy phần còn lại. Với PowerShell, khối
    batch nằm trong một block comment nên bị bỏ qua.

    Không hỏi gì, không hiện cửa sổ: cmd.exe khởi động PowerShell ẩn rồi thoát
    ngay; quét xong tự mở thư mục kết quả trong Explorer. Lỗi (nếu có) hiện bằng
    hộp thoại. Tiến trình vẫn thấy trong Task Manager (powershell.exe).

    -Visible: bản có cửa sổ console, in tổng kết rồi tự đóng sau
    -CloseAfterSeconds giây (dùng khi cần xem log).

.EXAMPLE
    .\tools\Build-PresaleScanCmd.ps1
    .\tools\Build-PresaleScanCmd.ps1 -Destination "$env:USERPROFILE\Downloads\presale-scan.cmd"
    .\tools\Build-PresaleScanCmd.ps1 -Visible -CloseAfterSeconds 5
#>
param(
    [string]$Source = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scan-once.ps1'),
    [string]$Destination = (Join-Path (Split-Path -Parent $PSScriptRoot) 'presale-scan.cmd'),
    [switch]$Visible,
    [int]$CloseAfterSeconds = 10
)

$ErrorActionPreference = 'Stop'

# cmd.exe cần CRLF và KHÔNG được có BOM (BOM làm hỏng dòng đầu).
# Dot-source (không phải '&') để biến cấp script nằm đúng scope $script:.
$run = '. ([ScriptBlock]::Create([IO.File]::ReadAllText($env:PSW_SELF, [Text.Encoding]::UTF8))) %*'

$header = if ($Visible) {
    @'
<# : batch
@echo off
rem presale-wiper: quet TOAN BO PC, chi liet ke, KHONG XOA GI.
chcp 65001 >nul
set "PSW_SELF=%~f0"
set "PSW_OPEN_RESULT=1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "__RUN__"
echo.
echo Cua so se tu dong sau __SECONDS__ giay. Ket qua da mo trong Explorer.
timeout /t __SECONDS__ /nobreak >nul
exit /b
#>
'@
} else {
    # 'start ""' không chờ: cmd.exe thoát ngay, chỉ còn PowerShell chạy ẩn.
    @'
<# : batch
@echo off
rem presale-wiper: quet TOAN BO PC chay an, chi liet ke, KHONG XOA GI.
set "PSW_SELF=%~f0"
set "PSW_OPEN_RESULT=1"
set "PSW_HIDDEN=1"
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "__RUN__"
exit /b
#>
'@
}
$header = $header.Replace('__RUN__', $run).Replace('__SECONDS__', [string]$CloseAfterSeconds)

$body = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
$body = $body -replace '^#Requires[^\r\n]*\r?\n', ''

$text = ($header + "`n" + $body) -replace "`r?`n", "`r`n"
[IO.File]::WriteAllText($Destination, $text, (New-Object System.Text.UTF8Encoding($false)))

Get-Item -LiteralPath $Destination
