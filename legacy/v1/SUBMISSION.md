# PROTEUS submission audit

Status as of the last run on this host. Every claim below names the command or
file that produces it. Anything not listed here is either unverified or noted in
"Known gaps" at the end.

## What is submitted

| item | state |
|---|---|
| `info.yaml` | `tiles: "6x4"`, 50 MHz, `tt_um_proteus`, 4 sources, 24 pins |
| `src/` | 4 engines, 24-bit ISA, host SPI, pin fabric, capture, barriers, IRQ |
| `test/` + `.github/workflows/` | the Tiny Tapeout gate, adapted and passing |
| `docs/info.md` | project page (architecture, pinout, host protocol, demos, area) |
| `docs/architecture.md` | implementation contract |
| `docs/isa.md`, `docs/programming.md` | ISA and programmer guide |
| `docs/verification.md` | methodology, evidence, explicit gaps |
| `docs/ai-development.md` | auditable account of the autonomous process |
| `firmware/` | UART TX/RX, SPI master, I2C master (32+32 split), pin blink |
| `demos/` | autobaud, WS2812, barrier-synced UART↔SPI bridge |
| `fpga/` | Quartus II 13.0 DE2 project, self-hosting ROM loader, 4 demos |
| `tools/` | assembler, cycle-accurate model, differential generator |
| `results/` | measured evidence (area, formal, diff, protocol, flow) |

## Verification evidence

| gate | command | result |
|---|---|---|
| Toolchain + firmware | `.venv/bin/python -m pytest tools/tests -q` | **179 passed** |
| Engine bench | `iverilog -g2005 -I src -o /tmp/e tb/engine_smoke_tb.v src/proteus_engine.v && vvp /tmp/e` | PASS |
| Host SPI bench | `... tb/host_tb.v` | 28 checks, 0 errors |
| Top with stub | `... tb/top_stub_tb.v tb/stub_engine.v src/proteus_host.v src/tt_um_proteus.v` | 62 checks, 0 errors |
| Real-engine E2E | `iverilog -g2005 -I src -o /tmp/e2e tb/top_e2e_tb.v src/*.v && vvp /tmp/e2e` | **224 checks, 0 errors** |
| Depth-64 program port | `tb/top_depth64_tb.v` | 9 checks |
| Capture depth | `tb/top_capdepth_tb.v` | 13 checks |
| cocotb smoke | `cd sim && make` | 9 phases, 90 checks |
| **DUT vs model, every cycle** | `cd sim && make diff` | **209 programs, 16,122 cycles, 0 mismatches** |
| **Protocols on the real RTL** | `cd sim && make protocols` | **4/4**: UART TX 18, RX 6, SPI 123, I2C 30 checks |
| Official TT gate | `cd test && PATH=$PWD/../.venv/bin:$PATH make` | PASS |
| FPGA DE2 (RTL, 4 demos) | `iverilog -g2005 -I src -I fpga -o /tmp/f tb_fpga.v src/*.v fpga/*.v && vvp /tmp/f` | **36 checks, 0 errors** |
| Formal engine | `./formal/run.sh --engine-only` | E1-E11 PASS, E0 expected-fail control |
| Mutation testing | `python3 tools/mutate.py --all` | 57 mutants, **94.7% killed** after hardening (3 survivors explained) |
| Formal top | `./formal/run.sh --top-only` | T1-T6 PASS, T4 SPEC, T7 OPEN |
| X-freedom | `iverilog ... formal/xcheck_tb.v src/*.v && vvp` | **208 cycles, no X/Z** |
| Full-chip area | `scripts/synth_full.sh` | **581,139 um² / 42,049 cells** (64.4% row area) |
| Full-chip timed flow | `make flow` (`PL_TARGET_DENSITY_PCT=65`) | **pending** (detailed routing) |

## Design summary

* Four engines, 32 x 24-bit program RAM each, 8 x 8-bit registers, 8-bit ALU,
  4-deep byte FIFOs both directions.
* 24.8 fixed-point deadline pacer with a 32-bit integer deadline and explicit
  fractional carry: no drift, `period` may be fractional (100.5 cycles is legal).
* Per-instruction pin masks and 3-bit side-set; per-pin direction, open-drain
  release and sticky collision detection.
* 32-bit free-running timebase; 4-deep edge-timestamp capture FIFO; software
  `CAPTURE` events; `MEAS` pulse-width measurement.
* Four hardware barriers (same-cycle release) and eight IRQ lines.
* Host SPI mode 0 with a 16-bit pointer, auto-increment bursts, and a documented
  one-byte-per-frame rule for FIFO ports.

## Hybrid v2 (in progress, isolated under `v2/`)

The 4-engine design does not route at 64.4% row utilisation (two DRT attempts
failed to converge). A measured hybrid alternative is being built without
touching v1:

| item | value |
|---|---|
| engines | 3 |
| assists | CRC (bit-serial), 16x8 FIFO, shift32, NRZI enc/dec, Manchester enc/dec |
| new opcodes | `LDAS` 0x4E, `STAS` 0x4F, `ASST` 0x50 (CSR access, 1 instruction/byte) |
| measured area | **497,927 um2 flat / 33,936 cells = 55.18% of row area** (hierarchical 539,039 = 59.7%), 91.96% of the 60% budget with +43.5k margin |
| RTL state | 8/8 v2 benches pass, CSR 37 checks, top smoke 19 checks, verilator `-Wall` clean, `selfcheck.py` pass |
| remaining | differential/formal/flow parity; 64-byte frame buffer to remove the host-bandwidth limit on sustained Ethernet |
| firmware | ported to 3 engines: UART TX 18, UART RX 26, SPI 32, I2C 32+32 (engines 2+1, halves swapped), **Ethernet MII full frame 31 words** with CRC+FIFO assists; `v2/demos/run_v2.py` **115 checks, 0 FAIL**, FCS `0xE7C87B32` = `zlib.crc32`, 144/144 nibbles |
| RTL verification | `v2/test` TT harness PASS (identity `50 52 02`, 3-engine program pages, RUN retired by HALT); `v2/sim` **6 tests / 236 checks** (v2 map 25, UART TX 18, RX 6, SPI 123, I2C 30, MII TX 34) decoded at the pads. Defect found and fixed: `PROTEUS_PM_END` was 0x02FF (engine 2 page unreachable), now 0x03FF with a regression |

Adoption rule: v2 replaces v1 only after it passes the same protocol,
differential, formal and physical gates. Until then v1 is the submission.

## Known gaps (not overclaimed)

1. **Physical sign-off.** Timing looks healthy (post-global-route setup
   **+11.02 ns / hold +0.29 ns** on a 20 ns clock for v2; +10.64/+0.27 for v1),
   but **no local routed GDS exists**. Six LibreLane 6x4 attempts stalled in
   OpenROAD detailed routing with an identical silent signature (4 threads or 1,
   64.4% or 55.2% logic area, 0-byte log, empty `drt-run-0`, no DRC report),
   while the 1x1 smoke flow completes. The image ships one OpenROAD binary and
   LibreLane exposes no override, so this is an aarch64 runtime block, not a
   density verdict. The authoritative gate is the repository's GitHub
   `gds.yaml` action on x86_64; `results/flow_report.md` records every attempt.
   No GDS, DRC, LVS or GLS claim is made until that action runs.
2. **Gate-level simulation** needs the hardened netlist.
3. Formal T7 (HALT retires RUN at the top) is OPEN; its antecedent needs more
   than 70 SPI clocks at the affordable bound. T1/T2/T5/T6 covers are unreached
   at depth 20.
4. **No silicon.** The shuttle is March 2027. The DE2 build is simulated, not
   yet programmed onto a board.
5. Autobaud, WS2812, the bridge, Ethernet and JTAG are model-verified;
   UART/SPI/I2C are also RTL-verified. Ethernet is a **partial** result: MII
   nibble TX and the CRC-32 engine both fit (32+32 words) and the FCS matches
   `zlib.crc32`, but a legal 802.3 frame exceeds the 32-word budget; see
   `results/ethernet.md`. JTAG is **partial**: IDCODE and 12/12 required TAP
   states, but BYPASS/Pause/Exit2 need a 64-deep build; see
   `results/stretch.md`.

## Reproduce from scratch

```sh
python3 -m venv .venv && .venv/bin/pip install cocotb pytest pyyaml
make pdk-lite && make synth          # area without the full PDK
.venv/bin/python -m pytest tools/tests -q
cd sim && make && make diff && make protocols
cd ../test && PATH=$PWD/../.venv/bin:$PATH make
python3 demos/run_demos.py
./formal/run.sh --engine-only
```
