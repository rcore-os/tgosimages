#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
source_cache="$repo_root/scripts/lib/git-source-cache.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
real_git=$(command -v git)
test_home="$work/home"
mkdir -p "$test_home" "$work/bin"

git_env=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE
    HOME="$test_home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    GIT_TERMINAL_PROMPT=0 LC_ALL=C)
upstream="$work/upstream"
"${git_env[@]}" "$real_git" init -q "$upstream"
printf 'base\n' >"$upstream/value"
"${git_env[@]}" "$real_git" -C "$upstream" add value
"${git_env[@]}" "$real_git" -C "$upstream" -c user.name=test \
    -c user.email=test@example.com commit -qm base
base=$("${git_env[@]}" "$real_git" -C "$upstream" rev-parse HEAD)
upstream_url="file://$upstream"

cat >"$work/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
joined=" ${args[*]} "
match=0
case ${GIT_TEST_KIND:-none} in
    remote-clone)
        [[ ${args[0]:-} == clone && ${args[1]:-} == --bare ]] && match=1
        ;;
    refresh)
        [[ $joined == *' fetch --quiet --depth=1 --no-tags origin HEAD '* ]] && match=1
        ;;
    ref)
        [[ $joined == *" fetch --quiet --depth=1 --no-tags origin $GIT_TEST_REF "* ]] && match=1
        ;;
    local-clone)
        [[ ${args[0]:-} == clone && ${args[1]:-} == --no-local ]] && match=1
        ;;
    local-fetch)
        [[ $joined == *' fetch --quiet --depth=1 --no-tags file://'*
           && $joined == *' refs/tgos-cache/'* ]] && match=1
        ;;
esac
if ((match)); then
    count=0
    [[ ! -f $GIT_TEST_COUNT ]] || read -r count <"$GIT_TEST_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" >"$GIT_TEST_COUNT"
    if ((count <= GIT_TEST_FAILURES)); then
        if [[ ${GIT_TEST_KIND:-} == remote-clone ]]; then
            destination=${args[${#args[@]} - 1]}
            mkdir -p "$destination"
            printf 'incomplete\n' >"$destination/partial"
        fi
        printf 'injected git failure\n' >&2
        exit 71
    fi
fi
exec "$GIT_TEST_REAL_GIT" "${args[@]}"
EOF
chmod +x "$work/bin/git"

cat >"$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$GIT_TEST_SLEEP_LOG"
EOF
chmod +x "$work/bin/sleep"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1': ${3:-}"; }

scenario=0
run_cache() {
    local kind=$1 failures=$2 cache=$3 operation=$4 repo=$5 value=$6
    scenario=$((scenario + 1))
    count_file="$work/count-$scenario"
    sleep_log="$work/sleep-$scenario"
    stderr_file="$work/stderr-$scenario"
    : >"$sleep_log"
    set +e
    stdout=$("${git_env[@]}" PATH="$work/bin:$PATH" BUILD_SOURCE_CACHE_DIR="$cache" \
        GIT_TEST_REAL_GIT="$real_git" GIT_TEST_KIND="$kind" \
        GIT_TEST_FAILURES="$failures" GIT_TEST_COUNT="$count_file" \
        GIT_TEST_SLEEP_LOG="$sleep_log" GIT_TEST_REF="${requested_ref:-}" \
        bash "$source_cache" "$operation" "$repo" "$value" 2>"$stderr_file")
    status=$?
    set -e
    attempts=0
    [[ ! -f $count_file ]] || read -r attempts <"$count_file"
}

assert_retry_trace() {
    assert_eq "$(tr '\n' ' ' <"$sleep_log")" '1 2 ' 'retry delays'
    grep -q 'attempt 1/3; retrying in 1s' "$stderr_file" || fail 'missing first retry notice'
    grep -q 'attempt 2/3; retrying in 2s' "$stderr_file" || fail 'missing second retry notice'
    ! grep 'attempt [12]/3' "$stderr_file" | grep -Fq "$upstream_url" || fail 'retry notice leaked URL'
}

cache="$work/cache"
sentinel="$cache/unrelated-sentinel"
mkdir -p "$cache"
printf 'keep\n' >"$sentinel"
workspace="$work/workspace"
run_cache remote-clone 2 "$cache" clone "$workspace" "$upstream_url"
assert_eq "$status" 0 'remote clone retry'
assert_eq "$attempts" 3 'remote clone attempts'
assert_retry_trace
assert_eq "$(<"$sentinel")" keep 'cleanup scope'
assert_eq "$("${git_env[@]}" "$real_git" -C "$workspace" rev-parse HEAD)" "$base" 'workspace HEAD'
[[ ! -e $workspace/.git/objects/info/alternates ]] || fail 'workspace uses cache alternates'

printf 'tip\n' >"$upstream/value"
"${git_env[@]}" "$real_git" -C "$upstream" add value
"${git_env[@]}" "$real_git" -C "$upstream" -c user.name=test \
    -c user.email=test@example.com commit -qm tip
tip=$("${git_env[@]}" "$real_git" -C "$upstream" rev-parse HEAD)
refreshed="$work/refreshed"
run_cache refresh 2 "$cache" clone "$refreshed" "$upstream_url"
assert_eq "$status" 0 'cache refresh retry'
assert_eq "$attempts" 3 'cache refresh attempts'
assert_retry_trace
assert_eq "$("${git_env[@]}" "$real_git" -C "$refreshed" rev-parse HEAD)" "$tip" 'refreshed HEAD'

printf 'late\n' >"$upstream/value"
"${git_env[@]}" "$real_git" -C "$upstream" add value
"${git_env[@]}" "$real_git" -C "$upstream" -c user.name=test \
    -c user.email=test@example.com commit -qm late
late=$("${git_env[@]}" "$real_git" -C "$upstream" rev-parse HEAD)
requested_ref=refs/heads/late-ref
"${git_env[@]}" "$real_git" -C "$upstream" branch "$requested_ref" "$late"
run_cache ref 2 "$cache" ref "$workspace" "$requested_ref"
assert_eq "$status" 0 'requested ref retry'
assert_eq "$attempts" 3 'requested ref attempts'
assert_retry_trace
assert_eq "$stdout" "$late" 'requested ref result'

failed_cache="$work/failed-cache"
failed_workspace="$work/failed-workspace"
run_cache remote-clone 99 "$failed_cache" clone "$failed_workspace" "$upstream_url"
[[ $status -ne 0 ]] || fail 'permanent clone failure succeeded'
assert_eq "$attempts" 3 'permanent failure attempt cap'
assert_retry_trace
grep -q 'Source cache:' "$stderr_file" || fail 'missing source-cache failure prefix'
[[ ! -e $failed_workspace ]] || fail 'failed clone published workspace'
[[ -z $(find "$failed_cache" -maxdepth 1 -name '*.git' -print -quit) ]] || fail 'failed clone published cache'

local_workspace="$work/local-workspace"
run_cache local-clone 1 "$cache" clone "$local_workspace" "$upstream_url"
[[ $status -ne 0 ]] || fail 'injected local clone failure succeeded'
assert_eq "$attempts" 1 'local clone must not retry'
[[ ! -s $sleep_log ]] || fail 'local clone slept before retry'

printf 'local-ref\n' >"$upstream/value"
"${git_env[@]}" "$real_git" -C "$upstream" add value
"${git_env[@]}" "$real_git" -C "$upstream" -c user.name=test \
    -c user.email=test@example.com commit -qm local-ref
local_ref_commit=$("${git_env[@]}" "$real_git" -C "$upstream" rev-parse HEAD)
requested_ref=refs/heads/local-ref
"${git_env[@]}" "$real_git" -C "$upstream" branch "$requested_ref" "$local_ref_commit"
run_cache local-fetch 1 "$cache" ref "$workspace" "$requested_ref"
[[ $status -ne 0 ]] || fail 'injected cache-local fetch failure succeeded'
assert_eq "$attempts" 1 'cache-local fetch must not retry'
[[ ! -s $sleep_log ]] || fail 'cache-local fetch slept before retry'

printf 'PASS: Git source-cache retries\n'
