; i32Mul — signed 32-bit multiply
; Input:  $B0-$B3 = operand1 (i32), $B4-$B7 = operand2 (i32)
; Output: $B0-$B3 = result (i32)
; Method: negate if needed, unsigned multiply, negate result if needed

i32Mul:
    LDA #$00
    STA $BC         ; sign flag
    LDA $B3
    BPL .op1_pos
    JSR .neg32_b0
    INC $BC
.op1_pos:
    LDA $B7
    BPL .op2_pos
    JSR .neg32_b4
    INC $BC
.op2_pos:
    JSR u32Mul
    LDA $BC
    AND #$01
    BEQ .done
    JSR .neg32_b0
.done:
    RTS

.neg32_b0:
    LDA $B0 : EOR #$FF : STA $B0
    LDA $B1 : EOR #$FF : STA $B1
    LDA $B2 : EOR #$FF : STA $B2
    LDA $B3 : EOR #$FF : STA $B3
    INC $B0
    BNE .neg0_done : INC $B1
    BNE .neg0_done : INC $B2
    BNE .neg0_done : INC $B3
.neg0_done:
    RTS

.neg32_b4:
    LDA $B4 : EOR #$FF : STA $B4
    LDA $B5 : EOR #$FF : STA $B5
    LDA $B6 : EOR #$FF : STA $B6
    LDA $B7 : EOR #$FF : STA $B7
    INC $B4
    BNE .neg4_done : INC $B5
    BNE .neg4_done : INC $B6
    BNE .neg4_done : INC $B7
.neg4_done:
    RTS
