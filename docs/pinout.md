# Pins, banks and timing

Three views of the same 24 pins: the Tiny Tapeout physical pins, the logical
bank map the ISA addresses, and the pins the chip actually frees to the fabric.
All of it is derived from `src/tt_um_proteus.v` (port list, pin assignments,
merge order) and `src/proteus_defs.vh` (bank and window constants);
`docs/architecture.md` §2 and §4 are the prose contract.

**The pinout is unchanged from v1.** The hybrid v2 build moved one engine to
five protocol assists; no pad changed function, direction or location.

---

## 1. Physical pin map (Tiny Tapeout side)

| TT pin | top port | pad use | while `host_en = 1` | after `HOST_DISABLE` |
|---|---|---|---|---|
| `ui_in[0]` | `ui_in[0]` | input | SPI `SCK` | fabric input |
| `ui_in[1]` | `ui_in[1]` | input | SPI `CS_N`, active low | fabric input |
| `ui_in[2]` | `ui_in[2]` | input | SPI `MOSI` | fabric input |
| `ui_in[3]` | `ui_in[3]` | input | fabric input | fabric input |
| `ui_in[4]` | `ui_in[4]` | input | fabric input | fabric input |
| `ui_in[5]` | `ui_in[5]` | input | fabric input | fabric input |
| `ui_in[6]` | `ui_in[6]` | input | fabric input | fabric input |
| `ui_in[7]` | `ui_in[7]` | input | fabric input | fabric input |
| `uo_out[0]` | `uo_out[0]` | output | SPI `MISO` | fabric output |
| `uo_out[1]` | `uo_out[1]` | output | `IRQ` = `&#124;(irq &amp; irq_enable)` | fabric output |
| `uo_out[2]` | `uo_out[2]` | output | fabric output | fabric output |
| `uo_out[3]` | `uo_out[3]` | output | fabric output | fabric output |
| `uo_out[4]` | `uo_out[4]` | output | fabric output | fabric output |
| `uo_out[5]` | `uo_out[5]` | output | fabric output | fabric output |
| `uo_out[6]` | `uo_out[6]` | output | fabric output | fabric output |
| `uo_out[7]` | `uo_out[7]` | output | fabric output | fabric output |
| `uio[0]` | `uio_out[0]`/`uio_oe[0]`/`uio_in[0]` | inout | fabric, per-pin OE/OD | fabric, per-pin OE/OD |
| `uio[1]` | `uio_out[1]`/`uio_oe[1]`/`uio_in[1]` | inout | fabric | fabric |
| `uio[2]` | `uio_out[2]`/`uio_oe[2]`/`uio_in[2]` | inout | fabric | fabric |
| `uio[3]` | `uio_out[3]`/`uio_oe[3]`/`uio_in[3]` | inout | fabric | fabric |
| `uio[4]` | `uio_out[4]`/`uio_oe[4]`/`uio_in[4]` | inout | fabric | fabric |
| `uio[5]` | `uio_out[5]`/`uio_oe[5]`/`uio_in[5]` | inout | fabric | fabric |
| `uio[6]` | `uio_out[6]`/`uio_oe[6]`/`uio_in[6]` | inout | fabric | fabric |
| `uio[7]` | `uio_out[7]`/`uio_oe[7]`/`uio_in[7]` | inout | fabric | fabric |

`ena`, `clk` and `rst_n` are the Tiny Tapeout harness pins; `ena` is tied off as
unused inside the top (`wire _unused = &{ena, 1'b0};`).

Pad drive is 30 mA per the IHP harness; I/O is **3.3 V only** with no 5 V
tolerance and no internal pull-ups (`research/tt-ihp-constraints.md`). Open-drain
operation on `uio` therefore requires external pull-up resistors.

---

## 2. Logical bank map (ISA view)

Pin instructions carry a 2-bit bank in `rs[1:0]` and an 8-bit mask in `imm8`:

| bank | value | logical pins | underlying pins | access |
|---|---|---|---|---|
| `UI` | 0 | 0..7 | `ui_in[7:0]` | read only; writes are ignored |
| `UO` | 1 | 8..15 | `uo_out[7:0]` | write, readback of the driven value |
| `UIO` | 2 | 16..23 | `uio[7:0]` | read `uio_in`, write `uio_out` + OE |
| - | 3 | - | - | does not exist; reads as 0 |

The logical index is `8*bank + bit`, so `UIO[3]` is physical `uio[3]`.

Write registers (`src/tt_um_proteus.v`):

```verilog
uo_out  = {uo_q[7:2], host_en ? irq_out : uo_q[1], host_en ? miso : uo_q[0]};
uio_out = uio_q;
uio_oe  = oe_q & ~(od_q & uio_q);
```

### 2.1 Merge order and priority (v2)

Per cycle, in this order:

1. **Engines 0..2**, each with `{data, mask}` per bank:
   `reg = (reg & ~mask) | (data & mask)`, so engine 2 wins a bit engine 0 also
   drove.
2. **Assist stage**, one extra source per bank, gated by that assist's
   `PINCFG.en`. It beats every engine on the bits it owns, and because assist
   pins are push-pull the stage also clears open-drain for those bits
   (`od = od & ~as_od_m`).
3. **Host register write** to `0x0520..0x0523`, latched last in the same clocked
   block; it wins over engine and assist traffic for that cycle.

Any `UIO` write sets the corresponding `oe` bit (auto-direction) unless the
instruction is `DIRS`/`DIRC`.

### 2.2 Assist pin ownership (`PINCFG`, new in v2)

An assist drives or senses pads only when its host-only `PINCFG` register has
`en = 1`. The reset value of all five `PINCFG` registers is `0`, so a reset
fabric is engine/host owned exactly as in v1.

```
PINCFG  = 0x0600 + 0x10*id + 8        (id 0..4; host only, engines cannot see it)
  [7]   en
  [6:5] bank   0 ui_in (read-only), 1 uo_out, 2 uio, 3 none
  [4:2] tx_base
  [1:0] rx_base
```

| assist | pins it drives | pins it senses |
|---|---|---|
| `CRC` (0), `FIFO` (1), `SHIFT` (2) | none | none |
| `NRZI` (3) | two adjacent TX pins: `dp` at `tx_base`, `dm` at `tx_base+1` | `dp`/`dm` at `rx_base`, `rx_base+1` |
| `MANCH` (4) | one TX pin at `tx_base` | one RX pin at `rx_base` |

Receive pins are read from the raw pads (`pin_ui`/`pin_uio`), never from the
merged output, so an assist sees the bus it shares. The ownership regression is
`tb/top_e2e_tb.v` phase `[4e]`: with `PINCFG.en = 1` the Manchester assist's
idle level beats the host value on `uo_out[7]`, and an assist-owned `uio` bit is
forced push-pull (OE on) despite `UIO_OD`.

---

## 3. Host pin reservation and reclamation

The four host functions are not separate pads - they borrow fabric pins:

| pin | host function | fabric meaning after release |
|---|---|---|
| `ui_in[0]` | `SCK` | input bit 0 |
| `ui_in[1]` | `CS_N` | input bit 1 |
| `ui_in[2]` | `MOSI` | input bit 2 |
| `uo_out[0]` | `MISO` | output bit 0 |
| `uo_out[1]` | `IRQ` | output bit 1 |

While `host_en = 1` the top masks those bits away from the engines:

```verilog
wire [7:0] fab_ui = {ui_in[7:3], host_en ? 3'b000 : ui_in[2:0]};
wire [7:0] fab_uo = {uo_q[7:2],  host_en ? 2'b00  : uo_q[1:0]};
```

and drops engine writes to `uo_q[1:0]`. Engines and assists therefore always
see `ui_in[2:0] == 0` and `uo_out[1:0] == 0` while the host owns them - firmware
that polls those bits before `HOST_DISABLE` will read 0, not the pin.

Release paths:

1. command `0x09` (`HOST_DISABLE`) over SPI, or
2. write `0` to `0x0007` (`HOST_EN[0]`).

Both clear `host_en` and **abort the current frame** (`proteus_host` enters
`S_DEAD` until `CS_N` rises). Recovery: write `1` to `0x0007`.

Reclamation arithmetic, counted from the RTL rather than the prose:

| state | host owns | fabric drives | fabric reads | fabric-usable pins |
|---|---:|---:|---:|---:|
| `host_en = 1` | 5 (`SCK`, `CS_N`, `MOSI`, `MISO`, `IRQ`) | 14 (`uo_out[7:2]`, `uio[7:0]`) | 13 (`ui_in[7:3]`, `uio_in[7:0]`) | **19** |
| `host_en = 0` | 0 | 16 (`uo_out[7:0]`, `uio[7:0]`) | 16 (`ui_in[7:0]`, `uio_in[7:0]`) | **24** |

`uio` is counted once (bidirectional). The IRQ function loses its pin at
release: `irq_out` is simply no longer routed to `uo_out[1]`, and
`IRQ_STATUS`/`IRQ_ENABLE` remain readable and writable over SPI, so firmware can
still poll interrupts through the register map.

After release the register map is still reachable: frames are decoded even with
`host_en = 0`, so a fabric that bit-bangs `SCK`/`CS_N`/`MOSI` can still program
the chip.

---

## 4. Timing at 50 MHz

Sign-off clock: 50 MHz, 20 ns (`CLOCK_PERIOD: 20` in the Tiny Tapeout flow,
`results/area_baseline.md`, `docs/flow.md` §3). All numbers below are derived
from that period and the RTL; none is a measured silicon number.

| quantity | value at 50 MHz | derivation |
|---|---|---|
| clock period | 20 ns | `CLOCK_PERIOD` 20 |
| instruction retire | 20 ns | one instruction per cycle |
| peak instruction rate | 150 M instructions/s | 3 engines x 50 MHz |
| assist access | 20 ns per `LDAS`/`STAS`/`ASST` | combinational read, one cycle |
| pacer resolution | 5.12 ns | 24.8 fixed point, 1/256 cycle |
| pacer max period | 335.5 ms | `period[31:8]` up to 2^24-1 cycles |
| pacer/deadline horizon | 85.9 s | 32-bit `next_int` before wrap |
| `WAITC` range | 1 .. 2047 cycles = 20 ns .. 40.9 us | `n = rs[2:0]:imm8` |
| capture timestamp resolution | 20 ns | cycle counter |
| capture timestamp range | 85.9 s | 32-bit cycle counter |
| capture FIFO depth | 4 events | `CAP_DEPTH = 4` |
| pin write visibility | next cycle | bus registered at the clock edge |
| SPI `SCK` ceiling | 6.25 MHz | `clk/8`, `proteus_host` decision 3 |
| SPI transaction, 6-byte frame | ~7.7 us at 6.25 MHz | 48 bits / 6.25 Mbit/s |
| `WAITP`/`IRQWAIT` timeout unit | 5.12 us | 256 cycles |

Consequences worth designing around:

- A 24-pin protocol at 10 Mbit/s needs 5 cycles/bit; the engines have 3 x
  50 MHz of instruction budget. The shipped MII path therefore leaves the byte
  stream to the FIFO/CRC assists and uses the engine only for nibble slots
  (`firmware/ethernet_mii_tx.asm`, 31 words).
- Loading a full 32-word program (96 live bytes, or 128 bytes with the unused
  lane) is 1,024 `SCK` bits ~ 164 us at 6.25 MHz, plus the 32-cycle `prog_ready`
  fill.
- The pacer's 1/256 resolution is what lets a 115200-baud UART be exact at
  integer-ish clocks; at 50 MHz a bit time of 434.0278 cycles is representable
  as `111111` (434.0273 cycles), an error of 1 ppm.

### Clock-domain note for existing firmware

`firmware/uart_tx.asm`, `firmware/uart_rx.asm` and `docs/isa.md` §3.2 compute
their pacer constants for **48 MHz** (`106667/256 = 416.668` cycles). The
sign-off clock is **50 MHz**, so those constants produce 120.0 kbaud, not 115200
(4.2% fast, outside a UART's +/-2%). The RTL protocol gate drives the period the
host writes and measures 434.03 cycles/bit, so the hardware is correct for
either constant; the demo harness runs both clocks explicitly
(`demos/run_demos.py` header: `CLK_HZ_48`, `CLK_HZ_50`, and the autobaud rows
show 48000k/115200 and 50000k/115200 separately).

```
115200 baud at 50 MHz: 50e6/115200 = 434.02778 cycles
434.02778 * 256 = 111111.1 -> 111111 = 0x0001B207
```

This is recorded as a documentation/firmware conflict, not silently corrected:
the firmware files are owned elsewhere and the model tests pin the 48 MHz
constants.

---

## 5. DE2 FPGA mapping (v1 tree only)

The DE2 build is **v1 evidence only**. `fpga/` in this repository still targets
the four-engine v1 top and is archived alongside it at `legacy/v1/fpga/`; it has
not been ported to the three-engine v2 top, and no v2 FPGA result is claimed.

`legacy/v1/fpga/tt_um_proteus_fpga.v` (Cyclone II EP2C35F672C6, 50 MHz
`CLOCK_50`) contains the v1 chip RTL with `PROG_DEPTH = 64`, plus an SPI host
master and a self-hosting boot loader. Board mapping as implemented there:

| board resource | function |
|---|---|
| `SW[1:0]` | demo select: `00` pin blink, `01` UART loop, `10` SPI loop, `11` I2C loop |
| `SW[2]` | demo 00 rate: `0` = 12,500,000 cycles (250 ms, 2 Hz), `1` = 8,192 cycles (163.84 us) |
| `SW[3..7]` | drive the chip's fabric inputs `ui_in[7:3]` |
| `KEY[0]` | (re)run the selected demo, debounced (~164 us) falling edge |
| `KEY[1]` | reset, active low; the demo auto-starts ~80 us after release |
| `KEY[2]`, `KEY[3]` | unused |
| `LEDR[0]` | loader busy |
| `LEDR[1]` | loader PASS |
| `LEDR[2]` | loader FAIL |
| `LEDR[3]` | heartbeat |
| `LEDR[7:4]` | `{2'b00, demo}` |
| `LEDR[15:8]` | `uo_out` |
| `LEDG[0]` | BLINK pad mirror (demo 00) |
| `LEDG[1..3]` | per-demo PASS latches (demo 01 / 10 / 11) |
| `LEDG[4]` | SPI frame in flight |
| `LEDG[5]` | `SW[2]` mirror |
| `LEDG[6]` | `uo_out[0]` (MISO while the host owns it) |
| `LEDG[7]` | heartbeat |
| `LEDG[8]` | `uo_out[1]` (IRQ) |
| `HEX0`, `HEX1` | last data byte low / high nibble |
| `HEX2`, `HEX3` | loader status low / high nibble |
| `HEX4` | demo number |
| `HEX5` | `A` pass, `5` fail, `0` idle |
| `HEX6` | failing engine id, `F` if none |
| `HEX7` | `A` pass, `E` fail, `0` idle |
| `GPIO_0` | `[7:0] ui_in`, `[15:8] uo_out`, `[23:16] uio_out`, `[31:24] uio_oe` - scope probe |
| `GPIO_1` | `[7:0] uio_in`, `[15:8] chip_pin`, `[16] spi_slave_miso`, `[17] i2c_sda_low` |

The wrapper implements the loopback partners in the 50 MHz domain: a UART wire
between `UIO0` and `UIO1`, an 8-bit mode-0 SPI slave on `UIO2..5` that echoes
the previous frame, and a `0x50` I2C "EEPROM" with pull-ups on `UIO6/7`. The SPI
master in the boot loader runs `SCK = clk/16` (3.125 MHz), 2x inside the chip's
`clk/8` limit.

The v1 board-level self-check is `legacy/v1/fpga/tb_fpga.v` (Icarus, no board
required); its recorded result is **36 checks, 0 errors** on the settled v1
tree (`legacy/v1/`, `results/` v1 evidence). It was not re-run against `src/`:
the v2 top has three engines and an assist bank, so that bench is not expected
to compile or pass here, and no such claim is made.
