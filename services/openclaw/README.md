# OpenClaw Gateway

Host 使用既有 Docker，容器以專用 `openclaw` 系統帳號的 UID/GID 執行。
帳號禁止登入；資料固定在 `/var/lib/openclaw/{state,auth}`，權限 0700。
不掛 Docker/libvirt socket，也不掛 Host 使用者 home。

在 repo 根目錄操作（需 Docker 群組權限）：

```bash
bash services/openclaw/compose.sh ps
bash services/openclaw/compose.sh up -d
./openclaw models auth login --provider openai --device-code
```

介面或官方文件的 `openclaw ...`，在 Host repo 根目錄改成 `./openclaw ...`。
wrapper 直接呼叫執行中的 Gateway 容器，保留參數、stdin 與 exit code；互動終端啟用 TTY，管線自動停用 TTY。
容器未啟動時先執行上面的 `compose.sh up -d`。不需 sudo，也不需在 Host 安裝 OpenClaw。
這個入口管理 Gateway；文件若明確要求在 Node 執行，仍須在 Guest 操作。

## GitHub CLI

Gateway 使用官方 OpenClaw 固定版本為基底，加入官方 `gh 2.103.3` amd64 套件並驗證 SHA256。
在 **Host repo 根目錄**建置、套用；套用會短暫重啟 Gateway：

```bash
bash services/openclaw/gateway-update.sh
```

腳本建置並套用 repo 固定版本，再確認 gh 版本；任一步失敗就停止，不會自動升到 latest。
首次使用 gh 再登入：

```bash
bash services/openclaw/compose.sh exec gateway gh auth login --hostname github.com --git-protocol https --web
bash services/openclaw/compose.sh exec gateway gh auth status
```

依提示在自己的瀏覽器完成 GitHub 登入；不要分享登入碼或 token。
`GH_CONFIG_DIR` 指向既有持久掛載的 `/home/node/.config/openclaw/gh`，重建容器仍保留登入。
容器沒有系統 keyring 時，gh 會將 token 存成檔案，納入服務私有資料備份，勿提交 Git。
可用 `bash services/openclaw/compose.sh exec gateway gh repo list` 操作。
安裝方式與登入行為見 [官方 Linux 安裝文件](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
及 [gh auth login](https://cli.github.com/manual/gh_auth_login)。

## Gateway 操作

```bash
./openclaw --help
./openclaw devices list
./openclaw devices approve REQUEST_ID
./openclaw nodes status
```

Gateway 僅發布 Host localhost:18789；Web Control 使用 Host 的 Tailscale Serve 提供 HTTPS。
先在 Host 查現況，確認 HTTPS 443 沒有其他 Serve 路由再啟用（sudo 由使用者執行）：

```bash
tailscale serve status
sudo tailscale serve --bg --https=443 http://127.0.0.1:18789
```

首次若提示啟用 Serve／HTTPS，依 CLI 網址登入 tailnet 管理介面授權；不啟用 Funnel。
將 `https://HOST_MAGICDNS_NAME` 加入 Gateway 的 `gateway.controlUi.allowedOrigins`，保留既有 origins。
另外設定 `gateway.publicOrigin=https://HOST_MAGICDNS_NAME`，讓 App 配對使用 Serve 的 WSS 入口，
避免容器只偵測到 loopback 而無法產生可連線的地址：

```bash
./openclaw config set gateway.publicOrigin https://HOST_MAGICDNS_NAME
```

手機需連上同一 tailnet；需要 App 配對碼時由使用者執行 `./openclaw qr`，不要分享輸出的碼。
Docker 轉送後，Serve 的來源通常是 Compose 網路的 Host bridge IP。
用 `docker network inspect openclaw_default` 與 Gateway 日誌核對實際來源，
將該單一 IP 加入 `gateway.trustedProxies`；不信任整個 Docker 子網，也不改成免登入。
若 UI 回覆 `proxy_attribution_required`，優先檢查此設定與代理 forwarded headers。
重建 Docker 網路後需重新核對 bridge IP。Tailscale Serve 會以實際連線來源覆寫 `X-Forwarded-For`。
Serve 由 Host 管理，容器內不啟用 Tailscale 自動設定，也不掛 tailscaled socket。
連線端登入 tailnet 後，開啟 Serve 輸出的 `https://HOST_MAGICDNS_NAME/`；不需本機 SSH tunnel。
UI 仍需 token 與裝置配對；Tailscale 連線不代表自動登入 OpenClaw。

在 Host 取得含 token 的 Dashboard URL：

```bash
bash services/openclaw/dashboard.sh
```

腳本從 `dashboard --json` 取出含 token 的 URL，換成 Host 的 Tailscale HTTPS 網址。
此版本單獨使用 `dashboard --no-open` 只印不含 token 的網址。
完整網址含憑證，不要分享。新瀏覽器若要求配對，先用 `devices list` 核對裝置，再用 `devices approve REQUEST_ID` 批准。
登入憑證、token、工作區都留在服務資料目錄，不放入 Git。
OpenRouter 可在 Control UI 的 Settings → Models → Connect 登入，再設定模型與 fallback。

GUI Guest 安裝同版本 OpenClaw Node，以 `desktop-exec` 帶入桌面環境。
Guest Node 使用 `--host HOST_MAGICDNS_NAME --port 443 --tls` 連 Host Serve，需兩端 Tailscale 在線。
實際端點保存在 Guest 本機啟動腳本，不放入版控。
原 `openclaw-gui-tunnel` 已停用；Docker bridge 列入 trustedProxies 後，
不使用缺少 forwarded headers 的 SSH tunnel，避免 `proxy_attribution_required`。
Guest 的 `openclaw-node` 與 `openclaw-browser` 均為使用者服務。
Chromium profile 在 `~/snap/chromium/common/openclaw-profile`，CDP 僅 localhost:18800；
OpenClaw 使用 attach-only，保留 Chromium sandbox。

Gateway 設定 `tools.exec.host=node`，瀏覽器固定指向已配對 GUI Node。
Node 斷線時應先恢復連線，不改成在 Host 執行。
不要重啟 `agent-desktop` 來更新 Node；重啟桌面會關閉應用程式。

```bash
# Host
tailscale serve status
./openclaw nodes status
# Guest
systemctl --user status openclaw-node openclaw-browser
```

更新映像前備份服務資料，Gateway 與 Node 版本一起核對。
OpenRouter 備選需另行設定登入憑證與明確模型；未設定前不宣稱有自動 fallback。


## 新 Host：首次部署

以下是重建本次部署的步驟，不是已存在服務的升級腳本。新機需重新登入、產生 token 與配對。
僅更換手機／筆電時，安裝並登入 Tailscale，再完成 UI／App 配對即可，不需重建 Host。

本次版本：OpenClaw `2026.10.9`（Host 映像與 Guest npm 套件一致）、Guest Node.js `24.22.2`。
日後升級先核對官方文件與相容性，不直接把版本換成 latest。

1. **Host**：依 [Docker Ubuntu 安裝文件](https://docs.docker.com/engine/install/ubuntu/) 安裝 Engine 與 Compose plugin；依 [Tailscale Linux 文件](https://tailscale.com/download/linux) 安裝 Tailscale。Host 需有 Python 3、curl、SSH，VM 前置環境見 repo 根 README。
2. **Host，由使用者執行 sudo**：啟用服務並加入 Docker 群組，再重新登入 SSH。Docker 群組具 Host root 等級控制能力；服務容器本身仍使用獨立非 root 帳號。

```bash
sudo systemctl enable --now docker tailscaled
sudo usermod -aG docker "$USER"
sudo tailscale up
```

登入同一 tailnet，確認 MagicDNS 與 ACL/grants 允許用戶端及 Guest 存取 Host TCP 443。
本方案不使用 rootless Docker，不需安裝 uidmap 或為 Host 使用者啟用 linger。

3. **Host，由使用者執行 sudo**：僅限全新帳號／目錄。若已存在，先檢查用途與權限，不覆寫或遞迴 chown。

```bash
sudo useradd --system --user-group --home-dir /var/lib/openclaw \
  --no-create-home --shell /usr/sbin/nologin openclaw
sudo install -d -o openclaw -g openclaw -m 0700 \
  /var/lib/openclaw /var/lib/openclaw/state /var/lib/openclaw/auth
```

4. **Host repo 根目錄**：建置含 gh 的固定版本映像，以服務 UID 建立初始設定；隨機 token 只寫入私有檔案，不輸出。已有設定時此命令會拒絕覆寫。

```bash
bash services/openclaw/compose.sh build --pull gateway
bash services/openclaw/compose.sh run --rm -T --no-deps --entrypoint node gateway - <<'JS'
const fs = require('fs'), crypto = require('crypto');
const config = {
  gateway: {
    mode: 'local',
    auth: {mode: 'token', token: crypto.randomBytes(32).toString('hex')},
    controlUi: {allowedOrigins: ['http://127.0.0.1:18789', 'http://localhost:18789']}
  },
  agents: {defaults: {model: {primary: 'openai/gpt-6-astra'}}},
  tools: {exec: {host: 'node'}}
};
fs.writeFileSync('/home/node/.openclaw/openclaw.json',
  JSON.stringify(config, null, 2), {mode: 0o600, flag: 'wx'});
JS
bash services/openclaw/compose.sh run --rm --no-deps --entrypoint node gateway dist/index.js config validate
bash services/openclaw/compose.sh up -d
```

5. **Host**：等 Gateway 啟動，再登入 OpenAI 訂閱、設定入口。將範例 DNS 換成 `tailscale status --json` 中 Host 的 `Self.DNSName`（去掉結尾句點）。

```bash
./openclaw models auth login --provider openai --device-code
./openclaw config set gateway.publicOrigin https://HOST_MAGICDNS_NAME
./openclaw config set gateway.controlUi.allowedOrigins \
  '["http://127.0.0.1:18789","http://localhost:18789","https://HOST_MAGICDNS_NAME"]'
docker network inspect openclaw_default --format '{{json .IPAM.Config}}'
```

核對 Docker 網路的 Gateway IP 與代理來源後，將下列佔位符換成該單一 IP：

```bash
./openclaw config set gateway.trustedProxies '["DOCKER_BRIDGE_IP"]'
```

按前面的 Serve 步驟啟用 HTTPS（第一次可能需要 tailnet 管理員授權）。
不要在容器內執行 Tailscale Serve，也不要把 Tailscale socket 掛進容器。
再執行 `bash services/openclaw/dashboard.sh` 取得登入網址，在自己的瀏覽器完成裝置配對。
OpenRouter 由 Control UI 設定；只有登入並設定 fallback 模型後才有備援。

## 新 GUI Guest

先依根 README 建立 GUI VM，確認 cloud-init 成功、`verify-desktop` 通過，再登入 Guest Tailscale。
以下命令以 Guest 的一般桌面帳號執行，不用 root。GUI provisioning 已啟用該帳號 linger。

**Guest：安裝固定版本 Node.js 與 OpenClaw。**

```bash
mkdir -p ~/.local/opt ~/.cache/openclaw-install
cd ~/.cache/openclaw-install
curl -fLO https://nodejs.org/dist/v24.22.2/node-v24.22.2-linux-x64.tar.xz
printf '%s\n' '48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75  node-v24.22.2-linux-x64.tar.xz' | sha256sum -c -
# 只有校驗成功才解壓、安裝。
tar -xJf node-v24.22.2-linux-x64.tar.xz -C ~/.local/opt
export PATH="$HOME/.local/opt/node-v24.22.2-linux-x64/bin:$PATH"
npm install --prefix "$HOME/.local/opt/openclaw" openclaw@2026.10.9
```

**Host repo 根目錄：傳送 Node 連線憑證。** 先確認 SSH 目的地和 host key；換掉 `agent@GUEST_ADDRESS`。
這段以 SSH 加密傳送，不將 token 顯示在終端或命令列參數中。Host 只需一般 SSH 權限。

```bash
set -o pipefail
bash services/openclaw/compose.sh exec -T gateway node -e \
  'process.stdout.write(JSON.parse(require("fs").readFileSync("/home/node/.openclaw/openclaw.json")).gateway.auth.token)' |
  ssh agent@GUEST_ADDRESS 'umask 077; mkdir -p ~/.config/openclaw; cat > ~/.config/openclaw/gateway-token'
```

**Guest：建立 Node 啟動腳本。** 寫入前將 `HOST_MAGICDNS_NAME` 換成 Host 的完整 Tailscale DNS 名稱。

```bash
mkdir -p ~/.local/bin ~/.config/systemd/user
cat > ~/.local/bin/openclaw-node-start <<'EOF'
#!/bin/bash
set -euo pipefail
export PATH="$HOME/.local/opt/node-v24.22.2-linux-x64/bin:$PATH"
export OPENCLAW_GATEWAY_TOKEN
OPENCLAW_GATEWAY_TOKEN=$(cat "$HOME/.config/openclaw/gateway-token")
exec desktop-exec node "$HOME/.local/opt/openclaw/node_modules/openclaw/openclaw.mjs" \
  node run --host HOST_MAGICDNS_NAME --port 443 --tls --display-name desktop-01
EOF
chmod 700 ~/.local/bin/openclaw-node-start
cat > ~/.config/systemd/user/openclaw-node.service <<'EOF'
[Unit]
Description=OpenClaw GUI node
After=agent-desktop.service
[Service]
ExecStart=%h/.local/bin/openclaw-node-start
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
EOF
```

**Guest：建立共用桌面的專用瀏覽器。** Snap 不可寫任意隱藏目錄，profile 放在 Snap 的 common 目錄。

```bash
mkdir -p ~/snap/chromium/common/openclaw-profile
cat > ~/.config/systemd/user/openclaw-browser.service <<'EOF'
[Unit]
Description=OpenClaw shared desktop browser
After=agent-desktop.service
[Service]
ExecStart=/usr/local/bin/desktop-exec /snap/bin/chromium --remote-debugging-address=127.0.0.1 --remote-debugging-port=18800 --user-data-dir=%h/snap/chromium/common/openclaw-profile --no-first-run about:blank
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
EOF
export PATH="$HOME/.local/opt/node-v24.22.2-linux-x64/bin:$PATH"
cli="$HOME/.local/opt/openclaw/node_modules/openclaw/openclaw.mjs"
node "$cli" config set browser.executablePath /snap/bin/chromium
node "$cli" config set browser.headless false
node "$cli" config set browser.noSandbox false
node "$cli" config set browser.attachOnly true
systemctl --user daemon-reload
systemctl --user enable --now openclaw-browser openclaw-node
```

**Host：核對並批准新 Node，固定路由。** 裝置配對與 Node 能力批准是兩個步驟，Request ID 以當次查詢為準。

```bash
./openclaw devices list
./openclaw devices approve DEVICE_REQUEST_ID
./openclaw nodes pending
./openclaw nodes approve NODE_REQUEST_ID
./openclaw config set tools.exec.host node
./openclaw config set gateway.nodes.browser.mode manual
./openclaw config set gateway.nodes.browser.node desktop-01
./openclaw nodes status
```

## 驗收、開機與搬機

**Host**：分別檢查容器、HTTPS、Node 與瀏覽器，最後從聊天請模型在 Node 執行 `hostname`、`printenv DISPLAY`，核對工具執行記錄。

```bash
bash services/openclaw/compose.sh ps
curl -fsS https://HOST_MAGICDNS_NAME/healthz
./openclaw nodes status
./openclaw browser open https://example.com
./openclaw browser snapshot --limit 10
./openclaw models status
```

**Guest**：`systemctl --user status agent-desktop openclaw-node openclaw-browser`。
Node／瀏覽器可單獨重啟；重啟 `agent-desktop` 會關閉桌面應用程式。

| 元件 | 開機恢復方式 |
| --- | --- |
| Host Docker／Tailscale | 系統服務 enable |
| Gateway | Compose `restart: unless-stopped`；手動停止後需自行啟動 |
| Serve | `--bg` 保存路由，由 tailscaled 恢復 |
| Guest VM | provisioning 設定 libvirt autostart |
| Guest 桌面／Node／瀏覽器 | systemd user service enable + Guest linger |

本次已驗證：Gateway 非 root UID、HTTPS 健康、OpenAI 訂閱模型回覆、`node_exec` 在 Guest 的 `:1` 桌面環境執行、遠端瀏覽器開頁與讀取。
開機恢復設定已建立，但尚未做 Host 整機重開機驗收。OpenRouter 由使用者在介面設定，未驗證自動 fallback；App 配對入口已驗證為 WSS，手機端完成狀態需自行確認。

clone repo 不會帶回帳號、`/var/lib/openclaw`、Guest user service、Tailscale 登入／Serve 或裝置配對。
重建可重新登入配對；搬遷則需在停止相關服務後，安全備份及還原 Host 的完整 `/var/lib/openclaw` 與 Guest 的 `~/.openclaw`、`~/.config/openclaw`、啟動腳本／units、瀏覽器 profile。
新 Host 專用帳號的 UID/GID 可能不同，還原時由使用者核對擁有者；不要把私有資料提交 Git。
Gateway token 輪替後需安全更新 Guest 的 gateway-token 並重啟 Node；一次性 bootstrap token 與已配對裝置 token 是不同憑證，不能假設一起失效。
