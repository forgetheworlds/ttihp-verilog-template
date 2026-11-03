`timescale 1ns/1ps
// shiftreg32: width, direction, byte push/pop and the bit-stuff hook.
module tb_shiftreg;
  reg clk = 0, rst_n = 0;
  reg load = 0, sh_en = 0, dir = 1, push_we = 0, pop_req = 0;
  reg stuff_en = 0, bit_in_v = 0;
  reg [31:0] din = 0;
  reg [5:0] width_r = 6'd32;
  reg [7:0] bpush = 0;
  reg [2:0] stuff_len = 3'd0;
  wire [31:0] dout;
  wire bit_out, bit_valid, byte_valid, stuff_flag;
  wire [7:0] bpop;

  integer errs = 0, i;

  shiftreg32 dut (
    .clk(clk), .rst_n(rst_n), .load(load), .din(din),
    .sh_en(sh_en), .dir(dir), .width_r(width_r),
    .bpush(bpush), .push_we(push_we), .pop_req(pop_req),
    .stuff_en(stuff_en), .stuff_len(stuff_len), .bit_in(bit_in_v),
    .dout(dout), .bit_out(bit_out), .bit_valid(bit_valid),
    .bpop(bpop), .byte_valid(byte_valid), .stuff_flag(stuff_flag)
  );

  always #5 clk = ~clk;

  task do_load(input [31:0] v);
    begin
      @(negedge clk); din = v; load = 1;
      @(negedge clk); load = 0;
    end
  endtask

  task do_shift(input bi);
    begin
      @(negedge clk); bit_in_v = bi; sh_en = 1;
      @(posedge clk); #1;
      sh_en = 0;
    end
  endtask

  task chk(input [255:0] what, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin
        errs = errs + 1;
        $display("FAIL %0s: got 0x%08x want 0x%08x", what, got, want);
      end
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    // ---- MSB-first shift, 12-bit window
    width_r = 6'd12; dir = 1'b1;
    do_load(32'h0000_0F00);
    chk("load 12b", dout, 32'h0000_0F00);
    for (i = 0; i < 4; i = i + 1) begin
      do_shift(1'b0);
      chk("msb bit", {31'd0, bit_out}, 32'd1);
    end
    chk("after 4 msb shifts", dout, 32'd0);

    // ---- LSB-first shift, 12-bit window (0x005 -> bits 1,0,1)
    dir = 1'b0;
    do_load(32'h0000_0005);
    do_shift(1'b0); chk("lsb bit0", {31'd0, bit_out}, 32'd1);
    do_shift(1'b0); chk("lsb bit1", {31'd0, bit_out}, 32'd0);
    do_shift(1'b0); chk("lsb bit2", {31'd0, bit_out}, 32'd1);

    // ---- byte push/pop at the active end
    width_r = 6'd32; dir = 1'b1;
    @(negedge clk); bpush = 8'hAB; push_we = 1;
    @(negedge clk); push_we = 0;
    chk("byte push top", dout[31:24], 32'hAB);
    @(negedge clk); pop_req = 1;
    @(negedge clk); pop_req = 0;
    #1; chk("byte pop", {24'd0, bpop}, 32'hAB);

    // ---- stuff hook: insert a 0 after 2 ones with stuff_len = 3
    do_load(32'hFFFF_FFFF);
    stuff_en = 1; stuff_len = 3'd3;
    do_shift(1'b0); chk("stuff bit1", {31'd0, bit_out}, 32'd1);
    do_shift(1'b0); chk("stuff bit2", {31'd0, bit_out}, 32'd1);
    do_shift(1'b0); chk("inserted bit", {31'd0, bit_out}, 32'd0);
    chk("stuff flag", {31'd0, stuff_flag}, 32'd1);
    chk("register held", dout, 32'hFFFF_FFFC);
    stuff_en = 0;

    if (errs == 0) $display("TB_SHIFTREG PASS");
    else           $display("TB_SHIFTREG FAIL (%0d errors)", errs);
    $finish;
  end

  initial begin
    #100000;
    $display("TB_SHIFTREG FAIL (timeout)");
    $finish;
  end
endmodule
