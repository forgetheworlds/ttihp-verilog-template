; PROTEUS v2 (hybrid) firmware -- SPI master, engine 2
; =============================================================================
; PORT NOTE (v1 firmware/spi_master.asm -> v2)
;   Unchanged: 32 words (all of PROG_DEPTH), pin map, mode 0 / mode 3 handling,
;   side-set clocking, pacer arming, host contract.  No assist and no v2-only
;   opcode, so the image is instruction-for-instruction the v1 one; the window
;   and program addresses happen to be identical too (engine 2 in both builds),
;   only the program base changes from 0x0300 in v1 to 0x0300 in v2 (0x0100 +
;   0x100*2), i.e. also identical.  Listed here so the file is self-contained.
;
; Pins (modes 0 and 3, 8-bit, MSB first)
;   SCK       UIO[2]  side-set driven: the clock level is part of every
;                     instruction encoding, so a clock edge costs no slot
;   MOSI      UIO[3]  BITPIN target: OUTBIT drives bit 0 of r0, which holds
;                     the byte rotated left by one per bit (MSB first)
;   MISO      UIO[4]  read with INPR UIO,0x10; SHRI r2,5 moves the sampled
;                     bit into the carry and ADC r4,r4 shifts it into r4
;   CS_N      UIO[5]  asserted low for the whole byte
;
; Engine configuration
;   CFG SIDE   = 0xC8 -> side-set enabled, bank UIO, base 2, width 1 (SCK)
;   CFG BITPIN = 0x98 -> bank UIO, pin 3 (MOSI), no invert
;   CLK_HZ = 50 MHz (info.yaml clock_hz).
;   The host programs the pacing period (period bytes 2..5 of the engine
;   register window) to HALF a bit time in 24.8 fixed point; every SCK phase is
;   exactly one PACE, so the SCLK period is exactly 2 * period:
;       1 MHz : half bit = 25 cycles  -> 6400 = 0x00001900
;       2 MHz : half bit = 12.5 cycles -> 3200 = 0x00000C80
;   Timing contract (measured at the pads)
;     * CS_N is low before the first SCK edge and stays low until after the
;       last one.
;     * every SCK high and every SCK low phase measures exactly `period`
;       cycles (>= the programmed half period) -- including the first high
;       phase of a transfer; there is no short stub phase.
;     * exactly 8 rising and 8 falling edges per transfer, so a slave counting
;       edges inside CS sees 8 clock pulses in both modes.
;     * a phase occupies at most 9 instruction slots, so `period` must be
;       >= 9 cycles (SCLK <= CLK_HZ/18) for the phases to stay on the grid.
;
; How the pacer is armed
;   PACE completes on the first cycle where cycle >= next, and PACERST sets
;   next = cycle, so the PACE issued right after PACERST completes at once: it
;   is a one-cycle stub.  The stub is burned while CS_N is still high, which is
;   the only way to make the first real phase a full period.  Every following
;   PACE completion is exactly `period` cycles after the previous one.
;   Each phase is then laid out as "level-setting instruction first, PACE
;   last": the level changes on the cycle the instruction after the PACE
;   completion issues, and the next completion is one period later, so the high
;   and the low phase both measure exactly `period` at the pad.
;
; Mode selection (host writes engine-2 r7 before setting RUN)
;   r7 = 0x00 -> SPI mode 0 (CPOL=0, CPHA=0)
;   r7 nonzero -> SPI mode 3 (CPOL=1, CPHA=1)
;   Only "zero / nonzero" is tested.  A host that never writes r7 gets mode 0
;   (reset value 0).
;
; Host register contract (v2 hybrid top)
;   window    : engine 2 = 0x0010 + 0x20*2 = 0x0050
;   program   : 0x0100 + 0x100*2 + i*4 + b (words 0..31) = 0x0300
;   IN_FIFO   0x0060 : write a MOSI byte; consumed one per transfer
;   OUT_FIFO  0x0061 : read the MISO byte captured by the transfer
;   r7        0x005B : mode select
;   period    0x005C..0x005F : pacing period, 24.8 little endian
;   status    0x0050 : [0] run [2] in_empty [4] out_empty ...
;   A transfer = CS low, 8 SCLK pulses (16 edges), CS high.  The engine blocks
;   in PULL between transfers, so CS stays deasserted while idle.
;
; Protocol notes
;   Mode 0: SCLK idles low and never moves while CS_N is high.  CS asserts with
;           SCLK low; MOSI changes in the low phase; SCLK rises (sample point),
;           then falls.
;   Mode 3: SCLK idles high.  The transfer prologue raises SCLK one cycle
;           before CS asserts (CPOL = 1), CS asserts with SCLK already high,
;           MOSI changes in the low phase after the leading falling edge, SCLK
;           rises (sample point) and falls.  The transfer ends on the eighth
;           rising edge, so CS is released with SCLK high; the hold period is
;           still spent before CS rises.
;   Both modes sample MISO on the rising edge, i.e. at the receiver-defined
;   sampling instant, and hold MOSI stable across it.
;
; Instruction count: 32 words (exactly the 32-word build).
; =============================================================================

    .engine 2

    CFG SIDE,   0xC8           ; side-set -> UIO[2] = SCK
    CFG BITPIN, 0x98           ; OUTBIT -> UIO[3] = MOSI

loop:
    PULL r0                    ; MOSI byte (CS is high here)
    LDI r1, 8
    CMPI r7, 0
    JNZ b3                     ; nonzero -> mode 3

; ---- mode 0: SCLK idles low -----------------------------------------------
    PACERST                    ; deadline grid = this cycle
    CLRP UIO, 0x20             ; assert CS_N while SCLK is low (CPOL = 0)
    PACE                       ; burn the stub: next completion is a period out
    JMP b0l                    ; enter the bit loop at the low phase

; ---- mode 3: SCLK idles high ----------------------------------------------
b3:
    LDI r1, 16                 ; counter values 16..9, never 8..1 (see m3end)
    [ss=1] PACERST             ; raise SCLK (idle level) one cycle before CS
    [ss=1] CLRP UIO, 0x20      ; assert CS_N with SCLK already high (CPOL = 1)
    [ss=1] PACE                ; burn the stub
    [ss=1] PACE                ; first high phase: one full period

; ---- bit loop (both modes): low phase, rising edge, high phase ------------
b0l:
    [ss=0] ROLI r0, 0x01       ; MSB -> bit 0
    [ss=0] OUTBIT r0           ; MOSI changes while SCLK is low
    [ss=0] PACE                ; low phase, exactly one period
    [ss=1] INPR UIO, 0x10, r2  ; MISO sample on the rising edge
    [ss=1] SHRI r2, 0x05       ; bit 4 of the pin mask -> carry, r2 -> 0
    [ss=1] ADC r4, r4          ; accumulate with carry: r4 = 2*r4 + MISO
    [ss=1] CMPI r1, 9          ; mode 3's last bit (values 8..1 never match)
    [ss=1] JZ m3end
    [ss=1] PACE                ; high phase, exactly one period
    [ss=0] DJNZ r1, b0l        ; falling edge; loop while bits remain

; ---- end of transfer ------------------------------------------------------
    PACE                       ; hold SCLK low for a full half period
setp:
    SETP UIO, 0x20             ; deassert CS_N (SCLK low: CPOL = 0)
    JMP pub

m3end:
    [ss=1] PACE                ; complete the last high phase (SCLK high)
    [ss=1] SETP UIO, 0x20      ; deassert CS_N with SCLK high (CPOL = 1)
pub:
    PUSH r4                    ; publish the received byte
    JMP loop
