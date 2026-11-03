# PROTEUS LibreLane routing report

Status: **no local routed GDS.** Every detailed-routing attempt on this
aarch64 host stalls with an identical signature at both v1 (64.4% row) and
v2 (55.2% logic area). The conclusion is (b): the local aarch64
OpenROAD/DRT runtime is the blocker, not the design density. The authoritative
submission gate is the GitHub `gds.yaml` action on x86_64
(`TinyTapeout/tt-gds-action@ihp-cmos5l`).

Host: aarch64 (Ampere), 4 cores, 23 GB RAM, 64 GB free, Docker 29.8.0.
Image: `ghcr.io/librelane/librelane:3.1.0.dev4` (multi-arch, arm64 native).
PDK: IHP-Open-PDK `2bbec755`, `$HOME/pdk/ihp-sg13cmos5l`.

## Attempts

| # | tree | density | threads | DRT iters | wall | outcome |
|---|---|---:|---:|---:|---:|---|
| 1 | v1 (`src/`, 4 engines, FIFO/CAP=4) | 65 | 4 | 64 (default) | 3 h 27 min | killed, zero-byte step log |
| 2 | v1, resumed from step 43 | 65 | 4 | 8 | 1 h 01 min | killed, zero-byte step log |
| 3 | v2 (`v2/src`, 3 engines + assists) | 60 | 1 (default) | 64 | 40 min | killed, zero-byte step log |
| 4 | v2, resumed from step 43 | 60 | 4 | 8 | 1 h 30 min | killed, no DRC output |
| 5 | v2, resumed from step 43 | 60 | 4 | 4 + DRC save | 80 min | killed, no DRC output |
| 6 | v2, resumed from step 43 | 60 | 1 | 4 | 45 min | killed, zero-byte step log |

Exact configs: `PL_TARGET_DENSITY_PCT` as tabled; `PL_ROUTABILITY_DRIVEN` not
used (v2 density experiment superseded it); `DRT_SAVE_DRC_REPORT_ITERS=1` on
attempt 5; `OPENROAD_THREADS` explicitly 4 on 4/5 and 1 on 6.

## Identical stall signature (all six attempts)

```
runs/wokwi/<n>-openroad-detailedrouting/openroad-detailedrouting.log  0 bytes
runs/wokwi/<n>-openroad-detailedrouting/drt-run-0/                    empty
no state_out.json, no DRC report, no unrouted-net report, no congestion
hotspot report, no error line
CPU 101% (1 thread) or 378-395% (4 threads), RSS 2.0-3.1 GB, stable
elapsed 40 min - 3 h 27 min, no iteration artifact ever written
```

Because LibreLane buffers the OpenROAD subprocess, silence alone cannot
distinguish "slow" from "livelocked"; the fact that it is identical at 64.4%
and 55.2% and from 40 min to 3.5 h is the evidence that a local tool/runtime
problem dominates.

## OpenROAD binary checks

- LibreLane has no `OPENROAD_EXE`/`OPENROAD_BIN` override; it invokes
  `openroad` from `PATH`.
- The image contains two builds,
  `/nix/store/ibflsf...-openroad-2026-02-17/bin/openroad` and
  `/nix/store/5sa24...-openroad-2026-02-17-python3-3.13.13-env/bin/openroad`.
  Both report the same git revision `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0`,
  so there is no alternative local binary to try.

## Valid local evidence

Area and timing up to global route are complete and usable.

| tree | area | utilisation | post-GRT STA (20 ns, nom_typ) |
|---|---:|---:|---|
| v1 | 581,139 um^2 hierarchical / 568,294 lean flat, 39-40k cells | 64.4% of 902,417 rows | setup **+10.641 ns**, hold **+0.265 ns** |
| v2 | 497,927 um^2 flat logic, 33,936 cells; 641,029 um^2 incl. fillers, 48,738 instances (**superseded**, see below) | 55.18% of rows (logic, superseded) | setup **+11.0205 ns**, hold **+0.2878 ns** |

**Correction (2026-11-03):** the v2 area row above is not reproducible and
is superseded. The same flat script recorded in
`v2/results/synth_v2.txt`, run on the identical 11 source sha256 values with
the same yosys 0.33 and liberty, gives **519,233.80 um^2 flat, 36,343 cells =
57.54% of row area (95.90% of the 60% budget, 22,216.40 um^2 spare)**; two
independent runs are identical (`/tmp/flat_a.log`, `/tmp/flat_b.log`). That
number is the sign-off area and is recorded in `results/synth_v2_root.txt`
(lines 47230 and 47202; hierarchical 538,016.13 um^2 = 59.62%, line 19254).
The +21,306.61 um^2 (+4.28%) difference from the earlier record is
unexplained and is not assumed away. `docs/verification.md` §2.9 carries the
same note. The post-GRT timing above was measured on the flow netlist, not on
this mapping, and is unaffected.

Neither tree has: a routed GDS, routed DRC/LVS, antenna sign-off, or a
slow-corner number. 50 MHz is comfortably met before routing parasitics; that
is the strongest timing evidence available locally.

## Snapshot notes

- v1 flow ran on the post-cut RTL; its top differed from the final `src/` by
  the 4-line CAP_STATUS `cap_cnt4` change (no area/timing effect at depth 32).
- v2 flow ran on the `v2/src` snapshot that predates the approved
  `PROTEUS_PM_END 16'h03FF` constant fix (the staged copy has the old value).
  That is a one-bit compare-range constant with no area or timing impact, so
  the DRT evidence stands; it must not be copied into the final submission.

## Next step

Push the repo and let `.github/workflows/gds.yaml`
(`TinyTapeout/tt-gds-action@ihp-cmos5l`, x86_64, LibreLane 3.1.0.dev3/4)
produce the sign-off GDS, DRC/LVS and slow-corner timing. Local runs are for
iteration and area/timing estimation only. Do not read this local DRT
non-convergence as evidence that the design is unroutable.
