#Requires -Version 5.1
<#
.SYNOPSIS
    presale-wiper - quét (và sau này là dọn) môi trường dev trên Windows.

.DESCRIPTION
    Wrapper mỏng quanh module presale-wiper. Chạy được mà không cần cài
    module: script tự import từ src/ cạnh nó.

    Mặc định là DRY-RUN: chỉ quét và liệt kê, không xoá gì.

.PARAMETER Command
    scan | verify | report | clean | help | version

.EXAMPLE
    .\presale-wiper.ps1 scan

.EXAMPLE
    .\presale-wiper.ps1 scan C:\Test -Quiet

.EXAMPLE
    .\presale-wiper.ps1 scan -JsonPath report.json

.NOTES
    Exit codes: 0 = OK, 1 = cảnh báo, 2 = lỗi, 3 = user cancel.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'scan',

    [Parameter(Position = 1, ValueFromRemainingArguments = $false)]
    [string[]]$Path = @(),

    [switch]$IncludeHome,
    [string[]]$Exclude = @(),
    [string]$MinSize,
    [int]$MaxDepth = -1,
    [switch]$NoSize,
    [switch]$Json,
    [string]$JsonPath,
    [string]$Log,
    [switch]$NoLog,
    [switch]$Quiet,
    [switch]$NoErrors,
    [switch]$Yes,
    [string]$FromLog,
    [int]$Tail = 0,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\presale-wiper.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Error "Không tìm thấy module tại $modulePath"
    [Environment]::ExitCode = 2
    return
}

Import-Module -Name $modulePath -Force -DisableNameChecking

if ($Help) {
    Get-PswUsage | Write-Output
    [Environment]::ExitCode = 0
    return
}

# Path rỗng -> để module tự chọn root mặc định.
$pathArgument = @()
if ($null -ne $Path) {
    $pathArgument = @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$arguments = @{
    Path        = $pathArgument
    IncludeHome = $IncludeHome
    Exclude     = @($Exclude)
    NoSize      = $NoSize
    Json        = $Json
    JsonPath    = $JsonPath
    Log         = $Log
    NoLog       = $NoLog
    Quiet       = $Quiet
    NoErrors    = $NoErrors
    Yes         = $Yes
    FromLog     = $FromLog
    Tail        = $Tail
}

if (-not [string]::IsNullOrWhiteSpace($MinSize)) { $arguments['MinSize'] = $MinSize }
if ($MaxDepth -ge 0) { $arguments['MaxDepth'] = $MaxDepth }

try {
    $exitCode = Invoke-PswCli -Command $Command -Arguments $arguments
} catch {
    Write-Host "LỖI KHÔNG MONG ĐỢI: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    $exitCode = 2
}

# Vì sao dùng [Environment]::ExitCode thay vì `exit`:
#   `exit` bên trong script được gọi (& script.ps1) sẽ ném ExitException và
#   HUỶ PIPELINE của caller. Hệ quả: mọi thứ script này ghi ra bằng
#   Write-Output (JSON, version, help...) bị mất trước khi tới stdout, trong
#   khi Write-Host thì vẫn tới được. Đó chính là kiểu lỗi "chạy đúng mà test
#   đọc được chuỗi rỗng".
#   [Environment]::ExitCode đặt mã thoát của tiến trình mà không cắt ngang
#   luồng output, nên output luôn được flush đầy đủ.
[Environment]::ExitCode = [int]$exitCode
