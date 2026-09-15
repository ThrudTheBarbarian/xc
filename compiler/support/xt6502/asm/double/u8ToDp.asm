; u8ToDp — convert an 8-bit unsigned integer in $B0 to a double in $B0-$B7.
; Implementation: delegate to u8ToFp, then zero the extra mantissa bytes.
; Dependencies: u8ToFp (float path)

u8ToDp:
    JSR u8ToFp
    LDA #$00
    STA $B5
    STA $B6
    STA $B7
    RTS
