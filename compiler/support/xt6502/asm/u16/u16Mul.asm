; u16Mul — unsigned 16-bit multiply
; Input:  $B0,$B1 = operand1 (u16 little-endian)
;         $B2,$B3 = operand2 (u16 little-endian)
; Output: $B0,$B1,$B2,$B3 = result (u32 little-endian)
;
; Method: shift-and-add (16x16 -> 32)

u16Mul:
    ; result in $B4-$B7, then copy to $B0-$B3
    LDA #$00
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    LDX #16         ; 16 bits
.loop:
    LSR $B3
    ROR $B2         ; shift multiplier right
    BCC .no_add
    CLC
    LDA $B4
    ADC $B0
    STA $B4
    LDA $B5
    ADC $B1
    STA $B5
    LDA $B6
    ADC #$00
    STA $B6
    LDA $B7
    ADC #$00
    STA $B7
.no_add:
    ; Early exit: once the remaining multiplier is zero no further bit can
    ; add anything, so the accumulator is final — skip the rest of the loop.
    LDA $B2
    ORA $B3
    BEQ .copy
    ASL $B0
    ROL $B1         ; shift multiplicand left
    DEX
    BNE .loop
.copy:
    ; Copy result
    LDA $B4 : STA $B0
    LDA $B5 : STA $B1
    LDA $B6 : STA $B2
    LDA $B7 : STA $B3
    RTS
