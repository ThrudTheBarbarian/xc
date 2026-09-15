; print.asm — shared u16/i16-to-screen-decimal routine for the
; xt6502 Layer-4 fixtures. Writes Atari screen codes for the
; decimal digits of A:X (low:high) into $9C00+ starting at column
; $94. Caller must initialise $94 = 0 before the first call.
;
; ZP usage (transient): $90 (num_lo), $91 (num_hi), $92 (digit),
;                       $93 (emitted-flag), $94 (column — caller-owned).
; Clobbers: A, X, Y, P.
;
; Algorithm: divide-by-power-of-10 via subtract-and-count for each
; of 10000, 1000, 100, 10. Suppress leading zeros (but always emit
; the ones digit so 0 → "0").

print_u16:
    STA $90
    STX $91
    LDA #0
    STA $93           ; emitted-anything flag (local to print_u16)
    LDX #0            ; pow10 byte index
pu16_loop:
    LDA #0
    STA $92           ; digit value
pu16_sub:
    SEC
    LDA $90
    SBC pow10_lo,X
    PHA               ; tentative new num_lo
    LDA $91
    SBC pow10_hi,X
    BCC pu16_under    ; carry clear: num < pow10[X], undo
    STA $91
    PLA
    STA $90
    INC $92
    BRA pu16_sub
pu16_under:
    PLA               ; discard tentative new num_lo
    LDA $92
    BNE pu16_emit
    LDA $93
    BEQ pu16_skip
pu16_emit:
    LDA #1
    STA $93
    LDA $92
    CLC
    ADC #$10           ; '0' screen code
    LDY $94
    STA $9C00,Y
    INC $94
pu16_skip:
    INX
    CPX #4            ; 4 pow10 entries (one byte per entry in each table)
    BCC pu16_loop
    ; Always emit the ones digit.
    LDA $90
    CLC
    ADC #$10
    LDY $94
    STA $9C00,Y
    INC $94
    RTS

pow10_lo:
    .byte $10, $E8, $64, $0A     ; 10000, 1000, 100, 10 (LSB)
pow10_hi:
    .byte $27, $03, $00, $00     ; 10000, 1000, 100, 10 (MSB)

; print_i16: A=lo, X=hi → handle sign, then call print_u16.
print_i16:
    CPX #$80
    BCC pi16_nonneg
    PHA
    LDA #$0D           ; '-' screen code
    LDY $94
    STA $9C00,Y
    INC $94
    PLA
    EOR #$FF           ; negate A:X
    CLC
    ADC #1
    PHA
    TXA
    EOR #$FF
    ADC #0
    TAX
    PLA
pi16_nonneg:
    JMP print_u16
