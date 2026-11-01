#!/bin/bash
# Read-only: never starts/redefines a VM or changes its disk.
set -euo pipefail
export LC_ALL=C
name=${1:-gui-agent-01}
username=${2:-agent}
wait_seconds=${3:-120}
key=${4:-}
profile=${5:-unknown}
[[ $profile == gui || $profile == server || $profile == unknown ]] || { echo "Invalid profile" >&2; exit 2; }
[[ $name =~ ^[a-z][a-z0-9-]{0,62}$ && $username =~ ^[a-z_][a-z0-9_-]{0,30}$ && $wait_seconds =~ ^[0-9]{1,4}$ ]] || {
  echo "Usage: $0 [VM_NAME] [USERNAME] [WAIT_SECONDS:0-9999] [PRIVATE_KEY] [gui|server]" >&2; exit 2;
}
v=(virsh -c qemu:///system)
command -v virsh >/dev/null || { echo 'Missing virsh.' >&2; exit 1; }
echo "Checking $name; waiting up to ${wait_seconds}s for a DHCP lease..."
deadline=$((SECONDS + 10#$wait_seconds))
while true; do
  if ! state=$("${v[@]}" domstate "$name"); then
    echo 'Cannot query domain. Check the VM name and libvirt access.' >&2; exit 1
  fi
  if [[ $state != running ]]; then
    echo "VM state: $state. No disk changes made." >&2
    echo "Inspect: virsh -c qemu:///system dominfo $name" >&2
    echo "If shut off, start the existing VM: virsh -c qemu:///system start $name" >&2
    exit 1
  fi
  if ! addresses=$("${v[@]}" domifaddr "$name" --source lease); then
    echo 'VM is running, but libvirt could not query DHCP leases.' >&2; exit 1
  fi
  ip=$(awk '$3=="ipv4" {sub(/\/.*/, "", $4); print $4; exit}' <<< "$addresses")
  if [[ -n $ip ]]; then break; fi
  if ((SECONDS >= deadline)); then
    echo 'VM is running, but no DHCP IPv4 address was found before timeout.' >&2
    echo 'Do not rerun create-vm.sh or recreate the disk.' >&2
    echo "Retry: $0 $name $username 120" >&2
    echo 'Network: virsh -c qemu:///system net-dhcp-leases default' >&2
    echo "Boot console: virsh -c qemu:///system console $name (exit with Ctrl+])" >&2
    exit 2
  fi
  remaining=$((deadline - SECONDS))
  echo "VM running; waiting for DHCP (${remaining}s remaining)..."
  sleep "$((remaining < 5 ? remaining : 5))"
done
echo "VM running; DHCP IPv4: $ip"
echo 'DHCP does not mean SSH or cloud-init is ready; first boot may take several minutes.'
args=(ssh)
if [[ -n $key ]]; then args+=(-i "$key" -o IdentitiesOnly=yes); fi
printf 'Login: '; printf '%q ' "${args[@]}" "$username@$ip"; printf '\n'
if [[ $profile == gui ]]; then
  printf 'VNC tunnel: '; printf '%q ' "${args[@]}" -N -L 5901:127.0.0.1:5901 "$username@$ip"; printf '\n'
fi
echo 'In guest: sudo cloud-init status --wait --long'
if [[ $profile == gui ]]; then
  echo 'After successful initialization: verify-desktop'
elif [[ $profile == server ]]; then
  echo 'After successful initialization: systemctl is-active qemu-guest-agent; systemctl get-default'
fi
