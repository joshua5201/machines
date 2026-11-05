"""Local checks only: temporary images/configs, no sudo or libvirt mutations."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

import yaml

ROOT = Path(__file__).resolve().parents[1]


class ProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.run_cmd('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.path / 'key'))
        public_key = (self.path / 'key.pub').read_text().strip()
        self.keys = [public_key, 'restrict,command="echo test" ' + public_key]
        self.keyfile = self.path / 'authorized_keys'
        self.keyfile.write_text('# keys\n\n' + '\n'.join(self.keys + [public_key]) + '\n')
        self.base = self.path / 'base.img'
        self.run_cmd('qemu-img', 'create', '-f', 'qcow2', str(self.base), '64M')
        digest = hashlib.sha256(self.base.read_bytes()).hexdigest()
        (self.path / 'SHA256SUMS').write_text(digest + ' *base.img\n')

    def run_cmd(self, *args, check=True, **kwargs):
        return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=check, **kwargs)

    def create(self, *args):
        return self.run_cmd(str(ROOT / 'provisioning/create-vm.sh'), 'test-vm',
                            '--base-image', str(self.base), '--ssh-key', str(self.keyfile),
                            '--dry-run', *args, check=False)

    def test_defaults_and_profiles(self):
        for args, profile, size in [((), 'server', 80), (('--profile', 'gui'), 'gui', 120),
                                    (('--cpu', '4', '--ram', '12'), 'server', 80),
                                    (('--profile', 'gui', '--cpu', '4', '--ram', '12'), 'gui', 120),
                                    (('--no-sudo', '--cpu', '4', '--ram', '12'), 'server', 80),
                                    (('--profile', 'gui', '--no-sudo'), 'gui', 120),
                                    (('--size-gib', '40'), 'server', 40)]:
            result = self.create(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'profile: {profile} | user: agent | disk: {size} GiB', result.stdout)
            self.assertIn('No VM, network, or disk changes made', result.stdout)
            self.assertEqual('Guest sudo: disabled' in result.stdout, '--no-sudo' in args)

    def test_invalid_inputs(self):
        for args in [('--profile', 'invalid'), ('--size-gib', '0'), ('--username', 'root'), ('--xml',)]:
            self.assertNotEqual(self.create(*args).returncode, 0)
        for flag in ('--cpu', '--ram'):
            for value in ('0', '-1', '1.5', 'abc', '', '1000000'):
                result = self.create(flag, value)
                self.assertNotEqual(result.returncode, 0, (flag, value))
                self.assertIn('positive integer', result.stderr)
            self.assertIn('Missing value', self.create(flag).stderr)
        self.keyfile.write_text('# empty\n')
        self.assertNotEqual(self.create().returncode, 0)
        self.keyfile.write_text(self.keys[0] + '\ninvalid-key\n')
        self.assertNotEqual(self.create().returncode, 0)

    def test_checksum_failure(self):
        with self.base.open('ab') as f:
            f.write(b'changed')
        result = self.create()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Configuration validated', result.stdout)

    def test_rendered_profiles(self):
        password = self.run_cmd('openssl', 'passwd', '-6', '-stdin', input='test-only\n').stdout
        hashfile = self.path / 'password.hash'
        hashfile.write_text(password)
        cases = []
        for profile, cpu, memory in [('server', 2, 8192), ('gui', 8, 16384)]:
            cases.extend([(profile, cpu, memory, ()),
                          (profile, 4, memory, ('--cpu', '4')),
                          (profile, cpu, 12288, ('--ram', '12')),
                          (profile, 4, 12288, ('--cpu', '4', '--ram', '12')),
                          (profile, 4, 12288, ('--cpu', '4', '--ram', '12', '--no-sudo'))])
        for index, (profile, cpu, memory, overrides) in enumerate(cases):
            output = self.path / f'{profile}-{index}'
            self.run_cmd('python3', 'provisioning/scripts/render.py', '--profile', profile,
                         '--name', 'test-vm', '--username', 'builder', '--ssh-key', str(self.keyfile),
                         '--password-hash', str(hashfile), '--user-data',
                         f'provisioning/templates/{profile}-user-data.yaml', '--xml',
                         f'provisioning/templates/{profile}-domain.xml', '--disk',
                         '/var/lib/libvirt/images/test-vm/root.qcow2', '--seed',
                         '/var/lib/libvirt/images/test-vm/seed.iso', '--output', str(output),
                         *overrides)
            config = yaml.safe_load((output / 'user-data').read_text())
            self.assertEqual(config['users'][0]['ssh_authorized_keys'], self.keys)
            self.assertFalse(config['ssh_pwauth'])
            self.assertEqual('xfce4' in config['packages'], profile == 'gui')
            self.assertEqual('agent-desktop.service' in config['runcmd'][0], profile == 'gui')
            self.assertIn('enable --now tailscaled', config['runcmd'][0])
            self.assertNotIn('tailscale up', config['runcmd'][0])
            user = config['users'][0]
            files = {item['path']: item for item in config['write_files']}
            if '--no-sudo' in overrides:
                self.assertIs(user['sudo'], False)
                self.assertTrue(user['lock_passwd'])
                self.assertEqual(user['groups'], ['kvm', 'plugdev'])
                self.assertTrue({'kvm', 'plugdev'} <= set(config['groups']))
                self.assertNotIn('NOPASSWD', (output / 'user-data').read_text())
                deny = files['/etc/sudoers.d/99-agent-no-sudo']
                self.assertEqual(deny['permissions'], '0440')
                self.assertEqual(deny['content'], 'builder ALL=(ALL:ALL) !ALL\n')
                self.assertIn('MODE="0660"', files['/etc/udev/rules.d/99-agent-kvm.rules']['content'])
                self.assertIn('android-sdk-platform-tools-common', config['packages'])
                self.assertIn('dbus-user-session', config['packages'])
                self.assertIn('modprobe kvm_amd', config['runcmd'][0])
                self.assertIn('modprobe kvm_intel', config['runcmd'][0])
                self.assertIn('loginctl enable-linger builder', config['runcmd'][0])
                self.assertIn('tailscale set --operator=builder', config['runcmd'][0])
                self.assertLess(config['runcmd'][0].index('enable --now tailscaled'),
                                config['runcmd'][0].index('tailscale set'))
            else:
                self.assertEqual(user['groups'], ['sudo'])
                self.assertEqual(user['sudo'], ['ALL=(ALL) NOPASSWD:ALL'])
                self.assertFalse(user['lock_passwd'])
                self.assertNotIn('/etc/sudoers.d/99-agent-no-sudo', files)
                self.assertNotIn('tailscale set --operator', config['runcmd'][0])
            self.run_cmd('sh', '-n', input=config['runcmd'][0])
            self.run_cmd('cloud-init', 'schema', '--config-file', str(output / 'user-data'))
            tree = ET.parse(output / 'domain.xml')
            self.assertEqual(int(tree.findtext('vcpu')), cpu)
            self.assertEqual(int(tree.findtext('memory')), memory)
            self.assertEqual(int(tree.findtext('currentMemory')), memory)
            self.assertEqual(tree.find('memory').get('unit'), 'MiB')
            self.assertEqual(tree.find('currentMemory').get('unit'), 'MiB')
            self.assertEqual(tree.find('os/loader').get('type'), 'pflash')
            self.run_cmd('virt-xml-validate', str(output / 'domain.xml'), 'domain')

    def test_status_no_sudo_hint(self):
        # Fake read-only libvirt replies; never contact the real daemon.
        virsh = self.path / 'virsh'
        virsh.write_text('#!/bin/sh\ncase "$3" in\n'
                         'domstate) echo running;;\n'
                         'domifaddr) echo "vnet0 unused ipv4 192.0.2.10/24";;\n'
                         '*) exit 1;;\nesac\n')
        virsh.chmod(0o700)
        env = dict(os.environ, PATH=str(self.path) + os.pathsep + os.environ['PATH'])
        for no_sudo in ('true', 'false'):
            result = self.run_cmd('bash', 'provisioning/vm-status.sh', 'test-vm',
                                  'builder', '0', '', 'server', no_sudo, env=env)
            self.assertEqual('sudo cloud-init' in result.stdout, no_sudo == 'false')
            self.assertEqual('user is Tailscale operator' in result.stdout, no_sudo == 'true')
            self.assertNotIn('VNC', result.stdout)


if __name__ == '__main__':
    unittest.main()
