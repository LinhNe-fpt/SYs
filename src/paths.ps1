#Requires -Version 5.1
<#
    paths.ps1 - Tiện ích đường dẫn.

    Trên Windows 10 1903+ (và mọi bản .NET Framework 4.x), các API System.IO
    vẫn giới hạn 260 ký tự trừ khi path có prefix \\?\ hoặc \\?\UNC\.
    Toàn bộ I/O của presale-wiper đi qua các hàm ở đây để chỉ có MỘT nơi
    xử lý prefix này.

    Quy ước: prefix chỉ được thêm ở lớp I/O, KHÔNG lưu vào object/entry/report.
#>

Set-StrictMode -Version Latest

$script:PswLongPathPrefix = '\\?\'
$script:PswUncPrefix = '\\?\UNC\'

function ConvertTo-PswLongPath {
    <#
        .SYNOPSIS
        Thêm prefix \\?\ (hoặc \\?\UNC\) để vượt giới hạn MAX_PATH.

        .DESCRIPTION
        Idempotent: truyền vào path đã có prefix thì trả về nguyên trạng.
        Path tương đối sẽ được chuẩn hoá thành tuyệt đối trước.

        .EXAMPLE
        ConvertTo-PswLongPath 'C:\a\b'
        -> '\\?\C:\a\b'

        .EXAMPLE
        ConvertTo-PswLongPath '\\server\share\dir'
        -> '\\?\UNC\server\share\dir'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $Path }
    if ($Path.StartsWith('\\.\', [StringComparison]::Ordinal)) { return $Path }

    # UNC: \\server\share -> \\?\UNC\server\share
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        return $script:PswUncPrefix + $Path.Substring(2).TrimStart('\')
    }

    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full)) {
        try { $full = [System.IO.Path]::GetFullPath($full) } catch { }
    }

    if ($full -match '^[A-Za-z]:\\{2,}') {
        # 'C:\\\\foo' -> 'C:\foo'
        $full = $full -replace '\\{2,}', '\'
    }
    if ($full.EndsWith('\') -and $full.Length -gt 3) {
        $full = $full.TrimEnd('\')
    }

    return $script:PswLongPathPrefix + $full
}

function ConvertFrom-PswLongPath {
    <#
        .SYNOPSIS
        Bỏ prefix \\?\ / \\?\UNC\ để hiển thị cho người dùng.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith($script:PswUncPrefix, [StringComparison]::Ordinal)) {
        return '\\' + $Path.Substring($script:PswUncPrefix.Length)
    }
    if ($Path.StartsWith($script:PswLongPathPrefix, [StringComparison]::Ordinal)) {
        return $Path.Substring($script:PswLongPathPrefix.Length)
    }
    return $Path
}

function Get-PswFullPath {
    <#
        .SYNOPSIS
        Chuẩn hoá path thành tuyệt đối, bỏ '.'/'..', bỏ '\' cuối.

        .DESCRIPTION
        Dùng [System.IO.Path]::GetFullPath để không phụ thuộc vào
        PowerShell provider. Không kiểm tra tồn tại.
        Trả về $null nếu path không hợp lệ.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $candidate = ConvertFrom-PswLongPath $Path

    # Mở rộng %VAR% và ~ cho tiện dùng tay
    if ($candidate -match '%[^%]+%') {
        $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
    }
    if ($candidate -eq '~') { $candidate = $script:PswConfig.HomeDir }
    elseif ($candidate.StartsWith('~\', [StringComparison]::Ordinal)) {
        $candidate = Join-Path $script:PswConfig.HomeDir $candidate.Substring(2)
    }

    # 'C:' phải được hiểu là gốc ổ 'C:\', KHÔNG phải thư mục hiện hành của ổ đó
    # (đó là ngữ nghĩa kỳ quặc của Win32 mà .NET kế thừa từ cmd.exe).
    if ($candidate -match '^[A-Za-z]:$') { return $candidate + '\' }

    try {
        $full = [System.IO.Path]::GetFullPath($candidate)
    } catch {
        return $null
    }

    if ($full.Length -gt 3 -and $full.EndsWith('\')) { $full = $full.TrimEnd('\') }
    return $full
}

function Resolve-PswRootPath {
    <#
        .SYNOPSIS
        Chuẩn hoá + kiểm tra một root dùng để scan.
        Trả về object: Path, Exists, IsDirectory, Error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    $full = Get-PswFullPath $Path
    $result = [PSCustomObject]@{
        Input       = $Path
        Path        = $full
        Exists      = $false
        IsDirectory = $false
        Error       = $null
    }

    if ($null -eq $full) {
        $result.Error = 'Đường dẫn không hợp lệ.'
        return $result
    }

    $long = ConvertTo-PswLongPath $full
    try {
        if ([System.IO.Directory]::Exists($long)) {
            $result.Exists = $true
            $result.IsDirectory = $true
        } elseif ([System.IO.File]::Exists($long)) {
            $result.Exists = $true
        } else {
            $result.Error = 'Không tìm thấy đường dẫn.'
        }
    } catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Test-PswPathExists {
    <#
        .SYNOPSIS
        Tồn tại (file hoặc folder)? Dùng được với long path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $long = ConvertTo-PswLongPath $Path
    try {
        if ([System.IO.Directory]::Exists($long)) { return $true }
        return [System.IO.File]::Exists($long)
    } catch {
        return $false
    }
}

function Test-PswSamePath {
    <#
        .SYNOPSIS
        So sánh 2 path theo đúng ngữ nghĩa Windows (không phân biệt hoa/thường,
        bỏ '\' cuối, chấp nhận long-path prefix).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Other
    )

    $a = Get-PswFullPath $Path
    $b = Get-PswFullPath $Other
    if ($null -eq $a -or $null -eq $b) { return $false }
    return [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PswPathIsUnder {
    <#
        .SYNOPSIS
        $Path có nằm trong (hoặc bằng) $Parent không?

        .DESCRIPTION
        So sánh theo ranh giới component, nên
        'C:\foo-bar' KHÔNG nằm dưới 'C:\foo'.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][string]$Parent
    )

    $a = Get-PswFullPath $Path
    $b = Get-PswFullPath $Parent
    if ($null -eq $a -or $null -eq $b) { return $false }

    if ([string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    $prefix = if ($b.EndsWith('\')) { $b } else { $b + '\' }
    return $a.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PswParentPath {
    <#
        .SYNOPSIS
        Folder cha của path, hoặc $null nếu là gốc ổ đĩa / UNC share.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    $full = Get-PswFullPath $Path
    if ($null -eq $full) { return $null }

    try {
        $parent = [System.IO.Path]::GetDirectoryName($full)
    } catch {
        return $null
    }
    if ([string]::IsNullOrEmpty($parent)) { return $null }
    return $parent
}

function Get-PswPathDepth {
    <#
        .SYNOPSIS
        Số component của path ('C:\' = 0, 'C:\a\b' = 2).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    $full = Get-PswFullPath $Path
    if ($null -eq $full) { return -1 }
    $normalized = $full.TrimEnd('\')
    if ($normalized -match '^[A-Za-z]:$') { return 0 }
    return @($normalized.Split('\') | Where-Object { $_ -ne '' }).Count - 1
}

function Get-PswRelativePath {
    <#
        .SYNOPSIS
        Path tương đối so với $Base (dùng để log gọn).
        Nếu không nằm dưới $Base, trả về path tuyệt đối.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][string]$Base
    )

    $full = Get-PswFullPath $Path
    $baseFull = Get-PswFullPath $Base
    if ($null -eq $full) { return $Path }
    if ($null -eq $baseFull) { return $full }

    if (-not (Test-PswPathIsUnder -Path $full -Parent $baseFull)) { return $full }
    if ([string]::Equals($full, $baseFull, [StringComparison]::OrdinalIgnoreCase)) { return '.' }

    $prefixLen = if ($baseFull.EndsWith('\')) { $baseFull.Length } else { $baseFull.Length + 1 }
    if ($prefixLen -ge $full.Length) { return '.' }
    return $full.Substring($prefixLen)
}

function Test-PswIsReparsePoint {
    <#
        .SYNOPSIS
        Path có phải junction / symlink / mount point không?

        .DESCRIPTION
        Quan trọng cho an toàn: KHÔNG đi theo junction (ví dụ
        'C:\Users\All Users' -> 'C:\ProgramData') vì sẽ gây loop vô hạn
        hoặc xoá nhầm dữ liệu ngoài cây thư mục đang xét.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [System.IO.FileAttributes]$Attributes = [System.IO.FileAttributes]::Directory
    )

    if (($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }

    try {
        $long = ConvertTo-PswLongPath $Path
        $info = New-Object System.IO.DirectoryInfo $long
        if (-not $info.Exists) { return $false }
        return (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Join-PswPath {
    <#
        .SYNOPSIS
        Nối path AN TOÀN kể cả khi path đã có prefix \\?\.

        .DESCRIPTION
        Join-Path của PowerShell hiểu '\\?\C:\dir' là "drive \\?\C:" và ném
        lỗi "the value of argument drive is null". Vì vậy mọi chỗ nối path
        trong module dùng hàm này thay cho Join-Path.

        .EXAMPLE
        Join-PswPath 'C:\dir' 'file.log'      -> 'C:\dir\file.log'
        Join-PswPath '\\?\C:\dir' 'file.log'  -> '\\?\C:\dir\file.log'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Child
    )

    if ([string]::IsNullOrEmpty($Path)) { return $Child }
    if ([string]::IsNullOrEmpty($Child)) { return $Path }

    # Nếu Child đã là path tuyệt đối thì trả về Child (Join-Path cũng vậy)
    $childHasDrive = $Child -match '^[A-Za-z]:[\\/]'
    $childIsUnc = $Child.StartsWith('\\')
    $childIsRooted = $childHasDrive -or $childIsUnc
    if ($childIsRooted) {
        return ConvertFrom-PswLongPath $Child
    }

    $trimmed = if ($Path.EndsWith('\') -or $Path.EndsWith('/')) { $Path } else { $Path + '\' }
    $cleanChild = $Child.TrimStart('\', '/')
    return $trimmed + $cleanChild
}

function Get-PswFileSystemInfos {
    <#
        .SYNOPSIS
        Liệt kê con trực tiếp của 1 folder, trả về FileSystemInfo[].

        .DESCRIPTION
        - Dùng API .NET với long-path prefix (không đi qua provider của PS).
        - Không ném lỗi khi gặp folder không có quyền: ghi vào -Errors.
        - Trả về mảng rỗng nếu không đọc được.

        .PARAMETER Errors
        Danh sách (List[object]) để nhận lỗi dạng @{ Path; Error }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [System.Collections.Generic.List[object]]$Errors
    )

    $long = ConvertTo-PswLongPath $Path
    $result = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'

    try {
        $dirInfo = New-Object System.IO.DirectoryInfo $long
        if (-not $dirInfo.Exists) {
            if ($null -ne $Errors) {
                [void]$Errors.Add([PSCustomObject]@{
                        Path  = (ConvertFrom-PswLongPath $Path)
                        Error = 'Folder không tồn tại hoặc đã bị xoá.'
                    })
            }
            return $result.ToArray()
        }

        foreach ($info in $dirInfo.EnumerateFileSystemInfos()) {
            [void]$result.Add($info)
        }
    } catch [System.UnauthorizedAccessException] {
        if ($null -ne $Errors) {
            [void]$Errors.Add([PSCustomObject]@{ Path = (ConvertFrom-PswLongPath $Path); Error = 'Từ chối truy cập (UnauthorizedAccess).' })
        }
    } catch [System.IO.DirectoryNotFoundException] {
        if ($null -ne $Errors) {
            [void]$Errors.Add([PSCustomObject]@{ Path = (ConvertFrom-PswLongPath $Path); Error = 'Folder không tồn tại hoặc đã bị xoá.' })
        }
    } catch [System.IO.PathTooLongException] {
        if ($null -ne $Errors) {
            [void]$Errors.Add([PSCustomObject]@{ Path = (ConvertFrom-PswLongPath $Path); Error = 'Đường dẫn quá dài (PathTooLong).' })
        }
    } catch {
        if ($null -ne $Errors) {
            [void]$Errors.Add([PSCustomObject]@{
                    Path  = (ConvertFrom-PswLongPath $Path)
                    Error = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
                })
        }
    }

    return $result.ToArray()
}

function Remove-PswLongPathPrefix {
    <#
        .SYNOPSIS
        Alias tương thích ngược của ConvertFrom-PswLongPath.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    return ConvertFrom-PswLongPath $Path
}
