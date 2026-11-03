# PROTEUS v2 firmware

The hybrid build (`3 engines x 32 words + 5 assists`) runs these five images.
They are the v1 protocol images (`firmware/*.asm`) ported to the v2 engine map,
plus one new image that only exists because of the assists: a complete 802.3
frame transmitter.

Verified by `python3 v2/demos/run_v2.py` against independent device models
(UART 16x receiver, 8N1 source, SPI mode-0 slave, I2C target, MII PHY + zlib
CRC).  Evidence, measured numbers and limitations: `v2/results/v2_firmware.md`.
The RTL benches in `v2/tb/` cover what the model does not model (line codes,
the SPI host port, the assist CSR window).

## Images

| image | engines | words | assists used | v1 | note |
|---|---|---:|---|---|---|
| `uart_tx.asm` | 0 | 18 | — | identical | pacer 115200 baud, UIO0 |
| `uart_rx.asm` | 1 | 26 | — | identical | half-bit pacer, UIO1, framing-error ASSERT |
| `spi_master.asm` | 2 | 32 | — | identical | mode 0/3, side-set SCLK, UIO2..5 |
| `i2c_master.asm` | 2 + 1 | 32 + 32 | — | **remapped 3+2 -> 2+1** | see below |
| `ethernet_mii_tx.asm` | 0 | 31 | FIFO (16x8) + CRC-32 | **new** | full frame + FCS, UIO0..5 |

`PROG_DEPTH = 32`; every image is inside it.

## Engine map, and why I2C swaps its halves instead of just its index

The v2 top has engines 0..2 and the pin merge gives the **highest engine index**
priority, the same rule v1 used with engines 0..3.

v1 ran I2C as `START/WRITE on engine 3` + `READ/STOP on engine 2`, and its header
relies on engine 3's higher priority: the READ/STOP image leaves side-set on
while it is blocked in `PULL` and therefore drives SCL **low** on every cycle it
is in flight; the START/WRITE image wins its high phases only because it has the
higher index.

A straight `3 -> 1` remap would put START/WRITE on engine 1, i.e. *below* the
parked READ/STOP image on engine 2, whose continuous SCL-low would then hold
every high phase down: the bus deadlocks.  The remap that preserves the
invariant is:

* `START / repeated START / WRITE / ACK check` -> **engine 2** (higher index)
* `READ + ACK/NACK / STOP`                      -> **engine 1**

which also makes the parking explicit on the side that gives the bus away
(`CFG SIDE, 0` in `st_pass`).  The IRQ token lines keep their v1 numbers
(`IRQ1` = bus free for the START/WRITE half, `IRQ0` = bus free for the READ/STOP
half); only which engine waits on which changed, so the host's round order is
unchanged: one command slot per engine per bus operation, START first.

Register and program addresses in v2 (`PROTEUS_EW_BASE 0x0010`, stride `0x20`;
program `0x0100 + 0x100*e`):

| engine | window | IN_FIFO | OUT_FIFO | program |
|---|---|---|---|---|
| 0 | 0x0010 | 0x0020 | 0x0021 | 0x0100 |
| 1 | 0x0030 | 0x0040 | 0x0041 | 0x0200 |
| 2 | 0x0050 | 0x0060 | 0x0061 | 0x0300 |

Assist window: `0x0600 + 0x10*id + reg`; ids 0 CRC, 1 FIFO, 2 SHIFT, 3 NRZI,
4 MANCH; `reg 8` of each stride is the host-only PINCFG.

## Host contract, `ethernet_mii_tx.asm`

The program is 31 of 32 words, so the host does everything that does not depend
on the wire:

1. **CRC assist** (`0x0600 + reg`): `reg2` = `0xE0` `{lsb=1, refl=1, width=32}`;
   `reg3` = 8 (page init) then `reg4..7` = the init pre-image;
   `reg3` = 9 (page poly) then `20 83 B8 ED`; `reg3` = 10 (page xorout) then
   `FF FF FF FF`; `reg3` = 1 (start, `crc <= init`); `reg3` = 0 (page = result).
2. **FIFO assist** (`0x0610`): `reg3` = 0 clears the queue.
3. **Engine 0 registers**: `r2` = number of bytes the host will push
   (`8 + body length`, 68 for the 60-byte demo frame), `r3` = 1 (pass phase).
4. **RUN**: global `0x0004` bit 0.
5. **Push exactly `r2` bytes** in wire order into the FIFO DATA register
   (`0x0610`), never letting the queue run dry: the emitter reads
   `STATUS.empty` once per byte and **aborts** the frame (TX_EN drops, TXD
   parked, IFG, HALT) when the next byte is missing.  It never emits a stale
   byte.
6. The engine appends the FCS itself, re-using the FIFO for the four bytes it
   generates, so the host must stop at exactly `r2` bytes.

The bytes are the *whole* wire frame from the preamble on:
`55 55 55 55 55 55 55 D5 | dst[6] | src[6] | ethertype[2] | payload`.

### The init pre-image

The streamed loop folds every byte it emits into the CRC, including the eight
preamble/SFD bytes.  Folding is an invertible map of the LFSR state, so the host
presets `crc_init` to the pre-image of `0xFFFFFFFF` under the header:

```
fold(init_pre, 55 55 55 55 55 55 55 D5) == 0xFFFFFFFF
init_pre = 0x26B6A4C8            (derived, not transcribed)
```

After the header the assist sits in the state 802.3 requires
(`init 0xFFFFFFFF`), the body folds from there, and the result read from lanes
4..7 is `zlib.crc32(dst|src|ethertype|payload)` with the low byte first, which
is the wire order of the FCS field.  The alternative -- a `ASST CRC, START`
between header and body, or a second loop that skips the fold -- does not fit
31 words.

## Assembling

```sh
python3 - <<'PY'
import sys; sys.path.insert(0, 'v2/tools')
import asm
for n in ('uart_tx', 'uart_rx', 'spi_master', 'i2c_master', 'ethernet_mii_tx'):
    r = asm.assemble_file(f'v2/firmware/{n}.asm')
    print(n, {e: len(w) for e, w in sorted(r['programs'].items())})
PY
```
