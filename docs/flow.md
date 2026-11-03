# PROTEUS physical flow (IHP SG13CMOS5L, 6x4)

Copy-pasteable commands to synthesise PROTEUS, report cell area, and harden it
with the same LibreLane invocation as `TinyTapeout/tt-gds-action@ihp-cmos5l`.

Verified on this host: aarch64 (Oracle/Ampere), Linux 7.0, 4 cores, 23 GB RAM,
64 GB free disk, Docker 29.8.0, yosys 0.33 (system), yosys 0.66 inside the
LibreLane image.

---

## 1. What the official flow actually is

`tt-gds-action@ihp-cmos5l` is a composite GitHub Action, not a Docker image. It:

1. clones `TinyTapeout/tt-support-tools` at branch `ihp-sg13cmos5l`;
2. runs `./tt/tt_tool.py --create-user-config` to build `src/config_merged.json`
   from `info.yaml` + `src/config.json`;
3. installs the PDK by a shallow `git fetch` of `IHP-Open-PDK` at the pinned
   revision (`2bbec755dc67ca3db0261c3d6163e15735d66710`) into `$PDK_ROOT`;
4. `pip install librelane==3.1.0.dev3` and runs
   `python -m librelane --dockerized --docker-no-tty --pdk-root $PDK_ROOT
   --pdk ihp-sg13cmos5l --manual-pdk --run-tag wokwi
   --force-run-dir runs/wokwi src/config_merged.json`;
5. the `--dockerized` mode pulls `ghcr.io/librelane/librelane:<version>` and
   runs LibreLane inside it.

Consequences for a local aarch64 run:

| piece | value on this host |
|---|---|
| LibreLane image | `ghcr.io/librelane/librelane:3.1.0.dev4` (multi-arch index; arm64 manifest exists). Pulled in 74 s, 5.88 GB unpacked |
| inside image | yosys 0.66, OpenROAD, KLayout 0.30.9, librelane 3.1.0.dev4 |
| PDK | `IHP-Open-PDK@2bbec755`, 1.3 GB, fetched in 20 s into `$HOME/pdk` |
| PDK root layout | `$PDK_ROOT/ihp-sg13cmos5l/` (SOURCES records the revision) |
| SRAM | `$PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram` -> `../../ihp-sg13g2/libs.ref/sg13g2_sram` |

Version note: the action default is `3.1.0.dev3`; TT's local-hardening guide
requires LibreLane **3.1.0.dev4 or newer** for IHP SG13CMOS5L. `scripts/flow.sh`
defaults to dev4. Both images are arm64-native and were pulled here.

---

## 2. Commands

```sh
cd /home/ubuntu/verilog

# PDK (once); ~1.3 GB, 20 s. Use pdk-lite for a 1.8 MB liberty-only download.
make pdk
# make pdk-lite

# Cell-area baseline -> results/synth.txt (+ results/yosys_*.log)
make synth

# Full-chip synthesis only, PROG_DEPTH=32 (requires src/tt_um_proteus.v).
# DEPTHS="32 16" overrides; depths <32 cost more area until ADDR_W is fixed.
make synth-design

# LibreLane 6x4 hardening. Stages a copy in $HOME/tt-stage/proteus, generates
# src/config_merged.json, then runs the image. Does not touch the working tree.
make flow

# Variants
scripts/flow.sh --in-place                 # run in this tree (root-owned files)
scripts/flow.sh --tag mytag                # runs/mytag
scripts/flow.sh --version 3.1.0.dev3       # match the CI action default
scripts/flow.sh --stage /tmp/proteus-stage
scripts/flow.sh --no-docker                # native librelane install
PL_TARGET_DENSITY_PCT=65 make flow         # override the 60% density target
```

Direct invocation, once `src/config_merged.json` and `runs/wokwi/` exist:

```sh
export PDK_ROOT=$HOME/pdk
mkdir -p runs/wokwi
docker run --rm -v "$PWD":/work -v "$PDK_ROOT":/pdk -w /work \
  ghcr.io/librelane/librelane:3.1.0.dev4 \
  python3 -m librelane \
    --pdk-root /pdk --pdk ihp-sg13cmos5l --manual-pdk \
    --run-tag wokwi --force-run-dir runs/wokwi \
    src/config_merged.json
```

`--force-run-dir` requires the directory to exist (LibreLane does not create
it); `tt_tool.py --harden` creates `runs/wokwi` first and `flow.sh` does the
same.

Outputs: `runs/wokwi/final/gds/*.gds`, `final/nl/*.nl.v`, `final/reports/`,
`final/metrics.json` (timing: `timing__setup__ws`, `timing__hold__ws`;
DRC/LVS: `route__drc_errors`, `design__lvs_error__count`).

---

## 3. Exact configuration for `tiles: "6x4"`

`src/config_merged.json` is `src/config.json` overridden by the TT keys generated
from `info.yaml`. For PROTEUS the generated values are:

```json
{
  "DESIGN_NAME": "tt_um_proteus",
  "VERILOG_FILES": ["dir::proteus_defs.vh", "dir::proteus_engine.v",
                    "dir::proteus_host.v", "dir::tt_um_proteus.v"],
  "DIE_AREA": "0 0 1289.28 710.64",
  "FP_DEF_TEMPLATE": "dir::../tt_block_6x4_pgvdd.def",
  "VDD_PIN": "VPWR",
  "GND_PIN": "VGND",
  "RT_MAX_LAYER": "Metal4"
}
```

(`VERILOG_FILES` comes from `info.yaml: project.source_files`; only `.v` files
are listed, `proteus_defs.vh` is pulled in by `` `include ``. `dir::` resolves
relative to the config file, which is why `FP_DEF_TEMPLATE` uses `../`.)

The TT default `src/config.json` (`tt-template/src/config.json`) then supplies:

| key | value | effect |
|---|---|---|
| `CLOCK_PERIOD` | 20 | 50 MHz sign-off |
| `CLOCK_PORT` | `clk` | |
| `PL_TARGET_DENSITY_PCT` | 60 | target placement density |
| `FP_SIZING` | absolute | uses `DIE_AREA` |
| `RUN_KLAYOUT_DRC` / `RUN_KLAYOUT_XOR` | 0 | TT precheck does sign-off DRC |
| `FP_PDN_MULTILAYER` | 0 | Metal4-only vertical PDN |
| `FP_PDN_VPITCH` / `FP_PDN_VWIDTH` | 50.0 / 2.1 | |
| `TOP_MARGIN_MULT`/`BOTTOM`/`LEFT`/`RIGHT` | 1/1/6/6 | TT IO margins |

For the real engine at `PROG_DEPTH = 32`, one extra knob matters: the measured
flat cell area is 519,233.80 um2 = 57.54 % of the 902,417 um2 rows
(`results/synth_v2_root.txt`), i.e. 95.90 % of the 60 % target with 22,216.40 um2
spare. The 60 % target is therefore workable, and `PL_TARGET_DENSITY_PCT` need
only be raised (TT FAQ says up to 80 works) if global placement fails. `make flow`
leaves the config as generated; change `src/config.json` deliberately, not the
generated file.

---

## 4. What `tiles: "6x4"` means

The validator is not a hard-coded list. `ProjectInfo` checks `tiles` against the
keys of `tt-support-tools/tech/ihp-sg13cmos5l/tile_sizes.yaml`:

```python
tiles = project_section.get("tiles")
if tiles not in tile_sizes.keys():
    errors.append(f"Invalid value for 'tiles' in 'project' section: {tiles}")
```

Complete valid set (this PDK): `1x1, 1x2, 2x1, 2x2, 3x1, 3x2, 3x4, 4x1, 4x2,
4x4, 5x4, 6x1, 6x2, 6x4, 8x1, 8x2, 8x4`. The comment in
`tt-template/info.yaml` ("Valid values: 1x1, 1x2, 2x2, 3x2, 4x2, 6x2 or 8x2")
is stale and must not be used.

`tiles: "6x4"` is the exact YAML string (lowercase `x`, no spaces) with
`yaml_version: 6`. It selects:

| quantity | value |
|---|---|
| `DIEAREA` | `(0 0) (1289280 710640)` database units = **1289.28 x 710.64 um** |
| die area | **916,214 um^2** |
| DEF template | `tech/ihp-sg13cmos5l/def/tt_block_6x4_pgvdd.def` |
| standard-cell rows | 186 rows x 2674 sites, site 0.48 x 3.78 um |
| row area | **902,417 um^2** (98.5% of die) |
| budget at `PL_TARGET_DENSITY_PCT=60` | **541,450 um^2** |
| budget at 68.9% (proven by `core-asic`, 8x4) | 621,765 um^2 |
| measured flat cell area, this tree | **519,233.80 um^2** = 57.54 % of rows, 95.90 % of the 60 % budget (22,216.40 um^2 spare; `results/synth_v2_root.txt`) |

A 6x4 block is not 24 copies of a 1x1: its extra per-tile area is real
(37,601 vs 28,941 um^2 per tile) because the multi-tile DEF spans 1283.52 x
703.08 um of rows.

---

## 5. Runtime and disk (measured on this host)

| run | design | wall time | run-dir size |
|---|---|---|---|
| 1x1 smoke, full flow | 8x8 async-read RAM wrapper, TT ports | **129 s** | 43 MB |
| 6x4, full PROTEUS, PROG_DEPTH=32, density 65 | `src/tt_um_proteus.v` | **DRT >3 h 12 min, not converged** | 65 MB at step 44/80 |

1x1 smoke result: 80/80 flow steps, Magic DRC 0 errors, LVS 0 errors, antenna
0 violations, `timing__setup__ws = +9.16 ns` at the slow corner
(`nom_slow_1p08V_125C`, 20 ns period), 396 stdcells / 7,689 um^2.

6x4 results: both trees complete placement, detailed placement, CTS and global
routing, then stall identically in detailed routing with no iteration output:

| tree | density | post-GRT STA (20 ns, nom_typ) | DRT attempts |
|---|---|---:|---|
| v1 (4 engines, 64.4% rows) | 65 | setup +10.641 ns / hold +0.265 ns | 3 h 27 min; 1 h 01 min bounded |
| v2 (3 engines + assists, 57.54% flat area) | 60 | setup +11.0205 ns / hold +0.2878 ns | 40 min; 1 h 30 min; 80 min; 45 min single-thread |

All attempts have the same signature (zero-byte step log, empty `drt-run-0/`,
no DRC/unrouted report) and the image contains only one OpenROAD binary, so
this is the local aarch64 runtime, not density or threading. **No local
routed GDS exists**; the authoritative sign-off is the GitHub `gds.yaml`
action on x86_64 (see section 8). 50 MHz has large margin before routed
parasitics. Full evidence: `results/flow_report.md`.

`make synth` runtime: ~40 s for the bench rows plus ~5 min for the full chip.
The lean flow below was measured on the **v1** four-engine tree; v2's sign-off
number comes from `scripts/synth_full.sh` on the full flow
(`results/synth_v2_root.txt`, 519,233.80 um^2). The design target used a lean
yosys flow (`proc; memory_map; techmap;
dfflibmap; abc -liberty`) because yosys 0.33's `synth` script spends >15 min in
techmap/opt on a ~42k-cell top. On v1 the lean flow reports 568,294 um^2 where
the full flow reports 581,138.67 um^2 (-2.2%); use the full-flow number for
sign-off and the lean number for iteration. `abc -fast` is not usable
(889k um^2).

Disk plan for a real 6x4 run:

| item | size |
|---|---|
| LibreLane image (unpacked) | 5.9 GB |
| PDK checkout | 1.3 GB |
| run directory | 43 MB for 1x1; expect 0.5-2 GB for 25-40k cells (odb/GDS/SDF/reports) |
| **minimum free disk** | **~10 GB**, 20 GB comfortable |

Runtime for the real 6x4: TT's FAQ warns that 20-25 minutes or more usually
means the design is running out of tile area; the 8x4 `core-asic` precedent
(34.8k cells, 668k um^2, 68.9%) is the realistic upper bound. Plan on tens of
minutes to ~1-2 hours on 4 cores. The provided devcontainer caps the container
at 10 GB RAM; this host has 23 GB. `[INFERENCE]` for the unrun cases.

---

## 6. Blockers found, and the workarounds in these scripts

1. **`tt_tool.py` cannot run on this aarch64 host.** Its pinned requirements
   build `gdstk` from source (needs Qhull 8 headers, absent) and `klayout` from
   source; `python3 -m venv` + `pip install -r requirements.txt` fails. The
   `klayout==0.30.9` cp312 aarch64 wheel exists, but the `gdstk`/`cairosvg`
   chain still fails. Workaround: `scripts/flow.sh` reproduces
   `tt_tool.py --create-user-config` directly (same keys, same merge order,
   `project.py:486-503`) using only PyYAML. If you need the full tool (PNG
   render, precheck), run it inside an x86_64 container.
2. **`--force-run-dir` needs an existing directory.** LibreLane quits with
   `Directory 'runs/...' does not exist`. `flow.sh` runs `mkdir -p` first.
3. **The DEF template port check rejects non-TT port names.** A design with
   arbitrary ports fails `ApplyDEFTemplate` with `wdata[23] not found in
   template layout`. The top must expose exactly `ui_in`, `uo_out`, `uio_in`,
   `uio_out`, `uio_oe`, `ena`, `clk`, `rst_n`.
4. **`dir::` is relative to the config file**, i.e. `src/`, not the project
   root. `FP_DEF_TEMPLATE` must be `dir::../tt_block_6x4_pgvdd.def`, not
   `dir::tt_block_6x4_pgvdd.def`.
5. **Docker writes root-owned files.** With `--in-place`, `src/config_merged.json`
   and `runs/` become root-owned. Use the default staging mode (copy in
   `$STAGE`) or `chown` afterwards.
6. **yosys 0.33 liberty warning** (`unsupported expression 'SCE*SCD+!SCE*D' in
   pin attribute of sg13cmos5l_sdfrbp_*`). Harmless: those scan-FF cells are
   skipped by ABC and are not used by PROTEUS; plain FFs map to
   `sg13cmos5l_dfrbpq_1` (48.99 um^2).
7. **Version mismatch**: CI uses dev3, the IHP local guide requires dev4+. Pin
   dev4 locally or override the action input `librelane-version: 3.1.0.dev4`.

---

## 7. Gate-level test on the routed netlist

Once a run reaches `final/nl/`, run the official cocotb test against the
LibreLane netlist (TT's `GATES=yes` branch):

```sh
TOP=tt_um_proteus
RUN=$HOME/tt-stage/proteus/runs/wokwi          # or --stage directory
cp "$RUN/final/nl/$TOP.nl.v" test/gate_level_netlist.v
cd test && make -B GATES=yes
```

`test/Makefile` keeps the `GATES=yes` branch intact; it compiles
`gate_level_netlist.v` with Icarus and runs the same cocotb test. No SRAM
behavioural models are needed for v1/v2 (no macros instantiated). The IHP
netlist is unpowered (`nl`, not `pnl`), so do not look for `VPWR/VGND` ports.

## 8. Submission gate is CI, not this host

The authoritative Tiny Tapeout gate is `.github/workflows/gds.yaml` running
`TinyTapeout/tt-gds-action@ihp-cmos5l` on GitHub's x86_64 runners. This
aarch64 host proves the toolchain and produces area/pre-route timing locally,
but its 4-core open-source flow has not completed detailed routing for either
tree (v1 at a 65 % placement target, this tree at 60 %) within the local time
bounds; the signature is
identical at both targets, which points at the local tool/runtime, not at
the design being unroutable. Push the repo and let the action produce the
sign-off GDS, DRC/LVS and slow-corner timing. Do not read a local DRT
non-convergence as a tapeout failure.

If a local routed result is required, the next experiments in order are:
(1) rerun DRT single-threaded (`OPENROAD_THREADS=1`) as a threading test; if it
still prints nothing, (2) point the flow at another OpenROAD binary on `PATH`
(LibreLane has no binary-override variable; it uses `openroad` from `PATH`).

## 9. Reproduce from scratch

```sh
git clone <proteus> && cd proteus

# 1. toolchain
docker pull ghcr.io/librelane/librelane:3.1.0.dev4
make pdk                     # IHP-Open-PDK @2bbec755 into $HOME/pdk

# 2. area
make synth                   # -> results/synth.txt
make synth-design            # PROG_DEPTH=32 and 24 (needs src/)

# 3. GDS + timing
make flow                    # -> $HOME/tt-stage/proteus/runs/wokwi/final

# 4. evidence
cat results/synth.txt
cat results/area_baseline.md
```

Environment overrides: `PDK_ROOT`, `PDK_LIB`, `SRAM_PDK_LIB`, `YOSYS`,
`LIBRELANE_VERSION`, `LIBRELANE_IMAGE`, `TT_TOOLS`, `STAGE`, `RUN_TAG`,
`NO_FETCH=1` (never download a liberty), `DEPTHS="32 16"` (synth-design sweep).
