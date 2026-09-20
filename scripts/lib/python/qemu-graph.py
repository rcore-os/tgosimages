#!/usr/bin/env python3
"""Adapt QEMU's existing argument parser and executable steps to a flat graph."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
PYTHON_LIB = Path(__file__).resolve().parent
SHELL_LIB = PYTHON_LIB.parent
ROOT = PYTHON_LIB.parents[2]
spec = importlib.util.spec_from_file_location('build_graph', PYTHON_LIB / 'build-graph.py')
scheduler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scheduler)
rootfs_spec = importlib.util.spec_from_file_location('rootfs_graph', PYTHON_LIB / 'rootfs-graph.py')
rootfs_graph = importlib.util.module_from_spec(rootfs_spec)
rootfs_spec.loader.exec_module(rootfs_graph)


def make_graph(arch, args, log_dir):
    args = list(args)
    log_dir = Path(log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    if args[0].startswith('--'):
        args.insert(0, 'all')
    guest_count = None if args[0] == 'clean' else rootfs_graph.guest_count()
    arches = ['aarch64', 'riscv64', 'x86_64', 'loongarch64'] if arch == 'all' else [arch]
    root = Path(os.environ.get('BUILD_WORKSPACE_ROOT', ROOT / 'build/workspaces')).resolve()
    cache = Path(os.environ.get('BUILD_CACHE_DIR', ROOT / 'build/.cache')).resolve()
    graph = {'cwd': str(ROOT), 'tasks': [], 'locks': []}
    groups = []
    for target in arches:
        name = f'qemu-{target}'
        workspace = root / name
        workspace.mkdir(parents=True, exist_ok=True)
        if workspace.resolve() != workspace:
            raise ValueError(f'Workspace must not be a symlink: {workspace}')
        for key in ('ARCEOS_SRC_DIR', 'FREERTOS_SRC_DIR', 'FREERTOS_KERNEL_SRC_DIR',
                    'ZEPHYR_SRC_DIR', 'STARRY_SRC_DIR', 'RTTHREAD_SRC_DIR', 'BUSYBOX_SRC_DIR',
                    'AXVISOR_TOOLS_SRC_DIR', 'ROOTFS_TEST_BUILD_ROOT'):
            if os.environ.get(key) and workspace not in Path(os.environ[key]).resolve().parents:
                raise ValueError(f'Mutable source path escapes workspace {name}: {key}={os.environ[key]}')
        env = dict(BUILD_WORKSPACE_NAME=name, BUILD_WORK_DIR=str(workspace),
                   BUILD_CACHE_DIR=str(cache), BUILD_SOURCE_CACHE_DIR=os.environ.get('BUILD_SOURCE_CACHE_DIR', str(cache / 'git')),
                   ROOTFS_TEST_BUILD_ROOT=os.environ.get('ROOTFS_TEST_BUILD_ROOT', str(workspace / 'rootfs-tests')),
                   QEMU_GRAPH_INTERNAL='execute', LOG_CREATE_DEFAULT_FILE='0')
        if guest_count is not None:
            env['ROOTFS_GUEST_COUNT'] = str(guest_count)
        command = ['bash', str(ROOT / 'scripts/platform/qemu.sh'), target, *args]
        description = log_dir / f'{name}.json'
        plan_env = dict(os.environ, **env)
        plan_env.update(QEMU_GRAPH_INTERNAL='describe', QEMU_GRAPH_DESCRIPTION=str(description),
                        LOG_STDIO_CAPTURED='1', LOG_COLOR='never')
        plan_env.pop('LOG_FILE', None)
        with (log_dir / f'{name}-plan.log').open('w') as stream:
            result = subprocess.run(command, env=plan_env, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise ValueError((log_dir / f'{name}-plan.log').read_text())
        steps = json.loads(description.read_text())
        nodes = []
        for step in steps:
            match = re.fullmatch(r'qemu_rootfs_(busybox|alpine|debian)_step', step)
            node = {'id': f'{name}.{step}', 'command': command,
                    'env': dict(env, QEMU_GRAPH_STEP=step)}
            if match and os.environ.get('ROOTFS_GRAPH_DISABLE') != '1':
                rootfs_type = match.group(1)
                base_dir = workspace / 'rootfs-bases' / rootfs_type
                base = {'id': f'{name}.rootfs.{rootfs_type}.base', 'command': command,
                        'env': dict(env, QEMU_GRAPH_STEP=step, ROOTFS_GRAPH_BASE_ONLY='1',
                                    ROOTFS_GRAPH_OUTPUT_DIR=str(base_dir))}
                node['deps'] = [base['id']]
                node['command'] = ['bash', str(SHELL_LIB / 'rootfs-compose-node.sh'), target, rootfs_type,
                    str(base_dir), str(ROOT / 'IMAGES/rootfs'), '', '',
                    rootfs_graph.option(args, '--guest-free-size') or '256M',
                    rootfs_graph.option(args, '--outer-free-size') or '256M']
                nodes.append(base)
                expanded = rootfs_graph.expand(node, f'{name}.rootfs.{rootfs_type}', target,
                                               rootfs_type, args)
                node['command'][6] = node['env']['ROOTFS_PREBUILT_OUTER_TEST_OVERLAY']
                node['command'][7] = node['env']['ROOTFS_PREBUILT_GUEST_TEST_OVERLAY']
                nodes.extend(expanded)
                nodes.append(node)
            else:
                nodes.append(node)
        nodes.append({'id': f'{name}.compose', 'deps': [n['id'] for n in nodes],
                      'command': command, 'env': dict(env, QEMU_GRAPH_STEP='qemu_rootfs_inject_platform_dir')})
        groups.append(nodes)
        graph['locks'].append(str(root / '.locks' / f'{name}.lock'))
        graph['locks'].append(str(ROOT / 'build/.locks' / f'platform-{name}.lock'))
    # Round-robin architecture order keeps initial CPU allocation balanced without
    # reserving tokens for a whole architecture after its component tasks finish.
    for index in range(max(map(len, groups))):
        graph['tasks'].extend(group[index] for group in groups if index < len(group))
    return graph


def main():
    arch, *args = sys.argv[1:]
    log_root = Path(os.environ.get('LOG_DIR', ROOT / 'logs/platform'))
    log_root.mkdir(parents=True, exist_ok=True)
    log_dir = Path(tempfile.mkdtemp(prefix='qemu-graph-', dir=log_root)).resolve()
    return scheduler.execute(make_graph(arch, args, log_dir), log_dir)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'QEMU graph: {exc}', file=sys.stderr)
        sys.exit(1)
