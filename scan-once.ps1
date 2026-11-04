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
    Thư mục cần quét. Bỏ trống thì quét %USERPROFILE% (trừ AppData và thư mục
    hệ thống) cộng các thư mục dev ở gốc ổ (D:\Projects, ...). KHÔNG quét cả ổ C:.

.PARAMETER MinSize
    Chỉ liệt kê mục >= kích thước này. Nhận '100MB', '1.5GB', hoặc số byte.

.PARAMETER MaxDepth
    Độ sâu tối đa tính từ mỗi root. Mặc định 10.

.PARAMETER Kind
    Chỉ lấy các loại này. Mặc định: Project, DevDir, Secret, CodeFile.

.PARAMETER OutDir
    Nơi ghi kết quả. Mặc định: %USERPROFILE%\presale-scan-<timestamp>

.PARAMETER MaxFilesPerTarget
    Trần số file liệt kê cho mỗi mục, để node_modules 200.000 file không làm
    treo máy. Mặc định 50000. Danh sách bị cắt sẽ được ghi rõ.

.PARAMETER DevFoldersOnly
    Không quét cả %USERPROFILE%, chỉ quét các thư mục dev quen thuộc
    (source\repos, Projects, Developer, ...). Nhanh hơn nhưng dễ bỏ sót.

.PARAMETER IncludeHome
    Giữ để tương thích, không còn tác dụng (home đã được quét mặc định).

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

    [int]$MaxFilesPerTarget = 50000,

    [switch]$DevFoldersOnly,

    [switch]$IncludeHome,

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
)

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

function Write-Stdout {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
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
$script:UserProfileDir = Get-NormalizedPath ([Environment]::GetFolderPath('UserProfile'))

function Test-ProtectedContainer {
    <#
        Desktop, Downloads, Documents, ... : không bao giờ đề xuất cả thư mục,
        chỉ đi vào trong để xét từng mục con.
    #>
    param([string]$Value)

    $full = Get-NormalizedPath $Value
    if ($null -eq $full) { return $false }
    return $script:ForbiddenLookup.Contains($full.TrimEnd('\'))
}

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
    $isDotnetManifest = $Name -like '*.deps.json' -or $Name -like '*.runtimeconfig*.json'
    foreach ($pattern in @($script:SecretFilePatterns)) {
        if ($isDotnetManifest) { break }
        if ($Name -like $pattern) { return 'Secret' }
    }

    $ext = Get-ExtensionOf $Name
    if ($ext) {
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
    foreach ($pattern in @($script:ProjectMarkerPatterns)) {
        if ($Name -like $pattern) { return $true }
    }
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

    foreach ($child in $Children) {
        $attributes = [int]$child.Attributes
        $isDir = ($attributes -band [int][System.IO.FileAttributes]::Directory) -ne 0

        if (Test-ProjectMarker $child.Name) { $markers++ }
        if ($isDir) { continue }

        $total++
        switch (Get-FileKind $child.Name) {
            'Code' { $code++ }
            'Media' { $media++ }
            default { }
        }
    }

    if ($markers -gt 0) { return @{ Kind = 'Project'; Reason = "Có $markers marker project" } }

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

    if ($code -ge 1) { return @{ Kind = 'Project'; Reason = "Có $code file code" } }

    return @{ Kind = 'Skip'; Reason = 'Không có dấu hiệu code' }
}

# =============================================================================
# 5. Duyệt cây
# =============================================================================

function Get-DefaultRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $home_ = [Environment]::GetFolderPath('UserProfile')

    if (-not $DevFoldersOnly -and -not [string]::IsNullOrWhiteSpace($home_)) {
        if ((Test-PathExists $home_) -and $seen.Add($home_)) { $roots.Add($home_) }
    }

    foreach ($relative in @('source\repos', 'source', 'repos', 'Projects', 'projects',
            'Developer', 'dev', 'code', 'Code', 'workspace', 'Workspace', 'git', 'Git',
            'Documents\Projects', 'Documents\Source', 'Documents\GitHub')) {
        if ([string]::IsNullOrWhiteSpace($home_) -or $roots.Count -gt 0) { break }
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

function Measure-FolderSize {
    param([string]$Value, [int]$Limit = 750000)

    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push((Get-NormalizedPath $Value))
    $total = 0L
    $visited = 0

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        if ($null -eq $current) { continue }

        try {
            $info = New-Object System.IO.DirectoryInfo (To-LongPath $current)
            if (-not $info.Exists) { continue }
            $children = $info.EnumerateFileSystemInfos()
        } catch { continue }

        foreach ($child in $children) {
            $visited++
            if ($visited -gt $Limit) { return $total }

            $attributes = [int]$child.Attributes
            if (($attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

            if (($attributes -band [int][System.IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push((From-LongPath $child.FullName))
            } else {
                try { $total += [long]$child.Length } catch { }
            }
        }
    }
    return $total
}

function Get-FilesUnder {
    <#
        Bung một folder ra danh sách file cụ thể. Bỏ qua junction/symlink.
        Trả về @{ Files = [object[]]; Truncated = [bool]; TotalFiles = [int] }

        Mỗi file mang sẵn TargetPath = folder gốc, để lúc lọc theo Kind chỉ cần
        một phép tra HashSet thay vì kiểm tra "path có nằm dưới target nào"
        cho từng file (việc đó là O(file × target) và sẽ rất chậm).
    #>
    param(
        [string]$Value,
        [int]$Limit,
        [string]$KindLabel,
        [string]$Reason
    )

    $files = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push((Get-NormalizedPath $Value))
    $count = 0
    $truncated = $false

    while ($stack.Count -gt 0) {
        if ($count -ge $Limit) { $truncated = $true; break }

        $current = $stack.Pop()
        if ($null -eq $current) { continue }

        foreach ($child in (Get-ChildInfos $current)) {
            $attributes = [int]$child.Attributes
            if (($attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

            $childPath = From-LongPath $child.FullName

            if (($attributes -band [int][System.IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push($childPath)
                continue
            }

            $size = 0L
            try { $size = [long]$child.Length } catch { }

            [void]$files.Add([PSCustomObject]@{
                    Path       = $childPath
                    Size       = $size
                    Kind       = $KindLabel
                    Reason     = $Reason
                    TargetPath = $Value
                })
            $count++
            if ($count -ge $Limit) { $truncated = $true; break }
        }
    }

    return @{
        Files      = $files.ToArray()
        Truncated  = $truncated
        TotalFiles = $count
    }
}

function Invoke-Scan {
    <#
        Duyệt toàn bộ root, trả về:
          Targets = mục cấp cao (project / devdir / secret / codefile)
          Files   = danh sách file cụ thể bên trong từng target
    #>
    param([string[]]$Roots)

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $allFiles = New-Object 'System.Collections.Generic.List[object]'
    $notes = New-Object 'System.Collections.Generic.List[object]'

    $stats = [PSCustomObject]@{
        FoldersVisited = 0
        EntriesVisited = 0
        Truncated      = $false
    }

    $maxEntries = 750000

    foreach ($root in $Roots) {
        $resolved = Get-NormalizedPath $root
        if ($null -eq $resolved -or -not (Test-PathExists $resolved)) {
            [void]$notes.Add([PSCustomObject]@{ Path = $root; Note = 'Không tồn tại, bỏ qua.' })
            continue
        }

        # Duyệt BFS. Root không phải project thì đi tiếp; gặp project/devdir/
        # secret thì ghi nhận và KHÔNG đi vào (đã có danh sách file riêng).
        $queue = New-Object 'System.Collections.Generic.Queue[object]'
        $queue.Enqueue(@{ Path = $resolved; Depth = 0 })

        while ($queue.Count -gt 0) {
            $item = $queue.Dequeue()
            $currentPath = $item.Path
            $depth = $item.Depth
            $secretsOnly = [bool]$item['SecretsOnly']

            if ($stats.EntriesVisited -ge $maxEntries) {
                $stats.Truncated = $true
                [void]$notes.Add([PSCustomObject]@{
                        Path = $currentPath
                        Note = "Đã chạm trần $maxEntries entry, dừng duyệt."
                    })
                break
            }

            $children = Get-ChildInfos $currentPath
            $stats.FoldersVisited++
            $stats.EntriesVisited += @($children).Count

            foreach ($child in $children) {
                $attributes = [int]$child.Attributes
                if (($attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

                $childPath = From-LongPath $child.FullName
                $isDir = ($attributes -band [int][System.IO.FileAttributes]::Directory) -ne 0

                if ($isDir) {
                    if ($script:Lookup.SkipDirs.Contains($child.Name)) { continue }

                    $kindLabel = $null
                    $reason = $null

                    if ($script:Lookup.DevDirs.Contains($child.Name)) {
                        $kindLabel = 'DevDir'
                        $reason = "Thư mục rác dev: $($child.Name)"
                    } elseif ($script:Lookup.SecretDirs.Contains($child.Name)) {
                        $kindLabel = 'Secret'
                        $reason = "Thư mục chứa thông tin đăng nhập: $($child.Name)"
                    }

                    if ($secretsOnly -and $kindLabel -eq 'DevDir') { $kindLabel = $null }

                    # .vscode, .rustup, .cargo, ... ngay dưới home là dữ liệu của
                    # công cụ đã cài, không phải project của người dùng: chỉ tìm
                    # secret trong đó (vd .ollama\id_ed25519).
                    if ($null -eq $kindLabel -and -not $secretsOnly -and $child.Name.StartsWith('.') -and
                        $null -ne $script:UserProfileDir -and
                        [string]::Equals((Get-NormalizedPath $currentPath), $script:UserProfileDir, [StringComparison]::OrdinalIgnoreCase)) {
                        $queue.Enqueue(@{ Path = $childPath; Depth = ($depth + 1); SecretsOnly = $true })
                        continue
                    }

                    if ($null -eq $kindLabel -and $secretsOnly) {
                        if ($depth -lt $MaxDepth) {
                            $queue.Enqueue(@{ Path = $childPath; Depth = ($depth + 1); SecretsOnly = $true })
                        }
                        continue
                    }

                    if ($null -eq $kindLabel -and (Test-ProtectedContainer $childPath)) {
                        if ($depth -lt $MaxDepth) {
                            $queue.Enqueue(@{ Path = $childPath; Depth = ($depth + 1) })
                        }
                        continue
                    }

                    if ($null -ne $kindLabel) {
                        $size = Measure-FolderSize $childPath
                        [void]$targets.Add([PSCustomObject]@{
                                Path    = $childPath
                                Name    = $child.Name
                                Kind    = $kindLabel
                                Size    = $size
                                Reason  = $reason
                                Blocked = Get-BlockReason $childPath
                            })

                        $expanded = Get-FilesUnder -Value $childPath -Limit $MaxFilesPerTarget `
                            -KindLabel $kindLabel -Reason $reason
                        foreach ($file in $expanded.Files) { [void]$allFiles.Add($file) }

                        if ($expanded.Truncated) {
                            [void]$notes.Add([PSCustomObject]@{
                                    Path = $childPath
                                    Note = "Danh sách file bị cắt ở $MaxFilesPerTarget (còn nữa)."
                                })
                        }
                        continue
                    }

                    if ($depth -ge $MaxDepth) { continue }

                    $subChildren = Get-ChildInfos $childPath
                    $verdict = Get-FolderVerdict -Children $subChildren

                    if ($verdict.Kind -eq 'Project') {
                        $size = Measure-FolderSize $childPath
                        [void]$targets.Add([PSCustomObject]@{
                                Path    = $childPath
                                Name    = $child.Name
                                Kind    = 'Project'
                                Size    = $size
                                Reason  = $verdict.Reason
                                Blocked = Get-BlockReason $childPath
                            })

                        $expanded = Get-FilesUnder -Value $childPath -Limit $MaxFilesPerTarget `
                            -KindLabel 'Project' -Reason $verdict.Reason
                        foreach ($file in $expanded.Files) { [void]$allFiles.Add($file) }

                        if ($expanded.Truncated) {
                            [void]$notes.Add([PSCustomObject]@{
                                    Path = $childPath
                                    Note = "Danh sách file bị cắt ở $MaxFilesPerTarget (còn nữa)."
                                })
                        }
                        continue
                    }

                    if ($verdict.Kind -eq 'MediaHeavy') {
                        # Không phải code, không đưa vào danh sách dọn.
                        continue
                    }

                    $queue.Enqueue(@{ Path = $childPath; Depth = ($depth + 1) })
                    continue
                }

                # --- File lẻ ---
                $fileKind = Get-FileKind $child.Name
                if ($fileKind -ne 'Secret' -and $fileKind -ne 'Code') { continue }
                if ($secretsOnly -and $fileKind -ne 'Secret') { continue }

                $label = if ($fileKind -eq 'Secret') { 'Secret' } else { 'CodeFile' }
                $reason = if ($fileKind -eq 'Secret') {
                    "File chứa thông tin đăng nhập: $($child.Name)"
                } else {
                    'File source code nằm ngoài project'
                }

                $size = 0L
                try { $size = [long]$child.Length } catch { }

                [void]$targets.Add([PSCustomObject]@{
                        Path    = $childPath
                        Name    = $child.Name
                        Kind    = $label
                        Size    = $size
                        Reason  = $reason
                        Blocked = Get-BlockReason $childPath
                    })
                [void]$allFiles.Add([PSCustomObject]@{
                        Path       = $childPath
                        Size       = $size
                        Kind       = $label
                        Reason     = $reason
                        TargetPath = $childPath
                    })
            }
        }
    }

    return @{
        Targets = $targets.ToArray()
        Files   = $allFiles.ToArray()
        Notes   = $notes.ToArray()
        Stats   = $stats
    }
}

# =============================================================================
# 6. Xuất kết quả
# =============================================================================

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

    $targets = @($Result.Targets | Where-Object { $wantedKinds -contains $_.Kind -and -not $_.Blocked })
    # Lọc theo Kind bằng HashSet của target path đã chọn. Không kiểm tra
    # "path có nằm dưới target nào" cho từng file, vì với 50.000 file × 200
    # target thì đó là 10 triệu phép so sánh chuỗi.
    $keptTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($target in $targets) { [void]$keptTargets.Add($target.Path) }

    $files = @($Result.Files | Where-Object {
            ($wantedKinds -contains $_.Kind) -and $keptTargets.Contains($_.TargetPath)
        })

    # Lọc MinSize
    if ($null -ne $script:MinSizeBytes) {
        $files = @($files | Where-Object { $_.Size -ge $script:MinSizeBytes })
        $targets = @($targets | Where-Object { $_.Size -ge $script:MinSizeBytes })
    }

    $files = @($files | Sort-Object -Property Size -Descending)
    $targets = @($targets | Sort-Object -Property Size -Descending)

    $totalBytes = 0L
    foreach ($file in $files) { $totalBytes += [long]$file.Size }

    # --- TXT: danh sách đường dẫn, đúng thứ người dùng cần ---
    $txtPath = Join-PathSafe $Destination ("danh-sach-file-{0}.txt" -f $script:RunId)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("# presale-wiper - danh sách file CẦN DỌN (chưa xoá gì)")
    $lines.Add("# Tạo lúc: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("# Số file: $(@($files).Count) | Tổng: $(Format-Size $totalBytes)")
    $lines.Add('#')
    $lines.Add('# CẢNH BÁO: file này liệt kê đường dẫn tuyệt đối trên máy bạn.')
    $lines.Add('# Đừng chia sẻ công khai - nó cho thấy cấu trúc thư mục của bạn.')
    $lines.Add('')
    foreach ($file in $files) { $lines.Add($file.Path) }
    [System.IO.File]::WriteAllLines((To-LongPath $txtPath), $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

    # --- CSV: chi tiết để lọc/sắp xếp trong Excel ---
    $csvPath = Join-PathSafe $Destination ("danh-sach-file-{0}.csv" -f $script:RunId)
    $csvRows = @($files | ForEach-Object {
            [PSCustomObject]@{
                Path   = $_.Path
                SizeBytes = $_.Size
                SizeText  = Format-Size $_.Size
                Kind      = $_.Kind
                Reason    = $_.Reason
            }
        })
    $csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    # --- JSON ---
    $jsonPath = Join-PathSafe $Destination ("danh-sach-file-{0}.json" -f $script:RunId)
    $jsonObject = [ordered]@{
        tool        = 'presale-wiper scan-once'
        mode        = 'scan-only'
        deleted     = $false
        generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        computer    = $env:COMPUTERNAME
        user        = $env:USERNAME
        roots       = @($Result.Roots)
        totals      = [ordered]@{
            targets   = @($targets).Count
            files     = @($files).Count
            sizeBytes = $totalBytes
            sizeText  = Format-Size $totalBytes
        }
        targets     = @($targets | ForEach-Object {
                [ordered]@{
                    path   = $_.Path
                    kind   = $_.Kind
                    sizeBytes = $_.Size
                    sizeText  = Format-Size $_.Size
                    reason = $_.Reason
                }
            })
        files       = @($files | ForEach-Object {
                [ordered]@{
                    path      = $_.Path
                    sizeBytes = $_.Size
                    kind      = $_.Kind
                }
            })
        notes       = @($Result.Notes | ForEach-Object {
                [ordered]@{ path = [string]$_.Path; note = [string]$_.Note }
            })
    }
    $json = ConvertTo-Json -InputObject $jsonObject -Depth 6
    [System.IO.File]::WriteAllText((To-LongPath $jsonPath), $json, (New-Object System.Text.UTF8Encoding($false)))

    return @{
        Txt       = $txtPath
        Csv       = $csvPath
        Json      = $jsonPath
        Targets   = $targets
        Files     = $files
        TotalSize = $totalBytes
    }
}

function Show-Summary {
    param($Report)

    Write-Stdout ''
    Write-Stdout ('=' * 76)
    Write-Stdout '  presale-wiper - SCAN MỘT LẦN (chỉ liệt kê, KHÔNG xoá gì)'
    Write-Stdout ('=' * 76)

    if (-not $Quiet) {
        $topTargets = @($Report.Targets | Select-Object -First 40)
        if (@($topTargets).Count -gt 0) {
            Write-Stdout ''
            Write-Stdout '--- Mục lớn nhất ---'
            Write-Stdout ("{0,-10} {1,12}  {2}" -f 'Loại', 'Dung lượng', 'Đường dẫn')
            Write-Stdout ("{0,-10} {1,12}  {2}" -f ('-' * 10), ('-' * 12), ('-' * 50))
            foreach ($target in $topTargets) {
                $display = $target.Path
                if ($display.Length -gt 96) { $display = '...' + $display.Substring($display.Length - 93) }
                Write-Stdout ("{0,-10} {1,12}  {2}" -f $target.Kind, (Format-Size $target.Size), $display)
            }
            if (@($Report.Targets).Count -gt @($topTargets).Count) {
                Write-Stdout ("  ... và {0} mục khác (xem file CSV)." -f (@($Report.Targets).Count - @($topTargets).Count))
            }
        }

        $topFiles = @($Report.Files | Select-Object -First 15)
        if (@($topFiles).Count -gt 0) {
            Write-Stdout ''
            Write-Stdout '--- File lớn nhất ---'
            foreach ($file in $topFiles) {
                $display = $file.Path
                if ($display.Length -gt 96) { $display = '...' + $display.Substring($display.Length - 93) }
                Write-Stdout ("{0,12}  {1}" -f (Format-Size $file.Size), $display)
            }
        }
    }

    Write-Stdout ''
    Write-Stdout '--- Tổng kết ---'
    Write-Stdout ("  Mục (project/devdir/secret) : {0}" -f @($Report.Targets).Count)
    Write-Stdout ("  File cụ thể                 : {0}" -f @($Report.Files).Count)
    Write-Stdout ("  Tổng dung lượng             : {0}" -f (Format-Size $Report.TotalSize))
    Write-Stdout ''
    Write-Stdout '--- File kết quả ---'
    Write-Stdout ("  TXT  (danh sách path) : {0}" -f $Report.Txt)
    Write-Stdout ("  CSV  (chi tiết)       : {0}" -f $Report.Csv)
    Write-Stdout ("  JSON (cho tooling)    : {0}" -f $Report.Json)
    Write-Stdout ''
    Write-Stdout 'KHÔNG có file nào bị xoá. Đọc danh sách rồi tự quyết định.'
    Write-Stdout ''
}

# =============================================================================
# 7. Chạy
# =============================================================================

$MinSizeBytes = $null
if (-not [string]::IsNullOrWhiteSpace($MinSize)) {
    $MinSizeBytes = ConvertTo-Bytes $MinSize
    if ($null -eq $MinSizeBytes) {
        Write-Stdout ("LỖI: -MinSize không hợp lệ: '{0}'. Ví dụ: 100MB, 1.5GB, 2097152." -f $MinSize)
        [Environment]::ExitCode = 2
        return
    }
}

# @() bắt buộc: khi chỉ truyền 1 path, $Path là chuỗi chứ không phải mảng,
# nên $Path.Count ném lỗi dưới StrictMode.
$pathList = @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$roots = @(if ($pathList.Count -gt 0) { $pathList } else { Get-DefaultRoots })

if ($roots.Count -eq 0) {
    Write-Stdout 'Không tìm thấy thư mục dev nào để quét.'
    Write-Stdout 'Chỉ định thủ công, ví dụ:  .\scan-once.ps1 -Path D:\Projects'
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
    Write-Stdout ("LỖI khi quét: {0}" -f $_.Exception.Message)
    [Environment]::ExitCode = 2
    return
}

$scanResult.Roots = $roots

$report = $null
try {
    $report = Out-Report -Result $scanResult -Destination $destination
} catch {
    Write-Stdout ("LỖI khi ghi kết quả: {0}" -f $_.Exception.Message)
    [Environment]::ExitCode = 2
    return
}

Show-Summary -Report $report

if (@($scanResult.Notes).Count -gt 0) {
    Write-Stdout ("Ghi chú ({0}):" -f @($scanResult.Notes).Count)
    foreach ($note in @($scanResult.Notes | Select-Object -First 10)) {
        Write-Stdout ("  - {0}: {1}" -f $note.Path, $note.Note)
    }
    Write-Stdout ''
}

[Environment]::ExitCode = 0
