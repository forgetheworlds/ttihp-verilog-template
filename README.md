# PROTEUS

A programmable protocol engine on 24 pins.

PROTEUS is a Tiny Tapeout ASIC for the IHP SG13CMOS5L process. Three identical
24-bit micro-engines and five protocol-agnostic assists sit behind 24 pads with
per-pin direction and open-drain control. The chip carries a 32-bit cycle
timebase with deadline pacing, four hardware barriers, eight IRQ lines and a
four-entry edge-capture FIFO. Nothing about a protocol is committed to gates.
The host writes program RAM over SPI, and the same silicon speaks UART, SPI,
I2C or Ethernet MII depending on what was written into it.

That is the point of building it as an ASIC rather than bit-banging an MCU. An
MCU can produce a UART frame. Doing three protocols at once while holding their
edges to a shared cycle timebase, with no interrupt latency in the path, is
where bit-banging stops being a firmware problem. A fixed UART/SPI/I2C block
cannot do it either, because in that design the protocol set is the layout.
PROTEUS is the smallest processor that makes the pins programmable, plus five
blocks for the work a 32-word program should not be spending instructions on.

The functional evidence is strong and the physical evidence is incomplete, and
both are in this README. The RTL, testbenches, firmware, formal harness,
mutation catalogue and most of the flow debugging were produced by an AI coding
agent with me directing. **No silicon exists yet.** An 8x4 hardened GDS passes
DRC, LVS and antenna; timing sign-off is pending a rerun.

<p align="center">
  <img src="docs/assets/arch.svg" width="900" alt="PROTEUS block diagram: host SPI into proteus_host, a register bus into three 24-bit engines and a five-block assist fabric, then a pin merge and 24 pads. Opcode arrows show LDAS, STAS and ASST; the host CSR window is 0x0600 plus 0x10 times the assist id.">
  <br>
  <em>Host SPI is the only fixed interface. Protocols are program RAM, and pin ownership is host &gt; assist &gt; engine.</em>
</p>

## Why this exists

I started with four engines, a conventional instruction set and one firmware
image per protocol. v1 did UART, SPI and I2C; it did not do Ethernet, because
one complete 802.3 frame measured 230 words against a 32-word engine. The
problem was not the engine count. Byte-serial work was competing with control
flow for the same instruction slots.

The fix had two parts. Timing moved into hardware and the decisions stayed in
firmware: an engine waits on a pin without spending instructions, the pacer
carries the fractional remainder instead of rounding it, and the capture unit
timestamps edges to the cycle, which makes the chip usable as an instrument and
not only as a driver. Byte-serial work moved out of the instruction stream into
the assist fabric, reached by three opcodes. The same Ethernet frame now fits in
31 words.

## How I approach it

**Three engines, because waiting is not work.**
Each engine has 32 x 24 program RAM, an 8-bit ALU with `Z`/`C`/`N`, 4-deep
in/out FIFOs, a 24.8 deadline pacer, side-set, barriers, IRQ and a port to the
assist bank. UART TX, UART RX and SPI run side by side; an engine blocked in
`WAITP` or `IRQWAIT` does not stall the others. Four barriers and eight IRQ
lines are the only coupling.

**Five assists, because instruction slots are the scarce resource.**
The set is CRC-32, a 16 x 8 byte FIFO, a 32-bit shift register, NRZI enc/dec
and Manchester enc/dec. It costs 59,854.90 um2; the fourth engine it replaced
cost 132,381.80 um2. Three opcodes reach it (`LDAS` 0x4E, `STAS` 0x4F, `ASST`
0x50) and the host sees a window at `0x0600 + 0x10*id`. The assists are
deliberately not protocol blocks: they are the primitives a protocol needs,
which is why one set is enough for an Ethernet frame, a 10BASE-T line code and
a USB low-speed line code.

**One fixed interface, and then it gets out of the way.**
The host is an SPI master: mode 0, MSB first, `SCK <= clk/8`, ten commands
(`00..09`) and a 16-bit address pointer. It writes program RAM and registers,
reads them back, and issues `HOST_DISABLE` (`0x09`) to return `ui[0:2]` and
`uo[0:1]` to the fabric. Pin ownership is host register write > assist
`PINCFG.en` > engine 2 > engine 1 > engine 0, and every `PINCFG` register
resets to zero, so an unprogrammed chip behaves exactly as a three-engine
fabric with no assists attached.

**The model is the specification.**
`tools/model.py` is a cycle-accurate executable reference; the RTL is written
to match it. The differential then compares every architectural register, pin,
FIFO entry and capture event on every cycle, so agreement is not sampled. The
obvious weakness is stated rather than hidden: a wrong model makes both sides
wrong in the same way. The independent protocol decoders at the pads and the
mutation score are the cross-check.

**Tools the agent uses.**
The repository ships the working tools, not only the design. `python -m proteus`
exposes the ISA table, the assembler, the cycle model, a machine-readable spec
(`proteus spec --json`), a mutation-based benchmark generator for RTL-debugging
agents (`proteus bench`), and an evidence dashboard (`proteus status`) that
parses the recorded gates instead of restating them. The design was built with
these tools in the loop, and they are kept because a reviewer can rerun each
claim with the same entry point. Details in [docs/tools.md](docs/tools.md).

**Verification as a ladder, not a test suite.**
Each layer answers a different question. Model demos catch protocol mistakes;
cocotb at the pads catches integration; the differential catches semantic
drift; formal catches invariants a bench never reaches; mutation measures
whether the benches would notice a bug; synthesis and hardening catch the
things no simulation can. The defect with the widest blast radius was found by
the v2 host-interface suite: it loaded firmware into engine 2 and read back
zeros, because the program window ended at the two-engine address. Details in
[docs/showcase/verification.md](docs/showcase/verification.md).

**An agent did the work; I made the calls.**
The build was one orchestrating agent plus specialist agents on disjoint file
sets, with decisions written into the files they affect instead of into a chat
log. The rule that made it reviewable was simple: every number names the log or
command that produced it. My calls were the target, the cutover bar, the
one-constant fix for the address-map defect and the move from 6x4 to 8x4. The
account, including what was reverted, is in
[docs/showcase/agent-workflow.md](docs/showcase/agent-workflow.md).

**What did not work.**
6x4 does not route. Metal3 is the only horizontal layer in the stack this flow
configures, and the design asks for 114.45 % of the derated supply. With
`GRT_ADJUSTMENT 0.2` the global figure falls to 94.43 %, but 10,404 local
overflow edges remain and detailed routing never converges. My first
explanation, an aarch64 runtime block, was wrong; six silent attempts at two
placement densities looked like a tool problem until the global-route
congestion report was read. The design moved to 8x4, which routes and passes
DRC, LVS and antenna. Its timing checkers then failed because the resizer
margins had been zeroed for the 6x4 experiments and followed the design; the
margins are restored and the rerun is pending. The full investigation is in
[docs/showcase/flow.md](docs/showcase/flow.md).

## What worked

The differential is the strongest single result: 209 programs, 16,122 compared
cycles, zero mismatches, no program cut at the cycle cap. The protocol layer is
the one that proves the pads: six tests, 236 checks, including a complete
Ethernet MII frame decoded by a model that shares no code with the firmware.
The formal suite covers the engine invariants, and mutation says the benches
would notice a plausible bug 95 times out of 99, with the four survivors argued
equivalent.

Two defects that review did not catch are worth naming. The engine-2 program
page was unreachable because `PROTEUS_PM_END` still held the two-engine value
`0x02FF`; the fix is one constant (`0x03FF`) and a 25-check regression that
proves the neighbouring page does not alias. Separately, the recorded v2 area
of 497,927 um2 / 55.18 % did not reproduce on the same sources and library; the
sign-off number is **519,233.80 um2 / 36,343 cells / 57.54 %**, and the old
figure is kept in the record as superseded. Both are written up in
[docs/showcase/verification.md](docs/showcase/verification.md).

| gate | result |
|---|---|
| Toolchain self-check | **PASS**: assist opcodes round-trip, five CRC vectors, model FIFO/`nf` |
| Tiny Tapeout harness | **PASS**: `VERSION 0x02`, 13-word program over SPI, engine-2 page, `HALT` retires `RUN` |
| cocotb protocols on the RTL | **PASS 6/6, 236 checks**: UART TX/RX, SPI, I2C, Ethernet MII |
| Directed RTL benches | **10/10**, 693 recorded checks (`tb_csr` 37, `tb_top_smoke` 19, `engine_smoke` 237, `top_e2e` 400) |
| Cycle-exact differential | **PASS**: 209 programs, 16,122 cycles, 0 mismatches |
| Engine formal (SBY) | **E1-E8, E10, E11 PASS**, E0 expected-fail control, E9 cover 4/5 |
| Mutation | **95/99 killed = 96.0 %**, four survivors shown equivalent |
| Model-level demos | **11/11 PASS** |
| Synthesis (Yosys flat) | **519,233.80 um2**, 36,343 cells, 57.54 % of 902,417 um2 rows (hierarchical 538,016.13 = 59.62 %) |
| LibreLane 8x4 | DRC **PASS**, LVS **PASS**, antenna **PASS**, views saved; setup and hold checkers **FAIL**, rerun pending |

<p align="center">
  <img src="docs/assets/ladder.svg" width="430" alt="Eight verification layers from golden model to LibreLane GDS, with measured counts: 11/11 demos, 6 tests and 236 checks, 10 benches and 693 checks, 209 programs and 16,122 cycles, formal E1-E8/E10/E11 with E9 4/5, 95/99 mutants killed, 519,233.80 square microns and 57.54 percent, and a routed 8x4 GDS with DRC/LVS/antenna pass and timing open.">
  <img src="docs/assets/flow.svg" width="430" alt="Left: 6x4 Metal3 demand of 114.45 percent of the derated supply, and 94.43 percent with GRT_ADJUSTMENT 0.2 while 10,404 local overflow edges remain. Right: the 8x4 flow completes detailed route, DRC, LVS and antenna, but setup and hold fail because resizer margins had been zeroed for 6x4; the rerun is pending.">
  <br>
  <em>Left: the verification ladder and its counts. Right: why 6x4 stopped and where 8x4 stands.</em>
</p>

## Quick start

Needs Python 3.12, Icarus Verilog and Yosys. The formal suite also needs
SymbiYosys and z3; the physical flow needs Docker and the PDK.

```sh
python3 -m venv .venv && .venv/bin/pip install pytest cocotb pyyaml

python3 tools/selfcheck.py                  # toolchain and opcode round-trip
python -m proteus status                    # every gate, from the recorded evidence
python -m proteus spec --json | head        # machine-readable ISA and register spec
python -m pytest tests -q                   # 91 tests for the toolkit itself
PATH=$PWD/.venv/bin:$PATH make -C test      # official Tiny Tapeout gate
make -C sim                                 # protocols on the real RTL
make -C sim diff                            # RTL vs model, every cycle
bash tb/run.sh                              # directed benches
python3 demos/run_demos.py                  # model-level demos
./formal/run.sh                             # engine formal, E0..E11
python3 tools/mutate.py --all               # mutation score

scripts/fetch_pdk.sh --liberty-only && scripts/synth_full.sh   # area
scripts/fetch_pdk.sh && scripts/flow.sh                        # LibreLane
```

Every count in the table above has its command and its output in
[docs/verification.md](docs/verification.md) §2, with the artifact behind it.
The hardware flow and its current state are in
[docs/showcase/flow.md](docs/showcase/flow.md).

## Layout

| Path | What |
|---|---|
| `src/` | 12 RTL files: definitions, engine, host SPI, top, five assists |
| `tools/` | ISA table, assembler, cycle model, differential generator, mutation catalogue |
| `proteus/` | `python -m proteus`: ISA, assembler, model runner, spec, benchmark generator, evidence status |
| `tests/` | pytest suite for the toolkit (91 tests) |
| `firmware/` | UART TX/RX, SPI, I2C, Ethernet MII, pin blink |
| `sim/` | cocotb protocol tests and the RTL-vs-model differential |
| `test/` | the official Tiny Tapeout cocotb gate, pads only |
| `tb/` | 10 directed Icarus benches |
| `formal/` | SymbiYosys engine harness, E0-E11 |
| `docs/` | architecture, ISA, pinout, programming, verification, flow |
| `docs/assets/` | the three figures used in this README |
| `docs/showcase/` | verification, agent workflow and physical-flow investigations |
| `v2/results/` | the v2 evidence snapshot: protocol, differential, formal, mutation |
| `results/` | measured logs: synthesis, area, flow, formal |
| `legacy/v1/` | the previous four-engine build, frozen and unmodified |
| `scripts/` | PDK fetch, synthesis, LibreLane hardening |

Design detail: [docs/architecture.md](docs/architecture.md) for the register
map and merge rules, [docs/isa.md](docs/isa.md) for the 75-opcode encoding,
[docs/programming.md](docs/programming.md) for the host frames and assist CSR,
[docs/pinout.md](docs/pinout.md) for the pad map and ownership.

## Target and hardware

Tiny Tapeout, IHP SG13CMOS5L, 8x4 tiles (32 tiles). The clock target is 50 MHz.
There are 24 user pads: `ui_in[7:0]`, `uo_out[7:0]` and `uio[7:0]` with
per-pin output-enable and open-drain control. I/O is 3.3 V only, with no 5 V
tolerance, no internal pull-ups and 30 mA pad drive, so open-drain use needs
external pull-ups. The host is any SPI master; an MCU or an FPGA is enough.

There is no board and no silicon. The 8x4 GDS exists and passes DRC, LVS and
antenna, but timing sign-off is awaiting a rerun with the resizer margins
restored, and gate-level simulation has not been run. The 8x4 tile choice costs
die area; 6x4 would have been cheaper and does not route. That is the physical
state.

## Licence

Apache-2.0 (`LICENSE`). Contributions are under the same licence; see
[CONTRIBUTING.md](CONTRIBUTING.md).
