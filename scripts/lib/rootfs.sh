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
    local tmp_path="${target_path}.tmp.$$"

    [[ -f "${source_path}" ]] || return 1
    [[ -n "${target_path}" ]] || die "rootfs target is empty"
    mkdir -p "$(dirname "${target_path}")"
    rm -f "${tmp_path}"
    cp -f "${source_path}" "${tmp_path}"
    mv -f "${tmp_path}" "${target_path}"
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

_rootfs_inject_tree_via_cpio_gz() {
    local image_path="$1"
    local source_dir="$2"
    local tmp_dir
    local tmp_image="${image_path}.tmp.$$"
    local abs_source

    command -v cpio >/dev/null 2>&1 || return 1
    command -v gzip >/dev/null 2>&1 || return 1
    command -v fakeroot >/dev/null 2>&1 || return 1

    abs_source="$(cd "${source_dir}" && pwd -P)"
    tmp_dir="$(mktemp -d "${BUILD_DIR}/rootfs-cpio.XXXXXX")"
    rm -f "${tmp_image}"

    fakeroot bash -c '
        set -euo pipefail
        work_dir="$1"
        image_path="$2"
        source_dir="$3"
        tmp_image="$4"

        cd "${work_dir}"
        gzip -dc "${image_path}" | cpio -idmu --no-absolute-filenames >/dev/null 2>&1
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "${source_dir}/" .
        else
            cp -a "${source_dir}/." .
        fi
        find . -print0 | sort -z | cpio --null -H newc -o 2>/dev/null | gzip -9 > "${tmp_image}"
    ' _ "${tmp_dir}" "${image_path}" "${abs_source}" "${tmp_image}" || {
        rm -rf "${tmp_dir}" "${tmp_image}"
        return 1
    }

    mv -f "${tmp_image}" "${image_path}"
    rm -rf "${tmp_dir}"
    return 0
}

_rootfs_debugfs_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

_rootfs_debugfs_stat() {
    local image=$1 path=$2 quoted output
    quoted=$(_rootfs_debugfs_quote "$path") || return 1
    output=$(LC_ALL=C debugfs -R "stat ${quoted}" "$image" 2>&1) || return 1
    [[ "$output" != *'File not found'* && "$output" == *'Inode:'* ]] || return 1
    printf '%s\n' "$output"
}

_rootfs_payload_has_unpreserved_metadata() {
    local path=$1 output
    output=$(getfattr -h -d -m- -- "$path" 2>/dev/null) || return 2
    [[ "$output" != *'='* ]] || return 0
    if [[ ! -L "$path" ]]; then
        output=$(getfacl -cp -- "$path" 2>/dev/null) || return 2
        if grep -Eq '^(default:|user:.+:|group:.+:|mask:)' <<<"$output"; then
            return 0
        fi
    fi
    return 1
}

# Contract: this mutates IMAGE directly. Atomic callers must pass an image they
# own (rootfs-compose does so via an adjacent temporary copy).
_rootfs_inject_tree_via_debugfs() (
    local image_path=$1 source_dir=$2 image_dir snapshot inventory_raw inventory
    local path rel target type mode uid gid atime mtime size sha link_target key first
    local quoted_source quoted_target quoted_first stat_output actual actual_mode actual_uid actual_gid
    local actual_size actual_atime actual_mtime actual_links verify_dir verify_file verify_sha full_mode type_bits index=0
    local -a paths=()
    local -a source_paths=()
    local -a scan_dirs=()
    local -A hardlink_first=()
    local -A captured_mode=() captured_uid=() captured_gid=() captured_atime=() captured_mtime=()
    local -A captured_identity=()
    local timestamp_text fraction atime_raw mtime_raw scan_dir scan_path scan_index=0 snapshot_path

    for tool in awk basename cat chmod cp debugfs dirname find getfacl getfattr grep head mkdir mktemp readlink rm sed sha256sum sort stat touch; do
        command -v "$tool" >/dev/null 2>&1 || {
            warn "${tool} not found, cannot safely inject ext filesystem image: ${image_path}"
            return 1
        }
    done
    [[ -f "$image_path" && -d "$source_dir" ]] || return 1
    image_dir=$(dirname -- "$image_path")
    snapshot=
    inventory_raw=
    inventory=
    verify_dir=
    trap 'if [[ -n ${snapshot:-} ]]; then chmod -R u+w -- "$snapshot" 2>/dev/null || true; rm -rf -- "$snapshot"; fi; [[ -z ${verify_dir:-} ]] || rm -rf -- "$verify_dir"; [[ -z ${inventory_raw:-} ]] || rm -f -- "$inventory_raw"; [[ -z ${inventory:-} ]] || rm -f -- "$inventory"' EXIT
    trap 'exit 130' INT TERM
    snapshot=$(mktemp -d "${image_dir}/.rootfs-payload.XXXXXX") || return 1
    inventory_raw=$(mktemp "${image_dir}/.rootfs-inventory.raw.XXXXXX") || return 1
    inventory=$(mktemp "${image_dir}/.rootfs-inventory.sorted.XXXXXX") || return 1
    verify_dir=$(mktemp -d "${image_dir}/.rootfs-verify.XXXXXX") || return 1

    # Capture metadata and reject unsupported entries before any content read.
    : >"$inventory_raw"
    scan_dirs=("$source_dir")
    while ((scan_index < ${#scan_dirs[@]})); do
        scan_dir=${scan_dirs[$scan_index]}
        scan_index=$((scan_index + 1))
        LC_ALL=C find "$scan_dir" -mindepth 1 -maxdepth 1 \
            -printf '%A@\034%T@\034%m\034%U\034%G\034%p\0' >"$inventory" || return 1
        cat "$inventory" >>"$inventory_raw" || return 1
        while IFS=$'\034' read -r -d '' _ _ _ _ _ scan_path; do
            [[ -d "$scan_path" && ! -L "$scan_path" ]] && scan_dirs+=("$scan_path")
        done <"$inventory"
    done
    while IFS=$'\034' read -r -d '' atime_raw mtime_raw mode uid gid path; do
        source_paths+=("$path")
        rel=${path#"$source_dir/"}
        [[ "$rel" != *[$'\001'-$'\037'$'\177']* && "$rel" != *['"'\\]* ]] || return 1
        captured_mode[$rel]=$mode
        captured_uid[$rel]=$uid
        captured_gid[$rel]=$gid
        captured_atime[$rel]=${atime_raw%%.*}
        captured_mtime[$rel]=${mtime_raw%%.*}
        captured_identity[$rel]=$(stat -c '%d:%i:%s:%f:%z' -- "$path") || return 1
        # Traversing a directory to inventory its children can itself update
        # directory atime under relatime. Directory mtime and all file/symlink
        # timestamps remain immutable and are checked exactly.
        if [[ ! -L "$path" && -d "$path" ]]; then
            timestamp_text=$mtime_raw
        else
            timestamp_text="$atime_raw $mtime_raw"
        fi
        for timestamp_text in $timestamp_text; do
            [[ "$timestamp_text" =~ \.([0-9]{9}) ]] || return 1
            fraction=${BASH_REMATCH[1]}
            [[ "$fraction" == 000000000 ]] || {
                warn "Fractional payload timestamps are not supported: ${rel}"
                return 1
            }
        done
        if [[ -L "$path" ]]; then
            link_target=$(readlink -- "$path") || return 1
            [[ "$link_target" != *[$'\001'-$'\037'$'\177']* && "$link_target" != *['"'\\]* ]] || return 1
        elif [[ ! -f "$path" && ! -d "$path" ]]; then
            return 1
        fi
        if _rootfs_payload_has_unpreserved_metadata "$path"; then return 1; else [[ $? -eq 1 ]] || return 1; fi
    done <"$inventory_raw"

    cp -a --reflink=auto -- "$source_dir/." "$snapshot/" || return 1
    # Never write caller-owned payload paths. Verify identity after the copy,
    # then apply the pre-read manifest only to the private snapshot.
    for path in "${source_paths[@]}"; do
        rel=${path#"$source_dir/"}
        [[ "$(stat -c '%d:%i:%s:%f:%z' -- "$path")" == "${captured_identity[$rel]}" ]] || return 1
        snapshot_path="$snapshot/$rel"
        if [[ -L "$snapshot_path" ]]; then
            touch -h -a -d "@${captured_atime[$rel]}" -- "$snapshot_path" || return 1
            touch -h -m -d "@${captured_mtime[$rel]}" -- "$snapshot_path" || return 1
        else
            touch -a -d "@${captured_atime[$rel]}" -- "$snapshot_path" || return 1
            touch -m -d "@${captured_mtime[$rel]}" -- "$snapshot_path" || return 1
        fi
    done
    find "$snapshot" -mindepth 1 -print0 >"$inventory_raw" || return 1
    sort -z "$inventory_raw" >"$inventory" || return 1
    while IFS= read -r -d '' path; do
        paths+=("$path")
    done <"$inventory"

    # Validate the complete immutable snapshot before the first image write.
    for path in "${paths[@]}"; do
        rel=${path#"$snapshot/"}
        [[ "$rel" != *[$'\001'-$'\037'$'\177']* ]] || {
            warn "Unsupported control character in payload path"
            return 1
        }
        [[ "$rel" != *['"'\\]* ]] || {
            warn "Payload path cannot be represented losslessly by debugfs: ${rel}"
            return 1
        }
        if [[ -L "$path" ]]; then
            link_target=$(readlink -- "$path") || return 1
            [[ "$link_target" != *[$'\001'-$'\037'$'\177']* ]] || {
                warn "Unsupported control character in symlink target: ${rel}"
                return 1
            }
            [[ "$link_target" != *['"'\\]* ]] || {
                warn "Symlink target cannot be represented losslessly by debugfs: ${rel}"
                return 1
            }
        elif [[ ! -f "$path" && ! -d "$path" ]]; then
            warn "Unsupported special payload object: ${rel}"
            return 1
        fi
        if _rootfs_payload_has_unpreserved_metadata "$path"; then
            warn "Payload xattrs or extended ACLs are not supported: ${rel}"
            return 1
        else
            [[ $? -eq 1 ]] || return 1
        fi
    done

    # Create directory topology first. Existing directories are overlay roots.
    for path in "${paths[@]}"; do
        [[ -d "$path" && ! -L "$path" ]] || continue
        rel=${path#"$snapshot/"}; target="/${rel}"
        if ! _rootfs_debugfs_stat "$image_path" "$target" >/dev/null; then
            quoted_target=$(_rootfs_debugfs_quote "$target") || return 1
            LC_ALL=C debugfs -w -R "mkdir ${quoted_target}" "$image_path" >/dev/null 2>&1 || return 1
        fi
    done

    # Write data and construct hardlinks. Final verification, not debugfs's
    # process status, decides whether each semantic operation succeeded.
    for path in "${paths[@]}"; do
        rel=${path#"$snapshot/"}; target="/${rel}"
        if [[ -L "$path" ]]; then
            link_target=$(readlink -- "$path") || return 1
            quoted_target=$(_rootfs_debugfs_quote "$target") || return 1
            if _rootfs_debugfs_stat "$image_path" "$target" >/dev/null; then
                LC_ALL=C debugfs -w -R "rm ${quoted_target}" "$image_path" >/dev/null 2>&1 || return 1
            fi
            LC_ALL=C debugfs -w -R "symlink ${quoted_target} $(_rootfs_debugfs_quote "$link_target")" \
                "$image_path" >/dev/null 2>&1 || return 1
        elif [[ -f "$path" ]]; then
            key=$(stat -c '%d:%i' -- "$path") || return 1
            quoted_target=$(_rootfs_debugfs_quote "$target") || return 1
            if _rootfs_debugfs_stat "$image_path" "$target" >/dev/null; then
                LC_ALL=C debugfs -w -R "rm ${quoted_target}" "$image_path" >/dev/null 2>&1 || return 1
            fi
            first=${hardlink_first[$key]-}
            if [[ -n "$first" ]]; then
                quoted_first=$(_rootfs_debugfs_quote "$first") || return 1
                LC_ALL=C debugfs -w -R "ln ${quoted_first} ${quoted_target}" "$image_path" >/dev/null 2>&1 || return 1
            else
                quoted_source=$(_rootfs_debugfs_quote "$path") || return 1
                LC_ALL=C debugfs -w -R "write ${quoted_source} ${quoted_target}" "$image_path" >/dev/null 2>&1 || return 1
                hardlink_first[$key]=$target
            fi
        fi
    done

    # Apply inode metadata only after all children and links have been created.
    for path in "${paths[@]}"; do
        rel=${path#"$snapshot/"}; target="/${rel}"
        mode=${captured_mode[$rel]}
        uid=${captured_uid[$rel]}
        gid=${captured_gid[$rel]}
        atime=${captured_atime[$rel]}
        mtime=${captured_mtime[$rel]}
        ((atime >= 0 && atime <= 4294967295 && mtime >= 0 && mtime <= 4294967295)) || return 1
        if [[ -L "$path" ]]; then type_bits=$((8#120000));
        elif [[ -d "$path" ]]; then type_bits=$((8#040000));
        else type_bits=$((8#100000)); fi
        full_mode=$((type_bits + 8#$mode))
        printf -v full_mode '0%o' "$full_mode"
        quoted_target=$(_rootfs_debugfs_quote "$target") || return 1
        LC_ALL=C debugfs -w -R "set_inode_field ${quoted_target} mode ${full_mode}" "$image_path" >/dev/null 2>&1 || return 1
        LC_ALL=C debugfs -w -R "set_inode_field ${quoted_target} uid ${uid}" "$image_path" >/dev/null 2>&1 || return 1
        LC_ALL=C debugfs -w -R "set_inode_field ${quoted_target} gid ${gid}" "$image_path" >/dev/null 2>&1 || return 1
        LC_ALL=C debugfs -w -R "set_inode_field ${quoted_target} atime @${atime}" "$image_path" >/dev/null 2>&1 || return 1
        LC_ALL=C debugfs -w -R "set_inode_field ${quoted_target} mtime @${mtime}" "$image_path" >/dev/null 2>&1 || return 1
        if [[ -f "$path" && ! -L "$path" ]]; then
            LC_ALL=C debugfs -w -R "set_inode_field ${quoted_target} links_count $(stat -c %h -- "$path")" \
                "$image_path" >/dev/null 2>&1 || return 1
        fi
    done

    # Verify a complete post-write manifest. This catches debugfs commands that
    # return zero while reporting semantic errors.
    for path in "${paths[@]}"; do
        index=$((index + 1)); rel=${path#"$snapshot/"}; target="/${rel}"
        stat_output=$(_rootfs_debugfs_stat "$image_path" "$target") || return 1
        actual_mode=$(sed -n 's/.*Mode:[[:space:]]*\([0-7][0-7]*\).*/\1/p' <<<"$stat_output" | head -n1)
        read -r actual_uid actual_gid < <(awk '/^User:/ {print $2, $4; exit}' <<<"$stat_output")
        actual_atime=$(sed -n 's/.*atime: 0x\([0-9a-fA-F]*\):.*/\1/p' <<<"$stat_output" | head -n1)
        actual_mtime=$(sed -n 's/.*mtime: 0x\([0-9a-fA-F]*\):.*/\1/p' <<<"$stat_output" | head -n1)
        actual_links=$(awk '/^Links:/ {print $2; exit}' <<<"$stat_output")
        mode=${captured_mode[$rel]}; uid=${captured_uid[$rel]}; gid=${captured_gid[$rel]}
        atime=${captured_atime[$rel]}; printf -v atime '%08x' "$atime"
        mtime=${captured_mtime[$rel]}; printf -v mtime '%08x' "$mtime"
        [[ "$actual_mode" == "0${mode}" || "$actual_mode" == "$mode" ]] || return 1
        [[ "$actual_uid" == "$uid" && "$actual_gid" == "$gid" ]] || return 1
        [[ "${actual_atime,,}" == "${atime,,}" && "${actual_mtime,,}" == "${mtime,,}" ]] || return 1
        if [[ -L "$path" ]]; then
            [[ "$stat_output" == *'Type: symlink'* ]] || return 1
            mkdir "$verify_dir/$index" || return 1
            LC_ALL=C debugfs -R "rdump $(_rootfs_debugfs_quote "$target") $(_rootfs_debugfs_quote "$verify_dir/$index")" \
                "$image_path" >/dev/null 2>&1 || return 1
            actual=$(readlink -- "$verify_dir/$index/$(basename -- "$path")") || return 1
            [[ "$actual" == "$(readlink -- "$path")" ]] || return 1
        elif [[ -f "$path" ]]; then
            [[ "$stat_output" == *'Type: regular'* && "$actual_links" == "$(stat -c %h -- "$path")" ]] || return 1
            size=$(stat -c %s -- "$path"); sha=$(sha256sum -- "$path" | awk '{print $1}')
            actual_size=$(awk '/ Project: / {print $NF; exit}' <<<"$stat_output")
            verify_file="$verify_dir/file.$index"
            LC_ALL=C debugfs -R "dump $(_rootfs_debugfs_quote "$target") $(_rootfs_debugfs_quote "$verify_file")" \
                "$image_path" >/dev/null 2>&1 || return 1
            [[ -f "$verify_file" && "$(stat -c %s -- "$verify_file")" == "$size" ]] || return 1
            verify_sha=$(sha256sum -- "$verify_file" | awk '{print $1}')
            [[ "$verify_sha" == "$sha" ]] || return 1
            key=$(stat -c '%d:%i' -- "$path"); first=${hardlink_first[$key]}
            if [[ "$first" != "$target" ]]; then
                actual=$(_rootfs_debugfs_stat "$image_path" "$first" | awk '/^Inode:/ {print $2; exit}')
                [[ "$actual" == "$(awk '/^Inode:/ {print $2; exit}' <<<"$stat_output")" ]] || return 1
            fi
        elif [[ -d "$path" ]]; then
            [[ "$stat_output" == *'Type: directory'* ]] || return 1
        fi
    done
)

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

    if [[ "${rootfs_target}" == *.cpio.gz ]]; then
        info "Injecting guest payload into cpio.gz initramfs: ${rootfs_target}"
        local stage_dir
        stage_dir="$(mktemp -d "${BUILD_DIR}/rootfs-inject.XXXXXX")"
        rootfs_stage_guest_tree "${stage_dir}" "${source_dir}"
        _rootfs_inject_tree_via_cpio_gz "${rootfs_target}" "${stage_dir}" || {
            rm -rf "${stage_dir}"
            die "Failed to inject guest payload into cpio.gz initramfs: ${rootfs_target}"
        }
        rm -rf "${stage_dir}"
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

rootfs_inject_overlay_stage() {
    local rootfs_target="$1"
    local source_dir="$2"
    local fs_type=""

    [[ -d "${source_dir}" ]] || {
        warn "Overlay source directory not found, skipping rootfs injection: ${source_dir}"
        return 0
    }

    if [[ -z "${rootfs_target}" ]]; then
        warn "No rootfs target found, skipping overlay injection"
        return 0
    fi

    if [[ -d "${rootfs_target}" ]]; then
        info "Injecting overlay into rootfs directory: ${rootfs_target}"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "${source_dir}/" "${rootfs_target}/"
        else
            cp -a "${source_dir}/." "${rootfs_target}/"
        fi
        return 0
    fi

    if [[ ! -f "${rootfs_target}" ]]; then
        warn "Rootfs target does not exist, skipping overlay injection: ${rootfs_target}"
        return 0
    fi

    if [[ "${rootfs_target}" == *.cpio.gz ]]; then
        info "Injecting overlay into cpio.gz initramfs: ${rootfs_target}"
        _rootfs_inject_tree_via_cpio_gz "${rootfs_target}" "${source_dir}" || \
            die "Failed to inject overlay into cpio.gz initramfs: ${rootfs_target}"
        return 0
    fi

    fs_type="$(_rootfs_detect_fs_type "${rootfs_target}")"
    if [[ "${fs_type}" =~ ^ext[234]$ ]]; then
        info "Injecting overlay into ext filesystem image: ${rootfs_target}"
        _rootfs_inject_tree_via_debugfs "${rootfs_target}" "${source_dir}" || \
            die "Failed to inject overlay into ext filesystem image: ${rootfs_target}"
        return 0
    fi

    info "Attempting to inject overlay into disk image: ${rootfs_target}"
    _rootfs_inject_tree_via_partition_extract "${rootfs_target}" "${source_dir}" \
        || _rootfs_inject_tree_via_loop_mount "${rootfs_target}" "${source_dir}" || \
            die "Failed to inject overlay into disk image: ${rootfs_target}"
}
