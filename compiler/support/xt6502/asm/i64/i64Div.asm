; i64Div — signed 64-bit divide
; Input:  $B0-$B7 = dividend, $B8-$BF = divisor
; Output: $B0-$B7 = quotient, $B8-$BF = remainder
;
; Negate the negative operands, divide unsigned, negate the quotient when the
; signs differed — the same method as i32Div. i32Div keeps its sign flag in
; $BC, which here is part of the second operand, so the flag is module storage.

i64Div:
    LDA #$00
    STA _i64div_sign
    LDA $B7
    BPL .op1_pos
    JSR .neg64_b0
    INC _i64div_sign
.op1_pos:
    LDA $BF
    BPL .op2_pos
    JSR .neg64_b8
    INC _i64div_sign
.op2_pos:
    JSR u64Div
    LDA _i64div_sign
    AND #$01
    BEQ .done
    JSR .neg64_b0
.done:
    RTS

.neg64_b0:
    LDA $B0 : EOR #$FF : STA $B0
    LDA $B1 : EOR #$FF : STA $B1
    LDA $B2 : EOR #$FF : STA $B2
    LDA $B3 : EOR #$FF : STA $B3
    LDA $B4 : EOR #$FF : STA $B4
    LDA $B5 : EOR #$FF : STA $B5
    LDA $B6 : EOR #$FF : STA $B6
    LDA $B7 : EOR #$FF : STA $B7
    INC $B0
    BNE .neg0_done : INC $B1
    BNE .neg0_done : INC $B2
    BNE .neg0_done : INC $B3
    BNE .neg0_done : INC $B4
    BNE .neg0_done : INC $B5
    BNE .neg0_done : INC $B6
    BNE .neg0_done : INC $B7
.neg0_done:
    RTS

.neg64_b8:
    LDA $B8 : EOR #$FF : STA $B8
    LDA $B9 : EOR #$FF : STA $B9
    LDA $BA : EOR #$FF : STA $BA
    LDA $BB : EOR #$FF : STA $BB
    LDA $BC : EOR #$FF : STA $BC
    LDA $BD : EOR #$FF : STA $BD
    LDA $BE : EOR #$FF : STA $BE
    LDA $BF : EOR #$FF : STA $BF
    INC $B8
    BNE .neg8_done : INC $B9
    BNE .neg8_done : INC $BA
    BNE .neg8_done : INC $BB
    BNE .neg8_done : INC $BC
    BNE .neg8_done : INC $BD
    BNE .neg8_done : INC $BE
    BNE .neg8_done : INC $BF
.neg8_done:
    RTS

_i64div_sign: .byte $00
