#Requires -Version 5.1
<#
    Classify.Tests.ps1 - Table-driven test cho bộ phân loại.

    Đây là phần logic "khó" nhất của Phase 1: quyết định một folder có phải
    project code hay không. Mỗi luật (L1..L5) có test riêng, cộng thêm các
    case biên (media chi phối, chỉ có config, folder rỗng).
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    Import-PswTestModule
}

Describe 'Get-PswExtension' {

    It '<Name> -> <Expected>' -ForEach @(
        @{ Name = 'index.js'; Expected = '.js' }
        @{ Name = 'INDEX.JS'; Expected = '.js' }
        @{ Name = 'archive.tar.gz'; Expected = '.gz' }
        @{ Name = 'Makefile'; Expected = '' }
        @{ Name = '.env'; Expected = '' }
        @{ Name = '.gitignore'; Expected = '' }
        @{ Name = 'README.md'; Expected = '.md' }
        @{ Name = 'noext'; Expected = '' }
        @{ Name = 'weird.name.TS'; Expected = '.ts' }
        @{ Name = ''; Expected = '' }
    ) {
        Get-PswExtension $Name | Should -Be $Expected
    }
}

Describe 'Get-PswFileKind' {

    It 'nhận diện file code: <Name>' -ForEach @(
        @{ Name = 'main.rs' }, @{ Name = 'app.py' }, @{ Name = 'index.tsx' }
        @{ Name = 'Server.java' }, @{ Name = 'Program.cs' }, @{ Name = 'main.go' }
        @{ Name = 'deploy.ps1' }, @{ Name = 'schema.sql' }, @{ Name = 'build.gradle' }
        @{ Name = 'view.vue' }, @{ Name = 'lib.kt' }, @{ Name = 'app.ex' }
    ) {
        Get-PswFileKind $Name | Should -Be 'Code'
    }

    It 'nhận diện secret: <Name>' -ForEach @(
        @{ Name = '.env' }, @{ Name = '.env.local' }, @{ Name = '.env.production' }
        @{ Name = 'id_rsa' }, @{ Name = 'id_ed25519' }, @{ Name = '.gitconfig' }
        @{ Name = 'cert.pem' }, @{ Name = 'server.key' }, @{ Name = 'store.pfx' }
        @{ Name = 'credentials.json' }, @{ Name = 'secrets.json' }
        @{ Name = 'kubeconfig' }, @{ Name = 'terraform.tfstate' }
        @{ Name = '.npmrc' }, @{ Name = '.netrc' }
    ) {
        Get-PswFileKind $Name | Should -Be 'Secret'
    }

    It 'nhận diện media: <Name>' -ForEach @(
        @{ Name = 'photo.jpg' }, @{ Name = 'video.mp4' }, @{ Name = 'doc.pdf' }
        @{ Name = 'song.mp3' }, @{ Name = 'icon.svg' }, @{ Name = 'IMG_1234.HEIC' }
    ) {
        Get-PswFileKind $Name | Should -Be 'Media'
    }

    It 'nhận diện binary/build artifact: <Name>' -ForEach @(
        @{ Name = 'app.exe' }, @{ Name = 'lib.dll' }, @{ Name = 'archive.zip' }
        @{ Name = 'Foo.class' }, @{ Name = 'data.sqlite' }, @{ Name = 'lib.a' }
    ) {
        Get-PswFileKind $Name | Should -Be 'Binary'
    }

    It 'nhận diện config (yếu): <Name>' -ForEach @(
        @{ Name = 'package.json' }, @{ Name = 'config.yml' }, @{ Name = 'app.toml' }
        @{ Name = 'settings.ini' }, @{ Name = 'web.xml' }
    ) {
        Get-PswFileKind $Name | Should -Be 'Config'
    }

        It 'file rlib duoc coi la binary' {
            Get-PswFileKind 'libfoo.rlib' | Should -Be 'Binary'
        }

        It 'còn lại là Other: <Name>' -ForEach @(
        @{ Name = 'readme' }, @{ Name = 'NOTES.txt' }, @{ Name = 'LICENSE' }
        @{ Name = '' }
    ) {
        Get-PswFileKind $Name | Should -Be 'Other'
    }

    It 'secret thắng code: file .env không bị coi là code dù extension lạ' {
        Get-PswFileKind '.env' | Should -Be 'Secret'
    }

    It 'không phân biệt hoa thường với extension' {
        Get-PswFileKind 'MAIN.PY' | Should -Be 'Code'
        Get-PswFileKind 'CERT.PEM' | Should -Be 'Secret'
    }
}

Describe 'New-PswFolderProfile + Add-PswChildToProfile' {

    It 'đếm đúng từng loại file' {
        $profile = New-PswFolderProfile -Path 'C:\fake'
        foreach ($name in @('a.js', 'b.py', 'photo.jpg', 'app.exe', 'package.json', 'notes.txt')) {
            Add-PswChildToProfile -Profile $profile -Info ([PSCustomObject]@{
                    Name       = $name
                    Attributes = [System.IO.FileAttributes]::Normal
                })
        }

        $profile.CodeFiles | Should -Be 2
        $profile.MediaFiles | Should -Be 1
        $profile.BinaryFiles | Should -Be 1
        $profile.ConfigFiles | Should -Be 1
        $profile.OtherFiles | Should -Be 1
        $profile.TotalFiles | Should -Be 6
    }

    It 'ghi nhận marker từ cả file và folder' {
        $profile = New-PswFolderProfile -Path 'C:\fake'
        Add-PswChildToProfile -Profile $profile -Info ([PSCustomObject]@{
                Name = '.git'; Attributes = [System.IO.FileAttributes]::Directory
            })
        Add-PswChildToProfile -Profile $profile -Info ([PSCustomObject]@{
                Name = 'package.json'; Attributes = [System.IO.FileAttributes]::Normal
            })

        $profile.Markers.Count | Should -Be 2
        $profile.SubDirs | Should -Be 1
        $profile.TotalFiles | Should -Be 1
    }

    It 'không đếm trùng marker' {
        $profile = New-PswFolderProfile -Path 'C:\fake'
        Add-PswChildToProfile -Profile $profile -Info ([PSCustomObject]@{
                Name = 'package.json'; Attributes = [System.IO.FileAttributes]::Normal
            })
        Add-PswChildToProfile -Profile $profile -Info ([PSCustomObject]@{
                Name = 'package.json'; Attributes = [System.IO.FileAttributes]::Normal
            })
        $profile.Markers.Count | Should -Be 1
    }
}

Describe 'Get-PswFolderKind' {

    It 'L1: có marker thi Project bat ke noi dung' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.Markers.Add('.git')
        $profile.MediaFiles = 100
        $profile.TotalFiles = 100

        $verdict = Get-PswFolderKind -Profile $profile
        $verdict.Kind | Should -Be 'Project'
    }

    It 'L2: tu 2 file code va ti le tu 30 phan tram thi la Project' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.CodeFiles = 3
        $profile.OtherFiles = 7
        $profile.TotalFiles = 10

        (Get-PswFolderKind -Profile $profile).Kind | Should -Be 'Project'
    }

    It 'L2: code duoi 30 phan tram va khong co marker thi roi xuong luat khac' {
        # 1 code / 10 file = 10%, không có marker -> L4 vẫn cho Project (yếu).
        # Điều quan trọng: KHÔNG bị nhầm thành MediaHeavy khi không có media.
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.CodeFiles = 1
        $profile.OtherFiles = 9
        $profile.TotalFiles = 10

        (Get-PswFolderKind -Profile $profile).Kind | Should -Be 'Project'
    }

    It 'L3: media chiem uu the (tu 80 phan tram, tu 5 file) va toi da 1 code thi la MediaHeavy' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.MediaFiles = 9
        $profile.CodeFiles = 1
        $profile.TotalFiles = 10

        (Get-PswFolderKind -Profile $profile).Kind | Should -Be 'MediaHeavy'
    }

    It 'L3: media chiem uu the nhung tu 2 code thi van la Project' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.MediaFiles = 8
        $profile.CodeFiles = 2
        $profile.TotalFiles = 10

        (Get-PswFolderKind -Profile $profile).Kind | Should -Be 'Project'
    }

    It 'L3: ít hơn 5 file media thì không coi là media-heavy' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.MediaFiles = 3
        $profile.TotalFiles = 3

        $verdict = Get-PswFolderKind -Profile $profile
        $verdict.Kind | Should -Be 'Skip'
    }

    It 'L4: dung 1 file code va khong co media thi la Project' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.CodeFiles = 1
        $profile.OtherFiles = 5
        $profile.TotalFiles = 6

        (Get-PswFolderKind -Profile $profile).Kind | Should -Be 'Project'
    }

    It 'L5: folder rong thi la Skip' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        (Get-PswFolderKind -Profile $profile).Kind | Should -Be 'Skip'
    }

    It 'L5: chi co config va binary, khong co code thi la Skip' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.ConfigFiles = 3
        $profile.BinaryFiles = 2
        $profile.TotalFiles = 5

        (Get-PswFolderKind -Profile $profile).Kind | Should -Be 'Skip'
    }

    It 'luôn trả về Reasons không rỗng' {
        $profile = New-PswFolderProfile -Path 'C:\x'
        (Get-PswFolderKind -Profile $profile).Reasons.Count | Should -BeGreaterThan 0
    }

    It 'Kind trả về luôn nằm trong danh sách hợp lệ' -ForEach @(
        @{ Code = 0; Media = 0; Other = 5; Markers = 0; Expected = 'Skip' }
        @{ Code = 5; Media = 0; Other = 0; Markers = 0; Expected = 'Project' }
        @{ Code = 0; Media = 0; Other = 0; Markers = 1; Expected = 'Project' }
        @{ Code = 1; Media = 9; Other = 0; Markers = 0; Expected = 'MediaHeavy' }
    ) {
        $profile = New-PswFolderProfile -Path 'C:\x'
        $profile.CodeFiles = $Code
        $profile.MediaFiles = $Media
        $profile.OtherFiles = $Other
        $profile.TotalFiles = $Code + $Media + $Other
        if ($Markers -gt 0) { $profile.Markers.Add('.git') }

        (Get-PswFolderKind -Profile $profile).Kind | Should -Be $Expected
    }
}

Describe 'Get-PswEntryKindFromName' {

    It 'folder dev tra ve DevDir' {
        Get-PswEntryKindFromName -Name 'node_modules' -IsDirectory | Should -Be 'DevDir'
        Get-PswEntryKindFromName -Name 'target' -IsDirectory | Should -Be 'DevDir'
        Get-PswEntryKindFromName -Name '.venv' -IsDirectory | Should -Be 'DevDir'
    }

    It 'folder secret tra ve Secret' {
        Get-PswEntryKindFromName -Name '.ssh' -IsDirectory | Should -Be 'Secret'
        Get-PswEntryKindFromName -Name '.aws' -IsDirectory | Should -Be 'Secret'
    }

    It 'file secret tra ve Secret' {
        Get-PswEntryKindFromName -Name '.env' | Should -Be 'Secret'
    }

    It 'file code tra ve CodeFile' {
        Get-PswEntryKindFromName -Name 'main.rs' | Should -Be 'CodeFile'
    }

    It 'file thuong tra ve Skip' {
        Get-PswEntryKindFromName -Name 'photo.jpg' | Should -Be 'Skip'
        Get-PswEntryKindFromName -Name 'notes.txt' | Should -Be 'Skip'
    }

    It 'folder khong ro tra ve null (can profile chi tiet)' {
        Get-PswEntryKindFromName -Name 'my_folder' -IsDirectory | Should -BeNullOrEmpty
    }
}
