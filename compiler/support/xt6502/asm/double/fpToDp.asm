; fpToDp — widen a 5-byte float to an 8-byte double in place.
; Input:  $B0-$B4 = float
; Output: $B0-$B7 = double (bytes 5-7 zeroed)
;
; Bytes 0-4 already match the double's byte layout (flags, exponent,
; top three mantissa bytes). The widening just zeros the low 24
; mantissa bits at $B5-$B7 — no arithmetic, no rounding.

fpToDp:
    LDA #$00
    STA $B5
    STA $B6
    STA $B7
    RTS
