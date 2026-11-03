#Requires -Version 5.1
<#
    Integration.Scan.Tests.ps1 - Test end-to-end qua CLI trên bộ fixtures.

    Khác với Unit/Walk.Tests.ps1 (tự tạo cây nhỏ), các test này chạy
    `presale-wiper.ps1` như người dùng thật: gọi tiến trình con, đọc
    output/exit code. Nhờ vậy mới bắt được lỗi ở lớp CLI (param binding,
    format output, exit code) mà unit test không thấy.

    Fixtures được sinh bởi tests/New-TestFixture.ps1 - không commit cây
    thật vì lý do long path + folder rỗng (xem TestHelpers.ps1).
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    Import-PswTestModule

    $script:RepoRoot = Get-PswTestRepoRoot
    $script:EntryScript = Join-Path $script:RepoRoot 'presale-wiper.ps1'
    $script:Fixtures = Get-PswTestFixtureRoot

    function Invoke-PswCliProcess {
        <#
            Chạy CLI trong tiến trình con và trả về @{ Output; StdOut; StdErr; ExitCode }.

            Vì sao dùng wrapper script thay vì -File trực tiếp hay -EncodedCommand:
              * -File trực tiếp: stdout bị ghi theo codepage OEM (437/1258) nên
                tiếng Việt thành mojibake, test so khớp text sẽ fail sai.
              * -EncodedCommand: chuỗi base64 dài có thể vượt giới hạn dòng
                lệnh trên một số cấu hình và im lặng không chạy.
              * Wrapper .ps1 (UTF-8 BOM): đặt [Console]::OutputEncoding = UTF8
                ngay đầu, truyền tham số qua mảng literal nên không có vấn đề
                quote, và dễ đọc khi cần debug.
        #>
        param([string[]]$Arguments)

        $workDir = Get-PswTestWorkDir
        if (-not (Test-Path -LiteralPath $workDir)) {
            [void][System.IO.Directory]::CreateDirectory($workDir)
        }
        $wrapperPath = Join-Path $workDir 'invoke-cli-wrapper.ps1'

        # Sinh token cho dòng lệnh:
        #   * Tham số BẮT ĐẦU BẰNG '-' phải để trần. Nếu quote ('-NoLog')
        #     PowerShell coi đó là chuỗi positional chứ không phải tên tham
        #     số -> "A positional parameter cannot be found".
        #   * Giá trị thường phải quote để path có dấu cách/Unicode vẫn ok.
        $literalArgs = foreach ($argument in $Arguments) {
            $text = [string]$argument
            if ($text -match '^-[A-Za-z]') {
                # Tên tham số: chỉ cho phép ký tự an toàn, không quote.
                if ($text -match '^-[A-Za-z][A-Za-z0-9]*$') { $text }
                else { "'" + $text.Replace("'", "''") + "'" }
            } else {
                "'" + $text.Replace("'", "''") + "'"
            }
        }
        $cliScript = $script:EntryScript.Replace("'", "''")

        # Vì sao có '2>&1 | Out-Host':
        #   Output của script con đi vào pipeline của wrapper dưới dạng object.
        #   Khi wrapper gọi 'exit', tiến trình kết thúc và phần object còn nằm
        #   trong pipeline có thể chưa được ghi ra stdout -> test thấy chuỗi
        #   rỗng dù lệnh chạy đúng. Out-Host buộc ghi ngay ra host stream
        #   (chính là stdout khi bị redirect), giống hệt cách Write-Host đã
        #   hoạt động tốt.
        $invokeLine = "& '$cliScript' $($literalArgs -join ' ') 2>&1 | Out-Host"

        # Dùng here-string NHÁY ĐƠN (@'...'@) để nội dung được giữ nguyên
        # 100%: không biến nào bị nội suy lúc sinh file. Mọi giá trị động
        # được thay qua placeholder __INVOKE_LINE__.
        $wrapperTemplate = @'
#Requires -Version 5.1
# Wrapper tự sinh bởi Integration.Scan.Tests.ps1 - không sửa tay.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

__INVOKE_LINE__

# Chuyển tiếp mã thoát: CLI đặt [Environment]::ExitCode (để không cắt ngang
# pipeline và làm mất output). Wrapper chạy top-level bằng -File, nên lệnh
# thoát ở đây là cách duy nhất để tiến trình con trả đúng mã cho caller.
exit [int][Environment]::ExitCode
'@
        $wrapper = $wrapperTemplate.Replace('__INVOKE_LINE__', $invokeLine)
        [System.IO.File]::WriteAllText($wrapperPath, $wrapper, (New-Object System.Text.UTF8Encoding($true)))

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command powershell.exe).Source
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapperPath`""

        $process = [System.Diagnostics.Process]::Start($psi)

        # Đọc stdout và stderr SONG SONG. Đọc tuần tự sẽ deadlock khi tiến
        # trình con ghi đủ nhiều vào pipe còn lại để đầy buffer của OS.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit(180000)) {
            try { $process.Kill() } catch { }
            return @{
                Output   = 'TIMEOUT: tiến trình con không kết thúc sau 180 giây.'
                StdOut   = ''
                StdErr   = 'TIMEOUT'
                ExitCode = 124
            }
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        return @{
            Output   = ($stdout + $stderr)
            StdOut   = $stdout
            StdErr   = $stderr
            ExitCode = $process.ExitCode
        }
    }
}

Describe 'CLI scan - exit code và output cơ bản' {

    It 'scan fixtures tra exit code 0' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-NoLog', '-NoErrors')
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'output có tiêu đề dry-run' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-NoLog')
        $result.StdOut | Should -BeLike '*DRY-RUN*'
    }

    It 'output liệt kê project_node' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-NoLog')
        $result.StdOut | Should -BeLike '*project_node*'
    }

    It 'output liệt kê node_modules là DevDir' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-NoLog')
        $result.StdOut | Should -BeLike '*DevDir*'
        $result.StdOut | Should -BeLike '*node_modules*'
    }

    It 'không in mục đã protected vào bảng có thể xoá' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-NoLog')
        $result.StdOut | Should -BeLike '*ĐƯỢC BẢO VỆ*'
        $result.StdOut | Should -BeLike '*mixed_with_media*'
    }

    It 'project_rust được phát hiện' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-NoLog')
        $result.StdOut | Should -BeLike '*project_rust*'
    }

    It 'project_python được phát hiện' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-NoLog')
        $result.StdOut | Should -BeLike '*project_python*'
    }
}

Describe 'CLI scan - tuỳ chọn' {

    It '-Json tra JSON hợp lệ ra stdout' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-Json', '-NoLog')

        $result.ExitCode | Should -Be 0 -Because $result.Output
        { $result.StdOut | ConvertFrom-Json } | Should -Not -Throw

        $json = $result.StdOut | ConvertFrom-Json
        $json.tool | Should -Be 'presale-wiper'
        $json.mode | Should -Be 'scan'
        $json.totals.entries | Should -BeGreaterThan 0
        $json.entries | Should -Not -BeNullOrEmpty
    }

    It '-Json có đủ thông tin cho tooling' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-Json', '-NoLog')
        $json = $result.StdOut | ConvertFrom-Json

        $json.PSObject.Properties.Name | Should -Contain 'tool'
        $json.PSObject.Properties.Name | Should -Contain 'version'
        $json.PSObject.Properties.Name | Should -Contain 'generatedAt'
        $json.PSObject.Properties.Name | Should -Contain 'host'
        $json.PSObject.Properties.Name | Should -Contain 'totals'
        $json.PSObject.Properties.Name | Should -Contain 'byKind'
        $json.PSObject.Properties.Name | Should -Contain 'stats'
        $json.PSObject.Properties.Name | Should -Contain 'roots'
        $json.PSObject.Properties.Name | Should -Contain 'entries'
        $json.PSObject.Properties.Name | Should -Contain 'errors'

        # Mỗi entry đủ trường
        $entry = @($json.entries)[0]
        foreach ($field in @('path', 'name', 'kind', 'isDirectory', 'sizeBytes', 'protected')) {
            $entry.PSObject.Properties.Name | Should -Contain $field
        }
    }

    It '-JsonPath ghi file và không in JSON ra stdout' {
        $outFile = Join-Path (Get-PswTestWorkDir) 'report.json'
        $parent = Split-Path $outFile -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            [void][System.IO.Directory]::CreateDirectory($parent)
        }
        if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }

        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-JsonPath', $outFile, '-NoLog')

        $result.ExitCode | Should -Be 0 -Because $result.Output
        (Test-Path -LiteralPath $outFile) | Should -BeTrue

        $json = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
        $json.totals.entries | Should -BeGreaterThan 0

        Remove-Item -LiteralPath $outFile -Force
    }

    It '-Quiet chỉ in tổng kết' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-Quiet', '-NoLog')
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.StdOut | Should -BeLike '*Tổng kết*'
        $result.StdOut | Should -Not -BeLike '*CÓ THỂ xoá*'
    }

    It '-MinSize lọc mục nhỏ' {
        # Chỉ còn project_rust (150 KB) sau khi lọc >= 100KB
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-MinSize', '100KB', '-Json', '-NoLog')
        $result.ExitCode | Should -Be 0 -Because $result.Output

        $json = $result.StdOut | ConvertFrom-Json
        foreach ($entry in $json.entries) {
            $entry.sizeBytes | Should -BeGreaterOrEqual 102400
        }
        @($json.entries | Where-Object { $_.name -eq 'project_rust' }) | Should -HaveCount 1
    }

    It '-MinSize với giá trị sai tra exit code 2' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-MinSize', 'khong-phai-so', '-NoLog')
        $result.ExitCode | Should -Be 2
        $result.StdOut | Should -BeLike '*không hợp lệ*'
    }

    It '-Exclude loại trừ project_python' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-Exclude', 'project_python', '-Json', '-NoLog')
        $json = $result.StdOut | ConvertFrom-Json
        @($json.entries | Where-Object { $_.name -eq 'project_python' }) | Should -HaveCount 0
    }

    It '-NoSize khiến sizeBytes = 0' {
        $result = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-NoSize', '-Json', '-NoLog')
        $json = $result.StdOut | ConvertFrom-Json
        foreach ($entry in $json.entries) {
            $entry.sizeBytes | Should -Be 0
        }
    }
}

Describe 'CLI - lệnh khác' {

    It 'version in ra số phiên bản' {
        $result = Invoke-PswCliProcess -Arguments @('version')
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -BeLike '*presale-wiper*'
        $result.StdOut | Should -Match '\d+\.\d+\.\d+'
    }

    It 'help in ra hướng dẫn' {
        $result = Invoke-PswCliProcess -Arguments @('help')
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -BeLike '*CÁCH DÙNG*'
        $result.StdOut | Should -BeLike '*scan*'
        $result.StdOut | Should -BeLike '*verify*'
    }

    It '-Help cũng in hướng dẫn' {
        $result = Invoke-PswCliProcess -Arguments @('scan', '-Help')
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -BeLike '*CÁCH DÙNG*'
    }

    It 'lệnh không hợp lệ tra exit code 2' {
        $result = Invoke-PswCliProcess -Arguments @('khong_phai_lenh')
        $result.ExitCode | Should -Be 2
        $result.StdOut | Should -BeLike '*không hợp lệ*'
    }

    It 'clean bị từ chối ở bản Phase 1 (exit code 2)' {
        $result = Invoke-PswCliProcess -Arguments @('clean', '-NoLog')
        $result.ExitCode | Should -Be 2
        $result.StdOut | Should -BeLike '*chưa được bật*'
    }

    It 'report thiếu -FromLog tra exit code 2' {
        $result = Invoke-PswCliProcess -Arguments @('report')
        $result.ExitCode | Should -Be 2
        $result.StdOut | Should -BeLike '*FromLog*'
    }

    It 'report từ log thật hoạt động' {
        $logPath = Join-Path (Get-PswTestWorkDir) 'integration.log'
        $parent = Split-Path $logPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            [void][System.IO.Directory]::CreateDirectory($parent)
        }
        if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }

        $scan = Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-Log', $logPath, '-Quiet')
        $scan.ExitCode | Should -Be 0 -Because $scan.Output
        (Test-Path -LiteralPath $logPath) | Should -BeTrue

        $report = Invoke-PswCliProcess -Arguments @('report', '-FromLog', $logPath)
        $report.ExitCode | Should -Be 0 -Because $report.Output
        $report.StdOut | Should -BeLike '*REPORT*'
        $report.StdOut | Should -BeLike '*SCAN*'

        Remove-Item -LiteralPath $logPath -Force
    }

    It 'report -Json tra JSON hợp lệ' {
        $logPath = Join-Path (Get-PswTestWorkDir) 'integration-json.log'
        $parent = Split-Path $logPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            [void][System.IO.Directory]::CreateDirectory($parent)
        }
        if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }

        Invoke-PswCliProcess -Arguments @('scan', $script:Fixtures, '-Log', $logPath, '-Quiet') | Out-Null
        $report = Invoke-PswCliProcess -Arguments @('report', '-FromLog', $logPath, '-Json')

        $report.ExitCode | Should -Be 0 -Because $report.Output
        { $report.StdOut | ConvertFrom-Json } | Should -Not -Throw
        $json = $report.StdOut | ConvertFrom-Json
        $json.mode | Should -Be 'report'
        $json.totals.lines | Should -BeGreaterThan 0

        Remove-Item -LiteralPath $logPath -Force
    }

    It 'verify trên fixtures báo còn mục chưa dọn' {
        $result = Invoke-PswCliProcess -Arguments @('verify', $script:Fixtures, '-NoLog')
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.StdOut | Should -BeLike '*VERIFY*'
        $result.StdOut | Should -BeLike '*chưa được dọn*'
    }

    It 'verify -Json có trường clean' {
        $result = Invoke-PswCliProcess -Arguments @('verify', $script:Fixtures, '-Json', '-NoLog')
        $json = $result.StdOut | ConvertFrom-Json
        $json.mode | Should -Be 'verify'
        $json.PSObject.Properties.Name | Should -Contain 'clean'
        $json.clean | Should -BeFalse
        $json.remaining.count | Should -BeGreaterThan 0
    }
}

Describe 'CLI - an toàn ở mức tiến trình' {

    It 'không xoá gì sau khi chạy scan' {
        $sandbox = Join-Path (Get-PswTestWorkDir) 'readonly-check'
        New-PswTestTree -Root $sandbox -Tree @{
            'proj/package.json' = '{}'
            'proj/a.js'         = 'x'
            'proj/b.py'         = 'x'
        }

        $before = @(Get-ChildItem -LiteralPath $sandbox -Recurse -File).Count
        $result = Invoke-PswCliProcess -Arguments @('scan', $sandbox, '-NoLog', '-Quiet')
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $after = @(Get-ChildItem -LiteralPath $sandbox -Recurse -File).Count

        $after | Should -Be $before
        Remove-PswTestTree -Path $sandbox
    }

    It 'từ chối quét gốc ổ đĩa kèm thông báo rõ' {
        $result = Invoke-PswCliProcess -Arguments @('scan', 'C:\', '-NoLog')
        $result.StdOut | Should -BeLike '*Từ chối*'
    }

    It 'root không tồn tại tra exit code 1 và vẫn in báo cáo' {
        $result = Invoke-PswCliProcess -Arguments @('scan', 'C:\khong_ton_tai_xyz_123', '-NoLog')
        $result.ExitCode | Should -Be 1
        $result.StdOut | Should -BeLike '*KHÔNG TỒN TẠI*'
    }
}
