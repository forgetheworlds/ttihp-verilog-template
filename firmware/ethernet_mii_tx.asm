; PROTEUS v2 (hybrid) firmware -- full 802.3 frame TX over MII, 31 words
; =============================================================================
; WHERE THIS SITS
;   v1 (firmware/ethernet_mii_tx.asm) measured that a *complete* frame does not
;   fit the 32-word engine: 230 words for preamble + SFD + dst/src/ethertype +
;   46-byte payload + IFG, plus a second 32-word engine for the FCS.  This image
;   is the same frame in 31 words, because the hybrid build has data paths that
;   v1 did not:
;
;     assist 1  FIFO   16 x 8  -- the frame body arrives from the host instead
;                                 of being generated (or unrolled) in code
;     assist 0  CRC    bit-serial CRC-32, folded one byte per STAS
;
;   Per frame byte the loop costs 7 words once (pop, fold, rotate, emit two
;   nibbles, retire) and 2 words per FCS byte, instead of ~11 words per
;   constant byte in v1 -- and, decisively, the *code size no longer depends on
;   the payload length*.
;
; ---------------------------------------------------------------------------
; HOST CONTRACT (model-level in v2/demos/run_v2.py; the RTL SPI window is
; exercised by v2/tb/tb_csr.v and v2/tb/tb_top_smoke.v)
; ---------------------------------------------------------------------------
;   1. Host configures the CRC assist once (host window 0x0600 + 0x10*0 + reg):
;        reg 2  CFG0   = 0xE0   {lsb=1, refl=1, width=32}
;        reg 3  CMD    = 8      select page = init
;        reg 4..7      = the init pre-image (see "The init pre-image" below)
;        reg 3  CMD    = 9      page = poly,  reg 4..7 = 20 83 B8 ED
;        reg 3  CMD    = 10     page = xorout, reg 4..7 = FF FF FF FF
;        reg 3  CMD    = 1      start: crc <= init
;        reg 3  CMD    = 0      page back to CRC result (lane 0)
;      then the FIFO assist (0x0610 + reg): reg 3 = 0 (clear).
;   2. Host writes two engine-0 registers:
;        r2 = N   number of bytes it will push  (8 header + body length)
;        r3 = 1   phase flag: 1 = payload pass, 2 = FCS pass (see below)
;   3. Host sets RUN for engine 0.
;   4. Host pushes exactly N bytes into the assist FIFO in wire order: seven
;      0x55 (preamble), one 0xD5 (SFD), then dst | src | ethertype | payload.
;      It must never let the FIFO run dry: the emitter checks STATUS.empty once
;      per byte and aborts the frame (TX_EN drops, pins parked, IFG, HALT) when
;      the next byte is not there yet.
;   5. The engine appends the FCS itself: it reads the four result lanes, pushes
;      them back through the same FIFO and streams them with the same code path.
;
;   The frame byte count is 8 + body: 68 for the 60-byte body used by the demo
;   (64-byte frame with the FCS = the 802.3 minimum).
;
; ---------------------------------------------------------------------------
; THE INIT PRE-IMAGE (why the header can be folded and still give a clean FCS)
; ---------------------------------------------------------------------------
;   The FIFO delivers preamble and SFD too, and the loop folds *every* byte it
;   emits (that is what makes the loop one code path).  Folding the 8 header
;   bytes must therefore be a no-op on the CRC state.  The fold is an invertible
;   map of the LFSR state for a fixed byte string, so the host presets the init
;   page to the pre-image of 0xFFFFFFFF under the header:
;
;       fold(init_pre, 55 55 55 55 55 55 55 D5) == 0xFFFFFFFF
;
;   After the header the assist is in exactly the state the standard requires
;   (init 0xFFFFFFFF) and the body folds from there, so the result is
;   zlib.crc32(dst|src|ethertype|payload) -- the FCS, low byte first, which is
;   the wire order.  v2/demos/run_v2.py derives the pre-image with an inverse
;   CRC step and asserts fold(init_pre, header) == 0xFFFFFFFF, so the value in
;   this file is checked, not transcribed.
;
;   The alternative (a `ASST CRC, START` between the header and the body, or a
;   second copy of the loop that skips the fold) costs words this engine does
;   not have: the emitter is 31 of 32.
;
; ---------------------------------------------------------------------------
; PIN MAP (MII, 6 pads, all on uio so the host SPI on ui_in coexists)
;   TX_CLK  UIO[0]  input, 2.5 MHz, driven by the PHY (10 low + 10 high cycles
;                   at the 50 MHz info.yaml clock = one nibble)
;   TX_EN   UIO[1]  output, side-set driven (CFG SIDE = 0xC4: bank UIO, base 1,
;                   width 1).  ss=1 on every instruction of the frame keeps it
;                   high through stalls; the align instructions and the IFG
;                   carry ss=0 and therefore drive it low.
;   TXD0..3 UIO[5:2] output, one OUTP mask 0x3C from bits [5:2] of a register
;   uio[7:6], ui_in, uo_out untouched.
;
; ---------------------------------------------------------------------------
; NIBBLE ORDER AND THE TWO ROTATES
;   802.3 clause 3 sends bits [3:0] of each byte first, and TXD0 is the LSB.
;   For a byte b, bits [5:2] of ROL(b,2) are b[3:0] (low nibble) and bits [5:2]
;   of ROR(b,2) are b[7:4] (high nibble).  Starting from the low-nibble form,
;   ROR(x,4) is exactly the high-nibble form, so a byte costs two rotates and no
;   copy register:
;        ROLI r0,2 -> OUTP -> RORI r0,4 -> OUTP
;   A FIFO byte 0x55 therefore emits 5,5 and 0xD5 emits 5,D: the preamble and
;   the SFD come out of the same loop as the body, no special case.
;
; ---------------------------------------------------------------------------
; TIMING AT THE PADS (measured, v2/results/v2_firmware.md)
;   One nibble slot is 20 cycles: the byte loop takes exactly two slots, so the
;   wire rate is the PHY's 2.5 MHz nibble clock = 10 Mbit/s and the loop cannot
;   drift against it (every slot starts on WAITP, none is counted).
;   Per byte: nibble A is driven 8 cycles before its sampling edge, nibble B 8
;   cycles before its own; TXD only ever changes in a low phase, so the
;   sampling-edge hold is 12 cycles.  Measured minimum setup 8 / hold 12 cycles
;   (160 ns / 240 ns at 50 MHz) against the 25 ns MII requirement.
;   The byte preparation (status read, pop, fold, rotate) runs in the *high*
;   phase after nibble B, where changing registers is free.
;
; ---------------------------------------------------------------------------
; FCS PASS: the emitter reuses the FIFO for four bytes it generates itself
;   After the payload count expires the loop reads CRC result lanes 4..7 and
;   pushes them back into the FIFO (STAS to DATA), then streams them with the
;   same 7-word path.  Folding them again is harmless: the result was read
;   before they were pushed.  This is why the FCS costs 8 words (four
;   LDAS/STAS pairs) instead of 32 unrolled emit sequences.
;   Consequence for the host: it must push exactly N bytes and then stop; the
;   four bytes the engine pushes are its own.
;
; ---------------------------------------------------------------------------
; PHASE DISPATCH (one word)
;   r3 starts at 1.  The first time a pass expires, `DJNZ r3` decrements 1 -> 0
;   and does not branch, so the FCS block runs.  The second time it decrements
;   0 -> 0xFF, which is nonzero, so it branches to the IFG.  No compare, no flag
;   store, one word.
;
; ---------------------------------------------------------------------------
; Instruction count: 31 words (PROG_DEPTH = 32).  1 word left.
; =============================================================================

    .engine 0

    CFG SIDE,   0xC4           ; 0  side-set -> UIO[1] = TX_EN (off while ss=0)
    WAITP UIO,  0x01, 1        ; 1  align: finish in a TX_CLK high phase, so the
                               ;    next WAITP(0) lands on a low-phase boundary
    [ss=1] JMP prep            ; 2  TX_EN rises here, 8..18 cycles before the
                               ;    first sampling edge and after the last one

; ---- FCS pass / frame end ---------------------------------------------------
fcs:
    [ss=1] DJNZ r3, ifg        ; 3  1 -> 0: FCS block; 0 -> 0xFF: IFG
    [ss=1] LDAS r0, r4, CRC    ; 4  FCS byte 0 = crc[7:0]   (wire order)
    [ss=1] STAS r0, r0, FIFO   ; 5
    [ss=1] LDAS r0, r5, CRC    ; 6
    [ss=1] STAS r0, r0, FIFO   ; 7
    [ss=1] LDAS r0, r6, CRC    ; 8
    [ss=1] STAS r0, r0, FIFO   ; 9
    [ss=1] LDAS r0, r7, CRC    ; 10
    [ss=1] STAS r0, r0, FIFO   ; 11
    [ss=1] LDI r2, 4           ; 12 emit four FCS bytes: the fall-through prep
                               ;    pops byte 0, DJNZ branches for bytes 1..3

; ---- byte preparation: runs in the high phase after nibble B ---------------
prep:
    [ss=1] LDAS r1, r1, FIFO   ; 13 STATUS: {0, full, empty, level[4:0]}
    [ss=1] ANDI r1, 0x20       ; 14 bit 5 = empty -> nonzero result when empty
    [ss=1] JNZ ifg             ; 15 underrun: abort the frame, never emit stale
    [ss=1] LDAS r0, r0, FIFO   ; 16 pop the byte
    [ss=1] STAS r0, r0, CRC    ; 17 fold it into the FCS (8 cycles, done before
                               ;    the next byte reaches this point)
    [ss=1] ROLI r0, 2          ; 18 bits [5:2] = low nibble
    [ss=1] WAITP UIO, 0x01, 0  ; 19 next low phase

; ---- one byte = two nibble slots ------------------------------------------
loop:
    [ss=1] OUTP UIO, 0x3C, r0  ; 20 low nibble  -> TXD
    [ss=1] WAITP UIO, 0x01, 1  ; 21 sampling edge
    [ss=1] RORI r0, 4          ; 22 bits [5:2] = high nibble
    [ss=1] WAITP UIO, 0x01, 0  ; 23
    [ss=1] OUTP UIO, 0x3C, r0  ; 24 high nibble
    [ss=1] WAITP UIO, 0x01, 1  ; 25 sampling edge
    [ss=1] DJNZ r2, prep       ; 26 r2 bytes left -> prepare the next one
    [ss=1] JMP fcs             ; 27 count expired: append the FCS, or leave

ifg:
    CLRP UIO, 0x3C             ; 28 TX_EN (ss=0) and TXD low
    WAITC 480                  ; 29 480 cycles = 24 nibble times = 96 bit
                               ;    times = the 802.3 inter-frame gap
    HALT                       ; 30 pins parked, RUN retired
