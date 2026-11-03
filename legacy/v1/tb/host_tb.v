// ===========================================================================
// tb/host_tb.v -- SPI host interface testbench (proteus_host only).
//
// Bit-bangs a mode-0 (CPOL=0, CPHA=0) SPI master at SCK = clk/8 and drives a
// small register model on the host's register bus.  Covers:
//   * PING returns 0x50 (and re-arms inside one frame)
//   * SET_PTR_LO/HI + WRITE_INC + READ_INC round trip, pointer advance
//   * WRITE_ADDR / READ_ADDR with auto-increment
//   * HOST_EN register write 0 -> 1 (host_en observable on the port)
//   * HOST_DISABLE releases the pins and stays released
//   * SOFT_RESET command and SOFT_RESET register both pulse soft_reset
//   * CS_N framing: independent frames, NOP frames, back-to-back frames
//   * reg_we / reg_re are exactly one clk wide
//
// Exit status: 1 on any failure ($fatal), 0 on success.
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module host_tb;

  localparam CLKP  = 10;      // clk period in ns (100 MHz sim)
  localparam CLKH  = 5;

  reg clk = 1'b0;
  always #(CLKH) clk = ~clk;

  reg  rst_n = 1'b0;
  reg  sck   = 1'b0;
  reg  cs_n  = 1'b1;
  reg  mosi  = 1'b0;
  wire miso;
  wire        reg_we;
  wire [15:0] reg_addr;
  wire [7:0]  reg_wdata;
  wire        reg_re;
  wire [15:0] reg_raddr;
  reg  [7:0]  reg_rdata;
  wire        host_en;
  wire        soft_reset;

  // --------------------------------------------------------- register model
  reg [7:0] mem [0:255];
  integer   mi;
  initial for (mi = 0; mi < 256; mi = mi + 1) mem[mi] = 8'h00;

  always @* reg_rdata = mem[reg_raddr[7:0]];

  always @(posedge clk) begin
    if (reg_we) mem[reg_addr[7:0]] <= reg_wdata;
  end

  // ------------------------------------------------------------- DUT
  proteus_host dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .sck       (sck),
    .cs_n      (cs_n),
    .mosi      (mosi),
    .miso      (miso),
    .reg_we    (reg_we),
    .reg_addr  (reg_addr),
    .reg_wdata (reg_wdata),
    .reg_re    (reg_re),
    .reg_raddr (reg_raddr),
    .reg_rdata (reg_rdata),
    .host_en   (host_en),
    .soft_reset(soft_reset)
  );

  // ------------------------------------------------------------ scoreboard
  integer errors = 0;
  integer nchecks = 0;
  integer nwrites = 0;
  integer nreads  = 0;

  task check8(input [7:0] got, input [7:0] exp, input [255:0] what);
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got 0x%02x expected 0x%02x (t=%0t)",
                 what, got, exp, $time);
      end
    end
  endtask

  task check1(input got, input exp, input [255:0] what);
    begin
      nchecks = nchecks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got %b expected %b (t=%0t)", what, got, exp, $time);
      end
    end
  endtask

  // --------------------------------------------------------- SPI master
  // SCK = clk/8: 4 clk low, 4 clk high, MISO sampled 2 clk into the high phase.
  task spi_byte(input [7:0] mo, output [7:0] mi);
    integer b;
    begin
      mi = 8'h00;
      for (b = 7; b >= 0; b = b - 1) begin
        mosi = mo[b];
        sck  = 1'b0;
        #(CLKP*4);
        sck  = 1'b1;
        #(CLKP*2);
        mi[b] = miso;
        #(CLKP*2);
        sck  = 1'b0;
      end
    end
  endtask

  task frame_start;
    begin
      sck  = 1'b0;
      mosi = 1'b0;
      #(CLKP*2);
      cs_n = 1'b0;
      #(CLKP*8);                 // let the synchroniser see CS_N first
    end
  endtask

  task frame_end;
    begin
      #(CLKP*6);                 // let the last falling edge be absorbed
      cs_n = 1'b1;
      #(CLKP*8);
    end
  endtask

  // command byte + one dummy byte, returns the response
  task spi_cmd(input [7:0] cmd, output [7:0] resp);
    reg [7:0] dummy;
    begin
      frame_start;
      spi_byte(cmd, dummy);
      spi_byte(8'h00, resp);
      frame_end;
    end
  endtask

  // ------------------------------------------------------- bus pulse monitor
  reg prev_we = 1'b0, prev_re = 1'b0;
  integer nsoft = 0;
  always @(posedge clk) begin
    if (reg_we && prev_we) begin
      errors = errors + 1;
      $display("FAIL reg_we wider than one clk at t=%0t", $time);
    end
    if (reg_re && prev_re) begin
      errors = errors + 1;
      $display("FAIL reg_re wider than one clk at t=%0t", $time);
    end
    if (reg_we) nwrites = nwrites + 1;
    if (reg_re) nreads  = nreads + 1;
    if (soft_reset) nsoft = nsoft + 1;
    prev_we <= reg_we;
    prev_re <= reg_re;
  end

  // ------------------------------------------------------------- test body
  reg [7:0] r, d;

  initial begin
    $display("=== proteus_host host_tb ===");

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    // ---- 1. host owns the pins after reset -----------------------------
    check1(host_en, 1'b1, "host_en after reset");
    check1(miso,   1'b0, "miso idle while CS_N high");

    // ---- 2. PING -------------------------------------------------------
    spi_cmd(8'h07, r);
    check8(r, 8'h50, "PING response");
    check1(miso, 1'b0, "miso released after frame");

    // ---- 3. PING twice in one frame ------------------------------------
    begin : ping2
      reg [7:0] d0, d1;
      frame_start;
      spi_byte(8'h07, d0);          // command
      spi_byte(8'h00, d0);          // response 1
      spi_byte(8'h00, d1);          // response 2 (re-armed)
      frame_end;
      check8(d0, 8'h50, "PING response #1 in frame");
      check8(d1, 8'h50, "PING response #2 in frame");
    end

    // ---- 4. NOP frame --------------------------------------------------
    spi_cmd(8'h00, r);
    check8(r, 8'h00, "NOP response is 0");

    // ---- 5. SET_PTR + WRITE_INC ---------------------------------------
    frame_start;
    spi_byte(8'h03, d);             // SET_PTR_LO
    spi_byte(8'h20, d);             // ptr[7:0] = 0x20
    spi_byte(8'h04, d);             // SET_PTR_HI
    spi_byte(8'h00, d);             // ptr[15:8] = 0x00
    spi_byte(8'h01, d);             // WRITE_INC
    spi_byte(8'h11, d);             // -> 0x0020
    spi_byte(8'h22, d);             // -> 0x0021
    spi_byte(8'h33, d);             // -> 0x0022
    frame_end;

    check8(mem[8'h20], 8'h11, "WRITE_INC mem[0x20]");
    check8(mem[8'h21], 8'h22, "WRITE_INC mem[0x21]");
    check8(mem[8'h22], 8'h33, "WRITE_INC mem[0x22]");
    check8(dut.ptr[15:0], 16'h0023, "pointer after WRITE_INC x3");

    // ---- 6. SET_PTR + READ_INC round trip ------------------------------
    frame_start;
    spi_byte(8'h03, d);             // SET_PTR_LO = 0x20
    spi_byte(8'h20, d);
    spi_byte(8'h04, d);             // SET_PTR_HI = 0x00
    spi_byte(8'h00, d);
    spi_byte(8'h02, d);             // READ_INC
    spi_byte(8'h00, r);             // <- mem[0x20]
    check8(r, 8'h11, "READ_INC mem[0x20]");
    spi_byte(8'h00, r);             // <- mem[0x21]
    check8(r, 8'h22, "READ_INC mem[0x21]");
    spi_byte(8'h00, r);             // <- mem[0x22]
    check8(r, 8'h33, "READ_INC mem[0x22]");
    frame_end;
    check8(dut.ptr[15:0], 16'h0023, "pointer after READ_INC x3");

    // ---- 7. WRITE_ADDR / READ_ADDR -----------------------------------
    frame_start;
    spi_byte(8'h05, d);             // WRITE_ADDR
    spi_byte(8'h30, d);             // addr[7:0]
    spi_byte(8'h00, d);             // addr[15:8]
    spi_byte(8'hAA, d);
    spi_byte(8'hBB, d);
    frame_end;
    check8(mem[8'h30], 8'hAA, "WRITE_ADDR mem[0x30]");
    check8(mem[8'h31], 8'hBB, "WRITE_ADDR mem[0x31] (auto-inc)");

    frame_start;
    spi_byte(8'h06, d);             // READ_ADDR
    spi_byte(8'h30, d);
    spi_byte(8'h00, d);
    spi_byte(8'h00, r);
    check8(r, 8'hAA, "READ_ADDR mem[0x30]");
    spi_byte(8'h00, r);
    check8(r, 8'hBB, "READ_ADDR mem[0x31] (auto-inc)");
    frame_end;

    // ---- 8. HOST_EN register write 0 -> 1 -----------------------------
    frame_start;
    spi_byte(8'h05, d);
    spi_byte(8'h07, d);             // addr 0x0007
    spi_byte(8'h00, d);
    spi_byte(8'h00, d);             // host_en = 0
    frame_end;
    check1(host_en, 1'b0, "host_en cleared by 0x0007 write");

    frame_start;
    spi_byte(8'h05, d);
    spi_byte(8'h07, d);
    spi_byte(8'h00, d);
    spi_byte(8'h01, d);             // host_en = 1
    frame_end;
    check1(host_en, 1'b1, "host_en set by 0x0007 write");

    // ---- 9. SOFT_RESET register pulses soft_reset ----------------------
    begin : srst_reg
      integer hits;
      hits = nsoft;
      frame_start;
      spi_byte(8'h05, d);
      spi_byte(8'h06, d);           // addr 0x0006
      spi_byte(8'h00, d);
      spi_byte(8'h01, d);
      frame_end;
      nchecks = nchecks + 1;
      if (nsoft == hits) begin
        errors = errors + 1;
        $display("FAIL soft_reset not pulsed by 0x0006 write");
      end
    end

    // ---- 9b. SOFT_RESET command pulses soft_reset ----------------------
    begin : srst_cmd
      integer hits;
      hits = nsoft;
      spi_cmd(8'h08, r);
      nchecks = nchecks + 1;
      if (nsoft == hits) begin
        errors = errors + 1;
        $display("FAIL soft_reset not pulsed by SOFT_RESET command");
      end
      repeat (4) @(posedge clk);
    end

    // ---- 10. HOST_DISABLE ---------------------------------------------
    spi_cmd(8'h09, r);
    check1(host_en, 1'b0, "host_en cleared by HOST_DISABLE");
    repeat (20) @(posedge clk);
    check1(host_en, 1'b0, "host_en stays clear after HOST_DISABLE");

    // further frames must not re-enable it
    spi_cmd(8'h07, r);
    check1(host_en, 1'b0, "host_en still clear after another frame");

    // ---- 11. final bus-pulse sanity ------------------------------------
    nchecks = nchecks + 1;
    if (nwrites == 0) begin
      errors = errors + 1;
      $display("FAIL no register writes observed");
    end
    nchecks = nchecks + 1;
    if (nreads == 0) begin
      errors = errors + 1;
      $display("FAIL no register reads observed");
    end

    $display("--- host_tb: %0d checks, %0d writes, %0d reads, %0d errors ---",
             nchecks, nwrites, nreads, errors);
    if (errors != 0) $fatal(1, "host_tb FAILED");
    $display("host_tb PASSED");
    $finish;
  end

endmodule

`default_nettype wire
