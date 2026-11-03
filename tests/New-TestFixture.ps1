#Requires -Version 5.1
<#
    New-TestFixture.ps1 - Sinh cây thư mục mẫu cho test.

    Vì sao sinh bằng script thay vì commit sẵn cây file:
      * '.git' và '.ssh' không commit được như folder rỗng (git bỏ folder rỗng);
      * long path >260 ký tự không thể lưu trong repo Windows;
      * nhiều file rác (node_modules...) làm repo phình to vô ích.

    Script này idempotent: gọi lại thì xoá cây cũ và tạo lại từ đầu.

.PARAMETER Destination
    Nơi tạo fixtures. Mặc định: <repo>\tests\fixtures

.PARAMETER IncludeLongPath
    Tạo thêm cây thư mục sâu >260 ký tự (chậm hơn, cần cho test 5.3).
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$IncludeLongPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path (Split-Path $PSScriptRoot -Parent) 'fixtures'
}

function New-Dir {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }
}

function New-TextFile {
    param([string]$Path, [string]$Content = 'x')
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    New-Dir $parent
    [System.IO.File]::WriteAllText($Path, $Content)
}

function New-SizedFile {
    param([string]$Path, [int]$Bytes)
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    New-Dir $parent
    $buffer = New-Object 'byte[]' $Bytes
    [System.IO.File]::WriteAllBytes($Path, $buffer)
}

Write-Host "Tạo fixtures tại: $Destination"

if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
}
New-Dir $Destination

# ---------------------------------------------------------------------------
# project_node: project Node.js điển hình, có node_modules
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'project_node'
New-TextFile (Join-Path $root 'package.json') '{"name":"demo","version":"1.0.0"}'
New-TextFile (Join-Path $root 'package-lock.json') '{}'
New-TextFile (Join-Path $root 'index.js') 'console.log(1)'
New-TextFile (Join-Path $root 'README.md') '# demo'
New-TextFile (Join-Path $root 'src\app.js') 'export default 1'
New-TextFile (Join-Path $root 'src\util.js') 'export const x = 1'
New-TextFile (Join-Path $root 'src\styles.css') 'body{}'
New-TextFile (Join-Path $root 'node_modules\react\package.json') '{}'
New-TextFile (Join-Path $root 'node_modules\react\index.js') 'module.exports={}'
New-SizedFile (Join-Path $root 'node_modules\react\lib\big.bundle.js') 20480
New-TextFile (Join-Path $root '.git\HEAD') 'ref: refs/heads/main'
New-TextFile (Join-Path $root '.git\config') '[core]'

# ---------------------------------------------------------------------------
# project_rust: có target/ nặng
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'project_rust'
New-TextFile (Join-Path $root 'Cargo.toml') '[package]'
New-TextFile (Join-Path $root 'Cargo.lock') ''
New-TextFile (Join-Path $root 'src\main.rs') 'fn main(){}'
New-TextFile (Join-Path $root 'src\lib.rs') 'pub fn f(){}'
New-SizedFile (Join-Path $root 'target\debug\app.exe') 51200
New-SizedFile (Join-Path $root 'target\debug\deps\libfoo.rlib') 102400
New-TextFile (Join-Path $root '.git\HEAD') 'ref: refs/heads/main'

# ---------------------------------------------------------------------------
# project_python: có .venv/ và __pycache__/
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'project_python'
New-TextFile (Join-Path $root 'pyproject.toml') '[project]'
New-TextFile (Join-Path $root 'requirements.txt') 'requests'
New-TextFile (Join-Path $root 'app\__init__.py') ''
New-TextFile (Join-Path $root 'app\main.py') 'print(1)'
New-TextFile (Join-Path $root 'app\models.py') 'class A: pass'
New-TextFile (Join-Path $root 'app\__pycache__\main.cpython-311.pyc') 'x'
New-TextFile (Join-Path $root '.venv\pyvenv.cfg') 'home=C:\Python311'
New-TextFile (Join-Path $root '.venv\Lib\site-packages\requests\__init__.py') ''
New-SizedFile (Join-Path $root '.venv\Scripts\python.exe') 30720
New-TextFile (Join-Path $root '.git\HEAD') 'ref: refs/heads/main'

# ---------------------------------------------------------------------------
# mixed_with_media: ảnh chi phối -> KHÔNG được coi là project
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'mixed_with_media'
1..9 | ForEach-Object { New-TextFile (Join-Path $root ("photo_{0}.jpg" -f $_)) 'jpeg' }
New-TextFile (Join-Path $root 'script.py') 'print(2)'

# ---------------------------------------------------------------------------
# empty_project: có .git nhưng không có code
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'empty_project'
New-TextFile (Join-Path $root '.git\HEAD') 'ref: refs/heads/main'
New-TextFile (Join-Path $root 'notes.txt') 'hello'

# ---------------------------------------------------------------------------
# secret_folder: .env, .ssh/id_rsa, .gitconfig...
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'secret_folder'
New-TextFile (Join-Path $root '.env') 'API_KEY=abc'
New-TextFile (Join-Path $root '.env.local') 'DB=1'
New-TextFile (Join-Path $root '.ssh\id_rsa') '-----BEGIN-----'
New-TextFile (Join-Path $root '.ssh\known_hosts') 'github.com ssh-rsa AAA'
New-TextFile (Join-Path $root '.gitconfig') '[user]'
New-TextFile (Join-Path $root '.aws\credentials') '[default]'
New-TextFile (Join-Path $root 'cert.pem') 'pem'

# ---------------------------------------------------------------------------
# protected: folder tên "Documents" -> không được xoá, chỉ dọn bên trong
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'protected'
New-TextFile (Join-Path $root 'Documents\my_notes.txt') 'important'
New-TextFile (Join-Path $root 'Documents\.env') 'secret=1'
New-TextFile (Join-Path $root 'Documents\project_in_docs\package.json') '{}'
New-TextFile (Join-Path $root 'Documents\project_in_docs\src\a.js') 'x'
New-TextFile (Join-Path $root 'Pictures\a.png') 'png'
New-TextFile (Join-Path $root 'Downloads\setup.exe') 'exe'

# ---------------------------------------------------------------------------
# nested: project lồng sâu trong container (phải tìm thấy)
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'nested'
New-TextFile (Join-Path $root 'workspace\2024\client_a\webapp\package.json') '{}'
New-TextFile (Join-Path $root 'workspace\2024\client_a\webapp\src\index.ts') 'x'
New-TextFile (Join-Path $root 'workspace\2024\client_a\webapp\node_modules\lodash\index.js') 'x'
New-TextFile (Join-Path $root 'workspace\2024\client_b\notes.txt') 'x'

# ---------------------------------------------------------------------------
# unicode: tên tiếng Việt / tiếng Trung / emoji
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'unicode'
New-TextFile (Join-Path $root 'dự án tiếng việt\package.json') '{}'
New-TextFile (Join-Path $root 'dự án tiếng việt\src\chính.js') 'x'
New-TextFile (Join-Path $root '项目\Cargo.toml') '[package]'
New-TextFile (Join-Path $root '项目\src\lib.rs') 'x'
New-TextFile (Join-Path $root 'project 🚀\go.mod') 'module x'
New-TextFile (Join-Path $root 'project 🚀\main.go') 'package main'
New-TextFile (Join-Path $root 'folder có dấu cách\pyproject.toml') '[project]'
New-TextFile (Join-Path $root 'folder có dấu cách\a.py') 'x'

# ---------------------------------------------------------------------------
# long path (>260 ký tự)
# ---------------------------------------------------------------------------
if ($IncludeLongPath) {
    $deep = Join-Path $Destination 'long_path_dir'
    $root = $deep
    1..8 | ForEach-Object { $root = Join-Path $root ('sub_' + ('x' * 26)) }
    $longDir = '\\?\' + $root
    [void][System.IO.Directory]::CreateDirectory($longDir)
    [System.IO.File]::WriteAllText(('\\?\' + (Join-Path $root 'package.json')), '{}')
    [System.IO.File]::WriteAllText(('\\?\' + (Join-Path $root 'code.js')), 'x')
    [System.IO.File]::WriteAllText(('\\?\' + (Join-Path $root '.env')), 'A=1')
    Write-Host ("  long path length: {0}" -f $root.Length)
}

# ---------------------------------------------------------------------------
# orphan_devdirs: rác dev nằm NGOÀI project (node_modules mồ côi...)
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'orphan_devdirs'
New-TextFile (Join-Path $root 'node_modules\left-pad\index.js') 'module.exports=1'
New-SizedFile (Join-Path $root 'node_modules\left-pad\dist\big.js') 4096
New-TextFile (Join-Path $root '.venv\pyvenv.cfg') 'home=C:\Python'
New-TextFile (Join-Path $root 'target\debug\dummy') 'x'
New-TextFile (Join-Path $root 'readme.txt') 'not code'

# ---------------------------------------------------------------------------
# code_files_only: chỉ có file code lẻ, không có marker nào
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'code_files_only'
New-TextFile (Join-Path $root 'snippet.py') 'print(1)'
New-TextFile (Join-Path $root 'helper.js') 'console.log(1)'
New-TextFile (Join-Path $root 'readme.txt') 'x'

# ---------------------------------------------------------------------------
# not_a_project: toàn file văn bản/ảnh, không có gì để dọn
# ---------------------------------------------------------------------------
$root = Join-Path $Destination 'not_a_project'
1..6 | ForEach-Object { New-TextFile (Join-Path $root ("doc_{0}.txt" -f $_)) 'text' }
New-TextFile (Join-Path $root 'photo.jpg') 'jpeg'

$count = (Get-ChildItem -LiteralPath $Destination -Force | Measure-Object).Count
Write-Host "Xong. $count thư mục fixture."
