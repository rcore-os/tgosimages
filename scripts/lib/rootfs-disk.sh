#!/usr/bin/env bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    printf 'This is a library, should be sourced, not executed.\n' >&2
    exit 1
fi

_rootfs_disk_lib_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if ! declare -F _rootfs_detect_fs_type >/dev/null; then
    # shellcheck source=rootfs.sh
    source "${_rootfs_disk_lib_dir}/rootfs.sh"
fi
if ! declare -F _rootfs_resize_for_capacity_in_place >/dev/null; then
    # shellcheck source=rootfs-compose.sh
    source "${_rootfs_disk_lib_dir}/rootfs-compose.sh"
fi
unset _rootfs_disk_lib_dir

_rootfs_disk_error() {
    printf 'rootfs-disk: %s\n' "$*" >&2
    return 1
}

_rootfs_disk_require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || {
            _rootfs_disk_error "required tool not found: ${tool}"
            return 1
        }
    done
}

_rootfs_disk_uint() {
    local value=${1-} max=9223372036854775807
    [[ $value =~ ^[0-9]+$ ]] || return 1
    value=${value#"${value%%[!0]*}"}
    [[ -n $value ]] || value=0
    ((${#value} < ${#max})) || {
        ((${#value} == ${#max})) && [[ $value < "$max" || $value == "$max" ]]
    } || return 1
    printf '%s\n' "$value"
}

_rootfs_disk_type_is_linux() {
    local label=${1,,} type=${2,,}
    case $label in
    gpt)
        case $type in
        0fc63daf-8483-4772-8e79-3d69d8477de4 | \
        44479540-f297-41b2-9af7-d131d5f0458a | \
        4f68bce3-e8cd-4db1-96e7-fbcaf984b709 | \
        b921b045-1df0-41c3-af44-4c6f280d3fae | \
        69dad710-2ce4-4e3c-b16c-21a1d49abed3)
            return 0
            ;;
        esac
        ;;
    dos)
        [[ $type == 83 || $type == 0x83 ]]
        return
        ;;
    esac
    return 1
}

_rootfs_disk_partition_rows() {
    local disk=$1
    sfdisk -J -- "$disk" 2>/dev/null | python3 -c '
import json
import sys

data = json.load(sys.stdin).get("partitiontable", {})
label = data.get("label", "")
if label not in ("gpt", "dos"):
    raise SystemExit(2)
device = data.get("device", "")
if not device:
    raise SystemExit(2)
seen = set()
for part in data.get("partitions", []):
    node = part.get("node", "")
    if not node.startswith(device):
        raise SystemExit(2)
    suffix = node[len(device):]
    if device[-1:].isdigit() and suffix.startswith("p"):
        suffix = suffix[1:]
    if not suffix.isdigit() or int(suffix) < 1 or int(suffix) in seen:
        raise SystemExit(2)
    number = int(suffix)
    seen.add(number)
    print(number, part.get("start", ""), part.get("size", ""),
          part.get("type", ""), label, sep="\t")
'
}

_rootfs_disk_restore_tree_atimes() (
    local source=$1 snapshot=$2 inventory path rel reference
    inventory=$(mktemp "${TMPDIR:-/tmp}/rootfs-disk-atimes.XXXXXX") || return 1
    trap 'rm -f -- "$inventory"' EXIT
    find -P "$source" -depth -print0 >"$inventory" || return 1
    while IFS= read -r -d '' path; do
        if [[ $path == "$source" ]]; then
            reference=$snapshot
        else
            rel=${path#"$source/"}
            reference="$snapshot/$rel"
        fi
        [[ -e $reference || -L $reference ]] || return 1
        if [[ -L $path ]]; then
            touch -h -a -r "$reference" "$path" || return 1
        else
            touch -a -r "$reference" "$path" || return 1
        fi
    done <"$inventory"
)

_rootfs_disk_normalize_absolute_path() {
    local path=$1 component result= item
    local -a components=() stack=()
    [[ $path == /* && $path != *[$'\001'-$'\037'$'\177']* && $path != *['"'\\]* ]] || return 1
    IFS=/ read -r -a components <<<"$path"
    for component in "${components[@]}"; do
        case $component in
        ''|.) ;;
        ..)
            ((${#stack[@]} > 0)) || return 1
            unset 'stack[${#stack[@]}-1]'
            ;;
        *) stack+=("$component") ;;
        esac
    done
    result=/
    for item in "${stack[@]}"; do
        [[ $result == / ]] || result+=/
        result+=$item
    done
    printf '%s\n' "$result"
}

rootfs_ext4_resolve_file() (
    local image=$1 requested=$2 current stat_output type target parent next hops=0
    local -A seen=()
    [[ -f $image ]] || return 1
    [[ $(_rootfs_detect_fs_type "$image") == ext4 ]] || return 1
    current=$(_rootfs_disk_normalize_absolute_path "$requested") || return 1
    while ((hops++ < 40)); do
        [[ -z ${seen[$current]+set} ]] || return 1
        seen[$current]=1
        stat_output=$(_rootfs_debugfs_stat "$image" "$current") || return 1
        type=$(awk '{for (i = 1; i <= NF; i++) if ($i == "Type:") {print $(i + 1); exit}}' \
            <<<"$stat_output")
        case $type in
        regular)
            printf '%s\n' "$current"
            return 0
            ;;
        symlink)
            target=$(sed -n 's/^Fast link dest: "\(.*\)"$/\1/p' <<<"$stat_output")
            [[ -n $target ]] || return 1
            if [[ $target == /* ]]; then
                next=$target
            else
                parent=${current%/*}
                [[ -n $parent ]] || parent=/
                next="${parent}/${target}"
            fi
            current=$(_rootfs_disk_normalize_absolute_path "$next") || return 1
            ;;
        *) return 1 ;;
        esac
    done
    return 1
)

rootfs_disk_find_root_partition() (
    local disk=$1 disk_bytes disk_sectors rows row
    local partno start size type label end fs_type candidate
    local best_partno= best_start= best_size= best_label= tie=0

    _rootfs_disk_require_tools blkid dd mktemp python3 rm sfdisk stat || return 1
    [[ -f $disk ]] || { _rootfs_disk_error "disk image not found: $disk"; return 1; }
    disk_bytes=$(_rootfs_disk_uint "$(stat -c %s -- "$disk")") || return 1
    disk_sectors=$((disk_bytes / 512))
    rows=$(_rootfs_disk_partition_rows "$disk") || {
        _rootfs_disk_error "cannot read a supported partition table: $disk"
        return 1
    }
    [[ -n $rows ]] || { _rootfs_disk_error "partition table is empty: $disk"; return 1; }

    while IFS=$'\t' read -r partno start size type label; do
        partno=$(_rootfs_disk_uint "$partno") || return 1
        start=$(_rootfs_disk_uint "$start") || return 1
        size=$(_rootfs_disk_uint "$size") || return 1
        ((size > 0 && start <= 9223372036854775807 - size)) || {
            _rootfs_disk_error "invalid partition bounds: partition $partno"
            return 1
        }
        end=$((start + size))
        ((end <= disk_sectors)) || {
            _rootfs_disk_error "partition $partno exceeds disk image bounds"
            return 1
        }
        _rootfs_disk_type_is_linux "$label" "$type" || continue
        candidate=$(mktemp "${TMPDIR:-/tmp}/rootfs-disk-probe.XXXXXX") || return 1
        if ! dd if="$disk" of="$candidate" bs=512 skip="$start" count="$size" status=none; then
            rm -f -- "$candidate"
            return 1
        fi
        fs_type=$(_rootfs_detect_fs_type "$candidate")
        rm -f -- "$candidate"
        [[ $fs_type == ext4 ]] || continue
        if [[ -z $best_size ]] || ((size > best_size)); then
            best_partno=$partno
            best_start=$start
            best_size=$size
            best_label=$label
            tie=0
        elif ((size == best_size)); then
            tie=1
        fi
    done <<<"$rows"

    [[ -n $best_partno ]] || { _rootfs_disk_error "no Linux ext4 partition found: $disk"; return 1; }
    ((tie == 0)) || { _rootfs_disk_error "ambiguous largest Linux ext4 partition: $disk"; return 1; }
    printf '%s %s %s %s\n' "$best_partno" "$best_start" "$best_size" "$best_label"
)

rootfs_disk_extract_partition() (
    local disk=$1 start_value=$2 size_value=$3 output=$4
    local disk_bytes disk_sectors start size end directory base temporary=

    _rootfs_disk_require_tools dd dirname mktemp mv rm stat || return 1
    [[ -f $disk ]] || { _rootfs_disk_error "disk image not found: $disk"; return 1; }
    [[ ! -e $output && ! -L $output ]] || {
        _rootfs_disk_error "partition output already exists: $output"
        return 1
    }
    start=$(_rootfs_disk_uint "$start_value") || return 1
    size=$(_rootfs_disk_uint "$size_value") || return 1
    ((size > 0 && start <= 9223372036854775807 - size)) || return 1
    end=$((start + size))
    disk_bytes=$(_rootfs_disk_uint "$(stat -c %s -- "$disk")") || return 1
    disk_sectors=$((disk_bytes / 512))
    ((end <= disk_sectors)) || {
        _rootfs_disk_error "requested partition exceeds disk image bounds"
        return 1
    }
    directory=$(dirname -- "$output")
    base=$(basename -- "$output")
    [[ -d $directory ]] || return 1
    trap '[[ -z ${temporary:-} ]] || rm -f -- "$temporary"' EXIT
    trap 'exit 130' INT TERM
    temporary=$(mktemp "${directory}/.${base}.extract.XXXXXX") || return 1
    dd if="$disk" of="$temporary" bs=512 skip="$start" count="$size" status=none || return 1
    mv -T -- "$temporary" "$output" || return 1
    temporary=
    trap - EXIT INT TERM
)

_rootfs_disk_partition_by_number() {
    local disk=$1 requested=$2 row partno
    while IFS= read -r row; do
        IFS=$'\t' read -r partno _ <<<"$row"
        if [[ $partno == "$requested" ]]; then
            printf '%s\n' "$row"
            return 0
        fi
    done < <(_rootfs_disk_partition_rows "$disk")
    return 1
}

_rootfs_disk_partition_is_last() {
    local disk=$1 requested=$2 requested_start=$3 requested_size=$4
    local row partno start size _ end max_end=0
    while IFS= read -r row; do
        IFS=$'\t' read -r partno start size _ <<<"$row"
        start=$(_rootfs_disk_uint "$start") || return 1
        size=$(_rootfs_disk_uint "$size") || return 1
        ((start <= 9223372036854775807 - size)) || return 1
        end=$((start + size))
        ((end > max_end)) && max_end=$end
    done < <(_rootfs_disk_partition_rows "$disk")
    ((requested_start + requested_size == max_end))
}

rootfs_disk_replace_partition() (
    local disk=$1 partno_value=$2 start_value=$3 old_size_value=$4 payload=$5
    local partno start old_size payload_bytes payload_sectors new_size label
    local row actual_partno actual_start actual_size type actual_label required_end
    local disk_sectors new_disk_sectors alignment=2048 gpt_reserve=33
    local directory base temporary= verify_image= lock_fd updated_row

    _rootfs_disk_require_tools cp dd e2fsck flock mktemp mv python3 resize2fs \
        rm sfdisk stat touch truncate || return 1
    [[ -f $disk && ! -L $disk ]] || { _rootfs_disk_error "disk image not found: $disk"; return 1; }
    [[ -f $payload && ! -L $payload ]] || {
        _rootfs_disk_error "replacement ext4 image not found: $payload"
        return 1
    }
    partno=$(_rootfs_disk_uint "$partno_value") || return 1
    start=$(_rootfs_disk_uint "$start_value") || return 1
    old_size=$(_rootfs_disk_uint "$old_size_value") || return 1
    ((partno > 0 && old_size > 0)) || return 1
    row=$(_rootfs_disk_partition_by_number "$disk" "$partno") || {
        _rootfs_disk_error "partition not found: $partno"
        return 1
    }
    IFS=$'\t' read -r actual_partno actual_start actual_size type actual_label <<<"$row"
    [[ $actual_partno == "$partno" && $actual_start == "$start" && $actual_size == "$old_size" ]] || {
        _rootfs_disk_error "partition metadata changed for partition $partno"
        return 1
    }
    _rootfs_disk_type_is_linux "$actual_label" "$type" || {
        _rootfs_disk_error "partition $partno is not a supported Linux partition type"
        return 1
    }
    [[ $(_rootfs_detect_fs_type "$payload") == ext4 ]] || {
        _rootfs_disk_error "replacement is not ext4: $payload"
        return 1
    }
    _rootfs_run_tool 0 e2fsck -fn "$payload" >/dev/null || return 1

    payload_bytes=$(_rootfs_disk_uint "$(stat -c %s -- "$payload")") || return 1
    ((payload_bytes > 0 && payload_bytes <= 9223372036854775295)) || return 1
    payload_sectors=$(((payload_bytes + 511) / 512))
    new_size=$old_size
    if ((payload_sectors > old_size)); then
        _rootfs_disk_partition_is_last "$disk" "$partno" "$start" "$old_size" || {
            _rootfs_disk_error "partition $partno is not last and cannot grow"
            return 1
        }
        new_size=$payload_sectors
    fi
    ((start <= 9223372036854775807 - new_size)) || return 1
    required_end=$((start + new_size))
    disk_sectors=$(($(stat -c %s -- "$disk") / 512))

    directory=$(dirname -- "$disk")
    base=$(basename -- "$disk")
    exec {lock_fd}>"${disk}.lock" || return 1
    flock -x "$lock_fd" || return 1
    trap '
        status=$?
        [[ -z ${verify_image:-} ]] || rm -f -- "$verify_image"
        [[ -z ${temporary:-} ]] || rm -f -- "$temporary"
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&-
        exit "$status"
    ' EXIT
    trap 'exit 130' INT TERM
    temporary=$(mktemp "${directory}/.${base}.replace.XXXXXX") || return 1
    cp --preserve=all --reflink=auto --sparse=always -- "$disk" "$temporary" || return 1

    if ((new_size > old_size)); then
        if [[ $actual_label == gpt ]]; then
            ((required_end <= 9223372036854775807 - gpt_reserve)) || return 1
            new_disk_sectors=$((required_end + gpt_reserve))
        else
            new_disk_sectors=$required_end
        fi
        new_disk_sectors=$((((new_disk_sectors + alignment - 1) / alignment) * alignment))
        if ((new_disk_sectors > disk_sectors)); then
            ((new_disk_sectors <= 9223372036854775807 / 512)) || return 1
            truncate -s "$((new_disk_sectors * 512))" -- "$temporary" || return 1
        fi
        if [[ $actual_label == gpt ]]; then
            sfdisk --relocate gpt-bak-std "$temporary" >/dev/null 2>&1 || return 1
        fi
        printf 'start=%s, size=%s\n' "$start" "$new_size" |
            sfdisk --no-reread --no-tell-kernel -N "$partno" "$temporary" >/dev/null 2>&1 || return 1
    fi

    sfdisk --verify "$temporary" >/dev/null 2>&1 || return 1
    updated_row=$(_rootfs_disk_partition_by_number "$temporary" "$partno") || return 1
    IFS=$'\t' read -r actual_partno actual_start actual_size type label <<<"$updated_row"
    [[ $actual_partno == "$partno" && $actual_start == "$start" && $actual_size == "$new_size" &&
       $label == "$actual_label" ]] || return 1
    dd if="$payload" of="$temporary" bs=512 seek="$start" conv=notrunc,fsync status=none || return 1

    verify_image=$(mktemp "${directory}/.${base}.verify.XXXXXX") || return 1
    dd if="$temporary" of="$verify_image" bs=512 skip="$start" count="$payload_sectors" status=none || return 1
    truncate -s "$payload_bytes" -- "$verify_image" || return 1
    [[ $(_rootfs_detect_fs_type "$verify_image") == ext4 ]] || return 1
    _rootfs_run_tool 0 e2fsck -fn "$verify_image" >/dev/null || return 1
    rm -f -- "$verify_image"
    verify_image=
    touch -r "$disk" "$temporary" || return 1
    mv -T -- "$temporary" "$disk" || return 1
    temporary=
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    trap - EXIT INT TERM
)

rootfs_compose_disk_guest() (
    local LC_ALL=C
    export LC_ALL
    local base=$1 platform_source=$2 guest_input=$3 arch=$4 rootfs_type=$5
    local guest_free_value=$6 outer_free_value=$7 output=$8
    local guest_mode=${9:-overlay}
    local output_dir output_base guest_free outer_free nested_name root_info
    local partno start size label guest_bytes guest_inodes base_lock output_lock actual_guest_free
    local lock_fd1 lock_fd2 stage=validate-inputs status
    local base_snapshot= platform_snapshot= guest_overlay= guest_image= outer_partition=
    local nested_stage= empty_overlay= outer_disk= validation_partition=

    cleanup_disk_compose() {
        status=$?
        trap - EXIT INT TERM
        if ((status != 0)); then
            printf 'rootfs-disk: FAILED %s/%s stage=%s status=%s base=%s output=%s\n' \
                "$rootfs_type" "$arch" "$stage" "$status" "$base" "$output" >&2
        fi
        [[ -z $base_snapshot ]] || rm -f -- "$base_snapshot"
        [[ -z $platform_snapshot ]] || rm -rf -- "$platform_snapshot"
        [[ -z $guest_overlay ]] || rm -rf -- "$guest_overlay"
        [[ -z $guest_image ]] || rm -f -- "$guest_image"
        [[ -z $outer_partition ]] || rm -f -- "$outer_partition"
        [[ -z $nested_stage ]] || rm -rf -- "$nested_stage"
        [[ -z $empty_overlay ]] || rm -rf -- "$empty_overlay"
        [[ -z $outer_disk ]] || rm -f -- "$outer_disk"
        [[ -z $validation_partition ]] || rm -f -- "$validation_partition"
        if [[ -n ${lock_fd2:-} ]]; then flock -u "$lock_fd2" 2>/dev/null || true; exec {lock_fd2}>&-; fi
        if [[ -n ${lock_fd1:-} ]]; then flock -u "$lock_fd1" 2>/dev/null || true; exec {lock_fd1}>&-; fi
        exit "$status"
    }
    trap cleanup_disk_compose EXIT
    trap 'exit 130' INT TERM

    _rootfs_disk_require_tools basename cp dd debugfs dirname dumpe2fs e2fsck find \
        flock mkdir mktemp mv python3 realpath resize2fs rm sfdisk stat touch truncate || return 1
    [[ -f $base && ! -L $base ]] || { _rootfs_disk_error "base disk not found: $base"; return 1; }
    [[ -d $platform_source ]] || {
        _rootfs_disk_error 'platform input must be a directory'
        return 1
    }
    case $guest_mode in
        overlay) [[ -d $guest_input ]] || { _rootfs_disk_error 'guest overlay input must be a directory'; return 1; } ;;
        prebuilt) [[ -f $guest_input && ! -L $guest_input ]] || { _rootfs_disk_error 'prebuilt guest input must be a regular file'; return 1; } ;;
        *) _rootfs_disk_error "unknown guest input mode: $guest_mode"; return 1 ;;
    esac
    [[ $arch =~ ^[a-zA-Z0-9._-]+$ && $rootfs_type =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
    guest_free=$(rootfs_parse_size_bytes "$guest_free_value") || return 1
    outer_free=$(rootfs_parse_size_bytes "$outer_free_value") || return 1
    output_dir=$(dirname -- "$output")
    output_base=$(basename -- "$output")
    mkdir -p -- "$output_dir" || return 1
    if _rootfs_paths_alias "$base" "$output"; then
        _rootfs_disk_error "base and output resolve to the same file: $base"
        return 1
    else
        [[ $? -eq 1 ]] || return 1
    fi

    stage=lock-images
    base_lock=$(realpath -m -- "${base}.lock") || return 1
    output_lock=$(realpath -m -- "${output}.lock") || return 1
    [[ $base_lock != "$output_lock" ]] || return 1
    if [[ $base_lock < "$output_lock" ]]; then
        exec {lock_fd1}>"$base_lock" || return 1
        exec {lock_fd2}>"$output_lock" || return 1
    else
        exec {lock_fd1}>"$output_lock" || return 1
        exec {lock_fd2}>"$base_lock" || return 1
    fi
    flock -x "$lock_fd1" || return 1
    flock -x "$lock_fd2" || return 1

    stage=snapshot-inputs
    base_snapshot=$(mktemp "${output_dir}/.${output_base}.base.XXXXXX") || return 1
    platform_snapshot=$(mktemp -d "${output_dir}/.${output_base}.platform.XXXXXX") || return 1
    cp --preserve=all --reflink=auto --sparse=always -- "$base" "$base_snapshot" || return 1
    cp -a --reflink=auto -- "$platform_source/." "$platform_snapshot/" || return 1
    touch -a -r "$base_snapshot" "$base" || return 1
    _rootfs_disk_restore_tree_atimes "$platform_source" "$platform_snapshot" || return 1
    _rootfs_builder_normalize_overlay_seconds "$platform_snapshot" || return 1
    _rootfs_validate_payload_tree "$platform_snapshot" || return 1
    if [[ $guest_mode == overlay ]]; then
        guest_overlay=$(mktemp -d "${output_dir}/.${output_base}.guest-overlay.XXXXXX") || return 1
        cp -a --reflink=auto -- "$guest_input/." "$guest_overlay/" || return 1
        _rootfs_disk_restore_tree_atimes "$guest_input" "$guest_overlay" || return 1
        _rootfs_validate_payload_tree "$guest_overlay" || return 1
    else
        guest_image=$(mktemp "${output_dir}/.${output_base}.guest.XXXXXX") || return 1
        cp --preserve=all --reflink=auto --sparse=always -- "$guest_input" "$guest_image" || return 1
        touch -a -r "$guest_image" "$guest_input" || return 1
        _rootfs_check_clean "$guest_image" || return 1
        actual_guest_free=$(rootfs_ext4_free_bytes "$guest_image") || return 1
        ((actual_guest_free >= guest_free)) || {
            _rootfs_disk_error "prebuilt guest reserve is below ${guest_free_value}"
            return 1
        }
    fi

    stage=find-root-partition
    root_info=$(rootfs_disk_find_root_partition "$base_snapshot") || return 1
    read -r partno start size label <<<"$root_info"
    nested_name="rootfs-${arch}-${rootfs_type}.img"
    empty_overlay=$(mktemp -d "${output_dir}/.${output_base}.empty.XXXXXX") || return 1
    _rootfs_validate_protected_outer_path "$platform_snapshot" "$empty_overlay" "$nested_name" || return 1

    if [[ $guest_mode == overlay ]]; then
        stage=extract-clean-guest
        guest_image=$(mktemp "${output_dir}/.${output_base}.guest.XXXXXX") || return 1
        rm -f -- "$guest_image"
        rootfs_disk_extract_partition "$base_snapshot" "$start" "$size" "$guest_image" || return 1
        _rootfs_check_clean "$guest_image" || return 1

        stage=grow-and-inject-guest-tests
        guest_bytes=$(rootfs_overlay_apparent_bytes "$guest_overlay") || return 1
        guest_inodes=$(_rootfs_overlay_required_inodes "$guest_overlay") || return 1
        _rootfs_resize_for_capacity_in_place "$guest_image" "$guest_bytes" "$guest_free" "$guest_inodes" || return 1
        _rootfs_inject_tree_via_debugfs "$guest_image" "$guest_overlay" || return 1

        stage=compact-guest
        _rootfs_compact_in_place "$guest_image" "$guest_free" || return 1
        _rootfs_check_clean "$guest_image" || return 1
    fi

    stage=stage-nested-and-platform-payload
    nested_stage=$(mktemp -d "${output_dir}/.${output_base}.nested.XXXXXX") || return 1
    touch -d "@$(stat -c %Y -- "$base_snapshot")" "$guest_image" || return 1
    cp --preserve=mode,ownership,timestamps --reflink=auto --sparse=always -- \
        "$guest_image" "$nested_stage/$nested_name" || return 1
    _rootfs_validate_payload_tree "$nested_stage" || return 1

    stage=extract-outer-root
    outer_partition=$(mktemp "${output_dir}/.${output_base}.outer-root.XXXXXX") || return 1
    rm -f -- "$outer_partition"
    rootfs_disk_extract_partition "$base_snapshot" "$start" "$size" "$outer_partition" || return 1
    _rootfs_check_clean "$outer_partition" || return 1

    stage=grow-and-inject-outer-payload
    _rootfs_finish_outer_in_place "$outer_partition" "$nested_stage" "$empty_overlay" 0 || return 1
    _rootfs_finish_outer_in_place "$outer_partition" "$platform_snapshot" "$empty_overlay" \
        "$outer_free" "$nested_name" || return 1
    _rootfs_check_clean "$outer_partition" || return 1

    stage=replace-outer-partition
    outer_disk=$(mktemp "${output_dir}/.${output_base}.disk.XXXXXX") || return 1
    cp --preserve=all --reflink=auto --sparse=always -- "$base_snapshot" "$outer_disk" || return 1
    rootfs_disk_replace_partition "$outer_disk" "$partno" "$start" "$size" "$outer_partition" || return 1

    stage=validate-output
    root_info=$(rootfs_disk_find_root_partition "$outer_disk") || return 1
    read -r _ start size _ <<<"$root_info"
    validation_partition=$(mktemp "${output_dir}/.${output_base}.validation.XXXXXX") || return 1
    rm -f -- "$validation_partition"
    rootfs_disk_extract_partition "$outer_disk" "$start" "$size" "$validation_partition" || return 1
    _rootfs_check_clean "$validation_partition" || return 1
    _rootfs_debugfs_stat "$validation_partition" "/guest/$nested_name" required >/dev/null || return 1

    stage=publish-output
    touch -r "$base_snapshot" "$outer_disk" || return 1
    mv -T -- "$outer_disk" "$output" || return 1
    outer_disk=

    rm -f -- "$base_snapshot" "$guest_image" "$outer_partition" "$validation_partition"
    rm -rf -- "$platform_snapshot" "$guest_overlay" "$nested_stage" "$empty_overlay"
    base_snapshot=
    platform_snapshot=
    guest_overlay=
    guest_image=
    outer_partition=
    nested_stage=
    empty_overlay=
    validation_partition=
    flock -u "$lock_fd2"
    flock -u "$lock_fd1"
    exec {lock_fd2}>&-
    exec {lock_fd1}>&-
    trap - EXIT INT TERM
)
