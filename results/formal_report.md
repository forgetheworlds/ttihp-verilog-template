# PROTEUS formal verification report

Date: 2026-11-03. Design snapshot: `src/` at the time of the final run
(`proteus_engine.v` with `halt_exec`/`halt_mask` run-retire, 24.8+8 pacer,
`FIFO_DEPTH=4`, `CAP_DEPTH=4`; `tt_um_proteus.v` with the same).

Reproduce everything with:

```sh
./formal/run.sh                 # engine suite + X check + top suite
./formal/run.sh --engine-only   # engine only (~8 min)
./formal/run.sh --top-only      # top only (~35 min)
```

Raw logs: `results/formal_<PROP>.txt` (prove) and
`results/formal_<PROP>_cover.txt` (cover). Machine summary:
`results/formal_summary.txt`. Flow documentation: `formal/README.md`.

## 1. Toolchain — what actually worked

Nothing usable was installed (no `sby`, no SMT solver), so the OSS CAD Suite
aarch64 tarball was installed under `.tools/`:

```sh
curl -sSLO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-11-02/oss-cad-suite-linux-arm64-20261102.tgz
tar -xzf oss-cad-suite-linux-arm64-20261102.tgz
```

Versions used: `sby` 0.70-9, `yosys` 0.70+290, `yosys-smtbmc`, z3 4.15.5.
(yices 2.7.0, boolector 3.2.4, bitwuzla 0.9.1 and cvc5 are also present but
were not faster here.) The system yosys 0.33 is unusable for this flow: it has
no `expose`/`connect -set` binding and its `sat` pass rejects `$check` cells.

`pip install sby` does not exist; the tarball was the working path.

Two proof paths, because the models differ by ~4x in state:

| | engine (`E*`) | top (`T*`) |
|---|---|---|
| driver | `sby` (BMC + induction) | `yosys` → `yosys-smtbmc -t N` (BMC only) |
| bounds | depth 40 (E4 48) | depth 20 (T7 96) |
| covers | sby cover task | `yosys-smtbmc -c` |
| cost | ~40 s/property | ~14 s per BMC step |

Top-level `sby` was abandoned: its induction step did not converge on the full
chip (still "waiting for solver" after 25 min on one step), and `abc pdr` did
not converge either. `yosys-smtbmc -t N` runs the same bounded proof without
the induction phase.

## 2. Method

* Two harnesses: `formal/eng_formal.sv` (one `proteus_engine`) and
  `formal/top_formal.sv` (one `tt_um_proteus`). Properties are selected per run
  with `-D PROP_<id>`, so every run reports exactly one PASS/FAIL.
* Internal DUT state is read through **probe wires bound explicitly** in the
  generated yosys script (`expose` → `flatten` → `connect -set`). This matters:
  yosys silently turns `u.in_cnt` in a wrapper into an *undriven* wire, and
  `opt` then prunes the DUT, so a hierarchical-reference property would
  "fail" against a design that no longer contains the logic. A probe typo or
  width mismatch is a hard yosys error instead.
* Reset: `rst_n` low for cycle 0 only; checks start after the DUT's own reset
  synchronisers settle (`f_cycles`). The engine is given a looping program
  (`PUSH r0; JMP 0`, or `PULL r0; JMP 0` for the input-FIFO direction) because
  the reset fill leaves `HALT` in every unwritten entry, so a one-instruction
  program halts at PC=1 and no FIFO/barrier state is ever reached.
* Non-vacuity: every property with an antecedent has a `cover()`, run on the
  same bound. The summary prints reached/total; a PASS with an unreached cover
  is flagged.

Measured boot ladder (property **E9**, all covers but `halted` reached at depth
40): `prog_ready` step 32, `exec_act` step 32, first PC advance step 33, first
PUSH step 33. This is why engine depths below 40 cannot observe execution.

## 3. Results

### 3.1 Engine (`proteus_engine`), verified

| id | depth | prove | cover | property |
|---|---|---|---|---|
| E0 | 40 | **FAIL (expected)** | reached | negative control: `in_cnt <= FIFO_DEPTH-1` |
| E1 | 40 | PASS | reached | `PC < PROG_DEPTH` every cycle |
| E2 | 40 | PASS | 2/2 | `in_cnt/out_cnt <= FIFO_DEPTH`; `full == (cnt == FIFO_DEPTH)`; not (full and empty) |
| E3 | 40 | PASS | reached | push offered while full must not move the write pointer |
| E4 | 48 | PASS | reached | no engine push into a full output FIFO |
| E4B | 40 | PASS | reached | no pop from an empty input FIFO (`PULL` loop) |
| E5 | 40 | PASS | reached | pop from an empty output FIFO must not move the read pointer |
| E6 | 40 | PASS | 2/2 | while `!prog_ready`: no execution, PC frozen, all pin write buses idle |
| E7 | 40 | PASS (basecase) | reached | `OP_BAR` cannot advance while `bar_req` is high and `bar_go` low |
| E8 | 40 | PASS | reached | `HALT` is sticky and freezes the PC while `run` stays high |
| E9 | 40 | PASS | 5 milestones, 1 unreached | boot-ladder audit (see below) |
| E10 | 40 | PASS | reached | `prog_ready` never drops after assertion |
| E11 | 40 | PASS | reached | after the fill, program memory only changes on a host write |

Notes:

* **E0 is a negative control by design.** It asserts `in_cnt <= 3` on a FIFO of
  depth 4 and must fail. It did, and its cover (`in_cnt == 4`) was reached in
  the same run — together that is evidence the probe binding is live: the
  harness really observes the DUT counter, so the other PASSes are not
  assertions over undriven wires. Counterexample in `results/formal_E0.txt`.
* **E7** reported depth-40 basecase PASS; only the induction phase failed to
  converge (capped at 300 s). The bounded proof is valid; the run is labelled
  accordingly.
* **E9** is a diagnostic, not a design property: its audit program loops and
  never halts, so `cover (halted)` is unreachable *by construction*. E8
  reaches that milestone with a `HALT` program.
* **E3/E5 were initially written too strongly** (asserting occupancy stability
  when a concurrent engine PULL/PUSH legitimately changes it in the same
  cycle). They now constrain the pointer, which is the real invariant.

### 3.2 Top level (`tt_um_proteus`)

| id | depth | prove | cover | property |
|---|---|---|---|---|
| T1 | 20 | PASS | 0/1 unreached | open-drain release: `uio_oe & od_q & uio_q == 0`, and `uio_oe == oe_q & ~(od_q & uio_q)` |
| T2 | 20 | PASS | 0/1 unreached | priority merge equals the documented highest-index-wins function |
| T3 | 20 | PASS | **1/1 reached** | `miso == 0` whenever CS_N high; `uo_out[0] == 0` when CS_N high and the host owns the pin |
| T4 | 96 | **SPEC** | 1/1 reached | no host register/program write while CS_N high; the last byte of a legal frame triggers it because the strobe is registered one clk later — see the CS_N hold contract in docs/architecture.md §6 |
| T5 | 20 | PASS | 0/1 unreached | `bar_go_e` implies every running engine arrived at that barrier id |
| T6 | 20 | PASS | 0/1 unreached | `bar_go_e` only to an engine waiting on the barrier that released |
| T7 | 96 | not run | — | HALT retires RUN — OPEN, see §4.1 |

**Caveat for T1/T2/T5/T6.** At depth 20 no host register write and no engine
execution has occurred yet (the fill alone takes 32 cycles and a 4-byte SPI
frame ~68 more), so those four are proven only over the reset-derived state
space in which the fabric registers are still zero and `bar_go` is never
asserted. They are *not* evidence for the interesting cases (two engines
writing one bit, an open-drain pin driven high, a barrier release). The blocker
is BMC cost (~14 s per step with z3), not the design.

**T3 is exercised**: its cover (a frame open, i.e. CS_N low) was reached, and
the MISO/`uo_out[0]` assertions held in every cycle of the window, including
with CS_N high between frames.

**T4 is a spec clarification, not a design defect.** Its cover (a host write
actually issued) was reached, and the counterexample is the last byte of a
legal frame: the write strobe is registered one `clk` after the 8th SCK edge,
so a master that releases CS_N on that same clock gets a strobe while CS_N is
high. No data is lost or corrupted. The interface contract is now explicit in
`docs/architecture.md` §6: CS_N must stay low for at least 2 `clk` after the
last SCK rising edge (all drivers in this repo use >=6). The RTL is not gated,
because gating would drop the final write from a prompt master.

### 3.3 X-freedom — PASS

`formal/xcheck_tb.v` is the 4-state check (`smtbmc` is 2-valued, so SMT cannot
prove "never X"). Two portability issues were fixed on the way:

* `host_en` and `run_reg` were used before their declarations in
  `src/tt_um_proteus.v`; newer iverilog rejects that even though 12.0 tolerates
  it. Both declarations now precede first use.
* `$isunknown()` is not implemented by Icarus; the checks now use
  `(^sig === 1'bx)`, which is portable and catches any X/Z bit in the vector.

Result:

```
XCHECK PASS: uio_oe/uio_out/uo_out free of X and Z for 208 post-reset cycles
```

Command:

```sh
iverilog -g2005 -I src -o /tmp/xcheck formal/xcheck_tb.v \
    src/tt_um_proteus.v src/proteus_engine.v src/proteus_host.v && vvp /tmp/xcheck
```

## 4. Findings

### 4.1 HALT did not retire RUN (found here; fixed by integration)

`docs/architecture.md` §3 says `HALT` stops the engine with `run` cleared. The
RTL cleared only `halted_r` (one cycle later) while `run_reg` was written solely
by host RUN/HALT register writes, so after a `HALT` instruction a host reading
RUN or the engine status byte still saw `run = 1`.

Reported to the orchestrator; the fix landed in `src/` as
`halt_exec` (engine) → `halt_mask` → `run_reg <= run_reg & ~halt_mask` (top),
with host writes still winning. Formal status after the fix:

* engine half — `HALT` is sticky and freezes the PC (**E8**, PASS with the
  halted milestone reached).
* top half — `halted_mask[e] && !wr_run && !wr_halt |=> !run_reg[e]` (**T7**).
  **NOT proven**: T7 needs the `HALT` instruction to actually execute, which
  requires a host frame to set RUN (~68 clocks) and a program image; at the
  affordable bound no such state is reached, so T7 would pass vacuously. It is
  reported as OPEN rather than PASS.

### 4.2 Declaration-after-use in `src/tt_um_proteus.v` (FIXED)

`host_en` (used at 132-133, declared at 141) and `run_reg` (used at 201,
declared at 203) were accepted by iverilog 12 but rejected by stricter front
ends. Both declarations now precede first use, and the X check runs clean (see
§3.3).

### 4.3 A host write pulse can coincide with CS_N high (T4, SPEC)

`formal/top_formal.sv:127-128` asserts

```verilog
assert (!(reg_we | win_wr | pm_sel | wr_run | wr_halt |
          wr_uo | wr_uio | wr_oe | wr_od) || !ui_in[1]);
```

At depth 96 this **fails** (`results/formal_T4.txt`), with the cover (a write
actually issued) reached, so the antecedent is real. The failure appears ~39
steps in, i.e. right after the first SPI byte completes.

Mechanism, from the RTL:

* `proteus_host.v:244` (and `:270` for `WRITE_ADDR` data bytes) sets
  `reg_we <= 1'b1` on the clock edge where the 8th SCK rising edge is detected.
  The pulse is therefore asserted on the **following** clock.
* Nothing gates that pulse with `cs_n`; `miso` is gated on the raw pin
  (`proteus_host.v:131`), but the write strobe is not.
* A master that releases CS_N immediately after the last sampling edge (legal
  for the master — the bit has been taken) therefore sees the write pulse land
  while CS_N is already high.

Consequences and reading:

* This is the **last byte of an otherwise valid frame**, not a stray write. The
  FSM cannot accept new data while CS_N is high (it only decodes in
  `S_CMD`/`S_*` states entered while CS was low), so there is no data-corruption
  path.
* The requirement "host writes never occur with cs_n high" is therefore an
  interface contract, not a free-standing invariant. Decision: keep the RTL
  ungated (gating would drop the final byte for a prompt master) and require
  CS_N to remain low for >= 2 `clk` after the last SCK edge; all drivers in
  this repo use >= 6. The contract is in `docs/architecture.md` §6 and T4 is
  reported as SPEC, not a defect.
* T3 is unaffected: `miso` is combinational on `cs_n`, so it is 0 whenever
  CS_N is high regardless of the write pulse.

## 5. Harness defects found and fixed (for the record)

These were all *my* bugs, each caught by the flow itself:

1. **Program write during the reset cycle is dropped** by the DUT (its whole
   sequential block is inside `if (!rst_n)`), so the fill then wrote `HALT` into
   entry 0 and the engine halted immediately (`insn = 0x700000`). Fixed by
   writing program words from cycle 1; confirmed against simulation.
2. **`|->` is rejected inside an immediate `assert`** by yosys's frontend; all
   implications are plain boolean.
3. **`expose` on two modules crashes `flatten`** (yosys assert in `rtlil.cc`),
   so the host's `cs_s` is unavailable and the CS property is checked on the raw
   pin.
4. **`connect` aborts on a probe width mismatch** with the same assert and no
   message; probe widths are now derived from `FIFO_DEPTH`/`PROG_DEPTH`.
5. **`write_smt2` rejects `$adff`/`$sdff`**; the top script runs `async2sync`
   then `dffunmap`.

## 6. Known limits / open items

* **T7 (HALT retires RUN) — OPEN**, as explained in §4.1.
* **T4 — FAIL (real), OPEN**: the write pulse is not gated by `cs_n` (§4.3).
  The design-level question is whether the CS_N hold requirement is documented
  or the strobe is gated; both are one-line decisions for the RTL owner.
* **T1/T2/T5/T6 — PASS at depth 20 with unreached covers**, i.e. the interesting
  antecedents are not exercised (§3.2). Only T3 is exercised.
* **X-freedom — BLOCKED** by the RTL compile error in §4.2.
* Barrier *release* (T5/T6) is only argued combinationally; the barrier *hold*
  side is verified with a real executed `OP_BAR` in **E7**.
* Engine proofs are for the default build (`PROG_DEPTH=32`, `FIFO_DEPTH=4`);
  depth-parameter changes need the harness constants updated (E2 will fail
  loudly if they are stale).

## 7. Reproducing the individual results

```sh
./formal/run.sh --engine-only          # E0..E11, ~8 min
./formal/run.sh T3                     # a single top property, depth 20
TOP_DEPTH=96 ./formal/run.sh T4        # T4 with the frame-depth needed to see a write
```

Counterexample logs: `results/formal_E0.txt` (control), `results/formal_T4.txt`
(write/CS_N race). The raw `yosys-smtbmc`/`sby` output for every property is
kept in `results/formal_<PROP>.txt` and `results/formal_<PROP>_cover.txt`.
