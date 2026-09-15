; u32Sub — unsigned 32-bit subtraction
; Input:  $B0-$B3 = operand1, $B4-$B7 = operand2
; Output: $B0-$B3 = operand1 - operand2

u32Sub:
    SEC
    LDA $B0 : SBC $B4 : STA $B0
    LDA $B1 : SBC $B5 : STA $B1
    LDA $B2 : SBC $B6 : STA $B2
    LDA $B3 : SBC $B7 : STA $B3
    RTS
