; PROTEUS firmware -- JTAG TAP (IEEE 1149.1 subset), engine 0
; =============================================================================
; Pins
;   TMS       UIO[0]  input, sampled on the TCK rising edge
;   TCK       UIO[1]  input, the edge detector (falling edge re-arm, rising
;                     edge is the TAP clock)
;   TDI       UIO[2]  input, unused (see "read-only TAP" below)
;   TDO       UIO[3]  output, push-pull via OUTBIT, updated once per TCK cycle
;
; Engine configuration (host contract, written BEFORE the RUN bit is set)
;   bit-pin cfg (engine 0 window +0x12 = 0x0012) = 0x98
;       [7:6] bank = 2 (UIO), [5:3] pin = 3, [2] invert = 0
;       OUTBIT then drives UIO[3] = TDO.  OUTBIT sets that pin's OE, so TDO is
;       push-pull (never high-Z) from the first shift edge onwards.
;   No other register has to be preloaded: the shift register r2 is loaded by
;   every capture, so RUN can start from any reset value.
;   CFG BITPIN is NOT executed by the image: it would cost the one word this
;   build does not have (32 of 32 used).  The host register is the documented
;   equivalent (docs/programming.md section 2.2).
;
; Timing contract
;   The engine waits for TCK low, then for TCK high.  That pair is one TAP
;   clock.  TMS is sampled in the cycle the rising edge completes, i.e. exactly
;   on the TCK rising edge as 1149.1 requires.  The longest path between the
;   rising edge and the next "wait for TCK low" is 5 instructions (the shift
;   block: INPR, JNZ, OUTBIT, RORI, JMP).
;   Measured by demos/run_stretch.py (it sweeps the TCK phases every run):
;   IDCODE reads correctly from a TCK period of 7 clk (2 low + 5 high), and
;   from a symmetric 4/4; a 1-clk low phase is fine as long as the high phase
;   covers the 5-instruction path.  The demo ships 40/40, i.e. ~5x the minimum.
;   TDO is written at the end of the processing of one edge and is therefore
;   stable a whole TCK period before the host samples it on the next rising
;   edge: no setup race.
;
; TAP states implemented (all 12 required states; two of them merged)
;   Test-Logic-Reset  tlr   TMS=1 stay, TMS=0 -> Run-Test/Idle
;   Run-Test/Idle     upd   TMS=1 -> Select-DR, TMS=0 stay
;   Select-DR         seldr TMS=1 -> Select-IR, TMS=0 -> Capture-DR (load)
;   Select-IR         selir TMS=1 -> Test-Logic-Reset, TMS=0 -> Capture-IR
;   Capture-DR/IR           merged into Shift: the load happens on the
;                           Select->Shift edge, which the host does not sample,
;                           so the first sampled bit is still bit 0.
;   Shift-DR/IR       shift TMS=1 -> Exit1, TMS=0 present bit, rotate, stay
;   Exit1-DR/IR       exit1 TMS=1 -> Update, TMS=0 -> Pause (see LIMITS)
;   Update-DR/IR      upd   TMS=0 -> Run-Test/Idle, TMS=1 -> Select-DR
;                           Update is reached by the fall-through of exit1 and
;                           shares the Run-Test/Idle block: both have the same
;                           successors (TMS=1 -> Select-DR, TMS=0 -> stay).
;   The DR and IR columns are not distinguished: both shift paths are the same
;   8-bit rotator, and only the capture constant differs.
;
; Instruction (IR) model
;   Capture-IR loads 0b0001 and the shift path presents LSB first, so a host
;   reading 4 IR bits reads 0b0001.  The IR is NOT decoded: every instruction
;   behaves as IDCODE (see LIMITS).
;
; IDCODE
;   0x5B5B5B5B, read LSB first.  Bit 0 = 1 as 1149.1 requires.
;   The 32-bit value is a repeating byte on purpose: one 8-bit rotator
;   (RORI r2,1, period 8) emits all 32 bits with 2 instructions per clock,
;   which is the only form that fits the 32-word engine.  The suggested
;   0x0A5C0A5C has period 16 and would need a second register plus a carry
;   chain: +3 words at capture and +3 per shift edge, which does not fit.
;
; LIMITS (measured, see results/stretch.md section 6)
;   * Pause-DR / Exit2-DR / Pause-IR / Exit2-IR are not modelled.  Exit1 with
;     TMS=0 stays in Exit1, so a host that pauses and later leaves Pause with
;     TMS=1 lands in Update one state early.  Measured cost of adding them in
;     the same style: +12 words (an assembled 16-state build is 44 words).
;   * BYPASS is not implemented: it needs TDI capture.  Measured cost: +9 words
;     (4 for the TDI accumulator in the shift path, 5 for the capture select),
;     an assembled 41-word build.
;   * The TAP is read-only: TDI never enters a shift register.
;   * Both together assemble to 51 words.  The per-state cost here is 5-7 words
;     (3 of edge wait + one TMS branch + one tail jump) because the ISA has no
;     indirect jump, so state count is what the 32-word budget actually limits.
;
; Instruction count: 32 words (exactly the 32-word build).
; =============================================================================

    .engine 0

; ---- Test-Logic-Reset ------------------------------------------------------
tlr:
    WAITP UIO, 0x02, 0         ; 0  wait for TCK low
    WAITP UIO, 0x02, 1         ; 1  TCK rising edge: sample TMS
    INPR  UIO, 0x01, r1        ; 2  r1 = TMS, Z = (TMS == 0)
    JZ    upd                  ; 3  TMS=0 -> Run-Test/Idle
    JMP   tlr                  ; 4  TMS=1 -> stay in reset

; ---- Run-Test/Idle and Update-DR/IR (same successors) ----------------------
upd:
    WAITP UIO, 0x02, 0         ; 5
    WAITP UIO, 0x02, 1         ; 6
    INPR  UIO, 0x01, r1        ; 7
    JZ    upd                  ; 8  TMS=0 -> stay (Update -> Run-Test/Idle)
    ; fall through: TMS=1 -> Select-DR

; ---- Select-DR -------------------------------------------------------------
seldr:
    WAITP UIO, 0x02, 0         ; 9
    WAITP UIO, 0x02, 1         ; 10
    INPR  UIO, 0x01, r1        ; 11
    JNZ   selir                ; 12 TMS=1 -> Select-IR
    LDI   r2, 0x5b             ; 13 TMS=0 -> Capture-DR: load IDCODE byte
    ; fall through: Capture -> Shift (the host does not sample this edge)

; ---- Shift-DR / Shift-IR ---------------------------------------------------
shift:
    WAITP UIO, 0x02, 0         ; 14
    WAITP UIO, 0x02, 1         ; 15
    INPR  UIO, 0x01, r1        ; 16
    JNZ   exit1                ; 17 TMS=1 -> Exit1 (no shift at this edge)
    OUTBIT r2                  ; 18 TMS=0: present bit 0 on TDO
    RORI  r2, 1                ; 19 next bit into bit 0, stay in Shift
    JMP   shift                ; 20

; ---- Exit1-DR / Exit1-IR ---------------------------------------------------
exit1:
    WAITP UIO, 0x02, 0         ; 21
    WAITP UIO, 0x02, 1         ; 22
    INPR  UIO, 0x01, r1        ; 23
    JZ    exit1                ; 24 TMS=0 -> Pause (not modelled: stay)
    JMP   upd                  ; 25 TMS=1 -> Update

; ---- Select-IR -------------------------------------------------------------
selir:
    WAITP UIO, 0x02, 0         ; 26
    WAITP UIO, 0x02, 1         ; 27
    INPR  UIO, 0x01, r1        ; 28
    JNZ   tlr                  ; 29 TMS=1 -> Test-Logic-Reset
    LDI   r2, 0x01             ; 30 TMS=0 -> Capture-IR = 0b0001, LSB first
    JMP   shift                ; 31 -> Shift
