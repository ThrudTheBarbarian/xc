; short-circuit.harness.asm — call sc(), print u16. Expected: "13".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    JSR _sc
    JSR print_u16
    BRK
