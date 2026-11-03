// ===========================================================================
// spi_master.vh -- mode-0 SPI master tasks for the v2 top-level benches.
//
// Include this file *inside* a testbench module: the tasks drive the module's
// sck/cs_n/mosi regs and sample miso, at SCK = clk/8 (4 clk low, 4 clk high),
// which is the rate tb/host_tb.v proves clean for proteus_host's 2-FF
// synchroniser and registered MISO.
//
// Host protocol (docs/architecture.md sec. 6, src/proteus_host.v):
//   0x05 WRITE_ADDR + alo + ahi + data...   (auto-increment)
//   0x06 READ_ADDR  + alo + ahi + dummy -> data...  (auto-increment)
//   0x03/0x04 SET_PTR_LO/HI, 0x01/0x02 WRITE_INC/READ_INC, 0x07 PING
// ===========================================================================

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
      #(CLKP*8);
    end
  endtask

  task frame_end;
    begin
      #(CLKP*6);
      cs_n = 1'b1;
      #(CLKP*8);
    end
  endtask

  task spi_cmd(input [7:0] cmd, output [7:0] resp);
    reg [7:0] dummy;
    begin
      frame_start;
      spi_byte(cmd, dummy);
      spi_byte(8'h00, resp);
      frame_end;
    end
  endtask

  // WRITE_ADDR at addr, one data byte.
  task host_wr(input [15:0] addr, input [7:0] data);
    reg [7:0] dummy;
    begin
      frame_start;
      spi_byte(8'h05, dummy);
      spi_byte(addr[7:0], dummy);
      spi_byte(addr[15:8], dummy);
      spi_byte(data, dummy);
      frame_end;
    end
  endtask

  // WRITE_ADDR at addr, n consecutive bytes from buf[0..n-1].
  task host_wr_blk(input [15:0] addr, input integer n);
    reg [7:0] dummy;
    integer k;
    begin
      frame_start;
      spi_byte(8'h05, dummy);
      spi_byte(addr[7:0], dummy);
      spi_byte(addr[15:8], dummy);
      for (k = 0; k < n; k = k + 1) spi_byte(wbuf[k], dummy);
      frame_end;
    end
  endtask

  // READ_ADDR at addr, one byte.
  task host_rd(input [15:0] addr, output [7:0] data);
    reg [7:0] dummy;
    begin
      frame_start;
      spi_byte(8'h06, dummy);
      spi_byte(addr[7:0], dummy);
      spi_byte(addr[15:8], dummy);
      spi_byte(8'h00, data);
      frame_end;
    end
  endtask

  // READ_ADDR at addr, n consecutive bytes into rbuf[0..n-1].
  task host_rd_blk(input [15:0] addr, input integer n);
    reg [7:0] dummy;
    integer k;
    begin
      frame_start;
      spi_byte(8'h06, dummy);
      spi_byte(addr[7:0], dummy);
      spi_byte(addr[15:8], dummy);
      for (k = 0; k < n; k = k + 1) spi_byte(8'h00, rbuf[k]);
      frame_end;
    end
  endtask
