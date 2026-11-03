"""DUT-vs-model differential test: one program, two implementations, every cycle.

``v2/tools/model.py`` is the executable specification for ``v2/src/``.  This
test is the missing half of that claim: for each generated program the *same*
words are loaded into the real ``tt_um_proteus`` over the host SPI
(``v2/sim/host.py``) and into ``ProteusModel``, the model is aligned to the
DUT's run strobe, and every cycle compares

    uio_out, uio_oe, uio_od, uo_out[7:2], the level on uio_in,
    r0..r7, pc, z/c/n/flags, in/out FIFO contents and counts, halted, run,
    irq, collision, capture overflow, and every capture event pushed.

Hybrid v2 scope
---------------
The DUT is the 3-engine top (``v2/src/tt_um_proteus.v``) running **engine 0**
only; engines 1 and 2 are asserted idle every cycle (halted, PC 0), which is
itself a v2 wiring check (`run_reg[1]`/`run_reg[2]` are never set, so a run-bit
or engine-index miswire shows up as a mismatch rather than as a silent pass).

The corpus is the **non-assist ISA subset**: ``v2/tools/diffgen.py`` emits no
``LDAS``/``STAS``/``ASST`` (asserted before the run, see ``_corpus()``).  The
v2 model reproduces assist *register, queue and timing* accounting, not the
assist data path, so a cycle-exact comparison is only defined for the engine
core that v1 and v2 share.  The assist side is gated by
``v2/tools/selfcheck.py``, ``v2/tb/tb_csr.v`` and ``v2/sim/test_protocols.py``.
With every PINCFG register at its reset value (``en=0``) the assist pin-merge
stage in ``v2/src/proteus_assist.v`` is the identity, so the pads are
engine-owned and the v1 comparison contract carries over unchanged.

Alignment
---------
``proteus_engine.v`` needs one extra cycle for a run rising edge (``restart``
gates ``exec_act`` so a stale PC never executes).  The monitor samples
``run_reg[0]`` on every posedge; at the edge where it reads 1 it takes the DUT's
``cycle`` value ``c``, sets ``model.cycle = c + 1`` and calls ``model.start(0)``.
One edge later it checks the restart state, and from then on it performs exactly
one ``model.step()`` per DUT clock, comparing after each.  ``model.step()`` for
interval ``k`` therefore runs with ``model.cycle == k``, so every timestamped
instruction (``TSLO``/``MEASLO``/``CAPTURE``) sees the same cycle value the RTL
does -- without that, a cycle-index comparison would be meaningless.

Pad model
---------
``uio_in = (uio_out & uio_oe) | ext`` is applied by this test after every
posedge, from the just-committed fabric registers, and re-verified from the DUT
on the next edge (``pad_level``).  ``ext`` is a per-program constant external
pull, so open-drain release and the collision detector are exercised.  A write
issued after posedge ``k`` is what the DUT samples at posedge ``k + 1``, which
is the same one-cycle convention ``v2/tools/model.py`` documents.  ``ui_in[7:3]``
carries a constant fabric input; ``ui_in[2:0]`` stay idle (CS_N high) so no host
command can land mid-run.

Excluded by construction, not masked here
-----------------------------------------
``v2/tools/diffgen.py`` keeps programs inside the subset where both sides are
*supposed* to agree: at most 4 FIFO pushes and 4 capture events (the RTL
parameters and the model constants are both 4), no engine access to
``uo_out[1:0]`` (host IRQ/MISO while ``host_en=1``), and no assist CSR
instruction.  The first two keep every program inside the shared buffer depth;
the third removes a pin that is not fabric-owned in that mode; the fourth
keeps the comparison inside the modelled subset.

Run:  cd v2/sim && make diff        (or: make COCOTB_TEST_MODULES=test_diff)
Env:  DIFF_SEEDS (default 200), DIFF_CYCLES (default 3000)
"""

from __future__ import annotations

import os
import sys

import cocotb
from cocotb.triggers import RisingEdge, Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_TOOLS = os.path.abspath(os.path.join(_HERE, "..", "tools"))
for _path in (_HERE, _TOOLS):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import diffgen                     # noqa: E402
import isa                         # noqa: E402
import model as golden             # noqa: E402

from host import (                 # noqa: E402
    ProteusHost,
    prog_addr,
    reset,
    start_clock,
    RA_CAP_EN,
    RA_RUN,
)

N_SEEDS = int(os.environ.get("DIFF_SEEDS", "200"))
MAX_CYCLES = int(os.environ.get("DIFF_CYCLES", "3000"))
CLK_NS = 10.0                      # host SPI runs at clk/8, see ProteusHost.byte
MIN_TOTAL_CYCLES = 3000

# uo_out bits the engines own while the host is active; [1:0] are the host's
# IRQ and MISO pins (v2/src/tt_um_proteus.v pin assign).
UO_FABRIC_MASK = 0xFC

# Engines the corpus does not run: v2 has three lanes and the harness drives
# only lane 0.  They must stay idle (reset leaves halted=1, PC=0) for the whole
# run -- an engine-index or run-bit miswire in the 3-engine top would move one
# of them, and the pad comparison would then fail for an unexplained reason.
IDLE_ENGINES = (("1", "u_eng1"), ("2", "u_eng2"))


class Mismatch(AssertionError):
    def __init__(self, cycle: int, field: str, expected, got):
        self.cycle = cycle
        self.field = field
        self.expected = expected
        self.got = got
        super().__init__(
            f"cycle {cycle}: {field} model={_fmt(expected)} rtl={_fmt(got)}"
        )


def _fmt(v) -> str:
    if v is None:
        return "X"
    if isinstance(v, int):
        return f"0x{v:x}"
    return repr(v)


def _v(handle):
    """Integer value of a signal, or None when it holds X/Z."""
    try:
        return int(handle.value)
    except ValueError:
        return None


def _vec(handle):
    """Integer list for an unpacked array, or None when any element is X/Z."""
    try:
        return [int(v) for v in handle.value]
    except ValueError:
        return None


class DiffRun:
    """Drive the model in lockstep with the DUT and compare every cycle."""

    def __init__(self, dut, prog: diffgen.Program):
        self.dut = dut
        self.prog = prog
        self.eng = dut.u_eng0

        m = golden.ProteusModel(nsms=3)      # the v2 build has three engines
        m.load(0, prog.words)
        for byte in prog.in_bytes:
            if not m.push_in(0, byte):
                raise RuntimeError("model input FIFO rejected a prefilled byte")
        m.capture_en = prog.cap_en
        m.ui_in = (prog.fabric_in & 0x1F) << 3   # fab_ui while host_en=1
        m.uio_in = prog.ext
        # The DUT tracks uio_in from reset; with the pad held at `ext` through
        # the whole load, its idle "previous pin state" is ext.
        m._prev_capture_pins = prog.ext
        self.m = m

        self.state = 0        # 0 = waiting for RUN, 1 = restart edge, 2 = lockstep
        self.cycles = 0
        self.cycle_index = 0
        self.error: Mismatch | None = None
        self._written = prog.ext   # last level presented on uio_in
        self._cap_seen = 0
        self._pre = (0, 0, 0, 0)
        self._prev_dut = (0, 0, 0)

    # ------------------------------------------------------------------ pad
    def _drive_pad(self) -> None:
        """Present the pad level for the interval that follows.

        ``uio_in = (uio_out & uio_oe) | ext`` -- the rule ``sim/host.py`` uses,
        plus a constant external pull so open-drain release and the collision
        detector are exercised.  The value latched by the DUT at the next
        posedge is this level, which is what the model consumes one step later;
        ``pad_level`` re-reads the pad at that posedge to prove it landed.
        """
        uio_out = _v(self.dut.uio_out)
        uio_oe = _v(self.dut.uio_oe)
        if uio_out is None or uio_oe is None:
            raise Mismatch(self.cycle_index, "uio_out/uio_oe", "defined", None)
        self._written = (uio_out & uio_oe) | (self.prog.ext & 0xFF)
        self.dut.uio_in.value = self._written

    # -------------------------------------------------------------- compare
    def _compare(self, restart: bool = False) -> None:
        m, e, eng, dut = self.m, self.m.engines[0], self.eng, self.dut
        cyc = self.cycle_index

        def chk(field, expected, got):
            if got is None:
                raise Mismatch(cyc, field, expected, None)
            if expected != got:
                raise Mismatch(cyc, field, expected, got)

        # --- the pad: the level presented after the last edge is the level the
        # DUT holds at this edge, and it is what the model just consumed.
        chk("pad_level", self._written, _v(dut.uio_in))

        # --- engine datapath ------------------------------------------------
        chk("pc", e.pc, _v(eng.pc_r))
        chk("halted", e.halted, _v(eng.halted_r))
        chk("run", e.run, _v(dut.run_reg) & 1)
        if not restart:
            regs = _vec(eng.regs)
            if regs is None:
                raise Mismatch(cyc, "regs", e.regs, None)
            for i in range(8):
                chk(f"r{i}", e.regs[i], regs[i])
            chk("z", e.z, _v(eng.z_r))
            chk("c", e.c, _v(eng.c_r))
            chk("n", e.n, _v(eng.n_r))

        # --- the two lanes the corpus does not run must stay idle --------
        for lane, name in IDLE_ENGINES:
            other = getattr(dut, name)
            chk(f"eng{lane}.halted", 1, _v(other.halted_r))
            chk(f"eng{lane}.pc", 0, _v(other.pc_r))
            chk(f"eng{lane}.out_cnt", 0, _v(other.out_cnt))

        # --- pin fabric -----------------------------------------------------
        chk("uio_out", m.uio_out, _v(dut.uio_out))
        chk("uio_oe", m.oe_eff, _v(dut.uio_oe))          # the port is oe_eff
        chk("uio_od", m.uio_od, _v(dut.od_q))
        uo = _v(dut.uo_out)
        chk("uo_out[7:2]", m.uo_out & UO_FABRIC_MASK,
            None if uo is None else uo & UO_FABRIC_MASK)
        chk("irq", m.irq, _v(dut.irq))
        coll = _v(dut.collision_q)
        if coll is not None and m.collision != coll:
            cocotb.log.error(
                "collision differs at cycle %d\n"
                "  model pre-step: out=%02x oe_raw=%02x od=%02x pad=%02x\n"
                "  rtl   prev cyc: out=%02x oe_raw=%02x od=%02x",
                cyc, self._pre[0], self._pre[1], self._pre[2], self._pre[3],
                self._prev_dut[0], self._prev_dut[1], self._prev_dut[2])
        chk("collision", m.collision, coll)

        # --- FIFOs: logical contents and count ------------------------------
        in_cnt, in_rd = _v(eng.in_cnt), _v(eng.in_rd)
        in_mem = _vec(eng.in_mem)
        if None in (in_cnt, in_rd) or in_mem is None:
            raise Mismatch(cyc, "in_fifo", list(e.in_fifo), None)
        chk("in_fifo", list(e.in_fifo),
            [in_mem[(in_rd + i) % len(in_mem)] for i in range(in_cnt)])

        out_cnt, out_rd = _v(eng.out_cnt), _v(eng.out_rd)
        out_mem = _vec(eng.out_mem)
        if None in (out_cnt, out_rd) or out_mem is None:
            raise Mismatch(cyc, "out_fifo", list(e.out_fifo), None)
        chk("out_fifo", list(e.out_fifo),
            [out_mem[(out_rd + i) % len(out_mem)] for i in range(out_cnt)])

        # --- capture --------------------------------------------------------
        cap_cnt = _v(dut.cap_cnt)
        chk("capture_count", len(m.capture), cap_cnt)
        chk("capture_overflow", m.capture_overflow, _v(dut.cap_ovf))
        if cap_cnt and cap_cnt != self._cap_seen:
            cmem = _vec(dut.cap_mem)
            wp = _v(dut.cap_wp)
            if cmem is None or wp is None:
                raise Mismatch(cyc, "capture_newest", m.capture[-1], None)
            entry = cmem[(wp - 1) % len(cmem)]
            chk("capture_newest", list(m.capture[-1]),
                [(entry >> 5) & 0xFFFFFFFF, (entry >> 1) & 0xF, entry & 1])
            self._cap_seen = cap_cnt

    # ------------------------------------------------------------------ run
    async def run(self) -> None:
        clk = self.dut.clk
        try:
            while True:
                await RisingEdge(clk)
                # ``RisingEdge`` resumes before the design's non-blocking
                # updates, so every read here would be one cycle stale; a
                # picosecond settles the edge.  Verified with a probe: at the
                # edge ``pc_r`` still reads the old value, one ps later it is
                # the value the cycle produced.
                await Timer(1, unit="ps")
                if self.state == 0:
                    if _v(self.dut.run_reg) & 1:    # the RUN write landed
                        cycle = _v(self.dut.cycle)
                        self.m.cycle = (cycle + 1) & golden.ALWAYS
                        self.m.start(0)
                        self.state = 1
                elif self.state == 1:
                    self.cycle_index = self.m.cycle
                    self._compare(restart=True)
                    self.state = 2
                else:
                    self.cycle_index = self.m.cycle
                    self.m.uio_in = self._written
                    self._pre = (self.m.uio_out, self.m.uio_oe,
                                 self.m.uio_od, self.m.uio_in)
                    self.m.step()                  # models the cycle just ended
                    self.cycles += 1
                    self._compare()
                    self._prev_dut = (_v(self.dut.uio_q), _v(self.dut.oe_q),
                                      _v(self.dut.od_q))
                    if self.m.engines[0].halted or self.cycles >= MAX_CYCLES:
                        return
                self._drive_pad()                  # for the next interval
        except Mismatch as exc:
            self.error = exc


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
def _corpus() -> list[diffgen.Program]:
    progs = [diffgen.gen_program(seed) for seed in range(N_SEEDS)]
    progs.extend(diffgen.corner_programs())
    # The compared subset excludes the assist CSRs: v2/tools/model.py models
    # their register/queue accounting, not the data path, so a cycle-exact
    # comparison would be comparing a model approximation to the RTL.  Assert
    # the invariant instead of trusting the generator to keep it.
    for prog in progs:
        for word in prog.words:
            name = isa.OPC.get(isa.fields(word)["op"], ("?", "none"))[0]
            if name in diffgen.ASSIST_OPS:
                raise AssertionError(
                    f"seed {prog.seed} ({prog.kind}) emits {name}: the diff "
                    "corpus must stay inside the non-assist ISA subset"
                )
    return progs


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def proteus_diff(dut):
    await start_clock(dut, CLK_NS)
    host = ProteusHost(dut, clk_ns=CLK_NS)

    corpus = _corpus()
    total_cycles = 0
    compared = 0
    cut_short = 0

    for prog in corpus:
        await reset(dut, host)

        # ui_in[7:3] is the fabric input the program reads through INPR UI;
        # ui_in[2:0] stay idle (CS_N high) once the load finishes.
        host._fabric_in = (prog.fabric_in & 0x1F) << 3
        dut.uio_in.value = prog.ext
        await Timer(100, unit="ns")

        # One WRITE_ADDR frame with auto-increment for the whole program: four
        # bytes per word, where lane 3 is the program-memory hole (the top
        # drops `pm_byte == 3`).  Same bytes as load_program() lane by lane,
        # ~35% fewer host clocks, which is what keeps a 200-program corpus
        # inside the runtime budget.
        payload = bytearray()
        for word in prog.words:
            payload += bytes((word & 0xFF, (word >> 8) & 0xFF,
                              (word >> 16) & 0xFF, 0))
        await host.write_regs(prog_addr(0, 0, 0), bytes(payload))
        for byte in prog.in_bytes:
            await host.push_in(0, byte)
        if prog.cap_en:
            await host.write_reg(RA_CAP_EN, prog.cap_en)

        runner = DiffRun(dut, prog)
        task = cocotb.start_soon(runner.run())
        await host.write_reg(RA_RUN, 0x01)
        await task

        if runner.error is not None:
            exc = runner.error
            cocotb.log.error(
                "DIFF MISMATCH seed=%d kind=%s cycle=%d field=%s "
                "model=%s rtl=%s",
                prog.seed, prog.kind, exc.cycle, exc.field,
                _fmt(exc.expected), _fmt(exc.got),
            )
            cocotb.log.error("program:\n%s", prog.listing())
            raise AssertionError(
                f"seed {prog.seed} ({prog.kind}) cycle {exc.cycle}: "
                f"{exc.field} model={_fmt(exc.expected)} rtl={_fmt(exc.got)}"
            )

        total_cycles += runner.cycles
        compared += 1
        if not runner.m.engines[0].halted:
            cut_short += 1
        cocotb.log.info(
            "[%3d/%d] seed=%-4d %-7s words=%2d cycles=%4d %s",
            compared, len(corpus), prog.seed, prog.kind, len(prog.words),
            runner.cycles, "halt" if runner.m.engines[0].halted else "cut",
        )

    cocotb.log.info(
        "DIFF PASS: %d programs, %d compared cycles, 0 mismatches "
        "(%d cut at the %d-cycle limit)",
        compared, total_cycles, cut_short, MAX_CYCLES,
    )
    assert compared == len(corpus)
    if N_SEEDS >= 200:
        # The acceptance corpus.  A deliberately reduced run (DIFF_SEEDS<n>) is
        # reported as partial rather than failed, so the guard cannot be
        # satisfied by a corpus too small to mean anything.
        assert total_cycles >= MIN_TOTAL_CYCLES, (
            f"only {total_cycles} compared cycles, need >= {MIN_TOTAL_CYCLES}"
        )
    elif total_cycles < MIN_TOTAL_CYCLES:
        cocotb.log.warning(
            "PARTIAL corpus: %d compared cycles (< %d needed for acceptance)",
            total_cycles, MIN_TOTAL_CYCLES,
        )
