; fpTrig.asm — CORDIC-based trig functions for standard mode
; Implements: fpSin, fpCos, fpTan, fpAtan
;
; All functions use 5-byte float format:
;   Input:  $B0-$B4 = angle in radians (float)
;   Output: $B0-$B4 = result (float)
;
; Internal CORDIC uses signed 16-bit Q3.13 fixed-point.
; 14 iterations → ~14 bits of accuracy (matches 16-bit precision).
;
; Workspace: $B0-$B9 (overlaps input — input is consumed)

; ── Constants ─────────────────────────────────────────────────────────
; 1/K (CORDIC gain) in Q1.15 = 0.60725 * 32768 = 19898
_cordic_invK_lo = $BA
_cordic_invK_hi = $4D

; π/2 in Q3.13 = 1.5708 * 8192 = 12868
_cordic_halfpi_lo = $44
_cordic_halfpi_hi = $32

; π in Q3.13 = 3.14159 * 8192 = 25736
_cordic_pi_lo = $88
_cordic_pi_hi = $64

; ── fpSin ─────────────────────────────────────────────────────────────
fpSin:
    ; Infinity input → NaN (sin of ±∞ is undefined).
    LDA $B0
    AND #$20
    BNE .fs_ret_nan
    ; Exactly-zero input short-circuit. The rotation-mode CORDIC starts
    ; with a spurious +atan(1) rotation that never fully zigzags back
    ; to 0, so bypassing the pipeline here is both faster and correct.
    LDA $B0
    AND #$10
    BEQ .fs_nonzero
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.fs_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.fs_nonzero:
    ; If |angle| ≥ 4 (exp ≥ 2), fold into (-π, π] in float
    ; arithmetic before the Q3.13 conversion — Q3.13 only
    ; represents [-4, 4) and would otherwise truncate.
    LDA $B1
    SEC
    SBC #$02
    BMI .fs_in_range
    JSR _fp_reduce_to_pi
.fs_in_range:
    JSR _cordic_float_to_q313  ; convert $B0-$B4 float → $B4,$B5 Q3.13 angle
    JSR _cordic_range_reduce   ; reduce to [-π/2,π/2], flags in $B7
    JSR _cordic_compute        ; CORDIC iteration
    ; sin result is in $B2,$B3 (y register)
    LDA $B2
    STA $B8
    LDA $B3
    STA $B9
    ; Apply sign from range reduction
    LDA $B7
    AND #$01
    BEQ .sin_pos
    ; Negate the result
    SEC
    LDA #$00
    SBC $B8
    STA $B8
    LDA #$00
    SBC $B9
    STA $B9
.sin_pos:
    ; Convert Q1.15 in $B8,$B9 to float in $B0-$B4
    LDA $B8
    STA $B4
    LDA $B9
    STA $B5
    JMP _cordic_q115_to_float

; ── fpCos ─────────────────────────────────────────────────────────────
fpCos:
    ; Infinity input → NaN.
    LDA $B0
    AND #$20
    BNE .fc_ret_nan
    ; Exactly-zero input short-circuit → cos(0) = 1.0, which in the
    ; implicit-leading-1 format is {0,0,0,0,0}.
    LDA $B0
    AND #$10
    BEQ .fc_nonzero
    LDA #$00
    STA $B0 : STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.fc_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.fc_nonzero:
    ; See the matching reduce-before-Q3.13 block in fpSin above.
    LDA $B1
    SEC
    SBC #$02
    BMI .fc_in_range
    JSR _fp_reduce_to_pi
.fc_in_range:
    JSR _cordic_float_to_q313
    JSR _cordic_range_reduce
    JSR _cordic_compute
    ; cos result is in $B0,$B1 (x register)
    LDA $B0
    STA $B8
    LDA $B1
    STA $B9
    ; Apply cos sign from range reduction (bit 1 of $B7)
    LDA $B7
    AND #$02
    BEQ .cos_pos
    SEC
    LDA #$00
    SBC $B8
    STA $B8
    LDA #$00
    SBC $B9
    STA $B9
.cos_pos:
    LDA $B8
    STA $B4
    LDA $B9
    STA $B5
    JMP _cordic_q115_to_float

; ── fpTan ─────────────────────────────────────────────────────────────
; tan(x) = sin(x) / cos(x), computed from a SINGLE CORDIC rotation
; pass instead of two. The previous version called fpSin and fpCos
; independently, which (a) ran CORDIC twice and (b) round-tripped sin
; and cos through the Q1.15→float pack before dividing — losing a
; bit or so of precision on each side. This version runs one CORDIC,
; applies range-reduction sign flags directly to the Q1.15 x and y,
; converts each to float once, and divides.
;
; cos → 0 near ±π/2 still blows up through fpDiv (inevitable for
; tan), but everywhere else the result is visibly tighter than the
; two-pass version.
fpTan:
    ; Infinity input → NaN.
    LDA $B0
    AND #$20
    BNE .ft_ret_nan
    ; Exactly-zero input short-circuit: tan(0) = 0.
    LDA $B0
    AND #$10
    BEQ .ft_nonzero
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.ft_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.ft_nonzero:
    ; See the matching reduce-before-Q3.13 block in fpSin above.
    LDA $B1
    SEC
    SBC #$02
    BMI .ft_in_range
    JSR _fp_reduce_to_pi
.ft_in_range:
    JSR _cordic_float_to_q313
    JSR _cordic_range_reduce
    ; ── Pole detection ──────────────────────────────────────────
    ; After mod-π range reduction the reduced angle lives at
    ; $B4:$B5 in signed Q3.13. If |reduced| is within ε of π/2
    ; we short-circuit to ±∞ instead of running CORDIC + fpDiv
    ; (which would just blow precision on a near-zero cos). The
    ; sign of the infinity is sign(reduced) XOR the parity of
    ; the sin/cos flip flags stored in $B7.
    LDA $B5
    BPL .ft_abs_pos
    SEC
    LDA #$00 : SBC $B4 : STA $BA
    LDA #$00 : SBC $B5 : STA $BB
    JMP .ft_abs_done
.ft_abs_pos:
    LDA $B4 : STA $BA
    LDA $B5 : STA $BB
.ft_abs_done:
    ; delta = π/2 − |reduced|
    SEC
    LDA #_cordic_halfpi_lo
    SBC $BA
    STA $BA
    LDA #_cordic_halfpi_hi
    SBC $BB
    STA $BB
    BMI .ft_no_pole             ; |reduced| > π/2 — treat as finite
    LDA $BB
    BNE .ft_no_pole             ; delta hi ≠ 0 → outside ε window
    LDA $BA
    CMP #$20                    ; ε = 32 Q3.13 units ≈ 0.004 rad
    BCS .ft_no_pole
    ; Pole detected. raw_sign = (reduced < 0 ? 1 : 0)
    LDA $B5
    ASL A                       ; sign bit → carry
    LDA #$00
    ROL A                       ; A bit 0 = raw_sign
    STA $BA
    ; Range-reduction flip parity = sin_flip XOR cos_flip
    LDA $B7
    AND #$01
    STA $BB                     ; sin_flip
    LDA $B7
    LSR A                       ; cos_flip into bit 0
    AND #$01
    EOR $BB                     ; sin_flip XOR cos_flip
    EOR $BA                     ; XOR raw_sign
    AND #$01
    ORA #$20                    ; infinity flag
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.ft_no_pole:
    JSR _cordic_compute
    ; $B0:$B1 = cos (Q1.15), $B2:$B3 = sin (Q1.15), $B7 = sign flags.

    ; Apply sin sign (bit 0 of $B7) to y in place.
    LDA $B7
    AND #$01
    BEQ .ft_sin_pos
    SEC
    LDA #$00 : SBC $B2 : STA $B2
    LDA #$00 : SBC $B3 : STA $B3
.ft_sin_pos:
    ; Apply cos sign (bit 1 of $B7) to x in place.
    LDA $B7
    AND #$02
    BEQ .ft_cos_pos
    SEC
    LDA #$00 : SBC $B0 : STA $B0
    LDA #$00 : SBC $B1 : STA $B1
.ft_cos_pos:
    ; Stash x (cos_q115) in $BA,$BB so we can convert sin first
    ; without losing it — q115_to_float clobbers $B0-$B5.
    LDA $B0 : STA $BA
    LDA $B1 : STA $BB

    ; Convert sin (y) to float.
    LDA $B2 : STA $B4
    LDA $B3 : STA $B5
    JSR _cordic_q115_to_float
    ; sin_float now in $B0-$B4. Park it on the hw stack while we
    ; do cos.
    LDA $B0 : PHA
    LDA $B1 : PHA
    LDA $B2 : PHA
    LDA $B3 : PHA
    LDA $B4 : PHA

    ; Convert cos (x) to float.
    LDA $BA : STA $B4
    LDA $BB : STA $B5
    JSR _cordic_q115_to_float
    ; cos_float in $B0-$B4 — move to the fpDiv divisor slot.
    LDA $B0 : STA $B5
    LDA $B1 : STA $B6
    LDA $B2 : STA $B7
    LDA $B3 : STA $B8
    LDA $B4 : STA $B9

    ; Restore sin_float to $B0-$B4 (dividend slot).
    PLA : STA $B4
    PLA : STA $B3
    PLA : STA $B2
    PLA : STA $B1
    PLA : STA $B0

    JMP fpDiv

; ── fpAtan ────────────────────────────────────────────────────────────
; atan(x) using CORDIC vectoring mode
; Input: $B0-$B4 = x (float)
; Output: $B0-$B4 = atan(x) in radians (float)
; atan via CORDIC vectoring in Q3.13. Q3.13 has enough integer range
; (approx [-4, 4)) to hold the x value that grows through the
; iterations — the final x = K * sqrt(1 + y²) ≈ 1.65 * sqrt(1 + y²),
; which for |y| ≤ ~2.2 stays below 4. We restrict the direct
; path to |input| < 2 (float exponent ≤ 0) and fold larger inputs
; through the identity atan(a) = π/2 − atan(1/a) so the CORDIC only
; ever sees values in [0, 1] (1/a for a ≥ 2).
;
; Layout during the loop:
;     $B0:$B1 = x (Q3.13, starts at $2000 = 1.0)
;     $B2:$B3 = y (Q3.13, starts at |input| or 1/|input|)
;     $B4:$B5 = z (Q3.13, starts at 0)
;     $BA     = saved sign of the original input (0 = +, 1 = −)
;     $BB     = reciprocal flag (1 if we inverted the input)
;     X       = iteration counter
fpAtan:
    ; NaN or infinity input → NaN (we don't emit the asymptotic
    ; ±π/2 value for atan(±∞); the rest of the float runtime treats
    ; infinity as a hard error and we stay consistent.)
    LDA $B0
    AND #$28
    BNE .fa_ret_nan
    LDA $B0
    AND #$10
    BNE .fa_ret_zero

    ; Save input sign, then clear it so the rest of the routine works
    ; on |input|.
    LDA $B0
    AND #$01
    STA $BA
    LDA $B0
    AND #$FE
    STA $B0
    LDA #$00
    STA $BB             ; no reciprocal by default

    ; Decide direct vs reciprocal based on the float exponent. Float
    ; exponent 0 means value in [1, 2); we run direct CORDIC for that
    ; too (final x ≈ K * sqrt(5) ≈ 3.7, still fits in Q3.13's ~[-4, 4)
    ; range). For exp ≥ 1 (value ≥ 2) we compute 1/|input| first.
    LDA $B1
    BMI .fa_direct      ; exp < 0 → |input| < 1
    BEQ .fa_direct      ; exp == 0 → |input| in [1, 2)
    ; exp ≥ 1 → reciprocal path
    LDA $B0 : STA $B5
    LDA $B1 : STA $B6
    LDA $B2 : STA $B7
    LDA $B3 : STA $B8
    LDA $B4 : STA $B9   ; divisor = |input|
    LDA #$00            ; dividend = 1.0
    STA $B0
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    JSR fpDiv
    LDA #$01
    STA $BB             ; mark reciprocal

.fa_direct:
    ; Convert the (possibly inverted) absolute float to Q3.13 in
    ; $B4:$B5. The converter handles the zero short-circuit via the
    ; flag bit, produces a positive Q3.13 value (we cleared the sign).
    JSR _cordic_float_to_q313

    ; Initialise the CORDIC state:
    ;   y ($B2:$B3) = the Q3.13 value we just produced
    ;   x ($B0:$B1) = 1.0 in Q3.13 = $2000
    ;   z ($B4:$B5) = 0
    LDA $B4 : STA $B2
    LDA $B5 : STA $B3
    LDA #$00 : STA $B0
    LDA #$20 : STA $B1
    LDA #$00
    STA $B4
    STA $B5

    LDX #$00

.fa_loop:
    CPX #14
    BEQ .fa_loop_done
    LDA $B3              ; y.hi
    BMI .fa_y_neg

    ; y ≥ 0  (d = −1):
    ;   x += y  >> i
    ;   y −= x_old >> i
    ;   z += atan[i]
    ; Save x_old on the hw stack before updating x, because the y
    ; update needs the *old* x shifted — we don't want the new value.
    LDA $B0 : PHA
    LDA $B1 : PHA
    JSR _cordic_shift_y          ; $B8:$B9 = y arith-shifted right by i
    CLC
    LDA $B0 : ADC $B8 : STA $B0
    LDA $B1 : ADC $B9 : STA $B1
    PLA : STA $B9
    PLA : STA $B8                ; restore x_old into $B8:$B9
    STX $B6
    JSR _cordic_shift_b89        ; $B8:$B9 = x_old arith-shifted right by i
    LDX $B6
    SEC
    LDA $B2 : SBC $B8 : STA $B2
    LDA $B3 : SBC $B9 : STA $B3
    TXA : ASL A : TAY
    CLC
    LDA $B4 : ADC _cordic_atan_tbl,Y : STA $B4
    LDA $B5 : ADC _cordic_atan_tbl+1,Y : STA $B5
    JMP .fa_loop_next

.fa_y_neg:
    ; y < 0  (d = +1):
    ;   x −= y  >> i
    ;   y += x_old >> i
    ;   z −= atan[i]
    LDA $B0 : PHA
    LDA $B1 : PHA
    JSR _cordic_shift_y
    SEC
    LDA $B0 : SBC $B8 : STA $B0
    LDA $B1 : SBC $B9 : STA $B1
    PLA : STA $B9
    PLA : STA $B8
    STX $B6
    JSR _cordic_shift_b89
    LDX $B6
    CLC
    LDA $B2 : ADC $B8 : STA $B2
    LDA $B3 : ADC $B9 : STA $B3
    TXA : ASL A : TAY
    SEC
    LDA $B4 : SBC _cordic_atan_tbl,Y : STA $B4
    LDA $B5 : SBC _cordic_atan_tbl+1,Y : STA $B5

.fa_loop_next:
    INX
    JMP .fa_loop

.fa_loop_done:
    ; z at $B4:$B5 now holds atan(|input|) or atan(1/|input|) in
    ; Q3.13. Convert it to a 5-byte float in $B0-$B4.
    LDA $B4
    ORA $B5
    BNE .fa_q_nonzero
    ; z is exactly zero (rare but possible for very small inputs).
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    JMP .fa_maybe_recip

.fa_q_nonzero:
    ; Atan results are always non-negative here (we work on |input|),
    ; so we don't need to check the sign of the Q3.13 value.
    LDX #$02                      ; exponent tracker — starts at 2
.fa_q_norm:
    LDA $B5
    BMI .fa_q_normed
    ASL $B4
    ROL $B5
    DEX
    JMP .fa_q_norm
.fa_q_normed:
    ; Bit 15 of $B5 is the implicit leading 1; shift it off the top.
    ASL $B4
    ROL $B5
    ; Pack the 15-bit fraction (now in the top 15 bits of $B5:$B4) into
    ; the float's 24-bit mantissa slot ($B2:$B3:$B4). We just copy the
    ; two bytes up and zero the low byte — losing 9 zero-padding bits
    ; at the bottom, which is fine.
    LDA $B5 : STA $B2
    LDA $B4 : STA $B3
    LDA #$00
    STA $B4
    STX $B1                       ; final exponent
    STA $B0                       ; clear flags (sign handled below)

.fa_maybe_recip:
    LDA $BB
    BEQ .fa_apply_sign
    ; We computed atan(1/|input|); the real answer is π/2 − that.
    ; Move the current result to $B5-$B9 as fpSub's op2 and load π/2
    ; (≈ 1 + 0x921FB5/2^24) into $B0-$B4 as op1.
    LDA $B0 : STA $B5
    LDA $B1 : STA $B6
    LDA $B2 : STA $B7
    LDA $B3 : STA $B8
    LDA $B4 : STA $B9
    LDA #$00
    STA $B0
    STA $B1
    LDA #$92
    STA $B2
    LDA #$1F
    STA $B3
    LDA #$B5
    STA $B4
    JSR fpSub

.fa_apply_sign:
    LDA $BA
    BEQ .fa_done
    LDA $B0
    EOR #$01
    STA $B0
.fa_done:
    RTS

.fa_ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.fa_ret_zero:
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

; Legacy label so other code that references the original body still
; assembles — the implementation above replaces it.
.fa_legacy_end:
    LDX #$00        ; iteration counter

.atan_loop:
    CPX #14
    BEQ .atan_done
    ; Decision based on sign of y (vectoring: drive y to 0).
    ; NOTE: x must be saved before we overwrite it with x+=..., because
    ; the y update uses the OLD x. The original code called shift_x
    ; on the already-updated x and produced garbage.
    LDA $B3         ; y.hi
    BMI .atan_neg

    ; y >= 0 (d = -1 in the standard formulation):
    ;   x' = x + (y >> i)
    ;   y' = y - (x_old >> i)
    ;   z' = z + atan[i]
    LDA $B0 : PHA
    LDA $B1 : PHA                 ; save x_old on stack
    JSR _cordic_shift_y           ; $B8:$B9 = y >> i
    CLC
    LDA $B0 : ADC $B8 : STA $B0
    LDA $B1 : ADC $B9 : STA $B1   ; x = x + (y >> i)
    PLA : STA $B9
    PLA : STA $B8                 ; restore x_old to $B8:$B9
    STX $B6
    JSR _cordic_shift_b89         ; $B8:$B9 = x_old >> i
    LDX $B6
    SEC
    LDA $B2 : SBC $B8 : STA $B2
    LDA $B3 : SBC $B9 : STA $B3   ; y = y - (x_old >> i)
    ; z += atan[i]
    TXA : ASL A : TAY
    CLC
    LDA $B4 : ADC _cordic_atan_tbl,Y : STA $B4
    LDA $B5 : ADC _cordic_atan_tbl+1,Y : STA $B5
    JMP .atan_next

.atan_neg:
    ; y < 0 (d = +1):
    ;   x' = x - (y >> i)
    ;   y' = y + (x_old >> i)
    ;   z' = z - atan[i]
    LDA $B0 : PHA
    LDA $B1 : PHA                 ; save x_old
    JSR _cordic_shift_y
    SEC
    LDA $B0 : SBC $B8 : STA $B0
    LDA $B1 : SBC $B9 : STA $B1   ; x = x - (y >> i)
    PLA : STA $B9
    PLA : STA $B8                 ; restore x_old
    STX $B6
    JSR _cordic_shift_b89         ; $B8:$B9 = x_old >> i
    LDX $B6
    CLC
    LDA $B2 : ADC $B8 : STA $B2
    LDA $B3 : ADC $B9 : STA $B3   ; y = y + (x_old >> i)
    TXA : ASL A : TAY
    SEC
    LDA $B4 : SBC _cordic_atan_tbl,Y : STA $B4
    LDA $B5 : SBC _cordic_atan_tbl+1,Y : STA $B5

.atan_next:
    INX
    JMP .atan_loop

.atan_done:
    ; z ($B4,$B5) contains the angle in Q3.13
    ; Convert to float: first to Q1.15 (shift left by 2)
    ASL $B4
    ROL $B5
    ASL $B4
    ROL $B5
    JMP _cordic_q115_to_float

; ── CORDIC core (rotation mode) ──────────────────────────────────────
; Input: $B4,$B5 = angle in Q3.13 (range-reduced)
; Output: $B0,$B1 = cos (Q1.15), $B2,$B3 = sin (Q1.15)
_cordic_compute:
    ; Initialize: x = 1/K, y = 0
    LDA #_cordic_invK_lo
    STA $B0
    LDA #_cordic_invK_hi
    STA $B1
    LDA #$00
    STA $B2
    STA $B3
    ; Convert angle from Q3.13 to Q3.13 (already there)
    ; z is in $B4,$B5
    LDX #$00        ; iteration counter

.rot_loop:
    CPX #14
    BEQ .rot_done
    ; Decision based on sign of z
    LDA $B5         ; z.hi
    BMI .rot_neg    ; z < 0: rotate clockwise

    ; z >= 0: rotate counter-clockwise
    ; x' = x - (y >> i), y' = y + (x >> i), z' = z - atan[i]
    ; Save x for y calculation
    LDA $B0 : PHA : LDA $B1 : PHA
    JSR _cordic_shift_y ; $B8,$B9 = y >> i
    SEC
    LDA $B0 : SBC $B8 : STA $B0
    LDA $B1 : SBC $B9 : STA $B1
    PLA : STA $B9 : PLA : STA $B8 ; restore original x to $B8,$B9
    ; Shift original x by i
    STX $B6         ; save i
    JSR _cordic_shift_b89
    CLC
    LDA $B2 : ADC $B8 : STA $B2
    LDA $B3 : ADC $B9 : STA $B3
    LDX $B6
    ; z -= atan[i]
    TXA : ASL A : TAY
    SEC
    LDA $B4 : SBC _cordic_atan_tbl,Y : STA $B4
    LDA $B5 : SBC _cordic_atan_tbl+1,Y : STA $B5
    JMP .rot_next

.rot_neg:
    ; z < 0: x' = x + (y >> i), y' = y - (x >> i), z' = z + atan[i]
    LDA $B0 : PHA : LDA $B1 : PHA
    JSR _cordic_shift_y
    CLC
    LDA $B0 : ADC $B8 : STA $B0
    LDA $B1 : ADC $B9 : STA $B1
    PLA : STA $B9 : PLA : STA $B8
    STX $B6
    JSR _cordic_shift_b89
    SEC
    LDA $B2 : SBC $B8 : STA $B2
    LDA $B3 : SBC $B9 : STA $B3
    LDX $B6
    TXA : ASL A : TAY
    CLC
    LDA $B4 : ADC _cordic_atan_tbl,Y : STA $B4
    LDA $B5 : ADC _cordic_atan_tbl+1,Y : STA $B5

.rot_next:
    INX
    JMP .rot_loop

.rot_done:
    RTS

; ── Arithmetic shift right $B2,$B3 by X positions → $B8,$B9 ─────────
_cordic_shift_y:
    LDA $B2 : STA $B8
    LDA $B3 : STA $B9
    STX $B6
    JMP _cordic_shift_b89

_cordic_shift_x:
    LDA $B0 : STA $B8
    LDA $B1 : STA $B9
    STX $B6

_cordic_shift_b89:
    ; Arithmetic right shift $B8,$B9 by X positions
    TXA
    BEQ .shift_done
    TAY
.shift_loop:
    LDA $B9         ; preserve sign
    ASL A           ; sign bit into carry
    ROR $B9         ; arithmetic shift right
    ROR $B8
    DEY
    BNE .shift_loop
.shift_done:
    LDX $B6         ; restore X
    RTS

; ── Float ($B0-$B4) to Q3.13 signed → $B4,$B5 ───────────────────────
_cordic_float_to_q313:
    ; Extract sign
    LDA $B0
    AND #$01
    STA $B7         ; save sign in $B7 bit 0
    ; Check for zero via the zero flag (bit 4 of $B0). Cannot use
    ; "$B1|$B2|$B3|$B4 == 0" here — 1.0 also encodes as all-zero bytes
    ; in the implicit-leading-1 format.
    LDA $B0
    AND #$10
    BEQ .f2q_nonzero
    LDA #$00
    STA $B4
    STA $B5
    RTS
.f2q_nonzero:
    ; Build 16-bit mantissa with implicit 1: hi = $80 | (byte2 >> 1), lo = (byte2 << 7) | (byte3 >> 1)
    LDA $B2
    LSR A
    ORA #$80
    STA $B9         ; hi byte of mantissa
    LDA $B2
    ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A
    STA $B8
    LDA $B3
    LSR A
    ORA $B8
    STA $B8         ; lo byte of mantissa
    ; Now $B8,$B9 is Q1.15 of the mantissa (1.xxx)
    ; To get Q3.13: shift right by (2 - exponent)
    LDA $B1         ; signed exponent
    ; shift count = 2 - exp
    ; If exp = 0, shift right 2. If exp = 1, shift right 1. If exp = 2, no shift.
    ; If exp = -1, shift right 3. If exp > 2, shift left.
    STA $B6         ; save exp
    LDA #$02
    SEC
    SBC $B6         ; A = 2 - exp = shift right count
    BMI .f2q_shl    ; negative = shift left
    BEQ .f2q_noshift
    TAY
.f2q_shr:
    LSR $B9
    ROR $B8
    DEY
    BNE .f2q_shr
    JMP .f2q_noshift
.f2q_shl:
    ; Shift left by |A|
    EOR #$FF
    CLC
    ADC #$01        ; negate
    TAY
.f2q_shl_loop:
    ASL $B8
    ROL $B9
    DEY
    BNE .f2q_shl_loop
.f2q_noshift:
    ; Apply sign
    LDA $B7
    AND #$01
    BEQ .f2q_pos
    SEC
    LDA #$00
    SBC $B8
    STA $B8
    LDA #$00
    SBC $B9
    STA $B9
.f2q_pos:
    LDA $B8
    STA $B4
    LDA $B9
    STA $B5
    RTS

; ── Float ($B0-$B4) to Q1.15 signed → $B4,$B5 ───────────────────────
_cordic_float_to_q115:
    JSR _cordic_float_to_q313
    ; Q3.13 to Q1.15: shift left by 2
    ASL $B4
    ROL $B5
    ASL $B4
    ROL $B5
    RTS

; ── Q1.15 signed ($B4,$B5) to float ($B0-$B4) ───────────────────────
_cordic_q115_to_float:
    ; Check for zero — output must carry the zero flag so it can be
    ; distinguished from 1.0 downstream.
    LDA $B4
    ORA $B5
    BNE .q2f_nonzero
    LDA #$10
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.q2f_nonzero:
    ; Extract sign
    LDA #$00
    STA $B0         ; flags
    LDA $B5
    BPL .q2f_pos
    ; Negate
    SEC
    LDA #$00 : SBC $B4 : STA $B4
    LDA #$00 : SBC $B5 : STA $B5
    LDA #$01
    STA $B0         ; set sign bit
.q2f_pos:
    ; Find MSB position to determine exponent.
    ; Q1.15 after sign-stripping holds a value in [0, 1). A Q1.15 value
    ; of 0x4000 represents 0.5, so after one normalising left-shift it
    ; becomes 0x8000 and the exponent should read -1. Each subsequent
    ; shift drops the exponent by another bit. Start X at 0 — the loop
    ; decrements it once per shift — and the final "strip the implicit
    ; 1" shift after the loop does NOT touch X (bit 15 moves to the
    ; carry, but the value's base-2 exponent stays put).
    LDX #$00
.q2f_norm:
    LDA $B5
    BMI .q2f_normed
    ASL $B4
    ROL $B5
    DEX
    CPX #$F0        ; safety: don't loop too many times
    BNE .q2f_norm
.q2f_normed:
    ; $B5:$B4 holds the normalised value with bit 15 (= bit 7 of $B5)
    ; as the implicit 1. Shift the 16-bit value left by 1 to discard
    ; the implicit 1; what remains are 15 fraction bits in positions
    ; 15..1 (bit 0 becomes zero). The old code stripped the leading 1
    ; from $B5 separately and then ASL'd $B4, which dropped the
    ; carry between bytes — costing one bit of precision. ASL/ROL as
    ; a 16-bit pair avoids that.
    ASL $B4
    ROL $B5
    LDA $B5
    STA $B2         ; mantissa high byte (Q1.15 bits 14..7)
    LDA $B4
    STA $B3         ; mantissa mid  byte (Q1.15 bits  6..0 + 0 pad)
    LDA #$00
    STA $B4         ; mantissa low byte
    STX $B1         ; exponent
    RTS

; ── Range reduce angle from Q3.13 to [-π/2, π/2] ────────────────────
; Input: $B4,$B5 = angle in Q3.13
; Output: $B4,$B5 = reduced angle
;         $B7 bit 0 = negate sin, bit 1 = negate cos
_cordic_range_reduce:
    LDA #$00
    STA $B7         ; clear flags
    ; If angle > π/2, subtract π and flip sin sign
    LDA $B5
    BMI .rr_check_neg
    ; Positive angle
    CMP #_cordic_halfpi_hi
    BCC .rr_done    ; < π/2, done
    BNE .rr_sub_pi
    LDA $B4
    CMP #_cordic_halfpi_lo
    BCC .rr_done
.rr_sub_pi:
    ; angle -= π, flip both sin and cos signs
    SEC
    LDA $B4 : SBC #_cordic_pi_lo : STA $B4
    LDA $B5 : SBC #_cordic_pi_hi : STA $B5
    LDA $B7
    EOR #$03        ; flip both sign bits
    STA $B7
    JMP .rr_done
.rr_check_neg:
    ; Negative angle: if < −π/2, add π and flip both signs.
    ; −π/2 in Q3.13 is $CDBC (two's complement of $3244). We need a
    ; proper two-byte comparison: if hi > $CD, angle is less negative
    ; than −π/2 → done. If hi < $CD, angle is more negative → add π.
    ; If hi == $CD, tiebreak on lo: lo >= $BC → done, else add π.
    ; (The previous single-byte `CMP #$CE; BCS` was off by one — it
    ; treated exactly −π/2 as "needs another π" and produced a spurious
    ; reduction, which put the tan pole detector on the wrong branch.)
    CMP #$CD
    BCC .rr_add_pi
    BNE .rr_done
    LDA $B4
    CMP #$BC
    BCS .rr_done
.rr_add_pi:
    CLC
    LDA $B4 : ADC #_cordic_pi_lo : STA $B4
    LDA $B5 : ADC #_cordic_pi_hi : STA $B5
    LDA $B7
    EOR #$03
    STA $B7
.rr_done:
    RTS

; ── CORDIC atan table (Q3.13, little-endian) ─────────────────────────
_cordic_atan_tbl:
    .word 6434      ; atan(2^0)  = 0.7854 rad
    .word 3798      ; atan(2^-1) = 0.4636
    .word 2007      ; atan(2^-2) = 0.2450
    .word 1019      ; atan(2^-3) = 0.1244
    .word 511       ; atan(2^-4) = 0.0624
    .word 256       ; atan(2^-5) = 0.0312
    .word 128       ; atan(2^-6) = 0.0156
    .word 64        ; atan(2^-7) = 0.0078
    .word 32        ; atan(2^-8) = 0.0039
    .word 16        ; atan(2^-9) = 0.00195
    .word 8         ; atan(2^-10)
    .word 4         ; atan(2^-11)
    .word 2         ; atan(2^-12)
    .word 1         ; atan(2^-13)
