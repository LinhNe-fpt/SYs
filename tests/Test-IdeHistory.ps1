#Requires -Version 5.1
<#
    Kiểm thử Get-IdeHistoryTargets trên cây thư mục GIẢ (không đụng profile thật).

    Nạp scan-once.ps1 tới trước phần "main" (dòng $pathList = @($Path...)),
    nhờ vậy chỉ có định nghĩa hàm được nạp, không chạy quét.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$src = [System.IO.File]::ReadAllText((Join-Path $root 'scan-once.ps1'), [System.Text.Encoding]::UTF8)
$cut = $src.IndexOf('$pathList = @($Path')
if ($cut -lt 0) { throw 'Không tìm thấy điểm cắt phần main trong scan-once.ps1' }
. ([ScriptBlock]::Create($src.Substring(0, $cut)))

# ---- cây giả ----
$fake = Join-Path $PSScriptRoot '.work\fakeprofile'
if (Test-Path $fake) { Remove-Item $fake -Recurse -Force }
$ws = Join-Path $fake 'AppData\Roaming\Code\User\workspaceStorage'
foreach ($id in @('aaaa1111', 'bbbb2222', 'cccc3333')) {
    [void][System.IO.Directory]::CreateDirectory((Join-Path $ws $id))
}

# aaaa1111: project CÒN tồn tại -> phải được GIỮ
$live = Join-Path $fake 'projects\live-project'
[void][System.IO.Directory]::CreateDirectory($live)
Set-Content (Join-Path $live 'a.js') 'x'
$liveUri = 'file:///' + ($live -replace '\\', '/' -replace ':', '%3A')
@{ folder = $liveUri } | ConvertTo-Json | Set-Content (Join-Path $ws 'aaaa1111\workspace.json')

# bbbb2222: project ĐÃ mất -> phải bị đề xuất xoá
@{ folder = 'file:///C%3A/Users/Admin/da-bi-xoa/project-cu' } | ConvertTo-Json |
    Set-Content (Join-Path $ws 'bbbb2222\workspace.json')
Set-Content (Join-Path $ws 'bbbb2222\state.vscdb') ('y' * 500)

# cccc3333: không metadata -> phải bỏ qua
Set-Content (Join-Path $ws 'cccc3333\state.vscdb') ('z' * 500)

$result = Get-IdeHistoryTargets -Limit 0 -ProfileDir $fake

Write-Host ''
Write-Host ('Mục đề xuất xoá: {0}' -f @($result.Targets).Count)
foreach ($t in @($result.Targets)) {
    Write-Host ('  {0}' -f $t.Path.Replace($fake, '<fake>'))
    Write-Host ('    lý do: {0}' -f $t.Reason)
}

$liveKept = @($result.Targets | Where-Object { $_.Path -like '*aaaa1111*' }).Count -eq 0
$deadFound = @($result.Targets | Where-Object { $_.Path -like '*bbbb2222*' }).Count -eq 1
$noMetaSkipped = @($result.Targets | Where-Object { $_.Path -like '*cccc3333*' }).Count -eq 0

Write-Host ''
Write-Host ('[1] project còn sống KHÔNG bị đụng     : {0}' -f $(if ($liveKept) { 'ĐẠT' } else { 'HỎNG' }))
Write-Host ('[2] project đã mất được phát hiện       : {0}' -f $(if ($deadFound) { 'ĐẠT' } else { 'HỎNG' }))
Write-Host ('[3] workspace thiếu metadata bị bỏ qua  : {0}' -f $(if ($noMetaSkipped) { 'ĐẠT' } else { 'HỎNG' }))

Remove-Item $fake -Recurse -Force

if ($liveKept -and $deadFound -and $noMetaSkipped) { exit 0 } else { exit 1 }
