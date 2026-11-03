# Root tree final evidence (hybrid v2)

Tree under test: `/home/ubuntu/verilog` root, 12 RTL files in `src/`
(3 engines + 5 protocol-agnostic assists, 75 opcodes, VERSION 0x02).
Every number below is a quote from a file or from a command run in this
session; the command and the evidence file are named in each section.
`v1` (`legacy/v1/`) and `v2/` were not modified.

Files this task wrote:

| file | role |
|---|---|
| `formal/eng_formal.sv`, `formal/run.sh`, `formal/README.md`, `formal/.gitignore` | engine harness copied from `v2/formal/` with root paths |
| `results/formal_root/` (27 files) | prove + cover logs and `formal_summary_root.txt` |
| `results/mutation_root.md`, `results/mutation_root_raw.txt` | mutation report + raw log |
| `results/synth_v2_root.txt` | full synthesis log (area, ltp, flops, levers) |
| `results/final_evidence.md` | this file |
| `scripts/synth_full.sh` | **bug fix**: see §3.1 |

---

## 1. Formal: engine suite PASS

```sh
bash formal/run.sh            # sby prove + cover, smtbmc z3, .tools/oss-cad-suite
```

`results/formal_root/formal_summary_root.txt` (verbatim):

```
PROP  DEPTH  PROVE     COVER            NOTE
== tool versions ==
SBY v0.70-9-g79fc9ed
Yosys 0.70+290 (git sha1 e8968a4f7, Release, GNU /usr/bin/aarch64-linux-g++ 15.2.0)
E0    40     FAIL      REACHED(1/1)     control: FAIL is EXPECTED (probe liveness); cex in results/formal_root/formal_E0.txt
E1    40     PASS      REACHED(1/1)     
E2    40     PASS      REACHED(2/2)     
E3    40     PASS      REACHED(1/1)     
E4    48     PASS      REACHED(1/1)     
E4B   40     PASS      REACHED(1/1)     
E5    40     PASS      REACHED(1/1)     
E6    40     PASS      REACHED(2/2)     
E7    40     PASS      REACHED(1/1)     bounded proof ok; induction step did not converge
E8    40     PASS      REACHED(1/1)     
E9    40     PASS      PARTIAL(4/5)      PASS, but not every cover was reached: PARTIAL(4/5) unreached-cover-at: /home/ubuntu/verilog/formal/eng_formal.sv:400.5-400.19 
E10   40     PASS      REACHED(1/1)     
E11   40     PASS      REACHED(1/1)     
```

Acceptance set **E1–E8, E10, E11: PASS, and every antecedent cover was
reached** (E2 and E6 have 2 covers each; all reached).  Provenance:

* total wall time 453.6 s (`bash formal/run.sh` job, 2nd identical run; the
  first run, 11:00–11:07, produced the same table).
* E1 is a genuine k-induction proof, not just BMC — tail of
  `results/formal_root/formal_E1.txt`:
  `summary: engine_0 (smtbmc z3) returned pass for induction` /
  `summary: successful proof by k-induction.` / `DONE (PASS, rc=0)`.
* E7 is a **bounded** proof: basecase passes, the induction step was stopped by
  the 300 s cap — `formal_E7.txt:104`
  `engine_0.basecase: Status returned by engine for basecase: pass`, and the
  log ends with `SBY 11:06:51 ... engine_0.induction: terminating process`.
  The summary marks it `bounded proof ok; induction step did not converge`.
* E0 is the negative control and **is expected to FAIL**: it asserts the
  deliberately false bound `in_cnt <= FIFO_DEPTH - 1`
  (`formal/eng_formal.sv:260`; sby reports the failure at
  `eng_formal.sv:260.5-260.38`).  The only reachable value that can violate it
  is `in_cnt == 4`, i.e. the input FIFO's legitimate full occupancy, so the
  counterexample must come from the real FIFO probe — an unbound probe could
  not produce it, and a probe-name typo would be a hard yosys error rather
  than a vacuous PASS.
* E9 is a reachability audit, not an assertion.  Its 5 covers are
  `prog_ready, exec_act, dbg_pc>=1, halted, out_cnt>=1`
  (`formal/eng_formal.sv:397-401`).  `halted` (line 400) is unreachable in
  depth 40 **by construction**: E9 runs the default program
  `PROG0 = PUSH r0; PROG1 = JMP 0` (`formal/eng_formal.sv:190-192`), and the
  engine under test therefore never reaches a `HALT` word inside the bound.
  The four reached milestones are at steps 34/34/35/35
  (`formal_E9_cover.txt:77-81`).

Scope note (in `formal/README.md`): the top-level `T*` suite is **v1-only**
(`legacy/v1/formal/top_formal.sv`, `run.sh --top-only`).  It was not ported:
the v1 top already cost ~14 s per BMC step and needed depth ~70 before any
host-write antecedent was reachable, and the hybrid top adds five assist blocks
plus a second pin-merge stage.  Those properties are gated in simulation
instead (`sim/test_protocols.py`, `sim/test_diff.py`, `tb/tb_csr.v`,
`tb/top_e2e_tb.v`).

---

## 2. Mutation: 99 mutants, 95 killed (96.0 %)

```sh
python3 tools/mutate.py --verify-mutations          # 99/99 mutation specs apply cleanly
python3 tools/mutate.py --all --raw results/mutation_root_raw.txt
```

Tail (verbatim from the run):

```
mutations: 99  KILLED=95  SURVIVED=4
kill rate: 95/99 = 96.0% (survivors 4)
kills per bench: engine=49/99  top=64/99
elapsed: 974.8s

raw log -> /home/ubuntu/verilog/results/mutation_root_raw.txt
```

Survivors (all four are equivalent mutants, none is a coverage gap — full
argument with line references in `results/mutation_root.md` §2):

| id | location | mutation | why equivalent |
|---|---|---|---|
| C05 | `proteus_engine.v:1039` | PC wrap term → `1'b0` | `ADDR_W=5`, `LAST_PC=5'd31` is all-ones, `pc_r+1` wraps identically at depth 32 |
| H04 | `proteus_host.v:208` | `tx_byte[6-bit_cnt]` → `[7-bit_cnt]` | overwritten on the SCK falling edge (`proteus_host.v:306`) before sampling |
| T11 | `tt_um_proteus.v:232` | drop `~halted_mask` | `run_reg` HALT retirement (`:635`) + engine `restart` gate (`proteus_engine.v:300-301`) |
| T16 | `tt_um_proteus.v:230` | `wire [2:0] err_mask` → `[3:0]` | only consumer is `|err_mask` (`:725`); concat zero-extends |

Post-run confirmation (the mutator works on a scratch copy; the tree is not
touched): the 11 `src/*.v` sha256 values were compared against the hashes
recorded in `results/synth_v2_root.txt` → `files compared: 11 mismatches: 0`,
and both ported benches still pass:

```
$ bash tb/run.sh
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

(`logs/tb_top_e2e.log`: `--- top_e2e_tb: 400 checks, 0 errors ---`.)

---

## 3. Synthesis: measured area

```sh
OUT=results/synth_v2_root.txt bash scripts/synth_full.sh
```

Liberty: `~/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib`
(yosys 0.33).  Row area for 6x4: 902,417 um2; 60 % placement budget
541,450.20 um2.

| quantity | value | source line in `results/synth_v2_root.txt` |
|---|---:|---|
| **flat area** (sign-off number) | **519,233.8032 um2** | `Chip area for module '\tt_um_proteus': 519233.803200` (l. 47230) |
| flat mapped cells | **36,343** | `Number of cells: 36343` (l. 47202) |
| **row utilisation** | **57.54 %** | 519233.8032 / 902417 |
| 60 % budget | 95.90 % of 541,450.20, **22,216.40 um2 spare** | arithmetic |
| vs v1 shipped (581,138.67 um2, 64.40 %) | **−61,904.87 um2, −6.86 pp** | arithmetic |
| hierarchical sum of 13 modules | 538,016.13 um2 = 59.62 % | sum of the `Chip area for module` lines in the hierarchical section |
| engine, per instance | 132,741.24 / 132,576.77 / 131,313.72 um2 | l. 18723, 18762, 18801 |
| assist set (crc_bit 21,152.96 + assist_fifo 12,423.12 + shiftreg32 9,559.51 + nrzi 6,658.55+4,071.51 + manchester 2,912.07+3,077.18) | 59,854.90 um2 | same section |
| flops (mapped) | 4,446 | timing section, `(total)` |

Longest topological path (`ltp -noff`, flat netlist), verbatim:

```
Longest topological path in tt_um_proteus (length=64):
    0: \u_eng2.pc_r [3]
   ...
   64: $abc$190063$flatten\u_eng2.$0\regs[7][7:0][7] (via ...)
  ff: \u_eng2.regs[7] [7]
```

i.e. `u_eng2.pc_r[3]` → `u_eng2.regs[7][7]`, 64 levels, inside engine 2's
ALU/register cone.  The script's NLDM estimate for that cone (estimate, **not
STA** — no interconnect, no clock tree): 12.80 ns at the typical point
(63 levels), 6.21 ns intrinsic, 93.03 ns pessimistic upper bound.  12.80 ns
< 20 ns period, consistent with the post-GRT STA in `results/flow_report.md`
(+11.02 ns setup at 20 ns).

### 3.1 Gate that failed, and the fix

`scripts/synth_full.sh` as it stood **could not produce any number on this
tree**.  Its flows ran `chparam -set PROG_DEPTH 32 tt_um_proteus`; the hybrid
top has that parameter, so yosys renames the module to
`$paramod\tt_um_proteus\PROG_DEPTH=32'...` and the next command fails:

```
15.1. Executing HIERARCHY pass (managing design hierarchy).
ERROR: Module `tt_um_proteus' not found!
...
FileNotFoundError: .../d32.json     (timing + flop sections)
```

(first run of the script, logged in the pre-fix `results/synth_v2_root.txt`).
Fix, minimal: drop both `chparam` lines from the three heredocs (the module
default is already 32, and the top propagates `PROG_DEPTH` to the engine
instances), and **refuse** a non-32 `DEPTHS` entry explicitly instead of
silently synthesising the default.  Re-ran: `synth_full: wrote
results/synth_v2_root.txt`, all sections produced.

### 3.2 The published 497,927.19 um2 is not reproducible today

`v2/results/synth_v2.txt` (04:57) records `Chip area for module '\tt_um_proteus':
497927.190600`, 33,936 cells, 55.18 % — the number quoted in
`results/flow_report.md` and `docs/hybrid-architecture.md`.  Today, on
**byte-identical sources** (11/11 sha256 match the v2 log's own list) and with
the **same script**, the flow produces 519,233.8032 / 36,343:

| run | script | sources | flat area | cells |
|---|---|---|---:|---:|
| 04:57 (recorded) | `v2/scripts/synth.sh` | same sha256 | 497,927.1906 | 33,936 |
| today #1 | `scripts/synth_full.sh` (root) | same sha256 | 519,233.8032 | 36,343 |
| today #2 | flat yosys command, repeated | same sha256 | 519,233.8032 | 36,343 |
| today #3 | `v2/scripts/synth.sh` (`OUT=/tmp/v2check.txt`) | same sha256 | 519,233.8032 | 36,343 |

Three independent runs today agree exactly, so the current number is stable;
the 04:57 sample is not reproducible from the same inputs, which points at
mapping-order sensitivity inside yosys 0.33 / abc rather than at the RTL
[INFERENCE — the same `synth` + `abc` sequence yields different-but-equivalent
mapped netlists; the per-module hierarchical areas differ the same way, e.g.
the third engine maps to 131,313.72 today vs 132,695.96 in the old log].
Both numbers are **inside** the 60 % placement budget (519,233.80 = 95.90 % of
it), so the v2 decision does not change; the 57.54 % should replace 55.18 % as
the flat-area figure quoted for this tree.  The spread between the 04:57
sample and today's reproducible value is +21,306.61 um2 (+4.28 %); treat the
flat area at this tool version as good to a few percent, not to the last
digit.

### 3.3 Source list consistency: 12/12

```python
info = yaml.safe_load(open('info.yaml'))['project']['source_files']
src  = sorted(p.name for p in pathlib.Path('src').iterdir() if p.suffix in ('.v','.vh'))
# parsed PROJECT_SOURCES from test/Makefile and VERILOG_SOURCES from sim/Makefile
```

```
info.yaml : 12 True
test/Mk   : 12 True
sim/Mk    : 12 True
src/      : 12
all three identical to src/ and to each other: True
['assist_fifo.v', 'crc_bit.v', 'manchester_dec.v', 'manchester_enc.v', 'nrzi_dec.v',
 'nrzi_enc.v', 'proteus_assist.v', 'proteus_defs.vh', 'proteus_engine.v',
 'proteus_host.v', 'shiftreg32.v', 'tt_um_proteus.v']
```

### 3.4 Unintended overwrite (recorded, not hidden)

`scripts/synth_full.sh` hardcodes its engine depth sweep to
`results/synth_full_depth.txt`.  The two runs above rewrote that file (it held
the v1 sweep from 2026-11-02 23:27; v1 is not a git repo, so the old copy is
gone).  The file now contains the root tree's own sweep, generated
2026-11-03T11:16:51Z for `src/proteus_engine.v`
sha256 `c7f5449e…95ffc`: d32 9,589 cells / 132,277.698 um2, d24 7,690 /
110,324.8944, d16 6,723 / 90,041.4522.  No v1 number in this report depends on
it; v1 area evidence remains in `results/area_full.md` and
`results/flow_report.md` (581,138.67 um2), both untouched (mtime
2026-11-02 23:29 and 2026-11-03 10:15).  `results/synth_full.txt` (the v1 full log, 24 MB) was **not** touched:
the new run writes `results/synth_v2_root.txt` via `OUT=`.

---

## 4. Fast gates, re-run for the record

| gate | command | result | tail |
|---|---|---|---|
| test | `PATH=$PWD/.venv/bin:$PATH make -C test` | **PASS** | `test.test_project PASS 147690.00` / `TESTS=1 PASS=1 FAIL=0 SKIP=0` |
| sim | `cd sim && make smoke` | **PASS** | `proteus_v2_map PASS 187260.00` / `TESTS=1 PASS=1 FAIL=0 SKIP=0` |
| tb | `bash tb/run.sh` | **PASS 10 / FAIL 0** | `benches PASS=10 FAIL=0` (see §2) |
| selfcheck | `python3 tools/selfcheck.py` | **PASS** | `SELFCHECK PASS` |
| mutation catalogue | `python3 tools/mutate.py --verify-mutations` | **PASS** | `99/99 mutation specs apply cleanly` |

Notes:

* `cd test && make` **without** the virtualenv on `PATH` fails, and this is a
  real plumbing gap, not a design failure:
  `make: cocotb-config: No such file or directory` /
  `Makefile:58: /Makefile.sim: No such file or directory`.
  `test/Makefile` has no venv resolution (unlike `sim/Makefile`, which
  resolves `cocotb-config` itself), so the documented form
  `PATH=$PWD/.venv/bin:$PATH make -C test` (`docs/verification.md:56,401`) is
  the one that runs.  With it: `TESTS=1 PASS=1 FAIL=0`.
* `make smoke` runs one test on purpose (`COCOTB_TEST_FILTER=proteus_v2_map`);
  the full protocol suite is `make` / `make protocols` (6 tests).  Smoke was
  the gate requested here.
* Selfcheck tail (verbatim):
  `ok ISA table has 75 opcodes including 0x4E/0x4F/0x50` …
  `ok HALT retired RUN` / `SELFCHECK PASS`.

---

## 5. Summary of failures found (none papered over)

| # | item | status |
|---|---|---|
| 1 | `scripts/synth_full.sh` `chparam` on the hybrid top → `ERROR: Module 'tt_um_proteus' not found`; no area/ltp/JSON produced | **fixed** (chparam removed, non-32 depth refused), re-run produces all sections |
| 2 | flat area is 519,233.80 (57.54 %), not the published 497,927.19 (55.18 %) | **reported**; 3/3 today's runs agree; old sample not reproducible from identical sources + script; both inside the 60 % budget |
| 3 | `results/synth_full_depth.txt` (v1 sweep) overwritten by the script's hardcoded path | **reported**; file now holds the root sweep, v1 area evidence elsewhere untouched |
| 4 | bare `cd test && make` fails (`cocotb-config` not on PATH) | **reported**; documented `PATH=$PWD/.venv/bin:$PATH make -C test` passes |
| 5 | E7 induction does not converge (bounded pass only) | expected, carried over from v1; documented |
| 6 | E9 cover 5/5 unreachable (`halted` with a non-halting test program) | by construction; E9 is an audit, excluded from the PASS set |
| 7 | top-level `T*` formal suite absent for the hybrid top | **v1-only by decision**, rationale in `formal/README.md` |
