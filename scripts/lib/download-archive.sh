#!/usr/bin/env bash
# Source this file to download, verify and extract a cached gzip tarball.

download_archive() {
    local url=$1 cache=$2 destination=$3 expected=${4:-}
    local stored actual temp lock_fd attempt downloaded=0
    mkdir -p -- "$(dirname -- "$cache")" "$destination"
    exec {lock_fd}>"${cache}.lock"
    flock "$lock_fd"

    if [[ -f $cache && -f ${cache}.sha256 ]]; then
        read -r stored < "${cache}.sha256"
        actual=$(sha256sum -- "$cache")
        actual=${actual%% *}
    else
        stored='' actual=''
    fi
    if [[ -z $stored || $stored != "$actual" || ( -n $expected && $actual != "$expected" ) ]] ||
       ! tar -tzf "$cache" >/dev/null 2>&1; then
        temp=$(mktemp "${cache}.tmp.XXXXXX")
        for attempt in 1 2 3; do
            if curl --fail --silent --show-error --location --retry 2 --retry-delay 2 \
                    --retry-all-errors --connect-timeout 15 --output "$temp" "$url" &&
               tar -tzf "$temp" >/dev/null 2>&1; then
                downloaded=1
                break
            fi
            ((attempt == 3)) || sleep "$attempt"
        done
        if ((downloaded == 0)); then
            rm -f -- "$temp"
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            return 1
        fi
        actual=$(sha256sum -- "$temp")
        actual=${actual%% *}
        if [[ -n $expected && $actual != "$expected" ]]; then
            printf 'Archive SHA-256 mismatch: %s\n' "$url" >&2
            rm -f -- "$temp"
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            return 1
        fi
        mv -f -- "$temp" "$cache"
        printf '%s\n' "$actual" > "${cache}.sha256"
    fi
    tar -xzf "$cache" -C "$destination" --strip-components=1
    flock -u "$lock_fd"
    exec {lock_fd}>&-
}
