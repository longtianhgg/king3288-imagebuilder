# KING3288 iStoreOS ImageBuilder

为 **KING3288 / Rockchip RK3288 ARMv7** 制作的 iStoreOS Standalone ImageBuilder。与 [OrangePi Zero3 ImageBuilder](https://github.com/longtianhgg/orangepi-zero3-imagebuilder) 一样，仓库只保存脚本、固定包清单和文档，预编译的 ImageBuilder 在 **Releases** 下载。

> 非官方项目；默认配置面向 KING3288 单网口 SD 启动。请勿直接写入 eMMC。

## 当前版本

| 内容 | 值 |
|---|---|
| 系统 | iStoreOS 24.10.8 |
| Linux | 6.6.144 |
| SoC | RK3288 / 4× Cortex-A17 / ARMv7 |
| Target | `rockchip/armv7` |
| Profile | `king3288` |
| 用户空间 | ARMv7 little-endian / musl / OPKG |
| 软件包 | 核心包选择清单 + 自动解析依赖；296 包为历史参考 |
| ImageBuilder | Standalone x86_64 Linux（约 176MiB） |
| GMAC | RGMII, TX PBL=1, TX/RX checksum=on |
| 下载包 | `istoreos-imagebuilder-rockchip-armv7.Linux-x86_64.tar.zst` |
| SHA256 | `70470f3fa09fc910471dfef5e86cef0e409ef0f2a95e0b95174082c6eb7bef32` |

## 已包含的软件

LuCI / iStore / QuickStart / Argon、OpenClash + Mihomo 1.19.31、Tailscale、Docker、Docker Compose、Dockerman、ttyd、eMMC 自动禁挂载及 SD ext4 安全扩容脚本等；**并非所有应用都已做实机功能测试**。

原生 ImageBuilder 默认 profile 的软件包少于历史 M8 rootfs。当前 `packages.conf` 只列主动选择的功能包；依赖由 ImageBuilder 自动解析，最终安装清单见每次 Release 的 `king3288.manifest`。原始 296 包列表保留在 `board/king3288-configs/` 作历史参考。脚本排除默认 `dnsmasq`，保留 `dnsmasq-full`。

## GitHub Actions 自定义固件构建

打开 [Actions → Build customizable KING3288 SD firmware](https://github.com/longtianhgg/king3288-imagebuilder/actions/workflows/build-firmware.yml)，点击 **Run workflow**：

- **rootfs_gib**：SD 第二分区 ext4 容量，1–6 GiB，默认 2 GiB（不包括 1GiB FAT 启动分区）。
- **docker**：默认启用；关闭时不集成 Docker、dockerd、containerd、Compose 和 Dockerman UI。
- **packages.conf**：仓库根目录的软件包选择清单。每行一个包名；把 `foo` 改成 `#foo` 表示禁止集成 `foo`；原样保留表示集成。注释说明文字以 `# `（井号后空格）开头。

构建先下载**最近一个含 ImageBuilder 归档的正式 Release**；这是为了防止随后生成的固件 Release 抢占“latest”入口。下载并校验 ImageBuilder SHA256 后，执行 `make image PROFILE=king3288`，再使用已经验证的 KING3288 原始 IDB + FAT32/extlinux + ext4 封装流程。内核、DTB、TXPBL、eMMC 禁止自动挂载的脚本不修改。

完成后发布 `firmware-<run-id>` Release，提供 `.img.gz`、SHA256SUMS、软件包 manifest。构建中会检查软件包是否按清单实际存在/缺失；若注释掉仍被依赖自动引入，构建报错而非悄悄忽略。手动输入容量只改变**新 SD 镜像**的 p2 容量；不触碰本机 SD 或 eMMC。

**注意：** 用户自定义固件需要新 SD 卡进行首次冷启动实机验证；离线镜像完整性校验不代表已实机验证。GitHub 公共 runner 磁盘有限，当前最大 6GiB 根分区。

本地示例：

```bash
# 将最新 ImageBuilder 归档及对应 SHA256SUMS 放在仓库根目录
ROOTFS_GIB=4 WITH_DOCKER=false ./build.sh
```

---

## 下载和安装

从 [Releases](https://github.com/longtianhgg/king3288-imagebuilder/releases) 下载 ImageBuilder 归档，放在本仓库克隆目录：

~~~bash
git clone https://github.com/longtianhgg/king3288-imagebuilder.git
cd king3288-imagebuilder
# 从 Releases 下载 istoreos-imagebuilder-rockchip-armv7.Linux-x86_64.tar.zst 到此目录
sha256sum -c SHA256SUMS
~~~

宿主机为 **Ubuntu 24.04 x86_64**，安装：

~~~bash
sudo apt update
sudo apt install -y make tar zstd git fakeroot fdisk dosfstools mtools \
  e2fsprogs pigz device-tree-compiler
~~~

## 方法一：直接制作完整 SD v3 镜像（推荐）

~~~bash
chmod +x build.sh
./build.sh
~~~

依次完成：

1. 解压 Standalone ImageBuilder，不编译内核。
2. 以精简的 `packages.conf` 执行 `make image PROFILE=king3288 PACKAGES=...`。
3. 验证主动选择的软件包存在，以及显式禁用的软件包没有被依赖重新引入。
4. 利用 ImageBuilder 内置的 zImage/DTB、仓库的已验证 IDB，制作 MBR + extlinux + FAT32 p1 + ext4 p2 完整 SD 镜像。
5. 校验分区布局、IDB、读回 zImage/DTB、整段 ext4 和扩容/eMMC 保护脚本。

输出：

`output/istoreos-rockchip-armv7-king3288-sdcard-3g-txpbl1-v3.img.gz`

输出约 3GiB raw / 约 173MiB gzip；**不同时间或宿主机生成的压缩包 SHA256 不要求等于本地 M8 首次发行的校验值**。

若只需要 rootfs：

~~~bash
./build.sh --rootfs-only
~~~

输出位于 ImageBuilder 解包后的 `bin/targets/rockchip/armv7/`。

原生 `make image` 本身只创建 rootfs；KING3288 的完整 SD 镜像依赖本仓库的外部封装脚本。这一点不同于 OrangePi Zero3 的内置三分区镜像 profile。

## SD 启动与安全边界

`原厂 U-Boot 2017.09 → SD p1 FAT32/extlinux/zImage/DTB → SD p2 ext4`。不插卡保持原有 eMMC Ubuntu 启动。p1=1GiB，p2=2GiB（可通过带防误操作保护的脚本扩容），MBR ID=`0x4b328826`，root PARTUUID=`4b328826-02`。

SD IDB 二进制位于 `board/king3288-blobs/king3288-idb-miniloader.bin`，仅 105472 字节，是先前启动成功的旧 SD 候选 IDB；**并非任意 RK3288 开发板通用的正式启动固件**。

**禁止把完整 SD raw image 直接 dd 到生产 eMMC。** M8 v3 已离线全盘检查，尚未进行新卡冷启动实机验收。

## 来源与验证

- iStoreOS 源码：[arm-istoreos 的 king3288 分支](https://github.com/longtianhgg/arm-istoreos/tree/king3288)
- 原生 ImageBuilder 产生于 M8 已构建提交：`420f023d1aea39bc5fd07115610e04f4603e9f9b`
- 原生构建及 ImageBuilder 重建的 296 包 manifest 完全一致（2026-10-16，Ubuntu 24.04 x86_64）。
- ImageBuilder SHA256：`70470f3fa09fc910471dfef5e86cef0e409ef0f2a95e0b95174082c6eb7bef32`。
- 源码分支后续增加发布脚本、IDB 可移植性和 GitHub Actions 文件，不改变上述编译产生的 M8 kernel 或 package 集合。

## 许可

原始 iStoreOS/OpenWrt、内核、OpenClash、Mihomo、Docker 等组件遵守各自的原始许可证。此仓库的脚本不能重新许可第三方二进制；详见 [NOTICE.md](NOTICE.md)。

## 独立构建验证结果（2026-10-16）

在 Ubuntu 24.04 x86_64 的新仓库目录解压上述已发行的 Standalone ImageBuilder，执行本仓库的 `./build.sh`（无源码内核编译），从 296 包重建 rootfs，再封装完整 SD v3，全部成功，返回码 0。完整镜像离线校验标志：`M8_V3_FULL_DISK_OFFLINE_VALIDATION_OK`。

这次独立运行生成的 SD 镜像 SHA256：

`eb0576eaa4cb45f797090509711d221555a1107d2931db55e1479bfb4388b8f3`

这是 ImageBuilder 离线打包产物；与第一次本机直接编译 SD v3 的压缩包 SHA256 不同，但两者均使用已验证板级启动布局。新卡实机冷启动仍未验收。
