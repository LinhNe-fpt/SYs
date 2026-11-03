#Requires -Version 5.1
<#
    presale-wiper.psm1 - Module root.

    Thứ tự load có phụ thuộc: paths -> size -> config -> classify -> guard -> walk -> report -> cli.
    (guard dùng $PswConfig nên config phải đứng trước.)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PswModuleRoot = $PSScriptRoot
$script:PswVersion = $null

$script:PswSourceFiles = @(
    'paths.ps1'
    'size.ps1'
    'config.ps1'
    'classify.ps1'
    'guard.ps1'
    'walk.ps1'
    'report.ps1'
    'log.ps1'
    'cli.ps1'
)

foreach ($file in $script:PswSourceFiles) {
    $sourcePath = Join-Path $PSScriptRoot $file
    if (Test-Path -LiteralPath $sourcePath) {
        . $sourcePath
    }
}

# Version từ manifest để report/JSON luôn khớp với cái đã cài.
try {
    $manifestPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'presale-wiper.psd1'
    if (Test-Path -LiteralPath $manifestPath) {
        $manifestData = Import-PowerShellDataFile -Path $manifestPath
        if ($null -ne $manifestData -and $manifestData.ContainsKey('ModuleVersion')) {
            $script:PswVersion = [string]$manifestData.ModuleVersion
        }
    }
} catch {
    $script:PswVersion = '0.1.0'
}
if ([string]::IsNullOrWhiteSpace($script:PswVersion)) { $script:PswVersion = '0.1.0' }

Initialize-PswConfig | Out-Null
