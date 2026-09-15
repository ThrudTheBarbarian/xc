; mixed-call.harness.asm — call run(), print u16 result. Expected: "17061".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    JSR _run         ; no args; result in A:X (lo:hi)
    JSR print_u16
    BRK
