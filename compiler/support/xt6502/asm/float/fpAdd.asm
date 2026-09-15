; fpAdd — add two 5-byte floats
; Input:  $B0-$B4 = op1, $B5-$B9 = op2
; Output: $B0-$B4 = op1 + op2
;
; NOTE: mirrored by generic/double/dpAdd.asm; keep in sync.
;
; Float format: byte 0 flags (bit 0=sign, 1=uflow, 2=oflow, 3=NaN,
; 4=zero), byte 1 signed base-2 exponent, bytes 2-4 24-bit mantissa
; with the implicit leading 1 unstored (value = 1.mantissa * 2^exp).
;
; Method
; ──────
; Same family as the textbook align/add/normalise routine, but the
; mantissas are extended with an 8-bit guard byte (4 bytes / 32 bits
; total). The original LSB of each mantissa rolls into the guard byte
; during the "install implicit leading 1" right-shift instead of being
; dropped, alignment shifts likewise carry bits into the guard rather
; than off the bottom, and the final fold back to format 1 uses the
; guard's high bit for round-half-up. The previous routine `LSR $B2 :
; ROR $B3 : ROR $B4` and discarded the LSB outright, costing one bit
; of precision per operand per call; this one preserves both inputs
; bit-for-bit through the 4-byte add and only quantises at the very
; end.
;
; Storage layout (all inside the reserved $B0-$BF runtime window):
;   $B0:      result flags / sign byte (final output)
;   $B1:      result exponent (final output)
;   $B2-$B4:  op1 mantissa bytes 23..0 (high to low)
;   $B5-$B6:  op2 sign / exponent (input only)
;   $B7-$B9:  op2 mantissa bytes 23..0
;   $BA:      op1 guard byte (extends $B2-$B4 to 32 bits)
;   $BB:      op2 guard byte (extends $B7-$B9 to 32 bits)
;   $BC:      provisional result sign (was at $BA in the prior version,
;             relocated because $BA is now op1's guard byte)

fpAdd:
    ; Infinity operand → NaN. We don't do IEEE-style infinity
    ; arithmetic (∞ + ∞, ∞ − ∞, etc.); only fpDiv/fpTan generate ±∞,
    ; and here it degrades cleanly to NaN.
    LDA $B0
    ORA $B5
    AND #$20
    BNE .fa_ret_nan

    ; NaN / overflow / underflow pass-through
    LDA $B0
    AND #$0E
    BNE .fa_ret_a
    LDA $B5
    AND #$0E
    BNE .fa_ret_b

    ; Zero short-circuits: 0 + x = x, x + 0 = x
    LDA $B0
    AND #$10
    BNE .fa_ret_b
    LDA $B5
    AND #$10
    BNE .fa_ret_a

    ; Initialise both guard bytes to zero. From here on out the
    ; mantissa of each operand is treated as a 32-bit big-endian
    ; value: op1 = $B2,$B3,$B4,$BA  and  op2 = $B7,$B8,$B9,$BB.
    LDA #$00
    STA $BA
    STA $BB

    ; Install the implicit leading 1 in op1: shift the 32-bit mantissa
    ; right by 1 (the original LSB lands in bit 7 of $BA instead of
    ; being dropped) then OR bit 23 of $B2 to 1. Bump the exponent by
    ; 1 to compensate for the right shift.
    LSR $B2
    ROR $B3
    ROR $B4
    ROR $BA
    LDA $B2
    ORA #$80
    STA $B2
    INC $B1

    ; Same for op2.
    LSR $B7
    ROR $B8
    ROR $B9
    ROR $BB
    LDA $B7
    ORA #$80
    STA $B7
    INC $B6

    ; Align mantissas by shifting the smaller-exponent operand right.
    ; With a 32-bit mantissa, an operand becomes negligible only after
    ; ≥ 32 right shifts (at which point its leading 1 has fallen off
    ; the bottom of the guard byte).
    LDA $B1
    SEC
    SBC $B6
    BEQ .fa_aligned
    BMI .fa_shift_op1

    ; exp1 > exp2: shift op2 right by A bits.
    TAX
    CPX #32
    BCS .fa_drop_op2
.fa_shift_op2_loop:
    LSR $B7
    ROR $B8
    ROR $B9
    ROR $BB
    DEX
    BNE .fa_shift_op2_loop
    LDA $B1
    STA $B6
    JMP .fa_aligned

.fa_shift_op1:
    ; exp2 > exp1: A is the (negative) diff, compute count = -A
    EOR #$FF
    CLC
    ADC #$01
    TAX
    CPX #32
    BCS .fa_drop_op1
.fa_shift_op1_loop:
    LSR $B2
    ROR $B3
    ROR $B4
    ROR $BA
    DEX
    BNE .fa_shift_op1_loop
    LDA $B6
    STA $B1

.fa_aligned:
    ; Compare sign bits. Equal → add; different → subtract. The
    ; provisional result sign lives in $BC (used to be $BA, but $BA
    ; is now op1's guard byte).
    LDA $B0
    AND #$01
    STA $BC
    LDA $B5
    AND #$01
    CMP $BC
    BNE .fa_subtract

    ; Same sign: 4-byte add of the (mantissa, guard) pairs. Both
    ; inputs have bit 23 of their high byte set so the carry out of
    ; the $B2 ADC is always 1 — the final ROR sequence shifts the
    ; resulting 33-bit value right by one, putting the carry back
    ; into bit 7 of $B2 and bumping the exponent by 1.
    CLC
    LDA $BA
    ADC $BB
    STA $BA
    LDA $B4
    ADC $B9
    STA $B4
    LDA $B3
    ADC $B8
    STA $B3
    LDA $B2
    ADC $B7
    STA $B2
    ROR $B2
    ROR $B3
    ROR $B4
    ROR $BA
    INC $B1
    JMP .fa_finish

.fa_subtract:
    ; Different signs: subtract magnitudes. Assume op1 has the larger
    ; magnitude (if not, the result comes out negative and we flip).
    SEC
    LDA $BA
    SBC $BB
    STA $BA
    LDA $B4
    SBC $B9
    STA $B4
    LDA $B3
    SBC $B8
    STA $B3
    LDA $B2
    SBC $B7
    STA $B2
    BCS .fa_sub_positive
    ; Result came out negative: 4-byte two's-complement negate and
    ; flip the sign bit.
    LDA $BA
    EOR #$FF
    STA $BA
    LDA $B4
    EOR #$FF
    STA $B4
    LDA $B3
    EOR #$FF
    STA $B3
    LDA $B2
    EOR #$FF
    STA $B2
    INC $BA
    BNE .fa_sub_neg_done
    INC $B4
    BNE .fa_sub_neg_done
    INC $B3
    BNE .fa_sub_neg_done
    INC $B2
.fa_sub_neg_done:
    LDA $BC
    EOR #$01
    STA $BC
.fa_sub_positive:

.fa_finish:
    ; Zero-result guard — if all 4 mantissa bytes (including the
    ; guard) are 0 the normalise loop would spin forever (the old
    ; hang). Return a proper zero.
    LDA $B2
    ORA $B3
    ORA $B4
    ORA $BA
    BEQ .fa_return_zero

    ; Normalise: shift the 32-bit mantissa left until bit 23 of $B2
    ; is set, decrementing the exponent on each shift.
.fa_norm_loop:
    LDA $B2
    BMI .fa_norm_done
    ASL $BA
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    JMP .fa_norm_loop
.fa_norm_done:

    ; Convert back to format 1 (strip the leading 1): shift left once
    ; more so bit 23 falls off the top of $B2, decrement the exponent.
    ; The guard byte shifts up by 1 too — its old bit 7 becomes bit 0
    ; of $B4 and its old bit 6 becomes the new bit 7 of $BA, which is
    ; the bit just below the format's LSB (i.e. the round bit).
    ASL $BA
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1

    ; Round-half-up: if the round bit (bit 7 of $BA) is set, increment
    ; the 24-bit stored mantissa. On overflow past 2^24 (all bytes
    ; went $FF→$00) the true value is 2^(exp+1), which in the
    ; stored-mantissa format is just `mantissa=0, exp+1` — the
    ; implicit leading 1 already carries the whole value.
    BIT $BA
    BPL .fa_no_round
    INC $B4
    BNE .fa_no_round
    INC $B3
    BNE .fa_no_round
    INC $B2
    BNE .fa_no_round
    ; All three mantissa bytes rolled over to $00 already — just
    ; bump the exponent to promote to the next power of 2.
    INC $B1
.fa_no_round:

    LDA $BC
    STA $B0
    RTS

.fa_return_zero:
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.fa_drop_op2:
    ; op2 too small to matter. Result = op1, but we already converted
    ; op1 to "top bit set" 32-bit form — fold it back to format 1
    ; (same convert-back + round-half-up sequence as the main path).
    ASL $BA
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    BIT $BA
    BPL .fa_drop_op2_done
    INC $B4
    BNE .fa_drop_op2_done
    INC $B3
    BNE .fa_drop_op2_done
    INC $B2
    BNE .fa_drop_op2_done
    ; Mantissa overflowed $FFFFFF → $000000; already zero. Bump exp
    ; to encode 1.0 * 2^(exp+1) in the stored-mantissa-is-zero form.
    INC $B1
.fa_drop_op2_done:
    RTS

.fa_drop_op1:
    ; op1 too small. Move op2 into op1's slot, then convert back.
    LDA $B5
    STA $B0
    LDA $B6
    STA $B1
    LDA $B7
    STA $B2
    LDA $B8
    STA $B3
    LDA $B9
    STA $B4
    LDA $BB
    STA $BA
    ASL $BA
    ROL $B4
    ROL $B3
    ROL $B2
    DEC $B1
    BIT $BA
    BPL .fa_drop_op1_done
    INC $B4
    BNE .fa_drop_op1_done
    INC $B3
    BNE .fa_drop_op1_done
    INC $B2
    BNE .fa_drop_op1_done
    ; Same overflow-to-next-power-of-2 case as above.
    INC $B1
.fa_drop_op1_done:
    RTS

.fa_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS

.fa_ret_a:
    RTS                      ; op1 unchanged (specials / zero path, no conversion done)

.fa_ret_b:
    LDA $B5
    STA $B0
    LDA $B6
    STA $B1
    LDA $B7
    STA $B2
    LDA $B8
    STA $B3
    LDA $B9
    STA $B4
    RTS
