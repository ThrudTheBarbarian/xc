; u16ToFp — convert unsigned 16-bit integer to 5-byte xtc float.
;
; Input:  $B0,$B1 = u16 value (little-endian)
; Output: $B0..$B4 = 5-byte xtc float
;
; xtc float layout:
;   byte 0: flags (bit 0 = sign, bit 4 = zero, bit 5 = inf, bit 3 = NaN)
;   byte 1: signed exponent (int8)
;   bytes 2-4: 24-bit mantissa, big-endian (byte 2 high, byte 4 low),
;              implicit leading 1 bit stripped
;
; Algorithm: place the u16 into the low 16 bits of a 24-bit working
; field and left-shift until bit 23 is set. The number of shifts gives
; the exponent (23 - shifts). One final shift drops the implicit
; leading 1 into the carry, leaving just the fractional bits in the
; 24-bit field.
;
; Example: 1000 = $03E8
;   Initial:   $B2:$B3:$B4 = $00 $03 $E8   (u16 parked in low 16 bits)
;   After 14 shifts: $B2:$B3:$B4 = $FA $00 $00   (MSB now at bit 23)
;   Exponent = 23 - 14 = 9
;   Final extra shift: $B2:$B3:$B4 = $F4 $00 $00   (leading 1 dropped)
;   Flags = $00, exp = $09. Output: $00 $09 $F4 $00 $00 (matches
;   XTFloatEncoding's encoding of 1000.0).

u16ToFp:
    ; Zero check — both bytes must be 0.
    LDA $B0
    ORA $B1
    BNE .u16fp_nonzero
    LDA #$10            ; zero flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.u16fp_nonzero:
    ; Copy the u16 into the low 16 bits of the 24-bit working
    ; field. $B4 is the low byte, $B3 is the middle byte, $B2
    ; is the high byte (matches the mantissa's big-endian layout).
    LDA $B1
    STA $B3
    LDA $B0
    STA $B4
    LDA #$00
    STA $B2

    LDX #23             ; exponent starts at 23
.u16fp_shift:
    LDA $B2
    BMI .u16fp_found    ; bit 7 of $B2 set → MSB reached bit 23
    ASL $B4
    ROL $B3
    ROL $B2
    DEX
    BPL .u16fp_shift    ; nonzero input always finds MSB before underflow

.u16fp_found:
    ; X = exponent. One more shift to drop the implicit leading 1.
    ASL $B4
    ROL $B3
    ROL $B2

    ; Flags byte = 0 (positive, normal). Exponent to byte 1.
    LDA #$00
    STA $B0
    STX $B1
    RTS
