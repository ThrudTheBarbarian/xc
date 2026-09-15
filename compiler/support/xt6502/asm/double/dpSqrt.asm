; dpSqrt — square root of an 8-byte double
; Input:  $B0-$B7 = operand (double)
; Output: $B0-$B7 = sqrt(operand) (double)
;
; Double format: byte 0 bit 0=sign, 1=underflow, 2=overflow,
;                3=NaN, 4=zero, 5=infinity;
;                byte 1 = signed exponent (int8);
;                bytes 2-7 = 48-bit mantissa (implicit leading 1).
;
; Algorithm
; ─────────
; Same shape as fpSqrt, widened to a 48-bit stored mantissa. For
; input (1 + f/2^48) * 2^E, let M = 2^48 + f (a 49-bit integer with
; bit 48 = 1). Write the true value as M * 2^(E-48). Then
;
;     sqrt(value) = sqrt(M) * 2^((E-48)/2)
;
; When (E-48) is odd we rewrite as sqrt(2*M) * 2^((E-49)/2) and
; run the sqrt on 2M.
;
; Scale M up by 2^14 to build a 64-bit radicand D = M << 14 (bit 62
; = implicit 1, bits 61..14 = mantissa, bits 13..0 = 0), then feed
; through a 49-iteration bit-by-bit integer sqrt. Q comes out as a
; 49-bit value with bit 48 set (the implicit leading 1) and bits
; 47..0 as the new stored mantissa — no extra shift / exp correction
; needed.
;
; The bit-by-bit sqrt iteration (in pseudocode):
;
;     Q = 0; R = 0
;     for i = 1..49:
;         shift (R:D) left by 2 bits
;         trial = (Q << 2) | 1
;         if R >= trial:
;             R -= trial
;             Q = (Q << 1) | 1
;         else:
;             Q = Q << 1
;
; Storage
; ───────
; $B0:         final flags byte (0 on success, $10 for zero, $08 for
;              NaN returns).
; $B1:         halved signed exponent (computed on entry, final
;              output byte).
; $B2-$B7:     input mantissa bytes at entry; Q's low 48 bits
;              ($B2 = Q's MSByte of bits 47..0, $B7 = LSByte) during
;              and after the loop. Those are exactly the output
;              mantissa bytes so no repack is needed.
; $B8-$BF:     64-bit remainder R during the loop. $B8 = MSByte,
;              $BF = LSByte. Clobbered on exit.
;
; Data-section scratch:
;   _dpSqrt_Qhi     1 byte  Q bit 48 in bit 0 — the implicit leading
;                           1 that iter 49 sets.
;   _dpSqrt_parity  1 byte  original exponent parity (bit 0).
;   _dpSqrt_D       8 bytes 64-bit radicand. D[0] = MSByte,
;                           D[7] = LSByte.
;   _dpSqrt_trial   7 bytes precomputed (Q << 2) | 1 for the subtract.
;                           trial[0] = LSByte, trial[6] = MSByte.
;   _dpSqrt_newR    8 bytes tentative new R after trial-subtract.
;                           newR[0] = MSByte so that the commit-copy
;                           loop stores newR[0]→$B8, newR[7]→$BF.
;
; All branch targets are global labels to avoid interaction with
; xta's long-branch rewriter (same convention as the other dp*
; files).

dpSqrt:
    ; --- Special cases ---
    LDA $B0
    AND #$28                    ; NaN (bit 3) or infinity (bit 5) → NaN
    BNE dpSqrt_nan
    LDA $B0
    AND #$01                    ; negative?
    BNE dpSqrt_nan
    LDA $B0
    AND #$02                    ; underflow → zero
    BNE dpSqrt_zero
    LDA $B0
    AND #$10                    ; zero flag → zero
    BNE dpSqrt_zero

    ; --- Exponent preparation ---
    ; Save parity of E, then compute halved E via arithmetic shift
    ; right (same CMP #$80 / ROR trick fpSqrt uses).
    LDA $B1
    AND #$01
    STA _dpSqrt_parity
    LDA $B1
    CMP #$80
    ROR A
    STA $B1

    ; --- Build D = M << 14 in _dpSqrt_D (8 bytes, MSByte first) ---
    ; M has bit 48 = implicit 1, bits 47..0 in $B2..$B7. D[0] gets
    ; the implicit 1 as bit 6 (= bit 62 of D), plus mantissa bits
    ; 47..42 as bits 5..0. D[1..5] pack each 8 mantissa bits.
    ; D[6] bits 7..6 = mantissa bits 1..0, rest 0. D[7] = 0.
    ;
    ; Per-byte formula (read top-down):
    ;   D[0] = ($B2 >> 2) | $40
    ;   D[1] = ($B2 << 6) | ($B3 >> 2)
    ;   D[2] = ($B3 << 6) | ($B4 >> 2)
    ;   D[3] = ($B4 << 6) | ($B5 >> 2)
    ;   D[4] = ($B5 << 6) | ($B6 >> 2)
    ;   D[5] = ($B6 << 6) | ($B7 >> 2)
    ;   D[6] = ($B7 << 6)
    ;   D[7] = 0

    LDA $B2
    LSR A
    LSR A
    ORA #$40
    STA _dpSqrt_D+0

    LDA $B2 : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA _dpSqrt_D+1
    LDA $B3 : LSR A : LSR A : ORA _dpSqrt_D+1 : STA _dpSqrt_D+1

    LDA $B3 : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA _dpSqrt_D+2
    LDA $B4 : LSR A : LSR A : ORA _dpSqrt_D+2 : STA _dpSqrt_D+2

    LDA $B4 : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA _dpSqrt_D+3
    LDA $B5 : LSR A : LSR A : ORA _dpSqrt_D+3 : STA _dpSqrt_D+3

    LDA $B5 : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA _dpSqrt_D+4
    LDA $B6 : LSR A : LSR A : ORA _dpSqrt_D+4 : STA _dpSqrt_D+4

    LDA $B6 : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA _dpSqrt_D+5
    LDA $B7 : LSR A : LSR A : ORA _dpSqrt_D+5 : STA _dpSqrt_D+5

    LDA $B7 : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA _dpSqrt_D+6

    LDA #$00
    STA _dpSqrt_D+7

    ; If E was odd, multiply D by 2 so the leading 1 lands at bit 63.
    LDA _dpSqrt_parity
    BEQ dpSqrt_even_exp
    ASL _dpSqrt_D+7
    ROL _dpSqrt_D+6
    ROL _dpSqrt_D+5
    ROL _dpSqrt_D+4
    ROL _dpSqrt_D+3
    ROL _dpSqrt_D+2
    ROL _dpSqrt_D+1
    ROL _dpSqrt_D+0
dpSqrt_even_exp:

    ; --- Initialise Q ($B2..$B7 = 0, _dpSqrt_Qhi = 0) and R ($B8..$BF = 0) ---
    LDA #$00
    STA $B2
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    STA _dpSqrt_Qhi
    STA $B8
    STA $B9
    STA $BA
    STA $BB
    STA $BC
    STA $BD
    STA $BE
    STA $BF

    ; --- 49 iterations of bit-by-bit sqrt ---
    LDX #49
dpSqrt_loop:
    ; Shift (R:D) left by 2 bits.  D low-to-high then R low-to-high:
    ;   ASL D[7], ROL D[6..0], ROL R[low=$BF], ROL R[up to $B8]
    ASL _dpSqrt_D+7
    ROL _dpSqrt_D+6
    ROL _dpSqrt_D+5
    ROL _dpSqrt_D+4
    ROL _dpSqrt_D+3
    ROL _dpSqrt_D+2
    ROL _dpSqrt_D+1
    ROL _dpSqrt_D+0
    ROL $BF
    ROL $BE
    ROL $BD
    ROL $BC
    ROL $BB
    ROL $BA
    ROL $B9
    ROL $B8

    ASL _dpSqrt_D+7
    ROL _dpSqrt_D+6
    ROL _dpSqrt_D+5
    ROL _dpSqrt_D+4
    ROL _dpSqrt_D+3
    ROL _dpSqrt_D+2
    ROL _dpSqrt_D+1
    ROL _dpSqrt_D+0
    ROL $BF
    ROL $BE
    ROL $BD
    ROL $BC
    ROL $BB
    ROL $BA
    ROL $B9
    ROL $B8

    ; --- Precompute trial = (Q << 2) | 1 into _dpSqrt_trial[0..6] ---
    ; Q stored as Qhi (bit 48 in bit 0) + $B2..$B7 (bits 47..0, $B2
    ; is MSByte). Trial is little-endian, 7 bytes.
    LDA $B7 : ASL A : ASL A : ORA #$01 : STA _dpSqrt_trial+0

    LDA $B7 : LSR A : LSR A : LSR A : LSR A : LSR A : LSR A : STA _dpSqrt_trial+1
    LDA $B6 : ASL A : ASL A : ORA _dpSqrt_trial+1 : STA _dpSqrt_trial+1

    LDA $B6 : LSR A : LSR A : LSR A : LSR A : LSR A : LSR A : STA _dpSqrt_trial+2
    LDA $B5 : ASL A : ASL A : ORA _dpSqrt_trial+2 : STA _dpSqrt_trial+2

    LDA $B5 : LSR A : LSR A : LSR A : LSR A : LSR A : LSR A : STA _dpSqrt_trial+3
    LDA $B4 : ASL A : ASL A : ORA _dpSqrt_trial+3 : STA _dpSqrt_trial+3

    LDA $B4 : LSR A : LSR A : LSR A : LSR A : LSR A : LSR A : STA _dpSqrt_trial+4
    LDA $B3 : ASL A : ASL A : ORA _dpSqrt_trial+4 : STA _dpSqrt_trial+4

    LDA $B3 : LSR A : LSR A : LSR A : LSR A : LSR A : LSR A : STA _dpSqrt_trial+5
    LDA $B2 : ASL A : ASL A : ORA _dpSqrt_trial+5 : STA _dpSqrt_trial+5

    LDA $B2 : LSR A : LSR A : LSR A : LSR A : LSR A : LSR A : STA _dpSqrt_trial+6

    ; --- Subtract trial from R into _dpSqrt_newR (MSByte first) ---
    ; newR[0] corresponds to $B8 (MSByte of R); newR[7] to $BF.
    SEC
    LDA $BF : SBC _dpSqrt_trial+0 : STA _dpSqrt_newR+7
    LDA $BE : SBC _dpSqrt_trial+1 : STA _dpSqrt_newR+6
    LDA $BD : SBC _dpSqrt_trial+2 : STA _dpSqrt_newR+5
    LDA $BC : SBC _dpSqrt_trial+3 : STA _dpSqrt_newR+4
    LDA $BB : SBC _dpSqrt_trial+4 : STA _dpSqrt_newR+3
    LDA $BA : SBC _dpSqrt_trial+5 : STA _dpSqrt_newR+2
    LDA $B9 : SBC _dpSqrt_trial+6 : STA _dpSqrt_newR+1
    LDA $B8 : SBC #$00            : STA _dpSqrt_newR+0

    BCC dpSqrt_no_sub

    ; Commit: copy newR back into R.
    LDA _dpSqrt_newR+0 : STA $B8
    LDA _dpSqrt_newR+1 : STA $B9
    LDA _dpSqrt_newR+2 : STA $BA
    LDA _dpSqrt_newR+3 : STA $BB
    LDA _dpSqrt_newR+4 : STA $BC
    LDA _dpSqrt_newR+5 : STA $BD
    LDA _dpSqrt_newR+6 : STA $BE
    LDA _dpSqrt_newR+7 : STA $BF

    ; Shift Q left by 1 and set bit 0. Q is 49-bit:
    ;   $B7 = LSByte of bits 47..0, $B2 = MSByte of bits 47..0,
    ;   Qhi  = bit 48 (in bit 0).
    ASL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    ROL _dpSqrt_Qhi
    INC $B7
    JMP dpSqrt_next

dpSqrt_no_sub:
    ; No commit; Q bit stays 0. Shift Q left by 1 without setting
    ; bit 0.
    ASL $B7
    ROL $B6
    ROL $B5
    ROL $B4
    ROL $B3
    ROL $B2
    ROL _dpSqrt_Qhi

dpSqrt_next:
    DEX
    BNE dpSqrt_loop

    ; --- Round-to-nearest using the leftover remainder ---
    ; The loop produces Q = floor(sqrt(D')) and R = D' - Q^2. Next
    ; bit (half-ULP at the format level) is 1 iff R > Q. Compare R
    ; (8 bytes at $B8..$BF, MSByte first) against Q (virtual 8-byte
    ; MSByte-first value: {$00, Qhi, $B2, $B3, $B4, $B5, $B6, $B7}).
    ; Q's top byte is always 0 (Q ≤ 2^49), so R > Q iff R's top byte
    ; is nonzero OR the remaining 7 bytes of R lex-exceed Q's 7 bytes.
    LDA $B8
    BNE dpSqrt_round_up         ; R[0] > 0 ⇒ R > Q
    LDA $B9
    CMP _dpSqrt_Qhi
    BCC dpSqrt_round_done
    BNE dpSqrt_round_up
    LDA $BA
    CMP $B2
    BCC dpSqrt_round_done
    BNE dpSqrt_round_up
    LDA $BB
    CMP $B3
    BCC dpSqrt_round_done
    BNE dpSqrt_round_up
    LDA $BC
    CMP $B4
    BCC dpSqrt_round_done
    BNE dpSqrt_round_up
    LDA $BD
    CMP $B5
    BCC dpSqrt_round_done
    BNE dpSqrt_round_up
    LDA $BE
    CMP $B6
    BCC dpSqrt_round_done
    BNE dpSqrt_round_up
    LDA $BF
    CMP $B7
    BCC dpSqrt_round_done
    BEQ dpSqrt_round_done       ; equal ⇒ no round
    ; fall through: R > Q

dpSqrt_round_up:
    INC $B7
    BNE dpSqrt_round_done
    INC $B6
    BNE dpSqrt_round_done
    INC $B5
    BNE dpSqrt_round_done
    INC $B4
    BNE dpSqrt_round_done
    INC $B3
    BNE dpSqrt_round_done
    INC $B2
    BNE dpSqrt_round_done
    INC _dpSqrt_Qhi
    LDA _dpSqrt_Qhi
    CMP #$02
    BCC dpSqrt_round_done
    ; Q overflowed past 2^49: sqrt rounded up to the next power of
    ; 2. Collapse Q to 1.0 (Qhi=1, $B2..$B7=0) and bump exponent.
    LDA #$01
    STA _dpSqrt_Qhi
    LDA #$00
    STA $B2
    STA $B3
    STA $B4
    STA $B5
    STA $B6
    STA $B7
    INC $B1

dpSqrt_round_done:
    ; Q is already in format-1 mantissa form: bit 48 = implicit
    ; leading 1 (in Qhi, not stored), bits 47..0 of Q in $B2..$B7
    ; are the output mantissa. Clear flags.
    LDA #$00
    STA $B0
    RTS

dpSqrt_nan:
    LDA #$08
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

dpSqrt_zero:
    LDA #$10
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


_dpSqrt_Qhi:    .byte $00
_dpSqrt_parity: .byte $00
_dpSqrt_D:      .byte $00, $00, $00, $00, $00, $00, $00, $00
_dpSqrt_trial:  .byte $00, $00, $00, $00, $00, $00, $00
_dpSqrt_newR:   .byte $00, $00, $00, $00, $00, $00, $00, $00
