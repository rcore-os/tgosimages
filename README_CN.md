# TGOS Images 仓库

[English](README.md) | 中文

## 简介

本仓库包含 TGOS 相关镜像的构建脚本、补丁与辅助工具，覆盖以下内容：

- 面向具体平台的 Linux 与 ArceOS 构建流程
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
| `scripts/os/` | 通用 OS 构建器，如 ArceOS、Zephyr、FreeRTOS 和 RT-Thread |
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
| `scripts/os/zephyr.sh` | 通用 Zephyr 构建器 |
| `scripts/os/freertos.sh` | 通用 FreeRTOS 构建器 |
| `scripts/os/rtthread.sh` | 通用 RT-Thread 构建器 |

### Rootfs 生成脚本

这类脚本负责生成文件系统内容或根文件系统镜像。

| 脚本 | 主要职责 | 典型产物 |
| --- | --- | --- |
| `scripts/rootfs/busybox.sh` | 基于 BusyBox 生成最小 rootfs | `busybox-initramfs-<arch>.cpio.gz`、`busybox-rootfs-<arch>.img` |
| `scripts/rootfs/alpine.sh` | 下载 Alpine minirootfs 并生成 ext4 镜像 | `alpine-rootfs-<arch>.img` |
| `scripts/rootfs/debian.sh` | 基于 Docker + debootstrap 生成 Debian rootfs 镜像 | `debian-rootfs-<arch>.img` |

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

### BusyBox

- 同时生成 initramfs 和 ext4 rootfs 镜像
- 被 `scripts/platform/qemu.sh` 用于 QEMU 的 Linux / ArceOS 流程
- 当前支持 `aarch64`、`loongarch64`、`riscv64`、`x86_64`

### Alpine

- 下载 Alpine 官方 `minirootfs`
- 使用 SHA256 校验下载文件
- 从 `https://github.com/linux-test-project/ltp/releases/download/20260529/ltp-full-20260529.tar.xz` 构建并安装 LTP syscall 测例到 `/opt/ltp`
- 在 Alpine Docker 容器内通过 `apk add` 安装构建依赖并编译 LTP
- 生成 ext4 rootfs 镜像
- 当前支持 `aarch64`、`loongarch64`、`riscv64`、`x86_64`

### Debian

- 基于 Docker + `debootstrap`
- 生成 ext4 rootfs 镜像
- 默认 suite 为 `trixie`
- 支持 `aarch64`、`riscv64`、`x86_64`、`loongarch64`

## 输出目录

构建产物统一收集到 `IMAGES/`。常见位置如下：

| 路径 | 内容 |
| --- | --- |
| `IMAGES/qemu-<arch>/linux` | 对应架构的 QEMU Linux 内核产物 |
| `IMAGES/qemu-<arch>/arceos` | 对应架构的 QEMU ArceOS 二进制 |
| `IMAGES/rootfs` | 直接由 rootfs 脚本生成的独立镜像 |
| `IMAGES/<platform>/linux` | 某硬件平台的 Linux 产物 |
| `IMAGES/<platform>/arceos` | 某硬件平台的 ArceOS 产物 |

QEMU Linux 的典型文件包括：

- `Image`，用于 `aarch64` / `riscv64`
- `bzImage`，用于 `x86_64`
- `vmlinuz.efi` 与 `vmlinux.elf`，用于 `loongarch64`
- `linux-qemu` 作为通用 QEMU Linux 入口名；对于 `loongarch64`，它是从 `vmlinux.elf` 复制得到的 ELF 镜像
- BusyBox 产物，如 `busybox-initramfs-<arch>.cpio.gz`、`busybox-rootfs-<arch>.img`

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
