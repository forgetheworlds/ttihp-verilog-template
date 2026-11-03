// -----------------------------------------------------------------------------
// proteus_engine.v -- one PROTEUS protocol engine.
//
// Implements docs/architecture.md sections 3 and 7.  Cycle-level semantics are
// aligned to tools/model.py, which is the executable reference.  Orchestrator
// ruling (binding) applied here:
//   * uniform 24-bit ISA layout: op[23:17] rd[16:14] rs[13:11] imm[10:3] ss[2:0]
//     (tools/isa.py carries the same constants; keep the localparams in sync
//     with src/proteus_defs.vh)
//   * side-set width is 1..3 pins (CFG SIDE [1:0]=width-1, clamped to 3)
//   * WAITC n occupies exactly max(n,1) cycles
//   * default build PROG_DEPTH=32; JMP/DJNZ targets mask to PROG_DEPTH-1
//
// ---------------------------------------------------------------------------
// BUS NAMING (normative for the top level, which merges these buses)
// ---------------------------------------------------------------------------
//   uo_data/uo_mask   : write bus for the uo_out register     (ISA bank UO)
//   wo_data/wo_mask   : write bus for the uio output register (ISA bank UIO)
//   oe_data/oe_mask   : uio output-enable register write
//   od_data/od_mask   : uio open-drain register write
// Merge rule (architecture section 4): reg = (reg & ~mask) | (data & mask),
// engines applied 0..3 so the highest-numbered writer wins an overlapping bit.
// "wo" is the bidirectional-wire (uio) write bus; it is NOT uo_out.
//
// ---------------------------------------------------------------------------
// DELIBERATE MODEL-ALIGNED DECISIONS
// ---------------------------------------------------------------------------
// 1. WAITC n occupies max(n,1) cycles (n=0,1 -> 1; n=5 -> 5), matching the
//    corrected model.  The issue cycle counts as the first.
// 2. PACE completes on the cycle where cycle >= next_int; the deadline then
//    advances by the 24.8 period with the fraction carried separately
//    (next_frac += period[7:0], next_int += period[31:8] + carry).  The integer
//    part is 32 bits, so the horizon is 2^32 cycles; a packed 24.8 successor
//    would truncate at 2^24 cycles and free-run at one completion per cycle
//    afterwards.  PACERST sets next_int = cycle, next_frac = 0, so the first
//    completion after PACERST is one cycle later and every later completion is
//    exactly `period` cycles after the previous one (average, <=1 cycle jitter
//    for fractional periods, no accumulated drift).
// 3. WAITP/IRQWAIT timeouts share one accounting: timeout_cfg is in 256-cycle
//    units (0 = wait forever); the issue cycle never times out, then
//    timeout_cfg*256 stall cycles are allowed before timeout_flag is set and
//    the instruction completes.
// 4. Any completed instruction clears wait_active (model does this for every
//    complete), so no stale wait state survives an instruction.
// 5. Host register writes win over an engine write to the same register in the
//    same cycle (host applied last).
// 6. `run` rising edge restarts the engine: PC=0, halted=0, wait cleared, and
//    no instruction executes in that cycle (matches model.start()).  Gating
//    exec_act with `restart` matters: a phantom execution at the stale PC
//    would commit its register/pin/FIFO side effects before PC is reset.
// 7. ISA bank 3 (undefined) reads as 0 (matches model pin_snapshot()).
// 8. Shift/rotate by 0 leaves the register unchanged and clears C.
//
// ---------------------------------------------------------------------------
// ADDED PORT
// ---------------------------------------------------------------------------
//   prog_ready : output.  Deasserted from reset until the HALT fill (one entry
//                per cycle) has written every program word the host has not
//                written.  The engine does not execute while prog_ready=0.
//                Reset never relies on RAM contents.
//
// Host register port (hr_addr 0..15), all reads combinational:
//   0..7   r0..r7
//   8..11  pacing period bytes 0..3   (24.8 fixed point)
//   12     bit-pin cfg {bank[7:6], bit[5:3], invert[2]}
//   13     side-set cfg {en[7], bank[6:5], base[4:2], width-1[1:0]}
//   14     WAITP/IRQWAIT timeout, 256-cycle units (0 = disabled)
//   15     status byte, read-only, bit order per architecture E_STATUS:
//          [7] timeout_flag [6] nf_flag [5] out_full [4] out_empty
//          [3] in_full      [2] in_empty [1] halted  [0] run
// -----------------------------------------------------------------------------
`default_nettype none

module proteus_engine #(
  parameter PROG_DEPTH = 32,
  parameter ENG_ID     = 0,
  // in/out FIFO entries (legal 2..8).  Depth is an area lever only: push/pop
  // blocking semantics are identical at any depth, only the full threshold
  // moves.
  parameter FIFO_DEPTH = 4
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        run,
  // program memory host port
  input  wire        host_prog_we,
  input  wire [2:0]  host_prog_be,      // byte write enables, bit b = byte b
  input  wire [5:0]  host_prog_addr,
  input  wire [23:0] host_prog_data,
  output wire [23:0] host_prog_rdata,   // combinational read of prog[host_prog_addr]
  // pin snapshot (cycle start)
  input  wire [7:0]  pin_ui,
  input  wire [7:0]  pin_uo,
  input  wire [7:0]  pin_uio,
  // pin write buses (combinational, valid every cycle the engine executes)
  output reg  [7:0]  wo_data,
  output reg  [7:0]  wo_mask,
  output reg  [7:0]  uo_data,
  output reg  [7:0]  uo_mask,
  output reg  [7:0]  oe_data,
  output reg  [7:0]  oe_mask,
  output reg  [7:0]  od_data,
  output reg  [7:0]  od_mask,
  // time / sync
  input  wire [31:0] cycle,
  input  wire [7:0]  irq,
  output wire [7:0]  irq_set,
  output wire [7:0]  irq_clr,
  input  wire [3:0]  run_mask,
  input  wire        bar_go,
  output wire        bar_req,
  output wire [1:0]  bar_id,
  // capture
  output wire        cap_req,
  output wire [4:0]  cap_tag,
  // host register port
  input  wire        hr_we,
  input  wire [3:0]  hr_addr,
  input  wire [7:0]  hr_wdata,
  output wire [7:0]  hr_rdata,
  // host fifo ports
  input  wire        host_in_push,
  input  wire [7:0]  host_in_data,
  input  wire        host_out_pop,
  output wire [7:0]  host_out_data,
  // assist CSR port (LDAS / STAS / ASST, docs/hybrid-architecture.md 5.2).
  // Reads are combinational on (as_id, as_reg) so LDAS retires in one cycle;
  // as_empty is the assist's data-path-empty condition for that read (an empty
  // FIFO DATA read sets nf_flag and leaves rd unchanged, the PULLN rule).
  output wire        as_rd,
  output wire        as_wr,
  output wire [2:0]  as_id,
  output wire [2:0]  as_reg,
  output wire [7:0]  as_wdata,
  output wire        as_cmd_en,
  output wire [2:0]  as_cmd_id,
  output wire [7:0]  as_cmd,
  input  wire [7:0]  as_rdata,
  input  wire        as_empty,
  // status
  output wire        halted,
  output wire        error,
  output wire [5:0]  dbg_pc,
  output wire        prog_ready,
  // combinational: a HALT instruction is executing this cycle, so the top can
  // retire the engine's RUN bit in the same cycle (model.py sets run=0 with
  // halted=1 on the HALT step).
  output wire        halt_exec
);

  // ---------------------------------------------------------------------------
  // ISA field map -- mirrors tools/isa.py and src/proteus_defs.vh
  // ---------------------------------------------------------------------------
  localparam OP_SHIFT = 17, OP_BITS = 7;
  localparam RD_SHIFT = 14, RD_BITS = 3;
  localparam RS_SHIFT = 11, RS_BITS = 3;
  localparam IMM_SHIFT = 3, IMM_BITS = 8;
  localparam SS_SHIFT = 0,  SS_BITS = 3;

  // ---------------------------------------------------------------------------
  // Derived geometry
  // ---------------------------------------------------------------------------
  // PC / RAM index width is derived from the actual depth so shallow builds
  // really save area (a fixed 5..6-bit PC muxes all 32..64 words at any depth).
  // LAST_ADDR stays 6 bits because the host_prog_addr port is 6 bits: the
  // out-of-range test must compare the *whole* port, otherwise address 32
  // aliases word 0 in a 32-entry build.
  localparam integer ADDR_W = (PROG_DEPTH > 1) ? $clog2(PROG_DEPTH) : 1;
  /* verilator lint_off WIDTHTRUNC */
  localparam [ADDR_W-1:0] LAST_PC  = PROG_DEPTH - 1;
  localparam [5:0]        LAST_ADDR = PROG_DEPTH - 1;
  /* verilator lint_on WIDTHTRUNC */
  localparam [ADDR_W-1:0] ADDR_ONE = 1;

  // FIFO geometry.  Pointer width wraps modulo FIFO_DEPTH; the count needs one
  // more bit than the pointer because it must represent FIFO_DEPTH itself.
  localparam integer      FIFO_AW  = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
  localparam integer      FIFO_CW  = $clog2(FIFO_DEPTH + 1);
  localparam [FIFO_CW-1:0] FIFO_FULL = FIFO_DEPTH;

  // ---------------------------------------------------------------------------
  // Opcodes (tools/isa.py is the numeric source of truth)
  // ---------------------------------------------------------------------------
  localparam [6:0] OP_LDI    = 7'h00, OP_ADDI = 7'h01, OP_SUBI  = 7'h02,
                   OP_ANDI   = 7'h03, OP_ORI  = 7'h04, OP_XORI  = 7'h05,
                   OP_CMPI   = 7'h06, OP_SHLI = 7'h07, OP_SHRI  = 7'h08,
                   OP_ASRI   = 7'h09, OP_ROLI = 7'h0A, OP_RORI  = 7'h0B,
                   OP_ADCI   = 7'h0C, OP_SBCI = 7'h0D, OP_MOVI  = 7'h0E;
  localparam [6:0] OP_MOV    = 7'h10, OP_ADD  = 7'h11, OP_SUB   = 7'h12,
                   OP_AND    = 7'h13, OP_OR   = 7'h14, OP_XOR   = 7'h15,
                   OP_CMP    = 7'h16, OP_SHL  = 7'h17, OP_SHR   = 7'h18,
                   OP_ASR    = 7'h19, OP_ROL  = 7'h1A, OP_ROR   = 7'h1B,
                   OP_NOT    = 7'h1C, OP_NEG  = 7'h1D, OP_INC   = 7'h1E,
                   OP_DEC    = 7'h1F, OP_ADC  = 7'h20, OP_SBC   = 7'h21;
  localparam [6:0] OP_SETP   = 7'h22, OP_CLRP = 7'h23, OP_TOGP  = 7'h24,
                   OP_OUTP   = 7'h25, OP_INPR = 7'h26, OP_DIRS  = 7'h27,
                   OP_DIRC   = 7'h28, OP_ODSET= 7'h29, OP_ODCLR = 7'h2A,
                   OP_OUTBIT = 7'h2B, OP_INBIT= 7'h2C, OP_WAITP = 7'h2D;
  localparam [6:0] OP_JMP    = 7'h30, OP_JZ   = 7'h31, OP_JNZ   = 7'h32,
                   OP_JC     = 7'h33, OP_JNC  = 7'h34, OP_JN    = 7'h35,
                   OP_DJNZ   = 7'h36, OP_HALT = 7'h38, OP_NOP   = 7'h39,
                   OP_WAITC  = 7'h3A, OP_PACE = 7'h3B, OP_PACERST=7'h3C,
                   OP_ASSERT = 7'h3E;
  localparam [6:0] OP_PUSH   = 7'h40, OP_PULL = 7'h41, OP_PUSHN = 7'h42,
                   OP_PULLN  = 7'h43, OP_IRQSET=7'h44, OP_IRQCLR= 7'h45,
                   OP_IRQWAIT= 7'h46, OP_BAR  = 7'h47, OP_TSLO  = 7'h48,
                   OP_TSHI   = 7'h49, OP_MEASLO=7'h4A, OP_MEASHI= 7'h4B,
                   OP_CAPTURE= 7'h4C, OP_CFG  = 7'h4D,
                   OP_LDAS   = 7'h4E, OP_STAS = 7'h4F, OP_ASST = 7'h50;

  localparam [23:0] HALT_WORD = {7'h38, 3'd0, 3'd0, 8'h00, 3'd0};

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  reg [23:0] prog_mem [0:PROG_DEPTH-1];
  reg [PROG_DEPTH-1:0] prog_written; // entries written by the host during fill
  reg [ADDR_W-1:0] fill_cnt;
  reg        prog_ready_r;

  reg [ADDR_W-1:0] pc_r;
  reg [7:0]  regs [0:7];
  reg        z_r, c_r, n_r;
  reg        halted_r, error_r;

  reg [31:0] period_r;            // 24.8 fixed point (int = period_r[31:8])
  // Deadline: 32-bit integer cycle + 8-bit fraction.  Keeping the integer part
  // 32 bits wide is what gives a 2^32-cycle horizon; a packed 24.8 next value
  // truncates at 2^24 cycles and then free-runs (see decision 2).
  reg [31:0] next_int_r;          // next completion cycle
  reg [7:0]  next_frac_r;         // fractional accumulator

  reg        ss_en_r;
  reg [1:0]  ss_bank_r;
  reg [2:0]  ss_base_r;
  reg [1:0]  ss_wm1_r;            // width - 1, clamped to 2 (width 1..3)

  reg [1:0]  bp_bank_r;
  reg [2:0]  bp_bit_r;
  reg        bp_inv_r;

  reg [7:0]  timeout_r;
  reg        wait_active_r;
  reg [31:0] wait_left_r;
  reg [31:0] ts_event_r;
  reg        nf_r, tof_r;

  // input FIFO (host -> engine), FIFO_DEPTH x 8
  reg [7:0]        in_mem [0:FIFO_DEPTH-1];
  reg [FIFO_AW-1:0] in_rd, in_wr;
  reg [FIFO_CW-1:0] in_cnt;
  // output FIFO (engine -> host), FIFO_DEPTH x 8
  reg [7:0]         out_mem [0:FIFO_DEPTH-1];
  reg [FIFO_AW-1:0] out_rd, out_wr;
  reg [FIFO_CW-1:0] out_cnt;

  reg        run_q;

  // ---------------------------------------------------------------------------
  // Instruction fetch (asynchronous read)
  // ---------------------------------------------------------------------------
  wire [23:0] insn;
  assign insn = prog_mem[pc_r];

  // ---------------------------------------------------------------------------
  // Host program-write merge helpers
  // ---------------------------------------------------------------------------
  /* verilator lint_off CMPCONST */
  wire host_addr_ok = (host_prog_addr <= LAST_ADDR);  // false for i >= depth
  /* verilator lint_on CMPCONST */
  wire [ADDR_W-1:0] host_waddr = host_prog_addr[ADDR_W-1:0];
  wire [23:0] host_bmask = {{8{host_prog_be[2]}},
                            {8{host_prog_be[1]}},
                            {8{host_prog_be[0]}}};
  // The word at host_waddr is defined if the host wrote it, the fill finished,
  // or the fill counter has already passed it.
  wire host_word_valid = prog_written[host_waddr] | prog_ready_r |
                         (host_waddr < fill_cnt);
  wire [23:0] host_base = host_word_valid ? prog_mem[host_waddr] : HALT_WORD;

  // Host program read: same memory, zero outside PROG_DEPTH.
  assign host_prog_rdata =
      host_addr_ok ? prog_mem[host_prog_addr[ADDR_W-1:0]]
                                          : 24'h000000;

  wire [OP_BITS-1:0]  f_op  = insn[OP_SHIFT  +: OP_BITS];
  wire [RD_BITS-1:0]  f_rd  = insn[RD_SHIFT  +: RD_BITS];
  wire [RS_BITS-1:0]  f_rs  = insn[RS_SHIFT  +: RS_BITS];
  wire [IMM_BITS-1:0] f_imm = insn[IMM_SHIFT +: IMM_BITS];
  wire [SS_BITS-1:0]  f_ss  = insn[SS_SHIFT  +: SS_BITS];

  wire [10:0] waitc_n = {f_rs, f_imm};   // WAITC count, 0..2047
  wire [15:0] meas_delta = cycle[15:0] - ts_event_r[15:0];

  // A run rising edge restarts the engine at PC 0 (model.start()).  That cycle
  // must not execute: exec_act is combinational on `run`, so without this gate
  // the engine issues the instruction at the *stale* PC while the same edge
  // resets PC to 0 -- side effects of that phantom instruction are visible
  // (e.g. a PUSH at the stale PC lands in the output FIFO with pre-load data).
  wire restart   = run & ~run_q;
  wire exec_act  = rst_n & run & ~halted_r & prog_ready_r & ~restart;
  wire [3:0] self_mask = 4'b0001 << ENG_ID;

  // ---------------------------------------------------------------------------
  // Side-set expansion
  // ---------------------------------------------------------------------------
  wire [2:0] ss_width = {1'b0, ss_wm1_r} + 3'd1;   // 1..3
  wire [2:0] ss_bmask = (3'd1 << ss_width) - 3'd1;
  wire [7:0] ss_mask  = {{5{1'b0}}, ss_bmask} << ss_base_r;
  wire [7:0] ss_val   = ({{5{1'b0}}, f_ss} & {{5{1'b0}}, ss_bmask}) << ss_base_r;

  // ---------------------------------------------------------------------------
  // Status helpers
  // ---------------------------------------------------------------------------
  wire in_empty_w  = (in_cnt  == 0);
  wire in_full_w   = (in_cnt  == FIFO_FULL);
  wire out_empty_w = (out_cnt == 0);
  wire out_full_w  = (out_cnt == FIFO_FULL);

  // bar_req must be a pure function of execution state: it must NOT depend on
  // bar_go, otherwise the top-level release logic (bar_req -> arrivals ->
  // release -> bar_go) forms a zero-delay combinational loop.  bar_go only
  // gates the advance, in the OP_BAR case below.
  wire bar_waiting = exec_act && (f_op == OP_BAR) &&
                     ((run_mask & ~self_mask) != 4'h0);

  // ---------------------------------------------------------------------------
  // Combinational next-state / write-bus generation
  // ---------------------------------------------------------------------------
  reg [ADDR_W-1:0] n_pc;
  reg        n_pc_we;
  reg [7:0]  n_reg_v;
  reg [2:0]  n_reg_i;
  reg        n_reg_we;
  reg        n_z, n_c, n_n;
  reg        n_zn_we, n_c_we;
  reg        n_wait_active;
  reg [31:0] n_wait_left;
  reg [31:0] n_ts_event;
  reg        n_nf, n_tof;
  reg        n_halted, n_error;
  reg [31:0] n_period;
  reg [31:0] n_next_int;
  reg [7:0]  n_next_frac;
  reg        n_next_carry;
  reg        n_ss_en;
  reg [1:0]  n_ss_bank;
  reg [2:0]  n_ss_base;
  reg [1:0]  n_ss_wm1;
  reg [1:0]  n_bp_bank;
  reg [2:0]  n_bp_bit;
  reg        n_bp_inv;
  reg [7:0]  n_timeout;
  reg        n_in_pop, n_out_push;
  reg [7:0]  n_out_data;
  reg [7:0]  irq_set_v, irq_clr_v;
  reg        cap_req_v;
  reg [4:0]  cap_tag_v;

  reg [7:0]  p_uo_mask, p_uo_val;
  reg [7:0]  p_uio_mask, p_uio_val;
  reg [7:0]  p_oe_mask, p_oe_val;
  reg [7:0]  p_od_mask, p_od_val;

  reg        do_advance;
  reg        take;
  reg [7:0]  tmp_v;
  reg        tmp_c;
  reg [8:0]  tmp9;          // ALU result (carry + value)
  reg [7:0]  hr_rdata_r;
  reg [5:0]  pc_status;

  assign host_out_data = out_mem[out_rd];
  assign hr_rdata      = hr_rdata_r;
  assign halted        = halted_r;
  assign error         = error_r;
  assign dbg_pc        = pc_status;
  assign prog_ready    = prog_ready_r;
  // Same decode that sets n_halted below: execution active and opcode HALT.
  assign halt_exec     = exec_act && (f_op == OP_HALT);
  assign irq_set       = irq_set_v;
  assign irq_clr       = irq_clr_v;
  assign cap_req       = cap_req_v;
  assign cap_tag       = cap_tag_v;
  assign bar_req       = bar_waiting;
  assign bar_id        = (exec_act && (f_op == OP_BAR)) ? f_imm[1:0] : 2'b00;

  // Assist CSR port.  The access strobes are single-cycle because all three
  // opcodes always advance, so exec_act is high for exactly one cycle of a
  // LDAS/STAS/ASST.  LDAS/STAS take the assist id from imm8[2:0] and the
  // register index from rs; ASST takes the assist id from rs and the command
  // from imm8 (docs/hybrid-architecture.md 5.2).
  assign as_rd     = exec_act && (f_op == OP_LDAS);
  assign as_wr     = exec_act && (f_op == OP_STAS);
  assign as_id     = f_imm[2:0];
  assign as_reg    = f_rs;
  assign as_wdata  = regs[f_rd];
  assign as_cmd_en = exec_act && (f_op == OP_ASST);
  assign as_cmd_id = f_rs;
  assign as_cmd    = f_imm;

  // 2-bit bank -> cycle-start pin snapshot.  Argument-passed on purpose so
  // always @* sensitivity is exact; bank 3 (undefined) reads 0 like the model.
  function [7:0] bank_snap;
    input [1:0] bk;
    input [7:0] ui;
    input [7:0] uo;
    input [7:0] uio;
    begin
      case (bk)
        2'd0:    bank_snap = ui;
        2'd1:    bank_snap = uo;
        2'd2:    bank_snap = uio;
        default: bank_snap = 8'h00;
      endcase
    end
  endfunction

  // 8-bit ALU.  Returns {carry, result}.  Logical ops leave carry = cin;
  // shifts/rotates by 0 clear carry (model "shift by zero" rule).
  function [8:0] alu_f;
    input [6:0]  opc;
    input [7:0]  a;
    input [7:0]  b;
    input        cin;
    reg [8:0]    t;
    reg [7:0]    r;
    reg          co;
    reg [3:0]    shn;
    begin
      r   = a;
      co  = cin;
      t   = 9'h000;
      shn = {1'b0, b[2:0]};
      case (opc)
        OP_ADD, OP_ADDI: begin
          t  = {1'b0, a} + {1'b0, b};
          co = t[8];
          r  = t[7:0];
        end
        OP_ADC, OP_ADCI: begin
          t  = {1'b0, a} + {1'b0, b} + {8'd0, cin};
          co = t[8];
          r  = t[7:0];
        end
        OP_SUB, OP_SUBI, OP_CMP, OP_CMPI: begin
          t  = {1'b0, a} - {1'b0, b};
          co = t[8];
          r  = t[7:0];
        end
        OP_SBC, OP_SBCI: begin
          t  = {1'b0, a} - {1'b0, b} - {8'd0, cin};
          co = t[8];
          r  = t[7:0];
        end
        OP_AND, OP_ANDI: r = a & b;
        OP_OR,  OP_ORI:  r = a | b;
        OP_XOR, OP_XORI: r = a ^ b;
        OP_SHL, OP_SHLI: begin
          r = a << shn[2:0];
          if (shn != 4'd0) co = |(a & (8'h01 << (4'd8 - shn)));
          else             co = 1'b0;
        end
        OP_SHR, OP_SHRI: begin
          r = a >> shn[2:0];
          if (shn != 4'd0) co = |(a & (8'h01 << (shn - 4'd1)));
          else             co = 1'b0;
        end
        OP_ASR, OP_ASRI: begin
          if (shn == 4'd0) begin
            r  = a;
            co = 1'b0;
          end else begin
            r  = (a >> shn[2:0]) |
                 (a[7] ? (8'hFF << (4'd8 - shn)) : 8'h00);
            co = |(a & (8'h01 << (shn - 4'd1)));
          end
        end
        OP_ROL, OP_ROLI: begin
          if (shn == 4'd0) begin
            r  = a;
            co = 1'b0;
          end else begin
            r  = (a << shn[2:0]) | (a >> (4'd8 - shn));
            co = r[0];
          end
        end
        OP_ROR, OP_RORI: begin
          if (shn == 4'd0) begin
            r  = a;
            co = 1'b0;
          end else begin
            r  = (a >> shn[2:0]) | (a << (4'd8 - shn));
            co = r[7];
          end
        end
        default: begin
          r  = a;
          co = cin;
        end
      endcase
      alu_f = {co, r};
    end
  endfunction

  // Pin write into the per-bank accumulators.  Instruction writes are applied
  // after side-set, so they win on overlapping bits.
`define PW_WRITE(bk, mk, vl, autoe) \
  begin \
    if ((bk) == 2'd1) begin \
      p_uo_mask = p_uo_mask | (mk); \
      p_uo_val  = (p_uo_val & ~(mk)) | ((vl) & (mk)); \
    end else if ((bk) == 2'd2) begin \
      p_uio_mask = p_uio_mask | (mk); \
      p_uio_val  = (p_uio_val & ~(mk)) | ((vl) & (mk)); \
      if ((autoe)) begin \
        p_oe_mask = p_oe_mask | (mk); \
        p_oe_val  = (p_oe_val & ~(mk)) | (mk); \
      end \
    end \
  end

  always @* begin
    // ---- defaults ------------------------------------------------------
    p_uo_mask  = 8'h00; p_uo_val  = 8'h00;
    p_uio_mask = 8'h00; p_uio_val = 8'h00;
    p_oe_mask  = 8'h00; p_oe_val  = 8'h00;
    p_od_mask  = 8'h00; p_od_val  = 8'h00;

    // Write buses must be driven every cycle, not only when executing:
    // otherwise the combinational block infers latches (verilator LATCH).
    wo_mask = 8'h00; wo_data = 8'h00;
    uo_mask = 8'h00; uo_data = 8'h00;
    oe_mask = 8'h00; oe_data = 8'h00;
    od_mask = 8'h00; od_data = 8'h00;

    irq_set_v = 8'h00; irq_clr_v = 8'h00;
    cap_req_v = 1'b0;  cap_tag_v = 5'h00;

    n_pc         = pc_r;
    n_pc_we      = 1'b0;
    n_reg_i      = f_rd;
    n_reg_v      = 8'h00;
    n_reg_we     = 1'b0;
    n_z          = z_r;
    n_c          = c_r;
    n_n          = n_r;
    n_zn_we      = 1'b0;
    n_c_we       = 1'b0;
    n_wait_active= wait_active_r;
    n_wait_left  = wait_left_r;
    n_ts_event   = ts_event_r;
    n_nf         = nf_r;
    n_tof        = tof_r;
    n_halted     = halted_r;
    n_error      = error_r;
    n_period     = period_r;
    n_next_int   = next_int_r;
    n_next_frac  = next_frac_r;
    n_next_carry = 1'b0;
    n_ss_en      = ss_en_r;
    n_ss_bank    = ss_bank_r;
    n_ss_base    = ss_base_r;
    n_ss_wm1     = ss_wm1_r;
    n_bp_bank    = bp_bank_r;
    n_bp_bit     = bp_bit_r;
    n_bp_inv     = bp_inv_r;
    n_timeout    = timeout_r;
    n_in_pop     = 1'b0;
    n_out_push   = 1'b0;
    n_out_data   = 8'h00;

    do_advance   = 1'b1;
    take         = 1'b0;
    tmp_v        = 8'h00;
    tmp_c        = 1'b0;
    tmp9         = 9'h000;

    if (exec_act) begin
      // ---- side-set: applied every cycle the instruction is in flight --
      if (ss_en_r && (ss_mask != 8'h00)) begin
        if (ss_bank_r == 2'd1) begin
          p_uo_mask = p_uo_mask | ss_mask;
          p_uo_val  = (p_uo_val & ~ss_mask) | ss_val;
        end else if (ss_bank_r == 2'd2) begin
          p_uio_mask = p_uio_mask | ss_mask;
          p_uio_val  = (p_uio_val & ~ss_mask) | ss_val;
          p_oe_mask  = p_oe_mask | ss_mask;
          p_oe_val   = p_oe_val | ss_mask;
        end
      end

      // ---- execute -----------------------------------------------------
      case (f_op)
        // ---------------- ALU, immediate -------------------------------
        OP_LDI, OP_MOVI: begin
          n_reg_v  = f_imm;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (f_imm == 8'h00);
          n_n      = f_imm[7];
          n_zn_we  = 1'b1;
        end

        OP_ASSERT: begin
          if (regs[f_rd] != f_imm) n_error = 1'b1;
        end

        OP_ADDI, OP_SUBI, OP_ANDI, OP_ORI, OP_XORI, OP_CMPI,
        OP_SHLI, OP_SHRI, OP_ASRI, OP_ROLI, OP_RORI, OP_ADCI, OP_SBCI: begin
          tmp9 = alu_f(f_op, regs[f_rd], f_imm, c_r);
          tmp_c = tmp9[8];
          tmp_v = tmp9[7:0];
          if (f_op != OP_CMPI) begin
            n_reg_v  = tmp_v;
            n_reg_i  = f_rd;
            n_reg_we = 1'b1;
          end
          n_z     = (tmp_v == 8'h00);
          n_n     = tmp_v[7];
          n_zn_we = 1'b1;
          n_c     = tmp_c;
          n_c_we  = 1'b1;
        end

        // ---------------- ALU, register --------------------------------
        OP_MOV: begin
          tmp_v    = regs[f_rs];
          n_reg_v  = tmp_v;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (tmp_v == 8'h00);
          n_n      = tmp_v[7];
          n_zn_we  = 1'b1;
        end

        OP_ADD, OP_SUB, OP_AND, OP_OR, OP_XOR, OP_CMP,
        OP_SHL, OP_SHR, OP_ASR, OP_ROL, OP_ROR, OP_ADC, OP_SBC: begin
          tmp9 = alu_f(f_op, regs[f_rd], regs[f_rs], c_r);
          tmp_c = tmp9[8];
          tmp_v = tmp9[7:0];
          if (f_op != OP_CMP) begin
            n_reg_v  = tmp_v;
            n_reg_i  = f_rd;
            n_reg_we = 1'b1;
          end
          n_z     = (tmp_v == 8'h00);
          n_n     = tmp_v[7];
          n_zn_we = 1'b1;
          n_c     = tmp_c;
          n_c_we  = 1'b1;
        end

        // ---------------- unary ALU ------------------------------------
        OP_NOT: begin
          tmp_v    = ~regs[f_rd];
          n_reg_v  = tmp_v;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (tmp_v == 8'h00);
          n_n      = tmp_v[7];
          n_zn_we  = 1'b1;
        end

        OP_NEG: begin
          tmp9 = alu_f(OP_SUB, 8'h00, regs[f_rd], c_r);
          tmp_c = tmp9[8];
          tmp_v = tmp9[7:0];
          n_reg_v  = tmp_v;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (tmp_v == 8'h00);
          n_n      = tmp_v[7];
          n_zn_we  = 1'b1;
          n_c      = tmp_c;
          n_c_we   = 1'b1;
        end

        OP_INC: begin
          tmp9 = alu_f(OP_ADD, regs[f_rd], 8'h01, c_r);
          tmp_c = tmp9[8];
          tmp_v = tmp9[7:0];
          n_reg_v  = tmp_v;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (tmp_v == 8'h00);
          n_n      = tmp_v[7];
          n_zn_we  = 1'b1;
          n_c      = tmp_c;
          n_c_we   = 1'b1;
        end

        OP_DEC: begin
          tmp9 = alu_f(OP_SUB, regs[f_rd], 8'h01, c_r);
          tmp_c = tmp9[8];
          tmp_v = tmp9[7:0];
          n_reg_v  = tmp_v;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (tmp_v == 8'h00);
          n_n      = tmp_v[7];
          n_zn_we  = 1'b1;
          n_c      = tmp_c;
          n_c_we   = 1'b1;
        end

        // ---------------- bit-pin shortcuts ----------------------------
        OP_OUTBIT: begin
          tmp_v = regs[f_rd];
          if (bp_inv_r) tmp_v[0] = ~tmp_v[0];
          `PW_WRITE(bp_bank_r, (8'h01 << bp_bit_r),
                    (tmp_v[0] ? (8'h01 << bp_bit_r) : 8'h00), 1'b1)
        end

        OP_INBIT: begin
          tmp_v = bank_snap(bp_bank_r, pin_ui, pin_uo, pin_uio);
          tmp_v = {7'h00, (tmp_v[bp_bit_r] ^ bp_inv_r)};
          n_reg_v  = tmp_v;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (tmp_v == 8'h00);
          n_n      = 1'b0;
          n_zn_we  = 1'b1;
        end

        // ---------------- pin operations -------------------------------
        OP_SETP: `PW_WRITE(f_rs[1:0], f_imm, 8'hFF, 1'b1)

        OP_CLRP: `PW_WRITE(f_rs[1:0], f_imm, 8'h00, 1'b1)

        OP_TOGP: begin
          tmp_v = bank_snap(f_rs[1:0], pin_ui, pin_uo, pin_uio);
          `PW_WRITE(f_rs[1:0], f_imm, ~tmp_v, 1'b1)
        end

        OP_OUTP: `PW_WRITE(f_rs[1:0], f_imm, regs[f_rd], 1'b1)

        OP_INPR: begin
          tmp_v = bank_snap(f_rs[1:0], pin_ui, pin_uo, pin_uio) & f_imm;
          n_reg_v  = tmp_v;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (tmp_v == 8'h00);
          n_n      = tmp_v[7];
          n_zn_we  = 1'b1;
        end

        OP_DIRS: begin
          if (f_rs[1:0] == 2'd2) begin
            p_oe_mask = p_oe_mask | f_imm;
            p_oe_val  = (p_oe_val & ~f_imm) | f_imm;
          end
        end

        OP_DIRC: begin
          if (f_rs[1:0] == 2'd2) begin
            p_oe_mask = p_oe_mask | f_imm;
            p_oe_val  = p_oe_val & ~f_imm;
          end
        end

        OP_ODSET: begin
          if (f_rs[1:0] == 2'd2) begin
            p_od_mask = p_od_mask | f_imm;
            p_od_val  = (p_od_val & ~f_imm) | f_imm;
          end
        end

        OP_ODCLR: begin
          if (f_rs[1:0] == 2'd2) begin
            p_od_mask = p_od_mask | f_imm;
            p_od_val  = p_od_val & ~f_imm;
          end
        end

        // WAITP bank, mask, level.  Level and bank both live in rs.
        OP_WAITP: begin
          tmp_v = bank_snap(f_rs[1:0], pin_ui, pin_uo, pin_uio) & f_imm;
          if (f_rs[2] ? (tmp_v == f_imm) : (tmp_v == 8'h00)) begin
            n_ts_event    = cycle;
            n_wait_active = 1'b0;
            n_wait_left   = 32'd0;
          end else if (!wait_active_r) begin
            n_wait_active = 1'b1;
            n_wait_left   = {16'h0000, timeout_r, 8'h00};
            do_advance    = 1'b0;
          end else if (timeout_r != 8'h00) begin
            if (wait_left_r <= 32'd1) begin
              n_tof         = 1'b1;
              n_wait_active = 1'b0;
              n_wait_left   = 32'd0;
            end else begin
              n_wait_left = wait_left_r - 32'd1;
              do_advance  = 1'b0;
            end
          end else begin
            do_advance = 1'b0;   // timeout disabled: wait forever
          end
        end

        // ---------------- control --------------------------------------
        OP_JMP, OP_JZ, OP_JNZ, OP_JC, OP_JNC, OP_JN: begin
          case (f_rd)
            3'd0: take = 1'b1;      // ALWAYS
            3'd1: take = z_r;       // Z
            3'd2: take = ~z_r;      // NZ
            3'd3: take = c_r;       // C
            3'd4: take = ~c_r;      // NC
            3'd5: take = n_r;       // N
            3'd6: take = z_r;       // EQ
            default: take = ~z_r;   // NE
          endcase
          if (take) begin
            n_pc       = f_imm[ADDR_W-1:0] & LAST_PC;
            n_pc_we    = 1'b1;
            do_advance = 1'b0;
          end
        end

        OP_DJNZ: begin
          tmp_v = regs[f_rd] - 8'd1;
          n_reg_v  = tmp_v;
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
          n_z      = (tmp_v == 8'h00);
          n_n      = tmp_v[7];
          n_zn_we  = 1'b1;
          if (tmp_v != 8'h00) begin
            n_pc       = f_imm[ADDR_W-1:0] & LAST_PC;
            n_pc_we    = 1'b1;
            do_advance = 1'b0;
          end
        end

        OP_HALT: begin
          n_halted   = 1'b1;
          do_advance = 1'b0;
        end

        OP_WAITC: begin
          // max(n,1) cycles: issue cycle sets wait_left = max(n,1)-1 and
          // stalls while it is non-zero; later cycles decrement and complete
          // when the decrement reaches zero.
          if (!wait_active_r) begin
            n_wait_active = 1'b1;
            n_wait_left   = (waitc_n == 11'd0) ? 32'd0 :
                            ({21'd0, waitc_n} - 32'd1);
            if (n_wait_left != 32'd0) do_advance = 1'b0;
          end else if (wait_left_r > 32'd1) begin
            n_wait_left = wait_left_r - 32'd1;
            do_advance  = 1'b0;
          end else begin
            n_wait_left   = 32'd0;
            n_wait_active = 1'b0;
          end
        end

        OP_PACE: begin
          // Stall while cycle < next_int.  On completion the deadline advances
          // by the 24.8 period, integer and fraction separately, so the
          // average rate is exact with no drift and the horizon is 2^32 cycles
          // (32-bit wraparound only after ~89 s at 48 MHz).
          if (cycle >= next_int_r) begin
            {n_next_carry, n_next_frac} = {1'b0, next_frac_r} +
                                          {1'b0, period_r[7:0]};
            n_next_int = next_int_r + {8'h00, period_r[31:8]} +
                         {31'd0, n_next_carry};
          end else begin
            do_advance = 1'b0;
          end
        end

        OP_PACERST: begin
          n_next_int  = cycle;
          n_next_frac = 8'h00;
        end

        OP_NOP: ; // default behaviour

        // ---------------- streaming ------------------------------------
        OP_PUSH: begin
          if (out_cnt < FIFO_FULL) begin
            n_out_push = 1'b1;
            n_out_data = regs[f_rd];
            n_nf       = 1'b0;
          end else begin
            do_advance = 1'b0;
          end
        end

        OP_PULL: begin
          if (in_cnt > 0) begin
            n_reg_v  = in_mem[in_rd];
            n_reg_i  = f_rd;
            n_reg_we = 1'b1;
            n_in_pop = 1'b1;
            n_nf     = 1'b0;
          end else begin
            do_advance = 1'b0;
          end
        end

        OP_PUSHN: begin
          if (out_cnt < FIFO_FULL) begin
            n_out_push = 1'b1;
            n_out_data = regs[f_rd];
            n_nf       = 1'b0;
          end else begin
            n_nf = 1'b1;
          end
        end

        OP_PULLN: begin
          if (in_cnt > 0) begin
            n_reg_v  = in_mem[in_rd];
            n_reg_i  = f_rd;
            n_reg_we = 1'b1;
            n_in_pop = 1'b1;
            n_nf     = 1'b0;
          end else begin
            n_nf = 1'b1;
          end
        end

        // ---------------- IRQ / barrier --------------------------------
        OP_IRQSET:  irq_set_v = 8'd1 << f_imm[2:0];

        OP_IRQCLR:  irq_clr_v = 8'd1 << f_imm[2:0];

        OP_IRQWAIT: begin
          if (irq[f_imm[2:0]]) begin
            n_wait_active = 1'b0;
            n_wait_left   = 32'd0;
          end else if (!wait_active_r) begin
            n_wait_active = 1'b1;
            n_wait_left   = {16'h0000, timeout_r, 8'h00};
            do_advance    = 1'b0;
          end else if (timeout_r != 8'h00) begin
            if (wait_left_r <= 32'd1) begin
              n_tof         = 1'b1;
              n_wait_active = 1'b0;
              n_wait_left   = 32'd0;
            end else begin
              n_wait_left = wait_left_r - 32'd1;
              do_advance  = 1'b0;
            end
          end else begin
            do_advance = 1'b0;
          end
        end

        OP_BAR: begin
          // Complete immediately when this engine is the only runner; else
          // hand off to the top-level barrier unit via bar_req/bar_go.
          if (((run_mask & ~self_mask) != 4'h0) && !bar_go)
            do_advance = 1'b0;
        end

        // ---------------- time / measurement ---------------------------
        OP_TSLO: begin
          n_reg_v  = cycle[7:0];
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
        end

        OP_TSHI: begin
          n_reg_v  = cycle[15:8];
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
        end

        OP_MEASLO: begin
          n_reg_v  = meas_delta[7:0];
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
        end

        OP_MEASHI: begin
          n_reg_v  = meas_delta[15:8];
          n_reg_i  = f_rd;
          n_reg_we = 1'b1;
        end

        OP_CAPTURE: begin
          cap_req_v = 1'b1;
          cap_tag_v = f_imm[4:0];
        end

        // ---------------- configuration --------------------------------
        OP_CFG: begin
          case (f_rs)
            3'd0: begin
              n_ss_en   = f_imm[7];
              n_ss_bank = f_imm[6:5];
              n_ss_base = f_imm[4:2];
              n_ss_wm1  = (f_imm[1:0] == 2'd3) ? 2'd2 : f_imm[1:0];
            end
            3'd1: begin
              n_bp_bank = f_imm[7:6];
              n_bp_bit  = f_imm[5:3];
              n_bp_inv  = f_imm[2];
            end
            3'd2: n_period[7:0]   = f_imm;
            3'd3: n_period[15:8]  = f_imm;
            3'd4: n_period[23:16] = f_imm;
            3'd5: n_period[31:24] = f_imm;
            3'd6: n_timeout       = f_imm;
            default: ; // SCRATCH: no architectural effect
          endcase
        end

        // ---------------- assist CSR (hybrid v2) -----------------------
        // LDAS rd, assist[id].reg[rs]: one cycle, combinational read.  An
        // empty FIFO sets nf_flag and leaves rd untouched (the PULLN rule);
        // like PULL, the load does not update Z/N.
        OP_LDAS: begin
          if (as_empty) begin
            n_nf = 1'b1;
          end else begin
            n_reg_v  = as_rdata;
            n_reg_i  = f_rd;
            n_reg_we = 1'b1;
            n_nf     = 1'b0;
          end
        end

        // STAS rd, assist[id].reg[rs]: the value is on as_wdata/as_wr; the
        // register bank latches it on this cycle's clock edge.  A write to a
        // DATA register is the data-path side effect (fold/push/queue).
        OP_STAS: ;

        // ASST assist[rs], command: as_cmd_en/as_cmd_id/as_cmd.
        OP_ASST: ;

        default: ; // undefined opcodes behave as NOP (matches model.py)
      endcase

      if (do_advance) begin
        n_pc          = (pc_r == LAST_PC) ? {ADDR_W{1'b0}} :
                                           (pc_r + ADDR_ONE);
        n_pc_we       = 1'b1;
        n_wait_active = 1'b0;   // model clears wait_active on any complete
      end
    end

    // ---- write buses ---------------------------------------------------
    wo_mask = p_uio_mask;
    wo_data = p_uio_val;
    uo_mask = p_uo_mask;
    uo_data = p_uo_val;
    oe_mask = p_oe_mask;
    oe_data = p_oe_val;
    od_mask = p_od_mask;
    od_data = p_od_val;
  end

  // ---------------------------------------------------------------------------
  // dbg_pc zero-extension (port is 6 bits, PC may be narrower)
  // ---------------------------------------------------------------------------
  always @* begin
    pc_status = 6'd0;
    pc_status[ADDR_W-1:0] = pc_r;
  end

  // ---------------------------------------------------------------------------
  // Host read port (combinational)
  // ---------------------------------------------------------------------------
  always @* begin
    if (hr_addr < 4'd8) begin
      hr_rdata_r = regs[hr_addr[2:0]];
    end else begin
      case (hr_addr)
        4'd8:    hr_rdata_r = period_r[7:0];
        4'd9:    hr_rdata_r = period_r[15:8];
        4'd10:   hr_rdata_r = period_r[23:16];
        4'd11:   hr_rdata_r = period_r[31:24];
        4'd12:   hr_rdata_r = {bp_bank_r, bp_bit_r, bp_inv_r, 2'b00};
        4'd13:   hr_rdata_r = {ss_en_r, ss_bank_r, ss_base_r, ss_wm1_r};
        4'd14:   hr_rdata_r = timeout_r;
        default: hr_rdata_r = {tof_r, nf_r, out_full_w, out_empty_w,
                               in_full_w, in_empty_w, halted_r, run};
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Sequential state update
  // ---------------------------------------------------------------------------
  integer i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fill_cnt     <= {ADDR_W{1'b0}};
      prog_ready_r <= 1'b0;
      prog_written <= {PROG_DEPTH{1'b0}};

      pc_r     <= {ADDR_W{1'b0}};
      halted_r <= 1'b1;
      error_r  <= 1'b0;
      z_r      <= 1'b0;
      c_r      <= 1'b0;
      n_r      <= 1'b0;

      period_r <= 32'd0;
      next_int_r  <= 32'd0;
      next_frac_r <= 8'd0;

      ss_en_r   <= 1'b0;
      ss_bank_r <= 2'd2;
      ss_base_r <= 3'd0;
      ss_wm1_r  <= 2'd0;

      bp_bank_r <= 2'd2;
      bp_bit_r  <= 3'd0;
      bp_inv_r  <= 1'b0;

      timeout_r     <= 8'h00;
      wait_active_r <= 1'b0;
      wait_left_r   <= 32'd0;
      ts_event_r    <= 32'd0;
      nf_r          <= 1'b0;
      tof_r         <= 1'b0;

      in_rd   <= {FIFO_AW{1'b0}};
      in_wr   <= {FIFO_AW{1'b0}};
      in_cnt  <= {FIFO_CW{1'b0}};
      out_rd  <= {FIFO_AW{1'b0}};
      out_wr  <= {FIFO_AW{1'b0}};
      out_cnt <= {FIFO_CW{1'b0}};

      run_q <= 1'b0;

      for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        in_mem[i]  <= 8'h00;
        out_mem[i] <= 8'h00;
      end
      for (i = 0; i < 8; i = i + 1)
        regs[i]    <= 8'h00;
    end else begin
      run_q <= run;

      // ---- reset fill: HALT every entry the host has not written ---------
      if (!prog_ready_r) begin
        if (!prog_written[fill_cnt])
          prog_mem[fill_cnt] <= HALT_WORD;
        if (fill_cnt == LAST_PC)
          prog_ready_r <= 1'b1;
        else
          fill_cnt <= fill_cnt + ADDR_ONE;
      end

      // Host program write: byte lanes merged into the current word.  A word
      // that neither the host nor the fill has touched yet is based on
      // HALT_WORD so untouched lanes are always defined (never X).
      if (host_prog_we && host_addr_ok) begin
        prog_mem[host_prog_addr[ADDR_W-1:0]] <=
            (host_base & ~host_bmask) | (host_prog_data & host_bmask);
        prog_written[host_prog_addr[ADDR_W-1:0]] <= 1'b1;
      end

      // ---- engine execution ----------------------------------------------
      if (exec_act) begin
        if (n_pc_we) pc_r <= n_pc;
        halted_r <= n_halted;
        error_r  <= n_error;

        if (n_reg_we) regs[n_reg_i] <= n_reg_v;
        if (n_zn_we) begin
          z_r <= n_z;
          n_r <= n_n;
        end
        if (n_c_we) c_r <= n_c;

        wait_active_r <= n_wait_active;
        wait_left_r   <= n_wait_left;
        ts_event_r    <= n_ts_event;
        nf_r          <= n_nf;
        tof_r         <= n_tof;

        period_r <= n_period;
        next_int_r  <= n_next_int;
        next_frac_r <= n_next_frac;

        ss_en_r   <= n_ss_en;
        ss_bank_r <= n_ss_bank;
        ss_base_r <= n_ss_base;
        ss_wm1_r  <= n_ss_wm1;

        bp_bank_r <= n_bp_bank;
        bp_bit_r  <= n_bp_bit;
        bp_inv_r  <= n_bp_inv;

        timeout_r <= n_timeout;
      end

      // ---- host register writes (win over engine writes, next cycle) ------
      if (hr_we) begin
        case (hr_addr)
          4'd0, 4'd1, 4'd2, 4'd3,
          4'd4, 4'd5, 4'd6, 4'd7: regs[hr_addr[2:0]] <= hr_wdata;
          4'd8:    period_r[7:0]   <= hr_wdata;
          4'd9:    period_r[15:8]  <= hr_wdata;
          4'd10:   period_r[23:16] <= hr_wdata;
          4'd11:   period_r[31:24] <= hr_wdata;
          4'd12: begin
            bp_bank_r <= hr_wdata[7:6];
            bp_bit_r  <= hr_wdata[5:3];
            bp_inv_r  <= hr_wdata[2];
          end
          4'd13: begin
            ss_en_r   <= hr_wdata[7];
            ss_bank_r <= hr_wdata[6:5];
            ss_base_r <= hr_wdata[4:2];
            ss_wm1_r  <= (hr_wdata[1:0] == 2'd3) ? 2'd2 : hr_wdata[1:0];
          end
          4'd14:   timeout_r <= hr_wdata;
          default: ; // addr 15 is read-only status
        endcase
      end

      // ---- run rising edge: restart --------------------------------------
      if (run && !run_q) begin
        halted_r      <= 1'b0;
        pc_r          <= {ADDR_W{1'b0}};
        wait_active_r <= 1'b0;
      end

      // ---- input FIFO (host push / engine pop) ---------------------------
      if (host_in_push && (in_cnt < FIFO_FULL)) begin
        in_mem[in_wr] <= host_in_data;
        in_wr         <= in_wr + 1'b1;
      end
      if (n_in_pop && (in_cnt > 0))
        in_rd <= in_rd + 1'b1;
      in_cnt <= in_cnt
              + {2'b00, (host_in_push && (in_cnt < FIFO_FULL))}
              - {2'b00, (n_in_pop && (in_cnt > 0))};

      // ---- output FIFO (engine push / host pop) --------------------------
      if (n_out_push) begin
        out_mem[out_wr] <= n_out_data;
        out_wr          <= out_wr + 1'b1;
      end
      if (host_out_pop && (out_cnt > 0))
        out_rd <= out_rd + 1'b1;
      out_cnt <= out_cnt
               + {2'b00, n_out_push}
               - {2'b00, (host_out_pop && (out_cnt > 0))};
    end
  end

`undef PW_WRITE

endmodule

`default_nettype wire
