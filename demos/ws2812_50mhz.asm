; PROTEUS demo -- WS2812 / NeoPixel driver, engine 1 (50 MHz sign-off clock)
; =============================================================================
; Same program as demos/ws2812.asm, retimed for CLK_HZ = 50_000_000 (the clock
; declared in info.yaml, i.e. the one the silicon actually runs at).  The bit
; cell is 1.25 us = 62.5 cycles, which is *fractional*; the pacer carries the
; remainder, so the mean period is exactly 62.5 cycles with +-1 cycle jitter
; (20 ns) and no drift.
;
; Timing at 50 MHz
;   period 1.25 us  = 62.5 cycles -> pacer period 16000 = 0x00003E80 (62.5 in
;                    24.8 fixed point).  Completion instants alternate
;                     62/63/63/62... with a mean of exactly 62.5.
;   T0H    0.40 us  = 20.0 cycles -> 20 cycles = 400 ns (exact)
;   T1H    0.80 us  = 40.0 cycles -> 40 cycles = 800 ns (exact)
;   T0L = 62.5 - 20 = 42.5 cycles = 850 ns
;   T1L = 62.5 - 40 = 22.5 cycles = 450 ns
;   Both high times land exactly on the WS2812B nominal, and the period error is
;   zero on average (the only imperfection is the 1-cycle grid jitter).
;
; Everything else -- pins, side-set encoding, FIFO contract, host period write
; -- is identical to demos/ws2812.asm; see that file for the full description.
;
; Instruction count: 18 words (fits the 32-word default).
; =============================================================================

    .engine 1

    CFG SIDE, 0xC8             ; 0  side-set -> UIO[2] = DATA
pixel:
    LDI r2, 3                  ; 1  bytes per pixel: G, R, B
    LDI r1, 8                  ; 2  bits per byte
    PULL r0                    ; 3  first byte (blocks; line low = reset gap)
    PACERST                    ; 4  arm the bit grid
    PACE                       ; 5  priming completion, absorbed
bit:
    PACE                       ; 6  grid: start of this bit cell
    ROLI r0, 1                 ; 7  MSB -> bit 0 (and into C)
    JC one                     ; 8
    [ss=1] WAITC 20            ; 9  T0H = 20 cycles = 400 ns
    JMP cont                   ; 10
one:
    [ss=1] WAITC 40            ; 11 T1H = 40 cycles = 800 ns
cont:
    DJNZ r1, bit               ; 12
    DJNZ r2, nextb             ; 13
    JMP pixel                  ; 14
nextb:
    PULL r0                    ; 15 next byte of this pixel
    LDI r1, 8                  ; 16
    JMP bit                    ; 17
