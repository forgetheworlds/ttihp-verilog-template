# PROTEUS full-chip area and timing budget

Measured 2026-11-02 (run started 22:55:31Z) on the aarch64 host with
`yosys 0.33`, IHP sg13cmos5l typical liberty, four engines + host + pin
fabric + capture + barriers/IRQ, `PROG_DEPTH = 32`, `FIFO_DEPTH = 4`,
`CAP_DEPTH = 4`.

Source snapshot this report is valid for (the run prints the same hashes in
its header; any edit to these files invalidates the numbers):

```
c8cc546730b070ef0a1bed27721d416bbae5523edf44687b39be153e552176a4  src/proteus_engine.v
e0d19eaf00eb8e9938ee646ade67672c3094e15292693012cca4b9a36ca5982d  src/proteus_host.v
65a62a1c5db3cc32ec46767c7c54c3586d3dc0cc7ebedb0ef0a83653c2a21893  src/tt_um_proteus.v
```

Snapshot notes: this revision contains the `ADDR_W = $clog2(PROG_DEPTH)` fix,
the HALT/run fix, the 32-bit pacer, `FIFO_DEPTH = 4` / `CAP_DEPTH = 4`
(per-engine IN/OUT FIFOs and the capture FIFO), `PDEPTH[6:0]`, and the
write-bus defaults. Library: 84 cells, typ 1.20 V 25 C, `sg13cmos5l_dfrbpq_1`
= 48.99 um^2.

Raw data: `results/synth_full.txt` (23.6 MB, full yosys transcripts for the
hierarchical run, the flat run, the timing JSON analysis and the lever
benches) and `results/synth_full_depth.txt` (engine `PROG_DEPTH`
32/24/16 sweep).

---

## Verdict at PROG_DEPTH = 32

| criterion | requirement | measured | result |
|---|---|---:|---|
| 60%-density 6x4 budget (cell area) | <= 541,450 um^2 | **581,138.67 um^2** (sum of mapped modules) / **558,240.45 um^2** (flat mapped) | **NO FIT at 60%** |
| margin vs 60% budget | >= 20% (i.e. <= 433,160 um^2) | 581,139 / 558,240 | **NO — 34.2% / 28.9% over the 20%-margin ceiling** |
| 65% placement target (Main ruling) | <= 586,571 um^2 | 581,138.67 | fits, **0.93% margin (5,432 um^2)** |
| row utilisation | <= 902,417 um^2 | 581,138.67 | 64.40% |

Headline for the hardening flow: **581,138.67 um^2, 42,049 cells, 64.4% of
row area, 107.3% of the 541,450 um^2 60% budget.** Fits the 65% density
target with under 1% margin, so it is a tight place-and-route problem and
should be run at 65 first, 68 as the fallback.

Two area numbers are reported deliberately:

* **581,138.67 um^2 / 42,049 cells** — hierarchical flow, sum of the
  per-module `stat` areas. This is the number the hardening flow is being
  handed and the conservative (upper-bound) figure: `abc -liberty` cannot
  optimise or share logic across module boundaries here.
* **558,240.45 um^2 / 38,958 cells** — flat flow (`synth -flatten`). Cross-
  module optimisation removes 22,898 um^2 (3.9%). A gate-level LibreLane
  synthesis (flattened) should land nearer this number, but the 581k figure
  is the one to harden against.

Flops (mapped, `sg13cmos5l_dfrbpq_1`): **4,838 = 237,014 um^2 = 42.5% of the
flat area / 40.8% of the 581k figure.**

---

## 1. Exact commands

Full run (all sections below; ~30 min on this host):

```sh
scripts/synth_full.sh                      # PROG_DEPTH=32, writes results/synth_full.txt
DEPTHS="32 24" scripts/synth_full.sh       # optional top-level depth sweep
```

The script runs, with `LIB` = the liberty path and `SRCS` = `src/*.v`:

```sh
# hierarchical: per-module cells and area
yosys -p "read_verilog -I src $SRCS; chparam -set PROG_DEPTH 32 tt_um_proteus;
          chparam -set PROG_DEPTH 32 proteus_engine; hierarchy -check -top tt_um_proteus;
          synth -top tt_um_proteus; dfflibmap -liberty $LIB; abc -liberty $LIB;
          opt_clean; stat; stat -liberty $LIB"

# flat: sign-off total, ltp, JSON netlist for the timing estimate
yosys -p "read_verilog -I src $SRCS; chparam -set PROG_DEPTH 32 tt_um_proteus;
          chparam -set PROG_DEPTH 32 proteus_engine; hierarchy -check -top tt_um_proteus;
          synth -top tt_um_proteus -flatten; stat; ltp -noff;
          write_json d32.json; dfflibmap -liberty $LIB; abc -liberty $LIB;
          opt_clean; stat -liberty $LIB"

# engine PROG_DEPTH sweep (also section 5 of scripts/synth_full.sh)
yosys -p "read_verilog -I src src/proteus_engine.v; chparam -set PROG_DEPTH 32 proteus_engine;
          hierarchy -check -top proteus_engine; synth -top proteus_engine -flatten;
          dfflibmap -liberty $LIB; abc -liberty $LIB; opt_clean; stat -liberty $LIB"
```

Liberty:
`/home/ubuntu/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib`
(pinned IHP-Open-PDK `2bbec755dc67ca3db0261c3d6163e15735d66710`, fetched by
`scripts/fetch_pdk.sh`). It was present; no generic-library fallback was
needed.

Timing: `sta` and `openroad` are **not installed** on this host
(`command -v sta openroad` → empty), so there is no liberty-based STA of the
mapped netlist. Section 6 is an estimated-delay analysis, not timing closure.

---

## 2. Per-module breakdown (hierarchical flow, exact `stat -liberty` areas)

| block | cells | flops | area um^2 | % of 541,450 budget |
|---|---:|---:|---:|---:|
| engine 0 (`u_eng0`, ENG_ID=0) | 9,616 | 1,104 | 132,227.12 | 24.42% |
| engine 1 | 9,636 | 1,104 | 132,306.12 | 24.44% |
| engine 2 | 9,611 | 1,104 | 132,234.76 | 24.42% |
| engine 3 | 9,672 | 1,104 | 132,381.80 | 24.45% |
| **4 engines** | **38,535** | **4,416** | **529,149.80** | **97.73%** |
| host SPI slave (`proteus_host`) | 737 | 128 | 12,503.60 | 2.31% |
| top glue (pin fabric, capture, barriers, IRQ, decode, timebase) | 2,777 (2,782 incl. 5 instance refs) | 294 | 39,485.28 | 7.29% |
| **total, hierarchical** | **42,049** | **4,838** | **581,138.67** | **107.33%** |
| total, flat mapping | 38,958 | 4,838 | 558,240.45 | 103.10% |

The four engines differ slightly because `ENG_ID` is a constant inside each
instance (self-mask/branching logic) and because `abc` maps each derived
module independently.

---

## 3. Engines: program RAM vs logic

Measured by `chparam` on `proteus_engine` alone (same RTL, `ADDR_W =
$clog2(PROG_DEPTH)`, flattened, liberty mapping). Raw: `results/synth_full_depth.txt`.

| PROG_DEPTH | cells | flops | area um^2 |
|---|---:|---:|---:|
| 32 | 9,692 | 1,104 | 132,510.89 |
| 24 | 8,227 | 904 | 111,380.23 |
| 16 | 6,680 | 702 | 89,728.09 |

The 32 -> 24 delta is 21,130.65 um^2 for 8 words (200 flops: 8 x 24 program
bits + 8 `prog_written` bits), i.e. **2,641.33 um^2 per program word** for
this RAM shape (2 read ports: instruction fetch + host read-back, byte-
enable write, async read). That is 37% more per word than the single-read
`prog_ram_ff` bench in `results/area_baseline.md` (1,924.6 um^2/word),
because of the host read port.

| engine component, PROG_DEPTH=32 | area um^2 | % of engine |
|---|---:|---:|
| program RAM 32 x 24 (2 read ports, incl. `prog_written`) | 84,522.61 | 63.8% |
| engine logic (decode, ALU, 8x8 regs, FIFOs 4x8 x2, pacing, barrier/IRQ, host port) | 47,988.28 | 36.2% |
| **engine total (standalone)** | **132,510.89** | 100% |
| 4 engines, RAM share | 338,090.46 | 63.9% of 529,149.80 |
| 4 engines, logic share | 191,059.36 | 36.1% of 529,149.80 |

`[INFERENCE]` The split assumes the depth-dependent area is entirely
program-memory; true for the 32-vs-24 pair (both use ADDR_W=5), approximately
true for 16 (ADDR_W drops to 4, which also shrinks PC/counter logic).

---

## 4. Top glue breakdown

Top module (glue only, excludes the four engine instances and the host):
**39,485.28 um^2**, 2,782 cells.

| top-glue bucket | area um^2 | basis |
|---|---:|---|
| capture FIFO (`CAP_DEPTH=4`, 37-bit entries, up to 5 pushes/cycle) | 27,504.34 | isolated exact-shape bench of the same RTL block (`lever_cap D=4` in `results/synth_full.txt`); 2,337 cells |
| pin fabric + barriers + IRQ + register decode + 32-bit timebase + collision + reset/host gating | 11,980.94 | 39,485.28 - 27,504.34 |

The capture unit is **69.7% of the top glue** and ~4.7% of the whole design.
Its cost is dominated by the 5-port, 8-way priority write network into
4 x 37 bits (the 4 engine `CAPTURE` requests plus one UIO edge event per
cycle), not by the flop count.

Flop split (exact from `stat` per module; RTL-count cross-check in brackets):

| block | flops | composition |
|---|---:|---|
| engine (each) | 1,104 | program RAM 800 (768 = 32x24 data + 32 `prog_written`), engine logic 304 (8x8 regs, 2 x 4x8 FIFOs, pc, 32-bit period, `next_int` 32 + `next_frac` 8, `wait_left` 32, `ts_event` 32, side-set/bit-pin cfg, FIFO pointers/counters, flags) |
| host | 128 | SPI synchronisers, shift register, pointer/address, command FSM, tx/rd registers |
| top module | 294 [RTL: 280] | capture 170 (4x37 entry memory + pointers + flags + `cap_en` + `uio_prev`), timebase 32, pin fabric 32 (`uo_q`/`uio_q`/`oe_q`/`od_q`), IRQ 16, run/assert/error 16, collision 8, reset chain 6 |
| **total** | **4,838** | 4,416 + 128 + 294 |

The 14-flop difference between the measured top-module count (294) and the
RTL register list (280) is `dfflibmap`/`abc` duplication of shared enables;
the module totals above are the authoritative numbers. A pre-abc JSON
attribution (in `results/synth_full.txt`, "flip-flop cells by bucket") splits
the same 4,838 differently (engines 1,092/1,088/1,087/1,088, host 84,
capture 202, pin fabric 18, irq/run 30, top other 141) because `abc` renames
some Q nets; use the `stat` numbers.

---

## 5. PROG_DEPTH 24 vs 32, and the levers

### 5.1 Full top at 32

Does **not** fit the 60%-density 6x4 budget: 581,138.67 um^2 is 107.3% of
541,450 (39,689 um^2 over; 16,790 um^2 over even with the flat mapping), and
it is nowhere near a 20% margin (that needs <= 433,160 um^2). It fits the 65%
density target with 0.93% margin (hierarchical) or 4.8% (flat).

### 5.2 Depth 24 (valid now that ADDR_W is fixed)

The previous sweep (`results/yosys_design_d24.log`, 596,652 um^2 at d24 vs
565,189 at d32) was non-monotonic because `ADDR_W` was pinned to 5 for all
depths <= 32; those numbers are void. With `ADDR_W = $clog2(PROG_DEPTH)` the
engine is now linear (section 3): d24 costs 21,130.65 um^2 less per engine.

Extrapolated full top at PROG_DEPTH=24 `[INFERENCE: engine delta x 4, not
re-measured at the top]`:

| mapping | area um^2 | % of 60% budget | row utilisation |
|---|---:|---:|---:|
| hierarchical (581,138.67 - 84,522.61) | 496,616.06 | 91.7% | 55.0% |
| flat (558,240.45 - 84,522.61) | 473,717.84 | 87.5% | 52.5% |

So depth 24 fits the 60% budget with 8.3-12.5% margin, but still not 20%.
Cost: 24 instructions per engine instead of 32 (capacity, not semantics).

### 5.3 FIFO 8 -> 4 and capture 8 -> 4 (already applied)

Both cuts are in the snapshot and are measured three ways.

| lever | isolated bench um^2 saved | integrated delta |
|---|---:|---:|
| per-engine IN+OUT FIFO 8 -> 4 | 5,465.62 per engine (`lever_fifo` D=8 11,528.09 -> D=4 6,062.48; two FIFOs, two read ports) | 5,428.23 per engine (137,655.35 -> 132,227.12 for engine 0) = 21,712.9 for four engines |
| capture FIFO 8 -> 4 (37-bit, 5 write ports) | 20,499.20 (`lever_cap` 48,003.54 -> 27,504.34) | 19,571.18 (top glue 59,056.45 -> 39,485.28) |
| **combined** | **42,361.6** | **39,843.9 hierarchical** (620,982.60 -> 581,138.67); **41,197.4 flat** (599,437.81 -> 558,240.45) |

Independent single-read-port FIFO benches measured by another lane give
3,004.65 um^2 per 8-bit FIFO and 12,419.6 um^2 for a plain 37-bit FIFO; the
capture FIFO's real saving is larger because the capture memory has five
priority write ports.

### 5.4 Other cuts

| cut | um^2 saved | cost |
|---|---:|---|
| FIFO 4 -> 2 (engine in/out) | ~10.9k `[INFERENCE: half the measured 8->4 delta]` | protocol buffering drops to 2 bytes; host must strictly interleave |
| capture entry width 37 -> 33 bits | ~3.4k `[INFERENCE]` | loses 32-bit timestamps; rejected, capture is the product feature |
| program RAM as `RM_IHPSG13_2P_64x32_c2` macro | ~127.6k (84,522.61 -> 52,620.88 per engine x 4) | requires the LibreLane MACROS flow (PDN/LEF/GDS/DRC/LVS) and a registered read, which changes the ISA cycle model |
| PROG_DEPTH 16 (`ADDR_W=4`) | 171,131.2 (4 x 42,782.80) | 16-instruction capacity; top -> ~410,007 um^2 hierarchical = 75.7% of the 60% budget (24.3% margin), the only cut that reaches the 20% target |

The depth-16 figure is the only lever that satisfies the ">= 20% margin at
32-deep budget" acceptance criterion, and it does so by halving ISA capacity,
not by fixing the implementation.

---

## 6. Timing estimate (no STA available)

`sta`/`openroad` are not installed, so this is **not timing closure**. Two
independent pieces of evidence:

1. `yosys ltp -noff` on the flat netlist (after `synth`, before liberty
   mapping): longest topological path length = **62**, starting at
   `\u_eng0.pc_r[3]` — the PC -> asynchronous program-RAM read ->
   decode/ALU -> register-file write-mux path.
2. Estimated cell delay along that 62-level path from the liberty NLDM tables
   (`parse_liberty` samples `cell_rise`/`cell_fall`; no interconnect, no slew
   propagation, no clock tree):

| weight | delay | levels |
|---|---:|---:|
| intrinsic (min slew, min load; lower bound) | 6.14 ns | 62 |
| typical (0.1 ns input slew, 0.023 pF load) | **12.39 ns** | 62 |
| max table entry (pessimistic upper bound) | 88.92 ns | 59 |

At 20 ns (50 MHz) the typical cell-only estimate leaves **7.61 ns (38% of the
period)** for interconnect, clock insertion and on-chip variation. The path
is 62 levels deep and starts/ends inside one engine (pc_r -> regs write mux),
so it is a real single-cycle datapath, not a false path.

Why 50 MHz is plausible but unproven:

* the 32x24 program RAM is flip-flop based with an asynchronous read; the
  ~6-level read mux at the head of the path is the largest single
  contributor, and it fits comfortably in 20 ns on this 130 nm-class library;
* the library is fast at the typical corner (inverter ~20 ps intrinsic,
  ~85 ps at 0.023 pF / 0.1 ns slew), and 62 levels at ~200 ps average is
  12.4 ns;
* the whole design is ~64% row utilisation, which leaves routing room, but
  the 65% target is where congestion and wire delay grow, so the 38% margin
  can be consumed.

What would prove it: LibreLane/OpenSTA `timing__setup__ws` at 20 ns on the
mapped, placed netlist (`final/metrics.json`). If that fails, the fix is
architectural: registering the program-RAM read adds one cycle and breaks
`tools/model.py`; a decode/execute pipeline changes ISA cycle counts. Neither
is a synthesis option, so the timing sign-off must come from the flow.

---

## 7. Caveats

* Numbers are area-oriented `abc -liberty` mapping (no `-D` delay target),
  with no filler/tap/decap cells, no clock tree and no routing. The budget
  comparison is cell area only, which is how `PL_TARGET_DENSITY_PCT` is
  applied.
* The hierarchical total (581k) overcounts by 3.9% relative to the flat
  mapping (558k); both are reported and the conservative one is the headline.
* `[INFERENCE]` tags mark the three extrapolations: the depth-24/16 top-level
  areas, the engine RAM/logic split, and the sub-4 FIFO estimate. Everything
  else is a direct `stat`/bench number from this run.
