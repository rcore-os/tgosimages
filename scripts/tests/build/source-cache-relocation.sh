#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export LOG_CREATE_DEFAULT_FILE=0
export BUILD_WORK_DIR="$work/workspace"
source "$root/scripts/lib/utils.sh"

upstream="$work/upstream"
patches="$work/patches"
git init -q -b dev "$upstream"
printf 'base\n' >"$upstream/config.toml"
git -C "$upstream" add .
git -C "$upstream" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm base
old_base=$(git -C "$upstream" rev-parse HEAD)
mkdir "$patches"
printf 'patched\n' >"$upstream/config.toml"
git -C "$upstream" diff >"$patches/01.patch"
git -C "$upstream" restore config.toml
git clone -q "$upstream" "$work/source"
prepare_patched_source "$work/source" "$old_base" "$patches"

# Moving a prepared workspace changes its absolute-path fingerprint.
cp -a "$work/source" "$work/relocated"
printf 'upstream update\n' >"$upstream/new-file"
git -C "$upstream" add .
git -C "$upstream" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm update
new_base=$(git -C "$upstream" rev-parse HEAD)
git -C "$work/relocated" fetch -q origin dev
prepare_patched_source "$work/relocated" "$new_base" "$patches"
[[ $(git -C "$work/relocated" rev-parse HEAD) == "$new_base" ]]
[[ $(cat "$work/relocated/config.toml") == patched ]]
[[ $(cat "$work/relocated/new-file") == 'upstream update' ]]
printf 'PASS: relocated owned patches can advance to a new upstream base\n'

# Extra local changes must never become owned patches.
cp -a "$work/relocated" "$work/edited"
printf 'user edit\n' >"$work/edited/config.toml"
if prepare_patched_source "$work/edited" "$new_base" "$patches"; then
    printf 'unverified user edit was discarded\n' >&2
    exit 1
fi
[[ $(cat "$work/edited/config.toml") == 'user edit' ]]
[[ $(git -C "$work/edited" rev-parse HEAD) == "$new_base" ]]
printf 'PASS: relocated user edits are rejected and preserved\n'
cp -a "$work/relocated" "$work/untracked"
printf 'user data\n' >"$work/untracked/user-file"
if prepare_patched_source "$work/untracked" "$new_base" "$patches"; then
    printf 'unverified untracked file was discarded\n' >&2
    exit 1
fi
[[ $(cat "$work/untracked/user-file") == 'user data' ]]
printf 'PASS: relocated untracked files are rejected and preserved\n'

# Managed build caches discard residual changes and reapply the same patch.
cp -a "$work/relocated" "$BUILD_DIR/managed"
printf staged >"$BUILD_DIR/managed/config.toml"
git -C "$BUILD_DIR/managed" add config.toml
printf extra >"$BUILD_DIR/managed/extra-file"
prepare_patched_source "$BUILD_DIR/managed" "$new_base" "$patches" reset
[[ $(cat "$BUILD_DIR/managed/config.toml") == patched ]]
[[ ! -e $BUILD_DIR/managed/extra-file ]]
[[ -z $(git -C "$BUILD_DIR/managed" diff --cached --name-only) ]]
if prepare_patched_source "$work/edited" "$new_base" "$patches" reset; then
    printf 'reset accepted source outside build directory\n' >&2
    exit 1
fi
[[ $(cat "$work/edited/config.toml") == 'user edit' ]]
printf 'PASS: managed reruns discard residue and reapply patches inside build only\n'
