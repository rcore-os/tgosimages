#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
work=$(mktemp -d /tmp/freertos-source-preparation.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

for name in benchmark kernel; do
    repository="$work/upstream-$name"
    mkdir -p "$repository"
    git -C "$repository" init -q
    git -C "$repository" config user.name test
    git -C "$repository" config user.email test@example.com
    printf 'base\n' >"$repository/value"
    git -C "$repository" add value
    git -C "$repository" commit -qm base
done

export BUILD_WORK_DIR="$work/workspace"
export BUILD_CACHE_DIR="$work/cache"
export FREERTOS_REPO_URL="$work/upstream-benchmark"
export FREERTOS_KERNEL_REPO_URL="$work/upstream-kernel"
export FREERTOS_REF
export FREERTOS_KERNEL_REF
FREERTOS_REF=$(git -C "$work/upstream-benchmark" rev-parse HEAD)
FREERTOS_KERNEL_REF=$(git -C "$work/upstream-kernel" rev-parse HEAD)
mkdir -p "$BUILD_WORK_DIR" "$work/patches"
LOG_CREATE_DEFAULT_FILE=0
export LOG_CREATE_DEFAULT_FILE
LOG_FILE="$work/patch.log"
export LOG_FILE

cat >"$work/patches/both.patch" <<'PATCH'
--- a/freertos/value
+++ b/freertos/value
@@ -1 +1 @@
-base
+patched-main
--- a/FreeRTOS-Kernel/value
+++ b/FreeRTOS-Kernel/value
@@ -1 +1 @@
-base
+patched-kernel
PATCH

run_preparation() {
    local expected_main=$1
    bash -c '
        source "$1/scripts/os/freertos.sh"
        prepare_target_source
        apply_single_patch "$2" "$FREERTOS_SOURCE_ROOT"
        [[ $(<"$FREERTOS_SRC_DIR/value") == "$3" ]]
        [[ $(<"$FREERTOS_KERNEL_SRC_DIR/value") == patched-kernel ]]
        [[ $(<"$FREERTOS_BASE_SRC_DIR/value") == base ]]
        [[ $(<"$FREERTOS_BASE_KERNEL_SRC_DIR/value") == base ]]
        if [[ $3 == patched-main ]]; then
            cp "$2" "$FREERTOS_SOURCE_ROOT/original.patch"
            sed -i "s/+patched-main/+changed-within-build/" "$2"
            if (apply_single_patch "$2" "$FREERTOS_SOURCE_ROOT"); then
                exit 1
            fi
            cp "$FREERTOS_SOURCE_ROOT/original.patch" "$2"
        fi
    ' _ "$repo_root" "$work/patches/both.patch" "$expected_main"
}

run_preparation patched-main
sed -i 's/+patched-main/+updated-main/' "$work/patches/both.patch"
run_preparation updated-main
[[ -d $BUILD_WORK_DIR/freertos-sources/rtos-benchmark ]]
[[ -d $BUILD_WORK_DIR/freertos-sources/FreeRTOS-Kernel ]]
! find "$BUILD_WORK_DIR" -maxdepth 1 -name 'freertos-work.*' -print -quit | grep -q .

printf 'user edit\n' >"$BUILD_WORK_DIR/freertos-sources/rtos-benchmark/value"
if run_preparation updated-main; then
    printf 'edited FreeRTOS source cache was accepted\n' >&2
    exit 1
fi
[[ $(<"$BUILD_WORK_DIR/freertos-sources/rtos-benchmark/value") == 'user edit' ]]

printf 'PASS: FreeRTOS prepares isolated patch copies and preserves source cache edits\n'
