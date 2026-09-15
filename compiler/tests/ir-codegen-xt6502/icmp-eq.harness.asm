; icmp-eq.harness.asm — call cmp(7), print u16. Expected: "6".
; (7!=5)+2 + (7>5)+4 = 6.

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
    LDA #7
    PHA              ; n low (on top → read at +9,SP)
    JSR _cmp
    ADD SP, #2
    JSR print_u16
    BRK
