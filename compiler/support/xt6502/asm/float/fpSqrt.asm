; fpSqrt — square root of a 5-byte float
; Input:  $B0-$B4 = operand (float)
; Output: $B0-$B4 = sqrt(operand) (float)
;
; Float format: byte 0 bit 0=sign, bit 1=underflow, bit 2=overflow,
;               bit 3=NaN, bit 4=zero
;               byte 1 = signed exponent (int8)
;               bytes 2-4 = 24-bit mantissa (implicit leading 1)
;
; Algorithm
; ─────────
; For input (1 + f/2^24) * 2^E, let M = 2^24 + f (a 25-bit integer
; with bit 24 = 1) and write the true value as M * 2^(E-24). Then
;
;     sqrt(value) = sqrt(M) * 2^((E-24)/2)
;
; When (E-24) is odd we can't produce a half-integer exponent, so we
; rewrite it as sqrt(2*M) * 2^((E-25)/2) and run the sqrt on 2M.
;
; We scale M (or 2M) up by 2^6 and feed it through a 24-iteration
; bit-by-bit integer sqrt on a 32-bit radicand D, which produces
; Q = floor(sqrt(D * 2^16)) — i.e. floor(sqrt(M * 2^22)) for even E
; or floor(sqrt(M * 2^23)) for odd E. In both cases Q ends up in
; [2^23, 2^24), so Q's bit 23 is set — exactly the "normalised with
; implicit leading 1 at bit 23" form we need.
;
; Final conversion to format 1:
;     mantissa_f1 = (Q << 1) & 2^24 - 1   ; drop the leading 1, shift up
;     exp_f1      = floor(E/2)            ; same for even and odd parity
;
; (The old routine used `AND #$7F` to "strip the leading 1", which
; only gave the right answer for perfect squares of powers of two —
; it effectively halved the mantissa contribution. And its inner
; loop used trial = 2*Q+1 instead of the correct 4*Q+1, so the
; quotient was wrong even before the repack. Both bugs are fixed
; below.)
;
; The bit-by-bit sqrt iteration, in pseudocode:
;
;     Q = 0; R = 0
;     for i = 1..24:
;         shift (R:D) left by 2 bits
;         trial = (Q << 2) | 1                   ; 4*Q + 1
;         if R >= trial:
;             R -= trial
;             Q = (Q << 1) | 1
;         else:
;             Q = Q << 1
;
; Storage layout ($B0-$BF, all inside the reserved runtime region):
;   $B0:      final flags byte (= 0 on success, $10 for zero result)
;   $B1:      halved signed exponent (computed on entry, final output)
;   $B2-$B4:  Q, the 24-bit quotient (final output mantissa after shift)
;   $B5-$B8:  D, the 32-bit radicand (shifts left as bits feed into R)
;   $B9-$BC:  R, the 32-bit remainder (accumulates leftover radicand bits)
;   $BD:      parity flag (bit 0 = 1 iff original exponent was odd)
;   $BE-$BF:  trial-subtract scratch (used byte-by-byte)
; X register is the loop counter.

fpSqrt:
    ; --- Special cases ---
    LDA $B0
    AND #$28            ; NaN (bit 3) or infinity (bit 5) → NaN
    BNE .ret_nan
    LDA $B0
    AND #$01            ; negative?
    BNE .ret_nan
    LDA $B0
    AND #$02            ; underflow → zero
    BNE .ret_zero
    LDA $B0
    AND #$10            ; zero flag → zero
    BNE .ret_zero

    ; --- Exponent preparation ---
    ; Save parity of E (for the "odd exponent → shift D left one more"
    ; adjustment), then compute halved E via arithmetic shift right.
    LDA $B1
    AND #$01
    STA $BD             ; parity
    LDA $B1
    CMP #$80            ; set carry if E is negative
    ROR A               ; ASR: sign bit back into bit 7, bit 0 → C
    STA $B1             ; final halved exponent (stays in $B1)

    ; --- Build the 32-bit radicand D in $B5..$B8 ---
    ; Goal for even parity: D = M << 6 = (1<<30) | (mantissa << 6).
    ; That places the implicit leading 1 at bit 30 of D and the 24
    ; stored fraction bits below it, bits 5..0 zero.
    ;
    ; $B5 byte layout (even): 0 1 m23 m22 m21 m20 m19 m18
    ; $B6:                    m17..m10
    ; $B7:                    m9..m2
    ; $B8:                    m1 m0  0  0  0  0  0  0

    LDA $B2
    LSR A
    LSR A
    ORA #$40            ; set bit 30 (= $B5 bit 6) to be the implicit 1
    STA $B5
    LDA $B2
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A               ; mantissa hi bits 1..0 now in bits 7..6
    STA $B6
    LDA $B3
    LSR A
    LSR A               ; mantissa mid bits 7..2 in bits 5..0
    ORA $B6
    STA $B6

    LDA $B3
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    STA $B7
    LDA $B4
    LSR A
    LSR A
    ORA $B7
    STA $B7

    LDA $B4
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    STA $B8

    ; If E was odd, multiply D by 2 so the leading 1 lands at bit 31
    ; and the final Q absorbs an extra factor of sqrt(2). Read the
    ; parity flag out of $BD into Y first so we can immediately reuse
    ; $BD as the high byte of the 25-bit quotient Q below.
    LDY $BD
    CPY #$00
    BEQ .even_exp
    ASL $B8
    ROL $B7
    ROL $B6
    ROL $B5
.even_exp:

    ; --- Initialise Q (in $BD,$B2,$B3,$B4) and R (in $B9-$BC) to 0 ---
    ; Q is now a 25-bit value: $BD bit 0 holds Q bit 24 (the implicit
    ; leading 1, which iter 25 sets), $B2..$B4 hold Q bits 23..0 (the
    ; format's stored mantissa). Going to 25 iterations and 4-byte Q
    ; gives the format's full 24 stored bits of fractional precision,
    ; up from the 23 the previous 24-iter / 3-byte Q produced.
    LDA #$00
    STA $B2
    STA $B3
    STA $B4
    STA $BD
    STA $B9
    STA $BA
    STA $BB
    STA $BC

    ; --- 25 iterations of bit-by-bit sqrt ---
    LDX #25
.sqrt_loop:
    ; Shift (R:D) left by 2 bits. Bits flowing out the top of D ($B5)
    ; enter the bottom of R ($BC). The sequence is two 1-bit shifts:
    ; ASL D_low, ROL D bytes up, ROL R bytes up (from low to high).
    ASL $B8
    ROL $B7
    ROL $B6
    ROL $B5
    ROL $BC
    ROL $BB
    ROL $BA
    ROL $B9
    ASL $B8
    ROL $B7
    ROL $B6
    ROL $B5
    ROL $BC
    ROL $BB
    ROL $BA
    ROL $B9

    ; Compute trial = (Q << 2) | 1 on the fly and subtract byte-by-byte
    ; from R ($B9 high .. $BC low). Trial bytes, from low to high:
    ;
    ;   t_byte0 = ((Q_lo << 2) & $FF) | 1
    ;   t_byte1 = (Q_lo >> 6) | ((Q_mid << 2) & $FF)
    ;   t_byte2 = (Q_mid >> 6) | ((Q_hi << 2) & $FF)
    ;   t_byte3 = Q_hi >> 6
    ;
    ; The trial-byte math uses LSR/ASL which clobber the carry flag,
    ; so we can't rely on SBC's natural carry chain. Instead, save the
    ; carry after each SBC with PHP and restore it with PLP right
    ; before the next SBC.
    ;
    ; The new tentative R byte for $BC lands in $BF; new $BB/$BA bytes
    ; are pushed to the 6502 stack; new $B9 ends up in A at the final
    ; SBC. On commit we pull them back; on skip we PLA/PLA to discard.

    ; t_byte0 in $BE = (Q_lo << 2) | 1
    LDA $B4
    ASL A
    ASL A
    ORA #$01
    STA $BE
    SEC
    LDA $BC
    SBC $BE
    STA $BF             ; tentative new R_lo
    PHP                 ; save carry

    ; t_byte1 in $BE = (Q_lo >> 6) | (Q_mid << 2)
    LDA $B4
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    STA $BE
    LDA $B3
    ASL A
    ASL A
    ORA $BE
    STA $BE
    PLP                 ; restore carry from the previous SBC
    LDA $BB
    SBC $BE
    PHA                 ; tentative new R byte 1 on stack
    PHP

    ; t_byte2 in $BE = (Q_mid >> 6) | (Q_hi << 2)
    LDA $B3
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    STA $BE
    LDA $B2
    ASL A
    ASL A
    ORA $BE
    STA $BE
    PLP
    LDA $BA
    SBC $BE
    PHA                 ; tentative new R byte 2 on stack
    PHP

    ; t_byte3 in $BE = Q_hi >> 6
    LDA $B2
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    STA $BE
    PLP
    LDA $B9
    SBC $BE

    ; Final carry tells us R >= trial iff set. If clear, skip the sub.
    BCC .sqrt_no_sub

    ; Commit: A already holds the new $B9; pop the stacked bytes into
    ; $BA and $BB; $BF holds the new $BC.
    STA $B9
    PLA
    STA $BA
    PLA
    STA $BB
    LDA $BF
    STA $BC

    ; Quotient bit = 1: shift Q left by 1 and set bit 0. Q is now a
    ; 4-byte value ($BD = bit 24 high byte) so the shift propagates
    ; through $BD as well.
    ASL $B4
    ROL $B3
    ROL $B2
    ROL $BD
    INC $B4
    JMP .sqrt_next

.sqrt_no_sub:
    ; Drop the two tentative bytes off the stack; Q bit = 0.
    PLA
    PLA
    ASL $B4
    ROL $B3
    ROL $B2
    ROL $BD

.sqrt_next:
    DEX
    BNE .sqrt_loop

    ; --- Round-to-nearest using the leftover remainder ---
    ; The bit-by-bit loop produces Q = floor(sqrt(D')) and R = D' - Q^2,
    ; with Q a 25-bit value (bit 24 in $BD bit 0, bits 23..0 in
    ; $B2..$B4) and R a 32-bit value in $B9..$BC. The next sqrt bit
    ; (the half-ULP position at the format level, which we don't
    ; compute) is 1 iff the midpoint (Q + 0.5)^2 ≤ D'. Expanding:
    ; Q^2 + Q + 0.25 ≤ D' ⇔ R > Q (in integers, since 2R ≥ 2Q+1 and
    ; parity makes 2R = 2Q+1 impossible). When that holds, round Q up
    ; by 1.
    ;
    ; Compare R (4 bytes, big-endian in $B9..$BC) against Q (4 bytes
    ; with the high byte in $BD). Pairing:
    ;   R[0]=$B9 vs Q[0]=$BD   (Q's high byte: 0 or 1)
    ;   R[1]=$BA vs Q[1]=$B2
    ;   R[2]=$BB vs Q[2]=$B3
    ;   R[3]=$BC vs Q[3]=$B4
    LDA $B9
    CMP $BD
    BCC .sqrt_round_done      ; R[0] < $BD ⇒ R < Q
    BNE .sqrt_round_up        ; R[0] > $BD ⇒ R > Q
    LDA $BA
    CMP $B2
    BCC .sqrt_round_done
    BNE .sqrt_round_up
    LDA $BB
    CMP $B3
    BCC .sqrt_round_done
    BNE .sqrt_round_up
    LDA $BC
    CMP $B4
    BCC .sqrt_round_done
    BEQ .sqrt_round_done      ; equal ⇒ no round
    ; fall through: R > Q

.sqrt_round_up:
    INC $B4
    BNE .sqrt_round_done
    INC $B3
    BNE .sqrt_round_done
    INC $B2
    BNE .sqrt_round_done
    INC $BD
    LDA $BD
    CMP #$02
    BCC .sqrt_round_done
    ; Q overflowed past 2^25. The true sqrt has rounded up to the
    ; next power of 2: collapse Q to the encoding of 1.0 — implicit
    ; leading bit only ($BD = $01, mantissa $00,$00,$00) — and bump
    ; the exponent.
    LDA #$01
    STA $BD
    LDA #$00
    STA $B2
    STA $B3
    STA $B4
    INC $B1

.sqrt_round_done:
    ; Q is already in the format-1 mantissa form: bit 24 = implicit
    ; leading 1 (in $BD bit 0, not stored in the output), bits 23..0
    ; of Q in $B2..$B4 are the 24-bit stored mantissa, which is
    ; exactly what the output format wants. No shift / exponent
    ; correction needed (the previous 24-iter routine had to ASL the
    ; mantissa to drop the leading bit and DEC the exponent; the
    ; 25-iter form skips both because the leading bit was already
    ; computed into the dedicated $BD byte).

    ; Clear output flags (sign always positive for sqrt, no special).
    LDA #$00
    STA $B0
    RTS

.ret_nan:
    LDA #$08
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS

.ret_zero:
    LDA #$10            ; zero flag
    STA $B0
    LDA #$00
    STA $B1
    STA $B2
    STA $B3
    STA $B4
    RTS
