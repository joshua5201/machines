#!/usr/bin/python3
import argparse
import pathlib
import re
import shlex
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET
import yaml

p = argparse.ArgumentParser()
p.add_argument('--profile', choices=('gui', 'server'), default='gui')
for key in ('name', 'username', 'ssh-key', 'password-hash', 'user-data', 'xml', 'disk', 'seed', 'output'):
    p.add_argument('--' + key, required=True)
a = p.parse_args()
if not re.fullmatch(r'[a-z][a-z0-9-]{0,62}', a.name):
    p.error('name must be a lowercase hostname')
if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,30}', a.username) or a.username == 'root':
    p.error('invalid non-root username')
# Preserve authorized_keys options and comments on each actual key line.
# Validate independently so one valid key cannot hide a malformed second entry.
keys = []
for number, line in enumerate(pathlib.Path(a.ssh_key).read_text().splitlines(), 1):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    with tempfile.NamedTemporaryFile(mode='w') as candidate:
        candidate.write(line + '\n')
        candidate.flush()
        result = subprocess.run(['ssh-keygen', '-lf', candidate.name],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        p.error(f'invalid authorized_keys entry at line {number}')
    if line not in keys:
        keys.append(line)
if not keys:
    p.error('SSH public key file contains no keys')
password_hash = pathlib.Path(a.password_hash).read_text().strip()
if not re.fullmatch(r'\$(?:6|y)\$[^\s:]+', password_hash):
    p.error('provide a SHA-512 crypt or yescrypt hash')
config = yaml.safe_load(pathlib.Path(a.user_data).read_text())
config['users'] = [dict(name=a.username, shell='/bin/bash', groups=['sudo'],
    sudo=['ALL=(ALL) NOPASSWD:ALL'], lock_passwd=False, passwd=password_hash,
    ssh_authorized_keys=keys)]
config['chpasswd'] = {'expire': False}
guest = pathlib.Path(__file__).resolve().parents[1] / 'guest'
desktop_files = (
    ('agent-desktop', '/usr/local/bin/agent-desktop', '0755'),
    ('desktop-exec', '/usr/local/bin/desktop-exec', '0755'),
    ('verify-desktop', '/usr/local/bin/verify-desktop', '0755'),
    ('agent-desktop.service', '/etc/systemd/user/agent-desktop.service', '0644'))
for name, dest, mode in desktop_files if a.profile == 'gui' else ():
    config.setdefault('write_files', []).append(dict(path=dest, permissions=mode,
        content=(guest / name).read_text()))
desktop_commands = [
    ['systemctl', '--global', 'enable', 'agent-desktop.service'],
    ['loginctl', 'enable-linger', a.username],
    ['bash', '-ec', 'uid=$(id -u "$1"); systemctl start "user@$uid.service"; runuser -u "$1" -- env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" systemctl --user start agent-desktop.service', '--', a.username],
    ['snap', 'wait', 'system', 'seed.loaded'],
    ['snap', 'install', 'chromium'],
]
config.setdefault('runcmd', []).extend(desktop_commands if a.profile == 'gui' else [])
# Fail cloud-final on any setup failure, rather than masking an earlier command.
config['runcmd'] = ['set -eu\n' + '\n'.join(
    shlex.join(str(x) for x in command) if isinstance(command, list) else command
    for command in config['runcmd'])]
xml = pathlib.Path(a.xml).read_text()
from xml.sax.saxutils import escape
for key, value in {'NAME': a.name, 'DISK': a.disk, 'SEED': a.seed}.items():
    xml = xml.replace('__' + key + '__', escape(value, {'"': '&quot;', "'": '&apos;'}))
if re.search(r'__[A-Z_]+__', xml):
    p.error('unresolved XML placeholder')
ET.fromstring(xml)
out = pathlib.Path(a.output)
out.mkdir(mode=0o700, parents=True, exist_ok=True)
for name, content in {
    'user-data': '#cloud-config\n' + yaml.safe_dump(config, sort_keys=False),
    'meta-data': yaml.safe_dump({'instance-id': str(uuid.uuid4()), 'local-hostname': a.name}),
    'domain.xml': xml,
}.items():
    with (out / name).open('x') as f:
        f.write(content)
    (out / name).chmod(0o600)
