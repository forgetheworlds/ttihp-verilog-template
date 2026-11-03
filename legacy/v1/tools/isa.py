"""PROTEUS ISA v2 -- single source of truth for opcodes, encoding, decoding.

Instruction word: 24 bits, uniform layout (revision 2: 7-bit opcode field)

    [23:17] op   7 bits
    [16:14] rd   3 bits
    [13:11] rs   3 bits
    [10:3]  imm8 8 bits
    [2:0]   ss   3 bits  side-set value (driven every instruction)

Field interpretation depends on the opcode class (see docs/isa.md).

DECISIONS (documented, encoding frozen by the orchestrator ruling)
------------------------------------------------------------------
  * The opcode field is 7 bits so the system group 0x40..0x4D is encodable.
    All opcode NUMBERS are unchanged from the first table; only the field
    positions moved (op [23:17], rd [16:14], rs [13:11], imm [10:3], ss [2:0]).
  * The ss field is 3 bits: values 0..7.  Side-set width is 1..3 pins
    (CFG field 0: [7]=en, [6:5]=bank, [4:2]=base, [1:0]=width-1 clamped to 3).
  * ``CAPTURE`` takes an 8-bit *tag* in imm (format ``tag``); rd/rs unused.
  * ``WAITP`` packs bank in rs[1:0] and level in rs[2]; mask lives in imm.
  * ``WAITC`` packs the 11-bit cycle count as rs[2:0]:imm[7:0].
  * Jump conditions live in rd; the target is imm[4:0] (PROG_DEPTH = 32).
  * PROG_DEPTH = 32 (default build parameter; the RTL keeps it a parameter).

Python-side only conveniences (no encoding effect):
  * ``enc()`` validates ranges instead of silently masking.
  * ``disasm()`` renders every format: cfg field names, banks, levels, tags.
  * ``OPERANDS`` publishes each format's operand signature so the assembler
    and docs/isa.md cannot drift apart.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PROG_DEPTH = 32          # instructions per engine (5-bit PC, default build)
MAX_PROG_DEPTH = 64      # largest supported parameterisation

# ---------------------------------------------------------------------------
# Register names
# ---------------------------------------------------------------------------
V = list(range(8))

# ---------------------------------------------------------------------------
# Opcode table: name -> (code, fmt)
# fmt is one of: imm, reg, pin, waitp, jmp, djmp, waitc, cfg, irq, bar, tag,
#                unary, none
# ---------------------------------------------------------------------------
OPS: dict[str, tuple[int, str]] = {}
OPC: dict[int, tuple[str, str]] = {}


def _op(name: str, code: int, fmt: str) -> None:
    assert name not in OPS, name
    assert 0 <= code <= 0x7F, f"{name}: opcode 0x{code:02x} does not fit 7 bits"
    assert code not in OPC, f"opcode 0x{code:02x} used twice"
    OPS[name] = (code, fmt)
    OPC[code] = (name, fmt)


# ALU immediate: rd = rd <op> imm8
_op("LDI", 0x00, "imm")
_op("ADDI", 0x01, "imm")
_op("SUBI", 0x02, "imm")
_op("ANDI", 0x03, "imm")
_op("ORI", 0x04, "imm")
_op("XORI", 0x05, "imm")
_op("CMPI", 0x06, "imm")
_op("SHLI", 0x07, "imm")
_op("SHRI", 0x08, "imm")
_op("ASRI", 0x09, "imm")
_op("ROLI", 0x0A, "imm")
_op("RORI", 0x0B, "imm")
_op("ADCI", 0x0C, "imm")
_op("SBCI", 0x0D, "imm")
_op("MOVI", 0x0E, "imm")  # alias of LDI kept distinct for clarity in disasm

# ALU register: rd = rd <op> rs
_op("MOV", 0x10, "reg")
_op("ADD", 0x11, "reg")
_op("SUB", 0x12, "reg")
_op("AND", 0x13, "reg")
_op("OR", 0x14, "reg")
_op("XOR", 0x15, "reg")
_op("CMP", 0x16, "reg")
_op("SHL", 0x17, "reg")
_op("SHR", 0x18, "reg")
_op("ASR", 0x19, "reg")
_op("ROL", 0x1A, "reg")
_op("ROR", 0x1B, "reg")
_op("NOT", 0x1C, "unary")
_op("NEG", 0x1D, "unary")
_op("INC", 0x1E, "unary")
_op("DEC", 0x1F, "unary")
_op("ADC", 0x20, "reg")
_op("SBC", 0x21, "reg")

# Pin operations: bank = rs[1:0], mask = imm8, value register = rd
_op("SETP", 0x22, "pin")
_op("CLRP", 0x23, "pin")
_op("TOGP", 0x24, "pin")
_op("OUTP", 0x25, "pin")
_op("INPR", 0x26, "pin")
_op("DIRS", 0x27, "pin")
_op("DIRC", 0x28, "pin")
_op("ODSET", 0x29, "pin")
_op("ODCLR", 0x2A, "pin")
_op("OUTBIT", 0x2B, "unary")
_op("INBIT", 0x2C, "unary")
_op("WAITP", 0x2D, "waitp")

# Control
_op("JMP", 0x30, "jmp")
_op("JZ", 0x31, "jmp")
_op("JNZ", 0x32, "jmp")
_op("JC", 0x33, "jmp")
_op("JNC", 0x34, "jmp")
_op("JN", 0x35, "jmp")
_op("DJNZ", 0x36, "djmp")
_op("HALT", 0x38, "none")
_op("NOP", 0x39, "none")
_op("WAITC", 0x3A, "waitc")
_op("PACE", 0x3B, "none")
_op("PACERST", 0x3C, "none")
_op("ASSERT", 0x3E, "imm")

# System / streaming / time
_op("PUSH", 0x40, "unary")
_op("PULL", 0x41, "unary")
_op("PUSHN", 0x42, "unary")
_op("PULLN", 0x43, "unary")
_op("IRQSET", 0x44, "irq")
_op("IRQCLR", 0x45, "irq")
_op("IRQWAIT", 0x46, "irq")
_op("BAR", 0x47, "bar")
_op("TSLO", 0x48, "unary")
_op("TSHI", 0x49, "unary")
_op("MEASLO", 0x4A, "unary")
_op("MEASHI", 0x4B, "unary")
_op("CAPTURE", 0x4C, "tag")
_op("CFG", 0x4D, "cfg")

assert len(OPC) == len(OPS) == 72, (len(OPS), len(OPC))

# Pin ops whose rd field carries the value register.
PIN_RD_OPS = frozenset(("OUTP", "INPR"))

# Jump mnemonic -> condition code stored in rd.
JUMP_CONDS = {"JMP": 0, "JZ": 1, "JNZ": 2, "JC": 3, "JNC": 4, "JN": 5}

# ---------------------------------------------------------------------------
# Fields
# ---------------------------------------------------------------------------
OP_SHIFT, OP_BITS = 17, 7
RD_SHIFT, RD_BITS = 14, 3
RS_SHIFT, RS_BITS = 11, 3
IMM_SHIFT, IMM_BITS = 3, 8
SS_SHIFT, SS_BITS = 0, 3

MASK_OP = (1 << OP_BITS) - 1
MASK_R = (1 << RD_BITS) - 1
MASK_IMM = (1 << IMM_BITS) - 1
MASK_SS = (1 << SS_BITS) - 1
MASK_WORD = (1 << 24) - 1

assert OP_SHIFT + OP_BITS == 24
assert RD_SHIFT + RD_BITS == OP_SHIFT
assert RS_SHIFT + RS_BITS == RD_SHIFT
assert IMM_SHIFT + IMM_BITS == RS_SHIFT
assert SS_SHIFT + SS_BITS == IMM_SHIFT

# ---------------------------------------------------------------------------
# CFG field codes (imm8 value, rs = field)
# ---------------------------------------------------------------------------
CFG_FIELDS = {
    "SIDE": 0,       # value: [7]=en [6:5]=bank [4:2]=base [1:0]=width-1 (1..3)
    "BITPIN": 1,     # value: [7:6]=bank [5:3]=pin index [2]=invert
    "PERIOD0": 2,    # pacing period byte 0 (LSB)   (24.8 fixed point)
    "PERIOD1": 3,
    "PERIOD2": 4,
    "PERIOD3": 5,
    "TIMEOUT": 6,    # WAITP/IRQWAIT timeout in 256-cycle units (0 = off)
    "SCRATCH": 7,
}
CFG_NAMES = {v: k for k, v in CFG_FIELDS.items()}

# Condition codes for jumps (rd field)
CONDS = ["ALWAYS", "Z", "NZ", "C", "NC", "N", "EQ", "NE"]

# Pin banks
BANK_UI = 0   # ui_in[7:0], read-only
BANK_UO = 1   # uo_out[7:0], write-only
BANK_UIO = 2  # uio[7:0], read/write with per-pin output enable
BANK_NAMES = ["UI", "UO", "UIO", "BAD"]

# Operand signature per format, used by the assembler and docs/isa.md.
#   r = register r0..r7   i = 8-bit immediate (labels/equates allowed)
#   b = pin bank name     f = cfg field name   t = jump target
OPERANDS = {
    "imm": ("r", "i"),
    "reg": ("r", "r"),
    "unary": ("r",),
    "pin": ("b", "i"),
    "waitp": ("b", "i", "i"),
    "jmp": ("t",),
    "djmp": ("r", "t"),
    "waitc": ("i",),
    "irq": ("i",),
    "bar": ("i",),
    "cfg": ("f", "i"),
    "tag": ("i",),
    "none": (),
}


def operands_for(op: str) -> tuple:
    """Operand signature for a mnemonic (handles OUTP/INPR's extra rd)."""
    fmt = OPS[op][1]
    if fmt == "pin" and op in PIN_RD_OPS:
        return ("b", "i", "r")
    return OPERANDS[fmt]


# ---------------------------------------------------------------------------
# Encode / decode
# ---------------------------------------------------------------------------
def enc(op: str, rd: int = 0, rs: int = 0, imm: int = 0, ss: int = 0) -> int:
    """Encode one instruction.  Raises ValueError on an out-of-range field."""
    try:
        code = OPS[op][0]
    except KeyError:
        raise ValueError(f"unknown mnemonic {op!r}") from None
    for what, val, hi in (("rd", rd, MASK_R), ("rs", rs, 7),
                          ("imm", imm, MASK_IMM), ("ss", ss, MASK_SS)):
        if not 0 <= val <= hi:
            raise ValueError(f"{op}: {what}={val} out of range 0..{hi}")
    word = (code << OP_SHIFT) | (rd << RD_SHIFT) | (rs << RS_SHIFT) \
        | (imm << IMM_SHIFT) | ss
    assert 0 <= word <= MASK_WORD, hex(word)
    return word


def fields(word: int) -> dict:
    return {
        "op": (word >> OP_SHIFT) & MASK_OP,
        "rd": (word >> RD_SHIFT) & MASK_R,
        "rs": (word >> RS_SHIFT) & 7,
        "imm": (word >> IMM_SHIFT) & MASK_IMM,
        "ss": (word >> SS_SHIFT) & MASK_SS,
    }


def disasm(word: int, ss: bool = True) -> str:
    """Render one instruction.  Never raises, even for undefined opcodes."""
    f = fields(word)
    name, fmt = OPC.get(f["op"], (f"OP{f['op']:02x}", "none"))
    rd, rs, imm = f["rd"], f["rs"], f["imm"]
    ssx = f" ss={f['ss']}" if (ss and f["ss"]) else ""
    if name.startswith("OP"):
        return f"{name} 0x{word:06x}"

    if fmt == "imm":
        return f"{name} r{rd}, 0x{imm:02x}{ssx}"
    if fmt == "reg":
        return f"{name} r{rd}, r{rs}{ssx}"
    if fmt == "unary":
        return f"{name} r{rd}{ssx}"
    if fmt == "pin":
        val = f", r{rd}" if name in PIN_RD_OPS else ""
        return f"{name} {BANK_NAMES[rs & 3]}, 0x{imm:02x}{val}{ssx}"
    if fmt == "waitp":
        return f"WAITP {BANK_NAMES[rs & 3]}, 0x{imm:02x}, {(rs >> 2) & 1}{ssx}"
    if fmt == "jmp":
        return f"{name} 0x{imm & (PROG_DEPTH - 1):02x}{ssx}"
    if fmt == "djmp":
        return f"DJNZ r{rd}, 0x{imm & (PROG_DEPTH - 1):02x}{ssx}"
    if fmt == "waitc":
        return f"WAITC {((rs << 8) | imm) & 0x7FF}{ssx}"
    if fmt == "irq":
        return f"{name} {imm & 7}{ssx}"
    if fmt == "bar":
        return f"BAR {imm & 3}{ssx}"
    if fmt == "tag":
        return f"CAPTURE 0x{imm:02x}{ssx}"
    if fmt == "cfg":
        return f"CFG {CFG_NAMES.get(rs, 'BAD')}, 0x{imm:02x}{ssx}"
    return f"{name}{ssx}"


if __name__ == "__main__":
    for code in sorted(OPC):
        name, fmt = OPC[code]
        print(f"0x{code:02x} {name:8s} {fmt}")
