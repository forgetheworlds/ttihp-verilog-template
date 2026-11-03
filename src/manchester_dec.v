// =============================================================================
// Manchester decoder with a 4x/8x oversampling digital receiver.
//
// Assumes clk = 20 MHz * OS (OS = 4 -> 80 MHz, OS = 8 -> 160 MHz), i.e. a
// 10 Mbit/s bit cell is 2*OS clocks and a half-bit is OS clocks.
//
// Receiver: 2-FF synchroniser -> edge detector -> phase accumulator snapped to
// the nearest legal edge position (bit boundary or half-bit), a 1-bit
// quantised phase detector.  A bit is decoded from the two half-cell samples:
// 0,1 -> 1 and 1,0 -> 0; equal halves are a Manchester violation.
// Edges outside OS/4 samples raise phase_err and drop lock.
// =============================================================================
module manchester_dec #(
  parameter integer OS = 4
) (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       en,
  input  wire       rx,
  output reg        bit_out,
  output reg        bit_valid,
  output reg [7:0]  dout,
  output reg        dout_valid,
  output reg        locked,
  output reg        phase_err,      // pulse: edge outside the snap window
  output reg        manch_err       // pulse: identical halves
);

  // Sized so the comparisons and subtractions below stay single-width under
  // the -Wall lint (the study RTL used integer parameters, which the linter
  // widens to 32 bits and then truncates back).  Values are unchanged.
  // The truncation warnings on these five initialisers are suppressed because
  // the legal OS range is 4..8, i.e. BP <= 16, Q3 <= 12, PTOL <= 2: every
  // constant fits in the declared 5 bits by construction.
  /* verilator lint_off WIDTHTRUNC */
  localparam [4:0] BP   = 2 * OS;          // clocks per bit (8 or 16)
  localparam [4:0] HALF = OS;
  localparam [4:0] Q1   = OS / 2;          // first-half sample point
  localparam [4:0] Q3   = OS + (OS / 2);   // second-half sample point
  localparam [4:0] PTOL = OS / 4;          // snap tolerance
  /* verilator lint_on WIDTHTRUNC */

  reg rx_s1, rx_s2, rx_d;
  reg [4:0] ph;                              // 0 .. BP-1
  reg       s1;
  reg [2:0] lock_cnt;
  reg [2:0] bcnt;
  /* verilator lint_off UNUSEDSIGNAL */
  // acc[0] / win[0] are the bits shifted out of the byte assembly window; the
  // measured block keeps 8-bit registers so the {bit, acc[7:1]} shift shape is
  // unchanged, and the linter correctly notes the low bit is never read.
  reg [7:0] acc;
  /* verilator lint_on UNUSEDSIGNAL */

  wire rx_sync = rx_s2;
  wire is_edge    = rx_sync ^ rx_d;

  // Distance to the nearest legal edge position and which one it is.
  reg [4:0] d_bnd, d_half;
  reg       to_half;
  reg [4:0] snap, perr;
  always @* begin
    d_bnd   = (ph < (BP - ph)) ? ph : (BP - ph);
    d_half  = (ph > HALF) ? (ph - HALF) : (HALF - ph);
    to_half = (d_half < d_bnd);
    snap    = to_half ? HALF : 5'd0;
    perr    = to_half ? d_half : d_bnd;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      rx_s1      <= 1'b1;
      rx_s2      <= 1'b1;
      rx_d       <= 1'b1;
      ph         <= 5'd0;
      s1         <= 1'b1;
      lock_cnt   <= 3'd0;
      bcnt       <= 3'd0;
      acc        <= 8'h00;
      bit_out    <= 1'b0;
      bit_valid  <= 1'b0;
      dout       <= 8'h00;
      dout_valid <= 1'b0;
      locked     <= 1'b0;
      phase_err  <= 1'b0;
      manch_err  <= 1'b0;
    end else begin
      rx_s1 <= rx;
      rx_s2 <= rx_s1;
      rx_d  <= rx_s2;
      bit_valid  <= 1'b0;
      dout_valid <= 1'b0;
      phase_err  <= 1'b0;
      manch_err  <= 1'b0;

      if (!en) begin
        ph       <= 5'd0;
        bcnt     <= 3'd0;
        acc      <= 8'h00;
        lock_cnt <= 3'd0;
        locked   <= 1'b0;
      end else begin
        // phase accumulator: free-runs, snapped by every input edge
        if (is_edge) begin
          ph <= snap;
          if (perr > PTOL) begin
            phase_err <= 1'b1;
            lock_cnt  <= 3'd0;
            locked    <= 1'b0;
          end else if (lock_cnt != 3'd7) begin
            lock_cnt <= lock_cnt + 3'd1;
            if (lock_cnt == 3'd6) locked <= 1'b1;
          end
        end else begin
          ph <= (ph == BP - 5'd1) ? 5'd0 : (ph + 5'd1);
        end

        // half-cell samples
        if (ph == Q1)
          s1 <= rx_sync;

        if (ph == Q3) begin
          if (rx_sync != s1) begin
            bit_out   <= rx_sync;               // 0,1 -> 1 ; 1,0 -> 0
            bit_valid <= 1'b1;
            acc       <= {rx_sync, acc[7:1]};   // LSB-first byte assembly
            if (bcnt == 3'd7) begin
              bcnt       <= 3'd0;
              dout       <= {rx_sync, acc[7:1]};
              dout_valid <= 1'b1;
            end else begin
              bcnt <= bcnt + 3'd1;
            end
          end else begin
            manch_err <= 1'b1;
          end
        end
      end
    end
  end

endmodule
