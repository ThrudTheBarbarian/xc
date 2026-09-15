; i32Abs — absolute value of signed 32-bit integer
; Input:  $B0-$B3 = value
; Output: $B0-$B3 = |value|

i32Abs:
    LDA $B3
    BPL .done
    LDA $B0 : EOR #$FF : STA $B0
    LDA $B1 : EOR #$FF : STA $B1
    LDA $B2 : EOR #$FF : STA $B2
    LDA $B3 : EOR #$FF : STA $B3
    INC $B0
    BNE .done : INC $B1
    BNE .done : INC $B2
    BNE .done : INC $B3
.done:
    RTS
