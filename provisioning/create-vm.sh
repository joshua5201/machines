#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C
umask 077
root=$(cd -- "$(dirname -- "$0")" && pwd)
project=$(dirname "$root")
usage() {
  cat <<'HELP'
Usage: sudo ./provisioning/create-vm.sh HOSTNAME [options]

  --profile server|gui   Default: server (2 CPU / 8 GiB / 20 GiB)
                         gui: 8 CPU / 16 GiB / 120 GiB
  --username USER       Default: agent
  --size-gib N          Override disk size
  --ssh-key FILE        Default: invoking Host user's ~/.ssh/authorized_keys
  --password-hash FILE  Default: generate a random password hash; discard plaintext
  --base-image FILE     Default: project cache/resolute-server-cloudimg-amd64.img
  --xml FILE            Override profile's domain XML
  --user-data FILE      Override profile's cloud-init YAML
  --dry-run             Validate/render in temporary storage; no sudo or VM changes
  -h, --help            Show this help

Storage: /var/lib/libvirt/images/HOSTNAME (never overwritten).
Download the base image once as a normal user with download-image.sh.
All profiles use SSH keys only. Tailscale enrollment is manual after first boot.
HELP
}
die() { echo "Error: $*" >&2; exit 1; }
name=''
username=agent
profile=server
key=''
hash=''
xml=''
userdata=''
size=''
dir=''
base=$project/cache/resolute-server-cloudimg-amd64.img
dry_run=false
while (($#)); do
  case $1 in
    -h|--help) usage; exit 0;;
    --dry-run) dry_run=true; shift; continue;;
    --*)
      (($# >= 2)) && [[ $2 != --* ]] || die "Missing value for $1"
      case $1 in
        --name) [[ -z $name ]] || die 'Specify only one hostname'; name=$2;;
        --username) username=$2;; --profile) profile=$2;; --ssh-key) key=$2;;
        --password-hash) hash=$2;; --base-image) base=$2;; --vm-dir) dir=$2;;
        --size-gib) size=$2;; --xml) xml=$2;; --user-data) userdata=$2;;
        *) die "Unknown option: $1";;
      esac
      shift 2;;
    -*) die "Unknown option: $1";;
    *) [[ -z $name ]] || die 'Specify only one hostname'; name=$1; shift;;
  esac
done
[[ $name =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die 'Provide a lowercase hostname (1-63 characters, no trailing hyphen).'
[[ $username =~ ^[a-z_][a-z0-9_-]{0,30}$ && $username != root ]] || die 'Invalid non-root username.'
case $profile in
  server) size=${size:-20};;
  gui) size=${size:-120};;
  *) die 'Profile must be server or gui';;
esac
[[ $size =~ ^[1-9][0-9]{0,5}$ ]] || die 'Disk size must be a positive integer in GiB.'
xml=${xml:-$root/templates/$profile-domain.xml}
userdata=${userdata:-$root/templates/$profile-user-data.yaml}
dir=${dir:-/var/lib/libvirt/images/$name}
[[ $dir == /var/lib/libvirt/images/"$name" ]] || die 'VM directory must be /var/lib/libvirt/images/HOSTNAME.'
$dry_run || [[ $EUID == 0 ]] || die 'Use sudo to create a VM, or --dry-run to validate without changes.'
for cmd in python3 ssh-keygen openssl qemu-img; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
python3 -c 'import yaml'
if [[ -z $key ]]; then
  key=$(python3 - <<'PY'
import os,pwd
print(os.path.join(pwd.getpwuid(int(os.environ.get('SUDO_UID',os.getuid()))).pw_dir,'.ssh','authorized_keys'))
PY
)
fi
if [[ ! -r $base ]]; then
  echo 'Download the image first as your normal user:' >&2
  printf '  %q %q\n' "$root/download-image.sh" "$project/cache" >&2
  die "Cannot read base image: $base"
fi
for file in "$key" "$xml" "$userdata"; do [[ -f $file && -r $file ]] || die "Cannot read $file"; done
[[ -z $hash || -r $hash ]] || die "Cannot read password hash file: $hash"
base=$(realpath "$base")
manifest=$(dirname "$base")/SHA256SUMS
[[ -r $manifest ]] || die "Missing checksum manifest: $manifest"
expected=$(awk -v f="$(basename "$base")" '$2 == "*"f || $2 == f {print $1}' "$manifest")
[[ $expected =~ ^[a-f0-9]{64}$ ]] || die 'No unique checksum for base image.'
printf '%s  %s\n' "$expected" "$base" | sha256sum -c -
qemu-img info --output=json "$base" | python3 -c '
import json,sys
info=json.load(sys.stdin)
if info["format"] != "qcow2" or info.get("backing-filename"):
    raise SystemExit("Base must be an independent qcow2 image")
if int(sys.argv[1])*1024**3 < info["virtual-size"]:
    raise SystemExit("Requested disk is smaller than base image")
' "$size"
stage='validate configuration'
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
failed() {
  result=$?
  echo "Failed during: $stage (exit $result)." >&2
  echo "Any VM artifacts at $dir are retained. Do not recreate/delete the disk blindly." >&2
  echo "Inspect: virsh -c qemu:///system dominfo $name" >&2
  echo 'Logs: journalctl -u libvirtd -n 60 --no-pager' >&2
  echo "If already defined, fix the error and use: virsh -c qemu:///system start $name" >&2
  exit "$result"
}
trap failed ERR
if [[ -z $hash ]]; then
  hash=$work/password.hash
  python3 - "$hash" <<'PY'
import secrets,subprocess,sys
with open(sys.argv[1],'x') as f:
    subprocess.run(['openssl','passwd','-6','-stdin'],input=secrets.token_urlsafe(48)+'\n',
                   text=True,stdout=f,check=True)
PY
fi
python3 "$root/scripts/render.py" --name "$name" --username "$username" \
  --profile "$profile" --ssh-key "$key" --password-hash "$hash" \
  --user-data "$userdata" --xml "$xml" --disk "$dir/root.qcow2" \
  --seed "$dir/seed.iso" --output "$work/config"
# Validate before creating a VM directory or changing libvirt.
if command -v virt-xml-validate >/dev/null; then virt-xml-validate "$work/config/domain.xml" domain; fi
echo "Name: $name | profile: $profile | user: $username | disk: ${size} GiB"
echo "Public keys: $key"
echo "Templates: $xml ; $userdata"
if $dry_run; then
  echo 'Configuration validated. No VM, network, or disk changes made; libvirt state not checked.'
  exit 0
fi
for cmd in virsh cloud-localds flock; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
[[ -c /dev/kvm && -r /usr/share/OVMF/OVMF_CODE_4M.fd && -r /usr/share/OVMF/OVMF_VARS_4M.fd ]] || die 'KVM or OVMF is missing.'
exec 9>/run/lock/agent-vm-provision.lock
flock -n 9 || die 'Another provisioning operation is running.'
v=(virsh -c qemu:///system)
stage='check libvirt and existing resources'
"${v[@]}" list --all >/dev/null
if "${v[@]}" dominfo "$name" >/dev/null 2>&1; then die "Domain $name already exists; use vm-status.sh instead."; fi
[[ ! -e $dir && ! -L $dir ]] || die "VM path already exists: $dir"
network=$("${v[@]}" net-dumpxml default)
python3 -c 'import sys,xml.etree.ElementTree as E; n=E.fromstring(sys.argv[1]); f=n.find("forward"); assert f is not None and f.get("mode")=="nat", "default network must use NAT"' "$network"
stage='enable default NAT'
if ! "${v[@]}" net-list --name | grep -Fxq default; then "${v[@]}" net-start default; fi
"${v[@]}" net-autostart default
stage='create VM storage'
mkdir -m 0711 "$dir"
cp -a "$work/config" "$dir/config"
"$root/create-disk.sh" "$base" "$dir/root.qcow2" "$size"
stage='create NoCloud seed ISO'
cloud-localds "$dir/seed.iso" "$dir/config/user-data" "$dir/config/meta-data"
stage='set QEMU storage permissions'
chown libvirt-qemu:kvm "$dir/root.qcow2" "$dir/seed.iso"
chmod 0600 "$dir/root.qcow2" "$dir/seed.iso"
stage='define domain'
"${v[@]}" define --validate "$dir/config/domain.xml"
stage='enable autostart'
"${v[@]}" autostart "$name"
stage='start domain'
"${v[@]}" start "$name"
"${v[@]}" dominfo "$name"
trap - ERR
login_key=${key%.pub}
[[ $login_key != "$key" && -f $login_key ]] || login_key=''
"$root/vm-status.sh" "$name" "$username" 120 "$login_key" "$profile"
