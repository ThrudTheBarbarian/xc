; fpMod — float modulus (remainder after integer division)
; Input:  $B0-$B4 = operand1 (dividend), $B5-$B9 = operand2 (divisor)
; Output: $B0-$B4 = operand1 - trunc(operand1 / operand2) * operand2
;
; Method: r = a - trunc(a/b) * b
;
;   1. Save op1 and op2 on the hw stack.
;   2. r = fpDiv(op1, op2).
;   3. Truncate r to its integer part in place.
;   4. Restore op2 into $B5-$B9 and compute r = fpMul(r, op2).
;   5. Move r into $B5-$B9 as "op2".
;   6. Restore op1 into $B0-$B4 and compute fpSub(op1, r).
;
; The old routine "truncated" the quotient by simply zeroing bytes 3
; and 4 of its mantissa — a bit-pattern hack that almost never did
; what it claimed (for example `5 mod 2` came out as 0 because the
; 2.5 quotient {$00,$01,$40,$00,$00} was unchanged by the zeroing).
; The new truncate uses the mantissa's exponent to decide how many
; low fractional bits to clear, implemented by shifting the mantissa
; right by (24 - exp) bits and then left by the same amount.

fpMod:
    ; Save operand1
    LDA $B0 : PHA
    LDA $B1 : PHA
    LDA $B2 : PHA
    LDA $B3 : PHA
    LDA $B4 : PHA
    ; Save operand2
    LDA $B5 : PHA
    LDA $B6 : PHA
    LDA $B7 : PHA
    LDA $B8 : PHA
    LDA $B9 : PHA

    JSR fpDiv           ; $B0-$B4 = a/b

    ; --- Truncate $B0-$B4 to its integer part ---
    ; If the division result is already zero, flagged as NaN/overflow,
    ; or has a fractional-only magnitude (exp < 0), short-circuit.
    LDA $B0
    AND #$1E            ; zero / uflow / oflow / NaN
    BNE .fm_trunc_done
    LDA $B1             ; exponent
    BMI .fm_trunc_zero  ; exp < 0 → |q| < 1 → truncate to 0
    CMP #24
    BCS .fm_trunc_done  ; exp ≥ 24 → mantissa is already all integer

    ; shift_count = 24 - exp
    SEC
    LDA #24
    SBC $B1
    TAX                 ; X = number of low bits to clear

    ; Shift mantissa right X times, dropping the low bits.
.fm_trunc_r:
    LSR $B2
    ROR $B3
    ROR $B4
    DEX
    BNE .fm_trunc_r

    ; Re-shift left by the same count (X fell to 0, so recompute).
    SEC
    LDA #24
    SBC $B1
    TAX
.fm_trunc_l:
    ASL $B4
    ROL $B3
    ROL $B2
    DEX
    BNE .fm_trunc_l
    JMP .fm_trunc_done

.fm_trunc_zero:
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4

.fm_trunc_done:
    ; Restore operand2 into $B5-$B9 (popped in reverse push order).
    PLA : STA $B9
    PLA : STA $B8
    PLA : STA $B7
    PLA : STA $B6
    PLA : STA $B5

    JSR fpMul           ; $B0-$B4 = trunc(a/b) * b

    ; Move result into $B5-$B9 as the new operand2 for the final subtract.
    LDA $B0 : STA $B5
    LDA $B1 : STA $B6
    LDA $B2 : STA $B7
    LDA $B3 : STA $B8
    LDA $B4 : STA $B9

    ; Restore operand1 into $B0-$B4.
    PLA : STA $B4
    PLA : STA $B3
    PLA : STA $B2
    PLA : STA $B1
    PLA : STA $B0

    JSR fpSub           ; r = a - trunc(a/b)*b
    RTS
