# PROTEUS formal flow (engine suite)

Reproduce with:

```sh
./formal/run.sh                 # engine suite (E0..E11), ~10 min on this host
./formal/run.sh --engine-only   # same selection, explicit
./formal/run.sh E2 E8           # individual properties
```

Outputs (all under `results/formal_root/`, so the v1 logs in `results/` are
untouched): `formal_<PROP>.txt` (prove), `formal_<PROP>_cover.txt`
(cover/non-vacuity), `formal_summary_root.txt`.  Generated `.sby` scripts and
solver work dirs go to `formal/work/` (gitignored).

Toolchain: OSS CAD Suite at `.tools/oss-cad-suite` (`sby` 0.70-9, `yosys`
0.70+290, `yosys-smtbmc`, `z3`).  The system `yosys` 0.33 is **not**
sufficient (no `$check` cells, `expose` or `connect -set`).  Install steps:
see `legacy/v1/formal/README.md`.

## Scope: engine only; the top T-suite is v1-only

`eng_formal.sv` proves properties of `src/proteus_engine.v` alone.  The
**top-level T-suite is v1-only and lives at `legacy/v1/formal/`**
(`top_formal.sv`, `run.sh --top-only`, `xcheck_tb.v`).  It is not ported
here, for three measured reasons:

1. **Model size.**  The v1 top (4 engines + capture arrays) already cost ~14 s
   per BMC step with z3 (~18 s with yices), and neither `smtbmc` induction nor
   `abc pdr` converged in minutes, so the T-suite ran BMC-only at depth 20 for
   ~35 min.  The hybrid top adds five assist blocks plus a second pin-merge
   stage, so the same bound is strictly more expensive.
2. **Depth needed for any host-write property.**  The host samples one SPI bit
   per two clocks; a 4-byte `WRITE_ADDR` frame that sets RUN costs ~68 clocks
   on top of the 32-cycle program fill, i.e. depth ~70 before an antecedent is
   even reachable.  At ~14 s/step that depth is unaffordable here, and a PASS
   below it would be vacuous.
3. **Those properties are covered by simulation instead.**  Host strobes, pin
   merge, the barrier graph and HALT-instr RUN retire are gated by
   `sim/test_protocols.py` (which drives the real pads through the SPI host),
   `sim/test_diff.py` against `tools/model.py`, and `tb/tb_csr.v` /
   `tb/top_e2e_tb.v`.  See `results/final_evidence.md` and
   `v2/results/v2_diff_formal.md`.

The engine harness itself is the v1 harness ported to the hybrid port list:
same properties, same probes, same depths (E4 needs 48, everything else 40),
so a v1/v2 difference is a real difference and not a re-tune.  The assist CSR
port is a tied-off input here (`as_rdata = 8'h00`, `as_empty = 1'b1`) and no
formal program issues LDAS/STAS/ASST, so no property depends on an
unconstrained assist input.  See the harness header for the probe binding.

## Results

`results/formal_root/formal_summary_root.txt` is the table of record; the
per-property status quoted in `results/final_evidence.md` comes from it.
`E0` is a negative control (expected FAIL, proves the probe binding is live);
`E9` is a reachability audit whose 5th milestone is unreachable by
construction in this harness (see `v2/results/v2_diff_formal.md` §2.3), so its
cover count is reported as `PARTIAL(4/5)` and it is not part of the PASS set.
