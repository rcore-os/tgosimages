#!/usr/bin/env python3
"""Offline checks for locked dependency inputs and package provenance."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('aka_package', ROOT / 'scripts/lib/python/aka-package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.output = self.work / 'package'
        for name in package.REQUIRED_FILES:
            path = self.output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if name.startswith(('bin/', 'lib/')):
                self.elf(path)
            elif name.endswith('.json'):
                path.write_text('{"fixture":true}')
            else:
                path.write_text('fixture')

    @staticmethod
    def elf(path):
        header = bytearray(20)
        header[:6] = b'\x7fELF\x02\x01'
        header[18:20] = (183).to_bytes(2, 'little')
        path.write_bytes(header)

    def test_incomplete_package_and_host_library_are_rejected(self):
        package.validate_package(self.output)
        target = self.output / 'lib/libuvc.so.0'
        target.write_bytes(b'host library')
        with self.assertRaisesRegex(ValueError, 'AArch64'):
            package.validate_package(self.output)
        target.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing AKA package file'):
            package.validate_package(self.output)

    def test_single_robot_uses_a_real_binary_and_shares_common_assets(self):
        self.elf(self.output / 'bin/tennis')
        single = self.output / 'single'
        (single / 'build').mkdir(parents=True)
        (single / 'build/tennis').symlink_to('../../bin/tennis')
        for name in ('lib', 'models', 'config'):
            (single / name).symlink_to('../' + name)
        for name in ('run_lekiwi_full.sh', 'run_robot_ci_once.sh'):
            (single / name).write_text('#!/bin/sh\nexit 0\n')
        package.validate_single_package(self.output)
        (self.output / 'bin/tennis').write_bytes(b'wrong architecture')
        with self.assertRaisesRegex(ValueError, 'AArch64'):
            package.validate_single_package(self.output)

    def test_dual_only_override_cannot_be_published_as_a_complete_robot_package(self):
        package.validate_package(self.output)
        with self.assertRaisesRegex(ValueError, 'tennis'):
            package.validate_single_package(self.output)
        result = subprocess.run(['bash', str(ROOT / 'scripts/apps/orangepi-aka-package.sh')],
                                text=True, capture_output=True,
                                env=dict(os.environ, ORANGEPI_AKA_PACKAGE=str(self.output),
                                         ORANGEPI_AKA_PACKAGE_PROVIDED='1',
                                         LOG_CREATE_DEFAULT_FILE='0'))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('tennis', result.stdout + result.stderr)

    def helper(self, *arguments):
        return subprocess.run(['python3', str(ROOT / 'scripts/lib/python/aka-package.py'), *map(str, arguments)],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_installed_single_launchers_export_package_libraries_without_changing_source(self):
        source = self.work / 'aka-source'
        source.mkdir()
        single = self.output / 'single'
        single.mkdir()
        (single / 'lib').symlink_to('../lib')
        scripts = ('run_lekiwi_full.sh', 'run_robot_ci_once.sh')
        original = '#!/bin/sh\nset -eu\nprintf "%s\\n" "${LD_LIBRARY_PATH:-}"\n'
        for name in scripts:
            (source / name).write_text(original)
        installed = self.helper('install-launchers', '--aka', source, '--single', single)
        self.assertEqual(installed.returncode, 0, installed.stdout)
        for name in scripts:
            self.assertEqual((source / name).read_text(), original)
            for previous in ('', '/caller/lib:/another/lib'):
                with self.subTest(script=name, previous=previous):
                    environment = dict(os.environ, LD_LIBRARY_PATH=previous)
                    actual = subprocess.check_output([str(single / name)], env=environment, text=True).strip()
                    expected = str(single / 'lib') + (':' + previous if previous else '')
                    self.assertEqual(actual, expected)

    def test_cross_build_headers_support_cpp_include_next_without_fallback_c_headers(self):
        cc, cxx = shutil.which('aarch64-linux-gnu-gcc'), shutil.which('aarch64-linux-gnu-g++')
        if not cc or not cxx:
            self.skipTest('AArch64 GNU compilers unavailable')
        libc = Path(subprocess.check_output([cc, '-print-file-name=libc.so'], text=True).strip())
        headers = libc.resolve().parents[1] / 'include'
        if not (headers / 'math.h').is_file():
            self.skipTest('Target C headers unavailable')
        sysroot, libraries = self.sysroot_fixture()
        shutil.rmtree(sysroot / 'usr/include')
        (sysroot / 'usr/include').mkdir()
        for header in headers.iterdir():
            if header.name not in ('c++', 'math.h'):
                (sysroot / 'usr/include' / header.name).symlink_to(header)
        # A distinct target header proves the build uses this SDK rather than
        # succeeding through the compiler's default target-C header fallback.
        (sysroot / 'usr/include/math.h').write_text(
            '#define TGOS_SELECTED_TARGET_MATH 1\n#include "' + str(headers / 'math.h') + '"\n')
        tools = self.work / 'tools'
        tools.mkdir()
        capture = self.work / 'cmake-arguments.json'
        cmake = tools / 'cmake'
        cmake.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                         'open(os.environ["CAPTURE"], "w").write(json.dumps(sys.argv[1:]))\n'
                         'sys.exit(77)\n')
        cmake.chmod(0o755)
        source, sdk = self.work / 'source', self.work / 'sdk'
        source.mkdir()
        sdk.mkdir()
        config = source / 'config'
        config.mkdir()
        for name in ('lekiwi_calibration.json', 'lekiwi_pick_config.txt'):
            (config / name).write_text('fixture')
        project = source / 'apps/axvisor/normal/board-ballpick-robot/linux-guest-checks/rknn-yolov8-image'
        project.mkdir(parents=True)
        (project / 'CMakeLists.txt').write_text('fixture')
        probe = self.work / 'probe.cpp'
        probe.write_text('#include <cmath>\n#include <cstdlib>\n#include <vector>\n'
                         '#ifndef TGOS_SELECTED_TARGET_MATH\n#error Wrong target C headers\n#endif\n'
                         'long value(double x) { return std::lround(x); }\n')
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                   CAPTURE=str(capture), LOG_CREATE_DEFAULT_FILE='0',
                   BUILD_WORK_DIR=str(self.work / 'objects'), AXVISOR_SRC_DIR=str(source),
                   ORANGEPI_YOLO_CC=cc, ORANGEPI_YOLO_CXX=cxx, ORANGEPI_YOLO_SYSROOT=str(sysroot))
        for kind in ('aka', 'yolo'):
            with self.subTest(kind=kind):
                capture.unlink(missing_ok=True)
                if kind == 'aka':
                    command = ['bash', str(ROOT / 'scripts/apps/orangepi-aka-perception.sh'),
                               '--aka-dir', str(source), '--ivc-sdk-dir', str(sdk),
                               '--runtime-dir', str(libraries), '--include-dir', str(sysroot / 'usr/include'),
                               '--cc', cc, '--cxx', cxx, '--sysroot', str(sysroot),
                               '--build-dir', str(self.work / 'aka-build'), '--output-dir', str(self.work / 'aka-output')]
                else:
                    command = ['bash', '-c', 'source "$1/scripts/os/axvisor.sh"; axvisor_payload_yolo "$2"',
                               '_', str(ROOT), str(self.work / 'yolo-output')]
                result = subprocess.run(command, env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 77 if kind == 'aka' else 1,
                                 result.stdout + result.stderr)
                self.assertTrue(capture.is_file(), result.stdout + result.stderr)
                arguments = json.loads(capture.read_text())
                flags = shlex.split(next(arg.split('=', 1)[1] for arg in arguments
                                         if arg.startswith('-DCMAKE_CXX_FLAGS=')))
                deps = self.work / (kind + '.d')
                result = subprocess.run([cxx, '--sysroot=' + str(sysroot),
                                         *flags, '-MD', '-MF', str(deps), '-c', str(probe),
                                         '-o', str(self.work / (kind + '.o'))], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                dependencies = shlex.split(deps.read_text().replace('\\\n', ''))
                self.assertIn((sysroot / 'usr/include/math.h').resolve(),
                              [Path(path).resolve() for path in dependencies])

    def sysroot_fixture(self, folder='usr/lib/aarch64-linux-gnu'):
        sysroot = self.work / 'target-sysroot'
        libraries = sysroot / folder
        libraries.mkdir(parents=True)
        (sysroot / 'usr/include').mkdir(parents=True, exist_ok=True)
        (sysroot / 'usr/include/target-header.h').write_text('caller target header')
        for name in (*package.RUNTIME_LIBRARIES, *package.TOOLCHAIN_LIBRARIES):
            self.elf(libraries / name)
        (sysroot / 'caller-owned').write_text('preserve me')
        return sysroot, libraries

    @staticmethod
    def snapshot(tree):
        return {str(p.relative_to(tree)): ('symlink', os.readlink(p)) if p.is_symlink()
                else ('file', p.read_bytes(), p.stat().st_mtime_ns) if p.is_file() else ('dir',)
                for p in tree.rglob('*')}

    def test_user_sysroot_runtime_is_copied_readonly_and_resolves_target_absolute_links(self):
        sysroot, libraries = self.sysroot_fixture()
        library = libraries / package.RUNTIME_LIBRARIES[0]
        library.rename(library.with_suffix('.0.1'))
        library.symlink_to('/usr/lib/aarch64-linux-gnu/' + library.with_suffix('.0.1').name)
        before = self.snapshot(sysroot)
        runtime = self.work / 'runtime-copy'
        result = self.helper('sysroot-runtime', '--sysroot', sysroot, '--output', runtime)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.snapshot(sysroot), before)
        for name in (*package.RUNTIME_LIBRARIES, *package.TOOLCHAIN_LIBRARIES):
            self.assertTrue((runtime / name).is_file(), name)
            self.assertFalse((runtime / name).is_symlink(), name)
            package.arm64_elf(runtime / name)
        for name, soname in (('libstdc++.so', 'libstdc++.so.6'), ('libgcc_s.so', 'libgcc_s.so.1')):
            self.assertTrue((runtime / name).is_symlink(), name)
            self.assertEqual(os.readlink(runtime / name), soname)
            self.assertEqual((runtime / name).resolve(), runtime / soname)
        manifest = json.loads((runtime / 'runtime-manifest.json').read_text())
        self.assertEqual(manifest['kind'], 'caller-provided-sysroot')
        self.assertEqual(manifest['path'], str(sysroot))

    def test_user_sysroot_runtime_rejects_missing_library_without_modifying_target(self):
        sysroot, libraries = self.sysroot_fixture()
        (libraries / 'libudev.so.1').unlink()
        before = self.snapshot(sysroot)
        runtime = self.work / 'runtime-copy'
        result = self.helper('sysroot-runtime', '--sysroot', sysroot, '--output', runtime)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('libudev.so.1', result.stdout)
        self.assertIn('ORANGEPI_AKA_RUNTIME_DIR', result.stdout)
        self.assertEqual(self.snapshot(sysroot), before)
        self.assertFalse(runtime.exists())

    def test_package_entry_uses_explicit_sysroot_readonly_even_with_managed_manifest(self):
        fixture = self.work / 'entry-fixture'
        for folder in ('scripts/apps', 'scripts/lib/python'):
            (fixture / folder).mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/apps/orangepi-aka-package.sh', fixture / 'scripts/apps/orangepi-aka-package.sh')
        (fixture / 'scripts/lib/python/aka-package.py').symlink_to(ROOT / 'scripts/lib/python/aka-package.py')
        (fixture / 'scripts/lib/utils.sh').write_text('''BUILD_DIR="$BUILD_WORK_DIR"
build_prepare_checkout() { :; }
build_jobs() { echo 1; }
info() { :; }
die() { echo "$*" >&2; exit 1; }
''')
        (fixture / 'scripts/apps/orangepi-aka-perception.sh').write_text('''#!/bin/bash
python3 - "$@" <<'PY'
import json, os, sys
from pathlib import Path
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
assert (Path(args['--runtime-dir']) / 'libuvc.so.0').is_file()
Path(os.environ['AKA_TEST_CAPTURE']).write_text(json.dumps(args))
PY
''')
        lock = self.work / 'empty-lock.json'
        lock.write_text(json.dumps(dict(schema_version=1, architecture='arm64', packages=[])))
        sysroot, _ = self.sysroot_fixture()
        for managed_marker in (False, True):
            with self.subTest(managed_marker=managed_marker):
                if managed_marker:
                    (sysroot / 'runtime').mkdir()
                    (sysroot / 'runtime/runtime-manifest.json').write_text('{"caller-owned":true}')
                before = self.snapshot(sysroot)
                environment = {key: value for key, value in os.environ.items()
                               if not key.startswith(('ORANGEPI_AKA_', 'IVC_SDK_', 'AKA_RK3588_'))}
                environment.update(BUILD_WORK_DIR=str(self.work / 'objects'), ORANGEPI_AKA_SYSROOT=str(sysroot),
                                   ORANGEPI_AKA_CC='/bin/true', ORANGEPI_AKA_CXX='/bin/true',
                                   ORANGEPI_AKA_DEPENDENCY_LOCK=str(lock), AKA_TEST_CAPTURE=str(self.work / 'arguments'))
                result = subprocess.run(['bash', str(fixture / 'scripts/apps/orangepi-aka-package.sh')],
                                        env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 0, result.stdout)
                arguments = json.loads((self.work / 'arguments').read_text())
                self.assertEqual(arguments['--sysroot'], str(sysroot))
                self.assertEqual(arguments['--include-dir'], str(sysroot / 'usr/include'))
                self.assertFalse(Path(arguments['--runtime-dir']).is_relative_to(sysroot))
                self.assertEqual(self.snapshot(sysroot), before)

    def test_manifest_records_source_runtime_config_and_payload_hashes(self):
        sources = []
        for name in ('aka', 'sdk'):
            source = self.work / name
            subprocess.run(['git', 'init', '-q', str(source)], check=True)
            subprocess.run(['git', '-C', str(source), 'remote', 'add', 'origin', f'https://example.invalid/{name}.git'], check=True)
            subprocess.run(['git', '-C', str(source), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                            'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
            sources.append(source)
        compiler = self.work / 'cc'
        compiler.write_text('#!/bin/sh\nif [ "$1" = --version ]; then echo "Fixture GCC"; else echo aarch64-linux-gnu; fi\n')
        compiler.chmod(0o755)
        runtime = self.work / 'runtime'
        runtime.mkdir()
        origin = {'lock': {'packages': [{'name': 'fixture', 'version': '1', 'sha256': 'a' * 64}]}}
        (runtime / 'runtime-manifest.json').write_text(json.dumps(origin))
        config = self.output / 'config'
        package.write_manifest(self.output, *sources, compiler, runtime, config)
        manifest = json.loads((self.output / 'package-manifest.json').read_text())
        self.assertEqual(manifest['aka']['remote'], 'https://example.invalid/aka.git')
        self.assertEqual(manifest['runtime_source'], origin)
        self.assertEqual(manifest['config_source'], str(config))
        self.assertEqual(manifest['files']['config/lekiwi_calibration.json'], package.sha256(config / 'lekiwi_calibration.json'))
        self.assertNotIn('package-manifest.json', manifest['files'])

    def test_local_source_without_remote_is_recorded(self):
        source = self.work / 'local-source'
        subprocess.run(['git', 'init', '-q', str(source)], check=True)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                        'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
        recorded = package.repository(source)
        self.assertIsNone(recorded['remote'])
        self.assertFalse(recorded['dirty'])
        self.assertEqual(len(recorded['commit']), 40)

    def test_locked_deb_is_verified_extracted_and_reusable_offline(self):
        tree = self.work / 'deb-tree'
        (tree / 'DEBIAN').mkdir(parents=True)
        (tree / 'DEBIAN/control').write_text('Package: fixture\nVersion: 1.0\nArchitecture: arm64\nMaintainer: Fixture <fixture@example.invalid>\nDescription: fixture\n')
        libraries = tree / 'usr/lib/aarch64-linux-gnu'
        libraries.mkdir(parents=True)
        for name in (*package.RUNTIME_LIBRARIES, *package.TOOLCHAIN_LIBRARIES, 'libc.so.6'):
            self.elf(libraries / name)
        archive = self.work / 'fixture.deb'
        subprocess.run(['dpkg-deb', '--build', str(tree), str(archive)], check=True, stdout=subprocess.DEVNULL)
        digest = package.sha256(archive)
        lock = self.work / 'lock.json'
        lock.write_text(json.dumps(dict(schema_version=1, architecture='arm64', packages=[
            dict(name='fixture', version='1.0', architecture='arm64', url=archive.as_uri(), sha256=digest)])))
        cache = self.work / 'cache'
        sysroot = self.work / 'sysroot'
        package.prepare_runtime(lock, cache, sysroot)
        archive.unlink()
        package.prepare_runtime(lock, cache, sysroot)
        self.assertTrue((sysroot / 'runtime/runtime-manifest.json').is_file())
        (cache / (digest + '.deb')).write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
            package.prepare_runtime(lock, cache, sysroot)
        self.assertTrue((sysroot / 'runtime/libuvc.so.0').is_file())


if __name__ == '__main__':
    unittest.main()
