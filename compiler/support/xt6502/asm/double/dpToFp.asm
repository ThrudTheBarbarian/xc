; dpToFp — narrow an 8-byte double to a 5-byte float in place.
; Input:  $B0-$B7 = double
; Output: $B0-$B4 = float (bytes 5-7 of the double discarded)
;
; The two formats share byte 0 (flags), byte 1 (signed exponent),
; and the top three mantissa bytes (bytes 2-4). The 8-byte double's
; mantissa bytes 5-7 are the low 24 bits of the 48-bit mantissa,
; which this routine drops. So the narrowing is a no-op on the
; wire — $B0-$B4 already holds a valid (precision-truncated) float
; encoding of the same value.

dpToFp:
    RTS
