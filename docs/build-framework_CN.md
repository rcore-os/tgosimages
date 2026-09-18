# 全局构建规范与目标接入要求

本文统一约束所有平台、OS、rootfs、应用以及构建辅助脚本，既用于新增目标，也用于现有目标的改造。所有目标必须复用公共构建层，不能各自维护线程数、编译缓存和日志策略。

下文的 Zephyr 仅用于说明已发现的问题和迁移方式。目录隔离、缓存失效、补丁处理、资源调度、日志和清理规则对所有组件同样适用。

## 1. 目录必须按用途隔离

| 类型 | 目录约定 | 要求 |
| --- | --- | --- |
| 上游源码 | `build/sources/<组件>/` | 新组件优先使用；已有源码路径可继续兼容 |
| 中间产物 | `build/objects/<组件>/<目标或架构>/` | 独立于源码目录；配置或工具链不兼容时进一步分目录 |
| 编译及任务缓存 | `build/.cache/` | 由公共层管理，可通过 `BUILD_CACHE_DIR` 调整 |
| 最终镜像/产物 | `IMAGES/<目标>/` | 只放供运行、打包或交付的产物 |
| 构建日志 | `logs/<类别>/` | 使用公共日志入口 |

**所有目标不得把 `.o`、CMake/Ninja 构建目录、临时打包文件或最终镜像写进源码 checkout。** 即使增加 `.gitignore`，也不能替代目录隔离。同一源码的不同架构、板型和不兼容配置不得共用中间产物目录。

对于支持 out-of-tree 构建的工具，使用 CMake 的 `-S/-B` 或项目支持的 Make `O=`。若上游确实只支持 in-tree 构建，应在 `build/objects/` 下创建该任务独占的源码副本或工作树；不要让多个任务修改下载缓存中的共享源码。

### 构建工具接入同一套目录规则

| 构建工具或流程 | 接入要求 |
| --- | --- |
| CMake / Ninja | 源码使用 `-S`，中间产物使用独立的 `-B` 目录 |
| Make / 内核 / U-Boot | 使用上游支持的 `O=` 或等价输出目录参数；不支持时使用任务独占的源码副本 |
| Cargo / Rust | 将 target 目录设置到该目标的中间产物目录，按架构及不兼容配置隔离 |
| SCons | 使用项目支持的独立构建目录；不支持时使用任务独占的源码副本 |
| rootfs / 应用打包 | 解包、安装、挂载和镜像组装的暂存目录必须由任务独占，独立于源码和最终产物 |

构建目录标识必须能区分目标、架构、应用来源及不兼容配置。不同路径但同名的应用不能仅凭 basename 共用目录。源码、编译缓存和任务产物应有明确的归属；清理一个目标不得破坏其他目标。

已有组件应按同一规范逐项迁移。临时兼容必须写明范围和迁移方式，不作为新增目标复制旧布局的依据；规范本身不表示所有历史脚本已完成改造。

## 2. 必须使用公共构建入口

脚本加载 `scripts/lib/utils.sh` 后，使用：

- `build_make`：Make 构建。
- `build_cmake`：CMake 配置和 `--build`。
- `build_cargo`：Cargo 及 Cargo 子命令。
- `build_scons`：SCons 构建。

平台脚本只提供目标、工具链、配置和产物参数。不要重新实现 ccache 初始化，也不要硬编码 `-j$(nproc)`。CMake 编译 launcher、Zephyr 原生 ccache 的协调以及 Cargo wrapper 的默认选择均由公共层处理。

```bash
source "${SCRIPT_DIR}/../lib/utils.sh"
build_cmake -S "$source_dir" -B "$object_dir" -DBOARD="$board"
build_cmake --build "$object_dir"
```

命令参数必须使用数组或逐参数传递，不能用 `eval` 拼接执行。

Make 适配器必须保留项目选择的编译器，不能根据 `CROSS_COMPILE` 强制推断为 GCC；LLVM 构建也可能设置这个变量。绝对路径编译器不会经过 PATH 缓存别名，需要项目显式配置对应 launcher。

## 3. 并行任务必须共享资源预算

`BUILD_JOBS` 表示一次构建调用的总编译线程预算；公共并行入口向子任务分配较小预算。`BUILD_PARALLEL_TASKS` 可进一步限制同时运行的任务数，超额任务排队。

新增批量入口使用 `run_parallel_functions` 或 `run_sequential_targets`。共享可变源码、相同输出文件或可变配置的任务，必须保持串行，或者先隔离工作区；需要锁时，锁必须覆盖准备源码到构建完成的整个阶段，不能只锁 checkout。

此预算不会限制其他独立构建进程、远程 SDK 服务器或不使用公共入口的外部脚本。用户显式传入的工具级线程参数也可能覆盖默认值，新增目标不应依赖这些覆盖。

运行 shell 函数步骤时，不要把 `run_parallel_functions` 或其外层构建函数放入 `if`、`!`、`&&`、`||` 条件列表并依赖步骤内部的 `set -e`；Bash 会在这种上下文中抑制 errexit。需接收失败结果时，应暂时关闭调用层的 errexit，直接调用运行器、记录退出码，再恢复原设置，参考 QEMU 和 Orange Pi 的调用方式。汇总器还必须处理子进程未写状态文件就退出的情况，使用进程退出码报告失败。

## 4. 补丁是构建输入，旧标记不是证明

源码准备统一使用：

```bash
clone_repository "$repo_url" "$source_dir"
prepare_patched_source "$source_dir" "$pinned_ref" "$patch_dir"
```

复用条件必须同时满足：基础 commit 一致、有序补丁集一致、实际源码状态一致。补丁顺序固定为 C 排序的 `*.patch`，随后是 `*.diff`。

以下变化都必须使缓存失效：

- 基础源码版本改变。
- 补丁内容修改、增加、删除、重命名或应用顺序改变。
- checkout、回滚或本地修改使源码不再等于已验证状态。

不得以 `.patch_stamps` 目录存在、`.applied` 文件存在或产物文件存在作为跳过构建的依据。重叠补丁必须验证整个补丁序列，不能逐个反向检查来替代整体校验。

旧源码通过临时 Git 索引重建预期补丁结果后才能迁移标记。已验证且未被外部修改的源码，可以在补丁变化后重新准备；未能确认来源的本地修改必须保留并报告，不能为了命中缓存而自动丢弃。

补丁失败不能写成功记录。公共层会记录自身产生的已知部分状态，以便修正补丁后安全重试。新增自定义补丁步骤若未使用这个流程，必须自己声明等价的输入及失败恢复规则。

## 5. 整项任务缓存必须显式声明输入

编译缓存由公共入口自动接入。跳过整个任务则使用 `build_task`，并声明所有影响产物的输入，包括：

- 基础源码版本、源码改动和补丁集。
- 构建驱动脚本及其引用的构建逻辑。
- 配置、工具链及 sysroot 身份、相关环境变量。
- 依赖任务产物，以及生成的或 Git 忽略的源码输入。
- 当前任务的最终输出文件或目录。

```bash
build_task "kernel-$arch" \
    --source-ref "$source_dir" "$pinned_ref" \
    --patch-dir "$patch_dir" \
    --input "$config_file" \
    --input "$build_driver" \
    --input "$toolchain_manifest" \
    --input "$dependency_artifact" \
    --env CROSS_COMPILE --env CFLAGS \
    --tool "${CROSS_COMPILE}gcc" \
    --value "arch=$arch" \
    --output "$kernel_image" \
    -- bash "$build_driver" "$arch"
```

先完成源码准备，再调用产物任务。`--source-ref` 检查已跟踪变更和未被忽略的未跟踪文件；被忽略文件、外部头文件和符号链接指向的外部依赖需要显式声明。目录输入会校验其中所有内容，不能把输出目录放进输入目录。

每个任务必须独占其输出路径；同名任务的文件锁不能阻止不同任务名写同一文件。产物必须存在且校验和、权限匹配才能命中。失败、缺失产物或构建过程中输入变化，都不能发布新的成功记录。

现有镜像任务不会因为引入公共框架就自动跳过；完成完整输入声明后才能接入整项任务缓存。

## 6. 配置与清理

| 环境变量 | 含义 |
| --- | --- |
| `BUILD_JOBS` | 总编译线程预算，默认 `nproc` |
| `BUILD_PARALLEL_TASKS` | 每个并行边界的并发任务上限 |
| `BUILD_CACHE=0` | 关闭框架编译缓存及整项任务缓存 |
| `BUILD_CACHE_DIR` | 缓存根目录，默认 `build/.cache` |
| `BUILD_REBUILD=1` | 跳过整项任务命中检查，成功后更新记录 |

保留现有 `CCACHE_DIR`、CMake launcher、`CARGO_BUILD_JOBS` 和 `RUSTC_WRAPPER` 等显式覆盖。缺少 ccache/sccache 时回退到普通编译。

普通目标 `clean` 应只清理该目标拥有的构建产物，不清理其他目标和公共缓存。`build.sh cleanall` 会删除整个 `build/`；若需要跨 cleanall 保留缓存，将 `BUILD_CACHE_DIR` 设置在其外部。

## 7. 新目标验收要求

接入时必须验证：首次构建成功；重复构建可以正确复用；源码、补丁、配置、工具链和依赖变化触发重建；输出损坏触发重建；失败后可以重试；并行任务不争写源码或产物；clean 不删除其他目标的数据。

使用统一日志报告缓存命中/失效原因、线程预算、耗时和错误状态。编译缓存的小型基准不能作为整个镜像提速比例的证明，完整目标需单独测量。

公共回归入口：`bash scripts/tests/build-performance.sh`。它包含真实 Make/CMake 编译、线程预算、任务并发、缓存失效和补丁生命周期测试。

边界回归入口：`python3 scripts/tests/build-review-regressions.py`，覆盖编译器选择、异常进程退出、失败传播、文件类型区分及构建期间工具变化。

## 附录：Zephyr 迁移案例

旧版本曾把产物写到 `build/zephyr/orangepi-5-plus/` 等位置，而 `build/zephyr/` 本身就是源码仓库。这会使 Ninja、CMake 和 ELF 文件出现在源码状态检查中，影响补丁验证和增量缓存判断。

现在采用：

```text
build/zephyr/                              # 现有源码路径，保持兼容
build/objects/zephyr/orangepi-5-plus/       # 编译中间产物
build/objects/zephyr/<平台>-<应用>/         # 其他应用的独立构建目录
IMAGES/orangepi/zephyr/                    # 最终产物
```

此例展示通用目录隔离规则在 Zephyr 上的应用，其他组件应按正文中的同一规则接入。

公共源码准备流程只会保护能验证的旧 CMake 产物目录：`CMakeCache.txt` 中记录的目录必须与实际路径一致，且该目录不能含 Git 已跟踪文件。通过验证后，将精确目录加入源码仓库本地 `.git/info/exclude`，避免后续源码清理删除旧产物。此机制仅用于旧数据兼容，不允许新目标继续混放。
