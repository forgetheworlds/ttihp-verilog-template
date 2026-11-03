// ===========================================================================
// top_formal.sv -- bounded-proof harness for src/tt_um_proteus.v
//
// One property per sby invocation: select with -D PROP_T<id>.  Internal state
// is read through PROBE wires bound by formal/run.sh with yosys
// `expose` + `flatten` + `connect -set` (yosys has no hierarchical refs: an
// `u.sig` reference silently becomes an undriven wire).
//
// Reset: rst_n is low on edge 0 and high afterwards.  The top's own
// synchroniser (rst_sync) takes 2 edges, so chip_rst_n is high from step 3 and
// eng_rst_n from step 4; the check window opens at step 6, after every
// sequential block has seen a reset edge.
//
// Environment: the SPI pins are free inputs.  Properties that need a host
// frame (only T7) rely on the solver choosing a legal SPI sequence; their
// cover() proves the antecedent is reachable inside the bound, so run.sh
// reports UNREACHABLE rather than a vacuous PASS.
// ===========================================================================
`default_nettype none

module top_formal (
  input wire       clk,
  input wire       rst_n,
  input wire       ena,
  input wire [7:0] ui_in,
  input wire [7:0] uio_in
);

  // ------------------------------------------------------- probe wires
  // fabric registers
  wire [7:0] uo_q, uio_q, oe_q, od_q;
  // per-engine write buses and the priority merge result
  wire [31:0] uo_d_all, uo_m_all, wo_d_all, wo_m_all;
  wire [31:0] oe_d_all, oe_m_all, od_d_all, od_m_all;
  wire [7:0]  m_uo, m_uio, m_oe, m_od;
  // run / halt bookkeeping
  wire [3:0]  run_reg, halted_mask, ready_mask, run_mask;
  // host register strobes
  wire        reg_we, win_wr, pm_sel;
  wire        wr_run, wr_halt, wr_uo, wr_uio, wr_oe, wr_od;
  // barriers
  wire [3:0]  bar_arr0, bar_arr1, bar_arr2, bar_arr3;
  wire [3:0]  arr_b0, arr_b1, arr_b2, arr_b3;
  wire        rel_b0, rel_b1, rel_b2, rel_b3;
  wire        bar_go0, bar_go1, bar_go2, bar_go3;
  wire        e_bar_req0, e_bar_req1, e_bar_req2, e_bar_req3;
  wire [1:0]  e_bar_id0, e_bar_id1, e_bar_id2, e_bar_id3;
  // host MISO line (before the uo_out[0] output mux)
  wire        miso;
  // host pin ownership: uo_out[0] only carries MISO while host_en is set
  wire        host_en;

  // ------------------------------------------------------------ DUT ports
  wire [7:0] uo_out, uio_out, uio_oe;

  tt_um_proteus u_top (
    .ui_in   (ui_in),
    .uo_out  (uo_out),
    .uio_in  (uio_in),
    .uio_out (uio_out),
    .uio_oe  (uio_oe),
    .ena     (ena),
    .clk     (clk),
    .rst_n   (rst_n)
  );

  // ------------------------------------------------------ cycle bookkeeping
  reg [2:0] f_cycles = 3'd0;
  always @(posedge clk) if (f_cycles != 3'd6) f_cycles <= f_cycles + 3'd1;
  wire first = (f_cycles == 3'd0);
  wire chk   = (f_cycles == 3'd6);

  always @(posedge clk) begin
    if (first) assume (!rst_n);
    else       assume (rst_n);
  end

  // ------------------------------------------- priority-merge reference model
  // Independent formulation of the documented merge rule: for each bit the
  // highest-numbered engine whose mask bit is set wins; otherwise the previous
  // register value is kept.  Deliberately written bitwise (not as the RTL's
  // 32-bit shift/or chain) so it is not a copy of the code under test.
  function [7:0] ref_merge(input [7:0] prev, input [31:0] d, input [31:0] m);
    integer b;
    integer k;
    reg [7:0] r;
    begin
      r = prev;
      for (b = 0; b < 8; b = b + 1)
        for (k = 0; k < 4; k = k + 1)
          if (m[k*8 + b]) r[b] = d[k*8 + b];
      ref_merge = r;
    end
  endfunction

  // ------------------------------------------------------------ properties
  always @(posedge clk) if (chk) begin

`ifdef PROP_T1
    // Open-drain release: a pin configured open-drain whose output register
    // drives 1 must never be driven (uio_oe = oe & ~(od & out)).
    assert ((uio_oe & od_q & uio_q) == 8'h00);
    assert (uio_oe == (oe_q & ~(od_q & uio_q)));
`endif

`ifdef PROP_T2
    // Pin-fabric determinism: the merged value is exactly the documented
    // priority function of the four engine buses and the previous register
    // value.  This is what "conflicting engines in one cycle" resolves to.
    assert (m_uio == ref_merge(uio_q, wo_d_all, wo_m_all));
    assert (m_uo  == ref_merge(uo_q,  uo_d_all, uo_m_all));
    assert (m_oe  == ref_merge(oe_q,  oe_d_all, oe_m_all));
    assert (m_od  == ref_merge(od_q,  od_d_all, od_m_all));
`endif

`ifdef PROP_T3
    // MISO is 0 whenever CS_N is high (ui_in[1] = CS_N).  Written as a plain
    // boolean: yosys does not accept SVA `|->` inside an immediate assert.
    assert (!ui_in[1] || (miso === 1'b0));
    // uo_out[0] carries MISO only while the host owns the pin; after
    // HOST_DISABLE the pin belongs to the fabric and may be driven high.
    assert (!(ui_in[1] && host_en) || (uo_out[0] === 1'b0));
`endif

`ifdef PROP_T4
    // No host register or program-memory write is issued while CS_N is high.
    assert (!(reg_we | win_wr | pm_sel | wr_run | wr_halt |
              wr_uo | wr_uio | wr_oe | wr_od) || !ui_in[1]);
`endif

`ifdef PROP_T5
    // bar_go for engine e implies every engine that is running has arrived at
    // that barrier id (arr_be already includes e's own current request).
    assert (!bar_go0 || ((arr_b0 & run_mask) == run_mask));
    assert (!bar_go1 || ((arr_b1 & run_mask) == run_mask));
    assert (!bar_go2 || ((arr_b2 & run_mask) == run_mask));
    assert (!bar_go3 || ((arr_b3 & run_mask) == run_mask));
`endif

`ifdef PROP_T6
    // bar_go is only asserted towards an engine that is actually waiting on the
    // barrier that released, so an unrelated release cannot free an engine.
    assert (!bar_go0 || (e_bar_req0 && rel_b0[e_bar_id0]));
    assert (!bar_go1 || (e_bar_req1 && rel_b1[e_bar_id1]));
    assert (!bar_go2 || (e_bar_req2 && rel_b2[e_bar_id2]));
    assert (!bar_go3 || (e_bar_req3 && rel_b3[e_bar_id3]));
`endif

`ifdef PROP_T7
    // HALT retires the engine's RUN bit in the same cycle, unless the host is
    // writing RUN/HALT in that cycle (host writes always win).
    if ($past(halted_mask[0]) && !$past(wr_run) && !$past(wr_halt))
      assert (!run_reg[0]);
    if ($past(halted_mask[1]) && !$past(wr_run) && !$past(wr_halt))
      assert (!run_reg[1]);
    if ($past(halted_mask[2]) && !$past(wr_run) && !$past(wr_halt))
      assert (!run_reg[2]);
    if ($past(halted_mask[3]) && !$past(wr_run) && !$past(wr_halt))
      assert (!run_reg[3]);
`endif

  end

  // ---------------------------------------------------------------- covers
  always @(posedge clk) if (f_cycles == 3'd6) begin
`ifdef PROP_T1
    // open-drain mode actually configured and driven high somewhere
    cover (|(od_q & uio_q));
`endif
`ifdef PROP_T3
    // a frame is open (CS_N low)
    cover (!ui_in[1]);
`endif
`ifdef PROP_T4
    // the host actually issued a register/program write in the window
    cover (reg_we | win_wr | pm_sel);
`endif
`ifdef PROP_T2
    // an engine actually drove a pin-write bus (needs a running program)
    cover ((|wo_m_all) || (|uo_m_all) || (|oe_m_all) || (|od_m_all));
`endif
`ifdef PROP_T7
    // The scenario T7 is about: engine 0 has just halted (it was running).
    cover ($past(run_reg[0]) && !$past(halted_mask[0]) && halted_mask[0]);
`endif
`ifdef PROP_T5
    cover (bar_go0 || bar_go1 || bar_go2 || bar_go3);
`endif
`ifdef PROP_T6
    cover (bar_go0 || bar_go1 || bar_go2 || bar_go3);
`endif
  end

endmodule

`default_nettype wire
