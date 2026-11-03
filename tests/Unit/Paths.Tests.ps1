#Requires -Version 5.1
<#
    Paths.Tests.ps1 - Test tiện ích đường dẫn và long path.

    Đây là lớp dễ sai nhất trên Windows: MAX_PATH, UNC, dấu '\' cuối,
    ranh giới component ('C:\foo-bar' không nằm dưới 'C:\foo').
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    Import-PswTestModule
}

Describe 'ConvertTo-PswLongPath' {

    It 'thêm prefix cho đường dẫn ổ đĩa tuyệt đối' {
        ConvertTo-PswLongPath 'C:\a\b' | Should -Be '\\?\C:\a\b'
    }

    It 'idempotent - không thêm prefix hai lần' {
        $once = ConvertTo-PswLongPath 'C:\a\b'
        ConvertTo-PswLongPath $once | Should -Be $once
    }

    It 'giữ nguyên prefix của đường dẫn đã có' {
        ConvertTo-PswLongPath '\\?\C:\very\long' | Should -Be '\\?\C:\very\long'
    }

    It 'chuyển UNC sang \\?\UNC\' {
        ConvertTo-PswLongPath '\\server\share\dir' | Should -Be '\\?\UNC\server\share\dir'
    }

    It 'đường dẫn UNC đã có prefix thì giữ nguyên' {
        ConvertTo-PswLongPath '\\?\UNC\server\share\dir' | Should -Be '\\?\UNC\server\share\dir'
    }

    It 'bỏ dấu \ cuối (trừ gốc ổ)' {
        ConvertTo-PswLongPath 'C:\a\b\' | Should -Be '\\?\C:\a\b'
        ConvertTo-PswLongPath 'C:\' | Should -Be '\\?\C:\'
    }

    It 'giữ nguyên path có dấu cách và Unicode' {
        $result = ConvertTo-PswLongPath 'C:\Users\Nguyễn Văn A\dự án'
        $result | Should -Be '\\?\C:\Users\Nguyễn Văn A\dự án'
    }

    It 'trả về nguyên trạng với chuỗi rỗng' {
        ConvertTo-PswLongPath '' | Should -Be ''
    }

    It 'xu ly duoc path dai hon 260 ky tu' {
        $deep = 'C:\' + ((1..30 | ForEach-Object { 'a' * 10 }) -join '\')
        $result = ConvertTo-PswLongPath $deep
        $result.Length | Should -BeGreaterThan 260
        $result.StartsWith('\\?\') | Should -BeTrue
    }
}

Describe 'ConvertFrom-PswLongPath' {

    It 'bỏ prefix ổ đĩa' {
        ConvertFrom-PswLongPath '\\?\C:\a\b' | Should -Be 'C:\a\b'
    }

    It 'bỏ prefix UNC và trả về \\' {
        ConvertFrom-PswLongPath '\\?\UNC\server\share' | Should -Be '\\server\share'
    }

    It 'không đổi path thường' {
        ConvertFrom-PswLongPath 'C:\a\b' | Should -Be 'C:\a\b'
    }

    It 'khứ hồi (roundtrip) giữ nguyên giá trị' {
        $original = 'C:\Users\Admin\Documents\Projects\app'
        ConvertFrom-PswLongPath (ConvertTo-PswLongPath $original) | Should -Be $original
    }
}

Describe 'Get-PswFullPath' {

    It 'trả về path tuyệt đối từ path tương đối' {
        $result = Get-PswFullPath '.\src'
        [System.IO.Path]::IsPathRooted($result) | Should -BeTrue
    }

    It 'giải quyết . và ..' {
        $result = Get-PswFullPath 'C:\a\b\..\c'
        $result | Should -Be 'C:\a\c'
    }

    It 'bỏ dấu \ cuối' {
        Get-PswFullPath 'C:\a\b\' | Should -Be 'C:\a\b'
    }

    It 'giữ nguyên gốc ổ đĩa có dấu \' {
        Get-PswFullPath 'C:\' | Should -Be 'C:\'
    }

    It 'mở rộng biến môi trường' {
        $result = Get-PswFullPath '%SystemDrive%\Windows'
        $result | Should -Not -BeLike '*%*'
        $result | Should -BeLike '*\Windows'
    }

    It 'trả về $null với chuỗi rỗng' {
        Get-PswFullPath '' | Should -BeNullOrEmpty
    }

    It 'trả về $null với path chứa ký tự không hợp lệ' {
        Get-PswFullPath 'C:\a<b>c' | Should -BeNullOrEmpty
    }

    It 'chấp nhận path đã có prefix long-path' {
        (Get-PswFullPath '\\?\C:\a\b') | Should -Be 'C:\a\b'
    }
}

Describe 'Test-PswSamePath' {

    It 'coi hoa/thường là như nhau' {
        Test-PswSamePath 'C:\Foo\Bar' 'c:\foo\bar' | Should -BeTrue
    }

    It 'coi dấu \ cuối là như nhau' {
        Test-PswSamePath 'C:\Foo\' 'C:\Foo' | Should -BeTrue
    }

    It 'phân biệt được path khác nhau' {
        Test-PswSamePath 'C:\Foo' 'C:\Bar' | Should -BeFalse
    }

    It 'trả về false khi một bên không hợp lệ' {
        Test-PswSamePath -Path 'C:\Foo' -Other '' | Should -BeFalse
    }
}

Describe 'Test-PswPathIsUnder' {

    It 'true khi path bằng parent' {
        Test-PswPathIsUnder 'C:\a\b' 'C:\a\b' | Should -BeTrue
    }

    It 'true khi path nằm trong parent' {
        Test-PswPathIsUnder 'C:\a\b\c' 'C:\a\b' | Should -BeTrue
    }

    It 'FALSE với ranh giới component: C:\foo-bar không nằm dưới C:\foo' {
        Test-PswPathIsUnder 'C:\foo-bar' 'C:\foo' | Should -BeFalse
    }

    It 'false khi parent không phải tổ tiên' {
        Test-PswPathIsUnder 'C:\x\y' 'C:\a\b' | Should -BeFalse
    }

    It 'true với parent có dấu \ cuối' {
        Test-PswPathIsUnder 'C:\a\b\c' 'C:\a\b\' | Should -BeTrue
    }

    It 'không phân biệt hoa thường' {
        Test-PswPathIsUnder 'C:\A\B\C' 'c:\a\b' | Should -BeTrue
    }
}

Describe 'Get-PswParentPath' {

    It 'trả về folder cha' {
        Get-PswParentPath 'C:\a\b\c' | Should -Be 'C:\a\b'
    }

    It 'trả về $null cho gốc ổ đĩa' {
        Get-PswParentPath 'C:\' | Should -BeNullOrEmpty
    }

    It 'trả về folder cha cấp 1 từ folder cấp 2' {
        Get-PswParentPath 'C:\Users' | Should -Be 'C:\'
    }
}

Describe 'Get-PswPathDepth' {

    It 'gốc ổ đĩa có depth 0' {
        Get-PswPathDepth 'C:\' | Should -Be 0
    }

    It 'C:\a có depth 1' {
        Get-PswPathDepth 'C:\a' | Should -Be 1
    }

    It 'C:\a\b\c có depth 3' {
        Get-PswPathDepth 'C:\a\b\c' | Should -Be 3
    }
}

Describe 'Get-PswRelativePath' {

    It 'trả về path tương đối khi nằm dưới base' {
        Get-PswRelativePath 'C:\a\b\c\d' 'C:\a\b' | Should -Be 'c\d'
    }

    It 'trả về "." khi path bằng base' {
        Get-PswRelativePath 'C:\a\b' 'C:\a\b' | Should -Be '.'
    }

    It 'trả về path tuyệt đối khi nằm ngoài base' {
        Get-PswRelativePath 'C:\x\y' 'C:\a\b' | Should -Be 'C:\x\y'
    }
}

Describe 'Test-PswIsReparsePoint' {

    It 'false với folder thường' {
        $temp = Join-Path $TestDrive 'normal'
        [void][System.IO.Directory]::CreateDirectory($temp)
        Test-PswIsReparsePoint $temp | Should -BeFalse
    }

    It 'true với junction' {
        $target = Join-Path $TestDrive 'junction_target'
        $link = Join-Path $TestDrive 'junction_link'
        [void][System.IO.Directory]::CreateDirectory($target)

        # mklink /J không cần quyền admin (khác với symlink)
        $output = & cmd /c "mklink /J `"$link`" `"$target`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because "môi trường không tạo được junction: $output"
            return
        }

        Test-PswIsReparsePoint $link | Should -BeTrue
    }
}

Describe 'Get-PswFileSystemInfos' {

    It 'liệt kê file và folder con trực tiếp' {
        $root = Join-Path $TestDrive 'listing'
        New-PswTestTree -Root $root -Tree @{
            'a.txt'   = 'x'
            'b.txt'   = 'x'
            'sub/c.txt' = 'x'
        }

        $items = Get-PswFileSystemInfos -Path $root
        @($items) | Should -HaveCount 3
        @($items | Where-Object { $_.Name -eq 'a.txt' }) | Should -HaveCount 1
        @($items | Where-Object { $_.Name -eq 'sub' }) | Should -HaveCount 1
    }

    It 'trả về mảng rỗng cho folder không tồn tại' {
        $items = Get-PswFileSystemInfos -Path (Join-Path $TestDrive 'khong_ton_tai')
        @($items) | Should -HaveCount 0
    }

    It 'ghi lỗi vào -Errors thay vì ném exception' {
        $errors = New-Object 'System.Collections.Generic.List[object]'
        $items = Get-PswFileSystemInfos -Path (Join-Path $TestDrive 'khong_ton_tai') -Errors $errors
        @($items) | Should -HaveCount 0
        $errors.Count | Should -BeGreaterThan 0
    }

    It 'doc duoc folder co path dai hon 260 ky tu' {
        $root = Join-Path $TestDrive 'lp'
        $deep = $root
        1..8 | ForEach-Object { $deep = Join-Path $deep ('x' * 30) }
        [void][System.IO.Directory]::CreateDirectory('\\?\' + $deep)
        [System.IO.File]::WriteAllText('\\?\' + (Join-Path $deep 'deep.txt'), 'x')

        $deep.Length | Should -BeGreaterThan 260
        $items = Get-PswFileSystemInfos -Path $deep
        @($items) | Should -HaveCount 1
        @($items)[0].Name | Should -Be 'deep.txt'
    }
}
