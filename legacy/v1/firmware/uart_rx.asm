; PROTEUS firmware -- UART 8N1 receiver, engine 1
; =============================================================================
; Pins
;   RX        UIO[1]  (input; OE is cleared with DIRC, never auto-enabled
;                      because no instruction writes bit 1)
;
; Engine configuration
;   CLK_HZ = 50 MHz (info.yaml clock_hz).
;   CFG PERIOD0..2 = 0x00D904 -> 55556 in 24.8 fixed point
;       half of 434.02777 cycles = 217.01388 cycles; *256 = 55555.56 -> 55556
;       two half-periods = 434.03125 cycles -> 115200.08 baud (+0.0008 %)
;       The pacer carries the fractional remainder, so the 21 half-periods
;       of a frame are exact to within one cycle (<=1 cycle jitter, no drift).
;   The pacer runs at half-bit resolution so every sample lands on a bit
;   centre: 3 half periods after the detected start edge, then 2 per bit.
;   A 16x software receiver in the testbench recovers every byte for random
;   edge phases.
;
; Host register contract
;   data out  : read the engine-1 OUT_FIFO (host_out_pop); one byte per frame,
;               8-deep; PUSH blocks when the host does not drain.
;   status    : engine 1 STATUS bit[4] out_empty, bit[7] timeout;
;               E_ERROR bit[0] = 1 after a framing error (stop bit sampled 0)
;               and is sticky until the host clears it.
;   control   : set the engine-1 RUN bit.  The engine starts by waiting for a
;               start edge; it must be run before the first start bit.
;   Framing errors: the byte is still pushed so the host never loses data;
;   the error is reported through ASSERT (E_ERROR) only.  After a framing error
;   the engine re-enters WAITP, which matches immediately if the line is still
;   low (a break or a mid-frame glitch) and treats that low level as a new
;   start edge: deliberate for a demo, the next real frame re-synchronises.
;
;   RX has no internal pull-up (the IHP pad cell has none), so the far end must
;   drive the idle-high level; a floating pad would read as a permanent break.
;
; Timing argument
;   WAITP matches the start edge on the cycle the pin is already low, so the
;   first sample is 3 half-periods later = 1.5 bit times from the edge, the
;   centre of d0.  Each following bit costs exactly 2 half-periods, so the
;   stop bit is sampled at 9.5 bit times (the loop's last two PACEs land
;   there, so the stop sample follows the loop directly): the standard midpoint
;   scheme with
;   a +-0.5 bit tolerance, and no accumulation because the pacer carries the
;   fractional remainder.
;
; Instruction count: 26 words (fits the 32-word default).
; =============================================================================

    .engine 1

    CFG PERIOD0, 0x04          ; period = 0x00D904 = 55556 (24.8) = half a bit
    CFG PERIOD1, 0xD9
    DIRC UIO, 0x02             ; RX is an input

loop:
    WAITP UIO, 0x02, 0         ; block until the start edge (RX low)
    PACERST                    ; re-arm the pacer on the edge
    PACE                       ; priming completion (no time passes)
    PACE                       ; 1 half bit
    PACE                       ; 1 bit
    PACE                       ; 1.5 bits -> d0 centre
    LDI r4, 0                  ; received byte
    LDI r1, 8
bit:
    INPR UIO, 0x02, r5         ; sample RX at the centre of this bit
    SHRI r5, 1                 ; 0x02 -> 1, 0x00 -> 0
    SHLI r5, 7
    SHRI r4, 1                 ; shift the accumulator right ...
    OR r4, r5                  ; ... and insert the new bit at bit 7
    PACE                       ; +0.5 bit
    PACE                       ; +1.0 bit -> next centre
    DJNZ r1, bit
    INPR UIO, 0x02, r5         ; stop-bit centre (9.5 bits, the loop's last
                               ; two PACEs already advanced past 9.0/9.5)
    ANDI r5, 0x02
    JNZ ok                     ; framing ok when the stop bit is high
    LDI r6, 1
    ASSERT r6, 0x00            ; force E_ERROR: framing error
ok:
    PUSH r4                    ; publish the byte (blocks if out_fifo is full)
    JMP loop
