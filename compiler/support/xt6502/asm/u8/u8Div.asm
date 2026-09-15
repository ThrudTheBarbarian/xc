; u8Div — unsigned 8-bit divide
; Input:  $B0 = dividend (u8), $B1 = divisor (u8)
; Output: $B0 = quotient (u8), $B1 = remainder (u8)
;
; Uses: A, X

u8Div:
    LDA #$00        ; remainder
    LDX #8          ; 8 bits
.loop:
    ASL $B0         ; shift dividend left, MSB into carry
    ROL A           ; shift carry into remainder
    CMP $B1         ; compare remainder with divisor
    BCC .no_sub
    SBC $B1         ; subtract divisor from remainder
    INC $B0         ; set quotient bit
.no_sub:
    DEX
    BNE .loop
    STA $B1         ; store remainder
    RTS
