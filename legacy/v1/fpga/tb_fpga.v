// ===========================================================================
// tb_fpga.v -- self-checking testbench for the PROTEUS DE2 build.
//
// Instantiates the real board top (tt_um_proteus_fpga), which contains the real
// chip RTL, the real SPI host master and the real boot loader, and drives it
// exactly like the owner does: reset on KEY[1], demo select on SW[1:0], start
// on KEY[0] (or automatically when the demo switches change).
//
// Runs, in order, all four demos end to end through the real host protocol:
//   00 pin blink   PASS + BLINK edges exactly 8192 cycles apart (SW[2]=1)
//   01 UART loop   PASS + 4 bytes verified + last byte 0xC3
//   10 SPI loop    PASS + 4 bytes verified + last byte 0x00 (echo)
//   11 I2C loop    PASS + 3 bytes verified + last byte 0xC3
// then re-runs demo 11 with an explicit KEY[0] press to prove the key path.
//
// Self-check only: no VCD dumps, no external files.  Exit status 1 on failure.
//
//   iverilog -g2005 -o /tmp/fpga_tb fpga/tb_fpga.v src/*.v fpga/*.v
//   vvp /tmp/fpga_tb
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_fpga;

  localparam CLK_HALF = 10;          // 10 ns half period -> 50 MHz
  localparam PACE_FAST = 8192;       // blink tick with SW[2] = 1

  reg clk = 1'b0;
  always #(CLK_HALF) clk = ~clk;

  reg  [3:0]  KEY = 4'b1111;
  reg  [17:0] SW  = 18'd0;
  wire [17:0] LEDR;
  wire [8:0]  LEDG;
  wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;
  wire [35:0] GPIO_0, GPIO_1;

  integer errors = 0;
  integer checks = 0;

  tt_um_proteus_fpga dut (
    .CLOCK_50 (clk),
    .KEY      (KEY),
    .SW       (SW),
    .LEDR     (LEDR),
    .LEDG     (LEDG),
    .HEX0     (HEX0), .HEX1 (HEX1), .HEX2 (HEX2), .HEX3 (HEX3),
    .HEX4     (HEX4), .HEX5 (HEX5), .HEX6 (HEX6), .HEX7 (HEX7),
    .GPIO_0   (GPIO_0),
    .GPIO_1   (GPIO_1)
  );

  // ------------------------------------------------------------- checking
  task check_int(input integer got, input integer exp, input [255:0] what);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("  FAIL %0s: got %0d expected %0d (t=%0t)", what, got, exp, $time);
      end
    end
  endtask

  task check_hex(input [6:0] got, input [6:0] exp, input [255:0] what);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("  FAIL %0s: got %b expected %b", what, got, exp);
      end
    end
  endtask

  // DE2 7-segment encodings used by the checks (active low).
  localparam [6:0] SEG_A = 7'b0001000;
  localparam [6:0] SEG_E = 7'b0000110;
  localparam [6:0] SEG_F = 7'b0001110;
  localparam [6:0] SEG_3 = 7'b0110000;

  // ---------------------------------------------------------------- reset
  task do_reset;
    begin
      KEY = 4'b1101;                 // KEY[1] low = reset
      SW  = 18'b000100;              // demo 00, SW[2]=1 (fast pacer)
      repeat (200) @(posedge clk);
      KEY = 4'b1111;
      repeat (10) @(posedge clk);
    end
  endtask

  task press_start;
    begin
      KEY[0] = 1'b0;
      repeat (10000) @(posedge clk);
      KEY[0] = 1'b1;
      repeat (10000) @(posedge clk);
    end
  endtask

  // Wait for one boot-loader run to start and finish; report its result.
  task run_demo(input integer limit);
    integer n;
    begin
      n = 0;
      while (!dut.ld_busy && n < limit) begin
        @(posedge clk);
        n = n + 1;
      end
      checks = checks + 1;
      if (n >= limit) begin
        errors = errors + 1;
        $display("  FAIL loader never started (t=%0t)", $time);
      end
      n = 0;
      while (dut.ld_busy && n < limit) begin
        @(posedge clk);
        n = n + 1;
      end
      checks = checks + 1;
      if (n >= limit) begin
        errors = errors + 1;
        $display("  FAIL loader never finished (t=%0t)", $time);
      end
    end
  endtask

  // ------------------------------------------------- BLINK edge timing probe
  // LEDG[0] is the resolved BLINK pad value (pull-up when the chip releases it),
  // which is what the board actually shows.
  reg        pin_d = 1'b1;
  integer    nedge = 0;
  realtime   edge_t [0:15];
  always @(posedge clk) begin
    pin_d <= LEDG[0];
    if ((LEDG[0] ^ pin_d) === 1'b1) begin
      if (nedge < 16) edge_t[nedge] = $realtime;
      nedge = nedge + 1;
    end
  end

  // --------------------------------------------------------------- watchdog
  // Cycle-count based so it is independent of the timescale.
  integer wd_cycles = 0;
  always @(posedge clk) begin
    wd_cycles = wd_cycles + 1;
    if (wd_cycles > 2500000) begin
      $display("FAIL watchdog: simulation did not converge");
      $display("=== tb_fpga: %0d checks, %0d errors (WATCHDOG)", checks, errors);
      $fatal;
    end
  end

  // ------------------------------------------------------------------ tests
  integer i;
  realtime d, exp_ns;

  initial begin
    $display("=== PROTEUS DE2 board top: tb_fpga ===");

    do_reset;

    // ---------------------------------------------------------- demo 00
    $display("-- demo 00: pin blink (pacer tick %0d cycles)", PACE_FAST);
    run_demo(400000);
    check_int(dut.ld_pass, 1, "demo00 pass");
    check_int(dut.ld_fail, 0, "demo00 no fail");
    check_int({29'd0, dut.demo_s2}, 0, "demo00 selected id");
    // Let the pacer emit a few edges, then check the spacing exactly.
    // PACERST phase convention (docs/isa.md): the first PACE issued the cycle
    // after PACERST completes immediately, so the first completion interval is
    // period-1 and every later one is exactly period.  Pin edges are one
    // instruction later than completions, which absorbs that first cycle, so
    // accept period-1 or period for the first interval and require exact
    // period afterwards.
    nedge = 0;
    repeat (10 * PACE_FAST) @(posedge clk);
    checks = checks + 1;
    if (nedge < 6) begin
      errors = errors + 1;
      $display("  FAIL demo00: only %0d BLINK edges in 10 pacer ticks", nedge);
    end else begin
      d = edge_t[1] - edge_t[0];
      checks = checks + 1;
      if ((d != PACE_FAST * 20.0) && (d != (PACE_FAST - 1) * 20.0)) begin
        errors = errors + 1;
        $display("  FAIL demo00 first edge spacing %0.1f ns, expected %0.1f or %0.1f",
                 d, PACE_FAST * 20.0, (PACE_FAST - 1) * 20.0);
      end
      for (i = 2; i < 6; i = i + 1) begin
        d = edge_t[i] - edge_t[i-1];
        checks = checks + 1;
        if (d != PACE_FAST * 20.0) begin
          errors = errors + 1;
          $display("  FAIL demo00 edge %0d spacing %0.1f ns, expected %0.1f ns",
                   i, d, PACE_FAST * 20.0);
        end
      end
    end
    check_int({16'd0, dut.blink_cnt} > 0, 1, "demo00 edge counter advanced");
    check_hex(HEX7, 7'b0001000, "demo00 HEX7 shows A (pass)");

    // ---------------------------------------------------------- demo 01
    // Changing SW[1:0] restarts with the new demo, exactly like the board.
    $display("-- demo 01: UART loopback (engine 0 TX -> engine 1 RX)");
    SW[1:0] = 2'd1;
    run_demo(400000);
    check_int(dut.ld_pass, 1, "demo01 pass");
    check_int(dut.ld_fail, 0, "demo01 no fail");
    check_int({24'd0, dut.ld_bytes_done}, 4, "demo01 bytes verified");
    check_int({24'd0, dut.ld_last_byte}, 8'hC3, "demo01 last byte");
    check_hex(HEX1, SEG_3, "demo01 HEX1 low nibble of last byte");

    // ---------------------------------------------------------- demo 10
    $display("-- demo 10: SPI loopback (engine 2 + wrapper mode-0 slave)");
    SW[1:0] = 2'd2;
    run_demo(400000);
    check_int(dut.ld_pass, 1, "demo10 pass");
    check_int(dut.ld_fail, 0, "demo10 no fail");
    check_int({24'd0, dut.ld_bytes_done}, 4, "demo10 bytes verified");
    check_int({24'd0, dut.ld_last_byte}, 8'h00, "demo10 last echo byte");

    // ---------------------------------------------------------- demo 11
    $display("-- demo 11: I2C loopback (engine 3 + wrapper 0x50 EEPROM)");
    SW[1:0] = 2'd3;
    run_demo(400000);
    check_int(dut.ld_pass, 1, "demo11 pass");
    check_int(dut.ld_fail, 0, "demo11 no fail");
    check_int({24'd0, dut.ld_bytes_done}, 3, "demo11 bytes verified");
    check_int({24'd0, dut.ld_last_byte}, 8'hC3, "demo11 read-back byte 1");

    // ------------------------------------------- KEY[0] re-run of demo 11
    $display("-- demo 11 re-run via KEY[0]");
    press_start;
    run_demo(400000);
    check_int(dut.ld_pass, 1, "demo11 key re-run pass");
    check_int({24'd0, dut.ld_last_byte}, 8'hC3, "demo11 key re-run last byte");

    // ------------------------------------------------------------- summary
    $display("=== tb_fpga: %0d checks, %0d errors ===", checks, errors);
    if (errors != 0) $fatal(1, "FAILED");
    $display("PASS: all demos booted and verified through the real host protocol");
    $finish;
  end

endmodule

`default_nettype wire
