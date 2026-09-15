; u8ToFp — convert unsigned 8-bit integer to 5-byte xtc float.
;
; Input:  $B0 = u8 value
; Output: $B0..$B4 = 5-byte xtc float
;
; Zero-extends to u16 and delegates.

u8ToFp:
    LDA #$00
    STA $B1
    JMP u16ToFp
