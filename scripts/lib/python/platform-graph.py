#!/usr/bin/env python3
"""Merge platform declarations into one scheduler invocation."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
PYTHON_LIB = Path(__file__).resolve().parent
if str(PYTHON_LIB) not in sys.path:
    sys.path.insert(0, str(PYTHON_LIB))
from build_pipeline import cache_arguments, phase_task
SHELL_LIB = PYTHON_LIB.parent
ROOT = PYTHON_LIB.parents[2]
spec = importlib.util.spec_from_file_location('qemu_graph', PYTHON_LIB / 'qemu-graph.py')
qemu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qemu)
rootfs_spec = importlib.util.spec_from_file_location('rootfs_graph', PYTHON_LIB / 'rootfs-graph.py')
rootfs_graph = importlib.util.module_from_spec(rootfs_spec)
rootfs_spec.loader.exec_module(rootfs_graph)


def board_graph(name, declaration, args):
    action, *options = args or ['all']
    components = declaration['components']
    if action not in ['all', 'clean', *components] or action in declaration.get('private', []):
        raise ValueError(f'Unknown command for {name}: {action}')
    guest_count = rootfs_graph.guest_count() if name == 'orangepi-5-plus' and action != 'clean' else None
    workspace_root = Path(os.environ.get('BUILD_WORKSPACE_ROOT', ROOT / 'build/workspaces')).resolve()
    workspace = workspace_root / name
    workspace.mkdir(parents=True, exist_ok=True)
    if workspace.resolve() != workspace:
        raise ValueError(f'Workspace must not be a symlink: {workspace}')
    for key in ('ARCEOS_SRC_DIR', 'FREERTOS_SRC_DIR', 'FREERTOS_KERNEL_SRC_DIR', 'ZEPHYR_SRC_DIR',
                'STARRY_SRC_DIR', 'RTTHREAD_SRC_DIR', 'BUSYBOX_SRC_DIR', 'TGOSKITS_SRC_DIR',
                'ROOTFS_TEST_BUILD_ROOT', 'ORANGEPI_UBOOT_WORKDIR', 'ORANGEPI_BASE_IMAGE', 'IVC_BUILD_DIR'):
        if os.environ.get(key) and workspace not in Path(os.environ[key]).resolve().parents:
            raise ValueError(f'Mutable path escapes workspace {name}: {key}')
    cache = Path(os.environ.get('BUILD_CACHE_DIR', ROOT / 'build/.cache')).resolve()
    env = dict(PLATFORM_GRAPH_INTERNAL='1', BUILD_WORKSPACE_NAME=name, BUILD_WORK_DIR=str(workspace),
               BUILD_CACHE_DIR=str(cache), BUILD_SOURCE_CACHE_DIR=os.environ.get('BUILD_SOURCE_CACHE_DIR', str(cache / 'git')),
               ROOTFS_TEST_BUILD_ROOT=str(workspace / 'rootfs-tests'))
    if guest_count is not None:
        env['ROOTFS_GUEST_COUNT'] = str(guest_count)
    graph = dict(tasks=[], locks=[str(workspace_root / '.locks' / f'{name}.lock'),
                                 str(ROOT / 'build/.locks' / f'platform-{name}.lock')])
    if action == 'clean':
        graph['tasks'].append(dict(id=f'{name}.clean', command=['bash', str(ROOT / f'scripts/platform/{name}.sh'), 'clean'], env=env))
        return graph
    dependencies = declaration.get('deps', {})
    selected = set(components if action == 'all' else [action])
    # Injection requires an image built from this invocation's Linux inputs.
    if declaration.get('compose'):
        selected.add('linux')
    def include(step):
        for dep in dependencies.get(step, []):
            if dep not in selected:
                selected.add(dep)
                include(dep)
    for step in list(selected):
        include(step)
    for step in components:
        if step not in selected:
            continue
        phase = 'compose' if name == 'orangepi-5-plus' and step == 'finalize_linux_image' else 'build'
        cache = None
        if phase == 'compose':
            platform_images = ROOT / 'IMAGES/orangepi'
            rootfs_type = os.environ.get('ORANGEPI_ROOTFS_TYPE', 'orangepi-jammy')
            guest_image = os.environ.get('ORANGEPI_GUEST_ROOTFS',
                str(ROOT / f'IMAGES/rootfs/rootfs-aarch64-{rootfs_type}.img'))
            base_image = os.environ.get('ORANGEPI_BASE_IMAGE',
                str(workspace / 'orangepi-rootfs/orangepi-5-plus-base.img'))
            cache = {
                'inputs': [base_image, guest_image,
                           *[str(platform_images / component) for component in
                             ('linux', 'u-boot', 'arceos', 'starry', 'zephyr', 'freertos', 'ivc')],
                           str(ROOT / 'scripts/platform/orangepi-5-plus.sh'),
                           str(SHELL_LIB / 'rootfs-disk.sh'), str(SHELL_LIB / 'rootfs-compose.sh')],
                'outputs': [str(ROOT / 'IMAGES/rootfs/orangepi-5-plus.img')],
                'environment': ['ORANGEPI_GUEST_FREE_SIZE', 'ORANGEPI_OUTER_FREE_SIZE',
                                'ORANGEPI_ROOTFS_TYPE', 'ROOTFS_GUEST_COUNT'],
            }
        graph['tasks'].append(phase_task(f'{name}.{step}', phase,
            ['bash', str(SHELL_LIB / 'platform-node.sh'), name, step, *options],
            deps=[f'{name}.{dep}' for dep in dependencies.get(step, [])], env=env,
            resources=declaration.get('resources', {}).get(step, []), cache=cache))
    if name == 'orangepi-5-plus' and action != 'clean' and os.environ.get('ROOTFS_GRAPH_DISABLE') != '1':
        rootfs_task = next((task for task in graph['tasks'] if task['id'] == f'{name}.rootfs'), None)
        if rootfs_task is not None:
            graph['tasks'].remove(rootfs_task)
            rootfs_type = os.environ.get('ORANGEPI_ROOTFS_TYPE', 'orangepi-jammy')
            guest_image = os.environ.get('ORANGEPI_GUEST_ROOTFS',
                str(ROOT / f'IMAGES/rootfs/rootfs-aarch64-{rootfs_type}.img'))
            prepared_image = workspace / f'rootfs-bases/{rootfs_type}.img'
            base_env = dict(rootfs_task['env'], ROOTFS_GRAPH_BASE_ONLY='1',
                            ORANGEPI_GUEST_ROOTFS=str(prepared_image))
            base_task = phase_task(f'{name}.rootfs.base', 'prepare', rootfs_task['command'],
                deps=rootfs_task['deps'], env=base_env, resources=rootfs_task['resources'], cache={
                    'inputs': [str(ROOT / 'scripts/platform/orangepi-5-plus.sh'),
                               str(SHELL_LIB / 'rootfs-compose.sh'), str(SHELL_LIB / 'rootfs.sh'),
                               str(SHELL_LIB / 'utils.sh')],
                    'mutable_inputs': [str(workspace / 'orangepi/output/debs'),
                                       str(workspace / 'orangepi/external/cache/rootfs')],
                    'outputs': [str(prepared_image)],
                    'environment': ['ORANGEPI_GUEST_FREE_SIZE', 'ORANGEPI_ROOTFS_TYPE',
                                    'ROOTFS_GUEST_COUNT'],
                    'patches': [str(ROOT / 'patches/orangepi')],
                })
            rootfs_task = phase_task(f'{name}.rootfs', 'compose',
                ['bash', str(SHELL_LIB / 'rootfs-guest-compose-node.sh'), str(prepared_image), '',
                 os.environ.get('ORANGEPI_GUEST_FREE_SIZE', '256M'), guest_image],
                deps=[base_task['id']], env=env)
            expanded = rootfs_graph.expand(rootfs_task, f'{name}.rootfs.{rootfs_type}',
                'aarch64', rootfs_type, options,
                guest_default=os.environ.get('ORANGEPI_GUEST_TESTS', 'cyclictest,lmbench,iozone'))
            rootfs_task['command'][3] = rootfs_task['env']['ROOTFS_PREBUILT_GUEST_TEST_OVERLAY']
            rootfs_task['cache_args'] = cache_arguments({
                'inputs': [str(prepared_image), rootfs_task['command'][3],
                           str(SHELL_LIB / 'rootfs-guest-compose-node.sh'),
                           str(SHELL_LIB / 'rootfs-compose.sh')],
                'outputs': [guest_image],
                'environment': ['ROOTFS_GUEST_COUNT'],
            })
            graph['tasks'] = expanded + [base_task, rootfs_task] + graph['tasks']
    if declaration.get('compose'):
        graph['tasks'].append(phase_task(f'{name}.compose', 'compose',
            ['bash', str(SHELL_LIB / 'platform-node.sh'), name, 'compose'],
            deps=[n['id'] for n in graph['tasks']], env=env))
    return graph


def main():
    target, *args = sys.argv[1:]
    target = target.removesuffix('.sh')
    declarations = json.loads((SHELL_LIB / 'platform-tasks.json').read_text())
    log_root = Path(os.environ.get('LOG_DIR', ROOT / 'logs/platform'))
    log_root.mkdir(parents=True, exist_ok=True)
    log_dir = Path(tempfile.mkdtemp(prefix='platform-graph-', dir=log_root)).resolve()
    groups = []
    graph = dict(cwd=str(ROOT), tasks=[], locks=[])
    targets = [*declarations, 'qemu'] if target == 'all' else [target]
    for name in targets:
        if name == 'qemu' or name.startswith('qemu-'):
            part = qemu.make_graph('all' if name == 'qemu' else name[5:], args or ['all'], log_dir)
        else:
            part = board_graph(name, declarations[name], args)
        for task in part['tasks']:
            task['locks'] = [*task.get('locks', []), *part['locks']]
        groups.append(part['tasks'])
    for index in range(max(map(len, groups))):
        graph['tasks'].extend(group[index] for group in groups if index < len(group))
    return qemu.scheduler.execute(graph, log_dir)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'Platform graph: {exc}', file=sys.stderr)
        sys.exit(1)
