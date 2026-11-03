// ===========================================================================
// tt_um_proteus.v -- PROTEUS top level (Tiny Tapeout, IHP sg13cmos5l 6x4)
//
// Four programmable protocol engines, 24-pin fabric with per-pin direction /
// open-drain, deadline-capable 32-bit timebase, 4 hardware barriers, 8 IRQ
// lines, host SPI slave with a 16-bit register map and a CAP_DEPTH-entry
// (default 4) edge-timestamp capture FIFO.  Contract: docs/architecture.md.
// Numeric truth: tools/isa.py, tools/model.py.
//
// Decisions / deviations -- read before editing:
//
//  1. PROG_DEPTH is a top parameter (default 32, area ruling).  Program window
//     is 0x0100 + e*0x100 + i*4 + b for i < PROG_DEPTH and b < 3.  Writes with
//     i >= PROG_DEPTH are dropped; reads there return 0.  Writes use the
//     engine's byte-enable port (host_prog_be) so every host byte write lands
//     in exactly one byte lane -- no shadow RAM and no write combining.
//
//  2. Pins presented to the engines: ui_in[2:0] (SCK/CS_N/MOSI) and
//     uo_out[1:0] (IRQ/MISO) read as 0 while host_en=1, because the host owns
//     them.  After HOST_DISABLE they are ordinary fabric pins (the docs'
//     "20 protocol pins").  uio_in is presented raw, exactly as
//     tools/model.py pin_state() does.
//
//  3. Capture and collision sample the raw uio_in (no synchroniser) so capture
//     timestamps stay cycle-exact with tools/model.py; the analyser axis
//     depends on it.  A metastable sample can only mis-stage one event.
//
//  4. Engine window reads: +0x0 E_STATUS comes from the engine's hr address 15
//     ("status", frozen interface), +0x1 E_PC from dbg_pc, +0x3 E_ERROR from
//     error.  E_FLAGS (+0x2) has no engine interface in the frozen port list
//     and reads 0.
//
//  5. Writes to 0x0006 (SOFT_RESET) and 0x0007 (HOST_EN) are consumed by
//     proteus_host, which owns those two bits.  This module ignores them on
//     write and returns {7'b0,host_en} for a 0x0007 read.
//
//  6. Collision is stored as an 8-bit per-pin sticky mask (0x0510, cleared by
//     0x0511); STATUS[3] is its reduction.  A single bit would lose the pin
//     information for no area saving.
//
//  7. Engine-window geometry (orchestrator-confirmed, docs updated): the map's
//     offsets run 0x00..0x15, which do not fit the 0x10 stride the map also
//     states, so the window is 0x20 bytes: base = 0x0010 + 0x20*e, region
//     0x0010..0x008F, engine = (addr-0x0010)[6:5], offset = (addr-0x0010)[4:0].
//     A comment block at the decode lists every offset for test authors.
//
//  8. Barrier handshake: the top releases a barrier in the cycle the last
//     running engine arrives (model.py semantics) and drives bar_go only to
//     engines waiting on the barrier that released.  proteus_engine's bar_req
//     must therefore not depend on bar_go (combinational loop); bar_go only
//     gates the engine's BAR advance.  See the note in proteus_engine.v.
//
//  9. Engines take a separate reset net from the top's own registers: the
//     engine port is an asynchronous reset, the top's registers reset
//     synchronously, and the two nets are kept structurally distinct to avoid
//     a mixed-async/sync reset (Verilator SYNCASYNCNET).
// ===========================================================================

`default_nettype none

module tt_um_proteus #(
  parameter PROG_DEPTH = 32,
  // Edge-timestamp capture FIFO entries (default 4: measured area lever).
  // Count width and the overflow condition derive from it; the host-visible
  // CAP_STATUS count field stays [3:0].
  parameter CAP_DEPTH  = 4
) (
  input  wire [7:0] ui_in,      // Dedicated inputs
  output wire [7:0] uo_out,     // Dedicated outputs
  input  wire [7:0] uio_in,     // IOs: input path
  output wire [7:0] uio_out,    // IOs: output path
  output wire [7:0] uio_oe,     // IOs: enable path (1 = output)
  input  wire       ena,        // always 1 when powered
  input  wire       clk,        // clock
  input  wire       rst_n       // reset, active low
);

  `include "proteus_defs.vh"

  // 7 bits: PROG_DEPTH=64 must not truncate to 0 (which would make every
  // program-memory write fail and every program read return 0).
  localparam [6:0] PDEPTH = PROG_DEPTH;

  // Capture FIFO geometry: pointer wraps modulo CAP_DEPTH, the count needs one
  // extra bit so it can represent CAP_DEPTH itself (full).
  localparam integer       CAP_AW  = (CAP_DEPTH > 1) ? $clog2(CAP_DEPTH) : 1;
  localparam integer       CAP_CNT_W = $clog2(CAP_DEPTH + 1);

  // ------------------------------------------------------------------ reset
  // Asynchronous assert, synchronous release.
  reg [1:0] rst_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_sync <= 2'b00;
    else        rst_sync <= {rst_sync[0], 1'b1};
  end
  wire rst_n_s = rst_sync[1];

  // Soft reset (host command 0x08 or a write to 0x0006): stretch the one-clk
  // pulse into a four-clk synchronous reset window for the whole chip.
  reg [2:0] soft_rst_cnt;
  wire      host_soft_reset;
  always @(posedge clk) begin
    if (!rst_n_s)                  soft_rst_cnt <= 3'd0;
    else if (host_soft_reset)      soft_rst_cnt <= 3'd4;
    else if (soft_rst_cnt != 3'd0) soft_rst_cnt <= soft_rst_cnt - 3'd1;
  end
  wire chip_rst_n = rst_n_s & (soft_rst_cnt == 3'd0);
  // Engines declare an asynchronous reset port (`always @(posedge clk or
  // negedge rst_n)`), so they get their own net: rst_n_s is the classic
  // async-assert / sync-release synchroniser output, gated by a registered
  // "soft-reset finished" flag, which keeps this net distinct from the
  // synchronous chip_rst_n the top's own registers use (lint: SYNCASYNCNET)
  // and still releases the engines one clk after the internal registers.
  reg eng_rst_rel;
  always @(posedge clk) begin
    if (!rst_n_s) eng_rst_rel <= 1'b0;
    else          eng_rst_rel <= (soft_rst_cnt == 3'd0);
  end
  wire eng_rst_n = rst_n_s & eng_rst_rel;

  // -------------------------------------------------------------- timebase
  reg [31:0] cycle;
  always @(posedge clk) begin
    if (!chip_rst_n) cycle <= 32'd0;
    else             cycle <= cycle + 32'd1;
  end

  // ------------------------------------------------------ fabric registers
  reg [7:0] uo_q, uio_q, oe_q, od_q;

  // Pin views handed to the engines.
  wire        host_en;
  wire [7:0] fab_ui = {ui_in[7:3], host_en ? 3'b000 : ui_in[2:0]};
  wire [7:0] fab_uo = {uo_q[7:2],  host_en ? 2'b00  : uo_q[1:0]};

  // ---------------------------------------------------------- host SPI slave
  wire        reg_we;
  wire [15:0] reg_addr;
  wire [7:0]  reg_wdata;
  wire        reg_re;
  wire [15:0] reg_raddr;
  wire        miso;
  wire        host_soft_reset_w;

  reg  [7:0]  reg_rdata;

  proteus_host u_host (
    .clk       (clk),
    .rst_n     (chip_rst_n),
    .sck       (ui_in[0]),
    .cs_n      (ui_in[1]),
    .mosi      (ui_in[2]),
    .miso      (miso),
    .reg_we    (reg_we),
    .reg_addr  (reg_addr),
    .reg_wdata (reg_wdata),
    .reg_re    (reg_re),
    .reg_raddr (reg_raddr),
    .reg_rdata (reg_rdata),
    .host_en   (host_en),
    .soft_reset(host_soft_reset_w)
  );
  assign host_soft_reset = host_soft_reset_w;

  // ------------------------------------------------- engine <-> top wiring
  wire [5:0]  hp_addr;
  wire [23:0] hp_wdata;
  wire [3:0]  hp_we;
  wire [11:0] hp_be;                    // 3 byte enables per engine

  wire [23:0] e_hprd0, e_hprd1, e_hprd2, e_hprd3;
  wire [7:0]  e_wo_d0, e_wo_d1, e_wo_d2, e_wo_d3;
  wire [7:0]  e_wo_m0, e_wo_m1, e_wo_m2, e_wo_m3;
  wire [7:0]  e_uo_d0, e_uo_d1, e_uo_d2, e_uo_d3;
  wire [7:0]  e_uo_m0, e_uo_m1, e_uo_m2, e_uo_m3;
  wire [7:0]  e_oe_d0, e_oe_d1, e_oe_d2, e_oe_d3;
  wire [7:0]  e_oe_m0, e_oe_m1, e_oe_m2, e_oe_m3;
  wire [7:0]  e_od_d0, e_od_d1, e_od_d2, e_od_d3;
  wire [7:0]  e_od_m0, e_od_m1, e_od_m2, e_od_m3;
  wire [7:0]  e_is0, e_is1, e_is2, e_is3;     // irq set pulses
  wire [7:0]  e_ic0, e_ic1, e_ic2, e_ic3;     // irq clear pulses
  wire        e_bar_req0, e_bar_req1, e_bar_req2, e_bar_req3;
  wire [1:0]  e_bar_id0, e_bar_id1, e_bar_id2, e_bar_id3;
  wire        e_cap_req0, e_cap_req1, e_cap_req2, e_cap_req3;
  wire [4:0]  e_cap_tag0, e_cap_tag1, e_cap_tag2, e_cap_tag3;
  wire [7:0]  e_hr0, e_hr1, e_hr2, e_hr3;
  wire [7:0]  e_out0, e_out1, e_out2, e_out3;
  wire        e_halt0, e_halt1, e_halt2, e_halt3;
  wire        e_err0, e_err1, e_err2, e_err3;
  wire        e_rdy0, e_rdy1, e_rdy2, e_rdy3;
  wire [5:0]  e_pc0, e_pc1, e_pc2, e_pc3;
  wire        e_hx0, e_hx1, e_hx2, e_hx3;      // HALT executing this cycle

  wire [3:0]  halted_mask = {e_halt3, e_halt2, e_halt1, e_halt0};
  // A HALT instruction retires its own RUN bit in the same cycle (model.py:
  // the HALT step sets halted=1 and run=0 together).  Host RUN/HALT writes
  // still win in run_reg below.
  wire [3:0]  halt_mask   = {e_hx3, e_hx2, e_hx1, e_hx0};
  wire [3:0]  ready_mask  = {e_rdy3,  e_rdy2,  e_rdy1,  e_rdy0};
  wire [3:0]  err_mask    = {e_err3,  e_err2,  e_err1,  e_err0};
  reg  [3:0]  run_reg;
  wire [3:0]  run_mask    = run_reg & (~halted_mask) & ready_mask;

  reg  [7:0]  irq;
  reg  [7:0]  irq_enable;

  wire [3:0]  hr_we;
  wire [3:0]  hr_addr;
  wire [3:0]  in_push;
  wire [3:0]  out_pop;
  wire        bar_go0, bar_go1, bar_go2, bar_go3;

  // -------------------------------------------------------------- engines
  proteus_engine #(.PROG_DEPTH(PROG_DEPTH), .ENG_ID(0)) u_eng0 (
    .clk(clk), .rst_n(eng_rst_n), .run(run_reg[0]),
    .host_prog_we(hp_we[0]), .host_prog_addr(hp_addr), .host_prog_data(hp_wdata),
    .host_prog_be(hp_be[2:0]), .host_prog_rdata(e_hprd0),
    .pin_ui(fab_ui), .pin_uo(fab_uo), .pin_uio(uio_in),
    .wo_data(e_wo_d0), .wo_mask(e_wo_m0),
    .uo_data(e_uo_d0), .uo_mask(e_uo_m0),
    .oe_data(e_oe_d0), .oe_mask(e_oe_m0),
    .od_data(e_od_d0), .od_mask(e_od_m0),
    .cycle(cycle), .irq(irq),
    .irq_set(e_is0), .irq_clr(e_ic0),
    .run_mask(run_mask), .bar_go(bar_go0),
    .bar_req(e_bar_req0), .bar_id(e_bar_id0),
    .cap_req(e_cap_req0), .cap_tag(e_cap_tag0),
    .hr_we(hr_we[0]), .hr_addr(hr_addr), .hr_wdata(reg_wdata), .hr_rdata(e_hr0),
    .host_in_push(in_push[0]), .host_in_data(reg_wdata),
    .host_out_pop(out_pop[0]), .host_out_data(e_out0),
    .halted(e_halt0), .error(e_err0), .dbg_pc(e_pc0), .prog_ready(e_rdy0),
    .halt_exec(e_hx0)
  );

  proteus_engine #(.PROG_DEPTH(PROG_DEPTH), .ENG_ID(1)) u_eng1 (
    .clk(clk), .rst_n(eng_rst_n), .run(run_reg[1]),
    .host_prog_we(hp_we[1]), .host_prog_addr(hp_addr), .host_prog_data(hp_wdata),
    .host_prog_be(hp_be[5:3]), .host_prog_rdata(e_hprd1),
    .pin_ui(fab_ui), .pin_uo(fab_uo), .pin_uio(uio_in),
    .wo_data(e_wo_d1), .wo_mask(e_wo_m1),
    .uo_data(e_uo_d1), .uo_mask(e_uo_m1),
    .oe_data(e_oe_d1), .oe_mask(e_oe_m1),
    .od_data(e_od_d1), .od_mask(e_od_m1),
    .cycle(cycle), .irq(irq),
    .irq_set(e_is1), .irq_clr(e_ic1),
    .run_mask(run_mask), .bar_go(bar_go1),
    .bar_req(e_bar_req1), .bar_id(e_bar_id1),
    .cap_req(e_cap_req1), .cap_tag(e_cap_tag1),
    .hr_we(hr_we[1]), .hr_addr(hr_addr), .hr_wdata(reg_wdata), .hr_rdata(e_hr1),
    .host_in_push(in_push[1]), .host_in_data(reg_wdata),
    .host_out_pop(out_pop[1]), .host_out_data(e_out1),
    .halted(e_halt1), .error(e_err1), .dbg_pc(e_pc1), .prog_ready(e_rdy1),
    .halt_exec(e_hx1)
  );

  proteus_engine #(.PROG_DEPTH(PROG_DEPTH), .ENG_ID(2)) u_eng2 (
    .clk(clk), .rst_n(eng_rst_n), .run(run_reg[2]),
    .host_prog_we(hp_we[2]), .host_prog_addr(hp_addr), .host_prog_data(hp_wdata),
    .host_prog_be(hp_be[8:6]), .host_prog_rdata(e_hprd2),
    .pin_ui(fab_ui), .pin_uo(fab_uo), .pin_uio(uio_in),
    .wo_data(e_wo_d2), .wo_mask(e_wo_m2),
    .uo_data(e_uo_d2), .uo_mask(e_uo_m2),
    .oe_data(e_oe_d2), .oe_mask(e_oe_m2),
    .od_data(e_od_d2), .od_mask(e_od_m2),
    .cycle(cycle), .irq(irq),
    .irq_set(e_is2), .irq_clr(e_ic2),
    .run_mask(run_mask), .bar_go(bar_go2),
    .bar_req(e_bar_req2), .bar_id(e_bar_id2),
    .cap_req(e_cap_req2), .cap_tag(e_cap_tag2),
    .hr_we(hr_we[2]), .hr_addr(hr_addr), .hr_wdata(reg_wdata), .hr_rdata(e_hr2),
    .host_in_push(in_push[2]), .host_in_data(reg_wdata),
    .host_out_pop(out_pop[2]), .host_out_data(e_out2),
    .halted(e_halt2), .error(e_err2), .dbg_pc(e_pc2), .prog_ready(e_rdy2),
    .halt_exec(e_hx2)
  );

  proteus_engine #(.PROG_DEPTH(PROG_DEPTH), .ENG_ID(3)) u_eng3 (
    .clk(clk), .rst_n(eng_rst_n), .run(run_reg[3]),
    .host_prog_we(hp_we[3]), .host_prog_addr(hp_addr), .host_prog_data(hp_wdata),
    .host_prog_be(hp_be[11:9]), .host_prog_rdata(e_hprd3),
    .pin_ui(fab_ui), .pin_uo(fab_uo), .pin_uio(uio_in),
    .wo_data(e_wo_d3), .wo_mask(e_wo_m3),
    .uo_data(e_uo_d3), .uo_mask(e_uo_m3),
    .oe_data(e_oe_d3), .oe_mask(e_oe_m3),
    .od_data(e_od_d3), .od_mask(e_od_m3),
    .cycle(cycle), .irq(irq),
    .irq_set(e_is3), .irq_clr(e_ic3),
    .run_mask(run_mask), .bar_go(bar_go3),
    .bar_req(e_bar_req3), .bar_id(e_bar_id3),
    .cap_req(e_cap_req3), .cap_tag(e_cap_tag3),
    .hr_we(hr_we[3]), .hr_addr(hr_addr), .hr_wdata(reg_wdata), .hr_rdata(e_hr3),
    .host_in_push(in_push[3]), .host_in_data(reg_wdata),
    .host_out_pop(out_pop[3]), .host_out_data(e_out3),
    .halted(e_halt3), .error(e_err3), .dbg_pc(e_pc3), .prog_ready(e_rdy3),
    .halt_exec(e_hx3)
  );

  // ------------------------------------------------------- pin fabric merge
  wire [31:0] uo_d_all = {e_uo_d3, e_uo_d2, e_uo_d1, e_uo_d0};
  wire [31:0] uo_m_all = {e_uo_m3, e_uo_m2, e_uo_m1, e_uo_m0};
  wire [31:0] wo_d_all = {e_wo_d3, e_wo_d2, e_wo_d1, e_wo_d0};
  wire [31:0] wo_m_all = {e_wo_m3, e_wo_m2, e_wo_m1, e_wo_m0};
  wire [31:0] oe_d_all = {e_oe_d3, e_oe_d2, e_oe_d1, e_oe_d0};
  wire [31:0] oe_m_all = {e_oe_m3, e_oe_m2, e_oe_m1, e_oe_m0};
  wire [31:0] od_d_all = {e_od_d3, e_od_d2, e_od_d1, e_od_d0};
  wire [31:0] od_m_all = {e_od_m3, e_od_m2, e_od_m1, e_od_m0};

  reg [7:0] m_uo, m_uio, m_oe, m_od;
  integer   mi;
  always @* begin
    m_uo  = uo_q;
    m_uio = uio_q;
    m_oe  = oe_q;
    m_od  = od_q;
    for (mi = 0; mi < 4; mi = mi + 1) begin
      m_uo  = (m_uo  & ~uo_m_all[mi*8 +: 8]) | (uo_d_all[mi*8 +: 8] & uo_m_all[mi*8 +: 8]);
      m_uio = (m_uio & ~wo_m_all[mi*8 +: 8]) | (wo_d_all[mi*8 +: 8] & wo_m_all[mi*8 +: 8]);
      m_oe  = (m_oe  & ~oe_m_all[mi*8 +: 8]) | (oe_d_all[mi*8 +: 8] & oe_m_all[mi*8 +: 8]);
      m_od  = (m_od  & ~od_m_all[mi*8 +: 8]) | (od_d_all[mi*8 +: 8] & od_m_all[mi*8 +: 8]);
    end
  end

  // ------------------------------------------------------- register strobes
  wire wr_run      = reg_we && (reg_addr == `PROTEUS_RA_RUN);
  wire wr_halt     = reg_we && (reg_addr == `PROTEUS_RA_HALT);
  wire wr_irq_ack  = reg_we && (reg_addr == `PROTEUS_RA_IRQ_ACK);
  wire wr_irq_en   = reg_we && (reg_addr == `PROTEUS_RA_IRQ_ENABLE);
  wire wr_cap_en   = reg_we && (reg_addr == `PROTEUS_RA_CAP_EN);
  wire cap_pop     = reg_we && (reg_addr == `PROTEUS_RA_CAP_POP);
  wire wr_coll_clr = reg_we && (reg_addr == `PROTEUS_RA_COLL_CLR);
  wire wr_uo       = reg_we && (reg_addr == `PROTEUS_RA_UO_OUT);
  wire wr_uio      = reg_we && (reg_addr == `PROTEUS_RA_UIO_OUT);
  wire wr_oe       = reg_we && (reg_addr == `PROTEUS_RA_UIO_OE);
  wire wr_od       = reg_we && (reg_addr == `PROTEUS_RA_UIO_OD);

  always @(posedge clk) begin
    if (!chip_rst_n) begin
      uo_q  <= 8'h00;
      uio_q <= 8'h00;
      oe_q  <= 8'h00;
      od_q  <= 8'h00;
    end else begin
      // Host pin-register writes win over engine traffic in the same cycle.
      // Engine writes to uo_out[1:0] are dropped while the host owns them.
      uo_q  <= wr_uo  ? reg_wdata :
               (host_en ? {m_uo[7:2], uo_q[1:0]} : m_uo);
      uio_q <= wr_uio ? reg_wdata : m_uio;
      oe_q  <= wr_oe  ? reg_wdata : m_oe;
      od_q  <= wr_od  ? reg_wdata : m_od;
    end
  end

  // ---------------------------------------------------- collision detection
  wire [7:0] od_low    = oe_q & od_q & (~uio_q);    // open-drain pull-downs
  wire [7:0] pp_driven = oe_q & (~od_q);            // push-pull drivers
  wire [7:0] coll_now  = (pp_driven & (uio_in ^ uio_q)) | (od_low & uio_in);

  reg [7:0] collision_q;
  always @(posedge clk) begin
    if (!chip_rst_n)      collision_q <= 8'h00;
    else if (wr_coll_clr) collision_q <= 8'h00;
    else                  collision_q <= collision_q | coll_now;
  end
  wire coll_any = |collision_q;

  // ---------------------------------------------------------- assert record
  reg [7:0] assert_info;
  reg       err_q0, err_q1, err_q2, err_q3;
  always @(posedge clk) begin
    if (!chip_rst_n) begin
      err_q0 <= 1'b0; err_q1 <= 1'b0; err_q2 <= 1'b0; err_q3 <= 1'b0;
      assert_info <= 8'h00;
    end else begin
      err_q0 <= e_err0; err_q1 <= e_err1; err_q2 <= e_err2; err_q3 <= e_err3;
      if      (e_err0 & (~err_q0)) assert_info <= {2'b00, 2'd0, e_pc0[3:0]};
      else if (e_err1 & (~err_q1)) assert_info <= {2'b00, 2'd1, e_pc1[3:0]};
      else if (e_err2 & (~err_q2)) assert_info <= {2'b00, 2'd2, e_pc2[3:0]};
      else if (e_err3 & (~err_q3)) assert_info <= {2'b00, 2'd3, e_pc3[3:0]};
    end
  end

  // ---------------------------------------------------------------- capture
  reg [7:0]  cap_en;
  reg [7:0]  uio_prev;
  reg [36:0] cap_mem [0:CAP_DEPTH-1];
  reg [CAP_AW-1:0]    cap_wp;
  reg [CAP_CNT_W-1:0] cap_cnt;
  reg        cap_ovf;

  wire [7:0] cap_diff = (uio_in ^ uio_prev) & cap_en;

  // Lowest changed pin wins, matching tools/model.py _capture_cycle().
  reg [3:0] cap_edge_pin;
  reg       cap_edge_lvl;
  always @* begin
    cap_edge_pin = 4'd0;
    cap_edge_lvl = 1'b0;
    if      (cap_diff[0]) begin cap_edge_pin = 4'd0; cap_edge_lvl = uio_in[0]; end
    else if (cap_diff[1]) begin cap_edge_pin = 4'd1; cap_edge_lvl = uio_in[1]; end
    else if (cap_diff[2]) begin cap_edge_pin = 4'd2; cap_edge_lvl = uio_in[2]; end
    else if (cap_diff[3]) begin cap_edge_pin = 4'd3; cap_edge_lvl = uio_in[3]; end
    else if (cap_diff[4]) begin cap_edge_pin = 4'd4; cap_edge_lvl = uio_in[4]; end
    else if (cap_diff[5]) begin cap_edge_pin = 4'd5; cap_edge_lvl = uio_in[5]; end
    else if (cap_diff[6]) begin cap_edge_pin = 4'd6; cap_edge_lvl = uio_in[6]; end
    else if (cap_diff[7]) begin cap_edge_pin = 4'd7; cap_edge_lvl = uio_in[7]; end
  end
  wire cap_edge = |cap_diff;

  // Push arbitration: engines 0..3 software events, then the external edge --
  // the same order tools/model.py appends them within one cycle.
  reg [36:0] cap_src  [0:4];
  reg [36:0] cap_ev   [0:4];
  reg [CAP_AW-1:0] cap_slot [0:4];
  reg [3:0]  cap_nev;
  reg [3:0]  cap_ok;
  integer    ck;

  wire [4:0] cap_src_v   = {cap_edge, e_cap_req3, e_cap_req2, e_cap_req1, e_cap_req0};
  wire       cap_pop_eff = cap_pop && (cap_cnt != 0);
  wire [CAP_CNT_W-1:0] cap_free =
      CAP_DEPTH - cap_cnt + {{(CAP_CNT_W-1){1'b0}}, cap_pop_eff};

  always @* begin
    cap_src[0] = {cycle, e_cap_tag0[3:0], e_cap_tag0[4]};
    cap_src[1] = {cycle, e_cap_tag1[3:0], e_cap_tag1[4]};
    cap_src[2] = {cycle, e_cap_tag2[3:0], e_cap_tag2[4]};
    cap_src[3] = {cycle, e_cap_tag3[3:0], e_cap_tag3[4]};
    cap_src[4] = {cycle, cap_edge_pin, cap_edge_lvl};
    cap_nev  = 4'd0;
    for (ck = 0; ck < 5; ck = ck + 1) begin
      cap_ev[ck]   = 37'd0;
      cap_slot[ck] = cap_wp + ck[CAP_AW-1:0];
    end
    for (ck = 0; ck < 5; ck = ck + 1) begin
      if (cap_src_v[ck]) begin
        cap_ev[cap_nev[2:0]] = cap_src[ck];
        cap_nev = cap_nev + 4'd1;
      end
    end
    cap_ok = (cap_nev > {1'b0, cap_free}) ? {1'b0, cap_free} : cap_nev;
  end

  // Explicit width arithmetic for the capture count (avoids implicit
  // extension warnings and keeps the wrap/saturate intent obvious).
  reg [CAP_CNT_W:0] cap_cnt_next;
  always @* begin
    cap_cnt_next = {1'b0, cap_cnt} + {1'b0, cap_ok[CAP_CNT_W-1:0]}
                   - (cap_pop_eff ? 1'b1 : 1'b0);
  end

  integer ck2;
  always @(posedge clk) begin
    if (!chip_rst_n) begin
      cap_wp   <= {CAP_AW{1'b0}};
      cap_cnt  <= {CAP_CNT_W{1'b0}};
      cap_ovf  <= 1'b0;
      cap_en   <= 8'h00;
      uio_prev <= 8'h00;
      for (ck2 = 0; ck2 < CAP_DEPTH; ck2 = ck2 + 1) cap_mem[ck2] <= 37'd0;
    end else begin
      uio_prev <= uio_in;
      if (cap_ok >= 4'd1) cap_mem[cap_slot[0]] <= cap_ev[0];
      if (cap_ok >= 4'd2) cap_mem[cap_slot[1]] <= cap_ev[1];
      if (cap_ok >= 4'd3) cap_mem[cap_slot[2]] <= cap_ev[2];
      if (cap_ok >= 4'd4) cap_mem[cap_slot[3]] <= cap_ev[3];
      if (cap_ok >= 4'd5) cap_mem[cap_slot[4]] <= cap_ev[4];
      if (cap_nev > cap_ok) cap_ovf <= 1'b1;
      cap_wp  <= cap_wp + cap_ok[CAP_AW-1:0];
      cap_cnt <= cap_cnt_next[CAP_CNT_W-1:0];
      if (wr_cap_en) cap_en <= reg_wdata;
    end
  end

  wire [CAP_AW-1:0] cap_head  = cap_wp - cap_cnt[CAP_AW-1:0];
  // 4-bit view of the count for the host-visible CAP_STATUS field [3:0].
  wire [3:0] cap_cnt4 = cap_cnt;
  wire [36:0] cap_entry = (cap_cnt != 0) ? cap_mem[cap_head] : 37'd0;
  wire [31:0] cap_ts    = cap_entry[36:5];
  wire [3:0]  cap_pin   = cap_entry[4:1];
  wire        cap_lvl   = cap_entry[0];

  // --------------------------------------------------------------- barriers
  reg [3:0] bar_arr0, bar_arr1, bar_arr2, bar_arr3;

  wire [3:0] cur_b0 = {e_bar_req3 & (e_bar_id3 == 2'd0),
                       e_bar_req2 & (e_bar_id2 == 2'd0),
                       e_bar_req1 & (e_bar_id1 == 2'd0),
                       e_bar_req0 & (e_bar_id0 == 2'd0)};
  wire [3:0] cur_b1 = {e_bar_req3 & (e_bar_id3 == 2'd1),
                       e_bar_req2 & (e_bar_id2 == 2'd1),
                       e_bar_req1 & (e_bar_id1 == 2'd1),
                       e_bar_req0 & (e_bar_id0 == 2'd1)};
  wire [3:0] cur_b2 = {e_bar_req3 & (e_bar_id3 == 2'd2),
                       e_bar_req2 & (e_bar_id2 == 2'd2),
                       e_bar_req1 & (e_bar_id1 == 2'd2),
                       e_bar_req0 & (e_bar_id0 == 2'd2)};
  wire [3:0] cur_b3 = {e_bar_req3 & (e_bar_id3 == 2'd3),
                       e_bar_req2 & (e_bar_id2 == 2'd3),
                       e_bar_req1 & (e_bar_id1 == 2'd3),
                       e_bar_req0 & (e_bar_id0 == 2'd3)};

  wire [3:0] arr_b0 = bar_arr0 | cur_b0;
  wire [3:0] arr_b1 = bar_arr1 | cur_b1;
  wire [3:0] arr_b2 = bar_arr2 | cur_b2;
  wire [3:0] arr_b3 = bar_arr3 | cur_b3;

  wire rel_b0 = (arr_b0 != 4'd0) && ((arr_b0 & run_mask) == run_mask);
  wire rel_b1 = (arr_b1 != 4'd0) && ((arr_b1 & run_mask) == run_mask);
  wire rel_b2 = (arr_b2 != 4'd0) && ((arr_b2 & run_mask) == run_mask);
  wire rel_b3 = (arr_b3 != 4'd0) && ((arr_b3 & run_mask) == run_mask);

  always @(posedge clk) begin
    if (!chip_rst_n) begin
      bar_arr0 <= 4'd0; bar_arr1 <= 4'd0; bar_arr2 <= 4'd0; bar_arr3 <= 4'd0;
    end else begin
      bar_arr0 <= rel_b0 ? 4'd0 : arr_b0;
      bar_arr1 <= rel_b1 ? 4'd0 : arr_b1;
      bar_arr2 <= rel_b2 ? 4'd0 : arr_b2;
      bar_arr3 <= rel_b3 ? 4'd0 : arr_b3;
    end
  end

  // bar_go is one bit per engine instance: only a release of *that* engine's
  // barrier completes it, so an unrelated release cannot free a waiting engine.
  wire [3:0] rel_vec = {rel_b3, rel_b2, rel_b1, rel_b0};
  assign bar_go0 = e_bar_req0 && rel_vec[e_bar_id0];
  assign bar_go1 = e_bar_req1 && rel_vec[e_bar_id1];
  assign bar_go2 = e_bar_req2 && rel_vec[e_bar_id2];
  assign bar_go3 = e_bar_req3 && rel_vec[e_bar_id3];

  // -------------------------------------------------------------------- IRQ
  wire [7:0] irq_n0 = (irq     | e_is0) & (~e_ic0);
  wire [7:0] irq_n1 = (irq_n0  | e_is1) & (~e_ic1);
  wire [7:0] irq_n2 = (irq_n1  | e_is2) & (~e_ic2);
  wire [7:0] irq_n3 = (irq_n2  | e_is3) & (~e_ic3);

  always @(posedge clk) begin
    if (!chip_rst_n)     irq <= 8'h00;
    else if (wr_irq_ack) irq <= irq_n3 & (~reg_wdata);
    else                 irq <= irq_n3;
  end

  wire irq_out = |(irq & irq_enable);

  // ------------------------------------------------------------- run / halt
  always @(posedge clk) begin
    if (!chip_rst_n)      run_reg <= 4'd0;
    else if (wr_run)      run_reg <= reg_wdata[3:0];
    else if (wr_halt)     run_reg <= run_reg & (~reg_wdata[3:0]);
    // A HALT instruction clears its own bit in the same cycle the engine
    // halts, matching tools/model.py (halt step: halted=1, run=0).  Host
    // writes above always win over this path.
    else                  run_reg <= run_reg & (~halt_mask);
  end

  always @(posedge clk) begin
    if (!chip_rst_n)    irq_enable <= 8'h00;
    else if (wr_irq_en) irq_enable <= reg_wdata;
  end

  // ------------------------------------------- engine host register decode
  // DECISION (docs/architecture.md sec. 6 window geometry): the documented
  // window carries offsets 0x00..0x15, which cannot fit inside a 0x10-byte
  // stride -- base+0x10 is already the next engine's base, so under the
  // literal stride IN_FIFO/OUT_FIFO/bitpin/side/timeout are unreachable for
  // every engine.  The window is therefore 0x20 bytes:
  //     base = 0x0010 + 0x20*e, region 0x0010..0x008F,
  //     engine = addr[7:5], offset = addr[4:0].
  // Every register of the map is then reachable exactly once.  Reported to
  // the orchestrator because host-side test scripts compute these addresses.
  // Engine window address list for test authors (base = 0x0010 + 0x20*e):
  //   +0x00 R E_STATUS     +0x01 R E_PC        +0x02 R E_FLAGS (reads 0)
  //   +0x03 R E_ERROR      +0x04..+0x0B RW r0..r7
  //   +0x0C..+0x0F RW period bytes 0..3
  //   +0x10 RW IN_FIFO (read 0)   +0x11 R OUT_FIFO (read pops)
  //   +0x12 RW bitpin cfg         +0x13 RW side-set cfg
  //   +0x14 RW timeout cfg        +0x15 reserved (0)
  //   e.g. eng0 r0 = 0x0014, eng1 r0 = 0x0034, eng3 IN_FIFO = 0x0080.
  wire        win_sel  = (reg_addr >= `PROTEUS_EW_BASE) &&
                         (reg_addr <= `PROTEUS_EW_END);
  // 7 bits are enough: the window region is 0x0010..0x008F, so the modular
  // 7-bit difference is the exact 0..0x7F offset.
  wire [6:0]  win_rel  = reg_addr[6:0] - 7'h10;
  wire [4:0]  win_off  = win_rel[4:0];
  wire [1:0]  win_e2   = win_rel[6:5];
  wire        win_wr   = reg_we && win_sel;
  wire        win_in   = (win_off == `PROTEUS_EO_IN_FIFO);
  wire        win_out  = (win_off == `PROTEUS_EO_OUT_FIFO);
  // Writable register window: +0x4..+0x14 except the FIFO ports +0x10/+0x11.
  wire        hr_hit   = win_wr && (win_off >= `PROTEUS_EO_R0) &&
                         (win_off <= `PROTEUS_EO_TIMEOUT) && (~win_in) && (~win_out);

  assign hr_we   = hr_hit ? (4'd1 << win_e2) : 4'd0;
  assign in_push = (win_wr && win_in) ? (4'd1 << win_e2) : 4'd0;

  wire [6:0]  rd_rel  = reg_raddr[6:0] - 7'h10;
  wire        rd_win  = reg_re && (reg_raddr >= `PROTEUS_EW_BASE) &&
                        (reg_raddr <= `PROTEUS_EW_END);
  wire        rd_outf = rd_win && (rd_rel[4:0] == `PROTEUS_EO_OUT_FIFO);
  assign out_pop = rd_outf ? (4'd1 << rd_rel[6:5]) : 4'd0;

  // window offset -> engine hr address:
  //   0x0 status(15) | 0x4..0xF -> 0..11 | 0x12 bitpin(12) | 0x13 side(13)
  //   0x14 timeout(14)
  wire [4:0] off_r = rd_rel[4:0];
  wire [4:0] off_w = win_rel[4:0];
  wire [3:0] hr_addr_r = (off_r == `PROTEUS_EO_STATUS)                  ? 4'hF :
                         ((off_r >= `PROTEUS_EO_R0) && (off_r <= 5'h0F)) ? (off_r[3:0] - 4'h4) :
                         (off_r == `PROTEUS_EO_BITPIN)                   ? 4'hC :
                         (off_r == `PROTEUS_EO_SIDECFG)                  ? 4'hD :
                         (off_r == `PROTEUS_EO_TIMEOUT)                  ? 4'hE : 4'h0;
  wire [3:0] hr_addr_w = ((off_w >= `PROTEUS_EO_R0) && (off_w <= 5'h0F)) ? (off_w[3:0] - 4'h4) :
                         (off_w == `PROTEUS_EO_BITPIN)                   ? 4'hC :
                         (off_w == `PROTEUS_EO_SIDECFG)                  ? 4'hD :
                         (off_w == `PROTEUS_EO_TIMEOUT)                  ? 4'hE : 4'h0;
  // Address must stay valid for the cycle *after* the one-clk request pulse,
  // because proteus_host samples reg_rdata one clk after reg_re.
  assign hr_addr = reg_we ? hr_addr_w : hr_addr_r;

  // --------------------------------------------------------- program memory
  wire        pm_sel   = reg_we && (reg_addr >= `PROTEUS_PM_BASE) &&
                         (reg_addr <= `PROTEUS_PM_END);
  wire [1:0]  pm_eng   = reg_addr[9:8] - 2'd1;   // 0x0100+e*0x100 -> e
  wire [5:0]  pm_idx   = reg_addr[7:2];
  wire [1:0]  pm_byte  = reg_addr[1:0];
  wire [3:0]  pm_lane  = {2'b00, pm_eng} * 4'd3 + {2'b00, pm_byte};
  wire        pm_ok    = pm_sel && ({1'b0, pm_idx} < PDEPTH) && (pm_byte != 2'd3);

  assign hp_we    = pm_ok ? (4'd1 << pm_eng) : 4'd0;
  assign hp_be    = pm_ok ? (12'd1 << pm_lane) : 12'd0;
  assign hp_addr  = reg_we ? pm_idx : reg_raddr[7:2];
  assign hp_wdata = {3{reg_wdata}};

  wire [1:0]  rd_eng = reg_raddr[9:8] - 2'd1;    // 0x0100+e*0x100 -> e
  wire [23:0] prd_e  = (rd_eng == 2'd0) ? e_hprd0 :
                       (rd_eng == 2'd1) ? e_hprd1 :
                       (rd_eng == 2'd2) ? e_hprd2 : e_hprd3;
  reg  [7:0] prd_byte;
  always @* begin
    case (reg_raddr[1:0])
      2'd0:    prd_byte = prd_e[7:0];
      2'd1:    prd_byte = prd_e[15:8];
      default: prd_byte = prd_e[23:16];
    endcase
  end

  // -------------------------------------------------------------- read mux
  wire [1:0] rde     = rd_rel[6:5];
  wire [7:0] eng_hr  = (rde == 2'd0) ? e_hr0 :
                       (rde == 2'd1) ? e_hr1 :
                       (rde == 2'd2) ? e_hr2 : e_hr3;
  wire [7:0] eng_out = (rde == 2'd0) ? e_out0 :
                       (rde == 2'd1) ? e_out1 :
                       (rde == 2'd2) ? e_out2 : e_out3;
  wire [5:0] eng_pc  = (rde == 2'd0) ? e_pc0 :
                       (rde == 2'd1) ? e_pc1 :
                       (rde == 2'd2) ? e_pc2 : e_pc3;
  wire       eng_err = (rde == 2'd0) ? e_err0 :
                       (rde == 2'd1) ? e_err1 :
                       (rde == 2'd2) ? e_err2 : e_err3;

  wire any_run = |(run_reg & (~halted_mask) & ready_mask);
  wire any_err = |err_mask;
  wire irq_any = |irq;
  wire [7:0] status_byte = {3'b000, any_err, coll_any, cap_ovf, irq_any, any_run};

  always @* begin
    reg_rdata = 8'h00;
    if ((reg_raddr >= `PROTEUS_PM_BASE) && (reg_raddr <= `PROTEUS_PM_END)) begin
      if ({1'b0, reg_raddr[7:2]} < PDEPTH) reg_rdata = prd_byte;
      else                         reg_rdata = 8'h00;
    end else if (reg_raddr[15:8] == 8'h00) begin
      if (reg_raddr[7:4] == 4'h0) begin
        case (reg_raddr[3:0])
          4'h0:    reg_rdata = `PROTEUS_ID0;
          4'h1:    reg_rdata = `PROTEUS_ID1;
          4'h2:    reg_rdata = `PROTEUS_VERSION;
          4'h3:    reg_rdata = status_byte;
          4'h4:    reg_rdata = {4'b0000, run_reg};
          4'h7:    reg_rdata = {7'b0000000, host_en};
          4'h8:    reg_rdata = irq;
          4'h9:    reg_rdata = irq_enable;
          4'hB:    reg_rdata = cycle[7:0];
          4'hC:    reg_rdata = cycle[15:8];
          4'hD:    reg_rdata = cycle[23:16];
          4'hE:    reg_rdata = cycle[31:24];
          default: reg_rdata = 8'h00;
        endcase
      end else if ((reg_raddr >= `PROTEUS_EW_BASE) &&
                   (reg_raddr <= `PROTEUS_EW_END)) begin
        case (rd_rel[4:0])
          5'h00:   reg_rdata = eng_hr;                // E_STATUS (hr 15)
          5'h01:   reg_rdata = {2'b00, eng_pc};       // E_PC
          5'h02:   reg_rdata = 8'h00;                 // E_FLAGS: no interface
          5'h03:   reg_rdata = {7'b0000000, eng_err}; // E_ERROR
          5'h04, 5'h05, 5'h06, 5'h07, 5'h08, 5'h09, 5'h0A, 5'h0B,
          5'h0C, 5'h0D, 5'h0E, 5'h0F, 5'h12, 5'h13, 5'h14: reg_rdata = eng_hr;
          5'h11:   reg_rdata = eng_out;               // OUT_FIFO head (pops)
          default: reg_rdata = 8'h00;                 // +0x10 reads 0, +0x15 res
        endcase
      end
    end else if ((reg_raddr >= 16'h0500) && (reg_raddr <= 16'h0530)) begin
      case (reg_raddr[5:0])
        6'h00:   reg_rdata = cap_en;
        // [7:5] reserved, [4] overflow, [3:0] count (cap_cnt4 zero-extends the
        // CAP_CNT_W-bit counter so the field position is depth-independent).
        6'h01:   reg_rdata = {3'b000, cap_ovf, cap_cnt4};
        6'h02:   reg_rdata = cap_ts[7:0];
        6'h03:   reg_rdata = cap_ts[15:8];
        6'h04:   reg_rdata = cap_ts[23:16];
        6'h05:   reg_rdata = cap_ts[31:24];
        6'h06:   reg_rdata = {3'b000, cap_lvl, cap_pin};
        6'h10:   reg_rdata = collision_q;
        6'h20:   reg_rdata = uo_q;
        6'h21:   reg_rdata = uio_q;
        6'h22:   reg_rdata = oe_q;
        6'h23:   reg_rdata = od_q;
        6'h30:   reg_rdata = assert_info;
        default: reg_rdata = 8'h00;
      endcase
    end
  end

  // ------------------------------------------------------------------- pins
  assign uo_out  = {uo_q[7:2],
                    host_en ? irq_out : uo_q[1],
                    host_en ? miso    : uo_q[0]};
  assign uio_out = uio_q;
  assign uio_oe  = oe_q & (~(od_q & uio_q));

  // All unused inputs consumed for lint cleanliness.
  wire _unused = &{ena, 1'b0};

endmodule

`default_nettype wire
