; i64Mod — signed 64-bit modulus (C99: sign of dividend)
; Input:  $B0-$B7 = dividend, $B8-$BF = divisor
; Output: $B0-$B7 = remainder
;
; i64Div returns the unsigned remainder in $B8-$BF with the sign discarded.
; C99 says `%` takes the sign of the dividend, so the dividend's sign bit (top
; of $B7) is saved before the divide and the remainder negated after if it was
; negative — the same method as i32Mod, one width up.

i64Mod:
    LDA $B7         ; dividend top byte — bit 7 = sign
    PHA
    JSR i64Div
    LDA $B8 : STA $B0
    LDA $B9 : STA $B1
    LDA $BA : STA $B2
    LDA $BB : STA $B3
    LDA $BC : STA $B4
    LDA $BD : STA $B5
    LDA $BE : STA $B6
    LDA $BF : STA $B7
    PLA
    BPL .mod_done
    ; Negate 64-bit $B0-$B7
    SEC
    LDA #$00 : SBC $B0 : STA $B0
    LDA #$00 : SBC $B1 : STA $B1
    LDA #$00 : SBC $B2 : STA $B2
    LDA #$00 : SBC $B3 : STA $B3
    LDA #$00 : SBC $B4 : STA $B4
    LDA #$00 : SBC $B5 : STA $B5
    LDA #$00 : SBC $B6 : STA $B6
    LDA #$00 : SBC $B7 : STA $B7
.mod_done:
    RTS
