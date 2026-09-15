; byte-list-aggregate.harness.asm — call run(), print the u16 result.
; Validates array + struct byte-list initialisers (task #59).
; Expected: 10+40+5+7+100+200 = "362".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94
    JSR _run
    JSR print_u16
    BRK
