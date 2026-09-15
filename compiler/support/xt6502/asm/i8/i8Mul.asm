; i8Mul — signed 8-bit multiply
; Input:  $B0 = operand1 (i8), $B1 = operand2 (i8)
; Output: $B0 = result low byte (i16 low), $B1 = result high byte (i16 high)
;
; Method: convert to unsigned, multiply, fix sign

i8Mul:
    LDA #$00
    STA $B2         ; sign flag
    LDA $B0
    BPL .op1_pos
    EOR #$FF
    CLC
    ADC #$01
    STA $B0
    INC $B2         ; flip sign
.op1_pos:
    LDA $B1
    BPL .op2_pos
    EOR #$FF
    CLC
    ADC #$01
    STA $B1
    INC $B2
.op2_pos:
    JSR u8Mul       ; unsigned multiply
    LDA $B2
    AND #$01        ; odd = negative result
    BEQ .done
    ; Negate 16-bit result
    LDA $B0
    EOR #$FF
    CLC
    ADC #$01
    STA $B0
    LDA $B1
    EOR #$FF
    ADC #$00
    STA $B1
.done:
    RTS
