#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/build-lock.sh"

# Cache only the clean Debian ext4; composition always works on a private copy.

debian_platform_image_identity() (
    local container= identity
    cleanup_platform_container() {
        local status=$?
        trap - EXIT INT TERM
        [[ -z $container ]] || docker container rm -f "$container" >/dev/null 2>&1 || true
        exit "$status"
    }
    trap cleanup_platform_container EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    container=$(docker create --platform "$DEBIAN_DOCKER_PLATFORM" \
        "$DEBIAN_DOCKER_IMAGE" /bin/true) || return 1
    identity=$(docker container inspect --format '{{.Image}}' "$container") || return 1
    [[ $identity =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    docker container rm "$container" >/dev/null || return 1
    container=
    docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$identity"
)

debian_resolve_docker_image() {
    local identity
    # Pull when the local tag is absent or belongs to another platform.
    identity=$(docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$DEBIAN_DOCKER_IMAGE" 2>/dev/null) || identity=
    if [[ $identity != *" $DEBIAN_DOCKER_PLATFORM" ]]; then
        docker pull --platform "$DEBIAN_DOCKER_PLATFORM" "$DEBIAN_DOCKER_IMAGE" >&2 || return 1
        # API 1.49+ selects the platform directly. Older Docker versions use a
        # temporary container to expose the image selected for that platform.
        identity=$(docker image inspect --platform "$DEBIAN_DOCKER_PLATFORM" \
            --format '{{.Id}} {{.Os}}/{{.Architecture}}' \
            "$DEBIAN_DOCKER_IMAGE" 2>/dev/null) ||
            identity=$(debian_platform_image_identity) || return 1
    fi
    [[ $identity == *" $DEBIAN_DOCKER_PLATFORM" ]] || die "Docker image platform does not match $DEBIAN_DOCKER_PLATFORM"
    DEBIAN_DOCKER_IMAGE_ID=${identity%% *}
    [[ $DEBIAN_DOCKER_IMAGE_ID =~ ^sha256:[a-f0-9]{64}$ ]] || die "Cannot resolve immutable Debian Docker image ID"
}

debian_base_cache_key() {
    {
        printf '%s\0' debian-base-v1 "$DEBIAN_ARCH" "$DEBIAN_DPKG_ARCH" \
            "$DEBIAN_DOCKER_PLATFORM" "$DEBIAN_SUITE" "$DEBIAN_MIRROR" \
            "$DEBIAN_IMG_SIZE" "$DEBIAN_DOCKER_IMAGE_ID" "${DEBIAN_DEFAULT_PACKAGES[@]}"
        printf '%s' "$DEBIAN_PASSWORD" | sha256sum
        # Hash the complete recipes so bootstrap/packing edits invalidate bases.
        sha256sum "$ROOT_DIR/scripts/rootfs/debian.sh" "$ROOT_DIR/scripts/lib/debian-base-cache.sh" | cut -d ' ' -f 1
    } | sha256sum | cut -d ' ' -f 1
}

debian_base_sane() {
    [[ -f $1 && ! -L $1 ]] || return 1
    LC_ALL=C dumpe2fs -h "$1" 2>/dev/null | grep -q '^Filesystem features:.*\bextent\b' || return 1
    e2fsck -fn "$1" >/dev/null 2>&1
}

debian_base_cache_valid() {
    local entry=$1 expected actual
    [[ -f $entry/sha256 && ! -L $entry && ! -L $entry/sha256 ]] || return 1
    expected=$(cat "$entry/sha256")
    [[ $expected =~ ^[a-f0-9]{64}$ ]] || return 1
    actual=$(sha256sum "$entry/base.img") || return 1
    [[ ${actual%% *} == "$expected" ]] || return 1
    debian_base_sane "$entry/base.img"
}

debian_acquire_base() (
    local destination=$1 cache_dir key entry cache_fd staging= backup= publishing=0 committed=0 control
    for control in DEBIAN_BASE_CACHE DEBIAN_BASE_CACHE_REFRESH; do
        [[ ${!control-0} == 0 || ${!control-0} == 1 ]] || die "$control must be 0 or 1"
    done
    if [[ ${DEBIAN_BASE_CACHE:-1} == 0 ]]; then
        debian_create_base "$destination" || return $?
        return
    fi
    for command in flock sha256sum dumpe2fs e2fsck; do
        command -v "$command" >/dev/null || die "Debian base cache requires $command"
    done
    cache_dir="$BUILD_DIR/debian/base-cache"
    mkdir -p -- "$cache_dir"
    key=$(debian_base_cache_key)
    entry="$cache_dir/$key"
    trap 'build_lock_release_all' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    build_lock_acquire cache_fd "$cache_dir/$key.lock"
    if [[ ${DEBIAN_BASE_CACHE_REFRESH:-0} != 1 ]] && debian_base_cache_valid "$entry"; then
        info "Reusing clean Debian base for $DEBIAN_ARCH"
        cp --reflink=auto --sparse=always --preserve=mode,timestamps -- "$entry/base.img" "$destination"
        return $?
    fi
    info "Building clean Debian base for $DEBIAN_ARCH"
    staging=$(mktemp -d "$cache_dir/.stage.$key.XXXXXX")
    cleanup_cache_stage() {
        trap '' INT TERM
        if [[ $publishing == 1 && $committed == 0 ]]; then
            if [[ -d $backup/previous ]]; then
                rm -rf -- "$entry"
                mv -- "$backup/previous" "$entry" || return $?
            elif [[ $had_previous == 0 ]]; then
                rm -rf -- "$entry"
            fi
        fi
        rm -rf -- "$staging" "$backup"
    }
    trap 'status=$?; cleanup_cache_stage; build_lock_release_all; exit "$status"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Keep packing in the output parent to preserve the Docker bind mount.
    debian_create_base "$destination" || return $?
    debian_base_sane "$destination" || die "Debian base image failed ext4 validation"
    cp --reflink=auto --sparse=always --preserve=mode,timestamps -- "$destination" "$staging/base.img" || return $?
    sha256sum "$staging/base.img" | cut -d ' ' -f 1 >"$staging/sha256" || return $?
    # Only this key is replaced, while its lock covers lookup through publication.
    backup=$(mktemp -d "$cache_dir/.backup.$key.XXXXXX") || return $?
    local had_previous=0
    [[ ! -e $entry ]] || had_previous=1
    publishing=1
    if [[ $had_previous == 1 ]]; then
        mv -- "$entry" "$backup/previous" || return $?
    fi
    mv -- "$staging" "$entry" || return $?
    committed=1
    staging=
)
