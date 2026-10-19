#!/bin/sh
# Create only a missing volume in unused ubi0 space, preserving kernel/rootfs.
set -e
. /lib/functions.sh
set -u
die() { echo "[ex520v] ERROR: $*" >&2; exit 1; }
MODE="${1:---check}"
[ "$MODE" = --check ] || [ "$MODE" = --repair ] || die 'invalid mode'
[ "$(id -u)" = 0 ] && [ "$(board_name)" = tplink,ex520v ] || die 'wrong board or UID'
grep -Eq '(^| )ubi\.mtd=ubi0( |$)' /proc/cmdline || die 'not booted from ubi0'
[ "$(awk '$2=="/rom"{print $3;exit}' /proc/mounts)" = squashfs ] || die 'flash squashfs required'
[ "$(awk '$2=="/"{print $1;exit}' /proc/mounts)" = overlayfs:/tmp/root ] || die 'root is not the expected RAM fallback'
[ -z "$(awk '$2=="/overlay"{print $3}' /proc/mounts)" ] || die 'overlay already mounted'
[ "$(cat /sys/class/ubi/ubi0/mtd_num)" = 4 ] || die 'ubi0 not on expected MTD'
[ "$(cat /sys/class/mtd/mtd4/name)" = ubi0 ] || die 'wrong MTD name'
[ "$(cat /sys/class/mtd/mtd4/offset)" = 34603008 ] || die 'wrong MTD offset'
[ "$(cat /sys/class/mtd/mtd4/size)" = 41943040 ] || die 'wrong MTD size'
for v in /sys/class/ubi/ubi*_*; do
    [ -f "$v/name" ] || continue
    [ "$(cat "$v/name")" != rootfs_data ] || die 'rootfs_data already exists; refusing to overwrite'
done
[ "$(cat /sys/class/ubi/ubi0/avail_eraseblocks)" -ge 32 ] || die 'not enough unused eraseblocks'
[ -d /tmp/root/upper/etc ] || die 'RAM upper directory missing'
used=$(du -sk /tmp/root/upper | cut -f1)
available=$(($(cat /sys/class/ubi/ubi0/avail_eraseblocks) * $(cat /sys/class/ubi/ubi0/eraseblock_size) / 1024))
[ "$used" -lt "$((available / 2))" ] || die 'RAM overlay too large for safe copy'
echo '[ex520v] CHECK OK: missing overlay can be created in unused ubi0 space'
[ "$MODE" = --repair ] || exit 0
MNT=/tmp/ex520v-overlay-repair
[ ! -e "$MNT" ] || die 'repair mountpoint already exists'
mkdir "$MNT"
ubimkvol /dev/ubi0 -N rootfs_data -m
id=''
for v in /sys/class/ubi/ubi0/ubi0_*; do
    [ -f "$v/name" ] || continue
    [ "$(cat "$v/name")" != rootfs_data ] || id="${v##*_}"
done
[ -n "$id" ] || die 'new rootfs_data not found'
mount -t ubifs "/dev/ubi0_$id" "$MNT"
trap 'umount "$MNT" 2>/dev/null || true' EXIT
mkdir "$MNT/upper" "$MNT/work"
cp -a /tmp/root/upper/. "$MNT/upper/"
# OpenWrt fstools FS_STATE_READY prevents the first boot discarding this copy.
ln -s 2 "$MNT/.fs_state"
cat /proc/sys/kernel/random/boot_id > "$MNT/upper/etc/ex520v-overlay-repair-proof"
sync
umount "$MNT"
trap - EXIT
rmdir "$MNT"
echo '[ex520v] DONE: persistent overlay created and RAM settings copied; reboot verification required'
