# Môi trường test

Thư mục này chứa các cách chạy test suite của `presale-wiper` **mà không dùng
máy thật của bạn**. Mỗi script ứng với một mức cách ly khác nhau.

Tool này xoá dữ liệu vĩnh viễn, nên chạy test trên máy cá nhân là việc nên
tránh. Dưới đây là 4 mức, từ nhẹ nhất tới mạnh nhất.

---

## Chọn nhanh

| Mức | Script | Cần admin | Cần cài | Cách ly | Dùng được ngay |
|---|---|---|---|---|---|
| 1. GitHub Actions | `Start-GitHubActionsRun.ps1` | Không | git, gh | **VM Windows sạch, xoá sau mỗi run** | Cần mạng + tài khoản GitHub |
| 2. Windows Sandbox | `Start-WindowsSandbox.ps1` | Có (1 lần) | — | VM dùng-một-lần, xoá khi đóng | Sau khi bật feature + restart |
| 3. Hyper-V VM | `Start-HyperVVM.ps1` | Có | File ISO | VM đầy đủ, có snapshot/rollback | Sau khi bật Hyper-V |
| 4. Isolated root | `Start-IsolatedRoot.ps1` | Không | — | **Chỉ cách ly ở tầng thư mục**, cùng kernel | **Có** |

**Khuyến nghị:** dùng **mức 1** (GitHub Actions) nếu có mạng — đó là môi
trường sạch nhất và không cần quyền gì trên máy bạn. Dùng **mức 4** để có
vòng phản hồi nhanh trong lúc code.

---

## Trạng thái thực tế của máy này

Đã kiểm tra:

```
Edition            : Windows 10 Pro (25H2, build 26200)
WindowsSandbox.exe : KHÔNG CÓ
Hyper-V            : KHÔNG CÓ
Docker             : KHÔNG CÓ
WSL                : CHƯA CÀI
Quyền admin        : KHÔNG (phiên làm việc hiện tại)
VirtualBox/QEMU    : KHÔNG CÓ
winget             : CÓ
Ổ phụ              : D: (152 GB trống)
```

Kết luận: **mức 1 và mức 4 chạy được ngay**. Mức 2 và 3 cần bạn bật feature
(một lần, cần admin + restart).

### Đã chạy thật (mức 4, isolated root trên D:)

```
D:\presale-wiper-iso
  repo    (bản copy, không có .git)
  work    (fixtures + log, TMP/TEMP trỏ vào đây)
  results (nunit.xml)
```

```
Passed  : 312
Failed  : 0
Skipped : 0
Duration: 37.2s

PASS - test xanh trong isolated root
```

Kết quả lặp lại được (chạy 2 lần, cùng 312/312) và root tự dọn bằng `-Cleanup`.

Lệnh dùng:

```powershell
.\tests\environments\Start-IsolatedRoot.ps1 -RootPath 'D:\presale-wiper-iso' -Suite All -KeepResult
# hoặc, tự dọn khi xong:
.\tests\environments\Start-IsolatedRoot.ps1 -RootPath 'D:\presale-wiper-iso' -Suite All -Cleanup
```

---

## Mức 1 — GitHub Actions (khuyến nghị)

Runner của GitHub Actions là một VM Windows **dựng mới cho mỗi lần chạy và bị
xoá hoàn toàn sau đó**. Không có project cũ, không có `.env` thật, không có
Credential Manager của ai. Đây là môi trường gần nhất với "máy của người lạ"
mà không phải cài gì.

```powershell
# Cài công cụ (1 lần)
winget install --id Git.Git -e
winget install --id GitHub.cli -e
gh auth login

# Chạy
.\tests\environments\Start-GitHubActionsRun.ps1
```

Script sẽ tạo repo **private** tên `presale-wiper`, push code, chạy workflow
`.github/workflows/ci.yml` trên **2 phiên bản Windows Server** (2022 và 2025),
rồi tải kết quả XML về `tests\.results\`.

Không muốn đẩy code lên GitHub? Dùng `-SkipCreate` sau khi đã có repo, hoặc
chuyển sang mức 4.

---

## Mức 2 — Windows Sandbox

VM dùng-một-lần của Microsoft: mỗi lần bật là một Windows sạch, đóng cửa sổ
là xoá sạch. Rất phù hợp để test tool xoá dữ liệu.

### Bật một lần (cần admin + restart)

```powershell
# PowerShell với quyền Administrator
Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All
# Khởi động lại máy
```

Kiểm tra: `Test-Path C:\Windows\System32\WindowsSandbox.exe`

### Chạy

```powershell
.\tests\environments\Start-WindowsSandbox.ps1 -Suite All
```

Script chuẩn bị thư mục handoff gồm:
- bản copy repo (không có `.git`),
- **Pester 5 đã tải sẵn** (vì sandbox được cấu hình `Networking=Disable`),
- bootstrap script tự chạy khi đăng nhập.

Kết quả ghi ra `tests\.sandbox\work\sandbox-result.txt` và `.xml` — vẫn còn
sau khi Sandbox đóng, vì thư mục này được map từ host.

Tùy chọn: `-KeepOpen` để không tự tắt sau khi test xong.

---

## Mức 3 — Hyper-V VM

Cần khi test những thứ mà Sandbox không làm được: cài đặt lặp lại nhiều lần,
giữ trạng thái giữa các lần chạy, hoặc test Credential Manager / WSL / Docker
ở Phase 3.

### Bật một lần (cần admin + restart)

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
```

### Tải ISO

Microsoft cung cấp bản Evaluation miễn phí 90 ngày (script không tự tải —
bạn cần đồng ý điều khoản trên web):

- Windows 11 Enterprise: <https://www.microsoft.com/evalcenter/download-windows-11-enterprise>
- Windows 10 Enterprise: <https://www.microsoft.com/evalcenter/download-windows-10-enterprise>

### Tạo VM

```powershell
# PowerShell Admin
.\tests\environments\Start-HyperVVM.ps1 -IsoPath 'D:\ISO\Win11.iso'
```

VM được tạo với switch **Internal** (không lộ ra mạng LAN), 4 GB RAM, 60 GB ổ
ảo, boot từ ISO.

Sau khi cài Windows trong VM, chạy test bằng runner chung:

```powershell
# Trong VM
Z:\tests\environments\Invoke-TestSuite.ps1 -WorkDir C:\psw-work -ResultPath C:\psw-work\nunit.xml
```

### Rollback (điểm mạnh của VM)

Trước mỗi lần test:

```powershell
Checkpoint-VM -Name presale-wiper-test -SnapshotName clean
# ... chạy test ...
Restore-VMSnapshot -Name presale-wiper-test -SnapshotName clean -Confirm:$false
```

Mất khoảng 10 giây thay vì cài lại Windows.

---

## Mức 4 — Isolated root (không cần admin)

Dùng được ngay. Nguyên tắc:

1. Copy repo sang một **ổ khác** (mặc định tự chọn ổ phụ còn nhiều chỗ).
2. Sinh fixtures + mọi file tạm **trong** root đó.
3. Đặt `TMP`, `TEMP`, `PRESALE_WIPER_TEST_WORK` trỏ vào trong root.
4. Chạy test trong tiến trình PowerShell con với môi trường sạch
   (`-NoProfile`, không auto-load module user, không proxy).
5. Xuất kết quả XML, rồi có thể xoá sạch root bằng một lệnh.

```powershell
.\tests\environments\Start-IsolatedRoot.ps1
.\tests\environments\Start-IsolatedRoot.ps1 -Suite Unit -Cleanup
.\tests\environments\Start-IsolatedRoot.ps1 -RootPath 'E:\psw-iso' -KeepResult
```

### Giới hạn cần biết

Đây **không phải** VM. Nó cách ly ở tầng thư mục, không cách ly kernel hay
registry. Nếu tool có bug xoá `C:\Windows`, isolated root **không cứu được**.

Vì vậy khi dùng mức này:
- `presale-wiper` luôn chạy dry-run mặc định (không có cờ xoá ở Phase 1);
- guard (`src/guard.ps1`) là lớp bảo vệ chính, và đã có 48 unit test riêng;
- test integration chỉ quét, không xoá.

Dùng mức này để phát triển, và mức 1/2/3 trước khi phát hành.

---

## Đã kiểm chứng tới đâu

| Script | Trạng thái | Ghi chú |
|---|---|---|
| `Invoke-TestSuite.ps1` | ✅ **đã chạy thật** | 312/312 pass, dùng cho mọi mức |
| `Start-IsolatedRoot.ps1` | ✅ **đã chạy thật** | copy → chạy → dọn, lặp lại 3 lần đều 312/312 |
| `Start-GitHubActionsRun.ps1` | ⚠️ chưa chạy | cần `gh auth login`; workflow `ci.yml` đã viết xong |
| `Start-WindowsSandbox.ps1` | ⚠️ chưa kiểm chứng | máy không có Sandbox; đã kiểm tra syntax + logic điều kiện |
| `Start-HyperVVM.ps1` | ⚠️ chưa kiểm chứng | máy không có Hyper-V và không có ISO |

Ba script ⚠️ được viết theo đúng API chính thức nhưng chưa chạy thử trên máy
này vì thiếu điều kiện (không admin, không feature, không ISO). Nếu bạn bật
một trong hai feature rồi chạy mà gặp lỗi, gửi lại thông báo lỗi.

## Runner chung

`Invoke-TestSuite.ps1` là "một cửa" vào test suite, dùng được ở cả 4 mức:

```powershell
.\tests\environments\Invoke-TestSuite.ps1                      # tất cả, work dir mặc định
.\tests\environments\Invoke-TestSuite.ps1 -Suite Unit
.\tests\environments\Invoke-TestSuite.ps1 -WorkDir D:\psw-work -ResultPath D:\psw-work\nunit.xml
```

Nó tự:
- kiểm tra PowerShell và Pester 5 (cài nếu thiếu, không cần admin),
- sinh fixtures nếu chưa có,
- chạy Pester, xuất NUnit XML,
- in tổng kết và trả exit code 0/1.

Biến môi trường `PRESALE_WIPER_TEST_WORK` điều khiển nơi test ghi dữ liệu —
đây là cơ chế để mọi script ở trên ép test ghi vào đúng chỗ.

---

## Bảng đối chiếu: test nào cần môi trường nào

| Test | Mức 4 (isolated root) | Mức 2 (Sandbox) | Mức 3 (VM) |
|---|---|---|---|
| Unit tests (paths, classify, guard, log, size) | ✅ | ✅ | ✅ |
| Integration scan trên fixtures | ✅ | ✅ | ✅ |
| Long path > 260 ký tự | ✅ | ✅ | ✅ |
| Unicode path (tiếng Việt, 中文, emoji) | ✅ | ✅ | ✅ |
| Junction / symlink | ✅ | ✅ | ✅ |
| **Registry Windows thật** | ⚠️ dùng registry thật | ✅ | ✅ |
| **Credential Manager thật** (Phase 3) | ❌ | ✅ | ✅ |
| **WSL unregister** (Phase 3) | ❌ | ❌ | ✅ |
| **Docker Desktop data** (Phase 3) | ❌ | ❌ | ✅ |
| **Antivirus false-positive** | ❌ | ✅ | ✅ |
| **Rollback sau khi xoá nhầm** | ❌ | ⚠️ (Sandbox reset) | ✅ (snapshot) |
| **Windows 10 vs 11 khác nhau** | ❌ | ❌ | ✅ |
| **Non-admin user** | ✅ | ⚠️ (sandbox luôn admin) | ✅ |

Ghi chú: sandbox luôn chạy bằng tài khoản admin, nên không test được kịch bản
"user thường chạy scan". VM mức 3 mới làm được điều đó (tạo user standard).
