; ternary.harness.asm — call mix(), print u16. Expected: "114".
; then-arm 100 + else-arm 14.

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    JSR _mix
    JSR print_u16
    BRK
