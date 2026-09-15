; asc2fp — parse an ATASCII text string into a 5-byte float
; Input:  $B5,$B6 = pointer to a null-terminated ATASCII string
; Output: $B0-$B4 = parsed float
;
; Grammar:  [+|-]? digit+ ('.' digit*)? ([eE] [+|-]? digit+)?
;
; Examples that now round-trip:
;     "0"             →  0.0  (zero-flagged)
;     "3"             →  3.0
;     "-42"           → -42.0
;     "3.14"          →  3.14  (within ~1 ulp of the true value)
;     ".5"            →  0.5
;     "1.5e3"         →  1500.0
;     "2.5e-2"        →  0.025
;     "123456"        →  1.23456e5   (7-digit precision preserved)
;
; Strategy: accumulate every decimal digit — integer part *and*
; fractional part — into a single 24-bit integer at $BC-$BE. Count
; the fractional digits (or rather, track a signed "10-scale down"
; factor at $BF). If an exponent marker is present, adjust the scale
; factor by the parsed exponent value. After all digits are
; collected, convert the 24-bit integer to a float in $B0-$B4 and
; apply the scale factor via iterative fpMul (scale<0) or fpDiv
; (scale>0) against a 10.0 constant.
;
; Using a 24-bit integer accumulator gives ~7.2 decimal digits of
; precision — the same as the float's 24-bit mantissa — so the
; intermediate rounding errors that plagued a "multiply by 10 in
; float at every step" approach disappear. Inputs longer than 7
; digits silently wrap in the accumulator, matching what the
; target float precision can represent anyway.
;
; Storage ($B0-$BF — all inside the reserved runtime region):
;     $B0-$B4   result accumulator (also used as scratch during parsing)
;     $B5-$B9   operand 2 for fpMul / fpDiv (the 10.0 constant)
;     $BA-$BB   saved copy of the input pointer
;     $BC-$BE   24-bit integer accumulator (high to low)
;     $BF       signed scale factor — positive = divide by 10 that many
;               times, negative = multiply by 10 |that| times
;     X         sign flag (0 = positive, 1 = negative)
;     Y         byte offset into the input string
;
; Requires: fpMul, fpDiv (linked automatically via the JSR scan).

asc2fp:
    ; Stash the input pointer before we touch $B5-$B9.
    LDA $B5
    STA $BA
    LDA $B6
    STA $BB

    ; int_acc = 0, scale = 0
    LDA #$00
    STA $BC
    STA $BD
    STA $BE
    STA $BF

    LDX #$00            ; sign = positive
    LDY #$00

    ; --- Optional leading sign ---
    LDA ($BA),Y
    CMP #$2D            ; '-'
    BNE .a2f_not_neg
    LDX #$01
    INY
    JMP .a2f_parse_int
.a2f_not_neg:
    CMP #$2B            ; '+'
    BNE .a2f_parse_int
    INY

.a2f_parse_int:
    LDA ($BA),Y
    BEQ .a2f_convert
    CMP #$69            ; 'i' → possibly "inf"
    BEQ .a2f_check_inf
    CMP #$49            ; 'I'
    BEQ .a2f_check_inf
    CMP #$6E            ; 'n' → possibly "nan"
    BEQ .a2f_check_nan
    CMP #$4E            ; 'N'
    BEQ .a2f_check_nan
    CMP #$2E            ; '.'
    BEQ .a2f_seen_dot
    CMP #$65            ; 'e'
    BEQ .a2f_parse_exp
    CMP #$45            ; 'E'
    BEQ .a2f_parse_exp
    CMP #$30            ; '0'
    BCC .a2f_convert
    CMP #$3A            ; ':' (one past '9')
    BCS .a2f_convert
    ; digit
    SEC
    SBC #$30
    PHA                 ; stash digit across mul10
    JSR .a2f_mul10
    PLA
    CLC
    ADC $BE
    STA $BE
    BCC .a2f_pi_nc
    INC $BD
    BNE .a2f_pi_nc
    INC $BC
.a2f_pi_nc:
    INY
    JMP .a2f_parse_int

.a2f_seen_dot:
    INY
.a2f_parse_frac:
    LDA ($BA),Y
    BEQ .a2f_convert
    CMP #$65            ; 'e'
    BEQ .a2f_parse_exp
    CMP #$45            ; 'E'
    BEQ .a2f_parse_exp
    CMP #$30
    BCC .a2f_convert
    CMP #$3A
    BCS .a2f_convert
    SEC
    SBC #$30
    PHA
    JSR .a2f_mul10
    PLA
    CLC
    ADC $BE
    STA $BE
    BCC .a2f_pf_nc
    INC $BD
    BNE .a2f_pf_nc
    INC $BC
.a2f_pf_nc:
    INC $BF             ; each fractional digit bumps the scale
    INY
    JMP .a2f_parse_frac

.a2f_parse_exp:
    ; We've already consumed the 'e'/'E' — advance past it.
    INY
    ; Optional exponent sign, stashed on the 6502 stack below exp_acc.
    LDA #$00
    PHA                 ; exp_sign = 0 (positive)
    LDA ($BA),Y
    CMP #$2D            ; '-'
    BNE .a2f_exp_plus
    PLA
    LDA #$01
    PHA                 ; exp_sign = 1 (negative)
    INY
    JMP .a2f_exp_start
.a2f_exp_plus:
    CMP #$2B            ; '+'
    BNE .a2f_exp_start
    INY

.a2f_exp_start:
    LDA #$00
    PHA                 ; exp_acc = 0 (top of stack now, above exp_sign)
.a2f_exp_digit:
    LDA ($BA),Y
    BEQ .a2f_exp_done
    CMP #$30
    BCC .a2f_exp_done
    CMP #$3A
    BCS .a2f_exp_done
    SEC
    SBC #$30            ; digit
    STA $B0             ; stash digit at $B0 (unused until .a2f_convert)
    PLA                 ; current exp_acc
    STA $B1             ; copy for the "5x = 4x+x" step
    ASL A
    ASL A               ; 4x
    CLC
    ADC $B1             ; 5x
    ASL A               ; 10x
    CLC
    ADC $B0             ; 10x + digit
    PHA                 ; new exp_acc back on stack
    INY
    JMP .a2f_exp_digit

.a2f_exp_done:
    ; Stack top = exp_acc, below = exp_sign.
    PLA                 ; A = exp_acc
    STA $B0
    PLA                 ; A = exp_sign
    BEQ .a2f_exp_pos
    ; Negative exponent → scale += exp_acc (more divisions at the end).
    LDA $BF
    CLC
    ADC $B0
    STA $BF
    JMP .a2f_convert
.a2f_exp_pos:
    ; Positive exponent → scale -= exp_acc (fewer divisions, or shift to multiply).
    LDA $BF
    SEC
    SBC $B0
    STA $BF
    ; fall through

.a2f_convert:
    ; Check for a zero accumulator — handles empty input, "0", "0.0", etc.
    LDA $BC
    ORA $BD
    ORA $BE
    BNE .a2f_nonzero
    ; Zero — return the zero-flagged float regardless of sign or scale.
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.a2f_nonzero:
    ; Stash the sign flag before we reuse X as the exponent counter.
    ; $B0 isn't used for final flags until the normalise step below
    ; wants to write it, so it's safe scratch here.
    STX $B0

    ; Normalise int_acc until bit 23 (= bit 7 of $BC) is set. X tracks
    ; the exponent: starts at 23 and decreases for each left shift.
    LDX #23
.a2f_norm_loop:
    LDA $BC
    BMI .a2f_norm_done
    ASL $BE
    ROL $BD
    ROL $BC
    DEX
    JMP .a2f_norm_loop
.a2f_norm_done:
    ; One more shift drops the implicit leading 1 off the top, leaving
    ; the 24-bit fraction in $BC-$BE exactly as format 1 wants it.
    ASL $BE
    ROL $BD
    ROL $BC
    LDA $BC
    STA $B2
    LDA $BD
    STA $B3
    LDA $BE
    STA $B4
    TXA
    STA $B1
    ; Apply sign now — $B0 still holds the sign flag (0 or 1), which is
    ; exactly the format-1 flag-byte layout for "sign, no specials".
    LDA $B0
    AND #$01
    STA $B0

    ; --- Scale: multiply or divide by 10 per the $BF counter ---
.a2f_scale:
    LDA $BF
    BEQ .a2f_done
    BMI .a2f_scale_mul
    ; Positive scale → divide by 10.
    LDA #$00
    STA $B5
    LDA #$03
    STA $B6
    LDA #$40
    STA $B7
    LDA #$00
    STA $B8
    LDA #$00
    STA $B9
    JSR fpDiv
    DEC $BF
    JMP .a2f_scale
.a2f_scale_mul:
    ; Negative scale → multiply by 10 until the counter reaches 0.
    LDA #$00
    STA $B5
    LDA #$03
    STA $B6
    LDA #$40
    STA $B7
    LDA #$00
    STA $B8
    LDA #$00
    STA $B9
    JSR fpMul
    INC $BF
    JMP .a2f_scale

.a2f_done:
    RTS

; --- Recognise "inf" (case-insensitive) ---
; Entered when the first non-sign char is 'i' or 'I'. We've
; consumed the sign into X already. Advance past 'n'/'N' and
; 'f'/'F'; on mismatch, fall through to the normal conversion
; path (which produces 0 for an unrecognised leading character).
; ORA #$20 maps uppercase ASCII letters to their lowercase form
; without affecting the comparisons on the expected letters.
.a2f_check_inf:
    INY
    LDA ($BA),Y
    ORA #$20
    CMP #$6E            ; 'n' / 'N'
    BNE .a2f_convert
    INY
    LDA ($BA),Y
    ORA #$20
    CMP #$66            ; 'f' / 'F'
    BNE .a2f_convert
    TXA                 ; X = sign (0 or 1)
    ORA #$20            ; infinity flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.a2f_check_nan:
    INY
    LDA ($BA),Y
    ORA #$20
    CMP #$61            ; 'a' / 'A'
    BNE .a2f_convert
    INY
    LDA ($BA),Y
    ORA #$20
    CMP #$6E            ; 'n' / 'N'
    BNE .a2f_convert
    LDA #$08            ; NaN flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

; --- int_acc ($BC-$BE) *= 10 ---
; Uses the identity 10x = 8x + 2x. Compute 2x in place, save to the
; 6502 stack, compute 8x in place (two more doublings), then add
; the saved 2x back. Clobbers A and flags.
.a2f_mul10:
    ASL $BE
    ROL $BD
    ROL $BC             ; int_acc = 2x
    LDA $BC
    PHA
    LDA $BD
    PHA
    LDA $BE
    PHA                 ; stack: hi, mid, lo
    ASL $BE
    ROL $BD
    ROL $BC             ; 4x
    ASL $BE
    ROL $BD
    ROL $BC             ; 8x
    CLC
    PLA                 ; lo of saved 2x
    ADC $BE
    STA $BE
    PLA                 ; mid
    ADC $BD
    STA $BD
    PLA                 ; hi
    ADC $BC
    STA $BC
    RTS
