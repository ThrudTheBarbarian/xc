; u32Mod — unsigned 32-bit modulus
; Input:  $B0-$B3 = dividend, $B4-$B7 = divisor
; Output: $B0-$B3 = remainder

u32Mod:
    JSR u32Div
    LDA $B4 : STA $B0
    LDA $B5 : STA $B1
    LDA $B6 : STA $B2
    LDA $B7 : STA $B3
    RTS
