; u64Mod — unsigned 64-bit remainder
; Input:  $B0-$B7 = dividend, $B8-$BF = divisor
; Output: $B0-$B7 = remainder
;
; u64Div leaves the remainder in $B8-$BF; this moves it down into the result
; position, matching how u32Mod defers to u32Div.

u64Mod:
    JSR u64Div
    LDA $B8 : STA $B0
    LDA $B9 : STA $B1
    LDA $BA : STA $B2
    LDA $BB : STA $B3
    LDA $BC : STA $B4
    LDA $BD : STA $B5
    LDA $BE : STA $B6
    LDA $BF : STA $B7
    RTS
