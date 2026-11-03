// =============================================================================
// crc_bit -- one LFSR step per clock, same register semantics as crc_engine.
//
// Eight of these steps (a 3-bit counter in the surrounding glue) make one byte,
// which is what a 10 Mbit/s MII or a 1.5 Mbit/s USB LS link actually needs: a
// byte arrives every 38 or 256 clocks at 48 MHz, so 8 clocks per byte is free.
// Measured for the study's "minimum assist set" argument.
// =============================================================================
module crc_bit #(
  parameter integer FIXED_REFLECT = -1
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        cfg_we,
  input  wire [1:0]  cfg_sel,
  input  wire [31:0] cfg_data,
  input  wire        start,
  input  wire        bit_en,
  input  wire        bit_in,        // next transmitted bit
  output wire [31:0] crc_out,
  output wire        crc_bit_out,
  output wire        refl_out
);

  reg [31:0] init_r, poly_r, xorout_r, crc_r;
  reg [5:0]  width_r;
  reg        refl_r;

  wire refl = (FIXED_REFLECT >= 0) ? (FIXED_REFLECT != 0) : refl_r;
  assign refl_out = refl;

  wire [5:0]  sh     = 6'd32 - width_r;
  wire [31:0] mask   = (width_r >= 6'd32) ? 32'hFFFF_FFFF
                                           : ((32'd1 << width_r) - 32'd1);
  wire [31:0] poly_a = poly_r << sh;
  wire [31:0] init_a = init_r << sh;
  wire [31:0] poly_rf = poly_r & mask;

  wire [31:0] nc = refl
      ? ((crc_r >> 1) ^ (poly_rf & {32{crc_r[0] ^ bit_in}}))
      : ((crc_r << 1) ^ (poly_a  & {32{crc_r[31] ^ bit_in}}));

  wire [31:0] crc_nat = refl ? crc_r : (crc_r >> sh);

  assign crc_out    = crc_nat ^ xorout_r;
  assign crc_bit_out = refl ? crc_r[0] : crc_r[31];

  always @(posedge clk) begin
    if (!rst_n) begin
      init_r   <= 32'hFFFF_FFFF;
      poly_r   <= 32'h04C1_1DB7;
      xorout_r <= 32'hFFFF_FFFF;
      width_r  <= 6'd32;
      refl_r   <= 1'b0;
      crc_r    <= 32'h0000_0000;
    end else begin
      if (cfg_we) begin
        case (cfg_sel)
          2'd0: init_r   <= cfg_data;
          2'd1: poly_r   <= cfg_data;
          2'd2: begin
                  width_r <= (cfg_data[5:0] == 6'd0) ? 6'd1 : cfg_data[5:0];
                  refl_r  <= cfg_data[6];
                  // cfg_data[7] (caller's bit order) is not stored here: the
                  // caller shifts out the byte, so the bit order belongs to it
                  // (proteus_assist keeps it in the CFG0 shadow register).
                end
          default: xorout_r <= cfg_data;
        endcase
      end
      if (start)
        crc_r <= refl ? (init_r & mask) : init_a;
      else if (bit_en)
        crc_r <= nc;
    end
  end

endmodule
