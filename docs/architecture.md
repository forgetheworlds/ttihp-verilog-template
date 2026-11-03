# PROTEUS architecture

PROTEUS is a **software-defined pin engine**: three independent 24-bit-instruction
engines plus five protocol-agnostic assists, a 24-pin fabric with per-pin
direction / open-drain control, a global 32-bit cycle timebase, deadline pacing,
inter-engine barriers, and an edge timestamp capture unit.  Target: Tiny
Tapeout IHP `sg13cmos5l`, 6x4 tiles, 50 MHz.

This document is the implementation contract. `tools/isa.py` is the numeric
source of truth for opcodes; `tools/model.py` is the executable reference for
cycle-level behaviour. The build is hybrid v2 (`\`define PROTEUS_ENGINES 3`,
`PROTEUS_VERSION 8'h02` in `src/proteus_defs.vh`); the v1 four-engine design is
archived at `legacy/v1/`.

---

## 1. Why this shape

| | RP2040 PIO | TI PRU | PROTEUS (v2) |
|---|---|---|---|
| Instructions/cycle | 1 | 1 | 1 |
| Delays | 5-bit field on every insn | multi-cycle insns | 1-cycle insns + `WAITC` + deadline `PACE` |
| Data ops | 2 registers, no ALU | full ALU, 32-bit | 8x 8-bit regs + 8-bit ALU + flags |
| Pins | windows + side-set | memory-mapped, slow | per-instruction 8-bit masks + side-set |
| Fractional timing | instruction clock divider | none | 24.8 deadline pacer (no drift) |
| Event capture | none | none | 4-deep timestamped edge FIFO |
| Open-drain | manual OE | manual | per-pin OD mode + collision detect |
| Inter-engine sync | IRQ flags | shared memory | 4 hardware barriers + 8 IRQ lines |
| Protocol offload | none | none | 5 assists (CRC, FIFO, SHIFT, NRZI, MANCH) via 3 opcodes |

Design bets:
1. **Deterministic one-cycle ISA** makes timing analysable, so firmware timing
   can be proved mechanically (our simulator asserts cycle-exact deadlines).
2. **Deadline pacing** replaces PIO's clock divider: `next += period` in fixed
   point gives exact average rates with <=1 cycle jitter and no accumulated
   drift, even for irrational ratios such as 115200 baud from 48 MHz.
3. **Capture + timestamps** turns the chip into a protocol *analyser*, not just
   a generator. This is the "novel functionality" axis.
4. **Open-drain + collision** is required for real I2C arbitration and is a
   hardware primitive, not a firmware workaround.
5. **Assists carry the byte stream, not the protocol.** CRC/FIFO/SHIFT/NRZI/
   MANCH are data-path blocks selected by a CSR, so Ethernet MII fits a 32-word
   engine without committing a single protocol to gates. The rationale and the
   area trade are `docs/hybrid-architecture.md`: option B' predicted
   506,883.22 um2, and the shipped build measured 519,233.80 um2, i.e.
   12,350.58 um2 above it (`results/synth_v2_root.txt`).

---

## 2. Pin map (Tiny Tapeout)

| TT pin | function |
|---|---|
| `ui_in[0]` | host SPI `SCK` |
| `ui_in[1]` | host SPI `CS_N` |
| `ui_in[2]` | host SPI `MOSI` |
| `ui_in[7:3]` | fabric inputs (5) |
| `uo_out[0]` | host SPI `MISO` |
| `uo_out[1]` | IRQ output (masked IRQ status) |
| `uo_out[7:2]` | fabric outputs (6) |
| `uio[7:0]` | fabric bidirectional (8), per-pin OE + open-drain |

Logical pin banks used by the ISA:

| bank | value | pins | access |
|---|---|---|---|
| `UI` | 0 | logical 0..7 = `ui_in` | read-only |
| `UO` | 1 | logical 8..15 = `uo_out` | write, readback of driven value |
| `UIO` | 2 | logical 16..23 = `uio` | read = `uio_in`, write = `uio_out` + OE |

Host pins stay active until the host issues `HOST_DISABLE`; counted from the
RTL (`src/tt_um_proteus.v`, `fab_ui`/`fab_uo` and the `uo_q` write mask) that
leaves **19 fabric-usable pins while the host is active and 24 after release**
(`docs/pinout.md` §3). The assists own pins only through `PINCFG`: an assist's
TX/RX pins join the same fabric merge as an extra stage (§4).

---

## 3. Engine

Three instances (`0..2`), `PROG_DEPTH = 32` instructions each, 24-bit wide.

State per engine:
- 8 x 8-bit registers `r0..r7`
- flags `Z`, `C`, `N`
- `PC` (6 bit), `halted`, `error`
- 4-deep x 8-bit input FIFO (host -> engine) and output FIFO (engine -> host)
- side-set config: `en`, `bank`, `base`, `width` (1..3 pins)
- bit-pin shortcut config: `bank`, `bit`, `invert`
- pacing: `period` (24.8 fixed point), `next` (32-bit deadline + 8-bit fraction)
- wait state: `wait_active`, `wait_left`, `timeout_cfg`
- `ts_event` (cycle of last `WAITP` match / `CAPTURE`)
- `nf_flag` (non-blocking FIFO failure), `timeout_flag`

Execution model, per cycle:
1. If `run=0` or `halted=1`: no execution, no side effects.
2. Fetch `prog[pc]`; apply side-set bits **every cycle the instruction is in
   flight**, including stall cycles.
3. Execute. Multi-cycle instructions (`WAITC`, `WAITP`, `PACE`, blocked
   `PUSH`/`PULL`, `IRQWAIT`, `BAR`) hold `pc` and re-execute until the condition
   is met; all other instructions complete in one cycle and `pc += 1`.
4. Pin writes computed against the cycle-start pin snapshot; all three engines'
   writes are merged by priority (engine 0 lowest priority, engine 2 highest),
   then the assist stage, then the host (§4).

`HALT` stops the engine (`run` cleared) and does not advance.

### 3.1 Assist access (new in v2)

`LDAS` (0x4E), `STAS` (0x4F) and `ASST` (0x50) give each engine one-cycle
access to the five assists' register files:

| op | fields | effect |
|---|---|---|
| `LDAS` | `rd` dest, `rs` register index, `imm8[2:0]` assist id | combinational read into `rd`; an empty source sets `nf_flag` and leaves `rd` unchanged |
| `STAS` | `rd` source, `rs` register index, `imm8[2:0]` assist id | write; a write to `DATA` (reg 0) is the data-path side effect (fold a CRC byte, push a FIFO byte) |
| `ASST` | `rs` assist id, `imm8` command | command strobe (reset/start/stop/arm/sync/eop/flush/latch, per-assist mapping) |

No new instruction format: all three use `op/rd/rs/imm8`. Arbitration is the
pin-merge rule: the highest engine index wins a same-cycle write or command
collision, and a host CSR write wins over every engine. Reads have one port per
engine and never conflict. The assist register map is §6.2; opcode encodings and
per-assist semantics are `docs/isa.md` §2.6 and §6.1.

### 3.2 Timing semantics
- `WAITC n` occupies `max(n,1)` cycles (the issue cycle counts as the first).
- `PACE`: completes when `cycle >= next[31:8]`, then `next += period`.  A
  `PACERST` sets `next = {cycle, 8'b0}`.  Consecutive `PACE` completions are
  exactly `period` cycles apart on average, with no drift; the integer part is
  a full 32 bits, so the horizon is 2^32 cycles.
- `WAITP bank, mask, level`: completes when `(pins(mask) == mask)` for level=1
  or `(pins(mask) == 0)` for level=0; records `ts_event = cycle` on match.
- `IRQWAIT n`: completes when global IRQ bit `n` is set.
- `BAR id` (0..3): arrives at barrier `id` and completes once every engine with
  `run=1` has arrived; the barrier then clears in that cycle.
- `PUSH`/`PULL` block on full/empty FIFO; `PUSHN`/`PULLN` set `nf_flag` and
  continue.

### 3.3 ALU
8-bit `ADD/SUB/ADC/SBC/AND/OR/XOR/CMP/SHL/SHR/ASR/ROL/ROR/NOT/NEG/INC/DEC` plus
immediate forms.  `C` is carry/borrow; `Z` is result==0; `N` is bit 7.
Shift counts are taken modulo 8 (`rs[2:0]`).

---

## 4. Pin fabric and assist ownership

Registers: `uo_q[7:0]`, `uio_q[7:0]`, `oe_q[7:0]`, `od_q[7:0]`.

Per-engine write bus per bank: `{data[7:0], mask[7:0]}`. Merge:

```
engines 0..2 : reg = (reg & ~mask) | (data & mask)
assist stage : reg = (reg & ~as_mask) | (as_data & as_mask)
               od  = od & ~as_od_mask            // assist pins are push-pull
host         : a write to 0x0520..0x0523 latches the register last
```

The assist stage is unconditional in the RTL: `proteus_assist` resets every
`PINCFG` to 0, so with `en = 0` the stage is the identity and the engines own
the pads exactly as before (the differential test relies on this:
`v2/results/v2_diff_formal.md` §1.1).

Pin ownership priority, highest first: **host register write > assist (where
`PINCFG.en = 1`) > engine index 2 > 1 > 0**. Assist receive pins are sampled
from the raw pads (`uio_in`/`ui_in`), never from the merged output, so an assist
sees the bus.

Effective drive: `uio_oe_eff = oe_q & ~(od_q & uio_q)`; a pin with OE=0 or
released by open-drain is high-Z (input). Collision (sticky, host-clearable):
for `uio` bits with `oe_eff=1`, if `uio_in != uio_q` (push-pull) then collision;
for open-drain driven-low bits if `uio_in != 0` then collision.

Any pin write to `UIO` also sets `oe_q` for the written bits (auto direction),
unless the instruction is `DIRC`.

---

## 5. Capture unit

- `CAP_EN[7:0]` selects watched `uio` pins; any edge pushes an event.
- Event = `{cycle[31:0], pin[3:0], level}` into a **4-entry** FIFO
  (`CAP_DEPTH = 4` in `src/tt_um_proteus.v`), plus `overflow` sticky flag.
- `CAPTURE <tag>` from any engine pushes a software event with `pin = tag[3:0]`,
  `level = tag[4]`.
- Host reads a snapshot of the head entry (`CAP_TS0..3`, `CAP_INFO`) and writes
  `CAP_POP` to advance. `CAP_STATUS` is `{3'b0, overflow, count[3:0]}`, and the
  count can reach `CAP_DEPTH` because it carries one extra bit.

---

## 6. Host interface

SPI mode 0, MSB first, `SCK <= clk/8` (the synchroniser needs several clk per
SCK edge).  `CS_N` frames a command; the command byte is followed by data bytes.

| cmd | name | payload |
|---|---|---|
| 0x01 | WRITE_INC | byte* -> PTR, PTR++ |
| 0x02 | READ_INC | byte* <- PTR, PTR++ |
| 0x03 | SET_PTR_LO | 1 byte -> PTR[7:0] |
| 0x04 | SET_PTR_HI | 1 byte -> PTR[15:8] |
| 0x05 | WRITE_ADDR | 2 bytes LE addr, then data bytes (auto-inc) |
| 0x06 | READ_ADDR | 2 bytes LE addr, then read bytes (auto-inc) |
| 0x07 | PING | reads 0x50 |
| 0x08 | SOFT_RESET | resets chip |
| 0x09 | HOST_DISABLE | release host pins until reset |
| 0x00 | NOP | - |

For read commands the chip shifts out `reg_rdata` for the current address on
`MISO` while the host clocks dummy bytes.

**FIFO ports are one byte per frame.** A `WRITE_INC`/`WRITE_ADDR` burst that
starts at `IN_FIFO` (`+0x10`) auto-increments into `OUT_FIFO` (`+0x11`),
`BITPIN` (`+0x12`) and `SIDECFG` (`+0x13`): all but the first byte are lost and
the side-set configuration is overwritten. Push one byte per frame and poll
`E_STATUS.in_full` (`+0x0`, bit 3) before each push; read `OUT_FIFO` one byte per
frame as well. This is a property of the flat auto-increment pointer, not of the
FIFO itself.

**CS_N hold.** The write/read strobe is registered one `clk` after the 8th bit
of a byte, so `CS_N` must stay low for at least 2 `clk` cycles after the last
SCK rising edge of a frame (the drivers use >=6). Releasing CS_N on the same
clock as the final sampling edge still lands the write correctly, but a formal
property that asserts "no strobe while CS_N is high" would flag that last byte;
the interface requirement above is the contract.

### 6.1 Register map (16-bit)

```
0x0000 R  ID0  = 0x50 ('P')
0x0001 R  ID1  = 0x52 ('R')
0x0002 R  VERSION = 0x02        (hybrid v2; v1 read 0x01)
0x0003 R  STATUS  [0] any_run [1] irq [2] cap_ovf [3] collision [4] any_error
0x0004 RW RUN      bit e = engine e run (3 bits; bit 3 ignored)
0x0005 W  HALT     bit e = clear run
0x0006 W  SOFT_RESET
0x0007 RW HOST_EN  bit0 = host pins driven (reset = 1)
0x0008 R  IRQ_STATUS
0x0009 RW IRQ_ENABLE
0x000A W  IRQ_ACK
0x000B..0x000E R CYCLE0..3 (32-bit, LE bytes)
0x0010 + 0x20*e: engine e window (0x0010..0x006F, e = 0..2), offset = (addr-0x0010)[4:0]
    +0x0 R   E_STATUS [0]run [1]halted [2]in_empty [3]in_full [4]out_empty [5]out_full [6]nf [7]timeout
    +0x1 R   E_PC
    +0x2 R   E_FLAGS reads 0 (flags are not exported; use branches)
    +0x3 R   E_ERROR
    +0x4..B RW regs r0..r7
    +0xC..F RW period bytes 0..3
    +0x10 RW IN_FIFO  (write pushes byte, read returns 0)
    +0x11 R  OUT_FIFO (read pops byte)
    +0x12 RW bitpin cfg  (same encoding as CFG field 1)
    +0x13 RW side cfg    (same encoding as CFG field 0)
    +0x14 RW timeout cfg
    +0x15 R  reserved (0)
0x0100 + e*0x100 + i*4 + b: program byte b of instruction i (b=0..2, e=0..2)
0x0500 RW CAP_EN
0x0501 R  CAP_STATUS {3'b0, [4] overflow, [3:0] count}
0x0502 R  CAP_TS0
0x0503 R  CAP_TS1
0x0504 R  CAP_TS2
0x0505 R  CAP_TS3
0x0506 R  CAP_INFO [3:0] pin, [4] level
0x0507 W  CAP_POP
0x0510 R  COLLISION (sticky)
0x0511 W  COLLISION_CLR
0x0520 RW UO_OUT
0x0521 RW UIO_OUT
0x0522 RW UIO_OE
0x0523 RW UIO_OD
0x0530 R  ASSERT_INFO [5:4] engine, [3:0] pc (last failed ASSERT)
0x0600 + 0x10*id + reg: assist CSR bank (id 0..4, reg 0..7, +8 = PINCFG, host only)
```

Program window ends at `0x03FF`. `0x0400` is not mapped: a write there is
dropped and a read returns 0 (`PROTEUS_PM_END` in `src/proteus_defs.vh`; the
regression is `sim/test_protocols.py::proteus_v2_map`). The assist window ends
at `0x064F`; `0x0650` is outside it.

### 6.2 Assist CSR map

Host view `0x0600 + 0x10*id + reg`; engine view via `LDAS`/`STAS` with the same
`reg` index. `PINCFG` at `+8` is host-only so the engine view stays 8 registers.
Full per-register semantics live in `src/proteus_assist.v` (the normative
comment block) and `docs/programming.md` §2.6; the summary:

| id | assist | function | area, shipped hierarchy (`results/synth_v2_root.txt`) |
|---|---|---|---|
| 0 | `CRC` (id 0) | 5..32-bit CRC, runtime init/poly/xorout/reflection/bit order, 8 clocks per byte | 21,152.96 um2 |
| 1 | `FIFO` | 16 x 8 byte stream FIFO, drain port, burst counter + IRQ | 12,423.12 um2 |
| 2 | `SHIFT` | 32-bit bidirectional shift register, byte push/pop, stuff hook | 9,559.51 um2 |
| 3 | `NRZI` | USB LS encoder/decoder: stuffing, SYNC window, EOP/SE0, runtime `DIV` | 10,730.06 um2 (enc 4,071.51 + dec 6,658.55) |
| 4 | `MANCH` | 10BASE-T PCS encoder + 4x/8x oversampled receiver (elaboration-time `HALF_DIV`/`OS`) | 5,989.26 um2 (enc 2,912.07 + dec 3,077.18) |

---

## 7. RTL module split

```
src/tt_um_proteus.v   top: pins, host SPI instance, 3 engines, assist bank,
                           pin merge (engines -> assists -> host), capture,
                           barriers, IRQ, cycle counter, address decode
src/proteus_engine.v  one engine: program RAM, decode, ALU, FIFOs, pacing,
                           side-set, barriers, IRQ, host register port, assist port
src/proteus_host.v    SPI slave + command FSM + pointer
src/proteus_assist.v  the five assists behind one CSR interface + PINCFG ownership
src/crc_bit.v         bit-serial configurable CRC
src/assist_fifo.v     16 x 8 stream FIFO
src/shiftreg32.v      32-bit shift register
src/nrzi_enc.v        USB LS NRZI encoder + stuffer + EOP
src/nrzi_dec.v        USB LS NRZI decoder + unstuffer + SYNC/EOP
src/manchester_enc.v  802.3 Manchester encoder
src/manchester_dec.v  4x/8x oversampling Manchester receiver
src/proteus_defs.vh   parameters, opcode localparams, register map constants
```

That is 12 source files, and `info.yaml` `source_files` lists all of them in
dependency order.

### proteus_engine ports (assist port added in v2)

```verilog
module proteus_engine #(parameter PROG_DEPTH=32, parameter ENG_ID=0,
                        parameter FIFO_DEPTH=4) (
  input  wire        clk, rst_n,
  input  wire        run,
  // program memory host port
  input  wire        host_prog_we,
  input  wire [2:0]  host_prog_be,
  input  wire [5:0]  host_prog_addr,
  input  wire [23:0] host_prog_data,
  output wire [23:0] host_prog_rdata,
  // pin snapshot
  input  wire [7:0]  pin_ui, pin_uo, pin_uio,
  // pin write buses
  output reg  [7:0]  wo_data, wo_mask,
  output reg  [7:0]  uo_data, uo_mask,
  output reg  [7:0]  oe_data, oe_mask,
  output reg  [7:0]  od_data, od_mask,
  // time / sync
  input  wire [31:0] cycle,
  input  wire [7:0]  irq,
  output wire [7:0]  irq_set, irq_clr,
  input  wire [3:0]  run_mask,
  input  wire        bar_go,
  output wire        bar_req,
  output wire [1:0]  bar_id,
  // host register / FIFO port
  input  wire        hr_we,
  input  wire [3:0]  hr_addr,
  input  wire [7:0]  hr_wdata,
  output wire [7:0]  hr_rdata,
  input  wire        host_in_push,
  input  wire [7:0]  host_in_data,
  input  wire        host_out_pop,
  output wire [7:0]  host_out_data,
  // capture
  output wire        cap_req,
  output wire [4:0]  cap_tag,
  // assist CSR port (LDAS / STAS / ASST)
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
  output wire        halted, error,
  output wire [5:0]  dbg_pc,
  output wire        prog_ready,      // program-RAM fill complete
  output wire        halt_exec        // HALT is executing: retire RUN this cycle
);
```

`run_mask` is 4 bits in the frozen engine interface; the top drives
`{1'b0, run_mask[2:0]}` so a v2 build cannot run engine 3.

### proteus_host ports

```verilog
module proteus_host (
  input  wire clk, rst_n,
  input  wire sck, cs_n, mosi,
  output wire miso,
  output reg        reg_we,
  output reg [15:0] reg_addr,
  output reg [7:0]  reg_wdata,
  output reg        reg_re,
  output reg [15:0] reg_raddr,
  input  wire [7:0] reg_rdata,
  output reg        host_en,
  output reg        soft_reset
);
```

---

## 8. Verification strategy

1. `tools/model.py` cycle model is co-simulated against the RTL for the same
   programs (aligned at the run strobe): `sim/test_diff.py`, 209 programs,
   16,122 compared cycles, 0 mismatches (`v2/results/v2_diff_formal.md`).
2. cocotb protocol tests drive the real host SPI, load firmware, then decode the
   pin traffic with independent Python protocol models: `sim/test_protocols.py`,
   6 tests / 236 checks (`v2/results/v2_verify.md`).
3. Directed RTL benches: unit benches for each assist plus `tb_csr` (37 checks),
   `tb_top_smoke` (19 checks), `engine_smoke` (237 checks) and `top_e2e`
   (400 checks), all in `tb/run.sh`.
4. Formal (SymbiYosys): engine properties E1-E8/E10/E11 plus the E0
   expected-fail control and E9 covers, same depths as v1
   (`v2/formal/`, `v2/results/formal_summary_v2.txt`). The top T1-T7 suite has
   not been ported; its v1 evidence is `results/formal_summary.txt`.
5. Mutation testing of the RTL benches: 99 mutants, 95 killed (96.0 %), the 4
   survivors shown equivalent (`v2/results/v2_mutation.md`).
6. Synthesis with the IHP PDK: 519,233.80 um2 flat / 36,343 cells = 57.54 % of
   row area, 95.90 % of the 60 % placement budget (22,216.40 um2 spare);
   hierarchical sum 538,016.13 um2 = 59.62 % (`results/synth_v2_root.txt`
   lines 47230 / 47202 / 19254). The superseded 497,927.19 um2 record is
   discussed in `docs/verification.md` §2.9. The official
   LibreLane GDS gate runs on x86_64 GitHub (`gds.yaml`), not locally.
