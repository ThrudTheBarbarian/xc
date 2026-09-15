; loop-postfix.harness.asm — call sum_postfix(), print u16 result.
; Expected: "45" (proves the i++ loop terminates).

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    JSR _sum_postfix
    JSR print_u16
    BRK
