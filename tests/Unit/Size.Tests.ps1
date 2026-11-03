#Requires -Version 5.1
<#
    Size.Tests.ps1 - Test đo dung lượng và format.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    Import-PswTestModule
}

Describe 'Format-PswSize' {

    It '<Bytes> byte -> <Expected>' -ForEach @(
        @{ Bytes = 0; Expected = '0 B' }
        @{ Bytes = 37; Expected = '37 B' }
        @{ Bytes = 1023; Expected = '1023 B' }
        @{ Bytes = 1024; Expected = '1.0 KB' }
        @{ Bytes = 1536; Expected = '1.5 KB' }
        @{ Bytes = 1048576; Expected = '1.0 MB' }
        @{ Bytes = 1073741824; Expected = '1.0 GB' }
        @{ Bytes = 1610612736; Expected = '1.5 GB' }
        @{ Bytes = 1099511627776; Expected = '1.0 TB' }
    ) {
        Format-PswSize -Bytes $Bytes | Should -Be $Expected
    }

    It 'dùng dấu chấm thập phân (không phụ thuộc locale)' {
        Format-PswSize -Bytes 1536 | Should -BeLike '*.*'
        Format-PswSize -Bytes 1536 | Should -Not -BeLike '*,*'
    }

    It 'trả về 0 B cho số âm' {
        Format-PswSize -Bytes -100 | Should -Be '0 B'
    }

    It 'tôn trọng -Decimals' {
        Format-PswSize -Bytes 1536 -Decimals 2 | Should -Be '1.50 KB'
        Format-PswSize -Bytes 1536 -Decimals 0 | Should -Be '2 KB'
    }

    It 'nhận input từ pipeline' {
        $result = @(1024, 2048) | ConvertTo-PswSizeText
        $result | Should -HaveCount 2
        $result[0] | Should -Be '1.0 KB'
    }
}

Describe 'Measure-PswDirectorySize' {

    BeforeEach {
        Reset-PswSizeCache
    }

    It 'trả về 0 cho folder không tồn tại' {
        Measure-PswDirectorySize -Path (Join-Path $TestDrive 'khong_ton_tai') | Should -Be 0
    }

    It 'trả về 0 cho folder rỗng' {
        $empty = Join-Path $TestDrive 'empty'
        [void][System.IO.Directory]::CreateDirectory($empty)
        Measure-PswDirectorySize -Path $empty | Should -Be 0
    }

    It 'cộng đúng kích thước file trực tiếp' {
        $root = Join-Path $TestDrive 'direct'
        New-PswTestTree -Root $root -Tree @{
            'a.txt' = ('x' * 100)
            'b.txt' = ('x' * 200)
        }
        Measure-PswDirectorySize -Path $root | Should -Be 300
    }

    It 'cộng cả file trong folder con nhiều cấp' {
        $root = Join-Path $TestDrive 'nested'
        New-PswTestTree -Root $root -Tree @{
            'a.txt'           = ('x' * 10)
            'l1/b.txt'        = ('x' * 20)
            'l1/l2/c.txt'     = ('x' * 30)
            'l1/l2/l3/d.txt'  = ('x' * 40)
        }
        Measure-PswDirectorySize -Path $root | Should -Be 100
    }

    It 'kết quả được cache: gọi lần 2 không đọc lại đĩa' {
        $root = Join-Path $TestDrive 'cached'
        New-PswTestTree -Root $root -Tree @{ 'a.txt' = ('x' * 50) }

        $first = Measure-PswDirectorySize -Path $root
        $first | Should -Be 50

        # Thêm file mới nhưng KHÔNG xoá cache -> vẫn trả giá trị cũ
        [System.IO.File]::WriteAllText((Join-Path $root 'b.txt'), ('x' * 50))
        (Measure-PswDirectorySize -Path $root) | Should -Be 50

        # -NoCache -> đọc lại và thấy file mới
        (Measure-PswDirectorySize -Path $root -NoCache) | Should -Be 100
    }

    It 'không đi theo junction (tránh loop và đếm nhầm)' {
        $target = Join-Path $TestDrive 'jtarget'
        New-PswTestTree -Root $target -Tree @{ 'big.txt' = ('x' * 1000) }

        $root = Join-Path $TestDrive 'jroot'
        New-PswTestTree -Root $root -Tree @{ 'small.txt' = ('x' * 10) }
        $link = Join-Path $root 'link'
        $null = & cmd /c "mklink /J `"$link`" `"$target`"" 2>&1

        if (-not (Test-Path -LiteralPath $link)) {
            Set-ItResult -Skipped -Because 'không tạo được junction'
            return
        }

        # Chỉ đếm small.txt, KHÔNG đếm big.txt phía sau junction
        Measure-PswDirectorySize -Path $root | Should -Be 10
    }

    It 'đo được folder có path dài hơn 260 ký tự' {
        $deep = Join-Path $TestDrive 'lp'
        1..8 | ForEach-Object { $deep = Join-Path $deep ('y' * 30) }
        [void][System.IO.Directory]::CreateDirectory('\\?\' + $deep)
        [System.IO.File]::WriteAllText('\\?\' + (Join-Path $deep 'deep.bin'), ('x' * 123))

        $deep.Length | Should -BeGreaterThan 260
        Measure-PswDirectorySize -Path $deep | Should -Be 123
    }

    It 'tôn trọng -MaxEntries (không treo với cây quá lớn)' {
        $root = Join-Path $TestDrive 'many'
        [void][System.IO.Directory]::CreateDirectory($root)
        1..50 | ForEach-Object {
            [System.IO.File]::WriteAllText((Join-Path $root "f$_.txt"), 'x')
        }

        # Với giới hạn nhỏ, kết quả phải <= tổng thật và không ném lỗi
        $limited = Measure-PswDirectorySize -Path $root -MaxEntries 5 -NoCache
        $limited | Should -BeLessOrEqual 50
        $limited | Should -BeGreaterOrEqual 0
    }
}

Describe 'Measure-PswEntrySize' {

    It 'file: dùng Length khi được truyền vào (không I/O)' {
        Measure-PswEntrySize -Path 'C:\khong\ton\tai.txt' -Length 999 | Should -Be 999
    }

    It 'file: đọc Length từ đĩa khi không truyền' {
        $file = Join-Path $TestDrive 'sized.txt'
        [System.IO.File]::WriteAllText($file, ('x' * 321))
        Measure-PswEntrySize -Path $file | Should -Be 321
    }

    It 'file không tồn tại -> 0' {
        Measure-PswEntrySize -Path (Join-Path $TestDrive 'nope.txt') | Should -Be 0
    }

    It 'folder: đo đệ quy' {
        $root = Join-Path $TestDrive 'dirsize'
        New-PswTestTree -Root $root -Tree @{
            'a.txt'     = ('x' * 10)
            'sub/b.txt' = ('x' * 20)
        }
        Reset-PswSizeCache
        Measure-PswEntrySize -Path $root -IsDirectory | Should -Be 30
    }
}

Describe 'Reset-PswSizeCache' {

    It 'xoá cache để lần đo sau đọc lại đĩa' {
        $root = Join-Path $TestDrive 'resetcache'
        New-PswTestTree -Root $root -Tree @{ 'a.txt' = ('x' * 10) }

        Measure-PswDirectorySize -Path $root | Should -Be 10
        [System.IO.File]::WriteAllText((Join-Path $root 'b.txt'), ('x' * 10))
        Measure-PswDirectorySize -Path $root | Should -Be 10

        Reset-PswSizeCache
        Measure-PswDirectorySize -Path $root | Should -Be 20
    }
}
