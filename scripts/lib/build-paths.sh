#!/usr/bin/env bash

# All host builders initialize paths through this function so descendants
# inherit the active workspace instead of silently returning to repo/build.
build_paths_init() {
    local root=$1
    BUILD_DIR=${BUILD_WORK_DIR:-${root}/build}
    mkdir -p -- "$BUILD_DIR" || return
    BUILD_DIR=$(cd -- "$BUILD_DIR" && pwd -P) || return
}

build_assert_workspace_path() {
    [[ -n ${BUILD_WORKSPACE_NAME:-} ]] || return 0
    local candidate
    candidate=$(realpath -m -- "$1") || return
    case $candidate in
        "${BUILD_WORK_DIR}/"*) return 0 ;;
    esac
    printf 'Mutable source path escapes workspace %s: %s\n' "$BUILD_WORKSPACE_NAME" "$candidate" >&2
    return 1
}
