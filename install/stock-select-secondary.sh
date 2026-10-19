#!/bin/sh
# Select the verified secondary stock slot before ubi0 is reused for OpenWrt.
# This script never writes an MTD/UBI volume; --execute changes only U-Boot env.
set -e

MODE="${1:---check}"
EXPECTED_CRC="${2:-}"

log() { echo "[ex520v] $*"; }
die() { log "ERROR: $*"; exit 1; }
mtd_index() { grep "\"$1\"" /proc/mtd | cut -d: -f1 | sed 's/^mtd//'; }

[ "$MODE" = --check ] || [ "$MODE" = --execute ] || die "invalid mode"
echo "$EXPECTED_CRC" | grep -Eq '^0x[0-9a-f]{8}$' || die "invalid expected ubi1 CRC"
[ "$(cat /proc/sys/kernel/hostname)" = "EX520v" ] || die "this does not look like a TP-Link EX520v"
grep -Eq '(^| )ubi\.mtd=ubi0( |$)' /proc/cmdline || die "stock is not running from primary ubi0"

BOOT_IDX="$(fw_printenv -n tp_boot_idx 2>/dev/null || true)"
[ -z "$BOOT_IDX" ] || [ "$BOOT_IDX" = 0 ] || die "unexpected tp_boot_idx"

MTD="$(mtd_index ubi1)"
[ -n "$MTD" ] || die "MTD ubi1 not found"
[ "$(cat /sys/class/mtd/mtd$MTD/size)" = 41943040 ] || die "unexpected ubi1 size"
for n in /sys/class/ubi/ubi*/mtd_num; do
	[ -e "$n" ] || continue
	[ "$(cat "$n")" != "$MTD" ] || die "inactive ubi1 is unexpectedly attached"
done
[ "$(ubicrc32 /dev/mtd$MTD)" = "$EXPECTED_CRC" ] || die "inactive ubi1 differs from the verified stock backup"

if [ "$MODE" = --check ]; then
	log "CHECK OK: inactive stock ubi1 matches the verified backup; no flash or environment write performed"
	exit 0
fi

# Clearing a stale trial marker first is fail-safe: if the second write fails,
# the device remains on the currently running primary stock slot.
fw_setenv ex520v_trial
fw_setenv tp_boot_idx 1
[ "$(fw_printenv -n tp_boot_idx 2>/dev/null)" = 1 ] || die "tp_boot_idx was not set to 1"
[ -z "$(fw_printenv -n ex520v_trial 2>/dev/null || true)" ] || die "stale trial marker remains"
log "DONE: verified secondary stock slot selected; reboot required"
