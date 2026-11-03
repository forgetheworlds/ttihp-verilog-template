"""Independent protocol models used to check the firmware.

Nothing here shares code with firmware or with tools/model.py: each decoder
only sees a pin-level trace, exactly like an external analyser or a real peer
device.
"""

from __future__ import annotations


# ---------------------------------------------------------------------------
# UART
# ---------------------------------------------------------------------------
def decode_uart16(trace, period, bit=0):
    """Decode 8N1 frames with a 16x-oversampling receiver.

    ``period`` is the ideal bit time in cycles (float).  A frame starts at a
    high->low transition; every one of the ten bit slots is decided by a
    majority vote of 16 sub-samples spread across the slot, which is what a
    real 16x UART receiver does.  Returns one dict per frame.
    """
    frames = []
    n = len(trace)
    lvl = lambda t: (trace[t] >> bit) & 1
    i = 1
    while i < n:
        if not (lvl(i - 1) == 1 and lvl(i) == 0):
            i += 1
            continue
        start = i
        bits = []
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
            bits.append(1 if votes >= 8 else 0)
        if not ok:
            break
        if bits[0] != 0:
            i += 1
            continue
        byte = 0
        for k, b in enumerate(bits[1:9]):
            byte |= b << k
        frames.append({
            "start": start,
            "byte": byte,
            "stop": bits[9],
            "byte_cycles": [start + (k + 1) * period for k in range(9)],
        })
        i = start + int(round(9.5 * period)) + 1
    return frames


class UartTx:
    """8N1 transmitter driving one pad; used to feed the RX firmware.

    The waveform is computed on the fly, so a 1000-byte drift measurement costs
    nothing in memory.  ``bit_time`` is fractional on purpose: frames are
    placed at t0 + k*10*bit_time, i.e. the ideal schedule.
    """

    def __init__(self, bit, bit_time, data, t0=0, idle=1, stop=1):
        self.bit = bit
        self.bit_time = float(bit_time)
        self.data = list(data)
        self.t0 = t0
        self.idle = idle
        self.stop = stop

    def level_at(self, t):
        if t < self.t0:
            return self.idle
        u = (t - self.t0) / self.bit_time
        i = int(u)
        if i >= 10 * len(self.data):
            return self.idle
        slot = i % 10
        b = self.data[i // 10]
        if slot == 0:
            return 0
        if slot == 9:
            return self.stop
        return (b >> (slot - 1)) & 1

    def __call__(self, bench, resolved):
        bench.drive(1 << self.bit, self.level_at(bench.cycle + 1) << self.bit)


# ---------------------------------------------------------------------------
# SPI
# ---------------------------------------------------------------------------
class SpiSlave:
    """Mode 0/3 SPI slave: shifts MOSI in, drives MISO from a TX queue."""

    def __init__(self, tx, cpol=0, cpha=0, p_sck=2, p_mosi=3, p_miso=4, p_cs=5):
        self.pending = list(tx)
        self.rx = []
        self.cpol = cpol
        self.cpha = cpha
        self.p_sck, self.p_mosi, self.p_miso, self.p_cs = p_sck, p_mosi, p_miso, p_cs
        self.prev_cs = 1
        self.prev_sck = None
        self.idx = 0
        self.out = 0
        self.shift = 0

    def _present(self, bench, idx):
        if idx < 8:
            val = (self.out >> (7 - idx)) & 1
            bench.drive(1 << self.p_miso, val << self.p_miso)
        else:
            bench.release(1 << self.p_miso)

    def __call__(self, bench, resolved):
        cs = (resolved >> self.p_cs) & 1
        sck = (resolved >> self.p_sck) & 1
        mosi = (resolved >> self.p_mosi) & 1
        if self.prev_cs and not cs:                 # CS asserted
            self.idx = 0
            self.shift = 0
            self.out = self.pending.pop(0) if self.pending else 0xFF
            if self.cpha == 0:
                self._present(bench, 0)
                self.idx = 1
            else:
                bench.release(1 << self.p_miso)
            self.prev_sck = sck
            self.prev_cs = cs
            return
        if not self.prev_cs and cs:                 # CS released
            self.rx.append(self.shift & 0xFF)
            bench.release(1 << self.p_miso)
            self.prev_cs = cs
            return
        if not cs and self.prev_sck is not None and sck != self.prev_sck:
            if sck == 1:                            # sampling edge (both modes)
                self.shift = ((self.shift << 1) | mosi) & 0xFF
            else:                                   # trailing edge: next bit out
                self._present(bench, self.idx)
                self.idx += 1
        self.prev_sck = sck
        self.prev_cs = cs


def spi_decode(trace, cpol=0, cpha=0, p_sck=2, p_mosi=3, p_miso=4, p_cs=5):
    """Decode and validate SPI frames from a pin trace.

    Checks, per frame: SCK idles at CPOL while CS is low, exactly 16 SCK edges
    (8 rising + 8 falling), MOSI stable across every sampling (rising) edge,
    and returns the MOSI/MISO bytes.  Both modes 0 and 3 sample on the rising
    edge, so one decoder covers both.
    """
    frames = []
    n = len(trace)
    c = 0
    while c < n:
        if (trace[c] >> p_cs) & 1:
            c += 1
            continue
        start = c
        while c < n and not ((trace[c] >> p_cs) & 1):
            c += 1
        end = c
        seg = trace[start:end]
        sck0 = (seg[0] >> p_sck) & 1
        edges = []
        prev = sck0
        for k in range(1, len(seg)):
            lvl = (seg[k] >> p_sck) & 1
            if lvl != prev:
                edges.append((start + k, lvl))
                prev = lvl
        rising = [t for t, lvl in edges if lvl == 1]
        mosi = 0
        miso = 0
        setup_ok = True
        for k, t in enumerate(rising[:8]):
            # sample the level that is on the wire *at* the rising edge
            mosi = (mosi << 1) | ((trace[t] >> p_mosi) & 1)
            miso = (miso << 1) | ((trace[t] >> p_miso) & 1)
            # setup: MOSI must already be stable one cycle before the edge
            if t - 1 >= start and ((trace[t - 1] >> p_mosi) & 1) != \
                    ((trace[t] >> p_mosi) & 1):
                setup_ok = False
        # MOSI must never change in the same cycle as a clock edge: that is
        # the mode-independent statement of "data is stable when it is sampled"
        for k in range(start + 1, end):
            m_chg = ((trace[k] >> p_mosi) & 1) != ((trace[k - 1] >> p_mosi) & 1)
            s_chg = ((trace[k] >> p_sck) & 1) != ((trace[k - 1] >> p_sck) & 1)
            if m_chg and s_chg:
                setup_ok = False
        frames.append({
            "start": start,
            "end": end,
            "idle": sck0,
            "cpol_ok": sck0 == cpol,
            "edges": len(edges),
            "rising": len(rising),
            "mosi": mosi,
            "miso": miso,
            "setup_ok": setup_ok,
            "edge_times": [t for t, _ in edges],
        })
    return frames


# ---------------------------------------------------------------------------
# I2C
# ---------------------------------------------------------------------------
class I2cTarget:
    """7-bit I2C target with pull-ups, register file and optional stretching.

    Drives SDA/SCL only by pulling them low (open drain), and only while it is
    allowed to: ACK slots for address and write data, the data phase of reads,
    and the stretch window.  Records bus events so tests can assert on
    START / repeated START / STOP ordering.
    """

    def __init__(self, addr, mem=None, stretch=0, stretch_after=0,
                 p_scl=6, p_sda=7):
        self.addr = addr & 0x7F
        self.mem = dict(mem or {})
        self.pointer = 0
        self.stretch = stretch            # cycles to hold SCL low ...
        self.stretch_after = stretch_after  # ... after this many ACK slots
        self.p_scl, self.p_sda = p_scl, p_sda
        self.prev_scl = 1
        self.prev_sda = 1
        self.active = False
        self.phase = "addr"
        self.pending_phase = None
        self.bc = 0
        self.shift = 0
        self.read = False
        self.ack = 1
        self.out_byte = 0xFF
        self.events = []
        self.acks = []
        self.written = []
        self.read_bytes = []
        self.stretch_until = 0
        self.stretch_events = []
        self.ack_release = False

    # -- helpers
    def _sda(self, bench, val):
        if val:
            bench.release(1 << self.p_sda)
        else:
            bench.drive(1 << self.p_sda, 0)

    def _present(self, bench, idx):
        self._sda(bench, (self.out_byte >> (7 - idx)) & 1)

    # -- cycle hook
    def __call__(self, bench, resolved):
        scl = (resolved >> self.p_scl) & 1
        sda = (resolved >> self.p_sda) & 1
        t = bench.cycle

        if self.stretch_until:
            # the target owns SCL for the whole stretch: the release itself is
            # not a data clock edge, and the following high phase is the one
            # the master samples, so do not run the edge handlers here
            if t >= self.stretch_until:
                bench.release(1 << self.p_scl)
                self.stretch_until = 0
            self.prev_scl, self.prev_sda = 1, sda
            return

        # START / STOP are SDA transitions while SCL is high
        if self.prev_scl and scl and sda != self.prev_sda:
            if sda == 0:
                self.events.append(("START", t))
                self.active = True
                self.bc = 0
                self.shift = 0
                self.phase = "addr"
                self.pending_phase = None
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
                            b = self.shift
                            self.read = bool(b & 1)
                            self.match = ((b >> 1) & 0x7F) == self.addr
                            self.ack = 0 if self.match else 1
                            self.pending_phase = "data" if self.match else "idle"
                        elif not self.read:
                            self.mem[self.pointer] = self.shift
                            self.written.append(self.shift)
                            self.pointer = (self.pointer + 1) & 0xFF
                            self.ack = 0
                else:                                    # 9th clock: ACK slot
                    if self.phase == "data" and self.read:
                        self.acks.append(0 if sda == 0 else 1)
                        if sda == 0:
                            self.out_byte = self.mem.get(self.pointer, 0xFF)
                            self.pointer = (self.pointer + 1) & 0xFF
                        else:            # NACK: the master owns SDA from here
                            self.phase = "idle"
                            self.read = False
                    else:
                        self.acks.append(self.ack)
                        self.ack_release = True  # release on the next falling
                                                 # edge, i.e. after the master
                                                 # has sampled this ACK
                    self.bc = 0
                    self.shift = 0
                    if self.pending_phase:
                        self.phase = self.pending_phase
                        self.pending_phase = None
                        if self.phase == "data" and self.read:
                            self.out_byte = self.mem.get(self.pointer, 0xFF)
                            self.pointer = (self.pointer + 1) & 0xFF
                    if self.stretch and len(self.acks) == self.stretch_after:
                        self.stretch_until = t + self.stretch
                        self.stretch_events.append((t, self.stretch_until))
                        bench.drive(1 << self.p_scl, 0)

            elif not scl and self.prev_scl:              # falling: drive
                if self.ack_release:
                    bench.release(1 << self.p_sda)
                    self.ack_release = False
                if self.phase == "data" and self.read:
                    if self.bc < 8:
                        self._present(bench, self.bc)
                    else:
                        bench.release(1 << self.p_sda)   # master drives ACK
                elif self.bc == 8:
                    self._sda(bench, 0 if self.ack == 0 else 1)

        self.prev_scl = scl
        self.prev_sda = sda
