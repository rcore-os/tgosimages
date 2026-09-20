#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"

# One owner captures the whole platform invocation, including serial stages
# before/after parallel builds. Child scripts inherit the same output stream.
platform_log_init() {
    [[ -z ${PLATFORM_LOG_RUN_DIR:-} ]] || return 0

    local name=${0##*/} argument action=${1:-all}
    name=${name%.sh}
    for argument in "$@"; do
        case "$argument" in
            help|-h|--help)
                LOG_CREATE_DEFAULT_FILE=0
                return 0
                ;;
        esac
    done
    if [[ $# -eq 0 && $name != orangepi-5-plus ]] ||
       [[ $name == qemu && $# -eq 1 && $action != clean ]]; then
        LOG_CREATE_DEFAULT_FILE=0
        return 0
    fi
    # Multi-architecture QEMU uses the same batch summary as platform all.
    if [[ $name == qemu && ( $action == all || $action == clean ) ]]; then
        return 0
    fi
    # Keep explicit caller-managed logging and the existing opt-out working.
    [[ -z ${LOG_FILE:-} && ${LOG_CREATE_DEFAULT_FILE:-1} == 1 ]] || return 0
    if [[ $name == qemu && $# -ge 2 ]]; then
        action="${1}-${2}"
    fi
    action=${action//[^a-zA-Z0-9_-]/_}
    local log_root=${LOG_DIR:-${ROOT_DIR}/logs/platform}
    mkdir -p -- "$log_root"
    log_root=$(cd -- "$log_root" && pwd -P)
    local run_dir
    run_dir=$(mktemp -d "${log_root}/${name}-${action}-$(date '+%Y%m%d-%H%M%S')-XXXXXX")
    local summary=${run_dir}/summary.log full_log=${run_dir}/build.log
    local statuses status
    log_format INFO 'START %s %s' "$name" "$action" | tee -a "$summary" "$full_log" | log_render
    log_format INFO 'Log directory: %s' "$run_dir" | tee -a "$summary" "$full_log" | log_render

    # A fresh Bash retains the script's errexit semantics; wait for tee before
    # reporting completion so the log is fully written when the command exits.
    set +e
    PLATFORM_LOG_RUN_DIR="$run_dir" LOG_FILE="$full_log" \
        LOG_STDIO_CAPTURED=1 LOG_TO_STDERR=1 \
        bash "$0" "$@" 2>&1 | tee -a "$full_log" | log_render
    statuses=("${PIPESTATUS[@]}")
    set -e
    status=${statuses[0]}
    if ((status == 0 && statuses[1] != 0)); then
        status=${statuses[1]}
    fi
    if ((status == 0 && statuses[2] != 0)); then
        status=${statuses[2]}
    fi
    if ((status == 0)); then
        log_format SUCCESS 'COMPLETE %s %s: all stages finished successfully (status=0)' \
            "$name" "$action" | tee -a "$summary" "$full_log" | log_render
    else
        log_format ERROR 'FAILED %s %s: status=%s; see %s and steps/' \
            "$name" "$action" "$status" "$full_log" |
            tee -a "$summary" "$full_log" | log_render
    fi
    exit "$status"
}
