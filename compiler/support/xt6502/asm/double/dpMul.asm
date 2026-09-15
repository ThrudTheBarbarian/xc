; dpMul — multiply two 8-byte doubles
; Input:  $B0-$B7 = op1, $B8-$BF = op2
; Output: $B0-$B7 = op1 * op2
;
; Double format: byte 0 flags (bit 0=sign, 1=uflow, 2=oflow, 3=NaN,
; 4=zero, 5=inf), byte 1 signed base-2 exponent, bytes 2-7 48-bit
; big-endian mantissa with the implicit leading 1 unstored
; (value = 1.mantissa * 2^exp). Zero is flagged by bit 4 of byte 0.
;
; Method
; ──────
; Same (1+a)(1+b) decomposition as fpMul, just with 48-bit mantissas:
;
;   value(op1) = (1 + A/2^48) * 2^ea   where A = op1 mantissa (6 bytes)
;   value(op2) = (1 + B/2^48) * 2^eb   where B = op2 mantissa (6 bytes)
;   product    = (1 + A/2^48 + B/2^48 + A*B/2^96) * 2^(ea+eb)
;
; Let T = A + B + ⌊A*B / 2^48⌋ (top 48 bits of the 96-bit product).
; Y tallies the total carry-out of the two 6-byte adds (0, 1 or 2)
; and selects the post-multiply case:
;
;   Y = 0  →  T < 2^48, result in [1, 2). Mantissa = T_low_48,
;             exponent stays at ea+eb.
;   Y = 1  →  T = 2^48 + T_low_48, result in [2, 3). Mantissa
;             = T_low_48 >> 1, exponent += 1.
;   Y = 2  →  T = 2*2^48 + T_low_48, result in [3, 4). Mantissa
;             = $800000000000 | (T_low_48 >> 1), exponent += 1.
;
; This is a 1:1 mirror of fpMul.asm — the algorithm is identical in
; structure; only the mantissa width (3 → 6 bytes) and loop count
; (24 → 48) change. Any bug fix or correctness audit applied to one
; file MUST be carried over to the other; keep the two files in
; sync. xta doesn't support assembler-level IF conditionals so a
; true shared source template isn't expressible here.
;
; Storage layout
; ──────────────
; ZP runtime window ($B0-$BF):
;   $B0:      result flags / sign byte (final output)
;   $B1:      result exponent (final output)
;   $B2-$B7:  A mantissa (preserved across the multiply, then reused
;             to hold T = A + B + P_high)
;   $B8-$B9:  op2 flags/exp (consumed early; then free — kept as
;             scratch but the routine doesn't currently need them
;             after phase 2)
;   $BA-$BF:  B mantissa at entry; scan destructively shifts it
;             left, leaving all zero. Original B is copied to
;             _dpmul_B (data-section) before the scan so T's
;             "+ B" term has the unshifted bits.
;
; Data-section scratch (declared at end of file):
;   _dpmul_P:  12 bytes — the 96-bit accumulator, big-endian
;              (P[0] = _dpmul_P = top byte, P[11] = bottom byte).
;              Holds the full product; P[0..5] is P_high which
;              participates in T, P[6..11] is discarded except
;              for bit 7 of P[6] which drives the round-half-up.
;   _dpmul_B:  6 bytes — preserved copy of the original op2
;              mantissa for the post-multiply add.
;
; The $B0-$BF window is exhausted by the two 8-byte operands, so
; there's no room for the 12-byte P accumulator. Data-section
; absolute addressing costs an extra cycle per byte op vs ZP, but
; the alternative (bumping the runtime ZP window to $B0-$CF) eats
; 16 bytes of user-var space compiler-wide; see doc/double.md
; §"ZP pressure" for the design rationale.

dpMul:
    ; Infinity operand → NaN. Only dpDiv / dpTan would generate ±∞;
    ; no other routine accepts it as input.
    LDA $B0
    ORA $B8
    AND #$20
    BNE .dm_ret_nan

    ; NaN / overflow / underflow pass-through
    LDA $B0
    AND #$0E
    BNE .dm_special_a
    LDA $B8
    AND #$0E
    BNE .dm_special_b

    ; Zero handling: 0 * x = x * 0 = 0
    LDA $B0
    AND #$10
    BNE .dm_return_zero
    LDA $B8
    AND #$10
    BNE .dm_return_zero

    ; Result sign → $B0 (overwrites op1 flags — we no longer need them)
    LDA $B0
    EOR $B8
    AND #$01
    STA $B0

    ; Result exponent = ea + eb. The +1 bump for results in [2, 4)
    ; happens later when we detect the carry from A + B + P_high.
    CLC
    LDA $B1
    ADC $B9
    STA $B1

    ; Save B's mantissa to data-section scratch — the multiply loop
    ; scans B by shift-left, leaving it zero, but we need the
    ; original bytes again for the "+ B" term in T = A + B + P_high
    ; below.
    LDA $BA
    STA _dpmul_B
    LDA $BB
    STA _dpmul_B+1
    LDA $BC
    STA _dpmul_B+2
    LDA $BD
    STA _dpmul_B+3
    LDA $BE
    STA _dpmul_B+4
    LDA $BF
    STA _dpmul_B+5

    ; Initialise the 96-bit accumulator P at _dpmul_P..+11 to zero.
    LDA #$00
    STA _dpmul_P
    STA _dpmul_P+1
    STA _dpmul_P+2
    STA _dpmul_P+3
    STA _dpmul_P+4
    STA _dpmul_P+5
    STA _dpmul_P+6
    STA _dpmul_P+7
    STA _dpmul_P+8
    STA _dpmul_P+9
    STA _dpmul_P+10
    STA _dpmul_P+11

    ; 48-iteration shift-and-add multiply. Each pass shifts P left
    ; by 1, then shifts B left so the bit that pops out of bit 47
    ; lands in carry; if set, A is added into the lower 6 bytes of
    ; P (with full 96-bit ripple-carry propagation).
    LDX #48
.dm_mul_loop:
    ; Shift P left by 1 (12 bytes, bottom-up so each ROL picks up
    ; the carry from the byte below).
    ASL _dpmul_P+11
    ROL _dpmul_P+10
    ROL _dpmul_P+9
    ROL _dpmul_P+8
    ROL _dpmul_P+7
    ROL _dpmul_P+6
    ROL _dpmul_P+5
    ROL _dpmul_P+4
    ROL _dpmul_P+3
    ROL _dpmul_P+2
    ROL _dpmul_P+1
    ROL _dpmul_P

    ; Shift B ($BA-$BF) left by 1; the bit that pops out of the
    ; top byte $BA lands in carry.
    ASL $BF
    ROL $BE
    ROL $BD
    ROL $BC
    ROL $BB
    ROL $BA
    BCC .dm_mul_skip

    ; Add A ($B2-$B7) into P's low 6 bytes (_dpmul_P+6..+11),
    ; then ripple carry through the high 6 bytes (_dpmul_P..+5).
    CLC
    LDA _dpmul_P+11
    ADC $B7
    STA _dpmul_P+11
    LDA _dpmul_P+10
    ADC $B6
    STA _dpmul_P+10
    LDA _dpmul_P+9
    ADC $B5
    STA _dpmul_P+9
    LDA _dpmul_P+8
    ADC $B4
    STA _dpmul_P+8
    LDA _dpmul_P+7
    ADC $B3
    STA _dpmul_P+7
    LDA _dpmul_P+6
    ADC $B2
    STA _dpmul_P+6
    LDA _dpmul_P+5
    ADC #$00
    STA _dpmul_P+5
    LDA _dpmul_P+4
    ADC #$00
    STA _dpmul_P+4
    LDA _dpmul_P+3
    ADC #$00
    STA _dpmul_P+3
    LDA _dpmul_P+2
    ADC #$00
    STA _dpmul_P+2
    LDA _dpmul_P+1
    ADC #$00
    STA _dpmul_P+1
    LDA _dpmul_P
    ADC #$00
    STA _dpmul_P

.dm_mul_skip:
    DEX
    BNE .dm_mul_loop

    ; Round-half-up the discarded low half of P. Bit 7 of
    ; _dpmul_P+6 (the first byte we're about to drop) is the
    ; highest discarded bit; if it's set, increment P_high
    ; (_dpmul_P..+5) by 1. Mirror of fpMul.asm's .fm_no_round
    ; block but across 6 bytes instead of 3.
    BIT _dpmul_P+6
    BPL .dm_no_round
    INC _dpmul_P+5
    BNE .dm_no_round
    INC _dpmul_P+4
    BNE .dm_no_round
    INC _dpmul_P+3
    BNE .dm_no_round
    INC _dpmul_P+2
    BNE .dm_no_round
    INC _dpmul_P+1
    BNE .dm_no_round
    INC _dpmul_P
.dm_no_round:

    ; Compute T = A + B + P_high in $B2..$B7 (overwriting A — its
    ; previous contents are no longer needed). Y tallies the total
    ; carry-out across the two 6-byte adds; it lands in {0, 1, 2}
    ; and selects the case-split below.
    LDY #$00

    ; T = A + B_original (from _dpmul_B)
    CLC
    LDA $B7
    ADC _dpmul_B+5
    STA $B7
    LDA $B6
    ADC _dpmul_B+4
    STA $B6
    LDA $B5
    ADC _dpmul_B+3
    STA $B5
    LDA $B4
    ADC _dpmul_B+2
    STA $B4
    LDA $B3
    ADC _dpmul_B+1
    STA $B3
    LDA $B2
    ADC _dpmul_B
    STA $B2
    BCC .dm_add_phigh
    INY
.dm_add_phigh:

    ; T += P_high (top 6 bytes of the product accumulator)
    CLC
    LDA $B7
    ADC _dpmul_P+5
    STA $B7
    LDA $B6
    ADC _dpmul_P+4
    STA $B6
    LDA $B5
    ADC _dpmul_P+3
    STA $B5
    LDA $B4
    ADC _dpmul_P+2
    STA $B4
    LDA $B3
    ADC _dpmul_P+1
    STA $B3
    LDA $B2
    ADC _dpmul_P
    STA $B2
    BCC .dm_classify
    INY
.dm_classify:

    ; Y = 0 → T < 2^48, result in [1, 2). Mantissa = T_low_48,
    ;         exponent stays at ea+eb.
    ; Y = 1 → T = 2^48 + T_low_48, result in [2, 3). Mantissa
    ;         = T_low_48 >> 1, exponent += 1.
    ; Y = 2 → T = 2*2^48 + T_low_48, result in [3, 4). Mantissa
    ;         = $800000000000 | (T_low_48 >> 1), exponent += 1.
    CPY #$00
    BEQ .dm_done

    LSR $B2
    ROR $B3
    ROR $B4
    ROR $B5
    ROR $B6
    ROR $B7
    INC $B1

    CPY #$01
    BEQ .dm_done

    LDA $B2
    ORA #$80
    STA $B2

.dm_done:
    RTS

.dm_return_zero:
    LDA #$10            ; zero flag
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

.dm_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    STA $B5 : STA $B6 : STA $B7
    RTS

.dm_special_a:
    RTS                 ; op1 is special; leave $B0-$B7 untouched

.dm_special_b:
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

; Data-section scratch — kept at the tail of the routine so it sits
; next to the code that uses it and stays out of the ZP runtime
; window. Absolute addressing costs +1 cycle per byte op vs ZP, but
; the $B0-$BF runtime window is already exhausted by the two 8-byte
; operands.
_dpmul_P:
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
_dpmul_B:
    .byte $00,$00,$00,$00,$00,$00
