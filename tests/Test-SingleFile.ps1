#Requires -Version 5.1
<#
    Kiểm thử presale-scan.cmd là MỘT file tự đủ.

    Cách làm: chép chỉ file .cmd vào thư mục trống, tạo project giả ở nơi khác,
    chạy .cmd với -Path trỏ vào project giả. Nếu chạy được tới bước xoá thì
    chứng tỏ remove-once.ps1 nhúng Base64 hoạt động (không có file .ps1 kề bên).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolRoot = Split-Path -Parent $PSScriptRoot
$solo = Join-Path $env:USERPROFILE 'psw-solo-test'          # chỉ chứa .cmd
$data = Join-Path $env:USERPROFILE 'psw-solo-data'          # project giả
$out = Join-Path $env:USERPROFILE 'psw-solo-scan'

foreach ($p in @($solo, $data, $out)) {
    if ([System.IO.Directory]::Exists($p)) { [System.IO.Directory]::Delete($p, $true) }
    [void][System.IO.Directory]::CreateDirectory($p)
}

# ---- 1. đóng gói ----
$cmdName = 'presale-scan.cmd'
$built = & (Join-Path $toolRoot 'tools\Build-PresaleScanCmd.ps1') -Visible -Destination (Join-Path $solo $cmdName)
Write-Host ('=== 1. Dong goi: {0} ({1:N0} bytes) ===' -f $built.Name, $built.Length) -ForegroundColor Cyan

# ---- 2. xác nhận thư mục chỉ có 1 file ----
$filesInSolo = @(Get-ChildItem $solo -File)
Write-Host ''
Write-Host ('=== 2. Thu muc chi chua: {0} ===' -f (($filesInSolo | ForEach-Object Name) -join ', '))
$onlyOne = ($filesInSolo.Count -eq 1 -and $filesInSolo[0].Name -eq $cmdName)
Write-Host ('    dung 1 file .cmd, khong co .ps1 : {0}' -f $(if ($onlyOne) { 'DAT' } else { 'HONG' }))

# ---- 3. dữ liệu giả ----
function New-DummyFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($Path, $Content)
}

New-DummyFile (Join-Path $data 'proj-a\package.json') '{"name":"proj-a"}'
1..5 | ForEach-Object { New-DummyFile (Join-Path $data "proj-a\src\m$_.js") ('a' * 400) }
1..8 | ForEach-Object { New-DummyFile (Join-Path $data "proj-a\node_modules\x\n$_.js") ('n' * 500) }

New-DummyFile (Join-Path $data 'proj-b\app.py') 'print(1)'
1..4 | ForEach-Object { New-DummyFile (Join-Path $data "proj-b\__pycache__\c$_.pyc") ('c' * 300) }

New-DummyFile (Join-Path $data 'giu-lai\ghi-chu.txt') 'Khong phai code, phai con lai.'

$before = @(Get-ChildItem $data -Recurse -File).Count
Write-Host ''
Write-Host ('=== 3. Du lieu gia: {0} file (2 project + 1 thu muc giu lai) ===' -f $before)

# ---- 4. chạy .cmd trong thư mục cô lập ----
Write-Host ''
Write-Host '=== 4. Chay .cmd tu thu muc chi co no ===' -ForegroundColor Cyan
$cmdPath = Join-Path $solo $cmdName
'XOA' | & $cmdPath -Path $data -OutDir $out 2>&1 | Select-Object -Last 22

# ---- 5. kết quả ----
Write-Host ''
Write-Host '=== 5. Ket qua ===' -ForegroundColor Cyan
$survivors = @(Get-ChildItem $data -Recurse -File -ErrorAction SilentlyContinue)
$keepAlive = Test-Path (Join-Path $data 'giu-lai\ghi-chu.txt')
$reports = @(Get-ChildItem $out -File -ErrorAction SilentlyContinue)
$deletedReport = @($reports | Where-Object { $_.Name -like 'da-xoa-*.json' })

Write-Host ('    File con lai    : {0}' -f $survivors.Count)
foreach ($s in $survivors) { Write-Host ('      con: {0}' -f $s.FullName.Replace($data, '<data>')) }
Write-Host ('    proj-a con      : {0}' -f (Test-Path (Join-Path $data 'proj-a')))
Write-Host ('    proj-b con      : {0}' -f (Test-Path (Join-Path $data 'proj-b')))
Write-Host ('    giu-lai con     : {0}' -f $keepAlive)
Write-Host ('    Bao cao sinh ra : {0} file' -f $reports.Count)

if ($deletedReport.Count -gt 0) {
    $j = Get-Content $deletedReport[0].FullName -Raw | ConvertFrom-Json
    Write-Host ('    da-xoa: mode={0} files={1} dirs={2} failed={3}' -f $j.mode, $j.deleted, $j.removedDirs, $j.failed)
}

Write-Host ''
Write-Host '=== 6. Ket luan ===' -ForegroundColor Cyan
$t1 = $onlyOne
$t2 = ($deletedReport.Count -gt 0)
$t3 = ($survivors.Count -eq 1 -and $keepAlive)
$t4 = (-not (Test-Path (Join-Path $data 'proj-a')) -and -not (Test-Path (Join-Path $data 'proj-b')))

Write-Host ('    [1] Thu muc chi co 1 file .cmd               : {0}' -f $(if ($t1) { 'DAT' } else { 'HONG' }))
Write-Host ('    [2] Buoc xoa that chay (co da-xoa-*.json)    : {0}' -f $(if ($t2) { 'DAT' } else { 'HONG' }))
Write-Host ('    [3] Chi con file giu-lai                     : {0}' -f $(if ($t3) { 'DAT' } else { 'HONG' }))
Write-Host ('    [4] Ca 2 project gia da bi xoa               : {0}' -f $(if ($t4) { 'DAT' } else { 'HONG' }))

if ($t1 -and $t2 -and $t3 -and $t4) { exit 0 } else { exit 1 }
