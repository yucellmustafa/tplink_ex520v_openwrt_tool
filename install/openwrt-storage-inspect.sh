#!/bin/sh
# Read-only NAND/UBI inventory; no attach, mount, erase or environment writes.
set -e
. /lib/functions.sh
set -u
echo SCHEMA=1
echo BOARD="$(board_name)"
echo UID="$(id -u)"
echo BOOTID="$(cat /proc/sys/kernel/random/boot_id)"
echo CMDLINE="$(cat /proc/cmdline)"
echo ROOTFS="$(awk '$2=="/"{print $3;exit}' /proc/mounts)"
echo ROMFS="$(awk '$2=="/rom"{print $3;exit}' /proc/mounts)"
echo OVERLAYFS="$(awk '$2=="/overlay"{print $3;exit}' /proc/mounts)"
echo OVERLAYSRC="$(awk '$2=="/overlay"{print $1;exit}' /proc/mounts)"
ENV_MTD="$(awk -F: '$2 ~ /"u-boot-env"/{gsub(/^mtd/,"",$1);print $1}' /proc/mtd)"
ENV_CONFIG=/tmp/ex520v-fw-env.config
if echo "$ENV_MTD" | grep -Eq '^[0-9]+$'; then
    printf '/dev/mtd%s 0x0 0x20000 0x20000 1\n' "$ENV_MTD" > "$ENV_CONFIG"
fi
echo BOOTIDX="$(fw_printenv -c "$ENV_CONFIG" -n tp_boot_idx 2>/dev/null || true)"
echo TRIAL="$(fw_printenv -c "$ENV_CONFIG" -n ex520v_trial 2>/dev/null || true)"
echo TRIALMARK="$(cat /tmp/ex520v-trial 2>/dev/null || true)"
df -Pk / | awk 'NR==2{print "ROOT_TOTAL_KIB=" $2;print "ROOT_AVAILABLE_KIB=" $4}'
for d in /sys/class/mtd/mtd[0-9]*; do
    [ -f "$d/name" ] || continue
    echo PART="${d##*/}|$(cat "$d/name")|$(cat "$d/offset")|$(cat "$d/size")|$(cat "$d/erasesize")"
done
for u in /sys/class/ubi/ubi[0-9]*; do
    [ -f "$u/mtd_num" ] || continue
    echo UBI="${u##*/}|$(cat "$u/mtd_num")|$(cat "$u/eraseblock_size")|$(cat "$u/avail_eraseblocks")"
    for v in "$u"/ubi[0-9]*_*; do
        [ -f "$v/name" ] || continue
        echo VOL="${u##*/}|${v##*/}|$(cat "$v/name")|$(cat "$v/reserved_ebs")"
    done
done
echo COMPLETE=1
