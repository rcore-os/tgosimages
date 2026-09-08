#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
work=$(mktemp -d /tmp/debian-pack-diagnostics.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
export LOG_CREATE_DEFAULT_FILE=0
source "$repo_root/scripts/rootfs/debian.sh"
DEBIAN_ARCH=riscv64 DEBIAN_DOCKER_PLATFORM=linux/riscv64
DEBIAN_DOCKER_IMAGE=debian:test DEBIAN_ROOTFS_IMG="$work/result.img" DEBIAN_IMG_SIZE=12M
mkdir "$work/bin"
export PACK_TEST_WORK="$work"
for tool in apt-get dd mkfs.ext4 mkdir mount cp sync umount rmdir; do
    cat >"$work/bin/$tool" <<'EOF'
#!/usr/bin/env bash
tool=${0##*/}
printf '%s\n' "$tool" >>"$PACK_TEST_WORK/commands"
if [[ $tool == "$PACK_FAIL_TOOL" ]]; then
    printf '%s failure fixture\n' "$tool" >&2
    exit 29
fi
EOF
    chmod +x "$work/bin/$tool"
done

# Execute the actual container shell in a temporary directory with simulated
# tools. The extra bash process preserves container errexit behavior.
docker() {
    while [[ ${1:-} != bash ]]; do shift; done
    shift 2
    local script=$1
    shift
    script=${script/'cd /output'/'cd "$PACK_TEST_WORK"'}
    PATH="$work/bin:$PATH" bash -c "$script" "$@"
}

for tool in dd mount cp; do
    case $tool in
        dd) stage=create-image ;;
        mount) stage=mount-image ;;
        cp) stage=copy-rootfs ;;
    esac
    export PACK_FAIL_TOOL=$tool
    : >"$work/commands"
    status=0
    debian_pack_rootfs_volume fixture-volume "$work/result.img.base.tmp" >"$work/output" 2>&1 || status=$?
    [[ $status == 29 ]] || { printf 'wrong pack status: %s\n' "$status" >&2; exit 1; }
    for text in "$tool failure fixture" 'debian/riscv64' "stage=$stage" 'status=29' 'command='; do
        if ! grep -Fq -- "$text" "$work/output"; then
            printf 'not ok - missing diagnostic: %s\n' "$text" >&2
            cat "$work/output" >&2
            exit 1
        fi
    done
    [[ $(tail -n 1 "$work/commands") == "$tool" ]] || { printf 'packing continued after failure\n' >&2; exit 1; }
    printf 'ok - container %s failure retains output, command, stage, architecture, and status\n' "$tool"
done
