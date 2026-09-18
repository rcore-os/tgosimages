#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fixture=$work/repo
mkdir -p "$fixture/scripts/platform" "$fixture/scripts/lib"
cp "$repo_root/build.sh" "$fixture/build.sh"
cp "$repo_root/scripts/lib/"*.sh "$fixture/scripts/lib/"
for platform in phytiumpi roc-rk3568-pc evm3588 tac-e400-plc orangepi-5-plus rdk-s100p bst-a1000; do
    cat >"$fixture/scripts/platform/$platform.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name=${0##*/}
printf 'compiler-output %s\n' "$name"
printf '<%s>\n' "$@"
[[ ${FAIL_TARGET:-} != "${name%.sh}" ]] || exit 23
EOF
done
# Keep the real QEMU batch dispatcher and replace only actual architecture
# builds, which would otherwise download sources and compile images.
python3 - "$repo_root/scripts/platform/qemu.sh" "$fixture/scripts/platform/qemu.sh" <<'PY'
import sys
from pathlib import Path
s = Path(sys.argv[1]).read_text()
marker = 'if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then'
stub = '''case ${1:-} in
    aarch64|riscv64|x86_64|loongarch64)
        printf 'compiler-output qemu-%s\\n' "$1"
        printf '<%s>\\n' "$@"
        [[ ${FAIL_TARGET:-} != qemu-$1 ]] || exit 23
        exit 0
        ;;
esac
'''
assert s.count(marker) == 1
Path(sys.argv[2]).write_text(s.replace(marker, stub + marker))
PY
export LOG_DIR="$work/logs"
unset LOG_CREATE_DEFAULT_FILE LOG_FILE PLATFORM_LOG_RUN_DIR LOG_STDIO_CAPTURED
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for batch in platform qemu; do
    if [[ $batch == platform ]]; then
        command=(bash "$fixture/build.sh" platform all)
        first=phytiumpi count=11
    else
        command=(bash "$fixture/build.sh" platform qemu all)
        first=qemu-aarch64 count=4
    fi
    "${command[@]}" >"$work/$batch.console" 2>&1
    [[ $(grep -c '] STARTED ' "$work/$batch.console") == "$count" ]] || fail "$batch target count"
    [[ $(grep -c '] DONE ' "$work/$batch.console") == "$count" ]] || fail "$batch completion count"
    ! grep -q compiler-output "$work/$batch.console" || fail "$batch leaked verbose output"
    grep -q "COMPLETE $batch all: all targets finished successfully" "$work/$batch.console" || fail "$batch summary"
    status=0
    FAIL_TARGET=$first "${command[@]}" >"$work/$batch.failed" 2>&1 || status=$?
    [[ $status == 1 ]] || fail "$batch failure exit"
    grep -q "FAILED $first: status=23 log=" "$work/$batch.failed" || fail "$batch failure message"
    grep -q compiler-output "$work/$batch.failed" || fail "$batch failure excerpt"
    [[ $(grep -c '] STARTED ' "$work/$batch.failed") == 1 ]] || fail "$batch failed to stop after failure"
    printf 'PASS: %s batch success/failure display\n' "$batch"
done
