; dpDiv — divide double op1 by double op2
; Input:  $B0-$B7 = dividend, $B8-$BF = divisor
; Output: $B0-$B7 = dividend / divisor
;
; Double format: byte 0 flags, byte 1 signed exp, bytes 2-7 48-bit
; big-endian mantissa with implicit leading 1.
;
; Method: install the implicit leading 1 in both mantissas. If M1 ≥
; M2, shift M1 right by 1 and bump the result exponent so the ratio
; lands in [0.5, 1.0) and the 48-bit quotient has bit 47 set. Then
; run a classic restoring-division loop for 48 iterations, doubling
; a 49-bit remainder and conditionally subtracting the divisor.
; Finally convert the quotient back to the implicit-leading-1 form.
;
; NOTE: mirrored by generic/float/fpDiv.asm; keep in sync.
;
; Storage layout
; ──────────────
; ZP runtime window ($B0-$BF):
;   $B0:     result flags (final output)
;   $B1:     result exponent (final output)
;   $B2-$B7: M1 mantissa at entry → becomes Q (quotient) during
;            the divide loop, after M1 is copied to R (scratch).
;   $B8-$B9: consumed in phase 2 (op2 flags/exp), then unused.
;   $BA-$BF: M2 mantissa (divisor, preserved across the loop).
;
; Data-section scratch:
;   _dpdiv_R:    6 bytes — the remainder, big-endian (R[0] = high).
;                Initially holds M1, then shifts left across
;                iterations.
;   _dpdiv_Rhi:  1 byte — extra bit above R (bit 48) to make R a
;                49-bit value; needed because after R <<= 1 the
;                original MSB (which is always 1 after the
;                M1-shift-if-needed step) moves above the 48-bit
;                window and must be preserved for the compare
;                against M2.

dpDiv:
    ; Infinity operand → NaN. We don't do IEEE-style infinity
    ; arithmetic; only dpDiv's divide-by-zero path and dpTan's
    ; pole detection generate infinity.
    LDA $B0
    ORA $B8
    AND #$20
    BNE .dd_ret_nan

    ; Divide-by-zero priority: divisor zero → ±∞ (0/0 inside the
    ; handler returns NaN). Don't also test mantissa-all-zero here
    ; — 1.0 encodes as all-zero mantissa and would be misdiagnosed.
    LDA $B8
    AND #$10
    BNE .dd_divzero

    ; Zero dividend → zero result (after the div-by-zero check).
    LDA $B0
    AND #$10
    BNE .dd_retzero

    ; NaN / overflow / underflow pass-through
    LDA $B0
    AND #$0E
    BNE .dd_ret_a
    LDA $B8
    AND #$0E
    BNE .dd_ret_nan

    ; Result sign → $B0 (op1 flags no longer needed)
    LDA $B0
    EOR $B8
    AND #$01
    STA $B0

    ; Install implicit leading 1 in both mantissas
    LSR $B2
    ROR $B3
    ROR $B4
    ROR $B5
    ROR $B6
    ROR $B7
    LDA $B2
    ORA #$80
    STA $B2
    INC $B1

    LSR $BA
    ROR $BB
    ROR $BC
    ROR $BD
    ROR $BE
    ROR $BF
    LDA $BA
    ORA #$80
    STA $BA
    INC $B9

    ; Initial result exponent = e1' - e2'
    LDA $B1
    SEC
    SBC $B9
    STA $B1

    ; If M1 ≥ M2, shift M1 right and bump the exponent — keeps the
    ; ratio in [0.5, 1.0) so the quotient's bit 47 is guaranteed
    ; set. 6-byte big-endian compare (byte 0 = high).
    LDA $B2
    CMP $BA
    BCC .dd_m1_less
    BNE .dd_m1_shift
    LDA $B3
    CMP $BB
    BCC .dd_m1_less
    BNE .dd_m1_shift
    LDA $B4
    CMP $BC
    BCC .dd_m1_less
    BNE .dd_m1_shift
    LDA $B5
    CMP $BD
    BCC .dd_m1_less
    BNE .dd_m1_shift
    LDA $B6
    CMP $BE
    BCC .dd_m1_less
    BNE .dd_m1_shift
    LDA $B7
    CMP $BF
    BCC .dd_m1_less
.dd_m1_shift:
    LSR $B2
    ROR $B3
    ROR $B4
    ROR $B5
    ROR $B6
    ROR $B7
    INC $B1
.dd_m1_less:

    ; Initialise R := M1 in _dpdiv_R (6 bytes, big-endian).
    ; R_hi (bit 48) := 0.
    ; Clear Q (quotient accumulator) in $B2-$B7.
    LDA $B2
    STA _dpdiv_R
    LDA $B3
    STA _dpdiv_R+1
    LDA $B4
    STA _dpdiv_R+2
    LDA $B5
    STA _dpdiv_R+3
    LDA $B6
    STA _dpdiv_R+4
    LDA $B7
    STA _dpdiv_R+5
    LDA #$00
    STA _dpdiv_Rhi
    STA $B2
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7

    LDX #48
.dd_div_loop:
    ; Q <<= 1 (the INC $B7 below will OR-in the new low bit if we
    ; subtract)
    ASL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    ; R <<= 1 (49-bit)
    ASL _dpdiv_R+5
    ROL _dpdiv_R+4
    ROL _dpdiv_R+3
    ROL _dpdiv_R+2
    ROL _dpdiv_R+1
    ROL _dpdiv_R
    ROL _dpdiv_Rhi

    ; Compare R (49-bit) with M2 (48-bit). R_hi set → R > M2
    ; unconditionally.
    LDA _dpdiv_Rhi
    LSR A
    BCS .dd_do_sub
    LDA _dpdiv_R
    CMP $BA
    BCC .dd_no_sub
    BNE .dd_do_sub
    LDA _dpdiv_R+1
    CMP $BB
    BCC .dd_no_sub
    BNE .dd_do_sub
    LDA _dpdiv_R+2
    CMP $BC
    BCC .dd_no_sub
    BNE .dd_do_sub
    LDA _dpdiv_R+3
    CMP $BD
    BCC .dd_no_sub
    BNE .dd_do_sub
    LDA _dpdiv_R+4
    CMP $BE
    BCC .dd_no_sub
    BNE .dd_do_sub
    LDA _dpdiv_R+5
    CMP $BF
    BCC .dd_no_sub
.dd_do_sub:
    SEC
    LDA _dpdiv_R+5
    SBC $BF
    STA _dpdiv_R+5
    LDA _dpdiv_R+4
    SBC $BE
    STA _dpdiv_R+4
    LDA _dpdiv_R+3
    SBC $BD
    STA _dpdiv_R+3
    LDA _dpdiv_R+2
    SBC $BC
    STA _dpdiv_R+2
    LDA _dpdiv_R+1
    SBC $BB
    STA _dpdiv_R+1
    LDA _dpdiv_R
    SBC $BA
    STA _dpdiv_R
    LDA _dpdiv_Rhi
    SBC #$00
    STA _dpdiv_Rhi
    INC $B7
.dd_no_sub:
    DEX
    BNE .dd_div_loop

    ; Q should already have bit 47 set by construction (M1 ∈
    ; [M2/2, M2)). Zero-guard against a degenerate path, and
    ; normalise if bit 47 somehow came out clear.
    LDA $B2
    ORA $B3
    ORA $B4
    ORA $B5
    ORA $B6
    ORA $B7
    BEQ .dd_retzero
.dd_norm:
    LDA $B2
    BMI .dd_norm_done
    ASL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    JMP .dd_norm
.dd_norm_done:

    ; Convert the result back to format 1: shift left once, DEC exp.
    ASL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    RTS

.dd_divzero:
    ; Divisor is zero. If dividend is also zero → 0/0 = NaN;
    ; otherwise return ±∞ with sign = op1_sign XOR op2_sign.
    LDA $B0
    AND #$10
    BNE .dd_ret_nan
    LDA $B0
    EOR $B8
    AND #$01
    ORA #$20                ; infinity flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    RTS

.dd_retzero:
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    RTS

.dd_ret_a:
    RTS                     ; op1 is special; return unchanged

.dd_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    RTS

; Data-section scratch.
_dpdiv_R:
    .byte $00,$00,$00,$00,$00,$00
_dpdiv_Rhi:
    .byte $00
