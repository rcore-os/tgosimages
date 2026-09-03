#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

version=3.23.5
release_series=v3.23
mirror=https://dl-cdn.alpinelinux.org/alpine
package_set=build-base-0.5-r3_linux-headers-6.16.12-r0_numactl-dev-2.0.18-r0_python3-3.12.14-r0
packages=(build-base=0.5-r3 linux-headers=6.16.12-r0 numactl-dev=2.0.18-r0 python3=3.12.14-r0)
# Alpine's release repositories are not immutable snapshots. Pin the requested
# packages and compare the complete resolved manifest so any repository drift
# fails the image build instead of silently changing the toolchain.
manifest_file="$script_dir/alpine-builder-packages.txt"

die() { echo "alpine-builder: $*" >&2; exit 1; }

metadata_for_arch() {
    case $1 in
    aarch64)
        archive=alpine-minirootfs-3.23.5-aarch64.tar.gz
        sha256=d9a77cb31f715c56afa4f0a5aa42c04cfde813b70ad74a64725902b09c29a6cc
        platform=linux/arm64/v8
        ;;
    riscv64)
        archive=alpine-minirootfs-3.23.5-riscv64.tar.gz
        sha256=51019c39af89029a8bc19255738d370bc3b222830dbb78129b02721ac6b5933d
        platform=linux/riscv64
        ;;
    x86_64)
        archive=alpine-minirootfs-3.23.5-x86_64.tar.gz
        sha256=fae0d78ad39563573ddececfdd55ae1040ed428442e95ea5401cf66d9079b327
        platform=linux/amd64
        ;;
    loongarch64)
        archive=alpine-minirootfs-3.23.5-loongarch64.tar.gz
        sha256=92185135af8b8694f9732c4cdc0dae7f26f72059fd79e9bef6d5dbafd05898ea
        platform=linux/loong64
        ;;
    *) die "unsupported arch: $1" ;;
    esac
    url="$mirror/$release_series/releases/$1/$archive"
    archive_cache="${archive%.tar.gz}-$sha256.tar.gz"
}

set_image_names() {
    local arch=$1 manifest_sha
    manifest_sha=$(sha256sum "$manifest_file" | awk '{print $1}')
    base_image="tgos/rootfs-tests-alpine-base:$version-$arch-${sha256:0:16}"
    builder_image="tgos/rootfs-tests-alpine-builder:$version-$arch-${sha256:0:16}-${manifest_sha:0:16}"
}

describe_builder() {
    local arch=$1
    metadata_for_arch "$arch"
    set_image_names "$arch"
    printf '%s\n' "version=$version" "archive=$archive" "sha256=$sha256" \
        "archive_cache=$archive_cache" "platform=$platform" "package_set=$package_set" "base_image=$base_image" \
        "builder_image=$builder_image"
}

image_has_label() {
    local image=$1 label=$2 expected=$3 actual
    actual=$(docker image inspect --format "{{ index .Config.Labels \"$label\" }}" "$image" 2>/dev/null) || return 1
    [[ $actual == "$expected" ]]
}

prepare_builder() (
    local arch=$1 base_only=$2 build_root archive_path lock_fd actual context='' manifest_sha
    cleanup_context() {
        local cleanup_status=$?
        trap - EXIT INT TERM
        [[ -z $context ]] || rm -rf -- "$context"
        exit "$cleanup_status"
    }
    trap cleanup_context EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    command -v docker >/dev/null 2>&1 || die 'docker is required'
    metadata_for_arch "$arch"
    set_image_names "$arch"
    manifest_sha=$(sha256sum "$manifest_file" | awk '{print $1}')
    build_root=${ROOTFS_TEST_BUILD_ROOT:-"$repo_root/build/rootfs-tests"}
    mkdir -p "$build_root/builders/downloads" "$build_root/builders/locks" "$build_root/builders/work"
    archive_path="$build_root/builders/downloads/$archive_cache"
    exec {lock_fd}>"$build_root/builders/locks/minirootfs-$sha256.lock"
    flock -x "$lock_fd"
    if [[ -f $archive_path ]]; then
        actual=$(sha256sum "$archive_path" | awk '{print $1}')
        [[ $actual == "$sha256" ]] || die "cached minirootfs checksum mismatch: $archive_path"
    else
        rootfs_test_download_checked "$url" "$sha256" "$archive_path" || die 'checked minirootfs download failed'
    fi
    flock -u "$lock_fd"; exec {lock_fd}>&-

    exec {lock_fd}>"$build_root/builders/locks/image-$arch-$sha256-$manifest_sha.lock"
    flock -x "$lock_fd"
    if ! image_has_label "$base_image" org.tgos.rootfs-tests.minirootfs-sha256 "$sha256"; then
        context=$(mktemp -d "$build_root/builders/work/base-$arch.XXXXXX")
        cp "$archive_path" "$context/$archive"
        printf '%s\n' 'FROM scratch' "ADD $archive /" \
            "LABEL org.tgos.rootfs-tests.minirootfs-sha256=$sha256" \
            "LABEL org.tgos.rootfs-tests.arch=$arch" >"$context/Dockerfile"
        docker build --platform "$platform" -t "$base_image" "$context" >&2
        rm -rf -- "$context"; context=''
    fi
    if [[ $base_only == 1 ]]; then
        printf '%s\n' "$base_image"
        flock -u "$lock_fd"; exec {lock_fd}>&-; trap - EXIT INT TERM
        exit 0
    fi
    if ! image_has_label "$builder_image" org.tgos.rootfs-tests.package-manifest-sha256 "$manifest_sha" ||
       ! image_has_label "$builder_image" org.tgos.rootfs-tests.minirootfs-sha256 "$sha256"; then
        context=$(mktemp -d "$build_root/builders/work/builder-$arch.XXXXXX")
        cp "$manifest_file" "$context/expected-packages.txt"
        printf '%s\n' "FROM $base_image" \
            'COPY expected-packages.txt /tmp/expected-packages.txt' \
            "RUN apk add --no-cache ${packages[*]} && apk info -v | LC_ALL=C sort > /tmp/actual-packages.txt && diff -u /tmp/expected-packages.txt /tmp/actual-packages.txt && mkdir -p /usr/share/rootfs-tests && mv /tmp/actual-packages.txt /usr/share/rootfs-tests/alpine-builder-packages.txt && rm /tmp/expected-packages.txt" \
            "LABEL org.tgos.rootfs-tests.minirootfs-sha256=$sha256" \
            "LABEL org.tgos.rootfs-tests.package-manifest-sha256=$manifest_sha" \
            "LABEL org.tgos.rootfs-tests.package-set=$package_set" >"$context/Dockerfile"
        docker build --platform "$platform" -t "$builder_image" "$context" >&2
        rm -rf -- "$context"; context=''
    fi
    printf '%s\n' "$builder_image"
    flock -u "$lock_fd"; exec {lock_fd}>&-; trap - EXIT INT TERM
)

(($#)) || die 'command required: describe or prepare'
command=$1; shift
arch=; base_only=0
while (($#)); do
    case $1 in
    --arch) (($# >= 2)) || die 'missing --arch value'; arch=$2; shift 2 ;;
    --base-only) base_only=1; shift ;;
    *) die "unknown argument: $1" ;;
    esac
done
[[ -n $arch ]] || die 'arch is required'
case $command in
describe) ((base_only == 0)) || die 'describe does not accept --base-only'; describe_builder "$arch" ;;
prepare) prepare_builder "$arch" "$base_only" ;;
*) die "unknown command: $command" ;;
esac
