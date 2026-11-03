`timescale 1ns/1ps
// Manchester encoder -> decoder loopback.
// clk models an 80 MHz core: HALF_DIV = 4 clocks per half-bit (20 Mbaud),
// decoder OS = 4 samples per half-bit.  Eight bytes are transmitted (six data
// plus two zero flush bytes); the decoded bit stream must contain the
// transmitted 48-bit pattern.  Byte framing is not carried by Manchester, so
// the check allows an arbitrary bit offset.
module tb_manchester;
  localparam integer HIST = 192;

  reg clk = 0, rst_n = 0, en = 0;
  reg [7:0] din = 0;
  reg din_we = 0;
  wire tx, half_stb, busy, ready, overflow;

  wire rx_bit, rx_bv, dout_valid, locked, phase_err, manch_err;
  wire [7:0] dout;

  reg [HIST-1:0] rx_hist = 0;
  reg [47:0] expected = 0;
  reg [7:0]  bytes [0:5];
  reg        sticky_phase = 0, sticky_manch = 0;
  reg        seen_lock = 0;
  integer i, k, off, errs = 0;
  reg matched;
  reg b1;

  manchester_enc #(.HALF_DIV(4)) enc (
    .clk(clk), .rst_n(rst_n), .en(en),
    .din(din), .din_we(din_we),
    .tx(tx), .half_stb(half_stb), .busy(busy), .ready(ready),
    .overflow(overflow)
  );

  manchester_dec #(.OS(4)) dec (
    .clk(clk), .rst_n(rst_n), .en(en), .rx(tx),
    .bit_out(rx_bit), .bit_valid(rx_bv),
    .dout(dout), .dout_valid(dout_valid),
    .locked(locked), .phase_err(phase_err), .manch_err(manch_err)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n) begin
      if (rx_bv) rx_hist <= {rx_hist[HIST-2:0], rx_bit};
      if (locked) seen_lock <= 1'b1;
      // a stable idle line is not Manchester, so only judge errors once locked
      if (locked && phase_err) sticky_phase <= 1'b1;
      // violations while the line is idle (no transmitter) are expected
      if (locked && busy && manch_err) sticky_manch <= 1'b1;
    end
  end

  task send_byte(input [7:0] b);
    begin
      while (!ready) @(negedge clk);
      @(negedge clk); din = b; din_we = 1;
      @(negedge clk); din_we = 0;
    end
  endtask

  initial begin
    bytes[0] = 8'h55; bytes[1] = 8'hAA; bytes[2] = 8'h01;
    bytes[3] = 8'hFE; bytes[4] = 8'h00; bytes[5] = 8'hFF;

    for (i = 0; i < 6; i = i + 1)
      for (k = 0; k < 8; k = k + 1) begin
        b1 = (bytes[i] >> k) & 8'h01;
        expected = {expected[46:0], b1};
      end

    repeat (3) @(negedge clk);
    rst_n = 1;
    en = 1;
    repeat (2) @(negedge clk);

    for (i = 0; i < 6; i = i + 1) send_byte(bytes[i]);
    send_byte(8'h00);                 // flush the tail of the pattern through
    send_byte(8'h00);

    repeat (300) @(negedge clk);

    matched = 0;
    for (off = 0; off <= (HIST - 48); off = off + 1)
      if (((rx_hist >> off) & 48'hFFFFFFFFFFFF) == expected) matched = 1;

    if (!matched) begin
      errs = errs + 1;
      $display("FAIL decoded bit pattern not found");
      $display("  hist=%0h", rx_hist);
      $display("  exp =%0h", expected);
    end
    if (!seen_lock) begin errs = errs + 1; $display("FAIL decoder never locked"); end
    if (sticky_phase) begin errs = errs + 1; $display("FAIL phase error after lock"); end
    if (sticky_manch) begin errs = errs + 1; $display("FAIL Manchester violation after lock"); end
    if (overflow) begin errs = errs + 1; $display("FAIL encoder overflow"); end

    $display("  hist=%0h", rx_hist);
    $display("  exp =%0h", expected);
    $display("  locked=%0b (seen=%0b) phase_err=%0b manch_err=%0b",
             locked, seen_lock, sticky_phase, sticky_manch);

    if (errs == 0) $display("TB_MANCHESTER PASS");
    else           $display("TB_MANCHESTER FAIL (%0d errors)", errs);
    $finish;
  end

  initial begin
    #200000;
    $display("TB_MANCHESTER FAIL (timeout)");
    $finish;
  end
endmodule
