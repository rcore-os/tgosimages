#!/usr/bin/env bash

TGOS_BUILD_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# The budget belongs to the invocation, not to each concurrently running tool.
build_jobs() {
    local jobs=${BUILD_JOBS:-$(nproc)} budget=${TGOS_BUILD_JOB_BUDGET:-}
    [[ $jobs =~ ^[1-9][0-9]*$ ]] || { error 'BUILD_JOBS must be a positive integer'; return 2; }
    if [[ -n $budget ]]; then
        [[ $budget =~ ^[1-9][0-9]*$ ]] || { error 'Invalid inherited build budget'; return 2; }
        ((jobs <= budget)) || jobs=$budget
    fi
    printf '%s\n' "$jobs"
}

build_child_jobs() {
    local count=$1 index=$2 total jobs
    [[ $count =~ ^[1-9][0-9]*$ && $index =~ ^[0-9]+$ ]] || return 2
    total=$(build_jobs) || return
    jobs=$((total / count))
    ((jobs > 0)) || jobs=1
    printf '%s\n' "$jobs"
}

build_parallel_limit() {
    local count=$1 jobs limit
    jobs=$(build_jobs) || return
    limit=${BUILD_PARALLEL_TASKS:-$jobs}
    [[ $limit =~ ^[1-9][0-9]*$ ]] || { error 'BUILD_PARALLEL_TASKS must be positive'; return 2; }
    ((limit <= jobs)) || limit=$jobs
    ((limit <= count)) || limit=$count
    printf '%s\n' "$limit"
}

build_wait_slot() {
    local limit=$1 pid active started=$SECONDS
    shift
    while :; do
        active=0
        for pid in "$@"; do
            if kill -0 "$pid" 2>/dev/null; then active=$((active + 1)); fi
        done
        ((active >= limit)) || return 0
        if ((SECONDS - started >= 60)); then
            info "RUNNING scheduler: $active tasks active; waiting for a slot"
            started=$SECONDS
        fi
        sleep 1
    done
}

build_cache_enabled() {
    [[ ${BUILD_CACHE:-1} != 0 && -z ${CCACHE_DISABLE:-} ]] && command -v ccache >/dev/null 2>&1
}

_build_prepare() {
    case ${BUILD_CACHE:-1} in 0|1|auto) ;; *) error 'BUILD_CACHE must be 0, 1, or auto'; return 2 ;; esac
    local jobs
    jobs=$(build_jobs) || return
    export TGOS_BUILD_JOB_BUDGET=$jobs
    export BUILD_CACHE_DIR=${BUILD_CACHE_DIR:-${BUILD_DIR}/.cache}
    export CMAKE_BUILD_PARALLEL_LEVEL=$TGOS_BUILD_JOB_BUDGET
    export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-$TGOS_BUILD_JOB_BUDGET}
    if [[ ${BUILD_CACHE:-1} == 0 ]]; then export CCACHE_DISABLE=1; fi
    if build_cache_enabled; then
        export CCACHE_DIR=${CCACHE_DIR:-${BUILD_CACHE_DIR}/ccache}
        export CCACHE_BASEDIR=${CCACHE_BASEDIR:-${ROOT_DIR}}
        mkdir -p -- "$CCACHE_DIR"
    fi
}

# Compiler aliases preserve Makefile-selected compilers, including cross tools.
# Absolute compiler paths require an explicit launcher from the caller.
_build_compiler_path() {
    build_cache_enabled || return 0
    local cache_binary wrapper_dir compiler
    cache_binary=$(command -v ccache)
    wrapper_dir="${BUILD_CACHE_DIR}/compiler-wrappers"
    mkdir -p -- "$wrapper_dir"
    while IFS= read -r compiler; do
        [[ $compiler =~ ^([a-zA-Z0-9_.+-]+-)?(gcc|g\+\+|cc|c\+\+|clang|clang\+\+)(-[0-9.]+)?$ ]] || continue
        [[ -L $wrapper_dir/$compiler ]] || ln -sf -- "$cache_binary" "$wrapper_dir/$compiler"
    done < <(compgen -c | LC_ALL=C sort -u)
    export PATH="$wrapper_dir:$PATH"
}

_build_run() {
    local backend=$1 status=0 started=$SECONDS
    shift
    info "BUILD $backend: jobs=$TGOS_BUILD_JOB_BUDGET cache_policy=${BUILD_CACHE:-1}"
    "$@" || status=$?
    if ((status == 0)); then
        success "BUILD $backend: elapsed=$((SECONDS - started))s"
    else
        error "BUILD $backend: status=$status elapsed=$((SECONDS - started))s"
    fi
    return "$status"
}

build_make() (
    _build_prepare || exit
    _build_compiler_path || exit
    # CROSS_COMPILE also coexists with LLVM=1 and Makefile-selected compilers.
    # Injecting CC here would change the toolchain instead of just caching it.
    _build_run make command make -j"$TGOS_BUILD_JOB_BUDGET" "$@"
)

# Called in the parent's shell: command substitution cannot wait for its child.
build_reap_task() {
    local _task_pid=$1 _task_file=$2 _task_result=$3 _task_status=0
    wait "$_task_pid" 2>/dev/null || _task_status=$?
    if ((_task_status == 0)) && [[ ! -s $_task_file ]]; then
        _task_status=1
    fi
    printf -v "$_task_result" '%s' "$_task_status"
}

build_cmake() (
    _build_prepare || exit
    local launcher= arg configure=1
    local cache_args=()
    for arg in "$@"; do
        case $arg in --build|--install|--version|--help*|-E|-P|--find-package) configure=0 ;; esac
    done
    if ((configure)); then
        if build_cache_enabled; then launcher=$(command -v ccache); fi
        cache_args+=("-DCMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER-$launcher}"
                     "-DCMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER-$launcher}")
        # Zephyr otherwise installs its own RULE_LAUNCH_COMPILE and wraps twice.
        [[ -z ${ZEPHYR_BASE:-} ]] || cache_args+=(-DUSE_CCACHE=0)
    fi
    _build_run cmake command cmake "${cache_args[@]}" "$@"
)

build_cargo() (
    _build_prepare || exit
    if [[ ${BUILD_CACHE:-1} != 0 && -z ${RUSTC_WRAPPER:-} ]] && command -v sccache >/dev/null 2>&1; then
        export RUSTC_WRAPPER=$(command -v sccache)
        export SCCACHE_DIR=${SCCACHE_DIR:-${BUILD_CACHE_DIR}/sccache}
    fi
    _build_run cargo command cargo "$@"
)

build_scons() (
    _build_prepare || exit
    _build_compiler_path || exit
    _build_run scons command scons -j"$TGOS_BUILD_JOB_BUDGET" "$@"
)

# Opt-in task cache: declarations must include all artifact-affecting inputs.
# The command is an executable, not an unevaluated shell string.
build_task() (
    _build_prepare || exit
    python3 "${TGOS_BUILD_LIB_DIR}/build-task.py" "$@"
)

# Reuse source preparation only when the entire patched tree is verified.
# Callers must serialize use of shared source trees through the build phase.
prepare_patched_source() {
    local source=$1 ref=$2 patches=$3
    build_assert_workspace_path "$source" || return
    local state_dir="$source/.patch_stamps" identity current base
    python3 "$TGOS_BUILD_LIB_DIR/build_inputs.py" --protect-cmake-outputs "$source" || return
    if ! base=$(git -C "$source" rev-parse --verify "${ref}^{commit}" 2>/dev/null); then
        if [[ -n ${BUILD_SOURCE_CACHE_DIR:-} ]]; then
            base=$(bash "$TGOS_BUILD_LIB_DIR/git-source-cache.sh" ref "$source" "$ref") || return
        else
            git -C "$source" fetch --quiet --no-tags --depth=1 origin "$ref" || return
            base=$(git -C "$source" rev-parse --verify 'FETCH_HEAD^{commit}') || return
        fi
        ref=$base
    fi
    identity=$(python3 "$TGOS_BUILD_LIB_DIR/build_inputs.py" "$patches") || return
    current=$(python3 "$TGOS_BUILD_LIB_DIR/build_inputs.py" --source "$source") || return
    if [[ -f $state_dir/source.sha256 && $(<"$state_dir/source.sha256") == "$current" ]]; then
        if [[ -f $state_dir/base.commit && $(<"$state_dir/base.commit") == "$base" &&
              -f $state_dir/patch-set.sha256 && $(<"$state_dir/patch-set.sha256") == "$identity" ]]; then
            info "SOURCE CACHE HIT: $source (base and patched tree verified)"
            return 0
        fi
        info "SOURCE CACHE MISS: base revision or ordered patch set changed"
    elif python3 "$TGOS_BUILD_LIB_DIR/build_inputs.py" --verify "$source" "$base" "$patches"; then
        # Adopt legacy stamps only after reconstructing and comparing the
        # expected complete tree. This also handles overlapping patch chains.
        mkdir -p "$state_dir"
        printf '%s\n' "$identity" >"$state_dir/patch-set.sha256"
        printf '%s\n' "$current" >"$state_dir/source.sha256"
        printf '%s\n' "$base" >"$state_dir/base.commit"
        info "SOURCE CACHE HIT: verified existing patched source $source"
        return 0
    elif [[ -f $state_dir/source.sha256 ]] ||
         ! python3 "$TGOS_BUILD_LIB_DIR/build_inputs.py" --verify "$source" HEAD /nonexistent-tgos-patches; then
        error "Source has unverified local changes: $source; preserve or resolve them before rebuilding"
        return 1
    fi
    checkout_ref "$source" "$ref" || return
    if apply_patches "$patches" "$source"; then
        :
    else
        local status=$?
        # Record ownership of our partial application so a corrected patch can
        # safely retry from the base, without publishing a successful cache.
        mkdir -p "$state_dir"
        current=$(python3 "$TGOS_BUILD_LIB_DIR/build_inputs.py" --source "$source") || return
        printf '%s\n' "$current" >"$state_dir/source.sha256"
        rm -f -- "$state_dir/patch-set.sha256"
        return "$status"
    fi
    mkdir -p "$state_dir"
    current=$(python3 "$TGOS_BUILD_LIB_DIR/build_inputs.py" --source "$source") || return
    printf '%s\n' "$identity" >"$state_dir/patch-set.sha256"
    printf '%s\n' "$current" >"$state_dir/source.sha256"
    printf '%s\n' "$base" >"$state_dir/base.commit"
}
