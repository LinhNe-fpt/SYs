#Requires -Version 5.1
<#
.SYNOPSIS
    Chạy test trên runner Windows sạch của GitHub Actions (không cần admin).

.DESCRIPTION
    Vì sao đây là lựa chọn tốt cho tool xoá dữ liệu:
    mỗi lần chạy, GitHub dựng một VM Windows MỚI, cài sẵn toolchain, rồi
    XOÁ TOÀN BỘ sau khi job xong. Không có dữ liệu người dùng thật nào để
    làm hỏng, không có Credential Manager thật, không có project cũ.

    Script này (chạy trên máy bạn) thực hiện:
      1. Kiểm tra git + gh CLI + trạng thái đăng nhập.
      2. Tạo repo riêng tư (private) trên GitHub nếu chưa có - mặc định
         PRIVATE vì repo chứa code của tool xoá dữ liệu.
      3. Push code (kèm workflow .github/workflows/ci.yml).
      4. Bật workflow và theo dõi cho tới khi xong.
      5. Tải kết quả test về tests\.results\.
      6. In tổng kết PASS/FAIL.

    Điều kiện:
      * Đã cài gh CLI  (winget install --id GitHub.cli)
      * Đã đăng nhập    (gh auth login)
      * Có mạng

.PARAMETER RepoName
    Tên repo trên GitHub. Mặc định: presale-wiper

.PARAMETER Visibility
    private | public. Mặc định private.

.PARAMETER SkipCreate
    Không tạo repo mới (dùng khi repo đã tồn tại và chỉ muốn chạy lại).

.PARAMETER Watch
    Theo dõi job theo thời gian thực (mặc định bật).

.EXAMPLE
    .\Start-GitHubActionsRun.ps1

.EXAMPLE
    .\Start-GitHubActionsRun.ps1 -RepoName presale-wiper-test -SkipCreate
#>
[CmdletBinding()]
param(
    [string]$RepoName = 'presale-wiper',
    [ValidateSet('private', 'public')]
    [string]$Visibility = 'private',
    [switch]$SkipCreate,
    [switch]$NoWatch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$environmentsRoot = $PSScriptRoot
$testsRoot = Split-Path $environmentsRoot -Parent
$repoRoot = Split-Path $testsRoot -Parent
$workflowPath = Join-Path $repoRoot '.github\workflows\ci.yml'
$resultsDir = Join-Path $testsRoot '.results'

Write-Host ''
Write-Host ('=' * 70)
Write-Host '  presale-wiper - GitHub Actions (Windows runner sạch)'
Write-Host ('=' * 70)
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Kiểm tra công cụ
# ---------------------------------------------------------------------------
$missing = New-Object 'System.Collections.Generic.List[string]'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $missing.Add('git') }
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) { $missing.Add('gh (GitHub CLI)') }

if ($missing.Count -gt 0) {
    Write-Host 'Thiếu công cụ:' -ForegroundColor Red
    foreach ($tool in $missing) { Write-Host "  - $tool" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Cài bằng winget:' -ForegroundColor Yellow
    Write-Host '  winget install --id Git.Git -e'
    Write-Host '  winget install --id GitHub.cli -e'
    exit 2
}

if (-not (Test-Path -LiteralPath $workflowPath)) {
    Write-Host "Không tìm thấy workflow: $workflowPath" -ForegroundColor Red
    exit 2
}

# Đăng nhập?
& gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Chưa đăng nhập GitHub CLI.' -ForegroundColor Red
    Write-Host 'Chạy:  gh auth login' -ForegroundColor Yellow
    exit 2
}

$account = (& gh api user --jq '.login' 2>$null)
Write-Host ("Tài khoản GitHub : {0}" -f $account)
Write-Host ("Repo             : {0}/{1}" -f $account, $RepoName)
Write-Host ("Visibility       : {0}" -f $Visibility)
Write-Host ''

# ---------------------------------------------------------------------------
# 2. Chuẩn bị git
# ---------------------------------------------------------------------------
Push-Location $repoRoot
try {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) {
        Write-Host 'Chưa có git repo, đang khởi tạo...'
        & git init --initial-branch=main 2>&1 | Out-Null
    }

    # .gitignore tối thiểu nếu chưa có
    $gitignorePath = Join-Path $repoRoot '.gitignore'
    if (-not (Test-Path -LiteralPath $gitignorePath)) {
        $gitignore = @'
# Thư mục làm việc của test (fixtures, log, sandbox tạm)
tests/.work/
tests/.results/
tests/.sandbox/

# Môi trường ảo
*.iso
*.vhd
*.vhdx
.vm/

# Hệ điều hành
Thumbs.db
Desktop.ini
'@
        [System.IO.File]::WriteAllText($gitignorePath, $gitignore, (New-Object System.Text.UTF8Encoding($false)))
    }

    & git add -A 2>&1 | Out-Null
    $status = & git status --porcelain
    if ($status) {
        & git -c user.name='presale-wiper' -c user.email='noreply@example.invalid' `
            commit -m 'ci: thêm test suite cho presale-wiper' 2>&1 | Out-Null
        Write-Host 'Đã commit thay đổi.'
    } else {
        Write-Host 'Không có thay đổi cần commit.'
    }

    # -----------------------------------------------------------------------
    # 3. Tạo/push repo
    # -----------------------------------------------------------------------
    $fullName = "$account/$RepoName"
    $repoExists = $false
    & gh repo view $fullName 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $repoExists = $true }

    if (-not $repoExists) {
        if ($SkipCreate) {
            Write-Host "Repo $fullName không tồn tại và -SkipCreate đã bật. Dừng." -ForegroundColor Red
            exit 2
        }
        Write-Host ("Đang tạo repo {0}: {1} ..." -f $Visibility, $fullName)
        & gh repo create $fullName "--$Visibility" --source . --remote origin --push 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'Tạo repo thất bại.' -ForegroundColor Red
            exit 2
        }
        Write-Host 'Đã tạo và push.'
    } else {
        Write-Host "Repo đã tồn tại, đang push..."
        $hasRemote = (& git remote) -contains 'origin'
        if (-not $hasRemote) {
            & git remote add origin "https://github.com/$fullName.git"
        }
        & git push -u origin HEAD 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'Push thất bại (kiểm tra quyền hoặc branch).' -ForegroundColor Red
            exit 2
        }
    }

    # -----------------------------------------------------------------------
    # 4. Chạy workflow
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Kích hoạt workflow ci.yml ...'
    & git commit --allow-empty -m 'ci: trigger' 2>&1 | Out-Null
    & git push 2>&1 | Out-Null

    # Đợi run xuất hiện
    $runId = $null
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        Start-Sleep -Seconds 5
        $runId = (& gh run list --workflow=ci.yml --limit 1 --json databaseId --jq '.[0].databaseId' 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($runId)) { break }
    }

    if ([string]::IsNullOrWhiteSpace($runId)) {
        Write-Host 'Không tìm thấy workflow run. Mở trang Actions để kiểm tra:' -ForegroundColor Yellow
        Write-Host ("  https://github.com/{0}/actions" -f $fullName)
        exit 2
    }

    Write-Host ("Run ID: {0}" -f $runId)
    Write-Host ("Theo dõi: https://github.com/{0}/actions/runs/{1}" -f $fullName, $runId)
    Write-Host ''

    if (-not $NoWatch) {
        & gh run watch $runId --exit-status
        $watchExit = $LASTEXITCODE
    } else {
        $watchExit = 0
    }

    # -----------------------------------------------------------------------
    # 5. Tải kết quả
    # -----------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $resultsDir)) {
        [void][System.IO.Directory]::CreateDirectory($resultsDir)
    }
    & gh run download $runId --dir $resultsDir --pattern 'test-results-*' 2>&1 | Out-Null

    Write-Host ''
    Write-Host ('=' * 70)
    if ($watchExit -eq 0) {
        Write-Host '  PASS - test xanh trên Windows runner sạch' -ForegroundColor Green
    } else {
        Write-Host '  FAIL - xem log trên GitHub Actions' -ForegroundColor Red
        Write-Host ("  https://github.com/{0}/actions/runs/{1}" -f $fullName, $runId)
    }
    Write-Host ('=' * 70)
    Write-Host ("Kết quả (nếu có): {0}" -f $resultsDir)
    Write-Host ''

    exit $watchExit
} finally {
    Pop-Location
}
