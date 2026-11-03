`timescale 1ns/1ps
// NRZI decoder against a perfect J/K waveform (no encoder in the loop).
//
// nrzi_wave.hex holds one {dp,dm} level per bit time: idle J, then the bytes
// 0x80 (SYNC), 0x69, 0xFE (seven 1s -> one stuffed 0), 0x00, 0x5A, then idle.
// Each level is held DIV clocks.  The decoder must emit exactly the four bytes
// after SYNC and assert sync_det on the SYNC pattern.
module tb_nrzi_wave;
  localparam integer DIV = 6'd8;
  localparam integer NLV = 54;

  reg clk = 0, rst_n = 0, en = 0;
  reg [5:0] div_r = DIV;
  reg dp = 0, dm = 1;
  wire [7:0] dout;
  wire dv, sd, ed, rd, se, se0o, busy, bo, bv;

  reg [1:0] wave [0:NLV-1];
  reg [7:0] rx [0:7];
  integer n = 0, i, got = 0, errs = 0;
  reg sync_seen = 0;

  nrzi_dec #(.AW(6)) dut (
    .clk(clk), .rst_n(rst_n), .en(en), .div_r(div_r),
    .dp(dp), .dm(dm),
    .dout(dout), .dout_valid(dv),
    .sync_det(sd), .eop_det(ed), .reset_det(rd),
    .stuff_err(se), .se0(se0o), .busy(busy),
    .bit_out(bo), .bit_valid(bv)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n) begin
      if (dv) begin
        if (got < 8) rx[got] = dout;
        got = got + 1;
      end
      if (sd) sync_seen <= 1'b1;
    end
  end

  initial begin
    $readmemb("nrzi_wave.hex", wave);
    repeat (3) @(negedge clk);
    rst_n = 1; en = 1;
    repeat (80) @(negedge clk);          // idle so the detector arms
    for (i = 0; i < NLV; i = i + 1) begin
      dp = wave[i][1];
      dm = wave[i][0];
      repeat (DIV) @(negedge clk);
    end
    repeat (40) @(negedge clk);

    if (!sync_seen) begin errs = errs + 1; $display("FAIL sync_det never asserted"); end
    if (got != 4) begin
      errs = errs + 1;
      $display("FAIL decoded %0d bytes after SYNC, want 4", got);
    end
    if (rx[0] !== 8'h69) begin errs = errs + 1; $display("FAIL byte0 0x%02x want 0x69", rx[0]); end
    if (rx[1] !== 8'hFE) begin errs = errs + 1; $display("FAIL byte1 0x%02x want 0xFE", rx[1]); end
    if (rx[2] !== 8'h00) begin errs = errs + 1; $display("FAIL byte2 0x%02x want 0x00", rx[2]); end
    if (rx[3] !== 8'h5A) begin errs = errs + 1; $display("FAIL byte3 0x%02x want 0x5A", rx[3]); end
    if (se)              begin errs = errs + 1; $display("FAIL spurious stuff error"); end

    for (i = 0; i < got && i < 8; i = i + 1)
      $display("  byte[%0d] = 0x%02x", i, rx[i]);

    if (errs == 0) $display("TB_NRZI_WAVE PASS");
    else           $display("TB_NRZI_WAVE FAIL (%0d errors)", errs);
    $finish;
  end

  initial begin
    #200000;
    $display("TB_NRZI_WAVE FAIL (timeout)");
    $finish;
  end
endmodule
