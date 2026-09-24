#!/usr/bin/env python3
# Run: python3 Scripts/tests/test_make_pbt_batt.py
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GEN = ROOT / "Scripts" / "make_pbt_batt.py"


class MakePbtBatt(unittest.TestCase):
    def _build(self):
        with tempfile.NamedTemporaryFile(suffix=".elf", delete=False) as f:
            out = Path(f.name)
        subprocess.run([sys.executable, str(GEN), str(out)], check=True)
        return out.read_bytes()

    def test_elf32_arm_header(self):
        elf = self._build()
        self.assertEqual(elf[:4], b"\x7fELF")          # magic
        self.assertEqual(elf[4], 1)                     # ELFCLASS32
        self.assertEqual(elf[5], 1)                     # little-endian
        e_type, e_machine = struct.unpack_from("<HH", elf, 16)
        self.assertEqual(e_type, 2)                     # ET_EXEC
        self.assertEqual(e_machine, 40)                 # EM_ARM

    def test_opens_the_request_file_path(self):
        elf = self._build()
        self.assertIn(b"/tmp/pbt-req\x00", elf)

    def test_syscall_immediates_present(self):
        # __NR_open(5), lseek(19), read(3), write(4), exit(1) loaded into r7.
        elf = self._build()
        for nr in (5, 19, 3, 4, 1):
            insn = struct.pack("<I", 0xE3A07000 | nr)   # mov r7, #nr
            self.assertIn(insn, elf, f"missing mov r7,#{nr}")

    def test_committed_bytes_match_generator(self):
        # The shipped artifact must be exactly what the generator emits, so a
        # stale prebuilt binary is caught in CI.
        shipped = (ROOT / "Sources/PixbarKit/Resources/pbt-batt").read_bytes()
        self.assertEqual(shipped, self._build())


if __name__ == "__main__":
    unittest.main()
