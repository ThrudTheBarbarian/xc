; u8Mod — unsigned 8-bit modulus
; Input:  $B0 = dividend (u8), $B1 = divisor (u8)
; Output: $B0 = remainder (u8)
;
; Uses u8Div then moves remainder to $B0.

u8Mod:
    JSR u8Div
    LDA $B1
    STA $B0
    RTS
