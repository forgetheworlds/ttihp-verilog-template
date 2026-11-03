# Verification

Methodology, the exact command for every claim, the current result of each, and
an explicit list of what is **not** verified. This document is written to be
useful to a reviewer who wants to reproduce or falsify something, so it quotes
failures as precisely as passes.

Tree under test: the hybrid v2 root (`src/`, 12 files, 3 engines + 5 assists,
`VERSION 0x02`). v1 is archived at `legacy/v1/` and still owns the evidence it
alone produced (top-level formal, FPGA, the 4-engine area number).

## 0. Snapshot and provenance

Every command below was run on **2026-11-03** on this aarch64 host against the
tree as shipped. v2 work has its own report files, which carry the source
hashes and the exact command for each number:

| report | contents |
|---|---|
| `v2/results/v2_verify.md` | TT harness + protocol E2E on the hybrid RTL, defect D1 and its regression |
| `v2/results/v2_diff_formal.md` | 209-program differential and the engine formal suite |
| `v2/results/v2_mutation.md` | 99-mutant mutation run and survivor analysis |
| `results/flow_report.md` | six LibreLane attempts, area, post-GRT STA, flow conclusion |
| `v2/results/synth_v2.txt` | Yosys hierarchical + flat area for the 12-file tree |

`v2/results/synth_v2.txt` lists the sha256 of all 11 `.v` files it synthesised;
`src/proteus_defs.vh` is an include and is not in that list. A number without a
corresponding artifact in this table is not a measurement.

---

## 1. Layers, and what each can catch

| # | layer | artifact | catches | cannot catch |
|---|---|---|---|---|
| 1 | encoding conformance | `tools/isa.py` assertions, `tools/asm.py` | field layout, opcode width, operand arity, assist names/commands, depth limits | anything about hardware |
| 2 | toolchain self-check | `tools/selfcheck.py` | LDAS/STAS/ASST round-trip, the five CRC check values, model FIFO/`nf` semantics | RTL behaviour |
| 3 | model-level protocol E2E | `demos/run_demos.py` | UART autobaud, WS2812, UART↔SPI bridge framing vs independent decoders | RTL bugs; anything about pads |
| 4 | RTL unit benches | `tb/tb_crc_bit.v`, `tb/tb_fifo.v`, `tb/tb_shiftreg.v`, `tb/tb_nrzi*.v`, `tb/tb_manchester.v` | each assist's datapath | integration |
| 5 | RTL top benches | `tb/tb_csr.v`, `tb/tb_top_smoke.v`, `tb/engine_smoke_tb.v`, `tb/top_e2e_tb.v` | assist CSR bank, engine 2 pages, RUN mask, arbitration, pin ownership, capture, barriers, handover | model agreement |
| 6 | cocotb through the real host SPI | `test/` | the Tiny Tapeout submission gate: identity, program load, run, pads | protocol content |
| 7 | cocotb protocol E2E on the RTL | `sim/test_protocols.py` | UART TX/RX, SPI, I2C, Ethernet MII decoded at the pads by independent models | host throughput; gate level |
| 8 | DUT-vs-model differential | `sim/test_diff.py` + `tools/diffgen.py` | the whole architectural surface, every cycle | assist data paths (excluded by design); multi-engine interaction |
| 9 | formal | `v2/formal/` | engine invariants over all inputs within a depth | behavioural equivalence; X |
| 10 | mutation | `tools/mutate.py` | whether the benches notice a plausible bug | coverage of code the catalogue does not mutate |
| 11 | synthesis / area / timing | `v2/results/synth_v2.txt`, `results/flow_report.md` | cell area; post-GRT STA | functional correctness; routed sign-off |
| 12 | gate-level simulation | **not run** | - | - |

---

## 2. Current evidence

### 2.1 Tiny Tapeout submission harness (layer 6)

```sh
PATH=$PWD/.venv/bin:$PATH make -C test
```

```
147690.00ns INFO  cocotb.tb  identity ok (VERSION 0x02)
147690.00ns INFO  cocotb.tb  program loaded and verified over SPI (13 words)
147690.00ns INFO  cocotb.tb  engine 2 page ok; 0x0400 outside the 3-engine map
147690.00ns INFO  cocotb.tb  RUN retired by HALT
147690.00ns INFO  cocotb.tb  register readback ok
** TESTS=1 PASS=1 FAIL=0 SKIP=0        147690.00    2.18 s **
```

Covered over the pads only, so the same test can run on a netlist with
`GATES=yes`: identity `[0x50, 0x52, 0x02]`, `PING` = `0x50`, a 13-word program
loaded and read back word for word, engine 2's page (`0x0300`), `0x0400` proven
outside the map, `RUN` retired by `HALT`, `E_STATUS.halted = 1`, `E_PC = 12`,
`r0 = 0x5A`, `uio[0]` toggled 6 times and parked low.

### 2.2 Protocol E2E on the RTL (layer 7)

```sh
cd sim && make            # = make protocols, COCOTB_TEST_MODULES=test_protocols
```

```
test_protocols.proteus_v2_map                 PASS
test_protocols.proteus_uart_tx_pins           PASS
test_protocols.proteus_uart_rx_pins           PASS
test_protocols.proteus_spi_master_pins        PASS
test_protocols.proteus_i2c_master_pins        PASS
test_protocols.proteus_ethernet_mii_tx_pins   PASS
** TESTS=6 PASS=6 FAIL=0 SKIP=0      9352290.01 ns   76.69 s **
```

Check counts decoded from the pads: v2 map 25, UART TX 18, UART RX 6, SPI 123,
I2C 30, MII TX 34 = **236 checks** (`v2/results/v2_verify.md` §2.2, §4). One
test can be re-run alone with
`make COCOTB_TEST_FILTER=proteus_ethernet_mii_tx_pins`.

What the pads showed (full detail in `v2/results/v2_verify.md` §4):

- **UART TX** (engine 0, `UIO[0]`): bytes `00 ff 55 aa 41`, frame-start deltas
  `[4343, 4343, 4343, 4343]` against ideal 4340.27, measured bit period 434.03.
- **UART RX** (engine 1, `UIO[1]`): nine source frames including one with a low
  stop bit; `OUT_FIFO` yielded `55 00 ff 81 7e a5 5a 3c 00` byte-exact,
  `E_ERROR[0] = 1`.
- **SPI** (engine 2, `UIO[2..5]`): six transfers, every SCK half phase exactly
  25 cycles, no SCK edge while CS is high.
- **I2C** (engines 2 + 1, `UIO[6]/[7]`): START/RSTART/STOP, ACKs
  `[0,0,0,0,0,1]`, one 400-cycle stretch, bus bytes `5a a5` / `11 22`.
- **Ethernet MII TX** (engine 0 + CRC/FIFO assists): 144 nibbles = 72 wire
  bytes, FCS `32 7b c8 e7` = `0xE7C87B32` equals `zlib.crc32(dst..payload)`,
  zero TXD changes while TX_CLK is high, setup min/median 498/498 cycles.

**The Ethernet gate is rate-limited, not content-limited.** The PHY model clocks
TX_CLK with a 500-cycle half period because the host port cannot sustain
10 Mbit/s: one wire byte every 40 clk needs a host byte every 0.8 us against a
~280 clk (5.6 us) SPI frame. The 16-byte assist FIFO carries content, not
sustained line rate.

**Defect D1, found by this gate and fixed.** `PROTEUS_PM_END` was `0x02FF`
(space for two engines), so engine 2's page `0x0300..0x03FF` could not be
loaded: two of the five firmware images were dead on arrival. The fix is the
constant `0x03FF`, and the `proteus_v2_map` test above is its permanent
regression (`v2/results/v2_verify.md` §5).

### 2.3 DUT vs model, every cycle (layer 8)

```sh
cd sim && make diff        # DIFF_SEEDS=200, DIFF_CYCLES=3000
```

```
9737490.00ns INFO  test  DIFF PASS: 209 programs, 16122 compared cycles, 0 mismatches (0 cut at the 3000-cycle limit)
test_diff.proteus_diff         PASS     9737490.00         107.51
** TESTS=1 PASS=1 FAIL=0 SKIP=0  9737490.00   107.51 **
```

Corpus and verdict, from `v2/results/v2_diff_formal.md` §1.3 (same contract; the
run above reproduces the simulated time exactly):

| item | value |
|---|---|
| programs compared | 209 / 209 (200 seeded + 9 crafted corners) |
| compared cycles | **16,122** |
| mismatches | **0** |
| programs cut at the 3000-cycle limit | 0 |
| simulated time | 9,737,490 ns @ 10 ns clock |
| opcodes exercised | 69 of 75 (`missing_required=[]`); the three assist opcodes are excluded by design, as are `MOVI`/`NOP`/`ASSERT` |

Every architectural register, PC, flags, pins, FIFO contents/counts, capture
events, IRQ and collision is compared each cycle. The other two engine lanes are
asserted idle every cycle in v2, so a `run_reg` or engine-index miswire cannot
hide behind an unexercised lane. Negative control: mutating `INC` in the model
(`ADD a,1` -> `ADD a,2`) produced
`DIFF MISMATCH seed=0 kind=alu cycle=5996 field=r6 model=0x2 rtl=0x1`, then the
file was reverted (`v2/results/v2_diff_formal.md` §1.4).

Not covered: assist instructions (`LDAS`/`STAS`/`ASST`) are excluded because the
model does not model their data path; multi-engine interaction is not exercised
(the other lanes are idle); the host address map is not in the model (it is
gated by `proteus_v2_map`).

### 2.4 RTL benches (layers 4 and 5)

```sh
bash tb/run.sh
```

```
crc_bit        TB_CRC_BIT PASS
fifo           TB_FIFO PASS
shiftreg       TB_SHIFTREG PASS
nrzi           TB_NRZI PASS
nrzi_wave      TB_NRZI_WAVE PASS
manchester     TB_MANCHESTER PASS
csr            TB_CSR PASS (37 checks)
top_smoke      TB_TOP_SMOKE PASS (19 checks, 7 pad edges)
engine_smoke   ==== PASS: all engine smoke checks passed (237 checks) ====
top_e2e        top_e2e_tb PASSED

benches PASS=10 FAIL=0
```

`top_e2e_tb` reports **400 checks, 0 errors** in its own log
(`v2/results/v2_mutation.md` §2.2). The v2-only assertions are the ones that
matter for this build: engine 2's page and the 3-bit `RUN` mask (`[4c]`), the
assist CSR window and arbitration (`[4d]`), and assist pin ownership with the
push-pull stage (`[4e]`). `tb_nrzi` is a closed loop over four bytes with EOP;
`tb_nrzi_wave` decodes a perfect USB LS waveform. The study copy of the NRZI
pair lost the last byte (`results/hybrid_area.md` §3, defect R2); the shipped
pair passes the four-byte check, and no USB protocol demo exists beyond that.

### 2.5 Toolchain self-check (layers 1–2)

```sh
python3 tools/selfcheck.py
```

```
  ok CRC config 4: 0x00006346 == 0x00006346
== model program through LDAS/STAS/ASST
  ok out FIFO order ['0xa5', '0x5a', '0x20']
  ok empty LDAS set nf_flag
  ok empty LDAS left rd unchanged (0x20)
  ok HALT retired RUN

SELFCHECK PASS
```

Three claims, each unambiguous (`tools/selfcheck.py` docstring): every new
opcode round-trips assemble -> disassemble -> assemble; the model's CRC assist
reproduces all five study vectors including `zlib.crc32`; and a model program
built from `LDAS`/`STAS`/`ASST` reproduces the RTL semantics the benches check
(FIFO order, empty-read rule, STATUS bits).

**There is no pytest suite in the v2 tree.** v1's suite (179 tests) is archived
at `legacy/v1/tools/tests/` and was not re-run against v2; the replacement above
covers the new tool surface only. This is a real reduction in layer-1/2 coverage
and is listed again in §3.

### 2.6 Model-level demos (layer 3)

```sh
python3 demos/run_demos.py
```

```
demo      config                   measured                traffic      result
--------  -----------------------  ----------------------  -----------  ------
autobaud  48000k/9600              d=5003 T=5000 P=640000  6/6 bytes    PASS
autobaud  48000k/19200             d=2503 T=2500 P=320000  6/6 bytes    PASS
autobaud  48000k/57600             d=835 T=832 P=106496    8/8 bytes    PASS
autobaud  48000k/115200            d=419 T=416 P=53248     8/8 bytes    PASS
autobaud  48000k/250000            d=195 T=192 P=24576     8/8 bytes    PASS
autobaud  50000k/115200            d=437 T=434 P=55552     8/8 bytes    PASS
autobaud  115200 framing           err=1 d=419             2/2 bytes    PASS
ws2812    48000k ws2812.asm        T0H=19 T1H=38 P=60..60  9/9 bytes    PASS
ws2812    50000k ws2812_50mhz.asm  T0H=20 T1H=40 P=62..63  9/9 bytes    PASS
bridge    48k/115200               uart=32 spi=32 short=0  32/32 bytes  PASS
bridge    48k/57600                uart=32 spi=32 short=0  32/32 bytes  PASS

pacer probe @cycle 2^24: 100 completions in 9802 cycles (period=100) -> 98.0 cycles/completion: exact

baseline autobaud_uart_rx.txt: matches
baseline ws2812.txt: matches
baseline uart_spi_bridge.txt: matches

RESULT: PASS
```

**11 of 11 demo runs PASS**, and the three recorded baselines match byte for
byte. Every pass is decoded by a model that shares no code with the firmware
(16x UART receiver, pulse-width WS2812 decoder, mode-0 SPI checker). This is
model-level evidence, not RTL.

### 2.7 Formal (layer 9)

```sh
./v2/formal/run.sh        # sby prove + cover, engine suite, 462 s wall
```

`v2/results/formal_summary_v2.txt` (verbatim, engine rows):

```
PROP  DEPTH  PROVE     COVER            NOTE
E0    40     FAIL      REACHED(1/1)     control: FAIL is EXPECTED (probe liveness)
E1    40     PASS      REACHED(1/1)
E2    40     PASS      REACHED(2/2)
E3    40     PASS      REACHED(1/1)
E4    48     PASS      REACHED(1/1)
E4B   40     PASS      REACHED(1/1)
E5    40     PASS      REACHED(1/1)
E6    40     PASS      REACHED(2/2)
E7    40     PASS      REACHED(1/1)     bounded proof ok; induction step did not converge
E8    40     PASS      REACHED(1/1)
E9    40     PASS      PARTIAL(4/5)      one audit cover unreachable by construction
E10   40     PASS      REACHED(1/1)
E11   40     PASS      REACHED(1/1)
```

E0 is the negative control: it asserts a deliberately wrong bound and the
solver produces a counterexample at step 6, which proves the probes are bound to
the DUT. E9 is a cover-only audit (no assertion), so its `PASS` means "the cover
task ran", not a proof; 4 of its 5 milestones are reached and `halted` is not
because that program loops forever by construction. E7 is a bounded proof at
depth 40, exactly as in v1.

Not ported: the top-level T1-T7 suite and the X-freedom bench. Their only
evidence is the v1 run (`results/formal_summary.txt`, §3 below).

### 2.8 Mutation testing (layer 10)

```sh
python3 tools/mutate.py --verify-mutations    # 99/99 mutation specs apply cleanly
python3 tools/mutate.py --all                 # ~16 min
```

`v2/results/v2_mutation.md` §3.2:

```
mutations: 99  KILLED=95  SURVIVED=4
kill rate: 95/99 = 96.0% (survivors 4)
kills per bench: engine=49/99  top=64/99
elapsed: 969.1s
```

The four survivors are shown equivalent, not gaps: `C05` (explicit PC wrap is
redundant at a power-of-two depth), `H04` (dead assignment overwritten on the
same bit period), `T11` (the masked engine ignores the cycle in which the
difference exists) and `T16` (3-bit to 4-bit zero-extension of `err_mask`).
First-pass score was 83.8 %; the 16 survivors were triaged and 12 real gaps were
closed with minimal assertions, each with a measured kill (`v2/results/
v2_mutation.md` §4–§5). The catalogue mutates engine, host, top and assist
*registers/pin logic*; the five assists' internal datapaths are covered by their
own unit benches, not by this score (§6 of that report). `results/mutation.md`
and `results/mutation_raw.txt` at the root are the superseded **v1** 57-mutant
run; the v2 evidence is `v2/results/`.

### 2.9 Synthesis, area and timing (layer 11)

```sh
scripts/synth_full.sh            # hierarchical + flat; default OUT=results/synth_full.txt
                                 # sign-off log: results/synth_v2_root.txt
                                 # (v2/results/synth_v2.txt is superseded, see below)
```

`results/synth_v2_root.txt`, `Chip area` lines (line numbers in the log):

```
l. 19254  Chip area for top module '\tt_um_proteus': 538016.131800   # hierarchical sum
l. 47230  Chip area for module '\tt_um_proteus': 519233.803200       # flat (-flatten)
l. 47202  Number of cells:              36343
```

| quantity | value | source |
|---|---:|---|
| flat (sign-off) area | **519,233.80 um2**, 36,343 cells | `results/synth_v2_root.txt` l. 47230 / 47202 |
| hierarchical sum | 538,016.13 um2 (59.62 %) | same, l. 19254 |
| row utilisation | **57.54 %** of 902,417 um2 | arithmetic |
| 60 % placement budget (541,450.20 um2) | 95.90 %, 22,216.40 um2 spare | arithmetic |
| vs study option B' prediction (506,883.22 um2) | **+12,350.58 um2 (+1.37 pp) above** | arithmetic |
| post-GRT STA, 20 ns `nom_typ` | setup **+11.0205 ns**, hold **+0.2878 ns** | `results/flow_report.md` |

**Area provenance.** The earlier v2 record — `v2/results/synth_v2.txt`,
497,927.19 um2 flat / 33,936 cells / 55.18 % — is **superseded**; it is not the
sign-off number and should not be quoted for this tree. The script printed in
that log, re-run today on the identical 11 source sha256 values with the same
yosys 0.33 and the same liberty cell library, produces 519,233.80 um2 /
36,343 cells, twice, deterministically (`/tmp/flat_a.log`, `/tmp/flat_b.log`;
three independent runs agree in `results/final_evidence.md` §3.2). So
**519,233.80 um2 / 36,343 cells is the sign-off figure**. The 21,306.61 um2
(+4.28 %) difference is unexplained — the per-module hierarchical areas moved
the same way, e.g. the third engine maps to 131,313.72 um2 today against
132,695.96 in the old log — and is recorded rather than assumed away
(`results/final_evidence.md` §3.2). Both values are inside the 60 % budget, so
the three-engine decision does not turn on it. Filler counts in
`results/flow_report.md` (641,029 um2 / 48,738 instances) belong to that earlier
flow run and are not reproduced here.

No routed GDS exists locally. `make flow` was attempted six times against this
host and stalled in OpenROAD detailed routing with an identical signature:
0-byte `openroad-detailedrouting.log`, empty `drt-run-0/`, no DRC or unrouted-net
report, 40 min to 3 h 27 min wall, at both placement targets tried (v1 at
`PL_TARGET_DENSITY_PCT=65`, this tree at 60 — the placement knob, distinct from
the 57.54 % measured cell area). The image
ships one OpenROAD binary (`dcf36133...`) and LibreLane exposes no override while
the 1x1 smoke flow completes, so this is an aarch64 runtime block, not a density
verdict. The authoritative sign-off is the repository's GitHub `gds.yaml` action
on x86_64 (`TinyTapeout/tt-gds-action@ihp-cmos5l`). Full attempt table:
`results/flow_report.md`.

Snapshot caveat carried from that report: the v2 flow ran on the `v2/src`
snapshot that predates the approved `PROTEUS_PM_END 0x03FF` constant fix. That is
a compare-range constant with no area or timing effect, but the final flow must
run on the shipped tree.

---

## 3. What is not verified (read before trusting a claim)

1. **No routed GDS, no DRC/LVS, no antenna check, no slow-corner timing.** The
   local flow stalls in DRT (`results/flow_report.md`); only the GitHub
   `gds.yaml` action can close this. The +11.02/+0.29 ns numbers are post-global-
   route, typical corner, before routing parasitics.
2. **No gate-level simulation.** `test/Makefile GATES=yes` keeps the branch, but
   no v2 netlist exists to run it against.
3. **Top-level formal is v1-only.** T1-T7 and X1 live in `results/
   formal_summary.txt`; T1/T2/T5/T6 pass with unreached covers (vacuous at depth
   20), T4 is a documented interface contract, and **T7 is OPEN** (HALT-instr
   antecedent needs >70 SPI clocks). Nothing in that table was re-proved for the
   three-engine top.
4. **FPGA is v1-only.** `fpga/` (and `legacy/v1/fpga/`) target the four-engine
   v1 top. The recorded v1 result is 36 checks, 0 errors; no v2 DE2 build or
   result exists.
5. **Assist data paths are outside the differential.** `LDAS`/`STAS`/`ASST` are
   excluded from the 209-program corpus by assertion, because the model does not
   model CRC bit order, shift framing, NRZI or Manchester. Their evidence is the
   unit benches, `tb_csr`/`top_e2e`, `selfcheck.py` and the MII pad test.
6. **Ethernet is host-bandwidth-bound.** Content and pad protocol are proven at
   a slowed TX_CLK; 10 Mbit/s sustained needs a wider FIFO or a faster host
   port. No MAC, no PHY, no 10BASE-T on the wire.
7. **USB LS and 10BASE-T are not implemented as protocols.** The NRZI and
   Manchester assists exist, are instantiated and are unit-benched, and the
   Manchester block is specified for an 80/160 MHz core, not this 50 MHz ASIC
   (risk R1 in `docs/hybrid-architecture.md` §8). No USB or 10BASE-T firmware or
   pad test exists.
8. **JTAG is partial and is v1 evidence only.** The v1 stretch experiment
   (`results/stretch.md`) reads IDCODE `0x5B5B5B5B` exactly and walks 12 of 16
   TAP states, but BYPASS and Pause/Exit2 are not implemented; the firmware is
   not in the v2 tree.
9. **No pytest suite in v2.** Layer-1/2 coverage is `tools/selfcheck.py`; the
   179 v1 tests are at `legacy/v1/tools/tests/` and were not re-run.
10. **No silicon.** Shuttle is March 2027. Every "measured" number here is
    simulation or synthesis, not a part.
11. **Mutation score is for the benches, not the assists' internals**
    (`v2/results/v2_mutation.md` §6), and the root `results/mutation.md` is the
    superseded v1 57-mutant record.

---

## 4. Reproduce everything

```sh
# 1. Tiny Tapeout gate (pads only)
PATH=$PWD/.venv/bin:$PATH make -C test

# 2. protocol E2E on the RTL (6 tests, 236 checks)
cd sim && make && cd ..

# 3. DUT vs model, every cycle (209 programs, 16,122 cycles)
cd sim && make diff && cd ..

# 4. directed RTL benches (10 benches)
bash tb/run.sh

# 5. toolchain self-check
python3 tools/selfcheck.py

# 6. model-level demos (11 runs)
python3 demos/run_demos.py

# 7. engine formal (E0 control + E1-E11 covers)
./v2/formal/run.sh

# 8. mutation score (99 mutants, ~16 min)
python3 tools/mutate.py --verify-mutations && python3 tools/mutate.py --all

# 9. area and timing
scripts/synth_full.sh
make flow          # stalls on aarch64; use the GitHub gds.yaml action
```
