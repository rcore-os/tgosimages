#!/usr/bin/env bash
set -euo pipefail

name=lmbench
version=5a386c1c32a84898151dade7754031813e33994e
archive_name=lmbench-5a386c1c32a84898151dade7754031813e33994e.tar.gz
default_url=https://github.com/intel/lmbench/archive/5a386c1c32a84898151dade7754031813e33994e.tar.gz
default_sha256=febf1d63221ee6dba60877bce0943ce268231ad9b4d5804b3fdfa614bf5c6459
source_top=lmbench-5a386c1c32a84898151dade7754031813e33994e
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
sanitize_runtime_launcher() {
    local launcher=$1
    sed -i \
        -e 's/ lat_rpc//g' \
        -e '/if \[ .*BENCHMARK_RPC.*\]; then/,/^[[:space:]]*fi[[:space:]]*$/d' \
        -e '/^[[:space:]]*lat_rpc -S /d' \
        -e '/if \[ ! -d \.\.\/\.\.\/src\/webpage-lm \]/,/^[[:space:]]*fi[[:space:]]*$/d' \
        -e '/^[[:space:]]*DOCROOT=.*lmhttp/d' \
        -e '/^[[:space:]]*sleep 2;[[:space:]]*$/d' \
        -e '/if \[ .*BENCHMARK_HTTP.*\]; then/,/^[[:space:]]*fi[[:space:]]*$/d' \
        -e '/^[[:space:]]*lat_http -S /d' \
        -e 's/ lmhttp \.\.\/\.\.\/src\/webpage-lm\.tar//g' \
        -e '/webpage-lm/d' \
        "$launcher"
    if grep -Eq 'lat_rpc|lat_http|lmhttp|webpage-lm' "$launcher"; then
        die 'failed to remove disabled RPC/HTTP launcher orchestration'
    fi
    sh -n "$launcher" || die 'sanitized lmbench launcher is invalid'
}
select_source() {
    local fixture=${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} override_url=${LMBENCH_SOURCE_URL:-}
    local override_sha=${LMBENCH_SOURCE_SHA256:-} sidecar actual
    if [[ -n $fixture ]]; then
        [[ -z $override_url && -z $override_sha ]] || die 'fixture mode cannot be combined with source overrides'
        [[ -d $fixture ]] || die "offline fixture directory does not exist: $fixture"
        source_url="file://$fixture/$archive_name"; sidecar="$fixture/$archive_name.sha256"
        [[ -f $fixture/$archive_name && -f $sidecar ]] || die "incomplete offline fixture for $archive_name"
        mapfile -t fixture_sum <"$sidecar"; ((${#fixture_sum[@]} == 1)) && [[ ${fixture_sum[0]} =~ ^[0-9a-f]{64}$ ]] || die 'invalid fixture checksum sidecar'
        source_sha256=${fixture_sum[0]}
        actual=$(sha256sum "$fixture/$archive_name" | awk '{print $1}'); [[ $actual == "$source_sha256" ]] || die 'offline fixture checksum mismatch'
    elif [[ -n $override_url || -n $override_sha ]]; then
        [[ -n $override_url && -n $override_sha ]] || die 'source URL and checksum overrides must be provided together'; [[ $override_sha =~ ^[0-9a-f]{64}$ ]] || die 'invalid source checksum override'
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
        [[ -d $extract_tmp/$source_top ]] || die "archive lacks $source_top"; cp -a "$extract_tmp/$source_top/." "$candidate/"
        printf '%s\n' "$source_sha256" >"$candidate/.rootfs-test-source-sha256"
        mv -T -- "$candidate" "$source_dir"; candidate=''; rm -rf -- "$extract_tmp"; extract_tmp=''
    fi
    flock -u "$lock_fd"; exec {lock_fd}>&-; printf '%s\n' "$source_dir"; trap - EXIT INT TERM
)
build_plugin() {
    local arch= rootfs= scope= output= build_root source_dir platform uid gid file script script_source builder_image smoke_config found=0
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
    sanitize_runtime_launcher "$plugin_work_dir/scripts/lmbench"
    if [[ -n ${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} ]]; then
        make -C "$plugin_work_dir/src" OS=Linux CC="${CC:-cc}" CFLAGS='-O2 -static' LDFLAGS='-static'
    else
        command -v docker >/dev/null 2>&1 || die 'docker is required for real source builds'; uid=$(id -u); gid=$(id -g)
        patch -d "$plugin_work_dir" -p1 <"$repo_root/patches/rootfs-tests/lmbench/5a386c1c32a84898151dade7754031813e33994e-no-portmapper.patch"
        builder_image=$(ROOTFS_TEST_BUILD_ROOT="$build_root" "$plugin_dir/../alpine-builder.sh" prepare --arch "$arch")
        docker run --rm --platform "$platform" -v "$plugin_work_dir:/work" -w /work "$builder_image" sh -ec \
            "trap 'chown -R $uid:$gid /work' EXIT; make -C src OS=Linux CC=gcc CFLAGS='-O2 -static' LDFLAGS='-static'"
    fi
    mkdir -p "$output/guest-tests/lmbench/bin/Linux" "$output/guest-tests/lmbench/scripts"
    while IFS= read -r -d '' file; do
        if LC_ALL=C readelf -h -- "$file" >/dev/null 2>&1; then
            chmod +x "$file"; validate_static_elf "$arch" "$file"
            install -m 0755 "$file" "$output/guest-tests/lmbench/bin/Linux/$(basename -- "$file")"; found=1
        elif [[ $(basename -- "$file") == lmbench ]]; then
            install -m 0755 "$file" "$output/guest-tests/lmbench/bin/Linux/lmbench"
        fi
    done < <(find "$plugin_work_dir/bin/Linux" -maxdepth 1 -type f -perm /111 -print0)
    ((found)) || die 'lmbench produced no runtime executables'
    for script in lmbench config-run results config os gnu-os info info-template version; do
        script_source="$plugin_work_dir/scripts/$script"
        [[ -f $script_source ]] || die "missing lmbench runtime script: $script"
        install -m 0755 "$script_source" "$output/guest-tests/lmbench/scripts/$script"
    done
    if [[ -z ${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} ]]; then
        smoke_config="$plugin_work_dir/rootfs-test-smoke.conf"
        printf '%s\n' \
            'OUTPUT=/tmp/lmbench-smoke.out' \
            'ENOUGH=1000' 'TIMING_O=0' 'LOOP_O=0' 'LINE_SIZE=64' \
            'FILE=/tmp/lmbench-smoke-file' 'FSDIR=/tmp/lmbench-smoke-fs' \
            'MB=1' 'SYNC_MAX=1' 'SYNC=' 'REMOTE=' 'DISKS=' \
            'BENCHMARK_OS=NO' 'BENCHMARK_HARDWARE=NO' \
            >"$smoke_config"
        docker run --rm --platform "$platform" -v "$output:/overlay:ro" \
            -v "$smoke_config:/work/rootfs-test-smoke.conf:ro" "$builder_image" sh -ec '
                cd /overlay/guest-tests/lmbench/bin/Linux
                test "$(../../scripts/os)" = Linux
                set +e
                timeout 15 ./lmbench /work/rootfs-test-smoke.conf >/tmp/lmbench-smoke.stdout 2>/tmp/lmbench-smoke.stderr
                smoke_status=$?
                set -e
                if [ "$smoke_status" -ne 0 ]; then
                    cat /tmp/lmbench-smoke.stderr >&2
                    exit "$smoke_status"
                fi
                if grep -E "not found|No such file|lat_rpc|lat_http|lmhttp|webpage-lm" /tmp/lmbench-smoke.stderr; then
                    cat /tmp/lmbench-smoke.stderr >&2
                    exit 1
                fi
            '
    fi
    cleanup_work; plugin_work_dir=''; trap - EXIT INT TERM
}
case ${1-} in
describe) (($# == 1)) || die 'describe takes no arguments'; printf '%s\n' 'name=lmbench' 'arches=aarch64,riscv64,x86_64,loongarch64' 'rootfs=busybox,alpine,debian' 'scopes=guest';;
build) shift; build_plugin "$@";;
*) die 'command required: describe or build';;
esac
