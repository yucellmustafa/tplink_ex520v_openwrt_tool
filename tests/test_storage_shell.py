"""Exercise the shipped erase wrapper in a disposable, mocked filesystem.

No device/network access. Every sysupgrade invocation resolves to a test stub.
Run with: py -3 -m unittest discover -s tests -p 'test_*.py' -v
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GIT_BASH = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
BASH = str(GIT_BASH) if GIT_BASH.exists() else shutil.which("bash")


@unittest.skipUnless(BASH, "bash is required for shell integration tests")
class ExpansionShellTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ex520v-storage-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root.as_posix()
        self.parts = [
            ("boot", 0, 2097152), ("u-boot-env", 2097152, 1048576),
            ("misc_ro", 3145728, 15728640), ("misc_rw", 18874368, 15728640),
            ("ubi0", 34603008, 41943040), ("ubi", 76546048, 426770432),
        ]
        for i, (name, offset, size) in enumerate(self.parts):
            d = self.root / f"sys/class/mtd/mtd{i}"
            d.mkdir(parents=True)
            for key, value in {"name": name, "offset": offset, "size": size, "erasesize": 262144}.items():
                (d / key).write_text(str(value), encoding="ascii")
        self.ubi = self.root / "sys/class/ubi/ubi0"
        self.ubi.mkdir(parents=True)
        (self.ubi / "mtd_num").write_text("4", encoding="ascii")
        for volume_id, name in enumerate(('uboot', 'kernel', 'rootfs', 'rootfs_data')):
            vol = self.ubi / f'ubi0_{volume_id}'
            vol.mkdir()
            (vol / 'name').write_text(name, encoding='ascii')
            (vol / 'data_bytes').write_text('662376', encoding='ascii')
            (vol / 'type').write_text('static' if volume_id == 0 else 'dynamic', encoding='ascii')
            sibling = self.root / f'sys/class/ubi/ubi0_{volume_id}'
            sibling.mkdir()
            (sibling / 'name').write_text(name, encoding='ascii')
        (self.root / "proc").mkdir()
        (self.root / 'proc/cmdline').write_text('ubi.mtd=ubi0 console=ttyS0', encoding='ascii')
        (self.root / "proc/mounts").write_text('/dev/root /rom squashfs ro 0 0\n/dev/ubi0_3 /overlay ubifs rw 0 0\noverlayfs:/overlay / overlay rw 0 0\n', encoding="ascii")
        (self.root / "tmp").mkdir()
        self.image = self.root / "image.bin"
        self.image.write_bytes(b"mock image; hash command is stubbed")
        (self.root / "bin").mkdir()
        stub = self.root / "bin/sysupgrade"
        stub.write_text("#!/bin/sh\necho \"sysupgrade:$*\" >> \"$TRACE\"\nexit 0\n", encoding="ascii", newline="\n")
        stub.chmod(0o700)
        formatter = self.root / 'bin/ubiformat'
        formatter.write_text('#!/bin/sh\necho "format:$*" >> "$TRACE"\nexit 0\n', encoding='ascii', newline='\n')
        formatter.chmod(0o700)
        self.trace = self.root / "trace"
        self.env = dict(os.environ, TRACE=str(self.trace), TEST_ROOT=self.prefix)
        self.script = self.root / "expand.sh"
        source = (ROOT / "install/openwrt-expand-storage.sh").read_text(encoding="utf-8")
        mocks = r'''
board_name() { echo tplink,ex520v; }
id() { echo 0; }
fw_printenv() {
    [ "${ENV_FAIL:-0}" = 0 ] || return 1
    [ "${ENV_WARNING:-0}" = 0 ] || echo 'Warning: Bad CRC, using default environment' >&2
    case "$*" in *ex520v_trial*) [ "${ARMED:-0}" = 0 ] || echo 1 ;; esac
    return 0
}
sha256sum() {
    if [ "$#" = 1 ]; then
        echo "3f066005e89afc8fae214e874ea3b4e40d9ad0639daff494b4ff258f7a1bbe0b  $1"
    else
        cat >/dev/null
        [ "${HASH_FAIL:-0}" = 0 ]
    fi
}
export PATH="$(cd "$TEST_ROOT/bin" && pwd):$PATH"
'''
        source = source.replace(". /lib/functions.sh", mocks)
        for path in ("/sys/", "/proc/", "/tmp/"):
            source = source.replace(path, self.prefix + path)
        self.script.write_text(source, encoding="ascii", newline="\n")

    def run_script(self, mode="--check"):
        return subprocess.run([BASH, self.script.as_posix(), self.image.as_posix(), mode],
                              env=self.env, capture_output=True, text=True, timeout=15)

    def assert_no_write(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.trace.exists(), "refused preflight must not even invoke sysupgrade")

    def test_check_never_flashes(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CHECK OK:", result.stdout)
        self.assertEqual(self.trace.read_text().strip(), f"sysupgrade:-T {self.image.as_posix()}")

    def test_explicit_erase_invokes_only_reviewed_sysupgrade(self):
        result = self.run_script("--erase-stock-407m")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("STARTING:", result.stdout)
        self.assertIn(f"sysupgrade:-c {self.image.as_posix()}", self.trace.read_text())
        self.assertIn('format:/dev/mtd5 -y', self.trace.read_text())

    def test_bootstrap_preserves_stock_and_uses_sysupgrade_config_save(self):
        entries = [('ubi1',76546048,41943040),('bflag',118489088,15728640),('misc_rw_bak',134217728,15728640),('misc_isp',149946368,15728640),('runtime_data',165675008,15728640),('container',181403648,209715200)]
        for i,(name,offset,size) in enumerate(entries,5):
            d=self.root / f'sys/class/mtd/mtd{i}'
            d.mkdir(exist_ok=True)
            for key,value in {'name':name,'offset':offset,'size':size,'erasesize':262144}.items():
                (d/key).write_text(str(value),encoding='ascii')
        result=self.run_script('--erase-stock-407m')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('stage=bootstrap',result.stdout)
        self.assertNotIn('format:',self.trace.read_text())
        self.assertIn('sysupgrade:-c ',self.trace.read_text())

    def test_wrong_size_refuses_before_sysupgrade(self):
        (self.root / "sys/class/mtd/mtd5/size").write_text("41943040", encoding="ascii")
        self.assert_no_write(self.run_script("--erase-stock-407m"))

    def test_flash_tmpfs_overlay_is_not_initramfs(self):
        (self.root / "proc/mounts").write_text(
            "/dev/root /rom squashfs ro 0 0\noverlayfs:/tmp/root / overlay rw 0 0\n", encoding="ascii")
        self.assert_no_write(self.run_script("--erase-stock-407m"))

    def test_missing_second_stage_bootloader_refuses(self):
        (self.ubi / "ubi0_0/name").write_text("kernel", encoding="ascii")
        self.assert_no_write(self.run_script("--erase-stock-407m"))

    def test_unreviewed_upgrader_refuses(self):
        self.env["HASH_FAIL"] = "1"
        self.assert_no_write(self.run_script("--erase-stock-407m"))

    def test_unreadable_environment_refuses(self):
        self.env["ENV_FAIL"] = "1"
        self.assert_no_write(self.run_script("--erase-stock-407m"))

    def test_armed_fallback_refuses(self):
        self.env["ARMED"] = "1"
        self.assert_no_write(self.run_script("--erase-stock-407m"))

    def test_crc_warning_with_zero_exit_code_refuses(self):
        self.env["ENV_WARNING"] = "1"
        self.assert_no_write(self.run_script("--erase-stock-407m"))

    def test_unknown_mode_refuses(self):
        self.assert_no_write(self.run_script("--execute"))


if __name__ == "__main__":
    unittest.main()
