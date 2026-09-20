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
import time
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
            script.write_text('''#!/bin/bash
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    source "$ROOT_DIR/scripts/lib/platform-graph-entry.sh"
fi
PLATFORM_IMAGES_DIR="$ROOT_DIR/IMAGES/fixture"
PLATFORM_ROOTFS_DIR="$ROOT_DIR/IMAGES/rootfs"
linux() {
    touch "$PROBE_ROOT/board.started"
    if [[ ${PROBE_HOLD:-0} == 1 ]]; then
        printf '%s' "$$" >"$BUILD_WORK_DIR/worker.pid"
        sleep 30
    fi
    if [[ ${PROBE_GLOBAL_BARRIER:-0} == 1 && $BUILD_WORKSPACE_NAME == phytiumpi ]]; then
        deadline=$((SECONDS+12))
        until [[ -f $PROBE_ROOT/aarch64.started ]]; do
            ((SECONDS < deadline)) || return 24
            sleep .05
        done
    fi
    printf 'compiler-output board\\n'
    [[ ${PROBE_BOARD_FAIL:-0} != 1 ]] || return 23
    touch "$BUILD_WORK_DIR/linux.done"
}
arceos() { touch "$BUILD_WORK_DIR/arceos.done"; }
rtthread() { :; }
zephyr() { touch "$BUILD_WORK_DIR/zephyr.done"; }
freertos() { touch "$BUILD_WORK_DIR/freertos.done"; }
uboot() { touch "$BUILD_WORK_DIR/uboot.done"; }
rootfs() { test -f "$BUILD_WORK_DIR/linux.done"; touch "$BUILD_WORK_DIR/rootfs.done"; }
starry() { touch "$BUILD_WORK_DIR/starry.done"; }
ivc() {
    test -f "$BUILD_WORK_DIR/starry.done"
    test -f "$BUILD_WORK_DIR/zephyr.done"
    touch "$BUILD_WORK_DIR/ivc.done"
}
orangepi_build_base_image() {
    for component in linux rootfs uboot arceos starry zephyr freertos ivc; do
        test -f "$BUILD_WORK_DIR/$component.done"
    done
    touch "$BUILD_WORK_DIR/base.done"
}
finalize_linux_image() { test -f "$BUILD_WORK_DIR/base.done"; touch "$PROBE_ROOT/orangepi.composed"; }
rootfs_inject_guest_stage() { test -f "$BUILD_WORK_DIR/linux.done"; }
''')
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
        stub = '''linux() {
    python3 "$PROBE_ROOT/record.py" "$PROBE_ROOT" start "$ARCH"
    touch "$PROBE_ROOT/$ARCH.started"
    if [[ ${PROBE_GLOBAL_BARRIER:-0} == 1 ]]; then
        deadline=$((SECONDS+12))
        until [[ -f $PROBE_ROOT/board.started ]]; do
            ((SECONDS < deadline)) || return 24
            sleep .05
        done
    fi
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
    printf '%s\\n' "$ARCH" >"$BUILD_DIR/probe/.config"
    sleep 0.2
    printf 'compiler-output %s\\n' "$ARCH"
    python3 "$PROBE_ROOT/record.py" "$PROBE_ROOT" end "$ARCH"
    if [[ ${PROBE_FAIL:-} == "$ARCH" ]]; then
        (exit 19)
        printf 'wrongly-continued\\n'
    fi
}
arceos() { :; }
zephyr() { :; }
freertos() { :; }
qemu_rootfs_busybox_step() { :; }
qemu_rootfs_alpine_step() { :; }
qemu_rootfs_debian_step() { :; }
qemu_rootfs_inject_platform_dir() { touch "$PROBE_ROOT/$ARCH.composed"; }
'''
        (self.repo / 'scripts/platform/qemu.sh').write_text(original.replace(marker, stub + marker))
        self.env = dict(os.environ, LOG_CREATE_DEFAULT_FILE='0', LOG_COLOR='never', BUILD_JOBS='8', BUILD_PARALLEL_TASKS='4',
                        PROBE_ROOT=str(self.work), PROBE_UPSTREAM=upstream.as_uri(), PROBE_REF=base,
                        ROOTFS_GRAPH_DISABLE='1')
        for key in ('BUILD_WORKSPACE_NAME', 'BUILD_WORK_DIR', 'BUILD_WORKSPACE_ROOT', 'BUILD_CACHE_DIR',
                    'BUILD_SOURCE_CACHE_DIR', 'TGOS_BUILD_JOB_BUDGET', 'LOG_FILE', 'LOG_DIR',
                    'PLATFORM_LOG_RUN_DIR', 'LOG_STDIO_CAPTURED', 'PARALLEL_STEP_CALLBACK'):
            self.env.pop(key, None)

    def invoke(self, target='qemu', **env):
        return run(['bash', str(self.repo / 'build.sh'), 'platform', target, 'all'], env=dict(self.env, **env))

    def test_architectures_overlap_and_share_only_downloads(self):
        result = self.invoke(PROBE_BARRIER='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('COMPLETE graph: all tasks finished successfully', result.stdout)
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
        self.assertIn('FAILED qemu-aarch64.linux: status=19', result.stdout)
        self.assertIn('compiler-output aarch64', result.stdout)
        self.assertNotIn('wrongly-continued', result.stdout)
        self.assertFalse((self.work / 'aarch64.composed').exists())
        self.assertTrue((self.work / 'x86_64.composed').exists())

    def test_invalid_guest_count_is_rejected_before_tasks_start(self):
        result = self.invoke(ROOTFS_GUEST_COUNT='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ROOTFS_GUEST_COUNT must be from 1 through 8',
                      result.stderr)
        self.assertFalse((self.work / 'events.json').exists())

    def test_platform_all_shares_graph_and_continues_after_board_failure(self):
        result = self.invoke('all', PROBE_BOARD_FAIL='1', PROBE_GLOBAL_BARRIER='1')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FAILED phytiumpi.linux: status=23', result.stdout)
        self.assertIn('compiler-output board', result.stdout)
        self.assertTrue((self.work / 'aarch64.composed').exists())
        graphs = list((self.repo / 'logs').rglob('graph.json'))
        self.assertEqual(len(graphs), 1)
        states = json.loads(graphs[0].with_name('state.json').read_text())
        self.assertEqual(states['phytiumpi.compose']['state'], 'blocked')
        self.assertEqual(states['qemu-aarch64.compose']['state'], 'success')

    def test_platform_all_respects_orangepi_dependencies(self):
        result = self.invoke('all', PROBE_GLOBAL_BARRIER='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.work / 'orangepi.composed').exists())
        self.assertEqual(len(list((self.repo / 'logs').rglob('graph.json'))), 1)

    def test_single_board_command_includes_dependencies(self):
        result = run(['bash', str(self.repo / 'build.sh'), 'platform', 'orangepi-5-plus', 'rootfs'], env=self.env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        workspace = self.repo / 'build/workspaces/orangepi-5-plus'
        self.assertTrue((workspace / 'linux.done').exists())
        self.assertTrue((workspace / 'rootfs.done').exists())
        self.assertFalse((workspace / 'starry.done').exists())
        result = run(['bash', str(self.repo / 'build.sh'), 'platform', 'phytiumpi', 'arceos'], env=self.env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.repo / 'build/workspaces/phytiumpi/linux.done').exists())

    def test_same_outputs_are_serialized_across_workspace_roots(self):
        processes = [subprocess.Popen(['bash', str(self.repo / 'build.sh'), 'platform', 'qemu-aarch64', 'all'],
                                      env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                     for env in (self.env, dict(self.env, BUILD_WORKSPACE_ROOT=str(self.work / 'other-workspaces')))]
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
        workspace = self.repo / 'build/workspaces/qemu-aarch64'
        workspace.rmdir()
        shared = self.work / 'shared-source'
        shared.mkdir()
        workspace.symlink_to(shared, target_is_directory=True)
        result = self.invoke('qemu-aarch64')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must not be a symlink', result.stdout + result.stderr)

    def test_platform_all_sigterm_reaches_scheduler(self):
        process = subprocess.Popen(['bash', str(self.repo / 'build.sh'), 'platform', 'all'],
                                   env=dict(self.env, PROBE_HOLD='1'), stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            while not list((self.repo / 'build').rglob('worker.pid')) and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(list((self.repo / 'build').rglob('worker.pid')))
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 1)
            state_file, = (self.repo / 'logs').rglob('state.json')
            states = json.loads(state_file.read_text())
            self.assertNotIn('running', [s['state'] for s in states.values()])
            self.assertIn('cancelled', [s['state'] for s in states.values()])
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for path in (self.repo / 'build').rglob('worker.pid'):
                try:
                    os.killpg(int(path.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

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
            for path in ('build/workspaces/.locks/daemon.lock', 'build/.locks/platform-daemon.lock'):
                with (self.repo / path).open('a') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            try:
                os.kill(daemon, signal.SIGTERM)
            except ProcessLookupError:
                pass


if __name__ == '__main__':
    unittest.main()
