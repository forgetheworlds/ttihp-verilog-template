`default_nettype none
`timescale 1ns / 1ps

/* PROTEUS v2 (hybrid) testbench for the Tiny Tapeout harness.

   Same top port list as v1 (test/tb.v), so the netlist flow is unchanged.
   Instantiates the real top and exposes the pins as regs/wires that
   test/test.py drives.  No behaviour lives here: the whole protocol is
   exercised over ui_in[2:0] / uo_out[0] (host SPI) and the uio pads, so the
   same testbench works against the gate-level netlist (GATES=yes).
*/
module tb ();

  // Dump the signals to an FST file. You can view it with gtkwave or surfer.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  tt_um_proteus user_project (
      .ui_in  (ui_in),    // Dedicated inputs: [2:0] host SPI, [7:3] fabric
      .uo_out (uo_out),   // Dedicated outputs: [0] host MISO, [1] IRQ, [7:2] fabric
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  );

endmodule

`default_nettype wire
