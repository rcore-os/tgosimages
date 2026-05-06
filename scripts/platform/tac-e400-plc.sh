#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"
source "${SCRIPT_DIR}/../lib/rootfs.sh"

# Repository and directory configuration
LINUX_REPO_URL="git@github.com:arceos-hypervisor/tac-e400-plc.git"
LINUX_REF="34b97418d663621b2c5d87e3c2faaa8c48dc2756"
LINUX_SRC_DIR="${BUILD_DIR}/tac-e400-plc"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/tac-e400-plc"
PLATFORM_IMAGES_DIR="${ROOT_DIR}/IMAGES/tac-e400-plc"
PLATFORM_ROOTFS_DIR="${ROOT_DIR}/IMAGES/rootfs"

# Output help information
usage() {
    printf 'Build supported OS for TAC-E400 series intelligent PLC products with rootfs support\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/tac-e400-plc.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build only the Linux system\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  zephyr                            Build only the Zephyr guest image\n'
    printf '  freertos                          Build only the FreeRTOS guest image\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tac-e400-plc.sh all       # Build everything\n'
    printf '  scripts/tac-e400-plc.sh linux     # Build only Linux\n'
}

linux() {
    local linux_images_dir="${PLATFORM_IMAGES_DIR}/linux"

    if [[ "$@" != *"clean"* ]]; then
        info "Cloning Linux source repository $LINUX_REPO_URL -> $LINUX_SRC_DIR"
        clone_repository "$LINUX_REPO_URL" "$LINUX_SRC_DIR"
        info "Checking out Linux ref ${LINUX_REF}"
        checkout_ref "$LINUX_SRC_DIR" "$LINUX_REF"
        
        if [[ -d "$LINUX_PATCH_DIR" ]]; then
            info "Applying patches..."
            apply_patches "$LINUX_PATCH_DIR" "$LINUX_SRC_DIR"
        fi
        info "Building to build the Linux system..."
    else
        info "Cleaning the Linux build artifacts..."
    fi

    if [[ -d "$LINUX_SRC_DIR" ]]; then
        pushd "$LINUX_SRC_DIR/EDGE_KERNEL" >/dev/null
        if [[ "$@" != *"clean"* ]]; then
            info "Configuring kernel: cp \"$LINUX_SRC_DIR/.config\" .config"
            cp "$LINUX_SRC_DIR/.config" .config

            info "Starting compilation: make -j$(nproc) $@"
            make -j$(nproc) $@ 2>&1

            info "Copying build artifacts -> $linux_images_dir"
            mkdir -p "$linux_images_dir"
            cp "$LINUX_SRC_DIR/EDGE_KERNEL/arch/arm64/boot/Image" "$linux_images_dir/tac-e400-plc"
            cp "$LINUX_SRC_DIR/EDGE_KERNEL/arch/arm64/boot/dts/phytium/e2000q-hanwei-board.dtb" "$linux_images_dir/tac-e400-plc.dtb"
        else
            info "Cleaning: make -j$(nproc) clean"
            make -j$(nproc) clean 2>&1
            info "Removing ${linux_images_dir}/*"
            rm "${linux_images_dir}"/* || true
        fi
        popd >/dev/null
    fi
}

arceos() {
    local arceos_images_dir="${PLATFORM_IMAGES_DIR}/arceos"

    if [[ "$@" != *"clean"* ]]; then
        info "Building ArceOS using common arceos.sh script"
    else
        info "Cleaning ArceOS using common arceos.sh script"
    fi
    bash "${SCRIPT_DIR}/../os/arceos.sh" aarch64-dyn --images-dir "${arceos_images_dir}" --image-name tac-e400-plc "$@"
}

zephyr() {
    local zephyr_images_dir="${PLATFORM_IMAGES_DIR}/zephyr"

    if [[ "$@" != *"clean"* ]]; then
        info "Building Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/../os/zephyr.sh" tac-e400-plc --images-dir "${zephyr_images_dir}" "$@"
    else
        info "Cleaning Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/../os/zephyr.sh" tac-e400-plc clean --images-dir "${zephyr_images_dir}"
    fi
}

freertos() {
    local freertos_images_dir="${PLATFORM_IMAGES_DIR}/freertos"

    if [[ "$@" != *"clean"* ]]; then
        info "Building FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/../os/freertos.sh" tac-e400-plc --images-dir "${freertos_images_dir}" --image-name "tac-e400-plc" "$@"
    else
        info "Cleaning FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/../os/freertos.sh" tac-e400-plc clean --images-dir "${freertos_images_dir}" --image-name "tac-e400-plc"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            usage
            exit 0
            ;;
        linux)
            linux "$@"
            ;;
        arceos)
            arceos "$@"
            ;;
        zephyr)
            zephyr "$@"
            ;;
        freertos)
            freertos "$@"
            ;;
        all)
            linux "$@"

            arceos "$@"

            zephyr "$@"

            freertos "$@"
            ;;
        clean)
            linux "clean"

            arceos "clean"

            zephyr "clean"

            freertos "clean"
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
    # if [[ "$cmd" != "clean" ]]; then
    #     rootfs_inject_guest_stage "${PLATFORM_ROOTFS_DIR}/tac-e400-plc.img" "${PLATFORM_IMAGES_DIR}"
    # fi
fi
