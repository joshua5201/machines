#!/bin/bash
set -euo pipefail
[[ $# == 3 ]] || { echo "Usage: $0 BASE_IMAGE NEW_DISK SIZE_GIB" >&2; exit 2; }
base=$(realpath "$1")
disk=$2
size=$3
[[ $size =~ ^[1-9][0-9]*$ && -f $base && ! -e $disk && ! -L $disk ]] || exit 1
original=$(qemu-img info --output=json "$base" | python3 -c 'import json,sys; i=json.load(sys.stdin); assert i["format"] == "qcow2"; assert not i.get("backing-filename"); print(i["virtual-size"])')
((size * 1024 * 1024 * 1024 >= original)) || { echo 'Refusing to shrink image' >&2; exit 1; }
# Exclusive reservation prevents accidental replacement, including concurrent runs.
(set -o noclobber; : > "$disk")
trap 'echo "Disk creation failed; reserved/partial disk retained for inspection: $disk" >&2' ERR
qemu-img convert -f qcow2 -O qcow2 "$base" "$disk"
qemu-img resize "$disk" "${size}G"
qemu-img info "$disk"
