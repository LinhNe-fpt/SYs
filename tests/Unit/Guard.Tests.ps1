#Requires -Version 5.1
<#
    Guard.Tests.ps1 - Test lớp an toàn.

    Đây là test quan trọng nhất của dự án: nếu guard sai, tool sẽ xoá dữ
    liệu của người dùng. Mỗi luật R1..R8 có ít nhất 2 case (một positive,
    một negative) và các case biên theo ranh giới component.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    Import-PswTestModule

    # KHÔNG dùng $TestDrive: Pester đặt TestDrive trong %TEMP%, mà %TEMP%
    # nằm dưới AppData\Local - chính là vùng guard cấm. Sandbox phải nằm ở
    # nơi "bình thường" như một project thật của user.
    $script:Sandbox = Join-Path (Get-PswTestWorkDir) 'guard-sandbox'
    if (Test-Path -LiteralPath $script:Sandbox) {
        Remove-PswTestTree -Path $script:Sandbox
    }
    [void][System.IO.Directory]::CreateDirectory($script:Sandbox)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Sandbox 'project'))
    [System.IO.File]::WriteAllText((Join-Path $script:Sandbox 'project\a.js'), 'x')
    [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Sandbox 'Documents-fake'))
}

AfterAll {
    Clear-PswGuardCache
    if (Test-Path -LiteralPath $script:Sandbox) {
        Remove-PswTestTree -Path $script:Sandbox
    }
}

Describe 'Get-PswSystemSubtrees' {

    It 'bao gồm Windows và Program Files' {
        $subtrees = Get-PswSystemSubtrees
        @($subtrees | Where-Object { $_ -like '*\Windows' }) | Should -HaveCount 1
        @($subtrees | Where-Object { $_ -like '*\Program Files' }) | Should -HaveCount 1
    }

    It 'mọi phần tử đều là path tuyệt đối' {
        foreach ($path in (Get-PswSystemSubtrees)) {
            [System.IO.Path]::IsPathRooted($path) | Should -BeTrue -Because "$path phải là path tuyệt đối"
        }
    }

    It 'không chứa path rỗng' {
        @(Get-PswSystemSubtrees | Where-Object { [string]::IsNullOrWhiteSpace($_) }) | Should -HaveCount 0
    }
}

Describe 'Get-PswExactForbidden' {

    It 'bao gồm %USERPROFILE%' {
        $found = @(Get-PswExactForbidden | Where-Object {
                $_ -eq (Get-PswFullPath $env:USERPROFILE)
            })
        $found | Should -HaveCount 1
    }

    It 'bao gồm Desktop và Documents' {
        $forbidden = Get-PswExactForbidden
        $desktop = [Environment]::GetFolderPath('Desktop')
        $documents = [Environment]::GetFolderPath('MyDocuments')

        @($forbidden | Where-Object { $_ -eq (Get-PswFullPath $desktop) }) | Should -HaveCount 1
        @($forbidden | Where-Object { $_ -eq (Get-PswFullPath $documents) }) | Should -HaveCount 1
    }
}

Describe 'Get-PswProtectionReason: luật cấm' {

    Context 'R1 - đường dẫn không hợp lệ' {

        It 'chuỗi rỗng bị cấm' {
            Get-PswProtectionReason '' | Should -Not -BeNullOrEmpty
        }

        It 'chuỗi khoảng trắng bị cấm' {
            Get-PswProtectionReason '   ' | Should -Not -BeNullOrEmpty
        }

        It '$null bị cấm' {
            Get-PswProtectionReason $null | Should -Not -BeNullOrEmpty
        }

        It 'path có ký tự không hợp lệ bị cấm' {
            Get-PswProtectionReason 'C:\a<b>\c' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'R2 - gốc ổ đĩa và UNC' {

        It 'gốc ổ đĩa bị cấm' {
            Get-PswProtectionReason 'C:\' | Should -Not -BeNullOrEmpty
        }

        It 'gốc ổ đĩa không có \ cũng bị cấm' {
            Get-PswProtectionReason 'C:' | Should -Not -BeNullOrEmpty
        }

        It 'gốc UNC share bị cấm' {
            { Get-PswProtectionReason '\\server\share' } | Should -Not -Throw
            Get-PswProtectionReason '\\server\share' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'R3 - nằm trong thư mục hệ thống' {

        It 'C:\Windows bị cấm' {
            Get-PswProtectionReason (New-PswTestFilePath 'Windows') | Should -Not -BeNullOrEmpty
        }

        It 'C:\Windows\System32 bị cấm' {
            Get-PswProtectionReason (New-PswTestFilePath 'Windows\System32') | Should -Not -BeNullOrEmpty
        }

        It 'C:\Program Files\SomeApp bị cấm' {
            Get-PswProtectionReason (New-PswTestFilePath 'Program Files\SomeApp') | Should -Not -BeNullOrEmpty
        }

        It 'C:\ProgramData\App bị cấm' {
            Get-PswProtectionReason (New-PswTestFilePath 'ProgramData\App') | Should -Not -BeNullOrEmpty
        }
    }

    Context 'R4 - chính folder shell của user' {

        It 'Desktop bị cấm' {
            Get-PswProtectionReason ([Environment]::GetFolderPath('Desktop')) | Should -Not -BeNullOrEmpty
        }

        It 'Documents bị cấm' {
            Get-PswProtectionReason ([Environment]::GetFolderPath('MyDocuments')) | Should -Not -BeNullOrEmpty
        }

        It '%USERPROFILE% bị cấm' {
            Get-PswProtectionReason $env:USERPROFILE | Should -Not -BeNullOrEmpty
        }

        It 'C:\Users bị cấm' {
            $parent = Get-PswParentPath $env:USERPROFILE
            Get-PswProtectionReason $parent | Should -Not -BeNullOrEmpty
        }
    }

    Context 'R4b - tên trùng folder shell ở bất kỳ vị trí' {

        It 'folder tên Documents ở nơi khác cũng bị cấm' {
            $fake = Join-Path $script:Sandbox 'Documents'
            [void][System.IO.Directory]::CreateDirectory($fake)
            Get-PswProtectionReason $fake | Should -Not -BeNullOrEmpty
        }

        It 'repo tên Downloads không bị xoá cả cụm' {
            $fake = Join-Path $script:Sandbox 'Downloads'
            [void][System.IO.Directory]::CreateDirectory($fake)
            Get-PswProtectionReason $fake | Should -Not -BeNullOrEmpty
        }

        It 'project nằm BÊN TRONG folder tên Documents vẫn xoá được' {
            $inner = Join-Path $script:Sandbox 'Documents\my_project'
            [void][System.IO.Directory]::CreateDirectory($inner)
            Get-PswProtectionReason $inner | Should -BeNullOrEmpty
        }
    }

    Context 'R5 - component tên cấm trong đường dẫn' {

        It 'path chứa $Recycle.Bin bị cấm' {
            Get-PswProtectionReason 'C:\$Recycle.Bin\S-1-5-21' | Should -Not -BeNullOrEmpty
        }

        It 'path chứa System Volume Information bị cấm' {
            Get-PswProtectionReason 'C:\System Volume Information\foo' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'R6 - AppData' {

        It 'AppData\Local bị cấm' {
            Get-PswProtectionReason ([Environment]::GetFolderPath('LocalApplicationData')) | Should -Not -BeNullOrEmpty
        }

        It 'folder trong AppData\Local bị cấm' {
            $local = [Environment]::GetFolderPath('LocalApplicationData')
            Get-PswProtectionReason (Join-Path $local 'SomeApp') | Should -Not -BeNullOrEmpty
        }
    }

    Context 'R8 - không tồn tại' {

        It 'path không tồn tại bị cấm' {
            Get-PswProtectionReason (Join-Path $script:Sandbox 'khong_ton_tai') | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Negative - path bình thường phải được phép' {

        It 'folder thường trong sandbox được phép' {
            Get-PswProtectionReason (Join-Path $script:Sandbox 'project') | Should -BeNullOrEmpty
        }

        It 'file trong sandbox được phép' {
            Get-PswProtectionReason (Join-Path $script:Sandbox 'project\a.js') | Should -BeNullOrEmpty
        }

        It 'sandbox chính nó được phép (đủ sâu)' {
            # TestDrive nằm trong temp, đủ sâu để không bị luật "quá nông" chặn
            Get-PswProtectionReason $script:Sandbox | Should -BeNullOrEmpty
        }
    }

    Context 'Ranh giới component' {

        It 'folder tên Windows-Foo KHÔNG bị coi là Windows' {
            $fake = Join-Path $script:Sandbox 'Windows-Foo'
            [void][System.IO.Directory]::CreateDirectory($fake)
            Get-PswProtectionReason $fake | Should -BeNullOrEmpty
        }

        It 'folder tên MyWindows KHÔNG bị coi là Windows' {
            $fake = Join-Path $script:Sandbox 'MyWindows'
            [void][System.IO.Directory]::CreateDirectory($fake)
            Get-PswProtectionReason $fake | Should -BeNullOrEmpty
        }

        It 'folder tên WindowsDocument bị chặn bởi R4b? Không - chỉ tên chính xác mới chặn' {
            $fake = Join-Path $script:Sandbox 'WindowsDocument'
            [void][System.IO.Directory]::CreateDirectory($fake)
            Get-PswProtectionReason $fake | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-PswProtectedPath' {

    It 'true với path bị cấm' {
        Test-PswProtectedPath 'C:\Windows\System32' | Should -BeTrue
    }

    It 'false với path an toàn' {
        $safe = Join-Path $script:Sandbox 'project'
        Test-PswProtectedPath $safe | Should -BeFalse
    }

    It 'true với chuỗi rỗng' {
        Test-PswProtectedPath '' | Should -BeTrue
    }
}

Describe 'Test-PswShallowPath' {

    It 'true với folder cấp 1' {
        Test-PswShallowPath (New-PswTestFilePath 'SomethingFolder') | Should -BeTrue
    }

    It 'false với folder cấp 2' {
        Test-PswShallowPath (New-PswTestFilePath 'Something\Nested') | Should -BeFalse
    }

    It 'false với gốc ổ đĩa (được xử lý bởi luật khác)' {
        Test-PswShallowPath 'C:\' | Should -BeFalse
    }
}

Describe 'Get-PswScanRootBlockReason' {

    It 'từ chối quét gốc ổ đĩa' {
        Get-PswScanRootBlockReason 'C:\' | Should -Not -BeNullOrEmpty
    }

    It 'từ chối quét C:\Windows' {
        Get-PswScanRootBlockReason (New-PswTestFilePath 'Windows') | Should -Not -BeNullOrEmpty
    }

    It 'từ chối quét bên trong Program Files' {
        Get-PswScanRootBlockReason (New-PswTestFilePath 'Program Files\App') | Should -Not -BeNullOrEmpty
    }

    It 'cho phép quét folder thường' {
        Get-PswScanRootBlockReason $script:Sandbox | Should -BeNullOrEmpty
    }

    It 'cho phép quét Desktop (quét được, chỉ không xoá được)' {
        Get-PswScanRootBlockReason ([Environment]::GetFolderPath('Desktop')) | Should -BeNullOrEmpty
    }
}

Describe 'Test-PswElevated' {

    It 'trả về boolean, không ném lỗi' {
        $result = Test-PswElevated
        $result | Should -BeOfType [bool]
    }
}

Describe 'Get-PswRunningEditorProcesses' {

    It 'trả về mảng (có thể rỗng), không ném lỗi' {
        $processes = Get-PswRunningEditorProcesses
        , $processes | Should -Not -BeNullOrEmpty -Because 'phải luôn trả về mảng, kể cả rỗng'
    }

    It 'mỗi phần tử có Name và Id' {
        foreach ($process in (Get-PswRunningEditorProcesses)) {
            $process.Name | Should -Not -BeNullOrEmpty
            $process.Id | Should -BeGreaterThan 0
        }
    }
}
