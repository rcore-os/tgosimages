#!/usr/bin/env bash

# Formatting only: sourcing this file never redirects output or creates logs.
log_format() {
    local level=$1 format=$2 message
    shift 2
    printf -v message "$format" "$@"
    printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$message"
}

log_level() {
    local level=$1 line
    shift
    line=$(log_format "$level" '%s' "$*")
    if [[ ${LOG_TO_STDERR:-1} == 1 ]]; then
        printf '%s\n' "$line" >&2
    fi
    if [[ -n ${LOG_FILE:-} && ( -z ${LOG_STDIO_CAPTURED:-} || ${LOG_TO_STDERR:-1} != 1 ) ]]; then
        mkdir -p -- "$(dirname -- "$LOG_FILE")"
        printf '%s\n' "$line" >>"$LOG_FILE"
    fi
}

log() { log_level INFO "$@"; }
info() { log_level INFO "$@"; }
success() { log_level SUCCESS "$@"; }
warn() { log_level WARN "$@"; }
error() { log_level ERROR "$@"; }
vlog() { if [[ ${VERBOSE:-0} == 1 ]]; then log_level DEBUG "$@"; fi; }
die() { error "$1"; exit "${2:-1}"; }

# Batch summaries use the same formatter, with an additional summary file.
log_summary() {
    local summary=$1
    shift
    log_format "$@" | tee -a "$summary"
}

log_failure_tail() {
    local summary=$1 target=$2 file=$3
    log_summary "$summary" ERROR 'FAILURE LOG %s (last 20 lines):' "$target"
    tail -n 20 -- "$file" | tee -a "$summary"
}
