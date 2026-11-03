#!/usr/bin/env python3
"""v2/tools -- self-check for the hybrid toolchain (isa/asm/model).

Three claims, each unambiguous:

  1. every new opcode round-trips: assemble -> disassemble -> assemble gives
     the same 24-bit word, with the documented field placement
     (LDAS/STAS: rd, rs=register index, imm8[2:0]=assist id; ASST: rs=assist,
     imm8=command);
  2. the model's CRC assist reproduces all five study vectors
     (tb/crc_*.hex, including the zlib.crc32 16-byte stream);
  3. a model program built from LDAS/STAS/ASST reproduces the RTL semantics the
     benches check: FIFO push/pop order, the empty-read nf_flag rule (rd
     unchanged), and the executor's STATUS bits.

Run: v2/tools/selfcheck.py
Exit status 1 on any failure.
"""
from __future__ import annotations

import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import asm                      # noqa: E402
import isa                      # noqa: E402
import model                    # noqa: E402

V2 = HERE.parent
fails: list[str] = []


def check(cond: bool, what: str) -> None:
    if not cond:
        fails.append(what)
        print(f"FAIL {what}")
    else:
        print(f"  ok {what}")


# ---------------------------------------------------------------------------
# 1. opcode round-trip and field placement
# ---------------------------------------------------------------------------
print("== opcode round-trip")
src = """
.engine 0
    STAS r0, r0, CRC
    LDAS r1, r3, FIFO
    ASST NRZI, EOP
    ASST CRC, FLUSH
    HALT
"""
prog = asm.assemble_text(src)["programs"][0]

want = [
    # STAS r0, r0, CRC: op 0x4F, rd 0, rs 0, imm 0
    (0x4F << 17),
    # LDAS r1, r3, FIFO: op 0x4E, rd 1, rs 3, imm 1
    (0x4E << 17) | (1 << 14) | (3 << 11) | (1 << 3),
    # ASST NRZI, EOP: op 0x50, rs 3, imm 5
    (0x50 << 17) | (3 << 11) | (5 << 3),
    # ASST CRC, FLUSH: op 0x50, rs 0, imm 6
    (0x50 << 17) | (6 << 3),
    isa.enc("HALT"),
]
for i, (got, exp) in enumerate(zip(prog, want)):
    check(got == exp, f"word {i} encoding 0x{got:06x} == 0x{exp:06x}")

for word in prog:
    text = isa.disasm(word)
    re_word = asm.assemble_text(".engine 0\n" + text + "\n")["programs"][0][0]
    check(re_word == word, f"disasm re-assembles: {text}")

f = isa.fields(prog[1])
check(f["rd"] == 1 and f["rs"] == 3 and (f["imm"] & 7) == 1,
      "LDAS fields are rd/rs/immediate-with-assist-id")
check(len(isa.OPC) == 75 and 0x4E in isa.OPC and 0x50 in isa.OPC,
      "ISA table has 75 opcodes including 0x4E/0x4F/0x50")


# ---------------------------------------------------------------------------
# 2. model CRC against the five study vectors
# ---------------------------------------------------------------------------
print("== model CRC vs studies/hybrid/tb vectors")


def load(fn: str) -> list[int]:
    return [int(x, 16) for x in (V2 / "tb" / fn).read_text().split()]


init, poly, wsel = load("crc_init.hex"), load("crc_poly.hex"), load("crc_wsel.hex")
xorv, exp = load("crc_xor.hex"), load("crc_exp.hex")
data = load("crc_bytes.hex")


def cfg32(a, page: int, value: int) -> None:
    a.write(3, page)                       # CMD: select the config page
    for k in range(4):
        a.write(4 + k, (value >> (8 * k)) & 0xFF)


for c in range(len(wsel)):
    m = model.ProteusModel()
    a = m.assists[model.ASSIST_CRC]
    a.write(2, wsel[c] & 0xFF)
    cfg32(a, 8, init[c])
    cfg32(a, 9, poly[c])
    cfg32(a, 10, xorv[c])
    a.write(3, 0)                          # page = live CRC
    a.cmd(1)                               # start
    for b in data:
        a.write(0, b)
        for _ in range(8):
            m.step()
    check(a.crc_value() == exp[c],
          f"CRC config {c}: 0x{a.crc_value():08x} == 0x{exp[c]:08x}")


# ---------------------------------------------------------------------------
# 3. model program: FIFO push/pop, empty-read nf rule, executor status
# ---------------------------------------------------------------------------
print("== model program through LDAS/STAS/ASST")
m = model.ProteusModel()
prog = asm.assemble_text("""
.engine 0
    LDI r0, 0xA5
    STAS r0, r0, FIFO
    LDI r0, 0x5A
    STAS r0, r0, FIFO
    LDAS r1, r0, FIFO
    PUSH r1
    LDAS r1, r0, FIFO
    PUSH r1
    LDAS r1, r1, FIFO
    PUSH r1
    LDAS r1, r0, FIFO
    HALT
""")["programs"][0]
m.load(0, prog)
m.start(0)
m.run_until(lambda mm: mm.engines[0].halted, max_cycles=200)

e = m.engines[0]
out = []
while (b := m.pop_out(0)) is not None:
    out.append(b)
check(out == [0xA5, 0x5A, 0x20], f"out FIFO order {[hex(x) for x in out]}")
check(e.nf_flag == 1, "empty LDAS set nf_flag")
check(e.regs[1] == 0x20, "empty LDAS left rd unchanged (0x20)")
check(e.halted == 1 and e.run == 0, "HALT retired RUN")

print()
if fails:
    print(f"SELFCHECK FAIL ({len(fails)} failures)")
    sys.exit(1)
print("SELFCHECK PASS")
