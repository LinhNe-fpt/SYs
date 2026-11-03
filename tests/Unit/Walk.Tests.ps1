#Requires -Version 5.1
<#
    Walk.Tests.ps1 - Test bộ quét (unit, dùng cây nhỏ tự tạo).

    Các test này KHÔNG dùng bộ fixtures lớn; mỗi test tạo đúng cây nó cần để
    dễ đọc và để lỗi chỉ về đúng một luật.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    Import-PswTestModule

    $script:Work = Join-Path (Get-PswTestWorkDir) 'walk'
}

Describe 'walk' {

    AfterEach {
        if (Test-Path -LiteralPath $script:Work) {
            Remove-PswTestTree -Path $script:Work
        }
    }

    Describe 'New-PswScanOptions' {

        It 'trả về đủ các khoá mặc định' {
            $options = New-PswScanOptions
            foreach ($key in @('MaxDepth', 'MaxEntries', 'MinSizeBytes', 'IncludeHome',
                    'IncludeSecrets', 'SkipSize', 'Quiet', 'ExcludePatterns',
                    'ExcludePaths', 'FollowLinks')) {
                $options.PSObject.Properties.Name | Should -Contain $key
            }
        }

        It 'IncludeHome mặc định là false (an toàn)' {
            (New-PswScanOptions).IncludeHome | Should -BeFalse
        }

        It 'MinSizeBytes mặc định là 0 (báo cáo tất cả)' {
            (New-PswScanOptions).MinSizeBytes | Should -Be 0
        }
    }

    Describe 'Test-PswExcluded' {

        It 'khớp wildcard trên full path' {
            Test-PswExcluded -Path 'C:\a\b\c.cs' -Patterns @('*.cs') | Should -BeTrue
        }

        It 'khớp wildcard trên tên leaf' {
            Test-PswExcluded -Path 'C:\a\b\node_modules' -Patterns @('node_modules') | Should -BeTrue
        }

        It 'khớp tiền tố folder trong -ExactPaths' {
            Test-PswExcluded -Path 'C:\a\skip\deep\x.js' -ExactPaths @('C:\a\skip') | Should -BeTrue
        }

        It 'false khi không khớp gì' {
            Test-PswExcluded -Path 'C:\a\b\c.js' -Patterns @('*.cs') | Should -BeFalse
        }

        It 'false khi danh sách rỗng' {
            Test-PswExcluded -Path 'C:\a\b\c.js' -Patterns @() -ExactPaths @() | Should -BeFalse
        }
    }

    Describe 'Invoke-PswScan: phát hiện project' {

        It 'project có marker được báo là Project' {
            $root = Join-Path $script:Work 'with_marker'
            New-PswTestTree -Root $root -Tree @{
                'app/package.json' = '{}'
                'app/src/index.js' = 'x'
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $projects = @($result.Entries | Where-Object { $_.Kind -eq 'Project' })

            $projects | Should -HaveCount 1
            $projects[0].Name | Should -Be 'app'
            $projects[0].IsDirectory | Should -BeTrue
            $projects[0].SizeBytes | Should -BeGreaterThan 0
        }

        It 'KHÔNG đi vào bên trong project đã nhận diện (tránh liệt kê cả repo)' {
            $root = Join-Path $script:Work 'noprune'
            $tree = @{ 'app/package.json' = '{}' }
            1..20 | ForEach-Object { $tree["app/src/f$_.js"] = 'x' }
            $tree['app/src/deep/nested/package.json'] = '{}'
            New-PswTestTree -Root $root -Tree $tree

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            @($result.Entries | Where-Object { $_.Kind -eq 'Project' }) | Should -HaveCount 1
            @($result.Entries | Where-Object { $_.Path -like '*deep*' }) | Should -HaveCount 0
        }

        It 'container không phải project thì đi tiếp xuống dưới' {
            $root = Join-Path $script:Work 'container'
            New-PswTestTree -Root $root -Tree @{
                'a/b/c/proj/Cargo.toml' = '[package]'
                'a/b/c/proj/src/main.rs' = 'fn main(){}'
                'a/b/notes.txt' = 'x'
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $projects = @($result.Entries | Where-Object { $_.Kind -eq 'Project' })
            $projects | Should -HaveCount 1
            $projects[0].Name | Should -Be 'proj'
        }

        It 'tìm được nhiều project anh em' {
            $root = Join-Path $script:Work 'siblings'
            New-PswTestTree -Root $root -Tree @{
                'p1/package.json' = '{}'
                'p2/Cargo.toml' = '[package]'
                'p3/go.mod' = 'module x'
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            @($result.Entries | Where-Object { $_.Kind -eq 'Project' }) | Should -HaveCount 3
        }
    }

    Describe 'Invoke-PswScan: folder rác dev' {

        It 'node_modules được báo là DevDir và không đi vào' {
            $root = Join-Path $script:Work 'devdir'
            $tree = @{}
            1..10 | ForEach-Object { $tree["node_modules/lib$_.js"] = 'x' }
            $tree['node_modules/deep/nested/package.json'] = '{}'
            New-PswTestTree -Root $root -Tree $tree

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $devDirs = @($result.Entries | Where-Object { $_.Kind -eq 'DevDir' })

            $devDirs | Should -HaveCount 1
            $devDirs[0].Name | Should -Be 'node_modules'
            @($result.Entries | Where-Object { $_.Path -like '*nested*' }) | Should -HaveCount 0
        }

        It 'target, .venv, dist, __pycache__ đều được báo' {
            $root = Join-Path $script:Work 'manydev'
            New-PswTestTree -Root $root -Tree @{
                'target/debug/a.rlib'        = 'x'
                '.venv/Lib/site.py'          = 'x'
                'dist/bundle.js'             = 'x'
                'app/__pycache__/m.pyc'      = 'x'
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $names = @($result.Entries | Where-Object { $_.Kind -eq 'DevDir' } | ForEach-Object { $_.Name })

            $names | Should -Contain 'target'
            $names | Should -Contain '.venv'
            $names | Should -Contain 'dist'
            $names | Should -Contain '__pycache__'
        }
    }

    Describe 'Invoke-PswScan: secret' {

        It 'file .env được báo là Secret' {
            $root = Join-Path $script:Work 'secretfile'
            New-PswTestTree -Root $root -Tree @{ '.env' = 'A=1' }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            @($result.Entries | Where-Object { $_.Kind -eq 'Secret' }) | Should -HaveCount 1
        }

        It 'folder .ssh được báo là Secret và không đi vào' {
            $root = Join-Path $script:Work 'secretdir'
            New-PswTestTree -Root $root -Tree @{
                '.ssh/id_rsa'      = 'key'
                '.ssh/known_hosts' = 'host'
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $secrets = @($result.Entries | Where-Object { $_.Kind -eq 'Secret' })

            $secrets | Should -HaveCount 1
            $secrets[0].Name | Should -Be '.ssh'
            $secrets[0].IsDirectory | Should -BeTrue
        }

        It 'cảnh báo .git-credentials' {
            $root = Join-Path $script:Work 'creds'
            New-PswTestTree -Root $root -Tree @{ '.git-credentials' = 'https://x:y@z' }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            @($result.Entries | Where-Object { $_.Kind -eq 'Secret' }) | Should -HaveCount 1
        }
    }

    Describe 'Invoke-PswScan: an toàn' {

        It 'không báo folder tên Documents là xoá được' {
            $root = Join-Path $script:Work 'safety'
            New-PswTestTree -Root $root -Tree @{
                'Documents/proj/package.json' = '{}'
                'Documents/proj/a.js'         = 'x'
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)

            # Bản thân folder "Documents" KHÔNG bao giờ được xuất hiện như một
            # mục có thể xoá (dù nó có bị báo cáo hay không).
            @($result.Entries | Where-Object { $_.Name -eq 'Documents' -and -not $_.Protected }) |
                Should -HaveCount 0

            # Và guard độc lập cũng phải chặn xoá nó.
            Get-PswProtectionReason (Join-Path $root 'Documents') | Should -Not -BeNullOrEmpty

            # project bên trong Documents được phép xoá (chỉ cấm xoá cả Documents)
            $inDocs = @($result.Entries | Where-Object { $_.Name -eq 'proj' -and $_.Kind -eq 'Project' })
            $inDocs | Should -HaveCount 1
            $inDocs[0].Protected | Should -BeFalse
        }

        It 'folder tên Documents được báo là protected nếu nó khớp luật dev/secret' {
            # 'Desktop' vừa là tên shell folder vừa không phải dev dir, nên để
            # chắc chắn guard chạy, dùng .ssh (secret) đặt trong folder tên
            # 'Downloads' - entry .ssh phải được báo và nằm dưới shell name.
            $root = Join-Path $script:Work 'safety2'
            New-PswTestTree -Root $root -Tree @{
                'Downloads/.ssh/id_rsa' = 'key'
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $ssh = @($result.Entries | Where-Object { $_.Name -eq '.ssh' })
            $ssh | Should -HaveCount 1
            # Bản thân .ssh thì xoá được; cái bảo vệ là folder Downloads.
            Get-PswProtectionReason (Join-Path $root 'Downloads') | Should -Not -BeNullOrEmpty
        }

        It 'không đi theo junction khi quét' {
            $target = Join-Path $script:Work 'jtarget'
            New-PswTestTree -Root $target -Tree @{ 'package.json' = '{}' }

            $root = Join-Path $script:Work 'jscan'
            New-PswTestTree -Root $root -Tree @{ 'normal/a.js' = 'x' }
            $link = Join-Path $root 'link'
            $null = & cmd /c "mklink /J `"$link`" `"$target`"" 2>&1

            if (-not (Test-Path -LiteralPath $link)) {
                Set-ItResult -Skipped -Because 'không tạo được junction'
                return
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)

            # Không có entry nào đi qua junction
            @($result.Entries | Where-Object { $_.Path -like '*\link\*' }) | Should -HaveCount 0
            $result.Stats.LinksSkipped | Should -BeGreaterThan 0
        }

        It 'không báo folder media-heavy là xoá được' {
            $root = Join-Path $script:Work 'media'
            $tree = @{}
            1..12 | ForEach-Object { $tree["photos/img$_.jpg"] = 'jpeg' }
            $tree['photos/one_script.py'] = 'x'
            New-PswTestTree -Root $root -Tree $tree

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $mediaHeavy = @($result.Entries | Where-Object { $_.Kind -eq 'MediaHeavy' })

            $mediaHeavy | Should -HaveCount 1
            $mediaHeavy[0].Protected | Should -BeTrue
        }
    }

    Describe 'Invoke-PswScan: tuỳ chọn' {

        It '-MaxDepth giới hạn độ sâu' {
            $root = Join-Path $script:Work 'depth'
            New-PswTestTree -Root $root -Tree @{
                'lvl1/lvl2/lvl3/lvl4/proj/package.json' = '{}'
            }

            $options = New-PswScanOptions
            $options.MaxDepth = 2
            $result = Invoke-PswScan -Root @($root) -Options $options

            @($result.Entries | Where-Object { $_.Kind -eq 'Project' }) | Should -HaveCount 0
        }

        It '-Exclude loại trừ theo mẫu' {
            $root = Join-Path $script:Work 'exclude'
            New-PswTestTree -Root $root -Tree @{
                'keep/package.json'   = '{}'
                'skipme/package.json' = '{}'
            }

            $options = New-PswScanOptions
            $options.ExcludePatterns = @('skipme')
            $result = Invoke-PswScan -Root @($root) -Options $options

            $names = @($result.Entries | ForEach-Object { $_.Name })
            $names | Should -Contain 'keep'
            $names | Should -Not -Contain 'skipme'
        }

        It '-SkipSize để lại SizeBytes = 0' {
            $root = Join-Path $script:Work 'nosize'
            New-PswTestTree -Root $root -Tree @{
                'proj/package.json' = '{}'
                'proj/big.js'       = ('x' * 5000)
            }

            $options = New-PswScanOptions
            $options.SkipSize = $true
            $result = Invoke-PswScan -Root @($root) -Options $options

            foreach ($entry in $result.Entries) { $entry.SizeBytes | Should -Be 0 }
        }

        It '-MinSizeBytes lọc bớt entry nhỏ' {
            $root = Join-Path $script:Work 'minsize'
            New-PswTestTree -Root $root -Tree @{
                'small/package.json' = '{}'
                'big/package.json'   = '{}'
                'big/big.js'         = ('x' * 5000)
            }

            $options = New-PswScanOptions
            $options.MinSizeBytes = 1000
            $result = Invoke-PswScan -Root @($root) -Options $options

            $names = @($result.Entries | ForEach-Object { $_.Name })
            $names | Should -Contain 'big'
            $names | Should -Not -Contain 'small'
        }
    }

    Describe 'Invoke-PswScan: root không hợp lệ' {

        It 'báo lỗi cho root không tồn tại, không ném exception' {
            $missing = Join-Path $script:Work 'khong_ton_tai'
            $result = Invoke-PswScan -Root @($missing) -Options (New-PswScanOptions)

            @($result.Errors) | Should -HaveCount 1
            $result.Roots[0].Status | Should -Be 'Missing'
        }

        It 'từ chối quét gốc ổ đĩa (trừ khi IncludeHome)' {
            $result = Invoke-PswScan -Root @('C:\') -Options (New-PswScanOptions)
            $result.Roots[0].Status | Should -Be 'Blocked'
        }

        It 'vẫn quét root hợp lệ khi có root lỗi xen kẽ' {
            $good = Join-Path $script:Work 'good'
            New-PswTestTree -Root $good -Tree @{ 'proj/package.json' = '{}' }

            $result = Invoke-PswScan -Root @((Join-Path $script:Work 'nope'), $good) -Options (New-PswScanOptions)
            @($result.Entries | Where-Object { $_.Kind -eq 'Project' }) | Should -HaveCount 1
            @($result.Errors) | Should -HaveCount 1
        }

        It 'root là một file code thì phân loại là CodeFile' {
            $root = Join-Path $script:Work 'file_root'
            New-PswTestTree -Root $root -Tree @{ 'lonely.py' = 'print(1)' }

            $result = Invoke-PswScan -Root @((Join-Path $root 'lonely.py')) -Options (New-PswScanOptions)
            $entries = @($result.Entries)
            $entries | Should -HaveCount 1
            $entries[0].Kind | Should -Be 'CodeFile'
        }
    }

    Describe 'Invoke-PswScan: thống kê' {

        It 'Stats đếm đúng số project/devdir/secret' {
            $root = Join-Path $script:Work 'stats'
            New-PswTestTree -Root $root -Tree @{
                'proj1/package.json'    = '{}'
                'proj2/Cargo.toml'      = '[package]'
                'node_modules/x.js'     = 'x'
                '.env'                  = 'A=1'
            }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $result.Stats.Projects | Should -Be 2
            $result.Stats.DevDirs | Should -Be 1
            $result.Stats.Secrets | Should -Be 1
            $result.Stats.FoldersVisited | Should -BeGreaterThan 0
        }

        It 'Stats.DurationMs >= 0' {
            $root = Join-Path $script:Work 'dur'
            New-PswTestTree -Root $root -Tree @{ 'a.txt' = 'x' }

            $result = Invoke-PswScan -Root @($root) -Options (New-PswScanOptions)
            $result.Stats.DurationMs | Should -BeGreaterOrEqual 0
        }

        It 'chạm trần MaxEntries thì dừng và ghi lỗi, không treo' {
            $root = Join-Path $script:Work 'truncate'
            $tree = @{}
            1..60 | ForEach-Object { $tree["f$_.txt"] = 'x' }
            New-PswTestTree -Root $root -Tree $tree

            $options = New-PswScanOptions
            $options.MaxEntries = 10
            $result = Invoke-PswScan -Root @($root) -Options $options

            $result.Stats.Truncated | Should -BeTrue
            @($result.Errors | Where-Object { $_.Error -like '*trần*' }) | Should -HaveCount 1
        }
    }
}
