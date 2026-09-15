; unary-ops.harness.asm — call un(), print u16. Expected: "42".
; Exercises prefix ++/-- (40→41→40) and `!z` (z==0 → true → +2).

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    JSR _un
    JSR print_u16
    BRK
