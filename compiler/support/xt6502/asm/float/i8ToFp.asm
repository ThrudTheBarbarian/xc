; i8ToFp — convert signed 8-bit integer to 5-byte xtc float.
;
; Input:  $B0 = i8 value (two's complement)
; Output: $B0..$B4 = 5-byte xtc float
;
; Sign-extends to i16 and delegates.

i8ToFp:
    LDA $B0
    BMI .i8fp_neg
    LDA #$00
    STA $B1
    JMP u16ToFp

.i8fp_neg:
    LDA #$FF
    STA $B1
    JMP i16ToFp
