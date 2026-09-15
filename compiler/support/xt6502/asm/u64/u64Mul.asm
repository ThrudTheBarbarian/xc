; u64Mul — unsigned 64-bit multiply
; Input:  $B0-$B7 = operand1 (multiplicand), $B8-$BF = operand2 (multiplier)
; Output: $B0-$B7 = low 64 bits of the product
; Note:   the upper 64 bits are discarded, as u32Mul discards its upper 32.
;
; Method: shift-and-add, the same shape as u32Mul one width up. The
; accumulator cannot live in zero page — $B0-$BF is the whole runtime window
; (xt.lnk [zp] `runtime`) and both operands already fill it — so it is module
; storage addressed absolutely. Slower per byte than u32Mul's ZP accumulator,
; and correct, which is the trade that matters here.

u64Mul:
    LDA #$00
    STA _u64mul_acc+0 : STA _u64mul_acc+1
    STA _u64mul_acc+2 : STA _u64mul_acc+3
    STA _u64mul_acc+4 : STA _u64mul_acc+5
    STA _u64mul_acc+6 : STA _u64mul_acc+7
    LDX #64
.loop:
    ; multiplier >>= 1, low bit into carry
    LSR $BF : ROR $BE : ROR $BD : ROR $BC
    ROR $BB : ROR $BA : ROR $B9 : ROR $B8
    BCC .no_add
    CLC
    LDA _u64mul_acc+0 : ADC $B0 : STA _u64mul_acc+0
    LDA _u64mul_acc+1 : ADC $B1 : STA _u64mul_acc+1
    LDA _u64mul_acc+2 : ADC $B2 : STA _u64mul_acc+2
    LDA _u64mul_acc+3 : ADC $B3 : STA _u64mul_acc+3
    LDA _u64mul_acc+4 : ADC $B4 : STA _u64mul_acc+4
    LDA _u64mul_acc+5 : ADC $B5 : STA _u64mul_acc+5
    LDA _u64mul_acc+6 : ADC $B6 : STA _u64mul_acc+6
    LDA _u64mul_acc+7 : ADC $B7 : STA _u64mul_acc+7
.no_add:
    ; Early exit once the multiplier is exhausted — no later bit can contribute.
    LDA $B8 : ORA $B9 : ORA $BA : ORA $BB
    ORA $BC : ORA $BD : ORA $BE : ORA $BF
    BEQ .copy
    ASL $B0 : ROL $B1 : ROL $B2 : ROL $B3
    ROL $B4 : ROL $B5 : ROL $B6 : ROL $B7
    DEX
    BNE .loop
.copy:
    LDA _u64mul_acc+0 : STA $B0
    LDA _u64mul_acc+1 : STA $B1
    LDA _u64mul_acc+2 : STA $B2
    LDA _u64mul_acc+3 : STA $B3
    LDA _u64mul_acc+4 : STA $B4
    LDA _u64mul_acc+5 : STA $B5
    LDA _u64mul_acc+6 : STA $B6
    LDA _u64mul_acc+7 : STA $B7
    RTS

_u64mul_acc: .byte $00, $00, $00, $00, $00, $00, $00, $00
