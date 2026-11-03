; PROTEUS demo -- barrier-synchronised UART -> SPI mode 0 bridge
; =============================================================================
; Two engines, one byte at a time, phase-locked by BAR 0:
;   engine 0 (0x10) receives 8N1 UART on UIO[1] at any host-configured baud and
;            publishes each byte to its OUT FIFO,
;   engine 1 (0x30) takes the byte from its IN FIFO and shifts it out on SPI
;            mode 0 (SCK UIO[3], MOSI UIO[4], CS_N UIO[5]).
; Both engines arrive at barrier 0 once per byte, so a byte is transmitted only
; after the receiver has finished sampling it: the two sides cannot drift, and
; no byte can be dropped or duplicated.
;
; Pins
;   UIO[1]  RX    input (engine 0 reads it, never writes it -> no auto-OE)
;   UIO[3]  SCK   engine 1 output via side-set, idle low (mode 0)
;   UIO[4]  MOSI  engine 1 output via BITPIN (OUTBIT drives bit 0 of r0)
;   UIO[5]  CS_N  engine 1 output, active low
;
; Byte path, and why the host is in it
;   PROTEUS has no engine-to-engine data path by design: the FIFOs are strictly
;   host <-> engine, and the only inter-engine state is the 4 barriers and the
;   8 IRQ lines.  (A 4-pin nibble bus would fit in the remaining UIO bits, but
;   it would cost handshake instructions on both sides and would make the SPI
;   side read pins that the UART side drives, i.e. a shared pad with contention
;   instead of the chip's own handshake primitives.)  So the byte moves
;   OUT_FIFO -> host -> IN_FIFO, and the *synchronisation* is on-chip:
;     engine 0: PUSH r2 ; IRQSET 0 ; BAR 0 ; IRQCLR 0
;     engine 1: PULL r0 ;            BAR 0 ; ... SPI frame ...
;   The host only reacts to IRQ 0 (it sees it while engine 0 waits at the
;   barrier) and copies one byte into engine 1's IN FIFO.  Back-pressure is
;   structural: PUSH blocks on a full OUT FIFO, PULL blocks on an empty IN
;   FIFO, and the barrier makes the two engines rendezvous once per byte, so
;   the sequence at both ends is identical with no overflow or loss.
;
; Host register contract
;   engine 0  IN_FIFO unused, OUT_FIFO (+0x11) one byte per frame
;             period (+0x0C..+0x0F): half a bit, H = T * 128 in 24.8, where T
;             is the host's own bit period -- this demo is *not* autobaud
;   engine 1  IN_FIFO (+0x30) one byte per SPI frame
;             period (+0x2C..+0x2F): half an SCK period = 6 cycles -> 0x00000600
;             (SCK = 12 cycles = 4 MHz at 48 MHz; one side-set PACE is the
;             high half, the DJNZ at the end of the body is the low half)
;   IRQ 0 = "UART byte ready" (engine 0 sets, host consumes, engine 0 clears)
;   IRQ 1 = "SPI frame done"  (engine 1 pulses it for the host/analyser)
;   E_ERROR: engine 0 sets it on a UART framing error
;
; Throughput bound
;   After sampling the stop bit engine 0 waits at the barrier for the whole SPI
;   frame (8 bits * 12 cycles = 96 cycles, ~111 with CS/IRQ overhead).  That
;   must fit in the half bit time between the stop sample and the next start
;   edge, i.e. T/2 > 111 cycles -> the bridge sustains baud below
;   48e6 / 222 = 216 kbaud back to back.  Verified at 115200 (T/2 = 208) and
;   57600 (T/2 = 417); at 250 kbaud (T/2 = 96) the SPI frame would overrun.
;
; Instruction counts: engine 0 = 21 words, engine 1 = 19 words (both <= 32).
; =============================================================================

    .engine 0

idle:
    WAITP UIO, 0x02, 0         ; 0  start edge
    PACERST                    ; 1  arm the pacer on the edge
    PACE                       ; 2  priming completion (deadline already met)
    PACE                       ; 3
    PACE                       ; 4  -> sample grid at 1.5 bit times
    LDI r1, 8                  ; 5  bit counter (r2 self-clears over 8 shifts)
bit:
    PACE                       ; 6
    INPR UIO, 0x02, r5         ; 7  sample the centre of this bit
    SHRI r2, 1                 ; 8
    SHLI r5, 6                 ; 9  0x02 -> 0x80
    OR r2, r5                  ; 10 LSB first -> bit 7
    PACE                       ; 11
    DJNZ r1, bit               ; 12
    PACE                       ; 13 -> stop-bit centre
    INPR UIO, 0x02, r5         ; 14
    PUSH r2                    ; 15 publish (blocks if the host is behind)
    ASSERT r5, 0x02            ; 16 framing error -> sticky E_ERROR
    IRQSET 0                   ; 17 tell the host a byte is waiting
    BAR 0                      ; 18 rendezvous: the SPI frame starts now
    IRQCLR 0                   ; 19 the host has taken the byte
    JMP idle                   ; 20

    .engine 1

    CFG SIDE,   0xCC           ; 0  side-set -> UIO[3] = SCK (en, UIO, base 3)
    CFG BITPIN, 0xA0           ; 1  OUTBIT -> UIO[4] = MOSI
    CLRP UIO, 0x08             ; 2  SCK idle low (mode 0, explicit OE)
    SETP UIO, 0x20             ; 3  CS_N idle high
loop:
    PULL r0                    ; 4  byte for this SPI frame
    BAR 0                      ; 5  rendezvous with the UART engine
    PACERST                    ; 6  arm the SCK grid
    PACE                       ; 7  priming completion, absorbed
    CLRP UIO, 0x20             ; 8  CS_N low (SCK is low: mode 0)
    LDI r1, 8                  ; 9
bit:
    [ss=0] PACE                ; 10 grid: SCK low, MOSI from the last OUTBIT
    ROLI r0, 1                 ; 11 MSB -> bit 0
    OUTBIT r0                  ; 12 MOSI valid one cycle before the clock
    [ss=1] PACE                ; 13 SCK rises on this issue cycle and stays
                               ;    high through the stall (6-cycle half bit)
    DJNZ r1, bit               ; 14 SCK falls here (ss=0)
    SETP UIO, 0x20             ; 15 CS_N high
    IRQSET 1                   ; 16 frame done (analyser/host marker)
    IRQCLR 1                   ; 17
    JMP loop                   ; 18
