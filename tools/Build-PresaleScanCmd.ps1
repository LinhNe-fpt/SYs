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

    -Visible: bản có cửa sổ console, in kết quả màu xanh lá, chờ Enter để
    chuyển sang bước xoá (mô phỏng trước; xoá thật cần Enter lần nữa).

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
rem presale-wiper: quet TOAN BO PC va XOA LUON nhung gi tim thay.
chcp 65001 >nul
set "PSW_SELF=%~f0"
set "PSW_OPEN_RESULT=0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "__RUN__"
echo.
echo Da xong. Cua so se tu dong sau __SECONDS__ giay.
rem 'ping' thay cho 'timeout': timeout loi ngay khi stdin bi redirect
rem (vd khi chay tu script khac), con ping thi khong doc stdin.
ping -n __PINGS__ 127.0.0.1 >nul
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
$header = $header.Replace('__RUN__', $run).Replace('__SECONDS__', [string]$CloseAfterSeconds).Replace('__PINGS__', [string]([Math]::Max(2, $CloseAfterSeconds + 1)))

$body = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
$body = $body -replace '^#Requires[^\r\n]*\r?\n', ''

# Nhúng remove-once.ps1 vào cuối file (Base64) để presale-scan.cmd tự đủ:
# không cần mang theo file .ps1 nào khác.
$removePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'remove-once.ps1'
$embedded = ''
if ([System.IO.File]::Exists($removePath)) {
    $removeBytes = [IO.File]::ReadAllBytes($removePath)
    $encoded = [Convert]::ToBase64String($removeBytes)
    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $encoded.Length; $i += 120) {
        [void]$builder.AppendLine('# ' + $encoded.Substring($i, [Math]::Min(120, $encoded.Length - $i)))
    }
    $embedded = "`r`n# PSW_REMOVE_BASE64_BEGIN`r`n" + $builder.ToString() + '# PSW_REMOVE_BASE64_END' + "`r`n"
}

$text = ($header + "`n" + $body + $embedded) -replace "`r?`n", "`r`n"
[IO.File]::WriteAllText($Destination, $text, (New-Object System.Text.UTF8Encoding($false)))

Get-Item -LiteralPath $Destination
