#Requires -Version 5.1
<#
    cli.ps1 - Mặt tiền dòng lệnh.

    Triết lý CLI của presale-wiper: KHÔNG có chế độ nào xoá dữ liệu mà
    không được yêu cầu rõ ràng. Ở giai đoạn này (Phase 1) chỉ có scan,
    nên mọi thứ đều là dry-run tuyệt đối.

    Exit codes:
        0 = OK
        1 = lỗi nhẹ (vài mục không đọc được, scan vẫn xong)
        2 = lỗi nghiêm trọng (không quét được gì / tham số sai)
        3 = user cancel
#>

Set-StrictMode -Version Latest

function Write-PswStdout {
    <#
        .SYNOPSIS
        Ghi dữ liệu ra STDOUT thật (không qua pipeline của hàm).

        .DESCRIPTION
        Vì sao không dùng Write-Output ở đây:
        các hàm trong file này vừa XUẤT DỮ LIỆU (JSON, text) vừa TRẢ VỀ
        exit code. Trong PowerShell, mọi thứ ghi bằng Write-Output / trả về
        không kèm từ khoá đều bị gom vào cùng một luồng output của hàm.
        Hệ quả: `$exitCode = Invoke-PswCli ...` sẽ nhận một MẢNG gồm cả chuỗi
        JSON lẫn số 0, và chuỗi JSON không bao giờ tới được stdout.

        [Console]::Out ghi thẳng ra stdout của tiến trình, hoàn toàn tách khỏi
        luồng output của hàm, nên exit code vẫn là số nguyên sạch và dữ liệu
        vẫn tới được chỗ cần (pipe, file, redirect).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text
    )

    [Console]::Out.WriteLine($Text)
}

function Get-PswUsage {
    <#
        .SYNOPSIS
        Text trợ giúp.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @"
presale-wiper $(Get-PswVersion) - dọn môi trường dev trước khi bán máy (Windows)

CÁCH DÙNG
    presale-wiper.ps1 <lệnh> [đường-dẫn...] [tuỳ-chọn]

LỆNH
    scan      Liệt kê những gì sẽ bị xoá. ĐÂY LÀ MẶC ĐỊNH - không xoá gì.
    verify    Quét lại để kiểm tra còn sót gì (dùng sau khi clean).
    report    Đọc lại một file log cũ.
    clean     (chưa có ở bản này - sẽ ra mắt ở milestone M1)

TUỲ CHỌN
    -Path <string[]>       Thư mục cần quét. Mặc định: các thư mục dev quen thuộc.
    -IncludeHome           Cho phép quét cả %USERPROFILE% (chậm hơn nhiều).
    -Exclude <string[]>    Mẫu loại trừ (wildcard, khớp full path hoặc tên).
    -MinSize <string>      Chỉ báo cáo mục >= kích thước này (vd: 100MB).
    -MaxDepth <int>        Độ sâu tối đa tính từ root (mặc định 4).
    -NoSize                Không đo dung lượng (nhanh hơn, size = 0).
    -Json                  Xuất JSON ra stdout thay vì bảng.
    -JsonPath <string>     Ghi JSON ra file.
    -Log <string>          Ghi log ra file (mặc định: ~/.presale-wiper/presale-wiper.log).
    -NoLog                 Không ghi log.
    -Quiet                 Chỉ in tổng kết.
    -Yes                   Bỏ qua câu hỏi xác nhận (dùng cho clean sau này).

VÍ DỤ
    .\presale-wiper.ps1 scan
    .\presale-wiper.ps1 scan C:\Test
    .\presale-wiper.ps1 scan C:\Users\Admin\Desktop -MinSize 50MB
    .\presale-wiper.ps1 scan -Json > report.json
    .\presale-wiper.ps1 report -FromLog ~\.presale-wiper\presale-wiper.log -Tail 50

LƯU Ý AN TOÀN
    * Bản này là readonly: chỉ quét, không xoá, không sửa gì.
    * Junction/symlink không bao giờ bị đi theo.
    * File log chứa đường dẫn tuyệt đối - đừng chia sẻ công khai.
    * Tool KHÔNG thay thế factory reset. Xem docs/SAFETY.md.
"@
}

function ConvertTo-PswByteSize {
    <#
        .SYNOPSIS
        Parse '-MinSize 100MB' / '1.5 GB' / '2097152' -> long bytes.

        .DESCRIPTION
        Chấp nhận KB/MB/GB/TB (nhị phân) và K/M/G/T; có hoặc không có 'B'.
        Trả về $null nếu không parse được (để CLI báo lỗi tham số).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $trimmed = $Text.Trim()
    if ($trimmed -match '^\d+$') {
        $plain = 0L
        if ([long]::TryParse($trimmed, [ref]$plain)) { return $plain }
        return $null
    }

    if ($trimmed -notmatch '^(?<value>\d+(?:[.,]\d+)?)\s*(?<unit>[KMGTP]?)(?:i?B)?$') { return $null }

    $value = [double]::Parse(($matches['value'] -replace ',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
    $unit = $matches['unit'].ToUpperInvariant()

    $power = switch ($unit) {
        '' { 0 }
        'K' { 1 }
        'M' { 2 }
        'G' { 3 }
        'T' { 4 }
        'P' { 5 }
        default { return $null }
    }

    $bytes = $value * [Math]::Pow(1024, $power)
    if ($bytes -lt 0) { return $null }
    return [long]$bytes
}

function Invoke-PswScanCommand {
    <#
        .SYNOPSIS
        Thực thi lệnh scan (không xoá gì).
    #>
    [CmdletBinding()]
    param(
        [string[]]$Path = @(),
        [switch]$IncludeHome,
        [string[]]$Exclude = @(),
        [string]$MinSize,
        [int]$MaxDepth = -1,
        [switch]$NoSize,
        [switch]$Json,
        [string]$JsonPath,
        [string]$Log,
        [switch]$NoLog,
        [switch]$Quiet,
        [switch]$NoErrors
    )

    $exitCode = 0

    $options = New-PswScanOptions
    $options.IncludeHome = [bool]$IncludeHome
    $options.SkipSize = [bool]$NoSize
    $options.Quiet = [bool]$Quiet
    $options.ExcludePatterns = @($Exclude)
    if ($MaxDepth -ge 0) { $options.MaxDepth = $MaxDepth }

    if (-not [string]::IsNullOrWhiteSpace($MinSize)) {
        $minBytes = ConvertTo-PswByteSize $MinSize
        if ($null -eq $minBytes) {
            Write-PswErrorLine "Giá trị -MinSize không hợp lệ: '$MinSize'. Ví dụ đúng: 100MB, 1.5GB, 2097152."
            return 2
        }
        $options.MinSizeBytes = [long]$minBytes
    }

    if (-not $NoLog) {
        try {
            [void](New-PswLogSession -Path $Log)
        } catch {
            Write-PswWarnLine "Không tạo được log: $($_.Exception.Message)"
            $exitCode = 1
        }
    }

    Add-PswLogEntry -Message "Bắt đầu scan" -Action 'SCAN' -Level 'INFO' `
        -Detail ("roots=[{0}] includeHome={1} maxDepth={2}" -f ($Path -join '; '), $IncludeHome, $options.MaxDepth)

    $scanResult = $null
    try {
        $scanResult = Invoke-PswScan -Root $Path -Options $options
    } catch {
        Add-PswLogEntry -Message 'Scan thất bại' -Action 'SCAN' -Level 'ERROR' -Detail $_.Exception.Message
        Write-PswErrorLine "Scan thất bại: $($_.Exception.Message)"
        [void](Close-PswLogSession)
        return 2
    }

    $summary = Get-PswScanSummary -ScanResult $scanResult

    foreach ($entry in $summary.Entries) {
        Add-PswLogEntry -Message 'Entry' -Action 'SCAN' -Level 'DRYRUN' -Kind $entry.Kind `
            -SizeBytes $entry.SizeBytes -Path $entry.Path `
            -Detail $(if ($entry.Protected) { "PROTECTED: $($entry.ProtectionReason)" } else { $entry.Reason })
    }
    foreach ($err in $summary.Errors) {
        Add-PswLogEntry -Message 'Lỗi quét' -Action 'SCAN' -Level 'WARN' -Path ([string]$err.Path) -Detail ([string]$err.Error)
    }

    if ($Json -or -not [string]::IsNullOrWhiteSpace($JsonPath)) {
        $jsonText = ConvertTo-PswReportObject -ScanResult $scanResult -Mode 'scan' | ConvertTo-Json -Depth 8
        if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
            Write-PswJsonReport -ScanResult $scanResult -Mode 'scan' -Path $JsonPath | Out-Null
            if (-not $Json) { Write-Host "Đã ghi JSON: $JsonPath" }
        }
        if ($Json) { Write-PswStdout $jsonText }
    }

    if (-not $Json) {
        Write-PswScanReport -ScanResult $scanResult -Quiet:$Quiet -NoErrors:$NoErrors
    }

    if ($summary.Errors.Count -gt 0) { $exitCode = 1 }

    $session = Close-PswLogSession
    if ($null -ne $session) {
        if (-not [string]::IsNullOrWhiteSpace($session.Failed)) {
            Write-PswWarnLine "Ghi log có lỗi: $($session.Failed)"
            $exitCode = 1
        } elseif (-not $Json) {
            Write-Host ("Log: {0} ({1} dòng{2})" -f $session.Path, $session.EntryCount,
                $(if ($session.Rotated) { ', đã rotate bản cũ' } else { '' }))
        }
    }

    return $exitCode
}

function Invoke-PswVerifyCommand {
    <#
        .SYNOPSIS
        Quét lại và chỉ báo cáo những gì còn sót (dùng sau khi clean).

        .DESCRIPTION
        Khác scan ở chỗ: mặc định KHÔNG in các mục đã protected (vì đó là
        thứ tool cố tình giữ lại), chỉ in những mục "đáng lẽ phải sạch".
    #>
    [CmdletBinding()]
    param(
        [string[]]$Path = @(),
        [switch]$IncludeHome,
        [string[]]$Exclude = @(),
        [int]$MaxDepth = -1,
        [switch]$Json,
        [string]$Log,
        [switch]$NoLog
    )

    $options = New-PswScanOptions
    $options.IncludeHome = [bool]$IncludeHome
    $options.ExcludePatterns = @($Exclude)
    if ($MaxDepth -ge 0) { $options.MaxDepth = $MaxDepth }

    if (-not $NoLog) {
        try { [void](New-PswLogSession -Path $Log) } catch { }
    }

    $scanResult = Invoke-PswScan -Root $Path -Options $options
    $summary = Get-PswScanSummary -ScanResult $scanResult
    $remaining = @($summary.Entries | Where-Object { -not $_.Protected })

    $object = [ordered]@{
        tool        = 'presale-wiper'
        version     = (Get-PswVersion)
        mode        = 'verify'
        generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        clean       = ($remaining.Count -eq 0)
        remaining   = [ordered]@{ count = $remaining.Count; sizeBytes = [long]$summary.DeletableSizeBytes }
        items       = @($remaining | ForEach-Object {
                [ordered]@{ path = $_.Path; kind = $_.Kind; sizeBytes = [long]$_.SizeBytes }
            })
        errors      = @($summary.Errors | ForEach-Object { [ordered]@{ path = [string]$_.Path; message = [string]$_.Error } })
    }

    if ($Json) {
        Write-PswStdout (ConvertTo-Json -InputObject $object -Depth 6)
    } else {
        Write-Host ''
        Write-Host 'presale-wiper - VERIFY'
        Write-Host ('=' * 60)
        if ($remaining.Count -eq 0) {
            Write-Host 'Không còn mục nào cần dọn. Môi trường đã sạch (theo tiêu chí của tool).'
        } else {
            Write-Host ("Còn {0} mục ({1}) chưa được dọn:" -f $remaining.Count, (Format-PswSize $summary.DeletableSizeBytes))
            $rows = @($remaining | Sort-Object -Property SizeBytes -Descending)
            $columns = @(
                @{ Header = 'Loại'; Expression = { $_.Kind } }
                @{ Header = 'Dung lượng'; Expression = { Format-PswSize $_.SizeBytes }; Align = 'Right' }
                @{ Header = 'Đường dẫn'; Expression = { $_.Path } }
            )
            foreach ($line in (Format-PswTable -Row $rows -Column $columns -MaxWidth 150)) { Write-Host $line }
        }

        if ($summary.Errors.Count -gt 0) {
            Write-Host ''
            Write-Host ("Cảnh báo: {0} lỗi khi quét." -f $summary.Errors.Count)
            foreach ($err in @($summary.Errors | Select-Object -First 10)) {
                Write-Host ("  {0}: {1}" -f $err.Path, $err.Error)
            }
        }
        Write-Host ''
    }

    [void](Close-PswLogSession)
    return $(if ($summary.Errors.Count -gt 0) { 1 } else { 0 })
}

function Invoke-PswReportCommand {
    <#
        .SYNOPSIS
        Đọc một file log cũ và tóm tắt lại.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FromLog,
        [int]$Tail = 0,
        [switch]$Json
    )

    try {
        $records = Read-PswLogFile -Path $FromLog -Tail $Tail
    } catch {
        Write-PswErrorLine $_.Exception.Message
        return 2
    }

    $byAction = $records | Group-Object -Property Action | ForEach-Object {
        [ordered]@{
            action    = $_.Name
            count     = $_.Count
            sizeBytes = [long](($_.Group | Measure-Object -Property SizeBytes -Sum).Sum)
        }
    }

    if ($Json) {
        $object = [ordered]@{
            tool    = 'presale-wiper'
            version = (Get-PswVersion)
            mode    = 'report'
            source  = (Get-PswFullPath $FromLog)
            totals  = [ordered]@{
                lines     = $records.Count
                sizeBytes = [long](($records | Measure-Object -Property SizeBytes -Sum).Sum)
            }
            byAction = @($byAction)
        }
        Write-PswStdout (ConvertTo-Json -InputObject $object -Depth 5)
        return 0
    }

    Write-Host ''
    Write-Host ("presale-wiper - REPORT từ log: {0}" -f (Get-PswFullPath $FromLog))
    Write-Host ('=' * 60)

    if ($records.Count -eq 0) {
        Write-Host 'Log rỗng hoặc không có dòng hợp lệ.'
        return 0
    }

    Write-Host ("Số dòng: {0}" -f $records.Count)
    Write-Host ("Tổng dung lượng ghi nhận: {0}" -f (Format-PswSize ([long](($records | Measure-Object -Property SizeBytes -Sum).Sum))))
    Write-Host ''
    Write-Host 'Theo hành động:'
    foreach ($group in ($records | Group-Object -Property Action)) {
        Write-Host ("  {0,-12} {1,5} dòng" -f $group.Name, $group.Count)
    }

    Write-Host ''
    Write-Host 'Dòng cuối:'
    foreach ($record in @($records | Select-Object -Last 10)) {
        Write-Host ("  [{0}] {1,-6} {2,-10} {3}" -f $record.Timestamp, $record.Level, $record.Action, $record.Path)
    }
    Write-Host ''

    return 0
}

function Write-PswErrorLine {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-Host "LỖI: $Message" -ForegroundColor Red
}

function Write-PswWarnLine {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-Host "CẢNH BÁO: $Message" -ForegroundColor Yellow
}

function Select-PswArgumentSet {
    <#
        .SYNOPSIS
        Lọc hashtable tham số CLI xuống đúng những gì một lệnh chấp nhận.

        .DESCRIPTION
        Splatting một hashtable có tham số lạ sẽ ném lỗi
        "A parameter cannot be found", nên mỗi lệnh có danh sách trắng.
        Đây cũng là nơi duy nhất cần cập nhật khi thêm tham số mới.

        .PARAMETER For
        Tên lệnh: scan / verify / report.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Arguments,
        [Parameter(Mandatory, Position = 1)]
        [ValidateSet('scan', 'verify', 'report')][string]$For
    )

    $accepted = switch ($For) {
        'scan' {
            @('Path', 'IncludeHome', 'Exclude', 'MinSize', 'MaxDepth', 'NoSize',
                'Json', 'JsonPath', 'Log', 'NoLog', 'Quiet', 'NoErrors')
        }
        'verify' { @('Path', 'IncludeHome', 'Exclude', 'MaxDepth', 'Json', 'Log', 'NoLog') }
        'report' { @('FromLog', 'Tail', 'Json') }
    }

    $filtered = @{}
    foreach ($key in $accepted) {
        if ($Arguments.ContainsKey($key)) { $filtered[$key] = $Arguments[$key] }
    }
    return $filtered
}

function Invoke-PswCli {
    <#
        .SYNOPSIS
        Entry point của CLI. Trả về exit code.

        .PARAMETER Command
        scan / verify / report / clean / help / version. Rỗng -> scan.

        .DESCRIPTION
        Tham số được truyền dưới dạng hashtable/object để script wrapper
        (presale-wiper.ps1) map từ tham số PowerShell vào.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Command = 'scan',
        [hashtable]$Arguments = @{}
    )

    $normalized = if ([string]::IsNullOrWhiteSpace($Command)) { 'scan' } else { $Command.Trim().ToLowerInvariant() }

    # Bỏ qua tham số null để không phải kiểm tra từng cái bên dưới
    $argsHashtable = @{}
    if ($null -ne $Arguments) {
        foreach ($key in $Arguments.Keys) {
            if ($null -ne $Arguments[$key]) { $argsHashtable[$key] = $Arguments[$key] }
        }
    }

    switch ($normalized) {
        'scan' {
            $scanArgs = Select-PswArgumentSet -Arguments $argsHashtable -For 'scan'
            return Invoke-PswScanCommand @scanArgs
        }
        'verify' {
            $verifyArgs = Select-PswArgumentSet -Arguments $argsHashtable -For 'verify'
            return Invoke-PswVerifyCommand @verifyArgs
        }
        'report' {
            if (-not $argsHashtable.ContainsKey('FromLog') -or [string]::IsNullOrWhiteSpace($argsHashtable['FromLog'])) {
                Write-PswErrorLine 'Lệnh report cần -FromLog <đường-dẫn-file-log>.'
                return 2
            }
            $reportArgs = Select-PswArgumentSet -Arguments $argsHashtable -For 'report'
            return Invoke-PswReportCommand @reportArgs
        }
        'clean' {
            Write-PswErrorLine 'Lệnh clean chưa được bật trong bản này (Phase 1 chỉ quét).'
            Write-Host 'Xem docs/SAFETY.md - clean sẽ ra mắt ở milestone M1 cùng dry-run mặc định.' -ForegroundColor Yellow
            return 2
        }
        { $_ -in @('help', '-h', '--help', '/?', '?') } {
            Write-PswStdout (Get-PswUsage)
            return 0
        }
        { $_ -in @('version', '-v', '--version') } {
            Write-PswStdout "presale-wiper $(Get-PswVersion)"
            return 0
        }
        default {
            Write-PswErrorLine "Lệnh không hợp lệ: '$Command'."
            Write-Host 'Các lệnh hợp lệ: scan, verify, report, clean, help, version.'
            return 2
        }
    }
}
