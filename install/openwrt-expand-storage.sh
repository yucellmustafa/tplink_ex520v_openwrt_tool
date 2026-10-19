#!/bin/sh
# Two-stage SSH migration using the normal sysupgrade RAM-pivot.
# Bootstrap: update kernel/rootfs in ubi0; keep stock and settings.
# Finalize: after wide-DTS boot, format the exact 407 MiB data MTD.
set -e
. /lib/functions.sh
set -u
die() { echo "[ex520v] ERROR: $*" >&2; exit 1; }
IMG="${1:-}"
MODE="${2:---check}"
EXPECTED_UBOOT_SHA256="${3:-}"
[ "$MODE" = --check ] || [ "$MODE" = --erase-stock-407m ] || die 'invalid mode'
[ "$(id -u)" = 0 ] && [ "$(board_name)" = tplink,ex520v ] || die 'wrong board or UID'
grep -Eq '(^| )ubi\.mtd=ubi0( |$)' /proc/cmdline || die 'not booted from ubi0'
[ "$(awk '$2=="/rom"{print $3;exit}' /proc/mounts)" = squashfs ] || die 'installed OpenWrt flash system required'
[ "$(awk '$2=="/overlay"{print $3;exit}' /proc/mounts)" = ubifs ] || die 'repair the missing persistent overlay first'
OVERLAY="$(awk '$2=="/overlay"{print $1;exit}' /proc/mounts)"
case "$OVERLAY" in /dev/ubi0_*) ;; *) die 'transition requires persistent overlay in ubi0' ;; esac
[ "$(cat /sys/class/ubi/ubi0/mtd_num)" = 4 ] || die 'ubi0 mapping is not the boot MTD'
[ "$(cat "/sys/class/ubi/${OVERLAY##*/}/name")" = rootfs_data ] || die 'overlay volume is not rootfs_data'

check_part() {
    local d count=0
    for d in /sys/class/mtd/mtd[0-9]*; do
        [ -f "$d/name" ] || continue
        [ "$(cat "$d/name")" = "$1" ] || continue
        count=$((count + 1))
        [ "$(cat "$d/offset")" = "$2" ] || die "wrong $1 offset"
        [ "$(cat "$d/size")" = "$3" ] || die "wrong $1 size"
        [ "$(cat "$d/erasesize")" = 262144 ] || die 'wrong NAND erase size'
        case "$1" in u-boot-env) ENV_MTD="${d##*mtd}" ;; ubi) DATA_MTD="${d##*mtd}" ;; esac
    done
    [ "$count" = 1 ] || die "partition $1 missing or duplicated"
}
check_part boot 0 2097152
check_part u-boot-env 2097152 1048576
check_part misc_ro 3145728 15728640
check_part misc_rw 18874368 15728640
check_part ubi0 34603008 41943040
count=0
for d in /sys/class/mtd/mtd[0-9]*; do [ ! -f "$d/name" ] || count=$((count + 1)); done
case "$count" in
    11)
        STAGE=bootstrap
        check_part ubi1 76546048 41943040
        check_part bflag 118489088 15728640
        check_part misc_rw_bak 134217728 15728640
        check_part misc_isp 149946368 15728640
        check_part runtime_data 165675008 15728640
        check_part container 181403648 209715200
        PLATFORM_HASH=9471d212d5d93e81655c53e72af56f3eaaca5d9ed183da447e2a8aa2ebc41c3f
        ;;
    6)
        STAGE=finalize
        check_part ubi 76546048 426770432
        PLATFORM_HASH=77545e65ef8e1a8f03794a6abc4f64916bc5bcd02cfb7548851f34764ce96be4
        ;;
    *) die 'unreviewed MTD layout' ;;
esac
ENV_CONFIG=/tmp/ex520v-expansion-fw-env.config
printf '/dev/mtd%s 0x0 0x20000 0x20000 1\n' "$ENV_MTD" > "$ENV_CONFIG"
env_error=$(fw_printenv -c "$ENV_CONFIG" 2>&1 >/dev/null) || die 'cannot verify boot environment CRC'
[ -z "$env_error" ] || die 'boot environment warning; CRC/default fallback is not accepted'
[ -z "$(fw_printenv -c "$ENV_CONFIG" -n ex520v_trial 2>/dev/null || true)" ] || die 'trial is still armed'
[ -z "$(fw_printenv -c "$ENV_CONFIG" -n tp_boot_idx 2>/dev/null || true)" ] || die 'stock slot is selected'
echo "$PLATFORM_HASH  /lib/upgrade/platform.sh" | sha256sum -c - >/dev/null || die 'unreviewed platform upgrader'
echo '89d17e2ac4aab82493e4bcffa14fd98dffbe59f27b585e42225796ec47d83d92  /lib/upgrade/nand.sh' | sha256sum -c - >/dev/null || die 'unreviewed NAND upgrader'
[ -f "$IMG" ] || die 'sysupgrade image missing'
[ "$(sha256sum "$IMG" | cut -d' ' -f1)" = 3f066005e89afc8fae214e874ea3b4e40d9ad0639daff494b4ff258f7a1bbe0b ] || die 'wrong sysupgrade SHA256'
for required in '0:uboot' '1:kernel' '2:rootfs' '3:rootfs_data'; do
    id=${required%%:*}; name=${required#*:}; v="/sys/class/ubi/ubi0/ubi0_$id"
    [ -f "$v/name" ] && [ "$(cat "$v/name")" = "$name" ] || die "unexpected ubi0 volume $id (expected $name)"
done
[ "$(cat /sys/class/ubi/ubi0/ubi0_0/type)" = static ] || die 'uboot volume is not static'
[ "$(cat /sys/class/ubi/ubi0/ubi0_0/data_bytes)" -gt 0 ] || die 'second-stage uboot is empty'
if [ -n "$EXPECTED_UBOOT_SHA256" ]; then
    echo "$EXPECTED_UBOOT_SHA256" | grep -Eq '^[0-9a-f]{64}$' || die 'invalid expected uboot SHA256'
    [ "$(sha256sum /dev/ubi0_0 | cut -d' ' -f1)" = "$EXPECTED_UBOOT_SHA256" ] || die 'second-stage uboot SHA256 changed'
fi
sysupgrade -T "$IMG" || die 'sysupgrade image check rejected'
echo "[ex520v] CHECK OK: SSH expansion stage=$STAGE; sysupgrade will preserve settings"
[ "$MODE" = --erase-stock-407m ] || exit 0
if [ "$STAGE" = finalize ]; then
    sysupgrade -b /tmp/ex520v-expansion-settings.tar.gz
    for u in /sys/class/ubi/ubi[0-9]*; do
        [ -f "$u/mtd_num" ] || continue
        [ "$(cat "$u/mtd_num")" = "$DATA_MTD" ] || continue
        if grep -Eq "(/dev/${u##*/}_|${u##*/}:)" /proc/mounts; then die 'data MTD is mounted'; fi
        ubidetach -m "$DATA_MTD" || die 'data MTD cannot be detached'
    done
    echo '[ex520v] WRITING: formatting stock/data area for the 407 MiB overlay'
    ubiformat "/dev/mtd$DATA_MTD" -y || die 'data MTD format failed'
fi
echo "[ex520v] STARTING: expansion sysupgrade stage=$STAGE; reboot verification required"
exec sysupgrade -c "$IMG"
