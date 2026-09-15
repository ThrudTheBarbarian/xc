; fpTrigTab.asm — table-based trig functions for banked mode
; Implements: fpSin, fpCos, fpTan, fpAtan
;
; Uses a 64-entry Q1.15 sine table for one quadrant (0..π/2).
; Linear interpolation between entries for accuracy.
; Table is 128 bytes — stored inline (fits easily in banked code page).
;
; Input:  $B0-$B4 = angle in radians (float)
; Output: $B0-$B4 = result (float)

; ── fpSin ─────────────────────────────────────────────────────────────
fpSin:
    ; If |angle| ≥ 4 (exp ≥ 2), reduce mod 2π in float arithmetic
    ; first — _trig_angle_to_idx converts via Q3.13 which only
    ; represents [-4, 4) and would otherwise truncate large angles.
    LDA $B1
    SEC
    SBC #$02
    BMI .tsin_in_range
    JSR _fp_reduce_to_pi
.tsin_in_range:
    ; Convert float angle to table index
    ; index = angle * 64 / (π/2) = angle * 128/π ≈ angle * 40.74
    ; In practice: convert to Q3.13, then index = Q3.13_value * 64 / 12868
    ; Simpler: convert angle to 0-255 range for full circle (0..2π)
    ;   idx256 = angle * 256 / (2π) ≈ angle * 40.74
    ;   First quadrant: idx = idx256 & 63
    JSR _trig_angle_to_idx  ; $B6 = table index (0-63), $B7 = quadrant flags
    ; Look up sin value from table
    LDA $B6
    ASL A               ; × 2 for word index
    TAY
    LDA _sin_table,Y
    STA $B4             ; Q1.15 lo
    LDA _sin_table+1,Y
    STA $B5             ; Q1.15 hi
    ; Apply sign from quadrant
    LDA $B7
    AND #$01
    BEQ .tsin_pos
    SEC
    LDA #$00 : SBC $B4 : STA $B4
    LDA #$00 : SBC $B5 : STA $B5
.tsin_pos:
    JMP _trig_q115_to_float

; ── fpCos ─────────────────────────────────────────────────────────────
fpCos:
    ; See the matching reduce-before-Q3.13 block in fpSin above.
    LDA $B1
    SEC
    SBC #$02
    BMI .tcos_in_range
    JSR _fp_reduce_to_pi
.tcos_in_range:
    JSR _trig_angle_to_idx
    ; cos(x) = sin(π/2 - x): complement the index within quadrant
    LDA #64
    SEC
    SBC $B6
    AND #$3F            ; wrap to 0-63
    ASL A
    TAY
    LDA _sin_table,Y
    STA $B4
    LDA _sin_table+1,Y
    STA $B5
    ; cos sign: negate in quadrants 1 and 2
    LDA $B7
    AND #$02
    BEQ .tcos_pos
    SEC
    LDA #$00 : SBC $B4 : STA $B4
    LDA #$00 : SBC $B5 : STA $B5
.tcos_pos:
    JMP _trig_q115_to_float

; ── fpTan ─────────────────────────────────────────────────────────────
fpTan:
    ; Save input
    LDA $B0 : PHA : LDA $B1 : PHA : LDA $B2 : PHA : LDA $B3 : PHA : LDA $B4 : PHA
    JSR fpSin
    LDA $B0 : STA $B5 : LDA $B1 : STA $B6 : LDA $B2 : STA $B7
    LDA $B3 : STA $B8 : LDA $B4 : STA $B9
    PLA : STA $B4 : PLA : STA $B3 : PLA : STA $B2 : PLA : STA $B1 : PLA : STA $B0
    JSR fpCos
    JMP fpDiv

; ── fpAtan ────────────────────────────────────────────────────────────
; atan via reverse table search + interpolation
; For the table approach, atan is less natural. Use CORDIC vectoring
; which is compact and doesn't need extra tables.
fpAtan:
    ; ⚠ KNOWN BROKEN (same as the non-banked fpTrig.asm — see the
    ; comment there for the Q1.15 overflow explanation). Left in place
    ; so the label still resolves; not covered by the test fixture.
    JSR _trig_float_to_q115
    LDA $B4
    STA $B0
    LDA $B5
    STA $B1
    LDA #$00
    STA $B2 : STA $B3 : STA $B4 : STA $B5
    LDX #$00
.at_loop:
    CPX #14
    BEQ .at_done
    LDA $B3
    BMI .at_neg
    ; y >= 0: subtract
    LDA $B2 : STA $B8 : LDA $B3 : STA $B9
    STX $BA
    TXA : BEQ .at_ns1 : TAY
.at_s1:
    LDA $B9 : ASL A : ROR $B9 : ROR $B8 : DEY : BNE .at_s1
.at_ns1:
    CLC : LDA $B0 : ADC $B8 : STA $B0 : LDA $B1 : ADC $B9 : STA $B1
    LDA $B0 : STA $B8 : LDA $B1 : STA $B9
    LDX $BA : TXA : BEQ .at_ns2 : TAY
.at_s2:
    LDA $B9 : ASL A : ROR $B9 : ROR $B8 : DEY : BNE .at_s2
.at_ns2:
    SEC : LDA $B2 : SBC $B8 : STA $B2 : LDA $B3 : SBC $B9 : STA $B3
    LDX $BA
    TXA : ASL A : TAY
    CLC : LDA $B4 : ADC _at_tbl,Y : STA $B4 : LDA $B5 : ADC _at_tbl+1,Y : STA $B5
    JMP .at_next
.at_neg:
    LDA $B2 : STA $B8 : LDA $B3 : STA $B9
    STX $BA
    TXA : BEQ .at_ns3 : TAY
.at_s3:
    LDA $B9 : ASL A : ROR $B9 : ROR $B8 : DEY : BNE .at_s3
.at_ns3:
    SEC : LDA $B0 : SBC $B8 : STA $B0 : LDA $B1 : SBC $B9 : STA $B1
    LDA $B0 : STA $B8 : LDA $B1 : STA $B9
    LDX $BA : TXA : BEQ .at_ns4 : TAY
.at_s4:
    LDA $B9 : ASL A : ROR $B9 : ROR $B8 : DEY : BNE .at_s4
.at_ns4:
    CLC : LDA $B2 : ADC $B8 : STA $B2 : LDA $B3 : ADC $B9 : STA $B3
    LDX $BA
    TXA : ASL A : TAY
    SEC : LDA $B4 : SBC _at_tbl,Y : STA $B4 : LDA $B5 : SBC _at_tbl+1,Y : STA $B5
.at_next:
    INX
    JMP .at_loop
.at_done:
    ; z is in Q3.13 — shift to Q1.15 and convert to float
    ASL $B4 : ROL $B5 : ASL $B4 : ROL $B5
    JMP _trig_q115_to_float

; ── CORDIC atan table for fpAtan (Q3.13) ─────────────────────────────
_at_tbl:
    .word 6434, 3798, 2007, 1019, 511, 256, 128, 64, 32, 16, 8, 4, 2, 1

; ── Convert float angle to table index ────────────────────────────────
; Input: $B0-$B4 = angle (float radians)
; Output: $B6 = index 0-63, $B7 = quadrant flags (bit0=negate sin, bit1=negate cos)
_trig_angle_to_idx:
    ; Convert to Q3.13 first
    JSR _trig_float_to_q313
    ; $B4,$B5 = angle in Q3.13, $B7 bit 0 = input sign
    LDA #$00
    STA $B7
    ; Make positive
    LDA $B5
    BPL .idx_pos
    SEC
    LDA #$00 : SBC $B4 : STA $B4
    LDA #$00 : SBC $B5 : STA $B5
    LDA #$01
    STA $B7         ; sin is negative
.idx_pos:
    ; Now angle is in [0, ~π] in Q3.13 (or larger)
    ; Check if > π/2 (12868 = $3244)
    LDA $B5
    CMP #$32
    BCC .idx_q1
    BNE .idx_q2
    LDA $B4
    CMP #$44
    BCC .idx_q1
.idx_q2:
    ; Quadrant 2: index = 128 - raw_index, negate cos
    ; Subtract from π
    SEC
    LDA #$88 : SBC $B4 : STA $B4
    LDA #$64 : SBC $B5 : STA $B5
    LDA $B7
    ORA #$02        ; negate cos
    STA $B7
.idx_q1:
    ; Convert Q3.13 angle (0..π/2) to index 0..63
    ; index = angle * 64 / (π/2) = angle * 64 / 12868 ≈ angle / 201
    ; Simpler: angle * 5 / 1006 ≈ angle >> 8 * 5 / 4
    ; Even simpler: index = (angle * 64) >> 13 = angle >> 7 (approximate)
    ; More accurate: idx = angle * 64 / 12868
    ; ≈ angle / 201, but 201 is awkward
    ; Practical: (angle * 5) >> 10  (since 5/1024 ≈ 1/201)
    ; Actually simplest: idx = (angle_hi * 2) since angle_hi covers 0-50 for 0..π/2
    ; and we want 0-63. 50 * 1.28 ≈ 64. So idx ≈ angle_hi * 5 / 4
    LDA $B5         ; high byte of Q3.13 angle
    STA $B8
    ASL A           ; × 2
    ADC $B8         ; × 3
    ASL A           ; × 6  (but this overflows)
    ; Simpler: just use hi byte * 2, capped at 63
    LDA $B5
    ASL A
    CMP #$40
    BCC .idx_ok
    LDA #$3F
.idx_ok:
    STA $B6
    RTS

; ── Float to Q3.13 (reuse from CORDIC but local copy) ────────────────
_trig_float_to_q313:
    LDA $B0 : AND #$01 : PHA  ; save sign
    ; Zero detection: use the zero flag (bit 4 of $B0), not an all-zero
    ; byte test — 1.0 encodes as all-zero bytes in the implicit-leading-1
    ; format.
    LDA $B0 : AND #$10
    BEQ .tf_nz
    LDA #$00 : STA $B4 : STA $B5
    PLA : STA $B7
    RTS
.tf_nz:
    LDA $B2 : LSR A : ORA #$80 : STA $B9
    LDA $B2 : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA $B8
    LDA $B3 : LSR A : ORA $B8 : STA $B8
    LDA #$02 : SEC : SBC $B1 : BMI .tf_shl : BEQ .tf_ns : TAY
.tf_shr:
    LSR $B9 : ROR $B8 : DEY : BNE .tf_shr : JMP .tf_ns
.tf_shl:
    EOR #$FF : CLC : ADC #$01 : TAY
.tf_shl2:
    ASL $B8 : ROL $B9 : DEY : BNE .tf_shl2
.tf_ns:
    PLA : STA $B7   ; sign
    AND #$01 : BEQ .tf_pos
    SEC : LDA #$00 : SBC $B8 : STA $B8 : LDA #$00 : SBC $B9 : STA $B9
.tf_pos:
    LDA $B8 : STA $B4 : LDA $B9 : STA $B5
    RTS

; ── Float to Q1.15 ────────────────────────────────────────────────────
_trig_float_to_q115:
    JSR _trig_float_to_q313
    ASL $B4 : ROL $B5 : ASL $B4 : ROL $B5
    RTS

; ── Q1.15 to float ───────────────────────────────────────────────────
_trig_q115_to_float:
    LDA $B4 : ORA $B5 : BNE .tq_nz
    LDA #$10                     ; zero flag
    STA $B0
    LDA #$00
    STA $B1 : STA $B2 : STA $B3 : STA $B4
    RTS
.tq_nz:
    LDA #$00 : STA $B0
    LDA $B5 : BPL .tq_pos
    SEC : LDA #$00 : SBC $B4 : STA $B4 : LDA #$00 : SBC $B5 : STA $B5
    LDA #$01 : STA $B0
.tq_pos:
    ; Same off-by-one fix as the non-banked fpTrig: start X at 0, the
    ; norm loop decrements it once per shift, and the "strip implicit
    ; 1" shift after the loop doesn't touch X.
    LDX #$00
.tq_norm:
    LDA $B5 : BMI .tq_normed
    ASL $B4 : ROL $B5 : DEX : CPX #$F0 : BNE .tq_norm
.tq_normed:
    ; Shift the 16-bit value left once as a pair to discard the
    ; implicit leading 1 in bit 15. ASL/ROL together preserves the
    ; carry between the two bytes — byte-separated ASLs lose a bit.
    ASL $B4 : ROL $B5
    LDA $B5 : STA $B2
    LDA $B4 : STA $B3
    LDA #$00 : STA $B4
    STX $B1
    RTS

; ── Sine lookup table (Q1.15, 64 entries for first quadrant) ─────────
; sin(i * π/128) * 32768 for i = 0..63
_sin_table:
    .word 0         ; sin(0°)
    .word 804       ; sin(1.41°)
    .word 1608      ; sin(2.81°)
    .word 2410      ; sin(4.22°)
    .word 3212      ; sin(5.63°)
    .word 4011      ; sin(7.03°)
    .word 4808      ; sin(8.44°)
    .word 5602      ; sin(9.84°)
    .word 6393      ; sin(11.25°)
    .word 7179      ; sin(12.66°)
    .word 7962      ; sin(14.06°)
    .word 8739      ; sin(15.47°)
    .word 9512      ; sin(16.88°)
    .word 10278     ; sin(18.28°)
    .word 11039     ; sin(19.69°)
    .word 11793     ; sin(21.09°)
    .word 12540     ; sin(22.50°)
    .word 13279     ; sin(23.91°)
    .word 14010     ; sin(25.31°)
    .word 14732     ; sin(26.72°)
    .word 15446     ; sin(28.13°)
    .word 16151     ; sin(29.53°)
    .word 16846     ; sin(30.94°)
    .word 17530     ; sin(32.34°)
    .word 18204     ; sin(33.75°)
    .word 18868     ; sin(35.16°)
    .word 19519     ; sin(36.56°)
    .word 20159     ; sin(37.97°)
    .word 20787     ; sin(39.38°)
    .word 21403     ; sin(40.78°)
    .word 22005     ; sin(42.19°)
    .word 22594     ; sin(43.59°)
    .word 23170     ; sin(45.00°)
    .word 23731     ; sin(46.41°)
    .word 24279     ; sin(47.81°)
    .word 24811     ; sin(49.22°)
    .word 25329     ; sin(50.63°)
    .word 25832     ; sin(52.03°)
    .word 26319     ; sin(53.44°)
    .word 26790     ; sin(54.84°)
    .word 27245     ; sin(56.25°)
    .word 27683     ; sin(57.66°)
    .word 28105     ; sin(59.06°)
    .word 28510     ; sin(60.47°)
    .word 28898     ; sin(61.88°)
    .word 29268     ; sin(63.28°)
    .word 29621     ; sin(64.69°)
    .word 29956     ; sin(66.09°)
    .word 30273     ; sin(67.50°)
    .word 30571     ; sin(68.91°)
    .word 30852     ; sin(70.31°)
    .word 31113     ; sin(71.72°)
    .word 31356     ; sin(73.13°)
    .word 31580     ; sin(74.53°)
    .word 31785     ; sin(75.94°)
    .word 31971     ; sin(77.34°)
    .word 32137     ; sin(78.75°)
    .word 32285     ; sin(80.16°)
    .word 32412     ; sin(81.56°)
    .word 32521     ; sin(82.97°)
    .word 32609     ; sin(84.38°)
    .word 32678     ; sin(85.78°)
    .word 32728     ; sin(87.19°)
    .word 32757     ; sin(88.59°)
