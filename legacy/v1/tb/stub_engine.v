// ===========================================================================
// tb/stub_engine.v -- TESTBENCH-ONLY stand-in for proteus_engine.
//
// Purpose: let tt_um_proteus be compiled and its host register map exercised
// before the real engine exists.  It is NOT the engine implementation and MUST
// NOT be compiled into the design (it lives in tb/ for that reason).
//
// Port list and parameter names are the frozen proteus_engine interface
// (docs/architecture.md sec. 7 + orchestrator interface ruling):
//   * program memory: word writes qualified by a 3-bit byte enable,
//     combinational read port host_prog_rdata
//   * host register port: 0..7 regs, 8..11 period bytes, 12 bitpin,
//     13 side-set, 14 timeout, 15 status (read-only)
//   * prog_ready asserted permanently (no HALT fill in the stub)
//
// Stub-specific convenience: a byte written to IN_FIFO is also pushed into the
// OUT_FIFO, so the top's push/pop paths can be exercised deterministically.
// ===========================================================================

`default_nettype none

// The stub keeps the real module name (it stands in for the engine) but lives
// in tb/, so the file name deliberately differs.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
module proteus_engine #(
  parameter PROG_DEPTH = 32,
  parameter ENG_ID     = 0,
  parameter FIFO_DEPTH = 4
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        run,

  input  wire        host_prog_we,
  input  wire [5:0]  host_prog_addr,
  input  wire [23:0] host_prog_data,
  input  wire [2:0]  host_prog_be,
  output wire [23:0] host_prog_rdata,

  input  wire [7:0]  pin_ui,
  input  wire [7:0]  pin_uo,
  input  wire [7:0]  pin_uio,

  output wire [7:0]  wo_data,
  output wire [7:0]  wo_mask,
  output wire [7:0]  uo_data,
  output wire [7:0]  uo_mask,
  output wire [7:0]  oe_data,
  output wire [7:0]  oe_mask,
  output wire [7:0]  od_data,
  output wire [7:0]  od_mask,

  input  wire [31:0] cycle,
  input  wire [7:0]  irq,
  output wire [7:0]  irq_set,
  output wire [7:0]  irq_clr,

  input  wire [3:0]  run_mask,
  input  wire        bar_go,
  output wire        bar_req,
  output wire [1:0]  bar_id,

  output wire        cap_req,
  output wire [4:0]  cap_tag,

  input  wire        hr_we,
  input  wire [3:0]  hr_addr,
  input  wire [7:0]  hr_wdata,
  output wire [7:0]  hr_rdata,

  input  wire        host_in_push,
  input  wire [7:0]  host_in_data,
  input  wire        host_out_pop,
  output wire [7:0]  host_out_data,

  output wire        halted,
  output wire        error,
  output wire [5:0]  dbg_pc,
  output wire        prog_ready,
  output wire        halt_exec
);

  // The stub is written for PROG_DEPTH = 32 (5-bit program address).
  localparam       PDEPTH  = PROG_DEPTH;   // array bound
  localparam [5:0] PDEPTH6 = PROG_DEPTH;   // 6-bit compare value (32 fits)
  localparam integer STUB_AW = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
  localparam integer STUB_CW = $clog2(FIFO_DEPTH + 1);
  localparam [STUB_CW-1:0] STUB_FULL = FIFO_DEPTH;
  wire [4:0] paddr = host_prog_addr[4:0];

  // ------------------------------------------------------------ program RAM
  reg [23:0] prog [0:PDEPTH-1];

  assign host_prog_rdata = (host_prog_addr < PDEPTH6) ? prog[paddr] : 24'h000000;

  // ------------------------------------------------------- host register file
  reg [7:0] regs    [0:7];
  reg [7:0] period  [0:3];
  reg [7:0] bitpin_cfg;
  reg [7:0] side_cfg;
  reg [7:0] timeout_cfg;

  // ------------------------------------------------------------- FIFOs (stub)
  // inbound FIFO contents are not read by the stub (engine side is absent),
  // only its occupancy matters for the status byte.
  reg [7:0] out_fifo [0:FIFO_DEPTH-1];
  reg [STUB_CW-1:0] in_cnt, out_cnt;
  reg [STUB_AW-1:0] out_wp, out_rp;

  reg        halted_i;
  reg        error_i;
  reg [5:0]  pc_i;

  wire [7:0] status_byte = {timeout_cfg[7],    // placeholder, unused bit
                            1'b0,               // nf
                            (out_cnt == STUB_FULL),
                            (out_cnt == 0),
                            (in_cnt  == STUB_FULL),
                            (in_cnt  == 0),
                            halted_i,
                            run};

  assign hr_rdata = (hr_addr <= 4'h7) ? regs[hr_addr[2:0]] :
                    (hr_addr <= 4'hB) ? period[hr_addr[1:0]] :
                    (hr_addr == 4'hC) ? bitpin_cfg :
                    (hr_addr == 4'hD) ? side_cfg :
                    (hr_addr == 4'hE) ? timeout_cfg :
                    (hr_addr == 4'hF) ? status_byte : 8'h00;

  // ---------------------------------------------------------- stub behaviour
  assign halted     = halted_i;
  assign error      = error_i;
  assign dbg_pc     = pc_i;
  assign prog_ready = 1'b1;
  // The stub never executes, so it never retires a RUN bit by HALT.
  assign halt_exec  = 1'b0;

  assign irq_set   = 8'h00;
  assign irq_clr   = 8'h00;
  assign bar_req   = 1'b0;
  assign bar_id    = 2'd0;
  assign cap_req   = 1'b0;
  assign cap_tag   = 5'd0;
  assign host_out_data = (out_cnt != 0) ? out_fifo[out_rp] : 8'h00;

  // Unused inputs consumed for lint cleanliness.
  wire _unused = &{pin_ui, pin_uo, pin_uio, irq, run_mask, bar_go, cycle, 1'b0};

  integer k;
  always @(posedge clk) begin
    if (!rst_n) begin
      halted_i    <= 1'b1;
      error_i     <= 1'b0;
      pc_i        <= 6'd0;
      bitpin_cfg  <= 8'h00;
      side_cfg    <= 8'h00;
      timeout_cfg <= 8'h00;
      in_cnt      <= {STUB_CW{1'b0}};
      out_cnt     <= {STUB_CW{1'b0}};
      out_wp      <= {STUB_AW{1'b0}};
      out_rp      <= {STUB_AW{1'b0}};
      for (k = 0; k < 8; k = k + 1) regs[k] <= 8'h00;
      for (k = 0; k < FIFO_DEPTH; k = k + 1) out_fifo[k] <= 8'h00;
      for (k = 0; k < 4; k = k + 1) period[k] <= 8'h00;
      for (k = 0; k < PDEPTH; k = k + 1) prog[k] <= 24'h000000;
    end else begin
      // ---- program memory: per-byte-lane write ----
      if (host_prog_we && (host_prog_addr < PDEPTH6)) begin
        if (host_prog_be[0]) prog[paddr][7:0]   <= host_prog_data[7:0];
        if (host_prog_be[1]) prog[paddr][15:8]  <= host_prog_data[15:8];
        if (host_prog_be[2]) prog[paddr][23:16] <= host_prog_data[23:16];
      end

      // ---- host register writes (0..14; 15 is read-only status) ----
      if (hr_we) begin
        if (hr_addr <= 4'h7)      regs[hr_addr[2:0]]      <= hr_wdata;
        else if (hr_addr <= 4'hB) period[hr_addr[1:0]]    <= hr_wdata;
        else if (hr_addr == 4'hC) bitpin_cfg              <= hr_wdata;
        else if (hr_addr == 4'hD) side_cfg                <= hr_wdata;
        else if (hr_addr == 4'hE) timeout_cfg             <= hr_wdata;
      end

      // ---- FIFOs ----
      if (host_in_push) begin
        if (in_cnt != STUB_FULL) in_cnt <= in_cnt + 1'b1;
        // stub convenience: mirror into the out FIFO as well
        if (out_cnt != STUB_FULL) begin
          out_fifo[out_wp] <= host_in_data;
          out_wp           <= out_wp + 1'b1;
          out_cnt          <= out_cnt + 1'b1;
        end
      end
      if (host_out_pop && (out_cnt != 0)) begin
        out_rp  <= out_rp + 1'b1;
        out_cnt <= out_cnt - 1'b1;
      end

      // ---- trivial state machine so E_PC/STATUS move ----
      halted_i <= ~run;
      if (run) pc_i <= pc_i + 6'd1;
    end
  end

  // Pin write buses are permanently idle in the stub.
  assign wo_data = 8'h00;  assign wo_mask = 8'h00;
  assign uo_data = 8'h00;  assign uo_mask = 8'h00;
  assign oe_data = 8'h00;  assign oe_mask = 8'h00;
  assign od_data = 8'h00;  assign od_mask = 8'h00;

endmodule

`default_nettype wire
