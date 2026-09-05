# Quectel Linux 驱动自动安装

插入 Quectel 模组后，自动识别、自动安装/加载 Linux USB 驱动，省去手工编译驱动，
用户可直接开始拨号上网（`quectel-CM -s <APN>` 或 `pppd`）。

**统一收敛目标**：脚本不论走哪条路径，都以「**设备已就绪 ✅**」或「**设备未就绪 ⚠️ + 原因**」
收尾——环境已 OK 就直接报告就绪；环境不 OK 就继续往下装（下载预编译包或源码编译 → 加载 → 再校验），
直到就绪或给出明确阻塞原因。

**轻量化设计**：驱动源码（Quectel 官方《Linux USB Serial Option Driver V1.1》，覆盖
v2.6.12 ~ v6.17.1 共 179 个内核版本）**不上传到本仓库**，而是打包成
`quectel-src-vX.Y.Z.tar.gz` 放到 GitHub Release；脚本按当前 `uname -r` **按需下载
对应版本源码**再编译，绝不拿不匹配的源码去编译。

> 📊 全流程（用户操作 vs 脚本自动）见 [操作指导示意图](操作指导示意图.md)。

## 一键安装

```bash
# 0. 源码编译路径需要内核头文件：
sudo apt install linux-headers-$(uname -r)     # Debian/Ubuntu
#   或: sudo dnf install kernel-devel kernel-headers   # RHEL/CentOS

# 1. 首次安装（配置检查 → 按需下载源码 → 编译安装 → 加载 → udev → DKMS）
sudo ./quectel_auto_install.sh --first-time --prebuilt-repo <owner>/<repo>
```

`--prebuilt-repo`（`--source-repo` 同义）指向你存放源码/预编译包的 GitHub 仓库。
首次安装后：每次插入模组，udev 自动触发 `--quick-load`（仅 modprobe，2~3 秒），无需任何手工操作。

## 发布源码到 GitHub（一次性，让脚本能按需下载）

```bash
# 在有完整 sources/ 的机器上，把每个内核版本打包成 quectel-src-vX.Y.Z.tar.gz：
./make_source_assets.sh                          # 产物在 release-assets/
# 或直接打包并上传（需 gh CLI）：
./make_source_assets.sh <owner>/<repo> quectel-usb-2.0
```

上传后即可**删除本地 `sources/` 目录和 zip 原包**，仓库保持轻量。脚本运行时会：

1. 从 `sources-manifest.txt` 解析出与内核匹配的版本（如 4.15 内核 → `v4.15.1`）；
2. 下载 `quectel-src-v4.15.1.tar.gz` 到 `/var/cache/quectel-usb/sources/`；
3. 解包 → 编译 → 安装 → 加载 → 收敛到「设备已就绪」。

## 预编译 .ko 快速通道（可选，免编译器）

对固定内核版本（同一套 BSP 镜像跑在成百上千台设备上），可再发布预编译 `.ko`，
让目标机**连编译都省掉**：

```bash
# 在目标内核机上打包（会自动按需下载源码再编译）：
sudo ./make_release_asset.sh            # 生成 quectel-usb-<uname -r>-<arch>.tar.gz
# 上传到同一 GitHub Release（tag: quectel-usb-2.0）
```

脚本优先尝试 `quectel-usb-<uname -r>-<arch>.tar.gz`（预编译，免 gcc/headers），
找不到才回退到源码按需下载 + 编译。

> ⚠️ 预编译 `.ko` 与「内核版本 + 架构 + 配置」强绑定，仅适用于版本/配置固定的嵌入式/BSP 内核；
> 通用发行版请走源码路径（按需下载 + 编译）。

## 其它用法

```bash
sudo ./quectel_auto_install.sh                 # auto：已就绪则报就绪，否则安装
sudo ./quectel_auto_install.sh --quick-load    # 仅加载驱动（热插拔路径）
sudo ./quectel_auto_install.sh --dry-run       # 只打印将执行的动作
sudo ./quectel_auto_install.sh --kernel /path  # 指定内核 build 目录
sudo ./quectel_auto_install.sh --source-dir /path  # 用本地源码树（离线）
sudo ./quectel_auto_install.sh --no-download   # 强制只用本地源码编译
sudo ./quectel_auto_install.sh --uninstall     # 卸载驱动 / udev / DKMS / 启动器
```

## 目录结构

```
quectel-auto-install/
├── quectel_auto_install.sh   # 主安装脚本（按内核版本自动选源码）
├── sources-manifest.txt      # 可用的源码版本清单（179 行，轻量）
├── make_source_assets.sh     # 把 sources/ 打成 quectel-src-*.tar.gz（发布用）
├── make_release_asset.sh     # 打包预编译 .ko（发布用）
├── 99-quectel.rules          # udev 热插拔规则
├── dkms.conf                 # DKMS 配置
├── Quectel_LTE&5G_Linux_USB_Driver_User_Guide_V2.0.pdf   # 依据的官方手册
└── sources/                  # 【仅发布机需要，部署仓库可删除】
    └── vX.Y.Z/               # 每个版本：Makefile + drivers/usb/serial/*.{c,h}
```

## 已落实的手册补丁（User Guide V2.0，已含在官方源码内）

| 章节 | 补丁 | 位置 |
|---|---|---|
| 3.2.1 | 增加 VID/PID（含 2c7c 厂商级通配） | `option.c` |
| 3.2.2 | Zero Packet（ZLP）机制 | `usb_wwan.c` |
| 3.2.3 | Reset-resume 机制 | `option.c`（`.reset_resume`） |
| 3.2.5 | 屏蔽 interface 4 / 网络接口 | `option.c`（`option_probe`） |
| 5.1 / 5.2 | USB Auto Suspend / Remote Wakeup（**可选，官方包未内置**） | 需手动加 |

## 接口与驱动映射（手册 Table 2）

- `ttyUSB0` = DM，`ttyUSB1` = GPS NMEA，`ttyUSB2` = AT，`ttyUSB3` = PPP/AT。
- interface 4 为 USB 网络适配器：QMI_WWAN 显示 `wwanX`，GobiNet 显示 `ethX`/`usbX`，MBIM 用 `cdc_mbim`。
- 本工程提供 **USB Serial Option**（option/usb_wwan/qcserial）；网络侧用内核自带的
  `qmi_wwan`（QMI）/ `cdc_mbim`（MBIM），由 `quectel-CM` 拨号。

## 说明

- 安装会用 Quectel 补丁版覆盖发行版自带的 `option` / `usb_wwan` / `qcserial`。
- GobiNet 是 Quectel 单独提供的源码包（未包含），且与 QMI_WWAN 二选一。
- 若模组以 USB 存储/CD-ROM 模式枚举，需先 `usb_modeswitch` 或 AT 命令切到 modem 模式。
- 本机（WSL2 6.6）缺对应 build 目录（headers），无法完成真实编译验证；请在目标内核机实跑。
