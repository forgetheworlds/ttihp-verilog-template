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
  Assists (hybrid v2)
      The five assist blocks are reached through LDAS/STAS/ASST.  The model
      reproduces the *register, queue and timing* accounting that firmware can
      observe: CRC fold (one LFSR bit per cycle, 8 cycles per byte, busy/drop),
      FIFO push/pop/level/burst, shift-register push/pop/step, and the NRZI /
      Manchester transmit-queue occupancy (ready / busy / overflow) at their
      bit timers.  The wire-level line codes (NRZI SYNC/stuffing/SE0, the
      Manchester receiver) are not modelled: they are verified by the RTL
      benches in v2/tb.  A concurrent LDAS of the FIFO DATA by two engines in
      the same cycle returns the same head byte and pops once, matching the
      single read port in src/proteus_assist.v.
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
FIFO_DEPTH = 4                # per-engine in/out FIFO (proteus_engine FIFO_DEPTH)
AS_FIFO_DEPTH = 16            # assist FIFO: src/assist_fifo.v .DEPTH(16) with a
                              # 5-bit level.  A separate constant because the
                              # two blocks really are different depths.
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



# ---------------------------------------------------------------------------
# Assist CSR bank (hybrid v2).  Register map: src/proteus_assist.v header.
# ---------------------------------------------------------------------------
ASSIST_CRC, ASSIST_FIFO, ASSIST_SHIFT, ASSIST_NRZI, ASSIST_MANCH = range(5)


@dataclass
class Assist:
    idx: int
    # CRC
    crc_cfg: int = 0x20            # {lsb, refl, width[5:0]}
    crc_page: int = 0
    crc_init: int = 0xFFFFFFFF
    crc_poly: int = 0x04C11DB7
    crc_xor: int = 0xFFFFFFFF
    crc: int = 0
    fold_left: int = 0             # LFSR bits still to consume
    fold_byte: int = 0
    fold_drop: int = 0
    # FIFO
    fifo: deque = field(default_factory=deque)
    fifo_burstlen: int = 0
    fifo_pops: int = 0
    fifo_burst_done: int = 0
    # SHIFT
    shift_cfg: int = 0xC0          # {dir, width[5:0]=32, en}
    shift_dout: int = 0
    shift_byte_valid: int = 0
    shift_stuff: int = 0
    # NRZI encoder queue / timer
    nrzi_div: int = 32
    nrzi_en: int = 1
    nrzi_cnt: int = 0
    nrzi_q: int = 0
    nrzi_busy: int = 0
    nrzi_bi: int = 0
    nrzi_overflow: int = 0
    nrzi_stuff_err: int = 0
    nrzi_eop: int = 0
    nrzi_sync: int = 0
    nrzi_reset: int = 0
    # MANCH encoder queue / timer
    manch_div: int = 4             # clocks per half-bit (HALF_DIV = 4)
    manch_en: int = 1
    manch_cnt: int = 0
    manch_q: int = 0
    manch_busy: int = 0
    manch_half: int = 0            # half-bits emitted for the byte in flight
    manch_overflow: int = 0

    def __post_init__(self):
        self.fifo = deque(maxlen=None)

    # ------------------------------------------------------------ CRC helpers
    def _crc_width(self) -> int:
        w = self.crc_cfg & 0x3F
        return w if w else 1

    def _crc_bit(self, bit: int) -> None:
        w = self._crc_width()
        mask = (1 << w) - 1
        refl = (self.crc_cfg >> 6) & 1
        if refl:
            fb = (self.crc & 1) ^ bit
            self.crc = (self.crc >> 1) ^ (self.crc_poly & mask if fb else 0)
        else:
            fb = ((self.crc >> (w - 1)) & 1) ^ bit
            self.crc = ((self.crc << 1) & mask) ^                 ((self.crc_poly & mask) if fb else 0)
        self.crc &= mask

    def crc_value(self) -> int:
        return (self.crc & ((1 << self._crc_width()) - 1)) ^ self.crc_xor

    def _fold_start(self, byte: int) -> None:
        if self.fold_left:
            self.fold_drop = 1
        else:
            self.fold_byte = byte & 0xFF
            self.fold_left = 8

    # -------------------------------------------------------------- registers
    def read(self, reg: int) -> int:
        r = reg & 7
        if self.idx == ASSIST_CRC:
            if r == 1:
                return ((1 if self.fold_left else 0) << 7) |                        (self.fold_drop << 1) | (0 if self.fold_left else 1)
            if r == 2:
                return self.crc_cfg
            if r == 3:
                return self.crc_page & 3
            if 4 <= r <= 7:
                v = (self.crc_value(), self.crc_init, self.crc_poly,
                     self.crc_xor)[self.crc_page & 3]
                return (v >> (8 * (r - 4))) & 0xFF
            return 0
        if self.idx == ASSIST_FIFO:
            if r == 0:
                return self.fifo[0] if self.fifo else 0
            if r == 1:
                lvl = len(self.fifo)
                return (1 if lvl >= AS_FIFO_DEPTH else 0) << 6 | (1 if lvl == 0 else 0) << 5 | (lvl & 0x1F)
            if r == 2:
                return self.fifo_burstlen
            if r == 4:
                return self.fifo_pops
            if r == 5:
                return self.fifo_burst_done
            return 0
        if self.idx == ASSIST_SHIFT:
            if r == 0:
                sh8 = max(0, self._shift_width() - 8)
                return ((self.shift_dout >> sh8) if self.shift_cfg & 0x80
                        else self.shift_dout) & 0xFF
            if r == 1:
                return (self.shift_stuff << 7) | self.shift_byte_valid
            if r == 2:
                return self.shift_cfg
            if 4 <= r <= 7:
                return (self.shift_dout >> (8 * (r - 4))) & 0xFF
            return 0
        if self.idx == ASSIST_NRZI:
            if r == 2:
                return (self.nrzi_stuff_err << 7) | (self.nrzi_eop << 6) | \
                       (self.nrzi_sync << 5) | (self.nrzi_busy << 3) | \
                       ((0 if self.nrzi_q else 1) << 2) | \
                       (self.nrzi_overflow << 1) | self.nrzi_reset
            if r == 3:
                return self.nrzi_div & 0x3F
            return 0
        if self.idx == ASSIST_MANCH:
            if r == 2:
                return (self.manch_busy << 4) | \
                       ((0 if self.manch_q else 1) << 3) | (self.manch_overflow << 2)
            if r == 3:
                return (self.manch_div & 0xF) | 0x40   # {HALF_DIV=4, OS=4}
            return 0
        return 0

    def write(self, reg: int, value: int) -> None:
        r = reg & 7
        value &= 0xFF
        if self.idx == ASSIST_CRC:
            if r == 0:
                self._fold_start(value)
            elif r == 2:
                self.crc_cfg = value
            elif r == 3:
                self.cmd(value)
            elif 4 <= r <= 7 and (self.crc_page & 3) != 0:
                sh = 8 * (r - 4)
                page = self.crc_page & 3
                cur = (self.crc_init, self.crc_poly, self.crc_xor)[page - 1]
                cur = (cur & ~(0xFF << sh)) | (value << sh)
                if page == 1:
                    self.crc_init = cur
                elif page == 2:
                    self.crc_poly = cur
                else:
                    self.crc_xor = cur
            return
        if self.idx == ASSIST_FIFO:
            if r == 0:
                if len(self.fifo) < AS_FIFO_DEPTH:
                    self.fifo.append(value)
            elif r == 2:
                self.fifo_burstlen = value & 0x1F
            elif r == 3:
                self.cmd(value)
            return
        if self.idx == ASSIST_SHIFT:
            if r == 0:
                self._shift_push(value)
            elif r == 2:
                self.shift_cfg = value
            elif r == 3:
                self.cmd(value)
            return
        if self.idx == ASSIST_NRZI:
            if r == 0:
                if self.nrzi_q:
                    self.nrzi_overflow = 1
                else:
                    self.nrzi_q = 1
            elif r == 3:
                self.nrzi_div = value & 0x3F
            return
        if self.idx == ASSIST_MANCH:
            if r == 0:
                if self.manch_q:
                    self.manch_overflow = 1
                else:
                    self.manch_q = 1
            return

    def cmd(self, c: int) -> None:
        c &= 0xFF
        if self.idx == ASSIST_CRC:
            if c == 0:
                self.crc_page = 0
            elif c == 1:
                self.crc = self.crc_init & ((1 << self._crc_width()) - 1)
            elif c == 6:
                self._fold_start(0x00)
            elif c in (8, 9, 10):
                self.crc_page = c - 7
            return
        if self.idx == ASSIST_FIFO:
            if (c & 1) or c == 3:
                self.fifo_pops = self.fifo_burstlen
                self.fifo_burst_done = 0
            if (c & 2) or c == 0:
                self.fifo.clear()
                self.fifo_pops = 0
                self.fifo_burst_done = 0
            return
        if self.idx == ASSIST_SHIFT:
            if c == 0:
                self.shift_cfg = 0xC0
                self.shift_dout = 0
            elif c == 1:
                self.shift_cfg |= 1
            elif c == 2:
                self.shift_cfg &= ~1
            elif c == 8:
                self._shift_step()
            return
        if self.idx == ASSIST_NRZI:
            if c == 0:
                self.nrzi_en = 1
                self.nrzi_stuff_err = self.nrzi_eop = 0
                self.nrzi_sync = self.nrzi_reset = 0
            elif c == 1:
                self.nrzi_en = 1
            elif c == 2:
                self.nrzi_en = 0
            elif c == 4:
                self.write(0, 0x80)          # SYNC
            elif c == 5:
                self.nrzi_eop = 1            # packet-end request (no wire model)
            return
        if self.idx == ASSIST_MANCH:
            if c in (0, 1):
                self.manch_en = 1
            elif c == 2:
                self.manch_en = 0
            return

    # ------------------------------------------------------------ shift helpers
    def _shift_width(self) -> int:
        w = (self.shift_cfg >> 1) & 0x3F
        if not w:
            w = 1
        return w

    def _shift_mask(self) -> int:
        w = self._shift_width()
        return 0xFFFFFFFF if w >= 32 else ((1 << w) - 1)

    def _shift_push(self, byte: int) -> None:
        w = self._shift_width()
        mask = self._shift_mask()
        sh8 = max(0, w - 8)
        if self.shift_cfg & 0x80:
            self.shift_dout = ((self.shift_dout & ~(0xFF << sh8)) |
                               (byte << sh8)) & mask
        else:
            self.shift_dout = ((self.shift_dout & ~0xFF) | byte) & mask

    def _shift_step(self) -> None:
        mask = self._shift_mask()
        if self.shift_cfg & 0x80:
            self.shift_dout = (self.shift_dout << 1) & mask
        else:
            self.shift_dout = (self.shift_dout >> 1) & mask

    # ------------------------------------------------------------------ cycle
    def step(self) -> None:
        """Advance one chip cycle of assist-local time (called by the chip)."""
        self.shift_byte_valid = 0

        # CRC: one LFSR step per cycle; a byte is 8 steps.
        if self.fold_left:
            i = 8 - self.fold_left
            bit = (self.fold_byte >> i) & 1 if (self.crc_cfg & 0x80) \
                else (self.fold_byte >> (7 - i)) & 1
            self._crc_bit(bit)
            self.fold_left -= 1
            if not self.fold_left:
                self.fold_drop = 0

        # SHIFT: free-running shift when en is set.
        if self.shift_cfg & 1:
            self._shift_step()

        # NRZI encoder: byte queue + bit timer (line code not modelled).
        div = self.nrzi_div or 1
        self.nrzi_cnt += 1
        if self.nrzi_cnt >= div:
            self.nrzi_cnt = 0
            if self.nrzi_q:
                self.nrzi_q = 0
                self.nrzi_busy = 1
                self.nrzi_bi = 7
            elif self.nrzi_busy:
                self.nrzi_bi -= 1
                if self.nrzi_bi == 0:
                    self.nrzi_busy = 0
        if not self.nrzi_en:
            self.nrzi_busy = 0
            self.nrzi_q = 0

        # Manchester encoder: 16 half-bits per byte.
        div = self.manch_div or 1
        self.manch_cnt += 1
        if self.manch_cnt >= div:
            self.manch_cnt = 0
            if not self.manch_busy:
                if self.manch_q:
                    self.manch_q = 0
                    self.manch_busy = 1
                    self.manch_half = 15
            else:
                self.manch_half -= 1
                if self.manch_half == 0:
                    self.manch_busy = 0
        if not self.manch_en:
            self.manch_busy = 0
            self.manch_q = 0


class ProteusModel:
    def __init__(self, nsms: int = 3, prog_depth: int = PROG_DEPTH):
        if not 1 <= prog_depth <= isa.MAX_PROG_DEPTH:
            raise ValueError(f"prog_depth {prog_depth} outside 1..{isa.MAX_PROG_DEPTH}")
        self.nsms = nsms
        self.prog_depth = prog_depth
        self.cycle = 0
        self.engines = [Engine(i, prog_depth) for i in range(nsms)]
        self.assists = [Assist(i) for i in range(5)]
        self._as_writes: list = []
        self._as_cmds: list = []
        self._as_reads: list = []
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
        self.assists = [Assist(i) for i in range(5)]
        self._as_writes = []
        self._as_cmds = []
        self._as_reads = []
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
        # 0. assist-local time (CRC fold counter, shift, encoder timers)
        for a in self.assists:
            a.step()
        self._as_writes = []
        self._as_cmds = []
        self._as_reads = []

        # 0b. pad contention for the state driven last cycle
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

        # 3b. assist CSR effects latch at the end of the cycle, so a read in
        # the same cycle saw the pre-write value (RTL: one write port, one read
        # port, host wins).
        for (aid, reg, val) in self._as_writes:
            self.assists[aid].write(reg, val)
        for (aid, cv) in self._as_cmds:
            self.assists[aid].cmd(cv)
        if any(a == ASSIST_FIFO and r == 0 for (a, r) in self._as_reads):
            f = self.assists[ASSIST_FIFO]
            if f.fifo:
                f.fifo.popleft()
                if f.fifo_pops:
                    f.fifo_pops -= 1
                    if f.fifo_pops == 0:
                        f.fifo_burst_done = 1

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

        elif fmt == "assist":
            aid = f["imm"] & 7
            reg = f["rs"]
            if name == "LDAS":
                if aid == ASSIST_FIFO and reg == 0 and \
                        not self.assists[ASSIST_FIFO].fifo:
                    e.nf_flag = 1                    # PULLN rule: rd unchanged
                else:
                    wr(f["rd"], self.assists[aid].read(reg))
                    e.nf_flag = 0
                    self._as_reads.append((aid, reg))
            elif name == "STAS":
                self._as_writes.append((aid, reg, rd(f["rd"])))
            else:
                raise AssertionError(name)

        elif fmt == "asst":
            self._as_cmds.append((f["rs"] & 7, f["imm"]))

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
