; dpCmp — compare two 8-byte doubles.
; Input:  $B0-$B7 = op1, $B8-$BF = op2
; Output: A and flags encode the relationship between op1 and op2:
;           A = $00  (Z=1, N=0)   → op1 == op2
;           A = $FF  (Z=0, N=1)   → op1 <  op2
;           A = $01  (Z=0, N=0)   → op1 >  op2
;
; Caller branches directly off the flags after JSR (same shape as
; fpCmp):
;   ==  → BEQ
;   !=  → BNE
;   <   → BMI
;   >=  → BPL
;   >   → BEQ false ; BMI false   (two-branch sequence)
;   <=  → BEQ true  ; BPL false   (two-branch sequence)
;
; NaN handling: NaN compares "equal" to everything (matches fpCmp's
; non-IEEE behaviour). Revisit only if a real test case demands it.
;
; Storage: operands occupy $B0-$BF in full, so scratch lives in the
; data section below, accessed via absolute addressing (same pattern
; as dpMul / dpDiv / dp2Asc).

dpCmp:
    ; NaN short-circuit → "equal".
    LDA $B0
    ORA $B8
    AND #$08
    BNE dpCmp_ret_eq

    ; Zero-flag extract for both operands.
    LDA $B0 : AND #$10 : STA _dpCmp_z1
    LDA $B8 : AND #$10 : STA _dpCmp_z2

    LDA _dpCmp_z1
    BEQ dpCmp_op1_nonzero
    ; op1 is zero.
    LDA _dpCmp_z2
    BNE dpCmp_ret_eq                 ; both zero → equal
    ; op1 = 0, op2 ≠ 0. Sign of op2 decides: op2 negative → 0 > op2.
    LDA $B8
    AND #$01
    BNE dpCmp_ret_gt
    JMP dpCmp_ret_lt

dpCmp_op1_nonzero:
    LDA _dpCmp_z2
    BEQ dpCmp_both_nonzero
    ; op1 ≠ 0, op2 = 0. Sign of op1 decides.
    LDA $B0
    AND #$01
    BNE dpCmp_ret_lt                 ; op1 negative → op1 < 0
    JMP dpCmp_ret_gt

dpCmp_both_nonzero:
    ; Compare signs first. Different signs → positive one wins.
    LDA $B0 : AND #$01 : STA _dpCmp_s1
    LDA $B8 : AND #$01 : STA _dpCmp_s2
    LDA _dpCmp_s1
    CMP _dpCmp_s2
    BEQ dpCmp_same_sign
    LDA _dpCmp_s1
    BNE dpCmp_ret_lt                 ; op1 negative, op2 positive
    JMP dpCmp_ret_gt

dpCmp_same_sign:
    ; Same sign. Check for infinity on either side.
    LDA $B0 : AND #$20 : STA _dpCmp_i1
    LDA $B8 : AND #$20 : STA _dpCmp_i2
    LDA _dpCmp_i1
    BEQ dpCmp_op1_finite
    ; op1 is infinity.
    LDA _dpCmp_i2
    BNE dpCmp_ret_eq                 ; both inf, same sign → equal
    JMP dpCmp_mag_op1_greater        ; op1 inf, op2 finite → |op1|>|op2|
dpCmp_op1_finite:
    LDA _dpCmp_i2
    BEQ dpCmp_cmp_exp
    JMP dpCmp_mag_op1_less           ; op1 finite, op2 inf → |op1|<|op2|

dpCmp_cmp_exp:
    ; Signed-exponent compare via the usual EOR #$80 bias trick.
    LDA $B1 : EOR #$80 : STA _dpCmp_e1
    LDA $B9 : EOR #$80 : STA _dpCmp_e2
    LDA _dpCmp_e1
    CMP _dpCmp_e2
    BCC dpCmp_mag_op1_less
    BNE dpCmp_mag_op1_greater

    ; Exponents equal — lex-compare mantissa bytes MSB-first. The
    ; implicit leading 1 is the same for both, so direct byte-wise
    ; compare on $B2..$B7 vs $BA..$BF is correct.
    LDA $B2 : CMP $BA
    BCC dpCmp_mag_op1_less
    BNE dpCmp_mag_op1_greater
    LDA $B3 : CMP $BB
    BCC dpCmp_mag_op1_less
    BNE dpCmp_mag_op1_greater
    LDA $B4 : CMP $BC
    BCC dpCmp_mag_op1_less
    BNE dpCmp_mag_op1_greater
    LDA $B5 : CMP $BD
    BCC dpCmp_mag_op1_less
    BNE dpCmp_mag_op1_greater
    LDA $B6 : CMP $BE
    BCC dpCmp_mag_op1_less
    BNE dpCmp_mag_op1_greater
    LDA $B7 : CMP $BF
    BCC dpCmp_mag_op1_less
    BNE dpCmp_mag_op1_greater
    JMP dpCmp_ret_eq                 ; all bytes equal

dpCmp_mag_op1_less:
    ; |op1| < |op2|. Flip if both negative.
    LDA _dpCmp_s1
    BNE dpCmp_ret_gt
    JMP dpCmp_ret_lt

dpCmp_mag_op1_greater:
    ; |op1| > |op2|. Flip if both negative.
    LDA _dpCmp_s1
    BNE dpCmp_ret_lt
    JMP dpCmp_ret_gt

dpCmp_ret_eq:
    LDA #$00
    RTS

dpCmp_ret_lt:
    LDA #$FF
    RTS

dpCmp_ret_gt:
    LDA #$01
    RTS


_dpCmp_z1: .byte $00
_dpCmp_z2: .byte $00
_dpCmp_s1: .byte $00
_dpCmp_s2: .byte $00
_dpCmp_i1: .byte $00
_dpCmp_i2: .byte $00
_dpCmp_e1: .byte $00
_dpCmp_e2: .byte $00
