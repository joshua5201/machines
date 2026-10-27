#!/bin/bash
set -euo pipefail
umask 077
root=$(cd -- "$(dirname -- "$0")" && pwd)
usage() {
  echo "Usage: $0 --name NAME --username USER --ssh-key FILE --password-hash FILE --base-image FILE --vm-dir /var/lib/libvirt/images/NAME [--size-gib 120] [--xml FILE] [--user-data FILE]"
}
xml=$root/templates/domain.xml
userdata=$root/templates/user-data.yaml
size=120
while (($#)); do
  [[ $# -ge 2 ]] || { usage; exit 2; }
  case $1 in
    --name) name=$2;; --username) username=$2;; --ssh-key) key=$2;;
    --password-hash) hash=$2;; --base-image) base=$2;; --vm-dir) dir=$2;;
    --size-gib) size=$2;; --xml) xml=$2;; --user-data) userdata=$2;;
    *) usage; exit 2;;
  esac
  shift 2
done
: "${name:?}" "${username:?}" "${key:?}" "${hash:?}" "${base:?}" "${dir:?}"
[[ $EUID == 0 ]] || { echo 'Run create-vm.sh with sudo (download remains unprivileged).' >&2; exit 1; }
[[ $name =~ ^[a-z][a-z0-9-]{0,62}$ && $size =~ ^[1-9][0-9]*$ ]] || exit 1
# Keep QEMU storage in the standard AppArmor-supported hierarchy.
[[ $dir == /var/lib/libvirt/images/"$name" ]] || { echo 'VM directory must be /var/lib/libvirt/images/NAME' >&2; exit 1; }
for cmd in virsh qemu-img cloud-localds python3 ssh-keygen flock; do command -v "$cmd" >/dev/null; done
python3 -c 'import yaml'
[[ -c /dev/kvm && -r /usr/share/OVMF/OVMF_CODE_4M.fd ]] || exit 1
for file in "$base" "$key" "$hash" "$xml" "$userdata"; do [[ -r $file ]] || { echo "Cannot read $file" >&2; exit 1; }; done
ssh-keygen -lf "$key" >/dev/null
base=$(realpath "$base")
# Require the checksum manifest retained by download-image.sh.
manifest=$(dirname "$base")/SHA256SUMS
expected=$(awk -v f="$(basename "$base")" '$2 == "*"f || $2 == f {print $1}' "$manifest")
[[ $expected =~ ^[a-f0-9]{64}$ ]] || { echo 'No unique checksum for base image' >&2; exit 1; }
printf '%s  %s\n' "$expected" "$base" | sha256sum -c -
exec 9>/run/lock/agent-vm-provision.lock
flock -n 9 || { echo 'Another provisioning operation is running' >&2; exit 1; }
v=(virsh -c qemu:///system)
"${v[@]}" list --all >/dev/null
if "${v[@]}" dominfo "$name" >/dev/null 2>&1; then echo 'Domain already exists' >&2; exit 1; fi
[[ ! -e $dir && ! -L $dir ]] || { echo 'VM path already exists' >&2; exit 1; }
network=$("${v[@]}" net-dumpxml default)
python3 -c 'import sys,xml.etree.ElementTree as E; n=E.fromstring(sys.argv[1]); assert n.find("forward").get("mode")=="nat"' "$network"
if ! "${v[@]}" net-list --name | grep -Fxq default; then "${v[@]}" net-start default; fi
"${v[@]}" net-autostart default
mkdir -m 0711 "$dir"
trap 'echo "Provisioning stopped. Artifacts retained at $dir; inspect before retrying. No existing VM is deleted." >&2' ERR
python3 "$root/scripts/render.py" --name "$name" --username "$username" \
  --ssh-key "$key" --password-hash "$hash" --user-data "$userdata" --xml "$xml" \
  --disk "$dir/root.qcow2" --seed "$dir/seed.iso" --output "$dir/config"
"$root/create-disk.sh" "$base" "$dir/root.qcow2" "$size"
cloud-localds "$dir/seed.iso" "$dir/config/user-data" "$dir/config/meta-data"
chown libvirt-qemu:kvm "$dir/root.qcow2" "$dir/seed.iso"
chmod 0600 "$dir/root.qcow2" "$dir/seed.iso"
"${v[@]}" define --validate "$dir/config/domain.xml"
"${v[@]}" autostart "$name"
"${v[@]}" start "$name"
"${v[@]}" dominfo "$name"
echo 'Waiting up to 120 seconds for a DHCP address (cloud-init takes longer)...'
ip=''
for _ in {1..24}; do
  ip=$("${v[@]}" domifaddr "$name" --source lease | awk '$3=="ipv4" {sub(/\/.*/, "", $4); print $4; exit}')
  [[ -z $ip ]] || break
  sleep 5
done
if [[ -n $ip ]]; then
  echo "ssh $username@$ip"
  echo "ssh -N -L 5901:127.0.0.1:5901 $username@$ip"
  echo 'In guest: sudo cloud-init status --wait; desktop-exec xdpyinfo'
else
  echo "No lease yet. Inspect: virsh -c qemu:///system console $name"
fi
