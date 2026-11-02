# 接手指南

這是自用、可公開的 KVM VM provisioning repo，不是通用 VM 管理產品。先讀 `README.md` 與 `provisioning/create-vm.sh --help`，保持介面簡單、文件簡短中文。

## 工作方式

- 使用者常從手機 SSH 操作；需要他執行時，提供可直接貼上的短命令，說明是在 Host 還是 Guest。
- 需要 sudo 的操作由使用者在自己的終端執行。不要代跑 sudo、索取密碼，或透過 Guest／其他管道繞過這個分工；先完成本機程式與無特權驗證，再給命令。
- 可自行做不需 sudo 的程式修改、靜態檢查、測試與唯讀盤點。工具 sandbox 的核准與作業系統 sudo 是兩回事。
- 不更改 Host 實體網路、不干擾既有 Docker／Tailscale／VM。修改 Host 服務前先查現況，不因 repo 有安裝腳本就假設線上設定相同。
- 先讀 `git status`，保留使用者已有修改。不自行 commit、push、公開 repo 或改寫 Git 歷史。
- 不把未驗證的結果說成完成：區分模板檢查、VM 啟動、取得 DHCP、cloud-init 完成、Guest 功能驗收。

## 介面與程式位置

唯一建立入口：

```bash
sudo ./provisioning/create-vm.sh HOSTNAME
sudo ./provisioning/create-vm.sh HOSTNAME --profile gui
```

- 預設 `server`：2 vCPU／8 GiB／80 GiB；`gui`：8 vCPU／16 GiB／120 GiB。帳號預設 `agent`。
- 不新增每台機器的 wrapper，也不再分 `create-server-vm.sh`、`create-gui-vm.sh`。差異放 profile／模板，進階需求用選填參數。
- `templates/server-*`、`templates/gui-*`：libvirt Domain XML 與 cloud-init YAML。
- `scripts/render.py`：注入帳號、多把 SSH 公鑰、密碼 hash、唯一 instance-id；GUI 才注入桌面檔案與命令。內部呼叫必須明確傳 profile。
- `download-image.sh`：一般使用者下載、續傳、官方 SHA256 驗證。Base Image 與 manifest 固定重用、唯讀；下載與建立分開。
- `create-disk.sh`：獨立稀疏 qcow2，沒有 backing chain，拒絕覆寫或縮小。
- `vm-status.sh`：唯讀查狀態／等待 DHCP。exit 0 只表示拿到 IP；exit 2 是等待逾時。
- `guest/`：持續桌面與檢查工具；`tests/`：不需 sudo 的回歸測試。
- `host/install-cockpit.sh`：選用的 Host 工具，不是 VM 建立流程的一部分。
- `fix-vm-firmware.sh`：舊版韌體選擇錯誤的窄範圍修復，不是一般建立流程。

## 不變的架構

- Host 是基礎設施／Control Plane，Guest 是執行環境。Guest 不掛 Host filesystem、Docker socket 或 libvirt socket。
- Ubuntu 26.04 amd64 Cloud Image + cloud-init，KVM、q35、host-passthrough、UEFI、VirtIO、default NAT、自動開機。
- 使用一般 OVMF pflash 的 CODE／VARS。曾遇到自動 firmware selection 選中 `OVMF.amdsev.fd`，被 virt-aa-helper 拒絕；不要以停用 AppArmor 當作修法。
- VM 資料固定 `/var/lib/libvirt/images/HOSTNAME/`，注意 QEMU 權限與 AppArmor。既有 domain 或目錄不可覆寫，失敗保留產物供診斷。
- 不對運作中 VM 做離線磁碟寫入，不自動刪除失敗的 VM／磁碟來重試。
- 新 VM 複製 Host 呼叫者的 `~/.ssh/authorized_keys`；sudo 下依 `SUDO_UID` 找原使用者。保留 key options，只複製公鑰、不持續同步。
- SSH 密碼與 keyboard-interactive 關閉；Guest 保留 `NOPASSWD:ALL`。隨機本機密碼只保存 hash，不記錄明文。
- Tailscale 自動安裝並啟動服務，首次 `tailscale up` 由使用者登入；不在 cloud-init 放 auth key，不啟用 Tailscale SSH／subnet router／exit node。
- VM provisioning 模板仍不預裝 OpenClaw；獨立部署放 `services/openclaw/`。Gateway 使用 Host 既有 Docker，以專用 `openclaw` UID/GID 執行；Node 與桌面瀏覽器放 GUI Guest。整合時查當時官方文件／原始碼，不猜工具路由或配置欄位。
- OpenClaw Control UI 使用 Host Tailscale Serve 提供 tailnet HTTPS，Docker 僅發布 localhost:18789；保留 token 與裝置配對，不啟用 Funnel。先查 Serve 現況再修改，不覆蓋其他服務。Guest Node 也經 Tailscale 連 Host Serve 的 WSS:443，需 Guest Tailscale 在線；原 SSH tunnel 已停用。Docker bridge 被列為可信代理後，不使用缺少 forwarded headers 的 SSH tunnel 連入。

## GUI 注意事項

- XFCE + Xtigervnc `:1`，由 systemd user service + linger 管理，不裝 display manager。桌面生命週期獨立於 Agent 與 SSH。
- Agent 與人共用同一個 display；用 `desktop-exec` 帶入 Xauthority、D-Bus 與 runtime 環境，不只是設定 DISPLAY。
- VNC 只監聽 Guest localhost:5901，透過 SSH tunnel 使用。有 `~/.config/tigervnc/passwd` 就用 VncAuth，否則 None。
- Mac 螢幕共享曾要求 VNC 密碼；使用獨立 8 字元密碼。重啟桌面會關閉應用程式，操作前告知使用者。
- Chromium 用 Snap，不使用 root 或 `--no-sandbox`。Server 不應包含任何桌面元件或顯示 GUI 驗收提示。

## 驗證與交接

```bash
bash -n provisioning/*.sh host/*.sh
python3 -m unittest discover -s tests -v
git diff --check
```

測試依賴 qemu-img、ssh-keygen、openssl、python3-yaml、cloud-init、virt-xml-validate；只使用暫存映像與設定，不操作 libvirt。
有已驗證的 cache 及 Host 公鑰時，可用 `create-vm.sh TEST_NAME --profile server|gui --dry-run` 檢查實際輸入；它不檢查 libvirt 狀態，也不代表 VM 已實機驗收。
涉及 profile／render／建立流程時測兩種 profile；涉及 sudo／開機／GUI 的結果由使用者執行並回傳。修改模板不會更新既有 VM，不要求使用者重跑 cloud-init 來套更新。

## Public-ready

- 版控只放程式、模板、文件、測試。文件用範例 hostname 與位址佔位符，不放實際帳號路徑、IP、設備清單。
- `credentials/`、`cache/`、`state/`、金鑰、authorized_keys、hash、seed ISO、磁碟及產生的 user-data 都留在本機；不要讀出或輸出秘密。
- 不用 `git add -f` 加入被忽略的資料。公開前檢查可提交檔案與已追蹤檔案；`.gitignore` 不能清除歷史中的秘密。
- 歷史曾做過憑證掃描但不代表未來修改安全；發現已追蹤或歷史中的秘密先回報，不擅自改寫歷史。
- README 只保留使用步驟；接手規則放本檔。實際 VM 名稱、IP 與狀態以唯讀查詢為準，不把對話中的舊值當現況。
