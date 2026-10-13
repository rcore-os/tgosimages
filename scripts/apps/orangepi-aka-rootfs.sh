#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
usage() {
    echo "Usage: orangepi-aka-rootfs.sh --base-image PATH --aka-package DIR --output PATH"
    echo "Compose the existing Starry guest ext4 image with AKA under /opt/aka."
    echo "The package must contain calibrated config and required libraries in lib/."
}
base=""; package=""; output=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-image|--aka-package|--output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --base-image) base=$2 ;;
                --aka-package) package=$2 ;;
                --output) output=$2 ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ -f "$base" && -d "$package" && -n "$output" ]] || { usage >&2; exit 2; }
for item in bin/tennis-perception lib/librknnrt.so config/lekiwi_calibration.json config/lekiwi_pick_config.txt models/tennis.rknn run_dual_pick_ci_once.sh; do
    [[ -f "$package/$item" ]] || { echo "Missing AKA payload: $item" >&2; exit 2; }
done
mkdir -p -- "$(dirname -- "$output")"
base=$(realpath "$base"); output=$(realpath -m "$output")
[[ "$base" != "$output" && ! -e "$output" && ! -L "$output" ]] || { echo "Output must be a new image, distinct from base" >&2; exit 2; }
warn() { printf '%s\n' "$*" >&2; }
source "$ROOT_DIR/scripts/lib/rootfs.sh"
source "$ROOT_DIR/scripts/lib/rootfs-compose.sh"
source "$ROOT_DIR/scripts/lib/aka-rootfs.sh"
stage=$(mktemp -d "$(dirname -- "$output")/.aka-rootfs.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
overlay="$stage/overlay"
candidate="$stage/rootfs.img"
mkdir -p "$overlay/opt/aka"
cp -a -- "$package/." "$overlay/opt/aka/"
rootfs_normalize_tree_seconds "$overlay"
cp --preserve=all --reflink=auto --sparse=always -- "$base" "$candidate"
read -r bytes inodes < <(rootfs_overlay_capacity_stats "$overlay")
reserve=$(rootfs_parse_size_bytes "${ORANGEPI_GUEST_FREE_SIZE:-1G}")
_rootfs_resize_for_capacity_in_place "$candidate" "$bytes" "$reserve" "$inodes"
_rootfs_inject_tree_via_debugfs "$candidate" "$overlay"
_rootfs_run_tool '0 1' e2fsck -f -y "$candidate" >/dev/null
aka_validate_guest_image "$candidate"
base_sum=$(sha256sum "$base"); base_sum=${base_sum%% *}
image_sum=$(sha256sum "$candidate"); image_sum=${image_sum%% *}
printf '%s  %s\n%s  %s\n' "$base_sum" "$base" "$image_sum" "$output" >"$stage/sources.sha256"
# A hard link publishes the fully validated image atomically and fails if
# another writer created the output after the initial existence check.
ln -- "$candidate" "$output"
mv -- "$stage/sources.sha256" "$output.sources.sha256"
echo "AKA_ROOTFS_READY image=$output"
