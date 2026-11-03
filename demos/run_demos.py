#!/usr/bin/env python3
"""PROTEUS demo suite: assemble, run and independently decode three demos.

    python3 demos/run_demos.py            # run everything, compare demos/expected/
    python3 demos/run_demos.py --update   # rewrite the expected/ baselines
    python3 demos/run_demos.py --only ws2812

Everything runs on ``tools/model.py`` (the cycle-accurate golden model).  Each
demo's pin traffic is decoded by a model that shares no code with the firmware
under test -- a 16x-oversampling UART receiver, a pulse-width WS2812 decoder and
a mode-0 SPI checker -- so a pass means the *waveform* is right, not that the
program agreed with itself.

Exit status is non-zero if any check fails or any expected/ baseline differs.

Clock constants
---------------
``CLK_HZ_48`` is the vendor reference clock used for the timing tables in the
firmware headers.  ``CLK_HZ_50`` is the sign-off clock declared in info.yaml,
so every demo that can be retimed is also run at 50 MHz.  The UART demos are
clock independent by construction (the pacer period comes from the host; the
autobaud demo measures it from the wire), and the WS2812 demo has a second
source file for 50 MHz because its pulse widths are immediates.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "tools"))

import asm                                  # noqa: E402
import isa                                  # noqa: E402
import model as _model                      # noqa: E402
from model import ProteusModel              # noqa: E402

#: Per-engine FIFO depth of the build under test (8 today, 4 after the area cut).
FIFO_DEPTH = getattr(_model, "FIFO_DEPTH", 8)

CLK_HZ_48 = 48_000_000
CLK_HZ_50 = 50_000_000

#: The autobaud firmware publishes d = (poll-exit cycle) - (start edge cycle),
#: which is T + 2 or T + 3 depending on the 2-cycle poll phase; the host uses
#: the conservative T = d - 3 (see demos/autobaud_uart_rx.asm).
AUTOBAUD_MEAS_OFFSET = 3

RX_BIT = 1          # UART RX pad, both UART demos
DATA_BIT = 2        # WS2812 data pad
SCK_BIT, MOSI_BIT, CS_BIT = 3, 4, 5


# ---------------------------------------------------------------------------
# Harness: model + resolved pad level + per-cycle host hook
# ---------------------------------------------------------------------------
class Harness:
    """ProteusModel with a resolved UIO pad level and a host-side hook.

    ``uio_in`` is what the world drives into the chip, i.e. the wired-OR of the
    chip's drivers, any external driver and the pull-ups, exactly like a board.
    """

    def __init__(self, pullups: int = 0xFF):
        self.m = ProteusModel()
        self.pullups = pullups & 0xFF
        self.ext_drive = 0
        self.ext_val = 0
        self.trace: list[int] = []
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

    # --- execution --------------------------------------------------------
    def step(self, n: int = 1, hook=None) -> None:
        for _ in range(n):
            self.m.uio_in = self.level()
            self.trace.append(self.m.uio_in)
            self.m.step()
            self.cycle += 1
            if hook is not None:
                hook(self)

    def load(self, prog: dict) -> None:
        for eng, words in prog.items():
            self.m.load(eng, words)

    def edges(self, bit: int, first: int = 0, last: int | None = None):
        last = len(self.trace) if last is None else min(last, len(self.trace))
        out = []
        prev = (self.trace[first] >> bit) & 1
        for t in range(first + 1, last):
            cur = (self.trace[t] >> bit) & 1
            if cur != prev:
                out.append((t, cur))
                prev = cur
        return out


def assemble(name: str) -> dict:
    res = asm.assemble_text((HERE / name).read_text())
    return res["programs"]


# ---------------------------------------------------------------------------
# Peer models (no shared code with the firmware)
# ---------------------------------------------------------------------------
class UartTx:
    """8N1 transmitter with an exactly scheduled waveform.

    Transitions are precomputed on the pacer-free grid the host asks for, i.e.
    bit k of a frame starts at ``round(t0 + k*period)``.  ``push`` may give a
    frame any stop level and any following idle gap, which is what the framing
    error test needs.
    """

    def __init__(self, period: float, bit: int = RX_BIT, start: float = 200.0):
        self.period = float(period)
        self.bit = bit
        self.ev: list[tuple[int, int]] = [(0, 1)]
        self.i = 0
        self.t = float(start)
        self.driven = 1

    def push(self, byte: int, stop: int = 1, gap: float = 0.0) -> "UartTx":
        p, t0 = self.period, self.t
        self._at(int(round(t0)), 0)
        for k in range(8):
            self._at(int(round(t0 + (1 + k) * p)), (byte >> k) & 1)
        self._at(int(round(t0 + 9 * p)), stop)
        self._at(int(round(t0 + 10 * p)), 1)      # idle level after the frame
        self.t = t0 + 10 * p + gap
        return self

    def _at(self, cycle: int, lvl: int) -> None:
        if lvl != self.driven:
            self.ev.append((cycle, lvl))
            self.driven = lvl

    def feed(self, h: Harness) -> None:
        while self.i < len(self.ev) and self.ev[self.i][0] <= h.cycle:
            lvl = self.ev[self.i][1]
            self.i += 1
            h.drive(1 << self.bit, lvl << self.bit)


def decode_uart16(trace, period: float, bit: int = RX_BIT) -> list[dict]:
    """8N1 receiver with 16x oversampling and 3-sample majority voting."""
    n = len(trace)
    lvl = lambda t: (trace[t] >> bit) & 1
    frames = []
    t = 1
    while t < n - 1:
        if lvl(t - 1) == 1 and lvl(t) == 0:
            start = t
            if start + int(round(10.5 * period)) >= n:
                break

            def sample(k: int) -> int:
                centre = start + (k + 0.5) * period
                votes = [lvl(int(round(centre + off)))
                         for off in (-period / 16, 0.0, period / 16)]
                return 1 if sum(votes) >= 2 else 0

            bits = [sample(k) for k in range(10)]
            value = 0
            for k in range(8):
                value |= (bits[1 + k] & 1) << k
            frames.append({"byte": value, "stop": bits[9], "start": start,
                           "ok": bits[0] == 0 and bits[9] == 1})
            t = start + int(round(9.5 * period)) + 1
        else:
            t += 1
    return frames


def ws2812_pulses(trace, bit: int = DATA_BIT):
    """[(rise, width_in_cycles)] for every high pulse the chip drove."""
    pulses = []
    prev = (trace[0] >> bit) & 1
    rise = 0 if prev else None
    for t in range(1, len(trace)):
        cur = (trace[t] >> bit) & 1
        if cur and not prev:
            rise = t
        elif prev and not cur:
            if rise:                       # ignore the undriven pull-up at t=0
                pulses.append((rise, t - rise))
            rise = None
        prev = cur
    return pulses


def decode_spi_mode0(trace, sck=SCK_BIT, mosi=MOSI_BIT, cs=CS_BIT) -> list[dict]:
    """Mode 0: sample MOSI on every SCK rising edge while CS is low."""
    frames, bits = [], []
    prev_sck = (trace[0] >> sck) & 1
    prev_cs = (trace[0] >> cs) & 1
    for t in range(1, len(trace)):
        s = (trace[t] >> sck) & 1
        c = (trace[t] >> cs) & 1
        if prev_cs and not c:              # CS asserted: start a frame
            bits = []
        elif not prev_cs and c:            # CS released: close the frame
            if bits:
                value = 0
                for b in bits:
                    value = (value << 1) | b
                frames.append({"byte": value, "nbits": len(bits)})
            bits = []
        elif not c and not prev_sck and s:  # rising edge inside the frame
            bits.append((trace[t] >> mosi) & 1)
        prev_sck, prev_cs = s, c
    return frames


# ---------------------------------------------------------------------------
# Demo 1: autobaud UART receiver
# ---------------------------------------------------------------------------
def run_autobaud(clk_hz: int, baud: int, data: list[int],
                 framing_error: bool = False) -> dict:
    """Lock on a 0xFF training frame, then decode `data`.

    The host side is the whole register contract of the demo: it forwards the
    two measurement bytes into the pacer (period = T*128, half a bit in 24.8)
    and raises IRQ 0.  It never learns the baud rate.
    """
    prog = assemble("autobaud_uart_rx.asm")[0]
    h = Harness()
    h.load({0: prog})
    period_cycles = clk_hz / baud
    tx = UartTx(period_cycles)
    tx.push(0xFF)                                    # training frame
    if framing_error:
        # a break: all-zero data with a low stop bit, then >= 2 idle frames so
        # the receiver can find the line high again before the next start bit
        tx.push(data[0], stop=0, gap=2.5 * period_cycles)
        for b in data[1:]:
            tx.push(b)
    else:
        for b in data:
            tx.push(b)

    st = {"lo": None, "locked": False, "got": [], "d": None, "irq_at": None,
          "period": None}

    def hook(hh: Harness) -> None:
        fifo = hh.m.engines[0].out_fifo
        while fifo:
            b = hh.m.pop_out(0)
            if not st["locked"]:
                if st["lo"] is None:
                    st["lo"] = b
                else:
                    d = st["lo"] | (b << 8)
                    st["lo"] = None
                    st["d"] = d
                    t_meas = d - AUTOBAUD_MEAS_OFFSET
                    if 1 <= t_meas <= 5000:
                        hh.m.engines[0].period = (t_meas * 128) & 0xFFFFFFFF
                        hh.m.irq |= 1 << 0
                        st["locked"] = True
                        st["irq_at"] = hh.cycle
                        st["period"] = t_meas * 128
            else:
                st["got"].append(b)

    h.m.start(0)
    frames = 1 + len(data)
    h.step(int(frames * 10 * period_cycles) + 4 * int(period_cycles) + 600,
           hook=lambda hh: (tx.feed(hh), hook(hh)))

    decoded = decode_uart16(h.trace, period_cycles)
    sent = list(data)
    # frames[0] is the training frame; everything after it must be the payload
    wire = [f["byte"] for f in decoded]
    trained = len(wire) > len(sent) and wire[0] == 0xFF
    ok = (st["locked"] and st["got"] == sent
          and trained and wire[1:len(sent) + 1] == sent
          and h.m.engines[0].error_flag == (1 if framing_error else 0))
    return {
        "clk": clk_hz, "baud": baud, "T": period_cycles,
        "d": st["d"], "T_meas": None if st["d"] is None else st["d"] - AUTOBAUD_MEAS_OFFSET,
        "period": st["period"], "locked": st["locked"],
        "got": st["got"], "sent": sent, "err": h.m.engines[0].error_flag,
        "decoded": [f["byte"] for f in decoded[1:]],
        "frames": len(decoded), "ok": ok,
    }


# ---------------------------------------------------------------------------
# Demo 2: WS2812
# ---------------------------------------------------------------------------
def run_ws2812(source: str, clk_hz: int, pixels, reset_cycles: int = 2600) -> dict:
    prog = assemble(source)[1]
    period_cycles = clk_hz * 1.25e-6
    period_fixed = int(round(period_cycles * 256))
    h = Harness()
    h.load({1: prog})
    h.m.engines[1].period = period_fixed
    h.m.start(1)
    h.step(64)                                    # CFG SIDE before any traffic

    sent: list[int] = []
    for g, r, b in pixels:
        for byte in (g, r, b):
            h.m.push_in(1, byte)
            sent.append(byte)
        # 24 bits of one pixel, plus slack for the PULL/PACERST preamble
        h.step(int(24 * period_cycles) + 400)
        h.step(reset_cycles)                      # FIFO empty -> line low = reset

    pulses = ws2812_pulses(h.trace)
    widths = [w for _, w in pulses]
    grid = [pulses[i + 1][0] - pulses[i][0]
            for i in range(len(pulses) - 1)
            if (i + 1) % 24]                          # inside one pixel only
    bits = [1 if w > period_cycles / 2 else 0 for w in widths]
    out = []
    for base in range(0, 24 * len(pixels), 24):
        chunk = bits[base:base + 24]
        if len(chunk) < 24:
            break
        for j in range(3):
            v = 0
            for k in range(8):
                v = (v << 1) | chunk[j * 8 + k]
            out.append(v)

    t0h = min(w for w in widths if w < period_cycles / 2) if any(
        w < period_cycles / 2 for w in widths) else None
    t1h = max(widths) if widths else None
    ok = (out == sent and len(pulses) == 24 * len(pixels)
          and all(g in (int(period_cycles) - 1, int(period_cycles)) or
                  abs(g - period_cycles) <= 1 for g in grid))
    return {
        "clk": clk_hz, "source": source, "period_cycles": period_cycles,
        "period_fixed": period_fixed, "pulses": len(pulses),
        "widths": sorted(set(widths)), "t0h": t0h, "t1h": t1h,
        "grid_min": min(grid) if grid else None,
        "grid_max": max(grid) if grid else None,
        "grid_mean": (sum(grid) / len(grid)) if grid else None,
        "sent": sent, "got": out, "ok": ok,
    }


# ---------------------------------------------------------------------------
# Demo 3: barrier-synchronised UART -> SPI bridge
# ---------------------------------------------------------------------------
def run_bridge(clk_hz: int, baud: int, data: list[int]) -> dict:
    progs = assemble("uart_spi_bridge.asm")
    period_cycles = clk_hz / baud
    h = Harness()
    h.load(progs)
    h.m.engines[0].period = int(round(period_cycles / 2 * 256)) & 0xFFFFFFFF
    h.m.engines[1].period = 6 * 256            # half an SCK period: 6 cycles
    tx = UartTx(period_cycles)
    for b in data:
        tx.push(b)
    moved: list[int] = []

    def host(hh: Harness) -> None:
        # The sanely minimal bridge host: react to IRQ 0 only.
        if (hh.m.irq & 1) and hh.m.engines[0].out_fifo \
                and len(hh.m.engines[1].in_fifo) < FIFO_DEPTH:
            moved.append(hh.m.engines[0].out_fifo[0])
            hh.m.push_in(1, hh.m.pop_out(0))

    h.m.start(0)
    h.m.start(1)
    h.step(int(len(data) * 10 * period_cycles) + 8 * int(period_cycles) + 600,
           hook=lambda hh: (tx.feed(hh), host(hh)))

    uart = [f["byte"] for f in decode_uart16(h.trace, period_cycles)
            if f["ok"]]
    spi_frames = decode_spi_mode0(h.trace)
    spi = [f["byte"] for f in spi_frames if f["nbits"] == 8]
    short = [f["nbits"] for f in spi_frames if f["nbits"] != 8]
    ok = (uart == data and spi == data and not short
          and h.m.engines[0].error_flag == 0)
    return {
        "clk": clk_hz, "baud": baud, "T": period_cycles,
        "uart": uart, "spi": spi, "moved": moved, "short": short,
        "frames": len(spi_frames), "err": h.m.engines[0].error_flag, "ok": ok,
    }


# ---------------------------------------------------------------------------
# Pacer capability probe (does not gate the demos)
# ---------------------------------------------------------------------------
def probe_pacer() -> dict:
    """Does PACE survive past the 24-bit deadline boundary?

    Arms the pacer 50 cycles before cycle 2**24 with a period of 100 cycles and
    counts how many cycles 100 PACE completions take.  A model whose deadline
    truncates to 24 bits free-runs (one completion per cycle) after the
    boundary; the 32-bit next_int/next_frac definition keeps ~100 cycles.
    """
    prog = asm.assemble_text(""".engine 0
    PACERST
loop:
    PACE
    JMP loop
""")["programs"][0]
    m = ProteusModel()
    m.load(0, prog)
    e = m.engines[0]
    e.period = 100 * 256
    m.cycle = (1 << 24) - 50
    m.start(0)
    done = 0
    steps = 0
    prev_pc = e.pc
    while done < 100 and steps < 12000:
        m.step()
        steps += 1
        if e.pc != prev_pc and e.pc == 1:
            done += 1
        prev_pc = e.pc
    per = steps / done if done else float("inf")
    return {"completions": done, "cycles": steps, "cycles_per_completion": per,
            "free_run": per < 50.0}


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def hexs(values) -> str:
    return " ".join(f"{v:02x}" for v in values)


def autobaud_text(rows) -> str:
    out = []
    for r in rows:
        out.append(
            f"clk={r['clk']} baud={r['baud']} T={r['T']:.3f} d={r['d']} "
            f"T_meas={r['T_meas']} period_fixed={r['period']} err={r['err']} "
            f"bytes={hexs(r['got'])}")
    return "\n".join(out) + "\n"


def ws2812_text(rows) -> str:
    out = []
    for r in rows:
        out.append(
            f"clk={r['clk']} source={r['source']} period_cycles={r['period_cycles']:.3f} "
            f"period_fixed={r['period_fixed']} t0h={r['t0h']} t1h={r['t1h']} "
            f"widths={r['widths']} grid={r['grid_min']}..{r['grid_max']} "
            f"pixels={hexs(r['got'])}")
    return "\n".join(out) + "\n"


def bridge_text(rows) -> str:
    out = []
    for r in rows:
        out.append(f"clk={r['clk']} baud={r['baud']} T={r['T']:.3f} "
                   f"frames={r['frames']} err={r['err']}")
        out.append(f"uart={hexs(r['uart'])}")
        out.append(f"spi ={hexs(r['spi'])}")
    return "\n".join(out) + "\n"


def save_or_compare(name: str, text: str, update: bool) -> tuple[bool, str]:
    path = HERE / "expected" / name
    if update or not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return True, "written"
    old = path.read_text()
    if old == text:
        return True, "matches"
    return False, "DIFFERS"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="PROTEUS demo suite")
    ap.add_argument("--only", choices=["autobaud", "ws2812", "bridge"],
                    help="run a single demo")
    ap.add_argument("--update", action="store_true",
                    help="rewrite demos/expected/ instead of comparing")
    ap.add_argument("--fifo-depth", type=int, metavar="N",
                    help="model the RTL with per-engine FIFOs of depth N "
                         "(the area cut moves 8 -> 4); every demo must pass "
                         "at 4")
    args = ap.parse_args(argv)
    if args.fifo_depth:
        global FIFO_DEPTH
        FIFO_DEPTH = args.fifo_depth
        _model.FIFO_DEPTH = args.fifo_depth

    failures = 0
    table: list[tuple[str, str, str, str, str]] = []

    # ---- demo 1 ----------------------------------------------------------
    ab_rows = []
    if args.only in (None, "autobaud"):
        plan = [(CLK_HZ_48, 9600, 6), (CLK_HZ_48, 19200, 6),
                (CLK_HZ_48, 57600, 8), (CLK_HZ_48, 115200, 8),
                (CLK_HZ_48, 250000, 8), (CLK_HZ_50, 115200, 8)]
        payload = [0x00, 0xFF, 0x55, 0xAA, 0x01, 0x80, 0x3C, 0x7F]
        for clk, baud, count in plan:
            r = run_autobaud(clk, baud, payload[:count])
            ab_rows.append(r)
            failures += 0 if r["ok"] else 1
            table.append(("autobaud", f"{clk // 1000}k/{baud}",
                          f"d={r['d']} T={r['T_meas']} P={r['period']}",
                          f"{len(r['got'])}/{len(r['sent'])} bytes",
                          "PASS" if r["ok"] else "FAIL"))
        # framing error: torn stop bit must flag E_ERROR and still publish
        r = run_autobaud(CLK_HZ_48, 115200, [0x00, 0xA5], framing_error=True)
        ab_rows.append(r)
        failures += 0 if r["ok"] else 1
        table.append(("autobaud", "115200 framing",
                      f"err={r['err']} d={r['d']}",
                      f"{len(r['got'])}/2 bytes", "PASS" if r["ok"] else "FAIL"))

    # ---- demo 2 ----------------------------------------------------------
    ws_rows = []
    if args.only in (None, "ws2812"):
        plan = [("ws2812.asm", CLK_HZ_48,
                 [(0x11, 0x22, 0x33), (0x00, 0x00, 0x00), (0xFF, 0xFF, 0xFF)]),
                ("ws2812_50mhz.asm", CLK_HZ_50,
                 [(0x11, 0x22, 0x33), (0xAA, 0x55, 0x0F), (0x01, 0x02, 0x04)])]
        for source, clk, pixels in plan:
            r = run_ws2812(source, clk, pixels)
            ws_rows.append(r)
            failures += 0 if r["ok"] else 1
            table.append(("ws2812", f"{clk // 1000}k {source}",
                          f"T0H={r['t0h']} T1H={r['t1h']} "
                          f"P={r['grid_min']}..{r['grid_max']}",
                          f"{len(r['got'])}/9 bytes",
                          "PASS" if r["ok"] else "FAIL"))

    # ---- demo 3 ----------------------------------------------------------
    br_rows = []
    if args.only in (None, "bridge"):
        payload = [(k * 37 + 11) & 0xFF for k in range(32)]
        payload[0], payload[1], payload[2], payload[3] = 0x00, 0xFF, 0x55, 0xAA
        for baud in (115200, 57600):
            r = run_bridge(CLK_HZ_48, baud, payload)
            br_rows.append(r)
            failures += 0 if r["ok"] else 1
            table.append(("bridge", f"48k/{baud}",
                          f"uart={len(r['uart'])} spi={len(r['spi'])} "
                          f"short={len(r['short'])}",
                          f"{len(r['spi'])}/32 bytes",
                          "PASS" if r["ok"] else "FAIL"))

    # ---- expected/ baselines --------------------------------------------
    arte = []
    if ab_rows:
        arte.append(("autobaud_uart_rx.txt", autobaud_text(ab_rows)))
    if ws_rows:
        arte.append(("ws2812.txt", ws2812_text(ws_rows)))
    if br_rows:
        arte.append(("uart_spi_bridge.txt", bridge_text(br_rows)))
    baseline_notes = []
    for name, text in arte:
        ok, note = save_or_compare(name, text, args.update)
        failures += 0 if ok else 1
        baseline_notes.append(f"{name}: {note}")

    # ---- print ----------------------------------------------------------
    print("PROTEUS demo suite -- tools/model.py, independent decoders")
    print(f"  CLK_HZ_48={CLK_HZ_48} CLK_HZ_50={CLK_HZ_50} "
          f"PROG_DEPTH={isa.PROG_DEPTH} FIFO_DEPTH={FIFO_DEPTH}")
    print()
    hdr = ("demo", "config", "measured", "traffic", "result")
    widths = [max(len(str(row[i])) for row in [hdr] + table) for i in range(5)]
    line = "  ".join(h.ljust(w) for h, w in zip(hdr, widths))
    print(line)
    print("  ".join("-" * w for w in widths))
    for row in table:
        print("  ".join(str(c).ljust(w) for c, w in zip(row, widths)))
    print()
    if ab_rows:
        for r in ab_rows:
            print(f"autobaud baud={r['baud']:6d} T={r['T']:7.3f} "
                  f"T_meas={r['T_meas']} period={r['period']} "
                  f"bytes={hexs(r['got'])}")
    if ws_rows:
        for r in ws_rows:
            print(f"ws2812   {r['source']:17s} widths={r['widths']} "
                  f"period={r['grid_min']}..{r['grid_max']} "
                  f"mean={r['grid_mean']:.3f} pixels={hexs(r['got'])}")
    if br_rows:
        for r in br_rows:
            print(f"bridge   baud={r['baud']:6d} uart={hexs(r['uart'])}")
            print(f"                            spi ={hexs(r['spi'])}")
    print()
    p = probe_pacer()
    print(f"pacer probe @cycle 2^24: {p['completions']} completions in "
          f"{p['cycles']} cycles (period=100) -> "
          f"{p['cycles_per_completion']:.1f} cycles/completion: "
          f"{'FREE-RUN (24-bit truncated deadline)' if p['free_run'] else 'exact'}")
    print()
    for note in baseline_notes:
        print(f"baseline {note}")
    print()
    print("RESULT:", "PASS" if failures == 0 else f"FAIL ({failures} check(s))")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
