; for-continue.harness.asm — call fsum(10), print u16. Expected: "42".
; sum 0..9 skipping 3; proves continue runs the increment (no hang).

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
    JSR _fsum
    ADD SP, #2
    JSR print_u16
    BRK
