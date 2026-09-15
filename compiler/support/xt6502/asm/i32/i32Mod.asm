; i32Mod — signed 32-bit modulus (C99: sign of dividend)
; Input:  $B0-$B3 = dividend, $B4-$B7 = divisor
; Output: $B0-$B3 = remainder
;
; i32Div returns the unsigned remainder in $B4-$B7 with sign
; information discarded. C99 says `%` takes the sign of the
; dividend, so we save the dividend's sign bit (high byte of $B3)
; before calling i32Div and negate the remainder after if the
; dividend was negative.

i32Mod:
    LDA $B3         ; dividend top byte — bit 7 = sign
    PHA
    JSR i32Div
    LDA $B4 : STA $B0
    LDA $B5 : STA $B1
    LDA $B6 : STA $B2
    LDA $B7 : STA $B3
    PLA
    BPL .mod_done
    ; Negate 32-bit $B0-$B3
    SEC
    LDA #$00 : SBC $B0 : STA $B0
    LDA #$00 : SBC $B1 : STA $B1
    LDA #$00 : SBC $B2 : STA $B2
    LDA #$00 : SBC $B3 : STA $B3
.mod_done:
    RTS
