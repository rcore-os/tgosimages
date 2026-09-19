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
LINUX_REPO_URL=""
LINUX_SRC_DIR="${BUILD_DIR}/evm3588"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/evm3588"
PLATFORM_IMAGES_DIR="${ROOT_DIR}/IMAGES/evm3588"
PLATFORM_ROOTFS_DIR="${ROOT_DIR}/IMAGES/rootfs"

# Output help information
usage() {
    printf 'Build supported OS for EVM3588 development board with rootfs support\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/evm3588.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build only the Linux system\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/evm3588.sh all            # Build everything\n'
    printf '  scripts/evm3588.sh linux          # Build only Linux\n'
}

linux() {
    local linux_images_dir="${PLATFORM_IMAGES_DIR}/linux"

    if [[ "$@" != *"clean"* ]]; then
        info "Building to build the Linux system..."
    else
        info "Cleaning the Linux build artifacts..."
    fi

    # Since the Linux SDK from Rockchip is managed by a large repository using repo, and manufacturers usually do not provide online repositories (typically only compressed packages), we log in to a prepared SDK server via SSH for building.
    REMOTE_HOST="10.3.10.194"
    REMOTE_DIR="/share/guest-images/evm3588_linux_sdk_v1.0.3"

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
            info "Building remotely via SSH：ssh ${REMOTE_HOST} cd '${REMOTE_DIR}' && ./build.sh $@"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./build.sh $@"

            info "Copying build artifacts: -> $linux_images_dir"
            mkdir -p "${linux_images_dir}"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/rockdev/boot.img" "${linux_images_dir}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/rockdev/MiniLoaderAll.bin" "${linux_images_dir}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/rockdev/parameter.txt" "${linux_images_dir}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/kernel/arch/arm64/boot/Image" "${linux_images_dir}/evm3588"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/kernel/arch/arm64/boot/dts/rockchip/evm3588.dtb" "${linux_images_dir}/evm3588.dtb"
            mkdir -p "${PLATFORM_ROOTFS_DIR}"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/rockdev/rootfs.img" "${PLATFORM_ROOTFS_DIR}/evm3588.img" 2>/dev/null || warn "Optional rootfs image not found: ${REMOTE_DIR}/rockdev/rootfs.img"
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; building locally in ${REMOTE_DIR}"
            if [[ -d "$REMOTE_DIR" ]]; then
                (cd "$REMOTE_DIR" && ./build.sh $@)
            else
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./build.sh here as fallback"
                ./build.sh $@
            fi

            info "Copying build artifacts: -> $linux_images_dir"
            copy_required "${REMOTE_DIR}/rockdev/boot.img" "${linux_images_dir}/boot.img"
            copy_required "${REMOTE_DIR}/rockdev/MiniLoaderAll.bin" "${linux_images_dir}/MiniLoaderAll.bin"
            copy_required "${REMOTE_DIR}/rockdev/parameter.txt" "${linux_images_dir}/parameter.txt"
            copy_required "${REMOTE_DIR}/kernel/arch/arm64/boot/Image" "${linux_images_dir}/evm3588"
            copy_required "${REMOTE_DIR}/kernel/arch/arm64/boot/dts/rockchip/evm3588.dtb" "${linux_images_dir}/evm3588.dtb"
            copy_optional "${REMOTE_DIR}/rockdev/rootfs.img" "${PLATFORM_ROOTFS_DIR}/evm3588.img"
        fi
    else
        if $is_remote; then
            info "Cleaning remotely via SSH：ssh ${REMOTE_HOST} cd '${REMOTE_DIR}' && ./build.sh cleanall"
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
        rm -f "${PLATFORM_ROOTFS_DIR}/evm3588.img" || true
    fi
}

arceos() {
    local arceos_images_dir="${PLATFORM_IMAGES_DIR}/arceos"

    if [[ "$@" != *"clean"* ]]; then
        info "Building ArceOS using common arceos.sh script"
    else
        info "Cleaning ArceOS using common arceos.sh script"
    fi
    bash "${SCRIPT_DIR}/../os/arceos.sh" aarch64-dyn --images-dir "${arceos_images_dir}" --image-name evm3588_arceos "$@"
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
        all)
            run_parallel_functions "all" linux arceos -- "$@"
            ;;
        clean)
            run_parallel_functions "clean" linux arceos -- clean
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
    if [[ "$cmd" != "clean" ]]; then
        rootfs_inject_guest_stage "${PLATFORM_ROOTFS_DIR}/evm3588.img" "${PLATFORM_IMAGES_DIR}"
    fi
fi
