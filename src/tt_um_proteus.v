// ===========================================================================
// tt_um_proteus.v -- PROTEUS hybrid v2 top level (Tiny Tapeout, IHP
// sg13cmos5l 6x4): THREE programmable protocol engines plus five protocol-
// agnostic assists behind one CSR interface.
//
// Derived from the shipped 4-engine v1 top (src/tt_um_proteus.v, untouched).
// Architecture and area case: docs/hybrid-architecture.md (verdict B', 3
// engines + bit-serial CRC = 506,883.22 um2 / 56.17 % of the row).  What
// changed against v1, exhaustively:
//
//  1. THREE engines (0..2).  Engine window is still 0x0010 + 0x20*e, now
//     ending at 0x006F; program window is 0x0100 + 0x100*e, ending at 0x02FF.
//     Program byte lanes are 3 per engine (9 total, was 12).  run/halt/ready/
//     error masks, barrier arrivals, the IRQ OR chain, the assert record and
//     the capture push ports are all 3 bits wide (capture keeps its fourth
//     push port: the external uio edge, unchanged).
//  2. NEW: proteus_assist at 0x0600 + 0x10*id + reg (5 assists x 8 registers,
//     plus the host-only PINCFG register at +8 of each stride).
//  3. NEW: engine assist port.  LDAS/STAS/ASST (0x4E/0x4F/0x50) drive one
//     arbitrated write/command port into the assist bank; read data is
//     returned per engine, combinationally, so LDAS retires in one cycle.
//     Arbitration: highest engine index wins a write/command collision, the
//     same rule the pin merge uses.
//  4. NEW: one extra pin-merge stage per bank for the assists, priority above
//     all engines and below the host (docs 5.4).  Assists are push-pull, so
//     the stage also clears open-drain for the pins it owns.
//  5. VERSION reads 0x02 to identify the hybrid build.
//
// Everything else -- the host SPI slave, soft reset, timebase, capture FIFO,
// collision detection, pin registers, host register map -- is the v1 logic
// unchanged, and the v1 numbered decisions below still hold.
//
// Decisions / deviations -- read before editing:
//
//  1. PROG_DEPTH is a top parameter (default 32, area ruling).  Program window
//     is 0x0100 + e*0x100 + i*4 + b for i < PROG_DEPTH, b < 3, e < 3.  Writes
//     with i >= PROG_DEPTH are dropped; reads there return 0.  Writes use the
//     engine's byte-enable port (host_prog_be) so every host byte write lands
//     in exactly one byte lane -- no shadow RAM and no write combining.
//
//  2. Pins presented to the engines: ui_in[2:0] (SCK/CS_N/MOSI) and
//     uo_out[1:0] (IRQ/MISO) read as 0 while host_en=1, because the host owns
//     them.  After HOST_DISABLE they are ordinary fabric pins.  uio_in is
//     presented raw, exactly as tools/model.py pin_state() does.
//
//  3. Capture and collision sample the raw uio_in (no synchroniser) so capture
//     timestamps stay cycle-exact with tools/model.py.
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
//     0x0511); STATUS[3] is its reduction.
//
//  7. Engine-window geometry: the map's offsets run 0x00..0x15, which do not
//     fit the 0x10 stride the map also states, so the window is 0x20 bytes:
//     base = 0x0010 + 0x20*e, region 0x0010..0x006F, engine = (addr-0x0010)
//     [6:5], offset = (addr-0x0010)[4:0].  A comment block at the decode lists
//     every offset for test authors.
//
//  8. Barrier handshake: the top releases a barrier in the cycle the last
//     running engine arrives (model.py semantics) and drives bar_go only to
//     engines waiting on the barrier that released.  proteus_engine's bar_req
//     must therefore not depend on bar_go (combinational loop).
//
//  9. Engines take a separate reset net from the top's own registers (async
//     port, sync release), kept structurally distinct to avoid a mixed
//     async/sync reset (Verilator SYNCASYNCNET).
//
// 10. Assist pin writes are push-pull and win over engine writes on an owned
//     pin; the host's pin-register writes still win over everything because
//     they are applied in the same clocked block, last.  Assist receive pins
//     are sampled from the raw pads, never from the merged output.
// ===========================================================================

`default_nettype none

module tt_um_proteus #(
  parameter PROG_DEPTH = 32,
  // Edge-timestamp capture FIFO entries (default 4: measured area lever).
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

  // 7 bits: PROG_DEPTH=64 must not truncate to 0.
  localparam [6:0] PDEPTH = PROG_DEPTH;

  // Capture FIFO geometry: pointer wraps modulo CAP_DEPTH, the count needs one
  // extra bit so it can represent CAP_DEPTH itself (full).
  localparam integer CAP_AW    = (CAP_DEPTH > 1) ? $clog2(CAP_DEPTH) : 1;
  localparam integer CAP_CNT_W = $clog2(CAP_DEPTH + 1);

  // Push ports: 3 engines + the external uio edge (unchanged role).
  localparam integer CAP_PUSH  = 4;
  localparam integer CAP_IX    = $clog2(CAP_PUSH);

  // ------------------------------------------------------------------ reset
  // Asynchronous assert, synchronous release.
  reg [1:0] rst_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_sync <= 2'b00;
    else        rst_sync <= {rst_sync[0], 1'b1};
  end
  wire rst_n_s = rst_sync[1];

  // Soft reset: stretch the one-clk pulse into a four-clk synchronous reset
  // window for the whole chip.
  reg [2:0] soft_rst_cnt;
  wire      host_soft_reset;
  always @(posedge clk) begin
    if (!rst_n_s)                  soft_rst_cnt <= 3'd0;
    else if (host_soft_reset)      soft_rst_cnt <= 3'd4;
    else if (soft_rst_cnt != 3'd0) soft_rst_cnt <= soft_rst_cnt - 3'd1;
  end
  wire chip_rst_n = rst_n_s & (soft_rst_cnt == 3'd0);

  reg eng_rst_rel;
  always @(posedge clk) begin
    if (!rst_n_s) eng_rst_rel <= 1'b0;
    else          eng_rst_rel <= (soft_rst_cnt == 3'd0);
  end
  wire eng_rst_n = rst_n_s & eng_rst_rel;
  // The assist bank is synchronous-reset like the top's own registers: none of
  // the measured assist blocks has an asynchronous reset port.
  wire as_rst_n = chip_rst_n;

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
  wire [2:0]  hp_we;                    // one per engine
  wire [8:0]  hp_be;                    // 3 byte enables per engine

  wire [23:0] e_hprd [0:2];
  wire [7:0]  e_wo_d [0:2];
  wire [7:0]  e_wo_m [0:2];
  wire [7:0]  e_uo_d [0:2];
  wire [7:0]  e_uo_m [0:2];
  wire [7:0]  e_oe_d [0:2];
  wire [7:0]  e_oe_m [0:2];
  wire [7:0]  e_od_d [0:2];
  wire [7:0]  e_od_m [0:2];
  wire [7:0]  e_is   [0:2];             // irq set pulses
  wire [7:0]  e_ic   [0:2];             // irq clear pulses
  wire        e_bar_req [0:2];
  wire [1:0]  e_bar_id  [0:2];
  wire        e_cap_req [0:2];
  wire [4:0]  e_cap_tag [0:2];
  wire [7:0]  e_hr     [0:2];
  wire [7:0]  e_out    [0:2];
  wire        e_halt   [0:2];
  wire        e_err    [0:2];
  wire        e_rdy    [0:2];
  wire [5:0]  e_pc     [0:2];
  wire        e_hx     [0:2];           // HALT executing this cycle
  // assist port
  wire        e_as_rd    [0:2];
  wire        e_as_wr    [0:2];
  wire [2:0]  e_as_id    [0:2];
  wire [2:0]  e_as_reg   [0:2];
  wire [7:0]  e_as_wdata [0:2];
  wire        e_as_cmd_en[0:2];
  wire [2:0]  e_as_cmd_id[0:2];
  wire [7:0]  e_as_cmd   [0:2];
  wire [7:0]  e_as_rdata [0:2];
  wire        e_as_empty [0:2];

  wire [2:0]  halted_mask = {e_halt[2], e_halt[1], e_halt[0]};
  wire [2:0]  halt_mask   = {e_hx[2],   e_hx[1],   e_hx[0]};
  wire [2:0]  ready_mask  = {e_rdy[2],  e_rdy[1],  e_rdy[0]};
  wire [2:0]  err_mask    = {e_err[2],  e_err[1],  e_err[0]};
  reg  [2:0]  run_reg;
  wire [2:0]  run_mask    = run_reg & (~halted_mask) & ready_mask;

  reg  [7:0]  irq;
  reg  [7:0]  irq_enable;

  wire [2:0]  hr_we;
  wire [3:0]  hr_addr;
  wire [2:0]  in_push;
  wire [2:0]  out_pop;
  wire        bar_go0, bar_go1, bar_go2;

  // -------------------------------------------------------------- engines
  proteus_engine #(.PROG_DEPTH(PROG_DEPTH), .ENG_ID(0)) u_eng0 (
    .clk(clk), .rst_n(eng_rst_n), .run(run_reg[0]),
    .host_prog_we(hp_we[0]), .host_prog_addr(hp_addr), .host_prog_data(hp_wdata),
    .host_prog_be(hp_be[2:0]), .host_prog_rdata(e_hprd[0]),
    .pin_ui(fab_ui), .pin_uo(fab_uo), .pin_uio(uio_in),
    .wo_data(e_wo_d[0]), .wo_mask(e_wo_m[0]),
    .uo_data(e_uo_d[0]), .uo_mask(e_uo_m[0]),
    .oe_data(e_oe_d[0]), .oe_mask(e_oe_m[0]),
    .od_data(e_od_d[0]), .od_mask(e_od_m[0]),
    .cycle(cycle), .irq(irq),
    .irq_set(e_is[0]), .irq_clr(e_ic[0]),
    .run_mask({1'b0, run_mask}), .bar_go(bar_go0),
    .bar_req(e_bar_req[0]), .bar_id(e_bar_id[0]),
    .cap_req(e_cap_req[0]), .cap_tag(e_cap_tag[0]),
    .hr_we(hr_we[0]), .hr_addr(hr_addr), .hr_wdata(reg_wdata),
    .hr_rdata(e_hr[0]),
    .host_in_push(in_push[0]), .host_in_data(reg_wdata),
    .host_out_pop(out_pop[0]), .host_out_data(e_out[0]),
    .halted(e_halt[0]), .error(e_err[0]), .dbg_pc(e_pc[0]),
    .prog_ready(e_rdy[0]), .halt_exec(e_hx[0]),
    .as_rd(e_as_rd[0]), .as_wr(e_as_wr[0]), .as_id(e_as_id[0]),
    .as_reg(e_as_reg[0]), .as_wdata(e_as_wdata[0]),
    .as_cmd_en(e_as_cmd_en[0]), .as_cmd_id(e_as_cmd_id[0]),
    .as_cmd(e_as_cmd[0]),
    .as_rdata(e_as_rdata[0]), .as_empty(e_as_empty[0])
  );

  proteus_engine #(.PROG_DEPTH(PROG_DEPTH), .ENG_ID(1)) u_eng1 (
    .clk(clk), .rst_n(eng_rst_n), .run(run_reg[1]),
    .host_prog_we(hp_we[1]), .host_prog_addr(hp_addr), .host_prog_data(hp_wdata),
    .host_prog_be(hp_be[5:3]), .host_prog_rdata(e_hprd[1]),
    .pin_ui(fab_ui), .pin_uo(fab_uo), .pin_uio(uio_in),
    .wo_data(e_wo_d[1]), .wo_mask(e_wo_m[1]),
    .uo_data(e_uo_d[1]), .uo_mask(e_uo_m[1]),
    .oe_data(e_oe_d[1]), .oe_mask(e_oe_m[1]),
    .od_data(e_od_d[1]), .od_mask(e_od_m[1]),
    .cycle(cycle), .irq(irq),
    .irq_set(e_is[1]), .irq_clr(e_ic[1]),
    .run_mask({1'b0, run_mask}), .bar_go(bar_go1),
    .bar_req(e_bar_req[1]), .bar_id(e_bar_id[1]),
    .cap_req(e_cap_req[1]), .cap_tag(e_cap_tag[1]),
    .hr_we(hr_we[1]), .hr_addr(hr_addr), .hr_wdata(reg_wdata),
    .hr_rdata(e_hr[1]),
    .host_in_push(in_push[1]), .host_in_data(reg_wdata),
    .host_out_pop(out_pop[1]), .host_out_data(e_out[1]),
    .halted(e_halt[1]), .error(e_err[1]), .dbg_pc(e_pc[1]),
    .prog_ready(e_rdy[1]), .halt_exec(e_hx[1]),
    .as_rd(e_as_rd[1]), .as_wr(e_as_wr[1]), .as_id(e_as_id[1]),
    .as_reg(e_as_reg[1]), .as_wdata(e_as_wdata[1]),
    .as_cmd_en(e_as_cmd_en[1]), .as_cmd_id(e_as_cmd_id[1]),
    .as_cmd(e_as_cmd[1]),
    .as_rdata(e_as_rdata[1]), .as_empty(e_as_empty[1])
  );

  proteus_engine #(.PROG_DEPTH(PROG_DEPTH), .ENG_ID(2)) u_eng2 (
    .clk(clk), .rst_n(eng_rst_n), .run(run_reg[2]),
    .host_prog_we(hp_we[2]), .host_prog_addr(hp_addr), .host_prog_data(hp_wdata),
    .host_prog_be(hp_be[8:6]), .host_prog_rdata(e_hprd[2]),
    .pin_ui(fab_ui), .pin_uo(fab_uo), .pin_uio(uio_in),
    .wo_data(e_wo_d[2]), .wo_mask(e_wo_m[2]),
    .uo_data(e_uo_d[2]), .uo_mask(e_uo_m[2]),
    .oe_data(e_oe_d[2]), .oe_mask(e_oe_m[2]),
    .od_data(e_od_d[2]), .od_mask(e_od_m[2]),
    .cycle(cycle), .irq(irq),
    .irq_set(e_is[2]), .irq_clr(e_ic[2]),
    .run_mask({1'b0, run_mask}), .bar_go(bar_go2),
    .bar_req(e_bar_req[2]), .bar_id(e_bar_id[2]),
    .cap_req(e_cap_req[2]), .cap_tag(e_cap_tag[2]),
    .hr_we(hr_we[2]), .hr_addr(hr_addr), .hr_wdata(reg_wdata),
    .hr_rdata(e_hr[2]),
    .host_in_push(in_push[2]), .host_in_data(reg_wdata),
    .host_out_pop(out_pop[2]), .host_out_data(e_out[2]),
    .halted(e_halt[2]), .error(e_err[2]), .dbg_pc(e_pc[2]),
    .prog_ready(e_rdy[2]), .halt_exec(e_hx[2]),
    .as_rd(e_as_rd[2]), .as_wr(e_as_wr[2]), .as_id(e_as_id[2]),
    .as_reg(e_as_reg[2]), .as_wdata(e_as_wdata[2]),
    .as_cmd_en(e_as_cmd_en[2]), .as_cmd_id(e_as_cmd_id[2]),
    .as_cmd(e_as_cmd[2]),
    .as_rdata(e_as_rdata[2]), .as_empty(e_as_empty[2])
  );

  // ------------------------------------------------------ assist CSR window
  wire       as_wsel = reg_we && (reg_addr  >= `PROTEUS_AS_BASE) &&
                                  (reg_addr  <= `PROTEUS_AS_END);
  wire       as_rsel = reg_re && (reg_raddr >= `PROTEUS_AS_BASE) &&
                                  (reg_raddr <= `PROTEUS_AS_END);
  wire [6:0] as_woff = reg_addr[6:0];
  wire [6:0] as_roff = reg_raddr[6:0];
  wire [7:0] as_h_rdata;

  // Engine assist port arbitration: highest engine index wins a collision,
  // matching the pin-merge rule.  Reads are per engine and never arbitrate.
  wire       as_wr_eff  = e_as_wr[2] | e_as_wr[1] | e_as_wr[0];
  wire [2:0] as_wid_eff = e_as_wr[2] ? e_as_id[2] :
                          e_as_wr[1] ? e_as_id[1] : e_as_id[0];
  wire [2:0] as_wreg_eff = e_as_wr[2] ? e_as_reg[2] :
                           e_as_wr[1] ? e_as_reg[1] : e_as_reg[0];
  wire [7:0] as_wdata_eff = e_as_wr[2] ? e_as_wdata[2] :
                            e_as_wr[1] ? e_as_wdata[1] : e_as_wdata[0];

  wire       as_cmd_eff   = e_as_cmd_en[2] | e_as_cmd_en[1] | e_as_cmd_en[0];
  wire [2:0] as_cid_eff   = e_as_cmd_en[2] ? e_as_cmd_id[2] :
                            e_as_cmd_en[1] ? e_as_cmd_id[1] : e_as_cmd_id[0];
  wire [7:0] as_ccmd_eff  = e_as_cmd_en[2] ? e_as_cmd[2] :
                            e_as_cmd_en[1] ? e_as_cmd[1] : e_as_cmd[0];

  wire [7:0] as_uo_d, as_uo_m, as_uio_d, as_uio_m, as_oe_d, as_oe_m, as_od_m;

  proteus_assist u_assist (
    .clk       (clk),
    .rst_n     (as_rst_n),
    .h_we      (as_wsel),
    .h_addr    (as_woff),
    .h_wdata   (reg_wdata),
    .h_re      (as_rsel),
    .h_raddr   (as_roff),
    .h_rdata   (as_h_rdata),
    .e_rden    ({e_as_rd[2], e_as_rd[1], e_as_rd[0]}),
    .e_rid0    (e_as_id[0]), .e_rreg0(e_as_reg[0]),
    .e_rid1    (e_as_id[1]), .e_rreg1(e_as_reg[1]),
    .e_rid2    (e_as_id[2]), .e_rreg2(e_as_reg[2]),
    .e_rdata   ({e_as_rdata[2], e_as_rdata[1], e_as_rdata[0]}),
    .e_rempty  ({e_as_empty[2], e_as_empty[1], e_as_empty[0]}),
    .e_wr      (as_wr_eff),
    .e_wid     (as_wid_eff),
    .e_wreg    (as_wreg_eff),
    .e_wdata   (as_wdata_eff),
    .e_cmd     (as_cmd_eff),
    .e_cid     (as_cid_eff),
    .e_ccmd    (as_ccmd_eff),
    .pin_ui    (ui_in),
    .pin_uio   (uio_in),
    .ap_uo_d   (as_uo_d),
    .ap_uo_m   (as_uo_m),
    .ap_uio_d  (as_uio_d),
    .ap_uio_m  (as_uio_m),
    .ap_oe_d   (as_oe_d),
    .ap_oe_m   (as_oe_m),
    .ap_od_m   (as_od_m)
  );

  // ------------------------------------------------------- pin fabric merge
  wire [23:0] uo_d_all = {e_uo_d[2], e_uo_d[1], e_uo_d[0]};
  wire [23:0] uo_m_all = {e_uo_m[2], e_uo_m[1], e_uo_m[0]};
  wire [23:0] wo_d_all = {e_wo_d[2], e_wo_d[1], e_wo_d[0]};
  wire [23:0] wo_m_all = {e_wo_m[2], e_wo_m[1], e_wo_m[0]};
  wire [23:0] oe_d_all = {e_oe_d[2], e_oe_d[1], e_oe_d[0]};
  wire [23:0] oe_m_all = {e_oe_m[2], e_oe_m[1], e_oe_m[0]};
  wire [23:0] od_d_all = {e_od_d[2], e_od_d[1], e_od_d[0]};
  wire [23:0] od_m_all = {e_od_m[2], e_od_m[1], e_od_m[0]};

  reg [7:0] m_uo, m_uio, m_oe, m_od;
  integer   mi;
  always @* begin
    m_uo  = uo_q;
    m_uio = uio_q;
    m_oe  = oe_q;
    m_od  = od_q;
    for (mi = 0; mi < 3; mi = mi + 1) begin
      m_uo  = (m_uo  & ~uo_m_all[mi*8 +: 8]) | (uo_d_all[mi*8 +: 8] & uo_m_all[mi*8 +: 8]);
      m_uio = (m_uio & ~wo_m_all[mi*8 +: 8]) | (wo_d_all[mi*8 +: 8] & wo_m_all[mi*8 +: 8]);
      m_oe  = (m_oe  & ~oe_m_all[mi*8 +: 8]) | (oe_d_all[mi*8 +: 8] & oe_m_all[mi*8 +: 8]);
      m_od  = (m_od  & ~od_m_all[mi*8 +: 8]) | (od_d_all[mi*8 +: 8] & od_m_all[mi*8 +: 8]);
    end
    // One extra stage per bank for the assists: above every engine, below the
    // host (the host's writes below are applied last in the clocked block).
    m_uo  = (m_uo  & ~as_uo_m)  | (as_uo_d  & as_uo_m);
    m_uio = (m_uio & ~as_uio_m) | (as_uio_d & as_uio_m);
    m_oe  = (m_oe  & ~as_oe_m)  | (as_oe_d  & as_oe_m);
    m_od  = m_od & ~as_od_m;      // assist-driven pins are push-pull
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
      // Host pin-register writes win over engine and assist traffic.
      uo_q  <= wr_uo  ? reg_wdata :
               (host_en ? {m_uo[7:2], uo_q[1:0]} : m_uo);
      uio_q <= wr_uio ? reg_wdata : m_uio;
      oe_q  <= wr_oe  ? reg_wdata : m_oe;
      od_q  <= wr_od  ? reg_wdata : m_od;
    end
  end

  // ---------------------------------------------------- collision detection
  wire [7:0] od_low    = oe_q & od_q & (~uio_q);
  wire [7:0] pp_driven = oe_q & (~od_q);
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
  reg       err_q0, err_q1, err_q2;
  always @(posedge clk) begin
    if (!chip_rst_n) begin
      err_q0 <= 1'b0; err_q1 <= 1'b0; err_q2 <= 1'b0;
      assert_info <= 8'h00;
    end else begin
      err_q0 <= e_err[0]; err_q1 <= e_err[1]; err_q2 <= e_err[2];
      if      (e_err[0] & (~err_q0)) assert_info <= {2'b00, 2'd0, e_pc[0][3:0]};
      else if (e_err[1] & (~err_q1)) assert_info <= {2'b00, 2'd1, e_pc[1][3:0]};
      else if (e_err[2] & (~err_q2)) assert_info <= {2'b00, 2'd2, e_pc[2][3:0]};
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

  // Push arbitration: engines 0..2 software events, then the external edge --
  // the order tools/model.py appends them within one cycle.
  reg [36:0] cap_src  [0:CAP_PUSH-1];
  reg [36:0] cap_ev   [0:CAP_PUSH-1];
  reg [CAP_AW-1:0] cap_slot [0:CAP_PUSH-1];
  reg [3:0]  cap_nev;
  reg [3:0]  cap_ok;
  integer    ck;

  wire [CAP_PUSH-1:0] cap_src_v = {cap_edge, e_cap_req[2], e_cap_req[1],
                                   e_cap_req[0]};
  wire       cap_pop_eff = cap_pop && (cap_cnt != 0);
  wire [CAP_CNT_W-1:0] cap_free =
      CAP_DEPTH - cap_cnt + {{(CAP_CNT_W-1){1'b0}}, cap_pop_eff};

  always @* begin
    cap_src[0] = {cycle, e_cap_tag[0][3:0], e_cap_tag[0][4]};
    cap_src[1] = {cycle, e_cap_tag[1][3:0], e_cap_tag[1][4]};
    cap_src[2] = {cycle, e_cap_tag[2][3:0], e_cap_tag[2][4]};
    cap_src[3] = {cycle, cap_edge_pin, cap_edge_lvl};
    cap_nev  = 4'd0;
    for (ck = 0; ck < CAP_PUSH; ck = ck + 1) begin
      cap_ev[ck]   = 37'd0;
      cap_slot[ck] = cap_wp + ck[CAP_AW-1:0];
    end
    for (ck = 0; ck < CAP_PUSH; ck = ck + 1) begin
      if (cap_src_v[ck]) begin
        cap_ev[cap_nev[CAP_IX-1:0]] = cap_src[ck];
        cap_nev = cap_nev + 4'd1;
      end
    end
    cap_ok = (cap_nev > {1'b0, cap_free}) ? {1'b0, cap_free} : cap_nev;
  end

  // Explicit width arithmetic for the capture count.  cap_ok is clamped to the
  // free space, so the sum can never exceed CAP_DEPTH and the natural count
  // width is enough; the widths are stated to keep the arithmetic free of
  // implicit extension.
  reg [CAP_CNT_W-1:0] cap_cnt_next;
  always @* begin
    cap_cnt_next = cap_cnt + cap_ok[CAP_CNT_W-1:0]
                   - {{(CAP_CNT_W-1){1'b0}}, cap_pop_eff};
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
      if (cap_nev > cap_ok) cap_ovf <= 1'b1;
      cap_wp  <= cap_wp + cap_ok[CAP_AW-1:0];
      cap_cnt <= cap_cnt_next;
      if (wr_cap_en) cap_en <= reg_wdata;
    end
  end

  wire [CAP_AW-1:0] cap_head  = cap_wp - cap_cnt[CAP_AW-1:0];
  wire [3:0] cap_cnt4 = {{(4-CAP_CNT_W){1'b0}}, cap_cnt};
  wire [36:0] cap_entry = (cap_cnt != 0) ? cap_mem[cap_head] : 37'd0;
  wire [31:0] cap_ts    = cap_entry[36:5];
  wire [3:0]  cap_pin   = cap_entry[4:1];
  wire        cap_lvl   = cap_entry[0];

  // --------------------------------------------------------------- barriers
  reg [2:0] bar_arr0, bar_arr1, bar_arr2, bar_arr3;

  wire [2:0] cur_b0 = {e_bar_req[2] & (e_bar_id[2] == 2'd0),
                       e_bar_req[1] & (e_bar_id[1] == 2'd0),
                       e_bar_req[0] & (e_bar_id[0] == 2'd0)};
  wire [2:0] cur_b1 = {e_bar_req[2] & (e_bar_id[2] == 2'd1),
                       e_bar_req[1] & (e_bar_id[1] == 2'd1),
                       e_bar_req[0] & (e_bar_id[0] == 2'd1)};
  wire [2:0] cur_b2 = {e_bar_req[2] & (e_bar_id[2] == 2'd2),
                       e_bar_req[1] & (e_bar_id[1] == 2'd2),
                       e_bar_req[0] & (e_bar_id[0] == 2'd2)};
  wire [2:0] cur_b3 = {e_bar_req[2] & (e_bar_id[2] == 2'd3),
                       e_bar_req[1] & (e_bar_id[1] == 2'd3),
                       e_bar_req[0] & (e_bar_id[0] == 2'd3)};

  wire [2:0] arr_b0 = bar_arr0 | cur_b0;
  wire [2:0] arr_b1 = bar_arr1 | cur_b1;
  wire [2:0] arr_b2 = bar_arr2 | cur_b2;
  wire [2:0] arr_b3 = bar_arr3 | cur_b3;

  wire rel_b0 = (arr_b0 != 3'd0) && ((arr_b0 & run_mask) == run_mask);
  wire rel_b1 = (arr_b1 != 3'd0) && ((arr_b1 & run_mask) == run_mask);
  wire rel_b2 = (arr_b2 != 3'd0) && ((arr_b2 & run_mask) == run_mask);
  wire rel_b3 = (arr_b3 != 3'd0) && ((arr_b3 & run_mask) == run_mask);

  always @(posedge clk) begin
    if (!chip_rst_n) begin
      bar_arr0 <= 3'd0; bar_arr1 <= 3'd0; bar_arr2 <= 3'd0; bar_arr3 <= 3'd0;
    end else begin
      bar_arr0 <= rel_b0 ? 3'd0 : arr_b0;
      bar_arr1 <= rel_b1 ? 3'd0 : arr_b1;
      bar_arr2 <= rel_b2 ? 3'd0 : arr_b2;
      bar_arr3 <= rel_b3 ? 3'd0 : arr_b3;
    end
  end

  wire [3:0] rel_vec = {rel_b3, rel_b2, rel_b1, rel_b0};
  assign bar_go0 = e_bar_req[0] && rel_vec[e_bar_id[0]];
  assign bar_go1 = e_bar_req[1] && rel_vec[e_bar_id[1]];
  assign bar_go2 = e_bar_req[2] && rel_vec[e_bar_id[2]];

  // -------------------------------------------------------------------- IRQ
  wire [7:0] irq_n0 = (irq     | e_is[0]) & (~e_ic[0]);
  wire [7:0] irq_n1 = (irq_n0  | e_is[1]) & (~e_ic[1]);
  wire [7:0] irq_n2 = (irq_n1  | e_is[2]) & (~e_ic[2]);

  always @(posedge clk) begin
    if (!chip_rst_n)     irq <= 8'h00;
    else if (wr_irq_ack) irq <= irq_n2 & (~reg_wdata);
    else                 irq <= irq_n2;
  end

  wire irq_out = |(irq & irq_enable);

  // ------------------------------------------------------------- run / halt
  always @(posedge clk) begin
    if (!chip_rst_n)      run_reg <= 3'd0;
    else if (wr_run)      run_reg <= reg_wdata[2:0];
    else if (wr_halt)     run_reg <= run_reg & (~reg_wdata[2:0]);
    // A HALT instruction retires its own RUN bit in the same cycle the engine
    // halts.  Host writes above always win over this path.
    else                  run_reg <= run_reg & (~halt_mask);
  end

  always @(posedge clk) begin
    if (!chip_rst_n)    irq_enable <= 8'h00;
    else if (wr_irq_en) irq_enable <= reg_wdata;
  end

  // ------------------------------------------- engine host register decode
  // Window: base = 0x0010 + 0x20*e, region 0x0010..0x006F,
  //         engine = addr[6:5], offset = addr[4:0].
  // Engine window address list for test authors (base = 0x0010 + 0x20*e):
  //   +0x00 R E_STATUS     +0x01 R E_PC        +0x02 R E_FLAGS (reads 0)
  //   +0x03 R E_ERROR      +0x04..+0x0B RW r0..r7
  //   +0x0C..+0x0F RW period bytes 0..3
  //   +0x10 RW IN_FIFO (read 0)   +0x11 R OUT_FIFO (read pops)
  //   +0x12 RW bitpin cfg         +0x13 RW side-set cfg
  //   +0x14 RW timeout cfg        +0x15 reserved (0)
  //   e.g. eng0 r0 = 0x0014, eng1 r0 = 0x0034, eng2 IN_FIFO = 0x0060.
  wire        win_sel  = (reg_addr >= `PROTEUS_EW_BASE) &&
                         (reg_addr <= `PROTEUS_EW_END);
  wire [6:0]  win_rel  = reg_addr[6:0] - 7'h10;
  wire [4:0]  win_off  = win_rel[4:0];
  wire [1:0]  win_e2   = win_rel[6:5];
  wire        win_wr   = reg_we && win_sel;
  wire        win_in   = (win_off == `PROTEUS_EO_IN_FIFO);
  wire        win_out  = (win_off == `PROTEUS_EO_OUT_FIFO);
  wire        hr_hit   = win_wr && (win_off >= `PROTEUS_EO_R0) &&
                         (win_off <= `PROTEUS_EO_TIMEOUT) && (~win_in) && (~win_out);

  assign hr_we   = hr_hit ? (3'd1 << win_e2) : 3'd0;
  assign in_push = (win_wr && win_in) ? (3'd1 << win_e2) : 3'd0;

  wire [6:0]  rd_rel  = reg_raddr[6:0] - 7'h10;
  wire        rd_win  = reg_re && (reg_raddr >= `PROTEUS_EW_BASE) &&
                        (reg_raddr <= `PROTEUS_EW_END);
  wire        rd_outf = rd_win && (rd_rel[4:0] == `PROTEUS_EO_OUT_FIFO);
  assign out_pop = rd_outf ? (3'd1 << rd_rel[6:5]) : 3'd0;

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
  assign hr_addr = reg_we ? hr_addr_w : hr_addr_r;

  // --------------------------------------------------------- program memory
  wire        pm_sel   = reg_we && (reg_addr >= `PROTEUS_PM_BASE) &&
                         (reg_addr <= `PROTEUS_PM_END);
  wire [1:0]  pm_eng   = reg_addr[9:8] - 2'd1;   // 0x0100+e*0x100 -> e
  wire [5:0]  pm_idx   = reg_addr[7:2];
  wire [1:0]  pm_byte  = reg_addr[1:0];
  wire [3:0]  pm_lane  = {2'b00, pm_eng} * 4'd3 + {2'b00, pm_byte};
  wire        pm_ok    = pm_sel && ({1'b0, pm_idx} < PDEPTH) && (pm_byte != 2'd3);

  assign hp_we    = pm_ok ? (3'd1 << pm_eng) : 3'd0;
  assign hp_be    = pm_ok ? (9'd1 << pm_lane) : 9'd0;
  assign hp_addr  = reg_we ? pm_idx : reg_raddr[7:2];
  assign hp_wdata = {3{reg_wdata}};

  wire [1:0]  rd_eng = reg_raddr[9:8] - 2'd1;    // 0x0100+e*0x100 -> e
  wire [23:0] prd_e  = (rd_eng == 2'd0) ? e_hprd[0] :
                       (rd_eng == 2'd1) ? e_hprd[1] : e_hprd[2];
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
  wire [7:0] eng_hr  = (rde == 2'd0) ? e_hr[0] :
                       (rde == 2'd1) ? e_hr[1] : e_hr[2];
  wire [7:0] eng_out = (rde == 2'd0) ? e_out[0] :
                       (rde == 2'd1) ? e_out[1] : e_out[2];
  wire [5:0] eng_pc  = (rde == 2'd0) ? e_pc[0] :
                       (rde == 2'd1) ? e_pc[1] : e_pc[2];
  wire       eng_err = (rde == 2'd0) ? e_err[0] :
                       (rde == 2'd1) ? e_err[1] : e_err[2];

  wire any_run = |(run_reg & (~halted_mask) & ready_mask);
  wire any_err = |err_mask;
  wire irq_any = |irq;
  wire [7:0] status_byte = {3'b000, any_err, coll_any, cap_ovf, irq_any, any_run};

  always @* begin
    reg_rdata = 8'h00;
    if ((reg_raddr >= `PROTEUS_PM_BASE) && (reg_raddr <= `PROTEUS_PM_END)) begin
      if ({1'b0, reg_raddr[7:2]} < PDEPTH) reg_rdata = prd_byte;
      else                                 reg_rdata = 8'h00;
    end else if (reg_raddr[15:8] == 8'h00) begin
      if (reg_raddr[7:4] == 4'h0) begin
        case (reg_raddr[3:0])
          4'h0:    reg_rdata = `PROTEUS_ID0;
          4'h1:    reg_rdata = `PROTEUS_ID1;
          4'h2:    reg_rdata = `PROTEUS_VERSION;
          4'h3:    reg_rdata = status_byte;
          4'h4:    reg_rdata = {5'b00000, run_reg};
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
    end else if ((reg_raddr >= `PROTEUS_AS_BASE) &&
                 (reg_raddr <= `PROTEUS_AS_END)) begin
      reg_rdata = as_h_rdata;                        // assist CSR bank
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
