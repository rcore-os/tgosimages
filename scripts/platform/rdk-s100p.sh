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
LINUX_SRC_DIR="${BUILD_DIR}/rdk-s100p"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/rdk-s100p"
PLATFORM_IMAGES_DIR="${ROOT_DIR}/IMAGES/rdk-s100p"
PLATFORM_ROOTFS_DIR="${ROOT_DIR}/IMAGES/rootfs"

# Apply patches to defconfig and uboot config (remote via SSH)
apply_patches_remote() {
    local patch_dir="$1"
    local remote_host="$2"
    local remote_dir="$3"
    
    if [[ ! -d "${patch_dir}" ]]; then
        info "No patch directory: ${patch_dir}"
        return 0
    fi
    
    shopt -s nullglob
    local patch_files=("${patch_dir}"/*.patch)
    if (( ${#patch_files[@]} == 0 )); then
        info "No patch files in ${patch_dir}"
        return 0
    fi
    
    info "Found ${#patch_files[@]} patch file(s)"
    
    for patch_file in "${patch_files[@]}"; do
        [[ -f "$patch_file" ]] || continue
        local base=$(basename "$patch_file")
        local stamp_dir="${remote_dir}/.patch_stamps"
        
        # Create stamp directory and check if already applied
        ssh "${remote_host}" "mkdir -p '${stamp_dir}'"
        if ssh "${remote_host}" "[ -f '${stamp_dir}/${base}.applied' ]"; then
            info "[SKIP] ${base} (already applied)"
            continue
        fi
        
        info "[APPLY] ${base}"
        
        # Try patch -p1 first, then patch -p0
        local applied=0
        for plevel in 1 0; do
            if ssh "${remote_host}" "cd '${remote_dir}' && patch -p${plevel} --dry-run" < "${patch_file}" >/dev/null 2>&1; then
                if ssh "${remote_host}" "cd '${remote_dir}' && patch -p${plevel}" < "${patch_file}"; then
                    ssh "${remote_host}" "touch '${stamp_dir}/${base}.applied'"
                    applied=1
                    info "  patch -p${plevel} applied"
                    break
                fi
            fi
        done
        
        if [[ $applied -eq 0 ]]; then
            warn "Failed to apply ${base}"
        fi
    done
}

apply_patches_local_sdk() (
    local patch_dir="$1"
    local sdk_dir="$2"
    local trusted_sdk="/share/guest-images/rdk_s100p"
    local resolved_sdk patch_file base applied plevel

    resolved_sdk=$(realpath -e -- "$sdk_dir") || {
        error "RDK S100P SDK path does not exist: $sdk_dir"
        exit 1
    }
    if [[ "$resolved_sdk" != "$trusted_sdk" ]]; then
        error "Refusing to patch untrusted RDK S100P SDK path: $resolved_sdk"
        exit 1
    fi

    shopt -s nullglob
    local patch_files=("$patch_dir"/*.patch "$patch_dir"/*.diff)
    info "Found ${#patch_files[@]} RDK S100P SDK patch file(s)"
    mkdir -p "$resolved_sdk/.patch_stamps"
    pushd "$resolved_sdk" >/dev/null
    for patch_file in "${patch_files[@]}"; do
        base=$(basename -- "$patch_file")
        applied=0
        if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
            info "[SKIP] $base (already applied)"
            applied=1
        elif git apply --check "$patch_file" >/dev/null 2>&1; then
            git apply "$patch_file"
            info "[APPLY] $base (git apply)"
            applied=1
        else
            for plevel in 1 0; do
                if patch --batch -R -p"$plevel" --dry-run <"$patch_file" >/dev/null 2>&1; then
                    info "[SKIP] $base (already applied, -p$plevel)"
                    applied=1
                    break
                fi
                if patch --batch -p"$plevel" --dry-run <"$patch_file" >/dev/null 2>&1; then
                    patch --batch -p"$plevel" <"$patch_file"
                    info "[APPLY] $base (patch -p$plevel)"
                    applied=1
                    break
                fi
            done
        fi
        if ((applied == 0)); then
            error "Cannot verify or apply RDK S100P SDK patch: $base"
            exit 1
        fi
        : >"$resolved_sdk/.patch_stamps/${base}.applied"
    done
    popd >/dev/null
)

# Output help information
usage() {
    printf 'Build supported OS for RDK S100P development board with rootfs support\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/rdk-s100p.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build Linux kernel and U-Boot\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/rdk-s100p.sh all          # Build everything\n'
    printf '  scripts/rdk-s100p.sh linux        # Build only Linux\n'
}

linux() {
    local linux_images_dir="${PLATFORM_IMAGES_DIR}/linux"

    if [[ "$@" != *"clean"* ]]; then
        info "Building to build the Linux system..."
    else
        info "Cleaning the Linux build artifacts..."
    fi

    # RDK S100P SDK is located at /share/guest-images/rdk_s100p
    REMOTE_HOST="10.3.10.194"
    REMOTE_DIR="/share/guest-images/rdk_s100p"
    BOOTLOADER_DIR="${REMOTE_DIR}/source/bootloader"
    KERNEL_DTB_REL="out/build/kernel/arch/arm64/boot/dts/hobot/rdk-s100p-v1p0.dtb"

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
            # Apply patches before build
            apply_patches_remote "${LINUX_PATCH_DIR}" "${REMOTE_HOST}" "${REMOTE_DIR}"
            
            # Build kernel
            info "Building kernel remotely via SSH"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./mk_kernel.sh"

            # Build uboot
            info "Building uboot remotely via SSH"
            # Create img_packages directory before build (mk_hb_img.py doesn't create it)
            ssh "${REMOTE_HOST}" "mkdir -p '${BOOTLOADER_DIR}/out/target/product/img_packages'"
            ssh "${REMOTE_HOST}" "cd '${BOOTLOADER_DIR}/build' && ./xbuild.sh lunch 1 && ./xbuild.sh uboot && ./xbuild.sh pack"

            # Copy kernel and uboot artifacts
            info "Copying build artifacts: -> $linux_images_dir"
            mkdir -p "${linux_images_dir}"
            # Copy kernel image
            scp "${REMOTE_HOST}:${REMOTE_DIR}/out/build/kernel/arch/arm64/boot/Image" "${linux_images_dir}/rdk-s100p"
            # Copy built kernel dtb needed for release
            scp "${REMOTE_HOST}:${REMOTE_DIR}/${KERNEL_DTB_REL}" "${linux_images_dir}/"
            # Copy uboot.img
            scp "${REMOTE_HOST}:${BOOTLOADER_DIR}/out/target/product/img_packages/uboot.img" "${linux_images_dir}/"
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; building locally in ${REMOTE_DIR}"
            if [[ -d "$REMOTE_DIR" ]]; then
                # Apply patches before build (locally)
                apply_patches_local_sdk "${LINUX_PATCH_DIR}" "${REMOTE_DIR}"
                
                # Build kernel
                info "Building kernel locally"
                (cd "$REMOTE_DIR" && ./mk_kernel.sh)

                # Build uboot
                info "Building uboot locally"
                # Create img_packages directory before build (mk_hb_img.py doesn't create it)
                mkdir -p "${BOOTLOADER_DIR}/out/target/product/img_packages"
                (cd "${BOOTLOADER_DIR}/build" && ./xbuild.sh lunch 1 && ./xbuild.sh uboot && ./xbuild.sh pack)
            else
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./mk_kernel.sh here as fallback"
                ./mk_kernel.sh
            fi

            # Copy kernel and uboot artifacts
            info "Copying build artifacts: -> $linux_images_dir"
            # Copy kernel image
            copy_required "${REMOTE_DIR}/out/build/kernel/arch/arm64/boot/Image" "${linux_images_dir}/rdk-s100p"
            # Copy built kernel dtb needed for release
            copy_required "${REMOTE_DIR}/${KERNEL_DTB_REL}" "${linux_images_dir}/$(basename "${KERNEL_DTB_REL}")"
            # Copy uboot.img
            copy_required "${BOOTLOADER_DIR}/out/target/product/img_packages/uboot.img" "${linux_images_dir}/uboot.img"
        fi
    else
        if $is_remote; then
            info "Cleaning kernel and uboot remotely via SSH"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./mk_kernel.sh clean"
            ssh "${REMOTE_HOST}" "cd '${BOOTLOADER_DIR}/build' && ./xbuild.sh uboot clean"
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; cleaning locally in ${REMOTE_DIR}"
            if [[ -d "$REMOTE_DIR" ]]; then
                (cd "$REMOTE_DIR" && ./mk_kernel.sh clean)
                (cd "${BOOTLOADER_DIR}/build" && ./xbuild.sh uboot clean)
            else
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./mk_kernel.sh clean here as fallback"
                ./mk_kernel.sh clean || true
            fi
        fi

        info "Removing ${linux_images_dir}/*"
        rm -f "${linux_images_dir}"/* || true
    fi
}

arceos() {
    local arceos_images_dir="${PLATFORM_IMAGES_DIR}/arceos"

    if [[ "$@" != *"clean"* ]]; then
        info "Building ArceOS using common arceos.sh script"
    else
        info "Cleaning ArceOS using common arceos.sh script"
    fi
    bash "${SCRIPT_DIR}/../os/arceos.sh" aarch64-dyn --images-dir "${arceos_images_dir}" --image-name rdk-s100p "$@"
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
    # if [[ "$cmd" != "clean" ]]; then
    #     rootfs_inject_guest_stage "$linux_images_dir/rdk-s100p.img" "${PLATFORM_IMAGES_DIR}"
    # fi
fi
