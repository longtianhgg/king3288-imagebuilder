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
ROOTFS_GIB="$"+"{ROOTFS_GIB:-2}"
WITH_DOCKER="$"+"{WITH_DOCKER:-true}"
[[ "$ROOTFS_GIB" =~ ^[0-9]+$ ]] && (( ROOTFS_GIB >= 1 && ROOTFS_GIB <= 6 )) || { echo "ROOTFS_GIB must be 1..6" >&2; exit 2; }
[[ "$WITH_DOCKER" == true || "$WITH_DOCKER" == false ]] || exit 2
test -s "$HERE/packages.conf"
mkdir -p "$HERE/output"
# #name disables that package. Reject incompatible package selections.
sed -e 's/^[[:space:]]*//' -e '/^$/d' "$HERE/packages.conf" > "$HERE/output/all-package-lines.txt"
grep -v '^#' "$HERE/output/all-package-lines.txt" | awk '{print $1}' | LC_ALL=C sort -u > "$HERE/output/selected.txt"
grep '^#' "$HERE/output/all-package-lines.txt" | sed 's/^#[[:space:]]*//' | awk '/^[a-zA-Z0-9]/{print $1}' | LC_ALL=C sort -u > "$HERE/output/disabled.txt"
if [[ "$WITH_DOCKER" == false ]]; then
  for p in docker dockerd containerd docker-compose luci-app-dockerman luci-lib-docker luci-i18n-dockerman-zh-cn; do
    echo "$p" >> "$HERE/output/disabled.txt"
  done
  LC_ALL=C sort -u -o "$HERE/output/disabled.txt" "$HERE/output/disabled.txt"
  comm -23 "$HERE/output/selected.txt" "$HERE/output/disabled.txt" > "$HERE/output/selected.tmp"
  mv "$HERE/output/selected.tmp" "$HERE/output/selected.txt"
fi
# Disabled packages win; all selected packages are checked after image creation.
comm -23 "$HERE/output/selected.txt" "$HERE/output/disabled.txt" > "$HERE/output/selected.tmp"
mv "$HERE/output/selected.tmp" "$HERE/output/selected.txt"
test -s "$HERE/output/selected.txt"
PACKAGES="-dnsmasq $(tr '\n' ' ' < "$HERE/output/selected.txt") $(sed 's/^/-/' "$HERE/output/disabled.txt" | tr '\n' ' ')"
echo "Building rootfs with $(wc -l < "$HERE/output/selected.txt") packages, Docker=$WITH_DOCKER, rootfs=$ROOTFS_GIB GiB"
(
  cd "$NAME"
  make image PROFILE=king3288 PACKAGES="$PACKAGES"
)
OUT="$NAME/bin/targets/rockchip/armv7"
MANIFEST="$OUT/istoreos-rockchip-armv7-king3288.manifest"
test -s "$MANIFEST"
awk '{print $1}' "$MANIFEST" | LC_ALL=C sort -u > "$HERE/output/actual.txt"
comm -23 "$HERE/output/selected.txt" "$HERE/output/actual.txt" > "$HERE/output/missing.txt"
comm -12 "$HERE/output/disabled.txt" "$HERE/output/actual.txt" > "$HERE/output/unwanted.txt"
if [[ -s "$HERE/output/missing.txt" || -s "$HERE/output/unwanted.txt" ]]; then
  echo 'Package manifest mismatch:' >&2
  cat "$HERE/output/missing.txt" "$HERE/output/unwanted.txt" >&2
  exit 1
fi
echo "PACKAGE_MANIFEST_VERIFIED"
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
  ROOTFS_GIB="$ROOTFS_GIB" bash king3288-tools/build-king3288-sd-image-txpbl1-v3.sh
  ROOTFS_GIB="$ROOTFS_GIB" bash king3288-tools/validate-king3288-sd-image-txpbl1-v3.sh
)
mkdir -p "$HERE/output"
cp -f "$OUT/istoreos-rockchip-armv7-king3288-sdcard-3g-txpbl1-v3.img.gz" "$HERE/output/king3288-root${ROOTFS_GIB}g-docker-${WITH_DOCKER}.img.gz"
(cd "$HERE/output" && sha256sum "king3288-root${ROOTFS_GIB}g-docker-${WITH_DOCKER}.img.gz" > SHA256SUMS)
cp -f "$MANIFEST" "$HERE/output/king3288.manifest"

echo "SD_V3_IMAGEBUILDER_OK"
echo "Output: $HERE/output/"
