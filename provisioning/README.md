使用方式請看專案根目錄的 [README](../README.md)。

## 無 sudo runner

Host 建立新 VM（只設定權限與基礎服務，不預裝 Android SDK／JDK／GitHub runner）：

```bash
sudo ./provisioning/create-vm.sh android-build-server --profile server --cpu 4 --ram 12 --no-sudo
```

兩種 profile 都支援 `--no-sudo`。Host 建立 VM 仍需要 sudo；Guest 的 cloud-init 以 root 初始化，日後登入的帳號沒有 sudo，也不加入 Docker／libvirt 群組。系統套件需求須在建立前放進 `--user-data` 模板的 `packages`；系統維護仍由 Host 管理員安排，不讓 workflow 提權安裝套件。此選項不會更新既有 VM。

Guest：等待初始化，成功後人工登入 Tailscale：

```bash
cloud-init status --wait --long && tailscale up --hostname="$(hostname -s)"
```

帳號是 Guest 的 [Tailscale operator](https://tailscale.com/docs/reference/troubleshooting/linux/linux-operator-permission)，可管理這台 Guest 的 Tailscale；不自動登入，不啟用 Tailscale SSH／路由／exit node。

將專案需要的 JDK、Android SDK、AVD 與 runner 安裝到 home，確認其系統依賴已預裝。GitHub runner 依 GitHub 註冊畫面下載、驗證並執行 `config.sh`，註冊 token 不寫入 repo。runner 若裝在 `~/actions-runner`，可在 Guest 用 user service 自動啟動：

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/github-runner.service <<'EOF'
[Unit]
Description=GitHub Actions runner

[Service]
WorkingDirectory=%h/actions-runner
ExecStart=%h/actions-runner/runsvc.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now github-runner
journalctl --user -u github-runner -n 30 --no-pager
```

cloud-init 已設定 linger，登出 SSH 後 user service 仍會執行。使用官方要求的 [`runsvc.sh` 服務入口](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/configure-the-application#customizing-the-self-hosted-runner-service)，不執行需要 root 的 `svc.sh install`。workflow 中的 `sudo` 或需要 Docker daemon 的 job 不會因此獲得權限。

## Guest 驗收

以 runner 的一般帳號執行，以下假設 SDK 位於 `~/Android/Sdk`：

```bash
id
if sudo -n true; then echo 'FAIL: sudo is allowed'; else echo 'sudo denied'; fi
test -r /dev/kvm && test -w /dev/kvm && echo 'KVM device accessible'
systemctl --user is-system-running
~/Android/Sdk/emulator/emulator -accel-check
~/Android/Sdk/platform-tools/adb devices -l
```

Host 須支援並啟用 nested KVM；模板使用 host-passthrough。Guest 初始化只在暴露 `svm`／`vmx` 時載入對應 KVM 驅動，不會修改 Host。裝置可讀寫、`-accel-check` 成功仍不等於 AVD 已開機。Android 官方仍列有 [VM 內加速的限制](https://developer.android.com/studio/run/emulator-acceleration#restrictions)，必須實測。

Guest：先建立 x86_64 AVD，再把以下 `AVD_NAME` 換成實際名稱，於另一個 SSH session 啟動：

```bash
~/Android/Sdk/emulator/emulator -avd AVD_NAME -no-window -no-audio -accel on -gpu software
```

從 `adb devices -l` 找到模擬器 serial，指定 `adb -s SERIAL shell getprop sys.boot_completed` 回傳 `1`，再測安裝 APK、截圖與一個 GitHub job。多裝置時一律明確指定 serial；USB 手機另外確認 Host 直通成功、Guest udev rules 涵蓋裝置、手機批准 USB debugging，並以一般帳號驗證安裝與截圖。模板檢查、KVM 可用、AVD 開機、USB 可用與 job 成功是不同驗收階段。
