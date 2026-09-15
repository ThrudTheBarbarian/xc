; i32Div — signed 32-bit divide
; Input:  $B0-$B3 = dividend, $B4-$B7 = divisor
; Output: $B0-$B3 = quotient, $B4-$B7 = remainder

i32Div:
    LDA #$00
    STA $BC
    LDA $B3
    BPL .op1_pos
    JSR i32Mul.neg32_b0
    INC $BC
.op1_pos:
    LDA $B7
    BPL .op2_pos
    JSR i32Mul.neg32_b4
    INC $BC
.op2_pos:
    JSR u32Div
    LDA $BC
    AND #$01
    BEQ .done
    JSR i32Mul.neg32_b0
.done:
    RTS
