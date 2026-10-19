#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs on OpenWrt. Verifies the preserved stock slot (ubi1), then selects it.
# Usage: openwrt-return-stock.sh [--check]

set -e
. /lib/functions.sh

log() { echo "[ex520v] $*"; }
die() { log "ERROR: $*"; exit 1; }
mtd_index() { grep "\"$1\"" /proc/mtd | cut -d: -f1 | sed 's/^mtd//'; }

CHECK_ONLY=0
EXPECTED_MERGED_UBI1=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--check) CHECK_ONLY=1 ;;
		--expected-merged-ubi1)
			shift
			[ "$#" -gt 0 ] || die "missing expected stock SHA256"
			EXPECTED_MERGED_UBI1="$1"
			echo "$EXPECTED_MERGED_UBI1" | grep -Eq '^[0-9a-f]{64}$' || die "invalid expected stock SHA256"
			;;
		*) die "unexpected argument" ;;
	esac
	shift
done

[ "$(board_name)" = "tplink,ex520v" ] || die "not a TP-Link EX520v"
for p in boot u-boot-env misc_ro misc_rw ubi0; do
	[ -n "$(mtd_index "$p")" ] || die "MTD $p missing, unexpected flash layout"
done
if [ -n "$(mtd_index ubi1)" ]; then
	for p in bflag container; do
		[ -n "$(mtd_index "$p")" ] || die "MTD $p missing, unexpected classic flash layout"
	done
else
	[ -n "$(mtd_index ubi)" ] || die "neither stock ubi1 nor merged ubi partition exists"
fi

ENV_MTD=$(mtd_index u-boot-env)
[ -n "$ENV_MTD" ] || die "MTD u-boot-env missing"
ENV_CONFIG=/tmp/ex520v-fw-env.config
printf '/dev/mtd%s 0x0 0x20000 0x20000 1\n' "$ENV_MTD" > "$ENV_CONFIG"
fw_printenv -c "$ENV_CONFIG" >/dev/null 2>&1 || die "boot environment CRC cannot be verified"
MTD=$(mtd_index ubi1)
if [ -n "$MTD" ]; then
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
		for volume in /sys/class/ubi/ubi${UBIDEV}_*; do
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
	log "CHECK OK: stock slot ubi1 contains uboot/kernel/rootfs"
else
	MERGED_MTD=$(mtd_index ubi)
	[ -n "$MERGED_MTD" ] || die "neither stock ubi1 nor merged ubi partition exists"
	[ -n "$EXPECTED_MERGED_UBI1" ] || die "expected stock SHA256 is required for merged NAND layout"
	[ "$(cat /sys/class/mtd/mtd${MERGED_MTD}/offset)" = 76546048 ] || die "merged ubi offset is unexpected"
	[ "$(cat /sys/class/mtd/mtd${MERGED_MTD}/size)" = 426770432 ] || die "merged ubi size is unexpected"
	ACTUAL_MERGED_UBI1="$(dd if=/dev/mtd${MERGED_MTD} bs=262144 count=160 2>/dev/null | sha256sum | awk '{print $1}')"
	[ "$ACTUAL_MERGED_UBI1" = "$EXPECTED_MERGED_UBI1" ] || die "preserved stock ubi1 does not match the verified backup"
	log "CHECK OK: preserved stock ubi1 matches verified backup inside merged NAND layout"
fi

if [ "$CHECK_ONLY" = 1 ]; then
	log "CHECK OK: nothing written"
	exit 0
fi

# Failure between these commands keeps OpenWrt selected; only the verified
# tp_boot_idx=1 value selects stock on the next boot.
fw_setenv -c "$ENV_CONFIG" ex520v_trial
fw_setenv -c "$ENV_CONFIG" tp_boot_idx 1
[ "$(fw_printenv -c "$ENV_CONFIG" -n tp_boot_idx 2>/dev/null)" = "1" ] || die "tp_boot_idx could not be set to 1"
fw_printenv -c "$ENV_CONFIG" -n ex520v_trial >/dev/null 2>&1 && die "ex520v_trial is still set"

log "DONE: stock slot ubi1 selected for the next boot"
