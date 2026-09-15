; byte-list-scalar-float.harness.asm — mkf3() assembles 3.0 from a
; runtime byte pattern ({$00,$01,$80,$00,$00}) via element-wise stores,
; then returns (i16)r. Validates that the 5 stored bytes load back as
; the correct xtc float on xt6502. Expected: "3".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    JSR _mkf3
    JSR print_i16
    BRK

.include "../../support/xt6502/asm/float/fpToI32.asm"
_fpToI32 = fpToI32
