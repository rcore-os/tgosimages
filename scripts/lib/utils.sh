#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library, should be sourced, not executed." >&2
    exit 1
fi

UTILS_CALLER_SOURCE="${BASH_SOURCE[1]:-${0:-script}}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

script_log_info() {
    local caller_dir
    local category=""
    local name
    local root

    caller_dir="$(cd -- "$(dirname -- "${UTILS_CALLER_SOURCE}")" >/dev/null 2>&1 && pwd -P)"
    if [[ "${caller_dir}" == "${ROOT_DIR}/scripts/"* ]]; then
        category="${caller_dir#"${ROOT_DIR}/scripts/"}"
        category="${category%%/*}"
    fi

    name="$(basename "${UTILS_CALLER_SOURCE}")"
    name="${name%.sh}"

    if [[ -n "${LOG_DIR:-}" ]]; then
        root="${LOG_DIR}"
    elif [[ -n "${category}" ]]; then
        root="${ROOT_DIR}/logs/${category}"
    else
        root="${ROOT_DIR}/logs"
    fi

    printf '%s|%s|%s\n' "${category}" "${name}" "${root}"
}

new_log_dir() {
    local category="$1"
    local name="$2"
    local action="$3"
    local log_root

    if [[ -n "${LOG_DIR:-}" ]]; then
        log_root="${LOG_DIR}"
    elif [[ -n "${category}" ]]; then
        log_root="${ROOT_DIR}/logs/${category}"
    else
        log_root="${ROOT_DIR}/logs"
    fi
    if [[ -n "${action}" ]]; then
        printf '%s/%s-%s-%s-%s\n' "${log_root}" "${name}" "${action}" "$(date '+%Y%m%d-%H%M%S')" "$$"
    else
        printf '%s/%s-%s-%s\n' "${log_root}" "${name}" "$(date '+%Y%m%d-%H%M%S')" "$$"
    fi
}

# Log file
if [[ -z "${LOG_FILE:-}" && "${LOG_CREATE_DEFAULT_FILE:-1}" == "1" ]]; then
    IFS='|' read -r _ LOG_NAME LOG_ROOT < <(script_log_info)
    mkdir -p "${LOG_ROOT}"
    LOG_FILE="${LOG_ROOT}/${LOG_NAME}-$(date '+%Y%m%d-%H%M%S')-$$.log"
fi
export LOG_FILE

if [[ -n "${LOG_FILE:-}" && "${LOG_CAPTURE_STDIO:-1}" == "1" && -z "${LOG_STDIO_CAPTURED:-}" && "${LOG_TO_STDERR:-1}" == "1" ]]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    export LOG_STDIO_CAPTURED=1
    exec > >(tee -a "${LOG_FILE}") 2>&1
fi

# Logging function
log() {
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "${LOG_TO_STDERR:-1}" == "1" ]]; then
        printf "[%s] %s\n" "$timestamp" "$*" >&2
    fi
    if [[ -n "${LOG_FILE:-}" && (-z "${LOG_STDIO_CAPTURED:-}" || "${LOG_TO_STDERR:-1}" != "1") ]]; then
        mkdir -p "$(dirname "${LOG_FILE}")"
        echo "[$timestamp] $*" >> "${LOG_FILE}"
    fi
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

copy_required() {
    local src="$1"
    local dst="$2"
    [[ -e "$src" ]] || die "Required artifact not found: $src"
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
}

copy_optional() {
    local src="$1"
    local dst="$2"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst"
    else
        warn "Optional artifact not found: $src"
    fi
}

run_parallel_functions() {
    local action="$1"
    shift
    local steps=()
    local step_names=()
    local args=()
    local step
    local pid
    local status
    local failed=0
    local failed_steps=()
    local category
    local script_name
    IFS='|' read -r category script_name _ < <(script_log_info)
    local log_dir="${PARALLEL_LOG_DIR:-$(new_log_dir "${category}" "${script_name}" "${action}")}"
    local summary_log="${log_dir}/summary.log"

    while [[ "$#" -gt 0 && "$1" != "--" ]]; do
        steps+=("$1")
        if [[ "$1" == *=* ]]; then
            step_names+=("${1%%=*}")
        else
            step_names+=("$1")
        fi
        shift
    done
    [[ "${1:-}" == "--" ]] || die "Missing run_parallel_functions separator"
    shift
    args=("$@")

    mkdir -p "$log_dir"
    : >"$summary_log"

    printf '[%s] START %s\n' "$(date '+%F %T')" "$action" | tee -a "$summary_log"
    printf '[%s] Log directory: %s\n' "$(date '+%F %T')" "$log_dir" | tee -a "$summary_log"
    printf '[%s] Steps: %s\n' "$(date '+%F %T')" "${step_names[*]}" | tee -a "$summary_log"
    printf '[%s] Arguments: %s\n' "$(date '+%F %T')" "${args[*]:-(none)}" | tee -a "$summary_log"

    local pids=()
    local pid_steps=()
    local pid_logs=()
    local pid_status_files=()
    local pid_start_times=()
    local now
    for step in "${steps[@]}"; do
        local step_name="$step"
        local step_command=()
        local use_common_args=1
        if [[ "$step" == *=* ]]; then
            step_name="${step%%=*}"
            read -r -a step_command <<< "${step#*=}"
            use_common_args=0
        fi
        local step_log="${log_dir}/${step_name}.log"
        local status_file="${log_dir}/${step_name}.status"
        rm -f "${status_file}"
        printf '[%s] QUEUE %s: %s\n' "$(date '+%F %T')" "$step_name" "$step_log" | tee -a "$summary_log"
        (
            set +e
            {
                printf '[%s] START %s\n' "$(date '+%F %T')" "$step_name"
                printf 'cwd=%s\n' "$(pwd)"
                printf 'function='
                if [[ "${use_common_args}" -eq 1 ]]; then
                    printf '%q ' "$step" "${args[@]}"
                else
                    printf '%q ' "${step_command[@]}"
                fi
                printf '\n\n'
                LOG_FILE="$step_log"
                LOG_TO_STDERR=0
                export LOG_FILE LOG_TO_STDERR
                if [[ "${use_common_args}" -eq 1 ]]; then
                    ( set -e; "$step" "${args[@]}" )
                else
                    ( set -e; "${step_command[@]}" )
                fi
                status=$?
                printf '\n[%s] END %s status=%s\n' "$(date '+%F %T')" "$step_name" "$status"
                printf '%s\n' "$status" >"${status_file}"
                exit "$status"
            } >"$step_log" 2>&1
        ) &
        pid=$!
        pids+=("$pid")
        pid_steps+=("$step_name")
        pid_logs+=("$step_log")
        pid_status_files+=("$status_file")
        pid_start_times+=("$(date '+%s')")
        printf '[%s] STARTED %s: pid=%s\n' "$(date '+%F %T')" "$step_name" "$pid" | tee -a "$summary_log"
    done

    local remaining="${#pids[@]}"
    local heartbeat_interval="${PARALLEL_HEARTBEAT_INTERVAL:-30}"
    local next_heartbeat=$(( $(date '+%s') + heartbeat_interval ))
    while [[ "${remaining}" -gt 0 ]]; do
        local progressed=0
        for i in "${!pids[@]}"; do
            [[ -n "${pids[$i]:-}" ]] || continue
            [[ -f "${pid_status_files[$i]}" ]] || continue
            pid="${pids[$i]}"
            step="${pid_steps[$i]}"
            step_log="${pid_logs[$i]}"
            status="$(<"${pid_status_files[$i]}")"
            wait "$pid" 2>/dev/null || true
            rm -f "${pid_status_files[$i]}"
            unset 'pids[i]'
            progressed=1
            if [[ "${status}" -eq 0 ]]; then
                printf '[%s] DONE %s: log=%s\n' "$(date '+%F %T')" "$step" "$step_log" | tee -a "$summary_log"
            else
                failed=1
                failed_steps+=("$step")
                printf '[%s] FAILED %s: status=%s log=%s\n' "$(date '+%F %T')" "$step" "$status" "$step_log" | tee -a "$summary_log"
            fi
            remaining=$((remaining - 1))
        done

        now="$(date '+%s')"
        if [[ "${remaining}" -gt 0 && "${now}" -ge "${next_heartbeat}" ]]; then
            local running=()
            for i in "${!pids[@]}"; do
                [[ -n "${pids[$i]:-}" ]] || continue
                running+=("${pid_steps[$i]}:$((now - pid_start_times[$i]))s")
            done
            printf '[%s] RUNNING %s: %s\n' "$(date '+%F %T')" "$action" "${running[*]}" | tee -a "$summary_log"
            next_heartbeat=$((now + heartbeat_interval))
        fi

        [[ "${remaining}" -eq 0 || "${progressed}" -eq 1 ]] || sleep 1
    done

    if [[ "${PARALLEL_DEFER_COMPLETION:-0}" != "1" ]]; then
        if [[ "$failed" -eq 0 ]]; then
            printf '[%s] COMPLETE %s: all steps finished successfully\n' "$(date '+%F %T')" "$action" | tee -a "$summary_log"
        else
            printf '[%s] COMPLETE %s: failed steps=%s\n' "$(date '+%F %T')" "$action" "${failed_steps[*]}" | tee -a "$summary_log"
        fi
        printf '[%s] Summary log: %s\n' "$(date '+%F %T')" "$summary_log" | tee -a "$summary_log"
    fi

    return "$failed"
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
    local fetch_attempt
    local target="$ref"
    if [ ! -d "$repo_path/.git" ]; then
        echo "Error: $repo_path is not a git repository" >&2
        return 1
    fi
    pushd "$repo_path" >/dev/null || return 1
    # Most repositories are cloned with --depth=1. Fetch only the requested ref
    # first; fetching all tags/branches is expensive and fragile for large repos.
    # rev-parse can succeed with only a commit object, so check the tree too.
    if ! git cat-file -e "${ref}^{tree}" >/dev/null 2>&1; then
        for fetch_attempt in 1 2 3; do
            echo "[FETCH] Fetching ref ${ref} (attempt ${fetch_attempt}/3)"
            git fetch --quiet --no-tags --depth=1 origin "$ref" || true
            if git cat-file -e "${ref}^{tree}" >/dev/null 2>&1; then
                break
            fi
            if git cat-file -e "FETCH_HEAD^{tree}" >/dev/null 2>&1; then
                target="FETCH_HEAD"
                break
            fi
            sleep $((fetch_attempt * 2))
        done
    fi
    if ! git cat-file -e "${target}^{tree}" >/dev/null 2>&1; then
        echo "[FETCH] Ref not found in shallow clone, deepening history..."
        for fetch_attempt in 1 2 3; do
            git fetch --quiet --no-tags --deepen=50000 origin || true
            if git cat-file -e "${ref}^{tree}" >/dev/null 2>&1; then
                target="$ref"
                break
            fi
            if git cat-file -e "FETCH_HEAD^{tree}" >/dev/null 2>&1; then
                target="FETCH_HEAD"
                break
            fi
            sleep $((fetch_attempt * 2))
        done
    fi
    if ! git cat-file -e "${target}^{tree}" >/dev/null 2>&1; then
        echo "Error: Branch, tag, or commit not found: $ref" >&2
        popd >/dev/null
        return 2
    fi
    # Try checkout; if it fails (e.g. "unable to read tree"), unshallow and retry
    if ! git checkout --quiet --force "$target" 2>&1; then
        echo "[FETCH] Checkout failed in shallow clone, fetching requested ref again..."
        git fetch --quiet --no-tags --depth=1 origin "$ref" || true
        git checkout --quiet --force "$target"
    fi
    git clean -fd --quiet
    # The forced checkout above reset the worktree to $ref, which discards any
    # previously applied patches (both `git apply` working-tree edits and `git am`
    # commits, since HEAD moved back to $ref). Their stamps under .patch_stamps
    # are now stale, so drop them — otherwise apply_patches would skip the patches
    # and leave the tree without them. This matters when several builds reuse one
    # source dir (e.g. qemu multi-arch builds sharing build/qemu_linux).
    rm -rf -- "${repo_path}/.patch_stamps"
    echo "Switched to $ref"
    popd >/dev/null
    return 0
}
