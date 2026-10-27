#!/usr/bin/env python3
"""Prepare locked ARM64 inputs and record the provenance of an AKA package."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import urllib.request

RUNTIME_LIBRARIES = ('libuvc.so.0', 'libusb-1.0.so.0', 'libturbojpeg.so.0', 'libjpeg.so.8', 'libudev.so.1')
TOOLCHAIN_LIBRARIES = ('libstdc++.so.6', 'libgcc_s.so.1')
SYSROOT_LIBRARY_DIRS = ('usr/lib/aarch64-linux-gnu', 'lib/aarch64-linux-gnu', 'usr/lib64', 'lib64', 'usr/lib', 'lib')
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


def target_header_flags(compiler, sysroot, language):
    """Retain GCC's wrappers/builtins, then use only the selected SDK's C headers."""
    compiler = str(compiler)
    directories = []
    if language == 'c++':
        search = subprocess.run([compiler, '-E', '-x', language, '-v', '-'], input='',
                                text=True, capture_output=True, check=True,
                                env=dict(os.environ, LC_ALL='C')).stderr
        begin, end = '#include <...> search starts here:\n', 'End of search list.'
        if begin not in search or end not in search:
            raise ValueError(f'Cannot inspect C++ header search paths: {compiler}')
        for line in search.split(begin, 1)[1].split(end, 1)[0].splitlines():
            path = Path(line.strip())
            if 'c++' in path.parts and path.is_dir():
                directories.append(path)
        if not directories:
            raise ValueError(f'Compiler has no C++ standard headers: {compiler}')
    for name in ('include', 'include-fixed'):
        path = Path(subprocess.check_output([compiler, '-print-file-name=' + name], text=True).strip())
        if path.is_absolute() and path.is_dir():
            directories.append(path)
    sysroot = sysroot.resolve(strict=True)
    directories.extend(sysroot / relative for relative in
                       ('usr/include/aarch64-linux-gnu', 'usr/include', 'include')
                       if (sysroot / relative).is_dir())
    return shlex.join(['-nostdinc', *[flag for path in dict.fromkeys(directories)
                                   for flag in ('-isystem', str(path))]])


def sysroot_path(sysroot, relative):
    """Resolve links using the target root, including target-absolute links."""
    pending = list(Path(relative).parts)
    resolved = sysroot
    links = 0
    while pending:
        part = pending.pop(0)
        if part == '.':
            continue
        if part == '..':
            if resolved == sysroot:
                raise ValueError(f'Target sysroot link escapes root: {relative}')
            resolved = resolved.parent
            continue
        resolved = resolved / part
        if resolved.is_symlink():
            links += 1
            if links > 40:
                raise ValueError(f'Target sysroot link loop: {relative}')
            target = resolved.readlink()
            resolved = sysroot if target.is_absolute() else resolved.parent
            pending = list(target.parts[1:] if target.is_absolute() else target.parts) + pending
    return resolved


def copy_sysroot_runtime(sysroot, output):
    """Copy selected target libraries without managing or changing the SDK."""
    sysroot = sysroot.resolve(strict=True)
    output = output.resolve()
    if output.is_relative_to(sysroot):
        raise ValueError('Runtime output must be outside the caller target sysroot')
    if output.exists():
        raise ValueError(f'Runtime output already exists: {output}')
    sources = {}
    for name in (*RUNTIME_LIBRARIES, *TOOLCHAIN_LIBRARIES):
        candidates = (sysroot_path(sysroot, Path(folder) / name) for folder in SYSROOT_LIBRARY_DIRS)
        source = next((candidate for candidate in candidates if candidate.is_file()), None)
        if source is None:
            if name in TOOLCHAIN_LIBRARIES:
                continue
            raise ValueError(f'Caller target sysroot lacks {name}: {sysroot}; '
                             'provide both ORANGEPI_AKA_RUNTIME_DIR and ORANGEPI_AKA_INCLUDE_DIR')
        arm64_elf(source)
        sources[name] = source
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.aka-target-runtime.', dir=output.parent) as temporary:
        stage = Path(temporary)
        for name, source in sources.items():
            shutil.copyfile(source, stage / name)
        # Keep -lstdc++/-lgcc_s in this target-derived runtime even when the
        # caller SDK supplies only SONAME files and no development aliases.
        for name, soname in (('libstdc++.so', 'libstdc++.so.6'), ('libgcc_s.so', 'libgcc_s.so.1')):
            if soname in sources:
                (stage / name).symlink_to(soname)
        notices = stage / 'licenses'
        for document in (sysroot / 'usr/share/doc').glob('*/copyright'):
            if not document.parent.name.startswith(('libuvc', 'libusb-1.0-', 'libturbojpeg', 'libjpeg',
                                                     'libudev', 'libstdc++', 'libgcc')):
                continue
            source = sysroot_path(sysroot, document.relative_to(sysroot))
            if source.is_file():
                notices.mkdir(exist_ok=True)
                shutil.copyfile(source, notices / (document.parent.name + '.copyright'))
        manifest = dict(kind='caller-provided-sysroot', path=str(sysroot),
                        libraries={name: sha256(stage / name) for name in sources})
        (stage / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        os.replace(stage, output)
    print(f'AKA_TARGET_RUNTIME_READY sysroot={sysroot} runtime={output}', flush=True)


def install_single_launchers(aka, single):
    # RUNPATH on tennis does not cover indirect dependencies such as
    # libuvc -> libjpeg and libusb -> libudev. Set the search path in both
    # installed entry points while keeping the caller's checkout untouched.
    bootstrap = '''# Resolve all direct and indirect libraries from this installed AKA package.
_aka_package_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" || exit 1
export LD_LIBRARY_PATH="${_aka_package_dir}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
unset _aka_package_dir
'''
    for name in ('run_lekiwi_full.sh', 'run_robot_ci_once.sh'):
        first, newline, body = (aka / name).read_text().partition('\n')
        if not first.startswith('#!') or not newline:
            raise ValueError(f'Expected a shell launcher: {aka / name}')
        destination = single / name
        destination.write_text(first + '\n' + bootstrap + body)
        destination.chmod(0o755)


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
                with tempfile.NamedTemporaryFile(prefix='.download-', suffix='.deb', dir=cache, delete=False) as output:
                    pending = Path(output.name)
                try:
                    with urllib.request.urlopen(package['url'], timeout=60) as response, pending.open('wb') as output:
                        shutil.copyfileobj(response, output)
                    if sha256(pending) != digest:
                        raise ValueError(f"SHA256 mismatch: {package['name']}")
                    os.replace(pending, archive)
                finally:
                    pending.unlink(missing_ok=True)
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
        for name in (*RUNTIME_LIBRARIES, *TOOLCHAIN_LIBRARIES, 'libc.so.6'):
            candidates = [stage / folder / name for folder in ('usr/lib/aarch64-linux-gnu', 'lib/aarch64-linux-gnu')]
            source = next((p for p in candidates if p.is_file()), None)
            if source is None or not source.resolve().is_relative_to(stage):
                raise ValueError(f'Locked dependency does not provide {name}')
            arm64_elf(source)
            shutil.copyfile(source, runtime / name)
            libraries[name] = sha256(runtime / name)
        # Development linker names are absent from runtime-only C++ packages.
        # Resolve -lstdc++/-lgcc_s inside this sysroot, not the build host SDK.
        linker_dir = stage / 'usr/lib/aarch64-linux-gnu'
        linker_dir.mkdir(parents=True, exist_ok=True)
        for name, soname in (('libstdc++.so', 'libstdc++.so.6'), ('libgcc_s.so', 'libgcc_s.so.1')):
            source = next(stage / folder / soname for folder in ('usr/lib/aarch64-linux-gnu', 'lib/aarch64-linux-gnu')
                          if (stage / folder / soname).is_file())
            (linker_dir / name).symlink_to(os.path.relpath(source, linker_dir))
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


def validate_single_package(package):
    validate_package(package)
    for name in ('bin/tennis', 'single/build/tennis', 'single/run_lekiwi_full.sh', 'single/run_robot_ci_once.sh',
                 'single/models/tennis.rknn', 'single/config/lekiwi_calibration.json',
                 'single/config/lekiwi_pick_config.txt', 'single/lib/librknnrt.so'):
        path = package / name
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f'Missing single robot package file: {name}')
        if not path.resolve().is_relative_to(package.resolve()):
            raise ValueError(f'Single robot package link escapes package: {name}')
    arm64_elf(package / 'bin/tennis')


def repository(path):
    remote = subprocess.run(['git', '-C', str(path), 'config', '--get', 'remote.origin.url'],
                            text=True, stdout=subprocess.PIPE, check=False)
    return dict(path=str(path), commit=subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip(),
                remote=remote.stdout.strip() or None,
                dirty=bool(subprocess.check_output(['git', '-C', str(path), 'status', '--porcelain'])))


def write_manifest(package, aka, sdk, compiler, runtime, config):
    validate_package(package)
    if (package / 'single').exists():
        validate_single_package(package)
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
    target_runtime = sub.add_parser('sysroot-runtime')
    target_runtime.add_argument('--sysroot', type=Path, required=True)
    target_runtime.add_argument('--output', type=Path, required=True)
    headers = sub.add_parser('header-flags')
    for name in ('cc', 'cxx', 'sysroot'):
        headers.add_argument('--' + name, type=Path, required=True)
    launchers = sub.add_parser('install-launchers')
    launchers.add_argument('--aka', type=Path, required=True)
    launchers.add_argument('--single', type=Path, required=True)
    validate = sub.add_parser('validate')
    validate.add_argument('package', type=Path)
    validate.add_argument('--with-single', action='store_true')
    manifest = sub.add_parser('manifest')
    for name in ('package', 'aka', 'sdk', 'compiler', 'runtime', 'config'):
        manifest.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'runtime':
        prepare_runtime(args.lock, args.cache, args.sysroot)
    elif args.action == 'sysroot-runtime':
        copy_sysroot_runtime(args.sysroot, args.output)
    elif args.action == 'header-flags':
        print(target_header_flags(args.cc, args.sysroot, 'c'))
        print(target_header_flags(args.cxx, args.sysroot, 'c++'))
    elif args.action == 'install-launchers':
        install_single_launchers(args.aka, args.single)
    elif args.action == 'validate':
        (validate_single_package if args.with_single else validate_package)(args.package)
    else:
        write_manifest(args.package, args.aka, args.sdk, args.compiler, args.runtime, args.config)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        raise SystemExit(f'AKA package: {exc}')
