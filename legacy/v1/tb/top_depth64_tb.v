// ===========================================================================
// tb/top_depth64_tb.v -- program-memory addressing at PROG_DEPTH = 64.
//
// Regression for the PDEPTH truncation defect: with `localparam [5:0] PDEPTH`
// and PROG_DEPTH=64, PDEPTH evaluated to 0, so pm_ok was always false (every
// program-memory write dropped) and every program read returned 0.  Depth 32
// hid it.
//
// This bench elaborates the real top at PROG_DEPTH=64 and checks, over real
// SPI mode-0 frames:
//   * word 0 (0x0100..0x0102) writes and reads back
//   * word 63 (0x01FC..0x01FE), the last word of a 64-entry engine window,
//     writes and reads back
//   * word 0 is unchanged afterwards (no index truncation / aliasing)
//
// Exit status: 1 on any failure ($fatal), 0 on success.
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module top_depth64_tb;

  localparam CLKP = 10;

  reg clk = 1'b0;
  always #(5) clk = ~clk;

  reg  rst_n = 1'b0;
  reg  [7:0] ui_in   = 8'h00;
  reg  [7:0] uio_ext = 8'h00;
  wire [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

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
  assign miso   = uo_out[0];
  assign uio_in = uio_ext | (uio_out & uio_oe);

  tt_um_proteus #(.PROG_DEPTH(64)) dut (
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

  // ------------------------------------------------------------- test body
  reg [7:0] b0, b1, b2;
  reg [7:0] r0, r1, r2;

  initial begin
    $display("=== tt_um_proteus top_depth64_tb (PROG_DEPTH=64) ===");
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (80) @(posedge clk);        // engine HALT fill for 64 entries

    // ---- word 0 ---------------------------------------------------------
    wr1(16'h0100, 8'hAA);
    wr1(16'h0101, 8'h56);
    wr1(16'h0102, 8'h34);
    rd1(16'h0100, r0);
    rd1(16'h0101, r1);
    rd1(16'h0102, r2);
    check8(r0, 8'hAA, "depth64 word0 byte0 written");
    check8(r1, 8'h56, "depth64 word0 byte1 written");
    check8(r2, 8'h34, "depth64 word0 byte2 written");

    // ---- word 63: 0x0100 + 63*4 = 0x01FC --------------------------------
    wr1(16'h01FC, 8'h12);
    wr1(16'h01FD, 8'h34);
    wr1(16'h01FE, 8'h56);
    rd1(16'h01FC, r0);
    rd1(16'h01FD, r1);
    rd1(16'h01FE, r2);
    check8(r0, 8'h12, "depth64 word63 byte0 written");
    check8(r1, 8'h34, "depth64 word63 byte1 written");
    check8(r2, 8'h56, "depth64 word63 byte2 written");

    // ---- word 63 write must not have disturbed word 0 -------------------
    rd1(16'h0100, b0);
    rd1(16'h0101, b1);
    rd1(16'h0102, b2);
    check8(b0, 8'hAA, "depth64 word0 byte0 intact");
    check8(b1, 8'h56, "depth64 word0 byte1 intact");
    check8(b2, 8'h34, "depth64 word0 byte2 intact");

    if (errors == 0) begin
      $display("==== PASS: %0d depth-64 checks passed ====", nchecks);
      $finish;
    end else begin
      $fatal(1, "==== FAIL: %0d of %0d checks failed ====", errors, nchecks);
    end
  end

endmodule

`default_nettype wire
