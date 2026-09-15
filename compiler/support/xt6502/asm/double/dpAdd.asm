; dpAdd — add two 8-byte doubles
; Input:  $B0-$B7 = op1, $B8-$BF = op2
; Output: $B0-$B7 = op1 + op2
;
; Double format: byte 0 flags (bit 0=sign, 1=uflow, 2=oflow, 3=NaN,
; 4=zero, 5=inf), byte 1 signed base-2 exponent, bytes 2-7 48-bit
; big-endian mantissa with the implicit leading 1 unstored.
;
; Method
; ──────
; Textbook align/add/normalise, mirroring fpAdd.asm's 4-byte-with-
; guard approach but widened to 7-byte mantissa+guard. Each operand
; is expanded to 56 bits by right-shifting the 48-bit mantissa one
; place and ORing the implicit leading 1 in at bit 47; the bit that
; rolled off the LSB lands in the guard byte's bit 7 rather than
; being dropped, so both inputs pass through the add losslessly and
; the final round-half-up uses the guard's high bit. The previous
; Tier 1 stub just returned op1 unchanged; this is the real routine.
;
; NOTE: mirrored by generic/float/fpAdd.asm. The two files use the
; same algorithm; only the mantissa width (3 vs 6 bytes) and the
; guard slot location change. xta has no assembler-level
; conditionals, so a true shared template isn't expressible — keep
; the two files in sync by hand.
;
; Storage layout
; ──────────────
; ZP runtime window ($B0-$BF):
;   $B0:     result flags (final output, set in finish)
;   $B1:     result exponent (final output)
;   $B2-$B7: op1 mantissa bytes 47..0 (high to low, 6 bytes)
;   $B8-$B9: op2 flags / exponent (input only; consumed by align)
;   $BA-$BF: op2 mantissa bytes 47..0 (high to low, 6 bytes)
;
; Data-section scratch (declared at end of file):
;   _dpadd_gA:    op1 guard byte (extends $B2-$B7 to 56 bits)
;   _dpadd_gB:    op2 guard byte (extends $BA-$BF to 56 bits)
;   _dpadd_sign:  provisional result sign (written before the
;                 add/subtract branch, possibly flipped if the
;                 subtract yields a negative, then copied to $B0
;                 at the finish label).
;
; The $B0-$BF window is exhausted by the two 8-byte operands, so
; there's no room for the guard bytes or sign scratch in ZP; see
; dpMul.asm and doc/double.md §"ZP pressure" for the same choice.

dpAdd:
    ; Infinity operand → NaN. We don't do IEEE-style infinity
    ; arithmetic (∞ + ∞, ∞ − ∞, etc.).
    LDA $B0
    ORA $B8
    AND #$20
    BNE .da_ret_nan

    ; NaN / overflow / underflow pass-through
    LDA $B0
    AND #$0E
    BNE .da_ret_a
    LDA $B8
    AND #$0E
    BNE .da_ret_b

    ; Zero short-circuits: 0 + x = x, x + 0 = x
    LDA $B0
    AND #$10
    BNE .da_ret_b
    LDA $B8
    AND #$10
    BNE .da_ret_a

    ; Initialise both guard bytes to zero. From here the mantissa of
    ; each operand is treated as a 56-bit big-endian value:
    ;   op1 = $B2,$B3,$B4,$B5,$B6,$B7,_dpadd_gA
    ;   op2 = $BA,$BB,$BC,$BD,$BE,$BF,_dpadd_gB
    LDA #$00
    STA _dpadd_gA
    STA _dpadd_gB

    ; Install the implicit leading 1 in op1: shift the 56-bit
    ; mantissa right by 1 (the original LSB lands in bit 7 of gA
    ; instead of being dropped) then OR bit 47 of $B2 to 1. Bump
    ; the exponent by 1 to compensate.
    LSR $B2
    ROR $B3
    ROR $B4
    ROR $B5
    ROR $B6
    ROR $B7
    ROR _dpadd_gA
    LDA $B2
    ORA #$80
    STA $B2
    INC $B1

    ; Same for op2.
    LSR $BA
    ROR $BB
    ROR $BC
    ROR $BD
    ROR $BE
    ROR $BF
    ROR _dpadd_gB
    LDA $BA
    ORA #$80
    STA $BA
    INC $B9

    ; Align mantissas by shifting the smaller-exponent operand
    ; right by |exp_diff| bits. With a 56-bit mantissa, the
    ; smaller operand becomes negligible once its leading 1 has
    ; fallen off the bottom of the guard byte (≥ 56 shifts).
    LDA $B1
    SEC
    SBC $B9
    BEQ .da_aligned
    BMI .da_shift_op1

    ; exp1 > exp2: shift op2 right by A bits.
    TAX
    CPX #56
    BCS .da_drop_op2
.da_shift_op2_loop:
    LSR $BA
    ROR $BB
    ROR $BC
    ROR $BD
    ROR $BE
    ROR $BF
    ROR _dpadd_gB
    DEX
    BNE .da_shift_op2_loop
    LDA $B1
    STA $B9
    JMP .da_aligned

.da_shift_op1:
    ; exp2 > exp1: A is the (negative) diff, compute count = -A
    EOR #$FF
    CLC
    ADC #$01
    TAX
    CPX #56
    BCS .da_drop_op1
.da_shift_op1_loop:
    LSR $B2
    ROR $B3
    ROR $B4
    ROR $B5
    ROR $B6
    ROR $B7
    ROR _dpadd_gA
    DEX
    BNE .da_shift_op1_loop
    LDA $B9
    STA $B1

.da_aligned:
    ; Compare sign bits. Equal → add; different → subtract. The
    ; provisional result sign lives in _dpadd_sign.
    LDA $B0
    AND #$01
    STA _dpadd_sign
    LDA $B8
    AND #$01
    CMP _dpadd_sign
    BNE .da_subtract

    ; Same sign: 7-byte add of the (mantissa, guard) pairs. Both
    ; inputs have bit 47 of their high byte set so the carry out
    ; of the $B2 ADC is always 1 — the final ROR sequence shifts
    ; the resulting 57-bit value right by one, putting the carry
    ; back into bit 7 of $B2 and bumping the exponent by 1.
    CLC
    LDA _dpadd_gA
    ADC _dpadd_gB
    STA _dpadd_gA
    LDA $B7
    ADC $BF
    STA $B7
    LDA $B6
    ADC $BE
    STA $B6
    LDA $B5
    ADC $BD
    STA $B5
    LDA $B4
    ADC $BC
    STA $B4
    LDA $B3
    ADC $BB
    STA $B3
    LDA $B2
    ADC $BA
    STA $B2
    ROR $B2
    ROR $B3
    ROR $B4
    ROR $B5
    ROR $B6
    ROR $B7
    ROR _dpadd_gA
    INC $B1
    JMP .da_finish

.da_subtract:
    ; Different signs: subtract magnitudes. Assume op1 has the
    ; larger magnitude; if not, the result comes out negative and
    ; we flip below.
    SEC
    LDA _dpadd_gA
    SBC _dpadd_gB
    STA _dpadd_gA
    LDA $B7
    SBC $BF
    STA $B7
    LDA $B6
    SBC $BE
    STA $B6
    LDA $B5
    SBC $BD
    STA $B5
    LDA $B4
    SBC $BC
    STA $B4
    LDA $B3
    SBC $BB
    STA $B3
    LDA $B2
    SBC $BA
    STA $B2
    BCS .da_sub_positive
    ; Result came out negative: 7-byte two's-complement negate
    ; and flip the provisional sign bit.
    LDA _dpadd_gA
    EOR #$FF
    STA _dpadd_gA
    LDA $B7
    EOR #$FF
    STA $B7
    LDA $B6
    EOR #$FF
    STA $B6
    LDA $B5
    EOR #$FF
    STA $B5
    LDA $B4
    EOR #$FF
    STA $B4
    LDA $B3
    EOR #$FF
    STA $B3
    LDA $B2
    EOR #$FF
    STA $B2
    INC _dpadd_gA
    BNE .da_sub_neg_done
    INC $B7
    BNE .da_sub_neg_done
    INC $B6
    BNE .da_sub_neg_done
    INC $B5
    BNE .da_sub_neg_done
    INC $B4
    BNE .da_sub_neg_done
    INC $B3
    BNE .da_sub_neg_done
    INC $B2
.da_sub_neg_done:
    LDA _dpadd_sign
    EOR #$01
    STA _dpadd_sign
.da_sub_positive:

.da_finish:
    ; Zero-result guard — if all 7 mantissa+guard bytes are 0 the
    ; normalise loop would spin forever. Return a proper zero.
    LDA $B2
    ORA $B3
    ORA $B4
    ORA $B5
    ORA $B6
    ORA $B7
    ORA _dpadd_gA
    BEQ .da_return_zero

    ; Normalise: shift the 56-bit mantissa left until bit 47 of
    ; $B2 is set, decrementing the exponent on each shift.
.da_norm_loop:
    LDA $B2
    BMI .da_norm_done
    ASL _dpadd_gA
    ROL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    JMP .da_norm_loop
.da_norm_done:

    ; Convert back to format 1 (strip the leading 1): shift left
    ; once more so bit 47 falls off the top of $B2, decrement the
    ; exponent. The guard byte shifts up by 1 too — its old bit 7
    ; becomes bit 0 of $B7 and its old bit 6 becomes the new bit
    ; 7 of gA, which is the bit just below the format's LSB (the
    ; round bit).
    ASL _dpadd_gA
    ROL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1

    ; Round-half-up: if the round bit (bit 7 of gA) is set,
    ; increment the 48-bit stored mantissa. On overflow past 2^48
    ; (all bytes went from $FF to $00) the true value was 2^(exp+1),
    ; which in the stored-mantissa format is `mantissa=0, exp+1` —
    ; the implicit leading 1 carries the whole value. Setting $B2
    ; to $80 here would encode 1.5 * 2^(exp+1) instead of 1.0.
    BIT _dpadd_gA
    BPL .da_no_round
    INC $B7
    BNE .da_no_round
    INC $B6
    BNE .da_no_round
    INC $B5
    BNE .da_no_round
    INC $B4
    BNE .da_no_round
    INC $B3
    BNE .da_no_round
    INC $B2
    BNE .da_no_round
    ; All mantissa bytes overflowed $FF→$00 — they're already $00,
    ; nothing more to clear. Just bump the exponent to promote to
    ; the next power of 2.
    INC $B1
.da_no_round:

    LDA _dpadd_sign
    STA $B0
    RTS

.da_return_zero:
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

.da_drop_op2:
    ; op2 too small to matter. Result = op1, but we already
    ; converted op1 to "top bit set" 56-bit form — fold it back to
    ; format 1 (same convert-back + round-half-up sequence as the
    ; main path).
    ASL _dpadd_gA
    ROL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    BIT _dpadd_gA
    BPL .da_drop_op2_done
    INC $B7
    BNE .da_drop_op2_done
    INC $B6
    BNE .da_drop_op2_done
    INC $B5
    BNE .da_drop_op2_done
    INC $B4
    BNE .da_drop_op2_done
    INC $B3
    BNE .da_drop_op2_done
    INC $B2
    BNE .da_drop_op2_done
    LDA #$80
    STA $B2
    LDA #$00
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    INC $B1
.da_drop_op2_done:
    RTS

.da_drop_op1:
    ; op1 too small. Move op2 into op1's slot, then convert back.
    LDA $B8
    STA $B0
    LDA $B9
    STA $B1
    LDA $BA
    STA $B2
    LDA $BB
    STA $B3
    LDA $BC
    STA $B4
    LDA $BD
    STA $B5
    LDA $BE
    STA $B6
    LDA $BF
    STA $B7
    LDA _dpadd_gB
    STA _dpadd_gA
    ASL _dpadd_gA
    ROL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    BIT _dpadd_gA
    BPL .da_drop_op1_done
    INC $B7
    BNE .da_drop_op1_done
    INC $B6
    BNE .da_drop_op1_done
    INC $B5
    BNE .da_drop_op1_done
    INC $B4
    BNE .da_drop_op1_done
    INC $B3
    BNE .da_drop_op1_done
    INC $B2
    BNE .da_drop_op1_done
    LDA #$80
    STA $B2
    LDA #$00
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    INC $B1
.da_drop_op1_done:
    RTS

.da_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    STA $B5 : STA $B6 : STA $B7
    RTS

.da_ret_a:
    RTS                 ; op1 unchanged (specials / zero path)

.da_ret_b:
    LDA $B8
    STA $B0
    LDA $B9
    STA $B1
    LDA $BA
    STA $B2
    LDA $BB
    STA $B3
    LDA $BC
    STA $B4
    LDA $BD
    STA $B5
    LDA $BE
    STA $B6
    LDA $BF
    STA $B7
    RTS

; Data-section scratch.
_dpadd_gA:
    .byte $00
_dpadd_gB:
    .byte $00
_dpadd_sign:
    .byte $00
