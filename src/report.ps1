#Requires -Version 5.1
<#
    report.ps1 - Dựng report (console / JSON) từ kết quả scan.

    Phase 1 chỉ có scan -> report. Phase 2 (clean) sẽ dùng lại đúng
    các hàm ở đây với Kind = hành động đã thực hiện.
#>

Set-StrictMode -Version Latest

function Get-PswScanSummary {
    <#
        .SYNOPSIS
        Tổng hợp kết quả scan thành các con số dùng được cho cả console và JSON.

        .PARAMETER ScanResult
        Object trả về từ Invoke-PswScan.

        .OUTPUTS
        [PSCustomObject] với các nhóm: Counts, Sizes, Top, ByKind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$ScanResult
    )

    $entries = @($ScanResult.Entries)
    $deletable = @($entries | Where-Object { -not $_.Protected })
    $protected = @($entries | Where-Object { $_.Protected })

    function SumBytes($items) {
        $total = 0L
        foreach ($item in $items) { $total += [long]$item.SizeBytes }
        return $total
    }

    $byKind = [ordered]@{}
    foreach ($kind in (Get-PswEntryKinds)) {
        $subset = @($entries | Where-Object { $_.Kind -eq $kind })
        $byKind[$kind] = [PSCustomObject]@{
            Count     = $subset.Count
            SizeBytes = SumBytes $subset
        }
    }

    return [PSCustomObject]@{
        EntryCount        = $entries.Count
        DeletableCount    = $deletable.Count
        ProtectedCount    = $protected.Count
        TotalSizeBytes    = (SumBytes $entries)
        DeletableSizeBytes = (SumBytes $deletable)
        ProtectedSizeBytes = (SumBytes $protected)
        ByKind            = $byKind
        Top               = @($deletable | Sort-Object -Property SizeBytes -Descending | Select-Object -First 10)
        Errors            = @($ScanResult.Errors)
        Stats             = $ScanResult.Stats
        Roots             = @($ScanResult.Roots)
        Entries           = $entries
    }
}

function Get-PswDisplayPath {
    <#
        .SYNOPSIS
        Path để hiển thị trên console: tương đối so với root gần nhất,
        và rút gọn phần giữa nếu vẫn còn quá dài.

        .DESCRIPTION
        Path tuyệt đối của một folder deep 300 ký tự sẽ đẩy bảng ra ngoài
        màn hình và vô dụng với người đọc. Hiển thị tương đối so với root
        ("long_path_dir\sub_xxx\...\sub_xxx") giữ được ngữ cảnh.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]$Entry,
        [object[]]$Root = @(),
        [int]$MaxLength = 90
    )

    $path = [string]$Entry.Path
    if ([string]::IsNullOrEmpty($path)) { return '' }

    # Chọn root dài nhất mà entry nằm dưới
    $bestRoot = $null
    $bestLength = -1
    foreach ($rootItem in $Root) {
        $rootPath = [string]$rootItem.Path
        if ([string]::IsNullOrWhiteSpace($rootPath)) { continue }
        if (-not (Test-PswPathIsUnder -Path $path -Parent $rootPath)) { continue }
        if ($rootPath.Length -gt $bestLength) {
            $bestRoot = $rootPath
            $bestLength = $rootPath.Length
        }
    }

    $display = if ($null -ne $bestRoot) {
        Get-PswRelativePath -Path $path -Base $bestRoot
    } else {
        $path
    }

    if ($display.Length -le $MaxLength) { return $display }

    # Rút gọn giữa: giữ vài component đầu và cuối
    $segments = $display.Split('\')
    if ($segments.Count -le 3) { return $display }

    $head = $segments[0]
    $tail = $segments[($segments.Count - 2)..($segments.Count - 1)] -join '\'
    return ('{0}\...\{1}' -f $head, $tail)
}

function Format-PswTable {
    <#
        .SYNOPSIS
        Vẽ bảng text không cần module ngoài.

        .PARAMETER Row
        Mảng object. Mỗi object là 1 dòng.

        .PARAMETER Column
        Định nghĩa cột: @{ Header; Expression (scriptblock); Align ('Left'/'Right') }.

        .PARAMETER MaxWidth
        Tổng trần chiều rộng; cột co giãn đầu tiên sẽ bị cắt nếu vượt.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Row,
        [Parameter(Mandatory, Position = 1)][object[]]$Column,
        [int]$MaxWidth = 160
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Row -or $Row.Count -eq 0) { return $lines.ToArray() }

    # Chuẩn hoá cột: cho phép viết tắt (thiếu Align, thiếu Header) mà không
    # phải kiểm tra tồn tại key ở từng vòng lặp bên dưới.
    $columns = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $Column.Count; $i++) {
        $columns.Add((ConvertTo-PswTableColumn $Column[$i]))
    }
    $columnCount = $columns.Count

    $cells = New-Object 'System.Collections.Generic.List[object[]]'
    $widths = New-Object 'int[]' $columnCount
    for ($i = 0; $i -lt $columnCount; $i++) {
        $widths[$i] = ([string]$columns[$i].Header).Length
    }

    foreach ($item in $Row) {
        $rowCells = New-Object 'string[]' $columnCount
        for ($i = 0; $i -lt $columnCount; $i++) {
            # Chạy qua ForEach-Object để biểu thức viết theo kiểu $_ quen thuộc
            # (không dùng & vì như vậy $_ sẽ không được set).
            $value = $item | ForEach-Object -Process $columns[$i].Expression
            $text = if ($null -eq $value) { '' } else { [string]$value }
            $rowCells[$i] = $text
            if ($text.Length -gt $widths[$i]) { $widths[$i] = $text.Length }
        }
        $cells.Add($rowCells)
    }

    # Co lại nếu rộng quá: cắt ở cột dài nhất
    $totalWidth = ($widths | Measure-Object -Sum).Sum + (($columnCount - 1) * 2)
    if ($totalWidth -gt $MaxWidth) {
        $overflow = $totalWidth - $MaxWidth
        $widestIndex = 0
        for ($i = 1; $i -lt $widths.Count; $i++) {
            if ($widths[$i] -gt $widths[$widestIndex]) { $widestIndex = $i }
        }
        $newWidth = [Math]::Max(12, $widths[$widestIndex] - $overflow)
        $widths[$widestIndex] = $newWidth

        for ($r = 0; $r -lt $cells.Count; $r++) {
            $text = $cells[$r][$widestIndex]
            if ($text.Length -gt $newWidth) {
                $cells[$r][$widestIndex] = Get-PswTruncatedText -Text $text -MaxLength $newWidth
            }
        }
    }

    $header = New-Object 'System.Text.StringBuilder'
    for ($i = 0; $i -lt $columnCount; $i++) {
        if ($i -gt 0) { [void]$header.Append('  ') }
        [void]$header.Append(([string]$columns[$i].Header).PadRight($widths[$i]))
    }
    $lines.Add($header.ToString().TrimEnd())

    $separator = New-Object 'System.Text.StringBuilder'
    for ($i = 0; $i -lt $columnCount; $i++) {
        if ($i -gt 0) { [void]$separator.Append('  ') }
        [void]$separator.Append(('-' * $widths[$i]))
    }
    $lines.Add($separator.ToString())

    foreach ($rowCells in $cells) {
        $line = New-Object 'System.Text.StringBuilder'
        for ($i = 0; $i -lt $columnCount; $i++) {
            if ($i -gt 0) { [void]$line.Append('  ') }
            $cellText = $rowCells[$i]
            if ($cellText.Length -gt $widths[$i]) {
                $cellText = Get-PswTruncatedText -Text $cellText -MaxLength $widths[$i]
            }
            $align = [string]$columns[$i].Align
            if ($align -eq 'Right') { [void]$line.Append($cellText.PadLeft($widths[$i])) }
            else { [void]$line.Append($cellText.PadRight($widths[$i])) }
        }
        $lines.Add($line.ToString().TrimEnd())
    }

    return $lines.ToArray()
}

function ConvertTo-PswTableColumn {
    <#
        .SYNOPSIS
        Chuẩn hoá 1 định nghĩa cột: Header (string), Expression (scriptblock),
        Align ('Left'|'Right'). Nhận hashtable hoặc object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Column
    )

    $header = ''
    $expression = $null
    $align = 'Left'

    if ($Column -is [hashtable]) {
        if ($Column.ContainsKey('Header')) { $header = [string]$Column['Header'] }
        if ($Column.ContainsKey('Expression')) { $expression = $Column['Expression'] }
        if ($Column.ContainsKey('Align')) { $align = [string]$Column['Align'] }
    } else {
        $headerProperty = $Column.PSObject.Properties['Header']
        if ($null -ne $headerProperty) { $header = [string]$headerProperty.Value }

        $expressionProperty = $Column.PSObject.Properties['Expression']
        if ($null -ne $expressionProperty) { $expression = $expressionProperty.Value }

        $alignProperty = $Column.PSObject.Properties['Align']
        if ($null -ne $alignProperty) { $align = [string]$alignProperty.Value }
    }

    if ($null -eq $expression) { $expression = { '' } }
    if ($align -ne 'Right') { $align = 'Left' }

    return [PSCustomObject]@{
        Header     = $header
        Expression = $expression
        Align      = $align
    }
}

function Write-PswScanReport {
    <#
        .SYNOPSIS
        In báo cáo scan ra console (text). Không dùng màu ANSI để an toàn
        với mọi terminal cũ và với output bị pipe/redirect.

        .PARAMETER Quiet
        Chỉ in phần tổng kết, không in bảng entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$ScanResult,
        [switch]$Quiet,
        [switch]$NoErrors
    )

    $summary = Get-PswScanSummary -ScanResult $ScanResult
    $writer = { param($text) Write-Host $text }

    $out = New-Object 'System.Collections.Generic.List[string]'

    $out.Add('')
    $out.Add('=' * 78)
    $out.Add('  presale-wiper - KẾT QUẢ QUÉT (DRY-RUN, chưa xoá gì)')
    $out.Add('=' * 78)

    $out.Add('')
    $out.Add('Thư mục đã quét:')
    foreach ($root in $summary.Roots) {
        $statusText = switch ($root.Status) {
            'Scanned' { '{0} entry' -f $root.Entries }
            'Blocked' { "BỎ QUA - $($root.Error)" }
            'Missing' { "KHÔNG TỒN TẠI - $($root.Error)" }
            'Invalid' { "KHÔNG HỢP LỆ - $($root.Error)" }
            default { $root.Status }
        }
        $out.Add(('  [{0}] {1}  ->  {2}' -f $root.Status, $root.Path, $statusText))
    }

    if (-not $Quiet) {
        $out.Add('')
        $out.Add(('Đã tìm thấy {0} mục ({1} có thể xoá, {2} được bảo vệ).' -f
                $summary.EntryCount, $summary.DeletableCount, $summary.ProtectedCount))

        $deletable = @($summary.Entries | Where-Object { -not $_.Protected })

        if ($deletable.Count -gt 0) {
            $out.Add('')
            $out.Add('--- Các mục CÓ THỂ xoá (sắp xếp theo dung lượng) ---')
            $rows = @($deletable | Sort-Object -Property SizeBytes -Descending)
            $columns = @(
                @{ Header = 'Loại'; Expression = { $_.Kind } }
                @{ Header = 'Dung lượng'; Expression = { Format-PswSize $_.SizeBytes }; Align = 'Right' }
                @{ Header = 'Đường dẫn (tương đối)'; Expression = { Get-PswDisplayPath -Entry $_ -Root $summary.Roots } }
            )
            foreach ($line in (Format-PswTable -Row $rows -Column $columns -MaxWidth 150)) { $out.Add($line) }
        }

        $protected = @($summary.Entries | Where-Object { $_.Protected })
        if ($protected.Count -gt 0) {
            $out.Add('')
            $out.Add('--- Các mục ĐƯỢC BẢO VỆ / không đề xuất xoá ---')
            $rows = @($protected | Sort-Object -Property SizeBytes -Descending)
            $columns = @(
                @{ Header = 'Loại'; Expression = { $_.Kind } }
                @{ Header = 'Dung lượng'; Expression = { Format-PswSize $_.SizeBytes }; Align = 'Right' }
                @{ Header = 'Đường dẫn (tương đối)'; Expression = { Get-PswDisplayPath -Entry $_ -Root $summary.Roots } }
                @{ Header = 'Lý do'; Expression = { $_.ProtectionReason } }
            )
            foreach ($line in (Format-PswTable -Row $rows -Column $columns -MaxWidth 165)) { $out.Add($line) }
        }
    }

    $out.Add('')
    $out.Add('--- Tổng kết ---')
    $out.Add(('  Project       : {0,5}  ({1})' -f $summary.ByKind['Project'].Count, (Format-PswSize $summary.ByKind['Project'].SizeBytes)))
    $out.Add(('  DevDir        : {0,5}  ({1})' -f $summary.ByKind['DevDir'].Count, (Format-PswSize $summary.ByKind['DevDir'].SizeBytes)))
    $out.Add(('  Secret        : {0,5}  ({1})' -f $summary.ByKind['Secret'].Count, (Format-PswSize $summary.ByKind['Secret'].SizeBytes)))
    $out.Add(('  CodeFile      : {0,5}  ({1})' -f $summary.ByKind['CodeFile'].Count, (Format-PswSize $summary.ByKind['CodeFile'].SizeBytes)))
    $out.Add(('  MediaHeavy    : {0,5}  ({1})' -f $summary.ByKind['MediaHeavy'].Count, (Format-PswSize $summary.ByKind['MediaHeavy'].SizeBytes)))
    $out.Add('')
    $out.Add(('  Tổng cộng      : {0}' -f (Format-PswSize $summary.TotalSizeBytes)))
    $out.Add(('  Có thể giải phóng: {0}' -f (Format-PswSize $summary.DeletableSizeBytes)))
    $out.Add(('  Được bảo vệ    : {0}' -f (Format-PswSize $summary.ProtectedSizeBytes)))
    $out.Add(('  Thời gian      : {0:N2}s  ({1} folder, {2} entry đã duyệt)' -f
            ($summary.Stats.DurationMs / 1000.0), $summary.Stats.FoldersVisited, $summary.Stats.EntriesVisited))

    if ($summary.Stats.LinksSkipped -gt 0) {
        $out.Add(('  Junction/link bỏ qua: {0}' -f $summary.Stats.LinksSkipped))
    }
    if ($summary.Stats.Truncated) {
        $out.Add(('  !! Đã chạm trần duyệt tại: {0}' -f $summary.Stats.TruncatedAt))
    }

    if (-not $NoErrors -and $summary.Errors.Count -gt 0) {
        $out.Add('')
        $out.Add(('--- Cảnh báo / lỗi khi quét ({0}) ---' -f $summary.Errors.Count))
        foreach ($err in @($summary.Errors | Select-Object -First 20)) {
            $out.Add(('  {0}: {1}' -f $err.Path, $err.Error))
        }
        if ($summary.Errors.Count -gt 20) {
            $out.Add(('  ... và {0} mục khác.' -f ($summary.Errors.Count - 20)))
        }
    }

    $out.Add('')
    $out.Add('Đây là DRY-RUN: chưa có file nào bị xoá.')
    $out.Add('')

    foreach ($line in $out) { & $writer $line }
}

function ConvertTo-PswReportObject {
    <#
        .SYNOPSIS
        Chuyển kết quả scan thành object thuần dữ liệu để serialize JSON.

        .DESCRIPTION
        Không đưa scriptblock hay $null không cần thiết vào JSON.
        Giữ tên property ổn định (snake-free camelCase) để tooling đọc được
        mà không phải biết tiếng Việt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$ScanResult,
        [ValidateSet('scan', 'clean', 'verify')]
        [string]$Mode = 'scan'
    )

    $summary = Get-PswScanSummary -ScanResult $ScanResult

    $kindSummary = [ordered]@{}
    foreach ($key in $summary.ByKind.Keys) {
        $kindSummary[$key] = [ordered]@{
            count     = [int]$summary.ByKind[$key].Count
            sizeBytes = [long]$summary.ByKind[$key].SizeBytes
        }
    }

    $entryList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in ($summary.Entries | Sort-Object -Property SizeBytes -Descending)) {
        $entryList.Add([ordered]@{
                path             = $entry.Path
                name             = $entry.Name
                kind             = $entry.Kind
                isDirectory      = [bool]$entry.IsDirectory
                sizeBytes        = [long]$entry.SizeBytes
                depth            = [int]$entry.Depth
                protected        = [bool]$entry.Protected
                reason           = [string]$entry.Reason
                protectionReason = [string]$entry.ProtectionReason
            })
    }

    $errorList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($err in $summary.Errors) {
        $errorList.Add([ordered]@{ path = [string]$err.Path; message = [string]$err.Error })
    }

    $rootList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $summary.Roots) {
        $rootList.Add([ordered]@{
                input   = [string]$root.Input
                path    = [string]$root.Path
                status  = [string]$root.Status
                entries = [int]$root.Entries
                error   = [string]$root.Error
            })
    }

    return [ordered]@{
        tool        = 'presale-wiper'
        version     = (Get-PswVersion)
        mode        = $Mode
        generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        host        = [ordered]@{
            machineName = $env:COMPUTERNAME
            userName    = $env:USERNAME
            psVersion   = $PSVersionTable.PSVersion.ToString()
            osVersion   = [Environment]::OSVersion.VersionString
            elevated    = (Test-PswElevated)
        }
        totals      = [ordered]@{
            entries          = [int]$summary.EntryCount
            deletable        = [int]$summary.DeletableCount
            protected        = [int]$summary.ProtectedCount
            totalSizeBytes   = [long]$summary.TotalSizeBytes
            deletableBytes   = [long]$summary.DeletableSizeBytes
            protectedBytes   = [long]$summary.ProtectedSizeBytes
        }
        byKind      = $kindSummary
        stats       = [ordered]@{
            foldersVisited   = [int]$summary.Stats.FoldersVisited
            filesVisited     = [int]$summary.Stats.FilesVisited
            entriesVisited   = [int]$summary.Stats.EntriesVisited
            linksSkipped     = [int]$summary.Stats.LinksSkipped
            truncated        = [bool]$summary.Stats.Truncated
            durationMs       = [long]$summary.Stats.DurationMs
        }
        roots       = $rootList.ToArray()
        entries     = $entryList.ToArray()
        errors      = $errorList.ToArray()
    }
}

function Write-PswJsonReport {
    <#
        .SYNOPSIS
        Serialize report ra JSON (UTF-8 không BOM cho tooling, hoặc có BOM
        để Notepad cũ đọc được tiếng Việt).

        .PARAMETER Path
        Ghi ra file nếu có; nếu không thì trả về string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]$ScanResult,
        [ValidateSet('scan', 'clean', 'verify')][string]$Mode = 'scan',
        [string]$Path,
        [switch]$Bom,
        [int]$Depth = 8
    )

    $object = ConvertTo-PswReportObject -ScanResult $ScanResult -Mode $Mode
    $json = ConvertTo-Json -InputObject $object -Depth $Depth

    if ([string]::IsNullOrWhiteSpace($Path)) { return $json }

    $full = Get-PswFullPath $Path
    $parent = Get-PswParentPath $full
    if ($null -ne $parent -and -not (Test-PswPathExists $parent)) {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-PswLongPath $parent))
    }

    $encoding = New-Object System.Text.UTF8Encoding($Bom.IsPresent)
    [System.IO.File]::WriteAllText((ConvertTo-PswLongPath $full), $json, $encoding)
    return $full
}

function Get-PswVersion {
    <#
        .SYNOPSIS
        Version của module (lấy từ manifest nếu có, fallback hằng số).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($null -ne $script:PswVersion -and -not [string]::IsNullOrWhiteSpace($script:PswVersion)) {
        return $script:PswVersion
    }
    return '0.1.0'
}
