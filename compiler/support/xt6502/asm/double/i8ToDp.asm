; i8ToDp — convert an 8-bit signed integer in $B0 to a double in $B0-$B7.
; Delegates to i8ToFp and zero-extends the extra mantissa bytes.

i8ToDp:
    JSR i8ToFp
    LDA #$00
    STA $B5
    STA $B6
    STA $B7
    RTS
