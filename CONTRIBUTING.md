# Contributing

PROTEUS is a Tiny Tapeout ASIC submission. The bar for a change is that the
evidence in the tree still supports every claim the documents make, so the
rules below are mostly about evidence rather than style.

## Before you open a change

Run the gates that cover what you touched. The cheap layers take seconds; the
full ladder is a few tens of minutes on a 4-core host.

```sh
python3 -m venv .venv && .venv/bin/pip install pytest cocotb pyyaml

python3 tools/selfcheck.py                  # toolchain, opcodes, CRC vectors
PATH=$PWD/.venv/bin:$PATH make -C test      # official Tiny Tapeout gate
make -C sim                                 # protocols on the real RTL
make -C sim diff                            # RTL vs model, every cycle
bash tb/run.sh                              # 10 directed benches
python3 demos/run_demos.py                  # model-level protocol demos
./formal/run.sh                             # engine formal, needs sby + z3
python3 tools/mutate.py --all               # mutation score
```

Physical checks need more setup:

```sh
scripts/fetch_pdk.sh --liberty-only && scripts/synth_full.sh   # area
scripts/fetch_pdk.sh && scripts/flow.sh                        # LibreLane, Docker
```

If you change RTL, expect to run the first six and the formal suite. If you
change an opcode or a register, also run `tools/selfcheck.py` and the mutation
run. If you change the flow configuration, say which target it is for.

## Style

* **Verilog-2001** in `src/`. The formal harness is the only SystemVerilog
  (`.sv`) in the tree. No latches, no inferred memories outside the explicit
  program RAM, one clock, reset active low.
* **Constants live in `src/proteus_defs.vh`.** Address windows, engine
  geometry, opcode numbers and assist ids are declared once. If a constant
  bounds an address range, the test for it belongs at the host interface, not
  in the model.
* **`tools/isa.py` is the source of truth for the encoding.** `docs/isa.md`
  mirrors it. A change to one without the other is a defect.
* **Non-obvious behaviour gets a numbered decision comment and a test.**
  Examples: `src/tt_um_proteus.v` decision 7 and 8, `src/proteus_engine.v`
  decisions 2 and 3, `src/proteus_host.v` decision 3. The comment says what was
  decided and why; the test pins it.
* **Python is 3.12, standard library plus PyYAML.** Tools share no global
  state and must be runnable from the repository root.
* **Firmware is one protocol per file.** Comments carry the timing budget in
  cycles, not just the mnemonic.

Keep the change surgical. A workaround for one target is fine; a workaround
that becomes another target's default is how the 8x4 timing failure happened.
Name it at the point of change.

## Evidence rules

1. **Every number names its command and its artifact.** If a number has no
   log, it does not go in a document. `results/synth_v2_root.txt` line 47230 is
   the area; `results/flow_report.md` is the route record.
2. **Correct in place, keep the old value.** When a measurement supersedes a
   claim, mark the old one superseded and say why. Do not delete it. The area
   correction (`497,927.19 um2` -> `519,233.80 um2`) and the routing
   explanation are the models.
3. **Keep the failing logs.** `legacy/v1/sim/results.xml` still contains the
   output-FIFO failure that led to a fix; the six failed routing attempts are
   still in `results/flow_report.md`. A repository of passes cannot show what
   was tried.
4. **Frozen trees stay frozen.** `legacy/v1/` is the previous submission and is
   not edited. `v2/results/` is the evidence snapshot for the v2 port; add a
   new report rather than rewriting one.
5. **Counts are a snapshot.** Test counts are counts of collected tests or
   decoded checks, not coverage. Re-run the command in the row you are quoting.

## What is in scope

Bug fixes, verification improvements, firmware for protocols the hardware can
already run, documentation corrections, and flow experiments with their raw
logs are all welcome. A new instruction, a new assist or a different tile size
is a design change: it needs an area number, a verification plan and a reason
the existing design cannot do the job.

## Licence

Apache-2.0. By contributing you agree that your changes are licensed under the
same terms.
