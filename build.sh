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
    printf '%s\n' "  all                  -> build all platform targets sequentially with rootfs and all os if applicable"
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
    [[ -f "$script_path" ]] || { echo "[ERROR] Script not found: $script_path" >&2; exit 1; }
    chmod +x "$script_path" 2>/dev/null || true
    echo "Running: $script_path $*"
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
    [[ "${1:-}" == "--" ]] || { echo "[ERROR] Missing run_parallel_targets separator" >&2; exit 1; }
    shift
    target_args=("$@")

    mkdir -p "$log_dir"
    : >"$summary_log"

    printf '[%s] START %s %s\n' "$(date '+%F %T')" "$group" "$action" | tee -a "$summary_log"
    printf '[%s] Log directory: %s\n' "$(date '+%F %T')" "$log_dir" | tee -a "$summary_log"
    printf '[%s] Targets: %s\n' "$(date '+%F %T')" "${targets[*]}" | tee -a "$summary_log"
    printf '[%s] Arguments: %s\n' "$(date '+%F %T')" "${target_args[*]:-(none)}" | tee -a "$summary_log"

    local pids=()
    local pid_targets=()
    local pid_logs=()
    local pid_status_files=()
    local pid_start_times=()
    local now
    for target in "${targets[@]}"; do
        local target_log="${log_dir}/${target}.log"
        local status_file="${log_dir}/${target}.status"
        local command=("$0" "$group" "$target" "${target_args[@]}")
        rm -f "${status_file}"
        printf '[%s] QUEUE %s: %s\n' "$(date '+%F %T')" "$target" "$target_log" | tee -a "$summary_log"
        (
            set +e
            {
                printf '[%s] START %s %s\n' "$(date '+%F %T')" "$group" "$target"
                printf 'cwd=%s\n' "$(pwd)"
                printf 'command='
                printf '%q ' "${command[@]}"
                printf '\n\n'
                LOG_FILE="$target_log" LOG_TO_STDERR=0 "${command[@]}"
                status=$?
                printf '\n[%s] END %s %s status=%s\n' "$(date '+%F %T')" "$group" "$target" "$status"
                printf '%s\n' "$status" >"${status_file}"
                exit "$status"
            } >"$target_log" 2>&1
        ) &
        pid=$!
        pids+=("$pid")
        pid_targets+=("$target")
        pid_logs+=("$target_log")
        pid_status_files+=("$status_file")
        pid_start_times+=("$(date '+%s')")
        printf '[%s] STARTED %s: pid=%s\n' "$(date '+%F %T')" "$target" "$pid" | tee -a "$summary_log"
    done

    local remaining="${#pids[@]}"
    local heartbeat_interval="${PARALLEL_HEARTBEAT_INTERVAL:-30}"
    local next_heartbeat=$(( $(date '+%s') + heartbeat_interval ))
    local i
    while [[ "${remaining}" -gt 0 ]]; do
        local progressed=0
        for i in "${!pids[@]}"; do
            [[ -n "${pids[$i]:-}" ]] || continue
            [[ -f "${pid_status_files[$i]}" ]] || continue
            pid="${pids[$i]}"
            target="${pid_targets[$i]}"
            target_log="${pid_logs[$i]}"
            status="$(<"${pid_status_files[$i]}")"
            wait "$pid" 2>/dev/null || true
            rm -f "${pid_status_files[$i]}"
            unset 'pids[i]'
            progressed=1
            if [[ "${status}" -eq 0 ]]; then
                printf '[%s] DONE %s: log=%s\n' "$(date '+%F %T')" "$target" "$target_log" | tee -a "$summary_log"
            else
                failed=1
                failed_targets+=("$target")
                printf '[%s] FAILED %s: status=%s log=%s\n' "$(date '+%F %T')" "$target" "$status" "$target_log" | tee -a "$summary_log"
            fi
            remaining=$((remaining - 1))
        done

        now="$(date '+%s')"
        if [[ "${remaining}" -gt 0 && "${now}" -ge "${next_heartbeat}" ]]; then
            local running=()
            for i in "${!pids[@]}"; do
                [[ -n "${pids[$i]:-}" ]] || continue
                running+=("${pid_targets[$i]}:$((now - pid_start_times[$i]))s")
            done
            printf '[%s] RUNNING %s %s: %s\n' "$(date '+%F %T')" "$group" "$action" "${running[*]}" | tee -a "$summary_log"
            next_heartbeat=$((now + heartbeat_interval))
        fi

        [[ "${remaining}" -eq 0 || "${progressed}" -eq 1 ]] || sleep 1
    done

    if [[ "$failed" -eq 0 ]]; then
        printf '[%s] COMPLETE %s %s: all targets finished successfully\n' "$(date '+%F %T')" "$group" "$action" | tee -a "$summary_log"
    else
        printf '[%s] COMPLETE %s %s: failed targets=%s\n' "$(date '+%F %T')" "$group" "$action" "${failed_targets[*]}" | tee -a "$summary_log"
    fi
    printf '[%s] Summary log: %s\n' "$(date '+%F %T')" "$summary_log" | tee -a "$summary_log"

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
            [[ -n "$target" ]] || { echo "[ERROR] Missing platform target" >&2; usage; exit 2; }
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
                all)
                    extra_args=("$@")
                    for p in phytiumpi roc-rk3568-pc evm3588 tac-e400-plc orangepi-5-plus rdk-s100p bst-a1000 qemu-aarch64 qemu-x86_64 qemu-riscv64 qemu-loongarch64; do
                        if [[ ${#extra_args[@]} -eq 0 ]]; then
                            echo "Building: $p all"
                            "$0" platform "$p" all || { echo "[ERROR] $p build failed" >&2; exit 1; }
                        else
                            echo "Building: $p ${extra_args[*]}"
                            "$0" platform "$p" "${extra_args[@]}" || { echo "[ERROR] $p build failed" >&2; exit 1; }
                        fi
                    done
                    ;;
                clean)
                    for p in phytiumpi roc-rk3568-pc evm3588 tac-e400-plc orangepi-5-plus rdk-s100p bst-a1000 qemu-aarch64 qemu-x86_64 qemu-riscv64 qemu-loongarch64; do
                        echo "Cleaning: $p"
                        "$0" platform "$p" clean || { echo "[ERROR] $p clean failed" >&2; exit 1; }
                    done
                    ;;
                *)
                    echo "[ERROR] Unknown platform target: $target" >&2
                    usage
                    exit 2
                    ;;
            esac
            ;;
        os)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { echo "[ERROR] Missing OS target" >&2; usage; exit 2; }
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
                    echo "[ERROR] Unknown independent OS target: $target" >&2
                    usage
                    exit 2
                    ;;
            esac
            ;;
        rootfs)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { echo "[ERROR] Missing rootfs target" >&2; usage; exit 2; }
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
                    echo "[ERROR] Unknown rootfs target: $target" >&2
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
                    echo "[ERROR] Unknown release subcommand: $subcmd" >&2
                    usage
                    exit 2
                    ;;
            esac
            ;;
        cleanall|distclean)
            echo "[CLEANALL] Removing build, IMAGES and release directories"
            rm -rf build IMAGES release
            echo "[CLEANALL] Removed all directories"
            ;;
        *)
            echo "[ERROR] Unknown command or target: $cmd" >&2
            usage
            exit 2
            ;;
    esac
fi
