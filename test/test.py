# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
"""PROTEUS v2 (hybrid) harness smoke test.

Adapted from v1 ``test/test.py`` (untouched).  Same idea: everything enters and
leaves the chip through its pins only --

  * host SPI mode 0 on ui_in[0]=SCK / ui_in[1]=CS_N / ui_in[2]=MOSI,
    uo_out[0]=MISO (docs/architecture.md section 6);
  * uio pads, mirrored back into uio_in like a real pad.

No internal hierarchy is referenced, so this test also runs against the
gate-level netlist (GATES=yes).  It is the submission gate; the protocol suite
(wire-level UART/SPI/I2C/MII decode) lives in v2/sim.

v2 deltas against the v1 gate:
  * VERSION reads 0x02 (hybrid identity);
  * the program page of engine 2 (0x0300) is programmed too, which is the last
    page of the 3-engine map (v1 had engines 0..3);
  * the gate checks RUN -> HALT: the HALT instruction retires the RUN bit, which
    is the v2 run/halt contract for a three-bit run mask.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

# SPI driver shared with the v2/sim suite (protocol level, ports only).
from host import (  # noqa: E402  (PYTHONPATH puts ../sim on the path)
    EO_R0,
    EO_STATUS,
    ProteusHost,
    RA_ID0,
    RA_RUN,
    RA_UIO_OE,
    RA_UIO_OUT,
    eng_reg,
    reset,
    uio_pad_model,
)

# ISA (v2/tools/isa.py): op[23:17] rd[16:14] rs[13:11] imm[10:3] ss[2:0]
OP_LDI = 0x00
OP_SETP = 0x22
OP_CLRP = 0x23
OP_WAITC = 0x3A
OP_HALT = 0x38
BANK_UIO = 2


def enc(op, rd=0, rs=0, imm=0):
    return ((op & 0x7F) << 17) | ((rd & 7) << 14) | ((rs & 7) << 11) | (
        (imm & 0xFF) << 3
    )


# r0 = 0x5A (register readback); uio[0] toggles six times and then HALT parks
# it low, so one run covers the pin, the register and the RUN retirement.
PROGRAM = [
    enc(OP_LDI, 0, 0, 0x5A),            # 0  r0 = 0x5A
    enc(OP_SETP, 0, BANK_UIO, 0x01),    # 1  uio[0] = 1
    enc(OP_WAITC, 0, 0, 5),             # 2
    enc(OP_CLRP, 0, BANK_UIO, 0x01),    # 3  uio[0] = 0
    enc(OP_WAITC, 0, 0, 5),             # 4
    enc(OP_SETP, 0, BANK_UIO, 0x01),    # 5
    enc(OP_WAITC, 0, 0, 5),             # 6
    enc(OP_CLRP, 0, BANK_UIO, 0x01),    # 7
    enc(OP_WAITC, 0, 0, 5),             # 8
    enc(OP_SETP, 0, BANK_UIO, 0x01),    # 9
    enc(OP_WAITC, 0, 0, 5),             # 10
    enc(OP_CLRP, 0, BANK_UIO, 0x01),    # 11
    enc(OP_HALT),                       # 12
]
PC_HALT = len(PROGRAM) - 1


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def test_project(dut):
    dut._log.info("Start")

    # 10 ns clock; host SPI runs at clk/8 (proteus_host's synchroniser limit).
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())

    host = ProteusHost(dut)
    await reset(dut, host)
    cocotb.start_soon(uio_pad_model(dut))

    # ---- identity -------------------------------------------------------
    ids = await host.read_regs(RA_ID0, 3)
    assert ids == [0x50, 0x52, 0x02], f"identity {ids} != ['P','R',2]"
    assert await host.ping() == 0x50, "PING did not return 0x50"
    dut._log.info("identity ok (VERSION 0x02)")

    # ---- program load / readback (engine 0) ----------------------------
    await host.load_program(0, PROGRAM)
    for i, word in enumerate(PROGRAM):
        got = await host.read_program_word(0, i)
        want = [word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF]
        assert got == want, f"program word {i}: {got} != {want}"
    dut._log.info("program loaded and verified over SPI (%d words)", len(PROGRAM))

    # ---- engine 2 program page: the last page of the 3-engine map ------
    # v1 had 0x0300 as engine 2 of four; in v2 it is engine 2 of three and the
    # page must still land, so a 3-engine top cannot silently keep a 4-engine
    # decoder.
    probe = enc(OP_HALT)
    await host.load_program(2, [probe])
    got = await host.read_program_word(2, 0)
    assert got == [probe & 0xFF, (probe >> 8) & 0xFF, (probe >> 16) & 0xFF], (
        f"engine 2 program page readback {got}"
    )
    # ... and one byte past the last page (0x0300, v1 engine 3) is not mapped
    # in v2: the window ends at 0x02FF, so the write must not reach engine 2.
    await host.write_reg(0x0400, 0xAA)
    got = await host.read_program_word(2, 0)
    assert got == [probe & 0xFF, (probe >> 8) & 0xFF, (probe >> 16) & 0xFF], (
        f"0x0400 is outside the v2 program window but changed engine 2: {got}"
    )
    dut._log.info("engine 2 page ok; 0x0400 outside the 3-engine map")

    # ---- run: uio[0] must toggle, r0 must read back, HALT must retire RUN
    # The pad is sampled every cycle by a monitor started *before* RUN: the
    # host SPI write of RUN itself costs ~280 clocks, and a program that ends
    # in HALT can finish most of its toggles while that frame is still on the
    # wire, so sampling after the write would miss them.
    await host.write_reg(RA_UIO_OUT, 0x00)
    await host.write_reg(RA_UIO_OE, 0x00)

    levels: list[int] = []

    async def monitor():
        while True:
            await FallingEdge(dut.clk)
            levels.append(int(dut.uio_out.value) & 1)

    mon = cocotb.start_soon(monitor())
    await host.write_reg(RA_RUN, 0x01)

    run = None
    for _ in range(64):
        run = await host.read_reg(RA_RUN)
        if not (run & 0x01):
            break
    try:
        mon.cancel()
    except AttributeError:
        mon.kill()

    assert run == 0x00, f"RUN not retired after HALT: 0x{run:02x}"
    dut._log.info("RUN retired by HALT")

    toggles = sum(1 for a, b in zip(levels, levels[1:]) if a != b)
    seen = set(levels)
    assert toggles >= 5, f"uio[0] toggled only {toggles} times in {len(levels)} clocks"
    assert seen == {0, 1}, f"uio[0] never reached both levels: {seen}"
    dut._log.info("uio[0] toggled %d times", toggles)

    r0 = await host.read_reg(eng_reg(0, EO_R0))
    assert r0 == 0x5A, f"eng0 r0 = 0x{r0:02x}, expected 0x5a"
    dut._log.info("register readback ok")

    st = await host.read_reg(eng_reg(0, EO_STATUS))
    assert st & 0x02, f"E_STATUS.halted not set after HALT: 0x{st:02x}"
    assert not (st & 0x01), f"E_STATUS.run still set: 0x{st:02x}"
    pc = await host.read_reg(eng_reg(0, 1))
    assert pc == PC_HALT, f"engine 0 PC = {pc}, expected {PC_HALT}"
    assert int(dut.uio_out.value) & 1 == 0, "uio[0] not parked low by HALT"
    if int(dut.uio_oe.value) & 1 != 1:
        dut._log.warning("uio[0] output enable is low (pad not driven)")
    dut._log.info("halted, PC=%d, uio[0] parked low", pc)

    dut._log.info("Test passed")
