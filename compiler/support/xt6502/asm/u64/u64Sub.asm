; u64Sub — unsigned 64-bit subtraction (same as signed, two's complement)
; Input:  $B0-$B7 = operand1, $B8-$BF = operand2
; Output: $B0-$B7 = operand1 - operand2

u64Sub:
    SEC
    LDA $B0 : SBC $B8 : STA $B0
    LDA $B1 : SBC $B9 : STA $B1
    LDA $B2 : SBC $BA : STA $B2
    LDA $B3 : SBC $BB : STA $B3
    LDA $B4 : SBC $BC : STA $B4
    LDA $B5 : SBC $BD : STA $B5
    LDA $B6 : SBC $BE : STA $B6
    LDA $B7 : SBC $BF : STA $B7
    RTS
