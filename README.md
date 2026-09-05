# Quectel 驱动自动安装

插上 Quectel 模组，**一条命令**自动装好驱动，直接就能拨号上网。
不用手动编译、不用找驱动包、不用懂内核。

---

## 使用方法（就三步）

```bash
# ① 下载工程
git clone https://github.com/louishuangQ/Quectel_Linux_USB-driver_installer.git
cd Quectel_Linux_USB-driver_installer

# ② 插入模组，然后运行
sudo ./quectel_auto_install.sh

# ③ 如果提示「缺少内核头文件」，装一下再重跑（装过一次以后就不用管了）
sudo apt install linux-headers-$(uname -r) build-essential
sudo ./quectel_auto_install.sh
```

**看到这行就是成功了：**

```
[OK]  设备已就绪 ✅
```

---

## 成功之后

**重插/换插模组**：什么都不用做，系统会自动加载驱动（几秒钟）。

**拨号上网**（`<APN>` 换成运营商的接入点，例如移动 `cmnet`、联通 `3gnet`、电信 `ctnet`）：

```bash
sudo quectel-CM -s <APN> &     # QMI/MBIM 方式
# 或者
pppd call quectel-ppp          # PPP 方式
```

---

## 出了问题看这里

| 现象 | 解决 |
|---|---|
| `缺少内核头文件` | `sudo apt install linux-headers-$(uname -r) build-essential` 后重跑 |
| `下载失败 / 未找到源码包` | 检查能否联网，再重跑一次 |
| `设备未就绪` 且没有 `/dev/ttyUSB*` | 模组可能处于「U 盘/CD-ROM」模式，用 `usb_modeswitch` 或 AT 命令切到 modem 模式 |
| 有 ttyUSB 但没有网卡（wwanX/usbX） | 发 `AT+QCFG="usbnet"` 查/改网络模式，或直接用 PPP 拨号 |
| 内核升级后驱动失效 | `sudo apt install dkms`，再跑一次脚本（会自动注册自动重编译） |

---

## 它是怎么工作的（一句话）

脚本自动判断：内核已有驱动 → 直接「设备已就绪」；没有 → 按你的内核版本从 GitHub 下载对应源码 → 编译安装 → 加载 → 「设备已就绪」。全程零参数、零配置。

> 支持的内核版本：v2.6.12 ~ v6.17.1（179 个）。详细流程图见 [操作指导示意图](操作指导示意图.md)。

---

## 给维护者（普通用户不用看）

- 更新驱动源码 / 新增内核版本：把源码放进 `sources/`，跑 `./make_source_assets.sh <owner>/<repo>` 重新打包上传。
- 发布免编译的预编译包：在目标内核机上跑 `sudo ./make_release_asset.sh`，把产物上传到同一 Release。
