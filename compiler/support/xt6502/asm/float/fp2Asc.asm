; fp2Asc — convert xtc 5-byte float to ATASCII decimal string
; Input:  $B0-$B4 = float
;         $B5,$B6 = pointer to output buffer (at least 16 bytes)
; Output: buffer filled with ATASCII decimal, null-terminated
;
; Float format (matches XTFloatEncoding):
;   byte 0 bit 0: sign (1 = negative)
;   byte 0 bit 1: underflow flag
;   byte 0 bit 2: overflow flag
;   byte 0 bit 3: NaN flag
;   byte 1: signed 8-bit base-2 exponent
;   bytes 2-4: 24-bit fractional mantissa, big-endian (implicit leading 1)
;
; Value = (-1)^sign * (1 + mantissa/2^24) * 2^exp
;
; ZP scratch (matches existing float-runtime convention):
;   $B7-$BA + $BF  IP (40-bit integer part, little-endian; $BF is
;                  the high byte, non-contiguous but stitched into
;                  every IP shift / div via an extra ROL/LSR step)
;   $BB-$BE        FP (32-bit fraction * 2^32, little-endian)
;
; The IP field used to be 32 bits in $B7-$BA, which capped the
; "render as fixed-point" range at exp 30 — i.e. the routine
; printed `inf` for any value at or above 2^31 (~2.15e9), so a
; perfectly representable u32 like $FFFFFFFF (exp = 31) came out
; as inf rather than ~4.29e9. Adding $BF as the high byte pushes
; the cap to exp 39 (~5.5e11), which covers the full u32 range
; and a chunk beyond. Values larger than that still emit `inf`,
; since 6 decimal places of fixed-point output for anything past
; ~10^12 is mostly-noise digits anyway.
;
; All branch targets are global labels to avoid interaction with xta's
; long-branch rewriter (which inserts _xlb_N globals and would otherwise
; reshuffle local-label scoping).

fp2Asc:
    LDY #$00

    LDA $B0
    AND #$08
    BNE fp2Asc_nan
    ; Infinity: bit 5 ($20) is the new canonical flag, bit 2 ($04)
    ; was the legacy overflow route which still reaches the same
    ; "inf" output string. Both go through fp2Asc_maybe_inf so the
    ; sign byte is emitted up front (NaN is unsigned and skips this).
    LDA $B0
    AND #$24
    BNE fp2Asc_maybe_inf
    ; Underflow flag (bit 1) → print "0.0".
    LDA $B0
    AND #$02
    BNE fp2Asc_zero

    ; True zero flag (bit 4) → print "0.0". Without this check the
    ; old code fell into an "all mantissa+exp bytes zero" fallback
    ; (removed below), which happened to handle zero but also
    ; confused 1.0 for 0.0 because 1.0 is encoded as
    ; {$00, $00, $00, $00, $00} (exp 0, mantissa 0, implicit
    ; leading 1 → value 1.0). Every `printf("%f", 1.0)` used to
    ; print "0.0" because of that collision.
    LDA $B0
    AND #$10
    BNE fp2Asc_zero

    LDA $B0
    AND #$01
    STA _fp2asc_sign
    BEQ fp2Asc_pos
    LDA #$2D
    STA ($B5),Y
    INY
fp2Asc_pos:

    LDA $B1
    STA _fp2asc_exp

    ; V (25-bit, implicit 1 at bit 24) → $B7-$BA little-endian.
    ; $BF is the new high byte of IP, initialised to zero so the
    ; 40-bit field starts as just the 25-bit V at the bottom.
    LDA $B4 : STA $B7
    LDA $B3 : STA $B8
    LDA $B2 : STA $B9
    LDA #$01 : STA $BA
    LDA #$00 : STA $BF

    LDA #$00
    STA $BB
    STA $BC
    STA $BD
    STA $BE

    LDA _fp2asc_exp
    BMI fp2Asc_neg_exp

    CMP #24
    BCC fp2Asc_small_pos
    CMP #40
    BCS fp2Asc_inf

    ; 24 <= exp <= 39: left-shift IP by (exp - 24). The ROL chain
    ; runs from $B7 (low) up through $BA and finally $BF (high).
    SEC
    SBC #24
    TAX
    BEQ fp2Asc_have_parts
fp2Asc_lsh_ip:
    ASL $B7
    ROL $B8
    ROL $B9
    ROL $BA
    ROL $BF
    DEX
    BNE fp2Asc_lsh_ip
    JMP fp2Asc_have_parts

fp2Asc_small_pos:
    ; 0 <= exp < 24: right-shift V by (24 - exp), rotating ejected bits
    ; into the top of FP. IP ends up in $B7-$BA + $BF, fraction in $BB-$BE.
    ; $BF is always 0 here (the leading 1 lives in $BA bit 0), but the
    ; LSR/ROR chain still has to start from $BF so the carry chain is
    ; consistent with the rest of the routine.
    LDA #24
    SEC
    SBC _fp2asc_exp
    TAX
fp2Asc_sp_loop:
    LSR $BF
    ROR $BA
    ROR $B9
    ROR $B8
    ROR $B7
    ROR $BE
    ROR $BD
    ROR $BC
    ROR $BB
    DEX
    BNE fp2Asc_sp_loop
    JMP fp2Asc_have_parts

fp2Asc_neg_exp:
    ; IP = 0; FP = V << (8 + exp), handling negative shifts as right shifts.
    ;
    ; V is a 25-bit integer in $B7-$BA with the implicit leading 1 at
    ; bit 24. For exp < 0 the true value is V * 2^(exp - 24). As a
    ; 32-bit fixed-point fraction F such that F = value < 1 implies
    ; FP = F * 2^32, we want FP = V * 2^(exp - 24 + 32) = V * 2^(8 + exp).
    ;
    ; The previous constant here was `ADC #$07`, which computed
    ; `V << (7 + exp)` — exactly half the correct value. Every negative-
    ; exponent printf %f came out as half its actual magnitude, but no
    ; fixture caught it because float_arith.xt captures raw bytes via
    ; asm and compares patterns rather than printing via fp2Asc.
    LDA $B7 : STA $BB
    LDA $B8 : STA $BC
    LDA $B9 : STA $BD
    LDA $BA : STA $BE
    LDA #$00
    STA $B7
    STA $B8
    STA $B9
    STA $BA
    STA $BF             ; clear the new IP high byte too

    LDA _fp2asc_exp
    CLC
    ADC #$08
    BEQ fp2Asc_have_parts
    BPL fp2Asc_ne_left
    EOR #$FF
    CLC
    ADC #$01
    CMP #33
    BCS fp2Asc_fp_clear
    TAX
fp2Asc_ne_right:
    LSR $BE
    ROR $BD
    ROR $BC
    ROR $BB
    DEX
    BNE fp2Asc_ne_right
    JMP fp2Asc_have_parts
fp2Asc_ne_left:
    TAX
fp2Asc_ne_left_loop:
    ASL $BB
    ROL $BC
    ROL $BD
    ROL $BE
    DEX
    BNE fp2Asc_ne_left_loop
    JMP fp2Asc_have_parts

fp2Asc_fp_clear:
    LDA #$00
    STA $BB
    STA $BC
    STA $BD
    STA $BE

fp2Asc_have_parts:
    JSR _fp2asc_print_ip

    LDA #$2E
    STA ($B5),Y
    INY

    LDA #$06
    STA _fp2asc_cnt
fp2Asc_frac_loop:
    JSR _fp2asc_mul10
    CLC
    ADC #$30
    STA ($B5),Y
    INY
    DEC _fp2asc_cnt
    BNE fp2Asc_frac_loop

    LDA #$00
    STA ($B5),Y
    RTS

fp2Asc_zero:
    LDA #$30 : STA ($B5),Y : INY
    LDA #$2E : STA ($B5),Y : INY
    LDA #$30 : STA ($B5),Y : INY
    LDA #$00 : STA ($B5),Y
    RTS

fp2Asc_nan:
    LDA #$6E : STA ($B5),Y : INY    ; 'n'
    LDA #$61 : STA ($B5),Y : INY    ; 'a'
    LDA #$6E : STA ($B5),Y : INY    ; 'n'
    LDA #$00 : STA ($B5),Y
    RTS

; Entry from the top-of-routine infinity check: emit '-' if the
; sign bit is set, then fall into fp2Asc_inf to emit "inf". The
; other path into fp2Asc_inf (a BCS from the conversion loop when
; the exponent overflows) has already emitted the sign separately,
; so it jumps past this stub.
fp2Asc_maybe_inf:
    LDA $B0
    AND #$01
    BEQ fp2Asc_inf
    LDA #$2D
    STA ($B5),Y
    INY
fp2Asc_inf:
    LDA #$69 : STA ($B5),Y : INY    ; 'i'
    LDA #$6E : STA ($B5),Y : INY    ; 'n'
    LDA #$66 : STA ($B5),Y : INY    ; 'f'
    LDA #$00 : STA ($B5),Y
    RTS


; ── Print 40-bit unsigned integer at $B7-$BA + $BF to ($B5),Y ────────
_fp2asc_print_ip:
    LDA $B7
    ORA $B8
    ORA $B9
    ORA $BA
    ORA $BF
    BNE _fp2asc_pi_nonzero
    LDA #$30
    STA ($B5),Y
    INY
    RTS
_fp2asc_pi_nonzero:
    LDA #$00
    STA _fp2asc_cnt
_fp2asc_pi_div:
    LDA $B7
    ORA $B8
    ORA $B9
    ORA $BA
    ORA $BF
    BEQ _fp2asc_pi_emit
    JSR _fp2asc_div10
    CLC
    ADC #$30
    PHA
    INC _fp2asc_cnt
    JMP _fp2asc_pi_div
_fp2asc_pi_emit:
    LDX _fp2asc_cnt
_fp2asc_pi_emit_loop:
    PLA
    STA ($B5),Y
    INY
    DEX
    BNE _fp2asc_pi_emit_loop
    RTS


; ── Divide 40-bit $B7-$BA + $BF by 10. Quotient in place, remainder in A. ──
_fp2asc_div10:
    LDX #40
    LDA #$00
_fp2asc_d10_loop:
    ASL $B7
    ROL $B8
    ROL $B9
    ROL $BA
    ROL $BF
    ROL A
    CMP #10
    BCC _fp2asc_d10_skip
    SBC #10
    INC $B7
_fp2asc_d10_skip:
    DEX
    BNE _fp2asc_d10_loop
    RTS


; ── FP ($BB-$BE) *= 10. Returns digit (0..9) in A. ──────────────────
_fp2asc_mul10:
    LDA $BB : STA _fp2asc_tmpA
    LDA $BC : STA _fp2asc_tmpA+1
    LDA $BD : STA _fp2asc_tmpA+2
    LDA $BE : STA _fp2asc_tmpA+3
    LDA #$00 : STA _fp2asc_tmpA+4

    LDA _fp2asc_tmpA   : STA _fp2asc_tmpB
    LDA _fp2asc_tmpA+1 : STA _fp2asc_tmpB+1
    LDA _fp2asc_tmpA+2 : STA _fp2asc_tmpB+2
    LDA _fp2asc_tmpA+3 : STA _fp2asc_tmpB+3
    LDA _fp2asc_tmpA+4 : STA _fp2asc_tmpB+4

    ASL _fp2asc_tmpA
    ROL _fp2asc_tmpA+1
    ROL _fp2asc_tmpA+2
    ROL _fp2asc_tmpA+3
    ROL _fp2asc_tmpA+4

    ASL _fp2asc_tmpB
    ROL _fp2asc_tmpB+1
    ROL _fp2asc_tmpB+2
    ROL _fp2asc_tmpB+3
    ROL _fp2asc_tmpB+4
    ASL _fp2asc_tmpB
    ROL _fp2asc_tmpB+1
    ROL _fp2asc_tmpB+2
    ROL _fp2asc_tmpB+3
    ROL _fp2asc_tmpB+4
    ASL _fp2asc_tmpB
    ROL _fp2asc_tmpB+1
    ROL _fp2asc_tmpB+2
    ROL _fp2asc_tmpB+3
    ROL _fp2asc_tmpB+4

    CLC
    LDA _fp2asc_tmpA   : ADC _fp2asc_tmpB   : STA _fp2asc_tmpA
    LDA _fp2asc_tmpA+1 : ADC _fp2asc_tmpB+1 : STA _fp2asc_tmpA+1
    LDA _fp2asc_tmpA+2 : ADC _fp2asc_tmpB+2 : STA _fp2asc_tmpA+2
    LDA _fp2asc_tmpA+3 : ADC _fp2asc_tmpB+3 : STA _fp2asc_tmpA+3
    LDA _fp2asc_tmpA+4 : ADC _fp2asc_tmpB+4 : STA _fp2asc_tmpA+4

    LDA _fp2asc_tmpA   : STA $BB
    LDA _fp2asc_tmpA+1 : STA $BC
    LDA _fp2asc_tmpA+2 : STA $BD
    LDA _fp2asc_tmpA+3 : STA $BE

    LDA _fp2asc_tmpA+4
    RTS


_fp2asc_sign: .byte $00
_fp2asc_exp:  .byte $00
_fp2asc_cnt:  .byte $00
_fp2asc_tmpA: .byte $00, $00, $00, $00, $00
_fp2asc_tmpB: .byte $00, $00, $00, $00, $00
