#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    source "${ROOT_DIR}/scripts/lib/platform-graph-entry.sh"
fi
source "${ROOT_DIR}/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"

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

phytiumpi_unmount_rootfs_mounts() {
    local rootfs="$LINUX_SRC_DIR/output/build/skeleton-custom" relative path staging_sys
    local had_mount=0
    local -a mount_paths=(dev/pts dev proc sys)

    [[ -d $rootfs ]] || return 0
    build_assert_workspace_path "$rootfs" || return 1
    for relative in "${mount_paths[@]}"; do
        path="$rootfs/$relative"
        mountpoint -q "$path" || continue
        had_mount=1
        info "Unmounting stale Phytium rootfs mount: $path"
        sudo umount -R -- "$path" || return 1
    done
    for relative in "${mount_paths[@]}"; do
        path="$rootfs/$relative"
        mountpoint -q "$path" || continue
        error "Phytium rootfs mount is still active: $path"
        return 1
    done
    if ((had_mount)) && [[ -d $LINUX_SRC_DIR/output/host ]]; then
        while IFS= read -r -d '' staging_sys; do
            case $staging_sys in
                "$LINUX_SRC_DIR/output/host/"*/sysroot/sys) ;;
                *) error "Refusing unexpected Phytium staging sys path: $staging_sys"; return 1 ;;
            esac
            mountpoint -q "$staging_sys" && {
                error "Refusing to remove mounted Phytium staging sys path: $staging_sys"
                return 1
            }
            info "Removing sysfs files copied into Phytium staging: $staging_sys"
            rm -rf -- "$staging_sys" || return 1
        done < <(find "$LINUX_SRC_DIR/output/host" -mindepth 3 -maxdepth 3 \
            -type d -path '*/sysroot/sys' -print0)
    fi
}

phytiumpi_publish_linux_artifacts() {
    local source_images="${1:-$LINUX_SRC_DIR/output/images}"
    local linux_images_dir="${2:-$PLATFORM_IMAGES_DIR/linux}"
    local rootfs_dir="${3:-$PLATFORM_ROOTFS_DIR}"
    local artifact kernel_tmp

    for artifact in fip-all.bin fitImage kernel.its Image.gz phytiumpi_firefly.dtb sdcard.img rootfs.ext2; do
        [[ -f $source_images/$artifact ]] || die "Required artifact not found: $source_images/$artifact"
    done

    info "Copying build artifacts: $source_images -> $linux_images_dir"
    copy_required "$source_images/fip-all.bin" "$linux_images_dir/fip-all.bin"
    copy_required "$source_images/fitImage" "$linux_images_dir/fitImage"
    copy_required "$source_images/kernel.its" "$linux_images_dir/kernel.its"
    copy_required "$source_images/phytiumpi_firefly.dtb" "$linux_images_dir/phytiumpi.dtb"
    # The whole platform images directory becomes /guest during compose. Keep
    # container/rootfs images out of it: besides being useless guest payloads,
    # either one is large enough to exhaust the filesystem being composed.
    rm -f -- "$linux_images_dir/sdcard.img" "$linux_images_dir/rootfs.ext2"

    kernel_tmp=$(mktemp "$linux_images_dir/.Image.tmp.XXXXXX")
    if ! gzip -dc -- "$source_images/Image.gz" >"$kernel_tmp"; then
        rm -f -- "$kernel_tmp"
        die "Failed to decompress required artifact: $source_images/Image.gz"
    fi
    mv -f -- "$kernel_tmp" "$linux_images_dir/Image"
    copy_required "$linux_images_dir/Image" "$linux_images_dir/phytiumpi"

    mkdir -p "$rootfs_dir"
    copy_required "$source_images/sdcard.img" "$rootfs_dir/phytiumpi.img"
    copy_required "$source_images/rootfs.ext2" "$rootfs_dir/phytiumpi.rootfs.ext2"
}

linux() (
    local linux_images_dir="${PLATFORM_IMAGES_DIR}/linux"
    local cleanup_status status

    cleanup_status=0
    trap '
        status=$?
        trap - EXIT INT TERM
        phytiumpi_unmount_rootfs_mounts || cleanup_status=$?
        ((status != 0)) || status=$cleanup_status
        exit "$status"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    phytiumpi_unmount_rootfs_mounts

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
            build_make phytiumpi_desktop_defconfig || {
                local status=$?
                popd >/dev/null
                return "$status"
            }

            info "Starting compilation: make $@"
            build_make "$@" || {
                local status=$?
                popd >/dev/null
                return "$status"
            }
            
            phytiumpi_publish_linux_artifacts
        else
            info "Cleaning: make $@"
            build_make $@
            info "Removing ${linux_images_dir}/*"
            rm "${linux_images_dir}"/* || true
            rm -f "${PLATFORM_ROOTFS_DIR}/phytiumpi.img" || true
        fi
        popd >/dev/null
    fi
)

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
    source "${SCRIPT_DIR}/../lib/platform-log.sh"
    platform_log_init "$@"
    cmd="${1:-}"
    if [[ "${cmd}" =~ ^(all|clean)$ ]]; then
        LOG_CREATE_DEFAULT_FILE="${LOG_CREATE_DEFAULT_FILE:-0}"
    fi
    source "${SCRIPT_DIR}/../lib/utils.sh"
    source "${SCRIPT_DIR}/../lib/rootfs.sh"
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
            run_parallel_functions "all" linux arceos rtthread zephyr freertos -- "$@"
            ;;
        clean)
            run_parallel_functions "clean" linux arceos rtthread zephyr freertos -- clean
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
    if [[ "$cmd" != "clean" ]]; then
        rootfs_inject_guest_stage "$PLATFORM_ROOTFS_DIR/phytiumpi.rootfs.ext2" "${PLATFORM_IMAGES_DIR}" || true
    fi
fi
