; PROTEUS v2 (hybrid) firmware -- UART 8N1 transmitter, engine 0
; =============================================================================
; PORT NOTE (v1 firmware/uart_tx.asm -> v2)
;   Unchanged: 18 words, pin map, pacer period, host FIFO contract.  The image
;   uses no assist and no v2-only opcode, so it assembles and runs identically.
;   Only the register/program addresses below are v2 numbers (they are the same
;   for engine 0 as in v1: window 0x0010, program 0x0100).
;
; Pins
;   TX        UIO[0]  (push-pull output, idle high)
;   (engine 0 owns no other pin)
;
; Engine configuration
;   CLK_HZ = 50 MHz (info.yaml clock_hz).
;   CFG BITPIN  = UIO pin 0   -> OUTBIT drives TX from bit 0 of a register
;   CFG PERIOD0..2 = 0x01B207 -> 111111 in 24.8 fixed point
;       CLK_HZ / 115200 baud = 434.02777.. cycles/bit at CLK_HZ = 50 MHz
;       434.02777 * 256 = 111111.11 -> 111111 (0x0001B207)
;       realised bit period = 111111/256 = 434.02734 cycles
;       -> 50e6/434.02734 = 115200.12 baud (+0.0001 % error)
;       The pacer carries the fractional remainder, so the error does not
;       accumulate; completions are floor(c0 + k*period/256), i.e. at most
;       one cycle of jitter and zero drift over any number of frames.
;   WAITC is not used: every bit boundary comes from the deadline pacer.
;
; Host register contract (v2 hybrid top)
;   window    : engine 0 = 0x0010 + 0x20*0 = 0x0010
;   program   : 0x0100 + 0x100*0 + i*4 + b (words 0..17)
;   data in   : write the engine-0 IN_FIFO (window +0x10, i.e. 0x0020); one
;               byte per frame, 4-deep, back-pressures the host when full.
;   status    : engine 0 STATUS (window +0x00) bit[2] in_empty, bit[6] nf,
;               bit[7] timeout.
;   control   : set the engine-0 RUN bit (global 0x0004 bit 0); the engine idles
;               on TX high and blocks in PULL until the host supplies a byte.
;   Only in_fifo is used; out_fifo is untouched.  r0 (the byte) and r1 (the bit
;   counter) are clobbered every frame; r2..r7 are preserved.
;
; Frame format
;   start (low) | d0 d1 ... d7 (LSB first) | stop (high)
;   Each of the 10 bit slots is exactly one pacer period.  The PACERST before
;   the start bit re-arms the deadline grid, so a frame is bit-exact no matter
;   how long the engine idled.  Frames may follow back to back.
;
; Timing argument (why there is no drift)
;   PACERST latches next = cycle<<8.  The immediately following PACE completes
;   in the same cycle it executes (deadline already passed) and rolls next
;   forward by exactly one period, so the *next* PACE stalls until the true
;   boundary.  From then on every completion is floor(c0 + k*period/256);
;   the fractional part is carried in `next`, so 1000 frames accumulate 0
;   cycles of error.
;
; Instruction count: 18 words (fits the 32-word default).
; =============================================================================

    .engine 0

    CFG PERIOD0, 0x07          ; period = 0x0001B207 = 111111 (24.8)
    CFG PERIOD1, 0xB2
    CFG PERIOD2, 0x01
    CFG BITPIN,  0x80          ; bit ops -> UIO[0] = TX
    SETP UIO, 0x01             ; idle high, output enabled

loop:
    PULL r0                    ; block until the host supplies a byte
    PACERST                    ; arm the pacer at the frame start
    CLRP UIO, 0x01             ; START bit (low)
    PACE                       ; first boundary (completes immediately)
    LDI r1, 8
bit:
    PACE                       ; wait out the previous bit slot
    OUTBIT r0                  ; drive d0..d7, LSB first
    SHRI r0, 1
    DJNZ r1, bit
    PACE                       ; hold d7 for its full bit slot
    SETP UIO, 0x01             ; STOP bit (high)
    PACE                       ; stop slot
    JMP loop
