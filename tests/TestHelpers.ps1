#Requires -Version 5.1
<#
    TestHelpers.ps1 - Hàm dùng chung cho test.

    Dot-source file này ở đầu mỗi file .Tests.ps1.

    Vì sao fixtures được SINH thay vì commit:
      * '.git' / '.ssh' là folder rỗng trên git (git không track folder rỗng);
      * long path >260 ký tự không lưu được trong repo trên Windows;
      * node_modules/target chứa file rác làm repo phình to.

    Fixtures được sinh 1 lần cho mỗi lần chạy test (cache bằng marker file)
    để không phải tạo lại cây 300 ký tự cho từng Describe.
#>

Set-StrictMode -Version Latest

# TestHelpers.ps1 nằm ở tests\, nên gốc repo là thư mục cha của $PSScriptRoot.
$script:PswTestRepoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($script:PswTestRepoRoot)) {
    $script:PswTestRepoRoot = (Get-Location).Path
}

$script:PswTestModulePath = Join-Path $script:PswTestRepoRoot 'src\presale-wiper.psd1'

# Thư mục làm việc của test có thể bị đổi bằng biến môi trường
# PRESALE_WIPER_TEST_WORK, để chạy test trong môi trường cách ly
# (ổ khác, VM, Windows Sandbox) mà không ghi gì vào ổ hệ thống.
$script:PswTestWorkDir = $env:PRESALE_WIPER_TEST_WORK
if ([string]::IsNullOrWhiteSpace($script:PswTestWorkDir)) {
    $script:PswTestWorkDir = Join-Path $script:PswTestRepoRoot 'tests\.work'
}

function Get-PswTestWorkDir {
    <#
        .SYNOPSIS
        Thư mục làm việc của test (chứa fixtures, sandbox, log tạm).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:PswTestWorkDir
}

function Get-PswTestRepoRoot {
    <#
        .SYNOPSIS
        Gốc repo (thư mục chứa src\, tests\, presale-wiper.ps1).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:PswTestRepoRoot
}

function Get-PswTestModulePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:PswTestModulePath
}

function Import-PswTestModule {
    <#
        .SYNOPSIS
        Import module sạch (bỏ module cũ trong session để tránh cache state).
    #>
    [CmdletBinding()]
    param()

    Remove-Module -Name 'presale-wiper' -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:PswTestModulePath -Force -DisableNameChecking -ErrorAction Stop
}

function Get-PswTestFixtureRoot {
    <#
        .SYNOPSIS
        Trả về đường dẫn bộ fixtures đã sinh, sinh nếu chưa có.

        .DESCRIPTION
        Marker file '.ready' chứa số fixture đã tạo; nếu số này khớp với
        mong đợi thì dùng lại, ngược lại sinh mới.

        .PARAMETER Fresh
        Bắt buộc sinh lại từ đầu.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Fresh)

    $fixtures = Join-Path $script:PswTestWorkDir 'fixtures'
    $marker = Join-Path $script:PswTestWorkDir '.fixtures.ready'

    if (-not $Fresh -and (Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $fixtures)) {
        return $fixtures
    }

    if (-not (Test-Path -LiteralPath $script:PswTestWorkDir)) {
        [void][System.IO.Directory]::CreateDirectory($script:PswTestWorkDir)
    }

    $generator = Join-Path $script:PswTestRepoRoot 'tests\New-TestFixture.ps1'
    & $generator -Destination $fixtures -IncludeLongPath | Out-Null
    Set-Content -LiteralPath $marker -Value (Get-Date).ToString('o') -Encoding ASCII
    return $fixtures
}

function New-PswTestTree {
    <#
        .SYNOPSIS
        Tạo nhanh một cây thư mục từ mô tả dạng hashtable.

        .DESCRIPTION
        Khoá là đường dẫn tương đối dùng '/' làm phân cách.
        Giá trị:
          * [string]           -> tạo file với nội dung đó
          * [hashtable]        -> tạo thư mục rỗng (dùng @{})
          * @{ Size = <int> }  -> tạo file rỗng có kích thước đó

        .EXAMPLE
        New-PswTestTree -Root $dir -Tree @{
            'package.json'          = '{}'
            'src/index.js'          = 'x'
            'node_modules/lib/a.js' = 'x'
            'empty'                 = @{}
        }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][hashtable]$Tree
    )

    if (-not [System.IO.Directory]::Exists($Root)) {
        [void][System.IO.Directory]::CreateDirectory($Root)
    }

    foreach ($key in $Tree.Keys) {
        $relative = $key -replace '/', '\'
        $target = Join-Path $Root $relative
        $value = $Tree[$key]

        if ($value -is [hashtable]) {
            if (-not [System.IO.Directory]::Exists($target)) {
                [void][System.IO.Directory]::CreateDirectory($target)
            }
            continue
        }

        $parent = [System.IO.Path]::GetDirectoryName($target)
        if (-not [string]::IsNullOrEmpty($parent) -and -not [System.IO.Directory]::Exists($parent)) {
            [void][System.IO.Directory]::CreateDirectory($parent)
        }

        $content = [string]$value
        [System.IO.File]::WriteAllText($target, $content)
    }

    return $Root
}

function Remove-PswTestTree {
    <#
        .SYNOPSIS
        Xoá cây thư mục test, kể cả long path và file readonly.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $long = if ($Path.StartsWith('\\?\')) { $Path } else { '\\?\' + $Path }

    # Bỏ readonly trước (long path không dùng được thuộc tính của PS provider)
    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($long, '*', [System.IO.SearchOption]::AllDirectories)) {
            $attributes = [System.IO.File]::GetAttributes($file)
            if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                [System.IO.File]::SetAttributes($file, ($attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
            }
        }
    } catch { }

    try {
        [System.IO.Directory]::Delete($long, $true)
    } catch {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-PswTestFilePath {
    <#
        .SYNOPSIS
        Tạo path file giả lập (không cần tồn tại trên đĩa) để test guard.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$RelativeToSystemDrive)

    $drive = [Environment]::GetEnvironmentVariable('SystemDrive')
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'C:' }
    return "$drive\$RelativeToSystemDrive"
}
