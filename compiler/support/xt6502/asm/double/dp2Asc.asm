; dp2Asc — convert xtc 8-byte double to ATASCII decimal string
; Input:  $B0-$B7 = double
;         $B8,$B9 = pointer to output buffer (at least 32 bytes)
; Output: buffer filled with ATASCII decimal, null-terminated
;
; Double format (matches XTFloatEncoding):
;   byte 0 flags: bit 0 sign, bit 1 underflow, bit 2 overflow,
;                 bit 3 NaN, bit 4 zero, bit 5 infinity
;   byte 1      : signed 8-bit base-2 exponent
;   bytes 2-7   : 48-bit big-endian mantissa, implicit leading 1
;
; Value = (-1)^sign * (1 + mantissa/2^48) * 2^exp
;
; Strategy (same shape as fp2Asc, wider fields):
; ──────────────────────────────────────────────
; Construct a 112-bit fixed-point representation W = IP.FP, where
; IP is 8 bytes (little-endian) and FP is 6 bytes (little-endian,
; scale 2^-48). The value represented is IP + FP/2^48.
;
; Load V = 1.mantissa as a 49-bit integer (mantissa bytes + an
; implicit 1 bit) into the low 7 bytes of W (V's LSB at W bit 0).
; At this point W = V = 1.mantissa * 2^48, i.e. the actual value
; multiplied by 2^48. Shift W left by `exp` bits (right by |exp|
; for negative exponents) so W = value * 2^48 exactly, at which
; point IP = integer part and FP/2^48 = fractional part.
;
; Print IP via repeated /10 (digits accumulated on the hardware
; stack, then popped back out), then a '.', then 10 fractional
; digits via repeated FP *= 10 (top byte of each *10 is the next
; digit). 10 frac digits is the compromise between float's 6 and
; the ~14.5 digits a 48-bit mantissa can theoretically express;
; by digit 10 the accumulated rounding noise in FP is still well
; below the last-emitted digit.
;
; Range:
;   exp  >= 64  → overflow, emit "inf" (IP would overflow 64 bits)
;   exp  <  -48 → underflow, emit "0.0000000000" (V shifted out
;                 past FP bit 0; value < 2^-48, well below the
;                 10th-digit representability of 10^-10)
;
; Storage
; ───────
; ZP:
;   $B0-$B7  input double
;   $B8,$B9  output buffer pointer (indirect via ($B8),Y)
;
; Data-section scratch (declared at end of file):
;   _dp2asc_sign  1 byte   sign (0/1), stashed for the emit path
;   _dp2asc_exp   1 byte   working exponent copy
;   _dp2asc_cnt   1 byte   loop counters (reused IP-emit / frac)
;   _dp2asc_IP    8 bytes  64-bit integer part, LE
;   _dp2asc_FP    6 bytes  48-bit fraction part, LE
;   _dp2asc_tmpA  7 bytes  mul10 2x scratch (+1 byte overflow)
;   _dp2asc_tmpB  7 bytes  mul10 8x scratch (+1 byte overflow)
;
; All branch targets are global labels to avoid interaction with
; xta's long-branch rewriter (same convention as fp2Asc).

dp2Asc:
    LDY #$00

    LDA $B0
    AND #$08
    BNE dp2Asc_nan

    ; Infinity: bit 5 ($20) is the canonical flag, bit 2 ($04) is
    ; the legacy overflow route; both reach the same "inf" string
    ; via dp2Asc_maybe_inf (which also emits the sign byte).
    LDA $B0
    AND #$24
    BNE dp2Asc_maybe_inf

    ; Underflow (bit 1) or zero (bit 4) → "0.0000000000".
    LDA $B0
    AND #$12
    BNE dp2Asc_zero

    LDA $B0
    AND #$01
    STA _dp2asc_sign
    BEQ dp2Asc_pos
    LDA #$2D
    STA ($B8),Y
    INY
dp2Asc_pos:

    LDA $B1
    STA _dp2asc_exp

    ; Load V (49 bits, implicit 1 at bit 48) as a little-endian
    ; integer at W bit 0 — the combined 14-byte field W = FP.IP
    ; (FP[0..5] low 48 bits, IP[0..7] high 64 bits). V's bits 0..47
    ; are the stored mantissa (LSB in FP[0]); bit 48 is the implicit
    ; 1, which lands at IP[0] bit 0. Everything else is zero. At
    ; this point W = V = (1.mantissa) * 2^48, so the "baseline"
    ; exponent is 0 and any further shift left by `exp` bits leaves
    ; W = value * 2^48.
    LDA $B7 : STA _dp2asc_FP
    LDA $B6 : STA _dp2asc_FP+1
    LDA $B5 : STA _dp2asc_FP+2
    LDA $B4 : STA _dp2asc_FP+3
    LDA $B3 : STA _dp2asc_FP+4
    LDA $B2 : STA _dp2asc_FP+5
    LDA #$01 : STA _dp2asc_IP
    LDA #$00
    STA _dp2asc_IP+1
    STA _dp2asc_IP+2
    STA _dp2asc_IP+3
    STA _dp2asc_IP+4
    STA _dp2asc_IP+5
    STA _dp2asc_IP+6
    STA _dp2asc_IP+7

    LDA _dp2asc_exp
    BMI dp2Asc_shift_right
    CMP #64
    BCS dp2Asc_inf_mid

    ; Positive exponent: shift W left by `exp` bits.
    TAX
    BEQ dp2Asc_have_parts
dp2Asc_lsh_loop:
    ASL _dp2asc_FP
    ROL _dp2asc_FP+1
    ROL _dp2asc_FP+2
    ROL _dp2asc_FP+3
    ROL _dp2asc_FP+4
    ROL _dp2asc_FP+5
    ROL _dp2asc_IP
    ROL _dp2asc_IP+1
    ROL _dp2asc_IP+2
    ROL _dp2asc_IP+3
    ROL _dp2asc_IP+4
    ROL _dp2asc_IP+5
    ROL _dp2asc_IP+6
    ROL _dp2asc_IP+7
    DEX
    BNE dp2Asc_lsh_loop
    JMP dp2Asc_have_parts

dp2Asc_inf_mid:
    JMP dp2Asc_inf

dp2Asc_shift_right:
    ; Negative exp: shift W right by |exp| bits. Cap at 49 (more
    ; than that shifts V's implicit 1 past FP bit 0).
    EOR #$FF
    CLC
    ADC #$01
    CMP #49
    BCS dp2Asc_underflow
    TAX
dp2Asc_rsh_loop:
    LSR _dp2asc_IP+7
    ROR _dp2asc_IP+6
    ROR _dp2asc_IP+5
    ROR _dp2asc_IP+4
    ROR _dp2asc_IP+3
    ROR _dp2asc_IP+2
    ROR _dp2asc_IP+1
    ROR _dp2asc_IP
    ROR _dp2asc_FP+5
    ROR _dp2asc_FP+4
    ROR _dp2asc_FP+3
    ROR _dp2asc_FP+2
    ROR _dp2asc_FP+1
    ROR _dp2asc_FP
    DEX
    BNE dp2Asc_rsh_loop
    JMP dp2Asc_have_parts

dp2Asc_underflow:
    ; Value is below 2^-48; 10 fractional digits all round to 0.
    LDA #$00
    STA _dp2asc_FP
    STA _dp2asc_FP+1
    STA _dp2asc_FP+2
    STA _dp2asc_FP+3
    STA _dp2asc_FP+4
    STA _dp2asc_FP+5
    STA _dp2asc_IP
    STA _dp2asc_IP+1
    STA _dp2asc_IP+2
    STA _dp2asc_IP+3
    STA _dp2asc_IP+4
    STA _dp2asc_IP+5
    STA _dp2asc_IP+6
    STA _dp2asc_IP+7

dp2Asc_have_parts:
    JSR _dp2asc_print_ip

    LDA #$2E
    STA ($B8),Y
    INY

    LDA #10
    STA _dp2asc_cnt
dp2Asc_frac_loop:
    JSR _dp2asc_mul10
    CLC
    ADC #$30
    STA ($B8),Y
    INY
    DEC _dp2asc_cnt
    BNE dp2Asc_frac_loop

    LDA #$00
    STA ($B8),Y
    RTS

dp2Asc_zero:
    LDA #$30 : STA ($B8),Y : INY
    LDA #$2E : STA ($B8),Y : INY
    LDX #10
dp2Asc_zero_frac:
    LDA #$30 : STA ($B8),Y : INY
    DEX
    BNE dp2Asc_zero_frac
    LDA #$00
    STA ($B8),Y
    RTS

dp2Asc_nan:
    LDA #$6E : STA ($B8),Y : INY    ; 'n'
    LDA #$61 : STA ($B8),Y : INY    ; 'a'
    LDA #$6E : STA ($B8),Y : INY    ; 'n'
    LDA #$00 : STA ($B8),Y
    RTS

dp2Asc_maybe_inf:
    LDA $B0
    AND #$01
    BEQ dp2Asc_inf
    LDA #$2D
    STA ($B8),Y
    INY
dp2Asc_inf:
    LDA #$69 : STA ($B8),Y : INY    ; 'i'
    LDA #$6E : STA ($B8),Y : INY    ; 'n'
    LDA #$66 : STA ($B8),Y : INY    ; 'f'
    LDA #$00 : STA ($B8),Y
    RTS


; ── Print IP (8 bytes, LE) to ($B8),Y ─────────────────────────────────
_dp2asc_print_ip:
    LDA _dp2asc_IP
    ORA _dp2asc_IP+1
    ORA _dp2asc_IP+2
    ORA _dp2asc_IP+3
    ORA _dp2asc_IP+4
    ORA _dp2asc_IP+5
    ORA _dp2asc_IP+6
    ORA _dp2asc_IP+7
    BNE _dp2asc_pi_nonzero
    LDA #$30
    STA ($B8),Y
    INY
    RTS
_dp2asc_pi_nonzero:
    LDA #$00
    STA _dp2asc_cnt
_dp2asc_pi_div:
    LDA _dp2asc_IP
    ORA _dp2asc_IP+1
    ORA _dp2asc_IP+2
    ORA _dp2asc_IP+3
    ORA _dp2asc_IP+4
    ORA _dp2asc_IP+5
    ORA _dp2asc_IP+6
    ORA _dp2asc_IP+7
    BEQ _dp2asc_pi_emit
    JSR _dp2asc_div10
    CLC
    ADC #$30
    PHA
    INC _dp2asc_cnt
    JMP _dp2asc_pi_div
_dp2asc_pi_emit:
    LDX _dp2asc_cnt
_dp2asc_pi_emit_loop:
    PLA
    STA ($B8),Y
    INY
    DEX
    BNE _dp2asc_pi_emit_loop
    RTS


; ── Divide IP (8 bytes, LE) by 10. Quotient in place; remainder in A. ─
_dp2asc_div10:
    LDX #64
    LDA #$00
_dp2asc_d10_loop:
    ASL _dp2asc_IP
    ROL _dp2asc_IP+1
    ROL _dp2asc_IP+2
    ROL _dp2asc_IP+3
    ROL _dp2asc_IP+4
    ROL _dp2asc_IP+5
    ROL _dp2asc_IP+6
    ROL _dp2asc_IP+7
    ROL A
    CMP #10
    BCC _dp2asc_d10_skip
    SBC #10
    INC _dp2asc_IP
_dp2asc_d10_skip:
    DEX
    BNE _dp2asc_d10_loop
    RTS


; ── FP (6 bytes, LE) *= 10. Returns digit (0..9) in A. ────────────────
; 10x = 8x + 2x. Compute 2x into tmpA (FP copied with a zero
; overflow byte), copy to tmpB, triple-shift tmpB (now 8x), add
; tmpA back. tmpB+6 is the carry-out = next decimal digit.
_dp2asc_mul10:
    LDA _dp2asc_FP   : STA _dp2asc_tmpA
    LDA _dp2asc_FP+1 : STA _dp2asc_tmpA+1
    LDA _dp2asc_FP+2 : STA _dp2asc_tmpA+2
    LDA _dp2asc_FP+3 : STA _dp2asc_tmpA+3
    LDA _dp2asc_FP+4 : STA _dp2asc_tmpA+4
    LDA _dp2asc_FP+5 : STA _dp2asc_tmpA+5
    LDA #$00         : STA _dp2asc_tmpA+6

    LDA _dp2asc_tmpA   : STA _dp2asc_tmpB
    LDA _dp2asc_tmpA+1 : STA _dp2asc_tmpB+1
    LDA _dp2asc_tmpA+2 : STA _dp2asc_tmpB+2
    LDA _dp2asc_tmpA+3 : STA _dp2asc_tmpB+3
    LDA _dp2asc_tmpA+4 : STA _dp2asc_tmpB+4
    LDA _dp2asc_tmpA+5 : STA _dp2asc_tmpB+5
    LDA _dp2asc_tmpA+6 : STA _dp2asc_tmpB+6

    ASL _dp2asc_tmpA
    ROL _dp2asc_tmpA+1
    ROL _dp2asc_tmpA+2
    ROL _dp2asc_tmpA+3
    ROL _dp2asc_tmpA+4
    ROL _dp2asc_tmpA+5
    ROL _dp2asc_tmpA+6

    ASL _dp2asc_tmpB
    ROL _dp2asc_tmpB+1
    ROL _dp2asc_tmpB+2
    ROL _dp2asc_tmpB+3
    ROL _dp2asc_tmpB+4
    ROL _dp2asc_tmpB+5
    ROL _dp2asc_tmpB+6
    ASL _dp2asc_tmpB
    ROL _dp2asc_tmpB+1
    ROL _dp2asc_tmpB+2
    ROL _dp2asc_tmpB+3
    ROL _dp2asc_tmpB+4
    ROL _dp2asc_tmpB+5
    ROL _dp2asc_tmpB+6
    ASL _dp2asc_tmpB
    ROL _dp2asc_tmpB+1
    ROL _dp2asc_tmpB+2
    ROL _dp2asc_tmpB+3
    ROL _dp2asc_tmpB+4
    ROL _dp2asc_tmpB+5
    ROL _dp2asc_tmpB+6

    CLC
    LDA _dp2asc_tmpA   : ADC _dp2asc_tmpB   : STA _dp2asc_tmpA
    LDA _dp2asc_tmpA+1 : ADC _dp2asc_tmpB+1 : STA _dp2asc_tmpA+1
    LDA _dp2asc_tmpA+2 : ADC _dp2asc_tmpB+2 : STA _dp2asc_tmpA+2
    LDA _dp2asc_tmpA+3 : ADC _dp2asc_tmpB+3 : STA _dp2asc_tmpA+3
    LDA _dp2asc_tmpA+4 : ADC _dp2asc_tmpB+4 : STA _dp2asc_tmpA+4
    LDA _dp2asc_tmpA+5 : ADC _dp2asc_tmpB+5 : STA _dp2asc_tmpA+5
    LDA _dp2asc_tmpA+6 : ADC _dp2asc_tmpB+6 : STA _dp2asc_tmpA+6

    LDA _dp2asc_tmpA   : STA _dp2asc_FP
    LDA _dp2asc_tmpA+1 : STA _dp2asc_FP+1
    LDA _dp2asc_tmpA+2 : STA _dp2asc_FP+2
    LDA _dp2asc_tmpA+3 : STA _dp2asc_FP+3
    LDA _dp2asc_tmpA+4 : STA _dp2asc_FP+4
    LDA _dp2asc_tmpA+5 : STA _dp2asc_FP+5

    LDA _dp2asc_tmpA+6
    RTS


_dp2asc_sign: .byte $00
_dp2asc_exp:  .byte $00
_dp2asc_cnt:  .byte $00
_dp2asc_IP:   .byte $00, $00, $00, $00, $00, $00, $00, $00
_dp2asc_FP:   .byte $00, $00, $00, $00, $00, $00
_dp2asc_tmpA: .byte $00, $00, $00, $00, $00, $00, $00
_dp2asc_tmpB: .byte $00, $00, $00, $00, $00, $00, $00
