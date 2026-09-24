#!/usr/bin/env python3
"""Emit the static ARMv7 ELF `pbt-batt`.

It reads three parameters from /tmp/pbt-req — u32 address, u32 length, a
NUL-terminated path — then open(path), lseek(address), read(length),
write(stdout), exit. No toolchain: hand-encoded A32 + a hand-built ELF32
header, exactly as the spike's mkelf_mem.py proved on the device. The only
change from that spike is the request-file prologue: parameters are read at
run time so one shipped binary serves any pid and any load address.

The kernel preserves r4-r11 across the SVC (only r0 is the return), so the
address (r4), length (r5) and path pointer (r9) survive the open/lseek calls.

Usage: make_pbt_batt.py OUT
"""
import struct
import sys

BASE = 0x10000
EHSIZE, PHSIZE = 52, 32
CODE_OFF = EHSIZE + PHSIZE
ENTRY = BASE + CODE_OFF
REQBUF = BASE + 0x1000          # bss: the request file is read here
DATABUF = BASE + 0x2000         # bss: the memory window is read here


# Data-processing immediate: bit25 (0x02000000) marks the immediate form — the
# bug that produced SIGILL in the spike when it was dropped. Callers pass small
# values (< 256) so the imm8 is literal; larger constants go through movw/movt.
def mov_imm(rd, imm12): return 0xE3A00000 | (rd << 12) | (imm12 & 0xFFF)
def add_imm(rd, rn, imm12): return 0xE2800000 | (rn << 16) | (rd << 12) | (imm12 & 0xFFF)
def mov_reg(rd, rm): return (0xE << 28) | (0x1A << 20) | (rd << 12) | rm
def movw(rd, imm16): return 0xE3000000 | ((imm16 >> 12) << 16) | (rd << 12) | (imm16 & 0xFFF)
def movt(rd, imm16): return 0xE3400000 | ((imm16 >> 12) << 16) | (rd << 12) | (imm16 & 0xFFF)
def ldr_imm(rt, rn, off12): return 0xE5900000 | (rn << 16) | (rt << 12) | (off12 & 0xFFF)
def svc(): return 0xEF000000


def load32(rd, value):
    return [movw(rd, value & 0xFFFF), movt(rd, (value >> 16) & 0xFFFF)]


def main():
    out = sys.argv[1]
    req_path = b"/tmp/pbt-req\0"
    insns = []

    # open("/tmp/pbt-req", O_RDONLY) — path address patched after layout.
    open_req_index = len(insns)
    insns.append(None)                       # add r0, pc, #(reqpath - pc)
    insns.append(mov_imm(1, 0))              # O_RDONLY
    insns.append(mov_imm(7, 5))              # __NR_open
    insns.append(svc())
    insns.append(mov_reg(6, 0))              # r6 = req fd

    # read(req_fd, REQBUF, 256)
    insns.append(mov_reg(0, 6))
    insns += load32(1, REQBUF)
    insns.append(movw(2, 0x100))             # 256 (not a valid mov imm8)
    insns.append(mov_imm(7, 3))              # __NR_read
    insns.append(svc())

    # r4 = address = [REQBUF]; r5 = length = [REQBUF+4]; r9 = &path = REQBUF+8
    insns += load32(3, REQBUF)
    insns.append(ldr_imm(4, 3, 0))           # r4 = address
    insns.append(ldr_imm(5, 3, 4))           # r5 = length
    insns.append(add_imm(9, 3, 8))           # r9 = path pointer

    # open(path, O_RDONLY)
    insns.append(mov_reg(0, 9))
    insns.append(mov_imm(1, 0))
    insns.append(mov_imm(7, 5))              # __NR_open
    insns.append(svc())
    insns.append(mov_reg(6, 0))              # r6 = mem fd

    # lseek(mem_fd, address, SEEK_SET)
    insns.append(mov_reg(0, 6))
    insns.append(mov_reg(1, 4))              # offset = address
    insns.append(mov_imm(2, 0))              # SEEK_SET
    insns.append(mov_imm(7, 19))             # __NR_lseek
    insns.append(svc())

    # read(mem_fd, DATABUF, length)
    insns.append(mov_reg(0, 6))
    insns += load32(1, DATABUF)
    insns.append(mov_reg(2, 5))              # count = length
    insns.append(mov_imm(7, 3))              # __NR_read
    insns.append(svc())

    # write(1, DATABUF, r0)  — r0 is the byte count just read
    insns.append(mov_reg(2, 0))
    insns.append(mov_imm(0, 1))              # stdout
    insns += load32(1, DATABUF)
    insns.append(mov_imm(7, 4))              # __NR_write
    insns.append(svc())

    # exit(0)
    insns.append(mov_imm(0, 0))
    insns.append(mov_imm(7, 1))              # __NR_exit
    insns.append(svc())

    n = len(insns)
    reqpath_off = n * 4                       # request-file path sits after code
    # Patch the adr: add r0, pc, #(reqpath - (open_req_index*4 + 8)); pc reads
    # ahead by 8. The offset must stay a valid ARM imm8 (< 256) — it is, at ~41
    # instructions.
    adr_pc = open_req_index * 4 + 8
    imm = reqpath_off - adr_pc
    assert 0 <= imm < 256, f"adr offset {imm} not a valid imm8; code grew"
    insns[open_req_index] = add_imm(0, 15, imm)

    code = b"".join(struct.pack("<I", w) for w in insns) + req_path
    filesz = CODE_OFF + len(code)
    memsz = 0x3000                            # code + two bss scratch pages

    ehdr = struct.pack(
        "<16sHHIIIIIHHHHHH",
        b"\x7fELF\x01\x01\x01\x00" + b"\x00" * 8,
        2, 40, 1, ENTRY, EHSIZE, 0, 0x5000400, EHSIZE, PHSIZE, 1, 0, 0, 0,
    )
    phdr = struct.pack("<IIIIIIII", 1, 0, BASE, BASE, filesz, memsz, 7, 0x1000)
    with open(out, "wb") as f:
        f.write(ehdr + phdr + code)
    print(f"wrote {out}: {filesz}B")


if __name__ == "__main__":
    main()
