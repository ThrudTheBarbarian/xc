; fpMul — multiply two 5-byte floats
; Input:  $B0-$B4 = operand1, $B5-$B9 = operand2
; Output: $B0-$B4 = operand1 * operand2
;
; NOTE: mirrored by generic/double/dpMul.asm. The two files use the
; same (1+a)(1+b) algorithm and structure; only the mantissa width
; (3 vs 6 bytes) and loop count (24 vs 48) differ. xta has no
; assembler-level conditionals, so a true shared template isn't
; expressible — keep the two files in sync by hand: any bug fix or
; correctness audit applied to one MUST be carried over to the other.
;
; Float format: byte 0 flags (bit 0=sign, 1=uflow, 2=oflow, 3=NaN,
; 4=zero), byte 1 signed base-2 exponent, bytes 2-4 24-bit big-endian
; mantissa with the implicit leading 1 unstored (value = 1.mantissa *
; 2^exp). Zero is flagged by bit 4 of byte 0; its other bytes are
; ignored.
;
; Method
; ──────
; The previous implementation converted both operands to "fraction in
; [0.5, 1.0) with bit 23 set" by shifting each mantissa right one bit
; and ORing in $80, which discarded the LSB of every multiply input —
; a full bit of precision per operand per call. Compounded across the
; ~1000 multiplies in the AHL benchmark this dropped roughly 0.05 of
; signal per round-trip and the published "accuracy" digit drifted to
; ~0.37 (from a true zero on infinite precision).
;
; The new approach uses the (1+a)(1+b) decomposition:
;
;   value(op1) = (1 + A/2^24) * 2^ea   where A = stored mantissa of op1
;   value(op2) = (1 + B/2^24) * 2^eb
;   product    = (1 + A/2^24 + B/2^24 + A*B/2^48) * 2^(ea+eb)
;
; Let T = A + B + ⌊A*B / 2^24⌋ (top 24 bits of the 48-bit product).
; The fractional contribution above 1 is T/2^24, so:
;
;   product = (1 + T/2^24) * 2^(ea+eb)
;
; where T may overflow 24 bits. The overflow tells us whether the
; result lands in [1,2) (no overflow), [2,3) (one carry-out from
; the three additions) or [3,4) (two carry-outs). The first case
; needs no exponent bump; the latter two shift right by one and
; bump the exponent.
;
; Crucially every bit of the input mantissas is preserved through
; the multiply — the only precision loss is the bottom 24 bits of
; the 48-bit product (rounded back into T via the high bit of P[3]).
;
; Storage layout (all inside the reserved $B0-$BF runtime window):
;   $B0:      result flags / sign byte (final output, set in prologue)
;   $B1:      result exponent (final output, set in prologue)
;   $B2-$B4:  A mantissa (preserved across the multiply, then reused
;             to hold T = A + B + P_high)
;   $B5:      P[0]  — accumulator top byte (reusing op2 flags slot)
;   $B6:      P[1]  — (reusing op2 exponent slot)
;   $B7-$B9:  B mantissa (consumed by the multiply scan, restored
;             from the 6502 stack before the post-multiply add)
;   $BA:      P[2]
;   $BB:      P[3]  — high bit of this byte is the round bit
;   $BC:      P[4]
;   $BD:      P[5]  — accumulator bottom byte
;   $BE,$BF:  intentionally untouched — asc2fp parks its scale
;             counter in $BF across its scaling-by-10 fpMul loop
;             and the older runtime contract was that fpMul didn't
;             reach that high. fpSqrt does use $BD-$BF, but asc2fp
;             doesn't call sqrt so the two never collide.
;
; Y is used as the carry-total counter (0, 1 or 2) during the
; A + B + P_high accumulation so the case-split at the end can pick
; between the three result ranges.

fpMul:
    ; Infinity operand → NaN. Only fpDiv and fpTan generate ±∞; no
    ; other routine accepts it as input.
    LDA $B0
    ORA $B5
    AND #$20
    BNE .fm_ret_nan

    ; NaN / overflow / underflow pass-through
    LDA $B0
    AND #$0E
    BNE .fm_special_a
    LDA $B5
    AND #$0E
    BNE .fm_special_b

    ; Zero handling: 0 * x = x * 0 = 0
    LDA $B0
    AND #$10
    BNE .fm_return_zero
    LDA $B5
    AND #$10
    BNE .fm_return_zero

    ; Result sign → $B0 (overwrites op1 flags — we no longer need them)
    LDA $B0
    EOR $B5
    AND #$01
    STA $B0

    ; Result exponent = ea + eb. The +1 bump for results in [2, 4)
    ; happens later when we detect the carry from A + B + P_high.
    CLC
    LDA $B1
    ADC $B6
    STA $B1

    ; Save B's mantissa to the 6502 stack — the multiply loop scans
    ; B by shift-left, leaving it zero, but we need the original
    ; bytes again for the "+ B" term in T = A + B + P_high below.
    LDA $B7
    PHA
    LDA $B8
    PHA
    LDA $B9
    PHA

    ; Initialise the 48-bit accumulator P (big-endian, P[0] high) at
    ; $B5, $B6, $BA, $BB, $BC, $BD.
    LDA #$00
    STA $B5
    STA $B6
    STA $BA
    STA $BB
    STA $BC
    STA $BD

    ; 24-iteration shift-and-add multiply. Each pass shifts P left
    ; by 1, then shifts B left so the bit that pops out of bit 23
    ; lands in carry; if set, A is added into the lower 24 bits of
    ; P (with full 48-bit ripple-carry propagation).
    LDX #24
.fm_mul_loop:
    ASL $BD
    ROL $BC
    ROL $BB
    ROL $BA
    ROL $B6
    ROL $B5

    ASL $B9
    ROL $B8
    ROL $B7
    BCC .fm_mul_skip

    CLC
    LDA $BD
    ADC $B4
    STA $BD
    LDA $BC
    ADC $B3
    STA $BC
    LDA $BB
    ADC $B2
    STA $BB
    LDA $BA
    ADC #$00
    STA $BA
    LDA $B6
    ADC #$00
    STA $B6
    LDA $B5
    ADC #$00
    STA $B5

.fm_mul_skip:
    DEX
    BNE .fm_mul_loop

    ; Restore B's mantissa from the stack so the post-multiply add
    ; below can use it.
    PLA
    STA $B9
    PLA
    STA $B8
    PLA
    STA $B7

    ; Round-half-up the discarded low half of P. Bit 7 of $BB (the
    ; first byte we're about to drop) is the highest discarded bit;
    ; if it's set, increment P_high (P[0..2] = $B5, $B6, $BA) by 1.
    ; This costs one bit of precision over true round-to-nearest-
    ; even but is enough to cut the systematic downward bias that
    ; pure truncation would introduce.
    BIT $BB
    BPL .fm_no_round
    INC $BA
    BNE .fm_no_round
    INC $B6
    BNE .fm_no_round
    INC $B5
.fm_no_round:

    ; Compute T = A + B + P_high in $B2..$B4 (overwriting A — its
    ; previous contents are no longer needed). Y tallies the
    ; total carry-out across the two adds; it lands in {0, 1, 2}
    ; and selects the case-split below.
    LDY #$00

    CLC
    LDA $B4
    ADC $B9
    STA $B4
    LDA $B3
    ADC $B8
    STA $B3
    LDA $B2
    ADC $B7
    STA $B2
    BCC .fm_add_phigh
    INY
.fm_add_phigh:

    CLC
    LDA $B4
    ADC $BA
    STA $B4
    LDA $B3
    ADC $B6
    STA $B3
    LDA $B2
    ADC $B5
    STA $B2
    BCC .fm_classify
    INY
.fm_classify:

    ; Y = 0  →  T < 2^24, result in [1, 2). Mantissa = T_low_24,
    ;          exponent stays at ea+eb.
    ; Y = 1  →  T = 2^24 + T_low_24, result in [2, 3). Mantissa
    ;          = T_low_24 >> 1, exponent += 1.
    ; Y = 2  →  T = 2*2^24 + T_low_24, result in [3, 4). Mantissa
    ;          = $800000 | (T_low_24 >> 1), exponent += 1.
    CPY #$00
    BEQ .fm_done

    LSR $B2
    ROR $B3
    ROR $B4
    INC $B1

    CPY #$01
    BEQ .fm_done

    LDA $B2
    ORA #$80
    STA $B2

.fm_done:
    RTS

.fm_return_zero:
    LDA #$10            ; zero flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.fm_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS

.fm_special_a:
    RTS                 ; op1 is special; leave $B0-$B4 untouched

.fm_special_b:
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
