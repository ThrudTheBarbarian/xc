; loop.harness.asm — call sum_to(10), print u16 result. Expected: "45".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    LDA #10
    PHA              ; n = 10
    JSR _sum_to
    ADD SP, #1
    JSR print_u16
    BRK
