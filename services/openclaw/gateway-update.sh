#!/usr/bin/env bash
# Host：建置並套用 repo 固定版本，會短暫重啟 Gateway。
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo '建置 Gateway 映像；套用時會短暫重啟 Gateway。'
bash "$script_dir/compose.sh" build --pull gateway
bash "$script_dir/compose.sh" up -d --no-deps gateway
bash "$script_dir/compose.sh" exec -T gateway gh --version
