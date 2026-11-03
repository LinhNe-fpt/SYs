#Requires -Version 5.1
<#
    guard.ps1 - Lớp an toàn.

    Nguyên tắc: deny by default. Một path chỉ được coi là xoá được khi nó
    KHÔNG khớp bất kỳ luật cấm nào dưới đây.

    Có HAI loại vùng cấm, phân biệt rất quan trọng:

      * SystemSubtree  - cấm cả cây (C:\Windows, C:\Program Files,
                         C:\ProgramData, $Recycle.Bin...). Không có ngoại lệ.
      * ExactOnly      - chỉ cấm chính path đó, KHÔNG cấm con của nó:
                         Desktop, Documents, Downloads, %USERPROFILE%,
                         C:\Users, gốc ổ đĩa. Dọn bên trong vẫn được.

    Nếu gộp hai loại này làm một thì hoặc là quá nguy hiểm (cho xoá
    C:\Windows\System32 khi user gõ nhầm), hoặc là vô dụng (project nằm
    trong Documents\Projects sẽ không bao giờ xoá được).

    Guard được dùng ở 2 thời điểm:
      1. Lúc scan  -> entry bị cấm có Protected = $true, không vào danh sách xoá.
      2. Lúc clean -> kiểm tra lại ngay trước khi gọi remove (phòng thủ 2 lớp).
#>

Set-StrictMode -Version Latest

$script:PswSystemSubtrees = $null
$script:PswExactForbidden = $null

function Get-PswSystemSubtrees {
    <#
        .SYNOPSIS
        Các thư mục mà TOÀN BỘ cây con bên trong đều bị cấm xoá.

        .OUTPUTS
        [string[]] path tuyệt đối.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$Force)

    if (-not $Force -and $null -ne $script:PswSystemSubtrees) { return $script:PswSystemSubtrees }

    $candidates = New-Object 'System.Collections.Generic.List[string]'

    foreach ($name in @('SystemRoot', 'windir', 'ProgramFiles', 'ProgramFiles(x86)',
            'ProgramW6432', 'ProgramData', 'CommonProgramFiles', 'CommonProgramFiles(x86)',
            'ALLUSERSPROFILE')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $candidates.Add($value) }
    }

    $systemDrive = [Environment]::GetEnvironmentVariable('SystemDrive')
    if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = 'C:' }
    foreach ($name in @('Windows', 'Windows.old', 'Program Files', 'Program Files (x86)',
            'ProgramData', 'PerfLogs', 'Recovery', 'Boot', '$Recycle.Bin',
            'System Volume Information', 'Config.Msi', 'Documents and Settings')) {
        $candidates.Add("$systemDrive\$name")
    }

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        $full = Get-PswFullPath $candidate
        if ($null -ne $full -and $full -match '^[A-Za-z]:\\') { [void]$set.Add($full.TrimEnd('\')) }
    }

    $script:PswSystemSubtrees = @($set)
    return $script:PswSystemSubtrees
}

function Get-PswExactForbidden {
    <#
        .SYNOPSIS
        Các path mà chỉ CHÍNH NÓ bị cấm xoá (con bên trong vẫn được dọn).

        .DESCRIPTION
        Gồm folder shell của user, %USERPROFILE%, C:\Users, Public, các
        folder AppData, và mọi tổ tiên của những path trên.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$Force)

    if (-not $Force -and $null -ne $script:PswExactForbidden) { return $script:PswExactForbidden }

    $candidates = New-Object 'System.Collections.Generic.List[string]'

    foreach ($name in @('USERPROFILE', 'PUBLIC', 'LOCALAPPDATA', 'APPDATA', 'HOMEDRIVE', 'HOMEPATH')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $candidates.Add($value) }
    }

    foreach ($name in @('Desktop', 'DesktopDirectory', 'MyDocuments', 'MyPictures', 'MyMusic',
            'MyVideos', 'Favorites', 'UserProfile', 'CommonDocuments',
            'CommonDesktopDirectory', 'ApplicationData', 'LocalApplicationData',
            'CommonApplicationData')) {
        try {
            $value = [Environment]::GetFolderPath($name)
            if (-not [string]::IsNullOrWhiteSpace($value)) { $candidates.Add($value) }
        } catch { }
    }

    # Downloads không có entry trong SpecialFolder, phải ghép tay từ registry.
    $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $candidates.Add($userProfile)
        $candidates.Add((Join-Path $userProfile 'Downloads'))
        $candidates.Add((Join-Path $userProfile 'OneDrive'))
        $parent = Get-PswParentPath $userProfile
        if ($null -ne $parent) { $candidates.Add($parent) }  # C:\Users
    }

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        $full = Get-PswFullPath $candidate
        if ($null -eq $full -or [string]::IsNullOrWhiteSpace($full)) { continue }
        [void]$set.Add($full)

        # Mọi tổ tiên cũng cấm (nhưng dừng ở gốc ổ đĩa, xử lý riêng bên dưới)
        $parent = Get-PswParentPath $full
        while ($null -ne $parent) {
            [void]$set.Add($parent)
            if ($parent -match '^[A-Za-z]:$') { break }
            $parent = Get-PswParentPath $parent
        }
    }

    $script:PswExactForbidden = @($set)
    return $script:PswExactForbidden
}

function Clear-PswGuardCache {
    <#
        .SYNOPSIS
        Xoá cache guard (dùng trong test sau khi đổi biến môi trường).
    #>
    [CmdletBinding()]
    param()

    $script:PswSystemSubtrees = $null
    $script:PswExactForbidden = $null
}

function Get-PswProtectionReason {
    <#
        .SYNOPSIS
        Trả về lý do path KHÔNG được xoá, hoặc $null nếu xoá được.

        .DESCRIPTION
        Thứ tự kiểm tra (fail sớm, fail rõ):

          R1. Rỗng / không hợp lệ.
          R2. Gốc ổ đĩa (C:\) hoặc gốc share mạng (\\server\share).
          R3. Nằm trong (hoặc bằng) một SystemSubtree.
          R4. Bằng một ExactlyForbidden path (Desktop, Downloads, C:\Users...).
          R5. Chứa component tên cấm ở bất kỳ độ sâu ($Recycle.Bin, Windows...).
          R6. Nằm trong AppData (presale-wiper không dọn AppData).
          R7. Quá nông so với gốc ổ (C:\something) -> từ chối.
          R8. Không tồn tại.

        .OUTPUTS
        [string] lý do, hoặc $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    # R1
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'Đường dẫn rỗng.' }
    $full = Get-PswFullPath $Path
    if ($null -eq $full) { return 'Đường dẫn không hợp lệ.' }

    if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }

    # R2
    if ($full -match '^[A-Za-z]:\\?$') { return "Gốc ổ đĩa ($full) không được phép xoá." }
    if ($full.StartsWith('\\')) {
        $parts = @($full.TrimStart('\').Split('\') | Where-Object { $_ -ne '' })
        if ($parts.Count -le 2) { return "Gốc chia sẻ mạng ($full) không được phép xoá." }
    }

    # R3
    foreach ($root in (Get-PswSystemSubtrees)) {
        if (Test-PswSamePath -Path $full -Other $root) {
            return "Là thư mục hệ thống được bảo vệ: $root"
        }
        if (Test-PswPathIsUnder -Path $full -Parent $root) {
            return "Nằm trong thư mục hệ thống được bảo vệ: $root"
        }
    }

    # R4
    foreach ($exact in (Get-PswExactForbidden)) {
        if (Test-PswSamePath -Path $full -Other $exact) {
            return "Là thư mục người dùng/hệ thống ($exact); chỉ được dọn bên trong, không xoá cả thư mục."
        }
    }

    # R4b - tên folder trùng tên folder shell của user, ở BẤT KỲ vị trí nào.
    # Chỉ cấm xoá CHÍNH folder đó (được dọn bên trong), vì một folder tên
    # "Documents" rất có thể là folder shell đã bị redirect sang ổ khác mà
    # GetFolderPath không phản ánh hết. Đánh đổi: một repo tình cờ đặt tên
    # "Documents"/"Downloads" sẽ không bị xoá cả cụm - chấp nhận được, vì
    # đây là tool xoá không thể hoàn tác.
    $leaf = [System.IO.Path]::GetFileName($full)
    if (-not [string]::IsNullOrEmpty($leaf) -and $script:PswLookup.ShellFolderNames.Contains($leaf)) {
        return "Tên thư mục '$leaf' trùng tên thư mục người dùng; chỉ được dọn bên trong."
    }

    # R5
    $segments = @($full.Split('\') | Where-Object { $_ -ne '' })
    if ($segments.Count -gt 1) {
        for ($i = 1; $i -lt $segments.Count; $i++) {
            if ($script:PswLookup.NeverTouchNames.Contains($segments[$i])) {
                return "Chứa thư mục cấm '$($segments[$i])' trong đường dẫn."
            }
        }
    }

    # R6
    foreach ($appDataName in @('LocalApplicationData', 'ApplicationData')) {
        try {
            $appData = [Environment]::GetFolderPath($appDataName)
            if ([string]::IsNullOrWhiteSpace($appData)) { continue }
            if (Test-PswPathIsUnder -Path $full -Parent $appData) {
                return "Nằm trong AppData ($appData); presale-wiper không dọn AppData."
            }
        } catch { }
    }

    # R7 - AppData đã chặn ở R6; ở đây không chặn theo độ sâu.
    # Lý do: `presale-wiper scan C:\Test` là use case hợp lệ (xem roadmap).
    # Chặn xoá các folder cấp 1 là việc của bước clean (Phase 2), nơi có
    # thêm ngữ cảnh "user có chỉ định đúng path này không".

    # R8
    if (-not (Test-PswPathExists $full)) { return 'Đường dẫn không tồn tại.' }

    return $null
}

function Test-PswShallowPath {
    <#
        .SYNOPSIS
        Path có "quá nông" so với gốc ổ đĩa không (C:\Foo)?

        .DESCRIPTION
        Quét thì được, nhưng XOÁ một folder cấp 1 dễ là gõ nhầm. Hàm này
        không tham gia vào guard xoá chung; Phase 2 (clean) gọi nó khi
        quyết định có cần user xác nhận thêm hay không.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $full = Get-PswFullPath $Path
    if ($null -eq $full) { return $false }
    if ($full.StartsWith('\\')) { return $false }
    if ($full.TrimEnd('\') -match '^[A-Za-z]:$') { return $false }  # gốc ổ: xử lý bởi luật khác
    return ((Get-PswPathDepth $full) -lt 2)
}

function Test-PswProtectedPath {
    <#
        .SYNOPSIS
        Convenience: path có bị cấm xoá không?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    return ($null -ne (Get-PswProtectionReason -Path $Path))
}

function Get-PswScanRootBlockReason {
    <#
        .SYNOPSIS
        Root này có bị từ chối làm ĐIỂM QUÉT không?

        .DESCRIPTION
        Khác với guard xoá: quét C:\Windows không nguy hiểm về mất dữ liệu,
        nhưng chắc chắn là gõ nhầm và sẽ làm tool chạy hàng chục phút.
        Từ chối sớm kèm thông báo rõ ràng thay vì lặng lẽ chạy.

        Bỏ qua kiểm tra này khi user truyền -IncludeHome.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path
    )

    $full = Get-PswFullPath $Path
    if ($null -eq $full) { return 'Đường dẫn không hợp lệ.' }

    # Get-PswFullPath giữ nguyên 'C:\'; sau đây kiểm tra cả 'C:\' và 'C:'
    if ($full -match '^[A-Za-z]:\\?$') {
        return "Từ chối quét gốc ổ đĩa ($full). Hãy chỉ định thư mục cụ thể."
    }

    if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }

    foreach ($root in (Get-PswSystemSubtrees)) {
        if (Test-PswSamePath -Path $full -Other $root) {
            return "Từ chối quét thư mục hệ thống: $root"
        }
        if (Test-PswPathIsUnder -Path $full -Parent $root) {
            return "Từ chối quét bên trong thư mục hệ thống: $root"
        }
    }

    $segments = @($full.Split('\') | Where-Object { $_ -ne '' })
    if ($segments.Count -gt 1) {
        for ($i = 1; $i -lt $segments.Count; $i++) {
            if ($script:PswLookup.NeverTouchNames.Contains($segments[$i])) {
                return "Từ chối quét thư mục hệ thống '$($segments[$i])' trong đường dẫn."
            }
        }
    }

    return $null
}

function Test-PswElevated {
    <#
        .SYNOPSIS
        Process hiện tại có chạy với quyền admin không?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal $identity
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-PswRunningEditorProcesses {
    <#
        .SYNOPSIS
        Các process đang chạy thường giữ file trong project (để cảnh báo).

        .DESCRIPTION
        Chỉ ĐỌC danh sách process; không kill gì cả.
    #>
    [CmdletBinding()]
    param()

    $known = @(
        'Code', 'Code - Insiders', 'devenv', 'idea64', 'idea', 'pycharm64', 'pycharm'
        'webstorm64', 'webstorm', 'rider64', 'rider', 'clion64', 'clion', 'goland64', 'goland'
        'studio64', 'sublime_text', 'notepad++', 'atom', 'fleet', 'cursor', 'zed'
        'node', 'python', 'pythonw', 'dotnet', 'java', 'javaw', 'cargo', 'rustc'
        'docker', 'Docker Desktop', 'com.docker.backend', 'vmmem', 'wslservice'
    )
    $knownSet = New-PswLookupSet $known

    $result = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
            if ($knownSet.Contains($process.ProcessName)) {
                $result.Add([PSCustomObject]@{
                        Name        = $process.ProcessName
                        Id          = $process.Id
                        Description = $process.Description
                    })
            }
        }
    } catch { }

    return $result.ToArray()
}
