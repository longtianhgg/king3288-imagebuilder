#!/usr/bin/env bash
# Host-side file-only KING3288 full SD image builder. No sudo, no /dev writes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDB=king3288-blobs/king3288-idb-miniloader.bin
cd "$ROOT"
OUT=bin/targets/rockchip/armv7
WORK=build_dir/king3288-m7-sd-image
mkdir -p "$WORK" "$OUT"
RAW="$OUT/istoreos-rockchip-armv7-king3288-sdcard-3g-txpbl1-v3.img"
GZ="$RAW.gz"
FAT="$WORK/boot.fat"
EXT4="$WORK/root.ext4"
STAGING="$WORK/staging"
KDIR=build_dir/target-arm_cortex-a15+neon-vfpv4_musl_eabi/linux-rockchip_armv7
KERNEL="$KDIR/zImage"
DTB="$KDIR/linux-6.6.144/arch/arm/boot/dts/rockchip/rk3288-king3288.dtb"
# A released standalone ImageBuilder stores the prebuilt DTB at this location.
if [ ! -s "$DTB" ] && [ -s "$KDIR/image-rk3288-king3288.dtb" ]; then
  DTB="$KDIR/image-rk3288-king3288.dtb"
fi
ROOT_TAR="$OUT/istoreos-rockchip-armv7-king3288-rootfs.tar.gz"
EXPAND=king3288-tools/king3288-expand-rootfs.sh
INIT=king3288-tools/king3288-rootfs-resize.init
EMMC_PROTECT=target/linux/rockchip/armv7/base-files/etc/uci-defaults/10-king3288-protect-emmc
PREFIX_SHA=84c08dd990738c1e935f86206a062aa75effc1148039328b5aa1722db818f8e3
DISK_ID=0x4b328826
P1_START=32768
P1_SECTORS=2097152
P2_START=2129920
P2_SECTORS=4194304
TOTAL_SECTORS=$((P2_START + P2_SECTORS))
for path in "$IDB" "$KERNEL" "$DTB" "$ROOT_TAR" "$EXPAND" "$INIT" "$EMMC_PROTECT"; do test -s "$path" || { echo "MISSING: $path"; exit 1; }; done
test "$(fdtget -t x "$DTB" /ethernet@ff290000 snps,txpbl)" = 1 || { echo "ERROR: compiled DTB is not TXPBL=1"; exit 1; }
tar -tzf "$ROOT_TAR" > "$WORK/rootfs-files.txt"
for f in \
  ./usr/sbin/king3288-expand-rootfs \
  ./etc/init.d/king3288-rootfs-resize \
  ./etc/uci-defaults/10-king3288-protect-emmc; do
  grep -Fx "$f" "$WORK/rootfs-files.txt" >/dev/null || {
    echo "ERROR: compiled rootfs missing source-owned $f"
    exit 1
  }
done
echo M8_SOURCE_ROOTFS_INTEGRATION_VERIFIED

test "$(wc -l < king3288-configs/m8-txpbl1-imagebuilder-packages.txt)" -eq 296
test -s "$OUT/istoreos-rockchip-armv7-king3288.manifest"
diff -u <(awk '{print $1}' "$OUT/istoreos-rockchip-armv7-king3288.manifest" | sort) <(sort king3288-configs/m8-txpbl1-imagebuilder-packages.txt)
sh -n "$EXPAND"; sh -n "$INIT"; sh -n "$EMMC_PROTECT"
test "$(stat -c %s "$IDB")" = 105472
test "$(sha256sum "$IDB" | awk '{print $1}')" = "$PREFIX_SHA"
echo "M7_BUILD_READY source and IDB prefix verified"
rm -f "$RAW" "$GZ" "$FAT" "$EXT4"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# One common fakeroot context preserves the numeric UID/GID from tar into -d ext4.
fakeroot -- /bin/bash -euc '
 tar --numeric-owner -xzpf "$1" -C "$2"
 install -D -m 0755 "$3" "$2/usr/sbin/king3288-expand-rootfs"
 install -D -m 0755 "$4" "$2/etc/init.d/king3288-rootfs-resize"
 install -D -m 0755 "$5" "$2/etc/uci-defaults/10-king3288-protect-emmc"
 mkdir -p "$2/root"
 cat > "$2/root/README-KING3288-SD-EXPAND.txt" <<EOF
KING3288 SD p2 ext4 rootfs expansion
New image: p1 FAT32 boot, p2 ext4 rootfs.
Run only on a newly flashed SD booting KING3288:
  /usr/sbin/king3288-expand-rootfs --check
  /usr/sbin/king3288-expand-rootfs --apply
  reboot
After reboot:
  df -h /
  /usr/sbin/king3288-expand-rootfs --check
The one-shot service finishes resize2fs after reboot, if --apply enabled it.
Never use the script on eMMC or on the production SD card.
EOF
 chown 0:0 "$2/usr/sbin/king3288-expand-rootfs" "$2/etc/init.d/king3288-rootfs-resize" "$2/etc/uci-defaults/10-king3288-protect-emmc" "$2/root/README-KING3288-SD-EXPAND.txt"
 truncate -s 2G "$6"
 mkfs.ext4 -q -F -m 1 -L KINGROOT -U 52b116ba-1676-4cb6-a20e-9e80e340cf65 -d "$2" "$6"
' _ "$ROOT_TAR" "$STAGING" "$EXPAND" "$INIT" "$EMMC_PROTECT" "$EXT4"
echo M7_EXT4_CREATED
e2fsck -fn "$EXT4" > "$WORK/e2fsck.log" 2>&1 || { tail -n 35 "$WORK/e2fsck.log"; exit 1; }
debugfs -R 'stat /etc/shadow' "$EXT4" 2>/dev/null | grep -E 'User: *0 *Group: *0' >/dev/null
debugfs -R 'stat /usr/sbin/king3288-expand-rootfs' "$EXT4" 2>/dev/null | grep -E 'User: *0 *Group: *0' >/dev/null
debugfs -R 'cat /usr/sbin/king3288-expand-rootfs' "$EXT4" 2>/dev/null | grep -F "NOT AN SD CARD: refusing eMMC" >/dev/null
if debugfs -R 'cat /usr/sbin/king3288-expand-rootfs' "$EXT4" 2>/dev/null | grep -q "die 'Not a removable SD disk'"; then echo 'Old SD removable blocking check still present'; exit 1; fi
debugfs -R 'stat /etc/uci-defaults/10-king3288-protect-emmc' "$EXT4" 2>/dev/null | grep -E 'User: *0 *Group: *0' >/dev/null
debugfs -R 'cat /etc/uci-defaults/10-king3288-protect-emmc' "$EXT4" 2>/dev/null | grep -F "set fstab.emmc_protect.enabled='0'" >/dev/null
debugfs -R 'cat /root/README-KING3288-SD-EXPAND.txt' "$EXT4" 2>/dev/null | grep -F -- '--apply'
echo M7_EXT4_METADATA_AND_EXPAND_PAYLOAD_VERIFIED

truncate -s 1G "$FAT"
mkfs.vfat -F 32 -n KINGBOOT "$FAT" >/dev/null
mmd -i "$FAT" ::/extlinux
cat > "$WORK/extlinux.conf" <<'EOF'
DEFAULT istoreos
TIMEOUT 10

LABEL istoreos
LINUX /zImage
FDT /rk3288-king3288.dtb
APPEND console=ttyS2,115200n8 earlycon root=PARTUUID=4b328826-02 rootfstype=ext4 rootwait rw init=/sbin/init
EOF
mcopy -i "$FAT" "$KERNEL" ::/zImage
mcopy -i "$FAT" "$DTB" ::/rk3288-king3288.dtb
mcopy -i "$FAT" "$WORK/extlinux.conf" ::/extlinux/extlinux.conf
mdir -i "$FAT" ::/extlinux > "$WORK/fat-verify.txt"
echo M7_FAT_BOOT_FILES_VERIFIED

truncate -s "$((TOTAL_SECTORS * 512))" "$RAW"
dd if="$IDB" of="$RAW" bs=512 seek=64 conv=notrunc status=none
printf 'label: dos\nlabel-id: %s\nunit: sectors\nstart=%s,size=%s,type=c\nstart=%s,size=%s,type=83\n' "$DISK_ID" "$P1_START" "$P1_SECTORS" "$P2_START" "$P2_SECTORS" | sfdisk --no-reread --wipe never "$RAW" > "$WORK/sfdisk.log" 2>&1
test "$(dd if="$RAW" bs=512 skip=64 count=206 status=none | sha256sum | awk '{print $1}')" = "$PREFIX_SHA"
dd if="$FAT" of="$RAW" bs=1M seek=16 conv=notrunc status=none
dd if="$EXT4" of="$RAW" bs=1M seek=1040 conv=notrunc status=none
sync
sfdisk -d "$RAW" > "$WORK/partitions.txt"
echo M7_RAW_IMAGE_ASSEMBLED
pigz -1 -p 4 -c "$RAW" > "$GZ"
gzip -t "$GZ"
sha256sum "$RAW" "$GZ" > "$WORK/image-sha256sums.txt"
(cd "$OUT" && sha256sum "$(basename "$GZ")" > "$(basename "$GZ").sha256")
ls -lh "$RAW" "$GZ"
cat "$WORK/partitions.txt"
cat "$WORK/image-sha256sums.txt"
echo M7_IMAGE_BUILD_RC=0
