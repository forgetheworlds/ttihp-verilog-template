# The physical flow: six silent attempts and a capacity answer

The functional design was finished before the physical one. Hardening it
produced six failures with no error message, and eventually a correct
explanation that was not the first one.

This page is the investigation, in the order it happened. The artifact behind
each statement is named; the older runtime hypothesis is still in
`results/flow_report.md` and is superseded here rather than deleted.

---

## 1. What was being run

LibreLane 3.1.0.dev4 in the pinned container, IHP-Open-PDK at `2bbec755`,
`--pdk ihp-sg13cmos5l`. The relevant configuration for 6x4:

| key | value |
|---|---|
| `CLOCK_PERIOD` | 20 ns (50 MHz) |
| `PL_TARGET_DENSITY_PCT` | 60 |
| `RT_MAX_LAYER` | Metal4 |
| `FP_PDN_MULTILAYER` | 0 (Metal4-only vertical PDN) |
| die | 1289.28 x 710.64 um |
| standard-cell rows | 902,417 um2 |

`tiles: "6x4"` is 24 tiles. The design's measured flat cell area is
519,233.80 um2 = 57.54 % of the rows, so the placement target was plausible
going in: 95.90 % of the 60 % budget with 22,216.40 um2 spare
(`results/synth_v2_root.txt`).

The flow reached global routing every time. It never finished detailed routing.

---

## 2. Six attempts, one signature

| # | tree | placement target | threads | wall time | outcome |
|---|---|---:|---:|---:|---|
| 1 | v1, four engines | 65 | 4 | 3 h 27 min | killed, zero-byte step log |
| 2 | v1, resumed from step 43 | 65 | 4 | 1 h 01 min | killed, zero-byte step log |
| 3 | v2, three engines + assists | 60 | 1 | 40 min | killed, zero-byte step log |
| 4 | v2, resumed from step 43 | 60 | 4 | 1 h 30 min | killed, no DRC output |
| 5 | v2, resumed from step 43 | 60 | 4 | 80 min | killed, 4 iterations, no DRC output |
| 6 | v2, resumed from step 43 | 60 | 1 | 45 min | killed, zero-byte step log |

Every attempt produced the same signature:

```
runs/wokwi/<n>-openroad-detailedrouting/openroad-detailedrouting.log   0 bytes
runs/wokwi/<n>-openroad-detailedrouting/drt-run-0/                     empty
no state_out.json, no DRC report, no unrouted-net report,
no congestion-hotspot report, no error line
CPU 101 % (1 thread) or 378–395 % (4 threads), RSS 2.0–3.1 GB, stable
```

The 1x1 smoke flow completes on the same host, and the image contains a single
OpenROAD build (`dcf36133...`), so the first explanation was a local aarch64
runtime problem. That explanation was wrong, and the next section is why.

Two things about the signature are worth keeping in mind. First, it is genuinely
silent: LibreLane buffers the OpenROAD subprocess, so "slow" and "livelocked"
look identical from outside. Second, the attempts therefore cannot be used to
prove a cause by themselves. The cause comes from the global-route report, not
from the stall.

---

## 3. The measurement that replaced the explanation

Global routing has to report what it could not fit. On 6x4 it reported Metal3
over capacity:

| configuration | Metal3 demand, % of derated supply | local overflow |
|---|---:|---:|
| default global-route adjustment | **114.45 %** | not recorded here |
| `GRT_ADJUSTMENT 0.2` | **94.43 %** | **10,404 local overflow edges** |

Metal3 is the only horizontal routing layer in the stack this flow configures.
Every horizontal wire on the die competes for it. The design asks for more
horizontal capacity than the die can supply.

The important detail is the difference between the two rows. Lowering the
global-route adjustment factor brings the *global* average below 100 %, which
looks like a fix and is not: 10,404 local overflow edges remain. Detailed
routing resolves local congestion, not global averages. That is why the derate
experiment did not make 6x4 routable and why it was reverted to the default.

With this measurement, the six attempts have an explanation that fits all of
them: detailed routing was being asked to resolve overflow that the layer stack
could not support at that die width. More wall time would not have helped. The
"aarch64 runtime block" conclusion in `results/flow_report.md` is withdrawn.

What remains true from those runs is the pre-route timing: setup **+11.0205 ns**
and hold **+0.2878 ns** at 20 ns on `nom_typ`, measured after global route and
before routed parasitics. That is a real number and it is the strongest timing
evidence from the 6x4 attempt.

---

## 4. 8x4

The fix was capacity, not tuning: `tiles: "8x4"`, 32 tiles instead of 24. The
die is wider, so Metal3 has more horizontal track length. The cost is a larger
die and, in this project, one more thing to get wrong.

The flow's own synthesis, with `SYNTH_STRATEGY` `AREA 0`, reports
**485,436.67 um2 / 33,692 instances / 53.8 % at floorplan**. This is a different
number from the Yosys sign-off figure of 519,233.80 um2 / 36,343 cells because
it is a different script with different synthesis settings; both are recorded,
and the Yosys flat number remains the area claim.

The 8x4 run then did what the 6x4 runs never did:

* global route and detailed route completed;
* **DRC PASS**;
* **LVS PASS**;
* **antenna PASS**;
* the flow saved its views: GDS, netlist, reports.

That is a routed GDS with a clean physical verification result. It is the first
one in the project.

---

## 5. The timing failure, and why it is a workaround bug

The same run failed both timing checkers:

* setup at `nom_slow_1p08V_125C`;
* hold at `nom_fast_1p32V_m40C`.

The cause is not the design and it is not 8x4. The resizer margins had been
zeroed during the 6x4 experiments, and those settings were inherited by the 8x4
run. A resizer with its margins zeroed has no budget to repair a violation, so
both checkers fail at the corners where margin matters.

The margins are restored on the branch. The rerun is pending, and it cannot go
through the fork's GitHub Actions because Actions is currently disabled there.
So the current physical status is:

| item | status |
|---|---|
| routed GDS on 8x4 | yes |
| DRC | PASS |
| LVS | PASS |
| antenna | PASS |
| setup at slow corner | FAIL — margins were zeroed, restored, rerun pending |
| hold at fast corner | FAIL — same cause |
| gate-level simulation | not run |
| silicon | none |

I am not claiming timing sign-off here. The honest statement is that the routing
and physical verification are done, and the timing check is waiting on a rerun
with the margins that should always have been in place.

---

## 6. What this changed in the design process

Two rules came out of this investigation and are now part of how the tree is
maintained:

1. **A capacity number is a design input, not a post-mortem.** The 6x4 answer
   was available from global routing before any detailed-routing attempt. The
   cheap measurement should have been read first; six multi-hour runs would not
   have been started.
2. **A knob changed for one target must be named at the point of change.** The
   zeroed resizer margins were a 6x4 workaround that silently became an 8x4
   default. It cost a run and it briefly looked like a design problem. A
   comment beside the change, listing the target it was for, would have caught
   it.

Neither rule is about EDA tooling. Both are about not letting a previous
experiment's setting become invisible.

---

## 7. Reproduce

```sh
scripts/fetch_pdk.sh                       # full PDK, ~1.3 GB, pinned revision
scripts/flow.sh                            # staged LibreLane run, tag wokwi
scripts/flow.sh --tag try8x4               # a named run directory
```

The tile count comes from `info.yaml` (`tiles: "8x4"`) and the flow settings
from `src/config.json`. `scripts/flow.sh` generates `src/config_merged.json` the
same way `tt_tool.py --create-user-config` does, stages a copy outside the
working tree, and runs the pinned container. Results land in
`runs/<tag>/final/`.

The congestion report is in the global-route step of the run directory; the
DRC, LVS and antenna verdicts and the timing metrics are in
`final/reports/` and `final/metrics.json`.
