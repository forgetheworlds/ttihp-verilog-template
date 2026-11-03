# PROTEUS formal flow

Reproduce with:

```sh
./formal/run.sh                  # engine suite + X check + top suite
./formal/run.sh --engine-only    # engine harness only (fast, ~8 min)
./formal/run.sh --top-only       # top harness only (~35 min, see costs below)
./formal/run.sh E2 T5            # individual properties
FORMAL_APPEND=1 ./formal/run.sh --top-only   # append to the existing summary
```

Outputs: `results/formal_<PROP>.txt` (prove), `results/formal_<PROP>_cover.txt`
(cover / non-vacuity), `results/formal_summary.txt`. The written report is
`results/formal_report.md`.

## Toolchain (aarch64, this host)

Nothing suitable was installed (no sby, no z3/yices/boolector), so the OSS CAD
Suite aarch64 tarball was installed under `.tools/` (~690 MB download, 2.3 GB
unpacked):

```sh
mkdir -p .tools && cd .tools
curl -sSLO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-11-02/oss-cad-suite-linux-arm64-20261102.tgz
tar -xzf oss-cad-suite-linux-arm64-20261102.tgz     # note: .tgz, not .xz
```

Provides: `sby` 0.70-9, `yosys` 0.70+290, `yosys-smtbmc`, `yosys-witness`, and
the solvers `z3` 4.15.5, `yices-smt2` 2.7.0, `boolector` 3.2.4, `bitwuzla`
0.9.1, `cvc5`. `run.sh` uses `smtbmc z3`.

The system `yosys` 0.33 is not sufficient: this flow needs 0.70's `$check`
cells, `expose` and `connect -set`.

## Two proof paths

| | engine (`E*`) | top (`T*`) |
|---|---|---|
| driver | `sby` | `yosys` + `yosys-smtbmc -t N` |
| prove | BMC + induction, depth 40 | BMC only, depth 20 |
| covers | `sby` cover task | `yosys-smtbmc -c` |
| why | small model, induction cheap | induction does not converge |

The top model (four engines + capture arrays) costs ~14 s per BMC step with
z3 and ~18 s with yices, and neither `smtbmc` induction nor `abc pdr`
converged in minutes. `yosys-smtbmc -t N` runs the same bounded proof without
the induction step.

## Why the model is built the way it is

1. **Hierarchical references are silently ignored.** `assert (u.in_cnt <= 8)`
   in a wrapper does *not* read the submodule's `in_cnt`; the frontend
   implicitly declares an undriven wire `u.in_cnt`, and `opt` then prunes the
   DUT, so a "counterexample" is reported for a design that no longer contains
   the logic. DUT internals are read through PROBE wires bound explicitly:

   ```
   select -module proteus_engine
   select w:in_cnt
   expose                       # adds in_cnt as an output port
   select -clear
   flatten                      # probe port becomes u.in_cnt
   select -module eng_formal
   connect -set in_cnt u.in_cnt # harness probe <- DUT signal
   ```

   A typo in a probe name is a hard yosys error, never a vacuous PASS.

2. **`prep` does not flatten**, and it runs `opt`, which deletes logic whose
   outputs are unused. The scripts run `proc` explicitly, expose before
   flattening, and `opt_clean` last.

3. **`expose` on two modules crashes `flatten`** (`Assert GetSize(conn.first)
   == GetSize(conn.second)` in `rtlil.cc`). Only one module is exposed per run,
   which is why `proteus_host.cs_s` is not available and the CS property is
   checked on the raw pin.

4. **`connect` aborts on a width mismatch** (same assert, no message). Probe
   widths must match the DUT exactly, which couples the harness to
   `PROG_DEPTH` / `FIFO_DEPTH`. `E2` asserts `in_full_w == (in_cnt ==
   FIFO_DEPTH)`, so a stale depth constant fails loudly instead of silently
   weakening the bound.

5. **`write_smt2` rejects `$adff` and `$sdff`**, which the engine instances
   contain. The top script runs `async2sync` then `dffunmap` before
   `write_smt2`.

6. **SVA `|->` is rejected inside an immediate `assert`.** All implications are
   plain boolean (`!a || b`).

The DUT is instantiated **without parameter overrides** so the module keeps its
plain name; an override renames it `$paramod$…` and breaks `select -module`.

## Reset and proof window

* Harness `rst_n` is low for cycle 0 only and high afterwards; properties are
  checked from a later cycle (`f_cycles`) so `$past` never reads pre-reset
  state. The top needs 6 cycles because `rst_sync`/`eng_rst_rel` delay the chip
  and engine resets.
* Uninitialised DUT registers are left unconstrained by the tool; the reset
  assumption is what puts them in the architectural reset state. This is the
  2-valued equivalent of "after reset".
* **A host program write during the reset cycle is dropped** by the DUT (its
  whole sequential block is inside `if (!rst_n)`), and the reset fill then
  leaves `HALT` in that entry. Program writes must start one cycle after reset
  deasserts; the symptom is an engine that halts on its first instruction
  (`insn` read back as `0x700000`).

## Non-vacuity

Every property with an antecedent has a matching `cover()`, and the cover task
runs on the same bound. A `PASS` whose covers were not all reached is labelled
in the summary and in the report; it must not be read as a proof of the active
case.

Reachability: `prog_ready` rises only after `PROG_DEPTH` (=32) fill cycles, so
nothing executes before cycle ~32. Measured boot ladder (property `E9`):

| milestone | first reached |
|---|---|
| `prog_ready` | step 32 |
| `exec_act` | step 32 |
| `dbg_pc >= 1` (first retire) | step 33 |
| `out_cnt >= 1` (first PUSH) | step 33 |

Because the fill writes `HALT` into every entry the host did not write, a
single-instruction program runs once and then halts at PC=1. The engine
harnesses load small *loops* (`PUSH r0; JMP 0`, or `PULL r0; JMP 0` for the
input-FIFO direction) so the FIFO antecedents are actually reachable.

The top harness needs depth ~70 for any property whose antecedent is a real
host write: the host samples one SPI bit per two clocks, so a 4-byte
`WRITE_ADDR` frame that sets RUN costs ~68 clocks on top of the 32-cycle fill.
At ~14 s per BMC step that depth was not affordable here; see the report for
which top properties consequently ran with unexercised antecedents.

## X-freedom

`smtbmc` is 2-valued, so "never X" cannot be proven in SMT. `formal/xcheck_tb.v`
checks it with genuine 4-state semantics in iverilog: reset, then 208 cycles of
known stimulus, asserting `!$isunknown()` on `uio_oe`, `uio_out`, `uo_out`.

**This check currently does not compile**: `src/tt_um_proteus.v` uses
`host_en` (lines 132-133) and `run_reg` (line 201) before their declarations
(line 141 and line ~195) under `` `default_nettype none ``, which iverilog 12
rejects ("Check for declaration after use"). yosys accepts it, so the SMT
proofs are unaffected. Reported to the RTL owner; see results/formal_report.md.
