#!/usr/bin/env bash
set -euo pipefail
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
work=$(mktemp -d /tmp/debian-base-cache.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
export LOG_CREATE_DEFAULT_FILE=0
source "$repo_root/scripts/rootfs/debian.sh"
BUILD_DIR=$work/build
DEBIAN_ARCH=x86_64 DEBIAN_DPKG_ARCH=amd64 DEBIAN_DOCKER_PLATFORM=linux/amd64
DEBIAN_DOCKER_IMAGE=debian:trixie DEBIAN_IMG_SIZE=12M
real_create_base=$(declare -f debian_create_base)
fixture_id=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# A multi-platform image store may keep the tag ambiguous after a platform pull.
# New Docker versions can inspect the selected platform directly.
(
    DEBIAN_DOCKER_PLATFORM=linux/arm64
    selected_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    wrong_id=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    docker() {
        local reference=${@: -1}
        case "$1 $2" in
            'image inspect')
                if [[ " $* " == *' --platform linux/arm64 '* ]]; then
                    printf '%s\n' "$selected_id linux/arm64"
                else
                    printf '%s\n' "$wrong_id linux/amd64"
                fi
                ;;
            'create --platform') return 91 ;;
            'pull --platform') : ;;
            *) return 90 ;;
        esac
    }
    debian_resolve_docker_image
    [[ $DEBIAN_DOCKER_IMAGE_ID == "$selected_id" ]]
    [[ ! -e $work/platform-events ]]
)
echo 'ok - ambiguous multi-platform tags use platform-aware image inspection'

# Docker before API 1.49 has no platform-aware image inspect. Keep the
# temporary-container resolver only as a compatibility fallback.
(
    DEBIAN_DOCKER_PLATFORM=linux/arm64
    selected_id=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    wrong_id=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    docker() {
        local reference=${@: -1}
        case "$1 $2" in
            'image inspect')
                if [[ $reference == "$selected_id" ]]; then
                    printf '%s\n' "$selected_id linux/arm64"
                elif [[ " $* " == *' --platform linux/arm64 '* ]]; then
                    return 92
                else
                    printf '%s\n' "$wrong_id linux/amd64"
                fi
                ;;
            'create --platform') printf '%s\n' platform-container ;;
            'container inspect') printf '%s\n' "$selected_id" ;;
            'container rm') printf '%s\n' removed >>"$work/platform-events" ;;
            'pull --platform') : ;;
            *) return 90 ;;
        esac
    }
    debian_resolve_docker_image
    [[ $DEBIAN_DOCKER_IMAGE_ID == "$selected_id" ]]
    [[ $(cat "$work/platform-events") == removed ]]
)
echo 'ok - old Docker falls back to temporary-container platform resolution'

# Docker cannot run in this unit test; preserve real ext4 validation/copying.
docker() {
    case "$1 $2" in
        'image inspect') printf '%s\n' "$fixture_id $DEBIAN_DOCKER_PLATFORM" ;;
        'pull --platform') : ;;
        *) return 90 ;;
    esac
}
debian_create_base() {
    printf 'build\n' >>"$work/builds"
    [[ ${FAIL_BUILD:-0} != 1 ]] || return 28
    truncate -s "$DEBIAN_IMG_SIZE" "$1"
    mkfs.ext4 -q -F "$1"
}
[[ $(type -t debian_acquire_base || true) == function ]] || { echo 'FAIL: Debian base cache acquisition is missing' >&2; exit 1; }
acquire() { debian_resolve_docker_image; debian_acquire_base "$work/$1.img"; }
acquire first
acquire second
[[ -z $(find "$BUILD_DIR" -name '*.lock' -print -quit) ]] || {
    echo 'FAIL: completed Debian builds leave lock files behind' >&2
    exit 1
}
[[ $(wc -l <"$work/builds") == 1 ]]
cmp "$work/first.img" "$work/second.img"
printf 'composition' | dd of="$work/second.img" conv=notrunc status=none
acquire third
cmp "$work/first.img" "$work/third.img"
DEBIAN_GUEST_TESTS=none DEBIAN_OUTER_FREE_SIZE=512M
acquire options
[[ $(wc -l <"$work/builds") == 1 ]]
cache_image=$(find "$BUILD_DIR/debian/base-cache" -name base.img)
printf corruption | dd of="$cache_image" conv=notrunc status=none
acquire repaired
[[ $(wc -l <"$work/builds") == 2 ]]
DEBIAN_BASE_CACHE_REFRESH=1 acquire refreshed
[[ $(wc -l <"$work/builds") == 3 ]]
DEBIAN_BASE_CACHE=0 acquire bypass
[[ $(wc -l <"$work/builds") == 4 ]]
DEBIAN_PASSWORD=changed acquire password
[[ $(wc -l <"$work/builds") == 5 ]]
fixture_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
acquire imageid
[[ $(wc -l <"$work/builds") == 6 ]]
DEBIAN_SUITE=failed
if (FAIL_BUILD=1 acquire failed); then echo 'FAIL: build failure ignored'; exit 1; fi
[[ ! -e $work/failed.img ]]
[[ $(find "$BUILD_DIR/debian/base-cache" -name base.img | wc -l) == 3 ]]
[[ $(find "$BUILD_DIR/debian/base-cache" -name '.stage.*' | wc -l) == 0 ]]
echo 'ok - clean base cache reuse, isolation, corruption, refresh, bypass, keys and failed publication'

# Every base input changes identity; composition-only inputs were checked above.
original_key=$(debian_base_cache_key)
for variable in DEBIAN_ARCH DEBIAN_DPKG_ARCH DEBIAN_DOCKER_PLATFORM DEBIAN_SUITE DEBIAN_MIRROR DEBIAN_IMG_SIZE DEBIAN_PASSWORD DEBIAN_DOCKER_IMAGE_ID; do
    changed_key=$(declare "$variable=changed-value"; debian_base_cache_key)
    [[ $changed_key != "$original_key" ]]
done
changed_key=$(DEBIAN_DEFAULT_PACKAGES+=(extra-package); debian_base_cache_key)
[[ $changed_key != "$original_key" ]]
echo 'ok - each base input and package selection changes cache identity'

# Concurrent misses share the per-key lock and produce one base.
DEBIAN_SUITE=concurrent
before=$(wc -l <"$work/builds")
acquire concurrent1 & first_pid=$!
acquire concurrent2 & second_pid=$!
wait "$first_pid"
wait "$second_pid"
[[ $(wc -l <"$work/builds") == $((before + 1)) ]]
# Even a matching checksum must not make malformed ext4 acceptable.
entry="$BUILD_DIR/debian/base-cache/$(debian_base_cache_key)"
printf invalid >"$entry/base.img"
sha256sum "$entry/base.img" | cut -d ' ' -f 1 >"$entry/sha256"
acquire malformed
[[ $(wc -l <"$work/builds") == $((before + 2)) ]]
echo 'ok - concurrent misses serialize and matching checksums still require ext4 sanity'
# Refresh publication failure must retain the old cache, including metadata.
entry="$BUILD_DIR/debian/base-cache/$(debian_base_cache_key)"
touch -d @1000000000 "$entry/base.img"
chmod 640 "$entry/base.img"
acquire metadata
[[ $(stat -c '%a:%Y' "$work/metadata.img") == 640:1000000000 ]]
old_sum=$(sha256sum "$entry/base.img")
mv() {
    if [[ $* == *'.stage.'* && $* != *'.backup.'* ]]; then return 39; fi
    command mv "$@"
}
status=0
(DEBIAN_BASE_CACHE_REFRESH=1 acquire rename_failure) || status=$?
unset -f mv
[[ $status == 39 ]]
[[ $(sha256sum "$entry/base.img") == "$old_sum" ]]
[[ $(find "$BUILD_DIR/debian/base-cache" -name '.stage.*' -o -name '.backup.*' | wc -l) == 0 ]]
for signal in INT TERM; do
    mv() {
        if [[ $* == *'.stage.'* && $* != *'.backup.'* ]]; then
            command mv "$@" || return $?
            kill -s "$signal" "$BASHPID"
        else
            command mv "$@"
        fi
    }
    status=0
    (DEBIAN_BASE_CACHE_REFRESH=1 acquire interrupted_refresh) || status=$?
    unset -f mv
    [[ $status == 130 || $status == 143 ]]
    [[ $(sha256sum "$entry/base.img") == "$old_sum" ]]
    [[ $(find "$BUILD_DIR/debian/base-cache" -name '.stage.*' -o -name '.backup.*' | wc -l) == 0 ]]
done
for variable in DEBIAN_BASE_CACHE DEBIAN_BASE_CACHE_REFRESH; do
    if (export "$variable=invalid"; acquire invalid_control); then
        echo "FAIL: accepted invalid $variable" >&2; exit 1
    fi
done
echo 'ok - warm copy preserves metadata, failed refresh restores old cache, controls reject invalid values'

# Exercise the production bootstrap/pack boundary using simulated Docker runs.
eval "$real_create_base"
DEBIAN_ROOTFS_IMG="$work/pinned.img"
docker() {
    case "$1 $2" in
        'volume create'|'volume rm') printf '%s %s\n' "$1" "$2" >>"$work/docker-events" ;;
        'run --rm')
            [[ " $* " == *" --platform $DEBIAN_DOCKER_PLATFORM "* ]] || return 90
            [[ " $* " == *" $DEBIAN_DOCKER_IMAGE "* ]] || return 91
            [[ " $* " != *" $DEBIAN_DOCKER_IMAGE_ID "* ]] || return 92
            printf 'run\n' >>"$work/docker-events"
            [[ -z ${SIGNAL_DOCKER:-} ]] || kill -s "$SIGNAL_DOCKER" "$BASHPID"
            [[ ${FAIL_DOCKER:-0} != 1 ]] || return 29
            ;;
        *) return 93 ;;
    esac
}
debian_create_base "$DEBIAN_ROOTFS_IMG"
[[ $(grep -c '^run$' "$work/docker-events") == 2 ]]
: >"$work/docker-events"
status=0
FAIL_DOCKER=1 debian_create_base "$DEBIAN_ROOTFS_IMG" || status=$?
[[ $status == 29 ]]
[[ $(grep -c '^run$' "$work/docker-events") == 1 ]]
[[ $(tail -n 1 "$work/docker-events") == 'volume rm' ]]
echo 'ok - Docker runs select the tag by platform while cache identity stays separate'

for signal in INT TERM; do
    : >"$work/docker-events"
    status=0
    SIGNAL_DOCKER=$signal debian_create_base "$DEBIAN_ROOTFS_IMG" || status=$?
    [[ $status == 130 || $status == 143 ]]
    [[ $(tail -n 1 "$work/docker-events") == 'volume rm' ]]
done
echo 'ok - INT and TERM roll back refreshed cache and clean bootstrap volumes'

[[ -z $(find "$work" -type f -name '*.lock' -print -quit) ]] || {
    echo 'FAIL: completed operations leave lock files behind' >&2
    exit 1
}
