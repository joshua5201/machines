#!/usr/bin/python3
import argparse
import pathlib
import re
import shlex
import uuid
import xml.etree.ElementTree as ET
import yaml

p = argparse.ArgumentParser()
for key in ('name', 'username', 'ssh-key', 'password-hash', 'user-data', 'xml', 'disk', 'seed', 'output'):
    p.add_argument('--' + key, required=True)
a = p.parse_args()
if not re.fullmatch(r'[a-z][a-z0-9-]{0,62}', a.name):
    p.error('name must be a lowercase hostname')
if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,30}', a.username) or a.username == 'root':
    p.error('invalid non-root username')
key = pathlib.Path(a.ssh_key).read_text().strip()
if '\n' in key or not re.match(r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) \S+', key):
    p.error('provide one OpenSSH public key')
password_hash = pathlib.Path(a.password_hash).read_text().strip()
if not re.fullmatch(r'\$(?:6|y)\$[^\s:]+', password_hash):
    p.error('provide a SHA-512 crypt or yescrypt hash')
config = yaml.safe_load(pathlib.Path(a.user_data).read_text())
config['users'] = [dict(name=a.username, shell='/bin/bash', groups=['sudo'],
    sudo=['ALL=(ALL) NOPASSWD:ALL'], lock_passwd=False, passwd=password_hash,
    ssh_authorized_keys=[key])]
config['chpasswd'] = {'expire': False}
guest = pathlib.Path(__file__).resolve().parents[1] / 'guest'
for name, dest, mode in (
    ('agent-desktop', '/usr/local/bin/agent-desktop', '0755'),
    ('desktop-exec', '/usr/local/bin/desktop-exec', '0755'),
    ('verify-desktop', '/usr/local/bin/verify-desktop', '0755'),
    ('agent-desktop.service', '/etc/systemd/user/agent-desktop.service', '0644')):
    config.setdefault('write_files', []).append(dict(path=dest, permissions=mode,
        content=(guest / name).read_text()))
config.setdefault('runcmd', []).extend([
    ['systemctl', '--global', 'enable', 'agent-desktop.service'],
    ['loginctl', 'enable-linger', a.username],
    ['bash', '-ec', 'uid=$(id -u "$1"); systemctl start "user@$uid.service"; runuser -u "$1" -- env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" systemctl --user start agent-desktop.service', '--', a.username],
])
config['runcmd'].extend([['snap', 'wait', 'system', 'seed.loaded'], ['snap', 'install', 'chromium']])
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
