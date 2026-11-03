# PROTEUS hybrid-assist area: measured blocks, engine-count options

Measured 2026-11-03 on the aarch64 host with `yosys 0.33` and the IHP
`sg13cmos5l` typical liberty, using the same mapping flow as
`scripts/synth_full.sh` (`synth` -> `dfflibmap -liberty` -> `abc -liberty` ->
`opt_clean` -> `stat -liberty`).  Every number below is a direct
`Chip area for module` line from a log in `studies/hybrid/logs/`.  Nothing in
this file is estimated unless the line is marked `[INFERENCE]`.

RTL under test (all new, Verilog-2005, `studies/hybrid/rtl/`):

| file | block |
|---|---|
| `crc_engine.v` | byte-at-a-time configurable CRC, 5..32 bit, reflected / non-reflected, runtime init/poly/xorout, independent byte bit order |
| `crc_bit.v` | the same engine with one LFSR step per clock (8 clocks per byte) |
| `manchester_enc.v` | IEEE 802.3 Manchester encoder with a one-deep byte queue, `HALF_DIV` clocks per half-bit |
| `manchester_dec.v` | 4x/8x oversampling Manchester receiver (2-FF sync, edge-snapped phase accumulator, half-cell majority samples) |
| `nrzi_enc.v` | USB LS NRZI encoder + bit stuffer + EOP generator |
| `nrzi_dec.v` | USB LS NRZI decoder + unstuffer + SYNC (sliding window, armed after SOP) + EOP/SE0 detector |
| `shiftreg32.v` | 32-bit bidirectional shift register, runtime width/bit order, byte push/pop, optional bit-stuff hook |
| `assist_fifo.v` | 16 x 8 byte-stream FIFO / mini-DMA with an assist drain port and burst counter |
| `prg_ram_shared.v` | program-RAM shape bench (same flop-array style as `proteus_engine.v`) |
| `cap_fifo_bench.v` | capture FIFO shape bench, parameterised push-port count |
| `merge_bench.v` | pin-fabric priority merge bench, parameterised engine count |

## 1. Exact commands

```sh
studies/hybrid/synth.sh        # all 20 synthesis runs, ~37 s on this host
studies/hybrid/tb/run.sh       # iverilog functional tests, logs in the same dir
```

Each synthesis run is, with `LIB` = the liberty file:

```sh
yosys -p "read_verilog <rtl>; [chparam -set P V <top>;] hierarchy -check -top <top>;
          synth -top <top>; dfflibmap -liberty $LIB; abc -liberty $LIB;
          opt_clean; stat; stat -liberty $LIB"
```

Liberty (pinned PDK `2bbec755dc67ca3db0261c3d6163e15735d66710`):

```
/home/ubuntu/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib
```

Flow control bench: the program-RAM bench at the engine's own shape
(`DEPTH=32`, `AW=5`, `NR=2` = instruction fetch + host read) measures
**86,653.14 um2**, against the 84,522.61 um2 that `results/area_full.md`
attributes to the engine's program memory.  The bench carries the same
`prog_written` flags and init fill, so it is a +2.5% upper control on that
shape; deltas between bench runs are used below, not absolute values.

## 2. Measured blocks

| block | parameters | cells | flops | area um2 |
|---|---|---:|---:|---:|
| `crc_engine` | runtime reflect, 8 steps/byte | 2,846 | 136 | **35,035.01** |
| `crc_engine` | `FIXED_REFLECT=0`, 8 steps/byte | 1,579 | 135 | 22,730.77 |
| `crc_engine` | `FIXED_REFLECT=1`, 8 steps/byte | 1,235 | 135 | 17,924.42 |
| `crc_bit` | runtime reflect, 1 step/clock | 1,310 | 135 | **21,152.96** |
| `crc_bit` | `FIXED_REFLECT=1`, 1 step/clock | 729 | 134 | 12,522.95 |
| `manchester_enc` | `HALF_DIV=4` (20 Mbaud at 80 MHz) | 159 | 32 | **2,881.19** |
| `manchester_enc` | `HALF_DIV=8` (20 Mbaud at 160 MHz) | 157 | 32 | 2,852.16 |
| `manchester_dec` | `OS=4` (80 MHz) | 162 | 36 | **2,991.95** |
| `manchester_dec` | `OS=8` (160 MHz) | 146 | 36 | 2,857.68 |
| `nrzi_enc` | `AW=6`, div=32 at 48 MHz | 249 | 43 | **4,069.62** |
| `nrzi_dec` | `AW=6`, div=32 at 48 MHz | 410 | 72 | **6,685.80** |
| `shiftreg32` | 32 bit, runtime width/order/stuff | 799 | 47 | **10,411.25** |
| `assist_fifo` | `DEPTH=16`, `AW=4` | 446 | 151 | **12,397.80** |
| `assist_fifo` | `DEPTH=8`, `AW=3` | 262 | 82 | 6,764.05 |
| `prg_ram_shared` | `DEPTH=32`, `AW=5`, `NR=2` (engine shape) | 3,481 | 806 | 86,653.14 |
| `prg_ram_shared` | `DEPTH=32`, `AW=5`, `NR=4` | 4,008 | 806 | 106,020.04 |
| `prg_ram_shared` | `DEPTH=64`, `AW=6`, `NR=4` (3 PCs + host) | 9,256 | 1,607 | **205,419.98** |
| `cap_fifo_bench` | `NPUSH=5` (4 engines + UIO edge) | 1,938 | 154 | 24,336.77 |
| `cap_fifo_bench` | `NPUSH=4` | 1,629 | 154 | 22,453.16 |
| `merge_bench` | `NENG=4` | 192 | 0 | 2,264.37 |
| `merge_bench` | `NENG=3` | 160 | 0 | 1,683.76 |

### 2.1 What the CRC numbers say

The 8-step unroll is expensive because the direction (`reflected`) is a
runtime config bit: every step carries a 32-bit 2:1 select between the
left-shifting and right-shifting forms.

* runtime direction, 8 steps: **35,035.01 um2**
* runtime direction, 1 step: **21,152.96 um2** (8 clocks per byte)
* direction tied at synthesis: 17,924.42 (8 steps) / 12,522.95 (1 step)

Both variants are functionally identical (section 3).  The bit-serial variant
is the right choice for this chip: at 48 MHz a 10 Mbit/s MII byte arrives
every 38.4 clocks and a 1.5 Mbit/s USB LS byte every 256 clocks, so 8 clocks
per byte is free and 13,882.05 um2 cheaper.

### 2.2 Engine-count inputs (from `results/area_full.md`)

| quantity | um2 |
|---|---:|
| engine 0 / 1 / 2 / 3 | 132,227.12 / 132,306.12 / 132,234.76 / 132,381.80 |
| 4 engines | 529,149.80 |
| 3 engines (0..2) | 396,768.00 |
| program RAM per engine (of which) | 84,522.61 |
| 3 engines, logic only (3 x 47,988.28) | 143,200.17 |
| host SPI slave | 12,503.60 |
| top glue, 4 engines | 39,485.28 |
| capture FIFO inside that glue | 27,504.34 |

Glue for 3 engines, from this study's benches:

```
glue3 = 39,485.28 - (24,336.77 - 22,453.16) - (2,264.37 - 1,683.76)
      = 39,485.28 - 1,883.61 - 580.61 = 37,021.06 um2
```

The remaining per-engine top logic (RUN/HALT bit, assert record mux, barrier
arm, window decode) is inside the 11,980.94 um2 non-capture residue and is not
re-measured here; it is bounded by 11,980.94 / 4 = 2,995.24 um2
`[INFERENCE]`, i.e. under 0.6% of every option below.

### 2.3 Assist-set totals

| set | composition | um2 |
|---|---|---:|
| **all five blocks, byte CRC** | crc_engine(rt) + manch enc/dec + nrzi enc/dec + shiftreg32 + fifo16 | **74,472.61** |
| **all five blocks, bit CRC** (minimum set) | crc_bit(rt) + manch enc/dec + nrzi enc/dec + shiftreg32 + fifo16 | **60,590.57** |
| MII-only (no Manchester) | crc_bit + nrzi enc/dec + shiftreg32 + fifo16 | 54,717.43 |
| USB LS only | crc_bit + nrzi enc/dec + fifo16 | 44,306.18 |

## 3. Functional status of the measured blocks

Scripts: `studies/hybrid/tb/run.sh` (iverilog 14.0), logs
`studies/hybrid/logs/tb_*.log`, vectors
`studies/hybrid/tb/gen_crc_vectors.py` and `tb/nrzi_wave.hex`.

| test | result | evidence |
|---|---|---|
| CRC engine, 5 protocol configs (`tb_crc.log`) | **PASS** | 16-byte stream per config matches the reference model; each configuration also reproduces its published check value over `"123456789"`: CRC-32/ISO-HDLC 0xCBF43926 (and `zlib.crc32` agrees), CRC-16/USB 0xB4C8, CRC-5/USB 0x19, CRC-7/MMC 0x75, CRC-16/XMODEM 0x31C3 |
| Manchester encoder -> decoder loopback (`tb_manchester.log`) | **PASS** | 6 bytes at `HALF_DIV=4` / `OS=4`; the decoded bit stream contains the exact 48-bit transmitted pattern (`hist=aa55807f00ff0000`), decoder locks, no phase or Manchester violation while the transmitter is active, encoder overflow clear |
| 16 x 8 assist FIFO (`tb_fifo.log`) | **PASS** | host fill/read order, level, assist drain, burst counter/IRQ, full/overflow guard |
| 32-bit shift register (`tb_shiftreg.log`) | **PASS** | 12-bit MSB-first and LSB-first shifts, byte push/pop, stuff hook inserts a 0 after 2 ones with `stuff_len=3` and holds the register |
| NRZI decoder vs a perfect J/K waveform (`tb_nrzi_wave.log`) | **PASS** | `nrzi_wave.hex` (idle J, then 0x80 0x69 0xFE 0x00 0x5A, with the 0xFE stuffed bit): `sync_det` asserts and the four bytes after SYNC decode exactly 0x69 0xFE 0x00 0x5A, no stuff error |
| NRZI encoder -> decoder closed loop with EOP (`tb_nrzi.log`) | **FAIL (1 byte)** | the testbench expects the four bytes the decoder emits by design (SYNC is reported by `sync_det`, not `dout_valid`); three arrive exactly (0x69 0xFE 0x00) and 0x5A is emitted after the EOP: at the end the encoder is idle with an empty queue and the decoder is mid-byte (`bcnt=1 acc=0x80`). The encoder's strobe-level line code is correct (KJKJKJKK SYNC and the 0x69 prefix verified) and the decoder is correct on a perfect waveform, so the remaining defect is the packet-tail handshake (`eop_req` is a level evaluated at whichever byte boundary comes next), not the line code |

NRZI is a working prototype, not sign-off quality: risk R2 in
`docs/hybrid-architecture.md`.  The measured RTL is the one in this table, so
the area numbers already include the current logic.

## 4. Option areas

Row area 902,417 um2 (`results/area_full.md`); 60% budget 541,450.20;
65% target 586,571.05; 68.9% precedent 621,765.31.  "all" = the 74,472.61
five-block set with the byte CRC; "min" = the 60,590.57 set with the
bit-serial CRC.

| option | arithmetic | area um2 | row % | % of 60% budget | margin vs 60% |
|---|---|---:|---:|---:|---:|
| shipped, 4 engines, no assists | measured | 581,138.67 | 64.40 | 107.3 | −39,688.47 |
| A: 4 engines + all assists | 581,138.67 + 74,472.61 | **655,611.28** | 72.65 | 121.1 | −114,161.08 |
| A': 4 engines + min assists | 581,138.67 + 60,590.57 | 641,729.24 | 71.11 | 118.5 | −100,279.04 |
| B: 3 engines + all assists | 396,768.00 + 37,021.06 + 12,503.60 + 74,472.61 | **520,765.27** | 57.71 | 96.2 | +20,684.93 |
| B': 3 engines + min assists | same with 60,590.57 | **506,883.22** | **56.17** | **93.6** | **+34,566.98** |
| C: 3 engines + all + 64-deep shared PRAM | 143,200.17 + 205,419.98 + 37,021.06 + 12,503.60 + 74,472.61 | **472,617.42** | 52.37 | 87.3 | +68,832.78 |
| C': 3 engines + min + 64-deep shared PRAM | same with 60,590.57 | 458,735.37 | 50.83 | 84.7 | +82,714.83 |

Sensitivity, `[INFERENCE]` (engine delta from the measured 32->24 depth sweep,
37,021.06 glue held):

| option | area um2 | row % | % of 60% budget |
|---|---:|---:|---:|
| 4 engines at PROG_DEPTH=24 + min assists | 557,206.63 | 61.75 | 102.9 |

The 64-deep shared store replaces 3 x 84,522.61 = 253,567.83 um2 of per-engine
program RAM with 205,419.98 um2 measured for a 64 x 24, four-read-port flop
array: a saving of 48,147.85 um2, at the cost of 64 total instruction words for
three engines instead of 96.

Flat mapping (`synth -flatten`) removed 3.9% in the shipped run
(`results/area_full.md`); the hierarchical numbers above are the conservative
ones.  Applying the same factor (0.96059): A 629,779, A' 616,444, B 500,246,
B' 486,911, C 453,995, C' 440,660 `[INFERENCE: same ratio]`.

## 5. Caveats

* Cell area only: no filler/tap/decap, no clock tree, no routing.  This is how
  `PL_TARGET_DENSITY_PCT` is applied, so the 60% comparison is like for like.
* `abc -liberty` with no delay target; the area numbers are not timing-signed.
  `sta`/`openroad` are not installed on this host.
* Hierarchical sums overcount against a flat mapping by the 3.9% measured in
  `results/area_full.md`.
* All assist blocks are measured standalone.  Their integration glue (CSR
  decode, opcode decode, pin muxing into the fabric) is not in these numbers
  and is budgeted separately in `docs/hybrid-architecture.md`.
