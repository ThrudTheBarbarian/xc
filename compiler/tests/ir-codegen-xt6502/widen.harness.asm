; widen.harness.asm — call widen(-5), print i16 result. Expected: "-5".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    LDA #$FB         ; i8 -5
    PHA
    JSR _widen
    ADD SP, #1
    ; result: i16 in A:X (lo:hi).
    JSR print_i16
    BRK
