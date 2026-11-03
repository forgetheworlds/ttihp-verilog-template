# v2 verification parity (2/2): ported v1 benches + mutation testing

Scope: hybrid v2 tree only (`v2/src`, `v2/tb`, `v2/tools`, `v2/results`).  This
task's edits, by mtime: `v2/tb/run.sh` 09:58, `v2/tb/engine_smoke_tb.v` and
`v2/tools/mutate.py` 10:02, `v2/tb/top_e2e_tb.v` 10:24,
`v2/results/mutation_raw.txt` 10:41, `v2/results/v2_mutation.md` 10:46.

Nothing outside `v2/` was written by this task.  Measured (mtime scan over
`src/ tools/ firmware/ sim/ test/ tb/ formal/ scripts/ docs/`, `info.yaml`,
`README.md`, `SUBMISSION.md`; 109 files):

```
newest 5 mtimes outside v2/:
  2026-11-03 04:56  README.md
  2026-11-03 04:57  docs/verification.md
  2026-11-03 10:16  docs/flow.md
  2026-11-03 10:16  scripts/synth.sh
  2026-11-03 10:18  SUBMISSION.md
```

The three 10:16-10:18 entries are other agents on this shared tree (docs and
synth), not this task.  Every v1 file — `src/`, `tools/`, `firmware/`, `sim/`,
`test/`, `tb/`, `formal/`, `info.yaml` — is older than 04:57, i.e. older than
the first edit of this task.

What this closes from `v2/results/v2_verify.md` §6:

| v1 gate | v2 status before | v2 status now |
|---|---|---|
| `tb/engine_smoke_tb.v` | NOT covered | **ported, PASS (237 checks)** |
| `tb/top_e2e_tb.v` | NOT covered | **ported, PASS (400 checks)** |
| `results/mutation.md` | NOT covered | **re-run on v2: 99 mutants, 95 killed (96.0 %)** |

---

## 1. Files

| file | origin | change |
|---|---|---|
| `v2/tb/engine_smoke_tb.v` | `tb/engine_smoke_tb.v` | assist CSR port wired, new `[z]` task, check counter, 64-char assertion names |
| `v2/tb/top_e2e_tb.v` | `tb/top_e2e_tb.v` | v2 map/VERSION, engine 2 + 3-bit RUN + IRQ chain `[4c]`, assist CSR bank `[4d]`, assist pin ownership `[4e]` |
| `v2/tb/run.sh` | `v2/tb/run.sh` | both benches added; verdict taken from each bench's own PASS marker |
| `v2/tools/mutate.py` | `tools/mutate.py` | v2 paths, 12 RTL files, 99-mutation catalogue, text-anchored mutations |
| `v2/results/mutation_raw.txt` | new | per-mutant raw log of the run below |
| `v2/results/v2_mutation.md` | new | this report |

Port fidelity is measurable.  The v1→v2 diff removes **5** lines from the engine
bench and **12** from the top bench, and none of them is an assertion:

```
$ diff -u tb/engine_smoke_tb.v v2/tb/engine_smoke_tb.v | grep -E '^-[^-]'
-// engine_smoke_tb.v -- self-checking smoke test for src/proteus_engine.v
-    input [255:0] name;
-    input [255:0] name;
-    $display("==== proteus_engine smoke test ====");
-      $display("==== PASS: all engine smoke checks passed ====");

$ diff -u tb/top_e2e_tb.v v2/tb/top_e2e_tb.v | grep -E '^-[^-]'
-// tb/top_e2e_tb.v -- PROTEUS end-to-end: REAL tt_um_proteus, four REAL engines,
-// everything driven through the host SPI pins only (ui_in[2:0] / uo_out[0]).
-// hierarchy is only read (dut.cycle, dut.u_eng0.prog_mem[i], dut.host_en,
-  localparam [6:0] OP_PUSH   = 7'h40, OP_BAR  = 7'h47, OP_CFG  = 7'h4D;
-  localparam [15:0] E0_BASE    = 16'h0010, E1_BASE = 16'h0030;
-  localparam [15:0] RA_PM0     = 16'h0100, RA_PM1  = 16'h0200;
-  task fail(input [255:0] what);
-  task chk8(input [7:0] got, input [7:0] exp, input [255:0] what);
-  task chk1(input got, input exp, input [255:0] what);
-  task chk24(input [23:0] got, input [23:0] exp, input [255:0] what);
-      base = (e == 1) ? E1_BASE : E0_BASE;
-    chk8(b2, 8'h01, "VERSION");
```

i.e. comments, constants rewritten in place for the 3-engine map, the
assertion-name width (32 → 64 chars: a 256-bit `what` silently truncated longer
names in FAIL messages), the engine-1-only base lookup, and the VERSION
literal.  Every v1 check is still present and still runs.

---

## 2. Bench results

### 2.1 Engine bench (assist port tied to valid idle defaults)

```sh
iverilog -g2005 -Iv2/src -Iv2/tb -o /tmp/v2eng.vvp \
         v2/tb/engine_smoke_tb.v v2/src/proteus_engine.v
vvp /tmp/v2eng.vvp
```

```
[y2] PUSHN on a full FIFO sets nf and does not stall
[z] LDAS/STAS/ASST assist port + empty-read nf rule
==== PASS: all engine smoke checks passed (237 checks) ====
```

### 2.2 Top bench (3 engines, 3-bit RUN masks, pages 0x0100/0x0200/0x0300, assist window 0x0600)

```sh
ALL="v2/src/tt_um_proteus.v v2/src/proteus_engine.v v2/src/proteus_host.v \
     v2/src/proteus_assist.v v2/src/crc_bit.v v2/src/assist_fifo.v \
     v2/src/shiftreg32.v v2/src/nrzi_enc.v v2/src/nrzi_dec.v \
     v2/src/manchester_enc.v v2/src/manchester_dec.v"
iverilog -g2005 -Iv2/src -Iv2/tb -o /tmp/v2top.vvp v2/tb/top_e2e_tb.v $ALL
vvp /tmp/v2top.vvp
```

```
[4] capture unit (CAP_EN uio0)
[4c] engine 2 page 0x0300 / 3-engine window ends / RUN mask
[4d] assist CSR window 0x0600 (host register + engine LDAS/STAS)
[4e] assist pin ownership (PINCFG en=1) and the push-pull stage
[5] BAR 0 across engines 0 and 1
    barrier pin cycles: uio0=62156 uio1=62156
[6] PACE past cycle 2^24
    cycle after injection = 0x010000ca
    cycle now = 0x01000fa1, toggles=13
[7] restart does not execute the stale PC
[8] HOST_DISABLE handover
--- top_e2e_tb: 400 checks, 0 errors ---
top_e2e_tb PASSED
```

### 2.3 Whole tree

```sh
bash v2/tb/run.sh
```

```
crc_bit        TB_CRC_BIT PASS
fifo           TB_FIFO PASS
shiftreg       TB_SHIFTREG PASS
nrzi           TB_NRZI PASS
nrzi_wave      TB_NRZI_WAVE PASS
manchester     TB_MANCHESTER PASS
csr            TB_CSR PASS (37 checks)
top_smoke      TB_TOP_SMOKE PASS (19 checks, 7 pad edges)
engine_smoke   ==== PASS: all engine smoke checks passed (237 checks) ====
top_e2e        top_e2e_tb PASSED

benches PASS=10 FAIL=0
```

### 2.4 Assertions that exist only in the v2 ports

`engine_smoke [z]`: `as_rd` / `as_wr` / `as_cmd_en` are single-instruction
strobes; `as_id = imm[2:0]`, `as_reg = rs`, `as_wdata = rd`, `as_cmd_id = rs`,
`as_cmd = imm8`; an empty read sets `nf`, leaves `rd` unchanged, and does not
touch Z/N (asserted together with Z/N sampled across the LDAS).

`top_e2e [4c]`: engine 2's page `0x0300` loads and reads back without clobbering
engine 0 word 0; `0x0400` is out of map and does not alias engine 2; `0x006F` is
the last window byte, `0x0070` aliases nothing; `0x0054` (engine 2's r0) is
writable; `RUN` is 3 bits (bit 3 ignored, bit 2 runs engine 2, and a HALT
retires it); `RA_HALT` clears a RUN bit without touching the others; engine 2's
two `PUSH` bytes drain in order (host pop routing); a host `IN_FIFO` write is
routed to engine 2; engine 2's `IRQSET` reaches `IRQ_STATUS` and `IRQ_ACK`
clears it; an empty `LDAS` of FIFO DATA on engine 2 sets `nf` and keeps `rd`.

`top_e2e [4d]`: `PINCFG` resets to 0, is host-writable, and sits outside the
8-register engine view (`0x0643` is MANCH CFG, `0x0648` is PINCFG); `0x0650` is
outside the window; NRZI DIV host write/readback (6-bit register); host FIFO
DATA write pushes, host read pops (level → 0); engine 0 `STAS`→`LDAS` round trip
through DIV; engine `STAS` push + `LDAS` pop through FIFO DATA with the drained
status; empty DATA read keeps `rd` and sets `nf`; assist write arbitration with
two engines strobing in the same cycle (engine 1 beats engine 0 on the same
register; engine 2 beats engine 1 across different assists, and engine 2's
`ASST` reaches its own assist id); engine 2 writing alone still reaches the bank.

`top_e2e [4e]`: with `PINCFG` en=1 the MANCH assist owns its TX bit — its idle
level beats the host register value on `uo_out[7]` while `uo_out[6]` is
untouched, and on the UIO bank it forces OE on despite `UIO_OD` (assist pins are
push-pull, so the merge stage clears open-drain for the bits it owns).

---

## 3. Mutation run

### 3.1 Catalogue

99 mutations, all anchored by a text string that must occur exactly once in its
file (the resolved `file:line` is printed by `--list` / `--verify-mutations`, so
a mislocated mutation aborts instead of reporting a fake survivor):

| group | ids | count |
|---|---|---:|
| ALU / flags / shifts | A01–A12 | 12 |
| pacer, WAITC, WAITP timeout/level | P01–P08 | 8 |
| control: branch conditions, PC, restart gating, fill | C01–C10 | 10 |
| engine FIFOs | F01–F04 | 4 |
| pins / side-set / bit-pin | G01–G07 | 7 |
| host SPI FSM, address/shift paths | H01–H06 | 6 |
| top: merge, barrier, capture, program lanes, RUN/HALT | T01–T18, T28–T30 | 21 |
| v2 top: 3-bit masks, 3-engine decode, assist CSR window, arbitration, pin stage | T19–T27 | 9 |
| v2 engine: LDAS/STAS/ASST port and empty-read rule | V01–V12 | 12 |
| v2 assist wrapper: PINCFG, FIFO push/pop/status, DIV, address decode | W01–W10 | 10 |

```sh
python3 v2/tools/mutate.py --verify-mutations
python3 v2/tools/mutate.py --all
```

```
$ python3 v2/tools/mutate.py --verify-mutations | tail -1
99/99 mutation specs apply cleanly
```

Baseline (unmutated `v2/src`, same build path as every mutant):

```
# baseline (unmutated v2/src)
#   engine: SURVIVED in 0.13s      # = the bench reached its PASS marker
#   top: SURVIVED in 9.26s
```

### 3.2 Result

```
mutations: 99  KILLED=95  SURVIVED=4
kill rate: 95/99 = 96.0% (survivors 4)
kills per bench: engine=49/99  top=64/99
elapsed: 969.1s
```

Machine-readable matrix, verbatim from `v2/results/mutation_raw.txt`
(`KILLED` on either bench kills the mutant):

```
id,file,line,cat,engine,top,verdict
A01,proteus_engine.v,437,alu,KILLED,KILLED,KILLED
A02,proteus_engine.v,447,alu,KILLED,SURVIVED,KILLED
A03,proteus_engine.v,447,alu,KILLED,SURVIVED,KILLED
A04,proteus_engine.v,442,alu,KILLED,SURVIVED,KILLED
A05,proteus_engine.v,461,alu,KILLED,SURVIVED,KILLED
A06,proteus_engine.v,475,alu,KILLED,SURVIVED,KILLED
A07,proteus_engine.v,485,alu,KILLED,SURVIVED,KILLED
A08,proteus_engine.v,494,alu,KILLED,SURVIVED,KILLED
A09,proteus_engine.v,680,alu,KILLED,SURVIVED,KILLED
A10,proteus_engine.v,694,alu,KILLED,SURVIVED,KILLED
A11,proteus_engine.v,666,alu,KILLED,SURVIVED,KILLED
A12,proteus_engine.v,434,alu,KILLED,SURVIVED,KILLED
P01,proteus_engine.v,863,pacer,SURVIVED,KILLED,KILLED
P02,proteus_engine.v,867,pacer,KILLED,SURVIVED,KILLED
P03,proteus_engine.v,874,pacer,SURVIVED,KILLED,KILLED
P04,proteus_engine.v,847,waitc,KILLED,SURVIVED,KILLED
P05,proteus_engine.v,849,waitc,KILLED,SURVIVED,KILLED
P06,proteus_engine.v,780,timeout,KILLED,SURVIVED,KILLED
P07,proteus_engine.v,780,timeout,KILLED,SURVIVED,KILLED
P08,proteus_engine.v,779,waitp,KILLED,SURVIVED,KILLED
C01,proteus_engine.v,805,control,KILLED,SURVIVED,KILLED
C02,proteus_engine.v,807,control,KILLED,SURVIVED,KILLED
C03,proteus_engine.v,813,control,KILLED,KILLED,KILLED
C04,proteus_engine.v,173,control,KILLED,KILLED,KILLED
C05,proteus_engine.v,1039,control,SURVIVED,SURVIVED,SURVIVED
C06,proteus_engine.v,380,control,SURVIVED,KILLED,KILLED
C07,proteus_engine.v,300,control,KILLED,KILLED,KILLED
C08,proteus_engine.v,301,control,KILLED,SURVIVED,KILLED
C09,proteus_engine.v,1146,control,KILLED,SURVIVED,KILLED
C10,proteus_engine.v,269,control,KILLED,SURVIVED,KILLED
F01,proteus_engine.v,316,fifo,KILLED,SURVIVED,KILLED
F02,proteus_engine.v,881,fifo,KILLED,SURVIVED,KILLED
F03,proteus_engine.v,1229,fifo,KILLED,SURVIVED,KILLED
F04,proteus_engine.v,903,fifo,KILLED,SURVIVED,KILLED
G01,proteus_engine.v,727,pins,KILLED,KILLED,KILLED
G02,proteus_engine.v,733,pins,KILLED,KILLED,KILLED
G03,proteus_engine.v,751,pins,KILLED,SURVIVED,KILLED
G04,proteus_engine.v,758,pins,KILLED,SURVIVED,KILLED
G05,proteus_engine.v,765,pins,KILLED,SURVIVED,KILLED
G06,proteus_engine.v,307,pins,KILLED,SURVIVED,KILLED
G07,proteus_engine.v,710,pins,KILLED,SURVIVED,KILLED
H01,proteus_host.v,245,host,SURVIVED,KILLED,KILLED
H02,proteus_host.v,247,host,SURVIVED,KILLED,KILLED
H03,proteus_host.v,127,host,SURVIVED,KILLED,KILLED
H04,proteus_host.v,208,host,SURVIVED,SURVIVED,SURVIVED
H05,proteus_host.v,199,host,SURVIVED,KILLED,KILLED
H06,proteus_host.v,266,host,SURVIVED,KILLED,KILLED
T01,tt_um_proteus.v,792,top,SURVIVED,KILLED,KILLED
T02,tt_um_proteus.v,448,top,SURVIVED,KILLED,KILLED
T03,tt_um_proteus.v,594,top,SURVIVED,KILLED,KILLED
T04,tt_um_proteus.v,589,top,SURVIVED,KILLED,KILLED
T05,tt_um_proteus.v,635,top,SURVIVED,KILLED,KILLED
T06,tt_um_proteus.v,403,top,SURVIVED,KILLED,KILLED
T07,tt_um_proteus.v,569,capture,SURVIVED,KILLED,KILLED
T08,tt_um_proteus.v,560,capture,SURVIVED,KILLED,KILLED
T09,tt_um_proteus.v,694,top,SURVIVED,KILLED,KILLED
T10,tt_um_proteus.v,693,top,SURVIVED,KILLED,KILLED
T11,tt_um_proteus.v,232,top,SURVIVED,SURVIVED,SURVIVED
T12,tt_um_proteus.v,690,top,SURVIVED,KILLED,KILLED
T13,tt_um_proteus.v,689,top,SURVIVED,KILLED,KILLED
T14,tt_um_proteus.v,655,top,SURVIVED,KILLED,KILLED
T15,tt_um_proteus.v,632,top,SURVIVED,KILLED,KILLED
T16,tt_um_proteus.v,230,top,SURVIVED,SURVIVED,SURVIVED
T17,tt_um_proteus.v,666,top,SURVIVED,KILLED,KILLED
T18,tt_um_proteus.v,672,top,SURVIVED,KILLED,KILLED
T19,tt_um_proteus.v,618,top,SURVIVED,KILLED,KILLED
T20,tt_um_proteus.v,413,assist,SURVIVED,KILLED,KILLED
T21,tt_um_proteus.v,410,assist,SURVIVED,KILLED,KILLED
T22,tt_um_proteus.v,326,assist,SURVIVED,KILLED,KILLED
T23,tt_um_proteus.v,328,assist,SURVIVED,KILLED,KILLED
T24,tt_um_proteus.v,336,assist,SURVIVED,KILLED,KILLED
T25,tt_um_proteus.v,337,assist,SURVIVED,KILLED,KILLED
T26,tt_um_proteus.v,344,assist,SURVIVED,KILLED,KILLED
T27,tt_um_proteus.v,341,assist,SURVIVED,KILLED,KILLED
T29,tt_um_proteus.v,658,top,SURVIVED,KILLED,KILLED
T30,tt_um_proteus.v,697,top,SURVIVED,KILLED,KILLED
T28,tt_um_proteus.v,610,top,SURVIVED,KILLED,KILLED
V01,proteus_engine.v,393,assist,KILLED,KILLED,KILLED
V02,proteus_engine.v,394,assist,KILLED,KILLED,KILLED
V03,proteus_engine.v,395,assist,KILLED,KILLED,KILLED
V04,proteus_engine.v,396,assist,KILLED,KILLED,KILLED
V05,proteus_engine.v,397,assist,KILLED,KILLED,KILLED
V06,proteus_engine.v,398,assist,KILLED,KILLED,KILLED
V07,proteus_engine.v,399,assist,KILLED,KILLED,KILLED
V08,proteus_engine.v,400,assist,KILLED,KILLED,KILLED
V09,proteus_engine.v,1017,assist,KILLED,KILLED,KILLED
V10,proteus_engine.v,1022,assist,KILLED,KILLED,KILLED
V11,proteus_engine.v,1018,assist,KILLED,KILLED,KILLED
V12,proteus_engine.v,1017,assist,KILLED,KILLED,KILLED
W01,proteus_assist.v,712,assist,SURVIVED,KILLED,KILLED
W02,proteus_assist.v,281,assist,SURVIVED,KILLED,KILLED
W03,proteus_assist.v,547,assist,SURVIVED,KILLED,KILLED
W04,proteus_assist.v,803,assist,SURVIVED,KILLED,KILLED
W05,proteus_assist.v,525,assist,SURVIVED,KILLED,KILLED
W06,proteus_assist.v,503,assist,SURVIVED,KILLED,KILLED
W07,proteus_assist.v,279,assist,SURVIVED,KILLED,KILLED
W08,proteus_assist.v,418,assist,SURVIVED,KILLED,KILLED
W09,proteus_assist.v,147,assist,SURVIVED,KILLED,KILLED
W10,proteus_assist.v,148,assist,SURVIVED,KILLED,KILLED
```

Raw log with the change, the intent, the source line and the failing assertion
for every mutant: `v2/results/mutation_raw.txt` (1242 lines).

---

## 4. Survivor analysis

Four mutants survive; all four are **equivalent** (no observable difference),
and none is a coverage gap in these benches.

| id | location | mutation | verdict |
|---|---|---|---|
| C05 | `proteus_engine.v:1039` | `(pc_r == LAST_PC) ? 0 : pc_r + 1` → `1'b0` | equivalent |
| H04 | `proteus_host.v:208` | `miso_q <= tx_byte[6 - bit_cnt]` → `[7 - bit_cnt]` | equivalent (dead assignment) |
| T11 | `tt_um_proteus.v:232` | `run_mask = run_reg & ~halted_mask & ready_mask` → drop `~halted_mask` | equivalent |
| T16 | `tt_um_proteus.v:230` | `wire [2:0] err_mask` → `wire [3:0] err_mask` | equivalent |

**C05** — `ADDR_W = $clog2(PROG_DEPTH)` is 5 for the default `PROG_DEPTH=32` and
`LAST_PC = PROG_DEPTH-1 = 31`, the largest 5-bit value.  The mutant arm
`n_pc = pc_r + ADDR_ONE` truncates to 5 bits, so at 31 it produces 0 as well;
the explicit wrap is redundant at this depth (it would matter only for a
non-power-of-two depth, e.g. 24 or 48, which these benches do not instantiate).

**H04** — the same clocked block assigns `miso_q <= tx_byte[7 - bit_cnt]` on the
SCK *falling* edge (`proteus_host.v:306`) in every bit period (`else if (fall)`),
and the falling edge always follows the rising edge within a run.  The
rising-edge assignment the mutant changes is unconditionally overwritten before
the master samples again, so no value the bench can observe changes.

**T11** — `run_mask` feeds only the engines' `run` input and the barrier release
comparison.  `run_reg`'s HALT retirement (`halt_mask`, line 635) clears a
halting engine's bit in the same cycle, so the only cycle with `run_reg=1` and
`halted=1` is a halted engine the host re-enables in that cycle; the engine's own
`restart` gate (`run & ~run_q`, `proteus_engine.v:300`) suppresses execution for
exactly that cycle and clears `halted_r` on the same edge.  The mutation can only
change the `run` input of a cycle the engine ignores, and no state exists where a
halted engine carries a RUN bit into a barrier comparison.

**T16** — `err_mask` is consumed only by `wire any_err = |err_mask;`
(`tt_um_proteus.v:725`).  The 3-bit concatenation zero-extends into the 4-bit
wire, so the reduction is bit-identical.

### 4.1 One survivor that was *nearly* equivalent — and what it exposed

T24 (`as_wr_eff` without `e_as_wr[2]`) first survived *not* because the bench
lacked an engine-2 write, but because the payload muxes are separate signals:
with engines 1 and 2 strobing in the same cycle the write still leaves with
engine 2's fields.  Instrumented probe (`v2/src` copy in `/tmp`, monitor on the
assist port):

```
ASWR t=741135000 id=3 reg=3 data=0b e1wr=0 e2wr=0
ASWR t=741165000 id=1 reg=0 data=5a e1wr=0 e2wr=0
ASWR t=791145000 id=3 reg=3 data=22 e1wr=1 e2wr=0
ASWR t=873695000 id=0 reg=2 data=3f e1wr=1 e2wr=1
```

So the bench needed the case where engine 2 writes **alone**.  Adding it killed
the mutant:

```
=== MUT T24 [assist] tt_um_proteus.v:336 -- KILLED
--- top: KILLED in 9.23s
    exit=1 FAIL engine 2 writing alone reaches the CSR bank: got 0x15 expected 0x37 (t=923835000)
```

---

## 5. Iteration record (how the 16 first-pass survivors were closed)

First full run against the ported benches, before the survivor work:

```
mutations: 99  KILLED=83  SURVIVED=16
kill rate: 83/99 = 83.8% (survivors 16)
kills per bench: engine=49/99  top=49/99
```

12 of the 16 were real coverage gaps (the other 4 are the equivalent mutants
above); 8 of those 12 were uncovered by every v2 bench, one only by the ported
bench (§5.1).  Each was closed with the minimal assertion, and the kill was then
measured:

| survivor | what the bench did not check | assertion added (v2 top bench) | kill evidence |
|---|---|---|---|
| T02 | collision flag for an open-drain low | `0x0510 == 0` + `STATUS[3] == 0` after the od pull-down | `FAIL open-drain low is not recorded as a collision: got 0x01 expected 0x00` |
| T15 | `RA_HALT` write path | stop engine 2's loop with `RA_HALT 0x04`, assert RUN bit 2 cleared and E_STATUS run=0 | `FAIL RA_HALT write clears RUN bit 2: got 0x04 expected 0x00` |
| T17 | host `IN_FIFO` write routing | write `0x0060` and run `PULL; PUSH` on engine 2 | `FAIL eng2 did not halt after the IN_FIFO push` / `got 0x00 expected 0x7e` |
| T18 | host `OUT_FIFO` pop routing | engine 2 pushes two bytes, host reads twice | `FAIL eng2 OUT_FIFO second byte …: got 0xc3 expected 0xd4` |
| T20 | assist pin stage clearing open-drain | `PINCFG` en=1 on UIO with `UIO_OD=0xFF`, assert `uio_oe[3]=1`, `uio_oe[2]=0` | `FAIL assist pin is push-pull: OE forced on despite od: got 0 expected 1` |
| T21 | assist `uo_out` merge stage | `PINCFG` en=1 on `uo_out[7]` over a 0 host value | `FAIL assist owns uo[7]: its idle 1 beats the host 0` |
| T23 | host read side effects in the assist bank | host FIFO DATA push/pop with the level readback | `FAIL host FIFO DATA read pops (level 0, empty): got 0x01 expected 0x20` |
| T24 | engine 2 writing alone | solo `STAS` to DIV from engine 2 | `FAIL engine 2 writing alone reaches the CSR bank: got 0x15 expected 0x37` |
| T25, T27 | arbitration payload/id when two engines strobe | engines 1+2 write different assists in the same cycle | killed (see matrix) |
| T26 | `ASST` command from engine 2 | engine 2 `ASST` selects the CRC page, read back `0x0603 == 0x02` | killed (see matrix) |
| W03 | engine 2's empty-read `as_empty` | `LDAS` of empty FIFO DATA on engine 2 | `FAIL eng2 empty FIFO DATA read leaves rd unchanged: got 0xxx expected 0x66` |

Re-measured on the final benches: 95/99 (96.0 %), the 4 survivors being exactly
the equivalent mutants.  `top_e2e_tb` went from 303 checks (first port) to 400;
`engine_smoke_tb` reports 237 checks, of which the `[z]` task and the counter are
v2 additions.

### 5.1 Were those gaps already covered by another v2 bench?

Measured by running `v2/tb/tb_csr.v` and `v2/tb/tb_top_smoke.v` against each
mutant (fresh `v2/src` copy in `/tmp`, `cwd=v2/tb` so the benches' hex vectors
resolve; the unmutated baseline passes both: `TB_CSR PASS (37 checks)`):

8 mutants x 2 benches, each run separately:

| survivor | `tb_csr` | `tb_top_smoke` |
|---|---|---|
| T02, T15, T17, T18, T20, T21, T24, W03 | survived | survived |
| T23 | **killed** (`FAIL FIFO level 1: got 0x02 want 0x01`, `FAIL FIFO pop order #2`) | survived |

So 8 of the 12 were gaps in *every* v2 bench, and T23 was a gap in the ported
bench only — `tb_csr` already asserted the host-side FIFO DATA pop order and
level.  `v2/sim/test_protocols.py` was not measured against the survivors (74 s
per run); no claim is made about it.

---

## 6. What these two benches still do not cover

Stated so the kill rate is not over-read:

1. **CRC / SHIFT / NRZI / MANCH internals.**  The catalogue mutates only the
   assist registers and pin logic the top bench drives.  The five blocks'
   datapaths are covered by their own benches (`v2/tb/tb_crc_bit.v`,
   `tb_shiftreg.v`, `tb_nrzi.v`, `tb_nrzi_wave.v`, `tb_manchester.v`, all in
   `v2/tb/run.sh`) and, at pad level, by `v2/sim/test_protocols.py`.
2. **Differential RTL vs model** (`sim/test_diff.py` equivalent) and **formal**
   (`formal/`) remain absent for v2 — `v2/CUTOVER.md` items 3 and 4.
3. **Physical flow** (LibreLane/GDS/DRC/LVS/STA) and **GLS** — unchanged, still
   open (`v2/CUTOVER.md` items 1, 5, 6).
4. Found while writing this run, and measured: `RA_HALT` (`0x0005`) is defined
   in `v2/sim/host.py` but no v2 bench or test wrote it before this port
   (`grep` over `v2/tb`, `v2/sim`, `v2/test` matches only the definition).  The
   host-side assist FIFO DATA read/pop was already covered by `v2/tb/tb_csr.v`
   (§5.1), so that one was a gap in the ported bench only.

## 7. Reproduce

```sh
bash v2/tb/run.sh                                  # 10 benches, includes both ports
python3 v2/tools/mutate.py --verify-mutations      # 99/99
python3 v2/tools/mutate.py --all                   # ~16 min, writes the raw log
python3 v2/tools/mutate.py --only T24 --raw ""     # one mutant, stdout only
```
