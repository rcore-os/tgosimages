#!/usr/bin/env bash
set -euo pipefail
image=$1 overlay=$2 reserve=$3 output=${4:-$1}
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT_DIR/scripts/lib/utils.sh"
source "$ROOT_DIR/scripts/lib/rootfs-compose.sh"
_rootfs_builder_normalize_overlay_seconds "$overlay"
if [[ $image == "$output" ]]; then
    rootfs_compose_guest_tests_atomic "$image" "$overlay" "$reserve"
    exit
fi
mkdir -p -- "$(dirname -- "$output")"
temporary=$(mktemp "$(dirname -- "$output")/.${output##*/}.compose.XXXXXX")
lock_fd=
cleanup() {
    rm -f -- "$temporary"
    [[ -z $lock_fd ]] || build_lock_release "$lock_fd" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp --preserve=all --reflink=auto --sparse=always -- "$image" "$temporary"
rootfs_compose_guest_tests_atomic "$temporary" "$overlay" "$reserve"
build_lock_acquire lock_fd "${output}.lock"
mv -T -- "$temporary" "$output"
temporary=
build_lock_release "$lock_fd"
lock_fd=
trap - EXIT INT TERM
