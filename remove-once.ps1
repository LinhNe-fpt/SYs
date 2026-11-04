#Requires -Version 5.1
<#
.SYNOPSIS
    Dọn file theo danh sách của scan-once.ps1. MẶC ĐỊNH CHỈ MÔ PHỎNG, không xoá gì.

.DESCRIPTION
    Đọc file JSON do scan-once.ps1 tạo ra (danh-sach-file-*.json), kiểm tra lại
    từng đường dẫn bằng bộ guard giống bên scan, rồi:

      - Không có -Execute  : chỉ liệt kê "sẽ xoá gì" ra file kế hoạch. Không
                             sửa, không xoá, không đổi quyền bất kỳ file nào.
      - Có -Execute        : xoá vĩnh viễn những file đã qua guard, và chỉ những
                             file có trong danh sách JSON (không tự tìm thêm).

    Xoá vĩnh viễn là KHÔNG HOÀN TÁC ĐƯỢC. Vì vậy -Execute yêu cầu thêm
    -ConfirmToken XOA, và từ chối chạy nếu vượt hạn mức an toàn (xem -MaxFiles,
    -MaxBytes). Nên chạy mô phỏng trước, đọc file kế hoạch, rồi mới quyết định.

.PARAMETER Plan
    File JSON của scan, hoặc thư mục chứa nó (lấy file mới nhất). Bỏ trống thì
    dùng thư mục presale-scan-* mới nhất trong %USERPROFILE%.

.PARAMETER Execute
    Xoá thật. Không có tham số này thì chương trình chỉ mô phỏng.

.PARAMETER ConfirmToken
    Phải đúng bằng 'XOA' khi dùng -Execute. Cố ý để không thể xoá do bấm nhầm.

.PARAMETER Keep
    Mẫu wildcard trên đường dẫn: file khớp sẽ KHÔNG bị xoá.
    Ví dụ: -Keep '*\BOT\*','*\VPQL\*'

.PARAMETER OutDir
    Nơi ghi file kế hoạch / log. Mặc định: cạnh file JSON.

.PARAMETER MaxFiles
    Trần số file được xoá trong một lần. Mặc định 20000. Vượt thì từ chối chạy.

.PARAMETER MaxBytes
    Trần tổng dung lượng được xoá trong một lần. Mặc định 20GB.

.EXAMPLE
    .\remove-once.ps1 -Plan "$env:USERPROFILE\presale-scan-20261104-090000"
    # Chỉ mô phỏng, ghi ke-hoach-xoa-*.txt/.csv/.json

.EXAMPLE
    .\remove-once.ps1 -Plan .\presale-scan-... -Execute -ConfirmToken XOA
    # Xoá thật những gì đã duyệt

.NOTES
    Guard: không bao giờ xoá file trong Windows / Program Files / ProgramData /
    AppData, gốc ổ, thùng rác, thư mục đang chứa công cụ này, file hệ thống của
    ổ (pagefile, hiberfil, ...). Số lượng và dung lượng bị giới hạn.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Plan,

    [switch]$Execute,

    [string]$ConfirmToken,

    [string[]]$Keep = @(),

    [string]$OutDir,

    [int]$MaxFiles = 20000,

    [long]$MaxBytes = 20GB,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:ToolRoot = $PSScriptRoot

function Write-Line {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
}

function Write-Fail {
    param([string]$Text)
    Write-Line $Text
    if ($env:PSW_HIDDEN -eq '1') {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($Text, 'presale-wiper remove')
        } catch { }
    }
}

function Stop-WithError {
    param([string]$Text)
    Write-Fail $Text
    # Script độc lập, không bị dot-source: exit ở đây đặt đúng mã thoát của tiến trình.
    exit 2
}

function To-Long {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Value.StartsWith('\\?\') -or $Value.StartsWith('.\')) { return $Value }
    if ($Value.StartsWith('\\')) { return '\\?\UNC\' + $Value.Substring(2).TrimStart('\') }
    return '\\?\' + $Value
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
# Guard: danh sách tuyệt đối không được xoá (giống scan-once.ps1 + thư mục tool)
# -----------------------------------------------------------------------------
$script:ForbiddenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('SystemRoot', 'windir', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
        'ProgramData', 'ALLUSERSPROFILE', 'USERPROFILE', 'PUBLIC')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $full = Get-FullPathSafe $value
        if ($null -ne $full) { [void]$script:ForbiddenPaths.Add($full) }
    }
}
foreach ($name in @('Desktop', 'MyDocuments', 'MyPictures', 'MyMusic', 'MyVideos',
        'ApplicationData', 'LocalApplicationData', 'UserProfile', 'CommonDocuments')) {
    try {
        $value = [Environment]::GetFolderPath($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $full = Get-FullPathSafe $value
            if ($null -ne $full) { [void]$script:ForbiddenPaths.Add($full) }
        }
    } catch { }
}
$systemDrive = [Environment]::GetEnvironmentVariable('SystemDrive')
if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = 'C:' }
foreach ($name in @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'Users',
        'PerfLogs', 'Recovery', 'Boot', 'System Volume Information', 'Config.Msi', 'Windows.old')) {
    $full = Get-FullPathSafe "$systemDrive\$name"
    if ($null -ne $full) { [void]$script:ForbiddenPaths.Add($full) }
}
$toolFull = Get-FullPathSafe $script:ToolRoot
if ($null -ne $toolFull) { [void]$script:ForbiddenPaths.Add($toolFull) }

$script:NeverTouch = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('Windows', 'Windows.old', 'Program Files', 'Program Files (x86)', 'ProgramData',
        'Recovery', 'PerfLogs', 'Boot', 'System Volume Information', 'Config.Msi', '$Recycle.Bin',
        'AppData', 'Application Data', 'Local Settings')) {
    [void]$script:NeverTouch.Add($name)
}

# File hệ thống: xoá là hỏng máy.
$script:CriticalFileNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'bootmgr', 'BOOTNXT',
        'ntldr', 'ntdetect.com', 'desktop.ini', 'thumbs.db', 'dumpstack.log.tmp',
        'boot.ini', 'io.sys', 'msdos.sys', 'autoexec.bat', 'config.sys')) {
    [void]$script:CriticalFileNames.Add($name)
}

function Get-BlockReason {
    param([string]$FullPath)

    if ([string]::IsNullOrWhiteSpace($FullPath)) { return 'Đường dẫn rỗng.' }
    if ($FullPath -match '^[A-Za-z]:\\?$') { return 'Là gốc ổ đĩa.' }
    if ($FullPath -match '^\\\\') { return 'Đường dẫn mạng.' }

    $segments = @($FullPath.Split('\') | Where-Object { $_ -ne '' })
    $leaf = $segments[$segments.Count - 1]

    if ($script:CriticalFileNames.Contains($leaf)) { return "File hệ thống: $leaf" }

    for ($i = 1; $i -lt $segments.Count; $i++) {
        if ($script:NeverTouch.Contains($segments[$i])) { return "Nằm trong thư mục cấm '$($segments[$i])'." }
    }

    # Thư mục đặc biệt của Windows (Desktop, Documents, ...) chỉ bị chặn khi
    # chính nó là đường dẫn cần xoá; file bên trong vẫn xét tiếp các điều kiện khác.
    foreach ($forbidden in $script:ForbiddenPaths) {
        if ([string]::Equals($FullPath, $forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            return "Là thư mục hệ thống/người dùng ($forbidden)."
        }
    }

    # Nằm trong thư mục chứa công cụ này (repo presale-wiper): không tự xoá chính mình.
    if ($null -ne $toolFull) {
        $toolPrefix = if ($toolFull.EndsWith('\')) { $toolFull } else { $toolFull + '\' }
        if ($FullPath.StartsWith($toolPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return 'Nằm trong thư mục của chính công cụ này.'
        }
    }

    foreach ($pattern in $Keep) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($FullPath -like $pattern) { return "Khớp mẫu -Keep '$pattern'." }
    }

    if (-not [System.IO.File]::Exists((To-Long $FullPath))) { return 'File không còn tồn tại.' }

    return $null
}

# -----------------------------------------------------------------------------
# 1. Đọc kế hoạch từ scan
# -----------------------------------------------------------------------------
$planPath = $Plan
if ([string]::IsNullOrWhiteSpace($planPath)) {
    # Double-click: dùng kết quả scan mới nhất.
    $home_ = [Environment]::GetFolderPath('UserProfile')
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($home_)) {
        $candidates = @([System.IO.Directory]::GetDirectories((To-Long $home_), 'presale-scan-*') |
                Sort-Object -Descending)
    }
    if ($candidates.Count -eq 0) {
        Stop-WithError ('LỖI: chưa có kết quả scan nào trong thư mục người dùng.' + "`r`n" +
            'Chạy presale-scan.cmd trước, hoặc chỉ định: -Plan <đường dẫn>.')
    }
    $planPath = $candidates[0]
}
if ([System.IO.Directory]::Exists((To-Long $planPath))) {
    # Ưu tiên CSV: file JSON của lần quét toàn PC có thể hàng trăm MB, đọc bằng
    # ConvertFrom-Json sẽ ngốn RAM và mất hàng chục giây.
    $found = @([System.IO.Directory]::GetFiles((To-Long $planPath), 'danh-sach-file-*.csv'))
    if ($found.Count -eq 0) {
        $found = @([System.IO.Directory]::GetFiles((To-Long $planPath), 'danh-sach-file-*.json'))
    }
    if ($found.Count -eq 0) { Stop-WithError "LỖI: không thấy danh-sach-file-*.csv/.json trong $planPath" }
    $planPath = $found[0]
    foreach ($candidate in $found) {
        if ((Get-Item -LiteralPath $candidate).LastWriteTimeUtc -gt (Get-Item -LiteralPath $planPath).LastWriteTimeUtc) {
            $planPath = $candidate
        }
    }
}

if (-not [System.IO.File]::Exists((To-Long $planPath))) {
    Stop-WithError "LỖI: không tìm thấy file kế hoạch: $planPath"
}

$filesFromScan = New-Object 'System.Collections.Generic.List[object]'
if ($planPath.EndsWith('.csv', [StringComparison]::OrdinalIgnoreCase)) {
    $reader = New-Object System.IO.StreamReader ((To-Long $planPath), [System.Text.Encoding]::UTF8)
    try {
        $null = $reader.ReadLine()   # dòng tiêu đề
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            # CSV của scan chỉ có cột path/size/kind/reason, path có thể chứa dấu phẩy:
            # lấy phần trong ngoặc kép đầu tiên làm path, các cột sau không cần.
            if ($line[0] -ne '"') { continue }
            $close = $line.IndexOf('","')
            if ($close -lt 0) { continue }
            $path = $line.Substring(1, $close - 1).Replace('""', '"')
            [void]$filesFromScan.Add([PSCustomObject]@{ path = $path })
        }
    } finally {
        $reader.Dispose()
    }
} else {
    $planJson = [System.IO.File]::ReadAllText((To-Long $planPath), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -ne $planJson.PSObject.Properties['files']) { $filesFromScan = @($planJson.files) }
}

if ($filesFromScan.Count -eq 0) {
    Write-Line 'Danh sách rỗng - không có gì để dọn.'
    [Environment]::ExitCode = 0
    return
}

# -----------------------------------------------------------------------------
# 2. Lọc lại từng file
# -----------------------------------------------------------------------------
$willDelete = New-Object 'System.Collections.Generic.List[object]'
$skipped = New-Object 'System.Collections.Generic.List[object]'
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($entry in $filesFromScan) {
    $raw = [string]$entry.path
    $full = Get-FullPathSafe $raw
    if ($null -eq $full) {
        [void]$skipped.Add([PSCustomObject]@{ Path = $raw; Reason = 'Đường dẫn không hợp lệ.'; Size = 0L })
        continue
    }
    if (-not $seen.Add($full)) { continue }

    $reason = Get-BlockReason $full
    if ($null -ne $reason) {
        [void]$skipped.Add([PSCustomObject]@{ Path = $full; Reason = $reason; Size = 0L })
        continue
    }

    $size = 0L
    try { $size = (New-Object System.IO.FileInfo (To-Long $full)).Length } catch { }

    [void]$willDelete.Add([PSCustomObject]@{ Path = $full; Size = $size; Kind = [string]$entry.kind })
}

$totalBytes = 0L
foreach ($item in $willDelete) { $totalBytes += $item.Size }

# -----------------------------------------------------------------------------
# 3. Kết quả
# -----------------------------------------------------------------------------
$destination = if ([string]::IsNullOrWhiteSpace($OutDir)) { Split-Path -Parent (Get-FullPathSafe $planPath) } else { $OutDir }
if (-not [System.IO.Directory]::Exists((To-Long $destination))) {
    [void][System.IO.Directory]::CreateDirectory((To-Long $destination))
}

$mode = if ($Execute) { 'delete' } else { 'dry-run' }
$baseName = if ($Execute) { 'da-xoa' } else { 'ke-hoach-xoa' }
$stamp = '{0}-{1}' -f $baseName, $script:RunId

$txtPath = Join-Path $destination "$stamp.txt"
$csvPath = Join-Path $destination "$stamp.csv"
$jsonPath = Join-Path $destination "$stamp.json"

if ($Execute -and $ConfirmToken -ne 'XOA') {
    Stop-WithError "LỖI: -Execute cần -ConfirmToken XOA (bạn đang yêu cầu xoá vĩnh viễn)."
}
if ($Execute -and $willDelete.Count -gt $MaxFiles) {
    Stop-WithError ("LỖI: {0} file vượt trần -MaxFiles {1}. Tăng trần nếu thật sự muốn, hoặc dùng -Keep để loại trừ." -f $willDelete.Count, $MaxFiles)
}
if ($Execute -and $totalBytes -gt $MaxBytes) {
    Stop-WithError ("LỖI: {0:N1} GB vượt trần -MaxBytes {1:N1} GB. Tăng trần nếu thật sự muốn." -f ($totalBytes / 1GB), ($MaxBytes / 1GB))
}

$deleted = New-Object 'System.Collections.Generic.List[object]'
$failed = New-Object 'System.Collections.Generic.List[object]'

if ($Execute) {
    foreach ($item in $willDelete) {
        try {
            [System.IO.File]::Delete((To-Long $item.Path))
            [void]$deleted.Add($item)
        } catch {
            [void]$failed.Add([PSCustomObject]@{ Path = $item.Path; Reason = $_.Exception.Message; Size = $item.Size })
        }
    }
}

$doneBytes = 0L
foreach ($item in $deleted) { $doneBytes += $item.Size }

$noBom = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter ((To-Long $txtPath), $false, $noBom)
try {
    if ($Execute) {
        $writer.WriteLine('# presale-wiper - ĐÃ XOÁ VĨNH VIỄN (không hoàn tác được)')
    } else {
        $writer.WriteLine('# presale-wiper - KẾ HOẠCH XOÁ (mô phỏng, CHƯA xoá gì)')
    }
    $writer.WriteLine("# Tạo lúc: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $writer.WriteLine("# Nguồn: $planPath")
    $writer.WriteLine("# Sẽ xoá / đã xoá: $($willDelete.Count) file, $(Format-Bytes $totalBytes)")
    if ($Execute) { $writer.WriteLine("# Xoá thành công: $($deleted.Count) | Lỗi: $($failed.Count)") }
    $writer.WriteLine("# Bỏ qua (guard): $($skipped.Count) file")
    $writer.WriteLine('')
    foreach ($item in $willDelete) { $writer.WriteLine($item.Path) }
    if ($skipped.Count -gt 0) {
        $writer.WriteLine('')
        $writer.WriteLine('# --- BỎ QUA ---')
        foreach ($item in $skipped) { $writer.WriteLine(('# {0}  [{1}]' -f $item.Path, $item.Reason)) }
    }
} finally {
    $writer.Dispose()
}

$rows = @($willDelete | ForEach-Object {
        [PSCustomObject]@{ Path = $_.Path; SizeBytes = $_.Size; Kind = $_.Kind; Action = $mode }
    })
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$summary = [ordered]@{
    tool        = 'presale-wiper remove-once'
    mode        = $mode
    source      = $planPath
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    candidates  = $willDelete.Count
    skipped     = $skipped.Count
    sizeBytes   = $totalBytes
    sizeText    = Format-Bytes $totalBytes
    deleted     = if ($Execute) { $deleted.Count } else { 0 }
    failed      = if ($Execute) { $failed.Count } else { 0 }
    limits      = [ordered]@{ maxFiles = $MaxFiles; maxBytes = $MaxBytes }
    files       = @($willDelete | ForEach-Object { [ordered]@{ path = $_.Path; sizeBytes = $_.Size; kind = $_.Kind } })
    skippedList = @($skipped | ForEach-Object { [ordered]@{ path = $_.Path; reason = $_.Reason } })
    failedList  = @($failed | ForEach-Object { [ordered]@{ path = $_.Path; reason = $_.Reason } })
}
[System.IO.File]::WriteAllText((To-Long $jsonPath), (ConvertTo-Json -InputObject $summary -Depth 6), $noBom)

if (-not $Quiet) {
    Write-Line ''
    Write-Line ('=' * 76)
    if ($Execute) {
        Write-Line '  presale-wiper - XOÁ VĨNH VIỄN'
    } else {
        Write-Line '  presale-wiper - KẾ HOẠCH XOÁ (mô phỏng, chưa xoá gì)'
    }
    Write-Line ('=' * 76)
    Write-Line ''
    Write-Line ("  Nguồn danh sách : {0}" -f $planPath)
    Write-Line ("  Sẽ xử lý        : {0} file, {1}" -f $willDelete.Count, (Format-Bytes $totalBytes))
    Write-Line ("  Bỏ qua (guard)  : {0} file" -f $skipped.Count)
    if ($Execute) {
        Write-Line ("  Đã xoá          : {0} file, {1}" -f $deleted.Count, (Format-Bytes $doneBytes))
        Write-Line ("  Lỗi             : {0} file" -f $failed.Count)
    }
    Write-Line ''
    Write-Line '  File kế hoạch:'
    Write-Line ("    TXT  : {0}" -f $txtPath)
    Write-Line ("    CSV  : {0}" -f $csvPath)
    Write-Line ("    JSON : {0}" -f $jsonPath)
    Write-Line ''
    if ($Execute) {
        Write-Line 'Xong. Không khôi phục được những file đã xoá.'
    } else {
        Write-Line 'Chưa có file nào bị xoá. Đọc file TXT, rồi chạy lại với:'
        Write-Line "  -Execute -ConfirmToken XOA"
    }
    Write-Line ''
}

[Environment]::ExitCode = 0
