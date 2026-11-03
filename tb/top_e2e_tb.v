// ===========================================================================
// v2/tb/top_e2e_tb.v -- PROTEUS hybrid v2 end-to-end: REAL v2 tt_um_proteus,
// THREE real engines + the assist bank, everything driven through the host SPI
// pins only (ui_in[2:0] / uo_out[0]).
//
// Port of tb/top_e2e_tb.v (v1, four engines, untouched).  Every v1 check is
// kept; what changed is only what the 3-engine hybrid build changed:
//   * VERSION reads 0x02;
//   * the map ends at 0x006F (engines) / 0x03FF (program pages), so the
//     out-of-map checks moved to 0x0070 and 0x0400;
//   * engine 2's page 0x0300 and RUN bit 2 are exercised (phase [4c]);
//   * the assist CSR window 0x0600 + 0x10*id + reg is exercised over the host
//     window AND through real LDAS/STAS instructions, including the assist
//     write-arbitration priority (phase [4d]).
//
// Nothing in this bench touches an internal signal to *drive* the design; the
// hierarchy is only read (dut.cycle, dut.u_engN.prog_mem[i], dut.host_en,
// dut.miso) to make the pin-level checks exact in places where a pin cannot
// distinguish two causes.
//
// Phases
//   [0] reset + identity over SPI (PING, ID0/ID1/VERSION)
//   [1] program load into engine 0 through 0x0100 + i*4 + b byte writes
//       (including single-lane byte writes that must not clobber the others),
//       read back over READ_ADDR and compare, plus the assembled RAM word
//   [2] RUN bit 0: UIO0 toggles with the PACE/loop period, PC advances
//   [3] program-written registers read back over the engine window, plus the
//       output FIFO (PUSH) and the RUN-bit-retired-by-HALT rule
//   [4] capture unit: CAP_EN(uio0) -> 3 engine-generated edges, CAP_STATUS /
//       CAP_TS / CAP_INFO, CAP_POP drain
//   [4a] open-drain release at the pad, [4b] capture timestamp width
//   [4c] 3-engine map: engine 2's page 0x0300, window/map ends, RUN bit width
//   [4d] assist CSR window: PINCFG/DIV over the host, LDAS/STAS round trip,
//        empty-data-read nf rule, engine write arbitration
//   [5] two-engine barrier: engines 0 and 1 leave BAR 0 in the SAME cycle
//   [6] pacer across the 2^24 cycle boundary: the 32-bit deadline keeps
//       completions exactly `period` apart (cycle counter injected to reach
//       the boundary without simulating 16.7M clocks)
//   [7] run-rising restart must not execute the instruction at the stale PC
//   [8] HOST_DISABLE: engine writes reach uo_out/uio and MISO stops driving
//
// Exit: $fatal(1) on any failed check (vvp exits non-zero), PASS line + exit 0
// otherwise.
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module top_e2e_tb;

  localparam CLKP = 10;          // 100 MHz sim clock, SPI SCK = clk/8

  // ------------------------------------------------------------------ ISA
  // tools/isa.py opcodes; 24-bit layout op[23:17] rd[16:14] rs[13:11]
  // imm[10:3] ss[2:0].
  localparam [6:0] OP_LDI    = 7'h00, OP_ADDI = 7'h01;
  localparam [6:0] OP_SETP   = 7'h22, OP_CLRP = 7'h23, OP_TOGP = 7'h24;
  localparam [6:0] OP_JMP    = 7'h30, OP_HALT = 7'h38, OP_NOP  = 7'h39;
  localparam [6:0] OP_WAITC  = 7'h3A, OP_PACE = 7'h3B, OP_PACERST = 7'h3C;
  localparam [6:0] OP_PUSH   = 7'h40, OP_PULL  = 7'h41, OP_IRQSET = 7'h44,
                   OP_BAR  = 7'h47, OP_CFG = 7'h4D;
  // hybrid v2 assist CSR access
  localparam [6:0] OP_LDAS   = 7'h4E, OP_STAS = 7'h4F, OP_ASST = 7'h50;

  localparam [1:0] BANK_UO   = 2'd1, BANK_UIO = 2'd2;

  // ------------------------------------------------------------ register map
  localparam [15:0] RA_ID0      = 16'h0000, RA_ID1   = 16'h0001,
                    RA_VERSION  = 16'h0002, RA_STATUS= 16'h0003,
                    RA_RUN      = 16'h0004, RA_HALT  = 16'h0005,
                    RA_IRQ_ST   = 16'h0008, RA_IRQ_ACK = 16'h000A,
                    RA_CYCLE0   = 16'h000B;
  localparam [15:0] E0_BASE    = 16'h0010, E1_BASE = 16'h0030,
                    E2_BASE    = 16'h0050;
  localparam [15:0] E0_STATUS  = 16'h0010, E0_PC   = 16'h0011;
  localparam [15:0] E0_R0      = 16'h0014, E0_OUT  = 16'h0021;
  localparam [15:0] E1_STATUS  = 16'h0030;
  localparam [15:0] E2_STATUS  = 16'h0050, E2_PC   = 16'h0051,
                    E2_R0      = 16'h0054, E2_OUT  = 16'h0061;
  localparam [15:0] RA_PM0     = 16'h0100, RA_PM1  = 16'h0200,
                    RA_PM2     = 16'h0300;
  // v2 assist CSR window: 0x0600 + 0x10*id + reg, PINCFG at +8
  localparam [15:0] AS_NRZI_DIV    = 16'h0633,   // id 3, reg 3
                    AS_FIFO_DATA   = 16'h0610,   // id 1, reg 0 (R pops)
                    AS_FIFO_STATUS = 16'h0611,   // id 1, reg 1
                    AS_PINCFG_MANCH= 16'h0648,   // id 4, reg 8 (host only)
                    AS_CRC_CFG0    = 16'h0602,   // id 0, reg 2
                    AS_CRC_PAGE    = 16'h0603;   // id 0, reg 3 (RO {6'b0,page})
  localparam [15:0] RA_COLLISION = 16'h0510, RA_COLL_CLR = 16'h0511;
  localparam [15:0] E2_IN       = 16'h0060;    // engine 2 IN_FIFO (write pushes)
  localparam [15:0] RA_CAP_EN  = 16'h0500, RA_CAP_ST = 16'h0501,
                    RA_CAP_TS  = 16'h0502, RA_CAP_INFO = 16'h0506,
                    RA_CAP_POP = 16'h0507;
  localparam [15:0] RA_UO      = 16'h0520, RA_UIO  = 16'h0521,
                    RA_UOE     = 16'h0522, RA_UOD  = 16'h0523;

  localparam integer PERIOD = 16;        // PACE period, in cycles (24.8 integer part)

  // ---------------------------------------------------------------- clock
  reg clk = 1'b0;
  always #(CLKP/2) clk = ~clk;

  reg  rst_n = 1'b0;

  // ------------------------------------------------------------ DUT pins
  reg  sck  = 1'b0;
  reg  cs_n = 1'b1;
  reg  mosi = 1'b0;
  reg  [7:0] ui_in = 8'h02;        // SPI idle: SCK=0, CS_N=1, MOSI=0 (never X)
  wire [7:0] uo_out, uio_out, uio_oe;
  wire miso;                       // host MISO as seen on the uo_out[0] pad
  wire [7:0] uio_in;

  always @* begin
    ui_in[0]   = sck;
    ui_in[1]   = cs_n;
    ui_in[2]   = mosi;
    ui_in[7:3] = 5'b00000;         // fabric inputs, unused here
  end

  assign miso   = uo_out[0];
  // Pad model: a pin reads back what the chip drives on it while OE is set,
  // otherwise the external line level (nothing attached -> 0).
  assign uio_in = uio_out & uio_oe;

  tt_um_proteus #(.PROG_DEPTH(32)) dut (
    .ui_in  (ui_in),
    .uo_out (uo_out),
    .uio_in (uio_in),
    .uio_out(uio_out),
    .uio_oe (uio_oe),
    .ena    (1'b1),
    .clk    (clk),
    .rst_n  (rst_n)
  );

  // ------------------------------------------------------------ scoreboard
  integer errors  = 0;
  integer nchecks = 0;

  task fail(input [511:0] what);
    begin
      errors = errors + 1;
      $display("FAIL %0s (t=%0t)", what, $time);
    end
  endtask

  task chk8(input [7:0] got, input [7:0] exp, input [511:0] what);
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got 0x%02x expected 0x%02x (t=%0t)",
                 what, got, exp, $time);
      end
    end
  endtask

  task chk1(input got, input exp, input [511:0] what);
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got %b expected %b (t=%0t)", what, got, exp, $time);
      end
    end
  endtask

  task chk24(input [23:0] got, input [23:0] exp, input [511:0] what);
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got 0x%06x expected 0x%06x (t=%0t)",
                 what, got, exp, $time);
      end
    end
  endtask

  // ------------------------------------------------------------ instruction
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

  // ------------------------------------------------------------ SPI master
  // Mode 0 (CPOL=0, CPHA=0), MSB first, SCK = clk/8 (see proteus_host decision
  // 3: clk/4 is one clk short of the two-FF synchroniser plus MISO pipeline).
  task spi_byte;
    input  [7:0] mo;
    output [7:0] mi;
    integer b;
    begin
      mi = 8'h00;
      for (b = 7; b >= 0; b = b - 1) begin
        mosi = mo[b];
        sck  = 1'b0;
        #(CLKP*4);
        sck  = 1'b1;
        #(CLKP*2);
        mi[b] = miso;              // mode-0 sample point, inside the high phase
        #(CLKP*2);
        sck  = 1'b0;
      end
    end
  endtask

  task frame_start;
    begin
      sck  = 1'b0;
      mosi = 1'b0;
      #(CLKP*2);
      cs_n = 1'b0;
      #(CLKP*8);                   // let the CS_N synchroniser see it first
    end
  endtask

  task frame_end;
    begin
      #(CLKP*6);                   // absorb the last falling edge
      cs_n = 1'b1;
      #(CLKP*10);
    end
  endtask

  // WRITE_ADDR frame: 16-bit LE address followed by n data bytes (auto-inc).
  task wr1;
    input [15:0] a;
    input [7:0]  d;
    reg   [7:0]  t;
    begin
      frame_start;
      spi_byte(8'h05, t);          // WRITE_ADDR
      spi_byte(a[7:0],  t);
      spi_byte(a[15:8], t);
      spi_byte(d,       t);
      frame_end;
    end
  endtask

  // READ_ADDR frame: 16-bit LE address, one response byte.
  task rd1;
    input  [15:0] a;
    output [7:0]  d;
    reg    [7:0]  t;
    begin
      frame_start;
      spi_byte(8'h06, t);          // READ_ADDR
      spi_byte(a[7:0],  t);
      spi_byte(a[15:8], t);
      spi_byte(8'h00,   d);
      frame_end;
    end
  endtask

  // READ_ADDR frame, four auto-incrementing response bytes.
  task rd4;
    input  [15:0] a;
    output [7:0]  d0, d1, d2, d3;
    reg    [7:0]  t;
    begin
      frame_start;
      spi_byte(8'h06, t);
      spi_byte(a[7:0],  t);
      spi_byte(a[15:8], t);
      spi_byte(8'h00, d0);
      spi_byte(8'h00, d1);
      spi_byte(8'h00, d2);
      spi_byte(8'h00, d3);
      frame_end;
    end
  endtask

  // WRITE_ADDR frame with exactly one data byte: one program byte at
  // 0x0100 + e*0x100 + i*4 + b, landing in lane b only.
  task prog_byte;
    input [15:0] a;
    input [7:0]  d;
    reg   [7:0]  t;
    begin
      frame_start;
      spi_byte(8'h05, t);
      spi_byte(a[7:0],  t);
      spi_byte(a[15:8], t);
      spi_byte(d,       t);
      frame_end;
    end
  endtask

  // --------------------------------------------------------- program store
  reg [23:0] pwords [0:31];
  integer    pi;

  task clr_words;
    begin
      for (pi = 0; pi < 32; pi = pi + 1) pwords[pi] = 24'h000000;
    end
  endtask

  // Load the first n words of pwords into engine e.  One frame per word:
  // WRITE_ADDR 0x0100+e*0x100+i*4 followed by the three byte lanes.
  task program_load;
    input integer e;
    input integer n;
    integer j;
    reg [15:0] a;
    reg [7:0]  t;
    begin
      for (j = 0; j < n; j = j + 1) begin
        a = 16'h0100 + e*16'h0100 + j*4;
        frame_start;
        spi_byte(8'h05, t);            // WRITE_ADDR
        spi_byte(a[7:0],  t);
        spi_byte(a[15:8], t);
        spi_byte(pwords[j][7:0],   t); // byte 0
        spi_byte(pwords[j][15:8],  t); // byte 1
        spi_byte(pwords[j][23:16], t); // byte 2
        frame_end;
      end
    end
  endtask

  // Read the program back and compare byte for byte.  One frame per word:
  // program bytes are 0x0100 + e*0x100 + i*4 + b with b in 0..2 only, so the
  // i*4+3 lane is a hole (the top decodes it as byte 2) and a single
  // auto-incrementing read across words would read holes.
  task program_verify;
    input integer e;
    input integer n;
    integer j, b;
    reg [15:0] a;
    reg [7:0]  t, rb, exp;
    begin
      for (j = 0; j < n; j = j + 1) begin
        a = 16'h0100 + e*16'h0100 + j*4;
        frame_start;
        spi_byte(8'h06, t);              // READ_ADDR
        spi_byte(a[7:0],  t);
        spi_byte(a[15:8], t);
        for (b = 0; b < 3; b = b + 1) begin
          spi_byte(8'h00, rb);
          exp = (pwords[j] >> (b * 8)) & 8'hFF;
          nchecks = nchecks + 1;
          if (rb !== exp) begin
            errors = errors + 1;
            $display("FAIL prog readback eng%0d word %0d lane %0d: got 0x%02x expected 0x%02x",
                     e, j, b, rb, exp);
          end
        end
        frame_end;
      end
    end
  endtask

  // -------------------------------------------------------------- pin monitors
  // Phase [2]: record the cycle of every UIO0 transition (post-edge sampling).
  reg     mon_tog = 1'b0;
  reg     uio0_prev = 1'b0;
  integer n_tog = 0;
  integer tog_cyc [0:15];

  // Phase [5]: record the first cycle each barrier pin appears high.
  reg     mon_bar = 1'b0;
  integer bar_cyc0 = -1, bar_cyc1 = -1;

  always @(posedge clk) begin
    #1;
    if (mon_tog) begin
      if (uio_out[0] !== uio0_prev) begin
        if (n_tog < 16) tog_cyc[n_tog] = dut.cycle;
        n_tog = n_tog + 1;
      end
      uio0_prev = uio_out[0];
    end else begin
      uio0_prev = uio_out[0];
    end
    if (mon_bar) begin
      if ((uio_out[0] === 1'b1) && (bar_cyc0 < 0)) bar_cyc0 = dut.cycle;
      if ((uio_out[1] === 1'b1) && (bar_cyc1 < 0)) bar_cyc1 = dut.cycle;
    end
  end

  // ------------------------------------------------------------- helpers
  task tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask

  // Poll an engine's E_STATUS until halted=1; ok=0 on timeout.
  task wait_halted;
    input  integer e;
    input  integer max_polls;
    output integer ok;
    integer k;
    reg [7:0] s;
    reg [15:0] base;
    begin
      base = E0_BASE + 16'h0020 * e[15:0];   // 0x0010 + 0x20*e, e = 0..2
      ok = 0;
      for (k = 0; k < max_polls; k = k + 1) begin
        rd1(base, s);                    // +0x0 E_STATUS
        if (s[1]) begin
          ok = 1;
          k = max_polls;
        end
      end
    end
  endtask

  // --------------------------------------------------------------- test body
  reg [7:0] b0, b1, b2, b3;
  reg [31:0] ts0, ts1, ts2;
  integer    i, ok, itv;
  reg [7:0]  pc_a, pc_b;
  reg [23:0] prog0_snap;      // e0 word0, for the e2-page alias check

  initial begin
    $display("=== PROTEUS end-to-end (real top, real engines) ===");

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    // =====================================================================
    // [0] identity over real SPI traffic
    // =====================================================================
    $display("[0] identity over SPI");
    rd4(RA_ID0, b0, b1, b2, b3);
    chk8(b0, 8'h50, "ID0 = 'P'");
    chk8(b1, 8'h52, "ID1 = 'R'");
    chk8(b2, 8'h02, "VERSION = 0x02 (hybrid)");
    // PING command path (0x07 -> 0x50)
    begin : ping
      reg [7:0] t;
      frame_start;
      spi_byte(8'h07, t);
      spi_byte(8'h00, b0);
      frame_end;
      chk8(b0, 8'h50, "PING response");
    end

    // =====================================================================
    // [1] program load through 0x0100 + i*4 + b byte writes
    // =====================================================================
    $display("[1] program load / readback (byte lanes)");
    // Three separate single-byte frames into word 0: each byte enable must hit
    // exactly one lane, so bytes 0 and 2 must survive the byte-1 write.
    prog_byte(16'h0100 + 0, 8'h34);
    prog_byte(16'h0100 + 1, 8'h12);
    prog_byte(16'h0100 + 2, 8'hAA);
    rd4(RA_PM0, b0, b1, b2, b3);
    chk8(b0, 8'h34, "prog word0 byte0");
    chk8(b1, 8'h12, "prog word0 byte1");
    chk8(b2, 8'hAA, "prog word0 byte2");
    chk24(dut.u_eng0.prog_mem[0], 24'hAA1234, "eng0 prog_mem[0] assembled");
    // rewrite lane 1 only
    prog_byte(16'h0100 + 1, 8'h56);
    rd4(RA_PM0, b0, b1, b2, b3);
    chk8(b0, 8'h34, "byte0 untouched by byte1 rewrite");
    chk8(b1, 8'h56, "byte1 rewritten");
    chk8(b2, 8'hAA, "byte2 untouched by byte1 rewrite");
    chk24(dut.u_eng0.prog_mem[0], 24'hAA5634, "eng0 prog_mem[0] merged");
    // an address past PROG_DEPTH must not alias word 0
    prog_byte(16'h0100 + 32*4, 8'hEE);
    chk24(dut.u_eng0.prog_mem[0], 24'hAA5634, "i=32 write did not alias word0");
    rd1(16'h0100 + 32*4, b0);
    chk8(b0, 8'h00, "i=32 readback is 0");

    // ---- WRITE_INC / READ_INC: the auto-incrementing pointer path ----------
    // WRITE_ADDR/READ_ADDR (used above) carry their own address; these two
    // commands use the 16-bit PTR and advance it after every byte.
    begin : inc_ptr
      reg [7:0] t, i0, i1;
      // PTR <- 0x0520 (UO_OUT).  One data byte per frame: once the command
      // byte is decoded, every later byte in the same frame is payload.
      frame_start;
      spi_byte(8'h03, t); spi_byte(8'h20, t);      // SET_PTR_LO
      frame_end;
      frame_start;
      spi_byte(8'h04, t); spi_byte(8'h05, t);      // SET_PTR_HI
      frame_end;
      frame_start;
      spi_byte(8'h01, t); spi_byte(8'h5A, t);      // WRITE_INC -> 0x0520
      frame_end;
      frame_start;
      spi_byte(8'h01, t); spi_byte(8'hA5, t);      // WRITE_INC -> 0x0521
      frame_end;
      rd1(RA_UO,  i0);
      rd1(RA_UIO, i1);
      chk8(i0, 8'h5A, "WRITE_INC wrote 0x0520 (UO_OUT)");
      chk8(i1, 8'hA5, "WRITE_INC ptr++ -> 0x0521");

      // PTR back to 0x0520, then a READ_INC burst: the command byte is
      // followed by one dummy byte per register read.
      frame_start;
      spi_byte(8'h03, t); spi_byte(8'h20, t);
      frame_end;
      frame_start;
      spi_byte(8'h04, t); spi_byte(8'h05, t);
      frame_end;
      frame_start;
      spi_byte(8'h02, t); spi_byte(8'h00, i0);
      spi_byte(8'h00, i1);
      frame_end;
      chk8(i0, 8'h5A, "READ_INC read 0x0520");
      chk8(i1, 8'hA5, "READ_INC ptr++ -> 0x0521");

      wr1(RA_UIO, 8'h00);
      wr1(RA_UOE, 8'h00);
    end

    // =====================================================================
    // [2] RUN bit 0: PACE loop drives UIO0 at a 16-cycle period
    // =====================================================================
    $display("[2] RUN / PACE loop period + PC advance");
    clr_words;
    // period is 24.8 fixed point: 16.0 cycles = 16 << 8 = 0x1000, so the
    // integer part lives in periods bytes 1..3, not byte 0.
    pwords[0] = enc(OP_CFG,     3'd0, 3'd2, 8'h00, 3'd0);       // period frac
    pwords[1] = enc(OP_CFG,     3'd0, 3'd3, PERIOD[7:0], 3'd0); // period[15:8]
    pwords[2] = enc(OP_CFG,     3'd0, 3'd4, 8'h00, 3'd0);
    pwords[3] = enc(OP_CFG,     3'd0, 3'd5, 8'h00, 3'd0);
    pwords[4] = enc(OP_PACERST, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[5] = enc(OP_PACE,    3'd0, 3'd0, 8'h00, 3'd0);
    pwords[6] = enc(OP_TOGP,    3'd0, {1'b0, BANK_UIO}, 8'h01, 3'd0);
    pwords[7] = enc(OP_JMP,     3'd0, 3'd0, 8'd5, 3'd0);        // -> PACE
    program_load(0, 8);
    program_verify(0, 8);

    rd1(E0_PC, b0);
    chk8(b0, 8'h00, "eng0 PC = 0 while stopped");

    n_tog     = 0;
    uio0_prev = uio_out[0];
    mon_tog   = 1'b1;
    wr1(RA_RUN, 8'h01);                     // run bit 0
    repeat (400) @(posedge clk);
    #2;
    mon_tog = 1'b0;

    // Loop body: PACERST at pc4, then PACE(5) / TOGP(6) / JMP(7).  The first
    // completion is one cycle after PACERST (decision 2 in proteus_engine.v),
    // so the first toggle-to-toggle interval is PERIOD-1 and every later one is
    // exactly PERIOD -- no accumulated drift.
    nchecks = nchecks + 1;
    if (n_tog < 6) begin
      errors = errors + 1;
      $display("FAIL UIO0 toggled only %0d times in 400 cycles (expected >= 6)",
               n_tog);
    end
    itv = tog_cyc[1] - tog_cyc[0];
    chk8(itv[7:0], (PERIOD-1), "first toggle interval = PERIOD-1");
    for (i = 1; i < 5; i = i + 1) begin
      itv = tog_cyc[i+1] - tog_cyc[i];
      nchecks = nchecks + 1;
      if (itv != PERIOD) begin
        errors = errors + 1;
        $display("FAIL toggle interval %0d = %0d, expected %0d (cycles %0d..%0d)",
                 i, itv, PERIOD, tog_cyc[i], tog_cyc[i+1]);
      end
    end
    $display("    toggles=%0d cycles: %0d %0d %0d %0d %0d %0d",
             n_tog, tog_cyc[0], tog_cyc[1], tog_cyc[2], tog_cyc[3],
             tog_cyc[4], tog_cyc[5]);

    // PC is inside the loop body while running, and it is not parked at 0.
    rd1(E0_PC, pc_a);
    rd1(E0_PC, pc_b);
    nchecks = nchecks + 2;
    if (!((pc_a >= 8'd5) && (pc_a <= 8'd7))) begin
      errors = errors + 1;
      $display("FAIL eng0 PC sample 0x%02x outside loop body 5..7", pc_a);
    end
    if (!((pc_b >= 8'd5) && (pc_b <= 8'd7))) begin
      errors = errors + 1;
      $display("FAIL eng0 PC sample 0x%02x outside loop body 5..7", pc_b);
    end
    rd1(E0_STATUS, b0);
    chk1(b0[0], 1'b1, "eng0 E_STATUS run=1 while looping (host wrote RUN)");
    wr1(RA_RUN, 8'h00);                     // stop the loop
    repeat (8) @(posedge clk);

    // =====================================================================
    // [3] registers written by the program, read over the engine window
    // =====================================================================
    $display("[3] program-written registers / output FIFO / HALT retires RUN");
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'hA5, 3'd0);
    pwords[1] = enc(OP_LDI,  3'd1, 3'd0, 8'h3C, 3'd0);
    pwords[2] = enc(OP_LDI,  3'd2, 3'd0, 8'h00, 3'd0);
    pwords[3] = enc(OP_LDI,  3'd3, 3'd0, 8'hFF, 3'd0);
    pwords[4] = enc(OP_ADDI, 3'd0, 3'd0, 8'h01, 3'd0);   // r0 = 0xA6
    pwords[5] = enc(OP_PUSH, 3'd1, 3'd0, 8'h00, 3'd0);   // out FIFO <= 0x3C
    pwords[6] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(0, 7);
    program_verify(0, 7);

    wr1(RA_RUN, 8'h01);
    wait_halted(0, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng0 did not halt within 20 polls");

    rd4(E0_R0, b0, b1, b2, b3);             // r0..r3
    chk8(b0, 8'hA6, "eng0 r0 = 0xA5 + 1 (program-computed)");
    chk8(b1, 8'h3C, "eng0 r1");
    chk8(b2, 8'h00, "eng0 r2");
    chk8(b3, 8'hFF, "eng0 r3");
    rd1(E0_OUT, b0);
    chk8(b0, 8'h3C, "eng0 OUT_FIFO byte from PUSH r1");

    rd1(E0_STATUS, b0);
    chk1(b0[1], 1'b1, "eng0 E_STATUS halted=1 after HALT");
    chk1(b0[0], 1'b0, "eng0 E_STATUS run=0 after HALT (halt_exec)");
    rd1(RA_RUN, b0);
    chk1(b0[0], 1'b0, "RUN register bit0 retired by HALT instruction");

    // =====================================================================
    // [4] capture unit on UIO0, edges generated by engine 0
    // =====================================================================
    $display("[4] capture unit (CAP_EN uio0)");
    wr1(RA_RUN, 8'h00);
    wr1(RA_UOD, 8'h00);
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    repeat (4) @(posedge clk);
    chk1(uio_out[0], 1'b0, "uio0 forced low before capture");

    clr_words;
    pwords[0] = enc(OP_SETP, 3'd0, {1'b0, BANK_UIO}, 8'h01, 3'd0); // rise
    pwords[1] = enc(OP_WAITC,3'd0, 3'd0, 8'd4, 3'd0);
    pwords[2] = enc(OP_CLRP, 3'd0, {1'b0, BANK_UIO}, 8'h01, 3'd0); // fall
    pwords[3] = enc(OP_WAITC,3'd0, 3'd0, 8'd4, 3'd0);
    pwords[4] = enc(OP_SETP, 3'd0, {1'b0, BANK_UIO}, 8'h01, 3'd0); // rise
    pwords[5] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(0, 6);
    program_verify(0, 6);

    wr1(RA_CAP_EN, 8'h01);                 // watch uio0
    rd1(RA_CAP_EN, b0);
    chk8(b0, 8'h01, "CAP_EN readback");
    rd1(RA_CAP_ST, b0);
    chk8(b0[3:0], 4'd0, "CAP_STATUS empty before run");

    wr1(RA_RUN, 8'h01);
    wait_halted(0, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng0 did not halt after the capture program");

    rd1(RA_CAP_ST, b0);
    chk8(b0[3:0], 4'd3, "CAP_STATUS: 3 engine-generated edges");
    chk1(b0[4], 1'b0, "CAP_STATUS overflow clear");

    rd1(RA_CAP_INFO, b0);
    chk8(b0[3:0], 4'd0, "CAP_INFO pin 0 (edge 1)");
    chk1(b0[4], 1'b1, "CAP_INFO level=1 (rising edge 1)");
    rd4(RA_CAP_TS, b0, b1, b2, b3);
    ts0 = {b3, b2, b1, b0};
    nchecks = nchecks + 1;
    if (ts0 == 32'd0) fail("CAP_TS edge 1 is zero");

    wr1(RA_CAP_POP, 8'h01);
    rd1(RA_CAP_INFO, b0);
    chk8(b0[3:0], 4'd0, "CAP_INFO pin 0 (edge 2)");
    chk1(b0[4], 1'b0, "CAP_INFO level=0 (falling edge 2)");
    rd4(RA_CAP_TS, b0, b1, b2, b3);
    ts1 = {b3, b2, b1, b0};
    nchecks = nchecks + 1;
    if (!(ts1 > ts0)) begin
      errors = errors + 1;
      $display("FAIL capture timestamps not increasing: %0d then %0d", ts0, ts1);
    end

    wr1(RA_CAP_POP, 8'h01);
    rd1(RA_CAP_INFO, b0);
    chk1(b0[4], 1'b1, "CAP_INFO level=1 (rising edge 3)");
    rd4(RA_CAP_TS, b0, b1, b2, b3);
    ts2 = {b3, b2, b1, b0};
    nchecks = nchecks + 1;
    if (!(ts2 > ts1)) begin
      errors = errors + 1;
      $display("FAIL capture timestamps not increasing: %0d then %0d", ts1, ts2);
    end

    wr1(RA_CAP_POP, 8'h01);
    rd1(RA_CAP_ST, b0);
    chk8(b0[3:0], 4'd0, "CAP_STATUS empty after 3 pops");
    wr1(RA_CAP_EN, 8'h00);

    // ---- [4a] open-drain: a driven 1 must release the pad ------------------
    // Effective drive is oe & ~(od & out): with od=1 a high releases the pin
    // (high-Z, external pull-up) and a low still pulls it down.  This is the
    // I2C primitive, so it is checked at the pad, not in the register.
    wr1(RA_UIO, 8'h01);
    wr1(RA_UOE, 8'h01);
    wr1(RA_UOD, 8'h01);
    repeat (4) @(posedge clk);
    chk1(uio_oe[0], 1'b0, "od high releases the pad");
    wr1(RA_UIO, 8'h00);                    // open-drain pull-down is driven
    repeat (4) @(posedge clk);
    chk1(uio_oe[0], 1'b1, "od low still drives the pad");
    chk1(uio_out[0], 1'b0, "od low pulls the pin low");
    // A driven low that the pad also reads low is not contention; only a
    // driven-released pad reading high (or a push-pull disagreeing) is.
    wr1(RA_COLL_CLR, 8'h01);
    repeat (4) @(posedge clk);
    rd1(RA_COLLISION, b0);
    chk8(b0, 8'h00, "open-drain low is not recorded as a collision");
    rd1(RA_STATUS, b0);
    chk1(b0[3], 1'b0, "STATUS collision bit stays clear");
    wr1(RA_UOD, 8'h00);
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    repeat (4) @(posedge clk);
    chk1(uio_oe[0], 1'b0, "uio0 released after od check");

    // ---- [4b] capture timestamp width --------------------------------------
    // The event word is {cycle[31:0], pin[3:0], level}.  Bit 31 is unreachable
    // by simulation (2.1e9 clocks), so inject the timebase the same way phase
    // [6] does and require the full 32-bit stamp to come back.
    begin : cap_msb
      reg [7:0] t;
      wr1(RA_RUN, 8'h00);
      clr_words;
      pwords[0] = enc(OP_SETP, 3'd0, {1'b0, BANK_UIO}, 8'h01, 3'd0);
      pwords[1] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
      program_load(0, 2);
      wr1(RA_CAP_EN, 8'h01);
      force dut.cycle = 32'h8000_0000;
      repeat (2) @(posedge clk);
      wr1(RA_RUN, 8'h01);
      wait_halted(0, 20, ok);
      nchecks = nchecks + 1;
      if (!ok) fail("eng0 did not halt in the capture-MSB check");
      release dut.cycle;
      rd1(RA_CAP_ST, t);
      chk8(t[3:0], 4'd1, "one event at the injected cycle");
      rd4(RA_CAP_TS, b0, b1, b2, b3);
      nchecks = nchecks + 1;
      if ({b3, b2, b1, b0} !== 32'h8000_0000) begin
        errors = errors + 1;
        $display("FAIL CAP_TS at injected cycle 0x80000000: got 0x%08x",
                 {b3, b2, b1, b0});
      end
      wr1(RA_CAP_POP, 8'h01);
      wr1(RA_CAP_EN, 8'h00);
      wr1(RA_UIO, 8'h00);
      wr1(RA_UOE, 8'h00);
      // Restore a small timebase: later phases use the cycle value for
      // before/after comparisons and for "not seen yet" sentinels.
      force dut.cycle = 32'd0;
      repeat (2) @(posedge clk);
      release dut.cycle;
    end

    // =====================================================================
    // [4c] 3-engine map: engine 2's page, the window ends, RUN bit width
    // =====================================================================
    $display("[4c] engine 2 page 0x0300 / 3-engine window ends / RUN mask");
    wr1(RA_RUN, 8'h00);
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    repeat (4) @(posedge clk);

    // Loading engine 2's page must not disturb engine 0's.
    prog0_snap = dut.u_eng0.prog_mem[0];
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'hC3, 3'd0);
    pwords[1] = enc(OP_PUSH, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[2] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(2, 3);
    program_verify(2, 3);
    chk24(dut.u_eng0.prog_mem[0], prog0_snap,
          "e2 page load left e0 word0 untouched");
    chk24(dut.u_eng2.prog_mem[0], enc(OP_LDI, 3'd0, 3'd0, 8'hC3, 3'd0),
          "eng2 prog_mem[0] assembled from 0x0300");

    // 0x0400 is the v1 engine-3 page: outside the 3-engine map, dropped.
    prog_byte(16'h0400, 8'hEE);
    rd1(16'h0400, b0);
    chk8(b0, 8'h00, "0x0400 outside the 3-engine program map (reads 0)");
    chk24(dut.u_eng2.prog_mem[0], enc(OP_LDI, 3'd0, 3'd0, 8'hC3, 3'd0),
          "0x0400 write did not alias e2 word0");

    // Engine 2's window is writable at base 0x0050 (the write decode has its
    // own end-of-window compare).
    wr1(E2_R0, 8'h99);
    rd1(E2_R0, b0);
    chk8(b0, 8'h99, "e2 r0 window write/readback at 0x0054");

    // Engine window ends at 0x006F; 0x0070 must not alias engine 0.
    rd1(16'h006F, b0);
    chk8(b0, 8'h00, "0x006F is e2 +0x1F (reserved, reads 0)");
    rd1(E0_R0, b2);
    wr1(16'h0070, 8'h5A);
    rd1(16'h0070, b0);
    chk8(b0, 8'h00, "0x0070 outside the engine window (reads 0)");
    rd1(E0_R0, b0);
    chk8(b0, b2, "0x0070 write did not alias e0 r0");

    // RUN is 3 bits wide: bit 3 does not exist, bit 2 selects engine 2.
    // Checking the bit with a program that ENDS would race the HALT that
    // retires it (the read frame alone costs ~280 clocks), so the mask check
    // uses the same never-ending JMP 0 loop phase [2] uses for engine 0.
    wr1(RA_RUN, 8'h08);
    rd1(RA_RUN, b0);
    chk8(b0, 8'h00, "RUN bit3 ignored (3-bit run register)");

    clr_words;
    pwords[0] = enc(OP_JMP, 3'd0, 3'd0, 8'd0, 3'd0);
    program_load(2, 1);
    wr1(RA_RUN, 8'h04);
    rd1(RA_RUN, b0);
    chk8(b0, 8'h04, "RUN bit2 selects engine 2");
    rd1(E2_STATUS, b0);
    chk1(b0[0], 1'b1, "eng2 E_STATUS run=1 while looping");
    // RA_HALT clears the RUN bits it is given, without touching the others.
    wr1(RA_HALT, 8'h04);
    rd1(RA_RUN, b0);
    chk8(b0[2:0], 3'b000, "RA_HALT write clears RUN bit 2");
    rd1(E2_STATUS, b0);
    chk1(b0[0], 1'b0, "eng2 stops when RA_HALT clears its RUN bit");
    repeat (4) @(posedge clk);

    // Reload the terminating program: its HALT must retire RUN bit 2, and the
    // two pushes must drain in order -- reading OUT_FIFO is what pops it, so a
    // second read returning the first byte would mean the pop went to engine 0.
    clr_words;
    pwords[0] = enc(OP_LDI,   3'd0, 3'd0, 8'hC3, 3'd0);
    pwords[1] = enc(OP_PUSH,  3'd0, 3'd0, 8'h00, 3'd0);
    pwords[2] = enc(OP_LDI,   3'd0, 3'd0, 8'hD4, 3'd0);
    pwords[3] = enc(OP_PUSH,  3'd0, 3'd0, 8'h00, 3'd0);
    pwords[4] = enc(OP_IRQSET, 3'd0, 3'd0, 8'd0, 3'd0);  // irq bit 0
    pwords[5] = enc(OP_HALT,  3'd0, 3'd0, 8'h00, 3'd0);
    program_load(2, 6);
    program_verify(2, 6);
    wr1(RA_RUN, 8'h04);
    wait_halted(2, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng2 did not halt within 20 polls");
    rd1(E2_OUT, b0);
    chk8(b0, 8'hC3, "eng2 OUT_FIFO byte from PUSH");
    rd1(E2_OUT, b0);
    chk8(b0, 8'hD4, "eng2 OUT_FIFO second byte: the host pop is routed to e2");
    rd1(E2_STATUS, b0);
    chk1(b0[1], 1'b1, "eng2 E_STATUS halted=1 after HALT");
    rd1(RA_RUN, b0);
    chk8(b0[2:0], 3'b000, "RUN bit2 retired by HALT on engine 2");

    // Engine 2's IRQSET reached the IRQ register (3-engine OR chain), and
    // IRQ_ACK clears the bit.
    rd1(RA_IRQ_ST, b0);
    chk8(b0, 8'h01, "eng2 IRQSET sets IRQ_STATUS bit 0");
    wr1(RA_IRQ_ACK, 8'h01);
    rd1(RA_IRQ_ST, b0);
    chk8(b0, 8'h00, "IRQ_ACK clears IRQ_STATUS bit 0");

    // A host write to engine 2's IN_FIFO is pushed into engine 2, not engine 0:
    // PULL -> PUSH through the engine proves which queue received it.
    clr_words;
    pwords[0] = enc(OP_PULL, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[1] = enc(OP_PUSH, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[2] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(2, 3);
    program_verify(2, 3);
    wr1(E2_IN, 8'h7E);
    wr1(RA_RUN, 8'h04);
    wait_halted(2, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng2 did not halt after the IN_FIFO push");
    rd1(E2_OUT, b0);
    chk8(b0, 8'h7E, "IN_FIFO write is routed to engine 2 (PULL saw the byte)");

    // The assist FIFO is empty again: an LDAS of FIFO DATA must take the
    // empty-read path for ENGINE 2 (nf set, rd unchanged), not just engine 0.
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'h66, 3'd0);
    pwords[1] = enc(OP_LDAS, 3'd0, 3'd0, 8'h01, 3'd0);  // FIFO DATA, empty
    pwords[2] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(2, 3);
    program_verify(2, 3);
    wr1(RA_RUN, 8'h04);
    wait_halted(2, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng2 did not halt after the empty LDAS");
    rd1(E2_R0, b0);
    chk8(b0, 8'h66, "eng2 empty FIFO DATA read leaves rd unchanged");
    rd1(E2_STATUS, b0);
    chk1(b0[6], 1'b1, "eng2 empty FIFO DATA read sets nf");
    wr1(RA_RUN, 8'h00);
    repeat (4) @(posedge clk);

    // =====================================================================
    // [4d] assist CSR bank: 0x0600 + 0x10*id + reg, host and engine paths
    // =====================================================================
    $display("[4d] assist CSR window 0x0600 (host register + engine LDAS/STAS)");

    // PINCFG is host-only (reg 8 of the stride) and resets to 0, i.e. no
    // assist owns any pin until the host says so.
    rd1(AS_PINCFG_MANCH, b0);
    chk8(b0, 8'h00, "MANCH PINCFG resets to 0 (no assist pin ownership)");
    wr1(AS_PINCFG_MANCH, 8'h48);
    rd1(AS_PINCFG_MANCH, b0);
    chk8(b0, 8'h48, "MANCH PINCFG host write/readback");
    // ... and it is not part of the 8-register engine view: reg 0x0648 is
    // writable by the host only, reg 0x0643 (MANCH CFG) reads back instead.
    rd1(16'h0643, b0);
    chk8(b0, 8'h44, "MANCH r3 reports HALF_DIV=4 / OS=4");
    // The window ends at 0x064F.
    rd1(16'h0650, b0);
    chk8(b0, 8'h00, "0x0650 outside the assist CSR window (reads 0)");

    // Host path to a writable CSR register.
    wr1(AS_NRZI_DIV, 8'h0A);
    rd1(AS_NRZI_DIV, b0);
    chk8(b0, 8'h0A, "NRZI DIV host write/readback");

    // Host path through the FIFO assist: a DATA write pushes, a DATA read pops.
    wr1(AS_FIFO_DATA, 8'h5C);
    rd1(AS_FIFO_STATUS, b0);
    chk8(b0, 8'h01, "host FIFO DATA write pushes (level=1)");
    rd1(AS_FIFO_DATA, b0);
    chk8(b0, 8'h5C, "host FIFO DATA read returns the pushed byte");
    rd1(AS_FIFO_STATUS, b0);
    chk8(b0, 8'h20, "host FIFO DATA read pops (level 0, empty)");

    // Engine path: STAS writes DIV, LDAS reads it back, STAS/LDAS round-trip
    // the FIFO DATA register, and an empty DATA read sets nf / keeps rd.
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'h0B, 3'd0);  // r0 = 0x0B
    pwords[1] = enc(OP_STAS, 3'd0, 3'd3, 8'h03, 3'd0);  // DIV      <- r0
    pwords[2] = enc(OP_LDAS, 3'd1, 3'd3, 8'h03, 3'd0);  // r1 <- DIV
    pwords[3] = enc(OP_LDI,  3'd2, 3'd0, 8'h5A, 3'd0);  // r2 = 0x5A
    pwords[4] = enc(OP_STAS, 3'd2, 3'd0, 8'h01, 3'd0);  // FIFO DATA <- r2 (push)
    pwords[5] = enc(OP_LDAS, 3'd3, 3'd0, 8'h01, 3'd0);  // r3 <- FIFO DATA (pop)
    pwords[6] = enc(OP_LDI,  3'd4, 3'd0, 8'h77, 3'd0);  // r4 sentinel
    pwords[7] = enc(OP_LDAS, 3'd4, 3'd0, 8'h01, 3'd0);  // empty read: nf
    pwords[8] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(0, 9);
    program_verify(0, 9);
    wr1(RA_RUN, 8'h01);
    wait_halted(0, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng0 did not halt in the assist CSR check");

    rd1(E0_R0 + 1, b0);
    chk8(b0, 8'h0B, "LDAS read the value STAS wrote to the CSR bank");
    rd1(AS_NRZI_DIV, b0);
    chk8(b0, 8'h0B, "engine STAS reached the NRZI DIV register");
    rd1(E0_R0 + 3, b0);
    chk8(b0, 8'h5A, "LDAS popped the FIFO DATA byte pushed by STAS");
    rd1(AS_FIFO_STATUS, b0);
    chk8(b0, 8'h20, "FIFO drained after the pop (empty=1, level=0)");
    rd1(E0_R0 + 4, b0);
    chk8(b0, 8'h77, "empty FIFO DATA read leaves rd unchanged");
    rd1(E0_STATUS, b0);
    chk1(b0[6], 1'b1, "empty FIFO DATA read sets nf");

    // Assist write arbitration: two engines, identical-length programs, so both
    // STAS land in the same cycle; the highest engine index must win.
    wr1(RA_RUN, 8'h00);
    repeat (4) @(posedge clk);
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'h11, 3'd0);
    pwords[1] = enc(OP_STAS, 3'd0, 3'd3, 8'h03, 3'd0);
    pwords[2] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(0, 3);
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'h22, 3'd0);
    pwords[1] = enc(OP_STAS, 3'd0, 3'd3, 8'h03, 3'd0);
    pwords[2] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(1, 3);
    wr1(RA_RUN, 8'h03);
    wait_halted(0, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng0 did not halt in the assist arbitration check");
    wait_halted(1, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng1 did not halt in the assist arbitration check");
    rd1(AS_NRZI_DIV, b0);
    chk8(b0, 8'h22, "assist write arbitration: engine 1 beats engine 0");

    // Same cycle, DIFFERENT assists: only the highest index's write lands, so
    // engine 1's DIV write must be dropped and engine 2's CFG0 write kept --
    // and engine 2's ASST must reach its own assist id.
    wr1(RA_RUN, 8'h00);
    repeat (4) @(posedge clk);
    wr1(AS_NRZI_DIV, 8'h15);               // pre-image: must NOT change
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'h22, 3'd0);
    pwords[1] = enc(OP_STAS, 3'd0, 3'd3, 8'h03, 3'd0);  // assist 3 reg 3 = DIV
    pwords[2] = enc(OP_NOP,  3'd0, 3'd0, 8'h00, 3'd0);
    pwords[3] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(1, 4);
    program_verify(1, 4);
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'h3F, 3'd0);
    pwords[1] = enc(OP_STAS, 3'd0, 3'd2, 8'h00, 3'd0);  // assist 0 reg 2 = CFG0
    pwords[2] = enc(OP_ASST, 3'd0, 3'd0, 8'd9,  3'd0);  // CRC: page = poly
    pwords[3] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(2, 4);
    program_verify(2, 4);
    wr1(RA_RUN, 8'h06);                     // engines 1 and 2 together
    wait_halted(1, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng1 did not halt in the assist conflict check");
    wait_halted(2, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng2 did not halt in the assist conflict check");
    rd1(AS_NRZI_DIV, b0);
    chk8(b0, 8'h15, "engine 1's same-cycle write lost to engine 2 (arbitration)");
    rd1(AS_CRC_CFG0, b0);
    chk8(b0, 8'h3F, "engine 2's write reached its own assist register");
    rd1(AS_CRC_PAGE, b0);
    chk8(b0, 8'h02, "engine 2's ASST reached its own assist id (CRC page)");

    // Engine 2 writing ALONE must reach the bank as well: the conflict test
    // above only shows the payload mux selects engine 2's fields when both
    // engines strobe together.
    wr1(RA_RUN, 8'h00);
    repeat (4) @(posedge clk);
    clr_words;
    pwords[0] = enc(OP_LDI,  3'd0, 3'd0, 8'h37, 3'd0);
    pwords[1] = enc(OP_STAS, 3'd0, 3'd3, 8'h03, 3'd0);  // assist 3 reg 3 = DIV
    pwords[2] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(2, 3);
    program_verify(2, 3);
    wr1(RA_RUN, 8'h04);
    wait_halted(2, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng2 did not halt in the solo assist write check");
    rd1(AS_NRZI_DIV, b0);
    chk8(b0, 8'h37, "engine 2 writing alone reaches the CSR bank");
    wr1(RA_RUN, 8'h00);
    repeat (4) @(posedge clk);

    // =====================================================================
    // [4e] assist pin stage: PINCFG en=1 makes the assist own the pad
    // =====================================================================
    $display("[4e] assist pin ownership (PINCFG en=1) and the push-pull stage");
    // MANCH (id 4) owns one TX pin whenever PINCFG[7] is set; its idle drive is
    // 0.  Priority is host > assist > engine, and assist pins are push-pull, so
    // the stage clears open-drain for the bits it owns.
    // (a) bank UO (1), tx_base 7 -> PINCFG = 0x80 | 0x20 | 0x1C = 0xBC
    wr1(RA_UO, 8'h00);
    repeat (4) @(posedge clk);
    chk1(uo_out[7], 1'b0, "uo_out[7] holds the host value before PINCFG");
    wr1(AS_PINCFG_MANCH, 8'hBC);
    repeat (4) @(posedge clk);
    chk1(uo_out[7], 1'b1, "assist owns uo[7]: its idle 1 beats the host 0");
    chk1(uo_out[6], 1'b0, "assist owns only its own bit (uo[6] untouched)");

    // (b) bank UIO (2), tx_base 3 -> PINCFG = 0x80 | 0x40 | 0x0C = 0xCC
    wr1(RA_UOE, 8'hFF);
    wr1(RA_UIO, 8'hFF);
    wr1(RA_UOD, 8'hFF);                     // all open-drain: every pin released
    repeat (4) @(posedge clk);
    chk1(uio_oe[3], 1'b0, "open-drain high releases uio[3] before PINCFG");
    wr1(AS_PINCFG_MANCH, 8'hCC);
    repeat (4) @(posedge clk);
    chk1(uio_oe[3], 1'b1, "assist pin is push-pull: OE forced on despite od");
    chk1(uio_oe[2], 1'b0, "unowned open-drain pin stays released");
    // ... and the assist's own level reaches the pad over a 0 host value.
    wr1(RA_UOD, 8'h00);
    wr1(RA_UIO, 8'h00);
    repeat (4) @(posedge clk);
    chk1(uio_out[3], 1'b1, "assist drives its idle 1 onto uio[3] over the host 0");

    wr1(AS_PINCFG_MANCH, 8'h00);
    wr1(RA_UOD, 8'h00);
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    wr1(RA_UO, 8'h00);
    repeat (4) @(posedge clk);
    chk1(uio_oe[3], 1'b0, "uio[3] released again after PINCFG en=0");

    // =====================================================================
    // [5] two-engine barrier: same-cycle release
    // =====================================================================
    $display("[5] BAR 0 across engines 0 and 1");
    wr1(RA_RUN, 8'h00);
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    repeat (4) @(posedge clk);
    chk8(uio_out[1:0], 2'b00, "uio[1:0] clear before the barrier test");

    // Engine 0 reaches BAR 0 after one instruction; engine 1 needs three NOPs.
    // They can only leave the barrier in the same cycle if BAR actually syncs.
    clr_words;
    pwords[0] = enc(OP_NOP, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[1] = enc(OP_BAR, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[2] = enc(OP_SETP, 3'd0, {1'b0, BANK_UIO}, 8'h01, 3'd0);
    pwords[3] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(0, 4);
    program_verify(0, 4);

    clr_words;
    pwords[0] = enc(OP_NOP, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[1] = enc(OP_NOP, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[2] = enc(OP_NOP, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[3] = enc(OP_BAR, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[4] = enc(OP_SETP, 3'd0, {1'b0, BANK_UIO}, 8'h02, 3'd0);
    pwords[5] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(1, 6);
    program_verify(1, 6);

    bar_cyc0 = -1;
    bar_cyc1 = -1;
    mon_bar  = 1'b1;
    wr1(RA_RUN, 8'h03);                    // engines 0 and 1 together
    wait_halted(0, 40, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng0 did not leave the barrier within 40 polls");
    wait_halted(1, 40, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng1 did not leave the barrier within 40 polls");
    repeat (4) @(posedge clk);
    #2;
    mon_bar = 1'b0;

    $display("    barrier pin cycles: uio0=%0d uio1=%0d", bar_cyc0, bar_cyc1);
    nchecks = nchecks + 1;
    if ((bar_cyc0 < 0) || (bar_cyc1 < 0)) begin
      errors = errors + 1;
      $display("FAIL barrier pins never asserted (uio0=%0d uio1=%0d)",
               bar_cyc0, bar_cyc1);
    end
    nchecks = nchecks + 1;
    if (bar_cyc0 != bar_cyc1) begin
      errors = errors + 1;
      $display("FAIL barrier released engines in different cycles: uio0 at %0d, uio1 at %0d (%0d cycles apart)",
               bar_cyc0, bar_cyc1, bar_cyc1 - bar_cyc0);
    end
    chk8(uio_out[1:0], 2'b11, "both barrier pins driven afterwards");
    rd1(RA_RUN, b0);
    chk8(b0[1:0], 2'b00, "RUN bits retired by HALT on both engines");

    // =====================================================================
    // [6] pacer across the 2^24 boundary (32-bit integer deadline)
    // =====================================================================
    $display("[6] PACE past cycle 2^24");
    wr1(RA_RUN, 8'h00);
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    repeat (4) @(posedge clk);

    // period = 256.0 cycles = 0x10000 in 24.8 -> period[23:16] = 0x01
    clr_words;
    pwords[0] = enc(OP_CFG,     3'd0, 3'd2, 8'h00, 3'd0);
    pwords[1] = enc(OP_CFG,     3'd0, 3'd3, 8'h00, 3'd0);
    pwords[2] = enc(OP_CFG,     3'd0, 3'd4, 8'h01, 3'd0);
    pwords[3] = enc(OP_CFG,     3'd0, 3'd5, 8'h00, 3'd0);
    pwords[4] = enc(OP_PACERST, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[5] = enc(OP_PACE,    3'd0, 3'd0, 8'h00, 3'd0);
    pwords[6] = enc(OP_TOGP,    3'd0, {1'b0, BANK_UIO}, 8'h01, 3'd0);
    pwords[7] = enc(OP_JMP,     3'd0, 3'd0, 8'd5, 3'd0);
    program_load(0, 8);
    program_verify(0, 8);

    // Inject the cycle counter just below 2^24 instead of simulating 16.7M
    // clocks.  While forced the top's own increment is ignored; on release the
    // variable keeps the forced value (IEEE 1364 9.3.2), which the readback
    // below proves -- if it were restored the boundary check would fail.
    force dut.cycle = 32'h00FF_FF00;
    rd4(RA_CYCLE0, b0, b1, b2, b3);
    nchecks = nchecks + 1;
    if ({b3, b2, b1, b0} != 32'h00FF_FF00) begin
      errors = errors + 1;
      $display("FAIL cycle injection: got 0x%08x", {b3, b2, b1, b0});
    end
    release dut.cycle;
    rd4(RA_CYCLE0, b0, b1, b2, b3);
    nchecks = nchecks + 1;
    if ({b3, b2, b1, b0} < 32'h00FF_FF00) begin
      errors = errors + 1;
      $display("FAIL cycle counter fell back after release: 0x%08x",
               {b3, b2, b1, b0});
    end
    $display("    cycle after injection = 0x%08x", {b3, b2, b1, b0});

    n_tog     = 0;
    uio0_prev = uio_out[0];
    mon_tog   = 1'b1;
    wr1(RA_RUN, 8'h01);
    repeat (3300) @(posedge clk);
    #2;
    mon_tog = 1'b0;

    nchecks = nchecks + 1;
    if (n_tog < 8) begin
      errors = errors + 1;
      $display("FAIL pacer produced only %0d completions past 2^24", n_tog);
    end
    itv = tog_cyc[1] - tog_cyc[0];
    chk8(itv[7:0], 8'd255, "first interval past 2^24 = period-1");
    for (i = 1; i < 6; i = i + 1) begin
      itv = tog_cyc[i+1] - tog_cyc[i];
      nchecks = nchecks + 1;
      if (itv != 256) begin
        errors = errors + 1;
        $display("FAIL pacer interval %0d past 2^24 = %0d, expected 256 (cycles 0x%08x..0x%08x)",
                 i, itv, tog_cyc[i], tog_cyc[i+1]);
      end
    end
    rd4(RA_CYCLE0, b0, b1, b2, b3);
    $display("    cycle now 0x%08x, toggles=%0d", {b3, b2, b1, b0}, n_tog);
    nchecks = nchecks + 1;
    if ({b3, b2, b1, b0} <= 32'h0100_0000) begin
      errors = errors + 1;
      $display("FAIL pacer never crossed 2^24 (cycle 0x%08x)", {b3, b2, b1, b0});
    end
    // the next_int deadlines must have crossed the old 24-bit horizon too:
    // toggles 1..n all happened at cycle >= 0x01000000
    nchecks = nchecks + 1;
    if (tog_cyc[n_tog-1] < 32'h0100_0000) begin
      errors = errors + 1;
      $display("FAIL last completion at 0x%08x is below 2^24", tog_cyc[n_tog-1]);
    end
    wr1(RA_RUN, 8'h00);

    // =====================================================================
    // [7] run-rising restart must not execute the stale-PC instruction
    // =====================================================================
    $display("[7] restart does not execute the stale PC");
    wr1(RA_RUN, 8'h00);
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    wr1(E0_R0, 8'h55);                     // r0 = 0x55 while the engine is stopped
    repeat (4) @(posedge clk);

    // Park the engine with pc == 0 deterministically: JMP 0 keeps pc at 0.
    clr_words;
    pwords[0] = enc(OP_JMP, 3'd0, 3'd0, 8'd0, 3'd0);
    program_load(0, 1);
    wr1(RA_RUN, 8'h01);
    repeat (20) @(posedge clk);
    wr1(RA_RUN, 8'h00);
    repeat (4) @(posedge clk);
    rd1(E0_PC, b0);
    chk8(b0, 8'h00, "engine parked at PC 0");

    // Word 0 of the next program is a side-effecting PUSH r0.  If the restart
    // executed the stale PC, that push fires once with the pre-load r0 and the
    // FIFO ends up with 0x55,0x55 instead of 0x55,0xAA.
    clr_words;
    pwords[0] = enc(OP_PUSH, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[1] = enc(OP_LDI,  3'd0, 3'd0, 8'hAA, 3'd0);
    pwords[2] = enc(OP_PUSH, 3'd0, 3'd0, 8'h00, 3'd0);
    pwords[3] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(0, 4);
    program_verify(0, 4);
    wr1(RA_RUN, 8'h01);
    wait_halted(0, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng0 did not halt in the restart check");
    rd1(E0_OUT, b0);
    chk8(b0, 8'h55, "first pushed byte (post-load r0)");
    rd1(E0_OUT, b1);
    chk8(b1, 8'hAA, "second pushed byte proves no phantom push");

    // =====================================================================
    // [8] HOST_DISABLE: fabric owns uo_out[1:0], MISO stops driving
    // =====================================================================
    $display("[8] HOST_DISABLE handover");
    wr1(RA_RUN, 8'h00);
    wr1(RA_UO, 8'h00);
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    wr1(RA_UOD, 8'h00);
    repeat (4) @(posedge clk);

    // Program: set uo_out[1:0] (host-owned MISO/IRQ pins) then uio[7].
    clr_words;
    pwords[0] = enc(OP_SETP, 3'd0, {1'b0, BANK_UO}, 8'h03, 3'd0);
    pwords[1] = enc(OP_SETP, 3'd0, {1'b0, BANK_UIO}, 8'h80, 3'd0);
    pwords[2] = enc(OP_HALT, 3'd0, 3'd0, 8'h00, 3'd0);
    program_load(0, 3);
    program_verify(0, 3);

    // While the host owns the pins the uo_out write must be dropped ...
    wr1(RA_RUN, 8'h01);
    wait_halted(0, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng0 did not halt before HOST_DISABLE");
    repeat (4) @(posedge clk);
    chk1(dut.host_en, 1'b1, "host_en=1 before HOST_DISABLE");
    chk8(uo_out[1:0], 2'b00, "uo_out[1:0] host-owned: engine write dropped");
    chk1(uio_out[7], 1'b1, "uio[7] fabric-owned: engine write landed");
    chk1(uio_oe[7], 1'b1, "uio[7] auto-OE set by the engine write");

    // ... HOST_DISABLE releases them.
    begin : host_dis
      reg [7:0] t;
      frame_start;
      spi_byte(8'h09, t);                  // HOST_DISABLE command
      frame_end;
    end
    repeat (4) @(posedge clk);
    chk1(dut.host_en, 1'b0, "host_en=0 after HOST_DISABLE");

    // Clear the fabric registers, restart the same program, and check that the
    // uo_out and uio writes now reach the pins.
    wr1(RA_UO, 8'h00);                     // host register writes still decode
    wr1(RA_UIO, 8'h00);
    wr1(RA_UOE, 8'h00);
    repeat (4) @(posedge clk);
    chk8(uo_out[1:0], 2'b00, "uo_out[1:0] cleared");
    chk1(uio_out[7], 1'b0, "uio[7] cleared");
    wr1(RA_RUN, 8'h01);                    // run-rising restarts at PC 0
    wait_halted(0, 20, ok);
    nchecks = nchecks + 1;
    if (!ok) fail("eng0 did not halt after HOST_DISABLE");
    repeat (4) @(posedge clk);
    chk8(uo_out[1:0], 2'b11, "uo_out[1:0] fabric-owned: engine write landed");
    chk1(uio_out[7], 1'b1, "uio[7] engine write landed after disable");

    // MISO is no longer routed to uo_out[0]: keep a frame open and clock data.
    // The pin must stay at the fabric value (1) while the slave's MISO is 0.
    begin : miso_check
      reg [7:0] t;
      frame_start;
      spi_byte(8'h00, t);
      spi_byte(8'h00, t);
      // still inside the frame (CS_N low): compare pin against the slave MISO
      chk1(cs_n, 1'b0, "frame open during MISO check");
      chk1(uo_out[0], 1'b1, "uo_out[0] holds the fabric value inside a frame");
      chk1(dut.miso, 1'b0, "host MISO output is idle-low");
      nchecks = nchecks + 1;
      if (uo_out[0] === dut.miso) begin
        errors = errors + 1;
        $display("FAIL uo_out[0] still tracks MISO after HOST_DISABLE");
      end
      frame_end;
    end
    chk1(dut.host_en, 1'b0, "host_en still 0 after a post-disable frame");

    // =====================================================================
    $display("--- top_e2e_tb: %0d checks, %0d errors ---", nchecks, errors);
    if (errors != 0) $fatal(1, "top_e2e_tb FAILED");
    $display("top_e2e_tb PASSED");
    $finish;
  end

  // Watchdog: a hung test must not look like a pass.
  initial begin
    #(CLKP * 400000);
    $display("FAIL top_e2e_tb watchdog timeout");
    $fatal(1, "top_e2e_tb TIMEOUT");
  end

endmodule

`default_nettype wire
