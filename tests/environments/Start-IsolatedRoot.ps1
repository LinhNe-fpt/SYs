#Requires -Version 5.1
<#
.SYNOPSIS
    Chạy test trong "isolated root" - môi trường cách ly không cần admin.

.DESCRIPTION
    Đây là mức cách ly thực dụng nhất khi máy không có Windows Sandbox,
    Hyper-V hay Docker và bạn không có quyền admin.

    Ý tưởng: KHÔNG chạy test trực tiếp trong thư mục repo trên ổ hệ thống.
    Thay vào đó:

      1. Copy toàn bộ repo sang một "root" riêng trên ổ khác (mặc định D:).
      2. Sinh fixtures + mọi file tạm TRONG root đó.
      3. Đặt TMP/TEMP và PRESALE_WIPER_TEST_WORK trỏ vào trong root.
      4. Áp một số rào chắn môi trường (không proxy, không profile, không
         module auto-load từ user) để test không phụ thuộc cấu hình máy.
      5. Chạy test suite trong một tiến trình PowerShell con với các biến
         môi trường đó.
      6. Xuất kết quả XML ra ngoài, rồi (tùy chọn) xoá sạch root.

    Điều script này ĐẢM BẢO:
      - Không ghi/sửa gì trên ổ hệ thống (chỉ ĐỌC để copy).
      - Không đụng tới dữ liệu người dùng (Desktop, Documents...).
      - Dọn sạch bằng một lệnh khi xong (-Cleanup).

    Điều script này KHÔNG làm được (cần VM/Sandbox thật):
      - Không phải kernel/registry riêng: nếu test có bug xoá C:\Windows
        thì nó vẫn xoá được. Vì vậy guard của tool mới là lớp bảo vệ chính,
        và luôn có -DryRun mặc định.
      - Không mô phỏng Windows phiên bản khác (build/edition).

    Muốn cách ly mạnh hơn: xem Start-WindowsSandbox.ps1 hoặc Start-HyperVVM.ps1.

.PARAMETER Drive
    Ổ đích để đặt isolated root. Mặc định: tự chọn ổ cố định (không phải ổ
    hệ thống) còn nhiều dung lượng nhất.

.PARAMETER RootPath
    Đường dẫn chính xác của isolated root. Ghi đè -Drive.

.PARAMETER Suite
    Unit | Integration | All.

.PARAMETER Cleanup
    Xoá isolated root sau khi chạy xong (mặc định giữ lại để xem log).

.PARAMETER KeepResult
    Copy file kết quả XML về repo (tests\.results) trước khi cleanup.

.EXAMPLE
    .\Start-IsolatedRoot.ps1
    # Tự chọn ổ, copy repo, chạy toàn bộ test

.EXAMPLE
    .\Start-IsolatedRoot.ps1 -Suite Unit -Cleanup

.EXAMPLE
    .\Start-IsolatedRoot.ps1 -RootPath 'E:\psw-iso' -KeepResult
#>
[CmdletBinding()]
param(
    [string]$Drive,
    [string]$RootPath,
    [ValidateSet('Unit', 'Integration', 'All')]
    [string]$Suite = 'All',
    [switch]$Cleanup,
    [switch]$KeepResult
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$environmentsRoot = $PSScriptRoot
$testsRoot = Split-Path $environmentsRoot -Parent
$repoRoot = Split-Path $testsRoot -Parent

# ---------------------------------------------------------------------------
# 1. Chọn ổ đích
# ---------------------------------------------------------------------------
function Get-CandidateDrives {
    <#
        Các ổ cố định, đã sẵn sàng, không phải ổ hệ thống, còn >= 2 GB.
    #>
    $systemDrive = [Environment]::GetEnvironmentVariable('SystemDrive')
    if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = 'C:' }

    return @(
        [System.IO.DriveInfo]::GetDrives() | Where-Object {
            $_.IsReady -and
            $_.DriveType -eq [System.IO.DriveType]::Fixed -and
            ($_.Name.TrimEnd('\') -ne $systemDrive) -and
            $_.AvailableFreeSpace -gt 2GB
        } | Sort-Object AvailableFreeSpace -Descending
    )
}

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    if ([string]::IsNullOrWhiteSpace($Drive)) {
        $candidates = Get-CandidateDrives
        if ($candidates.Count -eq 0) {
            Write-Host 'Không có ổ phụ nào đủ chỗ (cần >= 2 GB).' -ForegroundColor Red
            Write-Host 'Chỉ định thủ công: -RootPath <đường-dẫn>'
            Write-Host ''
            Write-Host 'LƯU Ý: nếu buộc phải dùng ổ hệ thống, biết rằng mức cách ly'
            Write-Host 'sẽ yếu hơn - test sẽ ghi vào một folder riêng, nhưng vẫn'
            Write-Host 'là cùng ổ với Windows.'
            exit 2
        }
        $target = $candidates[0]
        Write-Host ("Chọn ổ: {0} (trống {1:N1} GB)" -f $target.Name, ($target.AvailableFreeSpace / 1GB))
        $RootPath = Join-Path $target.Name 'presale-wiper-iso'
    } else {
        $normalizedDrive = $Drive.TrimEnd('\', ':') + ':'
        $RootPath = Join-Path ($normalizedDrive + '\') 'presale-wiper-iso'
    }
}

$RootPath = [System.IO.Path]::GetFullPath($RootPath)

# An toàn: không cho root nằm trong repo (sẽ copy chính nó)
if ($RootPath.TrimEnd('\').StartsWith($repoRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "RootPath không được nằm trong repo: $RootPath" -ForegroundColor Red
    exit 2
}

Write-Host ''
Write-Host ('=' * 70)
Write-Host '  presale-wiper - Isolated root (không cần admin)'
Write-Host ('=' * 70)
Write-Host ''
Write-Host ("Repo nguồn  : {0}" -f $repoRoot)
Write-Host ("Root cách ly: {0}" -f $RootPath)
Write-Host ("Suite       : {0}" -f $Suite)
Write-Host ''

# ---------------------------------------------------------------------------
# 2. Chuẩn bị root
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $RootPath) {
    Write-Host 'Root đã tồn tại, xoá để đảm bảo trạng thái sạch...'
    Remove-Item -LiteralPath $RootPath -Recurse -Force -ErrorAction SilentlyContinue
}

$repoCopy = Join-Path $RootPath 'repo'
$workDir = Join-Path $RootPath 'work'
$tmpDir = Join-Path $RootPath 'tmp'
$resultDir = Join-Path $RootPath 'results'

foreach ($directory in @($RootPath, $repoCopy, $workDir, $tmpDir, $resultDir)) {
    [void][System.IO.Directory]::CreateDirectory($directory)
}

Write-Host 'Đang copy repo sang root cách ly...'
$robocopyArgs = @(
    $repoRoot, $repoCopy,
    '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP',
    '/XD', '.git', '/XD', '.work', '/XD', '.sandbox', '/XD', '.results'
)
$robocopy = Start-Process -FilePath 'robocopy.exe' -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
# robocopy: 0-7 là thành công, >=8 là lỗi
if ($robocopy.ExitCode -ge 8) {
    Write-Host ("Copy thất bại (robocopy mã {0})." -f $robocopy.ExitCode) -ForegroundColor Red
    exit 2
}

$copiedFiles = @(Get-ChildItem -LiteralPath $repoCopy -Recurse -File -ErrorAction SilentlyContinue).Count
Write-Host ("Đã copy {0} file." -f $copiedFiles)

# ---------------------------------------------------------------------------
# 3. Chạy test trong tiến trình con với môi trường sạch
# ---------------------------------------------------------------------------
$xmlPath = Join-Path $resultDir 'nunit.xml'
$logPath = Join-Path $resultDir 'runner.log'
$suiteRunner = Join-Path $repoCopy 'tests\environments\Invoke-TestSuite.ps1'

if (-not (Test-Path -LiteralPath $suiteRunner)) {
    Write-Host "Không tìm thấy runner trong bản copy: $suiteRunner" -ForegroundColor Red
    exit 2
}

# Script chạy trong tiến trình con: đặt biến môi trường rồi gọi runner.
$childScript = Join-Path $RootPath 'run-child.ps1'
$childContent = @"
#Requires -Version 5.1
`$ErrorActionPreference = 'Stop'

# Môi trường cách ly: TMP/TEMP và work dir đều trỏ vào root
`$env:TMP = '$tmpDir'
`$env:TEMP = '$tmpDir'
`$env:PRESALE_WIPER_TEST_WORK = '$workDir'

# KHÔNG đặt PSModuleAutoLoadingPreference='None': nó chặn cả module core
# (Microsoft.PowerShell.Utility chứa Split-Path, Join-Path...) và làm mọi
# script chết ngay dòng đầu. Muốn cô lập module thì lọc PSModulePath.

# Không cho test phụ thuộc proxy/mạng của máy
`$env:HTTP_PROXY = ''
`$env:HTTPS_PROXY = ''
`$env:NO_PROXY = '*'

& '$suiteRunner' -WorkDir '$workDir' -Suite '$Suite' -ResultPath '$xmlPath'
exit `$LASTEXITCODE
"@
[System.IO.File]::WriteAllText($childScript, $childContent, (New-Object System.Text.UTF8Encoding($true)))

Write-Host ''
Write-Host 'Chạy test trong tiến trình con (môi trường sạch)...'
Write-Host ('-' * 70)

$process = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$childScript`"") `
    -Wait -PassThru -NoNewWindow

$exitCode = $process.ExitCode

Write-Host ('-' * 70)
Write-Host ''

# ---------------------------------------------------------------------------
# 4. Kết quả
# ---------------------------------------------------------------------------
Write-Host ('=' * 70)
if ($exitCode -eq 0) {
    Write-Host '  PASS - test xanh trong isolated root' -ForegroundColor Green
} else {
    Write-Host ("  FAIL - exit code {0}" -f $exitCode) -ForegroundColor Red
}
Write-Host ('=' * 70)
Write-Host ''

if (Test-Path -LiteralPath $xmlPath) {
    try {
        [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw
        $results = $xml.'test-results'
        Write-Host ("Kết quả: total={0} failures={1} errors={2} skipped={3}" -f `
                $results.total, $results.failures, $results.errors, $results.'not-run')
    } catch {
        Write-Host "Không đọc được XML: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host 'Không có file XML kết quả - xem log để biết lỗi.' -ForegroundColor Yellow
}

Write-Host ("Result dir: {0}" -f $resultDir)

# ---------------------------------------------------------------------------
# 5. Copy kết quả về + dọn
# ---------------------------------------------------------------------------
if ($KeepResult) {
    $keepDir = Join-Path $testsRoot '.results'
    if (-not (Test-Path -LiteralPath $keepDir)) {
        [void][System.IO.Directory]::CreateDirectory($keepDir)
    }
    foreach ($file in @($xmlPath, $logPath)) {
        if (Test-Path -LiteralPath $file) {
            Copy-Item -LiteralPath $file -Destination $keepDir -Force
        }
    }
    Write-Host ("Đã copy kết quả về: {0}" -f $keepDir)
}

if ($Cleanup) {
    Write-Host 'Đang xoá isolated root...'
    Remove-Item -LiteralPath $RootPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Đã dọn sạch.'
} else {
    Write-Host ''
    Write-Host 'Isolated root được giữ lại để xem log. Dọn bằng:'
    Write-Host ("  Remove-Item -LiteralPath '{0}' -Recurse -Force" -f $RootPath)
}

exit $exitCode
