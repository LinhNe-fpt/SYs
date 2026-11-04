#Requires -Version 5.1
<#
.SYNOPSIS
    Benchmark scan-once.ps1 trên bộ dữ liệu giả lập cố định (không quét máy thật).

.EXAMPLE
    .\tests\Measure-ScanOnce.ps1 -Runs 3
    .\tests\Measure-ScanOnce.ps1 -Script C:\old\scan-once.ps1
#>
param(
    [string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scan-once.ps1'),
    [string]$WorkDir = (Join-Path $PSScriptRoot '.work\bench'),
    [int]$Runs = 3
)

$ErrorActionPreference = 'Stop'
$data = Join-Path $WorkDir 'data'
$out = Join-Path $WorkDir 'out'

if (-not (Test-Path -LiteralPath (Join-Path $data '.done'))) {
    Write-Host "Tạo dữ liệu benchmark tại $data ..."
    $null = New-Item -ItemType Directory -Path $data -Force
    $payload = 'x' * 64

    # 30 project node, mỗi cái có node_modules ~1.000 file
    for ($p = 0; $p -lt 30; $p++) {
        $proj = Join-Path $data "projects\web-$p"
        $null = New-Item -ItemType Directory -Path (Join-Path $proj 'src') -Force
        [IO.File]::WriteAllText((Join-Path $proj 'package.json'), '{}')
        for ($i = 0; $i -lt 20; $i++) { [IO.File]::WriteAllText((Join-Path $proj "src\f$i.ts"), $payload) }
        for ($m = 0; $m -lt 50; $m++) {
            $mod = Join-Path $proj "node_modules\mod$m\lib"
            $null = New-Item -ItemType Directory -Path $mod -Force
            for ($i = 0; $i -lt 20; $i++) { [IO.File]::WriteAllText((Join-Path $mod "f$i.js"), $payload) }
        }
    }

    # Cây tài liệu không phải code: 1.500 thư mục, mỗi cái 5 file
    for ($a = 0; $a -lt 30; $a++) {
        for ($b = 0; $b -lt 50; $b++) {
            $dir = Join-Path $data "docs\d$a\e$b"
            $null = New-Item -ItemType Directory -Path $dir -Force
            for ($i = 0; $i -lt 5; $i++) { [IO.File]::WriteAllText((Join-Path $dir "note$i.txt"), $payload) }
        }
    }

    # File code lẻ và secret rải rác
    $loose = Join-Path $data 'loose'
    $null = New-Item -ItemType Directory -Path $loose -Force
    for ($i = 0; $i -lt 300; $i++) { [IO.File]::WriteAllText((Join-Path $loose "q$i.sql"), $payload) }
    for ($i = 0; $i -lt 300; $i++) { [IO.File]::WriteAllText((Join-Path $loose "doc$i.docx"), $payload) }
    [IO.File]::WriteAllText((Join-Path $loose '.env'), 'A=1')

    [IO.File]::WriteAllText((Join-Path $data '.done'), '')
}

$times = @()
$summary = $null
for ($r = 1; $r -le $Runs; $r++) {
    if (Test-Path -LiteralPath $out) { Get-ChildItem -LiteralPath $out -Force | Remove-Item -Recurse -Force }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -Path $data -OutDir $out -Quiet
    $sw.Stop()
    $times += $sw.Elapsed.TotalSeconds
    $summary = ($lines | Select-String 'Mục \(|File cụ thể|Tổng dung') -join ' | '
    Write-Host ("Lần {0}: {1:N2}s" -f $r, $sw.Elapsed.TotalSeconds)
}

$json = Get-ChildItem -LiteralPath $out -Filter '*.json' | Select-Object -First 1
[PSCustomObject]@{
    Script   = $Script
    MedianS  = [math]::Round((($times | Sort-Object)[[int][math]::Floor($times.Count / 2)]), 2)
    Summary  = $summary
    JsonHash = if ($json) { (Get-FileHash -LiteralPath $json.FullName).Hash } else { $null }
}
