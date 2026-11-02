# KVM VM Provisioning

用 libvirt + cloud-init 建立 Ubuntu 26.04 VM。以下命令在 Host 的 repo 根目錄執行。
Host 需有 KVM/libvirt、OVMF、qemu-utils、cloud-image-utils、python3-yaml、OpenSSH、OpenSSL、curl，以及 `default` NAT。

## 建立 VM

映像只需下載一次，可續傳並驗證 SHA256：

```bash
./provisioning/download-image.sh "$PWD/cache"
```

只需指定 hostname；預設為 Server：

```bash
sudo ./provisioning/create-vm.sh dev-01
sudo ./provisioning/create-vm.sh desktop-01 --profile gui
```

| Profile | CPU | RAM | Disk | 內容 |
| --- | --- | --- | --- | --- |
| `server`（預設） | 2 | 8 GiB | 80 GiB | SSH、開發工具、Tailscale |
| `gui` | 8 | 16 GiB | 120 GiB | 另加 XFCE、TigerVNC、Chromium |

帳號預設 `agent`，沿用 Host 執行者的 `~/.ssh/authorized_keys`（sudo 下仍是原使用者）。
SSH 僅公鑰登入、sudo 免密碼；本機密碼 hash 自動產生。VM 自動開機，資料位於 `/var/lib/libvirt/images/VM名稱/`，不覆寫既有 VM。

```bash
# 選填設定、檢查、完整參數
sudo ./provisioning/create-vm.sh dev-02 --size-gib 40 --username developer
./provisioning/create-vm.sh dev-02 --dry-run
./provisioning/create-vm.sh --help
```

模板在 `provisioning/templates/{server,gui}-{domain.xml,user-data.yaml}`，可用 `--xml`、`--user-data` 覆寫。變更模板不影響既有 VM。

## 登入

查 IP，再從持有對應私鑰的電腦經 Host 跳板登入：

```bash
./provisioning/vm-status.sh dev-01
ssh -J HOST_USER@HOST_ADDRESS agent@VM_IP
```

Guest 初始化成功後，登入 Tailscale：

```bash
sudo cloud-init status --wait --long &&
  sudo tailscale up --hostname="$(hostname -s)"
```

完成網址登入，連線端使用同一個 tailnet、MagicDNS 且允許 SSH 後，可直接 `ssh agent@dev-01`。

## GUI / Mac VNC

Guest 裡設定專用 VNC 密碼（8 字元，view-only 選 n）：

```bash
mkdir -p ~/.config/tigervnc
tigervncpasswd ~/.config/tigervnc/passwd
systemctl --user restart agent-desktop
```

重啟會關閉桌面程式，先保存工作。Mac 連上 Tailscale 後開 tunnel：

```bash
ssh -N -L 127.0.0.1:5901:127.0.0.1:5901 agent@desktop-01
```

保持 Terminal 開著，Finder 按 ⌘K，連 `vnc://127.0.0.1:5901`。
Guest 用 `verify-desktop` 驗收，`desktop-exec COMMAND` 執行 X11 程式。

## OpenClaw

獨立部署的 Gateway 跑在 Host Docker，GUI Node 與瀏覽器跑在 Guest；不包含在 VM 建立流程內。
Control UI 使用 Host 的 Tailscale Serve HTTPS，連上 tailnet 後開 `https://HOST_MAGICDNS_NAME/`。
啟用、登入與維護步驟見 [OpenClaw 操作說明](services/openclaw/README.md)。
在 Host repo 根目錄用 `./openclaw ...` 執行容器內 CLI，例如 `./openclaw devices list`。

### 新電腦從頭設定

以下假設新電腦是 Linux Host，並要重新建立一台 GUI Guest。命令中的名稱與網址請換成自己的值；不要把 token、配對碼或密碼寫進 repo。

1. **Host：準備環境與登入 tailnet。** 安裝並設定 KVM/libvirt、OVMF、qemu-utils、cloud-image-utils、Python YAML、OpenSSH、OpenSSL、curl、Docker 與 Tailscale；確認 libvirt `default` NAT 可用。登入既有 tailnet，確認新 Host 有 MagicDNS 名稱。Docker、libvirt 與 Tailscale 的安裝方式依該台 Host 的 Linux 發行版官方文件。
2. **Host：取回 repo 與 SSH 公鑰。** clone 此 repo，將要登入 Guest 的公鑰放在執行者的 `~/.ssh/authorized_keys`；若沒有既有 key，先用 `ssh-keygen` 建立。下載並驗證 Base Image，再建立 GUI VM：

   ```bash
   ./provisioning/download-image.sh "$PWD/cache"
   sudo ./provisioning/create-vm.sh desktop-01 --profile gui
   ./provisioning/vm-status.sh desktop-01
   ```

   `vm-status` 取得 IP 只代表 DHCP 完成。Guest 初始化成功後，SSH 登入 Guest，等待 cloud-init 完成，再執行 `sudo tailscale up --hostname="$(hostname -s)"` 並完成登入；確認 Guest 也出現在同一 tailnet。
3. **Host：啟動 Gateway。** 先依 [首次部署步驟](services/openclaw/README.md#新-host首次部署) 建立專用帳號、資料目錄與初始設定，不能只 clone 後直接啟動。確認 Docker 可用且沒有需保留的舊資料，再從 repo 根目錄啟動服務並登入模型供應商：

   ```bash
   bash services/openclaw/compose.sh up -d
   ./openclaw models auth login --provider openai --device-code
   ```

   設定 Control UI 的 allowed origin 與 public origin 為 Host 的 `https://HOST_MAGICDNS_NAME`。先查 `tailscale serve status`，確認 HTTPS 443 沒有既有路由，再依 [OpenClaw 操作說明](services/openclaw/README.md) 啟用 Serve、檢查並設定 Gateway 的 trusted proxy。不得啟用 Funnel。瀏覽器端登入同一 tailnet 後開啟該 HTTPS 網址；UI 仍須用 token 登入並批准新裝置配對。
4. **GUI Guest：安裝並連線 Node。** 按 [Guest 設定步驟](services/openclaw/README.md#新-gui-guest) 安裝與 Gateway 同版本的 OpenClaw，以及相容的 Node.js，透過 `wss://HOST_MAGICDNS_NAME:443` 連線。建立瀏覽器與 Node 使用者服務後，在 Host 分別核對並批准裝置配對與 Node 能力請求，再確認 `./openclaw nodes status`。

Host 與 Guest 必須同時在線於同一 tailnet，Control UI 才能經 Serve 使用，Guest Node 才能連到 Gateway。Gateway 的模型登入、OpenClaw state/token、Serve 設定及配對狀態不會因 clone repo 自動搬過來；舊服務資料若要遷移，須另外備份並安全還原，勿提交或貼出資料目錄、Dashboard URL、token 或 QR 碼。各階段需分別確認：VM 開機、Guest cloud-init 完成、兩端 Tailscale 在線、Serve 可達、UI 裝置已批准、Node 已連線。

## 排錯 / 版控

- 初始化：`sudo cloud-init status --long`、`/var/log/cloud-init-output.log`。
- 桌面：`journalctl --user -u agent-desktop`。
- Host：`journalctl -u libvirtd`。失敗會保留產物；先排錯，不要刪磁碟重建。
- 測試：`python3 -m unittest discover -s tests -v`（不需 sudo；另需 cloud-init、virt-xml-validate）。
- 只提交腳本、模板、文件。憑證、hash、映像與產生檔已排除 Git；提交前確認 `git diff --cached`，不要用 `git add -f` 加入本機資料。
