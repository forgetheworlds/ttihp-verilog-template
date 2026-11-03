// =============================================================================
// NRZI encoder + bit stuffer for USB low-speed (1.5 Mbit/s).
//
// Line coding: 1 = no transition, 0 = transition.  J = {dp,dm} = 2'b01 (LS
// idle), K = 2'b10, SE0 = 2'b00.
// Stuffing: a 0 is inserted after six consecutive 1s.  The run counter is
// carried across bytes, so SYNC (0x80, LSB-first, = KJKJKJKK) obeys the same
// rule as the rest of the packet.
// EOP: eop_req emits SE0 for two bit times then J for one.
//
// The bit timer is free-running and never restarted at a byte boundary, so the
// output is bit-continuous (a gap would be a phase step for the receiver).
// ready = the one-deep byte queue can accept a byte.
// =============================================================================
module nrzi_enc #(
  parameter integer AW = 6            // div_r / counter width
) (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       en,
  input  wire [AW-1:0] div_r,
  input  wire [7:0] din,
  input  wire       din_we,
  input  wire       eop_req,
  output reg        dp,
  output reg        dm,
  output reg        tx_oe,
  output reg        bit_stb,
  output reg        tx_bit,        // data bit transmitted on this strobe
  output reg        busy,
  output reg        ready,
  output reg        overflow,
  output reg        eop_done
);

  localparam [2:0] S_IDLE = 3'd0,
                   S_DATA = 3'd1,
                   S_EOP0 = 3'd2,   // first SE0 bit time
                   S_EOP1 = 3'd3,   // second SE0 bit time
                   S_EOPJ = 3'd4;   // J bit after SE0

  reg [2:0]    st;
  reg [7:0]    sr;
  reg [7:0]    q;
  reg [3:0]    bi;                 // bits left in sr
  reg [2:0]    ones;
  reg [AW-1:0] cnt;
  reg          q_valid;

  wire [AW-1:0] div = (div_r == {AW{1'b0}}) ? {{(AW-1){1'b0}}, 1'b1} : div_r;
  wire tick       = (cnt == div - 1);
  wire stuff_next = (ones == 3'd6);
  wire cur        = (st == S_IDLE) ? q[0] : sr[0];

  always @(posedge clk) begin
    if (!rst_n) begin
      st       <= S_IDLE;
      sr       <= 8'h00;
      q        <= 8'h00;
      bi       <= 4'd0;
      ones     <= 3'd0;
      cnt      <= {AW{1'b0}};
      q_valid  <= 1'b0;
      dp       <= 1'b0;
      dm       <= 1'b1;           // J
      tx_oe    <= 1'b0;
      bit_stb  <= 1'b0;
      tx_bit   <= 1'b0;
      busy     <= 1'b0;
      ready    <= 1'b1;
      overflow <= 1'b0;
      eop_done <= 1'b0;
    end else if (!en) begin
      st      <= S_IDLE;
      dp      <= 1'b0;
      dm      <= 1'b1;
      tx_oe   <= 1'b0;
      busy    <= 1'b0;
      ones    <= 3'd0;
      q_valid <= 1'b0;
      ready   <= 1'b1;
      cnt     <= {AW{1'b0}};
    end else begin
      bit_stb  <= 1'b0;
      eop_done <= 1'b0;
      tx_oe    <= 1'b1;

      // one-deep byte queue
      if (din_we) begin
        if (q_valid) overflow <= 1'b1;
        else begin q <= din; q_valid <= 1'b1; end
      end
      ready <= ~q_valid & ~(din_we & ~q_valid);

      // free-running bit timer
      if (tick) begin
        cnt     <= {AW{1'b0}};
        bit_stb <= 1'b1;

        if (stuff_next) begin
          // stuffed 0: transition, consume no data bit
          ones   <= 3'd0;
          tx_bit <= 1'b0;
          dp   <= dm;
          dm   <= dp;
        end else begin
          case (st)
            S_IDLE: begin
              if (q_valid) begin
                q_valid <= 1'b0;
                sr      <= {1'b0, q[7:1]};   // q[0] is transmitted now
                bi      <= 4'd7;
                st      <= S_DATA;
                busy    <= 1'b1;
                tx_bit  <= cur;
                if (cur) ones <= ones + 3'd1;
                else begin ones <= 3'd0; dp <= dm; dm <= dp; end
              end else if (eop_req) begin   // queue already empty
                st <= S_EOP0;
                dp <= 1'b0;
                dm <= 1'b0;                  // SE0
              end else begin
                dp <= 1'b0;
                dm <= 1'b1;                  // idle J
                ones <= 3'd0;
              end
            end

            S_DATA: begin
              tx_bit <= cur;
              if (cur) ones <= ones + 3'd1;
              else begin ones <= 3'd0; dp <= dm; dm <= dp; end
              sr <= {1'b0, sr[7:1]};
              bi <= bi - 4'd1;
              if (bi == 4'd1) begin
                st   <= S_IDLE;
                busy <= 1'b0;
                // v2 fix for risk R2: do NOT enter EOP on this tick.  The
                // assignments below would overwrite the NRZI toggle that this
                // very tick drives for the last data bit (dp<=0, dm<=0 wins
                // over dp<=dm, dm<=dp), so the receiver never saw that bit's
                // edge and lost the final byte.  S_IDLE is reached on the next
                // bit time with the timer free-running, so the EOP starts
                // exactly one bit period after the last data bit began -- which
                // is what USB requires -- by the `else if (eop_req)` arm there.
              end
            end

            S_EOP0: begin
              dp <= 1'b0;
              dm <= 1'b0;
              st <= S_EOP1;
            end

            S_EOP1: begin
              dp <= 1'b0;
              dm <= 1'b1;                    // J
              st <= S_EOPJ;
            end

            S_EOPJ: begin
              dp       <= 1'b0;
              dm       <= 1'b1;
              st       <= S_IDLE;
              busy     <= 1'b0;
              eop_done <= 1'b1;
            end

            default: st <= S_IDLE;
          endcase
        end
      end else begin
        cnt <= cnt + {{(AW-1){1'b0}}, 1'b1};
      end
    end
  end

endmodule
