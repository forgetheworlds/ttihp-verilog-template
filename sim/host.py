"""PROTEUS v2 host-side SPI driver for cocotb.

Derived from v1 ``sim/host.py`` (untouched).  The host protocol is
instruction-for-instruction the same -- the hybrid top kept ``proteus_host``,
the command set and the v1 register map -- so only the v2 additions are new:

  * ``AS_BASE`` / ``as_reg()``: the assist CSR window at ``0x0600 + 0x10*id + reg``
    (``reg 8`` = the host-only PINCFG register of that assist).
  * ``PROG_DEPTH = 32`` and the three-engine map (``EW_END = 0x006F``,
    ``PM_END = 0x02FF``).
  * ``RA_VERSION`` reads ``0x02`` in this build (v1 read ``0x01``).

Everything else -- SPI mode 0, MSB first, SCK = clk/8, the pad mirror, reset --
is v1 code, kept byte-identical so a v1/v2 result cannot differ for driver
reasons.  See v2/CUTOVER.md item 4 ("sim/host.py: unchanged").

Speaks only the pin-level protocol of docs/architecture.md section 6: SPI mode 0
(CPOL=0, CPHA=0), MSB first, SCK = clk/8, on ui_in[2:0] / uo_out[0].  Nothing
here reaches into the DUT to move data; hierarchy is only *read* where a pin
cannot distinguish two causes (the pad model below mirrors uio_out/uio_oe back
onto uio_in, exactly like the resolved pad in the Verilog benches).

Timing note: proteus_host synchronises SCK/CS_N/MOSI through two flops and a
pipeline stage, so SCK <= clk/8 is the fastest clean rate (see decision 3 in
src/proteus_host.v).  Every transfer here uses 4 clk low / 4 clk high and
samples MISO 2 clk into the high phase.
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

# --------------------------------------------------------------- command set
CMD_NOP = 0x00
CMD_WRITE_INC = 0x01
CMD_READ_INC = 0x02
CMD_SET_PTR_LO = 0x03
CMD_SET_PTR_HI = 0x04
CMD_WRITE_ADDR = 0x05
CMD_READ_ADDR = 0x06
CMD_PING = 0x07
CMD_SOFT_RESET = 0x08
CMD_HOST_DISABLE = 0x09

# ------------------------------------------------------------- register map
RA_ID0 = 0x0000
RA_ID1 = 0x0001
RA_VERSION = 0x0002
RA_STATUS = 0x0003
RA_RUN = 0x0004
RA_HALT = 0x0005
RA_SOFT_RESET = 0x0006
RA_HOST_EN = 0x0007
RA_IRQ_STATUS = 0x0008
RA_IRQ_ENABLE = 0x0009
RA_IRQ_ACK = 0x000A
RA_CYCLE0 = 0x000B

EW_BASE = 0x0010
EW_STRIDE = 0x0020
EW_END = 0x006F          # v2: engines 0..2 (v1: 0x008F)
EO_STATUS = 0x00
EO_PC = 0x01
EO_FLAGS = 0x02
EO_ERROR = 0x03
EO_R0 = 0x04
EO_PERIOD0 = 0x0C
EO_IN_FIFO = 0x10
EO_OUT_FIFO = 0x11
EO_BITPIN = 0x12
EO_SIDE = 0x13
EO_TIMEOUT = 0x14

PM_BASE = 0x0100
PM_STRIDE_E = 0x0100
PM_END = 0x03FF          # v2: 3 program pages, 0x0100 + 0x100*3 - 1

RA_CAP_EN = 0x0500
RA_CAP_STATUS = 0x0501
RA_CAP_TS0 = 0x0502
RA_CAP_INFO = 0x0506
RA_CAP_POP = 0x0507
RA_COLLISION = 0x0510
RA_UO_OUT = 0x0520
RA_UIO_OUT = 0x0521
RA_UIO_OE = 0x0522
RA_UIO_OD = 0x0523
RA_ASSERT_INFO = 0x0530

# ------------------------------------------------------- assist CSR window
# 0x0600 + 0x10*id + reg, reg 0..7; reg 8 of each stride is host-only PINCFG.
AS_BASE = 0x0600
AS_STRIDE = 0x0010
AS_END = 0x064F
AS_PINCFG = 0x08
AS_CRC, AS_FIFO, AS_SHIFT, AS_NRZI, AS_MANCH = range(5)

# FIFO/FIFO-STATUS bits (proteus_assist.v id 1, reg 1)
AS_FIFO_STATUS_FULL = 0x40
AS_FIFO_STATUS_EMPTY = 0x20
AS_FIFO_LEVEL_MASK = 0x1F

# PINCFG fields
PINCFG_EN = 0x80
PINCFG_BANK_UI = 0x00
PINCFG_BANK_UO = 0x20
PINCFG_BANK_UIO = 0x40
BANK_UI, BANK_UO, BANK_UIO = 0, 1, 2


def eng_reg(engine: int, off: int) -> int:
    """Engine-window address (0x20-byte stride, see the top's geometry note)."""
    return EW_BASE + EW_STRIDE * engine + off


def prog_addr(engine: int, index: int, byte: int) -> int:
    """Program byte address: 0x0100 + e*0x100 + i*4 + b, b in 0..2."""
    return PM_BASE + PM_STRIDE_E * engine + index * 4 + byte


def as_reg(assist: int, reg: int) -> int:
    """Assist CSR address: 0x0600 + 0x10*id + reg (reg 8 = PINCFG)."""
    return AS_BASE + AS_STRIDE * assist + reg


def pincfg(en: bool, bank: int, tx_base: int, rx_base: int) -> int:
    """PINCFG byte: [7] en [6:5] bank [4:2] tx_base [1:0] rx_base."""
    return ((0x80 if en else 0) | ((bank & 3) << 5)
            | ((tx_base & 7) << 2) | (rx_base & 3))


class ProteusHost:
    """Bit-banging SPI mode-0 master on the PROTEUS host pins."""

    def __init__(self, dut, clk_ns: float = 10.0):
        self.dut = dut
        self.clk_ns = clk_ns
        self._sck = 0
        self._cs = 1
        self._mosi = 0
        self._fabric_in = 0
        self._apply()

    # ---------------------------------------------------------------- pins
    def _apply(self) -> None:
        self.dut.ui_in.value = (
            ((self._fabric_in & 0xF8) << 0)
            | (self._mosi << 2)
            | (self._cs << 1)
            | self._sck
        )

    def _miso(self) -> int:
        try:
            return int(self.dut.uo_out.value) & 1
        except ValueError:  # X/Z while out of reset
            return 0

    async def _clk(self, n: float) -> None:
        await Timer(n * self.clk_ns, unit="ns")

    # ------------------------------------------------------------ transfer
    async def byte(self, mosi: int) -> int:
        """One full-duplex byte; returns the byte clocked in on MISO."""
        miso = 0
        for bit in range(7, -1, -1):
            self._mosi = (mosi >> bit) & 1
            self._sck = 0
            self._apply()
            await self._clk(4)
            self._sck = 1
            self._apply()
            await self._clk(2)
            miso = (miso << 1) | self._miso()
            await self._clk(2)
            self._sck = 0
            self._apply()
        return miso

    async def frame_start(self) -> None:
        self._sck = 0
        self._mosi = 0
        self._apply()
        await self._clk(2)
        self._cs = 0
        self._apply()
        await self._clk(8)

    async def frame_end(self) -> None:
        await self._clk(6)
        self._cs = 1
        self._apply()
        await self._clk(10)

    # ------------------------------------------------------------- commands
    async def write_regs(self, addr: int, data: bytes) -> None:
        await self.frame_start()
        await self.byte(CMD_WRITE_ADDR)
        await self.byte(addr & 0xFF)
        await self.byte((addr >> 8) & 0xFF)
        for d in data:
            await self.byte(d & 0xFF)
        await self.frame_end()

    async def write_reg(self, addr: int, data: int) -> None:
        await self.write_regs(addr, bytes([data & 0xFF]))

    async def read_regs(self, addr: int, count: int) -> list[int]:
        out: list[int] = []
        await self.frame_start()
        await self.byte(CMD_READ_ADDR)
        await self.byte(addr & 0xFF)
        await self.byte((addr >> 8) & 0xFF)
        for _ in range(count):
            out.append(await self.byte(0))
        await self.frame_end()
        return out

    async def read_reg(self, addr: int) -> int:
        return (await self.read_regs(addr, 1))[0]

    async def read_reg32(self, addr: int) -> int:
        b = await self.read_regs(addr, 4)
        return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)

    async def ping(self) -> int:
        await self.frame_start()
        await self.byte(CMD_PING)
        r = await self.byte(0)
        await self.frame_end()
        return r

    # --------------------------------------------------------- program RAM
    async def write_prog_byte(self, engine: int, index: int, byte: int, val: int) -> None:
        """One single-byte frame: exercises the byte-enable lane directly."""
        await self.write_reg(prog_addr(engine, index, byte), val)

    async def load_program(self, engine: int, words: list[int]) -> None:
        """Byte writes at 0x0100+e*0x100+i*4+b for b = 0,1,2 (little endian)."""
        for i, w in enumerate(words):
            await self.write_regs(
                prog_addr(engine, i, 0),
                bytes([w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF]),
            )

    async def read_program_word(self, engine: int, index: int) -> list[int]:
        """Three bytes at 0x0100+e*0x100+i*4+{0,1,2}; lane 3 is a hole."""
        return await self.read_regs(prog_addr(engine, index, 0), 3)

    # --------------------------------------------------------------- FIFOs
    async def push_in(self, engine: int, value: int) -> None:
        await self.write_reg(eng_reg(engine, EO_IN_FIFO), value)

    async def pop_out(self, engine: int) -> int:
        return await self.read_reg(eng_reg(engine, EO_OUT_FIFO))

    # ------------------------------------------------------ assist CSR port
    async def as_write(self, assist: int, reg: int, value: int) -> None:
        await self.write_reg(as_reg(assist, reg), value)

    async def as_write_block(self, assist: int, reg: int, values: bytes) -> None:
        await self.write_regs(as_reg(assist, reg), values)

    async def as_read(self, assist: int, reg: int) -> int:
        return await self.read_reg(as_reg(assist, reg))

    async def as_read_block(self, assist: int, reg: int, count: int) -> list[int]:
        return await self.read_regs(as_reg(assist, reg), count)

    async def as_cmd(self, assist: int, command: int) -> None:
        """CMD register (reg 3) of one assist; the host form of ASST."""
        await self.as_write(assist, 3, command)

    async def fifo_status(self, tries: int = 8) -> int:
        """Assist FIFO STATUS: {0, full, empty, level[4:0]} (mirrored reads)."""
        return await self.as_read(AS_FIFO, 1)

    async def fifo_push_when_ready(self, value: int) -> int:
        """Push one byte into the assist FIFO once it is not full; return level."""
        st = await self.fifo_status()
        for _ in range(64):
            if not (st & AS_FIFO_STATUS_FULL):
                break
            st = await self.fifo_status()
        else:
            raise AssertionError("assist FIFO stayed full")
        await self.as_write(AS_FIFO, 0, value)
        return st & AS_FIFO_LEVEL_MASK

    # ------------------------------------------------------------ lifecycle
    async def host_disable(self) -> None:
        await self.frame_start()
        await self.byte(CMD_HOST_DISABLE)
        await self.frame_end()


async def uio_pad_model(dut) -> None:
    """Resolve the uio pins like a real pad: the chip's driven value wins.

    Held at the falling edge so every posedge samples a stable level; this is
    the same value the combinational `assign uio_in = uio_out & uio_oe` in the
    Verilog benches presents at each posedge.
    """
    dut.uio_in.value = 0
    while True:
        await FallingEdge(dut.clk)
        dut.uio_in.value = int(dut.uio_out.value) & int(dut.uio_oe.value)


async def start_clock(dut, clk_ns: float = 10.0) -> None:
    # Positional units: works on cocotb 2.0 (``units``) and 2.1 (``unit``).
    cocotb.start_soon(Clock(dut.clk, clk_ns, "ns").start())


async def reset(dut, host: ProteusHost | None = None, cycles: int = 10) -> None:
    """Reset the chip, then wait past the engine HALT fill (PROG_DEPTH = 32)."""
    dut.ena.value = 1
    dut.rst_n.value = 0
    if host is not None:
        host._cs = 1
        host._sck = 0
        host._mosi = 0
        host._apply()
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(cycles + 40):
        await RisingEdge(dut.clk)
