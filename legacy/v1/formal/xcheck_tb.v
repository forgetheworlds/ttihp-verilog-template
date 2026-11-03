// ===========================================================================
// xcheck_tb.v -- 4-state (X) check of the pin fabric after reset.
//
// The SMT-based proofs in run.sh are 2-valued: `x` does not exist there, so
// "never X" cannot be proven by smtbmc.  This testbench checks it with real
// 4-state semantics in iverilog: reset the chip, then drive only KNOWN values
// on every input for 200 cycles (constant zero, then pseudo-random) and assert
// that uio_oe / uio_out / uo_out are never X or Z.
//
// It is a simulation check, not a proof; the formal counterpart is that every
// state element is assigned a constant in its reset branch, which the 2-valued
// model cannot state.
// ===========================================================================
`timescale 1ns/1ps

module xcheck_tb;

  reg        clk = 1'b0;
  reg        rst_n = 1'b0;
  reg  [7:0] ui_in = 8'h00;
  reg  [7:0] uio_in = 8'h00;
  wire [7:0] uo_out, uio_out, uio_oe;

  integer errors = 0;
  integer cyc;

  tt_um_proteus dut (
    .ui_in   (ui_in),
    .uo_out  (uo_out),
    .uio_in  (uio_in),
    .uio_out (uio_out),
    .uio_oe  (uio_oe),
    .ena     (1'b1),
    .clk     (clk),
    .rst_n   (rst_n)
  );

  always #5 clk = ~clk;

  task check_pins(input [8*16-1:0] phase);
    begin
      if (^uio_oe === 1'bx) begin
        errors = errors + 1;
        $display("XCHECK FAIL t=%0t phase=%0s uio_oe=%b", $time, phase, uio_oe);
      end
      if (^uio_out === 1'bx) begin
        errors = errors + 1;
        $display("XCHECK FAIL t=%0t phase=%0s uio_out=%b", $time, phase, uio_out);
      end
      if (^uo_out === 1'bx) begin
        errors = errors + 1;
        $display("XCHECK FAIL t=%0t phase=%0s uo_out=%b", $time, phase, uo_out);
      end
    end
  endtask

  initial begin
    // reset for 8 clocks
    rst_n = 1'b0;
    for (cyc = 0; cyc < 8; cyc = cyc + 1) begin
      @(posedge clk);
      #1 check_pins("reset");
    end
    rst_n = 1'b1;

    // phase 1: all inputs known-zero
    for (cyc = 0; cyc < 50; cyc = cyc + 1) begin
      ui_in  = 8'h00;
      uio_in = 8'h00;
      @(posedge clk);
      #1 check_pins("quiet");
    end

    // phase 2: pseudo-random known stimulus (LFSR), exercises the host
    // synchronisers, capture unit and fabric registers.
    for (cyc = 0; cyc < 150; cyc = cyc + 1) begin
      ui_in  = $random;
      uio_in = $random;
      @(posedge clk);
      #1 check_pins("random");
    end

    if (errors == 0)
      $display("XCHECK PASS: uio_oe/uio_out/uo_out free of X and Z for 208 post-reset cycles");
    else
      $display("XCHECK FAIL: %0d X violations", errors);
    $finish;
  end

  // hard stop
  initial begin
    #200000;
    $display("XCHECK FAIL: timeout");
    $finish;
  end

endmodule
