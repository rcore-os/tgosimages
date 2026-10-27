#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
source "$ROOT_DIR/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/utils.sh"
source "$ROOT_DIR/scripts/lib/build-lock.sh"
source "$ROOT_DIR/scripts/lib/axvisor-payloads.sh"

AXVISOR_REPO_URL="${AXVISOR_REPO_URL:-https://github.com/rcore-os/tgoskits.git}"
AXVISOR_REF="${AXVISOR_REF:-dev}"
AXVISOR_SOURCE_PROVIDED=0
[[ -z ${AXVISOR_SRC_DIR:-} ]] || AXVISOR_SOURCE_PROVIDED=1
AXVISOR_SRC_DIR="${AXVISOR_SRC_DIR:-$BUILD_DIR/tgoskits-axvisor}"
AXVISOR_CONFIG="${AXVISOR_CONFIG:-os/axvisor/configs/board/orangepi-5-plus.toml}"
AXVISOR_IMAGES_DIR="${AXVISOR_IMAGES_DIR:-$ROOT_DIR/IMAGES/orangepi/axvisor}"

axvisor_usage() {
    cat <<'EOF'
Build the Orange Pi AxVisor host, prebuilt Shell/robot guests, YOLOv8 runtime,
and shared BallPick robot configurations.

Usage: scripts/os/axvisor.sh orangepi-5-plus [--debug]
       scripts/os/axvisor.sh clean

Environment: AXVISOR_REPO_URL, AXVISOR_REF (default dev), AXVISOR_SRC_DIR,
AXVISOR_CONFIG (relative to checkout, with vm_configs = []), AXVISOR_IMAGES_DIR,
AXVISOR_OBJCOPY (optional binary converter), CARGO_TARGET_DIR.
ORANGEPI_YOLO_CC, ORANGEPI_YOLO_CXX, ORANGEPI_YOLO_SYSROOT select the
GNU/Linux target SDK independently of the build host environment.
Existing explicitly supplied checkouts are preserved. Guest configs are copied
from that same checkout and shared across scenarios, for `vm create <path>`.
EOF
}

axvisor_prepare_source() {
    build_assert_workspace_path "$AXVISOR_SRC_DIR" || return 1
    if [[ $AXVISOR_SOURCE_PROVIDED == 1 && -e $AXVISOR_SRC_DIR/.git ]]; then
        git -C "$AXVISOR_SRC_DIR" rev-parse --is-inside-work-tree >/dev/null || return 1
        info "Using provided TGOSKits checkout: $AXVISOR_SRC_DIR"
        return 0
    fi
    clone_repository "$AXVISOR_REPO_URL" "$AXVISOR_SRC_DIR" || return 1
    git -C "$AXVISOR_SRC_DIR" fetch --quiet --no-tags --depth=1 origin "$AXVISOR_REF" || return 1
    prepare_patched_source "$AXVISOR_SRC_DIR" FETCH_HEAD /nonexistent-tgos-patches reset
}

axvisor_objcopy() {
    local tool=${AXVISOR_OBJCOPY:-} library
    if [[ -z $tool ]]; then
        library=$(rustc --print target-libdir) || return 1
        tool="$(dirname -- "$library")/bin/llvm-objcopy"
    fi
    "$tool" -O binary "$1" "$2"
}

axvisor_build() (
    local stage= backup= lock_fd log elf config target_dir status=0
    local -a args=("$@")
    axvisor_prepare_source || return $?
    AXVISOR_SRC_DIR=$(realpath -e -- "$AXVISOR_SRC_DIR") || return 1
    config=$(realpath -e -- "$AXVISOR_SRC_DIR/$AXVISOR_CONFIG") || return 1
    [[ $config == "$AXVISOR_SRC_DIR/"* ]] || {
        error "AxVisor build configuration escapes checkout: $AXVISOR_CONFIG"; return 1;
    }
    AXVISOR_IMAGES_DIR=$(realpath -m -- "$AXVISOR_IMAGES_DIR") || return 1
    mkdir -p -- "$(dirname -- "$AXVISOR_IMAGES_DIR")" || return 1
    trap '
        if [[ -n $backup && -d $backup && ! -e $AXVISOR_IMAGES_DIR ]]; then
            mv -T -- "$backup" "$AXVISOR_IMAGES_DIR"
        fi
        [[ -z $stage ]] || rm -rf -- "$stage"
        build_lock_release_all
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    build_lock_acquire lock_fd "$AXVISOR_IMAGES_DIR" || return 1
    stage=$(mktemp -d "$(dirname -- "$AXVISOR_IMAGES_DIR")/.axvisor-package.XXXXXX") || return 1
    python3 "$ROOT_DIR/scripts/lib/python/axvisor-package.py" "$AXVISOR_SRC_DIR" "$stage" \
        --build-config "$config" || return $?
    export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$BUILD_DIR/objects/axvisor}"
    target_dir=$(realpath -m -- "$CARGO_TARGET_DIR") || return 1
    export CARGO_TARGET_DIR=$target_dir
    ensure_musl_toolchain aarch64 || return 1
    log="$stage/build.log"
    (
        cd -- "$AXVISOR_SRC_DIR" || exit 1
        export AXBUILD_NO_SNAPSHOT=1
        build_cargo xtask axvisor build -c "$AXVISOR_CONFIG" "${args[@]}"
    ) 2>&1 | tee "$log" || status=$?
    ((status == 0)) || return "$status"
    # Use the artifact reported by this invocation rather than guessing between
    # bare-metal and std target directories or picking an old axvisor.bin.
    elf=$(sed -n 's/^\[axbuild\] cargo build elf=//p' "$log" | tail -1)
    [[ -n $elf ]] || { error "AxVisor build did not report its ELF artifact"; return 1; }
    elf=$(realpath -e -- "$elf") || return 1
    [[ $elf == "$target_dir/"* && -s $elf ]] || {
        error "AxVisor artifact missing or outside the Cargo target directory: $elf"; return 1;
    }
    install -m 0644 -- "$elf" "$stage/orangepi-5-plus.elf" || return 1
    (
        cd -- "$AXVISOR_SRC_DIR" || exit 1
        axvisor_objcopy "$elf" "$stage/AxVisor.bin"
    ) || return 1
    [[ -s $stage/AxVisor.bin ]] || return 1
    # Record the lockfile and source state actually used by Cargo, which may
    # have updated dependency resolution during this build.
    python3 "$ROOT_DIR/scripts/lib/python/axvisor-package.py" "$AXVISOR_SRC_DIR" "$stage" \
        --build-config "$config" || return $?
    axvisor_stage_payloads "$stage" || return $?
    rm -- "$log" || return 1
    (
        cd -- "$stage" || exit 1
        find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | \
            xargs -0 sha256sum >SHA256SUMS
    ) || return 1
    if [[ -e $AXVISOR_IMAGES_DIR ]]; then
        backup=$(mktemp -d "$(dirname -- "$AXVISOR_IMAGES_DIR")/.axvisor-previous.XXXXXX") || return 1
        mv -T -- "$AXVISOR_IMAGES_DIR" "$backup" || return 1
    fi
    mv -T -- "$stage" "$AXVISOR_IMAGES_DIR" || return 1
    stage=
    [[ -z $backup ]] || rm -rf -- "$backup"
    backup=
    success "AxVisor host and shared guest configurations: $AXVISOR_IMAGES_DIR"
)

axvisor_clean() (
    local lock_fd
    trap 'build_lock_release_all' EXIT
    build_lock_acquire lock_fd "$AXVISOR_IMAGES_DIR" || return 1
    rm -rf -- "$AXVISOR_IMAGES_DIR"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    command=${1:-help}
    shift || true
    case $command in
        help|-h|--help) axvisor_usage ;;
        orangepi-5-plus)
            for argument in "$@"; do
                [[ $argument == --debug ]] || { error "Unsupported AxVisor option: $argument"; exit 2; }
            done
            axvisor_build "$@"
            ;;
        clean) axvisor_clean ;;
        *) error "Unknown AxVisor target: $command"; exit 2 ;;
    esac
fi
