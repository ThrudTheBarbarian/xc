; i8Abs — absolute value of signed 8-bit integer
; Input:  $B0 = value (i8)
; Output: $B0 = |value| (i8)

i8Abs:
    LDA $B0
    BPL .done
    EOR #$FF
    CLC
    ADC #$01
    STA $B0
.done:
    RTS
