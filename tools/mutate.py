#!/usr/bin/env python3
"""Mutation testing for the hybrid v2 RTL against the ported self-checking benches.

Why this exists
---------------
Every other layer answers "does the design behave as specified".  This answers
the prior question for a *test*: "would this bench notice if the design were
wrong".  It breaks the RTL on purpose, one textual mutation at a time, and
requires the bench to say so.

Adapted from tools/mutate.py (v1, untouched) with three changes:
  * paths are v2/src and v2/tb, and all twelve v2 RTL files are in scope;
  * the two benches are the ported ones (v2/tb/engine_smoke_tb.v against
    v2/src/proteus_engine.v, v2/tb/top_e2e_tb.v against the whole chip);
  * a mutation is anchored by its literal text, not by a line number: the
    substring must occur EXACTLY ONCE in the file, or the run aborts.  The
    resolved file:line is reported, so a mislocated mutation can never silently
    test unmutated RTL and report a fake survivor.

Method
------
  * v2/src is copied into a scratch directory; the working tree is never
    modified.  One mutation is applied to one file, then the bench is rebuilt
    from the repo's v2/tb file (so bench assertions cannot be mutated) plus the
    mutated v2/src copy and run under a bounded timeout.
  * verdict per bench: KILLED if the process exits non-zero, times out, or
    prints FAIL/FATAL; SURVIVED if it reaches its own PASS marker.  A mutant
    that does not compile is COMPILE and is excluded from the kill rate.

Commands
--------
    python3 v2/tools/mutate.py --list               # the catalogue
    python3 v2/tools/mutate.py --verify-mutations   # spec vs. tree, no sim
    python3 v2/tools/mutate.py --all                # the full matrix
    python3 v2/tools/mutate.py --only A01,T07       # a subset
    python3 v2/tools/mutate.py --all --append       # append to the raw log

Defaults: benches ``engine`` and ``top``, 180 s per simulation run, raw log
``v2/results/mutation_raw.txt``.
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

ROOT = Path(__file__).resolve().parent.parent      # v2/
SRC_DIR = ROOT / "src"
TB_DIR = ROOT / "tb"

# Every RTL file that participates in a build.  Only the mutated one differs
# from the tree; the rest are restored from the pristine snapshot each time.
RTL_FILES = ("proteus_defs.vh", "proteus_engine.v", "proteus_host.v",
             "proteus_assist.v", "tt_um_proteus.v", "crc_bit.v",
             "assist_fifo.v", "shiftreg32.v", "nrzi_enc.v", "nrzi_dec.v",
             "manchester_enc.v", "manchester_dec.v")

# The assist blocks are separate compilation units; the full-chip bench needs
# all of them, the engine bench needs only the engine.
CHIP_UNITS = tuple(f for f in RTL_FILES if f != "proteus_defs.vh")


# ---------------------------------------------------------------------------
# Benches
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Bench:
    name: str
    tb: str            # tb file, taken from the repo (never mutated)
    units: tuple       # RTL units besides the defs header
    marker: str        # the bench's own PASS line (substring)

    def sources(self, src: Path) -> list[str]:
        return [str(TB_DIR / self.tb), str(src / "proteus_defs.vh")] + \
               [str(src / u) for u in self.units]


BENCHES = {
    # Broadest ISA/stall/assist-port coverage: instantiates proteus_engine only.
    "engine": Bench(
        name="engine",
        tb="engine_smoke_tb.v",
        units=("proteus_engine.v",),
        marker="==== PASS: all engine smoke checks passed",
    ),
    # Real top through the host SPI pins only: host FSM, program byte lanes for
    # all three engines, pin fabric + assist pin stage, capture, barriers,
    # assist CSR bank (host and engine paths), pacer horizon, HALT/RUN
    # retirement, HOST_DISABLE.
    "top": Bench(
        name="top",
        tb="top_e2e_tb.v",
        units=CHIP_UNITS,
        marker="top_e2e_tb PASSED",
    ),
}

DEFAULT_BENCHES = ("engine", "top")


# ---------------------------------------------------------------------------
# Mutation catalogue
#
# Each entry is a bug a person could plausibly write.  ``find`` must be a
# substring of exactly one line in ``file`` and must occur exactly once in that
# file (checked by --verify-mutations and again before every run).
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Mut:
    id: str
    file: str
    find: str
    repl: str
    cat: str
    desc: str


MUTATIONS = [
    # ---------------------------------------------------------------- ALU --
    Mut("A01", "proteus_engine.v",
        "+ {1'b0, b};", "- {1'b0, b};", "alu",
        "ADD/ADDI adds -> subtracts"),
    Mut("A02", "proteus_engine.v",
        "- {1'b0, b};", "+ {1'b0, b};", "alu",
        "SUB/SUBI/CMP subtracts -> adds"),
    Mut("A03", "proteus_engine.v",
        "t  = {1'b0, a} - {1'b0, b};\n          co = t[8];",
        "t  = {1'b0, a} - {1'b0, b};\n          co = ~t[8];", "alu",
        "subtract borrow flag inverted"),
    Mut("A04", "proteus_engine.v",
        "+ {8'd0, cin};", ";", "alu",
        "ADC/ADCI drops the carry-in"),
    Mut("A05", "proteus_engine.v",
        "if (shn != 4'd0) co = |(a & (8'h01 << (4'd8 - shn)));",
        "if (shn != 4'd0) co = |(a & (8'h01 << (shn - 4'd1)));", "alu",
        "SHL carry uses the SHR carry formula"),
    Mut("A06", "proteus_engine.v",
        "(a[7] ? (8'hFF << (4'd8 - shn)) : 8'h00)", "8'h00", "alu",
        "ASR loses the sign fill (becomes SHR)"),
    Mut("A07", "proteus_engine.v",
        "co = r[0];", "co = r[7];", "alu",
        "ROL carry taken from the wrong end"),
    Mut("A08", "proteus_engine.v",
        "co = r[7];", "co = r[0];", "alu",
        "ROR carry taken from the wrong end"),
    Mut("A09", "proteus_engine.v",
        "alu_f(OP_ADD, regs[f_rd], 8'h01, c_r)",
        "alu_f(OP_SUB, regs[f_rd], 8'h01, c_r)", "alu",
        "INC decrements"),
    Mut("A10", "proteus_engine.v",
        "alu_f(OP_SUB, regs[f_rd], 8'h01, c_r)",
        "alu_f(OP_ADD, regs[f_rd], 8'h01, c_r)", "alu",
        "DEC increments"),
    Mut("A11", "proteus_engine.v",
        "alu_f(OP_SUB, 8'h00, regs[f_rd], c_r)",
        "alu_f(OP_ADD, 8'h00, regs[f_rd], c_r)", "alu",
        "NEG becomes a no-op (0-x -> 0+x)"),
    Mut("A12", "proteus_engine.v",
        "{1'b0, b[2:0]}", "{1'b0, b[3:1]}", "alu",
        "shift/rotate count read one bit too high"),

    # ------------------------------------------------- pacer / time / wait --
    Mut("P01", "proteus_engine.v",
        "if (cycle >= next_int_r)", "if (cycle > next_int_r)", "pacer",
        "PACE deadline compare off by one"),
    Mut("P02", "proteus_engine.v",
        "{31'd0, n_next_carry}", "{31'd0, 1'b0}", "pacer",
        "pacer fractional carry dropped from the deadline"),
    Mut("P03", "proteus_engine.v",
        "n_next_int  = cycle;", "n_next_int  = cycle + 32'd1;", "pacer",
        "PACERST arms the deadline one cycle late"),
    Mut("P04", "proteus_engine.v",
        "({21'd0, waitc_n} - 32'd1)", "({21'd0, waitc_n})", "waitc",
        "WAITC n occupies n+1 cycles"),
    Mut("P05", "proteus_engine.v",
        "end else if (wait_left_r > 32'd1) begin\n            n_wait_left = wait_left_r - 32'd1;",
        "end else if (wait_left_r > 32'd1) begin\n            n_wait_left = wait_left_r - 32'd2;",
        "waitc", "WAITC stall counter decrements by two"),
    Mut("P06", "proteus_engine.v",
        "n_ts_event    = cycle;\n            n_wait_active = 1'b0;\n"
        "            n_wait_left   = 32'd0;\n"
        "          end else if (!wait_active_r) begin\n"
        "            n_wait_active = 1'b1;\n"
        "            n_wait_left   = {16'h0000, timeout_r, 8'h00};\n"
        "            do_advance    = 1'b0;\n"
        "          end else if (timeout_r != 8'h00) begin\n"
        "            if (wait_left_r <= 32'd1) begin",
        "n_ts_event    = cycle;\n            n_wait_active = 1'b0;\n"
        "            n_wait_left   = 32'd0;\n"
        "          end else if (!wait_active_r) begin\n"
        "            n_wait_active = 1'b1;\n"
        "            n_wait_left   = {16'h0000, timeout_r, 8'h00};\n"
        "            do_advance    = 1'b0;\n"
        "          end else if (timeout_r != 8'h00) begin\n"
        "            if (wait_left_r < 32'd1) begin",
        "timeout", "WAITP timeout fires one cycle late"),
    Mut("P07", "proteus_engine.v",
        "n_ts_event    = cycle;\n            n_wait_active = 1'b0;\n"
        "            n_wait_left   = 32'd0;\n"
        "          end else if (!wait_active_r) begin\n"
        "            n_wait_active = 1'b1;\n"
        "            n_wait_left   = {16'h0000, timeout_r, 8'h00};",
        "n_ts_event    = cycle;\n            n_wait_active = 1'b0;\n"
        "            n_wait_left   = 32'd0;\n"
        "          end else if (!wait_active_r) begin\n"
        "            n_wait_active = 1'b1;\n"
        "            n_wait_left   = {17'h0000, timeout_r, 7'h00};",
        "timeout", "WAITP timeout unit 256 -> 128 cycles"),
    Mut("P08", "proteus_engine.v",
        "if (f_rs[2] ? (tmp_v == f_imm) : (tmp_v == 8'h00))",
        "if (f_rs[2] ? (tmp_v == 8'h00) : (tmp_v == f_imm))", "waitp",
        "WAITP level polarity swapped"),

    # ------------------------------------------------------------ control --
    Mut("C01", "proteus_engine.v",
        "3'd1: take = z_r;", "3'd1: take = ~z_r;", "control",
        "JZ takes the opposite condition"),
    Mut("C02", "proteus_engine.v",
        "3'd3: take = c_r;", "3'd3: take = ~c_r;", "control",
        "JC takes the opposite condition"),
    Mut("C03", "proteus_engine.v",
        "if (take) begin\n            n_pc       = f_imm[ADDR_W-1:0] & LAST_PC;",
        "if (take) begin\n            n_pc       = f_imm[ADDR_W-1:0] & (LAST_PC - 1);",
        "control", "jump target mask off by one"),
    Mut("C04", "proteus_engine.v",
        "ADDR_ONE = 1;", "ADDR_ONE = 2;", "control",
        "PC increments by two"),
    Mut("C05", "proteus_engine.v",
        "(pc_r == LAST_PC)", "1'b0", "control",
        "PC wrap test removed (rely on width wrap)"),
    Mut("C06", "proteus_engine.v",
        "assign halt_exec     = exec_act && (f_op == OP_HALT);",
        "assign halt_exec     = exec_act && (f_op == OP_NOP);", "control",
        "halt_exec decodes NOP, so HALT does not retire RUN"),
    Mut("C07", "proteus_engine.v",
        "run & ~run_q", "run & run_q", "control",
        "run-rising restart never fires (stale PC executes)"),
    Mut("C08", "proteus_engine.v",
        "& prog_ready_r & ~restart", "& ~restart", "control",
        "engine executes before the program fill is ready"),
    Mut("C09", "proteus_engine.v",
        "if (fill_cnt == LAST_PC)", "if (fill_cnt == LAST_PC - 1)", "control",
        "prog_ready asserted one word early"),
    Mut("C10", "proteus_engine.v",
        "host_prog_addr <= LAST_ADDR", "host_prog_addr < LAST_ADDR", "control",
        "last program word is dropped / reads 0 (off-by-one)"),

    # -------------------------------------------------------------- FIFOs --
    Mut("F01", "proteus_engine.v",
        "in_full_w   = (in_cnt  == FIFO_FULL)",
        "in_full_w   = (in_cnt  == FIFO_FULL - 1)", "fifo",
        "input-FIFO full comparison flipped (full one early)"),
    Mut("F02", "proteus_engine.v",
        "OP_PUSH: begin\n          if (out_cnt < FIFO_FULL) begin",
        "OP_PUSH: begin\n          if (out_cnt <= FIFO_FULL) begin", "fifo",
        "PUSH accepted when the output FIFO is full"),
    Mut("F03", "proteus_engine.v",
        "if (host_in_push && (in_cnt < FIFO_FULL)) begin\n"
        "        in_mem[in_wr] <= host_in_data;",
        "if (host_in_push && (in_cnt <= FIFO_FULL)) begin\n"
        "        in_mem[in_wr] <= host_in_data;", "fifo",
        "host push accepted when the input FIFO is full"),
    Mut("F04", "proteus_engine.v",
        "OP_PUSHN: begin\n          if (out_cnt < FIFO_FULL) begin\n"
        "            n_out_push = 1'b1;\n            n_out_data = regs[f_rd];\n"
        "            n_nf       = 1'b0;\n          end else begin\n"
        "            n_nf = 1'b1;",
        "OP_PUSHN: begin\n          if (out_cnt < FIFO_FULL) begin\n"
        "            n_out_push = 1'b1;\n            n_out_data = regs[f_rd];\n"
        "            n_nf       = 1'b0;\n          end else begin\n"
        "            n_nf = 1'b0;", "fifo",
        "PUSHN on a full FIFO does not flag nf"),

    # --------------------------------------------------------------- pins --
    Mut("G01", "proteus_engine.v",
        "8'hFF, 1'b1)", "8'h00, 1'b1)", "pins",
        "SETP drives 0 instead of 1 (equals CLRP)"),
    Mut("G02", "proteus_engine.v",
        "~tmp_v, 1'b1)", "tmp_v, 1'b1)", "pins",
        "TOGP does not invert the pin snapshot"),
    Mut("G03", "proteus_engine.v",
        "p_oe_val  = (p_oe_val & ~f_imm) | f_imm;",
        "p_oe_val  = p_oe_val & ~f_imm;", "pins",
        "DIRS acts as DIRC (clears instead of sets)"),
    Mut("G04", "proteus_engine.v",
        "p_oe_val  = p_oe_val & ~f_imm;",
        "p_oe_val  = (p_oe_val & ~f_imm) | f_imm;", "pins",
        "DIRC acts as DIRS (sets instead of clears)"),
    Mut("G05", "proteus_engine.v",
        "p_od_val  = (p_od_val & ~f_imm) | f_imm;",
        "p_od_val  = p_od_val & ~f_imm;", "pins",
        "ODSET clears the open-drain bit instead of setting it"),
    Mut("G06", "proteus_engine.v",
        "{1'b0, ss_wm1_r} + 3'd1", "{1'b0, ss_wm1_r} + 3'd2", "pins",
        "side-set window one pin too wide"),
    Mut("G07", "proteus_engine.v",
        "if (bp_inv_r) tmp_v[0] = ~tmp_v[0];",
        "if (1'b0) tmp_v[0] = ~tmp_v[0];", "pins",
        "OUTBIT ignores the configured invert"),

    # --------------------------------------------------------------- host --
    Mut("H01", "proteus_host.v",
        "reg_addr  <= ptr;", "reg_addr  <= addr;", "host",
        "WRITE_INC writes to the address pointer instead of the data pointer"),
    Mut("H02", "proteus_host.v",
        "ptr       <= ptr + 16'd1;", "ptr       <= ptr + 16'd2;", "host",
        "WRITE_INC auto-increment skips a register"),
    Mut("H03", "proteus_host.v",
        "{shreg, mosi_d2}", "{mosi_d2, shreg}", "host",
        "SPI receive shift register takes bits LSB-first"),
    Mut("H04", "proteus_host.v",
        "tx_byte[6 - bit_cnt]", "tx_byte[7 - bit_cnt]", "host",
        "MISO shifts out the wrong bit of the byte"),
    Mut("H05", "proteus_host.v",
        "reg_raddr        <= ptr + 16'd1;", "reg_raddr        <= ptr;", "host",
        "READ_INC re-reads the same address (early fetch pointer)"),
    Mut("H06", "proteus_host.v",
        "addr  <= {byte_in, addr[7:0]};", "addr  <= {addr[7:0], byte_in};",
        "host",
        "WRITE_ADDR high address byte swapped into the low half"),

    # ---------------------------------------------------------------- top --
    Mut("T01", "tt_um_proteus.v",
        "oe_q & (~(od_q & uio_q))", "oe_q & (~(od_q & ~uio_q))", "top",
        "open-drain release inverted (drives high instead of releasing)"),
    Mut("T02", "tt_um_proteus.v",
        "(od_low & uio_in)", "(od_low & ~uio_in)", "top",
        "open-drain collision condition inverted"),
    Mut("T03", "tt_um_proteus.v",
        "((arr_b0 & run_mask) == run_mask)",
        "((arr_b0 & run_mask) != 3'd0)", "top",
        "barrier releases as soon as any engine arrives"),
    Mut("T04", "tt_um_proteus.v",
        "bar_arr0 | cur_b0", "bar_arr0 & cur_b0", "top",
        "barrier arrivals are not sticky"),
    Mut("T05", "tt_um_proteus.v",
        "run_reg <= run_reg & (~halt_mask);", "run_reg <= run_reg;", "top",
        "halt_mask dropped: HALT no longer retires RUN"),
    Mut("T06", "tt_um_proteus.v",
        "~uo_m_all[mi*8 +: 8]) | (uo_d_all[mi*8 +: 8] & uo_m_all[mi*8 +: 8]",
        "~wo_m_all[mi*8 +: 8]) | (uo_d_all[mi*8 +: 8] & wo_m_all[mi*8 +: 8]",
        "top",
        "uo_out merge uses the uio write mask"),
    Mut("T07", "tt_um_proteus.v",
        "cap_entry[36:5]", "{1'b0, cap_entry[35:5]}", "capture",
        "capture timestamp loses its top bit"),
    Mut("T08", "tt_um_proteus.v",
        "cap_wp + cap_ok[CAP_AW-1:0]", "cap_wp + 1'b1", "capture",
        "capture write pointer advances once per cycle, not once per event"),
    Mut("T09", "tt_um_proteus.v",
        "(pm_byte != 2'd3)", "(pm_byte != 2'd2)", "top",
        "program byte lane 2 is dropped"),
    Mut("T10", "tt_um_proteus.v",
        "* 4'd3 +", "* 4'd4 +", "top",
        "program byte-lane map uses a 4-lane stride (engine lane swap)"),

    # -------------------------------------------- v2: 3-engine top deltas --
    Mut("T11", "tt_um_proteus.v",
        "wire [2:0]  run_mask    = run_reg & (~halted_mask) & ready_mask;",
        "wire [2:0]  run_mask    = run_reg & ready_mask;", "top",
        "halted mask dropped from run_mask (a halted engine restarts itself)"),
    Mut("T12", "tt_um_proteus.v",
        "wire [1:0]  pm_eng   = reg_addr[9:8] - 2'd1;",
        "wire [1:0]  pm_eng   = reg_addr[9:8];", "top",
        "program-window engine index off by one (engine 0 -> 0x0004 lane)"),
    Mut("T13", "tt_um_proteus.v",
        "(reg_addr <= `PROTEUS_PM_END)", "(reg_addr <= 16'h02FF)", "top",
        "program window ends at engine 1 (engine 2's page unreachable)"),
    Mut("T14", "tt_um_proteus.v",
        "(reg_addr <= `PROTEUS_EW_END)", "(reg_addr <= 16'h004F)", "top",
        "engine window ends at engine 1 (engine 2's window unreachable)"),
    Mut("T15", "tt_um_proteus.v",
        "else if (wr_halt)     run_reg <= run_reg & (~reg_wdata[2:0]);",
        "else if (wr_halt)     run_reg <= run_reg;", "top",
        "HALT register write does not clear RUN bits"),
    Mut("T16", "tt_um_proteus.v",
        "wire [2:0]  err_mask", "wire [3:0]  err_mask", "top",
        "error mask widened to four engines (status reduction mismatch)"),
    Mut("T17", "tt_um_proteus.v",
        "assign in_push = (win_wr && win_in) ? (3'd1 << win_e2) : 3'd0;",
        "assign in_push = (win_wr && win_in) ? (3'd1 << 3'd0) : 3'd0;", "top",
        "IN_FIFO push always routed to engine 0"),
    Mut("T18", "tt_um_proteus.v",
        "assign out_pop = rd_outf ? (3'd1 << rd_rel[6:5]) : 3'd0;",
        "assign out_pop = rd_outf ? (3'd1 << 3'd0) : 3'd0;", "top",
        "OUT_FIFO pop always routed to engine 0"),
    Mut("T19", "tt_um_proteus.v",
        "wire [7:0] irq_n2 = (irq_n1  | e_is[2]) & (~e_ic[2]);",
        "wire [7:0] irq_n2 = irq_n1 & (~e_ic[2]);", "top",
        "engine 2 IRQSET never reaches the IRQ register"),
    Mut("T20", "tt_um_proteus.v",
        "m_od  = m_od & ~as_od_m;", "m_od  = m_od | as_od_m;", "assist",
        "assist pin stage sets open-drain instead of clearing it"),
    Mut("T21", "tt_um_proteus.v",
        "m_uo  = (m_uo  & ~as_uo_m)  | (as_uo_d  & as_uo_m);",
        "m_uo  = m_uo;", "assist",
        "assist uo_out stage dropped (assist pin writes never reach the pad)"),
    Mut("T22", "tt_um_proteus.v",
        "wire       as_wsel = reg_we && (reg_addr  >= `PROTEUS_AS_BASE) &&",
        "wire       as_wsel = 1'b0 && (reg_addr  >= `PROTEUS_AS_BASE) &&",
        "assist", "assist CSR window not writable from the host"),
    Mut("T23", "tt_um_proteus.v",
        "wire       as_rsel = reg_re && (reg_raddr >= `PROTEUS_AS_BASE) &&",
        "wire       as_rsel = 1'b0 && (reg_raddr >= `PROTEUS_AS_BASE) &&",
        "assist", "assist CSR window not readable from the host"),
    Mut("T24", "tt_um_proteus.v",
        "wire       as_wr_eff  = e_as_wr[2] | e_as_wr[1] | e_as_wr[0];",
        "wire       as_wr_eff  = e_as_wr[0] | e_as_wr[1];", "assist",
        "engine-2 assist writes never reach the bank"),
    Mut("T25", "tt_um_proteus.v",
        "wire [2:0] as_wid_eff = e_as_wr[2] ? e_as_id[2] :",
        "wire [2:0] as_wid_eff = e_as_wr[2] ? e_as_id[1] :", "assist",
        "assist write arbitration takes engine 1's id for engine 2's write"),
    Mut("T26", "tt_um_proteus.v",
        "wire       as_cmd_eff   = e_as_cmd_en[2] | e_as_cmd_en[1] | e_as_cmd_en[0];",
        "wire       as_cmd_eff   = e_as_cmd_en[0];", "assist",
        "assist commands only from engine 0"),
    Mut("T27", "tt_um_proteus.v",
        "wire [7:0] as_wdata_eff = e_as_wr[2] ? e_as_wdata[2] :",
        "wire [7:0] as_wdata_eff = e_as_wr[2] ? e_as_wdata[1] :", "assist",
        "assist write data taken from the wrong engine (arbitration)"),
    Mut("T29", "tt_um_proteus.v",
        "wire [1:0]  win_e2   = win_rel[6:5];",
        "wire [1:0]  win_e2   = win_rel[5:4];", "top",
        "engine-window write decode selects the wrong engine"),
    Mut("T30", "tt_um_proteus.v",
        "assign hp_be    = pm_ok ? (9'd1 << pm_lane) : 9'd0;",
        "assign hp_be    = pm_ok ? (9'd1 << pm_byte) : 9'd0;", "top",
        "program byte lane ignores the engine (all engines share lane 0..2)"),
    Mut("T28", "tt_um_proteus.v",
        "wire [3:0] rel_vec = {rel_b3, rel_b2, rel_b1, rel_b0};",
        "wire [3:0] rel_vec = {rel_b3, rel_b2, rel_b0, rel_b1};", "top",
        "barrier release vector mis-wired for ids 0/1"),

    # --------------------------------------- v2: engine assist CSA port ----
    Mut("V01", "proteus_engine.v",
        "assign as_rd     = exec_act && (f_op == OP_LDAS);",
        "assign as_rd     = exec_act && (f_op == OP_STAS);", "assist",
        "LDAS read strobe fires on STAS"),
    Mut("V02", "proteus_engine.v",
        "assign as_wr     = exec_act && (f_op == OP_STAS);",
        "assign as_wr     = 1'b0;", "assist",
        "STAS never writes the CSR bank"),
    Mut("V03", "proteus_engine.v",
        "assign as_id     = f_imm[2:0];", "assign as_id     = f_rd;", "assist",
        "assist id taken from rd instead of imm8[2:0]"),
    Mut("V04", "proteus_engine.v",
        "assign as_reg    = f_rs;", "assign as_reg    = f_rd;", "assist",
        "CSR register index taken from rd instead of rs"),
    Mut("V05", "proteus_engine.v",
        "assign as_wdata  = regs[f_rd];", "assign as_wdata  = regs[f_rs];",
        "assist", "STAS write data taken from rs instead of rd"),
    Mut("V06", "proteus_engine.v",
        "assign as_cmd_en = exec_act && (f_op == OP_ASST);",
        "assign as_cmd_en = exec_act && (f_op == OP_STAS);", "assist",
        "ASST command strobe fires on STAS"),
    Mut("V07", "proteus_engine.v",
        "assign as_cmd_id = f_rs;", "assign as_cmd_id = f_imm[2:0];", "assist",
        "ASST assist id taken from imm instead of rs"),
    Mut("V08", "proteus_engine.v",
        "assign as_cmd    = f_imm;", "assign as_cmd    = regs[f_rd];", "assist",
        "ASST command word taken from rd instead of imm8"),
    Mut("V09", "proteus_engine.v",
        "if (as_empty) begin", "if (1'b0) begin", "assist",
        "LDAS ignores as_empty (empty FIFO read returns stale data)"),
    Mut("V10", "proteus_engine.v",
        "            n_reg_we = 1'b1;\n            n_nf     = 1'b0;",
        "            n_reg_we = 1'b0;\n            n_nf     = 1'b0;", "assist",
        "LDAS reads the bus but never writes rd"),
    Mut("V11", "proteus_engine.v",
        "            n_nf = 1'b1;\n          end else begin\n            n_reg_v  = as_rdata;",
        "            n_nf = 1'b0;\n          end else begin\n            n_reg_v  = as_rdata;",
        "assist", "empty LDAS does not set nf_flag"),
    Mut("V12", "proteus_engine.v",
        "          if (as_empty) begin\n            n_nf = 1'b1;",
        "          if (as_empty) begin\n            n_reg_v = as_rdata;\n            n_reg_we = 1'b1;\n            n_nf = 1'b1;",
        "assist", "empty LDAS still writes rd from the (invalid) read bus"),

    # ------------------------------------------ v2: assist wrapper deltas --
    Mut("W01", "proteus_assist.v",
        "if (h_we && (h_wr_reg == 4'd8) && (h_wr_id < 3'd5))",
        "if (h_we && (h_wr_reg == 4'd8) && (h_wr_id < 3'd4))", "assist",
        "PINCFG for assist 4 (MANCH) is not stored"),
    Mut("W02", "proteus_assist.v",
        "wire        fifo_rd    = h_rd_fifo0 | e_rd_fifo0;",
        "wire        fifo_rd    = h_rd_fifo0;", "assist",
        "engine FIFO DATA reads do not pop"),
    Mut("W03", "proteus_assist.v",
        "assign e_rempty = {(e_rid2 == 3'd1) && (e_rreg2 == 3'd0) && fifo_rd_empty,",
        "assign e_rempty = {1'b0,",
        "assist", "engine 2 never sees FIFO DATA as empty"),
    Mut("W04", "proteus_assist.v",
        "nrzi_div <= nrzi_div_h ? h_wdata[5:0] : e_wdata[5:0];",
        "nrzi_div <= nrzi_div_h ? e_wdata[5:0] : h_wdata[5:0];", "assist",
        "DIV write source swapped (host/engine)"),
    Mut("W05", "proteus_assist.v",
        "4'd3: as_read = {2'b00, nrzi_div};", "4'd3: as_read = 8'h00;",
        "assist", "NRZI DIV reads back as 0"),
    Mut("W06", "proteus_assist.v",
        "4'd1: as_read = {1'b0, fifo_full, fifo_empty, fifo_level};",
        "4'd1: as_read = {1'b0, fifo_full, fifo_level, fifo_empty};", "assist",
        "FIFO STATUS empty/level fields swapped"),
    Mut("W07", "proteus_assist.v",
        "wire        fifo_wr    = h_wr_fifo0 | e_wr_fifo0;",
        "wire        fifo_wr    = h_wr_fifo0;", "assist",
        "engine STAS to FIFO DATA does not push"),
    Mut("W08", "proteus_assist.v",
        "wire nrzi_div_wr = nrzi_div_h || (e_wr_id3 && (e_wreg == 3'd3));",
        "wire nrzi_div_wr = nrzi_div_h;", "assist",
        "engine STAS to NRZI DIV is dropped"),
    Mut("W09", "proteus_assist.v",
        "wire [2:0] h_wr_id  = h_addr[6:4];",
        "wire [2:0] h_wr_id  = h_addr[5:3];", "assist",
        "host CSR assist id decoded from the wrong address bits"),
    Mut("W10", "proteus_assist.v",
        "wire [3:0] h_wr_reg = h_addr[3:0];",
        "wire [3:0] h_wr_reg = {h_addr[2:0], 1'b0};", "assist",
        "host CSR register index decoded from the wrong address bits"),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def snapshot() -> dict[str, str]:
    return {f: (SRC_DIR / f).read_text() for f in RTL_FILES}


def restore(src: Path, snap: dict[str, str]) -> None:
    for f, text in snap.items():
        (src / f).write_text(text)


def locate(snap: dict[str, str], m: Mut) -> tuple[int, str]:
    """Resolve the mutation to (line, line_text).  Raises ValueError."""
    if m.file not in snap:
        raise ValueError(f"{m.file}: not an RTL file")
    text = snap[m.file]
    first = text.find(m.find)
    if first < 0:
        raise ValueError(f"{m.file}: find string not present")
    if text.find(m.find, first + 1) >= 0:
        raise ValueError(f"{m.file}: find string is not unique in the file")
    if m.find == m.repl:
        raise ValueError(f"{m.file}: mutation is a no-op")
    line_no = text.count("\n", 0, first) + 1
    line = text.splitlines()[line_no - 1]
    # A mutation must not land inside a comment: a comment edit would compile to
    # the unmutated design and report a fake survivor.
    col = line.find(m.find)
    if line.lstrip().startswith("//") or "//" in line[:max(col, 0)]:
        raise ValueError(f"{m.file}:{line_no}: target is inside a comment")
    return line_no, line


def apply_mutation(src: Path, snap: dict[str, str], m: Mut) -> tuple[int, str]:
    """Write the mutant into ``src``.  Returns (line, '') or (0, reason)."""
    try:
        line_no, _ = locate(snap, m)
    except ValueError as exc:
        return 0, str(exc)
    text = snap[m.file]
    (src / m.file).write_text(text.replace(m.find, m.repl, 1))
    return line_no, ""


@dataclass
class BenchResult:
    name: str
    verdict: str        # KILLED | SURVIVED | COMPILE | ODD
    seconds: float
    detail: str         # first failure line(s) for the log


def run_bench(bench: Bench, src: Path, build: Path,
              timeout: float) -> BenchResult:
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
    fails = [ln for ln in out.splitlines()
             if ("FAIL" in ln) or ln.startswith("FATAL")]
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
    snap = snapshot()
    print(f"{'id':4} {'file:line':30} {'cat':8} mutation")
    bad = 0
    for m in MUTATIONS:
        try:
            line_no, _ = locate(snap, m)
            where = f"{m.file}:{line_no}"
        except ValueError as exc:
            where = "<invalid>"
            print(f"BAD  {m.id}: {exc}")
            bad += 1
        print(f"{m.id:4} {where:30} {m.cat:8} {m.desc}")
    print(f"\n{len(MUTATIONS)} mutations ({bad} unresolved)")
    return 1 if bad else 0


def cmd_verify() -> int:
    snap = snapshot()
    bad = 0
    for m in MUTATIONS:
        try:
            line_no, line = locate(snap, m)
            print(f"ok   {m.id}: {m.file}:{line_no}  {line.strip()[:78]}")
        except ValueError as exc:
            bad += 1
            print(f"BAD  {m.id}: {exc}")
    print(f"{len(MUTATIONS) - bad}/{len(MUTATIONS)} mutation specs apply cleanly")
    return 1 if bad else 0


def cmd_run(ids: list[str], benches: list[str], timeout: float,
            raw_path: Path | None, append: bool) -> int:
    snap = snapshot()
    selected = [m for m in MUTATIONS if not ids or m.id in ids]
    if not selected:
        print(f"no mutation matches {ids}", file=sys.stderr)
        return 2

    tmp = Path(tempfile.mkdtemp(prefix="proteus-v2-mut-"))
    log: list[str] = []
    t_start = time.time()

    def emit(line: str = "") -> None:
        print(line, flush=True)
        log.append(line)

    emit("# PROTEUS hybrid v2 mutation run")
    emit(f"# when: {time.strftime('%Y-%m-%dT%H:%M:%S')}")
    emit(f"# command: python3 v2/tools/mutate.py --all"
         + (f" --only {','.join(ids)}" if ids else "")
         + (f" --benches {','.join(benches)}"
            if benches != list(DEFAULT_BENCHES) else ""))
    emit(f"# benches: {', '.join(benches)}")
    emit(f"# per-run timeout: {timeout:g} s")
    for a in sha_anchor(snap):
        emit(a)

    # Baseline: the unmutated tree must pass every bench, otherwise a "kill"
    # would be meaningless.
    emit("\n# baseline (unmutated v2/src)")
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
            line_no, err = apply_mutation(tmp, snap, m)
            if err:
                emit(f"\n=== MUT {m.id} [{m.cat}] {m.file} -- INVALID SPEC\n{err}")
                rows.append((m, 0, "INVALID", {}))
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
            rows.append((m, line_no, verdict, results))

            per = "  ".join(f"{n}={r.verdict}({r.seconds:.1f}s)"
                            for n, r in results.items())
            print(f"{m.id:4} {verdict:9} {m.file}:{line_no:<5} "
                  f"{m.desc[:56]:56} {per}", flush=True)
            emit(f"\n=== MUT {m.id} [{m.cat}] {m.file}:{line_no} -- {verdict}")
            emit(f"--- change: {m.find!r} -> {m.repl!r}")
            emit(f"--- intent: {m.desc}")
            emit(f"--- source: {snap[m.file].splitlines()[line_no-1].strip()}")
            for n, r in results.items():
                emit(f"--- {n}: {r.verdict} in {r.seconds:.2f}s")
                if r.detail:
                    for ln in r.detail.splitlines():
                        emit(f"    {ln}")

        emit("\n=== SUMMARY")
        emit("id,file,line,cat," + ",".join(benches) + ",verdict")
        for m, line_no, verdict, results in rows:
            cells = ",".join(results[n].verdict if n in results else "-"
                             for n in benches)
            emit(f"{m.id},{m.file},{line_no},{m.cat},{cells},{verdict}")

        counts: dict[str, int] = {}
        for _, _, verdict, _ in rows:
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
        per_bench = {n: sum(1 for _, _, v, r in rows
                            if n in r and r[n].verdict == "KILLED")
                     for n in benches}
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
