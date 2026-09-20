#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export LOG_CREATE_DEFAULT_FILE=0
source "$repo_root/scripts/lib/utils.sh"
source "$repo_root/scripts/lib/build-cpu-scope.sh"
unset TGOS_BUILD_JOB_BUDGET
nproc() { printf '8\n'; }
automatic_jobs=$(build_jobs)
((automatic_jobs >= 1 && automatic_jobs < 8))
unset -f nproc

scope_bin="$work/scope-bin"
mkdir "$scope_bin"
cat >"$scope_bin/systemd-run" <<'SCOPE'
#!/usr/bin/env bash
set -e
[[ ${SCOPE_UNAVAILABLE:-0} != 1 ]] || exit 1
printf '%s\n' "$*" >>"$SCOPE_CALLS"
for argument in "$@"; do
    [[ $argument != true ]] || exit 0
done
while [[ $# -gt 0 && $1 != env ]]; do shift; done
shift
exec env "$@"
SCOPE
chmod +x "$scope_bin/systemd-run"
cat >"$work/scoped-command" <<'COMMAND'
#!/usr/bin/env bash
test "$TGOS_CPU_SCOPE_ACTIVE" = 1
printf 'scoped\n' >"$SCOPE_RESULT"
COMMAND
chmod +x "$work/scoped-command"
(
    export PATH="$scope_bin:$PATH" SCOPE_CALLS="$work/scope.calls" SCOPE_RESULT="$work/scope.result"
    nproc() { printf '8\n'; }
    build_cpu_scope_reexec build "$work/scoped-command"
)
[[ $(<"$work/scope.result") == scoped ]]
grep -Fq 'CPUQuota=500%' "$work/scope.calls"
(
    export PATH="$scope_bin:$PATH" SCOPE_UNAVAILABLE=1
    nproc() { printf '8\n'; }
    build_cpu_scope_reexec build "$work/scoped-command"
    printf 'fallback\n' >"$work/scope.fallback"
)
[[ $(<"$work/scope.fallback") == fallback ]]
printf 'PASS: build entry uses cgroup CPU quota with an unsupported-system fallback\n'

export BUILD_CACHE_DIR="$work/cache" TGOS_BUILD_JOB_BUDGET=4

# Exercise real parallel runner with a budget smaller than its task count.
slot_task() {
    [[ $(build_jobs) == 1 ]]
    mkdir "$work/active" || return 7
    sleep 0.1
    rmdir "$work/active"
}
TGOS_BUILD_JOB_BUDGET=1 PARALLEL_LOG_DIR="$work/parallel" run_parallel_functions slots \
    'one=slot_task' 'two=slot_task' 'three=slot_task' -- >"$work/parallel.console"
printf 'PASS: parallel fan-out respects a one-job budget\n'

mkdir -p "$work/project"
cat >"$work/project/Makefile" <<'MAKE'
all: test.o

test.o: test.c
	$(CC) -O2 -c $< -o $@
MAKE
printf 'int main(void) { return 0; }\n' >"$work/project/test.c"
export CCACHE_DIR="$work/ccache"
(
    cd "$work/project"
    build_make
    cp test.o first.o
    rm test.o
    build_make
    cmp first.o test.o
)
if command -v ccache >/dev/null; then
    ccache --print-stats >"$work/stats"
    awk '$1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { n += $2 } END { exit !(n > 0) }' "$work/stats"
fi
printf 'PASS: real Make compile reuses compiler cache with identical output\n'
cat >"$work/project/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(cache_test C)
add_executable(cache_test test.c)
CMAKE
build_cmake -S "$work/project" -B "$work/cmake" >"$work/cmake.log" 2>&1
build_cmake --build "$work/cmake" >>"$work/cmake.log" 2>&1
"$work/cmake/cache_test"
BUILD_CACHE=0 build_cmake -S "$work/project" -B "$work/cmake" >>"$work/cmake.log" 2>&1
grep -q '^CMAKE_C_COMPILER_LAUNCHER:.*=$' "$work/cmake/CMakeCache.txt"
printf 'PASS: real CMake build and cache disable\n'

mkdir "$work/source" "$work/patches"
git -C "$work/source" init -q
git -C "$work/source" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm base
printf 'one\n' >"$work/input"
printf 'patch-one\n' >"$work/patches/01.patch"
cat >"$work/build.sh" <<'BUILD'
#!/bin/bash
set -eu
printf 'run\n' >>"$1/count"
[[ ! -e $1/fail ]] || exit 23
cp "$1/input" "$1/output"
BUILD
run_task() {
    build_task fixture --input "$work/input" --input "$work/build.sh" \
        --source-ref "$work/source" HEAD --patch-dir "$work/patches" \
        --env TEST_SETTING --output "$work/output" -- bash "$work/build.sh" "$work"
}
run_task
run_task
[[ $(wc -l <"$work/count") == 1 ]]
printf 'two\n' >"$work/input"
run_task
[[ $(wc -l <"$work/count") == 2 ]]
printf 'corrupt\n' >"$work/output"
run_task
[[ $(wc -l <"$work/count") == 3 ]]
printf 'patch-two\n' >"$work/patches/01.patch"
run_task
mv "$work/patches/01.patch" "$work/patches/02.patch"
run_task
rm "$work/patches/02.patch"
run_task
[[ $(wc -l <"$work/count") == 6 ]]
git -C "$work/source" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm changed
run_task
[[ $(wc -l <"$work/count") == 7 ]]
printf 'untracked source\n' >"$work/source/new.c"
run_task
[[ $(wc -l <"$work/count") == 8 ]]
TEST_SETTING=changed run_task
[[ $(wc -l <"$work/count") == 9 ]]
touch "$work/fail"
status=0
BUILD_REBUILD=1 run_task || status=$?
[[ $status == 23 ]]
rm "$work/fail"
run_task
run_task
[[ $(wc -l <"$work/count") == 11 ]]
printf 'PASS: input/ref/patch/environment/output invalidation and failed retries\n'

mkdir "$work/patched" "$work/ordered"
git -C "$work/patched" init -q
printf 'one\n' >"$work/patched/value"
git -C "$work/patched" add value
git -C "$work/patched" -c user.name=test -c user.email=test@example.com commit -qm base
base=$(git -C "$work/patched" rev-parse HEAD)
printf 'two\n' >"$work/patched/value"
git -C "$work/patched" diff >"$work/ordered/01.patch"
git -C "$work/patched" add value
printf 'three\n' >"$work/patched/value"
git -C "$work/patched" diff >"$work/ordered/02.patch"
git -C "$work/patched" reset --hard -q "$base"
touch "$work/patched/.git/index.lock"
checkout_ref "$work/patched" "$base"
[[ ! -e $work/patched/.git/index.lock ]]
printf 'PASS: checkout removes an unowned stale Git index lock\n'
exec {held_lock_fd}>"$work/patched/.git/index.lock"
if git_remove_stale_index_lock "$work/patched"; then exit 1; fi
[[ -e $work/patched/.git/index.lock ]]
exec {held_lock_fd}>&-
rm "$work/patched/.git/index.lock"
printf 'PASS: checkout preserves an actively owned Git index lock\n'
prepare_patched_source "$work/patched" "$base" "$work/ordered"
[[ $(cat "$work/patched/value") == three ]]
prepare_patched_source "$work/patched" "$base" "$work/ordered"
# Ordered overlapping patches must be checked as a whole, never reversed alone.
apply_patches "$work/ordered" "$work/patched"
sed -i 's/+three/+four/' "$work/ordered/02.patch"
prepare_patched_source "$work/patched" "$base" "$work/ordered"
[[ $(cat "$work/patched/value") == four ]]
rm "$work/ordered/02.patch"
prepare_patched_source "$work/patched" "$base" "$work/ordered"
[[ $(cat "$work/patched/value") == two ]]
# Legacy markers can be adopted without touching the working tree.
rm "$work/patched/.patch_stamps/"*.sha256
prepare_patched_source "$work/patched" "$base" "$work/ordered"
printf 'user edit\n' >"$work/patched/value"
if prepare_patched_source "$work/patched" "$base" "$work/ordered"; then exit 1; fi
[[ $(cat "$work/patched/value") == 'user edit' ]]
checkout_ref "$work/patched" "$base"
prepare_patched_source "$work/patched" "$base" "$work/ordered"
[[ $(cat "$work/patched/value") == two ]]
printf 'PASS: overlapping patches, changed/removed patches, legacy adoption, local edits, and checkout reset\n'
printf 'parallel\n' >"$work/input"
run_task & first=$!
run_task & second=$!
wait "$first"
wait "$second"
[[ $(wc -l <"$work/count") == 12 ]]
printf 'PASS: concurrent callers execute a cached task once\n'
cat >"$work/ordered/02.patch" <<'PATCH'
diff --git a/value b/value
--- a/value
+++ b/value
@@ -1 +1 @@
-does-not-exist
+changed
PATCH
if prepare_patched_source "$work/patched" "$base" "$work/ordered"; then exit 1; fi
[[ ! -f $work/patched/.patch_stamps/patch-set.sha256 ]]
sed -i 's/-does-not-exist/-two/' "$work/ordered/02.patch"
prepare_patched_source "$work/patched" "$base" "$work/ordered"
[[ $(cat "$work/patched/value") == changed ]]
printf 'PASS: failed patch does not publish success and can retry\n'
mkdir "$work/patched/legacy-build"
printf 'CMAKE_CACHEFILE_DIR:INTERNAL=%s\n' "$work/patched/legacy-build" >"$work/patched/legacy-build/CMakeCache.txt"
printf 'old object\n' >"$work/patched/legacy-build/keep.o"
python3 "$TGOS_BUILD_LIB_DIR/python/build_inputs.py" --protect-cmake-outputs "$work/patched"
prepare_patched_source "$work/patched" "$base" "$work/ordered"
printf '\n' >>"$work/ordered/02.patch"
prepare_patched_source "$work/patched" "$base" "$work/ordered"
[[ $(cat "$work/patched/legacy-build/keep.o") == 'old object' ]]
printf 'PASS: legacy CMake outputs survive source invalidation\n'
