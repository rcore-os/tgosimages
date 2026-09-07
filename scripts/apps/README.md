# 外部应用构建入口

本目录存放“业务应用属于其他仓库、系统构建环境属于 TGOSImages”场景的薄封装脚本。

当前包含两个外部应用入口：

```text
scripts/apps/aka-rk3588-zephyr.sh
scripts/apps/ivc-rk3588.sh
```

`aka-rk3588-zephyr.sh` 查找 AKA 中的控制应用，然后调用 `scripts/os/zephyr.sh`，使用本仓库管理的 Zephyr
版本、补丁、交叉工具链和 Orange Pi 5 Plus board 配置生成客户机镜像。

`ivc-rk3588.sh` 查找或下载 `ivc-sdk`，构建 Zephyr IVC demo/benchmark 客户机镜像、
Starry 用户态程序和 StarryOS 客户机镜像，并把板端需要的文件收集到 Orange Pi 发布目录。

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
├── build/                                # Zephyr 源码、SDK、构建缓存
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
build/zephyr/orangepi-5-plus-orangepi_robot_control
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
3. `tgosimages` 同级的 `aka-rk3588` checkout；
4. 以上均不存在时，在 `tgosimages` 同级创建 `aka-rk3588` checkout。

`ivc-sdk` 使用同样的查找规则，默认使用 `tgosimages` 同级的 `ivc-sdk` checkout。不存在时 clone
`https://github.com/rcore-os/ivc-sdk.git` 的当前默认分支；已有 checkout 不会被自动
pull、切换、reset 或清理。

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

只对本次新 clone 指定 branch、tag 或 commit：

```bash
./scripts/apps/aka-rk3588-zephyr.sh \
  --aka-ref <ref>
```

已有 AKA 工作树不会被自动执行：

- pull；
- checkout 或切换分支；
- reset；
- clean；
- 覆盖本地修改。

若目录已经存在，`--aka-ref` 会被忽略并打印提示。需要更新时，应由使用者进入 AKA 仓库
显式处理版本和本地修改。

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

- `ivc-sdk` 优先使用 `tgosimages` 同级的同名 checkout；不存在时 clone
  `https://github.com/rcore-os/ivc-sdk.git`。
- StarryOS 使用远端 `https://github.com/rcore-os/tgoskits.git` 的 `dev` 分支，不使用同级本地
  `tgoskits`。
- StarryOS 日志级别默认为 `Error`。
- Zephyr demo application 为 `ivc-sdk/samples/zephyr-starry`。
- Zephyr benchmark application 为 `ivc-sdk/samples/zephyr-starry-benchmark`。
- Starry 用户态程序由 `ivc-sdk` 的 Makefile 构建。

常用覆盖参数：

```bash
./build.sh platform orangepi-5-plus ivc \
  --ivc-sdk-dir <ivc-sdk-checkout> \
  --tgoskits-ref dev \
  --starry-log Error
```

发布目录会生成以下板端 payload：

```text
IMAGES/orangepi/ivc/guest/starry/orangepi-5-plus
IMAGES/orangepi/ivc/guest/zephyr/zephyr-ivc-demo.bin
IMAGES/orangepi/ivc/guest/zephyr/zephyr-ivc-benchmark.bin
IMAGES/orangepi/ivc/usr/bin/ivc-demo
IMAGES/orangepi/ivc/usr/bin/ivc-starry-bench
IMAGES/orangepi/ivc/usr/lib/libaxivc.so
```

其中 `zephyr-ivc-*` 是板端使用的 Zephyr IVC 镜像文件名。Zephyr 的 ELF/DTB 等调试产物
保留在 `build/ivc-rk3588/zephyr`，不会进入发布 payload。

构建完成后可以生成发布包：

```bash
./build.sh release pack
```

默认 release 打包入口是 `IMAGES/`，因此 `release/orangepi.tar.xz` 会包含整个
`IMAGES/orangepi`，也就包含上面的 `ivc/guest` 和 `ivc/usr` 文件。部署由项目 CI 或板卡
管理环境负责；服务器地址、认证信息和临时解包目录不写入仓库文档。

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
