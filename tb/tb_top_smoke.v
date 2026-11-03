`timescale 1ns/1ps
// ===========================================================================
// tb_top_smoke.v -- hybrid v2 top smoke test over the real SPI host.
//
// Drives the chip the way a host does:
//   1. identity registers of the hybrid build (ID0/ID1/VERSION = 0x02)
//   2. loads an 8-word program into engine 0 through the program window
//      (0x0100 + i*4 + byte) and reads one word back
//   3. sets RUN and waits for the HALT to retire the RUN bit
//   4. checks the pad actually toggled (uio_out[0] edge count) and that the
//      engine's own register and PC read back correctly
//   5. touches the new assist window (PINCFG for the Manchester assist) to
//      prove the 0x0600 bank coexists with the v1 register map
//
// Program (v2/tools/asm.py):
//   0  LDI  r0, 0x01          5  CMPI r1, 0x04
//   1  LDI  r1, 0x00          6  JNZ  2
//   2  OUTP UIO, 0x01, r0     7  HALT
//   3  XORI r0, 0x01
//   4  ADDI r1, 0x01
// r0 alternates 1/0 at uio[0] (4 writes: 1,0,1,0) and r1 ends at 4.
// ===========================================================================
module tb_top_smoke;

  localparam CLKP = 10;
  localparam CLKH = 5;

  reg clk = 1'b0;
  always #(CLKH) clk = ~clk;

  reg rst_n = 1'b0;
  reg sck = 1'b0, cs_n = 1'b1, mosi = 1'b0;
  wire miso;

  wire [7:0] ui_in  = {5'b0, mosi, cs_n, sck};   // ui[2]=MOSI ui[1]=CS_N ui[0]=SCK
  wire [7:0] uio_in = 8'h00;
  wire [7:0] uo_out, uio_out, uio_oe;

  tt_um_proteus dut (
    .ui_in  (ui_in),
    .uo_out (uo_out),
    .uio_in (uio_in),
    .uio_out(uio_out),
    .uio_oe (uio_oe),
    .ena    (1'b1),
    .clk    (clk),
    .rst_n  (rst_n)
  );
  assign miso = uo_out[0];   // uo_out[1] is IRQ, uo_out[0] is MISO

  reg [7:0] wbuf [0:31];
  reg [7:0] rbuf [0:31];

  `include "spi_master.vh"

  // ------------------------------------------------------------ scoreboard
  integer errors = 0;
  integer nchecks = 0;

  task chk8(input [7:0] got, input [7:0] exp, input [255:0] what);
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got 0x%02x want 0x%02x (t=%0t)", what, got, exp, $time);
      end
    end
  endtask

  task chkbit(input got, input exp, input [255:0] what);
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got %b want %b (t=%0t)", what, got, exp, $time);
      end
    end
  endtask

  // ----------------------------------------------------------- pin monitor
  reg     prev_pad = 1'b0;
  integer nedge = 0;
  always @(posedge clk) begin
    if (uio_out[0] !== prev_pad) begin
      nedge = nedge + 1;
      prev_pad <= uio_out[0];
    end
  end

  // ------------------------------------------------------------- program
  reg [23:0] prog_words [0:7];

  task load_prog;
    integer k;
    begin
      for (k = 0; k < 8; k = k + 1) begin
        wbuf[0] = prog_words[k][7:0];
        wbuf[1] = prog_words[k][15:8];
        wbuf[2] = prog_words[k][23:16];
        host_wr_blk(16'h0100 + (k * 4), 3);
      end
    end
  endtask

  // ---------------------------------------------------------------- body
  integer k, tries;
  reg [7:0] v;
  reg [7:0] p0, p1, p2;

  initial begin
    prog_words[0] = 24'h000008;   // LDI   r0, 0x01
    prog_words[1] = 24'h004000;   // LDI   r1, 0x00
    prog_words[2] = 24'h4a1008;   // OUTP  UIO, 0x01, r0
    prog_words[3] = 24'h0a0008;   // XORI  r0, 0x01
    prog_words[4] = 24'h024008;   // ADDI  r1, 0x01
    prog_words[5] = 24'h0c4020;   // CMPI  r1, 0x04
    prog_words[6] = 24'h648010;   // JNZ   2
    prog_words[7] = 24'h700000;   // HALT

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    // ---- 1. identity ------------------------------------------------
    host_rd(16'h0000, v);  chk8(v, 8'h50, "ID0");
    host_rd(16'h0001, v);  chk8(v, 8'h52, "ID1");
    host_rd(16'h0002, v);  chk8(v, 8'h02, "VERSION = hybrid v2");

    // ---- 2. load program into engine 0 and read one word back -------
    load_prog;
    host_rd_blk(16'h0100, 3);
    chk8(rbuf[0], prog_words[0][7:0],   "prog[0] byte 0 readback");
    chk8(rbuf[1], prog_words[0][15:8],  "prog[0] byte 1 readback");
    chk8(rbuf[2], prog_words[0][23:16], "prog[0] byte 2 readback");
    host_rd(16'h011C, p0);              // word 7, byte 0 (0x0100 + 7*4)
    chk8(p0, prog_words[7][7:0], "prog[7] byte 0 readback");

    // ---- 3. run engine 0 until HALT ---------------------------------
    host_rd(16'h0004, v);   chk8(v, 8'h00, "RUN clear before start");
    host_wr(16'h0004, 8'h01);
    tries = 0;
    v = 8'h01;
    while (v[0] && tries < 80) begin
      host_rd(16'h0004, v);
      tries = tries + 1;
    end
    chkbit(v[0], 1'b0, "RUN retired by HALT");

    // ---- 4. engine state and pad activity ---------------------------
    chkbit(nedge >= 4, 1'b1, "uio_out[0] toggled at least 4 times");
    chk8(uio_out[0], 8'h00, "uio_out[0] left low by the program");
    chkbit(uio_oe[0], 1'b1, "uio[0] driven by the engine");
    host_rd(16'h0015, v);   chk8(v, 8'h04, "engine 0 r1 = 4 iterations");
    host_rd(16'h0011, v);   chk8(v, 8'h07, "engine 0 PC stopped on HALT");
    host_rd(16'h0010, v);
    chkbit(v[1], 1'b1, "engine 0 halted");
    chkbit(v[0], 1'b0, "engine 0 run clear");

    // ---- 5. assist window reachable alongside the v1 map ------------
    host_wr(16'h0648, 8'hC1);            // MANCH PINCFG: en, UIO, tx 0, rx 1
    host_rd(16'h0648, v);   chk8(v, 8'hC1, "assist PINCFG readback");
    host_rd(16'h0643, v);   chk8(v, 8'h44, "assist MANCH CFG readback");
    // a v1 register is still intact next to the new window
    host_rd(16'h0003, v);
    chkbit(v[0], 1'b0, "STATUS.any_run clear after HALT");

    if (errors == 0)
      $display("TB_TOP_SMOKE PASS (%0d checks, %0d pad edges)", nchecks, nedge);
    else
      $display("TB_TOP_SMOKE FAIL (%0d errors, %0d checks)", errors, nchecks);
    $finish;
  end

  initial begin
    #2000000;
    $display("TB_TOP_SMOKE FAIL (timeout)");
    $finish;
  end
endmodule
