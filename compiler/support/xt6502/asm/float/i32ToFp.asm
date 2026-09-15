; i32ToFp — convert signed 32-bit integer to 5-byte xtc float.
;
; Input:  $B0..$B3 = i32 value (little-endian two's complement)
; Output: $B0..$B4 = 5-byte xtc float
;
; Negative inputs are negated in place to obtain their magnitude,
; converted via u32ToFp, and the float's sign bit is then set.

i32ToFp:
    LDA $B3
    BMI .i32fp_neg
    JMP u32ToFp

.i32fp_neg:
    ; Two's-complement negate the 32-bit input.
    SEC
    LDA #$00
    SBC $B0
    STA $B0
    LDA #$00
    SBC $B1
    STA $B1
    LDA #$00
    SBC $B2
    STA $B2
    LDA #$00
    SBC $B3
    STA $B3
    JSR u32ToFp
    LDA $B0
    ORA #$01            ; sign bit
    STA $B0
    RTS
