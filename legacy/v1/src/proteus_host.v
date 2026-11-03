// ===========================================================================
// proteus_host.v -- PROTEUS host interface: SPI mode 0 (CPOL=0, CPHA=0) slave,
// command decoder and 16-bit register pointer (docs/architecture.md sec. 6).
//
// Decisions / deviations -- read before editing:
//
//  1. REGISTER BUS CONTRACT (with tt_um_proteus):
//       reg_we / reg_addr / reg_wdata : one-clk write pulse in the clk domain.
//       reg_re / reg_raddr            : one-clk read request pulse; reg_rdata
//                                       must be valid *combinationally* while
//                                       reg_re is high.  This module samples
//                                       reg_rdata one clk later, so a top-level
//                                       read mux (and a FIFO pop side effect
//                                       that takes effect on the closing edge)
//                                       both behave: the value sampled is the
//                                       pre-pop head.
//     Read requests are issued one bit-time ahead of the byte boundary, i.e.
//     at the 7th rising edge of the byte that is being clocked out (and at the
//     command's 8th edge for the first response byte), so the answer is stable
//     long before the falling edge that shifts it onto MISO.
//
//  2. SOFT_RESET (0x0006) and HOST_EN (0x0007) are consumed *here*: the port
//     list in architecture.md sec. 7 has no input for them and this module is
//     the only owner of both bits.  A write to 0x0006 pulses soft_reset; a
//     write to 0x0007 loads host_en from wdata[0].  The top ignores both
//     addresses on writes and returns {7'b0, host_en} for 0x0007 reads.
//
//  3. SCK/CS_N/MOSI are asynchronous.  They are synchronised with two FFs and
//     both SCK edges are taken from the *synchronised* clock.  A registered
//     MISO that changes on the synchronised falling edge needs 3 clk from the
//     raw falling edge, so the "SCK <= clk/4" figure in the docs cannot be met
//     at the absolute limit with a two-FF synchroniser: SCK <= clk/8 is fully
//     clean (verified), clk/6 is marginal, clk/4 is short by one clk.  MISO is
//     still never driven while CS_N is high, and mode-0 sampling at the rising
//     edge is always satisfied at SCK <= clk/8.
//
//  4. MOSI is sampled with the edge detect and then compensated for the two
//     synchroniser stages plus two pipeline stages (mosi_d2), so the sample is
//     taken from inside the master's data eye rather than after the following
//     falling edge.  Required at clk/8 and above; harmless at slow clocks.
//
//  5. HOST_DISABLE and SOFT_RESET abort the current frame (S_DEAD until CS_N
//     rises).  Later frames are still decoded even though host_en is 0: the
//     pins are released to the fabric, but a fabric that bit-bangs SCK/CS/MOSI
//     (or a host that keeps driving) can still reach the register map.  The
//     pins themselves are gated by host_en in the top.
// ===========================================================================

`default_nettype none

module proteus_host (
  input  wire        clk,
  input  wire        rst_n,        // synchronous, active low
  input  wire        sck,          // raw SPI clock (asynchronous)
  input  wire        cs_n,         // raw SPI chip select, active low
  input  wire        mosi,         // raw SPI data in
  output wire        miso,         // SPI data out (0 while CS_N is high)
  output reg         reg_we,
  output reg  [15:0] reg_addr,
  output reg  [7:0]  reg_wdata,
  output reg         reg_re,
  output reg  [15:0] reg_raddr,
  input  wire [7:0]  reg_rdata,
  output reg         host_en,      // 1 = host owns SCK/CS_N/MOSI/MISO pins
  output reg         soft_reset
);

  `include "proteus_defs.vh"

  // ------------------------------------------------------------ states
  localparam [3:0] S_IDLE  = 4'd0,
                   S_CMD   = 4'd1,
                   S_WR    = 4'd2,
                   S_RD    = 4'd3,
                   S_PTRLO = 4'd4,
                   S_PTRHI = 4'd5,
                   S_WALO  = 4'd6,
                   S_WAHI  = 4'd7,
                   S_WDATA = 4'd8,
                   S_RALO  = 4'd9,
                   S_RAHI  = 4'd10,
                   S_RDATA = 4'd11,
                   S_PING  = 4'd12,
                   S_DEAD  = 4'd13;

  // ------------------------------------------------------ input synchronisers
  reg sck_m, sck_s, sck_d;      // 2FF synchroniser + 1 delay stage
  reg cs_m,  cs_s,  cs_d;
  reg mosi_m, mosi_s, mosi_d1, mosi_d2;

  always @(posedge clk) begin
    if (!rst_n) begin
      sck_m <= 1'b0;  sck_s <= 1'b0;  sck_d <= 1'b0;
      cs_m  <= 1'b1;  cs_s  <= 1'b1;  cs_d  <= 1'b1;
      mosi_m <= 1'b0; mosi_s <= 1'b0; mosi_d1 <= 1'b0; mosi_d2 <= 1'b0;
    end else begin
      sck_m  <= sck;
      sck_s  <= sck_m;
      sck_d  <= sck_s;
      cs_m   <= cs_n;
      cs_s   <= cs_m;
      cs_d   <= cs_s;
      mosi_m <= mosi;
      mosi_s <= mosi_m;
      mosi_d1 <= mosi_s;
      mosi_d2 <= mosi_d1;
    end
  end

  wire rise    = sck_s & ~sck_d;   // synchronised SCK rising edge
  wire fall    = ~sck_s & sck_d;   // synchronised SCK falling edge
  wire cs_fall = cs_d & ~cs_s;     // CS_N asserted
  wire cs_rise = ~cs_d & cs_s;     // CS_N released (frame end)

  // ------------------------------------------------------------ FSM state
  reg [3:0]  state;
  reg [2:0]  bit_cnt;              // index of the bit currently on MISO
  reg [6:0]  shreg;                // MOSI receive shift register (7 held bits)
  reg [15:0] ptr;
  reg [15:0] addr;
  reg [7:0]  tx_byte;              // byte being shifted out (MSB first)
  reg        miso_q;
  reg [7:0]  rd_data_q;            // registered read answer
  reg        rd_fetch_pending;
  reg        tx_load_pending;      // load tx_byte from rd_data_q at next edge

  wire [7:0] byte_in = {shreg, mosi_d2};

  // MISO is only driven while the frame is open (CS_N low, raw pin so the pin
  // is released immediately at the frame end).
  assign miso = cs_n ? 1'b0 : miso_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      state            <= S_IDLE;
      bit_cnt          <= 3'd0;
      shreg            <= 7'h00;
      ptr              <= 16'h0000;
      addr             <= 16'h0000;
      tx_byte          <= 8'h00;
      miso_q           <= 1'b0;
      rd_data_q        <= 8'h00;
      rd_fetch_pending <= 1'b0;
      tx_load_pending  <= 1'b0;
      reg_we           <= 1'b0;
      reg_addr         <= 16'h0000;
      reg_wdata        <= 8'h00;
      reg_re           <= 1'b0;
      reg_raddr        <= 16'h0000;
      host_en          <= 1'b1;
      soft_reset       <= 1'b0;
    end else begin
      // ------------------------------------------------ one-cycle pulses
      reg_we     <= 1'b0;
      reg_re     <= 1'b0;
      soft_reset <= 1'b0;

      // Read answer capture: exactly one clk after the request was issued.
      if (rd_fetch_pending) begin
        rd_data_q        <= reg_rdata;
        rd_fetch_pending <= 1'b0;
      end

      // Intercept the two register writes this module owns.  It snoops its
      // *registered* write pulse, so the action lands one clk after the write.
      if (reg_we) begin
        if (reg_addr == `PROTEUS_RA_HOST_EN) begin
          host_en <= reg_wdata[0];
        end else if (reg_addr == `PROTEUS_RA_SOFT_RESET) begin
          soft_reset <= 1'b1;
          state      <= S_DEAD;
        end
      end

      // ------------------------------------------------------ SPI framing
      if (cs_rise) begin
        state           <= S_IDLE;
        bit_cnt         <= 3'd0;
        tx_byte         <= 8'h00;
        miso_q          <= 1'b0;
        tx_load_pending <= 1'b0;
      end else if (cs_fall) begin
        state           <= S_CMD;
        bit_cnt         <= 3'd0;
        shreg           <= 7'h00;
        tx_byte         <= 8'h00;
        miso_q          <= 1'b0;
        tx_load_pending <= 1'b0;
      end else if ((state == S_DEAD) || (state == S_IDLE)) begin
        // frame aborted / not started: ignore SCK until CS_N moves
      end else if (rise) begin
        // ------------------------------------------------ MOSI sampling
        shreg <= {shreg[5:0], mosi_d2};
        if (bit_cnt != 3'd7) begin
          // still inside the byte: fetch the next answer one bit early
          if (bit_cnt == 3'd6) begin
            if (state == S_RD) begin
              reg_re           <= 1'b1;
              reg_raddr        <= ptr + 16'd1;
              rd_fetch_pending <= 1'b1;
            end else if (state == S_RDATA) begin
              reg_re           <= 1'b1;
              reg_raddr        <= addr + 16'd1;
              rd_fetch_pending <= 1'b1;
            end
          end
          bit_cnt <= bit_cnt + 3'd1;
          miso_q  <= tx_byte[6 - bit_cnt];   // next bit, sampled MSB first
        end else begin
          // ------------------------------------------------ byte complete
          bit_cnt  <= 3'd0;
          tx_byte  <= 8'h00;
          case (state)
            S_CMD: begin
              case (byte_in)
                `PROTEUS_CMD_WRITE_INC: state <= S_WR;
                `PROTEUS_CMD_READ_INC: begin
                  state            <= S_RD;
                  reg_re           <= 1'b1;
                  reg_raddr        <= ptr;
                  rd_fetch_pending <= 1'b1;
                  tx_load_pending  <= 1'b1;
                end
                `PROTEUS_CMD_SET_PTR_LO: state <= S_PTRLO;
                `PROTEUS_CMD_SET_PTR_HI: state <= S_PTRHI;
                `PROTEUS_CMD_WRITE_ADDR: state <= S_WALO;
                `PROTEUS_CMD_READ_ADDR:  state <= S_RALO;
                `PROTEUS_CMD_PING: begin
                  state   <= S_PING;
                  tx_byte <= 8'h50;
                end
                `PROTEUS_CMD_SOFT_RESET: begin
                  state      <= S_DEAD;
                  soft_reset <= 1'b1;
                end
                `PROTEUS_CMD_HOST_DISABLE: begin
                  state   <= S_DEAD;
                  host_en <= 1'b0;
                end
                default: state <= S_CMD;          // NOP and unknown opcodes
              endcase
            end
            S_WR: begin
              reg_we    <= 1'b1;
              reg_addr  <= ptr;
              reg_wdata <= byte_in;
              ptr       <= ptr + 16'd1;
            end
            S_RD: begin
              ptr              <= ptr + 16'd1;
              tx_load_pending  <= 1'b1;   // answer fetched at bit 6
            end
            S_PTRLO: begin
              ptr   <= {ptr[15:8], byte_in};
              state <= S_CMD;
            end
            S_PTRHI: begin
              ptr   <= {byte_in, ptr[7:0]};
              state <= S_CMD;
            end
            S_WALO: begin
              addr  <= {addr[15:8], byte_in};
              state <= S_WAHI;
            end
            S_WAHI: begin
              addr  <= {byte_in, addr[7:0]};
              state <= S_WDATA;
            end
            S_WDATA: begin
              reg_we    <= 1'b1;
              reg_addr  <= addr;
              reg_wdata <= byte_in;
              addr      <= addr + 16'd1;
            end
            S_RALO: begin
              addr  <= {addr[15:8], byte_in};
              state <= S_RAHI;
            end
            S_RAHI: begin
              addr             <= {byte_in, addr[7:0]};
              reg_re           <= 1'b1;
              reg_raddr        <= {byte_in, addr[7:0]};
              rd_fetch_pending <= 1'b1;
              tx_load_pending  <= 1'b1;
              state            <= S_RDATA;
            end
            S_RDATA: begin
              addr             <= addr + 16'd1;
              tx_load_pending  <= 1'b1;   // answer fetched at bit 6
            end
            S_PING: begin
              tx_byte <= 8'h50;           // re-arm for repeated PING reads
            end
            default: begin
              state <= S_CMD;
            end
          endcase
        end
      end else if (fall) begin
        // ------------------------------------------------ MISO shift / load
        if (tx_load_pending) begin
          tx_byte         <= rd_data_q;
          miso_q          <= rd_data_q[7];
          tx_load_pending <= 1'b0;
        end else begin
          miso_q <= tx_byte[7 - bit_cnt];
        end
      end
    end
  end

endmodule

`default_nettype wire
