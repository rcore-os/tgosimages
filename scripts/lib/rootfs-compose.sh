#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library, should be sourced, not executed." >&2
    exit 1
fi

_rootfs_compose_lib_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOTFS_TEST_BUILD=${ROOTFS_TEST_BUILD:-"${_rootfs_compose_lib_dir}/../rootfs-tests/build.sh"}
if ! declare -F _rootfs_inject_tree_via_debugfs >/dev/null; then
    # shellcheck source=rootfs.sh
    source "${_rootfs_compose_lib_dir}/rootfs.sh"
fi
unset _rootfs_compose_lib_dir

_rootfs_compose_error() {
    printf 'rootfs-compose: %s\n' "$*" >&2
    return 1
}

rootfs_builder_load_test_options() {
    (($# == 5)) || {
        _rootfs_compose_error 'rootfs_builder_load_test_options requires rootfs and four variable names'
        return 1
    }
    local rootfs_type=$1 outer_var=$2 guest_var=$3 guest_free_var=$4 outer_free_var=$5
    local outer_value guest_value guest_free_value outer_free_value
    outer_value=${!outer_var-}
    guest_value=${!guest_var-}
    guest_free_value=${!guest_free_var-}
    outer_free_value=${!outer_free_var-}
    [[ -n $outer_value ]] || outer_value=$("$ROOTFS_TEST_BUILD" defaults --rootfs "$rootfs_type" --scope outer) || return 1
    [[ -n $guest_value ]] || guest_value=$("$ROOTFS_TEST_BUILD" defaults --rootfs "$rootfs_type" --scope guest) || return 1
    [[ -n $guest_free_value ]] || guest_free_value=256M
    [[ -n $outer_free_value ]] || outer_free_value=256M
    printf -v "$outer_var" '%s' "$outer_value"
    printf -v "$guest_var" '%s' "$guest_value"
    printf -v "$guest_free_var" '%s' "$guest_free_value"
    printf -v "$outer_free_var" '%s' "$outer_free_value"
}

rootfs_builder_validate_reserves() {
    (($# == 2)) || return 1
    rootfs_parse_size_bytes "$1" >/dev/null || {
        _rootfs_compose_error "invalid guest free size: $1"
        return 1
    }
    rootfs_parse_size_bytes "$2" >/dev/null || {
        _rootfs_compose_error "invalid outer free size: $2"
        return 1
    }
}

_rootfs_builder_validate_test_selection() {
    local arch=$1 rootfs_type=$2 scope=$3 selection=$4 available name
    local -A supported=() seen=()
    [[ $selection == none || $selection == all ]] && return 0
    [[ $selection != ,* && $selection != *, && $selection != *,,* ]] || {
        _rootfs_compose_error "empty ${scope} test selection"
        return 1
    }
    available=$("$ROOTFS_TEST_BUILD" list --arch "$arch" --rootfs "$rootfs_type" --scope "$scope") || return 1
    while IFS= read -r name; do
        [[ -z $name ]] || supported[$name]=1
    done <<<"$available"
    local IFS=,
    for name in $selection; do
        [[ -z ${seen[$name]+set} ]] || continue
        seen[$name]=1
        [[ -n ${supported[$name]+set} ]] || {
            _rootfs_compose_error "plugin '$name' is not compatible with $arch/$rootfs_type/$scope"
            return 1
        }
    done
}

_rootfs_builder_normalize_overlay_seconds() {
    local overlay=$1 path atime mtime inventory
    inventory=$(mktemp) || return 1
    if ! find -P "$overlay" -depth -print0 >"$inventory"; then
        rm -f -- "$inventory"
        return 1
    fi
    while IFS= read -r -d '' path; do
        read -r atime mtime < <(stat -c '%X %Y' -- "$path") || { rm -f -- "$inventory"; return 1; }
        if [[ -L $path ]]; then
            touch -h -a -d "@$atime" "$path" || { rm -f -- "$inventory"; return 1; }
            touch -h -m -d "@$mtime" "$path" || { rm -f -- "$inventory"; return 1; }
        else
            touch -a -d "@$atime" "$path" || { rm -f -- "$inventory"; return 1; }
            touch -m -d "@$mtime" "$path" || { rm -f -- "$inventory"; return 1; }
        fi
    done <"$inventory"
    rm -f -- "$inventory"
}

rootfs_builder_prepare_test_overlays() {
    (($# == 7)) || {
        _rootfs_compose_error 'rootfs_builder_prepare_test_overlays requires arch, rootfs, selections, parent, and output variables'
        return 1
    }
    local arch=$1 rootfs_type=$2 outer_tests=$3 guest_tests=$4 parent=$5 outer_var=$6 guest_var=$7
    local owner="rootfs-${arch}-${rootfs_type}" outer_overlay guest_overlay
    _rootfs_builder_validate_test_selection "$arch" "$rootfs_type" outer "$outer_tests" || return 1
    _rootfs_builder_validate_test_selection "$arch" "$rootfs_type" guest "$guest_tests" || return 1
    mkdir -p -- "$parent" || return 1
    outer_overlay=$(mktemp -d "${parent}/.${owner}-outer-tests.XXXXXX") || return 1
    guest_overlay=$(mktemp -d "${parent}/.${owner}-guest-tests.XXXXXX") || {
        rm -rf -- "$outer_overlay"
        return 1
    }
    if ! "$ROOTFS_TEST_BUILD" build --arch "$arch" --rootfs "$rootfs_type" --scope outer \
        --tests "$outer_tests" --output "$outer_overlay" ||
       ! "$ROOTFS_TEST_BUILD" build --arch "$arch" --rootfs "$rootfs_type" --scope guest \
        --tests "$guest_tests" --output "$guest_overlay"; then
        rm -rf -- "$outer_overlay" "$guest_overlay"
        return 1
    fi
    # Generated overlays are builder-owned staging trees. Quantize their
    # timestamps without changing whole-second values before strict validation.
    if ! _rootfs_builder_normalize_overlay_seconds "$outer_overlay" ||
       ! _rootfs_builder_normalize_overlay_seconds "$guest_overlay" ||
       ! rootfs_validate_payload_tree "$outer_overlay" ||
       ! rootfs_validate_payload_tree "$guest_overlay"; then
        rm -rf -- "$outer_overlay" "$guest_overlay"
        return 1
    fi
    printf -v "$outer_var" '%s' "$outer_overlay"
    printf -v "$guest_var" '%s' "$guest_overlay"
}

_rootfs_require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || {
            _rootfs_compose_error "required tool not found: ${tool}"
            return 1
        }
    done
}

_rootfs_parse_decimal_bounded() {
    local value=${1-} limit=${2-}
    [[ "$value" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]] || return 1
    value=${value#"${value%%[!0]*}"}
    [[ -n "$value" ]] || value=0
    ((${#value} <= ${#limit})) || return 1
    if ((${#value} == ${#limit})) && [[ "$value" > "$limit" ]]; then
        return 1
    fi
    printf '%s\n' "$value"
}

rootfs_parse_size_bytes() {
    local value=${1-}
    local number suffix multiplier max=9223372036854775807 limit

    [[ "$value" =~ ^([0-9]+)([KkMmGg]([iI]?[Bb])?|[Bb])?$ ]] || return 1
    number=${BASH_REMATCH[1]}
    suffix=${BASH_REMATCH[2]-}
    suffix=${suffix,,}
    case "$suffix" in
        ''|b) multiplier=1 ;;
        k|kib) multiplier=1024 ;;
        m|mib) multiplier=1048576 ;;
        g|gib) multiplier=1073741824 ;;
        kb) multiplier=1000 ;;
        mb) multiplier=1000000 ;;
        gb) multiplier=1000000000 ;;
        *) return 1 ;;
    esac
    limit=$((max / multiplier))
    number=$(_rootfs_parse_decimal_bounded "$number" "$limit") || return 1
    printf '%s\n' "$((number * multiplier))"
}

_rootfs_ext4_stats() {
    local image=$1 output block_count free_blocks block_size free_inodes max=9223372036854775807 value
    [[ -f "$image" ]] || return 1
    output=$(LC_ALL=C dumpe2fs -h "$image" 2>/dev/null) || return 1
    block_count=$(awk -F: '$1 == "Block count" {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$output")
    free_blocks=$(awk -F: '$1 == "Free blocks" {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$output")
    block_size=$(awk -F: '$1 == "Block size" {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$output")
    free_inodes=$(awk -F: '$1 == "Free inodes" {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$output")
    for value in "$block_count" "$free_blocks" "$block_size" "$free_inodes"; do
        [[ "$value" =~ ^[0-9]+$ ]] || return 1
        ((${#value} <= ${#max})) || return 1
        if ((${#value} == ${#max})) && [[ "$value" > "$max" ]]; then return 1; fi
    done
    ((block_size > 0 && free_blocks <= block_count)) || return 1
    printf '%s %s %s %s\n' "$block_count" "$free_blocks" "$block_size" "$free_inodes"
}

rootfs_ext4_free_inodes() {
    _rootfs_require_tools awk dumpe2fs || return 1
    local stats free_inodes
    stats=$(_rootfs_ext4_stats "$1") || return 1
    read -r _ _ _ free_inodes <<<"$stats"
    printf '%s\n' "$free_inodes"
}

_rootfs_overlay_required_inodes() (
    local directory=$1 inventory path key count=1
    local -A regular_inodes=()
    [[ -d "$directory" ]] || return 1
    inventory=$(mktemp) || return 1
    trap 'rm -f -- "$inventory"' EXIT
    find "$directory" -mindepth 1 -print0 >"$inventory" || return 1
    while IFS= read -r -d '' path; do
        if [[ -L "$path" || -d "$path" ]]; then
            ((count < 9223372036854775807)) || return 1
            count=$((count + 1))
        elif [[ -f "$path" ]]; then
            key=$(stat -c '%d:%i' -- "$path") || return 1
            if [[ -z ${regular_inodes[$key]+x} ]]; then
                regular_inodes[$key]=1
                ((count < 9223372036854775807)) || return 1
                count=$((count + 1))
            fi
        else
            return 1
        fi
    done <"$inventory"
    printf '%s\n' "$count"
)

rootfs_ext4_free_bytes() {
    _rootfs_require_tools awk dumpe2fs || return 1
    local stats free_blocks block_size
    stats=$(_rootfs_ext4_stats "$1") || return 1
    read -r _ free_blocks block_size _ <<<"$stats"
    ((free_blocks <= 9223372036854775807 / block_size)) || return 1
    printf '%s\n' "$((free_blocks * block_size))"
}

rootfs_overlay_apparent_bytes() {
    local directory=$1 path size total=0
    [[ -d "$directory" ]] || return 1
    _rootfs_require_tools find stat || return 1
    while IFS= read -r -d '' path; do
        if [[ -L "$path" ]]; then
            size=$(stat -c %s -- "$path") || return 1
        elif [[ -f "$path" ]]; then
            size=$(stat -c %s -- "$path") || return 1
        elif [[ -d "$path" ]]; then
            size=0
        else
            _rootfs_compose_error "unsupported payload entry: ${path}"
            return 1
        fi
        ((size <= 9223372036854775807 - total - 4096)) || return 1
        total=$((total + size + 4096))
    done < <(find "$directory" -mindepth 1 -print0)
    # Account for the root directory inode/block even for an empty overlay.
    ((total <= 9223372036854771711)) || return 1
    printf '%s\n' "$((total + 4096))"
}

_rootfs_check_clean() {
    local image=$1 status state
    state=$(LC_ALL=C dumpe2fs -h "$image" 2>/dev/null | awk -F: '
        $1 == "Filesystem state" {gsub(/^[[:space:]]+/, "", $2); print $2; exit}
    ') || return 1
    [[ "$state" == clean ]] || return 1
    if LC_ALL=C e2fsck -fn "$image" >/dev/null 2>&1; then
        status=0
    else
        status=$?
    fi
    [[ $status -eq 0 ]]
}

_rootfs_resize_for_capacity_in_place() {
    local image=$1 pending=$2 reserve=$3 pending_inodes=${4:-0}
    local free free_inodes required deficit addition current_size new_size headroom units
    local quantum=$((4 * 1024 * 1024)) iterations=0

    free=$(rootfs_ext4_free_bytes "$image") || return 1
    free_inodes=$(rootfs_ext4_free_inodes "$image") || return 1
    headroom=$((pending / 20 + (pending % 20 != 0)))
    ((pending <= 9223372036854775807 - headroom)) || return 1
    ((reserve <= 9223372036854775807 - pending - headroom)) || return 1
    required=$((pending + reserve + headroom))
    while ((free < required || free_inodes < pending_inodes)); do
        ((iterations++ < 64)) || {
            _rootfs_compose_error "capacity growth did not converge for ${image}"
            return 1
        }
        if ((free < required)); then deficit=$((required - free)); else deficit=$quantum; fi
        units=$((deficit / quantum + (deficit % quantum != 0)))
        ((units <= 9223372036854775807 / quantum)) || return 1
        addition=$((units * quantum))
        current_size=$(stat -c %s -- "$image") || return 1
        ((current_size <= 9223372036854775807 - addition)) || return 1
        new_size=$((current_size + addition))
        truncate -s "$new_size" -- "$image" || return 1
        LC_ALL=C resize2fs "$image" >/dev/null 2>&1 || return 1
        free=$(rootfs_ext4_free_bytes "$image") || return 1
        free_inodes=$(rootfs_ext4_free_inodes "$image") || return 1
    done
}

rootfs_ensure_ext4_capacity() (
    local image=$1 pending_value=$2 reserve_value=$3 pending_inodes=${4:-0}
    local pending reserve directory base temp lock_fd headroom
    _rootfs_require_tools awk basename cp dirname dumpe2fs e2fsck flock mktemp mv resize2fs rm stat touch truncate || return 1
    pending=$(rootfs_parse_size_bytes "$pending_value") || return 1
    reserve=$(rootfs_parse_size_bytes "$reserve_value") || return 1
    pending_inodes=$(_rootfs_parse_decimal_bounded "$pending_inodes" 9223372036854775807) || return 1
    headroom=$((pending / 20 + (pending % 20 != 0)))
    ((pending <= 9223372036854775807 - headroom)) || return 1
    ((reserve <= 9223372036854775807 - pending - headroom)) || return 1
    directory=$(dirname -- "$image")
    base=$(basename -- "$image")
    exec {lock_fd}>"${image}.lock" || return 1
    flock -x "$lock_fd" || return 1
    _rootfs_ext4_stats "$image" >/dev/null || return 1
    _rootfs_check_clean "$image" || {
        _rootfs_compose_error "ext4 image is dirty or unrepairable: ${image}"
        return 1
    }
    temp=
    trap '[[ -z ${temp:-} ]] || rm -f -- "$temp"' EXIT
    trap 'exit 130' INT TERM
    temp=$(mktemp "${directory}/.${base}.capacity.XXXXXX") || return 1
    if ! cp --preserve=all --reflink=auto --sparse=always -- "$image" "$temp" ||
       ! _rootfs_resize_for_capacity_in_place "$temp" "$pending" "$reserve" "$pending_inodes" ||
       ! touch -r "$image" "$temp" ||
       ! mv -T -- "$temp" "$image"; then
        rm -f -- "$temp"
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    fi
    temp=
    flock -u "$lock_fd"
    exec {lock_fd}>&-
)

_rootfs_repair_ext4() {
    local image=$1 status
    if LC_ALL=C e2fsck -fy "$image" >/dev/null 2>&1; then
        status=0
    else
        status=$?
    fi
    ((status == 0 || status == 1))
}

_rootfs_compact_in_place() {
    local image=$1 reserve=$2 stats blocks block_size exact_size free deficit add_blocks new_blocks headroom
    local iterations=0
    _rootfs_repair_ext4 "$image" || return 1
    LC_ALL=C resize2fs -M "$image" >/dev/null 2>&1 || return 1
    stats=$(_rootfs_ext4_stats "$image") || return 1
    read -r blocks _ block_size _ <<<"$stats"
    ((blocks <= 9223372036854775807 / block_size)) || return 1
    exact_size=$((blocks * block_size))
    truncate -s "$exact_size" -- "$image" || return 1
    while :; do
        ((iterations++ < 64)) || return 1
        _rootfs_repair_ext4 "$image" || return 1
        stats=$(_rootfs_ext4_stats "$image") || return 1
        read -r blocks _ block_size _ <<<"$stats"
        ((blocks <= 9223372036854775807 / block_size)) || return 1
        truncate -s "$((blocks * block_size))" -- "$image" || return 1
        free=$(rootfs_ext4_free_bytes "$image") || return 1
        ((free < reserve)) || break
        deficit=$((reserve - free))
        add_blocks=$((deficit / block_size + (deficit % block_size != 0)))
        # Give resize metadata a 5% margin and grow by at least one block.
        headroom=$((add_blocks / 20 + (add_blocks % 20 != 0)))
        ((add_blocks <= 9223372036854775807 - headroom - 1)) || return 1
        add_blocks=$((add_blocks + headroom + 1))
        ((blocks <= 9223372036854775807 - add_blocks)) || return 1
        new_blocks=$((blocks + add_blocks))
        ((new_blocks <= 9223372036854775807 / block_size)) || return 1
        truncate -s "$((new_blocks * block_size))" -- "$image" || return 1
        LC_ALL=C resize2fs "$image" "$new_blocks" >/dev/null 2>&1 || return 1
        stats=$(_rootfs_ext4_stats "$image") || return 1
        read -r blocks _ block_size _ <<<"$stats"
        ((blocks <= 9223372036854775807 / block_size)) || return 1
        truncate -s "$((blocks * block_size))" -- "$image" || return 1
    done
}

rootfs_compact_ext4() (
    local image=$1 reserve_value=$2 reserve directory base temp lock_fd
    _rootfs_require_tools awk basename cp dirname dumpe2fs e2fsck flock mktemp mv resize2fs rm stat touch truncate || return 1
    reserve=$(rootfs_parse_size_bytes "$reserve_value") || return 1
    directory=$(dirname -- "$image")
    base=$(basename -- "$image")
    exec {lock_fd}>"${image}.lock" || return 1
    flock -x "$lock_fd" || return 1
    _rootfs_ext4_stats "$image" >/dev/null || return 1
    temp=
    trap '[[ -z ${temp:-} ]] || rm -f -- "$temp"' EXIT
    trap 'exit 130' INT TERM
    temp=$(mktemp "${directory}/.${base}.compact.XXXXXX") || return 1
    if ! cp --preserve=all --reflink=auto --sparse=always -- "$image" "$temp" ||
       ! _rootfs_compact_in_place "$temp" "$reserve" ||
       ! touch -r "$image" "$temp" ||
       ! mv -T -- "$temp" "$image"; then
        rm -f -- "$temp"
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    fi
    temp=
    flock -u "$lock_fd"
    exec {lock_fd}>&-
)

_rootfs_validate_payload_tree() {
    rootfs_validate_payload_tree "$@"
}

rootfs_validate_payload_tree() (
    local directory=$1 path rel atime_raw mtime_raw timestamp_text fraction link_target inventory_raw inventory
    local -a timestamps=()
    [[ -d "$directory" ]] || return 1
    _rootfs_require_tools find getfacl getfattr mktemp readlink sort stat || return 1
    inventory_raw=$(mktemp "${TMPDIR:-/tmp}/rootfs-payload-inventory.raw.XXXXXX") || return 1
    inventory=$(mktemp "${TMPDIR:-/tmp}/rootfs-payload-inventory.sorted.XXXXXX") || {
        rm -f -- "$inventory_raw"
        return 1
    }
    trap 'rm -f -- "$inventory_raw" "$inventory"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! find -P "$directory" -mindepth 1 -print0 >"$inventory_raw"; then
        return 1
    fi
    if ! LC_ALL=C sort -z "$inventory_raw" >"$inventory"; then
        return 1
    fi
    while IFS= read -r -d '' path; do
        rel=${path#"$directory/"}
        [[ "$rel" != *[$'\001'-$'\037'$'\177']* && "$rel" != *['"'\\]* ]] || {
            _rootfs_compose_error "unsupported payload path: ${rel}"
            return 1
        }
        atime_raw=$(stat -c %x -- "$path") || return 1
        mtime_raw=$(stat -c %y -- "$path") || return 1
        timestamps=("$mtime_raw")
        [[ ! -L $path && -d $path ]] || timestamps+=("$atime_raw")
        for timestamp_text in "${timestamps[@]}"; do
            [[ $timestamp_text =~ \.([0-9]{9}) ]] || return 1
            fraction=${BASH_REMATCH[1]}
            [[ $fraction == 000000000 ]] || {
                _rootfs_compose_error "fractional payload timestamp: ${rel}"
                return 1
            }
        done
        if [[ -L $path ]]; then
            link_target=$(readlink -- "$path") || return 1
            [[ "$link_target" != *[$'\001'-$'\037'$'\177']* && "$link_target" != *['"'\\]* ]] || return 1
        elif [[ ! -f $path && ! -d $path ]]; then
            _rootfs_compose_error "unsupported special payload object: ${rel}"
            return 1
        fi
        if _rootfs_payload_has_unpreserved_metadata "$path"; then
            _rootfs_compose_error "payload xattrs or extended ACLs are unsupported: ${rel}"
            return 1
        else
            [[ $? -eq 1 ]] || return 1
        fi
    done <"$inventory"
)

_rootfs_validate_guest_overlay_merge() {
    local guest_source=$1 overlay_source=$2 path relative counterpart
    if [[ -e "$overlay_source/guest" || -L "$overlay_source/guest" ]]; then
        [[ -d "$overlay_source/guest" && ! -L "$overlay_source/guest" ]] || {
            _rootfs_compose_error "overlay /guest entry is not a directory"
            return 1
        }
        while IFS= read -r -d '' path; do
            relative=${path#"$overlay_source/guest/"}
            counterpart="$guest_source/$relative"
            if [[ -e "$counterpart" || -L "$counterpart" ]]; then
                if [[ ! -d "$path" || -L "$path" || ! -d "$counterpart" || -L "$counterpart" ]]; then
                    _rootfs_compose_error "guest/overlay payload collision: guest/${relative}"
                    return 1
                fi
            fi
        done < <(find "$overlay_source/guest" -mindepth 1 -print0)
    fi
}

_rootfs_validate_protected_outer_path() {
    local guest_source=$1 overlay_source=$2 protected=$3
    [[ -n "$protected" && "$protected" != */* && "$protected" != . && "$protected" != .. ]] || return 1
    [[ ! -e "$guest_source/$protected" && ! -L "$guest_source/$protected" ]] || {
        _rootfs_compose_error "guest payload collides with protected image: ${protected}"
        return 1
    }
    # A non-directory /guest is an ancestor conflict; any kind of exact target
    # (file, directory, or symlink, including dangling symlinks) is protected.
    if [[ -e "$overlay_source/guest" || -L "$overlay_source/guest" ]]; then
        [[ -d "$overlay_source/guest" && ! -L "$overlay_source/guest" ]] || {
            _rootfs_compose_error "overlay path conflicts with protected image ancestor: guest"
            return 1
        }
    fi
    [[ ! -e "$overlay_source/guest/$protected" && ! -L "$overlay_source/guest/$protected" ]] || {
        _rootfs_compose_error "overlay payload collides with protected image: guest/${protected}"
        return 1
    }
}

_rootfs_paths_alias() {
    local first=$1 second=$2 first_canonical second_canonical
    if [[ -e "$second" || -L "$second" ]]; then
        [[ "$first" -ef "$second" ]] && return 0
    fi
    first_canonical=$(realpath -m -- "$first") || return 2
    second_canonical=$(realpath -m -- "$second") || return 2
    [[ "$first_canonical" == "$second_canonical" ]]
}

_rootfs_finish_outer_in_place() (
    local image=$1 guest_source=$2 overlay_source=$3 reserve=$4 protected=${5-}
    local guest_bytes overlay_bytes guest_inodes overlay_inodes pending pending_inodes stage free guest_snapshot overlay_snapshot image_dir
    local iterations=0
    image_dir=$(dirname -- "$image")
    stage=
    guest_snapshot=
    overlay_snapshot=
    trap '[[ -z ${stage:-} ]] || rm -rf -- "$stage"; [[ -z ${guest_snapshot:-} ]] || rm -rf -- "$guest_snapshot"; [[ -z ${overlay_snapshot:-} ]] || rm -rf -- "$overlay_snapshot"' EXIT
    trap 'exit 130' INT TERM
    guest_snapshot=$(mktemp -d "${image_dir}/.guest-snapshot.XXXXXX") || return 1
    overlay_snapshot=$(mktemp -d "${image_dir}/.overlay-snapshot.XXXXXX") || return 1
    cp -a --reflink=auto -- "$guest_source/." "$guest_snapshot/" || return 1
    cp -a --reflink=auto -- "$overlay_source/." "$overlay_snapshot/" || return 1
    _rootfs_validate_payload_tree "$guest_snapshot" || return 1
    _rootfs_validate_payload_tree "$overlay_snapshot" || return 1
    _rootfs_validate_guest_overlay_merge "$guest_snapshot" "$overlay_snapshot" || return 1
    if [[ -n "$protected" ]]; then
        _rootfs_validate_protected_outer_path "$guest_snapshot" "$overlay_snapshot" "$protected" || return 1
    fi
    guest_bytes=$(rootfs_overlay_apparent_bytes "$guest_snapshot") || return 1
    overlay_bytes=$(rootfs_overlay_apparent_bytes "$overlay_snapshot") || return 1
    guest_inodes=$(_rootfs_overlay_required_inodes "$guest_snapshot") || return 1
    overlay_inodes=$(_rootfs_overlay_required_inodes "$overlay_snapshot") || return 1
    ((guest_bytes <= 9223372036854775807 - overlay_bytes)) || return 1
    ((guest_inodes <= 9223372036854775807 - overlay_inodes)) || return 1
    pending=$((guest_bytes + overlay_bytes))
    pending_inodes=$((guest_inodes + overlay_inodes))
    _rootfs_resize_for_capacity_in_place "$image" "$pending" "$reserve" "$pending_inodes" || return 1
    stage=$(mktemp -d "${image_dir}/.outer-stage.XXXXXX") || return 1
    mkdir -p "$stage/guest"
    cp -a -- "$guest_snapshot/." "$stage/guest/" || { rm -rf -- "$stage"; return 1; }
    touch -d @0 "$stage/guest" || return 1
    _rootfs_inject_tree_via_debugfs "$image" "$stage" || { rm -rf -- "$stage"; return 1; }
    rm -rf -- "$stage"
    stage=
    _rootfs_inject_tree_via_debugfs "$image" "$overlay_snapshot" || return 1
    while :; do
        ((iterations++ < 64)) || return 1
        _rootfs_repair_ext4 "$image" || return 1
        free=$(rootfs_ext4_free_bytes "$image") || return 1
        ((free < reserve)) || break
        _rootfs_resize_for_capacity_in_place "$image" 0 "$reserve" || return 1
    done
)

rootfs_inject_outer_payload_atomic() (
    local image=$1 guest_source=$2 overlay_source=$3 protected=$4 reserve_value=$5
    local reserve directory base temp lock_fd
    _rootfs_require_tools awk basename cp debugfs dirname dumpe2fs e2fsck find flock mkdir mktemp mv resize2fs rm stat touch truncate || return 1
    reserve=$(rootfs_parse_size_bytes "$reserve_value") || return 1
    _rootfs_validate_payload_tree "$guest_source" || return 1
    _rootfs_validate_payload_tree "$overlay_source" || return 1
    _rootfs_validate_guest_overlay_merge "$guest_source" "$overlay_source" || return 1
    _rootfs_validate_protected_outer_path "$guest_source" "$overlay_source" "$protected" || return 1
    directory=$(dirname -- "$image")
    base=$(basename -- "$image")
    exec {lock_fd}>"${image}.lock" || return 1
    flock -x "$lock_fd" || return 1
    _rootfs_ext4_stats "$image" >/dev/null || return 1
    _rootfs_check_clean "$image" || return 1
    temp=
    trap '[[ -z ${temp:-} ]] || rm -f -- "$temp"' EXIT
    trap 'exit 130' INT TERM
    temp=$(mktemp "${directory}/.${base}.inject.XXXXXX") || return 1
    if ! cp --preserve=all --reflink=auto --sparse=always -- "$image" "$temp" ||
       ! _rootfs_finish_outer_in_place "$temp" "$guest_source" "$overlay_source" "$reserve" "$protected" ||
       ! touch -r "$image" "$temp" ||
       ! mv -T -- "$temp" "$image"; then
        rm -f -- "$temp"
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    fi
    temp=
    flock -u "$lock_fd"
    exec {lock_fd}>&-
)

rootfs_compose_test_images() (
    local LC_ALL=C
    export LC_ALL
    local base=$1 outer_overlay=$2 guest_overlay=$3 outer_guest=$4 arch=$5 rootfs_type=$6
    local guest_free_value=$7 outer_free_value=$8 output=$9 guest_free outer_free nested_name
    local output_dir output_base guest_image outer_image nested_stage empty_overlay guest_overlay_snapshot base_snapshot
    local base_lock output_lock lock_fd1 lock_fd2
    _rootfs_require_tools awk basename cp debugfs dirname dumpe2fs e2fsck find flock mkdir mktemp mv realpath resize2fs rm stat touch truncate || return 1
    [[ "$base" != *.cpio.gz && "$output" != *.cpio.gz ]] || return 1
    [[ -f "$base" && -n "$arch" && "$arch" != */* && -n "$rootfs_type" && "$rootfs_type" != */* ]] || return 1
    output_dir=$(dirname -- "$output")
    output_base=$(basename -- "$output")
    mkdir -p -- "$output_dir" || return 1
    if _rootfs_paths_alias "$base" "$output"; then
        _rootfs_compose_error "base and output resolve to the same file: ${base}"
        return 1
    else
        [[ $? -eq 1 ]] || return 1
    fi
    base_lock=$(realpath -m -- "${base}.lock") || return 1
    output_lock=$(realpath -m -- "${output}.lock") || return 1
    [[ "$base_lock" != "$output_lock" ]] || {
        _rootfs_compose_error "base and output resolve to the same lock path: ${base_lock}"
        return 1
    }
    # All two-image operations acquire persistent lock paths lexicographically.
    if [[ "$base_lock" < "$output_lock" ]]; then
        exec {lock_fd1}>"$base_lock" || return 1
        exec {lock_fd2}>"$output_lock" || return 1
    else
        exec {lock_fd1}>"$output_lock" || return 1
        exec {lock_fd2}>"$base_lock" || return 1
    fi
    flock -x "$lock_fd1" || return 1
    flock -x "$lock_fd2" || return 1
    guest_free=$(rootfs_parse_size_bytes "$guest_free_value") || return 1
    outer_free=$(rootfs_parse_size_bytes "$outer_free_value") || return 1
    _rootfs_validate_payload_tree "$outer_overlay" || return 1
    _rootfs_validate_payload_tree "$guest_overlay" || return 1
    _rootfs_validate_payload_tree "$outer_guest" || return 1
    _rootfs_validate_guest_overlay_merge "$outer_guest" "$outer_overlay" || return 1
    _rootfs_ext4_stats "$base" >/dev/null || return 1
    _rootfs_check_clean "$base" || return 1
    nested_name="rootfs-${arch}-${rootfs_type}.img"
    _rootfs_validate_protected_outer_path "$outer_guest" "$outer_overlay" "$nested_name" || return 1
    guest_image=
    outer_image=
    nested_stage=
    empty_overlay=
    guest_overlay_snapshot=
    base_snapshot=
    trap '[[ -z ${guest_image:-} ]] || rm -f -- "$guest_image"; [[ -z ${outer_image:-} ]] || rm -f -- "$outer_image"; [[ -z ${nested_stage:-} ]] || rm -rf -- "$nested_stage"; [[ -z ${empty_overlay:-} ]] || rm -rf -- "$empty_overlay"; [[ -z ${guest_overlay_snapshot:-} ]] || rm -rf -- "$guest_overlay_snapshot"; [[ -z ${base_snapshot:-} ]] || rm -f -- "$base_snapshot"' EXIT
    trap 'exit 130' INT TERM
    base_snapshot=$(mktemp "${output_dir}/.${output_base}.base.XXXXXX") || return 1
    cp --preserve=all --reflink=auto --sparse=always -- "$base" "$base_snapshot" || return 1
    guest_overlay_snapshot=$(mktemp -d "${output_dir}/.${output_base}.guest-overlay.XXXXXX") || return 1
    cp -a --reflink=auto -- "$guest_overlay/." "$guest_overlay_snapshot/" || return 1
    _rootfs_validate_payload_tree "$guest_overlay_snapshot" || return 1
    guest_image=$(mktemp "${output_dir}/.${output_base}.guest.XXXXXX") || return 1
    outer_image=$(mktemp "${output_dir}/.${output_base}.outer.XXXXXX") || { rm -f -- "$guest_image"; return 1; }
    nested_stage=$(mktemp -d "${output_dir}/.${output_base}.nested.XXXXXX") || {
        rm -f -- "$guest_image" "$outer_image"; return 1;
    }
    empty_overlay=$(mktemp -d "${output_dir}/.${output_base}.empty.XXXXXX") || {
        rm -rf -- "$nested_stage"; rm -f -- "$guest_image" "$outer_image"; return 1;
    }
    if ! cp --preserve=all --reflink=auto --sparse=always -- "$base_snapshot" "$guest_image" ||
       ! _rootfs_resize_for_capacity_in_place "$guest_image" "$(rootfs_overlay_apparent_bytes "$guest_overlay_snapshot")" "$guest_free" "$(_rootfs_overlay_required_inodes "$guest_overlay_snapshot")" ||
       ! _rootfs_inject_tree_via_debugfs "$guest_image" "$guest_overlay_snapshot" ||
       ! _rootfs_compact_in_place "$guest_image" "$guest_free" ||
       ! cp --preserve=all --reflink=auto --sparse=always -- "$base_snapshot" "$outer_image"; then
        rm -rf -- "$nested_stage" "$empty_overlay"; rm -f -- "$guest_image" "$outer_image"
        return 1
    fi
    touch -d "@$(stat -c %Y -- "$base_snapshot")" "$guest_image" || return 1
    mkdir -p "$nested_stage/guest"
    # The nested image becomes filesystem payload; retain ordinary metadata but
    # do not carry host-only xattrs/ACLs that the debugfs policy rejects.
    cp --preserve=mode,ownership,timestamps --reflink=auto --sparse=always -- \
        "$guest_image" "$nested_stage/guest/$nested_name" || {
        rm -rf -- "$nested_stage" "$empty_overlay"; rm -f -- "$guest_image" "$outer_image"
        return 1
    }
    if ! _rootfs_finish_outer_in_place "$outer_image" "$nested_stage/guest" "$empty_overlay" 0 ||
       ! _rootfs_finish_outer_in_place "$outer_image" "$outer_guest" "$outer_overlay" "$outer_free" "$nested_name" ||
       ! _rootfs_compact_in_place "$outer_image" "$outer_free" ||
       ! touch -r "$base_snapshot" "$outer_image" ||
       ! mv -T -- "$outer_image" "$output"; then
        rm -rf -- "$nested_stage" "$empty_overlay"; rm -f -- "$guest_image" "$outer_image"
        return 1
    fi
    rm -rf -- "$nested_stage" "$empty_overlay" "$guest_overlay_snapshot"
    rm -f -- "$guest_image" "$base_snapshot"
    guest_image=
    outer_image=
    nested_stage=
    empty_overlay=
    guest_overlay_snapshot=
    base_snapshot=
    flock -u "$lock_fd2"
    flock -u "$lock_fd1"
    exec {lock_fd2}>&-
    exec {lock_fd1}>&-
)
