#!/usr/bin/env bash

# Collect lstat metadata in one GNU find traversal. Each record has 12 NUL-
# terminated fields: relative path (empty for root), atime, mtime, octal mode,
# uid, gid, device, inode, size, type, ctime, link count. Times are decimal Unix
# seconds with nanosecond precision (GNU find may append a trailing zero).
# Preorder captures each directory's atime before reading its entries. Symlinks
# are recorded without following them. Entry order is otherwise unspecified.
# MANIFEST and its temporary sibling must be outside ROOT. Failed scans leave
# any existing manifest untouched; callers must check the return status.
# For source-change checks, compare records by path, excluding only atime.
_rootfs_collect_metadata() {
    local root=$1 manifest=$2 temporary status
    temporary=$(mktemp -- "${manifest}.tmp.XXXXXX") || return
    if (cd -- "$root" && LC_ALL=C find -P . -printf '%P\0%A@\0%T@\0%m\0%U\0%G\0%D\0%i\0%s\0%y\0%C@\0%n\0') > "$temporary"; then
        if mv -f -- "$temporary" "$manifest"; then
            return 0
        else
            status=$?
        fi
    else
        status=$?
    fi
    rm -f -- "$temporary"
    return "$status"
}
