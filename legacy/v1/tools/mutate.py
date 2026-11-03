#!/usr/bin/env python3
"""Mutation testing for the PROTEUS RTL against the self-checking benches.

Why this exists
---------------
Every other layer in docs/verification.md answers "does the design behave as
specified".  None of them answers the prior question for a *test*: "would this
bench notice if the design were wrong".  This tool answers it by breaking the
RTL on purpose, one textual mutation at a time, and requiring the bench to say
so.

Method
------
  * ``src/`` is copied into a scratch directory.  The working tree's ``src/`` is
    never modified: a mutation is only ever written into the copy.
  * exactly one mutation is applied to exactly one line, addressed by
    ``file:line`` + the literal substring on that line.  The substring must
    occur exactly once on that line, or the run aborts -- a mislocated mutation
    would silently test the unmutated RTL and report a fake survivor.
  * the chosen bench is rebuilt from the *repo's* tb/ file (so bench assertions
    can never be mutated) plus the mutated ``src/`` copy, and run under a
    bounded timeout.
  * verdict per bench: KILLED if the process exits non-zero, times out, or
    prints ``FAIL``; SURVIVED if it reaches its own PASS marker.  A mutant that
    does not compile is reported as COMPILE and is excluded from the kill rate
    (it is not a behavioural mutant).

Commands
--------
    python3 tools/mutate.py --list               # the curated catalogue
    python3 tools/mutate.py --verify-mutations   # spec vs. tree, no simulation
    python3 tools/mutate.py --all                # the full matrix
    python3 tools/mutate.py --only E13,T01       # a subset
    python3 tools/mutate.py --all --append       # append to the raw log

Defaults: benches ``engine`` and ``top``, 180 s per simulation run, raw log
``results/mutation_raw.txt``.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "src"
TB_DIR = ROOT / "tb"

# Every RTL file that participates in a build.  Only the mutated one differs
# from the tree; the rest are restored from the pristine snapshot each time.
RTL_FILES = ("proteus_defs.vh", "proteus_engine.v", "proteus_host.v",
             "tt_um_proteus.v")


# ---------------------------------------------------------------------------
# Benches
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Bench:
    name: str
    tb: str            # tb file, taken from the repo (never mutated)
    units: tuple       # RTL units besides the defs header
    marker: str        # the bench's own PASS line

    def sources(self, src: Path) -> list[str]:
        return [str(TB_DIR / self.tb), str(src / "proteus_defs.vh")] + \
               [str(src / u) for u in self.units]


BENCHES = {
    # Fastest and broadest ISA/stall coverage: instantiates proteus_engine only.
    "engine": Bench(
        name="engine",
        tb="engine_smoke_tb.v",
        units=("proteus_engine.v",),
        marker="==== PASS: all engine smoke checks passed ====",
    ),
    # Real top through the host SPI pins only: host FSM, program byte lanes,
    # pin fabric, capture, barriers, pacer horizon, HALT/RUN retirement.
    "top": Bench(
        name="top",
        tb="top_e2e_tb.v",
        units=("proteus_engine.v", "proteus_host.v", "tt_um_proteus.v"),
        marker="top_e2e_tb PASSED",
    ),
}

DEFAULT_BENCHES = ("engine", "top")


# ---------------------------------------------------------------------------
# Mutation catalogue
#
# Each entry is a bug a person could plausibly write.  ``find`` must be a
# substring of ``line`` in ``file`` and must occur there exactly once.
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Mut:
    id: str
    file: str
    line: int
    find: str
    repl: str
    cat: str
    desc: str


MUTATIONS = [
    # ---------------------------------------------------------------- ALU --
    Mut("A01", "proteus_engine.v", 408,
        "+ {1'b0, b};", "- {1'b0, b};", "alu",
        "ADD/ADDI adds -> subtracts"),
    Mut("A02", "proteus_engine.v", 418,
        "- {1'b0, b};", "+ {1'b0, b};", "alu",
        "SUB/SUBI/CMP subtracts -> adds"),
    Mut("A03", "proteus_engine.v", 419,
        "co = t[8];", "co = ~t[8];", "alu",
        "subtract borrow flag inverted"),
    Mut("A04", "proteus_engine.v", 413,
        "+ {8'd0, cin};", ";", "alu",
        "ADC/ADCI drops the carry-in"),
    Mut("A05", "proteus_engine.v", 432,
        "4'd8 - shn", "shn - 4'd1", "alu",
        "SHL carry uses the SHR carry formula"),
    Mut("A06", "proteus_engine.v", 446,
        "(a[7] ? (8'hFF << (4'd8 - shn)) : 8'h00)", "8'h00", "alu",
        "ASR loses the sign fill (becomes SHR)"),
    Mut("A07", "proteus_engine.v", 456,
        "co = r[0];", "co = r[7];", "alu",
        "ROL carry taken from the wrong end"),
    Mut("A08", "proteus_engine.v", 465,
        "co = r[7];", "co = r[0];", "alu",
        "ROR carry taken from the wrong end"),
    Mut("A09", "proteus_engine.v", 651,
        "alu_f(OP_ADD, regs[f_rd], 8'h01, c_r)",
        "alu_f(OP_SUB, regs[f_rd], 8'h01, c_r)", "alu",
        "INC decrements"),
    Mut("A10", "proteus_engine.v", 665,
        "alu_f(OP_SUB, regs[f_rd], 8'h01, c_r)",
        "alu_f(OP_ADD, regs[f_rd], 8'h01, c_r)", "alu",
        "DEC increments"),
    Mut("A11", "proteus_engine.v", 637,
        "alu_f(OP_SUB, 8'h00, regs[f_rd], c_r)",
        "alu_f(OP_ADD, 8'h00, regs[f_rd], c_r)", "alu",
        "NEG becomes a no-op (0-x -> 0+x)"),
    Mut("A12", "proteus_engine.v", 405,
        "{1'b0, b[2:0]}", "{1'b0, b[3:1]}", "alu",
        "shift/rotate count read one bit too high"),

    # ------------------------------------------------- pacer / time / wait --
    Mut("P01", "proteus_engine.v", 834,
        "if (cycle >= next_int_r)", "if (cycle > next_int_r)", "pacer",
        "PACE deadline compare off by one"),
    Mut("P02", "proteus_engine.v", 838,
        "{31'd0, n_next_carry}", "{31'd0, 1'b0}", "pacer",
        "pacer fractional carry dropped from the deadline"),
    Mut("P03", "proteus_engine.v", 845,
        "n_next_int  = cycle;", "n_next_int  = cycle + 32'd1;", "pacer",
        "PACERST arms the deadline one cycle late"),
    Mut("P04", "proteus_engine.v", 818,
        "({21'd0, waitc_n} - 32'd1)", "({21'd0, waitc_n})", "waitc",
        "WAITC n occupies n+1 cycles"),
    Mut("P05", "proteus_engine.v", 821,
        "wait_left_r - 32'd1", "wait_left_r - 32'd2", "waitc",
        "WAITC stall counter decrements by two"),
    Mut("P06", "proteus_engine.v", 759,
        "if (wait_left_r <= 32'd1)", "if (wait_left_r < 32'd1)", "timeout",
        "WAITP timeout fires one cycle late"),
    Mut("P07", "proteus_engine.v", 756,
        "{16'h0000, timeout_r, 8'h00}", "{17'h0000, timeout_r, 7'h00}",
        "timeout",
        "WAITP timeout unit 256 -> 128 cycles"),
    Mut("P08", "proteus_engine.v", 750,
        "if (f_rs[2] ? (tmp_v == f_imm) : (tmp_v == 8'h00))",
        "if (f_rs[2] ? (tmp_v == 8'h00) : (tmp_v == f_imm))", "waitp",
        "WAITP level polarity swapped"),

    # ------------------------------------------------------------ control --
    Mut("C01", "proteus_engine.v", 776,
        "3'd1: take = z_r;", "3'd1: take = ~z_r;", "control",
        "JZ takes the opposite condition"),
    Mut("C02", "proteus_engine.v", 778,
        "3'd3: take = c_r;", "3'd3: take = ~c_r;", "control",
        "JC takes the opposite condition"),
    Mut("C03", "proteus_engine.v", 785,
        "& LAST_PC;", "& (LAST_PC - 1);", "control",
        "jump target mask off by one"),
    Mut("C04", "proteus_engine.v", 159,
        "ADDR_ONE = 1;", "ADDR_ONE = 2;", "control",
        "PC increments by two"),
    Mut("C05", "proteus_engine.v", 987,
        "(pc_r == LAST_PC)", "1'b0", "control",
        "PC wrap test removed (rely on width wrap)"),
    Mut("C06", "proteus_engine.v", 365,
        "(f_op == OP_HALT)", "(f_op == OP_NOP)", "control",
        "halt_exec decodes NOP, so HALT does not retire RUN"),
    Mut("C07", "proteus_engine.v", 285,
        "run & ~run_q", "run & run_q", "control",
        "run-rising restart never fires (stale PC executes)"),
    Mut("C08", "proteus_engine.v", 286,
        "& prog_ready_r & ~restart", "& ~restart", "control",
        "engine executes before the program fill is ready"),
    Mut("C09", "proteus_engine.v", 1094,
        "if (fill_cnt == LAST_PC)", "if (fill_cnt == LAST_PC - 1)", "control",
        "prog_ready asserted one word early"),
    Mut("C10", "proteus_engine.v", 254,
        "host_prog_addr <= LAST_ADDR", "host_prog_addr < LAST_ADDR", "control",
        "last program word is dropped / reads 0 (off-by-one)"),

    # -------------------------------------------------------------- FIFOs --
    Mut("F01", "proteus_engine.v", 301,
        "in_full_w   = (in_cnt  == FIFO_FULL)",
        "in_full_w   = (in_cnt  == FIFO_FULL - 1)", "fifo",
        "input-FIFO full comparison flipped (full one early)"),
    Mut("F02", "proteus_engine.v", 853,
        "if (out_cnt < FIFO_FULL)", "if (out_cnt <= FIFO_FULL)", "fifo",
        "PUSH accepted when the output FIFO is full"),
    Mut("F03", "proteus_engine.v", 1184,
        "(host_in_push && (in_cnt < FIFO_FULL))",
        "(host_in_push && (in_cnt <= FIFO_FULL))", "fifo",
        "host push accepted when the input FIFO is full"),
    Mut("F04", "proteus_engine.v", 880,
        "n_nf = 1'b1;", "n_nf = 1'b0;", "fifo",
        "PUSHN on a full FIFO does not flag nf"),

    # --------------------------------------------------------------- pins --
    Mut("G01", "proteus_engine.v", 698,
        "8'hFF, 1'b1)", "8'h00, 1'b1)", "pins",
        "SETP drives 0 instead of 1 (equals CLRP)"),
    Mut("G02", "proteus_engine.v", 704,
        "~tmp_v, 1'b1)", "tmp_v, 1'b1)", "pins",
        "TOGP does not invert the pin snapshot"),
    Mut("G03", "proteus_engine.v", 722,
        "p_oe_val  = (p_oe_val & ~f_imm) | f_imm;",
        "p_oe_val  = p_oe_val & ~f_imm;", "pins",
        "DIRS acts as DIRC (clears instead of sets)"),
    Mut("G04", "proteus_engine.v", 729,
        "p_oe_val  = p_oe_val & ~f_imm;",
        "p_oe_val  = (p_oe_val & ~f_imm) | f_imm;", "pins",
        "DIRC acts as DIRS (sets instead of clears)"),
    Mut("G05", "proteus_engine.v", 736,
        "p_od_val  = (p_od_val & ~f_imm) | f_imm;",
        "p_od_val  = p_od_val & ~f_imm;", "pins",
        "ODSET clears the open-drain bit instead of setting it"),
    Mut("G06", "proteus_engine.v", 292,
        "{1'b0, ss_wm1_r} + 3'd1", "{1'b0, ss_wm1_r} + 3'd2", "pins",
        "side-set window one pin too wide"),
    Mut("G07", "proteus_engine.v", 681,
        "if (bp_inv_r) tmp_v[0] = ~tmp_v[0];",
        "if (1'b0) tmp_v[0] = ~tmp_v[0];", "pins",
        "OUTBIT ignores the configured invert"),

    # --------------------------------------------------------------- host --
    Mut("H01", "proteus_host.v", 245,
        "reg_addr  <= ptr;", "reg_addr  <= addr;", "host",
        "WRITE_INC writes to the address pointer instead of the data pointer"),
    Mut("H02", "proteus_host.v", 247,
        "ptr       <= ptr + 16'd1;", "ptr       <= ptr + 16'd2;", "host",
        "WRITE_INC auto-increment skips a register"),
    Mut("H03", "proteus_host.v", 127,
        "{shreg, mosi_d2}", "{mosi_d2, shreg}", "host",
        "SPI receive shift register takes bits LSB-first"),
    Mut("H04", "proteus_host.v", 208,
        "tx_byte[6 - bit_cnt]", "tx_byte[7 - bit_cnt]", "host",
        "MISO shifts out the wrong bit of the byte"),
    Mut("H05", "proteus_host.v", 199,
        "reg_raddr        <= ptr + 16'd1;", "reg_raddr        <= ptr;", "host",
        "READ_INC re-reads the same address (early fetch pointer)"),
    Mut("H06", "proteus_host.v", 266,
        "addr  <= {byte_in, addr[7:0]};", "addr  <= {addr[7:0], byte_in};",
        "host",
        "WRITE_ADDR high address byte swapped into the low half"),

    # ---------------------------------------------------------------- top --
    Mut("T01", "tt_um_proteus.v", 729,
        "oe_q & (~(od_q & uio_q))", "oe_q & (~(od_q & ~uio_q))", "top",
        "open-drain release inverted (drives high instead of releasing)"),
    Mut("T02", "tt_um_proteus.v", 356,
        "(od_low & uio_in)", "(od_low & ~uio_in)", "top",
        "open-drain collision condition inverted"),
    Mut("T03", "tt_um_proteus.v", 507,
        "((arr_b0 & run_mask) == run_mask)",
        "((arr_b0 & run_mask) != 4'd0)", "top",
        "barrier releases as soon as any engine arrives"),
    Mut("T04", "tt_um_proteus.v", 502,
        "bar_arr0 | cur_b0", "bar_arr0 & cur_b0", "top",
        "barrier arrivals are not sticky"),
    Mut("T05", "tt_um_proteus.v", 553,
        "run_reg <= run_reg & (~halt_mask);", "run_reg <= run_reg;", "top",
        "halt_mask dropped: HALT no longer retires RUN"),
    Mut("T06", "tt_um_proteus.v", 316,
        "~uo_m_all[mi*8 +: 8]) | (uo_d_all[mi*8 +: 8] & uo_m_all[mi*8 +: 8]",
        "~wo_m_all[mi*8 +: 8]) | (uo_d_all[mi*8 +: 8] & wo_m_all[mi*8 +: 8]",
        "top",
        "uo_out merge uses the uio write mask"),
    Mut("T07", "tt_um_proteus.v", 478,
        "cap_entry[36:5]", "{1'b0, cap_entry[35:5]}", "capture",
        "capture timestamp loses its top bit"),
    Mut("T08", "tt_um_proteus.v", 468,
        "cap_wp + cap_ok[CAP_AW-1:0]", "cap_wp + 1'b1", "capture",
        "capture write pointer advances once per cycle, not once per event"),
    Mut("T09", "tt_um_proteus.v", 627,
        "(pm_byte != 2'd3)", "(pm_byte != 2'd2)", "top",
        "program byte lane 2 is dropped"),
    Mut("T10", "tt_um_proteus.v", 626,
        "* 4'd3 +", "* 4'd4 +", "top",
        "program byte-lane map uses a 4-lane stride (engine lane swap)"),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def snapshot() -> dict[str, str]:
    return {f: (SRC_DIR / f).read_text() for f in RTL_FILES}


def restore(src: Path, snap: dict[str, str]) -> None:
    for f, text in snap.items():
        (src / f).write_text(text)


def apply_mutation(src: Path, snap: dict[str, str], m: Mut) -> str:
    """Write the mutant into ``src``.  Returns '' on success, else the reason."""
    if m.file not in snap:
        return f"{m.file}: not an RTL file"
    text = snap[m.file]
    lines = text.splitlines(keepends=True)
    if not (1 <= m.line <= len(lines)):
        return f"{m.file}: line {m.line} out of range (file has {len(lines)})"
    line = lines[m.line - 1]
    hits = line.count(m.find)
    if hits != 1:
        return (f"{m.file}:{m.line}: find string occurs {hits}x, need exactly 1\n"
                f"    line: {line.rstrip()}")
    col = line.index(m.find)
    if line.lstrip().startswith("//") or "//" in line[:col]:
        return f"{m.file}:{m.line}: target is inside a comment"
    if m.find == m.repl:
        return f"{m.file}:{m.line}: mutation is a no-op"
    new_line = line[:col] + m.repl + line[col + len(m.find):]
    if new_line == line:
        return f"{m.file}:{m.line}: mutation is a no-op"
    lines[m.line - 1] = new_line
    (src / m.file).write_text("".join(lines))
    return ""


@dataclass
class BenchResult:
    name: str
    verdict: str        # KILLED | SURVIVED | COMPILE | ODD
    seconds: float
    detail: str         # first failure line(s) for the log


def run_bench(bench: Bench, src: Path, build: Path, timeout: float) -> BenchResult:
    vvp = build / f"{bench.name}.vvp"
    cmd = ["iverilog", "-g2005", "-I", str(src), "-o", str(vvp),
           *bench.sources(src)]
    t0 = time.time()
    try:
        cp = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return BenchResult(bench.name, "KILLED", time.time() - t0,
                           "iverilog compile timed out")
    if cp.returncode != 0:
        return BenchResult(bench.name, "COMPILE", time.time() - t0,
                           (cp.stdout + cp.stderr).strip()[:2000])

    try:
        rp = subprocess.run(["vvp", str(vvp)], capture_output=True, text=True,
                            timeout=timeout)
    except subprocess.TimeoutExpired:
        return BenchResult(bench.name, "KILLED", time.time() - t0,
                           f"simulation exceeded the {timeout:g}s bound")
    out = rp.stdout + rp.stderr
    fails = [ln for ln in out.splitlines() if "FAIL" in ln]
    if rp.returncode != 0 or fails:
        detail = "\n".join(fails[:6]) if fails else out.strip()[-800:]
        return BenchResult(bench.name, "KILLED", time.time() - t0,
                           f"exit={rp.returncode} " + detail)
    if bench.marker not in out:
        return BenchResult(bench.name, "ODD", time.time() - t0,
                           "exit 0 but no PASS marker: " + out.strip()[-400:])
    return BenchResult(bench.name, "SURVIVED", time.time() - t0, "")


def sha_anchor(snap: dict[str, str]) -> list[str]:
    return [f"# src sha256: {f} {hashlib.sha256(t.encode()).hexdigest()[:16]}"
            for f, t in snap.items()]


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_list() -> int:
    print(f"{'id':4} {'file:line':30} {'cat':8} mutation")
    for m in MUTATIONS:
        print(f"{m.id:4} {m.file + ':' + str(m.line):30} {m.cat:8} {m.desc}")
    print(f"\n{len(MUTATIONS)} mutations")
    return 0


def cmd_verify() -> int:
    snap = snapshot()
    tmp = Path(tempfile.mkdtemp(prefix="proteus-mut-verify-"))
    bad = 0
    try:
        for m in MUTATIONS:
            restore(tmp, snap)
            err = apply_mutation(tmp, snap, m)
            if err:
                bad += 1
                print(f"BAD  {m.id}: {err}")
        print(f"{len(MUTATIONS) - bad}/{len(MUTATIONS)} mutation specs apply cleanly")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 1 if bad else 0


def cmd_run(ids: list[str], benches: list[str], timeout: float,
            raw_path: Path | None, append: bool) -> int:
    snap = snapshot()
    selected = [m for m in MUTATIONS if not ids or m.id in ids]
    if not selected:
        print(f"no mutation matches {ids}", file=sys.stderr)
        return 2

    tmp = Path(tempfile.mkdtemp(prefix="proteus-mut-"))
    log: list[str] = []
    t_start = time.time()

    def emit(line: str = "") -> None:
        print(line, flush=True)
        log.append(line)

    emit("# PROTEUS mutation run")
    emit(f"# when: {time.strftime('%Y-%m-%dT%H:%M:%S')}")
    emit(f"# command: python3 tools/mutate.py --all"
         + (f" --only {','.join(ids)}" if ids else "")
         + (f" --benches {','.join(benches)}" if benches != list(DEFAULT_BENCHES) else ""))
    emit(f"# benches: {', '.join(benches)}")
    emit(f"# per-run timeout: {timeout:g} s")
    for a in sha_anchor(snap):
        emit(a)

    # Baseline: the unmutated tree must pass every bench, otherwise a "kill"
    # would be meaningless.
    emit("\n# baseline (unmutated src/)")
    try:
        baseline_ok = True
        for name in benches:
            restore(tmp, snap)
            r = run_bench(BENCHES[name], tmp, tmp, timeout)
            emit(f"#   {name}: {r.verdict} in {r.seconds:.2f}s")
            if r.verdict != "SURVIVED":
                baseline_ok = False
                emit(f"#   !! baseline {name} did not pass: {r.detail}")
        if not baseline_ok:
            emit("# ABORT: baseline is not green")
            return 2

        rows = []
        for m in selected:
            restore(tmp, snap)
            err = apply_mutation(tmp, snap, m)
            if err:
                emit(f"\n=== MUT {m.id} [{m.cat}] {m.file}:{m.line} -- INVALID SPEC\n{err}")
                rows.append((m, "INVALID", {}))
                continue
            results: dict[str, BenchResult] = {}
            for name in benches:
                results[name] = run_bench(BENCHES[name], tmp, tmp, timeout)
            verdicts = [r.verdict for r in results.values()]
            if "KILLED" in verdicts:
                verdict = "KILLED"
            elif "ODD" in verdicts:
                verdict = "ODD"
            elif "SURVIVED" in verdicts:
                verdict = "SURVIVED"
            else:
                verdict = "COMPILE"
            rows.append((m, verdict, results))

            per = "  ".join(f"{n}={r.verdict}({r.seconds:.1f}s)"
                            for n, r in results.items())
            print(f"{m.id:4} {verdict:9} {m.file}:{m.line:<5} {m.desc[:58]:58} {per}",
                  flush=True)
            emit(f"\n=== MUT {m.id} [{m.cat}] {m.file}:{m.line} -- {verdict}")
            emit(f"--- change: {m.find!r} -> {m.repl!r}")
            emit(f"--- intent: {m.desc}")
            for n, r in results.items():
                emit(f"--- {n}: {r.verdict} in {r.seconds:.2f}s")
                if r.detail:
                    for ln in r.detail.splitlines():
                        emit(f"    {ln}")

        emit("\n=== SUMMARY")
        emit("id,file,line,cat," + ",".join(benches) + ",verdict")
        for m, verdict, results in rows:
            cells = ",".join(results[n].verdict if n in results else "-"
                             for n in benches)
            emit(f"{m.id},{m.file},{m.line},{m.cat},{cells},{verdict}")

        counts: dict[str, int] = {}
        for _, verdict, _ in rows:
            counts[verdict] = counts.get(verdict, 0) + 1
        valid = sum(v for k, v in counts.items() if k in ("KILLED", "SURVIVED"))
        killed = counts.get("KILLED", 0)
        surv = counts.get("SURVIVED", 0)
        emit("")
        emit(f"mutations: {len(rows)}  " +
             "  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
        if valid:
            emit(f"kill rate: {killed}/{valid} = {100.0 * killed / valid:.1f}% "
                 f"(survivors {surv})")
        per_bench = {n: sum(1 for _, v, r in rows
                            if n in r and r[n].verdict == "KILLED") for n in benches}
        emit("kills per bench: " +
             "  ".join(f"{n}={c}/{len(rows)}" for n, c in per_bench.items()))
        emit(f"elapsed: {time.time() - t_start:.1f}s")

        if raw_path is not None:
            raw_path.parent.mkdir(parents=True, exist_ok=True)
            with raw_path.open("a" if append else "w") as fh:
                fh.write("\n".join(log) + "\n")
            print(f"\nraw log -> {raw_path}")

        return 0 if counts.get("INVALID", 0) == 0 else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--all", action="store_true", help="run every mutation")
    ap.add_argument("--only", default="", help="comma-separated mutation ids")
    ap.add_argument("--benches", default=",".join(DEFAULT_BENCHES),
                    help=f"comma-separated bench names {sorted(BENCHES)}")
    ap.add_argument("--timeout", type=float, default=180.0,
                    help="bound per compile/simulation run (s)")
    ap.add_argument("--list", action="store_true", help="print the catalogue")
    ap.add_argument("--verify-mutations", action="store_true",
                    help="check every spec applies to the tree; no simulation")
    ap.add_argument("--raw", default="results/mutation_raw.txt",
                    help="raw log path ('' disables)")
    ap.add_argument("--append", action="store_true", help="append to the raw log")
    a = ap.parse_args(argv)

    if a.list:
        return cmd_list()
    if a.verify_mutations:
        return cmd_verify()

    ids = [s.strip() for s in a.only.split(",") if s.strip()]
    benches = [s.strip() for s in a.benches.split(",") if s.strip()]
    for b in benches:
        if b not in BENCHES:
            print(f"unknown bench {b!r}; choose from {sorted(BENCHES)}",
                  file=sys.stderr)
            return 2
    if not a.all and not ids:
        print("nothing to do: pass --all, --only IDS, --list or "
              "--verify-mutations", file=sys.stderr)
        return 2
    raw = ROOT / a.raw if a.raw else None
    return cmd_run(ids, benches, a.timeout, raw, a.append)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
