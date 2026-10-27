#!/usr/bin/env python3
"""Check deployed guest identity, runtime paths and reuse without compiling Rust."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / 'scripts/lib/python/axvisor-payloads.py'
BOARD = Path('apps/axvisor/normal/board-ballpick-robot')
GUEST = '/guest/axvisor/'


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.source = self.work / 'source'
        self.output = self.work / 'package'
        self.generated = self.work / 'generated'
        self.generated.mkdir()
        self.output.mkdir()
        self.shell = 'kernel-types/arceos/configs/arceos.toml'
        self.single = Path('apps/axvisor/normal/board-orangepi-5-plus/robot-real-starry/guest.toml')
        definition = ('[base]\nid = 1\ncpu_num = 1\n[kernel]\n'
                      'kernel_path = "${workspace}/target/original.bin"\n'
                      'cmdline = "root=/dev/mmcblk0p2 rw"\n'
                      'memory_regions = [[1073741824, 134217728, 7, 0]]\n')
        for path in (self.source / BOARD / self.shell, self.source / self.single,
                     self.output / 'board-ballpick-robot' / self.shell):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(definition)
        for name in ('arceos-vm-shell.bin', 'starry-robot-single.bin'):
            p = self.output / 'guests' / name
            p.parent.mkdir(exist_ok=True)
            p.write_bytes(b'guest-code')
        manifest = {'runtime_guest_configs': [], 'source_dependent_guest_configs': [GUEST + 'board-ballpick-robot/' + self.shell],
                    'scenarios': {}, 'source_dependent_scenarios': {'virtio-net-peer/vcpus/build.toml': [f'target/axvisor-arceos-net-scale/vm{n}.toml' for n in range(1, 65)]}}
        (self.output / 'manifest.json').write_text(json.dumps(manifest))
        for n in range(1, 65):
            (self.generated / f'vm{n}.toml').write_text(
                f'[base]\nid = {n}\nname = "peer-{n}"\ncpu_num = 1\n'
                f'phys_cpu_ids = [{((n - 1) % 8) * 256}]\n'
                '[kernel]\nkernel_path = "/workstation/objects/arceos-virtio-net-peer.bin"\n'
                'memory_regions = [[2147483648, 67108864, 7, 0]]\n'
                f'[[devices.virtual]]\nmodel = "virtio-net"\nguest_mac = [82, 84, 0, 32, 1, {n}]\n')

    def stage(self):
        return subprocess.run(['python3', HELPER, self.source, self.output,
                               '--network-configs', self.generated], capture_output=True, text=True)

    def test_prebuilt_configs_keep_identity_and_share_the_existing_network_binary(self):
        before = {str(p): p.read_bytes() for p in self.source.rglob('*') if p.is_file()}
        result = self.stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        shell = tomllib.loads((self.output / 'board-ballpick-robot' / self.shell).read_text())
        self.assertEqual(shell['kernel']['kernel_path'], GUEST + 'guests/arceos-vm-shell.bin')
        single = tomllib.loads((self.output / 'robot-single/guest.toml').read_text())
        self.assertEqual(single['kernel']['kernel_path'], GUEST + 'guests/starry-robot-single.bin')
        self.assertEqual(single['kernel']['cmdline'], 'root=/dev/mmcblk0p2 rw')
        configs = self.output / 'board-ballpick-robot/virtio-net-peer/vcpus/generated'
        self.assertEqual(len(list(configs.glob('vm*.toml'))), 64)
        for n in range(1, 65):
            actual = tomllib.loads((configs / f'vm{n}.toml').read_text())
            expected = tomllib.loads((self.generated / f'vm{n}.toml').read_text())
            expected['kernel']['kernel_path'] = '/guest/arceos/orangepi-5-plus'
            self.assertEqual(actual, expected)
        manifest = json.loads((self.output / 'manifest.json').read_text())
        self.assertEqual(manifest['source_dependent_guest_configs'], [])
        self.assertEqual(len(manifest['runtime_guest_configs']), 66)
        self.assertNotIn('virtio-net-peer/vcpus/build.toml', manifest['source_dependent_scenarios'])
        self.assertEqual(len(manifest['scenarios']['virtio-net-peer/vcpus/build.toml']), 64)
        self.assertTrue(manifest['prebuilt_guests'])
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.source.rglob('*') if p.is_file()})
        self.assertFalse((self.output / 'guests/arceos-virtio-net-peer.bin').exists())

    def test_missing_prebuilt_binary_is_rejected(self):
        (self.output / 'guests/arceos-vm-shell.bin').unlink()
        result = self.stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('arceos-vm-shell.bin', result.stderr)

    def test_incomplete_generated_set_is_rejected(self):
        (self.generated / 'vm64.toml').unlink()
        result = self.stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('vm64.toml', result.stderr)

    def test_physical_root_uses_final_partition_label_without_changing_resources(self):
        self.assertEqual(self.stage().returncode, 0)
        config = self.output / 'robot-single/guest.toml'
        before = tomllib.loads(config.read_text())
        result = subprocess.run(['python3', HELPER, '--physical-root-config', config,
                                 '--root-partition', '3', '--root-label', 'rootfs'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        after = tomllib.loads(config.read_text())
        before['kernel']['cmdline'] = 'root=PARTLABEL=rootfs rw'
        self.assertEqual(after, before)

    def test_network_generator_does_not_overwrite_provided_checkout_target(self):
        sentinel = self.source / 'target/axvisor-arceos-net-scale/vm1.toml'
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text('preserve-user-config')
        generator = self.source / BOARD / 'virtio-net-peer/vcpus/orangepi-arceos-virtio-net-test.sh'
        generator.parent.mkdir(parents=True)
        generator.write_text('''#!/bin/bash
set -eu
workspace=$(cd "$(dirname "$0")/../../../../../.." && pwd)
mkdir -p "$workspace/target/axvisor-arceos-net-scale"
cp "$GEN_FIXTURE"/vm*.toml "$workspace/target/axvisor-arceos-net-scale/"
''')
        command = '''source "$1/scripts/os/axvisor.sh"
axvisor_payload_kernel() { :; }
axvisor_payload_yolo() { :; }
axvisor_stage_payloads "$2"
'''
        result = subprocess.run(['bash', '-c', command, '_', ROOT, self.output], text=True, capture_output=True,
                                env=dict(os.environ, AXVISOR_SRC_DIR=str(self.source), GEN_FIXTURE=str(self.generated),
                                         BUILD_WORK_DIR=str(self.work / 'objects'), LOG_CREATE_DEFAULT_FILE='0'))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(), 'preserve-user-config')


class LinuxRuntimeTests(unittest.TestCase):
    def test_aarch64_runtime_checks_architecture_and_selected_target_symbol_versions(self):
        compiler = shutil.which('aarch64-linux-gnu-gcc')
        if not compiler:
            self.skipTest('AArch64 GNU compiler unavailable')
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            (work / 'main.c').write_text('int main(void) { return 0; }\n')
            binary = work / 'program'
            subprocess.run([compiler, str(work / 'main.c'), '-o', binary], check=True)
            validator = ROOT / 'scripts/lib/python/linux-runtime.py'
            target_libc = subprocess.check_output([compiler, '-print-file-name=libc.so.6'], text=True).strip()
            target = Path(target_libc).resolve().parent.parent
            result = subprocess.run(['python3', validator, '--sysroot', target, binary], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            incompatible = work / 'newer-glibc'
            data = binary.read_bytes()
            self.assertIn(b'GLIBC_2.34', data)
            incompatible.write_bytes(data.replace(b'GLIBC_2.34', b'GLIBC_2.99'))
            result = subprocess.run(['python3', validator, '--sysroot', target, incompatible], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('GLIBC_2.99', result.stderr)
            result = subprocess.run(['python3', validator, '--sysroot', target, '/bin/true'], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('AArch64', result.stderr)
            selected = work / 'selected-target'
            (selected / 'lib').mkdir(parents=True)
            (selected / 'payload').mkdir()
            shutil.copyfile(Path(target_libc).resolve(), selected / 'payload/libc.so.6')
            (selected / 'lib/libc.so.6').symlink_to('/payload/libc.so.6')
            result = subprocess.run(['python3', validator, '--sysroot', selected, binary], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            (selected / 'usr/lib64').mkdir(parents=True)
            shutil.copyfile(Path(target_libc).resolve(), selected / 'payload/libstdc++.so.6')
            (selected / 'usr/lib64/libstdc++.so.6').symlink_to('/payload/libstdc++.so.6')
            copied = work / 'copied-libraries'
            result = subprocess.run(['python3', validator, '--sysroot', selected, '--copy-libraries', copied,
                                     'libstdc++.so.6'], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((copied / 'libstdc++.so.6').read_bytes(), (selected / 'payload/libstdc++.so.6').read_bytes())
            self.assertEqual((copied / 'libstdc++.so').readlink(), Path('libstdc++.so.6'))


if __name__ == '__main__':
    unittest.main()
