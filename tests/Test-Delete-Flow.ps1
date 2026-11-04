#Requires -Version 5.1
<#
    Kiểm thử quy mô nhỏ: tạo project GIẢ rồi chạy đúng luồng quét -> xoá.

    An toàn:
      - Dữ liệu giả nằm NGOÀI thư mục công cụ (remove-once.ps1 chặn xoá trong
        chính thư mục tool) và ngoài mọi thư mục hệ thống.
      - Quét bằng -Path nên KHÔNG dò AppData / lịch sử IDE.
      - Có file "sentinel" không phải code, phải còn lại sau khi xoá.
      - Đếm file trong AppData trước và sau để chứng minh không bị đụng tới.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolRoot = Split-Path -Parent $PSScriptRoot
$sandbox = Join-Path $env:USERPROFILE 'psw-dummy-test'
$outDir = Join-Path $env:USERPROFILE 'psw-dummy-scan'

function New-DummyFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($Path, $Content)
}

# ---- don sach lan chay truoc ----
foreach ($p in @($sandbox, $outDir)) {
    if ([System.IO.Directory]::Exists($p)) { [System.IO.Directory]::Delete($p, $true) }
}

Write-Host '=== 1. Tao du lieu gia ===' -ForegroundColor Cyan

# web-app: Node project
New-DummyFile (Join-Path $sandbox 'web-app\package.json') '{"name":"web-app","version":"1.0.0"}'
1..4 | ForEach-Object { New-DummyFile (Join-Path $sandbox "web-app\src\mod$_.js") ("export const v = $_;" * 20) }
1..30 | ForEach-Object { New-DummyFile (Join-Path $sandbox "web-app\node_modules\lib\pkg$_.js") ('x' * 800) }
New-DummyFile (Join-Path $sandbox 'web-app\dist\bundle.js') ('y' * 3000)
New-DummyFile (Join-Path $sandbox 'web-app\.vscode\settings.json') '{"editor.tabSize":2}'

# api-server: Python
New-DummyFile (Join-Path $sandbox 'api-server\requirements.txt') 'flask==3.0.0'
New-DummyFile (Join-Path $sandbox 'api-server\app.py') "print('hello')"
1..20 | ForEach-Object { New-DummyFile (Join-Path $sandbox "api-server\.venv\Lib\site-packages\mod$_.py") ('p' * 600) }
1..6 | ForEach-Object { New-DummyFile (Join-Path $sandbox "api-server\__pycache__\m$_.pyc") ('c' * 200) }

# rust-tool: Rust
New-DummyFile (Join-Path $sandbox 'rust-tool\Cargo.toml') "[package]`nname = `"rust-tool`""
New-DummyFile (Join-Path $sandbox 'rust-tool\src\main.rs') 'fn main() { println!("hi"); }'
1..15 | ForEach-Object { New-DummyFile (Join-Path $sandbox "rust-tool\target\debug\d$_.rlib") ('r' * 900) }

# java-app: Java/Maven
New-DummyFile (Join-Path $sandbox 'java-app\pom.xml') '<project></project>'
New-DummyFile (Join-Path $sandbox 'java-app\src\main\java\App.java') 'public class App {}'
1..12 | ForEach-Object { New-DummyFile (Join-Path $sandbox "java-app\target\classes\C$_.class") ('j' * 400) }

# SENTINEL: khong phai code -> phai con lai
New-DummyFile (Join-Path $sandbox 'keep-me\important.txt') 'Tai lieu quan trong, KHONG duoc xoa.'

$beforeCount = (Get-ChildItem $sandbox -Recurse -File).Count
Write-Host ("  File gia tao ra      : {0}" -f $beforeCount)
Write-Host '  Thu muc            : web-app, api-server, rust-tool, java-app, keep-me'

# ---- 2. chup trang thai AppData ----
function Get-AppDataFingerprint {
    $sum = 0
    foreach ($p in @("$env:APPDATA\Code\User", "$env:APPDATA\Cursor\User")) {
        if ([System.IO.Directory]::Exists($p)) {
            $sum += @([System.IO.Directory]::GetFiles($p, '*', [System.IO.SearchOption]::AllDirectories)).Count
        }
    }
    return $sum
}
$appBefore = Get-AppDataFingerprint
Write-Host ''
Write-Host ("=== 2. AppData truoc khi chay: {0} file trong Code\User + Cursor\User ===" -f $appBefore) -ForegroundColor Cyan

# ---- 3. chay quet + xoa, go XOA ----
Write-Host ''
Write-Host '=== 3. Chay scan-once.ps1 -Path <sandbox> -AskDelete, go "XOA" ===' -ForegroundColor Cyan
$scanScript = Join-Path $toolRoot 'scan-once.ps1'
'XOA' | & powershell -NoProfile -ExecutionPolicy Bypass -File $scanScript -Path $sandbox -OutDir $outDir -AskDelete

# ---- 4. ket qua ----
Write-Host ''
Write-Host '=== 4. Ket qua ===' -ForegroundColor Cyan

$survivors = @(Get-ChildItem $sandbox -Recurse -File -ErrorAction SilentlyContinue)
$keepMe = Test-Path (Join-Path $sandbox 'keep-me\important.txt')

Write-Host ("  File con lai trong sandbox : {0}" -f $survivors.Count)
foreach ($s in $survivors) { Write-Host ("    con: {0}" -f $s.FullName.Replace($sandbox, '<sandbox>')) }
Write-Host ''
Write-Host ("  web-app con       : {0}" -f (Test-Path (Join-Path $sandbox 'web-app')))
Write-Host ("  api-server con    : {0}" -f (Test-Path (Join-Path $sandbox 'api-server')))
Write-Host ("  rust-tool con     : {0}" -f (Test-Path (Join-Path $sandbox 'rust-tool')))
Write-Host ("  java-app con      : {0}" -f (Test-Path (Join-Path $sandbox 'java-app')))
Write-Host ("  keep-me/important : {0}" -f $keepMe)

$appAfter = Get-AppDataFingerprint
Write-Host ''
Write-Host ("  AppData sau khi chay: {0} file (truoc: {1})" -f $appAfter, $appBefore)

$reports = @(Get-ChildItem $outDir -File -ErrorAction SilentlyContinue)
Write-Host ''
Write-Host '  Bao cao sinh ra:'
foreach ($r in $reports) { Write-Host ("    {0}  ({1} bytes)" -f $r.Name, $r.Length) }

$ideReport = @($reports | Where-Object { $_.Name -like 'danh-sach-ide-*' })
$deletedReport = @($reports | Where-Object { $_.Name -like 'da-xoa-*' })

Write-Host ''
Write-Host '=== 5. Ket luan ===' -ForegroundColor Cyan

$t1 = ($reports.Count -gt 0 -and $deletedReport.Count -gt 0)
$t2 = ($survivors.Count -eq 1 -and $keepMe)
$t3 = (-not (Test-Path (Join-Path $sandbox 'web-app')))
$t4 = ($appAfter -eq $appBefore)

Write-Host ("  [1] Co bao cao 'da-xoa-*' (xoá thật đã chạy) : {0}" -f $(if ($t1) { 'DAT' } else { 'HONG' }))
Write-Host ("  [2] Chi con sentinel, khong con file code     : {0}" -f $(if ($t2) { 'DAT' } else { 'HONG' }))
Write-Host ("  [3] Project gia da bi xoa het                 : {0}" -f $(if ($t3) { 'DAT' } else { 'HONG' }))
Write-Host ("  [4] AppData KHONG bi dung toi                : {0}" -f $(if ($t4) { 'DAT' } else { 'HONG' }))

if ($t1 -and $t2 -and $t3 -and $t4) { exit 0 } else { exit 1 }
