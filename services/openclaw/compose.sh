#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export OPENCLAW_UID OPENCLAW_GID
OPENCLAW_UID=$(id -u openclaw)
OPENCLAW_GID=$(id -g openclaw)
if [[ "$OPENCLAW_UID" == 0 || "$OPENCLAW_GID" == 0 ]]; then
  echo 'Refusing root service identity' >&2
  exit 1
fi
exec docker compose -f compose.yaml "$@"
