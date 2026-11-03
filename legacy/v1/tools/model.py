"""PROTEUS cycle-accurate golden model.

This model is the executable specification for the RTL.  One call to ``step()``
advances the whole chip by exactly one ``clk`` cycle.

Conventions (must match RTL):
  * Every engine samples the pin state at the start of the cycle.
  * Engine pin writes are merged by a priority chain: engine 0 first, engine 3
    last, so on an overlapping bit the highest-numbered writing engine wins.
  * Side-set is applied *every* cycle the instruction is in flight, including
    stall cycles (WAITC/WAITP/PACE/blocked PUSH/PULL/IRQWAIT/BAR).
  * A pin write issued in cycle ``t`` is visible to every reader in cycle
    ``t + 1`` (writes land on the register at the end of the cycle).
  * ``PACE`` completes when ``cycle >= next_int`` and then advances the
    deadline by ``period`` (24.8 fixed point) with an explicit fractional
    carry:
        {carry, next_frac} = next_frac + period[7:0]
        next_int = next_int + period[31:8] + carry
    ``PACERST`` sets ``next_int = cycle`` and ``next_frac = 0``.  Completion
    instants are exactly ``floor(c0 + k*period/256)`` for any number of cycles:
    the horizon is the 32-bit cycle counter, not 24 bits.
  * ``WAITC n`` occupies exactly ``n`` cycles (minimum 1).
  * Open-drain: a pin with od=1 and out=1 is released (high-Z).
  * Undefined opcodes execute as ``NOP`` (the RTL decode defaults to no-op), so
    an un-programmed engine idles instead of faulting.

Semantic decisions that docs/architecture.md left open
------------------------------------------------------
  WAITP/IRQWAIT timeout
      ``timeout_cfg`` is in 256-cycle units; 0 disables the timeout.  The
      timeout counts *stall* cycles after the issue cycle: with
      ``timeout_cfg = 1`` the instruction occupies 2 cycles (issue + 1 stall)
      and then sets ``timeout_flag`` and continues.  This keeps the issue cycle
      free for a match ("the pin was already in the requested state"), which
      is what the model does and what the RTL must do.
  Shift/rotate by zero
      Any shift or rotate with a count of 0 leaves the register unchanged and
      clears ``C``.  (Counts are ``b[2:0]`` for register forms and ``imm[2:0]``
      for immediate forms.)
  Carry/borrow
      Additions set ``C`` to the carry out; subtractions and ``CMP`` set ``C``
      to the borrow (1 when ``a < b+cin``).  ``SBC`` consumes that borrow.
  ASR
      Fills exactly the top ``n`` bits with the sign bit (not the whole byte).
  Auto output-enable
      Any write to the UIO bank through a pin instruction or through side-set
      sets ``oe`` for the written bits.  ``DIRS``/``DIRC`` write ``oe``
      directly and never trigger auto-OE.  Writes to the read-only UI bank are
      ignored.
  Capture
      The unit watches the *pin* level (``uio_in``, i.e. what the world drives
      into the pad).  At most one event is pushed per cycle: if several watched
      pins change in the same cycle, the lowest pin index wins.  A full FIFO
      sets ``capture_overflow`` and drops the event.
  Collision (sticky, host-cleared)
      Evaluated at the start of each cycle, when the previously driven value is
      compared with the pin level: push-pull driven bits flag when
      ``uio_in != uio_out``; open-drain driven-low bits flag when
      ``uio_in != 0``.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

import isa
from isa import OPC

PROG_DEPTH = isa.PROG_DEPTH   # 32 by default; the model accepts up to MAX
FIFO_DEPTH = 4
CAPTURE_DEPTH = 4

BANK_UI, BANK_UO, BANK_UIO = 0, 1, 2

ALWAYS = 0xFFFFFFFF


@dataclass
class Engine:
    idx: int
    depth: int = PROG_DEPTH
    prog: list[int] = field(default_factory=list)
    pc: int = 0
    regs: list[int] = field(default_factory=lambda: [0] * 8)
    z: int = 0
    c: int = 0
    n: int = 0
    run: int = 0
    halted: int = 1
    # pacing: period is 24.8 fixed point; the deadline is split into a 32-bit
    # integer cycle count and an 8-bit fraction so it never truncates
    period: int = 0
    next: int = 0             # next_int, cycle domain
    next_frac: int = 0        # next_frac, 8-bit
    # side-set config
    ss_en: int = 0
    ss_bank: int = BANK_UIO
    ss_base: int = 0
    ss_width: int = 1
    # bit-pin shortcut
    bp_bank: int = BANK_UIO
    bp_bit: int = 0
    bp_inv: int = 0
    # misc
    timeout_cfg: int = 0
    wait_left: int = 0
    wait_active: int = 0
    ts_event: int = 0
    in_fifo: deque = field(default_factory=lambda: deque())
    out_fifo: deque = field(default_factory=lambda: deque())
    nf_flag: int = 0          # non-blocking FIFO op failed
    timeout_flag: int = 0
    error_flag: int = 0       # ASSERT failed
    irq_wait: int = -1

    def __post_init__(self):
        if not self.prog:
            self.prog = [isa.enc("HALT")] * self.depth

    def flag_word(self) -> int:
        return (self.n << 2) | (self.c << 1) | self.z


class ProteusModel:
    def __init__(self, nsms: int = 4, prog_depth: int = PROG_DEPTH):
        if not 1 <= prog_depth <= isa.MAX_PROG_DEPTH:
            raise ValueError(f"prog_depth {prog_depth} outside 1..{isa.MAX_PROG_DEPTH}")
        self.nsms = nsms
        self.prog_depth = prog_depth
        self.cycle = 0
        self.engines = [Engine(i, prog_depth) for i in range(nsms)]
        # external input pins
        self.ui_in = 0
        self.uio_in = 0
        # output state
        self.uo_out = 0
        self.uio_out = 0
        self.uio_oe = 0
        self.uio_od = 0
        self.irq = 0
        self.barrier_arrived = [0] * 4
        self.collision = 0
        self.capture_en = 0
        self.capture: deque = deque()   # (ts, pin, level), oldest first
        self.capture_overflow = 0
        self._prev_capture_pins = 0

    # ------------------------------------------------------------------ pins
    @property
    def oe_eff(self) -> int:
        """Bits actually driving the pad (open-drain 'high' is released)."""
        return self.uio_oe & ~(self.uio_od & self.uio_out) & 0xFF

    @property
    def uio_drive(self) -> int:
        """Pins driven high by the chip (open-drain aware)."""
        return self.uio_out & self.oe_eff

    def pin_state(self, bank: int) -> int:
        if bank == BANK_UI:
            return self.ui_in
        if bank == BANK_UO:
            return self.uo_out
        if bank == BANK_UIO:
            return self.uio_in
        return 0

    # kept for callers of the previous API
    pin_view = pin_state

    # ------------------------------------------------------------------ setup
    def reset(self) -> None:
        """Soft reset: cycle counter, engines and fabric back to power-on."""
        self.cycle = 0
        self.engines = [Engine(i, self.prog_depth) for i in range(self.nsms)]
        self.ui_in = self.uio_in = 0
        self.uo_out = self.uio_out = self.uio_oe = self.uio_od = 0
        self.irq = 0
        self.barrier_arrived = [0] * 4
        self.collision = 0
        self.capture.clear()
        self.capture_en = 0
        self.capture_overflow = 0
        self._prev_capture_pins = 0

    def load(self, eng: int, words: list[int]) -> None:
        e = self.engines[eng]
        words = list(words)
        if len(words) > e.depth:
            raise ValueError(f"engine {eng}: {len(words)} words exceeds depth {e.depth}")
        e.prog = words + [isa.enc("HALT")] * (e.depth - len(words))
        e.pc = 0

    def start(self, eng: int) -> None:
        """Host RUN strobe.  Clears any half-finished wait state."""
        e = self.engines[eng]
        e.run = 1
        e.halted = 0
        e.pc = 0
        e.wait_active = 0
        e.wait_left = 0

    def stop(self, eng: int) -> None:
        e = self.engines[eng]
        e.run = 0
        for i in range(4):
            self.barrier_arrived[i] &= ~(1 << eng) & 0xF

    def push_in(self, eng: int, byte: int) -> bool:
        f = self.engines[eng].in_fifo
        if len(f) >= FIFO_DEPTH:
            return False
        f.append(byte & 0xFF)
        return True

    def pop_out(self, eng: int):
        f = self.engines[eng].out_fifo
        return f.popleft() if f else None

    def clear_collision(self) -> None:
        self.collision = 0

    # ------------------------------------------------------------------ cycle
    def step(self) -> None:
        # 0. pad contention for the state driven last cycle
        self._update_collision()

        # 1. snapshot (every engine sees the same cycle-start pin state)
        snap_ui, snap_uo, snap_uio = self.ui_in, self.uo_out, self.uio_in

        # running set for barriers
        run_mask = 0
        for e in self.engines:
            if e.run and not e.halted:
                run_mask |= 1 << e.idx

        # 2. barrier pre-pass: a barrier releases every waiting engine in the
        # same cycle the last participant arrives (RTL semantics).  Computing
        # this before per-engine execution avoids the old bug where only the
        # last arriver advanced and the early arrivers re-armed the barrier.
        bar_ids: dict[int, int] = {}
        for e in self.engines:
            if e.run and not e.halted:
                f0 = isa.fields(e.prog[e.pc % e.depth])
                if f0["op"] == isa.OPS["BAR"][0]:
                    bar_ids[e.idx] = f0["imm"] & 3
        self._bar_release: set[int] = set()
        for bid in set(bar_ids.values()):
            arrived = self.barrier_arrived[bid]
            for idx, b in bar_ids.items():
                if b == bid:
                    arrived |= 1 << idx
            if arrived and (arrived & run_mask) == run_mask:
                self._bar_release.add(bid)
                self.barrier_arrived[bid] = 0
            else:
                self.barrier_arrived[bid] = arrived

        # 3. per-engine actions
        acts = []
        for e in self.engines:
            if not (e.run and not e.halted):
                acts.append(None)
                continue
            acts.append(self._engine_cycle(e, snap_ui, snap_uo, snap_uio, run_mask))

        # 3. merge pin writes (priority: later engine wins)
        for act in acts:
            if not act:
                continue
            if act["uo_we"]:
                self.uo_out = (self.uo_out & ~act["uo_we"] & 0xFF) \
                    | (act["uo_val"] & act["uo_we"] & 0xFF)
            if act["uio_we"]:
                self.uio_out = (self.uio_out & ~act["uio_we"] & 0xFF) \
                    | (act["uio_val"] & act["uio_we"] & 0xFF)
            if act["oe_we"]:
                self.uio_oe = (self.uio_oe & ~act["oe_we"] & 0xFF) \
                    | (act["oe_val"] & act["oe_we"] & 0xFF)
            if act["od_we"]:
                self.uio_od = (self.uio_od & ~act["od_we"] & 0xFF) \
                    | (act["od_val"] & act["od_we"] & 0xFF)

        # 4. capture unit on the external pin level
        self._capture_cycle(snap_uio)

        # 5. clock
        self.cycle = (self.cycle + 1) & ALWAYS

    # ------------------------------------------------------------ one engine
    def _engine_cycle(self, e: Engine, ui: int, uo: int, uio: int, run_mask: int):
        word = e.prog[e.pc % e.depth]
        f = isa.fields(word)
        name, fmt = OPC.get(f["op"], ("NOP", "none"))

        act = {
            "uo_we": 0, "uo_val": 0,
            "uio_we": 0, "uio_val": 0,
            "oe_we": 0, "oe_val": 0,
            "od_we": 0, "od_val": 0,
        }

        def apply_ss():
            """Side-set is driven every cycle, including stall cycles."""
            if not e.ss_en:
                return
            width = e.ss_width
            wmask = ((1 << width) - 1) << e.ss_base
            val = ((f["ss"] & ((1 << width) - 1)) << e.ss_base) & wmask
            if not wmask:
                return
            if e.ss_bank == BANK_UO:
                act["uo_we"] |= wmask
                act["uo_val"] = (act["uo_val"] & ~wmask) | (val & wmask)
            elif e.ss_bank == BANK_UIO:
                act["uio_we"] |= wmask
                act["uio_val"] = (act["uio_val"] & ~wmask) | (val & wmask)
                act["oe_we"] |= wmask
                act["oe_val"] |= wmask

        apply_ss()

        def pin_write(bank, mask, val, auto_oe=True):
            mask &= 0xFF
            if mask == 0:
                return
            if bank == BANK_UO:
                act["uo_we"] |= mask
                act["uo_val"] = (act["uo_val"] & ~mask) | (val & mask)
            elif bank == BANK_UIO:
                act["uio_we"] |= mask
                act["uio_val"] = (act["uio_val"] & ~mask) | (val & mask)
                if auto_oe:
                    act["oe_we"] |= mask
                    act["oe_val"] |= mask
            # BANK_UI is read-only: writes are ignored

        def pin_snapshot(bank):
            if bank == BANK_UI:
                return ui
            if bank == BANK_UO:
                return uo
            if bank == BANK_UIO:
                return uio
            return 0

        def rd(i):
            return e.regs[i]

        def wr(i, v):
            e.regs[i] = v & 0xFF

        def set_flags(v):
            v &= 0xFF
            e.z = 1 if v == 0 else 0
            e.n = (v >> 7) & 1

        def alu(op, a, b):
            a &= 0xFF
            b &= 0xFF
            if op in ("ADD", "ADDI", "ADC", "ADCI"):
                carry = e.c if op in ("ADC", "ADCI") else 0
                r = a + b + carry
                e.c = 1 if r > 0xFF else 0
                return r & 0xFF
            if op in ("SUB", "SUBI", "SBC", "SBCI", "CMP", "CMPI"):
                borrow = e.c if op in ("SBC", "SBCI") else 0
                r = a - b - borrow
                e.c = 1 if r < 0 else 0
                return r & 0xFF
            if op in ("AND", "ANDI"):
                return a & b
            if op in ("OR", "ORI"):
                return a | b
            if op in ("XOR", "XORI"):
                return a ^ b
            if op in ("SHL", "SHLI"):
                n = b & 7
                e.c = ((a >> (8 - n)) & 1) if n else 0
                return (a << n) & 0xFF
            if op in ("SHR", "SHRI"):
                n = b & 7
                e.c = ((a >> (n - 1)) & 1) if n else 0
                return (a >> n) & 0xFF
            if op in ("ASR", "ASRI"):
                n = b & 7
                if not n:
                    e.c = 0
                    return a
                e.c = (a >> (n - 1)) & 1
                if a & 0x80:
                    return ((a >> n) | (0xFF << (8 - n))) & 0xFF
                return a >> n
            if op in ("ROL", "ROLI"):
                n = b & 7
                if not n:
                    e.c = 0
                    return a
                r = ((a << n) | (a >> (8 - n))) & 0xFF
                e.c = r & 1
                return r
            if op in ("ROR", "RORI"):
                n = b & 7
                if not n:
                    e.c = 0
                    return a
                r = ((a >> n) | (a << (8 - n))) & 0xFF
                e.c = (r >> 7) & 1
                return r
            raise AssertionError(op)

        def wait_stall(cond: bool, timeout_units: int) -> bool:
            """Common WAITP/IRQWAIT accounting.

            Returns True when the instruction may complete this cycle.
            ``timeout_units`` is 256-cycle units (0 = wait forever).  The issue
            cycle never times out; ``timeout_units * 256`` stall cycles are
            allowed afterwards.
            """
            if cond:
                e.wait_active = 0
                e.wait_left = 0
                return True
            if not e.wait_active:
                e.wait_active = 1
                e.wait_left = timeout_units
                return False
            if timeout_units:
                if e.wait_left <= 1:
                    e.wait_active = 0
                    e.wait_left = 0
                    e.timeout_flag = 1
                    return True
                e.wait_left -= 1
            return False

        complete = True
        advance = True

        # ---------------------------------------------------------- decode
        if fmt == "imm":
            v = f["imm"]
            if name in ("LDI", "MOVI"):
                wr(f["rd"], v)
                set_flags(v)
            elif name == "ASSERT":
                if rd(f["rd"]) != v:
                    e.error_flag = 1
            else:
                r = alu(name, rd(f["rd"]), v)
                if name != "CMPI":
                    wr(f["rd"], r)
                set_flags(r)

        elif fmt == "reg":
            a, b = rd(f["rd"]), rd(f["rs"])
            if name == "MOV":
                wr(f["rd"], b)
                set_flags(b)
            elif name == "CMP":
                r = alu("CMP", a, b)
                set_flags(r)
            else:
                r = alu(name, a, b)
                wr(f["rd"], r)
                set_flags(r)

        elif fmt == "unary":
            a = rd(f["rd"])
            if name == "INC":
                r = alu("ADD", a, 1)
                wr(f["rd"], r)
                set_flags(r)
            elif name == "DEC":
                r = alu("SUB", a, 1)
                wr(f["rd"], r)
                set_flags(r)
            elif name == "NOT":
                r = (~a) & 0xFF
                wr(f["rd"], r)
                set_flags(r)
            elif name == "NEG":
                r = alu("SUB", 0, a)
                wr(f["rd"], r)
                set_flags(r)
            elif name == "OUTBIT":
                bit = a & 1
                if e.bp_inv:
                    bit ^= 1
                if e.bp_bank in (BANK_UO, BANK_UIO):
                    pin_write(e.bp_bank, 1 << e.bp_bit, bit << e.bp_bit)
            elif name == "INBIT":
                bit = (pin_snapshot(e.bp_bank) >> e.bp_bit) & 1
                if e.bp_inv:
                    bit ^= 1
                wr(f["rd"], bit)
                set_flags(bit)
            elif name == "PUSH":
                if len(e.out_fifo) < FIFO_DEPTH:
                    e.out_fifo.append(a)
                    e.nf_flag = 0
                else:                      # blocked: hold pc, keep side-set
                    complete = False
                    advance = False
            elif name == "PULL":
                if e.in_fifo:
                    wr(f["rd"], e.in_fifo.popleft())
                    e.nf_flag = 0
                else:                      # blocked: hold pc, keep side-set
                    complete = False
                    advance = False
            elif name == "PUSHN":
                if len(e.out_fifo) < FIFO_DEPTH:
                    e.out_fifo.append(a)
                    e.nf_flag = 0
                else:
                    e.nf_flag = 1
            elif name == "PULLN":
                if e.in_fifo:
                    wr(f["rd"], e.in_fifo.popleft())
                    e.nf_flag = 0
                else:
                    e.nf_flag = 1
            elif name == "TSLO":
                wr(f["rd"], self.cycle & 0xFF)
            elif name == "TSHI":
                wr(f["rd"], (self.cycle >> 8) & 0xFF)
            elif name in ("MEASLO", "MEASHI"):
                d = (self.cycle - e.ts_event) & ALWAYS
                wr(f["rd"], (d & 0xFF) if name == "MEASLO" else ((d >> 8) & 0xFF))
            else:
                raise AssertionError(name)

        elif fmt == "pin":
            bank = f["rs"] & 3
            mask = f["imm"]
            if name == "SETP":
                pin_write(bank, mask, 0xFF)
            elif name == "CLRP":
                pin_write(bank, mask, 0x00)
            elif name == "TOGP":
                pin_write(bank, mask, pin_snapshot(bank) ^ 0xFF)
            elif name == "OUTP":
                pin_write(bank, mask, rd(f["rd"]))
            elif name == "INPR":
                wr(f["rd"], pin_snapshot(bank) & mask)
                set_flags(rd(f["rd"]))
            elif name in ("DIRS", "DIRC"):
                # explicit direction control: never triggers auto-OE
                if bank == BANK_UIO:
                    act["oe_we"] |= mask
                    act["oe_val"] = (act["oe_val"] & ~mask) \
                        | (mask if name == "DIRS" else 0)
            elif name in ("ODSET", "ODCLR"):
                if bank == BANK_UIO:
                    act["od_we"] |= mask
                    act["od_val"] = (act["od_val"] & ~mask) \
                        | (mask if name == "ODSET" else 0)

        elif fmt == "waitp":
            bank = f["rs"] & 3
            mask = f["imm"]
            level = (f["rs"] >> 2) & 1
            v = pin_snapshot(bank) & mask
            match = (v == mask) if level else (v == 0)
            if wait_stall(match, (e.timeout_cfg << 8) & ALWAYS):
                if match:                     # timestamp the pin transition,
                    e.ts_event = self.cycle  # not the timeout
                e.wait_active = 0
            else:
                complete = False
                advance = False

        elif fmt == "jmp":
            cond = f["rd"]
            taken = {
                0: True,
                1: bool(e.z),
                2: not e.z,
                3: bool(e.c),
                4: not e.c,
                5: bool(e.n),
                6: bool(e.z),
                7: not e.z,
            }[cond]
            if taken:
                e.pc = f["imm"] & (e.depth - 1)
                advance = False

        elif fmt == "djmp":
            v = (rd(f["rd"]) - 1) & 0xFF
            wr(f["rd"], v)
            set_flags(v)
            if v != 0:
                e.pc = f["imm"] & (e.depth - 1)
                advance = False

        elif fmt == "waitc":
            n = ((f["rs"] << 8) | f["imm"]) & 0x7FF
            if not e.wait_active:
                e.wait_active = 1
                e.wait_left = max(n, 1) - 1
                if e.wait_left > 0:
                    complete = False
                    advance = False
            else:
                e.wait_left -= 1
                if e.wait_left > 0:
                    complete = False
                    advance = False
                else:
                    e.wait_active = 0

        elif fmt == "none":
            if name == "PACE":
                if self.cycle >= e.next:
                    frac = e.next_frac + (e.period & 0xFF)
                    carry = 1 if frac > 0xFF else 0
                    e.next_frac = frac & 0xFF
                    e.next = (e.next + (e.period >> 8) + carry) & ALWAYS
                else:
                    complete = False
                    advance = False
            elif name == "PACERST":
                e.next = self.cycle & ALWAYS
                e.next_frac = 0
            elif name == "HALT":
                e.halted = 1
                e.run = 0
                complete = False
                advance = False
            elif name == "NOP":
                pass
            # unknown opcodes decode as NOP (see module docstring)

        elif fmt == "irq":
            line = f["imm"] & 7
            if name == "IRQSET":
                self.irq |= 1 << line
            elif name == "IRQCLR":
                self.irq &= ~(1 << line) & 0xFF
            elif name == "IRQWAIT":
                if not wait_stall(bool(self.irq & (1 << line)),
                                  (e.timeout_cfg << 8) & ALWAYS):
                    complete = False
                    advance = False

        elif fmt == "bar":
            bid = f["imm"] & 3
            if bid not in self._bar_release:
                complete = False
                advance = False

        elif fmt == "tag":
            self._capture_push(self.cycle, f["imm"] & 0xF, (f["imm"] >> 4) & 1)

        elif fmt == "cfg":
            field_ = f["rs"] & 7
            v = f["imm"]
            if field_ == 0:                      # SIDE
                e.ss_en = (v >> 7) & 1
                e.ss_bank = (v >> 5) & 3
                e.ss_base = (v >> 2) & 7
                e.ss_width = min((v & 3) + 1, 3)
            elif field_ == 1:                    # BITPIN
                e.bp_bank = (v >> 6) & 3
                e.bp_bit = (v >> 3) & 7
                e.bp_inv = (v >> 2) & 1
            elif 2 <= field_ <= 5:               # PERIOD0..3
                sh = 8 * (field_ - 2)
                e.period = (e.period & ~(0xFF << sh)) | (v << sh)
            elif field_ == 6:                    # TIMEOUT
                e.timeout_cfg = v
            # field 7 (SCRATCH) is a no-op in the model
        else:
            raise AssertionError(fmt)

        if complete:
            e.wait_active = 0
        if advance:
            e.pc = (e.pc + 1) % e.depth
        return act

    # -------------------------------------------------------------- capture
    def _capture_push(self, ts: int, pin: int, level: int) -> None:
        if len(self.capture) >= CAPTURE_DEPTH:
            self.capture_overflow = 1
            return
        self.capture.append((ts & ALWAYS, pin & 0xF, level & 1))

    def _capture_cycle(self, uio: int) -> None:
        if not self.capture_en:
            self._prev_capture_pins = uio
            return
        diff = (uio ^ self._prev_capture_pins) & self.capture_en & 0xFF
        self._prev_capture_pins = uio
        if diff:
            bit = (diff & -diff).bit_length() - 1     # lowest changed pin wins
            self._capture_push(self.cycle, bit, (uio >> bit) & 1)

    # ------------------------------------------------------------ collision
    def _update_collision(self) -> None:
        eff = self.oe_eff
        if not eff:
            return
        push_pull = eff & ~self.uio_od & 0xFF
        drive = self.uio_out & eff
        conflict = push_pull & (self.uio_in ^ drive)
        od_low = eff & self.uio_od & 0xFF             # od=1 & out=0 => driving low
        conflict |= od_low & self.uio_in
        self.collision = (self.collision | conflict) & 0xFF

    # -------------------------------------------------------------- helpers
    def run_until(self, pred, max_cycles=100000) -> int:
        n = 0
        while n < max_cycles:
            if pred(self):
                return n
            self.step()
            n += 1
        return n
