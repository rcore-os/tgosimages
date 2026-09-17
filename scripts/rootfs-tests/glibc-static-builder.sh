#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

suite=ubuntu-24.04
platform=linux/amd64
base_image=ubuntu@sha256:69cecf4bbf72d2d44a9eef1b71fb98c7fb973d78af11399deccef19beb008ad9
manifest_file="$script_dir/glibc-static-builder-packages.txt"

die() { echo "glibc-static-builder: $*" >&2; exit 1; }

set_builder_metadata() {
    case $1 in x86_64|aarch64|riscv64|loongarch64) ;; *) die "unsupported architecture: $1" ;; esac
    manifest_sha=$(sha256sum "$manifest_file" | awk '{print $1}')
    builder_image="tgos/rootfs-tests-glibc-static-builder:$suite-${manifest_sha:0:16}"
}

describe_builder() {
    local arch=$1
    set_builder_metadata "$arch"
    printf '%s\n' "suite=$suite" "platform=$platform" "base_image=$base_image" \
        "package_manifest_sha256=$manifest_sha" "builder_image=$builder_image"
}

image_has_label() {
    local image=$1 label=$2 expected=$3 actual
    actual=$(docker image inspect --format "{{ index .Config.Labels \"$label\" }}" "$image" 2>/dev/null) || return 1
    [[ $actual == "$expected" ]]
}

prepare_builder() (
    local arch=$1 build_root lock_fd context='' package_specs
    cleanup_context() {
        local cleanup_status=$?
        trap - EXIT INT TERM
        [[ -z $context ]] || rm -rf -- "$context"
        build_lock_release_all || true
        exit "$cleanup_status"
    }
    trap cleanup_context EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    command -v docker >/dev/null 2>&1 || die 'docker is required'
    set_builder_metadata "$arch"
    build_root=${ROOTFS_TEST_BUILD_ROOT:-"$repo_root/build/rootfs-tests"}
    mkdir -p "$build_root/builders/work"
    build_lock_acquire lock_fd "$build_root/builders/glibc-static-$manifest_sha.lock"
    if ! image_has_label "$builder_image" org.tgos.rootfs-tests.package-manifest-sha256 "$manifest_sha" ||
       ! image_has_label "$builder_image" org.tgos.rootfs-tests.base-image "$base_image"; then
        context=$(mktemp -d "$build_root/builders/work/glibc-static.XXXXXX")
        package_specs=$(tr '\n' ' ' <"$manifest_file")
        cat >"$context/Dockerfile" <<EOF
FROM $base_image
RUN export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends $package_specs; rm -rf /var/lib/apt/lists/*
LABEL org.tgos.rootfs-tests.base-image="$base_image"
LABEL org.tgos.rootfs-tests.package-manifest-sha256="$manifest_sha"
EOF
        docker build --platform "$platform" -t "$builder_image" "$context" >&2
        rm -rf -- "$context"; context=''
    fi
    printf '%s\n' "$builder_image"
    build_lock_release "$lock_fd"
    trap - EXIT INT TERM
)

(($#)) || die 'command required: describe or prepare'
command=$1; shift
arch=
while (($#)); do
    case $1 in
    --arch) (($# >= 2)) || die 'missing --arch value'; arch=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
    esac
done
[[ -n $arch ]] || die 'arch is required'
case $command in
describe) describe_builder "$arch" ;;
prepare) prepare_builder "$arch" ;;
*) die "unknown command: $command" ;;
esac
