#Requires -Version 5.1
<#
.SYNOPSIS
    Chạy test trong Windows Sandbox - VM dùng-một-lần, cách ly hoàn toàn.

.DESCRIPTION
    Windows Sandbox là container/VM nhẹ của Microsoft: mỗi lần bật là một
    Windows sạch, mọi thay đổi bị xoá khi đóng cửa sổ. Đây là môi trường
    gần nhất với "máy lạ" mà không cần cài VM thật.

    Script này (chạy trên host) làm 3 việc:
      1. Kiểm tra điều kiện (edition, feature, admin).
      2. Chuẩn bị một thư mục "handoff" chứa: bản copy repo, Pester 5 đã
         tải sẵn (Sandbox có thể không có mạng), và bootstrap script.
      3. Sinh file .wsb map thư mục đó vào Sandbox (repo chỉ-đọc, workDir
         đọc-ghi) rồi bật WindowsSandbox.exe.

    Vì sao phải chuẩn bị Pester offline: Windows Sandbox mặc định có mạng,
    nhưng nếu máy host không có mạng thì Install-Module trong sandbox sẽ
    fail. Copy sẵn module là cách chắc chắn nhất.

    YÊU CẦU (một lần, cần admin + restart):
      - Windows 10/11 Pro, Enterprise hoặc Education (bản Home KHÔNG có)
      - Bật feature:  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM
      - Virtualization bật trong BIOS/UEFI
      - Cần khoảng 8 GB RAM trống khuyến nghị

.PARAMETER HandoffDir
    Nơi chuẩn bị file cho Sandbox. Mặc định: <repo>\tests\.sandbox
    Nên đặt trên ổ còn nhiều dung lượng (repo + Pester ~50 MB).

.PARAMETER Suite
    Unit | Integration | All.

.PARAMETER KeepOpen
    Không tự đóng Sandbox sau khi test xong (để xem tận mắt).

.EXAMPLE
    .\Start-WindowsSandbox.ps1 -Suite All

.EXAMPLE
    # Nếu chưa bật feature, chạy lệnh này trong PowerShell Admin rồi restart:
    Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All
#>
[CmdletBinding()]
param(
    [string]$HandoffDir,
    [ValidateSet('Unit', 'Integration', 'All')]
    [string]$Suite = 'All',
    [switch]$KeepOpen,
    [switch]$SkipPrerequisiteCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$testsRoot = $PSScriptRoot
$repoRoot = Split-Path (Split-Path $testsRoot -Parent) -Parent

if ([string]::IsNullOrWhiteSpace($HandoffDir)) {
    $HandoffDir = Join-Path $testsRoot '..\.sandbox'
}
$HandoffDir = [System.IO.Path]::GetFullPath($HandoffDir)

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SandboxFeatureState {
    <#
        Trả về 'Enabled' / 'Disabled' / 'Unknown' / 'Unsupported'.
    #>
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -ErrorAction Stop
        return [string]$feature.State
    } catch {
        # Get-WindowsOptionalFeature cần admin; thử đọc registry như fallback.
        try {
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
            if (Test-Path $key) { return 'Unknown' }
        } catch { }
        return 'Unknown'
    }
}

function Test-SandboxBinaryPresent {
    $candidates = @(
        'C:\Windows\System32\WindowsSandbox.exe'
        'C:\Windows\System32\WindowsSandboxClient.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

Write-Host ''
Write-Host ('=' * 70)
Write-Host '  presale-wiper - Windows Sandbox runner'
Write-Host ('=' * 70)
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Kiểm tra điều kiện
# ---------------------------------------------------------------------------
$sandboxExe = Test-SandboxBinaryPresent
$featureState = Get-SandboxFeatureState
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
$isAdmin = Test-IsAdmin

Write-Host ("Edition            : {0}" -f $edition)
Write-Host ("WindowsSandbox.exe : {0}" -f $(if ($sandboxExe) { $sandboxExe } else { 'KHÔNG CÓ' }))
Write-Host ("Feature state      : {0}" -f $featureState)
Write-Host ("Đang chạy admin    : {0}" -f $isAdmin)
Write-Host ''

$blockers = New-Object 'System.Collections.Generic.List[string]'

if ($edition -in @('Core', 'CoreSingleLanguage', 'CoreCountrySpecific', 'Home', 'HomeSingleLanguage')) {
    $blockers.Add("Bản Windows Home không có Windows Sandbox. Cần Pro/Enterprise/Education.")
}

if ($null -eq $sandboxExe) {
    $blockers.Add("Không tìm thấy WindowsSandbox.exe. Feature 'Containers-DisposableClientVM' chưa bật.")
}

if (-not $SkipPrerequisiteCheck -and $blockers.Count -gt 0) {
    Write-Host 'KHÔNG CHẠY ĐƯỢC WINDOWS SANDBOX:' -ForegroundColor Red
    foreach ($blocker in $blockers) { Write-Host "  - $blocker" -ForegroundColor Red }

    Write-Host ''
    Write-Host 'Cách khắc phục (làm 1 lần):' -ForegroundColor Yellow
    Write-Host '  1. Mở PowerShell với quyền Administrator'
    Write-Host '  2. Chạy:'
    Write-Host '       Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -All'
    Write-Host '  3. Khởi động lại máy'
    Write-Host '  4. Đảm bảo Virtualization (VT-x / AMD-V) đã bật trong BIOS/UEFI'
    Write-Host ''
    Write-Host 'Trong lúc chờ, dùng môi trường cách ly không cần admin:' -ForegroundColor Green
    Write-Host '       .\tests\environments\Start-IsolatedRoot.ps1 -Drive D:'
    Write-Host ''
    Write-Host '(Hoặc chạy lại script này với -SkipPrerequisiteCheck để chỉ chuẩn bị file.)'
    exit 2
}

# ---------------------------------------------------------------------------
# 2. Chuẩn bị handoff
# ---------------------------------------------------------------------------
Write-Host ("Chuẩn bị handoff tại: {0}" -f $HandoffDir)

if (Test-Path -LiteralPath $HandoffDir) {
    Remove-Item -LiteralPath $HandoffDir -Recurse -Force
}
[void][System.IO.Directory]::CreateDirectory($HandoffDir)

$repoTarget = Join-Path $HandoffDir 'repo'
$workTarget = Join-Path $HandoffDir 'work'
$moduleTarget = Join-Path $HandoffDir 'modules'
[void][System.IO.Directory]::CreateDirectory($repoTarget)
[void][System.IO.Directory]::CreateDirectory($workTarget)
[void][System.IO.Directory]::CreateDirectory($moduleTarget)

# Copy repo (bỏ .git, .work, .sandbox để nhẹ)
Write-Host '  - copy repo...'
$excludeDirs = @('.git', '.work', '.sandbox', 'node_modules')
$robocopyArgs = @(
    $repoRoot, $repoTarget, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP'
) + ($excludeDirs | ForEach-Object { "/XD"; $_ })
$robocopy = Start-Process -FilePath 'robocopy.exe' -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
if ($robocopy.ExitCode -ge 8) {
    Write-Host ("CẢNH BÁO: robocopy trả mã {0}" -f $robocopy.ExitCode) -ForegroundColor Yellow
}

# Copy Pester >= 5 (Sandbox có thể không có mạng)
Write-Host '  - copy Pester...'
$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $pester) {
    Write-Host '  Pester >= 5 chưa cài trên host, đang cài...' -ForegroundColor Yellow
    Get-PackageProvider -Name NuGet -ForceBootstrap -ErrorAction SilentlyContinue | Out-Null
    Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck -Confirm:$false
    $pester = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge [version]'5.0.0' } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

if ($null -eq $pester) {
    Write-Host 'KHÔNG CÓ PESTER >= 5. Sandbox sẽ thử cài từ mạng.' -ForegroundColor Yellow
} else {
    $pesterSource = Split-Path $pester.Path -Parent
    $pesterDest = Join-Path $moduleTarget 'Pester'
    Copy-Item -LiteralPath $pesterSource -Destination $pesterDest -Recurse -Force
    Write-Host ("    Pester {0}" -f $pester.Version)
}

# Bootstrap chạy trong Sandbox
$bootstrapPath = Join-Path $HandoffDir 'bootstrap-sandbox.ps1'
$bootstrap = @'
#Requires -Version 5.1
<#
    Bootstrap chạy BÊN TRONG Windows Sandbox.
    Không sửa file này trên host trừ khi bạn hiểu môi trường mapping.
#>
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$repo = Join-Path $here 'repo'
$work = Join-Path $here 'work'
$modules = Join-Path $here 'modules'
$suite = '__SUITE__'
$keepOpen = __KEEPOPEN__

Write-Host ''
Write-Host '=== Trong Windows Sandbox ==='
Write-Host ("Repo : {0}" -f $repo)
Write-Host ("Work : {0}" -f $work)
Write-Host ("PS   : {0}" -f $PSVersionTable.PSVersion)
Write-Host ''

# Ưu tiên Pester đã copy sẵn (offline)
if (Test-Path (Join-Path $modules 'Pester')) {
    $env:PSModulePath = $modules + ';' + $env:PSModulePath
    Write-Host 'Dùng Pester offline đã copy sẵn.'
}

$logPath = Join-Path $work 'sandbox-result.txt'
$xmlPath = Join-Path $work 'sandbox-result.xml'

try {
    & (Join-Path $repo 'tests\environments\Invoke-TestSuite.ps1') `
        -WorkDir $work `
        -Suite $suite `
        -ResultPath $xmlPath 2>&1 | Tee-Object -FilePath $logPath

    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
} catch {
    "LỖI: $($_.Exception.Message)" | Tee-Object -FilePath $logPath -Append
    $exitCode = 2
}

Write-Host ''
Write-Host ('=' * 70)
if ($exitCode -eq 0) {
    Write-Host '  KẾT QUẢ: PASS - tất cả test xanh trong môi trường sạch' -ForegroundColor Green
} else {
    Write-Host ('  KẾT QUẢ: FAIL (exit {0}) - xem {1}' -f $exitCode, $logPath) -ForegroundColor Red
}
Write-Host ('=' * 70)
Write-Host ''
Write-Host ("Log: {0}" -f $logPath)
Write-Host ("XML: {0}" -f $xmlPath)
Write-Host ''
Write-Host 'File log/XML được ghi ra thư mục mapped nên VẪN CÒN sau khi đóng Sandbox.'

if (-not $keepOpen) {
    Write-Host 'Sandbox sẽ tự đóng sau 20 giây...'
    Start-Sleep -Seconds 20
    # Tắt máy sạch: Sandbox xoá toàn bộ trạng thái.
    Stop-Computer -Force
}
'@
$bootstrap = $bootstrap.Replace('__SUITE__', $Suite).Replace('__KEEPOPEN__', $(if ($KeepOpen) { '$true' } else { '$false' }))
[System.IO.File]::WriteAllText($bootstrapPath, $bootstrap, (New-Object System.Text.UTF8Encoding($true)))

# ---------------------------------------------------------------------------
# 3. Sinh .wsb
# ---------------------------------------------------------------------------
$wsbPath = Join-Path $HandoffDir 'presale-wiper.wsb'

# Windows Sandbox KHÔNG cho map cùng một folder vừa read-only vừa read-write,
# nên map repo (read-only) và work (read-write) là hai folder riêng.
$wsb = @"
<Configuration>
  <!-- presale-wiper test sandbox. Sinh tự động bởi Start-WindowsSandbox.ps1 -->
  <VGpu>Disable</VGpu>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$HandoffDir</HostFolder>
      <SandboxFolder>C:\psw</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\psw\bootstrap-sandbox.ps1</Command>
  </LogonCommand>
</Configuration>
"@
[System.IO.File]::WriteAllText($wsbPath, $wsb, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("  - .wsb: {0}" -f $wsbPath)
Write-Host ("  - bootstrap: {0}" -f $bootstrapPath)
Write-Host ''
Write-Host 'Lưu ý: Networking=Disable nên Sandbox không ra mạng - đó là lý do'
Write-Host 'Pester được copy sẵn. Nếu cần mạng, sửa <Networking>Enable</Networking>.'
Write-Host ''

if ($null -eq $sandboxExe) {
    Write-Host 'Không có WindowsSandbox.exe để bật. File đã chuẩn bị xong;' -ForegroundColor Yellow
    Write-Host 'sau khi bật feature + restart, chạy lại script này.' -ForegroundColor Yellow
    exit 2
}

Write-Host 'Đang bật Windows Sandbox...' -ForegroundColor Green
Start-Process -FilePath $sandboxExe -ArgumentList "`"$wsbPath`""

Write-Host ''
Write-Host 'Sandbox đang khởi động trong cửa sổ riêng.'
Write-Host 'Kết quả test sẽ được ghi vào:'
Write-Host ("  {0}" -f (Join-Path $workTarget 'sandbox-result.txt'))
Write-Host ''
Write-Host 'Đợi Sandbox chạy xong (hoặc xem cửa sổ Sandbox), rồi đọc file trên.'
exit 0
