#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
unset ORANGEPI_AKA_SOURCE_DIR AKA_RK3588_SOURCE_DIR AKA_RK3588_DIR AKA_RK3588_REF
export ORANGEPI_WITH_AKA=1
export BUILD_WORK_DIR="$work/platform-workspace"
export AKA_RK3588_REPO_URL="$work/upstream"

# The default branch deliberately lacks the app; only dual can build it.
git init -q -b master "$work/upstream"
git -C "$work/upstream" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m 'default branch without controller'
git -C "$work/upstream" switch -q -c dual
mkdir -p "$work/upstream/zephyr/orangepi_robot_control"
printf fixture >"$work/upstream/zephyr/orangepi_robot_control/CMakeLists.txt"
git -C "$work/upstream" add .
git -C "$work/upstream" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -q -m 'controller on dual'
git -C "$work/upstream" switch -q master

source "$root/scripts/platform/orangepi-5-plus.sh"
info() { :; }
warn() { printf "%s\n" "$*" >&2; }
[[ $ORANGEPI_AKA_SOURCE_DIR == "$BUILD_DIR/aka-rk3588" ]]
# Stop at the builder boundary so these tests never compile or download SDKs.
bash() {
    [[ $1 == */apps/ivc-rk3588.sh ]]
    [[ " $* " == *" --aka-dir $ORANGEPI_AKA_SOURCE_DIR "* ]]
}
zephyr
[[ $(git -C "$ORANGEPI_AKA_SOURCE_DIR" rev-parse HEAD) == $(git -C "$work/upstream" rev-parse dual) ]]
printf local-change >>"$ORANGEPI_AKA_SOURCE_DIR/zephyr/orangepi_robot_control/CMakeLists.txt"
export AKA_RK3588_REF=dual
zephyr
[[ $(git -C "$ORANGEPI_AKA_SOURCE_DIR" rev-parse HEAD) == $(git -C "$work/upstream" rev-parse dual) ]]
[[ -z $(git -C "$ORANGEPI_AKA_SOURCE_DIR" status --short) ]]
if zephyr --aka-dir "$work/missing-explicit"; then
    printf 'explicit missing source unexpectedly succeeded\n' >&2
    exit 1
fi
[[ ! -e $work/missing-explicit ]]
unset -f bash
unset AKA_RK3588_REF
printf 'ok - platform workspace clone, dual branch, managed source cleanup, explicit missing path\n'

# Exercise the standalone wrapper with its downstream Zephyr builder replaced.
fixture_root="$work/standalone"
mkdir -p "$fixture_root/scripts/"{apps,lib,os} "$work/sdk/zephyr"
cp "$root/scripts/apps/aka-rk3588-zephyr.sh" "$fixture_root/scripts/apps/"
cp "$root/scripts/lib/"{log,build-paths}.sh "$fixture_root/scripts/lib/"
git init -q "$work/sdk"
printf fixture >"$work/sdk/zephyr/module.yml"
git -C "$work/sdk" add .
git -C "$work/sdk" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -q -m "SDK module fixture"
cat >"$fixture_root/scripts/os/zephyr.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$AKA_TEST_ARGUMENTS"
STUB
chmod +x "$fixture_root/scripts/os/zephyr.sh"
export IVC_SDK_DIR="$work/sdk"
export AKA_TEST_ARGUMENTS="$work/arguments"
export BUILD_WORK_DIR="$work/standalone-workspace"
bash "$fixture_root/scripts/apps/aka-rk3588-zephyr.sh"
[[ $(git -C "$BUILD_WORK_DIR/aka-rk3588" rev-parse HEAD) == $(git -C "$work/upstream" rev-parse dual) ]]
rg -Fx "$BUILD_WORK_DIR/aka-rk3588/zephyr/orangepi_robot_control" "$AKA_TEST_ARGUMENTS"
[[ ! -e $fixture_root/../aka-rk3588 ]]
printf 'ok - standalone wrapper uses active build workspace and dual branch\n'

export AKA_RK3588_DIR="$work/env-aka"
bash "$fixture_root/scripts/apps/aka-rk3588-zephyr.sh"
rg -Fx "$AKA_RK3588_DIR/zephyr/orangepi_robot_control" "$AKA_TEST_ARGUMENTS"
printf local-change >>"$AKA_RK3588_DIR/zephyr/orangepi_robot_control/CMakeLists.txt"
env AKA_RK3588_DIR="$work/unused-env-aka" \
    bash "$fixture_root/scripts/apps/aka-rk3588-zephyr.sh" --aka-dir "$AKA_RK3588_DIR" --aka-ref master
[[ ! -e $work/unused-env-aka ]]
[[ $(git -C "$AKA_RK3588_DIR" rev-parse HEAD) == $(git -C "$work/upstream" rev-parse dual) ]]
[[ $(git -C "$AKA_RK3588_DIR" status --short) != '' ]]
printf 'ok - environment and CLI overrides preserve existing local source\n'

unset AKA_RK3588_DIR BUILD_WORK_DIR
bash "$fixture_root/scripts/apps/aka-rk3588-zephyr.sh"
[[ $(git -C "$fixture_root/build/aka-rk3588" rev-parse HEAD) == $(git -C "$work/upstream" rev-parse dual) ]]
rg -Fx "$fixture_root/build/aka-rk3588/zephyr/orangepi_robot_control" "$AKA_TEST_ARGUMENTS"
printf 'ok - standalone default stays inside repo/build\n'

# The shared SDK is managed inside build unless explicitly selected.
unset IVC_SDK_DIR
export IVC_SDK_REPO_URL="$work/sdk"
export AKA_RK3588_DIR="$work/env-aka"
export BUILD_WORK_DIR="$work/sdk-workspace"
bash "$fixture_root/scripts/apps/aka-rk3588-zephyr.sh"
managed_sdk="$BUILD_WORK_DIR/ivc-sdk-source"
[[ -f $managed_sdk/zephyr/module.yml ]]
printf residue >"$managed_sdk/zephyr/module.yml"
git -C "$managed_sdk" add zephyr/module.yml
printf extra >"$managed_sdk/extra-file"
printf update >"$work/sdk/README"
printf fixture >"$work/sdk/Makefile"
git -C "$work/sdk" add .
git -C "$work/sdk" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm update
bash "$fixture_root/scripts/apps/aka-rk3588-zephyr.sh"
[[ $(cat "$managed_sdk/zephyr/module.yml") == fixture ]]
[[ ! -e $managed_sdk/extra-file ]]
[[ -f $managed_sdk/README ]]
[[ -z $(git -C "$managed_sdk" status --short) ]]
[[ $(cat "$AKA_RK3588_DIR/zephyr/orangepi_robot_control/CMakeLists.txt") == fixturelocal-change ]]
printf 'ok - managed SDK updates and cleans while explicit AKA remains unchanged\n'

# Exercise the second SDK consumer without invoking toolchains.
export IVC_BUILD_DIR="$work/sdk-objects"
mkdir -p "$IVC_BUILD_DIR/examples"
for program in ivc-demo ivc-starry-bench ivc-roundtrip; do
    printf fixture >"$IVC_BUILD_DIR/examples/$program"
done
printf residue >"$managed_sdk/zephyr/module.yml"
LOG_CREATE_DEFAULT_FILE=0 bash "$root/scripts/apps/ivc-rk3588.sh" \
    --skip-user-apps --skip-zephyr --skip-starry-image --stage-dir "$work/stage"
[[ $(cat "$managed_sdk/zephyr/module.yml") == fixture ]]
printf caller >"$managed_sdk/zephyr/module.yml"
LOG_CREATE_DEFAULT_FILE=0 bash "$root/scripts/apps/ivc-rk3588.sh" \
    --ivc-sdk-dir "$managed_sdk" --skip-user-apps --skip-zephyr --skip-starry-image \
    --stage-dir "$work/stage"
[[ $(cat "$managed_sdk/zephyr/module.yml") == caller ]]
printf 'ok - IVC entry cleans default SDK and preserves caller-selected SDK\n'
