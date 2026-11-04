<# : batch
@echo off
rem presale-wiper: quet TOAN BO PC va XOA LUON nhung gi tim thay.
chcp 65001 >nul
set "PSW_SELF=%~f0"
set "PSW_OPEN_RESULT=0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". ([ScriptBlock]::Create([IO.File]::ReadAllText($env:PSW_SELF, [Text.Encoding]::UTF8))) %*"
echo.
echo Da xong. Cua so se tu dong sau 10 giay.
rem 'ping' thay cho 'timeout': timeout loi ngay khi stdin bi redirect
rem (vd khi chay tu script khac), con ping thi khong doc stdin.
ping -n 11 127.0.0.1 >nul
exit /b
#>
<#
.SYNOPSIS
    Quét PC và XOÁ LUÔN những file rác dev tìm thấy. Chạy là xoá, không hỏi.

.DESCRIPTION
    Script độc lập, tự chứa: không import module, không cần Pester, không cần
    quyền admin.

    Nó làm bốn việc:
      1. Duyệt các thư mục dev, phân loại từng mục (project / rác dev / secret).
      2. Bung mỗi mục ra thành DANH SÁCH FILE cụ thể.
      3. Ghi ra báo cáo và in bảng tổng kết.
      4. XOÁ VĨNH VIỄN các file đó (không vào Thùng rác), rồi dọn thư mục rỗng.

    XOÁ LÀ KHÔNG HOÀN TÁC ĐƯỢC. Muốn xem trước thì chạy với -DryRun.
    Muốn tự tay xoá theo danh sách thì dùng -NoDelete rồi chạy remove-once.ps1.

    Bộ guard vẫn giữ: không bao giờ xoá gốc ổ, C:\Windows, C:\Boot,
    Program Files, ProgramData, AppData, thư mục người dùng (Desktop,
    Documents, Downloads...), hay chính thư mục của công cụ này.

.PARAMETER Path
    Thư mục cần quét. Bỏ trống thì quét TOÀN BỘ PC: gốc mọi ổ cố định (C:\, D:\,
    ...). Tự bỏ qua Windows, Program Files, ProgramData, AppData, thùng rác,
    toolchain/game/driver ở gốc ổ (C:\Python312, D:\SteamLibrary, ...) và thư
    mục phần mềm đã cài (có .exe/.dll). Không quét USB / ổ mạng.

.PARAMETER MinSize
    Chỉ liệt kê mục >= kích thước này. Nhận '100MB', '1.5GB', hoặc số byte.

.PARAMETER MaxDepth
    Độ sâu tối đa tính từ mỗi root. Mặc định 10.

.PARAMETER Kind
    Chỉ lấy các loại này. Mặc định: Project, DevDir, Secret, CodeFile, IdeHistory.
    IdeHistory = lịch sử project của IDE (VS Code, Cursor, JetBrains, Sublime,
    SSMS, ...) và danh sách file/thư mục gần đây của Windows. Xoá các mục này
    thì project đã xoá không còn hiện lại trong menu "Recent / Open Recent".

.PARAMETER OutDir
    Nơi ghi kết quả. Mặc định: %USERPROFILE%\presale-scan-<timestamp>

.PARAMETER MaxFilesPerTarget
    Trần số file liệt kê cho mỗi mục. 0 = không giới hạn (mặc định). Với
    node_modules rất lớn, đặt số cụ thể (vd 50000) để tránh tốn RAM.

.PARAMETER DevFoldersOnly
    Không quét toàn bộ PC, chỉ quét các thư mục dev quen thuộc
    (source\repos, Projects, Developer, D:\Projects, ...). Nhanh hơn nhưng dễ bỏ sót.

.PARAMETER IncludeHome
    Giữ để tương thích, không còn tác dụng (home đã được quét mặc định).

.PARAMETER DryRun
    Chỉ in danh sách, KHÔNG xoá. Bỏ trống thì chạy là xoá luôn.

.PARAMETER NoDelete
    Như -DryRun: quét, ghi báo cáo, không xoá.

.PARAMETER AskDelete
    Giữ để tương thích lệnh cũ, không còn tác dụng.

.PARAMETER Quiet
    Chỉ in tổng kết, không in bảng chi tiết.

.EXAMPLE
    .\scan-once.ps1

.EXAMPLE
    .\scan-once.ps1 -Path 'D:\OldProjects' -MinSize 10MB

.EXAMPLE
    .\scan-once.ps1 -Kind Secret

.NOTES
    Chỉ đọc. Không sửa, không xoá, không đổi quyền file.
    Exit code: 0 = xong, 2 = tham số/lỗi nghiêm trọng.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path = @(),

    [string]$MinSize,

    [int]$MaxDepth = 10,

    [ValidateSet('Project', 'DevDir', 'Secret', 'CodeFile', 'IdeHistory', 'All')]
    [string[]]$Kind = @('Project', 'DevDir', 'Secret', 'CodeFile', 'IdeHistory'),

    [string]$OutDir,

    [int]$MaxFilesPerTarget = 0,

    [switch]$DevFoldersOnly,

    [switch]$IncludeHome,

    # Chạy là xoá luôn: không cần xác nhận. Hai công tắc dưới để xem trước.
    [switch]$DryRun,

    [switch]$NoDelete,

    # Giữ lại cho tương thích lệnh cũ; không còn tác dụng.
    [switch]$AskDelete,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# 0. Ranh giới trách nhiệm
# =============================================================================
# File này quét và gọi remove-once.ps1 để xoá. Mọi lệnh xoá thật nằm ở
# remove-once.ps1 (xoá dưới đây chỉ là danh sách cần xoá, không xoá trực tiếp).
# Bộ guard chặn đường dẫn hệ thống nằm ở cả hai file.

$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss'

# Console mặc định dùng codepage OEM (437/850) nên tiếng Việt thành '?'.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

# =============================================================================
# 1. Hằng số
# =============================================================================

$script:CodeExtensions = @(
    '.java', '.kt', '.kts', '.scala', '.groovy', '.clj', '.cljs'
    '.cs', '.csx', '.fs', '.fsx', '.vb'
    '.c', '.h', '.cc', '.cpp', '.cxx', '.hpp', '.hh', '.hxx', '.m', '.mm'
    '.rs', '.go', '.zig', '.nim', '.d', '.v'
    '.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx', '.mts', '.cts'
    '.vue', '.svelte', '.astro', '.html', '.htm'
    '.css', '.scss', '.sass', '.less'
    '.py', '.pyw', '.pyi', '.ipynb'
    '.rb', '.php', '.pl', '.pm', '.lua', '.r', '.jl'
    '.ex', '.exs', '.erl', '.hrl', '.hs', '.lhs'
    '.sol', '.move', '.cairo'
    '.sh', '.bash', '.zsh', '.fish', '.ps1', '.psm1', '.psd1'
    '.bat', '.cmd', '.awk', '.tcl'
    '.sql', '.graphql', '.gql', '.proto', '.thrift', '.avsc'
    '.gradle', '.cmake', '.mk', '.bzl', '.nix', '.tf', '.hcl'
)

$script:WeakConfigExtensions = @(
    '.json', '.jsonc', '.json5', '.yaml', '.yml', '.toml', '.ini', '.conf'
    '.xml', '.properties', '.plist', '.env', '.cfg', '.editorconfig'
)

$script:MediaExtensions = @(
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.tif', '.tiff'
    '.heic', '.heif', '.raw', '.cr2', '.nef', '.arw', '.dng', '.svg', '.ico'
    '.mp4', '.mov', '.avi', '.mkv', '.wmv', '.flv', '.webm', '.m4v', '.mpg'
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a', '.wma', '.opus'
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.odt', '.ods', '.epub'
)

$script:BinaryExtensions = @(
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.zst'
    '.iso', '.img', '.vhd', '.vhdx', '.bin', '.exe', '.dll', '.msi'
    '.pdb', '.lib', '.so', '.dylib', '.o', '.obj', '.class', '.jar', '.war'
    '.rlib', '.rmeta', '.a'
    '.pyc', '.pyo', '.lock', '.db', '.sqlite', '.sqlite3', '.dat', '.pck'
)

$script:ProjectMarkerNames = @(
    '.git', '.hg', '.svn'
    'package.json', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lockb'
    'Cargo.toml', 'Cargo.lock'
    'go.mod', 'go.sum'
    'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile'
    'poetry.lock', 'uv.lock'
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
    '.tool-versions', '.nvmrc', '.python-version'
    'docker-compose.yml', 'docker-compose.yaml'
)

$script:ProjectMarkerPatterns = @(
    '*.sln', '*.csproj', '*.fsproj', '*.vbproj', '*.vcxproj', '*.pro', '*.pri'
    '*.xcodeproj', '*.xcworkspace', '*.gemspec', '*.cabal', '*.uproject'
)

$script:DevDirNames = @(
    'node_modules', 'bower_components', 'jspm_packages'
    '.pnpm-store', '.yarn'
    '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache'
    '.ruff_cache', '.tox', '.nox', 'site-packages'
    'target', 'dist', 'out', 'obj', 'pkg', '.gradle', '.m2', '.ivy2'
    '.next', '.nuxt', '.svelte-kit', '.astro', '.output', '.vercel'
    '.turbo', '.parcel-cache', '.esbuild', '.vite'
    'coverage', '.nyc_output'
    '.terraform', '.serverless', '.stack-work', 'elm-stuff'
    'cmake-build-debug', 'cmake-build-release'
    '.dart_tool', 'Pods', 'DerivedData'
    '.bundle', '.vs', '.idea', 'storybook-static'
)

$script:SkipDirNames = @(
    '.git', '.hg', '.svn'
    '$Recycle.Bin', 'System Volume Information', 'Config.Msi'
    'AppData', 'Application Data', 'Local Settings'
    'Windows', 'Windows.old', 'Program Files', 'Program Files (x86)'
    'ProgramData', 'Recovery', 'PerfLogs', 'Boot'
    'OneDrive'
    'WindowsPowerShell'
    'WindowsApps', 'WpSystem', '$WinREAgent', '$Windows.~BT', '$Windows.~WS'
    '$SysReset', '$GetCurrent'
)

# Chỉ bỏ qua khi nằm NGAY dưới gốc ổ (C:\Python312, D:\SteamLibrary, ...):
# đó là toolchain/game/driver đã cài, không phải project. Ở chỗ khác, một thư
# mục tên 'tools' hay 'Go' vẫn có thể là code của người dùng.
$script:DriveRootSkipPatterns = @(
    'Intel', 'AMD', 'NVIDIA', 'Drivers', 'MSOCache', 'ESD', 'OneDriveTemp'
    'Windows10Upgrade', 'XboxGames', 'SteamLibrary', 'Steam', 'Epic Games', 'Riot Games', 'Garena'
    'Go', 'flutter', 'Android', 'msys64', 'msys32', 'cygwin', 'cygwin64'
    'MinGW', 'mingw32', 'mingw64', 'Strawberry', 'Qt', 'tools'
    'Python*', 'Ruby*', 'jdk*', 'Perl*', 'Program Files*'
)

# Thư mục đặc biệt trong MỌI profile (C:\Users\<ai đó>\...): chỉ đi vào trong,
# không bao giờ đề xuất cả thư mục.
$script:ProfileContainerNames = @(
    'Desktop', 'Downloads', 'Documents', 'Pictures', 'Music', 'Videos'
    'Favorites', 'Contacts', 'Links', 'Saved Games', 'Searches', '3D Objects', 'OneDrive'
)

# Profile hệ thống dưới C:\Users: không phải người dùng thật.
$script:SystemProfileNames = @('Default', 'Default User', 'All Users', 'defaultuser0')

# Có các file này trực tiếp trong thư mục (mà không có marker project) thì đó
# là phần mềm đã cài / bản portable, không đi vào.
$script:InstalledBinaryExtensions = @('.exe', '.dll', '.sys', '.msi')

$script:SecretFileNames = @(
    '.env', '.netrc', '.npmrc', '.pypirc', '.git-credentials', '.gitconfig'
    '.pgpass', '.my.cnf', '.msmtprc', '.vault-token'
    'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519'
    'credentials', 'credentials.json', 'secrets.json', 'secret.json'
    'kubeconfig', 'terraform.tfstate', 'htpasswd'
)

$script:SecretFilePatterns = @(
    '.env.*', '*.pem', '*.key', '*.pfx', '*.p12', '*.jks', '*.keystore'
    '*.kdbx', '*.ppk', '*.asc', '*.ovpn'
    'id_rsa*', 'id_dsa*', 'id_ecdsa*', 'id_ed25519*'
    '*.tfstate.backup', '*credentials*.json', '*serviceaccount*.json'
)

$script:SecretDirNames = @('.ssh', '.gnupg', '.aws', '.azure', '.kube', '.password-store')

# -----------------------------------------------------------------------------
# Lịch sử project của IDE: nằm trong AppData nên bước quét thường bỏ qua.
#
# NGUYÊN TẮC AN TOÀN: chỉ xoá phần dữ liệu THUỘC VỀ project sắp bị xoá, dựa
# trên metadata mà IDE tự ghi. Tuyệt đối không xoá cả thư mục cấu hình, không
# xoá lịch sử của project người dùng muốn giữ.
#
#   Kind = 'Workspace': mỗi thư mục con là một workspace. Đọc file Manifest
#     trong đó để lấy đường dẫn project; chỉ khi đường dẫn ấy nằm trong phạm vi
#     xoá thì mới đề xuất xoá thư mục con đó.
#   Kind = 'Note'     : chỉ ghi chú, KHÔNG xoá (file cấu hình dùng chung, xoá
#     sẽ mất cài đặt của IDE).
# -----------------------------------------------------------------------------
$script:IdeHistoryEntries = @(
    # VS Code và các bản fork: mỗi workspace có workspace.json trỏ tới project.
    @{ Path = 'AppData\Roaming\Code\User\workspaceStorage'; Kind = 'Workspace'; Manifest = 'workspace.json'; Keys = @('folder', 'workspace'); Label = 'VS Code' }
    # Lịch sử sửa file (local history) cũng chia theo workspace.
    @{ Path = 'AppData\Roaming\Code\User\History'; Kind = 'Workspace'; Manifest = 'entries.json'; Keys = @('resource'); Label = 'VS Code (lịch sử sửa file)' }
    @{ Path = 'AppData\Roaming\Code - Insiders\User\workspaceStorage'; Kind = 'Workspace'; Manifest = 'workspace.json'; Keys = @('folder', 'workspace'); Label = 'VS Code Insiders' }
    @{ Path = 'AppData\Roaming\Cursor\User\workspaceStorage'; Kind = 'Workspace'; Manifest = 'workspace.json'; Keys = @('folder', 'workspace'); Label = 'Cursor' }
    @{ Path = 'AppData\Roaming\Cursor\User\History'; Kind = 'Workspace'; Manifest = 'entries.json'; Keys = @('resource'); Label = 'Cursor (lịch sử sửa file)' }
    @{ Path = 'AppData\Roaming\VSCodium\User\workspaceStorage'; Kind = 'Workspace'; Manifest = 'workspace.json'; Keys = @('folder', 'workspace'); Label = 'VSCodium' }
    @{ Path = 'AppData\Roaming\Windsurf\User\workspaceStorage'; Kind = 'Workspace'; Manifest = 'workspace.json'; Keys = @('folder', 'workspace'); Label = 'Windsurf' }
    @{ Path = 'AppData\Roaming\Trae\User\workspaceStorage'; Kind = 'Workspace'; Manifest = 'workspace.json'; Keys = @('folder', 'workspace'); Label = 'Trae' }
    @{ Path = 'AppData\Roaming\Antigravity\User\workspaceStorage'; Kind = 'Workspace'; Manifest = 'workspace.json'; Keys = @('folder', 'workspace'); Label = 'Antigravity' }

    # JetBrains gom mọi project vào một file XML dùng chung: chỉ báo, không xoá.
    @{ Path = 'AppData\Roaming\JetBrains'; Kind = 'Note'; Label = 'JetBrains' }
)

$script:NeverTouchNames = @('AppData', 'Application Data', 'Local Settings')

# Thư mục hệ thống chỉ cấm ở CẤP GỐC Ổ. So ở mọi cấp sẽ chặn nhầm đường dẫn
# Maven như '...\.m2\repository\org\springframework\boot\...' (có đoạn 'boot').
$script:NeverTouchTopLevelNames = @(
    '$Recycle.Bin', 'System Volume Information', 'Config.Msi'
    'Recovery', 'PerfLogs', 'Boot', 'Windows.old'
    'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData'
)

# Bộ tra cứu không phân biệt hoa/thường
function New-LookupSet {
    param([string[]]$Items)

    # ::new (không phải New-Object) để comparer được áp đúng; 'return ,' để
    # PowerShell không enumerate HashSet thành object[].
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Items) {
        if (-not [string]::IsNullOrWhiteSpace($item)) { [void]$set.Add($item) }
    }
    return , $set
}

function New-WildcardRegex {
    param([string[]]$Patterns)

    $parts = foreach ($pattern in $Patterns) {
        [regex]::Escape($pattern).Replace('\*', '.*').Replace('\?', '.')
    }
    $options = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant, Compiled'
    return [regex]::new('^(?:' + ($parts -join '|') + ')$', $options)
}

$script:SecretRegex = New-WildcardRegex $script:SecretFilePatterns
$script:MarkerRegex = New-WildcardRegex $script:ProjectMarkerPatterns
$script:DotnetManifestRegex = New-WildcardRegex @('*.deps.json', '*.runtimeconfig*.json')
$script:DriveRootSkipRegex = New-WildcardRegex $script:DriveRootSkipPatterns

$script:Lookup = @{
    Code        = New-LookupSet $script:CodeExtensions
    WeakConfig  = New-LookupSet $script:WeakConfigExtensions
    Media       = New-LookupSet $script:MediaExtensions
    Binary      = New-LookupSet $script:BinaryExtensions
    Markers     = New-LookupSet $script:ProjectMarkerNames
    DevDirs     = New-LookupSet $script:DevDirNames
    SkipDirs    = New-LookupSet $script:SkipDirNames
    SecretFiles = New-LookupSet $script:SecretFileNames
    SecretDirs  = New-LookupSet $script:SecretDirNames
    NeverTouch  = New-LookupSet $script:NeverTouchNames
    NeverTouchTopLevel = New-LookupSet $script:NeverTouchTopLevelNames
    ProfileContainers = New-LookupSet $script:ProfileContainerNames
    SystemProfiles    = New-LookupSet $script:SystemProfileNames
    InstalledBinaries = New-LookupSet $script:InstalledBinaryExtensions
}

# =============================================================================
# 2. Đường dẫn (long path)
# =============================================================================

function To-LongPath {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Value.StartsWith('\\?\') -or $Value.StartsWith('\\.\')) { return $Value }

    if ($Value.StartsWith('\\')) { return '\\?\UNC\' + $Value.Substring(2).TrimStart('\') }

    $full = $Value
    if (-not [System.IO.Path]::IsPathRooted($full)) {
        try { $full = [System.IO.Path]::GetFullPath($full) } catch { }
    }
    if ($full -match '^[A-Za-z]:\\{2,}') { $full = $full -replace '\\{2,}', '\' }
    if ($full.Length -gt 3 -and $full.EndsWith('\')) { $full = $full.TrimEnd('\') }

    return '\\?\' + $full
}

function From-LongPath {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.StartsWith('\\?\UNC\')) { return '\\' + $Value.Substring(8) }
    if ($Value.StartsWith('\\?\')) { return $Value.Substring(4) }
    return $Value
}

function Get-NormalizedPath {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $candidate = From-LongPath $Value
    $candidate = [Environment]::ExpandEnvironmentVariables($candidate)

    $home_ = [Environment]::GetFolderPath('UserProfile')
    if ($candidate -eq '~') { $candidate = $home_ }
    elseif ($candidate.StartsWith('~\')) { $candidate = $home_ + '\' + $candidate.Substring(2) }

    if ($candidate -match '^[A-Za-z]:$') { return $candidate + '\' }

    try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { return $null }

    if ($full.Length -gt 3 -and $full.EndsWith('\')) { $full = $full.TrimEnd('\') }
    return $full
}

function Join-PathSafe {
    param([string]$Base, [string]$Child)

    if ([string]::IsNullOrEmpty($Base)) { return $Child }
    if ([string]::IsNullOrEmpty($Child)) { return $Base }
    if ($Child -match '^[A-Za-z]:[\\/]' -or $Child.StartsWith('\\')) { return $Child }

    $prefix = if ($Base.EndsWith('\') -or $Base.EndsWith('/')) { $Base } else { $Base + '\' }
    return $prefix + $Child.TrimStart('\', '/')
}

function Test-PathExists {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try {
        $long = To-LongPath $Value
        if ([System.IO.Directory]::Exists($long)) { return $true }
        return [System.IO.File]::Exists($long)
    } catch { return $false }
}

function Test-PathUnder {
    param([string]$Candidate, [string]$Parent)

    $a = Get-NormalizedPath $Candidate
    $b = Get-NormalizedPath $Parent
    if ($null -eq $a -or $null -eq $b) { return $false }
    if ([string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    $prefix = if ($b.EndsWith('\')) { $b } else { $b + '\' }
    return $a.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ChildInfos {
    <#
        Liệt kê con trực tiếp. Không ném lỗi; trả mảng (có thể rỗng).
    #>
    param([string]$Value)

    $result = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    try {
        $info = New-Object System.IO.DirectoryInfo (To-LongPath $Value)
        if ($info.Exists) {
            foreach ($child in $info.EnumerateFileSystemInfos()) { [void]$result.Add($child) }
        }
    } catch { }
    return $result.ToArray()
}

function Get-ExtensionOf {
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return '' }
    $dot = $Name.LastIndexOf('.')
    if ($dot -lt 1) { return '' }
    return $Name.Substring($dot).ToLowerInvariant()
}

function Format-Size {
    param([long]$Bytes)

    if ($Bytes -lt 0) { return '0 B' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }
    if ($index -eq 0) { return ('{0} B' -f $Bytes) }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F1} {1}', $value, $units[$index])
}

function ConvertTo-Bytes {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()

    if ($trimmed -match '^\d+$') {
        $plain = 0L
        if ([long]::TryParse($trimmed, [ref]$plain)) { return $plain }
        return $null
    }
    if ($trimmed -notmatch '^(?<v>\d+(?:[.,]\d+)?)\s*(?<u>[KMGTP]?)(?:i?B)?$') { return $null }

    $number = [double]::Parse(($matches['v'] -replace ',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
    $power = switch ($matches['u'].ToUpperInvariant()) {
        'K' { 1 } 'M' { 2 } 'G' { 3 } 'T' { 4 } 'P' { 5 } default { 0 }
    }
    return [long]($number * [Math]::Pow(1024, $power))
}

function Write-Green {
    param([string]$Text)
    $previous = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = [ConsoleColor]::Green
        [Console]::Out.WriteLine($Text)
    } finally {
        [Console]::ForegroundColor = $previous
    }
}

function Write-Stdout {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
}

function Write-Failure {
    param([string]$Text)

    Write-Stdout $Text
    # presale-scan.cmd chạy ẩn (PSW_HIDDEN=1): không có console nên báo lỗi bằng hộp thoại.
    if ($env:PSW_HIDDEN -eq '1') {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($Text, 'presale-wiper scan')
        } catch { }
    }
}

# =============================================================================
# 3. Guard: mục nào tuyệt đối không được liệt kê để xoá
# =============================================================================

function Get-ForbiddenRoots {
    $list = New-Object 'System.Collections.Generic.List[string]'

    foreach ($name in @('SystemRoot', 'windir', 'ProgramFiles', 'ProgramFiles(x86)',
            'ProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'USERPROFILE')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $list.Add($value) }
    }

    foreach ($name in @('Desktop', 'MyDocuments', 'MyPictures', 'MyMusic', 'MyVideos',
            'ApplicationData', 'LocalApplicationData', 'UserProfile')) {
        try {
            $value = [Environment]::GetFolderPath($name)
            if (-not [string]::IsNullOrWhiteSpace($value)) { $list.Add($value) }
        } catch { }
    }

    # Environment.SpecialFolder không có Downloads/Saved Games/... nên lấy từ
    # registry, kèm tên mặc định phòng khi bị chuyển chỗ.
    $profileDir = [Environment]::GetFolderPath('UserProfile')
    if (-not [string]::IsNullOrWhiteSpace($profileDir)) {
        foreach ($name in @('Downloads', 'Desktop', 'Documents', 'Pictures', 'Music', 'Videos',
                'Favorites', 'Contacts', 'Links', 'Saved Games', 'Searches', '3D Objects', 'OneDrive')) {
            $list.Add((Join-PathSafe $profileDir $name))
        }
    }
    try {
        $shellFolders = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop
        foreach ($property in $shellFolders.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }
            $value = [string]$property.Value
            if ($value -match '^[A-Za-z]:\\') { $list.Add($value) }
        }
    } catch { }

    $systemDrive = [Environment]::GetEnvironmentVariable('SystemDrive')
    if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = 'C:' }
    foreach ($name in @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
            'Users', 'PerfLogs', 'Recovery', 'Boot', '$Recycle.Bin',
            'System Volume Information', 'Config.Msi', 'Windows.old')) {
        $list.Add("$systemDrive\$name")
    }

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $list) {
        $full = Get-NormalizedPath $item
        if ($null -ne $full) { [void]$set.Add($full.TrimEnd('\')) }
    }
    return , @($set)
}

$script:ForbiddenRoots = Get-ForbiddenRoots
$script:ForbiddenLookup = New-LookupSet $script:ForbiddenRoots
# Desktop, Downloads, Documents, ... : không bao giờ đề xuất cả thư mục, chỉ
# đi vào trong để xét từng mục con (Invoke-Scan tra $script:ForbiddenLookup).
$script:UserProfileDir = Get-NormalizedPath ([Environment]::GetFolderPath('UserProfile'))

function Get-BlockReason {
    <#
        Trả về lý do KHÔNG được đề xuất xoá, hoặc $null nếu ổn.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Đường dẫn rỗng.' }

    $full = Get-NormalizedPath $Value
    if ($null -eq $full) { return 'Đường dẫn không hợp lệ.' }

    if ($full -match '^[A-Za-z]:\\?$') { return 'Gốc ổ đĩa.' }

    foreach ($root in $script:ForbiddenRoots) {
        if ([string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) {
            return "Là thư mục hệ thống/người dùng: $root"
        }
    }

    $segments = @($full.Split('\') | Where-Object { $_ -ne '' })

    # AppData: cấm ở MỌI cấp (lịch sử IDE được xử lý riêng, có cho phép tường minh).
    foreach ($segment in $segments) {
        if ($script:Lookup.NeverTouch.Contains($segment)) {
            return "Nằm trong thư mục cấm '$segment'."
        }
    }

    # Thư mục hệ thống: chỉ cấm ở CẤP GỐC Ổ (C:\Windows, C:\Boot, ...).
    if ($segments.Count -gt 1 -and $script:Lookup.NeverTouchTopLevel.Contains($segments[1])) {
        return "Chứa thư mục cấm '$($segments[1])'."
    }

    foreach ($name in @('LocalApplicationData', 'ApplicationData')) {
        try {
            $appData = [Environment]::GetFolderPath($name)
            if ([string]::IsNullOrWhiteSpace($appData)) { continue }
            if (Test-PathUnder -Candidate $full -Parent $appData) { return 'Nằm trong AppData.' }
        } catch { }
    }

    return $null
}

# =============================================================================
# 4. Phân loại
# =============================================================================

function Get-FileKind {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Other' }

    if ($script:Lookup.SecretFiles.Contains($Name)) { return 'Secret' }
    if ($script:SecretRegex.IsMatch($Name) -and -not $script:DotnetManifestRegex.IsMatch($Name)) { return 'Secret' }

    # Các HashSet đều OrdinalIgnoreCase nên không cần ToLower.
    $dot = $Name.LastIndexOf('.')
    if ($dot -ge 1) {
        $ext = $Name.Substring($dot)
        if ($script:Lookup.Code.Contains($ext)) { return 'Code' }
        if ($script:Lookup.Media.Contains($ext)) { return 'Media' }
        if ($script:Lookup.Binary.Contains($ext)) { return 'Binary' }
        if ($script:Lookup.WeakConfig.Contains($ext)) { return 'Config' }
    }
    return 'Other'
}

function Test-ProjectMarker {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($script:Lookup.Markers.Contains($Name)) { return $true }
    if ($script:MarkerRegex.IsMatch($Name)) { return $true }
    return $false
}

function Get-FolderVerdict {
    <#
        Từ danh sách con trực tiếp -> kết luận folder có phải project không.
    #>
    param([System.IO.FileSystemInfo[]]$Children)

    $markers = 0
    $code = 0
    $media = 0
    $total = 0

    # Gọi hàm trên PS 5.1 tốn vài chục µs mỗi lần, nên vòng này tự phân loại
    # thay vì gọi Test-ProjectMarker / Get-FileKind cho từng file.
    $dirFlag = [int][System.IO.FileAttributes]::Directory
    $markerSet = $script:Lookup.Markers
    $markerRegex = $script:MarkerRegex
    $secretSet = $script:Lookup.SecretFiles
    $secretRegex = $script:SecretRegex
    $codeSet = $script:Lookup.Code
    $mediaSet = $script:Lookup.Media
    $installedSet = $script:Lookup.InstalledBinaries
    $binaries = 0

    foreach ($child in $Children) {
        $name = $child.Name

        if ($markerSet.Contains($name) -or $markerRegex.IsMatch($name)) { $markers++ }
        if (([int]$child.Attributes -band $dirFlag) -ne 0) { continue }

        $total++
        if ($secretSet.Contains($name) -or $secretRegex.IsMatch($name)) { continue }
        $dot = $name.LastIndexOf('.')
        if ($dot -lt 1) { continue }
        $ext = $name.Substring($dot)
        if ($codeSet.Contains($ext)) { $code++ }
        elseif ($mediaSet.Contains($ext)) { $media++ }
        elseif ($installedSet.Contains($ext)) { $binaries++ }
    }

    if ($markers -gt 0) { return @{ Kind = 'Project'; Reason = "Có $markers marker project" } }

    # Từ 2 file .exe/.dll trở lên: bộ cài (xampp, portable app), dù cạnh đó có
    # nhiều .bat/.cmd/.js khiến tỉ lệ code cao.
    if ($binaries -ge 2) { return @{ Kind = 'Installed'; Reason = "Phần mềm đã cài: $binaries file .exe/.dll" } }

    if ($total -gt 0) {
        $codeRatio = [double]$code / [double]$total
        $mediaRatio = [double]$media / [double]$total

        if ($code -ge 2 -and $codeRatio -ge 0.30) {
            return @{ Kind = 'Project'; Reason = ('{0} file code / {1} ({2:P0})' -f $code, $total, $codeRatio) }
        }
        if ($media -ge 5 -and $mediaRatio -ge 0.80 -and $code -le 1) {
            return @{ Kind = 'MediaHeavy'; Reason = ('Media chi phối: {0}/{1}' -f $media, $total) }
        }
    }

    # Python, Git, Node bản portable, game, ... : có .exe/.dll cạnh vài script.
    if ($binaries -gt 0) { return @{ Kind = 'Installed'; Reason = "Phần mềm đã cài: $binaries file .exe/.dll" } }

    if ($code -ge 1) { return @{ Kind = 'Project'; Reason = "Có $code file code" } }

    return @{ Kind = 'Skip'; Reason = 'Không có dấu hiệu code' }
}

# =============================================================================
# 5. Duyệt cây
# =============================================================================

function Get-DefaultRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not $DevFoldersOnly) {
        # Toàn bộ PC: gốc mọi ổ cố định. Thư mục hệ thống / phần mềm đã cài bị
        # loại trong lúc duyệt (SkipDirNames, DriveRootSkipPatterns, Installed).
        try {
            foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
                if (-not $drive.IsReady) { continue }
                if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
                if ($seen.Add($drive.RootDirectory.FullName)) { $roots.Add($drive.RootDirectory.FullName) }
            }
        } catch { }
        return $roots.ToArray()
    }

    $home_ = [Environment]::GetFolderPath('UserProfile')

    foreach ($relative in @('source\repos', 'source', 'repos', 'Projects', 'projects',
            'Developer', 'dev', 'code', 'Code', 'workspace', 'Workspace', 'git', 'Git',
            'Documents\Projects', 'Documents\Source', 'Documents\GitHub')) {
        if ([string]::IsNullOrWhiteSpace($home_)) { break }
        $candidate = Join-PathSafe $home_ $relative
        if ((Test-PathExists $candidate) -and $seen.Add($candidate)) { $roots.Add($candidate) }
    }

    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if (-not $drive.IsReady) { continue }
            if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
            foreach ($folder in @('Projects', 'Source', 'repos', 'Repos', 'Dev', 'Code', 'Workspace')) {
                $candidate = Join-PathSafe $drive.RootDirectory.FullName $folder
                if ((Test-PathExists $candidate) -and $seen.Add($candidate)) { $roots.Add($candidate) }
            }
        }
    } catch { }

    return $roots.ToArray()
}

function Expand-Target {
    <#
        Một lần duyệt cho mỗi target: cộng dung lượng (tối đa $EntryLimit entry)
        và giữ đường dẫn + kích thước của $Limit file đầu tiên.
        Trả về @{ Size; Paths = List[string]; Sizes = List[long]; Truncated }

        Không tạo object cho từng file: PSCustomObject trên PS 5.1 tốn hàng
        chục µs mỗi cái, với node_modules 50.000 file là mất vài giây.
    #>
    param([string]$Value, [int]$Limit, [int]$EntryLimit = 0)

    # $Limit = 0 hoặc $EntryLimit = 0 nghĩa là không giới hạn.
    $unlimited = $Limit -le 0

    $paths = New-Object 'System.Collections.Generic.List[string]'
    $sizes = New-Object 'System.Collections.Generic.List[long]'
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push((To-LongPath $Value))
    # Chính target cũng phải nằm trong danh sách thư mục, nếu không sau khi xoá
    # file thì vỏ thư mục project vẫn còn lại.
    $self = From-LongPath (To-LongPath $Value)
    if ([System.IO.Directory]::Exists((To-LongPath $Value))) { $dirs.Add($self) }

    $dirFlag = [int][System.IO.FileAttributes]::Directory
    $reparseFlag = [int][System.IO.FileAttributes]::ReparsePoint
    $total = 0L
    $visited = 0
    $truncated = $false

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            foreach ($child in ([System.IO.DirectoryInfo]::new($current)).EnumerateFileSystemInfos()) {
                $visited++
                if ($EntryLimit -gt 0 -and $visited -gt $EntryLimit) { $truncated = $true; $stack.Clear(); break }

                $attributes = [int]$child.Attributes
                if (($attributes -band $reparseFlag) -ne 0) { continue }
                if (($attributes -band $dirFlag) -ne 0) {
                    $dirPath = $child.FullName
                    if ($dirPath.StartsWith('\\?\UNC\')) { $dirPath = '\\' + $dirPath.Substring(8) }
                    elseif ($dirPath.StartsWith('\\?\')) { $dirPath = $dirPath.Substring(4) }
                    $dirs.Add($dirPath)
                    $stack.Push($child.FullName)
                    continue
                }

                $length = $child.Length
                $total += $length
                if (-not $unlimited -and $paths.Count -ge $Limit) { $truncated = $true; continue }

                $full = $child.FullName
                if ($full.StartsWith('\\?\UNC\')) { $full = '\\' + $full.Substring(8) }
                elseif ($full.StartsWith('\\?\')) { $full = $full.Substring(4) }
                $paths.Add($full)
                $sizes.Add($length)
            }
        } catch { }
    }

    return @{ Size = $total; Paths = $paths; Sizes = $sizes; Dirs = $dirs; Truncated = $truncated }
}

function New-ScanTarget {
    <#
        Target giữ luôn danh sách file của nó (Paths/Sizes song song), nên lọc
        theo Kind chỉ là lọc target, không phải duyệt từng file.
    #>
    param([string]$Path, [string]$Name, [string]$Kind, [string]$Reason, $Expanded)

    return [PSCustomObject]@{
        Path      = $Path
        Name      = $Name
        Kind      = $Kind
        Size      = [long]$Expanded.Size
        Reason    = $Reason
        Blocked   = Get-BlockReason $Path
        Paths     = $Expanded.Paths
        Sizes     = $Expanded.Sizes
        Dirs      = $Expanded.Dirs
        Truncated = [bool]$Expanded.Truncated
    }
}

function ConvertFrom-FileUri {
    <#
        'file:///c%3A/Users/x/My%20Project' -> 'C:\Users\x\My Project'
        Trả về $null nếu không phải file URI trên ổ cục bộ.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if (-not $Value.StartsWith('file://', [StringComparison]::OrdinalIgnoreCase)) { return $null }

    $path = $Value.Substring(7)
    # Bỏ phần host rỗng: file:///c:/... -> /c:/...
    if ($path.StartsWith('/')) { $path = $path.Substring(1) }
    try { $path = [System.Uri]::UnescapeDataString($path) } catch { return $null }
    $path = $path.Replace('/', '\')
    if ($path -notmatch '^[A-Za-z]:\\') { return $null }
    return $path
}

function Get-WorkspaceProjectPath {
    <#
        Đọc metadata của một workspace trong workspaceStorage để lấy đường dẫn
        project mà IDE đã mở. Không đọc được thì trả về $null.
    #>
    param([string]$WorkspaceDir, [string]$Manifest, [string[]]$Keys)

    $manifestPath = Join-PathSafe $WorkspaceDir $Manifest
    if (-not (Test-PathExists $manifestPath)) { return $null }

    try {
        $raw = [System.IO.File]::ReadAllText((To-LongPath $manifestPath), [System.Text.Encoding]::UTF8)
        $json = $raw | ConvertFrom-Json
    } catch { return $null }

    foreach ($key in $Keys) {
        $property = $json.PSObject.Properties[$key]
        if ($null -eq $property) { continue }
        $value = $property.Value
        if ($null -eq $value) { continue }

        # 'folder' là chuỗi URI; 'workspace' là đường dẫn file .code-workspace.
        $candidate = ConvertFrom-FileUri ([string]$value)
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        # .code-workspace: lấy thư mục chứa file, vì đó là gốc project.
        if ($candidate -like '*.code-workspace') { return [System.IO.Path]::GetDirectoryName($candidate) }
        return $candidate
    }
    return $null
}

function Get-IdeHistoryTargets {
    <#
        Dò lịch sử project của IDE.

        CHỈ đề xuất xoá dữ liệu MỒ CÔI: workspace mà đường dẫn project ghi
        trong metadata không còn tồn tại trên đĩa. Nhờ vậy:
          - project đã xoá không còn hiện trong "Recent / Open Recent";
          - project còn dùng thì dữ liệu IDE của nó KHÔNG bị đụng tới;
          - không bao giờ xoá cả thư mục cấu hình của IDE.

        Hàm này KHÔNG nhận -Path và chỉ được gọi khi quét toàn PC.
    #>
    param([int]$Limit, [string]$ProfileDir)

    $found = New-Object 'System.Collections.Generic.List[object]'
    $notes = New-Object 'System.Collections.Generic.List[object]'
    # ProfileDir chỉ dùng cho kiểm thử: cho phép chạy trên cây thư mục giả thay
    # vì profile thật, nên không bao giờ đụng dữ liệu IDE của người dùng.
    if ([string]::IsNullOrWhiteSpace($ProfileDir)) { $ProfileDir = [Environment]::GetFolderPath('UserProfile') }
    if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
        return @{ Targets = $found.ToArray(); Notes = $notes.ToArray() }
    }

    foreach ($entry in $script:IdeHistoryEntries) {
        $matchPath = Join-PathSafe $ProfileDir $entry.Path
        if (-not (Test-PathExists $matchPath)) { continue }

        # Chỉ báo, không xoá: file cấu hình dùng chung cho mọi project.
        if ($entry.Kind -eq 'Note') {
            [void]$notes.Add([PSCustomObject]@{
                    Path = $matchPath
                    Note = ("{0}: danh sách project gần đây nằm trong file cấu hình dùng chung nên KHÔNG xoá tự động. Muốn dọn thì mở IDE, chuột phải project đã xoá và chọn 'Remove from Recent'." -f $entry.Label)
                })
            continue
        }

        foreach ($workspaceDir in @([System.IO.Directory]::GetDirectories((To-LongPath $matchPath)))) {
            $workspaceDir = From-LongPath $workspaceDir
            $projectPath = Get-WorkspaceProjectPath -WorkspaceDir $workspaceDir -Manifest $entry.Manifest -Keys $entry.Keys
            if ([string]::IsNullOrWhiteSpace($projectPath)) { continue }

            # Project còn tồn tại => dữ liệu IDE của nó phải được giữ nguyên.
            if (Test-PathExists $projectPath) { continue }

            $expanded = Expand-Target -Value $workspaceDir -Limit $Limit
            if ($expanded.Size -le 0 -and $expanded.Paths.Count -eq 0 -and $expanded.Dirs.Count -eq 0) { continue }

            $reason = "Workspace mồ côi của $($entry.Label): project '$projectPath' không còn tồn tại"
            $target = New-ScanTarget -Path $workspaceDir -Name (Split-Path -Leaf $workspaceDir) `
                -Kind 'IdeHistory' -Reason $reason -Expanded $expanded
            # Guard chặn AppData cho mục thường; lịch sử IDE nằm đúng trong
            # AppData nên bỏ đúng lý do đó, các kiểm tra khác vẫn giữ.
            if ($null -ne $target.Blocked -and $target.Blocked -notlike 'Nằm trong AppData*') { continue }
            $target.Blocked = $null
            [void]$found.Add($target)
        }
    }

    return @{ Targets = $found.ToArray(); Notes = $notes.ToArray() }
}

function Invoke-Scan {
    <#
        Duyệt toàn bộ root, trả về:
          Targets = mục cấp cao (project / devdir / secret / codefile), mỗi mục
                    mang sẵn danh sách file cụ thể (Paths/Sizes)
    #>
    param([string[]]$Roots, [switch]$IncludeIdeHistory)

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $notes = New-Object 'System.Collections.Generic.List[object]'

    $stats = [PSCustomObject]@{
        FoldersVisited = 0
        EntriesVisited = 0
        Truncated      = $false
    }

    # Trần tính riêng cho từng root (mỗi ổ), để ổ C: đầy file không làm bỏ sót ổ D:.
    # Trần entry khi duyệt từng ổ, tránh treo nếu ổ có hàng chục triệu file.
    # 0 = không giới hạn.
    $maxEntries = 0

    # Vòng duyệt chạy cho mọi entry trên đĩa: đọc sẵn hằng số và lookup ra
    # biến local, tự phân loại inline thay vì gọi hàm cho từng file.
    $dirFlag = [int][System.IO.FileAttributes]::Directory
    $reparseFlag = [int][System.IO.FileAttributes]::ReparsePoint
    $skipSet = $script:Lookup.SkipDirs
    $devSet = $script:Lookup.DevDirs
    $secretDirSet = $script:Lookup.SecretDirs
    $secretFileSet = $script:Lookup.SecretFiles
    $codeSet = $script:Lookup.Code
    $secretRegex = $script:SecretRegex
    $manifestRegex = $script:DotnetManifestRegex
    $forbidden = $script:ForbiddenLookup
    $homeDir = if ($null -ne $script:UserProfileDir) { $script:UserProfileDir.TrimEnd('\') } else { $null }
    $usersDir = if ($null -ne $homeDir) { [System.IO.Path]::GetDirectoryName($homeDir) } else { $null }
    $driveRootSkip = $script:DriveRootSkipRegex
    $profileContainers = $script:Lookup.ProfileContainers
    $systemProfiles = $script:Lookup.SystemProfiles
    $webRoots = New-LookupSet @('htdocs', 'www', 'wwwroot', 'webapps', 'public_html')

    foreach ($root in $Roots) {
        $rootEntries = 0
        $resolved = Get-NormalizedPath $root
        if ($null -eq $resolved -or -not (Test-PathExists $resolved)) {
            [void]$notes.Add([PSCustomObject]@{ Path = $root; Note = 'Không tồn tại, bỏ qua.' })
            continue
        }

        # Duyệt BFS. Root không phải project thì đi tiếp; gặp project/devdir/
        # secret thì ghi nhận và KHÔNG đi vào (đã có danh sách file riêng).
        $queue = New-Object 'System.Collections.Generic.Queue[object]'
        $queue.Enqueue(@{ Path = $resolved; Depth = 0; SecretsOnly = $false; Children = $null })

        while ($queue.Count -gt 0) {
            $item = $queue.Dequeue()
            $currentPath = $item.Path
            $depth = $item.Depth
            $secretsOnly = $item.SecretsOnly

            if ($maxEntries -gt 0 -and $rootEntries -ge $maxEntries) {
                $stats.Truncated = $true
                [void]$notes.Add([PSCustomObject]@{
                        Path = $currentPath
                        Note = "Đã chạm trần $maxEntries entry, dừng duyệt."
                    })
                break
            }

            # Đã liệt kê lúc xét verdict ở vòng trước thì dùng lại, khỏi đọc đĩa lần hai.
            # Gán trong từng nhánh và bọc @(): PowerShell mở mảng 0/1 phần tử
            # thành $null/scalar cả khi return lẫn khi lấy output của if.
            $children = $item.Children
            if ($null -eq $children) { $children = @(Get-ChildInfos $currentPath) }
            $stats.FoldersVisited++
            $stats.EntriesVisited += $children.Count
            $rootEntries += $children.Count

            # Gốc một profile bất kỳ: home hiện tại hoặc C:\Users\<ai đó>.
            $trimmed = $currentPath.TrimEnd('\')
            $parentDir = [System.IO.Path]::GetDirectoryName($trimmed)
            $isHomeLevel = ($null -ne $homeDir -and [string]::Equals($trimmed, $homeDir, [StringComparison]::OrdinalIgnoreCase)) -or
                ($null -ne $usersDir -and $null -ne $parentDir -and [string]::Equals($parentDir, $usersDir, [StringComparison]::OrdinalIgnoreCase))
            $isUsersDir = $null -ne $usersDir -and [string]::Equals($trimmed, $usersDir, [StringComparison]::OrdinalIgnoreCase)
            $isDriveRoot = $currentPath -match '^[A-Za-z]:\\?$'

            foreach ($child in $children) {
                $attributes = [int]$child.Attributes
                if (($attributes -band $reparseFlag) -ne 0) { continue }

                $name = $child.Name
                $childPath = $child.FullName
                if ($childPath.StartsWith('\\?\UNC\')) { $childPath = '\\' + $childPath.Substring(8) }
                elseif ($childPath.StartsWith('\\?\')) { $childPath = $childPath.Substring(4) }

                if (($attributes -band $dirFlag) -ne 0) {
                    if ($skipSet.Contains($name)) { continue }

                    $kindLabel = $null
                    $reason = $null

                    if (-not $secretsOnly -and $devSet.Contains($name)) {
                        $kindLabel = 'DevDir'
                        $reason = "Thư mục rác dev: $name"
                    } elseif ($secretDirSet.Contains($name)) {
                        $kindLabel = 'Secret'
                        $reason = "Thư mục chứa thông tin đăng nhập: $name"
                    }

                    if ($null -eq $kindLabel) {
                        if ($isDriveRoot -and $driveRootSkip.IsMatch($name)) { continue }
                        if ($isUsersDir -and $systemProfiles.Contains($name)) { continue }

                        if ($isHomeLevel -and $profileContainers.Contains($name)) {
                            if ($depth -lt $MaxDepth) {
                                $queue.Enqueue(@{ Path = $childPath; Depth = ($depth + 1); SecretsOnly = $false; Children = $null })
                            }
                            continue
                        }

                        # .vscode, .rustup, .cargo, ... ngay dưới home là dữ liệu của
                        # công cụ đã cài, không phải project của người dùng: chỉ tìm
                        # secret trong đó (vd .ollama\id_ed25519).
                        if ($secretsOnly -or ($isHomeLevel -and $name.StartsWith('.'))) {
                            if ($depth -lt $MaxDepth) {
                                $queue.Enqueue(@{ Path = $childPath; Depth = ($depth + 1); SecretsOnly = $true; Children = $null })
                            }
                            continue
                        }

                        if ($forbidden.Contains($childPath)) {
                            if ($depth -lt $MaxDepth) {
                                $queue.Enqueue(@{ Path = $childPath; Depth = ($depth + 1); SecretsOnly = $false; Children = $null })
                            }
                            continue
                        }

                        if ($depth -ge $MaxDepth) { continue }

                        $subChildren = @(Get-ChildInfos $childPath)
                        $verdict = Get-FolderVerdict -Children $subChildren

                        # MediaHeavy / Installed: không phải code của người dùng, không đi vào.
                        # Riêng web server (xampp, wamp, ...) vẫn xét thư mục web root,
                        # vì đó là nơi người dùng để code PHP/web.
                        if ($verdict.Kind -eq 'Installed') {
                            foreach ($sub in $subChildren) {
                                if (([int]$sub.Attributes -band $dirFlag) -eq 0) { continue }
                                if (([int]$sub.Attributes -band $reparseFlag) -ne 0) { continue }
                                if ($webRoots.Contains($sub.Name) -and $depth + 1 -lt $MaxDepth) {
                                    $subPath = $sub.FullName
                                    if ($subPath.StartsWith('\\?\')) { $subPath = From-LongPath $subPath }
                                    $queue.Enqueue(@{ Path = $subPath; Depth = ($depth + 2); SecretsOnly = $false; Children = $null })
                                }
                            }
                            continue
                        }
                        if ($verdict.Kind -eq 'MediaHeavy') { continue }
                        if ($verdict.Kind -ne 'Project') {
                            $queue.Enqueue(@{ Path = $childPath; Depth = ($depth + 1); SecretsOnly = $false; Children = $subChildren })
                            continue
                        }

                        $kindLabel = 'Project'
                        $reason = $verdict.Reason
                    }

                    $expanded = Expand-Target -Value $childPath -Limit $MaxFilesPerTarget
                    [void]$targets.Add((New-ScanTarget -Path $childPath -Name $name -Kind $kindLabel -Reason $reason -Expanded $expanded))
                    if ($expanded.Truncated) {
                        [void]$notes.Add([PSCustomObject]@{
                                Path = $childPath
                                Note = "Danh sách file bị cắt ở $MaxFilesPerTarget (còn nữa)."
                            })
                    }                    continue
                }

                # --- File lẻ ---
                $isSecret = $secretFileSet.Contains($name) -or
                    ($secretRegex.IsMatch($name) -and -not $manifestRegex.IsMatch($name))
                if (-not $isSecret) {
                    if ($secretsOnly) { continue }
                    $dot = $name.LastIndexOf('.')
                    if ($dot -lt 1 -or -not $codeSet.Contains($name.Substring($dot))) { continue }
                }

                $label = if ($isSecret) { 'Secret' } else { 'CodeFile' }
                $reason = if ($isSecret) {
                    "File chứa thông tin đăng nhập: $name"
                } else {
                    'File source code nằm ngoài project'
                }

                $size = [long]$child.Length
                $single = @{
                    Size      = $size
                    Paths     = [System.Collections.Generic.List[string]]::new()
                    Sizes     = [System.Collections.Generic.List[long]]::new()
                    Dirs      = [System.Collections.Generic.List[string]]::new()
                    Truncated = $false
                }
                $single.Paths.Add($childPath)
                $single.Sizes.Add($size)
                [void]$targets.Add((New-ScanTarget -Path $childPath -Name $name -Kind $label -Reason $reason -Expanded $single))
            }
        }
    }

    # Lịch sử IDE nằm trong AppData (bị bỏ qua khi duyệt) nên phải dò riêng.
    # CHỈ khi quét toàn PC: quét một thư mục cụ thể mà vẫn gom lịch sử IDE thì
    # người chạy thử -Path <thư mục nhỏ> sẽ mất dữ liệu IDE của cả máy.
    if ($IncludeIdeHistory) {
        $ide = Get-IdeHistoryTargets -Limit $MaxFilesPerTarget
        foreach ($ideTarget in @($ide.Targets)) { [void]$targets.Add($ideTarget) }
        foreach ($ideNote in @($ide.Notes)) { [void]$notes.Add($ideNote) }
    }

    return @{
        Targets = $targets.ToArray()
        Notes   = $notes.ToArray()
        Stats   = $stats
    }
}

# =============================================================================
# 6. Xuất kết quả
# =============================================================================

function ConvertTo-JsonString {
    param([string]$Value)

    if ($null -eq $Value) { return 'null' }
    $builder = [System.Text.StringBuilder]::new($Value.Length + 2)
    [void]$builder.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$builder.Append('\"') }
            '\' { [void]$builder.Append('\\') }
            default {
                if ([int]$ch -lt 0x20) { [void]$builder.AppendFormat('\u{0:x4}', [int]$ch) }
                else { [void]$builder.Append($ch) }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Out-Report {
    param($Result, [string]$Destination)

    if (-not (Test-PathExists $Destination)) {
        [void][System.IO.Directory]::CreateDirectory((To-LongPath $Destination))
    }

    # Lọc theo Kind
    $wantedKinds = if ($Kind -contains 'All') {
        @('Project', 'DevDir', 'Secret', 'CodeFile', 'IdeHistory')
    } else {
        $Kind
    }

    $minSize = $script:MinSizeBytes
    $kindTargets = @($Result.Targets | Where-Object { $wantedKinds -contains $_.Kind -and -not $_.Blocked })
    $targets = if ($null -ne $minSize) { @($kindTargets | Where-Object { $_.Size -ge $minSize }) } else { $kindTargets }
    $targets = @($targets | Sort-Object -Property Size -Descending)

    # Gom file của mọi target vào mảng song song rồi Array.Sort một lần.
    # Sort-Object / Where-Object trên hàng chục nghìn object mất nhiều giây.
    $capacity = 0
    foreach ($target in $kindTargets) { $capacity += $target.Paths.Count }

    $filePaths = New-Object 'string[]' $capacity
    $fileSizes = New-Object 'long[]' $capacity
    $fileOwner = New-Object 'int[]' $capacity
    $count = 0
    $totalBytes = 0L

    for ($t = 0; $t -lt $kindTargets.Count; $t++) {
        $paths = $kindTargets[$t].Paths
        $sizes = $kindTargets[$t].Sizes
        for ($j = 0; $j -lt $paths.Count; $j++) {
            $size = $sizes[$j]
            if ($null -ne $minSize -and $size -lt $minSize) { continue }
            $filePaths[$count] = $paths[$j]
            $fileSizes[$count] = $size
            $fileOwner[$count] = $t
            $totalBytes += $size
            $count++
        }
    }

    $sortKeys = [long[]]$fileSizes.Clone()
    $order = [int[]][System.Linq.Enumerable]::ToArray([System.Linq.Enumerable]::Range(0, $capacity))
    if ($count -gt 1) { [Array]::Sort($sortKeys, $order, 0, $count) }

    $txtPath = Join-PathSafe $Destination ("danh-sach-file-{0}.txt" -f $script:RunId)
    $csvPath = Join-PathSafe $Destination ("danh-sach-file-{0}.csv" -f $script:RunId)
    $jsonPath = Join-PathSafe $Destination ("danh-sach-file-{0}.json" -f $script:RunId)
    # Thư mục của từng target, sắp theo độ dài giảm dần: xoá con trước cha.
    $dirsPath = Join-PathSafe $Destination ("danh-sach-thu-muc-{0}.txt" -f $script:RunId)
    # Đường dẫn lịch sử IDE: remove-once.ps1 dùng để cho phép xoá trong AppData.
    $idePath = Join-PathSafe $Destination ("danh-sach-ide-{0}.txt" -f $script:RunId)

    $noBom = New-Object System.Text.UTF8Encoding($false)
    $withBom = New-Object System.Text.UTF8Encoding($true)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $units = @('B', 'KB', 'MB', 'GB', 'TB')

    $txt = [System.IO.StreamWriter]::new((To-LongPath $txtPath), $false, $noBom)
    # Export-Csv -Encoding UTF8 của PS 5.1 có BOM; giữ BOM để Excel đọc đúng tiếng Việt.
    $csv = [System.IO.StreamWriter]::new((To-LongPath $csvPath), $false, $withBom)
    $json = [System.IO.StreamWriter]::new((To-LongPath $jsonPath), $false, $noBom)
    $topFiles = New-Object 'System.Collections.Generic.List[object]'

    try {
        # --- TXT: danh sách đường dẫn, đúng thứ người dùng cần ---
        $txt.WriteLine('# presale-wiper - danh sách file CẦN DỌN (chưa xoá gì)')
        $txt.WriteLine("# Tạo lúc: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $txt.WriteLine("# Số file: $count | Tổng: $(Format-Size $totalBytes)")
        $txt.WriteLine('#')
        $txt.WriteLine('# CẢNH BÁO: file này liệt kê đường dẫn tuyệt đối trên máy bạn.')
        $txt.WriteLine('# Đừng chia sẻ công khai - nó cho thấy cấu trúc thư mục của bạn.')
        $txt.WriteLine('')

        # --- CSV: chi tiết để lọc/sắp xếp trong Excel ---
        $csv.WriteLine('"Path","SizeBytes","SizeText","Kind","Reason"')

        # --- JSON: chỉ ghi phần tóm tắt, KHÔNG kèm danh sách file ---
        # Trước đây JSON chứa toàn bộ đường dẫn, sinh ra bản sao 75-135 MB mỗi
        # lần quét toàn PC. Giờ dữ liệu chi tiết chỉ nằm trong CSV + TXT.
        $json.WriteLine('{')
        $json.WriteLine('  "tool": "presale-wiper scan-once",')
        $json.WriteLine('  "mode": "scan-only",')
        $json.WriteLine('  "deleted": false,')
        $json.WriteLine('  "generatedAt": ' + (ConvertTo-JsonString (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) + ',')
        $json.WriteLine('  "computer": ' + (ConvertTo-JsonString $env:COMPUTERNAME) + ',')
        $json.WriteLine('  "user": ' + (ConvertTo-JsonString $env:USERNAME) + ',')
        $json.WriteLine('  "roots": [' + ((@($Result.Roots) | ForEach-Object { ConvertTo-JsonString ([string]$_) }) -join ', ') + '],')
        $json.WriteLine('  "totals": {')
        $json.WriteLine("    `"targets`": $($targets.Count),")
        $json.WriteLine("    `"files`": $count,")
        $json.WriteLine("    `"sizeBytes`": $totalBytes,")
        $json.WriteLine('    "sizeText": ' + (ConvertTo-JsonString (Format-Size $totalBytes)))
        $json.WriteLine('  },')
        $json.WriteLine('  "filesListedIn": ' + (ConvertTo-JsonString $csvPath))
        $json.WriteLine('}')

        # Đường dẫn Windows không chứa ký tự điều khiển, nên chỉ cần thoát \ và ".
        $csvReason = New-Object 'string[]' $kindTargets.Count
        # Đường dẫn Windows không chứa ký tự điều khiển, nên chỉ cần thoát \ và ".
        $csvReason = New-Object 'string[]' $kindTargets.Count
        for ($t = 0; $t -lt $kindTargets.Count; $t++) {
            $csvReason[$t] = '","' + $kindTargets[$t].Kind + '","' + $kindTargets[$t].Reason.Replace('"', '""') + '"'
        }

        for ($i = $count - 1; $i -ge 0; $i--) {
            $index = $order[$i]
            $path = $filePaths[$index]
            $size = $fileSizes[$index]

            if ($size -lt 1024) {
                $sizeText = "$size B"
            } else {
                $value = [double]$size
                $unit = 0
                while ($value -ge 1024 -and $unit -lt 4) { $value = $value / 1024; $unit++ }
                $sizeText = $value.ToString('F1', $invariant) + ' ' + $units[$unit]
            }

            $txt.WriteLine($path)
            $csv.WriteLine('"' + $path.Replace('"', '""') + '","' + $size + '","' + $sizeText + $csvReason[$fileOwner[$index]])

            if ($topFiles.Count -lt 200) { [void]$topFiles.Add([PSCustomObject]@{ Path = $path; Size = $size }) }
        }

        # --- TXT thư mục: mỗi target kèm cây thư mục của nó ---
        $dirLines = New-Object 'System.Collections.Generic.List[string]'
        $allDirs = New-Object 'System.Collections.Generic.List[string]'
        foreach ($target in $targets) {
            foreach ($dir in @($target.Dirs)) {
                if ([string]::IsNullOrWhiteSpace($dir)) { continue }
                if ($allDirs.Contains($dir)) { continue }
                $allDirs.Add($dir)
            }
        }
        $sortedDirs = $allDirs.ToArray()
        # Sắp xếp bằng mảng khóa độ dài (giảm dần) - nhanh hơn Sort-Object nhiều.
        $dirKeys = New-Object 'int[]' $sortedDirs.Count
        for ($i = 0; $i -lt $sortedDirs.Count; $i++) { $dirKeys[$i] = -$sortedDirs[$i].Length }
        if ($sortedDirs.Count -gt 1) { [Array]::Sort($dirKeys, $sortedDirs, [System.StringComparer]::OrdinalIgnoreCase) }
        $dirLines.Add('# presale-wiper - thư mục thuộc các mục cần dọn (con trước cha)')
        $dirLines.Add("# Số thư mục: $($sortedDirs.Count)")
        $dirLines.Add('')
        foreach ($dir in $sortedDirs) { $dirLines.Add($dir) }
        [System.IO.File]::WriteAllLines((To-LongPath $dirsPath), $dirLines.ToArray(), $noBom)

        # --- Lịch sử IDE ---
        $ideLines = New-Object 'System.Collections.Generic.List[string]'
        $ideFileCount = 0
        foreach ($ideTarget in @($targets | Where-Object { $_.Kind -eq 'IdeHistory' })) {
            $ideFileCount += $ideTarget.Paths.Count
        }
        $ideLines.Add('# presale-wiper - lịch sử project của IDE (xoá để menu Recent không còn hiện project đã mất)')
        $ideTargets = @($targets | Where-Object { $_.Kind -eq 'IdeHistory' })
        $ideLines.Add("# Số mục: $($ideTargets.Count)")
        $ideLines.Add('')
        foreach ($ideTarget in $ideTargets) { $ideLines.Add(('{0}|{1}' -f $ideTarget.Path, $ideTarget.Reason)) }
        [System.IO.File]::WriteAllLines((To-LongPath $idePath), $ideLines.ToArray(), $noBom)
    } finally {
        $txt.Dispose()
        $csv.Dispose()
        $json.Dispose()
    }

    return @{
        Txt       = $txtPath
        Csv       = $csvPath
        Json      = $jsonPath
        Dirs      = $dirsPath
        Ide       = $idePath
        IdeFileCount = $ideFileCount
        Targets   = $targets
        FileCount = $count
        TopFiles  = $topFiles.ToArray()
        TotalSize = $totalBytes
    }
}

function Show-Summary {
    param($Report)

    # Không cắt bớt: hiện đủ mọi mục và mọi file lớn nhất, để tự thấy toàn bộ.
    Write-Green ''
    Write-Green ('=' * 76)
    Write-Green '  presale-wiper - KẾT QUẢ SCAN'
    Write-Green ('=' * 76)

    if (-not $Quiet) {
        $allTargets = @($Report.Targets)
        if ($allTargets.Count -gt 0) {
            Write-Green ''
            Write-Green ("--- Tất cả mục cần dọn ({0}) ---" -f $allTargets.Count)
            Write-Green ("{0,-10} {1,12}  {2}" -f 'Loại', 'Dung lượng', 'Đường dẫn')
            Write-Green ("{0,-10} {1,12}  {2}" -f ('-' * 10), ('-' * 12), ('-' * 50))
            foreach ($target in $allTargets) {
                Write-Green ("{0,-10} {1,12}  {2}" -f $target.Kind, (Format-Size $target.Size), $target.Path)
            }
        }

        $allFiles = @($Report.TopFiles)
        if ($allFiles.Count -gt 0) {
            Write-Green ''
            Write-Green ("--- File lớn nhất ({0}) ---" -f $allFiles.Count)
            foreach ($file in $allFiles) {
                Write-Green ("{0,12}  {1}" -f (Format-Size $file.Size), $file.Path)
            }
        }
    }

    Write-Green ''
    Write-Green '--- Tổng kết ---'
    Write-Green ("  Mục (project/devdir/secret) : {0}" -f @($Report.Targets).Count)
    Write-Green ("  File cụ thể                 : {0}" -f $Report.FileCount)
    Write-Green ("  Tổng dung lượng             : {0}" -f (Format-Size $Report.TotalSize))
    Write-Green ''
    Write-Green '--- File kết quả ---'
    Write-Green ("  TXT  (danh sách path) : {0}" -f $Report.Txt)
    Write-Green ("  CSV  (chi tiết)       : {0}" -f $Report.Csv)
    Write-Green ("  JSON (cho tooling)    : {0}" -f $Report.Json)
    Write-Green ("  DIRS (thư mục)        : {0}" -f $Report.Dirs)
    Write-Green ("  IDE  (lịch sử IDE)    : {0}" -f $Report.Ide)
    Write-Green ''
    $ideCount = @($Report.Targets | Where-Object { $_.Kind -eq 'IdeHistory' }).Count
    if ($ideCount -gt 0) {
        Write-Green ("Đã tìm thấy {0} mục lịch sử IDE ({1} file). Xoá chúng để project đã xoá không còn hiện trong menu Recent/Open Recent." -f `
                $ideCount, $Report.IdeFileCount)
        Write-Green ''
    }
    if ($Report.DryRun) {
        Write-Green 'CHƯA có file nào bị xoá (chế độ chỉ xem).'
    } else {
        Write-Green 'Tiếp theo: XOÁ VĨNH VIỄN các mục trên.'
    }
    Write-Green ''
}

# =============================================================================
# 7. Chạy
# =============================================================================

$MinSizeBytes = $null
if (-not [string]::IsNullOrWhiteSpace($MinSize)) {
    $MinSizeBytes = ConvertTo-Bytes $MinSize
    if ($null -eq $MinSizeBytes) {
        Write-Failure ("LỖI: -MinSize không hợp lệ: '{0}'. Ví dụ: 100MB, 1.5GB, 2097152." -f $MinSize)
        [Environment]::ExitCode = 2
        return
    }
}

# @() bắt buộc: khi chỉ truyền 1 path, $Path là chuỗi chứ không phải mảng,
# nên $Path.Count ném lỗi dưới StrictMode.
$pathList = @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$roots = @(if ($pathList.Count -gt 0) { $pathList } else { Get-DefaultRoots })

if ($roots.Count -eq 0) {
    Write-Failure ("Không tìm thấy thư mục nào để quét.`r`n" +
        'Chỉ định thủ công, ví dụ:  .\scan-once.ps1 -Path D:\Projects')
    [Environment]::ExitCode = 2
    return
}

$destination = if ([string]::IsNullOrWhiteSpace($OutDir)) {
    Join-PathSafe ([Environment]::GetFolderPath('UserProfile')) ("presale-scan-{0}" -f $script:RunId)
} else {
    $OutDir
}

Write-Stdout ''
Write-Stdout 'presale-wiper - scan một lần'
Write-Stdout ("  Thư mục quét : {0}" -f ($roots -join '; '))
Write-Stdout ("  Nơi ghi kết quả: {0}" -f $destination)

# Dọn kết quả của những lần chạy trước: mỗi lần quét toàn PC sinh ra file
# danh sách hàng chục tới hàng trăm MB, chạy vài lần là đầy ổ. Chỉ xoá đúng
# các file do công cụ này tạo (theo mẫu tên), không đụng file khác.
$staleCleaned = 0
$staleBytes = 0L
try {
    # 1) Các thư mục kết quả mặc định (presale-scan-*) của những lần chạy trước.
    $staleDirs = @([System.IO.Directory]::GetDirectories((To-LongPath (Split-Path -Parent $destination)), 'presale-scan-*'))
    foreach ($staleDir in $staleDirs) {
        $staleFull = [System.IO.Path]::GetFullPath($staleDir).TrimEnd('\')
        if ([string]::Equals($staleFull, ([System.IO.Path]::GetFullPath($destination).TrimEnd('\')), [StringComparison]::OrdinalIgnoreCase)) { continue }
        foreach ($pattern in @('danh-sach-file-*', 'danh-sach-thu-muc-*', 'danh-sach-ide-*', 'ke-hoach-xoa-*', 'da-xoa-*')) {
            foreach ($oldFile in [System.IO.Directory]::GetFiles($staleFull, $pattern)) {
                try {
                    $staleBytes += (New-Object System.IO.FileInfo $oldFile).Length
                    [System.IO.File]::Delete($oldFile)
                    $staleCleaned++
                } catch { }
            }
        }
        # Thư mục rỗng sau khi dọn thì bỏ luôn.
        try { [System.IO.Directory]::Delete($staleFull, $false) } catch { }
    }

    # 2) Kết quả cũ ngay trong thư mục đích (khi dùng -OutDir riêng).
    if ([System.IO.Directory]::Exists((To-LongPath $destination))) {
        foreach ($pattern in @('danh-sach-file-*', 'danh-sach-thu-muc-*', 'danh-sach-ide-*', 'ke-hoach-xoa-*', 'da-xoa-*')) {
            foreach ($oldFile in [System.IO.Directory]::GetFiles((To-LongPath $destination), $pattern)) {
                try {
                    $staleBytes += (New-Object System.IO.FileInfo $oldFile).Length
                    [System.IO.File]::Delete($oldFile)
                    $staleCleaned++
                } catch { }
            }
        }
    }
} catch { }

if ($staleCleaned -gt 0) {
    Write-Stdout ("  Đã dọn {0} file kết quả cũ ({1:N1} MB) từ lần chạy trước." -f $staleCleaned, ($staleBytes / 1MB))
}
Write-Stdout ''
Write-Stdout 'Đang quét...'

$scanResult = $null
# Chỉ dò lịch sử IDE khi quét toàn PC (không truyền -Path). Quét một thư mục cụ
# thể thì tuyệt đối không đụng tới AppData của người dùng.
$scanWholePc = ($pathList.Count -eq 0)
try {
    $scanResult = Invoke-Scan -Roots $roots -IncludeIdeHistory:$scanWholePc
} catch {
    Write-Failure ("LỖI khi quét: {0}" -f $_.Exception.Message)
    [Environment]::ExitCode = 2
    return
}

$scanResult.Roots = $roots

$report = $null
try {
    $report = Out-Report -Result $scanResult -Destination $destination
    # Show-Summary cần biết có đang ở chế độ chỉ xem hay không để in đúng.
    $report | Add-Member -NotePropertyName DryRun -NotePropertyValue ([bool]($DryRun -or $NoDelete)) -Force
} catch {
    Write-Failure ("LỖI khi ghi kết quả: {0}" -f $_.Exception.Message)
    [Environment]::ExitCode = 2
    return
}

Show-Summary -Report $report

# presale-scan.cmd đặt biến này: mở sẵn kết quả để người dùng không phải đi tìm.
if ($env:PSW_OPEN_RESULT -eq '1') {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $report.Txt) } catch { }
}

if (@($scanResult.Notes).Count -gt 0) {
    Write-Green ("Ghi chú ({0}):" -f @($scanResult.Notes).Count)
    foreach ($note in @($scanResult.Notes | Select-Object -First 10)) {
        Write-Green ("  - {0}: {1}" -f $note.Path, $note.Note)
    }
    Write-Green ''
}

function Get-RemoveScriptPath {
    <#
        Tìm remove-once.ps1. presale-scan.cmd là file duy nhất: nội dung
        remove-once.ps1 được nhúng Base64 ở cuối file, giải nén ra temp khi cần.
    #>
    # $PSScriptRoot rỗng khi mã chạy trong ScriptBlock (presale-scan.cmd): chỉ
    # dùng khi thật sự có, tránh Join-Path với base rỗng.
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $sibling = Join-Path $PSScriptRoot 'remove-once.ps1'
        if ([System.IO.File]::Exists($sibling)) { return $sibling }
    }

    $self = $env:PSW_SELF
    if ([string]::IsNullOrWhiteSpace($self) -or -not [System.IO.File]::Exists($self)) { return $null }

    $begin = '# PSW_REMOVE_BASE64_BEGIN'
    $end = '# PSW_REMOVE_BASE64_END'
    $text = [System.IO.File]::ReadAllText($self, [System.Text.Encoding]::UTF8)
    # Tìm ở dạng dòng chú thích: chuỗi trần cũng xuất hiện trong chính hàm này.
    $startIndex = $text.LastIndexOf($begin, [StringComparison]::Ordinal)
    if ($startIndex -lt 0) { return $null }
    $endIndex = $text.LastIndexOf($end, [StringComparison]::Ordinal)
    if ($endIndex -le $startIndex) { return $null }

    $payload = $text.Substring($startIndex + $begin.Length, $endIndex - $startIndex - $begin.Length)
    # Mỗi dòng base64 được ghi kèm tiền tố '# ' để cả file vẫn là comment hợp lệ
    # khi PowerShell parse; bỏ tiền tố đó rồi nối lại.
    $payload = ($payload -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            ForEach-Object { if ($_.StartsWith('#')) { $_.Substring(1).Trim() } else { $_ } }) -join ''
    $bytes = [Convert]::FromBase64String($payload)

    $target = Join-Path ([System.IO.Path]::GetTempPath()) ("presale-remove-{0}.ps1" -f $script:RunId)
    [System.IO.File]::WriteAllBytes($target, $bytes)
    return $target
}

# Chạy là xoá luôn. Không hỏi, không cần gõ gì thêm.
# -DryRun: chỉ in danh sách, không xoá (dùng khi muốn xem trước).
# -NoDelete: quét và ghi báo cáo nhưng dừng lại, không xoá.
if ($DryRun -or $NoDelete) {
    Write-Green ''
    Write-Green 'CHẾ ĐỘ CHỈ XEM: không xoá file nào.'
    Write-Green 'Bỏ -DryRun / -NoDelete là chạy sẽ xoá ngay.'
} else {
    try {
        $removeScript = Get-RemoveScriptPath
        if ([string]::IsNullOrWhiteSpace($removeScript)) {
            throw 'Không tìm thấy remove-once.ps1 (hãy để cùng thư mục, hoặc dùng presale-scan.cmd bản mới).'
        }
        # -Yes: chạy file là đã đồng ý xoá, không hỏi lại.
        & $removeScript -Plan (Split-Path -Parent $report.Json) -FromScan -Execute -ConfirmToken XOA -Yes
    } catch {
        Write-Green ("LỖI khi mở bước xoá: {0}" -f $_.Exception.Message)
    }
}

if (-not $DryRun -and -not $NoDelete -and -not [Console]::IsInputRedirected) {
    # Giữ cửa sổ lại để kịp đọc kết quả trước khi tự đóng.
    Write-Green ''
    Write-Green 'Xong. Ấn Enter để đóng cửa sổ.'
    $null = [Console]::ReadLine()
}

[Environment]::ExitCode = 0

# PSW_REMOVE_BASE64_BEGIN
# 77u/I1JlcXVpcmVzIC1WZXJzaW9uIDUuMQ0KPCMNCi5TWU5PUFNJUw0KICAgIFhvw6EgZmlsZS90aMawIG3hu6VjIHRoZW8gZGFuaCBzw6FjaCBj4bunYSBz
# Y2FuLW9uY2UucHMxLiBN4bq3YyDEkeG7i25oIGNo4buJIG3DtCBwaOG7j25nLg0KDQouREVTQ1JJUFRJT04NCiAgICDEkOG7jWMga+G6v3QgcXXhuqMgc2Nh
# biAoxrB1IHRpw6puIENTViArIGRhbmgtc2FjaC10aHUtbXVjLSoudHh0KSwga2nhu4NtIHRyYSBs4bqhaSB04burbmcNCiAgICDEkcaw4budbmcgZOG6q24g
# YuG6sW5nIGLhu5kgZ3VhcmQsIHLhu5NpOg0KDQogICAgICAtIEtow7RuZyBjw7MgLUV4ZWN1dGUgOiBjaOG7iSBpbiByYSAic+G6vSB4b8OhIGfDrCIuIEto
# w7RuZyDEkeG7pW5nIHbDoG8gZmlsZSBuw6BvLg0KICAgICAgLSBDw7MgLUV4ZWN1dGUgICAgICAgOiB4b8OhIGZpbGUsIHNhdSDEkcOzIHhvw6EgY8OhYyB0
# aMawIG3hu6VjIMSRw6MgcuG7l25nIChjb24gdHLGsOG7m2MNCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBjaGEpLiBD4bqnbiAtQ29uZmlybVRva2Vu
# IFhPQS4NCg0KICAgIFhvw6EgbMOgIHbEqW5oIHZp4buFbiwga2jDtG5nIGhvw6BuIHTDoWMgxJHGsOG7o2MuDQoNCi5QQVJBTUVURVIgUGxhbg0KICAgIFRo
# xrAgbeG7pWMga+G6v3QgcXXhuqMgc2NhbiwgaG/hurdjIGZpbGUgQ1NWL0pTT04uIELhu48gdHLhu5FuZzogZMO5bmcgcHJlc2FsZS1zY2FuLSoNCiAgICBt
# 4bubaSBuaOG6pXQgdHJvbmcgJVVTRVJQUk9GSUxFJS4NCg0KLlBBUkFNRVRFUiBGcm9tU2Nhbg0KICAgIMSQxrDhu6NjIHNjYW4tb25jZS5wczEgZ+G7jWkg
# buG7mWkgYuG7mTsga2jDtG5nIGTDuW5nIHRy4buxYyB0aeG6v3AuDQoNCi5QQVJBTUVURVIgRXhlY3V0ZQ0KICAgIFhvw6EgdGjhuq10Lg0KDQouUEFSQU1F
# VEVSIFllcw0KICAgIMSQw6MgeMOhYyBuaOG6rW4g4bufIGLGsOG7m2MgdHLGsOG7m2MgKHNjYW4tb25jZS5wczEgaOG7j2kgRW50ZXIpOiBraMO0bmcgaOG7
# j2kgbOG6oWkuDQogICAgQ2jhu4kgZMO5bmcgY8O5bmcgLUV4ZWN1dGUuDQoNCi5QQVJBTUVURVIgQ29uZmlybVRva2VuDQogICAgUGjhuqNpIGLhurFuZyAn
# WE9BJyBraGkgZMO5bmcgLUV4ZWN1dGUuDQoNCi5QQVJBTUVURVIgS2VlcA0KICAgIE3huqt1IHdpbGRjYXJkOiBmaWxlL3RoxrAgbeG7pWMga2jhu5twIHPh
# ur0gS0jDlE5HIGLhu4sgeG/DoS4NCg0KLlBBUkFNRVRFUiBNYXhGaWxlcw0KICAgIFRy4bqnbiBz4buRIGZpbGUgbeG7l2kgbOG6p24uIDAgPSBraMO0bmcg
# Z2nhu5tpIGjhuqFuICht4bq3YyDEkeG7i25oKS4NCg0KLlBBUkFNRVRFUiBNYXhCeXRlcw0KICAgIFRy4bqnbiB04buVbmcgZHVuZyBsxrDhu6NuZyBt4buX
# aSBs4bqnbi4gMCA9IGtow7RuZyBnaeG7m2kgaOG6oW4gKG3hurdjIMSR4buLbmgpLg0KDQouRVhBTVBMRQ0KICAgIC5ccmVtb3ZlLW9uY2UucHMxDQogICAg
# LlxyZW1vdmUtb25jZS5wczEgLUV4ZWN1dGUgLUNvbmZpcm1Ub2tlbiBYT0ENCiM+DQpbQ21kbGV0QmluZGluZygpXQ0KcGFyYW0oDQogICAgW1BhcmFtZXRl
# cihQb3NpdGlvbiA9IDApXQ0KICAgIFtzdHJpbmddJFBsYW4sDQoNCiAgICBbc3dpdGNoXSRGcm9tU2NhbiwNCg0KICAgIFtzd2l0Y2hdJEV4ZWN1dGUsDQoN
# CiAgICBbc3dpdGNoXSRZZXMsDQoNCiAgICBbc3RyaW5nXSRDb25maXJtVG9rZW4sDQoNCiAgICBbc3RyaW5nW11dJEtlZXAgPSBAKCksDQoNCiAgICBbc3Ry
# aW5nXSRPdXREaXIsDQoNCiAgICBbaW50XSRNYXhGaWxlcyA9IDAsDQoNCiAgICBbbG9uZ10kTWF4Qnl0ZXMgPSAwLA0KDQogICAgW3N3aXRjaF0kUXVpZXQN
# CikNCg0KU2V0LVN0cmljdE1vZGUgLVZlcnNpb24gTGF0ZXN0DQokRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gJ1N0b3AnDQoNCnRyeSB7IFtDb25zb2xlXTo6
# T3V0cHV0RW5jb2RpbmcgPSBbU3lzdGVtLlRleHQuVVRGOEVuY29kaW5nXTo6bmV3KCRmYWxzZSkgfSBjYXRjaCB7IH0NCg0KJHNjcmlwdDpSdW5JZCA9IEdl
# dC1EYXRlIC1Gb3JtYXQgJ3l5eXlNTWRkLUhIbW1zcycNCiRzY3JpcHQ6VG9vbFJvb3QgPSAkUFNTY3JpcHRSb290DQokc2NyaXB0OkdyZWVuID0gW0NvbnNv
# bGVDb2xvcl06OkdyZWVuDQokc2NyaXB0OlJlZCA9IFtDb25zb2xlQ29sb3JdOjpSZWQNCg0KZnVuY3Rpb24gV3JpdGUtTGluZSB7DQogICAgcGFyYW0oW3N0
# cmluZ10kVGV4dCwgW0NvbnNvbGVDb2xvcl0kQ29sb3IgPSAkc2NyaXB0OkdyZWVuKQ0KICAgIHRyeSB7DQogICAgICAgIFtDb25zb2xlXTo6Rm9yZWdyb3Vu
# ZENvbG9yID0gJENvbG9yDQogICAgfSBjYXRjaCB7IH0NCiAgICBbQ29uc29sZV06Ok91dC5Xcml0ZUxpbmUoJFRleHQpDQp9DQoNCmZ1bmN0aW9uIFdyaXRl
# LUVycm9yLUxpbmUgew0KICAgIHBhcmFtKFtzdHJpbmddJFRleHQpDQogICAgV3JpdGUtTGluZSAkVGV4dCAkc2NyaXB0OlJlZA0KfQ0KDQojIEThu6tuZyBj
# w7MgYsOhbyBs4buXaS4gS2hpIMSRxrDhu6NjIHNjYW4tb25jZS5wczEgZ+G7jWkgKEZyb21TY2FuKSwgcGjhuqNpIFRIUk9XIGNo4bupIGtow7RuZw0KIyBl
# eGl0LCBu4bq/dSBraMO0bmcgc+G6vSBnaeG6v3QgbHXDtG4gdGnhur9uIHRyw6xuaCBjaGEuDQpmdW5jdGlvbiBTdG9wLVdpdGhFcnJvciB7DQogICAgcGFy
# YW0oW3N0cmluZ10kVGV4dCkNCiAgICBXcml0ZS1FcnJvci1MaW5lICRUZXh0DQogICAgaWYgKCRGcm9tU2NhbikgeyB0aHJvdyBbU3lzdGVtLk9wZXJhdGlv
# bkNhbmNlbGVkRXhjZXB0aW9uXTo6bmV3KCRUZXh0KSB9DQogICAgZXhpdCAyDQp9DQoNCmZ1bmN0aW9uIEZvcm1hdC1CeXRlcyB7DQogICAgcGFyYW0oW2xv
# bmddJEJ5dGVzKQ0KDQogICAgaWYgKCRCeXRlcyAtbHQgMTAyNCkgeyByZXR1cm4gIiRCeXRlcyBCIiB9DQogICAgJHZhbHVlID0gW2RvdWJsZV0kQnl0ZXMN
# CiAgICAkdW5pdHMgPSBAKCdCJywgJ0tCJywgJ01CJywgJ0dCJywgJ1RCJykNCiAgICAkaW5kZXggPSAwDQogICAgd2hpbGUgKCR2YWx1ZSAtZ2UgMTAyNCAt
# YW5kICRpbmRleCAtbHQgNCkgeyAkdmFsdWUgPSAkdmFsdWUgLyAxMDI0OyAkaW5kZXgrKyB9DQogICAgcmV0dXJuICR2YWx1ZS5Ub1N0cmluZygnRjEnLCBb
# U3lzdGVtLkdsb2JhbGl6YXRpb24uQ3VsdHVyZUluZm9dOjpJbnZhcmlhbnRDdWx0dXJlKSArICcgJyArICR1bml0c1skaW5kZXhdDQp9DQoNCmZ1bmN0aW9u
# IFRvLUxvbmcgew0KICAgIHBhcmFtKFtzdHJpbmddJFZhbHVlKQ0KICAgIGlmIChbc3RyaW5nXTo6SXNOdWxsT3JXaGl0ZVNwYWNlKCRWYWx1ZSkpIHsgcmV0
# dXJuICRWYWx1ZSB9DQogICAgaWYgKCRWYWx1ZS5TdGFydHNXaXRoKCdcXD9cJykpIHsgcmV0dXJuICRWYWx1ZSB9DQogICAgaWYgKCRWYWx1ZS5TdGFydHNX
# aXRoKCdcXCcpKSB7IHJldHVybiAnXFw/XFVOQ1wnICsgJFZhbHVlLlN1YnN0cmluZygyKS5UcmltU3RhcnQoJ1wnKSB9DQogICAgJGZ1bGwgPSAkVmFsdWUN
# CiAgICBpZiAoLW5vdCBbU3lzdGVtLklPLlBhdGhdOjpJc1BhdGhSb290ZWQoJGZ1bGwpKSB7DQogICAgICAgIHRyeSB7ICRmdWxsID0gW1N5c3RlbS5JTy5Q
# YXRoXTo6R2V0RnVsbFBhdGgoJGZ1bGwpIH0gY2F0Y2ggeyB9DQogICAgfQ0KICAgIGlmICgkZnVsbC5MZW5ndGggLWd0IDMpIHsgJGZ1bGwgPSAkZnVsbC5U
# cmltRW5kKCdcJykgfQ0KICAgIHJldHVybiAnXFw/XCcgKyAkZnVsbA0KfQ0KDQpmdW5jdGlvbiBHZXQtRnVsbFBhdGhTYWZlIHsNCiAgICBwYXJhbShbc3Ry
# aW5nXSRWYWx1ZSkNCiAgICBpZiAoW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkVmFsdWUpKSB7IHJldHVybiAkbnVsbCB9DQogICAgJGNhbmRpZGF0
# ZSA9ICRWYWx1ZQ0KICAgIGlmICgkY2FuZGlkYXRlLlN0YXJ0c1dpdGgoJ1xcP1xVTkNcJykpIHsgJGNhbmRpZGF0ZSA9ICdcXCcgKyAkY2FuZGlkYXRlLlN1
# YnN0cmluZyg4KSB9DQogICAgZWxzZWlmICgkY2FuZGlkYXRlLlN0YXJ0c1dpdGgoJ1xcP1wnKSkgeyAkY2FuZGlkYXRlID0gJGNhbmRpZGF0ZS5TdWJzdHJp
# bmcoNCkgfQ0KICAgICRjYW5kaWRhdGUgPSBbRW52aXJvbm1lbnRdOjpFeHBhbmRFbnZpcm9ubWVudFZhcmlhYmxlcygkY2FuZGlkYXRlKQ0KICAgIHRyeSB7
# ICRmdWxsID0gW1N5c3RlbS5JTy5QYXRoXTo6R2V0RnVsbFBhdGgoJGNhbmRpZGF0ZSkgfSBjYXRjaCB7IHJldHVybiAkbnVsbCB9DQogICAgaWYgKCRmdWxs
# Lkxlbmd0aCAtZ3QgMykgeyAkZnVsbCA9ICRmdWxsLlRyaW1FbmQoJ1wnKSB9DQogICAgcmV0dXJuICRmdWxsDQp9DQoNCiMgLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCiMgR3VhcmQNCiMgLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCiRzY3JpcHQ6Rm9yYmlkZGVuRXhhY3QgPSBOZXct
# T2JqZWN0ICdTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYy5IYXNoU2V0W3N0cmluZ10nIChbU3lzdGVtLlN0cmluZ0NvbXBhcmVyXTo6T3JkaW5hbElnbm9y
# ZUNhc2UpDQpmb3JlYWNoICgkbmFtZSBpbiBAKCdTeXN0ZW1Sb290JywgJ3dpbmRpcicsICdQcm9ncmFtRmlsZXMnLCAnUHJvZ3JhbUZpbGVzKHg4NiknLCAn
# UHJvZ3JhbVc2NDMyJywNCiAgICAgICAgJ1Byb2dyYW1EYXRhJywgJ0FMTFVTRVJTUFJPRklMRScsICdVU0VSUFJPRklMRScsICdQVUJMSUMnKSkgew0KICAg
# ICR2YWx1ZSA9IFtFbnZpcm9ubWVudF06OkdldEVudmlyb25tZW50VmFyaWFibGUoJG5hbWUpDQogICAgaWYgKC1ub3QgW3N0cmluZ106OklzTnVsbE9yV2hp
# dGVTcGFjZSgkdmFsdWUpKSB7DQogICAgICAgICRmdWxsID0gR2V0LUZ1bGxQYXRoU2FmZSAkdmFsdWUNCiAgICAgICAgaWYgKCRudWxsIC1uZSAkZnVsbCkg
# eyBbdm9pZF0kc2NyaXB0OkZvcmJpZGRlbkV4YWN0LkFkZCgkZnVsbCkgfQ0KICAgIH0NCn0NCmZvcmVhY2ggKCRuYW1lIGluIEAoJ0Rlc2t0b3AnLCAnTXlE
# b2N1bWVudHMnLCAnTXlQaWN0dXJlcycsICdNeU11c2ljJywgJ015VmlkZW9zJywNCiAgICAgICAgJ0FwcGxpY2F0aW9uRGF0YScsICdMb2NhbEFwcGxpY2F0
# aW9uRGF0YScsICdVc2VyUHJvZmlsZScsICdDb21tb25Eb2N1bWVudHMnKSkgew0KICAgIHRyeSB7DQogICAgICAgICR2YWx1ZSA9IFtFbnZpcm9ubWVudF06
# OkdldEZvbGRlclBhdGgoJG5hbWUpDQogICAgICAgIGlmICgtbm90IFtzdHJpbmddOjpJc051bGxPcldoaXRlU3BhY2UoJHZhbHVlKSkgew0KICAgICAgICAg
# ICAgJGZ1bGwgPSBHZXQtRnVsbFBhdGhTYWZlICR2YWx1ZQ0KICAgICAgICAgICAgaWYgKCRudWxsIC1uZSAkZnVsbCkgeyBbdm9pZF0kc2NyaXB0OkZvcmJp
# ZGRlbkV4YWN0LkFkZCgkZnVsbCkgfQ0KICAgICAgICB9DQogICAgfSBjYXRjaCB7IH0NCn0NCiRzY3JpcHRzUm9vdCA9IEdldC1GdWxsUGF0aFNhZmUgJHNj
# cmlwdDpUb29sUm9vdA0KaWYgKCRudWxsIC1uZSAkc2NyaXB0c1Jvb3QpIHsgW3ZvaWRdJHNjcmlwdDpGb3JiaWRkZW5FeGFjdC5BZGQoJHNjcmlwdHNSb290
# KSB9DQoNCiRzY3JpcHQ6TmV2ZXJUb3VjaCA9IE5ldy1PYmplY3QgJ1N5c3RlbS5Db2xsZWN0aW9ucy5HZW5lcmljLkhhc2hTZXRbc3RyaW5nXScgKFtTeXN0
# ZW0uU3RyaW5nQ29tcGFyZXJdOjpPcmRpbmFsSWdub3JlQ2FzZSkNCmZvcmVhY2ggKCRuYW1lIGluIEAoJ0FwcERhdGEnLCAnQXBwbGljYXRpb24gRGF0YScs
# ICdMb2NhbCBTZXR0aW5ncycpKSB7DQogICAgW3ZvaWRdJHNjcmlwdDpOZXZlclRvdWNoLkFkZCgkbmFtZSkNCn0NCg0KIyBUaMawIG3hu6VjIGjhu4cgdGjh
# u5FuZyBjaOG7iSBj4bqlbSDhu58gQ+G6pFAgR+G7kEMg4buULiBO4bq/dSBzbyDhu58gbeG7jWkgY+G6pXAgdGjDrCDEkcaw4budbmcgZOG6q24gTWF2ZW4N
# CiMgbmjGsCAnLi4uXC5tMlxyZXBvc2l0b3J5XG9yZ1xzcHJpbmdmcmFtZXdvcmtcYm9vdFwuLi4nIGPFqW5nIGLhu4sgY2jhurduIHbDrCBjw7MNCiMgxJFv
# 4bqhbiB0w6puICdib290Jywga2hp4bq/biBraMO0bmcgZmlsZSBuw6BvIHRyb25nIC5tMiDEkcaw4bujYyB4b8OhLg0KJHNjcmlwdDpOZXZlclRvdWNoVG9w
# TGV2ZWwgPSBOZXctT2JqZWN0ICdTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYy5IYXNoU2V0W3N0cmluZ10nIChbU3lzdGVtLlN0cmluZ0NvbXBhcmVyXTo6
# T3JkaW5hbElnbm9yZUNhc2UpDQpmb3JlYWNoICgkbmFtZSBpbiBAKCdXaW5kb3dzJywgJ1dpbmRvd3Mub2xkJywgJ1Byb2dyYW0gRmlsZXMnLCAnUHJvZ3Jh
# bSBGaWxlcyAoeDg2KScsICdQcm9ncmFtRGF0YScsDQogICAgICAgICdSZWNvdmVyeScsICdQZXJmTG9ncycsICdCb290JywgJ1N5c3RlbSBWb2x1bWUgSW5m
# b3JtYXRpb24nLCAnQ29uZmlnLk1zaScsICckUmVjeWNsZS5CaW4nKSkgew0KICAgIFt2b2lkXSRzY3JpcHQ6TmV2ZXJUb3VjaFRvcExldmVsLkFkZCgkbmFt
# ZSkNCn0NCg0KJHNjcmlwdDpDcml0aWNhbEZpbGVzID0gTmV3LU9iamVjdCAnU3lzdGVtLkNvbGxlY3Rpb25zLkdlbmVyaWMuSGFzaFNldFtzdHJpbmddJyAo
# W1N5c3RlbS5TdHJpbmdDb21wYXJlcl06Ok9yZGluYWxJZ25vcmVDYXNlKQ0KIyBDaOG7iSBmaWxlIG3DoCB2aeG7h2MgeG/DoSBjw7MgdGjhu4MgbMOgbSBo
# 4buPbmcvaOG7j25nIGjhu4cgdGjhu5FuZy4NCiMgJ3RodW1icy5kYicgdsOgICdkZXNrdG9wLmluaScgS0jDlE5HIG7hurFtIOG7nyDEkcOieTogY2jDum5n
# IGNo4buJIGzDoCBjYWNoZS9tZXRhZGF0YSBkbw0KIyBXaW5kb3dzIHThu7Egc2luaCBs4bqhaSwgdsOgIHRyxrDhu5tjIMSRw6J5IGLhu4sgY2jhurduIG7D
# qm4gc2F1IGtoaSB4b8OhIHByb2plY3QgduG6q24gY8Oybg0KIyBzw7N0IDIgZmlsZSwga2hp4bq/biB0aMawIG3hu6VjIHByb2plY3Qga2jDtG5nIHhvw6Eg
# xJHGsOG7o2MuDQpmb3JlYWNoICgkbmFtZSBpbiBAKCdwYWdlZmlsZS5zeXMnLCAnaGliZXJmaWwuc3lzJywgJ3N3YXBmaWxlLnN5cycsICdib290bWdyJywg
# J0JPT1ROWFQnLCAnbnRsZHInLA0KICAgICAgICAnbnRkZXRlY3QuY29tJywgJ2Jvb3QuaW5pJywgJ2lvLnN5cycsICdtc2Rvcy5zeXMnLA0KICAgICAgICAn
# YXV0b2V4ZWMuYmF0JywgJ2NvbmZpZy5zeXMnKSkgew0KICAgIFt2b2lkXSRzY3JpcHQ6Q3JpdGljYWxGaWxlcy5BZGQoJG5hbWUpDQp9DQoNCmZ1bmN0aW9u
# IEdldC1CbG9ja1JlYXNvbiB7DQogICAgcGFyYW0oW3N0cmluZ10kRnVsbFBhdGgsIFtzd2l0Y2hdJEFsbG93QXBwRGF0YSkNCg0KICAgIGlmIChbc3RyaW5n
# XTo6SXNOdWxsT3JXaGl0ZVNwYWNlKCRGdWxsUGF0aCkpIHsgcmV0dXJuICfEkMaw4budbmcgZOG6q24gcuG7l25nLicgfQ0KICAgIGlmICgkRnVsbFBhdGgg
# LW1hdGNoICdeW0EtWmEtel06XFw/JCcpIHsgcmV0dXJuICdMw6AgZ+G7kWMg4buVIMSRxKlhLicgfQ0KICAgIGlmICgkRnVsbFBhdGggLW1hdGNoICdeXFxc
# XCcpIHsgcmV0dXJuICfEkMaw4budbmcgZOG6q24gbeG6oW5nLicgfQ0KDQogICAgJHNlZ21lbnRzID0gQCgkRnVsbFBhdGguU3BsaXQoJ1wnKSB8IFdoZXJl
# LU9iamVjdCB7ICRfIC1uZSAnJyB9KQ0KICAgIGlmICgkc2VnbWVudHMuQ291bnQgLWVxIDApIHsgcmV0dXJuICfEkMaw4budbmcgZOG6q24gcuG7l25nLicg
# fQ0KICAgICRsZWFmID0gJHNlZ21lbnRzWyRzZWdtZW50cy5Db3VudCAtIDFdDQoNCiAgICBpZiAoJHNjcmlwdDpDcml0aWNhbEZpbGVzLkNvbnRhaW5zKCRs
# ZWFmKSkgeyByZXR1cm4gIkZpbGUgaOG7hyB0aOG7kW5nOiAkbGVhZiIgfQ0KDQogICAgIyBBcHBEYXRhOiBj4bqlbSDhu58gTeG7jEkgY+G6pXAgKHRy4bur
# IGzhu4tjaCBz4butIElERSDEkcaw4bujYyBjaG8gcGjDqXAgdMaw4budbmcgbWluaCkuDQogICAgJHNjYW5TZWdtZW50cyA9IGlmICgkRnVsbFBhdGggLW1h
# dGNoICdeXFxcXFw/XFwoLispJCcpIHsgJG1hdGNoZXNbMV0uU3BsaXQoJ1wnKSB9IGVsc2UgeyAkRnVsbFBhdGguU3BsaXQoJ1wnKSB9DQogICAgZm9yZWFj
# aCAoJHNlZ21lbnQgaW4gJHNjYW5TZWdtZW50cykgew0KICAgICAgICBpZiAoW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkc2VnbWVudCkpIHsgY29u
# dGludWUgfQ0KICAgICAgICBpZiAoJEFsbG93QXBwRGF0YSAtYW5kICRzZWdtZW50IC1lcSAnQXBwRGF0YScpIHsgY29udGludWUgfQ0KICAgICAgICBpZiAo
# JHNjcmlwdDpOZXZlclRvdWNoLkNvbnRhaW5zKCRzZWdtZW50KSkgeyByZXR1cm4gIk7hurFtIHRyb25nIHRoxrAgbeG7pWMgY+G6pW0gJyRzZWdtZW50Jy4i
# IH0NCiAgICB9DQoNCiAgICAjIFRoxrAgbeG7pWMgaOG7hyB0aOG7kW5nOiBjaOG7iSBj4bqlbSDhu58gY+G6pXAgZ+G7kWMg4buVIChDOlxXaW5kb3dzLCBD
# OlxCb290LCAuLi4pLg0KICAgIGlmICgkc2NhblNlZ21lbnRzLkNvdW50IC1ndCAxIC1hbmQgJHNjcmlwdDpOZXZlclRvdWNoVG9wTGV2ZWwuQ29udGFpbnMo
# JHNjYW5TZWdtZW50c1sxXSkpIHsNCiAgICAgICAgcmV0dXJuICJDaOG7qWEgdGjGsCBt4bulYyBj4bqlbSAnJCgkc2NhblNlZ21lbnRzWzFdKScuIg0KICAg
# IH0NCiAgICBmb3JlYWNoICgkZm9yYmlkZGVuIGluICRzY3JpcHQ6Rm9yYmlkZGVuRXhhY3QpIHsNCiAgICAgICAgaWYgKFtzdHJpbmddOjpFcXVhbHMoJEZ1
# bGxQYXRoLCAkZm9yYmlkZGVuLCBbU3RyaW5nQ29tcGFyaXNvbl06Ok9yZGluYWxJZ25vcmVDYXNlKSkgew0KICAgICAgICAgICAgcmV0dXJuICJMw6AgdGjG
# sCBt4bulYyBo4buHIHRo4buRbmcvbmfGsOG7nWkgZMO5bmcgKCRmb3JiaWRkZW4pLiINCiAgICAgICAgfQ0KICAgIH0NCg0KICAgIGZvcmVhY2ggKCRwYXR0
# ZXJuIGluICRLZWVwKSB7DQogICAgICAgIGlmIChbc3RyaW5nXTo6SXNOdWxsT3JXaGl0ZVNwYWNlKCRwYXR0ZXJuKSkgeyBjb250aW51ZSB9DQogICAgICAg
# IGlmICgkRnVsbFBhdGggLWxpa2UgJHBhdHRlcm4pIHsgcmV0dXJuICJLaOG7m3AgbeG6q3UgLUtlZXAgJyRwYXR0ZXJuJy4iIH0NCiAgICB9DQoNCiAgICBy
# ZXR1cm4gJG51bGwNCn0NCg0KIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLQ0KIyAxLiBUw6xtIGvhur90IHF14bqjIHNjYW4NCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCmlmIChbc3RyaW5nXTo6SXNOdWxsT3JXaGl0ZVNwYWNlKCRQbGFuKSkgew0KICAgICRob21lXyA9IFtFbnZp
# cm9ubWVudF06OkdldEZvbGRlclBhdGgoJ1VzZXJQcm9maWxlJykNCiAgICAkY2FuZGlkYXRlcyA9IEAoKQ0KICAgIGlmICgtbm90IFtzdHJpbmddOjpJc051
# bGxPcldoaXRlU3BhY2UoJGhvbWVfKSkgew0KICAgICAgICAkY2FuZGlkYXRlcyA9IEAoW1N5c3RlbS5JTy5EaXJlY3RvcnldOjpHZXREaXJlY3Rvcmllcygo
# VG8tTG9uZyAkaG9tZV8pLCAncHJlc2FsZS1zY2FuLSonKSB8DQogICAgICAgICAgICAgICAgU29ydC1PYmplY3QgLURlc2NlbmRpbmcpDQogICAgfQ0KICAg
# IGlmICgkY2FuZGlkYXRlcy5Db3VudCAtZXEgMCkgew0KICAgICAgICBTdG9wLVdpdGhFcnJvciAoJ0zhu5ZJOiBjaMawYSBjw7Mga+G6v3QgcXXhuqMgc2Nh
# biB0cm9uZyB0aMawIG3hu6VjIG5nxrDhu51pIGTDuW5nLicgKyAiYHJgbiIgKw0KICAgICAgICAgICAgJ0No4bqheSBwcmVzYWxlLXNjYW4uY21kIHRyxrDh
# u5tjLCBob+G6t2MgY2jhu4kgxJHhu4tuaCAtUGxhbiA8xJHGsOG7nW5nIGThuqtuPi4nKQ0KICAgIH0NCiAgICAkUGxhbiA9ICRjYW5kaWRhdGVzWzBdDQp9
# DQoNCiRwbGFuRGlyID0gJG51bGwNCiRmaWxlc1NvdXJjZSA9ICRudWxsDQokZGlyc1NvdXJjZSA9ICRudWxsDQoNCmlmIChbU3lzdGVtLklPLkRpcmVjdG9y
# eV06OkV4aXN0cygoVG8tTG9uZyAkUGxhbikpKSB7DQogICAgJHBsYW5EaXIgPSBHZXQtRnVsbFBhdGhTYWZlICRQbGFuDQogICAgJGNzdiA9IEAoW1N5c3Rl
# bS5JTy5EaXJlY3RvcnldOjpHZXRGaWxlcygoVG8tTG9uZyAkcGxhbkRpciksICdkYW5oLXNhY2gtZmlsZS0qLmNzdicpIHwgU29ydC1PYmplY3QgLURlc2Nl
# bmRpbmcpDQogICAgJGpzb24gPSBAKFtTeXN0ZW0uSU8uRGlyZWN0b3J5XTo6R2V0RmlsZXMoKFRvLUxvbmcgJHBsYW5EaXIpLCAnZGFuaC1zYWNoLWZpbGUt
# Ki5qc29uJykgfCBTb3J0LU9iamVjdCAtRGVzY2VuZGluZykNCiAgICAkZGlycyA9IEAoW1N5c3RlbS5JTy5EaXJlY3RvcnldOjpHZXRGaWxlcygoVG8tTG9u
# ZyAkcGxhbkRpciksICdkYW5oLXNhY2gtdGh1LW11Yy0qLnR4dCcpIHwgU29ydC1PYmplY3QgLURlc2NlbmRpbmcpDQogICAgaWYgKCRjc3YuQ291bnQgLWd0
# IDApIHsgJGZpbGVzU291cmNlID0gJGNzdlswXSB9DQogICAgZWxzZWlmICgkanNvbi5Db3VudCAtZ3QgMCkgeyAkZmlsZXNTb3VyY2UgPSAkanNvblswXSB9
# DQogICAgaWYgKCRkaXJzLkNvdW50IC1ndCAwKSB7ICRkaXJzU291cmNlID0gJGRpcnNbMF0gfQ0KfSBlbHNlIHsNCiAgICAkZnVsbCA9IEdldC1GdWxsUGF0
# aFNhZmUgJFBsYW4NCiAgICBpZiAoJG51bGwgLWVxICRmdWxsIC1vciAtbm90IFtTeXN0ZW0uSU8uRmlsZV06OkV4aXN0cygoVG8tTG9uZyAkZnVsbCkpKSB7
# DQogICAgICAgIFN0b3AtV2l0aEVycm9yICJM4buWSToga2jDtG5nIHTDrG0gdGjhuqV5IGvhur90IHF14bqjIHNjYW46ICRQbGFuIg0KICAgIH0NCiAgICAk
# ZmlsZXNTb3VyY2UgPSAkZnVsbA0KICAgICRwbGFuRGlyID0gW1N5c3RlbS5JTy5QYXRoXTo6R2V0RGlyZWN0b3J5TmFtZSgkZnVsbCkNCiAgICAkZGlycyA9
# IEAoW1N5c3RlbS5JTy5EaXJlY3RvcnldOjpHZXRGaWxlcygoVG8tTG9uZyAkcGxhbkRpciksICdkYW5oLXNhY2gtdGh1LW11Yy0qLnR4dCcpIHwgU29ydC1P
# YmplY3QgLURlc2NlbmRpbmcpDQogICAgaWYgKCRkaXJzLkNvdW50IC1ndCAwKSB7ICRkaXJzU291cmNlID0gJGRpcnNbMF0gfQ0KfQ0KDQppZiAoW3N0cmlu
# Z106OklzTnVsbE9yV2hpdGVTcGFjZSgkZmlsZXNTb3VyY2UpKSB7DQogICAgU3RvcC1XaXRoRXJyb3IgIkzhu5ZJOiBraMO0bmcgdGjhuqV5IGRhbmgtc2Fj
# aC1maWxlLSouY3N2Ly5qc29uIHRyb25nICRwbGFuRGlyIg0KfQ0KDQojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tDQojIDIuIMSQ4buNYyBkYW5oIHPDoWNoIGZpbGUNCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCiRmaWxlTGlzdCA9IE5ldy1PYmplY3QgJ1N5c3RlbS5Db2xsZWN0
# aW9ucy5HZW5lcmljLkxpc3Rbc3RyaW5nXScNCmlmICgkZmlsZXNTb3VyY2UuRW5kc1dpdGgoJy5jc3YnLCBbU3RyaW5nQ29tcGFyaXNvbl06Ok9yZGluYWxJ
# Z25vcmVDYXNlKSkgew0KICAgICRyZWFkZXIgPSBOZXctT2JqZWN0IFN5c3RlbS5JTy5TdHJlYW1SZWFkZXIgKChUby1Mb25nICRmaWxlc1NvdXJjZSksIFtT
# eXN0ZW0uVGV4dC5FbmNvZGluZ106OlVURjgpDQogICAgdHJ5IHsNCiAgICAgICAgJG51bGwgPSAkcmVhZGVyLlJlYWRMaW5lKCkNCiAgICAgICAgd2hpbGUg
# KCRudWxsIC1uZSAoJGxpbmUgPSAkcmVhZGVyLlJlYWRMaW5lKCkpKSB7DQogICAgICAgICAgICBpZiAoW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgk
# bGluZSkpIHsgY29udGludWUgfQ0KICAgICAgICAgICAgIyBD4buZdCDEkeG6p3UgbMOgIHBhdGggdHJvbmcgbmdv4bq3YyBrw6lwIChjw7MgdGjhu4MgY2jh
# u6lhIGThuqV1IHBo4bqpeSkuDQogICAgICAgICAgICBpZiAoJGxpbmVbMF0gLW5lICciJykgeyBjb250aW51ZSB9DQogICAgICAgICAgICAkY2xvc2UgPSAk
# bGluZS5JbmRleE9mKCciLCInKQ0KICAgICAgICAgICAgaWYgKCRjbG9zZSAtbHQgMCkgeyBjb250aW51ZSB9DQogICAgICAgICAgICAkZmlsZUxpc3QuQWRk
# KCRsaW5lLlN1YnN0cmluZygxLCAkY2xvc2UgLSAxKS5SZXBsYWNlKCciIicsICciJykpDQogICAgICAgIH0NCiAgICB9IGZpbmFsbHkgeyAkcmVhZGVyLkRp
# c3Bvc2UoKSB9DQp9IGVsc2Ugew0KICAgICRqc29uT2JqID0gW1N5c3RlbS5JTy5GaWxlXTo6UmVhZEFsbFRleHQoKFRvLUxvbmcgJGZpbGVzU291cmNlKSwg
# W1N5c3RlbS5UZXh0LkVuY29kaW5nXTo6VVRGOCkgfCBDb252ZXJ0RnJvbS1Kc29uDQogICAgaWYgKCRudWxsIC1uZSAkanNvbk9iai5QU09iamVjdC5Qcm9w
# ZXJ0aWVzWydmaWxlcyddKSB7DQogICAgICAgIGZvcmVhY2ggKCRlbnRyeSBpbiBAKCRqc29uT2JqLmZpbGVzKSkgeyAkZmlsZUxpc3QuQWRkKFtzdHJpbmdd
# JGVudHJ5LnBhdGgpIH0NCiAgICB9DQp9DQoNCmlmICgkZmlsZUxpc3QuQ291bnQgLWVxIDApIHsNCiAgICBXcml0ZS1MaW5lICdEYW5oIHPDoWNoIHLhu5du
# ZyAtIGtow7RuZyBjw7MgZ8OsIMSR4buDIGThu41uLicNCiAgICBpZiAoJEZyb21TY2FuKSB7IHJldHVybiB9IGVsc2UgeyBleGl0IDAgfQ0KfQ0KDQojIC0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tDQojIDMuIMSQ4buNYyBk
# YW5oIHPDoWNoIHRoxrAgbeG7pWMgKGNvbiB0csaw4bubYyBjaGEsIMSRw6Mgc+G6r3AgdHJvbmcgZmlsZSkNCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCiRkaXJMaXN0ID0gTmV3LU9iamVjdCAnU3lzdGVtLkNvbGxl
# Y3Rpb25zLkdlbmVyaWMuTGlzdFtzdHJpbmddJw0KaWYgKC1ub3QgW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkZGlyc1NvdXJjZSkpIHsNCiAgICAk
# cmVhZGVyID0gTmV3LU9iamVjdCBTeXN0ZW0uSU8uU3RyZWFtUmVhZGVyICgoVG8tTG9uZyAkZGlyc1NvdXJjZSksIFtTeXN0ZW0uVGV4dC5FbmNvZGluZ106
# OlVURjgpDQogICAgdHJ5IHsNCiAgICAgICAgd2hpbGUgKCRudWxsIC1uZSAoJGxpbmUgPSAkcmVhZGVyLlJlYWRMaW5lKCkpKSB7DQogICAgICAgICAgICBp
# ZiAoW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkbGluZSkgLW9yICRsaW5lLlN0YXJ0c1dpdGgoJyMnKSkgeyBjb250aW51ZSB9DQogICAgICAgICAg
# ICAkZGlyTGlzdC5BZGQoJGxpbmUpDQogICAgICAgIH0NCiAgICB9IGZpbmFsbHkgeyAkcmVhZGVyLkRpc3Bvc2UoKSB9DQp9DQoNCiMgTOG7i2NoIHPhu60g
# SURFOiBkYW5oIHPDoWNoIMSRxrDhu51uZyBk4bqrbiDEkcaw4bujYyBwaMOpcCB4b8OhIGTDuSBu4bqxbSB0cm9uZyBBcHBEYXRhLg0KJGlkZUFsbG93ZWQg
# PSBOZXctT2JqZWN0ICdTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYy5MaXN0W3N0cmluZ10nDQppZiAoLW5vdCBbc3RyaW5nXTo6SXNOdWxsT3JXaGl0ZVNw
# YWNlKCRwbGFuRGlyKSkgew0KICAgICRpZGVGaWxlcyA9IEAoW1N5c3RlbS5JTy5EaXJlY3RvcnldOjpHZXRGaWxlcygoVG8tTG9uZyAkcGxhbkRpciksICdk
# YW5oLXNhY2gtaWRlLSoudHh0JykgfCBTb3J0LU9iamVjdCAtRGVzY2VuZGluZykNCiAgICBpZiAoJGlkZUZpbGVzLkNvdW50IC1ndCAwKSB7DQogICAgICAg
# ICRyZWFkZXIgPSBOZXctT2JqZWN0IFN5c3RlbS5JTy5TdHJlYW1SZWFkZXIgKChUby1Mb25nICRpZGVGaWxlc1swXSksIFtTeXN0ZW0uVGV4dC5FbmNvZGlu
# Z106OlVURjgpDQogICAgICAgIHRyeSB7DQogICAgICAgICAgICB3aGlsZSAoJG51bGwgLW5lICgkbGluZSA9ICRyZWFkZXIuUmVhZExpbmUoKSkpIHsNCiAg
# ICAgICAgICAgICAgICBpZiAoW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkbGluZSkgLW9yICRsaW5lLlN0YXJ0c1dpdGgoJyMnKSkgeyBjb250aW51
# ZSB9DQogICAgICAgICAgICAgICAgJHBpcGUgPSAkbGluZS5MYXN0SW5kZXhPZignfCcpDQogICAgICAgICAgICAgICAgJHBhdGggPSBpZiAoJHBpcGUgLWd0
# IDApIHsgJGxpbmUuU3Vic3RyaW5nKDAsICRwaXBlKSB9IGVsc2UgeyAkbGluZSB9DQogICAgICAgICAgICAgICAgJGZ1bGwgPSBHZXQtRnVsbFBhdGhTYWZl
# ICRwYXRoLlRyaW0oKQ0KICAgICAgICAgICAgICAgIGlmICgkbnVsbCAtbmUgJGZ1bGwpIHsgJGlkZUFsbG93ZWQuQWRkKCRmdWxsKSB9DQogICAgICAgICAg
# ICB9DQogICAgICAgIH0gZmluYWxseSB7ICRyZWFkZXIuRGlzcG9zZSgpIH0NCiAgICB9DQp9DQoNCmZ1bmN0aW9uIFRlc3QtSWRlQWxsb3dlZCB7DQogICAg
# cGFyYW0oW3N0cmluZ10kRnVsbFBhdGgpDQoNCiAgICBmb3JlYWNoICgkYWxsb3dlZCBpbiAkaWRlQWxsb3dlZCkgew0KICAgICAgICBpZiAoW3N0cmluZ106
# OkVxdWFscygkRnVsbFBhdGgsICRhbGxvd2VkLCBbU3RyaW5nQ29tcGFyaXNvbl06Ok9yZGluYWxJZ25vcmVDYXNlKSkgeyByZXR1cm4gJHRydWUgfQ0KICAg
# ICAgICAkcHJlZml4ID0gaWYgKCRhbGxvd2VkLkVuZHNXaXRoKCdcJykpIHsgJGFsbG93ZWQgfSBlbHNlIHsgJGFsbG93ZWQgKyAnXCcgfQ0KICAgICAgICBp
# ZiAoJEZ1bGxQYXRoLlN0YXJ0c1dpdGgoJHByZWZpeCwgW1N0cmluZ0NvbXBhcmlzb25dOjpPcmRpbmFsSWdub3JlQ2FzZSkpIHsgcmV0dXJuICR0cnVlIH0N
# CiAgICB9DQogICAgcmV0dXJuICRmYWxzZQ0KfQ0KDQojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tDQojIDQuIEzhu41jIGzhuqFpIHThu6tuZyBmaWxlDQojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tDQokd2lsbERlbGV0ZSA9IE5ldy1PYmplY3QgJ1N5c3RlbS5Db2xsZWN0aW9ucy5H
# ZW5lcmljLkxpc3Rbc3RyaW5nXScNCiRza2lwcGVkID0gTmV3LU9iamVjdCAnU3lzdGVtLkNvbGxlY3Rpb25zLkdlbmVyaWMuTGlzdFtvYmplY3RdJw0KJHNl
# ZW4gPSBOZXctT2JqZWN0ICdTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYy5IYXNoU2V0W3N0cmluZ10nIChbU3lzdGVtLlN0cmluZ0NvbXBhcmVyXTo6T3Jk
# aW5hbElnbm9yZUNhc2UpDQokdG90YWxCeXRlcyA9IDBMDQoNCmZvcmVhY2ggKCRyYXcgaW4gJGZpbGVMaXN0KSB7DQogICAgJGZ1bGwgPSBHZXQtRnVsbFBh
# dGhTYWZlICRyYXcNCiAgICBpZiAoJG51bGwgLWVxICRmdWxsKSB7DQogICAgICAgIFt2b2lkXSRza2lwcGVkLkFkZChbUFNDdXN0b21PYmplY3RdQHsgUGF0
# aCA9ICRyYXc7IFJlYXNvbiA9ICfEkMaw4budbmcgZOG6q24ga2jDtG5nIGjhu6NwIGzhu4cuJyB9KQ0KICAgICAgICBjb250aW51ZQ0KICAgIH0NCiAgICBp
# ZiAoLW5vdCAkc2Vlbi5BZGQoJGZ1bGwpKSB7IGNvbnRpbnVlIH0NCg0KICAgICMgTOG7i2NoIHPhu60gSURFIMSRxrDhu6NjIHBow6lwIG7hurFtIHRyb25n
# IEFwcERhdGE7IG3hu41pIGtp4buDbSB0cmEga2jDoWMgduG6q24gw6FwIGThu6VuZy4NCiAgICAkcmVhc29uID0gaWYgKFRlc3QtSWRlQWxsb3dlZCAkZnVs
# bCkgeyBHZXQtQmxvY2tSZWFzb24gJGZ1bGwgLUFsbG93QXBwRGF0YSB9IGVsc2UgeyBHZXQtQmxvY2tSZWFzb24gJGZ1bGwgfQ0KICAgIGlmICgkbnVsbCAt
# bmUgJHJlYXNvbikgew0KICAgICAgICBbdm9pZF0kc2tpcHBlZC5BZGQoW1BTQ3VzdG9tT2JqZWN0XUB7IFBhdGggPSAkZnVsbDsgUmVhc29uID0gJHJlYXNv
# biB9KQ0KICAgICAgICBjb250aW51ZQ0KICAgIH0NCiAgICBpZiAoLW5vdCBbU3lzdGVtLklPLkZpbGVdOjpFeGlzdHMoKFRvLUxvbmcgJGZ1bGwpKSkgew0K
# ICAgICAgICBbdm9pZF0kc2tpcHBlZC5BZGQoW1BTQ3VzdG9tT2JqZWN0XUB7IFBhdGggPSAkZnVsbDsgUmVhc29uID0gJ0ZpbGUga2jDtG5nIGPDsm4gdOG7
# k24gdOG6oWkuJyB9KQ0KICAgICAgICBjb250aW51ZQ0KICAgIH0NCg0KICAgIHRyeSB7ICR0b3RhbEJ5dGVzICs9IChOZXctT2JqZWN0IFN5c3RlbS5JTy5G
# aWxlSW5mbyAoVG8tTG9uZyAkZnVsbCkpLkxlbmd0aCB9IGNhdGNoIHsgfQ0KICAgICR3aWxsRGVsZXRlLkFkZCgkZnVsbCkNCn0NCg0KJGRpcnNUb1JlbW92
# ZSA9IE5ldy1PYmplY3QgJ1N5c3RlbS5Db2xsZWN0aW9ucy5HZW5lcmljLkxpc3Rbc3RyaW5nXScNCmZvcmVhY2ggKCRyYXcgaW4gJGRpckxpc3QpIHsNCiAg
# ICAkZnVsbCA9IEdldC1GdWxsUGF0aFNhZmUgJHJhdw0KICAgIGlmICgkbnVsbCAtZXEgJGZ1bGwpIHsgY29udGludWUgfQ0KICAgICRibG9ja2VkID0gaWYg
# KFRlc3QtSWRlQWxsb3dlZCAkZnVsbCkgeyBHZXQtQmxvY2tSZWFzb24gJGZ1bGwgLUFsbG93QXBwRGF0YSB9IGVsc2UgeyBHZXQtQmxvY2tSZWFzb24gJGZ1
# bGwgfQ0KICAgIGlmICgkbnVsbCAtbmUgJGJsb2NrZWQpIHsgY29udGludWUgfQ0KICAgIGlmIChbU3lzdGVtLklPLkRpcmVjdG9yeV06OkV4aXN0cygoVG8t
# TG9uZyAkZnVsbCkpKSB7ICRkaXJzVG9SZW1vdmUuQWRkKCRmdWxsKSB9DQp9DQoNCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCiMgNS4gS2nhu4NtIHRyYSBo4bqhbiBt4bupYw0KIyAtLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQ0KJGRlc3RpbmF0aW9uID0gaWYgKFtzdHJpbmddOjpJ
# c051bGxPcldoaXRlU3BhY2UoJE91dERpcikpIHsgJHBsYW5EaXIgfSBlbHNlIHsgJE91dERpciB9DQppZiAoLW5vdCBbU3lzdGVtLklPLkRpcmVjdG9yeV06
# OkV4aXN0cygoVG8tTG9uZyAkZGVzdGluYXRpb24pKSkgew0KICAgIFt2b2lkXVtTeXN0ZW0uSU8uRGlyZWN0b3J5XTo6Q3JlYXRlRGlyZWN0b3J5KChUby1M
# b25nICRkZXN0aW5hdGlvbikpDQp9DQoNCmlmICgkRXhlY3V0ZSkgew0KICAgIGlmICgkQ29uZmlybVRva2VuIC1uZSAnWE9BJykgew0KICAgICAgICBTdG9w
# LVdpdGhFcnJvciAiTOG7lkk6IC1FeGVjdXRlIGPhuqduIC1Db25maXJtVG9rZW4gWE9BICh4b8OhIHbEqW5oIHZp4buFbiwga2jDtG5nIGhvw6BuIHTDoWMp
# LiINCiAgICB9DQogICAgaWYgKCRNYXhGaWxlcyAtZ3QgMCAtYW5kICR3aWxsRGVsZXRlLkNvdW50IC1ndCAkTWF4RmlsZXMpIHsNCiAgICAgICAgU3RvcC1X
# aXRoRXJyb3IgKCJM4buWSTogezB9IGZpbGUgdsaw4bujdCB0cuG6p24gLU1heEZpbGVzIHsxfS4gRMO5bmcgLUtlZXAsIGhv4bq3YyAtTWF4RmlsZXMgMCDE
# keG7gyBi4buPIGdp4bubaSBo4bqhbi4iIC1mICR3aWxsRGVsZXRlLkNvdW50LCAkTWF4RmlsZXMpDQogICAgfQ0KICAgIGlmICgkTWF4Qnl0ZXMgLWd0IDAg
# LWFuZCAkdG90YWxCeXRlcyAtZ3QgJE1heEJ5dGVzKSB7DQogICAgICAgIFN0b3AtV2l0aEVycm9yICgiTOG7lkk6IHswOk4xfSBHQiB2xrDhu6N0IHRy4bqn
# biAtTWF4Qnl0ZXMgezE6TjF9IEdCLiBEw7luZyAtTWF4Qnl0ZXMgMCDEkeG7gyBi4buPIGdp4bubaSBo4bqhbi4iIC1mICgkdG90YWxCeXRlcyAvIDFHQiks
# ICgkTWF4Qnl0ZXMgLyAxR0IpKQ0KICAgIH0NCn0NCg0KIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLQ0KIyA2LiBJbiBr4bq/IGhv4bqhY2ggKMSR4bunLCBraMO0bmcgY+G6r3QpDQojIC0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tDQpXcml0ZS1MaW5lICcnDQpXcml0ZS1MaW5lICgnPScg
# KiA3NikNCmlmICgkRXhlY3V0ZSkgew0KICAgIFdyaXRlLUxpbmUgJyAgcHJlc2FsZS13aXBlciAtIFhPw4EgVsSoTkggVknhu4ROJw0KfSBlbHNlIHsNCiAg
# ICBXcml0ZS1MaW5lICcgIHByZXNhbGUtd2lwZXIgLSBL4bq+IEhP4bqgQ0ggWE/DgSAobcO0IHBo4buPbmcsIENIxq9BIHhvw6EgZ8OsKScNCn0NCldyaXRl
# LUxpbmUgKCc9JyAqIDc2KQ0KV3JpdGUtTGluZSAnJw0KV3JpdGUtTGluZSAoIiAgTmd14buTbiBkYW5oIHPDoWNoIDogezB9IiAtZiAkZmlsZXNTb3VyY2Up
# DQpXcml0ZS1MaW5lICgiICBGaWxlIHPhur0geG/DoSAgICAgOiB7MH0gICh7MX0pIiAtZiAkd2lsbERlbGV0ZS5Db3VudCwgKEZvcm1hdC1CeXRlcyAkdG90
# YWxCeXRlcykpDQpXcml0ZS1MaW5lICgiICBUaMawIG3hu6VjIHPhur0gZOG7jW4gIDogezB9IiAtZiAkZGlyc1RvUmVtb3ZlLkNvdW50KQ0KV3JpdGUtTGlu
# ZSAoIiAgQuG7jyBxdWEgKGd1YXJkKSAgOiB7MH0iIC1mICRza2lwcGVkLkNvdW50KQ0KV3JpdGUtTGluZSAnJw0KDQppZiAoLW5vdCAkUXVpZXQpIHsNCiAg
# ICBpZiAoJHdpbGxEZWxldGUuQ291bnQgLWd0IDApIHsNCiAgICAgICAgV3JpdGUtTGluZSAnLS0tIEZpbGUgLS0tJw0KICAgICAgICBmb3JlYWNoICgkaXRl
# bSBpbiAkd2lsbERlbGV0ZSkgeyBXcml0ZS1MaW5lICgiICB7MH0iIC1mICRpdGVtKSB9DQogICAgICAgIFdyaXRlLUxpbmUgJycNCiAgICB9DQogICAgaWYg
# KCRkaXJzVG9SZW1vdmUuQ291bnQgLWd0IDApIHsNCiAgICAgICAgV3JpdGUtTGluZSAnLS0tIFRoxrAgbeG7pWMgKGNo4buJIHhvw6EgbuG6v3UgcuG7l25n
# KSAtLS0nDQogICAgICAgIGZvcmVhY2ggKCRpdGVtIGluICRkaXJzVG9SZW1vdmUpIHsgV3JpdGUtTGluZSAoIiAgezB9IiAtZiAkaXRlbSkgfQ0KICAgICAg
# ICBXcml0ZS1MaW5lICcnDQogICAgfQ0KICAgIGlmICgkc2tpcHBlZC5Db3VudCAtZ3QgMCkgew0KICAgICAgICBXcml0ZS1MaW5lICgiLS0tIELhu48gcXVh
# ICh7MH0pIC0tLSIgLWYgJHNraXBwZWQuQ291bnQpDQogICAgICAgIGZvcmVhY2ggKCRpdGVtIGluICRza2lwcGVkKSB7IFdyaXRlLUxpbmUgKCIgIFt7MH1d
# IHsxfSIgLWYgJGl0ZW0uUmVhc29uLCAkaXRlbS5QYXRoKSB9DQogICAgICAgIFdyaXRlLUxpbmUgJycNCiAgICB9DQp9DQoNCiMgLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0NCiMgNy4gWG/DoQ0KIyAtLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQ0KJGRlbGV0ZWQgPSAwDQokcmVtb3ZlZERp
# cnMgPSAwDQokZmFpbGVkID0gTmV3LU9iamVjdCAnU3lzdGVtLkNvbGxlY3Rpb25zLkdlbmVyaWMuTGlzdFtvYmplY3RdJw0KDQppZiAoJEV4ZWN1dGUpIHsN
# CiAgICAkcHJvZ3Jlc3MgPSAkbnVsbA0KICAgIHRyeSB7DQogICAgICAgICRwcm9ncmVzcyA9IE5ldy1PYmplY3QgU3lzdGVtLldpbmRvd3MuRm9ybXMuRm9y
# bQ0KICAgICAgICAkcHJvZ3Jlc3MuVGV4dCA9ICdwcmVzYWxlLXdpcGVyIC0gxJFhbmcgeG/DoScNCiAgICAgICAgJHByb2dyZXNzLldpZHRoID0gNTIwDQog
# ICAgICAgICRwcm9ncmVzcy5IZWlnaHQgPSAxMzANCiAgICAgICAgJHByb2dyZXNzLlN0YXJ0UG9zaXRpb24gPSAnQ2VudGVyU2NyZWVuJw0KICAgICAgICAk
# cHJvZ3Jlc3MuRm9ybUJvcmRlclN0eWxlID0gJ0ZpeGVkRGlhbG9nJw0KICAgICAgICAkcHJvZ3Jlc3MuTWF4aW1pemVCb3ggPSAkZmFsc2UNCiAgICAgICAg
# JHByb2dyZXNzLk1pbmltaXplQm94ID0gJGZhbHNlDQogICAgICAgICRsYWJlbCA9IE5ldy1PYmplY3QgU3lzdGVtLldpbmRvd3MuRm9ybXMuTGFiZWwNCiAg
# ICAgICAgJGxhYmVsLkxlZnQgPSAxNjsgJGxhYmVsLlRvcCA9IDE0OyAkbGFiZWwuV2lkdGggPSA0ODA7ICRsYWJlbC5UZXh0ID0gJ8SQYW5nIGNodeG6qW4g
# YuG7iy4uLicNCiAgICAgICAgJGJhciA9IE5ldy1PYmplY3QgU3lzdGVtLldpbmRvd3MuRm9ybXMuUHJvZ3Jlc3NCYXINCiAgICAgICAgJGJhci5MZWZ0ID0g
# MTY7ICRiYXIuVG9wID0gNDQ7ICRiYXIuV2lkdGggPSA0ODA7ICRiYXIuSGVpZ2h0ID0gMjINCiAgICAgICAgJGJhci5NaW5pbXVtID0gMDsgJGJhci5NYXhp
# bXVtID0gW01hdGhdOjpNYXgoMSwgJHdpbGxEZWxldGUuQ291bnQpDQogICAgICAgIFt2b2lkXSRwcm9ncmVzcy5Db250cm9scy5BZGQoJGxhYmVsKQ0KICAg
# ICAgICBbdm9pZF0kcHJvZ3Jlc3MuQ29udHJvbHMuQWRkKCRiYXIpDQogICAgICAgICRwcm9ncmVzcy5TaG93KCkNCiAgICAgICAgJHByb2dyZXNzLlJlZnJl
# c2goKQ0KICAgIH0gY2F0Y2ggeyAkcHJvZ3Jlc3MgPSAkbnVsbCB9DQoNCiAgICBmb3IgKCRpID0gMDsgJGkgLWx0ICR3aWxsRGVsZXRlLkNvdW50OyAkaSsr
# KSB7DQogICAgICAgICRwYXRoID0gJHdpbGxEZWxldGVbJGldDQogICAgICAgICRsb25nID0gVG8tTG9uZyAkcGF0aA0KICAgICAgICAkb2sgPSAkZmFsc2UN
# CiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgIFtTeXN0ZW0uSU8uRmlsZV06OkRlbGV0ZSgkbG9uZykNCiAgICAgICAgICAgICRvayA9ICR0cnVlDQogICAg
# ICAgIH0gY2F0Y2ggew0KICAgICAgICAgICAgIyBXaW5kb3dzIGhheSBraG/DoSB0aHVtYnMuZGIgLyBkZXNrdG9wLmluaSB2w6AgZmlsZSBjaOG7iS3EkeG7
# jWMuIELhu48NCiAgICAgICAgICAgICMgdGh14buZYyB0w61uaCBy4buTaSB0aOG7rSBs4bqhaSBt4buZdCBs4bqnbiB0csaw4bubYyBraGkgY29pIGzDoCBs
# 4buXaS4NCiAgICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgW1N5c3RlbS5JTy5GaWxlXTo6U2V0QXR0cmlidXRlcygkbG9uZywgW1N5c3RlbS5J
# Ty5GaWxlQXR0cmlidXRlc106Ok5vcm1hbCkNCiAgICAgICAgICAgICAgICBbU3lzdGVtLklPLkZpbGVdOjpEZWxldGUoJGxvbmcpDQogICAgICAgICAgICAg
# ICAgJG9rID0gJHRydWUNCiAgICAgICAgICAgIH0gY2F0Y2ggew0KICAgICAgICAgICAgICAgIFt2b2lkXSRmYWlsZWQuQWRkKFtQU0N1c3RvbU9iamVjdF1A
# eyBQYXRoID0gJHBhdGg7IFJlYXNvbiA9ICRfLkV4Y2VwdGlvbi5NZXNzYWdlIH0pDQogICAgICAgICAgICB9DQogICAgICAgIH0NCiAgICAgICAgaWYgKCRv
# aykgeyAkZGVsZXRlZCsrIH0NCg0KICAgICAgICBpZiAoJG51bGwgLW5lICRwcm9ncmVzcyAtYW5kICgkaSAlIDI1IC1lcSAwIC1vciAkaSAtZXEgJHdpbGxE
# ZWxldGUuQ291bnQgLSAxKSkgew0KICAgICAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICAkYmFyLlZhbHVlID0gW01hdGhdOjpNaW4oJGJhci5NYXhp
# bXVtLCAkaSArIDEpDQogICAgICAgICAgICAgICAgJGxhYmVsLlRleHQgPSAoJ8SQw6MgeG/DoSB7MH0vezF9IGZpbGUnIC1mICgkaSArIDEpLCAkd2lsbERl
# bGV0ZS5Db3VudCkNCiAgICAgICAgICAgICAgICAkcHJvZ3Jlc3MuUmVmcmVzaCgpDQogICAgICAgICAgICB9IGNhdGNoIHsgfQ0KICAgICAgICB9DQogICAg
# fQ0KDQogICAgIyBE4buNbiB0aMawIG3hu6VjOiBmaWxlIMSRw6Mgc+G6r3AgdGhlbyDEkeG7mSBzw6J1IG7Dqm4geG/DoSB4b25nIGZpbGUgdGjDrCB0aMaw
# IG3hu6VjIHLhu5duZyBk4bqnbi4NCiAgICAkbGVmdG92ZXJEaXJzID0gTmV3LU9iamVjdCAnU3lzdGVtLkNvbGxlY3Rpb25zLkdlbmVyaWMuTGlzdFtzdHJp
# bmddJw0KICAgIGZvciAoJGkgPSAwOyAkaSAtbHQgJGRpcnNUb1JlbW92ZS5Db3VudDsgJGkrKykgew0KICAgICAgICB0cnkgew0KICAgICAgICAgICAgW1N5
# c3RlbS5JTy5EaXJlY3RvcnldOjpEZWxldGUoKFRvLUxvbmcgJGRpcnNUb1JlbW92ZVskaV0pLCAkZmFsc2UpDQogICAgICAgICAgICAkcmVtb3ZlZERpcnMr
# Kw0KICAgICAgICB9IGNhdGNoIHsNCiAgICAgICAgICAgICMgQ8OybiBmaWxlIGzhuqEgaG/hurdjIHRoxrAgbeG7pWMgYuG7iyBraG/DoTogZ2hpIGzhuqFp
# IMSR4buDIGLDoW8gY2hvIG5nxrDhu51pIGTDuW5nDQogICAgICAgICAgICAjIGJp4bq/dCBjaMOtbmggeMOhYyBjw6FpIGfDrCBjw7JuIHPDs3QsIHRoYXkg
# dsOsIGltIGzhurduZyBi4buPIHF1YS4NCiAgICAgICAgICAgICRsZWZ0b3ZlckRpcnMuQWRkKCRkaXJzVG9SZW1vdmVbJGldKQ0KICAgICAgICB9DQogICAg
# ICAgIGlmICgkbnVsbCAtbmUgJHByb2dyZXNzIC1hbmQgKCRpICUgMjUgLWVxIDAgLW9yICRpIC1lcSAkZGlyc1RvUmVtb3ZlLkNvdW50IC0gMSkpIHsNCiAg
# ICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgJGxhYmVsLlRleHQgPSAoJ8SQw6MgeG/DoSB7MH0gZmlsZSwgZOG7jW4gezF9L3syfSB0aMawIG3h
# u6VjJyAtZiAkZGVsZXRlZCwgKCRpICsgMSksICRkaXJzVG9SZW1vdmUuQ291bnQpDQogICAgICAgICAgICAgICAgJHByb2dyZXNzLlJlZnJlc2goKQ0KICAg
# ICAgICAgICAgfSBjYXRjaCB7IH0NCiAgICAgICAgfQ0KICAgIH0NCg0KICAgIGlmICgkbnVsbCAtbmUgJHByb2dyZXNzKSB7DQogICAgICAgIHRyeSB7ICRw
# cm9ncmVzcy5DbG9zZSgpOyAkcHJvZ3Jlc3MuRGlzcG9zZSgpIH0gY2F0Y2ggeyB9DQogICAgfQ0KfQ0KDQojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tDQojIDguIELDoW8gY8Ohbw0KIyAtLS0tLS0tLS0tLS0tLS0tLS0t
# LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQ0KJG1vZGUgPSBpZiAoJEV4ZWN1dGUpIHsgJ2RlbGV0
# ZScgfSBlbHNlIHsgJ2RyeS1ydW4nIH0NCiRiYXNlTmFtZSA9IGlmICgkRXhlY3V0ZSkgeyAnZGEteG9hJyB9IGVsc2UgeyAna2UtaG9hY2gteG9hJyB9DQok
# c3RhbXAgPSAnezB9LXsxfScgLWYgJGJhc2VOYW1lLCAkc2NyaXB0OlJ1bklkDQojIENo4buJIGdoaSBN4buYVCBmaWxlIHTDs20gdOG6r3QuIERhbmggc8Oh
# Y2ggxJHGsOG7nW5nIGThuqtuIMSRw6MgY8OzIHRyb25nIENTViBj4bunYSBixrDhu5tjIHF1w6l0DQojIHLhu5NpOyB0csaw4bubYyDEkcOieSBixrDhu5tj
# IHhvw6EgZ2hpIHRow6ptIFRYVCArIEpTT04gY2jhu6lhIGzhuqFpIHRvw6BuIGLhu5kgxJHGsOG7nW5nIGThuqtuLCBsw6BtDQojIG3hu5dpIGzhuqduIGNo
# 4bqheSB04buRbiB0aMOqbSBow6BuZyB0csSDbSBNQi4NCiRzdW1tYXJ5UGF0aCA9IEpvaW4tUGF0aCAkZGVzdGluYXRpb24gIiRzdGFtcC5qc29uIg0KJG5v
# Qm9tID0gTmV3LU9iamVjdCBTeXN0ZW0uVGV4dC5VVEY4RW5jb2RpbmcoJGZhbHNlKQ0KDQokc3VtbWFyeSA9IFtvcmRlcmVkXUB7DQogICAgdG9vbCAgICAg
# ICAgPSAncHJlc2FsZS13aXBlciByZW1vdmUtb25jZScNCiAgICBtb2RlICAgICAgICA9ICRtb2RlDQogICAgc291cmNlICAgICAgPSAkZmlsZXNTb3VyY2UN
# CiAgICBnZW5lcmF0ZWRBdCA9IChHZXQtRGF0ZSkuVG9Vbml2ZXJzYWxUaW1lKCkuVG9TdHJpbmcoJ3l5eXktTU0tZGRUSEg6bW06c3NaJykNCiAgICBmaWxl
# cyAgICAgICA9ICR3aWxsRGVsZXRlLkNvdW50DQogICAgZGlyZWN0b3JpZXMgPSAkZGlyc1RvUmVtb3ZlLkNvdW50DQogICAgc2tpcHBlZCAgICAgPSAkc2tp
# cHBlZC5Db3VudA0KICAgIHNpemVCeXRlcyAgID0gJHRvdGFsQnl0ZXMNCiAgICBzaXplVGV4dCAgICA9IEZvcm1hdC1CeXRlcyAkdG90YWxCeXRlcw0KICAg
# IGRlbGV0ZWQgICAgID0gJGRlbGV0ZWQNCiAgICByZW1vdmVkRGlycyA9ICRyZW1vdmVkRGlycw0KICAgIGZhaWxlZCAgICAgID0gJGZhaWxlZC5Db3VudA0K
# ICAgIGZhaWxlZExpc3QgID0gQCgkZmFpbGVkIHwgRm9yRWFjaC1PYmplY3QgeyBbb3JkZXJlZF1AeyBwYXRoID0gJF8uUGF0aDsgcmVhc29uID0gJF8uUmVh
# c29uIH0gfSkNCiAgICBza2lwcGVkTGlzdCA9IEAoJHNraXBwZWQgfCBGb3JFYWNoLU9iamVjdCB7IFtvcmRlcmVkXUB7IHBhdGggPSAkXy5QYXRoOyByZWFz
# b24gPSAkXy5SZWFzb24gfSB9KQ0KICAgIGxlZnRvdmVyRGlycyA9IEAoJGxlZnRvdmVyRGlycykNCn0NCltTeXN0ZW0uSU8uRmlsZV06OldyaXRlQWxsVGV4
# dCgoVG8tTG9uZyAkc3VtbWFyeVBhdGgpLCAoQ29udmVydFRvLUpzb24gLUlucHV0T2JqZWN0ICRzdW1tYXJ5IC1EZXB0aCA2KSwgJG5vQm9tKQ0KDQpXcml0
# ZS1MaW5lICcnDQpXcml0ZS1MaW5lICgnPScgKiA3NikNCmlmICgkRXhlY3V0ZSkgew0KICAgIFdyaXRlLUxpbmUgJyAgxJDDgyBYT8OBIFhPTkcnDQp9IGVs
# c2Ugew0KICAgIFdyaXRlLUxpbmUgJyAgQ0jGr0EgWE/DgSBHw4wgKGNo4bq/IMSR4buZIG3DtCBwaOG7j25nKScNCn0NCldyaXRlLUxpbmUgKCc9JyAqIDc2
# KQ0KaWYgKCRFeGVjdXRlKSB7DQogICAgV3JpdGUtTGluZSAoIiAgRmlsZSDEkcOjIHhvw6EgICAgIDogezB9ICAoezF9KSIgLWYgJGRlbGV0ZWQsIChGb3Jt
# YXQtQnl0ZXMgJHRvdGFsQnl0ZXMpKQ0KICAgIFdyaXRlLUxpbmUgKCIgIFRoxrAgbeG7pWMgxJHDoyBk4buNbiAgOiB7MH0iIC1mICRyZW1vdmVkRGlycykN
# CiAgICBXcml0ZS1MaW5lICgiICBM4buXaSAgICAgICAgICAgICA6IHswfSIgLWYgJGZhaWxlZC5Db3VudCkNCiAgICBmb3JlYWNoICgkaXRlbSBpbiBAKCRm
# YWlsZWQgfCBTZWxlY3QtT2JqZWN0IC1GaXJzdCAyMCkpIHsNCiAgICAgICAgV3JpdGUtRXJyb3ItTGluZSAoIiAgICBbezB9XSB7MX0iIC1mICRpdGVtLlJl
# YXNvbiwgJGl0ZW0uUGF0aCkNCiAgICB9DQogICAgIyBOw7NpIHLDtSBjw6FpIGfDrCBjw7JuIHPDs3QuIFF1YW4gdHLhu41uZzogbuG6v3UgZmlsZSBsaeG7
# h3Qga8OqIMSRw6MgeG/DoSBo4bq/dCBtw6AgdGjGsCBt4bulYw0KICAgICMgduG6q24gY8OybiB0aMOsIHBo4bqjaSBiaeG6v3QgbmdheSwgdHLDoW5oIHTG
# sOG7n25nIMSRw6MgZOG7jW4gc+G6oWNoLg0KICAgIGlmIChAKCRsZWZ0b3ZlckRpcnMpLkNvdW50IC1ndCAwKSB7DQogICAgICAgIFdyaXRlLUxpbmUgJycN
# CiAgICAgICAgV3JpdGUtTGluZSAoIiAgVGjGsCBt4bulYyBjw7JuIGzhuqFpIDogezB9IChiw6puIHRyb25nIGPDsm4gZmlsZSBraMO0bmcgeG/DoSDEkcaw
# 4bujYykiIC1mIEAoJGxlZnRvdmVyRGlycykuQ291bnQpDQogICAgICAgIGZvcmVhY2ggKCRsZWZ0b3ZlciBpbiBAKCRsZWZ0b3ZlckRpcnMgfCBTZWxlY3Qt
# T2JqZWN0IC1GaXJzdCAyMCkpIHsNCiAgICAgICAgICAgICRyZW1haW4gPSAwDQogICAgICAgICAgICB0cnkgeyAkcmVtYWluID0gQChbU3lzdGVtLklPLkRp
# cmVjdG9yeV06OkdldEZpbGVTeXN0ZW1FbnRyaWVzKChUby1Mb25nICRsZWZ0b3ZlcikpKS5Db3VudCB9IGNhdGNoIHsgfQ0KICAgICAgICAgICAgV3JpdGUt
# RXJyb3ItTGluZSAoIiAgICBjw7JuIHswfSBt4bulYzogezF9IiAtZiAkcmVtYWluLCAkbGVmdG92ZXIpDQogICAgICAgIH0NCiAgICB9DQp9IGVsc2Ugew0K
# ICAgIFdyaXRlLUxpbmUgKCIgIFPhur0geG/DoSAgICAgICAgICA6IHswfSBmaWxlICAoezF9KSIgLWYgJHdpbGxEZWxldGUuQ291bnQsIChGb3JtYXQtQnl0
# ZXMgJHRvdGFsQnl0ZXMpKQ0KICAgIFdyaXRlLUxpbmUgKCIgIFPhur0gZOG7jW4gICAgICAgICAgOiB7MH0gdGjGsCBt4bulYyIgLWYgJGRpcnNUb1JlbW92
# ZS5Db3VudCkNCiAgICBXcml0ZS1MaW5lICcnDQogICAgV3JpdGUtTGluZSAnICBNdeG7kW4geG/DoSB0aOG6rXQsIGNo4bqheSBs4bqhaSB24bubaTogLUV4
# ZWN1dGUgLUNvbmZpcm1Ub2tlbiBYT0EnDQp9DQpXcml0ZS1MaW5lICcnDQpXcml0ZS1MaW5lICgiICBCw6FvIGPDoW86IHswfSIgLWYgJHN1bW1hcnlQYXRo
# KQ0KV3JpdGUtTGluZSAnJw0KDQppZiAoLW5vdCAkRXhlY3V0ZSAtYW5kIC1ub3QgJFF1aWV0IC1hbmQgLW5vdCAkWWVzKSB7DQogICAgIyBI4buPaSB4w6Fj
# IG5o4bqtbiBraGkgY2jhuqF5IHTGsMahbmcgdMOhYy4gxJBp4buBdSBraeG7h24gZOG7sWEgdHLDqm4gY29uc29sZSB0aOG6rXQsIEtIw5RORw0KICAgICMg
# ZOG7sWEgdsOgbyBiaeG6v24gbcO0aSB0csaw4budbmc6IHRyxrDhu5tjIMSRw6J5IGNo4buJIGPhuqduIHRoaeG6v3UgYmnhur9uIMSRw7MgbMOgIGLGsOG7
# m2MgeG/DoQ0KICAgICMgbOG6t25nIGzhur0gZOG7q25nIOG7nyBi4bqjbiBr4bq/IGhv4bqhY2gsIGtoaeG6v24gbmfGsOG7nWkgZMO5bmcgdMaw4bufbmcg
# xJHDoyB4b8OhLg0KICAgICRpbnRlcmFjdGl2ZSA9ICgtbm90IFtDb25zb2xlXTo6SXNJbnB1dFJlZGlyZWN0ZWQpIC1vciAkRnJvbVNjYW4NCiAgICBpZiAo
# JGludGVyYWN0aXZlKSB7DQogICAgICAgIFdyaXRlLUxpbmUgJ+G6pG4gRW50ZXIgxJHhu4MgeG/DoSB0aOG6rXQsIMSRw7NuZyBj4butYSBz4buVIMSR4buD
# IGh14bu3LicNCiAgICAgICAgJG51bGwgPSBbQ29uc29sZV06OlJlYWRMaW5lKCkNCiAgICAgICAgJHJlY3Vyc2UgPSBAeyBQbGFuID0gJHBsYW5EaXI7IEV4
# ZWN1dGUgPSAkdHJ1ZTsgQ29uZmlybVRva2VuID0gJ1hPQSc7IFllcyA9ICR0cnVlIH0NCiAgICAgICAgaWYgKCRLZWVwLkNvdW50IC1ndCAwKSB7ICRyZWN1
# cnNlWydLZWVwJ10gPSAkS2VlcCB9DQogICAgICAgICYgJFBTQ29tbWFuZFBhdGggQHJlY3Vyc2UNCiAgICB9DQp9DQoNCmlmICgkRnJvbVNjYW4pIHsgcmV0
# dXJuIH0NCltFbnZpcm9ubWVudF06OkV4aXRDb2RlID0gMA0K
# PSW_REMOVE_BASE64_END
