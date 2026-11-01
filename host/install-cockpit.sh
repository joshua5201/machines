#!/bin/bash
# Install the Host web console. Explicit private IPv4 listeners only.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo "Usage: sudo $0 LAN_IPV4 [TAILSCALE_IPV4]" >&2; exit 1; }
(($# >= 1 && $# <= 2)) || { echo "Usage: sudo $0 LAN_IPV4 [TAILSCALE_IPV4]" >&2; exit 2; }
python3 - "$@" <<'PY'
import ipaddress,json,subprocess,sys
allowed=[ipaddress.ip_network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','100.64.0.0/10')]
local={a['local'] for i in json.loads(subprocess.check_output(['ip','-j','-4','address'])) for a in i.get('addr_info',[])}
for value in sys.argv[1:]:
    addr=ipaddress.IPv4Address(value)
    if not any(addr in n for n in allowed) or value not in local:
        raise SystemExit('Use a private IPv4 address currently assigned to this Host: '+value)
PY
config=/etc/systemd/system/cockpit.socket.d/90-private-listen.conf
stage='configure private listeners'
trap 'result=$?; echo "Cockpit setup failed at: $stage (exit $result). Inspect the error before retrying." >&2; exit "$result"' ERR
mkdir -p /etc/systemd/system/cockpit.socket.d
if [[ -e $config ]]; then
  cp -a "$config" "${config}.backup.$(date +%s)"
fi
# Write before installation so package activation never uses the wildcard default.
{
  echo '[Socket]'
  echo 'ListenStream='
  for address in "$@"; do printf 'ListenStream=%s:9090\n' "$address"; done
  echo 'FreeBind=yes'
} > "$config"
systemctl daemon-reload
stage='install Cockpit and VM management'
apt-get update
apt-get install -y --no-install-recommends cockpit cockpit-machines
stage='activate Cockpit socket'
systemctl daemon-reload
systemctl enable cockpit.socket
systemctl restart cockpit.socket
systemctl is-active cockpit.socket
systemctl show cockpit.socket -p Listen
for address in "$@"; do printf 'Open: https://%s:9090\n' "$address"; done
echo 'Log in with your Host Linux account. Open Virtual Machines to manage system libvirt VMs.'
