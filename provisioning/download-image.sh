#!/bin/bash
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 CACHE_DIRECTORY" >&2; exit 2; }
[[ $EUID != 0 ]] || { echo 'Run download as an ordinary user.' >&2; exit 1; }
mkdir -p "$1"
cd "$1"
exec 9>.download.lock
flock -n 9 || { echo 'Download already running' >&2; exit 1; }
base=https://cloud-images.ubuntu.com/resolute/current
file=resolute-server-cloudimg-amd64.img
# Pin manifest on first run, so subsequent runs reuse the verified base.
if [[ ! -f SHA256SUMS ]]; then
  curl -fL --retry 3 "$base/SHA256SUMS" -o SHA256SUMS.part
  mv SHA256SUMS.part SHA256SUMS
fi
line=$(awk -v f="$file" '$2 == "*"f || $2 == f {print}' SHA256SUMS)
[[ $(printf '%s\n' "$line" | wc -l) == 1 && $line =~ ^[a-f0-9]{64}\  ]] || { echo 'Missing/invalid checksum' >&2; exit 1; }
if [[ -f $file ]]; then
  printf '%s\n' "$line" | sha256sum -c -
else
  curl -fL --retry 3 -C - "$base/$file" -o "$file.part"
  expected=${line%% *}
  printf '%s  %s\n' "$expected" "$file.part" | sha256sum -c -
  mv "$file.part" "$file"
fi
chmod 0444 "$file" SHA256SUMS
realpath "$file"
