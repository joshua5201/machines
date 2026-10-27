# GUI Agent VM

用 KVM/libvirt + cloud-init 建立 Ubuntu 26.04 GUI VM，不安裝 OpenClaw。
預設 8 vCPU、16 GiB RAM、120 GiB 獨立稀疏 qcow2、UEFI、default NAT、自動開機。
桌面是 XFCE + TigerVNC `:1`，附 Chromium 和 X11 操作工具。

腳本與設定已完成靜態檢查；尚未完成 VM 實機驗收。
以下命令都從專案根目錄執行，需要 sudo 的操作請自行執行。

## 建立第一台

Host 需要 KVM、libvirt、OVMF、cloud-image-utils、python3-yaml、curl、OpenSSH、OpenSSL，且已有 `default` NAT。

第一台名稱 `gui-agent-01`，帳號 `agent`。本機已準備好 `credentials/gui-agent-01/`；此目錄不會放進 Git。
重新 clone 或建立新憑證時才執行以下命令（拒絕覆寫既有目錄）：

```bash
(
  set -eu
  umask 077
  mkdir -p credentials
  mkdir credentials/gui-agent-01
  ssh-keygen -q -t ed25519 -N '' -C gui-agent-01-bootstrap \
    -f credentials/gui-agent-01/id_ed25519
  python3 - <<'PY'
import secrets, subprocess
with open('credentials/gui-agent-01/password.hash', 'x') as f:
    subprocess.run(['openssl', 'passwd', '-6', '-stdin'],
                   input=secrets.token_urlsafe(48) + '\n',
                   text=True, stdout=f, check=True)
PY
)
```

下載映像（一般使用者），再建立 VM：

```bash
./provisioning/download-image.sh "$PWD/cache" &&
  sudo ./provisioning/create-first-vm.sh
```

如果另一個下載仍在進行，先執行 `flock cache/.download.lock true` 等待，再執行上面的命令。
下載支援續傳，會驗證官方 SHA256；成功後重用唯讀基底。若官方 `current` 更新導致 checksum 不符，請改用新 cache 目錄，勿覆寫舊基底。

VM 資料位於 `/var/lib/libvirt/images/gui-agent-01/`。腳本拒絕覆寫既有 VM 或目錄，失敗會保留產物供檢查。

## 登入與桌面

建立腳本會顯示 IP，也可以在 Host 查詢：

```bash
virsh -c qemu:///system domifaddr gui-agent-01 --source lease
ssh -i credentials/gui-agent-01/id_ed25519 -o IdentitiesOnly=yes agent@VM_IP
```

SSH 只允許公鑰登入；密碼及 keyboard-interactive 登入已關閉。隨機本機密碼只保存 hash，帳號保留 `NOPASSWD:ALL` sudo。
可以先登入 Host，再用上述金鑰進 VM，之後把自己的公鑰加入 Guest 的 `~/.ssh/authorized_keys`。

Guest 內等待初始化、檢查桌面：

```bash
sudo cloud-init status --wait --long
verify-desktop
# 啟動 Chromium：
systemd-run --user --unit=chromium --collect desktop-exec /snap/bin/chromium
```

`verify-desktop` 會操作滑鼠、截圖並開啟 Chromium。`desktop-exec COMMAND` 會設定 X11 認證與 D-Bus 環境，不要只設定 `DISPLAY`。
桌面由 systemd user service 與 linger 管理，SSH 登出不會關閉；Chromium 安裝需要 Guest 連外。

在持有 VM 私鑰的電腦上開 SSH tunnel（直接連 VM 或加上 `-J HOST_USER@HOST_ADDRESS` 跳板）：

```bash
ssh -i /path/to/vm-private-key -N -L 5901:127.0.0.1:5901 agent@VM_IP
```

VNC Viewer 連 `127.0.0.1:5901`。VNC 只監聽 Guest localhost，不設額外 VNC 密碼，由 SSH tunnel 提供存取認證。

## 第二台 VM

準備另一組公鑰及密碼 hash 後執行：

```bash
sudo ./provisioning/create-vm.sh \
  --name gui-agent-02 --username agent \
  --ssh-key "$PWD/credentials/gui-agent-02/id_ed25519.pub" \
  --password-hash "$PWD/credentials/gui-agent-02/password.hash" \
  --base-image "$PWD/cache/resolute-server-cloudimg-amd64.img" \
  --vm-dir /var/lib/libvirt/images/gui-agent-02 \
  --size-gib 120
```

帳號可改；VM 目錄必須是 `/var/lib/libvirt/images/VM名稱`。
CPU/RAM 改 `provisioning/templates/domain.xml`，套件改 `provisioning/templates/user-data.yaml`；亦可透過 `--xml`、`--user-data` 指定其他模板。
每台磁碟沒有 backing file，可獨立備份；請先關機，並另存 domain XML 與 UEFI NVRAM。

## 排錯與公開 repo

Guest 初始化錯誤看 `/var/log/cloud-init-output.log`；桌面錯誤用：

```bash
journalctl --user -u agent-desktop.service -b
```

只提交腳本、模板與文件。`credentials/`、`cache/`、`state/`、私鑰、密碼 hash、映像及 seed ISO 都已加入 `.gitignore`。
產生的 user-data 含密碼 hash，也不要提交。不要用 `git add -f` 加入這些檔案；`.gitignore` 不會移除已追蹤的檔案。
提交前用 `git diff --cached --name-only` 與 `git diff --cached` 確認內容。
