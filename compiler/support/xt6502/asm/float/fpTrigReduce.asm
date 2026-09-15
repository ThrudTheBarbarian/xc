; fpTrigReduce.asm — float-arithmetic range reduction for trig
;
; The CORDIC and table-based fpSin/fpCos/fpTan routines both convert
; their input angle to a 16-bit Q3.13 fixed-point representation
; whose range is [-4, 4). Anything outside that overflows the
; conversion silently — `sin(10.0)` came out as the wrong answer
; because the float-to-Q3.13 step truncated the high bits before any
; range reduction happened, and the existing `_cordic_range_reduce`
; only subtracts a single ±π once it's already in [-4, 4).
;
; The fix here is a separate routine that the trig functions invoke
; before the Q3.13 conversion, but only when the input's exponent is
; ≥ 2 (i.e. magnitude ≥ 4). Inputs that already fit in [-4, 4) skip
; this entirely and stay in the existing fast path. For inputs that
; do trigger reduction:
;
;   1. fpMod by 2π — gives a result in (-2π, 2π).
;   2. If result > π, subtract 2π — now in (-π, 0).
;   3. If result < -π, add 2π — now in (0, π).
;
; After step 3 the magnitude is ≤ π < 4, fits cleanly in Q3.13, and
; the existing in-range _cordic_range_reduce / _trig_angle_to_idx
; reduction takes it the rest of the way to [-π/2, π/2].
;
; Constants are 2π and ±π in the xtc 5-byte float format. Only π and
; 2π are stored; the negatives are derived from the sign bit on the
; fly so the table stays a single 10-byte block.
;
; Input:  $B0-$B4 = angle (float)
; Output: $B0-$B4 = angle (float) reduced to (-π, π]
; Clobbers: A, X, Y, $B5-$B9, hardware stack via fpMod / fpAdd / fpCmp.

_fp_reduce_to_pi:
    ; Save the original input on the HW stack so we can fall back to
    ; it untouched if the input is NaN or infinity. fpMod on a
    ; non-finite operand would return garbage; better to leave the
    ; trig routine to detect the special case itself.
    LDA $B0
    AND #$2C            ; NaN ($08) | inf ($20) | overflow ($04)
    BNE .rtp_nonfinite

    ; Load 2π into $B5-$B9 and call fpMod.
    LDY #_fp_const_2pi
    JSR _fp_load_const_op2
    JSR fpMod                       ; $B0-$B4 = angle mod 2π in (-2π, 2π)

    ; Compare against +π. fpCmp returns A=$01 (>), $00 (==), $FF (<).
    LDY #_fp_const_pi
    JSR _fp_load_const_op2
    JSR fpCmp
    BEQ .rtp_done                   ; equal — already in range
    BMI .rtp_check_neg              ; less — check the lower bound
    ; Greater than π → subtract 2π by adding -2π.
    LDY #_fp_const_2pi
    JSR _fp_load_const_op2
    LDA $B5
    ORA #$01                        ; flip sign bit → -2π
    STA $B5
    JSR fpAdd
    RTS

.rtp_check_neg:
    ; Compare against -π. Reuse the π constant and flip the sign.
    LDY #_fp_const_pi
    JSR _fp_load_const_op2
    LDA $B5
    ORA #$01                        ; -π
    STA $B5
    JSR fpCmp
    BPL .rtp_done                   ; ≥ -π — in range
    ; Less than -π → add 2π.
    LDY #_fp_const_2pi
    JSR _fp_load_const_op2
    JSR fpAdd
.rtp_done:
    RTS

.rtp_nonfinite:
    ; Leave the value alone — the trig routine's NaN / infinity
    ; check at entry will turn it into a NaN result.
    RTS

; Y = byte offset into the constant table; copies 5 bytes into
; $B5-$B9. Used for both the 2π and π entries (the negatives are
; produced by ORing $01 into byte 0 after the load).
_fp_load_const_op2:
    LDA _fp_trig_consts,Y
    STA $B5
    LDA _fp_trig_consts+1,Y
    STA $B6
    LDA _fp_trig_consts+2,Y
    STA $B7
    LDA _fp_trig_consts+3,Y
    STA $B8
    LDA _fp_trig_consts+4,Y
    STA $B9
    RTS

_fp_const_pi  = $00
_fp_const_2pi = $05

_fp_trig_consts:
    .byte $00, $01, $92, $1F, $B5    ; +0  π   = 3.14159265
    .byte $00, $02, $92, $1F, $B5    ; +5  2π  = 6.28318531
