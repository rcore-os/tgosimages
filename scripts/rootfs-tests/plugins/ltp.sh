#!/usr/bin/env bash
set -euo pipefail

name=ltp
version=20260529
archive_name=ltp-full-20260529.tar.xz
default_url=https://github.com/linux-test-project/ltp/releases/download/20260529/ltp-full-20260529.tar.xz
default_sha256=685d83c6e370ac09201fb79593412f868fe031ee2890e204b5727fedcf51fb47
source_top=ltp-full-20260529
prefix=/opt/ltp

plugin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$plugin_dir/../../.." && pwd)
# shellcheck source=../lib/common.sh
source "$plugin_dir/../lib/common.sh"

die() { echo "$name: $*" >&2; exit 1; }
plugin_work_dir=''
plugin_stage_dir=''
declare -a ltp_filter_dirs=()
declare -a ltp_filter_tests=()
ltp_runtest_filter_pattern=''
cleanup_work() {
    [[ -z $plugin_work_dir ]] || rm -rf -- "$plugin_work_dir"
    [[ -z $plugin_stage_dir ]] || rm -rf -- "$plugin_stage_dir"
}

configure_build_environment() {
    local item normalized
    ALPINE_LTP_CFLAGS=${ALPINE_LTP_CFLAGS:-}
    ALPINE_LTP_LDFLAGS=${ALPINE_LTP_LDFLAGS:-}
    ALPINE_LTP_FILTER_OUT_DIRS=${ALPINE_LTP_FILTER_OUT_DIRS:-fmtmsg}
    ALPINE_LTP_FILTER_OUT_TESTS=${ALPINE_LTP_FILTER_OUT_TESTS:-timer_create01 timer_create03}
    read -r -a ltp_filter_dirs <<<"$ALPINE_LTP_FILTER_OUT_DIRS"
    read -r -a ltp_filter_tests <<<"$ALPINE_LTP_FILTER_OUT_TESTS"
    for item in "${ltp_filter_dirs[@]}" "${ltp_filter_tests[@]}"; do
        [[ $item =~ ^[A-Za-z0-9_]+$ ]] || die "invalid LTP filter token: $item"
    done
    normalized=''
    printf -v normalized '%s ' "${ltp_filter_dirs[@]}"
    ALPINE_LTP_FILTER_OUT_DIRS=${normalized% }
    normalized=''
    printf -v normalized '%s ' "${ltp_filter_tests[@]}"
    ALPINE_LTP_FILTER_OUT_TESTS=${normalized% }
    for item in "${ltp_filter_dirs[@]}"; do
        ltp_runtest_filter_pattern="${ltp_runtest_filter_pattern:+$ltp_runtest_filter_pattern|}^${item}([0-9_]|[[:space:]]|$)"
    done
    for item in "${ltp_filter_tests[@]}"; do
        ltp_runtest_filter_pattern="${ltp_runtest_filter_pattern:+$ltp_runtest_filter_pattern|}^${item}([[:space:]]|$)"
    done
    export ALPINE_LTP_CFLAGS ALPINE_LTP_LDFLAGS ALPINE_LTP_FILTER_OUT_DIRS ALPINE_LTP_FILTER_OUT_TESTS
}

platform_for_arch() {
    case $1 in
    aarch64) printf '%s\n' linux/arm64/v8 ;;
    riscv64) printf '%s\n' linux/riscv64 ;;
    x86_64) printf '%s\n' linux/amd64 ;;
    loongarch64) printf '%s\n' linux/loong64 ;;
    *) return 1 ;;
    esac
}

select_source() {
    local fixture=${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-}
    local override_url=${ALPINE_LTP_URL:-} override_sha=${ALPINE_LTP_SHA256:-}
    local sidecar actual
    if [[ -n $override_url || -n $override_sha ]]; then
        [[ -n $override_url && -n $override_sha ]] ||
            die 'source URL and checksum overrides must be provided together'
        [[ $override_sha =~ ^[0-9a-f]{64}$ ]] || die 'invalid LTP source checksum'
    fi
    if [[ -n $fixture ]]; then
        [[ -d $fixture ]] || die "offline fixture directory does not exist: $fixture"
        if [[ -n $override_url || -n $override_sha ]]; then
            source_url=${override_url:-$default_url}
            source_sha256=${override_sha:-$default_sha256}
            [[ $source_sha256 =~ ^[0-9a-f]{64}$ ]] || die 'invalid LTP source checksum'
        else
            source_url="file://$fixture/$archive_name"
            sidecar="$fixture/$archive_name.sha256"
            [[ -f $fixture/$archive_name && -f $sidecar ]] || die "incomplete offline fixture for $archive_name"
            mapfile -t fixture_sum <"$sidecar"
            ((${#fixture_sum[@]} == 1)) && [[ ${fixture_sum[0]} =~ ^[0-9a-f]{64}$ ]] ||
                die 'invalid fixture checksum sidecar'
            source_sha256=${fixture_sum[0]}
            actual=$(sha256sum "$fixture/$archive_name" | awk '{print $1}')
            [[ $actual == "$source_sha256" ]] || die 'offline fixture checksum mismatch'
        fi
    else
        source_url=${override_url:-$default_url}
        source_sha256=${override_sha:-$default_sha256}
        [[ $source_sha256 =~ ^[0-9a-f]{64}$ ]] || die 'invalid LTP source checksum'
    fi
}

prepare_source() (
    local build_root=$1 archive source_dir lock_fd actual extract_tmp='' candidate=''
    cleanup_source() {
        local cleanup_status=$?
        trap - EXIT INT TERM
        [[ -z $extract_tmp ]] || rm -rf -- "$extract_tmp"
        [[ -z $candidate ]] || rm -rf -- "$candidate"
        exit "$cleanup_status"
    }
    trap cleanup_source EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    archive="$build_root/downloads/$name-$version-$source_sha256.tar.xz"
    source_dir="$build_root/sources/$name-$version-$source_sha256"
    mkdir -p "$build_root/downloads" "$build_root/sources"
    exec {lock_fd}>"$build_root/downloads/$name-$version-$source_sha256.lock"
    flock -x "$lock_fd"
    if [[ -f $archive ]]; then
        actual=$(sha256sum "$archive" | awk '{print $1}')
        [[ $actual == "$source_sha256" ]] || die "cached archive checksum mismatch: $archive"
    else
        rootfs_test_download_checked "$source_url" "$source_sha256" "$archive" ||
            die 'checked source download failed'
    fi
    flock -u "$lock_fd"; exec {lock_fd}>&-

    exec {lock_fd}>"$source_dir.lock"
    flock -x "$lock_fd"
    if [[ -d $source_dir ]]; then
        [[ -f $source_dir/.rootfs-test-source-sha256 ]] ||
            die "cached source lacks checksum provenance: $source_dir"
        read -r actual <"$source_dir/.rootfs-test-source-sha256"
        [[ $actual == "$source_sha256" ]] ||
            die "cached source checksum provenance mismatch: $source_dir"
    else
        extract_tmp=$(mktemp -d "$build_root/sources/.extract-$name-$version.XXXXXX")
        candidate=$(mktemp -d "$build_root/sources/.$name-$version.XXXXXX")
        tar -xf "$archive" -C "$extract_tmp" || die 'source extraction failed'
        [[ -d $extract_tmp/$source_top ]] || die "archive lacks $source_top"
        cp -a "$extract_tmp/$source_top/." "$candidate/"
        printf '%s\n' "$source_sha256" >"$candidate/.rootfs-test-source-sha256"
        mv -T -- "$candidate" "$source_dir"
        candidate=''
        rm -rf -- "$extract_tmp"
        extract_tmp=''
    fi
    flock -u "$lock_fd"; exec {lock_fd}>&-
    printf '%s\n' "$source_dir"
    trap - EXIT INT TERM
)

filter_install() {
    local source_dir=$1 stage_prefix=$2 item

    for item in "${ltp_filter_dirs[@]}"; do
        find "$stage_prefix" -type d -name "$item" -prune -exec rm -rf -- {} +
        find "$stage_prefix" -type f -name "${item}[0-9_]*" -delete
    done
    for item in "${ltp_filter_tests[@]}"; do
        find "$stage_prefix" -type f -name "$item" -delete
    done
    mkdir -p "$stage_prefix/runtest"
    if [[ -n $ltp_runtest_filter_pattern ]]; then
        grep -v -E "$ltp_runtest_filter_pattern" "$source_dir/runtest/syscalls" >"$stage_prefix/runtest/syscalls"
    else
        cp "$source_dir/runtest/syscalls" "$stage_prefix/runtest/syscalls"
    fi
    cp "$source_dir/runtest/sched" "$stage_prefix/runtest/sched"
    install -m 0644 "$source_dir/VERSION" "$stage_prefix/Version"
}

validate_install() {
    local arch=$1 stage_prefix=$2 actual_version item hackbench
    [[ -f $stage_prefix/Version ]] || die 'staged LTP Version is missing'
    actual_version=$(tr -d '\r\n' <"$stage_prefix/Version")
    [[ $actual_version == "$version" ]] || die "unexpected staged LTP version: $actual_version"
    [[ -s $stage_prefix/runtest/syscalls ]] || die 'staged LTP syscall runtest is empty'
    [[ -s $stage_prefix/runtest/sched ]] || die 'staged LTP scheduler runtest is empty'
    [[ -x $stage_prefix/testcases/bin/timer_create02 ]] || die 'staged timer_create02 is not executable'
    rootfs_test_validate_elf "$arch" "$stage_prefix/testcases/bin/timer_create02" ||
        die "invalid timer_create02 ELF for $arch"
    hackbench=$stage_prefix/testcases/bin/hackbench
    [[ -x $hackbench ]] || die 'staged scheduler representative hackbench is not executable'
    rootfs_test_validate_elf "$arch" "$hackbench" || die "invalid hackbench ELF for $arch"
    for item in "${ltp_filter_tests[@]}"; do
        [[ ! -e $stage_prefix/testcases/bin/$item ]] || die "excluded LTP testcase was staged: $item"
    done
    for item in "${ltp_filter_dirs[@]}"; do
        [[ -z $(find "$stage_prefix" -type d -name "$item" -print -quit) ]] ||
            die "excluded LTP directory was staged: $item"
        [[ -z $(find "$stage_prefix" -type f -name "${item}[0-9_]*" -print -quit) ]] ||
            die "excluded LTP directory testcase was staged: $item"
    done
    if [[ -n $ltp_runtest_filter_pattern ]] &&
       grep -Eq "$ltp_runtest_filter_pattern" "$stage_prefix/runtest/syscalls"; then
        die 'excluded LTP runtest entry was staged'
    fi
    awk '$1 ~ /^hackbench[0-9_]*$/ && $2 == "hackbench" { found=1 } END { exit !found }' \
        "$stage_prefix/runtest/sched" || die 'hackbench is not referenced by scheduler runtest'
}

build_fixture() {
    local source_dir=$1 stage_dir=$2
    make -C "$source_dir" CC="${CC:-cc}" CFLAGS="${ALPINE_LTP_CFLAGS:-}" \
        LDFLAGS="${ALPINE_LTP_LDFLAGS:-}"
    make -C "$source_dir" CC="${CC:-cc}" CFLAGS="${ALPINE_LTP_CFLAGS:-}" \
        LDFLAGS="${ALPINE_LTP_LDFLAGS:-}" DESTDIR="$stage_dir" PREFIX="$prefix" install
}

build_real() {
    local arch=$1 build_root=$2 source_dir=$3 stage_dir=$4 platform=$5 image uid gid builder
    command -v docker >/dev/null 2>&1 || die 'docker is required for real source builds'
    [[ -x $source_dir/configure ]] || die 'LTP release archive lacks executable configure'
    builder=${ROOTFS_TEST_ALPINE_BUILDER:-"$plugin_dir/../alpine-builder.sh"}
    image=$(ROOTFS_TEST_BUILD_ROOT="$build_root" "$builder" prepare --arch "$arch")
    uid=$(id -u); gid=$(id -g)
    docker run --rm --platform "$platform" \
        --env ALPINE_LTP_CFLAGS --env ALPINE_LTP_LDFLAGS \
        --env ALPINE_LTP_FILTER_OUT_DIRS --env ALPINE_LTP_FILTER_OUT_TESTS \
        -v "$source_dir:/ltp" -v "$stage_dir:/stage" -w /ltp \
        "$image" sh -ec "
            trap 'chown -R $uid:$gid /ltp /stage' EXIT
            make clean >/dev/null 2>&1 || true
            for filter_test in \$ALPINE_LTP_FILTER_OUT_TESTS; do
                find testcases/kernel/syscalls -type f -name \"\${filter_test}.c\" -print -delete
            done
            rm -f include/mk/config.mk include/mk/config-openposix.mk include/mk/features.mk include/config.h config.status
            CFLAGS=\"\$ALPINE_LTP_CFLAGS\" LDFLAGS=\"\$ALPINE_LTP_LDFLAGS\" ./configure \\
                --prefix='$prefix' --without-numa --without-tirpc --without-modules
            if printf '#include <linux/if_alg.h>\nint main(void){struct sockaddr_alg a; struct af_alg_iv v; return sizeof(a)+sizeof(v);}\n' |
                gcc -x c -c -o /tmp/ltp-if-alg.o - >/dev/null 2>&1; then
                sed -i -e 's@^/\\* #undef HAVE_LINUX_IF_ALG_H \\*/@#define HAVE_LINUX_IF_ALG_H 1@' \\
                    -e 's@^/\\* #undef HAVE_STRUCT_AF_ALG_IV \\*/@#define HAVE_STRUCT_AF_ALG_IV 1@' \\
                    -e 's@^/\\* #undef HAVE_STRUCT_SOCKADDR_ALG \\*/@#define HAVE_STRUCT_SOCKADDR_ALG 1@' include/config.h
            else
                sed -i -e 's@^#define HAVE_STRUCT_AF_ALG_IV .*@/* #undef HAVE_STRUCT_AF_ALG_IV */@' \\
                    -e 's@^#define HAVE_STRUCT_SOCKADDR_ALG .*@/* #undef HAVE_STRUCT_SOCKADDR_ALG */@' include/config.h
            fi
            make -C testcases/kernel/syscalls top_srcdir=/ltp top_builddir=/ltp \\
                FILTER_OUT_DIRS=\"\$ALPINE_LTP_FILTER_OUT_DIRS\"
            make -C testcases/kernel/syscalls top_srcdir=/ltp top_builddir=/ltp \\
                FILTER_OUT_DIRS=\"\$ALPINE_LTP_FILTER_OUT_DIRS\" DESTDIR=/stage install
            make -C testcases/kernel/ipc/pipeio top_srcdir=/ltp top_builddir=/ltp
            make -C testcases/kernel/ipc/pipeio top_srcdir=/ltp top_builddir=/ltp DESTDIR=/stage install
            make -C testcases/kernel/sched top_srcdir=/ltp top_builddir=/ltp
            make -C testcases/kernel/sched top_srcdir=/ltp top_builddir=/ltp DESTDIR=/stage install
        "
}

build_plugin() {
    local arch= rootfs= scope= output= build_root source_dir platform stage_prefix
    while (($#)); do
        case $1 in
        --arch) (($# >= 2)) || die 'missing --arch value'; arch=$2; shift 2 ;;
        --rootfs) (($# >= 2)) || die 'missing --rootfs value'; rootfs=$2; shift 2 ;;
        --scope) (($# >= 2)) || die 'missing --scope value'; scope=$2; shift 2 ;;
        --output) (($# >= 2)) || die 'missing --output value'; output=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
        esac
    done
    [[ -n $arch && -n $rootfs && -n $scope && -n $output ]] ||
        die 'arch, rootfs, scope, and output are required'
    platform=$(platform_for_arch "$arch") || die "unsupported arch: $arch"
    [[ $rootfs == alpine ]] || die "unsupported rootfs: $rootfs"
    [[ $scope == outer ]] || die "unsupported scope: $scope"
    [[ -d $output && -z $(find "$output" -mindepth 1 -print -quit) ]] ||
        die 'output must be an empty directory'

    configure_build_environment
    select_source
    build_root=${ROOTFS_TEST_BUILD_ROOT:-"$repo_root/build/rootfs-tests"}
    source_dir=$(prepare_source "$build_root")
    mkdir -p "$build_root/work/$name/$version/$arch/$rootfs"
    plugin_work_dir=$(mktemp -d "$build_root/work/$name/$version/$arch/$rootfs/run.XXXXXX")
    plugin_stage_dir=$(mktemp -d "$build_root/work/$name/$version/$arch/$rootfs/stage.XXXXXX")
    trap cleanup_work EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp -a "$source_dir/." "$plugin_work_dir/"
    if [[ -n ${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} ]]; then
        build_fixture "$plugin_work_dir" "$plugin_stage_dir"
    else
        build_real "$arch" "$build_root" "$plugin_work_dir" "$plugin_stage_dir" "$platform"
    fi
    stage_prefix="$plugin_stage_dir$prefix"
    [[ -d $stage_prefix ]] || die "LTP install did not create $prefix"
    filter_install "$plugin_work_dir" "$stage_prefix"
    validate_install "$arch" "$stage_prefix"
    mkdir -p "$output$(dirname "$prefix")"
    cp -a "$stage_prefix" "$output$prefix"
    cleanup_work; plugin_work_dir=''; plugin_stage_dir=''; trap - EXIT INT TERM
}

case ${1-} in
describe)
    (($# == 1)) || die 'describe takes no arguments'
    printf '%s\n' 'name=ltp' 'arches=aarch64,riscv64,x86_64,loongarch64' \
        'rootfs=alpine' 'scopes=outer'
    ;;
build) shift; build_plugin "$@" ;;
*) die 'command required: describe or build' ;;
esac
