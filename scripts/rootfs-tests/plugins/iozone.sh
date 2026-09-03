#!/usr/bin/env bash
set -euo pipefail

name=iozone
version=3.511
archive_name=iozone3_511.tgz
default_url=https://iozone.org/src/current/iozone3_511.tgz
default_sha256=1aa00bc3cd627ec46ca17aa78c8fabd143d32025155c741f49392b1bdd776298
source_top=iozone3_511
plugin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$plugin_dir/../../.." && pwd)
source "$plugin_dir/../lib/common.sh"
die() { echo "$name: $*" >&2; exit 1; }
plugin_work_dir=''
cleanup_work() { [[ -z $plugin_work_dir ]] || rm -rf -- "$plugin_work_dir"; }
platform_for_arch() { case $1 in aarch64) echo linux/arm64/v8;; riscv64) echo linux/riscv64;; x86_64) echo linux/amd64;; loongarch64) echo linux/loong64;; *) return 1;; esac; }
validate_static_elf() {
    rootfs_test_validate_elf "$1" "$2" || die "invalid ELF for $1: $2"
    ! LC_ALL=C readelf -l -- "$2" | grep -q INTERP || die "ELF has an interpreter: $2"
    ! LC_ALL=C readelf -d -- "$2" | grep -q '(NEEDED)' || die "ELF has shared dependencies: $2"
    [[ -x $2 ]] || die "ELF is not executable: $2"
}
select_source() {
    local fixture=${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} override_url=${IOZONE_SOURCE_URL:-}
    local override_sha=${IOZONE_SOURCE_SHA256:-} sidecar actual
    if [[ -n $fixture ]]; then
        [[ -z $override_url && -z $override_sha ]] || die 'fixture mode cannot be combined with source overrides'
        [[ -d $fixture ]] || die "offline fixture directory does not exist: $fixture"
        source_url="file://$fixture/$archive_name"; sidecar="$fixture/$archive_name.sha256"
        [[ -f $fixture/$archive_name && -f $sidecar ]] || die "incomplete offline fixture for $archive_name"
        mapfile -t fixture_sum <"$sidecar"
        ((${#fixture_sum[@]} == 1)) && [[ ${fixture_sum[0]} =~ ^[0-9a-f]{64}$ ]] || die 'invalid fixture checksum sidecar'
        source_sha256=${fixture_sum[0]}
        actual=$(sha256sum "$fixture/$archive_name" | awk '{print $1}'); [[ $actual == "$source_sha256" ]] || die 'offline fixture checksum mismatch'
    elif [[ -n $override_url || -n $override_sha ]]; then
        [[ -n $override_url && -n $override_sha ]] || die 'source URL and checksum overrides must be provided together'
        [[ $override_sha =~ ^[0-9a-f]{64}$ ]] || die 'invalid source checksum override'
        source_url=$override_url; source_sha256=$override_sha
    else source_url=$default_url; source_sha256=$default_sha256; fi
}
prepare_source() (
    local build_root=$1 archive source_dir lock_fd actual extract_tmp='' candidate=''
    cleanup_source() { local cleanup_status=$?; trap - EXIT INT TERM; [[ -z $extract_tmp ]] || rm -rf -- "$extract_tmp"; [[ -z $candidate ]] || rm -rf -- "$candidate"; exit "$cleanup_status"; }
    trap cleanup_source EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
    archive="$build_root/downloads/$name-$version-$source_sha256.tar"; source_dir="$build_root/sources/$name-$version-$source_sha256"
    mkdir -p "$build_root/downloads" "$build_root/sources"; exec {lock_fd}>"$source_dir.lock"; flock -x "$lock_fd"
    if [[ -d $source_dir ]]; then
        [[ -f $source_dir/.rootfs-test-source-sha256 ]] || die "cached source lacks checksum provenance: $source_dir"
        read -r actual <"$source_dir/.rootfs-test-source-sha256"; [[ $actual == "$source_sha256" ]] || die "cached source checksum provenance mismatch: $source_dir"
    else
        if [[ -f $archive ]]; then actual=$(sha256sum "$archive" | awk '{print $1}'); [[ $actual == "$source_sha256" ]] || die "cached archive checksum mismatch: $archive"
        else rootfs_test_download_checked "$source_url" "$source_sha256" "$archive" || die 'checked source download failed'; fi
        extract_tmp=$(mktemp -d "$build_root/sources/.extract-$name-$version.XXXXXX"); candidate=$(mktemp -d "$build_root/sources/.$name-$version.XXXXXX")
        tar -xf "$archive" -C "$extract_tmp" || die 'source extraction failed'
        [[ -d $extract_tmp/$source_top/src/current ]] || die "archive lacks $source_top/src/current"
        cp -a "$extract_tmp/$source_top/src/current/." "$candidate/"; printf '%s\n' "$source_sha256" >"$candidate/.rootfs-test-source-sha256"
        mv -T -- "$candidate" "$source_dir"; candidate=''
        rm -rf -- "$extract_tmp"; extract_tmp=''
    fi
    flock -u "$lock_fd"; exec {lock_fd}>&-; printf '%s\n' "$source_dir"; trap - EXIT INT TERM
)
build_plugin() {
    local arch= rootfs= scope= output= build_root source_dir platform uid gid builder_image
    while (($#)); do case $1 in
        --arch) (($# >= 2)) || die 'missing --arch value'; arch=$2; shift 2;;
        --rootfs) (($# >= 2)) || die 'missing --rootfs value'; rootfs=$2; shift 2;;
        --scope) (($# >= 2)) || die 'missing --scope value'; scope=$2; shift 2;;
        --output) (($# >= 2)) || die 'missing --output value'; output=$2; shift 2;;
        *) die "unknown argument: $1";; esac; done
    [[ -n $arch && -n $rootfs && -n $scope && -n $output ]] || die 'arch, rootfs, scope, and output are required'
    platform=$(platform_for_arch "$arch") || die "unsupported arch: $arch"; case $rootfs in busybox|alpine|debian);; *) die "unsupported rootfs: $rootfs";; esac
    [[ $scope == guest ]] || die "unsupported scope: $scope"; [[ -d $output && -z $(find "$output" -mindepth 1 -print -quit) ]] || die 'output must be an empty directory'
    select_source; build_root=${ROOTFS_TEST_BUILD_ROOT:-"$repo_root/build/rootfs-tests"}; source_dir=$(prepare_source "$build_root")
    mkdir -p "$build_root/work/$name/$version/$arch/$rootfs"; plugin_work_dir=$(mktemp -d "$build_root/work/$name/$version/$arch/$rootfs/run.XXXXXX")
    trap cleanup_work EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; cp -a "$source_dir/." "$plugin_work_dir/"
    if [[ -n ${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} ]]; then
        make -C "$plugin_work_dir" linux CC="${CC:-cc}" CFLAGS='-O2 -static' LDFLAGS='-static'
    else
        command -v docker >/dev/null 2>&1 || die 'docker is required for real source builds'; uid=$(id -u); gid=$(id -g)
        builder_image=$(ROOTFS_TEST_BUILD_ROOT="$build_root" "$plugin_dir/../alpine-builder.sh" prepare --arch "$arch")
        docker run --rm --platform "$platform" -v "$plugin_work_dir:/work" -w /work "$builder_image" sh -ec \
            "trap 'chown -R $uid:$gid /work' EXIT; make linux CC=gcc CFLAGS='-O2 -static' LDFLAGS='-static'"
    fi
    chmod +x "$plugin_work_dir/iozone"; validate_static_elf "$arch" "$plugin_work_dir/iozone"
    mkdir -p "$output/guest-tests/iozone"; install -m 0755 "$plugin_work_dir/iozone" "$output/guest-tests/iozone/iozone"
    cleanup_work; plugin_work_dir=''; trap - EXIT INT TERM
}
case ${1-} in
describe) (($# == 1)) || die 'describe takes no arguments'; printf '%s\n' 'name=iozone' 'arches=aarch64,riscv64,x86_64,loongarch64' 'rootfs=busybox,alpine,debian' 'scopes=guest';;
build) shift; build_plugin "$@";;
*) die 'command required: describe or build';;
esac
