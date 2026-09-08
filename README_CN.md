# TGOS Images 仓库

[English](README.md) | 中文

## 简介

本仓库包含 TGOS 相关镜像的构建脚本、补丁与辅助工具，覆盖以下内容：

- 面向具体平台的 Linux、ArceOS 与 StarryOS 构建流程
- `scripts/os/` 下的通用 OS 构建器
- `scripts/rootfs/` 下的根文件系统生成器
- 打包与发布辅助脚本
- 使用 `http_server.py` 进行本地镜像分发

仓库目前已经按职责对 `scripts/` 重新分层，不再是所有脚本都平铺在同一级目录下。

## 仓库结构

| 路径 | 说明 |
| --- | --- |
| `build.sh` | OS、rootfs、release 的统一入口 |
| `run.sh` | QEMU Linux 镜像的快速启动辅助脚本 |
| `scripts/platform/` | 各平台入口脚本，如 Phytium Pi、QEMU、Orange Pi 等 |
| `scripts/os/` | 通用 OS 构建器，如 ArceOS、StarryOS、Zephyr、FreeRTOS 和 RT-Thread |
| `scripts/apps/` | 使用 TGOSImages 工具链构建外部仓库应用的入口及中文说明 |
| `scripts/rootfs/` | BusyBox、Alpine、Debian 根文件系统生成脚本 |
| `scripts/tools/` | 打包、发布及其他辅助工具 |
| `scripts/lib/` | 共享 shell 工具函数 |
| `patches/` | 构建过程中应用到上游项目的补丁 |
| `IMAGES/` | 最终构建产物 |
| `build/` | 下载缓存、源码目录和临时构建输出 |
| `release/` | 打包脚本生成的归档文件 |

## 脚本分类

### 平台脚本

这类脚本是面向具体平台的主入口，通常负责拉取源码、打补丁、调用厂商或上游构建系统，并将产物复制到 `IMAGES/`。

| 脚本 | 主要职责 |
| --- | --- |
| `scripts/platform/phytiumpi.sh` | 构建 Phytium Pi 客户机镜像 |
| `scripts/platform/roc-rk3568-pc.sh` | 构建 ROC-RK3568-PC 客户机镜像 |
| `scripts/platform/evm3588.sh` | 构建 EVM3588 客户机镜像 |
| `scripts/platform/tac-e400-plc.sh` | 构建 TAC-E400-PLC 客户机镜像 |
| `scripts/platform/orangepi-5-plus.sh` | 构建 Orange Pi 5 Plus 客户机镜像 |
| `scripts/platform/rdk-s100p.sh` | 构建 RDK-S100P 客户机镜像 |
| `scripts/platform/bst-a1000.sh` | 构建 BST-A1000 客户机镜像 |
| `scripts/platform/qemu.sh` | 构建 QEMU 客户机镜像，并在需要时串联 rootfs 生成流程 |

### 通用 OS 构建器

这类脚本提供可复用的 OS 构建流程，可被平台脚本调用，也可以直接单独执行。

| 脚本 | 主要职责 |
| --- | --- |
| `scripts/os/arceos.sh` | 通用 ArceOS 构建器 |
| `scripts/os/starry.sh` | StarryOS 客户机内核构建器 |
| `scripts/os/zephyr.sh` | 通用 Zephyr 构建器 |
| `scripts/os/freertos.sh` | 通用 FreeRTOS 构建器 |
| `scripts/os/rtthread.sh` | 通用 RT-Thread 构建器 |

外部应用入口的使用方法见 `scripts/apps/README.md`。当前包含 AKA RK3588 Zephyr 机器人
控制应用构建入口。

### Rootfs 生成脚本

这类脚本负责生成文件系统内容或根文件系统镜像。

| 脚本 | 主要职责 | 典型产物 |
| --- | --- | --- |
| `scripts/rootfs/busybox.sh` | 基于 BusyBox 生成最小 rootfs | `initramfs-<arch>-busybox.cpio.gz`、`rootfs-<arch>-busybox.img` |
| `scripts/rootfs/alpine.sh` | 下载 Alpine minirootfs 并生成 ext4 镜像 | `rootfs-<arch>-alpine.img` |
| `scripts/rootfs/debian.sh` | 基于 Docker + debootstrap 生成 Debian rootfs 镜像 | `rootfs-<arch>-debian.img` |

## 支持的目标

### 平台 OS 目标

`build.sh os <target>` 当前支持以下平台目标：

- `phytiumpi`
- `roc-rk3568-pc`
- `evm3588`
- `tac-e400-plc`
- `orangepi-5-plus`
- `rdk-s100p`
- `bst-a1000`
- `qemu`
- `qemu-aarch64`
- `qemu-riscv64`
- `qemu-x86_64`
- `qemu-loongarch64`

其中：

- `qemu` 会顺序执行 `qemu-aarch64`、`qemu-x86_64`、`qemu-riscv64`、`qemu-loongarch64`
- `qemu-aarch64`、`qemu-riscv64`、`qemu-x86_64`、`qemu-loongarch64` 底层调用的是 `scripts/platform/qemu.sh`

`scripts/platform/qemu.sh` 当前支持：

- `aarch64`
- `riscv64`
- `x86_64`
- `loongarch64`

### Rootfs 目标

`build.sh rootfs <target>` 当前支持：

- `busybox`
- `alpine`

`scripts/rootfs/debian.sh` 目前作为独立脚本提供，支持：

- `aarch64`
- `riscv64`
- `x86_64`
- `loongarch64`

`scripts/rootfs/alpine.sh` 当前支持：

- `aarch64`
- `loongarch64`
- `riscv64`
- `x86_64`

说明：
`loongarch64` 已经作为 Debian 脚本目标存在，但 Debian `trixie` 主仓库当前并不提供 `loong64` 包，因此该架构建议使用 `sid` / `unstable` 等更合适的 suite。

## 构建环境准备

执行构建前，请确保宿主机具备足够磁盘空间、可访问所需源码仓库或内网 SDK 服务，并安装相应工具链。

在 Ubuntu 24.04 或相近发行版上，可先安装一组实用的基础依赖：

```bash
sudo apt update
sudo apt install \
  flex bison libelf-dev libssl-dev \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  gcc-riscv64-linux-gnu g++-riscv64-linux-gnu \
  bc fakeroot coreutils cpio gzip rsync file \
  debootstrap binfmt-support debian-archive-keyring eatmydata \
  e2fsprogs docker.io \
  python3 python3-venv curl git openssh-client libmpc-dev libgmp-dev \
  lz4 chrpath gawk texinfo diffstat expect cmake
```

部分平台还需要：

- 访问私有仓库
- 访问内网 SDK 主机 `10.3.10.194`
- 安装厂商 SDK 依赖
- 具备管理员权限或免密 sudo

## 快速开始

### 统一入口

`build.sh` 是推荐的统一入口。

```bash
./build.sh help

# 平台 OS 构建
./build.sh platform phytiumpi
./build.sh platform qemu all
./build.sh platform qemu-aarch64 linux
./build.sh platform qemu all --rootfs busybox,alpine,debian

# Orange Pi 5 Plus StarryOS 客户机内核
./build.sh platform orangepi-5-plus starry

# rootfs 构建
./build.sh rootfs busybox aarch64 --out_dir IMAGES/rootfs
./build.sh rootfs alpine riscv64 --out_dir IMAGES/rootfs/alpine-riscv64.img

# 打包
./build.sh release pack
```

### 直接执行脚本

如果需要更细粒度的控制，可以直接调用平台脚本：

```bash
scripts/platform/phytiumpi.sh all
scripts/platform/qemu.sh aarch64 linux
scripts/platform/qemu.sh riscv64 all
scripts/platform/evm3588.sh arceos
```

如果只需要 rootfs，可直接调用 rootfs 脚本：

```bash
scripts/rootfs/busybox.sh aarch64 --out_dir IMAGES/rootfs
scripts/rootfs/alpine.sh x86_64 --img-size 2G
scripts/rootfs/debian.sh riscv64 --debian trixie --out_dir IMAGES/rootfs
scripts/rootfs/debian.sh loongarch64 --debian unstable --out_dir IMAGES/rootfs
```

## Rootfs 说明

### 外层与嵌套镜像

每个 ext4 构建器都从同一个干净基础镜像分出两条独立的组合分支：

```text
干净基础镜像
├── 客户机分支 + 客户机测试插件 -> 嵌套 rootfs
└── 外层分支 + 外层测试插件 + /guest 平台文件
    └── /guest/rootfs-<arch>-<type>.img（嵌套 rootfs）
```

客户机插件安装到嵌套镜像的 `/guest-tests/<plugin>`。外层镜像在 `/guest`
下包含平台文件，并在 `/guest/rootfs-<arch>-<type>.img` 保存原始嵌套镜像；
外层专用平台文件和 `/opt/ltp` 不会进入嵌套镜像。系统刻意不生成
`run-all.sh`：选择测试只负责打包测试资源，不规定执行顺序，也不会自动运行。

默认值如下：

| 镜像范围 | BusyBox | Alpine | Debian |
| --- | --- | --- | --- |
| 外层测试 | `none` | `ltp` | `none` |
| 嵌套客户机测试 | `cyclictest,lmbench,iozone` | `cyclictest,lmbench,iozone` | `cyclictest,lmbench,iozone` |

嵌套与外层 ext4 默认各保留 256 MiB 空闲空间。嵌套镜像以未压缩原始文件
嵌入，因此外层原始镜像可能明显变大；发布阶段的 xz 压缩包仍可能小得多，
但不保证固定压缩大小阈值。BusyBox ext4 同样参与组合。旧有 initramfs
继续保留平台文件注入，但不包含客户机测试插件和嵌套 rootfs。

直接构建 rootfs 的示例：

```bash
scripts/rootfs/busybox.sh x86_64 \
  --outer-tests none --guest-tests cyclictest \
  --guest-free-size 128M --outer-free-size 384M
scripts/rootfs/alpine.sh aarch64 \
  --outer-tests ltp --guest-tests cyclictest,lmbench,iozone \
  --guest-free-size 256M --outer-free-size 512M
```

QEMU 流程会透传相同选项：

```bash
./build.sh platform qemu-x86_64 linux --rootfs busybox,alpine,debian \
  --outer-tests none --guest-tests cyclictest \
  --guest-free-size 256M --outer-free-size 512M
```

使用 `none` 可让某个范围不安装测试；非默认构建可传入逗号分隔的明确列表。

### Rootfs 测试插件

可执行的 `scripts/rootfs-tests/plugins/*.sh` 文件是扩展入口。插件实现两个命令：

- `describe` 必须恰好输出 `name=`、`arches=`、`rootfs=`、`scopes=` 四行。
- `build --arch <arch> --rootfs <type> --scope <outer|guest> --output <empty-dir>`
  向指定空目录写入 overlay。客户机插件通常使用 `guest-tests/<name>/`，
  外层插件则写入它在外层 rootfs 中的原生路径。

新增插件时，可复制一个现有的小型插件，固定上游版本与 SHA256，只声明实际支持
的组合；如包含二进制，应为所选架构生成静态 ELF64，并扩展快速插件测试。
框架会自动发现插件，无需维护中央列表。Overlay 只接受目录、普通文件和符号链接；
特殊节点与额外的元数据路径会被拒绝。下载缓存与解压源码按已校验的 checksum
区分并记录 checksum 来源，构建容器则由配置中的镜像版本固定。

### BusyBox

- 同时生成 initramfs 和 ext4 rootfs 镜像
- 被 `scripts/platform/qemu.sh` 用于 QEMU 的 Linux / ArceOS 流程
- 当前支持 `aarch64`、`loongarch64`、`riscv64`、`x86_64`

### Alpine

- 下载 Alpine 官方 `minirootfs`
- 使用 SHA256 校验下载文件
- 只生成干净的 Alpine 基础镜像；默认外层 `ltp` 插件另行构建并把筛选后的 LTP 20260529 内容安装到 `/opt/ltp`
- 遵循 Alpine 排除规则：跳过 `fmtmsg` 目录与 `timer_create01`、`timer_create03`，保留 `timer_create02`
- 通过共享且校验 checksum 的 Alpine 插件构建器编译 LTP
- 生成 ext4 rootfs 镜像
- 当前支持 `aarch64`、`loongarch64`、`riscv64`、`x86_64`

### Debian

- 基于 Docker + `debootstrap`
- 生成 ext4 rootfs 镜像
- 默认 suite 为 `trixie`
- 支持 `aarch64`、`riscv64`、`x86_64`、`loongarch64`

### Rootfs 验证

耗时镜像构建前先运行不触发构建的快速测试：

```bash
scripts/tests/rootfs-nested-content-test.sh
scripts/tests/qemu-rootfs-test-options.sh
scripts/tests/rootfs-builder-options.sh
scripts/tests/rootfs-test-plugins.sh
scripts/tests/rootfs-compose.sh
scripts/tests/starry-release-smoke.sh
```

构建完成后，可在不挂载镜像的情况下验证指定内容：

```bash
scripts/tests/rootfs-nested-content.sh --image-dir IMAGES/rootfs \
  --arch x86_64 --rootfs busybox \
  --guest-tests cyclictest,lmbench,iozone \
  --guest-free-size 256M --outer-free-size 256M
scripts/tests/alpine-ltp-content.sh --image-dir IMAGES/rootfs --arch x86_64
```

BusyBox 端到端夹具构建需要显式启用：

```bash
scripts/tests/rootfs-builder-options.sh --integration
```

完整 QEMU 验证同样是可选的，并需按架构手动执行：

```bash
./build.sh platform qemu-aarch64 all --rootfs busybox,alpine,debian
./build.sh platform qemu-riscv64 all --rootfs busybox,alpine,debian
./build.sh platform qemu-x86_64 all --rootfs busybox,alpine,debian
./build.sh platform qemu-loongarch64 all --rootfs busybox,alpine
```

这些构建或验证命令都不会自动执行 `run-all.sh`；工作负载必须在客户机中显式调用。

## 输出目录

构建产物统一收集到 `IMAGES/`。常见位置如下：

| 路径 | 内容 |
| --- | --- |
| `IMAGES/qemu-<arch>/linux` | 对应架构的 QEMU Linux 内核产物 |
| `IMAGES/qemu-<arch>/arceos` | 对应架构的 QEMU ArceOS 二进制 |
| `IMAGES/rootfs` | 直接由 rootfs 脚本生成的独立镜像 |
| `IMAGES/<platform>/linux` | 某硬件平台的 Linux 产物 |
| `IMAGES/<platform>/arceos` | 某硬件平台的 ArceOS 产物 |
| `IMAGES/orangepi/starry/orangepi-5-plus` | 可放入客户机根文件系统 `/guest/starry/orangepi-5-plus` 的 StarryOS 内核 |
| `IMAGES/orangepi-5-plus-starry` | 独立 StarryOS 发布包的暂存目录（镜像、manifest 和 SHA256） |

### Orange Pi 5 Plus StarryOS

推荐使用统一入口：

```bash
./build.sh platform orangepi-5-plus starry
```

构建脚本固定使用 tgoskits 中的
`os/StarryOS/configs/board/orangepi-5-plus.toml`，默认构建 tgoskits 最新的
`dev` 分支。生成的 `manifest.toml` 会记录实际构建提交。需要复现或验证指定提交时可显式覆盖：

```bash
./build.sh platform orangepi-5-plus starry --ref <tgoskits-commit>
```

构建完成后：

- 客户机加载文件：`IMAGES/orangepi/starry/orangepi-5-plus`
- 独立发布暂存目录：`IMAGES/orangepi-5-plus-starry/`
- 发布归档：执行 `./build.sh release pack` 后得到
  `release/orangepi-5-plus-starry.tar.xz`
- 清理产物：`./build.sh platform orangepi-5-plus starry clean`

发布包可由镜像注册表识别为 `orangepi-5-plus-starry`（`aarch64`）。本地验证脚本：

```bash
scripts/tests/starry-release-smoke.sh
```

QEMU Linux 的典型文件包括：

- `Image`，用于 `aarch64` / `riscv64`
- `bzImage`，用于 `x86_64`
- `vmlinuz.efi` 与 `vmlinux.elf`，用于 `loongarch64`
- `linux-qemu` 作为通用 QEMU Linux 入口名；对于 `loongarch64`，它是从 `vmlinux.elf` 复制得到的 ELF 镜像
- BusyBox 产物，如 `initramfs-<arch>-busybox.cpio.gz`、`rootfs-<arch>-busybox.img`

## QEMU 快速验证

可以用 `run.sh` 快速启动本地 QEMU 进行验证：

```bash
./run.sh aarch64 ramfs
./run.sh riscv64 rootfs
./run.sh x86_64 rootfs
```

QEMU 平台构建产物现在统一位于 `IMAGES/qemu-<arch>/` 下。
对于 LoongArch64，平台包 `qemu-loongarch64.tar.xz` 会同时包含
`linux/vmlinuz.efi` 与 `linux/vmlinux.elf`；其中 `linux/linux-qemu` 是 QEMU
平台流程使用的通用入口名，指向 `vmlinux.elf`。
rootfs 独立发布，默认包括 `initramfs-loongarch64-busybox.cpio.gz.tar.xz`、
`rootfs-loongarch64-busybox.img.tar.xz` 与 `rootfs-loongarch64-alpine.img.tar.xz`。

## 打包与发布

### 打包产物

```bash
./build.sh release pack

# 或直接调用脚本
scripts/tools/pack.sh --in_dir IMAGES --out_dir release
```

### 发布到 GitHub Release

`--pack IMAGES,release` 表示先将 `IMAGES/` 中的产物打包到 `release/`，然后发布 `release/` 目录中的文件。

```bash
./build.sh release github \
  --pack IMAGES,release \
  --token <GITHUB_TOKEN> \
  --repo rcore-os/tgosimages \
  --tag v0.0.10

# 或直接调用脚本
scripts/tools/github.sh \
  --pack IMAGES,release \
  --token <GITHUB_TOKEN> \
  --repo rcore-os/tgosimages \
  --tag v0.0.10
```

## 本地分发

`http_server.py` 基于 Python 标准库从 `IMAGES/` 提供 HTTP 文件服务。

```bash
python3 http_server.py start
python3 http_server.py status
python3 http_server.py restart -p 9000 -b 127.0.0.1
python3 http_server.py stop
```

如果需要在共享网络中暴露该服务，建议结合防火墙或反向代理限制访问。

## 贡献

欢迎围绕以下方向提交改进：

- 新平台脚本
- 现有构建流程优化
- rootfs 生成能力增强
- 文档修正与补充

提交 Pull Request 前，请保持脚本风格一致，并说明复现步骤。

## 许可证

本项目基于 MIT License，详见 [LICENSE](LICENSE)。
