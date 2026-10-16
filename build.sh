#!/usr/bin/env bash
# Reproduce the M8 296-package rootfs using the released native ImageBuilder,
# optionally assemble a complete KING3288 SD image without kernel compilation.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
ARCHIVE="istoreos-imagebuilder-rockchip-armv7.Linux-x86_64.tar.zst"
NAME="istoreos-imagebuilder-rockchip-armv7.Linux-x86_64"
MODE="${1:-sd}"
if [[ "$MODE" != sd && "$MODE" != --rootfs-only ]]; then
  echo "Usage: $0 [sd|--rootfs-only]" >&2
  exit 2
fi
if [[ ! -d "$NAME" ]]; then
  test -s "$ARCHIVE" || {
    echo "Missing $ARCHIVE. Download it from GitHub Releases into this directory." >&2
    exit 1
  }
  sha256sum -c SHA256SUMS
  tar --use-compress-program=zstd -xf "$ARCHIVE"
fi
test -s "$NAME/Makefile"
PKG_LIST="$HERE/board/king3288-configs/m8-txpbl1-imagebuilder-packages.txt"
test "$(wc -l < "$PKG_LIST")" -eq 296
PACKAGES="-dnsmasq $(tr '\n' ' ' < "$PKG_LIST")"
echo "Building rootfs from 296 pinned packages ..."
(
  cd "$NAME"
  make image PROFILE=king3288 PACKAGES="$PACKAGES"
)
OUT="$NAME/bin/targets/rockchip/armv7"
diff -u <(sort "$PKG_LIST") <(awk '{print $1}' "$OUT/istoreos-rockchip-armv7-king3288.manifest" | sort)
echo "296_PACKAGE_MANIFEST_VERIFIED"
test -s "$OUT/istoreos-rockchip-armv7-king3288-rootfs.tar.gz"
if [[ "$MODE" == --rootfs-only ]]; then
  echo "ROOTFS_ONLY_OK: $OUT/istoreos-rockchip-armv7-king3288-rootfs.tar.gz"
  exit 0
fi
echo "Preparing standalone SD image packaging tools ..."
cp -a "$HERE/board/king3288-tools" "$NAME/"
cp -a "$HERE/board/king3288-blobs" "$NAME/"
cp -a "$HERE/board/king3288-configs" "$NAME/"
mkdir -p "$NAME/target/linux/rockchip/armv7/base-files/etc/uci-defaults"
cp "$HERE/board/target/linux/rockchip/armv7/base-files/etc/uci-defaults/10-king3288-protect-emmc" \
  "$NAME/target/linux/rockchip/armv7/base-files/etc/uci-defaults/"
(
  cd "$NAME"
  bash king3288-tools/build-king3288-sd-image-txpbl1-v3.sh
  bash king3288-tools/validate-king3288-sd-image-txpbl1-v3.sh
)
mkdir -p "$HERE/output"
cp -f "$OUT/istoreos-rockchip-armv7-king3288-sdcard-3g-txpbl1-v3.img.gz" "$HERE/output/"
cp -f "$OUT/istoreos-rockchip-armv7-king3288-sdcard-3g-txpbl1-v3.img.gz.sha256" "$HERE/output/"
echo "SD_V3_IMAGEBUILDER_OK"
echo "Output: $HERE/output/"
