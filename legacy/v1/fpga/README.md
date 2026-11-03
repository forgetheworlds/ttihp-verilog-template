# PROTEUS on the Altera DE2 (Cyclone II EP2C35F672C6)

Self-hosting, self-checking FPGA build of the PROTEUS pin engine.

The board needs **no PC after programming**: the FPGA is the chip's SPI host. It
soft-resets the chip, loads the selected demo's firmware into the engines over
the real host protocol (`docs/architecture.md` section 6), runs the demo through
hardware loopback models implemented in the wrapper, and shows PASS/FAIL plus
the byte it verified on the LEDs and 7-segment displays.

```
fpga/tt_um_proteus_fpga.v   DE2 top: chip + SPI master + boot loader + loopbacks
fpga/host_master.v          SPI mode-0 master and command sequencer
fpga/boot_loader.v          boot FSM: reset -> PING -> load -> config -> run -> check
fpga/rom_programs.vh        generated boot ROM (6 program images, 64 words each)
fpga/rom_programs.mif       the same image as a Quartus .mif (documentation)
fpga/proteus_de2.qpf/.qsf   Quartus II 13.0 project, device EP2C35F672C6
fpga/tb_fpga.v              iverilog self-checking testbench
tools/gen_fpga_rom.py       assembles firmware/*.asm -> rom_programs.vh/.mif
```

The chip is instantiated with `PROG_DEPTH = 64` (the RTL default is 32), so the
boot ROM carries 64-word images. Every current program fits 32 words:
`firmware/i2c_master.asm` is a 32+32 split across engines 3 and 2 and therefore
occupies two ROM banks (4 and 5). Program RAM is 4 x 64 x 24 bit.

---

## 1. Prerequisites

* Quartus II **13.0** (Web Edition is fine) with **Cyclone II** device support
  installed. Newer Quartus releases dropped Cyclone II; 13.0 is the last one
  that supports EP2C35.
* Altera **USB-Blaster** and the DE2 board.
* On Linux the Blaster needs udev access; the usual fix is
  `sudo /path/to/quartus/drivers/usb-blaster/install_usb_blaster.sh` plus a
  replug. `jtagconfig` must list `DE2 [1-1]` before programming will work.

No serial cable, no SD card, no NIOS, no PLL and no external clock are used:
the design runs directly from the 50 MHz oscillator.

## 2. Synthesize

```sh
cd fpga
quartus_sh --flow compile proteus_de2
```

Output: `fpga/output_files/proteus_de2.sof` plus the usual reports. The design
is single-clock (CLOCK_50 from the on-board oscillator), so there is no CDC to
close; check `Compilation Report -> TimeQuest` (or the classic Timing Analyzer
summary) for the 50 MHz setup/hold result. Resource usage is whatever the flow
reports: four engines with 4 x 64 x 24 bits of program RAM, the boot ROM
(512 x 24, inferred as LUT logic), the SPI master and the two loopback models.

If you open the project in the GUI instead, open `fpga/proteus_de2.qpf`,
make sure `proteus_de2` is the active revision, and press *Start Compilation*.

## 3. Program the board

```sh
quartus_pgm -c USB-Blaster -m jtag -o "p;output_files/proteus_de2.sof"
```

(Quartus 13 also accepts `quartus_pgm -c USB-Blaster -m JTAG -o ...`.)

The design boots itself about 80 us after configuration and runs the demo
selected by SW[1:0].

---

## 4. Controls

| control | function |
|---|---|
| `KEY[1]` | reset (active low). The FPGA resets, then auto-runs the selected demo. |
| `KEY[0]` | re-run the selected demo (debounced; a run in flight is not interrupted). |
| `SW[1:0]` | demo select: `00` pin blink, `01` UART loop, `10` SPI loop, `11` I2C loop. **Changing SW[1:0] auto-starts the new demo.** |
| `SW[2]` | demo 00 blink rate: `0` = 12.5 M-cycle tick (2 Hz, visible), `1` = 8192-cycle tick (scope / simulation). |
| `SW[7:3]` | drive the chip's fabric inputs `ui_in[7:3]` (visible on the chip's UI bank). |
| `KEY[2]`, `KEY[3]` | unused. |

## 5. Panel map

### LEDs

| LED | meaning |
|---|---|
| `LEDR[0]` | boot-loader busy (SPI frames in flight) |
| `LEDR[1]` | PASS (last completed run) |
| `LEDR[2]` | FAIL / timeout |
| `LEDR[3]` | 1.5 Hz heartbeat (wrapper, not the chip) |
| `LEDR[7:4]` | selected demo id (`0`..`3`) |
| `LEDR[15:8]` | chip `uo_out[7:0]` (`uo_out[0]` = MISO, `uo_out[1]` = IRQ) |
| `LEDG[0]` | **the BLINK pad** (resolved UIO0: chip drive or pull-up) |
| `LEDG[1]` | demo 01 PASS latch |
| `LEDG[2]` | demo 10 PASS latch |
| `LEDG[3]` | demo 11 PASS latch |
| `LEDG[4]` | SPI frame in flight (same as LEDR[0]) |
| `LEDG[5]` | `SW[2]` mirror (fast blink selected) |
| `LEDG[6]` | `uo_out[0]`, i.e. MISO while the host owns the pin |
| `LEDG[7]` | heartbeat |
| `LEDG[8]` | `uo_out[1]`, the IRQ output |

The PASS latches accumulate: run demo 01, then 10, then 11 and `LEDG[1..3]` all
light up. `KEY[1]` clears them.

### 7-segment displays

| display | demo 00 | demos 01 / 10 / 11 |
|---|---|---|
| `HEX0` | BLINK edge count, `count[7:4]` | number of bytes verified (low nibble) |
| `HEX1` | BLINK edge count, `count[15:12]` | **last byte received** (low nibble) |
| `HEX2` | chip `STATUS[3:0]` = any_run, irq, cap_ovf, collision | engine `E_STATUS[3:0]` = run, halted, in_empty, in_full |
| `HEX3` | chip `STATUS[7:4]` = any_error | engine `E_STATUS[7:4]` = out_empty, out_full, nf, timeout |
| `HEX4` | selected demo id | same |
| `HEX5` | `A` = PASS, `5` = FAIL, `0` = busy / just booted | same |
| `HEX6` | failing engine id (`F` when nothing failed) | same |
| `HEX7` | `EE` = FAIL or timeout, `A5` = PASS, `00` while running | same |

A timeout (no expected data within 4.2 M cycles, 84 ms) is a FAIL, so `HEX7`
reads `EE` and `HEX6` shows the engine the demo depends on.

### GPIO headers

Both headers are **outputs** (3.3 V LVTTL); do not drive them.

| signal | GPIO_0 | GPIO_1 |
|---|---|---|
| chip `ui_in[7:0]` | `[7:0]` | – |
| chip `uo_out[7:0]` | `[15:8]` | – |
| chip `uio_out[7:0]` | `[23:16]` | – |
| chip `uio_oe[7:0]` | `[31:24]` | – |
| `uio_in[7:0]` (resolved lines the chip sees) | – | `[7:0]` |
| resolved pad value with pull-ups (`chip_pin`) | – | `[15:8]` |
| `{spi_slave_miso, i2c_sda_low, 6'b0}` | – | `[23:16]` |
| unused | `[35:32]` = 0 | `[35:24]` = 0 |

`ui_in[0]=SCK`, `ui_in[1]=CS_N`, `ui_in[2]=MOSI`, `uo_out[0]=MISO` while the
host owns the pins (which it does until the firmware issues `HOST_DISABLE`).
SCK idles low and runs at 50 MHz / 16 = **3.125 MHz**, well inside the chip's
documented `SCK <= clk/8` limit.

---

## 6. What each demo does, and what you should see

All four demos run at 50 MHz. The firmware's UART constants were derived for
48 MHz, so the board's absolute baud is not 115200:

* TX bit period = 106667/256 = 416.668 cycles = 8.33336 us at 50 MHz
  -> **120000.5 baud** (4.17 % above 115200).
* RX half-bit period = 53333/256 = 208.332 cycles, i.e. 416.664 cycles per bit.
  TX and RX are both driven by the same 50 MHz pacer, so the loopback sees only
  the 0.004-cycle/bit difference between them (0.04 cycle per 10-bit frame) and
  no accumulated drift; the demo is exact in its own clock domain.
* An **external** 115200 host would see the 4.17 % error, which is inside 8N1's
  ±5 % tolerance but marginal. Rebuild the firmware with 50 MHz period values
  (434.0278 cycles/bit -> 111111) before talking to a real 115200 peer.

Demo 01 does not care about the absolute rate: engine 0 transmits and engine 1
receives on the same clock.

### Demo 00 — pin blink (`SW[1:0]=00`)

* Program: `firmware/pin_blink.asm` (5 words) on engine 0. The loader writes the
  pacer period before `RUN`; the engine then free-runs `PACE; TOGP UIO,0x01`.
* `SW[2]=0`: tick = 12 500 000 cycles = 250 ms, so **LEDG[0] blinks at 2 Hz**
  (needs the 32-bit pacer; see finding 1 in section 9).
* `SW[2]=1`: tick = 8192 cycles = 163.84 us (3 kHz, for a scope or the
  testbench -- this is the mode tb_fpga.v verifies, because 8192 cycles per
  edge keeps the simulation short; both modes differ only in the period
  constant the loader writes).
* `HEX1:HEX0` counts rising edges on the pad; `HEX4`=`0`, `HEX5`=`A`, `HEX7`=`A5`.
* PASS is reported as soon as `STATUS[0]` (any_run) reads 1; the engine keeps
  running afterwards, so the display keeps counting.

### Demo 01 — UART loopback (`SW[1:0]=01`)

* Programs: `uart_tx.asm` on engine 0 (UIO0), `uart_rx.asm` on engine 1 (UIO1);
  the wrapper wires UIO0 to UIO1, so engine 1 receives what engine 0 sends.
* The loader pushes four bytes (A5 3C 0F C3) into engine 0's IN_FIFO, waits for
  engine 1's OUT_FIFO to fill through the 8N1 receiver, and compares each byte.
* Expected: `LEDG[1]` on, `LEDR[1]` on, `HEX5`=`A`, `HEX7`=`A5`,
  `HEX1`=`3` (low nibble of the last byte, 0xC3), `HEX0`=`4` bytes verified.
* A mismatch (or a framing error) gives FAIL and `HEX6`=`1`.

### Demo 10 — SPI loopback (`SW[1:0]=10`)

* Program: `spi_master.asm` on engine 2 (`SCK`=UIO2, `MOSI`=UIO3, `MISO`=UIO4,
  `CS_N`=UIO5, SPI mode 0). The loader programs a half-bit period of 25 cycles
  (SCK = 1 MHz) and `r7 = 0` (mode 0) before `RUN`.
* The wrapper contains `fpga_spi_slave`, an 8-bit mode-0 slave that echoes the
  **previous** frame. Sending 5A C3 00 FF therefore returns 00 5A C3 00.
* Expected: `LEDG[2]` on, `HEX5`=`A`, `HEX7`=`A5`, `HEX0`=`4`, `HEX1`=`0`
  (`HEX1` shows the last echo byte, 0x00).

### Demo 11 — I2C loopback (`SW[1:0]=11`)

* Programs: `i2c_master.asm` is a **32+32 two-engine split**. The loader loads
  the engine-3 half (`START`, repeated `START`, `WRITE` byte + ACK check) and
  the engine-2 half (`READ` byte, `ACK`/`NACK`, `STOP`) and runs **both**
  engines (`RUN` mask `0x0C`); `SCL`=UIO6, `SDA`=UIO7, open drain with
  pull-ups modelled in the wrapper.
* Before `RUN` the loader writes `UIO_OD` (`0x0523`) = `0xC0`. Open drain is
  one fabric-wide register, so neither engine sets it; the SCL half period is
  `WAITC 250` inside the image (100 kHz at 50 MHz), and the engine period
  registers are unused by this firmware.
* The two engines share SCL/SDA, so they pass a single **IRQ token** back and
  forth (`IRQ1` = bus free for engine 3, `IRQ0` = bus free for engine 2). The
  loader therefore pushes **one command slot to each engine per bus
  operation**, engine 3 first, exactly the round sequence
  `sim/test_protocols.py` feeds:

  ```
  (01,00) (02 A0,00) (02 5A,00) (02 C3,00) (01,00) (02 A1,00)
  (00,04) (00,05) (00,02)
  ```

  (engine 3 slot, engine 2 slot; `00` = NOP, which consumes the token and
  passes it back). It drains each round's result before pushing the next
  round, so at most one byte is ever outstanding in either `OUT_FIFO`.
* The wrapper contains `fpga_i2c_eeprom`, a 7-bit target at address `0x50` with
  two bytes of storage. Its address pointer restarts at 0 on every START, which
  is a documented simplification of a 24C02 (a real part would need a dummy
  write to set the address pointer first).
* One transaction: START, `A0`, `5A`, `C3`, repeated START, `A1`, READ+ACK,
  READ+NACK, STOP. Engine 3 reports the four ACKs (`0`), engine 2 the two
  read-back bytes (`5A`, `C3`); the loader verifies `00, 00, 00` then
  `00, 5A, C3` and only reports PASS once engine 2 has consumed the STOP
  (`E_STATUS.in_empty`).
* Expected: `LEDG[3]` on, `HEX5`=`A`, `HEX7`=`A5`, `HEX0`=`3`, `HEX1`=`3`
  (last byte 0xC3). Measured in the testbench: one demo 11 run is 123 750
  clocks, 34x inside the 4.19 M-clock loader timeout.

---

## 7. Simulate (no board needed)

The testbench drives the real board top — chip, SPI master, boot loader and all
loopback models — exactly like the panel does, and runs all four demos:

```sh
cd /home/ubuntu/verilog
iverilog -g2005 -I src -I fpga -o /tmp/fpga_tb fpga/tb_fpga.v \
         src/*.v fpga/host_master.v fpga/boot_loader.v fpga/tt_um_proteus_fpga.v
vvp /tmp/fpga_tb
```

`-I src` and `-I fpga` are required: `src/*.v` includes `proteus_defs.vh` and
`boot_loader.v` includes `rom_programs.vh`, and Icarus does not search a source
file's own directory. (`fpga/*.v` cannot be used as the last argument because it
would also pick up `tb_fpga.v`, which is already named explicitly.)

The testbench is self-checking: it prints one line per demo, the number of
checks, and exits non-zero on any failure.  Measured on the current `src/`
(Icarus Verilog 12.0, ~45 s):

```
=== PROTEUS DE2 board top: tb_fpga ===
-- demo 00: pin blink (pacer tick 8192 cycles)
-- demo 01: UART loopback (engine 0 TX -> engine 1 RX)
-- demo 10: SPI loopback (engine 2 + wrapper mode-0 slave)
-- demo 11: I2C loopback (engines 3+2 + wrapper 0x50 EEPROM)
-- demo 11 re-run via KEY[0]
=== tb_fpga: 36 checks, 0 errors ===
PASS: all demos booted and verified through the real host protocol
```

What the checks cover: the power-on auto-start, the real SPI PING handshake
(0x50), the program download for each demo, the per-demo register setup, the
RUN mask, four bytes through the UART loopback, four through the SPI echo, the
I2C transaction driven as one command slot per engine per bus operation (four
ACKs on engine 3, two read bytes on engine 2, 3 bytes verified), the exact
pacer edge spacing (8192 clocks, measured on the BLINK pad), the HEX1 last-byte
display, and a second run of demo 11 driven by a debounced KEY[0] press.

## 8. Regenerate the boot ROM

After editing anything in `firmware/`:

```sh
python3 tools/gen_fpga_rom.py            # rewrites fpga/rom_programs.vh and .mif
python3 tools/gen_fpga_rom.py --check    # exit 1 if the checked-in files are stale
```

Program images are emitted as a Verilog-2001 `case` function (no `$readmemh`,
no synthesis-time file I/O), 64 words per programme, unused words = `HALT`.
A firmware file that targets two engines contributes one bank per engine:
`i2c_master.asm` is bank 4 (engine 3) and bank 5 (engine 2), and
`fpga_demo_prog` maps demo 3/11 to both. Engines a demo does not use are not
loaded at all: the chip's reset fill has already written `HALT` into every
unwritten program word.

## 9. RTL findings from this build

Three defects were found while bringing this up and have been reported to the
RTL owner. All three are fixed in the current `src/`; the notes are kept here
because a build against an older revision will show the symptoms described.

1. **Pacer deadline was only 24 bits wide** (`proteus_engine.v`, `OP_PACE` /
   `OP_PACERST`). It compared `cycle` against the zero-extended `next[31:8]` and
   latched `cycle[23:0]`, so pacing was exact only below 2^24 cycles (0.33 s at
   48 MHz) and then free-ran one completion per cycle for ever, while
   `tools/model.py` used the full 32-bit value. Fixed by the 32-bit
   `next_int` + `next_frac` deadline. On an older revision, demo 00 with
   `SW[2]=0` free-runs after about a third of a second; `SW[2]=1` still works.
2. **`localparam [5:0] PDEPTH = PROG_DEPTH` truncated depth 64 to 0**
   (`tt_um_proteus.v:80` at the time). At `PROG_DEPTH = 64` this made `pm_ok`
   false for every address, so every program-memory write was silently dropped
   and every program read returned 0; the engines then executed HALT at PC 0 and
   the new `halt_exec` path cleared their RUN bits. Invisible at the default
   depth 32. Fixed by widening PDEPTH to 7 bits. Any 64-deep build (this FPGA
   design) needs that fix.
3. **FIFO data cannot be pushed with one auto-incrementing burst.**
   `WRITE_ADDR`/`WRITE_INC` advance the chip address, so a burst aimed at an
   engine's `IN_FIFO` (window `+0x10`) also writes `+0x11` (OUT_FIFO read port),
   `+0x12` (bit-pin cfg) and `+0x13` (side-set cfg). Pushing N bytes that way
   delivers one byte and destroys the engine configuration -- which silently
   disables side-set, so SCK/I2C-SCL stop toggling. Host-side code (this loader,
   cocotb tests, any PC script) must push FIFO bytes **one frame per byte**, and
   should poll `E_STATUS[3]` (`in_full`) first because `FIFO_DEPTH` is now a
   parameter (4 in the current build) and a push to a full FIFO is dropped.

## 10. Troubleshooting

| symptom | cause |
|---|---|
| `jtagconfig` sees no cable | udev rules / missing `install_usb_blaster.sh`, or another `jtagd` owns the cable (`killall jtagd`) |
| `Error: Can't access JTAG chain` | Blaster in the wrong port; try `-c USB-Blaster` with the cable in the DE2's JTAG header |
| `HEX7`=`EE` on every demo | the chip is not answering: `HEX6` says which demo engine failed, `HEX3:HEX2` shows the last status byte read (`any_error` is bit 4 of the global STATUS, shown on `HEX2` for demo 00) |
| `HEX7`=`EE` with `HEX6`=`F` | never reached the demo: PING failed 4 times (SPI wiring/clock) |
| demo 00 flickers after ~0.3 s | old RTL pacer (finding 1); rebuild against current `src/` or set `SW[2]=1` |
| demo 10/11 stall after the first byte, SCK/SCL never move | FIFO pushed with an auto-incrementing burst: side-set cfg was overwritten (finding 3) |
