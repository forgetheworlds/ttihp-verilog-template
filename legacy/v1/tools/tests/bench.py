"""Test harness: run the cycle model with a resolved UIO pad level.

The model's ``uio_in`` is "what the world drives into the chip".  On a real
board every UIO pad is the wired-OR of the chip's drivers, any external
drivers and the pull-ups, so the harness resolves that level every cycle and
feeds it back.  External devices (UART transmitter, SPI slave, I2C target) are
plain callables that see the resolved level after each cycle and may drive or
release pads for the next cycle.
"""

from __future__ import annotations

import model
from model import ProteusModel


class Bench:
    """ProteusModel + resolved pad level + external device hooks."""

    def __init__(self, prog_depth=model.PROG_DEPTH, pullups=0xFF, device=None):
        self.m = ProteusModel(prog_depth=prog_depth)
        self.pullups = pullups & 0xFF
        self.device = device
        self.ext_drive = 0          # bits the external world drives
        self.ext_val = 0            # their level
        self.trace = []             # resolved uio level per cycle
        self.ui_trace = []
        self.cycle = 0

    # ---------------------------------------------------------------- pads
    def level(self) -> int:
        """Resolve the UIO pad level from pull-ups, chip drivers and devices."""
        lvl = self.pullups
        eff = self.m.oe_eff
        lvl = (lvl & ~eff) | (self.m.uio_out & eff)
        lvl = (lvl & ~self.ext_drive) | (self.ext_val & self.ext_drive)
        return lvl & 0xFF

    def drive(self, mask: int, val: int) -> None:
        mask &= 0xFF
        self.ext_drive = (self.ext_drive & ~mask) | mask
        self.ext_val = (self.ext_val & ~mask) | (val & mask)

    def release(self, mask: int) -> None:
        self.ext_drive &= ~(mask & 0xFF)

    def pin(self, bit: int, cycle: int = None) -> int:
        """Resolved level of one pad at a cycle (default: the latest cycle)."""
        t = self.cycle - 1 if cycle is None else cycle
        return (self.trace[t] >> bit) & 1

    # ---------------------------------------------------------------- run
    def step(self, n: int = 1) -> None:
        for _ in range(n):
            self.m.uio_in = self.level()
            self.trace.append(self.m.uio_in)
            self.ui_trace.append(self.m.ui_in)
            self.m.step()
            self.cycle += 1
            if self.device is not None:
                self.device(self, self.level())

    def pump(self, cycles, feed=None, collect=None, device=None):
        """Step while feeding and draining FIFOs so they never stall the DUT.

        feed    : {engine: list}    bytes pushed whenever the FIFO has room
        collect : {engine: list}    bytes popped every cycle into the list
        device  : temporary external device model (None keeps the current one)
        """
        feed = feed or {}
        collect = collect or {}
        old_device = self.device
        if device is not None:
            self.device = device
        try:
            for _ in range(cycles):
                for eng, q in feed.items():
                    while q and self.m.push_in(eng, q[0]):
                        q.pop(0)
                self.step()
                for eng, out in collect.items():
                    v = self.m.pop_out(eng)
                    while v is not None:
                        out.append(v)
                        v = self.m.pop_out(eng)
        finally:
            self.device = old_device

    def run_until(self, pred, max_cycles=200000) -> bool:
        for _ in range(max_cycles):
            if pred(self):
                return True
            self.step()
        return False

    # ------------------------------------------------------------- helpers
    def load(self, eng: int, words) -> None:
        self.m.load(eng, words)

    def start(self, eng: int) -> None:
        self.m.start(eng)

    def edges(self, bit: int, first: int = 0, last: int = None):
        """[(cycle, level)] for every transition of a pad."""
        last = len(self.trace) if last is None else last
        out = []
        prev = (self.trace[first] >> bit) & 1
        for c in range(first + 1, last):
            lvl = (self.trace[c] >> bit) & 1
            if lvl != prev:
                out.append((c, lvl))
                prev = lvl
        return out


def assemble(path, depth=model.PROG_DEPTH):
    """Assemble a firmware file (depth must match the build parameter)."""
    import asm
    from pathlib import Path
    return asm.assemble_text(Path(path).read_text(), depth)
