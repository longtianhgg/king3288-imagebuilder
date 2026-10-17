#!/usr/bin/env bash
# Offline-only validation of the M8 v3 image, no /dev writes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT=bin/targets/rockchip/armv7
WORK=build_dir/king3288-m8-txpbl1
RAW="$OUT/istoreos-rockchip-armv7-king3288-sdcard-3g-txpbl1-v3.img"
GZ="$RAW.gz"
KDIR=build_dir/target-arm_cortex-a15+neon-vfpv4_musl_eabi/linux-rockchip_armv7
DTB="$KDIR/linux-6.6.144/arch/arm/boot/dts/rockchip/rk3288-king3288.dtb"
ROOTFS_GIB="${ROOTFS_GIB:-2}"
[[ "$ROOTFS_GIB" =~ ^[0-9]+$ ]] && (( ROOTFS_GIB >= 1 && ROOTFS_GIB <= 24 )) || exit 2
P2_SECTORS=$(( ROOTFS_GIB * 2097152 ))
TOTAL_BYTES=$(( (2129920 + P2_SECTORS)*512 ))
FAT_OFFSET=$((32768*512))
EXT4="$ROOT/build_dir/king3288-m7-sd-image/root.ext4"
mkdir -p "$WORK/v3-verify"
test -s "$RAW" && test -s "$GZ" && test -s "$EXT4" && test -s "$DTB"
test "$(stat -c %s "$RAW")" = "$TOTAL_BYTES"
(cd "$OUT" && sha256sum -c "$(basename "$GZ").sha256")
gzip -t "$GZ"
test "$(sfdisk -d "$RAW" | sed -n 's/^label-id: //p')" = 0x4b328826
sfdisk -d "$RAW" | grep -E '^.+img1 : start= +32768, size= +2097152, type=c$' >/dev/null
sfdisk -d "$RAW" | grep -E '^.+img2 : start= +2129920, size= +${P2_SECTORS}, type=83$' >/dev/null
test "$(dd if="$RAW" bs=512 skip=64 count=206 status=none | sha256sum | cut -d' ' -f1)" = 84c08dd990738c1e935f86206a062aa75effc1148039328b5aa1722db818f8e3
echo M8_PARTITION_AND_IDB_OK
mcopy -o -i "$RAW@@$FAT_OFFSET" ::/zImage "$WORK/v3-verify/zImage"
mcopy -o -i "$RAW@@$FAT_OFFSET" ::/rk3288-king3288.dtb "$WORK/v3-verify/rk3288-king3288.dtb"
mcopy -o -i "$RAW@@$FAT_OFFSET" ::/extlinux/extlinux.conf "$WORK/v3-verify/extlinux.conf"
cmp "$KDIR/zImage" "$WORK/v3-verify/zImage"
cmp "$DTB" "$WORK/v3-verify/rk3288-king3288.dtb"
cmp "$ROOT/build_dir/king3288-m7-sd-image/extlinux.conf" "$WORK/v3-verify/extlinux.conf"
test "$(fdtget -t x "$WORK/v3-verify/rk3288-king3288.dtb" /ethernet@ff290000 snps,txpbl)" = 1
test "$(fdtget -t x "$WORK/v3-verify/rk3288-king3288.dtb" /ethernet@ff290000 tx_delay)" = 30
test "$(fdtget -t x "$WORK/v3-verify/rk3288-king3288.dtb" /ethernet@ff290000 rx_delay)" = 10
echo M8_BOOT_FILES_AND_DTB_OK
test "$(dd if="$RAW" bs=1M skip=1040 count="$((ROOTFS_GIB*1024))" status=none | sha256sum | cut -d' ' -f1)" = "$(sha256sum "$EXT4" | cut -d' ' -f1)"
e2fsck -fn "$EXT4" > "$WORK/v3-verify/e2fsck.log" 2>&1
for f in /usr/sbin/king3288-expand-rootfs /etc/init.d/king3288-rootfs-resize /etc/uci-defaults/10-king3288-protect-emmc; do
  debugfs -R "stat $f" "$EXT4" 2>/dev/null | grep 'User: *0 *Group: *0' >/dev/null
done
echo M8_EXT4_BYTES_AND_3_SOURCE_SCRIPTS_OK
echo M8_V3_FULL_DISK_OFFLINE_VALIDATION_OK
