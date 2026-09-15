; u64Div — unsigned 64-bit divide
; Input:  $B0-$B7 = dividend, $B8-$BF = divisor
; Output: $B0-$B7 = quotient, $B8-$BF = remainder
;
; Restoring long division, the same shape as u32Div one width up. u32Div keeps
; its remainder in $B8-$BB; here both operands already fill $B0-$BF, so the
; remainder is module storage addressed absolutely and the divisor is read
; from zero page in place.

u64Div:
    LDA #$00
    STA _u64div_rem+0 : STA _u64div_rem+1
    STA _u64div_rem+2 : STA _u64div_rem+3
    STA _u64div_rem+4 : STA _u64div_rem+5
    STA _u64div_rem+6 : STA _u64div_rem+7
    LDX #64
.loop:
    ; dividend <<= 1, top bit into the remainder
    ASL $B0 : ROL $B1 : ROL $B2 : ROL $B3
    ROL $B4 : ROL $B5 : ROL $B6 : ROL $B7
    ROL _u64div_rem+0 : ROL _u64div_rem+1
    ROL _u64div_rem+2 : ROL _u64div_rem+3
    ROL _u64div_rem+4 : ROL _u64div_rem+5
    ROL _u64div_rem+6 : ROL _u64div_rem+7
    ; trial subtraction: remainder - divisor, kept only if it did not borrow
    SEC
    LDA _u64div_rem+0 : SBC $B8 : STA _u64div_tmp+0
    LDA _u64div_rem+1 : SBC $B9 : STA _u64div_tmp+1
    LDA _u64div_rem+2 : SBC $BA : STA _u64div_tmp+2
    LDA _u64div_rem+3 : SBC $BB : STA _u64div_tmp+3
    LDA _u64div_rem+4 : SBC $BC : STA _u64div_tmp+4
    LDA _u64div_rem+5 : SBC $BD : STA _u64div_tmp+5
    LDA _u64div_rem+6 : SBC $BE : STA _u64div_tmp+6
    LDA _u64div_rem+7 : SBC $BF : STA _u64div_tmp+7
    BCC .no_sub
    LDA _u64div_tmp+0 : STA _u64div_rem+0
    LDA _u64div_tmp+1 : STA _u64div_rem+1
    LDA _u64div_tmp+2 : STA _u64div_rem+2
    LDA _u64div_tmp+3 : STA _u64div_rem+3
    LDA _u64div_tmp+4 : STA _u64div_rem+4
    LDA _u64div_tmp+5 : STA _u64div_rem+5
    LDA _u64div_tmp+6 : STA _u64div_rem+6
    LDA _u64div_tmp+7 : STA _u64div_rem+7
    INC $B0                      ; quotient bit
.no_sub:
    DEX
    BNE .loop
    LDA _u64div_rem+0 : STA $B8
    LDA _u64div_rem+1 : STA $B9
    LDA _u64div_rem+2 : STA $BA
    LDA _u64div_rem+3 : STA $BB
    LDA _u64div_rem+4 : STA $BC
    LDA _u64div_rem+5 : STA $BD
    LDA _u64div_rem+6 : STA $BE
    LDA _u64div_rem+7 : STA $BF
    RTS

_u64div_rem: .byte $00, $00, $00, $00, $00, $00, $00, $00
_u64div_tmp: .byte $00, $00, $00, $00, $00, $00, $00, $00
