; fpCmp — compare two 5-byte floats
; Input:  $B0-$B4 = op1, $B5-$B9 = op2
; Output: A and flags encode the relationship between op1 and op2:
;           A = $00  (Z=1, N=0)   → op1 == op2
;           A = $FF  (Z=0, N=1)   → op1 <  op2
;           A = $01  (Z=0, N=0)   → op1 >  op2
;
; Caller branches directly off the flags after JSR:
;   ==  → BEQ
;   !=  → BNE
;   <   → BMI                         (N=1 only for the $FF case)
;   >=  → BPL                         (N=0 for $00 and $01)
;   >   → BEQ/BMI false-fallthrough   (two branches)
;   <=  → BEQ true ; BPL false        (two branches)
;
; NaN handling: NaN compares "equal" to everything (A=$00 returned at
; the top). This is NOT IEEE-compliant — IEEE wants every NaN
; comparison to be "unordered" (false for <,>,<=,>=, true for !=).
; For xtc we prefer a deterministic-but-sloppy answer over the added
; code path, and callers should not feed NaN through comparison
; operators anyway. Revisit if a real test case demands otherwise.
;
; Temporaries: $BA..$BD are used as scratch. The float runtime's
; reserved window is $B0..$BF, so this fits.

fpCmp:
    ; NaN short-circuit → "equal"
    LDA $B0
    ORA $B5
    AND #$08
    BNE .fc_ret_eq

    ; Zero detection for both operands.
    LDA $B0 : AND #$10 : STA $BC     ; op1 zero-flag (0 or $10)
    LDA $B5 : AND #$10 : STA $BD     ; op2 zero-flag

    LDA $BC
    BEQ .fc_op1_nonzero
    ; op1 is zero.
    LDA $BD
    BNE .fc_ret_eq                    ; both zero → equal
    ; op1 = 0, op2 ≠ 0. Sign of op2 decides the ordering.
    LDA $B5
    AND #$01
    BNE .fc_ret_gt                    ; op2 negative → 0 > op2
    JMP .fc_ret_lt                    ; op2 positive → 0 < op2
.fc_op1_nonzero:
    LDA $BD
    BEQ .fc_both_nonzero
    ; op1 ≠ 0, op2 = 0. Sign of op1 decides.
    LDA $B0
    AND #$01
    BNE .fc_ret_lt                    ; op1 negative → op1 < 0
    JMP .fc_ret_gt

.fc_both_nonzero:
    ; Compare signs first. Different signs → positive one is greater.
    LDA $B0 : AND #$01 : STA $BA      ; op1 sign
    LDA $B5 : AND #$01 : STA $BB      ; op2 sign
    LDA $BA
    CMP $BB
    BEQ .fc_same_sign
    ; op1 sign ≠ op2 sign → whichever is positive wins.
    LDA $BA
    BNE .fc_ret_lt                    ; op1 negative, op2 positive
    JMP .fc_ret_gt

.fc_same_sign:
    ; Same sign. Check for infinity on either side.
    LDA $B0 : AND #$20 : STA $BC      ; op1 inf?
    LDA $B5 : AND #$20 : STA $BD      ; op2 inf?
    LDA $BC
    BEQ .fc_op1_finite
    ; op1 is infinity.
    LDA $BD
    BNE .fc_ret_eq                    ; both inf, same sign → equal
    ; op1 inf, op2 finite → |op1| > |op2|
    JMP .fc_mag_op1_greater
.fc_op1_finite:
    LDA $BD
    BEQ .fc_cmp_exp
    ; op1 finite, op2 inf → |op1| < |op2|
    JMP .fc_mag_op1_less

.fc_cmp_exp:
    ; Compare signed exponents. Flip bit 7 to turn the signed byte
    ; into a plain unsigned comparison.
    LDA $B1 : EOR #$80 : STA $BC
    LDA $B6 : EOR #$80 : STA $BD
    LDA $BC
    CMP $BD
    BCC .fc_mag_op1_less
    BNE .fc_mag_op1_greater
    ; Exponents equal — compare mantissa bytes, MSB first. The
    ; implicit leading 1 is the same for both so a direct
    ; lexicographic compare on $B2:$B3:$B4 vs $B7:$B8:$B9 is correct.
    LDA $B2 : CMP $B7
    BCC .fc_mag_op1_less
    BNE .fc_mag_op1_greater
    LDA $B3 : CMP $B8
    BCC .fc_mag_op1_less
    BNE .fc_mag_op1_greater
    LDA $B4 : CMP $B9
    BCC .fc_mag_op1_less
    BNE .fc_mag_op1_greater
    ; All bytes equal → equal value
    JMP .fc_ret_eq

.fc_mag_op1_less:
    ; |op1| < |op2|. Flip the result if both operands are negative.
    LDA $BA
    BNE .fc_ret_gt
    JMP .fc_ret_lt

.fc_mag_op1_greater:
    ; |op1| > |op2|. Flip the result if both operands are negative.
    LDA $BA
    BNE .fc_ret_lt
    JMP .fc_ret_gt

.fc_ret_eq:
    LDA #$00
    RTS

.fc_ret_lt:
    LDA #$FF
    RTS

.fc_ret_gt:
    LDA #$01
    RTS
