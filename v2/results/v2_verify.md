# v2 verification: Tiny Tapeout harness + protocol E2E on the hybrid RTL

Status: **both new gates PASS on the real RTL** (`iverilog 12`, cocotb 2.1.0,
`PROG_DEPTH = 32`).  They close the gap that until now only existed at model
level (`v2/demos/run_v2.py` == `v2/tools/model.py`) or at bench level
(`v2/tb/run.sh`, block and CSR benches).

Two new suites, 7 tests, 236 decoded checks, ~80 s wall:

| suite | command | result |
|---|---|---|
| TT harness (`v2/test`) | `make -C v2/test` | **PASS** (1 test, 2.15 s) |
| protocol E2E (`v2/sim`) | `make -C v2/sim` | **PASS 6/6**, 236 checks, 74.1 s |
| pre-existing benches | `bash v2/tb/run.sh` | **PASS=8 FAIL=0** (re-run after the fix below) |

One **defect in `v2/src` was found by the new harness and fixed** with an
explicitly approved one-line change (§5).  Nothing in v1 was touched.

---

## 1. Files added

All new; no v1 file modified, and no `v2/` file outside this list.

```
v2/test/Makefile          # 12 v2 sources, GATES=yes branch kept
v2/test/tb.v              # same top port list as test/tb.v
v2/test/test.py           # submission gate (identity/program/run/toggle/readback)
v2/test/requirements.txt  # pytest 8.4.2, cocotb 2.1.0
v2/sim/Makefile           # full v2 source list, venv-resolved cocotb
v2/sim/host.py            # v1 SPI driver + v2 assist-window helpers
v2/sim/test_protocols.py  # 6 tests: map, UART TX/RX, SPI, I2C, MII TX
v2/sim/.gitignore         # sim_build/, results_protocols.xml, __pycache__/
v2/test/.gitignore        # sim_build/, results.xml, tb.fst, __pycache__/
v2/results/v2_verify.md   # this report
```

The root `.gitignore` only anchors the v1 paths (`test/sim_build`,
`sim/sim_build`, `sim/results.xml`), which do not match `v2/...`; the two
one-line files above mirror that pattern inside this tree so the build
artifacts stay out of a future commit.

`v2/sim/host.py` is the v1 driver byte-for-byte plus the v2 constants
(`AS_BASE`, `as_reg()`, `pincfg()`, `PROG_DEPTH`/window ends, assist helpers), so
a v1/v2 result cannot differ for driver reasons.  `v2/sim/Makefile` resolves
`.venv` itself (the v1 `sim/Makefile` mechanism); `v2/test/Makefile` uses
`cocotb-config` from `PATH`, as the Tiny Tapeout flow does.

---

## 2. Exact commands and tails

### 2.1 TT harness

```sh
cd /home/ubuntu/verilog/v2/test
PATH=/home/ubuntu/verilog/.venv/bin:$PATH make
```

```
  6230.00ns INFO     cocotb.tb    identity ok (VERSION 0x02)
112830.00ns INFO     cocotb.tb    program loaded and verified over SPI (13 words)
127950.00ns INFO     cocotb.tb    engine 2 page ok; 0x0400 outside the 3-engine map
139230.00ns INFO     cocotb.tb    RUN retired by HALT
139230.00ns INFO     cocotb.tb    uio[0] toggled 6 times
142050.00ns INFO     cocotb.tb    register readback ok
147690.00ns INFO     cocotb.tb    halted, PC=12, uio[0] parked low
147690.00ns INFO     cocotb.tb    Test passed
** TESTS=1 PASS=1 FAIL=0 SKIP=0        147690.00    2.15 s **
```

Covered, over the pads only (so the same test runs on a netlist with
`GATES=yes`): identity `[0x50, 0x52, 0x02]`, `PING` = `0x50`, 13-word program
loaded and read back word for word over SPI, engine 2's program page
(`0x0300`) programmed and read back, `0x0400` proven outside the 3-engine map,
`RUN` retired by `HALT` (`RA_RUN = 0x00`), `E_STATUS.halted = 1`, `E_PC = 12`,
`r0 = 0x5A`, `uio[0]` toggled 6 times and parked low, `uio_oe[0] = 1`.

Note: the pad is sampled by a monitor started *before* the `RUN` write.  The
SPI frame that writes `RUN` costs ~280 clocks, and a program that ends in
`HALT` finishes most of its toggles while that frame is still on the wire — the
v1 test's "write RUN, then count 160 clocks" pattern only worked because the v1
program loops forever.

### 2.2 Protocol E2E

```sh
cd /home/ubuntu/verilog/v2/sim
make                      # COCOTB_TEST_MODULES=test_protocols
```

```
v2 map: 25 checks ok
map: PM window 0x0100..0x03FF, EW end 0x006F
UART TX pins: 18 checks ok
UART RX pins: 6 checks ok
SPI master pins: 123 checks ok
I2C master pins: 30 checks ok
Ethernet MII TX pins: 34 checks ok
** TESTS=6 PASS=6 FAIL=0 SKIP=0        9352290.01 ns    74.13 s **
```

One test can be re-run alone with
`make COCOTB_TEST_FILTER=proteus_ethernet_mii_tx_pins`.

---

## 3. Images and word counts

Counts come from the assembler (`v2/tools/asm.py`), not from comments:

| image | engines | words | limit | this run |
|---|---|---:|---:|---|
| `v2/firmware/uart_tx.asm` | 0 | 18 | 32 | PASS |
| `v2/firmware/uart_rx.asm` | 1 | 26 | 32 | PASS |
| `v2/firmware/spi_master.asm` | 2 | 32 | 32 | PASS (exactly full) |
| `v2/firmware/i2c_master.asm` | 2 + 1 | 32 + 32 | 32 each | PASS |
| `v2/firmware/ethernet_mii_tx.asm` | 0 | 31 | 32 | PASS |

Every image is loaded by the host and **read back word for word** before it
runs (`load_firmware_checked`); a program that cannot be loaded fails with the
page address in the message instead of timing out.

---

## 4. Decoded traffic (independent models, at the pads)

### UART TX — engine 0, UIO[0], 16x-oversampling 8N1 receiver

5 frames, bytes `00 ff 55 aa 41` (exact), every stop bit high.  Frame-start
deltas `[4343, 4343, 4343, 4343]` cycles against the ideal `10 * 434.02734 =
4340.27` (i.e. +2.7 cycles/frame, inside the +-6 gate and non-accumulating:
the pacer carries the fraction).  Start-bit width 434 cycles, stop-bit run
437 cycles, measured bit period 434.03.

### UART RX — engine 1, UIO[1], independent 8N1 source

Source frames at cycles `[23294, 31541, 37183, 42391, 48034, 53242, 58884,
64527, 71905]` with random 2..10-bit gaps, last frame with a **low stop bit**.
Engine 1's OUT_FIFO yielded `55 00 ff 81 7e a5 5a 3c 00` (byte-exact, error
byte still delivered), `E_ERROR[0] = 1`, no `WAITP` timeout, and the pad trace
confirms the error frame's stop slot is low at `t_err + 9.5 bit`.

### SPI master — engine 2, mode 0, UIO[2..5], inverting-loopback slave

6 transfers, `MOSI -> MISO` = `00->ff ff->00 5a->a5 a5->5a 81->7e 7e->81`,
16 SCK edges each (8 rising / 8 falling), CPOL=0 at CS assert, **every** SCK
half phase exactly 25 cycles (first one included — no stub phase), SCK period
50, CS setup and hold >= 25 cycles, no SCK edge while CS is high (inside a frame
or in the gaps), no mode-0/CS-framing violations.

### I2C master — engines 2 + 1, UIO[6]/UIO[7], open drain with pull-ups

Bus events `START` (53849) -> `RSTART` (70370) -> `STOP` (85594); ACKs
`[0,0,0,0,0,1]` (address, data, data, read-address, master ACK, master NACK);
write bytes at the pads `5a a5`; read bytes served `11 22`; one clock stretch of
exactly 400 cycles starting at 59577.  56 SCL high phases (min/median/max
252/252/503) and 56 low phases (252/253/1438 — the stretch), 54/56 highs and
47/56 lows exactly 250 cycles; every high >= 40 and every low >= 65 (fast-mode
`t_HIGH`/`t_LOW`); START/RSTART/STOP setup and hold all 252/251 cycles; no
open-drain collision; engine 2 and engine 1 timeouts and `E_ERROR` clear; four
ACK bytes in engine 2's OUT_FIFO and two read bytes in engine 1's.

This is the v2 remap in action: START/WRITE on engine **2** (higher index, wins
the pin merge), READ/STOP on engine **1**, with engine 2 parking side-set
(`CFG SIDE, 0`) while engine 1 owns SCL.

### Ethernet MII TX — engine 0 + CRC assist + FIFO assist

One complete 802.3 frame decoded at the pads by an MII PHY model that drives
TX_CLK and samples TX_EN/TXD on each rising edge.  144 nibbles = 72 wire bytes:

| region | decoded at the pads |
|---|---|
| preamble / SFD | `55 55 55 55 55 55 55` / `d5` (nibbles `[5,5]*7 + [5,D]`) |
| dst | `02 00 00 00 00 01` |
| src | `02 00 00 00 00 02` |
| ethertype | `08 00` |
| payload | `00 01 02 ... 2b 2c 2d` (46 bytes, byte-exact = 802.3 minimum) |
| FCS on the wire | `32 7b c8 e7` = `0xE7C87B32`, LSB first |
| `zlib.crc32(dst..payload)` | `0xE7C87B32` (independent model, same value) |
| `zlib.crc32(whole 68-byte host stream)` | matches the fold model |
| CRC init pre-image | `0x26B6A4C8`, `fold(pre, header) == 0xFFFFFFFF` (derived in-test) |

`0xE7C87B32` is byte-identical to the number `v2/results/v2_firmware.md` records
for the same frame at model level, so the RTL path and the model agree on the
vector.  The CRC assist's init/poly/xorout pages were also read back over the
host window (`26 b6 a4 c8`, `20 83 b8 ed`, `ff ff ff ff`).

Framing and timing at the pads: exactly 144 nibbles inside a single TX_EN-high,
TXD-driven window; TX_EN deasserts once, within one nibble of the last FCS nibble;
TX_EN was already high at the first nibble (raised by `JMP prep`, i.e. before the
first `OUTP`); TXD never changed while TX_CLK was high and the frame was
asserted (0 violations over 105 TXD changes); setup min/median 498/498 cycles,
hold min/median 5/502 cycles — the 5-cycle minimum is the frame end (the IFG
`CLRP`, in the same edge that deasserts TX_EN); a short hold *inside* the frame
would have been a discipline violation, and there are none; inter-frame gap >= the programmed 480 cycles;
engine 0 halted with `RUN` retired, no `WAITP` timeout, no `ASSERT`; the host
pushed exactly `r2 = 68` bytes and the assist FIFO level reached 16 (it carried
the stream, never aborted).

**Wire rate caveat (same limit the model report documents).**  The real host
port cannot sustain 10 Mbit/s: one wire byte every 40 clk needs a host byte
every 0.8 us, while the cleanest SPI frame costs ~280 clk = 5.6 us.  The PHY
model therefore clocks TX_CLK with a 500-cycle half period (1000-cycle nibble
slot, ~25 kbit/s equivalent).  What this gate proves is the *content and the
pad-level protocol* — bytes, FCS, TX_EN window, TXD-vs-TX_CLK discipline,
setup/hold.  The 10 Mbit/s rate and the host-throughput arithmetic remain
model-only (§7).

**Boot artifact (observed, not a defect).**  The pads reset with every output
disabled, so a PHY sees `TX_EN` high (pull-up) until the engine's first
side-set write drives it low.  The MII model picks the longest TX_EN-high run
rather than "first to last", and only counts nibbles with TXD0..3 actually
driven, so the pad idle before the frame cannot be mistaken for frame data.

---

## 5. Defect found in `v2/src` (fixed with approval)

**D1 — the host program window ended one page early, so engine 2's program was
unreachable.**

```verilog
v2/src/proteus_defs.vh:   `define PROTEUS_PM_END 16'h02FF   // wrong for 3 engines
v2/src/tt_um_proteus.v:   pm_sel   = reg_we && addr >= 0x0100 && addr <= PM_END
                          (the read mux uses the same bound)
```

Program pages are `0x0100 + 0x100*e` for e < 3, i.e. `0x0100`, `0x0200`,
`0x0300..0x03FF`.  `0x02FF` is `0x0100 + 0x100*2 - 1` — the count that fits two
engines.  `PROTEUS_EW_END` (`0x006F`) and `PROTEUS_AS_END` (`0x064F`) are both
correct, so this was a single wrong constant, not a decode redesign.

Evidence, over the real SPI host, DUT = `tt_um_proteus`:

```
engine 0 page 0x0100 -> write 11 22 33, read back [17, 34, 51]   OK
engine 1 page 0x0200 -> write 11 22 33, read back [17, 34, 51]   OK
engine 2 page 0x0300 -> write 11 22 33, read back [0, 0, 0]      BROKEN
0x0304 / 0x03FC      -> writes dropped, reads 0x00               BROKEN
```

Why no existing gate saw it: `v2/tools/model.py` has no address map at all
(`load_program(engine, words)` is an API), so `v2/demos/run_v2.py` cannot observe
the host window; `v2/tb/tb_csr.v` and `v2/tb/tb_top_smoke.v` only ever load
engine 0.  Impact had it shipped: `spi_master.asm` (engine 2) and the
START/WRITE half of `i2c_master.asm` (engine 2) could never be loaded on
silicon, i.e. two of the five demo images would be dead while the model suite
stayed green.

**Fix (approved by the orchestrator, one constant, no other change):**

```diff
-`define PROTEUS_PM_END        16'h02FF   // v1: 0x04FF
+`define PROTEUS_PM_END        16'h03FF   // 0x0100 + 0x100*3 - 1 (v1: 0x04FF)
+                                          // (was 0x02FF: engine 2's page
+                                          //  0x0300..0x03FF was unreachable)
```

After the fix: harness PASS, protocol suite 6/6, benches still 8/8.
No area/functional change beyond the compare bound.

**Regression, in the protocol suite so it runs every time**
(`proteus_v2_map`, 25 checks): write `11 22 33` at `0x0100`, `0x0200`, `0x0300`
and assert the readback for all three; engine 2's last programmable word at
`0x037C`; `0x03FC` (inside the page, past `PROG_DEPTH`) must read 0 and must not
alias engine 2 word 0; `0x0400` (the v1 engine-3 page) must read 0 and must not
alias engine 2 word 0; `PM_END == 0x03FF`, `EW_END == 0x006F`.

---

## 6. Parity against the v1 gates

| v1 gate | what it proves | v2 equivalent | status |
|---|---|---|---|
| `test/test.py` + `test/Makefile` + `test/tb.v` | submission harness: identity, program load, run, pads, on pins only (GATES-capable) | `v2/test/{Makefile,tb.v,test.py}`, 12 v2 sources | **added, PASS** |
| `sim/test_protocols.py` (4 tests, evidence in `results/protocol_rtl.md`) | UART TX/RX, SPI, I2C firmware on the RTL, decoded at the pads | `v2/sim/test_protocols.py` (I2C remapped to 2+1, `RUN` masks 3-bit) | **ported, PASS** (4/4) |
| — (v1 Ethernet was model-only: `results/ethernet.md`) | — | `proteus_ethernet_mii_tx_pins`: full 64-byte frame + FCS from the FIFO/CRC assists | **new, PASS** |
| `sim/test_smoke.py` | full-chip host register/SPI smoke | `proteus_v2_map` (identity, assist CSR bank, window edges, all program pages) + the harness | **covered** |
| `tb/top_e2e_tb.v` (36 kB) | top-level engine/FIFO/IRQ/bar/capture behaviour | `v2/tb/tb_csr.v` (37 checks) + `tb_top_smoke.v` (19 checks) + the protocol suite | covered for engines 0..2 and the assist bank |
| `tb/host_tb.v` | SPI host synchroniser/handshake bench | no dedicated v2 bench; every v2 test drives the real host at clk/8 (`tb_csr`, harness, protocol suite) | **partial** (no directed host bench) |
| `tb/engine_smoke_tb.v`, `tb/top_stub_tb.v`, `tb/top_capdepth_tb.v`, `tb/top_depth64_tb.v` | per-instruction engine smoke, stubs, `CAP_DEPTH`, `PROG_DEPTH=64` builds | none in v2 | **NOT covered** |
| `sim/test_diff.py` (evidence in `results/diff_report.md`: 209 programs, 16,122 cycles, 0 mismatches) | RTL vs `tools/model.py` differential corpus | none in v2 | **NOT covered** (`v2/CUTOVER.md` item 3) |
| `formal/` (SBY: 12 engine + 6 top properties, evidence in `results/formal_report.md`) | engine/top invariants | none in v2 | **NOT covered** (`v2/CUTOVER.md` item 4) |
| `results/mutation.md` | mutation score of the v1 suite | not re-run | **NOT covered** |
| LibreLane flow, GDS, DRC/LVS/STA | physical sign-off | none in v2 | **NOT covered** (`v2/CUTOVER.md` items 1, 5) |
| `test/Makefile GATES=yes` | gate-level netlist run of the harness | branch kept in `v2/test/Makefile`; no v2 netlist exists | **not runnable yet** |

Read as: the *ISA core and protocol* gates now have v2 equivalents that run on
the RTL; the *differential, formal, mutation, remaining bench and physical*
gates do not.

---

## 7. Still model-only (explicitly not claimed here)

1. **MII bit rate and host throughput.**  The RTL frame is decoded at a slowed
   TX_CLK (§4); 10 Mbit/s needs a host byte every 0.8 us against a ~5.6 us
   host byte time.
2. **The MII under-run/abort path.**  A deliberate negative in
   `v2/results/v2_firmware.md` (host too slow -> two nibbles, TX_EN drops,
   IFG, HALT).  This feed never starves the queue, so the abort path is still
   model-only.
3. **SPI mode 3.**  Implemented in `spi_master.asm` and unchanged from v1; only
   mode 0 is exercised (v1 was the same).
4. **USB LS (NRZI) and 10BASE-T Manchester wire protocols.**  No firmware image
   exists; these assists are covered only by the unit benches `tb_nrzi`,
   `tb_nrzi_wave`, `tb_manchester`.  The CSR-side registers are covered by
   `tb_csr` and the map test.
5. **Assist FIFO -> CRC -> serializer chaining.**  The FIFO's autonomous drain
   port is tied to the pop strobe, so no hardware chaining exists yet
   (`v2/CUTOVER.md` phase-2 item).
6. **Capture FIFO, barrier and collision semantics** beyond the incidental
   `RA_COLLISION == 0` assertion in the I2C test: v1's `tb/top_e2e_tb.v` covered
   these and has no v2 counterpart.
7. Differential vs `v2/tools/model.py`, formal, mutation, LibreLane
   GDS/DRC/LVS/STA, gate-level simulation (§6).

---

## 8. Reproduction notes

* Toolchain: `iverilog 12.0`, cocotb **2.1.0**, Python 3.12.3, `.venv` at the
  repo root.  `v2/test` needs `.venv/bin` on `PATH` (or any `cocotb-config`);
  `v2/sim` finds the venv by relative path.
* `v2/test/requirements.txt` pins `cocotb==2.1.0` (v1 pins 2.0.1; the harness
  was verified against the installed 2.1.0 — the API used is the same).
* Total wall time: harness 2.2 s + protocol suite 74.1 s + benches 3.7 s
  (~80 s), inside the 15-minute budget.  The MII test dominates (~33 s).
* `v2/test/sim_build`, `v2/sim/sim_build`, `v2/sim/results_protocols.xml` and
  `v2/test/tb.fst` are build artefacts; all regenerable from the commands above.
