; banked-xcall.harness.asm — xt cross-bank-call golden harness.
;
; Memory map (the real xt map, task #60):
;   $0500-$07FF  software stack              (low RAM)
;   $2400-$3FFF  entry + _xcall trampoline   (unbanked)
;   $4000-$5FFF  screen RAM (SAVMSC)         (unbanked)
;   $6000-$9FFF  code-bank window via $D5C0 (__bank_code_reg)  (banked: leaf/mid)
;   $A000-$FFF9  generated unbanked code+data (.org from the backend)
;
; The generated code references _xcall / _xcall_vec / _xc_bank for
; cross-bank calls; this harness provides them (re-entrant, unbanked).

.org $2400
; Unified unbanked code_regions (task #121): the harness owns the
; `.code_regions` so its $2400 runtime block and the backend's unbanked
; generated code form ONE auto-spilling block. The backend no longer
; emits its own `.code_regions`/`.org` for the unbanked block (that
; reset xta's region list and re-split the two blocks). Ranges = the
; $2400 system region + the layout's main ranges ($A000-$CFFF, $D800-$FFF9).
.code_regions $2400-$3FFF, $A000-$CFFF, $D800-$FFF9
start:
    ; Unlock XT banking (BANK group, bit 3) via the $D1DF master switch
    ; before any $D5C0/$D5C1 use — resets locked. See the corpus harness
    ; and the hardware's register-unlock design.
    LDA $D1DF
    ORA #$08
    STA $D1DF

    LDA #$00
    STA $58
    LDA #$40
    STA $59             ; SAVMSC = $4000 (xt screen)
    LDA #0
    STA $94             ; print column = 0
    ; Software-stack pointer (STACK-ABI §11.3) = $0500 (low RAM; the
    ; generated unbanked code+data now occupies $A000-$FFF9).
    LDA #$00
    STA $8A
    STA $8C
    LDA #$05
    STA $8B
    STA $8D             ; SSP = FP = $0500

    JSR _main           ; result in A:X
    JSR print_u16
    BRK

; ── _xcall: re-entrant cross-bank trampoline (unbanked) ──────────
; Entry protocol from a call site: stage the callee address in
; _xcall_vec and its bank id in _xc_bank, then JSR _xcall. The
; trampoline pops the caller return into a LIFO save-stack (so nested
; cross-bank calls don't clobber each other), saves __bank_code_reg, selects the
; callee bank, RTS-jumps to the callee (no indirect JMP → no page-bug),
; and on return restores __bank_code_reg and re-pushes the caller return. The
; callee sees a clean [callee_ret][args] stack, so its PSH/SP-relative
; param offsets are unchanged from a direct call.
_xc_sp:     .byte $00
_xc_a:      .byte $00
_xc_x:      .byte $00
_xc_bank:   .byte $00
_xcall_vec: .word $0000
_xc_stk:    .space 240

_xcall:
    LDX _xc_sp
    PLA
    STA _xc_stk,X       ; caller ret-1 lo
    INX
    PLA
    STA _xc_stk,X       ; caller ret-1 hi
    INX
    LDA __bank_code_reg
    STA _xc_stk,X       ; caller bank
    INX
    STX _xc_sp
    LDA _xc_bank
    STA __bank_code_reg ; select callee bank
    LDA #>_xc_res_m1
    PHA
    LDA #<_xc_res_m1
    PHA
    LDA _xcall_vec
    SEC
    SBC #1
    TAX
    LDA _xcall_vec+1
    SBC #0
    PHA
    TXA
    PHA
    RTS                 ; → callee; callee RTSes to _xc_res
_xc_res_m1:
    NOP
_xc_res:
    STA _xc_a           ; stash retval lo (A)
    STX _xc_x           ; stash retval hi (X)
    LDX _xc_sp
    DEX
    LDA _xc_stk,X
    STA __bank_code_reg ; restore caller bank
    DEX
    LDA _xc_stk,X
    PHA                 ; caller ret-1 hi
    DEX
    LDA _xc_stk,X
    STX _xc_sp
    PHA                 ; caller ret-1 lo
    LDX _xc_x
    LDA _xc_a
    RTS                 ; → caller, A:X = retval

; ── print_u16 — A:X (lo:hi) → decimal at screen $4000 + $94 ──────
; ZP scratch $90/$91/$92/$93; column $94 (caller-owned). Writes Atari
; screen codes. Same algorithm as the shared print.asm but the screen
; base is $4000 (xt) rather than $9C00.
print_u16:
    STA $90
    STX $91
    LDA #0
    STA $93
    LDX #0
pu16_loop:
    LDA #0
    STA $92
pu16_sub:
    SEC
    LDA $90
    SBC pu16_pow10_lo,X
    PHA
    LDA $91
    SBC pu16_pow10_hi,X
    BCC pu16_under
    STA $91
    PLA
    STA $90
    INC $92
    BRA pu16_sub
pu16_under:
    PLA
    LDA $92
    BNE pu16_emit
    LDA $93
    BEQ pu16_skip
pu16_emit:
    LDA #1
    STA $93
    LDA $92
    CLC
    ADC #$10
    LDY $94
    STA $4000,Y
    INC $94
pu16_skip:
    INX
    CPX #4
    BCC pu16_loop
    LDA $90
    CLC
    ADC #$10
    LDY $94
    STA $4000,Y
    INC $94
    RTS

pu16_pow10_lo:
    .byte $10, $E8, $64, $0A
pu16_pow10_hi:
    .byte $27, $03, $00, $00
