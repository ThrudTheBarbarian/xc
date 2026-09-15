; u32Div — unsigned 32-bit divide
; Input:  $B0-$B3 = dividend, $B4-$B7 = divisor
; Output: $B0-$B3 = quotient, $B4-$B7 = remainder

u32Div:
    LDA #$00
    STA $B8 : STA $B9 : STA $BA : STA $BB  ; remainder = 0
    LDX #32
.loop:
    ASL $B0 : ROL $B1 : ROL $B2 : ROL $B3  ; shift dividend left
    ROL $B8 : ROL $B9 : ROL $BA : ROL $BB  ; into remainder
    ; Compare remainder >= divisor
    SEC
    LDA $B8 : SBC $B4
    PHA
    LDA $B9 : SBC $B5
    PHA
    LDA $BA : SBC $B6
    PHA
    LDA $BB : SBC $B7
    BCC .no_sub
    ; Remainder >= divisor, commit subtraction
    STA $BB
    PLA : STA $BA
    PLA : STA $B9
    PLA : STA $B8
    INC $B0         ; set quotient bit
    JMP .next
.no_sub:
    PLA : PLA : PLA ; discard tentative results
.next:
    DEX
    BNE .loop
    ; Copy remainder to $B4-$B7
    LDA $B8 : STA $B4
    LDA $B9 : STA $B5
    LDA $BA : STA $B6
    LDA $BB : STA $B7
    RTS
