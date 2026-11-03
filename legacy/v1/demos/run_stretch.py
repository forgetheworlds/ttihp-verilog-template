#!/usr/bin/env python3
"""PROTEUS stretch demo: a JTAG TAP implemented purely in firmware.

The firmware (firmware/jtag_tap.asm, engine 0) is driven over its real pins by
an *independent* IEEE 1149.1 TAP model written here: the model has its own
16-state machine, its own 4-bit IR shift register and 32-bit DR, and only ever
touches TMS / TCK / TDI / TDO at the pad level.  Nothing is shared with the
firmware except the pin names, so a decoder bug cannot hide a firmware bug.

Host timing
    One TAP clock = 40 clk with TCK low, then 40 clk with TCK high.  The
    firmware's longest path between a rising edge and its next "wait for TCK
    low" is 6 instructions, so 40/40 leaves >6x margin.  TDO is sampled just
    before the rising edge, which is when a 1149.1 host samples it.

Contracted checks (these set the exit code)
    * reset: five TMS=1 clocks -> Test-Logic-Reset, then TMS=0 -> Run-Test/Idle
    * Capture-IR loads 0b0001 and a 4-bit IR scan reads it back
    * an IDCODE DR scan reads exactly 0x5B5B5B5B
    * a walk over the twelve TAP states this image implements, with TDO checked
      against the model at every edge where 1149.1 defines it

Measured limitations (printed; they are the documented gap, see
results/stretch.md, and do NOT set the exit code)
    * Pause-DR/Exit2-DR/Pause-IR/Exit2-IR are not modelled
    * BYPASS is not decoded
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "tools"))

import asm                                  # noqa: E402
from model import ProteusModel              # noqa: E402

# ---------------------------------------------------------------------------
# Pin map (firmware/jtag_tap.asm)
# ---------------------------------------------------------------------------
TMS_BIT, TCK_BIT, TDI_BIT, TDO_BIT = 0, 1, 2, 3
PIN_TMS, PIN_TCK, PIN_TDI, PIN_TDO = (1 << TMS_BIT, 1 << TCK_BIT,
                                     1 << TDI_BIT, 1 << TDO_BIT)
HOST_PINS = PIN_TMS | PIN_TCK | PIN_TDI

#: documented bit-pin config for engine 0 (window +0x12): UIO, pin 3, no invert
BITPIN_CFG = 0x98

LOW_CLK = 40        # clk cycles with TCK low
HIGH_CLK = 40       # clk cycles with TCK high

IDCODE = 0x5B5B5B5B
IR_CAPTURE = 0b0001
BYPASS_IR = 0b1111


# ---------------------------------------------------------------------------
# Pad-level harness: the chip model plus the host's pin drivers
# ---------------------------------------------------------------------------
class Bench:
    """ProteusModel with a resolved pad level and a host-side pin driver."""

    def __init__(self, program: list[int], pullups: int = 0xFF):
        self.m = ProteusModel()
        self.m.load(0, program)
        # Host contract: bit-pin cfg 0x98 (bank UIO, pin 3, no invert) written
        # to engine 0 window +0x12 = 0x0012 before RUN.  The cycle model exposes
        # that register as Engine.bp_* (tools/model.py, CFG field 1 encoding).
        e = self.m.engines[0]
        e.bp_bank = (BITPIN_CFG >> 6) & 3
        e.bp_bit = (BITPIN_CFG >> 3) & 7
        e.bp_inv = (BITPIN_CFG >> 2) & 1
        self.pullups = pullups & 0xFF
        self.ext_drive = 0
        self.ext_val = 0
        self.cycle = 0

    # --- pads -------------------------------------------------------------
    def level(self) -> int:
        lvl = self.pullups
        eff = self.m.oe_eff
        lvl = (lvl & ~eff) | (self.m.uio_out & eff)
        lvl = (lvl & ~self.ext_drive) | (self.ext_val & self.ext_drive)
        return lvl & 0xFF

    def drive(self, mask: int, val: int) -> None:
        mask &= 0xFF
        self.ext_drive = (self.ext_drive & ~mask) | mask
        self.ext_val = (self.ext_val & ~mask) | (val & mask)

    def step(self, n: int = 1) -> None:
        for _ in range(n):
            self.m.uio_in = self.level()
            self.m.step()
            self.cycle += 1

    # --- chip outputs -----------------------------------------------------
    def tdo(self) -> int:
        """The level the chip drives on TDO (push-pull value)."""
        return 1 if (self.m.uio_out & PIN_TDO) else 0

    def tdo_oe(self) -> int:
        return 1 if (self.m.oe_eff & PIN_TDO) else 0

    def start(self) -> None:
        self.m.start(0)


# ---------------------------------------------------------------------------
# Independent IEEE 1149.1 TAP model
# ---------------------------------------------------------------------------
TLR, RTI, SEL_DR, CAP_DR, SH_DR, EX1_DR, PAUSE_DR, EX2_DR, UPD_DR = range(9)
SEL_IR, CAP_IR, SH_IR, EX1_IR, PAUSE_IR, EX2_IR, UPD_IR = range(9, 16)

STATE_NAMES = [
    "Test-Logic-Reset", "Run-Test/Idle", "Select-DR", "Capture-DR", "Shift-DR",
    "Exit1-DR", "Pause-DR", "Exit2-DR", "Update-DR", "Select-IR",
    "Capture-IR", "Shift-IR", "Exit1-IR", "Pause-IR", "Exit2-IR", "Update-IR",
]

#: (state, TMS) -> next state  (IEEE 1149.1 figure 4-1)
NEXT = {
    (TLR, 0): RTI,         (TLR, 1): TLR,
    (RTI, 0): RTI,         (RTI, 1): SEL_DR,
    (SEL_DR, 0): CAP_DR,   (SEL_DR, 1): SEL_IR,
    (CAP_DR, 0): SH_DR,    (CAP_DR, 1): EX1_DR,
    (SH_DR, 0): SH_DR,     (SH_DR, 1): EX1_DR,
    (EX1_DR, 0): PAUSE_DR, (EX1_DR, 1): UPD_DR,
    (PAUSE_DR, 0): PAUSE_DR, (PAUSE_DR, 1): EX2_DR,
    (EX2_DR, 0): SH_DR,    (EX2_DR, 1): UPD_DR,
    (UPD_DR, 0): RTI,      (UPD_DR, 1): SEL_DR,
    (SEL_IR, 0): CAP_IR,   (SEL_IR, 1): TLR,
    (CAP_IR, 0): SH_IR,    (CAP_IR, 1): EX1_IR,
    (SH_IR, 0): SH_IR,     (SH_IR, 1): EX1_IR,
    (EX1_IR, 0): PAUSE_IR, (EX1_IR, 1): UPD_IR,
    (PAUSE_IR, 0): PAUSE_IR, (PAUSE_IR, 1): EX2_IR,
    (EX2_IR, 0): SH_IR,    (EX2_IR, 1): UPD_IR,
    (UPD_IR, 0): RTI,      (UPD_IR, 1): SEL_DR,
}

#: the twelve states the firmware image implements
IMPLEMENTED_NAMES = ["Test-Logic-Reset", "Run-Test/Idle", "Select-DR",
                     "Capture-DR", "Shift-DR", "Exit1-DR", "Update-DR",
                     "Select-IR", "Capture-IR", "Shift-IR", "Exit1-IR",
                     "Update-IR"]


class TapModel:
    """A 1149.1 TAP state machine plus the host's pin traffic.

    ``clock(tms, tdi)`` drives one TCK cycle and returns ``(tdo, state_before)``
    -- the bit the host samples on that rising edge, and the state the TAP was
    in when it happened.  ``tdo`` is the *device* level, so every comparison is
    device-versus-model.
    """

    def __init__(self, bench: Bench, idcode: int = IDCODE,
                 low: int = LOW_CLK, high: int = HIGH_CLK):
        self.b = bench
        self.low = low
        self.high = high
        self.idcode = idcode
        self.state = TLR
        self.ir = IR_CAPTURE        # latched instruction (taken at Update-IR)
        self.ir_sr = IR_CAPTURE     # IR shift register
        self.dr_sr = idcode         # DR shift register
        self.bypass = 0             # BYPASS register holds the last TDI
        self.oe = 0                 # TDO output-enable at the last sample
        self.trace: list[tuple[int, int, int]] = []

    # --- one TCK cycle ----------------------------------------------------
    def clock(self, tms: int, tdi: int = 0) -> tuple[int, int]:
        b = self.b
        before = self.state
        pattern = (tms << TMS_BIT) | (tdi << TDI_BIT)
        b.drive(HOST_PINS, pattern)              # TCK low
        b.step(self.low)
        tdo = b.tdo()                            # host samples here
        self.oe = b.tdo_oe()
        b.drive(HOST_PINS, pattern | PIN_TCK)    # TCK rising edge
        b.step(self.high)
        b.drive(HOST_PINS, pattern)
        self._advance(tms, tdi)
        self.trace.append((before, tms, tdo))
        return tdo, before

    def _advance(self, tms: int, tdi: int) -> None:
        st = self.state
        if st == SH_DR:
            if self.ir == BYPASS_IR:
                self.dr_sr = tdi
            else:
                self.dr_sr = ((self.dr_sr >> 1) | (tdi << 31)) & 0xFFFFFFFF
        elif st == SH_IR:
            self.ir_sr = ((self.ir_sr >> 1) | (tdi << 3)) & 0xF
        nxt = NEXT[(st, tms)]
        if nxt == CAP_DR:
            self.dr_sr = self.bypass if self.ir == BYPASS_IR else self.idcode
        elif nxt == CAP_IR:
            self.ir_sr = IR_CAPTURE
        if nxt == UPD_IR:
            self.ir = self.ir_sr                 # Update-IR latches the IR
        self.state = nxt

    # --- host scan helpers (last data bit carries TMS=1, as 1149.1 hosts do)
    def reset(self) -> None:
        for _ in range(5):
            self.clock(1)

    def to_idle(self) -> None:
        self.clock(0)

    def leave_scan(self) -> None:
        """Exit1 (already reached) -> Update -> Run-Test/Idle."""
        self.clock(1)
        self.clock(0)

    def scan_ir(self, value: int, width: int = 4) -> int:
        """One IR scan from Run-Test/Idle; returns the bits shifted out."""
        self.clock(1)                            # RTI  -> Select-DR
        self.clock(1)                            # S-DR -> Select-IR
        self.clock(0)                            # S-IR -> Capture-IR
        self.clock(0)                            # C-IR -> Shift-IR
        out = 0
        for k in range(width):
            last = k == width - 1
            bit, _ = self.clock(1 if last else 0, (value >> k) & 1)
            out |= bit << k
        return out

    def scan_dr(self, width: int = 32, tdi_value: int = 0) -> tuple[int, list[int]]:
        """One DR scan from Run-Test/Idle; returns (value, per-bit samples)."""
        self.clock(1)                            # RTI  -> Select-DR
        self.clock(0)                            # S-DR -> Capture-DR
        self.clock(0)                            # C-DR -> Shift-DR
        out = 0
        bits: list[int] = []
        for k in range(width):
            last = k == width - 1
            bit, _ = self.clock(1 if last else 0, (tdi_value >> k) & 1)
            bits.append(bit)
            out |= bit << k
        return out, bits


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
def fresh(program: list[int]) -> Bench:
    b = Bench(program)
    b.start()
    b.drive(HOST_PINS, 0)                        # TCK low, TMS/TDI low
    b.step(LOW_CLK)
    return b


def check_reset(program: list[int]) -> dict:
    tap = TapModel(fresh(program))
    tap.reset()
    after_reset = tap.state
    tap.clock(0)
    after_zero = tap.state
    return {
        "name": "reset: 5 x TMS=1 -> Test-Logic-Reset",
        "ok": after_reset == TLR and after_zero == RTI,
        "detail": f"{STATE_NAMES[after_reset]}, then TMS=0 -> "
                  f"{STATE_NAMES[after_zero]}",
    }


def check_ir(program: list[int]) -> dict:
    tap = TapModel(fresh(program))
    tap.reset()
    tap.to_idle()
    seen = tap.scan_ir(BYPASS_IR)                # ask for BYPASS, read capture
    return {
        "name": "Capture-IR + 4-bit IR scan reads 0b0001",
        "ok": seen == IR_CAPTURE,
        "detail": f"device read {seen:04b}, model expects {IR_CAPTURE:04b}",
    }


def check_idcode(program: list[int]) -> dict:
    tap = TapModel(fresh(program))
    tap.reset()
    tap.to_idle()
    tap.scan_ir(IR_CAPTURE)
    tap.leave_scan()
    value, bits = tap.scan_dr(32)
    return {
        "name": "IDCODE DR scan, 32 bits",
        "ok": value == IDCODE,
        "detail": f"read 0x{value:08X}, expected 0x{IDCODE:08X}; "
                  f"first bits {' '.join(map(str, bits[:8]))}",
    }


def check_walk(program: list[int]) -> dict:
    """Walk the twelve implemented states, checking TDO where 1149.1 defines it."""
    tap = TapModel(fresh(program))
    seq = (
        [1] * 5                                  # Test-Logic-Reset (stays)
        + [0]                                    # -> Run-Test/Idle
        + [1]                                    # -> Select-DR
        + [0]                                    # -> Capture-DR
        + [0]                                    # -> Shift-DR
        + [0, 0]                                 # two IDCODE shift clocks
        + [1]                                    # -> Exit1-DR
        + [1]                                    # -> Update-DR
        + [1]                                    # -> Select-DR
        + [1]                                    # -> Select-IR
        + [0]                                    # -> Capture-IR
        + [0]                                    # -> Shift-IR
        + [0, 0]                                 # two IR shift clocks
        + [1]                                    # -> Exit1-IR
        + [1]                                    # -> Update-IR
        + [0]                                    # -> Run-Test/Idle
        + [1] * 5                                # -> Test-Logic-Reset
    )
    mismatches = []
    visited = []
    for tms in seq:
        before = tap.state
        visited.append(before)
        exp = None
        if before == SH_DR:
            exp = (tap.bypass if tap.ir == BYPASS_IR else tap.dr_sr) & 1
        elif before == SH_IR:
            exp = tap.ir_sr & 1
        tdo, _ = tap.clock(tms)
        if exp is not None and tdo != exp:
            mismatches.append((STATE_NAMES[before], exp, tdo))
    seen = [STATE_NAMES[s] for s in visited]
    missing = [n for n in IMPLEMENTED_NAMES if n not in set(seen)]
    return {
        "name": "TAP state walk, 12 implemented states, TDO checked",
        "ok": not mismatches and not missing,
        "detail": (f"{len(set(seen))}/12 states visited over {len(seq)} TCK "
                   f"edges"
                   + (f"; TDO mismatch at {mismatches}" if mismatches else "")
                   + (f"; never visited {missing}" if missing else "")),
        "states": sorted(set(seen)),
    }


def check_drive(program: list[int]) -> dict:
    """TDO must be push-pull: OE set on every edge the host samples."""
    tap = TapModel(fresh(program))
    tap.reset()
    tap.to_idle()
    tap.scan_ir(IR_CAPTURE)
    tap.leave_scan()
    value, bits = tap.scan_dr(32)
    oes = [oe for _, _, _, oe in
           [(s_, t_, tdo_, tap.oe) for s_, t_, tdo_ in tap.trace]]
    return {
        "name": "TDO driven push-pull (OE) on every sampled edge",
        "ok": value == IDCODE and all(oes),
        "detail": f"OE=1 on {sum(oes)}/{len(oes)} TCK edges of the DR scan",
    }


def measure_timing(program: list[int]) -> dict:
    """Smallest TCK phase that still reads IDCODE = the real margin."""
    def works(low: int, high: int) -> bool:
        tap = TapModel(fresh(program), low=low, high=high)
        tap.reset()
        tap.to_idle()
        tap.scan_ir(IR_CAPTURE)
        tap.leave_scan()
        value, _ = tap.scan_dr(32)
        return value == IDCODE

    min_both = next(n for n in range(1, 41) if works(n, n))
    min_high = next(n for n in range(1, 41) if works(2, n))
    min_low = next(n for n in range(1, 41) if works(n, 40))
    return {
        "name": "timing margin (smallest TCK phase that still reads IDCODE)",
        "ok": min_both <= 40,
        "detail": f"LOW=HIGH>={min_both} clk, HIGH>={min_high} clk with LOW=2, "
                  f"LOW>={min_low} clk with HIGH=40; shipped {LOW_CLK}/{HIGH_CLK}",
    }


# ---------------------------------------------------------------------------
# Measured limitations (device versus model, so the gap is a number)
# ---------------------------------------------------------------------------
def probe_bypass(program: list[int]) -> dict:
    """BYPASS needs TDI capture; this image does not decode the IR."""
    tap = TapModel(fresh(program))
    tap.reset()
    tap.to_idle()
    tap.scan_ir(BYPASS_IR)
    tap.leave_scan()
    expect = tap.bypass                           # 1-bit BYPASS register
    got, _ = tap.clock(1)                         # RTI -> Select-DR
    got, _ = tap.clock(0)                         # -> Capture-DR
    got, _ = tap.clock(0)                         # -> Shift-DR
    got, _ = tap.clock(0)                         # first (only) DR bit
    return {
        "name": "BYPASS (IR=0b1111): 1-bit DR",
        "ok": got == expect,
        "detail": f"model expects {expect} (1-bit bypass), device sent {got} "
                  f"(IDCODE bit 0 = {IDCODE & 1}) -> IR not decoded",
    }


def probe_pause(program: list[int]) -> dict:
    """Pause is folded into Exit1, so a Pause re-entry cannot reach Shift."""
    tap = TapModel(fresh(program))
    tap.reset()
    tap.to_idle()
    tap.scan_ir(IR_CAPTURE)
    tap.leave_scan()
    for tms in (1, 0, 0, 0, 0):                   # -> SelDR, CapDR, 3 DR bits
        tap.clock(tms)
    tap.clock(1)                                  # -> Exit1-DR
    tap.clock(0)                                  # host: -> Pause-DR
    tap.clock(1)                                  # host: -> Exit2-DR
    tap.clock(0)                                  # host: -> Shift-DR again
    dev, mod = [], []
    for _ in range(4):
        exp = tap.dr_sr & 1                       # model is in Shift-DR here
        got, _ = tap.clock(0)
        dev.append(got)
        mod.append(exp)
    mism = sum(1 for a, b in zip(dev, mod) if a != b)
    return {
        "name": "Pause-DR -> Exit2-DR -> Shift-DR re-entry",
        "ok": mism == 0,
        "detail": f"model re-entered Shift-DR and expected {mod}, device sent "
                  f"{dev}: {mism}/4 bits differ",
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def assemble() -> list[int]:
    res = asm.assemble_file(str(REPO / "firmware" / "jtag_tap.asm"))
    return list(res["programs"][0])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="PROTEUS JTAG TAP stretch demo")
    ap.add_argument("--words", action="store_true",
                    help="only print the assembled word count")
    args = ap.parse_args(argv)

    program = assemble()
    if args.words:
        print(f"engine 0: {len(program)} words")
        return 0

    print("PROTEUS stretch: JTAG TAP implemented in firmware")
    print("=" * 78)
    print(f"image         firmware/jtag_tap.asm, engine 0, {len(program)} words")
    print(f"IDCODE        0x{IDCODE:08X}  (bit 0 = 1, byte-periodic)")
    print("pins          TMS=UIO[0]  TCK=UIO[1]  TDI=UIO[2]  TDO=UIO[3]")
    print(f"host timing   TCK {LOW_CLK} clk low / {HIGH_CLK} clk high; TDO "
          f"sampled at the rising edge")
    print(f"bit-pin cfg   host writes 0x{BITPIN_CFG:02X} to 0x0012 before RUN")
    print()

    results = [
        check_reset(program),
        check_ir(program),
        check_idcode(program),
        check_walk(program),
        check_drive(program),
        measure_timing(program),
    ]
    print("contracted checks")
    print("-" * 78)
    for r in results:
        print(f"{'PASS' if r['ok'] else 'FAIL'}  {r['name']}")
        print(f"      {r['detail']}")
    print()

    print("measured limitations (not modelled by this 32-word image)")
    print("-" * 78)
    for p in (probe_bypass(program), probe_pause(program)):
        print(f"{'ok  ' if p['ok'] else 'GAP '}  {p['name']}")
        print(f"      {p['detail']}")
    print()

    failures = [r for r in results if not r["ok"]]
    print("=" * 78)
    print(f"word budget   32 (build) / {len(program)} used")
    print(f"contracted    {'PASS' if not failures else 'FAIL'}"
          f"  ({len(results) - len(failures)}/{len(results)} checks)")
    print("not implemented  Pause-DR, Exit2-DR, Pause-IR, Exit2-IR, BYPASS, "
          "TDI capture")
    print("accounting     results/stretch.md")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
