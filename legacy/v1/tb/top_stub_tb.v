// ===========================================================================
// tb/top_stub_tb.v -- tt_um_proteus with the TESTBENCH stub engine.
//
// Compiles the whole top before the real engine exists and exercises the
// register map end to end over real SPI mode-0 traffic:
//   * ID / VERSION / STATUS, CYCLE counter
//   * engine windows on all four engines (regs, period bytes, E_PC, E_STATUS)
//     window base = 0x0010 + 0x20*e (see the geometry decision in the top)
//   * program memory byte writes + readback on engines 0, 1 and 3, including
//     the i >= PROG_DEPTH drop / read-0 rule
//   * IN_FIFO push / OUT_FIFO pop on engine 3
//   * pin registers, effective UIO OE with open-drain release, collision reg
//   * capture FIFO: enable, edge, TS/INFO/count, pop
//   * IRQ_ENABLE, RUN/HALT, HOST_DISABLE pin handover, SOFT_RESET
//
// Exit status: 1 on any failure ($fatal), 0 on success.
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module top_stub_tb;

  localparam CLKP = 10;

  reg clk = 1'b0;
  always #(5) clk = ~clk;

  reg  rst_n = 1'b0;
  reg  [7:0] ui_in  = 8'h02;     // SPI idle: SCK=0, CS_N=1, MOSI=0 (never X)
  reg  [7:0] uio_ext = 8'h00;    // externally driven level on uio
  wire [7:0] uio_in;             // resolved wired-OR of external + chip
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  // SPI pins live on ui_in[2:0] / uo_out[0]
  reg  sck  = 1'b0;
  reg  cs_n = 1'b1;
  reg  mosi = 1'b0;
  wire miso;
  always @* begin
    ui_in[0] = sck;
    ui_in[1] = cs_n;
    ui_in[2] = mosi;
    ui_in[7:3] = 5'b00011;
  end
  assign miso = uo_out[0];

  // Model the pad: the chip's driven value and the external driver share the
  // same wire (high wins), so collision detection sees a consistent level.
  assign uio_in = uio_ext | (uio_out & uio_oe);

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
  integer errors = 0;
  integer nchecks = 0;

  task check8;
    input [7:0] got;
    input [7:0] exp;
    input [255:0] what;
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got 0x%02x expected 0x%02x (t=%0t)",
                 what, got, exp, $time);
      end
    end
  endtask

  task check24;
    input [23:0] got;
    input [23:0] exp;
    input [255:0] what;
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got 0x%06x expected 0x%06x (t=%0t)",
                 what, got, exp, $time);
      end
    end
  endtask

  // ------------------------------------------------------------- SPI master
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
        mi[b] = miso;
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
      #(CLKP*8);
    end
  endtask

  task frame_end;
    begin
      #(CLKP*6);
      cs_n = 1'b1;
      #(CLKP*10);
    end
  endtask

  task wr1;
    input [15:0] a;
    input [7:0]  d;
    reg   [7:0]  t;
    begin
      frame_start;
      spi_byte(8'h05, t);        // WRITE_ADDR
      spi_byte(a[7:0],  t);
      spi_byte(a[15:8], t);
      spi_byte(d,       t);
      frame_end;
    end
  endtask

  task rd1;
    input  [15:0] a;
    output [7:0]  d;
    reg    [7:0]  t;
    begin
      frame_start;
      spi_byte(8'h06, t);        // READ_ADDR
      spi_byte(a[7:0],  t);
      spi_byte(a[15:8], t);
      spi_byte(8'h00,   d);
      frame_end;
    end
  endtask

  // read n consecutive bytes from a (READ_ADDR + auto-inc)
  task rdn;
    input  [15:0] a;
    input  [3:0]  n;
    output [7:0]  d0, d1, d2, d3;
    reg    [7:0]  t;
    begin
      d0 = 8'h00; d1 = 8'h00; d2 = 8'h00; d3 = 8'h00;
      frame_start;
      spi_byte(8'h06, t);
      spi_byte(a[7:0],  t);
      spi_byte(a[15:8], t);
      if (n >= 1) spi_byte(8'h00, d0);
      if (n >= 2) spi_byte(8'h00, d1);
      if (n >= 3) spi_byte(8'h00, d2);
      if (n >= 4) spi_byte(8'h00, d3);
      frame_end;
      // outputs are left untouched for n < given count
      if (n < 2) d1 = 8'h00;
      if (n < 3) d2 = 8'h00;
      if (n < 4) d3 = 8'h00;
    end
  endtask

  // ------------------------------------------------------------- test body
  reg [7:0] b0, b1, b2, b3;
  reg [31:0] cyc_a, cyc_b;

  initial begin
    $display("=== tt_um_proteus top_stub_tb ===");
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    // ---- IDs ------------------------------------------------------------
    rdn(16'h0000, 4'd3, b0, b1, b2, b3);
    check8(b0, 8'h50, "ID0 'P'");
    check8(b1, 8'h52, "ID1 'R'");
    check8(b2, 8'h01, "VERSION");

    // ---- engine registers on every engine -------------------------------
    wr1(16'h0014, 8'h5A);   // engine 0 r0
    rd1(16'h0014, b0);
    check8(b0, 8'h5A, "eng0 r0 readback");

    wr1(16'h0034, 8'hA1);   // engine 1 r0 (base 0x0030 + 0x4)
    rd1(16'h0034, b0);
    check8(b0, 8'hA1, "eng1 r0 readback");

    wr1(16'h0054, 8'hC2);   // engine 2 r0 (base 0x0050 + 0x4)
    rd1(16'h0054, b0);
    check8(b0, 8'hC2, "eng2 r0 readback");

    wr1(16'h0074, 8'hD3);   // engine 3 r0 (base 0x0070 + 0x4)
    rd1(16'h0074, b0);
    check8(b0, 8'hD3, "eng3 r0 readback");

    // ---- period bytes (window +0xC.. -> hr 8..11) -----------------------
    wr1(16'h005C, 8'h11);   // engine 2 period byte 0 (base+0xC)
    rd1(16'h005C, b0);
    check8(b0, 8'h11, "eng2 period0 readback");
    wr1(16'h005F, 8'h99);   // engine 2 period byte 3 (base+0xF)
    rd1(16'h005F, b0);
    check8(b0, 8'h99, "eng2 period3 readback");

    // ---- E_PC / E_STATUS / E_ERROR on engine 1 --------------------------
    rd1(16'h0030, b0);      // E_STATUS (engine 1 base)
    check8(b0[1:0], 2'b10, "eng1 E_STATUS: halted=1 run=0 while stopped");
    rd1(16'h0033, b0);      // E_ERROR
    check8(b0, 8'h00, "eng1 E_ERROR clear");

    // ---- program memory: engine 0 ---------------------------------------
    frame_start;
    spi_byte(8'h05, b0);    // WRITE_ADDR 0x0100
    spi_byte(8'h00, b0);
    spi_byte(8'h01, b0);
    spi_byte(8'h11, b0);    // byte 0
    spi_byte(8'h22, b0);    // byte 1
    spi_byte(8'h33, b0);    // byte 2
    frame_end;
    rdn(16'h0100, 4'd3, b0, b1, b2, b3);
    check8(b0, 8'h11, "prog eng0 word0 byte0");
    check8(b1, 8'h22, "prog eng0 word0 byte1");
    check8(b2, 8'h33, "prog eng0 word0 byte2");
    check24(dut.u_eng0.prog[0], 24'h332211, "eng0 prog[0] assembled (3 lanes)");

    // ---- program memory: engine 1 (0x0200) ------------------------------
    frame_start;
    spi_byte(8'h05, b0);    // WRITE_ADDR 0x0200
    spi_byte(8'h00, b0);
    spi_byte(8'h02, b0);
    spi_byte(8'h44, b0);
    spi_byte(8'h55, b0);
    spi_byte(8'h66, b0);
    frame_end;
    rdn(16'h0200, 4'd3, b0, b1, b2, b3);
    check8(b0, 8'h44, "prog eng1 word0 byte0");
    check8(b1, 8'h55, "prog eng1 word0 byte1");
    check8(b2, 8'h66, "prog eng1 word0 byte2");
    check24(dut.u_eng1.prog[0], 24'h665544, "eng1 prog[0] assembled (3 lanes)");

    // ---- program memory: engine 3, last valid word (i = 31) ------------
    frame_start;
    spi_byte(8'h05, b0);    // 0x0400 + 31*4 = 0x047C
    spi_byte(8'h7C, b0);
    spi_byte(8'h04, b0);
    spi_byte(8'hDE, b0);
    spi_byte(8'hAD, b0);
    spi_byte(8'hBE, b0);
    frame_end;
    rdn(16'h047C, 4'd3, b0, b1, b2, b3);
    check8(b0, 8'hDE, "prog eng3 i31 byte0");
    check8(b1, 8'hAD, "prog eng3 i31 byte1");
    check8(b2, 8'hBE, "prog eng3 i31 byte2");
    check24(dut.u_eng3.prog[31], 24'hBEADDE, "eng3 prog[31] assembled (3 lanes)");

    // ---- program memory: i = 32 must be dropped and read 0 -------------
    frame_start;
    spi_byte(8'h05, b0);    // 0x0400 + 32*4 = 0x0480
    spi_byte(8'h80, b0);
    spi_byte(8'h04, b0);
    spi_byte(8'h77, b0);
    frame_end;
    rd1(16'h0480, b0);
    check8(b0, 8'h00, "prog i=32 writes dropped, reads 0");

    // ---- IN_FIFO push / OUT_FIFO pop on engine 3 -----------------------
    wr1(16'h0080, 8'h77);   // eng3 IN_FIFO (base 0x0070 + 0x10)
    rd1(16'h0081, b0);      // eng3 OUT_FIFO (stub mirrors pushes)
    check8(b0, 8'h77, "eng3 OUT_FIFO returns pushed byte");
    rd1(16'h0081, b0);      // empty now
    check8(b0, 8'h00, "eng3 OUT_FIFO empty reads 0");

    // ---- pin registers --------------------------------------------------
    wr1(16'h0520, 8'hA5);   // uo_out value
    wr1(16'h0521, 8'h0F);   // uio_out value
    wr1(16'h0522, 8'hFF);   // uio oe
    wr1(16'h0523, 8'h03);   // uio open-drain
    rd1(16'h0520, b0);
    check8(b0, 8'hA5, "uo_out readback");
    rd1(16'h0521, b0);
    check8(b0, 8'h0F, "uio_out readback");
    rd1(16'h0522, b0);
    check8(b0, 8'hFF, "uio_oe readback");
    rd1(16'h0523, b0);
    check8(b0, 8'h03, "uio_od readback");

    repeat (4) @(posedge clk);
    check8(uio_out, 8'h0F, "uio_out pin value");
    // effective OE: oe & ~(od & out) = 0xFF & ~(0x03 & 0x0F) = 0xFC
    check8(uio_oe,  8'hFC, "uio_oe open-drain release");
    // host_en=1: uo_out[7:2] from the register, [1]=IRQ(0), [0]=MISO(0)
    check8(uo_out & 8'hFC, 8'hA4, "uo_out[7:2] fabric value with host enabled");
    check8(uo_out[1], 1'b0, "uo_out[1] IRQ low with IRQ_ENABLE=0");
    check8(uo_out[0], 1'b0, "uo_out[0] MISO low outside a frame");

    // ---- collision register (no contention in this TB) ------------------
    rd1(16'h0510, b0);
    check8(b0, 8'h00, "collision clear");

    // ---- CYCLE counter --------------------------------------------------
    rdn(16'h000B, 4'd4, b0, b1, b2, b3);
    cyc_a = {b3, b2, b1, b0};
    repeat (200) @(posedge clk);
    rdn(16'h000B, 4'd4, b0, b1, b2, b3);
    cyc_b = {b3, b2, b1, b0};
    nchecks = nchecks + 1;
    if (!(cyc_b > cyc_a)) begin
      errors = errors + 1;
      $display("FAIL CYCLE counter did not advance (%0d -> %0d)", cyc_a, cyc_b);
    end

    // ---- IRQ_ENABLE -----------------------------------------------------
    wr1(16'h0009, 8'h3C);
    rd1(16'h0009, b0);
    check8(b0, 8'h3C, "IRQ_ENABLE readback");
    rd1(16'h0008, b0);
    check8(b0, 8'h00, "IRQ_STATUS clear");

    // ---- RUN / HALT / STATUS -------------------------------------------
    wr1(16'h0004, 8'h0F);
    rd1(16'h0004, b0);
    check8(b0, 8'h0F, "RUN readback");
    repeat (6) @(posedge clk);
    rd1(16'h0003, b0);
    check8(b0[0], 1'b1, "STATUS any_run set");
    wr1(16'h0005, 8'h01);
    rd1(16'h0004, b0);
    check8(b0, 8'h0E, "HALT clears run bit 0");
    wr1(16'h0005, 8'h0E);
    rd1(16'h0003, b0);
    check8(b0[0], 1'b0, "STATUS any_run clear after HALT");

    // ---- capture unit ---------------------------------------------------
    wr1(16'h0500, 8'h01);   // watch uio pin 0
    rd1(16'h0500, b0);
    check8(b0, 8'h01, "CAP_EN readback");
    @(posedge clk);
    uio_ext = 8'h01;
    repeat (4) @(posedge clk);
    uio_ext = 8'h00;
    repeat (4) @(posedge clk);
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd2, "CAP_STATUS count after two edges");
    check8(b0[4], 1'b0, "CAP_STATUS overflow clear");
    rdn(16'h0502, 4'd4, b0, b1, b2, b3);
    nchecks = nchecks + 1;
    if ({(b3), (b2), (b1), (b0)} == 32'd0) begin
      errors = errors + 1;
      $display("FAIL CAP timestamp is zero");
    end
    rd1(16'h0506, b0);
    check8(b0[3:0], 4'd0, "CAP_INFO pin 0");
    check8(b0[4], 1'b1, "CAP_INFO first edge is rising");
    wr1(16'h0507, 8'h01);   // pop
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd1, "CAP_STATUS count after pop");
    rd1(16'h0506, b0);
    check8(b0[3:0], 4'd0, "CAP_INFO pin 0 (second edge)");
    check8(b0[4], 1'b0, "CAP_INFO second edge is falling");
    wr1(16'h0507, 8'h01);   // pop remaining
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd0, "CAP_STATUS empty");

    // ---- assert info (no errors in the stub) ----------------------------
    rd1(16'h0530, b0);
    check8(b0, 8'h00, "ASSERT_INFO clear");

    // ---- HOST_DISABLE hands uo_out[1:0] to the fabric --------------------
    frame_start;
    spi_byte(8'h09, b0);    // HOST_DISABLE
    frame_end;
    repeat (4) @(posedge clk);
    check8(dut.host_en, 1'b0, "host_en clear after HOST_DISABLE");
    // uo_q = 0xA5 -> uo_out[1:0] now come from the register
    check8(uo_out[1:0], 2'b01, "uo_out[1:0] fabric-owned after HOST_DISABLE");
    check8(uo_out & 8'hFC, 8'hA4, "uo_out[7:2] unchanged after HOST_DISABLE");

    // ---- SOFT_RESET wipes the register file, restores host_en -----------
    wr1(16'h0006, 8'h01);
    repeat (10) @(posedge clk);
    check8(dut.host_en, 1'b1, "host_en restored by SOFT_RESET");
    rd1(16'h0520, b0);
    check8(b0, 8'h00, "uo_out register cleared by SOFT_RESET");
    rd1(16'h0500, b0);
    check8(b0, 8'h00, "CAP_EN cleared by SOFT_RESET");
    rd1(16'h0004, b0);
    check8(b0, 8'h00, "RUN cleared by SOFT_RESET");
    rd1(16'h0000, b0);
    check8(b0, 8'h50, "ID readable after SOFT_RESET");

    $display("--- top_stub_tb: %0d checks, %0d errors ---", nchecks, errors);
    if (errors != 0) $fatal(1, "top_stub_tb FAILED");
    $display("top_stub_tb PASSED");
    $finish;
  end

endmodule

`default_nettype wire
