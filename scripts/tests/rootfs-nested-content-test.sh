#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
validator="$repo_root/scripts/tests/rootfs-nested-content.sh"
work=$(mktemp -d /tmp/rootfs-nested-content-test.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
warn() { printf 'warning: %s\n' "$*" >&2; }
info() { :; }
die() { printf 'error: %s\n' "$*" >&2; return 1; }
# shellcheck source=../lib/rootfs.sh
source "$repo_root/scripts/lib/rootfs.sh"

tests=0
fail() { printf 'not ok %s - %s\n' "$tests" "$*" >&2; exit 1; }
pass() { printf 'ok %s - %s\n' "$tests" "$*"; }
run_ok() {
    local message=$1
    shift
    tests=$((tests + 1))
    if ! "$@" >"$work/stdout" 2>"$work/stderr"; then
        sed -n '1,120p' "$work/stderr" >&2
        fail "$message"
    fi
    pass "$message"
}
run_fail() {
    local message=$1
    shift
    tests=$((tests + 1))
    if "$@" >"$work/stdout" 2>"$work/stderr"; then
        fail "$message (unexpected success)"
    fi
    pass "$message"
}

run_ok 'help succeeds' bash "$validator" --help
run_fail 'unknown option is rejected' bash "$validator" --unknown
run_fail 'missing option value is rejected' bash "$validator" --arch
run_fail 'invalid architecture is rejected' bash "$validator" --arch mips --rootfs busybox
run_fail 'invalid rootfs type is rejected' bash "$validator" --arch x86_64 --rootfs fedora
run_fail 'invalid reserve is rejected' bash "$validator" --arch x86_64 --rootfs busybox --guest-free-size nope
run_fail 'missing selected image is rejected' bash "$validator" --image-dir "$work/empty" --arch x86_64 --rootfs busybox

mkdir -p "$work/empty" "$work/nested-tree/guest-tests/cyclictest" \
    "$work/nested-tree/guest-tests/lmbench/bin/Linux" \
    "$work/nested-tree/guest-tests/lmbench/scripts" \
    "$work/nested-tree/guest-tests/iozone" "$work/nested-tree/guest-tests/custom" \
    "$work/outer-tree/guest/platform" \
    "$work/initramfs-tree/guest/platform"
printf 'int main(void) { return 0; }\n' >"$work/tiny.c"
gcc -static -s -o "$work/tiny" "$work/tiny.c"
install -m 0755 "$work/tiny" "$work/nested-tree/guest-tests/cyclictest/cyclictest"
install -m 0755 "$work/tiny" "$work/nested-tree/guest-tests/lmbench/bin/Linux/bw_mem"
install -m 0755 "$work/tiny" "$work/nested-tree/guest-tests/lmbench/bin/Linux/lat_syscall"
install -m 0755 "$work/tiny" "$work/nested-tree/guest-tests/iozone/iozone"
for script in lmbench config-run results config os gnu-os info info-template version; do
    printf '#!/bin/sh\nexit 0\n' >"$work/nested-tree/guest-tests/lmbench/scripts/$script"
    chmod 0755 "$work/nested-tree/guest-tests/lmbench/scripts/$script"
done
printf '#!/bin/sh\nexit 0\n' >"$work/nested-tree/guest-tests/lmbench/bin/Linux/lmbench"
chmod 0755 "$work/nested-tree/guest-tests/lmbench/bin/Linux/lmbench"
find "$work/nested-tree" -type d -o -type f | xargs touch -d @1700000000

nested="$work/rootfs-x86_64-busybox.nested.img"
truncate -s 24M "$nested"
mkfs.ext4 -q -F "$nested"
_rootfs_inject_tree_via_debugfs "$nested" "$work/nested-tree"
cp "$nested" "$work/outer-tree/guest/rootfs-x86_64-busybox.img"
printf platform >"$work/outer-tree/guest/platform/marker"
find "$work/outer-tree" -type d -o -type f | xargs touch -d @1700000000

image_dir="$work/images"
mkdir "$image_dir"
outer="$image_dir/rootfs-x86_64-busybox.img"
truncate -s 56M "$outer"
mkfs.ext4 -q -F "$outer"
_rootfs_inject_tree_via_debugfs "$outer" "$work/outer-tree"
(
    cd "$work/initramfs-tree"
    find . -print0 | fakeroot cpio --null -o -H newc 2>/dev/null | gzip -n >"$image_dir/initramfs-x86_64-busybox.cpio.gz"
)

run_ok 'valid nested BusyBox fixture passes all built-in content checks' \
    bash "$validator" --image-dir "$image_dir" --arch x86_64 --rootfs busybox \
        --guest-free-size 1M --outer-free-size 1M --outer-only-path /guest/platform
run_ok 'relative image directory remains valid while unpacking initramfs' \
    bash -c 'cd "$1" && exec bash "$2" --image-dir images --arch x86_64 --rootfs busybox --guest-free-size 1M --outer-free-size 1M' \
        _ "$work" "$validator"
run_ok 'a nondefault single plugin does not require unselected plugins' \
    bash "$validator" --image-dir "$image_dir" --arch x86_64 --rootfs busybox \
        --guest-tests cyclictest --guest-free-size 1M --outer-free-size 1M
run_ok 'unknown plugin uses the extensible directory existence check' \
    bash "$validator" --image-dir "$image_dir" --arch x86_64 --rootfs busybox \
        --guest-tests custom --guest-free-size 1M --outer-free-size 1M
run_fail 'missing selected plugin is rejected' \
    bash "$validator" --image-dir "$image_dir" --arch x86_64 --rootfs busybox \
        --guest-tests missing --guest-free-size 1M --outer-free-size 1M
run_fail 'insufficient outer reserve is rejected' \
    bash "$validator" --image-dir "$image_dir" --arch x86_64 --rootfs busybox \
        --guest-tests none --guest-free-size 1M --outer-free-size 1T

chmod 0644 "$work/nested-tree/guest-tests/lmbench/bin/Linux/lmbench"
find "$work/nested-tree" -type d -o -type f | xargs touch -d @1700000000
bad_nested="$work/bad-nested.img"
truncate -s 24M "$bad_nested"
mkfs.ext4 -q -F "$bad_nested"
_rootfs_inject_tree_via_debugfs "$bad_nested" "$work/nested-tree"
bad_tree="$work/bad-outer-tree"
mkdir -p "$bad_tree/guest" "$work/bad-images"
cp "$bad_nested" "$bad_tree/guest/rootfs-x86_64-busybox.img"
find "$bad_tree" -type d -o -type f | xargs touch -d @1700000000
bad_outer="$work/bad-images/rootfs-x86_64-busybox.img"
truncate -s 56M "$bad_outer"
mkfs.ext4 -q -F "$bad_outer"
_rootfs_inject_tree_via_debugfs "$bad_outer" "$bad_tree"
run_fail 'non-executable lmbench launcher is rejected' \
    bash "$validator" --image-dir "$work/bad-images" --arch x86_64 --rootfs busybox \
        --guest-tests lmbench --guest-free-size 1M --outer-free-size 1M

chmod 0755 "$work/nested-tree/guest-tests/lmbench/bin/Linux/lmbench"
mkdir -p "$work/nested-tree/guest"
printf recursive >"$work/nested-tree/guest/rootfs-aarch64-alpine.img"
find "$work/nested-tree" -type d -o -type f | xargs touch -d @1700000000
recursive_nested="$work/recursive-nested.img"
truncate -s 24M "$recursive_nested"
mkfs.ext4 -q -F "$recursive_nested"
_rootfs_inject_tree_via_debugfs "$recursive_nested" "$work/nested-tree"
recursive_tree="$work/recursive-outer-tree"
mkdir -p "$recursive_tree/guest" "$work/recursive-images"
cp "$recursive_nested" "$recursive_tree/guest/rootfs-x86_64-busybox.img"
find "$recursive_tree" -type d -o -type f | xargs touch -d @1700000000
recursive_outer="$work/recursive-images/rootfs-x86_64-busybox.img"
truncate -s 56M "$recursive_outer"
mkfs.ext4 -q -F "$recursive_outer"
_rootfs_inject_tree_via_debugfs "$recursive_outer" "$recursive_tree"
run_fail 'any recursively nested rootfs image is rejected' \
    bash "$validator" --image-dir "$work/recursive-images" --arch x86_64 --rootfs busybox \
        --guest-tests none --guest-free-size 1M --outer-free-size 1M

mkdir -p "$work/bad-initramfs-images" "$work/bad-initramfs-tree/guest-tests"
cp "$outer" "$work/bad-initramfs-images/rootfs-x86_64-busybox.img"
(
    cd "$work/bad-initramfs-tree"
    find . -print0 | fakeroot cpio --null -o -H newc 2>/dev/null |
        gzip -n >"$work/bad-initramfs-images/initramfs-x86_64-busybox.cpio.gz"
)
run_fail 'BusyBox initramfs guest test contamination is rejected' \
    bash "$validator" --image-dir "$work/bad-initramfs-images" --arch x86_64 --rootfs busybox \
        --guest-tests none --guest-free-size 1M --outer-free-size 1M

printf '1..%s\n' "$tests"
