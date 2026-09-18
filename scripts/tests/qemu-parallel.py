#!/usr/bin/env python3
"""Exercise real QEMU dispatch with local Git sources and cheap build steps."""
import json
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ARCHES = ('aarch64', 'riscv64', 'x86_64', 'loongarch64')


def run(command, **kwargs):
    process = subprocess.Popen(command, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True, **kwargs)
    try:
        out, err = process.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise AssertionError('parallel build hung')
    return subprocess.CompletedProcess(command, process.returncode, out, err)


class QemuParallel(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.repo = self.work / 'repo'
        (self.repo / 'scripts/platform').mkdir(parents=True)
        shutil.copytree(ROOT / 'scripts/lib', self.repo / 'scripts/lib')
        shutil.copy2(ROOT / 'build.sh', self.repo / 'build.sh')
        for board in ('phytiumpi', 'roc-rk3568-pc', 'evm3588', 'tac-e400-plc',
                      'orangepi-5-plus', 'rdk-s100p', 'bst-a1000'):
            script = self.repo / f'scripts/platform/{board}.sh'
            script.write_text('#!/bin/bash\nprintf "compiler-output board\\n"\n'
                              '[[ ${PROBE_BOARD_FAIL:-0} != 1 ]] || exit 23\n')
            script.chmod(0o755)
        upstream = self.work / 'upstream'
        subprocess.run(['git', 'init', '-q', str(upstream)], check=True)
        (upstream / 'value').write_text('base\n')
        (upstream / '.gitignore').write_text('.config\n.patch_stamps/\n')
        subprocess.run(['git', '-C', str(upstream), 'add', '.'], check=True)
        git_identity = ['-c', 'user.name=test', '-c', 'user.email=test@example.com']
        subprocess.run(['git', '-C', str(upstream), *git_identity, 'commit', '-qm', 'base'], check=True)
        base = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
        (upstream / 'tip').write_text('new tip\n')
        subprocess.run(['git', '-C', str(upstream), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(upstream), *git_identity, 'commit', '-qm', 'tip'], check=True)
        for arch in ARCHES:
            patches = self.work / 'patches' / arch
            patches.mkdir(parents=True)
            (patches / '01.patch').write_text('diff --git a/value b/value\n--- a/value\n+++ b/value\n'
                                            '@@ -1 +1 @@\n-base\n+' + arch + '\n')
        self.record = self.work / 'record.py'
        self.record.write_text('''import fcntl,json,os,sys
from pathlib import Path
root=Path(sys.argv[1])
with (root/'events.lock').open('a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 file=root/'events.json'
 data=json.loads(file.read_text()) if file.exists() else dict(active=0,peak=0,entries=[])
 data['active'] += 1 if sys.argv[2]=='start' else -1
 data['peak']=max(data['peak'],data['active'])
 if sys.argv[2]=='start':
  data['entries'].append(dict(arch=sys.argv[3],workspace=os.environ['BUILD_WORK_DIR'],
                             budget=int(os.environ.get('TGOS_BUILD_JOB_BUDGET', os.environ['BUILD_JOBS']))))
 file.write_text(json.dumps(data))
''')
        original = (ROOT / 'scripts/platform/qemu.sh').read_text()
        marker = 'if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then'
        self.assertEqual(original.count(marker), 1)
        stub = '''qemu_build_os_and_rootfs() {
    python3 "$PROBE_ROOT/record.py" "$PROBE_ROOT" start "$ARCH"
    touch "$PROBE_ROOT/$ARCH.started"
    if [[ ${PROBE_BARRIER:-0} == 1 ]]; then
        local deadline=$((SECONDS+12)) ready peer
        while :; do
            ready=1
            for peer in aarch64 riscv64 x86_64 loongarch64; do
                [[ -e $PROBE_ROOT/$peer.started ]] || ready=0
            done
            ((ready)) && break
            ((SECONDS < deadline)) || return 20
            sleep 0.05
        done
    fi
    clone_repository "$PROBE_UPSTREAM" "$BUILD_DIR/probe"
    prepare_patched_source "$BUILD_DIR/probe" "$PROBE_REF" "$PROBE_ROOT/patches/$ARCH"
    probe_inner() {
        [[ $(build_jobs) -le $TGOS_BUILD_JOB_BUDGET ]]
        printf '%s\\n' "$ARCH" >"$BUILD_DIR/probe/.config"
    }
    run_parallel_functions inner probe_inner --
    sleep 0.2
    printf 'compiler-output %s\\n' "$ARCH"
    python3 "$PROBE_ROOT/record.py" "$PROBE_ROOT" end "$ARCH"
    [[ ${PROBE_FAIL:-} != "$ARCH" ]] || return 19
}
'''
        (self.repo / 'scripts/platform/qemu.sh').write_text(original.replace(marker, stub + marker))
        self.env = dict(os.environ, LOG_CREATE_DEFAULT_FILE='0', LOG_COLOR='never', BUILD_JOBS='8', BUILD_PARALLEL_TASKS='4',
                        PROBE_ROOT=str(self.work), PROBE_UPSTREAM=upstream.as_uri(), PROBE_REF=base)
        for key in ('BUILD_WORKSPACE_NAME', 'BUILD_WORK_DIR', 'BUILD_WORKSPACE_ROOT', 'BUILD_CACHE_DIR',
                    'BUILD_SOURCE_CACHE_DIR', 'TGOS_BUILD_JOB_BUDGET', 'LOG_FILE', 'LOG_DIR',
                    'PLATFORM_LOG_RUN_DIR', 'LOG_STDIO_CAPTURED', 'PARALLEL_STEP_CALLBACK'):
            self.env.pop(key, None)

    def invoke(self, target='qemu', **env):
        return run(['bash', str(self.repo / 'build.sh'), 'platform', target, 'all'], env=dict(self.env, **env))

    def test_architectures_overlap_and_share_only_downloads(self):
        result = self.invoke('all', PROBE_BARRIER='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('COMPLETE platform all: all targets finished successfully', result.stdout)
        self.assertNotIn('compiler-output', result.stdout)
        events = json.loads((self.work / 'events.json').read_text())
        self.assertEqual(events['peak'], 4)
        self.assertEqual(sum(e['budget'] for e in events['entries']), 8)
        self.assertEqual(len({e['workspace'] for e in events['entries']}), 4)
        caches = list((self.repo / 'build/.cache/git').glob('*.git'))
        self.assertEqual(len(caches), 1)
        caches[0].rename(self.work / 'detached-download-cache')
        for arch in ARCHES:
            source = self.repo / f'build/workspaces/qemu-{arch}/probe'
            self.assertEqual((source / 'value').read_text().strip(), arch)
            self.assertEqual((source / '.config').read_text().strip(), arch)
            subprocess.run(['git', '-C', str(source), 'fsck', '--no-reflogs'], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def test_cap_and_failure_aggregation(self):
        result = self.invoke(BUILD_PARALLEL_TASKS='2', PROBE_FAIL='aarch64')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        events = json.loads((self.work / 'events.json').read_text())
        self.assertLessEqual(events['peak'], 2)
        self.assertEqual(len(events['entries']), 4)
        self.assertIn('FAILED qemu-aarch64: status=19', result.stdout)
        self.assertIn('compiler-output aarch64', result.stdout)

    def test_platform_all_stops_after_board_failure(self):
        result = self.invoke('all', PROBE_BOARD_FAIL='1')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FAILED phytiumpi: status=23', result.stdout)
        self.assertIn('compiler-output board', result.stdout)
        self.assertEqual(result.stdout.count('] STARTED '), 1)
        self.assertFalse((self.work / 'events.json').exists())

    def test_same_architecture_reuses_and_serializes_workspace(self):
        processes = [subprocess.Popen(['bash', str(self.repo / 'build.sh'), 'platform', 'qemu-aarch64', 'all'],
                                      env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                     for _ in range(2)]
        try:
            for process in processes:
                self.assertEqual(process.wait(timeout=30), 0)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        events = json.loads((self.work / 'events.json').read_text())
        self.assertEqual(events['peak'], 1)
        self.assertEqual(len(events['entries']), 2)

    def test_shared_mutable_source_override_is_rejected(self):
        result = self.invoke('qemu-aarch64', ARCEOS_SRC_DIR=str(self.work / 'shared-source'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('escapes workspace', result.stdout + result.stderr)
        self.assertFalse((self.work / 'events.json').exists())

    def test_background_cache_process_does_not_keep_workspace_locked(self):
        command = ['bash', '-c', '''
ROOT_DIR=$1
source "$1/scripts/lib/build-paths.sh"
source "$1/scripts/lib/build-workspace.sh"
build_workspace_run daemon bash -c 'sleep 15 >/dev/null 2>&1 & echo $!'
''', '_', str(self.repo)]
        result = run(command, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        daemon = int(result.stdout.strip())
        try:
            with (self.repo / 'build/workspaces/.locks/daemon.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            try:
                os.kill(daemon, signal.SIGTERM)
            except ProcessLookupError:
                pass


if __name__ == '__main__':
    unittest.main()
