#!/usr/bin/env python3
"""Offline checks for locked dependency inputs and package provenance."""
import importlib.util
import json
import os
from pathlib import Path
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
        for name in (*package.RUNTIME_LIBRARIES, 'libc.so.6'):
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
