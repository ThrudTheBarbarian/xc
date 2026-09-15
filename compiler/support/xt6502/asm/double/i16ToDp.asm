; i16ToDp — convert a 16-bit signed integer in $B0-$B1 to a double.
; Delegates to i16ToFp and zero-extends.

i16ToDp:
    JSR i16ToFp
    LDA #$00
    STA $B5
    STA $B6
    STA $B7
    RTS
