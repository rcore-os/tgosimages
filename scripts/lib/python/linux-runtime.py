#!/usr/bin/env python3
"""Check AArch64 programs against libraries from the selected target sysroot."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess

_spec = importlib.util.spec_from_file_location('aka_package', Path(__file__).with_name('aka-package.py'))
_target = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_target)


def aarch64(path):
    with path.open('rb') as stream:
        header = stream.read(20)
    if len(header) < 20 or header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[18:20], 'little') != 183:
        raise ValueError(f'Expected AArch64 ELF: {path}')


def readelf(*args):
    return subprocess.check_output(['readelf', *map(str, args)], text=True, env=dict(os.environ, LC_ALL='C'))


def target_library(sysroot, library, library_dirs=()):
    folders = (*library_dirs, *('/' + folder for folder in _target.SYSROOT_LIBRARY_DIRS))
    candidates = (_target.sysroot_path(sysroot, Path(folder.lstrip('/')) / library) for folder in folders)
    candidate = next((path for path in candidates if path.is_file()), None)
    if candidate is None:
        raise ValueError(f'Target sysroot lacks {library}: {sysroot}')
    aarch64(candidate)
    return candidate


def validate(path, sysroot, library_dirs=()):
    aarch64(path)
    sysroot = sysroot.resolve(strict=True)
    versions = readelf('--version-info', path)
    needs = versions.partition('Version needs section')[2]
    provided = {}
    for version in re.findall(r'Name:\s+((?:GLIBCXX|GLIBC|CXXABI)_[A-Za-z0-9_.]+)', needs):
        library = 'libstdc++.so.6' if version.startswith(('GLIBCXX_', 'CXXABI_')) else 'libc.so.6'
        if library not in provided:
            candidate = target_library(sysroot, library, library_dirs)
            definitions = readelf('--version-info', candidate)
            provided[library] = set(re.findall(r'Name:\s+(\S+)', definitions.partition('Version needs section')[0]))
        if version not in provided[library]:
            raise ValueError(f'{path} needs {version}, absent from target sysroot {sysroot}')
    dynamic = readelf('-d', path)
    for dependency in re.findall(r'Shared library: \[([^]]+)\]', dynamic):
        if '/' in dependency:
            raise ValueError(f'Non-relocatable ELF dependency in {path}: {dependency}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', type=Path, nargs='+')
    parser.add_argument('--sysroot', type=Path, required=True)
    parser.add_argument('--library-dir', action='append', default=[])
    parser.add_argument('--copy-libraries', type=Path)
    args = parser.parse_args()
    try:
        for path in args.files:
            if args.copy_libraries:
                if path.name != str(path):
                    raise ValueError(f'Expected a library name: {path}')
                source = target_library(args.sysroot.resolve(strict=True), path.name, args.library_dir)
                args.copy_libraries.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, args.copy_libraries / path.name)
                alias = {'libstdc++.so.6': 'libstdc++.so', 'libgcc_s.so.1': 'libgcc_s.so'}.get(path.name)
                if alias:
                    link = args.copy_libraries / alias
                    if link.is_symlink() and link.readlink() == Path(path.name):
                        continue
                    if link.exists() or link.is_symlink():
                        raise ValueError(f'Conflicting target linker name: {link}')
                    link.symlink_to(path.name)
            else:
                validate(path, args.sysroot, args.library_dir)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(f'Linux runtime: {error}')
