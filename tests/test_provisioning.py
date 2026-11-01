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
        for args, profile, size in [((), 'server', 20), (('--profile', 'gui'), 'gui', 120),
                                    (('--size-gib', '40'), 'server', 40)]:
            result = self.create(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'profile: {profile} | user: agent | disk: {size} GiB', result.stdout)
            self.assertIn('No VM, network, or disk changes made', result.stdout)

    def test_invalid_inputs(self):
        for args in [('--profile', 'invalid'), ('--size-gib', '0'), ('--username', 'root'), ('--xml',)]:
            self.assertNotEqual(self.create(*args).returncode, 0)
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
        for profile, cpu, memory in [('server', 2, 8192), ('gui', 8, 16384)]:
            output = self.path / profile
            self.run_cmd('python3', 'provisioning/scripts/render.py', '--profile', profile,
                         '--name', 'test-vm', '--username', 'agent', '--ssh-key', str(self.keyfile),
                         '--password-hash', str(hashfile), '--user-data',
                         f'provisioning/templates/{profile}-user-data.yaml', '--xml',
                         f'provisioning/templates/{profile}-domain.xml', '--disk',
                         '/var/lib/libvirt/images/test-vm/root.qcow2', '--seed',
                         '/var/lib/libvirt/images/test-vm/seed.iso', '--output', str(output))
            config = yaml.safe_load((output / 'user-data').read_text())
            self.assertEqual(config['users'][0]['ssh_authorized_keys'], self.keys)
            self.assertFalse(config['ssh_pwauth'])
            self.assertEqual('xfce4' in config['packages'], profile == 'gui')
            self.assertEqual('agent-desktop.service' in config['runcmd'][0], profile == 'gui')
            self.assertIn('enable --now tailscaled', config['runcmd'][0])
            self.assertNotIn('tailscale up', config['runcmd'][0])
            self.run_cmd('sh', '-n', input=config['runcmd'][0])
            self.run_cmd('cloud-init', 'schema', '--config-file', str(output / 'user-data'))
            tree = ET.parse(output / 'domain.xml')
            self.assertEqual(int(tree.findtext('vcpu')), cpu)
            self.assertEqual(int(tree.findtext('memory')), memory)
            self.assertEqual(tree.find('os/loader').get('type'), 'pflash')
            self.run_cmd('virt-xml-validate', str(output / 'domain.xml'), 'domain')


if __name__ == '__main__':
    unittest.main()
