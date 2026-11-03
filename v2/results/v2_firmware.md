# v2 hybrid firmware: protocol port + a complete 802.3 frame in 31 words

Status: **PASS**, at the *cycle-model* level.

```
$ python3 v2/demos/run_v2.py ; echo EXIT=$?
... 115 checks PASS, 0 FAIL, 115 total
EXIT=0
```

Every assertion below is decoded from the pads by an independent device model in
`v2/demos/run_v2.py` (16x UART receiver, 8N1 source, SPI mode-0 slave with an
inverting loopback, I2C target with ACK/NACK and clock stretching, MII PHY that
clocks TX_CLK and samples on the rising edges, and `zlib.crc32` for the FCS).
Nothing is read out of engine registers except the FIFOs the host is documented
to read and the `E_ERROR`/timeout/`nf` flags.

## 1. Images and word counts

| image | engines | words | limit | verdict |
|---|---|---:|---:|---|
| `v2/firmware/uart_tx.asm` | 0 | 18 | 32 | PASS |
| `v2/firmware/uart_rx.asm` | 1 | 26 | 32 | PASS |
| `v2/firmware/spi_master.asm` | 2 | 32 | 32 | PASS (exactly full) |
| `v2/firmware/i2c_master.asm` | 2 + 1 | 32 + 32 | 32 each | PASS |
| `v2/firmware/ethernet_mii_tx.asm` | 0 | 31 | 32 | PASS |

Counts come straight from the assembler (`v2/tools/asm.py`, `PROG_DEPTH = 32`),
not from a comment:

```
uart_tx            {0: 18}
uart_rx            {1: 26}
spi_master         {2: 32}
i2c_master         {1: 32, 2: 32}
ethernet_mii_tx    {0: 31}
```

The four protocol images are the v1 images instruction-for-instruction; the only
edit is the engine map for I2C (v1 engines 3+2 -> v2 engines 2+1).  That remap is
not a renumber: v2's pin merge gives the highest engine index priority, so a
straight `3 -> 1` would put START/WRITE *below* the READ/STOP image, whose parked
side-set drives SCL low every cycle, and the bus would never clock.  The halves
therefore swap (`START/WRITE` on engine 2, `READ/STOP` on engine 1) and both keep
the v1 IRQ tokens.  Derivation and the address map: `v2/firmware/README.md`.

## 2. Ethernet: how 230 words became 31

v1 measured (`results/ethernet.md`) 230 words for the complete frame emitter:
32 as shipped (preamble, SFD, a 46-byte counter payload, IFG) + 154 for the 14
header bytes + 44 for the 4 FCS bytes -- about 11 words per constant byte,
because a nibble costs an `OUTP` and two `WAITP` and there is nowhere to store
the frame.  The hybrid build moves the *data* out of the code:

| region | words | why it is that cheap |
|---|---:|---|
| entry | 3 | `CFG SIDE`, one `WAITP` on the high phase (so the next `WAITP(0)` lands on a low-phase boundary and the frame never starts mid-nibble), `JMP` into the byte preparation |
| per-byte stream loop | 14 | under-run check 3 (`LDAS` STATUS, `ANDI` on the empty bit, branch -- run in the *high* phase where register work is free), pop/fold/rotate 3, `WAITP(0)` 1, two nibble slots 6 (`OUTP`,`WAITP(1)`,`WAITP(0)` each), `DJNZ` 1 |
| leave the loop | 1 | `JMP fcs` when the byte count expires |
| FCS pass | 10 | `DJNZ r3` (phase: `1 -> 0` does not branch, `0 -> 0xFF` later branches to the IFG -- no compare, no flag store), four `LDAS`/`STAS` pairs pushing the CRC result back through the FIFO, `LDI r2,4`; the 14-word loop above then emits it |
| IFG + park | 3 | `CLRP` (TX_EN/TXD low via side-set 0), `WAITC 480` = 96 bit times, `HALT` |
| **total** | **31** | |

Three decisions did the work:

1. **The frame comes from the FIFO, so code size is independent of frame
   length.**  A 46-byte payload and a 1500-byte payload cost the same 7 words.
2. **The 8 preamble/SFD bytes ride the same loop.**  The host presets
   `crc_init` to the pre-image of `0xFFFFFFFF` under `55 x7, D5`, so folding the
   header is a no-op and the body folds from the standard init.  Verified in the
   demo: `fold(0x26B6A4C8, header) == 0xFFFFFFFF`.  One loop, one code path.
3. **The FCS is recycled through the FIFO instead of being unrolled.**  Reading
   the four result lanes and pushing them back costs 8 words; emitting four bytes
   as separate unrolled sequences would have cost 32.  The same 14-word loop
   emits them, so the FCS costs code only for the *handover*, never per byte.

## 3. Host contract (Ethernet)

Full text in `v2/firmware/README.md`; the model-level form is
`host_setup_ethernet()` in the demo.

1. CRC assist: `cfg0 = 0xE0` `{lsb=1, refl=1, width=32}`; page init = the
   pre-image; poly = `0xEDB88320`; xorout = `0xFFFFFFFF`; start; page back to the
   result.
2. FIFO assist: clear.
3. Engine 0 `r2` = byte count (68 for this frame), `r3` = 1.
4. RUN engine 0.
5. Push exactly `r2` bytes in wire order (`55 x7, D5, dst, src, ethertype,
   payload`), never letting the queue empty: the program aborts the frame rather
   than emitting a stale byte.
6. Then the engine appends the FCS and parks.

Preconditions worth stating: at least one byte must be in the FIFO before RUN
(the check runs before the first pop); the host must stop at exactly `r2` bytes
(the FCS pass re-uses the queue); `r2` is 8-bit, so the body is limited to 247
bytes; and the image assumes it **owns** the assist FIFO -- the queue has one
data port shared by all three engines, so a second engine popping or pushing it
would corrupt the stream.

## 4. Decoded evidence

Frame under test: `dst 02:00:00:00:00:01`, `src 02:00:00:00:00:02`,
`ethertype 0x0800`, payload `0x00..0x2D` (46 bytes) -- 60 bytes, 64 with the FCS,
i.e. the 802.3 minimum frame.

| item | value |
|---|---|
| wire bytes | 72 (8 header + 60 body + 4 FCS) = 144 nibbles |
| preamble / SFD at the pads | `55 55 55 55 55 55 55` / `d5` |
| dst / src / ethertype | `02 00 00 00 00 01` / `02 00 00 00 00 02` / `08 00` |
| payload | `00 01 02 ... 2b 2c 2d` (46 bytes, byte-exact) |
| FCS on the wire (LSB first) | `0xE7C87B32` |
| `zlib.crc32(dst..payload)` | `0xE7C87B32` |
| CRC init pre-image | `0x26B6A4C8`, `fold(pre, header) = 0xFFFFFFFF` |
| UART TX bytes / UART RX bytes | `00 ff 55 aa 41` / `55 00 ff 81 7e a5 5a 3c 00` + 1 re-sync byte |
| SPI MOSI -> MISO | `00->ff, ff->00, 5a->a5, a5->5a, 81->7e, 7e->81` |
| I2C at the pads | START, RSTART, STOP; ACKs `0,0,0,0,0,1`; writes `5a a5`; reads `11 22` |

`0xE7C87B32` is the same value v1's `results/ethernet.md` records for this frame,
produced there by a 32-word software CRC engine and here by the CRC assist --
the two paths agree on the vector.

### Timing measured at the pads

| path | measurement | requirement |
|---|---|---|
| MII nibble rate | one nibble per 20 cycles = 2.5 MHz = 10 Mbit/s | PHY TX_CLK |
| MII setup | 8 cycles (160 ns) before every sampling edge | >= 25 ns |
| MII hold | 11 cycles (220 ns) after every sampling edge except the last | >= 25 ns |
| MII TXD discipline | 0 changes while TX_CLK is high | TXD changes in the low phase only |
| TX_EN | one contiguous window, exactly 144 of 209 rising edges, parked low after | frame only |
| IFG | 24 idle nibble times (480 cycles) before HALT | 96 bit times |
| UART TX pacing | frame starts 4343 cycles apart (ideal 4340.27) | +-6 |
| SPI half phases | every one exactly 25 cycles, 16 edges per transfer | host-programmed |
| I2C SCL | 55 high phases, min 252 / max 503 cycles (the stretch) | >= 30 high, >= 65 low |
| FIFO | level reached 16 (the assist depth), zero starved cycles | never empty |

The under-run test is a deliberate negative: with a host that pushes one byte per
60 cycles (slower than the 40-cycle wire byte) the emitter stops after 2 nibbles,
parks TX_EN/TXD, runs the IFG and halts -- and the two nibbles it did emit are an
exact prefix of the frame.  No stale byte, no partial FCS.

## 5. Full check table

```
scenario       check                                                       expected                                       got                                            result
---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
UART TX e0     program words <= 32                                         <=32                                           18                                             PASS
UART TX e0     program words                                               18                                             18                                             PASS
UART TX e0     decoded bytes                                               00 ff 55 aa 41                                 00 ff 55 aa 41                                 PASS
UART TX e0     one frame per queued byte                                   5                                              5                                              PASS
UART TX e0     every stop bit high                                         True                                           True                                           PASS
UART TX e0     frame start deltas (cycles, ideal 4340.27)                  -                                              [4343, 4343, 4343, 4343]                       PASS
UART TX e0     frame pacing within +-6 cycles                              True                                           True                                           PASS
UART RX e1     program words                                               26                                             26                                             PASS
UART RX e1     bytes popped from OUT_FIFO                                  55 00 ff 81 7e a5 5a 3c 00                     55 00 ff 81 7e a5 5a 3c 00                     PASS
UART RX e1     one re-sync byte after the error frame                      1                                              1                                              PASS
UART RX e1     re-sync byte (line sampled high)                            -                                              ff                                             PASS
UART RX e1     framing-error frame set E_ERROR                             1                                              1                                              PASS
UART RX e1     no WAITP timeout                                            0                                              0                                              PASS
UART RX e1     error frame stop bit low at the pad                         0                                              0                                              PASS
SPI e2         program words                                               32                                             32                                             PASS
SPI e2         OUT_FIFO echoes ~MOSI                                       ff 00 a5 5a 7e 81                              ff 00 a5 5a 7e 81                              PASS
SPI e2         one CS-framed transfer per byte                             6                                              6                                              PASS
SPI e2         no mode-0 / CS-framing violations                           0                                              0                                              PASS
SPI e2         frame 0 edges                                               16                                             16                                             PASS
SPI e2         frame 0 rises/falls                                         8/8                                            8/8                                            PASS
SPI e2         frame 0 CPOL=0 at CS                                        0                                              0                                              PASS
SPI e2         frame 0 MOSI at pads                                        00                                             00                                             PASS
SPI e2         frame 0 MISO at pads                                        ff                                             ff                                             PASS
SPI e2         frame 0 every half phase 25 cycles                          True                                           True                                           PASS
SPI e2         frame 0 CS setup/hold >= half                               True                                           True                                           PASS
SPI e2         frame 1 edges                                               16                                             16                                             PASS
SPI e2         frame 1 rises/falls                                         8/8                                            8/8                                            PASS
SPI e2         frame 1 CPOL=0 at CS                                        0                                              0                                              PASS
SPI e2         frame 1 MOSI at pads                                        ff                                             ff                                             PASS
SPI e2         frame 1 MISO at pads                                        00                                             00                                             PASS
SPI e2         frame 1 every half phase 25 cycles                          True                                           True                                           PASS
SPI e2         frame 1 CS setup/hold >= half                               True                                           True                                           PASS
SPI e2         frame 2 edges                                               16                                             16                                             PASS
SPI e2         frame 2 rises/falls                                         8/8                                            8/8                                            PASS
SPI e2         frame 2 CPOL=0 at CS                                        0                                              0                                              PASS
SPI e2         frame 2 MOSI at pads                                        5a                                             5a                                             PASS
SPI e2         frame 2 MISO at pads                                        a5                                             a5                                             PASS
SPI e2         frame 2 every half phase 25 cycles                          True                                           True                                           PASS
SPI e2         frame 2 CS setup/hold >= half                               True                                           True                                           PASS
SPI e2         frame 3 edges                                               16                                             16                                             PASS
SPI e2         frame 3 rises/falls                                         8/8                                            8/8                                            PASS
SPI e2         frame 3 CPOL=0 at CS                                        0                                              0                                              PASS
SPI e2         frame 3 MOSI at pads                                        a5                                             a5                                             PASS
SPI e2         frame 3 MISO at pads                                        5a                                             5a                                             PASS
SPI e2         frame 3 every half phase 25 cycles                          True                                           True                                           PASS
SPI e2         frame 3 CS setup/hold >= half                               True                                           True                                           PASS
SPI e2         frame 4 edges                                               16                                             16                                             PASS
SPI e2         frame 4 rises/falls                                         8/8                                            8/8                                            PASS
SPI e2         frame 4 CPOL=0 at CS                                        0                                              0                                              PASS
SPI e2         frame 4 MOSI at pads                                        81                                             81                                             PASS
SPI e2         frame 4 MISO at pads                                        7e                                             7e                                             PASS
SPI e2         frame 4 every half phase 25 cycles                          True                                           True                                           PASS
SPI e2         frame 4 CS setup/hold >= half                               True                                           True                                           PASS
SPI e2         frame 5 edges                                               16                                             16                                             PASS
SPI e2         frame 5 rises/falls                                         8/8                                            8/8                                            PASS
SPI e2         frame 5 CPOL=0 at CS                                        0                                              0                                              PASS
SPI e2         frame 5 MOSI at pads                                        7e                                             7e                                             PASS
SPI e2         frame 5 MISO at pads                                        81                                             81                                             PASS
SPI e2         frame 5 every half phase 25 cycles                          True                                           True                                           PASS
SPI e2         frame 5 CS setup/hold >= half                               True                                           True                                           PASS
SPI e2         no SCK edge between transfers                               0                                              0                                              PASS
I2C e2+e1      engine 2 words                                              32                                             32                                             PASS
I2C e2+e1      engine 1 words                                              32                                             32                                             PASS
I2C e2+e1      bus events                                                  START,RSTART,STOP                              START,RSTART,STOP                              PASS
I2C e2+e1      target ACKs then master ACK/NACK                            000001                                         000001                                         PASS
I2C e2+e1      write data at the pads                                      5a a5                                          5a a5                                          PASS
I2C e2+e1      read bytes served at the pads                               11 22                                          11 22                                          PASS
I2C e2+e1      engine 2 OUT_FIFO ACKs                                      00 00 00 00                                    00 00 00 00                                    PASS
I2C e2+e1      engine 1 OUT_FIFO read bytes                                11 22                                          11 22                                          PASS
I2C e2+e1      one clock stretch                                           1                                              1                                              PASS
I2C e2+e1      stretch held SCL low 400 cycles                             400                                            400                                            PASS
I2C e2+e1      no open-drain collision flagged                             0                                              0                                              PASS
I2C e2+e1      no engine timeout flags                                     0                                              0                                              PASS
I2C e2+e1      no engine E_ERROR                                           0                                              0                                              PASS
I2C e2+e1      SCL high phases (cycles)                                    -                                              n=55 min=252 max=503                           PASS
I2C e2+e1      every SCL high >= I2C_HALF-2                                True                                           True                                           PASS
I2C e2+e1      every SCL low >= I2C_HALF-2                                 True                                           True                                           PASS
I2C e2+e1      START/STOP setup+hold >= 40                                 True                                           True                                           PASS
I2C e2+e1      SDA released after STOP                                     True                                           True                                           PASS
ETH TX e0      program words <= 32                                         <=32                                           31                                             PASS
ETH TX e0      program words                                               31                                             31                                             PASS
ETH TX e0      engine halted                                               True                                           1                                              PASS
ETH TX e0      host byte count                                             68                                             68                                             PASS
ETH TX e0      FIFO depth reached (16-deep assist FIFO)                    16                                             16                                             PASS
ETH TX e0      starved cycles while the host still had bytes               0                                              0                                              PASS
ETH TX e0      engine nf_flag (failed FIFO read)                           0                                              0                                              PASS
ETH TX e0      no pad collision                                            0                                              0                                              PASS
ETH TX e0      TX_EN nibbles                                               144                                            144                                            PASS
ETH TX e0      nibble stream (preamble|SFD|frame|FCS)                      True                                           True                                           PASS
ETH TX e0      preamble 7 x 0x55                                           55 55 55 55 55 55 55                           55 55 55 55 55 55 55                           PASS
ETH TX e0      SFD 0xD5                                                    d5                                             d5                                             PASS
ETH TX e0      dst MAC                                                     02 00 00 00 00 01                              02 00 00 00 00 01                              PASS
ETH TX e0      src MAC                                                     02 00 00 00 00 02                              02 00 00 00 00 02                              PASS
ETH TX e0      ethertype                                                   08 00                                          08 00                                          PASS
ETH TX e0      payload                                                     00 01 02 03 04 05 06 ... 27 28 29 2a 2b 2c 2d  00 01 02 03 04 05 06 ... 27 28 29 2a 2b 2c 2d  PASS
ETH TX e0      FCS on the wire (LSB first)                                 e7c87b32                                       e7c87b32                                       PASS
ETH TX e0      FCS recomputed by zlib.crc32 over dst..payload              e7c87b32                                       e7c87b32                                       PASS
ETH TX e0      frame bytes on the wire                                     64                                             64                                             PASS
ETH TX e0      TX_EN one contiguous window                                 True                                           True                                           PASS
ETH TX e0      TX_CLK rising edges total / with TX_EN high                 -                                              209 / 144                                      PASS
ETH TX e0      min TXD/TX_EN setup at a sampling edge >= 8 cycles          True                                           True                                           PASS
ETH TX e0      measured min setup (cycles)                                 -                                              8                                              PASS
ETH TX e0      min TXD/TX_EN hold after a sampling edge >= 10 cycles       True                                           True                                           PASS
ETH TX e0      measured min hold (cycles)                                  -                                              11                                             PASS
ETH TX e0      hold after the final sampling edge (TX_EN release)          -                                              4                                              PASS
ETH TX e0      TXD changes only while TX_CLK is low                        0                                              0                                              PASS
ETH TX e0      IFG >= 24 nibble times (802.3, 96 bit times)                True                                           True                                           PASS
ETH TX e0      idle nibble times after the last frame nibble               -                                              24                                             PASS
ETH TX e0      TX_EN and TXD parked low after the frame                    0                                              0                                              PASS
ETH under-run  engine halted after the abort                               True                                           1                                              PASS
ETH under-run  frame truncated (no FCS emitted)                            True                                           True                                           PASS
ETH under-run  emitted nibbles are an exact prefix of the frame            True                                           True                                           PASS
ETH under-run  nibbles emitted before the abort (of 144)                   -                                              2                                              PASS
ETH under-run  host bytes pushed before HALT (feeder ran through the IFG)  -                                              9 of 68                                        PASS
ETH under-run  TX_EN dropped (pins parked) after the abort                 0                                              0                                              PASS
---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
115 checks PASS, 0 FAIL, 115 total
```

## 6. Limitations

* **Model level.**  This is `v2/tools/model.py`, the executable spec.  Not
  covered here, and covered instead by the RTL benches in `v2/tb/`: the SPI host
  port itself, the assist CSR window and its byte lanes (`tb_csr`,
  `tb_top_smoke`), the CRC/FIFO/shift blocks (`tb_crc_bit`, `tb_fifo`,
  `tb_shiftreg`) and the NRZI/Manchester line codes (`tb_nrzi`, `tb_nrzi_wave`,
  `tb_manchester`).  No RTL was run for this report.
* **The Ethernet path is host-bandwidth-bound, not instruction-bound.**  The
  model's feeder tops the FIFO up every cycle, so it verifies ordering, the CRC,
  the FIFO protocol and the MII timing -- not host throughput.  The arithmetic
  says sustained 10 Mbit/s needs one host byte per 0.8 us:

  | SPI SCK | host byte time (one `WRITE_INC` frame, 8 bits/byte) | FIFO drains |
  |---|---|---|
  | 3.125 MHz | 2.56 us | 16 - (1.25 - 0.39) t -> empty after ~18.6 us (~23 wire bytes) |
  | 6.25 MHz (`clk/8`, "fully clean" per `proteus_host.v`) | 1.28 us | empty after ~34 us (~42 wire bytes) |
  | 10 MHz (`clk/5`) | 0.80 us | break-even |

  So a 64-byte frame at a true 10 Mbit/s cannot be sustained by the default SPI
  host port: at the clean clock limit the FIFO starves about two thirds of the
  way in.  A 16-byte FIFO is 12.8 us of wire time, not the ~51 us a 3.2 us/byte
  wire assumption implies (10 Mbit/s is 0.8 us/byte).  Options, none in scope
  here: push SCK past `clk/8` (the host's synchroniser is documented as short by
  one clk at `clk/4`), widen the host path, or source the frame from on-chip
  storage instead of SPI.
* **Frame sizes.**  `r2` is an 8-bit register: body 1..247 bytes (the FCS pass
  needs four free queue slots).  The firmware makes no padding decision -- the
  host must send a >= 46-byte payload for a legal minimum frame.
* **No receive path.**  RXD/RX_DV/RX_CLK are neither driven nor sampled; no
  MDIO/MDC, no carrier sense, no collision/jam.  This is an MII MAC TX path to an
  external PHY.
* **SPI mode 3 is implemented but not exercised** by the v2 demo (the mode-0
  slave model has no CPOL=1 variant).  v1's RTL bench also exercised mode 0 only;
  the mode-3 path is unchanged from the v1 image that v1 shipped.
* **USB LS device skeleton (task 4) not delivered.**  `v2/tools/model.py`
  deliberately does not model the NRZI wire (SYNC/stuffing/SE0) or the Manchester
  line codes -- only "the *register, queue and timing* accounting" -- and its
  NRZI queue exposes occupancy, not the byte pushed.  A SOF/SETUP handshake could
  therefore only be checked against an occupancy counter, which would be a pass
  that proves nothing about USB.  The line-code evidence lives in
  `tb_nrzi`/`tb_nrzi_wave` instead; extending the model would be a larger change
  to `v2/tools/model.py` than the FIFO-depth fix below and is out of this task's
  file scope.

## 7. Defects found

1. **`v2/tools/model.py` modelled the assist FIFO as 4 deep.**
   `Assist.read`/`write` used the *engine* FIFO constant (`FIFO_DEPTH = 4`) for
   the assist queue, so STATUS reported `full` at level 4 and pushes above 4 were
   dropped, while `v2/src/assist_fifo.v` is `DEPTH = 16` with a 5-bit level
   (`full` at 16).  Fixed minimally: a separate `AS_FIFO_DEPTH = 16` used only by
   the assist block.  The Ethernet demo now proves the 16-deep behaviour (the
   level reaches 16) and `v2/tools/selfcheck.py` still passes.  No RTL change.
2. **I2C remap trap (design finding, no RTL defect).**  A pure `3 -> 1` engine
   renumber would deadlock the bus because the merge priority is by index; see
   section 1.  The port swaps the halves instead.  Recorded so nobody
   "simplifies" it back.

## 8. Exact commands

```sh
cd /home/ubuntu/verilog

# the acceptance run (exit 0 required)
python3 v2/demos/run_v2.py ; echo EXIT=$?

# same run plus per-frame / per-transfer detail
python3 v2/demos/run_v2.py -v

# word counts
python3 - <<'PYEOF'
import sys; sys.path.insert(0, 'v2/tools')
import asm
for n in ('uart_tx', 'uart_rx', 'spi_master', 'i2c_master', 'ethernet_mii_tx'):
    r = asm.assemble_file(f'v2/firmware/{n}.asm')
    print(n, {e: len(w) for e, w in sorted(r['programs'].items())})
PYEOF

# model still agrees with the RTL vectors (after the assist-FIFO depth fix)
python3 v2/tools/selfcheck.py        # -> SELFCHECK PASS

# RTL benches (not run for this report; already green per the v2 phase-1 cut)
bash v2/tb/run.sh
```
