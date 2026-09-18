#!/usr/bin/env bash

# The command owns this persistent workspace through its whole build, not just
# checkout. The lock also serializes direct and batch invocations of one target.
build_workspace_run() (
    local name=$1
    shift
    [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
        printf 'Invalid workspace name: %s\n' "$name" >&2
        exit 2
    }
    local root=${BUILD_WORKSPACE_ROOT:-${ROOT_DIR}/build/workspaces} lock_fd variable
    mkdir -p -- "$root/.locks" "$root/$name" || exit
    root=$(cd -- "$root" && pwd -P) || exit
    exec {lock_fd}>>"$root/.locks/$name.lock"
    flock -x "$lock_fd" || exit
    # A compiler-cache daemon may inherit descriptors. Explicitly unlock when
    # the build ends instead of waiting for every inherited descriptor to close.
    trap 'flock -u "$lock_fd"' EXIT
    export BUILD_WORKSPACE_NAME=$name BUILD_WORK_DIR="$root/$name"
    export BUILD_CACHE_DIR=${BUILD_CACHE_DIR:-${ROOT_DIR}/build/.cache}
    export BUILD_SOURCE_CACHE_DIR=${BUILD_SOURCE_CACHE_DIR:-${BUILD_CACHE_DIR}/git}
    export ROOTFS_TEST_BUILD_ROOT=${ROOTFS_TEST_BUILD_ROOT:-${BUILD_WORK_DIR}/rootfs-tests}
    # Explicit mutable source overrides may otherwise reconnect isolated tasks
    # to the same checkout. Read-only SDK/toolchain paths remain shareable.
    for variable in ARCEOS_SRC_DIR FREERTOS_SRC_DIR FREERTOS_KERNEL_SRC_DIR \
        ZEPHYR_SRC_DIR STARRY_SRC_DIR RTTHREAD_SRC_DIR BUSYBOX_SRC_DIR AXVISOR_TOOLS_SRC_DIR; do
        [[ -z ${!variable:-} ]] || build_assert_workspace_path "${!variable}" || exit
    done
    "$@"
)
