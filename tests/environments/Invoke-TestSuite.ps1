#Requires -Version 5.1
<#
.SYNOPSIS
    Chạy toàn bộ test suite trong một môi trường cách ly.

.DESCRIPTION
    Script này là "một cửa" để chạy test ở bất kỳ đâu: máy dev, ổ phụ,
    Windows Sandbox, hay VM. Nó KHÔNG tự tạo môi trường ảo - việc đó do
    các script khác trong thư mục này làm (xem README.md).

    Điểm quan trọng: mọi thứ ghi ra đĩa đều nằm dưới -WorkDir (mặc định là
    thư mục tạm trong repo), KHÔNG đụng tới dữ liệu thật của máy.

.PARAMETER WorkDir
    Nơi đặt fixtures, log, sandbox của test. Mặc định: <repo>\tests\.work

.PARAMETER ResultPath
    File XML kết quả (NUnit) để máy khác đọc lại.

.PARAMETER Suite
    Unit | Integration | All (mặc định All).

.PARAMETER MinimumPesterVersion
    Pester tối thiểu. Pester 5+ là bắt buộc (Pester 3.4 có sẵn trên Win10
    không hỗ trợ -ForEach / cấu hình mới).

.EXAMPLE
    .\Invoke-TestSuite.ps1 -WorkDir D:\psw-testwork

.EXAMPLE
    .\Invoke-TestSuite.ps1 -Suite Unit -ResultPath D:\results\nunit.xml
#>
[CmdletBinding()]
param(
    [string]$WorkDir,
    [string]$ResultPath,
    [ValidateSet('Unit', 'Integration', 'All')]
    [string]$Suite = 'All',
    [string]$MinimumPesterVersion = '5.0.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$environmentsRoot = $PSScriptRoot
# Script này nằm ở tests\environments\, nên tests\ là thư mục cha.
$testsRoot = Split-Path $environmentsRoot -Parent
$repoRoot = Split-Path $testsRoot -Parent

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Join-Path $testsRoot '.work'
}

# Phải tuyệt đối: New-TestFixture ghi bằng [System.IO.Directory]::CreateDirectory,
# API này KHÔNG hiểu path tương đối kiểu '.\tests\.work' trong mọi ngữ cảnh.
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 70)
    Write-Host "  $Text"
    Write-Host ('=' * 70)
}

# ---------------------------------------------------------------------------
# 1. Tiền điều kiện
# ---------------------------------------------------------------------------
Write-Section 'Môi trường'

Write-Host ("PowerShell     : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Host ("OS             : {0}" -f [Environment]::OSVersion.VersionString)
Write-Host ("64-bit process : {0}" -f [Environment]::Is64BitProcess)
Write-Host ("Repo           : {0}" -f $repoRoot)
Write-Host ("WorkDir        : {0}" -f $WorkDir)
Write-Host ("Admin          : {0}" -f (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))

# Pester
$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]$MinimumPesterVersion } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $pester) {
    Write-Host ''
    Write-Host 'Pester >= 5.0 chưa có. Đang cài vào CurrentUser (không cần admin)...'
    try {
        Get-PackageProvider -Name NuGet -ForceBootstrap -ErrorAction Stop | Out-Null
        Install-Module Pester -MinimumVersion $MinimumPesterVersion -Scope CurrentUser -Force -SkipPublisherCheck -Confirm:$false -ErrorAction Stop
        $pester = Get-Module -ListAvailable -Name Pester |
            Where-Object { $_.Version -ge [version]$MinimumPesterVersion } |
            Sort-Object Version -Descending |
            Select-Object -First 1
    } catch {
        Write-Host "CÀI PESTER THẤT BẠI: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Nếu máy không có mạng, tải thủ công: https://www.powershellgallery.com/packages/Pester'
        exit 2
    }
}

if ($null -eq $pester) {
    Write-Host 'Không có Pester >= 5.0. Dừng.' -ForegroundColor Red
    exit 2
}

Write-Host ("Pester         : {0}" -f $pester.Version)
Import-Module $pester.Path -Force

# ---------------------------------------------------------------------------
# 2. Chuẩn bị WorkDir
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $WorkDir)) {
    [void][System.IO.Directory]::CreateDirectory($WorkDir)
}
$env:PRESALE_WIPER_TEST_WORK = $WorkDir
Write-Host ''
Write-Host ("PRESALE_WIPER_TEST_WORK = {0}" -f $env:PRESALE_WIPER_TEST_WORK)

# ---------------------------------------------------------------------------
# 3. Chọn đường dẫn test
# ---------------------------------------------------------------------------
$runPaths = switch ($Suite) {
    'Unit' { @(Join-Path $testsRoot 'Unit') }
    'Integration' { @(Join-Path $testsRoot 'Integration') }
    default { @((Join-Path $testsRoot 'Unit'), (Join-Path $testsRoot 'Integration')) }
}

$existingPaths = @($runPaths | Where-Object { Test-Path -LiteralPath $_ })
if ($existingPaths.Count -eq 0) {
    Write-Host 'Không tìm thấy thư mục test.' -ForegroundColor Red
    exit 2
}

Write-Host ("Suite          : {0}" -f $Suite)
foreach ($path in $existingPaths) { Write-Host ("  - {0}" -f $path) }

# ---------------------------------------------------------------------------
# 4. Sinh fixtures trước (nếu chưa có)
# ---------------------------------------------------------------------------
$fixtures = Join-Path $WorkDir 'fixtures'
if (-not (Test-Path -LiteralPath $fixtures)) {
    Write-Host ''
    Write-Host 'Sinh fixtures...'
    # Script PowerShell thuần (không phải exe) nên KHÔNG dùng $LASTEXITCODE;
    # kiểm tra bằng chính sự tồn tại của kết quả.
    & (Join-Path $testsRoot 'New-TestFixture.ps1') -Destination $fixtures -IncludeLongPath

    if (-not (Test-Path -LiteralPath $fixtures)) {
        Write-Host 'Sinh fixtures thất bại.' -ForegroundColor Red
        exit 2
    }
}

# ---------------------------------------------------------------------------
# 5. Chạy
# ---------------------------------------------------------------------------
Write-Section "Chạy $Suite test"

$configuration = New-PesterConfiguration
$configuration.Run.Path = $existingPaths
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
$configuration.Output.CIFormat = 'None'

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $parent = Split-Path $ResultPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = $ResultPath
    Write-Host ("Kết quả XML    : {0}" -f $ResultPath)
}

$result = Invoke-Pester -Configuration $configuration

# ---------------------------------------------------------------------------
# 6. Tổng kết
# ---------------------------------------------------------------------------
Write-Section 'Tổng kết'

Write-Host ("Passed  : {0}" -f $result.PassedCount)
Write-Host ("Failed  : {0}" -f $result.FailedCount)
Write-Host ("Skipped : {0}" -f $result.SkippedCount)
Write-Host ("Total   : {0}" -f $result.TotalCount)
Write-Host ("Duration: {0:N1}s" -f $result.Duration.TotalSeconds)

if ($result.FailedCount -gt 0) {
    Write-Host ''
    Write-Host 'Các test thất bại:' -ForegroundColor Red
    foreach ($test in $result.Failed) {
        Write-Host ("  - {0}.{1}" -f $test.Block.BlockContainer.Name, $test.ExpandedName) -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($test.ErrorRecord.Exception.Message)) {
            Write-Host ("      {0}" -f $test.ErrorRecord.Exception.Message) -ForegroundColor DarkGray
        }
    }
    exit 1
}

Write-Host ''
Write-Host 'TẤT CẢ TEST ĐỀU PASS' -ForegroundColor Green
exit 0
