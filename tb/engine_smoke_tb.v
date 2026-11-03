// -----------------------------------------------------------------------------
// v2/tb/engine_smoke_tb.v -- self-checking smoke test for v2/src/proteus_engine.v
//
// Port of tb/engine_smoke_tb.v (v1, untouched).  The only RTL difference is the
// assist CSR port added for the hybrid build (LDAS/STAS/ASST): every original
// check is kept verbatim, the new inputs are tied to valid idle defaults
// (as_rdata = 0, as_empty = 0) so the engine sees an always-ready assist, and
// the four new checks in test_assist_port drive those inputs directly.
//
// Covers the sprint-1 acceptance list:
//   (a) reset readiness: prog_ready / halted
//   (b) LDI/ADDI/ADD/SUB/shift/flags
//   (c) SETP/CLRP/TOGP/OUTP buses, auto-OE, DIRS/DIRC, ODSET/ODCLR
//   (d) side-set on NOP and on a stalled WAITP
//   (e) WAITC exact cycle counts for n=0,1,5
//   (f) PACE: period 16.0 -> exactly 16 cycles; period 100.5 -> mean 100.5, +-1
//   (g) JMP/DJNZ loop iteration counts
//   (h) PULL blocks on empty, completes when host_in_push arrives
//   (i) BAR stalls until bar_go, and completes immediately when alone
// Plus CAPTURE pulse and out-FIFO readback.
//
// Encoding mirrors tools/isa.py after the orchestrator's 7-bit layout ruling:
//   op[23:17] rd[16:14] rs[13:11] imm[10:3] ss[2:0]
//
// Testbench conventions:
//   * clk period 10 ns; `tick` waits for a posedge and samples 1 ns later.
//   * cycle_q free-runs, incremented on the falling edge so the DUT sees a
//     stable value at every posedge.
//   * Engine pin-write buses are combinational: after a tick they reflect the
//     instruction now at dbg_pc (the one that executes on the next tick).
//   * A failing check increments `errors`; the run ends with $fatal so vvp
//     exits non-zero.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module engine_smoke_tb;

  // ---------------- opcode constants (mirror tools/isa.py) ------------------
  localparam [6:0] OP_LDI     = 7'h00, OP_ADDI  = 7'h01, OP_SUBI  = 7'h02,
                   OP_ANDI    = 7'h03, OP_ORI   = 7'h04, OP_XORI  = 7'h05,
                   OP_CMPI    = 7'h06, OP_SHLI  = 7'h07, OP_SHRI  = 7'h08,
                   OP_ASRI    = 7'h09, OP_ROLI  = 7'h0A, OP_RORI  = 7'h0B,
                   OP_ADCI    = 7'h0C, OP_SBCI  = 7'h0D, OP_MOVI  = 7'h0E;
  localparam [6:0] OP_MOV     = 7'h10, OP_ADD   = 7'h11, OP_SUB   = 7'h12,
                   OP_AND     = 7'h13, OP_OR    = 7'h14, OP_XOR   = 7'h15,
                   OP_CMP     = 7'h16, OP_SHL   = 7'h17, OP_SHR   = 7'h18,
                   OP_ASR     = 7'h19, OP_ROL   = 7'h1A, OP_ROR   = 7'h1B,
                   OP_NOT     = 7'h1C, OP_NEG   = 7'h1D, OP_INC   = 7'h1E,
                   OP_DEC     = 7'h1F, OP_ADC   = 7'h20, OP_SBC   = 7'h21;
  localparam [6:0] OP_SETP    = 7'h22, OP_CLRP  = 7'h23, OP_TOGP  = 7'h24,
                   OP_OUTP    = 7'h25, OP_INPR  = 7'h26, OP_DIRS  = 7'h27,
                   OP_DIRC    = 7'h28, OP_ODSET = 7'h29, OP_ODCLR = 7'h2A,
                   OP_OUTBIT  = 7'h2B, OP_INBIT = 7'h2C, OP_WAITP = 7'h2D;
  localparam [6:0] OP_JMP     = 7'h30, OP_JZ    = 7'h31, OP_JNZ   = 7'h32,
                   OP_JC      = 7'h33, OP_JNC   = 7'h34, OP_JN    = 7'h35,
                   OP_DJNZ    = 7'h36, OP_HALT  = 7'h38, OP_NOP   = 7'h39,
                   OP_WAITC   = 7'h3A, OP_PACE  = 7'h3B, OP_PACERST=7'h3C,
                   OP_ASSERT  = 7'h3E;
  localparam [6:0] OP_PUSH    = 7'h40, OP_PULL  = 7'h41, OP_PUSHN = 7'h42,
                   OP_PULLN   = 7'h43, OP_IRQSET= 7'h44, OP_IRQCLR= 7'h45,
                   OP_IRQWAIT = 7'h46, OP_BAR   = 7'h47, OP_TSLO  = 7'h48,
                   OP_TSHI    = 7'h49, OP_MEASLO= 7'h4A, OP_MEASHI= 7'h4B,
                   OP_CAPTURE = 7'h4C, OP_CFG   = 7'h4D;
  // hybrid v2 assist CSR access (mirror v2/tools/isa.py)
  localparam [6:0] OP_LDAS    = 7'h4E, OP_STAS  = 7'h4F, OP_ASST = 7'h50;

  localparam integer PROG_N     = 32;
  localparam integer FIFO_DEPTH = 4;   // build parameter under test

  // ---------------- DUT signals --------------------------------------------
  reg         clk, rst_n;
  reg         run;
  reg         host_prog_we;
  reg  [2:0]  host_prog_be;
  reg  [5:0]  host_prog_addr;
  reg  [23:0] host_prog_data;
  wire [23:0] host_prog_rdata;
  reg  [7:0]  pin_ui, pin_uo, pin_uio;
  wire [7:0]  wo_data, wo_mask, uo_data, uo_mask;
  wire [7:0]  oe_data, oe_mask, od_data, od_mask;
  reg  [31:0] cycle_q;
  reg  [7:0]  irq;
  wire [7:0]  irq_set, irq_clr;
  reg  [3:0]  run_mask;
  reg         bar_go;
  wire        bar_req;
  wire [1:0]  bar_id;
  wire        cap_req;
  wire [4:0]  cap_tag;
  reg         hr_we;
  reg  [3:0]  hr_addr;
  reg  [7:0]  hr_wdata;
  wire [7:0]  hr_rdata;
  reg         host_in_push;
  reg  [7:0]  host_in_data;
  reg         host_out_pop;
  wire [7:0]  host_out_data;
  // assist CSR port (v2).  Inputs driven by the bench: as_rdata is the value an
  // assist would return for the current (as_id, as_reg), as_empty is its
  // data-path-empty flag.  Both idle at valid defaults.
  wire        as_rd, as_wr;
  wire [2:0]  as_id, as_reg;
  wire [7:0]  as_wdata;
  wire        as_cmd_en;
  wire [2:0]  as_cmd_id;
  wire [7:0]  as_cmd;
  reg  [7:0]  as_rdata;
  reg         as_empty;
  wire        halted, error;

  wire [5:0]  dbg_pc;
  wire        prog_ready;

  proteus_engine #(
    .PROG_DEPTH(PROG_N),
    .ENG_ID(0),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) dut (
    .clk(clk), .rst_n(rst_n), .run(run),
    .host_prog_we(host_prog_we), .host_prog_be(host_prog_be),
    .host_prog_addr(host_prog_addr), .host_prog_data(host_prog_data),
    .host_prog_rdata(host_prog_rdata),
    .pin_ui(pin_ui), .pin_uo(pin_uo), .pin_uio(pin_uio),
    .wo_data(wo_data), .wo_mask(wo_mask),
    .uo_data(uo_data), .uo_mask(uo_mask),
    .oe_data(oe_data), .oe_mask(oe_mask),
    .od_data(od_data), .od_mask(od_mask),
    .cycle(cycle_q), .irq(irq), .irq_set(irq_set), .irq_clr(irq_clr),
    .run_mask(run_mask), .bar_go(bar_go), .bar_req(bar_req), .bar_id(bar_id),
    .cap_req(cap_req), .cap_tag(cap_tag),
    .hr_we(hr_we), .hr_addr(hr_addr), .hr_wdata(hr_wdata), .hr_rdata(hr_rdata),
    .host_in_push(host_in_push), .host_in_data(host_in_data),
    .host_out_pop(host_out_pop), .host_out_data(host_out_data),
    .as_rd(as_rd), .as_wr(as_wr), .as_id(as_id), .as_reg(as_reg),
    .as_wdata(as_wdata), .as_cmd_en(as_cmd_en), .as_cmd_id(as_cmd_id),
    .as_cmd(as_cmd), .as_rdata(as_rdata), .as_empty(as_empty),
    .halted(halted), .error(error), .dbg_pc(dbg_pc), .prog_ready(prog_ready)
  );

  // ---------------- clock / cycle counter -----------------------------------
  always #5 clk = ~clk;

  always @(negedge clk)
    cycle_q <= cycle_q + 32'd1;

  // ---------------- program store / helpers --------------------------------
  reg [23:0] prog [0:PROG_N-1];
  reg [7:0]  rdv;                 // result of hread
  integer    errors;
  integer    nchecks;            // checks executed (reported, not asserted)
  integer    i, k, t;
  integer    comp_tick [0:31];

  function [23:0] enc;
    input [6:0] op;
    input [2:0] rd;
    input [2:0] rs;
    input [7:0] imm;
    input [2:0] ss;
    begin
      enc = {op, rd, rs, imm, ss};
    end
  endfunction

  // Run one clock; sample 1 ns after the active edge.
  task tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask

  // Advance clocks until the engine's PC reaches `target` (bounded, so a
  // mutant that never gets there fails the following check instead of hanging).
  // Sampling with this makes a flag check independent of the exact cycle at
  // which a one-cycle instruction retires: when PC == target, the flag
  // register holds the result of the instruction at target-1.
  task run_to_pc;
    input [5:0] target;
    integer n;
    begin
      n = 0;
      while ((dbg_pc != target) && (n < 40)) begin
        tick;
        n = n + 1;
      end
    end
  endtask

  // Combinational host-register read.
  task hread;
    input [3:0] a;
    begin
      hr_addr = a;
      #1;
      rdv = hr_rdata;
    end
  endtask

  task chk;
    input [511:0] name;
    input [31:0]  got;
    input [31:0]  exp;
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        $display("FAIL %0s: got 0x%0h expected 0x%0h (pc=%0d cycle=%0d)",
                 name, got, exp, dbg_pc, cycle_q);
        errors = errors + 1;
      end
    end
  endtask

  task chkr;
    input [511:0] name;
    input integer got;
    input integer lo;
    input integer hi;
    begin
      nchecks = nchecks + 1;
      if (got < lo || got > hi) begin
        $display("FAIL %0s: got %0d expected %0d..%0d (pc=%0d cycle=%0d)",
                 name, got, lo, hi, dbg_pc, cycle_q);
        errors = errors + 1;
      end
    end
  endtask

  task reset_dut;
    begin
      rst_n          = 1'b0;
      run            = 1'b0;
      host_prog_we   = 1'b0;
      host_prog_be   = 3'b000;
      host_prog_addr = 6'd0;
      host_prog_data = 24'd0;
      pin_ui         = 8'h00;
      pin_uo         = 8'h00;
      pin_uio        = 8'h00;
      irq            = 8'h00;
      run_mask       = 4'b0001;
      bar_go         = 1'b0;
      hr_we          = 1'b0;
      hr_addr        = 4'd0;
      hr_wdata       = 8'h00;
      host_in_push   = 1'b0;
      host_in_data   = 8'h00;
      host_out_pop   = 1'b0;
      as_rdata       = 8'h00;   // assist idle: returns 0, never empty
      as_empty       = 1'b0;
      tick;
      tick;
      rst_n = 1'b1;
    end
  endtask

  // Load the first `n` words of `prog` through the byte-lane host port, then
  // wait for the reset HALT fill to report ready.
  task load_words;
    input integer n;
    integer j;
    begin
      for (j = 0; j < n; j = j + 1) begin
        host_prog_addr = j;
        host_prog_data = prog[j];
        host_prog_be   = 3'b111;
        host_prog_we   = 1'b1;
        tick;
      end
      host_prog_we = 1'b0;
      host_prog_be = 3'b000;
      // Bounded wait: a reset fill that never completes (a wrong fill-counter
      // step, say) must fail here instead of hanging the whole bench.  The
      // fill takes PROG_N clocks, so 4*PROG_N is a generous ceiling.
      j = 0;
      while (!prog_ready && j < 4*PROG_N) begin
        tick;
        j = j + 1;
      end
      if (!prog_ready) begin
        $display("FAIL load_words: prog_ready never asserted after %0d ticks",
                 4*PROG_N);
        errors = errors + 1;
      end
    end
  endtask

  // Rising edge of run: clears halted and sets PC=0 without executing.
  task start_run;
    begin
      run = 1'b1;
      tick;
    end
  endtask

  // ---------------------------------------------------------------------------
  // (a) reset readiness
  // ---------------------------------------------------------------------------
  task test_reset;
    integer n;
    begin
      $display("[a] reset readiness / prog_ready fill");
      reset_dut;

      chk("a_prog_ready_low_after_reset", {31'd0, prog_ready}, 32'd0);
      chk("a_halted_after_reset",        {31'd0, halted},     32'd1);

      // 32-entry fill: entries 0..30 during the first 31 clocks, ready on 32.
      for (n = 1; n <= 31; n = n + 1) begin
        tick;
        chk("a_prog_ready_during_fill", {31'd0, prog_ready}, 32'd0);
      end
      tick;
      chk("a_prog_ready_after_fill", {31'd0, prog_ready}, 32'd1);
      chk("a_halted_no_run",         {31'd0, halted},     32'd1);

      // unwritten entries must read as HALT (0x38 opcode)
      host_prog_addr = 6'd0;
      #1;
      chk("a_fetched_word0_is_halt", {8'd0, host_prog_rdata}, 32'h700000);
      host_prog_addr = 6'd31;
      #1;
      chk("a_fetched_word31_is_halt", {8'd0, host_prog_rdata}, 32'h700000);

      // addresses beyond PROG_DEPTH read 0
      host_prog_addr = 6'd32;
      #1;
      chk("a_fetched_oob_is_zero", {8'd0, host_prog_rdata}, 32'd0);

      // byte-lane write: only byte 1 of word 5 changes (opcode byte stays HALT)
      host_prog_addr = 6'd5;
      host_prog_data = 24'h00AB00;
      host_prog_be   = 3'b010;
      host_prog_we   = 1'b1;
      tick;
      host_prog_we   = 1'b0;
      host_prog_be   = 3'b000;
      #1;
      chk("a_byte_lane_write", {8'd0, host_prog_rdata}, 32'h70AB00);

      start_run;
      chk("a_halted_cleared", {31'd0, halted}, 32'd0);
      chk("a_pc_zero",        {26'd0, dbg_pc}, 32'd0);

      // exec_act is gated by prog_ready: a host that asserts RUN before the
      // reset fill has finished must not execute anything (the entries it
      // would fetch are still being written, and the host is about to
      // overwrite them).  A separate reset is used because clearing `halted`
      // through run is permanent until the next reset.
      //
      // The sensitive signal is `halted`: the fill has already put HALT in
      // word 0, so an ungated engine retires that HALT, freezes PC at 0 and
      // reports halted=1.  PC alone cannot see it.
      reset_dut;
      run = 1'b1;
      repeat (8) tick;
      chk("a_run_before_fill_pc",     {26'd0, dbg_pc},     32'd0);
      chk("a_run_before_fill_ready",  {31'd0, prog_ready}, 32'd0);
      chk("a_run_before_fill_no_exec",{31'd0, halted},     32'd0);
      run = 1'b0;
      tick;
    end
  endtask

  // ---------------------------------------------------------------------------
  // (b) ALU + flags
  // ---------------------------------------------------------------------------
  task test_alu;
    begin
      $display("[b] ALU immediate/register/shift/flags");
      reset_dut;

      prog[0]  = enc(OP_LDI,  3'd0, 3'd0, 8'h10, 3'd0);
      prog[1]  = enc(OP_ADDI, 3'd0, 3'd0, 8'h05, 3'd0);
      prog[2]  = enc(OP_LDI,  3'd1, 3'd0, 8'h03, 3'd0);
      prog[3]  = enc(OP_ADD,  3'd0, 3'd1, 8'h00, 3'd0);
      prog[4]  = enc(OP_SUB,  3'd0, 3'd1, 8'h00, 3'd0);
      prog[5]  = enc(OP_LDI,  3'd2, 3'd0, 8'hFF, 3'd0);
      prog[6]  = enc(OP_ADDI, 3'd2, 3'd0, 8'h01, 3'd0);
      prog[7]  = enc(OP_LDI,  3'd3, 3'd0, 8'h80, 3'd0);
      prog[8]  = enc(OP_SHRI, 3'd3, 3'd0, 8'h01, 3'd0);
      prog[9]  = enc(OP_ROLI, 3'd3, 3'd0, 8'h04, 3'd0);
      prog[10] = enc(OP_ASRI, 3'd3, 3'd0, 8'h01, 3'd0);
      prog[11] = enc(OP_NOT,  3'd3, 3'd0, 8'h00, 3'd0);
      prog[12] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);

      load_words(13);
      start_run;

      repeat (13) tick;   // 12 one-cycle instructions + HALT

      hread(4'd0); chk("b_r0", {24'd0, rdv}, 32'h15);
      hread(4'd1); chk("b_r1", {24'd0, rdv}, 32'h03);
      hread(4'd2); chk("b_r2_ff_plus_1", {24'd0, rdv}, 32'h00);
      hread(4'd3); chk("b_r3_not", {24'd0, rdv}, 32'hFD);

      // white-box flag check (no host-visible flag byte in the 0..15 window)
      chk("b_flag_z", {31'd0, dut.z_r}, 32'd0);
      chk("b_flag_c", {31'd0, dut.c_r}, 32'd0);
      chk("b_flag_n", {31'd0, dut.n_r}, 32'd1);
      chk("b_halted", {31'd0, halted},  32'd1);

      // MOV / INC / DEC / CMP quick pass in the same run: reload a short program
      reset_dut;
      prog[0] = enc(OP_LDI, 3'd4, 3'd0, 8'hFE, 3'd0);
      prog[1] = enc(OP_INC, 3'd4, 3'd0, 8'h00, 3'd0);  // 0xFF, C=0, N=1
      prog[2] = enc(OP_DEC, 3'd4, 3'd0, 8'h00, 3'd0);  // 0xFE, C=0
      prog[3] = enc(OP_MOV, 3'd5, 3'd4, 8'h00, 3'd0);  // r5 = 0xFE
      prog[4] = enc(OP_CMPI,3'd5, 3'd0, 8'hFE, 3'd0);  // Z=1, C=0
      prog[5] = enc(OP_HALT,3'd0, 3'd0, 8'h00, 3'd0);
      load_words(6);
      start_run;
      repeat (6) tick;
      hread(4'd4); chk("b_r4_dec", {24'd0, rdv}, 32'hFE);
      hread(4'd5); chk("b_r5_mov", {24'd0, rdv}, 32'hFE);
      chk("b_cmp_z", {31'd0, dut.z_r}, 32'd1);
      chk("b_cmp_c", {31'd0, dut.c_r}, 32'd0);

      // Third program: the ALU paths the first two skip.  ADC/SBC consume the
      // carry (value-visible), ASR must sign-fill, NEG is 0-x, and a count
      // above 1 proves the shift amount is not truncated.
      reset_dut;
      prog[0]  = enc(OP_LDI,  3'd0, 3'd0, 8'hFF, 3'd0);
      prog[1]  = enc(OP_ADDI, 3'd0, 3'd0, 8'h01, 3'd0); // 0x00, C=1
      prog[2]  = enc(OP_ADCI, 3'd0, 3'd0, 8'h00, 3'd0); // 0x01: carry-in used
      prog[3]  = enc(OP_LDI,  3'd1, 3'd0, 8'h00, 3'd0);
      prog[4]  = enc(OP_SUBI, 3'd1, 3'd0, 8'h01, 3'd0); // 0xFF, borrow
      prog[5]  = enc(OP_SBCI, 3'd1, 3'd0, 8'h00, 3'd0); // 0xFE: borrow used
      prog[6]  = enc(OP_LDI,  3'd2, 3'd0, 8'h80, 3'd0);
      prog[7]  = enc(OP_ASRI, 3'd2, 3'd0, 8'h01, 3'd0); // 0xC0: sign filled
      prog[8]  = enc(OP_LDI,  3'd5, 3'd0, 8'h05, 3'd0);
      prog[9]  = enc(OP_NEG,  3'd5, 3'd0, 8'h00, 3'd0); // 0xFB
      prog[10] = enc(OP_LDI,  3'd6, 3'd0, 8'h80, 3'd0);
      prog[11] = enc(OP_SHRI, 3'd6, 3'd0, 8'h07, 3'd0); // 0x01
      prog[12] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
      load_words(13);
      start_run;
      repeat (13) tick;
      hread(4'd0); chk("b_r0_adci_carry_in",  {24'd0, rdv}, 32'h01);
      hread(4'd1); chk("b_r1_sbci_borrow_in", {24'd0, rdv}, 32'hFE);
      hread(4'd2); chk("b_r2_asri_sign_fill", {24'd0, rdv}, 32'hC0);
      hread(4'd5); chk("b_r5_neg",            {24'd0, rdv}, 32'hFB);
      hread(4'd6); chk("b_r6_shift_by_7",     {24'd0, rdv}, 32'h01);

      // Fourth program: the carry out of SHL/ROL/ROR.  These are only visible
      // in C, so each is sampled at the cycle after it retires.
      reset_dut;
      prog[0] = enc(OP_LDI,  3'd7, 3'd0, 8'h80, 3'd0);
      prog[1] = enc(OP_SHLI, 3'd7, 3'd0, 8'h01, 3'd0); // 0x00, C=1 (bit 7 out)
      prog[2] = enc(OP_LDI,  3'd4, 3'd0, 8'h81, 3'd0);
      prog[3] = enc(OP_ROLI, 3'd4, 3'd0, 8'h01, 3'd0); // 0x03, C=r[0]=1
      prog[4] = enc(OP_LDI,  3'd5, 3'd0, 8'h81, 3'd0);
      prog[5] = enc(OP_RORI, 3'd5, 3'd0, 8'h01, 3'd0); // 0xC0, C=r[7]=1
      prog[6] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
      load_words(7);
      start_run;

      run_to_pc(6'd2);
      hread(4'd7); chk("b_r7_shli",  {24'd0, rdv}, 32'h00);
      chk("b_shl_carry", {31'd0, dut.c_r}, 32'd1);

      run_to_pc(6'd4);
      hread(4'd4); chk("b_r4_roli",  {24'd0, rdv}, 32'h03);
      chk("b_rol_carry", {31'd0, dut.c_r}, 32'd1);

      run_to_pc(6'd6);
      hread(4'd5); chk("b_r5_rori",  {24'd0, rdv}, 32'hC0);
      chk("b_ror_carry", {31'd0, dut.c_r}, 32'd1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (b2) conditional branches: the jump condition lives in rd (0 ALWAYS,
  // 1 Z, 2 NZ, 3 C, 4 NC, 5 N, 6 EQ, 7 NE).  Each branch below takes the path
  // that a wrong condition would not, and the marker r6 accumulates 1+2+4 only
  // if all five resolved correctly.
  // ---------------------------------------------------------------------------
  task test_branch;
    begin
      $display("[b2] JZ/JNZ/JC/JNC/JN taken and not taken");
      reset_dut;

      prog[0]  = enc(OP_LDI,  3'd0, 3'd0, 8'h00, 3'd0);
      prog[1]  = enc(OP_CMPI, 3'd0, 3'd0, 8'h00, 3'd0); // Z=1 C=0 N=0
      prog[2]  = enc(OP_JZ,   3'd1, 3'd0, 8'd4,  3'd0); // taken
      prog[3]  = enc(OP_LDI,  3'd6, 3'd0, 8'hEE, 3'd0); // skipped
      prog[4]  = enc(OP_JNZ,  3'd2, 3'd0, 8'd6,  3'd0); // not taken (Z=1)
      prog[5]  = enc(OP_ADDI, 3'd6, 3'd0, 8'h01, 3'd0); // r6 = 1
      prog[6]  = enc(OP_JNC,  3'd4, 3'd0, 8'd8,  3'd0); // taken (C=0)
      prog[7]  = enc(OP_LDI,  3'd6, 3'd0, 8'hEE, 3'd0); // skipped
      prog[8]  = enc(OP_JC,   3'd3, 3'd0, 8'd10, 3'd0); // not taken (C=0)
      prog[9]  = enc(OP_ADDI, 3'd6, 3'd0, 8'h02, 3'd0); // r6 = 3
      prog[10] = enc(OP_LDI,  3'd0, 3'd0, 8'h80, 3'd0); // Z=0 N=1
      prog[11] = enc(OP_CMPI, 3'd0, 3'd0, 8'h00, 3'd0); // Z=0 N=1 C=0
      prog[12] = enc(OP_JN,   3'd5, 3'd0, 8'd14, 3'd0); // taken (N=1)
      prog[13] = enc(OP_LDI,  3'd6, 3'd0, 8'hEE, 3'd0); // skipped
      prog[14] = enc(OP_JZ,   3'd1, 3'd0, 8'd16, 3'd0); // not taken (Z=0)
      prog[15] = enc(OP_ADDI, 3'd6, 3'd0, 8'h04, 3'd0); // r6 = 7
      prog[16] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);

      load_words(17);
      start_run;
      t = 0;
      while (!halted && t < 60) begin
        tick;
        t = t + 1;
      end
      chk("b2_halted", {31'd0, halted}, 32'd1);
      hread(4'd6); chk("b2_conditions", {24'd0, rdv}, 32'h07);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (c) pin operations and auto-OE
  // ---------------------------------------------------------------------------
  task test_pins;
    begin
      $display("[c] SETP/CLRP/TOGP/OUTP/DIRS/DIRC/ODSET/ODCLR");
      reset_dut;

      prog[0]  = enc(OP_LDI,  3'd0, 3'd0, 8'hAA, 3'd0);
      prog[1]  = enc(OP_SETP, 3'd0, 3'd1, 8'h0F, 3'd0); // UO
      prog[2]  = enc(OP_CLRP, 3'd0, 3'd1, 8'h03, 3'd0);
      prog[3]  = enc(OP_TOGP, 3'd0, 3'd1, 8'hFF, 3'd0);
      prog[4]  = enc(OP_OUTP, 3'd0, 3'd1, 8'hF0, 3'd0);
      prog[5]  = enc(OP_SETP, 3'd0, 3'd2, 8'h01, 3'd0); // UIO
      prog[6]  = enc(OP_DIRC, 3'd0, 3'd2, 8'h02, 3'd0);
      prog[7]  = enc(OP_DIRS, 3'd0, 3'd2, 8'h04, 3'd0);
      prog[8]  = enc(OP_ODSET,3'd0, 3'd2, 8'h08, 3'd0);
      prog[9]  = enc(OP_ODCLR,3'd0, 3'd2, 8'h08, 3'd0);
      prog[10] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);

      load_words(11);
      pin_uo = 8'h0F;      // TOGP snapshot
      start_run;

      // pc=0: LDI, no pin activity
      chk("c_ldi_uo_mask", {24'd0, uo_mask}, 32'd0);
      chk("c_ldi_wo_mask", {24'd0, wo_mask}, 32'd0);

      tick; // pc=1 SETP UO 0x0F
      chk("c_setp_uo_mask", {24'd0, uo_mask}, 32'h0F);
      chk("c_setp_uo_data", {24'd0, uo_data}, 32'h0F);
      chk("c_setp_wo_mask", {24'd0, wo_mask}, 32'd0);

      tick; // pc=2 CLRP UO 0x03
      chk("c_clrp_uo_mask", {24'd0, uo_mask}, 32'h03);
      chk("c_clrp_uo_data", {24'd0, uo_data}, 32'd0);

      tick; // pc=3 TOGP UO 0xFF on pin_uo=0x0F
      chk("c_togp_uo_mask", {24'd0, uo_mask}, 32'hFF);
      chk("c_togp_uo_data", {24'd0, uo_data}, 32'hF0);

      tick; // pc=4 OUTP UO 0xF0, r0=0xAA
      chk("c_outp_uo_mask", {24'd0, uo_mask}, 32'hF0);
      chk("c_outp_uo_data", {24'd0, uo_data}, 32'hA0);

      tick; // pc=5 SETP UIO 0x01 -> auto OE
      chk("c_setp_wo_mask",  {24'd0, wo_mask},  32'h01);
      chk("c_setp_wo_data",  {24'd0, wo_data},  32'h01);
      chk("c_setp_oe_mask",  {24'd0, oe_mask},  32'h01);
      chk("c_setp_oe_data",  {24'd0, oe_data},  32'h01);
      chk("c_setp_no_uo",    {24'd0, uo_mask},  32'd0);

      tick; // pc=6 DIRC UIO 0x02
      chk("c_dirc_oe_mask", {24'd0, oe_mask}, 32'h02);
      chk("c_dirc_oe_data", {24'd0, oe_data}, 32'd0);
      chk("c_dirc_no_wo",   {24'd0, wo_mask}, 32'd0);

      tick; // pc=7 DIRS UIO 0x04
      chk("c_dirs_oe_mask", {24'd0, oe_mask}, 32'h04);
      chk("c_dirs_oe_data", {24'd0, oe_data}, 32'h04);

      tick; // pc=8 ODSET UIO 0x08
      chk("c_odset_od_mask", {24'd0, od_mask}, 32'h08);
      chk("c_odset_od_data", {24'd0, od_data}, 32'h08);

      tick; // pc=9 ODCLR UIO 0x08
      chk("c_odclr_od_mask", {24'd0, od_mask}, 32'h08);
      chk("c_odclr_od_data", {24'd0, od_data}, 32'd0);
      chk("c_odclr_no_oe",   {24'd0, oe_mask}, 32'd0);

      tick; // pc=10 HALT
      tick;
      chk("c_halted", {31'd0, halted}, 32'd1);

      // Bit-pin shortcut, invert configured: OUTBIT drives r1[0] ^ invert.
      // CFG BITPIN = bank[7:6]=2 (UIO), bit[5:3]=0, invert[2]=1.
      reset_dut;
      prog[0] = enc(OP_CFG,    3'd0, 3'd1, 8'h84, 3'd0);
      prog[1] = enc(OP_LDI,    3'd1, 3'd0, 8'h01, 3'd0);
      prog[2] = enc(OP_OUTBIT, 3'd1, 3'd0, 8'h00, 3'd0);
      prog[3] = enc(OP_HALT,   3'd0, 3'd0, 8'h00, 3'd0);
      load_words(4);
      start_run;
      run_to_pc(6'd2);
      chk("c_outbit_inv_mask", {24'd0, wo_mask}, 32'h01);
      chk("c_outbit_inv_data", {24'd0, wo_data}, 32'h00);
      chk("c_outbit_inv_oe",   {24'd0, oe_mask}, 32'h01);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (d) side-set on NOP and on a stalled WAITP
  // ---------------------------------------------------------------------------
  task test_side_set;
    begin
      $display("[d] side-set on NOP and stalled WAITP");
      reset_dut;

      prog[0] = enc(OP_CFG, 3'd0, 3'd0, 8'hC1, 3'd0); // SIDE: en, UIO, base0, w2
      prog[1] = enc(OP_NOP, 3'd0, 3'd0, 8'h00, 3'b010);
      prog[2] = enc(OP_WAITP, 3'd0, 3'b100, 8'hFF, 3'b001); // UI, mask FF, lvl1
      prog[3] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);

      load_words(4);
      pin_ui = 8'h00;
      start_run;

      chk("d_cfg_no_ss_yet", {24'd0, wo_mask}, 32'd0);
      tick; // pc=1 NOP ss=2
      chk("d_nop_ss_wo_mask", {24'd0, wo_mask}, 32'h03);
      chk("d_nop_ss_wo_data", {24'd0, wo_data}, 32'h02);
      chk("d_nop_ss_oe_mask", {24'd0, oe_mask}, 32'h03);
      chk("d_nop_ss_oe_data", {24'd0, oe_data}, 32'h03);

      tick; // pc=2 WAITP, does not match -> stalls
      chk("d_waitp_pc_stall", {26'd0, dbg_pc}, 32'd2);
      for (i = 0; i < 3; i = i + 1) begin
        chk("d_waitp_ss_stall_mask", {24'd0, wo_mask}, 32'h03);
        chk("d_waitp_ss_stall_data", {24'd0, wo_data}, 32'h01);
        chk("d_waitp_ss_stall_oe",   {24'd0, oe_mask}, 32'h03);
        tick;
        chk("d_waitp_still_stalled", {26'd0, dbg_pc}, 32'd2);
      end

      pin_ui = 8'hFF;   // match: completes on this next clock
      tick;
      chk("d_waitp_done_pc", {26'd0, dbg_pc}, 32'd3);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (e) WAITC exact cycle counts
  // ---------------------------------------------------------------------------
  task test_waitc;
    input [10:0]  n;
    input integer exp_cycles;
    integer       cnt;
    begin
      reset_dut;
      prog[0] = enc(OP_WAITC, 3'd0, n[10:8], n[7:0], 3'd0);
      prog[1] = enc(OP_HALT,  3'd0, 3'd0, 8'h00, 3'd0);
      load_words(2);
      start_run;

      cnt = 0;
      while (dbg_pc == 6'd0 && cnt < 200) begin
        tick;
        cnt = cnt + 1;
      end
      $display("    WAITC %0d -> %0d cycles (expected %0d)", n, cnt, exp_cycles);
      chk("e_waitc_cycles", cnt, exp_cycles);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (e2) WAITP timeout: timeout_cfg=1 -> issue + 256 stall cycles, then flag
  // ---------------------------------------------------------------------------
  task test_waitp_timeout;
    integer cnt;
    begin
      $display("[e2] WAITP timeout (timeout_cfg=1)");
      reset_dut;

      prog[0] = enc(OP_WAITP, 3'd0, 3'b100, 8'hFF, 3'd0); // UI, level 1
      prog[1] = enc(OP_HALT,  3'd0, 3'd0, 8'h00, 3'd0);
      load_words(2);

      hr_we    = 1'b1;         // host write takes effect next cycle
      hr_addr  = 4'd14;
      hr_wdata = 8'h01;
      tick;
      hr_we    = 1'b0;

      pin_ui = 8'h00;          // never matches
      start_run;

      cnt = 0;
      while (dbg_pc == 6'd0 && cnt < 2000) begin
        tick;
        cnt = cnt + 1;
      end
      $display("    WAITP timeout -> %0d cycles (expected 257)", cnt);
      chk("e2_timeout_cycles", cnt, 257);
      hread(4'd15);
      chk("e2_timeout_flag", {31'd0, rdv[7]}, 32'd1);
      chk("e2_timeout_pc",   {26'd0, dbg_pc}, 32'd1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (f) PACE
  // ---------------------------------------------------------------------------
  task test_pace_16;
    integer comps, pcprev, sum;
    begin
      $display("[f1] PACE period 16.0");
      reset_dut;

      prog[0] = enc(OP_CFG, 3'd0, 3'd2, 8'h00, 3'd0); // PERIOD0
      prog[1] = enc(OP_CFG, 3'd0, 3'd3, 8'h10, 3'd0); // PERIOD1 -> 16.0
      prog[2] = enc(OP_PACERST, 3'd0, 3'd0, 8'h00, 3'd0);
      prog[3] = enc(OP_PACE, 3'd0, 3'd0, 8'h00, 3'd0);
      prog[4] = enc(OP_JMP, 3'd0, 3'd0, 8'd3, 3'd0);

      load_words(5);
      start_run;

      comps  = 0;
      t      = 0;
      while (comps < 10 && t < 2000) begin
        pcprev = dbg_pc;
        tick;
        t = t + 1;
        if (pcprev == 6'd3 && dbg_pc == 6'd4) begin
          comp_tick[comps] = t;
          comps = comps + 1;
        end
      end

      chk("f1_completions", comps, 10);
      for (i = 1; i < 9; i = i + 1) begin
        chk("f1_interval", comp_tick[i+1] - comp_tick[i], 16);
      end
    end
  endtask

  task test_pace_frac;
    integer comps, pcprev, sum, nd;
    begin
      $display("[f2] PACE period 100.5");
      reset_dut;

      prog[0] = enc(OP_CFG, 3'd0, 3'd2, 8'h80, 3'd0); // 0x6480 = 100.5*256
      prog[1] = enc(OP_CFG, 3'd0, 3'd3, 8'h64, 3'd0);
      prog[2] = enc(OP_CFG, 3'd0, 3'd4, 8'h00, 3'd0);
      prog[3] = enc(OP_CFG, 3'd0, 3'd5, 8'h00, 3'd0);
      prog[4] = enc(OP_PACERST, 3'd0, 3'd0, 8'h00, 3'd0);
      prog[5] = enc(OP_PACE, 3'd0, 3'd0, 8'h00, 3'd0);
      prog[6] = enc(OP_JMP, 3'd0, 3'd0, 8'd5, 3'd0);

      load_words(7);
      start_run;

      comps = 0;
      t     = 0;
      while (comps < 22 && t < 6000) begin
        pcprev = dbg_pc;
        tick;
        t = t + 1;
        if (pcprev == 6'd5 && dbg_pc == 6'd6) begin
          comp_tick[comps] = t;
          comps = comps + 1;
        end
      end

      chk("f2_completions", comps, 22);
      sum = 0;
      nd  = 0;
      for (i = 1; i < 21; i = i + 1) begin
        k = comp_tick[i+1] - comp_tick[i];
        chkr("f2_jitter", k, 100, 101);
        sum = sum + k;
        nd  = nd + 1;
      end
      // mean == 100.5  <=>  2*sum == 201*nd
      chkr("f2_mean", 2 * sum - 201 * nd, -1, 1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (g) JMP/DJNZ loop counts
  // ---------------------------------------------------------------------------
  task test_loop;
    begin
      $display("[g] DJNZ loop iteration count");
      reset_dut;

      prog[0] = enc(OP_LDI,  3'd4, 3'd0, 8'h05, 3'd0);
      prog[1] = enc(OP_LDI,  3'd5, 3'd0, 8'h00, 3'd0);
      prog[2] = enc(OP_ADDI, 3'd5, 3'd0, 8'h01, 3'd0);
      prog[3] = enc(OP_DJNZ, 3'd4, 3'd0, 8'd2, 3'd0);
      prog[4] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);

      load_words(5);
      start_run;

      t = 0;
      while (!halted && t < 200) begin
        tick;
        t = t + 1;
      end
      chk("g_stopped", {31'd0, halted}, 32'd1);
      hread(4'd4); chk("g_counter_zero", {24'd0, rdv}, 32'd0);
      hread(4'd5); chk("g_body_count",   {24'd0, rdv}, 32'd5);

      // host register write while halted takes effect next cycle
      hr_we    = 1'b1;
      hr_addr  = 4'd6;
      hr_wdata = 8'h77;
      tick;
      hr_we = 1'b0;
      hread(4'd6); chk("g_host_reg_write_halted", {24'd0, rdv}, 32'h77);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (h) PULL blocks until host_in_push
  // ---------------------------------------------------------------------------
  task test_pull;
    begin
      $display("[h] PULL blocks on empty input FIFO");
      reset_dut;

      prog[0] = enc(OP_PULL, 3'd0, 3'd0, 8'h00, 3'd0);
      prog[1] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);

      load_words(2);
      start_run;

      repeat (4) tick;
      chk("h_stalled_pc", {26'd0, dbg_pc}, 32'd0);
      hread(4'd15);
      chk("h_in_empty", {(31'd0), rdv[2]}, 32'd1);

      host_in_push = 1'b1;
      host_in_data = 8'hAB;
      tick;
      host_in_push = 1'b0;

      tick;   // PULL now completes
      chk("h_pc_advanced", {26'd0, dbg_pc}, 32'd1);
      hread(4'd0); chk("h_pulled_value", {24'd0, rdv}, 8'hAB);
      hread(4'd15);
      chk("h_in_empty_after", {31'd0, rdv[2]}, 32'd1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (i) BAR stalls until bar_go; completes immediately when alone
  // ---------------------------------------------------------------------------
  task test_bar;
    begin
      $display("[i] BAR handshake");
      reset_dut;

      prog[0] = enc(OP_BAR,  3'd0, 3'd0, 8'h00, 3'd0); // barrier 0
      prog[1] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);

      load_words(2);
      run_mask = 4'b0011;
      bar_go   = 1'b0;
      start_run;

      tick;
      chk("i_bar_req",   {31'd0, bar_req}, 32'd1);
      chk("i_bar_id",    {30'd0, bar_id},  32'd0);
      chk("i_bar_stall", {26'd0, dbg_pc},  32'd0);
      tick;
      chk("i_bar_req_hold", {31'd0, bar_req}, 32'd1);

      bar_go = 1'b1;
      tick;
      bar_go = 1'b0;
      chk("i_bar_done_pc",  {26'd0, dbg_pc},  32'd1);
      chk("i_bar_req_clear",{31'd0, bar_req}, 32'd0);

      tick;
      chk("i_bar_halted", {31'd0, halted}, 32'd1);

      // singleton: only this engine runs -> no handshake needed
      reset_dut;
      prog[0] = enc(OP_BAR,  3'd0, 3'd0, 8'h01, 3'd0); // barrier 1
      prog[1] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
      load_words(2);
      run_mask = 4'b0001;
      bar_go   = 1'b0;
      start_run;
      tick;
      chk("i_bar_singleton_pc", {26'd0, dbg_pc}, 32'd1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (j) IRQ pulses / IRQWAIT, and ASSERT error flag
  // ---------------------------------------------------------------------------
  task test_irq;
    begin
      $display("[j] IRQSET/IRQCLR pulses and blocking IRQWAIT");
      reset_dut;

      prog[0] = enc(OP_IRQCLR, 3'd0, 3'd0, 8'd3, 3'd0);
      prog[1] = enc(OP_IRQSET, 3'd0, 3'd0, 8'd3, 3'd0);
      prog[2] = enc(OP_IRQWAIT,3'd0, 3'd0, 8'd3, 3'd0);
      prog[3] = enc(OP_HALT,   3'd0, 3'd0, 8'h00, 3'd0);

      load_words(4);
      irq = 8'h00;
      start_run;

      chk("j_irqclr_pulse", {24'd0, irq_clr}, 32'h08);
      chk("j_irqset_low",   {24'd0, irq_set}, 32'd0);
      tick;   // IRQCLR executes
      chk("j_irqset_pulse", {24'd0, irq_set}, 32'h08);
      chk("j_irqclr_low",   {24'd0, irq_clr}, 32'd0);
      tick;   // IRQSET executes; IRQWAIT in flight with irq=0 -> blocks
      chk("j_irqwait_blocked", {26'd0, dbg_pc}, 32'd2);
      tick;
      chk("j_irqwait_still",   {26'd0, dbg_pc}, 32'd2);

      irq = 8'h08;
      tick;
      chk("j_irqwait_done", {26'd0, dbg_pc}, 32'd3);
    end
  endtask

  task test_assert;
    begin
      $display("[k] ASSERT error flag");
      reset_dut;

      prog[0] = enc(OP_LDI,    3'd0, 3'd0, 8'h55, 3'd0);
      prog[1] = enc(OP_ASSERT, 3'd0, 3'd0, 8'h55, 3'd0); // passes
      prog[2] = enc(OP_ASSERT, 3'd0, 3'd0, 8'h54, 3'd0); // fails
      prog[3] = enc(OP_HALT,   3'd0, 3'd0, 8'h00, 3'd0);

      load_words(4);
      start_run;
      repeat (4) tick;
      chk("k_error_set", {31'd0, error}, 32'd1);
      chk("k_halted",    {31'd0, halted}, 32'd1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // extra: CAPTURE pulse and out-FIFO readback
  // ---------------------------------------------------------------------------
  task test_capture_push;
    begin
      $display("[x] CAPTURE pulse + PUSH/out-FIFO readback");
      reset_dut;

      prog[0] = enc(OP_CAPTURE, 3'd0, 3'd0, 8'h15, 3'd0); // tag {level=1,pin=5}
      prog[1] = enc(OP_LDI,     3'd0, 3'd0, 8'h5A, 3'd0);
      prog[2] = enc(OP_PUSH,    3'd0, 3'd0, 8'h00, 3'd0);
      prog[3] = enc(OP_HALT,    3'd0, 3'd0, 8'h00, 3'd0);

      load_words(4);
      start_run;

      // CAPTURE is in flight during pc=0: request must be a 1-cycle pulse.
      chk("x_cap_req", {31'd0, cap_req}, 32'd1);
      chk("x_cap_tag", {27'd0, cap_tag}, 32'h15);
      tick;  // CAPTURE executes
      chk("x_cap_req_low", {31'd0, cap_req}, 32'd0);

      tick;  // LDI executes
      tick;  // PUSH executes
      hread(4'd15);
      chk("x_out_empty", {31'd0, rdv[4]}, 32'd0);

      host_out_pop = 1'b1;
      #1;
      chk("x_out_data", {24'd0, host_out_data}, 32'h5A);
      tick;
      host_out_pop = 1'b0;
      hread(4'd15);
      chk("x_out_empty_after", {31'd0, rdv[4]}, 32'd1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (y) FIFO_DEPTH: full/empty thresholds, dropped push, blocked PUSH
  // ---------------------------------------------------------------------------
  task test_fifo_depth;
    integer j;
    begin
      $display("[y] FIFO_DEPTH=%0d: in/out full, dropped push, blocked PUSH",
               FIFO_DEPTH);

      // ---- input FIFO: fill it, drop one push, drain exactly FIFO_DEPTH ----
      reset_dut;
      for (j = 0; j < FIFO_DEPTH; j = j + 1) begin
        host_in_push = 1'b1;
        host_in_data = j[7:0];
        tick;
      end
      host_in_push = 1'b0;
      hread(4'd15);
      chk("y_in_full",      {31'd0, rdv[3]}, 32'd1);
      chk("y_in_empty_off", {31'd0, rdv[2]}, 32'd0);

      // Full: the push must be dropped without moving in_wr.  in_wr wraps to
      // 0 at exactly FIFO_DEPTH pushes, so a wrongly accepted push would
      // overwrite entry 0 and the first PULL below would read 0xEE.
      host_in_push = 1'b1;
      host_in_data = 8'hEE;
      tick;
      host_in_push = 1'b0;
      hread(4'd15);
      chk("y_in_still_full", {31'd0, rdv[3]}, 32'd1);

      // Drain through the engine: PULL -> PUSH, FIFO_DEPTH times.
      prog[0] = enc(OP_LDI,  3'd1, 3'd0, FIFO_DEPTH[7:0], 3'd0);
      prog[1] = enc(OP_PULL, 3'd0, 3'd0, 8'h00, 3'd0);
      prog[2] = enc(OP_PUSH, 3'd0, 3'd0, 8'h00, 3'd0);
      prog[3] = enc(OP_DJNZ, 3'd1, 3'd0, 8'd1, 3'd0);
      prog[4] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
      load_words(5);
      start_run;
      t = 0;
      while (!halted && t < 100) begin
        tick;
        t = t + 1;
      end
      chk("y_drain_halted", {31'd0, halted}, 32'd1);
      hread(4'd15);
      chk("y_in_drained", {31'd0, rdv[2]}, 32'd1);

      // The output FIFO now holds exactly FIFO_DEPTH bytes: 0..FIFO_DEPTH-1.
      for (j = 0; j < FIFO_DEPTH; j = j + 1) begin
        chk("y_out_order", {24'd0, host_out_data}, j);
        host_out_pop = 1'b1;
        tick;
        host_out_pop = 1'b0;
      end
      hread(4'd15);
      chk("y_out_empty", {31'd0, rdv[4]}, 32'd1);

      // ---- output FIFO: PUSH blocks at FIFO_DEPTH, host pop unblocks -------
      reset_dut;
      for (j = 0; j <= FIFO_DEPTH; j = j + 1) begin
        prog[2*j]     = enc(OP_LDI,  3'd0, 3'd0, j[7:0], 3'd0);
        prog[2*j + 1] = enc(OP_PUSH, 3'd0, 3'd0, 8'h00, 3'd0);
      end
      prog[2*(FIFO_DEPTH+1)] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
      load_words(2*(FIFO_DEPTH+1) + 1);
      start_run;
      for (t = 0; t < 40; t = t + 1) tick;
      hread(4'd15);
      chk("y_out_full",          {31'd0, rdv[5]}, 32'd1);
      chk("y_out_blocked_halted",{31'd0, halted}, 32'd0);
      chk("y_out_head", {24'd0, host_out_data}, 32'd0);

      host_out_pop = 1'b1;
      tick;
      host_out_pop = 1'b0;
      t = 0;
      while (!halted && t < 20) begin
        tick;
        t = t + 1;
      end
      chk("y_out_unblocked_halted", {31'd0, halted}, 32'd1);

      for (j = 1; j <= FIFO_DEPTH; j = j + 1) begin
        chk("y_out_after_unblock", {24'd0, host_out_data}, j);
        host_out_pop = 1'b1;
        tick;
        host_out_pop = 1'b0;
      end
      hread(4'd15);
      chk("y_out_empty2", {31'd0, rdv[4]}, 32'd1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (y2) non-blocking FIFO forms: PUSHN on a full FIFO must set the nf flag and
  // continue instead of stalling (PULLN is the mirror image on an empty input
  // FIFO).  E_STATUS bit 6 is nf, bit 5 is out_full.
  // ---------------------------------------------------------------------------
  task test_fifo_nonblocking;
    integer j;
    begin
      $display("[y2] PUSHN on a full FIFO sets nf and does not stall");
      reset_dut;
      for (j = 0; j < FIFO_DEPTH; j = j + 1) begin
        prog[2*j]     = enc(OP_LDI,  3'd0, 3'd0, j[7:0], 3'd0);
        prog[2*j + 1] = enc(OP_PUSH, 3'd0, 3'd0, 8'h00, 3'd0);
      end
      prog[2*FIFO_DEPTH]     = enc(OP_LDI,   3'd1, 3'd0, 8'h77, 3'd0);
      prog[2*FIFO_DEPTH + 1] = enc(OP_PUSHN, 3'd1, 3'd0, 8'h00, 3'd0);
      prog[2*FIFO_DEPTH + 2] = enc(OP_HALT,  3'd0, 3'd0, 8'h00, 3'd0);
      load_words(2*FIFO_DEPTH + 3);
      start_run;
      t = 0;
      while (!halted && t < 60) begin
        tick;
        t = t + 1;
      end
      chk("y2_pushn_continues", {31'd0, halted}, 32'd1);
      hread(4'd15);
      chk("y2_pushn_nf",        {31'd0, rdv[6]}, 32'd1);
      chk("y2_pushn_out_full",  {31'd0, rdv[5]}, 32'd1);
      // The rejected push must not have overwritten the oldest entry.
      chk("y2_pushn_head_intact", {24'd0, host_out_data}, 32'd0);
    end
  endtask

  // ---------------------------------------------------------------------------
  // (z) assist CSR port [v2 only]: LDAS/STAS/ASST strobes, the assist-id and
  // register-index fields, the write data, and the empty-read rule (nf set, rd
  // unchanged, Z/N untouched -- the PULLN rule the model shares).  The assist
  // block itself is a bench stub here; the real CSR bank is covered by tb_csr
  // and top_e2e_tb.
  // ---------------------------------------------------------------------------
  task test_assist_port;
    begin
      $display("[z] LDAS/STAS/ASST assist port + empty-read nf rule");
      reset_dut;

      prog[0] = enc(OP_LDI,  3'd4, 3'd0, 8'h3C, 3'd0);
      prog[1] = enc(OP_STAS, 3'd4, 3'd2, 8'h06, 3'd0); // assist 6 reg 2 <- r4
      prog[2] = enc(OP_LDAS, 3'd2, 3'd5, 8'h03, 3'd0); // r2 <- assist 3 reg 5
      prog[3] = enc(OP_ASST, 3'd0, 3'd1, 8'h07, 3'd0); // cmd 0x07 to assist 1
      prog[4] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);

      load_words(5);
      as_rdata = 8'hA5;   // what the stub assist returns
      as_empty = 1'b0;
      start_run;

      chk("z_idle_rd",  {31'd0, as_rd},     32'd0);
      chk("z_idle_wr",  {31'd0, as_wr},     32'd0);
      chk("z_idle_cmd", {31'd0, as_cmd_en}, 32'd0);

      tick;   // pc=1 STAS
      chk("z_stas_wr",      {31'd0, as_wr},     32'd1);
      chk("z_stas_rd_low",  {31'd0, as_rd},     32'd0);
      chk("z_stas_id",      {29'd0, as_id},     32'd6);
      chk("z_stas_reg",     {29'd0, as_reg},    32'd2);
      chk("z_stas_wdata",   {24'd0, as_wdata},  32'h3C);
      chk("z_stas_cmd_low", {31'd0, as_cmd_en}, 32'd0);

      tick;   // pc=2 LDAS
      chk("z_ldas_rd",      {31'd0, as_rd},     32'd1);
      chk("z_ldas_wr_low",  {31'd0, as_wr},     32'd0);
      chk("z_ldas_id",      {29'd0, as_id},     32'd3);
      chk("z_ldas_reg",     {29'd0, as_reg},    32'd5);

      tick;   // LDAS executes: rd becomes as_rdata
      hread(4'd2);
      chk("z_ldas_value", {24'd0, rdv}, 32'hA5);
      hread(4'd15);
      chk("z_ldas_nf_low", {31'd0, rdv[6]}, 32'd0);

      // pc=3 ASST: assist id from rs, command from imm8
      chk("z_asst_cmd",    {31'd0, as_cmd_en}, 32'd1);
      chk("z_asst_id",     {29'd0, as_cmd_id}, 32'd1);
      chk("z_asst_imm",    {24'd0, as_cmd},    32'h07);
      chk("z_asst_rd_low", {31'd0, as_rd},     32'd0);
      chk("z_asst_wr_low", {31'd0, as_wr},     32'd0);

      tick;   // ASST executes
      tick;   // HALT executes
      chk("z_halted", {31'd0, halted}, 32'd1);

      // ---- empty read: nf set, rd unchanged, Z/N untouched ----------------
      reset_dut;
      prog[0] = enc(OP_LDI,  3'd2, 3'd0, 8'h00, 3'd0); // Z=1, N=0
      prog[1] = enc(OP_LDAS, 3'd2, 3'd0, 8'h01, 3'd0); // FIFO DATA, empty
      prog[2] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
      load_words(3);
      as_rdata = 8'h5A;
      as_empty = 1'b1;
      start_run;

      tick;   // LDI executes
      tick;   // LDAS executes
      chk("z_empty_pc", {26'd0, dbg_pc}, 32'd2);   // LDAS always retires
      hread(4'd2);
      chk("z_empty_rd_unchanged", {24'd0, rdv}, 32'h00);
      hread(4'd15);
      chk("z_empty_nf", {31'd0, rdv[6]}, 32'd1);
      chk("z_empty_z_flag", {31'd0, dut.z_r}, 32'd1);  // Z untouched
      chk("z_empty_n_flag", {31'd0, dut.n_r}, 32'd0);  // N untouched
      tick;
      chk("z_empty_halted", {31'd0, halted}, 32'd1);
    end
  endtask

  // ---------------------------------------------------------------------------
  // main
  // ---------------------------------------------------------------------------
  initial begin
    clk           = 1'b0;
    rst_n         = 1'b0;
    cycle_q       = 32'd0;
    run           = 1'b0;
    host_prog_we  = 1'b0;
    host_prog_be  = 3'b000;
    host_prog_addr= 6'd0;
    host_prog_data= 24'd0;
    pin_ui        = 8'h00;
    pin_uo        = 8'h00;
    pin_uio       = 8'h00;
    irq           = 8'h00;
    run_mask      = 4'b0001;
    bar_go        = 1'b0;
    hr_we         = 1'b0;
    hr_addr       = 4'd0;
    hr_wdata      = 8'h00;
    host_in_push  = 1'b0;
    host_in_data  = 8'h00;
    host_out_pop  = 1'b0;
    as_rdata      = 8'h00;
    as_empty      = 1'b0;
    errors        = 0;
    nchecks       = 0;

    $display("==== proteus_engine smoke test (v2) ====");

    test_reset;
    test_alu;
    test_branch;
    test_pins;
    test_side_set;
    test_waitc(11'd0, 1);
    test_waitc(11'd1, 1);
    test_waitc(11'd5, 5);
    test_waitp_timeout;
    test_pace_16;
    test_pace_frac;
    test_loop;
    test_irq;
    test_assert;
    test_pull;
    test_bar;
    test_capture_push;
    test_fifo_depth;
    test_fifo_nonblocking;
    test_assist_port;

    if (errors == 0) begin
      $display("==== PASS: all engine smoke checks passed (%0d checks) ====",
               nchecks);
      $finish;
    end else begin
      $fatal(1, "==== FAIL: %0d check(s) failed ====", errors);
    end
  end

endmodule

`default_nettype wire
