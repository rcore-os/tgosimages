#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export LOG_CREATE_DEFAULT_FILE=0
upstream="$work/upstream"
git init -q -b dev "$upstream"
printf 'base\n' >"$upstream/value"
git -C "$upstream" add .
git -C "$upstream" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm base
base=$(git -C "$upstream" rev-parse HEAD)
mkdir "$work/patches"
printf 'patched\n' >"$upstream/value"
git -C "$upstream" diff >"$work/patches/01.patch"
git -C "$upstream" restore value
for name in arceos zephyr rtthread; do
    prefix=${name^^}
    env BUILD_WORK_DIR="$work/$name" "${prefix}_REPO_URL=$upstream" \
        "${prefix}_REF=$base" "${prefix}_PATCH_DIR=$work/patches" \
        bash -s -- "$root" "$name" "$prefix" "$upstream" <<'TEST'
set -euo pipefail
unset "${3}_SRC_DIR"
source "$1/scripts/os/$2.sh"
arceos_build() { :; }
rtthread_build() { :; }
prepare() {
    case $2 in
        arceos) arceos ;;
        rtthread) rtthread ;;
        zephyr) prepare_zephyr_source ;;
    esac
}
prepare "$@"
source_var="${3}_SRC_DIR"
managed=${!source_var}
[[ $(cat "$managed/value") == patched ]]
printf residue >"$managed/value"
git -C "$managed" add value
printf extra >"$managed/extra-file"
prepare "$@"
[[ $(cat "$managed/value") == patched ]]
[[ ! -e $managed/extra-file ]]
[[ -z $(git -C "$managed" diff --cached --name-only) ]]

# A caller-selected checkout inside build must still be preserved.
selected="$BUILD_DIR/selected"
git clone -q "$4" "$selected"
printf caller >"$selected/value"
printf extra >"$selected/caller-file"
case $2 in
    arceos) arceos_parse_args --src-dir "$selected" ;;
    rtthread) rtthread_parse_args --src-dir "$selected" ;;
    zephyr) zephyr_parse_args --src-dir "$selected" ;;
esac
prepare "$@"
[[ $(cat "$selected/value") == caller ]]
[[ -e $selected/caller-file ]]
# Environment selections obey the same contract.
export "${3}_SRC_DIR=$selected"
source "$1/scripts/os/$2.sh"
arceos_build() { :; }
rtthread_build() { :; }
prepare "$@"
[[ $(cat "$selected/value") == caller ]]
flag="${3}_SOURCE_PROVIDED"
[[ ${!flag} == 1 ]]
printf 'PASS: %s managed cleanup and caller source preservation\n' "$2"
TEST
done

# Both consumers must serialize preparation/use of their shared SDK checkout.
python3 - "$root" "$work" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'scripts/lib/python'))
os.environ['BUILD_WORKSPACE_ROOT'] = str(Path(sys.argv[2]) / 'graph-workspaces')
os.environ['ROOTFS_GRAPH_DISABLE'] = '1'
spec = importlib.util.spec_from_file_location('platform_graph_test', root / 'scripts/lib/python/platform-graph.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
declaration = json.loads((root / 'scripts/lib/platform-tasks.json').read_text())['orangepi-5-plus']
graph = module.board_graph('orangepi-5-plus',
                          dict(components=['zephyr', 'ivc'], resources=declaration['resources']), ['all'])
resources = {task['id']: task['resources'] for task in graph['tasks']}
assert set(resources['orangepi-5-plus.zephyr']) & set(resources['orangepi-5-plus.ivc'])
print('PASS: platform SDK consumers share an exclusive resource')
PY
