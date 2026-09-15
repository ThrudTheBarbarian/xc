; fpDiv — divide float operand1 by float operand2
; Input:  $B0-$B4 = dividend, $B5-$B9 = divisor
; Output: $B0-$B4 = dividend / divisor
;
; NOTE: mirrored by generic/double/dpDiv.asm; keep in sync.
;
; Float format (shared with fpMul / fpAdd): byte 0 flags (bit 0=sign,
; 1=uflow, 2=oflow, 3=NaN, 4=zero), byte 1 signed base-2 exponent,
; bytes 2-4 24-bit mantissa with implicit leading 1.
;
; Method: convert both mantissas to "top bit set" form (install the
; implicit leading 1 via a right-shift + set-bit-23, +1 to each
; exponent). If the dividend mantissa is ≥ the divisor mantissa, shift
; the dividend right by 1 and bump the result exponent — this ensures
; M1 ∈ [M2/2, M2), so the ratio lands in [0.5, 1.0) and the 24-bit
; quotient has bit 23 set. Then run a classic restoring-division loop
; for 24 iterations, doubling a 25-bit remainder and conditionally
; subtracting the divisor. Finally convert the quotient back to the
; implicit-leading-1 format.

fpDiv:
    ; Infinity operand on either side → NaN. We don't do IEEE-style
    ; infinity arithmetic; only fpDiv's divide-by-zero path and fpTan's
    ; pole detection generate infinity, and nothing else accepts it as
    ; input. (fpDiv itself included — ∞ / x is meaningless here.)
    LDA $B0
    ORA $B5
    AND #$20
    BNE .fd_ret_nan

    ; Divide-by-zero priority: a divisor with the zero flag set returns
    ; ±∞ (sign = dividend_sign XOR divisor_sign). 0/0 is NaN and is
    ; handled inside .fd_divzero. Don't also test mantissa-all-zero
    ; here — 1.0 encodes as {0,0,0,0,0} and would be misdiagnosed.
    LDA $B5
    AND #$10
    BNE .fd_divzero

    ; Zero dividend → zero result (after the div-by-zero check above).
    LDA $B0
    AND #$10
    BNE .fd_retzero

    ; NaN / overflow / underflow pass-through
    LDA $B0
    AND #$0E
    BNE .fd_ret_a
    LDA $B5
    AND #$0E
    BNE .fd_ret_nan

    ; Result sign → $B0 (op1 flags no longer needed)
    LDA $B0
    EOR $B5
    AND #$01
    STA $B0

    ; Install implicit leading 1 in both mantissas
    LSR $B2
    ROR $B3
    ROR $B4
    LDA $B2
    ORA #$80
    STA $B2
    INC $B1

    LSR $B7
    ROR $B8
    ROR $B9
    LDA $B7
    ORA #$80
    STA $B7
    INC $B6

    ; Initial result exponent = e1' - e2'
    LDA $B1
    SEC
    SBC $B6
    STA $B1

    ; If M1 ≥ M2, shift M1 right and bump the exponent — keeps the
    ; ratio in [0.5, 1.0) so the quotient's bit 23 is guaranteed set.
    LDA $B2
    CMP $B7
    BCC .fd_m1_less
    BNE .fd_m1_shift
    LDA $B3
    CMP $B8
    BCC .fd_m1_less
    BNE .fd_m1_shift
    LDA $B4
    CMP $B9
    BCC .fd_m1_less
.fd_m1_shift:
    LSR $B2
    ROR $B3
    ROR $B4
    INC $B1
.fd_m1_less:

    ; Initialise R = M1 (in $B5:$B6:$BB), R_hi (bit 24) = $BA.
    ; Clear Q (quotient accumulator) in $B2-$B4.
    LDA $B2
    STA $B5
    LDA $B3
    STA $B6
    LDA $B4
    STA $BB
    LDA #$00
    STA $BA
    STA $B2
    STA $B3
    STA $B4

    LDX #24
.fd_div_loop:
    ; Q <<= 1 (the INC below will OR-in the new low bit if we subtract)
    ASL $B4
    ROL $B3
    ROL $B2
    ; R <<= 1 (25-bit)
    ASL $BB
    ROL $B6
    ROL $B5
    ROL $BA

    ; Compare R (25-bit) with M2 (24-bit). R_hi set → R > M2.
    LDA $BA
    LSR A
    BCS .fd_do_sub
    LDA $B5
    CMP $B7
    BCC .fd_no_sub
    BNE .fd_do_sub
    LDA $B6
    CMP $B8
    BCC .fd_no_sub
    BNE .fd_do_sub
    LDA $BB
    CMP $B9
    BCC .fd_no_sub
.fd_do_sub:
    SEC
    LDA $BB
    SBC $B9
    STA $BB
    LDA $B6
    SBC $B8
    STA $B6
    LDA $B5
    SBC $B7
    STA $B5
    LDA $BA
    SBC #$00
    STA $BA
    INC $B4
.fd_no_sub:
    DEX
    BNE .fd_div_loop

    ; Q should already have bit 23 set by construction (M1 ∈ [M2/2, M2)).
    ; Zero-guard as a belt-and-braces against the old BMI-hang, and
    ; normalise if — for any reason — bit 23 came out clear.
    LDA $B2
    ORA $B3
    ORA $B4
    BEQ .fd_retzero
.fd_norm:
    LDA $B2
    BMI .fd_norm_done
    ASL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    JMP .fd_norm
.fd_norm_done:

    ; Convert the result back to format 1: shift left once, DEC exp.
    ASL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    RTS

.fd_divzero:
    ; Divisor is zero. If dividend is also zero → 0/0 = NaN; otherwise
    ; return ±∞ with sign = dividend_sign XOR divisor_sign.
    LDA $B0
    AND #$10
    BNE .fd_ret_nan          ; 0/0 = NaN
    LDA $B0
    EOR $B5
    AND #$01                 ; combined sign
    ORA #$20                 ; infinity flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.fd_retzero:
    LDA #$10                 ; zero flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.fd_ret_a:
    RTS                      ; op1 is special; return unchanged

.fd_ret_nan:
    LDA #$08                 ; NaN
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS
