# PROTEUS area baseline - 64x24 program RAM

Measured 2026-11-02 on the aarch64 host with:

- `yosys 0.33` (system; `Yosys 0.33 (git sha1 2584903a060)`), liberty mapping
  `dfflibmap` + `abc -liberty`.
- IHP-Open-PDK `2bbec755dc67ca3db0261c3d6163e15735d66710` (the revision pinned
  by `tt-gds-action@ihp-cmos5l`), corner
  `sg13cmos5l_stdcell_typ_1p20V_25C` (TT `nom_typ_1p20V_25C`).
- Raw numbers: `results/synth.txt`; full transcripts `results/yosys_*.log`.
- Reproduce: `make synth` (needs `make pdk`, ~1.3 GB, or `make pdk-lite`).

## Die / cell budget for `tiles: "6x4"`

| quantity | value |
|---|---:|
| die | 1289.28 x 710.64 um = **916,214 um^2** |
| standard-cell row area | **902,417 um^2** |
| 60% placement target (`PL_TARGET_DENSITY_PCT: 60`) | **541,450 um^2** |
| reference utilisation 68.9% (`core-asic`, 8x4 sign-off) | 621,765 um^2 |
| typical standard cells | 25,000-30,000 for a 6x4 |
| single flop (`sg13cmos5l_dfrbpq_1`) | 48.99 um^2 |
| single flop (`sg13cmos5l_dfrbp_1`, async reset) | 52.62 um^2 |

The 60% number is the budget to design against. The 68.9% number is the highest
utilisation known to have converged in this PDK, not a target.

## Program RAM, flip-flop implementation

1 write port (host), 1 asynchronous read port (instruction fetch), no reset -
exactly the `prog_ram_ff` bench (`scripts/bench/prog_ram_ff.v`).

| depth x width | cells | DFFs | area (um^2) | % of 60% 6x4 budget |
|---|---:|---:|---:|---:|
| 16 x 24 | 916 | 384 | 30,594.41 | 5.65% |
| **24 x 24** | **1,402** | **576** | **46,267.20** | **8.55%** |
| 32 x 24 | 1,844 | 768 | 61,548.08 | 11.37% |
| **64 x 24** | **3,676** | **1,536** | **123,128.81** | **22.74%** |
| 24 x 24, four engines | 5,589 | 2,304 | **184,894.62** | **34.15%** |
| 32 x 24, four engines | - | 3,072 | **246,192.31** | **45.47%** |
| 64 x 24, four engines | 14,637 | 6,144 | **492,210.43** | **90.91%** |
| 64 x 24, four engines, at 68.9% reference | - | 6,144 | 492,210.43 | 79.2% |

Area is linear in depth: each 24-bit word costs about 1,924 um^2
(48.99 um^2 flop + 31.1 um^2 read mux per bit plus decode).

The 64x24 four-engine figure alone consumes 14,637 of the ~25-30k cells that
fit a 6x4, and 6,144 of the ~10,300 flops that would fit if the die were
nothing but flops. That leaves too little for four ALUs, 8x8 registers,
16-deep byte FIFOs, 32-bit pacers, the capture FIFO, barriers and the host SPI.

## Program RAM, SRAM macro

Yosys 0.33 and 0.66 **cannot infer** an IHP SRAM from RTL: `memory_libmap`
consumes a yosys *memlib* description, not liberty. The synchronous-read RTL
(`scripts/bench/prog_ram_sram.v`) therefore still synthesises to flops:
**124,767.22 um^2 / 3,726 cells / 1,560 DFFs** - slightly worse than the
async-read version. A macro must be instantiated explicitly and wired through
LibreLane `MACROS` (GDS/LEF/LIB/CDL + Metal4 PDN connections).

Smallest fitting 2-port macro: `RM_IHPSG13_2P_64x32_c2` (64 x 32, ports A+B,
BIST pads absent in this variant), 1 instance:
**702.83 x 74.87 um = 52,620.88 um^2** (liberty `area`, identical to LEF SIZE).
Four engines: **210,483.53 um^2 = 1 macro each, 38.87% of the 60% budget**.

Geometry: one macro is 702.83 um wide; the 6x4 core is 1283.52 um wide, so two
macros do not fit side by side (1405.66 um). Four stack vertically as four
rows of 74.87 um = 299.5 um of 703.08 um, which fits.

| option | per engine | 4 engines | % 60% budget | model.py timing preserved? |
|---|---:|---:|---:|---|
| FF, 64 deep | 123,128.81 | 492,210.43 | 90.9% | yes (async fetch) |
| FF, 32 deep | 61,548.08 | 246,192.31 | 45.5% | yes |
| FF, 24 deep | 46,267.20 | 184,894.62 | 34.1% | yes |
| FF, 16 deep | 30,594.41 | 122,377.65 | 22.6% | yes |
| 2P SRAM 64x32 | 52,620.88 | 210,483.53 | 38.9% | **no** - registered read |

(The 24/16 rows above are ideal memory-only costs. The full chip behaves
differently; see the next section.)

## Full-chip synthesis (current `src/`)

Command: `make synth` (yosys 0.33, liberty mapping, `-flatten`; PROG_DEPTH
overridden on `proteus_engine` with `chparam`). Logs:
`results/yosys_design_d{32,24,16}.log`, raw stat in `results/synth.txt` and
`results/synth_d16.txt`.

| PROG_DEPTH | cells | DFFs | area (um^2) | % of row area | % of 60% budget | % of 68.9% reference |
|---|---:|---:|---:|---:|---:|---:|
| **32** | **39,368** | **4,885** | **565,189.19** | **62.63%** | **104.38%** | **90.90%** |
| 24 | 41,542 | 5,235 | 596,652.25 | 66.12% | 110.20% | 95.96% |
| 16 | 41,537 | 5,235 | 597,675.76 | 66.23% | 110.38% | 96.13% |

Depth is **not** area-monotonic below 32. `proteus_engine` sets
`ADDR_W = (PROG_DEPTH <= 32) ? 5 : 6` and indexes
`prog_mem[0:PROG_DEPTH-1]` / `prog_written[PROG_DEPTH-1:0]` with that 5-bit
address. At 24 and 16 the out-of-range entries are expanded into 32:1 read
muxing plus range logic, so the netlist is 31-32k um^2 *larger* than at 32 and
has 350 more flops. 32 is the area minimum; **24 is not a useful retry**. A
16-deep retry only makes sense after `ADDR_W` becomes `$clog2(PROG_DEPTH)` and
the design is re-measured.

### Post-cut RTL (FIFO_DEPTH=4, CAP_DEPTH=4) - number to harden

The table above is the pre-cut snapshot. After the FIFO-depth cuts and the
HALT/PACER/PDEPTH fixes landed, the full chip measures:

| source | area (um^2) | cells | % of row area | % of 60% budget |
|---|---:|---:|---:|---:|
| `make synth` (lean flow, current `src/`, `results/synth.txt`) | **568,294.39** | **40,029** | **62.97%** | **104.96%** |
| `results/synth_full.txt` (full `synth`, hierarchical) | 581,138.67 | 42,049 | 64.40% | 107.33% |
| `results/synth_full.txt` (full `synth`, flat) | 558,240.45 | 38,958 | 61.86% | 103.10% |

The three numbers differ only in yosys optimisation/mapping quality (2.2-4%);
the flow's own yosys 0.66 synthesis number is the one that decides placement.

### Routability hedge: depth-2 FIFO/capture (`/tmp/proteus-lite`)

A copy of the same RTL with `FIFO_DEPTH=2` (engine in/out) and `CAP_DEPTH=2`
(top capture), nothing else changed: **545,147.78 um^2 / 38,797 cells =
60.41% of row area, 100.68% of the 60% budget** with the lean flow (full-synth
expectation ~555k). That is the variant the density-62 routing experiment
uses; it keeps all 4 engines, PROG_DEPTH=32 and the whole ISA. It is a hedge,
not the default: depth-2 changes FIFO/capture capacity and needs a firmware
and differential retest before adoption.

This is the design area to use for placement. It is 39.8k um^2 (6.4%) below
the pre-cut 620,982 um^2 netlist and still above the 60% target, because the
RTL gained the 32-bit pacer, HALT retirement and bus-default logic after the
565k measurement.

The 6x4 LibreLane run at `PL_TARGET_DENSITY_PCT=65` (details in
`results/flow_smoke.txt`) placed, clock-tree-synthesised and globally routed,
with mid-PnR setup slack **+10.64 ns on a 20 ns clock** at `nom_typ`. It did
**not** reach a routed GDS: detailed routing ran 3 h 27 min unbounded and
1 h 01 min with `DRT_OPT_ITERS=8` (resumed from the post-GRT state), both
killed with zero iteration artifacts. Routed DRC/LVS and slow-corner timing
remain open. That is a routability/DRT-convergence failure at 62.6%
utilisation, not a placement or setup-timing failure; v1 is therefore not a
submission candidate.

At 64.4% row utilisation the design sits 4.5% below the 68.9% utilisation that
`core-asic` routed on an 8x4, so placement is expected to converge at 65. If
global placement fails with GPL-0302, raise the target to 68 (TT FAQ says up
to 80 is known to work) and report the failure mode.

Note on `make synth` runtime: the full `synth` script on this ~42k-cell design
takes >15 min in yosys 0.33 (the techmap/opt passes dominate). `abc -fast`
finishes in ~7 min but maps to 889k um^2, which is not usable for decisions;
the full ABC script is required for a representative number.

## v2 tree (3 engines + hardware assists) - submission candidate

`v2/src` (top `tt_um_proteus`, 3 engines, assist blocks for CRC / Manchester /
NRZI / shift-register / FIFOs) measures, from `v2/results/synth_v2.txt`:

| metric | value | % of row area |
|---|---:|---:|
| flat netlist | **497,927.19 um^2 / 33,936 cells** | **55.18%** |
| hierarchical | 539,038.85 um^2 | 59.73% |

That is below the 60% density target, so v2 is the tree to harden
(`PL_TARGET_DENSITY_PCT=60`), in place of v1 (which failed detailed routing at
62.6%). The v2 LibreLane outcome is recorded in `results/flow_smoke.txt`.

## Cheap levers: FIFO depth 8 -> 4

Measured on structural copies of the RTL FIFOs (`scripts/bench/fifo_rb.v`:
register file + read/write pointers + count, combinational read):

| FIFO | 8 deep | 4 deep | saving |
|---|---:|---:|---:|
| engine in/out, 8 x 8 | 6,292.34 um^2 (226 cells, 77 DFF) | 3,287.69 um^2 (123 cells, 41 DFF) | **3,004.65 um^2 each** |
| capture, 8 x 37 | 24,599.64 um^2 (778 cells, 309 DFF) | 12,180.07 um^2 (384 cells, 157 DFF) | **12,419.57 um^2** |

Applying to the whole chip (4 engines x 2 engine FIFOs, 1 capture FIFO):

| lever | full-chip saving | of 565,189 um^2 |
|---|---:|---:|
| engine FIFOs 8 -> 4 | 8 x 3,004.65 = **24,037 um^2** | 4.25% |
| capture FIFO 8 -> 4 | **12,420 um^2** | 2.20% |
| **both** | **36,457 um^2** | **6.45%** |

The cut is now in the RTL (`FIFO_DEPTH=4`, `CAP_DEPTH=4`). Measured full-chip
effect on the current design: **620,982 -> 581,139 um^2 = 39,843 um^2 saved**,
within 9% of the bench sum above (the remainder of the pre-cut area growth is
the 32-bit pacer / HALT / bus-default fixes, not FIFO storage).

Caveats: the real capture FIFO accepts up to five events per cycle plus the
event-sort muxing, so 12.4k is a lower bound for that lever; the engine FIFOs
also carry full/empty/nf flags not modelled. Both FIFOs are hard-coded
`[0:7]` arrays in `proteus_engine.v` / `tt_um_proteus.v` (no DEPTH parameter),
so this lever needs an RTL edit by the file owners, not a config change.

## Recommendation: PROG_DEPTH = 32

`PROG_DEPTH = 64` **does not fit** a 6x4 with flip-flop program RAM: 4 x 64x24
is 492k um^2, 91% of the 60% budget, before any engine logic or the host
interface. Even at the 68.9% reference utilisation it is 79%, and the known
converging precedent (`core-asic`) used 668k um^2 for a *complete* design on an
8x4.

`PROG_DEPTH = 32` costs 246k um^2 for all four engines (45.5%), leaving ~295k
um^2 for logic at the 60% target. That is the largest depth with a credible
area margin, and it keeps `model.py`'s zero-latency fetch (async read), which a
1-cycle registered SRAM read cannot preserve: every taken branch would add a
bubble and diverge from the cycle model.

The orchestrator set **PROG_DEPTH = 32 as the default build parameter**
(ADDR_W=5, `prog_ready` after the HALT fill) with 24 as a planned retry. The
full-chip measurement above changes the retry advice: **32 is the smallest of
the three depths in this RTL** (565k vs 597k at both 24 and 16), so keep 32 and
do not spend a run on 24. 32 fits the row area at 62.6% utilisation; the
remaining risk is routing/timing at that density, reported by the LibreLane
run, not area.

64 deep is only viable if both of these are accepted:

1. Program memory becomes four `RM_IHPSG13_2P_64x32_c2` macros (39% of budget),
   which requires the `MACROS` flow: Metal4 PDN connections, 2 um halos,
   routing obstructions, KLayout/Magic DRC and LVS work. TinyTapeout documents
   this as non-trivial and still changing.
2. The engine gains a fetch pipeline stage (registered SRAM read), which
   changes ISA cycle counts versus `tools/model.py` (ground truth), so the
   model, deadline pacing tests and differential cosimulation must all be
   updated to match.

If neither is acceptable, keep `PROG_DEPTH = 64` only by moving to `tiles:
"8x4"` (row area 1,208,173 um^2, 60% budget 724,904 um^2), which is a
procurement change, not an RTL change.

`[INFERENCE]` The non-RAM logic budget (~295k um^2 at 32 deep, ~356k at 24) is
an estimate: `src/` was still empty when this baseline was measured, so the
real design has not been synthesised yet. `make synth` switches to
`src/tt_um_proteus.v` automatically once it exists, sweeping PROG_DEPTH 32 and
24 via `chparam` on `proteus_engine`; `make flow` produces the 50 MHz timing
number (`final/metrics.json`, `timing__setup__ws`).
