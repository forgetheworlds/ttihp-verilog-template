; PROTEUS demo -- autobaud UART 8N1 receiver, engine 0
; =============================================================================
; LEARNS THE BIT PERIOD FROM THE WIRE.  No baud configuration exists anywhere:
; the host is never told a baud rate, divider or period before the first frame.
; The engine measures the start bit against the timestamp grid, publishes the
; measurement, and from then on samples on a pacer grid derived from it.
;
; Pins
;   RX        UIO[1]  input, idle high.  This engine never writes UIO, so the
;                     pad's output enable stays 0 and no auto-OE can fight the
;                     transmitter (the host must not set UIO_OE bit 1 either).
;
; Flow
;   idle:   WAITP low           start edge, ts_event = cycle of the edge
;   poll:   INPR / JZ           spin at 2 cycles/iteration until the line rises
;   MEAS*                       d = (cycle at poll exit) - ts_event
;   PUSH, PUSH                  publish d (lo, hi); the host programs the pacer
;   CMPI / JNC bad              reject an implausible measurement
;   IRQWAIT 0                   wait until the host has loaded the period
;   IRQCLR 0
;   WAITP high, WAITP low       skip the training frame to the next start edge
;   PACERST + 3x PACE           arm at the start edge, prime to 1.5 bit times
;   PACE / INPR x8              sample d0..d7 at their centres, LSB first
;   PACE / INPR                 sample the stop bit
;   PUSH, ASSERT                publish the byte, flag a framing error
;   WAITP high, JMP frame       re-arm on the next start edge (no re-lock)
;
; Why the host writes the pacer instead of the firmware
;   The ISA has no register -> period path: CFG PERIOD0..3 and WAITC both take
;   an *immediate*, so no instruction can load a runtime-measured value into the
;   pacer.  RP2040 is the same shape: PIO cannot set its own clock divider, the
;   CPU does it after a software autobaud.  The bridge is therefore the
;   documented register window: the engine PUSHes the measurement, the host
;   writes the four period bytes (+0x0C..+0x0F) and raises IRQ 0.  Everything
;   after that -- arm, sampling, framing, publishing -- is firmware, and the
;   host still never learns the baud rate: it only forwards T.
;
; Measurement contract
;   d = T + 2 or T + 3 cycles (the 2-cycle INPR/JZ poll quantises the rising
;   edge by up to one cycle), so the host uses T = d - 3 and the worst-case
;   error on the true start width is -1 cycle (0.24 % at 115200, 0.02 % at
;   9600).  Fixed point period written by the host: half a bit,
;   H = T * 128 in 24.8, which is exact for every integer T.
;
; Sample instants (A = cycle of PACERST = start edge + 1, H = T/2)
;   PACE #1 completes at A, #2 at A+H, #3 at A+2H; the loop's PACE completes at
;   A+(3+2k)H and the INPR after it executes one cycle later:
;     d0  at A+3H+1  = start + 1.5T + 2
;     d7  at A+17H+1 = start + 8.5T + 2
;     stop at A+19H+1 = start + 9.5T + 2
;   Every sample is 2 cycles past the exact centre and exactly T further on:
;   +-0.5 bit of margin, no accumulated error.
;
; Stream contract
;   The frame during which the period is learned is a training frame and is
;   discarded, so bit 0 of it must be 1 for the poll to find the d0 edge: send
;   one 0xFF frame to train.  Every later frame is decoded, back to back.
;   A framing error (stop sampled low) sets the sticky E_ERROR flag; the byte
;   is still published so the host never loses data.  The receiver then waits
;   for the line to go high again, which recovers on the next idle gap.
;
; Host register contract
;   OUT_FIFO (+0x11) : lock -> d_lo, d_hi (T = d - 3); then one byte per frame,
;                      8-deep, PUSH blocks while the host does not drain
;   period (+0x0C..+0x0F) : H = T * 128 (24.8), written by the host on lock
;   IRQ line 0 : host sets it after writing the period; the engine clears it
;   E_ERROR (+0x3) : sticky; framing error, or a rejected measurement
;   E_STATUS (+0x0) : [0] run, [2] in_empty, [4] out_empty
;   IN_FIFO : unused
;
; Instruction count: 32 words = the default PROG_DEPTH exactly.
;   Word 31 is the reject path.  It falls through the end of program memory and
;   pc wraps modulo PROG_DEPTH into word 0, so it needs no JMP of its own (this
;   relies on PROG_DEPTH = 32; with 64 the fall-through hits NOP padding first).
; =============================================================================

    .engine 0

idle:
    WAITP UIO, 0x02, 0         ; 0  start edge; ts_event = edge cycle
poll:
    INPR UIO, 0x02, r5         ; 1  0x00 while low, 0x02 when high
    JZ poll                    ; 2
    MEASLO r1                  ; 3  d - ts_event, low byte
    MEASHI r4                  ; 4                high byte
    PUSH r1                    ; 5  publish the measurement: lo, hi
    PUSH r4                    ; 6
    CMPI r4, 0x14              ; 7  d >= 0x1400 (5120 cycles) is implausible
    JNC bad                    ; 8
    IRQWAIT 0                  ; 9  wait for the host to load the period
    IRQCLR 0                   ; 10
    WAITP UIO, 0x02, 1         ; 11 leave the training frame
frame:
    WAITP UIO, 0x02, 0         ; 12 next start edge
    PACERST                    ; 13 arm the pacer on the edge
    PACE                       ; 14 priming completion (deadline already met)
    PACE                       ; 15
    PACE                       ; 16 -> sample grid at 1.5 bit times
    LDI r1, 8                  ; 17 bit counter (r2 needs no init: the eight
                               ;    shifts shift any old byte out completely)
bit:
    PACE                       ; 18
    INPR UIO, 0x02, r5         ; 19 sample RX at the centre of this bit
    SHRI r2, 1                 ; 20
    SHLI r5, 6                 ; 21 0x02 -> 0x80
    OR r2, r5                  ; 22 insert the bit at bit 7 (LSB arrives first)
    PACE                       ; 23
    DJNZ r1, bit               ; 24
    PACE                       ; 25 -> stop-bit centre
    INPR UIO, 0x02, r5         ; 26 stop bit: 0x02 high, 0x00 low
    PUSH r2                    ; 27 publish the byte (blocks while out FIFO full)
    ASSERT r5, 0x02            ; 28 stop bit low -> sticky E_ERROR (framing)
    WAITP UIO, 0x02, 1         ; 29 resynchronise on the line going high
    JMP frame                  ; 30
bad:
    ASSERT r5, 0x01            ; 31 r5 = 0x02 here, so this always sets E_ERROR
