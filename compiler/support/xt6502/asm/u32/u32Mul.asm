; u32Mul — unsigned 32-bit multiply
; Input:  $B0-$B3 = operand1 (u32), $B4-$B7 = operand2 (u32)
; Output: $B0-$B3 = result low 32 bits (u32)
; Note:   upper 32 bits of 64-bit product are discarded.
;
; Method: shift-and-add

; Temporaries: $B8-$BB = accumulator
u32Mul:
    LDA #$00
    STA $B8 : STA $B9 : STA $BA : STA $BB
    LDX #32
.loop:
    LSR $B7 : ROR $B6 : ROR $B5 : ROR $B4  ; shift multiplier right
    BCC .no_add
    CLC
    LDA $B8 : ADC $B0 : STA $B8
    LDA $B9 : ADC $B1 : STA $B9
    LDA $BA : ADC $B2 : STA $BA
    LDA $BB : ADC $B3 : STA $BB
.no_add:
    ; Early exit: once the remaining multiplier is zero no further bit can
    ; add anything, so the accumulator is final — skip the rest of the loop.
    LDA $B4 : ORA $B5 : ORA $B6 : ORA $B7
    BEQ .copy
    ASL $B0 : ROL $B1 : ROL $B2 : ROL $B3  ; shift multiplicand left
    DEX
    BNE .loop
.copy:
    LDA $B8 : STA $B0
    LDA $B9 : STA $B1
    LDA $BA : STA $B2
    LDA $BB : STA $B3
    RTS
