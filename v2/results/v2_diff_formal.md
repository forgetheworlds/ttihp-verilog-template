# v2 differential + engine formal

Status: **both gates PASS on the v2 tree.**  Differential: 209 programs,
16,122 compared cycles, **0 mismatches**.  Engine formal: **E1–E8, E10, E11
PASS at the v1 depths with every antecedent cover reached**; the E0 negative
control FAILs as designed; the E9 reachability audit reaches 4 of its 5
milestones (the 5th is unreachable by construction in that harness, §2.3).

Nothing outside `v2/` was written.  `v2/` additions:

| file | role |
|---|---|
| `v2/tools/diffgen.py` | corpus generator (adapted copy of `tools/diffgen.py`) |
| `v2/sim/test_diff.py` | lockstep DUT-vs-model differential (adapted copy) |
| `v2/sim/Makefile` | new `diff` target, own `SIM_BUILD`/results file |
| `v2/sim/.gitignore` | `results_diff.xml` added |
| `v2/formal/eng_formal.sv` | engine harness for the v2 port list |
| `v2/formal/run.sh` | sby prove + cover flow, engine suite only |
| `v2/formal/.gitignore` | ignores `work/` (generated `.sby` + solver dirs) |
| `v2/results/v2_diff_formal.md` | this report |

`results/formal_summary_v2.txt` and the per-property logs
`v2/results/formal_<PROP>{,_cover}.txt` are the raw evidence.
`v2/formal/work/` holds the generated `.sby` files and solver work dirs.

---

## 1. Differential: v2 RTL vs `v2/tools/model.py`

### 1.1 Contract carried over

Same contract as v1 `sim/test_diff.py`: the same words go into the RTL over the
real SPI host (`v2/sim/host.py`) and into `ProteusModel`, the model is aligned
on the DUT's `run_reg[0]` rising edge, and **every cycle** compares

```
pc, halted, run, r0..r7, z/c/n,
uio_out, uio_oe, uio_od, uo_out[7:2], the level on uio_in, irq, collision,
in/out FIFO logical contents + counts, capture count/overflow/newest event
```

Four v2-specific changes:

1. **`ProteusModel(nsms=3)`** — the v2 build has three engine lanes (v1: 4).
2. **The two lanes the corpus does not run are asserted idle every cycle**
   (`u_eng1`/`u_eng2`: `halted_r == 1`, `pc_r == 0`, `out_cnt == 0`).  In v1
   the engines the corpus did not run were not checked; in the 3-engine top a
   `run_reg` bit or engine-index miswire would otherwise show up only as an
   unexplained pad mismatch.
3. **Corpus guard.**  `_corpus()` decodes every word and raises if
   `LDAS`/`STAS`/`ASST` appears, and `v2/tools/diffgen.py --check` asserts the
   same invariant (`ASSIST_OPS`).  The exclusion is a scope decision, §1.5.
4. Everything else — pad model, restart/alignment state machine, the
   4-word auto-increment load frame, `UO_FABRIC_MASK = 0xFC` — is the v1 code
   unchanged, so a v1/v2 difference cannot come from the driver.

Why the pads are still engine-owned in v2: the assist pin-merge stage is gated
by `PINCFG[7]`, and `v2/src/proteus_assist.v` resets all five PINCFG registers
to `8'h00` (`pincfg[0..4] <= 0`, lines 654-656), so `ap_uo_m/ap_uio_m/ap_oe_m/
ap_od_m` stay `0` and the extra merge stage is the identity.  The empirical
confirmation is that `uio_out/uio_oe/uio_od/uo_out[7:2]` match the model on
every compared cycle.

### 1.2 Corpus (identical to the v1 acceptance corpus)

`v2/tools/diffgen.py` is the v1 generator: `gen_program(seed)` is deterministic
(`random.Random(0x5EED0000 + seed)`), nine kinds, ≤32 words ending in `HALT`,
plus the nine hand-built corners (`corner_data_extremes` … `corner_bar_irq`).
The only edits are the v2 path references, the depth justification (the v2
model also uses `FIFO_DEPTH = CAPTURE_DEPTH = 4`, so the ≤4 push / ≤4 capture
budget keeps both sides inside the same parameter), the `ASSIST_OPS` guard and
`nsms=3` in `--check`.

`v2/tools/diffgen.py --check 200` (model only, no RTL):

```
corner corner_data_extremes     words=16 cycles=  16 halt=True
corner corner_shifts            words=17 cycles=  17 halt=True
corner corner_carry_chain       words=13 cycles=  13 halt=True
corner corner_pin_overlap       words=15 cycles=  15 halt=True
corner corner_waitp_timeout     words= 6 cycles= 262 halt=True
corner corner_capture           words= 8 cycles=  11 halt=True
corner corner_pacer_fractional  words=16 cycles= 310 halt=True
corner corner_djzn_wrap         words= 6 cycles= 261 halt=True
corner corner_bar_irq           words= 8 cycles=   8 halt=True
programs=200+9 halted=209 worst_cycles=780 (seed 141)
opcodes seen=69/75  missing_required=[]  assist_ops_excluded=('LDAS', 'STAS', 'ASST') seen=[]
```

Shape of the 209-program corpus (measured by running it on the model):

| item | value |
|---|---|
| programs | 209 = 200 seeds + 9 corners |
| words min/mean/max | 6 / 13.5 / 31 |
| cycles min/mean/max | 6 / 77.1 / 780 |
| cycles total | 16,122 |
| kinds | `alu` 23, `pins` 23, `ctrl` 22, `loop` 22, `wait` 22, `fifo` 22, `irq` 22, `capture` 22, `mix` 22, `corner` 9 |
| opcodes exercised | 69 of 75; never emitted: `MOVI`, `NOP`, `ASSERT` (the same three were never emitted in v1, 69/72) and the three assist opcodes that are excluded by design. `missing_required=[]`: the entire required safe subset is hit |

### 1.3 Command and result

```sh
cd /home/ubuntu/verilog/v2/sim && make diff          # DIFF_SEEDS=200, DIFF_CYCLES=3000
```

`make diff` is the new target: `COCOTB_TEST_MODULES=test_diff`,
`SIM_BUILD=sim_build/diff`, `COCOTB_RESULTS_FILE=results_diff.xml`, so it does
not disturb the default `test_protocols` build/results.  Tail (full log in
`/tmp/v2_diff_200.log`):

```
[207/209] seed=9007 corner  words=16 cycles= 310 halt
[208/209] seed=9008 corner  words= 6 cycles= 261 halt
[209/209] seed=9009 corner  words= 8 cycles=   8 halt
DIFF PASS: 209 programs, 16122 compared cycles, 0 mismatches (0 cut at the 3000-cycle limit)
test_diff.proteus_diff         PASS     9737490.00         109.38
** TESTS=1 PASS=1 FAIL=0 SKIP=0            9737490.00         109.38
```

| item | value |
|---|---|
| programs compared | 209 / 209 |
| compared cycles | **16,122** |
| mismatches | **0** |
| programs cut at the 3000-cycle limit | 0 (every program halted on both sides) |
| simulated time | 9,737,490 ns @ 10 ns clock |
| cocotb process time | 109.38 s |
| X/Z on any compared signal | none (a read of X/Z is a mismatch, `_v()` returns `None`) |
| `ERROR`/`MISMATCH` lines in the log | 0 |

The cycle count and simulated time are bit-identical to the v1 run
(`results/diff_report.md`: 209 programs, 16,122 cycles, 9,737,490 ns), which is
the expected outcome: the engine core is the v1 file plus the assist port and
the corpus is the same, so the compared trajectory must not move.

### 1.4 Negative control (the harness can fail)

A green differential is worthless if the comparison is dead, so one mutation
was injected, observed, and reverted.  `v2/tools/model.py`, `INC`:

```diff
-                r = alu("ADD", a, 1)
+                r = alu("ADD", a, 2)
```

`DIFF_SEEDS=3 make diff`:

```
DIFF MISMATCH seed=0 kind=alu cycle=5996 field=r6 model=0x2 rtl=0x1
AssertionError: seed 0 (alu) cycle 5996: r6 model=0x2 rtl=0x1
** TESTS=1 PASS=0 FAIL=1 SKIP=0
```

Reverted; `sha256sum v2/tools/model.py` is
`c684e0f6e8c551842cab441249c5ec76b4cefcf12d9c2623052f1a746fd5b0e4` before and
after the mutation, i.e. the file shipped here is the untouched v2 model.

### 1.5 What this run does not prove

* **Assist instructions are outside the compared subset.**  `v2/tools/model.py`
  models the assist *register/queue/timing* accounting (CRC fold counter, FIFO
  push/pop/level/burst, shift push/pop, NRZI/Manchester queue occupancy), not
  the data path: the CRC bit order against the CSR pages, the shift-register
  byte framing, and the NRZI/Manchester line codes are not modelled.  A
  cycle-exact comparison there would compare an approximation, so
  `LDAS`/`STAS`/`ASST` are excluded and the invariant is asserted, not assumed.
  Assist evidence remains outside this gate: `v2/tools/selfcheck.py`,
  `v2/tb/tb_csr.v` (37 checks, including `STAS`/`LDAS`/`ASST` programs on
  engine 0) and the MII test in `v2/sim/test_protocols.py` — as recorded in
  `v2/results/v2_verify.md` §2/§4 and re-run in §3 below (6/6 PASS), not
  re-derived here.
* **One engine lane.**  Only engine 0 executes; the other two are checked idle,
  not exercised.  Multi-engine interaction (pin-merge priority, barrier graph)
  is not covered by this gate; per `v2/results/v2_verify.md` it is covered by
  `v2/tb/tb_csr.v`/`tb_top_smoke.v` and the I2C test in
  `v2/sim/test_protocols.py` (engines 2+1), which passed in the §3 re-run.
* **Host-window semantics** are not part of this comparison (the model has no
  address map); they are gated by the `proteus_v2_map` test and `tb_csr`.

---

## 2. Engine formal: `v2/formal/`

### 2.1 Harness adaptation

`v2/formal/eng_formal.sv` is the v1 harness ported to the v2 port list.  The
engine core, the probe names, the property set, the test programs and the
depths are unchanged, so the two suites are directly comparable.

Three port-level additions:

* **assist CSR port tied to defined values.**  DUT inputs `as_rdata = 8'h00`
  and `as_empty = 1'b1`; DUT outputs `as_rd/as_wr/as_id/as_reg/as_wdata/
  as_cmd_en/as_cmd_id/as_cmd` are declared and read into a `_unused` wire so
  yosys cannot prune the assist decode.  No formal program contains an assist
  opcode, so the tied response never reaches an architectural register — it
  only removes an unconstrained DUT input.
* **`halt_exec`** is connected and unused: the RUN-retire path it feeds is a
  top-level property (out of scope), while E8 constrains `halted`/PC directly.
* `PROG_DEPTH = 32`, `FIFO_DEPTH = 4` defaults, no parameter overrides (an
  override renames the module and breaks `select -module proteus_engine`).

`v2/formal/run.sh` is the engine half of `formal/run.sh`: sby, `smtbmc z3`,
`expose`/`flatten`/`connect -set` probe binding, prove task plus a cover task on
the same bound.  The top-level T\* suite and the X-freedom sim are not ported
(§2.5).

### 2.2 Property table

```sh
cd /home/ubuntu/verilog && ./v2/formal/run.sh          # 462 s wall, 13 properties
```

`v2/results/formal_summary_v2.txt`:

```
PROP  DEPTH  PROVE     COVER            NOTE
== tool versions ==
SBY v0.70-9-g79fc9ed
Yosys 0.70+290 (git sha1 e8968a4f7, Release, GNU /usr/bin/aarch64-linux-gnu-g++ 15.2.0)
E0    40     FAIL      REACHED(1/1)     control: FAIL is EXPECTED (probe liveness); cex in results/formal_E0.txt
E1    40     PASS      REACHED(1/1)
E2    40     PASS      REACHED(2/2)
E3    40     PASS      REACHED(1/1)
E4    48     PASS      REACHED(1/1)
E4B   40     PASS      REACHED(1/1)
E5    40     PASS      REACHED(1/1)
E6    40     PASS      REACHED(2/2)
E7    40     PASS      REACHED(1/1)     bounded proof ok; induction step did not converge
E8    40     PASS      REACHED(1/1)
E9    40     PASS      PARTIAL(4/5)      PASS, but not every cover was reached: PARTIAL(4/5) unreached-cover-at: .../eng_formal.sv:400.5-400.19
E10   40     PASS      REACHED(1/1)
E11   40     PASS      REACHED(1/1)
```

Property meaning (unchanged from v1):

| prop | property | v1 depth | v2 depth | v2 result |
|---|---|---:|---:|---|
| E0 | control: `in_cnt <= FIFO_DEPTH-1` — must FAIL | 40 | 40 | FAIL (expected) |
| E1 | `dbg_pc < PROG_DEPTH` (PC bound) | 40 | 40 | PASS |
| E2 | FIFO occupancy ≤ depth, `full == (cnt == depth)`, not full+empty | 40 | 40 | PASS |
| E3 | no write into a full input FIFO (`in_wr` frozen) | 40 | 40 | PASS |
| E4 | no pop from empty / no push into full (push program) | 48 | 48 | PASS |
| E4B | same invariants with the PULL program (input-FIFO half) | 40 | 40 | PASS |
| E5 | host pop on empty does not advance `out_rd`/count | 40 | 40 | PASS |
| E6 | nothing executes before `prog_ready`; no pin-write bus driven | 40 | 40 | PASS |
| E7 | `BAR` cannot advance while waiting and unreleased | 40 | 40 | PASS (bounded; induction does not converge, as in v1) |
| E8 | HALT sticky, PC frozen while `run` high | 40 | 40 | PASS |
| E9 | reachability audit (covers only) | 40 | 40 | 4/5 covers, see §2.3 |
| E10 | `prog_ready` is a one-way latch | 40 | 40 | PASS |
| E11 | program memory has no engine self-modification path | 40 | 40 | PASS |

Every depth is the v1 value; E4 at 48 is the only non-40 bound (48 is what the
output FIFO fill needs), exactly as v1.

### 2.3 Non-vacuity, and the E9 audit

Each property's antecedent has a matching `cover()`, and the cover task runs on
the same bound, so a PASS whose antecedent was never exercised would print
`PARTIAL(...)`.  Every PASS row above is `REACHED(n/n)` except E9.

E9 is not a property — it is the boot-ladder audit, five `cover()`s only, and
its program is the `PUSH; JMP 0` loop (PROP_E9 falls into the default program),
which never halts.  Measured:

| milestone | reached |
|---|---|
| `prog_ready` | step 34 |
| `exec_act` | step 34 |
| `dbg_pc >= 1` (first retire) | step 35 |
| `halted` | **not reached** — the E9 program loops forever by construction |
| `out_cnt >= 1` | step 35 |

`eng_formal.sv:400` is `cover (halted);`; that is the single unreached entry in
`v2/results/formal_E9_cover.txt`.  The same cover is unreached in the v1 run
(`results/formal_E9_cover.txt`, line 360), i.e. v2 reproduces v1 behaviour.
The v1 summary printed `PARTIAL(6/7)` for that log; the log itself has 4
reached and 1 unreached.  `v2/formal/run.sh` counts covers from sby's summary
block only (the per-step `Unreached cover statement` line and the summary list
describe the same cover, and counting both is what inflated the v1 number to
6/7).  Because E9 carries no assertion, its `PASS` must be read as "the cover
task ran", not as a proof; the audit value is the milestone column above.

### 2.4 Probe liveness (E0) and the proof path

E0 asserts the *wrong* bound (`in_cnt <= FIFO_DEPTH-1`) so a live, bound probe
must produce a counterexample:

```
engine_0.basecase: ## 0:00:00  Assert failed in eng_formal: .../eng_formal.sv:260.5-260.38
engine_0.basecase: ## 0:00:00  Status: failed          (step 6)
```

That is `assert (in_cnt <= FIFO_DEPTH - 1)` at the v2 harness line 260; the
solver reaches `in_cnt == 4` from a host push at step 6, so the FIFO probes are
bound to the DUT and not to undriven wires.  Probe widths are enforced by
`connect` (it aborts on a mismatch), which is why the harness carries
`PROG_DEPTH`/`FIFO_DEPTH` parameters and E2 asserts `full == (cnt == depth)`.

E7 is `PASS` on the basecase with the induction step not converging
(`Status returned by engine for basecase: pass`, no `successful proof by
k-induction`, no `Assert failed`).  That is a bounded proof at depth 40, the
same reading v1 recorded.

### 2.5 Not ported (and why)

* **Top-level T1–T7.**  Out of scope for this phase.  The v2 top is the v1 top
  plus five assist blocks and a second pin-merge stage: bigger than the v1 top
  that already cost ~14 s per BMC step with z3, and the behaviours those
  properties target (host strobes, pin merge, barrier graph, HALT-instr RUN
  retire) are exercised at simulation level by `v2/sim/test_protocols.py`,
  `v2/sim/test_diff.py` (RUN retire + idle lanes every cycle) and
  `v2/tb/tb_csr.v`/`tb_top_smoke.v`.  They remain v1-only formal evidence.
* **X-freedom (`formal/xcheck_tb.v`, v1 `X1`).**  It drives the v1 top and does
  not compile against v1's declaration order; porting it to v2 is a top-level
  task.  The differential covers the same ground dynamically: any X/Z on a
  compared signal raises a mismatch, and 0 mismatches were observed over 16,122
  cycles.

---

## 3. Regression: pre-existing v2 gates

`v2/sim/Makefile` gained a `diff` target ahead of the cocotb include, so the
default goal was re-checked:

```sh
cd /home/ubuntu/verilog/v2/sim && make        # still COCOTB_TEST_MODULES=test_protocols
```

```
test_protocols.proteus_uart_tx_pins           PASS
test_protocols.proteus_uart_rx_pins           PASS
test_protocols.proteus_spi_master_pins        PASS
test_protocols.proteus_i2c_master_pins        PASS
test_protocols.proteus_ethernet_mii_tx_pins   PASS
** TESTS=6 PASS=6 FAIL=0 SKIP=0      9352290.01 ns   76.20 s
```

(`proteus_v2_map` is the 6th test and is inside that PASS=6 count.)  The other
v2 suites were not re-run: `v2/tb/run.sh`, `v2/test/` and `v2/tools/selfcheck.py`
do not import `diffgen`, `test_diff` or the formal harness, and no file they
read was modified by this work.

**Shared tree, verified.**  Another phase was writing `v2/tb`/`v2/tools`
concurrently (`v2/tb/engine_smoke_tb.v`, `v2/tb/top_e2e_tb.v`,
`v2/tools/mutate.py`, `v2/results/v2_mutation.md` appeared during this session).
The measurements above therefore had to be checked against the RTL that is on
disk now: all 11 `v2/src/*.v` match the sha256 values recorded at synthesis time
in `v2/results/synth_v2.txt` (the only difference in that comparison is
`proteus_defs.vh`, an include that report does not list), and every `v2/src`
mtime predates this session.  So the differential and the proofs were taken
against the shipped RTL, not against a temporarily mutated copy.

---

## 4. Remaining v1-only evidence

Status of every v1 gate, as of this report.  Two are closed here; the bench and
mutation rows changed under this session because a concurrent phase ported them
into `v2/` — those ports are listed as *not verified by this work*.

| v1 gate | status |
|---|---|
| `sim/test_diff.py` (209 programs, 16,122 cycles, 0 mismatches) | **closed** — `v2/sim/test_diff.py`: same corpus size, same cycle count, 0 mismatches |
| `formal/` engine suite E0–E11 | **closed** — `v2/formal/`: same properties, same depths, PASS; E9 cover 4/5 (same unreached cover as v1) |
| `formal/` top suite T1–T7 | **v1 only** — not ported (§2.5) |
| `formal/xcheck_tb.v` (X1, top-level 4-state sim) | **v1 only** — not ported (§2.5) |
| `tb/engine_smoke_tb.v` (directed per-instruction engine smoke) | **ported by the concurrent phase** to `v2/tb/engine_smoke_tb.v`; not run/verified here.  This work's substitute for the ISA core is the differential (every reachable ISA-core instruction vs the model, every cycle) |
| `tb/top_e2e_tb.v` (barrier, capture drain, 2^24 pacer boundary, stale-PC restart, HOST_DISABLE) | **ported by the concurrent phase** to `v2/tb/top_e2e_tb.v`; not run/verified here |
| `results/mutation.md` (mutation score of the v1 suite) | **ported by the concurrent phase**: `v2/tools/mutate.py` + `v2/results/v2_mutation.md` (report marked *in progress* when this was written); not verified here.  The control in §1.4 is a single targeted mutant, not a mutation score |
| `tb/host_tb.v` (directed SPI host bench) | **v1 only** — no `v2/tb` equivalent; every v2 test drives the real host, but no directed host bench exists |
| `tb/top_stub_tb.v`, `tb/top_capdepth_tb.v`, `tb/top_depth64_tb.v` (stubs, `CAP_DEPTH`, `PROG_DEPTH=64`) | **v1 only** — no v2 equivalent |
| LibreLane flow, routed GDS, DRC/LVS, STA | **v1 only** — v2 has flat synthesis (`results/synth_v2.txt`) only |
| `test/Makefile GATES=yes` (gate-level harness) | **v2 branch exists, not runnable** (no v2 netlist) |

---

## 5. Reproduce

```sh
cd /home/ubuntu/verilog

# corpus sanity on the model alone (no RTL)
.venv/bin/python v2/tools/diffgen.py --check 200

# differential: 209 programs, 16,122 cycles
cd v2/sim && make diff && cd ../..

# engine formal: E0..E11, same depths as v1
./v2/formal/run.sh

# evidence
v2/results/formal_summary_v2.txt
v2/results/formal_<PROP>.txt          # prove
v2/results/formal_<PROP>_cover.txt    # cover / non-vacuity
v2/sim/results_diff.xml               # cocotb result of the differential
```

Artifacts are regenerable; `v2/sim/sim_build/diff/`, `v2/sim/results_diff.xml`
and `v2/formal/work/` are build outputs (the first two are gitignored).
