// =============================================================================
// Assist byte-stream FIFO / mini-DMA (PROTEUS hybrid-assist study).
//
// 16 x 8 synchronous FIFO with two clients:
//   host  : h_wr / h_rd (the SPI window)
//   assist: a_pop / a_data (a hardware assist drains bytes with no CPU)
// A burst counter arms on `arm`, counts a_pop events and raises `burst_done`
// (and `irq`) when the programmed length has drained, so an engine can sleep
// on the IRQ line instead of polling.
// =============================================================================
module assist_fifo #(
  parameter integer DEPTH = 16,
  parameter integer AW    = 4,
  /* verilator lint_off UNUSEDPARAM */
  // CW is the count width the study benches pass explicitly.  The block
  // derives its count width from AW, so CW is retained only to keep the
  // measured instantiation signature (studies/hybrid/tb/tb_fifo.v) valid.
  parameter integer CW    = 5
  /* verilator lint_on UNUSEDPARAM */
) (
  input  wire          clk,
  input  wire          rst_n,
  input  wire          h_wr,
  input  wire [7:0]    h_wdata,
  input  wire          h_rd,
  input  wire          a_pop,
  input  wire          clr,
  input  wire          arm,
  input  wire [AW:0]   burst_len,
  output wire [7:0]    h_rdata,
  output wire [7:0]    a_data,
  output wire          a_valid,
  output wire [AW:0]   level,
  output wire          full,
  output wire          empty,
  output reg           burst_done,
  output wire          irq,
  output wire [AW:0]   pops
);

  reg [7:0] mem [0:DEPTH-1];
  reg [AW-1:0] rd, wr;
  reg [AW:0]   cnt;
  reg [AW:0]   pops_r;

  wire do_wr = h_wr & ~full;
  wire do_rd = h_rd & ~empty;
  wire do_ap = a_pop & ~empty;

  assign empty   = (cnt == {(AW+1){1'b0}});
  assign full    = (cnt == DEPTH[AW:0]);
  assign level   = cnt;
  assign h_rdata = mem[rd];
  assign a_data  = mem[rd];
  assign a_valid = ~empty;
  assign irq     = burst_done;
  assign pops    = pops_r;

  always @(posedge clk) begin
    if (!rst_n) begin
      rd   <= {AW{1'b0}};
      wr   <= {AW{1'b0}};
      cnt  <= {(AW+1){1'b0}};
      pops_r <= {(AW+1){1'b0}};
      burst_done <= 1'b0;
    end else if (clr) begin
      rd   <= {AW{1'b0}};
      wr   <= {AW{1'b0}};
      cnt  <= {(AW+1){1'b0}};
      pops_r <= {(AW+1){1'b0}};
      burst_done <= 1'b0;
    end else begin
      if (do_wr) begin
        mem[wr] <= h_wdata;
        wr      <= wr + {{(AW-1){1'b0}}, 1'b1};
      end
      if (do_rd | do_ap) begin
        rd <= rd + {{(AW-1){1'b0}}, 1'b1};
      end
      cnt <= cnt + (do_wr ? {{AW{1'b0}}, 1'b1} : {(AW+1){1'b0}})
                 - ((do_rd | do_ap) ? {{AW{1'b0}}, 1'b1} : {(AW+1){1'b0}});

      // burst bookkeeping: arm loads the length; every a_pop decrements.
      // A zero-length burst is complete on the arm; and a drained counter
      // must not underflow -- the v2 CSR exposes POPS, so a wrap would be
      // visible to software (an unarmed counter previously read 31 after two
      // pops).
      if (arm) begin
        pops_r     <= burst_len;
        burst_done <= (burst_len == {(AW+1){1'b0}});
      end else if (do_ap && (pops_r != {(AW+1){1'b0}})) begin
        if (pops_r == {{AW{1'b0}}, 1'b1}) begin
          pops_r     <= {(AW+1){1'b0}};
          burst_done <= 1'b1;
        end else begin
          pops_r <= pops_r - 1'b1;
        end
      end
    end
  end

endmodule
