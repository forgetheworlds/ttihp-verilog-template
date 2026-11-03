"""Firmware-in-the-model tests: each demo is decoded by an independent model.

Every test loads a real ``firmware/*.asm`` file into the cycle model, drives or
samples the pads, and checks the traffic with a protocol decoder that shares no
code with the firmware (tools/tests/protocols.py).
"""

from pathlib import Path

import pytest

import asm
import isa
import model
from bench import Bench, assemble
from protocols import I2cTarget, SpiSlave, UartTx, decode_uart16, spi_decode

FIRMWARE = Path(__file__).resolve().parents[2] / "firmware"

# 50 MHz sign-off clock (info.yaml clock_hz); change CLK_HZ alone to run the
# suite against another clock, then update the firmware period bytes to match.
CLK_HZ = 50_000_000
UART_BAUD = 115_200
UART_BIT = CLK_HZ / UART_BAUD                      # 434.0277.. cycles
UART_PERIOD_FIXED = round(CLK_HZ / UART_BAUD * 256)  # 111111 (0x0001B207)
UART_PERIOD = UART_PERIOD_FIXED / 256.0              # 434.02734 cycles
UART_RX_PERIOD_FIXED = round(CLK_HZ / UART_BAUD / 2 * 256)  # 55556 (0x00D904)
SPI_HALF_BIT = CLK_HZ // 2_000_000                 # 25 cycles at 1 MHz
I2C_PERIOD = CLK_HZ // 200_000                     # 250 cycles = half 100 kHz
# The timing contract both firmwares are written against (50 MHz cycles).
SPI_HALF_MIN = SPI_HALF_BIT                        # every SCK phase >= this
I2C_HALF = 250                                     # WAITC I2C_HALF in the image
I2C_MIN_HIGH = 40                                  # fast-mode t_HIGH 0.6 us = 30
I2C_MIN_LOW = 65                                   # fast-mode t_LOW 1.3 us
I2C_MIN_SETUP = 40                                 # START/STOP setup and hold


def prog(name, eng, depth=isa.PROG_DEPTH):
    res = assemble(FIRMWARE / name, depth)
    return res["programs"][eng], res


# ---------------------------------------------------------------------------
# UART transmitter
# ---------------------------------------------------------------------------
def test_uart_tx_frame_geometry_and_decode():
    words, res = prog("uart_tx.asm", 0)
    assert len(words) == 18
    b = Bench()
    b.load(0, words)
    b.start(0)
    b.m.push_in(0, 0xA5)
    b.step(6000)
    assert b.m.engines[0].period == UART_PERIOD_FIXED
    frames = decode_uart16(b.trace, UART_PERIOD)
    # one frame per byte; the chip stops after the last stop bit, so the
    # decoder may also report the trailing idle as nothing
    assert frames, "no frame decoded"
    f = frames[0]
    assert f["byte"] == 0xA5
    assert f["stop"] == 1
    assert b.pin(0, f["start"]) == 0


def test_uart_tx_bit_boundaries_are_on_the_pacer_grid():
    words, _ = prog("uart_tx.asm", 0)
    b = Bench()
    b.load(0, words)
    b.start(0)
    data = [0x55, 0x0F, 0xF0, 0x00, 0xFF, 0xA5]
    # the IN_FIFO is FIFO_DEPTH (4) deep in this build, so feed as it drains
    b.pump(int(len(data) * 11 * UART_BIT) + 2000, feed={0: list(data)})
    frames = decode_uart16(b.trace, UART_PERIOD)
    assert [f["byte"] for f in frames] == data
    assert all(f["stop"] == 1 for f in frames)
    # every TX transition must land within 1 cycle of a bit boundary of its
    # frame: start + k*period, k = 1..9
    for f in frames:
        t0 = f["start"]
        stop_at = int(t0 + 9.9 * UART_PERIOD)
        edges = [c for c, _ in b.edges(0, t0, min(stop_at, len(b.trace)))]
        assert edges
        for t in edges:
            d = min(abs(t - (t0 + k * UART_PERIOD)) for k in range(1, 10))
            assert d <= 1.0, (t, t0, d)


def test_uart_tx_1000_bytes_no_accumulated_drift():
    """Frame-internal bit timing is dead on for 1000 bytes: the pacer carries
    the fractional remainder instead of rounding each bit."""
    words, _ = prog("uart_tx.asm", 0)
    b = Bench()
    b.load(0, words)
    b.start(0)
    data = [(k * 37 + 11) & 0xFF for k in range(1000)]
    b.pump(int(1000 * 11 * UART_BIT) + 4000, feed={0: list(data)})
    frames = decode_uart16(b.trace, UART_PERIOD)
    assert len(frames) == 1000
    assert [f["byte"] for f in frames] == data
    assert all(f["stop"] == 1 for f in frames)
    # bit-boundary error never exceeds one cycle, at frame 0 or frame 999
    worst = 0.0
    for f in frames[::97] + [frames[-1]]:
        t0 = f["start"]
        for c, _ in b.edges(0, t0, min(int(t0 + 9.9 * UART_PERIOD), len(b.trace))):
            worst = max(worst, min(abs(c - (t0 + k * UART_PERIOD)) for k in range(1, 10)))
    assert worst <= 1.0, worst
    # frame-to-frame interval must be constant to within one cycle over the
    # whole run: a pacer that rounded each bit would drift by >= 1 cycle/frame
    starts = [f["start"] for f in frames]
    deltas = [starts[k + 1] - starts[k] for k in range(len(starts) - 1)]
    assert max(deltas) - min(deltas) <= 1, (min(deltas), max(deltas))
    overhead = sum(deltas) / len(deltas) - 10 * UART_PERIOD
    assert 0 <= overhead <= 4, overhead      # constant loop overhead only


def test_uart_tx_idles_high_between_frames():
    words, _ = prog("uart_tx.asm", 0)
    b = Bench()
    b.load(0, words)
    b.start(0)
    b.m.push_in(0, 0x00)
    b.step(5000)                     # no second byte queued
    frames = decode_uart16(b.trace, UART_PERIOD)
    assert len(frames) == 1
    end = frames[0]["start"] + int(11 * UART_PERIOD)
    assert all((b.trace[t] & 1) == 1 for t in range(end, len(b.trace)))


# ---------------------------------------------------------------------------
# UART receiver
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("phase", [0.0, 0.37, 0.5, 0.83])
def test_uart_rx_recovers_bytes_at_random_edge_phase(phase):
    words, res = prog("uart_rx.asm", 1)
    assert len(words) == 26
    data = [0x55, 0x00, 0xFF, 0x81, 0x7E]
    tx = UartTx(bit=1, bit_time=UART_BIT, data=data, t0=int(200 * phase))
    b = Bench(device=tx)
    b.load(1, words)
    b.start(1)
    got = []
    b.pump(int(200 + len(data) * 10 * UART_BIT + 4000), collect={1: got})
    assert b.m.engines[1].period == UART_RX_PERIOD_FIXED
    assert got == data
    assert b.m.engines[1].error_flag == 0


def test_uart_rx_flags_framing_error_but_keeps_the_byte():
    words, _ = prog("uart_rx.asm", 1)
    tx = UartTx(bit=1, bit_time=UART_BIT, data=[0x3C], stop=0)
    b = Bench(device=tx)
    b.load(1, words)
    b.start(1)
    b.step(int(6000))
    assert b.m.pop_out(1) == 0x3C
    assert b.m.engines[1].error_flag == 1


def test_uart_rx_handles_back_to_back_frames():
    words, _ = prog("uart_rx.asm", 1)
    data = [(k * 11) & 0xFF for k in range(20)]
    tx = UartTx(bit=1, bit_time=UART_BIT, data=data)
    b = Bench(device=tx)
    b.load(1, words)
    b.start(1)
    got = []
    b.pump(int(300 + len(data) * 10 * UART_BIT + 3000), collect={1: got})
    assert got == data


def test_uart_loopback_tx_to_rx():
    """TX (engine 0, UIO0) wired to RX (engine 1, UIO1) through the harness."""
    tx_words, _ = prog("uart_tx.asm", 0)
    rx_words, _ = prog("uart_rx.asm", 1)
    data = [0xA5, 0x5A, 0x01, 0x80]
    b = Bench()
    b.load(0, tx_words)
    b.load(1, rx_words)
    b.start(0)
    b.start(1)
    def wire(bench, resolved):
        # mirror UIO0 (TX) onto UIO1 (RX), plus keep pull-ups elsewhere
        bench.drive(0x02, ((resolved >> 0) & 1) << 1)

    got = []
    b.pump(26000, feed={0: list(data)}, collect={1: got}, device=wire)
    assert got == data
    assert b.m.engines[1].error_flag == 0


# ---------------------------------------------------------------------------
# SPI master
# ---------------------------------------------------------------------------
def _spi_bench(mode, mosi, miso, half_bit=SPI_HALF_BIT):
    """mode is the r7 value: 0 -> SPI mode 0, 1 -> SPI mode 3."""
    words, res = prog("spi_master.asm", 2)
    assert len(words) == 32
    cpol = cpha = 1 if mode else 0
    slave = SpiSlave(tx=miso, cpol=cpol, cpha=cpha)
    b = Bench(device=slave)
    b.load(2, words)
    b.m.engines[2].period = half_bit * 256
    b.m.engines[2].regs[7] = mode
    b.start(2)
    for byte in mosi:
        b.m.push_in(2, byte)
    b.step(len(mosi) * 16 * half_bit + 4000)
    out = []
    while True:
        v = b.m.pop_out(2)
        if v is None:
            break
        out.append(v)
    return b, slave, out


@pytest.mark.parametrize("mode", [0, 1])          # r7 = 0 -> mode 0, 1 -> mode 3
def test_spi_master_decodes_in_both_modes(mode):
    cpol = cpha = 1 if mode else 0
    mosi = [0x5A, 0xC3, 0x00, 0xFF]
    miso = [0x96, 0x3C, 0x55, 0xAA]
    b, slave, out = _spi_bench(mode, mosi, miso)
    assert out == miso
    assert slave.rx == mosi
    frames = spi_decode(b.trace, cpol=cpol, cpha=cpol)
    assert len(frames) == len(mosi)
    for f, tx, rx in zip(frames, mosi, miso):
        assert f["edges"] == 16, f
        assert f["rising"] == 8
        assert f["cpol_ok"], f
        assert f["setup_ok"], f
        assert f["mosi"] == tx, (hex(f["mosi"]), hex(tx))
        assert f["miso"] == rx


def test_spi_clock_period_is_exactly_two_half_periods():
    b, _, _ = _spi_bench(0, [0xA5], [0x3C])
    frames = spi_decode(b.trace, cpol=0, cpha=0)
    f = frames[0]
    times = f["edge_times"]
    assert len(times) == 16
    # rising-to-rising (one full SCLK period) is exactly 2 * half_bit,
    # including the first period of the transfer
    rises = times[1::2]
    assert len(rises) == 8
    deltas = [rises[k + 1] - rises[k] for k in range(7)]
    assert all(d == 2 * SPI_HALF_BIT for d in deltas), deltas


def test_spi_cs_frames_one_byte_per_transfer():
    b, _, _ = _spi_bench(0, [0x01, 0x02], [0x03, 0x04])
    frames = spi_decode(b.trace, cpol=0, cpha=0)
    assert len(frames) == 2
    assert frames[0]["end"] < frames[1]["start"]
    assert all(f["idle"] == 0 for f in frames)


@pytest.mark.parametrize("mode", [0, 1])
def test_spi_half_periods_are_full_and_cs_stays_clean(mode):
    """The clock contract: no SCK edge outside CS, every high and low phase a
    full programmed half period (including the first high phase), and CS low a
    half period either side of the pulse train."""
    b, slave, out = _spi_bench(mode, [0xA5, 0x3C], [0x5A, 0xC3])
    frames = spi_decode(b.trace, cpol=mode, cpha=mode)
    assert len(frames) == 2, frames
    sck = b.edges(2)
    for k, f in enumerate(frames):
        seg = [(t, lvl) for t, lvl in sck if f["start"] <= t <= f["end"]]
        assert len(seg) == 16, (k, seg)
        # no SCK edge at any cycle where CS is high
        assert not [t for t, _ in seg if (b.trace[t] >> 5) & 1], (k, seg)
        widths = [seg[i + 1][0] - seg[i][0] for i in range(len(seg) - 1)]
        assert all(w >= SPI_HALF_MIN for w in widths), (k, widths)
        # CS setup before the first edge and hold after the last one
        assert seg[0][0] - f["start"] >= SPI_HALF_MIN, (k, seg[0][0] - f["start"])
        assert f["end"] - seg[-1][0] >= SPI_HALF_MIN, (k, f["end"] - seg[-1][0])
    # With CPOL=0 SCK must not move at all between transfers; with CPOL=1 the
    # transfer ends high and the tail returns SCK to its low idle level, so only
    # require that SCK is back at CPOL when the next CS asserts (decoded above).
    if mode == 0:
        for a, z in zip([f["end"] for f in frames], [f["start"] for f in frames[1:]]):
            assert not [t for t, _ in sck if a < t < z]


# ---------------------------------------------------------------------------
# I2C master (two-engine split: engine 3 control/write, engine 2 read/stop)
# ---------------------------------------------------------------------------
def _i2c_bench(cmds3, cmds2, target=None, period=I2C_PERIOD):
    """Load both engines at depth 32 and feed one command slot per engine.

    The engines hand the bus over with an IRQ token, so the host must pair the
    streams: one byte to engine 3 and one to engine 2 per bus operation, 0x00
    (NOP) for the engine with nothing to do in that round.
    """
    w3, res = prog("i2c_master.asm", 3)
    w2 = res["programs"][2]
    assert len(w3) <= 32 and len(w2) <= 32, (len(w3), len(w2))
    tg = target or I2cTarget(addr=0x50, mem={0: 0xA5, 1: 0x5A})
    b = Bench(prog_depth=32, device=tg)
    # UIO_OD is one fabric-wide register: the host opens both I2C pads for
    # open-drain operation before RUN (0x0523 = 0xC0) instead of each engine
    # writing ODSET.  SCL phases are timed by WAITC in the firmware, so the
    # engine period registers are not used by this image.
    b.m.uio_od = 0xC0
    b.load(3, w3)
    b.load(2, w2)
    b.m.engines[3].period = period * 256
    b.m.engines[2].period = period * 256
    b.start(3)
    b.start(2)
    out3, out2 = [], []
    # the FIFO is 8 deep, so feed both streams as the engines drain them
    b.pump(60000, feed={3: list(cmds3), 2: list(cmds2)},
           collect={3: out3, 2: out2})
    return b, tg, out3, out2


def test_i2c_fits_32_words_on_both_engines():
    w3, res = prog("i2c_master.asm", 3)
    assert len(w3) == 32
    assert len(res["programs"][2]) == 32


def test_all_firmware_fits_the_32_word_build():
    assert len(prog("uart_tx.asm", 0)[0]) == 18
    assert len(prog("uart_rx.asm", 1)[0]) == 26
    assert len(prog("spi_master.asm", 2)[0]) == 32


def test_i2c_write_transaction():
    # rounds: (START, NOP) (WRITE 0xA0, NOP) (WRITE 0x5A, NOP) (NOP, STOP)
    b, tg, out3, out2 = _i2c_bench(
        [0x01, 0x02, 0xA0, 0x02, 0x5A, 0x00],
        [0x00, 0x00, 0x00, 0x02])
    assert tg.written == [0x5A]
    assert tg.acks[:2] == [0, 0]        # address ACK, data ACK
    assert [e[0] for e in tg.events] == ["START", "STOP"]
    assert out3 == [0x00, 0x00]         # engine 3: both ACKs
    assert out2 == []


def test_i2c_read_transaction_nack():
    # rounds: (START,NOP) (WRITE 0xA1,NOP) (NOP,READ+NACK) (NOP,STOP)
    b, tg, out3, out2 = _i2c_bench(
        [0x01, 0x02, 0xA1, 0x00, 0x00],
        [0x00, 0x00, 0x05, 0x02])
    assert out3 == [0x00]               # address ACK
    assert out2 == [0xA5]               # received byte (engine 2)
    assert tg.acks == [0, 1]            # address ACK, then master NACK
    assert [e[0] for e in tg.events] == ["START", "STOP"]


def test_i2c_read_multiple_bytes_with_repeated_start():
    # read two bytes (ACK then NACK), repeated START, write, STOP
    tg = I2cTarget(addr=0x50, mem={0: 0x11, 1: 0x22})
    b, tg, out3, out2 = _i2c_bench(
        [0x01, 0x02, 0xA1, 0x00, 0x00, 0x01, 0x02, 0xA0, 0x02, 0x33, 0x00],
        [0x00, 0x00, 0x04, 0x05, 0x00, 0x00, 0x00, 0x02],
        target=tg)
    assert out2 == [0x11, 0x22]         # READ+ACK then READ+NACK
    assert out3 == [0x00, 0x00, 0x00]   # three write ACKs
    assert tg.written == [0x33]
    kinds = [e[0] for e in tg.events]
    assert kinds == ["START", "START", "STOP"]      # repeated START, no STOP between


def _scl_phases(b):
    """[(start, width)] for every SCL high phase and every low phase."""
    scl = b.edges(6)
    highs = [(t, scl[i + 1][0] - t) for i, (t, lvl) in enumerate(scl[:-1]) if lvl == 1]
    lows = [(t, scl[i + 1][0] - t) for i, (t, lvl) in enumerate(scl[:-1]) if lvl == 0]
    return scl, highs, lows


def test_i2c_clock_stretching_extends_the_low_phase():
    """A stretch holds SCL low; the master waits for the release and then still
    clocks a full high phase (the pacer-era firmware produced a 23-cycle high
    phase after a 400-cycle stretch)."""
    tg = I2cTarget(addr=0x50, mem={0: 0xA5}, stretch=200, stretch_after=1)
    b, tg, out3, out2 = _i2c_bench(
        [0x01, 0x02, 0xA1, 0x00, 0x00],
        [0x00, 0x00, 0x05, 0x02],
        target=tg)
    assert out2 == [0xA5]
    assert out3 == [0x00]
    assert tg.stretch_events, "no stretch window was entered"
    t_start, t_end = tg.stretch_events[0]
    assert t_end - t_start == 200
    # the target owns SCL for the whole stretch window
    assert all((b.trace[t] >> 6) & 1 == 0 for t in range(t_start, t_end))
    scl, highs, lows = _scl_phases(b)
    # the low phase containing the stretch is at least the programmed stretch
    assert any(t <= t_start and t + w >= t_end and w >= 200 for t, w in lows), lows
    # the high phase right after the release is a full half period
    t_rise = min(t for t, lvl in scl if lvl == 1 and t > t_end)
    t_fall = min(t for t, lvl in scl if lvl == 0 and t > t_rise)
    assert t_fall - t_rise >= I2C_HALF - 5, (t_rise, t_fall)


def test_i2c_scl_phases_meet_fast_mode_minima():
    """Every SCL phase, and every START/STOP setup and hold, meets the
    fast-mode minima.  This is the assertion the pacer-era firmware failed:
    its first phase per command was 3 cycles long."""
    b, tg, out3, out2 = _i2c_bench(
        [0x01, 0x02, 0xA0, 0x02, 0x5A, 0x01, 0x02, 0xA1, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x02],
        target=I2cTarget(addr=0x50, mem={0: 0x5A, 1: 0x00}))
    assert [e[0] for e in tg.events] == ["START", "START", "STOP"], tg.events
    scl, highs, lows = _scl_phases(b)
    t_first = tg.events[0][1]
    t_last = tg.events[-1][1]
    inside_high = [(t, w) for t, w in highs if t >= t_first]
    inside_low = [(t, w) for t, w in lows if t_first <= t <= t_last]
    assert inside_high and inside_low
    assert min(w for _, w in inside_high) >= I2C_MIN_HIGH, inside_high
    assert min(w for _, w in inside_low) >= I2C_MIN_LOW, inside_low
    # and they are in fact the programmed half period, not just above the spec
    assert min(w for _, w in inside_high) >= I2C_HALF - 5
    assert min(w for _, w in inside_low) >= I2C_HALF - 5
    # START setup (SCL high -> SDA fall) and hold (SDA fall -> SCL fall)
    rises = [t for t, lvl in scl if lvl == 1]
    falls = [t for t, lvl in scl if lvl == 0]
    for kind, t in tg.events:
        prev_rise = max((r for r in rises if r <= t), default=None)
        next_fall = min((f for f in falls if f > t), default=None)
        if prev_rise is not None:
            assert t - prev_rise >= I2C_MIN_SETUP, (kind, t - prev_rise)
        if kind == "STOP":
            # bus free after the STOP: SDA stays released and SCL stays
            # high for at least the minimum bus-free time before the tail
            # lets the next command pull it low again
            assert all((b.trace[c] >> 7) & 1 for c in range(t, len(b.trace)))
            if next_fall is not None:
                assert next_fall - t >= I2C_MIN_SETUP, next_fall - t
        elif next_fall is not None:
            assert next_fall - t >= I2C_MIN_SETUP, (kind, next_fall - t)


def test_i2c_no_ack_from_missing_target_is_reported():
    tg = I2cTarget(addr=0x21)          # not the addressed device
    b, tg, out3, out2 = _i2c_bench(
        [0x01, 0x02, 0xA0, 0x02, 0x5A, 0x00],
        [0x00, 0x00, 0x00, 0x02],
        target=tg)
    assert out3 and out3[0] == 0x01    # NACK on the address byte
