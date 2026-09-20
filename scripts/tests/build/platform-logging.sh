#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/repo/scripts/platform" "$work/repo/scripts/lib"
cp "$repo_root/scripts/lib/"{utils,platform-log,log,build-performance,build-paths,build-workspace}.sh "$work/repo/scripts/lib/"
cp "$repo_root/scripts/lib/log-color.awk" "$work/repo/scripts/lib/"
cat >"$work/repo/scripts/platform/fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd -P)
source "$SCRIPT_DIR/../lib/platform-log.sh"
platform_log_init "$@"
source "$SCRIPT_DIR/../lib/utils.sh"
step() {
    printf 'raw-before\n'
    info 'step-message'
    bash -c 'source "$1"; info nested-message; printf "nested-raw\n"' _ "$SCRIPT_DIR/utils.sh"
    printf 'raw-after\n'
}
broken() { info 'broken-step'; return 7; }
case ${1:-} in
    early) printf 'early-failure\n'; exit 9 ;;
esac
printf 'serial-before\n'
if [[ ${1:-} == parallel-fail ]]; then
    run_parallel_functions all step broken --
else
    run_parallel_functions all step --
fi
printf 'serial-after\n'
if [[ ${1:-} == late ]]; then
    printf 'late-failure\n' >&2
    exit 8
fi
EOF

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
fixture="$work/repo/scripts/platform/fixture.sh"
export LOG_DIR="$work/logs"
unset LOG_FILE LOG_STDIO_CAPTURED PLATFORM_LOG_RUN_DIR LOG_CREATE_DEFAULT_FILE
for scenario in ok early late parallel-fail; do
    status=0
    bash "$fixture" "$scenario" >"$work/console" 2>&1 || status=$?
    case $scenario in
        ok) expected=0 ;;
        early) expected=9 ;;
        late) expected=8 ;;
        parallel-fail) expected=1 ;;
    esac
    [[ $status == "$expected" ]] || fail "$scenario exit status: $status"
    runs=("$LOG_DIR"/fixture-"$scenario"-*)
    [[ ${#runs[@]} == 1 && -d ${runs[0]} ]] || fail "$scenario run directory"
    run=${runs[0]}
    grep -Fq "status=$expected" "$run/summary.log" || fail "$scenario summary status"
    if [[ $scenario == ok ]]; then
        step_logs=("$run"/steps/*/step.log)
        for marker in raw-before step-message nested-message nested-raw raw-after; do
            [[ $(grep -c "$marker" "${step_logs[0]}") == 1 ]] || fail "$scenario missing/duplicate $marker"
        done
        grep -q serial-before "$run/build.log" || fail 'serial stage missing'
    fi
    if [[ $scenario == late ]]; then
        grep -q late-failure "$run/build.log" || fail 'postprocessing failure missing'
        ! grep -q 'all stages finished successfully' "$run/summary.log" || fail 'false overall success'
    fi
    printf 'PASS: %s\n' "$scenario"
done

# Each platform entry point must route through the common logger; help must
# remain safe to run without starting builds or creating default log files.
for script in "$repo_root"/scripts/platform/*.sh; do
    LOG_DIR="$work/help-logs" bash "$script" --help >"$work/help" 2>&1
done
[[ ! -e $work/help-logs ]] || fail 'platform help created logs'
printf 'PASS: platform help\n'
