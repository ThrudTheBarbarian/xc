; u16Mod — unsigned 16-bit modulus
; Input:  $B0,$B1 = dividend (u16), $B2,$B3 = divisor (u16)
; Output: $B0,$B1 = remainder (u16)

u16Mod:
    JSR u16Div
    LDA $B2 : STA $B0
    LDA $B3 : STA $B1
    RTS
