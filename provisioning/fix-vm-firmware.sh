#!/bin/bash
# Repair only the failed automatic AMD SEV firmware selection; preserve disks/UUID/MAC.
set -Eeuo pipefail
export LC_ALL=C
umask 077
name=${1:-gui-agent-01}
[[ $name =~ ^[a-z][a-z0-9-]{0,62}$ ]] || exit 2
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
v=(virsh -c qemu:///system)
[[ $("${v[@]}" domstate "$name") == 'shut off' ]] || { echo 'VM must be shut off.' >&2; exit 1; }
[[ -r /usr/share/OVMF/OVMF_CODE_4M.fd && -r /usr/share/OVMF/OVMF_VARS_4M.fd ]] || exit 1
stage='backup domain XML'
trap 'result=$?; echo "Firmware repair failed during: $stage. Disk retained; XML backup: ${backup:-not yet created}. Inspect the error before retrying." >&2; exit "$result"' ERR
backup=$(mktemp -d /var/lib/libvirt/images/firmware-fix.XXXXXX)
"${v[@]}" dumpxml "$name" --inactive > "$backup/before.xml"
stage='validate and prepare firmware change'
python3 - "$backup" <<'PY'
import pathlib,sys,xml.etree.ElementTree as ET
p=pathlib.Path(sys.argv[1])
t=ET.parse(p/'before.xml'); os=t.getroot().find('os')
loader=os.find('loader')
if loader is None or loader.text != '/usr/share/ovmf/OVMF.amdsev.fd':
    raise SystemExit('Unexpected firmware; refusing automatic change.')
if os.find('nvram') is not None:
    raise SystemExit('Existing NVRAM found; refusing automatic change.')
os.attrib.pop('firmware',None)
firmware=os.find('firmware')
if firmware is not None: os.remove(firmware)
loader.attrib.clear(); loader.attrib.update(readonly='yes',type='pflash',format='raw')
loader.text='/usr/share/OVMF/OVMF_CODE_4M.fd'
ET.SubElement(os,'nvram',template='/usr/share/OVMF/OVMF_VARS_4M.fd',format='raw')
t.write(p/'after.xml',encoding='unicode')
PY
stage='define corrected domain'
"${v[@]}" define --validate "$backup/after.xml"
echo "Original XML retained: $backup/before.xml"
stage='start corrected domain'
"${v[@]}" start "$name"
trap - ERR
root=$(cd -- "$(dirname -- "$0")" && pwd)
"$root/vm-status.sh" "$name" agent 120
