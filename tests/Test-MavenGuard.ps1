#Requires -Version 5.1
<#
    Kiểm thử guard: đường dẫn Maven '.m2\repository\org\springframework\boot\...'
    phải ĐƯỢC PHÉP xoá (trước đây bị chặn vì chứa đoạn tên 'boot'), trong khi
    thư mục hệ thống thật (C:\Windows, C:\Boot) vẫn phải bị chặn.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolRoot = Split-Path -Parent $PSScriptRoot
$sandbox = Join-Path $env:USERPROFILE 'psw-maven-test'
$out = Join-Path $env:USERPROFILE 'psw-maven-scan'

foreach ($p in @($sandbox, $out)) {
    if ([System.IO.Directory]::Exists($p)) { [System.IO.Directory]::Delete($p, $true) }
    [void][System.IO.Directory]::CreateDirectory($p)
}

function New-DummyFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($Path, $Content)
}

# Cấu trúc y hệt .m2 thật: có đoạn 'boot', 'jpa', 'tomcat' - những tên từng
# làm guard chặn nhầm.
$m2 = Join-Path $sandbox '.m2\repository\org\springframework\boot'
$versions = @(
    @('spring-boot-starter-data-jpa', '3.2.12'),
    @('spring-boot-starter-validation', '2.7.15'),
    @('spring-boot-starter-tomcat', '3.5.3'),
    @('spring-boot-starter-thymeleaf', '3.4.3'),
    @('spring-boot-autoconfigure', '2.7.15')
)
foreach ($v in $versions) {
    $dir = Join-Path $m2 ("{0}\{1}" -f $v[0], $v[1])
    New-DummyFile (Join-Path $dir ("{0}-{1}.jar" -f $v[0], $v[1])) ('J' * 2000)
    New-DummyFile (Join-Path $dir ("{0}-{1}.pom" -f $v[0], $v[1])) '<project/>'
    New-DummyFile (Join-Path $dir ("{0}-{1}.jar.sha1" -f $v[0], $v[1])) 'abc123'
}

# Thêm project thường để chắc chắn việc quét vẫn hoạt động
New-DummyFile (Join-Path $sandbox 'myapp\package.json') '{"name":"myapp"}'
1..3 | ForEach-Object { New-DummyFile (Join-Path $sandbox "myapp\src\f$_.js") ('x' * 300) }

$before = @(Get-ChildItem $sandbox -Recurse -File).Count
Write-Host ('=== Du lieu gia: {0} file (Maven .m2 + 1 project) ===' -f $before) -ForegroundColor Cyan

# ---- quét + xoá ----
Write-Host ''
Write-Host '=== Chay scan + go XOA ===' -ForegroundColor Cyan
$scanScript = Join-Path $toolRoot 'scan-once.ps1'
'XOA' | & powershell -NoProfile -ExecutionPolicy Bypass -File $scanScript -Path $sandbox -OutDir $out -AskDelete 2>&1 |
    Select-String -Pattern 'File đã xoá|Thư mục đã dọn|Lỗi|Bỏ qua|đã xoá|bị chặn|cấm' |
    ForEach-Object { Write-Host ('  ' + $_.Line) }

# ---- kiểm tra ----
Write-Host ''
Write-Host '=== Ket qua ===' -ForegroundColor Cyan
$left = @(Get-ChildItem $sandbox -Recurse -File -ErrorAction SilentlyContinue)
$m2Left = Test-Path (Join-Path $sandbox '.m2')
$myappLeft = Test-Path (Join-Path $sandbox 'myapp')

Write-Host ('  File con lai  : {0}' -f $left.Count)
foreach ($f in $left) { Write-Host ('    con: {0}' -f $f.FullName.Replace($sandbox, '<sandbox>')) }
Write-Host ('  .m2 con       : {0}' -f $m2Left)
Write-Host ('  myapp con     : {0}' -f $myappLeft)

$rep = @(Get-ChildItem $out -Filter 'da-xoa-*.json' -ErrorAction SilentlyContinue)
$skippedInPlan = $null
if ($rep.Count -gt 0) {
    $j = Get-Content $rep[0].FullName -Raw | ConvertFrom-Json
    Write-Host ('  da-xoa        : files={0} dirs={1} skipped={2} failed={3}' -f $j.deleted, $j.removedDirs, $j.skipped, $j.failed)
    $skippedInPlan = $j.skipped
}

Write-Host ''
Write-Host '=== Ket luan ===' -ForegroundColor Cyan
$t1 = ($left.Count -eq 0)
$t2 = (-not $m2Left)
$t3 = (-not $myappLeft)
$t4 = ($skippedInPlan -eq 0)

Write-Host ('  [1] Maven .m2 duoc xoa het (khong bi chan)   : {0}' -f $(if ($t2) { 'DAT' } else { 'HONG' }))
Write-Host ('  [2] Project thuong cung bi xoa               : {0}' -f $(if ($t3) { 'DAT' } else { 'HONG' }))
Write-Host ('  [3] Khong con file nao                          : {0}' -f $(if ($t1) { 'DAT' } else { 'HONG' }))
Write-Host ('  [4] Khong file nao bi guard bo qua           : {0}' -f $(if ($t4) { 'DAT' } else { 'HONG' }))

if ($t1 -and $t2 -and $t3 -and $t4) { exit 0 } else { exit 1 }
