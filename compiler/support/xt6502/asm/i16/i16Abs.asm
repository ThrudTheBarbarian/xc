; i16Abs — absolute value of signed 16-bit integer
; Input:  $B0,$B1 = value (i16)
; Output: $B0,$B1 = |value|

i16Abs:
    LDA $B1
    BPL .done
    LDA $B0 : EOR #$FF : STA $B0
    LDA $B1 : EOR #$FF : STA $B1
    INC $B0
    BNE .done
    INC $B1
.done:
    RTS
