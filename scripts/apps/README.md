# 外部应用构建入口

本目录存放“业务应用属于其他仓库、系统构建环境属于 TGOSImages”场景的薄封装脚本。

主要外部应用入口：

```text
scripts/apps/aka-rk3588-zephyr.sh
scripts/apps/ivc-rk3588.sh
scripts/apps/orangepi-aka-package.sh
```

`aka-rk3588-zephyr.sh` 查找 AKA 中的控制应用，然后调用 `scripts/os/zephyr.sh`，使用本仓库管理的 Zephyr
版本、补丁、交叉工具链和 Orange Pi 5 Plus board 配置生成客户机镜像。

`ivc-rk3588.sh` 查找或下载 `ivc-sdk`，构建 Zephyr IVC demo/benchmark 客户机镜像、
Starry 用户态程序和 StarryOS 客户机镜像，并把板端需要的文件收集到 Orange Pi 发布目录。

Orange Pi 三客户机基础功能检查统一使用 `apps/zephyr/orangepi-shell`，通过
`ivc-rk3588.sh --shell-only` 构建，与 IVC 和可选 AKA 控制端共用同一镜像。

本目录脚本不复制业务源码，也不负责修改 TGOSKits、部署镜像、启动 AxVisor 或运行板端
程序。

---

## 1. 仓库职责和结构

### 1.1 仓库关系

`tgosimages`、`aka-rk3588` 和 `ivc-sdk` 是彼此独立的 Git 仓库，不要求使用固定的父目录
名称或本地 checkout 布局。本文命令默认从命令所属仓库的根目录执行。

```text
aka-rk3588/                               # 感知、公共协议和机器人控制应用
ivc-sdk/                                  # Starry/Linux/Zephyr 共用 AXIVC SDK
tgosimages/                               # 系统构建环境和发布产物
├── scripts/os/zephyr.sh                  # 通用 Zephyr 构建器
├── scripts/apps/aka-rk3588-zephyr.sh     # AKA Zephyr 入口
├── scripts/apps/ivc-rk3588.sh            # AXIVC demo/benchmark 入口
├── patches/zephyr/                       # Zephyr 补丁
├── build/                                # AKA/Zephyr 源码、SDK、构建缓存
└── IMAGES/                               # 最终镜像
```

### 1.2 职责边界

AKA 负责机器人业务：

- 摄像头采集和 RKNN 推理；
- Starry→Zephyr 公共消息协议；
- IVC 发布端和订阅端适配；
- 底盘决策、机械臂状态机和看门狗；
- UART6/Feetech 业务使用方式；
- 机器人参数和控制单元测试。

TGOSImages 负责构建环境：

- 固定 Zephyr 源码版本并应用补丁；
- 准备 Python 环境和 AArch64 交叉工具链；
- 提供 Orange Pi 5 Plus Zephyr board；
- 调用 CMake/Ninja 构建 AKA application；
- 收集 BIN、ELF 和 DTB。

IVC SDK 负责通信公共实现：

- Starry/Linux 的 `libaxivc`；
- Zephyr AXIVC module 和 AxVisor HVC platform backend；
- AXIVC v2 region、ring、slot 和公共 API。

TGOSKits/AxVisor 负责板端系统集成：

- 创建 StarryOS 和 Zephyr 两台客户机；
- 分配 vCPU、内存和设备；
- 提供 IVC 共享区和通知；
- 把 UART6 直通给 Zephyr；
- 组装、上传和启动板端镜像。

### 1.3 为什么控制源码放在 AKA

如果 Starry 感知代码在 AKA、Zephyr 控制代码在 TGOSImages，会导致一项机器人功能需要
跨两个仓库修改，公共协议也容易被两边重复定义。

现在感知、协议和控制统一由 AKA 维护，但运行时仍分别位于 StarryOS 与 Zephyr 两台客户机。
TGOSImages 继续独立管理 Zephyr 系统环境，不引入具体机器人的状态机和动作参数。

---

## 2. TGOSImages 为此增加的能力

相关文件：

```text
.gitignore
README_CN.md
scripts/os/zephyr.sh
scripts/apps/README.md
scripts/apps/aka-rk3588-zephyr.sh
```

机器人控制应用、公共协议及其测试属于 AKA，不应复制进 TGOSImages。

### 2.1 通用 Zephyr 构建器支持外部应用

`scripts/os/zephyr.sh` 新增：

```text
--app <path>
```

路径规则：

- 绝对路径直接作为 CMake application source；
- 相对路径仍相对于下载后的 `ZEPHYR_SRC_DIR`；
- 未提供 `--app` 时继续使用各平台原来的默认 application。

使用自定义应用时，构建目录会追加 application basename：

```text
build/objects/zephyr/orangepi-5-plus-orangepi_robot_control
```

这可以避免与默认 benchmark 共用构建目录。

脚本还会比较 `CMakeCache.txt` 中的 `CMAKE_HOME_DIRECTORY`。如果缓存来自应用迁移前的
另一个源码路径，只重建对应 application build directory，避免 CMake 继续链接旧源码。

该修改没有改变 Zephyr 固定 ref、补丁流程、SDK、Python 环境、Orange Pi board 和其他
平台的默认 application。

### 2.2 AKA 专用入口

`aka-rk3588-zephyr.sh` 只负责：

1. 查找或下载 AKA；
2. 检查 `zephyr/orangepi_robot_control/CMakeLists.txt`；
3. 打印实际使用的路径、commit 和工作区状态；
4. 把应用绝对路径交给通用 Zephyr 构建器。

最终调用关系：

```text
scripts/apps/aka-rk3588-zephyr.sh
    ↓ --app <AKA绝对路径>/zephyr/orangepi_robot_control
scripts/os/zephyr.sh orangepi-5-plus
    ↓
CMake + Ninja
```

### 2.3 生成目录忽略规则

仓库已忽略 `build/`、`IMAGES/`、`release/` 等生成目录，并补充：

```text
/twister-out*/
```

Twister 生成的 CMake cache、对象文件、ELF、XML/JSON 和日志都不应提交。

---

## 3. 基本使用方法

### 3.1 从 TGOSImages 构建

推荐命令：

```bash
# 在 tgosimages 仓库根目录执行
./scripts/apps/aka-rk3588-zephyr.sh
```

脚本按以下顺序查找 AKA：

1. `--aka-dir <路径>`；
2. 环境变量 `AKA_RK3588_DIR`；
3. `${BUILD_DIR}/aka-rk3588`（默认 `build/aka-rk3588`，设置 `BUILD_WORK_DIR` 时使用该工作目录）；
4. 以上均不存在时，从 `https://github.com/bullhh/aka-rk3588.git` 下载到该目录，默认检出 `dual` 分支。

`master` 分支不包含所需的 Zephyr 控制应用。`--aka-ref` 或 `AKA_RK3588_REF` 可覆盖首次下载的版本；显式指定的已有源码不会自动更新或切换；自动下载到构建目录的源码重跑时会更新并清除残留改动。

`ivc-sdk` 可通过 `--ivc-sdk-dir` 或 `IVC_SDK_DIR` 指定，默认使用 `${BUILD_DIR}/ivc-sdk-source`。不存在时 clone
`https://github.com/rcore-os/ivc-sdk.git` 的当前默认分支；显式指定的已有 checkout 按原样使用；默认构建缓存会更新并清理。

输出会包含：

```text
TGOSIMAGES_DIR=<tgosimages-checkout>
AKA_RK3588_DIR=<aka-rk3588-checkout>
AKA_RK3588_COMMIT=<commit>
AKA_RK3588_WORKTREE=clean|dirty
```

应先检查这些信息，确认没有选错同名仓库或遗漏未提交源码。

### 3.2 指定 AKA 路径

```bash
./scripts/apps/aka-rk3588-zephyr.sh \
  --aka-dir <aka-rk3588-checkout>
```

同时指定 SDK：

```bash
./scripts/apps/aka-rk3588-zephyr.sh \
  --aka-dir <aka-rk3588-checkout> \
  --ivc-sdk-dir <ivc-sdk-checkout>
```

或者：

```bash
AKA_RK3588_DIR=<aka-rk3588-checkout> \
./scripts/apps/aka-rk3588-zephyr.sh
```

### 3.3 下载地址和版本

AKA 不存在时可以覆盖 clone 地址：

```bash
./scripts/apps/aka-rk3588-zephyr.sh \
  --aka-repo-url https://example.com/aka-rk3588.git
```

为自动管理的构建源码指定 branch、tag 或 commit：

```bash
./scripts/apps/aka-rk3588-zephyr.sh \
  --aka-ref <ref>
```

默认构建目录中的 AKA 和 IVC SDK 会在重跑时获取指定版本，清除源码残留改动和未跟踪文件后继续构建，不做备份。

通过 `--aka-dir`、`--ivc-sdk-dir` 或对应路径环境变量指定的已有工作树按原样使用，不自动切换版本或清理；这类已有源码会忽略 ref 参数。

### 3.4 从 AKA 侧构建

AKA 提供对称入口：

```bash
# 在 aka-rk3588 仓库根目录执行
./scripts/build_zephyr_control.sh
```

该脚本定位同级 TGOSImages 后，仍会调用本目录的专用入口。因此两个命令使用相同 AKA
源码和相同 TGOSImages 工具链，不存在两份控制实现。

非同级布局：

```bash
./scripts/build_zephyr_control.sh \
  --tgosimages-dir <tgosimages-checkout>
```

### 3.5 传递 Zephyr 参数

本入口不认识的参数会继续传给 `scripts/os/zephyr.sh`。

指定镜像名称：

```bash
./scripts/apps/aka-rk3588-zephyr.sh \
  --image-name orangepi-robot-control
```

指定输出目录：

```bash
./scripts/apps/aka-rk3588-zephyr.sh \
  --images-dir <output-directory>
```

查看通用参数：

```bash
./scripts/os/zephyr.sh --help
```

### 3.6 构建 AXIVC demo 和 benchmark

Orange Pi 5 Plus 上的 Zephyr-Starry IVC 测例使用：

```bash
# 在 tgosimages 仓库根目录执行
./build.sh platform orangepi-5-plus ivc
```

也可以直接调用薄封装脚本：

```bash
./scripts/apps/ivc-rk3588.sh
```

若希望构建 Orange Pi 5 Plus 平台相关的全部镜像和 IVC payload，可以省略子命令：

```bash
./build.sh platform orangepi-5-plus
```

默认行为：

- `ivc-sdk` 默认使用 `${BUILD_DIR}/ivc-sdk-source`；不存在时 clone
  `https://github.com/rcore-os/ivc-sdk.git`。
- StarryOS 使用远端 `https://github.com/rcore-os/tgoskits.git` 的 `dev` 分支，不使用同级本地
  `tgoskits`。
- ArceOS、StarryOS、Zephyr、RT-Thread、FreeRTOS、AKA 和 IVC SDK 自动下载到构建目录的源码是可重建缓存；重跑时直接清除残留改动及未跟踪文件、检出目标版本并重新应用项目补丁，不做备份。通过路径参数或环境变量指定的已有源码按原样使用（FreeRTOS 仅使用内部源码缓存）。
- 平台 StarryOS 日志由构建配置或 `--log` 决定；独立 `ivc-rk3588.sh` 构建内核时默认 `Error`。
- IVC Linux 模块直接复用 Linux 任务已经准备好的内核配置和版本文件，不再次执行 `olddefconfig`/`modules_prepare` 或 `make kernelrelease`。
- Linux任务从同一次内核构建执行modules_install，在IMAGES/orangepi/linux发布kernel.release及lib/modules/<release>和模块索引；客户机rootfs将其写入/usr/lib/modules，Jammy的/lib别名指向同一目录。缺少对应版本或索引时构建明确失败；Linux资产变化也会使客户机基础rootfs缓存失效，避免仅替换内核后丢失RTL8125等模块驱动。
- IVC initramfs 在同一个 `fakeroot` 会话中解包、添加程序和打包，保留 BusyBox 的设备节点与文件属主，普通用户无需 sudo。
- Zephyr 使用统一的 `apps/zephyr/orangepi-shell`，普通通信、基础检查和中断测量共用同一镜像。
- 平台 Zephyr 默认从 `${BUILD_DIR}/aka-rk3588` 的 `dual` 分支构建 AKA 控制端，可用 `--aka-dir` 或库参数覆盖；`ORANGEPI_WITH_AKA=0` 关闭默认接入。
- Starry 用户态程序由 `ivc-sdk` 的 Makefile 构建。

常用覆盖参数：

```bash
./build.sh platform orangepi-5-plus ivc \
  --ivc-sdk-dir <ivc-sdk-checkout> \
  --ivc-build-dir <object-directory>
```

整套平台构建中，`starry` 和 `zephyr` 分别构建客户机内核；`ivc` 只构建用户态程序、
Linux 驱动和 initramfs，不重复构建内核。`rootfs` 等待 IVC 工具就绪后，把三个程序加入
正式独立 ext4 的 `/usr/bin`。最终烧写镜像直接嵌入这份客户机文件系统。
SDK、对象目录和 AKA 参数只转发给支持它们的组件。rootfs 缓存包含 IVC 和默认 AKA
运行包的内容，更新程序、模型或校准参数后不会复用旧叠加内容。

发布目录会生成以下板端 payload：

```text
IMAGES/orangepi/starry/orangepi-5-plus
IMAGES/orangepi/zephyr/orangepi-5-plus
IMAGES/orangepi/zephyr/orangepi-5-plus.dtb
IMAGES/orangepi/linux/initramfs.cpio
IMAGES/orangepi/ivc/usr/bin/ivc-roundtrip
IMAGES/orangepi/ivc/usr/bin/ivc-demo
IMAGES/orangepi/ivc/usr/bin/ivc-starry-bench
IMAGES/orangepi/ivc/usr/lib/libaxivc.so
IMAGES/orangepi/linux/usr/bin/axivc-pingpong
```

IVC demo、benchmark 和可选 AKA 控制端共用统一的 Zephyr `orangepi-5-plus` 镜像。
Zephyr 的 ELF 与 DTB 沿用统一构建入口的正式产物目录。

构建完成后可以生成发布包：

```bash
./build.sh release pack
```

默认 release 打包入口是 `IMAGES/`，因此 `release/orangepi.tar.xz` 会包含整个
`IMAGES/orangepi`，也就包含上面的客户机镜像和 `ivc/usr` 文件。部署由项目 CI 或板卡
管理环境负责；服务器地址、认证信息和临时解包目录不写入仓库文档。

正式独立 ext4 包含 `ivc-demo`、`ivc-starry-bench` 和 `ivc-roundtrip`，最终宿主机镜像
还会将这三个程序安装到宿主机的 `/usr/bin/`。嵌套客户机副本使用同一份独立 ext4，
磁盘组合层不再维护另一套 IVC 注入逻辑。
Linux 客户机使用独立的 `linux/orangepi-5-plus` 和 `linux/initramfs.cpio`，其中 initramfs
包含 `axvisor.ko` 及 Linux 侧 IVC 程序。Zephyr 只使用统一的
`guest/zephyr/orangepi-5-plus` 与对应 DTB，AKA 控制逻辑应集成到该 shell 中。
`axvisor.ko` 是 Linux 客户机的 IVC 驱动模块，必须随 initramfs 一起发布；它不需要复制到
StarryOS rootfs、Zephyr shell 或 Orange Pi 宿主机的 `/usr/bin/`。

AKA 仓库本身不需要修改；构建时可传入其现有库和头文件目录：

```bash
./build.sh platform orangepi-5-plus zephyr \
  --aka-library <aka-rk3588-library> \
  --aka-include-dir <aka-rk3588-include-dir>
```

统一 shell 提供 `aka run` 命令，并通过可选的 `aka_rk3588_run()` C ABI 调用外部库。未提供库时，shell 仍可构建并保留
现有 IVC 功能。

### 3.7 三客户机基础功能检查

基础功能检查已整合到 `apps/zephyr/orangepi-shell`，使用统一入口：

```bash
./scripts/apps/ivc-rk3588.sh --shell-only --ivc-sdk-dir /path/to/ivc-sdk
# 需要 AKA 控制端时追加 --aka-dir /path/to/aka-rk3588
```

镜像输出为 `IMAGES/orangepi/zephyr/orangepi-5-plus`、`.elf` 和 `.dtb`。普通 IVC 和 AKA
构建均可执行 `kernel version`、`kernel thread list`、`device list`；提示符为 `zephyr:~$ `。
线程监控、线程名称和栈信息在统一配置中启用，客户机沿用 128 MiB 内存 overlay。
串口和 GIC 配置由现有统一 shell 与 AKA overlay 管理，不复制旧基础应用的 UART 配置。


---

## 4. 构建产物和验证

### 4.1 默认产物

```text
IMAGES/orangepi/zephyr/orangepi-5-plus
IMAGES/orangepi/zephyr/orangepi-5-plus.elf
IMAGES/orangepi/zephyr/orangepi-5-plus.dtb
```

| 文件 | 作用 |
| --- | --- |
| `orangepi-5-plus` | Zephyr 客户机 BIN，供 AxVisor 加载 |
| `orangepi-5-plus.elf` | 带符号 ELF，用于反汇编和调试 |
| `orangepi-5-plus.dtb` | Zephyr 构建生成的客户机设备树 |

若修改 `--image-name`，还要同步确认 TGOSKits 打包流程使用相同文件名，否则板端可能继续
加载旧镜像。

### 4.2 确认正式控制应用已链接

```bash
strings IMAGES/orangepi/zephyr/orangepi-5-plus.elf \
  | rg ZEPHYR_ROBOT_CONTROL_START
```

应找到：

```text
ZEPHYR_ROBOT_CONTROL_START protocol=2 source=axvisor-ivc uart=uart6
```

这只证明正式 application 被链接进 ELF，不证明 IVC、UART6 或机械设备已经在板端工作。

### 4.3 记录哈希

```bash
sha256sum \
  IMAGES/orangepi/zephyr/orangepi-5-plus \
  IMAGES/orangepi/zephyr/orangepi-5-plus.elf \
  IMAGES/orangepi/zephyr/orangepi-5-plus.dtb
```

部署时应将这里的 BIN/DTB 哈希与 TGOSKits 实际打包文件、最终 FIT 和板端加载文件逐级
对照。

### 4.4 Host 控制测试

测试源码位于 AKA，Zephyr 测试环境由 TGOSImages 提供：

```bash
# 在 tgosimages 仓库根目录执行，并显式提供外部仓库和 Python 环境
AKA_RK3588_DIR=<aka-rk3588-checkout>
ZEPHYR_PYTHON=<zephyr-python>
ZEPHYR_BASE="$PWD/build/zephyr" \
ZEPHYR_TOOLCHAIN_VARIANT=host \
"${ZEPHYR_PYTHON}" build/zephyr/scripts/twister \
  -T "${AKA_RK3588_DIR}/zephyr/orangepi_robot_control/tests" \
  -p native_sim/native/64
```

当前 4 项测试覆盖：

- 感知结果立即驱动底盘，不等待机械臂 50 ms 周期；
- 机械臂插值只在独立 tick 中推进；
- 输入看门狗可重置且单次触发；
- 超时停车后新输入恢复控制。

拆分后已有 4/4 通过记录。这些 host 测试不覆盖真实 IVC HVC、UART6、舵机供电和机械
动作。

---

## 5. 与部署和运行的关系

TGOSImages 构建结束后不会自动：

- 修改 TGOSKits 配置；
- 复制镜像到 TGOSKits 临时目录；
- 重建 AxVisor FIT；
- 上传或重启 Orange Pi；
- 启动 StarryOS 感知程序。

完整链路：

```text
AKA 机器人源码
    ↓
TGOSImages 构建 Zephyr BIN/ELF/DTB
    ↓
TGOSKits/AxVisor 组装双客户机镜像并部署
    ↓
Zephyr 启动后自动运行控制 application
    ↓
StarryOS 运行 AKA 的 run_dual_pick.sh
    ↓
Starry 感知结果经 IVC 驱动 Zephyr 控制
```

Zephyr 控制 application 静态链接进客户机镜像，不是在 Zephyr Shell 中从文件系统启动的
独立 ELF。客户机启动后 `main()` 自动执行；Shell 只用于观察和诊断。

感知、公共协议、控制状态机、UART6、看门狗和日志说明位于 AKA：

```text
AKA_RK3588_MODIFICATIONS.md
zephyr/orangepi_robot_control/README.md
```

---

## 6. 当前验证边界

拆分后已验证：

- 从 AKA 入口构建 Zephyr Orange Pi 镜像成功；
- 从 TGOSImages 入口构建同一应用成功；
- 两个入口的 BIN、ELF 和 DTB 哈希一致；
- ELF 包含正式控制入口，不含临时死锁复现入口；
- Zephyr host 控制测试 4/4 通过；
- shell 语法和 `git diff --check` 通过。

这些结果不能证明：

- 新产物已经被 TGOSKits 打包；
- 板端启动的一定是该哈希镜像；
- UART6 时钟、pinmux 和直通正确；
- Starry→Zephyr IVC 可以在当前板端长期稳定运行；
- 车轮方向、机械臂动作或真实捡球正确；
- 24 小时稳定性和严格实时性达标。

构建、板端启动、设备、架空动作、落地捡球和长期压力测试应分别验收。

---

## 7. 常见问题

### 7.1 找不到控制应用

```text
ERROR: Zephyr robot application not found
```

确认 `--aka-dir` 指向 AKA 根目录，并存在：

```text
zephyr/orangepi_robot_control/CMakeLists.txt
```

### 7.2 找不到 TGOSImages 专用入口

从 AKA 侧执行时如果提示：

```text
TGOSImages entry script is missing or not executable
```

说明选中的 TGOSImages 工作树尚未包含本脚本，或脚本没有执行权限。应检查仓库版本和文件
权限，不要通过删除构建缓存绕过。

### 7.3 AKA 版本不是预期

脚本不会更新已有仓库。检查输出中的 `AKA_RK3588_COMMIT` 和 `AKA_RK3588_WORKTREE`，然后
由使用者在 AKA 中显式 fetch/rebase/checkout。

### 7.4 首次构建下载失败

首次构建可能需要下载 Zephyr、Python requirements 和 SDK。网络失败与源码编译失败应
分别处理；已有完整 `build/` 缓存时会直接复用。

### 7.5 构建成功但板端仍是旧镜像

依次核对：

1. `IMAGES/` 产物哈希；
2. TGOSKits 实际使用的 BIN/DTB 哈希；
3. 最终 FIT 内容；
4. 本次板端上传命令；
5. 板端启动日志的新入口字符串。

不能只凭 TGOSImages 显示 `build succeeded` 推断板端已经更新。

---

## 8. 建议提交范围

TGOSImages 建议形成一个独立构建能力提交：

```text
.gitignore
README_CN.md
scripts/os/zephyr.sh
scripts/apps/README.md
scripts/apps/aka-rk3588-zephyr.sh
```

不应提交：

```text
build/
IMAGES/
twister-out*/
机器人控制业务源码
AKA 感知源码
TGOSKits 虚拟机配置
历史 QEMU 四架构 Starry 镜像改动
```

机器人业务应在 AKA 单独提交；AxVisor 双客户机配置和设备直通应在 TGOSKits 单独提交。
三个仓库可以记录兼容 commit，但不应混合代码所有权。


## 9. 从统一 shell 启动 AKA

`ivc-rk3588.sh --shell-only --aka-dir <aka-dual-checkout>` 会把外部 AKA 的 Zephyr
控制代码接入 `apps/zephyr/orangepi-shell`，通过 `aka run` 在后台启动，`aka status`
查询状态。`--aka-library` 仍支持提供 C ABI 的预编译实现；源码与库选项互斥。
已有 AKA checkout 不会被切换或修改。构建、UART6 overlay、板端目录与 StarryOS
联调步骤见 [统一 shell 文档](../../apps/zephyr/orangepi-shell/README.md)。

AKA 运行包自动准备入口为 `orangepi-aka-package.sh`，底层感知编译使用 `orangepi-aka-perception.sh`；`orangepi-aka-rootfs.sh` 向现有客户机 ext4 安装运行包并检查 JPEG 等间接依赖。正式 rootfs 仍为 `IMAGES/rootfs/rootfs-aarch64-orangepi-jammy.img`，Zephyr 仍输出到 `IMAGES/orangepi/zephyr`，板端 `/guest/ivc-test` 仅用于临时验证。详见统一 Zephyr shell README。


Orange Pi 普通 IVC 板卡验证统一使用 TGOSKits 的
`apps/axvisor/normal/board-orangepi-5-plus/ivc`：一次启动 Linux、StarryOS、Zephyr shell，分别校验三条链路的五条请求与回复。Linux 两条链路逐轮往返，Zephyr–StarryOS 沿用原 demo 的批量发送顺序。
`ivc-roundtrip` 在本仓库编译并加入 Linux initramfs 和 StarryOS 既有客户机 ext4。
它的公开入口为 `publish KEY REQUEST_PREFIX REPLY_PREFIX` 或
`subscribe VM KEY REQUEST_PREFIX REPLY_PREFIX`；key、对端和消息前缀由测例明确指定，失败返回非零。
正式板卡配置和启动命令见 TGOSKits 该目录的 README。

### AKA 客户机文件系统与构建验证

香橙派构建图在 rootfs 前自动生成 `IMAGES/orangepi/aka` 运行包，可用 `ORANGEPI_AKA_PACKAGE` 指定已有包；显式提供的包内校准参数按原样复制。`orangepi-aka-rootfs.sh` 用于已有独立 ext4 的验证副本，
只在临时镜像完成注入、架构、动态加载器和递归库校验后发布新输出；失败不留下正式镜像。
校验同时覆盖 AKA 明确使用的动态运行库，不仅检查 `DT_NEEDED`。

Starry 发布按本次 config/target/debug 选择产物，不从旧目标目录猜测文件。Cargo 解析
出的锁文件保留，manifest 的 `source_lock_sha256` 记录实际依赖锁；构建产生的工作区
变化仍由 `source_dirty` 标记。

定向验证入口：

```sh
bash scripts/tests/platform/orangepi-rootfs-flow.sh
python3 scripts/tests/rootfs/rootfs-graph.py
bash scripts/tests/build/starry-source-preparation.sh
bash scripts/tests/platform/starry-release-smoke.sh
AARCH64_CC=/path/to/aarch64-linux-musl-gcc bash scripts/tests/apps/orangepi-aka-rootfs.sh
```


### Orange Pi 默认 AKA

`./build.sh platform orangepi-5-plus all` 默认将 AKA 感知运行包安装到客户机 ext4 的 `/opt/aka`，并在统一 Zephyr shell 中构建 AKA 控制端；启动后用 `aka run` 主动运行控制逻辑。

默认 AKA 源码位于 `${BUILD_DIR}/aka-rk3588`，不存在时从 `https://github.com/bullhh/aka-rk3588.git` 下载并检出 `dual` 分支。平台构建图使用 `build/workspaces/orangepi-5-plus/aka-rk3588`。`all` 在 IVC 构建完成后自动生成 `IMAGES/orangepi/aka`，再构建 rootfs；新环境无需手动复制运行包。

感知程序从 AKA 和 IVC SDK 源码交叉编译，RKNN 模型和运行库来自 AKA 仓库。libuvc、libusb、JPEG 和 libudev 等依赖从 Ubuntu 官方 arm64 仓库下载，版本、地址和 SHA256 固定在 `scripts/apps/aka-runtime.lock.json`，下载包保存在构建缓存中。生成的 `package-manifest.json` 记录源码 commit、工作区状态、编译器、依赖来源、配置路径和每个文件的 SHA256。

默认使用 AKA 源码中的 `config/lekiwi_calibration.json` 和 `config/lekiwi_pick_config.txt`，它们是仓库提供的配置；部署到具体机器人前应通过 `ORANGEPI_AKA_CONFIG_DIR` 指定该机器已校准的配置目录。也可通过 `ORANGEPI_AKA_PACKAGE` 指定已有完整运行包，此时只校验和安装，不重新生成。单独生成默认运行包：

```sh
./build.sh platform orangepi-5-plus aka
```

可通过 `ORANGEPI_AKA_SOURCE_DIR`（或 `--aka-dir`）覆盖控制源码，通过 `ORANGEPI_AKA_PACKAGE` 覆盖感知运行包。关闭默认 AKA：

```sh
ORANGEPI_WITH_AKA=0 ./build.sh platform orangepi-5-plus all
```

此开关影响本次构建；此前已有镜像需重新构建 rootfs 才会移除 `/opt/aka`。
