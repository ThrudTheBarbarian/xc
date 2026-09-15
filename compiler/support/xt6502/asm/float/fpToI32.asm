; fpToI32 — convert 5-byte xtc float to signed 32-bit integer (truncate).
;
; Input:  $B0..$B4 = 5-byte xtc float
;         $B0 = flags (bit 0 = sign, bit 4 = zero)
;         $B1 = exponent (0..30 for representable integer magnitudes,
;                         negative for fractions, >=31 for overflow)
;         $B2..$B4 = 24-bit stored mantissa (the format's leading 1
;                    was dropped by u32ToFp's final left-shift, so
;                    fpToI32 reverses that drop here)
; Output: $B0..$B3 = i32 (little-endian, two's complement, truncated
;                    toward zero)
; Scratch: $B5..$B8 (32-bit big-endian working field)
;
; Truncation / saturation:
;   * |value| < 1                       → 0
;   * value in [-(2^31), 2^31-1]        → exact integer, fraction dropped
;   * value > 2^31-1 or < -(2^31)       → 0 (saturate-to-zero —
;                    matches the "no diagnostic, return defined value"
;                    convention xtc uses for other narrowing casts)

fpToI32:
    ; Zero shortcut.
    LDA $B0
    AND #$10
    BNE .fpi_zero

    ; Save the sign bit somewhere the working field doesn't touch.
    LDA $B0
    AND #$01
    STA _fpToI32_sign

    ; Negative exponent → |value| < 1 → 0.
    LDA $B1
    BMI .fpi_zero
    ; Exponent >= 31 → magnitude overflows i32 range → 0.
    CMP #31
    BCS .fpi_zero

    ; Build the 32-bit big-endian working field [B5][B6][B7][B8] so
    ; that the stored mantissa occupies bits 31..8 (its MSB at
    ; bit 31), then shift right by 1 to make room for the implicit
    ; leading 1 at bit 31. Final layout: bit 31 = 1, bits 30..7 =
    ; stored mantissa, bits 6..0 = 0. That's the "1.fraction" value
    ; scaled by 2^31; we'll shift right by (31 - exp) below to
    ; recover the integer.
    LDA $B2
    STA $B5
    LDA $B3
    STA $B6
    LDA $B4
    STA $B7
    LDA #$00
    STA $B8
    LSR $B5
    ROR $B6
    ROR $B7
    ROR $B8
    LDA $B5
    ORA #$80
    STA $B5

    ; Loop: shift the 32-bit field right by (31 - exp) bits.
    LDX $B1
.fpi_shift:
    CPX #31
    BEQ .fpi_aligned
    LSR $B5
    ROR $B6
    ROR $B7
    ROR $B8
    INX
    JMP .fpi_shift

.fpi_aligned:
    ; B5..B8 holds the magnitude as a 32-bit big-endian integer.
    ; Stage to a temp before writing back to B0..B3 (little-endian)
    ; because the source and dest overlap.
    LDA $B5
    STA _fpToI32_tmp + 3
    LDA $B6
    STA _fpToI32_tmp + 2
    LDA $B7
    STA _fpToI32_tmp + 1
    LDA $B8
    STA _fpToI32_tmp + 0

    ; Apply sign.
    LDA _fpToI32_sign
    BEQ .fpi_pos

    ; Two's-complement negate while moving from temp into B0..B3.
    SEC
    LDA #$00
    SBC _fpToI32_tmp + 0
    STA $B0
    LDA #$00
    SBC _fpToI32_tmp + 1
    STA $B1
    LDA #$00
    SBC _fpToI32_tmp + 2
    STA $B2
    LDA #$00
    SBC _fpToI32_tmp + 3
    STA $B3
    RTS

.fpi_pos:
    LDA _fpToI32_tmp + 0
    STA $B0
    LDA _fpToI32_tmp + 1
    STA $B1
    LDA _fpToI32_tmp + 2
    STA $B2
    LDA _fpToI32_tmp + 3
    STA $B3
    RTS

.fpi_zero:
    LDA #$00
    STA $B0
    STA $B1
    STA $B2
    STA $B3
    RTS

_fpToI32_sign:
    .byte $00
_fpToI32_tmp:
    .byte $00, $00, $00, $00
