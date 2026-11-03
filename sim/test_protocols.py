"""PROTEUS v2 (hybrid) protocol E2E on the real RTL: firmware + pad-level models.

Adapted from v1 ``sim/test_protocols.py`` (untouched).  Same method: the actual
``tt_um_proteus`` RTL at the default ``PROG_DEPTH = 32`` executes the
``v2/firmware/*.asm`` images, loaded over the real host SPI port at the
``info.yaml`` clock (50 MHz, 20 ns), and every protocol assertion is decoded
from the pads by an independent model in this file.  Nothing is read out of
engine/assist state except the registers and FIFOs a host is documented to read.

What is new against the v1 suite:

  * the map test, which pins the v2 window edges (identity 0x02, engine window
    end 0x006F, assist CSR bank, and every engine's program page -- that last
    check is what found defect D1, see v2/results/v2_verify.md);
  * the I2C halves move from engines 3+2 to 2+1 (the START/WRITE half must keep
    the higher engine index: pin-merge priority is by engine index, see
    v2/firmware/README.md);
  * the Ethernet MII transmitter: a complete 802.3 frame (preamble, SFD,
    dst/src/ethertype, 46-byte payload, FCS) emitted by 31 words of firmware on
    engine 0 out of the assist FIFO, with the FCS produced by the bit-serial CRC
    assist.  Decoded at the pads by an MII PHY model that drives TX_CLK and
    samples TXD on its rising edges; the FCS is checked against ``zlib.crc32``.

MII clock note: the real host port cannot sustain a 10 Mbit/s wire (one byte
every 40 clk needs a host byte every 0.8 us; the cleanest SPI frame costs ~280
clk = 5.6 us).  The PHY model therefore clocks TX_CLK slower than the demo, so
the frame is complete instead of aborted on FIFO underrun.  Every byte on the
wire, the FCS, the TX_EN window and the TXD-vs-TX_CLK discipline are still
decoded from the pads; only the bit rate is reduced, which is exactly the
host-bandwidth limit v2/results/v2_firmware.md documents.

Pad resolution mirrors ``tools/tests/bench.py``: pull-ups everywhere, the
chip's effective drive (``uio_oe`` already has the open-drain release folded
in by the RTL) overrides the pull-up, and an external device overrides for the
bits it drives.  Each device sees the resolved level *before* its own new
drive.
"""

from __future__ import annotations

import random
import zlib
from pathlib import Path

import cocotb
from cocotb.triggers import FallingEdge

import asm
from host import (
    AS_CRC,
    AS_FIFO,
    AS_FIFO_LEVEL_MASK,
    AS_FIFO_STATUS_EMPTY,
    AS_FIFO_STATUS_FULL,
    AS_MANCH,
    BANK_UIO,
    EO_ERROR,
    EO_PERIOD0,
    EO_R0,
    EO_STATUS,
    EW_END,
    PM_END,
    ProteusHost,
    RA_COLLISION,
    RA_ID0,
    RA_RUN,
    RA_VERSION,
    eng_reg,
    pincfg,
    prog_addr,
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
SPI_HALF_BIT = CLK_HZ // 2_000_000               # 25 cycles -> 1 MHz SCLK
I2C_HALF = 250                                   # WAITC I2C_HALF in the image
I2C_MIN_HIGH = 40                                # fast-mode t_HIGH 0.6 us = 30
I2C_MIN_LOW = 65                                 # fast-mode t_LOW 1.3 us
I2C_MIN_SETUP = 40                               # START/STOP setup and hold
RA_UIO_OD = 0x0523                               # fabric-wide open-drain cfg

# UIO pad map (protocol images: v2/firmware/*.asm pin tables)
UART_TX_BIT = 0
UART_RX_BIT = 1
SPI_SCK_BIT = 2
SPI_MOSI_BIT = 3
SPI_MISO_BIT = 4
SPI_CS_BIT = 5
I2C_SCL_BIT = 6
I2C_SDA_BIT = 7

# MII pad map (v2/firmware/ethernet_mii_tx.asm)
MII_TXCLK_BIT = 0
MII_TXEN_BIT = 1
MII_TXD_BIT = 2          # TXD0..3 on UIO[5:2]
MII_NIBBLE_CYCLES = 500  # PHY TX_CLK half period, in clk cycles
MII_SLOT = 2 * MII_NIBBLE_CYCLES   # one nibble = one full TX_CLK period
MII_BYTES = 72           # 8 header + 60 body + 4 FCS

FIRMWARE_DIR = Path(__file__).resolve().parents[1] / "firmware"

# E_STATUS bits (docs/architecture.md sec. 6)
ST_IN_EMPTY = 0x04
ST_IN_FULL = 0x08
ST_OUT_EMPTY = 0x10
ST_HALTED = 0x02
ST_TIMEOUT = 0x80


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


async def load_firmware_checked(host: "ProteusHost", engine: int,
                                name: str) -> list[int]:
    """Program an engine over the host port and read every word back.

    The readback is not ceremony: defect D1 (program window 0x0100..0x02FF in
    v2/src, so engine 2's page 0x0300+ is invisible) is only observable here,
    because the cycle model bypasses the address map entirely.
    """
    words = load_firmware(engine, name)
    await host.load_program(engine, words)
    for i, w in enumerate(words):
        got = await host.read_program_word(engine, i)
        want = [w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF]
        assert got == want, (
            f"{name}: engine {engine} program word {i} read back {got} != {want} "
            f"(host program window 0x0100..0x{PM_END:04X}; engine {engine}'s page "
            f"starts at 0x{prog_addr(engine, 0, 0):04X})"
        )
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

    At each clock the device sees the resolved level computed from the chip's
    current outputs and its own previous drive, may update its drive, and the
    resulting level is what the chip samples on the next posedge.  ``trace[k]``
    is that sampled level.
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
    """8N1 waveform generator with per-frame start times and stop levels."""

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
            self.violations.append(f"SCK moved while CS high at {t}")

        self.prev_cs = cs
        self.prev_sck = sck
        self.prev_mosi = mosi


# ---------------------------------------------------------------------------
# I2C target: 7-bit address, open drain, ACK/NACK, optional clock stretching
# ---------------------------------------------------------------------------
class I2cTarget:
    """Target at ``addr``; pulls SDA low only, with external pull-ups.

    Write bytes after the address are logged (``written``); read bytes are
    served from ``read_mem`` through an independent read pointer.  ACK bits are
    recorded in bus order: target ACKs first, then the master's ACK/NACK on
    read data.  Clock stretching holds SCL low for ``stretch`` cycles after the
    ``stretch_after``-th ACK slot and is invisible to the edge handlers,
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
# Ethernet: CRC-32 in the exact bit order the assist folds, and an MII PHY
# ---------------------------------------------------------------------------
CRC_POLY = 0xEDB88320
CRC_MASK = 0xFFFFFFFF

HEADER = bytes([0x55] * 7 + [0xD5])
DST = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
SRC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x02])
ETHERTYPE = bytes([0x08, 0x00])
PAYLOAD = bytes(range(46))                     # the 802.3 minimum
BODY = DST + SRC + ETHERTYPE + PAYLOAD         # 60 bytes
FRAME = HEADER + BODY                          # as pushed by the host (68)
N_FEED = len(FRAME)


def _crc_step(state: int, bit: int) -> int:
    """One reflected step of crc_bit with poly 0xEDB88320, LSB-first input."""
    fb = (state & 1) ^ bit
    return ((state >> 1) ^ (CRC_POLY if fb else 0)) & CRC_MASK


def _crc_unstep(state: int, bit: int) -> int:
    """Invert one reflected step (poly bit 31 set makes it uniquely invertible)."""
    fb = (state >> 31) & 1                     # = old state[0] ^ bit
    prev_shifted = (state ^ (CRC_POLY if fb else 0)) & CRC_MASK
    return (((prev_shifted << 1) & CRC_MASK) | (fb ^ bit)) & CRC_MASK


def crc_fold(state: int, data: bytes) -> int:
    for byte in data:
        for i in range(8):
            state = _crc_step(state, (byte >> i) & 1)
    return state


def crc_unfold(state: int, data: bytes) -> int:
    for byte in reversed(data):
        for i in reversed(range(8)):
            state = _crc_unstep(state, (byte >> i) & 1)
    return state


# The 802.3 init/report convention: result = LFSR ^ 0xFFFFFFFF.
CRC_INIT_PRE = crc_unfold(CRC_MASK, HEADER)
assert crc_fold(CRC_INIT_PRE, HEADER) == CRC_MASK, "pre-image does not fold back"
assert crc_fold(CRC_MASK, HEADER + BODY) ^ CRC_MASK == zlib.crc32(HEADER + BODY)
FCS_EXPECTED = crc_fold(CRC_MASK, BODY) ^ CRC_MASK
assert FCS_EXPECTED == zlib.crc32(BODY), "fold disagrees with zlib.crc32"


class MiiPhy:
    """MII PHY model: drives TX_CLK, samples TX_EN/TXD on each rising edge.

    ``half`` is the TX_CLK half period in clk cycles.  The nibble a PHY samples
    is the level the chip drives during the low phase that precedes the rising
    edge, which is exactly what ``resolved`` holds at the edge's cycle.  TXD
    changes are timestamped so the setup/hold and the "TXD only changes while
    TX_CLK is low" discipline can be measured, not assumed.
    """

    def __init__(self, half: int):
        self.half = half
        self.period = 2 * half
        self.prev_clk = 0
        self.prev_txd = None
        self.prev_txen = None
        # (cycle, tx_en, nibble, txd_driven)
        self.samples: list[tuple[int, int, int, bool]] = []
        self.txd_changes: list[int] = []
        self.hi_violations: list[tuple[int, int, int]] = []
        self.txen_edges: list[tuple[int, int]] = []

    def __call__(self, bench, resolved) -> None:
        c = bench.cycle
        clk = 1 if (c % self.period) >= self.half else 0
        txd = (resolved >> MII_TXD_BIT) & 0x0F
        txen = (resolved >> MII_TXEN_BIT) & 1
        # A PHY samples the pad level; an undriven pad reads the pull-up, so
        # "the engine is driving TXD0..3" is part of what the wire shows.
        oe = safe_int(bench.dut.uio_oe)
        driven = ((oe >> MII_TXD_BIT) & 0x0F) == 0x0F

        if self.prev_txd is not None and txd != self.prev_txd:
            self.txd_changes.append(c)
            # TXD may only change in a TX_CLK low phase *while the frame is
            # asserted*.  The deassertion itself changes TX_EN and TXD in the
            # same clock edge (the firmware's CLRP), and TXD is don't-care
            # once TX_EN is low, so a change in the cycle TX_EN drops is legal.
            if self.prev_clk and txen:
                self.hi_violations.append((c, self.prev_txd, txd))
        if clk and not self.prev_clk:                 # rising edge: PHY samples
            self.samples.append((c, txen, txd, driven))

        bench.drive(1 << MII_TXCLK_BIT, clk << MII_TXCLK_BIT)
        self.prev_clk = clk
        self.prev_txd = txd
        if self.prev_txen is not None and txen != self.prev_txen:
            self.txen_edges.append((c, txen))
        self.prev_txen = txen


def mii_frame_window(phy: "MiiPhy"):
    """The longest contiguous run of samples with TX_EN high.

    The pads have pull-ups and reset with every output disabled, so a PHY sees
    TX_EN high before the engine drives it.  The frame is therefore the
    longest run of TX_EN-high samples, and every nibble in it must also have
    TXD0..3 actually driven -- otherwise the run is pad idle, not a frame.
    """
    runs: list[list[int]] = []
    cur: list[int] = []
    for i, s in enumerate(phy.samples):
        if s[1]:
            cur.append(i)
        elif cur:
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)
    if not runs:
        return [], 0
    best = max(runs, key=len)
    return [phy.samples[i] for i in best], len(runs)


def mii_decode(window):
    """Bytes from the sampled nibbles (802.3 sends bits [3:0] first)."""
    nibs = [nib for (_, _, nib, _) in window]
    data = bytes(
        (nibs[i] & 0xF) | ((nibs[i + 1] & 0xF) << 4)
        for i in range(0, len(nibs) - 1, 2)
    )
    return data, nibs


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=20_000, timeout_unit="us")
async def proteus_v2_map(dut):
    """Hybrid identity, the assist CSR bank, and every engine's program page.

    This is the test that owns the v2 address map.  It found defect D1: the
    host program window ends at 0x02FF, so engine 2's page (0x0300) is dead.
    """
    ck = Checker()
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)
    await reset(dut, host)

    # ---- identity of the hybrid build --------------------------------
    ids = await host.read_regs(RA_ID0, 3)
    ck.eq(ids[:2], [0x50, 0x52], "ID0/ID1")
    ck.eq(ids[2], 0x02, "VERSION = 0x02 (hybrid)")
    ck.eq(await host.read_reg(RA_VERSION), 0x02, "VERSION readback")

    # ---- assist CSR window, next to the untouched v1 map -------------
    ck.eq(await host.read_reg(0x0523), 0x00, "UIO_OD reset value")
    cfg_manch = await host.read_reg(0x0643)
    ck.eq(cfg_manch, 0x44, "MANCH CFG {HALF_DIV=4, OS=4}")
    pc = pincfg(True, BANK_UIO, 0, 1)
    await host.write_reg(0x0648, pc)
    ck.eq(await host.read_reg(0x0648), pc, "MANCH PINCFG readback")
    ck.eq(await host.read_reg(0x0602), 0x20, "CRC CFG0 reset = width 32")
    await host.write_reg(0x0602, 0xE0)
    ck.eq(await host.read_reg(0x0602), 0xE0, "CRC CFG0 readback")
    ck.eq(await host.read_reg(0x0611) & AS_FIFO_STATUS_EMPTY,
          AS_FIFO_STATUS_EMPTY, "assist FIFO empty after reset")
    ck.eq(await host.read_reg(0x0611) & AS_FIFO_LEVEL_MASK, 0,
          "assist FIFO level 0")
    ck.eq(await host.read_reg(0x0603) & 3, 0, "CRC CMD page = result")

    # ---- engine window: end of engine 2 is 0x0010 + 0x20*3 -------------
    ck.eq(eng_reg(2, 0), 0x0050, "engine 2 window base")
    ck.eq(EW_END, 0x006F, "engine window end 0x006F")
    st2 = await host.read_reg(eng_reg(2, EO_STATUS))
    ck.true(st2 & ST_HALTED, f"engine 2 halted after reset: 0x{st2:02x}")
    ck.eq(await host.read_reg(eng_reg(2, 1)), 0, "engine 2 PC = 0")

    # ---- program page of every engine (D1 lived here) -----------------
    # Regression for the constant that was 0x02FF: every engine's page base
    # must be writable and readable over the real host SPI, engine 2 included.
    probe = bytes([0x11, 0x22, 0x33])
    for eng in (0, 1, 2):
        addr = prog_addr(eng, 0, 0)
        await host.write_regs(addr, probe)
        back = await host.read_regs(addr, 3)
        ck.eq(back, list(probe), f"engine {eng} program page 0x{addr:04X}")
    ck.eq(PM_END, 0x03FF, "program window end 0x03FF (0x0100 + 0x100*3 - 1)")

    # last programmable word of engine 2 (index 31 of 32) at 0x037C
    last = prog_addr(2, 31, 0)
    ck.eq(last, 0x037C, "engine 2 last word address")
    await host.write_regs(last, probe)
    ck.eq(await host.read_regs(last, 3), list(probe),
          "engine 2 last program word 0x037C")

    # inside the page but past PROG_DEPTH: the window selects it, the depth
    # check drops the write.  Must read 0, and must not alias engine 2 word 0.
    await host.write_reg(0x03FC, 0xAA)
    ck.eq(await host.read_reg(0x03FC), 0x00,
          "0x03FC inside the page but past PROG_DEPTH reads 0")
    ck.eq(await host.read_regs(prog_addr(2, 0, 0), 3), list(probe),
          "0x03FC did not alias engine 2 word 0")

    # the v1 engine-3 page is not anymore: no aliasing into engine 2
    await host.write_reg(0x0400, 0x55)
    ck.eq(await host.read_reg(0x0400), 0x00,
          "0x0400 (v1 engine 3 page) is unmapped in v2")
    ck.eq(await host.read_regs(prog_addr(2, 0, 0), 3), list(probe),
          "0x0400 did not alias engine 2 word 0")

    ck.done("v2 map")
    cocotb.log.info("map: PM window 0x0100..0x%04X, EW end 0x%04X",
                    PM_END, EW_END)


@cocotb.test(timeout_time=20_000, timeout_unit="us")
async def proteus_uart_tx_pins(dut):
    """Firmware uart_tx.asm on engine 0; TX decoded at UIO0 with 16x UART."""
    ck = Checker()
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)
    await reset(dut, host)
    bench = PinBench(dut)
    bench.start()

    words = await load_firmware_checked(host, 0, "uart_tx.asm")
    ck.eq(len(words), 18, "uart_tx.asm is 18 words at PROG_DEPTH=32")
    await host.write_regs(eng_reg(0, EO_PERIOD0),
                          bytes([0x07, 0xB2, 0x01, 0x00]))
    await host.write_reg(RA_RUN, 0x01)

    payload = [0x00, 0xFF, 0x55, 0xAA, 0x41]
    t_run = bench.cycle
    for b in payload:
        await push_wait(host, 0, b)

    await wait_cycles(dut, int(6 * 10 * UART_BIT) + 9000)
    await host.write_reg(RA_RUN, 0x00)
    await wait_cycles(dut, 200)
    bench.stop()

    frames = decode_uart16(bench.trace, UART_PERIOD, UART_TX_BIT)
    ck.eq(len(frames), len(payload), "one decoded frame per queued byte")
    ck.eq([f["byte"] for f in frames], payload, "UART TX decoded bytes")
    ck.true(all(f["stop"] == 1 for f in frames), "every stop bit high")

    bit_rows = []
    for k, f in enumerate(frames):
        start = f["start"]
        nxt = frames[k + 1]["start"] if k + 1 < len(frames) else None
        hi = nxt if nxt is not None else start + int(10 * UART_BIT) + 8
        edges = uart_transitions(bench.trace, UART_TX_BIT, start, hi)
        start_w = None
        if (f["byte"] & 1) and edges and edges[0][1] == 1:
            start_w = edges[0][0] - start
            ck.near(start_w, round(UART_PERIOD), 2, f"frame {k} start bit width")
        d7 = (f["byte"] >> 7) & 1
        stop_w = None
        if d7 == 0:
            rises = [t for t, lvl in edges if lvl == 1]
            if rises:
                stop_edge = rises[-1]
                if nxt is not None:
                    stop_w = nxt - stop_edge
                    ck.true(round(UART_PERIOD) - 2 <= stop_w
                            <= round(UART_PERIOD) + 8,
                            f"frame {k} stop bit width {stop_w}")
                else:
                    hi_list = [v for v in bench.trace[stop_edge:]
                               if (v >> UART_TX_BIT) & 1]
                    stop_w = len(hi_list)
                    ck.true(stop_w >= round(UART_PERIOD),
                            f"frame {k} final stop/idle high run {stop_w}")
            if rises:
                ck.near((rises[-1] - start) / 9.0, UART_PERIOD, 1.0,
                        f"frame {k} measured bit period")
        bit_rows.append((f["byte"], start_w, stop_w))

    starts = [f["start"] for f in frames]
    deltas = [starts[k + 1] - starts[k] for k in range(len(starts) - 1)]
    for i, d in enumerate(deltas):
        ck.true(round(10 * UART_PERIOD) - 4 <= d <= round(10 * UART_PERIOD) + 6,
                f"frame {i}->{i + 1} start delta {d} cycles")
    last_stop = frames[-1]["start"] + int(10 * UART_BIT)
    tail = bench.trace[last_stop:last_stop + 300]
    ck.true(bool(tail) and all((v >> UART_TX_BIT) & 1 for v in tail),
            "TX idles high after the last stop bit")

    cocotb.log.info("UART TX run cycle %d, %d frames, %d cycles simulated",
                    t_run, len(frames), bench.cycle)
    for byte, sw, ew in bit_rows:
        cocotb.log.info("UART TX byte 0x%02x start=%s stop=%s cycles",
                        byte, sw, ew)
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

    words = await load_firmware_checked(host, 1, "uart_rx.asm")
    ck.eq(len(words), 26, "uart_rx.asm is 26 words at PROG_DEPTH=32")
    await host.write_regs(eng_reg(1, EO_PERIOD0),
                          bytes([0x04, 0xD9, 0x00, 0x00]))

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
    ck.eq(st1 & ST_TIMEOUT, 0, "engine 1 WAITP timeout flag clear")

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

    words = await load_firmware_checked(host, 2, "spi_master.asm")
    ck.eq(len(words), 32, "spi_master.asm uses all 32 words")
    await host.write_reg(eng_reg(2, EO_R0 + 7), 0x00)   # mode 0
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
        edge_times = sorted(f["rise_times"] + f["fall_times"])
        ck.true(all(not ((bench.trace[t] >> SPI_CS_BIT) & 1)
                    for t in edge_times),
                f"frame {k}: no SCK edge while CS high")
        half = [edge_times[i + 1] - edge_times[i]
                for i in range(len(edge_times) - 1)]
        ck.true(all(w >= SPI_HALF_BIT for w in half),
                f"frame {k} SCK half phases {half}")
        ck.true(half == [SPI_HALF_BIT] * (len(edge_times) - 1),
                f"frame {k} every SCK half phase is {SPI_HALF_BIT} cycles, "
                f"got {half}")
        ck.true(edge_times[0] - f["start"] >= SPI_HALF_BIT,
                f"frame {k} CS setup {edge_times[0] - f['start']}")
        ck.true(f["end"] - edge_times[-1] >= SPI_HALF_BIT,
                f"frame {k} CS hold {f['end'] - edge_times[-1]}")
        rises = f["rise_times"]
        deltas = [rises[i + 1] - rises[i] for i in range(len(rises) - 1)]
        for i, d in enumerate(deltas):
            ck.near(d, 2 * SPI_HALF_BIT, 1, f"frame {k} SCK period {i}")
        rows.append((tx, rx, deltas, half))

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
    """Firmware i2c_master.asm on engines 2+1; 0x50 target on UIO6/UIO7.

    v2 remap: START/WRITE on engine 2 (higher index, so it wins the pin merge)
    and READ/STOP on engine 1.  One bus transaction: START, WRITE 0xA0, data
    0x5A, data 0xA5, repeated START, WRITE 0xA1, READ+ACK (0x11),
    READ+NACK (0x22), STOP.  The target stretches SCL for 400 cycles after the
    first (address) ACK, longer than one 250-cycle phase.
    """
    ck = Checker()
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)
    await reset(dut, host)
    bench = PinBench(dut)
    bench.start()

    w2 = await load_firmware_checked(host, 2, "i2c_master.asm")
    w1 = await load_firmware_checked(host, 1, "i2c_master.asm")
    ck.eq((len(w2), len(w1)), (32, 32), "i2c_master.asm is 32+32 words")
    await host.write_reg(RA_UIO_OD, 0xC0)

    target = I2cTarget(addr=0x50, read_mem={0: 0x11, 1: 0x22},
                       stretch=400, stretch_after=1)
    bench.device = target

    # One command slot per engine per bus operation: (engine 2, engine 1).
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
        for e2_bytes, e1_bytes in rounds:
            for b in e2_bytes:
                await push_wait(host, 2, b)
            for b in e1_bytes:
                await push_wait(host, 1, b)

    await host.write_reg(RA_RUN, 0x06)
    t_run = bench.cycle
    await feed()

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

    acks_host = [await host.pop_out(2) for _ in range(4)]
    read_host = [await host.pop_out(1) for _ in range(2)]
    ck.eq(acks_host, [0, 0, 0, 0], "engine 2 OUT_FIFO: four ACK results")
    ck.eq(read_host, [0x11, 0x22], "engine 1 OUT_FIFO: two read bytes")

    coll = await host.read_reg(RA_COLLISION)
    ck.eq(coll, 0x00, "no open-drain collision flagged")
    for eng in (2, 1):
        st = await host.read_reg(eng_reg(eng, EO_STATUS))
        ck.eq(st & ST_TIMEOUT, 0, f"engine {eng} timeout flag clear")
        err = await host.read_reg(eng_reg(eng, EO_ERROR))
        ck.eq(err & 1, 0, f"engine {eng} E_ERROR clear")

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


@cocotb.test(timeout_time=200_000, timeout_unit="us")
async def proteus_ethernet_mii_tx_pins(dut):
    """ethernet_mii_tx.asm on engine 0: a full 802.3 frame via FIFO + CRC.

    Host contract (v2/firmware/README.md): configure the CRC assist (CFG0,
    init pre-image, poly, xorout, start, page back to result), clear the FIFO,
    set r2 = 68 and r3 = 1, RUN, then push exactly those 68 bytes in wire
    order without ever letting the queue empty.  The engine appends the four
    FCS bytes itself, re-using the FIFO.

    The PHY model clocks TX_CLK and samples TX_EN/TXD on the rising edges, so
    the decoded frame, the TX_EN window, the FCS and the TXD-vs-TX_CLK
    discipline are all measured at the pads.  See the module docstring for why
    the wire rate is below the demo's 10 Mbit/s.
    """
    ck = Checker()
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)
    await reset(dut, host)
    bench = PinBench(dut)
    phy = MiiPhy(MII_NIBBLE_CYCLES)
    bench.device = phy
    bench.start()

    words = await load_firmware_checked(host, 0, "ethernet_mii_tx.asm")
    ck.eq(len(words), 31, "ethernet_mii_tx.asm is 31 words of 32")

    # ---- CRC assist: CFG0, init pre-image, poly, xorout, start, result page
    await host.as_write(AS_CRC, 2, 0xE0)              # lsb=1 refl=1 width=32
    ck.eq(await host.as_read(AS_CRC, 2), 0xE0, "CRC CFG0 = 0xE0")

    await host.as_write(AS_CRC, 3, 8)                 # page = init
    await host.as_write_block(AS_CRC, 4, CRC_INIT_PRE.to_bytes(4, "little"))
    await host.as_write(AS_CRC, 3, 9)                 # page = poly
    await host.as_write_block(AS_CRC, 4, CRC_POLY.to_bytes(4, "little"))
    await host.as_write(AS_CRC, 3, 10)                # page = xorout
    await host.as_write_block(AS_CRC, 4, b"\xff\xff\xff\xff")
    await host.as_write(AS_CRC, 3, 1)                 # start: crc <= init
    await host.as_write(AS_CRC, 3, 0)                 # page = result

    # page round-trip: 1 = init, 9 selected poly, 10 xorout.  Read back the
    # init page after selecting it again, then return to the result page.
    await host.as_write(AS_CRC, 3, 8)
    back = await host.as_read_block(AS_CRC, 4, 4)
    ck.eq(back, list(CRC_INIT_PRE.to_bytes(4, "little")),
          "CRC init page readback (pre-image)")
    await host.as_write(AS_CRC, 3, 9)
    back = await host.as_read_block(AS_CRC, 4, 4)
    ck.eq(back, list(CRC_POLY.to_bytes(4, "little")), "CRC poly page readback")
    await host.as_write(AS_CRC, 3, 10)
    back = await host.as_read_block(AS_CRC, 4, 4)
    ck.eq(back, [0xFF] * 4, "CRC xorout page readback")
    await host.as_write(AS_CRC, 3, 0)                 # page = result
    ck.eq(await host.as_read(AS_CRC, 3) & 3, 0, "CRC page back to result")

    # ---- FIFO assist: clear, then pre-fill before RUN -------------------
    await host.as_write(AS_FIFO, 3, 0x00)             # clear
    st = await host.as_read(AS_FIFO, 1)
    ck.true(st & AS_FIFO_STATUS_EMPTY, "FIFO empty after clear")
    ck.eq(st & AS_FIFO_LEVEL_MASK, 0, "FIFO level 0 after clear")

    # ---- engine 0: r2 = byte count, r3 = 1 (payload pass) --------------
    await host.write_reg(eng_reg(0, EO_R0 + 2), N_FEED)
    await host.write_reg(eng_reg(0, EO_R0 + 3), 0x01)
    ck.eq(await host.read_reg(eng_reg(0, EO_R0 + 2)), N_FEED, "engine 0 r2 = 68")
    ck.eq(await host.read_reg(eng_reg(0, EO_R0 + 3)), 0x01, "engine 0 r3 = 1")

    pre = min(16, N_FEED)
    for k in range(pre):
        await host.as_write(AS_FIFO, 0, FRAME[k])
    sent = pre
    max_level = 0
    st = await host.as_read(AS_FIFO, 1)
    max_level = max(max_level, st & AS_FIFO_LEVEL_MASK)
    ck.eq(st & AS_FIFO_LEVEL_MASK, pre, f"pre-filled {pre} bytes, level")

    # ---- run + feed while the emitter drains ---------------------------
    t_run = bench.cycle
    await host.write_reg(RA_RUN, 0x01)

    deadline = t_run + (MII_BYTES * 2 + 40) * MII_SLOT

    async def feed():
        nonlocal sent, max_level
        while sent < N_FEED and bench.cycle < deadline:
            st = await host.as_read(AS_FIFO, 1)
            lvl = st & AS_FIFO_LEVEL_MASK
            max_level = max(max_level, lvl)
            room = 16 - lvl
            n = min(room, N_FEED - sent)
            if n <= 0:
                continue
            for k in range(n):
                await host.as_write(AS_FIFO, 0, FRAME[sent + k])
            sent += n
        return sent

    task = cocotb.start_soon(feed())
    await wait_cycles(dut, MII_BYTES * 2 * MII_SLOT
                      + 6 * MII_SLOT + 480 + 2000)
    fed = await task
    bench.stop()

    ck.eq(fed, N_FEED, "host pushed exactly r2 bytes")
    ck.true(max_level >= 8, f"assist FIFO carried the stream (max level "
                            f"{max_level})")

    run = await host.read_reg(RA_RUN)
    ck.eq(run & 0x01, 0, "engine 0 RUN retired (frame finished, not aborted)")
    st0 = await host.read_reg(eng_reg(0, EO_STATUS))
    ck.true(st0 & ST_HALTED, f"engine 0 halted: 0x{st0:02x}")
    ck.eq(st0 & ST_TIMEOUT, 0, "engine 0 no WAITP timeout")
    err = await host.read_reg(eng_reg(0, EO_ERROR))
    ck.eq(err & 1, 0, "engine 0 no ASSERT")

    # ---- decode the wire ------------------------------------------------
    window, n_runs = mii_frame_window(phy)
    data, nibs = mii_decode(window)
    ck.eq(len(window), 2 * MII_BYTES,
          f"exactly {2 * MII_BYTES} nibbles under TX_EN")
    ck.true(all(en and drv for (_, en, _, drv) in window),
            "TX_EN high and TXD0..3 driven for the whole frame (contiguous)")

    ck.eq(nibs[:16], [5, 5] * 7 + [5, 0xD], "preamble 55*7 + SFD D5 at nibbles")
    ck.eq(data, FRAME + FCS_EXPECTED.to_bytes(4, "little"),
          "decoded wire bytes: header | dst | src | ethertype | payload | FCS")

    fcs_wire = int.from_bytes(data[-4:], "little") if len(data) >= 4 else 0
    ck.eq(fcs_wire, FCS_EXPECTED, "FCS on the wire = zlib.crc32(body)")
    ck.eq(fcs_wire, zlib.crc32(BODY), "FCS = zlib.crc32(dst..payload)")
    ck.eq(data[8:14], DST, "dst MAC at the pads")
    ck.eq(data[14:20], SRC, "src MAC at the pads")
    ck.eq(data[20:22], ETHERTYPE, "ethertype 0x0800")
    ck.eq(data[22:22 + len(PAYLOAD)], PAYLOAD, "payload byte-exact")

    # ---- TXD vs TX_CLK discipline, setup/hold --------------------------
    ck.eq(phy.hi_violations, [], "TXD never changes while TX_CLK is high")
    edge_cycles = [c for (c, _, _, _) in window]
    setup, hold = [], []
    for c in edge_cycles:
        prev_ch = [x for x in phy.txd_changes if x <= c]
        next_ch = [x for x in phy.txd_changes if x > c]
        if prev_ch:
            setup.append(c - prev_ch[-1])
        if next_ch:
            hold.append(next_ch[0] - c)
    ck.true(bool(setup) and min(setup) >= 1,
            f"every nibble settled before its sampling edge (min {min(setup) if setup else None})")
    ck.true(bool(hold) and min(hold) >= 1,
            f"every nibble held past its sampling edge (min {min(hold) if hold else None})")

    # ---- TX_EN edges and the inter-frame gap ---------------------------
    # The pads come out of reset with every output disabled, so a PHY sees
    # TX_EN high (pull-up) until the engine's first side-set write drives it
    # low; that boot transition is reported but is not part of the frame.
    boot = [t for (t, lvl) in phy.txen_edges if lvl == 0 and t <= window[0][0]]
    ck.true(bool(boot), "pad pull-up released at boot (TX_EN driven low)")
    falls = [t for (t, lvl) in phy.txen_edges
             if lvl == 0 and t > window[-1][0]]
    ck.eq(len(falls), 1, "exactly one TX_EN deassertion after the frame")
    if falls:
        t_fall = falls[0]
        ck.true(t_fall - window[-1][0] <= 2 * MII_SLOT,
                "TX_EN drops within one nibble of the FCS")
        ifg_cycles = bench.cycle - t_fall
        ck.true(ifg_cycles >= 480,
                f"inter-frame gap >= the programmed 480 cycles, got {ifg_cycles}")

    cocotb.log.info(
        "MII run cycle %d: %d nibbles, %d wire bytes, TX_CLK half period %d "
        "cycles (nibble slot %d); window %d..%d cycles (%d TX_EN runs)",
        t_run, len(nibs), len(data), MII_NIBBLE_CYCLES, MII_SLOT,
        window[0][0], window[-1][0], n_runs)
    cocotb.log.info(
        "MII wire: header %s | dst %s | src %s | type %s | payload %d bytes | "
        "FCS %02x %02x %02x %02x (0x%08X)",
        data[:8].hex(" "), data[8:14].hex(" "), data[14:20].hex(" "),
        data[20:22].hex(" "), len(PAYLOAD),
        data[-4], data[-3], data[-2], data[-1], fcs_wire)
    cocotb.log.info(
        "MII timing: setup min %d / median %d cycles, hold min %d / median %d "
        "cycles, TXD changes %d, high-phase violations %d",
        min(setup), sorted(setup)[len(setup) // 2],
        min(hold), sorted(hold)[len(hold) // 2],
        len(phy.txd_changes), len(phy.hi_violations))
    ck.done("Ethernet MII TX pins")
