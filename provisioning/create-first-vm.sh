#!/bin/bash
set -euo pipefail
project=$(cd -- "$(dirname -- "$0")/.." && pwd)
exec "$project/provisioning/create-vm.sh" \
  --name gui-agent-01 \
  --username agent \
  --ssh-key "$project/credentials/gui-agent-01/id_ed25519.pub" \
  --password-hash "$project/credentials/gui-agent-01/password.hash" \
  --base-image "$project/cache/resolute-server-cloudimg-amd64.img" \
  --vm-dir /var/lib/libvirt/images/gui-agent-01 \
  --size-gib 120
