; struct-local.harness.asm — call sp(), print u16. Expected: "42".
; Proves the value-typed struct local `p` got a pinned slot and the
; field store/load resolved against it (40 + 2).

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
