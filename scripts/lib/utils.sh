#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library, should be sourced, not executed." >&2
    exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

# Log file
LOG_FILE="${BUILD_DIR}/log.log"  # Default log file

# Logging function
log() {
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "[%s] %s\n" "$timestamp" "$*" >&2
    echo "[$timestamp] $*" >> "${LOG_FILE}"
}

# Verbose logging (only outputs when VERBOSE=1)
vlog() {
    if [[ ${VERBOSE:-0} -eq 1 ]]; then
        log "$@"
    fi
}

# Error handling
die() {
    log "❌ [ERROR]: $1"
    exit "${2:-1}"
}

# Success message
success() {
    log "✅ $1"
}

# Info message
info() {
    log "ℹ️  $1"
}

# Warning message
warn() {
    log "⚠️  $1"
}

apply_patches() {
    local patch_dir="$1"
    local src_dir="$2"

    if [[ -z "$patch_dir" || -z "$src_dir" ]]; then
        echo "[ERROR] apply_patches: patch_dir and src_dir cannot be empty!" >&2
        return 1
    fi

    if [[ -z "${patch_dir}" || -z "${src_dir}" ]]; then
        echo "Usage: apply_patches <patch_dir> <src_dir>" >&2
        return 1
    fi
    
    # Search patch directory
    if [[ ! -d "${patch_dir}" ]]; then
        log "[PATCH] Directory not found: ${patch_dir} (skip)"; return 0
    fi
    shopt -s nullglob
    local patch_files=("${patch_dir}"/*.patch "${patch_dir}"/*.diff)
    if (( ${#patch_files[@]} == 0 )); then
        log "[PATCH] No patch files in ${patch_dir}"; return 0
    fi
    log "[PATCH] Found ${#patch_files[@]} patch file(s)"
    pushd "${src_dir}" >/dev/null
    mkdir -p .patch_stamps
    for p in "${patch_files[@]}"; do
        [[ -f "$p" ]] || continue
        local base stamp type applied cid
        base=$(basename "$p")
        stamp=.patch_stamps/${base}.applied
        if [[ -f "$stamp" ]]; then
            log "[SKIP] $base (stamp exists)"; continue
        fi
        type="diff"
        if grep -q '^From [0-9a-f]\{7,40\} ' "$p" 2>/dev/null && grep -q '^Subject:' "$p" 2>/dev/null; then
            type="mbox"
        fi
        log "[APPLY] $base type=$type"
        applied=0
        if [[ $type == mbox ]]; then
            cid=$(grep -m1 '^From [0-9a-f]\{7,40\} ' "$p" | awk '{print $2}') || true
            if [[ -n "$cid" ]] && git rev-list --all | grep -q "^$cid"; then
                log "[SKIP] $base commit $cid already in history"; echo > "$stamp"; applied=1
            else
                if git am --keep-cr < "$p" >>"${LOG_FILE}" 2>&1; then
                    applied=1; echo > "$stamp"
                else
                    log "[WARN] git am failed; fallback to git apply path"; git am --abort || true
                fi
            fi
        fi
        if [[ $applied -eq 0 ]]; then
            if git apply --check "$p" >/dev/null 2>&1; then
                if git apply "$p" >>"${LOG_FILE}" 2>&1; then
                    applied=1; echo > "$stamp"; log "  git apply ok"
                fi
            else
                if git apply --reverse --check "$p" >/dev/null 2>&1; then
                    log "[INFO] $base appears already applied (reverse check)"; echo > "$stamp"; applied=1
                fi
            fi
        fi
        if [[ $applied -eq 0 ]]; then
            for plevel in 1 0; do
                if patch -p${plevel} --dry-run < "$p" >/dev/null 2>&1; then
                    if patch -p${plevel} < "$p" >>"${LOG_FILE}" 2>&1; then
                        applied=1; echo > "$stamp"; log "  fallback patch -p${plevel} applied"; break
                    fi
                fi
                vlog "  fallback patch -p${plevel} failed"
            done
        fi
        if [[ $applied -eq 0 ]]; then
            log "[ERROR] Cannot apply $base"; popd >/dev/null; return 1
        fi
    done
    popd >/dev/null
    return 0
}

clone_repository() {
    local repo_url="$1"
    local src_dir="$2"

    if [[ -z "$repo_url" || -z "$src_dir" ]]; then
        echo "[ERROR] clone_repository: repo_url and src_dir cannot be empty!" >&2
        return 1
    fi

    if [[ -d "${src_dir}/.git" ]]; then
        echo "[SKIP] repo exists: ${src_dir}" >&2
    else
        echo "[CLONE] ${repo_url} -> ${src_dir}" >&2
        git clone --depth=1 "${repo_url}" "${src_dir}"
    fi
}

checkout_ref() {
    # Usage: checkout_git_ref <repo_path> <ref>
    local repo_path="$1"
    local ref="$2"
    if [ ! -d "$repo_path/.git" ]; then
        echo "Error: $repo_path is not a git repository" >&2
        return 1
    fi
    pushd "$repo_path" >/dev/null || return 1
    # Attempt fetch to ensure tag/commit is available. Most repositories are
    # cloned with --depth=1, so a pinned commit may not exist locally yet.
    if ! git rev-parse --verify "$ref" >/dev/null 2>&1; then
        git fetch --quiet --depth=1 origin "$ref" 2>/dev/null || true
    fi
    git fetch --all --tags --quiet
    if git rev-parse --verify "$ref" >/dev/null 2>&1; then
        git checkout --quiet --force "$ref"
        git clean -fd --quiet
        echo "Switched to $ref"
        popd >/dev/null
        return 0
    else
        echo "Error: Branch, tag, or commit not found: $ref" >&2
        popd >/dev/null
        return 2
    fi
}
