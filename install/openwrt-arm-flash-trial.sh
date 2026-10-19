#!/bin/sh
# Re-arm the preserved stock slot after the first OpenWrt flash boot.
set -e
. /lib/functions.sh

log() { echo "[ex520v] $*"; }
die() { log "ERROR: $*"; exit 1; }
mtd_index() { grep "\"$1\"" /proc/mtd | cut -d: -f1 | sed 's/^mtd//'; }

EXPECTED_MERGED_UBI1=""
if [ "$1" = "--expected-merged-ubi1" ]; then
	EXPECTED_MERGED_UBI1="$2"
	echo "$EXPECTED_MERGED_UBI1" | grep -Eq '^[0-9a-f]{64}$' || die "invalid expected stock SHA256"
	[ -z "$3" ] || die "unexpected argument"
elif [ -n "$1" ]; then
	die "unexpected argument"
fi

[ "$(board_name)" = "tplink,ex520v" ] || die "not a TP-Link EX520v"
[ "$(awk '$2=="/rom"{print $3;exit}' /proc/mounts)" = squashfs ] || die "not running from flash"
[ "$(awk '$2=="/overlay"{print $3;exit}' /proc/mounts)" = ubifs ] || die "persistent overlay is missing"
grep -Eq '(^| )ubi\.mtd=ubi0( |$)' /proc/cmdline || die "OpenWrt was not booted from ubi0"

ENV_MTD="$(awk -F: '$2 ~ /"u-boot-env"/{gsub(/^mtd/,"",$1);print $1}' /proc/mtd)"
echo "$ENV_MTD" | grep -Eq '^[0-9]+$' || die "u-boot-env partition missing or duplicated"
ENV_CONFIG=/tmp/ex520v-fw-env.config
printf '/dev/mtd%s 0x0 0x20000 0x20000 1\n' "$ENV_MTD" > "$ENV_CONFIG"
fw_printenv -c "$ENV_CONFIG" >/dev/null 2>&1 || die "boot environment CRC cannot be verified"
[ "$(fw_printenv -c "$ENV_CONFIG" -n ex520v_trial 2>/dev/null)" = 1 ] || die "flash trial marker is not set"

# The wmemcmp DTS exposes the old ubi1 start as one 407 MiB "ubi"
# partition. Before selecting stock, prove that its first 40 MiB is still the
# exact secondary stock slot from this device's locally verified full backup.
if [ -z "$(mtd_index ubi1)" ]; then
	MERGED_MTD="$(mtd_index ubi)"
	[ -n "$MERGED_MTD" ] || die "neither stock ubi1 nor merged ubi partition exists"
	[ -n "$EXPECTED_MERGED_UBI1" ] || die "expected stock SHA256 is required for merged NAND layout"
	[ "$(cat /sys/class/mtd/mtd${MERGED_MTD}/offset)" = 76546048 ] || die "merged ubi offset is unexpected"
	[ "$(cat /sys/class/mtd/mtd${MERGED_MTD}/size)" = 426770432 ] || die "merged ubi size is unexpected"
	ACTUAL_MERGED_UBI1="$(dd if=/dev/mtd${MERGED_MTD} bs=262144 count=160 2>/dev/null | sha256sum | awk '{print $1}')"
	[ "$ACTUAL_MERGED_UBI1" = "$EXPECTED_MERGED_UBI1" ] || die "preserved stock ubi1 does not match the verified backup"
	log "CHECK OK: preserved stock ubi1 matches verified backup inside merged NAND layout"
fi

fw_setenv -c "$ENV_CONFIG" tp_boot_idx 1
[ "$(fw_printenv -c "$ENV_CONFIG" -n tp_boot_idx 2>/dev/null)" = 1 ] || die "stock fallback could not be selected"
sync
log "DONE: flash trial verified; stock fallback is armed"
