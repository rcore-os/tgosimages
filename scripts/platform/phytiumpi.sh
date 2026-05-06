#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"
source "${SCRIPT_DIR}/../lib/rootfs.sh"

# Repository and directory configuration
LINUX_REPO_URL="https://gitee.com/phytium_embedded/phytium-pi-os.git"
LINUX_REF="2841c3d939f32c8ac1ca57e3f4d2a8c5ed6ebd63"
LINUX_SRC_DIR="${BUILD_DIR}/phytium-pi-os"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/phytiumpi"
PLATFORM_IMAGES_DIR="${ROOT_DIR}/IMAGES/phytiumpi"
PLATFORM_ROOTFS_DIR="${ROOT_DIR}/IMAGES/rootfs"

# Output help information
usage() {
    printf 'Build supported OS for Phytium development board with rootfs support\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/phytiumpi.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build only the Linux system\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  rtthread                          Build only the RT-Thread system\n'
    printf '  zephyr                            Build only the Zephyr guest image\n'
    printf '  freertos                          Build only the FreeRTOS guest image\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/phytiumpi.sh all          # Build everything\n'
    printf '  scripts/phytiumpi.sh linux        # Build only Linux\n'
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
        pushd "$LINUX_SRC_DIR" >/dev/null
        if [[ "$@" != *"clean"* ]]; then
            info "Configuring build: make phytiumpi_desktop_defconfig"
            make phytiumpi_desktop_defconfig

            info "Starting compilation: make $@"
            make $@
            
            info "Copying build artifacts: $LINUX_SRC_DIR/output/images -> $linux_images_dir"
            mkdir -p "$linux_images_dir"
            rsync -av --ignore-missing-args "$LINUX_SRC_DIR/output/images/fip-all.bin" \
            "$LINUX_SRC_DIR/output/images/fitImage" \
            "$LINUX_SRC_DIR/output/images/kernel.its" \
            "$LINUX_SRC_DIR/output/images/Image" \
            "$LINUX_SRC_DIR/output/images/phytiumpi_firefly.dtb" \
            "$LINUX_SRC_DIR/output/images/sdcard.img" \
            "$LINUX_SRC_DIR/output/images/rootfs.ext2" \
            "$linux_images_dir/"
            [[ -f "$linux_images_dir/phytiumpi_firefly.dtb" ]] && mv "$linux_images_dir/phytiumpi_firefly.dtb" "$linux_images_dir/phytiumpi.dtb"
            [[ -f "$LINUX_SRC_DIR/output/images/Image.gz" ]] && gzip -dc "$LINUX_SRC_DIR/output/images/Image.gz" > "$linux_images_dir/phytiumpi"
            mkdir -p "$PLATFORM_ROOTFS_DIR"
            [[ -f "$linux_images_dir/sdcard.img" ]] && cp -f "$linux_images_dir/sdcard.img" "$PLATFORM_ROOTFS_DIR/phytiumpi.img"
            [[ -f "$linux_images_dir/rootfs.ext2" ]] && cp -f "$linux_images_dir/rootfs.ext2" "$PLATFORM_ROOTFS_DIR/phytiumpi.rootfs.ext2"
        else
            info "Cleaning: make $@"
            make $@
            info "Removing ${linux_images_dir}/*"
            rm "${linux_images_dir}"/* || true
            rm -f "${PLATFORM_ROOTFS_DIR}/phytiumpi.img" || true
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
    bash "${SCRIPT_DIR}/../os/arceos.sh" aarch64-dyn --images-dir "${arceos_images_dir}" --image-name phytiumpi "$@"
}

rtthread() {
    local rtthread_images_dir="${PLATFORM_IMAGES_DIR}/rtthread"

    if [[ "$@" != *"clean"* ]]; then
        info "Building RT-Thread using common rtthread.sh script"
        bash "${SCRIPT_DIR}/../os/rtthread.sh" phytiumpi "--images-dir" "${rtthread_images_dir}" "--image-name" "phytiumpi" "$@"
    else
        info "Cleaning RT-Thread using common rtthread.sh script"
        bash "${SCRIPT_DIR}/../os/rtthread.sh" phytiumpi "--images-dir" "${rtthread_images_dir}" "--image-name" "phytiumpi" "-c"
    fi
}

zephyr() {
    local zephyr_images_dir="${PLATFORM_IMAGES_DIR}/zephyr"

    if [[ "$@" != *"clean"* ]]; then
        info "Building Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/../os/zephyr.sh" phytiumpi --images-dir "${zephyr_images_dir}" "$@"
    else
        info "Cleaning Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/../os/zephyr.sh" phytiumpi clean --images-dir "${zephyr_images_dir}"
    fi
}

freertos() {
    local freertos_images_dir="${PLATFORM_IMAGES_DIR}/freertos"

    if [[ "$@" != *"clean"* ]]; then
        info "Building FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/../os/freertos.sh" phytiumpi --images-dir "${freertos_images_dir}" --image-name "phytiumpi" "$@"
    else
        info "Cleaning FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/../os/freertos.sh" phytiumpi clean --images-dir "${freertos_images_dir}" --image-name "phytiumpi"
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
        rtthread)
            rtthread "$@"
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

            rtthread "$@"

            zephyr "$@"

            freertos "$@"
            ;;
        clean)
            linux "clean"

            arceos "clean"

            rtthread "clean"

            zephyr "clean"

            freertos "clean"
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
    if [[ "$cmd" != "clean" ]]; then
        rootfs_inject_guest_stage "$PLATFORM_ROOTFS_DIR/phytiumpi.rootfs.ext2" "${PLATFORM_IMAGES_DIR}" || true
    fi
fi
