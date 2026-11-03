"""Deterministic generator of valid PROTEUS programs for the RTL-vs-model diff.

``sim/test_diff.py`` assembles ``gen_program(seed).words`` into the DUT over the
real host SPI and into ``tools/model.py``, then compares every architectural
field each cycle.  For that comparison to mean "the two implementations differ",
the generator must stay inside the subset where both are *supposed* to agree.
Each rule below is that boundary:

* Banks are ``UI``/``UO``/``UIO`` only.  Bank 3 is undefined in the ISA and
  reads 0 in both implementations; generating it would test nothing.
* ``UO`` accesses use mask bits ``[7:2]`` only.  While the host owns the pads
  (``host_en=1``, the reset state) ``uo_out[1:0]`` are the IRQ/MISO pins and
  ``src/tt_um_proteus.v`` drops engine writes to them, so a program touching
  them would diverge from ``tools/model.py`` for a reason that is not a defect.
* At most ``MAX_PUSH_OPS`` push instructions and at most ``MAX_CAPTURES``
  capture events per program.  The RTL defaults are ``FIFO_DEPTH=4`` and
  ``CAP_DEPTH=4``; ``tools/model.py`` hard-codes 8 for both.  Staying at or
  below 4 compares two implementations instead of two parameters.
* Every jump target is an instruction index in ``0..PROG_DEPTH-1``.  Only
  ``DJNZ`` jumps backwards, and its counter is loaded with a small constant, so
  every loop is bounded.  ``JMP``/``JZ``/``JNZ``/``JC``/``JNC``/``JN`` only
  skip forwards.
* ``WAITP``/``IRQWAIT`` either match on the issue cycle or are covered by
  ``CFG TIMEOUT`` (``src/proteus_engine.v``: a zero timeout waits forever).
  ``WAITC`` counts are small.  ``BAR`` uses id 0 only; with one running engine
  the RTL completes it in the arrival cycle, so it cannot deadlock.
* ``PUSH``/``PULL`` (blocking forms) are only emitted outside loops and within
  the FIFO budget, so no program stalls on a FIFO it cannot drain.

``python tools/diffgen.py --check 500`` regenerates the corpus and runs it on
``tools/model.py`` alone (no RTL), reporting word counts, cycle counts, the
opcode coverage of the required subset and any program that fails to halt.
"""

from __future__ import annotations

import argparse
import random
import sys
from dataclasses import dataclass, field

import isa

BANK_UI, BANK_UO, BANK_UIO = 0, 1, 2

MAX_WORDS = isa.PROG_DEPTH        # 32
MAX_PUSH_OPS = 4                  # RTL FIFO_DEPTH default
MAX_CAPTURES = 4                  # RTL CAP_DEPTH default
DEFAULT_MAX_CYCLES = 3000

# Opcode subsets the diff corpus is required to exercise (requirement: safe
# ISA subsets).  ``--check`` reports anything missing.
REQUIRED_OPS = (
    "LDI", "ADDI", "SUBI", "ANDI", "ORI", "XORI",
    "ADD", "SUB", "AND", "OR", "XOR", "MOV", "CMP",
    "INC", "DEC", "NOT", "NEG",
    "SHLI", "SHRI", "ASRI", "ROLI", "RORI",
    "SHL", "SHR", "ASR", "ROL", "ROR",
    "SETP", "CLRP", "TOGP", "OUTP", "INPR", "WAITP",
    "DIRS", "DIRC", "ODSET", "ODCLR", "OUTBIT", "INBIT",
    "WAITC", "PACE", "PACERST",
    "JMP", "JZ", "JNZ", "JC", "JNC", "JN", "DJNZ",
    "PUSH", "PULL", "PUSHN", "PULLN",
    "IRQSET", "IRQCLR", "IRQWAIT", "BAR",
    "TSLO", "TSHI", "MEASLO", "MEASHI", "CAPTURE",
    "CFG", "HALT",
)

# Immediates biased to the boundaries where carry, borrow and zero appear.
_IMM_BIAS = (0x00, 0x01, 0x02, 0x07, 0x08, 0x0F, 0x7F, 0x80, 0x81, 0xFE, 0xFF)
_IMM_OPS = ("ADDI", "SUBI", "ANDI", "ORI", "XORI", "CMPI",
            "SHLI", "SHRI", "ASRI", "ROLI", "RORI", "ADCI", "SBCI")
_REG_OPS = ("MOV", "ADD", "SUB", "AND", "OR", "XOR", "CMP",
            "SHL", "SHR", "ASR", "ROL", "ROR", "ADC", "SBC")
_UN_OPS = ("NOT", "NEG", "INC", "DEC")
_COND_JUMPS = ("JZ", "JNZ", "JC", "JNC", "JN")
# External pull onto uio_in.  Non-zero so a level-1 WAITP on a subset of these
# bits matches on its issue cycle.
_EXT_CHOICES = (0x01, 0x80, 0x03, 0x0F, 0xA5, 0x3C, 0xF0, 0x66, 0xC3)

KINDS = ("alu", "pins", "ctrl", "loop", "wait", "fifo", "irq", "capture", "mix")


# ---------------------------------------------------------------------------
# Program
# ---------------------------------------------------------------------------
@dataclass
class Program:
    seed: int
    kind: str
    words: list[int]
    ext: int = 0                  # external drive onto uio_in (open-drain pull)
    cap_en: int = 0
    fabric_in: int = 0            # ui_in[7:3], a constant for the whole run
    in_bytes: list[int] = field(default_factory=list)
    max_cycles: int = DEFAULT_MAX_CYCLES
    name: str = ""

    def listing(self) -> str:
        head = f"seed={self.seed} kind={self.kind}"
        if self.name:
            head += f" name={self.name}"
        body = "\n".join(
            f"{i:02d}  {w:06x}  {isa.disasm(w)}" for i, w in enumerate(self.words)
        )
        return f"{head}\next={self.ext:#04x} cap_en={self.cap_en:#04x} " \
               f"fabric_in={self.fabric_in:#04x} prefill={self.in_bytes}\n{body}"


# ---------------------------------------------------------------------------
# Assembler-ish builder: jump targets are instruction indices fixed at the end
# ---------------------------------------------------------------------------
class _P:
    def __init__(self, rng: random.Random):
        self.rng = rng
        self.items: list[tuple] = []

    # -- emit ---------------------------------------------------------------
    def emit(self, op: str, rd: int = 0, rs: int = 0, imm: int = 0, ss: int = 0) -> int:
        self.items.append(("i", op, rd, rs, imm, ss))
        return len(self.items) - 1

    def jump(self, op: str, target: int, ss: int = 0) -> int:
        """Conditional/unconditional jump to an instruction index."""
        self.items.append(("j", op, isa.JUMP_CONDS[op], target, ss))
        return len(self.items) - 1

    def djmp(self, reg: int, target: int, ss: int = 0) -> int:
        self.items.append(("d", reg, target, ss))
        return len(self.items) - 1

    def here(self) -> int:
        return len(self.items)

    def room(self) -> int:
        """Instructions we may still emit, reserving one word for HALT."""
        return MAX_WORDS - len(self.items) - 1

    def words(self) -> list[int]:
        out: list[int] = []
        for it in self.items:
            if it[0] == "i":
                out.append(isa.enc(it[1], it[2], it[3], it[4], it[5]))
            elif it[0] == "j":
                out.append(isa.enc(it[1], rd=it[2], imm=it[3], ss=it[4]))
            else:
                out.append(isa.enc("DJNZ", rd=it[1], imm=it[2], ss=it[3]))
        return out


class _Ctx:
    """Budgets that keep the program inside the subset rules."""

    def __init__(self, rng: random.Random, ext: int, prefill: list[int]):
        self.rng = rng
        self.ext = ext
        self.prefill = list(prefill)
        self.pushes = 0        # total push instructions (blocking or not)
        self.pops = 0          # total pull instructions (blocking or not)
        self.caps = 0
        self.ss: int = 0       # 0 = side-set disabled; else ss bits per insn
        self.loop_depth = 0
        self.avoid: int | None = None   # register a loop counter must keep

    # -- random helpers -----------------------------------------------------
    def imm(self) -> int:
        r = self.rng.random()
        if r < 0.6:
            return self.rng.choice(_IMM_BIAS)
        return self.rng.randrange(256)

    def reg(self, avoid: int | None = None) -> int:
        for _ in range(16):
            r = self.rng.randrange(8)
            if r != avoid and r != self.avoid:
                return r
        return 0

    def ssval(self) -> int:
        return self.rng.randrange(8) if self.ss else 0

    def uio_mask(self) -> int:
        r = self.rng.random()
        if r < 0.3:
            return 0x0F                 # overlapping low nibble
        if r < 0.5:
            return 0xF0
        if r < 0.7:
            return self.rng.choice((0x33, 0x3C, 0xC3, 0xAA, 0x55, 0x87, 0x78))
        return self.rng.randrange(1, 256)

    def uo_mask(self) -> int:
        # bits [7:2] only: [1:0] are the host's IRQ/MISO pins
        return self.rng.randrange(1, 64) << 2

    def can_push(self) -> bool:
        return self.pushes < MAX_PUSH_OPS

    def can_capture(self) -> bool:
        return self.caps < MAX_CAPTURES


# ---------------------------------------------------------------------------
# Instruction groups
# ---------------------------------------------------------------------------
def _imm_op(p: _P, ctx: _Ctx, rd: int | None = None) -> None:
    r = ctx.rng
    p.emit(r.choice(_IMM_OPS), rd=ctx.reg() if rd is None else rd,
           imm=ctx.imm(), ss=ctx.ssval())


def _reg_op(p: _P, ctx: _Ctx) -> None:
    r = ctx.rng
    rd = ctx.reg()
    p.emit(r.choice(_REG_OPS), rd=rd, rs=ctx.reg(avoid=rd), ss=ctx.ssval())


def _un_op(p: _P, ctx: _Ctx) -> None:
    r = ctx.rng
    p.emit(r.choice(_UN_OPS), rd=ctx.reg(), ss=ctx.ssval())


def _alu_block(p: _P, ctx: _Ctx, n: int) -> None:
    for _ in range(n):
        if p.room() < 2:
            return
        r = ctx.rng.random()
        if r < 0.50:
            _imm_op(p, ctx)
        elif r < 0.85:
            _reg_op(p, ctx)
        else:
            _un_op(p, ctx)


def _pin_block(p: _P, ctx: _Ctx, n: int) -> None:
    r = ctx.rng
    for _ in range(n):
        if p.room() < 2:
            return
        what = r.randrange(10)
        ss = ctx.ssval()
        if what == 0:
            p.emit("SETP", rs=BANK_UIO, imm=ctx.uio_mask(), ss=ss)
        elif what == 1:
            p.emit("CLRP", rs=BANK_UIO, imm=ctx.uio_mask(), ss=ss)
        elif what == 2:
            p.emit("TOGP", rs=BANK_UIO, imm=ctx.uio_mask(), ss=ss)
        elif what == 3:
            p.emit("OUTP", rd=ctx.reg(), rs=BANK_UIO, imm=ctx.uio_mask(), ss=ss)
        elif what == 4:
            p.emit("INPR", rd=ctx.reg(), rs=BANK_UIO, imm=ctx.uio_mask(), ss=ss)
        elif what == 5:
            # UO: fabric output bits only, plus a readback through INPR
            if r.random() < 0.5:
                p.emit("SETP", rs=BANK_UO, imm=ctx.uo_mask(), ss=ss)
            else:
                p.emit("OUTP", rd=ctx.reg(), rs=BANK_UO, imm=ctx.uo_mask(), ss=ss)
        elif what == 6:
            p.emit("INPR", rd=ctx.reg(), rs=BANK_UI,
                   imm=r.choice((0xFF, 0xF8, 0x18)), ss=ss)
        elif what == 7:
            p.emit(r.choice(("DIRS", "DIRC")), rs=BANK_UIO,
                   imm=ctx.uio_mask(), ss=ss)
        elif what == 8:
            p.emit(r.choice(("ODSET", "ODCLR")), rs=BANK_UIO,
                   imm=ctx.uio_mask(), ss=ss)
        else:
            p.emit(r.choice(("OUTBIT", "INBIT")), rd=ctx.reg(), ss=ss)


def _ctrl_block(p: _P, ctx: _Ctx, n: int) -> None:
    """Forward-only conditional/unconditional skips and small WAITC."""
    r = ctx.rng
    for _ in range(n):
        if p.room() < 4:
            return
        kind = r.randrange(4)
        if kind == 0:
            skip = r.randint(1, 3)
            if p.room() < skip + 2:
                continue
            target = p.here() + 1 + skip
            p.jump(r.choice(_COND_JUMPS), target, ss=ctx.ssval())
            _alu_block(p, ctx, skip)
        elif kind == 1:
            skip = r.randint(1, 3)
            if p.room() < skip + 2:
                continue
            target = p.here() + 1 + skip
            p.jump("JMP", target, ss=ctx.ssval())
            _alu_block(p, ctx, skip)
        elif kind == 2:
            ncyc = r.randint(0, 8)
            p.emit("WAITC", rs=(ncyc >> 8) & 7, imm=ncyc & 0xFF, ss=ctx.ssval())
        else:
            p.emit("CMPI", rd=ctx.reg(), imm=ctx.imm(), ss=ctx.ssval())


def _fifo_block(p: _P, ctx: _Ctx, n: int, allow_blocking: bool) -> None:
    r = ctx.rng
    for _ in range(n):
        if p.room() < 2:
            return
        what = r.randrange(4)
        if what in (0, 2):                       # push forms
            if not ctx.can_push():
                continue
            op = "PUSH" if (allow_blocking and what == 0 and not ctx.loop_depth) \
                else "PUSHN"
            ctx.pushes += 1
            p.emit(op, rd=ctx.reg(), ss=ctx.ssval())
        else:                                    # pull forms
            # A blocking PULL is only safe while the host-prefilled bytes are
            # guaranteed to cover every earlier pull in the program (a PULLN
            # that found the FIFO empty is counted against the budget too, so
            # this is conservative).
            if allow_blocking and what == 1 and not ctx.loop_depth \
                    and ctx.pops < len(ctx.prefill):
                p.emit("PULL", rd=ctx.reg(), ss=ctx.ssval())
            else:
                p.emit("PULLN", rd=ctx.reg(), ss=ctx.ssval())
            ctx.pops += 1


def _irq_block(p: _P, ctx: _Ctx, n: int) -> None:
    r = ctx.rng
    for _ in range(n):
        if p.room() < 3:
            return
        what = r.randrange(5)
        line = r.randrange(8)
        ss = ctx.ssval()
        if what == 0:
            p.emit("IRQSET", imm=line, ss=ss)
        elif what == 1:
            p.emit("IRQCLR", imm=line, ss=ss)
        elif what == 2:
            # set then wait: the wait matches on its issue cycle
            p.emit("IRQSET", imm=line, ss=0)
            p.emit("IRQWAIT", imm=line, ss=ss)
        elif what == 3:
            # clear then wait: only the CFG TIMEOUT prologue bounds this
            p.emit("IRQCLR", imm=line, ss=0)
            p.emit("IRQWAIT", imm=line, ss=ss)
        else:
            p.emit("BAR", imm=0, ss=ss)


def _time_block(p: _P, ctx: _Ctx, n: int) -> None:
    r = ctx.rng
    for _ in range(n):
        if p.room() < 2:
            return
        p.emit(r.choice(("TSLO", "TSHI", "MEASLO", "MEASHI")),
               rd=ctx.reg(), ss=ctx.ssval())


def _capture_block(p: _P, ctx: _Ctx, n: int) -> None:
    r = ctx.rng
    for _ in range(n):
        if p.room() < 2 or not ctx.can_capture():
            return
        ctx.caps += 1
        tag = (r.randrange(16)) | (r.randrange(2) << 4)
        p.emit("CAPTURE", imm=tag, ss=ctx.ssval())


# ---------------------------------------------------------------------------
# Prologue: every CFG the body relies on, before any instruction that uses it
# ---------------------------------------------------------------------------
def _prologue(p: _P, ctx: _Ctx, *, side: tuple | None, bitpin: tuple | None,
              timeout: int, period: int | None, scratch: bool) -> None:
    r = ctx.rng
    if side is not None:
        bank, base, width = side
        ctx.ss = 0                       # the CFG instruction itself: no ss
        p.emit("CFG", rs=isa.CFG_FIELDS["SIDE"],
               imm=0x80 | (bank << 5) | (base << 2) | (width - 1))
        ctx.ss = 1                       # ss bits become live from here on
    if bitpin is not None:
        bank, bit, inv = bitpin
        p.emit("CFG", rs=isa.CFG_FIELDS["BITPIN"],
               imm=(bank << 6) | (bit << 3) | (inv << 2))
    if timeout:
        p.emit("CFG", rs=isa.CFG_FIELDS["TIMEOUT"], imm=timeout)
    if period is not None:
        for i in range(4):
            p.emit("CFG", rs=isa.CFG_FIELDS[f"PERIOD{i}"],
                   imm=(period >> (8 * i)) & 0xFF)
    if scratch:
        p.emit("CFG", rs=isa.CFG_FIELDS["SCRATCH"], imm=r.randrange(256))


def _side_cfg(r: random.Random) -> tuple:
    """Legal side-set geometry: base+width<=8, bank UO needs base>=2."""
    bank = r.choice((BANK_UO, BANK_UIO))
    width = r.randint(1, 3)
    base = r.randint(2 if bank == BANK_UO else 0, 8 - width)
    return (bank, base, width)


def _bitpin_cfg(r: random.Random) -> tuple:
    if r.random() < 0.25:                # UI is read-only but INBIT works
        return (BANK_UI, r.randrange(8), r.randrange(2))
    return (r.choice((BANK_UO, BANK_UIO)), r.randint(2, 7), r.randrange(2))


# ---------------------------------------------------------------------------
# Body per kind
# ---------------------------------------------------------------------------
def _body(p: _P, ctx: _Ctx, kind: str, *, side: bool, bitpin: bool,
          timeout: int, period: int | None) -> None:
    r = ctx.rng
    if kind == "alu":
        _alu_block(p, ctx, r.randint(8, 20))
    elif kind == "pins":
        _alu_block(p, ctx, r.randint(2, 4))
        _pin_block(p, ctx, r.randint(5, 12))
        _alu_block(p, ctx, r.randint(1, 3))
    elif kind == "ctrl":
        _ctrl_block(p, ctx, r.randint(3, 6))
        _alu_block(p, ctx, r.randint(2, 5))
    elif kind == "loop":
        reg = ctx.reg()
        count = r.randint(1, 5)
        p.emit("LDI", rd=reg, imm=count)
        start = p.here()
        # The counter must survive the body and the body must not push: a
        # dynamic push count above the RTL FIFO depth would compare two
        # different parameters (see the module docstring).
        ctx.loop_depth = 1
        ctx.avoid = reg
        _alu_block(p, ctx, r.randint(1, 3))
        _pin_block(p, ctx, 1)
        ctx.avoid = None
        ctx.loop_depth = 0
        p.djmp(reg, start)
        _alu_block(p, ctx, 1)
    elif kind == "wait":
        p.emit("PACERST")
        for _ in range(r.randint(2, 5)):
            if p.room() < 3:
                break
            p.emit("PACE")
            p.emit("TOGP", rs=BANK_UIO, imm=1 << r.randrange(8),
                   ss=ctx.ssval() if side else 0)
        _ctrl_block(p, ctx, 1)
        _time_block(p, ctx, 2)
    elif kind == "fifo":
        _fifo_block(p, ctx, r.randint(3, 6), allow_blocking=True)
        _alu_block(p, ctx, 2)
        _fifo_block(p, ctx, 2, allow_blocking=True)
    elif kind == "irq":
        _irq_block(p, ctx, r.randint(3, 5))
        _time_block(p, ctx, 2)
    elif kind == "capture":
        _capture_block(p, ctx, r.randint(1, 3))
        _pin_block(p, ctx, 3)
        _time_block(p, ctx, 1)
    else:  # mix: waits + FIFOs + pins + time, the "longer program" class
        if period is not None:
            p.emit("PACERST")
            if p.room() > 3:
                p.emit("PACE")
        _alu_block(p, ctx, r.randint(2, 5))
        _pin_block(p, ctx, r.randint(2, 5))
        _fifo_block(p, ctx, r.randint(2, 4), allow_blocking=True)
        _ctrl_block(p, ctx, 1)
        _time_block(p, ctx, 2)
        if timeout:
            p.emit("IRQSET", imm=r.randrange(8), ss=0)
            p.emit("IRQWAIT", imm=r.randrange(8), ss=ctx.ssval())
        _capture_block(p, ctx, 1)
        _fifo_block(p, ctx, 2, allow_blocking=False)


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------
def gen_program(seed: int, kind: str | None = None) -> Program:
    """Deterministic: the same seed always yields the same program."""
    rng = random.Random(0x5EED0000 + seed)
    if kind is None:
        kind = KINDS[seed % len(KINDS)]
    assert kind in KINDS, kind

    ext = rng.choice(_EXT_CHOICES)
    prefill = [rng.randrange(256) for _ in range(rng.randint(1, 3))]

    use_side = kind in ("pins", "mix", "wait") and rng.random() < 0.5
    use_bitpin = kind in ("pins", "mix") and rng.random() < 0.5
    need_timeout = kind in ("irq", "mix")
    timeout = 1 if need_timeout else 0
    period = None
    if kind == "wait" or (kind == "mix" and rng.random() < 0.6):
        # fractional 24.8 period, e.g. 0x6480 = 100.5 cycles
        period = rng.choice((0x6480, 0x0A80, 0x0180, 0x2180, 0x4080))

    side = _side_cfg(rng) if use_side else None
    bitpin = _bitpin_cfg(rng) if use_bitpin else None

    p = _P(rng)
    ctx = _Ctx(rng, ext, prefill)
    _prologue(p, ctx, side=side, bitpin=bitpin, timeout=timeout,
              period=period, scratch=(kind == "mix" and rng.random() < 0.3))
    _body(p, ctx, kind, side=use_side, bitpin=use_bitpin,
          timeout=timeout, period=period)

    # WAITP: always match on the issue cycle (mask subset of the external
    # pull) unless a timeout is armed, in which case a never-matching mask is
    # also safe.
    if kind in ("wait", "mix", "pins") and p.room() >= 2:
        r = rng.random()
        if r < 0.5 and ext:
            mask = rng.choice([m for m in (0x01, 0x02, 0x04, 0x08, 0x80, ext)
                               if m and (m & ext) == m] or [ext])
            p.emit("WAITP", rs=(1 << 2) | BANK_UIO, imm=mask, ss=ctx.ssval())
        elif timeout:
            p.emit("WAITP", rs=(1 << 2) | BANK_UIO, imm=0x80 ^ ext,
                   ss=ctx.ssval())

    assert p.room() >= 0, f"program overflow: {len(p.items)} instructions"
    p.emit("HALT")

    return Program(
        seed=seed,
        kind=kind,
        words=p.words(),
        ext=ext,
        cap_en=0,
        fabric_in=rng.randrange(32),
        in_bytes=prefill,
    )


def _mk(seed: int, name: str, words: list[int], **kw) -> Program:
    assert len(words) <= MAX_WORDS, (name, len(words))
    return Program(seed=seed, kind="corner", words=words, name=name, **kw)


def corner_programs() -> list[Program]:
    """Hand-built cases the random corpus only reaches by luck."""
    E = isa.enc
    cf = isa.CFG_FIELDS
    out: list[Program] = []

    # 1. all-ones / all-zero data through every flag-producing path
    out.append(_mk(9001, "corner_data_extremes", [
        E("LDI", rd=0, imm=0xFF),
        E("LDI", rd=1, imm=0x00),
        E("ADDI", rd=0, imm=0x01),      # 0xFF+1 -> 0x00, C=1, Z=1
        E("SUBI", rd=1, imm=0x01),      # 0x00-1 -> 0xFF, C=1 (borrow), N=1
        E("NOT", rd=1),
        E("NEG", rd=1),
        E("AND", rd=0, rs=1),
        E("OR", rd=0, rs=1),
        E("XOR", rd=0, rs=1),
        E("CMP", rd=0, rs=1),
        E("INC", rd=1),
        E("DEC", rd=1),
        E("LDI", rd=2, imm=0x80),
        E("ADDI", rd=2, imm=0x80),      # 0x100 -> 0x00, C=1, N=0
        E("SUBI", rd=2, imm=0x00),
        E("HALT"),
    ]))

    # 2. shift and rotate by 0 and by 7, both forms
    out.append(_mk(9002, "corner_shifts", [
        E("LDI", rd=0, imm=0x81),
        E("LDI", rd=1, imm=0x00),
        E("LDI", rd=2, imm=0x07),
        E("SHLI", rd=0, imm=0),         # unchanged, C=0
        E("SHLI", rd=0, imm=7),
        E("SHRI", rd=0, imm=7),
        E("ASRI", rd=0, imm=7),
        E("ROLI", rd=0, imm=0),
        E("RORI", rd=0, imm=7),
        E("SHL", rd=0, rs=1),           # by 0
        E("SHR", rd=0, rs=2),           # by 7
        E("ASR", rd=0, rs=2),
        E("ROL", rd=0, rs=1),
        E("ROR", rd=0, rs=2),
        E("SHLI", rd=1, imm=0x07),
        E("RORI", rd=1, imm=0x07),
        E("HALT"),
    ]))

    # 3. carry / borrow chains through ADC and SBC
    out.append(_mk(9003, "corner_carry_chain", [
        E("LDI", rd=0, imm=0xFF),
        E("ADDI", rd=0, imm=0x01),      # C=1
        E("LDI", rd=1, imm=0x00),
        E("ADCI", rd=1, imm=0x00),      # r1 = 1 via carry
        E("ADCI", rd=1, imm=0xFF),      # 0x01+0xFF+0 = 0x100 -> 0x00, C=1
        E("LDI", rd=2, imm=0x00),
        E("SUBI", rd=2, imm=0x01),      # borrow out, C=1
        E("LDI", rd=3, imm=0x00),
        E("SBCI", rd=3, imm=0x00),      # 0 - 0 - 1 = 0xFF, C=1
        E("ADC", rd=3, rs=2),
        E("SBC", rd=3, rs=1),
        E("CMPI", rd=2, imm=0xFF),
        E("HALT"),
    ]))

    # 4. pin-mask overlap: successive writes to the same UIO bits, plus a
    #    side-set window that collides with an instruction write.
    out.append(_mk(9004, "corner_pin_overlap", [
        E("CFG", rs=cf["SIDE"], imm=0x80 | (BANK_UIO << 5) | (2 << 2) | 1),
        E("SETP", rs=BANK_UIO, imm=0x0F, ss=0b110),
        E("SETP", rs=BANK_UIO, imm=0x33, ss=0b001),
        E("OUTP", rd=0, rs=BANK_UIO, imm=0xFC, ss=0b010),
        E("LDI", rd=0, imm=0x5A),
        E("OUTP", rd=0, rs=BANK_UIO, imm=0x3C, ss=0b101),
        E("DIRS", rs=BANK_UIO, imm=0xF0),
        E("DIRC", rs=BANK_UIO, imm=0x30),
        E("ODSET", rs=BANK_UIO, imm=0x0C),
        E("ODCLR", rs=BANK_UIO, imm=0x08),
        E("TOGP", rs=BANK_UIO, imm=0xFF),
        E("INPR", rd=1, rs=BANK_UIO, imm=0xFF),
        E("SETP", rs=BANK_UO, imm=0xFC),
        E("CLRP", rs=BANK_UO, imm=0x0C),
        E("HALT"),
    ], ext=0x01))

    # 5. WAITP on a level that never arrives, bounded by CFG TIMEOUT
    out.append(_mk(9005, "corner_waitp_timeout", [
        E("CFG", rs=cf["TIMEOUT"], imm=1),
        E("WAITP", rs=(1 << 2) | BANK_UIO, imm=0x80),
        E("LDI", rd=0, imm=0x42),
        E("WAITP", rs=(0 << 2) | BANK_UIO, imm=0xFF),   # level 0, never
        E("TSLO", rd=1),
        E("HALT"),
    ], ext=0x00))

    # 6. capture: hardware edges on UIO0/1 plus one software event
    out.append(_mk(9006, "corner_capture", [
        E("SETP", rs=BANK_UIO, imm=0x03),
        E("WAITC", imm=3),
        E("CLRP", rs=BANK_UIO, imm=0x03),
        E("WAITC", imm=2),
        E("CAPTURE", imm=0x45),
        E("WAITC", imm=1),
        E("SETP", rs=BANK_UIO, imm=0x01),
        E("HALT"),
    ], ext=0x00, cap_en=0x03))

    # 7. pacer with a fractional period: 100.5 cycles (0x6480 in 24.8)
    per = 0x6480
    w = [E("CFG", rs=cf[f"PERIOD{i}"], imm=(per >> (8 * i)) & 0xFF)
         for i in range(4)]
    w.append(E("PACERST"))
    for i in range(4):
        w.append(E("PACE"))
        w.append(E("TOGP", rs=BANK_UIO, imm=0x01))
    w.append(E("TSLO", rd=0))
    w.append(E("MEASLO", rd=1))
    w.append(E("HALT"))
    out.append(_mk(9007, "corner_pacer_fractional", w, ext=0x00))

    # 8. DJNZ wrap: a counter of 0 decrements to 0xFF and runs 256 iterations
    out.append(_mk(9008, "corner_djzn_wrap", [
        E("LDI", rd=0, imm=0x00),
        E("LDI", rd=1, imm=0x00),
        E("INC", rd=1),
        E("DJNZ", rd=0, imm=3),          # back to the INC: 256 iterations
        E("TSLO", rd=2),
        E("HALT"),
    ]))

    # 9. BAR 0 with a single running engine, and a BAR-free JMP loop
    out.append(_mk(9009, "corner_bar_irq", [
        E("BAR", imm=0),
        E("IRQSET", imm=3),
        E("IRQWAIT", imm=3),
        E("IRQCLR", imm=3),
        E("MEASLO", rd=0),
        E("JMP", imm=6),
        E("CAPTURE", imm=0x13),
        E("HALT"),
    ]))

    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _model_check(n: int) -> int:
    """Run the generated corpus on tools/model.py alone."""
    import model as golden

    seen: dict[str, int] = {}
    worst = (0, 0)
    halts = 0
    for seed in range(n):
        for prog in (gen_program(seed),):
            assert len(prog.words) <= MAX_WORDS, (seed, len(prog.words))
            for w in prog.words:
                f = isa.fields(w)
                name = isa.OPC.get(f["op"], ("?", "none"))[0]
                seen[name] = seen.get(name, 0) + 1
                # no instruction may address the undefined bank 3
                if isa.OPC[f["op"]][1] in ("pin", "waitp"):
                    assert (f["rs"] & 3) != 3, (seed, name, f)
            m = golden.ProteusModel(nsms=4)
            m.load(0, prog.words)
            for b in prog.in_bytes:
                m.push_in(0, b)
            m.capture_en = prog.cap_en
            m.ui_in = (prog.fabric_in & 0x1F) << 3
            m.uio_in = prog.ext
            m._prev_capture_pins = prog.ext
            m.start(0)
            cyc = 0
            while not m.engines[0].halted and cyc < prog.max_cycles:
                m.step()
                cyc += 1
            if m.engines[0].halted:
                halts += 1
            if cyc > worst[0]:
                worst = (cyc, seed)
    for prog in corner_programs():
        for w in prog.words:
            f = isa.fields(w)
            seen[isa.OPC.get(f["op"], ("?", "none"))[0]] = 1
        m = golden.ProteusModel(nsms=4)
        m.load(0, prog.words)
        for b in prog.in_bytes:
            m.push_in(0, b)
        m.capture_en = prog.cap_en
        m.ui_in = (prog.fabric_in & 0x1F) << 3
        m.uio_in = prog.ext
        m._prev_capture_pins = prog.ext
        m.start(0)
        cyc = 0
        while not m.engines[0].halted and cyc < prog.max_cycles:
            m.step()
            cyc += 1
        if m.engines[0].halted:
            halts += 1
        if cyc > worst[0]:
            worst = (cyc, -1)
        print(f"corner {prog.name:24s} words={len(prog.words):2d} "
              f"cycles={cyc:4d} halt={bool(m.engines[0].halted)}")

    missing = [op for op in REQUIRED_OPS if op not in seen]
    print(f"programs={n}+{len(corner_programs())} halted={halts} "
          f"worst_cycles={worst[0]} (seed {worst[1]})")
    print(f"opcodes seen={len(seen)}/{len(isa.OPS)}  missing_required={missing}")
    return 0 if not missing else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seed", type=int, default=None,
                    help="print the listing of one generated program")
    ap.add_argument("--kind", default=None, choices=KINDS)
    ap.add_argument("--check", type=int, default=None,
                    help="validate N seeds against tools/model.py")
    args = ap.parse_args(argv)
    if args.check is not None:
        return _model_check(args.check)
    if args.seed is not None:
        print(gen_program(args.seed, args.kind).listing())
        return 0
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
