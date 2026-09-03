# Rootfs 双分支与可扩展测例组合设计

## 背景

当前 QEMU 构建流程先生成 BusyBox、Alpine 或 Debian rootfs，再把
`IMAGES/qemu-<arch>` 中的平台产物注入最终 rootfs 的 `/guest`。Alpine
还会在自身构建阶段安装 LTP。

后续需要让最终的外层 rootfs 同时携带一个可供客户机使用的 ext4
rootfs 镜像。外层与客户机需要的测例不同，并且两边以后都可能增加新的
测例，不能把 LTP、cyclictest、LMBench 或 IOZone 写死在镜像组合逻辑中。

## 目标

- 从同一份不含测例的基础 rootfs 分出外层和客户机两个 ext4 镜像。
- 外层与客户机分别使用独立、可配置、可扩展的测例集合。
- 保留 Alpine 外层 rootfs 中现有的 LTP。
- 客户机默认加入 cyclictest、LMBench 和 IOZone，目标路径为
  `/guest-tests`。
- 把客户机 ext4 镜像放入最终外层 rootfs 的 `/guest`。
- 根据真实负载调整两个镜像的大小，避免复制标称容量中的大量空闲空间。
- BusyBox ext4 rootfs 参与完整的双分支流程；BusyBox initramfs 不参与
  分支、客户机测例注入或内嵌镜像流程。

## 非目标

- 不生成 `run-all.sh` 或规定测例运行方式。
- 不把客户机镜像压缩后放入外层；内嵌文件必须是可直接使用的 ext4
  `.img`。
- 不改变现有 QEMU 平台产物在外层 `/guest` 下的组织方式。
- 不在镜像组合代码中维护固定测例名称列表。

## 总体流程

每种架构和 rootfs 类型都先形成一份无测例的基础内容，再产生两个分支：

```text
基础 rootfs
├── outer.img
│   ├── 注入 outer-tests overlay
│   ├── 注入现有 QEMU 平台产物
│   └── 在 /guest 中嵌入 guest.img
│
└── guest.img
    └── 注入 guest-tests overlay
```

必须先完成 `guest.img`，再将它加入 `outer.img`。不得从已经含有
`/guest/rootfs-*.img` 的外层镜像生成客户机副本，以免递归嵌套。

最终 Alpine 镜像示例：

```text
rootfs-aarch64-alpine.img
├── opt/ltp/
└── guest/
    ├── <现有 QEMU 平台产物>
    └── rootfs-aarch64-alpine.img
        └── guest-tests/
            ├── cyclictest/
            ├── lmbench/
            └── iozone/
```

其中三个客户机测例只是初始默认集合，不是固定上限。

## 测例插件系统

### 目录

新增统一的 rootfs 测例构建入口和插件目录：

```text
scripts/rootfs-tests/
├── build.sh
└── plugins/
    ├── ltp.sh
    ├── cyclictest.sh
    ├── lmbench.sh
    └── iozone.sh
```

`build.sh` 负责参数解析、插件选择、输出隔离、缓存协调和最终 overlay
合并。插件负责单个测例的下载、版本固定、校验、编译、安装及产物检查。

### 插件接口

每个插件作为独立可执行脚本，通过统一参数调用：

```text
<plugin>.sh build \
  --arch <arch> \
  --rootfs <busybox|alpine|debian> \
  --scope <outer|guest> \
  --output <empty-output-directory>
```

每个插件还必须通过统一的 `describe` 子命令声明支持的架构、rootfs 类型
和 scope。`build.sh` 根据这些能力声明解析显式列表和 `all`，组合层不按
插件名称维护特殊判断。显式选择不支持当前组合的插件时必须失败；`all`
只选择声明支持当前组合的插件。

插件必须：

- 使用固定版本或 commit，并校验下载内容；
- 支持的架构包括当前 rootfs 能覆盖的 aarch64、riscv64、x86_64 和
  loongarch64；不支持的组合必须明确失败；
- 将文件按镜像中的最终相对路径写入输出目录；
- 不读取或修改其他插件的输出；
- 检查关键文件、执行权限、ELF 架构和运行时解释器/依赖；
- 使用插件名和版本隔离源码与构建缓存。

首批源码建议固定为官方发布或受维护的上游版本：cyclictest 使用
kernel.org 的 rt-tests 发布包；LMBench 使用 Intel 维护仓库的固定 commit；
IOZone 使用官方发布包。确切 ref 和校验值在实施计划中记录，不能跟随
`latest` 漂移。

LTP 插件首期只声明支持 `rootfs=alpine`、`scope=outer`。因此无论使用
显式列表还是 `all`，LTP 都不能进入客户机镜像，也不能进入 BusyBox 或
Debian 外层镜像。未来若需求改变，必须通过修改并验证插件能力声明显式
扩展范围。

优先生成静态链接产物，使同架构 overlay 可用于不同 libc 的 rootfs。
如果某个测例无法可靠静态链接，则插件根据 `--rootfs` 构建对应 libc 的
产物，缓存键也必须包含 rootfs 类型。

### 集合与输出

统一入口分别构建两个集合：

```text
build.sh --scope outer --tests <comma-separated-list> ...
build.sh --scope guest --tests <comma-separated-list> ...
```

支持 `--tests all` 和 `--tests none`。`all` 表示所有声明支持当前
架构、rootfs 类型及 scope 的已注册插件。

各插件先写入独立临时目录，通过验证后才合并到集合 overlay。若两个
插件产生相同的文件或符号链接目标，构建必须失败，不能静默覆盖。多个
插件可以共享目录祖先（例如 `/guest-tests`），但文件与目录冲突、符号
链接与目录冲突以及祖先文件阻塞后代路径都必须拒绝。

初始默认集合为：

| Rootfs | outer-tests | guest-tests |
| --- | --- | --- |
| Alpine | `ltp` | `cyclictest,lmbench,iozone` |
| BusyBox ext4 | 空 | `cyclictest,lmbench,iozone` |
| Debian | 空 | `cyclictest,lmbench,iozone` |

默认值可以由顶层构建参数覆盖，例如 `--outer-tests` 和
`--guest-tests`。镜像组合层只接收两个已合并的 overlay 目录，不解析
具体测例名。

客户机默认 overlay 为：

```text
overlay/
└── guest-tests/
    ├── cyclictest/
    ├── lmbench/
    └── iozone/
```

不创建统一运行脚本。

## Rootfs 分支边界

基础分支点必须位于发行版基础内容、默认软件包和启动配置完成之后，任何
outer-tests、guest-tests、`--guest` 内容或 QEMU 平台产物加入之前。

现有 rootfs 构建参数 `--guest <dir>` 明确定义为外层内容：对 ext4 只注入
outer 的 `/guest`，不得进入公共基础或内嵌客户机镜像。BusyBox initramfs
继续保留当前 `--guest` 注入行为，但仍不参与双分支流程。

Alpine 当前在镜像打包前直接调用 LTP 安装函数。实施时应把 LTP 构建与
安装改造成 outer-tests overlay 提供者，使 LTP 不再污染公共基础分支，
但默认 Alpine 最终外层镜像的内容保持不变。

BusyBox ext4 和 Debian 在未传入 `--guest` 时，现有构建结果可作为公共
基础镜像。它们不需要把测例逻辑加入发行版构建函数；分支和 overlay
注入由公共组合层完成。此处以及后续“BusyBox 镜像”的表述均只指
`rootfs-<arch>-busybox.img`，不包括 `initramfs-<arch>-busybox.cpio.gz`。

## 镜像组合

公共组合层复用 `scripts/lib/rootfs.sh` 中现有的 ext 文件系统 overlay
注入能力，并新增职责明确的辅助函数：

- 从基础镜像安全地产生 outer/guest 临时副本；
- 检查和缩放 ext 文件系统；
- 根据待注入文件的表观大小与 ext4 可用块计算扩容量；
- 原子发布最终镜像。

组合顺序如下：

1. 复制基础镜像为 `outer.img` 和 `guest.img`。
2. 根据 guest-tests overlay 的表观大小检查 `guest.img` 的可用块；如有
   必要，先扩展镜像和 ext4 文件系统，确保注入容量充足。
3. 将 guest-tests overlay 注入 `guest.img`。
4. 校验并收缩 `guest.img`，随后增加客户机可写余量。
5. 将 outer-tests overlay 注入 `outer.img`；同样必须在注入前按 overlay
   大小预检和扩容。
6. 准备最终 `/guest` staging tree，其中包含现有 QEMU 平台产物和已经
   完成的 `guest.img`。
7. 计算 staging tree 所需空间，扩展 `outer.img`。
8. 将 staging tree 注入 `outer.img`。
9. 再次执行文件系统检查和内容验证。
10. 原子替换 `IMAGES/rootfs/rootfs-<arch>-<type>.img`。

QEMU 平台产物和 rootfs 当前并行构建，因此实现可以把第 5 至第 8 步作为
并行构建结束后的第二次原子外层注入。该实现必须具备与初次组合相同的
注入前容量预检、嵌入镜像路径冲突检查、失败时保留旧镜像、注入后余量
验证和 `e2fsck` 检查；不能继续直接原地修改最终 ext4 镜像。

内嵌客户机镜像固定命名为：

```text
/guest/rootfs-<arch>-<rootfs-type>.img
```

如果现有平台产物占用同一路径，组合必须报冲突并停止。

## 容量策略

不能直接把标称 2 GiB 的客户机镜像嵌入另一个 2 GiB 镜像。客户机分支
先根据 overlay 表观大小、当前 ext4 可用块和注入期安全余量执行容量预检；
空间不足时先增长镜像文件并扩展 ext4。完成注入后再执行：

1. `e2fsck -f`；
2. `resize2fs -M` 收缩到最小可用容量；
3. 在最小容量上增加可配置的客户机余量；
4. 再次扩展 ext4 文件系统并检查。

客户机默认余量为 256 MiB，通过 `--guest-free-size` 调整。

外层扩容按实际需求计算，而不是使用固定最终大小。计算时至少包含：

- 当前 ext4 已用块和可用块；
- outer-tests overlay 的表观大小；
- QEMU 平台 staging tree 的表观大小；
- 内嵌客户机镜像的完整文件长度；
- ext4 元数据与块取整开销；
- 注入完成后要求保留的外层可写余量。

外层默认余量为 256 MiB，通过 `--outer-free-size` 调整。扩容后必须重新
读取 ext4 可用块进行预检；空间仍不足时停止，不允许依赖注入工具部分写入
后才发现失败。

每一阶段只统计尚未注入的 payload。outer-tests 已经注入后，后续为
`/guest` staging tree 扩容时不得再次把 outer-tests 大小计入需求。

发布压缩仍在最终镜像产生之后统一进行。`/guest` 中保存原始 ext4 镜像，
不以压缩体积代替运行时容量计算。

## Initramfs 行为

BusyBox `.cpio.gz` 不进入上述双分支流程：

- 不嵌入客户机 rootfs；
- 不注入 guest-tests overlay；
- 不因客户机镜像扩容；
- 现有 QEMU 平台产物注入行为保持不变。

以上限制只适用于 initramfs。`rootfs-<arch>-busybox.img` 是 ext4 镜像，
正常参与 outer/guest 分支、guest-tests 注入、容量调整和客户机镜像嵌入。

## 失败处理与可重复构建

- 下载文件必须先写临时路径，校验通过后进入缓存。
- 每个插件和每个镜像分支使用独立临时目录。
- 使用 trap 清理临时镜像，但不删除已有正式产物。
- 任一插件失败会使对应 rootfs 构建失败，不能发布缺少部分测例的镜像。
- 所有镜像修改完成并验证后才通过同目录临时文件原子替换目标。
- 重复构建从公共基础分支重新组合，不能向上一次最终镜像继续注入。
- 并行构建共用下载缓存时使用锁或原子下载，禁止同时写同一缓存文件。

## 验证

自动验证至少覆盖：

- 插件选择：默认列表、显式列表、`all`、`none` 和未知插件；
- 插件路径冲突能够被拒绝；
- 首批三个客户机插件产生 `/guest-tests/<name>`；
- Alpine outer overlay 含 `/opt/ltp`，guest overlay 不含 `/opt/ltp`；
- 外层镜像包含内嵌客户机镜像和现有 QEMU 平台产物；
- 提取出的客户机镜像能通过 `e2fsck`；
- 客户机镜像含选中的 guest-tests，不含 outer-tests 和外层 `/guest`
  平台产物；
- 最终 outer/guest 镜像的可用空间不小于配置值；
- BusyBox initramfs 不含内嵌 rootfs 和 `/guest-tests`；
- 四种架构的 ELF 文件与目标架构匹配；
- 至少对一个架构执行 outer 和 guest 的启动冒烟测试。

## 兼容性

- 最终外层镜像名称保持 `rootfs-<arch>-<type>.img`。
- 现有 QEMU 平台产物路径保持不变。
- Alpine 外层默认继续携带 LTP。
- BusyBox initramfs 保持现有构建和平台注入方式。
- 新参数均提供默认值；未增加额外测例时无需修改镜像组合代码。
