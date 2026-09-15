; u32ToDp — convert unsigned 32-bit integer to 8-byte xtc double.
;
; Input:  $B0..$B3 = u32 value (little-endian)
; Output: $B0..$B7 = 8-byte xtc double
;
; The dp format's 48-bit mantissa has room for the full 32 bits of
; the input with no loss (unlike u32ToFp, whose 24-bit mantissa
; truncates the low 8 bits of $FFFFFFFF-class values). This routine
; normalises in place in $B2..$B7 using the output mantissa slot as
; its working field — the upper 16 bits start zero and the input
; u32 lives in the low 32 bits, big-endian, ready to shift up.

u32ToDp:
    ; Zero check — all four bytes must be 0.
    LDA $B0
    ORA $B1
    ORA $B2
    ORA $B3
    BNE .u32dp_nonzero
    LDA #$10                ; zero flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    RTS

.u32dp_nonzero:
    ; Copy u32 (little-endian $B0..$B3) into the low 32 bits of the
    ; output mantissa slot $B4..$B7, big-endian:
    ;   $B4 = bits 31..24 (u32 high byte)
    ;   $B5 = bits 23..16
    ;   $B6 = bits 15..8
    ;   $B7 = bits 7..0   (u32 low byte)
    ; Order matters: read $B3 before overwriting anything below it,
    ; then $B2 before $B5 is set, etc.
    LDA $B3
    STA $B4
    LDA $B2
    STA $B5
    LDA $B1
    STA $B6
    LDA $B0
    STA $B7
    ; Upper 16 bits of the working field = 0.
    LDA #$00
    STA $B2
    STA $B3

    ; Working field = $B2..$B7, 48-bit big-endian. Shift left until
    ; bit 47 (bit 7 of $B2) is set; X counts down from 47 giving
    ; the final exponent.
    LDX #47
.u32dp_shift:
    LDA $B2
    BMI .u32dp_found
    ASL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    DEX
    BPL .u32dp_shift        ; nonzero input always finds MSB before underflow

.u32dp_found:
    ; X = exponent. Drop the implicit leading 1 with one more shift.
    ASL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2

    ; Write flags + exponent. Mantissa is already in place at $B2..$B7.
    LDA #$00
    STA $B0
    STX $B1
    RTS
