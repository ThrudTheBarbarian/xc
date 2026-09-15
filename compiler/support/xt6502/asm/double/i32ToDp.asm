; i32ToDp — convert signed 32-bit integer to 8-byte xtc double.
;
; Input:  $B0..$B3 = i32 value (little-endian two's complement)
; Output: $B0..$B7 = 8-byte xtc double
;
; Negative inputs are negated in place to obtain their magnitude,
; converted via u32ToDp, and the double's sign bit is then set.

i32ToDp:
    LDA $B3
    BMI .i32dp_neg
    JMP u32ToDp

.i32dp_neg:
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
    JSR u32ToDp
    LDA $B0
    ORA #$01                ; sign bit
    STA $B0
    RTS
