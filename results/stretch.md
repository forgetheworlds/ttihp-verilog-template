# Stretch: JTAG TAP in firmware (measured)

`firmware/jtag_tap.asm` implements an IEEE 1149.1 TAP on engine 0, using only
the PROTEUS ISA and the pin fabric. It is verified by `demos/run_stretch.py`
against an independent Python TAP model (its own 16-state machine, its own 4-bit
IR and 32-bit DR, pad-level traffic only).

```
python3 demos/run_stretch.py          # this report, exit 0
python3 -c "import sys;sys.path.insert(0,'tools');import asm;
print({e:len(w) for e,w in asm.assemble_file('firmware/jtag_tap.asm')['programs'].items()})"
# -> {0: 32}
```

## 1. What landed, what did not

| requirement | status | evidence |
|---|---|---|
| TAP FSM the host can drive | **landed**, 12 of 16 states | §4 walk: 12/12 states, 27 edges |
| Test-Logic-Reset | landed | §4 reset row |
| Run-Test/Idle, Select-DR/IR, Capture-DR/IR, Shift-DR/IR, Exit1-DR/IR, Update-DR/IR | landed | §4 walk |
| Pause-DR, Exit2-DR, Pause-IR, Exit2-IR | **not implemented** | §4 gap probe: 3/4 bits differ |
| IR width 4, Capture-IR = 0b0001 | landed | §4 IR row reads `0001` |
| IDCODE, fixed 32-bit, LSB = 1 | landed: `0x5B5B5B5B` | §4 IDCODE row, exact match |
| BYPASS (1-bit DR) | **not implemented** | §4 gap probe: model 0, device 1 |
| TDO push-pull, inputs on TCK rising edge | landed | §5: OE = 1 on 51/51 sampled edges |
| <= 32 words, word count reported | landed: **32/32** | §3 |
| SWD (optional) | **not attempted** | JTAG did not reach the full goal, so the optional stage was not started |

A real host can therefore identify the device and read IDCODE, but it must not
use Pause/Exit2 (no re-entry into Shift from Pause) and must not select BYPASS.
Both limits are measured, not asserted: the demo prints the model's expectation
next to the device's actual bits.

## 2. Pin map and host contract

| signal | pin | direction | mechanism |
|---|---|---|---|
| TMS | `UIO[0]` | in | `INPR UIO, 0x01` in the cycle the TCK rising edge completes |
| TCK | `UIO[1]` | in | `WAITP UIO, 0x02, 0` / `WAITP UIO, 0x02, 1`: falling edge re-arm, rising edge is the clock |
| TDI | `UIO[2]` | in | not used by this image (read-only TAP) |
| TDO | `UIO[3]` | out | `OUTBIT r2` through the bit-pin shortcut, push-pull (OUTBIT sets OE) |

The host must write **`0x98` to `0x0012`** (engine 0 window `+0x12`, bit-pin
config = bank UIO, pin 3, no invert) before setting the `RUN` bit. The image
does not execute `CFG BITPIN`: that is the one word the 32/32 build does not
have, and `+0x12` is the documented host-writable equivalent
(`docs/programming.md` §2.2). Nothing else has to be preloaded — every capture
reloads the shift register.

Power-on state is Test-Logic-Reset: the block at address 0 is `tlr`, which is
where the PC starts.

## 3. Word count, block by block

Assembled addresses (`tools/asm.py --listing`):

| block | address | words | contents |
|---|---:|---:|---|
| `tlr` | 0 | 5 | edge wait, TMS sample, TMS=1 stay / TMS=0 -> Run-Test/Idle |
| `upd` | 5 | 4 | Run-Test/Idle **and** Update-DR/IR (identical successors) |
| `seldr` | 9 | 5 | Select-DR: TMS=1 -> Select-IR, TMS=0 -> load IDCODE, fall into Shift |
| `shift` | 14 | 7 | Shift-DR/IR: TMS=1 -> Exit1, TMS=0 present `r2` bit 0 and rotate |
| `exit1` | 21 | 5 | Exit1-DR/IR: TMS=1 -> Update, TMS=0 -> stay (Pause not modelled) |
| `selir` | 26 | 6 | Select-IR: TMS=1 -> Test-Logic-Reset, TMS=0 -> load 0b0001, -> Shift |
| **total** | | **32** | engine 0, exactly the 32-word build |

Why the state machine is six blocks and not sixteen: the DR and IR columns have
identical state graphs, so the column is not a state, only a capture constant.
Capture is folded into Shift — the load happens on the `Select -> Shift` edge,
which a 1149.1 host does not sample, so the first sampled bit is still bit 0
(verified: the 32-bit read is exact). Update-DR/IR and Run-Test/Idle have the
same successors (TMS=1 -> Select-DR, TMS=0 -> stay), so they share one block.

## 4. Test table (`python3 demos/run_stretch.py`)

```
contracted checks
PASS  reset: 5 x TMS=1 -> Test-Logic-Reset
      Test-Logic-Reset, then TMS=0 -> Run-Test/Idle
PASS  Capture-IR + 4-bit IR scan reads 0b0001
      device read 0001, model expects 0001
PASS  IDCODE DR scan, 32 bits
      read 0x5B5B5B5B, expected 0x5B5B5B5B; first bits 1 1 0 1 1 0 1 0
PASS  TAP state walk, 12 implemented states, TDO checked
      12/12 states visited over 27 TCK edges
PASS  TDO driven push-pull (OE) on every sampled edge
      OE=1 on 51/51 TCK edges of the DR scan
PASS  timing margin (smallest TCK phase that still reads IDCODE)
      LOW=HIGH>=4 clk, HIGH>=5 clk with LOW=2, LOW>=1 clk with HIGH=40;
      shipped 40/40

measured limitations (not modelled by this 32-word image)
GAP   BYPASS (IR=0b1111): 1-bit DR
      model expects 0 (1-bit bypass), device sent 1 (IDCODE bit 0 = 1)
      -> IR not decoded
GAP   Pause-DR -> Exit2-DR -> Shift-DR re-entry
      model re-entered Shift-DR and expected [1, 1, 0, 1], device sent
      [0, 0, 0, 0]: 3/4 bits differ
```

The walk drives reset, a 2-bit DR scan, a 2-bit IR scan and a reset again, and
at every edge where 1149.1 defines TDO (the Shift states) it compares the pad
level the chip drives against the model's expectation. The full 32-bit DR scan
is the separate IDCODE row above; the full 4-bit IR scan is the IR row.

IDCODE `0x5B5B5B5B`: bit 0 = 1 as required. It is a repeating byte on purpose —
one 8-bit rotator (`RORI r2, 1`, period 8) emits all 32 bits with 2
instructions per clock. The suggested `0x0A5C0A5C` has period 16 and needs a
second register plus a carry chain at every shift edge, which does not fit
(also measured: §6).

## 5. Timing, measured rather than claimed

The demo sweeps the TCK phases on every run:

| phase | measured minimum |
|---|---|
| symmetric low = high | 4 clk each |
| high, with low = 2 clk | 5 clk |
| low, with high = 40 clk | 1 clk |

The longest path between a rising edge and the next "wait for TCK low" is 5
instructions (`shift`: `INPR`, `JNZ`, `OUTBIT`, `RORI`, `JMP`). The shipped host
timing is 40 clk low + 40 clk high, ~5x margin. TDO is written at the end of one
edge's processing, so it is stable a whole TCK period before the host samples
it: no setup race. `OE` on `UIO[3]` is set on every sampled edge (51/51), i.e.
TDO is genuinely push-pull, not a pull-up.

## 6. Why 16 states and BYPASS do not fit (assembled, not argued)

Every number below is an assembler word count of a real variant in the same
block-per-state style, not an estimate:

| build | words | vs 32 |
|---|---:|---|
| shipped: 12 states, no BYPASS | **32** | fits |
| 12 states, with BYPASS | 41 | 9 over |
| 16 states, no BYPASS | 44 | 12 over |
| 16 states, with BYPASS | 51 | 19 over |

Per-state cost is irreducible on this ISA: 3 words of edge wait (`WAITP` low,
`WAITP` high, `INPR`) plus 1 conditional and 1 tail jump = 5-7 words per state,
because there is no indirect jump and every branch is two words
(`CMPI`/`JNZ`). Sixteen states alone are therefore 80+ words; the six-block
image above is already the compression (column-blind, Capture folded into Shift,
Update folded into Run-Test/Idle).

The options the task suggested were both attempted and measured:

* **Split the shift path across engine 0 and engine 1.** It does not create
  headroom. The action for a given TCK edge depends on TMS *at that edge*, and
  TMS can only be sampled by the engine that decides the transition, so the
  shift engine would have to be told the state class one edge in advance over
  sideband pads and would still need its own TMS test. Moving the 2-word shift
  body plus the 5-word capture select off engine 0 leaves the FSM at 25 words,
  and the FSM is 5-7 words per state: 16 states does not fit 32 either way.
* **`PROG_DEPTH = 64`.** The earlier `[5:0] PDEPTH` truncation is fixed
  (`[6:0]`, covered by `tb/top_depth64_tb.v`), so a 64-deep build is valid RTL.
  The 44-word and 51-word JTAG variants are still not shippable on the ASIC,
  because raising the default depth from 32 to 64 adds ~246k um2 of flip-flop
  program RAM and the 32-deep design is already routing-limited; they can run
  on the FPGA build, which instantiates `PROG_DEPTH = 64`.

## 7. What is missing, exactly

1. **Pause-DR / Exit2-DR / Pause-IR / Exit2-IR.** `exit1` with TMS=0 stays in
   Exit1 instead of entering Pause, so a host that pauses and later leaves with
   TMS=1 lands in Update one state early; re-entering Shift from Pause reads
   zeros instead of the IDCODE stream (measured: 3/4 bits differ). Cost to fix:
   two more blocks, +12 words (row "16 states, no BYPASS" = 44).
2. **BYPASS.** The IR is not decoded, so an `IR = 0b1111` scan followed by a
   1-bit DR scan returns IDCODE bit 0 instead of the bypass register (measured:
   model 0, device 1). Cost to fix: 3 words to accumulate the four TDI bits in
   the shift path, 2 words to select the capture constant, 3 words for the
   captured value's path = 9 words (row "12 states, with BYPASS" = 41).
3. **TDI capture.** The TAP is read-only: `TDI` is never shifted into a
   register. This is what makes BYPASS and any writable DR impossible; it is
   also why the IDCODE scan can afford a plain 8-bit rotator.
4. **SWD.** The optional stage was gated on JTAG landing cleanly. It did not
   (2 of the acceptance items are gaps above), so `firmware/swd_target.asm` was
   not written. A minimal SWD target (line reset, 8-bit packet + parity, ACK,
   IDCODE `0x0BB11477` with turnaround) needs its own open-drain `SWDIO`
   (`UIO[4]`), `SWCLK` (`UIO[5]`), a packet decoder and a turnaround FSM; on the
   measured per-block costs (§6) it is far outside a 32-word engine, and it
   would have to share engine 0 with the TAP.

## 8. Reproduce

```
python3 demos/run_stretch.py                 # 6 checks PASS, 2 gaps printed, exit 0
python3 demos/run_stretch.py --words         # engine 0: 32 words
python3 demos/run_demos.py                   # unchanged demos still pass
```
