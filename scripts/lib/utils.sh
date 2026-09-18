#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library, should be sourced, not executed." >&2
    exit 1
fi

UTILS_CALLER_SOURCE="${BASH_SOURCE[1]:-${0:-script}}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
source "${ROOT_DIR}/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"

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

    if [[ -n "${PLATFORM_LOG_RUN_DIR:-}" ]]; then
        log_root="${PLATFORM_LOG_RUN_DIR}/steps"
    elif [[ -n "${LOG_DIR:-}" ]]; then
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

# Help output should not create empty default logs.
if [[ $UTILS_CALLER_SOURCE == "$0" ]]; then
    for _log_arg in "$@"; do
        case $_log_arg in help|-h|--help) LOG_CREATE_DEFAULT_FILE=0 ;; esac
    done
    unset _log_arg
fi

# Log file
if [[ -z "${LOG_FILE:-}" && "${LOG_CREATE_DEFAULT_FILE:-1}" == "1" ]]; then
    IFS='|' read -r _ LOG_NAME LOG_ROOT < <(script_log_info)
    mkdir -p "${LOG_ROOT}"
    LOG_FILE="${LOG_ROOT}/${LOG_NAME}-$(date '+%Y%m%d-%H%M%S')-$$.log"
    _log_created=1
fi
export LOG_FILE

source "${SCRIPT_DIR}/log.sh"
if [[ -n "${LOG_FILE:-}" && "${LOG_CAPTURE_STDIO:-1}" == "1" && -z "${LOG_STDIO_CAPTURED:-}" && "${LOG_TO_STDERR:-1}" == "1" ]]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    export LOG_STDIO_CAPTURED=1
    exec > >(tee -a "${LOG_FILE}" | (unset LOG_STDIO_CAPTURED; log_render)) 2>&1
fi

source "${SCRIPT_DIR}/build-performance.sh"
source "${SCRIPT_DIR}/build-workspace.sh"
if [[ ${_log_created:-0} == 1 ]]; then
    info "Log file: ${LOG_FILE}"
    unset _log_created
fi

# Prepend the musl cross toolchain bin dir to PATH when <arch>-linux-musl-gcc is absent
ensure_musl_toolchain() {
    local arch="${1:-aarch64}"
    local gcc="${arch}-linux-musl-gcc"
    local root candidate

    if command -v "${gcc}" >/dev/null 2>&1; then
        return 0
    fi

    for root in "${MUSL_TOOLCHAIN_ROOT:-}" /env /opt /usr/local; do
        [[ -n "${root}" ]] || continue
        candidate="${root}/${arch}-linux-musl-cross/bin"
        if [[ -x "${candidate}/${gcc}" ]]; then
            export PATH="${candidate}:${PATH}"
            info "Using musl toolchain: ${candidate}"
            return 0
        fi
    done

    die "${gcc} not found on PATH; install it (e.g. extract to /env/${arch}-linux-musl-cross) or set MUSL_TOOLCHAIN_ROOT"
}

report_build_arch() {
    local arch=$1
    info "Building architecture: ${arch}"
    if [[ -n ${BUILD_PROGRESS_FILE:-} ]]; then
        # Append each transition so even short architectures survive polling.
        printf '%s %s\n' "$arch" "$(date '+%s')" >>"$BUILD_PROGRESS_FILE"
    fi
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

# Sequential platform, OS, and rootfs batches share one progress protocol.
run_script_target() { bash "$0" "$@"; }
run_sequential_targets() {
    local category=$1 action=$2 callback=$3
    shift 3
    local targets=() target
    while [[ $# -gt 0 && $1 != -- ]]; do
        targets+=("$1")
        shift
    done
    [[ ${1:-} == -- ]] || die "Missing run_sequential_targets separator"
    shift
    local log_dir summary_log target_log pid status started now next_heartbeat
    local interval=${PARALLEL_HEARTBEAT_INTERVAL:-60}
    [[ $interval =~ ^[1-9][0-9]*$ ]] || interval=60
    log_dir=$(new_log_dir "$category" "${action// /-}" "")
    mkdir -p "$log_dir"
    summary_log=$log_dir/summary.log
    batch_log "$summary_log" "START $action"
    batch_log "$summary_log" "Log directory: $log_dir"
    batch_log "$summary_log" "Targets: ${targets[*]}"
    for target in "${targets[@]}"; do
        target_log=$log_dir/$target.log
        batch_log "$summary_log" "STARTED $target: log=$target_log"
        started=$(date '+%s')
        next_heartbeat=$((started + interval))
        (
            export PLATFORM_LOG_RUN_DIR="$log_dir"
            export LOG_FILE="$target_log" LOG_STDIO_CAPTURED=1 LOG_TO_STDERR=1
            "$callback" "$target" "$@"
        ) >>"$target_log" 2>&1 &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            now=$(date '+%s')
            if ((now >= next_heartbeat)); then
                batch_log "$summary_log" "RUNNING $target: $((now - started))s log=$target_log"
                next_heartbeat=$((now + interval))
            fi
            sleep 1
        done
        status=0
        wait "$pid" || status=$?
        if ((status != 0)); then
            batch_log "$summary_log" "FAILED $target: status=$status log=$target_log"
            log_failure_tail "$summary_log" "$target" "$target_log"
            batch_log "$summary_log" "COMPLETE $action: failed target=$target"
            batch_log "$summary_log" "Summary log: $summary_log"
            return 1
        fi
        batch_log "$summary_log" "DONE $target: log=$target_log"
    done
    batch_log "$summary_log" "COMPLETE $action: all targets finished successfully"
    batch_log "$summary_log" "Summary log: $summary_log"
}

batch_log() {
    local summary_log=$1
    shift
    local level=INFO
    case "$*" in FAILED*|*'failed target='*) level=ERROR ;; DONE*|*'all targets finished successfully'*) level=SUCCESS ;; esac
    log_summary "$summary_log" "$level" '%s' "$*"
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
    local unit=steps
    local callback=${PARALLEL_STEP_CALLBACK:-}
    [[ -z $callback ]] || unit=targets
    local category
    local script_name
    IFS='|' read -r category script_name _ < <(script_log_info)
    local log_dir="${PARALLEL_LOG_DIR:-$(new_log_dir "${category}" "${script_name}" "${action// /-}")}"
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

    log_summary "$summary_log" INFO 'START %s' "$action"
    log_summary "$summary_log" INFO 'Log directory: %s' "$log_dir"
    log_summary "$summary_log" INFO 'Steps: %s' "${step_names[*]}"
    log_summary "$summary_log" INFO 'Arguments: %s' "${args[*]:-(none)}"

    local pids=()
    local pid_steps=()
    local pid_logs=()
    local pid_status_files=()
    local pid_start_times=()
    local now child_index=0 child_jobs parallel_limit
    parallel_limit=$(build_parallel_limit "${#steps[@]}") || return
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
        log_summary "$summary_log" INFO 'QUEUE %s: %s' "$step_name" "$step_log"
        build_wait_slot "$parallel_limit" "${pids[@]}"
        child_jobs=$(build_child_jobs "$parallel_limit" "$child_index") || return
        child_index=$((child_index + 1))
        (
            export TGOS_BUILD_JOB_BUDGET="$child_jobs"
            set +e
            {
                log_format INFO 'START %s' "$step_name"
                printf 'cwd=%s\n' "$(pwd)"
                printf 'function='
                if [[ -n $callback ]]; then
                    printf '%q ' "$callback" "$step" "${args[@]}"
                elif [[ "${use_common_args}" -eq 1 ]]; then
                    printf '%q ' "$step" "${args[@]}"
                else
                    printf '%q ' "${step_command[@]}"
                fi
                printf '\n\n'
                LOG_FILE="$step_log"
                # stdout/stderr already point at the step file. Use that one
                # append-only stream, including in nested scripts.
                LOG_TO_STDERR=1
                LOG_STDIO_CAPTURED=1
                export LOG_FILE LOG_TO_STDERR LOG_STDIO_CAPTURED
                unset PARALLEL_STEP_CALLBACK
                if [[ -n $callback ]]; then
                    ( set -e; "$callback" "$step" "${args[@]}" )
                elif [[ "${use_common_args}" -eq 1 ]]; then
                    ( set -e; "$step" "${args[@]}" )
                else
                    ( set -e; "${step_command[@]}" )
                fi
                status=$?
                log_format INFO 'END %s status=%s' "$step_name" "$status"
                printf '%s\n' "$status" >"${status_file}"
                exit "$status"
            } >>"$step_log" 2>&1
        ) &
        pid=$!
        pids+=("$pid")
        pid_steps+=("$step_name")
        pid_logs+=("$step_log")
        pid_status_files+=("$status_file")
        pid_start_times+=("$(date '+%s')")
        log_summary "$summary_log" INFO 'STARTED %s: pid=%s' "$step_name" "$pid"
    done

    local remaining="${#pids[@]}"
    local heartbeat_interval="${PARALLEL_HEARTBEAT_INTERVAL:-60}"
    local next_heartbeat=$(( $(date '+%s') + heartbeat_interval ))
    while [[ "${remaining}" -gt 0 ]]; do
        local progressed=0
        for i in "${!pids[@]}"; do
            [[ -n "${pids[$i]:-}" ]] || continue
            pid="${pids[$i]}"
            if [[ ! -f ${pid_status_files[$i]} ]] && kill -0 "$pid" 2>/dev/null; then
                continue
            fi
            step="${pid_steps[$i]}"
            step_log="${pid_logs[$i]}"
            build_reap_task "$pid" "${pid_status_files[$i]}" status
            rm -f "${pid_status_files[$i]}"
            unset 'pids[i]'
            progressed=1
            if [[ "${status}" -eq 0 ]]; then
                log_summary "$summary_log" SUCCESS 'DONE %s: log=%s' "$step" "$step_log"
            else
                failed=1
                failed_steps+=("$step")
                log_summary "$summary_log" ERROR 'FAILED %s: status=%s log=%s' "$step" "$status" "$step_log"
                log_failure_tail "$summary_log" "$step" "$step_log"
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
            log_summary "$summary_log" INFO 'RUNNING %s: %s' "$action" "${running[*]}"
            next_heartbeat=$((now + heartbeat_interval))
        fi

        [[ "${remaining}" -eq 0 || "${progressed}" -eq 1 ]] || sleep 1
    done

    if [[ "${PARALLEL_DEFER_COMPLETION:-0}" != "1" ]]; then
        if [[ "$failed" -eq 0 ]]; then
            log_summary "$summary_log" SUCCESS 'COMPLETE %s: all %s finished successfully' "$action" "$unit"
        else
            log_summary "$summary_log" ERROR 'COMPLETE %s: failed %s=%s' "$action" "$unit" "${failed_steps[*]}"
        fi
        log_summary "$summary_log" INFO 'Summary log: %s' "$summary_log"
    fi

    return "$failed"
}

apply_patches() {
    local LC_ALL=C
    local patch_dir="$1"
    local src_dir="$2"
    build_assert_workspace_path "$src_dir" || return

    if [[ -z "$patch_dir" || -z "$src_dir" ]]; then
        error "apply_patches: patch_dir and src_dir cannot be empty!"
        return 1
    fi

    if [[ -z "${patch_dir}" || -z "${src_dir}" ]]; then
        echo "Usage: apply_patches <patch_dir> <src_dir>" >&2
        return 1
    fi
    
    local patch_identity patch_manifest="${src_dir}/.patch_stamps/patch-set.sha256"
    patch_identity=$(python3 "${TGOS_BUILD_LIB_DIR}/build_inputs.py" "$patch_dir") || return
    if [[ -f $patch_manifest && $(<"$patch_manifest") != "$patch_identity" ]]; then
        error "Patch set changed: prepare the source with checkout_ref before applying $patch_dir"
        return 1
    fi
    local source_identity
    if [[ -f $patch_manifest ]]; then
        source_identity=$(python3 "${TGOS_BUILD_LIB_DIR}/build_inputs.py" --source "$src_dir") || return
        if [[ -f ${src_dir}/.patch_stamps/source.sha256 &&
              $(<"${src_dir}/.patch_stamps/source.sha256") == "$source_identity" ]]; then
            info "PATCH CACHE HIT: verified ordered patch set and source state"
            return 0
        fi
        error "Patched source changed: prepare it with checkout_ref before reapplying patches"
        return 1
    fi
    # Old markers cannot silently survive removal of their patch files.
    local old_stamp old_name
    if [[ -d ${src_dir}/.patch_stamps ]]; then
        while IFS= read -r -d '' old_stamp; do
            old_name=${old_stamp##*/}
            old_name=${old_name%.applied}
            error "Unverified legacy patch marker $old_name: prepare the source with checkout_ref first"
            return 1
        done < <(find "${src_dir}/.patch_stamps" -maxdepth 1 -name '*.applied' -print0)
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
    # git am needs a committer identity; set a repo-local fallback when unset
    if [[ -z "$(git config user.name 2>/dev/null || true)" || -z "$(git config user.email 2>/dev/null || true)" ]]; then
        git config user.name "tgosimages"
        git config user.email "tgosimages@localhost"
    fi
    for p in "${patch_files[@]}"; do
        [[ -f "$p" ]] || continue
        local base stamp type applied cid
        base=$(basename "$p")
        stamp=.patch_stamps/${base}.applied
        type="diff"
        if grep -q '^From [0-9a-f]\{7,40\} ' "$p" 2>/dev/null && grep -q '^Subject:' "$p" 2>/dev/null; then
            type="mbox"
        fi
        log "[APPLY] $base type=$type"
        applied=0
        if [[ $type == mbox ]]; then
            cid=$(grep -m1 '^From [0-9a-f]\{7,40\} ' "$p" | awk '{print $2}') || true
            if [[ -n "$cid" ]] && git merge-base --is-ancestor "$cid" HEAD 2>/dev/null && git apply --reverse --check "$p" >/dev/null 2>&1; then
                log "[SKIP] $base commit $cid already in history"; echo > "$stamp"; applied=1
            else
                if git am --keep-cr < "$p" >>"${LOG_FILE:-/dev/null}" 2>&1; then
                    applied=1; echo > "$stamp"
                else
                    warn "git am failed; fallback to git apply path"; git am --abort || true
                fi
            fi
        fi
        if [[ $applied -eq 0 ]]; then
            if git apply --check "$p" >/dev/null 2>&1; then
                if git apply "$p" >>"${LOG_FILE:-/dev/null}" 2>&1; then
                    applied=1; echo > "$stamp"; log "  git apply ok"
                fi
            else
                if git apply --reverse --check "$p" >/dev/null 2>&1; then
                    info "$base appears already applied (reverse check)"; echo > "$stamp"; applied=1
                fi
            fi
        fi
        if [[ $applied -eq 0 ]]; then
            for plevel in 1 0; do
                if patch -p${plevel} --dry-run < "$p" >/dev/null 2>&1; then
                    if patch -p${plevel} < "$p" >>"${LOG_FILE:-/dev/null}" 2>&1; then
                        applied=1; echo > "$stamp"; log "  fallback patch -p${plevel} applied"; break
                    fi
                fi
                vlog "  fallback patch -p${plevel} failed"
            done
        fi
        if [[ $applied -eq 0 ]]; then
            error "Cannot apply $base"; popd >/dev/null; return 1
        fi
    done
    source_identity=$(python3 "${TGOS_BUILD_LIB_DIR}/build_inputs.py" --source "$src_dir") || { popd >/dev/null; return 1; }
    printf '%s\n' "$source_identity" >.patch_stamps/source.sha256
    printf '%s\n' "$patch_identity" >.patch_stamps/patch-set.sha256
    popd >/dev/null
    return 0
}

clone_repository() {
    local repo_url="$1"
    local src_dir="$2"
    build_assert_workspace_path "$src_dir" || return

    if [[ -z "$repo_url" || -z "$src_dir" ]]; then
        error "clone_repository: repo_url and src_dir cannot be empty!"
        return 1
    fi

    if [[ -d "${src_dir}/.git" ]]; then
        info "SKIP: repo exists: ${src_dir}"
    else
        info "CLONE: ${repo_url} -> ${src_dir}"
        if [[ -n ${BUILD_SOURCE_CACHE_DIR:-} ]]; then
            bash "$TGOS_BUILD_LIB_DIR/git-source-cache.sh" clone "$src_dir" "$repo_url"
        else
            git clone --depth=1 "${repo_url}" "${src_dir}"
        fi
    fi
}

checkout_ref() {
    # Usage: checkout_git_ref <repo_path> <ref>
    local repo_path="$1"
    local ref="$2"
    build_assert_workspace_path "$repo_path" || return
    local fetch_attempt
    local target="$ref"
    if [[ -n ${BUILD_SOURCE_CACHE_DIR:-} ]] && ! git -C "$repo_path" cat-file -e "${ref}^{tree}" 2>/dev/null; then
        target=$(bash "$TGOS_BUILD_LIB_DIR/git-source-cache.sh" ref "$repo_path" "$ref") || return
        ref=$target
    fi
    if [ ! -d "$repo_path/.git" ]; then
        error "$repo_path is not a git repository"
        return 1
    fi
    pushd "$repo_path" >/dev/null || return 1
    # Most repositories are cloned with --depth=1. Fetch only the requested ref
    # first; fetching all tags/branches is expensive and fragile for large repos.
    # rev-parse can succeed with only a commit object, so check the tree too.
    if ! git cat-file -e "${ref}^{tree}" >/dev/null 2>&1; then
        for fetch_attempt in 1 2 3; do
            info "FETCH: Fetching ref ${ref} (attempt ${fetch_attempt}/3)"
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
        info "FETCH: Ref not found in shallow clone, deepening history..."
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
        error "Branch, tag, or commit not found: $ref"
        popd >/dev/null
        return 2
    fi
    # Try checkout; if it fails (e.g. "unable to read tree"), unshallow and retry
    if ! git checkout --quiet --force "$target" 2>&1; then
        info "FETCH: Checkout failed in shallow clone, fetching requested ref again..."
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
