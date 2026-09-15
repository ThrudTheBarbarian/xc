; u16ToDp — convert a 16-bit unsigned integer in $B0-$B1 to a double.
; Delegates to u16ToFp and zero-extends.

u16ToDp:
    JSR u16ToFp
    LDA #$00
    STA $B5
    STA $B6
    STA $B7
    RTS
