; i16Mod — signed 16-bit modulus (C99: sign of dividend)
; Input:  $B0,$B1 = dividend, $B2,$B3 = divisor
; Output: $B0,$B1 = remainder
;
; i16Div returns the unsigned remainder in $B2,$B3 with sign
; information discarded. C99 says `%` takes the sign of the
; dividend, so we save the dividend's sign bit (high byte of $B1)
; before calling i16Div and negate the remainder after if the
; dividend was negative.

i16Mod:
    LDA $B1         ; dividend high byte — bit 7 = sign
    PHA
    JSR i16Div
    LDA $B2 : STA $B0
    LDA $B3 : STA $B1
    PLA
    BPL .mod_done
    ; Negate 16-bit $B0,$B1
    SEC
    LDA #$00 : SBC $B0 : STA $B0
    LDA #$00 : SBC $B1 : STA $B1
.mod_done:
    RTS
