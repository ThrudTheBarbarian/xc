; u64Add — unsigned 64-bit addition (same as signed, two's complement)
; Input:  $B0-$B7 = operand1, $B8-$BF = operand2
; Output: $B0-$B7 = result
;
; The runtime scratch window is $B0-$BF (xt.lnk [zp] `runtime`), which two
; 8-byte operands consume exactly — so anything needing more than the operands
; keeps its own storage rather than borrowing zero page from the var pool.

u64Add:
    CLC
    LDA $B0 : ADC $B8 : STA $B0
    LDA $B1 : ADC $B9 : STA $B1
    LDA $B2 : ADC $BA : STA $B2
    LDA $B3 : ADC $BB : STA $B3
    LDA $B4 : ADC $BC : STA $B4
    LDA $B5 : ADC $BD : STA $B5
    LDA $B6 : ADC $BE : STA $B6
    LDA $B7 : ADC $BF : STA $B7
    RTS
