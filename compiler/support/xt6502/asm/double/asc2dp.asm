; asc2dp — parse an ATASCII text string into an 8-byte double
; Input:  $B5,$B6 = pointer to a null-terminated ATASCII string
; Output: $B0-$B7 = parsed double (zero-flagged on unparseable input)
;
; Grammar: [+|-]? digit+ ('.' digit*)? ([eE] [+|-]? digit+)?
;          plus case-insensitive "inf" and "nan" tokens.
;
; Mirrors asc2fp at double precision. The parsing stage accumulates
; every decimal digit (integer and fractional) into a 48-bit integer
; and counts the decimal-place shift in a signed scale byte; at the
; end, the integer is normalised into a double in $B0-$B7 and then
; scaled by 10^±N via iterative dpMul / dpDiv against a 10.0
; constant in $B8-$BF.
;
; 48 bits of integer accumulator = ~14.4 decimal digits of parsing
; precision. Inputs longer than 14 digits silently wrap in the
; accumulator; that matches what dp's 48-bit mantissa can represent
; anyway (so no information is lost versus a wider accumulator
; followed by rounding).
;
; Storage:
;   ZP ($B0-$BF — all inside the reserved runtime region):
;     $B0-$B7   result double (also scratch while parsing)
;     $B8-$BF   op2 buffer for dpMul / dpDiv (the 10.0 constant)
;     X         sign flag (0 = positive, 1 = negative)
;     Y         byte offset into the input string
;   Data-section scratch:
;     _asc2dp_ptr    2 bytes  saved input pointer ($B5,$B6 copy —
;                             the pointer ZP gets reused for dp ops
;                             during scaling)
;     _asc2dp_acc    6 bytes  48-bit integer accumulator, big-endian
;                             (acc[0] = top byte so normalisation
;                             can BMI on acc[0] just like asc2fp)
;     _asc2dp_scale  1 byte   signed: +N means divide by 10^N,
;                             −N means multiply by 10^|N|
;
; Requires: dpMul, dpDiv (linked automatically via the JSR scan).

asc2dp:
    ; Save input pointer — $B5,$B6 gets clobbered later.
    LDA $B5
    STA _asc2dp_ptr
    LDA $B6
    STA _asc2dp_ptr+1

    ; Zero the accumulator and scale.
    LDA #$00
    STA _asc2dp_acc
    STA _asc2dp_acc+1
    STA _asc2dp_acc+2
    STA _asc2dp_acc+3
    STA _asc2dp_acc+4
    STA _asc2dp_acc+5
    STA _asc2dp_scale

    LDX #$00                    ; sign = positive
    LDY #$00

    ; --- Optional leading sign ---
    LDA (_asc2dp_ptr),Y
    CMP #$2D                    ; '-'
    BNE .a2dp_not_neg
    LDX #$01
    INY
    JMP .a2dp_parse_int
.a2dp_not_neg:
    CMP #$2B                    ; '+'
    BNE .a2dp_parse_int
    INY

.a2dp_parse_int:
    LDA (_asc2dp_ptr),Y
    BEQ .a2dp_convert
    CMP #$69                    ; 'i'
    BEQ .a2dp_check_inf
    CMP #$49                    ; 'I'
    BEQ .a2dp_check_inf
    CMP #$6E                    ; 'n'
    BEQ .a2dp_check_nan
    CMP #$4E                    ; 'N'
    BEQ .a2dp_check_nan
    CMP #$2E                    ; '.'
    BEQ .a2dp_seen_dot
    CMP #$65                    ; 'e'
    BEQ .a2dp_parse_exp
    CMP #$45                    ; 'E'
    BEQ .a2dp_parse_exp
    CMP #$30                    ; '0'
    BCC .a2dp_convert
    CMP #$3A                    ; ':' (one past '9')
    BCS .a2dp_convert
    SEC
    SBC #$30
    PHA
    JSR .a2dp_mul10
    PLA
    CLC
    ADC _asc2dp_acc+5           ; low byte of accumulator
    STA _asc2dp_acc+5
    LDA #$00
    ADC _asc2dp_acc+4
    STA _asc2dp_acc+4
    LDA #$00
    ADC _asc2dp_acc+3
    STA _asc2dp_acc+3
    LDA #$00
    ADC _asc2dp_acc+2
    STA _asc2dp_acc+2
    LDA #$00
    ADC _asc2dp_acc+1
    STA _asc2dp_acc+1
    LDA #$00
    ADC _asc2dp_acc
    STA _asc2dp_acc
    INY
    JMP .a2dp_parse_int

.a2dp_seen_dot:
    INY
.a2dp_parse_frac:
    LDA (_asc2dp_ptr),Y
    BEQ .a2dp_convert
    CMP #$65
    BEQ .a2dp_parse_exp
    CMP #$45
    BEQ .a2dp_parse_exp
    CMP #$30
    BCC .a2dp_convert
    CMP #$3A
    BCS .a2dp_convert
    SEC
    SBC #$30
    PHA
    JSR .a2dp_mul10
    PLA
    CLC
    ADC _asc2dp_acc+5
    STA _asc2dp_acc+5
    LDA #$00
    ADC _asc2dp_acc+4
    STA _asc2dp_acc+4
    LDA #$00
    ADC _asc2dp_acc+3
    STA _asc2dp_acc+3
    LDA #$00
    ADC _asc2dp_acc+2
    STA _asc2dp_acc+2
    LDA #$00
    ADC _asc2dp_acc+1
    STA _asc2dp_acc+1
    LDA #$00
    ADC _asc2dp_acc
    STA _asc2dp_acc
    INC _asc2dp_scale           ; each fractional digit bumps scale
    INY
    JMP .a2dp_parse_frac

.a2dp_parse_exp:
    INY
    LDA #$00
    PHA                         ; exp_sign = 0 on stack
    LDA (_asc2dp_ptr),Y
    CMP #$2D
    BNE .a2dp_exp_plus
    PLA
    LDA #$01
    PHA                         ; exp_sign = 1
    INY
    JMP .a2dp_exp_start
.a2dp_exp_plus:
    CMP #$2B
    BNE .a2dp_exp_start
    INY

.a2dp_exp_start:
    LDA #$00
    PHA                         ; exp_acc = 0, pushed on top of exp_sign
.a2dp_exp_digit:
    LDA (_asc2dp_ptr),Y
    BEQ .a2dp_exp_done
    CMP #$30
    BCC .a2dp_exp_done
    CMP #$3A
    BCS .a2dp_exp_done
    SEC
    SBC #$30
    STA $B0                     ; stash digit; $B0 isn't final flag yet
    PLA                         ; previous exp_acc
    STA $B1                     ; copy for 5x = 4x+x step
    ASL A
    ASL A                       ; 4x
    CLC
    ADC $B1                     ; 5x
    ASL A                       ; 10x
    CLC
    ADC $B0                     ; 10x + digit
    PHA
    INY
    JMP .a2dp_exp_digit

.a2dp_exp_done:
    PLA                         ; exp_acc
    STA $B0
    PLA                         ; exp_sign
    BEQ .a2dp_exp_pos
    ; Negative: more divisions at the end.
    LDA _asc2dp_scale
    CLC
    ADC $B0
    STA _asc2dp_scale
    JMP .a2dp_convert
.a2dp_exp_pos:
    LDA _asc2dp_scale
    SEC
    SBC $B0
    STA _asc2dp_scale

.a2dp_convert:
    ; All-zero accumulator → return zero-flagged double regardless
    ; of sign or scale.
    LDA _asc2dp_acc
    ORA _asc2dp_acc+1
    ORA _asc2dp_acc+2
    ORA _asc2dp_acc+3
    ORA _asc2dp_acc+4
    ORA _asc2dp_acc+5
    BNE .a2dp_nonzero
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

.a2dp_nonzero:
    ; Stash sign in $B0 for later (X will be repurposed as the
    ; exponent counter during normalise).
    STX $B0

    ; Normalise acc until bit 47 (= bit 7 of acc[0]) is set. X
    ; tracks the exponent: starts at 47 and decreases for each
    ; left shift.
    LDX #47
.a2dp_norm_loop:
    LDA _asc2dp_acc
    BMI .a2dp_norm_done
    ASL _asc2dp_acc+5
    ROL _asc2dp_acc+4
    ROL _asc2dp_acc+3
    ROL _asc2dp_acc+2
    ROL _asc2dp_acc+1
    ROL _asc2dp_acc
    DEX
    JMP .a2dp_norm_loop
.a2dp_norm_done:
    ; One more shift drops the implicit leading 1 off the top,
    ; leaving a 48-bit fractional mantissa in acc[0..5].
    ASL _asc2dp_acc+5
    ROL _asc2dp_acc+4
    ROL _asc2dp_acc+3
    ROL _asc2dp_acc+2
    ROL _asc2dp_acc+1
    ROL _asc2dp_acc

    ; Store mantissa big-endian into $B2..$B7.
    LDA _asc2dp_acc   : STA $B2
    LDA _asc2dp_acc+1 : STA $B3
    LDA _asc2dp_acc+2 : STA $B4
    LDA _asc2dp_acc+3 : STA $B5
    LDA _asc2dp_acc+4 : STA $B6
    LDA _asc2dp_acc+5 : STA $B7

    TXA
    STA $B1                     ; exponent

    LDA $B0
    AND #$01
    STA $B0                     ; sign bit → flag byte

    ; --- Scale by 10^(-scale) via iterative dpMul / dpDiv ---
.a2dp_scale:
    LDA _asc2dp_scale
    BEQ .a2dp_done
    BMI .a2dp_scale_mul
    ; Positive scale → divide by 10.
    JSR .a2dp_load_ten
    JSR dpDiv
    DEC _asc2dp_scale
    JMP .a2dp_scale
.a2dp_scale_mul:
    ; Negative scale → multiply by 10.
    JSR .a2dp_load_ten
    JSR dpMul
    INC _asc2dp_scale
    JMP .a2dp_scale

.a2dp_done:
    RTS

; --- Load the 10.0 constant into $B8..$BF (dpMul / dpDiv op2). ---
; 10.0 = 1.25 * 2^3. Flags=0, exp=3, mantissa top byte $40, rest 0.
.a2dp_load_ten:
    LDA #$00 : STA $B8
    LDA #$03 : STA $B9
    LDA #$40 : STA $BA
    LDA #$00
    STA $BB
    STA $BC
    STA $BD
    STA $BE
    STA $BF
    RTS

; --- Recognise "inf" / "nan" (case-insensitive) ---
.a2dp_check_inf:
    INY
    LDA (_asc2dp_ptr),Y
    ORA #$20
    CMP #$6E
    BNE .a2dp_convert
    INY
    LDA (_asc2dp_ptr),Y
    ORA #$20
    CMP #$66
    BNE .a2dp_convert
    TXA                         ; X = sign
    ORA #$20                    ; infinity flag
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

.a2dp_check_nan:
    INY
    LDA (_asc2dp_ptr),Y
    ORA #$20
    CMP #$61
    BNE .a2dp_convert
    INY
    LDA (_asc2dp_ptr),Y
    ORA #$20
    CMP #$6E
    BNE .a2dp_convert
    LDA #$08                    ; NaN flag
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

; --- acc *= 10, low 48 bits only (silent overflow, matching asc2fp's
; --- 24-bit counterpart). 10x = 8x + 2x: compute 2x in place, save
; --- to stack, double twice more (= 8x), pop 2x back and add.
.a2dp_mul10:
    ; acc = 2x  (ASL/ROL from low → high since acc is big-endian,
    ; LSB at acc+5 and MSB at acc[0]).
    ASL _asc2dp_acc+5
    ROL _asc2dp_acc+4
    ROL _asc2dp_acc+3
    ROL _asc2dp_acc+2
    ROL _asc2dp_acc+1
    ROL _asc2dp_acc
    ; Save 2x on the hardware stack (push hi first so PLA pulls lo first).
    LDA _asc2dp_acc   : PHA
    LDA _asc2dp_acc+1 : PHA
    LDA _asc2dp_acc+2 : PHA
    LDA _asc2dp_acc+3 : PHA
    LDA _asc2dp_acc+4 : PHA
    LDA _asc2dp_acc+5 : PHA
    ; acc *= 4 (now 8x total)
    ASL _asc2dp_acc+5
    ROL _asc2dp_acc+4
    ROL _asc2dp_acc+3
    ROL _asc2dp_acc+2
    ROL _asc2dp_acc+1
    ROL _asc2dp_acc
    ASL _asc2dp_acc+5
    ROL _asc2dp_acc+4
    ROL _asc2dp_acc+3
    ROL _asc2dp_acc+2
    ROL _asc2dp_acc+1
    ROL _asc2dp_acc
    ; Add saved 2x back (PLA in LIFO order, lo first).
    CLC
    PLA : ADC _asc2dp_acc+5 : STA _asc2dp_acc+5
    PLA : ADC _asc2dp_acc+4 : STA _asc2dp_acc+4
    PLA : ADC _asc2dp_acc+3 : STA _asc2dp_acc+3
    PLA : ADC _asc2dp_acc+2 : STA _asc2dp_acc+2
    PLA : ADC _asc2dp_acc+1 : STA _asc2dp_acc+1
    PLA : ADC _asc2dp_acc   : STA _asc2dp_acc
    RTS


_asc2dp_ptr:   .byte $00, $00
_asc2dp_acc:   .byte $00, $00, $00, $00, $00, $00
_asc2dp_scale: .byte $00
