#Requires -Version 5.1
<#
    Config.Tests.ps1 - Test hợp đồng của config.ps1.

    Đây là test "gác cổng": nếu ai thêm một extension sai format hoặc trùng
    lặp, test fail ngay chứ không để lỗi âm thầm xuất hiện lúc runtime.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    Import-PswTestModule
}

Describe 'config: tính toàn vẹn của dữ liệu' {

    Context 'Extension code' {

        It 'mọi phần tử đều bắt đầu bằng dấu chấm' {
            $extensions = Get-PswConfig | ForEach-Object { $_.CodeExtensions }
            $bad = @($extensions | Where-Object { -not $_.StartsWith('.') })
            $bad | Should -HaveCount 0 -Because "extension thiếu dấu chấm sẽ không bao giờ khớp: $($bad -join ', ')"
        }

        It 'mọi phần tử đều đã lowercase' {
            $extensions = @((Get-PswConfig).CodeExtensions)
            $bad = @($extensions | Where-Object { $_ -cne $_.ToLowerInvariant() })
            $bad | Should -HaveCount 0
        }

        It 'không có phần tử trùng lặp' {
            $extensions = @((Get-PswConfig).CodeExtensions)
            $duplicates = @($extensions | Group-Object | Where-Object { $_.Count -gt 1 })
            $names = @($duplicates | ForEach-Object { $_.Name })
            $duplicates | Should -HaveCount 0 -Because "trùng: $($names -join ', ')"
        }

        It 'không có phần tử rỗng hoặc null' {
            $extensions = @((Get-PswConfig).CodeExtensions)
            @($extensions | Where-Object { [string]::IsNullOrWhiteSpace($_) }) | Should -HaveCount 0
        }
    }

    Context 'Mọi danh sách extension' {

        It '<ListName> hợp lệ hoàn toàn' -ForEach @(
            @{ ListName = 'CodeExtensions' }
            @{ ListName = 'WeakConfigExtensions' }
            @{ ListName = 'MediaExtensions' }
            @{ ListName = 'BinaryExtensions' }
        ) {
            $extensions = @((Get-PswConfig).$ListName)
            @($extensions | Where-Object { -not $_.StartsWith('.') }) | Should -HaveCount 0
            @($extensions | Where-Object { $_ -cne $_.ToLowerInvariant() }) | Should -HaveCount 0
            @($extensions | Group-Object | Where-Object { $_.Count -gt 1 }) | Should -HaveCount 0
        }

        It 'các nhóm extension không chồng lấn nhau' {
            $config = Get-PswConfig
            $code = @($config.CodeExtensions)
            $media = @($config.MediaExtensions)
            $binary = @($config.BinaryExtensions)
            $weak = @($config.WeakConfigExtensions)

            $overlap = @($code | Where-Object { $media -contains $_ })
            $overlap | Should -HaveCount 0 -Because "code và media trùng: $($overlap -join ', ')"

            $overlap2 = @($code | Where-Object { $binary -contains $_ })
            $overlap2 | Should -HaveCount 0 -Because "code và binary trùng: $($overlap2 -join ', ')"

            $overlap3 = @($code | Where-Object { $weak -contains $_ })
            $overlap3 | Should -HaveCount 0 -Because "code và weak-config trùng: $($overlap3 -join ', ')"
        }
    }

    Context 'Marker project' {

        It 'không có marker trùng giữa danh sách tên và wildcard' {
            $config = Get-PswConfig
            $names = @($config.ProjectMarkerNames)
            $patterns = @($config.ProjectMarkerPatterns)

            $collisions = @()
            foreach ($pattern in $patterns) {
                if ($pattern -notmatch '\*') { continue }
                foreach ($name in $names) {
                    if ($name -like $pattern) { $collisions += "$name khớp $pattern" }
                }
            }
            $collisions | Should -HaveCount 0
        }

        It 'mọi wildcard pattern đều chứa ít nhất một dấu *' {
            @((Get-PswConfig).ProjectMarkerPatterns | Where-Object { $_ -notmatch '\*' }) | Should -HaveCount 0
        }
    }

    Context 'Lookup set' {

        It 'không phân biệt hoa thường' {
            $lookup = Get-PswLookup -Name 'DevDirNames'
            $lookup.Contains('NODE_MODULES') | Should -BeTrue
            $lookup.Contains('node_modules') | Should -BeTrue
            $lookup.Contains('NoDe_MoDuLeS') | Should -BeTrue
        }

        It 'không chứa chuỗi rỗng' {
            (Get-PswLookup -Name 'DevDirNames').Contains('') | Should -BeFalse
        }

        It 'tên lookup không tồn tại sẽ throw' {
            { Get-PswLookup -Name 'KhongCoNhomNay' } | Should -Throw
        }
    }

    Context 'Defaults' {

        It 'mọi ngưỡng đều dương' {
            $defaults = (Get-PswConfig).Defaults
            foreach ($key in @('MaxDepth', 'MaxEntriesVisited', 'LogRotateBytes', 'DeleteRetryCount', 'WslTimeoutSeconds')) {
                $defaults[$key] | Should -BeGreaterThan 0 -Because "ngưỡng '$key' phải dương"
            }
        }

        It 'tỉ lệ media nằm trong (0,1]' {
            $ratio = Get-PswDefault -Name 'MediaDominanceRatio'
            $ratio | Should -BeGreaterThan 0
            $ratio | Should -BeLessOrEqual 1
        }

        It 'default không tồn tại sẽ throw' {
            { Get-PswDefault -Name 'KhongCoMacDinhNay' } | Should -Throw
        }
    }

    Context 'Section' {

        It 'lấy được section cụ thể' {
            (Get-PswConfig -Section 'Defaults') | Should -Not -BeNullOrEmpty
        }

        It 'section không tồn tại sẽ throw' {
            { Get-PswConfig -Section 'KhongCoSectionNay' } | Should -Throw
        }
    }
}

Describe 'config: dữ liệu thực tế quan trọng' {

    It 'nhận diện các marker phổ biến' {
        foreach ($marker in @('.git', 'package.json', 'Cargo.toml', 'go.mod', 'pyproject.toml', 'pom.xml', 'build.gradle')) {
            Test-PswIsProjectMarker $marker | Should -BeTrue -Because "'$marker' là marker project phổ biến"
        }
    }

    It 'nhận diện marker dạng wildcard' {
        foreach ($marker in @('App.sln', 'MyProj.csproj', 'ios.xcodeproj')) {
            Test-PswIsProjectMarker $marker | Should -BeTrue -Because "'$marker' khớp pattern"
        }
    }

    It 'không nhận diện nhầm file thường là marker' {
        foreach ($name in @('readme.md', 'notes.txt', 'photo.jpg', 'data.json')) {
            Test-PswIsProjectMarker $name | Should -BeFalse
        }
    }

    It 'nhận diện folder rác dev phổ biến' {
        foreach ($name in @('node_modules', 'target', '.venv', '__pycache__', 'dist', 'build', '.gradle', '.next')) {
            Test-PswIsDevDirName $name | Should -BeTrue
        }
    }

    It 'node_modules KHÔNG nằm trong skip list (để báo cáo được node_modules mồ côi)' {
        Test-PswIsDevDirName 'node_modules' | Should -BeTrue
        Test-PswIsSkipDirName 'node_modules' | Should -BeFalse
    }

    It 'AppData nằm trong skip list (không quét)' {
        Test-PswIsSkipDirName 'AppData' | Should -BeTrue
    }
}
