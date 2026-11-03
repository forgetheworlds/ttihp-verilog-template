// ===========================================================================
// proteus_assist.v -- hybrid v2 assist subsystem: five measured protocol
// blocks behind one CSR interface, plus pin ownership.
//
// Blocks (design/area: results/hybrid_area.md, docs/hybrid-architecture.md):
//   id 0  crc_bit        CRC 5..32 bit, runtime width/reflection/bit order,
//                        bit-serial (8 clocks per byte).         21,152.96 um2
//   id 1  assist_fifo    16 x 8 byte stream FIFO + burst counter   12,397.80
//   id 2  shiftreg32     32-bit shift register, runtime width/order  10,411.25
//   id 3  nrzi_enc/dec   USB LS line code + stuffing + SYNC/EOP      10,755.42
//   id 4  manchester_*   10BASE-T PCS, 4x/8x oversampled              5,873.14
//
// ---------------------------------------------------------------------------
// ACCESS MODEL
// ---------------------------------------------------------------------------
// Host view : 0x0600 + 0x10*id + reg, reg 0..7 (the address is pre-decoded by
//             tt_um_proteus; h_addr is the offset within the assist window).
//             Register 8 of each stride is the host-only PINCFG register: pin
//             ownership is static configuration, and keeping it out of the
//             engine's 8-register view means LDAS/STAS (rs is 3 bits) can reach
//             every register of docs section 5.3 unchanged.
// Engine view: LDAS rd, rs=reg, imm[2:0]=id ; STAS rd, rs=reg, imm[2:0]=id ;
//             ASST rs=id, imm=command.  Reads are combinational, so LDAS
//             retires in one cycle.
// Arbitration: the three engine write/command ports are arbitrated by the top
//             (highest engine index wins, the same rule the pin merge uses).
//             Read ports are per engine and never conflict.  Host and engine
//             writes in the same cycle: host wins.
//
// ---------------------------------------------------------------------------
// REGISTER MAP (per assist, reg 0..7; "RO" = read-only, writes ignored)
// ---------------------------------------------------------------------------
// id0 CRC
//   0  W  DATA      write = fold that byte (8 clocks). a write while busy is
//                    dropped and sets STATUS.drop
//   1  RO STATUS    [7] busy  [1] drop  [0] empty (=~busy)
//   2  RW CFG0      {lsb[7], refl[6], width[5:0]} -> crc_bit cfg_sel=2
//   3  RW CMD       0 page=CRC, 1 start (reload init), 6 flush (fold 0x00),
//                    8 page=init, 9 page=poly, 10 page=xorout
//   4..7 RW/RO PAGE {crc[7:0],[15:8],[23:16],[31:24]} for the selected page;
//                    page 0 (CRC result) is read-only, pages 1..3 are the
//                    init/poly/xorout configuration words.
//   The four-register page window is how init/poly/xorout stay programmable
//   inside the 8-register map of docs 5.3 without growing the field width.
//
// id1 FIFO (16 x 8)
//   0  RW DATA      write = push, read = pop (returns the pre-pop head)
//   1  RO STATUS    {0, full, empty, level[4:0]}
//   2  RW BURSTLEN  armed pop count
//   3  W  CMD       bit0 / command 1 or 3 = arm burst, bit1 / command 0 = clr
//   4  RO POPS      remaining armed pops
//   5  RO IRQ       [0] burst_done
//   6,7 RO 0
//
// id2 SHIFT
//   0  RW DATA      write = push byte at the active end, read = byte at the
//                   active end (a pop is non-destructive in shiftreg32)
//   1  RO STATUS    [7] stuff_flag  [0] byte_valid
//   2  RW CFG       {dir[7], width[6:1], en[0]}
//   3  W  CMD       0 reset, 1 start (en=1, free-run shift), 2 stop, 8 step
//   4..7 RO         {dout[7:0],[15:8],[23:16],[31:24]}
//
// id3 NRZI (USB LS)
//   0  W  TXDATA    push a byte into the encoder queue
//   1  RO RXDATA    last decoded byte
//   2  RO STATUS    [7] stuff_err [6] eop [5] sync [4] se0 [3] enc_busy
//                   [2] enc_ready [1] enc_overflow [0] reset_seen  (7..5 and
//                   0 are sticky, cleared by CMD 0)
//   3  RW DIV       clocks per bit (6 bit, 0 -> 1); 32 at 48 MHz = 1.5 MBit/s
//   4..7 RO 0
//   CMD: 0 reset, 1 start, 2 stop, 4 send SYNC (queue 0x80), 5 send EOP
//
// id4 MANCH (10BASE-T PCS)
//   0  W  TXDATA    push a byte into the encoder queue
//   1  RO RXDATA    last decoded byte
//   2  RO STATUS    [7] manch_err [6] phase_err [5] locked [4] enc_busy
//                   [3] enc_ready [2] enc_overflow [1] bit_valid  [0] -
//   3  RO CFG       {HALF_DIV[3:0], OS[3:0]} -- elaboration-time constants
//                   (docs/hybrid-architecture.md 5.5: the divider is fixed per
//                   build, so this register reports it instead of pretending
//                   to reprogram it)
//   4..7 RO 0
//   CMD: 0 reset, 1 start, 2 stop
//
// ---------------------------------------------------------------------------
// PIN OWNERSHIP (docs/hybrid-architecture.md 5.4)
// ---------------------------------------------------------------------------
// PINCFG (0x0600 + 0x10*id + 8), host only:
//   [7] en  [6:5] bank (0 ui_in RO, 1 uo_out, 2 uio, 3 none)
//   [4:2] tx_base  [1:0] rx_base
// NRZI drives two adjacent TX pins (dp at tx_base, dm at tx_base+1) while
// tx_oe is high, and senses dp/dm at rx_base/rx_base+1.  Manchester drives one
// TX pin at tx_base and senses one RX pin at rx_base.  Receive pins are read
// from the raw pads (pin_ui/pin_uio), never from the merged fabric output, so
// an assist sees the bus (docs 5.4).  Assist outputs enter the pin fabric as
// one extra merge stage per bank: priority above engines, below the host;
// assists are push-pull, so the stage also clears open-drain for owned pins.
// ===========================================================================
`default_nettype none

module proteus_assist (
  input  wire        clk,
  input  wire        rst_n,
  // host CSR window (address already relative to PROTEUS_AS_BASE)
  input  wire        h_we,
  input  wire [6:0]  h_addr,
  input  wire [7:0]  h_wdata,
  input  wire        h_re,
  input  wire [6:0]  h_raddr,
  output reg  [7:0]  h_rdata,
  // per-engine combinational read ports (LDAS)
  input  wire [2:0]  e_rden,
  input  wire [2:0]  e_rid0,
  input  wire [2:0]  e_rreg0,
  input  wire [2:0]  e_rid1,
  input  wire [2:0]  e_rreg1,
  input  wire [2:0]  e_rid2,
  input  wire [2:0]  e_rreg2,
  output wire [23:0] e_rdata,       // {eng2, eng1, eng0}
  output wire [2:0]  e_rempty,
  // arbitrated engine write / command port (STAS / ASST)
  input  wire        e_wr,
  input  wire [2:0]  e_wid,
  input  wire [2:0]  e_wreg,
  input  wire [7:0]  e_wdata,
  input  wire        e_cmd,
  input  wire [2:0]  e_cid,
  input  wire [7:0]  e_ccmd,
  // raw pads (assist receive side)
  input  wire [7:0]  pin_ui,
  input  wire [7:0]  pin_uio,
  // pin-fabric request (one extra merge stage per bank)
  output wire [7:0]  ap_uo_d,
  output wire [7:0]  ap_uo_m,
  output wire [7:0]  ap_uio_d,
  output wire [7:0]  ap_uio_m,
  output wire [7:0]  ap_oe_d,
  output wire [7:0]  ap_oe_m,
  output wire [7:0]  ap_od_m
);

  localparam [1:0] BANK_UI  = 2'd0;
  localparam [1:0] BANK_UO  = 2'd1;
  localparam [1:0] BANK_UIO = 2'd2;

  // Divide-and-conquer register index decode.
  wire [2:0] h_wr_id  = h_addr[6:4];
  wire [3:0] h_wr_reg = h_addr[3:0];
  wire [2:0] h_rd_id  = h_raddr[6:4];
  wire [3:0] h_rd_reg = h_raddr[3:0];

  // Host access strobes per assist id.
  wire h_wr_id0 = h_we && (h_wr_id == 3'd0);
  wire h_wr_id1 = h_we && (h_wr_id == 3'd1);
  wire h_wr_id2 = h_we && (h_wr_id == 3'd2);
  wire h_wr_id3 = h_we && (h_wr_id == 3'd3);
  wire h_wr_id4 = h_we && (h_wr_id == 3'd4);
  wire h_rd_id1 = h_re && (h_rd_id == 3'd1);
  wire h_rd_id2 = h_re && (h_rd_id == 3'd2);

  // Engine access strobes (arbitrated port).
  wire e_wr_id0 = e_wr && (e_wid == 3'd0);
  wire e_wr_id1 = e_wr && (e_wid == 3'd1);
  wire e_wr_id2 = e_wr && (e_wid == 3'd2);
  wire e_wr_id3 = e_wr && (e_wid == 3'd3);
  wire e_wr_id4 = e_wr && (e_wid == 3'd4);
  wire e_cmd_id0 = e_cmd && (e_cid == 3'd0);
  wire e_cmd_id1 = e_cmd && (e_cid == 3'd1);
  wire e_cmd_id2 = e_cmd && (e_cid == 3'd2);
  wire e_cmd_id3 = e_cmd && (e_cid == 3'd3);
  wire e_cmd_id4 = e_cmd && (e_cid == 3'd4);

  // Per-engine LDAS strobes, and the FIFO/SHIFT DATA read strobes (their own
  // read port pops / reports the active-end byte).
  wire e_rd0 = e_rden[0] && (e_rid0 == 3'd1) && (e_rreg0 == 3'd0);
  wire e_rd1 = e_rden[1] && (e_rid1 == 3'd1) && (e_rreg1 == 3'd0);
  wire e_rd2 = e_rden[2] && (e_rid2 == 3'd1) && (e_rreg2 == 3'd0);
  wire e_sr0 = e_rden[0] && (e_rid0 == 3'd2) && (e_rreg0 == 3'd0);
  wire e_sr1 = e_rden[1] && (e_rid1 == 3'd2) && (e_rreg1 == 3'd0);
  wire e_sr2 = e_rden[2] && (e_rid2 == 3'd2) && (e_rreg2 == 3'd0);

  // ------------------------------------------------------------- PINCFG
  reg [7:0] pincfg [0:4];

  wire [7:0] pc_crc   = pincfg[0];
  wire [7:0] pc_fifo  = pincfg[1];
  wire [7:0] pc_shift = pincfg[2];
  wire [7:0] pc_nrzi  = pincfg[3];
  wire [7:0] pc_manch = pincfg[4];

  wire [1:0] nrzi_bank   = pc_nrzi[6:5];
  wire [2:0] nrzi_txbase = pc_nrzi[4:2];
  wire [2:0] nrzi_rxbase = {1'b0, pc_nrzi[1:0]};
  wire       nrzi_pin_en = pc_nrzi[7];

  wire [1:0] manch_bank   = pc_manch[6:5];
  wire [2:0] manch_txbase = pc_manch[4:2];
  wire [2:0] manch_rxbase = {1'b0, pc_manch[1:0]};
  wire       manch_pin_en = pc_manch[7];

  // ============================================================== CRC (id 0)
  reg  [7:0]  crc_cfg;
  reg  [1:0]  crc_page;
  reg  [31:0] crc_init, crc_poly, crc_xor;
  reg         crc_start;
  reg         crc_cfg_we;
  reg  [1:0]  crc_cfg_sel;
  reg  [31:0] crc_cfg_data;
  reg         crc_fold_busy;
  reg         crc_fold_drop;
  reg  [7:0]  crc_fold_byte;
  reg  [2:0]  crc_fold_bit;
  wire [31:0] crc_out;
  wire        crc_refl_unused;
  wire        crc_bit_out_x;

  // Bit order for the fold: cfg[7] = lsb-first (reflected CRCs), else MSB.
  wire crc_bit_in = crc_cfg[7] ? crc_fold_byte[crc_fold_bit]
                               : crc_fold_byte[7 - crc_fold_bit];

  crc_bit u_crc (
    .clk       (clk),
    .rst_n     (rst_n),
    .cfg_we    (crc_cfg_we),
    .cfg_sel   (crc_cfg_sel),
    .cfg_data  (crc_cfg_data),
    .start     (crc_start),
    .bit_en    (crc_fold_busy),
    .bit_in    (crc_bit_in),
    .crc_out   (crc_out),
    .crc_bit_out(crc_bit_out_x),
    .refl_out  (crc_refl_unused)
  );

  wire crc_data_h  = h_wr_id0 && (h_wr_reg == 4'd0);
  wire crc_wr_data = crc_data_h || (e_wr_id0 && (e_wreg == 3'd0));
  wire crc_cfg0_h  = h_wr_id0 && (h_wr_reg == 4'd2);
  wire crc_wr_cfg0 = crc_cfg0_h || (e_wr_id0 && (e_wreg == 3'd2));
  // Any host write to assist 0 supplies the byte; otherwise the engine does.
  // (Keying this on crc_data_h alone made CFG0/page writes latch the engine's
  // 0x00 instead of the host's data.)
  wire [7:0] crc_wr_byte = h_wr_id0 ? h_wdata : e_wdata;

  // Page window writes (reg 4..7) when a configuration page is selected.
  wire crc_page_h  = h_wr_id0 && (h_wr_reg >= 4'd4) && (h_wr_reg <= 4'd7);
  wire crc_wr_page = (crc_page_h || (e_wr_id0 && (e_wreg >= 3'd4))) &&
                     (crc_page != 2'd0);
  wire [3:0] crc_page_off = h_wr_id0 ? {2'b00, h_wr_reg[1:0]}
                                     : {2'b00, e_wreg[1:0]};
  // Byte-lane update of the page word, and the matching crc_bit cfg_sel:
  // 0 init, 1 poly, 3 xorout (2 is the width/reflect CFG0 register).
  wire [31:0] crc_lane_mask = 32'h0000_00FF << {crc_page_off, 3'b000};
  wire [31:0] crc_lane_data = {24'd0, crc_wr_byte} << {crc_page_off, 3'b000};
  wire [31:0] crc_init_n = (crc_init & ~crc_lane_mask) | crc_lane_data;
  wire [31:0] crc_poly_n = (crc_poly & ~crc_lane_mask) | crc_lane_data;
  wire [31:0] crc_xor_n  = (crc_xor  & ~crc_lane_mask) | crc_lane_data;

  // CRC command decode (host write to reg 3, or ASST).
  wire        crc_cmd_h   = h_wr_id0 && (h_wr_reg == 4'd3);
  wire        crc_cmd_v   = crc_cmd_h || e_cmd_id0;
  wire [7:0]  crc_cmd     = crc_cmd_h ? h_wdata : e_ccmd;

  // ============================================================= FIFO (id 1)
  reg  [4:0] fifo_burstlen;
  reg        fifo_clr;
  reg        fifo_arm;
  wire [7:0] fifo_rdata;
  wire [7:0] fifo_a_data_x;
  wire       fifo_a_valid_x;
  wire [4:0] fifo_level;
  wire       fifo_full, fifo_empty, fifo_burst_done, fifo_irq_unused;
  wire [4:0] fifo_pops;

  wire h_wr_fifo0 = h_wr_id1 && (h_wr_reg == 4'd0);
  wire h_rd_fifo0 = h_rd_id1 && (h_rd_reg == 4'd0);
  wire e_wr_fifo0 = e_wr_id1 && (e_wreg == 3'd0);
  wire e_rd_fifo0 = e_rd0 | e_rd1 | e_rd2;

  wire        fifo_wr    = h_wr_fifo0 | e_wr_fifo0;
  wire [7:0]  fifo_wdata = h_wr_fifo0 ? h_wdata : e_wdata;
  wire        fifo_rd    = h_rd_fifo0 | e_rd_fifo0;

  wire fifo_cmd_h = h_wr_id1 && (h_wr_reg == 4'd3);
  wire fifo_cmd_v = fifo_cmd_h || e_cmd_id1;
  wire [7:0] fifo_cmd = fifo_cmd_h ? h_wdata : e_ccmd;

  // The block's autonomous drain port is driven by the same strobe as the
  // host/engine pop, so the armed burst counter observes every drained byte
  // and burst_done/POPS are live.  An independent consumer (FIFO -> CRC ->
  // serializer chaining, docs 9 step 2) is phase-2 work.
  assist_fifo #(.DEPTH(16), .AW(4), .CW(5)) u_fifo (
    .clk        (clk),
    .rst_n      (rst_n),
    .h_wr       (fifo_wr),
    .h_wdata    (fifo_wdata),
    .h_rd       (fifo_rd),
    .a_pop      (fifo_rd),
    .clr        (fifo_clr),
    .arm        (fifo_arm),
    .burst_len  (fifo_burstlen),
    .h_rdata    (fifo_rdata),
    .a_data     (fifo_a_data_x),
    .a_valid    (fifo_a_valid_x),
    .level      (fifo_level),
    .full       (fifo_full),
    .empty      (fifo_empty),
    .burst_done (fifo_burst_done),
    .irq        (fifo_irq_unused),
    .pops       (fifo_pops)
  );

  // ============================================================ SHIFT (id 2)
  reg  [7:0]  shift_cfg;             // {dir, width[5:0], en}
  reg         shift_step;            // one-cycle step pulse
  wire        shift_dir    = shift_cfg[7];
  wire [5:0]  shift_width  = shift_cfg[6:1];
  wire        shift_en     = shift_cfg[0];

  wire [31:0] shift_dout;
  wire        shift_bit_out, shift_bit_valid, shift_byte_valid,
              shift_stuff_flag;
  wire [7:0]  shift_bpop;

  wire shift_wr_h = h_wr_id2 && (h_wr_reg == 4'd0);
  wire shift_wr = shift_wr_h || (e_wr_id2 && (e_wreg == 3'd0));
  wire [7:0] shift_wdata = shift_wr_h ? h_wdata : e_wdata;
  wire shift_pop = (h_rd_id2 && (h_rd_reg == 4'd0)) | e_sr0 | e_sr1 | e_sr2;

  shiftreg32 u_shift (
    .clk        (clk),
    .rst_n      (rst_n),
    .load       (1'b0),
    .din        (32'd0),
    .sh_en      (shift_en | shift_step),
    .dir        (shift_dir),
    .width_r    (shift_width),
    .bpush      (shift_wdata),
    .push_we    (shift_wr),
    .pop_req    (shift_pop),
    .stuff_en   (1'b0),
    .stuff_len  (3'd0),
    .bit_in     (1'b0),
    .dout       (shift_dout),
    .bit_out    (shift_bit_out),
    .bit_valid  (shift_bit_valid),
    .bpop       (shift_bpop),
    .byte_valid (shift_byte_valid),
    .stuff_flag (shift_stuff_flag)
  );

  wire shift_cmd_h = h_wr_id2 && (h_wr_reg == 4'd3);
  wire shift_cmd_v = shift_cmd_h || e_cmd_id2;
  wire [7:0] shift_cmd = shift_cmd_h ? h_wdata : e_ccmd;

  // ============================================================= NRZI (id 3)
  reg  [5:0] nrzi_div;
  reg        nrzi_en;
  reg        nrzi_eop;
  reg        nrzi_push_sync;
  reg        nrzi_stuff_err_q, nrzi_eop_q, nrzi_sync_q, nrzi_reset_q;

  wire       nrzi_dp_tx, nrzi_dm_tx, nrzi_tx_oe, nrzi_bit_stb, nrzi_tx_bit;
  wire       nrzi_busy, nrzi_ready, nrzi_overflow, nrzi_eop_done;
  wire [7:0] nrzi_dout, nrzi_bit_out_unused;
  wire       nrzi_dout_valid, nrzi_sync_det, nrzi_eop_det, nrzi_reset_det,
             nrzi_stuff_err, nrzi_se0, nrzi_dec_busy, nrzi_dec_bit,
             nrzi_dec_bit_valid;

  wire [7:0] nrzi_rxpad = (nrzi_bank == BANK_UI) ? pin_ui : pin_uio;
  wire       nrzi_rxdp  = nrzi_rxpad[nrzi_rxbase];
  wire       nrzi_rxdm  = nrzi_rxpad[nrzi_rxbase + 3'd1];

  wire nrzi_wr_h = h_wr_id3 && (h_wr_reg == 4'd0);
  wire nrzi_wr = nrzi_wr_h || (e_wr_id3 && (e_wreg == 3'd0));
  wire [7:0] nrzi_wdata = nrzi_wr_h ? h_wdata : e_wdata;
  wire       nrzi_din_we = nrzi_wr | nrzi_push_sync;
  wire [7:0] nrzi_din    = nrzi_push_sync ? 8'h80 : nrzi_wdata;

  nrzi_enc #(.AW(6)) u_nrzi_enc (
    .clk      (clk),
    .rst_n    (rst_n),
    .en       (nrzi_en),
    .div_r    (nrzi_div),
    .din      (nrzi_din),
    .din_we   (nrzi_din_we),
    .eop_req  (nrzi_eop),
    .dp       (nrzi_dp_tx),
    .dm       (nrzi_dm_tx),
    .tx_oe    (nrzi_tx_oe),
    .bit_stb  (nrzi_bit_stb),
    .tx_bit   (nrzi_tx_bit),
    .busy     (nrzi_busy),
    .ready    (nrzi_ready),
    .overflow (nrzi_overflow),
    .eop_done (nrzi_eop_done)
  );

  nrzi_dec #(.AW(6)) u_nrzi_dec (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (nrzi_en),
    .div_r      (nrzi_div),
    .dp         (nrzi_rxdp),
    .dm         (nrzi_rxdm),
    .dout       (nrzi_dout),
    .dout_valid (nrzi_dout_valid),
    .sync_det   (nrzi_sync_det),
    .eop_det    (nrzi_eop_det),
    .reset_det  (nrzi_reset_det),
    .stuff_err  (nrzi_stuff_err),
    .se0        (nrzi_se0),
    .busy       (nrzi_dec_busy),
    .bit_out    (nrzi_dec_bit),
    .bit_valid  (nrzi_dec_bit_valid)
  );

  wire nrzi_div_h = h_wr_id3 && (h_wr_reg == 4'd3);
  wire nrzi_div_wr = nrzi_div_h || (e_wr_id3 && (e_wreg == 3'd3));
  wire nrzi_cmd_v = e_cmd_id3;
  wire [7:0] nrzi_cmd = e_ccmd;

  // ============================================================ MANCH (id 4)
  localparam integer MC_HALF_DIV = 4;   // 20 Mbaud at 80 MHz
  localparam integer MC_OS       = 4;   // 4x oversampling

  reg  manch_en;
  wire manch_tx, manch_half_stb, manch_busy, manch_ready, manch_overflow;
  wire [7:0] manch_dout;
  wire manch_bit_out, manch_bit_valid, manch_dout_valid, manch_locked,
       manch_phase_err, manch_manch_err;

  wire manch_wr_h = h_wr_id4 && (h_wr_reg == 4'd0);
  wire manch_wr = manch_wr_h || (e_wr_id4 && (e_wreg == 3'd0));
  wire [7:0] manch_wdata = manch_wr_h ? h_wdata : e_wdata;

  wire [7:0] manch_rxpad = (manch_bank == BANK_UI) ? pin_ui : pin_uio;
  wire       manch_rx    = manch_rxpad[manch_rxbase];

  manchester_enc #(.HALF_DIV(MC_HALF_DIV), .AW(4)) u_manch_enc (
    .clk      (clk),
    .rst_n    (rst_n),
    .en       (manch_en),
    .din      (manch_wdata),
    .din_we   (manch_wr),
    .tx       (manch_tx),
    .half_stb (manch_half_stb),
    .busy     (manch_busy),
    .ready    (manch_ready),
    .overflow (manch_overflow)
  );

  manchester_dec #(.OS(MC_OS)) u_manch_dec (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (manch_en),
    .rx         (manch_rx),
    .bit_out    (manch_bit_out),
    .bit_valid  (manch_bit_valid),
    .dout       (manch_dout),
    .dout_valid (manch_dout_valid),
    .locked     (manch_locked),
    .phase_err  (manch_phase_err),
    .manch_err  (manch_manch_err)
  );

  wire manch_cmd_v = e_cmd_id4;
  wire [7:0] manch_cmd = e_ccmd;

  // ====================================================== CSR read function
  // Combinational: LDAS and the host read both sample it in the issue cycle.
  function [7:0] crc_page_rd;
    input [1:0] bi;
    reg [31:0] v;
    begin
      case (crc_page)
        2'd0:    v = crc_out;
        2'd1:    v = crc_init;
        2'd2:    v = crc_poly;
        default: v = crc_xor;
      endcase
      crc_page_rd = v[{bi, 3'b000} +: 8];
    end
  endfunction

  function [7:0] as_read;
    input [2:0] id;
    input [3:0] r;
    begin
      as_read = 8'h00;
      case (id)
        3'd0: begin                              // CRC
          case (r)
            4'd1: as_read = {crc_fold_busy, 5'd0, crc_fold_drop, ~crc_fold_busy};
            4'd2: as_read = crc_cfg;
            4'd3: as_read = {6'b000000, crc_page};
            4'd4, 4'd5, 4'd6, 4'd7: as_read = crc_page_rd(r[1:0]);
            default: as_read = 8'h00;            // DATA is a write-only port
          endcase
        end
        3'd1: begin                              // FIFO
          case (r)
            4'd0: as_read = fifo_rdata;
            4'd1: as_read = {1'b0, fifo_full, fifo_empty, fifo_level};
            4'd2: as_read = {3'b000, fifo_burstlen};
            4'd4: as_read = {3'b000, fifo_pops};
            4'd5: as_read = {7'b0000000, fifo_burst_done};
            default: as_read = 8'h00;
          endcase
        end
        3'd2: begin                              // SHIFT
          case (r)
            4'd0: as_read = shift_bpop;
            4'd1: as_read = {shift_stuff_flag, 6'b000000, shift_byte_valid};
            4'd2: as_read = shift_cfg;
            4'd4, 4'd5, 4'd6, 4'd7: as_read = shift_dout[{r[1:0], 3'b000} +: 8];
            default: as_read = 8'h00;
          endcase
        end
        3'd3: begin                              // NRZI
          case (r)
            4'd1: as_read = nrzi_dout;
            4'd2: as_read = {nrzi_stuff_err_q, nrzi_eop_q, nrzi_sync_q,
                             nrzi_se0, nrzi_busy, nrzi_ready,
                             nrzi_overflow, nrzi_reset_q};
            4'd3: as_read = {2'b00, nrzi_div};
            default: as_read = 8'h00;
          endcase
        end
        3'd4: begin                              // MANCH
          case (r)
            4'd1: as_read = manch_dout;
            4'd2: as_read = {manch_manch_err, manch_phase_err, manch_locked,
                             manch_busy, manch_ready, manch_overflow,
                             manch_bit_valid, 1'b0};
            4'd3: as_read = {MC_HALF_DIV[3:0], MC_OS[3:0]};
            default: as_read = 8'h00;
          endcase
        end
        default: as_read = 8'h00;
      endcase
    end
  endfunction

  // "Reading the FIFO DATA register when the queue is empty" is the only
  // condition that makes LDAS take the PULLN path.
  wire fifo_rd_empty = fifo_empty;
  assign e_rempty = {(e_rid2 == 3'd1) && (e_rreg2 == 3'd0) && fifo_rd_empty,
                     (e_rid1 == 3'd1) && (e_rreg1 == 3'd0) && fifo_rd_empty,
                     (e_rid0 == 3'd1) && (e_rreg0 == 3'd0) && fifo_rd_empty};

  // PINCFG lives inside the 0x10 stride but outside the 8-register engine view.
  //
  // The four read ports share one always block with an EXPLICIT sensitivity
  // list.  Reason: the read logic lives in a function, and a function call
  // whose body reads module registers is not a sufficient re-evaluation
  // trigger in iverilog 12 (and not guaranteed by the LRM for continuous
  // assigns), so an access to an address that had not changed returned the
  // stale value -- reproduced as a CSR read after a write in v2/tb/tb_csr.v.
  // Adding a CSR register means adding it here; tb_csr exercises every one.
  reg [7:0] e_rdata0, e_rdata1, e_rdata2;

  always @(h_rd_id or h_rd_reg or
           e_rid0 or e_rreg0 or e_rid1 or e_rreg1 or e_rid2 or e_rreg2 or
           crc_cfg or crc_page or crc_out or crc_init or crc_poly or crc_xor
           or crc_fold_busy or crc_fold_drop or
           fifo_rdata or fifo_level or fifo_full or fifo_empty or
           fifo_burstlen or fifo_pops or fifo_burst_done or
           shift_bpop or shift_cfg or shift_stuff_flag or shift_byte_valid or
           shift_dout or
           nrzi_dout or nrzi_div or nrzi_stuff_err_q or nrzi_eop_q or
           nrzi_sync_q or nrzi_se0 or nrzi_busy or nrzi_ready or
           nrzi_overflow or nrzi_reset_q or
           manch_dout or manch_manch_err or manch_phase_err or manch_locked or
           manch_busy or manch_ready or manch_overflow or manch_bit_valid or
           pc_crc or pc_fifo or pc_shift or pc_nrzi or pc_manch) begin
    case (h_rd_id)
      3'd0:    h_rdata = pc_crc;
      3'd1:    h_rdata = pc_fifo;
      3'd2:    h_rdata = pc_shift;
      3'd3:    h_rdata = pc_nrzi;
      3'd4:    h_rdata = pc_manch;
      default: h_rdata = 8'h00;
    endcase
    if (h_rd_reg != 4'd8)
      h_rdata = as_read(h_rd_id, h_rd_reg);

    e_rdata0 = as_read(e_rid0, {1'b0, e_rreg0});
    e_rdata1 = as_read(e_rid1, {1'b0, e_rreg1});
    e_rdata2 = as_read(e_rid2, {1'b0, e_rreg2});
  end

  assign e_rdata = {e_rdata2, e_rdata1, e_rdata0};

  // ================================================= pin-fabric merge stage
  // Two pin-driving assists (NRZI id3, Manchester id4); higher id wins on an
  // overlapping bit, which is the same ordering the engine stages use.
  // TX occupies tx_base (dp) and tx_base+1 (dm): tx_base must be <= 6.
  wire [7:0] n_mask = (nrzi_pin_en && nrzi_tx_oe) ? (8'h03 << nrzi_txbase)
                                                  : 8'h00;
  wire [7:0] n_data = (nrzi_dp_tx ? (8'h01 << nrzi_txbase) : 8'h00) |
                      (nrzi_dm_tx ? (8'h01 << (nrzi_txbase + 3'd1)) : 8'h00);

  wire [7:0] m_mask = manch_pin_en ? (8'h01 << manch_txbase) : 8'h00;
  wire [7:0] m_data = manch_tx ? (8'h01 << manch_txbase) : 8'h00;

  reg [7:0] a_uo_d, a_uo_m, a_uio_d, a_uio_m, a_oe_d, a_oe_m, a_od_m;

`define AS_APPLY(bk, mk, dt) \
  begin \
    if ((bk) == BANK_UO) begin \
      a_uo_d = (a_uo_d & ~(mk)) | ((dt) & (mk)); \
      a_uo_m = a_uo_m | (mk); \
    end else if ((bk) == BANK_UIO) begin \
      a_uio_d = (a_uio_d & ~(mk)) | ((dt) & (mk)); \
      a_uio_m = a_uio_m | (mk); \
      a_oe_d  = (a_oe_d  & ~(mk)) | (mk); \
      a_oe_m  = a_oe_m | (mk); \
      a_od_m  = a_od_m | (mk);   /* assist pins are push-pull */ \
    end \
  end

  always @* begin
    a_uo_d = 8'h00; a_uo_m = 8'h00;
    a_uio_d = 8'h00; a_uio_m = 8'h00;
    a_oe_d = 8'h00;  a_oe_m = 8'h00;
    a_od_m = 8'h00;
    `AS_APPLY(nrzi_bank, n_mask, n_data)
    `AS_APPLY(manch_bank, m_mask, m_data)
  end

  assign ap_uo_d  = a_uo_d;
  assign ap_uo_m  = a_uo_m;
  assign ap_uio_d = a_uio_d;
  assign ap_uio_m = a_uio_m;
  assign ap_oe_d  = a_oe_d;
  assign ap_oe_m  = a_oe_m;
  assign ap_od_m  = a_od_m;

  // Block outputs that the CSR map does not expose.  Consumed so verilator
  // -Wall stays clean; every one of them is exercised by its unit bench in
  // v2/tb, so an unused here never means unverified.
  wire _unused = &{1'b0,
                   shift_bit_out, shift_bit_valid,
                   nrzi_bit_stb, nrzi_tx_bit, nrzi_eop_done,
                   nrzi_dout_valid, nrzi_dec_busy, nrzi_dec_bit,
                   nrzi_dec_bit_valid, crc_refl_unused,
                   manch_half_stb, manch_dout_valid, manch_bit_out,
                   fifo_irq_unused, fifo_a_data_x, fifo_a_valid_x,
                   crc_bit_out_x};

  // ============================================================ sequential

  always @(posedge clk) begin
    if (!rst_n) begin
      pincfg[0] <= 8'h00; pincfg[1] <= 8'h00; pincfg[2] <= 8'h00;
      pincfg[3] <= 8'h00; pincfg[4] <= 8'h00;

      crc_cfg        <= 8'h20;      // width 32, not reflected, MSB-first
      crc_page       <= 2'd0;
      crc_init       <= 32'hFFFF_FFFF;
      crc_poly       <= 32'h04C1_1DB7;
      crc_xor        <= 32'hFFFF_FFFF;
      crc_start      <= 1'b0;
      crc_cfg_we     <= 1'b0;
      crc_cfg_sel    <= 2'd2;
      crc_cfg_data   <= 32'd0;
      crc_fold_busy  <= 1'b0;
      crc_fold_drop  <= 1'b0;
      crc_fold_byte  <= 8'h00;
      crc_fold_bit   <= 3'd0;

      fifo_burstlen  <= 5'd0;
      fifo_clr       <= 1'b0;
      fifo_arm       <= 1'b0;

      shift_cfg      <= 8'hC0;      // dir=1, width[5:0]=32, en=0
      shift_step     <= 1'b0;

      nrzi_div       <= 6'd32;
      nrzi_en        <= 1'b1;
      nrzi_eop       <= 1'b0;
      nrzi_push_sync <= 1'b0;
      nrzi_stuff_err_q <= 1'b0;
      nrzi_eop_q       <= 1'b0;
      nrzi_sync_q      <= 1'b0;
      nrzi_reset_q     <= 1'b0;

      manch_en       <= 1'b1;
    end else begin
      // ---- one-cycle strobes -------------------------------------------
      crc_start      <= 1'b0;
      crc_cfg_we     <= 1'b0;
      fifo_clr       <= 1'b0;
      fifo_arm       <= 1'b0;
      shift_step     <= 1'b0;
      nrzi_eop       <= 1'b0;
      nrzi_push_sync <= 1'b0;

      // ---- sticky NRZI receive flags (cleared by CMD 0) ----------------
      if (nrzi_stuff_err) nrzi_stuff_err_q <= 1'b1;
      if (nrzi_eop_det)   nrzi_eop_q       <= 1'b1;
      if (nrzi_sync_det)  nrzi_sync_q      <= 1'b1;
      if (nrzi_reset_det) nrzi_reset_q     <= 1'b1;

      // ---- CRC: byte fold pipeline --------------------------------------
      if (crc_fold_busy) begin
        if (crc_fold_bit == 3'd7) crc_fold_busy <= 1'b0;
        else                      crc_fold_bit  <= crc_fold_bit + 3'd1;
      end

      // ---- host PINCFG (host-only, reg 8 of the stride) ------------------
      if (h_we && (h_wr_reg == 4'd8) && (h_wr_id < 3'd5))
        pincfg[h_wr_id] <= h_wdata;

      // ---- CRC CSR ------------------------------------------------------
      if (crc_wr_cfg0) begin
        crc_cfg        <= crc_wr_byte;
        crc_cfg_we     <= 1'b1;         // crc_bit latches width/refl/lsb
        crc_cfg_sel    <= 2'd2;
        crc_cfg_data   <= {24'd0, crc_wr_byte};
      end

      // The LFSR keeps its own copy of init/poly/xorout, so every page write
      // must also be pushed into crc_bit (cfg_sel 0/1/3).  Without this the
      // assist folded with crc_bit's reset defaults -- caught by tb_csr, which
      // compares against zlib.crc32.
      if (crc_wr_page) begin
        crc_cfg_we <= 1'b1;
        case (crc_page)
          2'd1: begin
                  crc_init      <= crc_init_n;
                  crc_cfg_sel   <= 2'd0;
                  crc_cfg_data  <= crc_init_n;
                end
          2'd2: begin
                  crc_poly      <= crc_poly_n;
                  crc_cfg_sel   <= 2'd1;
                  crc_cfg_data  <= crc_poly_n;
                end
          default: begin
                  crc_xor       <= crc_xor_n;
                  crc_cfg_sel   <= 2'd3;
                  crc_cfg_data  <= crc_xor_n;
                end
        endcase
      end

      if (crc_cmd_v) begin
        case (crc_cmd)
          8'd0:  crc_page <= 2'd0;
          8'd1:  crc_start <= 1'b1;          // reload init
          8'd6:  begin                       // flush: fold a zero byte
                   if (!crc_fold_busy) begin
                     crc_fold_byte <= 8'h00;
                     crc_fold_bit  <= 3'd0;
                     crc_fold_busy <= 1'b1;
                   end else crc_fold_drop <= 1'b1;
                 end
          8'd8:  crc_page <= 2'd1;           // init
          8'd9:  crc_page <= 2'd2;           // poly
          8'd10: crc_page <= 2'd3;           // xorout
          default: ;
        endcase
      end

      if (crc_wr_data) begin
        if (!crc_fold_busy) begin
          crc_fold_byte <= crc_wr_byte;
          crc_fold_bit  <= 3'd0;
          crc_fold_busy <= 1'b1;
          crc_fold_drop <= 1'b0;
        end else begin
          crc_fold_drop <= 1'b1;         // STATUS.drop: byte not folded
        end
      end

      // ---- FIFO CSR -----------------------------------------------------
      if (h_wr_id1 && (h_wr_reg == 4'd2))
        fifo_burstlen <= h_wdata[4:0];

      if (fifo_cmd_v) begin
        // Bit-mapped or numeric forms, so an ASST command and a host write to
        // CMD behave the same.
        if ((fifo_cmd & 8'h01) != 8'd0 || fifo_cmd == 8'd3) fifo_arm <= 1'b1;
        if ((fifo_cmd & 8'h02) != 8'd0 || fifo_cmd == 8'd0) fifo_clr <= 1'b1;
      end

      // ---- SHIFT CSR ----------------------------------------------------
      if (h_wr_id2 && (h_wr_reg == 4'd2)) shift_cfg <= h_wdata;

      if (shift_cmd_v) begin
        case (shift_cmd)
          8'd0: shift_cfg  <= 8'hC0;      // reset: MSB-first, width 32, stopped
          8'd1: shift_cfg[0] <= 1'b1;     // start (free-run shift)
          8'd2: shift_cfg[0] <= 1'b0;     // stop
          8'd8: shift_step <= 1'b1;       // one bit
          default: ;
        endcase
      end

      // ---- NRZI CSR -----------------------------------------------------
      if (nrzi_div_wr)
        nrzi_div <= nrzi_div_h ? h_wdata[5:0] : e_wdata[5:0];

      if (nrzi_cmd_v) begin
        case (nrzi_cmd)
          8'd0: begin
                  nrzi_en <= 1'b1;
                  nrzi_stuff_err_q <= 1'b0;
                  nrzi_eop_q       <= 1'b0;
                  nrzi_sync_q      <= 1'b0;
                  nrzi_reset_q     <= 1'b0;
                end
          8'd1: nrzi_en      <= 1'b1;
          8'd2: nrzi_en      <= 1'b0;
          8'd4: nrzi_push_sync <= 1'b1;   // SYNC = 0x80 (KJKJKJKK, LSB first)
          8'd5: nrzi_eop     <= 1'b1;
          default: ;
        endcase
      end

      // ---- MANCH CSR ----------------------------------------------------
      if (manch_cmd_v) begin
        case (manch_cmd)
          8'd0: manch_en <= 1'b1;   // reset = idle-enabled (tx high)
          8'd1: manch_en <= 1'b1;
          8'd2: manch_en <= 1'b0;
          default: ;
        endcase
      end
    end
  end

`undef AS_APPLY

endmodule

`default_nettype wire
