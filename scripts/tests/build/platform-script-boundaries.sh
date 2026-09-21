#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/rtthread/bsp/phytium/aarch64" "$fixture/sdk" "$fixture/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$PWD" > "$BOUNDARY_PROBE"\n' > "$fixture/bin/scons"
chmod +x "$fixture/bin/scons"
BOUNDARY_PROBE="$fixture/rtthread-path" BUILD_CACHE=0 PATH="$fixture/bin:$PATH" \
    bash "$root/scripts/os/rtthread.sh" phytiumpi --src-dir "$fixture/rtthread" \
    --images-dir "$fixture/images" -c
[[ $(<"$fixture/rtthread-path") == "$fixture/rtthread/bsp/phytium/aarch64" ]]

printf '#!/bin/sh\ncommand -v python2 > "$BOUNDARY_PROBE"\ncommand -v python > "$BOUNDARY_PYTHON_PROBE"\ncat >/dev/null\n' > "$fixture/sdk/build.sh"
chmod +x "$fixture/sdk/build.sh"
existing_python=$(command -v python || true)
assert_python_path() {
    local resolved
    resolved=$(<"$1")
    if [[ -n $existing_python ]]; then
        [[ $resolved == "$existing_python" ]]
    else
        [[ $resolved == *tgosimages-python2* ]]
    fi
}
BOUNDARY_PROBE="$fixture/firefly-python2" BOUNDARY_PYTHON_PROBE="$fixture/firefly-python" \
    bash "$root/scripts/lib/firefly-sdk-build.sh" "$fixture/sdk" all
[[ $(<"$fixture/firefly-python2") == *tgosimages-python2* ]]
assert_python_path "$fixture/firefly-python"

mkdir -p "$fixture/evm sdk"
printf '#!/usr/bin/env bash\nprintf "%%s\\0" "$@" >"$BOUNDARY_REMOTE_PROBE"\n' \
    >"$fixture/evm sdk/build.sh"
chmod +x "$fixture/evm sdk/build.sh"
source "$root/scripts/lib/utils.sh"
source "$root/scripts/platform/evm3588.sh"
ssh() {
    [[ $1 == fixture-host && $# -eq 2 ]]
    bash -c "$2"
}
BOUNDARY_REMOTE_PROBE="$fixture/evm-remote-argv"
export BOUNDARY_REMOTE_PROBE
run_evm3588_remote_sdk fixture-host "$fixture/evm sdk" \
    'argument with spaces' 'semi;colon' '*literal*'
mapfile -d '' -t remote_argv <"$BOUNDARY_REMOTE_PROBE"
[[ ${#remote_argv[@]} -eq 3 ]]
[[ ${remote_argv[0]} == 'argument with spaces' ]]
[[ ${remote_argv[1]} == 'semi;colon' ]]
[[ ${remote_argv[2]} == '*literal*' ]]
BOUNDARY_PROBE="$fixture/firefly-python2" BOUNDARY_PYTHON_PROBE="$fixture/firefly-python" \
    bash -s -- "$fixture/sdk" all < "$root/scripts/lib/firefly-sdk-build.sh"
assert_python_path "$fixture/firefly-python"
