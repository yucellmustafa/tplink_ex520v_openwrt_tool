#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs on OpenWrt. Verifies the preserved stock slot (ubi1), then selects it.
# Usage: openwrt-return-stock.sh [--check]

set -e
. /lib/functions.sh

log() { echo "[ex520v] $*"; }
die() { log "ERROR: $*"; exit 1; }
mtd_index() { grep "\"$1\"" /proc/mtd | cut -d: -f1 | sed 's/^mtd//'; }

[ "$(board_name)" = "tplink,ex520v" ] || die "not a TP-Link EX520v"
for p in boot u-boot-env misc_ro misc_rw ubi0 ubi1 bflag container; do
	[ -n "$(mtd_index "$p")" ] || die "MTD $p missing, unexpected flash layout"
done

MTD=$(mtd_index ubi1)
[ -n "$MTD" ] || die "MTD ubi1 missing"
UBIDEV=""
ATTACHED=0
for u in /sys/class/ubi/ubi[0-9]*; do
	[ -e "$u/mtd_num" ] || continue
	if [ "$(cat "$u/mtd_num")" = "$MTD" ]; then
		UBIDEV=$(basename "$u" | sed 's/^ubi//')
		break
	fi
done

if [ -z "$UBIDEV" ]; then
	ubiattach -m "$MTD" >/dev/null 2>&1 || die "stock slot ubi1 cannot be attached"
	ATTACHED=1
	for u in /sys/class/ubi/ubi[0-9]*; do
		[ -e "$u/mtd_num" ] || continue
		[ "$(cat "$u/mtd_num")" = "$MTD" ] && UBIDEV=$(basename "$u" | sed 's/^ubi//')
	done
fi
[ -n "$UBIDEV" ] || die "stock slot UBI device not found"
trap '[ "$ATTACHED" = 1 ] && ubidetach -d "$UBIDEV" 2>/dev/null || true' EXIT

for expected in uboot kernel rootfs; do
	found=0
	for volume in /sys/class/ubi/ubi${UBIDEV}/ubi${UBIDEV}_*; do
		[ -e "$volume/name" ] || continue
		if [ "$(cat "$volume/name")" = "$expected" ] &&
		   [ "$(cat "$volume/data_bytes")" -gt 0 ]; then
			found=1
			break
		fi
	done
	[ "$found" = 1 ] || die "stock slot volume $expected missing or empty"
done

if [ "$ATTACHED" = 1 ]; then
	ubidetach -d "$UBIDEV"
	ATTACHED=0
fi
trap - EXIT

if [ "$1" = "--check" ]; then
	log "CHECK OK: stock slot ubi1 contains uboot/kernel/rootfs; nothing written"
	exit 0
fi

# Failure between these commands keeps OpenWrt selected; only the verified
# tp_boot_idx=1 value selects stock on the next boot.
fw_setenv ex520v_trial
fw_setenv tp_boot_idx 1
[ "$(fw_printenv -n tp_boot_idx 2>/dev/null)" = "1" ] || die "tp_boot_idx could not be set to 1"
fw_printenv -n ex520v_trial >/dev/null 2>&1 && die "ex520v_trial is still set"

log "DONE: stock slot ubi1 selected for the next boot"
