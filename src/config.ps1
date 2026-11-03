#Requires -Version 5.1
<#
    config.ps1 - Toàn bộ hằng số của presale-wiper.

    Quy ước:
      * Mọi danh sách so khớp theo kiểu không phân biệt hoa/thường.
      * Extension luôn lowercase và bắt đầu bằng dấu chấm.
      * Test trong tests/Unit/Config.Tests.ps1 sẽ fail nếu có phần tử trùng
        hoặc sai format -> đây là "hợp đồng" của file này.
#>

Set-StrictMode -Version Latest

function Initialize-PswConfig {
    [CmdletBinding()]
    param()

    # ---------------------------------------------------------------------
    # 1. Extension được coi là "source code"
    # ---------------------------------------------------------------------
    $codeExtensions = @(
        # JVM / Android
        '.java', '.kt', '.kts', '.scala', '.groovy', '.clj', '.cljs'
        # .NET
        '.cs', '.csx', '.fs', '.fsx', '.vb'
        # C / C++ / hệ thống
        '.c', '.h', '.cc', '.cpp', '.cxx', '.hpp', '.hh', '.hxx', '.m', '.mm'
        '.rs', '.go', '.zig', '.nim', '.d', '.v'
        # Web
        '.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx', '.mts', '.cts'
        '.vue', '.svelte', '.astro', '.html', '.htm'
        '.css', '.scss', '.sass', '.less'
        # Script / data science
        '.py', '.pyw', '.pyi', '.ipynb'
        '.rb', '.php', '.pl', '.pm', '.lua', '.r', '.jl'
        '.ex', '.exs', '.erl', '.hrl', '.hs', '.lhs'
        '.sol', '.move', '.cairo'
        '.sh', '.bash', '.zsh', '.fish', '.ps1', '.psm1', '.psd1'
        '.bat', '.cmd', '.awk', '.tcl'
        # Query / schema / contract
        '.sql', '.graphql', '.gql', '.proto', '.thrift', '.avsc'
        # Build
        '.gradle', '.cmake', '.mk', '.bzl', '.nix', '.tf', '.hcl'
    )

    # Extension cấu hình "yếu": chỉ dùng để đếm tỉ lệ, KHÔNG tự nó biến
    # một folder thành "có code".
    $weakConfigExtensions = @(
        '.json', '.jsonc', '.json5', '.yaml', '.yml', '.toml', '.ini', '.conf'
        '.xml', '.properties', '.plist', '.env', '.cfg', '.editorconfig'
    )

    # Media / tài liệu: dùng cho luật "folder bị media chi phối thì bỏ qua"
    $mediaExtensions = @(
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.tif', '.tiff'
        '.heic', '.heif', '.raw', '.cr2', '.nef', '.arw', '.dng', '.svg', '.ico'
        '.mp4', '.mov', '.avi', '.mkv', '.wmv', '.flv', '.webm', '.m4v', '.mpg', '.mpeg'
        '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a', '.wma', '.opus'
        '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.odt', '.ods', '.epub'
    )

    # Archive / binary: không tính vào media cũng không tính vào code
    $binaryExtensions = @(
        '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.zst'
        '.iso', '.img', '.vhd', '.vhdx', '.bin', '.exe', '.dll', '.msi'
        # Rust build artifacts
        '.pdb', '.lib', '.so', '.dylib', '.o', '.obj', '.class', '.jar', '.war'
        '.rlib', '.rmeta', '.a'
        '.pyc', '.pyo', '.lock', '.db', '.sqlite', '.sqlite3', '.dat', '.pck'
    )

    # ---------------------------------------------------------------------
    # 2. Dấu hiệu nhận biết một folder là project
    # ---------------------------------------------------------------------
    # 2a. Marker so khớp chính xác theo tên file/folder
    $projectMarkerNames = @(
        '.git', '.hg', '.svn'
        'package.json', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lockb'
        'Cargo.toml', 'Cargo.lock'
        'go.mod', 'go.sum'
        'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile', 'poetry.lock', 'uv.lock'
        'pom.xml', 'build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts'
        'Gemfile', 'Gemfile.lock', 'Rakefile'
        'composer.json', 'composer.lock'
        'mix.exs', 'Package.swift', 'pubspec.yaml', 'pubspec.lock'
        'deno.json', 'deno.jsonc'
        'tsconfig.json', 'jsconfig.json'
        'vite.config.js', 'vite.config.ts', 'vite.config.mjs'
        'next.config.js', 'next.config.mjs', 'next.config.ts'
        'nuxt.config.js', 'nuxt.config.ts'
        'svelte.config.js', 'astro.config.mjs', 'angular.json'
        'webpack.config.js', 'rollup.config.js', 'esbuild.config.js'
        'CMakeLists.txt', 'meson.build', 'configure.ac', 'Makefile'
        '.editorconfig', '.tool-versions', '.nvmrc', '.python-version'
        'docker-compose.yml', 'docker-compose.yaml'
    )

    # 2b. Marker so khớp theo wildcard (thường là project .NET / Xcode / JetBrains)
    $projectMarkerPatterns = @(
        '*.sln'
        '*.csproj', '*.fsproj', '*.vbproj', '*.vcxproj', '*.pro', '*.pri'
        '*.xcodeproj', '*.xcworkspace'
        '*.gemspec'
        '*.cabal'
        '*.csproj.user'
        '*.uproject'
    )

    # ---------------------------------------------------------------------
    # 3. Folder rác của dev (báo cáo riêng, không đi vào bên trong)
    # ---------------------------------------------------------------------
    $devDirNames = @(
        'node_modules', 'bower_components', 'jspm_packages'
        '.pnpm-store', '.yarn', '.npm'
        '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache'
        '.ruff_cache', '.tox', '.nox', 'site-packages', '.conda'
        'target', 'build', 'dist', 'out', 'bin', 'obj', 'pkg', 'release'
        '.gradle', '.m2', '.ivy2'
        '.next', '.nuxt', '.svelte-kit', '.astro', '.output', '.vercel'
        '.turbo', '.parcel-cache', '.cache', '.esbuild', '.vite'
        'coverage', '.nyc_output', '.coveralls'
        '.terraform', '.serverless', '.stack-work', 'elm-stuff'
        'cmake-build-debug', 'cmake-build-release'
        '.dart_tool', '.pub-cache', 'Pods', 'DerivedData'
        '.bundle', '.vs', '.idea', 'storybook-static'
        '.angular', '.expo', '.docusaurus', '.vuepress'
    )

    # Folder không bao giờ đi vào (kể cả khi không phải folder dev).
    # QUAN TRỌNG: 'node_modules' KHÔNG nằm ở đây dù nó cũng là folder dev -
    # nếu để ở đây thì node_modules mồ côi (nằm ngoài project) sẽ bị bỏ qua
    # và không bao giờ được báo cáo.
    $skipDirNames = @(
        '.git', '.hg', '.svn'
        '$Recycle.Bin', 'System Volume Information'
        'AppData', 'Application Data', 'Local Settings'
        'Windows', 'Windows.old', 'Program Files', 'Program Files (x86)'
        'ProgramData', 'Config.Msi', 'Recovery', 'PerfLogs', 'Boot'
        'OneDrive'
    )

    # ---------------------------------------------------------------------
    # 4. Secret
    # ---------------------------------------------------------------------
    $secretFileNames = @(
        '.env', '.netrc', '.npmrc', '.pypirc', '.git-credentials', '.gitconfig'
        '.pgpass', '.my.cnf', '.msmtprc', '.vault-token', '.gem/credentials'
        'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519'
        'credentials', 'credentials.json', 'secrets.json', 'secret.json'
        'kubeconfig', 'terraform.tfstate', 'htpasswd'
    )

    $secretFilePatterns = @(
        '.env.*'
        '*.pem', '*.key', '*.pfx', '*.p12', '*.jks', '*.keystore', '*.kdbx'
        '*.ppk', '*.asc', '*.ovpn'
        'id_*'
        '*.tfstate.backup'
        '*credentials*.json'
        '*serviceaccount*.json'
    )

    $secretDirNames = @(
        '.ssh', '.gnupg', '.aws', '.azure', '.kube', '.password-store'
        '.docker', '.config'
    )

    # ---------------------------------------------------------------------
    # 5. Vùng cấm (safety/guard.ps1 dùng)
    # ---------------------------------------------------------------------
    # 5a. Tên folder bị cấm tuyệt đối ở bất kỳ độ sâu nào
    $neverTouchNames = @(
        '$Recycle.Bin', 'System Volume Information', 'Config.Msi'
        'Recovery', 'PerfLogs', 'Boot', 'Windows.old'
        'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData'
        'WindowsApps', 'Microsoft.NET'
    )

    # 5b. Folder người dùng: KHÔNG xoá chính nó, nhưng được phép dọn bên trong
    $shellFolderNames = @(
        'Desktop', 'Documents', 'My Documents', 'Downloads'
        'Pictures', 'My Pictures', 'Music', 'My Music', 'Videos', 'My Videos'
        'Favorites', 'Links', 'Searches', 'Contacts', 'Saved Games'
        'OneDrive', 'AppData', 'Application Data', 'Local Settings'
        '3D Objects', 'PrintHood', 'SendTo', 'Templates'
    )

    # ---------------------------------------------------------------------
    # 6. Ngưỡng / mặc định
    # ---------------------------------------------------------------------
    $defaults = @{
        # Độ sâu tối đa tính từ mỗi root. Đặt rộng vì project thật thường
        # nằm sâu (Documents\Projects\client\repo\src); chốt chặn thật sự là
        # MaxEntriesVisited bên dưới.
        MaxDepth              = 10
        # Folder chỉ bị coi là "media-heavy" khi có tối thiểu ngần này file
        MediaVoteMinFiles     = 5
        # ...và tỉ lệ media >= ngưỡng này
        MediaDominanceRatio   = 0.8
        # Chỉ báo cáo entry >= ngưỡng này (mặc định 0 = báo tất cả)
        MinSizeBytes          = 0L
        # Trần an toàn: số entry filesystem tối đa được duyệt trong 1 lần scan
        MaxEntriesVisited     = 750000
        # Log rotate khi vượt ngưỡng này
        LogRotateBytes        = 10MB
        # Khi xoá: số lần thử lại
        DeleteRetryCount      = 3
        # WSL unregister timeout (Phase 3)
        WslTimeoutSeconds     = 120
        # Tên file log mặc định
        DefaultLogName        = 'presale-wiper.log'
    }

    # ---------------------------------------------------------------------
    # 7. Các vị trí dev hay gặp (dùng khi user không truyền path)
    # ---------------------------------------------------------------------
    $homeDir = [Environment]::GetFolderPath('UserProfile')

    $relativeDevPaths = @(
        'source\repos', 'source', 'repos', 'Projects', 'projects', 'Developer'
        'dev', 'code', 'Code', 'workspace', 'Workspace', 'git', 'Git'
        'Documents\Projects', 'Documents\Source', 'Documents\GitHub'
        'OneDrive\Documents\Projects'
    )

    $devRootNamesAtDriveRoot = @(
        'Projects', 'Source', 'repos', 'Repos', 'Dev', 'Code', 'Workspace', 'git'
    )

    # Gom lại thành $script:PswConfig (chỉ đọc, không sửa lúc chạy)
    $script:PswConfig = @{
        CodeExtensions          = $codeExtensions
        WeakConfigExtensions    = $weakConfigExtensions
        MediaExtensions         = $mediaExtensions
        BinaryExtensions        = $binaryExtensions
        ProjectMarkerNames      = $projectMarkerNames
        ProjectMarkerPatterns   = $projectMarkerPatterns
        DevDirNames             = $devDirNames
        SkipDirNames            = $skipDirNames
        SecretFileNames         = $secretFileNames
        SecretFilePatterns      = $secretFilePatterns
        SecretDirNames          = $secretDirNames
        NeverTouchNames         = $neverTouchNames
        ShellFolderNames        = $shellFolderNames
        Defaults                = $defaults
        HomeDir                 = $homeDir
        RelativeDevPaths        = $relativeDevPaths
        DevRootNamesAtDriveRoot = $devRootNamesAtDriveRoot
    }

    # Bộ tra cứu nhanh (HashSet, không phân biệt hoa/thường)
    $script:PswLookup = @{
        CodeExtensions   = New-PswLookupSet $codeExtensions
        WeakConfigExtensions = New-PswLookupSet $weakConfigExtensions
        MediaExtensions  = New-PswLookupSet $mediaExtensions
        BinaryExtensions = New-PswLookupSet $binaryExtensions
        ProjectMarkers   = New-PswLookupSet $projectMarkerNames
        DevDirNames      = New-PswLookupSet $devDirNames
        SkipDirNames     = New-PswLookupSet $skipDirNames
        SecretFileNames  = New-PswLookupSet $secretFileNames
        SecretDirNames   = New-PswLookupSet $secretDirNames
        NeverTouchNames  = New-PswLookupSet $neverTouchNames
        ShellFolderNames = New-PswLookupSet $shellFolderNames
    }

    Reset-PswSizeCache

    return $script:PswConfig
}

function New-PswLookupSet {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([string[]]$Items)

    # Dùng ::new() thay New-Object: New-Object không nhận comparer đúng cách
    # khi chỉ có một tham số, khiến set trở thành case-sensitive.
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Items) {
        foreach ($item in $Items) {
            if (-not [string]::IsNullOrWhiteSpace($item)) { [void]$set.Add($item) }
        }
    }
    # Dấu ',' để trả về NGUYÊN set: nếu trả trực tiếp, PowerShell sẽ enumerate
    # hashset thành object[] và mất khả năng Contains(case-insensitive).
    return , $set
}

function Get-PswConfig {
    <#
        .SYNOPSIS
        Trả về bảng cấu hình đã khởi tạo (chỉ đọc).
    #>
    [CmdletBinding()]
    param([string]$Section)

    if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }

    if ([string]::IsNullOrEmpty($Section)) { return $script:PswConfig }
    if (-not $script:PswConfig.ContainsKey($Section)) {
        throw "Không có section cấu hình '$Section'."
    }
    return $script:PswConfig[$Section]
}

function Get-PswLookup {
    <#
        .SYNOPSIS
        Trả về HashSet tra cứu nhanh theo tên nhóm.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if ($null -eq $script:PswLookup) { Initialize-PswConfig | Out-Null }
    if (-not $script:PswLookup.ContainsKey($Name)) {
        throw "Không có lookup '$Name'."
    }
    # Dấu ',' giữ nguyên HashSet: nếu không, PowerShell enumerate nó thành
    # object[] và mất .Contains() (case-insensitive) ở phía người gọi.
    return , $script:PswLookup[$Name]
}

function Get-PswDefault {
    <#
        .SYNOPSIS
        Lấy một giá trị mặc định trong $PswConfig.Defaults.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if ($null -eq $script:PswConfig) { Initialize-PswConfig | Out-Null }
    $defaults = $script:PswConfig.Defaults
    if (-not $defaults.ContainsKey($Name)) { throw "Không có mặc định '$Name'." }
    return $defaults[$Name]
}
