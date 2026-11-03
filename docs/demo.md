# PROTEUS demo - three minutes, no board required

Every step below is a command that runs on this tree and prints the line quoted
next to it. Nothing needs the ASIC, the DE2, Docker or the PDK.

The claim to demo: **three engines, loaded over SPI, generate UART, SPI, I2C and
a complete Ethernet frame - with five protocol-agnostic assists carrying the
byte streams - and the same chip can observe a bus while doing it.** Every code
block starts at the repository root.

---

## 0. The 15-second version

```
host SPI  ->  proteus_host  ->  register file / program RAM / assist CSR
                                 |
                                 +-> 3 engines (32 x 24 program RAM each)
                                 |     pin writes: uo / uio / oe / od
                                 +-> assist fabric (CSR 0x0600 + 0x10*id)
                                 |     CRC · FIFO · SHIFT · NRZI · MANCH
                                 +-> capture FIFO (4 x {ts[31:0], pin, level})
                                 +-> 4 barriers, 8 IRQ lines, 32-bit cycle counter
                                           |
                                     pin fabric merge -> pads
                                  engines 0..2, then assists, then host
```

No UART, SPI, I2C or Ethernet gate logic exists anywhere in `src/`. What exists
is a 24-bit instruction per engine per cycle, a deadline pacer, a pin fabric
with per-pin direction and open drain, and five protocol-agnostic data paths
selected by three opcodes. Show
[`figures/fig1_architecture.svg`](figures/fig1_architecture.svg).

---

## 1. Assemble a protocol and read the image (20 s)

```sh
python3 tools/asm.py firmware/uart_tx.asm --listing
```

Prints the 18-word image with source lines. The two lines that matter are
`PACERST` and the `PACE` in the bit loop: the entire baud rate lives in three
`CFG PERIOD*` immediates and a 24.8 fixed-point deadline.

**Say:** "434.02734 cycles per bit at 50 MHz, held as 111111/256. The fraction
is carried, so frame 1000 is as exact as frame 1."

Show [`figures/fig4_uart_frame.svg`](figures/fig4_uart_frame.svg) - the measured
frame, pacer ticks and the two-cycle tick-to-edge latency. The drift argument
behind it is [`figures/fig3_pacer.svg`](figures/fig3_pacer.svg).

Then show why the assists exist: the same Ethernet frame that cost v1 230 words
(`results/ethernet.md`) is 31 words here.

```sh
python3 tools/asm.py firmware/ethernet_mii_tx.asm --listing
```

---

## 2. Pass the official submission gate (30 s)

The Tiny Tapeout harness drives the pads only; it is the same test the GDS
action runs.

```sh
PATH=$PWD/.venv/bin:$PATH make -C test
```

```
identity ok (VERSION 0x02)
program loaded and verified over SPI (13 words)
engine 2 page ok; 0x0400 outside the 3-engine map
RUN retired by HALT
uio[0] toggled 6 times
register readback ok
** TESTS=1 PASS=1 FAIL=0 SKIP=0        147690.00    2.18 s **
```

That is identity `50 52 02`, a 13-word program loaded and read back word for
word over the real SPI port, engine 2's page `0x0300`, and `HALT` retiring the
engine's `RUN` bit.

---

## 3. Three protocols from three firmware images, on the RTL (40 s)

```sh
cd sim && make protocols
```

```
v2 map: 25 checks ok
UART TX pins: 18 checks ok
UART RX pins: 6 checks ok
SPI master pins: 123 checks ok
I2C master pins: 30 checks ok
Ethernet MII TX pins: 34 checks ok
** TESTS=6 PASS=6 FAIL=0 SKIP=0      9352290.01 ns   76.69 s **
```

Each test assembles `firmware/*.asm`, loads it over the host SPI, sets the
engine period registers, asserts `RUN`, and decodes the pads with a model
written from the protocol spec (`sim/test_protocols.py`: 16x-oversampling UART,
mode-0 SPI checker, 7-bit I2C target with clock stretching, MII PHY sampler).

**UART TX** (`firmware/uart_tx.asm`, engine 0, `UIO[0]`): five frames,
frame-start deltas 4343 cycles against an ideal 4340.27, measured bit period
434.03. **UART RX** (engine 1): nine source frames including a low stop bit;
the OUT_FIFO yields `55 00 ff 81 7e a5 5a 3c 00` byte-exact and
`E_ERROR[0] = 1`. **SPI** (`firmware/spi_master.asm`, engine 2): 16 SCK edges
inside CS, every half period exactly 25 cycles. **I2C** (engines 2+1, halves
swapped so the higher index wins the pin): START/RSTART/STOP, ACKs
`[0,0,0,0,0,1]`, bus bytes `5a a5` / `11 22`, one 400-cycle stretch.

Show [`figures/fig5_spi_i2c.svg`](figures/fig5_spi_i2c.svg) for the pad-level
shapes. The open-drain release and the collision comparator that make the I2C
side legal are [`figures/fig2_pin_fabric.svg`](figures/fig2_pin_fabric.svg),
which also shows the v2 merge order: engines, then assists, then host.

---

## 4. A complete Ethernet frame out of 31 instructions (30 s)

```sh
cd sim && make COCOTB_TEST_FILTER=proteus_ethernet_mii_tx_pins
```

```
MII run cycle 38134: 144 nibbles, 72 wire bytes, TX_CLK half period 500 cycles
MII wire: header 55 55 55 55 55 55 55 d5 | dst 02 00 00 00 00 01 |
          src 02 00 00 00 00 02 | type 08 00 | payload 46 bytes |
          FCS 32 7b c8 e7 (0xE7C87B32)
MII timing: setup min 498 / median 498 cycles, hold min 5 / median 502 cycles,
            TXD changes 105, high-phase violations 0
Ethernet MII TX pins: 34 checks ok
```

**Say:** "The host pushes the frame into the assist FIFO. The engine pops one
byte per iteration, folds it into the hardware CRC, and emits two nibbles on
side-set - so code size does not depend on frame length. The four FCS bytes are
recycled through the same loop. `0xE7C87B32` is `zlib.crc32` of the frame."

Two honest caveats to say out loud: the PHY model clocks TX_CLK slowly because
the host port cannot feed 10 Mbit/s (a 16-byte FIFO is the limit), and the FCS
proves content, not sustained line rate (`v2/results/v2_verify.md` §4, §7).

---

## 5. The same chip as an analyser (30 s)

**Hardware capture.** The unit watches `uio_in` and timestamps every edge to the
cycle. Register sequence used by the bench:

| write | register | value |
|---|---|---|
| `CAP_EN` | `0x0500` | `0x01` (watch `uio[0]`) |
| read | `0x0501` | count, overflow (`{3'b0, ovf, count[3:0]}`) |
| read | `0x0502..0x0505` | `cycle[31:0]` of the head event |
| read | `0x0506` | `{level, pin[3:0]}` |
| write | `0x0507` | pop one entry |

```sh
cd sim && make smoke
```

```
** test_protocols.proteus_v2_map   PASS      187260.00           1.05 **
** TESTS=1 PASS=1 FAIL=0 SKIP=0              187260.00           1.06 **
```

`make smoke` runs `proteus_v2_map` alone (identity, assist CSR bank, every
engine program page). The capture path is asserted in the directed bench:

```sh
bash tb/run.sh
```

```
csr            TB_CSR PASS (37 checks)
top_smoke      TB_TOP_SMOKE PASS (19 checks, 7 pad edges)
engine_smoke   ==== PASS: all engine smoke checks passed (237 checks) ====
top_e2e        top_e2e_tb PASSED

benches PASS=10 FAIL=0
```

**Firmware as an analyser.** `firmware/uart_rx.asm` (engine 1) samples an
external 8N1 line at the bit centres, checks the stop bit, and pushes decoded
bytes to the host FIFO - the `UART RX pins: 6 checks ok` line above, including a
deliberately broken framing-error frame.

**Learning the rate from the wire** (model-level demo):

```sh
python3 demos/run_demos.py --only autobaud
```

The engine measures the start bit with `WAITP` + `MEASLO/MEASHI`, publishes the
measurement, and the host writes it back into the pacer; 9600..250000 baud at 48
and 50 MHz decode 6/6, 6/6, 8/8, 8/8, 8/8, 8/8 bytes, plus a framing-error row.

---

## 6. Two engines as one converter: the barrier bridge (30 s)

```sh
python3 demos/run_demos.py --only bridge
```

```
bridge    48k/115200               uart=32 spi=32 short=0  32/32 bytes  PASS
bridge    48k/57600                uart=32 spi=32 short=0  32/32 bytes  PASS
```

Engine 0 receives UART, publishes the byte, raises IRQ 0 and arrives at `BAR 0`;
the host moves the byte; engine 1 arrives at `BAR 0` and clocks an SPI frame.
32 bytes identical at both ends, no short frames.

On the RTL the same barrier hardware is measured directly in `tb/top_e2e_tb.v`:

```
[5] BAR 0 across engines 0 and 1
    barrier pin cycles: uio0=62156 uio1=62156
```

The two engines arrive after a different number of instructions and still leave
the barrier in the **same cycle** - that is the primitive, not a firmware
handshake.

---

## 7. Thirty seconds of "try to break it" (30 s)

```sh
# every architectural field, every cycle, 209 programs against the golden model
cd sim && make diff
# -> 209 programs, 16,122 compared cycles, 0 mismatches, 9,737,490 ns

# would the benches notice a bug? 99 mutants, 95 killed
python3 tools/mutate.py --verify-mutations
python3 tools/mutate.py --all
# -> mutations: 99  KILLED=95  SURVIVED=4 ; kill rate 95/99 = 96.0%
```

`v2/results/v2_diff_formal.md` §1.4 documents the sensitivity check: mutating
`INC` in the model was caught at cycle 5996 of the first program
(`r6 model=0x2 rtl=0x1`), then reverted, so the pass is not vacuous. The
survivors are analysed in `v2/results/v2_mutation.md` §4 and all four are
equivalent mutants.

The verification ladder itself is
[`figures/fig6_verification.svg`](figures/fig6_verification.svg).

---

## What this demo does not claim

No routed GDS or gate-level simulation; no v2 FPGA build (the DE2 project targets
the v1 top and is archived at `legacy/v1/fpga/`); top-level formal T1-T7 and
X-freedom are v1-only, and T7 is open; Ethernet content is proven at a slowed
TX_CLK because the host port is the bandwidth limit; USB LS and 10BASE-T have
assists but no protocol demo. `docs/verification.md` §3 lists all of it.

---

## Appendix - figure provenance

The figures under `docs/figures/` are drawn from the measurements in the v2
reports, not from a rerun script in this tree:

| figure | drawn from |
|---|---|
| `fig1_architecture.svg` | `src/tt_um_proteus.v` (port list, merge order, 3 engines, assist bank), `src/proteus_defs.vh` (windows), `docs/architecture.md` §2-§6 |
| `fig2_pin_fabric.svg` | the fabric merge and collision blocks in `src/tt_um_proteus.v`; `docs/pinout.md` §2.1-2.2 |
| `fig3_pacer.svg` | the model probe printed by `demos/run_demos.py` (`pacer probe @cycle 2^24`) and `docs/isa.md` §3.1 |
| `fig4_uart_frame.svg` | `firmware/uart_tx.asm` plus the pad decode in `sim/test_protocols.py` (434.03 cycles/bit, 4343-cycle frame deltas) |
| `fig5_spi_i2c.svg` | the SPI and I2C counts in `sim/test_protocols.py` (25-cycle half phases, 400-cycle stretch) |
| `fig6_verification.svg` | the rows of `docs/verification.md` §2 and the reports in its §0 |

The earlier appendix in this file ran a Python provenance script from the v1
pytest tree; that tree is v1-only (`legacy/v1/tools/tests/`, including
`bench.py` and `protocols.py`) and the v2 root deliberately does not ship it, so
the script was removed rather than left as a command that cannot run.
