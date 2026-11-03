# Differential verification: RTL vs `tools/model.py`

Layer 7 of `docs/verification.md` did not exist. `tools/model.py` is the
executable specification for `src/`, but "the RTL matches the model" was
enforced only by hand-written expectations in the other suites, never measured.
This is that measurement: the same program is loaded into the real
`tt_um_proteus` over the host SPI and into `ProteusModel`, and every
architectural field is compared on **every cycle**.

| item | value |
|---|---|
| command | `cd sim && env PATH=/home/ubuntu/verilog/.venv/bin:$PATH make COCOTB_TEST_MODULES=test_diff` |
| equivalent | `cd sim && make diff` (same test, private `sim_build/diff`) |
| programs | 209 = 200 generated seeds + 9 crafted corners |
| compared cycles | **16,122** |
| mismatches | **0** |
| programs cut at the 3000-cycle limit | 0 (every program halted) |
| simulated time | 9,737,490 ns (10 ns clock) |
| cocotb real time | 348.80 s (291.69 s for the same corpus an hour earlier; the box is shared with other agents) |
| result | `TESTS=1 PASS=1 FAIL=0 SKIP=0` |

Corpus shape: words 6..31 (mean 13.5), compared cycles per program 6..780
(mean 77.1). Kind histogram: `alu` 23, `pins` 23, `ctrl` 22, `loop` 22, `wait`
22, `fifo` 22, `irq` 22, `capture` 22, `mix` 22, `corner` 9.

---

## 1. How it works

### 1.1 Corpus: `tools/diffgen.py`

`gen_program(seed)` is deterministic (`random.Random(0x5EED0000 + seed)`) and
emits at most 32 words ending in `HALT`, from nine kinds: pure ALU, pin
fabric, control-flow skips, `DJNZ` loops, waits/pacer, FIFOs, IRQ/barrier,
capture, and a `mix` class that combines waits with FIFOs (the "longer
program"). Every CFG the body depends on is emitted in a prologue before first
use: `SIDE`, `BITPIN`, `TIMEOUT`, `PERIOD0..3`, `SCRATCH`.

The generator is also the *contract* for what "should agree". Four constraints
are enforced there rather than masked in the test, because each one would
otherwise compare two configurations or an undefined encoding:

| constraint | why |
|---|---|
| ≤ 4 push instructions, ≤ `len(prefill)` pulls, non-blocking forms in loops | keeps every program at or below the shared `FIFO_DEPTH = 4` (model and RTL now both default to 4; the corpus never depends on more) |
| ≤ 4 capture events | shared `CAP_DEPTH = 4` (RTL top parameter and model constant) |
| `UO` masks limited to bits `[7:2]` | `uo_out[1:0]` are the host's IRQ/MISO pins while `host_en=1`; `src/tt_um_proteus.v` drops engine writes to them |
| no bank 3, all jump targets in `0..31`, only `DJNZ` jumps backwards (counter loaded with 1..5), only `BAR 0` | bank 3 is undefined; loops must be bounded; a one-engine barrier must not deadlock |
| `WAITP`/`IRQWAIT` either match on the issue cycle or are covered by `CFG TIMEOUT` | `timeout_cfg = 0` waits forever in both implementations |

`WAITP` matching is guaranteed by construction: the test's pad presents a
constant external pull `ext` on `uio_in`, and a level-1 `WAITP` mask is chosen
as a subset of `ext`.

`python tools/diffgen.py --check 500` regenerates and runs the corpus on the
model alone, with no RTL: 509 programs, all halting, worst program 780 cycles,
69 of 72 opcodes reached and every opcode in the required safe subset present.
It also rejects any program that addresses bank 3 or exceeds 32 words.

### 1.2 Lockstep and alignment: `sim/test_diff.py`

`ProteusHost` loads the program bytes over SPI (`CMD_WRITE_ADDR` with
auto-increment, four bytes per word — lane 3 is the program-memory hole the top
drops), pushes the prefill bytes, arms `CAP_EN` when the program uses hardware
edges, and asserts `RUN`.

The subtle part is alignment. `proteus_engine.v` spends one cycle on a run
rising edge (`restart` gates `exec_act` so a stale PC never executes), so the
first instruction retires two clocks after the RUN write lands. A monitor task
samples `run_reg[0]` on every posedge; at the edge where it reads 1 it takes the
DUT's `cycle` counter `c`, sets `model.cycle = c + 1` and calls
`model.start(0)`. One edge later it checks the restart state, and from then on
performs exactly one `model.step()` per DUT clock. `model.step()` for interval
`k` therefore runs with `model.cycle == k`, which is what makes `TSLO`,
`MEASLO` and `CAPTURE` timestamps comparable at all.

### 1.3 Compared every cycle

`uio_out`, `uio_oe` (the port is `oe_eff`), `uio_od`, `uo_out[7:2]`,
`r0..r7`, `pc`, `z`/`c`/`n`, `halted`, `run`, `irq`, `collision` (sticky mask),
`in`/`out` FIFO *contents and counts* (logical order reconstructed from
`in_rd`/`in_cnt`/`in_mem`), capture count, capture overflow, and every capture
event pushed (newest entry's timestamp/pin/level whenever the count changes; no
pops occur, so that is the whole sequence).

Flags are read from the engine's internal `z_r`/`c_r`/`n_r`, because `E_FLAGS`
(`+0x2`) reads 0 over the host port by design — the top documents that
`docs/architecture.md`'s register map has no flags interface in the frozen
engine port list. Everything else is the same state the host can see.

On the first mismatch the test prints seed, cycle, field, the model value, the
RTL value, and the full disassembly, then fails with a one-line summary.

### 1.4 Pad model

`uio_in = (uio_out & uio_oe) | ext` — the rule `sim/host.py` uses, plus a
constant external pull so open-drain release and the collision detector are
exercised. `ext` costs nothing in realism and turns collision from
"always zero" into a live signal.

---

## 2. Semantic differences that had to be resolved

All were harness questions, not design defects. None required an `src/` change.

1. **`RisingEdge` resumes before the design's non-blocking updates.** Reading
   registers immediately after `await RisingEdge(dut.clk)` in cocotb 2.1 on
   Icarus returns the *pre-edge* value. Measured directly: at the edge `pc_r`
   read 2, one picosecond later it read 0 (the `JMP` had retired). Comparing
   the pre-edge snapshot against `model.step()` put every registered
   accumulator exactly one cycle behind — `collision` failed with
   `model=0x03 rtl=0x0f` on seed 1, and the same offset would have hidden real
   capture-event bugs. Fixed by a `Timer(1, "ps")` settle after the edge. This
   is the single most important detail for anyone extending the test.
2. **FIFO depth and capture depth were temporarily divergent.** `FIFO_DEPTH=4`
   / `CAP_DEPTH=4` in `src/`, originally 8 and 8 in `tools/model.py`. During
   this run the corpus was kept at or below 4 rather than clamping the
   comparison; the model has since been aligned to 4/4 (constants and guards),
   so the comparison now uses the same depth on both sides.
3. **`uo_out[1:0]` are not fabric pins while the host is active.** The top
   drives them from `irq_out`/`miso`. The test masks `uo_out` to `[7:2]` and the
   generator never emits a `UO` write outside that range.
4. **`uio_in` is a loopback pad, not a stimulus.** The level the engine samples
   is a function of the chip's own previous drive plus `ext`. The test presents
   it one half-cycle ahead of the sampling edge and re-reads the pad on the
   next edge (`pad_level` field) so a write-latency artefact becomes an
   explicit harness failure instead of a phantom design bug.
5. **`WAITP`/`IRQWAIT` with `timeout_cfg = 0` wait forever.** Both
   implementations agree, but a corpus containing one would burn the cycle
   budget doing nothing. The generator arms `CFG TIMEOUT` or uses a mask the
   external pull satisfies on the issue cycle.
6. **Undefined opcodes execute as `NOP` in both**, so un-programmed words are
   harmless; the generator still fills every word with `HALT` explicitly.

### 2.1 No design defect was found

16122 compared cycles over 209 programs, 0 mismatches, every program terminated
at its own `HALT` rather than the cycle cap. No program was minimized because
nothing failed.

### 2.2 The harness is sensitive, not vacuous

A pass is only evidence if the comparison can fail. Injected fault: `chk("pc",
e.pc + 1, ...)` in `sim/test_diff.py`. Result, on the first compared cycle:

```
DIFF MISMATCH seed=0 kind=alu cycle=5996 field=pc model=0x1 rtl=0x0
program:
seed=0 kind=alu
ext=0x3c cap_en=0x00 fabric_in=0x12 prefill=[184, 131, 153]
00  3d8000  INC r6
01  33e000  ASR r7, r4
...
17  700000  HALT
AssertionError: seed 0 (alu) cycle 5996: pc model=0x1 rtl=0x0
```

The fault was reverted; the run above is on the reverted tree. During
development the same machinery caught three genuine harness bugs (the pre-edge
read above, a pad written one interval late, and an off-by-one in the model's
`uio_in` slot), each of which would have masked real divergence.

---

## 3. Crafted corners exercised

`seed 9001` all-ones/zero data through every flag path (`0xFF+1 -> 0x00, C`,
`0x00-1 -> 0xFF, borrow`, `NOT`/`NEG` of both, `0x80+0x80`).
`9002` shift and rotate by 0 and by 7, both immediate and register forms.
`9003` carry/borrow chains through `ADCI`/`SBCI`/`ADC`/`SBC`/`CMPI`.
`9004` pin-mask overlap: overlapping `SETP`/`OUTP`/`TOGP` masks plus a
side-set window on the same pins, `DIRS`/`DIRC` and `ODSET`/`ODCLR` overlap.
`9005` `WAITP` level wait that never arrives, bounded by `CFG TIMEOUT` (262
cycles, timeout flag exercised in both).
`9006` capture: two hardware edges on `CAP_EN=0x03` plus one software
`CAPTURE` (11 cycles).
`9007` pacer with a fractional period, `0x6480` = 100.5 cycles in 24.8, four
`PACE`+`TOGP` slots (310 cycles).
`9008` `DJNZ` wrap: counter 0 decrements to `0xFF`, 256 iterations.
`9009` `BAR 0` with a single running engine, `IRQSET`/`IRQWAIT`/`IRQCLR`,
`MEASLO`, and an unconditional forward `JMP`.

---

## 4. What this does not cover

* **Concurrent engines.** Only engine 0 runs; the inter-engine pin-merge
  priority, multi-engine `BAR`, and cross-engine IRQ are not compared (the
  model's merge order and the top's are asserted equal by construction in
  `src/tt_um_proteus.v`, not measured here).
* **Host traffic during a run.** The SPI load finishes before `RUN`; no command
  is issued while an engine executes.
* **Hardware edge capture from random seeds.** Random programs leave
  `CAP_EN=0`, so only software `CAPTURE` events occur there; edge capture is
  covered by corner 9006 only.
* **X/Z propagation.** Reads that return `X` are reported as a mismatch, but
  the test does not assert X-freedom (that is `formal/xcheck_tb.v`).
* **Gate level.** This is RTL simulation; the netlist is not exercised.

Read this page next to `docs/verification.md`, which now records this layer and
the exact command.
