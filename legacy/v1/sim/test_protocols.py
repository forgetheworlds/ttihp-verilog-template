"""PROTEUS protocol E2E on the real RTL: real firmware, pin-level bus models.

Closes the gap that ``tools/tests/test_firmware.py`` leaves open: that suite
runs the firmware on the cycle model.  Here the *actual* ``tt_um_proteus`` RTL
at the default ``PROG_DEPTH = 32`` executes the same ``firmware/*.asm`` images,
loaded over the real host SPI port at 50 MHz (20 ns clock, ``info.yaml``
``clock_hz``), and every protocol assertion is decoded from the pads by an
independent model in this file:

  * UART TX (engine 0, UIO0) -- 16x-oversampling 8N1 receiver, exact bytes,
    start/stop bit widths and frame pacing measured at the pad.
  * UART RX (engine 1, UIO1) -- independent 8N1 transmitter with random
    inter-byte gaps, including a framing-error frame; bytes popped from the
    engine's OUT_FIFO must equal the transmitted bytes.
  * SPI master (engine 2, mode 0) -- slave on SCK=UIO2/MOSI=UIO3/MISO=UIO4/
    CS=UIO5 returning the bitwise complement of the byte it receives; the
    model checks CPOL/CPHA edge order, CS framing, 16 edges per transfer and
    byte order, and the OUT_FIFO echo.
  * I2C master (engines 3+2, SCL=UIO6/SDA=UIO7, open drain + pull-ups) --
    7-bit target at 0x50 with START/repeated-START/STOP detection, ACK/NACK,
    data, and clock stretching.  A single transaction writes address + 2 data
    bytes, then repeated START, reads address + 2 bytes (ACK then NACK) and
    STOPs.

Pad resolution mirrors ``tools/tests/bench.py``: pull-ups everywhere, the
chip's effective drive (``uio_oe`` already has the open-drain release folded
in by the RTL) overrides the pull-up, external devices override for the bits
they drive, and every external device sees the resolved level *before* its own
new drive.  Nothing in the assertions reads engine state; the only hierarchy
accesses are the pad ports themselves (``uio_out``/``uio_oe``), which the
Verilog testbenches also read.

Host contract (``firmware/README.md``): one FIFO byte per SPI frame, poll
``E_STATUS.in_full`` (bit 3) before each push, drain ``OUT_FIFO`` one byte per
frame.  FIFO depth in this build is 4 (``proteus_engine.FIFO_DEPTH``), so the
I2C host feeder pushes one command slot per engine per bus operation as the
engines drain them, instead of preloading the whole 13-byte engine-3 stream.
"""

from __future__ import annotations

import random
from pathlib import Path

import cocotb
from cocotb.triggers import FallingEdge

import asm
from host import (
    EO_ERROR,
    EO_PERIOD0,
    EO_R0,
    EO_STATUS,
    ProteusHost,
    RA_COLLISION,
    RA_RUN,
    eng_reg,
    reset,
    start_clock,
)

# ---------------------------------------------------------------------------
# Timing constants (info.yaml clock_hz = 50 MHz)
# ---------------------------------------------------------------------------
CLK_NS = 20.0
CLK_HZ = 50_000_000
UART_BAUD = 115_200
UART_BIT = CLK_HZ / UART_BAUD                    # 434.02777.. cycles
UART_PERIOD = 111111 / 256.0                     # 434.02734 cycles (0x0001B207)
UART_RX_PERIOD = 55556 / 256.0                   # 217.015625 cycles (0x00D904)
SPI_HALF_BIT = CLK_HZ // 2_000_000               # 25 cycles -> 1 MHz SCLK
I2C_PERIOD = CLK_HZ // 200_000                   # 250 cycles -> 100 kHz SCL
I2C_HALF = 250                                   # WAITC I2C_HALF in the image
I2C_MIN_HIGH = 40                                # fast-mode t_HIGH 0.6 us = 30
I2C_MIN_LOW = 65                                 # fast-mode t_LOW 1.3 us
I2C_MIN_SETUP = 40                               # START/STOP setup and hold
RA_UIO_OD = 0x0523                               # fabric-wide open-drain cfg

# UIO pad map
UART_TX_BIT = 0
UART_RX_BIT = 1
SPI_SCK_BIT = 2
SPI_MOSI_BIT = 3
SPI_MISO_BIT = 4
SPI_CS_BIT = 5
I2C_SCL_BIT = 6
I2C_SDA_BIT = 7

FIRMWARE_DIR = Path(__file__).resolve().parents[1] / "firmware"

# E_STATUS bits (docs/architecture.md sec. 6)
ST_IN_EMPTY = 0x04
ST_IN_FULL = 0x08
ST_OUT_EMPTY = 0x10


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def safe_int(handle) -> int:
    try:
        return int(handle.value)
    except ValueError:  # X/Z before the pads settle
        return 0


def load_firmware(engine: int, name: str) -> list[int]:
    with open(FIRMWARE_DIR / name) as f:
        res = asm.assemble_text(f.read(), 32)
    words = res["programs"][engine]
    assert len(words) <= 32, (name, engine, len(words))
    return words


class Checker:
    """Collect failures per phase and raise once, listing all of them."""

    def __init__(self) -> None:
        self.checks = 0
        self.fails: list[str] = []

    def eq(self, got, exp, what: str) -> None:
        self.checks += 1
        if got != exp:
            self.fails.append(f"{what}: got {got!r} expected {exp!r}")

    def true(self, cond: bool, what: str) -> None:
        self.checks += 1
        if not cond:
            self.fails.append(what)

    def near(self, got, exp, tol, what: str) -> None:
        self.checks += 1
        if abs(got - exp) > tol:
            self.fails.append(f"{what}: got {got!r} expected {exp!r} +-{tol}")

    def done(self, phase: str) -> None:
        assert not self.fails, (
            f"{phase}: {len(self.fails)} of {self.checks} checks failed: "
            + " | ".join(self.fails[:12])
        )
        cocotb.log.info("%s: %d checks ok", phase, self.checks)
        self.checks = 0
        self.fails = []


class PinBench:
    """Resolve the uio pads every clock and run one external device model.

    Semantics match ``tools/tests/bench.py``: at each clock the device sees the
    resolved level computed from the chip's current outputs and its own
    previous drive, may update its drive, and the resulting level is what the
    chip samples on the next posedge.  ``trace[k]`` is that sampled level.
    """

    def __init__(self, dut, pullups: int = 0xFF):
        self.dut = dut
        self.pullups = pullups & 0xFF
        self.ext_mask = 0
        self.ext_val = 0
        self.device = None
        self.trace: list[int] = []
        self.cycle = 0
        self._task = None

    # -- external drive (push-pull or open-drain pull-low)
    def drive(self, mask: int, val: int) -> None:
        mask &= 0xFF
        self.ext_mask = (self.ext_mask & ~mask) | mask
        self.ext_val = (self.ext_val & ~mask) | (val & mask)

    def release(self, mask: int) -> None:
        self.ext_mask &= ~(mask & 0xFF)

    def level(self) -> int:
        out = safe_int(self.dut.uio_out)
        oe = safe_int(self.dut.uio_oe)   # already open-drain released
        lvl = (self.pullups & ~oe) | (out & oe)
        lvl = (lvl & ~self.ext_mask) | (self.ext_val & self.ext_mask)
        return lvl & 0xFF

    async def _run(self) -> None:
        self.dut.uio_in.value = self.level()
        await FallingEdge(self.dut.clk)
        while True:
            pre = self.level()
            if self.device is not None:
                self.device(self, pre)
            lvl = self.level()
            self.dut.uio_in.value = lvl
            self.trace.append(lvl)
            self.cycle += 1
            await FallingEdge(self.dut.clk)

    def start(self) -> None:
        self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        if self._task is not None:
            try:
                self._task.cancel()
            except AttributeError:
                self._task.kill()
            self._task = None


async def wait_cycles(dut, n: int) -> None:
    for _ in range(n):
        await FallingEdge(dut.clk)


async def push_wait(host, engine: int, value: int, tries: int = 400) -> None:
    """Push one byte after polling E_STATUS.in_full (one byte per frame)."""
    for _ in range(tries):
        st = await host.read_reg(eng_reg(engine, EO_STATUS))
        if not (st & ST_IN_FULL):
            await host.push_in(engine, value)
            return
    raise AssertionError(f"engine {engine} IN_FIFO stayed full")


async def wait_out(host, engine: int, tries: int = 400) -> int:
    for _ in range(tries):
        st = await host.read_reg(eng_reg(engine, EO_STATUS))
        if not (st & ST_OUT_EMPTY):
            return await host.pop_out(engine)
    raise AssertionError(f"engine {engine} OUT_FIFO stayed empty")


# ---------------------------------------------------------------------------
# UART: 16x-oversampling 8N1 receiver (independent of the firmware/model)
# ---------------------------------------------------------------------------
def decode_uart16(trace, period: float, bit: int = 0) -> list[dict]:
    """Decode 8N1 with a 16x receiver: 16-vote majority per bit slot."""
    frames = []
    n = len(trace)
    lvl = lambda t: (trace[t] >> bit) & 1
    i = 1
    while i < n:
        if not (lvl(i - 1) == 1 and lvl(i) == 0):
            i += 1
            continue
        start = i
        slots = []
        ok = True
        for k in range(10):
            votes = 0
            for s in range(16):
                t = int(round(start + (k + (s + 0.5) / 16.0) * period))
                if t >= n:
                    ok = False
                    break
                votes += lvl(t)
            if not ok:
                break
            slots.append(1 if votes >= 8 else 0)
        if not ok:
            break
        if slots[0] != 0:          # not a start bit after all
            i += 1
            continue
        byte = sum(slots[1 + k] << k for k in range(8))
        frames.append({
            "start": start,
            "byte": byte,
            "stop": slots[9],
            "slots": slots,
        })
        i = start + int(round(9.5 * period)) + 1
    return frames


def uart_transitions(trace, bit: int, lo: int, hi: int) -> list[tuple[int, int]]:
    out = []
    prev = (trace[lo] >> bit) & 1
    for t in range(lo + 1, min(hi, len(trace))):
        cur = (trace[t] >> bit) & 1
        if cur != prev:
            out.append((t, cur))
            prev = cur
    return out


# ---------------------------------------------------------------------------
# UART transmitter model for the RX test (random inter-byte gaps)
# ---------------------------------------------------------------------------
class UartSource:
    """8N1 waveform generator with per-frame start times and stop levels.

    ``frames`` is ``[(start_cycle, byte, stop_level), ...]`` sorted by start;
    the line idles high elsewhere.  Bit positions are fractional, so the
    waveform is the ideal 115200-baud schedule independent of the DUT.
    """

    def __init__(self, bit: int, bit_time: float, frames):
        self.bit = bit
        self.bit_time = float(bit_time)
        self.frames = sorted(frames)
        self.i = 0

    def level_at(self, t: int) -> int:
        while (self.i < len(self.frames) and
               t >= self.frames[self.i][0] + 10 * self.bit_time):
            self.i += 1
        if self.i < len(self.frames):
            st, byte, stop = self.frames[self.i]
            if t >= st:
                k = int((t - st) / self.bit_time)
                if k < 10:
                    if k == 0:
                        return 0
                    if k == 9:
                        return stop
                    return (byte >> (k - 1)) & 1
        return 1

    def __call__(self, bench, resolved) -> None:
        lvl = self.level_at(bench.cycle)
        bench.drive(1 << self.bit, lvl << self.bit)


# ---------------------------------------------------------------------------
# SPI mode-0 slave: returns the bitwise complement of the byte it receives
# ---------------------------------------------------------------------------
class SpiComplementSlave:
    """Mode 0 (CPOL=0, CPHA=0) slave on UIO2..5, inverting loopback.

    In mode 0 the slave changes MISO while SCK is low and the master samples
    on the rising edge.  The complement of each MOSI bit is therefore legal to
    drive as soon as MOSI changes in the low phase; the model records a
    violation if MOSI changes at the same cycle as a rising SCK edge, if MISO
    is not stable at the sampling edge, or if SCK moves while CS is high.
    """

    def __init__(self):
        self.prev_cs = 1
        self.prev_sck = 0
        self.prev_mosi = 0
        self.cur = None
        self.frames: list[dict] = []
        self.violations: list[str] = []
        # The pads are high-Z with pull-ups until the engine drives them, so
        # the first side-set write of SCK is a pad-settling transition rather
        # than a clock edge.  Monitoring of "no SCK edge while CS is high"
        # therefore starts at the first CS assert; everything after that,
        # including the gap between transfers, is checked.
        self.armed = False

    def _miso(self, bench, level: int) -> None:
        bench.drive(1 << SPI_MISO_BIT, level << SPI_MISO_BIT)

    def _finish(self, t: int) -> None:
        f = self.cur
        f["end"] = t
        self.frames.append(f)
        self.cur = None

    def __call__(self, bench, resolved) -> None:
        t = bench.cycle
        cs = (resolved >> SPI_CS_BIT) & 1
        sck = (resolved >> SPI_SCK_BIT) & 1
        mosi = (resolved >> SPI_MOSI_BIT) & 1
        miso = (resolved >> SPI_MISO_BIT) & 1

        if self.prev_cs and not cs:                     # CS asserted
            self.armed = True
            self.cur = {
                "start": t, "sck_at_cs": sck, "cs_low_cycles": 0,
                "edges": 0, "rises": 0, "falls": 0,
                "rise_times": [], "fall_times": [],
                "mosi": 0, "miso": 0,
            }
            # MISO was released at the previous CS high; drive it again from
            # the level MOSI holds now (equal to bit 7 unless it changes).
            self._miso(bench, 1 - mosi)
        elif not self.prev_cs and cs:                   # CS released
            if self.cur is not None:
                self._finish(t)
            bench.release(1 << SPI_MISO_BIT)

        if self.cur is not None and not cs:
            self.cur["cs_low_cycles"] += 1
            if mosi != self.prev_mosi:
                if sck:                                 # CPHA=0 violation
                    msg = f"MOSI changed while SCK high at {t}"
                    self.cur.setdefault("violations", []).append(msg)
                    self.violations.append(msg)
                # inverting loopback: MISO follows MOSI in the low phase
                self._miso(bench, 1 - mosi)
                self.cur["miso_changes"] = self.cur.get("miso_changes", 0) + 1

            if sck and not self.prev_sck:               # sampling edge
                self.cur["edges"] += 1
                self.cur["rises"] += 1
                self.cur["rise_times"].append(t)
                self.cur["mosi"] = ((self.cur["mosi"] << 1) | mosi) & 0xFF
                self.cur["miso"] = ((self.cur["miso"] << 1) | miso) & 0xFF
                if miso != (1 - mosi):
                    msg = f"MISO not ~MOSI at rising edge {t}"
                    self.cur.setdefault("violations", []).append(msg)
                    self.violations.append(msg)
            elif not sck and self.prev_sck:             # trailing edge
                self.cur["edges"] += 1
                self.cur["falls"] += 1
                self.cur["fall_times"].append(t)

        if self.armed and self.prev_cs and cs and sck != self.prev_sck:
            msg = f"SCK moved while CS high at {t}"
            self.violations.append(msg)

        self.prev_cs = cs
        self.prev_sck = sck
        self.prev_mosi = mosi


# ---------------------------------------------------------------------------
# I2C target: 7-bit address, open drain, ACK/NACK, optional clock stretching
# ---------------------------------------------------------------------------
class I2cTarget:
    """Target at ``addr``; pulls SDA low only, with external pull-ups.

    Write bytes after the address are logged (``written``); read bytes are
    served from ``read_mem`` through an independent read pointer, so the data
    the master shifts in does not depend on what the write logged.  ACK bits
    are recorded in bus order: target ACKs first, then the master's ACK/NACK
    on read data.  Clock stretching holds SCL low for ``stretch`` cycles after
    the ``stretch_after``-th ACK slot and is invisible to the edge handlers,
    exactly like a real target that owns SCL while it stretches.
    """

    def __init__(self, addr=0x50, read_mem=None, stretch=0, stretch_after=1):
        self.addr = addr & 0x7F
        self.read_mem = dict(read_mem or {})
        self.stretch = stretch
        self.stretch_after = stretch_after
        self.prev_scl = 1
        self.prev_sda = 1
        self.active = False
        self.phase = "addr"
        self.pending_phase = None
        self.bc = 0
        self.shift = 0
        self.read = False
        self.match = False
        self.ack = 1
        self.out_byte = 0xFF
        self.rd_ptr = 0
        self.ack_release = False
        self.stretch_until = 0
        self.stretch_events = []
        self.events = []
        self.acks = []
        self.written = []
        self.served = []
        self.violations = []

    # -- open-drain helpers
    def _sda(self, bench, level: int) -> None:
        if level:
            bench.release(1 << I2C_SDA_BIT)
        else:
            bench.drive(1 << I2C_SDA_BIT, 0)

    def _present(self, bench, idx: int) -> None:
        self._sda(bench, (self.out_byte >> (7 - idx)) & 1)

    def _load_read_byte(self) -> None:
        self.out_byte = self.read_mem.get(self.rd_ptr, 0xFF)
        self.served.append(self.out_byte)
        self.rd_ptr = (self.rd_ptr + 1) & 0xFF

    # -- cycle hook
    def __call__(self, bench, resolved) -> None:
        scl = (resolved >> I2C_SCL_BIT) & 1
        sda = (resolved >> I2C_SDA_BIT) & 1
        t = bench.cycle

        if self.stretch_until:
            if t >= self.stretch_until:
                bench.release(1 << I2C_SCL_BIT)
                self.stretch_until = 0
            self.prev_scl, self.prev_sda = 1, sda
            return

        # START / STOP / repeated START are SDA changes while SCL is high
        if self.prev_scl and scl and sda != self.prev_sda:
            if sda == 0:
                kind = "RSTART" if self.active else "START"
                self.events.append((kind, t))
                self.active = True
                self.phase = "addr"
                self.pending_phase = None
                self.bc = 0
                self.shift = 0
                self.read = False
                self._sda(bench, 1)
            else:
                self.events.append(("STOP", t))
                self.active = False
                self._sda(bench, 1)

        if self.active:
            if scl and not self.prev_scl:                # rising: sample
                if self.bc < 8:
                    self.shift = ((self.shift << 1) | sda) & 0xFF
                    self.bc += 1
                    if self.bc == 8:
                        if self.phase == "addr":
                            self.read = bool(self.shift & 1)
                            self.match = ((self.shift >> 1) & 0x7F) == self.addr
                            self.ack = 0 if self.match else 1
                            self.pending_phase = "data" if self.match else "idle"
                        elif not self.read:
                            self.written.append(self.shift)
                            self.ack = 0
                else:                                    # 9th clock: ACK slot
                    if self.phase == "data" and self.read:
                        self.acks.append(0 if sda == 0 else 1)
                        if sda == 0:
                            self._load_read_byte()
                        else:                            # NACK: master owns SDA
                            self.phase = "idle"
                            self.read = False
                    else:
                        self.acks.append(self.ack)
                        self.ack_release = True
                    self.bc = 0
                    self.shift = 0
                    if self.pending_phase:
                        self.phase = self.pending_phase
                        self.pending_phase = None
                        if self.phase == "data" and self.read:
                            self._load_read_byte()
                    if (self.stretch and len(self.acks) == self.stretch_after):
                        self.stretch_until = t + self.stretch
                        self.stretch_events.append((t, self.stretch_until))
                        bench.drive(1 << I2C_SCL_BIT, 0)

            elif not scl and self.prev_scl:              # falling: drive
                if self.ack_release:
                    bench.release(1 << I2C_SDA_BIT)
                    self.ack_release = False
                if self.phase == "data" and self.read:
                    if self.bc < 8:
                        self._present(bench, self.bc)
                    else:
                        bench.release(1 << I2C_SDA_BIT)  # master drives ACK
                elif self.bc == 8:
                    self._sda(bench, 0 if self.ack == 0 else 1)

        self.prev_scl = scl
        self.prev_sda = sda


def bus_edges(trace, bit: int):
    out = []
    prev = (trace[0] >> bit) & 1
    for t in range(1, len(trace)):
        cur = (trace[t] >> bit) & 1
        if cur != prev:
            out.append((t, cur))
            prev = cur
    return out


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=20_000, timeout_unit="us")
async def proteus_uart_tx_pins(dut):
    """Firmware uart_tx.asm on engine 0; TX decoded at UIO0 with 16x UART."""
    ck = Checker()
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)
    await reset(dut, host)
    bench = PinBench(dut)
    bench.start()

    words = load_firmware(0, "uart_tx.asm")
    ck.eq(len(words), 18, "uart_tx.asm is 18 words at PROG_DEPTH=32")
    await host.load_program(0, words)
    # the firmware programs these itself; writing them matches the contract
    await host.write_regs(eng_reg(0, EO_PERIOD0),
                          bytes([0x07, 0xB2, 0x01, 0x00]))
    await host.write_reg(RA_RUN, 0x01)

    payload = [0x00, 0xFF, 0x55, 0xAA, 0x41]
    t_run = bench.cycle
    for b in payload:
        await push_wait(host, 0, b)

    # 5 frames of 10 bit times + the loop overhead and the first push latency
    await wait_cycles(dut, int(6 * 10 * UART_BIT) + 9000)
    await host.write_reg(RA_RUN, 0x00)
    await wait_cycles(dut, 200)
    bench.stop()

    frames = decode_uart16(bench.trace, UART_PERIOD, UART_TX_BIT)
    ck.eq(len(frames), len(payload), "one decoded frame per queued byte")
    ck.eq([f["byte"] for f in frames], payload, "UART TX decoded bytes")
    ck.true(all(f["stop"] == 1 for f in frames), "every stop bit high")

    # per-frame geometry, measured at the pad
    bit_rows = []
    for k, f in enumerate(frames):
        start = f["start"]
        nxt = frames[k + 1]["start"] if k + 1 < len(frames) else None
        hi = nxt if nxt is not None else start + int(10 * UART_BIT) + 8
        edges = uart_transitions(bench.trace, UART_TX_BIT, start, hi)
        # start bit width: only visible when d0 is high
        start_w = None
        if (f["byte"] & 1) and edges and edges[0][1] == 1:
            start_w = edges[0][0] - start
            ck.near(start_w, round(UART_PERIOD), 2, f"frame {k} start bit width")
        # stop bit width: d7 low gives a rising edge at the stop boundary
        d7 = (f["byte"] >> 7) & 1
        stop_w = None
        if d7 == 0:
            rises = [t for t, lvl in edges if lvl == 1]
            if rises:
                stop_edge = rises[-1]
                if nxt is not None:
                    stop_w = nxt - stop_edge
                    ck.true(round(UART_PERIOD) - 2 <= stop_w <= round(UART_PERIOD) + 8,
                            f"frame {k} stop bit width {stop_w}")
                else:
                    # last frame: measure the stop/idle high run to the end
                    hi_list = [v for v in bench.trace[stop_edge:]
                               if (v >> UART_TX_BIT) & 1]
                    stop_w = len(hi_list)
                    ck.true(stop_w >= round(UART_PERIOD),
                            f"frame {k} final stop/idle high run {stop_w}")
        # byte period from the decoded start edge to the stop boundary (9 bits)
        if d7 == 0:
            rises = [t for t, lvl in edges if lvl == 1]
            if rises:
                ck.near((rises[-1] - start) / 9.0, UART_PERIOD, 1.0,
                        f"frame {k} measured bit period")
        bit_rows.append((f["byte"], start_w, stop_w))

    starts = [f["start"] for f in frames]
    deltas = [starts[k + 1] - starts[k] for k in range(len(starts) - 1)]
    for i, d in enumerate(deltas):
        ck.true(round(10 * UART_PERIOD) - 4 <= d <= round(10 * UART_PERIOD) + 6,
                f"frame {i}->{i + 1} start delta {d} cycles")
    # last frame: stop stays high
    last_stop = frames[-1]["start"] + int(10 * UART_BIT)
    tail = bench.trace[last_stop:last_stop + 300]
    ck.true(bool(tail) and all((v >> UART_TX_BIT) & 1 for v in tail),
            "TX idles high after the last stop bit")

    cocotb.log.info("UART TX run cycle %d, %d frames, %d cycles simulated",
                    t_run, len(frames), bench.cycle)
    for byte, sw, ew in bit_rows:
        cocotb.log.info("UART TX byte 0x%02x start=%s stop=%s cycles", byte, sw, ew)
    cocotb.log.info("UART TX frame start deltas: %s (ideal 10*%.5f = %.2f)",
                    deltas, UART_PERIOD, 10 * UART_PERIOD)
    ck.done("UART TX pins")


@cocotb.test(timeout_time=20_000, timeout_unit="us")
async def proteus_uart_rx_pins(dut):
    """Firmware uart_rx.asm on engine 1; an independent 8N1 source feeds UIO1."""
    ck = Checker()
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)
    await reset(dut, host)
    bench = PinBench(dut)
    bench.start()

    words = load_firmware(1, "uart_rx.asm")
    ck.eq(len(words), 26, "uart_rx.asm is 26 words at PROG_DEPTH=32")
    await host.load_program(1, words)
    await host.write_regs(eng_reg(1, EO_PERIOD0),
                          bytes([0x04, 0xD9, 0x00, 0x00]))

    # 8 clean bytes + one framing-error frame (stop driven low) at the end.
    good = [0x55, 0x00, 0xFF, 0x81, 0x7E, 0xA5, 0x5A, 0x3C]
    rng = random.Random(1234)
    t = bench.cycle + 1500
    frames = []
    for b in good:
        frames.append((int(round(t)), b, 1))
        t += 10 * UART_BIT + rng.randint(2, 10) * UART_BIT
    frames.append((int(round(t)), 0x00, 0))     # framing error: stop = 0
    t_err = int(round(t))
    t_last = t_err + 10 * UART_BIT
    src = UartSource(UART_RX_BIT, UART_BIT, frames)
    bench.device = src

    expected = good + [0x00]
    got: list[int] = []

    async def drain():
        while len(got) < len(expected) and bench.cycle < t_last + 20 * UART_BIT:
            st = await host.read_reg(eng_reg(1, EO_STATUS))
            if not (st & ST_OUT_EMPTY):
                got.append(await host.pop_out(1))

    # RUN first: the drainer also uses the host SPI port, and two coroutines
    # must never bit-bang the same frame concurrently.
    await host.write_reg(RA_RUN, 0x02)
    task = cocotb.start_soon(drain())
    await wait_cycles(dut, int(t_last - bench.cycle + 12 * UART_BIT) + 4000)
    await host.write_reg(RA_RUN, 0x00)
    await wait_cycles(dut, 100)
    try:
        task.cancel()
    except AttributeError:
        task.kill()
    bench.stop()

    ck.eq(got, expected, "UART RX bytes popped from engine 1 OUT_FIFO")
    err = await host.read_reg(eng_reg(1, EO_ERROR))
    ck.eq(err & 1, 1, "framing-error frame set E_ERROR")
    st1 = await host.read_reg(eng_reg(1, EO_STATUS))
    ck.eq(st1 & 0x80, 0, "engine 1 WAITP timeout flag clear")

    # pin-level check of the stimulus: the last frame really had a low stop
    stop_slot = t_err + int(9.5 * UART_BIT)
    ck.eq((bench.trace[stop_slot] >> UART_RX_BIT) & 1, 0,
          "error frame stop bit driven low at the pad")
    ck.eq((bench.trace[t_err + int(0.5 * UART_BIT)] >> UART_RX_BIT) & 1, 0,
          "error frame start bit present at the pad")

    cocotb.log.info("UART RX %d bytes, gaps=%s, error frame at %d",
                    len(expected), [f[0] for f in frames], t_err)
    ck.done("UART RX pins")


@cocotb.test(timeout_time=20_000, timeout_unit="us")
async def proteus_spi_master_pins(dut):
    """Firmware spi_master.asm on engine 2 (mode 0); complement slave on UIO4."""
    ck = Checker()
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)
    await reset(dut, host)
    bench = PinBench(dut)
    bench.start()

    words = load_firmware(2, "spi_master.asm")
    ck.eq(len(words), 32, "spi_master.asm uses all 32 words")
    await host.load_program(2, words)
    # r7 = 0 -> mode 0; half bit = 25 cycles (1 MHz SCLK), 24.8 fixed point
    await host.write_reg(eng_reg(2, EO_R0 + 7), 0x00)
    await host.write_regs(eng_reg(2, EO_PERIOD0),
                          bytes([0x00, 0x19, 0x00, 0x00]))

    slave = SpiComplementSlave()
    bench.device = slave

    payload = [0x00, 0xFF, 0x5A, 0xA5, 0x81, 0x7E]
    expected = [(~b) & 0xFF for b in payload]
    out = []

    await host.write_reg(RA_RUN, 0x04)
    t_run = bench.cycle
    for b in payload:
        await push_wait(host, 2, b)
        out.append(await wait_out(host, 2))
    await host.write_reg(RA_RUN, 0x00)
    await wait_cycles(dut, 100)
    bench.stop()

    ck.eq(out, expected, "SPI OUT_FIFO echoes ~MOSI byte")
    ck.eq(len(slave.frames), len(payload), "one CS-framed transfer per byte")
    ck.eq(slave.violations, [], "no SPI mode-0 / CS-framing violations")

    rows = []
    for k, (f, tx, rx) in enumerate(zip(slave.frames, payload, expected)):
        ck.eq(f["edges"], 16, f"frame {k} has 16 SCK edges")
        ck.eq(f["rises"], 8, f"frame {k} has 8 rising edges")
        ck.eq(f["falls"], 8, f"frame {k} has 8 falling edges")
        ck.eq(f["sck_at_cs"], 0, f"frame {k} CPOL=0 at CS assert")
        ck.eq(f["mosi"], tx, f"frame {k} MOSI byte at the pads")
        ck.eq(f["miso"], rx, f"frame {k} MISO byte at the pads")
        ck.true(f.get("violations", []) == [], f"frame {k} clean edge order")
        # (i) no SCK edge at any cycle where CS_N is high -- inside the frame
        # or in the gap before it (the bus is idle-high again after each one)
        edge_times = sorted(f["rise_times"] + f["fall_times"])
        ck.true(all(not ((bench.trace[t] >> SPI_CS_BIT) & 1)
                    for t in edge_times),
                f"frame {k}: no SCK edge while CS high")
        # (ii) every SCK high and low phase is a full programmed half period,
        # the first one included: no 3-cycle stub, no 20-cycle short phase
        half = [edge_times[i + 1] - edge_times[i]
                for i in range(len(edge_times) - 1)]
        ck.true(all(w >= SPI_HALF_BIT for w in half),
                f"frame {k} SCK half phases {half}")
        ck.true(half == [SPI_HALF_BIT] * (len(edge_times) - 1),
                f"frame {k} every SCK half phase is {SPI_HALF_BIT} cycles, "
                f"got {half}")
        # CS_N is low a full half period before the first edge and after the
        # last one
        ck.true(edge_times[0] - f["start"] >= SPI_HALF_BIT,
                f"frame {k} CS setup {edge_times[0] - f['start']}")
        ck.true(f["end"] - edge_times[-1] >= SPI_HALF_BIT,
                f"frame {k} CS hold {f['end'] - edge_times[-1]}")
        rises = f["rise_times"]
        deltas = [rises[i + 1] - rises[i] for i in range(len(rises) - 1)]
        # every SCLK period, the first one included, is the programmed 2 halves
        for i, d in enumerate(deltas):
            ck.near(d, 2 * SPI_HALF_BIT, 1, f"frame {k} SCK period {i}")
        rows.append((tx, rx, deltas, half))

    # between transfers SCK must not move at all while CS is high
    for a, z in zip([f["end"] for f in slave.frames],
                    [f["start"] for f in slave.frames[1:]]):
        gap = [t for t in range(a, z)
               if ((bench.trace[t] >> SPI_SCK_BIT) & 1) !=
                  ((bench.trace[t - 1] >> SPI_SCK_BIT) & 1)]
        ck.eq(gap, [], "no SCK edge between transfers")

    cocotb.log.info("SPI mode 0 run cycle %d, %d transfers", t_run,
                    len(slave.frames))
    for tx, rx, deltas, half in rows:
        cocotb.log.info("SPI 0x%02x -> 0x%02x  SCK deltas=%s half phases=%s",
                        tx, rx, deltas, half)
    ck.done("SPI master pins")


@cocotb.test(timeout_time=40_000, timeout_unit="us")
async def proteus_i2c_master_pins(dut):
    """Firmware i2c_master.asm on engines 3+2; 0x50 target on UIO6/UIO7.

    One bus transaction: START, WRITE 0xA0, data 0x5A, data 0xA5, repeated
    START, WRITE 0xA1, READ+ACK (0x11), READ+NACK (0x22), STOP.  Engine 3
    makes ACKs for the four written bytes; engine 2 shifts the two read bytes
    in.  The target stretches SCL for 400 cycles after the first (address)
    ACK, which is longer than one 250-cycle phase, so the master must wait.
    """
    ck = Checker()
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)
    await reset(dut, host)
    bench = PinBench(dut)
    bench.start()

    w3 = load_firmware(3, "i2c_master.asm")
    w2 = load_firmware(2, "i2c_master.asm")
    ck.eq((len(w3), len(w2)), (32, 32), "i2c_master.asm is 32+32 words")
    await host.load_program(3, w3)
    await host.load_program(2, w2)
    # UIO_OD (0x0523) is one fabric-wide register: the host opens both I2C pads
    # for open-drain operation here instead of each engine writing ODSET.
    # SCL phases are timed by WAITC I2C_HALF inside the image, so the engine
    # period registers are not used by this firmware.
    await host.write_reg(RA_UIO_OD, 0xC0)

    target = I2cTarget(addr=0x50, read_mem={0: 0x11, 1: 0x22},
                       stretch=400, stretch_after=1)
    bench.device = target

    # One command slot per engine per bus operation, in round order.  WRITE
    # (0x02) consumes the following byte from the same IN_FIFO.
    rounds = [
        ([0x01], [0x00]),               # START
        ([0x02, 0xA0], [0x00]),         # WRITE address + W
        ([0x02, 0x5A], [0x00]),         # WRITE data 0
        ([0x02, 0xA5], [0x00]),         # WRITE data 1
        ([0x01], [0x00]),               # repeated START
        ([0x02, 0xA1], [0x00]),         # WRITE address + R
        ([0x00], [0x04]),               # READ + ACK
        ([0x00], [0x05]),               # READ + NACK
        ([0x00], [0x02]),               # STOP
    ]

    async def feed():
        for e3_bytes, e2_bytes in rounds:
            for b in e3_bytes:
                await push_wait(host, 3, b)
            for b in e2_bytes:
                await push_wait(host, 2, b)

    # Both engines must be RUN before the first token can pass.
    await host.write_reg(RA_RUN, 0x0C)
    t_run = bench.cycle
    await feed()

    # Wait for STOP; a host status read is the delay tick.
    for _ in range(600):
        if any(e[0] == "STOP" for e in target.events):
            break
        await host.read_reg(eng_reg(2, EO_STATUS))
    ck.true(any(e[0] == "STOP" for e in target.events),
            "STOP observed on the pads")
    await wait_cycles(dut, 600)
    await host.write_reg(RA_RUN, 0x00)
    await wait_cycles(dut, 100)
    bench.stop()

    # ---- bus-level assertions -------------------------------------------
    kinds = [e[0] for e in target.events]
    ck.eq(kinds, ["START", "RSTART", "STOP"],
          "START, repeated START, STOP (no STOP between the two phases)")
    ck.eq(target.acks, [0, 0, 0, 0, 0, 1],
          "ACKs: addr, data0, data1, read-addr, master ACK, master NACK")
    ck.eq(target.written, [0x5A, 0xA5], "write data bytes decoded at the pads")
    ck.eq(target.served, [0x11, 0x22], "read bytes served at the pads")
    ck.true(len(target.stretch_events) == 1, "one clock-stretch event observed")
    if target.stretch_events:
        ts, te = target.stretch_events[0]
        ck.eq(te - ts, 400, "SCL held low for the programmed 400 cycles")
        ck.eq((bench.trace[ts] >> I2C_SCL_BIT) & 1, 0, "SCL low during stretch")

    # host FIFO view (the intended host interface): 4 ACKs, 2 bytes
    acks_host = [await host.pop_out(3) for _ in range(4)]
    read_host = [await host.pop_out(2) for _ in range(2)]
    ck.eq(acks_host, [0, 0, 0, 0], "engine 3 OUT_FIFO: four ACK results")
    ck.eq(read_host, [0x11, 0x22], "engine 2 OUT_FIFO: two read bytes")

    coll = await host.read_reg(RA_COLLISION)
    ck.eq(coll, 0x00, "no open-drain collision flagged")
    for eng in (3, 2):
        st = await host.read_reg(eng_reg(eng, EO_STATUS))
        ck.eq(st & 0x80, 0, f"engine {eng} timeout flag clear")
        err = await host.read_reg(eng_reg(eng, EO_ERROR))
        ck.eq(err & 1, 0, f"engine {eng} E_ERROR clear")

    # ---- measured SCL timing -------------------------------------------
    # (iii) every SCL high >= I2C_MIN_HIGH and every low >= I2C_MIN_LOW, and
    #       every phase is in fact the programmed half period; (iv) START
    #       setup/hold and STOP setup.  The old firmware failed here: one
    #       3-cycle high phase per command (the PACERST stub) and a 23-cycle
    #       high phase after the 400-cycle stretch.
    scl = bus_edges(bench.trace, I2C_SCL_BIT)
    rises = [t for t, lvl in scl if lvl == 1]
    falls = [t for t, lvl in scl if lvl == 0]
    t_first = target.events[0][1]
    t_last = target.events[-1][1]
    highs, lows = [], []
    for t, lvl in scl:
        if lvl == 1:
            nxt = [f for f in falls if f > t]
            if nxt:
                highs.append((t, nxt[0] - t))
        else:
            nxt = [r for r in rises if r > t]
            if nxt:
                lows.append((t, nxt[0] - t))
    in_highs = [w for t, w in highs if t >= t_first]
    in_lows = [w for t, w in lows if t_first <= t <= t_last]
    ck.true(len(in_highs) >= 20,
            f"at least 20 SCL high phases, got {len(in_highs)}")
    ck.true(all(w >= I2C_MIN_HIGH for w in in_highs),
            f"every SCL high >= {I2C_MIN_HIGH} cycles, min {min(in_highs)}")
    ck.true(all(w >= I2C_MIN_LOW for w in in_lows),
            f"every SCL low >= {I2C_MIN_LOW} cycles, min {min(in_lows)}")
    # every phase is at least the programmed half period; the phases that span
    # a command boundary (or a slave stretch) are longer by design, so require
    # a steady-state population at exactly I2C_HALF as well
    ck.true(all(w >= I2C_HALF - 2 for w in in_highs),
            f"every SCL high >= the programmed {I2C_HALF} cycles, "
            f"min {min(in_highs)}")
    ck.true(all(w >= I2C_HALF - 2 for w in in_lows),
            f"every SCL low >= the programmed {I2C_HALF} cycles, "
            f"min {min(in_lows)}")
    steady_highs = [w for w in in_highs if I2C_HALF - 2 <= w <= I2C_HALF + 10]
    steady_lows = [w for w in in_lows if I2C_HALF - 2 <= w <= I2C_HALF + 10]
    ck.true(len(steady_highs) >= 20,
            f"at least 20 SCL high phases of {I2C_HALF} cycles, "
            f"got {len(steady_highs)}")
    ck.true(len(steady_lows) >= 20,
            f"at least 20 SCL low phases of {I2C_HALF} cycles, "
            f"got {len(steady_lows)}")
    edge_rows = []
    for kind, t in target.events:
        pr = [r for r in rises if r <= t]
        nf = [f for f in falls if f > t]
        setup = (t - pr[-1]) if pr else None
        hold = (nf[0] - t) if nf else None
        edge_rows.append((kind, setup, hold))
        if pr:
            ck.true(t - pr[-1] >= I2C_MIN_SETUP,
                    f"{kind} setup {t - pr[-1]} cycles (SCL high before SDA "
                    "changes)")
        if kind == "STOP":
            ck.true(all((v >> I2C_SDA_BIT) & 1 for v in bench.trace[t:]),
                    "SDA stays released after the STOP")
        elif nf:
            ck.true(nf[0] - t >= I2C_MIN_SETUP,
                    f"{kind} hold {nf[0] - t} cycles (SDA low before SCL falls)")
    cocotb.log.info("I2C START/STOP setup/hold (cycles): %s", edge_rows)

    # the stretched low phase is longer than one half period, and the high phase
    # right after the release is still a full half period
    if target.stretch_events:
        ts, te = target.stretch_events[0]
        nxt_rise = [r for r in rises if r > te]
        nxt_fall = [f for f in falls if nxt_rise and f > nxt_rise[0]]
        if nxt_rise and nxt_fall:
            ck.true(nxt_fall[0] - nxt_rise[0] >= I2C_HALF - 2,
                    "high phase after the stretch is a full half period, got "
                    f"{nxt_fall[0] - nxt_rise[0]} cycles")

    cocotb.log.info(
        "I2C run cycle %d: %d SCL high phases min/median/max %s/%s/%s, "
        "%d low phases min/median/max %s/%s/%s; %d/%d highs and %d/%d lows "
        "are exactly %d cycles",
        t_run, len(in_highs),
        min(in_highs), sorted(in_highs)[len(in_highs) // 2], max(in_highs),
        len(in_lows),
        min(in_lows), sorted(in_lows)[len(in_lows) // 2], max(in_lows),
        len(steady_highs), len(in_highs), len(steady_lows), len(in_lows),
        I2C_HALF,
    )
    cocotb.log.info("I2C events %s acks %s written %s served %s stretch %s",
                    target.events, target.acks, target.written,
                    target.served, target.stretch_events)
    ck.done("I2C master pins")
