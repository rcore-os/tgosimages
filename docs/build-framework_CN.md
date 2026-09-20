# 全局构建规范与目标接入要求

本文统一约束所有平台、OS、rootfs、应用以及构建辅助脚本，既用于新增目标，也用于现有目标的改造。所有目标必须复用公共构建层，不能各自维护线程数、编译缓存和日志策略。

下文的 Zephyr 仅用于说明已发现的问题和迁移方式。目录隔离、缓存失效、补丁处理、资源调度、日志和清理规则对所有组件同样适用。

## 1. 目录必须按用途隔离

| 类型 | 目录约定 | 要求 |
| --- | --- | --- |
| 上游源码 | `build/sources/<组件>/` | 新组件优先使用；已有源码路径可继续兼容 |
| 中间产物 | `build/objects/<组件>/<目标或架构>/` | 独立于源码目录；配置或工具链不兼容时进一步分目录 |
| 任务工作区 | `build/workspaces/<任务>/` | 保存任务独占的源码副本和构建目录，整次任务持有锁 |
| 编译及任务缓存 | `build/.cache/` | 由公共层管理，可通过 `BUILD_CACHE_DIR` 调整 |
| 最终镜像/产物 | `IMAGES/<目标>/` | 只放供运行、打包或交付的产物 |
| 构建日志 | `logs/<类别>/` | 使用公共日志入口 |

**所有目标不得把 `.o`、CMake/Ninja 构建目录、临时打包文件或最终镜像写进源码 checkout。** 即使增加 `.gitignore`，也不能替代目录隔离。同一源码的不同架构、板型和不兼容配置不得共用中间产物目录。

对于支持 out-of-tree 构建的工具，使用 CMake 的 `-S/-B` 或项目支持的 Make `O=`。若上游确实只支持 in-tree 构建，应在该任务的独占工作区中创建源码副本或工作树；不要让多个任务修改下载缓存中的共享源码。

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

一次构建调用的总编译线程预算自动取当前进程可用逻辑 CPU 的八分之五；公共并行入口向子任务分配较小预算。图调度器默认从 `ceil(sqrt(预算))` 个并发槽位起步（预算 16、50、100 时分别为 4、8、10）；cgroup v2 可用时每 10 秒按同一构建 cgroup 的 CPU 使用量和 CPU、I/O、内存压力按倍率调整新节点准入，上限为初始槽位的两倍，下限为一半。不支持指标时保持初始槽位；已启动工具的 `-j` 不变，但调度预留量可回收供新节点使用。显式设置 `BUILD_PARALLEL_TASKS` 会固定任务数上限并关闭自动槽位调节；旧并行入口仍按该值限制单个并行边界。

新增有依赖关系的批量入口声明任务图，通过 `build_graph <graph.json> --log-dir <日志目录>` 执行，不再嵌套创建并行池。旧入口仍可使用 `run_parallel_functions` 或 `run_sequential_targets`。共享可变源码、相同输出文件或可变配置的任务，必须声明依赖/互斥资源，或者先隔离工作区；跨进程工作区锁必须覆盖准备源码到构建完成的整个阶段，不能只锁 checkout。

此预算不会限制其他独立构建进程、远程 SDK 服务器或不使用公共入口的外部脚本。用户显式传入的工具级线程参数也可能覆盖默认值，新增目标不应依赖这些覆盖。

运行 shell 函数步骤时，不要把 `run_parallel_functions` 或其外层构建函数放入 `if`、`!`、`&&`、`||` 条件列表并依赖步骤内部的 `set -e`；Bash 会在这种上下文中抑制 errexit。需接收失败结果时，应暂时关闭调用层的 errexit，直接调用运行器、记录退出码，再恢复原设置，参考 QEMU 和 Orange Pi 的调用方式。汇总器还必须处理子进程未写状态文件就退出的情况，使用进程退出码报告失败。

### 全平台任务接入

`platform all` 将七个板级平台和四个 QEMU 架构的组件汇总到一张任务图，只调用一次调度器。平台和架构是分组；Linux、ArceOS、rootfs、IVC、组装等步骤是执行节点。`platform qemu all` 和单平台命令选择对应子图及其依赖，不再先完成一个平台再启动另一个。组件完成后释放预算，后续就绪任务根据当时的空闲预算启动。已启动的 Make/Ninja 不会被动态调整线程数。需要串行时设置 `BUILD_PARALLEL_TASKS=1`。

每个 QEMU 架构的组装依赖本架构全部组件；组装中的 IVC 准备可能修改 Linux/ArceOS 源码，因此不能与这些组件重叠。香橙派 Linux → rootfs 按序使用上游 checkout；IVC 等待 Starry、Zephyr，base image 等待全部产物，finalize 等待 base image。飞腾派、ROC、EVM 的 rootfs 注入是独立组装节点，组件失败后不会注入旧产物；飞腾派注入失败也会返回失败。

节点失败后会停止整张任务图，终止正在运行的节点并取消未启动任务。源码准备和 patch 校验当前仍在各组件内执行，尚未拆为独立节点。`platform clean` 仍按平台顺序清理，各板级 clean 使用同一工作区锁及预算，QEMU clean 保留原工作区入口。图调度器按平台获取工作区锁，不因一个平台的锁等待而阻塞其余平台启动。

板级声明集中在 `scripts/lib/platform-tasks.json`：`components` 列出可执行函数，`deps` 声明先后关系，`resources` 声明互斥资源，`private` 隐藏内部组装函数，`compose` 启用独立 rootfs 注入。`platform-graph.py` 汇总声明；`platform-node.sh` 在独立 Bash 中加载平台与公共库，再执行单个步骤。新增平台同时注册 CLI 入口，并在平台脚本初始化工作区前接入 `platform-graph-entry.sh`，不新增调度器。

ROC、EVM、RDK 的 Linux SDK 节点共用 `vendor-sdk` 互斥资源，当前图内串行。外部 SDK 自己控制线程数，本地预算不能强制限制远程进程，也不能防止其他机器直接操作 SDK；这类 SDK 仍需要服务端锁和资源管理。

### 公共任务声明

`build_graph` 位于 `scripts/lib/build-performance.sh`；也可以直接执行 `python3 scripts/lib/python/build-graph.py graph.json --log-dir logs/my-run`。每次调用使用新的日志目录。

```json
{
  "cwd": "/absolute/repository",
  "locks": ["/absolute/build/workspaces/.locks/example.lock"],
  "env": {"BUILD_CACHE_DIR": "/absolute/build/.cache"},
  "tasks": [
    {
      "id": "example.prepare",
      "command": ["bash", "scripts/example.sh", "prepare"],
      "cpu_max": 1,
      "resources": ["example.source"]
    },
    {
      "id": "example.compile",
      "deps": ["example.prepare"],
      "command": ["bash", "scripts/example.sh", "compile"],
      "cpu_min": 1,
      "cpu_max": 8,
      "memory_mb": 2048,
      "resources": ["example.source"]
    }
  ]
}
```

- `id` 全图唯一；`deps` 必须引用已有节点，环和无法满足的资源要求会在执行前被拒绝。
- `command` 是可执行文件及参数数组；用独立脚本恢复配置，不序列化当前 shell 的函数/变量。节点可设置自己的 `cwd`、`env`。
- `cpu_min` 默认 1，`cpu_max` 默认总预算。调度器同时限制总 CPU 配额和任务数，设置 Make/CMake/Cargo 的预算环境变量；任务仍须调用公共编译适配器。节点内不要另建并行池。
- `resources` 是同一张图中的互斥资源名；它不能代替跨进程文件锁。`locks` 是整个调用持有的工作区锁，按路径排序获取，子进程不继承锁描述符。QEMU 与原有 workspace launcher 使用同一锁文件。
- `memory_mb` 是声明的预计占用，只有设置 `BUILD_MEMORY_MB` 时才参与准入判断；它不是操作系统内存限制。未声明默认为 0，QEMU 目前未提供可靠的内存估计。
- 可选 `cache_args` 是现有 `build_task` 的输入/输出/patch/工具链声明参数数组，例如 `["--input", "config", "--output", "objects/image"]`。任务名和命令由调度器传入。只有完整声明输入后才能启用。缓存节点会自动把直接依赖中已声明的输出加入自己的输入；依赖产物内容变化时下游失效，依赖虽重跑但产物内容未变时下游仍可命中。

日志目录保存 `graph.json`、`state.json`、`summary.log` 和 `steps/<任务ID>.log`。状态包括 waiting、running、hit、success、failed、blocked、cancelled；失败展示尾部日志，SIGINT/SIGTERM 会终止运行中的任务进程组后释放工作区。没有自动重试或断点恢复；重新执行时重新判断源码/产物缓存。

新增隔离任务通过 `build_workspace_run <任务标识> <可执行命令> [参数...]` 启动。工作区锁覆盖完整命令，公共层向全部子进程传递 `BUILD_WORK_DIR`。各脚本必须通过 `build_paths_init` 初始化 `BUILD_DIR`，不能自行回到仓库根目录的 `build/`。

板级平台使用 `build/workspaces/<平台>/`，QEMU 使用 `build/workspaces/qemu-<架构>/`。单平台、批量和 clean 命令使用相同工作区锁；此外统一持有仓库 `build/.locks/platform-<目标>.lock`，防止不同 `BUILD_WORKSPACE_ROOT` 的调用争写同一份最终镜像。所有锁按路径顺序获取，并持有到该次调用结束。默认最终产物仍写入原有 `IMAGES/` 路径。目标工作区不得是符号链接，显式指定到工作区之外的可变源码目录会被拒绝；只读工具链可以共享。旧板级源码不自动搬迁，首次使用新工作区需要重新准备。

飞腾派、ROC、EVM 的单组件命令也会加入 Linux 节点，再执行 rootfs 注入，避免依赖缺失镜像或旧镜像。调度器在启动任何节点前验证环境变量和参数类型；失败节点退出后会终止同进程组的遗留子进程，再释放资源。任务不得把构建进程自行脱离进程组。`platform all` 入口直接替换为调度器进程，向入口发送 SIGTERM 可触发统一取消。

Git 下载缓存在 `${BUILD_CACHE_DIR}/git/` 中，通过锁串行更新，每个工作区拥有独立 Git 对象、checkout 和 patch 状态，不通过 alternates 或硬链接依赖缓存。新 clone 会同步上游默认分支；明确 commit 的下载可以复用。下载缓存独立于编译/整项任务缓存开关。

旧构建目录不迁移、不删除；新工作区首次运行会重新准备源码。执行 `cleanall` 前应停止构建，因为它还会删除默认工作区及其锁。

### 新增一个编译内容

新增 Linux、RTOS、应用或固件等编译内容时，按下面的顺序接入，不要直接在 `all` 中后台启动一个新函数：

1. **先定义边界。** 确定唯一节点 ID、独占工作区、中间产物目录和最终输出。最终输出写入 `IMAGES/<平台>/<组件>/`；源码和中间产物不能把公共下载缓存当工作区。
2. **实现单节点命令。** 在对应的 `scripts/platform/<平台>.sh` 或 `scripts/os/<组件>.sh` 中实现一个可独立执行的函数，使用 `build_make`、`build_cmake`、`build_cargo` 或 `build_scons`。成功返回前必须生成全部声明输出，失败必须返回非零。
3. **注册任务图。** 现有板级平台把函数名加入 `scripts/lib/platform-tasks.json` 的 `components`；用 `deps` 声明数据依赖，用 `resources` 声明同图内不能并发使用的共享可变资源。QEMU OS 还要更新 `scripts/platform/qemu.sh` 的目标选择、`qemu-graph.py` 的 guest 输出映射及 `QEMU_OS_CACHE`。其他流程在自己的图适配器中使用 `phase_task` 或 `BuildPipeline`，不要新增调度器。
4. **声明缓存契约。** 至少声明构建脚本、配置、源码 URL/ref 或已准备源码、补丁目录、影响产物的环境变量、工具链以及全部输出。若 clone/checkout 仍在同一节点内，用 `values` 记录固定 URL/ref；更推荐拆成 prepare/build，使 build 节点通过 `sources` 检查已经准备好的源码。任何无法完整描述输入、只做校验、修改外部系统或执行 `clean` 的节点都不要启用整节点缓存。
5. **连接后续步骤。** 缓存节点会自动继承直接依赖缓存节点的输出；非缓存依赖没有输出契约，消费者必须把实际产物显式放进 `inputs`。不要仅为“上游运行过”而强制下游失效：上游输出内容相同就允许下游命中。
6. **补测试。** 至少覆盖首次执行、相同输入命中、源码/ref/补丁/配置或依赖产物变化后重建、输出缺失或损坏后重建、失败不发布缓存，以及并发时不争写工作区和最终产物。自定义编译目标和 `clean` 还要验证不会误用完整构建缓存。

普通缓存节点示例：

```python
task = phase_task(
    'example-aarch64.kernel',
    'build',
    ['bash', 'scripts/os/example.sh', 'aarch64'],
    deps=['example-aarch64.prepare'],
    resources=['example.source'],
    cache={
        'inputs': ['scripts/os/example.sh', 'configs/example-aarch64.config'],
        'outputs': ['IMAGES/example-aarch64/kernel/example.bin'],
        'values': ['arch=aarch64', 'SOURCE_REF=<fixed-commit>'],
        'environment': ['CROSS_COMPILE', 'PATH'],
        'tools': ['aarch64-linux-gnu-gcc'],
        'patches': ['patches/example'],
    },
)
```

`inputs` 和 `outputs` 不能互相包含，也不能指向同一目录树。一个输出只能由一个节点拥有；多个变体写相同路径时，应拆分输出目录，磁盘成本确实不可接受时才使用同一个 `resources` 互斥键。完整构建参数可以缓存，任意 Make/Cargo 子目标应保守地保持不缓存，除非它也拥有独立、完整的输出契约。

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

现有镜像任务不会因为引入公共框架就自动跳过；完成完整输入声明后才能接入整项任务缓存。QEMU 的 Linux、ArceOS、Zephyr 和 FreeRTOS 完整构建节点已接入该缓存；`clean` 和自定义子目标不会复用完整构建记录。

## 6. 配置与清理

| 环境变量 | 含义 |
| --- | --- |
| `BUILD_PARALLEL_TASKS` | 显式设置时固定图调度器并发任务上限、关闭自适应槽位；旧入口为每个并行边界上限 |
| `BUILD_HEARTBEAT_SECONDS` | 任务图心跳间隔，默认 `60` 秒；显示活动节点耗时、线程数、日志路径和最新进度 |
| `BUILD_MEMORY_MB` | 图调度器声明内存的总预算，默认 0 不限制 |
| `BUILD_CACHE=0` | 关闭框架编译缓存及整项任务缓存 |
| `BUILD_CACHE_DIR` | 缓存根目录，默认 `build/.cache` |
| `BUILD_REBUILD=1` | 跳过整项任务命中检查，成功后更新记录 |
| `BUILD_WORKSPACE_ROOT` | 工作区根目录，默认 `build/workspaces` |
| `BUILD_SOURCE_CACHE_DIR` | Git 下载缓存，默认 `${BUILD_CACHE_DIR}/git` |
| `ROOTFS_GUEST_COUNT` | 零编号嵌套客户机 rootfs 数量，默认 `2`，最小 `1`，无固定上限 |
| `LOG_COLOR` | `auto` 自动终端着色、`always` 强制着色、`never` 关闭 |

保留现有 `CCACHE_DIR`、CMake launcher 和 `RUSTC_WRAPPER` 等显式覆盖。图调度器按自动预算分配 CPU 配额并设置 `CARGO_BUILD_JOBS`，防止节点继承更大的外层预算。缺少 ccache/sccache 时回退到普通编译。

终端颜色约定：进度青色、成功绿色、警告黄色、失败红色，不为具体节点或架构设置特殊颜色。`auto` 尊重 `NO_COLOR` 和 `TERM=dumb`。框架先保存纯文本日志，再对终端显示着色；子任务捕获流不加颜色，第三方工具原始输出不重新格式化。

普通目标 `clean` 应只清理该目标拥有的构建产物，不清理其他目标和公共缓存。`build.sh cleanall` 会删除整个 `build/`；若需要跨 cleanall 保留缓存，将 `BUILD_CACHE_DIR` 设置在其外部。

## 7. 新目标验收要求

使用公共 rootfs 组合流程的外层镜像必须包含 `ROOTFS_GUEST_COUNT` 份独立 guest rootfs；该变量默认为 `2`，接受大于等于 `1` 的十进制整数，不设置固定上限。复制开始前会根据单份镜像大小和宿主机可用空间拒绝当前机器无法容纳的数量。文件从 `/guest/rootfs-<arch>-<type>-0.img` 开始零编号，直到 `-(count-1).img`。所有副本初始内容相同，复用一次测例构建结果，以不同普通文件保存；每份分别满足 guest 空闲空间配置。组装时必须计算全部副本、平台载荷、元数据及 outer 预留空间所需容量，并保护全部编号文件名，同时拒绝旧的无编号名称。该规则同时适用于普通 ext4 外层镜像和香橙派分区磁盘镜像；BusyBox initramfs 仍不嵌套 guest 镜像。

rootfs 测例不得隐藏在 rootfs 镜像节点内部。图生成器把每个已选择插件展开为叶子节点，例如 `tests.guest.cyclictest`、`tests.guest.lmbench`、`tests.guest.iozone` 和 `tests.outer.ltp`；同一 scope 的插件完成后进入 `overlay.outer` 或 `overlay.guest` 合并节点。合并节点检查路径和祖先冲突，产出独占目录。干净基础 rootfs 是另一个无测例节点；最终 rootfs 镜像节点等待基础 rootfs 和两个 overlay，生成配置数量的 guest 与外层镜像。平台镜像组装再依赖最终 rootfs。

所有 guest 共用一个 `overlay.guest` 结果，所以测例只编译一次。outer 与 guest 是不同安装范围，即使插件名称相同也保持不同节点。插件的下载、源码和 builder 缓存继续使用 `ROOTFS_TEST_BUILD_ROOT` 及文件锁；节点的线程预算来自全局调度器。QEMU 的 BusyBox/Alpine/Debian 和香橙派 guest rootfs 已采用该结构。

香橙派的 guest 链为“基础 guest → guest overlay 注入 → 多 guest 外层磁盘组装”；QEMU 链为“基础 rootfs + outer/guest overlay → 多 guest rootfs → 平台载荷注入”。BusyBox 的基础节点同时生成 initramfs，最终 rootfs 节点使用原有双文件回滚发布，避免只更新 ext4 或 initramfs 其中一个。

接入时必须验证：首次构建成功；重复构建可以正确复用；源码、补丁、配置、工具链和依赖变化触发重建；输出损坏触发重建；失败后可以重试；并行任务不争写源码或产物；clean 不删除其他目标的数据。

使用统一日志报告缓存命中/失效原因、线程预算、耗时和错误状态。编译缓存的小型基准不能作为整个镜像提速比例的证明，完整目标需单独测量。

公共回归入口：`bash scripts/tests/build/build-performance.sh`。它包含真实 Make/CMake 编译、线程预算、任务并发、缓存失效和补丁生命周期测试。

图调度回归：`python3 scripts/tests/build/build-graph.py`，验证真实子进程重叠与预算回收、依赖失败传播、互斥/内存准入、缓存阶段命中、依赖产物变化向下游传播以及中断释放锁。产物损坏导致缓存失效由 `build-performance.sh` 覆盖。

rootfs 子图回归：`python3 scripts/tests/rootfs/rootfs-graph.py`，验证插件叶子并行、overlay 合并依赖和最终消费者顺序；`scripts/tests/rootfs/rootfs-compose.sh` 使用真实 ext4 验证基础节点、可配置 guest 组合及原子注入。

边界回归入口：`python3 scripts/tests/build/build-review-regressions.py`，覆盖编译器选择、异常进程退出、失败传播、文件类型区分及构建期间工具变化。

平台集成回归入口：`python3 scripts/tests/build/qemu-parallel.py`，通过本地 Git 仓库验证跨架构与跨平台调度重叠、单图汇总、香橙派阶段依赖、单平台依赖选择、失败隔离、独立补丁/配置、共享下载及工作区互斥。终端颜色与日志文件隔离由边界回归测试覆盖。

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
