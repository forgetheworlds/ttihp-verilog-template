"""Cycle-model tests: timing, flags, FIFOs, sync, capture, pin fabric."""

import pytest

import asm
import isa
import model


def build(src, depth=isa.PROG_DEPTH):
    return asm.assemble_text(src, depth)


def run_eng(src, eng=0, cycles=500, ui_in=0, uio_in=0, depth=isa.PROG_DEPTH):
    words = build(src, depth)["programs"].get(eng, [])
    m = model.ProteusModel(prog_depth=depth)
    m.load(eng, words)
    m.start(eng)
    m.ui_in = ui_in
    m.uio_in = uio_in
    for _ in range(cycles):
        if not m.engines[eng].run:
            break
        m.step()
    return m


def steps_until(src, pred, cycles=2000, **kw):
    """Run one engine, return the number of cycles until ``pred(model)``."""
    words = build(src)["programs"].get(0, [])
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    for k in range(cycles):
        if pred(m):
            return k, m
        m.step()
    raise AssertionError("condition never reached")


# ---------------------------------------------------------------------------
# WAITC: exactly max(n, 1) cycles
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("n,expected", [(0, 1), (1, 1), (2, 2), (3, 3),
                                        (5, 5), (100, 100), (2047, 2047)])
def test_waitc_exact_cycle_count(n, expected):
    src = f"    WAITC {n}\n    LDI r0, 0xAA\n"
    # the LDI executes on step expected+1 (WAITC occupies `expected` cycles)
    steps, m = steps_until(src, lambda m: m.engines[0].regs[0] == 0xAA,
                           cycles=expected + 10)
    assert steps == expected + 1
    assert m.cycle == expected + 1


def test_waitc_does_not_leak_wait_state_into_next_instruction():
    src = "    WAITC 3\n    NOP\n    NOP\n    HALT\n"
    m = run_eng(src, cycles=20)
    assert m.engines[0].halted == 1
    assert m.engines[0].wait_active == 0


# ---------------------------------------------------------------------------
# PACE: drift-free with a fractional period (100.5 cycles)
# ---------------------------------------------------------------------------
def test_pace_fractional_period_has_no_drift():
    # period = 100.5 cycles = 25728 in 24.8 fixed point (0x00006480)
    src = """
        CFG PERIOD0, 0x80
        CFG PERIOD1, 0x64
        PACERST
    loop:
        PACE
        ADDI r0, 1
        JMP loop
    """
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    marks = []
    prev = 0
    for c in range(1, 4000):
        m.step()
        r0 = m.engines[0].regs[0]
        if r0 != prev:
            marks.append(m.cycle - 1)     # cycle in which PACE completed
            prev = r0
    assert len(marks) > 20
    t0 = marks[0]                          # priming completion, next = t0_arm + P
    # every later completion is floor(k * 100.5) cycles after the arm cycle
    arm = marks[0] - 1                     # PACERST cycle is one before the first PACE
    for k, t in enumerate(marks[1:], start=1):
        ideal = arm + int(k * 100.5)
        assert t == ideal, (k, t, ideal)
    # 38 completions => 1900.5 cycles: the fractional part must be carried
    assert marks[-1] - arm == int((len(marks) - 1) * 100.5)


def test_pace_survives_the_24_bit_boundary():
    """The deadline is next_int + next_frac, not a 24.8 word: pacing must stay
    exact when the cycle counter crosses 2**24 (the old 24-bit integer part
    truncated there and PACE free-ran, one completion per cycle)."""
    src = """
        CFG PERIOD0, 0x80
        CFG PERIOD1, 0x64
        PACERST
    loop:
        PACE
        ADDI r0, 1
        JMP loop
    """
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    m.cycle = 0x00FFF000                   # injected: just below 2**24
    marks = []
    prev = 0
    for _ in range(110000):
        m.step()
        r0 = m.engines[0].regs[0]
        if r0 != prev:
            marks.append(m.cycle - 1)
            prev = r0
    assert marks[-1] > 0x01000000          # the run really crossed 2**24
    deltas = [marks[k + 1] - marks[k] for k in range(len(marks) - 1)]
    # the first interval is period-1: PACERST arms at `cycle`, and the PACE
    # issued one cycle later completes immediately, so it advances the
    # deadline by one full period from the arm cycle
    assert deltas[0] == 99, deltas[0]
    steady = deltas[1:]
    assert len(steady) >= 1000
    assert all(d in (100, 101) for d in steady)      # floor/ceil(100.5)
    assert all(d != 1 for d in steady)               # never free-running
    assert abs(sum(steady) / len(steady) - 100.5) < 0.01


def test_pace_completes_immediately_when_behind():
    src = "    CFG PERIOD0, 0x10\n    PACERST\n    WAITC 100\n    PACE\n    LDI r0, 1\n"
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    while m.engines[0].pc != 3:
        m.step()
    t0 = m.cycle
    m.step()
    assert m.engines[0].pc == 4
    assert m.cycle - t0 == 1           # deadline long past: no stall


# ---------------------------------------------------------------------------
# WAITP: level, timestamp, timeout
# ---------------------------------------------------------------------------
def test_waitp_level_and_timestamp():
    src = "    WAITP UI, 0x01, 1\n    LDI r0, 0x55\n"
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    m.ui_in = 0
    m.step()                     # issue cycle: no match
    m.step()                     # still waiting
    assert m.engines[0].wait_active == 1
    m.ui_in = 0x01
    m.step()                     # match on this cycle
    assert m.engines[0].wait_active == 0
    assert m.engines[0].ts_event == m.cycle - 1
    assert m.engines[0].regs[0] == 0       # LDI not executed yet
    m.step()
    assert m.engines[0].regs[0] == 0x55


def test_waitp_level_zero_matches_when_clear():
    src = "    WAITP UI, 0x03, 0\n    LDI r0, 1\n"
    m = run_eng(src, ui_in=0x04, cycles=10)     # mask bits 1:0 already 0
    assert m.engines[0].regs[0] == 1


def test_waitp_timeout():
    src = """
        CFG TIMEOUT, 1
        WAITP UI, 0x01, 1
        LDI r0, 0x77
        HALT
    """
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    m.ui_in = 0
    n = 0
    while m.engines[0].regs[0] != 0x77:
        m.step()
        n += 1
        assert n < 1000
    # CFG (1) + WAITP (issue + 256 stall cycles) + LDI
    assert n == 1 + 257 + 1
    assert m.engines[0].timeout_flag == 1
    assert m.engines[0].wait_active == 0


def test_waitp_match_cancels_timeout_window():
    src = "    CFG TIMEOUT, 1\n    WAITP UI, 0x01, 1\n    HALT\n"
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    m.ui_in = 0
    m.step()
    m.ui_in = 1
    for _ in range(5):
        m.step()
    assert m.engines[0].timeout_flag == 0
    assert m.engines[0].halted == 1


def test_irqwait_timeout():
    src = "    CFG TIMEOUT, 1\n    IRQWAIT 3\n    LDI r0, 1\n"
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    for _ in range(400):
        m.step()
        if m.engines[0].regs[0] == 1:
            break
    assert m.engines[0].regs[0] == 1
    assert m.engines[0].timeout_flag == 1


# ---------------------------------------------------------------------------
# Side-set
# ---------------------------------------------------------------------------
def test_side_set_driven_on_every_stall_cycle():
    src = """
        CFG SIDE, 0x00          ; en=0 first
        CFG SIDE, 0xA0          ; en=1, bank UO (1), base 0, width 1
        [ss=1] WAITC 6
        HALT
    """
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    m.step()                     # CFG (en=0)
    m.step()                     # CFG SIDE enables side-set
    seen = []
    for _ in range(6):           # WAITC 6 occupies 6 cycles
        assert m.engines[0].run
        m.step()
        seen.append(m.uo_out & 1)
    assert seen == [1] * 6, seen


def test_side_set_uio_sets_output_enable():
    src = """
        CFG SIDE, 0xC8          ; en, bank UIO, base 2, width 1
        [ss=1] NOP
        HALT
    """
    m = run_eng(src, cycles=2)          # sample while the NOP is in flight
    assert (m.uio_oe >> 2) & 1 == 1
    assert (m.uio_out >> 2) & 1 == 1


# ---------------------------------------------------------------------------
# ALU flags
# ---------------------------------------------------------------------------
def _alu(src):
    return run_eng(src, cycles=50).engines[0]


def test_add_carry_and_zero():
    e = _alu("    LDI r0, 0xFF\n    ADDI r0, 1\n    HALT\n")
    assert e.regs[0] == 0x00 and e.c == 1 and e.z == 1


def test_sub_borrow():
    e = _alu("    LDI r0, 0x00\n    SUBI r0, 1\n    HALT\n")
    assert e.regs[0] == 0xFF and e.c == 1 and e.n == 1 and e.z == 0
    e = _alu("    LDI r0, 0x05\n    CMPI r0, 0x05\n    HALT\n")
    assert e.c == 0 and e.z == 1


def test_adc_sbc_chain():
    e = _alu("    LDI r0, 0xFF\n    ADDI r0, 1\n    LDI r1, 0x10\n    ADCI r1, 0\n    HALT\n")
    assert e.regs[1] == 0x11 and e.c == 0
    e = _alu("    LDI r0, 0x00\n    SUBI r0, 1\n    LDI r1, 0x10\n    SBCI r1, 0\n    HALT\n")
    assert e.regs[1] == 0x0F


def test_shift_by_zero_clears_carry_and_keeps_value():
    for op in ("SHLI", "SHRI", "ASRI", "ROLI", "RORI"):
        e = _alu(f"    LDI r0, 0x00\n    SUBI r0, 1\n    LDI r0, 0x81\n"
                 f"    CMPI r0, 0xFF\n    {op} r0, 0\n    HALT\n")
        assert e.regs[0] == 0x81, op
        assert e.c == 0, op


def test_shift_and_rotate_results():
    e = _alu("    LDI r0, 0x80\n    SHLI r0, 1\n    HALT\n")
    assert e.regs[0] == 0x00 and e.c == 1
    e = _alu("    LDI r0, 0x81\n    ROLI r0, 1\n    HALT\n")
    assert e.regs[0] == 0x03 and e.c == 1
    e = _alu("    LDI r0, 0x81\n    RORI r0, 1\n    HALT\n")
    assert e.regs[0] == 0xC0 and e.c == 1
    e = _alu("    LDI r0, 0x80\n    SHRI r0, 4\n    HALT\n")
    assert e.regs[0] == 0x08 and e.c == 0


def test_asr_fills_exactly_n_sign_bits():
    e = _alu("    LDI r0, 0x80\n    ASRI r0, 1\n    HALT\n")
    assert e.regs[0] == 0xC0
    e = _alu("    LDI r0, 0x80\n    ASRI r0, 2\n    HALT\n")
    assert e.regs[0] == 0xE0 and e.c == 0
    e = _alu("    LDI r0, 0x7F\n    ASRI r0, 3\n    HALT\n")
    assert e.regs[0] == 0x0F


def test_register_shift_uses_rs_as_count():
    e = _alu("    LDI r1, 3\n    LDI r0, 0x80\n    SHR r0, r1\n    HALT\n")
    assert e.regs[0] == 0x10


def test_inc_dec_wrap_flags():
    e = _alu("    LDI r0, 0xFF\n    INC r0\n    HALT\n")
    assert e.regs[0] == 0 and e.z == 1 and e.c == 1
    e = _alu("    LDI r0, 0x00\n    DEC r0\n    HALT\n")
    assert e.regs[0] == 0xFF and e.c == 1 and e.n == 1


def test_djnz_sets_flags_and_loops():
    e = _alu("    LDI r2, 3\n    LDI r0, 0\n  l: ADDI r0, 1\n    DJNZ r2, l\n    HALT\n")
    assert e.regs[0] == 3 and e.regs[2] == 0 and e.z == 1


# ---------------------------------------------------------------------------
# Jumps / IRQ / barriers
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("setup,src,expect", [
    ("    LDI r0, 0\n", "    LDI r0, 0\n    JZ  t\n    LDI r1, 1\n  t: HALT\n", 0),
    ("    LDI r0, 1\n", "    LDI r0, 1\n    JZ  t\n    LDI r1, 1\n  t: HALT\n", 1),
    ("", "    LDI r0, 0\n    SUBI r0, 1\n    JC  t\n    LDI r1, 1\n  t: HALT\n", 0),
    ("", "    LDI r0, 0x80\n    LDI r0, 0x00\n    JN  t\n    LDI r1, 1\n  t: HALT\n", 1),
])
def test_conditional_jumps(setup, src, expect):
    e = _alu(src)
    assert e.regs[1] == expect


def test_irq_set_wait_clear():
    src = """
        IRQSET 2
        IRQWAIT 2
        IRQCLR 2
        IRQWAIT 2
        HALT
    """
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    for _ in range(20):
        m.step()
    assert m.irq == 0
    # the trailing IRQWAIT correctly blocks forever: nothing sets IRQ 2 again
    assert m.engines[0].halted == 0
    assert m.engines[0].pc == 3
    assert m.engines[0].wait_active == 1


def test_barrier_synchronises_running_engines():
    prog = "    BAR 0\n    ADDI r0, 1\n    HALT\n"
    words = build(prog)["programs"][0]
    m = model.ProteusModel()
    for eng in (0, 1):
        m.load(eng, words)
        m.start(eng)
    # engine 0 needs 1 extra cycle before the barrier (different start phase)
    m.step()
    for _ in range(40):
        m.step()
        if all(m.engines[e].regs[0] == 1 for e in (0, 1)):
            break
    assert [m.engines[e].regs[0] for e in (0, 1)] == [1, 1]
    assert m.barrier_arrived == [0, 0, 0, 0]


def test_barrier_releases_all_waiters_in_the_same_cycle():
    # Regression: the model used to advance only the last arriver, leaving the
    # early arriver stalled while it re-armed the barrier.
    prog = "    BAR 0\n    LDI r0, 1\n    HALT\n"
    words = build(prog)["programs"][0]
    m = model.ProteusModel()
    for eng in (0, 1):
        m.load(eng, words)
        m.start(eng)
    pcs = [0, 0]
    for _ in range(20):
        m.step()
        pcs = [m.engines[e].pc for e in (0, 1)]
        if pcs != [0, 0]:
            break
    assert pcs == [1, 1], f"barrier released engines on different cycles: pcs={pcs}"
    assert m.barrier_arrived == [0, 0, 0, 0]


def test_barrier_ignores_engines_that_are_not_running():
    prog = "    BAR 1\n    LDI r0, 9\n    HALT\n"
    words = build(prog)["programs"][0]
    m = model.ProteusModel()
    m.load(2, words)
    m.start(2)                     # only engine 2 runs
    for _ in range(10):
        m.step()
    assert m.engines[2].regs[0] == 9


# ---------------------------------------------------------------------------
# FIFOs
# ---------------------------------------------------------------------------
def test_push_blocks_until_host_pops():
    src = "\n".join(["    LDI r0, 0x%02x" % k + "\n    PUSH r0"
                     for k in range(model.FIFO_DEPTH)])
    src += "\n    LDI r0, 0x99\n    PUSH r0\n    LDI r1, 0x42\n    HALT\n"
    m = model.ProteusModel()
    m.load(0, build(src)["programs"][0])
    m.start(0)
    for _ in range(60):
        m.step()
    e = m.engines[0]
    assert len(e.out_fifo) == model.FIFO_DEPTH
    assert e.halted == 0 and e.regs[1] == 0        # blocked on the next PUSH
    assert m.pop_out(0) == 0x00
    for _ in range(5):
        m.step()
    assert len(e.out_fifo) == model.FIFO_DEPTH
    assert list(e.out_fifo)[-1] == 0x99
    assert e.regs[1] == 0x42 and e.halted == 1


def test_pushn_sets_nf_and_continues():
    src2 = "\n".join(["    LDI r0, 0x%02x" % k + "\n    PUSH r0"
                      for k in range(model.FIFO_DEPTH)])
    src2 += "\n    LDI r0, 0x99\n    PUSHN r0\n    LDI r1, 0x42\n    HALT\n"
    m = run_eng(src2, cycles=80)
    assert m.engines[0].halted == 1
    assert m.engines[0].nf_flag == 1
    assert m.engines[0].regs[1] == 0x42
    assert len(m.engines[0].out_fifo) == model.FIFO_DEPTH


def test_pull_blocks_and_pulln_sets_nf():
    src = "    PULL r0\n    LDI r1, 1\n    HALT\n"
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    for _ in range(10):
        m.step()
    assert m.engines[0].halted == 0 and m.engines[0].regs[1] == 0
    m.push_in(0, 0x7E)
    for _ in range(3):
        m.step()
    assert m.engines[0].regs[0] == 0x7E and m.engines[0].halted == 1

    src = "    PULLN r0\n    LDI r1, 1\n    HALT\n"
    m = run_eng(src, cycles=10)
    assert m.engines[0].regs[0] == 0        # unchanged
    assert m.engines[0].nf_flag == 1
    assert m.engines[0].halted == 1


# ---------------------------------------------------------------------------
# Pin fabric
# ---------------------------------------------------------------------------
def test_uio_write_sets_output_enable_and_dirc_clears_it():
    src = """
        OUTP UIO, 0x0F, r0
        DIRC UIO, 0x03
        HALT
    """
    m = run_eng(src, cycles=10)
    assert m.uio_oe == 0x0C
    assert m.uio_out == 0x00


def test_open_drain_releases_high_bits():
    src = "    ODSET UIO, 0xF0\n    SETP UIO, 0xFF\n    HALT\n"
    m = run_eng(src, cycles=10)
    assert m.uio_od == 0xF0
    assert m.oe_eff == 0x0F            # released bits are not driven


def test_engine_priority_highest_writer_wins():
    prog_lo = "    SETP UIO, 0x01\n    HALT\n"
    prog_hi = "    CLRP UIO, 0x01\n    HALT\n"
    m = model.ProteusModel()
    m.load(0, build(prog_lo)["programs"][0])
    m.load(1, build(prog_hi)["programs"][0])
    m.start(0)
    m.start(1)
    for _ in range(4):
        m.step()
    assert (m.uio_out & 0x01) == 0     # engine 1 (higher) wins


def test_collision_is_sticky_and_clearable():
    src = "    SETP UIO, 0x01\n    WAITC 4\n    HALT\n"
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    m.uio_in = 0x00                    # somebody else holds the pad low
    for _ in range(4):
        m.step()
    assert m.collision & 0x01
    m.clear_collision()
    assert m.collision == 0


# ---------------------------------------------------------------------------
# Capture and time
# ---------------------------------------------------------------------------
def test_capture_records_edges_with_timestamps():
    src = "    WAITC 3\n    HALT\n"
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.capture_en = 0x08
    m.start(0)
    m.uio_in = 0
    m.step()
    m.uio_in = 0x08
    m.step()
    m.uio_in = 0x00
    m.step()
    events = list(m.capture)
    assert len(events) == 2
    ts, pin, level = events[0]
    assert pin == 3 and level == 1
    assert ts == 1
    assert events[1][0] == 2 and events[1][2] == 0


def test_capture_overflow_flag():
    m = model.ProteusModel()
    for k in range(model.CAPTURE_DEPTH + 1):
        m._capture_push(k, 1, k & 1)
    assert m.capture_overflow == 1
    assert len(m.capture) == model.CAPTURE_DEPTH


def test_capture_instruction_pushes_software_event():
    src = "    CAPTURE 0x05\n    HALT\n"
    m = run_eng(src, cycles=5)
    assert len(m.capture) == 1
    ts, pin, level = m.capture[0]
    assert (pin, level) == (5 & 0xF, 0)
    assert ts == 0


def test_meas_reads_delta_from_ts_event():
    src = """
        CFG TIMEOUT, 1
        WAITP UI, 0x01, 1
        WAITC 4
        MEASLO r0
        MEASHI r1
        HALT
    """
    words = build(src)["programs"][0]
    m = model.ProteusModel()
    m.load(0, words)
    m.start(0)
    m.ui_in = 0
    for _ in range(4):
        m.step()
    m.ui_in = 1
    while not m.engines[0].halted:
        m.step()
    e = m.engines[0]
    assert (e.regs[1] << 8) | e.regs[0] == 5    # WAITC 4 + 1 pipeline cycle


def test_tslo_tshi_read_the_cycle_counter():
    src = "    WAITC 300\n    TSLO r0\n    TSHI r1\n    HALT\n"
    m = run_eng(src, cycles=400)
    assert (m.engines[0].regs[1] << 8) | m.engines[0].regs[0] == 300


# ---------------------------------------------------------------------------
# ASSERT / HALT / undefined opcodes
# ---------------------------------------------------------------------------
def test_assert_sets_error_flag():
    e = _alu("    LDI r0, 1\n    ASSERT r0, 0x02\n    HALT\n")
    assert e.error_flag == 1
    e = _alu("    LDI r0, 2\n    ASSERT r0, 0x02\n    HALT\n")
    assert e.error_flag == 0


def test_halt_clears_run_and_does_not_advance():
    e = _alu("    HALT\n")
    assert e.run == 0 and e.halted == 1 and e.pc == 0


def test_undefined_opcode_executes_as_nop():
    m = model.ProteusModel()
    m.load(0, [(0x3F << 17)] * 3)        # 0x3F has no instruction in the table
    m.start(0)
    for _ in range(3):
        m.step()
    assert m.engines[0].pc == 3          # advanced like a NOP
    assert m.engines[0].halted == 0


# ---------------------------------------------------------------------------
# Program depth parameterisation
# ---------------------------------------------------------------------------
def test_depth_parameter_and_load_overflow():
    m = model.ProteusModel(prog_depth=64)
    assert len(m.engines[0].prog) == 64
    with pytest.raises(ValueError):
        m.load(0, [0] * 65)
    m64 = model.ProteusModel(prog_depth=64)
    m64.load(0, [isa.enc("NOP")] * 40)
    m64.start(0)
    assert len(m64.engines[0].prog) == 64
    m32 = model.ProteusModel()
    with pytest.raises(ValueError):
        m32.load(0, [0] * 33)
