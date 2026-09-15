; u32Add — unsigned 32-bit addition
; Input:  $B0-$B3 = operand1 (u32), $B4-$B7 = operand2 (u32)
; Output: $B0-$B3 = result (u32)

u32Add:
    CLC
    LDA $B0 : ADC $B4 : STA $B0
    LDA $B1 : ADC $B5 : STA $B1
    LDA $B2 : ADC $B6 : STA $B2
    LDA $B3 : ADC $B7 : STA $B3
    RTS
