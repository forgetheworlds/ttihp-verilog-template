// ===========================================================================
// eng_formal.sv -- bounded-proof harness for src/proteus_engine.v
//
// Ported from v1 formal/eng_formal.sv.  The v2 engine is the v1 engine plus
// three things this harness pins down explicitly:
//
//   * the assist CSR port (LDAS/STAS/ASST).  It is an *input* environment here:
//     as_rdata is tied to 8'h00 and as_empty to 1'b1 (a defined "assist data
//     path is empty" answer), so every assist input has a constant value and
//     none of the properties can depend on an unconstrained input.  The formal
//     programs contain no assist opcode, so as_rd/as_wr/as_cmd_en stay low and
//     the tied values never reach an architectural register.
//   * the `halt_exec` output (HALT executing this cycle, used by the top to
//     retire the RUN bit) -- left unconnected; E8 constrains halted/PC, and
//     the RUN-retire path itself is a top-level property (out of scope here).
//   * PROG_DEPTH/FIFO_DEPTH keep their defaults (32/4), identical to v1, so the
//     boot ladder and the depths in run.sh carry over unchanged.
//
// One property per sby invocation: select with -D PROP_<id>.  Internal state
// is read through PROBE wires that run.sh binds with yosys `expose` + `flatten`
// + `connect -set` (hierarchical references are NOT supported by yosys:
// `u.in_cnt` would silently become an undriven wire).  The binding is explicit
// in the generated script, so a typo is a hard yosys error, not a vacuous PASS.
//
// Proof window: the DUT is reset on edge 0 only (`assume(!rst_n)` while
// f_cycles==0, `assume(rst_n)` afterwards); every property is checked from
// f_cycles==2 so that `$past` never reads pre-reset state.
//
// Environmental assumptions (harness only, never the DUT):
//   * run held high, run_mask=4'b0011 (this engine + one peer), bar_go=0.
//   * one program word written by the host while f_cycles==0; TEST_WORD is the
//     instruction under test.
//
// REACHABILITY: prog_ready only rises after PROG_DEPTH fill cycles (one array
// entry per cycle).  With PROG_DEPTH=32 execution starts at cycle ~34, so
// proofs about executing instructions need depth >= 40, and depth 48 to fill
// the output FIFO to 7.  run.sh carries the depth per property; each property
// also has a cover() so a PASS cannot be reported for an unreachable
// antecedent.
// ===========================================================================
`default_nettype none

module eng_formal (
  input wire        clk,
  input wire        rst_n,
  input wire        run,
  input wire        host_prog_we,
  input wire [2:0]  host_prog_be,
  input wire [5:0]  host_prog_addr,
  input wire [23:0] host_prog_data,
  input wire [7:0]  pin_ui,
  input wire [7:0]  pin_uo,
  input wire [7:0]  pin_uio,
  input wire [31:0] cycle,
  input wire [7:0]  irq,
  input wire [3:0]  run_mask,
  input wire        bar_go,
  input wire        hr_we,
  input wire [3:0]  hr_addr,
  input wire [7:0]  hr_wdata,
  input wire        host_in_push,
  input wire [7:0]  host_in_data,
  input wire        host_out_pop
);

  parameter PROG_DEPTH = 32;

  // ------------------------------------------------------- probe wires
  // Bound by `connect -set <name> u.<name>` after flatten (see run.sh).
  // Widths MUST match the DUT exactly: `connect` aborts on a width mismatch.
  // FIFO_DEPTH below must equal the DUT's default parameter
  // (src/proteus_engine.v: parameter FIFO_DEPTH = 4).
  parameter FIFO_DEPTH = 4;
  localparam FIFO_AW = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
  localparam FIFO_CW = $clog2(FIFO_DEPTH + 1);

  wire [FIFO_CW-1:0] in_cnt;
  wire [FIFO_CW-1:0] out_cnt;
  wire [FIFO_AW-1:0] in_rd, in_wr, out_rd;
  // The program counter is read from the DUT's own dbg_pc output (zero-extended
  // pc_r) instead of a probe: a probe must match the DUT width exactly, and
  // `connect` aborts on a width mismatch.
  wire       n_in_pop, n_out_push;
  wire       in_full_w, in_empty_w, out_full_w, out_empty_w;
  wire       exec_act, bar_waiting;

  // ------------------------------------------------------------- DUT ports
  wire [23:0] hp_rdata;
  wire [7:0]  wo_d, wo_m, uo_d, uo_m, oe_d, oe_m, od_d, od_m;
  wire [7:0]  irq_set, irq_clr;
  wire        bar_req;
  wire [1:0]  bar_id;
  wire        cap_req;
  wire [4:0]  cap_tag;
  wire [7:0]  hr_rdata;
  wire [7:0]  host_out_data;
  // Assist CSR port outputs (v2): driven by the DUT, unused by the properties.
  wire        as_rd, as_wr;
  wire [2:0]  as_id, as_reg, as_cmd_id;
  wire [7:0]  as_wdata, as_cmd;
  wire        as_cmd_en;
  wire        halted, error, halt_exec;
  wire [5:0]  dbg_pc;
  wire        prog_ready;

  // Keep the unused DUT outputs from being optimised into an unconnected
  // design: yosys prunes logic whose results nothing reads, and `opt_clean`
  // would then remove the assist decode this harness is meant to constrain.
  wire _unused = &{1'b0, as_rd, as_wr, as_id, as_reg, as_wdata, as_cmd_en,
                   as_cmd_id, as_cmd, halt_exec, error, host_out_data,
                   hp_rdata, hr_rdata};

  // Instantiated with the DUT's default parameters (PROG_DEPTH=32, ENG_ID=0)
  // on purpose: a parameter override turns the module into $paramod$... and
  // breaks the `select -module proteus_engine` probe binding in run.sh.
  proteus_engine u (
    .clk              (clk),
    .rst_n            (rst_n),
    .run              (run),
    .host_prog_we     (host_prog_we),
    .host_prog_be     (host_prog_be),
    .host_prog_addr   (host_prog_addr),
    .host_prog_data   (host_prog_data),
    .host_prog_rdata  (hp_rdata),
    .pin_ui           (pin_ui),
    .pin_uo           (pin_uo),
    .pin_uio          (pin_uio),
    .wo_data          (wo_d), .wo_mask (wo_m),
    .uo_data          (uo_d), .uo_mask (uo_m),
    .oe_data          (oe_d), .oe_mask (oe_m),
    .od_data          (od_d), .od_mask (od_m),
    .cycle            (cycle),
    .irq              (irq),
    .irq_set          (irq_set), .irq_clr (irq_clr),
    .run_mask         (run_mask),
    .bar_go           (bar_go),
    .bar_req          (bar_req), .bar_id (bar_id),
    .cap_req          (cap_req), .cap_tag (cap_tag),
    .hr_we            (hr_we), .hr_addr (hr_addr), .hr_wdata (hr_wdata),
    .hr_rdata         (hr_rdata),
    .host_in_push     (host_in_push), .host_in_data (host_in_data),
    .host_out_pop     (host_out_pop), .host_out_data (host_out_data),
    // Assist CSR port: environment inputs tied to defined constants (see the
    // header).  The response wires exist so the harness has no floating DUT
    // input; no property reads them.
    .as_rd            (as_rd),
    .as_wr            (as_wr),
    .as_id            (as_id),
    .as_reg           (as_reg),
    .as_wdata         (as_wdata),
    .as_cmd_en        (as_cmd_en),
    .as_cmd_id        (as_cmd_id),
    .as_cmd           (as_cmd),
    .as_rdata         (8'h00),
    .as_empty         (1'b1),
    .halted           (halted), .error (error), .dbg_pc (dbg_pc),
    .prog_ready       (prog_ready),
    .halt_exec        (halt_exec)
  );

  // ---------------------------------------------------------- test program
  // The reset fill puts HALT in every entry the host did not write, so a
  // one-instruction program runs once and then halts at PC=1.  The programs
  // below therefore loop (or block), which is what makes the FIFO/barrier
  // antecedents reachable inside the bound.
  localparam [23:0] W_HALT = {7'h38, 3'd0, 3'd0, 8'h00, 3'd0};  // HALT
  localparam [23:0] W_BAR  = {7'h47, 3'd0, 3'd0, 8'h00, 3'd0};  // BAR 0
  localparam [23:0] W_PUSH = {7'h40, 3'd0, 3'd0, 8'h00, 3'd0};  // PUSH r0
  localparam [23:0] W_PULL = {7'h41, 3'd0, 3'd0, 8'h00, 3'd0};  // PULL r0
  localparam [23:0] W_JMP0 = {7'h30, 3'd0, 3'd0, 8'h00, 3'd0};  // JMP 0

`ifdef PROP_E7
  // wait on barrier 0 forever (worst case: never released by the peer)
  localparam [23:0] PROG0 = W_BAR;
  localparam [23:0] PROG1 = W_HALT;
  localparam [23:0] PROG2 = W_HALT;
`elsif PROP_E8
  // halt on the first executed instruction
  localparam [23:0] PROG0 = W_HALT;
  localparam [23:0] PROG1 = W_HALT;
  localparam [23:0] PROG2 = W_HALT;
`elsif PROP_E4B
  // pull until the input FIFO is empty: exercises n_in_pop
  localparam [23:0] PROG0 = W_PULL;
  localparam [23:0] PROG1 = W_JMP0;
  localparam [23:0] PROG2 = W_HALT;
`else
  // push until the output FIFO is full: exercises n_out_push and the
  // full-FIFO guard, and fills out_cnt so the FIFO covers are reachable
  localparam [23:0] PROG0 = W_PUSH;
  localparam [23:0] PROG1 = W_JMP0;
  localparam [23:0] PROG2 = W_HALT;
`endif

  // ------------------------------------------------------ cycle bookkeeping
  // f_cycles saturates at 4.  Cycle 0 is reset; the host program words must be
  // written from cycle 1 onwards, because the DUT's whole sequential block is
  // inside `if (!rst_n)` -- a host write during the reset edge is dropped and
  // the reset fill then leaves HALT in that entry (verified in simulation:
  // the fetched instruction was 0x700000 = HALT, not the test word).
  // The fill counter has already passed entry k by cycle k+1, and the host
  // write wins over the fill for the same entry, so cycles 1..3 is safe.
  reg [2:0] f_cycles = 3'd0;
  always @(posedge clk) if (f_cycles != 3'd4) f_cycles <= f_cycles + 3'd1;
  wire first     = (f_cycles == 3'd0);
  wire chk       = (f_cycles == 3'd4);

  always @(posedge clk) begin
    if (first) begin
      assume (!rst_n);
      assume (run);
      assume (run_mask == 4'b0011);
      assume (!bar_go);
      assume (!host_prog_we);
    end else begin
      assume (rst_n);
      assume (run);
      assume (run_mask == 4'b0011);
      assume (!bar_go);
      case (f_cycles)
        3'd1: begin
          assume (host_prog_we);
          assume (host_prog_addr == 6'd0);
          assume (host_prog_be   == 3'b111);
          assume (host_prog_data == PROG0);
        end
        3'd2: begin
          assume (host_prog_we);
          assume (host_prog_addr == 6'd1);
          assume (host_prog_be   == 3'b111);
          assume (host_prog_data == PROG1);
        end
        3'd3: begin
          assume (host_prog_we);
          assume (host_prog_addr == 6'd2);
          assume (host_prog_be   == 3'b111);
          assume (host_prog_data == PROG2);
        end
        default: assume (!host_prog_we);
      endcase
    end
  end

  // ------------------------------------------------------------ properties
  always @(posedge clk) if (chk) begin

`ifdef PROP_DBG
    // Debug: expected to FAIL at the first execution cycle, producing a trace
    // that shows what instruction is actually fetched.  Not part of the
    // property set; used to explain the boot reachability ladder (E9).
    assert (!exec_act);
`endif

`ifdef PROP_E0
    // NEGATIVE CONTROL -- expected to FAIL.  It proves the probe binding is
    // live: if `in_cnt` were an unbound/undriven wire this would still fail,
    // but if the property were not observing the FIFO at all the solver could
    // not produce a counterexample where in_cnt really exceeds 3 after a host
    // push.  run.sh runs it once and reports the expected counterexample.
    assert (in_cnt <= FIFO_DEPTH - 1);
`endif

`ifdef PROP_E1
    // PC never leaves the program image.  dbg_pc is pc_r zero-extended to 6
    // bits, so this is exactly pc_r < PROG_DEPTH.
    assert (dbg_pc < PROG_DEPTH);
`endif

`ifdef PROP_E2
    // FIFO occupancy never exceeds the declared depth, the full flag is
    // exactly "count == depth" (so a stale harness constant fails loudly
    // instead of silently weakening the bound), and full/empty cannot both
    // be set.
    assert (in_cnt  <= FIFO_DEPTH);
    assert (out_cnt <= FIFO_DEPTH);
    assert (in_full_w  == (in_cnt  == FIFO_DEPTH));
    assert (out_full_w == (out_cnt == FIFO_DEPTH));
    assert (!(in_full_w  && in_empty_w));
    assert (!(out_full_w && out_empty_w));
`endif

`ifdef PROP_E3
    // No push into a full input FIFO: a byte offered while the FIFO is full is
    // dropped, so the write pointer must not move.  Occupancy may still change
    // in the same cycle, because a concurrent engine pop is legal.
    if ($past(host_in_push) && $past(in_cnt) == FIFO_DEPTH)
      assert (in_wr == $past(in_wr));
`endif

`ifdef PROP_E4
    // No pop from an empty input FIFO; no engine push into a full output FIFO.
    assert (!n_in_pop   || (in_cnt  > 0));
    assert (!n_out_push || (out_cnt < FIFO_DEPTH));
`endif

`ifdef PROP_E4B
    // Same invariants as E4, but with a PULL loop so the input-FIFO half is
    // the one actually exercised (E4's program pushes).
    assert (!n_in_pop   || (in_cnt  > 0));
    assert (!n_out_push || (out_cnt < FIFO_DEPTH));
`endif

`ifdef PROP_E5
    // No pop from an empty output FIFO at the host port: the pop must have no
    // effect, i.e. the read pointer does not advance.  Occupancy may still
    // rise in that cycle because a concurrent engine PUSH is legal, so the
    // count is only constrained when no push commits.
    if ($past(host_out_pop) && $past(out_cnt) == 0) begin
      assert (out_rd == $past(out_rd));
      if (!$past(n_out_push)) assert (out_cnt == $past(out_cnt));
    end
`endif

`ifdef PROP_E6
    // No execution before the program image is defined: PC frozen and no pin
    // write bus driven while prog_ready is low.
    if (!prog_ready) begin
      assert (!exec_act);
      assert ($stable(dbg_pc));
      assert (wo_m == 8'h00 && uo_m == 8'h00 &&
              oe_m == 8'h00 && od_m == 8'h00);
    end
`endif

`ifdef PROP_E7
    // OP_BAR cannot advance while it waits and the barrier is not released.
    if (bar_waiting && !bar_go) assert ($stable(dbg_pc));
`endif

`ifdef PROP_E8
    // HALT is sticky and freezes the PC while run stays high.
    if (halted) begin
      assert ($stable(dbg_pc));
      assert (halted);
    end
`endif

`ifdef PROP_E10
    // prog_ready is a one-way latch: never drops after assertion.
    if (prog_ready) assert (prog_ready);
`endif

`ifdef PROP_E11
    // Program memory has exactly two writers: the reset fill (only while
    // !prog_ready) and the host program port.  There is no engine
    // self-modification path.  Stated observably: once the fill is done, a
    // program word only changes in a cycle where host_prog_we is high.
    if ($past(prog_ready) && !$past(host_prog_we) && $stable(host_prog_addr))
      assert (hp_rdata == $past(hp_rdata));
`endif

  end

  // ---------------------------------------------------------------- covers
  always @(posedge clk) if (chk) begin
`ifdef PROP_E0
    cover (in_cnt == FIFO_DEPTH);
`endif
`ifdef PROP_E1
    cover (dbg_pc >= 6'd1);        // PC actually advanced (engine executed)
`endif
`ifdef PROP_E2
    cover (in_cnt  == FIFO_DEPTH);   // input FIFO actually filled
    cover (out_cnt >= 2);            // output FIFO actually has entries
`endif
`ifdef PROP_E3
    cover (host_in_push && in_cnt == FIFO_DEPTH);
`endif
`ifdef PROP_E4
    cover (n_out_push && out_cnt == FIFO_DEPTH - 1);
`endif
`ifdef PROP_E4B
    cover (n_in_pop);
`endif
`ifdef PROP_E5
    cover (host_out_pop && out_cnt == 4'd0);
`endif
`ifdef PROP_E6
    cover (!prog_ready);
    cover (prog_ready);
`endif
`ifdef PROP_E7
    cover (bar_waiting && !bar_go);
`endif
`ifdef PROP_E8
    cover (halted);
`endif
`ifdef PROP_E10
    cover (prog_ready);
`endif
`ifdef PROP_E11
    cover (prog_ready && !host_prog_we);
`endif
`ifdef PROP_E9
    // Reachability audit: which milestone of the boot sequence is reached
    // inside the bound.  Used to justify the depth of the execution properties.
    cover (prog_ready);
    cover (exec_act);
    cover (dbg_pc >= 6'd1);
    cover (halted);
    cover (out_cnt >= 4'd1);
`endif
  end

endmodule

`default_nettype wire
