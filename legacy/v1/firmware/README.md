# PROTEUS firmware

Each file is assembled for one engine at the build's `PROG_DEPTH`. The default
build is 32 instructions per engine; `tools/asm.py --depth` accepts up to 64.

| file | engine(s) | words | protocol |
|---|---|---:|---|
| `uart_tx.asm` | 0 | 18 | 8N1 transmitter, 115200 at 50 MHz |
| `uart_rx.asm` | 1 | 26 | 8N1 receiver, half-bit pacer sampling |
| `spi_master.asm` | 2 | 32 | SPI master, modes 0 and 3 |
| `i2c_master.asm` | 3 + 2 | 32 + 32 | I2C master, open drain, stretching |
| `ethernet_mii_tx.asm` | 0 + 1 | 32 + 32 | 10BASE-T MII transmitter + CRC-32 FCS |
| `jtag_tap.asm` | 0 | 32 | IEEE 1149.1 TAP subset, IDCODE `0x5B5B5B5B` |

All six fit a 32-word engine. Each file's header states its measured timing
contract; `results/protocol_rtl.md` holds the numbers measured on the RTL,
`results/ethernet.md` the Ethernet numbers measured on the model,
`results/stretch.md` the JTAG numbers.

## JTAG TAP: what a 32-word engine can afford

`jtag_tap.asm` is the only image here whose protocol is not point-to-point: it
has to hold an IEEE 1149.1 state machine. The compression that makes it fit is
that **the DR and IR columns are the same state graph**. The column is not a
state, only a capture constant, so the FSM is six blocks, not sixteen:

| block | words | states served |
|---|---:|---|
| `tlr` | 5 | Test-Logic-Reset |
| `upd` | 4 | Run-Test/Idle **and** Update-DR/IR (identical successors) |
| `seldr` | 5 | Select-DR |
| `shift` | 7 | Capture-DR/IR (folded in) + Shift-DR/IR |
| `exit1` | 5 | Exit1-DR/IR |
| `selir` | 6 | Select-IR |

Capture is folded into Shift because the load happens on the `Select -> Shift`
edge, which a 1149.1 host does not sample: the first *sampled* bit is still
bit 0, and the 32-bit read is exact. `Update` shares the Run-Test/Idle block
because both go to Select-DR on TMS=1 and stay on TMS=0.

Per-state cost is 5-7 words (3 of edge wait, 1 conditional, 1 tail jump) since
the ISA has no indirect jump. That is why the image covers the twelve required
states but not Pause/Exit2, and why BYPASS (which needs TDI capture) is absent:
a measured build with both is 51 words. `results/stretch.md` §6 has the
assembled counts for every variant.

Host contract: write `0x98` to `0x0012` (bit-pin = UIO[3], push-pull TDO) before
`RUN`. The image does not execute `CFG BITPIN` — that is the one word the 32/32
build does not have.

## SPI master: clock and CS framing

`SCK` is side-set driven and every SCK phase is one `PACE`. `PACERST` sets the
deadline to "now", so the PACE issued right after it completes immediately: the
mode prologues burn that one-cycle stub *before* CS is asserted, which is what
makes the first high phase a full half period instead of a 3-cycle stub. Each
phase then starts with its level-setting instruction and ends with the PACE, so
every high and low phase measures exactly the programmed period (25 cycles at
1 MHz; 20/30 before the fix). CS is asserted one cycle after the stub, stays
low for exactly 16 edges, and is released a full half period after the last
one. Mode 3 counts `r1 = 16..9` so the shared body can end its transfer on the
rising (sample) edge with `m3end`, leaving SCLK high for the CPOL=1 CS release.

## I2C master: why two engines

The full I2C master cannot fit one 32-word program. The irreducible parts are
a 15-word write path (8-bit shift, 9 clocks, ACK sample), a 12-word read path
(8 samples plus the 9th-clock ACK/NACK), a dispatcher/FIFO loop, and a
START/STOP pair: about 40 words even after sharing the 8-bit clock loop.
`i2c_master.asm` therefore splits the work:

| engine | owns | commands |
|---|---|---|
| 3 | START / repeated START, WRITE byte, ACK check | `0x00` NOP, `0x01` START, `0x02` WRITE |
| 2 | READ byte, ACK/NACK, STOP | `0x00` NOP, `0x02` STOP, `0x04` READ+ACK, `0x05` READ+NACK |

Pins: SCL = `UIO[6]`, SDA = `UIO[7]`, both open drain. `UIO_OD` is one
fabric-wide register (`0x0523`), so the host writes `0xC0` before RUN instead
of both engines writing `ODSET`. Engine 3 side-set drives SCL
(`CFG SIDE,0xD8`) and turns it off again (`CFG SIDE,0`) while engine 2 owns the
bus; both engines use the bit-pin shortcut for SDA (`CFG BITPIN,0xB8`). Every
SCL release is followed by `WAITP UIO,0x40,1`, so clock stretching is honoured
before the high phase.

### Host contract

The host routes commands to the right engine and, for each bus operation,
writes exactly one command slot to each engine: a real command for the acting
engine and `0x00` (NOP) for the other. Commands are consumed in order, so the
two streams are paired round by round.

```
write:  (START, NOP) (WRITE addr, NOP) (WRITE data, NOP) (NOP, STOP)
read:   (START, NOP) (WRITE addr|1, NOP) (NOP, READ+NACK) (NOP, STOP)
```

Engine 3 pushes the ACK result of each write (`0x00` ACK, `0x01` NACK); engine
2 pushes each received byte. A multi-byte read uses `0x04` for every byte and
`0x05` for the last one.

### Handoff: IRQ token, not BAR

The two engines share SCL/SDA, so only one may drive the bus at a time. The
cycle model's `BAR` only advances the engine that arrives last: an engine that
arrives early stalls, then re-arms the barrier after the last arriver has
cleared it, so a staggered rendezvous deadlocks. That was reproduced directly
in `tools/model.py` with two engines started a few cycles apart.

The split therefore uses the IRQ lines as a two-phase token:

* `IRQ0` = bus is free for engine 2
* `IRQ1` = bus is free for engine 3

Engine 3 sets `IRQ1` once at boot, so it owns the bus first. Each command
loop is `PULL r0; IRQWAIT <token>; IRQCLR <token>; execute; IRQSET <peer>`, and
`0x00` (NOP) consumes the token and passes it back. Both engines must be RUN.
This is race-free because the two engines wait on different token lines; the
token holder is the only one that can proceed.

### Clock: WAITC, not the pacer

`CLK_HZ = 50 MHz` (`info.yaml clock_hz`). SCL phases are timed with
`WAITC I2C_HALF`, where `I2C_HALF = 250` cycles, i.e. a 100 kHz SCL. The pacer
is not used by this image, for two reasons measured on the RTL:

* `PACE` completes on the first cycle where `cycle >= next`, and `PACERST` sets
  `next = cycle`, so the PACE issued right after `PACERST` completes at once.
  The first SCL phase of every command was therefore 3 cycles long instead of
  a half period (high widths `(3, 250)`, rising-edge intervals `7..1688`).
* a slave stretch (SCL held low, `WAITP` blocks) leaves the pacer grid behind
  real time, so the phases after a stretch were short: a 400-cycle stretch
  produced a 23-cycle high phase.

`WAITC` counts from the current cycle, so a stretch can only lengthen the low
phase, which is what the bus actually does. Measured at the pads: every SCL
high and low phase is 252-253 cycles (250 plus the instruction overhead), the
phases that span a command boundary or the stretch are longer, START setup 252
/ START hold 251, STOP setup 252 -- all above the 40-cycle requirement.
Fast-mode minima are t_LOW >= 1.3 us = 65 cycles and t_HIGH >= 0.6 us = 30
cycles, so any `I2C_HALF >= 65` is legal; the shipped 250 is 100 kHz. Changing
the SCL rate means rebuilding with another `I2C_HALF`; the host's period
register is unused by this image.

UART periods at 50 MHz: TX `111111` (`0x0001B207`, +0.0001 % baud error), RX
half-bit `55556` (`0x00D904`, +0.0008 %). Both use the fractional pacer, so
the one-cycle jitter does not accumulate.

## Ethernet MII transmit: what fits and what does not

`ethernet_mii_tx.asm` is the honest answer to "can it do Ethernet". It is two
32-word programs, each verified end to end on the cycle model against an
independent MII PHY model (`demos/run_eth.py`, `results/ethernet.md`).

| engine | words | job |
|---|---:|---|
| 0 | 32 | MII nibble transmitter: 7x`0x55` preamble, `0xD5` SFD, 46-byte counter payload; TXD/TX_EN clocked by the PHY's TX_CLK; 96-bit-time IFG; halt |
| 1 | 32 | Ethernet FCS: reflected CRC-32 over a 1..255-byte frame fed through `IN_FIFO`; FCS left in `r4..r7`, `r4` first on the wire |

Pins: `TX_CLK = UIO[0]` (input, PHY-generated 2.5 MHz), `TX_EN = UIO[1]`
(side-set), `TXD0..3 = UIO[2..5]` (one `OUTP UIO,0x3C`). The five other `uio`
pins, `ui_in` and `uo_out` stay free for the host interface.

Measured: 108 nibbles with TX_EN high and no other rising edge gated, 80 ns
worst-case setup and 240 ns hold around the sampling edge, 24 idle nibble
times (96 bit times) after the frame, `COLLISION = 0`, engine halted. FCS
bit-exact against `zlib.crc32` on three frames; the 60-byte frame under test
is `0xe7c87b32`, transmitted as `32 7b c8 e7`. CRC cost 140.8 cycles/byte
(169 us for 60 bytes) -- a pre-transmit computation, since 10 Mbit/s grants
only 40 cycles per byte of wire time.

A complete 802.3 frame does **not** fit, and the count is measured rather than
estimated: a constant frame byte costs 11 words (1 `LDI` + 10 to emit its two
nibbles, verified by assembling 4 and 5-byte blocks), so the emitter is
32 + 14x11 (MAC header) + 4x11 (FCS) = **230 words** against a 32-word engine.
Two engines cannot compose it either: only one engine may drive TXD/TX_EN, and
the only inter-engine path is the host FIFO, one byte per SPI frame.

Not implemented, deliberately: no receive path, no MDIO/MDC, no Manchester
encoding or analog front end (this is MII to an external PHY), no carrier
sense/collision/jam, and the FCS engine's 8-bit length register limits it to
255-byte frames.
