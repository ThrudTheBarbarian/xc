; i16Div — signed 16-bit divide
; Input:  $B0,$B1 = dividend (i16), $B2,$B3 = divisor (i16)
; Output: $B0,$B1 = quotient (i16), $B2,$B3 = remainder (i16)

i16Div:
    LDA #$00
    STA $B8
    LDA $B1
    BPL .op1_pos
    JSR .neg16_b0
    INC $B8
.op1_pos:
    LDA $B3
    BPL .op2_pos
    JSR .neg16_b2
    INC $B8
.op2_pos:
    JSR u16Div
    LDA $B8
    AND #$01
    BEQ .done
    JSR .neg16_b0
.done:
    RTS

.neg16_b0:
    LDA $B0 : EOR #$FF : STA $B0
    LDA $B1 : EOR #$FF : STA $B1
    INC $B0
    BNE .ret : INC $B1
.ret:
    RTS

.neg16_b2:
    LDA $B2 : EOR #$FF : STA $B2
    LDA $B3 : EOR #$FF : STA $B3
    INC $B2
    BNE .ret2 : INC $B3
.ret2:
    RTS
