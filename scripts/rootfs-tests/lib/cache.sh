#!/usr/bin/env bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)/build-lock.sh"

# The built-in plugin calls this after argument/source selection. Dynamic local
# variables (arch, rootfs, scope, build_root, output) belong to build_plugin.
# Run callbacks unconditionally: a Bash conditional would suppress errexit in
# the build recipe and could publish a partially built overlay.
rootfs_test_get_builder_image() {
    if [[ -n ${rootfs_test_builder_image:-} ]]; then
        printf '%s\n' "$rootfs_test_builder_image"
    else
        ROOTFS_TEST_BUILD_ROOT="$build_root" \
            "${ROOTFS_TEST_ALPINE_BUILDER:-$plugin_dir/../alpine-builder.sh}" prepare --arch "$1"
    fi
}

rootfs_test_artifact_key() (
    set -euo pipefail
    local image_id=$1 file patch_dir="$repo_root/patches/rootfs-tests/$name"
    {
        printf '%s\0' artifact-cache-v1 "$name" "$version" "$source_sha256" \
            "$arch" "$rootfs" "$scope" "$platform" "$image_id" "$(id -u)" "$(id -g)" \
            "${ALPINE_LTP_CFLAGS:-}" "${ALPINE_LTP_LDFLAGS:-}" \
            "${ALPINE_LTP_FILTER_OUT_DIRS:-}" "${ALPINE_LTP_FILTER_OUT_TESTS:-}"
        for file in "$plugin_dir/$name.sh" "$plugin_dir/../lib/common.sh" \
                    "$plugin_dir/../lib/cache.sh" "$plugin_dir/../alpine-builder.sh" \
                    "$plugin_dir/../alpine-builder-packages.txt" "$plugin_dir/../build.sh"; do
            sha256sum -- "$file" || exit 1
        done
        if [[ -d $patch_dir ]]; then
            # Include names and contents; additions/removals also invalidate.
            find "$patch_dir" -type f -print0 | LC_ALL=C sort -z |
                while IFS= read -r -d '' file; do sha256sum -- "$file" || exit 1; done
        fi
    } | sha256sum | awk '{print $1}'
)

rootfs_test_artifact_valid() {
    local entry=$1 expected actual
    [[ -d $entry && ! -L $entry && -f $entry/payload.tar && ! -L $entry/payload.tar &&
       -f $entry/sha256 && ! -L $entry/sha256 ]] || return 1
    expected=$(cat -- "$entry/sha256") || return 1
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum -- "$entry/payload.tar") || return 1
    [[ ${actual%% *} == "$expected" ]]
}

rootfs_test_with_artifact_cache() (
    set -euo pipefail
    local requested_output=$1
    shift
    local rootfs_test_builder_image= image_tag key cache_root entry lock_fd temporary= status
    local output=$requested_output
    case ${ROOTFS_TEST_CACHE:-1} in
        0) "$@"; return ;;
        1) ;;
        *) echo 'rootfs-tests: ROOTFS_TEST_CACHE must be 0 or 1' >&2; return 1 ;;
    esac
    if [[ -n ${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} || -n ${ROOTFS_TEST_ALPINE_BUILDER:-} ]]; then
        "$@"
        return
    fi
    image_tag=$(rootfs_test_get_builder_image "$arch")
    rootfs_test_builder_image=$(docker image inspect --format '{{.Id}}' "$image_tag")
    [[ $rootfs_test_builder_image =~ ^sha256:[0-9a-f]{64}$ ]] || {
        echo 'rootfs-tests: builder image has no immutable Docker image ID' >&2
        return 1
    }
    key=$(rootfs_test_artifact_key "$rootfs_test_builder_image")
    [[ $key =~ ^[0-9a-f]{64}$ ]] || return 1
    cache_root="$build_root/artifacts/$name"
    mkdir -p -- "$cache_root"
    entry="$cache_root/$key"
    trap 'status=$?; [[ -z $temporary ]] || rm -rf -- "$temporary"; build_lock_release_all; exit "$status"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    build_lock_acquire lock_fd "$entry.lock"
    temporary=$(mktemp -d "$cache_root/.stage.XXXXXX")
    output="$temporary/payload"
    mkdir "$output"
    if rootfs_test_artifact_valid "$entry" &&
       tar --extract --file="$entry/payload.tar" --directory="$output" --same-permissions --acls --xattrs; then
        printf 'rootfs-tests: cache hit %s/%s/%s/%s\n' "$name" "$arch" "$rootfs" "$scope" >&2
    else
        if [[ -e $entry || -L $entry ]]; then
            printf 'rootfs-tests: rebuilding invalid artifact %s/%s\n' "$name" "$arch" >&2
            rm -rf -- "$entry"
        fi
        rm -rf -- "$output"
        mkdir "$output"
        printf 'rootfs-tests: cache miss %s/%s/%s/%s\n' "$name" "$arch" "$rootfs" "$scope" >&2
        # Isolate plugin work cleanup traps from this cache transaction.
        ( "$@" )
        status=$?
        ((status == 0)) || return "$status"
        tar --create --format=pax --file="$temporary/payload.tar" --acls --xattrs -C "$output" .
        sha256sum -- "$temporary/payload.tar" | awk '{print $1}' > "$temporary/sha256"
        # Keep the publication directory free of the unarchived build tree.
        cp -a --reflink=auto -- "$output/." "$requested_output/"
        rm -rf -- "$output"
        mv -T -- "$temporary" "$entry"
        temporary=
        return
    fi
    cp -a --reflink=auto -- "$output/." "$requested_output/"
)
