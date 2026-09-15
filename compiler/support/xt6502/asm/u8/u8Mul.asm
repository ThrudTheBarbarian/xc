; u8Mul — unsigned 8-bit multiply
; Input:  $B0 = operand1 (u8), $B1 = operand2 (u8)
; Output: $B0 = result low byte (u8), $B1 = result high byte (u8)
;         Together they form a u16 product.
;
; Uses: A, X
; Method: shift-and-add

u8Mul:
    LDA #$00
    LDX #8          ; 8 bits to process
    CLC
.loop:
    ROR $B1         ; shift multiplier right, bit 0 into carry
    BCC .no_add
    CLC
    ADC $B0         ; add multiplicand if bit was set
.no_add:
    ROR A           ; shift partial product right (high byte)
    DEX
    BNE .loop
    ROR $B1         ; final shift of low byte
    STA $B0         ; A had the low partial; swap
    ; Actually the result high byte was shifted into $B1
    ; and the low byte is now in A → store properly
    TAY
    LDA $B1
    STA $B0         ; low byte of result
    STY $B1         ; high byte of result
    RTS
