// ===========================================================================
// tb/top_capdepth_tb.v -- capture FIFO at the default CAP_DEPTH = 4.
//
// The functional suites only ever push 3 events, which says nothing about the
// parameterised depth.  This bench drives the real top with CAP_DEPTH=4 and
// checks the two depth-dependent behaviours:
//   * the 5th event before a pop is dropped and CAP_STATUS[4] (sticky
//     overflow) is set, with the count saturating at 4
//   * popping drains exactly 4 entries (count 4 -> 3 -> 0) and the overflow
//     flag stays sticky
//
// Edges are injected on the external uio[0] line, CAP_EN = 0x01 over SPI.
//
// Exit status: 1 on any failure ($fatal), 0 on success.
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module top_capdepth_tb;

  localparam CLKP = 10;

  reg clk = 1'b0;
  always #(5) clk = ~clk;

  reg  rst_n = 1'b0;
  reg  [7:0] ui_in = 8'h02;        // SPI idle: SCK=0, CS_N=1, MOSI=0
  reg  [7:0] uio_ext = 8'h00;      // externally driven uio level
  wire [7:0] uio_in;
  wire [7:0] uo_out, uio_out, uio_oe;

  reg  sck  = 1'b0;
  reg  cs_n = 1'b1;
  reg  mosi = 1'b0;
  wire miso;
  always @* begin
    ui_in[0] = sck;
    ui_in[1] = cs_n;
    ui_in[2] = mosi;
    ui_in[7:3] = 5'b00000;
  end
  assign miso   = uo_out[0];
  assign uio_in = uio_ext | (uio_out & uio_oe);

  tt_um_proteus #(.PROG_DEPTH(32), .CAP_DEPTH(4)) dut (
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

  // Toggle uio0 on a falling edge, then hold the level across several rising
  // edges: driving it in the same delta as a posedge races the capture
  // sampler and can merge/lose an edge.
  task toggle_uio0;
    begin
      @(negedge clk);
      uio_ext[0] = ~uio_ext[0];
      repeat (4) @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------- test body
  reg [7:0] b0, b1;
  integer   e;

  initial begin
    $display("=== tt_um_proteus top_capdepth_tb (CAP_DEPTH=4) ===");
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (80) @(posedge clk);

    // capture enabled on uio0 only
    wr1(16'h0500, 8'h01);
    rd1(16'h0500, b0);
    check8(b0, 8'h01, "CAP_EN readback");
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd0, "capture empty before edges");

    // five transitions on uio0 (one event per transition), no pops
    for (e = 0; e < 5; e = e + 1) toggle_uio0;

    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd4, "count saturates at CAP_DEPTH");
    check8(b0[4],   1'b1, "overflow sticky set by dropped 5th event");
    rd1(16'h0506, b0);
    check8(b0[3:0], 4'd0, "head pin 0");
    check8(b0[4],   1'b1, "head level high (first edge rising)");

    // drain: 4 -> 3 -> 0
    wr1(16'h0507, 8'h01);
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd3, "count after one pop");
    wr1(16'h0507, 8'h01);
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd2, "count after two pops");
    wr1(16'h0507, 8'h01);
    wr1(16'h0507, 8'h01);
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd0, "count after four pops");
    check8(b0[4],   1'b1, "overflow sticky after drain");

    // a pop on an empty FIFO must not underflow
    wr1(16'h0507, 8'h01);
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd0, "pop on empty leaves count at 0");
    check8(b0[4],   1'b1, "overflow still sticky");

    // and the FIFO still accepts a new event afterwards
    toggle_uio0;
    rd1(16'h0501, b0);
    check8(b0[3:0], 4'd1, "new event accepted after drain");

    if (errors == 0) begin
      $display("==== PASS: %0d capture-depth checks passed ====", nchecks);
      $finish;
    end else begin
      $fatal(1, "==== FAIL: %0d of %0d checks failed ====", errors, nchecks);
    end
  end

endmodule

`default_nettype wire
