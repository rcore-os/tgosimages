#!/usr/bin/env python3
"""Prepare locked ARM64 inputs and record the provenance of an AKA package."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

RUNTIME_LIBRARIES = ('libuvc.so.0', 'libusb-1.0.so.0', 'libturbojpeg.so.0', 'libjpeg.so.8', 'libudev.so.1')
REQUIRED_FILES = ('bin/tennis-perception', 'lib/librknnrt.so', 'models/tennis.rknn',
                  'config/lekiwi_calibration.json', 'config/lekiwi_pick_config.txt',
                  'run_dual_pick_ci_once.sh', *(f'lib/{name}' for name in RUNTIME_LIBRARIES))


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def arm64_elf(path):
    with Path(path).open('rb') as stream:
        header = stream.read(20)
    if len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[18:20], 'little') != 183:
        raise ValueError(f'Expected AArch64 ELF: {path}')


def prepare_runtime(lock_path, cache, sysroot):
    lock = json.loads(lock_path.read_text())
    if lock.get('schema_version') != 1 or lock.get('architecture') != 'arm64':
        raise ValueError('Unsupported AKA runtime lock')
    if sysroot.exists() and not (sysroot / 'runtime/runtime-manifest.json').is_file():
        raise ValueError(f'Sysroot already exists without a managed runtime manifest: {sysroot}')
    cache.mkdir(parents=True, exist_ok=True)
    sysroot.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.aka-deps.', dir=sysroot.parent) as temporary:
        stage = Path(temporary)
        for package in lock['packages']:
            if package['architecture'] != 'arm64':
                raise ValueError('AKA dependencies must target arm64')
            digest = package['sha256']
            if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
                raise ValueError('Invalid package SHA256')
            archive = cache / (digest + '.deb')
            if not archive.exists():
                print(f"AKA dependency: {package['name']} {package['version']}", flush=True)
                pending = stage / 'download.deb'
                with urllib.request.urlopen(package['url'], timeout=60) as response, pending.open('wb') as output:
                    shutil.copyfileobj(response, output)
                if sha256(pending) != digest:
                    raise ValueError(f"SHA256 mismatch: {package['name']}")
                os.replace(pending, archive)
            if sha256(archive) != digest:
                raise ValueError(f'Cached package SHA256 mismatch: {archive}; remove it and retry')
            fields = subprocess.check_output(['dpkg-deb', '--field', str(archive), 'Package', 'Version', 'Architecture'], text=True)
            for key, expected in [('Package', package['name']), ('Version', package['version']), ('Architecture', 'arm64')]:
                if f'{key}: {expected}' not in fields.splitlines():
                    raise ValueError(f'Package metadata mismatch: {archive}')
            subprocess.run(['dpkg-deb', '--extract', str(archive), str(stage)], check=True)
        runtime = stage / 'runtime'
        runtime.mkdir()
        libraries = {}
        for name in (*RUNTIME_LIBRARIES, 'libc.so.6'):
            candidates = [stage / folder / name for folder in ('usr/lib/aarch64-linux-gnu', 'lib/aarch64-linux-gnu')]
            source = next((p for p in candidates if p.is_file()), None)
            if source is None or not source.resolve().is_relative_to(stage):
                raise ValueError(f'Locked dependency does not provide {name}')
            arm64_elf(source)
            shutil.copyfile(source, runtime / name)
            libraries[name] = sha256(runtime / name)
        licenses = runtime / 'licenses'
        licenses.mkdir()
        for package in lock['packages']:
            copyright_file = stage / 'usr/share/doc' / package['name'] / 'copyright'
            if copyright_file.is_file():
                shutil.copyfile(copyright_file, licenses / (package['name'] + '.copyright'))
        (runtime / 'runtime-manifest.json').write_text(json.dumps(dict(lock=lock, libraries=libraries), indent=2) + '\n')
        if sysroot.exists():
            shutil.rmtree(sysroot)
        os.replace(stage, sysroot)
    print(f'AKA_RUNTIME_READY sysroot={sysroot}', flush=True)


def validate_package(package):
    for name in REQUIRED_FILES:
        path = package / name
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f'Missing AKA package file: {name}')
    for name in ('bin/tennis-perception', 'lib/librknnrt.so', *(f'lib/{n}' for n in RUNTIME_LIBRARIES)):
        arm64_elf(package / name)
    json.loads((package / 'config/lekiwi_calibration.json').read_text())


def repository(path):
    remote = subprocess.run(['git', '-C', str(path), 'config', '--get', 'remote.origin.url'],
                            text=True, stdout=subprocess.PIPE, check=False)
    return dict(path=str(path), commit=subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip(),
                remote=remote.stdout.strip() or None,
                dirty=bool(subprocess.check_output(['git', '-C', str(path), 'status', '--porcelain'])))


def write_manifest(package, aka, sdk, compiler, runtime, config):
    validate_package(package)
    runtime_manifest = runtime / 'runtime-manifest.json'
    files = {str(p.relative_to(package)): sha256(p) for p in sorted(package.rglob('*'))
             if p.is_file() and p.name != 'package-manifest.json'}
    data = dict(schema_version=1, architecture='aarch64', aka=repository(aka), ivc_sdk=repository(sdk),
                compiler=subprocess.check_output([str(compiler), '--version'], text=True).splitlines()[0],
                compiler_target=subprocess.check_output([str(compiler), '-dumpmachine'], text=True).strip(),
                config_source=str(config), runtime_source=(json.loads(runtime_manifest.read_text()) if runtime_manifest.is_file()
                                                        else dict(kind='caller-provided', path=str(runtime))), files=files)
    (package / 'package-manifest.json').write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    runtime = sub.add_parser('runtime')
    for name in ('lock', 'cache', 'sysroot'):
        runtime.add_argument('--' + name, type=Path, required=True)
    validate = sub.add_parser('validate')
    validate.add_argument('package', type=Path)
    manifest = sub.add_parser('manifest')
    for name in ('package', 'aka', 'sdk', 'compiler', 'runtime', 'config'):
        manifest.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'runtime':
        prepare_runtime(args.lock, args.cache, args.sysroot)
    elif args.action == 'validate':
        validate_package(args.package)
    else:
        write_manifest(args.package, args.aka, args.sdk, args.compiler, args.runtime, args.config)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        raise SystemExit(f'AKA package: {exc}')
