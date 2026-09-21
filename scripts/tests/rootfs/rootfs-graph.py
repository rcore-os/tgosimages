#!/usr/bin/env python3
"""Exercise plugin leaves, overlay joins, and their consuming rootfs node."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / 'scripts/lib/python'
spec = importlib.util.spec_from_file_location('rootfs_graph', LIB / 'rootfs-graph.py')
rootfs_graph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rootfs_graph)
qemu_spec = importlib.util.spec_from_file_location('qemu_graph', LIB / 'qemu-graph.py')
qemu_graph = importlib.util.module_from_spec(qemu_spec)
qemu_spec.loader.exec_module(qemu_graph)
platform_spec = importlib.util.spec_from_file_location('platform_graph', LIB / 'platform-graph.py')
platform_graph = importlib.util.module_from_spec(platform_spec)
platform_spec.loader.exec_module(platform_graph)


class RootfsGraph(unittest.TestCase):
    def test_guest_count_environment_contract(self):
        with mock.patch.dict(os.environ, {'ROOTFS_GUEST_COUNT': '3'}, clear=True):
            self.assertEqual(rootfs_graph.guest_count(), 3)
        with mock.patch.dict(os.environ, {'ROOTFS_GUEST_COUNT': '999999999999999999999999'}, clear=True):
            self.assertEqual(rootfs_graph.guest_count(), 999999999999999999999999)
        for value in ('', '0', '-2', '2x'):
            with self.subTest(value=value), \
                    mock.patch.dict(os.environ, {'ROOTFS_GUEST_COUNT': value}, clear=True):
                with self.assertRaises(ValueError):
                    rootfs_graph.guest_count()

    def test_plugins_are_leaf_nodes_and_consumer_waits_for_merged_overlays(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            plugins = work / 'plugins'
            plugins.mkdir()
            for name in ('alpha', 'beta'):
                script = plugins / f'{name}.sh'
                script.write_text(f'''#!/usr/bin/env bash
set -eu
if [[ $1 == describe ]]; then
  printf '%s\\n' 'name={name}' 'arches=x86_64' 'rootfs=busybox' 'scopes=outer,guest'
  exit
fi
shift
while (($#)); do
  case $1 in --scope) scope=$2; shift 2;; --output) output=$2; shift 2;; *) shift;; esac
done
mkdir -p "$output"
printf '{name}-%s\\n' "$scope" >"$output/{name}-$scope"
''')
                script.chmod(0o755)
            env = dict(os.environ, ROOTFS_TEST_PLUGIN_DIR=str(plugins), TGOS_BUILD_JOB_BUDGET='4',
                       BUILD_PARALLEL_TASKS='4', BUILD_CACHE_DIR=str(work / 'cache'), LOG_COLOR='never')
            old = os.environ.get('ROOTFS_TEST_PLUGIN_DIR')
            os.environ['ROOTFS_TEST_PLUGIN_DIR'] = str(plugins)
            try:
                task = dict(id='rootfs.image', deps=[], env={'BUILD_WORK_DIR': str(work / 'workspace')},
                            command=['bash', '-c',
                                'test -f "$ROOTFS_PREBUILT_OUTER_TEST_OVERLAY/alpha-outer"; '
                                'test -f "$ROOTFS_PREBUILT_OUTER_TEST_OVERLAY/beta-outer"; '
                                'test -f "$ROOTFS_PREBUILT_GUEST_TEST_OVERLAY/alpha-guest"; '
                                'test -f "$ROOTFS_PREBUILT_GUEST_TEST_OVERLAY/beta-guest"'])
                tasks = rootfs_graph.expand(task, 'rootfs.busybox', 'x86_64', 'busybox',
                                            ['--outer-tests', 'all', '--guest-tests', 'all'])
            finally:
                if old is None:
                    os.environ.pop('ROOTFS_TEST_PLUGIN_DIR', None)
                else:
                    os.environ['ROOTFS_TEST_PLUGIN_DIR'] = old
            tasks.append(task)
            manifest = work / 'graph.json'
            manifest.write_text(json.dumps({'cwd': str(ROOT), 'tasks': tasks}))
            result = subprocess.run([sys.executable, str(LIB / 'build-graph.py'), str(manifest),
                                     '--log-dir', str(work / 'logs')], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout)
            states = json.loads((work / 'logs/state.json').read_text())
            self.assertEqual(states['rootfs.image']['state'], 'success')
            self.assertEqual(sum('.tests.' in name for name in states), 4)
            self.assertEqual(sum('.overlay.' in name for name in states), 2)

            result = subprocess.run([sys.executable, str(LIB / 'build-graph.py'), str(manifest),
                                     '--log-dir', str(work / 'logs-second')], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout)
            states = json.loads((work / 'logs-second/state.json').read_text())
            cached = [state['state'] for name, state in states.items()
                      if '.tests.' in name or '.overlay.' in name]
            self.assertEqual(cached, ['hit'] * 6)

            (plugins / 'alpha.sh').write_text((plugins / 'alpha.sh').read_text() + '\n# changed\n')
            result = subprocess.run([sys.executable, str(LIB / 'build-graph.py'), str(manifest),
                                     '--log-dir', str(work / 'logs-third')], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout)
            states = json.loads((work / 'logs-third/state.json').read_text())
            self.assertEqual(states['rootfs.busybox.tests.outer.alpha']['state'], 'success')
            self.assertEqual(states['rootfs.busybox.tests.guest.alpha']['state'], 'success')
            self.assertEqual(states['rootfs.busybox.tests.outer.beta']['state'], 'hit')
            self.assertEqual(states['rootfs.busybox.tests.guest.beta']['state'], 'hit')
            self.assertEqual(states['rootfs.busybox.overlay.outer']['state'], 'hit')
            self.assertEqual(states['rootfs.busybox.overlay.guest']['state'], 'hit')

    def test_qemu_rootfs_uses_cached_prepare_compose_and_final_publish_phases(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)

            def describe(_command, **kwargs):
                Path(kwargs['env']['QEMU_GRAPH_DESCRIPTION']).write_text(
                    json.dumps(['linux', 'qemu_rootfs_busybox_step']))
                return subprocess.CompletedProcess([], 0)

            environment = {
                'BUILD_WORKSPACE_ROOT': str(work / 'workspaces'),
                'BUILD_CACHE_DIR': str(work / 'cache'),
            }
            with mock.patch.dict(os.environ, environment, clear=False), \
                    mock.patch.object(qemu_graph.subprocess, 'run', side_effect=describe):
                graph = qemu_graph.make_graph(
                    'aarch64', ['all', '--outer-tests', 'none', '--guest-tests', 'none'],
                    work / 'logs')

            tasks = {task['id']: task for task in graph['tasks']}
            base = tasks['qemu-aarch64.rootfs.busybox.base']
            image = tasks['qemu-aarch64.qemu_rootfs_busybox_step']
            publish = tasks['qemu-aarch64.compose']
            self.assertEqual(base['phase'], 'prepare')
            self.assertIn('--output', base['cache_args'])
            self.assertEqual(image['phase'], 'compose')
            self.assertIn(str(work / 'workspaces/qemu-aarch64/rootfs-staged'), image['command'])
            self.assertEqual(publish['phase'], 'compose')
            self.assertEqual(publish['env']['QEMU_ROOTFS_STAGE_DIR'],
                             str(work / 'workspaces/qemu-aarch64/rootfs-staged'))
            self.assertEqual(publish['env']['QEMU_REQUIRED_GUEST_FILES'], 'linux/linux-qemu')

    def test_qemu_os_build_nodes_share_the_task_cache_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)

            def describe(_command, **kwargs):
                Path(kwargs['env']['QEMU_GRAPH_DESCRIPTION']).write_text(
                    json.dumps(['linux', 'arceos', 'zephyr', 'freertos']))
                return subprocess.CompletedProcess([], 0)

            with mock.patch.dict(os.environ, {
                    'BUILD_WORKSPACE_ROOT': str(work / 'workspaces'),
                    'BUILD_CACHE_DIR': str(work / 'cache'),
            }, clear=False), mock.patch.object(qemu_graph.subprocess, 'run', side_effect=describe):
                graph = qemu_graph.make_graph('aarch64', ['all'], work / 'logs')

            tasks = {task['id']: task for task in graph['tasks']}
            expected = {
                'linux': {
                    'ref': 'LINUX_REF=74fe02ce122a6103f207d29fafc8b3a53de6abaf',
                    'patch': ROOT / 'patches/qemu',
                    'outputs': ['linux-qemu'],
                },
                'arceos': {
                    'ref': 'ARCEOS_REF=2703515cd40f753a205f2b7c26d44cd1b44853b8',
                    'patch': ROOT / 'patches/arceos',
                    'outputs': ['arceos-qemu'],
                },
                'zephyr': {
                    'ref': 'ZEPHYR_REF=30bef2a126198f73ecc1f8a90590579e03379b18',
                    'patch': ROOT / 'patches/zephyr',
                    'outputs': ['zephyr-qemu', 'zephyr-qemu.elf'],
                },
                'freertos': {
                    'ref': 'FREERTOS_REF=3458360e7e038ca84a28c678e9bb7e967c565d87',
                    'patch': ROOT / 'patches/freertos',
                    'outputs': ['freertos-qemu.bin', 'freertos-qemu.elf'],
                },
            }
            for step, contract in expected.items():
                with self.subTest(step=step):
                    task = tasks[f'qemu-aarch64.{step}']
                    values = [task['cache_args'][index + 1]
                              for index, value in enumerate(task['cache_args'])
                              if value == '--value']
                    patches = [task['cache_args'][index + 1]
                               for index, value in enumerate(task['cache_args'])
                               if value == '--patch-dir']
                    outputs = [task['cache_args'][index + 1]
                               for index, value in enumerate(task['cache_args'])
                               if value == '--output']
                    self.assertIn(contract['ref'], values)
                    self.assertEqual(patches, [str(contract['patch'])])
                    self.assertEqual(outputs, [str(ROOT / f'IMAGES/qemu-aarch64/{step}/{name}')
                                               for name in contract['outputs']])

    def test_qemu_custom_os_commands_are_not_cached_as_full_builds(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)

            def describe(_command, **kwargs):
                Path(kwargs['env']['QEMU_GRAPH_DESCRIPTION']).write_text(json.dumps(['linux']))
                return subprocess.CompletedProcess([], 0)

            with mock.patch.dict(os.environ, {
                    'BUILD_WORKSPACE_ROOT': str(work / 'workspaces'),
                    'BUILD_CACHE_DIR': str(work / 'cache'),
            }, clear=False), mock.patch.object(qemu_graph.subprocess, 'run', side_effect=describe):
                graph = qemu_graph.make_graph('aarch64', ['linux', 'clean'], work / 'logs')

            linux = next(task for task in graph['tasks'] if task['id'] == 'qemu-aarch64.linux')
            self.assertNotIn('cache_args', linux)

    def test_orangepi_guest_rootfs_is_prepared_in_workspace_then_published(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            declaration = json.loads((ROOT / 'scripts/lib/platform-tasks.json').read_text())[
                'orangepi-5-plus']
            with mock.patch.dict(os.environ, {
                    'BUILD_WORKSPACE_ROOT': str(work / 'workspaces'),
                    'BUILD_CACHE_DIR': str(work / 'cache'),
                    'ORANGEPI_GUEST_ROOTFS': str(work / 'images/rootfs-aarch64-orangepi-jammy.img'),
            }, clear=False):
                graph = platform_graph.board_graph('orangepi-5-plus', declaration,
                    ['rootfs', '--outer-tests', 'none', '--guest-tests', 'none'])

            tasks = {task['id']: task for task in graph['tasks']}
            linux = tasks['orangepi-5-plus.linux']
            uboot_deb = tasks['orangepi-5-plus.orangepi_uboot_deb']
            base = tasks['orangepi-5-plus.rootfs.base']
            image = tasks['orangepi-5-plus.rootfs']
            prepared = work / 'workspaces/orangepi-5-plus/rootfs-bases/orangepi-jammy.img'
            self.assertEqual(base['phase'], 'prepare')
            self.assertEqual(base['env']['ORANGEPI_GUEST_ROOTFS'], str(prepared))
            self.assertEqual(uboot_deb['deps'], [linux['id']])
            self.assertEqual(base['deps'], [uboot_deb['id']])
            self.assertIn(str(work / 'workspaces/orangepi-5-plus/orangepi/output/debs'),
                          base['cache_args'])
            self.assertEqual(image['phase'], 'compose')
            self.assertEqual(image['command'][-1], str(work / 'images/rootfs-aarch64-orangepi-jammy.img'))
            self.assertIn('--output', image['cache_args'])

            with mock.patch.dict(os.environ, {
                    'BUILD_WORKSPACE_ROOT': str(work / 'workspaces'),
                    'BUILD_CACHE_DIR': str(work / 'cache'),
                    'ORANGEPI_GUEST_ROOTFS': str(work / 'images/rootfs-aarch64-orangepi-jammy.img'),
            }, clear=False):
                graph = platform_graph.board_graph('orangepi-5-plus', declaration,
                    ['all', '--outer-tests', 'none', '--guest-tests', 'none'])
            tasks = {task['id']: task for task in graph['tasks']}
            final = tasks['orangepi-5-plus.finalize_linux_image']
            self.assertEqual(final['phase'], 'compose')
            self.assertIn('--output', final['cache_args'])


if __name__ == '__main__':
    unittest.main()
