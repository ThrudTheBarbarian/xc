; fpAbs — absolute value of float
; Input:  $B0-$B4 = value
; Output: $B0-$B4 = |value|

fpAbs:
    LDA $B0
    AND #$FE        ; clear sign bit (bit 0)
    STA $B0
    RTS
