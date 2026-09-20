#!/usr/bin/env bash

build_cpu_scope_reexec() {
    local action=$1 command_path=$2 available quota quota_percent mode
    shift 2

    [[ -z ${TGOS_CPU_SCOPE_ACTIVE:-} ]] || return 0
    case $action in ''|help|-h|--help) return 0 ;; esac
    command -v systemd-run >/dev/null 2>&1 || return 0

    available=$(nproc) || return 0
    [[ $available =~ ^[1-9][0-9]*$ ]] || return 0
    quota=$((available * 5 / 8))
    ((quota > 0)) || quota=1
    quota_percent=$((quota * 100))

    if systemd-run --user --scope --quiet --collect --no-ask-password \
        -p "CPUQuota=${quota_percent}%" true >/dev/null 2>&1; then
        mode=user
    elif systemd-run --scope --quiet --collect --no-ask-password \
        -p "CPUQuota=${quota_percent}%" true >/dev/null 2>&1; then
        mode=system
    else
        return 0
    fi

    if [[ $mode == user ]]; then
        exec systemd-run --user --scope --quiet --collect --no-ask-password \
            -p "CPUQuota=${quota_percent}%" \
            env TGOS_CPU_SCOPE_ACTIVE=1 TGOS_BUILD_JOB_BUDGET="$quota" \
            "$command_path" "$@"
    fi
    exec systemd-run --scope --quiet --collect --no-ask-password \
        -p "CPUQuota=${quota_percent}%" \
        env TGOS_CPU_SCOPE_ACTIVE=1 TGOS_BUILD_JOB_BUDGET="$quota" \
        "$command_path" "$@"
}
