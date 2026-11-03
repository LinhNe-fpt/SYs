#Requires -Version 5.1
<#
    walk.ps1 - Duyệt cây thư mục và sinh danh sách entry.

    Chiến lược duyệt (DFS có kiểm soát):

      * Folder KHÔNG phải project  -> đi tiếp vào bên trong (nó là container).
      * Folder LÀ project          -> ghi nhận entry Project, KHÔNG đi vào
                                      (tránh liệt kê 50.000 file của 1 repo).
      * Folder rác dev             -> ghi nhận entry DevDir, KHÔNG đi vào.
      * Folder bị media chi phối   -> ghi nhận MediaHeavy (để minh bạch),
                                      KHÔNG đưa vào danh sách xoá.
      * Junction/symlink           -> KHÔNG đi theo (chống loop + xoá nhầm).

    Kết quả là một object Report-ish:
        @{ Roots; Entries; Errors; Stats }
#>

Set-StrictMode -Version Latest

function New-PswScanOptions {
    <#
        .SYNOPSIS
        Bộ tuỳ chọn cho Invoke-PswScan (không phải param của CLI, chỉ default).
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }
    $defaults = $script:PswConfig.Defaults

    return [PSCustomObject]@{
        MaxDepth        = [int]$defaults.MaxDepth
        MaxEntries      = [int]$defaults.MaxEntriesVisited
        MinSizeBytes    = [long]$defaults.MinSizeBytes
        IncludeHome     = $false
        IncludeSecrets  = $true
        SkipSize        = $false
        Quiet           = $false
        ExcludePatterns = @()
        ExcludePaths    = @()
        FollowLinks     = $false
    }
}

function New-PswEntry {
    <#
        .SYNOPSIS
        Tạo một entry chuẩn cho report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][string]$Kind,
        [switch]$IsDirectory,
        [long]$SizeBytes = 0,
        [string]$Reason = '',
        [bool]$Protected = $false,
        [string]$ProtectionReason = '',
        [int]$Depth = 0
    )

    return [PSCustomObject]@{
        Path             = $Path
        Name             = [System.IO.Path]::GetFileName($Path)
        Kind             = $Kind
        IsDirectory      = [bool]$IsDirectory
        SizeBytes        = [long]$SizeBytes
        Depth            = [int]$Depth
        Reason           = $Reason
        Protected        = [bool]$Protected
        ProtectionReason = $ProtectionReason
    }
}

function Test-PswExcluded {
    <#
        .SYNOPSIS
        Path có khớp danh sách loại trừ (wildcard trên full path, hoặc
        khớp tên folder)?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [string[]]$Patterns = @(),
        [string[]]$ExactPaths = @()
    )

    foreach ($exact in $ExactPaths) {
        if ([string]::IsNullOrWhiteSpace($exact)) { continue }
        if (Test-PswPathIsUnder -Path $Path -Parent $exact) { return $true }
    }

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) { return $false }

    $leaf = [System.IO.Path]::GetFileName($Path)
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Path -like $pattern) { return $true }
        if ($leaf -like $pattern) { return $true }
    }
    return $false
}

function Get-PswChildProfiles {
    <#
        .SYNOPSIS
        Đọc 1 folder và trả về hồ sơ của chính folder đó + danh sách con.

        .DESCRIPTION
        Kết quả được cache trong -Cache để lần descend sau không phải
        enumerate lại (mỗi folder chỉ đọc đĩa 1 lần).

        .OUTPUTS
        Hashtable: @{ Profile; Children; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [hashtable]$Cache,
        [System.Collections.Generic.List[object]]$Errors
    )

    if ($null -ne $Cache -and $Cache.ContainsKey($Path)) { return $Cache[$Path] }

    $profile = New-PswFolderProfile -Path $Path
    $children = Get-PswFileSystemInfos -Path $Path -Errors $Errors

    foreach ($child in $children) {
        Add-PswChildToProfile -Profile $profile -Info $child
    }

    $result = @{ Profile = $profile; Children = $children }
    if ($null -ne $Cache) { $Cache[$Path] = $result }
    return $result
}

function Invoke-PswScan {
    <#
        .SYNOPSIS
        Quét một hoặc nhiều root, trả về danh sách entry + thống kê.

        .PARAMETER Root
        Một hoặc nhiều đường dẫn. Nếu rỗng -> dùng root mặc định (dev paths).

        .PARAMETER Options
        Object từ New-PswScanOptions (hoặc hashtable cùng khoá).

        .OUTPUTS
        [PSCustomObject] với Roots, Entries, Errors, Stats.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$Root = @(),
        $Options
    )

    if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }
    Reset-PswSizeCache

    $opt = ConvertTo-PswScanOptions $Options

    $started = Get-Date
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $errors = New-Object 'System.Collections.Generic.List[object]'
    $cache = @{}
    $rootReports = New-Object 'System.Collections.Generic.List[object]'

    $stats = [PSCustomObject]@{
        FoldersVisited   = 0
        FilesVisited     = 0
        EntriesVisited   = 0
        Projects         = 0
        DevDirs          = 0
        Secrets          = 0
        CodeFiles        = 0
        MediaHeavy       = 0
        LinksSkipped     = 0
        ProtectedSkipped = 0
        Truncated        = $false
        TruncatedAt      = $null
    }

    if ($null -eq $Root -or $Root.Count -eq 0) {
        $Root = @(Get-PswDefaultScanRoots -IncludeHome:$opt.IncludeHome)
    }

    if ($Root.Count -eq 0) {
        $errors.Add([PSCustomObject]@{ Path = '(none)'; Error = 'Không tìm thấy thư mục dev nào để quét. Dùng -Path để chỉ định.' })
    }

    foreach ($rawRoot in $Root) {
        $resolved = Resolve-PswRootPath $rawRoot
        $rootReport = [PSCustomObject]@{
            Input   = $rawRoot
            Path    = $resolved.Path
            Status  = 'Scanned'
            Error   = $null
            Entries = 0
        }

        if ($null -eq $resolved.Path) {
            $rootReport.Status = 'Invalid'
            $rootReport.Error = $resolved.Error
            $errors.Add([PSCustomObject]@{ Path = $rawRoot; Error = $resolved.Error })
            $rootReports.Add($rootReport)
            continue
        }

        if (-not $opt.IncludeHome) {
            $blockReason = Get-PswScanRootBlockReason -Path $resolved.Path
            if ($null -ne $blockReason) {
                $rootReport.Status = 'Blocked'
                $rootReport.Error = $blockReason
                $errors.Add([PSCustomObject]@{ Path = $resolved.Path; Error = $blockReason })
                $rootReports.Add($rootReport)
                continue
            }
        }

        if (-not $resolved.Exists) {
            $rootReport.Status = 'Missing'
            $rootReport.Error = 'Không tìm thấy đường dẫn.'
            $errors.Add([PSCustomObject]@{ Path = $resolved.Path; Error = 'Không tìm thấy đường dẫn.' })
            $rootReports.Add($rootReport)
            continue
        }

        if (-not $resolved.IsDirectory) {
            # Root là 1 file: phân loại trực tiếp.
            $kind = Get-PswFileKind ([System.IO.Path]::GetFileName($resolved.Path))
            if ($kind -eq 'Secret' -or $kind -eq 'Code') {
                $entryKind = if ($kind -eq 'Secret') { 'Secret' } else { 'CodeFile' }
                $reason = Get-PswProtectionReason -Path $resolved.Path
                $entries.Add((New-PswEntry -Path $resolved.Path -Kind $entryKind -SizeBytes (Measure-PswEntrySize -Path $resolved.Path) -Reason "Root là file $kind" -Protected ($null -ne $reason) -ProtectionReason $reason))
                if ($entryKind -eq 'Secret') { $stats.Secrets++ } else { $stats.CodeFiles++ }
                $rootReport.Entries++
            }
            $rootReports.Add($rootReport)
            continue
        }

        $before = $entries.Count
        Invoke-PswScanFolder -Path $resolved.Path -Depth 0 -Options $opt -Entries $entries `
            -Errors $errors -Stats $stats -Cache $cache
        $rootReport.Entries = $entries.Count - $before
        $rootReports.Add($rootReport)
    }

    $duration = (Get-Date) - $started

    $stats | Add-Member -NotePropertyName DurationMs -NotePropertyValue ([long]$duration.TotalMilliseconds)

    $filtered = $entries
    if ($opt.MinSizeBytes -gt 0) {
        $filtered = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in $entries) {
            if ($entry.SizeBytes -ge $opt.MinSizeBytes) { $filtered.Add($entry) }
        }
    }

    return [PSCustomObject]@{
        Roots   = $rootReports.ToArray()
        Entries = $filtered.ToArray()
        Errors  = $errors.ToArray()
        Stats   = $stats
        Options = $opt
    }
}

function Invoke-PswScanFolder {
    <#
        .SYNOPSIS
        Phần đệ quy của Invoke-PswScan (nội bộ).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth,
        [Parameter(Mandatory)]$Options,
        [Parameter(Mandatory)]$Entries,
        [Parameter(Mandatory)]$Errors,
        [Parameter(Mandatory)]$Stats,
        [Parameter(Mandatory)][hashtable]$Cache
    )

    if ($Stats.EntriesVisited -ge $Options.MaxEntries) {
        Set-PswScanTruncated -Stats $Stats -Errors $Errors -Path $Path -MaxEntries $Options.MaxEntries
        return
    }

    $bundle = Get-PswChildProfiles -Path $Path -Cache $Cache -Errors $Errors
    $Stats.FoldersVisited++
    $Stats.EntriesVisited += @($bundle.Children).Count

    if (-not $Options.Quiet -and ($Stats.EntriesVisited % 500) -lt @($bundle.Children).Count) {
        try {
            Write-Progress -Activity 'presale-wiper: đang quét' -Status "$($Stats.FoldersVisited) folder, $($Stats.EntriesVisited) entry" -CurrentOperation (Get-PswTruncatedText $Path 70)
        } catch { }
    }

    foreach ($child in $bundle.Children) {
        # Kiểm tra trần ngay trong vòng lặp: một folder có 500.000 file sẽ
        # không bao giờ chạm trần nếu chỉ kiểm tra ở đầu mỗi folder.
        if ($Stats.EntriesVisited -ge $Options.MaxEntries) {
            Set-PswScanTruncated -Stats $Stats -Errors $Errors -Path $Path -MaxEntries $Options.MaxEntries
            return
        }
        if ($Stats.Truncated) { return }

        $childPath = ConvertFrom-PswLongPath $child.FullName
        $attrs = $child.Attributes
        $isDir = ($attrs -band [System.IO.FileAttributes]::Directory) -ne 0
        $isLink = ($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        $name = $child.Name

        # Junction / symlink: bỏ qua hoàn toàn (không đi theo, không xoá target)
        if ($isLink) {
            $Stats.LinksSkipped++
            continue
        }

        if (Test-PswExcluded -Path $childPath -Patterns $Options.ExcludePatterns -ExactPaths $Options.ExcludePaths) {
            continue
        }

        if ($isDir) {
            # Folder hệ thống / không quan tâm: bỏ qua, không đi vào
            if (Test-PswIsSkipDirName $name) { continue }

            # Rác dev: báo cáo, không đi vào
            if (Test-PswIsDevDirName $name) {
                if ($Stats.FilesVisited % 200 -eq 0) { }
                $protection = Get-PswProtectionReason -Path $childPath
                $size = if ($Options.SkipSize) { 0L } else { Measure-PswDirectorySize -Path $childPath -MaxEntries $Options.MaxEntries }
                $Entries.Add((New-PswEntry -Path $childPath -Kind 'DevDir' -IsDirectory `
                            -SizeBytes $size -Depth ($Depth + 1) `
                            -Reason "Thư mục rác của dev: $name" `
                            -Protected ($null -ne $protection) -ProtectionReason $protection))
                $Stats.DevDirs++
                if ($null -ne $protection) { $Stats.ProtectedSkipped++ }
                continue
            }

            # Secret folder: báo cáo, không đi vào
            if (Test-PswIsSecretDirName $name) {
                $protection = Get-PswProtectionReason -Path $childPath
                $size = if ($Options.SkipSize) { 0L } else { Measure-PswDirectorySize -Path $childPath -MaxEntries $Options.MaxEntries }
                $Entries.Add((New-PswEntry -Path $childPath -Kind 'Secret' -IsDirectory `
                            -SizeBytes $size -Depth ($Depth + 1) `
                            -Reason "Thư mục chứa thông tin đăng nhập: $name" `
                            -Protected ($null -ne $protection) -ProtectionReason $protection))
                $Stats.Secrets++
                if ($null -ne $protection) { $Stats.ProtectedSkipped++ }
                continue
            }

            # Phân loại theo hồ sơ của chính folder con
            if (($Depth + 1) -gt $Options.MaxDepth) { continue }

            $childBundle = Get-PswChildProfiles -Path $childPath -Cache $Cache -Errors $Errors
            $Stats.EntriesVisited += @($childBundle.Children).Count

            $verdict = Get-PswFolderKind -Profile $childBundle.Profile
            $kind = $verdict.Kind
            $reason = (@($verdict.Reasons) -join '; ')

            switch ($kind) {
                'Project' {
                    $protection = Get-PswProtectionReason -Path $childPath
                    $size = if ($Options.SkipSize) { 0L } else { Measure-PswDirectorySize -Path $childPath -MaxEntries $Options.MaxEntries }
                    $Entries.Add((New-PswEntry -Path $childPath -Kind 'Project' -IsDirectory `
                                -SizeBytes $size -Depth ($Depth + 1) -Reason $reason `
                                -Protected ($null -ne $protection) -ProtectionReason $protection))
                    $Stats.Projects++
                    if ($null -ne $protection) { $Stats.ProtectedSkipped++ }
                }
                'MediaHeavy' {
                    # Báo cáo để user thấy "tại sao folder này không bị đề xuất xoá",
                    # nhưng luôn Protected: tool không bao giờ tự đề xuất xoá
                    # một cây mà nó không chắc là code.
                    $size = if ($Options.SkipSize) { 0L } else { Measure-PswDirectorySize -Path $childPath -MaxEntries $Options.MaxEntries }
                    $Entries.Add((New-PswEntry -Path $childPath -Kind 'MediaHeavy' -IsDirectory `
                                -SizeBytes $size -Depth ($Depth + 1) -Reason $reason `
                                -Protected $true -ProtectionReason 'Không đủ dấu hiệu code; bị media chi phối.'))
                    $Stats.MediaHeavy++
                }
                default {
                    # Container: đi tiếp vào bên trong
                    Invoke-PswScanFolder -Path $childPath -Depth ($Depth + 1) -Options $Options `
                        -Entries $Entries -Errors $Errors -Stats $Stats -Cache $Cache
                }
            }
            continue
        }

        # ---- File ----
        $Stats.FilesVisited++
        $fileKind = Get-PswFileKind $name

        if ($fileKind -eq 'Secret') {
            $protection = Get-PswProtectionReason -Path $childPath
            $size = if ($Options.SkipSize) { 0L } else { Get-PswChildLength $child }
            $Entries.Add((New-PswEntry -Path $childPath -Kind 'Secret' -SizeBytes $size `
                        -Depth ($Depth + 1) -Reason "File chứa thông tin đăng nhập: $name" `
                        -Protected ($null -ne $protection) -ProtectionReason $protection))
            $Stats.Secrets++
            if ($null -ne $protection) { $Stats.ProtectedSkipped++ }
            continue
        }

        if ($fileKind -eq 'Code') {
            $protection = Get-PswProtectionReason -Path $childPath
            $size = if ($Options.SkipSize) { 0L } else { Get-PswChildLength $child }
            $Entries.Add((New-PswEntry -Path $childPath -Kind 'CodeFile' -SizeBytes $size `
                        -Depth ($Depth + 1) -Reason 'File source code nằm ngoài project' `
                        -Protected ($null -ne $protection) -ProtectionReason $protection))
            $Stats.CodeFiles++
            if ($null -ne $protection) { $Stats.ProtectedSkipped++ }
        }
    }
}

function Set-PswScanTruncated {
    <#
        .SYNOPSIS
        Đánh dấu đã chạm trần duyệt (ghi lỗi 1 lần duy nhất).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Stats,
        [Parameter(Mandatory, Position = 1)]$Errors,
        [Parameter(Mandatory, Position = 2)][string]$Path,
        [Parameter(Mandatory, Position = 3)][int]$MaxEntries
    )

    if ($Stats.Truncated) { return }
    $Stats.Truncated = $true
    $Stats.TruncatedAt = $Path
    $Errors.Add([PSCustomObject]@{
            Path  = $Path
            Error = "Đã chạm trần $MaxEntries entry, dừng duyệt để bảo vệ máy."
        })
}

function Get-PswChildLength {
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory, Position = 0)]$Info)

    try {
        if ($null -ne $Info.Length) { return [long]$Info.Length }
    } catch { }
    return 0L
}

function ConvertTo-PswScanOptions {
    <#
        .SYNOPSIS
        Chuẩn hoá options: nhận hashtable hoặc object, thiếu thì lấy default.
    #>
    [CmdletBinding()]
    param($Options)

    $defaults = New-PswScanOptions
    if ($null -eq $Options) { return $defaults }

    foreach ($property in $defaults.PSObject.Properties) {
        $name = $property.Name
        $hasValue = $false
        $value = $null

        if ($Options -is [hashtable]) {
            if ($Options.ContainsKey($name)) { $hasValue = $true; $value = $Options[$name] }
        } else {
            $optionProperty = $Options.PSObject.Properties[$name]
            if ($null -ne $optionProperty) { $hasValue = $true; $value = $optionProperty.Value }
        }

        if ($hasValue -and $null -ne $value) { $defaults.$name = $value }
    }
    return $defaults
}

function Get-PswDefaultScanRoots {
    <#
        .SYNOPSIS
        Đoán các root cần quét khi user không truyền path.

        .DESCRIPTION
        KHÔNG mặc định quét cả %USERPROFILE%: quá rộng và dễ chạm file
        người dùng. Thay vào đó:
          1. Các folder dev quen thuộc dưới home (source\repos, Projects...).
          2. Các folder dev nằm ngay gốc mỗi ổ đĩa cố định (C:\Projects...).
          3. Nếu -IncludeHome: chính %USERPROFILE% (trừ các folder hệ thống).

        Chỉ trả về path đang tồn tại.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$IncludeHome)

    if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }

    $found = New-Object 'System.Collections.Generic.List[string]'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $home = $script:PswConfig.HomeDir

    if ($IncludeHome -and -not [string]::IsNullOrWhiteSpace($home)) {
        if ((Test-PswPathExists $home) -and $seen.Add($home)) { $found.Add($home) }
    }

    foreach ($relative in $script:PswConfig.RelativeDevPaths) {
        if ([string]::IsNullOrWhiteSpace($home)) { break }
        $candidate = Join-Path $home $relative
        if ((Test-PswPathExists $candidate) -and $seen.Add($candidate)) { $found.Add($candidate) }
    }

    try {
        $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object {
            $_.IsReady -and ($_.DriveType -eq [System.IO.DriveType]::Fixed)
        }
        foreach ($drive in $drives) {
            foreach ($folderName in $script:PswConfig.DevRootNamesAtDriveRoot) {
                $candidate = Join-Path $drive.RootDirectory.FullName $folderName
                if ((Test-PswPathExists $candidate) -and $seen.Add($candidate)) { $found.Add($candidate) }
            }
        }
    } catch { }

    return $found.ToArray()
}

function Get-PswTruncatedText {
    <#
        .SYNOPSIS
        Cắt chuỗi dài thành '...abc' cho gọn output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
        [int]$MaxLength = 60
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($MaxLength -le 3 -or $Text.Length -le $MaxLength) { return $Text }
    return '...' + $Text.Substring($Text.Length - ($MaxLength - 3))
}
