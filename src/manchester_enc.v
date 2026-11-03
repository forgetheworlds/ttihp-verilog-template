// =============================================================================
// Manchester encoder (IEEE 802.3 convention: 1 = 0->1 at mid-bit).
//
// One half-bit every HALF_DIV clocks; 16 half-bits per byte, LSB first.
// Designed for 10BASE-T at 20 Mbaud: HALF_DIV = 4 gives 20 Mbaud at 80 MHz.
//
// A one-deep byte queue keeps the output bit-continuous: the next byte is
// loaded in the tick that emits the last half-bit of the current one, so there
// is never an idle half-cell between bytes (Ethernet sends preamble and data as
// one uninterrupted train; a gap is a phase step for the receiver).
// ready = the queue can accept a byte.
// =============================================================================
module manchester_enc #(
  parameter integer HALF_DIV = 4,   // clk cycles per half-bit
  parameter integer AW       = 4
) (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       en,
  input  wire [7:0] din,
  input  wire       din_we,
  output reg        tx,
  output reg        half_stb,      // 1-clock pulse on every half-bit boundary
  output reg        busy,
  output reg        ready,
  output reg        overflow
);

  reg [7:0]    sr;                 // remaining bits of the byte in flight
  reg [7:0]    q;                  // one-deep queue
  reg          cur_bit;            // bit whose second half is still to come
  reg [3:0]    bi;                 // bits remaining after the current one
  reg          hp;                 // 1 = the next half is the second one
  reg          q_valid;
  reg [AW-1:0] cnt;

  wire [31:0] cnt_x = {{(32-AW){1'b0}}, cnt};
  wire tick = (cnt_x == HALF_DIV - 1);

  always @(posedge clk) begin
    if (!rst_n) begin
      sr       <= 8'h00;
      q        <= 8'h00;
      cur_bit  <= 1'b0;
      bi       <= 4'd0;
      hp       <= 1'b0;
      q_valid  <= 1'b0;
      cnt      <= {AW{1'b0}};
      tx       <= 1'b1;
      half_stb <= 1'b0;
      busy     <= 1'b0;
      ready    <= 1'b1;
      overflow <= 1'b0;
    end else if (!en) begin
      sr      <= 8'h00;
      bi      <= 4'd0;
      hp      <= 1'b0;
      q_valid <= 1'b0;
      cnt     <= {AW{1'b0}};
      tx      <= 1'b1;
      busy    <= 1'b0;
      ready   <= 1'b1;
    end else begin
      half_stb <= 1'b0;

      if (din_we) begin
        if (q_valid) overflow <= 1'b1;
        else begin q <= din; q_valid <= 1'b1; end
      end
      ready <= ~q_valid & ~(din_we & ~q_valid);

      if (tick) begin
        cnt      <= {AW{1'b0}};
        half_stb <= 1'b1;

        if (!busy) begin
          if (q_valid) begin
            // first half of bit 0, and consume the queued byte
            tx      <= ~q[0];
            cur_bit <= q[0];
            sr      <= {1'b0, q[7:1]};
            q_valid <= 1'b0;
            bi      <= 4'd7;
            hp      <= 1'b1;
            busy    <= 1'b1;
          end else begin
            tx <= 1'b1;                       // idle high between packets
          end
        end else if (!hp) begin
          tx      <= ~sr[0];                  // first half
          cur_bit <= sr[0];
          sr      <= {1'b0, sr[7:1]};
          bi      <= bi - 4'd1;
          hp      <= 1'b1;
        end else begin
          tx <= cur_bit;                      // second half
          hp <= 1'b0;
          if (bi == 4'd0) begin
            if (q_valid) begin
              sr      <= q;                   // full byte; next tick emits bit 0
              q_valid <= 1'b0;
              bi      <= 4'd8;
            end else begin
              busy <= 1'b0;
            end
          end
        end
      end else begin
        cnt <= cnt + {{(AW-1){1'b0}}, 1'b1};
      end
    end
  end

endmodule
