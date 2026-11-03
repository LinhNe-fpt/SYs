#Requires -Version 5.1
<#
.SYNOPSIS
    Tạo VM Windows thật bằng Hyper-V (cách ly mạnh nhất).

.DESCRIPTION
    Windows Sandbox chỉ chạy được một phiên và không giữ trạng thái. Nếu bạn
    cần test lặp lại trên một Windows cài đặt thật (ví dụ để thử Credential
    Manager, WSL, Docker ở Phase 3), Hyper-V là lựa chọn phù hợp.

    Script này KHÔNG tự tải ISO Windows (Microsoft không cho phép script tải
    tự động hợp pháp; bạn cần tự tải từ trang Evaluation của Microsoft).
    Nó sẽ:
      1. Kiểm tra Hyper-V đã bật chưa, và hướng dẫn bật nếu chưa.
      2. Kiểm tra file ISO bạn cung cấp.
      3. Tạo VM, gắn ISO, tạo ổ ảo, và bật máy.
      4. In hướng dẫn cài Windows và chạy test trong VM.

    YÊU CẦU (một lần):
      * Windows 10/11 Pro/Enterprise/Education
      * PowerShell với quyền Administrator
      * CPU hỗ trợ VT-x/AMD-V, đã bật trong BIOS
      * >= 8 GB RAM (VM dùng 4 GB), >= 60 GB trống
      * File ISO Windows (tải từ https://www.microsoft.com/evalcenter/)

    LỆNH BẬT HYPER-V (PowerShell Admin, rồi restart):
      Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All

.PARAMETER IsoPath
    Đường dẫn file .iso Windows. BẮT BUỘC.

.PARAMETER VMName
    Tên VM. Mặc định: presale-wiper-test

.PARAMETER VMPath
    Nơi lưu file VM. Mặc định: ổ còn nhiều dung lượng nhất, thư mục <ổ>\Hyper-V

.PARAMETER MemoryGB
    RAM cấp cho VM. Mặc định 4.

.PARAMETER DiskGB
    Dung lượng ổ ảo. Mặc định 60.

.PARAMETER SwitchName
    Virtual switch. Mặc định: tự tạo 'presale-wiper-internal' (NAT/internal,
    không lộ VM ra mạng LAN).

.EXAMPLE
    .\Start-HyperVVM.ps1 -IsoPath 'D:\ISO\Win11_24H2_English_x64.iso'

.EXAMPLE
    .\Start-HyperVVM.ps1 -IsoPath 'D:\ISO\win10.iso' -MemoryGB 6 -DiskGB 80
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$IsoPath,
    [string]$VMName = 'presale-wiper-test',
    [string]$VMPath,
    [int]$MemoryGB = 4,
    [int]$DiskGB = 60,
    [string]$SwitchName = 'presale-wiper-internal'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host ''
Write-Host ('=' * 70)
Write-Host '  presale-wiper - Hyper-V VM (cách ly mạnh nhất)'
Write-Host ('=' * 70)
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Kiểm tra điều kiện
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Script này cần quyền Administrator.' -ForegroundColor Red
    Write-Host 'Mở PowerShell với "Run as administrator" rồi chạy lại.' -ForegroundColor Yellow
    exit 2
}

$hyperV = Get-Module -ListAvailable -Name Hyper-V
if (-not $hyperV) {
    Write-Host 'Hyper-V chưa có trên máy này.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Bật bằng PowerShell Admin rồi KHỞI ĐỘNG LẠI:' -ForegroundColor Yellow
    Write-Host '  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All'
    Write-Host ''
    Write-Host 'Sau khi restart, chạy lại script này.'
    exit 2
}

Import-Module Hyper-V -ErrorAction Stop

if (-not (Test-Path -LiteralPath $IsoPath)) {
    Write-Host "Không tìm thấy ISO: $IsoPath" -ForegroundColor Red
    Write-Host 'Tải Windows ISO (miễn phí, bản Evaluation 90 ngày):' -ForegroundColor Yellow
    Write-Host '  https://www.microsoft.com/evalcenter/download-windows-11-enterprise'
    Write-Host '  https://www.microsoft.com/evalcenter/download-windows-10-enterprise'
    exit 2
}

$isoInfo = New-Object System.IO.FileInfo $IsoPath
if ($isoInfo.Length -lt 1GB) {
    Write-Host ("File ISO có vẻ không hợp lệ ({0:N0} byte)." -f $isoInfo.Length) -ForegroundColor Red
    exit 2
}
Write-Host ("ISO: {0} ({1:N1} GB)" -f $isoInfo.Name, ($isoInfo.Length / 1GB))

# Ổ đích
if ([string]::IsNullOrWhiteSpace($VMPath)) {
    $candidate = [System.IO.DriveInfo]::GetDrives() | Where-Object {
        $_.IsReady -and $_.DriveType -eq [System.IO.DriveType]::Fixed -and
        $_.AvailableFreeSpace -gt ([long]$DiskGB + 20) * 1GB
    } | Sort-Object AvailableFreeSpace -Descending | Select-Object -First 1

    if ($null -eq $candidate) {
        Write-Host ("Cần ổ trống >= {0} GB cho VM." -f ($DiskGB + 20)) -ForegroundColor Red
        exit 2
    }
    $VMPath = Join-Path $candidate.Name 'Hyper-V'
}
if (-not (Test-Path -LiteralPath $VMPath)) {
    [void][System.IO.Directory]::CreateDirectory($VMPath)
}
Write-Host ("VM path: {0}" -f $VMPath)

# VM đã tồn tại?
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "VM '$VMName' đã tồn tại." -ForegroundColor Yellow
    $vm = Get-VM -Name $VMName
    if ($vm.State -eq 'Off') {
        Write-Host 'Đang bật...'
        Start-VM -Name $VMName
    } else {
        Write-Host ("VM đang ở trạng thái: {0}" -f $vm.State)
    }
    Write-Host ''
    Write-Host 'Dùng vmconnect để xem màn hình:'
    Write-Host ("  vmconnect.exe localhost `"$VMName`"")
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Virtual switch (internal = không lộ ra LAN)
# ---------------------------------------------------------------------------
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Write-Host ("Tạo switch nội bộ '{0}' (không lộ VM ra mạng LAN)..." -f $SwitchName)
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
}

# ---------------------------------------------------------------------------
# 3. Tạo VM
# ---------------------------------------------------------------------------
Write-Host 'Đang tạo VM...'
$vm = New-VM -Name $VMName `
    -MemoryStartupBytes ([int64]$MemoryGB * 1GB) `
    -Generation 2 `
    -NewVHDPath (Join-Path $VMPath "$VMName.vhdx") `
    -NewVHDSizeBytes ([int64]$DiskGB * 1GB) `
    -SwitchName $SwitchName `
    -Path $VMPath

# Generation 2 cần: secure boot tắt template (hoặc dùng Microsoft Windows template),
# và DVD drive. Tắt TPM để tránh yêu cầu hardware attestation khi cài Win11 eval.
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Set-VMProcessor -VMName $VMName -Count ([Math]::Min(4, [Environment]::ProcessorCount))
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true `
    -MinimumBytes 2GB -StartupBytes ([int64]$MemoryGB * 1GB) -MaximumBytes ([int64]$MemoryGB * 1GB)

Add-VMDvdDrive -VMName $VMName -Path $IsoPath

# Boot từ DVD trước
$dvd = Get-VMDvdDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

Write-Host 'Đang bật VM...'
Start-VM -Name $VMName

Write-Host ''
Write-Host ('=' * 70)
Write-Host '  VM ĐÃ TẠO' -ForegroundColor Green
Write-Host ('=' * 70)
Write-Host ''
Write-Host 'BƯỚC TIẾP THEO - làm thủ công trong cửa sổ VM:'
Write-Host ''
Write-Host '  1. Mở cửa sổ VM:'
Write-Host ("       vmconnect.exe localhost `"$VMName`"")
Write-Host ''
Write-Host '  2. Cài Windows như bình thường (bản Evaluation không cần key).'
Write-Host ''
Write-Host '  3. Trong VM, bật long path + copy repo:'
Write-Host '       Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" LongPathsEnabled 1'
Write-Host '       # copy repo từ share, hoặc dùng:'
Write-Host '       #   New-SmbShare -Name psw -Path <repo> -ReadAccess "Everyone"  (trên host)'
Write-Host '       #   net use Z: \\<host>\psw                              (trong VM)'
Write-Host ''
Write-Host '  4. Trong VM, chạy test:'
Write-Host '       Z:\tests\environments\Invoke-TestSuite.ps1 -WorkDir C:\psw-work -ResultPath C:\psw-work\nunit.xml'
Write-Host ''
Write-Host '  5. Trước mỗi lần test lại, ROLLBACK bằng checkpoint:'
Write-Host ("       Checkpoint-VM -Name `"$VMName`" -SnapshotName clean")
Write-Host ("       Restore-VMSnapshot -VMName `"$VMName`" -Name clean -Confirm:`$false")
Write-Host ''
Write-Host 'Đây chính là lý do dùng VM: rollback mất 10 giây thay vì cài lại.'
Write-Host ''
exit 0
