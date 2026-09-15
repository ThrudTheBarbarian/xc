; byte-list-init.harness.asm — call bl(), print u16. Expected: "22139".
; (u16)0x12345678 + (u16)3.0 = 22136 + 3.

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    JSR _bl
    JSR print_u16
    BRK
