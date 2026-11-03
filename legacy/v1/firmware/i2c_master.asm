; PROTEUS firmware -- I2C master, split over engines 3 and 2
; =============================================================================
; Why two engines
;   The complete master -- START, STOP, repeated START, 7-bit address write
;   with ACK check, byte write with ACK, byte read with ACK/NACK, and clock
;   stretching -- does not fit one 32-word program.  This file is therefore the
;   two-engine split required by the 32-word build:
;
;     engine 3  START / repeated START + WRITE byte + ACK check
;     engine 2  READ byte + ACK/NACK + STOP
;
;   The host routes commands to the right engine; engine 3 writes the address
;   and data bytes, engine 2 reads bytes and ends the transaction.
;
; Pins (open drain, external pull-ups required)
;   SCL       UIO[6]
;   SDA       UIO[7]
;   Engine 3 side-set drives SCL (CFG SIDE = 0xD8: UIO, base 6, width 1);
;   SDA is driven through the bit-pin shortcut (CFG BITPIN = 0xB8).  Engine 2
;   drives SCL through side-set and SDA through the bit-pin shortcut too.
;   Open drain is one fabric-wide register, so the host sets UIO_OD = 0xC0
;   (0x0523) once before RUN instead of both engines setting it.
;
; Clock: WAITC, not the pacer
;   SCL phases are timed with WAITC, not PACE.  Two reasons:
;     * PACE is driven by a deadline grid that PACERST anchors at "now".  The
;       PACE issued immediately after PACERST completes at once (a one-cycle
;       stub), so the first phase of every command was 3 cycles instead of a
;       full half period -- the defect this revision fixes.
;     * a slave stretch (SCL held low, WAITP blocks) leaves that grid behind
;       real time, so the phases after a stretch were short (a 400-cycle
;       stretch produced a 23-cycle high phase).  WAITC counts from the current
;       cycle, so a stretch can only lengthen the low phase, which is exactly
;       what the bus does.
;   WAITC I2C_HALF below is the half period in 50 MHz cycles (info.yaml
;   clock_hz): 250 cycles = 100 kHz SCL.  Fast-mode minima are t_LOW >= 1.3 us
;   = 65 cycles and t_HIGH >= 0.6 us = 30 cycles, so I2C_HALF >= 65 keeps
;   every phase legal; the shipped value is 250.  The host's period register
;   (window +0x0C..0x0F) is not used by this image.
;
; Timing contract, measured at the pads (results/protocol_rtl.md)
;     * every SCL high phase >= I2C_HALF cycles (>= 40)
;     * every SCL low phase >= I2C_HALF cycles (>= 65), and longer when a
;       slave stretches it
;     * START setup (SCL high -> SDA fall), START hold (SDA fall -> SCL fall)
;       and STOP setup (SCL high -> SDA rise) are all >= I2C_HALF cycles
;     * clock stretching honoured: every SCL release is followed by
;       WAITP UIO,0x40,1, so the high phase starts only once SCL is really high
;
; Idle SCL level
;   The fabric registers are shared and the pin merge gives engine 3 priority,
;   so the two engines never fight: whichever one is acting writes SCL every
;   cycle and the other one's value is overridden (engine 3) or simply not
;   driven (engine 3 has side-set off while it is idle).  Both engines drive
;   SCL low when they are not inside a high phase, so an idle engine leaves SCL
;   low, and the next command raises it inside its own phase.  Only the
;   high-phase instructions carry ss=1.
;
; Handoff: IRQ token, not BAR
;   The two engines share SCL/SDA, so exactly one may drive the bus at a time.
;   The cycle model's BAR only advances the engine that arrives last, so a
;   staggered rendezvous deadlocks (verified against tools/model.py).  This
;   firmware uses the IRQ lines as a two-phase token:
;
;     IRQ0 = "bus is free for engine 2"
;     IRQ1 = "bus is free for engine 3"
;
;   Engine 3 sets IRQ1 once at boot, so it owns the bus first.  Each
;   engine's command loop is:
;     PULL r0; IRQWAIT <my token>; IRQCLR <my token>; execute; IRQSET <peer>
;   Command 0x00 is NOP: it consumes the token and passes it back, so the host
;   can give the busy engine a turn even when the other engine has no work.
;   Both engines must be RUN.  The host supplies one command slot to each
;   engine per bus operation (NOP when the engine has nothing to do).
;
; Host command contract
;   engine 3 IN_FIFO / OUT_FIFO:
;     0x00  NOP, pass the token
;     0x01  START; also a repeated START while the bus is active
;     0x02  WRITE: pull the next IN_FIFO byte, send it MSB first, clock the
;           ACK slot and push 0x00 (ACK) or 0x01 (NACK) to OUT_FIFO
;   engine 2 IN_FIFO / OUT_FIFO:
;     0x00  NOP, pass the token
;     0x02  STOP: SCL low, SDA low, SCL high, SDA high; bus free
;     0x04  READ + ACK: sample 8 bits, drive ACK, push the byte to OUT_FIFO
;     0x05  READ + NACK: sample 8 bits, release SDA, push the byte to OUT_FIFO
;   A register write is:  (START, NOP) (WRITE addr, NOP) (WRITE data, NOP)
;                         (NOP, STOP)
;   A register read is:   (START, NOP) (WRITE addr|1, NOP) (NOP, READ+NACK)
;                         (NOP, STOP)
;   Multi-byte reads use 0x04 for all but the last byte, then 0x05.
;
; Word counts: engine 3 = 32, engine 2 = 32 (the 32-word build).
; =============================================================================

    .equ I2C_HALF, 250         ; half period in 50 MHz cycles (100 kHz SCL)

    .engine 3

    CFG BITPIN, 0xB8           ; bit ops -> UIO[7] = SDA
    IRQSET 1                   ; boot token: bus is free for engine 3

e3_loop:
    PULL r0
    IRQWAIT 1
    IRQCLR 1
    CFG SIDE, 0xD8             ; side-set -> UIO[6] = SCL
    DJNZ r0, e3_dsp            ; 0x02 (WRITE) -> 1 -> dispatch; 0x01 -> START
e3_st:
    [ss=1] WAITP UIO, 0x40, 1  ; SCL high, stretch-aware
    [ss=1] WAITC I2C_HALF      ; a full high phase before SDA falls
    [ss=1] CLRP UIO, 0x80      ; SDA falls -> START / repeated START
    [ss=1] WAITC I2C_HALF      ; START hold: SDA stays low a full period first
e3_dsp:
    CMPI r0, 1                 ; a WRITE command was decremented to 1
    JZ e3_wr
e3_pass:
    CFG SIDE, 0                ; park: hand SCL back, it stays low
    IRQSET 0                   ; bus is free for engine 2
    JMP e3_loop

e3_wr:
    PULL r1                    ; byte to transmit
    LDI r2, 8
e3_wl:
    ROLI r1, 1                 ; MSB -> bit 0 for OUTBIT
    OUTBIT r1                  ; SDA holds the low phase
    [ss=0] WAITC I2C_HALF      ; one full low phase
    [ss=1] WAITP UIO, 0x40, 1  ; SCL high, stretch-aware
    [ss=1] WAITC I2C_HALF      ; one full high phase
    DJNZ r2, e3_wl             ; SCL falls here
    SETP UIO, 0x80             ; release SDA for the ACK slot (SCL is low)
    [ss=0] WAITC I2C_HALF      ; one full low phase
    [ss=1] WAITP UIO, 0x40, 1
    [ss=1] INBIT r3            ; 0 = ACK, 1 = NACK
    [ss=1] WAITC I2C_HALF      ; one full high phase
    [ss=0] WAITC I2C_HALF      ; falling edge lets the target release SDA
    PUSH r3
    JMP e3_pass

; =============================================================================
    .engine 2

    CFG SIDE,   0xD8           ; side-set -> UIO[6] = SCL
    CFG BITPIN, 0xB8           ; bit ops -> UIO[7] = SDA

e2_loop:
    PULL r0
    IRQWAIT 0
    IRQCLR 0
    CMPI r0, 2
    JZ e2_sp
    JC e2_pass                 ; r0 < 2: NOP, pass the token back
    LDI r2, 8
e2_rl:
    [ss=0] WAITC I2C_HALF      ; SCL low, the target presents its bit
    [ss=1] WAITP UIO, 0x40, 1  ; SCL high, stretch-aware
    [ss=1] INBIT r3            ; sample on the high phase
    [ss=1] WAITC I2C_HALF      ; one full high phase
    SHLI r4, 1                 ; SCL falls; accumulate
    OR r4, r3
    DJNZ r2, e2_rl
    OUTBIT r0                  ; bit 0: 0 -> ACK, 1 -> NACK (release)
    [ss=0] WAITC I2C_HALF      ; one full low phase
    [ss=1] WAITP UIO, 0x40, 1
    [ss=1] WAITC I2C_HALF      ; one full high phase
    [ss=0] WAITC I2C_HALF      ; falling edge lets the target release SDA
    SETP UIO, 0x80             ; release SDA while SCL is low
    PUSH r4

e2_pass:
    IRQSET 1                   ; bus is free for engine 3
    JMP e2_loop

e2_sp:
    CLRP UIO, 0x80             ; SDA low while SCL is low
    [ss=0] WAITC I2C_HALF      ; one full low phase
    [ss=1] WAITP UIO, 0x40, 1
    [ss=1] WAITC I2C_HALF      ; one full high phase
    [ss=1] SETP UIO, 0x80      ; SDA rises while SCL high -> STOP
    [ss=1] WAITC I2C_HALF      ; bus free: SCL stays high a full period
    JMP e2_pass
