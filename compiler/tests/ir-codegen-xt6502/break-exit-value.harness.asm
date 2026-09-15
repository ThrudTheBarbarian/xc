; break-exit-value.harness.asm — call bsum(10), print u16. Expected: "30".
; r += 10 on i=0,1,2 then break; proves the break-point r reaches exit.

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
    JSR _bsum
    ADD SP, #2
    JSR print_u16
    BRK
