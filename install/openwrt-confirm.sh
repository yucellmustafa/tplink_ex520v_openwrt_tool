#!/bin/sh
# Runs ON OpenWrt booted from flash (slot "ubi0") in trial mode. Makes the
# install permanent: slot ubi0 boots by default and the stock fallback is
# no longer re-armed on every boot. Stock stays in slot ubi1; to go back:
#   fw_setenv ex520v_trial; fw_setenv tp_boot_idx 1; reboot

set -e

. /lib/functions.sh

log() { echo "[ex520v] $*"; }
die() { log "ERROR: $*"; exit 1; }

ENV_MTD="$(awk -F: '$2 ~ /"u-boot-env"/{gsub(/^mtd/,"",$1);print $1}' /proc/mtd)"
echo "$ENV_MTD" | grep -Eq '^[0-9]+$' || die "u-boot-env partition missing or duplicated"
ENV_CONFIG=/tmp/ex520v-fw-env.config
printf '/dev/mtd%s 0x0 0x20000 0x20000 1\n' "$ENV_MTD" > "$ENV_CONFIG"
fw_printenv -c "$ENV_CONFIG" >/dev/null 2>&1 || die "boot environment CRC cannot be verified"

[ "$(board_name)" = "tplink,ex520v" ] || die "not a TP-Link EX520v"
[ "$(awk '$2 == "/rom" { print $3; exit }' /proc/mounts)" = "squashfs" ] ||
	die "not running from flash"
grep -Eq '(^| )ubi\.mtd=ubi0( |$)' /proc/cmdline || die "booted UBI slot is not ubi0"
[ "$(awk '$2 == "/overlay" { print $3; exit }' /proc/mounts)" = "ubifs" ] ||
	die "overlay is not on rootfs_data"
[ "$(awk '$2 == "/overlay" { print $1; exit }' /proc/mounts)" = "/dev/ubi0_3" ] ||
	die "overlay is not on slot ubi0 rootfs_data"

fw_setenv -c "$ENV_CONFIG" tp_boot_idx
fw_setenv -c "$ENV_CONFIG" ex520v_trial
fw_printenv -c "$ENV_CONFIG" -n tp_boot_idx >/dev/null 2>&1 && die "tp_boot_idx still set"
fw_printenv -c "$ENV_CONFIG" -n ex520v_trial >/dev/null 2>&1 && die "ex520v_trial still set"

log "DONE: OpenWrt is now the default; stock remains in slot ubi1"
