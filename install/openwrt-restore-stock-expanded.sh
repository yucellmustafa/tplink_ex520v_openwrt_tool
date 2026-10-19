#!/bin/sh
# Restore both stock slots and the stock-only region after the 407 MiB expansion.
# The write stage runs after OpenWrt's normal stage2 pivot has detached rootfs.
set -e
. /lib/functions.sh
set -u

die() { echo "[ex520v] ERROR: $*" >&2; exit 1; }
log() { echo "[ex520v] $*"; }

BUNDLE="${1:-}"
EXPECTED_BUNDLE_SHA="${2:-}"
MODE="${3:---check}"
VALIDATOR_IMAGE="${4:-}"
[ "$MODE" = --check ] || [ "$MODE" = --execute ] || [ "$MODE" = --stage2 ] || die 'invalid mode'
[ -f "$BUNDLE" ] || die 'stock restore bundle missing'
echo "$EXPECTED_BUNDLE_SHA" | grep -Eq '^[0-9a-f]{64}$' || die 'invalid bundle SHA256'
[ "$(busybox sha256sum "$BUNDLE" | cut -d' ' -f1)" = "$EXPECTED_BUNDLE_SHA" ] || die 'stock restore bundle SHA256 mismatch'

check_layout() {
    if [ "$MODE" = --stage2 ]; then
        # stage2 intentionally copies only a minimal userspace. The trusted
        # sysinfo file survives the /tmp move; board_name/id binaries do not.
        [ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = tplink,ex520v ] || die 'wrong board in RAM stage'
    else
        [ "$(id -u)" = 0 ] || die 'UID 0 required'
        [ "$(board_name)" = tplink,ex520v ] || die 'wrong board'
    fi
    check_part() {
        local name="$1" offset="$2" size="$3" d found=0
        for d in /sys/class/mtd/mtd[0-9]*; do
            [ -f "$d/name" ] || continue
            [ "$(cat "$d/name")" = "$name" ] || continue
            found=$((found + 1))
            [ "$(cat "$d/offset")" = "$offset" ] || die "wrong $name offset"
            [ "$(cat "$d/size")" = "$size" ] || die "wrong $name size"
            [ "$(cat "$d/erasesize")" = 262144 ] || die "wrong $name erase size"
            [ "$name" != ubi ] || DATA_MTD="${d##*mtd}"
        done
        [ "$found" = 1 ] || die "partition $name missing or duplicated"
    }
    count=0
    for d in /sys/class/mtd/mtd[0-9]*; do [ ! -f "$d/name" ] || count=$((count + 1)); done
    [ "$count" = 6 ] || die 'expanded six-partition layout required'
    check_part boot 0 2097152
    check_part u-boot-env 2097152 1048576
    check_part misc_ro 3145728 15728640
    check_part misc_rw 18874368 15728640
    check_part ubi0 34603008 41943040
    check_part ubi 76546048 426770432
    BOOT_MTD=4
    [ "$(cat "/sys/class/mtd/mtd$BOOT_MTD/bad_blocks" 2>/dev/null)" = 0 ] || die 'primary slot MTD has bad blocks; automatic raw restore refused'
    [ "$(cat "/sys/class/mtd/mtd$DATA_MTD/bad_blocks" 2>/dev/null)" = 0 ] || die 'data MTD has bad blocks; automatic raw restore refused'
}

extract_manifest() {
    busybox tar -xOzf "$BUNDLE" SHA256SUMS | busybox tr -d '\r' > /tmp/ex520v-stock-restore.sha256
}

expected_hash() {
    awk -v name="$1" '$2 == name { print $1 }' /tmp/ex520v-stock-restore.sha256
}

check_member() {
    local name="$1" size="$2" hash count actual
    hash="$(expected_hash "$name")"
    echo "$hash" | grep -Eq '^[0-9a-f]{64}$' || die "manifest hash missing: $name"
    count="$(busybox tar -xOzf "$BUNDLE" "$name" | busybox wc -c)"
    [ "$count" = "$size" ] || die "wrong backup size: $name"
    actual="$(busybox tar -xOzf "$BUNDLE" "$name" | busybox sha256sum | cut -d' ' -f1)"
    [ "$actual" = "$hash" ] || die "backup hash mismatch: $name"
}

check_bundle() {
    local listing expected
    listing="$(busybox tar -tzf "$BUNDLE" | sort)"
    expected="$(printf '%s\n' SHA256SUMS mtd10-runtime_data.bin mtd11-container.bin mtd5-ubi0.bin mtd6-ubi1.bin mtd7-bflag.bin mtd8-misc_rw_bak.bin mtd9-misc_isp.bin | sort)"
    [ "$listing" = "$expected" ] || die 'stock restore bundle has missing or unexpected members'
    extract_manifest
    check_member mtd5-ubi0.bin 41943040
    check_member mtd6-ubi1.bin 41943040
    check_member mtd7-bflag.bin 15728640
    check_member mtd8-misc_rw_bak.bin 15728640
    check_member mtd9-misc_isp.bin 15728640
    check_member mtd10-runtime_data.bin 15728640
    check_member mtd11-container.bin 209715200
}

check_tools() {
    echo 'c494d3cc230b30da3f5b44f6d5d97f2e05d5a4abb87259111375df69fb2c668c  /lib/upgrade/stage2' | busybox sha256sum -c - >/dev/null || die 'unreviewed stage2'
    echo '07973c5ca3b903b2b48c69d41cc2c5bddb6897aab5deb341fb60975c2f20a701  /sbin/upgraded' | busybox sha256sum -c - >/dev/null || die 'unreviewed upgraded helper'
    echo '07dc73528a4520cd845c30b8e61443547425f40c475e9ceafc1e05f7b043fae9  /sbin/mtd' | busybox sha256sum -c - >/dev/null || die 'unreviewed mtd utility'
}

check_layout
check_bundle
check_tools
log 'CHECK OK: expanded layout and same-device stock bundle verified'
[ "$MODE" != --check ] || exit 0

if [ "$MODE" = --execute ]; then
    [ -f "$VALIDATOR_IMAGE" ] || die 'verified sysupgrade validator image missing'
    [ "$(busybox sha256sum "$VALIDATOR_IMAGE" | cut -d' ' -f1)" = '3f066005e89afc8fae214e874ea3b4e40d9ad0639daff494b4ff258f7a1bbe0b' ] || die 'sysupgrade validator image SHA256 mismatch'
    . /lib/upgrade/common.sh
    # install_bin may return 1 when every target already exists in RAM_ROOT.
    # That is harmless and is common after a repeated/preflight invocation.
    install_bin /sbin/upgraded || true
    install_file /lib/upgrade/stage2 || true
    [ -x /tmp/root/sbin/upgraded ] || die 'upgraded helper was not copied to RAM'
    [ -f /tmp/root/lib/upgrade/stage2 ] || die 'reviewed stage2 was not copied to RAM'
    log 'STARTING: stock restore RAM pivot; SSH disconnect and reboot verification required'
    command="/bin/busybox sh /tmp/ex520v-stock-restore.sh /tmp/ex520v-stock-restore.tar.gz $EXPECTED_BUNDLE_SHA --stage2"
    exec ubus call system sysupgrade "{\"prefix\":\"/tmp/root\",\"path\":\"$VALIDATOR_IMAGE\",\"command\":\"$command\",\"options\":{\"save_partitions\":0,\"add_provisioning\":0}}"
fi

# From this point the normal OpenWrt stage2 process has pivoted to tmpfs,
# stopped services and unmounted the large overlay.
[ -z "$(awk '$2=="/overlay"{print $2}' /proc/mounts)" ] || die 'overlay is still mounted in stage2'
for u in /sys/class/ubi/ubi[0-9]*; do
    [ -f "$u/mtd_num" ] || continue
    [ "$(cat "$u/mtd_num")" = "$DATA_MTD" ] || continue
    ubidetach -m "$DATA_MTD" || die 'expanded data UBI cannot be detached'
done
for u in /sys/class/ubi/ubi[0-9]*; do
    [ -f "$u/mtd_num" ] || continue
    [ "$(cat "$u/mtd_num")" = "$BOOT_MTD" ] || continue
    ubidetach -m "$BOOT_MTD" || die 'primary slot UBI cannot be detached'
done

ensure_mtd_node() {
    local index="$1" node="/dev/mtd$1" dev major minor
    dev="$(cat "/sys/class/mtd/mtd$index/dev" 2>/dev/null)"
    echo "$dev" | grep -Eq '^[0-9]+:[0-9]+$' || die "mtd$index device number missing"
    major="${dev%:*}"
    minor="${dev#*:}"
    if [ ! -c "$node" ]; then
        rm -f "$node"
        mknod "$node" c "$major" "$minor" || die "mtd$index RAM device node cannot be created"
    fi
    chmod 600 "$node"
    [ -c "$node" ] || die "mtd$index RAM device node missing"
}
ensure_mtd_node "$DATA_MTD"
ensure_mtd_node "$BOOT_MTD"

write_member() {
    local name="$1" size="$2" offset="$3" hash actual
    hash="$(expected_hash "$name")"
    log "WRITING: $name at offset $offset"
    set -o pipefail
    busybox tar -xOzf "$BUNDLE" "$name" | mtd -q -f -p "$offset" write - "/dev/mtd$DATA_MTD" || die "write failed: $name"
    set +o pipefail
    actual="$(busybox dd if="/dev/mtd$DATA_MTD" bs=1048576 skip=$((offset / 1048576)) count=$((size / 1048576)) 2>/dev/null | busybox sha256sum | cut -d' ' -f1)"
    [ "$actual" = "$hash" ] || die "read-back mismatch: $name"
    log "VERIFIED: $name"
}

# Write the stock-only data and secondary slot before touching the primary slot.
write_member mtd7-bflag.bin 15728640 41943040
write_member mtd8-misc_rw_bak.bin 15728640 57671680
write_member mtd9-misc_isp.bin 15728640 73400320
write_member mtd10-runtime_data.bin 15728640 89128960
write_member mtd11-container.bin 209715200 104857600
write_member mtd6-ubi1.bin 41943040 0

# Restore the primary stock slot only after every secondary region has passed
# read-back. This is the final flash write and makes the default boot stock.
log 'WRITING: mtd5-ubi0.bin to primary slot'
set -o pipefail
busybox tar -xOzf "$BUNDLE" mtd5-ubi0.bin | mtd -q -f write - "/dev/mtd$BOOT_MTD" || die 'write failed: mtd5-ubi0.bin'
set +o pipefail
primary_hash="$(expected_hash mtd5-ubi0.bin)"
actual="$(busybox dd if="/dev/mtd$BOOT_MTD" bs=1048576 count=40 2>/dev/null | busybox sha256sum | cut -d' ' -f1)"
[ "$actual" = "$primary_hash" ] || die 'read-back mismatch: mtd5-ubi0.bin'
log 'VERIFIED: mtd5-ubi0.bin'

ENV_CONFIG=/tmp/ex520v-stock-fw-env.config
printf '/dev/mtd1 0x0 0x20000 0x20000 1\n' > "$ENV_CONFIG"
fw_setenv -c "$ENV_CONFIG" ex520v_trial
fw_setenv -c "$ENV_CONFIG" tp_boot_idx
[ -z "$(fw_printenv -c "$ENV_CONFIG" -n tp_boot_idx 2>/dev/null || true)" ] || die 'primary stock boot index was not selected'
[ -z "$(fw_printenv -c "$ENV_CONFIG" -n ex520v_trial 2>/dev/null || true)" ] || die 'trial marker is still armed'
sync
log 'DONE: both stock slots and data restored; rebooting to primary stock ubi0'
reboot -f
sleep 5
echo b > /proc/sysrq-trigger
