# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
"""PROTEUS harness smoke test.

Everything enters and leaves the chip through its pins only:
  * host SPI mode 0 on ui_in[0]=SCK / ui_in[1]=CS_N / ui_in[2]=MOSI,
    uo_out[0]=MISO (docs/architecture.md section 6);
  * uio pads, mirrored back into uio_in like a real pad.

No internal hierarchy is referenced, so this test also runs against the
gate-level netlist (GATES=yes).  The full protocol suite lives in sim/ and
tb/top_e2e_tb.v; this is the submission gate.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

# SPI driver shared with the sim/ suite (protocol level, ports only).
from host import (  # noqa: E402  (PYTHONPATH puts ../sim on the path)
    ProteusHost,
    reset,
    uio_pad_model,
    RA_ID0,
    RA_RUN,
    RA_UIO_OE,
    RA_UIO_OUT,
    eng_reg,
    EO_R0,
)

# ISA (tools/isa.py): op[23:17] rd[16:14] rs[13:11] imm[10:3] ss[2:0]
OP_LDI = 0x00
OP_SETP = 0x22
OP_CLRP = 0x23
OP_JMP = 0x30
OP_WAITC = 0x3A
BANK_UIO = 2


def enc(op, rd=0, rs=0, imm=0):
    return ((op & 0x7F) << 17) | ((rd & 7) << 14) | ((rs & 7) << 11) | (
        (imm & 0xFF) << 3
    )


# r0 = 0x5A (register readback), then toggle uio[0] forever (~11 clk/half).
PROGRAM = [
    enc(OP_LDI, 0, 0, 0x5A),
    enc(OP_SETP, 0, BANK_UIO, 0x01),
    enc(OP_WAITC, 0, 0, 4),
    enc(OP_CLRP, 0, BANK_UIO, 0x01),
    enc(OP_WAITC, 0, 0, 4),
    enc(OP_JMP, 0, 0, 1),
]


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
    assert ids == [0x50, 0x52, 0x01], f"identity {ids} != ['P','R',1]"
    assert await host.ping() == 0x50, "PING did not return 0x50"
    dut._log.info("identity ok")

    # ---- program load / readback ---------------------------------------
    for i, word in enumerate(PROGRAM):
        await host.write_regs(
            0x0100 + i * 4,
            bytes([word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF]),
        )
    for i, word in enumerate(PROGRAM):
        got = await host.read_program_word(0, i)
        want = [word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF]
        assert got == want, f"program word {i}: {got} != {want}"
    dut._log.info("program loaded and verified over SPI")

    # ---- run: uio[0] must toggle, r0 must read back ---------------------
    await host.write_reg(RA_UIO_OUT, 0x00)
    await host.write_reg(RA_UIO_OE, 0x00)
    await host.write_reg(RA_RUN, 0x01)

    prev = int(dut.uio_out.value) & 1
    toggles = 0
    seen = {prev}
    for _ in range(160):
        await RisingEdge(dut.clk)
        cur = int(dut.uio_out.value) & 1
        seen.add(cur)
        if cur != prev:
            toggles += 1
            prev = cur
    assert toggles >= 6, f"uio[0] toggled only {toggles} times in 160 clocks"
    assert seen == {0, 1}, f"uio[0] never reached both levels: {seen}"
    dut._log.info("uio[0] toggled %d times", toggles)

    r0 = await host.read_reg(eng_reg(0, EO_R0))
    assert r0 == 0x5A, f"eng0 r0 = 0x{r0:02x}, expected 0x5a"
    dut._log.info("register readback ok")

    await host.write_reg(RA_RUN, 0x00)
    dut._log.info("Test passed")
