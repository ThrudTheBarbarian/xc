; u32ToFp — convert unsigned 32-bit integer to 5-byte xtc float.
;
; Input:  $B0..$B3 = u32 value (little-endian)
; Output: $B0..$B4 = 5-byte xtc float
; Scratch: $B5..$B8 (32-bit working field, big-endian)
;
; Algorithm: load the u32 into the 32-bit working field $B5..$B8
; with $B5 as the high byte, then left-shift the whole field until
; bit 31 (bit 7 of $B5) is set. The number of shifts counts down
; from 31 to give the exponent. One additional shift drops the
; implicit leading 1. The top 24 bits of the post-shift field
; ($B5, $B6, $B7) form the mantissa.
;
; u32 values that require more than 24 mantissa bits get the low
; bits truncated (e.g. $FFFFFFFF loses its bottom 8 bits and
; comes out as ~2^32 - 128). The 24-bit mantissa is the format's
; hard limit — same precision loss any IEEE single-precision
; conversion would see.

u32ToFp:
    ; Zero check — all four bytes must be 0.
    LDA $B0
    ORA $B1
    ORA $B2
    ORA $B3
    BNE .u32fp_nonzero
    LDA #$10            ; zero flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.u32fp_nonzero:
    ; Copy u32 (little-endian $B0..$B3) into the 32-bit big-endian
    ; working field $B5..$B8. $B5 holds bits 31..24, $B8 holds
    ; bits 7..0 so that ASL/ROL from $B8 up to $B5 shifts the
    ; whole field left by one bit.
    LDA $B3
    STA $B5
    LDA $B2
    STA $B6
    LDA $B1
    STA $B7
    LDA $B0
    STA $B8

    LDX #31             ; exponent starts at 31
.u32fp_shift:
    LDA $B5
    BMI .u32fp_found    ; bit 7 of $B5 set → MSB reached bit 31
    ASL $B8
    ROL $B7
    ROL $B6
    ROL $B5
    DEX
    BPL .u32fp_shift    ; nonzero input always finds MSB before underflow

.u32fp_found:
    ; X = exponent. Drop the implicit leading 1 with one more shift.
    ASL $B8
    ROL $B7
    ROL $B6
    ROL $B5

    ; Write the output: flags=0, exp=X, mantissa = $B5,$B6,$B7.
    LDA #$00
    STA $B0
    STX $B1
    LDA $B5
    STA $B2
    LDA $B6
    STA $B3
    LDA $B7
    STA $B4
    RTS
