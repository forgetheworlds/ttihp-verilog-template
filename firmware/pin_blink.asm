; PROTEUS firmware -- pin blinker, engine 0
; =============================================================================
; Pin
;   BLINK     UIO[0]  push-pull output (SETP/TOGP auto-enable OE)
;
; Engine configuration
;   This program does NOT set the pacing period: the host (the DE2 boot loader)
;   writes engine-0 period bytes 0x0C..0x0F before RUN, exactly like the SPI and
;   I2C demos.  Two rates are used, selected by DE2 SW[2]:
;     SW[2]=0  period = 0xBEBC2000 -> 12 500 000 cycles = 250 ms at 50 MHz
;              (2 Hz blink, visible on LEDG0)
;     SW[2]=1  period = 0x00200000 -> 8 192 cycles = 163.84 us at 50 MHz
;              (scope / simulation rate: an edge every 8 192 cycles)
;   The pacer carries the fractional part in next_frac, so the edge spacing is
;   exactly 8192 cycles (fast) or exactly 12 500 000 cycles (slow) with no
;   accumulated drift, and 32-bit next_int keeps this valid for the full
;   ~2^32-cycle timebase.
;
; Host register contract
;   Nothing is pushed or pulled; the engine free-runs and never halts, so the
;   host observes progress purely through the BLINK pad (and the wrapper's edge
;   counter).  Set the RUN bit after programming the period.
;
; Instruction count: 5 words (fits the 32-word default).
; =============================================================================

    .engine 0

    SETP UIO, 0x01             ; drive BLINK high, enable the output
    PACERST                    ; arm the pacer on the current cycle
loop:
    PACE                       ; one pacer period
    TOGP UIO, 0x01             ; invert BLINK
    JMP loop
