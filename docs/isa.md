# PROTEUS ISA v2

The PROTEUS engines execute 24-bit instructions, one per `clk` cycle, with a
fixed 1-cycle datapath. Timing is produced by three explicit primitives
(`WAITC`, `PACE`, `WAITP`) instead of instruction delays, so every cycle of a
program is accounted for.

`tools/isa.py` is the numeric source of truth; this document is its prose
mirror. `tools/model.py` is the executable reference (the RTL must match it).

The hybrid v2 build executes **75 opcodes**: the 72 of v1 plus three assist
access instructions (`LDAS`, `STAS`, `ASST`) added in v2. `tools/isa.py`
asserts the count:

```
$ python3 -c "import sys;sys.path.insert(0,'tools');import isa;print(len(isa.OPS))"
75
```

---

## 1. Instruction word

```
 23      17 16  14 13  11 10        3 2   0
+---------+------+------+------------+-----+
|   op    |  rd  |  rs  |    imm8    | ss  |
|  7 bits | 3 b  | 3 b  |   8 bits   | 3 b |
+---------+------+------+------------+-----+
```

| field | bits | use |
|---|---|---|
| `op`  | 23:17 | opcode (7 bits; 75 defined, 0x00..0x50) |
| `rd`  | 16:14 | destination register, jump condition, or value register |
| `rs`  | 13:11 | source register, pin bank, CFG field, assist id, or WAITP level |
| `imm8`| 10:3  | immediate, pin mask, jump target, WAITC low byte, CFG value, capture tag, assist id or command |
| `ss`  | 2:0   | side-set value, driven on **every** cycle the instruction is in flight |

`PROG_DEPTH = 32` instructions per engine by default (a Verilog parameter; the
assembler accepts any depth up to 64 with `--depth`). Jump targets are
`imm[4:0]`, i.e. `imm & (PROG_DEPTH-1)`.

> **Revision note.** v1 placed `op` in `[23:18]` (6 bits) while assigning
> opcodes 0x40..0x4D to the system group; those words do not fit in 24 bits.
> Revision 2 widens `op` to 7 bits and moves the other fields down by one.
> **All opcode numbers are unchanged**; only the field positions moved.

The engine count is a build parameter, not an ISA field: the hybrid build has
three engines (`0..2`, `\`define PROTEUS_ENGINES 3`). Pin-bank encodings are
unchanged.

---

## 2. Opcodes

`r` = register `r0..r7`; `i` = immediate (label/equate allowed); `b` = pin bank;
`f` = CFG field name; `t` = jump target; `a` = assist id. Format names match
`isa.OPERANDS`.

### 2.1 ALU immediate — `rd = rd <op> imm8` (format `imm`, operands `r, i`)

| op | mnemonic | semantics | flags |
|---|---|---|---|
| 0x00 | `LDI` | `rd = imm` | Z,N |
| 0x01 | `ADDI` | `rd = rd + imm` | Z,N,C=carry |
| 0x02 | `SUBI` | `rd = rd - imm` | Z,N,C=borrow |
| 0x03 | `ANDI` | `rd = rd & imm` | Z,N |
| 0x04 | `ORI` | `rd = rd \| imm` | Z,N |
| 0x05 | `XORI` | `rd = rd ^ imm` | Z,N |
| 0x06 | `CMPI` | compare only (no write) | Z,N,C=borrow |
| 0x07 | `SHLI` | `rd <<= imm[2:0]` | Z,N,C |
| 0x08 | `SHRI` | `rd >>= imm[2:0]` (logical) | Z,N,C |
| 0x09 | `ASRI` | `rd >>= imm[2:0]` (arithmetic) | Z,N,C |
| 0x0A | `ROLI` | rotate left `imm[2:0]` | Z,N,C |
| 0x0B | `RORI` | rotate right `imm[2:0]` | Z,N,C |
| 0x0C | `ADCI` | `rd = rd + imm + C` | Z,N,C=carry |
| 0x0D | `SBCI` | `rd = rd - imm - C` | Z,N,C=borrow |
| 0x0E | `MOVI` | alias of `LDI` (distinct opcode for disassembly) | Z,N |

### 2.2 ALU register — `rd = rd <op> rs` (format `reg`, operands `r, r`)

| op | mnemonic | semantics | flags |
|---|---|---|---|
| 0x10 | `MOV` | `rd = rs` | Z,N |
| 0x11 | `ADD` | `rd += rs` | Z,N,C |
| 0x12 | `SUB` | `rd -= rs` | Z,N,C=borrow |
| 0x13 | `AND` | `rd &= rs` | Z,N |
| 0x14 | `OR`  | `rd \|= rs` | Z,N |
| 0x15 | `XOR` | `rd ^= rs` | Z,N |
| 0x16 | `CMP` | compare only | Z,N,C=borrow |
| 0x17 | `SHL` | `rd <<= rs[2:0]` | Z,N,C |
| 0x18 | `SHR` | `rd >>= rs[2:0]` | Z,N,C |
| 0x19 | `ASR` | arithmetic `rd >>= rs[2:0]` | Z,N,C |
| 0x1A | `ROL` | rotate left `rs[2:0]` | Z,N,C |
| 0x1B | `ROR` | rotate right `rs[2:0]` | Z,N,C |
| 0x1C | `NOT` | `rd = ~rd` | Z,N |
| 0x1D | `NEG` | `rd = 0 - rd` | Z,N,C=borrow |
| 0x1E | `INC` | `rd += 1` | Z,N,C |
| 0x1F | `DEC` | `rd -= 1` | Z,N,C=borrow |
| 0x20 | `ADC` | `rd += rs + C` | Z,N,C |
| 0x21 | `SBC` | `rd -= rs + C` | Z,N,C=borrow |

### 2.3 Pin operations (format `pin`; bank in `rs[1:0]`, mask in `imm`)

| op | mnemonic | operands | semantics |
|---|---|---|---|
| 0x22 | `SETP` | `b, i` | write `1` to the masked pins |
| 0x23 | `CLRP` | `b, i` | write `0` to the masked pins |
| 0x24 | `TOGP` | `b, i` | invert the masked pins |
| 0x25 | `OUTP` | `b, i, r` | write `rd` to the masked pins |
| 0x26 | `INPR` | `b, i, r` | `rd = pins & mask`, flags from `rd` |
| 0x27 | `DIRS` | `b, i` | set UIO output-enable bits (no auto-OE) |
| 0x28 | `DIRC` | `b, i` | clear UIO output-enable bits (no auto-OE) |
| 0x29 | `ODSET` | `b, i` | set UIO open-drain bits |
| 0x2A | `ODCLR` | `b, i` | clear UIO open-drain bits |
| 0x2B | `OUTBIT` | `r` | drive the CFG BITPIN pad from `rd[0]` |
| 0x2C | `INBIT` | `r` | `rd = BITPIN pad`, flags from `rd` |
| 0x2D | `WAITP` | `b, i, i` | block until `pins & mask == mask` (level 1) or `== 0` (level 0) |

All pin instructions complete in one cycle; a `WAITP` that does not match
stalls (see §3.3). Writes to the `UI` bank are ignored (read-only).

### 2.4 Control

| op | mnemonic | operands | semantics | cycles |
|---|---|---|---|---|
| 0x30 | `JMP` | `t` | unconditional jump | 1 |
| 0x31 | `JZ`  | `t` | jump if Z | 1 |
| 0x32 | `JNZ` | `t` | jump if !Z | 1 |
| 0x33 | `JC`  | `t` | jump if C | 1 |
| 0x34 | `JNC` | `t` | jump if !C | 1 |
| 0x35 | `JN`  | `t` | jump if N | 1 |
| 0x36 | `DJNZ`| `r, t`| `rd -= 1`, jump if `rd != 0` | 1 |
| 0x38 | `HALT`| – | clear `run`, stop; `pc` does not advance | 1 |
| 0x39 | `NOP` | – | nothing | 1 |
| 0x3A | `WAITC`| `i` | wait `max(n,1)` cycles, `n = rs[2:0]:imm8` | `max(n,1)` |
| 0x3B | `PACE`| – | wait for the pacing deadline, then `next += period` | ≥1 |
| 0x3C | `PACERST`| – | `next = cycle << 8` | 1 |
| 0x3E | `ASSERT`| `r, i` | set the engine error flag if `rd != imm` | 1 |

Jump conditions live in `rd` (0=always, 1=Z, 2=NZ, 3=C, 4=NC, 5=N, 6=Z,
7=NZ). The assembler fills `rd` from the mnemonic.

### 2.5 Streaming, sync and time

| op | mnemonic | operands | semantics |
|---|---|---|---|
| 0x40 | `PUSH` | `r` | push `rd` to the output FIFO; **blocks** while full |
| 0x41 | `PULL` | `r` | pop the input FIFO into `rd`; **blocks** while empty |
| 0x42 | `PUSHN`| `r` | push; on a full FIFO set `nf_flag` and continue |
| 0x43 | `PULLN`| `r` | pop; on an empty FIFO set `nf_flag`, leave `rd` and continue |
| 0x44 | `IRQSET`| `i` | set global IRQ line `imm[2:0]` |
| 0x45 | `IRQCLR`| `i` | clear IRQ line |
| 0x46 | `IRQWAIT`| `i` | block until the IRQ line is set (timeout as `WAITP`) |
| 0x47 | `BAR` | `i` | arrive at barrier `imm[1:0]`; completes when every running engine has arrived |
| 0x48 | `TSLO`| `r` | `rd = cycle[7:0]` |
| 0x49 | `TSHI`| `r` | `rd = cycle[15:8]` |
| 0x4A | `MEASLO`| `r` | `rd = (cycle - ts_event)[7:0]` |
| 0x4B | `MEASHI`| `r` | `rd = (cycle - ts_event)[15:8]` |
| 0x4C | `CAPTURE`| `i` | push `{cycle, imm[3:0] pin, imm[4] level}` to the capture FIFO |
| 0x4D | `CFG` | `f, i` | write a configuration field (see §4) |

`PUSH`/`PULL` that block hold `pc` and re-execute; `nf_flag` is cleared by a
successful blocking or non-blocking transfer.

### 2.6 Assist access (format `assist` / `asst`) — new in v2

The five protocol-agnostic assists (CRC, FIFO, SHIFT, NRZI, MANCH) are
addressed as a per-assist 8-register file. Three opcodes move data between an
engine register and an assist register, or issue an assist command. All three
retire in **one cycle**; there is no address setup and no load/store window.

| op | mnemonic | encoding | operands | semantics |
|---|---|---|---|---|
| 0x4E | `LDAS` | `rd`=dest, `rs`=register index, `imm8[2:0]`=assist id | `r, r, a` | `rd <- assist[id].reg[rs]`; reads are combinational |
| 0x4F | `STAS` | `rd`=source, `rs`=register index, `imm8[2:0]`=assist id | `r, r, a` | `assist[id].reg[rs] <- rd`; a write to `DATA` (reg 0) is the data-path side effect |
| 0x50 | `ASST` | `rs`=assist id, `imm8`=command | `a, i` | command side effect on `assist[rs]` |

Assist ids (`isa.ASSIST_NAMES`): `CRC` 0, `FIFO` 1, `SHIFT` 2, `NRZI` 3,
`MANCH` 4; ids 5..7 decode as `BAD` in the assembler/disassembler.

Assembled examples (verbatim from `tools/asm.py`, `tools/isa.py`):

```
e0 00 9c5000  LDAS r1, r2, CRC
e0 01 9ec008  STAS r3, r0, FIFO
e0 02 a02008  ASST MANCH, START
e0 03 9f0810  STAS r4, r1, SHIFT
```

Decoding `0x9c5000`: `op = 0x4E` (`LDAS`), `rd = 1`, `rs = 2`, `imm = 0`
(assist `CRC`), `ss = 0`.

**Empty-read rule.** An `LDAS` from an assist register that has no data (FIFO
`DATA` empty, SHIFT byte not valid, CRC not ready) sets `nf_flag` and leaves
`rd` unchanged, exactly like `PULLN`; it does not clear `Z`/`N`. A successful
read clears `nf_flag` and sets flags from the value read.

**Write collisions.** Engine writes and commands to the assist bank are
arbitrated by the top level: the highest engine index wins a same-cycle
collision (the pin-merge rule), and a host CSR write in the same cycle wins over
every engine. Reads have one port per engine and never conflict.

**Worked byte path.** Moving a byte to and from the assist FIFO is

```asm
    STAS r0, r0, FIFO        ; push r0 into the 16 x 8 stream FIFO
    LDAS r1, r0, FIFO        ; r1 = head byte; the read also pops it
```

`FIFO.DATA` (reg 0) is write-push / read-pop; `FIFO.STATUS` (reg 1) reports
`{0, full, empty, level[4:0]}`. `CRC.DATA` (reg 0) folds the byte (8 clocks);
a write while busy is dropped and sets `STATUS.drop`. The full per-assist
register map is §6.1.

---

## 3. Cycle counts and stall semantics

Every instruction is one cycle except:

| instruction | cycles | notes |
|---|---|---|
| `WAITC n` | exactly `max(n,1)` | `n = 0` and `n = 1` both take one cycle; `n = 5` takes five |
| `PACE` | until `cycle >= next_int`, then `next_int += period` with the `next_frac` carry | ≥ 1 cycle; completes immediately if the deadline has passed |
| `WAITP` (match) | ≥ 1 | the issue cycle counts; a match on a later cycle completes that cycle |
| `WAITP` (timeout) | issue + `timeout_cfg*256` stall cycles | then `timeout_flag = 1` and execution continues |
| `IRQWAIT` | as `WAITP` | same timeout counter |
| `PUSH` (full) / `PULL` (empty) | until space/data | the instruction re-executes |
| `BAR` | until all running engines arrive | the barrier clears in the arrival cycle |
| `LDAS` / `STAS` / `ASST` | 1 | assist reads are combinational; the assist may finish its own work over later clocks |
| `HALT` | 1 | clears `run`; the engine stops and `pc` stays |

**Side-set is driven on every cycle an instruction is in flight**, including
all stall cycles. This is what lets an I2C master hold SCL high through a
`WAITP` (clock stretching) without extra instructions.

### 3.1 Deadline pacer (`PACE` / `PACERST`)

`period` is 24.8 unsigned fixed point in a 32-bit register (`period[31:8]`
integer, `period[7:0]` fraction). The deadline is kept as a 32-bit integer
`next_int` plus an 8-bit `next_frac`, so it never truncates:

```
PACERST : next_int = cycle; next_frac = 0
PACE    : stall while cycle < next_int; on completion
            {carry, next_frac} = next_frac + period[7:0]
            next_int = next_int + period[31:8] + carry
```

The horizon is therefore the full 32-bit cycle counter (about 85.9 s at 50 MHz),
not 24 bits.

**Phase convention.** `PACERST` arms the deadline at the cycle it executes, so
a `PACE` issued on the *next* cycle completes immediately and advances the
deadline by one full period from the arm cycle. The first completion-to-
completion interval is therefore `period - 1`; every later interval is
`floor(period)` or `ceil(period)` and the mean is exactly `period`. Firmware
that wants the first bit interval to be exactly `period` issues `PACE` in the
cycle immediately after `PACERST` (as `firmware/uart_tx.asm` does).

Because the fractional part is carried in `next`, completion instants are
exactly

```
t_k = floor(c0 + k * period / 256)
```

so the average period is exact and the jitter is at most one cycle — with no
accumulated drift, even for periods like 100.5 cycles. The model probe in
`demos/run_demos.py` reports the 2^24 boundary case:

```
pacer probe @cycle 2^24: 100 completions in 9802 cycles (period=100) -> 98.0 cycles/completion: exact
```

### 3.2 Worked example: 115200 baud from 48 MHz

`48e6 / 115200 = 416.6667` cycles per bit; `416.6667 * 256 = 106666.67`, which
rounds to `106667 = 0x0001A0AB`. `firmware/uart_tx.asm` programs that value and
then, per byte:

| cycle | instruction | effect |
|---|---|---|
| `c` | `PACERST` | `next = c<<8` |
| `c+1` | `CLRP UIO,0x01` | start bit scheduled; visible during `c+2` |
| `c+2` | `PACE` | deadline already met: completes now, `next = c<<8 + P` |
| `c+3` | `LDI r1,8` | |
| `c+4` | `PACE` | stalls until `cycle >= c + 416` |
| `c+P+1` | `OUTBIT r0` | data bit 0, visible from `c+P+2` |
| … | | each `PACE`+`OUTBIT` pair advances one bit |
| `c+8P+1` | `OUTBIT r0` | data bit 7 |
| `c+8P+4` | `PACE` | holds bit 7 for its full slot |
| `c+9P+1` | `SETP UIO,0x01` | stop bit |
| `c+9P+2` | `PACE` | stop slot |

Measured on the RTL over the host SPI (`sim/test_protocols.py`,
`proteus_uart_tx_pins`, 18 checks): frame-start deltas `[4343, 4343, 4343, 4343]`
against the ideal `10 * 434.02734 = 4340.27`, +2.7 cycles/frame, inside the ±6
gate and non-accumulating; start-bit width 434 cycles, stop-bit run 437, measured
bit period 434.03.

### 3.3 `WAITP` details and timeout

`WAITP bank, mask, level` completes when `(pins & mask) == mask` (level 1) or
`(pins & mask) == 0` (level 0), where `pins` is the cycle-start pin snapshot
(`UIO` reads `uio_in`). On a match it records `ts_event = cycle` for `MEAS*`.

`CFG TIMEOUT, t` arms a timeout of `t*256` **stall** cycles: the issue cycle
never times out, and if the condition is still false after `t*256` further
cycles the instruction completes, sets `timeout_flag` and execution continues.
`t = 0` disables the timeout (default).

`mask = 0` is legal and always matches (both levels); it is a 1-cycle no-op.

---

## 4. CFG fields

`CFG field, value` — `rs` selects the field, `imm` is the value.

| field | code | value layout |
|---|---|---|
| `SIDE` | 0 | `[7]` en, `[6:5]` bank, `[4:2]` base, `[1:0]` width-1 (width is 1..3 pins) |
| `BITPIN` | 1 | `[7:6]` bank, `[5:3]` pin, `[2]` invert |
| `PERIOD0` | 2 | pacing period byte 0 (LSB), 24.8 fixed point |
| `PERIOD1` | 3 | period byte 1 |
| `PERIOD2` | 4 | period byte 2 |
| `PERIOD3` | 5 | period byte 3 (MSB) |
| `TIMEOUT` | 6 | `WAITP`/`IRQWAIT` timeout in 256-cycle units (0 = off) |
| `SCRATCH` | 7 | reserved, ignored by the model |

Side-set drives `width` contiguous pins starting at `base` in `bank`, taking
the value from the instruction's `ss` field, on every cycle. A pin covered by
side-set also gets its output-enable bit set (auto direction).

---

## 5. Pin fabric

Banks: `UI` = 0 (`ui_in`, read-only), `UO` = 1 (`uo_out`), `UIO` = 2
(`uio`, bidirectional). Bank 3 does not exist.

* A pin write is `{data, mask}`; the register update is
  `reg = (reg & ~mask) | (data & mask)`.
* Engines merge in index order 0..2, so the highest-numbered engine wins on a
  contested bit within the same cycle.
* One extra merge stage per bank applies the five assists: it sits above every
  engine and below the host (`src/tt_um_proteus.v`, fabric merge block). An
  assist owns pins only when its host-written `PINCFG` has `en = 1`; assist
  pins are push-pull, so the stage clears open-drain for the bits it owns.
* Host writes to `0x0520..0x0523` are applied last in the clocked block and win
  over engine and assist traffic in the same cycle.
* Any `UIO` write (pin instruction or side-set) also sets that pin's `oe` bit.
  `DIRS`/`DIRC` write `oe` directly and never trigger the auto-enable.
* Open drain: with `od=1`, writing `1` releases the pad (high-Z, external
  pull-up) and writing `0` drives it low. Effective drive is
  `oe_eff = oe & ~(od & out)`.
* Collision (sticky, cleared by the host): for push-pull driven bits,
  `uio_in != uio_out` flags a conflict; for open-drain driven-low bits,
  `uio_in != 0` flags one.

---

## 6. Host-visible engine state

Three engines in the hybrid build. Engine window base is `0x0010 + 0x20*e`
for `e < 3`, region `0x0010..0x006F`. Offsets inside the window:

| offset | register |
|---|---|
| `+0x0` | `E_STATUS` `[0]`run `[1]`halted `[2]`in_empty `[3]`in_full `[4]`out_empty `[5]`out_full `[6]`nf `[7]`timeout |
| `+0x1` | `E_PC` |
| `+0x2` | `E_FLAGS {5'b0,n,c,z}` |
| `+0x3` | `E_ERROR` (sticky `ASSERT` failure) |
| `+0x4..0xB` | `r0..r7` |
| `+0xC..0xF` | period bytes 0..3 |
| `+0x10` | `IN_FIFO` write (pushes a byte) |
| `+0x11` | `OUT_FIFO` read (pops a byte) |
| `+0x12` | bit-pin config (CFG field 1 encoding) |
| `+0x13` | side-set config (CFG field 0 encoding) |
| `+0x14` | timeout config |
| `+0x15` | reserved (reads 0) |

Examples: engine 0 `r0` = `0x0014`; engine 1 `r0` = `0x0034`; engine 2
`IN_FIFO` = `0x0060`; engine 2 `OUT_FIFO` = `0x0061`.

Program RAM is at `0x0100 + e*0x100 + i*4 + b` (`e < 3`, instruction
`i < PROG_DEPTH`, byte `b < 3`), written per byte lane. The window therefore
ends at `0x03FF` (`PROTEUS_PM_END`, `src/proteus_defs.vh`); `0x0400` is the v1
engine-3 page and must read 0 without aliasing engine 2. The byte order is
**little endian**: instruction byte `b` occupies `prog[addr][8*b +: 8]`, and a
host read of that address returns `host_prog_rdata[8*b +: 8]`.

### 6.1 Assist CSR window (new in v2)

Host view: `0x0600 + 0x10*id + reg`, `id` 0..4, `reg` 0..7, window end `0x064F`
(`PROTEUS_AS_BASE/STRIDE/END`). Register 8 of each stride is the host-only
`PINCFG` register, which keeps the engine view exactly 8 registers (a 3-bit
`rs` field). Defined by `src/proteus_assist.v`; mirrored in
`docs/programming.md` §2.6.

| id | assist | reg 0 | reg 1 | reg 2 | reg 3 | reg 4..7 |
|---|---|---|---|---|---|---|
| 0 | `CRC` | DATA (write folds a byte) | STATUS `[7]`busy `[1]`drop `[0]`empty | CFG0 `{lsb, refl, width[5:0]}` | CMD: 0 page=CRC, 1 start, 6 flush, 8/9/10 page=init/poly/xorout | selected page bytes `[7:0] [15:8] [23:16] [31:24]` |
| 1 | `FIFO` | DATA (write push, read pop) | STATUS `{0,full,empty,level[4:0]}` | BURSTLEN | CMD: 1/3 arm burst, 0 clr | POPS, IRQ `[0]`burst_done, 0, 0 |
| 2 | `SHIFT` | DATA (push / non-destructive read) | STATUS `[7]`stuff `[0]`byte_valid | CFG `{dir,width[6:1],en}` | CMD: 0 reset, 1 start, 2 stop, 8 step | `{dout[7:0]..[31:24]}` |
| 3 | `NRZI` | TXDATA (write pushes a byte) | RXDATA | STATUS `[7]`stuff_err `[6]`eop `[5]`sync `[4]`se0 `[3]`busy `[2]`ready `[1]`overflow `[0]`reset_seen | DIV (clocks/bit, 6 bit) | 0 |
| 4 | `MANCH` | TXDATA | RXDATA | STATUS `[7]`manch_err `[6]`phase_err `[5]`locked `[4]`busy `[3]`ready `[2]`overflow `[1]`bit_valid | CFG `{HALF_DIV,OS}` (elaboration constants, read-only) | 0 |

`ASST` command names (`isa.ASST_CMDS`) are `RESET` 0, `START` 1, `STOP` 2,
`ARM` 3, `SYNC` 4, `EOP` 5, `FLUSH` 6, `LATCH` 7; each assist implements the
subset listed above, and the host CMD register uses the same numeric values.

`PINCFG` (+8) encoding: `[7]` en, `[6:5]` bank (0 `ui_in` read-only, 1 `uo_out`,
2 `uio`, 3 none), `[4:2]` tx_base, `[1:0]` rx_base. NRZI drives two adjacent TX
pins (`dp` at `tx_base`, `dm` at `tx_base+1`) and senses `dp/dm` at
`rx_base`/`rx_base+1`; MANCH drives one TX pin and senses one RX pin. Receive
pins are read from the raw pads, never from the merged output.

---

## 7. Assembler (`tools/asm.py`)

```
.venv/bin/python tools/asm.py firmware/uart_tx.asm --listing
.venv/bin/python tools/asm.py firmware/i2c_master.asm --depth 32 -o i2c.json
```

### Syntax

```
; comment
label:
[ss=N] INSTR operands      ; N = 0..7
.engine N                  ; 0..2 in the hybrid build, default 0
.equ NAME, value
.org N                     ; pad with NOPs up to address N
.fill N                    ; N NOPs
.word 0x123456             ; raw 24-bit word
```

Operands: `r0..r7`, `UI|UO|UIO`, CFG field names, assist names
(`CRC FIFO SHIFT NRZI MANCH`), command names (`RESET START STOP ARM SYNC EOP
FLUSH LATCH`), labels, immediates (`0x1f`, `0b1010`, `17`, `-1`). Labels are
**per engine**; a forward reference is fine, a cross-engine reference is an
error. `LI` → `LDI`, `RET`/`END` → `HALT`.

Assist operands: `LDAS rd, rs, ASSIST`, `STAS rd, rs, ASSIST`,
`ASST ASSIST, COMMAND`. `rs` is a register *index* 0..7, not a register name:
`LDAS r1, r0, CRC` reads CRC register 0 into `r1`.

Arity is strict: `LDI r0` and `LDI r0, 0, r1` are both errors. Immediates must
fit `-128..255`; `WAITC` takes `0..2047`; jump targets must be below the
program depth.

### Example

```
$ .venv/bin/python tools/asm.py firmware/uart_tx.asm --listing
e0 00 9a1558  CFG PERIOD0, 0xab               ; line 52
e0 01 9a1d00  CFG PERIOD1, 0xa0               ; line 53
e0 02 9a2008  CFG PERIOD2, 0x01               ; line 54
e0 03 9a0c00  CFG BITPIN, 0x80                ; line 55
e0 04 441008  SETP UIO, 0x01                  ; line 56
e0 05 820000  PULL r0                         ; line 59
e0 06 780000  PACERST                         ; line 60
e0 07 461008  CLRP UIO, 0x01                  ; line 61
e0 08 760000  PACE                            ; line 62
e0 09 004040  LDI r1, 0x08                    ; line 63
e0 0a 760000  PACE                            ; line 65
e0 0b 560000  OUTBIT r0                       ; line 66
labels e0: bit=10, loop=05
```

The listing columns are `engine address word disassembly ; source line`.

### Output

`-o out.json` writes `{"0": [words...], "1": [...]}`; `--hex` prints one
6-digit word per line with an `; engine N` header.
