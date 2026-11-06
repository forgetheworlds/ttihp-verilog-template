# How the AI agent was used

PROTEUS was built end to end by a coding agent: RTL, testbenches, firmware, the
cycle model, the formal harness, the mutation catalogue, the LibreLane
investigation and the prose. The human directed the work rather than writing it.
This page is the concrete account of that arrangement: how work was split, what
counted as evidence, which decisions were escalated, and what was tried,
failed and reverted.

The underlying record is [docs/ai-development.md](../ai-development.md). Where
this page and that one differ, the artifact in the tree wins.

---

## The brief

The brief fixed the things an agent should not decide:

* the target board and process: Tiny Tapeout, IHP SG13CMOS5L, a tile budget;
* the pin budget: 24 pads, 3.3 V, no 5 V tolerance;
* the clock: 50 MHz sign-off;
* the deliverable: RTL plus the evidence that it works, not a demo;
* the rule that every number must be reproducible from a command in the tree.

Everything inside those constraints was the agent's to design: the ISA, the
register map, the engine microarchitecture, the host protocol, the assist set,
the test strategy, the flow scripts. That split is what made the work
auditable. The agent could not quietly widen the scope to make a number look
better, and the human did not have to review 12 RTL files line by line to know
whether the result was real.

---

## Splitting the work

One orchestrating agent held the cross-cutting decisions. Specialist agents
owned disjoint file sets and were not allowed to edit each other's:

| slice | owned |
|---|---|
| engine RTL | `src/proteus_engine.v`, the ISA decode and the pacer |
| host RTL | `src/proteus_host.v`, the SPI command FSM |
| tools | `tools/isa.py`, `tools/asm.py`, `tools/model.py` |
| verification | `tb/`, `sim/`, `formal/` |
| physical flow | `scripts/`, `src/config.json`, the LibreLane investigation |
| firmware | `firmware/*.asm` |
| documentation | `docs/`, the README, `info.yaml` prose |

Disjoint ownership was the single most useful rule. The classic multi-agent
failure is two agents editing one file and one of them silently winning. The
file sets did not overlap, so that could not happen by construction, and a
change that needed to cross a boundary became a message plus a ruling, not a
concurrent edit.

Cross-cutting decisions were written into the file they affected as a numbered
`DECISION` comment, so the reasoning travels with the code instead of living in
a chat log. Examples that are still in the tree:

* `src/tt_um_proteus.v` — decision 1 (program depth 32), decision 7 (engine
  window stride `0x20`), decision 8 (`bar_req` must not depend on `bar_go`);
* `src/proteus_engine.v` — decision 1 (`WAITC` occupies `max(n,1)` cycles) and
  decision 2 (the 32-bit pacer integer part with a carried fraction);
* `src/proteus_host.v` — decision 3 (`SCK <= clk/8`, not `clk/4`).

A reviewer can check the ruling against the code and against the test that
pins it. That is the audit trail, and it is why the process does not depend on
reconstructing a conversation.

---

## Evidence discipline

Four rules did most of the work.

**A number without a report path is not a measurement.** Every count in the
README can be traced to a log or a command. `results/synth_v2_root.txt` line
47230 is the flat area. `results/flow_report.md` is the route and timing record.
If a number has no artifact, it is not quoted.

**Run the layer that can actually see the bug.** The engine-2 page defect
section in [verification.md](verification.md) is the example: the model has no
address map, so no amount of model testing could have found it. The fix was not
a better model; it was a test that drives the real SPI host.

**Keep the failures.** `v2/results/SUPERSEDED.md`, the six failed routing
attempts in `results/flow_report.md`, the quoted failing check from
`legacy/v1/sim/results.xml`, and the four surviving mutants with their
equivalence arguments are all still in the tree. A repository that only
contains passes cannot tell you what was tried.

**Correct in place, and keep the old value.** When the area claim turned out not
to reproduce, the old figure stayed in the record with a "superseded" label and
the reason. Deleting it would have hidden the fact that a claim had been wrong.
The same rule applied to the physical-flow conclusion: the runtime hypothesis
is still visible in the earlier report, and the later congestion measurement is
what supersedes it.

---

## What the human decided

These are the decisions that were escalated rather than derived, and each one
is visible in the tree:

* **The cutover bar.** v2 would replace v1 only after passing the same
  protocol, differential, formal and mutation gates. That rule is stated in
  [docs/ai-development.md](../ai-development.md) §2.11 and was applied: the
  functional gates closed before the root tree changed, and the physical gate
  could not be closed on the local host.
* **The one-constant fix.** When the engine-2 page defect was found, the
  approved fix was `PROTEUS_PM_END 0x02FF -> 0x03FF`, not a decode redesign.
  The minimal change is recorded as approved, and the regression test carries
  the rest of the argument.
* **The tile change.** Moving from 6x4 to 8x4 is an area-and-cost decision, not
  a verification result. It is visible as `tiles: "8x4"` in `info.yaml`, and its
  consequences are in [flow.md](flow.md).
* **Keeping the account honest.** The repository ships its gaps: no silicon, no
  timing sign-off, no gate-level simulation, assist data paths outside the
  differential. That is a choice about what the project is willing to claim.

The pattern is that the agent proposed, measured and documented; the human set
the bar and approved the changes that traded area, effort or schedule.

---

## What failed, and what was reverted

| attempt | outcome | what happened to it |
|---|---|---|
| Four engines, 64-deep program RAM | 64-deep cost 123,128.81 um2 per engine before any logic; four engines 90.9 % of the placement budget | depth cut to 32 before RTL; the four-engine v1 built at that depth was later archived at `legacy/v1/` when 3 engines + assists replaced it |
| A packed 24.8-bit pacer deadline | free-runs at one completion per cycle after 2^24 cycles | replaced by a 32-bit integer part with a carried fraction; pinned by a model test |
| `SCK <= clk/4` for the host SPI | the two-flop synchroniser plus a registered MISO needs three clocks, so `clk/4` is short by one | changed to `clk/8`; recorded in `proteus_host.v` decision 3 |
| "DRT stalls are an aarch64 runtime block" | six silent attempts at two placement densities looked like a tool problem | withdrawn once global-route congestion was measured: Metal3 demand is 114.45 % of the derated supply. The conclusion in `results/flow_report.md` is superseded by [flow.md](flow.md) |
| `GRT_ADJUSTMENT 0.2` as a 6x4 fix | the global figure fell to 94.43 %, but 10,404 local overflow edges remained | reverted to the default; it was a measurement experiment, not a shipped knob |
| Resizer margins zeroed for 6x4 | the margins were cut while working on 6x4 and then inherited by the 8x4 run, where setup and hold failed | restored on the branch; the 8x4 rerun is pending |
| A test that counted clocks after the SPI `RUN` write | the v2 program ends in `HALT` and finishes before the ~280-clock frame completes | test construction fixed; the pad monitor now starts before the write |
| The first mutation run | 83.8 %, 16 of 99 mutants survived | 12 assertions added after triage; 96.0 %, four survivors argued equivalent |
| The recorded area of 497,927.19 um2 / 55.18 % | did not reproduce on the same sources and library | superseded by 519,233.80 um2 / 57.54 %; both values kept in the record |

The pattern in the failures is consistent: the agent was good at producing a
plausible explanation and bad at knowing when that explanation had stopped
being true. The corrections came from measurements, not from re-reading the
explanation.

---

## What the agent did not do

* It did not fabricate a measurement the host could not produce. There is no
  routed-timing number invented for the 6x4 failure, and no "GDS clean" claim
  before the 8x4 run existed.
* It did not sign off timing. The 8x4 run's setup and hold failures are
  reported with their corners and their cause, not with an explanation that
  makes them go away.
* It did not produce silicon. There is no board and no fabricated part; the
  shuttle is later.
* It did not decide the trade-offs that cost area or schedule. Those were
  escalated.

## What I would keep, and what I would change

Keep: disjoint file ownership, the artifact rule, the model as executable
specification, and writing rulings into the file they affect. Those four made a
large agent-built tree reviewable by someone who was not present for the work.

Change: a workaround knob should carry a file note naming the target it was
changed for. The resizer margins were zeroed for 6x4 and silently inherited by
the 8x4 run; the resulting timing failure cost a run and looked, for a while,
like a design problem. A one-line comment at the point of change would have
prevented it.

The other change is about quoting. An agent will happily repeat a number from
its own earlier summary. The area correction happened because someone ran the
logged script again instead of trusting the sentence that described it. Treat
every summary as a claim, and every log as the evidence.
