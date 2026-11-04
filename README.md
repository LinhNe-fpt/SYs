# presale-wiper

CLI tool dọn môi trường lập trình trên Windows trước khi bán/thanh lý máy.
Mặc định là **dry-run**: chỉ quét và liệt kê, không xoá gì.

> **Trạng thái: Phase 1 (scan).** Lệnh `clean` chưa được bật. Xem
> [Roadmap](#roadmap) để biết phần còn lại.

## Vì sao

Trước khi bán máy, người ta thường quên những thứ nằm ngoài "My Documents":
`node_modules`, `target`, `.venv`, hàng trăm repo cũ, `.env` còn token, `.ssh`,
`.gitconfig`, `.aws/credentials`. Tool này tìm và (ở các phase sau) dọn chúng,
có kiểm soát và có log.

## Cài đặt

Không cần cài. Yêu cầu:

- Windows 10 1903+ hoặc Windows 11
- Windows PowerShell 5.1 (có sẵn trên mọi bản Windows) hoặc PowerShell 7+
- Quyền admin **không bắt buộc** cho `scan`

```powershell
git clone https://github.com/LinhNe-fpt/SYs.git presale-wiper
cd presale-wiper
```

## Dùng

```powershell
# Quét các thư mục dev quen thuộc (source\repos, Projects, Developer...)
.\presale-wiper.ps1 scan

# Quét một thư mục cụ thể
.\presale-wiper.ps1 scan C:\Users\Admin\Desktop

# Chỉ quan tâm mục lớn hơn 50 MB
.\presale-wiper.ps1 scan -MinSize 50MB

# Xuất JSON cho tooling khác
.\presale-wiper.ps1 scan -JsonPath report.json

# Quét lại xem còn sót gì
.\presale-wiper.ps1 verify

# Đọc lại log của lần chạy trước
.\presale-wiper.ps1 report -FromLog ~\.presale-wiper\presale-wiper.log -Tail 50
```

## Chạy một lần, chỉ lấy danh sách

Nếu bạn chỉ muốn **danh sách file cần dọn** để tự xem, dùng `scan-once.ps1`:
file độc lập, không import module, không cần admin, không hỏi xác nhận, và
**không chứa bất kỳ lệnh xoá nào**.

Cách dễ nhất: **double-click `presale-scan.cmd`**, một file duy nhất, tạo bằng
`.\tools\Build-PresaleScanCmd.ps1`. Không hỏi gì và **chạy ẩn**: không có cửa
sổ console (vẫn thấy `powershell.exe` trong Task Manager); quét xong tự mở thư
mục kết quả trong Explorer; nếu lỗi thì hiện hộp thoại. Cần xem log trên
console thì build bằng `-Visible`. (`scan-once.cmd` làm tương tự nhưng cần nằm
cạnh `scan-once.ps1`.)

Nếu file được tải qua trình duyệt / Zalo / email, Windows gắn nhãn "từ
Internet" và hỏi một lần trước khi chạy. Bỏ nhãn trước khi chạy: chuột phải
file → Properties → tick **Unblock**, hoặc `Unblock-File .\presale-scan.cmd`.

Hoặc từ PowerShell:

```powershell
.\scan-once.ps1
```

Mặc định quét **toàn bộ PC**: gốc mọi ổ cố định (`C:\`, `D:\`, ...; không quét
USB / ổ mạng). Tự bỏ qua:

- Windows, Program Files, ProgramData, AppData, thùng rác, System Volume Information
- toolchain / game / driver nằm ngay dưới gốc ổ (`C:\Python312`, `C:\Go`,
  `D:\SteamLibrary`, `Riot Games`, `msys64`, ...)
- thư mục phần mềm đã cài (có `.exe`/`.dll` mà không có marker project); riêng
  web server như xampp vẫn xét `htdocs` / `www`
- trong `.vscode`, `.cargo`, ... của mỗi profile: chỉ tìm secret

Desktop, Downloads, Documents, ... của mọi profile không bao giờ bị đề xuất
nguyên thư mục, chỉ các mục con. Thêm `-DevFoldersOnly` để chỉ quét
`source\repos`, `Projects`, `D:\Projects`, ...

Quét profile của người dùng khác cần chạy bằng quyền admin; không có quyền thì
các thư mục đó bị bỏ qua.

Quét xong, kết quả in ra **toàn bộ** (không còn kiểu "... và N mục khác"), chữ
màu xanh lá. Ấn **Enter** để chuyển sang `remove-once.ps1`: bước này in kế
hoạch xoá (đủ từng file, từng thư mục) và **chưa xoá gì**; ấn Enter lần nữa mới
xoá thật. Đóng cửa sổ ở bất kỳ bước nào là huỷ.

## Dọn file theo danh sách: `remove-once.ps1`

Tiêu thụ danh sách của `scan-once.ps1`. **Mặc định chỉ mô phỏng, không xoá gì**:

```powershell
.\remove-once.ps1                                  # dùng presale-scan-* mới nhất
.\remove-once.ps1 -Plan C:\Users\Admin\presale-scan-20261104-090000
.\remove-once.ps1 -Keep '*\BOT\*','*\VPQL\*'       # loại trừ project muốn giữ
```

Kết quả ghi ra `ke-hoach-xoa-<thời gian>.txt/.csv/.json`, gồm danh sách file sẽ
xoá và danh sách **bị bỏ qua kèm lý do** (guard).

Xoá thật chỉ khi gõ đủ cả hai:

```powershell
.\remove-once.ps1 -Execute -ConfirmToken XOA
```

Xoá vĩnh viễn là **không hoàn tác được**. Khi xoá, công cụ xoá cả file **và**
các thư mục của target (con trước cha), nên thư mục project không còn lại vỏ
rỗng; thư mục nào còn file lạ hoặc bị khoá thì được giữ lại.

Mặc định **không giới hạn** số file / dung lượng: quét liệt kê hết, xoá hết.
Vẫn có thể tự đặt trần cho an toàn (`-MaxFilesPerTarget` khi quét,
`-MaxFiles` / `-MaxBytes` khi xoá; `0` = không giới hạn). Chế độ `-Execute`
vẫn từ chối chạy nếu:

- thiếu `-ConfirmToken XOA`
- vượt `-MaxFiles` (mặc định 20.000) hoặc `-MaxBytes` (mặc định 20 GB)
- bất kỳ file nào nằm trong Windows / Program Files / ProgramData / AppData,
  gốc ổ, thùng rác, thư mục hệ thống của ổ, hoặc thư mục chứa chính công cụ này
- file hệ thống như `pagefile.sys`, `hiberfil.sys`, `bootmgr`

Không có chế độ chạy nền dài ngày, không có cơ chế ẩn khỏi Task Manager. Nếu
cần dọn định kỳ, hãy dùng Windows Task Scheduler với tác vụ hiển thị được và
log đầy đủ; đừng chạy ở chế độ không ai giám sát.

Kết quả ghi vào `%USERPROFILE%\presale-scan-<timestamp>\`:

| File | Nội dung |
|---|---|
| `*.txt` | Danh sách đường dẫn tuyệt đối, mỗi file một dòng — dùng để đọc/xem |
| `*.csv` | Chi tiết: path, size, kind, lý do — mở bằng Excel để lọc/sắp xếp |
| `*.json` | Cho tooling, có `"deleted": false` |

Tuỳ chọn:

```powershell
.\scan-once.ps1 -Path D:\OldProjects          # quét thư mục cụ thể
.\scan-once.ps1 -MinSize 100MB                # chỉ mục lớn
.\scan-once.ps1 -Kind Secret                  # chỉ tìm secret
.\scan-once.ps1 -OutDir C:\temp\my-list       # đổi nơi ghi
```

Đã kiểm chứng read-only: hash toàn bộ cây fixture (SHA-256 trên tên + kích
thước + mtime của 84 file) **không đổi** sau khi chạy.

### Tuỳ chọn thường dùng

| Tuỳ chọn | Ý nghĩa |
|---|---|
| `-Path <string[]>` | Thư mục cần quét |
| `-IncludeHome` | Cho phép quét cả `%USERPROFILE%` (chậm hơn nhiều) |
| `-Exclude <string[]>` | Mẫu loại trừ (wildcard trên path hoặc tên) |
| `-MinSize <string>` | Chỉ báo mục >= kích thước (`100MB`, `1.5GB`, `2097152`) |
| `-MaxDepth <int>` | Độ sâu tối đa tính từ root |
| `-NoSize` | Không đo dung lượng (nhanh hơn) |
| `-Json` / `-JsonPath` | Xuất JSON ra stdout / ra file |
| `-Log <path>` / `-NoLog` | Ghi log / không ghi |
| `-Quiet` | Chỉ in tổng kết |

Exit code: `0` OK, `1` cảnh báo, `2` lỗi nghiêm trọng, `3` user cancel.

### Output mẫu

```
==============================================================================
  presale-wiper - KẾT QUẢ QUÉT (DRY-RUN, chưa xoá gì)
==============================================================================

Thư mục đã quét:
  [Scanned] C:\Users\Admin\Projects  ->  23 entry

--- Các mục CÓ THỂ xoá (sắp xếp theo dung lượng) ---
Loại     Dung lượng  Đường dẫn (tương đối)
-------  ----------  -----------------------------------------------------------------
Project    150.1 KB  project_rust
Project     30.1 KB  project_python
DevDir       4.0 KB  orphan_devdirs\node_modules
Secret        37 B   secret_folder\.ssh

--- Tổng kết ---
  Project       :    12  (200.4 KB)
  DevDir        :     3  (4.0 KB)
  Secret        :     7  (78 B)
  Có thể giải phóng: 204.5 KB
```

## Phân loại

| Kind | Nghĩa |
|---|---|
| `Project` | Folder là gốc một project code (có marker hoặc đủ file code) |
| `DevDir` | Folder rác của dev: `node_modules`, `target`, `.venv`, `dist`... |
| `Secret` | File/folder chứa thông tin đăng nhập: `.env`, `.ssh`, `.gitconfig`... |
| `CodeFile` | File code lẻ, nằm ngoài project nào |
| `MediaHeavy` | Folder bị media chi phối — **không** đề xuất xoá |

## An toàn

Đây là phần quan trọng nhất của dự án.

- **Dry-run mặc định.** Không có cờ nào xoá gì ở Phase 1.
- **Deny by default.** Guard có 8 luật chặn: gốc ổ đĩa, `C:\Windows`,
  `Program Files`, `AppData`, folder shell của user (`Desktop`, `Documents`...),
  và mọi path không tồn tại.
- **Hai loại vùng cấm.** `SystemSubtree` cấm cả cây. `ExactOnly` chỉ cấm chính
  folder đó — nên project trong `Documents\Projects\app` vẫn dọn được, nhưng
  không bao giờ xoá cả `Documents`.
- **Junction/symlink không bao giờ bị đi theo** — chống loop và chống xoá
  dữ liệu ngoài cây đang xét.
- **Có trần duyệt** (750.000 entry) để không treo máy khi gõ nhầm path.
- **Log đầy đủ** kể cả trong dry-run: mỗi entry một dòng TSV, có lý do.

Chi tiết: [`tests/environments/README.md`](tests/environments/README.md),
`src/guard.ps1`.

> Tool này **không** thay thế factory reset. Nếu máy có dữ liệu nhạy cảm thật
> sự, hãy wipe ổ đĩa thay vì chỉ xoá file.

## Kiến trúc

```
presale-wiper.ps1        wrapper CLI (map tham số -> module)
src/
  presale-wiper.psd1     manifest, export list
  presale-wiper.psm1     loader (thứ tự phụ thuộc)
  paths.ps1              long path (\\?\), so sánh path, junction
  size.ps1               đo dung lượng có cache
  config.ps1             hằng số: extension, marker, danh sách cấm
  classify.ps1           quyết định Kind (pure function, dễ test)
  guard.ps1              lớp an toàn
  walk.ps1               duyệt cây, prune
  report.ps1             bảng console + JSON
  log.ps1                log TSV, rotate
  cli.ps1                subcommand, exit code
tests/
  Unit/                  284 test (Pester 5+)
  Integration/           28 test chạy CLI thật qua tiến trình con
  environments/          chạy test trong môi trường cách ly
  New-TestFixture.ps1    sinh cây fixture (long path, unicode, secret...)
```

## Test

```powershell
# Toàn bộ suite, trong môi trường cách ly trên ổ khác
.\tests\environments\Start-IsolatedRoot.ps1 -Suite All

# Chỉ unit test
.\tests\environments\Invoke-TestSuite.ps1 -Suite Unit
```

Hiện tại: **312/312 pass** (37s). Test bao gồm long path > 260 ký tự, Unicode
(`dự án tiếng Việt`, `项目`, emoji), junction, file bị khoá, và guard rules.

Các môi trường khác (Windows Sandbox, Hyper-V, GitHub Actions) — xem
[`tests/environments/README.md`](tests/environments/README.md).

## Roadmap

- [x] **Phase 0** — skeleton, CI
- [x] **Phase 1** — scan: long path, classify, guard, report, log
- [ ] **Phase 2** — clean: xoá file/folder, retry, `ERROR_SHARING_VIOLATION`
- [ ] **Phase 3** — Windows-specific: Credential Manager, WSL, Docker Desktop
- [ ] **Phase 4** — CLI UX: `clean --nuke`, `--yes`, progress bar
- [ ] **Phase 5** — hardening: VM test, antivirus, non-admin
- [ ] **Phase 6** — docs, release binary

## Giới hạn đã biết

- Chưa có `clean`. Phase 1 chỉ quét.
- `scan` là single-threaded (PowerShell 5.1 không có `ForEach-Object -Parallel`).
- Không quét `AppData` (quá nhiều file hệ thống, và guard cấm xoá ở đó).
- Không xử lý macOS/Linux.

## License

Chưa chọn. Xem [Roadmap](#roadmap) Phase 0.2.
