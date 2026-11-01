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
| `server`（預設） | 2 | 8 GiB | 20 GiB | SSH、開發工具、Tailscale |
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

## 排錯 / 版控

- 初始化：`sudo cloud-init status --long`、`/var/log/cloud-init-output.log`。
- 桌面：`journalctl --user -u agent-desktop`。
- Host：`journalctl -u libvirtd`。失敗會保留產物；先排錯，不要刪磁碟重建。
- 測試：`python3 -m unittest discover -s tests -v`（不需 sudo；另需 cloud-init、virt-xml-validate）。
- 只提交腳本、模板、文件。憑證、hash、映像與產生檔已排除 Git；提交前確認 `git diff --cached`，不要用 `git add -f` 加入本機資料。
