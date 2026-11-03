`timescale 1ns/1ps
// USB low-speed NRZI loopback: encoder (stuffing + EOP) -> decoder (edge
// DPLL + unstuffing + SYNC/EOP detect).  div_r = 8 clocks per bit for speed
// (the real value at 48 MHz is 32).
module tb_nrzi;
  reg clk = 0, rst_n = 0, en = 0;
  reg [5:0] div_r = 6'd8;
  reg [7:0] din = 0;
  reg din_we = 0, eop_req = 0;

  wire dp, dm, tx_oe, bit_stb, tx_bit, busy, ready, overflow, eop_done;
  wire dec_bit, dec_bit_valid;
  wire [7:0] dout;
  wire dout_valid, sync_det, eop_det, reset_det, stuff_err, se0, dbusy;

  reg [7:0] sent [0:4];
  reg [7:0] got  [0:9];
  integer ngot = 0, i, errs = 0;
  reg sync_seen = 0, eop_seen = 0;
  reg [63:0] enc_hist = 0, dec_hist = 0;
  integer nb_dec = 0;
  integer cyc = 0;
  reg [31:0] ev_cyc [0:199];
  reg [7:0]  ev_kind[0:199];
  integer nev = 0;

  nrzi_enc #(.AW(6)) enc (
    .clk(clk), .rst_n(rst_n), .en(en), .div_r(div_r),
    .din(din), .din_we(din_we), .eop_req(eop_req),
    .dp(dp), .dm(dm), .tx_oe(tx_oe), .bit_stb(bit_stb),
    .busy(busy), .ready(ready), .overflow(overflow), .eop_done(eop_done),
    .tx_bit(tx_bit)
  );

  nrzi_dec #(.AW(6), .EOP_BITS(1), .RESET_BITS(4)) dec (
    .clk(clk), .rst_n(rst_n), .en(en), .div_r(div_r),
    .dp(dp), .dm(dm),
    .dout(dout), .dout_valid(dout_valid),
    .sync_det(sync_det), .eop_det(eop_det), .reset_det(reset_det),
    .stuff_err(stuff_err), .se0(se0), .busy(dbusy),
    .bit_out(dec_bit), .bit_valid(dec_bit_valid)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n) begin
      if (dout_valid && sync_seen && !eop_seen) begin
        if (ngot < 10) got[ngot] = dout;
        ngot = ngot + 1;
      end
      cyc <= cyc + 1;
      if (bit_stb && nev < 200) begin
        ev_cyc[nev] = cyc; ev_kind[nev] = {6'd1, 1'b1, tx_bit}; nev = nev + 1;
      end
      if (dec_bit_valid && nev < 200) begin
        ev_cyc[nev] = cyc; ev_kind[nev] = {6'd1, 1'b0, dec_bit}; nev = nev + 1;
      end
      if (bit_stb) enc_hist <= {enc_hist[62:0], tx_bit};
      if (dec_bit_valid) begin
        dec_hist <= {dec_hist[62:0], dec_bit};
        nb_dec   <= nb_dec + 1;
      end
      if (sync_det) sync_seen <= 1'b1;
      if (eop_det)  eop_seen  <= 1'b1;
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
    sent[0] = 8'h80;   // SYNC: KJKJKJKK on the wire, 0x80 LSB-first
    sent[1] = 8'h69;   // IN PID
    sent[2] = 8'hFE;   // six consecutive 1s -> exercises stuffing
    sent[3] = 8'h00;
    sent[4] = 8'h5A;

    repeat (3) @(negedge clk);
    rst_n = 1;
    en = 1;
    // real bus is idle before a packet: let the decoder's idle detector arm
    repeat (200) @(negedge clk);

    for (i = 0; i < 5; i = i + 1) send_byte(sent[i]);
    // request the EOP while the last byte is still shifting out, so SE0
    // follows the last data bit with no intervening idle bit
    @(negedge clk); eop_req = 1;

    repeat (1200) @(negedge clk);

    // The decoder consumes the SYNC byte to realign (it asserts sync_det
    // instead of dout_valid), so four bytes are expected: sent[1..4].
    if (ngot != 4) begin
      errs = errs + 1;
      $display("FAIL decoded %0d bytes, want 4 (SYNC is reported by sync_det)", ngot);
    end
    for (i = 0; i < 4; i = i + 1)
      if (got[i] !== sent[i+1]) begin
        errs = errs + 1;
        $display("FAIL byte %0d: got 0x%02x want 0x%02x", i, got[i], sent[i+1]);
      end
    if (!sync_seen) begin errs = errs + 1; $display("FAIL sync_det never asserted"); end
    if (!eop_seen)  begin errs = errs + 1; $display("FAIL eop_det never asserted"); end
    if (stuff_err)  begin errs = errs + 1; $display("FAIL spurious stuff error"); end

    for (i = 0; i < ngot && i < 10; i = i + 1)
      $display("  byte[%0d] = 0x%02x", i, got[i]);
    $display("  enc_hist=%016x", enc_hist);
    for (i = 0; i < nev; i = i + 1)
      if (ev_kind[i][7:1] == 7'd2)
        $display("    dec cyc=%0d val=%0b", ev_cyc[i], ev_kind[i][0]);
    $display("  dec_hist=%016x (decoded bits=%0d)", dec_hist, nb_dec);
    $display("  enc st=%0d bi=%0d qv=%0b busy=%0b eop_done=%0b overflow=%0b",
             enc.st, enc.bi, enc.q_valid, busy, eop_done, overflow);
    $display("  dec bcnt=%0d acc=%02x win=%02x sop=%0d", dec.bcnt, dec.acc, dec.win, dec.sop_cnt);
    $display("  sync=%0b eop=%0b stuff_err=%0b bytes=%0d",
             sync_seen, eop_seen, stuff_err, ngot);

    if (errs == 0) $display("TB_NRZI PASS");
    else           $display("TB_NRZI FAIL (%0d errors)", errs);
    $finish;
  end

  initial begin
    #200000;
    $display("TB_NRZI FAIL (timeout)");
    $finish;
  end
endmodule
