#!/usr/bin/env bash
# 僅在自己的終端執行；輸出的網址含 Gateway 憑證。
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
bash ../../openclaw dashboard --no-open --json |
  python3 -c '
import json, subprocess, sys
from urllib.parse import urlsplit, urlunsplit
data = json.load(sys.stdin)
if not data.get("ok") or not data.get("tokenIncluded"):
    raise SystemExit("Dashboard 未提供 token URL；請先檢查 Gateway 認證設定。")
status = json.loads(subprocess.check_output(["tailscale", "status", "--json"]))
host = status.get("Self", {}).get("DNSName", "").rstrip(".")
if not host:
    raise SystemExit("找不到 Host Tailscale DNS 名稱。")
url = urlsplit(data["url"])
print(urlunsplit(("https", host, url.path, url.query, url.fragment)))
'
