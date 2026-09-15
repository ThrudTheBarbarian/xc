; u16Div — unsigned 16-bit divide
; Input:  $B0,$B1 = dividend (u16), $B2,$B3 = divisor (u16)
; Output: $B0,$B1 = quotient (u16), $B2,$B3 = remainder (u16)

u16Div:
    LDA #$00
    STA $B4         ; remainder lo
    STA $B5         ; remainder hi
    LDX #16
.loop:
    ASL $B0
    ROL $B1         ; shift dividend left
    ROL $B4
    ROL $B5         ; shift into remainder
    ; Compare remainder with divisor
    LDA $B4
    CMP $B2
    LDA $B5
    SBC $B3
    BCC .no_sub
    ; remainder >= divisor: subtract
    LDA $B4
    SEC
    SBC $B2
    STA $B4
    LDA $B5
    SBC $B3
    STA $B5
    INC $B0         ; set quotient bit
.no_sub:
    DEX
    BNE .loop
    LDA $B4 : STA $B2
    LDA $B5 : STA $B3
    RTS
