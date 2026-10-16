#!/bin/sh
# KING3288 SD-only p2/ext4 expansion; NO eMMC support.
# p1=FAT32/extlinux, p2=ext4 /, MBR disk. Run --check first.
# --apply backs up MBR/IDB prefix and extends SD p2; --finish grows ext4 after reboot.
set -eu
TAG=king3288-expand
STATE=/etc/king3288-rootfs-expand.pending
DONE=/etc/king3288-rootfs-expand.done
INIT=/etc/init.d/king3288-rootfs-resize
MIN_FREE_SECTORS=32768  # 16 MiB
log() { echo "[$TAG] $*"; }
die() { echo "[$TAG] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

[ "$#" -eq 1 ] || die "Usage: $0 --check|--apply|--finish"
case "$1" in --check|--apply|--finish) MODE=$1;; *) die "Unknown mode: $1";; esac
[ "$(id -u)" = 0 ] || die "Must run as root"
for cmd in awk blkid cat grep parted readlink tr; do need "$cmd"; done

MODEL=$(tr -d '\000' </proc/device-tree/model 2>/dev/null) || die 'Cannot read DT model'
[ "$MODEL" = KING3288 ] || die "Not the KING3288 device: $MODEL"

# Match root PARTUUID from the active extlinux bootargs to an actual block device.
# Never assume that SD is mmcblk0 or mmcblk1.
ROOT_ID=
for arg in $(cat /proc/cmdline); do
    case "$arg" in root=PARTUUID=*) ROOT_ID=${arg#root=PARTUUID=};; esac
done
[ -n "$ROOT_ID" ] || die 'Expected root=PARTUUID=... in cmdline'
ROOT_DEV=
for candidate in /dev/mmcblk[0-9]*p2; do
    [ -b "$candidate" ] || continue
    id=$(blkid -s PARTUUID -o value "$candidate" 2>/dev/null || true)
    if [ "$id" = "$ROOT_ID" ]; then
        [ -z "$ROOT_DEV" ] || die 'Ambiguous root PARTUUID'
        ROOT_DEV=$candidate
    fi
done
[ -n "$ROOT_DEV" ] || die 'Root PARTUUID does not identify mmcblkXp2'

BASE=${ROOT_DEV#/dev/}
DISK_BASE=${BASE%p2}
DISK=/dev/$DISK_BASE
SYS_DISK=/sys/class/block/$DISK_BASE
SYS_ROOT=/sys/class/block/$BASE
SYS_BOOT=/sys/class/block/${DISK_BASE}p1
[ -b "$DISK" ] || die 'Parent block disk missing'
[ -r "$SYS_ROOT/partition" ] || die 'Root partition number unavailable'
[ "$(cat "$SYS_ROOT/partition")" = 2 ] || die 'Root is not p2'
[ -d "$SYS_BOOT" ] || die 'Missing FAT boot p1'
[ -r "$SYS_DISK/device/type" ] || die 'MMC type unavailable'
[ "$(cat "$SYS_DISK/device/type")" = SD ] || die 'NOT AN SD CARD: refusing eMMC'
# The Rockchip MMC host can report removable=0 for a genuine SD card.
# Real SD identity is validated by device/type=SD, boot PARTUUID, and mounted root.
# Never use the generic removable flag as a blocking safety condition.
[ "$(cat "$SYS_DISK/queue/logical_block_size")" = 512 ] || die 'Unexpected sector size'

ROOT_SRC=$(awk '$2=="/" {print $1;exit}' /proc/mounts)
ROOT_TYPE=$(awk '$2=="/" {print $3;exit}' /proc/mounts)
[ "$ROOT_TYPE" = ext4 ] || die 'Root is not ext4'
case "$ROOT_SRC" in
    /dev/root|PARTUUID="$ROOT_ID") ;;
    /dev/*)
        ACTUAL=$(readlink -f "$ROOT_SRC") || die 'Cannot resolve mount source'
        [ "$ACTUAL" = "$ROOT_DEV" ] || die 'Mounted root and boot PARTUUID mismatch'
        ;;
    *) die "Unsupported root mount source: $ROOT_SRC";;
esac
[ "$(blkid -s TYPE -o value "$ROOT_DEV" 2>/dev/null)" = ext4 ] || die 'p2 not ext4'
[ "$(blkid -s TYPE -o value "/dev/${DISK_BASE}p1" 2>/dev/null)" = vfat ] || die 'p1 not FAT'

TABLE=$(parted -s "$DISK" print 2>/dev/null | awk -F': ' '/Partition Table:/ {print $2;exit}')
[ "$TABLE" = msdos ] || die "Expected MBR/msdos, found $TABLE"
# Current KING3288 image must have *only* SD p1 + p2, no extra partitions.
for part in /sys/class/block/${DISK_BASE}p*; do
    [ -e "$part" ] || continue
    n=${part##*/}
    case "$n" in "${DISK_BASE}p1"|"${DISK_BASE}p2") ;; *) die "Extra SD partition $n";; esac
done
P1_START=$(cat "$SYS_BOOT/start")
P1_SIZE=$(cat "$SYS_BOOT/size")
P2_START=$(cat "$SYS_ROOT/start")
P2_SIZE=$(cat "$SYS_ROOT/size")
DISK_SIZE=$(cat "$SYS_DISK/size")
[ "$P1_START" -lt "$P2_START" ] || die 'p1 must precede p2'
[ "$((P1_START + P1_SIZE))" -le "$P2_START" ] || die 'p1/p2 overlap'
[ "$((P2_START + P2_SIZE))" -le "$DISK_SIZE" ] || die 'p2 exceeds SD size'
FREE=$((DISK_SIZE - P2_START - P2_SIZE))
log "SD=$DISK ($TABLE), root=$ROOT_DEV, PARTUUID=$ROOT_ID"
log "p2 start=$P2_START sectors, size=$P2_SIZE sectors, unallocated after p2=$((FREE / 2048)) MiB"

if [ "$MODE" = --check ]; then
    [ ! -f "$STATE" ] || log 'Pending post-reboot resize2fs'
    [ ! -f "$DONE" ] || log 'Already successfully completed'
    log 'Read-only checks passed; nothing written'
    exit 0
fi

need resize2fs
if [ "$MODE" = --finish ]; then
    [ -r "$STATE" ] || die 'No pending resize; use --apply first'
    read -r SAVED_ID SAVED_START SAVED_SIZE < "$STATE" || die 'Invalid saved resize state'
    [ "$SAVED_ID" = "$ROOT_ID" ] || die 'PARTUUID changed; refusing'
    [ "$SAVED_START" = "$P2_START" ] || die 'Partition start changed; refusing'
    [ "$P2_SIZE" -gt "$SAVED_SIZE" ] || die 'Kernel still sees old partition geometry; reboot required'
    [ "$FREE" -lt "$MIN_FREE_SECTORS" ] || die 'Partition does not yet extend to card end'
    resize2fs "$ROOT_DEV" || die 'resize2fs failed; pending state preserved'
    sync
    printf '%s %s\n' "$ROOT_ID" "$P2_START" > "$DONE"
    rm -f "$STATE"
    [ ! -x "$INIT" ] || "$INIT" disable || :
    log 'p2 ext4 filesystem expansion complete'
    df -h / 2>/dev/null || :
    exit 0
fi

# --apply: reversible state and backups before any partition-table write.
[ ! -e "$DONE" ] || { log 'Already completed'; exit 0; }
[ ! -e "$STATE" ] || die 'Pending previous resize; reboot and use --finish'
if [ "$FREE" -lt "$MIN_FREE_SECTORS" ]; then
    log 'p2 already occupies SD disk; growing ext4 online'
    resize2fs "$ROOT_DEV" || die 'resize2fs failed'
    printf '%s %s\n' "$ROOT_ID" "$P2_START" > "$DONE"
    df -h / 2>/dev/null || :
    exit 0
fi

for cmd in dd date sync wc mkdir; do need "$cmd"; done
umask 077
BACKUP_DIR=/root/king3288-expand-backup
mkdir -p "$BACKUP_DIR" || die 'Cannot create backup directory'
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_DIR/${DISK_BASE}-first1MiB-$STAMP.bin"
log "Backing up SD first 1MiB (MBR/Rockchip IDB) to $BACKUP"
dd if="$DISK" of="$BACKUP" bs=1048576 count=1 2>/dev/null || die 'Backup failed'
[ "$(wc -c < "$BACKUP")" = 1048576 ] || die 'Backup is truncated'
parted -s "$DISK" unit s print > "$BACKUP.partition-table.txt" || die 'Partition table backup failed'
sync
# Preserve the original geometry if a partition change only partially succeeds.
printf '%s %s %s\n' "$ROOT_ID" "$P2_START" "$P2_SIZE" > "$STATE"
sync
log 'Changing ONLY SD p2 end to 100%; p1 and bootloader remain untouched'
printf 'Yes\n' | parted ---pretend-input-tty "$DISK" resizepart 2 100% || die 'parted failed; backup and state retained'
sync
[ ! -x "$INIT" ] || "$INIT" enable || log 'Cannot enable one-shot init; run --finish manually after reboot'
log 'Partition table updated. Reboot, then run --finish (or allow one-shot init).'
