`timescale 1ns/1ps
// Assist FIFO / mini-DMA: host fill, assist drain, burst counter.
module tb_fifo;
  reg clk = 0, rst_n = 0;
  reg h_wr = 0, h_rd = 0, a_pop = 0, clr = 1, arm = 0;
  reg [7:0] h_wdata = 0;
  reg [4:0] burst_len = 0;
  wire [7:0] h_rdata, a_data;
  wire a_valid, full, empty, burst_done, irq;
  wire [4:0] level, pops;

  integer i, errs = 0;

  assist_fifo #(.DEPTH(16), .AW(4), .CW(5)) dut (
    .clk(clk), .rst_n(rst_n),
    .h_wr(h_wr), .h_wdata(h_wdata), .h_rd(h_rd),
    .a_pop(a_pop), .clr(clr), .arm(arm), .burst_len(burst_len),
    .h_rdata(h_rdata), .a_data(a_data), .a_valid(a_valid),
    .level(level), .full(full), .empty(empty),
    .burst_done(burst_done), .irq(irq), .pops(pops)
  );

  always #5 clk = ~clk;

  task wr(input [7:0] b);
    begin
      @(negedge clk); h_wdata = b; h_wr = 1;
      @(negedge clk); h_wr = 0;
    end
  endtask

  task rd(input [7:0] want);
    begin
      @(negedge clk);
      if (h_rdata !== want) begin
        errs = errs + 1; $display("FAIL read got 0x%02x want 0x%02x", h_rdata, want);
      end
      h_rd = 1;
      @(negedge clk); h_rd = 0;
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk); clr = 0;
    repeat (2) @(negedge clk);

    if (!empty || level != 0) begin errs = errs + 1; $display("FAIL not empty after reset"); end

    for (i = 0; i < 5; i = i + 1) wr(8'h10 + i[7:0]);
    @(negedge clk);
    if (level != 5) begin errs = errs + 1; $display("FAIL level %0d want 5", level); end

    rd(8'h10); rd(8'h11); rd(8'h12);
    @(negedge clk);
    if (level != 2) begin errs = errs + 1; $display("FAIL level after 3 reads %0d", level); end

    // assist drains the rest with no host involvement, burst of 2
    burst_len = 5'd2; arm = 1;
    @(negedge clk); arm = 0;
    if (a_data !== 8'h13 || !a_valid) begin
      errs = errs + 1; $display("FAIL assist head 0x%02x valid=%0b", a_data, a_valid);
    end
    @(negedge clk); a_pop = 1;
    @(negedge clk); a_pop = 0;
    @(negedge clk); a_pop = 1;
    @(negedge clk); a_pop = 0;
    @(negedge clk);
    if (!burst_done || !irq) begin errs = errs + 1; $display("FAIL burst_done=%0b irq=%0b", burst_done, irq); end
    if (!empty) begin errs = errs + 1; $display("FAIL not empty after assist drain"); end

    // fill to full and check the overflow guard
    for (i = 0; i < 16; i = i + 1) wr(i[7:0]);
    @(negedge clk);
    if (!full || level != 16) begin errs = errs + 1; $display("FAIL full=%0b level=%0d", full, level); end
    wr(8'hEE);
    @(negedge clk);
    if (level != 16 || !full) begin errs = errs + 1; $display("FAIL overflow changed level"); end

    if (errs == 0) $display("TB_FIFO PASS");
    else           $display("TB_FIFO FAIL (%0d errors)", errs);
    $finish;
  end

  initial begin
    #100000;
    $display("TB_FIFO FAIL (timeout)");
    $finish;
  end
endmodule
