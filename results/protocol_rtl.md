# PROTEUS protocol E2E on the RTL: results

Real `tt_um_proteus` RTL (Icarus, `PROG_DEPTH = 32`, `FIFO_DEPTH = 4`), real
`firmware/*.asm` images loaded over the host SPI port at 50 MHz (20 ns), pads
decoded by the independent pin-level models in `sim/test_protocols.py`.

## Commands

```sh
cd sim && make protocols                       # the four protocol E2E tests
.venv/bin/python -m pytest tools/tests -q      # model + firmware + asm tests
```

`make protocols` runs `COCOTB_TEST_MODULES=test_protocols` into
`sim/sim_build/protocols`, writing `sim/results_protocols.xml`.

## Results

```
** test_protocols.proteus_uart_tx_pins      PASS      930730.00 ns  **
** test_protocols.proteus_uart_rx_pins      PASS     1515930.00 ns  **
** test_protocols.proteus_spi_master_pins   PASS      461190.00 ns  **
** test_protocols.proteus_i2c_master_pins   PASS     1273150.00 ns  **
** TESTS=4 PASS=4 FAIL=0 SKIP=0                      4181000.00 ns  **
```

Check counts: UART TX 18, UART RX 6, SPI master 123, I2C master 30.
`pytest tools/tests -q` -> `179 passed`.

### UART TX (engine 0, UIO0)

Payload `[0x00, 0xFF, 0x55, 0xAA, 0x41]`, decoded by the 16x-oversampling 8N1
receiver: five frames, all bytes exact, every stop bit high. Start deltas
`[4343, 4343, 4343, 4343]` cycles against the ideal `10 * 434.02734 = 4340.27`;
measured start-bit width 434 and stop-bit width 437 cycles (period 434.027).

### UART RX (engine 1, UIO1)

An independent 8N1 source with random inter-byte gaps drives UIO1; the bytes
popped from the OUT_FIFO equal what was sent, including the final framing-error
frame (`0x00` with the stop bit driven low), which sets `E_ERROR` and does not
set the `WAITP` timeout flag:

```
UART RX 9 bytes, gaps=[12634, 20881, 26523, 31731, 37374, 42582, 48224,
                       53867, 61245], error frame at 61245
```

### SPI master (engine 2, mode 0, UIO2..5)

Complement slave on MISO. OUT_FIFO echoes `~MOSI` for
`[0x00, 0xFF, 0x5A, 0xA5, 0x81, 0x7E]` -> `[0xFF, 0x00, 0xA5, 0x5A, 0x7E, 0x81]`,
six CS-framed transfers, 16 SCK edges each (8 rising / 8 falling), SCK low at
CS assert, MOSI/MISO bytes exact at the pads.

### I2C master (engines 3+2, SCL = UIO6, SDA = UIO7, open drain)

One transaction: START, WRITE `0xA0`, data `0x5A`, data `0xA5`, repeated START,
WRITE `0xA1`, READ+ACK, READ+NACK, STOP. Target at `0x50` stretches SCL for
400 cycles after the address ACK.

```
events  [('START', 27609), ('RSTART', 44130), ('STOP', 59354)]
acks    [0, 0, 0, 0, 0, 1]      addr, data0, data1, read-addr, master ACK, NACK
written [0x5A, 0xA5]            data bytes decoded at the pads
served  [0x11, 0x22]            bytes the target presented
stretch [(33337, 33737)]        400 cycles of SCL held low
engine 3 OUT_FIFO [0, 0, 0, 0]  four write ACKs
engine 2 OUT_FIFO [0x11, 0x22]  two read bytes
collision 0x00, both engines: no timeout, no E_ERROR
```

## Measured widths, before and after

All numbers are 50 MHz cycles measured at the pads.

### SPI, half bit = 25 cycles (period register 6400 = 0x1900)

RTL, pre-fix (baseline run) vs post-fix:

| | before | after |
|---|---|---|
| SCK high phases | `[3, 20, 20, 20, ...]` | `[25] * 15` |
| SCK low phases | `[22, 30, 30, 30, ...]` | `[25] * 15` |
| rising-to-rising | `[25, 50, 50, ...]` | `[50] * 7` |
| CS assert -> first edge | 3 | 25 |
| last edge -> CS release | 29 | 25 |
| SCK edges while CS high | 2 (`13876`, `14144`) | 0 |
| result | FAIL, 1 of 82 checks (`SCK moved while CS high`) | PASS, 123 checks |

(The half-phase and CS numbers are from the RTL run; the same values reproduce
on the cycle-model bench.)

Cause: `PACERST` sets the deadline to the current cycle, so the first `PACE`
after it completed at once and the first high phase was a 3-cycle stub; the
remaining phases then landed 20/30 apart because the edge instruction was
issued on the PACE completion cycle instead of the next one.

Fix: the stub is burned while CS is still high (`PACERST`, `CLRP CS`, `PACE`,
then the bit loop), mode 3 raises SCK one cycle before CS and burns its stub
before the first falling edge, and each phase is laid out as
"level-setting instruction first, PACE last" with the PACE side-set carrying
the level of the phase it terminates. Mode 3 counts `r1 = 16..9` and leaves via
`m3end`, so its transfer ends on the rising (sample) edge with SCLK high and
its CS release carries ss=1 (no SCK edge at the CS boundary).

### I2C, `WAITC I2C_HALF = 250` cycles (100 kHz)

RTL, pre-fix baseline vs post-fix, both with the 400-cycle stretch after the
address ACK:

| | before | after |
|---|---|---|
| SCL high phases (min/median/max) | 3 / 248 / 250 | 252 / 252 / 503 |
| SCL low phases (min/median/max) | 4 / 250 / 1684 | 252 / 253 / 1438 |
| rising-edge intervals | `7 / 500 / 1688` | (phases above; steady period 505) |
| phases at one half period | 41 of 56 highs, 44 of 56 lows | 54 of 56 highs, 47 of 56 lows (the rest span a command boundary or the stretch) |
| START setup / hold | 3 / 1 | 252 / 251 |
| repeated START setup / hold | 3 / 1 | 252 / 251 |
| STOP setup / hold (bus free) | 244 / 1 | 252 / 251 |
| high phase after the 400-cycle stretch | 240 | 252 |
| program size | 32 + 32 | 32 + 32 |

The before column is the pre-fix image under its own host setup (period
registers written, `ODSET` in both engines).  The model bench reproduces the
same defect class, and with a stretch applied mid-command it leaves a 23-cycle
high phase behind (on the RTL the 400-cycle ACK stretch leaves 240).

Minima for reference: t_HIGH >= 30 cycles (0.6 us), t_LOW >= 65 cycles
(1.3 us), START/STOP setup and hold >= 40 cycles.  In the fixed image every
phase is at least the programmed 250 cycles; the before column violated all
four minima.

Cause: `PACERST` per command left a 3-cycle first phase, the ACK clock's high
phase was cut short by the instruction that followed `INBIT`, and a stretch
left the pacer grid behind real time so the phases after it were short.

Fix: SCL phases are timed with `WAITC I2C_HALF` (immune to the pacer stub and
to grid drift after a stretch), the ACK clock keeps a full high phase and then
produces an explicit falling edge so the target releases SDA before the next
START, the START is held a full half period before SCL falls, and the STOP is
preceded by a full low and high phase.

## Regression proof: the assertions fail on the pre-fix images

The pre-fix `firmware/spi_master.asm` and `firmware/i2c_master.asm` were put
back temporarily and `cd sim && make protocols` was re-run with the final test
file unchanged:

```
** test_protocols.proteus_spi_master_pins   FAIL      461190.00 ns  **
** test_protocols.proteus_i2c_master_pins   FAIL      867070.00 ns  **
AssertionError: SPI master pins: 24 of 123 checks failed:
  frame 0 SCK half phases [3, 22, 20, 30, 20, 30, 20, 30, 20, 30, 20, 30, 20, 30, 20]
  frame 0 every SCK half phase is 25 cycles, got [...]
  frame 0 CS setup 3
  frame 0 SCK period 0: got 25 expected 50 +-1
AssertionError: I2C master pins: 9 of 30 checks failed:
  every SCL high >= 40 cycles, min 3
  every SCL low >= 65 cycles, min 4
  every SCL high >= the programmed 250 cycles, min 3
  START setup 3 cycles (SCL high before SDA changes)
  START hold 1 cycles (SDA low before SCL falls)
  RSTART setup 3 cycles (SCL high before SDA changes)
  RSTART hold 1 cycles (SDA low before SCL falls)
  high phase after the stretch is a full half period, got 240 cycles

I2C START/STOP setup/hold (cycles): [('START', 3, 1), ('RSTART', 3, 1),
                                     ('STOP', 244, 1)]
I2C run cycle 27752: 56 SCL high phases min/median/max 3/248/250,
  56 low phases min/median/max 4/250/1684
```

The pre-fix I2C image is pacer-driven, so that swap run wrote its two
`EO_PERIOD0` registers (the fixed image does not need them); without them the
old phases collapse to the `PACERST` stub and the failure list would not be
comparable with the before column above.  The test file used for the run is
otherwise the shipped one.

With the fixed images the same test file reports SPI 123/123 and I2C 30/30
checks, and `TESTS=4 PASS=4 FAIL=0`.

## Firmware changes

* `firmware/spi_master.asm` (32 words): stub burned before CS, one PACE per
  phase with the edge first, MISO accumulated with `SHRI r2,5` + `ADC r4,r4`
  (carry holds the sampled bit), mode 3 counter `16..9` plus a `CMPI r1,9` /
  `JZ m3end` exit so the transfer ends on the rising edge, and a per-mode CS
  release (`SETP` with ss=0 for CPOL=0, ss=1 for CPOL=1).
* `firmware/i2c_master.asm` (32 + 32 words): pacer replaced by `WAITC`, one
  full low and high phase per bit with a `WAITP` release in between, ACK clock
  held for a full period then an explicit falling edge, START held a full half
  period, STOP followed by a full bus-free half period, NOP/WRITE/START
  dispatched from `DJNZ r0` (engine 3) and `CMPI/JZ/JC` (engine 2).
* `uart_tx.asm` / `uart_rx.asm`: unchanged; their measured widths already met
  the contract (bit period 434.027, start deltas 4343 vs ideal 4340.27).

## Host contract changes

* `UIO_OD` (`0x0523`) is one fabric-wide register: the host writes `0xC0`
  before RUN instead of both I2C engines writing `ODSET`.
* The I2C image times its SCL phases with a compiled `WAITC I2C_HALF`, so its
  engine period registers are unused (the SPI and UART images still use the
  pacer and the host period bytes). Changing the I2C rate means rebuilding with
  another `I2C_HALF`; anything >= 65 cycles meets the fast-mode minima.
* Both I2C engines are 32 words, as before (the rewrite redistributed them);
  `spi_master.asm` still uses exactly 32.
