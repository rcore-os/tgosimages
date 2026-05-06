#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

# Default values
ARCEOS_REPO_URL="${ARCEOS_REPO_URL:-https://github.com/rcore-os/tgoskits.git}"
ARCEOS_REF="${ARCEOS_REF:-4927ff8ad4c156ef06bc9b5cc4e1ab547fe1a425}"
ARCEOS_SRC_DIR="${ARCEOS_SRC_DIR:-${BUILD_DIR}/tgoskits}"
ARCEOS_PATCH_DIR="${ARCEOS_PATCH_DIR:-${ROOT_DIR}/patches/arceos}"

# Global variables for parsed arguments
ARCEOS_PLATFORM=""
ARCEOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/arceos"
ARCEOS_IMAGE_NAME=""
ARCEOS_ARGS=""

# Platform-specific configurations
# Format: arch:<arch> target:<target_triple>
declare -A PLATFORM_CONFIGS
PLATFORM_CONFIGS[aarch64-dyn]="arch:aarch64 target:aarch64-unknown-none-softfloat"
PLATFORM_CONFIGS[riscv64-qemu-virt]="arch:riscv64 target:riscv64gc-unknown-none-elf"
PLATFORM_CONFIGS[x86-pc]="arch:x86_64 target:x86_64-unknown-none"

# Function to get platform-specific config value
get_platform_config() {
    local platform="$1"
    local config_key="$2"
    local config_str="${PLATFORM_CONFIGS[$platform]}"

    if [[ -z "$config_str" ]]; then
        die "Unsupported platform: $platform"
    fi

    # Parse the configuration string and return the requested value
    for item in $config_str; do
        local key="${item%%:*}"
        local value="${item#*:}"
        if [[ "$key" == "$config_key" ]]; then
            echo "$value"
            return 0
        fi
    done

    return 1
}

arceos_usage() {
    printf 'ArceOS build script for various platforms\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/arceos.sh <command> [options]\n'
    printf '\n'
    printf '<command>:\n'
    printf '  aarch64-dyn                   Build for aarch64-dyn platform\n'
    printf '  riscv64-qemu-virt             Build for riscv64-qemu-virt platform\n'
    printf '  x86-pc                        Build for x86-pc platform\n'
    printf '  all                           Build all supported platforms\n'
    printf '  clean                         Clean all supported platforms\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --repo-url <url>              tgoskits repository URL (default: https://github.com/rcore-os/tgoskits.git)\n'
    printf '  --src-dir <dir>               Source directory (default: build/tgoskits)\n'
    printf '  --patch-dir <dir>             Patch directory (default: patches/arceos)\n'
    printf '  --images-dir <dir>            Output images directory (default: IMAGES/arceos)\n'
    printf '  --image-name <name>           Output image name (default: current command)\n'
    printf '  The other options will be directly passed to cargo arceos build.\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  ARCEOS_REPO_URL               tgoskits repository URL\n'
    printf '  ARCEOS_REF                    tgoskits git commit/ref\n'
    printf '  ARCEOS_SRC_DIR                tgoskits source directory\n'
    printf '  ARCEOS_PATCH_DIR              ArceOS patch directory\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/arceos.sh aarch64-dyn --image-name arceos.bin\n'
    printf '  scripts/arceos.sh riscv64-qemu-virt clean\n'
}

arceos_parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repo-url)
                ARCEOS_REPO_URL="$2"
                shift 2
                ;;
            --src-dir)
                ARCEOS_SRC_DIR="$2"
                shift 2
                ;;
            --patch-dir)
                ARCEOS_PATCH_DIR="$2"
                shift 2
                ;;
            --images-dir)
                ARCEOS_IMAGES_DIR="$2"
                shift 2
                ;;
            --image-name)
                ARCEOS_IMAGE_NAME="$2"
                shift 2
                ;;
            *)
                ARCEOS_ARGS="$ARCEOS_ARGS $1"
                shift
                ;;
        esac
    done
}

arceos_build() {
    # Get platform-specific configuration
    local arch=$(get_platform_config "$ARCEOS_PLATFORM" "arch")
    local target=$(get_platform_config "$ARCEOS_PLATFORM" "target")

    if [[ -d "$ARCEOS_SRC_DIR" ]]; then
        pushd "$ARCEOS_SRC_DIR" >/dev/null

        local build_cmd="cargo arceos build --package ax-helloworld-myplat --arch $arch $ARCEOS_ARGS"
        info "EXEC: $build_cmd"
        cargo arceos build --package ax-helloworld-myplat --arch "$arch" $ARCEOS_ARGS

        popd >/dev/null
    fi

    if [[ "${ARCEOS_ARGS}" != *"clean"* ]]; then
        local bin_path="$ARCEOS_SRC_DIR/target/$target/release/ax-helloworld-myplat.bin"
        if [[ ! -f "$bin_path" ]]; then
            # x86_64 target does not produce .bin, use ELF directly
            bin_path="$ARCEOS_SRC_DIR/target/$target/release/ax-helloworld-myplat"
        fi
        info "Copying build artifacts: $bin_path -> $ARCEOS_IMAGES_DIR/$ARCEOS_IMAGE_NAME"
        mkdir -p "${ARCEOS_IMAGES_DIR}"
        cp "$bin_path" "${ARCEOS_IMAGES_DIR}/$ARCEOS_IMAGE_NAME"
    else
        info "Cleaning build artifacts in $ARCEOS_IMAGES_DIR"
        rm -rf "${ARCEOS_IMAGES_DIR}" || true
    fi
}

arceos() {
    if [[ "${ARCEOS_ARGS}" != *"clean"* ]]; then
        info "Cloning tgoskits source repository $ARCEOS_REPO_URL -> $ARCEOS_SRC_DIR"
        clone_repository "$ARCEOS_REPO_URL" "$ARCEOS_SRC_DIR"
        info "Checking out tgoskits ref ${ARCEOS_REF}"
        checkout_ref "$ARCEOS_SRC_DIR" "$ARCEOS_REF"

        if [[ -d "$ARCEOS_PATCH_DIR" ]]; then
            info "Applying patches..."
            apply_patches "$ARCEOS_PATCH_DIR" "$ARCEOS_SRC_DIR"
        fi
    fi

    arceos_build
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            arceos_usage
            exit 0
            ;;
        aarch64-dyn)
            ARCEOS_PLATFORM="aarch64-dyn"
            ;;
        riscv64-qemu-virt)
            ARCEOS_PLATFORM="riscv64-qemu-virt"
            ;;
        x86-pc)
            ARCEOS_PLATFORM="x86-pc"
            ;;
        all)
            for platform in aarch64-dyn riscv64-qemu-virt x86-pc; do
                "$0" "$platform" "$@" || { echo "[ERROR] $platform build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        clean)
            for platform in aarch64-dyn riscv64-qemu-virt x86-pc; do
                "$0" "$platform" "clean" || { echo "[ERROR] $platform build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac

    # Parse the other arguments
    arceos_parse_args "$@"

    if [[ -z "${ARCEOS_IMAGE_NAME}" ]]; then
        ARCEOS_IMAGE_NAME="${ARCEOS_PLATFORM}"
    fi

    # Call the main function
    arceos
fi
