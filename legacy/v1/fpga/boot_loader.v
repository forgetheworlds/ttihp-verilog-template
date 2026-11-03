// ===========================================================================
// boot_loader.v -- self-hosting boot sequence for the DE2 PROTEUS build
//
// No PC, no serial cable: after reset (or a KEY[0] press) this FSM soft-resets
// the chip, proves the SPI link with PING, streams the selected demo's program
// images into the engines' program memories, writes the demo's engine
// registers, sets the RUN mask, and then drives the demo's data path and
// checks the result.  Every panel indication comes from these checks.
//
// Sequence
//   1. SOFT_RESET (cmd 0x08), then 1024 clk of settle (engine HALT fill).
//   2. PING until MISO reads 0x50 (4 attempts), else FAIL.
//   3. For each engine the demo uses: two WRITE_ADDR bursts of 128 bytes at
//      0x0100 + e*0x100 + half*0x80.  Each burst carries 32 instructions as
//      4 bytes per instruction; byte lane 3 is written as 0x00 and dropped by
//      tt_um_proteus (`pm_ok` requires pm_byte != 3), so both bursts stay
//      address-contiguous.  Engines the demo does not use are skipped: the
//      reset fill has already written HALT into every program word, and an
//      all-zero word (LDI r0, 0) would free-run.
//   4. Per-demo register init: pacing period(s), the SPI mode register, or
//      the fabric-wide UIO_OD open-drain mask for the I2C demo.
//   5. RUN mask: demo 0 -> engine 0, demo 1 -> 0+1, demo 2 -> 2,
//      demo 3 -> 3+2 (both engines of the I2C split).
//   6. Per-demo data + verification.
//
// DEMO 11 -- TWO-ENGINE I2C
//   firmware/i2c_master.asm is a 32+32 split: engine 3 owns START / repeated
//   START / WRITE byte / ACK check, engine 2 owns READ byte / ACK-NACK / STOP,
//   and the two hand a single IRQ token back and forth (IRQ1 = bus free for
//   engine 3, IRQ0 = bus free for engine 2).  The pin merge gives engine 3
//   priority, and UIO_OD (0x0523) is one fabric-wide register, so the host
//   writes 0xC0 once before RUN instead of either engine writing ODSET.
//
//   The host must therefore deliver ONE command slot to EACH engine per bus
//   operation, engine 3 first then engine 2, because the token pairs the two
//   streams round by round.  The round table below is exactly the sequence
//   sim/test_protocols.py feeds:
//
//     round  engine 3 slot     engine 2 slot   produces
//       0    0x01 START        0x00 NOP        -
//       1    0x02 + 0xA0       0x00 NOP        engine 3 ACK
//       2    0x02 + 0x5A       0x00 NOP        engine 3 ACK
//       3    0x02 + 0xC3       0x00 NOP        engine 3 ACK
//       4    0x01 restart      0x00 NOP        -
//       5    0x02 + 0xA1       0x00 NOP        engine 3 ACK
//       6    0x00 NOP          0x04 READ+ACK   engine 2 byte 0
//       7    0x00 NOP          0x05 READ+NACK  engine 2 byte 1
//       8    0x00 NOP          0x02 STOP       -
//
//   WRITE consumes its data byte from the same IN_FIFO, so engine 3's slot is
//   two bytes wide in rounds 1/2/3/5.  Each round's result is drained before
//   the next round is pushed (the OUT_FIFO is FIFO_DEPTH deep, so draining
//   in-round keeps at most one byte outstanding for any depth).  The three
//   phase-1 ACKs are verified as 0x00, then the read-address ACK and the two
//   read bytes as {0x00, 0x5A, 0xC3} -- 3 bytes verified, last byte 0xC3.
//   PASS waits until engine 2 reports in_empty, i.e. the STOP really ran.
//
//   Engines the demo does not use are skipped: the reset fill has already
//   written HALT into every program word, and an all-zero word (LDI r0, 0)
//   would free-run.
//
// DEMO DATA PUSHING -- read this before editing
//   The engine's IN_FIFO is one register address (window +0x10), but both
//   pointer-based and address-based writes *auto-increment* the chip's address.
//   A single WRITE_ADDR burst to 0x0060 therefore writes 0x0060 (push), then
//   0x0061 (OUT_FIFO read port: ignored), 0x0062 (bit-pin cfg) and 0x0063
//   (side-set cfg) -- it silently destroys the engine configuration and only
//   one byte reaches the FIFO.  The loader therefore pushes FIFO data ONE BYTE
//   PER FRAME: a 1-byte WRITE_ADDR to the same address, repeated (B_PUSH).  The
//   cost is ~600 clk per byte (4-byte frame at clk/16 SPI), which is well under
//   one UART frame or one I2C byte time.
//
// Demo 00  pin blink    engine 0 free-runs on the deadline pacer; the loader
//                       only checks that the chip reports any_run.  SW[2]
//                       selects the period: 0 -> 12.5 M cycles (250 ms, a
//                       visible 2 Hz blink), 1 -> 8192 cycles (scope rate, and
//                       what tb_fpga.v uses).
// Demo 01  UART loop    push 4 golden bytes into engine 0 IN_FIFO; engine 0
//                       TX (UIO0) is wired to engine 1 RX (UIO1) by the
//                       wrapper; collect 4 bytes from engine 1 OUT_FIFO and
//                       compare with the golden vector.
// Demo 10  SPI loop     push 4 bytes into engine 2 IN_FIFO; the wrapper's
//                       mode-0 SPI slave echoes the previous frame, so the
//                       expected response is {00, b0, b1, b2}.
// Demo 11  I2C loop     two engines, round-paired command slots (see DEMO 11
//                       above); 4 ACKs on engine 3, 2 read bytes on engine 2.
//
// Failure: fail=1, fail_engine = the engine the demo depends on; the wrapper
// shows 0xEE on HEX7 and the engine number on HEX6.  Any wait longer than
// TMO_LIMIT (4.19 M cycles = 84 ms at 50 MHz) counts as FAIL, so a hung chip
// can never hang the board.
//
// Verilog-2001 only.
// ===========================================================================

`timescale 1ns / 1ps

`default_nettype none

module boot_loader #(
  parameter DEPTH = 64              // must equal tt_um_proteus PROG_DEPTH
) (
  input  wire        clk,
  input  wire        rst_n,

  // ------------------------------------------------------------ front panel
  input  wire        start,         // 1-clk pulse: (re)run the selected demo
  input  wire [1:0]  demo,          // SW[1:0]
  input  wire        fast_pace,     // SW[2]: 1 = fast blink period
  input  wire [15:0] blink_edges,   // wrapper edge counter on the BLINK pad

  // ------------------------------------------------------------ host master
  output reg         hm_start,
  output reg  [2:0]  hm_op,
  output reg  [15:0] hm_addr,
  output reg  [7:0]  hm_len,
  input  wire        hm_busy,
  input  wire        hm_done,
  input  wire [7:0]  hm_rdata,
  input  wire        hm_rvalid,
  input  wire [7:0]  hm_widx,
  output reg  [7:0]  hm_wdata,

  // --------------------------------------------------------------- results
  output reg         busy,
  output reg         pass,
  output reg         fail,
  output reg  [1:0]  fail_engine,
  output reg  [7:0]  last_byte,
  output reg  [7:0]  bytes_done,
  output reg  [7:0]  status_byte      // last chip status byte read by the FSM
);

  `include "rom_programs.vh"

  // ------------------------------------------------------------- SPI ops
  localparam [2:0] HOP_PING       = 3'd0,
                   HOP_SET_PTR    = 3'd1,
                   HOP_WRITE_INC  = 3'd2,
                   HOP_READ_INC   = 3'd3,
                   HOP_WRITE_ADDR = 3'd4,
                   HOP_READ_ADDR  = 3'd5,
                   HOP_RESET      = 3'd6;

  // ------------------------------------------------------ register addresses
  // Global: STATUS 0x0003 (bit0 any_run), RUN 0x0004.
  // Engine window base = 0x0010 + 0x20*e; offsets: +0x00 E_STATUS,
  // +0x0B r7, +0x0C..0x0F period bytes, +0x10 IN_FIFO, +0x11 OUT_FIFO.
  localparam [15:0] RA_STATUS   = 16'h0003,
                    RA_RUN      = 16'h0004,
                    RA_UIO_OD   = 16'h0523,   // fabric-wide open-drain mask
                    PM_BASE     = 16'h0100,
                    E0_STATUS   = 16'h0010,
                    E0_PERIOD   = 16'h001C,
                    E0_IN_FIFO  = 16'h0020,
                    E1_STATUS   = 16'h0030,
                    E1_OUT_FIFO = 16'h0041,
                    E2_STATUS   = 16'h0050,
                    E2_R7       = 16'h005B,
                    E2_PERIOD   = 16'h005C,
                    E2_IN_FIFO  = 16'h0060,
                    E2_OUT_FIFO = 16'h0061,
                    E3_STATUS   = 16'h0070,
                    E3_IN_FIFO  = 16'h0080,
                    E3_OUT_FIFO = 16'h0081;

  localparam [7:0]  LOAD_LEN  = 8'd128;          // bytes per program burst
  localparam [21:0] TMO_LIMIT = 22'h3F_FFFF;     // 4.19 M cycles = 84 ms

  // ---------------------------------------------------------- byte sources
  localparam [1:0] WSRC_ROM  = 2'd0,
                   WSRC_CFG  = 2'd1,
                   WSRC_DATA = 2'd2,
                   WSRC_RUN  = 2'd3;

  reg [1:0]  wsrc;
  reg [2:0]  cfg_sel;              // index into the per-demo config table
  reg        dph;                  // demo 11 drain phase (0 = write, 1 = read)
  reg [5:0]  didx;                // demo byte index {round[3:0], sel, sub}
  reg [3:0]  rnd;                  // demo 11 round counter (0..9)
  reg        psel;                 // push engine: 0 = engine 3, 1 = engine 2
  reg        drain_sel;            // drain engine: 0 = engine 3, 1 = engine 2
  reg        hh_l;                 // program burst half (0/1)
  reg [2:0]  prog_l;               // ROM bank of the engine being loaded

  // push engine
  reg [15:0] push_addr;
  reg [15:0] push_status;          // engine E_STATUS address (in_full check)
  reg [3:0]  ptotal, pcnt;
  reg [5:0]  push_next;

  // ---------------------------------------------------------------- states
  localparam [5:0] B_IDLE     = 6'd0,
                   B_SR       = 6'd1,
                   B_SRW      = 6'd2,
                   B_SETTLE   = 6'd3,
                   B_PING     = 6'd4,
                   B_PINGW    = 6'd5,
                   B_LOAD     = 6'd6,
                   B_LOADW    = 6'd7,
                   B_CFG      = 6'd8,
                   B_CFGW     = 6'd9,
                   B_RUN      = 6'd10,
                   B_RUNW     = 6'd11,
                   // demo 0
                   B_D0_POLL  = 6'd12,
                   B_D0_POLLW = 6'd13,
                   // shared FIFO push engine (one byte per frame)
                   B_PUSH     = 6'd14,
                   B_PUSHW    = 6'd15,
                   // demo 1
                   B_D1_POLL  = 6'd16,
                   B_D1_POLLW = 6'd17,
                   B_D1_RD    = 6'd18,
                   B_D1_RDW   = 6'd19,
                   // demo 2
                   B_D2_POLL  = 6'd20,
                   B_D2_POLLW = 6'd21,
                   B_D2_RD    = 6'd22,
                   B_D2_RDW   = 6'd23,
                   // demo 11: round-paired command push + per-round drain
                   B_D3_RND   = 6'd24,   // push engine 3's slot(s) for rnd
                   B_D3_RND2  = 6'd25,   // push engine 2's slot for rnd
                   B_D3_RNDX  = 6'd26,   // round done: drain or advance
                   B_D3_DRN   = 6'd27,   // poll the drain engine's E_STATUS
                   B_D3_DRNW  = 6'd28,
                   B_D3_DR    = 6'd29,   // read the drain engine's OUT_FIFO
                   B_D3_DRW   = 6'd30,   // compare + advance
                   B_D3_END   = 6'd31,   // all rounds pushed: wait for STOP
                   B_PUSHCHK  = 6'd34,
                   B_PUSHWR   = 6'd35,
                   B_PUSHX    = 6'd36,
                   B_D3_ENDW  = 6'd37,
                   // results
                   B_PASS     = 6'd32,
                   B_FAIL     = 6'd33;

  reg [5:0]  state;
  reg [1:0]  demo_l;
  reg        fast_l;
  reg [2:0]  ee;                   // engine being loaded
  reg [2:0]  ci;                   // config transaction index
  reg [2:0]  acount;               // config transaction count for the demo
  reg [1:0]  dcount;               // received-byte index inside a demo
  reg [7:0]  rb;                   // last response byte from the host master
  reg        rb_valid;
  reg [7:0]  retry;                // PING attempts
  reg [11:0] wait_cnt;             // post-reset settle counter
  reg [21:0] tmo;                  // demo timeout (saturating)

  wire tmo_hit = (tmo >= TMO_LIMIT);

  // ------------------------------------------------------------- constants
  // ROM word for a program burst: {half, byte-index[6:2]}.
  wire [5:0]  rom_idx  = {hh_l, hm_widx[6:2]};
  wire [23:0] rom_word = fpga_prog_word(prog_l, rom_idx);

  // -------------------------------------------------------- helper tables
  // RUN mask per demo.
  function [7:0] run_mask;
    input [1:0] d;
    begin
      case (d)
        2'd0:    run_mask = 8'h01;
        2'd1:    run_mask = 8'h03;
        2'd2:    run_mask = 8'h04;
        default: run_mask = 8'h0C;     // engines 3 and 2: the I2C split
      endcase
    end
  endfunction

  // Number of config transactions per demo.
  function [2:0] cfg_count;
    input [1:0] d;
    begin
      case (d)
        2'd0:    cfg_count = 3'd1;   // blink pacing period
        2'd1:    cfg_count = 3'd0;   // UART firmware programs its own period
        2'd2:    cfg_count = 3'd2;   // SPI pacing period + mode register
        default: cfg_count = 3'd1;   // I2C open-drain mask
      endcase
    end
  endfunction

  // Config transaction address / length.
  reg [15:0] cfg_addr_w;
  reg [7:0]  cfg_len_w;
  always @* begin
    cfg_addr_w = E0_PERIOD;
    cfg_len_w  = 8'd4;
    case (demo_l)
      2'd0: begin                          // engine 0 period
        cfg_addr_w = E0_PERIOD;
        cfg_len_w  = 8'd4;
      end
      2'd2: begin
        if (ci == 3'd0) begin              // engine 2 period
          cfg_addr_w = E2_PERIOD;
          cfg_len_w  = 8'd4;
        end else begin                     // engine 2 r7 = SPI mode
          cfg_addr_w = E2_R7;
          cfg_len_w  = 8'd1;
        end
      end
      default: begin                       // demo 11: UIO_OD open-drain mask
        cfg_addr_w = RA_UIO_OD;
        cfg_len_w  = 8'd1;
      end
    endcase
  end

  // Config byte values (little endian: index 0 = lowest byte lane).
  function [7:0] cfg_byte;
    input [1:0] d;
    input [2:0] c;
    input       f;
    input [2:0] ix;
    begin
      cfg_byte = 8'h00;
      case (d)
        2'd0: begin                        // blink period
          if (f) begin                     // 0x00200000 -> 8192 cycles
            case (ix)
              3'd2:    cfg_byte = 8'h20;
              default: cfg_byte = 8'h00;
            endcase
          end else begin                   // 0xBEBC2000 -> 12.5 M cycles
            case (ix)
              3'd1:    cfg_byte = 8'h20;
              3'd2:    cfg_byte = 8'hBC;
              3'd3:    cfg_byte = 8'hBE;
              default: cfg_byte = 8'h00;
            endcase
          end
        end
        2'd2: begin
          if (c == 3'd0) begin             // 0x00001900 -> 25 cycles/half bit
            case (ix)
              3'd1:    cfg_byte = 8'h19;
              default: cfg_byte = 8'h00;
            endcase
          end else begin                   // r7 = 0 -> SPI mode 0
            cfg_byte = 8'h00;
          end
        end
        default: begin                     // 0xC0 -> UIO6/UIO7 open drain
          case (ix)
            3'd0:    cfg_byte = 8'hC0;
            default: cfg_byte = 8'h00;
          endcase
        end
      endcase
    end
  endfunction

  // Demo push data (index order == FIFO push order).
  //   ix = {round[3:0], engine-sel, sub} for demo 11, where engine-sel is 0
  //   for the engine 3 slot and 1 for the engine 2 slot, and sub is the byte
  //   index within that slot (WRITE consumes its data byte too).
  function [7:0] demo_byte;
    input [1:0] d;
    input [5:0] ix;
    begin
      demo_byte = 8'h00;
      case (d)
        2'd1: begin                        // UART golden vector
          case (ix[1:0])
            2'd0:    demo_byte = 8'hA5;
            2'd1:    demo_byte = 8'h3C;
            2'd2:    demo_byte = 8'h0F;
            default: demo_byte = 8'hC3;
          endcase
        end
        2'd2: begin                        // SPI bytes to send
          case (ix[1:0])
            2'd0:    demo_byte = 8'h5A;
            2'd1:    demo_byte = 8'hC3;
            2'd2:    demo_byte = 8'h00;
            default: demo_byte = 8'hFF;
          endcase
        end
        default: begin                     // demo 11: paired I2C command slots
          if (!ix[1]) begin                // engine 3: START / WRITE / ACKs
            case (ix[5:2])
              4'd0:    demo_byte = 8'h01;  // START
              4'd1:    demo_byte = ix[0] ? 8'hA0 : 8'h02;  // WRITE addr|W
              4'd2:    demo_byte = ix[0] ? 8'h5A : 8'h02;  // WRITE data 0
              4'd3:    demo_byte = ix[0] ? 8'hC3 : 8'h02;  // WRITE data 1
              4'd4:    demo_byte = 8'h01;  // repeated START
              4'd5:    demo_byte = ix[0] ? 8'hA1 : 8'h02;  // WRITE addr|R
              default: demo_byte = 8'h00;  // NOP: consume + pass the token
            endcase
          end else begin                   // engine 2: READ / STOP
            case (ix[5:2])
              4'd6:    demo_byte = 8'h04;  // READ + ACK
              4'd7:    demo_byte = 8'h05;  // READ + NACK
              4'd8:    demo_byte = 8'h02;  // STOP
              default: demo_byte = 8'h00;  // NOP
            endcase
          end
        end
      endcase
    end
  endfunction

  // Number of bytes one engine's slot carries in a given round (demo 11).
  function [1:0] d3_slots;
    input [3:0] r;
    input       sel;
    begin
      if (sel) d3_slots = 2'd1;            // engine 2: always one command
      else     d3_slots = ((r == 4'd1) || (r == 4'd2) ||
                           (r == 4'd3) || (r == 4'd5)) ? 2'd2 : 2'd1;
    end
  endfunction

  // Expected read-back value for received-byte index ix.
  function [7:0] demo_expect;
    input [1:0] d;
    input       ph;
    input [1:0] ix;
    begin
      demo_expect = 8'h00;
      case (d)
        2'd1: begin                        // UART loopback: identical to sent
          case (ix)
            2'd0:    demo_expect = 8'hA5;
            2'd1:    demo_expect = 8'h3C;
            2'd2:    demo_expect = 8'h0F;
            default: demo_expect = 8'hC3;
          endcase
        end
        2'd2: begin                        // SPI echo arrives one frame late
          case (ix)
            2'd0:    demo_expect = 8'h00;
            2'd1:    demo_expect = 8'h5A;
            2'd2:    demo_expect = 8'hC3;
            default: demo_expect = 8'h00;
          endcase
        end
        default: begin                     // I2C: ACK, data 0, data 1
          if (!ph) demo_expect = 8'h00;
          else begin
            case (ix)
              2'd0:    demo_expect = 8'h00;
              2'd1:    demo_expect = 8'h5A;
              default: demo_expect = 8'hC3;
            endcase
          end
        end
      endcase
    end
  endfunction

  // ----------------------------------------------------- write byte selector
  always @* begin
    hm_wdata = 8'h00;
    case (wsrc)
      WSRC_ROM: begin
        case (hm_widx[1:0])
          2'd0:    hm_wdata = rom_word[7:0];
          2'd1:    hm_wdata = rom_word[15:8];
          2'd2:    hm_wdata = rom_word[23:16];
          default: hm_wdata = 8'h00;       // lane 3 is a dropped don't-care
        endcase
      end
      WSRC_CFG:  hm_wdata = cfg_byte(demo_l, cfg_sel, fast_l, hm_widx[2:0]);
      WSRC_DATA: hm_wdata = demo_byte(demo_l, didx);
      default:   hm_wdata = run_mask(demo_l);
    endcase
  end

  // --------------------------------------------------------------- the FSM
  always @(posedge clk) begin
    if (!rst_n) begin
      state       <= B_IDLE;
      hm_start    <= 1'b0;
      hm_op       <= HOP_PING;
      hm_addr     <= 16'h0000;
      hm_len      <= 8'd0;
      wsrc        <= WSRC_ROM;
      cfg_sel     <= 3'd0;
      dph         <= 1'b0;
      didx        <= 6'd0;
      rnd         <= 4'd0;
      psel        <= 1'b0;
      drain_sel   <= 1'b0;
      hh_l        <= 1'b0;
      prog_l      <= FPGA_PROG_HALT;
      push_addr   <= 16'h0000;
      push_status <= 16'h0000;
      ptotal      <= 4'd0;
      pcnt        <= 4'd0;
      push_next   <= B_IDLE;
      demo_l      <= 2'd0;
      fast_l      <= 1'b0;
      ee          <= 3'd0;
      ci          <= 3'd0;
      acount      <= 3'd0;
      dcount      <= 2'd0;
      rb          <= 8'h00;
      rb_valid    <= 1'b0;
      retry       <= 8'h00;
      wait_cnt    <= 12'd0;
      tmo         <= 22'd0;
      busy        <= 1'b0;
      pass        <= 1'b0;
      fail        <= 1'b0;
      fail_engine <= 2'd0;
      last_byte   <= 8'h00;
      bytes_done  <= 8'h00;
      status_byte <= 8'h00;
    end else begin
      hm_start <= 1'b0;

      // response capture (rvalid pulses inside the frame, before `done`)
      if (hm_rvalid) begin
        rb       <= hm_rdata;
        rb_valid <= 1'b1;
      end

      // demo timeout, saturating
      if (busy && !tmo_hit) tmo <= tmo + 22'd1;

      case (state)
        // ------------------------------------------------------------- idle
        B_IDLE: begin
          if (start) begin
            busy        <= 1'b1;
            pass        <= 1'b0;
            fail        <= 1'b0;
            fail_engine <= 2'd0;
            last_byte   <= 8'h00;
            bytes_done  <= 8'h00;
            demo_l      <= demo;
            fast_l      <= fast_pace;
            ee          <= 3'd0;
            ci          <= 3'd0;
            dcount      <= 2'd0;
            acount      <= cfg_count(demo);
            hh_l        <= 1'b0;
            dph         <= 1'b0;
            rnd         <= 4'd0;
            psel        <= 1'b0;
            drain_sel   <= 1'b0;
            retry       <= 8'h00;
            tmo         <= 22'd0;
            wait_cnt    <= 12'd1023;
            state       <= B_SR;
          end
        end

        // ------------------------------------------------ soft reset frame
        B_SR: begin
          hm_op    <= HOP_RESET;
          hm_addr  <= 16'h0000;
          hm_len   <= 8'd0;
          hm_start <= 1'b1;
          state    <= B_SRW;
        end
        B_SRW: if (hm_done) state <= B_SETTLE;

        // ------------------------------------ wait for the engine HALT fill
        B_SETTLE: begin
          if (wait_cnt == 12'd0) state <= B_PING;
          else                   wait_cnt <= wait_cnt - 12'd1;
        end

        // ---------------------------------------------------------- PING
        B_PING: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_PING;
          hm_addr  <= 16'h0000;
          hm_len   <= 8'd0;
          hm_start <= 1'b1;
          state    <= B_PINGW;
        end
        B_PINGW: begin
          if (hm_done) begin
            if (rb_valid && (rb == 8'h50)) begin
              ee    <= 3'd0;
              hh_l  <= 1'b0;
              state <= B_LOAD;
            end else if (retry == 8'd3) begin
              fail_engine <= 2'd0;
              state       <= B_FAIL;
            end else begin
              retry <= retry + 8'd1;
              state <= B_PING;
            end
          end
        end

        // ---------------------------------------- program load (ROM bursts)
        B_LOAD: begin
          if (ee == 3'd4) begin
            ci    <= 3'd0;
            state <= B_CFG;
          end else if (fpga_demo_prog(demo_l, ee) == FPGA_PROG_HALT) begin
            // The reset fill has already HALTed every word this demo does not
            // use, so there is nothing to stream for this engine.
            ee    <= ee + 3'd1;
            hh_l  <= 1'b0;
            state <= B_LOAD;
          end else begin
            prog_l   <= fpga_demo_prog(demo_l, ee);
            wsrc     <= WSRC_ROM;
            hm_op    <= HOP_WRITE_ADDR;
            hm_addr  <= PM_BASE + ({13'd0, ee} << 8) +
                        (hh_l ? 16'h0080 : 16'h0000);
            hm_len   <= LOAD_LEN;
            hm_start <= 1'b1;
            state    <= B_LOADW;
          end
        end
        B_LOADW: begin
          if (hm_done) begin
            if (!hh_l) begin
              hh_l  <= 1'b1;
              state <= B_LOAD;
            end else begin
              hh_l  <= 1'b0;
              ee    <= ee + 3'd1;
              state <= B_LOAD;
            end
          end
        end

        // ------------------------------------------- per-demo register init
        B_CFG: begin
          if ({1'b0, ci} >= acount) begin
            state <= B_RUN;
          end else begin
            wsrc     <= WSRC_CFG;
            cfg_sel  <= ci;
            hm_op    <= HOP_WRITE_ADDR;
            hm_addr  <= cfg_addr_w;
            hm_len   <= cfg_len_w;
            hm_start <= 1'b1;
            state    <= B_CFGW;
          end
        end
        B_CFGW: begin
          if (hm_done) begin
            ci    <= ci + 3'd1;
            state <= B_CFG;
          end
        end

        // ------------------------------------------------------ RUN bits
        B_RUN: begin
          wsrc     <= WSRC_RUN;
          hm_op    <= HOP_WRITE_ADDR;
          hm_addr  <= RA_RUN;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_RUNW;
        end
        B_RUNW: begin
          if (hm_done) begin
            tmo     <= 22'd0;
            pcnt    <= 4'd0;
            case (demo_l)
              2'd0: begin
                state <= B_D0_POLL;
              end
              2'd1: begin
                push_addr   <= E0_IN_FIFO;
                push_status <= E0_STATUS;
                ptotal      <= 4'd4;
                dph       <= 1'b0;
                push_next <= B_D1_POLL;
                state     <= B_PUSH;
              end
              2'd2: begin
                push_addr   <= E2_IN_FIFO;
                push_status <= E2_STATUS;
                ptotal      <= 4'd4;
                dph       <= 1'b0;
                push_next <= B_D2_POLL;
                state     <= B_PUSH;
              end
              default: begin               // demo 11: round-paired I2C slots
                rnd       <= 4'd0;
                psel      <= 1'b0;
                dph       <= 1'b0;
                state     <= B_D3_RND;
              end
            endcase
          end
        end

        // =================================== shared FIFO push (1 byte/frame)
        // The chip's FIFO depth is a parameter (4 in the current build), and a
        // push to a full FIFO is silently dropped, so poll E_STATUS[3]
        // (in_full) before each byte and retry.  This makes the loader correct
        // for any FIFO_DEPTH.
        B_PUSH: begin
          if (pcnt >= ptotal) state <= push_next;
          else                state <= B_PUSHCHK;
        end
        B_PUSHCHK: begin
          rb_valid <= 1'b0;
          wsrc     <= WSRC_ROM;         // unused for a read
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= push_status;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_PUSHW;
        end
        B_PUSHW: begin
          if (hm_done) begin
            if (tmo_hit) begin
              fail_engine <= (demo_l == 2'd3) ? (psel ? 2'd2 : 2'd3) : demo_l;
              state       <= B_FAIL;
            end else if (rb_valid && rb[3]) begin
              state <= B_PUSH;          // FIFO still full: retry
            end else begin
              state <= B_PUSHWR;
            end
          end
        end
        B_PUSHWR: begin
          didx     <= (demo_l == 2'd3) ? {rnd, psel, pcnt[0]} : {2'b00, pcnt};
          wsrc     <= WSRC_DATA;
          hm_op    <= HOP_WRITE_ADDR;
          hm_addr  <= push_addr;        // same address every time: no auto-inc
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_PUSHX;
        end
        B_PUSHX: begin
          if (hm_done) begin
            pcnt  <= pcnt + 4'd1;
            state <= B_PUSH;
          end
        end

        // ================================================== demo 00: blink
        // PASS as soon as the global STATUS byte reports any_run = 1.  The
        // engine keeps running afterwards: the pad and the wrapper's edge
        // counter are the visible evidence.
        B_D0_POLL: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= RA_STATUS;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_D0_POLLW;
        end
        B_D0_POLLW: begin
          if (hm_done) begin
            if (rb_valid) status_byte <= rb;
            if (rb_valid && rb[0]) begin
              state <= B_PASS;
            end else if (tmo_hit) begin
              fail_engine <= 2'd0;
              state       <= B_FAIL;
            end else begin
              state <= B_D0_POLL;
            end
          end
        end

        // ============================================ demo 01: UART loopback
        B_D1_POLL: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= E1_STATUS;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_D1_POLLW;
        end
        B_D1_POLLW: begin
          if (hm_done) begin
            if (rb_valid) status_byte <= rb;
            if (tmo_hit) begin
              fail_engine <= 2'd1;
              state       <= B_FAIL;
            end else if (rb_valid && !rb[4]) begin   // !out_empty
              state <= B_D1_RD;
            end else begin
              state <= B_D1_POLL;
            end
          end
        end
        B_D1_RD: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= E1_OUT_FIFO;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_D1_RDW;
        end
        B_D1_RDW: begin
          if (hm_done) begin
            last_byte <= rb;
            if (rb == demo_expect(2'd1, 1'b0, dcount)) begin
              bytes_done <= {6'd0, dcount} + 8'd1;
              if (dcount == 2'd3) begin
                state <= B_PASS;
              end else begin
                dcount <= dcount + 2'd1;
                state  <= B_D1_POLL;
              end
            end else begin
              fail_engine <= 2'd1;
              state       <= B_FAIL;
            end
          end
        end

        // ============================================= demo 10: SPI loopback
        B_D2_POLL: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= E2_STATUS;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_D2_POLLW;
        end
        B_D2_POLLW: begin
          if (hm_done) begin
            if (rb_valid) status_byte <= rb;
            if (tmo_hit) begin
              fail_engine <= 2'd2;
              state       <= B_FAIL;
            end else if (rb_valid && !rb[4]) begin
              state <= B_D2_RD;
            end else begin
              state <= B_D2_POLL;
            end
          end
        end
        B_D2_RD: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= E2_OUT_FIFO;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_D2_RDW;
        end
        B_D2_RDW: begin
          if (hm_done) begin
            last_byte <= rb;
            if (rb == demo_expect(2'd2, 1'b0, dcount)) begin
              bytes_done <= {6'd0, dcount} + 8'd1;
              if (dcount == 2'd3) begin
                state <= B_PASS;
              end else begin
                dcount <= dcount + 2'd1;
                state  <= B_D2_POLL;
              end
            end else begin
              fail_engine <= 2'd2;
              state       <= B_FAIL;
            end
          end
        end

        // ============================================= demo 11: I2C loopback
        // One round = one command slot to each engine, engine 3 first.  Each
        // round's result is drained before the next round is pushed.
        B_D3_RND: begin
          if (rnd == 4'd9) begin
            state <= B_D3_END;         // all slots pushed; STOP still in flight
          end else begin
            psel        <= 1'b0;
            push_addr   <= E3_IN_FIFO;
            push_status <= E3_STATUS;
            pcnt        <= 4'd0;
            ptotal      <= {2'b00, d3_slots(rnd, 1'b0)};
            push_next   <= B_D3_RND2;
            state       <= B_PUSH;
          end
        end
        B_D3_RND2: begin
          psel        <= 1'b1;
          push_addr   <= E2_IN_FIFO;
          push_status <= E2_STATUS;
          pcnt        <= 4'd0;
          ptotal      <= 4'd1;
          push_next   <= B_D3_RNDX;
          state       <= B_PUSH;
        end
        B_D3_RNDX: begin
          if ((rnd == 4'd1) || (rnd == 4'd2) ||
              (rnd == 4'd3) || (rnd == 4'd5)) begin
            drain_sel <= 1'b0;         // engine 3 pushed this WRITE's ACK
            state     <= B_D3_DRN;
          end else if ((rnd == 4'd6) || (rnd == 4'd7)) begin
            drain_sel <= 1'b1;         // engine 2 pushed this READ's byte
            state     <= B_D3_DRN;
          end else begin
            rnd   <= rnd + 4'd1;
            state <= B_D3_RND;
          end
        end
        B_D3_DRN: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= drain_sel ? E2_STATUS : E3_STATUS;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_D3_DRNW;
        end
        B_D3_DRNW: begin
          if (hm_done) begin
            if (rb_valid) status_byte <= rb;
            if (tmo_hit) begin
              fail_engine <= drain_sel ? 2'd2 : 2'd3;
              state       <= B_FAIL;
            end else if (rb_valid && !rb[4]) begin   // !out_empty
              state <= B_D3_DR;
            end else begin
              state <= B_D3_DRN;
            end
          end
        end
        B_D3_DR: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= drain_sel ? E2_OUT_FIFO : E3_OUT_FIFO;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_D3_DRW;
        end
        B_D3_DRW: begin
          if (hm_done) begin
            last_byte <= rb;
            if (rb == demo_expect(2'd3, dph, dcount)) begin
              bytes_done <= {6'd0, dcount} + 8'd1;
              if (dcount != 2'd2) begin
                dcount <= dcount + 2'd1;
              end else if (dph == 1'b0) begin
                // The three write-phase ACKs are verified; phase 1 begins with
                // the read address's ACK, then the two read data bytes.
                dph    <= 1'b1;
                dcount <= 2'd0;
              end
              rnd   <= rnd + 4'd1;
              state <= B_D3_RND;
            end else begin
              fail_engine <= drain_sel ? 2'd2 : 2'd3;
              state       <= B_FAIL;
            end
          end
        end

        // All nine rounds pushed: engine 2 must have consumed the STOP slot
        // before PASS is claimed (in_empty = E_STATUS[2]).
        B_D3_END: begin
          rb_valid <= 1'b0;
          hm_op    <= HOP_READ_ADDR;
          hm_addr  <= E2_STATUS;
          hm_len   <= 8'd1;
          hm_start <= 1'b1;
          state    <= B_D3_ENDW;
        end
        B_D3_ENDW: begin
          if (hm_done) begin
            if (rb_valid) status_byte <= rb;
            if (tmo_hit) begin
              fail_engine <= 2'd2;
              state       <= B_FAIL;
            end else if (rb_valid && rb[2]) begin
              state <= B_PASS;
            end else begin
              state <= B_D3_END;
            end
          end
        end

        // ------------------------------------------------------------ end
        B_PASS: begin
          pass  <= 1'b1;
          busy  <= 1'b0;
          state <= B_IDLE;
        end
        B_FAIL: begin
          fail  <= 1'b1;
          busy  <= 1'b0;
          state <= B_IDLE;
        end

        default: state <= B_IDLE;
      endcase
    end
  end

  // Unused inputs/net kept for lint cleanliness.
  wire _unused = &{1'b0, blink_edges[15:4], hm_busy, 1'b0};

endmodule

`default_nettype wire
