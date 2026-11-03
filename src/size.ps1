#Requires -Version 5.1
<#
    size.ps1 - Đếm dung lượng.

    PowerShell 5.1 không có ForEach-Object -Parallel, nên chiến lược là:
      * enumerate bằng [System.IO.DirectoryInfo]::EnumerateFileSystemInfos()
        (nhanh hơn Get-ChildItem rất nhiều vì không tạo PSObject cho từng file);
      * cache theo folder để 1 lần scan không đếm lại cùng một folder;
      * cache theo (path, ticks) để lần scan sau dùng lại được.
#>

Set-StrictMode -Version Latest

$script:PswSizeCache = @{}
$script:PswSizeCacheRoot = $null

function Reset-PswSizeCache {
    <#
        .SYNOPSIS
        Xoá cache dung lượng. Gọi khi bắt đầu một lần scan mới.
    #>
    [CmdletBinding()]
    param()

    $script:PswSizeCache = @{}
    $script:PswSizeCacheRoot = $null
}

function Get-PswSizeCache {
    [CmdletBinding()]
    param()
    if ($null -eq $script:PswSizeCache) { $script:PswSizeCache = @{} }
    return $script:PswSizeCache
}

function Measure-PswDirectorySize {
    <#
        .SYNOPSIS
        Tổng dung lượng (byte) của mọi file nằm dưới folder, đệ quy.

        .DESCRIPTION
        - Không đi theo junction/symlink (chỉ tính kích thước link = 0)
          để tránh loop và tránh đếm dữ liệu ngoài cây.
        - Không ném lỗi; folder không đọc được coi như 0 byte.
        - Có cache theo folder: gọi nhiều lần cho cùng folder rất rẻ.
        - Có trần -MaxEntries để không treo máy với cây quá lớn.

        .PARAMETER NoCache
        Bỏ qua cache đọc (vẫn ghi cache mới).

        .OUTPUTS
        [long] số byte.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [int]$MaxEntries = 0,
        [switch]$NoCache
    )

    $full = Get-PswFullPath $Path
    if ($null -eq $full) { return 0L }

    $cache = Get-PswSizeCache
    if (-not $NoCache -and $cache.ContainsKey($full)) { return [long]$cache[$full] }

    $budget = 0
    if ($MaxEntries -le 0) { $budget = [int]::MaxValue } else { $budget = $MaxEntries }

    # Stack thay cho đệ quy: cây sâu >1000 level sẽ làm đệ quy nổ stack.
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($full)
    $total = 0L
    $visited = 0

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $children = $null

        try {
            $dirInfo = New-Object System.IO.DirectoryInfo (ConvertTo-PswLongPath $current)
            if (-not $dirInfo.Exists) { continue }
            $children = $dirInfo.EnumerateFileSystemInfos()
        } catch {
            continue
        }

        foreach ($item in $children) {
            $visited++
            if ($visited -gt $budget) { break }

            $attrs = $item.Attributes
            if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                # Junction/symlink: không đi vào, không tính kích thước target.
                continue
            }

            if (($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push((ConvertFrom-PswLongPath $item.FullName))
            } else {
                try { $total += [long]$item.Length } catch { }
            }
        }

        if ($visited -gt $budget) { break }
    }

    $cache[$full] = $total
    return $total
}

function Measure-PswEntrySize {
    <#
        .SYNOPSIS
        Dung lượng của một entry (file hoặc folder) đã có sẵn metadata.

        .PARAMETER IsDirectory
        True nếu là folder -> đo đệ quy. False -> lấy .Length.

        .PARAMETER Length
        Kích thước đã biết (với file). Nếu > -1 thì dùng luôn, khỏi I/O.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [switch]$IsDirectory,
        [long]$Length = -1,
        [int]$MaxEntries = 0
    )

    if ($IsDirectory) {
        return Measure-PswDirectorySize -Path $Path -MaxEntries $MaxEntries
    }

    if ($Length -ge 0) { return $Length }

    try {
        $info = New-Object System.IO.FileInfo (ConvertTo-PswLongPath $Path)
        if ($info.Exists) { return [long]$info.Length }
    } catch { }
    return 0L
}

function Format-PswSize {
    <#
        .SYNOPSIS
        Đổi byte sang chuỗi dễ đọc: "1.4 GB", "812 KB", "37 B".

        .DESCRIPTION
        Dùng đơn vị nhị phân (1 KB = 1024 B) nhưng nhãn KB/MB/GB quen thuộc.
        Luôn dùng dấu chấm thập phân để JSON/log ổn định giữa các locale.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][long]$Bytes,
        [int]$Decimals = 1
    )

    if ($Bytes -lt 0) { return '0 B' }

    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$Bytes
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }

    if ($index -eq 0) { return ('{0} B' -f $Bytes) }

    $format = '{0:F' + $Decimals + '} {1}'
    return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $format, $value, $units[$index]))
}

function ConvertTo-PswSizeText {
    <#
        .SYNOPSIS
        Alias của Format-PswSize (tên đọc xuôi hơn khi dùng trong pipeline).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)][long]$Bytes,
        [int]$Decimals = 1
    )
    process { Format-PswSize -Bytes $Bytes -Decimals $Decimals }
}
