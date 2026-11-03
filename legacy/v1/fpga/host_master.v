// ===========================================================================
// host_master.v -- PROTEUS SPI host master + command sequencer (DE2 build)
//
// Drives the chip exactly per docs/architecture.md section 6: SPI mode 0
// (CPOL=0, CPHA=0), MSB first, CS_N framing, one command per frame.  The
// sequencer covers every command the boot loader needs, including the two
// pointer-based streaming commands and the two address-based ones:
//
//   HOP_PING        cmd 0x07, then one dummy byte -> rdata       (2 bytes)
//   HOP_SET_PTR     cmd 0x03 + ptr_lo, 0x04 + ptr_hi             (4 bytes)
//   HOP_WRITE_INC   cmd 0x01 + len bytes from wdata              (1+len)
//   HOP_READ_INC    cmd 0x02 + len dummy bytes -> rdata          (1+len)
//   HOP_WRITE_ADDR  cmd 0x05 + addr LE + len bytes from wdata    (3+len)
//   HOP_READ_ADDR   cmd 0x06 + addr LE + len dummy bytes -> rdata(3+len)
//   HOP_RESET       cmd 0x08 (soft reset; the frame is aborted on-chip)  (1)
//
// Byte-source / byte-sink contract (combinational, no handshake needed):
//   the caller drives wdata from widx, and reads rdata when rvalid pulses
//   with the corresponding ridx.  widx is the index of the write-data byte
//   within the frame's payload (0-based); ridx is the index of the returned
//   byte.  Both are stable for the whole byte time.
//
// Timing
//   SCK = clk / DIV, DIV = 16 -> 3.125 MHz on the DE2's 50 MHz oscillator.
//   The chip's slave synchronises SCK/CS_N/MOSI with two FFs and takes both
//   edges from the synchronised clock; proteus_host.v documents that
//   "SCK <= clk/8 is fully clean" for the chip, so clk/16 has 2x margin.
//   Per bit: HALF clocks low (MOSI changes here), HALF clocks high, MISO
//   sampled on the last high clock.  CS_N is asserted DIV clocks before the
//   first edge and released DIV/2 clocks after the last one, and DIV clocks
//   pass before `done`, so back-to-back frames are never seen as one frame.
//
// Verilog-2001: no SystemVerilog, no always_ff, no interfaces.
// ===========================================================================

`timescale 1ns / 1ps

`default_nettype none

module host_master #(
  parameter DIV = 16            // clk cycles per SCK period (16 = clk/16)
) (
  input  wire        clk,
  input  wire        rst_n,

  // ---------------------------------------------------- transaction request
  input  wire        start,     // 1-clk pulse, only honoured while !busy
  input  wire [2:0]  op,        // HOP_*
  input  wire [15:0] addr,      // pointer / address operand
  input  wire [7:0]  len,       // payload byte count
  output wire        busy,
  output reg         done,      // 1-clk pulse at the end of the frame

  // -------------------------------------------------------- write byte port
  output wire [7:0]  widx,      // index of the write-data byte being sent
  input  wire [7:0]  wdata,     // caller's byte for widx

  // --------------------------------------------------------- read byte port
  output reg  [7:0]  rdata,
  output reg         rvalid,    // 1-clk pulse; rdata/ridx valid
  output reg  [7:0]  ridx,

  // ------------------------------------------------------------------- SPI
  output wire        sck,
  output reg         cs_n,
  output reg         mosi,
  input  wire        miso
);

  // ------------------------------------------------------------- commands
  localparam [2:0] HOP_PING       = 3'd0,
                   HOP_SET_PTR    = 3'd1,
                   HOP_WRITE_INC  = 3'd2,
                   HOP_READ_INC   = 3'd3,
                   HOP_WRITE_ADDR = 3'd4,
                   HOP_READ_ADDR  = 3'd5,
                   HOP_RESET      = 3'd6;

  localparam [7:0] CMD_WRITE_INC  = 8'h01,
                   CMD_READ_INC   = 8'h02,
                   CMD_SET_PTR_LO = 8'h03,
                   CMD_SET_PTR_HI = 8'h04,
                   CMD_WRITE_ADDR = 8'h05,
                   CMD_READ_ADDR  = 8'h06,
                   CMD_PING       = 8'h07,
                   CMD_SOFT_RESET = 8'h08;

  localparam HALF = DIV / 2;

  // ---------------------------------------------------------------- states
  localparam [2:0] S_IDLE = 3'd0,
                   S_LEAD = 3'd1,   // CS_N low, settle before the first edge
                   S_BITS = 3'd2,   // 8 bits of the current byte
                   S_TAIL = 3'd3,   // hold SCK low, then release CS_N
                   S_GAP  = 3'd4;   // CS_N high settle before `done`

  reg [2:0]  state;
  reg [3:0]  tc;                 // clock counter within one bit
  reg [2:0]  bit_cnt;            // 0..7, MSB first
  reg [9:0]  bi;                 // index of the byte being shifted
  reg [9:0]  nbytes;             // bytes in this frame
  reg [7:0]  txbyte;             // byte currently on MOSI
  reg [7:0]  rxsh;               // MOSI/MISO shift register for the byte
  reg [7:0]  rcnt;               // number of response bytes produced
  reg [7:0]  op_r;
  reg [15:0] addr_r;

  assign busy = (state != S_IDLE);

  // SCK is a clean function of the registered bit timer; it is never driven
  // while CS_N is high and never glitches (tc changes on clk edges only).
  assign sck = (state == S_BITS) && (tc >= HALF);

  // --------------------------------------------------- frame length per op
  function [9:0] frame_bytes;
    input [2:0] o;
    input [7:0] n;
    begin
      case (o)
        HOP_PING:       frame_bytes = 10'd2;
        HOP_SET_PTR:    frame_bytes = 10'd4;
        HOP_WRITE_INC:  frame_bytes = 10'd1 + {2'b00, n};
        HOP_READ_INC:   frame_bytes = 10'd1 + {2'b00, n};
        HOP_WRITE_ADDR: frame_bytes = 10'd3 + {2'b00, n};
        HOP_READ_ADDR:  frame_bytes = 10'd3 + {2'b00, n};
        HOP_RESET:      frame_bytes = 10'd1;
        default:        frame_bytes = 10'd1;
      endcase
    end
  endfunction

  // -------------------------------------------------- byte classification
  // cur_byte : value shifted out (dummy 0x00 for read slots)
  // cur_rd   : this slot is a read response, captured into rdata
  // cur_wr   : this slot is write data, so widx selects the caller's byte
  reg [7:0] cur_byte;
  reg       cur_rd;
  reg       cur_wr;

  always @* begin
    cur_byte = 8'h00;
    cur_rd   = 1'b0;
    cur_wr   = 1'b0;
    case (op_r)
      HOP_PING: begin
        if (bi == 10'd0) cur_byte = CMD_PING;
        else             cur_rd   = 1'b1;
      end
      HOP_SET_PTR: begin
        if      (bi == 10'd0) cur_byte = CMD_SET_PTR_LO;
        else if (bi == 10'd1) cur_byte = addr_r[7:0];
        else if (bi == 10'd2) cur_byte = CMD_SET_PTR_HI;
        else                  cur_byte = addr_r[15:8];
      end
      HOP_RESET: cur_byte = CMD_SOFT_RESET;
      HOP_WRITE_INC: begin
        if (bi == 10'd0) cur_byte = CMD_WRITE_INC;
        else begin
          cur_wr   = 1'b1;
          cur_byte = wdata;
        end
      end
      HOP_READ_INC: begin
        if (bi == 10'd0) cur_byte = CMD_READ_INC;
        else             cur_rd   = 1'b1;
      end
      HOP_WRITE_ADDR: begin
        if      (bi == 10'd0) cur_byte = CMD_WRITE_ADDR;
        else if (bi == 10'd1) cur_byte = addr_r[7:0];
        else if (bi == 10'd2) cur_byte = addr_r[15:8];
        else begin
          cur_wr   = 1'b1;
          cur_byte = wdata;
        end
      end
      default: begin // HOP_READ_ADDR
        if      (bi == 10'd0) cur_byte = CMD_READ_ADDR;
        else if (bi == 10'd1) cur_byte = addr_r[7:0];
        else if (bi == 10'd2) cur_byte = addr_r[15:8];
        else                  cur_rd   = 1'b1;
      end
    endcase
  end

  // widx is the payload index of the byte currently on the wire.
  assign widx = (op_r == HOP_WRITE_ADDR) ? (bi[7:0] - 8'd3) :
                                             (bi[7:0] - 8'd1);

  // ------------------------------------------------------------------- FSM
  // NOTE: done / rvalid / rdata are the only outputs registered here; every
  // other transition is a plain register update, so the frame waveform is a
  // pure function of (state, tc, bit_cnt, bi).
  always @(posedge clk) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      tc      <= 4'd0;
      bit_cnt <= 3'd0;
      bi      <= 10'd0;
      nbytes  <= 10'd0;
      txbyte  <= 8'h00;
      rxsh    <= 8'h00;
      rcnt    <= 8'h00;
      op_r    <= 3'd0;
      addr_r  <= 16'h0000;
      cs_n    <= 1'b1;
      mosi    <= 1'b0;
      done    <= 1'b0;
      rdata   <= 8'h00;
      rvalid  <= 1'b0;
      ridx    <= 8'h00;
    end else begin
      done   <= 1'b0;
      rvalid <= 1'b0;

      case (state)
        // ------------------------------------------------------- idle
        S_IDLE: begin
          cs_n    <= 1'b1;
          mosi    <= 1'b0;
          tc      <= 4'd0;
          bit_cnt <= 3'd0;
          if (start) begin
            op_r    <= op;
            addr_r  <= addr;
            nbytes  <= frame_bytes(op, len);
            bi      <= 10'd0;
            rcnt    <= 8'h00;
            rxsh    <= 8'h00;
            cs_n    <= 1'b0;
            state   <= S_LEAD;
          end
        end

        // ------------------------------------------- CS_N low, first settle
        S_LEAD: begin
          if (tc == DIV - 1) begin
            tc    <= 4'd0;
            state <= S_BITS;
          end else begin
            tc <= tc + 4'd1;
          end
        end

        // ------------------------------------------------------ data bits
        S_BITS: begin
          // tc==0 of the FIRST bit of a byte: the byte index has settled, so
          // latch the byte and drive its MSB.  Later bits set MOSI at the
          // preceding bit boundary (see the tc==DIV-1 branch) while SCK is low.
          if ((tc == 4'd0) && (bit_cnt == 3'd0)) begin
            txbyte <= cur_byte;
            rxsh   <= 8'h00;
            mosi   <= cur_byte[7];
          end

          // MISO sample point: the last clock of the LOW phase, i.e. one clock
          // before SCK rises.  The chip's SPI slave presents each bit while SCK
          // is low and then *advances* miso_q on the synchronised rising edge,
          // so sampling late in the high phase would read the following bit.
          // Sampling just before the rise also mirrors the chip's own SPI
          // master, which samples MISO one cycle before its rising edge.
          if (tc == HALF - 1) rxsh <= {rxsh[6:0], miso};

          if (tc == DIV - 1) begin
            tc   <= 4'd0;
            if (bit_cnt == 3'd7) begin
              bit_cnt <= 3'd0;
              // ---- one byte complete (rxsh already holds all 8 bits)
              if (cur_rd) begin
                rdata  <= rxsh;
                rvalid <= 1'b1;
                ridx   <= rcnt;
                rcnt   <= rcnt + 8'd1;
              end
              if (bi == nbytes - 10'd1) begin
                state <= S_TAIL;
              end else begin
                bi <= bi + 10'd1;
              end
            end else begin
              bit_cnt <= bit_cnt + 3'd1;
              mosi    <= txbyte[6 - bit_cnt];   // next bit, SCK still low
            end
          end else begin
            tc <= tc + 4'd1;
          end
        end

        // ------------------------------------- last bit done: release CS_N
        S_TAIL: begin
          if (tc >= HALF - 1) begin
            tc    <= 4'd0;
            cs_n  <= 1'b1;
            mosi  <= 1'b0;
            state <= S_GAP;
          end else begin
            tc <= tc + 4'd1;
          end
        end

        // ------------------------------------------------ inter-frame gap
        S_GAP: begin
          if (tc == DIV - 1) begin
            tc    <= 4'd0;
            done  <= 1'b1;
            state <= S_IDLE;
          end else begin
            tc <= tc + 4'd1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
