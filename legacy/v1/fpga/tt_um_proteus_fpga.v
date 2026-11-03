// ===========================================================================
// tt_um_proteus_fpga.v -- PROTEUS DE2 (Cyclone II EP2C35F672C6) board top
//
// Self-hosting, self-checking board build: the FPGA is the only host the chip
// ever sees.  It boots the PROTEUS RTL, loads a demo program into the engines
// over the real SPI host protocol (docs/architecture.md section 6), runs the
// demo through hardware loopback models implemented *in the wrapper*, and
// reports PASS/FAIL on the LEDs and 7-segment displays.
//
//   SW[1:0]  demo select     00 pin blink    01 UART loop
//                            10 SPI loop     11 I2C loop
//   SW[2]    demo 00 blink rate: 0 = 12.5 M cycles (250 ms, 2 Hz, visible)
//                                1 = 8192 cycles (scope / simulation rate)
//   SW[7:3]  drive the chip's fabric inputs ui_in[7:3]
//   KEY[0]   (re)run the selected demo (debounced falling edge)
//   KEY[1]   reset, active low; the demo auto-starts ~80 us after release
//   KEY[2], KEY[3] unused
//
// Loopback models (all in this file, all in the 50 MHz clock domain):
//   demo 01: UIO0 (engine 0 UART TX) is wired to UIO1 (engine 1 UART RX).
//   demo 10: fpga_spi_slave, an 8-bit mode-0 SPI slave on UIO2/3/4/5 that
//            echoes the *previous* frame (MISO of frame n = MOSI of n-1).
//   demo 11: fpga_i2c_eeprom, a 0x50 "EEPROM" with pull-ups on UIO6/7 that
//            stores 2 bytes; its address pointer restarts at 0 on START.
//   Unused pads read back as 1 (pull-up), and every pad the chip drives
//   push-pull is fed its own driven value back, so the chip's collision
//   detector stays quiet.
//
// The chip runs with PROG_DEPTH = 64 so each ROM bank has headroom and the two
// 32-word I2C images (engines 3 and 2) fit side by side; the ASIC build is
// 32 deep.  4 x 64 x 24 = 6 kb of program RAM, a small fraction of the
// EP2C35's 105 M4K blocks.
//
// Verilog-2001 only (Quartus II 13.0 must accept this file).
// ===========================================================================

`timescale 1ns / 1ps

`default_nettype none

module tt_um_proteus_fpga (
  input  wire        CLOCK_50,
  input  wire [3:0]  KEY,        // active low: KEY[0] start, KEY[1] reset
  input  wire [17:0] SW,
  output wire [17:0] LEDR,
  output wire [8:0]  LEDG,
  output wire [6:0]  HEX0,
  output wire [6:0]  HEX1,
  output wire [6:0]  HEX2,
  output wire [6:0]  HEX3,
  output wire [6:0]  HEX4,
  output wire [6:0]  HEX5,
  output wire [6:0]  HEX6,
  output wire [6:0]  HEX7,
  output wire [35:0] GPIO_0,
  output wire [35:0] GPIO_1
);

  wire clk = CLOCK_50;

  // ------------------------------------------------------------------ reset
  // KEY[1] is active low: asynchronous assert, synchronous release, so every
  // register (including the chip's own synchroniser) sees one clean edge.
  reg [1:0] rst_sync;
  always @(posedge clk or negedge KEY[1]) begin
    if (!KEY[1]) rst_sync <= 2'b00;
    else         rst_sync <= {rst_sync[0], 1'b1};
  end
  wire rst_n = rst_sync[1];

  // ------------------------------------------------------------- chip nets
  wire [7:0] ui_in, uo_out, uio_in, uio_out, uio_oe;
  wire [7:0] chip_pin;           // resolved pad value with pull-ups

  // ------------------------------------------------------- host SPI master
  wire        hm_start;
  wire [2:0]  hm_op;
  wire [15:0] hm_addr;
  wire [7:0]  hm_len, hm_wdata, hm_widx;
  wire        hm_busy, hm_done, hm_rvalid;
  wire [7:0]  hm_rdata, hm_ridx;
  wire        hm_sck, hm_cs_n, hm_mosi;

  // ------------------------------------------------------------ boot loader
  wire        ld_busy, ld_pass, ld_fail;
  wire [1:0]  ld_fail_engine;
  wire [7:0]  ld_last_byte, ld_bytes_done, ld_status;

  // ------------------------------------------------------ loopback models
  wire        spi_slave_miso;
  wire        i2c_sda_low;
  wire [7:0]  uio_uart, uio_spi, uio_i2c;

  // ------------------------------------------------------------ panel state
  wire [1:0]  demo_sel = SW[1:0];
  wire        fast_pace = SW[2];

  reg  [1:0]  demo_s1, demo_s2, demo_q;
  reg  [16:0] db_cnt;
  reg         key0_stable, key0_prev;
  reg  [1:0]  key0_sync;
  reg  [11:0] por_cnt;
  reg         por_done, por_done_q;

  reg         blink_q;
  reg  [15:0] blink_cnt;         // rising edges on the BLINK pad (demo 00)
  reg  [3:0]  pass_lat;          // PASS latched per demo id
  reg  [24:0] hb_cnt;
  reg         hb;

  // KEY[0] debounce: accept a new level after ~164 us of stability.  A bounce
  // burst can only request a restart while the loader is idle, so a spurious
  // edge during a run is discarded.
  always @(posedge clk) begin
    if (!rst_n) begin
      db_cnt      <= 13'd0;
      key0_stable <= 1'b1;
      key0_prev   <= 1'b1;
      key0_sync   <= 2'b11;
    end else begin
      key0_sync <= {key0_sync[0], KEY[0]};
      key0_prev <= key0_stable;
      if (key0_sync[1] == key0_stable) begin
        db_cnt <= 13'd0;
      end else if (db_cnt == 13'h1FFF) begin
        db_cnt      <= 13'd0;
        key0_stable <= key0_sync[1];
      end else begin
        db_cnt <= db_cnt + 13'd1;
      end
    end
  end
  wire key0_press = key0_prev & ~key0_stable;

  // SW[1:0] synchroniser: a change restarts the newly selected demo.
  always @(posedge clk) begin
    if (!rst_n) begin
      demo_s1 <= 2'd0;
      demo_s2 <= 2'd0;
      demo_q  <= 2'd0;
    end else begin
      demo_s1 <= demo_sel;
      demo_s2 <= demo_s1;
      demo_q  <= demo_s2;
    end
  end
  wire demo_changed = (demo_s2 != demo_q);

  // Power-on run: one automatic start once the chip has settled.
  always @(posedge clk) begin
    if (!rst_n) begin
      por_cnt      <= 12'd0;
      por_done     <= 1'b0;
      por_done_q   <= 1'b0;
    end else begin
      por_done_q <= por_done;
      if (!por_done) begin
        if (por_cnt == 12'd4095) por_done <= 1'b1;
        else                     por_cnt  <= por_cnt + 12'd1;
      end
    end
  end

  wire start_pulse = (por_done & ~por_done_q) | key0_press | demo_changed;

  // ------------------------------------------------------------- instances
  host_master #(.DIV(16)) u_host_master (
    .clk    (clk),
    .rst_n  (rst_n),
    .start  (hm_start),
    .op     (hm_op),
    .addr   (hm_addr),
    .len    (hm_len),
    .busy   (hm_busy),
    .done   (hm_done),
    .widx   (hm_widx),
    .wdata  (hm_wdata),
    .rdata  (hm_rdata),
    .rvalid (hm_rvalid),
    .ridx   (hm_ridx),
    .sck    (hm_sck),
    .cs_n   (hm_cs_n),
    .mosi   (hm_mosi),
    .miso   (uo_out[0])
  );

  boot_loader #(.DEPTH(64)) u_boot_loader (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (start_pulse),
    .demo        (demo_sel),
    .fast_pace   (fast_pace),
    .blink_edges (blink_cnt),
    .hm_start    (hm_start),
    .hm_op       (hm_op),
    .hm_addr     (hm_addr),
    .hm_len      (hm_len),
    .hm_busy     (hm_busy),
    .hm_done     (hm_done),
    .hm_rdata    (hm_rdata),
    .hm_rvalid   (hm_rvalid),
    .hm_widx     (hm_widx),
    .hm_wdata    (hm_wdata),
    .busy        (ld_busy),
    .pass        (ld_pass),
    .fail        (ld_fail),
    .fail_engine (ld_fail_engine),
    .last_byte   (ld_last_byte),
    .bytes_done  (ld_bytes_done),
    .status_byte (ld_status)
  );

  // Host pins: ui_in[0]=SCK, ui_in[1]=CS_N, ui_in[2]=MOSI on the chip side,
  // uo_out[0]=MISO.  ui_in[7:3] are the fabric inputs driven by SW[7:3].
  assign ui_in = {SW[7:3], hm_mosi, hm_cs_n, hm_sck};

  // Pull-up model of every fabric pad: the chip's driven value where it
  // drives, 1 where it releases (open drain high or output disabled).
  assign chip_pin = (uio_oe & uio_out) | ~uio_oe;

  // demo 01: UIO0 (TX) -> UIO1 (RX); all other pads idle high.
  assign uio_uart = {chip_pin[7:2], chip_pin[0], chip_pin[0]};

  // demo 10: SCK=UIO2, MOSI=UIO3, MISO=UIO4 (slave), CS_N=UIO5.
  assign uio_spi = {chip_pin[7:6], chip_pin[5], spi_slave_miso,
                    chip_pin[3], chip_pin[2], chip_pin[1:0]};

  // demo 11: SCL=UIO6, SDA=UIO7 with pull-ups, slave pulls SDA low only.
  assign uio_i2c = {chip_pin[7] & ~i2c_sda_low, chip_pin[6], chip_pin[5:0]};

  assign uio_in = (demo_sel == 2'd0) ? chip_pin  :
                  (demo_sel == 2'd1) ? uio_uart  :
                  (demo_sel == 2'd2) ? uio_spi   : uio_i2c;

  tt_um_proteus #(.PROG_DEPTH(64)) u_chip (
    .ui_in   (ui_in),
    .uo_out  (uo_out),
    .uio_in  (uio_in),
    .uio_out (uio_out),
    .uio_oe  (uio_oe),
    .ena     (1'b1),
    .clk     (clk),
    .rst_n   (rst_n)
  );

  fpga_spi_slave u_spi_slave (
    .clk   (clk),
    .rst_n (rst_n),
    .sck   (chip_pin[2]),
    .cs_n  (chip_pin[5]),
    .mosi  (chip_pin[3]),
    .miso  (spi_slave_miso)
  );

  fpga_i2c_eeprom u_i2c (
    .clk     (clk),
    .rst_n   (rst_n),
    .scl     (chip_pin[6]),
    .sda     (chip_pin[7] & ~i2c_sda_low),
    .sda_low (i2c_sda_low)
  );

  // ------------------------------------------------- BLINK edge counter
  always @(posedge clk) begin
    if (!rst_n) begin
      blink_q   <= 1'b0;
      blink_cnt <= 16'd0;
    end else begin
      blink_q <= chip_pin[0];
      if (chip_pin[0] & ~blink_q) blink_cnt <= blink_cnt + 16'd1;
    end
  end

  // --------------------------------------------------------- result latches
  always @(posedge clk) begin
    if (!rst_n) begin
      pass_lat <= 4'b0000;
      hb_cnt   <= 25'd0;
      hb       <= 1'b0;
    end else begin
      if (ld_pass) pass_lat[demo_s2] <= 1'b1;
      hb_cnt <= hb_cnt + 25'd1;
      hb     <= hb_cnt[24];              // ~1.5 Hz wrapper heartbeat
    end
  end

  // ------------------------------------------------------- 7-segment decode
  function [6:0] seg7;
    input [3:0] v;
    begin
      case (v)
        4'h0: seg7 = 7'b1000000;
        4'h1: seg7 = 7'b1111001;
        4'h2: seg7 = 7'b0100100;
        4'h3: seg7 = 7'b0110000;
        4'h4: seg7 = 7'b0011001;
        4'h5: seg7 = 7'b0010010;
        4'h6: seg7 = 7'b0000010;
        4'h7: seg7 = 7'b1111000;
        4'h8: seg7 = 7'b0000000;
        4'h9: seg7 = 7'b0010000;
        4'hA: seg7 = 7'b0001000;
        4'hB: seg7 = 7'b0000011;
        4'hC: seg7 = 7'b1000110;
        4'hD: seg7 = 7'b0100001;
        4'hE: seg7 = 7'b0000110;
        default: seg7 = 7'b0001110;      // F
      endcase
    end
  endfunction

  // Panel map (see fpga/README.md for the expected values):
  //   HEX0  demo 00: BLINK edge count [3:0];  others: bytes verified
  //   HEX1  demo 00: BLINK edge count [7:4];  others: last byte received
  //   HEX2  chip STATUS[3:0]  (any_run, irq, cap_ovf, collision)
  //   HEX3  chip STATUS[7:4]  (any_error)
  //   HEX4  selected demo id
  //   HEX5  0xA = PASS, 0x5 = FAIL, 0x0 = busy / just booted
  //   HEX6  failing engine id, 0xF when nothing failed
  //   HEX7  0xEE on FAIL/timeout, 0xA5 on PASS, 0x00 while running
  wire [7:0] hex01 = (demo_sel == 2'd0) ? blink_cnt[7:0] : {ld_last_byte[7:4],
                                                           ld_bytes_done[3:0]};
  wire [7:0] hex01b = (demo_sel == 2'd0) ? blink_cnt[15:8] : ld_last_byte;

  assign HEX0 = seg7(hex01[3:0]);
  assign HEX1 = seg7(hex01b[3:0]);
  assign HEX2 = seg7(ld_status[3:0]);
  assign HEX3 = seg7(ld_status[7:4]);
  assign HEX4 = seg7({2'b00, demo_s2});
  assign HEX5 = seg7(ld_pass ? 4'hA : (ld_fail ? 4'h5 : 4'h0));
  assign HEX6 = seg7(ld_fail ? {2'b00, ld_fail_engine} : 4'hF);
  assign HEX7 = seg7(ld_fail ? 4'hE : (ld_pass ? 4'hA : 4'h0));

  // ---------------------------------------------------------------- LEDs
  assign LEDR[0]     = ld_busy;
  assign LEDR[1]     = ld_pass;
  assign LEDR[2]     = ld_fail;
  assign LEDR[3]     = hb;
  assign LEDR[7:4]   = {2'b00, demo_s2};
  assign LEDR[15:8]  = uo_out;
  assign LEDR[17:16] = 2'b00;

  assign LEDG[0] = chip_pin[0];     // BLINK pad mirror (demo 00)
  assign LEDG[1] = pass_lat[1];     // demo 01 PASS latch
  assign LEDG[2] = pass_lat[2];     // demo 10 PASS latch
  assign LEDG[3] = pass_lat[3];     // demo 11 PASS latch
  assign LEDG[4] = hm_busy;         // SPI frame in flight
  assign LEDG[5] = fast_pace;       // SW[2] mirror
  assign LEDG[6] = uo_out[0];       // MISO while the host owns the pin
  assign LEDG[7] = hb;
  assign LEDG[8] = uo_out[1];       // IRQ output

  // ------------------------------------------------------- GPIO for a scope
  // GPIO_0 (all outputs): [7:0] ui_in, [15:8] uo_out, [23:16] uio_out,
  // [31:24] uio_oe, [35:32] 0
  assign GPIO_0 = {4'b0000, uio_oe, uio_out, uo_out, ui_in};
  // GPIO_1 (all outputs): [7:0] uio_in (lines the chip sees),
  // [15:8] chip_pin, [23:16] {spi_slave_miso, i2c_sda_low, 6'b0}, [35:24] 0
  assign GPIO_1 = {12'b0, spi_slave_miso, i2c_sda_low, 6'b000000,
                   chip_pin, uio_in};

endmodule

// ===========================================================================
// fpga_spi_slave -- 8-bit SPI mode-0 slave with a one-frame echo.
//
// MISO of frame n carries the byte sampled in frame n-1 (0x00 for the first
// frame).  That makes a single-wire loopback checkable: the expected response
// to {b0,b1,b2,b3} is {0x00,b0,b1,b2}.
//
// Timing: both sides run in the same 50 MHz domain.  Bit 7 is driven
// combinationally from the raw CS_N, so MISO is valid the moment CS is
// asserted; later bits advance on detected SCK falling edges and MOSI is
// sampled on detected rising edges.  The engine holds MOSI stable across the
// whole high phase, so the one-cycle input register is safe.
// ===========================================================================
module fpga_spi_slave (
  input  wire clk,
  input  wire rst_n,
  input  wire sck,
  input  wire cs_n,
  input  wire mosi,
  output wire miso
);

  reg sck_d, cs_d, mosi_d;
  reg [7:0] shift_r;      // MOSI bits of the current frame
  reg [7:0] tx_r;         // byte being shifted out (previous frame's byte)
  reg [3:0] idx;          // index of the next bit to present

  wire sck_rise = sck & ~sck_d;
  wire sck_fall = ~sck & sck_d;
  wire cs_rise  = ~cs_d & cs_n;

  assign miso = cs_n ? 1'b0 : tx_r[3'd7 - idx[2:0]];

  always @(posedge clk) begin
    if (!rst_n) begin
      sck_d   <= 1'b0;
      cs_d    <= 1'b1;
      mosi_d  <= 1'b0;
      shift_r <= 8'h00;
      tx_r    <= 8'h00;
      idx     <= 4'd0;
    end else begin
      sck_d  <= sck;
      cs_d   <= cs_n;
      mosi_d <= mosi;

      if (cs_rise) begin
        // Frame end: the byte just received becomes the next echo.
        tx_r    <= shift_r;
        shift_r <= 8'h00;
        idx     <= 4'd0;
      end else if (!cs_n) begin
        if (sck_rise) begin
          shift_r <= {shift_r[6:0], mosi_d};
        end else if (sck_fall && (idx < 4'd8)) begin
          idx <= idx + 4'd1;
        end
      end
    end
  end

endmodule

// ===========================================================================
// fpga_i2c_eeprom -- 7-bit I2C "EEPROM" at address 0x50 with two bytes of
// storage, driven only by pulling SDA low (open drain; the top models the
// pull-ups in `chip_pin`).
//
// Simplification (documented): the byte-address pointer restarts at 0 on every
// START, so a write phase followed by a read phase reads back what was written
// without the dummy-write address phase that a real 24C02 needs.  Two bytes
// are stored, which is all the demo writes.
// ===========================================================================
module fpga_i2c_eeprom (
  input  wire clk,
  input  wire rst_n,
  input  wire scl,          // resolved SCL line
  input  wire sda,          // resolved SDA line
  output reg  sda_low       // 1 = pull SDA low
);

  localparam [1:0] P_NONE = 2'd0,
                   P_ADDR = 2'd1,
                   P_WR   = 2'd2,
                   P_RD   = 2'd3;

  reg scl_d, sda_d;
  reg       active;
  reg [1:0] phase, pending;
  reg [3:0] bc;              // 0..8 (8 = ACK slot)
  reg [7:0] shift_r;
  reg [7:0] ptr;
  reg [7:0] out_byte;
  reg       ack;             // 0 = drive ACK, 1 = NACK
  reg [7:0] mem0, mem1;
  reg [7:0] mem_rd;

  wire scl_rise = scl & ~scl_d;
  wire scl_fall = ~scl & scl_d;
  wire start_ev = scl & scl_d & ~sda &  sda_d;   // SDA falls, SCL high
  wire stop_ev  = scl & scl_d &  sda & ~sda_d;   // SDA rises, SCL high

  wire [7:0] shifted = {shift_r[6:0], sda};
  wire       match   = (shifted[7:1] == 7'h50);

  always @* begin
    mem_rd = ptr[0] ? mem1 : mem0;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      scl_d    <= 1'b1;
      sda_d    <= 1'b1;
      active   <= 1'b0;
      phase    <= P_NONE;
      pending  <= P_NONE;
      bc       <= 4'd0;
      shift_r  <= 8'h00;
      ptr      <= 8'h00;
      out_byte <= 8'hFF;
      ack      <= 1'b1;
      mem0     <= 8'h00;
      mem1     <= 8'h00;
      sda_low  <= 1'b0;
    end else begin
      scl_d <= scl;
      sda_d <= sda;

      if (start_ev) begin
        active  <= 1'b1;
        phase   <= P_ADDR;
        pending <= P_NONE;
        bc      <= 4'd0;
        shift_r <= 8'h00;
        ptr     <= 8'h00;          // simplification: pointer restarts
        ack     <= 1'b1;
        sda_low <= 1'b0;
      end else if (stop_ev) begin
        active  <= 1'b0;
        phase   <= P_NONE;
        bc      <= 4'd0;
        sda_low <= 1'b0;
      end else if (active) begin
        // --------------------------------------------------- sample on rise
        if (scl_rise) begin
          if (bc < 4'd8) begin
            shift_r <= shifted;
            bc      <= bc + 4'd1;
            if (bc == 4'd7) begin
              // Data byte complete; the ACK slot is clocked next.
              if (phase == P_ADDR) begin
                ack     <= ~match;
                pending <= match ? (shifted[0] ? P_RD : P_WR) : P_NONE;
              end else if (phase == P_WR) begin
                ack <= 1'b0;
                if (ptr[0]) mem1 <= shifted;
                else        mem0 <= shifted;
                ptr <= ptr + 8'd1;
              end
            end
          end else begin
            // 9th clock: ACK slot
            if (phase == P_RD) begin
              if (sda == 1'b0) begin
                out_byte <= mem_rd;      // master ACKed: next byte
                ptr      <= ptr + 8'd1;
              end else begin
                phase    <= P_NONE;      // master NACKed: release SDA
              end
            end else begin
              if (pending != P_NONE) begin
                phase <= pending;
                if (pending == P_RD) begin
                  out_byte <= mem_rd;
                  ptr      <= ptr + 8'd1;
                end
                pending <= P_NONE;
              end
            end
            bc      <= 4'd0;
            shift_r <= 8'h00;
          end
        end

        // ------------------------------------------------- drive on falling
        if (scl_fall) begin
          if (phase == P_RD) begin
            if (bc < 4'd8) sda_low <= ~out_byte[3'd7 - bc[2:0]];
            else           sda_low <= 1'b0;   // ACK slot: the master drives
          end else begin
            sda_low <= (bc == 4'd8) ? ~ack : 1'b0;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
