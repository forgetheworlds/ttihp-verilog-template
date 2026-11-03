# How PROTEUS was built

An auditable account of the autonomous engineering process behind this
repository: who did what, which decisions were driven by measurable evidence,
which failures were found by which mechanism, and what the process did **not**
establish. Every claim cites the artifact that contains it. Where no artifact
exists, that is stated rather than narrated.

Model: **DeepSeek V4.1 Flash via OMP**. The work was executed by an orchestrating
agent plus parallel specialist agents, each owning a disjoint file set (RTL,
tools/model, verification, physical flow, FPGA, docs, integration). Agents
communicated through a shared run store and a message channel; the orchestrator
adjudicated cross-cutting decisions (ISA layout, program depth, pacer
semantics, address geometry, the v1 -> v2 cutover) and those rulings are quoted
in the source files they affected.

Honesty note on provenance: this document was written by the documentation
agent from repository artifacts, not from a transcript. Where the artifact
records a decision (a `DECISION` comment, a failing test, a synthesis log), that
is cited. Where it does not, the item says so.

---

## 1. Phases

| phase | output | evidence in the tree |
|---|---|---|
| 1. Constraints research | tile geometry, cell budget, pad limits, flow commands | `research/tt-ihp-constraints.md`, `research/protocols.md`, `research/prior-art.md`, `research/bit-engines.md` |
| 2. Architecture + ISA contract | pin map, register map, engine semantics, 24-bit ISA | `docs/architecture.md`, `docs/isa.md`, `tools/isa.py` |
| 3. Area feasibility before RTL | program-RAM cost model, depth ruling | `results/area_baseline.md`, `results/synth.txt`, `results/yosys_bench_*.log` |
| 4. RTL (v1) | engine, host SPI, top | `legacy/v1/src/` |
| 5. Tools | assembler, cycle model, generators | `tools/asm.py`, `tools/model.py` |
| 6. Firmware | UART TX/RX, SPI, I2C, blink; later Ethernet | `firmware/*.asm` |
| 7. Verification | Icarus benches, cocotb, formal, differential, mutation | `tb/`, `sim/`, `formal/`, `v2/formal/` |
| 8. Physical | synthesis, area, LibreLane attempts | `results/area_full.md`, `results/flow_report.md`, `v2/results/synth_v2.txt` |
| 9. FPGA bring-up | self-hosting DE2 build (v1 only) | `fpga/`, `legacy/v1/fpga/` |
| 10. Hybrid area study | 5 measured assist blocks, 7 engine-count options | `results/hybrid_area.md`, `docs/hybrid-architecture.md` |
| 11. v2 integration | assists + CSR opcodes + 3-engine top | `src/proteus_assist.v`, `src/tt_um_proteus.v`, `src/proteus_defs.vh` |
| 12. v2 verification parity | TT harness, protocol E2E, differential, formal, mutation, benches | `v2/results/v2_verify.md`, `v2/results/v2_diff_formal.md`, `v2/results/v2_mutation.md` |
| 13. Cutover | v2 became the root tree; v1 frozen | `legacy/v1/`, root `src/` with 12 files |
| 14. Documentation | this set | `README.md`, `docs/`, `info.yaml` |

---

## 2. Decisions and the evidence that drove them

### 2.1 The 7-bit opcode (ISA revision 2)

The first ISA draft placed `op` in bits `[23:18]` (6 bits) but assigned opcodes
up to `0x4D` to the system group. A 6-bit field cannot encode `0x40..0x4D`, so
those instructions were unrepresentable - the assembler and the RTL could not
agree on any system instruction.

Evidence and fix: `docs/isa.md` §1 "Revision note" states that `op` was widened
to 7 bits and every other field moved down one, with **all opcode numbers
unchanged**. The constraint is asserted in code: `tools/isa.py` has
`assert OP_SHIFT + OP_BITS == 24` plus the opcode-table assertions, and the
`proteus_defs.vh` macros are now `7'hxx` (they were `6'hxx` at the time of the
first draft; the width was corrected, not just zero-extended harmlessly). The v2
additions keep the same format: the table asserts
`len(OPC) == len(OPS) == 75`.

### 2.2 `PROG_DEPTH = 32` from area arithmetic

The architecture document originally specified 64 instructions per engine. The
area baseline measured the cost before the RTL existed:
`results/area_baseline.md` reports 64x24 flip-flop program RAM at
**123,128.81 um^2 per engine**, i.e. **492,210.43 um^2 for four engines = 90.9%
of the 60% placement budget (541,450 um^2)** - program memory alone. At 32 deep
the same table shows 61,548.08 um^2 per engine.

The ruling is recorded in `src/tt_um_proteus.v` decision 1 and in
`results/area_baseline.md`. Depths 24 and 16 measured *larger* than 32 in the
first flow (596,652.25 and 597,675.76 um^2) because `ADDR_W` stayed 5, so 32
stayed. Two v2 consequences: `PDEPTH` is now 7 bits, so a 64-deep build loads
correctly (the v1 6-bit truncation defect is fixed); and the default build is 32
deep, which is what every firmware image is measured against.

### 2.3 The 32-bit pacer after the 2^24 defect

An early pacer kept the deadline as a packed 24.8 word. That truncates the
integer part at 2^24 cycles, after which the deadline is permanently in the past
and `PACE` free-runs at one completion per cycle - a silent timing failure that
only appears after 2^24 cycles.

Evidence: `src/proteus_engine.v` decision 2 states the deadline is
`next_int` (32-bit) plus `next_frac` (8-bit), with the carry propagated. The
defect is pinned by `legacy/v1/tools/tests/test_model.py::test_pace_survives_the_24_bit_boundary`
(v1 test, archived) and by the v2 model probe in `demos/run_demos.py`:

```
pacer probe @cycle 2^24: 100 completions in 9802 cycles (period=100) -> 98.0 cycles/completion: exact
```

The phase convention (first interval is `period - 1` after `PACERST`) is
documented in `docs/isa.md` §3.1 rather than silently corrected in the RTL.

### 2.4 `HALT` retiring `RUN` (formal counterexample)

`HALT` clears the engine's run bit. The top originally drove `run_reg` from host
writes only, so a halted engine still reported `RUN = 1`. The fix computes
`halt_mask` from per-engine `halt_exec` outputs and applies
`run_reg <= run_reg & (~halt_mask)` on every cycle no host write wins
(`src/tt_um_proteus.v`, run/halt block). In v2 the mask is 3 bits and the host
`RUN`/`HALT` writes mask `reg_wdata[2:0]`.

Evidence: engine formal E8 ("HALT is sticky, PC frozen while run high") PASS at
depth 40 in `v2/results/formal_summary_v2.txt`; simulation checks in
`tb/engine_smoke_tb.v`, `sim/test_protocols.py` and `tb/top_e2e_tb.v` phase
`[3]`/`[4c]`, including "RUN bit2 retired by HALT".

### 2.5 The barrier combinational loop (found by lint)

`BAR` must not depend on its own release signal. The first wiring had each
engine's `bar_req` depend on `bar_go`, which the top derives from the arrivals
that include `bar_req` - a combinational loop. The ruling is recorded in
`src/tt_um_proteus.v` decision 8: `bar_req` must not depend on `bar_go`;
`bar_go` only gates the engine's `BAR` advance, per engine and gated by that
engine's own barrier id.

Evidence: engine formal E7 ("OP_BAR cannot advance while it waits and the
barrier is not released") PASS at depth 40 in v2 (bounded; the induction step
does not converge, same as v1); `tb/top_e2e_tb.v` phase `[5]` logs both pads
leaving in the same cycle (`uio0=62156 uio1=62156` in the v2 port).

### 2.6 Engine-window geometry 0x20 instead of 0x10

The register map documented engine windows with a 0x10-byte stride while also
defining offsets `0x00..0x15`. Those cannot both hold: at stride 0x10,
`base + 0x10` is the next engine's base. Ruling: stride 0x20, base
`0x0010 + 0x20*e`, region `0x0010..0x006F` for three engines
(`PROTEUS_EW_END` in `src/proteus_defs.vh`; v1 ended at `0x008F`).

### 2.7 `SCK <= clk/8`, not `clk/4`

The host slave synchronises `SCK` through two flip-flops and derives both edges
from the synchronised clock; a registered `MISO` that changes on the synchronised
falling edge then needs 3 clocks from the raw edge, which `clk/4` does not
leave. `src/proteus_host.v` decision 3 records `clk/8` clean, `clk/6` marginal,
`clk/4` short by one clock.

### 2.8 The output-FIFO read/pop race (found by the cocotb smoke)

The engine drives `host_out_data` combinationally from the head of `out_mem` and
advances `out_rd` on `host_out_pop`; the top asserted `host_out_pop` in the same
cycle as `reg_re`, while `proteus_host` samples `reg_rdata` one clock later. The
host therefore captured the post-pop head and read `0` from a FIFO with one
entry. Recorded symptom, verbatim from the v1 run
(`legacy/v1/sim/results.xml`):

```
[3] registers / FIFO / HALT retires RUN: 1 of 9 checks failed:
OUT_FIFO byte from PUSH r1: got 0 expected 60
```

Fix: register the pop one cycle so the host samples the pre-pop head. The v2
successor of that check is `tb_csr`'s host FIFO DATA push/pop level and order
(37 checks) and the assist FIFO DATA path in `tb/top_e2e_tb.v` phase `[4d]`.

### 2.9 Hybrid study: three engines plus assists (the v2 decision)

v1 did not route at 64.4 % row area locally (`results/flow_report.md`), and
Ethernet was the protocol that did not fit: **230 words** measured for one
complete 802.3 frame against a 32-word engine (`results/ethernet.md`). The
response was measured, not argued: five protocol-agnostic blocks were built and
synthesised standalone (`studies/hybrid/rtl/`, numbers in
`results/hybrid_area.md`), then seven engine-count options were costed.

The ruling is `docs/hybrid-architecture.md` option B': **3 engines + the
bit-serial CRC variant**, predicted 506,883.22 um2 / 56.17 %. The decisive
number (study blocks, `results/hybrid_area.md`): one engine is 132,381.80 um2,
the entire assist set 60,590.57 um2, so
"4 engines + assists" is 655,611.28 um2 = 72.65 %, above the highest density
this project has routed (68.9 %). Assists and the fourth engine were mutually
exclusive. The shipped build measured **519,233.80 um2 flat = 57.54 %**
(`results/synth_v2_root.txt` line 47230; 36,343 cells), which is
**12,350.58 um2 (+1.37 pp) above** the study prediction, not below it. The
study budgets only 2,000 um2 of unmeasured integration glue
(`docs/hybrid-architecture.md` §5.4 and §8 R4), far
short of 12,350.58 um2, and this document does not claim to know which line item
accounts for the remainder. The gap is recorded rather than explained away
(`results/final_evidence.md` §3.2, `docs/verification.md` §2.9).

The functional payoff: the same frame in **31 words**
(`firmware/ethernet_mii_tx.asm`), FCS `0xE7C87B32` equal to `zlib.crc32` at the
pads (`v2/results/v2_verify.md` §4).

### 2.10 v2 integration defect D1: the program window ended one page early

This is the clearest example of a new verification layer catching a defect that
review did not. The v2 TT harness and protocol suite loaded firmware into
engines 0, 1 and 2 over the real SPI host. Engine 2 failed:

```
engine 2 page 0x0300 -> write 11 22 33, read back [0, 0, 0]      BROKEN
0x0304 / 0x03FC      -> writes dropped, reads 0x00               BROKEN
```

Root cause: `PROTEUS_PM_END` was `0x02FF`, the two-engine count. Engine 2's
page `0x0300..0x03FF` was unreachable, which would have killed
`spi_master.asm` and the START/WRITE half of `i2c_master.asm` on silicon while
the model suite stayed green (the model has no address map).

Fix, approved and minimal: `0x03FF`, one constant, no decode redesign.
Permanent regression: `sim/test_protocols.py::proteus_v2_map` (25 checks) writes
and reads back all three pages, checks the last programmable word `0x037C`,
checks `0x03FC` reads 0 without aliasing engine 2 word 0, and checks `0x0400`
(the v1 engine-3 page) reads 0 without aliasing engine 2. Full record:
`v2/results/v2_verify.md` §5.

A second, smaller finding from the same phase: the TT test had been written for
a program that loops forever ("write RUN, then count 160 clocks"); the v2 test
program ends in `HALT` and finishes its toggles while the ~280-clock SPI frame
that writes `RUN` is still on the wire, so the pad monitor must be started
before the write. That is a test-construction correction, recorded in
`v2/results/v2_verify.md` §2.1.

### 2.11 Cutover

The adoption rule stated in the previous submission audit was: v2 replaces v1
only after it passes the same protocol, differential, formal and physical gates.
The functional gates were closed (`v2/results/`): TT harness PASS, protocol
6/6, differential 209/16,122/0, engine formal E1-E8/E10/E11, mutation 96.0 %,
benches 10/10. The physical gate cannot be closed on this host (2.12). The
orchestrator therefore cut over the functional tree and froze the old one:

* root `src/`, `firmware/`, `sim/`, `test/`, `tb/`, `tools/`, `demos/`,
  `info.yaml` are v2 (12 RTL files, 75 opcodes, `VERSION 0x02`);
* v1 is preserved byte-for-byte at `legacy/v1/` and is not modified;
* the v2 development copy remains at `v2/` as the evidence tree.

The cutover is visible in the tree rather than asserted: `info.yaml`
`source_files` lists 12 files, `src/proteus_defs.vh` has
`PROTEUS_ENGINES 3` / `PROTEUS_VERSION 8'h02`, and `test/Makefile` /
`sim/Makefile` use the same 12-file list.

### 2.12 Flow infrastructure finding

Six 6x4 LibreLane attempts (v1 at a 65 % placement target, this tree at 60, 1
and 4 threads, 40 min to 3 h 27 min) all stalled in OpenROAD detailed routing
with an identical silent signature: 0-byte step log, empty `drt-run-0/`, no
DRC/unrouted/congestion
report, stable CPU and RSS. The image has a single OpenROAD build and LibreLane
offers no override, while the 1x1 smoke flow completes
(`results/flow_report.md`). Conclusion: a local aarch64 runtime block, not a
density verdict. The authoritative gate was moved to the repository's
`gds.yaml` action on x86_64. What the local flow did establish is real and is
kept: post-GRT STA at 20 ns with setup **+11.0205 ns** / hold **+0.2878 ns**.
The area number comes from synthesis, not the flow: flat 519,233.80 um2 /
36,343 cells / 57.54 % (`results/synth_v2_root.txt`).

---

## 3. Failures and how they were found

| failure | detector | evidence |
|---|---|---|
| 6-bit opcode could not encode `0x40..0x4D` | encoding review + a test that checks every opcode against the field width | `docs/isa.md` revision note, `tools/isa.py` assertions |
| 64-deep program RAM did not fit the tile budget | pre-RTL area model, then full-chip synthesis | `results/area_baseline.md`, `results/synth.txt` |
| pacer free-run after 2^24 cycles | cycle-model test with an injected cycle counter | `legacy/v1/tools/tests/test_model.py`, v2 pacer probe in `demos/run_demos.py` |
| `HALT` left `RUN` set | model-vs-contract mismatch, then formal property and sim checks | `src/tt_um_proteus.v` `halt_mask`, v2 E8 PASS |
| barrier combinational loop | lint/loop analysis plus formal reachability | `src/tt_um_proteus.v` decision 8, v2 E7 PASS |
| engine window registers unreachable at stride 0x10 | address-map arithmetic | `src/tt_um_proteus.v` decision 7, `src/proteus_defs.vh` |
| `SCK <= clk/4` unachievable with a 2-FF synchroniser | timing analysis of the host FSM | `src/proteus_host.v` decision 3 |
| `OUT_FIFO` read returned 0 | cocotb smoke through the real SPI pins | `legacy/v1/sim/results.xml`, v2 `tb_csr` FIFO checks |
| depth-64 build loaded no program (v1) | FPGA integration | v1 `PDEPTH` was 6 bits; v2 declares `localparam [6:0] PDEPTH` |
| **v2 engine 2 program page unreachable** | new v2 TT harness + protocol suite over the real SPI host | `PROTEUS_PM_END 0x02FF` -> `0x03FF`, regression `proteus_v2_map` (`v2/results/v2_verify.md` §5) |
| study NRZI packet tail lost the last byte | study closed-loop bench | `results/hybrid_area.md` §3 (R2); the shipped pair passes the four-byte `tb_nrzi` check |
| v2 benches missed 16 of 99 mutants on first run | mutation run | 83.8 % -> 96.0 % after 12 triaged assertions (`v2/results/v2_mutation.md` §5) |
| local LibreLane DRT stall | six identical silent failures | `results/flow_report.md` |
| v1 FPGA demos once reported errors | board-level self-checking bench | 36 checks, 0 errors on the settled v1 tree (`legacy/v1/fpga/`) |

---

## 4. What the process did not establish

Stated plainly because the competition scores verification methodology, and an
overclaim here would be worse than the gap:

1. **No routed GDS, DRC/LVS, antenna check or slow-corner timing.** The local
   flow stalls in detailed routing (§2.12); only the GitHub `gds.yaml` action can
   close it. The +11.02/+0.29 ns numbers are post-global-route, typical corner.
2. **No gate-level simulation.** `test/Makefile GATES=yes` exists, but there is
   no v2 netlist to run it against.
3. **Top-level formal and FPGA are v1-only.** T1-T7 pass as recorded in
   `results/formal_summary.txt` with T1/T2/T5/T6 vacuous covers, T4 a contract,
   and **T7 OPEN**. The DE2 build targets the four-engine top. Neither was
   re-run for v2.
4. **Assist data paths are outside the differential.** The model does not model
   CRC bit order, shift framing, NRZI or Manchester, so the corpus excludes
   `LDAS`/`STAS`/`ASST` by assertion. Their evidence is unit benches, `tb_csr`,
   `top_e2e`, `selfcheck.py` and the MII pad test.
5. **Ethernet is host-bandwidth-bound.** Content and pad protocol are proven at
   a slowed TX_CLK; 10 Mbit/s sustained needs a larger frame FIFO or a faster
   host port. USB LS and 10BASE-T have assists but no protocol demo; the
   Manchester block is specified for an 80/160 MHz core.
6. **JTAG is partial and v1-only.** IDCODE and 12/16 TAP states; BYPASS and
   Pause/Exit2 are not implemented (`results/stretch.md`).
7. **No pytest suite in v2.** Layer-1/2 coverage is `tools/selfcheck.py`; the
   179 v1 tests are archived at `legacy/v1/tools/tests/` and were not re-run.
8. **No silicon and no board.** No part has been fabricated (shuttle is March
   2027). The v1 DE2 build runs the real v1 RTL and its four demos pass in
   simulation (36 checks, 0 errors), but it has not been programmed onto a
   physical board.

---

## 5. Token and tool usage

No usage accounting is recorded in the repository. The only machine-readable
run state is `.omo/run-continuation/ses_*.json`, which stores a session id,
`updatedAt`, and background-task state, not token counts or per-agent costs.
Therefore this document makes **no claim** about tokens, tool calls, wall-clock
split between agents, or cost. The commands that would produce such a record
live in the harness, not in the repo.

What the repository does support is an audit of *effect*: every phase above has a
file, every decision has a comment or a test, and every failure above has a
reproducing command in `docs/verification.md` §4.

## 6. Limitations of this account

- It is written from artifacts, after the fact. Ordering between two changes that
  landed in the same minute cannot be reconstructed from mtimes.
- The tree was under concurrent edit while earlier revisions of this document
  were written. Measurements are therefore stamped with a timestamp and a report
  path in `docs/verification.md` §0; a number without a report is not a
  measurement here.
- Test counts are counts of collected tests or decoded checks, not a coverage
  metric. There is no line/branch/toggle coverage run in this repository.
- The model is the reference for cycle semantics, and the RTL is written to match
  it. That is a single point of failure: a wrong model makes both wrong in the
  same way. The independent protocol decoders in `sim/test_protocols.py`
  (a 16x UART receiver, an SPI mode checker, an I2C target with pull-ups, an MII
  PHY sampler) and `demos/run_demos.py` provide a second opinion for those
  protocols, and the mutation run measures whether the benches notice a bug.
