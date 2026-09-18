#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
PLATFORM_DIR="${SCRIPTS_DIR}/platform"
OS_DIR="${SCRIPTS_DIR}/os"
ROOTFS_DIR="${SCRIPTS_DIR}/rootfs"
TOOLS_DIR="${SCRIPTS_DIR}/tools"

LOG_CREATE_DEFAULT_FILE="${LOG_CREATE_DEFAULT_FILE:-0}"
source "${SCRIPTS_DIR}/lib/utils.sh"

usage() {
    printf '%s\n' "Usage:"
    printf '%s\n' "  $0 platform <target> [os] [options]"
    printf '%s\n' "  $0 os <target> <platform-or-arch> [options]"
    printf '%s\n' "  $0 rootfs <target> [arch] [options]"
    printf '%s\n' "  $0 release <pack|github> [options]"
    printf '%s\n' "  $0 help | -h | --help"
    printf '%s\n' ""
    printf '%s\n' "Platform Targets:"
    printf '%s\n' "  phytiumpi            -> scripts/platform/phytiumpi.sh"
    printf '%s\n' "  roc-rk3568-pc        -> scripts/platform/roc-rk3568-pc.sh"
    printf '%s\n' "  evm3588              -> scripts/platform/evm3588.sh"
    printf '%s\n' "  tac-e400-plc         -> scripts/platform/tac-e400-plc.sh"
    printf '%s\n' "  orangepi-5-plus      -> scripts/platform/orangepi-5-plus.sh"
    printf '%s\n' "  rdk-s100p            -> scripts/platform/rdk-s100p.sh"
    printf '%s\n' "  bst-a1000            -> scripts/platform/bst-a1000.sh"
    printf '%s\n' "  qemu-aarch64         -> scripts/platform/qemu.sh aarch64"
    printf '%s\n' "  qemu-x86_64          -> scripts/platform/qemu.sh x86_64"
    printf '%s\n' "  qemu-riscv64         -> scripts/platform/qemu.sh riscv64"
    printf '%s\n' "  qemu-loongarch64     -> scripts/platform/qemu.sh loongarch64"
    printf '%s\n' "  qemu                 -> scripts/platform/qemu.sh all"
    printf '%s\n' "  all                  -> build board targets sequentially and QEMU architectures in parallel"
    printf '%s\n' "  clean                -> clean all platform targets"
    printf '%s\n' ""
    printf '%s\n' "OS Targets:"
    printf '%s\n' "  arceos               -> scripts/os/arceos.sh"
    printf '%s\n' "  zephyr               -> scripts/os/zephyr.sh"
    printf '%s\n' "  freertos             -> scripts/os/freertos.sh"
    printf '%s\n' "  rtthread             -> scripts/os/rtthread.sh"
    printf '%s\n' "  starry               -> scripts/os/starry.sh (use through an Orange Pi platform target)"
    printf '%s\n' "  all                  -> build all independent OS targets in parallel"
    printf '%s\n' "  clean                -> clean all independent OS targets in parallel"
    printf '%s\n' ""
    printf '%s\n' "Rootfs Targets:"
    printf '%s\n' "  busybox              -> scripts/rootfs/busybox.sh"
    printf '%s\n' "  alpine               -> scripts/rootfs/alpine.sh"
    printf '%s\n' "  debian               -> scripts/rootfs/debian.sh"
    printf '%s\n' "  all                  -> build all rootfs targets in parallel"
    printf '%s\n' "  clean                -> clean all rootfs targets in parallel"
    printf '%s\n' ""
    printf '%s\n' "Release:"
    printf '%s\n' "  pack                 -> scripts/tools/pack.sh"
    printf '%s\n' "  github               -> scripts/tools/github.sh"
    printf '%s\n' ""
    printf '%s\n' "Examples:"
    printf '%s\n' "  $0 platform phytiumpi             # show phytiumpi help"
    printf '%s\n' "  $0 platform phytiumpi linux"
    printf '%s\n' "  $0 platform qemu                 # show qemu help"
    printf '%s\n' "  $0 platform qemu-aarch64          # show qemu help"
    printf '%s\n' "  $0 platform qemu-aarch64 linux    # build linux with default rootfs"
    printf '%s\n' "  $0 platform qemu-loongarch64 linux # build LoongArch64 linux with default rootfs"
    printf '%s\n' "  $0 platform qemu all              # build all qemu architectures with default rootfs"
    printf '%s\n' "  $0 platform qemu all --rootfs alpine,debian"
    printf '%s\n' "  $0 platform qemu-x86_64 linux --outer-tests none --guest-tests cyclictest"
    printf '%s\n' "  $0 platform qemu-aarch64 all --guest-free-size 512M --outer-free-size 512M"
    printf '%s\n' "      Rootfs test/size options apply to ext4 outer+nested images; BusyBox initramfs gets platform payload only."
    printf '%s\n' "  $0 platform orangepi-5-plus starry"
    printf '%s\n' "  $0 platform orangepi-5-plus ivc"
    printf '%s\n' "  $0 os arceos aarch64-dyn --image-name arceos.bin"
    printf '%s\n' "  $0 os starry orangepi-5-plus"
    printf '%s\n' "  $0 os all <options>"
    printf '%s\n' "  $0 os clean"
    printf '%s\n' "  $0 rootfs busybox aarch64 --out_dir IMAGES/rootfs"
    printf '%s\n' "  $0 rootfs alpine aarch64 --out_dir IMAGES/rootfs"
    printf '%s\n' "  $0 rootfs debian riscv64 --out_dir IMAGES/rootfs"
    printf '%s\n' "  $0 rootfs all"
    printf '%s\n' "  $0 rootfs all aarch64 --out_dir IMAGES/rootfs"
    printf '%s\n' "  $0 rootfs clean"
    printf '%s\n' "  $0 release pack"
    printf '%s\n' "  $0 release github --token <TOKEN> --repo <owner/repo> --tag <tag>"
}

run_checked_script() {
    local script_path="$1"
    shift || true
    [[ -f "$script_path" ]] || { error "Script not found: $script_path"; exit 1; }
    chmod +x "$script_path" 2>/dev/null || true
    if [[ $script_path != "${PLATFORM_DIR}/"* ]]; then
        info "Running: $script_path $*"
    fi
    exec "$script_path" "$@"
}

has_rootfs_override() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--rootfs" ]]; then
            return 0
        fi
    done
    return 1
}

run_parallel_targets() {
    local group="$1"
    local action="$2"
    shift 2
    local targets=()
    local target_args=()
    local target
    local pid
    local status
    local failed=0
    local failed_targets=()
    local log_dir
    log_dir="$(new_log_dir "${group}" "${action}" "")"
    local summary_log="${log_dir}/summary.log"

    while [[ "$#" -gt 0 && "$1" != "--" ]]; do
        targets+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] || { error "Missing run_parallel_targets separator"; exit 1; }
    shift
    target_args=("$@")

    mkdir -p "$log_dir"
    : >"$summary_log"

    log_summary "$summary_log" INFO 'START %s %s' "$group" "$action"
    log_summary "$summary_log" INFO 'Log directory: %s' "$log_dir"
    log_summary "$summary_log" INFO 'Targets: %s' "${targets[*]}"
    log_summary "$summary_log" INFO 'Arguments: %s' "${target_args[*]:-(none)}"

    local pids=()
    local pid_targets=()
    local pid_logs=()
    local pid_status_files=()
    local pid_start_times=()
    local pid_progress_files=()
    local pid_progress_lines=()
    local pid_arches=()
    local pid_arch_start_times=()
    local now child_index=0 child_jobs parallel_limit
    parallel_limit=$(build_parallel_limit "${#targets[@]}") || return
    for target in "${targets[@]}"; do
        local target_log="${log_dir}/${target}.log"
        local status_file="${log_dir}/${target}.status"
        local progress_file="${log_dir}/${target}.progress"
        local command=("$0" "$group" "$target" "${target_args[@]}")
        rm -f "${status_file}"
        : >"$progress_file"
        log_summary "$summary_log" INFO 'QUEUE %s: %s' "$target" "$target_log"
        build_wait_slot "$parallel_limit" "${pids[@]}"
        child_jobs=$(build_child_jobs "$parallel_limit" "$child_index") || return
        child_index=$((child_index + 1))
        (
            export TGOS_BUILD_JOB_BUDGET="$child_jobs"
            set +e
            {
                log_format INFO 'START %s %s' "$group" "$target"
                printf 'cwd=%s\n' "$(pwd)"
                printf 'command='
                printf '%q ' "${command[@]}"
                printf '\n\n'
                LOG_FILE="$target_log" LOG_TO_STDERR=1 LOG_STDIO_CAPTURED=1 BUILD_PROGRESS_FILE="$progress_file" "${command[@]}"
                status=$?
                log_format INFO 'END %s %s status=%s' "$group" "$target" "$status"
                printf '%s\n' "$status" >"${status_file}"
                exit "$status"
            } >>"$target_log" 2>&1
        ) &
        pid=$!
        pids+=("$pid")
        pid_targets+=("$target")
        pid_logs+=("$target_log")
        pid_status_files+=("$status_file")
        pid_start_times+=("$(date '+%s')")
        pid_progress_files+=("$progress_file")
        pid_progress_lines+=(0)
        pid_arches+=("")
        pid_arch_start_times+=(0)
        log_summary "$summary_log" INFO 'STARTED %s: pid=%s' "$target" "$pid"
    done

    local remaining="${#pids[@]}"
    local heartbeat_interval="${PARALLEL_HEARTBEAT_INTERVAL:-60}"
    local next_heartbeat=$(( $(date '+%s') + heartbeat_interval ))
    local i
    local target_finished entry arch arch_started display_target elapsed
    local progress_entries=()
    while [[ "${remaining}" -gt 0 ]]; do
        local progressed=0
        for i in "${!pids[@]}"; do
            [[ -n "${pids[$i]:-}" ]] || continue
            # Observe completion first, then drain progress: a fast final
            # transition must be included when reporting a failed target.
            target_finished=0
            [[ ! -f "${pid_status_files[$i]}" ]] || target_finished=1
            if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                target_finished=1
            fi
            mapfile -t -s "${pid_progress_lines[$i]}" progress_entries <"${pid_progress_files[$i]}"
            pid_progress_lines[$i]=$((pid_progress_lines[$i] + ${#progress_entries[@]}))
            for entry in "${progress_entries[@]}"; do
                read -r arch arch_started <<<"$entry"
                [[ $arch =~ ^[a-zA-Z0-9_-]+$ && $arch_started =~ ^[0-9]+$ ]] || continue
                pid_arches[$i]=$arch
                pid_arch_start_times[$i]=$arch_started
                log_summary "$summary_log" INFO 'BUILDING %s/%s' "${pid_targets[$i]}" "$arch"
            done
            [[ $target_finished -eq 1 ]] || continue
            pid="${pids[$i]}"
            target="${pid_targets[$i]}"
            target_log="${pid_logs[$i]}"
            build_reap_task "$pid" "${pid_status_files[$i]}" status
            rm -f "${pid_status_files[$i]}" "${pid_progress_files[$i]}"
            unset 'pids[i]'
            progressed=1
            if [[ "${status}" -eq 0 ]]; then
                log_summary "$summary_log" SUCCESS 'DONE %s: log=%s' "$target" "$target_log"
            else
                failed=1
                display_target="$target${pid_arches[$i]:+/${pid_arches[$i]}}"
                failed_targets+=("$display_target")
                log_summary "$summary_log" ERROR 'FAILED %s: status=%s log=%s' "$display_target" "$status" "$target_log"
                log_failure_tail "$summary_log" "$display_target" "$target_log"
            fi
            remaining=$((remaining - 1))
        done

        now="$(date '+%s')"
        if [[ "${remaining}" -gt 0 && "${now}" -ge "${next_heartbeat}" ]]; then
            local running=()
            for i in "${!pids[@]}"; do
                [[ -n "${pids[$i]:-}" ]] || continue
                display_target=${pid_targets[$i]}
                elapsed=$((now - pid_start_times[$i]))
                if [[ -n ${pid_arches[$i]} ]]; then
                    display_target+="/${pid_arches[$i]}"
                    elapsed=$((now - pid_arch_start_times[$i]))
                fi
                running+=("${display_target}:${elapsed}s")
            done
            log_summary "$summary_log" INFO 'RUNNING %s %s: %s' "$group" "$action" "${running[*]}"
            next_heartbeat=$((now + heartbeat_interval))
        fi

        [[ "${remaining}" -eq 0 || "${progressed}" -eq 1 ]] || sleep 1
    done

    if [[ "$failed" -eq 0 ]]; then
        log_summary "$summary_log" SUCCESS 'COMPLETE %s %s: all targets finished successfully' "$group" "$action"
    else
        log_summary "$summary_log" ERROR 'COMPLETE %s %s: failed targets=%s' "$group" "$action" "${failed_targets[*]}"
    fi
    log_summary "$summary_log" INFO 'Summary log: %s' "$summary_log"

    return "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true

    case "$cmd" in
        help|-h|--help|"")
            usage
            exit 0
            ;;
        phytiumpi|roc-rk3568-pc|evm3588|tac-e400-plc|orangepi-5-plus|rdk-s100p|bst-a1000|qemu|qemu-aarch64|qemu-x86_64|qemu-riscv64|qemu-loongarch64)
            exec "$0" platform "$cmd" "$@"
            ;;
        platform)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { error "Missing platform target"; usage; exit 2; }
            case "$target" in
                phytiumpi|roc-rk3568-pc|evm3588|tac-e400-plc|orangepi-5-plus|rdk-s100p|bst-a1000)
                    script_path="${PLATFORM_DIR}/${target}.sh"
                    run_checked_script "$script_path" "$@"
                    ;;
                qemu|qemu-aarch64|qemu-x86_64|qemu-riscv64|qemu-loongarch64)
                    script_path="${PLATFORM_DIR}/qemu.sh"
                    qemu_args=("$@")
                    if [[ "$target" == "qemu" ]]; then
                        qemu_cmd="all"
                    else
                        qemu_cmd="${target#qemu-}"
                    fi
                    export QEMU_ARCH="${qemu_cmd}"
                    if [[ "$qemu_cmd" != "all" ]] && ! has_rootfs_override "${qemu_args[@]}"; then
                        if [[ "$qemu_cmd" == "loongarch64" ]]; then
                            qemu_args+=(--rootfs "busybox,alpine")
                        else
                            qemu_args+=(--rootfs "busybox,alpine,debian")
                        fi
                    fi
                    run_checked_script "$script_path" "$qemu_cmd" "${qemu_args[@]}"
                    ;;
                all|clean)
                    if [[ $target == all && ${1:-all} != clean ]]; then
                        platform_graph_help=0
                        for argument in "$@"; do
                            case $argument in help|-h|--help) platform_graph_help=1 ;; esac
                        done
                        if ((platform_graph_help == 0)); then
                            exec python3 "${SCRIPTS_DIR}/lib/platform-graph.py" all "$@"
                        fi
                    fi
                    platform_targets=(phytiumpi roc-rk3568-pc evm3588 tac-e400-plc orangepi-5-plus rdk-s100p bst-a1000 qemu)
                    extra_args=("$@")
                    if [[ $target == clean ]]; then
                        extra_args=(clean)
                    elif [[ ${#extra_args[@]} -eq 0 ]]; then
                        extra_args=(all)
                    fi
                    platform_batch_target() {
                        local platform=$1
                        shift
                        bash "$0" platform "$platform" "$@"
                    }
                    run_sequential_targets platform "platform $target" platform_batch_target "${platform_targets[@]}" -- "${extra_args[@]}"
                    ;;
                *)
                    error "Unknown platform target: $target"
                    usage
                    exit 2
                    ;;
            esac
            ;;
        os)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { error "Missing OS target"; usage; exit 2; }
            case "$target" in
                all)
                    os_args=("$@")
                    if [[ ${#os_args[@]} -eq 0 ]]; then
                        os_args=("all")
                    fi
                    run_parallel_targets "os" "all" arceos zephyr freertos rtthread -- "${os_args[@]}" || exit 1
                    ;;
                clean)
                    run_parallel_targets "os" "clean" arceos zephyr freertos rtthread -- clean || exit 1
                    ;;
                arceos|starry|zephyr|freertos|rtthread)
                    script_path="${OS_DIR}/${target}.sh"
                    run_checked_script "$script_path" "$@"
                    ;;
                *)
                    error "Unknown independent OS target: $target"
                    usage
                    exit 2
                    ;;
            esac
            ;;
        rootfs)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { error "Missing rootfs target"; usage; exit 2; }
            case "$target" in
                all)
                    rootfs_args=("$@")
                    if [[ ${#rootfs_args[@]} -eq 0 ]]; then
                        rootfs_args=("all")
                    fi
                    run_parallel_targets "rootfs" "all" busybox alpine debian -- "${rootfs_args[@]}" || exit 1
                    ;;
                clean)
                    rootfs_args=("$@")
                    run_parallel_targets "rootfs" "clean" busybox alpine debian -- clean "${rootfs_args[@]}" || exit 1
                    ;;
                busybox|alpine|debian)
                    script_path="${ROOTFS_DIR}/${target}.sh"
                    run_checked_script "$script_path" "$@"
                    ;;
                *)
                    error "Unknown rootfs target: $target"
                    usage
                    exit 2
                    ;;
            esac
            ;;
        release)
            subcmd="${1:-pack}"
            shift || true
            case "$subcmd" in
                pack)
                    run_checked_script "${TOOLS_DIR}/pack.sh" "$@"
                    ;;
                github)
                    run_checked_script "${TOOLS_DIR}/github.sh" "$@"
                    ;;
                *)
                    error "Unknown release subcommand: $subcmd"
                    usage
                    exit 2
                    ;;
            esac
            ;;
        cleanall|distclean)
            info "CLEANALL: Removing build, IMAGES and release directories"
            rm -rf build IMAGES release
            info "CLEANALL: Removed all directories"
            ;;
        *)
            error "Unknown command or target: $cmd"
            usage
            exit 2
            ;;
    esac
fi
