#!/bin/sh
# Runs in the freshly booted OpenWrt initramfs. The release image does not
# ship /etc/fw_env.config, so create a RAM-only config and arm stock fallback.
set -e
. /lib/functions.sh

log() { echo "[ex520v] $*"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(board_name)" = "tplink,ex520v" ] || die "not a TP-Link EX520v"
[ "$(awk '$2=="/"{print $3;exit}' /proc/mounts)" = tmpfs ] || die "not running from initramfs"
grep -Eq '(^| )ubi\.mtd=ubi0( |$)' /proc/cmdline || die "OpenWrt was not booted from ubi0"

ENV_MTD=""
ENV_COUNT=0
for d in /sys/class/mtd/mtd[0-9]*; do
	[ -f "$d/name" ] || continue
	[ "$(cat "$d/name")" = "u-boot-env" ] || continue
	ENV_COUNT=$((ENV_COUNT + 1))
	ENV_MTD="${d##*mtd}"
	[ "$(cat "$d/offset")" = 2097152 ] || die "unexpected u-boot-env offset"
	[ "$(cat "$d/size")" = 1048576 ] || die "unexpected u-boot-env size"
	[ "$(cat "$d/erasesize")" = 262144 ] || die "unexpected u-boot-env erase size"
done
[ "$ENV_COUNT" = 1 ] && [ -n "$ENV_MTD" ] || die "u-boot-env partition missing or duplicated"

ENV_CONFIG=/etc/fw_env.config
printf '/dev/mtd%s 0x0 0x20000 0x20000 1\n' "$ENV_MTD" > "$ENV_CONFIG"
fw_printenv -c "$ENV_CONFIG" >/dev/null 2>&1 || die "boot environment CRC cannot be verified"

# If power is lost between the two writes, ubi0 remains selected. Only the
# second verified write changes the next boot to the preserved stock slot.
fw_setenv -c "$ENV_CONFIG" ex520v_trial 1
[ "$(fw_printenv -c "$ENV_CONFIG" -n ex520v_trial 2>/dev/null)" = 1 ] || die "trial marker could not be stored"
fw_setenv -c "$ENV_CONFIG" tp_boot_idx 1
[ "$(fw_printenv -c "$ENV_CONFIG" -n tp_boot_idx 2>/dev/null)" = 1 ] || die "stock fallback could not be selected"

printf 'armed\n' > /tmp/ex520v-trial
sync
log "DONE: RAM trial verified; stock fallback is armed"
