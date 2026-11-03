# PROTEUS - a programmable protocol engine

PROTEUS is a **software-defined pin engine** for the Jane Street protocol-emulator
ASIC competition: four independent 24-bit micro-engines on one die, sharing a
24-pin fabric with per-pin direction and open-drain control, a 32-bit cycle
timebase with deadline pacing, hardware barriers, eight IRQ lines, and an
8-entry edge-timestamp capture FIFO. Protocols are firmware; the silicon only
supplies pins, time, and synchronisation. Target: Tiny Tapeout IHP
`sg13cmos5l`, `6x4` tiles, 50 MHz, submission deadline 2027-01-18
(`research/prior-art.md`).

Unlike a fixed UART/SPI/I2C block, the same four engines run UART, SPI and I2C
side by side from program memory that the host writes over SPI after reset -
and can be reprogrammed in the field, because nothing about a protocol is
committed to gates. The chip is also an *instrument*: the capture unit
timestamps edges to the cycle, so it observes a bus as well as driving one.

<p align="center">
  <img src="docs/figures/fig1_architecture.svg"
       alt="PROTEUS block diagram: host SPI, register file and decode, four engines, pin fabric, barriers, IRQ, capture FIFO and pads"
       width="100%">
</p>

Block diagram: `docs/figures/fig1_architecture.svg`. A three-minute tour with
runnable commands is in `docs/demo.md`; the other figures are under
`docs/figures/`.

---

## Architecture

```
                    host SPI (mode 0, MSB first, SCK <= clk/8)
   ui_in[0] SCK ───┐  ui_in[1] CS_N ─┐  ui_in[2] MOSI ─┐      uo_out[0] MISO
                   v                 v                 v              ^
              +--------------------------------------------------+     |
              |  proteus_host: 14-state command FSM, 16-bit ptr |-----+
              |  cmds 00..09: NOP WRITE_INC READ_INC SET_PTR_LO  |
              |  SET_PTR_HI WRITE_ADDR READ_ADDR PING RESET DIS  |
              +---------------------------+----------------------+
                                          | reg_we/reg_addr/reg_wdata
                                          | reg_re /reg_raddr/reg_rdata
     +------------------------------------+-----------------------------------+
     |                          tt_um_proteus (top)                           |
     |   register file + address decode | barriers(4) | IRQ(8) | capture FIFO |
     |   cycle counter (32-bit)         |            |        | 8 x 37 bit   |
     +----+--------------+--------------+------+-----+--------+--------------+
          |              |              |      |              |
     +----v----+    +----v----+    +----v----+ +----v----+
     | engine0 |    | engine1 |    | engine2 | | engine3 |   4 x (32 x 24 prog
     | 8 regs  |    |         |    |         | |         |        RAM, 8x8 in/out
     | 8-bit ALU    |         |    |         | |         |        FIFO, pacer,
     | pacer   |    |         |    |         | |         |        side-set)
     +----+----+    +----+----+    +----+----+ +----+----+
          |  {data,mask} write buses per bank (uo / uio / oe / od)
          v              v              v            v
     +-----------------------------------------------------------------------+
     |  pin fabric merge:  reg = (reg & ~mask) | (data & mask), engines 0..3  |
     |  uo_q[7:0]  uio_q[7:0]  oe_q[7:0]  od_q[7:0]      od => high-Z release |
     +-----------------------------------------------------------------------+
        |                    |                         |
   uo_out[7:2]          uio[7:0]                 ui_in[7:3]
   fabric out 6        fabric io 8, per-pin OE/OD   fabric in 5
       (+ uo_out[0]=MISO, uo_out[1]=IRQ while the host owns the pins)
```

Source split (`docs/architecture.md` section 7):

| file | contents |
|---|---|
| `src/proteus_defs.vh` | geometry, register map, opcode and CFG constants |
| `src/proteus_engine.v` | one engine: program RAM, decode, ALU, FIFOs, pacer, side-set, barriers |
| `src/proteus_host.v` | SPI slave, command FSM, 16-bit pointer |
| `src/tt_um_proteus.v` | pins, 4 engines, fabric merge, capture, barriers, IRQ, decode |

### Pacing, measured

The deadline pacer is the part that is hard to get right and easy to claim: a
100.5-cycle period (0x6480 in 24.8 fixed point) has no integer divider that can
express it. Measured on `tools/model.py`, the pacer's completions stay on
`floor(c0 + k*100.5)` while a naive divider loses half a cycle per period:

<p align="center">
  <img src="docs/figures/fig3_pacer.svg"
       alt="Measured PACE completion instants for a 100.5-cycle period, the fractional carry, and the drift of a naive 100-cycle divider"
       width="100%">
</p>

The same mechanism turns into a real frame: `firmware/uart_tx.asm` (18 words)
produces the trace in `docs/figures/fig4_uart_frame.svg`, ten slots of exactly
434 cycles with transitions two cycles after each tick.

---

## ISA summary

24-bit instruction, one per cycle, 72 opcodes, 8 x 8-bit registers, flags
`Z`/`C`/`N`. Field layout (`tools/isa.py`, `docs/isa.md` section 1):

```
 23      17 16  14 13  11 10        3 2   0
+---------+------+------+------------+-----+
|   op    |  rd  |  rs  |    imm8    | ss  |
|  7 bits | 3 b  | 3 b  |   8 bits   | 3 b |
+---------+------+------+------------+-----+
```

| group | opcodes | examples |
|---|---|---|
| ALU immediate | `0x00..0x0E` | `LDI`, `ADDI`, `CMPI`, `SHLI`, `ADCI` |
| ALU register | `0x10..0x21` | `ADD`, `SUB`, `SHL`, `NOT`, `NEG`, `ADC` |
| Pin operations | `0x22..0x2D` | `SETP`, `CLRP`, `TOGP`, `OUTP`, `INPR`, `DIRS`, `DIRC`, `ODSET`, `OUTBIT`, `WAITP` |
| Control | `0x30..0x3E` | `JMP`, `JZ`, `DJNZ`, `HALT`, `WAITC`, `PACE`, `PACERST`, `ASSERT` |
| System / time | `0x40..0x4D` | `PUSH`, `PULL`, `IRQSET`, `IRQWAIT`, `BAR`, `TSLO`, `MEASLO`, `CAPTURE`, `CFG` |

Representative encoding - `CFG PERIOD0, 0x40` (set pacing period to 64.0 cycles),
as produced by `tools/asm.py` for the worked example in `docs/programming.md`:

```
word = 0x9A1200
  op   0x4D  = CFG                      bits 23:17
  rd   0     unused                     bits 16:14
  rs   2     CFG field PERIOD0          bits 13:11
  imm  0x40  period byte 0 (LSB)        bits 10:3
  ss   0     no side-set                bits  2:0
```

Field-level quirks worth knowing (all from `src/proteus_engine.v` /
`tools/asm.py`, not guesses):

- Pin ops: `rs[1:0]` = bank (`0`=UI, `1`=UO, `2`=UIO), `imm8` = mask; `OUTP`
  and `INPR` also carry a value register in `rd`.
- `WAITP bank, mask, level`: `rs = bank[1:0] | (level << 2)`, `imm8` = mask.
  So `WAITP UIO, 0x40, 1` assembles to `0x5A3201` with `[ss=1]`.
- `WAITC n` with `n = rs[2:0]:imm8` occupies `max(n,1)` cycles.
- Jump condition lives in `rd`; the assembler fills it from the mnemonic.

---

## Toolchain

Everything is plain Python 3.12 plus Icarus/Yosys; the virtualenv is `.venv`.

```sh
# assemble; --listing prints "engine address word  disassembly ; source line"
.venv/bin/python tools/asm.py firmware/uart_tx.asm --listing
.venv/bin/python tools/asm.py firmware/i2c_master.asm --depth 32 -o i2c.json

# cycle-accurate golden model (executable specification)
.venv/bin/python -c "import sys; sys.path.insert(0,'tools'); import model; print(model.ProteusModel)"

# unit + firmware + model tests
.venv/bin/python -m pytest tools/tests -q
```

Instruction counts at the default depth 32 (`tools/asm.py`, measured):

| firmware | words | fits 32-deep default? |
|---|---:|---|
| `firmware/pin_blink.asm` | 5 | yes |
| `firmware/uart_tx.asm` | 18 | yes |
| `firmware/uart_rx.asm` | 26 | yes |
| `firmware/spi_master.asm` | 32 | yes (exactly) |
| `firmware/i2c_master.asm` | 32 + 32 (engines 3 and 2) | yes |

---

## Verification

Current state, measured 2026-11-02 on this host. Commands are copy-pasteable.

| suite | command | result |
|---|---|---|
| Python: assembler / model / firmware | `.venv/bin/python -m pytest tools/tests -q` | **176 passed, 0 failed**, ~98 s |
| Host SPI unit bench | `iverilog -g2005 -I src -o /tmp/host_tb tb/host_tb.v src/proteus_defs.vh src/proteus_engine.v src/proteus_host.v src/tt_um_proteus.v && vvp /tmp/host_tb` | PASS: 28 checks, 0 errors |
| Engine smoke bench | same pattern with `tb/engine_smoke_tb.v` | PASS: `==== PASS: all engine smoke checks passed ====` |
| Top end-to-end (real engines, pins only) | same pattern with `tb/top_e2e_tb.v` | PASS: 224 checks, 0 errors |
| Top with stub engine (`proteus_engine` replaced) | `iverilog -g2005 -I src -o /tmp/top_stub_tb tb/top_stub_tb.v tb/stub_engine.v src/proteus_defs.vh src/proteus_host.v src/tt_um_proteus.v && vvp /tmp/top_stub_tb` | PASS: 62 checks, 0 errors |
| cocotb smoke through real host SPI | `make -C sim` | **PASS**: 1 test, 9 phases, 90 checks, 0 failures (`sim/results.xml`) |
| **DUT vs golden model, cycle lockstep** | `cd sim && make diff` | **PASS**: 209 programs, 16,122 compared cycles, **0 mismatches**, every program halted at its own `HALT`; fault injection caught on the first cycle (`results/diff_report.md`) |
| **Protocols on the real RTL** (UART TX/RX, SPI, I2C firmware) | `cd sim && make protocols` | **PASS 4/4**: UART TX 18 checks, UART RX 6, SPI 123 (CS framing + both modes), I2C 30 (START/RSTART/STOP, ACK, stretching, t_HIGH/t_LOW minima); decoded at the pads by independent models (`results/protocol_rtl.md`) |
| **Mutation testing** (do the benches catch bugs?) | `python3 tools/mutate.py --all` | **57 mutants**: 37/57 killed as-found (64.9%) → **54/57 (94.7%)** after hardening; 3 survivors explained (2 equivalent, 1 not observable by that bench) — `results/mutation.md` |
| Official TT submission gate (`tt-gds-action` path) | `cd test && PATH=$PWD/../.venv/bin:$PATH make` | **PASS** under both cocotb **2.0.1** (the `test/requirements.txt` CI pin) and 2.1.0 (local venv): identity ok, program loaded and verified over SPI, `uio[0]` toggled 29 times |
| DE2 FPGA demos (4 demos, real chip RTL) | `iverilog -g2005 -I src -I fpga -o /tmp/fpga_tb fpga/tb_fpga.v src/proteus_defs.vh src/proteus_engine.v src/proteus_host.v src/tt_um_proteus.v fpga/tt_um_proteus_fpga.v fpga/host_master.v fpga/boot_loader.v && vvp /tmp/fpga_tb` | **PASS**: 36 checks, 0 errors, all four demos boot and verify through the real host protocol |

<p align="center">
  <img src="docs/figures/fig6_verification.svg"
       alt="Ten verification layers from encoding tests to formal proofs and the FPGA self-check, with measured pass counts and sources"
       width="100%">
</p>

The same ten layers as a diagram, with the artifact behind every count, are in
`docs/figures/fig6_verification.svg`. Counts are a snapshot: re-run the command
in the row above and the figure's source column to refresh them.

The functional suites are green on the settled tree. The DUT-vs-model row is
the strongest single result: every architectural register, pin, FIFO content and
capture event is compared on every cycle, and an injected `pc+1` fault was
caught on the first compared cycle. `docs/verification.md` records the exact
methods, the remaining gaps (concurrent engines, host traffic during a run,
gate level, formal scope) and the commands.

`test/` and `.github/workflows/` are present, so the Tiny Tapeout submission gate
runs and passes. Gate-level simulation (`gl_test`) still needs the LibreLane
netlist, which is in progress.

---

## Synthesis and physical flow

```sh
make pdk            # IHP-Open-PDK @2bbec755 into $HOME/pdk (~1.3 GB)
make pdk-lite       # liberty-only alternative (~1.8 MB)
make synth          # cell-area report -> results/synth.txt (+ results/yosys_*.log)
make synth-design   # real RTL, PROG_DEPTH=32 (DEPTHS="32 16" to sweep)
scripts/synth_full.sh   # hierarchical + flat + lever benches -> results/synth_full.txt
make flow           # LibreLane 6x4 hardening (Docker) -> runs/wokwi/final
```

**Area is measured** on the settled post-cut tree (`results/area_full.md`,
`results/synth_full.txt`, snapshot hashes `c8cc5467 / e0d19eaf / 65a62a1c`):

| quantity | value |
|---|---:|
| full-chip, hierarchical | **581,138.67 um^2**, 42,049 cells |
| full-chip, flat / sign-off | **558,240.45 um^2**, 38,958 cells |
| utilisation | 64.4% of 902,417 um^2 row area (flat: 61.9%) |
| vs 60% placement budget (541,450 um^2) | 107.3% (flat: 103.1%) |
| engines | 132,227 / 132,306 / 132,235 / 132,382 um^2 |
| `proteus_host` | 12,503.60 um^2 |
| top-level glue | 39,485.28 um^2 (capture FIFO 27,504 of it) |
| flops | 4,838 = 237,014 um^2 |

The cut saved 39,843 um^2 (-6.4%) versus the 620,982 um^2 baseline. If 65%
density placement fails, `PROG_DEPTH = 24` is a valid fallback after the
`ADDR_W` fix: ~496,616 um^2 hierarchical / ~473,718 um^2 flat (91.7% / 87.5% of
the 60% budget), at the cost of 8 instructions per engine.

Timing at 50 MHz (`CLOCK_PERIOD` 20 ns) is **pending the LibreLane run**
(`PL_TARGET_DENSITY_PCT=65`); the figure of merit is `timing__setup__ws` in
`runs/wokwi/final/metrics.json`. A static `ltp` estimate gives a 62-level
longest path from `u_eng0.pc_r[3]` with an NLDM estimate of 12.39 ns typical,
leaving 7.61 ns at 20 ns - plausible, not closed.

---

## Repository layout

```
info.yaml              Tiny Tapeout project metadata (tiles 6x4, 50 MHz)
src/                   RTL: defs header, engine, host SPI, top
docs/architecture.md   implementation contract (behaviour, register map)
docs/isa.md            ISA prose mirror of tools/isa.py
docs/info.md           Tiny Tapeout project page
docs/verification.md   methodology, commands, current evidence, gaps
docs/demo.md           three-minute demo script + figure provenance
docs/figures/          SVG figures (architecture, fabric, pacer, traces, ladder)
docs/pinout.md         physical pins, bank map, host reservation, DE2 mapping
docs/programming.md    programmer guide: frames, registers, assembler, examples
docs/ai-development.md auditable account of the autonomous build
docs/flow.md           LibreLane / PDK commands and measured runtimes
research/              protocol timing, IHP constraints, prior art, ISA survey
tools/isa.py           opcode + encoding source of truth
tools/asm.py           assembler (labels, equates, side-set, per-engine images)
tools/model.py         cycle-accurate golden model (executable spec)
tools/tests/           pytest: encoding, model semantics, protocol decoders
firmware/              5 assembly programs (UART TX/RX, SPI, I2C, blink)
tb/                    Icarus benches: host, engine smoke, top, top-with-stub
test/                  official Tiny Tapeout cocotb gate (tb.v, Makefile, test.py)
sim/                   cocotb harness driving the real host SPI
formal/                SBY harness: engine properties, top properties, X-check bench
fpga/                  DE2 (Cyclone II) board build: host master, boot loader, demos
results/               synthesis area, Yosys logs, SBY output
scripts/               synth.sh, synth_full.sh, flow.sh, fetch_pdk.sh
```

---

## Reproduction

```sh
git clone <repo> && cd proteus
python3 -m venv .venv && .venv/bin/pip install -r tools/requirements.txt   # or: pip install pytest cocotb pyyaml

# 1. logic: 171 python tests + 4 Icarus benches (commands above)
.venv/bin/python -m pytest tools/tests -q

# 2. area (needs the IHP liberty)
make pdk-lite && make synth && make synth-design

# 3. GDS + 50 MHz timing (Docker; see docs/flow.md section 5 for runtime/disk)
make flow

# 4. FPGA demos (Icarus, no board needed)
iverilog -g2005 -I src -I fpga -o /tmp/fpga_tb fpga/tb_fpga.v src/proteus_defs.vh \
  src/proteus_engine.v src/proteus_host.v src/tt_um_proteus.v \
  fpga/tt_um_proteus_fpga.v fpga/host_master.v fpga/boot_loader.v && vvp /tmp/fpga_tb
```

Every number above is either quoted from the cited file or was produced by one
of these commands on 2026-11-02. Nothing here is estimated; where a measurement
does not exist, the command that produces it is given instead.

## Licence

Apache-2.0 (`LICENSE`).
