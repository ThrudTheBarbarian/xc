; i16Mul — signed 16-bit multiply → i32
; Input:  $B0,$B1 = operand1 (i16), $B2,$B3 = operand2 (i16)
; Output: $B0,$B1,$B2,$B3 = result (i32 little-endian)

i16Mul:
    LDA #$00
    STA $B8         ; sign flag
    ; Make operand1 positive
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
    JSR u16Mul
    LDA $B8
    AND #$01
    BEQ .done
    ; Negate 32-bit result
    LDA $B0 : EOR #$FF : STA $B0
    LDA $B1 : EOR #$FF : STA $B1
    LDA $B2 : EOR #$FF : STA $B2
    LDA $B3 : EOR #$FF : STA $B3
    INC $B0
    BNE .done
    INC $B1
    BNE .done
    INC $B2
    BNE .done
    INC $B3
.done:
    RTS

.neg16_b0:
    LDA $B0 : EOR #$FF : STA $B0
    LDA $B1 : EOR #$FF : STA $B1
    INC $B0
    BNE .neg16_b0_done
    INC $B1
.neg16_b0_done:
    RTS

.neg16_b2:
    LDA $B2 : EOR #$FF : STA $B2
    LDA $B3 : EOR #$FF : STA $B3
    INC $B2
    BNE .neg16_b2_done
    INC $B3
.neg16_b2_done:
    RTS
