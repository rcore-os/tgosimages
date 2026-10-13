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

# Unpatched application dependencies use the same disposable-cache contract.
build_prepare_checkout() {
    local source=$1 repository=$2 ref=${3:-HEAD} provided=${4:-0}
    if [[ $provided == 1 && -e $source/.git ]]; then
        info "Using provided source without updating or cleaning: $source"
        return 0
    fi
    if [[ $provided == 0 ]]; then
        case $(realpath -m -- "$source") in
            "$BUILD_DIR/"*) ;;
            *) error "Managed source must be inside the build directory: $source"; return 1 ;;
        esac
    fi
    if [[ ! -e $source/.git ]]; then
        [[ ! -e $source ]] || { error "Source exists but is not a Git checkout: $source"; return 1; }
        mkdir -p -- "$(dirname -- "$source")" || return
        git clone "$repository" "$source" || return
    fi
    git -C "$source" fetch --quiet --no-tags --depth=1 origin "$ref" || return
    git -C "$source" checkout --quiet --force FETCH_HEAD || return
    git -C "$source" clean -fd --quiet || return
}
