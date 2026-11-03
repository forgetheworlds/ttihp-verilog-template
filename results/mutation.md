# Mutation testing: do the fast benches actually catch bugs?

Every other layer in `docs/verification.md` answers "does the design behave as
specified". None of them answers the prior question about a *test*: would this
bench notice if the design were wrong? This is that measurement. The RTL is
broken on purpose, one plausible bug at a time, and each self-checking bench
must say so.

Exact command:

```sh
python3 tools/mutate.py --all
```

Raw log with every compile line, verdict and failure message:
`results/mutation_raw.txt`. It holds exactly two complete runs of the same 57
mutations, and both print the same canonical header line
`# command: python3 tools/mutate.py --all` -- the tool writes that header
itself rather than echoing argv, so disambiguate them by `# when:`:

* line 1, `2026-11-03T04:08:08` -- the tree **as found** (original `tb/`).
  Preserved verbatim.
* line 595, `2026-11-03T04:47:00` -- after the hardening in section 4. This
  run was regenerated into `results/mutation_raw.txt` and the as-found block
  was then prepended, which is why one file carries both passes with identical
  `src` SHA-256 lines.

| item | value |
|---|---|
| mutations | **57** (11 categories, `src/` lines only) |
| benches | `tb/engine_smoke_tb.v` + `tb/top_e2e_tb.v` |
| as-found kill rate | **37/57 = 64.9 %** (20 survivors) |
| after hardening | **54/57 = 94.7 %** (3 survivors) |
| kills per bench, as found | engine 25/57, top 18/57 |
| kills per bench, hardened | engine 37/57, top 23/57 |
| runtime | 492 s as-found (includes a 180 s hang on C04), 320 s hardened (57 mutants x 2 benches, 180 s/run cap) |
| survivor classes | 2 equivalent mutants; 1 not observable from this bench's pad model (killed elsewhere -- measured, section 3.2) |
| other suites after the `tb/` edits | `pytest tools/tests -q` **179 passed**; `tb/top_stub_tb.v` PASS (untouched) |

The 17-point improvement is not the interesting number. The interesting number
is the 20 survivors of the first pass: each is a bug the two fastest benches
would have shipped.

---

## 1. Method

`tools/mutate.py` copies `src/` into a scratch directory and applies **one**
textual mutation to **one** line:

* a mutation is addressed by `file:line` **and** the literal substring on that
  line. The substring must occur exactly once on that line, the target must not
  be inside a comment, and the result must differ from the original, or the run
  aborts. A mislocated mutation would silently test the unmutated RTL and
  report a fake survivor; this guard caught two wrong line numbers in the
  catalogue during development (`F04`, `G06`).
* the bench is rebuilt from the **repo's** `tb/` file plus the mutated `src/`
  copy, so a mutation can never touch an assertion, and `src/` in the working
  tree is never written (`src` SHA-256 prefixes are recorded in the log and are
  identical in both runs).
* verdict per bench: **KILLED** if the process exits non-zero, prints `FAIL`, or
  exceeds the 180 s bound; **SURVIVED** if the bench reaches its own PASS line;
  **COMPILE** if the mutant does not build (excluded from the kill rate, because
  it is not a behavioural mutant). None of the 57 hit COMPILE.
* a mutant counts as killed if **either** bench kills it. Before any mutant is
  run, the unmutated tree must pass both benches, otherwise the run aborts --
  a "kill" against a broken baseline means nothing.

Operators used: arithmetic/relational operator swaps, constant changes,
assignment deletions, one-bit index shifts, enable inversions, address masks,
and bus substitutions. Categories:

| category | n | what it targets |
|---|---:|---|
| `alu` | 12 | ADD/SUB/ADC/SBC, borrow, shifts, rotates, NEG, shift count |
| `pacer` | 3 | deadline compare, fractional carry, `PACERST` arming |
| `waitc` | 2 | `WAITC` cycle count (both directions) |
| `timeout` | 2 | `WAITP` timeout fire point and unit |
| `waitp` | 1 | `WAITP` level polarity |
| `control` | 10 | branches, jump mask, PC step/wrap, HALT/RUN retire, restart, fill |
| `fifo` | 4 | full comparisons, non-blocking push |
| `pins` | 7 | `SETP`/`TOGP`/`DIRS`/`DIRC`/`ODSET`/side-set/`OUTBIT` |
| `host` | 6 | SPI shift order, write/read pointers, address high byte |
| `capture` | 2 | timestamp width, write-pointer advance |
| `top` | 8 | open-drain release, collision, barrier release, merge mask, lanes |

---

## 2. Results: the tree as found

`python3 tools/mutate.py --all`, first run, 37/57 = 64.9 %.

`E` = killed by the engine smoke bench, `T` = killed by the top bench,
`-` = survived both.

| id | site | mutation | as-found |
|---|---|---|---|
| A01 | `proteus_engine.v:408` | ADD/ADDI adds -> subtracts | E T |
| A02 | `proteus_engine.v:418` | SUB/SUBI/CMP subtracts -> adds | E |
| A03 | `proteus_engine.v:419` | subtract borrow flag inverted | E |
| A04 | `proteus_engine.v:413` | ADC/ADCI drops the carry-in | **-** |
| A05 | `proteus_engine.v:432` | SHL carry uses the SHR carry formula | **-** |
| A06 | `proteus_engine.v:446` | ASR loses the sign fill | **-** |
| A07 | `proteus_engine.v:456` | ROL carry from the wrong end | **-** |
| A08 | `proteus_engine.v:465` | ROR carry from the wrong end | **-** |
| A09 | `proteus_engine.v:651` | INC decrements | E |
| A10 | `proteus_engine.v:665` | DEC increments | E |
| A11 | `proteus_engine.v:637` | NEG becomes a no-op | **-** |
| A12 | `proteus_engine.v:405` | shift/rotate count one bit high | **-** |
| P01 | `proteus_engine.v:834` | `PACE` deadline compare off by one | T |
| P02 | `proteus_engine.v:838` | pacer fractional carry dropped | E |
| P03 | `proteus_engine.v:845` | `PACERST` arms one cycle late | T |
| P04 | `proteus_engine.v:818` | `WAITC n` takes n+1 cycles | E |
| P05 | `proteus_engine.v:821` | `WAITC` counter decrements by two | E |
| P06 | `proteus_engine.v:759` | `WAITP` timeout fires one cycle late | E |
| P07 | `proteus_engine.v:756` | `WAITP` timeout unit 256 -> 128 | E |
| P08 | `proteus_engine.v:750` | `WAITP` level polarity swapped | E |
| C01 | `proteus_engine.v:776` | JZ takes the opposite condition | **-** |
| C02 | `proteus_engine.v:778` | JC takes the opposite condition | **-** |
| C03 | `proteus_engine.v:785` | jump-target mask off by one | E T |
| C04 | `proteus_engine.v:159` | PC increments by two | E T |
| C05 | `proteus_engine.v:987` | PC wrap test removed | **-** (equivalent) |
| C06 | `proteus_engine.v:365` | `halt_exec` decodes NOP | T |
| C07 | `proteus_engine.v:285` | run-rising restart never fires | E T |
| C08 | `proteus_engine.v:286` | executes before the fill is ready | **-** |
| C09 | `proteus_engine.v:1094` | `prog_ready` one word early | E |
| C10 | `proteus_engine.v:254` | last program word dropped | E |
| F01 | `proteus_engine.v:301` | input-FIFO full one entry early | E |
| F02 | `proteus_engine.v:853` | PUSH accepted when full | E |
| F03 | `proteus_engine.v:1184` | host push accepted when full | E |
| F04 | `proteus_engine.v:880` | PUSHN does not flag `nf` | **-** |
| G01 | `proteus_engine.v:698` | SETP drives 0 | E T |
| G02 | `proteus_engine.v:704` | TOGP does not invert | E T |
| G03 | `proteus_engine.v:722` | DIRS acts as DIRC | E |
| G04 | `proteus_engine.v:729` | DIRC acts as DIRS | E |
| G05 | `proteus_engine.v:736` | ODSET clears instead of sets | E |
| G06 | `proteus_engine.v:292` | side-set window one pin too wide | E |
| G07 | `proteus_engine.v:681` | OUTBIT ignores the invert | **-** |
| H01 | `proteus_host.v:245` | WRITE_INC uses the address pointer | **-** |
| H02 | `proteus_host.v:247` | WRITE_INC auto-increment skips one | **-** |
| H03 | `proteus_host.v:127` | SPI receive takes bits LSB-first | T |
| H04 | `proteus_host.v:208` | MISO shifts the wrong bit | **-** (equivalent) |
| H05 | `proteus_host.v:199` | READ_INC re-reads the same address | **-** |
| H06 | `proteus_host.v:266` | WRITE_ADDR high byte swapped | T |
| T01 | `tt_um_proteus.v:729` | open-drain release inverted | **-** |
| T02 | `tt_um_proteus.v:356` | open-drain collision inverted | **-** |
| T03 | `tt_um_proteus.v:507` | barrier releases on any arrival | T |
| T04 | `tt_um_proteus.v:502` | barrier arrivals not sticky | T |
| T05 | `tt_um_proteus.v:553` | `halt_mask` dropped | T |
| T06 | `tt_um_proteus.v:316` | `uo_out` merge uses the uio mask | T |
| T07 | `tt_um_proteus.v:478` | capture timestamp loses bit 31 | **-** |
| T08 | `tt_um_proteus.v:468` | capture write pointer advances per cycle | T |
| T09 | `tt_um_proteus.v:627` | program byte lane 2 dropped | T |
| T10 | `tt_um_proteus.v:626` | program byte-lane stride 3 -> 4 | T |

Two structural facts fall out of the as-found column:

* **The two benches are complementary, not redundant.** Of the 37 as-found
  kills, **19 die only on the engine bench, 12 only on the top bench, and 6 on
  both**. A single-bench mutation run would have reported a very different
  number for no good reason.
* **The engine bench is deep and narrow; the top bench is wide and shallow.**
  Every `alu`, `fifo`, `waitc` and `timeout` mutant that dies does so in the
  engine bench (only A01 is also caught downstream). Conversely every host,
  capture, barrier, lane-map and pin-fabric mutant needs the top bench, and 12
  of those died there alone.

---

## 3. Survivor analysis

20 survivors. 2 are equivalent mutants (one of them because the mutated line is
dead code), 1 is not observable from this bench's pad model -- but is killed by
a different suite, measured below -- and 17 are real coverage gaps, every one of
which is now closed.

### 3.1 Equivalent mutants (2) -- no assertion can kill these

**C05 -- `(pc_r == LAST_PC) ? 0 : pc_r + 1` replaced by `pc_r + 1`.**
At `PROG_DEPTH = 32`, `ADDR_W = 5` and `pc_r + 1` already wraps to 0 at 31, so
the explicit comparison is redundant. Formally equivalent **for any power-of-two
depth** (4/8/16/32/64). It is *not* equivalent at `PROG_DEPTH = 24`, where
`ADDR_W` is still 5 and the PC would wrap at 32 instead of 24 -- i.e. this line
is load-bearing exactly for the depth-24 area fallback that
`docs/architecture.md` keeps open. The catalogued mutant *is* the deletion
(`pc_r == LAST_PC` -> `1'b0`) and it passes both benches: no assertion can
distinguish it at depth 32.

**H04 -- `miso_q <= tx_byte[6 - bit_cnt]` on the rising edge, mutated to
`tx_byte[7 - bit_cnt]`.** The falling-edge branch writes
`tx_byte[7 - (bit_cnt+1)] == tx_byte[6 - bit_cnt]`, i.e. **the same bit**, and
the next sampling edge is the *following* rising edge. So the rising-edge
assignment is always overwritten with the value it just wrote.
Empirical confirmation, not reasoning: deleting that assignment outright and
re-running the top bench gives `235 checks, 0 errors`. `proteus_host.v:208` is
dead code. (Not changed here -- `src/` is out of scope for this task -- but it is
a one-line cleanup that removes a mutant site and an unused flop fan-out.)

### 3.2 Not observable from this bench (1) -- but killed elsewhere

**T02 -- `coll_now` open-drain term `(od_low & uio_in)` -> `(od_low & ~uio_in)`.**
`tb/top_e2e_tb.v` drives the pad with `assign uio_in = uio_out & uio_oe` -- a
chip with nothing attached. A collision is the pad *disagreeing* with the chip,
which cannot happen here, so the unmutated detector never fires; and the bench
has no `COLLISION` check at all, so the mutant's spurious fires are never read.
Closing it would mean adding an external driver to the pad model, which changes
the "everything enters through `ui_in`/`uio_in`" contract that makes this bench
trustworthy, so it is deliberately left open **in this matrix**.

That is a statement about these two benches, not about the design, and it was
measured rather than asserted. The I2C protocol suite resolves pads with
pull-ups (`sim/test_protocols.py:178`, `lvl = (pullups & ~oe) | (out & oe)`), so
when the master legitimately pulls SCL/SDA low the pad reads low and
`od_low & ~uio_in` is 1 -- the inverted term flags precisely the *correct*
behaviour, on every pull-down of the transaction:

```sh
# T02 applied to a copy of src/ (od_low & uio_in -> od_low & ~uio_in)
make -C sim COCOTB_TEST_MODULES=test_protocols \
  COCOTB_TEST_FILTER=proteus_i2c_master_pins \
  SIM_BUILD=/tmp/t02build COCOTB_RESULTS_FILE=/tmp/t02_results.xml \
  VERILOG_SOURCES="/tmp/t02/tt_um_proteus.v /tmp/t02/proteus_engine.v /tmp/t02/proteus_host.v" \
  VERILOG_INCLUDE_DIRS=/tmp/t02
```

Result: **KILLED** in 9.69 s,

```
** test_protocols.proteus_i2c_master_pins   FAIL   1273150.00 ns   9.69 s **
AssertionError: I2C master pins: 1 of 30 checks failed:
  no open-drain collision flagged: got 192 expected 0
```

(`0xC0` = SDA + SCL, the two open-drain pins.) So T02 is a *fast-set* gap, not
an uncaught bug: `sim/test_protocols.py` asserts `COLLISION == 0x00`, which is a
negative check but exactly the one this mutant violates. The residual gap is
narrower than "collision is untested": there is still **no positive assertion
that the detector fires** when the pad really does disagree with the driver
(forcing `uio_in` against a push-pull output), and formal T1/T2 are combinational
with unreached covers (`results/formal_report.md` section 3.2).

### 3.3 Real test gaps (17) -- all closed

| id | what the benches failed to notice | assertion added | before -> after |
|---|---|---|---|
| A04 | ADC/ADCI carry-in | `b_r0_adci_carry_in` (`0xFF`+1=0, then `ADCI 0` = 1) | survive -> `got 0x0 expected 0x1` |
| A05 | SHL carry-out | `b_shl_carry` (`0x80 SHLI 1` sets C) | survive -> `got 0x0 expected 0x1` |
| A06 | ASR sign fill | `b_r2_asri_sign_fill` (`0x80 ASRI 1` = 0xC0) | survive -> `got 0x40 expected 0xc0` |
| A07 | ROL carry | `b_rol_carry` (`0x81 ROLI 1` -> r[0]) | survive -> `got 0x0 expected 0x1` |
| A08 | ROR carry | `b_ror_carry` (`0x81 RORI 1` -> r[7]) | survive -> `got 0x0 expected 0x1` |
| A11 | NEG | `b_r5_neg` (`NEG 5` = 0xFB) | survive -> `got 0x5 expected 0xfb` |
| A12 | shift count masking | `b_r6_shift_by_7` (`0x80 SHRI 7` = 1) | survive -> `got 0x10 expected 0x1` |
| C01 | JZ condition | `b2_conditions` (5 branches, marker must reach 7) | survive -> `got 0xf0 expected 0x7` |
| C02 | JC condition | `b2_conditions` (same program) | survive -> `got 0x5 expected 0x7` |
| C08 | `prog_ready` gates execution | `a_run_before_fill_no_exec` | survive -> `got 0x1 expected 0x0` |
| F04 | PUSHN `nf` flag | `y2_pushn_nf` + head-intact | survive -> `got 0x0 expected 0x1` |
| G07 | OUTBIT invert | `c_outbit_inv_{mask,data,oe}` | survive -> `got 0x1 expected 0x0` |
| H01 | WRITE_INC target | `WRITE_INC wrote 0x0520` | survive -> `got 0x00 expected 0x5a` |
| H02 | WRITE_INC +1 | `WRITE_INC ptr++ -> 0x0521` | survive -> `got 0x00 expected 0xa5` |
| H05 | READ_INC early fetch | `READ_INC ptr++ -> 0x0521` | survive -> `got 0x5a expected 0xa5` |
| T01 | open-drain release | `od high releases the pad` | survive -> `got 1 expected 0` |
| T07 | capture timestamp bit 31 | `CAP_TS at injected cycle` | survive -> `got 0x00000000` |

Notable individual findings:

* **A06/A12: the existing ALU test was checking a chain, not the operations.**
  `test_alu` ran `LDI r3,0x80; SHRI 1; ROLI 4; ASRI 1; NOT` and compared only
  the final `r3 == 0xFD`. Every intermediate value in that chain happens to be
  non-negative and the shifts happen to commute, so a broken ASR sign fill *and*
  a truncated shift count both produce 0xFD. Checking the intermediate results
  separately exposes both.
* **C01/C02: no conditional branch was tested at all.** `JZ/JNZ/JC/JNC/JN` share
  one decode with the condition in `rd`; the benches only ever emitted
  `JMP` (rd=0, always) and `DJNZ`. Inverting JZ or JC changed nothing that was
  checked. `test_branch` now walks all five conditions through both a taken and
  a not-taken path.
* **H01/H02/H05: the host bench used `WRITE_ADDR`/`READ_ADDR` exclusively**, so
  the entire auto-incrementing pointer path (`SET_PTR`/`WRITE_INC`/`READ_INC`)
  was unverified at RTL level. `tb/host_tb.v` covers it, but that bench is not
  part of the fast set and was not in this matrix -- which is exactly the kind
  of thing a kill-rate number is for.
* **T01: the end-to-end bench never touched open-drain.** It wrote `UIO_OD = 0`
  three times and nothing else, so the `oe & ~(od & out)` release rule -- the
  primitive the I2C story rests on -- had no RTL-level assertion in the fast
  set. It now has one at the pad.

---

## 4. Bench hardening: what changed

Only `tb/` was touched; `src/`, `firmware/`, `test/`, `formal/` and `info.yaml`
are untouched (the `src` SHA-256 prefixes are identical in both raw-log passes).
Nothing outside `tb/` should therefore have moved -- checked rather than assumed:
`.venv/bin/python -m pytest tools/tests -q` gives **179 passed** in 36 s, and the
independent `tb/top_stub_tb.v` (which replaces `proteus_engine` with a stub and
so cannot see the engine edits at all) still reports **62 checks, 0 errors**.

| bench | checks before | checks after | added |
|---|---:|---:|---|
| `tb/engine_smoke_tb.v` | (counts internally, prints PASS/FAIL) | +23 `chk` calls | `run_to_pc` helper; `test_reset` run-before-fill; `test_alu` third/fourth programs; `test_branch`; `test_pins` OUTBIT; `test_fifo_nonblocking` |
| `tb/top_e2e_tb.v` | **224** | **235** | `[1b]` WRITE_INC/READ_INC; `[4a]` open-drain release; `[4b]` capture timestamp width |

Design notes, so the additions do not become their own liability:

* `run_to_pc(pc)` advances until PC reaches `pc`, bounded at 40 ticks. A flag is
  then sampled as "the result of the instruction at `pc-1`", which makes
  carry checks independent of the exact retirement cycle and turns a hung
  mutant into a *failed check* rather than a timeout.
* The new ALU programs use the existing `load_words`/`start_run`/`hread`
  helpers; no new machinery beyond `run_to_pc`.
* The capture-width check reuses the `force dut.cycle` technique phase `[6]`
  already used for the 2^24 boundary, and restores the counter afterwards --
  phase `[5]` uses `-1` as a "not seen" sentinel and would misread a cycle
  value above 2^31. (That mistake was made and caught: the first version left
  the counter at `0x8000_0000` and phase `[5]` failed with
  `barrier pins never asserted (uio0=-2147471865)`.)
* The `WRITE_INC` burst needs **one data byte per frame**: once the command byte
  is decoded, every later byte in the frame is payload, so two `WRITE_INC`
  commands in one frame silently write the second command byte as data. (Also
  caught by running it: `UIO_OUT` read back `0x01`.)
* Both benches take the check message as `input [255:0] what`, i.e. **32
  characters**; a longer literal is silently left-truncated in the failure line
  (`FAIL -incremented to 0x0521...` instead of `FAIL WRITE_INC auto-incremented
  to 0x0521...`). The new messages are all <= 31 characters so a failure names
  the check that failed. This is pre-existing behaviour of the `chk*` helpers
  and was not changed -- widening `what` would also alter how the existing 100+
  messages print.
* The engine bench had exactly one unbounded wait: `load_words` spun on
  `while (!prog_ready)`. Mutant C04 (`ADDR_ONE = 2`) makes the reset fill step
  0,2,...,30,0, so `LAST_PC` is never hit, `prog_ready` never asserts, and the
  bench hung after its (already failing) fill checks until the tool's 180 s
  bound -- 37 % of that run's total runtime spent on one mutant. The wait is now
  bounded at `4*PROG_N` ticks and reports
  `FAIL load_words: prog_ready never asserted after 128 ticks`, so C04 is killed
  in **0.29 s** (and the matrix drops from 492 s to 320 s). A hang is a worse
  diagnostic than a failure: it costs every future run the full timeout and it
  hides *which* check was waiting, even when the real failure was already
  printed above it.

After hardening, the golden tree still passes both benches:

```
tb/engine_smoke_tb.v: ==== PASS: all engine smoke checks passed ====   (exit 0)
tb/top_e2e_tb.v:      --- top_e2e_tb: 235 checks, 0 errors ---
                      top_e2e_tb PASSED                              (exit 0)
```

and the 17 mutants above move from SURVIVED to KILLED (section 3.3, with the
first failing check for each).

One consequence outside this task's file scope: `README.md` and
`docs/verification.md` quote `--- top_e2e_tb: 224 checks, 0 errors ---`. The
number is now **235**. Those two documents (and `docs/ai-development.md`'s
reference to the same bench) need their quoted count refreshed by their owner;
this task's file scope is `tools/mutate.py` + `results/mutation*.{md,txt}` and
`tb/` only.

---

## 5. Final matrix

`python3 tools/mutate.py --all`, second run, after the hardening. Tail of the
log verbatim (`results/mutation_raw.txt`, from `=== SUMMARY`):

```
id,file,line,cat,engine,top,verdict
A01,proteus_engine.v,408,alu,KILLED,KILLED,KILLED
A02,proteus_engine.v,418,alu,KILLED,SURVIVED,KILLED
A03,proteus_engine.v,419,alu,KILLED,SURVIVED,KILLED
A04,proteus_engine.v,413,alu,KILLED,SURVIVED,KILLED
A05,proteus_engine.v,432,alu,KILLED,SURVIVED,KILLED
A06,proteus_engine.v,446,alu,KILLED,SURVIVED,KILLED
A07,proteus_engine.v,456,alu,KILLED,SURVIVED,KILLED
A08,proteus_engine.v,465,alu,KILLED,SURVIVED,KILLED
A09,proteus_engine.v,651,alu,KILLED,SURVIVED,KILLED
A10,proteus_engine.v,665,alu,KILLED,SURVIVED,KILLED
A11,proteus_engine.v,637,alu,KILLED,SURVIVED,KILLED
A12,proteus_engine.v,405,alu,KILLED,SURVIVED,KILLED
P01,proteus_engine.v,834,pacer,SURVIVED,KILLED,KILLED
P02,proteus_engine.v,838,pacer,KILLED,SURVIVED,KILLED
P03,proteus_engine.v,845,pacer,SURVIVED,KILLED,KILLED
P04,proteus_engine.v,818,waitc,KILLED,SURVIVED,KILLED
P05,proteus_engine.v,821,waitc,KILLED,SURVIVED,KILLED
P06,proteus_engine.v,759,timeout,KILLED,SURVIVED,KILLED
P07,proteus_engine.v,756,timeout,KILLED,SURVIVED,KILLED
P08,proteus_engine.v,750,waitp,KILLED,SURVIVED,KILLED
C01,proteus_engine.v,776,control,KILLED,SURVIVED,KILLED
C02,proteus_engine.v,778,control,KILLED,SURVIVED,KILLED
C03,proteus_engine.v,785,control,KILLED,KILLED,KILLED
C04,proteus_engine.v,159,control,KILLED,KILLED,KILLED
C05,proteus_engine.v,987,control,SURVIVED,SURVIVED,SURVIVED
C06,proteus_engine.v,365,control,SURVIVED,KILLED,KILLED
C07,proteus_engine.v,285,control,KILLED,KILLED,KILLED
C08,proteus_engine.v,286,control,KILLED,SURVIVED,KILLED
C09,proteus_engine.v,1094,control,KILLED,SURVIVED,KILLED
C10,proteus_engine.v,254,control,KILLED,SURVIVED,KILLED
F01,proteus_engine.v,301,fifo,KILLED,SURVIVED,KILLED
F02,proteus_engine.v,853,fifo,KILLED,SURVIVED,KILLED
F03,proteus_engine.v,1184,fifo,KILLED,SURVIVED,KILLED
F04,proteus_engine.v,880,fifo,KILLED,SURVIVED,KILLED
G01,proteus_engine.v,698,pins,KILLED,KILLED,KILLED
G02,proteus_engine.v,704,pins,KILLED,KILLED,KILLED
G03,proteus_engine.v,722,pins,KILLED,SURVIVED,KILLED
G04,proteus_engine.v,729,pins,KILLED,SURVIVED,KILLED
G05,proteus_engine.v,736,pins,KILLED,SURVIVED,KILLED
G06,proteus_engine.v,292,pins,KILLED,SURVIVED,KILLED
G07,proteus_engine.v,681,pins,KILLED,SURVIVED,KILLED
H01,proteus_host.v,245,host,SURVIVED,KILLED,KILLED
H02,proteus_host.v,247,host,SURVIVED,KILLED,KILLED
H03,proteus_host.v,127,host,SURVIVED,KILLED,KILLED
H04,proteus_host.v,208,host,SURVIVED,SURVIVED,SURVIVED
H05,proteus_host.v,199,host,SURVIVED,KILLED,KILLED
H06,proteus_host.v,266,host,SURVIVED,KILLED,KILLED
T01,tt_um_proteus.v,729,top,SURVIVED,KILLED,KILLED
T02,tt_um_proteus.v,356,top,SURVIVED,SURVIVED,SURVIVED
T03,tt_um_proteus.v,507,top,SURVIVED,KILLED,KILLED
T04,tt_um_proteus.v,502,top,SURVIVED,KILLED,KILLED
T05,tt_um_proteus.v,553,top,SURVIVED,KILLED,KILLED
T06,tt_um_proteus.v,316,top,SURVIVED,KILLED,KILLED
T07,tt_um_proteus.v,478,capture,SURVIVED,KILLED,KILLED
T08,tt_um_proteus.v,468,capture,SURVIVED,KILLED,KILLED
T09,tt_um_proteus.v,627,top,SURVIVED,KILLED,KILLED
T10,tt_um_proteus.v,626,top,SURVIVED,KILLED,KILLED

mutations: 57  KILLED=54  SURVIVED=3
kill rate: 54/57 = 94.7% (survivors 3)
kills per bench: engine=37/57  top=23/57
```

Kill rate by category after hardening:

| category | killed |
|---|---|
| `alu` | 12/12 |
| `pacer` | 3/3 |
| `waitc` | 2/2 |
| `timeout` | 2/2 |
| `waitp` | 1/1 |
| `control` | 9/10 (C05, equivalent) |
| `fifo` | 4/4 |
| `pins` | 7/7 |
| `host` | 5/6 (H04, dead code) |
| `capture` | 2/2 |
| `top` | 7/8 (T02, unobservable here) |

---

## 6. What this does not cover

* **Only the two fast benches.** `tb/host_tb.v`, `tb/top_stub_tb.v`,
  `tb/top_depth64_tb.v`, `tb/top_capdepth_tb.v`, `sim/` (cocotb) and the
  differential test are not in this matrix. H01/H02/H05 are killed here *only*
  because new assertions were added; before that, the mutation run correctly
  reported that the fast set had no auto-increment coverage even though
  `tb/host_tb.v` does.
* **One mutation per site.** No second-order mutants, no mutants of `src/
  proteus_defs.vh` constants (e.g. `PROTEUS_FIFO_DEPTH`), no mutants of the
  `#define` opcode table -- a wrong opcode is caught by `tools/tests/test_asm.py`
  against `tools/isa.py`, which is a different layer.
* **Parameter space.** All runs are the default build (`PROG_DEPTH = 32`,
  `FIFO_DEPTH = 4`, `CAP_DEPTH = 4`). C05 shows why this matters: an equivalent
  mutant at depth 32 is a live bug at depth 24.
* **Purely combinatorial mutants are still possible.** The catalogue is curated
  by hand for plausibility. The bug classes it targets are all present: pacer
  carry, WAITC off-by-one, barrier release, FIFO full compare, open-drain
  release, halt_mask, program byte lanes, host strobes, capture width. It is not
  generated exhaustively from an operator grammar. A mechanically generated
  corpus would find more survivors and a lower kill rate.
* **Collision detection has no positive assertion.** T02 is killed by the I2C
  protocol suite (measured, 3.2), but only by a `COLLISION == 0` check; nothing
  asserts that a real pad/driver conflict *sets* a collision bit.

---

## 7. Reproducing

```sh
python3 tools/mutate.py --list                  # the 57-mutation catalogue
python3 tools/mutate.py --verify-mutations      # 57/57 specs apply cleanly
python3 tools/mutate.py --all                   # full matrix (~5.5 min)
python3 tools/mutate.py --only A04,C01,H01      # a subset
python3 tools/mutate.py --all --benches engine   # one bench only
python3 tools/mutate.py --all --timeout 60       # tighter run bound
```

Exit code is 0 when every mutation either kills or survives cleanly, 1 if a
mutation spec could not be applied (which would otherwise be reported as a fake
survivor), 2 on a non-green baseline.
