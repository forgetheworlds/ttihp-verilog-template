; PROTEUS v2 (hybrid) firmware -- I2C master, split over engines 2 and 1
; =============================================================================
; PORT NOTE (v1 firmware/i2c_master.asm, engines 3+2 -> v2 engines 2+1)
;
;   Word counts unchanged: 32 + 32.  The bus code is instruction-for-instruction
;   the v1 code; what changes is (a) which engine runs which half and (b) the
;   window/program addresses.
;
;   (a) WHY THE HALVES SWAP, NOT JUST THE INDEX
;   The v1 split put START/WRITE on engine 3 and READ/STOP on engine 2, and the
;   v1 header justifies sharing SCL with the pin-merge rule: "the pin merge
;   gives engine 3 priority, so whichever one is acting writes SCL every cycle
;   and the other one's value is overridden".  Concretely, the READ/STOP image
;   leaves side-set enabled while it is blocked in PULL, so it drives SCL *low*
;   on every cycle it is in flight; the START/WRITE image wins on the high
;   phases only because it has the higher engine index.
;
;   In the hybrid build there are three engines and the merge still gives the
;   *highest index* priority.  A straight 3 -> 1 remap would therefore put
;   START/WRITE on engine 1, i.e. *below* the idle READ/STOP image on engine 2,
;   and the parked engine's continuous SCL-low would hold every high phase down:
;   the bus would deadlock.  The remap that keeps the v1 invariant is to put
;   START/WRITE on engine 2 (the higher index, now the one that wins) and the
;   READ/STOP image on engine 1.  Then:
;     * engine 2 active: its SCL writes win over engine 1's idle low  (v1 rule)
;     * engine 1 active: engine 2 is parked by `CFG SIDE, 0` at st_pass, so it
;       writes SCL nowhere and engine 1 owns the line outright.
;   This is strictly safer than v1: the only engine that ever needs priority is
;   the one that has it, and the parking is explicit on both sides.
;
;   (b) IRQ handoff, renumbered with the engines
;     IRQ1 = "bus is free for the START/WRITE engine" (now engine 2)
;     IRQ0 = "bus is free for the READ/STOP engine"  (now engine 1)
;   Engine 2 sets IRQ1 once at boot, so it owns the bus first.  Each command
;   loop is: PULL r0; IRQWAIT <my token>; IRQCLR <my token>; execute;
;   IRQSET <peer>.  The IRQ *numbers* are unchanged from v1 -- only the engine
;   that waits on each one changed, so the host command stream keeps the same
;   round order (one slot per engine per bus operation, START first).
;   Command 0x00 is NOP: it consumes the token and passes it back, so the host
;   can give the busy engine a turn even when the other engine has no work.
;   Both engines must be RUN.  BAR is not usable here: the cycle model's BAR
;   only advances the engine that arrives last, so a staggered rendezvous
;   deadlocks (verified against tools/model.py in v1).
;
; Pins (open drain, external pull-ups required)
;   SCL       UIO[6]
;   SDA       UIO[7]
;   Both engines drive SCL through side-set (CFG SIDE = 0xD8: UIO, base 6,
;   width 1) and SDA through the bit-pin shortcut (CFG BITPIN = 0xB8).
;   Open drain is one fabric-wide register, so the host sets UIO_OD = 0xC0
;   (0x0523) once before RUN instead of both engines setting it.
;
; Clock: WAITC, not the pacer
;     * PACE is driven by a deadline grid that PACERST anchors at "now"; the
;       PACE issued immediately after PACERST completes at once (a one-cycle
;       stub), so the first phase of every command was short -- a defect v1
;       fixed by moving to WAITC.
;     * a slave stretch (SCL held low, WAITP blocks) leaves a deadline grid
;       behind real time, so the phases after a stretch would be short.
;   WAITC I2C_HALF below is the half period in 50 MHz cycles (info.yaml
;   clock_hz): 250 cycles = 100 kHz SCL.  Fast-mode minima are t_LOW >= 1.3 us
;   = 65 cycles and t_HIGH >= 0.6 us = 30 cycles, so I2C_HALF >= 65 keeps
;   every phase legal; the shipped value is 250.  The engine period register
;   (window +0x0C..+0x0F) is not used by this image.
;
; Timing contract, measured at the pads
;     * every SCL high phase >= I2C_HALF cycles (>= 40)
;     * every SCL low phase >= I2C_HALF cycles (>= 65), longer when stretched
;     * START setup (SCL high -> SDA fall), START hold (SDA fall -> SCL fall)
;       and STOP setup (SCL high -> SDA rise) are all >= I2C_HALF cycles
;     * clock stretching honoured: every SCL release is followed by
;       WAITP UIO,0x40,1, so the high phase starts only once SCL is really high
;
; Idle SCL level
;   Both engines drive SCL low when they are not inside a high phase, so an
;   idle engine that still has side-set enabled leaves SCL low; the START/WRITE
;   engine turns side-set off (`CFG SIDE, 0`) when it parks, so it does not
;   touch SCL while the READ/STOP engine works.
;
; Host command contract (v2 hybrid top)
;   window    : engine 2 = 0x0050, engine 1 = 0x0030
;   program   : 0x0300 (engine 2), 0x0200 (engine 1)
;   engine 2 IN_FIFO 0x0060 / OUT_FIFO 0x0061 (START/WRITE half):
;     0x00  NOP, pass the token
;     0x01  START; also a repeated START while the bus is active
;     0x02  WRITE: pull the next IN_FIFO byte, send it MSB first, clock the
;           ACK slot and push 0x00 (ACK) or 0x01 (NACK) to OUT_FIFO
;   engine 1 IN_FIFO 0x0040 / OUT_FIFO 0x0041 (READ/STOP half):
;     0x00  NOP, pass the token
;     0x02  STOP: SCL low, SDA low, SCL high, SDA high; bus free
;     0x04  READ + ACK: sample 8 bits, drive ACK, push the byte to OUT_FIFO
;     0x05  READ + NACK: sample 8 bits, release SDA, push the byte to OUT_FIFO
;   A register write is:  (START, NOP) (WRITE addr, NOP) (WRITE data, NOP)
;                         (NOP, STOP)
;   A register read is:   (START, NOP) (WRITE addr|1, NOP) (NOP, READ+NACK)
;                         (NOP, STOP)
;   Multi-byte reads use 0x04 for all but the last byte, then 0x05.
;   Each round is (engine-2 slot, engine-1 slot) in that order.
;
; Word counts: engine 2 = 32, engine 1 = 32 (the 32-word build).
; =============================================================================

    .equ I2C_HALF, 250         ; half period in 50 MHz cycles (100 kHz SCL)

; =============================================================================
; Engine 2 -- START / repeated START + WRITE byte + ACK check  (v1 engine 3)
; =============================================================================
    .engine 2

    CFG BITPIN, 0xB8           ; bit ops -> UIO[7] = SDA
    IRQSET 1                   ; boot token: bus is free for the START/WRITE half

st_loop:
    PULL r0
    IRQWAIT 1
    IRQCLR 1
    CFG SIDE, 0xD8             ; side-set -> UIO[6] = SCL
    DJNZ r0, st_dsp            ; 0x02 (WRITE) -> 1 -> dispatch; 0x01 -> START
st_st:
    [ss=1] WAITP UIO, 0x40, 1  ; SCL high, stretch-aware
    [ss=1] WAITC I2C_HALF      ; a full high phase before SDA falls
    [ss=1] CLRP UIO, 0x80      ; SDA falls -> START / repeated START
    [ss=1] WAITC I2C_HALF      ; START hold: SDA stays low a full period first
st_dsp:
    CMPI r0, 1                 ; a WRITE command was decremented to 1
    JZ st_wr
st_pass:
    CFG SIDE, 0                ; park: hand SCL back, it stays low
    IRQSET 0                   ; bus is free for the READ/STOP half
    JMP st_loop

st_wr:
    PULL r1                    ; byte to transmit
    LDI r2, 8
st_wl:
    ROLI r1, 1                 ; MSB -> bit 0 for OUTBIT
    OUTBIT r1                  ; SDA holds the low phase
    [ss=0] WAITC I2C_HALF      ; one full low phase
    [ss=1] WAITP UIO, 0x40, 1  ; SCL high, stretch-aware
    [ss=1] WAITC I2C_HALF      ; one full high phase
    DJNZ r2, st_wl             ; SCL falls here
    SETP UIO, 0x80             ; release SDA for the ACK slot (SCL is low)
    [ss=0] WAITC I2C_HALF      ; one full low phase
    [ss=1] WAITP UIO, 0x40, 1
    [ss=1] INBIT r3            ; 0 = ACK, 1 = NACK
    [ss=1] WAITC I2C_HALF      ; one full high phase
    [ss=0] WAITC I2C_HALF      ; falling edge lets the target release SDA
    PUSH r3
    JMP st_pass

; =============================================================================
; Engine 1 -- READ byte + ACK/NACK + STOP                         (v1 engine 2)
; =============================================================================
    .engine 1

    CFG SIDE,   0xD8           ; side-set -> UIO[6] = SCL
    CFG BITPIN, 0xB8           ; bit ops -> UIO[7] = SDA

rd_loop:
    PULL r0
    IRQWAIT 0
    IRQCLR 0
    CMPI r0, 2
    JZ rd_sp
    JC rd_pass                 ; r0 < 2: NOP, pass the token back
    LDI r2, 8
rd_rl:
    [ss=0] WAITC I2C_HALF      ; SCL low, the target presents its bit
    [ss=1] WAITP UIO, 0x40, 1  ; SCL high, stretch-aware
    [ss=1] INBIT r3            ; sample on the high phase
    [ss=1] WAITC I2C_HALF      ; one full high phase
    SHLI r4, 1                 ; SCL falls; accumulate
    OR r4, r3
    DJNZ r2, rd_rl
    OUTBIT r0                  ; bit 0: 0 -> ACK, 1 -> NACK (release)
    [ss=0] WAITC I2C_HALF      ; one full low phase
    [ss=1] WAITP UIO, 0x40, 1
    [ss=1] WAITC I2C_HALF      ; one full high phase
    [ss=0] WAITC I2C_HALF      ; falling edge lets the target release SDA
    SETP UIO, 0x80             ; release SDA while SCL is low
    PUSH r4

rd_pass:
    IRQSET 1                   ; bus is free for the START/WRITE half
    JMP rd_loop

rd_sp:
    CLRP UIO, 0x80             ; SDA low while SCL is low
    [ss=0] WAITC I2C_HALF      ; one full low phase
    [ss=1] WAITP UIO, 0x40, 1
    [ss=1] WAITC I2C_HALF      ; one full high phase
    [ss=1] SETP UIO, 0x80      ; SDA rises while SCL high -> STOP
    [ss=1] WAITC I2C_HALF      ; bus free: SCL stays high a full period
    JMP rd_pass
