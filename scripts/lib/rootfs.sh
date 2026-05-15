#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library, should be sourced, not executed." >&2
    exit 1
fi

rootfs_stage_guest_tree() {
    local stage_dir="$1"
    local source_dir="$2"
    local guest_dir

    [[ -d "${stage_dir}" ]] || die "Guest stage directory not found: ${stage_dir}"
    [[ -d "${source_dir}" ]] || die "Guest payload source directory not found: ${source_dir}"

    guest_dir="${stage_dir}/guest"
    rm -rf "${guest_dir}"
    mkdir -p "${guest_dir}"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${source_dir}/" "${guest_dir}/"
    else
        cp -a "${source_dir}/." "${guest_dir}/"
    fi
}

rootfs_prepare_target() {
    local rootfs_target="$1"

    [[ -n "${rootfs_target}" ]] || die "rootfs target is empty"
    mkdir -p "$(dirname "${rootfs_target}")"
    rm -f "${rootfs_target}"
}

rootfs_publish_target() {
    local source_path="$1"
    local target_path="$2"

    [[ -f "${source_path}" ]] || return 1
    rootfs_prepare_target "${target_path}"
    cp -f "${source_path}" "${target_path}"
}

_rootfs_detect_fs_type() {
    local target="$1"
    local fs_type=""

    fs_type="$(blkid -o value -s TYPE "${target}" 2>/dev/null || true)"
    if [[ -n "${fs_type}" ]]; then
        printf '%s\n' "${fs_type}"
        return 0
    fi

    if command -v file >/dev/null 2>&1; then
        file -b "${target}" 2>/dev/null | awk '
            /ext2 filesystem/ { print "ext2"; exit }
            /ext3 filesystem/ { print "ext3"; exit }
            /ext4 filesystem/ { print "ext4"; exit }
        '
    fi
}

_rootfs_inject_tree_via_debugfs() {
    local image_path="$1"
    local source_dir="$2"
    local abs_source
    local rel_path
    local target_path
    local link_target

    command -v debugfs >/dev/null 2>&1 || {
        warn "debugfs not found, cannot inject into ext filesystem image: ${image_path}"
        return 1
    }

    abs_source="$(cd "${source_dir}" && pwd -P)"
    pushd "${abs_source}" >/dev/null

    while IFS= read -r rel_path; do
        [[ "${rel_path}" == "." ]] && continue
        target_path="/${rel_path#./}"
        debugfs -w -R "mkdir ${target_path}" "${image_path}" >/dev/null 2>&1 || true
    done < <(find . -type d | sort)

    while IFS= read -r rel_path; do
        target_path="/${rel_path#./}"
        debugfs -w -R "rm ${target_path}" "${image_path}" >/dev/null 2>&1 || true
        debugfs -w -R "write ${abs_source}/${rel_path#./} ${target_path}" "${image_path}" >/dev/null || {
            popd >/dev/null
            return 1
        }
    done < <(find . -type f | sort)

    while IFS= read -r rel_path; do
        target_path="/${rel_path#./}"
        link_target="$(readlink "${rel_path}")"
        debugfs -w -R "rm ${target_path}" "${image_path}" >/dev/null 2>&1 || true
        debugfs -w -R "symlink ${target_path} ${link_target}" "${image_path}" >/dev/null || {
            popd >/dev/null
            return 1
        }
    done < <(find . -type l | sort)

    popd >/dev/null
}

_rootfs_inject_tree_via_loop_mount() {
    local image_path="$1"
    local source_dir="$2"
    local loop_dev=""
    local mount_dir=""
    local root_partition=""
    local status=0

    command -v losetup >/dev/null 2>&1 || return 1
    command -v lsblk >/dev/null 2>&1 || return 1
    command -v mount >/dev/null 2>&1 || return 1

    if [[ "${EUID}" -ne 0 ]]; then
        warn "Loop-mount injection requires root privileges: ${image_path}"
        return 1
    fi

    loop_dev="$(losetup --find --show --partscan "${image_path}")" || return 1
    mount_dir="$(mktemp -d "${BUILD_DIR}/rootfs-mount.XXXXXX")"

    root_partition="$(
        lsblk -lnbo NAME,FSTYPE,SIZE "${loop_dev}" 2>/dev/null \
            | awk '$2 ~ /^ext[234]$/ { print $1, $3 }' \
            | sort -k2 -nr \
            | head -n1 \
            | awk '{ print $1 }'
    )"

    if [[ -z "${root_partition}" ]]; then
        warn "No ext filesystem partition found in disk image: ${image_path}"
        status=1
    elif ! mount "${root_partition}" "${mount_dir}"; then
        warn "Failed to mount rootfs partition ${root_partition} from ${image_path}"
        status=1
    else
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "${source_dir}/" "${mount_dir}/" || status=1
        else
            cp -a "${source_dir}/." "${mount_dir}/" || status=1
        fi
        sync
        umount "${mount_dir}" || status=1
    fi

    losetup -d "${loop_dev}" >/dev/null 2>&1 || true
    rm -rf "${mount_dir}"
    return "${status}"
}

# Probe partitions by extracting and checking filesystem type (fallback for unknown GPT GUIDs)
_probe_partitions_for_ext() {
    local image_path="$1"
    local json_start json_size p_start p_size tmp_part fs_type
    local best_start="" best_size=0

    # Parse partition table via JSON output
    while IFS= read -r line; do
        json_start="$(echo "$line" | awk '{print $1}')"
        json_size="$(echo "$line" | awk '{print $2}')"
        [[ -n "${json_start}" && -n "${json_size}" ]] || continue

        tmp_part="$(mktemp "${BUILD_DIR}/rootfs-probe.XXXXXX")"
        dd if="${image_path}" of="${tmp_part}" bs=512 skip="${json_start}" count="${json_size}" >/dev/null 2>&1 || {
            rm -f "${tmp_part}"
            continue
        }

        fs_type="$(_rootfs_detect_fs_type "${tmp_part}")"
        rm -f "${tmp_part}"

        if [[ "${fs_type}" =~ ^ext[234]$ ]]; then
            if [[ "${json_size}" -gt "${best_size}" ]]; then
                best_size="${json_size}"
                best_start="${json_start}"
            fi
        fi
    done < <(sfdisk -J "${image_path}" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('partitiontable', {}).get('partitions', []):
    print(p.get('start', 0), p.get('size', 0))
" 2>/dev/null)

    if [[ -n "${best_start}" ]]; then
        printf '%s %s\n' "${best_start}" "${best_size}"
    fi
}

# Extract ext partition from disk image, inject via debugfs, write back (no root required)
_rootfs_inject_tree_via_partition_extract() {
    local image_path="$1"
    local source_dir="$2"
    local part_info part_start part_size
    local tmp_partition

    command -v sfdisk >/dev/null 2>&1 || return 1
    command -v debugfs >/dev/null 2>&1 || return 1

    # Well-known GPT type GUIDs for Linux partitions (case-insensitive)
    local gpt_linux_guids
    gpt_linux_guids="0fc63daf-8483-4772-8e79-3d69d8477de4|44479540-f297-41b2-9af7-d131d5f0458a|4f68bce3-e8cd-4db1-96e7-fbcaf984b709|b921b045-1df0-41c3-af44-4c6f280d3fae|69dad710-2ce4-4e3c-b16c-21a1d49abed3"

    # Find the largest Linux/ext partition (sectors are 512-byte units)
    part_info="$(
        sfdisk -d "${image_path}" 2>/dev/null | awk -F'[=, ]+' '
            /start=/ {
                start = 0; size = 0; type = ""
                for (i = 1; i <= NF; i++) {
                    if ($i == "start") start = $(i+1)
                    if ($i == "size") size = $(i+1)
                    if ($i == "type") type = $(i+1)
                }
                # MBR type 83 (Linux), or GPT Linux filesystem GUIDs, or name contains linux/ext
                if (type == "83" || tolower(type) ~ /'"${gpt_linux_guids}"'/ || tolower(type) ~ /ext|linux/) {
                    if (size+0 > max_size+0) {
                        max_size = size+0
                        max_start = start+0
                    }
                }
            }
            END {
                if (max_size > 0) print max_start, max_size
            }
        '
    )"

    # Fallback: probe each partition's actual filesystem
    if [[ -z "${part_info}" ]]; then
        part_info="$( _probe_partitions_for_ext "${image_path}" )"
    fi

    if [[ -z "${part_info}" ]]; then
        warn "No Linux/ext partition found in disk image: ${image_path}"
        return 1
    fi

    part_start="${part_info%% *}"
    part_size="${part_info##* }"
    tmp_partition="$(mktemp "${BUILD_DIR}/rootfs-part.XXXXXX")"
    rm -f "${tmp_partition}"

    # Extract the partition
    dd if="${image_path}" of="${tmp_partition}" bs=512 skip="${part_start}" count="${part_size}" >/dev/null 2>&1 || {
        warn "Failed to extract partition from disk image: ${image_path}"
        rm -f "${tmp_partition}"
        return 1
    }

    # Inject via debugfs
    _rootfs_inject_tree_via_debugfs "${tmp_partition}" "${source_dir}" || {
        warn "debugfs injection failed for extracted partition from ${image_path}"
        rm -f "${tmp_partition}"
        return 1
    }

    # Write the modified partition back
    info "Writing modified partition back to ${image_path}"
    chmod u+w "${image_path}" 2>/dev/null || sudo chmod a+w "${image_path}" 2>/dev/null || true
    dd if="${tmp_partition}" of="${image_path}" bs=512 seek="${part_start}" count="${part_size}" conv=notrunc >/dev/null || {
        warn "Failed to write partition back to disk image: ${image_path}"
        rm -f "${tmp_partition}"
        return 1
    }

    rm -f "${tmp_partition}"
    return 0
}

rootfs_inject_guest_stage() {
    local rootfs_target="$1"
    local source_dir="$2"
    local fs_type=""

    [[ -d "${source_dir}" ]] || {
        warn "Guest source directory not found, skipping rootfs injection: ${source_dir}"
        return 0
    }

    if [[ -z "${rootfs_target}" ]]; then
        warn "No rootfs target found, skipping /guest injection"
        return 0
    fi

    if [[ -d "${rootfs_target}" ]]; then
        info "Injecting guest payload into rootfs directory: ${rootfs_target}"
        mkdir -p "${rootfs_target}/guest"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "${source_dir}/" "${rootfs_target}/guest/"
        else
            cp -a "${source_dir}/." "${rootfs_target}/guest/"
        fi
        return 0
    fi

    if [[ ! -f "${rootfs_target}" ]]; then
        warn "Rootfs target does not exist, skipping /guest injection: ${rootfs_target}"
        return 0
    fi

    fs_type="$(_rootfs_detect_fs_type "${rootfs_target}")"
    if [[ "${fs_type}" =~ ^ext[234]$ ]]; then
        info "Injecting guest payload into ext filesystem image: ${rootfs_target}"
        local stage_dir
        stage_dir="$(mktemp -d "${BUILD_DIR}/rootfs-inject.XXXXXX")"
        rootfs_stage_guest_tree "${stage_dir}" "${source_dir}"
        _rootfs_inject_tree_via_debugfs "${rootfs_target}" "${stage_dir}" || {
            rm -rf "${stage_dir}"
            die "Failed to inject guest payload into ext filesystem image: ${rootfs_target}"
        }
        rm -rf "${stage_dir}"
        return 0
    fi

    info "Attempting to inject guest payload into disk image: ${rootfs_target}"
    local stage_dir
    stage_dir="$(mktemp -d "${BUILD_DIR}/rootfs-inject.XXXXXX")"
    rootfs_stage_guest_tree "${stage_dir}" "${source_dir}"
    _rootfs_inject_tree_via_partition_extract "${rootfs_target}" "${stage_dir}" \
        || _rootfs_inject_tree_via_loop_mount "${rootfs_target}" "${stage_dir}" || {
        rm -rf "${stage_dir}"
        die "Failed to inject guest payload into disk image: ${rootfs_target}"
    }
    rm -rf "${stage_dir}"
}
