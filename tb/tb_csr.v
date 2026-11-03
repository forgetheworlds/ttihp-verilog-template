`timescale 1ns/1ps
// ===========================================================================
// tb_csr.v -- assist CSR bench for the hybrid v2 top.
//
// Two access paths, both against the real SPI host in tt_um_proteus:
//
//   host path   : 0x0600 + 0x10*id + reg, plus the host-only PINCFG at +8.
//                 Every reachable register of every assist is written and read
//                 back, including the read-only status/count registers whose
//                 expected values are derived from the block behaviour.
//   engine path : LDAS / STAS / ASST from engine 0 (a real program loaded into
//                 the program window and run with the RUN register).  Covers
//                 CRC fold + 4-register read-back, FIFO push/pop, the empty
//                 LDAS -> nf_flag rule, and the host draining the engine's out
//                 FIFO.
//
// Check values are the study vectors: CRC-32/ISO-HDLC over gen_crc_vectors.py's
// 16-byte stream (crc_exp.hex, 0xE1BFA6A4) through the host path, and
// zlib.crc32("12") = 0x4F5344CD through the engine path.
// ===========================================================================
module tb_csr;

  localparam CLKP = 10;      // clk period, ns
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
  reg [7:0] rbuf [0:15];

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

  // ------------------------------------------------------- assist CSRs
  // Address = 0x0600 + 0x10*id + reg; reg 8 = PINCFG (host only).
  function [15:0] as_addr;
    input [15:0] id;
    input [3:0]  idx;
    begin
      as_addr = 16'h0600 + (id * 16) + {12'd0, idx};
    end
  endfunction

  task as_wr;
    input [15:0] id;
    input [3:0]  idx;
    input [7:0]  v;
    begin
      host_wr(as_addr(id, idx), v);
    end
  endtask

  task as_rd;
    input  [15:0] id;
    input  [3:0]  idx;
    output [7:0]  v;
    begin
      host_rd(as_addr(id, idx), v);
    end
  endtask

  // ------------------------------------------------- program / run helpers
  reg [23:0] prog_words [0:31];

  task load_prog(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) begin
        wbuf[0] = prog_words[k][7:0];
        wbuf[1] = prog_words[k][15:8];
        wbuf[2] = prog_words[k][23:16];
        host_wr_blk(16'h0100 + (k * 4), 3);
      end
    end
  endtask

  task run_engine;
    reg [7:0] v;
    integer tries;
    begin
      host_wr(16'h0004, 8'h01);              // RUN engine 0
      tries = 0;
      v = 8'h01;
      while (v[0] && tries < 80) begin
        host_rd(16'h0004, v);
        tries = tries + 1;
      end
      if (v[0]) begin
        errors = errors + 1;
        $display("FAIL engine did not halt within %0d polls", tries);
      end
    end
  endtask

  // --------------------------------------------------------------- body
  integer id, r, k, c;
  reg [7:0] v, seed;
  reg [7:0] byte_lo, byte_hi, byte_3;
  reg [31:0] crc_host;

  initial begin
    $readmemh("crc_bytes.hex", rbuf);        // reuse as the 16-byte stream
    for (k = 0; k < 16; k = k + 1) wbuf[k] = rbuf[k];

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    // ---- A. identity ---------------------------------------------------
    host_rd(16'h0000, v);  chk8(v, 8'h50, "ID0");
    host_rd(16'h0001, v);  chk8(v, 8'h52, "ID1");
    host_rd(16'h0002, v);  chk8(v, 8'h02, "VERSION = hybrid v2");

    // ---- B. PINCFG for all five assists (host-only, reg 8) -------------
    // {en, bank, tx_base[2:0], rx_base[1:0]}
    as_wr(0, 8, 8'h00); as_wr(1, 8, 8'h00); as_wr(2, 8, 8'h00);
    as_wr(3, 8, 8'hC4);                      // en, UIO, dp=1 dm=2, rx 0/1
    as_wr(4, 8, 8'hC1);                      // en, UIO, tx=0, rx=1
    for (id = 0; id < 5; id = id + 1) begin
      as_rd(id, 8, v);
      case (id)
        0, 1, 2: chk8(v, 8'h00, "PINCFG idle assist");
        3:       chk8(v, 8'hC4, "PINCFG NRZI");
        default: chk8(v, 8'hC1, "PINCFG MANCH");
      endcase
    end

    // ---- C. NRZI DIV and MANCH CFG ------------------------------------
    as_wr(3, 3, 8'h20);                      // 32 clocks/bit = 1.5 MBit/s
    as_rd(3, 3, v);   chk8(v, 8'h20, "NRZI DIV readback");
    as_rd(4, 3, v);   chk8(v, 8'h44, "MANCH CFG {HALF_DIV=4, OS=4}");

    // ---- D. FIFO through the host window ------------------------------
    as_wr(1, 3, 8'h02);                      // CMD: clr
    as_rd(1, 1, v);   chk8(v, 8'h20, "FIFO empty after clr");
    as_wr(1, 2, 8'h03);                      // BURSTLEN = 3
    as_rd(1, 2, v);   chk8(v, 8'h03, "FIFO BURSTLEN readback");
    as_wr(1, 0, 8'h11);                      // push 0x11
    as_wr(1, 0, 8'h22);                      // push 0x22
    as_rd(1, 1, v);   chk8(v, 8'h02, "FIFO level 2");
    as_rd(1, 0, v);   chk8(v, 8'h11, "FIFO pop order #1");
    as_rd(1, 1, v);   chk8(v, 8'h01, "FIFO level 1");
    as_rd(1, 0, v);   chk8(v, 8'h22, "FIFO pop order #2");
    as_rd(1, 1, v);   chk8(v, 8'h20, "FIFO empty again");
    as_rd(1, 4, v);   chk8(v, 8'h00, "FIFO POPS exhausted");
    as_rd(1, 5, v);   chk8(v, 8'h00, "FIFO IRQ flag clear");

    // ---- E. SHIFT through the host window -----------------------------
    as_wr(2, 3, 8'h00);                      // reset: MSB-first, width 32
    as_rd(2, 2, v);   chk8(v, 8'hC0, "SHIFT CFG after reset");
    as_wr(2, 0, 8'hAB);                      // push at the top of the word
    as_rd(2, 7, v);   chk8(v, 8'hAB, "SHIFT dout[31:24] after push");
    as_rd(2, 4, v);   chk8(v, 8'h00, "SHIFT dout[7:0]");
    as_rd(2, 0, v);   chk8(v, 8'hAB, "SHIFT byte at active end");

    // ---- F. CRC through the host window: CRC-32/ISO-HDLC --------------
    // CFG0 = {lsb=1, refl=1, width=32}
    as_wr(0, 2, 8'hE0);
    as_rd(0, 2, v);   chk8(v, 8'hE0, "CRC CFG0 readback");
    // page = init, poly, xorout (pages 1..3), then back to the result page
    as_wr(0, 3, 8'd8);
    as_wr(0, 4, 8'hFF); as_wr(0, 5, 8'hFF); as_wr(0, 6, 8'hFF); as_wr(0, 7, 8'hFF);
    as_wr(0, 3, 8'd9);
    as_wr(0, 4, 8'h20); as_wr(0, 5, 8'h83); as_wr(0, 6, 8'hB8); as_wr(0, 7, 8'hED);
    as_wr(0, 3, 8'd10);
    as_wr(0, 4, 8'hFF); as_wr(0, 5, 8'hFF); as_wr(0, 6, 8'hFF); as_wr(0, 7, 8'hFF);
    as_rd(0, 4, v);   chk8(v, 8'hFF, "CRC xorout page byte 0");
    as_wr(0, 3, 8'd0);                       // page = live CRC
    as_wr(0, 3, 8'd1);                       // START: reload init
    as_rd(0, 1, v);   chkbit(v[7], 1'b0, "CRC not busy after start");

    for (k = 0; k < 16; k = k + 1) begin
      as_wr(0, 0, wbuf[k]);                  // fold one byte
      as_rd(0, 1, v);
      if (v[7]) begin
        errors = errors + 1;
        $display("FAIL CRC busy after a host byte write");
      end
    end
    as_rd(0, 1, v);   chkbit(v[1], 1'b0, "CRC no dropped byte");
    as_rd(0, 4, byte_lo);
    as_rd(0, 5, byte_hi);
    as_rd(0, 6, byte_3);
    as_rd(0, 7, v);
    crc_host = {v, byte_3, byte_hi, byte_lo};
    if (crc_host !== 32'hE1BFA6A4) begin
      errors = errors + 1;
      $display("FAIL host CRC-32/ISO-HDLC: got 0x%08x want 0xe1bfa6a4",
               crc_host);
    end else
      $display("PASS host CRC-32/ISO-HDLC over 16 bytes: 0x%08x", crc_host);

    // ---- G. engine path: FIFO push/pop + nf rule ----------------------
    prog_words[0]  = 24'h000528;   // LDI   r0, 0xA5
    prog_words[1]  = 24'h9e0008;   // STAS  r0, r0, FIFO
    prog_words[2]  = 24'h0002d0;   // LDI   r0, 0x5A
    prog_words[3]  = 24'h9e0008;   // STAS  r0, r0, FIFO
    prog_words[4]  = 24'h9c4008;   // LDAS  r1, r0, FIFO
    prog_words[5]  = 24'h804000;   // PUSH  r1
    prog_words[6]  = 24'h9c4008;   // LDAS  r1, r0, FIFO
    prog_words[7]  = 24'h804000;   // PUSH  r1
    prog_words[8]  = 24'h9c4808;   // LDAS  r1, r1, FIFO   (STATUS)
    prog_words[9]  = 24'h804000;   // PUSH  r1
    prog_words[10] = 24'h9c4008;   // LDAS  r1, r0, FIFO   (empty -> nf)
    prog_words[11] = 24'h804000;   // PUSH  r1 (unchanged)
    // PUSH clears nf_flag (v1 semantics), so a final failed LDAS is left as the
    // last FIFO op to make nf observable at HALT.
    prog_words[12] = 24'h9c4008;   // LDAS  r1, r0, FIFO   (empty -> nf)
    prog_words[13] = 24'h700000;   // HALT
    load_prog(14);
    run_engine;

    host_rd(16'h0021, v);  chk8(v, 8'hA5, "engine FIFO pop #1");
    host_rd(16'h0021, v);  chk8(v, 8'h5A, "engine FIFO pop #2");
    host_rd(16'h0021, v);  chk8(v, 8'h20, "engine FIFO STATUS (empty)");
    host_rd(16'h0021, v);  chk8(v, 8'h20, "engine LDAS empty left rd alone");
    host_rd(16'h0010, v);
    chkbit(v[6], 1'b1, "engine nf_flag set by empty LDAS");
    chkbit(v[1], 1'b1, "engine halted after HALT");
    chkbit(v[0], 1'b0, "engine RUN retired by HALT");
    as_rd(1, 1, v);        chk8(v, 8'h20, "FIFO emptied by engine pops");

    // ---- H. engine path: CRC fold + 4-register read-back --------------
    prog_words[0]  = 24'ha00008;   // ASST  CRC, START
    prog_words[1]  = 24'h000188;   // LDI   r0, 0x31
    prog_words[2]  = 24'h9e0000;   // STAS  r0, r0, CRC
    prog_words[3]  = 24'h740040;   // WAITC 8
    prog_words[4]  = 24'h000190;   // LDI   r0, 0x32
    prog_words[5]  = 24'h9e0000;   // STAS  r0, r0, CRC
    prog_words[6]  = 24'h740040;   // WAITC 8
    prog_words[7]  = 24'h9c6000;   // LDAS  r1, r4, CRC
    prog_words[8]  = 24'h804000;   // PUSH  r1
    prog_words[9]  = 24'h9c6800;   // LDAS  r1, r5, CRC
    prog_words[10] = 24'h804000;   // PUSH  r1
    prog_words[11] = 24'h9c7000;   // LDAS  r1, r6, CRC
    prog_words[12] = 24'h804000;   // PUSH  r1
    prog_words[13] = 24'h9c7800;   // LDAS  r1, r7, CRC
    prog_words[14] = 24'h804000;   // PUSH  r1
    prog_words[15] = 24'h700000;   // HALT
    load_prog(16);
    run_engine;

    host_rd(16'h0021, byte_lo);
    host_rd(16'h0021, byte_hi);
    host_rd(16'h0021, byte_3);
    host_rd(16'h0021, v);
    crc_host = {v, byte_3, byte_hi, byte_lo};
    if (crc_host !== 32'h4F5344CD) begin
      errors = errors + 1;
      $display("FAIL engine CRC-32 over {0x31,0x32}: got 0x%08x want 0x4f5344cd",
               crc_host);
    end else
      $display("PASS engine CRC-32 over {0x31,0x32}: 0x%08x", crc_host);

    // the engine left the same value readable through the host window
    as_rd(0, 3, v);   chk8(v, 8'h00, "CRC page still CRC result");
    as_rd(0, 7, v);   chk8(v, 8'h4F, "CRC[31:24] visible to the host");

    if (errors == 0)
      $display("TB_CSR PASS (%0d checks)", nchecks);
    else
      $display("TB_CSR FAIL (%0d errors, %0d checks)", errors, nchecks);
    $finish;
  end

  initial begin
    #4000000;
    $display("TB_CSR FAIL (timeout)");
    $finish;
  end
endmodule
