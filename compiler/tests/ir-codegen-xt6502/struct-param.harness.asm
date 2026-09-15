; struct-param.harness.asm — call sp(), print u16. Expected: "42".
; Proves a struct local is pushed by value into sumpt(Point p) and the
; struct param's fields resolve against the spilled param slot (40+2).

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    JSR _sp
    JSR print_u16
    BRK
