# Orange Pi Zephyr shell

Zephyr shell 仍属于 Zephyr 客户机，输出沿用 `IMAGES/orangepi/zephyr/orangepi-5-plus`、`.elf` 和 `.dtb`。它提供普通 IVC 测试，以及可按需启动的 AKA 控制端。AKA 协议、控制代码、Kconfig 和 UART6 overlay 来自外部 `aka-rk3588` 源码，本仓库只负责构建接入。

## 构建 Zephyr

在 tgosimages 根目录执行：

```sh
scripts/apps/ivc-rk3588.sh --shell-only \
  --ivc-sdk-dir "$PWD/build/ivc-validation-20261012/ivc-sdk" \
  --aka-dir "$PWD/build/aka-validation-20261012/aka-rk3588"
```

上面的独立 `ivc-rk3588.sh` 入口不传 `--aka-dir` 时构建普通 IVC shell；平台入口 `./build.sh platform orangepi-5-plus zephyr` 默认接入同级 `aka-rk3588` 控制源码。源码接入保留 `zephyr:~$` 提示符，AKA `main` 编译为 `aka_rk3588_run`，不会修改 AKA checkout。可以用 `ZEPHYR_IMAGES_DIR` 指定验证输出目录；正式目录和镜像命名保持原样。

`aka run` 在后台启动实际控制循环；`aka status` 显示运行状态与返回值。同次启动只允许一个 AKA 实例。`aka_run=0` 只表示启动成功，完整联调以感知端 CI 结果为准。普通 `ivc` 命令会等待测试完成，校验完消息或超时后自动返回 shell，并打印 `state=passed/failed result=...`。不再提供单独的 `ivc wait`。默认总超时 30000 毫秒，可用例如 `ivc subscriber 1000` 指定 1 秒；允许范围为 1 至 600000 毫秒。等待、发送、接收和 benchmark 共享窗口等待使用同一个截止时间。等待期间按 Ctrl+C 可主动停止；超时或停止后由工作线程正常结束，命令返回真实结果，主动停止显示 `state=canceled`。删除了只重复打印状态、并不停止任务的 `stop` 入口。

## 基础功能检查

普通 IVC 和 AKA 构建均启用 Zephyr 内置检查命令：

```text
kernel version
kernel thread list
device list
```

它们分别显示内核版本、线程状态（包括 `shell_uart`、`idle`）和设备列表。原独立三客户机基础检查应用已并入本 shell；使用统一构建入口和 `IMAGES/orangepi/zephyr/orangepi-5-plus{,.elf,.dtb}`，不再生成另一套功能检查镜像。设备名称以本次 DTB 为准，AKA 的 PL011 控制台和机器人 UART6 由其 overlay 选择。客户机内存继续使用已有 128 MiB overlay。

## 客户机文件系统

沿用已有 `IMAGES/rootfs/rootfs-aarch64-orangepi-jammy.img`，AKA 程序、模型、真实运行库和校准配置安装在客户机 `/opt/aka`。原客户机系统和 cyclictest、lmbench、iozone 等内容保留。既有 Orange Pi rootfs 构建入口默认从 `IMAGES/orangepi/aka` 加入运行包，也可通过 `ORANGEPI_AKA_PACKAGE` 覆盖：

```sh
ORANGEPI_AKA_PACKAGE="$PWD/build/aka-validation-20261012/board/aka" \
  scripts/platform/orangepi-5-plus.sh rootfs
```

已有客户机镜像的验证副本可用 `scripts/apps/orangepi-aka-rootfs.sh --base-image PATH --aka-package DIR --output NEW_PATH` 注入相同内容；它只复用现有系统，不创建另一套发行版。

感知端必须链接真实 AArch64 运行库。`scripts/apps/orangepi-aka-perception.sh --help` 给出源码、SDK、目标库、头文件和交叉编译器参数。该入口严格解析符号，检查 UVC 动态绑定，并排除构建主机的 `/usr/include`。不能使用外部 AKA 默认交叉构建的空动态库桩及忽略未解析符号的选项。

实际运行库包括 `librknnrt.so`、`libuvc.so.0`、`libusb-1.0.so.0`、`libturbojpeg.so.0`、`libjpeg.so.8` 和 `libudev.so.1`；glibc/加载器沿用客户机。`scripts/lib/aka-rootfs.sh` 在 ext4 构建时递归验证 ELF 依赖及 AArch64 类型，缺库则失败。校准参数使用这台机器已有的真实文件，重建程序时不要覆盖为默认参数。

## 临时板端验证

正式产物仍在既有 IMAGES 目录。`build` 是中间产物，板端 `/guest/ivc-test` 是临时部署位置：

```text
/guest/ivc-test/starry/orangepi-5-plus
/guest/ivc-test/zephyr/orangepi-5-plus
/guest/ivc-test/zephyr/orangepi-5-plus.dtb
/guest/ivc-test/rootfs/rootfs-aarch64-orangepi-jammy.img
```

StarryOS 通过 virtio-blk 挂载独立 ext4，沿用已有测例自动选择磁盘，并使用 `init=/bin/sh`。eMMC/SD 不直通；相机、RKNPU 与 Zephyr UART6 仍沿用设备配置。AKA 文件来自客户机 `/opt/aka`。默认验证不依赖 cpio。

```sh
export CARGO_TARGET_DIR="$PWD/build/ivc-validation-20261012/target"
cd /home/yanlien/Workspace/QCL/hypervisor/tgoskits-pr
cargo xtask axvisor test board -g normal \
  -c board-orangepi-5-plus/aka-starry-shell \
  --server http://10.3.10.60:2999 -b OrangePi-5-Plus-robot-emmc
```

板卡测试配置放在 TGOSKits 的 `apps/axvisor/normal/board-orangepi-5-plus/aka-starry-shell/`，本仓库不保存测试配置副本。

TGOSKits 核心 IVC 映射/关闭修复只由 `tgoskits-pr` 维护；本仓库不保存或自动应用核心补丁。构建使用 `/home/yanlien/Workspace/QCL/hypervisor/tgoskits-pr` 的修复后源码；输出通过 `CARGO_TARGET_DIR` 放入 tgosimages/build。逻辑关闭后保留 DMA 可见内存，物理回收仍要求停稳证明，因此当前重复测试使用板级复位。

当前 AKA 功能验收要求真实相机、NPU、车轮和机械臂，31 项控制检查、至少 62000 ms 完整运行、正常退出、清理与零丢包，并输出 `AKA_SHELL_CI_PASS`。现有脚本只接受正数 FPS，正式测例采用 `--min-fps 0.01` 确认数据产出，不评估吞吐性能。普通输入预检和握手成功不能作为整体通过。

## 验证记录

2026-10-12：此前 cpio 方案已通过启动、校准传输、IVC 双向握手 tx=11/rx=11、模型加载和摄像头采集；结果 dropped=0，但性能窗口只有 7.92 FPS，完整 CI 失败。计时主要耗时为 JPEG 解码和 NPU 推理。该记录属于历史验证，不代表目前 ext4 方案完整通过。旧独立控制镜像此前也卡在宿主映射限制。最新 ext4 结果见 `logs/aka-validation-20261012`。

2026-10-13：原始 tgoskits-pr 的宿主存储交接修复使 virtio-blk/ext4 根启动通过；配置及核心修复均在 TGOSKits。相同镜像在 A55 上：统一 shell 8.58 FPS、旧自动控制镜像 8.27 FPS、JPEG NEON 对照 8.45 FPS，均未达标。只将 StarryOS vCPU 分配到实际 Cortex-A76（MPIDR 0x400）后，完整对照通过：两个窗口 28.45/30.00 FPS、31 项控制检查、62022 ms、cleanup=1、ivc_dropped=0，输出 AKA_SHELL_CI_PASS。正式用例采用该 A76 分配；上述 28 FPS 判定属于历史性能验证，当前正式用例按完整功能流程验收。历史记录见 logs/aka-validation-20261012/board-aka-formal-ext4-final.log。


## 三客户机普通 IVC 验证

统一用例位于 TGOSKits 的 `apps/axvisor/normal/board-orangepi-5-plus/ivc`。Linux 为 VM 1、StarryOS 为 VM 2、Zephyr 为 VM 3，Zephyr 排在最后。一次启动中依次验证三个组合。

`ivc subscriber` 校验 Linux 的五条 `linux-to-zephyr-N` 请求，并回复对应的 `zephyr-to-linux-N`。`ivc ivc_demo` 沿用原 Starry demo，先批量发送五条 `zephyr-to-starry-N`，再校验五条 `starry-to-zephyr-N`。每条消息均包含换行，N 从 1 到 5。

两条 Linux 链路和 Starry 对端使用本仓库构建的 `ivc-roundtrip`，传入发布者、通道 key 和消息前缀。测试要求全部消息内容及序号正确，客户端正常关闭，最终三个客户机仍为 Running。Zephyr 的保留映射由板级复位清理。

Linux 发布者先启动，再执行 Zephyr 的同步订阅命令。Zephyr–StarryOS 链路先等 Zephyr 的通道发布标记，再通过 AxVisor 切换到 StarryOS 启动对端；回到 Zephyr 后收集最终状态，不使用 `ivc wait`。测例验证订阅在无对端时约 1 秒返回 ETIMEDOUT，并验证 Ctrl+C 在 30 秒截止时间前主动停止，随后工作线程仍可执行命令。

## 定时器中断偏差测量

`irq latency` 在真实 `arm_arch_timer_compare_isr` 中采样，跳过前 5 次，收集 10000 个有效样本；默认超时 30 秒，支持 Ctrl+C。ISR 只更新统计，cycles 与纳秒的最小、平均、最大值在命令线程中打印。

- `IRQ_LATENCY`：当前 IRQ 采样时刻相对实际编程 compare 时刻的绝对偏差。周期模式下等于参考代码的 `abs(curr_cycle - last_cycle - CYC_PER_TICK)`。现有 tickless 模式按实际编程间隔计算，避免把正常跨多个 tick 的间隔误算为迟到。
- `IRQ_INTERVAL_DEVIATION`：相邻两次 IRQ 的实际进入间隔与对应编程 compare 间隔之差的绝对值。

命令运行期间用 1 ms 的软件定时器心跳保证真实 ARM 定时器 IRQ 持续产生；保留原有 tickless 设置、compare 写入、last_cycle 更新和 tick 通告逻辑。构建从上游驱动生成本应用专用的观察副本，上游 Zephyr checkout 不修改。ISR 的原有采样位置包含进入 ISR 后到读取计数器之间的开销；结果反映当前客户机及 AxVisor 的定时器服务时序。

```text
irq latency
irq latency 1000
```

第二条将总超时设为 1 秒；若未完成 10000 个样本，输出已收集的部分统计并返回超时。该功能使用单 vCPU，复用已有启动环境，没有新增独立测例目录。


### Orange Pi 默认 AKA

`./build.sh platform orangepi-5-plus all` 默认将 AKA 感知运行包安装到客户机 ext4 的 `/opt/aka`，并在统一 Zephyr shell 中构建 AKA 控制端；启动后用 `aka run` 主动运行控制逻辑。

默认控制源码为同级 `../aka-rk3588`，不存在时自动下载。默认感知运行包为 `IMAGES/orangepi/aka`，必须包含真实 AArch64 程序、模型、运行库和本机校准配置；该目录被 Git 忽略。新构建环境需先准备该包，可用 `scripts/apps/orangepi-aka-perception.sh` 构建感知程序，再保留真实运行库和校准文件。`all` 校验并安装运行包，不会凭空生成硬件校准参数。

可通过 `ORANGEPI_AKA_SOURCE_DIR`（或 `--aka-dir`）覆盖控制源码，通过 `ORANGEPI_AKA_PACKAGE` 覆盖感知运行包。关闭默认 AKA：

```sh
ORANGEPI_WITH_AKA=0 ./build.sh platform orangepi-5-plus all
```

此开关影响本次构建；此前已有镜像需重新构建 rootfs 才会移除 `/opt/aka`。
