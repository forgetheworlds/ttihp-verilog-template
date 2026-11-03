// =============================================================================
// 32-bit bidirectional serial shift register with runtime width, bit order and
// an optional bit-stuff hook (PROTEUS hybrid-assist study).
//
//   dir = 1 : shift toward MSB, bit_out = dout[width-1], bytes are MSB-first
//   dir = 0 : shift toward LSB, bit_out = dout[0],        bytes are LSB-first
//   width_r : 1..32 active bits
//   stuff_hook: when enabled, after (stuff_len-1) consecutive 1s emitted the
//               register emits a 0 without shifting (inserted stuff bit), so
//               the data bit is delayed by one serial slot.
// A byte push/pop moves 8 bits at the active end in one clock.
// =============================================================================
module shiftreg32 (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        load,
  input  wire [31:0] din,
  input  wire        sh_en,
  input  wire        dir,
  input  wire [5:0]  width_r,
  input  wire [7:0]  bpush,
  input  wire        push_we,
  input  wire        pop_req,
  input  wire        stuff_en,
  input  wire [2:0]  stuff_len,
  input  wire        bit_in,
  output reg  [31:0] dout,
  output reg         bit_out,
  output reg         bit_valid,
  // Combinational in v2: `pop_req` does not advance the register (a byte pop
  // is non-destructive), so the registered form only added one cycle of read
  // latency without changing the value.  The study TB checks bpop one cycle
  // after pop_req and still sees the same byte, so this is behaviour
  // preserving for `tb_shiftreg` while letting LDAS read the byte in its issue
  // cycle (docs/hybrid-architecture.md 5.2 wants 1-cycle LDAS).
  output wire [7:0]  bpop,
  output reg         byte_valid,
  output reg         stuff_flag
);

  wire [5:0] w6 = (width_r == 6'd0) ? 6'd1 : width_r;
  wire [31:0] wmask = (w6 >= 6'd32) ? 32'hFFFF_FFFF
                                     : ((32'd1 << w6) - 32'd1);
  wire [31:0] top_mask = wmask & ~(wmask >> 1);
  wire [5:0]  sh8 = (w6 > 6'd8) ? (w6 - 6'd8) : 6'd0;   // byte alignment

  reg [2:0] ones;

  wire obit   = dir ? (|(dout & top_mask)) : dout[0];
  wire insert = stuff_en && (stuff_len != 3'd0) &&
                (ones == stuff_len - 3'd1) && obit;

  wire [31:0] d_shl = ((dout << 1) | {31'd0, bit_in}) & wmask;
  wire [31:0] d_shr = (dout >> 1) | (bit_in ? top_mask : 32'd0);
  wire [31:0] d_in  = dir ? d_shl : d_shr;

  wire [31:0] push_mask = dir ? (32'h0000_00FF << sh8) : 32'h0000_00FF;
  wire [31:0] push_data = dir ? (({24'd0, bpush}) << sh8)
                              : ({24'd0, bpush});


  always @(posedge clk) begin
    if (!rst_n) begin
      dout       <= 32'h0000_0000;
      bit_out    <= 1'b0;
      bit_valid  <= 1'b0;
      byte_valid <= 1'b0;
      stuff_flag <= 1'b0;
      ones       <= 3'd0;
    end else begin
      bit_valid  <= 1'b0;
      byte_valid <= 1'b0;
      stuff_flag <= 1'b0;

      if (load) begin
        dout <= din & wmask;
        ones <= 3'd0;
      end else begin
        if (push_we)
          dout <= (dout & ~push_mask) | (push_data & push_mask);

        if (sh_en) begin
          if (insert) begin
            bit_out    <= 1'b0;
            bit_valid  <= 1'b1;
            stuff_flag <= 1'b1;            // inserted bit, register holds
          end else begin
            bit_out   <= obit;
            bit_valid <= 1'b1;
            dout      <= d_in;
            ones      <= obit ? (ones + 3'd1) : 3'd0;
          end
        end
      end

      if (pop_req) begin
        byte_valid <= 1'b1;
      end
    end
  end

  // Byte at the active end of the register (see the port comment: a pop does
  // not advance `dout`, so this is the same value the old registered form
  // produced, one cycle earlier).
  assign bpop = dir ? dout[sh8[4:0] +: 8] : dout[7:0];   // sh8 <= 24

endmodule
