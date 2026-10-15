#!/bin/sh
# ============================================================================
# 一键构建脚本（本仓库 = 某型号 × 某版本系列的 ImmortalWrt ubootmod 构建 overlay）
#
# 用法:
#   ./scripts/build.sh <ImmortalWrt 版本> [CPU 核数]
#   例:  ./scripts/build.sh 25.12.2 4
#
# 要求:
#   - Linux x86_64, 建议 2 核以上 / 16GB 内存 / 40GB 可用磁盘
#   - git, gcc/g++, bison, flex, libssl-dev, libffi-dev, python3 等 OpenWrt 常规依赖
#   - 完整依赖清单见官方文档:
#     https://openwrt.org/docs/guide-developer/install-building-software
#
# 产物:
#   ~/iwrt-build/iwrt-<版本>/bin/targets/mediatek/filogic/
#     immortalwrt-<版本>-mediatek-filogic-<设备>-ubootmod-initramfs-kernel.bin
#     immortalwrt-<版本>-mediatek-filogic-<设备>-ubootmod-squashfs-factory.bin
#     immortalwrt-<版本>-mediatek-filogic-<设备>-ubootmod-squashfs-sysupgrade.bin
# ============================================================================
set -e

VERSION="${1:?用法: ./scripts/build.sh <版本> [CPU核数]，例如 ./scripts/build.sh 25.12.2}"
CPUS="${2:-$(nproc 2>/dev/null || echo 2)}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# 如果直连外网不畅，取消下面三行注释并改成你的代理
# export http_proxy=http://192.168.111.1:9001
# export https_proxy=http://192.168.111.1:9001
# export no_proxy=127.0.0.1,localhost

if [ ! -f "$ROOT/config/$VERSION.config" ]; then
  echo "错误: 本仓库缺少 config/$VERSION.config" >&2
  echo "本仓库每个小版本对应一份经验证的配置文件，请先确认该版本是否已收录。" >&2
  exit 1
fi

WORK="${WORK:-$HOME/iwrt-build}"
mkdir -p "$WORK"
SRC="$WORK/iwrt-$VERSION"

# 1) 拉取官方源码（官方 tag，clone 一次后重复构建直接复用）
if [ ! -d "$SRC" ]; then
  echo "==> 克隆官方 ImmortalWrt v$VERSION 源码 ..."
  git clone --depth 1 --branch "v$VERSION" https://github.com/immortalwrt/immortalwrt.git "$SRC"
fi
cd "$SRC"

# 2) feeds（固定为官方 tag 声明的 commit）
echo "==> 更新/安装 feeds ..."
./scripts/feeds update -a
./scripts/feeds install -a

# 3) 套用本仓库 overlay：ubootmod DTS + 设备定义（幂等，重复构建安全）
cp -f "$ROOT"/files/mt7981b-*-ubootmod.dts target/linux/mediatek/dts/
if ! grep -q "end ubootmod overlay (auto-appended by scripts/build.sh)" \
     target/linux/mediatek/image/filogic.mk; then
  cat "$ROOT"/patches/*-ubootmod-device.mk >> target/linux/mediatek/image/filogic.mk
fi

# 4) 使用本版本经验证的构建配置
cp -f "$ROOT/config/$VERSION.config" .config
make defconfig

# 5) 构建
echo "==> make -j$CPUS world （2 核约 8~10 小时）"
make -j"$CPUS" world

echo
echo "===== 构建完成 ====="
echo "产物目录: $SRC/bin/targets/mediatek/filogic/"
echo
(cd "$SRC/bin/targets/mediatek/filogic" && sha256sum *ubootmod*)
