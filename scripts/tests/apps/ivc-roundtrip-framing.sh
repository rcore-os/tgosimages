#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
IVC_SDK_DIR=${IVC_SDK_DIR:-${ROOT_DIR}/../ivc-sdk}
SOURCE=${IVC_ROUNDTRIP_SOURCE:-${ROOT_DIR}/apps/ivc/ivc-roundtrip.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"${IVC_SDK_DIR}/include" \
    "$SOURCE" "${ROOT_DIR}/apps/ivc/tests/stream-fixture.c" -o "$work/client"
"$work/client" subscribe 37 0x234 request reply >"$work/good.log" 2>&1 || {
    cat "$work/good.log"; exit 1;
}
grep -q '^IVC_ROUNDTRIP_PASSED role=subscribe key=0x234 count=5$' "$work/good.log"
if IVC_TEST_BAD_SEQUENCE=1 "$work/client" subscribe 37 0x234 request reply >"$work/bad.log" 2>&1; then
    cat "$work/bad.log"; echo 'incorrect sequence was accepted' >&2; exit 1
fi
grep -q '^IVC_ROUNDTRIP_FAILED expected=request-2$' "$work/bad.log"
echo 'IVC byte-stream framing: PASS (merged, split, and invalid sequence)'
