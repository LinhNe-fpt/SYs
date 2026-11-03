#Requires -Version 5.1
<#
    classify.ps1 - Phân loại file/folder.

    Đây là "bộ não" quyết định cái gì là project code, cái gì là rác dev,
    cái gì là secret, cái gì phải bỏ qua.

    Mọi hàm ở đây là PURE: nhận metadata (tên, extension, danh sách con)
    và trả về kết luận, KHÔNG tự đọc đĩa. Nhờ vậy test được bằng
    table-driven test mà không cần fixtures thật.
#>

Set-StrictMode -Version Latest

# Các giá trị hợp lệ của Kind (dùng cho test hợp đồng + report)
$script:PswEntryKinds = @(
    'Project'     # folder là gốc một project code
    'DevDir'      # folder rác của dev: node_modules, target, .venv...
    'Secret'      # .ssh, .env, .gitconfig...
    'CodeFile'    # file code lẻ (không nằm trong project nào)
    'MediaHeavy'  # folder bị media chi phối -> không tính là project
    'Skip'        # không quan tâm
)

function Get-PswEntryKinds {
    <#
        .SYNOPSIS
        Danh sách Kind hợp lệ.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:PswEntryKinds
}

function Get-PswExtension {
    <#
        .SYNOPSIS
        Extension lowercase ('' nếu không có), bao gồm cả trường hợp
        tên file chỉ có dấu chấm ở đầu ('.env' -> '').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrEmpty($Name)) { return '' }
    $dot = $Name.LastIndexOf('.')
    if ($dot -lt 0) { return '' }
    # '.env' coi là file không extension (nó được nhận diện qua tên)
    if ($dot -eq 0) { return '' }
    return $Name.Substring($dot).ToLowerInvariant()
}

function Get-PswFileKind {
    <#
        .SYNOPSIS
        Phân loại 1 file theo tên.

        .OUTPUTS
        Một trong: 'Secret', 'Code', 'Media', 'Binary', 'Config', 'Other'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ($null -eq $script:PswLookup) { Initialize-PswConfig | Out-Null }

    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Other' }

    # Secret: khớp tên chính xác hoặc wildcard
    if ($script:PswLookup.SecretFileNames.Contains($Name)) { return 'Secret' }
    foreach ($pattern in $script:PswConfig.SecretFilePatterns) {
        if ($Name -like $pattern) { return 'Secret' }
    }

    $ext = Get-PswExtension $Name

    if ($null -ne $ext -and $ext -ne '') {
        if ($script:PswLookup.CodeExtensions.Contains($ext)) { return 'Code' }
        if ($script:PswLookup.MediaExtensions.Contains($ext)) { return 'Media' }
        if ($script:PswLookup.BinaryExtensions.Contains($ext)) { return 'Binary' }
        if ($script:PswLookup.WeakConfigExtensions.Contains($ext)) { return 'Config' }
    }

    return 'Other'
}

function Test-PswIsProjectMarker {
    <#
        .SYNOPSIS
        Tên này có phải marker của project không?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($null -eq $script:PswLookup) { Initialize-PswConfig | Out-Null }

    if ($script:PswLookup.ProjectMarkers.Contains($Name)) { return $true }

    foreach ($pattern in $script:PswConfig.ProjectMarkerPatterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Test-PswIsDevDirName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($null -eq $script:PswLookup) { Initialize-PswConfig | Out-Null }
    return $script:PswLookup.DevDirNames.Contains($Name)
}

function Test-PswIsSkipDirName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($null -eq $script:PswLookup) { Initialize-PswConfig | Out-Null }
    return $script:PswLookup.SkipDirNames.Contains($Name)
}

function Test-PswIsSecretDirName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($null -eq $script:PswLookup) { Initialize-PswConfig | Out-Null }
    return $script:PswLookup.SecretDirNames.Contains($Name)
}

function New-PswFolderProfile {
    <#
        .SYNOPSIS
        Hồ sơ rỗng của 1 folder (được điền dần khi duyệt con).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path
    )

    return [PSCustomObject]@{
        Path       = $Path
        Markers    = New-Object 'System.Collections.Generic.List[string]'
        CodeFiles  = 0
        MediaFiles = 0
        ConfigFiles = 0
        BinaryFiles = 0
        OtherFiles = 0
        SubDirs    = 0
        TotalFiles = 0
    }
}

function Get-PswFolderKind {
    <#
        .SYNOPSIS
        Từ hồ sơ folder -> quyết định Kind.

        .DESCRIPTION
        Luật, theo thứ tự ưu tiên:

          L1  Có marker project (.git, package.json, Cargo.toml...)  -> Project
              (marker thắng mọi thứ khác: một repo ảnh vẫn là repo)
          L2  Có >= 2 file code và tỉ lệ code >= 30%                 -> Project
          L3  Bị media chi phối (>= MediaVoteMinFiles file media và
              tỉ lệ >= 80%) mà có <= 1 file code                    -> MediaHeavy
          L4  Có >= 1 file code                                     -> Project (yếu)
          L5  Còn lại                                               -> Skip

        .PARAMETER Profile
        Object từ New-PswFolderProfile.

        .OUTPUTS
        Hashtable: Kind, Reasons (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Profile
    )

    if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }
    $defaults = $script:PswConfig.Defaults

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $total = [int]$Profile.TotalFiles
    $code = [int]$Profile.CodeFiles
    $media = [int]$Profile.MediaFiles

    $codeRatio = 0.0
    $mediaRatio = 0.0
    if ($total -gt 0) {
        $codeRatio = [double]$code / [double]$total
        $mediaRatio = [double]$media / [double]$total
    }

    # L1 - marker
    if ($Profile.Markers.Count -gt 0) {
        $sample = @($Profile.Markers | Select-Object -First 3) -join ', '
        $reasons.Add("Có marker project ($sample)")
        return @{ Kind = 'Project'; Reasons = $reasons.ToArray() }
    }

    # L2 - code chiếm ưu thế
    if ($code -ge 2 -and $codeRatio -ge 0.30) {
        $reasons.Add(('{0} file code / {1} file ({2:P0})' -f $code, $total, $codeRatio))
        return @{ Kind = 'Project'; Reasons = $reasons.ToArray() }
    }

    # L3 - media chi phối
    if ($media -ge [int]$defaults.MediaVoteMinFiles -and
        $mediaRatio -ge [double]$defaults.MediaDominanceRatio -and
        $code -le 1) {
        $reasons.Add(('Bị media chi phối: {0} file media / {1} file ({2:P0}), chỉ {3} file code' -f
                $media, $total, $mediaRatio, $code))
        return @{ Kind = 'MediaHeavy'; Reasons = $reasons.ToArray() }
    }

    # L4 - có code lẻ
    if ($code -ge 1) {
        $reasons.Add(('Có {0} file code / {1} file ({2:P0})' -f $code, $total, $codeRatio))
        return @{ Kind = 'Project'; Reasons = $reasons.ToArray() }
    }

    # L5
    $reasons.Add('Không có dấu hiệu project code.')
    return @{ Kind = 'Skip'; Reasons = $reasons.ToArray() }
}

function Add-PswChildToProfile {
    <#
        .SYNOPSIS
        Cập nhật hồ sơ folder bằng 1 entry con (file hoặc folder).

        .PARAMETER Info
        Object có Name + Attributes (FileSystemInfo hoặc object giả lập
        với 2 property đó) - cho phép test không cần đĩa thật.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Profile,
        [Parameter(Mandatory, Position = 1)]$Info
    )

    $name = [string]$Info.Name
    $attributes = [int]$Info.Attributes
    $isDir = ($attributes -band [int][System.IO.FileAttributes]::Directory) -ne 0

    if ($isDir) {
        $Profile.SubDirs = [int]$Profile.SubDirs + 1
        if (Test-PswIsProjectMarker $name) {
            if (-not $Profile.Markers.Contains($name)) { $Profile.Markers.Add($name) }
        }
        return
    }

    $Profile.TotalFiles = [int]$Profile.TotalFiles + 1
    if (Test-PswIsProjectMarker $name) {
        if (-not $Profile.Markers.Contains($name)) { $Profile.Markers.Add($name) }
    }

    switch (Get-PswFileKind $name) {
        'Code' { $Profile.CodeFiles = [int]$Profile.CodeFiles + 1 }
        'Media' { $Profile.MediaFiles = [int]$Profile.MediaFiles + 1 }
        'Config' { $Profile.ConfigFiles = [int]$Profile.ConfigFiles + 1 }
        'Binary' { $Profile.BinaryFiles = [int]$Profile.BinaryFiles + 1 }
        default { $Profile.OtherFiles = [int]$Profile.OtherFiles + 1 }
    }
}

function Get-PswEntryKindFromName {
    <#
        .SYNOPSIS
        Phân loại nhanh 1 entry chỉ dựa vào tên + thuộc tính
        (dùng khi KHÔNG cần duyệt con: folder dev, secret, skip).

        .OUTPUTS
        Kind hoặc $null nếu cần profile chi tiết hơn.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$IsDirectory
    )

    if ($IsDirectory) {
        if (Test-PswIsSkipDirName $Name) { return 'Skip' }
        if (Test-PswIsDevDirName $Name) { return 'DevDir' }
        if (Test-PswIsSecretDirName $Name) { return 'Secret' }
        if (Test-PswIsProjectMarker $Name) { return 'Skip' }  # '.git' bên trong project
        return $null
    }

    switch (Get-PswFileKind $Name) {
        'Secret' { return 'Secret' }
        'Code' { return 'CodeFile' }
        default { return 'Skip' }
    }
}
