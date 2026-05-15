#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"
source "${SCRIPT_DIR}/../lib/rootfs.sh"

# Repository and directory configuration
LINUX_REPO_URL=""
LINUX_SRC_DIR="${BUILD_DIR}/roc-rk3568-pc"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/roc-rk3568-pc"
PLATFORM_IMAGES_DIR="${ROOT_DIR}/IMAGES/roc-rk3568-pc"
PLATFORM_ROOTFS_DIR="${ROOT_DIR}/IMAGES/rootfs"

# Output help information
usage() {
    printf 'Build supported OS for ROC-RK3588-PC development board with rootfs support\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/roc-rk3568-pc.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build only the Linux system\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  rtthread                          Build only the RT-Thread system\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/roc-rk3568-pc.sh all      # Build everything\n'
    printf '  scripts/roc-rk3568-pc.sh linux    # Build only Linux\n'
}

linux() {
    local linux_images_dir="${PLATFORM_IMAGES_DIR}/linux"

    if [[ "$@" != *"clean"* ]]; then
        info "Building to build the Linux system..."
    else
        info "Cleaning the Linux build artifacts..."
    fi

    # Since Rockchip's Linux SDK is managed by a large repository using repo, and manufacturers usually do not provide online repositories (typically only compressed packages), we log in to a prepared SDK server via SSH for building.
    REMOTE_HOST="10.3.10.194"
    REMOTE_DIR="/share/guest-images/firefly_rk3568_sdk"
    REMOTE_IMAGES_DIR="output/RK3568-FIREFLY-ROC-PC-SE/latest/IMAGES"
    # Determine local IP addresses (IPv4) to detect if we are on REMOTE_HOST.
    # We collect all non-loopback IPv4 addresses assigned to the host.
    mapfile -t _local_ips < <(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)

    is_remote=true
    for ipaddr in "${_local_ips[@]:-}"; do
        if [[ "$ipaddr" == "$REMOTE_HOST" ]]; then
            is_remote=false
            break
        fi
    done

    if [[ "$@" != *"clean"* ]]; then
        if $is_remote; then
            info "Building remotely via SSH: ssh ${REMOTE_HOST} cd '${REMOTE_DIR}' && ./build.sh firefly_rk3568_roc-rk3568-pc_ubuntu_defconfig && ./build.sh $@"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./build.sh firefly_rk3568_roc-rk3568-pc_ubuntu_defconfig && ./build.sh $@"

            info "Copying build artifacts: -> $linux_images_dir"
            mkdir -p "${linux_images_dir}"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/boot.img" "${linux_images_dir}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/parameter.txt" "${linux_images_dir}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/MiniLoaderAll.bin" "${linux_images_dir}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/../kernel/rk3568-firefly-roc-pc-se.dtb" "${linux_images_dir}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/kernel/arch/arm64/boot/Image" "${linux_images_dir}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/rootfs.img" "${linux_images_dir}/roc-rk3568-pc.img"
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; building locally in ${REMOTE_DIR}"
            # If the REMOTE_DIR doesn't exist locally, fall back to running commands in place (assume local repo available at REMOTE_DIR)
            if [[ -d "$REMOTE_DIR" ]]; then
                (cd "$REMOTE_DIR" && ./build.sh firefly_rk3568_roc-rk3568-pc_ubuntu_defconfig && ./build.sh $@)
            else
                # If REMOTE_DIR is unavailable, attempt to run build in current directory as a best-effort
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./build.sh here as fallback"
                ./build.sh firefly_rk3568_roc-rk3568-pc_ubuntu_defconfig && ./build.sh $@
            fi

            info "Copying build artifacts: -> $linux_images_dir"
            mkdir -p "${linux_images_dir}"
            cp "${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/boot.img" "${linux_images_dir}/" 2>/dev/null || true
            cp "${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/parameter.txt" "${linux_images_dir}/" 2>/dev/null || true
            cp "${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/MiniLoaderAll.bin" "${linux_images_dir}/" 2>/dev/null || true
            cp "${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/../kernel/rk3568-firefly-roc-pc-se.dtb" "${linux_images_dir}/roc-rk3568-pc.dtb" 2>/dev/null || true
            cp "${REMOTE_DIR}/kernel/arch/arm64/boot/Image" "${linux_images_dir}/roc-rk3568-pc" 2>/dev/null || true
            cp "${REMOTE_DIR}/u-boot/uboot.img" "${linux_images_dir}/roc-rk3568-pc_uboot.img" 2>/dev/null || true
            cp "${REMOTE_DIR}/${REMOTE_IMAGES_DIR}/rootfs.img" "${PLATFORM_ROOTFS_DIR}/roc-rk3568-pc.img" 2>/dev/null || true
            chmod a+rw "${PLATFORM_ROOTFS_DIR}/roc-rk3568-pc.img" 2>/dev/null || true

        fi
    else
        if $is_remote; then
            info "Cleaning remotely via SSH: ssh ${REMOTE_HOST} cd '${REMOTE_DIR}' && ./build.sh cleanall"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./build.sh cleanall"
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; cleaning locally in ${REMOTE_DIR}"
            if [[ -d "$REMOTE_DIR" ]]; then
                (cd "$REMOTE_DIR" && ./build.sh cleanall)
            else
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./build.sh cleanall here as fallback"
                ./build.sh cleanall || true
            fi
        fi

        info "Removing ${linux_images_dir}/*"
        rm -f "${linux_images_dir}"/* || true
        rm -f "${PLATFORM_ROOTFS_DIR}/roc-rk3568-pc.img" || true
    fi
}

arceos() {
    local arceos_images_dir="${PLATFORM_IMAGES_DIR}/arceos"

    if [[ "$@" != *"clean"* ]]; then
        info "Building ArceOS using common arceos.sh script"
    else
        info "Cleaning ArceOS using common arceos.sh script"
    fi
    bash "${SCRIPT_DIR}/../os/arceos.sh" aarch64-dyn --images-dir "${arceos_images_dir}" --image-name roc-rk3568-pc "$@"
}

rtthread() {
    local rtthread_images_dir="${PLATFORM_IMAGES_DIR}/rtthread"

    if [[ "$@" != *"clean"* ]]; then
        info "Building RT-Thread using common rtthread.sh script"
        bash "${SCRIPT_DIR}/../os/rtthread.sh" roc-rk3568-pc "--images-dir" "${rtthread_images_dir}" "--image-name" "roc-rk3568-pc" "$@"
    else
        info "Cleaning RT-Thread using common rtthread.sh script"
        bash "${SCRIPT_DIR}/../os/rtthread.sh" roc-rk3568-pc "--images-dir" "${rtthread_images_dir}" "--image-name" "roc-rk3568-pc" "--patch-dir" "" "-c"
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
        all)
            linux "$@"

            arceos "$@"

            rtthread "$@"
            ;;
        clean)
            linux "clean"

            arceos "clean"

            rtthread "clean"
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
    if [[ "$cmd" != "clean" ]]; then
        rootfs_inject_guest_stage "${PLATFORM_ROOTFS_DIR}/roc-rk3568-pc.img" "${PLATFORM_IMAGES_DIR}"
    fi
fi
