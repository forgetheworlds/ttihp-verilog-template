# PROTEUS hybrid architecture: general engines + protocol-agnostic assists

Status: study, 2026-11-03.  Area numbers in §0-§4 are the study's block
measurements and predictions (`results/hybrid_area.md`, RTL in `studies/hybrid/`).
Claims marked `[INFERENCE]` are arithmetic or judgement, not measurements.

The shipped tree was then synthesised separately: **519,233.80 um2 flat /
36,343 cells / 57.54 % of row area, 95.90 % of the 60 % budget**
(`results/synth_v2_root.txt` lines 47230 / 47202), i.e. **12,350.58 um2
(+1.37 pp) above the B' prediction below**, not under it.  §0 carries both
numbers; `results/final_evidence.md` §3.2 records the provenance.

---

## 0. Verdict

**GO — 3 engines + a five-block assist set, bit-serial CRC variant.**

| prediction (`results/hybrid_area.md` blocks) | |
|---|---|
| recommended area (hierarchical, same flow as `results/area_full.md`) | **506,883.22 um2** |
| row utilisation (902,417 um2) | **56.17%** |
| against the 60% placement budget (541,450.20 um2) | **93.6%, 34,566.98 um2 spare** |
| against v1 (581,138.67 um2, 64.40%) | **74,255.45 um2 lower (−8.2 pp)** |
| assist set | CRC (bit-serial, runtime width/direction) 21,152.96 + FIFO 16x8 12,397.80 + shift register 10,411.25 + NRZI enc/dec 10,755.42 + Manchester enc/dec 5,873.14 = **60,590.57 um2** |
| **measured on the shipped tree** (`results/synth_v2_root.txt`) | |
| flat area / cells | **519,233.80 um2 / 36,343 cells** |
| row utilisation (902,417 um2) | **57.54%** |
| against the 60% placement budget (541,450.20 um2) | **95.90%, 22,216.40 um2 spare** |
| hierarchical sum | 538,016.13 um2 = 59.62% |
| against the prediction above | **+12,350.58 um2 (+1.37 pp) above** |
| against v1 (581,138.67 um2, 64.40%) | 61,904.87 um2 lower (−6.86 pp) |

What it costs: one engine (132,381.80 um2 study block, 2.2x the whole assist
set) and therefore one concurrent protocol lane.  What it buys: Ethernet MII
and USB LS become 32-instruction programs instead of out-of-reach ones, and the
design drops from v1's routing-bound 64.4% to 56.17% predicted and **57.54%
measured** - inside the placement budget either way, with 4.1% of the budget as
headroom on the measured number (22,216.40 um2).  The measured build overshoots
the prediction by 12,350.58 um2; that overshoot is recorded, not fully
attributed.

Why not "4 engines + assists": that is 655,611.28 um2 (72.65%), 33,846 um2
above even the 68.9% routability precedent.  Assists cannot be added without
removing an engine.

---

## 1. What the measured blocks are

Each block is protocol-agnostic; none contains a protocol FSM that only one
protocol can use.

| block | function | area um2 | verified |
|---|---|---:|---|
| `crc_bit` (recommended) / `crc_engine` | 5..32-bit CRC, reflected or not, runtime init/poly/xorout, independent byte bit order; 1 step/clock or 8 steps/clock | 21,152.96 / 35,035.01 | PASS: 5 configurations match published check values and `zlib.crc32` |
| `assist_fifo` 16x8 | byte stream buffer with a hardware drain port and burst counter/IRQ | 12,397.80 | PASS: host order, level, drain, burst, overflow |
| `shiftreg32` | 32-bit bidirectional shift register, runtime width/order, byte push/pop, bit-stuff hook | 10,411.25 | PASS: shift direction, byte moves, stuff insertion |
| `nrzi_enc` + `nrzi_dec` | USB LS line code: stuffing, SYNC sliding-window detect, EOP/SE0 | 4,069.62 + 6,685.80 | decoder PASS on a perfect waveform (all four bytes after SYNC); closed loop with EOP has a 1-bit defect — R2 |
| `manchester_enc` + `manchester_dec` | 10BASE-T PCS at 20 Mbaud half-bits, 4x/8x oversampling receiver | 2,881.19 + 2,991.95 | PASS: loopback exact 48-bit pattern, lock, no violation |
| `crc_engine` (8 steps) | same function, byte-at-a-time | 35,035.01 | PASS: same 5 check values |

The um2 column is the standalone study synthesis (`results/hybrid_area.md`).
The same blocks inside the shipped hierarchy measure
(`results/synth_v2_root.txt` lines 18834-19021): `crc_bit` 21,152.96,
`assist_fifo` 12,423.12, `shiftreg32` 9,559.51, `nrzi_enc` + `nrzi_dec`
4,071.51 + 6,658.55, `manchester_enc` + `manchester_dec` 2,912.07 + 3,077.18,
i.e. a **59,854.90 um2** assist set.  Both sets of numbers are kept; the
shipped-hierarchy values are the sign-off ones.

Two CRC variants are measured because the byte-at-a-time unroll is not free
when the shift direction is a runtime bit: 2,846 cells vs 1,310 for the
bit-serial form.  At 48 MHz neither rate is needed beyond 1 bit/clock
(section 4.4).

---

## 2. Why assists are necessary, in numbers

### 2.1 Ethernet MII today

`demos/run_eth.py --budget` on `tools/model.py`, measured this session:

```
constant payload byte = 1 LDI + 10 emit words = 11 words/byte
engine 0 as shipped (preamble+SFD+payload+IFG+HALT)      32 words
+ 14 header bytes x 11                                    154
+ 4 FCS bytes x 11                                        44
= complete frame emitter                                 230 words  (limit 32)
FCS engine is a second program: 29 words, 8434 cycles for 60 bytes = 131.8 cycles/byte
```

So today the MII transmit demo emits only preamble + SFD + payload from one
engine, and a *second* engine spends 29 words and 131.8 cycles/byte on the
FCS.  A complete frame is 7.2x the instruction memory.  The FCS program is
measured at 140.8 cycles/byte and, as of the current firmware, matches
`zlib.crc32` on all three regression vectors (0xE7C87B32 / 0x758D6336 /
0xED086180); an earlier revision was missing the final inversion, which is why
this document's first draft flagged it.  The remaining problem is size and
rate, not correctness.

Consequences, with no assists:

* no 32-word program can emit a real frame (230 words measured);
* no 32-word program can carry a CRC-32 at 131.8 cycles/byte and still emit
  nibbles every 20 cycles.

Consequences with the recommended set:

* the 29-word CRC program disappears (hardware CRC, 8 clocks/byte);
* the 11-word-per-byte emitter disappears: firmware writes the frame length
  once and the stream, and the FIFO -> CRC -> nibble serializer chain runs
  autonomously.  A complete frame becomes a ~6-10 word program `[INFERENCE:
  word count from the instruction mix, not assembled]`.

### 2.2 USB low-speed

At 48 MHz one LS bit is exactly 32 clocks.  Per bit, a firmware NRZI
transmitter needs at least: shift/extract the bit (2), conditionally toggle the
line (2-3), pace (1), loop (1) = 6-8 instructions, so one byte is 48-64 words
before stuffing and CRC — 2x the whole engine.  A bit-serial CRC in firmware
costs 16 more instructions *per bit*.  With the NRZI encoder and CRC assist the
same byte is one `STAS` per byte into the encoder queue; the encoder owns the
clock, the stuffing and the EOP.  `[INFERENCE: instruction counts from the ISA
shape, not assembled]`

The SYNC value is settled by measurement, not by the ambiguous prose in
`research/protocols.md`: driving 0x80 LSB-first produces KJKJKJKK
(`0x80 = 0000000 1` in time order), which is what `tb_nrzi_wave` drives and
what the decoder's sliding window matches.

---

## 3. Engine-count tradeoff

All rows include host (12,503.60 um2) and top glue; 3-engine glue is
37,021.06 um2 (measured capture-port and merge deltas, section 2.2 of
`results/hybrid_area.md`).  "all" = 74,472.61 um2 (byte CRC), "min" =
60,590.57 um2 (bit CRC).

| option | area um2 | row % | % of 60% budget | margin vs 60% | vs v1 (581,138.67) |
|---|---:|---:|---:|---:|---:|
| v1 (as shipped): 4 engines, no assists | 581,138.67 | 64.40 | 107.3 | −39,688.47 | — |
| A: 4 engines + all assists | 655,611.28 | 72.65 | 121.1 | −114,161.08 | +74,472.61 |
| A': 4 engines + min assists | 641,729.24 | 71.11 | 118.5 | −100,279.04 | +60,590.57 |
| **B: 3 engines + all assists** | 520,765.27 | 57.71 | 96.2 | +20,684.93 | −60,373.40 |
| **B': 3 engines + min assists (recommended)** | **506,883.22** | **56.17** | **93.6** | **+34,566.98** | **−74,255.45** |
| C: 3 engines + all + 64-deep shared PRAM | 472,617.42 | 52.37 | 87.3 | +68,832.78 | −108,521.25 |
| C': 3 engines + min + 64-deep shared PRAM | 458,735.37 | 50.83 | 84.7 | +82,714.83 | −122,403.30 |
| sensitivity: 4 engines @ PROG_DEPTH=24 + min | 557,206.63 `[INFERENCE]` | 61.75 | 102.9 | −15,756.43 | −23,932.04 |
| **B' as built: shipped hybrid v2 (measured, not modelled)** | **519,233.80** | **57.54** | **95.90** | **+22,216.40** | **−61,904.87** |

Notes:

* B/B' reuse engine instances 0..2 exactly as measured (396,768.00 um2); no
  re-synthesis of a 3-engine top was run.  The glue delta is measured by
  benches (capture 5->4 push ports −1,883.61; pin merge 4->3 −580.61); the
  residual per-engine top logic (RUN bit, assert mux, barrier arm, window
  decode) is ≤2,995.24 um2 `[INFERENCE]` and would only improve B/C.
* Option C is the only one that changes the instruction store.  It replaces
  3 x 84,522.61 = 253,567.83 um2 of per-engine program RAM with 205,419.98 um2
  of 64 x 24 four-read-port RAM (48,147.85 um2 saved) and cuts the three
  engines from 96 to 64 total words.  It is not recommended (R6).
* 4 engines at depth 24 does not reach the budget even with the minimal assist
  set (102.9% of 60%), and costs 8 instructions per engine.
* The "B' as built" row is the measured shipped tree, not a model:
  `results/synth_v2_root.txt` line 47230 (519233.803200), line 47202
  (36,343 cells), line 19254 (hierarchical 538,016.13 = 59.62%).  It sits
  12,350.58 um2 (+1.37 pp) **above** the 506,883.22 um2 B' prediction.  The
  study's block numbers and the shipped-hierarchy block numbers differ
  (§1 footnote); the overshoot is not fully attributed to either.

---

## 4. Routability

The v1 four-engine build was routing-bound at 64.4% of row area; LibreLane
detailed routing, not placement, is the bottleneck at that density
(`results/area_full.md`).  The placement density knob is a *target*, so the
comparison that matters is cell area against the 60% budget, 541,450.20 um2:

| option | cell area | utilisation of the budget | below the 60% budget? | below the 68.9% precedent (621,765.31)? |
|---|---:|---:|---|---|
| v1 (as shipped) | 581,138.67 | 107.3% | no (+39,688) | yes |
| A | 655,611.28 | 121.1% | no (+114,161) | **no (+33,846)** |
| A' | 641,729.24 | 118.5% | no (+100,279) | **no (+19,964)** |
| B | 520,765.27 | 96.2% | yes (−20,685) | yes |
| B' | 506,883.22 | 93.6% | yes (−34,567) | yes |
| C | 472,617.42 | 87.3% | yes (−68,833) | yes |
| C' | 458,735.37 | 84.7% | yes (−82,715) | yes |
| **B' as built (measured)** | **519,233.80** | **95.90%** | **yes (−22,216)** | yes |

So option A is not "the current design plus assists": it is 114.2k um2 further
over the budget than the build that already does not fit, and 33.8k um2 above
the highest density this project has routed (68.9%).  A/B' differ by
148,728 um2, i.e. the fourth engine costs 2.2x the entire assist set.

Routability of B' beyond raw area:

* 56.17% leaves 34,567 um2 of cell headroom at the 60% target and 79,688 um2
  against the 65% target (586,571.05), i.e. the placer is not asked to exceed
  anything that has not already been routed here.  As built, the flat build
  leaves 22,216.40 um2 at the 60% target (`results/synth_v2_root.txt`).
* The assist logic is regular: CRC is a shifter XOR matrix, the Manchester and
  NRZI blocks are small FSMs, the FIFO and shift register are bit-slices.  No
  assist has a wide crossbar comparable to the capture unit's five-port write
  network (27,504.34 um2 of the current glue).
* The new decode (3 opcodes) rides the existing 7-bit opcode field, so the
  instruction decode width does not change.

---

## 5. Integration proposal

### 5.1 Access model: instruction CSR, not memory-mapped load/store

Two candidate models were considered:

| model | cost per byte moved | verdict |
|---|---|---|
| host-style memory map: `LDI lo`, `LDI hi`, load/store | 3-4 instructions/byte plus a 16-bit address setup per window | rejected: the engine's scarcest resource is instructions |
| dedicated CSR opcodes (1 instruction/byte, no address) | 1 instruction/byte, 1 cycle | **chosen** |
| CFG-field only (8 fields, no readback) | 1 instruction but no data path and no status | rejected: no way to read a CRC or drain a byte |

Assist configuration and status are also exposed in the **host** window so the
host can set polynomials, bit rates and widths once, and read counters, without
spending engine instructions.

### 5.2 New opcodes (0x4E..0x7F are free: 72 of 128 opcodes are defined)

| op | name | fields | semantics |
|---|---|---|---|
| `0x4E` | `LDAS` | `rd` = destination, `rs` = register index, `imm8[2:0]` = assist id | `rd <- assist[id].reg[rs]`; 1 cycle; empty FIFO sets `nf_flag` and leaves `rd` (the `PULLN` rule) |
| `0x4F` | `STAS` | `rd` = source, `rs` = register index, `imm8[2:0]` = assist id | `assist[id].reg[rs] <- rd`; 1 cycle; a write to `DATA` is the data-path side effect (fold a byte, push a byte, arm a transfer) |
| `0x50` | `ASST` | `rs` = assist id, `imm8` = command | command: 0 reset, 1 start, 2 stop, 3 arm burst, 4 send SYNC, 5 send EOP, 6 flush CRC, 7 latch CRC |

Three opcodes, 47 slots left.  No new instruction format: all three use the
existing `op/rd/rs/imm8` layout, so `tools/isa.py`, the assembler, the
disassembler and `tools/model.py` change in one place each.

### 5.3 Assist register file (8 registers per assist, 8 assists)

Host window: `0x0600 + 0x10*id + reg`.  Engine view: the same 8 registers via
`LDAS`/`STAS` with `rs` = reg.

| id | assist | reg 0 | reg 1 | reg 2 | reg 3 | 4..7 |
|---|---|---|---|---|---|---|
| 0 | CRC | DATA (W: fold byte) | STATUS (busy, empty) | CFG0 (width/refl/lsb) | CMD | CRC[7:0], [15:8], [23:16], [31:8] |
| 1 | FIFO | DATA (R/W) | STATUS (level/full/empty) | BURSTLEN | CMD (arm/clr) | POPS, IRQ flags, 0, 0 |
| 2 | SHIFT | DATA (W push / R pop byte) | STATUS (bits left, stuff flag) | CFG (width, dir) | CMD | 0..3 |
| 3 | NRZI | TXDATA | RXDATA | STATUS (busy, sync, eop, se0, stuff_err) | DIV (clocks/bit) | 0..3 |
| 4 | MANCH | TXDATA | RXDATA | STATUS (locked, phase_err, manch_err) | CFG (OS, half-div) | 0..3 |

### 5.4 Pin ownership and the fabric merge

Assists must drive and sense pads, and the current fabric has no assist
request lines.  Proposal: extend the merge with one extra "assist" source per
bank, priority **above all engines** and below the host:

* assists decode which pins they own from a per-assist `PINCFG` register (bank,
  base, width), the same encoding `CFG SIDE` already uses;
* an assist's pin writes go through the same `{data, mask}` merge, so open-drain
  and collision detection keep working unchanged;
* assist inputs come from `uio_in`/`ui_in` (raw pads), not from the merged
  output, so an assist sees the bus, which is what I2C/USB/MII require.

Cost: one more merge stage and a 3-bit bank/base decode per assist, roughly
0.7-1.5k um2 `[INFERENCE]`, plus a few hundred cells of CSR decode.  Budget
2,000 um2 of integration glue in the recommendation (inside the 34,567 um2
predicted headroom; the shipped build has 22,216.40 um2 spare).

### 5.5 Pacer and capture interaction

**USB LS (1.5 Mbit/s = 32.0 clocks/bit).**  The 24.8 fixed-point pacer is exact
here (`period = 32*256 = 0x2000`), which is why the existing pacer, not a
divider, is the right timing source.  Division of labour: the NRZI encoder owns
the bit clock during a packet (its `DIV` register is written 32 once), so a
`PACE` slip or a firmware stall cannot corrupt the line; the engine pacer is
used *between* packets (inter-packet gap, SOF cadence 1 ms = 48,000 cycles,
reset debounce 2.5 us = 120 cycles).  Capture is still useful: 20.8 ns
resolution is 1/32 of a bit, so firmware can measure bit width, SE0 duration
and SOF jitter from timestamps without a logic analyser.

**Ethernet MII (2.5 MHz nibble clock from the PHY).**  TX_CLK is generated by
the PHY, so firmware must follow it — the existing demo does `WAITP` on the
TX_CLK pin each nibble.  That costs instructions per nibble; the recommended
serializer takes TX_CLK as an assist input and emits nibbles itself.  The
pacer is not the right tool for MII TX (it cannot follow an external clock);
the capture unit is, because it timestamps the TX_CLK/RX_CLK edges for
diagnostics.  For the RX direction, RX_DV/RX_CLK capture plus a nibble
deserializer is the natural use of the capture unit's edge FIFO.

**Manchester (10BASE-T).**  Two separate facts, both from `research/protocols.md`
and re-checked against the RTL:

* at 48 MHz a half-bit is 2.4 clocks, so any encoder places edges on a 20.8 ns
  grid: peak edge error ±10.4 ns.  A 24.8 pacer would keep the *average* exact
  (2.4 cycles, fraction 102/256 = 0.399, error 0.02% over a byte) and bound the
  accumulated error, so the ±20 ns no-TPM criterion is reachable and ±11 ns
  with TPM is marginal.  What is impossible is doing it in firmware: 2.4 clocks
  per half-bit is less than one instruction plus a pin write;
* therefore the Manchester encoder assist is mandatory for any direct
  10BASE-T attempt, and it is still not an 802.3-compliant PHY at 48 MHz
  (R1).  The assist is specified for an 80 MHz (OS=4) or 160 MHz (OS=8) core;
  on this ASIC it is exercised in the FPGA/bench build only.

**Capture at 48 MHz** cannot replace the Manchester decoder (2.4 samples per
half-bit vs a ±13.5 ns receive requirement) but is adequate for JTAG/SWD
(4-8 clocks per TCK/SWCLK edge at 6-8 MHz), which is why no JTAG/SWD assist is
in the recommended set.

---

## 6. Firmware and the 3-engine cutover

Measured program sizes with `PROG_DEPTH=32` (assembler, `sim/test_protocols.py`):

| program | words | engines |
|---|---:|---|
| `uart_tx.asm` | 18 | 1 |
| `uart_rx.asm` | 26 | 1 |
| `spi_master.asm` | 32 | 1 (all 32) |
| `i2c_master.asm` | 32 + 32 | 2 (not one 32-word program) |
| `ethernet_mii_tx.asm` | 32 (+ 29 for FCS) | 1 (+1) |

Concurrency with 3 engines:

* UART TX + UART RX + SPI: yes (18 + 26 + 32 into three separate memories);
* I2C + one other lane: yes, with I2C remapped from engines 3+2 to **1+2**
  (the task's proposed remap);
* UART RX + SPI + I2C at the same time: **no** — I2C still needs two engines at
  this ISA width.  That is the concrete price of the third engine and it
  should be accepted explicitly, not discovered later.

Instruction-capacity mitigations if concurrency matters more than area
`[INFERENCE]`: move the SPI byte shift to `shiftreg32` (its 32 words are all
pin twiddling) and move the MII/USB byte paths to the FIFO, which frees words
without new instructions.

### 6.1 Verification churn (exact)

| file | change | sites |
|---|---|---|
| `firmware/i2c_master.asm` | two `.engine` directives 3 -> 1 (+ header comment) | 2 |
| `sim/test_protocols.py` `proteus_i2c_master_pins` | `load_firmware(3)`->`(1)`, `load_program(3)`->`(1)`, two `push_wait(3,...)`, `RA_RUN 0x0C`->`0x06`, `pop_out(2)` unchanged, `for eng in (3,2)`->`(1,2)`, docstrings | 10 |
| `tb/top_stub_tb.v` | engine-3 window/program/FIFO assertions retargeted to engine 2 (or delete the 4th window checks) | 12 |
| `src/tt_um_proteus.v` | remove `u_eng3`, `hp_we[3]`, `hp_be[11:9]`, `e_*3` wires, `run_reg[3]`, capture push port 4 -> 3+edge, merge stage 4 -> 3, `run_mask`/`halted`/`err`/`ready` 4 -> 3 bits | ~40 lines |
| `formal/run.sh` + `formal/top_formal.sv` | probe/instance list for the removed engine; target run masks | ~10 |
| `docs/architecture.md`, `docs/isa.md`, `docs/programming.md` | 4 -> 3 engines, new register window 0x0600, new opcodes | 3 docs |
| `sim/test_smoke.py`, `sim/test_diff.py`, `tb/top_e2e_tb.v`, `tb/engine_smoke_tb.v` | no engine-3 dependence found; `test_diff` uses `u_eng0` only | 0 |
| `demos/*` | no engine-3 use found (`run_eth` uses 0/1/2, `run_demos` uses 0/1) | 0 |

Total: one firmware file, one sim module, one stub TB, the top, the formal
harness, three docs.  No test currently *requires* four engines for the
UART/SPI/I2C acceptance set; I2C is the only two-engine program.

---

## 7. Minimum assist set for <=32 instructions

| protocol path | assists required | why |
|---|---|---|
| USB LS device (TX and RX) | CRC5/16 + NRZI enc/dec + FIFO | 32 clocks/bit is too slow to bit-bang CRC and stuffing inside 32 words |
| Ethernet MII (external PHY) | CRC32 + FIFO + shift register/serializer | frame emission is 230 words and FCS is 29 words without them |
| 10BASE-T Manchester (direct) | Manchester enc/dec **in addition** | 2.4 clocks/half-bit cannot be firmware-placed |
| JTAG, SWD, PS/2, 1-Wire | none | <=6-8 MHz edges, capture + WAITP suffice |

Recommended set = all five blocks, CRC in the bit-serial configuration:
**60,590.57 um2**, 506,883.22 um2 total, 56.17% row, 93.6% of the 60% budget,
34,566.98 um2 headroom (prediction).

As built on the shipped tree the assists measure **59,854.90 um2** and the top
**519,233.80 um2 flat** = 57.54% row, 95.90% of the 60% budget,
**22,216.40 um2 spare** (`results/synth_v2_root.txt`), i.e. 12,350.58 um2 above
the prediction.

If a future 100 Mbit/s MII path is wanted, swap in the byte-at-a-time CRC
(+13,882.05 um2, total 520,765.27, 57.71%) rather than adding a second CRC.

---

## 8. Risks

| # | risk | evidence | severity | mitigation |
|---|---|---|---|---|
| R1 | Manchester at 48 MHz is not 802.3-compliant | 20.8 ns clock grid vs 50 ns half-bit: ±10.4 ns peak edge error; ±11 ns with TPM at 8.0/8.5 BT (`research/protocols.md` 6.3) | high for "Ethernet over Manchester", none for MII | sell MII (external PHY) as the Ethernet path; use the Manchester blocks only at 80/160 MHz (FPGA/bench) |
| R2 | NRZI packet tail loses the last byte | decoder PASSes on a perfect waveform (`tb_nrzi_wave.log`: 0x69 0xFE 0x00 0x5A exact); the closed loop (`tb_nrzi.log`) delivers only 0x69 0xFE 0x00 and emits 0x5A after the EOP (end state: encoder idle with an empty queue, decoder mid-byte `bcnt=1 acc=0x80`), because `eop_req` is a level evaluated at whichever byte boundary comes next; the encoder's strobe-level line code is correct (KJKJKJKK SYNC + 0x69 prefix) | high if shipped as-is | tag the queued byte with a `last` bit (or add a 2-deep queue with an explicit end-of-packet marker) so the EOP follows the marked byte; add a jittered-waveform test and re-run `tb_nrzi` |
| R3 | 3 engines lose one concurrent lane | I2C is 32+32 words; SPI uses all 32 | medium | accept explicitly; remap I2C to 1+2; optionally offload SPI/USB byte paths to assists |
| R4 | assist CSR/opcode glue not yet measured | not synthesised; budgeted 2,000 um2 `[INFERENCE]` | low | inside the 34,567 um2 predicted headroom (22,216.40 um2 measured headroom on the shipped tree); measure in the first integration run |
| R5 | pin ownership/arbitration | the merge has no assist source today | medium | assist-above-engine priority, per-assist PINCFG, open-drain/collision unchanged; verify with the existing collision and I2C tests |
| R6 | 64-deep shared program RAM (option C) | 205,419.98 um2 for 64 x 24 four-read-port flop RAM; 64:1 read mux | high (timing) | do not take C unless instruction capacity is the binding problem; if taken, register the fetch or split into two banks |
| R7 | critical path grows | existing longest path 62 levels, PC -> async RAM -> ALU -> regs (`results/area_full.md` 6) | medium | `LDAS`/`STAS` add only a 32:1 CSR read mux on the write-back side; re-check `yosys ltp` and the LibreLane `timing__setup__ws` |
| R8 | Ethernet FCS firmware correctness | **CLOSED**: `demos/run_eth.py` now matches `zlib.crc32` on all three vectors (0xE7C87B32 / 0x758D6336 / 0xED086180); the earlier 0x183784CD (missing final inversion) was a pre-fix revision | none | keep the three check values as regression vectors |

---

## 9. Implementation plan (ordered, each step gated)

1. **CRC assist integration.**  Add `crc_bit` + `LDAS`/`STAS`/`ASST` + the
   0x0600 host window.  Gate: the five check values (CRC-32/ISO-HDLC,
   CRC-16/USB, CRC-5/USB, CRC-7/MMC, CRC-16/XMODEM) read back correctly
   through both the host window and the opcodes; `sim/test_diff.py` still
   matches `tools/model.py`.
2. **FIFO + shift register + MII serializer.**  Chain FIFO -> CRC -> nibble
   serializer so a complete 64-byte frame with a correct FCS leaves the pads
   from a <=10-word program.  Gate: `demos/run_eth.py --budget` passes its FCS
   column and the emitter word count drops under 32.
3. **NRZI/Manchester.**  Close R2 (byte-boundary/EOP handshake; add a jitter
   profile), then an unassisted USB LS device packet (SYNC, PID, 8 data bytes,
   CRC16, EOP) in <=32 words; keep the Manchester pair for the 80 MHz FPGA
   build.  Gate: `tb_nrzi` and `tb_nrzi_wave` both pass.
4. **Engine cutover.**  Remove `u_eng3`, remap I2C to 1+2, update the files in
   section 6.1, re-run `sim`, `tb` and `formal` suites.  Gate: full suite green
   with 3 engines and the new register map.
5. **Close the loop.**  `scripts/synth_full.sh` on the new top — **done
   2026-11-03**: 519,233.80 um2 flat / 36,343 cells, inside the <=520,000 um2
   acceptance band used here but **12,350.58 um2 above** the 506,883.22 um2
   prediction (`results/synth_v2_root.txt`); then hand to LibreLane at 60% with
   65% as fallback.

Estimated gate risk: step 3 is the only one that can invalidate the plan
(USB LS correctness); steps 1, 2 and 4 are mechanical once the opcode decode
exists.
