#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
work=$(mktemp -d /tmp/rootfs-progress.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
fixture="$work/repo"
mkdir -p "$fixture/scripts/lib" "$fixture/scripts/rootfs" "$fixture/scripts/os"
cp "$repo_root/build.sh" "$fixture/build.sh"
cp "$repo_root/scripts/lib/utils.sh" "$fixture/scripts/lib/utils.sh"
export PROGRESS_TEST_REPO="$repo_root"
export LOG_DIR="$work/logs"
export LOG_CREATE_DEFAULT_FILE=0 PARALLEL_HEARTBEAT_INTERVAL=1

fail() { printf 'not ok - %s\n' "$*" >&2; cat "$work/console" >&2; exit 1; }

# Exercise the real builder entry points, failing before expensive test builds.
for kind in busybox alpine debian; do
    cat >"$fixture/scripts/rootfs/$kind.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
kind=${0##*/}
kind=${kind%.sh}
source "$PROGRESS_TEST_REPO/scripts/rootfs/$kind.sh"
debian_init_config() { :; }
alpine_init_config() { :; }
alpine_validate_legacy_ltp_environment() { :; }
rootfs_builder_load_test_options() { exit 42; }
MKFS_ARCH=$1 ALPINE_ARCH=$1 DEBIAN_ARCH=$1
case $kind in
    busybox) mkfs ;;
    alpine) alpine ;;
    debian) debian ;;
esac
EOF
done

status=0
"$fixture/build.sh" rootfs all riscv64 >"$work/console" 2>&1 || status=$?
[[ $status == 1 ]] || fail 'rootfs all must propagate a builder failure'
for kind in busybox alpine debian; do
    grep -Eq "FAILED $kind/riscv64: status=42" "$work/console" ||
        fail "$kind must report its architecture even when preparation fails"
done
printf 'ok - all three real builders report the architecture before preparation\n'

# Fast transitions must survive polling, and concurrent builders must keep
# independent architectures. Wait for observable heartbeats instead of guessing
# how long the parent will take to read progress.
for kind in busybox alpine debian; do
    cat >"$fixture/scripts/rootfs/$kind.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/utils.sh"
kind=${0##*/}
kind=${kind%.sh}
arch=${1:-all}
if [[ $arch == all ]]; then
    report_build_arch aarch64
    arch=riscv64
fi
report_build_arch "$arch"
touch "$LOG_DIR/$kind.started"
deadline=$((SECONDS + 10))
while :; do
    ready=1
    for peer in busybox alpine debian; do
        [[ -f $LOG_DIR/$peer.started ]] || ready=0
    done
    if ((ready)) && grep -Eq "RUNNING rootfs all:.*$kind/$arch:[0-9]+s" "$(dirname "$LOG_FILE")/summary.log"; then
        break
    fi
    ((SECONDS < deadline)) || exit 43
    sleep 0.05
done
if [[ $kind == debian ]]; then
    report_build_arch x86_64
    printf 'diagnostic fixture for debian/x86_64\n' >&2
    exit 42
fi
EOF
done

status=0
"$fixture/build.sh" rootfs all >"$work/console" 2>&1 || status=$?
[[ $status == 1 ]] || fail 'mixed results must return failure'
for kind in busybox alpine debian; do
    grep -Fq "BUILDING $kind/aarch64" "$work/console" || fail "$kind initial architecture is missing"
    grep -Fq "BUILDING $kind/riscv64" "$work/console" || fail "$kind architecture transition is missing"
    grep -Eq "RUNNING rootfs all:.*$kind/riscv64:[0-9]+s" "$work/console" || fail "$kind heartbeat architecture is missing"
done
grep -Fq 'DONE busybox:' "$work/console" || fail 'BusyBox did not finish concurrently'
grep -Fq 'DONE alpine:' "$work/console" || fail 'Alpine did not finish concurrently'
grep -Fq 'FAILED debian/x86_64: status=42' "$work/console" || fail 'failure must include the final architecture'
grep -Fq 'diagnostic fixture for debian/x86_64' "$work/console" || fail 'failure excerpt must reach the terminal'
grep -Fq 'diagnostic fixture for debian/x86_64' "$LOG_DIR"/*/summary.log || fail 'failure excerpt must reach the summary log'
printf 'ok - concurrent progress includes transitions, heartbeats, and the failed architecture\n'

status=0
"$fixture/build.sh" rootfs all loongarch64 >"$work/console" 2>&1 || status=$?
[[ $status == 1 ]] || fail 'single-architecture failure must propagate'
grep -Eq 'RUNNING rootfs all:.*busybox/loongarch64:[0-9]+s' "$work/console" || fail 'explicit architecture is missing'
printf 'ok - explicit architecture is reported\n'

# Targets that do not report architectures retain the existing summary format.
for kind in arceos zephyr freertos rtthread; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fixture/scripts/os/$kind.sh"
done
"$fixture/build.sh" os clean >"$work/console" 2>&1 || fail 'OS clean regressed'
for kind in arceos zephyr freertos rtthread; do
    grep -Fq "DONE $kind:" "$work/console" || fail "$kind summary changed"
done
printf 'ok - targets without architecture progress keep their existing summaries\n'
