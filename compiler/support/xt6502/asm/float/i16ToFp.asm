; i16ToFp — convert signed 16-bit integer to 5-byte xtc float.
;
; Input:  $B0,$B1 = i16 value (little-endian two's complement)
; Output: $B0..$B4 = 5-byte xtc float
;
; Negative inputs are negated to their magnitude, converted via
; u16ToFp, and the float's sign bit is set.

i16ToFp:
    LDA $B1
    BMI .i16fp_neg
    JMP u16ToFp

.i16fp_neg:
    ; Two's-complement negate the input to obtain its magnitude.
    SEC
    LDA #$00
    SBC $B0
    STA $B0
    LDA #$00
    SBC $B1
    STA $B1
    JSR u16ToFp
    LDA $B0
    ORA #$01            ; sign bit
    STA $B0
    RTS
