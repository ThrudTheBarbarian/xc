; i8Mod — signed 8-bit modulus (C99: sign of dividend)
; Input:  $B0 = dividend (i8), $B1 = divisor (i8)
; Output: $B0 = remainder (i8)
;
; i8Div returns the unsigned remainder in $B1 with the sign
; information already discarded (i8Div negates both operands to
; absolute before calling u8Div). To get C99 semantics we stash
; the dividend's sign bit on the hw stack before calling i8Div,
; then negate the remainder after if the dividend was negative.

i8Mod:
    LDA $B0         ; dividend — sign bit in bit 7
    PHA
    JSR i8Div
    LDA $B1         ; unsigned remainder from i8Div
    STA $B0
    PLA
    BPL .done       ; dividend was >= 0 → remainder already correct
    ; Negate remainder
    SEC
    LDA #$00
    SBC $B0
    STA $B0
.done:
    RTS
