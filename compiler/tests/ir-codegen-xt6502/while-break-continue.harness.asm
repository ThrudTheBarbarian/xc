; while-break-continue.harness.asm — call wsum(10), print u16.
; Expected: "18" (1+2+4+5+6; 3 skipped via continue, stop at 7 break).

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    LDA #0
    PHA              ; n high
    LDA #10
    PHA              ; n low (on top → read at +9,SP)
    JSR _wsum
    ADD SP, #2
    JSR print_u16
    BRK
