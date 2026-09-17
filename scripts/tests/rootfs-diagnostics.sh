#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
work=$(mktemp -d /tmp/rootfs-diagnostics.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
export LOG_CREATE_DEFAULT_FILE=0
source "$repo_root/scripts/lib/rootfs-compose.sh"
warn() { printf '%s\n' "$*" >&2; }

fail() { printf 'not ok - %s\n' "$*" >&2; cat "$work/stderr" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$work/stderr" || fail "missing diagnostic: $1"; }
expect_failure() {
    if "$@" >"$work/stdout" 2>"$work/stderr"; then
        fail "unexpected success: $*"
    else
        failure_status=$?
    fi
}

truncate -s 12M "$work/base.img"
mkfs.ext4 -F -q "$work/base.img"
mkdir "$work/outer" "$work/guest" "$work/payload"
printf fixture >"$work/guest/test"
touch -d @1700000000 "$work/guest/test"
compose() {
    touch -d @1700000000 "$work/guest/test"
    rootfs_compose_test_images "$work/base.img" "$work/outer" "$work/guest" \
        "$work/payload" riscv64 debian 1M 1M "$work/final.img"
}

test_fsck_failure() (
    e2fsck() { printf 'filesystem check report fixture\n'; printf 'unsupported feature fixture\n' >&2; return 8; }
    compose
)
expect_failure test_fsck_failure
contains 'e2fsck'
contains 'status=8'
contains 'unsupported feature fixture'
contains 'filesystem check report fixture'
contains 'debian/riscv64'
contains 'stage=check-base-image'
[[ ! -e $work/final.img ]] || fail 'failed check published an image'
printf 'ok - base check retains tool error, status, architecture, and stage\n'

test_dumpe2fs_failure() (
    dumpe2fs() { printf 'bad superblock fixture\n' >&2; return 19; }
    _rootfs_ext4_stats "$work/base.img"
)
expect_failure test_dumpe2fs_failure
contains 'dumpe2fs'
contains 'status=19'
contains 'bad superblock fixture'
printf 'ok - superblock reader retains diagnostics\n'

test_transcript_failure() (
    local _rootfs_tool_transcript=/dev/full
    failed_tool_fixture() { printf 'original tool failure fixture\n' >&2; return 23; }
    _rootfs_run_tool 0 failed_tool_fixture
)
expect_failure test_transcript_failure
contains 'failed_tool_fixture'
contains 'status=23'
contains 'original tool failure fixture'
[[ $failure_status == 23 ]] || fail 'transcript failure changed the original command status'
printf 'ok - transcript storage failure preserves the original command and status\n'

test_dirty_image() (
    cp "$work/base.img" "$work/dirty.img"
    debugfs -w -R 'set_super_value state 0' "$work/dirty.img" >/dev/null 2>&1
    _rootfs_check_clean "$work/dirty.img"
)
expect_failure test_dirty_image
contains 'filesystem state'
contains 'dirty.img'
printf 'ok - dirty image rejection explains its filesystem state\n'

test_repair_success() (
    e2fsck() { printf 'filesystem repaired fixture\n' >&2; return 1; }
    _rootfs_repair_ext4 "$work/base.img"
)
test_repair_success >"$work/stdout" 2>"$work/stderr" || fail 'repair status 1 must remain successful'
[[ ! -s $work/stdout && ! -s $work/stderr ]] || fail 'successful repair must stay quiet'
printf 'ok - repaired-filesystem status remains a quiet success\n'

test_resize_failure() (
    resize2fs() { printf 'resize failure fixture\n' >&2; return 23; }
    compose
)
printf previous-output >"$work/final.img"
expect_failure test_resize_failure
contains 'resize2fs'
contains 'status=23'
contains 'resize failure fixture'
contains 'stage=compact-guest-image'
[[ $(cat "$work/final.img") == previous-output ]] || fail 'failed composition replaced output'
[[ -z $(find "$work" -maxdepth 1 -name '.final.img.*' -print -quit) ]] || fail 'failed composition leaked staging files'
printf 'ok - failed compaction keeps diagnostics and preserves the previous image\n'

real_debugfs=$(command -v debugfs)
test_debugfs_failure() (
    debugfs() {
        if [[ ${1:-} == -w ]]; then
            printf 'debugfs write failure fixture\n' >&2
            return 27
        fi
        "$real_debugfs" "$@"
    }
    compose
)
expect_failure test_debugfs_failure
contains 'debugfs'
contains 'status=27'
contains 'debugfs write failure fixture'
contains 'stage=inject-guest-tests'
printf 'ok - failed debugfs commands retain original output\n'

test_debugfs_noop() (
    debugfs() {
        if [[ ${1:-} == -w ]]; then
            printf 'original debugfs error: No space left on device\n' >&2
            return 0
        fi
        "$real_debugfs" "$@"
    }
    compose
)
expect_failure test_debugfs_noop
contains '/test'
contains 'File not found'
contains 'stage=inject-guest-tests'
contains 'original debugfs error: No space left on device'
contains 'status=0 command=debugfs -w -f'
contains 'content.commands'
contains 'rootfs: content batch commands'
contains 'write "'
[[ -z $(find "$work" -maxdepth 1 -name '.rootfs-*' -print -quit) ]] || fail 'semantic failure leaked diagnostics staging'
printf 'ok - zero-exit debugfs write failures retain the original error and command\n'

rm "$work/final.img"
compose >"$work/stdout" 2>"$work/stderr" || fail 'real small image composition failed'
[[ ! -s $work/stdout && ! -s $work/stderr ]] || fail 'successful composition must stay quiet'
[[ -s $work/final.img ]] || fail 'successful composition did not publish'
printf 'ok - successful real image composition stays quiet\n'
