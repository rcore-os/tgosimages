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

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'scripts/lib'
spec = importlib.util.spec_from_file_location('rootfs_graph', LIB / 'rootfs-graph.py')
rootfs_graph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rootfs_graph)


class RootfsGraph(unittest.TestCase):
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
            env = dict(os.environ, ROOTFS_TEST_PLUGIN_DIR=str(plugins), BUILD_JOBS='4',
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


if __name__ == '__main__':
    unittest.main()
