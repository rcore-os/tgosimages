#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

die() {
    echo "rootfs-tests: $*" >&2
    exit 1
}

metadata_temp=''
producer_temp=''
cleanup_framework_temps() {
    if [[ -n $metadata_temp ]]; then
        rm -f -- "$metadata_temp"
        metadata_temp=''
    fi
    if [[ -n $producer_temp ]]; then
        rm -f -- "$producer_temp"
        producer_temp=''
    fi
}
trap cleanup_framework_temps EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_arch() {
    case $1 in aarch64|riscv64|x86_64|loongarch64) ;; *) die "unsupported arch: $1" ;; esac
}

validate_rootfs() {
    case $1 in busybox|alpine|debian) ;; *) die "unsupported rootfs: $1" ;; esac
}

validate_scope() {
    case $1 in outer|guest) ;; *) die "unsupported scope: $1" ;; esac
}

validate_capability_csv() {
    local kind=$1 csv=$2 member
    local -a members=()
    local -A seen=()
    [[ $csv != ,* && $csv != *, && $csv != *,,* ]] || die "empty $kind capability member"
    IFS=, read -r -a members <<<"$csv"
    for member in "${members[@]}"; do
        [[ -z ${seen[$member]+set} ]] || die "duplicate $kind capability member: $member"
        seen[$member]=1
        case $kind in
        arch) validate_arch "$member" ;;
        rootfs) validate_rootfs "$member" ;;
        scope) validate_scope "$member" ;;
        esac
    done
}

declare -a plugin_names=()
declare -A plugin_paths=()
declare -A plugin_arches=()
declare -A plugin_rootfs=()
declare -A plugin_scopes=()

discover_plugins() {
    local plugin_dir=${ROOTFS_TEST_PLUGIN_DIR:-"$script_dir/plugins"}
    local path line key value name description_file
    local -a lines paths=()
    local -A fields=() seen_names=()

    plugin_names=()
    [[ -d $plugin_dir ]] || return 0
    producer_temp=$(mktemp)
    if ! find "$plugin_dir" -mindepth 1 -maxdepth 1 -type f -name '*.sh' -perm /111 -print0 |
        LC_ALL=C sort -z >"$producer_temp"; then
        cleanup_framework_temps
        die "plugin discovery failed: $plugin_dir"
    fi
    while IFS= read -r -d '' path; do
        paths+=("$path")
    done <"$producer_temp"
    rm -f -- "$producer_temp"
    producer_temp=''

    for path in "${paths[@]}"; do
        fields=()
        metadata_temp=$(mktemp)
        description_file=$metadata_temp
        if ! "$path" describe >"$description_file"; then
            rm -f -- "$description_file"
            metadata_temp=''
            die "describe failed: $path"
        fi
        mapfile -t lines <"$description_file"
        rm -f -- "$description_file"
        metadata_temp=''
        ((${#lines[@]} == 4)) || die "describe must print exactly four lines: $path"
        for line in "${lines[@]}"; do
            [[ $line == *=* ]] || die "malformed describe line: $path"
            key=${line%%=*}
            value=${line#*=}
            case $key in name|arches|rootfs|scopes) ;; *) die "unknown describe key '$key': $path" ;; esac
            [[ -z ${fields[$key]+set} ]] || die "duplicate describe key '$key': $path"
            [[ -n $value ]] || die "empty describe value '$key': $path"
            fields[$key]=$value
        done
        for key in name arches rootfs scopes; do
            [[ -n ${fields[$key]+set} ]] || die "missing describe key '$key': $path"
        done
        validate_capability_csv arch "${fields[arches]}"
        validate_capability_csv rootfs "${fields[rootfs]}"
        validate_capability_csv scope "${fields[scopes]}"
        name=${fields[name]}
        [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid plugin name '$name': $path"
        [[ -z ${seen_names[$name]+set} ]] || die "duplicate declared plugin name: $name"
        seen_names[$name]=1
        plugin_names+=("$name")
        plugin_paths[$name]=$path
        plugin_arches[$name]=${fields[arches]}
        plugin_rootfs[$name]=${fields[rootfs]}
        plugin_scopes[$name]=${fields[scopes]}
    done
}

plugin_compatible() {
    local name=$1 arch=$2 rootfs=$3 scope=$4
    rootfs_test_csv_contains "$arch" "${plugin_arches[$name]}" &&
        rootfs_test_csv_contains "$rootfs" "${plugin_rootfs[$name]}" &&
        rootfs_test_csv_contains "$scope" "${plugin_scopes[$name]}"
}

parse_context_args() {
    arch= rootfs= scope=
    while (($#)); do
        case $1 in
        --arch) (($# >= 2)) || die 'missing --arch value'; arch=$2; shift 2 ;;
        --rootfs) (($# >= 2)) || die 'missing --rootfs value'; rootfs=$2; shift 2 ;;
        --scope) (($# >= 2)) || die 'missing --scope value'; scope=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
        esac
    done
    [[ -n $arch && -n $rootfs && -n $scope ]] || die 'arch, rootfs, and scope are required'
    validate_arch "$arch"
    validate_rootfs "$rootfs"
    validate_scope "$scope"
}

command_defaults() {
    local rootfs= scope=
    while (($#)); do
        case $1 in
        --rootfs) (($# >= 2)) || die 'missing --rootfs value'; rootfs=$2; shift 2 ;;
        --scope) (($# >= 2)) || die 'missing --scope value'; scope=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
        esac
    done
    [[ -n $rootfs && -n $scope ]] || die 'rootfs and scope are required'
    validate_rootfs "$rootfs"
    validate_scope "$scope"
    if [[ $scope == guest ]]; then
        printf '%s\n' 'cyclictest,lmbench,iozone'
    elif [[ $rootfs == alpine ]]; then
        printf '%s\n' ltp
    else
        printf '%s\n' none
    fi
}

command_list() {
    local arch rootfs scope name
    parse_context_args "$@"
    discover_plugins
    for name in "${plugin_names[@]}"; do
        if plugin_compatible "$name" "$arch" "$rootfs" "$scope"; then
            printf '%s\n' "$name"
        fi
    done | LC_ALL=C sort
}

path_type() {
    if [[ -L $1 ]]; then
        printf '%s\n' symlink
    elif [[ -d $1 ]]; then
        printf '%s\n' directory
    elif [[ -f $1 ]]; then
        printf '%s\n' file
    else
        return 1
    fi
}

command_build() {
    local arch= rootfs= scope= tests= output= name item dir rel type prior ancestor
    local publish='' publish_candidate='' temporary_root=''
    local backup='' backup_candidate='' replacement_complete=0 publish_lock_fd
    local -a selected=() stage_dirs=()
    local -A selected_names=() inventory=()

    while (($#)); do
        case $1 in
        --arch) (($# >= 2)) || die 'missing --arch value'; arch=$2; shift 2 ;;
        --rootfs) (($# >= 2)) || die 'missing --rootfs value'; rootfs=$2; shift 2 ;;
        --scope) (($# >= 2)) || die 'missing --scope value'; scope=$2; shift 2 ;;
        --tests) (($# >= 2)) || die 'missing --tests value'; tests=$2; shift 2 ;;
        --output) (($# >= 2)) || die 'missing --output value'; output=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
        esac
    done
    [[ -n $arch && -n $rootfs && -n $scope && -n $tests && -n $output ]] ||
        die 'arch, rootfs, scope, tests, and output are required'
    validate_arch "$arch"
    validate_rootfs "$rootfs"
    validate_scope "$scope"
    [[ -d $(dirname -- "$output") ]] || die "output parent does not exist: $output"

    discover_plugins
    case $tests in
    none) ;;
    all)
        for name in "${plugin_names[@]}"; do
            plugin_compatible "$name" "$arch" "$rootfs" "$scope" && selected+=("$name")
        done
        ;;
    *)
        local IFS=,
        for item in $tests; do
            [[ -n $item ]] || die 'empty plugin selection'
            [[ -n ${plugin_paths[$item]+set} ]] || die "unknown plugin: $item"
            plugin_compatible "$item" "$arch" "$rootfs" "$scope" ||
                die "plugin '$item' does not support $arch/$rootfs/$scope"
            if [[ -z ${selected_names[$item]+set} ]]; then
                selected_names[$item]=1
                selected+=("$item")
            fi
        done
        ;;
    esac

    cleanup_build() {
        local status=$?
        trap - EXIT
        if [[ -n $backup ]]; then
            if ((replacement_complete)); then
                rm -rf -- "$backup"
            else
                if [[ -e $output || -L $output ]]; then
                    rm -rf -- "$output"
                fi
                mv -T -- "$backup" "$output" || true
            fi
        fi
        [[ -z $publish ]] || rm -rf -- "$publish"
        [[ -z $temporary_root ]] || rm -rf -- "$temporary_root"
        cleanup_framework_temps
        exit "$status"
    }
    trap cleanup_build EXIT
    temporary_root=$(mktemp -d)
    for name in "${selected[@]}"; do
        dir=$(mktemp -d "$temporary_root/plugin.XXXXXX")
        stage_dirs+=("$dir")
        "${plugin_paths[$name]}" build --arch "$arch" --rootfs "$rootfs" --scope "$scope" --output "$dir" ||
            die "plugin build failed: $name"
    done

    for dir in "${stage_dirs[@]}"; do
        producer_temp=$(mktemp)
        if ! find -P "$dir" -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z >"$producer_temp"; then
            cleanup_framework_temps
            die "plugin inventory failed: $dir"
        fi
        while IFS= read -r -d '' rel; do
            type=$(path_type "$dir/$rel") || die "unsupported filesystem object: $rel"
            if [[ -n ${inventory[$rel]+set} ]]; then
                prior=${inventory[$rel]}
                [[ $type == directory && $prior == directory ]] || die "overlay collision: $rel"
            fi
            ancestor=$rel
            while [[ $ancestor == */* ]]; do
                ancestor=${ancestor%/*}
                if [[ -n ${inventory[$ancestor]+set} && ${inventory[$ancestor]} != directory ]]; then
                    die "overlay ancestor collision: $ancestor blocks $rel"
                fi
            done
            inventory[$rel]=$type
        done <"$producer_temp"
        rm -f -- "$producer_temp"
        producer_temp=''
    done

    publish_candidate="${output}.tmp.$$"
    [[ ! -e $publish_candidate && ! -L $publish_candidate ]] ||
        die "temporary output already exists: $publish_candidate"
    mkdir -- "$publish_candidate"
    publish=$publish_candidate
    for dir in "${stage_dirs[@]}"; do
        cp -a -- "$dir/." "$publish/"
    done
    # Keep the lock inode: unlinking it could split concurrent waiters across different locks.
    exec {publish_lock_fd}>"${output}.lock"
    flock -x "$publish_lock_fd"
    # Keep trap-visible ownership state synchronized with the two renames.
    trap '' INT TERM
    if [[ -e $output || -L $output ]]; then
        backup_candidate="${output}.old.$$"
        [[ ! -e $backup_candidate && ! -L $backup_candidate ]] ||
            die "backup output already exists: $backup_candidate"
        if ! mv -T -- "$output" "$backup_candidate"; then
            trap 'exit 130' INT
            trap 'exit 143' TERM
            die "failed to back up existing output: $output"
        fi
        backup=$backup_candidate
    fi
    if ! mv -T -- "$publish" "$output"; then
        if [[ -n $backup ]]; then
            if mv -T -- "$backup" "$output"; then
                backup=
            fi
        fi
        trap 'exit 130' INT
        trap 'exit 143' TERM
        die "failed to publish output: $output"
    fi
    publish=
    replacement_complete=1
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -n $backup ]]; then
        rm -rf -- "$backup"
        backup=
    fi
    flock -u "$publish_lock_fd"
    exec {publish_lock_fd}>&-
    rm -rf -- "$temporary_root"
    temporary_root=
    trap cleanup_framework_temps EXIT
}

(($#)) || die 'command required: build, defaults, or list'
command=$1
shift
case $command in
build) command_build "$@" ;;
defaults) command_defaults "$@" ;;
list) command_list "$@" ;;
*) die "unknown command: $command" ;;
esac
