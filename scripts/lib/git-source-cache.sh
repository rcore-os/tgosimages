#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_GIT_ATTEMPTS=3
REMOTE_GIT_RETRY_DELAYS=(1 2)
stage=

cleanup() {
    [[ -z $stage ]] || rm -rf -- "$stage"
}

fail() {
    printf 'Source cache: %s\n' "$1" >&2
    exit "${2:-1}"
}

on_error() {
    local status=$?
    trap - ERR
    printf 'Source cache: operation failed (status=%s)\n' "$status" >&2
    exit "$status"
}

remote_git() {
    local cleanup_path=$1
    shift
    local attempt delay status
    for ((attempt = 1; attempt <= REMOTE_GIT_ATTEMPTS; attempt++)); do
        if git "$@"; then
            return 0
        else
            status=$?
        fi
        if ((attempt == REMOTE_GIT_ATTEMPTS)); then
            return "$status"
        fi
        if [[ -n $cleanup_path ]]; then
            [[ -n $stage && $cleanup_path == "$stage/"* ]] || fail 'invalid retry cleanup path'
            rm -rf -- "$cleanup_path"
        fi
        delay=${REMOTE_GIT_RETRY_DELAYS[attempt - 1]}
        printf 'Source cache: remote Git operation failed; attempt %s/%s; retrying in %ss\n' \
            "$attempt" "$REMOTE_GIT_ATTEMPTS" "$delay" >&2
        sleep "$delay"
    done
}

trap cleanup EXIT
trap on_error ERR

[[ $# -eq 3 ]] || fail 'usage: git-source-cache.sh <clone|ref> <repo> <url-or-ref>' 2
operation=$1
repo=$(realpath -m -- "$2")
value=$3
case $operation in
    clone) url=$value ;;
    ref) url=$(git -C "$repo" remote get-url origin) ;;
    *) fail "unknown operation: $operation" 2 ;;
esac

root=$(realpath -m -- "${BUILD_SOURCE_CACHE_DIR:?BUILD_SOURCE_CACHE_DIR is required}")
mkdir -p -- "$root"
key=$(printf '%s' "$url" | sha256sum)
key=${key%% *}
cache="$root/$key.git"

exec {lock_fd}>>"$root/$key.lock"
flock -x "$lock_fd"

if [[ ! -e $cache ]]; then
    stage=$(mktemp -d "$root/.$key.XXXXXXXX")
    candidate="$stage/source.git"
    remote_git "$candidate" clone --bare --depth=1 "$url" "$candidate"
    git -C "$candidate" config gc.auto 0
    mv -- "$candidate" "$cache"
    rmdir -- "$stage"
    stage=
elif [[ $operation == clone ]]; then
    remote_git '' -C "$cache" fetch --quiet --depth=1 --no-tags origin HEAD
    tip=$(git -C "$cache" rev-parse 'FETCH_HEAD^{commit}')
    git -C "$cache" update-ref HEAD "$tip"
fi

if [[ $operation == clone ]]; then
    # Copy the pack instead of creating alternates or hardlinks into the cache.
    git clone --no-local --depth=1 "file://$cache" "$repo"
    git -C "$repo" remote set-url origin "$url"
else
    ref_key=$(printf '%s' "$value" | sha256sum)
    ref_key=${ref_key%% *}
    cached_ref="refs/tgos-cache/$ref_key"
    immutable=0
    [[ $value =~ ^[[:xdigit:]]{40}$ ]] && immutable=1
    found=0
    git -C "$cache" cat-file -e "$value^{commit}" >/dev/null 2>&1 && found=1
    if ((immutable == 0 || found == 0)); then
        remote_git '' -C "$cache" fetch --quiet --depth=1 --no-tags origin "$value"
        resolved=$(git -C "$cache" rev-parse 'FETCH_HEAD^{commit}')
    else
        resolved=$(git -C "$cache" rev-parse "$value^{commit}")
    fi
    git -C "$cache" update-ref "$cached_ref" "$resolved"
    git -C "$repo" fetch --quiet --depth=1 --no-tags "file://$cache" "$cached_ref"
    git -C "$repo" rev-parse 'FETCH_HEAD^{commit}'
fi
