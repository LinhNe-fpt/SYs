#Requires -Version 5.1
<#
    Log.Tests.ps1 - Test ghi log, rotate, và đọc lại.

    Log của tool xoá dữ liệu là bằng chứng duy nhất về việc đã xảy ra gì,
    nên phần này cần test kỹ: rotate đúng, không mất dòng, TSV không vỡ khi
    path có dấu tab/xuống dòng (dù Windows không cho phép, nhưng tên lạ vẫn
    có thể xuất hiện qua API).
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    Import-PswTestModule

    $script:LogDir = Join-Path (Get-PswTestWorkDir) 'log'
    if (Test-Path -LiteralPath $script:LogDir) {
        Remove-PswTestTree -Path $script:LogDir
    }
    [void][System.IO.Directory]::CreateDirectory($script:LogDir)
}

Describe 'log' {

    AfterEach {
        [void](Close-PswLogSession)
    }

    AfterAll {
        [void](Close-PswLogSession)
        if (Test-Path -LiteralPath $script:LogDir) {
            Remove-PswTestTree -Path $script:LogDir
        }
    }

    Describe 'New-PswLogSession' {

        It 'tạo file log mới với header' {
            $path = Join-Path $script:LogDir 'new.log'
            $session = New-PswLogSession -Path $path

            $session | Should -Not -BeNullOrEmpty
            $session.Path | Should -Be $path
            (Test-Path -LiteralPath $path) | Should -BeTrue

            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -BeLike '*presale-wiper log*'
            $content | Should -BeLike '*timestamp*'
        }

        It 'tạo folder cha nếu chưa có' {
            $path = Join-Path $script:LogDir 'deep\nested\dir\app.log'
            [void](New-PswLogSession -Path $path)
            (Test-Path -LiteralPath $path) | Should -BeTrue
        }

        It 'tên mặc định khi truyền vào là folder' {
            $dir = Join-Path $script:LogDir 'asfolder'
            [void][System.IO.Directory]::CreateDirectory($dir)
            $session = New-PswLogSession -Path $dir

            $session.Path | Should -BeLike "$dir\*presale-wiper.log"
        }

        It '-Disabled trả về $null và không tạo file' {
            $path = Join-Path $script:LogDir 'disabled.log'
            $session = New-PswLogSession -Path $path -Disabled
            $session | Should -BeNullOrEmpty
            (Test-Path -LiteralPath $path) | Should -BeFalse
        }

        It 'không ghi header lần thứ hai khi append vào file đã có' {
            $path = Join-Path $script:LogDir 'append.log'
            [void](New-PswLogSession -Path $path)
            Add-PswLogEntry -Message 'a'
            [void](Close-PswLogSession)

            [void](New-PswLogSession -Path $path)
            Add-PswLogEntry -Message 'b'
            [void](Close-PswLogSession)

            $headers = @(Get-Content -LiteralPath $path | Where-Object { $_ -like '# presale-wiper log*' })
            $headers | Should -HaveCount 1
        }
    }

    Describe 'Add-PswLogEntry' {

        It 'ghi đúng số trường TSV' {
            $path = Join-Path $script:LogDir 'fields.log'
            [void](New-PswLogSession -Path $path)
            Add-PswLogEntry -Message 'test' -Level 'INFO' -Action 'SCAN' -Kind 'Project' -SizeBytes 123 -Path 'C:\a'

            $lines = @(Get-Content -LiteralPath $path | Where-Object { -not $_.StartsWith('#') })
            $lines | Should -HaveCount 2   # header cột + 1 dòng dữ liệu

            $dataLine = $lines[1]
            $parts = $dataLine.Split("`t")
            $parts.Count | Should -Be 7
            $parts[1] | Should -Be 'INFO'
            $parts[2] | Should -Be 'SCAN'
            $parts[3] | Should -Be 'Project'
            $parts[4] | Should -Be '123'
            $parts[5] | Should -Be 'C:\a'
        }

        It 'không làm gì khi chưa mở session' {
            [void](Close-PswLogSession)
            { Add-PswLogEntry -Message 'no session' } | Should -Not -Throw
        }

        It 'thay tab và xuống dòng trong Detail bằng dấu cách (giữ TSV nguyên vẹn)' {
            $path = Join-Path $script:LogDir 'sanitize.log'
            [void](New-PswLogSession -Path $path)
            Add-PswLogEntry -Message 'x' -Detail "line1`r`nline2`tline3"

            $dataLines = @(Get-Content -LiteralPath $path | Where-Object { -not $_.StartsWith('#') })
            $fields = $dataLines[1].Split("`t")
            $fields.Count | Should -Be 7 -Because 'dấu tab trong Detail không được tạo thêm cột'
            $fields[6] | Should -BeLike '*line1*line2*line3*'
        }

        It 'cắt Detail quá dài' {
            $path = Join-Path $script:LogDir 'truncate.log'
            [void](New-PswLogSession -Path $path)
            Add-PswLogEntry -Message 'x' -Detail ('y' * 1000)

            $dataLines = @(Get-Content -LiteralPath $path | Where-Object { -not $_.StartsWith('#') })
            $fields = $dataLines[1].Split("`t")
            $fields[6].Length | Should -BeLessThan 500
            $fields[6] | Should -BeLike '*...'
        }

        It 'đếm đúng EntryCount trên session' {
            $path = Join-Path $script:LogDir 'count.log'
            $session = New-PswLogSession -Path $path
            Add-PswLogEntry -Message 'a'
            Add-PswLogEntry -Message 'b'
            Add-PswLogEntry -Message 'c'

            (Get-PswLogSession).EntryCount | Should -Be 3
        }
    }

    Describe 'Invoke-PswLogRotation' {

        It 'không rotate file nhỏ' {
            $path = Join-Path $script:LogDir 'small.log'
            Set-Content -LiteralPath $path -Value 'small' -Encoding UTF8
            Invoke-PswLogRotation -Path $path -MaxBytes 1MB | Should -BeFalse
            (Test-Path -LiteralPath $path) | Should -BeTrue
        }

        It 'rotate file vượt ngưỡng thành .1.log' {
            $path = Join-Path $script:LogDir 'rotate.log'
            Set-Content -LiteralPath $path -Value ('x' * 2000) -Encoding UTF8

            Invoke-PswLogRotation -Path $path -MaxBytes 1000 | Should -BeTrue
            (Test-Path -LiteralPath $path) | Should -BeFalse

            $rotatedPath = Join-Path $script:LogDir 'rotate.1.log'
            (Test-Path -LiteralPath $rotatedPath) | Should -BeTrue
        }

        It 'đẩy bản cũ lên số cao hơn (.1 -> .2)' {
            $path = Join-Path $script:LogDir 'chain.log'
            Set-Content -LiteralPath (Join-Path $script:LogDir 'chain.1.log') -Value 'v1' -Encoding UTF8
            Set-Content -LiteralPath $path -Value ('x' * 2000) -Encoding UTF8

            Invoke-PswLogRotation -Path $path -MaxBytes 1000 | Should -BeTrue

            (Get-Content -LiteralPath (Join-Path $script:LogDir 'chain.2.log') -Raw).Trim() | Should -Be 'v1'
            (Get-Content -LiteralPath (Join-Path $script:LogDir 'chain.1.log') -Raw).Trim().Length | Should -BeGreaterThan 1000
        }

        It 'xoá bản cũ nhất khi vượt -Keep' {
            $path = Join-Path $script:LogDir 'keep.log'
            3..1 | ForEach-Object {
                Set-Content -LiteralPath (Join-Path $script:LogDir "keep.$_.log") -Value "v$_" -Encoding UTF8
            }
            Set-Content -LiteralPath $path -Value ('x' * 2000) -Encoding UTF8

            Invoke-PswLogRotation -Path $path -MaxBytes 1000 -Keep 2 | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $script:LogDir 'keep.3.log')) | Should -BeFalse
        }
    }

    Describe 'Read-PswLogFile' {

        It 'đọc lại đúng các dòng đã ghi' {
            $path = Join-Path $script:LogDir 'read.log'
            [void](New-PswLogSession -Path $path)
            Add-PswLogEntry -Message 'x' -Action 'SCAN' -Kind 'Project' -SizeBytes 100 -Path 'C:\p1'
            Add-PswLogEntry -Message 'y' -Action 'DELETE' -Kind 'DevDir' -SizeBytes 200 -Path 'C:\p2'
            [void](Close-PswLogSession)

            $records = Read-PswLogFile -Path $path
            @($records) | Should -HaveCount 2
            @($records)[0].Action | Should -Be 'SCAN'
            @($records)[0].SizeBytes | Should -Be 100
            @($records)[1].Path | Should -Be 'C:\p2'
        }

        It '-Tail chỉ trả về N dòng cuối' {
            $path = Join-Path $script:LogDir 'tail.log'
            [void](New-PswLogSession -Path $path)
            1..10 | ForEach-Object { Add-PswLogEntry -Message "m$_" -Path "C:\p$_" }
            [void](Close-PswLogSession)

            $records = Read-PswLogFile -Path $path -Tail 3
            @($records) | Should -HaveCount 3
            @($records)[2].Path | Should -Be 'C:\p10'
        }

        It 'bỏ qua dòng comment và header' {
            $path = Join-Path $script:LogDir 'comment.log'
            [void](New-PswLogSession -Path $path)
            Add-PswLogEntry -Message 'x'
            [void](Close-PswLogSession)

            $records = Read-PswLogFile -Path $path
            @($records) | Should -HaveCount 1
        }

    It 'bỏ qua dòng hỏng thay vì ném lỗi' {
        $path = Join-Path $script:LogDir 'broken.log'
        $tab = "`t"
        $lines = @(
            ('timestamp' + $tab + 'level' + $tab + 'action' + $tab + 'kind' + $tab + 'sizeBytes' + $tab + 'path' + $tab + 'detail')
            ('2026-01-01 00:00:00' + $tab + 'INFO' + $tab + 'SCAN' + $tab + 'Project' + $tab + '100' + $tab + 'C:\ok' + $tab + 'fine')
            'random garbage line without tabs'
            ('2026-01-01 00:00:01' + $tab + 'INFO' + $tab + 'SCAN' + $tab + 'Project' + $tab + 'notanumber' + $tab + 'C:\x' + $tab + 'bad size')
        )
        [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))

        $records = Read-PswLogFile -Path $path
        @($records) | Should -HaveCount 2
    }

        It 'throw khi file không tồn tại' {
            { Read-PswLogFile -Path (Join-Path $script:LogDir 'nope.log') } | Should -Throw
        }

        It 'giữ nguyên path Unicode' {
            $path = Join-Path $script:LogDir 'unicode.log'
            [void](New-PswLogSession -Path $path)
            Add-PswLogEntry -Message 'x' -Path 'C:\Users\Nguyễn Văn A\dự án\项目'
            [void](Close-PswLogSession)

            $records = Read-PswLogFile -Path $path
            @($records)[0].Path | Should -Be 'C:\Users\Nguyễn Văn A\dự án\项目'
        }
    }

    Describe 'Test-PswContainerPath' {

        It 'true với folder' {
            $dir = Join-Path $script:LogDir 'iscontainer'
            [void][System.IO.Directory]::CreateDirectory($dir)
            Test-PswContainerPath $dir | Should -BeTrue
        }

        It 'false với file' {
            $file = Join-Path $script:LogDir 'isfile.txt'
            Set-Content -LiteralPath $file -Value 'x'
            Test-PswContainerPath $file | Should -BeFalse
        }

        It 'false với path không tồn tại' {
            Test-PswContainerPath (Join-Path $script:LogDir 'nope') | Should -BeFalse
        }
    }
}
