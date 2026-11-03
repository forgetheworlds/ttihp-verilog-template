// =============================================================================
// NRZI decoder + bit unstuffer + SYNC/EOP/SE0 detector for USB low-speed.
//
// Receiver: 2-FF synchroniser per line, J/K/SE0 decode, bit-boundary timer
// restarted by every line transition (NRZI edge DPLL: an edge *is* a bit
// boundary).  At a boundary the data bit is 0 when the boundary came from an
// edge and 1 when the timer expired without one.
//
// Framing recovery, as a USB device does it:
//   * bus idle  = no line transition for IDLE_BITS bit times;
//   * packet start = the first transition after idle (SOP).  That edge is by
//     definition bit 0 of SYNC (always 0), so it resets the stuffing run,
//     the byte phase and the SYNC window without dropping the bit;
//   * SYNC is found by a sliding 8-bit window, not byte alignment, and on a
//     match the byte counter restarts so the next bit begins the PID.
//
// After six 1s the next 0 is a stuffed bit and is discarded; a 1 there is a
// stuff error.  SE0 lasting EOP_BITS bit times is an EOP, RESET_BITS is a bus
// reset.
// =============================================================================
module nrzi_dec #(
  parameter integer AW         = 6,
  parameter integer IDLE_BITS  = 8,    // no-edge bit times that mean "bus idle"
  parameter integer EOP_BITS   = 1,    // SE0 bit times for an EOP (USB: >= 1)
  parameter integer RESET_BITS = 4     // SE0 bit times for a bus reset
) (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       en,
  input  wire [AW-1:0] div_r,
  input  wire       dp,
  input  wire       dm,
  output reg [7:0]  dout,
  output reg        dout_valid,
  output reg        sync_det,
  output reg        eop_det,
  output reg        reset_det,
  output reg        stuff_err,
  output reg        se0,
  output reg        busy,
  output reg        bit_out,        // decoded NRZI bit (for test/analysis)
  output reg        bit_valid
);

  reg dp_s1, dp_s2, dm_s1, dm_s2, dp_d;
  reg [AW-1:0]   cnt;
  reg [AW+2:0]   idle_cnt;
  reg            idle;
  reg [2:0]      ones;
  reg [2:0]      bcnt;
  reg [3:0]      sop_cnt;      // bits since SOP; SYNC window armed for 8
  /* verilator lint_off UNUSEDSIGNAL */
  // acc[0] / win[0] are the bits shifted out of the byte assembly window; the
  // measured block keeps 8-bit registers so the {bit, acc[7:1]} shift shape is
  // unchanged, and the linter correctly notes the low bit is never read.
  reg [7:0]      acc;
  reg [7:0]      win;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [AW+1:0]   se0_cnt;
  reg            eop_seen, rst_seen;

  wire [AW-1:0] div = (div_r == {AW{1'b0}}) ? {{(AW-1){1'b0}}, 1'b1} : div_r;
  wire line_se0 = (dp_s2 == 1'b0) && (dm_s2 == 1'b0);
  wire jk       = (dp_s2 ^ dm_s2);
  wire is_edge  = jk & (dp_s2 ^ dp_d);      // J<->K transition
  wire tick     = (cnt == div - 1);
  wire pkt_start = is_edge & idle;

  // 32-bit comparison domain: the study RTL compared AW-width counters against
  // unsized integer products, which verilator -Wall widens and then flags.
  // Zero-extending both sides makes the widths explicit with identical values.
  wire [31:0] div_x      = {{(32-AW){1'b0}}, div};
  wire [31:0] idle_cnt_x = {{(32-(AW+3)){1'b0}}, idle_cnt};
  wire [31:0] se0_cnt_x  = {{(32-(AW+2)){1'b0}}, se0_cnt};

  // A bit boundary is an edge (bit 0) or a timer expiry (bit 1); an edge that
  // coincides with an expiry wins and yields 0.
  wire bit_emit_w = (is_edge | tick) & ~line_se0 & ~idle;
  wire bit_dec_w  = tick & ~is_edge;
  wire [7:0] acc_n = {bit_dec_w, acc[7:1]};
  wire [7:0] win_n = {bit_dec_w, win[7:1]};   // same order as acc

  always @(posedge clk) begin
    if (!rst_n) begin
      dp_s1 <= 1'b0; dp_s2 <= 1'b0; dm_s1 <= 1'b1; dm_s2 <= 1'b1; dp_d <= 1'b0;
      cnt   <= {AW{1'b0}};
      idle_cnt <= {(AW+3){1'b0}};
      idle  <= 1'b0;
      ones  <= 3'd0;
      bcnt    <= 3'd0;
      sop_cnt <= 4'd0;
      acc     <= 8'h00;
      win     <= 8'h00;
      se0_cnt <= {(AW+2){1'b0}};
      dout <= 8'h00;
      dout_valid <= 1'b0;
      sync_det <= 1'b0;
      eop_det  <= 1'b0;
      reset_det <= 1'b0;
      stuff_err <= 1'b0;
      bit_out <= 1'b0;
      bit_valid <= 1'b0;
      se0 <= 1'b0;
      busy <= 1'b0;
      eop_seen <= 1'b0;
      rst_seen <= 1'b0;
    end else begin
      dp_s1 <= dp; dp_s2 <= dp_s1;
      dm_s1 <= dm; dm_s2 <= dm_s1;
      dp_d  <= dp_s2;
      dout_valid <= 1'b0;
      sync_det   <= 1'b0;
      eop_det    <= 1'b0;
      reset_det  <= 1'b0;
      stuff_err  <= 1'b0;
      bit_valid  <= 1'b0;
      se0        <= line_se0;

      if (!en) begin
        cnt  <= {AW{1'b0}};
        ones <= 3'd0;
        bcnt <= 3'd0;
        acc  <= 8'h00;
        win  <= 8'h00;
        busy <= 1'b0;
        idle <= 1'b0;
      end else begin
        // ---- bus-idle detector -------------------------------------------
        if (is_edge) begin
          idle_cnt <= {(AW+3){1'b0}};
          idle     <= 1'b0;
        end else if (!idle) begin
          if (idle_cnt_x >= IDLE_BITS * div_x)
            idle <= 1'b1;
          else
            idle_cnt <= idle_cnt + 1'b1;
        end

        // ---- SE0 / EOP / reset -------------------------------------------
        if (line_se0) begin
          if (!eop_seen && (se0_cnt_x >= EOP_BITS * div_x)) begin
            eop_det  <= 1'b1;
            eop_seen <= 1'b1;
          end
          if (!rst_seen && (se0_cnt_x >= RESET_BITS * div_x)) begin
            reset_det <= 1'b1;
            rst_seen  <= 1'b1;
            bcnt      <= 3'd0;
            acc       <= 8'h00;
            ones      <= 3'd0;
          end
          if (se0_cnt != {(AW+2){1'b1}}) se0_cnt <= se0_cnt + 1'b1;
        end else begin
          se0_cnt  <= {(AW+2){1'b0}};
          eop_seen <= 1'b0;
          rst_seen <= 1'b0;
        end

        // ---- bit boundary / NRZI decode ----------------------------------
        if (pkt_start) begin
          // SOP: this edge is bit 0 of SYNC (always 0).  Reset framing and
          // seed the byte counter with that bit instead of losing it.
          cnt  <= {AW{1'b0}};
          busy <= 1'b1;
          ones    <= 3'd0;
          win     <= 8'h00;
          acc     <= 8'h00;
          bcnt    <= 3'd1;
          sop_cnt <= 4'd1;
          bit_out   <= 1'b0;      // SOP edge is SYNC bit 0
          bit_valid <= 1'b1;
        end else if (!line_se0 && bit_emit_w) begin  // not while idle
          cnt  <= {AW{1'b0}};
          busy <= 1'b1;
          if ((ones == 3'd6) && (bit_dec_w == 1'b0)) begin
            ones <= 3'd0;                       // stuffed 0: discard
          end else if ((ones == 3'd6) && (bit_dec_w == 1'b1)) begin
            stuff_err <= 1'b1;                  // seven 1s
            ones      <= 3'd0;
          end else begin
            ones <= bit_dec_w ? (ones + 3'd1) : 3'd0;
            win  <= win_n;
            if (sop_cnt != 4'd9) sop_cnt <= sop_cnt + 4'd1;
            bit_out   <= bit_dec_w;
            bit_valid <= 1'b1;
            // The SYNC window is armed only for the 8 bits after SOP: a data
            // run of seven 0s followed by a 1 also forms 0x80 and must not
            // realign the byte counter mid-packet.
            if ((sop_cnt <= 4'd7) && (win_n == 8'h80)) begin
              sync_det <= 1'b1;                 // SYNC found (bit-serial)
              bcnt     <= 3'd0;                 // next bit starts the PID
              acc      <= 8'h00;
              sop_cnt  <= 4'd9;                 // disarm
            end else begin
              acc <= acc_n;
              if (bcnt == 3'd7) begin
                bcnt       <= 3'd0;
                dout       <= acc_n;
                dout_valid <= 1'b1;
                acc        <= 8'h00;
              end else begin
                bcnt <= bcnt + 3'd1;
              end
            end
          end
        end else if (!line_se0) begin
          cnt <= (cnt == div - 1) ? {AW{1'b0}}
                                  : cnt + {{(AW-1){1'b0}}, 1'b1};
        end else begin
          cnt  <= {AW{1'b0}};
          ones <= 3'd0;
        end
      end
    end
  end

endmodule
