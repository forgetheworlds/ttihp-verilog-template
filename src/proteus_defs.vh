// ===========================================================================
// proteus_defs.vh -- PROTEUS shared numeric definitions
//
// DECISION: Verilog-2005 has no compilation-unit ("package") scope, so shared
// constants cannot be file-scope localparams.  This file therefore exports
// `define macros (namespaced PROTEUS_*) that can be used from any module and
// any number of times without redeclaration errors.  Include it once per file.
//
// Numeric truth: tools/isa.py (opcodes/fields), docs/architecture.md sec. 6
// (host command set and register map).
// ===========================================================================

`ifndef PROTEUS_DEFS_VH
`define PROTEUS_DEFS_VH

// ---------------------------------------------------------------- geometry
`define PROTEUS_PROG_DEPTH   32      // default build depth (area ruling);
                                      // tt_um_proteus/proteus_engine take
                                      // PROG_DEPTH as a parameter (24/32/48)
`define PROTEUS_ENGINES      3       // hybrid build: one lane traded for the
                                      // five protocol assists (docs/hybrid-
                                      // architecture.md section 3, option B')
`define PROTEUS_PC_BITS      6
`define PROTEUS_INSN_BITS    24
`define PROTEUS_FIFO_DEPTH   4       // engine in/out FIFO parameter default
`define PROTEUS_CAP_DEPTH    4       // top-level capture FIFO parameter default

// ------------------------------------------------------------ identity regs
`define PROTEUS_ID0          8'h50    // 'P'
`define PROTEUS_ID1          8'h52    // 'R'
`define PROTEUS_VERSION      8'h02    // v2 = hybrid (3 engines + assists)

// --------------------------------------------------------- SPI command bytes
`define PROTEUS_CMD_NOP           8'h00
`define PROTEUS_CMD_WRITE_INC     8'h01
`define PROTEUS_CMD_READ_INC      8'h02
`define PROTEUS_CMD_SET_PTR_LO    8'h03
`define PROTEUS_CMD_SET_PTR_HI    8'h04
`define PROTEUS_CMD_WRITE_ADDR    8'h05
`define PROTEUS_CMD_READ_ADDR     8'h06
`define PROTEUS_CMD_PING          8'h07
`define PROTEUS_CMD_SOFT_RESET    8'h08
`define PROTEUS_CMD_HOST_DISABLE  8'h09

// -------------------------------------------------------------- global regs
`define PROTEUS_RA_ID0        16'h0000
`define PROTEUS_RA_ID1        16'h0001
`define PROTEUS_RA_VERSION    16'h0002
`define PROTEUS_RA_STATUS     16'h0003
`define PROTEUS_RA_RUN        16'h0004
`define PROTEUS_RA_HALT       16'h0005
`define PROTEUS_RA_SOFT_RESET 16'h0006
`define PROTEUS_RA_HOST_EN    16'h0007
`define PROTEUS_RA_IRQ_STATUS 16'h0008
`define PROTEUS_RA_IRQ_ENABLE 16'h0009
`define PROTEUS_RA_IRQ_ACK    16'h000A
`define PROTEUS_RA_CYCLE0     16'h000B
`define PROTEUS_RA_CYCLE1     16'h000C
`define PROTEUS_RA_CYCLE2     16'h000D
`define PROTEUS_RA_CYCLE3     16'h000E

// ------------------------------------------------------- engine reg windows
// NOTE (window geometry): the map defines offsets 0x00..0x15, which do not
// fit a 0x10-byte stride (base+0x10 would be the next engine's base).  A 0x20
// stride is the only geometry where every documented register is reachable
// exactly once; see the decision comment in tt_um_proteus.v.
`define PROTEUS_EW_BASE       16'h0010   // + 0x20*engine, engines 0..2
`define PROTEUS_EW_STRIDE     16'h0020
`define PROTEUS_EW_END        16'h006F   // 0x0010 + 0x20*3 - 1 (v1: 0x008F)
// window offsets (5 bits)
`define PROTEUS_EO_STATUS     5'h00
`define PROTEUS_EO_PC         5'h01
`define PROTEUS_EO_FLAGS      5'h02
`define PROTEUS_EO_ERROR      5'h03
`define PROTEUS_EO_R0         5'h04     // .. 5'h0B = r7
`define PROTEUS_EO_PERIOD0    5'h0C     // .. 5'h0F = period bytes 0..3
`define PROTEUS_EO_IN_FIFO    5'h10
`define PROTEUS_EO_OUT_FIFO   5'h11
`define PROTEUS_EO_BITPIN     5'h12
`define PROTEUS_EO_SIDECFG    5'h13
`define PROTEUS_EO_TIMEOUT    5'h14
`define PROTEUS_EO_RESERVED   5'h15

// ------------------------------------------------------------ program memory
`define PROTEUS_PM_BASE       16'h0100   // 0x0100 + e*0x100 + i*4 + b, e < 3
`define PROTEUS_PM_STRIDE_E   16'h0100
`define PROTEUS_PM_END        16'h03FF   // 0x0100 + 0x100*3 - 1 (v1: 0x04FF)
                                          // (was 0x02FF: engine 2's page
                                          //  0x0300..0x03FF was unreachable)

// ------------------------------------------------------------- assist window
// Hybrid v2 CSR window: 5 assists x 8 registers, 0x0600 + 0x10*id + reg.
// Register 8 of each 0x10 stride is the host-only PINCFG register (bank/base/
// width); the engine view is exactly the 8 registers of docs section 5.3.
`define PROTEUS_AS_BASE       16'h0600
`define PROTEUS_AS_STRIDE     16'h0010
`define PROTEUS_AS_END        16'h064F
`define PROTEUS_AS_NID        3'd5
`define PROTEUS_AS_PINCFG     4'h8

// assist ids (imm8[2:0] / rs field of LDAS, STAS, ASST)
`define PROTEUS_AS_CRC        3'd0
`define PROTEUS_AS_FIFO       3'd1
`define PROTEUS_AS_SHIFT      3'd2
`define PROTEUS_AS_NRZI       3'd3
`define PROTEUS_AS_MANCH      3'd4

// ----------------------------------------------------------- capture/collision
`define PROTEUS_RA_CAP_EN     16'h0500
`define PROTEUS_RA_CAP_STATUS 16'h0501
`define PROTEUS_RA_CAP_TS0    16'h0502
`define PROTEUS_RA_CAP_TS1    16'h0503
`define PROTEUS_RA_CAP_TS2    16'h0504
`define PROTEUS_RA_CAP_TS3    16'h0505
`define PROTEUS_RA_CAP_INFO   16'h0506
`define PROTEUS_RA_CAP_POP    16'h0507
`define PROTEUS_RA_COLLISION  16'h0510
`define PROTEUS_RA_COLL_CLR   16'h0511
`define PROTEUS_RA_UO_OUT     16'h0520
`define PROTEUS_RA_UIO_OUT    16'h0521
`define PROTEUS_RA_UIO_OE     16'h0522
`define PROTEUS_RA_UIO_OD     16'h0523
`define PROTEUS_RA_ASSERT     16'h0530

// --------------------------------------------------------------- pin banks
`define PROTEUS_BANK_UI       2'd0
`define PROTEUS_BANK_UO       2'd1
`define PROTEUS_BANK_UIO      2'd2

// ------------------------------------------------------- instruction format
// 24-bit word: [23:17] op(7) [16:14] rd(3) [13:11] rs(3) [10:3] imm8 [2:0] ss(3)
// (orchestrator-mandated uniform layout; matches tools/isa.py OP_/RD_/RS_/IMM_/SS_)
`define PROTEUS_OP_SHIFT      17
`define PROTEUS_OP_BITS       7
`define PROTEUS_OP_MASK       7'h7f
`define PROTEUS_RD_SHIFT      14
`define PROTEUS_RS_SHIFT      11
`define PROTEUS_IMM_SHIFT     3
`define PROTEUS_SS_SHIFT      0
`define PROTEUS_SS_MASK       3'h7

// --------------------------------------------------------------- opcodes
// (tools/isa.py OPS: name -> code; formats are in the assembler)
`define PROTEUS_OP_LDI        7'h00
`define PROTEUS_OP_ADDI       7'h01
`define PROTEUS_OP_SUBI       7'h02
`define PROTEUS_OP_ANDI       7'h03
`define PROTEUS_OP_ORI        7'h04
`define PROTEUS_OP_XORI       7'h05
`define PROTEUS_OP_CMPI       7'h06
`define PROTEUS_OP_SHLI       7'h07
`define PROTEUS_OP_SHRI       7'h08
`define PROTEUS_OP_ASRI       7'h09
`define PROTEUS_OP_ROLI       7'h0a
`define PROTEUS_OP_RORI       7'h0b
`define PROTEUS_OP_ADCI       7'h0c
`define PROTEUS_OP_SBCI       7'h0d
`define PROTEUS_OP_MOVI       7'h0e

`define PROTEUS_OP_MOV        7'h10
`define PROTEUS_OP_ADD        7'h11
`define PROTEUS_OP_SUB        7'h12
`define PROTEUS_OP_AND        7'h13
`define PROTEUS_OP_OR         7'h14
`define PROTEUS_OP_XOR        7'h15
`define PROTEUS_OP_CMP        7'h16
`define PROTEUS_OP_SHL        7'h17
`define PROTEUS_OP_SHR        7'h18
`define PROTEUS_OP_ASR        7'h19
`define PROTEUS_OP_ROL        7'h1a
`define PROTEUS_OP_ROR        7'h1b
`define PROTEUS_OP_NOT        7'h1c
`define PROTEUS_OP_NEG        7'h1d
`define PROTEUS_OP_INC        7'h1e
`define PROTEUS_OP_DEC        7'h1f
`define PROTEUS_OP_ADC        7'h20
`define PROTEUS_OP_SBC        7'h21

`define PROTEUS_OP_SETP       7'h22
`define PROTEUS_OP_CLRP       7'h23
`define PROTEUS_OP_TOGP       7'h24
`define PROTEUS_OP_OUTP       7'h25
`define PROTEUS_OP_INPR       7'h26
`define PROTEUS_OP_DIRS       7'h27
`define PROTEUS_OP_DIRC       7'h28
`define PROTEUS_OP_ODSET      7'h29
`define PROTEUS_OP_ODCLR      7'h2a
`define PROTEUS_OP_OUTBIT     7'h2b
`define PROTEUS_OP_INBIT      7'h2c
`define PROTEUS_OP_WAITP      7'h2d

`define PROTEUS_OP_JMP        7'h30
`define PROTEUS_OP_JZ         7'h31
`define PROTEUS_OP_JNZ        7'h32
`define PROTEUS_OP_JC         7'h33
`define PROTEUS_OP_JNC        7'h34
`define PROTEUS_OP_JN         7'h35
`define PROTEUS_OP_DJNZ       7'h36
`define PROTEUS_OP_HALT       7'h38
`define PROTEUS_OP_NOP        7'h39
`define PROTEUS_OP_WAITC      7'h3a
`define PROTEUS_OP_PACE       7'h3b
`define PROTEUS_OP_PACERST    7'h3c
`define PROTEUS_OP_ASSERT     7'h3e

`define PROTEUS_OP_PUSH       7'h40
`define PROTEUS_OP_PULL       7'h41
`define PROTEUS_OP_PUSHN      7'h42
`define PROTEUS_OP_PULLN      7'h43
`define PROTEUS_OP_IRQSET     7'h44
`define PROTEUS_OP_IRQCLR     7'h45
`define PROTEUS_OP_IRQWAIT    7'h46
`define PROTEUS_OP_BAR        7'h47
`define PROTEUS_OP_TSLO       7'h48
`define PROTEUS_OP_TSHI       7'h49
`define PROTEUS_OP_MEASLO     7'h4a
`define PROTEUS_OP_MEASHI     7'h4b
`define PROTEUS_OP_CAPTURE    7'h4c
`define PROTEUS_OP_CFG        7'h4d
// hybrid v2: assist CSR access (docs/hybrid-architecture.md 5.2)
`define PROTEUS_OP_LDAS       7'h4e
`define PROTEUS_OP_STAS       7'h4f
`define PROTEUS_OP_ASST       7'h50

// ------------------------------------------------------------ CFG field ids
`define PROTEUS_CFG_SIDE      3'd0    // [7]=en [6:5]=bank [4:2]=base [1:0]=width-1 (1..3)
`define PROTEUS_CFG_BITPIN    3'd1
`define PROTEUS_CFG_PERIOD0   3'd2
`define PROTEUS_CFG_PERIOD1   3'd3
`define PROTEUS_CFG_PERIOD2   3'd4
`define PROTEUS_CFG_PERIOD3   3'd5
`define PROTEUS_CFG_TIMEOUT   3'd6
`define PROTEUS_CFG_SCRATCH   3'd7

`endif // PROTEUS_DEFS_VH
