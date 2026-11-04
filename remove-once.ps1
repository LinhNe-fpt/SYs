#Requires -Version 5.1
<#
.SYNOPSIS
    Xoá file/thư mục theo danh sách của scan-once.ps1. Mặc định chỉ mô phỏng.

.DESCRIPTION
    Đọc kết quả scan (ưu tiên CSV + danh-sach-thu-muc-*.txt), kiểm tra lại từng
    đường dẫn bằng bộ guard, rồi:

      - Không có -Execute : chỉ in ra "sẽ xoá gì". Không đụng vào file nào.
      - Có -Execute       : xoá file, sau đó xoá các thư mục đã rỗng (con trước
                            cha). Cần -ConfirmToken XOA.

    Xoá là vĩnh viễn, không hoàn tác được.

.PARAMETER Plan
    Thư mục kết quả scan, hoặc file CSV/JSON. Bỏ trống: dùng presale-scan-*
    mới nhất trong %USERPROFILE%.

.PARAMETER FromScan
    Được scan-once.ps1 gọi nội bộ; không dùng trực tiếp.

.PARAMETER Execute
    Xoá thật.

.PARAMETER Yes
    Đã xác nhận ở bước trước (scan-once.ps1 hỏi Enter): không hỏi lại.
    Chỉ dùng cùng -Execute.

.PARAMETER ConfirmToken
    Phải bằng 'XOA' khi dùng -Execute.

.PARAMETER Keep
    Mẫu wildcard: file/thư mục khớp sẽ KHÔNG bị xoá.

.PARAMETER MaxFiles
    Trần số file mỗi lần. 0 = không giới hạn (mặc định).

.PARAMETER MaxBytes
    Trần tổng dung lượng mỗi lần. 0 = không giới hạn (mặc định).

.EXAMPLE
    .\remove-once.ps1
    .\remove-once.ps1 -Execute -ConfirmToken XOA
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Plan,

    [switch]$FromScan,

    [switch]$Execute,

    [switch]$Yes,

    [string]$ConfirmToken,

    [string[]]$Keep = @(),

    [string]$OutDir,

    [int]$MaxFiles = 0,

    [long]$MaxBytes = 0,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:ToolRoot = $PSScriptRoot
$script:Green = [ConsoleColor]::Green
$script:Red = [ConsoleColor]::Red

function Write-Line {
    param([string]$Text, [ConsoleColor]$Color = $script:Green)
    try {
        [Console]::ForegroundColor = $Color
    } catch { }
    [Console]::Out.WriteLine($Text)
}

function Write-Error-Line {
    param([string]$Text)
    Write-Line $Text $script:Red
}

# Dừng có báo lỗi. Khi được scan-once.ps1 gọi (FromScan), phải THROW chứ không
# exit, nếu không sẽ giết luôn tiến trình cha.
function Stop-WithError {
    param([string]$Text)
    Write-Error-Line $Text
    if ($FromScan) { throw [System.OperationCanceledException]::new($Text) }
    exit 2
}

function Format-Bytes {
    param([long]$Bytes)

    if ($Bytes -lt 1024) { return "$Bytes B" }
    $value = [double]$Bytes
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    while ($value -ge 1024 -and $index -lt 4) { $value = $value / 1024; $index++ }
    return $value.ToString('F1', [System.Globalization.CultureInfo]::InvariantCulture) + ' ' + $units[$index]
}

function To-Long {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Value.StartsWith('\\?\')) { return $Value }
    if ($Value.StartsWith('\\')) { return '\\?\UNC\' + $Value.Substring(2).TrimStart('\') }
    $full = $Value
    if (-not [System.IO.Path]::IsPathRooted($full)) {
        try { $full = [System.IO.Path]::GetFullPath($full) } catch { }
    }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return '\\?\' + $full
}

function Get-FullPathSafe {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $candidate = $Value
    if ($candidate.StartsWith('\\?\UNC\')) { $candidate = '\\' + $candidate.Substring(8) }
    elseif ($candidate.StartsWith('\\?\')) { $candidate = $candidate.Substring(4) }
    $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
    try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { return $null }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

# -----------------------------------------------------------------------------
# Guard
# -----------------------------------------------------------------------------
$script:ForbiddenExact = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('SystemRoot', 'windir', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
        'ProgramData', 'ALLUSERSPROFILE', 'USERPROFILE', 'PUBLIC')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $full = Get-FullPathSafe $value
        if ($null -ne $full) { [void]$script:ForbiddenExact.Add($full) }
    }
}
foreach ($name in @('Desktop', 'MyDocuments', 'MyPictures', 'MyMusic', 'MyVideos',
        'ApplicationData', 'LocalApplicationData', 'UserProfile', 'CommonDocuments')) {
    try {
        $value = [Environment]::GetFolderPath($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $full = Get-FullPathSafe $value
            if ($null -ne $full) { [void]$script:ForbiddenExact.Add($full) }
        }
    } catch { }
}
$scriptsRoot = Get-FullPathSafe $script:ToolRoot
if ($null -ne $scriptsRoot) { [void]$script:ForbiddenExact.Add($scriptsRoot) }

$script:NeverTouch = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('AppData', 'Application Data', 'Local Settings')) {
    [void]$script:NeverTouch.Add($name)
}

# Thư mục hệ thống chỉ cấm ở CẤP GỐC Ổ. Nếu so ở mọi cấp thì đường dẫn Maven
# như '...\.m2\repository\org\springframework\boot\...' cũng bị chặn vì có
# đoạn tên 'boot', khiến không file nào trong .m2 được xoá.
$script:NeverTouchTopLevel = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('Windows', 'Windows.old', 'Program Files', 'Program Files (x86)', 'ProgramData',
        'Recovery', 'PerfLogs', 'Boot', 'System Volume Information', 'Config.Msi', '$Recycle.Bin')) {
    [void]$script:NeverTouchTopLevel.Add($name)
}

$script:CriticalFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'bootmgr', 'BOOTNXT', 'ntldr',
        'ntdetect.com', 'desktop.ini', 'thumbs.db', 'boot.ini', 'io.sys', 'msdos.sys',
        'autoexec.bat', 'config.sys')) {
    [void]$script:CriticalFiles.Add($name)
}

function Get-BlockReason {
    param([string]$FullPath, [switch]$AllowAppData)

    if ([string]::IsNullOrWhiteSpace($FullPath)) { return 'Đường dẫn rỗng.' }
    if ($FullPath -match '^[A-Za-z]:\\?$') { return 'Là gốc ổ đĩa.' }
    if ($FullPath -match '^\\\\') { return 'Đường dẫn mạng.' }

    $segments = @($FullPath.Split('\') | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) { return 'Đường dẫn rỗng.' }
    $leaf = $segments[$segments.Count - 1]

    if ($script:CriticalFiles.Contains($leaf)) { return "File hệ thống: $leaf" }

    # AppData: cấm ở MỌI cấp (trừ lịch sử IDE được cho phép tường minh).
    $scanSegments = if ($FullPath -match '^\\\\\?\\(.+)$') { $matches[1].Split('\') } else { $FullPath.Split('\') }
    foreach ($segment in $scanSegments) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        if ($AllowAppData -and $segment -eq 'AppData') { continue }
        if ($script:NeverTouch.Contains($segment)) { return "Nằm trong thư mục cấm '$segment'." }
    }

    # Thư mục hệ thống: chỉ cấm ở cấp gốc ổ (C:\Windows, C:\Boot, ...).
    if ($scanSegments.Count -gt 1 -and $script:NeverTouchTopLevel.Contains($scanSegments[1])) {
        return "Chứa thư mục cấm '$($scanSegments[1])'."
    }
    foreach ($forbidden in $script:ForbiddenExact) {
        if ([string]::Equals($FullPath, $forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            return "Là thư mục hệ thống/người dùng ($forbidden)."
        }
    }

    foreach ($pattern in $Keep) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($FullPath -like $pattern) { return "Khớp mẫu -Keep '$pattern'." }
    }

    return $null
}

# -----------------------------------------------------------------------------
# 1. Tìm kết quả scan
# -----------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Plan)) {
    $home_ = [Environment]::GetFolderPath('UserProfile')
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($home_)) {
        $candidates = @([System.IO.Directory]::GetDirectories((To-Long $home_), 'presale-scan-*') |
                Sort-Object -Descending)
    }
    if ($candidates.Count -eq 0) {
        Stop-WithError ('LỖI: chưa có kết quả scan trong thư mục người dùng.' + "`r`n" +
            'Chạy presale-scan.cmd trước, hoặc chỉ định -Plan <đường dẫn>.')
    }
    $Plan = $candidates[0]
}

$planDir = $null
$filesSource = $null
$dirsSource = $null

if ([System.IO.Directory]::Exists((To-Long $Plan))) {
    $planDir = Get-FullPathSafe $Plan
    $csv = @([System.IO.Directory]::GetFiles((To-Long $planDir), 'danh-sach-file-*.csv') | Sort-Object -Descending)
    $json = @([System.IO.Directory]::GetFiles((To-Long $planDir), 'danh-sach-file-*.json') | Sort-Object -Descending)
    $dirs = @([System.IO.Directory]::GetFiles((To-Long $planDir), 'danh-sach-thu-muc-*.txt') | Sort-Object -Descending)
    if ($csv.Count -gt 0) { $filesSource = $csv[0] }
    elseif ($json.Count -gt 0) { $filesSource = $json[0] }
    if ($dirs.Count -gt 0) { $dirsSource = $dirs[0] }
} else {
    $full = Get-FullPathSafe $Plan
    if ($null -eq $full -or -not [System.IO.File]::Exists((To-Long $full))) {
        Stop-WithError "LỖI: không tìm thấy kết quả scan: $Plan"
    }
    $filesSource = $full
    $planDir = [System.IO.Path]::GetDirectoryName($full)
    $dirs = @([System.IO.Directory]::GetFiles((To-Long $planDir), 'danh-sach-thu-muc-*.txt') | Sort-Object -Descending)
    if ($dirs.Count -gt 0) { $dirsSource = $dirs[0] }
}

if ([string]::IsNullOrWhiteSpace($filesSource)) {
    Stop-WithError "LỖI: không thấy danh-sach-file-*.csv/.json trong $planDir"
}

# -----------------------------------------------------------------------------
# 2. Đọc danh sách file
# -----------------------------------------------------------------------------
$fileList = New-Object 'System.Collections.Generic.List[string]'
if ($filesSource.EndsWith('.csv', [StringComparison]::OrdinalIgnoreCase)) {
    $reader = New-Object System.IO.StreamReader ((To-Long $filesSource), [System.Text.Encoding]::UTF8)
    try {
        $null = $reader.ReadLine()
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            # Cột đầu là path trong ngoặc kép (có thể chứa dấu phẩy).
            if ($line[0] -ne '"') { continue }
            $close = $line.IndexOf('","')
            if ($close -lt 0) { continue }
            $fileList.Add($line.Substring(1, $close - 1).Replace('""', '"'))
        }
    } finally { $reader.Dispose() }
} else {
    $jsonObj = [System.IO.File]::ReadAllText((To-Long $filesSource), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -ne $jsonObj.PSObject.Properties['files']) {
        foreach ($entry in @($jsonObj.files)) { $fileList.Add([string]$entry.path) }
    }
}

if ($fileList.Count -eq 0) {
    Write-Line 'Danh sách rỗng - không có gì để dọn.'
    if ($FromScan) { return } else { exit 0 }
}

# -----------------------------------------------------------------------------
# 3. Đọc danh sách thư mục (con trước cha, đã sắp trong file)
# -----------------------------------------------------------------------------
$dirList = New-Object 'System.Collections.Generic.List[string]'
if (-not [string]::IsNullOrWhiteSpace($dirsSource)) {
    $reader = New-Object System.IO.StreamReader ((To-Long $dirsSource), [System.Text.Encoding]::UTF8)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            $dirList.Add($line)
        }
    } finally { $reader.Dispose() }
}

# Lịch sử IDE: danh sách đường dẫn được phép xoá dù nằm trong AppData.
$ideAllowed = New-Object 'System.Collections.Generic.List[string]'
if (-not [string]::IsNullOrWhiteSpace($planDir)) {
    $ideFiles = @([System.IO.Directory]::GetFiles((To-Long $planDir), 'danh-sach-ide-*.txt') | Sort-Object -Descending)
    if ($ideFiles.Count -gt 0) {
        $reader = New-Object System.IO.StreamReader ((To-Long $ideFiles[0]), [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
                $pipe = $line.LastIndexOf('|')
                $path = if ($pipe -gt 0) { $line.Substring(0, $pipe) } else { $line }
                $full = Get-FullPathSafe $path.Trim()
                if ($null -ne $full) { $ideAllowed.Add($full) }
            }
        } finally { $reader.Dispose() }
    }
}

function Test-IdeAllowed {
    param([string]$FullPath)

    foreach ($allowed in $ideAllowed) {
        if ([string]::Equals($FullPath, $allowed, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        $prefix = if ($allowed.EndsWith('\')) { $allowed } else { $allowed + '\' }
        if ($FullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# -----------------------------------------------------------------------------
# 4. Lọc lại từng file
# -----------------------------------------------------------------------------
$willDelete = New-Object 'System.Collections.Generic.List[string]'
$skipped = New-Object 'System.Collections.Generic.List[object]'
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$totalBytes = 0L

foreach ($raw in $fileList) {
    $full = Get-FullPathSafe $raw
    if ($null -eq $full) {
        [void]$skipped.Add([PSCustomObject]@{ Path = $raw; Reason = 'Đường dẫn không hợp lệ.' })
        continue
    }
    if (-not $seen.Add($full)) { continue }

    # Lịch sử IDE được phép nằm trong AppData; mọi kiểm tra khác vẫn áp dụng.
    $reason = if (Test-IdeAllowed $full) { Get-BlockReason $full -AllowAppData } else { Get-BlockReason $full }
    if ($null -ne $reason) {
        [void]$skipped.Add([PSCustomObject]@{ Path = $full; Reason = $reason })
        continue
    }
    if (-not [System.IO.File]::Exists((To-Long $full))) {
        [void]$skipped.Add([PSCustomObject]@{ Path = $full; Reason = 'File không còn tồn tại.' })
        continue
    }

    try { $totalBytes += (New-Object System.IO.FileInfo (To-Long $full)).Length } catch { }
    $willDelete.Add($full)
}

$dirsToRemove = New-Object 'System.Collections.Generic.List[string]'
foreach ($raw in $dirList) {
    $full = Get-FullPathSafe $raw
    if ($null -eq $full) { continue }
    $blocked = if (Test-IdeAllowed $full) { Get-BlockReason $full -AllowAppData } else { Get-BlockReason $full }
    if ($null -ne $blocked) { continue }
    if ([System.IO.Directory]::Exists((To-Long $full))) { $dirsToRemove.Add($full) }
}

# -----------------------------------------------------------------------------
# 5. Kiểm tra hạn mức
# -----------------------------------------------------------------------------
$destination = if ([string]::IsNullOrWhiteSpace($OutDir)) { $planDir } else { $OutDir }
if (-not [System.IO.Directory]::Exists((To-Long $destination))) {
    [void][System.IO.Directory]::CreateDirectory((To-Long $destination))
}

if ($Execute) {
    if ($ConfirmToken -ne 'XOA') {
        Stop-WithError "LỖI: -Execute cần -ConfirmToken XOA (xoá vĩnh viễn, không hoàn tác)."
    }
    if ($MaxFiles -gt 0 -and $willDelete.Count -gt $MaxFiles) {
        Stop-WithError ("LỖI: {0} file vượt trần -MaxFiles {1}. Dùng -Keep, hoặc -MaxFiles 0 để bỏ giới hạn." -f $willDelete.Count, $MaxFiles)
    }
    if ($MaxBytes -gt 0 -and $totalBytes -gt $MaxBytes) {
        Stop-WithError ("LỖI: {0:N1} GB vượt trần -MaxBytes {1:N1} GB. Dùng -MaxBytes 0 để bỏ giới hạn." -f ($totalBytes / 1GB), ($MaxBytes / 1GB))
    }
}

# -----------------------------------------------------------------------------
# 6. In kế hoạch (đủ, không cắt)
# -----------------------------------------------------------------------------
Write-Line ''
Write-Line ('=' * 76)
if ($Execute) {
    Write-Line '  presale-wiper - XOÁ VĨNH VIỄN'
} else {
    Write-Line '  presale-wiper - KẾ HOẠCH XOÁ (mô phỏng, CHƯA xoá gì)'
}
Write-Line ('=' * 76)
Write-Line ''
Write-Line ("  Nguồn danh sách : {0}" -f $filesSource)
Write-Line ("  File sẽ xoá     : {0}  ({1})" -f $willDelete.Count, (Format-Bytes $totalBytes))
Write-Line ("  Thư mục sẽ dọn  : {0}" -f $dirsToRemove.Count)
Write-Line ("  Bỏ qua (guard)  : {0}" -f $skipped.Count)
Write-Line ''

if (-not $Quiet) {
    if ($willDelete.Count -gt 0) {
        Write-Line '--- File ---'
        foreach ($item in $willDelete) { Write-Line ("  {0}" -f $item) }
        Write-Line ''
    }
    if ($dirsToRemove.Count -gt 0) {
        Write-Line '--- Thư mục (chỉ xoá nếu rỗng) ---'
        foreach ($item in $dirsToRemove) { Write-Line ("  {0}" -f $item) }
        Write-Line ''
    }
    if ($skipped.Count -gt 0) {
        Write-Line ("--- Bỏ qua ({0}) ---" -f $skipped.Count)
        foreach ($item in $skipped) { Write-Line ("  [{0}] {1}" -f $item.Reason, $item.Path) }
        Write-Line ''
    }
}

# -----------------------------------------------------------------------------
# 7. Xoá
# -----------------------------------------------------------------------------
$deleted = 0
$removedDirs = 0
$failed = New-Object 'System.Collections.Generic.List[object]'

if ($Execute) {
    $progress = $null
    try {
        $progress = New-Object System.Windows.Forms.Form
        $progress.Text = 'presale-wiper - đang xoá'
        $progress.Width = 520
        $progress.Height = 130
        $progress.StartPosition = 'CenterScreen'
        $progress.FormBorderStyle = 'FixedDialog'
        $progress.MaximizeBox = $false
        $progress.MinimizeBox = $false
        $label = New-Object System.Windows.Forms.Label
        $label.Left = 16; $label.Top = 14; $label.Width = 480; $label.Text = 'Đang chuẩn bị...'
        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Left = 16; $bar.Top = 44; $bar.Width = 480; $bar.Height = 22
        $bar.Minimum = 0; $bar.Maximum = [Math]::Max(1, $willDelete.Count)
        [void]$progress.Controls.Add($label)
        [void]$progress.Controls.Add($bar)
        $progress.Show()
        $progress.Refresh()
    } catch { $progress = $null }

    for ($i = 0; $i -lt $willDelete.Count; $i++) {
        $path = $willDelete[$i]
        try {
            [System.IO.File]::Delete((To-Long $path))
            $deleted++
        } catch {
            [void]$failed.Add([PSCustomObject]@{ Path = $path; Reason = $_.Exception.Message })
        }

        if ($null -ne $progress -and ($i % 25 -eq 0 -or $i -eq $willDelete.Count - 1)) {
            try {
                $bar.Value = [Math]::Min($bar.Maximum, $i + 1)
                $label.Text = ('Đã xoá {0}/{1} file' -f ($i + 1), $willDelete.Count)
                $progress.Refresh()
            } catch { }
        }
    }

    # Dọn thư mục: file đã sắp theo độ sâu nên xoá xong file thì thư mục rỗng dần.
    for ($i = 0; $i -lt $dirsToRemove.Count; $i++) {
        try {
            [System.IO.Directory]::Delete((To-Long $dirsToRemove[$i]), $false)
            $removedDirs++
        } catch {
            # Còn file lạ hoặc bị khoá: để lại, không phải lỗi nghiêm trọng.
        }
        if ($null -ne $progress -and ($i % 25 -eq 0 -or $i -eq $dirsToRemove.Count - 1)) {
            try {
                $label.Text = ('Đã xoá {0} file, dọn {1}/{2} thư mục' -f $deleted, ($i + 1), $dirsToRemove.Count)
                $progress.Refresh()
            } catch { }
        }
    }

    if ($null -ne $progress) {
        try { $progress.Close(); $progress.Dispose() } catch { }
    }
}

# -----------------------------------------------------------------------------
# 8. Báo cáo
# -----------------------------------------------------------------------------
$mode = if ($Execute) { 'delete' } else { 'dry-run' }
$baseName = if ($Execute) { 'da-xoa' } else { 'ke-hoach-xoa' }
$stamp = '{0}-{1}' -f $baseName, $script:RunId
# Chỉ ghi MỘT file tóm tắt. Danh sách đường dẫn đã có trong CSV của bước quét
# rồi; trước đây bước xoá ghi thêm TXT + JSON chứa lại toàn bộ đường dẫn, làm
# mỗi lần chạy tốn thêm hàng trăm MB.
$summaryPath = Join-Path $destination "$stamp.json"
$noBom = New-Object System.Text.UTF8Encoding($false)

$summary = [ordered]@{
    tool        = 'presale-wiper remove-once'
    mode        = $mode
    source      = $filesSource
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    files       = $willDelete.Count
    directories = $dirsToRemove.Count
    skipped     = $skipped.Count
    sizeBytes   = $totalBytes
    sizeText    = Format-Bytes $totalBytes
    deleted     = $deleted
    removedDirs = $removedDirs
    failed      = $failed.Count
    failedList  = @($failed | ForEach-Object { [ordered]@{ path = $_.Path; reason = $_.Reason } })
    skippedList = @($skipped | ForEach-Object { [ordered]@{ path = $_.Path; reason = $_.Reason } })
}
[System.IO.File]::WriteAllText((To-Long $summaryPath), (ConvertTo-Json -InputObject $summary -Depth 6), $noBom)

Write-Line ''
Write-Line ('=' * 76)
if ($Execute) {
    Write-Line '  ĐÃ XOÁ XONG'
} else {
    Write-Line '  CHƯA XOÁ GÌ (chế độ mô phỏng)'
}
Write-Line ('=' * 76)
if ($Execute) {
    Write-Line ("  File đã xoá     : {0}  ({1})" -f $deleted, (Format-Bytes $totalBytes))
    Write-Line ("  Thư mục đã dọn  : {0}" -f $removedDirs)
    Write-Line ("  Lỗi             : {0}" -f $failed.Count)
    foreach ($item in @($failed | Select-Object -First 20)) {
        Write-Error-Line ("    [{0}] {1}" -f $item.Reason, $item.Path)
    }
} else {
    Write-Line ("  Sẽ xoá          : {0} file  ({1})" -f $willDelete.Count, (Format-Bytes $totalBytes))
    Write-Line ("  Sẽ dọn          : {0} thư mục" -f $dirsToRemove.Count)
    Write-Line ''
    Write-Line '  Muốn xoá thật, chạy lại với: -Execute -ConfirmToken XOA'
}
Write-Line ''
Write-Line ("  Báo cáo: {0}" -f $summaryPath)
Write-Line ''

if (-not $Execute -and -not $Quiet -and -not $Yes) {
    # Hỏi xác nhận khi chạy tương tác. Điều kiện dựa trên console thật, KHÔNG
    # dựa vào biến môi trường: trước đây chỉ cần thiếu biến đó là bước xoá
    # lặng lẽ dừng ở bản kế hoạch, khiến người dùng tưởng đã xoá.
    $interactive = (-not [Console]::IsInputRedirected) -or $FromScan
    if ($interactive) {
        Write-Line 'Ấn Enter để xoá thật, đóng cửa sổ để huỷ.'
        $null = [Console]::ReadLine()
        $recurse = @{ Plan = $planDir; Execute = $true; ConfirmToken = 'XOA'; Yes = $true }
        if ($Keep.Count -gt 0) { $recurse['Keep'] = $Keep }
        & $PSCommandPath @recurse
    }
}

if ($FromScan) { return }
[Environment]::ExitCode = 0
