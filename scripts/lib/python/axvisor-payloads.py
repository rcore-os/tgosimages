#!/usr/bin/env python3
"""Adapt prebuilt guest configurations inside a private AxVisor package stage."""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tomllib

BOARD = Path('apps/axvisor/normal/board-ballpick-robot')
PREFIX = '/guest/axvisor/'
SHELL = Path('kernel-types/arceos/configs/arceos.toml')
SINGLE = Path('apps/axvisor/normal/board-orangepi-5-plus/robot-real-starry/guest.toml')
NETWORK = Path('virtio-net-peer/vcpus/generated')


def required(path):
    if path.is_symlink() or not path.is_file() or not path.stat().st_size:
        raise ValueError(f'Missing or unsafe payload: {path}')
    return path.read_text() if path.suffix == '.toml' else None


def kernel_field(source, key, destination):
    original = tomllib.loads(source)
    result, count = re.subn(r'(?m)^(' + re.escape(key) + r'\s*=\s*)[^\n]+$',
                           lambda m: m[1] + json.dumps(destination), source)
    expected = deepcopy(original)
    expected['kernel'][key] = destination
    if count != 1 or tomllib.loads(result) != expected:
        raise ValueError(f'Unable to adapt exactly one {key} without changing guest resources')
    return result


def kernel_path(source, destination):
    return kernel_field(source, 'kernel_path', destination)


def physical_root(config, partition, label):
    if partition < 1:
        raise ValueError('Root partition number must be positive')
    package = config.parent.parent
    changed = []
    for path in sorted(package.rglob('*.toml')):
        data = required(path)
        guest = tomllib.loads(data)
        cmdline = guest.get('kernel', {}).get('cmdline', '')
        match = re.search(r'(?<!\S)root=/dev/(mmcblk[0-9]+)p[0-9]+(?=\s|$)', cmdline)
        if not match:
            continue
        selector = ('PARTLABEL=' + label if label != '-' and re.fullmatch(r'[A-Za-z0-9_.-]+', label or '')
                    else f'/dev/{match[1]}p{partition}')
        cmdline = cmdline[:match.start()] + 'root=' + selector + cmdline[match.end():]
        path.write_text(kernel_field(data, 'cmdline', cmdline))
        changed.append(PREFIX + path.relative_to(package).as_posix())
    manifest_path = package / 'manifest.json'
    if manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text())
        manifest['physical_root'] = dict(partition=partition, label=label, configurations=changed)
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    checksums = []
    for path in sorted(package.rglob('*')):
        if path.is_file() and not path.is_symlink() and path.name != 'SHA256SUMS':
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            checksums.append(f'{digest}  ./{path.relative_to(package).as_posix()}\n')
    (package / 'SHA256SUMS').write_text(''.join(checksums))


def stage(source, output, network_configs):
    manifest_path = output / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    updates = []
    prebuilt = []
    for original, installed, binary in (
        (source / BOARD / SHELL, Path('board-ballpick-robot') / SHELL, 'arceos-vm-shell.bin'),
        (source / SINGLE, Path('robot-single/guest.toml'), 'starry-robot-single.bin'),
    ):
        data = required(original)
        artifact = Path('guests') / binary
        required(output / artifact)
        updates.append((installed, kernel_path(data, PREFIX + artifact.as_posix())))
        with (output / artifact).open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        prebuilt.append(dict(config=PREFIX + installed.as_posix(),
                             kernel=PREFIX + artifact.as_posix(),
                             source_config=str(original.relative_to(source)),
                             source_sha256=hashlib.sha256(data.encode()).hexdigest(),
                             kernel_sha256=digest))
    generated = []
    for n in range(1, 65):
        data = required(network_configs / f'vm{n}.toml')
        config = tomllib.loads(data)
        if config['base']['id'] != n:
            raise ValueError(f'Generated vm{n}.toml has a different VM id')
        installed = Path('board-ballpick-robot') / NETWORK / f'vm{n}.toml'
        updates.append((installed, kernel_path(data, '/guest/arceos/orangepi-5-plus')))
        generated.append(PREFIX + installed.as_posix())
    # Validate every input before changing the private package tree.
    for installed, data in updates:
        target = output / installed
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(data)
    deployed = [PREFIX + path.as_posix() for path, _ in updates]
    manifest['runtime_guest_configs'] = sorted(set(manifest['runtime_guest_configs'] + deployed))
    manifest['source_dependent_guest_configs'] = [p for p in manifest['source_dependent_guest_configs'] if p not in deployed]
    for scenario, references in list(manifest['source_dependent_scenarios'].items()):
        if references and all(p.startswith('target/axvisor-arceos-net-scale/vm') for p in references):
            by_name = {Path(path).name: path for path in generated}
            manifest['scenarios'][scenario] = [by_name[Path(p).name] for p in references] + manifest['scenarios'].get(scenario, [])
            del manifest['source_dependent_scenarios'][scenario]
    manifest['prebuilt_guests'] = prebuilt
    manifest['network_guest_kernel'] = '/guest/arceos/orangepi-5-plus'
    manifest['generated_network_configs'] = generated
    manifest['dedicated_validation'] = dict(task_switch='Use the dedicated axvm task_switch kernel-test host; normal VM startup does not set its FIFO host policy.')
    lock = source / 'Cargo.lock'
    if lock.is_file():
        manifest['source_lock_sha256'] = hashlib.sha256(lock.read_bytes()).hexdigest()
    if (source / '.git').exists():
        manifest['source_dirty'] = bool(subprocess.check_output(['git', '-C', source, 'status', '--porcelain']))
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, nargs='?')
    parser.add_argument('output', type=Path, nargs='?')
    parser.add_argument('--network-configs', type=Path)
    parser.add_argument('--physical-root-config', type=Path)
    parser.add_argument('--root-partition', type=int)
    parser.add_argument('--root-label', default='')
    args = parser.parse_args()
    try:
        if args.physical_root_config:
            if args.root_partition is None:
                parser.error('--root-partition is required with --physical-root-config')
            physical_root(args.physical_root_config, args.root_partition, args.root_label)
        else:
            if not (args.source and args.output and args.network_configs):
                parser.error('source, output and --network-configs are required')
            stage(args.source, args.output, args.network_configs)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit(f'AxVisor payloads: {error}')
