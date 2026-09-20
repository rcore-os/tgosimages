#!/usr/bin/env python3
"""Check dependency/resource contracts with real subprocesses and task caching."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

LIB = Path(__file__).resolve().parents[1] / 'lib/python'


class GraphTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, BUILD_JOBS='4', BUILD_PARALLEL_TASKS='2',
                        BUILD_MEMORY_MB='2', LOG_COLOR='never', BUILD_CACHE_DIR=str(self.root / 'cache'))
        for key in ('TGOS_BUILD_JOB_BUDGET', 'BUILD_REBUILD', 'BUILD_CACHE', 'LOG_FILE'):
            self.env.pop(key, None)

    def node(self, name, code='pass', **kwargs):
        return dict(id=name, command=[sys.executable, '-c', code], **kwargs)

    def launch(self, tasks, **kwargs):
        manifest = self.root / 'graph.json'
        manifest.write_text(json.dumps(dict(cwd=str(self.root), tasks=tasks, **kwargs)))
        return subprocess.Popen([sys.executable, str(LIB / 'build-graph.py'), str(manifest),
                                 '--log-dir', str(self.root / 'logs')], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def finish(self, process, expected=0):
        output, _ = process.communicate(timeout=20)
        self.assertEqual(process.returncode, expected, output)
        return json.loads((self.root / 'logs/state.json').read_text())

    def test_dependencies_failure_and_launch_failure(self):
        tasks = [self.node('bad', 'raise SystemExit(7)'), self.node('independent'),
                 self.node('child', 'raise AssertionError("must not run")', deps=['bad']),
                 self.node('grandchild', deps=['child']),
                 dict(id='missing', command=['/does/not/exist']), self.node('after-missing', deps=['missing'])]
        states = self.finish(self.launch(tasks), 1)
        self.assertEqual(states['bad']['status'], 7)
        self.assertEqual(states['independent']['state'], 'success')
        for name in ('child', 'grandchild', 'after-missing'):
            self.assertEqual(states[name]['state'], 'blocked')

    def test_cpu_overlap_and_reallocation(self):
        code = '''import os,time
from pathlib import Path
name=os.environ['NAME']
Path(name).write_text(os.environ['TGOS_BUILD_JOB_BUDGET'])
deadline=time.monotonic()+5
while not Path(os.environ['PEER']).exists():
 if time.monotonic()>deadline: raise RuntimeError('tasks did not overlap')
 time.sleep(.01)
'''
        tasks = [self.node('first', code, env={'NAME': 'first', 'PEER': 'second'}),
                 self.node('second', code, env={'NAME': 'second', 'PEER': 'first'}),
                 self.node('join', 'import os; assert os.environ["TGOS_BUILD_JOB_BUDGET"]=="4"', deps=['first', 'second'])]
        self.finish(self.launch(tasks))
        self.assertEqual(sum(int((self.root / name).read_text()) for name in ('first', 'second')), 4)

    def test_memory_and_exclusive_resources(self):
        # O_EXCL detects real overlap instead of inspecting scheduler internals.
        code = '''import os,time
fd=os.open('exclusive',os.O_CREAT|os.O_EXCL|os.O_WRONLY)
time.sleep(.1)
os.close(fd)
os.unlink('exclusive')
'''
        for resources, memory in ((['source'], 0), ([], 2)):
            tasks = [self.node(str(n), code, resources=resources, memory_mb=memory) for n in range(3)]
            self.finish(self.launch(tasks))

    def test_cache_hit_unblocks_consumer(self):
        (self.root / 'input').write_text('source')
        code = "from pathlib import Path; Path('output').write_text(Path('input').read_text())"
        tasks = [self.node('cached', code, cache_args=['--input', 'input', '--output', 'output']),
                 self.node('consumer', "from pathlib import Path; assert Path('output').read_text()=='source'", deps=['cached'])]
        self.finish(self.launch(tasks))
        states = self.finish(self.launch(tasks))
        self.assertEqual(states['cached']['state'], 'hit')

    def test_invalid_graph_does_not_execute_and_signal_releases_lock(self):
        tasks = [self.node('cycle', "open('unexpected','w').close()", deps=['cycle'])]
        process = self.launch(tasks)
        output, _ = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0, output)
        self.assertFalse((self.root / 'unexpected').exists())
        tasks = [self.node('running', "import time; open('started','w').close(); time.sleep(30)")]
        lock = str(self.root / 'workspace.lock')
        process = self.launch(tasks, locks=[lock])
        deadline = time.monotonic() + 5
        while not (self.root / 'started').exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue((self.root / 'started').exists())
        process.send_signal(signal.SIGTERM)
        states = self.finish(process, 1)
        self.assertEqual(states['running']['state'], 'cancelled')
        self.finish(self.launch([self.node('after')], locks=[lock]))

    def test_invalid_late_environment_is_rejected_before_any_task(self):
        self.env['BUILD_PARALLEL_TASKS'] = '1'
        process = self.launch([self.node('first', "open('unexpected','w').close()"),
                               self.node('invalid', env={'BAD': 1})])
        output, _ = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0, output)
        self.assertFalse((self.root / 'unexpected').exists())

    def test_failed_leader_does_not_leave_background_writer(self):
        child = "import time; time.sleep(.6); open('late-output','w').close()"
        code = f'import subprocess,sys; subprocess.Popen([sys.executable,"-c",{child!r}]); sys.exit(7)'
        self.finish(self.launch([self.node('bad', code)]), 1)
        time.sleep(.7)
        self.assertFalse((self.root / 'late-output').exists())


if __name__ == '__main__':
    unittest.main()
