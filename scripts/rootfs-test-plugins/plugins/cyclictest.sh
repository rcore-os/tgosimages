#!/usr/bin/env bash
set -euo pipefail

name=cyclictest
version=2.11
archive_name=rt-tests-2.11.tar.xz
default_url=https://www.kernel.org/pub/linux/utils/rt-tests/rt-tests-2.11.tar.xz
default_sha256=c01ce99d4b86a99ef83fb75ddc97ddd7669eb85996a2c35bc9ad9e83ecad47bc
source_top=rt-tests-2.11
numactl_version=2.0.16
numactl_archive_name=numactl-2.0.16.tar.gz
numactl_url=https://github.com/numactl/numactl/archive/refs/tags/v2.0.16.tar.gz
numactl_sha256=a35c3bdb3efab5c65927e0de5703227760b1101f5e27ab741d8f32b3d5f0a44c
numactl_source_top=numactl-2.0.16

plugin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$plugin_dir/../../.." && pwd)
# shellcheck source=../lib/common.sh
source "$plugin_dir/../lib/common.sh"

die() { error "$name: $*"; exit 1; }
plugin_work_dir=''
numactl_work_dir=''
cleanup_work() {
    [[ -z $plugin_work_dir ]] || rm -rf -- "$plugin_work_dir"
    [[ -z $numactl_work_dir ]] || rm -rf -- "$numactl_work_dir"
}

toolchain_for_arch() {
    case $1 in
    x86_64) target_triplet=x86_64-linux-gnu; target_cc=x86_64-linux-gnu-gcc; target_ar=x86_64-linux-gnu-ar ;;
    aarch64) target_triplet=aarch64-linux-gnu; target_cc=aarch64-linux-gnu-gcc; target_ar=aarch64-linux-gnu-ar ;;
    riscv64) target_triplet=riscv64-linux-gnu; target_cc=riscv64-linux-gnu-gcc; target_ar=riscv64-linux-gnu-ar ;;
    loongarch64) target_triplet=loongarch64-linux-gnu; target_cc=loongarch64-linux-gnu-gcc-14; target_ar=loongarch64-linux-gnu-ar ;;
    *) return 1 ;;
    esac
}

validate_static_elf() {
    rootfs_test_validate_elf "$1" "$2" || die "invalid ELF for $1: $2"
    ! LC_ALL=C readelf -l -- "$2" | grep -q INTERP || die "ELF has an interpreter: $2"
    ! LC_ALL=C readelf -d -- "$2" | grep -q '(NEEDED)' || die "ELF has shared dependencies: $2"
    [[ -x $2 ]] || die "ELF is not executable: $2"
}

select_source() {
    local fixture=${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} override_url=${CYCLICTEST_SOURCE_URL:-}
    local override_sha=${CYCLICTEST_SOURCE_SHA256:-} sidecar actual
    if [[ -n $fixture ]]; then
        [[ -z $override_url && -z $override_sha ]] || die 'fixture mode cannot be combined with source overrides'
        [[ -d $fixture ]] || die "offline fixture directory does not exist: $fixture"
        source_url="file://$fixture/$archive_name"
        sidecar="$fixture/$archive_name.sha256"
        [[ -f $fixture/$archive_name && -f $sidecar ]] || die "incomplete offline fixture for $archive_name"
        mapfile -t fixture_sum <"$sidecar"
        ((${#fixture_sum[@]} == 1)) && [[ ${fixture_sum[0]} =~ ^[0-9a-f]{64}$ ]] || die 'invalid fixture checksum sidecar'
        source_sha256=${fixture_sum[0]}
        actual=$(sha256sum "$fixture/$archive_name" | awk '{print $1}')
        [[ $actual == "$source_sha256" ]] || die 'offline fixture checksum mismatch'
    elif [[ -n $override_url || -n $override_sha ]]; then
        [[ -n $override_url && -n $override_sha ]] || die 'source URL and checksum overrides must be provided together'
        [[ $override_sha =~ ^[0-9a-f]{64}$ ]] || die 'invalid source checksum override'
        source_url=$override_url
        source_sha256=$override_sha
    else
        source_url=$default_url
        source_sha256=$default_sha256
    fi
}

prepare_source() (
    local build_root=$1 archive source_dir lock_fd actual extract_tmp='' candidate=''
    cleanup_source() {
        local cleanup_status=$?
        trap - EXIT INT TERM
        [[ -z $extract_tmp ]] || rm -rf -- "$extract_tmp"
        [[ -z $candidate ]] || rm -rf -- "$candidate"
        build_lock_release_all || true
        exit "$cleanup_status"
    }
    trap cleanup_source EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    archive="$build_root/downloads/$name-$version-$source_sha256.tar"
    source_dir="$build_root/sources/$name-$version-$source_sha256"
    mkdir -p "$build_root/downloads" "$build_root/sources"
    build_lock_acquire lock_fd "$source_dir.lock"
    if [[ -d $source_dir ]]; then
        [[ -f $source_dir/.rootfs-test-source-sha256 ]] || die "cached source lacks checksum provenance: $source_dir"
        read -r actual <"$source_dir/.rootfs-test-source-sha256"
        [[ $actual == "$source_sha256" ]] || die "cached source checksum provenance mismatch: $source_dir"
    else
        if [[ -f $archive ]]; then
            actual=$(sha256sum "$archive" | awk '{print $1}')
            [[ $actual == "$source_sha256" ]] || die "cached archive checksum mismatch: $archive"
        else
            rootfs_test_download_checked "$source_url" "$source_sha256" "$archive" || die 'checked source download failed'
        fi
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
    build_lock_release "$lock_fd"
    printf '%s\n' "$source_dir"
    trap - EXIT INT TERM
)

prepare_numactl_source() (
    local build_root=$1 archive source_dir lock_fd actual extract_tmp='' candidate=''
    cleanup_source() {
        local cleanup_status=$?
        trap - EXIT INT TERM
        [[ -z $extract_tmp ]] || rm -rf -- "$extract_tmp"
        [[ -z $candidate ]] || rm -rf -- "$candidate"
        build_lock_release_all || true
        exit "$cleanup_status"
    }
    trap cleanup_source EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    archive="$build_root/downloads/numactl-$numactl_version-$numactl_sha256.tar.gz"
    source_dir="$build_root/sources/numactl-$numactl_version-$numactl_sha256"
    mkdir -p "$build_root/downloads" "$build_root/sources"
    build_lock_acquire lock_fd "$source_dir.lock"
    if [[ -d $source_dir ]]; then
        [[ -f $source_dir/.rootfs-test-source-sha256 ]] || die "cached numactl source lacks checksum provenance: $source_dir"
        read -r actual <"$source_dir/.rootfs-test-source-sha256"
        [[ $actual == "$numactl_sha256" ]] || die "cached numactl source checksum provenance mismatch: $source_dir"
    else
        if [[ -f $archive ]]; then
            actual=$(sha256sum "$archive" | awk '{print $1}')
            [[ $actual == "$numactl_sha256" ]] || die "cached numactl archive checksum mismatch: $archive"
        else
            rootfs_test_download_checked "$numactl_url" "$numactl_sha256" "$archive" ||
                die 'checked numactl source download failed'
        fi
        extract_tmp=$(mktemp -d "$build_root/sources/.extract-numactl-$numactl_version.XXXXXX")
        candidate=$(mktemp -d "$build_root/sources/.numactl-$numactl_version.XXXXXX")
        tar -xf "$archive" -C "$extract_tmp" || die 'numactl source extraction failed'
        [[ -d $extract_tmp/$numactl_source_top ]] || die "numactl archive lacks $numactl_source_top"
        cp -a "$extract_tmp/$numactl_source_top/." "$candidate/"
        printf '%s\n' "$numactl_sha256" >"$candidate/.rootfs-test-source-sha256"
        mv -T -- "$candidate" "$source_dir"
        candidate=''
        rm -rf -- "$extract_tmp"
        extract_tmp=''
    fi
    build_lock_release "$lock_fd"
    printf '%s\n' "$source_dir"
    trap - EXIT INT TERM
)

build_plugin() {
    local arch= rootfs= scope= output= build_root source_dir numactl_source_dir uid gid
    local builder_image builder_script target_triplet target_cc target_ar jobs
    while (($#)); do
        case $1 in
        --arch) (($# >= 2)) || die 'missing --arch value'; arch=$2; shift 2 ;;
        --rootfs) (($# >= 2)) || die 'missing --rootfs value'; rootfs=$2; shift 2 ;;
        --scope) (($# >= 2)) || die 'missing --scope value'; scope=$2; shift 2 ;;
        --output) (($# >= 2)) || die 'missing --output value'; output=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
        esac
    done
    [[ -n $arch && -n $rootfs && -n $scope && -n $output ]] || die 'arch, rootfs, scope, and output are required'
    toolchain_for_arch "$arch" || die "unsupported arch: $arch"
    case $rootfs in busybox|alpine|debian|orangepi-jammy) ;; *) die "unsupported rootfs: $rootfs" ;; esac
    [[ $scope == guest ]] || die "unsupported scope: $scope"
    [[ -d $output && -z $(find "$output" -mindepth 1 -print -quit) ]] || die 'output must be an empty directory'

    select_source
    build_root=${ROOTFS_TEST_BUILD_ROOT:-"$repo_root/build/rootfs-tests"}
    source_dir=$(prepare_source "$build_root")
    mkdir -p "$build_root/work/$name/$version/$arch/$rootfs"
    plugin_work_dir=$(mktemp -d "$build_root/work/$name/$version/$arch/$rootfs/run.XXXXXX")
    trap cleanup_work EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp -a "$source_dir/." "$plugin_work_dir/"
    if [[ -n ${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} ]]; then
        make -C "$plugin_work_dir" cyclictest no_libcpupower=1 CC="${CC:-cc}" \
            CFLAGS='-O2 -static' LDFLAGS='-static'
    else
        command -v docker >/dev/null 2>&1 || die 'docker is required for real source builds'
        numactl_source_dir=$(prepare_numactl_source "$build_root")
        numactl_work_dir=$(mktemp -d "$build_root/work/$name/$version/$arch/$rootfs/numactl.XXXXXX")
        cp -a "$numactl_source_dir/." "$numactl_work_dir/"
        builder_script=${ROOTFS_TEST_GLIBC_STATIC_BUILDER:-"$plugin_dir/../glibc-static-builder.sh"}
        builder_image=$(ROOTFS_TEST_BUILD_ROOT="$build_root" "$builder_script" prepare --arch "$arch")
        uid=$(id -u); gid=$(id -g)
        jobs=$(TGOS_BUILD_JOB_BUDGET="${ROOTFS_TEST_BUILD_JOBS:-${TGOS_BUILD_JOB_BUDGET:-}}" build_jobs) || return
        docker run --rm --platform linux/amd64 \
            -e TARGET_TRIPLET="$target_triplet" -e TARGET_CC="$target_cc" -e TARGET_AR="$target_ar" \
            -e TGOS_BUILD_JOB_BUDGET="$jobs" -e HOST_UID="$uid" -e HOST_GID="$gid" \
            -v "$plugin_work_dir:/work" -v "$numactl_work_dir:/numactl" \
            "$builder_image" bash -ec '
                trap '\''chown -R "$HOST_UID:$HOST_GID" /work /numactl'\'' EXIT
                cd /numactl
                ./autogen.sh
                ./configure --host="$TARGET_TRIPLET" --disable-shared --enable-static CC="$TARGET_CC" \
                    CFLAGS="-O2 -ffunction-sections -fdata-sections"
                make -j"$TGOS_BUILD_JOB_BUDGET" libnuma.la
                cd /work
                make -j"$TGOS_BUILD_JOB_BUDGET" cyclictest no_libcpupower=1 PYLIB=/usr/lib \
                    CC="$TARGET_CC" AR="$TARGET_AR" \
                    CFLAGS="-O2 -static -ffunction-sections -fdata-sections -I/numactl" \
                    LDFLAGS="-static -Wl,--gc-sections -L/numactl/.libs"
            '
    fi
    chmod +x "$plugin_work_dir/cyclictest"
    validate_static_elf "$arch" "$plugin_work_dir/cyclictest"
    if [[ -z ${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} ]]; then
        "$plugin_dir/../validate-cyclictest.sh" "$arch" "$plugin_work_dir/cyclictest" ||
            die 'scheduler syscall validation failed'
    fi
    mkdir -p "$output/guest-tests/cyclictest"
    install -m 0755 "$plugin_work_dir/cyclictest" "$output/guest-tests/cyclictest/cyclictest"
    cleanup_work; plugin_work_dir=''; numactl_work_dir=''; trap - EXIT INT TERM
}

case ${1-} in
describe)
    (($# == 1)) || die 'describe takes no arguments'
    printf '%s\n' 'name=cyclictest' 'arches=aarch64,riscv64,x86_64,loongarch64' \
        'rootfs=busybox,alpine,debian,orangepi-jammy' 'scopes=guest'
    ;;
build) shift; build_plugin "$@" ;;
*) die 'command required: describe or build' ;;
esac
