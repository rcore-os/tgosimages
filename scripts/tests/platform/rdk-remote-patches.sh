#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
work=$(mktemp -d /tmp/rdk-remote-patches.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
LOG_CREATE_DEFAULT_FILE=0
source "$repo_root/scripts/lib/utils.sh"
source "$repo_root/scripts/platform/rdk-s100p.sh"

ssh() {
    [[ $1 == fixture-host && $# -eq 2 ]] || return 1
    bash -c "$2"
}

remote="$work/remote sdk"
patch_dir="$work/patches"
mkdir -p "$remote" "$patch_dir"
printf 'old\n' >"$remote/config"
patch_file="$patch_dir/change.patch"
cat >"$patch_file" <<'PATCH'
--- a/config
+++ b/config
@@ -1 +1 @@
-old
+new
PATCH

apply_patches_remote "$patch_dir" fixture-host "$remote"
[[ $(<"$remote/config") == new ]]
[[ $(<"$remote/.patch_stamps/change.patch.sha256") == $(sha256sum "$patch_file" | awk '{print $1}') ]]
apply_patches_remote "$patch_dir" fixture-host "$remote"
[[ $(<"$remote/config") == new ]]

sed -i 's/+new/+other/' "$patch_file"
if apply_patches_remote "$patch_dir" fixture-host "$remote"; then
    printf 'changed remote patch was accepted\n' >&2
    exit 1
fi
[[ $(<"$remote/config") == new ]]

rm "$patch_file"
if apply_patches_remote "$patch_dir" fixture-host "$remote"; then
    printf 'removed remote patch was accepted\n' >&2
    exit 1
fi
[[ $(<"$remote/config") == new ]]

cat >"$patch_file" <<'PATCH'
--- a/config
+++ b/config
@@ -1 +1 @@
-old
+new
PATCH
rm "$remote/.patch_stamps/change.patch.sha256"
apply_patches_remote "$patch_dir" fixture-host "$remote"
[[ $(<"$remote/.patch_stamps/change.patch.sha256") == $(sha256sum "$patch_file" | awk '{print $1}') ]]
rm "$remote/.patch_stamps/change.patch.sha256" "$remote/.patch_stamps/change.patch.applied"
mv "$patch_file" "$patch_dir/change.diff"
patch_file="$patch_dir/change.diff"
apply_patches_remote "$patch_dir" fixture-host "$remote"
[[ $(<"$remote/.patch_stamps/change.diff.sha256") == $(sha256sum "$patch_file" | awk '{print $1}') ]]
mv "$patch_file" "$patch_dir/change.patch"
patch_file="$patch_dir/change.patch"

local_sdk="$work/local sdk"
mkdir -p "$local_sdk"
printf 'old\n' >"$local_sdk/config"
rdk_apply_patches_local_tree "$patch_dir" "$local_sdk"
[[ $(<"$local_sdk/config") == new ]]
rdk_apply_patches_local_tree "$patch_dir" "$local_sdk"

sed -i 's/+new/+other/' "$patch_file"
if rdk_apply_patches_local_tree "$patch_dir" "$local_sdk"; then
    printf 'changed local SDK patch was accepted\n' >&2
    exit 1
fi
[[ $(<"$local_sdk/config") == new ]]

rm "$patch_file"
if rdk_apply_patches_local_tree "$patch_dir" "$local_sdk"; then
    printf 'removed local SDK patch was accepted\n' >&2
    exit 1
fi
[[ $(<"$local_sdk/config") == new ]]

cat >"$patch_file" <<'PATCH'
--- a/config
+++ b/config
@@ -1 +1 @@
-old
+new
PATCH
rm "$local_sdk/.patch_stamps/change.patch.sha256"
rdk_apply_patches_local_tree "$patch_dir" "$local_sdk"
[[ $(<"$local_sdk/.patch_stamps/change.patch.sha256") == $(sha256sum "$patch_file" | awk '{print $1}') ]]
printf 'user edit\n' >"$local_sdk/config"
if rdk_apply_patches_local_tree "$patch_dir" "$local_sdk"; then
    printf 'drifted local SDK patch was accepted\n' >&2
    exit 1
fi
[[ $(<"$local_sdk/config") == 'user edit' ]]

printf 'PASS: RDK remote and local SDK patch content, removal, and drift checks\n'
