#Requires -Version 5.1
<#
.SYNOPSIS
    Quét một lần, xuất danh sách file cần dọn. KHÔNG XOÁ BẤT CỨ THỨ GÌ.

.DESCRIPTION
    Script độc lập, tự chứa: không import module, không cần Pester, không cần
    quyền admin, không hỏi xác nhận. Chạy một lần rồi thoát.

    Nó làm đúng ba việc:
      1. Duyệt các thư mục dev, phân loại từng mục (project / rác dev / secret).
      2. Bung mỗi mục ra thành DANH SÁCH FILE cụ thể.
      3. Ghi ra TXT + CSV + JSON và in bảng tổng kết.

    Trong file này KHÔNG có lệnh xoá nào. Không Remove-Item, không
    [System.IO.File]::Delete, không [System.IO.Directory]::Delete. Nếu bạn
    cần dọn, hãy đọc danh sách rồi tự quyết định.

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
    Chỉ lấy các loại này. Mặc định: Project, DevDir, Secret, CodeFile.

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

.PARAMETER AskDelete
    Sau khi in kết quả, in hết danh sách rồi chờ Enter; Enter chuyển sang
    remove-once.ps1 (mô phỏng trước, xoá thật cần Enter lần nữa).

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

    [ValidateSet('Project', 'DevDir', 'Secret', 'CodeFile', 'All')]
    [string[]]$Kind = @('Project', 'DevDir', 'Secret', 'CodeFile'),

    [string]$OutDir,

    [int]$MaxFilesPerTarget = 0,

    [switch]$DevFoldersOnly,

    [switch]$IncludeHome,

    [switch]$AskDelete,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# 0. Cam kết: file này chỉ đọc
# =============================================================================
# Đặt ở đây để bất kỳ ai đọc code cũng thấy ngay. Nếu bạn định thêm chức năng
# xoá vào file này, hãy tạo file khác - giữ file này thuần read-only.

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

$script:NeverTouchNames = @(
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
    for ($i = 1; $i -lt $segments.Count; $i++) {
        if ($script:Lookup.NeverTouch.Contains($segments[$i])) {
            return "Chứa thư mục cấm '$($segments[$i])'."
        }
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

function Invoke-Scan {
    <#
        Duyệt toàn bộ root, trả về:
          Targets = mục cấp cao (project / devdir / secret / codefile), mỗi mục
                    mang sẵn danh sách file cụ thể (Paths/Sizes)
    #>
    param([string[]]$Roots)

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
        @('Project', 'DevDir', 'Secret', 'CodeFile')
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

        # --- JSON ---
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

        $json.WriteLine('  "targets": [')
        for ($i = 0; $i -lt $targets.Count; $i++) {
            $target = $targets[$i]
            $separator = if ($i -lt $targets.Count - 1) { ',' } else { '' }
            $json.WriteLine('    {"path": ' + (ConvertTo-JsonString $target.Path) +
                ', "kind": "' + $target.Kind + '", "sizeBytes": ' + $target.Size +
                ', "sizeText": "' + (Format-Size $target.Size) +
                '", "reason": ' + (ConvertTo-JsonString $target.Reason) + '}' + $separator)
        }
        $json.WriteLine('  ],')

        # Danh sách thư mục của từng target: remove-once.ps1 dùng để dọn thư mục
        # rỗng sau khi xoá file (nếu không, cây thư mục project vẫn còn nguyên).
        $json.WriteLine('  "targetDirs": [')
        for ($i = 0; $i -lt $targets.Count; $i++) {
            $target = $targets[$i]
            $separator = if ($i -lt $targets.Count - 1) { ',' } else { '' }
            $json.WriteLine('    {"path": ' + (ConvertTo-JsonString $target.Path) +
                ', "kind": "' + $target.Kind + '", "dirs": [' +
                ((@($target.Dirs) | ForEach-Object { ConvertTo-JsonString $_ }) -join ', ') + ']}' + $separator)
        }
        $json.WriteLine('  ],')


        # Đường dẫn Windows không chứa ký tự điều khiển, nên chỉ cần thoát \ và ".
        $csvReason = New-Object 'string[]' $kindTargets.Count
        $jsonKind = New-Object 'string[]' $kindTargets.Count
        for ($t = 0; $t -lt $kindTargets.Count; $t++) {
            $csvReason[$t] = '","' + $kindTargets[$t].Kind + '","' + $kindTargets[$t].Reason.Replace('"', '""') + '"'
            $jsonKind[$t] = ', "kind": "' + $kindTargets[$t].Kind + '"}'
        }

        $json.WriteLine('  "files": [')
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
            $separator = if ($i -gt 0) { ',' } else { '' }
            $json.WriteLine('    {"path": "' + $path.Replace('\', '\\').Replace('"', '\"') + '", "sizeBytes": ' + $size + $jsonKind[$fileOwner[$index]] + $separator)

            if ($topFiles.Count -lt 200) { [void]$topFiles.Add([PSCustomObject]@{ Path = $path; Size = $size }) }
        }
        $json.WriteLine('  ],')

        $noteItems = @($Result.Notes)
        $json.WriteLine('  "notes": [')
        for ($i = 0; $i -lt $noteItems.Count; $i++) {
            $separator = if ($i -lt $noteItems.Count - 1) { ',' } else { '' }
            $json.WriteLine('    {"path": ' + (ConvertTo-JsonString ([string]$noteItems[$i].Path)) +
                ', "note": ' + (ConvertTo-JsonString ([string]$noteItems[$i].Note)) + '}' + $separator)
        }
        $json.WriteLine('  ]')
        $json.WriteLine('}')

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
    Write-Green '  presale-wiper - KẾT QUẢ SCAN (chỉ liệt kê, KHÔNG xoá gì)'
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
    Write-Green ''
    Write-Green 'CHƯA có file nào bị xoá.'
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
Write-Stdout ''
Write-Stdout 'Đang quét...'

$scanResult = $null
try {
    $scanResult = Invoke-Scan -Roots $roots
} catch {
    Write-Failure ("LỖI khi quét: {0}" -f $_.Exception.Message)
    [Environment]::ExitCode = 2
    return
}

$scanResult.Roots = $roots

$report = $null
try {
    $report = Out-Report -Result $scanResult -Destination $destination
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

# Ở lại chờ Enter để người dùng kịp đọc kết quả. Có console thật (double-click)
# hoặc được presale-scan.cmd yêu cầu rõ bằng -AskDelete thì mới hỏi.
    $interactive = $AskDelete -or (-not [Console]::IsInputRedirected -and $env:PSW_NO_PAUSE -ne '1')
if ($interactive) {
    Write-Green 'Ấn Enter để chuyển sang bước xoá (hoặc đóng cửa sổ để dừng, chưa xoá gì).'
    $null = [Console]::ReadLine()
    try {
        $removeScript = Get-RemoveScriptPath
        if ([string]::IsNullOrWhiteSpace($removeScript)) {
            throw 'Không tìm thấy remove-once.ps1 (hãy để cùng thư mục, hoặc dùng presale-scan.cmd bản mới).'
        }
        & $removeScript -Plan (Split-Path -Parent $report.Json) -FromScan
    } catch {
        Write-Green ("LỖI khi mở bước xoá: {0}" -f $_.Exception.Message)
    }
}

[Environment]::ExitCode = 0
