# PROTEUS demos

Three demos, each assembled with `tools/asm.py`, executed on the cycle-accurate
reference model `tools/model.py`, and decoded by an independent pin-level model
(16x-oversampling UART receiver, pulse-width WS2812 decoder, SPI mode-0
checker). Nothing is asserted without a run:

```
python3 demos/run_demos.py            # or: .venv/bin/python demos/run_demos.py
python3 demos/run_demos.py --update   # rewrite demos/expected/*.txt
python3 demos/run_demos.py --only ws2812
```

The script exits non-zero if a check fails or a baseline in `demos/expected/`
differs, so it is usable as a regression gate in CI.

```
python3 demos/run_demos.py --fifo-depth 4    # the depth-4 area-cut build
```

Every demo is independent of FIFO depth >= 4 and this is verified, not assumed:
the autobaud receiver holds at most 2 pending measurement bytes plus its
publisher, the WS2812 driver holds exactly 3 bytes per pixel, and the bridge
moves one byte per barrier rendezvous with the host checking `IN_FULL`. With
`--fifo-depth 4` the whole suite still passes (11/11 rows).

| demo | file | engines | instructions |
|---|---|---|---|
| autobaud UART receiver | `autobaud_uart_rx.asm` | 0 | **32 / 32** |
| WS2812 driver, 48 MHz | `ws2812.asm` | 1 | 18 / 32 |
| WS2812 driver, 50 MHz | `ws2812_50mhz.asm` | 1 | 18 / 32 |
| UART -> SPI bridge | `uart_spi_bridge.asm` | 0 + 1 | 21 + 19 |

The v1 Ethernet and JTAG entry points (`run_eth.py`, `run_stretch.py`) are
archived at `legacy/v1/demos/` with the rest of v1: they target v1 firmware
images that the 3-engine tree does not ship (`firmware/ethernet_mii_tx.asm` as
a 32+32-word emitter + FCS pair on engines 0+1, and `firmware/jtag_tap.asm`).
The v2 Ethernet image is a single 31-word assist-based emitter, gated on the RTL
by `sim/test_protocols.py` (`proteus_ethernet_mii_tx_pins`).

Two clock constants are used, both defined once in `demos/run_demos.py`:

* `CLK_HZ_48 = 48_000_000` — the vendor reference clock used for the timing
  tables in the firmware headers and for the headline demo numbers.
* `CLK_HZ_50 = 50_000_000` — the sign-off clock (`info.yaml`), at which every
  demo that can be retimed is also run.

No baud rate, divider or period is baked into the UART firmware in either case:
periods always come from the host-written pacer register (or, in the autobaud
demo, from the measurement itself), so the same words run at 48 and at 50 MHz.

## Pin map

| demo | pad | direction | function |
|---|---|---|---|
| autobaud | UIO[1] | input | RX, 8N1, idle high |
| ws2812 | UIO[2] | output (side-set) | DATA to the first pixel |
| bridge | UIO[1] | input | RX, 8N1, idle high |
| bridge | UIO[3] | output (side-set) | SCK, mode 0, idle low |
| bridge | UIO[4] | output (BITPIN `OUTBIT`) | MOSI |
| bridge | UIO[5] | output | CS_N, active low |
| ethernet | UIO[0] | **input** (PHY drives it) | TX_CLK, 2.5 MHz, 20 cycles/nibble |
| ethernet | UIO[1] | output (side-set) | TX_EN |
| ethernet | UIO[2..5] | output (`OUTP UIO,0x3C`) | TXD0..TXD3 |

`ui_in`, `uo_out` and the host SPI pins (`ui_in[2:0]`, `uo_out[0]`) are
untouched: the demos run after `HOST_DISABLE` on the fabric pins only. Engine 2
stays halted, so `BAR 0` waits only for engines 0 and 1.

The demos never write a pad they also read (RX), so no auto-OE/collision can
occur; the harness resolves `uio_in` as the wired-OR of chip drivers, the
external device and the pull-ups, which is what a board does.

The `ethernet` rows above are the v1 pad map kept for reference; that demo's
runner is archived at `legacy/v1/demos/` (section 4).

## Host register contract

The demos use only registers from `docs/architecture.md` §6.

| register | demo | meaning |
|---|---|---|
| `0x0010+0x20*e +0x10` IN_FIFO | ws2812 (e1) | pixel bytes G, R, B, MSB first |
| | bridge (e1) | one byte per SPI frame |
| `+0x11` OUT_FIFO | autobaud (e0) | lock: `d_lo`, `d_hi`; then one byte per frame |
| | bridge (e0) | one byte per received frame |
| `+0x0C..+0x0F` period | all | 24.8 fixed-point pacing period (see below) |
| `+0x00` E_STATUS | all | `[0]` run, `[2]` in_empty, `[4]` out_empty |
| `+0x03` E_ERROR | autobaud, bridge | sticky: framing error / rejected measurement |
| IRQ 0 | autobaud, bridge | "measurement ready" / "UART byte ready" |
| IRQ 1 | bridge | "SPI frame done" |

Period values written by the host (24.8 fixed point, `int << 8 | frac`):

| demo | period | why |
|---|---|---|
| autobaud | `T * 128` where `T = d - 3` | half a bit; exact for every integer `T` |
| ws2812 @48 MHz | `60 << 8` | 1.25 us bit cell = 60 cycles |
| ws2812 @50 MHz | `16000` = 62.5 in 24.8 | 1.25 us = 62.5 cycles (fractional, carried) |
| bridge e0 | `T/2 * 256` | half a UART bit, from the host's known baud |
| bridge e1 | `6 << 8` | half an SCK period = 6 cycles -> SCK 4 MHz |

`demos/run_demos.py` implements exactly this contract and nothing else; the
harness hook is 6 lines per demo.

## 1. Autobaud UART receiver (headline demo)

**Learns the bit period from the wire.** The host is never told a baud rate; it
forwards the measurement into the pacer and raises IRQ 0.

Flow (32 words, `demos/autobaud_uart_rx.asm`): `WAITP` for the start edge
(records `ts_event`) -> a 2-cycle `INPR`/`JZ` poll until the line rises ->
`MEASLO`/`MEASHI` measure `d` -> `PUSH` `d` to the host -> range check
(`JNC bad` above `0x13ff`) -> `IRQWAIT 0` for the programmed period ->
`PACERST` + 3 `PACE` primes -> 8x (`PACE`, `INPR`, shift/OR) -> `PACE`,
`INPR` for the stop bit -> `PUSH` the byte, `ASSERT` the stop level (framing
flag) -> `WAITP` high and re-arm, with no re-lock.

Measured (48 MHz, run output in `demos/expected/autobaud_uart_rx.txt`):

| baud | true T (cycles) | `d` | T used by the pacer | period (24.8) | bytes |
|---|---|---|---|---|---|
| 9600 | 5000.000 | 5003 | 5000 | 640000 | 6/6 |
| 19200 | 2500.000 | 2503 | 2500 | 320000 | 6/6 |
| 57600 | 833.333 | 835 | 832 | 106496 | 8/8 |
| 115200 | 416.667 | 419 | 416 | 53248 | 8/8 |
| 250000 | 192.000 | 195 | 192 | 24576 | 8/8 |
| 115200 @50 MHz | 434.028 | 437 | 434 | 55552 | 8/8 |

Payload per baud: `00 ff 55 aa 01 80 3c 7f` (the two framing extremes and a
random tail); one 0xFF training frame precedes it. The framing test sends a
break (all-zero data, stop bit low, then 2.5 idle frames): the byte is still
published, `E_ERROR` is set, and the next frame decodes correctly.

Sampling geometry (A = `PACERST` cycle = start edge + 1, H = T/2):
`PACE #1..#3` complete at `A`, `A+H`, `A+2H`; the loop's `PACE` completes at
`A+(3+2k)H` and the `INPR` one cycle later, so d0 is at `start + 1.5T + 2`,
d7 at `start + 8.5T + 2` and the stop at `start + 9.5T + 2` — every sample is
the exact bit centre + 2 cycles, with +-0.5 bit of margin and no accumulation
(the pacer carries the fractional remainder).

Measurement contract: `d = T + 2` or `T + 3`, because the 2-cycle poll
quantises the rising edge by up to one cycle; the host uses `T = d - 3`, so the
worst-case error is -1 cycle (0.02 % at 9600 baud, 0.24 % at 115200). The
`57600` row shows it: `T` used is 832 for a true 833.33, and all 8 bytes still
decode.

**Architectural advantage: learn-from-wire.** The engine measures with its own
timebase (`WAITP` timestamps + `MEAS*`) and then generates its own sampling
clock from that measurement, with a fixed-point pacer that keeps the fractional
bit. No external divider, no configuration, no baud table: a protocol analyser
that becomes a receiver. Nothing in the public Tiny Tapeout/competition
firmware sets does this — the usual entry is a hard-coded divider.

### What the 32-word budget forced (and what it did not)

Two ISA facts shape the program, both reported rather than worked around:

1. **There is no register -> pacer path.** `CFG PERIOD0..3` and `WAITC` take an
   *immediate*, so firmware cannot load a runtime-measured value into the
   pacer. The demo therefore publishes the measurement and the host writes the
   four period bytes — the same division of labour as RP2040 (PIO cannot set
   its own clock divider; the CPU does it after software autobaud). The host
   still never learns the baud rate; it copies `T` (the arithmetic is in
   `run_demos.py`, `T = d - 3`, `period = T*128`).
2. **`MEAS*` cannot follow a second `WAITP`.** Any `WAITP` match overwrites
   `ts_event`, so "wait for the start edge, then wait for the rising edge, then
   `MEAS`" measures 1 cycle, not the start width. The demo keeps the start-edge
   timestamp and polls the pad instead (`INPR`/`JZ`), which is exact and costs
   the same number of words.

Fitting 32 words cost one behaviour: the range check rejects `d > 0x13ff`
(5119 cycles, i.e. below 9.4 kbaud) rather than the requested 5000-cycle
limit. The extra two comparisons needed for the exact bound do not fit; the
looser bound is +2.4 % and is documented here. Word 0-31 are all used, and the
reject path (word 31) falls through the end of program memory into word 0, so
this program needs `PROG_DEPTH = 32` exactly; at depth 64 the fall-through
would hit NOP padding (still correct, one extra wrap).

## 2. WS2812 driver

Side-set drives UIO[2] on **every** cycle (stall cycles included), so the level
is part of the instruction encoding and costs no slot. One `PACE` fixes the
1.25 us bit grid; `WAITC` (an immediate, legal because the pulse width is known
at assembly time) sets the high time; the low time is whatever the pacer has
left, so the period never drifts.

Measured (48 MHz): high widths exactly `{19, 38}` cycles, bit grid exactly
`{60}` cycles — **0 cycles of jitter** on every edge of all 72 bits, 0 cycles of
drift at the last bit.

| quantity | cycles | ns @48 MHz | WS2812B nominal | tolerance |
|---|---|---|---|---|
| period | 60 | 1250 | 1.25 us | +-600 ns |
| T0H | 19 | 396 | 0.40 us | +-150 ns |
| T0L | 41 | 854 | 0.85 us | |
| T1H | 38 | 792 | 0.80 us | +-150 ns |
| T1L | 22 | 458 | 0.45 us | |

At 50 MHz (`ws2812_50mhz.asm`, four immediates and one host period differ):
widths `{20, 40}` (400 ns / 800 ns, exact), grid alternating 62/63 cycles with a
measured mean of 62.522 cycles = 1250.4 ns (+0.03 % from 1.25 us; the exact
pacer average is 62.5, the residual is the per-pixel `PACERST` phase). This is
the case a clock divider cannot do: a non-integer 62.5-cycle period is carried
in the pacer's fraction, so there is no drift across bits or pixels.

Verified on 3 pixels per clock: `11 22 33`, `00 00 00`, `ff ff ff` and
`11 22 33`, `aa 55 0f`, `01 02 04`, reconstructed bit by bit from the measured
pulse widths (72 pulses = 24 bits x 3 pixels, no missing or extra pulse).

Host obligation: keep the FIFO non-empty *inside* a pixel (3 bytes, so depth 4
is enough) and leave it empty between pixels; `PULL` then blocks with DATA
driven low, which is exactly the >= 50 us reset gap. `run_demos.py` waits
2600 cycles (54 us at 48 MHz) between pixels.

**Architectural advantage: sub-cycle-accurate waveform generation.** A
1.25 us protocol with 150 ns tolerances is a hard real-time signal for a CPU,
and is where PIO's clock dividers round. Here the grid is a 24.8 fixed-point
deadline and the pulse width is an instruction-level immediate, so the same
program produces *identical* edges for every bit of every pixel, with a
measured 0-cycle jitter.

## 3. Barrier-synchronised UART -> SPI bridge

Engine 0 receives 8N1 UART at a host-configured baud (same half-bit pacer as
the receiver above, no autobaud), publishes the byte, sets IRQ 0 and arrives at
`BAR 0`. Engine 1 pulls its byte, arrives at `BAR 0`, then runs a mode-0 SPI
frame: CS low, 8 bits, CS high. SCK is side-set driven and pacer-placed
(period 12 cycles = 4 MHz at 48 MHz), MOSI is `BITPIN`/`OUTBIT` and changes one
cycle before each rising edge.

Measured with 32 bytes at 115200 and 57600 baud, both decoded from the same pin
trace: byte sequences at both ends are identical, no short frames, no drops,
`E_ERROR = 0`. `demos/expected/uart_spi_bridge.txt` holds both lists.

**Engine-to-engine data path: none, by design.** FIFOs are host <-> engine;
inter-engine state is 4 barriers and 8 IRQ lines. A nibble bus on the leftover
UIO pins was rejected: two engines would then drive one pad (contention instead
of the chip's own primitives) and it would cost handshake instructions on both
sides. The demo is therefore explicit about the split:

```
engine 0:  ... PUSH r2 ; IRQSET 0 ; BAR 0 ; IRQCLR 0
host:      on IRQ 0, move one byte OUT_FIFO -> IN_FIFO
engine 1:  PULL r0 ;               BAR 0 ; 8 x SCK ... IRQSET 1
```

Back-pressure is structural, not timed: `PUSH` blocks on a full OUT FIFO,
`PULL` blocks on an empty IN FIFO, and the barrier makes the two engines
rendezvous exactly once per byte, so IRQ 0 is always observed while engine 0
waits at the barrier and engine 1 can never start before the byte exists.

Throughput bound (documented, not hand-waved): the SPI frame is 8 x 12 = 96
cycles, ~111 with CS/IRQ overhead, and must fit between the stop-bit sample and
the next start edge (T/2). So the bridge sustains baud below
`48e6 / 222 = 216 kbaud` back to back — verified at 115200 (T/2 = 208) and
57600; at 250 kbaud (T/2 = 96) the SPI frame would overrun the gap.

**Architectural advantage: phase-locked multi-engine.** Four hardware barriers
plus 8 IRQ lines let two independent engines act as one protocol converter with
a rendezvous per byte, while each one keeps an exact local timebase (half-bit
UART sampling on one side, 4 MHz SPI on the other). No shared memory, no locks,
no software timing.

## Model note: the pacer probe

`run_demos.py` prints a non-gating probe of the model's `PACE` semantics:

```
pacer probe @cycle 2^24: N completions in M cycles (period=100) -> ...
```

It arms the pacer 50 cycles before `2**24` with a 100-cycle period and counts
completions. With the 32-bit `next_int`/`next_frac` model the probe reports
~99 cycles/completion and prints `exact` (the first completion is one cycle
after `PACERST`; the rest are one period apart). A 24-bit packed successor
would instead print `FREE-RUN (24-bit truncated deadline)` at one completion
per cycle. The demos themselves are unaffected either way (the longest run here
is < 700 k cycles, and the autobaud demo re-arms the pacer per frame), but any
long-running stream must rely on the 32-bit deadline.

## 4. Ethernet MII transmit (v1-only)

`demos/run_eth.py` lives at `legacy/v1/demos/run_eth.py`. It decodes the v1
two-program image (engine 0 MII emitter 32/32 + engine 1 FCS 32/32) and cannot
run against the v2 image: `firmware/ethernet_mii_tx.asm` is now one 31-word
program on engine 0 that emits out of the assist FIFO and appends the FCS from
the CRC assist, so `programs[1]` does not exist.

The v2 Ethernet path is gated on the RTL instead: `sim/test_protocols.py`
`proteus_ethernet_mii_tx_pins` decodes a complete 802.3 frame (preamble, SFD,
dst/src MAC, ethertype, 46-byte payload, FCS `0xE7C87B32` = `zlib.crc32`) at the
pads, plus the TX_EN window and TXD-vs-TX_CLK discipline. The measurement is in
`v2/results/v2_verify.md` section 4; the v1 evidence table, frame-size
arithmetic and negative tests are preserved in `legacy/v1/demos/README.md`.

## 5. JTAG TAP (v1-only)

`demos/run_stretch.py` lives at `legacy/v1/demos/run_stretch.py` together with
the image it assembles, `firmware/jtag_tap.asm` (engine 0, 32/32 words). Neither
is part of the 3-engine tree: the v2 `firmware/` carries only the five protocol
images (UART TX/RX, SPI, I2C, Ethernet MII) plus `pin_blink.asm`, and the JTAG
image was a v1 stretch target that never left the model.

The v1 TAP measurements (IDCODE `0x5B5B5B5B`, Capture-IR `0b0001`, 12/12
states, the 7-clk minimum TCK period, the BYPASS/Pause limitations and their
assembled word cost) are preserved in `legacy/v1/demos/README.md`.
