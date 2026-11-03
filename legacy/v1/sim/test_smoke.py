"""PROTEUS cocotb smoke test: real tt_um_proteus, four real engines, host SPI.

Mirrors tb/top_e2e_tb.v phase for phase, and adds the pin-timing assertion that
is the point of the pacer: UIO0 transitions are measured at the PAD, counted in
clock periods, and must be exactly `period` apart with no drift.

Everything enters the chip through ui_in[2:0] / uo_out[0]; the only hierarchy
reads are the uio pad mirror (in host.uio_pad_model), dut.cycle during the
2^24 injection, and correctness assertions that a pin cannot express.
"""

from __future__ import annotations

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from host import (
    ProteusHost,
    reset,
    start_clock,
    uio_pad_model,
    RA_CYCLE0,
    RA_CAP_EN,
    RA_CAP_INFO,
    RA_CAP_POP,
    RA_CAP_STATUS,
    RA_CAP_TS0,
    RA_ID0,
    RA_RUN,
    RA_UIO_OE,
    RA_UIO_OUT,
    RA_UIO_OD,
    RA_UO_OUT,
    eng_reg,
    EO_PC,
    EO_R0,
    EO_OUT_FIFO,
    EO_STATUS,
)

# ------------------------------------------------------------------- ISA
OP_LDI = 0x00
OP_ADDI = 0x01
OP_SETP = 0x22
OP_CLRP = 0x23
OP_TOGP = 0x24
OP_JMP = 0x30
OP_HALT = 0x38
OP_NOP = 0x39
OP_WAITC = 0x3A
OP_PACE = 0x3B
OP_PACERST = 0x3C
OP_PUSH = 0x40
OP_BAR = 0x47
OP_CFG = 0x4D

BANK_UO = 1
BANK_UIO = 2

PERIOD = 16          # cycles, 24.8 fixed point 16.0
PERIOD_LONG = 256    # cycles for the 2^24 boundary phase


def enc(op: int, rd: int = 0, rs: int = 0, imm: int = 0, ss: int = 0) -> int:
    """24-bit instruction: op[23:17] rd[16:14] rs[13:11] imm[10:3] ss[2:0]."""
    return ((op & 0x7F) << 17) | ((rd & 7) << 14) | ((rs & 7) << 11) | (
        (imm & 0xFF) << 3
    ) | (ss & 7)


def period_program(cycles: int) -> list[int]:
    """CFG period bytes + PACERST + PACE loop toggling UIO0."""
    p = cycles << 8                     # 24.8 fixed point
    return [
        enc(OP_CFG, 0, 2, p & 0xFF),        # period[7:0]  (fraction)
        enc(OP_CFG, 0, 3, (p >> 8) & 0xFF),  # period[15:8] (integer low)
        enc(OP_CFG, 0, 4, (p >> 16) & 0xFF),
        enc(OP_CFG, 0, 5, (p >> 24) & 0xFF),
        enc(OP_PACERST),
        enc(OP_PACE),
        enc(OP_TOGP, 0, BANK_UIO, 0x01),
        enc(OP_JMP, 0, 0, 5),
    ]


class Checker:
    """Collects failures per phase and raises once, so the log shows them all."""

    def __init__(self) -> None:
        self.checks = 0
        self.fails: list[str] = []

    def eq(self, got, exp, what: str) -> None:
        self.checks += 1
        if got != exp:
            self.fails.append(f"{what}: got {got!r} expected {exp!r}")

    def is_true(self, cond: bool, what: str) -> None:
        self.checks += 1
        if not cond:
            self.fails.append(what)

    def phase_done(self, phase: str) -> None:
        assert not self.fails, (
            f"{phase}: {len(self.fails)} of {self.checks} checks failed: "
            + " | ".join(self.fails[:12])
        )
        cocotb.log.info("%s: %d checks ok", phase, self.checks)
        self.checks = 0
        self.fails = []


class PinMonitor:
    """Records (falling-edge index, uio_out value) on every change of `mask`."""

    def __init__(self, dut, mask: int):
        self.dut = dut
        self.mask = mask
        self.changes: list[tuple[int, int]] = []
        self._n = 0
        self._task = None

    def value(self) -> int:
        try:
            return int(self.dut.uio_out.value) & self.mask
        except ValueError:
            return 0

    async def _run(self) -> None:
        prev = self.value()
        self.changes.append((0, prev))
        while True:
            await FallingEdge(self.dut.clk)
            self._n += 1
            cur = self.value()
            if cur != prev:
                self.changes.append((self._n, cur))
                prev = cur

    def start(self) -> None:
        self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        if self._task is not None:
            # cancel() on cocotb >= 2.0, kill() on older releases
            try:
                self._task.cancel()
            except AttributeError:
                self._task.kill()
            self._task = None

    def first_rise(self, bit: int) -> int | None:
        """Falling-edge index at which `bit` first reads 1."""
        val = 0
        for idx, cur in self.changes:
            if not (val >> bit) & 1 and (cur >> bit) & 1:
                return idx
            val = cur
        return None

    def mark_list(self, bit: int) -> list[int]:
        """Falling-edge indices of every transition of `bit`."""
        out: list[int] = []
        val = 0
        for idx, cur in self.changes:
            if ((val >> bit) & 1) != ((cur >> bit) & 1):
                out.append(idx)
            val = cur
        return out


async def wait_halted(host: ProteusHost, engine: int, polls: int = 40) -> bool:
    for _ in range(polls):
        status = await host.read_reg(eng_reg(engine, EO_STATUS))
        if status & 0x02:
            return True
    return False


@cocotb.test(timeout_time=8000, timeout_unit="us")
async def proteus_smoke(dut):
    ck = Checker()
    await start_clock(dut, 10.0)
    host = ProteusHost(dut)
    await reset(dut, host)
    cocotb.start_soon(uio_pad_model(dut))
    await Timer(50, unit="ns")

    # =====================================================================
    # [0] identity over real SPI traffic
    # =====================================================================
    ids = await host.read_regs(RA_ID0, 3)
    ck.eq(ids[0], 0x50, "ID0")
    ck.eq(ids[1], 0x52, "ID1")
    ck.eq(ids[2], 0x01, "VERSION")
    ck.eq(await host.ping(), 0x50, "PING response")
    ck.phase_done("[0] identity")

    # =====================================================================
    # [1] program load through 0x0100 + i*4 + b byte writes
    # =====================================================================
    await host.write_prog_byte(0, 0, 0, 0x34)
    await host.write_prog_byte(0, 0, 1, 0x12)
    await host.write_prog_byte(0, 0, 2, 0xAA)
    word = await host.read_program_word(0, 0)
    ck.eq(word, [0x34, 0x12, 0xAA], "word0 lanes after three byte frames")
    ck.eq(int(dut.u_eng0.prog_mem[0].value), 0xAA1234, "prog_mem[0] assembled")

    # rewriting one lane must not disturb the others
    await host.write_prog_byte(0, 0, 1, 0x56)
    word = await host.read_program_word(0, 0)
    ck.eq(word, [0x34, 0x56, 0xAA], "lane 1 rewrite leaves lanes 0 and 2")
    ck.eq(int(dut.u_eng0.prog_mem[0].value), 0xAA5634, "prog_mem[0] re-merged")

    # an address past PROG_DEPTH must not alias word 0
    await host.write_prog_byte(0, 32, 0, 0xEE)
    ck.eq(int(dut.u_eng0.prog_mem[0].value), 0xAA5634, "i=32 write ignored")
    ck.eq(await host.read_regs(0x0100 + 32 * 4, 1), [0x00], "i=32 reads 0")
    ck.phase_done("[1] program byte lanes")

    # =====================================================================
    # [2] RUN bit 0: PACE loop, pin timing measured at the pad
    # =====================================================================
    prog = period_program(PERIOD)
    await host.load_program(0, prog)
    readback = [await host.read_program_word(0, i) for i in range(len(prog))]
    for i, w in enumerate(prog):
        ck.eq(
            readback[i],
            [w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF],
            f"program word {i} readback",
        )
    ck.eq(await host.read_reg(eng_reg(0, EO_PC)), 0x00, "PC 0 while stopped")

    mon = PinMonitor(dut, 0x01)
    mon.start()
    await host.write_reg(RA_RUN, 0x01)
    await Timer(PERIOD * 30 * 10, unit="ns")
    mon.stop()

    marks = mon.mark_list(0)
    ck.is_true(len(marks) >= 6, f"at least 6 UIO0 transitions, got {len(marks)}")
    if len(marks) >= 6:
        intervals = [marks[i + 1] - marks[i] for i in range(len(marks) - 1)]
        # PIN TIMING: the first completion after PACERST is one cycle early,
        # every later one is exactly `period` clock cycles apart -- asserted
        # against clock edges counted at the pad, not against an internal timer.
        ck.eq(intervals[0], PERIOD - 1, "first toggle interval = period-1")
        for i, iv in enumerate(intervals[1:5], start=1):
            ck.eq(iv, PERIOD, f"toggle interval {i} = period")
        cocotb.log.info("UIO0 intervals (clk periods): %s", intervals[:8])

    pc_a = await host.read_reg(eng_reg(0, EO_PC))
    pc_b = await host.read_reg(eng_reg(0, EO_PC))
    ck.is_true(5 <= pc_a <= 7, f"PC sample 0x{pc_a:02x} inside loop body 5..7")
    ck.is_true(5 <= pc_b <= 7, f"PC sample 0x{pc_b:02x} inside loop body 5..7")
    ck.eq((await host.read_reg(eng_reg(0, EO_STATUS))) & 1, 1, "E_STATUS run=1")
    await host.write_reg(RA_RUN, 0x00)
    await Timer(100, unit="ns")
    ck.phase_done("[2] PACE loop period")

    # =====================================================================
    # [3] program-written registers / OUT_FIFO / HALT retires RUN
    # =====================================================================
    regs_prog = [
        enc(OP_LDI, 0, 0, 0xA5),
        enc(OP_LDI, 1, 0, 0x3C),
        enc(OP_LDI, 2, 0, 0x00),
        enc(OP_LDI, 3, 0, 0xFF),
        enc(OP_ADDI, 0, 0, 0x01),
        enc(OP_PUSH, 1, 0, 0x00),
        enc(OP_HALT),
    ]
    await host.load_program(0, regs_prog)
    await host.write_reg(RA_RUN, 0x01)
    ck.is_true(await wait_halted(host, 0), "engine 0 halts")

    r = await host.read_regs(eng_reg(0, EO_R0), 4)
    ck.eq(r[0], 0xA6, "r0 program-computed 0xA5+1")
    ck.eq(r[1], 0x3C, "r1")
    ck.eq(r[2], 0x00, "r2")
    ck.eq(r[3], 0xFF, "r3")
    ck.eq(await host.pop_out(0), 0x3C, "OUT_FIFO byte from PUSH r1")
    cocotb.log.info(
        "DEBUG fifo: cnt=%s rd=%s wr=%s mem0=0x%02x status=0x%02x raw_reads=%s",
        int(dut.u_eng0.out_cnt.value),
        int(dut.u_eng0.out_rd.value),
        int(dut.u_eng0.out_wr.value),
        int(dut.u_eng0.out_mem[0].value),
        await host.read_reg(eng_reg(0, EO_STATUS)),
        [hex(x) for x in await host.read_regs(eng_reg(0, EO_OUT_FIFO), 2)],
    )
    status = await host.read_reg(eng_reg(0, EO_STATUS))
    ck.eq(status & 0x02, 0x02, "E_STATUS halted=1")
    ck.eq(status & 0x01, 0x00, "E_STATUS run=0 after HALT (halt_exec)")
    ck.eq((await host.read_reg(RA_RUN)) & 0x01, 0x00, "RUN bit0 retired by HALT")
    ck.phase_done("[3] registers / FIFO / HALT retires RUN")

    # =====================================================================
    # [4] capture unit on UIO0, edges generated by engine 0
    # =====================================================================
    await host.write_reg(RA_RUN, 0x00)
    await host.write_reg(RA_UIO_OD, 0x00)
    await host.write_reg(RA_UIO_OUT, 0x00)
    await host.write_reg(RA_UIO_OE, 0x00)
    await Timer(50, unit="ns")
    ck.eq(int(dut.uio_out.value) & 1, 0, "uio0 low before capture")

    cap_prog = [
        enc(OP_SETP, 0, BANK_UIO, 0x01),
        enc(OP_WAITC, 0, 0, 4),
        enc(OP_CLRP, 0, BANK_UIO, 0x01),
        enc(OP_WAITC, 0, 0, 4),
        enc(OP_SETP, 0, BANK_UIO, 0x01),
        enc(OP_HALT),
    ]
    await host.load_program(0, cap_prog)
    await host.write_reg(RA_CAP_EN, 0x01)
    ck.eq(await host.read_reg(RA_CAP_EN), 0x01, "CAP_EN readback")
    ck.eq((await host.read_reg(RA_CAP_STATUS)) & 0x0F, 0, "capture empty before run")

    await host.write_reg(RA_RUN, 0x01)
    ck.is_true(await wait_halted(host, 0), "capture program halts")

    st = await host.read_reg(RA_CAP_STATUS)
    ck.eq(st & 0x0F, 3, "capture count = 3 engine edges")
    ck.eq((st >> 4) & 1, 0, "capture overflow clear")

    info = await host.read_reg(RA_CAP_INFO)
    ck.eq(info & 0x0F, 0, "edge 1 pin 0")
    ck.eq((info >> 4) & 1, 1, "edge 1 level 1 (rising)")
    ts0 = await host.read_reg32(RA_CAP_TS0)
    ck.is_true(ts0 != 0, "edge 1 timestamp non-zero")

    await host.write_reg(RA_CAP_POP, 0x01)
    info = await host.read_reg(RA_CAP_INFO)
    ck.eq(info & 0x0F, 0, "edge 2 pin 0")
    ck.eq((info >> 4) & 1, 0, "edge 2 level 0 (falling)")
    ts1 = await host.read_reg32(RA_CAP_TS0)
    ck.is_true(ts1 > ts0, f"timestamps increase {ts0} -> {ts1}")

    await host.write_reg(RA_CAP_POP, 0x01)
    info = await host.read_reg(RA_CAP_INFO)
    ck.eq((info >> 4) & 1, 1, "edge 3 level 1 (rising)")
    ts2 = await host.read_reg32(RA_CAP_TS0)
    ck.is_true(ts2 > ts1, f"timestamps increase {ts1} -> {ts2}")

    await host.write_reg(RA_CAP_POP, 0x01)
    ck.eq((await host.read_reg(RA_CAP_STATUS)) & 0x0F, 0, "capture drained")
    await host.write_reg(RA_CAP_EN, 0x00)
    ck.phase_done("[4] capture unit")

    # =====================================================================
    # [5] two-engine barrier: same-cycle release
    # =====================================================================
    await host.write_reg(RA_RUN, 0x00)
    await host.write_reg(RA_UIO_OUT, 0x00)
    await host.write_reg(RA_UIO_OE, 0x00)
    await Timer(50, unit="ns")
    ck.eq(int(dut.uio_out.value) & 0x03, 0, "uio[1:0] clear before barrier")

    # engine 0 reaches BAR 0 first, engine 1 three NOPs later: only a real
    # barrier handshake makes the following SETPs land in the same cycle.
    bar0 = [
        enc(OP_NOP),
        enc(OP_BAR, 0, 0, 0),
        enc(OP_SETP, 0, BANK_UIO, 0x01),
        enc(OP_HALT),
    ]
    bar1 = [
        enc(OP_NOP),
        enc(OP_NOP),
        enc(OP_NOP),
        enc(OP_BAR, 0, 0, 0),
        enc(OP_SETP, 0, BANK_UIO, 0x02),
        enc(OP_HALT),
    ]
    await host.load_program(0, bar0)
    await host.load_program(1, bar1)
    rd0 = [await host.read_program_word(0, i) for i in range(len(bar0))]
    rd1 = [await host.read_program_word(1, i) for i in range(len(bar1))]
    ck.eq(
        rd1[4],
        [bar1[4] & 0xFF, (bar1[4] >> 8) & 0xFF, (bar1[4] >> 16) & 0xFF],
        "eng1 word 4 readback",
    )

    bmon = PinMonitor(dut, 0x03)
    bmon.start()
    await host.write_reg(RA_RUN, 0x03)
    ck.is_true(await wait_halted(host, 0), "eng0 leaves the barrier")
    ck.is_true(await wait_halted(host, 1), "eng1 leaves the barrier")
    await Timer(100, unit="ns")
    bmon.stop()

    rise0 = bmon.first_rise(0)
    rise1 = bmon.first_rise(1)
    cocotb.log.info("barrier pin edges: uio0=%s uio1=%s", rise0, rise1)
    ck.is_true(rise0 is not None and rise1 is not None, "both barrier pins drove")
    ck.eq(rise0, rise1, "barrier released both engines in the SAME clock period")
    ck.eq(int(dut.uio_out.value) & 0x03, 0x03, "both barrier pins high afterwards")
    ck.eq((await host.read_reg(RA_RUN)) & 0x03, 0, "RUN bits retired by HALT")
    ck.phase_done("[5] two-engine barrier")

    # =====================================================================
    # [6] pacer across the 2^24 cycle boundary
    # =====================================================================
    await host.write_reg(RA_RUN, 0x00)
    await host.write_reg(RA_UIO_OUT, 0x00)
    await host.write_reg(RA_UIO_OE, 0x00)
    await Timer(50, unit="ns")

    await host.load_program(0, period_program(PERIOD_LONG))
    # Inject the cycle counter just below 2^24 (a deposit at the falling edge
    # survives, because the only writer is the top's posedge increment).
    await FallingEdge(dut.clk)
    dut.cycle.value = 0x00FF_FF00
    await RisingEdge(dut.clk)
    cyc = await host.read_reg32(RA_CYCLE0)
    ck.is_true(cyc >= 0x00FF_FF00, f"cycle counter injected (0x{cyc:08x})")

    pmon = PinMonitor(dut, 0x01)
    pmon.start()
    await host.write_reg(RA_RUN, 0x01)
    await Timer(PERIOD_LONG * 13 * 10, unit="ns")
    pmon.stop()

    pmarks = pmon.mark_list(0)
    ck.is_true(len(pmarks) >= 8, f">=8 completions past 2^24, got {len(pmarks)}")
    if len(pmarks) >= 3:
        ck.eq(pmarks[1] - pmarks[0], PERIOD_LONG - 1, "first interval past 2^24")
        for i in range(1, min(len(pmarks) - 1, 6)):
            ck.eq(
                pmarks[i + 1] - pmarks[i],
                PERIOD_LONG,
                f"pacer interval {i} past 2^24 = period",
            )
    cyc = await host.read_reg32(RA_CYCLE0)
    cocotb.log.info("cycle after pacer run: 0x%08x", cyc)
    ck.is_true(cyc > 0x0100_0000, f"cycle counter crossed 2^24 (0x{cyc:08x})")
    ck.is_true(pmarks and pmarks[-1] is not None, "pacer kept completing")
    await host.write_reg(RA_RUN, 0x00)
    ck.phase_done("[6] pacer past 2^24")

    # =====================================================================
    # [7] run-rising restart must not execute the stale-PC instruction
    # =====================================================================
    await host.write_reg(RA_RUN, 0x00)
    await host.write_reg(RA_UIO_OUT, 0x00)
    await host.write_reg(RA_UIO_OE, 0x00)
    await host.write_reg(eng_reg(0, EO_R0), 0x55)
    await Timer(50, unit="ns")

    # Park the engine at PC 0 deterministically: JMP 0 keeps pc == 0.
    await host.load_program(0, [enc(OP_JMP, 0, 0, 0)])
    await host.write_reg(RA_RUN, 0x01)
    await Timer(200, unit="ns")
    await host.write_reg(RA_RUN, 0x00)
    await Timer(50, unit="ns")
    ck.eq(await host.read_reg(eng_reg(0, EO_PC)), 0, "engine parked at PC 0")

    # Word 0 of the next program is a side-effecting PUSH r0: a phantom
    # execution at the stale PC would push the pre-load r0 and the FIFO would
    # read 0x55,0x55 instead of 0x55,0xAA.
    await host.load_program(
        0,
        [
            enc(OP_PUSH, 0, 0, 0),
            enc(OP_LDI, 0, 0, 0xAA),
            enc(OP_PUSH, 0, 0, 0),
            enc(OP_HALT),
        ],
    )
    await host.write_reg(RA_RUN, 0x01)
    ck.is_true(await wait_halted(host, 0), "engine halts in the restart check")
    ck.eq(await host.pop_out(0), 0x55, "first pushed byte (post-load r0)")
    ck.eq(
        await host.pop_out(0),
        0xAA,
        "second pushed byte proves no phantom push on restart",
    )
    ck.phase_done("[7] restart does not execute the stale PC")

    # =====================================================================
    # [8] HOST_DISABLE: fabric owns uo_out[1:0], MISO stops driving
    # =====================================================================
    await host.write_reg(RA_RUN, 0x00)
    for addr in (RA_UO_OUT, RA_UIO_OUT, RA_UIO_OE, RA_UIO_OD):
        await host.write_reg(addr, 0x00)
    await Timer(50, unit="ns")

    dis_prog = [
        enc(OP_SETP, 0, BANK_UO, 0x03),
        enc(OP_SETP, 0, BANK_UIO, 0x80),
        enc(OP_HALT),
    ]
    await host.load_program(0, dis_prog)

    # while the host owns the pins, the engine's uo_out write must be dropped
    await host.write_reg(RA_RUN, 0x01)
    ck.is_true(await wait_halted(host, 0), "eng0 halts before HOST_DISABLE")
    await Timer(100, unit="ns")
    ck.eq(int(dut.host_en.value), 1, "host_en=1 before HOST_DISABLE")
    ck.eq(int(dut.uo_out.value) & 0x03, 0x00, "uo_out[1:0] host-owned: write dropped")
    ck.eq((int(dut.uio_out.value) >> 7) & 1, 1, "uio[7] engine write landed")
    ck.eq((int(dut.uio_oe.value) >> 7) & 1, 1, "uio[7] auto-OE set")

    await host.host_disable()
    await Timer(50, unit="ns")
    ck.eq(int(dut.host_en.value), 0, "host_en=0 after HOST_DISABLE")

    # clear the fabric registers, restart, and check the writes now reach pins
    for addr in (RA_UO_OUT, RA_UIO_OUT, RA_UIO_OE):
        await host.write_reg(addr, 0x00)
    await Timer(50, unit="ns")
    ck.eq(int(dut.uo_out.value) & 0x03, 0x00, "uo_out[1:0] cleared")
    ck.eq((int(dut.uio_out.value) >> 7) & 1, 0, "uio[7] cleared")

    await host.write_reg(RA_RUN, 0x01)
    ck.is_true(await wait_halted(host, 0), "eng0 halts after HOST_DISABLE")
    await Timer(100, unit="ns")
    ck.eq(int(dut.uo_out.value) & 0x03, 0x03, "uo_out[1:0] fabric-owned: write landed")
    ck.eq((int(dut.uio_out.value) >> 7) & 1, 1, "uio[7] write landed after disable")

    # MISO is no longer routed to uo_out[0]: hold a frame open and clock data.
    # The pin must stay at the fabric value (1) while the slave drives 0.
    await host.frame_start()
    await host.byte(0x00)
    await host.byte(0x00)
    ck.eq(host._cs, 0, "frame open during the MISO check")
    ck.eq(int(dut.uo_out.value) & 1, 1, "uo_out[0] holds the fabric value")
    ck.eq(int(dut.miso.value) & 1, 0, "host MISO output idle-low")
    ck.is_true(
        (int(dut.uo_out.value) & 1) != (int(dut.miso.value) & 1),
        "uo_out[0] no longer tracks MISO after HOST_DISABLE",
    )
    await host.frame_end()
    ck.eq(int(dut.host_en.value), 0, "host_en still 0 after a post-disable frame")
    ck.phase_done("[8] HOST_DISABLE")

    cocotb.log.info("SIM SMOKE PASSED")
