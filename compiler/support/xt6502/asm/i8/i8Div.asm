; i8Div — signed 8-bit divide
; Input:  $B0 = dividend (i8), $B1 = divisor (i8)
; Output: $B0 = quotient (i8), $B1 = remainder (i8)

i8Div:
    LDA #$00
    STA $B2         ; sign flag
    LDA $B0
    BPL .op1_pos
    EOR #$FF
    CLC
    ADC #$01
    STA $B0
    INC $B2
.op1_pos:
    LDA $B1
    BPL .op2_pos
    EOR #$FF
    CLC
    ADC #$01
    STA $B1
    INC $B2
.op2_pos:
    JSR u8Div
    LDA $B2
    AND #$01
    BEQ .done
    LDA $B0
    EOR #$FF
    CLC
    ADC #$01
    STA $B0
.done:
    RTS
