#Requires -Version 5.1
<#
    log.ps1 - Ghi log ra file (append, có timestamp, tự rotate).

    Vì sao log quan trọng ở tool xoá dữ liệu: khi user hỏi "hôm qua tool xoá
    gì của tôi", log là câu trả lời duy nhất. Vì vậy log được ghi cả trong
    dry-run - một dòng cho mỗi entry, kèm lý do và kích thước.

    Định dạng: TSV (tab-separated) để grep/Excel đều đọc được, và không
    vỡ khi path có dấu cách hay dấu phẩy.
#>

Set-StrictMode -Version Latest

$script:PswLogSession = $null

function New-PswLogSession {
    <#
        .SYNOPSIS
        Mở (hoặc tạo) file log để ghi trong suốt phiên chạy.

        .DESCRIPTION
        Rotate trước khi ghi: nếu file hiện tại > -RotateBytes thì đổi tên
        thành <name>.1.log (đẩy các bản cũ lên .2, .3, xoá .4).
        Nhờ vậy log không phình vô hạn khi user chạy tool nhiều lần.

        .PARAMETER Path
        Đường dẫn file log. Nếu là folder thì dùng tên mặc định.

        .OUTPUTS
        Object session, hoặc $null nếu -Disabled.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [long]$RotateBytes = 0,
        [switch]$Disabled
    )

    if ($Disabled) { $script:PswLogSession = $null; return $null }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }
        $logDir = Join-PswPath $script:PswConfig.HomeDir '.presale-wiper'
        $Path = Join-PswPath $logDir $script:PswConfig.Defaults.DefaultLogName
        $RotateBytes = [long]$script:PswConfig.Defaults.LogRotateBytes
    } elseif ($RotateBytes -le 0) {
        if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }
        $RotateBytes = [long]$script:PswConfig.Defaults.LogRotateBytes
    }

    $full = Get-PswFullPath $Path
    if ($null -eq $full) { throw "Đường dẫn log không hợp lệ: $Path" }

    if ((Test-PswPathExists $full) -and (Test-PswContainerPath $full)) {
        if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }
        $full = Join-PswPath $full $script:PswConfig.Defaults.DefaultLogName
    }

    $parent = Get-PswParentPath $full
    if ($null -ne $parent -and -not (Test-PswPathExists $parent)) {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-PswLongPath $parent))
    }

    $rotated = Invoke-PswLogRotation -Path $full -MaxBytes $RotateBytes

    $session = [PSCustomObject]@{
        Path     = $full
        Rotated  = $rotated
        EntryCount = 0
        Failed   = $null
    }

    try {
        # Header chỉ ghi khi file mới (tránh lặp header mỗi lần chạy)
        $exists = [System.IO.File]::Exists((ConvertTo-PswLongPath $full))
        if (-not $exists) {
            $header = "# presale-wiper log`tversion=$(Get-PswVersion)`tformat=tsv"
            $columns = "timestamp`tlevel`taction`tkind`tsizeBytes`tpath`tdetail"
            [System.IO.File]::AppendAllText((ConvertTo-PswLongPath $full), "$header`r`n$columns`r`n", (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {
        $session.Failed = $_.Exception.Message
    }

    $script:PswLogSession = $session
    return $session
}

function Test-PswContainerPath {
    <#
        .SYNOPSIS
        Path có phải folder không (dùng cho long path)?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        return [System.IO.Directory]::Exists((ConvertTo-PswLongPath $Path))
    } catch {
        return $false
    }
}

function Invoke-PswLogRotation {
    <#
        .SYNOPSIS
        Rotate <name>.log -> <name>.1.log -> <name>.2.log -> <name>.3.log.

        .OUTPUTS
        [bool] đã rotate hay chưa.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [long]$MaxBytes = 10485760,
        [int]$Keep = 3
    )

    try {
        $long = ConvertTo-PswLongPath $Path
        if (-not [System.IO.File]::Exists($long)) { return $false }
        $info = New-Object System.IO.FileInfo $long
        if ($info.Length -le $MaxBytes) { return $false }

        # DirectoryName trên FileInfo có prefix sẽ trả về '\\?\C:\dir', nên
        # phải bỏ prefix trước khi Join-Path (xem Join-PswPath).
        $directory = ConvertFrom-PswLongPath $info.DirectoryName
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($info.Name)
        $extension = $info.Extension

        # Ngữ nghĩa của -Keep N: sau khi rotate còn đúng N bản backup
        # (.1 ... .N) cộng với file log hiện tại.
        #   Bước 1: xoá mọi bản có số >= N (bản cũ nhất sẽ bị đẩy ra ngoài).
        #   Bước 2: đẩy .(N-1) -> .N, ..., .1 -> .2.
        #   Bước 3: file hiện tại -> .1.
        foreach ($existing in [System.IO.Directory]::EnumerateFiles((ConvertTo-PswLongPath $directory), "$baseName.*$extension")) {
            $existingName = [System.IO.Path]::GetFileName($existing)
            if ($existingName -notmatch "^$([regex]::Escape($baseName))\.(\d+)$([regex]::Escape($extension))$") { continue }
            if ([int]$matches[1] -ge $Keep) {
                [System.IO.File]::Delete($existing)
            }
        }

        for ($i = $Keep - 1; $i -ge 1; $i--) {
            $current = Join-PswPath $directory ('{0}.{1}{2}' -f $baseName, $i, $extension)
            $next = Join-PswPath $directory ('{0}.{1}{2}' -f $baseName, ($i + 1), $extension)
            $currentLong = ConvertTo-PswLongPath $current
            if (-not [System.IO.File]::Exists($currentLong)) { continue }
            [System.IO.File]::Move($currentLong, (ConvertTo-PswLongPath $next))
        }

        $first = Join-PswPath $directory ('{0}.1{1}' -f $baseName, $extension)
        [System.IO.File]::Move($long, (ConvertTo-PswLongPath $first))
        return $true
    } catch {
        return $false
    }
}

function Add-PswLogEntry {
    <#
        .SYNOPSIS
        Ghi một dòng log.

        .PARAMETER Level
        INFO / WARN / ERROR / DRYRUN.

        .PARAMETER Action
        SCAN / DELETE / SKIP / UNREGISTER ...

        .PARAMETER Detail
        Text tự do. Tab và xuống dòng được thay bằng dấu cách để không vỡ TSV.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DRYRUN')][string]$Level = 'INFO',
        [string]$Action = 'SCAN',
        [string]$Kind = '',
        [long]$SizeBytes = 0,
        [string]$Path = '',
        [string]$Detail = ''
    )

    if ($null -eq $script:PswLogSession) { return }

    $safeDetail = if ([string]::IsNullOrEmpty($Detail)) { $Message } else { $Detail }
    $safeDetail = ($safeDetail -replace "[`t`r`n]+", ' ').Trim()
    if ($safeDetail.Length -gt 400) { $safeDetail = $safeDetail.Substring(0, 400) + '...' }

    $safePath = ($Path -replace "[`t`r`n]+", ' ')
    $safeKind = ($Kind -replace "[`t`r`n]+", ' ')

    # CHÚ Ý: format string PHẢI dùng nháy kép, vì `t chỉ được PowerShell
    # diễn giải trong chuỗi nháy kép. Dùng nháy đơn sẽ ghi ra literal "`t"
    # và toàn bộ file log thành 1 cột duy nhất.
    $line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f `
    ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')), $Level, $Action, $safeKind, $SizeBytes, $safePath, $safeDetail

    try {
        [System.IO.File]::AppendAllText((ConvertTo-PswLongPath $script:PswLogSession.Path), $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $script:PswLogSession.EntryCount = [int]$script:PswLogSession.EntryCount + 1
    } catch {
        $script:PswLogSession.Failed = $_.Exception.Message
    }
}

function Close-PswLogSession {
    <#
        .SYNOPSIS
        Đóng phiên log và trả về thông tin phiên.
    #>
    [CmdletBinding()]
    param()

    $session = $script:PswLogSession
    $script:PswLogSession = $null
    return $session
}

function Get-PswLogSession {
    [CmdletBinding()]
    param()
    return $script:PswLogSession
}

function Read-PswLogFile {
    <#
        .SYNOPSIS
        Đọc log đã ghi và trả về các dòng dạng object.

        .DESCRIPTION
        Dùng cho subcommand `report --from-log` (Phase 4). Bỏ qua dòng
        comment (#) và header. Không ném lỗi nếu file hỏng.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [int]$Tail = 0
    )

    $full = Get-PswFullPath $Path
    if ($null -eq $full -or -not (Test-PswPathExists $full)) {
        throw "Không tìm thấy file log: $Path"
    }

    $lines = [System.IO.File]::ReadAllLines((ConvertTo-PswLongPath $full))
    $records = New-Object 'System.Collections.Generic.List[object]'

    $index = 0
    foreach ($line in $lines) {
        $index++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }
        if ($line.StartsWith("timestamp`tlevel")) { continue }

        $parts = $line.Split("`t")
        if ($parts.Count -lt 7) { continue }

        $size = 0L
        [void][long]::TryParse($parts[4], [ref]$size)

        $records.Add([PSCustomObject]@{
                LineNo    = $index
                Timestamp = $parts[0]
                Level     = $parts[1]
                Action    = $parts[2]
                Kind      = $parts[3]
                SizeBytes = $size
                Path      = $parts[5]
                Detail    = ($parts[6..($parts.Count - 1)] -join ' ')
            })
    }

    if ($Tail -gt 0 -and $records.Count -gt $Tail) {
        return @($records | Select-Object -Last $Tail)
    }
    return $records.ToArray()
}
