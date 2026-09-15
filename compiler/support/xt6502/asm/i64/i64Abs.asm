; i64Abs — absolute value of a signed 64-bit integer
; Input:  $B0-$B7 = operand
; Output: $B0-$B7 = |operand|

i64Abs:
    LDA $B7
    BPL .done
    SEC
    LDA #$00 : SBC $B0 : STA $B0
    LDA #$00 : SBC $B1 : STA $B1
    LDA #$00 : SBC $B2 : STA $B2
    LDA #$00 : SBC $B3 : STA $B3
    LDA #$00 : SBC $B4 : STA $B4
    LDA #$00 : SBC $B5 : STA $B5
    LDA #$00 : SBC $B6 : STA $B6
    LDA #$00 : SBC $B7 : STA $B7
.done:
    RTS
