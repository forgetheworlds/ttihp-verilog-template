# PROTEUS submission audit (hybrid v2)

Status as of the last run on this host, 2026-11-03. Every claim below names the
command or file that produces it. Anything not listed here is either unverified
or noted in "Known gaps" at the end.

The submitted design is the **hybrid v2** tree at the repository root: three
24-bit engines plus five protocol-agnostic assists, 12 RTL source files,
75 opcodes, `VERSION 0x02`. The previous four-engine build is frozen at
`legacy/v1/` and is no longer the submission.

## What is submitted

| item | state |
|---|---|
| `info.yaml` | `tiles: "6x4"`, 50 MHz, top `tt_um_proteus`, **12 source files**, 24 pins |
| `src/` | 3 engines, 5 assists, 24-bit ISA (75 opcodes), host SPI, pin fabric, capture, barriers, IRQ |
| `test/` + `.github/workflows/` | the Tiny Tapeout gate, adapted to the 12-file tree and passing |
| `docs/info.md` | project page (architecture, pinout, host protocol, demos, area) |
| `docs/architecture.md` | implementation contract, including assist CSR and pin priority |
| `docs/isa.md`, `docs/programming.md` | ISA (with `LDAS`/`STAS`/`ASST`) and programmer guide |
| `docs/verification.md` | methodology, evidence, explicit gaps |
| `docs/ai-development.md` | auditable account of the autonomous process, including v2 |
| `docs/hybrid-architecture.md` | the measured 3-engine + assists study and its risks |
| `firmware/` | UART TX 18, UART RX 26, SPI 32, I2C 32+32, Ethernet MII 31, blink 5 words |
| `demos/` | autobaud, WS2812 (48/50 MHz), barrier-synced UART-SPI bridge + runner |
| `tools/` | assembler, cycle model, diffgen, 99-mutation catalogue, selfcheck |
| `tb/` | 10 Icarus benches (6 assist units + 4 top/engine) |
| `sim/` | cocotb: v2 map, protocol E2E, differential |
| `v2/formal/`, `v2/results/` | engine SBY harness and the v2 evidence reports |
| `results/` | flow report, area, formal/protocol/diff v1 records |
| `legacy/v1/` | the frozen four-engine build and its own evidence |
| `fpga/` | DE2 project for the v1 top only; **not** ported to v2 |

## Verification evidence

All commands run from the repository root unless noted.

| # | gate | command | result |
|---|---|---|---|
| 1 | Toolchain self-check | `python3 tools/selfcheck.py` | **SELFCHECK PASS** — assist opcodes round-trip (assemble/disassemble/assemble), the five CRC check values including `zlib.crc32`, model FIFO order and empty-read `nf` rule |
| 2 | Official TT submission harness | `PATH=$PWD/.venv/bin:$PATH make -C test` | **PASS**: `TESTS=1 PASS=1 FAIL=0`, 147,690 ns; identity `50 52 02`, 13-word program loaded and read back over SPI, engine 2 page `0x0300`, `0x0400` outside the map, `RUN` retired by `HALT`, `E_PC=12`, `r0=0x5A` |
| 3 | Protocol E2E on the RTL | `cd sim && make` | **PASS 6/6, 236 checks**, 9,352,290 ns: v2 map 25, UART TX 18, UART RX 6, SPI 123, I2C 30, MII TX 34 (`v2/results/v2_verify.md`) |
| 4 | RTL directed benches | `bash tb/run.sh` | **PASS=10 FAIL=0**: `tb_crc_bit`, `tb_fifo`, `tb_shiftreg`, `tb_nrzi`, `tb_nrzi_wave`, `tb_manchester`, `tb_csr` 37, `tb_top_smoke` 19, `engine_smoke` 237, `top_e2e` 400 checks |
| 5 | DUT vs model, every cycle | `cd sim && make diff` | **PASS**: 209 programs, **16,122 compared cycles, 0 mismatches**, 0 cut at 3000 cycles, 9,737,490 ns (`v2/results/v2_diff_formal.md`) |
| 6 | Engine formal | `./v2/formal/run.sh` | **E1-E8, E10, E11 PASS** at v1 depths (E4 48, others 40) with every antecedent cover reached; E0 FAIL is the expected control; E9 cover 4/5 by construction (`v2/results/formal_summary_v2.txt`) |
| 7 | Mutation testing | `python3 tools/mutate.py --verify-mutations && python3 tools/mutate.py --all` | **99/99 specs apply cleanly; 99 mutants, 95 killed = 96.0 %**, 4 survivors shown equivalent (`v2/results/v2_mutation.md`) |
| 8 | Model-level demos | `python3 demos/run_demos.py` | **11/11 PASS**, 3 recorded baselines match (`docs/verification.md` §2.6) |
| 9 | Full-chip area | `scripts/synth_full.sh` | **519,233.80 um2 flat / 36,343 cells = 57.54 %** of 902,417 um2 row area, 95.90 % of the 60 % budget (22,216.40 um2 spare); hierarchical 538,016.13 um2 (59.62 %) — `results/synth_v2_root.txt` lines 47230 / 47202 / 19254 |
| 10 | Post-GRT timing | `results/flow_report.md` | setup **+11.0205 ns**, hold **+0.2878 ns** on a 20 ns clock (typ, before routed parasitics) |
| 11 | Routed GDS / DRC / LVS / GLS | GitHub `gds.yaml` (x86_64) | **not run**; six local attempts stalled, see "Flow infrastructure" |

## Design summary

* **Three engines**, 32 x 24-bit program RAM each, 8 x 8-bit registers, 8-bit
  ALU, 4-deep byte FIFOs both directions, 24.8 fixed-point deadline pacer.
* **Five protocol-agnostic assists** behind one CSR interface: bit-serial CRC
  (5..32 bit, runtime init/poly/xorout/reflection), 16 x 8 stream FIFO with
  burst counter, 32-bit bidirectional shift register, USB LS NRZI
  encoder/decoder, 10BASE-T Manchester encoder/4x-8x receiver. The five blocks
  measure 59,854.90 um2 in the shipped hierarchy (`results/synth_v2_root.txt`
  lines 18834-19021; the standalone study syntheses give 60,590.57 um2,
  `results/hybrid_area.md`).
* **Three assist opcodes**: `LDAS` 0x4E, `STAS` 0x4F, `ASST` 0x50. One
  instruction per byte, one cycle, no address setup. Empty reads follow the
  `PULLN` rule (`nf` set, `rd` unchanged).
* **Assist CSR window** `0x0600 + 0x10*id + reg` (id 0..4, reg 0..7, end
  `0x064F`), host-only `PINCFG` at `+8` for bank/tx_base/rx_base ownership.
* **Pin priority** host > assist > engine 2 > 1 > 0; assist pins are push-pull
  and the stage clears open-drain for the bits it owns; assist receive pins read
  the raw pads.
* 24-pin fabric with per-pin direction, open-drain release and sticky collision
  detection; 32-bit timebase; 4-entry edge-timestamp capture FIFO; software
  `CAPTURE` events; `MEAS` pulse-width measurement; four hardware barriers;
  eight IRQ lines.
* Host SPI mode 0 with a 16-bit pointer, auto-increment bursts, and a documented
  one-byte-per-frame rule for FIFO ports.

## Why three engines plus assists (the measured case)

The v1 build was routing-bound at **64.4 %** of row area (581,138.67 um2) with
four engines. Adding assists to four engines measured **655,611.28 um2 = 72.65 %**
- 33,846 um2 above the highest density this project has routed (68.9 %) - so the
choice was "assists or the fourth engine", not both
(`docs/hybrid-architecture.md` §3).

| quantity | value | source |
|---|---:|---|
| one engine (study block) | 132,381.80 um2 | `results/hybrid_area.md` |
| one engine (shipped hierarchy, 3 modules) | 132,741.24 / 132,576.77 / 131,313.72 um2 | `results/synth_v2_root.txt` 18723-18801 |
| five-block assist set (study, bit-serial CRC) | 60,590.57 um2 | `results/hybrid_area.md` |
| same set in the shipped hierarchy | 59,854.90 um2 | `results/synth_v2_root.txt` 18834-19021 |
| option B' prediction (3 engines + min assists) | 506,883.22 um2 / 56.17 % | `docs/hybrid-architecture.md` §0 |
| **shipped v2 (flat)** | **519,233.80 um2 / 57.54 %**, 36,343 cells | `results/synth_v2_root.txt` 47230 / 47202 |
| shipped v2 (hierarchical sum) | 538,016.13 um2 / 59.62 % | `results/synth_v2_root.txt` 19254 |
| 60 % placement budget (541,450.20 um2) | 95.90 %, 22,216.40 um2 spare | arithmetic |
| shipped vs B' prediction | **+12,350.58 um2 (+1.37 pp) above**, not below | arithmetic |

The engine is 2.2x the whole assist set, and the assists are what make Ethernet
fit: v1 measured **230 words** for a complete 802.3 frame against a 32-word
engine (`results/ethernet.md`); v2 emits one in **31 words**
(`firmware/ethernet_mii_tx.asm`) because the frame body arrives from the host
FIFO and the FCS is computed in hardware, so code size no longer depends on
payload length. The build overshot the option B' prediction by 12,350.58 um2;
that difference is not fully attributed and is not assumed away (see the area
provenance note in "Known gaps" and `results/final_evidence.md` §3.2). The cost
is one concurrent protocol lane: I2C still needs two
engines (32+32 words), so UART RX + SPI + I2C cannot all run at once
(`docs/hybrid-architecture.md` §6, risk R3). That is accepted explicitly.

## Flow infrastructure conclusion

**The local aarch64 OpenROAD/DRT runtime is the blocker, not the design
density.** Six LibreLane 6x4 attempts stalled with an identical signature at
both placement targets tried — v1 at `PL_TARGET_DENSITY_PCT=65`, this tree at
60, the placement knob (not the 57.54 % measured cell area)
(`results/flow_report.md`):

| # | tree | density | threads | DRT iters | wall | outcome |
|---|---|---:|---:|---:|---:|---|
| 1 | v1 | 65 | 4 | 64 | 3 h 27 min | killed, zero-byte step log |
| 2 | v1, resumed | 65 | 4 | 8 | 1 h 01 min | killed, zero-byte step log |
| 3 | v2 | 60 | 1 | 64 | 40 min | killed, zero-byte step log |
| 4 | v2, resumed | 60 | 4 | 8 | 1 h 30 min | killed, no DRC output |
| 5 | v2, resumed | 60 | 4 | 4 + DRC save | 80 min | killed, no DRC output |
| 6 | v2, resumed | 60 | 1 | 4 | 45 min | killed, zero-byte step log |

Signature, all six: `openroad-detailedrouting.log` 0 bytes, `drt-run-0/` empty,
no `state_out.json`, no DRC/unrouted-net/congestion report, no error line, CPU
101 % (1 thread) or 378-395 % (4 threads), RSS 2.0-3.1 GB, stable. The image
contains one OpenROAD build (`dcf36133...`) and LibreLane exposes no override,
while the 1x1 smoke flow completes. Because the stall is identical across both
placement targets, both thread counts and from 40 min to 3.5 h, a local
tool/runtime problem dominates.

What *is* valid locally: area up to and including global route, and post-GRT
STA at 20 ns (`nom_typ`) - **setup +11.0205 ns, hold +0.2878 ns** for v2
(v1: +10.641 / +0.265). 50 MHz is comfortably met before routing parasitics; that
is the strongest timing evidence available on this host.

The authoritative submission gate is the repository's
`.github/workflows/gds.yaml` (`TinyTapeout/tt-gds-action@ihp-cmos5l`, x86_64,
LibreLane 3.1.0.dev3/4). Local runs are for iteration and area/timing estimation
only. Do not read the local DRT non-convergence as evidence that the design is
unroutable.

## Known gaps (not overclaimed)

1. **No local routed GDS, DRC/LVS, antenna check or slow-corner timing.** See
   above. The v2 flow also ran on a `v2/src` snapshot that predates the approved
   `PROTEUS_PM_END 0x03FF` constant fix; that is a compare-range constant with
   no area or timing effect, but the final flow must run on the shipped tree.
2. **No gate-level simulation.** `test/Makefile GATES=yes` keeps the branch, but
   no v2 netlist exists to run it.
3. **Top-level formal is v1-only and T7 is open.** T1-T7 plus X1 live in
   `results/formal_summary.txt` for the four-engine top: T1/T2/T5/T6 pass with
   unreached covers (vacuous at depth 20), T4 is a documented interface contract
   (CS_N hold >= 2 clk), T7 (HALT retires RUN at the top) is **OPEN**. Nothing
   in that table was re-proved for the three-engine top; v2's engine proofs are
   in `v2/results/formal_summary_v2.txt`.
4. **FPGA is v1-only.** `fpga/` (archived at `legacy/v1/fpga/`) targets the
   four-engine top; its recorded result is 36 checks, 0 errors on the v1 tree.
   No v2 FPGA build or result exists.
5. **Ethernet MII is host-bandwidth-bound at a 16-byte FIFO.** The RTL gate
   proves one complete 802.3 frame at the pads - 144 nibbles / 72 wire bytes,
   FCS `0xE7C87B32` equal to `zlib.crc32`, zero TXD changes while TX_CLK is high
   - but TX_CLK is slowed (500-cycle half period) because 10 Mbit/s needs a host
   byte every 0.8 us against a ~5.6 us SPI frame. A 64-byte frame buffer (or a
   faster host port) is what sustained line rate would need. No MAC, no PHY, no
   twisted-pair transmitter.
6. **JTAG is partial and is v1 evidence only.** The v1 stretch experiment
   (`results/stretch.md`) reads IDCODE `0x5B5B5B5B` exactly, Capture-IR `0001`,
   and walks 12 of 16 TAP states; BYPASS and Pause/Exit2 are not implemented
   (they need 41-51 words, beyond the 32-word ASIC image). The firmware is not
   in the v2 tree.
7. **USB low-speed and 10BASE-T are not implemented as protocols.** The NRZI and
   Manchester assists are instantiated and unit-benched; the Manchester block at
   48 MHz is not 802.3-compliant (2.4 clocks per half-bit, ±10.4 ns peak edge
   error) and is specified for an 80/160 MHz core. No USB or 10BASE-T firmware or
   pad test exists.
8. **Assist data paths are outside the cycle differential.** `LDAS`/`STAS`/`ASST`
   are excluded by an assertion in the corpus because the model does not model
   CRC bit order, shift framing, NRZI or Manchester. Their evidence is the unit
   benches, `tb_csr`, `top_e2e`, `selfcheck.py` and the MII pad test.
9. **The v2 tree ships no pytest suite.** v1's 179 tests are archived at
   `legacy/v1/tools/tests/` and were not re-run against v2; `tools/selfcheck.py`
   is the toolchain gate here.
10. **No silicon.** The shuttle is March 2027. Every "measured" number is
    simulation or synthesis.
11. **Area provenance.** The earlier v2 record (`v2/results/synth_v2.txt`:
    497,927.19 um2 flat, 33,936 cells, 55.18 %) is **superseded and is never
    the shipped figure**. Its own printed flat script, re-run on the identical
    11 source sha256 values with the same yosys 0.33 and liberty, yields
    **519,233.80 um2 / 36,343 cells** both times, so 519,233.80 is the sign-off
    number (`results/synth_v2_root.txt` line 47230, cells line 47202,
    hierarchical 538,016.13 line 19254). The 21,306.61 um2 (+4.28 %) gap between
    the two records is unexplained; it is recorded, not assumed away
    (`results/final_evidence.md` §3.2). Both values are inside the 60 % budget,
    so no design decision turns on it.

## Reproduce from scratch

```sh
python3 -m venv .venv && .venv/bin/pip install cocotb pytest pyyaml
make pdk-lite                                    # area without the full PDK

python3 tools/selfcheck.py
PATH=$PWD/.venv/bin:$PATH make -C test
cd sim && make && make diff && cd ..
bash tb/run.sh
python3 demos/run_demos.py
./v2/formal/run.sh
scripts/synth_full.sh
# GDS + slow-corner timing: push and let .github/workflows/gds.yaml run
```
