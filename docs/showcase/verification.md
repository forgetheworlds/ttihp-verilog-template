# Verification: one ladder, nine different questions

A single test suite answers one question: did the cases I wrote pass. PROTEUS
was verified by nine layers that each answer a different question, because the
defects that actually appeared were not all reachable from the same direction.
The first eight are the ladder in `docs/assets/ladder.svg`; the ninth is the
check that a document's number matches the log it names.

The counts below are from the shipped tree. Commands and per-layer detail live
in [docs/verification.md](../verification.md); this page is about why each layer
exists and what it caught.

---

## 1. Layers, questions and defects

| layer | question it answers | artifact | defect it caught |
|---|---|---|---|
| Golden model | does the protocol specification make sense at all | `tools/model.py`, `demos/run_demos.py` | pacer free-run past 2^24 cycles |
| Toolchain self-check | do the assembler, opcode table and model agree | `tools/selfcheck.py` | assist opcode encoding drift |
| cocotb protocols on the RTL | does the real chip speak the protocol at the pads | `sim/test_protocols.py` | output-FIFO read/pop race |
| Directed RTL benches | do the integration paths behave, phase by phase | `tb/`, 10 benches | HALT not retiring RUN; barrier loop |
| Cycle-exact differential | does the RTL match the model on every cycle, not just at the end | `sim/test_diff.py` | semantic drift the benches did not sample |
| Engine formal | are the invariants true for all inputs inside the bound | `formal/` | barrier release without an arrival |
| Mutation | would the benches notice if the RTL were wrong | `tools/mutate.py` | 16 assertions that were too weak |
| Synthesis and hardening | does it fit, does it route, does it pass DRC/LVS | `scripts/synth_full.sh`, `scripts/flow.sh` | Metal3 over capacity on 6x4 |
| Agent review | is the number in the document the number in the log | re-running the logged script | an area claim that did not reproduce |

The order is deliberate. The cheap layers run in seconds and get run constantly.
The expensive ones run once per candidate and are allowed to be slow. A defect
that survives the cheap layers is usually an integration defect, not a logic
defect, which is why the differential and the pad-level protocol tests sit
between the benches and the formal proofs.

---

## 2. The defect the new layer caught: engine 2 was unreachable

This is the cleanest example in the project of a verification layer paying for
itself.

The v2 build moved from four engines to three engines plus five assists. The
address map was edited accordingly. `PROTEUS_PM_END`, the constant that bounds
the programmable program window, was set to `0x02FF`, the end of a two-engine
map. The third engine's page is `0x0300..0x03FF`.

Nothing else noticed. The model has no address map, so every model-level test
stayed green. The benches in the tree had been ported from v1, where the map was
different. Synthesis and the formal suite do not look at the host address
decode at all.

What caught it was the new Tiny Tapeout harness plus the protocol suite, both of
which load firmware through the real SPI host:

```
engine 2 page 0x0300 -> write 11 22 33, read back [0, 0, 0]      BROKEN
0x0304 / 0x03FC      -> writes dropped, reads 0x00               BROKEN
```

The fix is one constant, `0x03FF`. The interesting part is the blast radius if
it had shipped: `firmware/spi_master.asm` uses engine 2 with all 32 words, and
the START/WRITE half of `firmware/i2c_master.asm` uses engine 2 as well. Both
would have failed on silicon while every model test passed.

The regression is `sim/test_protocols.py::proteus_v2_map`, 25 checks. It writes
and reads back all three pages, checks the last programmable word `0x037C`,
checks that `0x03FC` reads zero without aliasing engine 2 word 0, and checks
that `0x0400` (the old v1 engine-3 page) reads zero without aliasing engine 2.
That last check is the one that makes the constant's meaning explicit rather
than just wide enough.

Two lessons are recorded in the tree rather than in this page:

* a constant that bounds an address range has no natural test in a model that
  has no addresses, so it needs a test that drives the real bus;
* "the page loads" is weaker than "the page loads and the neighbouring page
  does not alias it".

A smaller finding from the same phase: the v2 test program ends in `HALT`, which
retires `RUN` while the ~280-clock SPI frame that writes `RUN` is still on the
wire. The original pad monitor started after the write and would have missed the
toggles. That was a test-construction bug, not an RTL bug; it is recorded in
`v2/results/v2_verify.md` §2.1.

---

## 3. The claim that did not survive: 55.18 %

The second defect was in the documentation, and it is included because the
project's rule is that a number without a reproducing command is not a
measurement.

An earlier v2 record stated the flat area as **497,927.19 um2, 33,936 cells,
55.18 % of row area**, sourced from `v2/results/synth_v2.txt`. That number had
been quoted in `results/flow_report.md` and in `docs/hybrid-architecture.md`.

Re-running the flat script printed in that log, on the identical 11 source
`sha256` values with the same yosys 0.33 and the same liberty file, produced
**519,233.80 um2 / 36,343 cells = 57.54 %**, deterministically, on repeated
runs. A third independent run agreed (`results/final_evidence.md` §3.2). The
difference is 21,306.61 um2 (+4.28 %), and it is not attributed; the per-module
hierarchical numbers moved in the same direction (the third engine maps to
131,313.72 um2 now against 132,695.96 um2 in the old log), which is not the
sign of a transcription slip.

The correction is carried in `results/flow_report.md` and
[docs/verification.md](../verification.md) §2.9, and the old figure is labelled
superseded rather than deleted. The sign-off numbers are:

| quantity | value | source |
|---|---:|---|
| flat area | 519,233.80 um2 | `results/synth_v2_root.txt` line 47230 |
| cells | 36,343 | same, line 47202 |
| utilisation | 57.54 % of 902,417 um2 | arithmetic |
| hierarchical sum | 538,016.13 um2 = 59.62 % | same, line 19254 |
| 60 % placement budget | 541,450.20 um2, 22,216.40 um2 spare | arithmetic |

Why the correction matters even though both values fit the budget: the
three-engine decision is only defensible if the numbers behind it reproduce.
Both 55.18 % and 57.54 % are inside 60 %, so the decision does not turn on the
difference, but a quoted area that cannot be regenerated is not evidence for
anything. The design stays at three engines; the claim changes.

The mechanism that caught it is not glamorous. It is the rule that every number
names its log and its command, applied by re-running the command instead of
trusting the summary line inside the log.

---

## 4. Smaller defects, and which layer noticed

These are listed because they show the ladder doing different work, not because
they are equally important.

* **The 6-bit opcode could not encode `0x40..0x4D`.** Found by encoding review
  and a check that every opcode fits its field. Layer: toolchain.
  `tools/isa.py` now asserts `OP_SHIFT + OP_BITS == 24` and
  `len(OPC) == len(OPS) == 75`.
* **A 64-deep program RAM did not fit.** The pre-RTL area model priced it at
  123,128.81 um2 per engine, 492,210.43 um2 for four engines, 90.9 % of the
  placement budget before any logic. Depths 32 and below were measured; 32
  stayed. Layer: synthesis and arithmetic, before the RTL existed.
* **The pacer free-ran after 2^24 cycles.** A packed 24.8 deadline truncates its
  integer part at 2^24; after that, every cycle completes. Caught by a model
  test at the boundary, fixed by a 32-bit integer part with a carried fraction.
  Layer: golden model.
* **`HALT` did not clear `RUN`.** The top drove `run_reg` from host writes only,
  so a halted engine still reported running. Caught by the model contract and
  then pinned by engine formal E8 and the simulation checks. Layer: formal and
  benches.
* **The barrier request depended on its own release.** A combinational loop:
  `bar_req` was derived from `bar_go`, which was derived from the arrivals that
  included `bar_req`. Caught by loop analysis, then by formal E7, which proves
  `OP_BAR` cannot advance while it waits and the barrier is not released.
  Layer: formal.
* **The host read zero from a one-entry output FIFO.** The top popped the FIFO
  in the same cycle the host sampled it, so the host read the post-pop head.
  Caught by cocotb driving the real SPI pins; the recorded symptom is
  `OUT_FIFO byte from PUSH r1: got 0 expected 60`. Layer: pad-level protocol
  test.
* **The benches missed 16 of 99 mutants.** The first mutation run scored 83.8 %.
  Twelve assertions were added after triage; the score is now 95/99 = 96.0 %,
  with the four survivors shown equivalent in `v2/results/v2_mutation.md` §5.
  Layer: mutation, measuring the benches rather than the RTL.

---

## 5. What the ladder does not cover

Stated plainly, because an overclaim in this section would be worse than the
gap:

* **The model is a single point of failure.** The RTL is written to match
  `tools/model.py`. A wrong model makes both wrong in the same way. The
  independent decoders in `sim/test_protocols.py` (a 16x UART receiver, a
  mode-0 SPI checker, an I2C target, an MII sampler) and the model-level demos
  are the second opinion for the protocols they cover.
* **Assist data paths are outside the differential.** The model does not model
  CRC bit order, shift framing, NRZI or Manchester, so the differential corpus
  excludes `LDAS`/`STAS`/`ASST` by assertion. Their evidence is the unit
  benches, `tb_csr`, `top_e2e`, `selfcheck.py` and the MII pad test.
* **No gate-level simulation.** `test/Makefile` keeps the `GATES=yes` branch,
  but there is no v2 netlist to run it against.
* **Top-level formal and the FPGA build are v1-only.** The engine suite is the
  v2 suite. The v1 top-level properties T1-T7 are archived with v1, and T7 is
  open there.
* **Ethernet is host-bandwidth-bound.** Content and pad protocol are proven at a
  slowed TX_CLK; 10 Mbit/s sustained needs a larger frame FIFO or a faster host
  port.
* **There is no coverage metric.** Test counts are counts of collected tests or
  decoded checks, not line, branch or toggle coverage. Mutation is the closest
  thing to a coverage argument in this repository.
* **Counts are a snapshot.** Re-run the command in the row you care about; the
  figure's numbers and this page will drift if you do not.

---

## 6. The command behind each count

The full list is in [docs/verification.md](../verification.md) §2 and §4. The
short form:

```sh
python3 tools/selfcheck.py                 # toolchain
PATH=$PWD/.venv/bin:$PATH make -C test     # official Tiny Tapeout gate
make -C sim && make -C sim diff            # protocols, then RTL vs model
bash tb/run.sh                             # 10 directed benches
python3 demos/run_demos.py                 # model-level protocol demos
./formal/run.sh                            # engine formal, E0..E11
python3 tools/mutate.py --all              # mutation score
scripts/fetch_pdk.sh --liberty-only && scripts/synth_full.sh   # area
scripts/flow.sh                            # LibreLane hardening
```
