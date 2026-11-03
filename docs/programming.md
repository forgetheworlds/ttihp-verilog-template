# Programming PROTEUS

This is the programmer's guide: the host SPI protocol byte by byte, the complete
register map (engine, global and assist), the assembler, the firmware idioms
that make the hardware useful, and a worked example with its assembled listing.

Numeric authority: `tools/isa.py` (opcodes and encoding), `src/proteus_defs.vh`
and the decode in `src/tt_um_proteus.v` (register map), `src/proteus_assist.v`
(assist registers), `tools/model.py` (cycle-level behaviour). Where this
document and an older doc disagree, the source files win.

The hybrid v2 build has **three engines (0..2)**, `VERSION = 0x02`, 75 opcodes,
a 16-bit register map extended by the assist window at `0x0600`.

---

## 1. Host link

SPI mode 0 (CPOL = 0, CPHA = 0), MSB first. `CS_N` frames exactly one command;
raising `CS_N` ends it. The slave synchronises `SCK`/`CS_N`/`MOSI` through two
flip-flops and derives both edges from the synchronised clock, so:

| `SCK` relative to `clk` | result |
|---|---|
| `<= clk/8` | fully clean (the documented, verified configuration) |
| `clk/6` | marginal |
| `clk/4` | short by one clock - **do not use** |

At 50 MHz the practical ceiling is 6.25 MHz. The DE2 build (v1 tree) runs
`SCK = clk/16` (3.125 MHz) for margin.

`MISO` is driven only while `CS_N` is low and only while the host owns the pins
(`host_en = 1`).

### Frame forms

With `N` data bytes, one command is `1 + N` bytes on `MOSI`. Read commands
therefore clock `1 + N` bytes too, where the `N` bytes after the command or
address are dummies and the answers come back on `MISO` during them.

| command | `MOSI` bytes | `MISO` during |
|---|---|---|
| `0x00` NOP | `00` | not driven / 0 |
| `0x03` SET_PTR_LO | `03 lo` | - |
| `0x04` SET_PTR_HI | `04 hi` | - |
| `0x01` WRITE_INC | `01 d0 d1 ...` | - |
| `0x02` READ_INC | `02 xx xx ...` | `r0 r1 ...` (one byte per dummy) |
| `0x05` WRITE_ADDR | `05 lo hi d0 d1 ...` | - |
| `0x06` READ_ADDR | `06 lo hi xx xx ...` | `r0 r1 ...` |
| `0x07` PING | `07 xx` | `50` (during the second byte) |
| `0x08` SOFT_RESET | `08` | - |
| `0x09` HOST_DISABLE | `09` | - |

Addresses in `WRITE_ADDR`/`READ_ADDR` are little endian: low byte first. The
internal pointer auto-increments on every data byte, so a single
`WRITE_ADDR`/`READ_ADDR` frame is a burst.

Reads are pipelined by one byte-time: the read request is issued at the 7th
`SCK` rising edge of the byte being shifted out, so the value is stable before
the falling edge that puts it on `MISO`. Consequence: the first returned byte
appears during the first dummy byte, and `READ_ADDR 0x0000 1` returns `0x50`
(`ID0`).

### Byte-level example: identity

```
MOSI  07 00
MISO  ?? 50          <- 0x50 = 'P' (PROTEUS_ID0)
MOSI  06 02 00 00    <- read VERSION at 0x0002
MISO  ?? ?? 02       <- 0x02 = hybrid v2
```

### Byte-level example: write one instruction word

Instruction `0x9A1000` (`CFG PERIOD0, 0x00`) belongs at program address `0x0100`
for engine 0. Program memory is little endian, so the bytes are `00 10 9A`.

```
MOSI  05 00 01 00 10 9A
        ^  ^^^^^ ^^^^^^^
        |  addr=0x0100   three data bytes
        WRITE_ADDR
```

Read it back:

```
MOSI  06 00 01 00 10 9A     (three dummies)
MISO  ?? ?? ?? 00 10 9A
```

### Program memory layout

```
address = 0x0100 + 0x100*engine + 4*instruction + byte      byte = 0..2
```

| engine | instruction 0 | last instruction (depth 32) |
|---|---|---|
| 0 | `0x0100..0x0102` | `0x017C..0x017E` |
| 1 | `0x0200..0x0202` | `0x027C..0x027E` |
| 2 | `0x0300..0x0302` | `0x037C..0x037E` |

The window ends at `0x03FF` (`PROTEUS_PM_END`); `0x0400` is the v1 engine-3
page and is **not mapped** in v2: writes there are dropped and reads return 0
without aliasing engine 2 (`sim/test_protocols.py::proteus_v2_map` checks this).

Byte 3 of each word (`0x0103`, `0x0107`, ...) is unused: a write there is
dropped (`pm_ok` requires `pm_byte != 3`) and a read returns 0. This is
deliberate and useful - it lets a loader stream **four** bytes per instruction
so the addresses stay contiguous.

Writes with `instruction >= PROG_DEPTH` are dropped and read back 0, so
overshooting a short program is harmless. `PROG_DEPTH` is a top parameter,
default 32, maximum 64; `PDEPTH` is 7 bits in v2, so a 64-deep build loads
correctly.

After reset the engine does not execute until its program array has been filled
(`prog_ready`, one entry per clock, 32 clocks at the default depth). Reset never
relies on RAM contents. Reset an engine and load it before setting its `RUN`
bit.

---

## 2. Register map

All addresses are 16-bit register indices (not byte offsets). `R` = read,
`W` = write, `RW` = both.

### 2.1 Global

| addr | acc | name | contents |
|---|---|---|---|
| `0x0000` | R | `ID0` | `0x50` (`'P'`) |
| `0x0001` | R | `ID1` | `0x52` (`'R'`) |
| `0x0002` | R | `VERSION` | `0x02` (hybrid v2) |
| `0x0003` | R | `STATUS` | `[0]` any_run `[1]` irq `[2]` cap_overflow `[3]` collision `[4]` any_error |
| `0x0004` | RW | `RUN` | bit `e` = engine `e` run; 3 bits, bit 3 is ignored |
| `0x0005` | W | `HALT` | bit `e` clears engine `e` run |
| `0x0006` | W | `SOFT_RESET` | any write resets the chip |
| `0x0007` | RW | `HOST_EN` | `[0]` host owns the SPI pins (reset = 1); reads back `{7'b0, host_en}` |
| `0x0008` | R | `IRQ_STATUS` | raw 8 IRQ lines |
| `0x0009` | RW | `IRQ_ENABLE` | mask for the `uo_out[1]` IRQ pin |
| `0x000A` | W | `IRQ_ACK` | write-1-to-clear mask |
| `0x000B..0x000E` | R | `CYCLE0..3` | 32-bit cycle counter, byte 0 (LSB) first |

`0x0006` and `0x0007` are consumed by `proteus_host`, not the top: a write to
`0x0006` pulses the chip reset, a write to `0x0007` loads `host_en` from bit 0.

### 2.2 Engine window

Base `0x0010 + 0x20*e`, `e = 0..2`; region `0x0010..0x006F`; engine =
`(addr-0x0010)[6:5]`, offset = `(addr-0x0010)[4:0]`. The stride is 0x20, not
0x10: the map defines offsets up to `0x15`, which cannot fit a 0x10 stride
(`src/tt_um_proteus.v`, decision 7).

| off | acc | name | contents |
|---|---|---|---|
| `+0x00` | R | `E_STATUS` | `[0]` run `[1]` halted `[2]` in_empty `[3]` in_full `[4]` out_empty `[5]` out_full `[6]` nf `[7]` timeout |
| `+0x01` | R | `E_PC` | program counter |
| `+0x02` | R | `E_FLAGS` | **reads 0** - the frozen engine port list has no flags output |
| `+0x03` | R | `E_ERROR` | sticky `ASSERT` failure |
| `+0x04..+0x0B` | RW | `r0..r7` | registers |
| `+0x0C..+0x0F` | RW | period bytes 0..3 | 24.8 fixed point, byte 0 = LSB |
| `+0x10` | W | `IN_FIFO` | a write pushes one byte; reads 0 |
| `+0x11` | R | `OUT_FIFO` | a read pops one byte |
| `+0x12` | RW | bit-pin cfg | `[7:6]` bank `[5:3]` pin `[2]` invert |
| `+0x13` | RW | side-set cfg | `[7]` en `[6:5]` bank `[4:2]` base `[1:0]` width-1 |
| `+0x14` | RW | timeout cfg | `WAITP`/`IRQWAIT` timeout in 256-cycle units, 0 = off |
| `+0x15` | R | reserved | reads 0 |

Examples: engine 0 `r0` = `0x0014`; engine 1 `r0` = `0x0034`; engine 2
`IN_FIFO` = `0x0060`; engine 2 `OUT_FIFO` = `0x0061`.

Writes to `+0x10` push a byte; reads of `+0x11` pop one. Both are side-effecting;
do not poll them casually.

### 2.3 Program memory

See section 1. `0x0100 + 0x100*e + 4*i + b`, `e = 0..2`.

### 2.4 Capture, collision, direct pins

| addr | acc | name | contents |
|---|---|---|---|
| `0x0500` | RW | `CAP_EN` | watched `uio` pins, one bit per pin |
| `0x0501` | R | `CAP_STATUS` | `{3'b0, [4] overflow, [3:0] count}` (4-entry FIFO, count reaches 4) |
| `0x0502..0x0505` | R | `CAP_TS0..3` | head event timestamp, byte 0 (LSB) first |
| `0x0506` | R | `CAP_INFO` | `[3:0]` pin, `[4]` level |
| `0x0507` | W | `CAP_POP` | advance the head |
| `0x0510` | R | `COLLISION` | 8-bit sticky per-pin collision mask |
| `0x0511` | W | `COLLISION_CLR` | clear the mask |
| `0x0520` | RW | `UO_OUT` | fabric output register |
| `0x0521` | RW | `UIO_OUT` | fabric output register |
| `0x0522` | RW | `UIO_OE` | per-pin output enable |
| `0x0523` | RW | `UIO_OD` | per-pin open-drain |
| `0x0530` | R | `ASSERT_INFO` | `[5:4]` engine, `[3:0]` PC of the last failed `ASSERT` |

`CAP_TS*`/`CAP_INFO` are a snapshot of the head entry: pop after reading, or
read all five bytes first and pop afterwards, so a new event cannot slip
between reads.

### 2.5 Host pin handover

While `host_en = 1`, `ui_in[2:0]` and `uo_out[0]` are owned by the SPI slave and
`uo_out[1]` is the IRQ pin; the engines read `ui_in[2:0]` and `uo_out[1:0]` as
0 and their writes to `uo_out[1:0]` are dropped.

Command `0x09` (or a write of 0 to `HOST_EN`) releases them; the fabric then
owns all 24 pins. Frames are still decoded after release - a fabric that
bit-bangs `SCK`/`CS_N`/`MOSI` can still reach the register map and set `HOST_EN`
back to 1. Two engines can be dedicated to software SPI/I2C to the host if the
board needs it.

### 2.6 Assist CSR window (new in v2)

Host view: `0x0600 + 0x10*id + reg`, `id` 0..4, `reg` 0..7, window end `0x064F`
(`0x0650` is outside). Register 8 of each 0x10 stride is the host-only `PINCFG`
register. The normative map is the comment block at the top of
`src/proteus_assist.v`; this is the same table.

Assist ids: `CRC` 0, `FIFO` 1, `SHIFT` 2, `NRZI` 3, `MANCH` 4.

Block areas in the headings below are the hierarchical per-module lines from
`results/synth_v2_root.txt` (lines 18834-19021); they sum to the 59,854.90 um2
assist set. The standalone study syntheses in `results/hybrid_area.md` give
slightly different values for the same blocks (see
`docs/hybrid-architecture.md` §1).

#### CRC (id 0) — `crc_bit`, 21,152.96 um2

| reg | acc | contents |
|---|---|---|
| 0 | W | `DATA`: write = fold that byte (8 clocks); a write while busy is dropped and sets `STATUS.drop` |
| 1 | R | `STATUS` `[7]` busy `[1]` drop `[0]` empty (= ~busy) |
| 2 | RW | `CFG0` `{lsb[7], refl[6], width[5:0]}` |
| 3 | RW | `CMD`: 0 page = CRC result, 1 start (reload init), 6 flush (fold 0x00), 8 page = init, 9 page = poly, 10 page = xorout |
| 4..7 | RW/RO | page bytes `[7:0]`, `[15:8]`, `[23:16]`, `[31:24]` of the selected page; page 0 is the read-only CRC result |

#### FIFO (id 1) — `assist_fifo` 16 x 8, 12,423.12 um2

| reg | acc | contents |
|---|---|---|
| 0 | RW | `DATA`: write = push, read = pop (returns the pre-pop head) |
| 1 | R | `STATUS` `{0, full, empty, level[4:0]}` |
| 2 | RW | `BURSTLEN` armed pop count |
| 3 | W | `CMD`: 1 or 3 = arm burst, 0 = clear |
| 4 | R | `POPS` remaining armed pops |
| 5 | R | `IRQ` `[0]` burst_done |
| 6,7 | R | 0 |

#### SHIFT (id 2) — `shiftreg32`, 9,559.51 um2

| reg | acc | contents |
|---|---|---|
| 0 | RW | `DATA`: write = push byte at the active end; read = byte at the active end (non-destructive) |
| 1 | R | `STATUS` `[7]` stuff_flag `[0]` byte_valid |
| 2 | RW | `CFG` `{dir[7], width[6:1], en[0]}` |
| 3 | W | `CMD`: 0 reset, 1 start (enable free-run), 2 stop, 8 step |
| 4..7 | R | `{dout[7:0], [15:8], [23:16], [31:24]}` |

#### NRZI (id 3) — USB LS encoder/decoder, 10,730.06 um2 (enc 4,071.51 + dec 6,658.55)

| reg | acc | contents |
|---|---|---|
| 0 | W | `TXDATA`: push a byte into the encoder queue |
| 1 | R | `RXDATA` last decoded byte |
| 2 | R | `STATUS` `[7]` stuff_err `[6]` eop `[5]` sync `[4]` se0 `[3]` enc_busy `[2]` enc_ready `[1]` enc_overflow `[0]` reset_seen (7..5 and 0 are sticky, cleared by CMD 0) |
| 3 | RW | `DIV` clocks per bit (6 bit, 0 -> 1); 32 at 48 MHz = 1.5 Mbit/s |
| 4..7 | R | 0 |

CMD: 0 reset, 1 start, 2 stop, 4 send SYNC (queues `0x80`), 5 send EOP.

#### MANCH (id 4) — 10BASE-T PCS, 5,989.26 um2 (enc 2,912.07 + dec 3,077.18)

| reg | acc | contents |
|---|---|---|
| 0 | W | `TXDATA`: push a byte into the encoder queue |
| 1 | R | `RXDATA` last decoded byte |
| 2 | R | `STATUS` `[7]` manch_err `[6]` phase_err `[5]` locked `[4]` enc_busy `[3]` enc_ready `[2]` enc_overflow `[1]` bit_valid |
| 3 | R | `CFG` `{HALF_DIV[3:0], OS[3:0]}`, elaboration-time constants (reported, not reprogrammable) |
| 4..7 | R | 0 |

CMD: 0 reset, 1 start, 2 stop. At 48 MHz a half-bit is 2.4 clocks, so this
block is specified for an 80 MHz (`OS=4`) or 160 MHz (`OS=8`) core
(`docs/hybrid-architecture.md` §5.5, risk R1); on this ASIC it is bench evidence
only.

#### PINCFG (host only, +8 of each stride)

```
0x0600 + 0x10*id + 8
  [7] en   [6:5] bank (0 ui_in RO, 1 uo_out, 2 uio, 3 none)
  [4:2] tx_base   [1:0] rx_base
```

NRZI drives two adjacent TX pins (`dp` at `tx_base`, `dm` at `tx_base+1`) and
senses `dp/dm` at `rx_base`/`rx_base+1`; MANCH drives one TX pin and senses one
RX pin. Receive pins are read from the raw pads. Assist outputs are push-pull
and enter the fabric merge above the engines and below the host; the stage
clears open-drain for the bits it owns. With `PINCFG.en = 0` (the reset value
for all five) the stage is the identity.

---

## 3. Assembler

```sh
.venv/bin/python tools/asm.py firmware/uart_tx.asm --listing
.venv/bin/python tools/asm.py firmware/i2c_master.asm --depth 32 -o i2c.json
.venv/bin/python tools/asm.py prog.asm --hex          # one 6-digit word per line
```

### Syntax

```
; comment                       everything from ';' to end of line
label:                          label in the current engine
[ss=N] INSTR operands           side-set value 0..7 for this instruction
.engine N                       select engine 0..2 (default 0)
.equ NAME, value                constant, usable as an immediate
.org N                          pad with NOPs up to address N
.fill N                         N NOPs
.word 0x123456                  raw 24-bit word
```

Operands: `r0..r7`, `UI|UO|UIO`, CFG field names
(`SIDE BITPIN PERIOD0..3 TIMEOUT SCRATCH`), assist names
(`CRC FIFO SHIFT NRZI MANCH`), assist commands
(`RESET START STOP ARM SYNC EOP FLUSH LATCH`), labels, immediates
(`0x1f`, `0b1010`, `17`, `-1`). Pseudo instructions: `LI` -> `LDI`,
`RET`/`END` -> `HALT`.

Labels are per engine; a forward reference is fine, a cross-engine reference is
an error. Arity is strict. Immediates must fit `-128..255`, `WAITC` takes
`0..2047`, jump targets must be below the program depth. Default depth is 32
(`--depth` up to 64).

### Operand forms worth memorising

| instruction | operands | encoding |
|---|---|---|
| `LDI r5, 0xA5` | register, immediate | `rd`=5, `imm`=0xA5 |
| `ADD r1, r2` | dest, source | `rd`=1, `rs`=2 |
| `SETP UIO, 0x01` | bank, mask | `rs[1:0]`=bank, `imm`=mask |
| `OUTP UIO, 0x80, r2` | bank, mask, value reg | as above, `rd`=2 |
| `WAITP UIO, 0x40, 1` | bank, mask, level | `rs` = bank &#124; (level<<2), `imm`=mask |
| `CFG PERIOD1, 0xE8` | field, value | `rs`=field code, `imm`=value |
| `DJNZ r1, loop` | counter, target | `rd`=1, `imm`=target |
| `CAPTURE 0x05` | tag | `imm[3:0]`=pin, `imm[4]`=level |
| `LDAS r1, r2, CRC` | dest, assist reg index, assist | `rd`=1, `rs`=2, `imm[2:0]`=0 |
| `STAS r3, r0, FIFO` | source, assist reg index, assist | `rd`=3, `rs`=0, `imm[2:0]`=1 |
| `ASST MANCH, START` | assist, command | `rs`=4, `imm`=1 |

Assist operand examples, assembled (`tools/asm.py`):

```
e0 00 9c5000  LDAS r1, r2, CRC
e0 01 9ec008  STAS r3, r0, FIFO
e0 02 a02008  ASST MANCH, START
e0 03 9f0810  STAS r4, r1, SHIFT
```

---

## 4. Firmware patterns

### 4.1 Deadline pacing (`PACE`) instead of delays

```asm
    CFG PERIOD0, 0x00        ; period = 0x0003E800 = 1000.0 cycles
    CFG PERIOD1, 0xE8
    CFG PERIOD2, 0x03
    CFG PERIOD3, 0x00
    PACERST
loop:
    PACE                     ; completes at arm + k*period
```

`PACE` stalls until `cycle >= next_int`; `PACERST` arms `next_int = cycle`.
Phase convention: a `PACE` issued on the cycle **immediately after** `PACERST`
completes at once and advances the deadline by one full period from the arm
cycle, so the very first interval is `period - 1`. Firmware that wants the first
interval to be exactly `period` issues `PACE` in that next cycle anyway - which
is what the pattern above does - and every later completion is `period` apart on
average. There is no accumulated drift: completion instants are
`floor(c0 + k*period/256)`.

### 4.2 Side-set: clock edges for free

Side-set bits are driven on every cycle the instruction is in flight, including
stall cycles. `spi_master.asm` puts SCK in side-set so a clock edge costs no
instruction slot:

```asm
    CFG SIDE, 0xC8           ; en=1, bank UIO, base 2 (SCK), width 1
    PACE
    [ss=0] OUTBIT r0         ; SCK low this cycle, MOSI changes
    PACE
    [ss=1] OUTBIT r0         ; SCK high: the slave samples MOSI
```

The same mechanism holds SCL high through a `WAITP` in an I2C master, which is
what makes clock stretching workable without extra instructions.

### 4.3 `WAITP`: block on a pin, with an optional timeout

```asm
    CFG TIMEOUT, 1           ; 1 * 256 stall cycles, 0 = wait forever
    WAITP UIO, 0x40, 1       ; block until UIO6 is high
    ; on match, ts_event = cycle (read it back with MEASLO/MEASHI)
```

On timeout the instruction completes, `E_STATUS[7]` (timeout) is set, and
execution continues - firmware can then decide whether to abort. `mask = 0`
always matches and is a one-cycle no-op.

### 4.4 Open-drain I2C

```asm
    CFG SIDE,  0xD8          ; SCL = UIO6 via side-set
    CFG BITPIN, 0xB8         ; SDA = UIO7, OUTBIT/INBIT target
    ODSET UIO, 0xC0          ; both pads open drain
    SETP  UIO, 0xC0          ; release both (high via external pull-up)
    ; drive low: CLRP UIO, 0x80     release: SETP UIO, 0x80
    ; read SDA:  INBIT r0           (bit 0 of r0), then check collision bits
```

Rules the hardware enforces: with `od = 1`, a `1` releases the pad and a `0`
drives it low; effective drive is `oe & ~(od & out)`. A pad you drive low but
read high sets `COLLISION[bit]` - that is arbitration loss, and it is sticky
until `0x0511` is written.

### 4.5 Barriers: align engines on one cycle

```asm
    ; engine 0 and engine 1 both execute this; the barrier clears in the
    ; arrival cycle, so both leave on the same clock
    BAR 0
```

A barrier completes when every engine whose `RUN` bit is set has arrived at the
same barrier id (0..3). If only one engine is running, `BAR` completes
immediately. Use it to start two protocol phases on a common edge instead of
relying on two pacers staying in phase.

### 4.6 Host FIFOs

`PULL r0` blocks until the host pushes a byte into `IN_FIFO`; `PUSH r0` blocks
while the output FIFO is full. The non-blocking forms `PULLN`/`PUSHN` set
`E_STATUS[6]` (nf) and continue, which is the right choice in a loop that must
not stall when the host is slow. `uart_tx.asm` uses blocking `PULL` and idles on
TX high between frames, which back-pressures the host instead of dropping bytes.

### 4.7 Byte streams through the assists

The Ethernet MII transmitter is the reference pattern
(`firmware/ethernet_mii_tx.asm`, 31 words): the host fills the assist FIFO,
each iteration pops one byte and folds it into the CRC, two nibbles go out on
the pads from side-set, and when the byte count expires the four CRC result
bytes are pushed back through the same FIFO and emitted by the same loop.

```asm
; ---- byte preparation: runs in the high phase after nibble B ---------------
prep:
    [ss=1] LDAS r1, r1, FIFO   ; STATUS: {0, full, empty, level[4:0]}
    [ss=1] ANDI r1, 0x20       ; bit 5 = empty -> nonzero when the FIFO is dry
    [ss=1] JNZ ifg             ; underrun: abort the frame
    [ss=1] LDAS r0, r0, FIFO   ; pop the byte
    [ss=1] STAS r0, r0, CRC    ; fold it into the FCS (8 clocks, background)
    [ss=1] ROLI r0, 2          ; bits [5:2] = low nibble
    [ss=1] WAITP UIO, 0x01, 0  ; next low phase
```

Quoted from `firmware/ethernet_mii_tx.asm` (words 13..19 of 31). The FCS pass
uses the same pairs in the other direction (`LDAS r0, r4..r7, CRC` then
`STAS r0, r0, FIFO`), and one 14-word loop emits both the frame body and the
four FCS bytes.

Relevant registers: `FIFO.STATUS` reg 1 for the under-run check, `CRC.STATUS`
reg 1 (`empty` = not busy), `CRC` regs 4..7 for the result page, `ASST CRC, 6`
to flush. The measured result at the pads is in `v2/results/v2_verify.md` §4:
one 802.3 frame, 144 nibbles / 72 wire bytes, FCS `0xE7C87B32` equal to
`zlib.crc32`.

**Rate limit.** The host port cannot feed 10 Mbit/s: one wire byte every 40 clk
needs a host byte every 0.8 us while the cleanest SPI frame costs ~280 clk
(5.6 us). The assist FIFO is 16 bytes deep, so sustained Ethernet is
host-bandwidth-bound; the RTL gate clocks TX_CLK slowly and proves content, not
rate (`v2/results/v2_verify.md` §4, §7).

---

## 5. Worked example

Source (`example.asm`), a 25 kHz square wave on `UIO[0]` with a capture tag per
edge. 1000.0 cycles at 50 MHz = 20 us per half period.

```asm
; period 1000.0 cycles = 0x0003E800 in 24.8 fixed point
    .engine 0
    CFG PERIOD0, 0x00
    CFG PERIOD1, 0xE8
    CFG PERIOD2, 0x03
    CFG PERIOD3, 0x00
    CFG BITPIN,  0x80        ; bit ops -> UIO0
    SETP UIO, 0x01           ; idle high, output enabled (auto-OE)
    PACERST
loop:
    PACE
    TOGP UIO, 0x01           ; one edge per period
    CAPTURE 0x05             ; software capture event: pin 5, level 0
    JMP loop
```

Assembled listing (`.venv/bin/python tools/asm.py example.asm --listing --depth 32`):

```
e0 00 9a1000  CFG PERIOD0, 0x00            ; line 4
e0 01 9a1f40  CFG PERIOD1, 0xe8            ; line 5
e0 02 9a2018  CFG PERIOD2, 0x03            ; line 6
e0 03 9a2800  CFG PERIOD3, 0x00            ; line 7
e0 04 9a0c00  CFG BITPIN, 0x80             ; line 8
e0 05 441008  SETP UIO, 0x01               ; line 9
e0 06 780000  PACERST                      ; line 10
e0 07 760000  PACE                         ; line 12
e0 08 481008  TOGP UIO, 0x01               ; line 13
e0 09 980028  CAPTURE 0x05                 ; line 14
e0 10 600038  JMP 0x07                     ; line 15
labels e0: loop=07
```

Columns are engine, decimal address, 24-bit word, disassembly, source line.
Decoding `e0 01 9a1f40` by hand: `op = 0x4D` (CFG), `rd = 0`, `rs = 3`
(`PERIOD1`), `imm = 0xE8`, `ss = 0`.

Load it. `WRITE_ADDR` auto-increments from the address you give, so the clean
way to stream a whole program is a pointer burst over the contiguous lane
stream, including the unused fourth lane:

```
MOSI  03 00                 SET_PTR_LO 0x00
MOSI  04 01                 SET_PTR_HI 0x01          pointer = 0x0100
MOSI  01 00 10 9A 00  40 1F 9A 00  18 20 9A 00  ...
            w0 b0..b3   w1 b0..b3   w2 b0..b3
```

Each group of four `MOSI` data bytes is one instruction: three live lanes plus
a `0x00` that the chip drops (`pm_byte == 3`). After 11 words (44 bytes) the
pointer sits at `0x012C`.

Then:

```
MOSI  05 04 00 01        ; RUN: write 0x01 to 0x0004 -> engine 0 runs
```

`UIO[0]` toggles every 1000 cycles; each edge also pushes a capture entry with
`pin = 5, level = 0`. Read the first event with

```
MOSI  06 02 05 00 00 00 00   ; CAP_TS0..3 (4 bytes)
MISO  .. .. 00 00 00 00      ; cycle count at the event, byte 0 first
MOSI  06 06 05 00            ; CAP_INFO
MISO  .. .. 05               ; [3:0]=5 pin, [4]=0 level
MOSI  05 07 05 00            ; CAP_POP
```

Stop it with `MOSI 05 05 00 01` (write 1 to `HALT`, clearing engine 0 bit 0), or
reset everything with `MOSI 08`.

---

## 6. Firmware images in this tree

Word counts from `tools/asm.py --depth 32` (the assembler, not comments):

| image | engine(s) | words | limit |
|---|---|---:|---:|
| `firmware/pin_blink.asm` | 0 | 5 | 32 |
| `firmware/uart_tx.asm` | 0 | 18 | 32 |
| `firmware/uart_rx.asm` | 1 | 26 | 32 |
| `firmware/spi_master.asm` | 2 | 32 | 32 (exactly full) |
| `firmware/i2c_master.asm` | 2 + 1 | 32 + 32 | 32 each |
| `firmware/ethernet_mii_tx.asm` | 0 | 31 | 32 |
| `demos/autobaud_uart_rx.asm` | 0 | 32 | 32 |
| `demos/ws2812.asm`, `demos/ws2812_50mhz.asm` | 1 | 18 each | 32 |
| `demos/uart_spi_bridge.asm` | 0 + 1 | 21 + 19 | 32 each |

I2C is the only two-engine program: START/WRITE runs on engine 2 and
READ/STOP on engine 1, because the highest engine index wins a contested pin.
The halves are swapped relative to v1's engines 3+2, not renumbered
(`v2/results/v2_firmware.md` §1).

---

## 7. Debugging checklist

1. `PING` returns `0x50`? If not, check `SCK <= clk/8`, `CS_N` framing, and that
   the host still owns the pins (`0x0007` reads 1). `VERSION` (`0x0002`) reads
   `0x02` on this build.
2. `STATUS` (`0x0003`): bit 0 any_run should be 1 after `RUN`. If it is 0, the
   engine halted, errored, or never became ready (`prog_ready` needs 32 clocks
   after reset).
3. `E_STATUS` per engine: `[1]` halted, `[7]` timeout, `[6]` nf. A stuck engine
   with `halted = 0` and an unchanging `E_PC` is blocked on `PULL`, `WAITP`,
   `IRQWAIT` or `BAR`; that is the intended behaviour, not a hang.
4. `E_ERROR` plus `ASSERT_INFO` (`0x0530`) gives the engine and the low 4 bits
   of the PC of the first failed `ASSERT`.
5. `COLLISION` (`0x0510`) tells you which pad disagreed with its driver - the
   usual cause is an I2C target pulling SDA low during an ACK, or a missing
   external pull-up on an open-drain pad.
6. `E_PC` frozen at 0 with everything else idle: the program was never loaded
   (check `READ_ADDR` at `0x0100`), or the depth is too small for the image.
7. An assist seems dead: read `0x0600 + 0x10*id + 1` (STATUS) before anything
   else. `PINCFG` (`+8`) resets to 0, so an assist owns no pin until the host
   enables it; `LDAS` from an empty source sets `nf` and leaves `rd` unchanged
   (a zero in `rd` is not proof the assist ran).
