#!/usr/bin/env bash

# Keep lock files out of output and cache directories. Callers may override the
# central directory for isolated builds and tests.
_build_lock_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BUILD_LOCK_DIR=${BUILD_LOCK_DIR:-$(realpath -m -- "$_build_lock_lib_dir/../../build/.locks")}
unset _build_lock_lib_dir

# Locks are removed while held. Waiters verify the inode after flock and retry
# if they opened a file that its previous owner has since removed.
# Callers install build_lock_release_all in their EXIT cleanup, after rollback.
if ! declare -p _build_lock_paths &>/dev/null; then
    declare -gA _build_lock_paths=() _build_lock_held=()
fi

build_lock_acquire() {
    local _bl_result=$1 _bl_key _bl_resource=$2 _bl_digest
    # EXIT cleanup can see these locals even if a signal arrives immediately
    # after opening the file, before its descriptor is added to the registry.
    local _bl_acquire_fd= _bl_acquire_path= _bl_acquire_owner=$BASHPID
    _bl_resource=$(realpath -m -- "$_bl_resource") || return 1
    _bl_digest=$(printf '%s' "$_bl_resource" | sha256sum) || return 1
    _bl_digest=${_bl_digest%% *}
    [[ $_bl_digest =~ ^[0-9a-f]{64}$ ]] || return 1
    _bl_acquire_path="$BUILD_LOCK_DIR/$_bl_digest.lock"
    while :; do
        mkdir -p -- "$BUILD_LOCK_DIR" || return 1
        if ! { exec {_bl_acquire_fd}>>"$_bl_acquire_path"; } 2>/dev/null; then
            # The last owner may have removed the empty directory after mkdir.
            [[ ! -d $BUILD_LOCK_DIR ]] && continue
            return 1
        fi
        _bl_key=$BASHPID:$_bl_acquire_fd
        _build_lock_paths[$_bl_key]=$_bl_acquire_path
        _build_lock_held[$_bl_key]=0
        flock -x "$_bl_acquire_fd" || return 1
        _build_lock_held[$_bl_key]=1
        if [[ $_bl_acquire_path -ef /proc/$BASHPID/fd/$_bl_acquire_fd ]]; then
            printf -v "$_bl_result" '%s' "$_bl_acquire_fd"
            return 0
        fi
        flock -u "$_bl_acquire_fd"
        exec {_bl_acquire_fd}>&-
        _bl_acquire_fd=
        unset '_build_lock_paths[$_bl_key]' '_build_lock_held[$_bl_key]'
    done
}

build_lock_release() {
    local _bl_fd=$1 _bl_key=$BASHPID:$1 _bl_path _bl_status=0
    [[ -n ${_build_lock_paths[$_bl_key]+set} ]] || return 0
    _bl_path=${_build_lock_paths[$_bl_key]}
    # An interrupted acquisition may have opened the file without locking it.
    # Never unlink another process's lock in that case.
    if [[ ${_build_lock_held[$_bl_key]:-0} == 1 ]] || flock -xn "$_bl_fd"; then
        if [[ $_bl_path -ef /proc/$BASHPID/fd/$_bl_fd ]]; then
            rm -f -- "$_bl_path" || _bl_status=$?
        fi
        # Children may still have inherited descriptors for this open file.
        flock -u "$_bl_fd" || _bl_status=$?
    fi
    exec {_bl_fd}>&-
    unset '_build_lock_paths[$_bl_key]' '_build_lock_held[$_bl_key]'
    rmdir -- "$BUILD_LOCK_DIR" 2>/dev/null || :
    return "$_bl_status"
}

build_lock_release_all() {
    local _bl_entry _bl_cleanup_status=0
    if [[ ${_bl_acquire_owner:-} == "$BASHPID" && -n ${_bl_acquire_fd:-} &&
          -e /proc/$BASHPID/fd/$_bl_acquire_fd ]]; then
        _build_lock_paths[$BASHPID:$_bl_acquire_fd]=$_bl_acquire_path
    fi
    for _bl_entry in "${!_build_lock_paths[@]}"; do
        # Subshells inherit the registry, but must not release their parent's locks.
        [[ $_bl_entry == "$BASHPID:"* ]] || continue
        build_lock_release "${_bl_entry#*:}" || _bl_cleanup_status=$?
    done
    return "$_bl_cleanup_status"
}
