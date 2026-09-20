#!/usr/bin/env python3
"""Expand rootfs test selections into plugin leaves and overlay merge nodes."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

PYTHON_LIB = Path(__file__).resolve().parent
SHELL_LIB = PYTHON_LIB.parent
ROOT = PYTHON_LIB.parents[2]
TEST_BUILD = ROOT / 'scripts/rootfs-test-plugins/build.sh'
if str(PYTHON_LIB) not in sys.path:
    sys.path.insert(0, str(PYTHON_LIB))
from build_pipeline import phase_task
PLUGIN_CACHE_ENV = [
    'ALPINE_LTP_CFLAGS', 'ALPINE_LTP_FILTER_OUT_DIRS', 'ALPINE_LTP_FILTER_OUT_TESTS',
    'ALPINE_LTP_LDFLAGS', 'ALPINE_LTP_SHA256', 'ALPINE_LTP_URL', 'CC',
    'CYCLICTEST_NM', 'CYCLICTEST_OBJDUMP', 'CYCLICTEST_SOURCE_SHA256',
    'CYCLICTEST_SOURCE_URL', 'IOZONE_SOURCE_SHA256', 'IOZONE_SOURCE_URL',
    'LMBENCH_SOURCE_SHA256', 'LMBENCH_SOURCE_URL', 'PATH',
    'ROOTFS_TEST_ALPINE_BUILDER', 'ROOTFS_TEST_BUILD_JOBS',
    'ROOTFS_TEST_GLIBC_STATIC_BUILDER', 'ROOTFS_TEST_OFFLINE_FIXTURE_DIR',
]


def plugin_framework_inputs():
    plugin_root = TEST_BUILD.parent / 'plugins'
    return [str(path) for path in sorted(TEST_BUILD.parent.rglob('*'))
            if path.is_file() and plugin_root not in path.parents]


def guest_count():
    value = os.environ.get('ROOTFS_GUEST_COUNT', '2')
    if not value.isascii() or not value.isdecimal():
        raise ValueError('ROOTFS_GUEST_COUNT must be a positive decimal integer')
    count = int(value, 10)
    if count < 1:
        raise ValueError('ROOTFS_GUEST_COUNT must be at least 1')
    return count


def option(args, name):
    result = None
    index = 0
    while index < len(args):
        if args[index] == name:
            if index + 1 >= len(args):
                raise ValueError(f'{name} requires a value')
            result = args[index + 1]
            index += 2
        else:
            index += 1
    return result


def query(command, arch, rootfs_type, scope):
    result = subprocess.run(['bash', str(TEST_BUILD), command, '--arch' if command == 'list' else '--rootfs',
                             arch if command == 'list' else rootfs_type,
                             *(['--rootfs', rootfs_type] if command == 'list' else []), '--scope', scope],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f'cannot resolve {rootfs_type}/{scope} tests')
    return [line for line in result.stdout.splitlines() if line]


def selection(arch, rootfs_type, scope, requested=None):
    if requested is None:
        defaults = query('defaults', arch, rootfs_type, scope)
        requested = defaults[0] if defaults else 'none'
    if requested == 'none':
        return []
    available = query('list', arch, rootfs_type, scope)
    selected = available if requested == 'all' else requested.split(',')
    if not selected or any(not item or item not in available for item in selected) or len(selected) != len(set(selected)):
        raise ValueError(f'invalid tests for {arch}/{rootfs_type}/{scope}: {requested}')
    return selected


def expand(task, prefix, arch, rootfs_type, args, guest_default=None):
    """Return leaf/merge nodes and mutate the consuming task's deps/env."""
    workspace = Path(task['env']['BUILD_WORK_DIR'])
    root = workspace / 'rootfs-nodes' / arch / rootfs_type
    requested = {
        'outer': option(args, '--outer-tests'),
        'guest': option(args, '--guest-tests') or guest_default,
    }
    nodes = []
    merge_ids = []
    overlays = {}
    plugin_directory = Path(os.environ.get('ROOTFS_TEST_PLUGIN_DIR', TEST_BUILD.parent / 'plugins')).resolve()
    framework_inputs = plugin_framework_inputs()
    compiler = f'{arch}-linux-gnu-gcc' if arch != 'x86_64' else 'x86_64-linux-gnu-gcc'
    plugin_tools = [compiler] if shutil.which(compiler) else []
    safe_prefix = re.sub(r'[^A-Za-z0-9_.-]', '-', prefix)
    for scope in ('outer', 'guest'):
        plugins = selection(arch, rootfs_type, scope, requested[scope])
        plugin_nodes = []
        plugin_outputs = []
        for plugin in plugins:
            node_id = f'{safe_prefix}.tests.{scope}.{plugin}'
            output = root / scope / plugin
            plugin_nodes.append(node_id)
            plugin_outputs.append(str(output))
            command = ['bash', str(SHELL_LIB / 'rootfs-test-node.sh'), str(output),
                       'bash', str(TEST_BUILD), 'build', '--arch', arch, '--rootfs', rootfs_type,
                       '--scope', scope, '--tests', plugin]
            nodes.append(phase_task(node_id, 'build', command,
                env=task['env'], resources=[], cache={
                    'inputs': [*framework_inputs, str(SHELL_LIB / 'rootfs-test-node.sh'),
                               str(plugin_directory / f'{plugin}.sh')],
                    'outputs': [str(output)],
                    'environment': PLUGIN_CACHE_ENV,
                    'tools': plugin_tools,
                }))
        merge_id = f'{safe_prefix}.overlay.{scope}'
        merged = root / f'{scope}-merged'
        merge_command = ['python3', str(PYTHON_LIB / 'rootfs-overlay-merge.py'),
                         '--output', str(merged), *plugin_outputs]
        nodes.append(phase_task(merge_id, 'compose', merge_command,
            deps=plugin_nodes, env=task['env'], cache={
                'inputs': [str(PYTHON_LIB / 'rootfs-overlay-merge.py'), *plugin_outputs],
                'outputs': [str(merged)],
            }))
        merge_ids.append(merge_id)
        overlays[scope] = str(merged)
    task.setdefault('deps', []).extend(merge_ids)
    task['env'] = dict(task['env'], ROOTFS_PREBUILT_OUTER_TEST_OVERLAY=overlays['outer'],
                       ROOTFS_PREBUILT_GUEST_TEST_OVERLAY=overlays['guest'])
    return nodes
