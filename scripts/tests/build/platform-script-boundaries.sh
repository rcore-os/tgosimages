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
BOUNDARY_PROBE="$fixture/firefly-python2" BOUNDARY_PYTHON_PROBE="$fixture/firefly-python" \
    bash "$root/scripts/lib/firefly-sdk-build.sh" "$fixture/sdk" all
[[ $(<"$fixture/firefly-python2") == *tgosimages-python2* ]]
[[ $(<"$fixture/firefly-python") == *tgosimages-python2* ]]
BOUNDARY_PROBE="$fixture/firefly-python2" BOUNDARY_PYTHON_PROBE="$fixture/firefly-python" \
    bash -s -- "$fixture/sdk" all < "$root/scripts/lib/firefly-sdk-build.sh"
[[ $(<"$fixture/firefly-python") == *tgosimages-python2* ]]
