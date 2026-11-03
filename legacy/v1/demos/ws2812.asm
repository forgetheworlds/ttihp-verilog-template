; PROTEUS demo -- WS2812 / NeoPixel driver, engine 1 (48 MHz)
; =============================================================================
; Sub-cycle-accurate waveform generation: a 1.25 us bit cell with a 0.40 us or
; 0.80 us high pulse, jitter 0 cycles, drift 0 cycles over the whole frame.
;
; Pins
;   DATA      UIO[2]  side-set driven: bit 2 is part of every instruction's
;                     encoding, so the level changes cost no instruction slot
;                     and cannot jitter.  An instruction without [ss=1] drives
;                     0, i.e. everything that is not a high pulse is low
;                     automatically.
;
; Timing at 48 MHz (CLK_HZ = 48_000_000)
;   period 1.25 us  = 60.000 cycles -> pacer period 60 (host-written)
;   T0H    0.40 us  = 19.2   cycles -> 19 cycles = 395.8 ns
;   T1H    0.80 us  = 38.4   cycles -> 38 cycles = 791.7 ns
;   T0L = 60 - 19 = 41 cycles = 854.2 ns   (nominal 0.85 us)
;   T1L = 60 - 38 = 22 cycles = 458.3 ns   (nominal 0.45 us)
;   WS2812B tolerances are +-150 ns on T0H/T1H and +-600 ns on the period, so
;   every number is inside spec with >= 4x margin.
;
; Mechanism
;   * CFG SIDE = 0xC8 -> side-set on, bank UIO, base 2, width 1 (DATA).
;   * per bit: one PACE fixes the 60-cycle grid, ROLI moves the next GRB MSB
;     into bit 0, JC picks the 19- or 38-cycle high time, and the trailing
;     WAITC low slot is absorbed by the next PACE.
;   * the pacer therefore owns the bit period and WAITC owns the pulse width:
;     both are exact, so edge-to-edge is exactly 60 cycles for all 24 bits of
;     every pixel (verified edge by edge by demos/run_demos.py).
;
; Data path
;   IN_FIFO (+0x10): push G, R, B in that order per pixel, MSB first per byte.
;   Three bytes per pixel = 24 bits.  The engine blocks in PULL when the FIFO
;   is empty and the line then stays low, which is exactly what the >=50 us
;   reset gap needs, so the host only has to leave the FIFO empty between
;   pixels (>= 280 us gives a wide margin).  Keep the FIFO non-empty inside a
;   pixel: a mid-pixel stall would be seen as a reset by the strip.
;
; Host register contract
;   period  (+0x0C..+0x0F) : 60 * 256 = 15360 = 0x00003C00 (24.8, integer part
;                       = 60) -- written before RUN
;   CFG SIDE is set by word 0, nothing else must touch the side-set config
;   any pixel count is allowed; 3 pixels are exercised by run_demos.py
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
    [ss=1] WAITC 19            ; 9  T0H = 19 cycles
    JMP cont                   ; 10
one:
    [ss=1] WAITC 38            ; 11 T1H = 38 cycles
cont:
    DJNZ r1, bit               ; 12
    DJNZ r2, nextb             ; 13
    JMP pixel                  ; 14
nextb:
    PULL r0                    ; 15 next byte of this pixel
    LDI r1, 8                  ; 16
    JMP bit                    ; 17
