#!/usr/bin/env python3
"""Exercise AxVisor packaging with a small local TGOSKits checkout."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
PACKAGER = ROOT / 'scripts/lib/python/axvisor-package.py'
SCRIPT = ROOT / 'scripts/os/axvisor.sh'
BOARD = Path('apps/axvisor/normal/board-ballpick-robot')


class AxvisorPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='orangepi-axvisor-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.source = self.work / 'source'
        self.board = self.source / BOARD
        self.board.mkdir(parents=True)
        self.host_config = self.source / 'os/axvisor/configs/board/orangepi-5-plus.toml'
        self.host_config.parent.mkdir(parents=True)
        self.host_config.write_text('target = "aarch64-unknown-none-softfloat"\nvm_configs = []\n')
        self.guest = self.board / 'shared/linux.toml'
        self.guest.parent.mkdir()
        self.guest.write_text('[base]\nid = 1\n[kernel]\nkernel_path = "/guest/linux/orangepi-5-plus"\n')
        for scenario in ('functional', 'lmbench'):
            directory = self.board / scenario
            directory.mkdir()
            (directory / 'build.toml').write_text(f'vm_configs = ["{BOARD}/shared/linux.toml"]\n')
            (directory / 'README.md').write_text('Use the shared guest configuration.\n')
        (self.board / 'source-only.toml').write_text(
            '[base]\nid = 2\n[kernel]\nkernel_path = "${workspace}/target/task-switch.bin"\n')
        (self.board / 'unrelated.bin').write_bytes(b'do not ship source artifacts')
        subprocess.run(['git', 'init', '-q', self.source], check=True)
        subprocess.run(['git', '-C', self.source, 'add', '.'], check=True)
        subprocess.run(['git', '-C', self.source, '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        self.output = self.work / 'package'

    def package(self):
        return subprocess.run(['python3', PACKAGER, self.source, self.output,
                               '--build-config', self.host_config], text=True, capture_output=True)

    def test_shared_guest_is_installed_once_and_referenced_by_both_scenarios(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.output / 'board-ballpick-robot'
        self.assertEqual((installed / 'shared/linux.toml').read_bytes(), self.guest.read_bytes())
        self.assertEqual(len(list(installed.rglob('linux.toml'))), 1)
        manifest = json.loads((self.output / 'manifest.json').read_text())
        guest_path = '/guest/axvisor/board-ballpick-robot/shared/linux.toml'
        for scenario in ('functional', 'lmbench'):
            self.assertEqual(manifest['scenarios'][f'{scenario}/build.toml'], [guest_path])
            self.assertTrue((installed / scenario / 'README.md').is_file())
        self.assertEqual(manifest['runtime_guest_configs'], [guest_path])
        self.assertIn('/guest/axvisor/board-ballpick-robot/source-only.toml',
                      manifest['source_dependent_guest_configs'])
        self.assertFalse((installed / 'unrelated.bin').exists())

    def test_missing_shared_reference_fails(self):
        self.guest.unlink()
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('shared/linux.toml', result.stderr)

    def test_generated_vcpu_configurations_are_recorded_as_source_dependencies(self):
        (self.board / 'generated.toml').write_text(
            'vm_configs = ["target/axvisor-arceos-net-scale/vm1.toml"]\n')
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / 'manifest.json').read_text())
        self.assertEqual(manifest['source_dependent_scenarios']['generated.toml'],
                         ['target/axvisor-arceos-net-scale/vm1.toml'])

    def test_symlink_cannot_copy_files_from_outside_configuration_tree(self):
        outside = self.work / 'private.toml'
        outside.write_text('private = true\n')
        (self.board / 'outside.toml').symlink_to(outside)
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symlink', result.stderr)

    def build(self, failure=False, source_toolchain=False, payload_failure=False):
        # Stub the expensive Cargo compile and binary converter, while retaining
        # the real source validation, configuration packaging and publication.
        command = r'''
set -euo pipefail
source "$1/scripts/os/axvisor.sh"
ensure_musl_toolchain() { :; }
axvisor_stage_payloads() { return "${PAYLOAD_FAILURE:-0}"; }
build_cargo() {
    [[ "$*" == "xtask axvisor build -c $AXVISOR_CONFIG" ]] || return 97
    [[ ${PROBE_FAIL:-0} == 0 ]] || return 23
    mkdir -p "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release"
    local image="$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/axvisor"
    printf fresh-image >"$image"
    printf '[axbuild] cargo build elf=%s\n' "$image"
}
axvisor_build
'''
        converter = self.work / 'objcopy'
        converter.write_text('#!/bin/bash\nset -eu\n[[ $1 == -O && $2 == binary ]]\ncp -- "$3" "$4"\n')
        converter.chmod(0o755)
        env = dict(os.environ, AXVISOR_SRC_DIR=str(self.source),
                   AXVISOR_IMAGES_DIR=str(self.output), AXVISOR_OBJCOPY=str(converter),
                   BUILD_WORK_DIR=str(self.work / 'build'), CARGO_TARGET_DIR=str(self.work / 'objects'),
                   LOG_CREATE_DEFAULT_FILE='0', PROBE_FAIL='1' if failure else '0',
                   PAYLOAD_FAILURE='42' if payload_failure else '0')
        if source_toolchain:
            tools = self.work / 'tools'
            tools.mkdir()
            library = self.work / 'toolchain/lib'
            library.mkdir(parents=True)
            (library.parent / 'bin').mkdir()
            (library.parent / 'bin/llvm-objcopy').write_text(converter.read_text())
            (library.parent / 'bin/llvm-objcopy').chmod(0o755)
            rustc = tools / 'rustc'
            rustc.write_text('#!/bin/bash\n[[ $PWD == "$EXPECTED_SOURCE" ]] || exit 88\n'
                             'printf "%s\\n" "$FIXTURE_LIB_DIR"\n')
            rustc.chmod(0o755)
            env.pop('AXVISOR_OBJCOPY')
            env.update(PATH=f'{tools}:{env["PATH"]}', EXPECTED_SOURCE=str(self.source),
                       FIXTURE_LIB_DIR=str(library))
        return subprocess.run(['bash', '-c', command, '_', ROOT], env=env, text=True, capture_output=True)

    def test_build_publishes_image_and_configs_from_same_checkout(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.output / 'AxVisor.bin').read_bytes(), b'fresh-image')
        self.assertEqual((self.output / 'orangepi-5-plus.elf').read_bytes(), b'fresh-image')
        self.assertTrue((self.output / 'board-ballpick-robot/shared/linux.toml').is_file())
        self.assertFalse((self.source / '.axconfig.toml').exists())
        manifest = json.loads((self.output / 'manifest.json').read_text())
        self.assertTrue(manifest['source_commit'])
        result = subprocess.run(['sha256sum', '-c', 'SHA256SUMS'], cwd=self.output,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_build_preserves_previous_package(self):
        self.output.mkdir()
        (self.output / 'old').write_text('previous package')
        result = self.build(failure=True)
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertEqual([p.name for p in self.output.iterdir()], ['old'])

    def test_failed_guest_build_preserves_previous_host_and_payload_package(self):
        self.output.mkdir()
        (self.output / 'old').write_text('previous package')
        result = self.build(payload_failure=True)
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertEqual([p.name for p in self.output.iterdir()], ['old'])

    def test_binary_converter_uses_tgoskits_rust_toolchain(self):
        result = self.build(source_toolchain=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_invalid_config_preserves_previous_package(self):
        self.output.mkdir()
        (self.output / 'old').write_text('previous package')
        self.guest.unlink()
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([p.name for p in self.output.iterdir()], ['old'])

    def test_clean_preserves_sources_and_other_components(self):
        self.output.mkdir()
        (self.output / 'image').write_text('old')
        other = self.work / 'starry'
        other.mkdir()
        result = subprocess.run(['bash', SCRIPT, 'clean'], text=True, capture_output=True,
                                env=dict(os.environ, AXVISOR_IMAGES_DIR=str(self.output),
                                         AXVISOR_SRC_DIR=str(self.source), LOG_CREATE_DEFAULT_FILE='0'))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.output.exists())
        self.assertTrue(other.is_dir())
        self.assertTrue(self.guest.is_file())


if __name__ == '__main__':
    unittest.main()
